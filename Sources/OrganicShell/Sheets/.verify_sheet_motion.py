#!/usr/bin/env python3
"""M10-F: immutable inputs, offscreen only; no App/Main, network transport or real backend.

Debt #65 round two (decision #181, 11-17): the current-tree check is built from the whole product tree by
tools/m11/check_package.py (App/Main.swift out); the suite's flag (M10_F_SELFTEST, SHEETS_SELFTEST, ORB_SELFTEST,
ORGANIC_SELFTEST) selects the product's own @main. motion remains the M10-F motion entry.
sheets is retired in favor of tools/m11/component-check.py sheets. The current Orb and Organic checks have
tools/bodies/run-host-regressions.py orb and organic as successors. The pre-M10-F f760de9 Orb baseline is a
retired historical comparison, available via explicit --suite orb. motion always skips that comparison.
The legacy modes remain available for compatibility.
--input-root now names a tree root (containing Sources/OrganicShell and Resources), never edited.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'tools/m11'))
import check_package  # noqa: E402

FLAGS = {'motion': 'M10_F_SELFTEST', 'sheets': 'SHEETS_SELFTEST', 'orb': 'ORB_SELFTEST',
         'organic': 'ORGANIC_SELFTEST'}
DISABLE_F = ['Orb/OrbComponent.swift', 'Organic/DraftColumn.swift', 'Sheets/SheetMotion.swift',
             'Sheets/SheetToasts.swift']


class Runner:
    """Starts children, records their PIDs, and stops only its own children."""

    def __init__(self, record):
        self.record = record
        self.owned = []

    def run(self, command, **kwargs):
        child = subprocess.Popen(command, **kwargs)
        entry = {'pid': child.pid, 'command': [str(x) for x in command]}
        self.owned.append(entry)
        try:
            entry['exitCode'] = child.wait()
            return entry['exitCode']
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait()
                entry['terminatedByPID'] = child.pid
            self.record.write_text(json.dumps(self.owned, indent=2) + '\n')


def orb_baseline(a, out, runner):
    """Retired pre-M10-F Orb endpoint comparison (explicit historical runs only)."""
    baseline = out / 'inputs-orb-m9'
    names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', a.baseline_ref, '--',
                                     'Sources/OrganicShell/Orb', 'Sources/OrganicShell/Engine'],
                                    cwd=REPO, text=True).splitlines()
    files = []
    hashes = {}
    for name in names:
        if not name.endswith('.swift'):
            continue
        data = subprocess.check_output(['git', 'show', a.baseline_ref + ':' + name], cwd=REPO)
        dest = baseline / Path(name).relative_to('Sources/OrganicShell')
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        files.append(str(dest))
        hashes[name] = hashlib.sha256(data).hexdigest()
    (out / 'orb-m9-baseline.json').write_text(json.dumps({'ref': a.baseline_ref, 'files': hashes}, indent=2) + '\n')
    binary = out / 'orb-m9-check'
    with (out / 'orb-m9-compile.log').open('w') as log:
        code = runner.run(['swiftc', '-swift-version', '6', '-O', '-whole-module-optimization', '-D', 'ORB_SELFTEST',
                           '-target', 'arm64-apple-macosx26.0', *files, '-o', str(binary)],
                          cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
    if code:
        print((out / 'orb-m9-compile.log').read_text()[-10000:])
        return code
    return runner.run([str(binary), str(out / 'm9-orb')], cwd=REPO)


def motion_harness(root, out):
    """Replace the retired comparison only in a private copy of the M10-F self-test."""
    original = root / 'Sources/OrganicShell/Sheets/SheetMotionVerification.swift'
    source = original.read_text(encoding='utf-8')
    historical_check = (
        r'^        let baseline=out\.appendingPathComponent\("m9-orb"\),current=out\n'
        r'^        var compared=0\n'
        r'^        for file in .*pathExtension=="png" \{\n'
        r'^            guard let a=.*else\{continue\}\n'
        r'^            compared\+=1;check\(pixels\(a\)==pixels\(b\),"orb baseline pixels ".*\)\n'
        r'^        \}\n'
        r'^        print\("Orb baseline PNG compared: .*\n'
        r'^        check\(compared==32,"all 32 committed M9 Orb endpoints compared '
        r'\(run --suite orb first\)"\)\n'
    )
    skip = '        print("\\nSKIP: Orb endpoint baseline f760de9 (retired historical comparison)")\n'
    source, count = re.subn(historical_check, lambda _: skip, source, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit('Expected exactly one retired Orb comparison in ' + str(original))
    private = out / 'motion-harness' / original.name
    private.parent.mkdir(exist_ok=True)
    check_package.write_changed(private, source.encode('utf-8'))
    return private


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--output', type=Path, default=Path('runs/m10-draft-subagent'))
    p.add_argument('--suite', choices=['motion', 'sheets', 'orb', 'organic'], default='motion')
    p.add_argument('--baseline-ref', default='f760de9', help='Retired pre-M10-F baseline for --suite orb only')
    p.add_argument('--input-root', type=Path, help='Optional immutable tree root for regression isolation')
    p.add_argument('--disable-f', action='store_true', help='Diagnostic only: disable just F exposure in copies')
    a = p.parse_args()
    out = (REPO / a.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    runner = Runner(out / (a.suite + '-processes.json'))
    root = a.input_root.resolve() if a.input_root else REPO
    if a.suite == 'orb':
        code = orb_baseline(a, out, runner)
        if code:
            return code
    replacement = {}
    if a.suite == 'motion':
        replacement['Sheets/SheetMotionVerification.swift'] = motion_harness(root, out)
    if a.disable_f:
        copies = out / ('disabled-f-' + a.suite)
        copies.mkdir(exist_ok=True)
        for rel in DISABLE_F:
            data = (root / 'Sources/OrganicShell' / rel).read_bytes()
            data, count = re.subn(rb'(var exposureEnabled\s*=\s*)true', rb'\g<1>false', data, count=1)
            if count != 1:
                raise SystemExit('Missing diagnostic exposure switch: ' + rel)
            (copies / Path(rel).name).write_bytes(data)
            replacement[rel] = copies / Path(rel).name
    package = out / ('package-' + a.suite)
    sources = check_package.prepare(root, package, define=[FLAGS[a.suite]], replacement=replacement or None,
                                    name='SheetMotion' + a.suite.title(),
                                    body_assets=os.environ.get('CHECK_BODY_ASSETS'))
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources.values()}
    (out / (a.suite + '-inputs.json')).write_text(json.dumps(hashes, indent=2) + '\n')
    with (out / (a.suite + '-compile.log')).open('w') as log:
        code = runner.run(['swift', 'build', '--package-path', str(package), '-c', 'debug', '-j', '4'],
                          cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
    if code:
        print((out / (a.suite + '-compile.log')).read_text()[-12000:])
        return code
    bin_dir = subprocess.check_output(['swift', 'build', '--package-path', str(package), '-c', 'debug',
                                       '--show-bin-path'], cwd=REPO, text=True).strip()
    return runner.run([str(Path(bin_dir) / 'Check'), str(out)], cwd=REPO)


if __name__ == '__main__':
    sys.exit(main())
