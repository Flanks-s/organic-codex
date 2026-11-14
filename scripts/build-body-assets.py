#!/usr/bin/env python3
"""Verify board inputs and build a disposable, content-addressed sprite cache outside the repository."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


OWNER = b'OrganicShell disposable body cache v1\n'
ENTRY = re.compile(r'([0-9a-f]{64})-direction-(?:pack|files)')
KEY_LOCK = re.compile(r'([0-9a-f]{64})\.lock')
RESIDUE = re.compile(r'\.(?:body-build|invalid)-([0-9a-f]{64})-[a-zA-Z0-9_-]+')
LEGACY_RESIDUE = re.compile(r'(?:\.body-build-[a-zA-Z0-9_-]+|\.invalid-[0-9a-f]{32})')
DEFAULT_MAX_ENTRIES = 3
DEFAULT_MAX_BYTES = 1536 * 1024 * 1024


def owned_cache(base, create=False):
    """Never follow a cache-root or ownership-marker symlink."""
    base = base.expanduser().absolute()
    if base.is_symlink():
        raise RuntimeError('Refusing a linked body cache root')
    if create:
        base.mkdir(parents=True, exist_ok=True)
    base = base.resolve(strict=True)
    marker = base / '.organic-body-cache-v1'
    if not marker.exists() and not marker.is_symlink() and create:
        if any(base.iterdir()):
            raise RuntimeError('Refusing an unowned nonempty body cache directory')
        try:
            with marker.open('xb') as stream:
                stream.write(OWNER)
        except FileExistsError:
            pass
    with regular_file(marker, os.O_RDONLY) as stream:
        if stream.read() != OWNER:
            raise RuntimeError('Invalid body cache ownership marker')
    return base


@contextmanager
def regular_file(path, flags):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError('Refusing a nonregular body cache file: ' + str(path))
        stream = os.fdopen(fd, 'rb' if flags == os.O_RDONLY else 'a+b')
    except BaseException:
        os.close(fd)
        raise
    with stream:
        yield stream


@contextmanager
def namespace_lock(base):
    # This permanent lock serializes key-lock creation, acquisition and unlinking.
    # Never wait for a key lock while holding it: builders may already own a key.
    with regular_file(base / '.cache-maintenance.lock', os.O_RDWR | os.O_CREAT) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


@contextmanager
def cache_key_lock(base, key):
    if not re.fullmatch(r'[0-9a-f]{64}', key):
        raise RuntimeError('Invalid body cache key')
    while True:
        with namespace_lock(base):
            handle = regular_file(base / (key + '.lock'), os.O_RDWR | os.O_CREAT)
            lock = handle.__enter__()
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                handle.__exit__(None, None, None)
            except BaseException:
                handle.__exit__(*sys.exc_info())
                raise
            else:
                break
        time.sleep(0.05)
    try:
        yield lock
    finally:
        handle.__exit__(None, None, None)


def tree_bytes(path):
    """Validate the entire deletion candidate before removing anything."""
    info = path.lstat()
    if stat.S_ISREG(info.st_mode):
        return info.st_size
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError('Refusing a linked or special cache path: ' + str(path))
    return sum(tree_bytes(child) for child in path.iterdir())


def cache_warning(receipt, message):
    receipt['warnings'].append(message)
    print('WARNING: body cache eviction: ' + message, file=sys.stderr)


def evict_cache(cache_base, current, max_entries=None, max_bytes=None, current_fd=None):
    """Best-effort LRU pruning. The caller keeps its current key leased throughout."""
    receipt = {'removed': [], 'freedBytes': 0, 'warnings': []}
    held = []
    try:
        max_entries = int(os.environ.get('ORGANIC_BODY_CACHE_MAX_ENTRIES', DEFAULT_MAX_ENTRIES)
                          if max_entries is None else max_entries)
        max_bytes = int(os.environ.get('ORGANIC_BODY_CACHE_MAX_BYTES', DEFAULT_MAX_BYTES)
                        if max_bytes is None else max_bytes)
        if max_entries < 1 or max_bytes < 1:
            raise ValueError('Cache limits must be positive integers')
        receipt.update(maxEntries=max_entries, maxBytes=max_bytes)
        base = owned_cache(cache_base)
        if current.parent != base or not ENTRY.fullmatch(current.name) or current.is_symlink() or not current.is_dir():
            raise RuntimeError('Unsafe current cache entry')
        with namespace_lock(base):
            paths = list(base.iterdir())
            entries, residues, locks = [], [], {}
            # Reject links anywhere in our namespace before any deletion. Foreign names stay untouched.
            for path in paths:
                if path.is_symlink():
                    raise RuntimeError('Refusing a linked cache path: ' + str(path))
                entry, lock = ENTRY.fullmatch(path.name), KEY_LOCK.fullmatch(path.name)
                residue = RESIDUE.fullmatch(path.name) or LEGACY_RESIDUE.fullmatch(path.name)
                if entry or residue:
                    size = tree_bytes(path)
                    if not path.is_dir():
                        raise RuntimeError('Expected a cache directory: ' + str(path))
                    if entry:
                        entries.append((path, size, path.stat().st_mtime_ns, entry[1]))
                    else:
                        residues.append((path, size, RESIDUE.fullmatch(path.name)))
                elif lock:
                    if path.is_symlink() or not path.is_file():
                        raise RuntimeError('Unsafe cache lock: ' + str(path))
                    locks[lock[1]] = path
            current_key = ENTRY.fullmatch(current.name)[1]
            if current_fd is not None:
                owner = os.fstat(current_fd)
                named = (base / (current_key + '.lock')).lstat()
                if not stat.S_ISREG(named.st_mode) or (owner.st_dev, owner.st_ino) != (named.st_dev, named.st_ino):
                    raise RuntimeError('Current lease does not match its named key lock')
                fcntl.flock(current_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            busy = set()
            for key, path in locks.items():
                if key == current_key and current_fd is not None:
                    continue
                handle = regular_file(path, os.O_RDWR)
                stream = handle.__enter__()
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    handle.__exit__(None, None, None)
                    busy.add(key)
                except BaseException:
                    handle.__exit__(*sys.exc_info())
                    raise
                else:
                    held.append(handle)

            def remove(path, size, kind):
                try:
                    if path.parent != base or path.is_symlink():
                        raise RuntimeError('Unsafe cache removal: ' + str(path))
                    if kind == 'lock':
                        path.unlink()
                    else:
                        shutil.rmtree(path)
                    receipt['removed'].append({'name': path.name, 'kind': kind, 'bytes': size})
                    receipt['freedBytes'] += size
                    return True
                except (OSError, RuntimeError) as error:
                    cache_warning(receipt, str(error))
                    return False

            remaining = {path.name for path, _, _, _ in entries}
            count, total = len(entries), sum(item[1] for item in entries)
            for path, size, _, key in sorted(entries, key=lambda item: (item[2], item[0].name)):
                if count <= max_entries and total <= max_bytes:
                    break
                if path == current or key in busy:
                    continue
                if remove(path, size, 'entry'):
                    remaining.remove(path.name)
                    count -= 1
                    total -= size
            for path, size, match in residues:
                # Old random-only names cannot identify an owner. Clean them only with all keys idle.
                # A verified current lease belongs to this completed bake, not another active owner.
                active = match[1] in busy if match else bool(busy)
                if not active:
                    remove(path, size, 'residue')
            for key, path in locks.items():
                if key not in busy and not any(name.startswith(key + '-') for name in remaining):
                    # A failed residue removal still needs its key lock on the next sweep.
                    if not any(p.exists() for p, _, match in residues if match and match[1] == key):
                        remove(path, path.stat().st_size, 'lock')
            receipt.update(remainingEntries=count, remainingBytes=total,
                           limitsSatisfied=count <= max_entries and total <= max_bytes)
    except (OSError, RuntimeError, ValueError) as error:
        cache_warning(receipt, str(error))
    finally:
        for handle in reversed(held):
            handle.__exit__(None, None, None)
    return receipt


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def approved_textures(root):
    manifest = json.loads((root / 'Resources/Bodies/manifest.json').read_text(encoding='utf-8'))
    if manifest['profile'] != 'org.organic.bodies.v2' or len(manifest['assets']) != 16:
        raise RuntimeError('Unsupported approved texture manifest')
    directory = (root / 'design/orrery/project/tex').resolve()
    result = []
    for asset in manifest['assets']:
        source = (root / asset['repositoryPath']).resolve()
        if directory not in source.parents or source.stat().st_size != asset['bytes'] or digest(source) != asset['sha256']:
            raise RuntimeError('Unapproved texture input: ' + str(source))
        result.append(source)
    return result


def valid_cache(directory, key, layout):
    try:
        if any(p.is_symlink() for p in (directory, directory / 'cache.json', directory / 'Sprites')):
            return False
        receipt = json.loads((directory / 'cache.json').read_text())
        if receipt['inputSHA256'] != key or receipt['layout'] != layout:
            return False
        paths = list((directory / 'Sprites').iterdir())
        if any(p.is_symlink() or not p.is_file() for p in paths):
            return False
        actual = {p.name for p in paths}
        if actual != set(receipt['files']):
            return False
        for name, record in receipt['files'].items():
            if Path(name).name != name:
                return False
            source = directory / 'Sprites' / name
            if source.stat().st_size != record['bytes'] or digest(source) != record['sha256']:
                return False
        return bool(receipt['files']) and (directory / 'Sprites/index.json').is_file()
    except (OSError, ValueError, KeyError):
        return False


def input_key(root):
    root = root.resolve()
    textures = approved_textures(root)
    sources = sorted((root / 'Sources/OrganicShell/Bodies').glob('*.swift'))
    inputs = sources + [root / 'tools/bodies/BakePackage.swift', Path(__file__).resolve()]
    inputs += sorted(p for p in (root / 'Resources/Bodies').iterdir() if p.is_file()) + textures
    hasher = hashlib.sha256()
    hasher.update(platform.platform().encode())
    hasher.update(subprocess.check_output(['swiftc', '--version']))
    for path in inputs:
        hasher.update(str(path.relative_to(root)).encode())
        hasher.update(bytes.fromhex(digest(path)))
    return hasher.hexdigest()


def touch_cache(destination, maintenance):
    try:
        os.utime(destination, None, follow_symlinks=False)
    except OSError as error:
        # A failed timestamp update must not make an otherwise valid build unusable.
        cache_warning(maintenance, 'Cannot update last use: ' + str(error))


@contextmanager
def cache_lease(root, layout, cache_base, maintenance=None):
    """Yield path/hit/key/fd; keep the key leased through consumption and pass fd to child readers."""
    root = root.resolve()
    if layout not in ('direction-pack', 'direction-files'):
        raise RuntimeError('Unsupported sprite layout')
    resolved = cache_base.expanduser().resolve()
    if root == resolved or root in resolved.parents:
        raise RuntimeError('Body cache must be outside the repository')
    key = input_key(root)
    sources = sorted((root / 'Sources/OrganicShell/Bodies').glob('*.swift'))
    cache_base = owned_cache(cache_base, create=True)
    destination = cache_base / (key + '-' + layout)
    maintenance = maintenance if maintenance is not None else {}
    with cache_key_lock(cache_base, key) as lock:
        if destination.is_symlink():
            raise RuntimeError('Refusing a linked cache entry')
        hit = valid_cache(destination, key, layout)
        if not hit:
            if destination.exists():
                tree_bytes(destination)
            with tempfile.TemporaryDirectory(prefix='.body-build-' + key + '-', dir=cache_base) as temporary:
                bake(root, layout, cache_base, destination, key, sources, Path(temporary), lock.fileno())
        maintenance.setdefault('warnings', [])
        touch_cache(destination, maintenance)
        warnings = maintenance['warnings']
        maintenance.update(evict_cache(cache_base, destination, current_fd=lock.fileno()))
        maintenance['warnings'] = warnings + maintenance['warnings']
        try:
            yield destination, hit, key, lock.fileno()
        finally:
            touch_cache(destination, maintenance)


def bake(root, layout, cache_base, destination, key, sources, work, lease_fd):
    binary = work / 'bake-package'
    command = ['swiftc', '-swift-version', '6', '-parse-as-library', '-O', *map(str, sources),
               str(root / 'tools/bodies/BakePackage.swift'), '-o', str(binary)]
    # The child keeps the lease even if its Python parent exits while it is still working.
    subprocess.run(command, check=True, cwd=root, pass_fds=(lease_fd,))
    subprocess.run([str(binary), str(root), str(work / 'Sprites'), layout], check=True, cwd=root,
                   pass_fds=(lease_fd,))
    files = {p.name: {'bytes': p.stat().st_size, 'sha256': digest(p)}
             for p in sorted((work / 'Sprites').iterdir()) if p.is_file()}
    receipt = {'inputSHA256': key, 'layout': layout, 'files': files}
    (work / 'cache.json').write_bytes(json.dumps(receipt, sort_keys=True).encode('utf-8'))
    binary.unlink()
    if destination.exists():
        if destination.parent != cache_base or not re.fullmatch(r'[0-9a-f]{64}-direction-(pack|files)', destination.name):
            raise RuntimeError('Unsafe cache replacement')
        tree_bytes(destination)
        quarantine = cache_base / ('.invalid-' + key + '-' + uuid.uuid4().hex)
        destination.rename(quarantine)
    work.rename(destination)

def build(root, layout, cache_base):
    # Compatibility for build-only callers. Payload consumers must use cache_lease instead.
    with cache_lease(root, layout, cache_base) as result:
        return result[:3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('--layout', choices=['direction-pack', 'direction-files'],
                        default=os.environ.get('ORGANIC_BODY_SPRITE_LAYOUT', 'direction-pack'))
    args = parser.parse_args()
    if args.app.suffix != '.app':
        raise RuntimeError('Body resources must be staged in an app bundle')
    cache_base = Path(os.environ.get('ORGANIC_BODY_CACHE_ROOT', str(Path.home() / 'Library/Caches/OrganicShell/Bodies')))
    start = time.monotonic()
    maintenance = {}
    with cache_lease(args.root, args.layout, cache_base, maintenance) as (cache, hit, key, lease_fd):
        stage(args.root, args.app, cache, lease_fd)
        try:
            with os.fdopen(os.open(cache / 'bake-timing.json', os.O_RDONLY | os.O_NOFOLLOW),
                           encoding='utf-8') as timing:
                bake_timing = json.loads(timing.read())
        except (OSError, ValueError):
            # Optional telemetry must neither outlive the cache lease nor invalidate staged resources.
            bake_timing = None
    receipt = {'inputSHA256': key, 'cacheHit': hit, 'layout': args.layout, 'cacheDirectory': str(cache),
               'wallSeconds': time.monotonic() - start, 'eviction': maintenance,
               'bakeTiming': bake_timing}
    (args.app.parent / (args.app.name + '.body-build.json')).write_bytes(json.dumps(receipt, indent=2).encode('utf-8'))
    print('BODY ASSETS ' + json.dumps(receipt))


def stage(root, app, cache, lease_fd):
    destination = app / 'Contents/Resources/Bodies'
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(['rsync', '-a', '--delete', str(cache / 'Sprites') + '/', str(destination / 'Sprites') + '/'],
                   check=True, pass_fds=(lease_fd,))
    for path in (root / 'Resources/Bodies').iterdir():
        if path.is_file():
            shutil.copyfile(path, destination / path.name)
    textures = destination / 'Textures'
    textures.mkdir(exist_ok=True)
    for path in approved_textures(root.resolve()):
        shutil.copyfile(path, textures / path.name)
    shutil.copyfile(root / 'Resources/Credits.rtf', app / 'Contents/Resources/Credits.rtf')


if __name__ == '__main__':
    main()
