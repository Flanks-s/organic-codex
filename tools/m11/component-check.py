#!/usr/bin/env python3
"""Build and run an original component harness against the whole product tree.

Usage: python3 tools/m11/component-check.py KIND OUT
See component-check.md for the window/focus audit and result contract.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


# Each flag selects the product's original @main; no product files are replaced.
# The summary is deliberately specific: partial/probe summaries are not a pass.
KINDS = {
    'native': ('M1_SELFTEST', (), r'M1 verification: (\d+) checks, (\d+) findings'),
    'settings': ('SETTINGS_SELFTEST', (), r'Settings (\d+) checks / (\d+) failures'),
    'overlay': ('OVERLAY_SELFTEST', (), r'Overlay verification: (\d+) checks, (\d+) findings'),
    'sheets': ('SHEETS_SELFTEST', (), r'Sheets verification: (\d+) checks, (\d+) findings'),
    'sheets-m101': ('SHEETS_M101_SELFTEST', ('gaussian-debug',), r'M10\.1 Sheets: (\d+) checks, (\d+) findings'),
    'debug': ('DEBUG_SELFTEST', (), r'Debug verification: (\d+) checks, (\d+) failures'),
    'tools': ('TOOLS_SELFTEST', (), r'Tools verification: (\d+) checks, (\d+) findings'),
    'header-ax': ('HEADER_AX_SELFTEST', (), r'Header AX verification: (\d+) checks, (\d+) findings'),
    'split': ('M9_SPLIT_SELFTEST', (), r'Split Dock: (\d+) checks, (\d+) failures'),
    'split-model': ('M9_MODEL_SELFTEST', (), r'Model sizing: (\d+) checks, (\d+) failures'),
    'normie-motion': ('M10_COMPOSER_SELFTEST', (), r'M10-C: (\d+) checks, (\d+) findings'),
    'dock-switches': ('M10_DOCK_SELFTEST', ('--switches',), r'M10 Dock switches: (\d+) checks, (\d+) findings'),
    'dock-gaussian': ('M10_DOCK_SELFTEST', ('--gaussian',), r'M10\.1 Dock/island: (\d+) checks, (\d+) findings'),
}


def write_json(path, value):
    path.write_bytes((json.dumps(value, indent=2) + '\n').encode('utf-8'))


def totals(kind, log, code):
    matches = re.findall('^' + KINDS[kind][2] + r'(?:\b|$)', log, re.MULTILINE)
    if code not in (0, 1) or len(matches) != 1 or int(matches[0][0]) == 0:
        raise ValueError('did not complete (exit {}, {} summaries)'.format(code, len(matches)))
    checks, findings = map(int, matches[0])
    if code != (1 if findings else 0):
        raise ValueError('inconsistent summary and exit {}'.format(code))
    return checks, findings


def run_logged(command, directory, name, *, cwd, env=None):
    """Record only our child PID; keep complete compiler and harness output."""
    record = {'command': command, 'started': time.time()}
    with (directory / (name + '.log')).open('wb') as log:
        child = subprocess.Popen(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
        record['pid'] = child.pid
        write_json(directory / (name + '-process.json'), record)
        record['exitCode'] = child.wait()
    write_json(directory / (name + '-process.json'), record)
    return record['exitCode']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=KINDS)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    directory = out / args.kind
    package = Path(os.environ.get('M11_CHECK_PACKAGE') or out / ('.package-' + args.kind)).resolve()
    if package == root or package in root.parents:
        raise ValueError('The package must be private, outside the repository root and its ancestors')
    if any(package == root / name or root / name in package.parents
           for name in ('Sources', 'Resources')):
        raise ValueError('The package must be outside product source/resource directories')
    directory.mkdir(parents=True, exist_ok=True)
    # A failed repeat must not leave an earlier success receipt or run log.
    for name in ('component-result.json', 'run.log', 'run-process.json'):
        (directory / name).unlink(missing_ok=True)
    flag, arguments, _ = KINDS[args.kind]
    # Decision #195: release only for the overlay debug/release control; debug stays the default. A release build
    # keeps the repository tree (#189: the flattened layout fails whole-module at Keyframes.swift:10).
    configuration = os.environ.get('COMPONENT_CONFIGURATION') or 'debug'
    if configuration not in ('debug', 'release'):
        raise ValueError('COMPONENT_CONFIGURATION must be debug or release')
    prepare = [sys.executable, str(root / 'tools/m11/check_package.py'),
               '--root', str(root), '--package', str(package),
               '--name', 'Component' + args.kind.title().replace('-', ''), '--define', flag]
    if configuration == 'release':
        prepare.append('--keep-tree')
    # --list validates the actual source set without staging body resources.
    with (directory / 'sources.txt').open('wb') as listing:
        subprocess.run(prepare + ['--list'], cwd=root, stdout=listing, check=True)
    subprocess.run(prepare, cwd=root, check=True)
    build = ['swift', 'build', '--package-path', str(package), '-c', configuration, '-j', '4']
    if run_logged(build, directory, 'build', cwd=root):
        print((directory / 'build.log').read_text(errors='replace'), end='')
        print('COMPONENT {}: did not run (build failed)'.format(args.kind))
        return 2
    if os.environ.get('COMPONENT_COMPILE_ONLY') == '1':
        print('COMPONENT {}: compile-only'.format(args.kind))
        return 0
    bin_path = subprocess.check_output(
        ['swift', 'build', '--package-path', str(package), '-c', configuration, '--show-bin-path'],
        cwd=root, text=True).strip()
    env = os.environ.copy()
    # These diagnostic selectors would silently reduce the original full suite.
    for key in ('M9_ORBS_ONLY', 'M1116_WHEEL_ONLY', 'NORMIE_INK_REGION_PROBE',
                'NORMIE_STARTUP_PROBE', 'NORMIE_ALPHA_PROBE',
                'NORMIE_HANDOFF_PROBE', 'NORMIE_STACK_PROBE'):
        env.pop(key, None)
    if args.kind == 'overlay':
        # The old transition entry runs the full Overlay suite with M10 frames.
        env['M10_FRAMES'] = '1'
    if args.kind == 'normie-motion':
        env['NORMIE_CHECK_CONFIGURATION'] = 'debug'
    code = run_logged([str(Path(bin_path) / 'Check'), str(directory), *arguments],
                      directory, 'run', cwd=root, env=env)
    log = (directory / 'run.log').read_text(errors='replace')
    print(log, end='' if log.endswith('\n') else '\n')
    try:
        checks, findings = totals(args.kind, log, code)
    except ValueError as error:
        print('COMPONENT {}: {}'.format(args.kind, error))
        return 3
    write_json(directory / 'component-result.json',
               {'kind': args.kind, 'checks': checks, 'findings': findings, 'exitCode': code,
                'configuration': configuration})
    print('COMPONENT {}: {} checks, {} findings'.format(args.kind, checks, findings))
    return 1 if findings else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('Component harness did not run: {}'.format(error), file=sys.stderr)
        sys.exit(2)
