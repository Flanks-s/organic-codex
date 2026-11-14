#!/usr/bin/env python3
"""Prepare a private windowless SwiftPM executable from the whole product tree.

CLI paths (including --add and replacement paths) are relative to --root, except
the package and body staging directories, which are relative to the working directory.
Exclusions/replacement names are basenames or product/repository-relative paths.
--list validates and prints all compiled Swift sources, including the resource target,
without creating directories, links, bytecode, or invoking the body baker.

Python callers can use prepare(root, package, add=..., exclude=..., define=...,
replacement={"Name.swift": path}, name=..., body_assets=..., keep_tree=False). The default Check layout remains
flat (Sources/Check/<basename>); keep_tree=True preserves repository-relative
directories. Use separate package directories for the two layouts. It returns the
resolved Check sources keyed by their destination basenames. The package's Sources
directories are private to this helper; stale files there are removed on preparation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


EXCLUSIONS = (
    'App/Main.swift',  # The caller supplies the executable's entry point.
)


def source_path(root, value):
    path = Path(value)
    return (root / path).resolve(strict=True)


def matches(path, value, root):
    value = str(value).replace('\\', '/')
    return value in (path.name, path.relative_to(root).as_posix(),
                     path.relative_to(root / 'Sources/OrganicShell').as_posix())


def collect(root, *, add=(), exclude=(), replacement=None):
    """Resolve/validate the source set without touching the filesystem."""
    root = Path(root).resolve(strict=True)
    product = sorted((root / 'Sources/OrganicShell').rglob('*.swift'))
    omitted = set()
    for value in (*EXCLUSIONS, *exclude):
        found = [path for path in product if matches(path, value, root)]
        if not found:
            raise ValueError('Exclusion matches no product source: ' + str(value))
        omitted.update(found)
    files = [path for path in product if path not in omitted]
    sources = {}
    for path in files + [source_path(root, value) for value in add]:
        if not path.is_file() or path.suffix != '.swift':
            raise ValueError('Not a Swift source file: ' + str(path))
        if path.name in sources:
            raise ValueError('Duplicate source basename: {} ({}, {})'.format(
                path.name, sources[path.name], path))
        sources[path.name] = path
    replaced = set()
    for value, replacement_path in (replacement or {}).items():
        found = [path for path in files if matches(path, value, root)]
        if len(found) != 1:
            raise ValueError('Replacement must match one included product source: ' + str(value))
        name = found[0].name
        if name in replaced:
            raise ValueError('Repeated replacement: ' + name)
        replaced.add(name)
        path = source_path(root, replacement_path)
        if not path.is_file():
            raise ValueError('Not a replacement file: ' + str(path))
        sources[name] = path
    return sources


def write_changed(path, data):
    if not path.is_file() or path.read_bytes() != data:
        path.write_bytes(data)


def link(source, destination):
    source = source.resolve(strict=True)
    # Keep correct relative links too; dangling and mutant links are replaced.
    if destination.is_symlink() and destination.resolve() == source:
        return
    if destination.is_symlink() or destination.is_file():
        destination.unlink()
    elif destination.exists():
        raise ValueError('Expected a file or link: ' + str(destination))
    destination.symlink_to(source, target_is_directory=source.is_dir())


def stage_bodies(root, directory):
    # Import only during preparation: --list also works on Windows, without fcntl
    # or Swift. The product owns texture validation and the sprite cache key.
    import fcntl
    import importlib.util
    import sys

    spec = importlib.util.spec_from_file_location('check_body_baker', root / 'scripts/build-body-assets.py')
    baker = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(baker)
    finally:
        sys.dont_write_bytecode = previous
    directory.mkdir(parents=True, exist_ok=True)
    assets = directory / 'BodyAssets.app'
    # A shared directory is staged once for unchanged inputs, even across packages
    # and jobs. A lock also protects Python callers preparing packages concurrently.
    with (directory / '.check-package.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = '\n'.join((baker.input_key(root),
                         os.environ.get('ORGANIC_BODY_SPRITE_LAYOUT', 'direction-pack'),
                         hashlib.sha256((root / 'Resources/Credits.rtf').read_bytes()).hexdigest(),
                         hashlib.sha256((root / 'scripts/package-bodies.sh').read_bytes()).hexdigest()))
        marker = directory / '.check-package-inputs'
        bodies = assets / 'Contents/Resources/Bodies'
        credits = assets / 'Contents/Resources/Credits.rtf'
        if (not marker.is_file() or marker.read_bytes() != key.encode('utf-8')
                or not (bodies / 'Sprites/index.json').is_file() or not credits.is_file()):
            marker.unlink(missing_ok=True)
            subprocess.run(['zsh', str(root / 'scripts/package-bodies.sh'), str(root), str(assets)], check=True)
            marker.write_bytes(key.encode('utf-8'))
    return assets


def tree_sources(root, sources, originals):
    """Keep repository paths, including the original path of a replacement.

    An added file outside the repository has no repository-relative directory;
    place it under tools/added so generated drivers follow the product tree.
    Basename uniqueness is still validated by collect().
    """
    files = {}
    for name, source in sources.items():
        original = originals[name]
        try:
            relative = original.relative_to(root)
        except ValueError:
            relative = Path('tools/added') / original.name
        files[relative.as_posix()] = source
    return files


def link_tree(directory, files):
    """Synchronize only the helper-owned Check tree, without following links."""
    if directory.is_symlink():
        raise ValueError('Expected a private directory: ' + str(directory))
    directory.mkdir(parents=True, exist_ok=True)
    for current, directories, names in os.walk(directory, topdown=False, followlinks=False):
        for name in names:
            path = Path(current) / name
            if path.relative_to(directory).as_posix() not in files:
                path.unlink()
        for name in directories:
            path = Path(current) / name
            if path.is_symlink():
                path.unlink()
            elif not any(path.iterdir()):
                path.rmdir()
    for relative, source in files.items():
        destination = directory / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        link(source, destination)


def prepare(root, package, *, add=(), exclude=(), define=(), replacement=None,
            name='WindowlessCheck', body_assets=None, keep_tree=False):
    """Link the full source set and shared body bundle; preserve unchanged mtimes."""
    root = Path(root).resolve(strict=True)
    sources = collect(root, add=add, exclude=exclude, replacement=replacement)
    package = Path(package).resolve()
    assets = stage_bodies(root, Path(body_assets).resolve() if body_assets else package / 'body-assets')
    targets = {
        'Check': sources,
        'OrganicBodyResources': {
            'BodyResources.swift': root / 'Resources/BodyResources.swift',
            'Bodies': assets / 'Contents/Resources/Bodies',
            'Credits.rtf': assets / 'Contents/Resources/Credits.rtf',
        },
    }
    if keep_tree:
        originals = collect(root, add=add, exclude=exclude)
        link_tree(package / 'Sources' / 'Check', tree_sources(root, sources, originals))
        del targets['Check']
    for target, files in targets.items():
        directory = package / 'Sources' / target
        directory.mkdir(parents=True, exist_ok=True)
        for stale in directory.iterdir():
            if stale.name not in files:
                if stale.is_symlink() or stale.is_file():
                    stale.unlink()
                else:
                    raise ValueError('Unexpected directory in private source target: ' + str(stale))
        for basename, source in files.items():
            link(source, directory / basename)
    settings = ['.define({})'.format(json.dumps(flag)) for flag in dict.fromkeys(define)]
    settings.append('.unsafeFlags(["-O"])')
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: %s, platforms: [.macOS(.v26)], targets: [
    .target(name: "OrganicBodyResources", resources: [.copy("Bodies"), .copy("Credits.rtf")]),
    .executableTarget(name: "Check", dependencies: ["OrganicBodyResources"],
                      swiftSettings: [%s])
])
''' % (json.dumps(name), ', '.join(settings))
    write_changed(package / 'Package.swift', manifest.encode('utf-8'))
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--package', type=Path)
    parser.add_argument('--name', default='WindowlessCheck')
    parser.add_argument('--body-assets', type=Path, default=os.environ.get('CHECK_BODY_ASSETS'))
    parser.add_argument('--keep-tree', action='store_true',
                        help='Keep repository-relative Check source directories (default: flat basenames)')
    parser.add_argument('--exclude', action='append', default=[])
    parser.add_argument('--add', action='append', default=[])
    parser.add_argument('--define', action='append', default=[])
    parser.add_argument('--replace', action='append', default=[], metavar='NAME=PATH')
    parser.add_argument('--list', action='store_true', help='Print sources and count; write nothing')
    args = parser.parse_args()
    replacement = {}
    for value in args.replace:
        key, separator, path = value.partition('=')
        if not separator or not key or not path or key in replacement:
            parser.error('Expected a unique NAME=PATH replacement: ' + value)
        replacement[key] = path
    options = dict(add=args.add, exclude=args.exclude, define=args.define,
                   replacement=replacement, name=args.name, body_assets=args.body_assets,
                   keep_tree=args.keep_tree)
    try:
        if args.list:
            sources = collect(args.root, add=args.add, exclude=args.exclude, replacement=replacement)
            paths = list(sources.values()) + [source_path(args.root.resolve(), 'Resources/BodyResources.swift')]
            for path in sorted(os.path.relpath(path, args.root.resolve()).replace('\\', '/') for path in paths):
                print(path)
            print('{} sources'.format(len(paths)))
        else:
            if args.package is None:
                parser.error('--package is required unless --list is used')
            prepare(args.root, args.package, **options)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, '{}\n'.format(error))


if __name__ == '__main__':
    main()
