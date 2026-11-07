#!/usr/bin/env python3
"""Current-tree component verification; no app, window, backend, or product build is started."""
import argparse
import hashlib
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('suite', choices=['all', 'normie', 'native', 'settings'], default='all', nargs='?')
    parser.add_argument('--output', type=Path, default=Path('/tmp/sol-m9-sidebar-final'))
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--run-only', action='store_true')
    args = parser.parse_args()
    if args.compile_only and args.run_only:
        parser.error('choose compile-only or run-only')
    repo = Path(__file__).resolve().parents[3]
    source = repo / 'Sources/OrganicShell'
    args.output.mkdir(parents=True, exist_ok=True)
    groups = {'native': ['Core', 'Native'], 'normie': ['Core', 'Native', 'Orb', 'Tools', 'Normie'], 'settings': ['Core', 'Native', 'Settings']}
    flags = {'native': 'M1', 'normie': 'NORMIE', 'settings': 'SETTINGS'}
    suites = ['native', 'normie', 'settings'] if args.suite == 'all' else [args.suite]
    for suite in suites:
        files = sorted(p for group in groups[suite] for p in (source / group).glob('*.swift')
                       if p.name != 'CoreSettingsController.swift' or suite == 'settings')
        binary = args.output / (suite + '-selftest')
        if not args.run_only:
            command = ['swiftc', '-swift-version', '6', '-O', '-whole-module-optimization', '-D', flags[suite] + '_SELFTEST',
                       '-target', 'arm64-apple-macosx26.0', *map(str, files), '-o', str(binary)]
            (args.output / (suite + '-command.txt')).write_text('\n'.join(command) + '\n')
            def digest():
                return {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
            before = digest()
            with (args.output / (suite + '-compile.log')).open('w') as log:
                result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                text = (args.output / (suite + '-compile.log')).read_text()
                errors = [line for line in text.splitlines() if 'error:' in line]
                print('\n'.join(errors) if errors else text[-12000:])
                raise SystemExit(result.returncode)
            if before != digest():
                raise SystemExit('Sources changed during compilation; rerun this suite after the parallel writer settles.')
        if not args.compile_only:
            result_dir = args.output / (suite + '-result')
            result_dir.mkdir(exist_ok=True)
            with (args.output / (suite + '-run.log')).open('w') as log:
                result = subprocess.run([str(binary), str(result_dir)], cwd=repo, stdout=log, stderr=subprocess.STDOUT)
            print((args.output / (suite + '-run.log')).read_text()[-20000:])
            if result.returncode:
                raise SystemExit(result.returncode)
    print('Component reports and PNGs:', args.output)


if __name__ == '__main__':
    main()
