#!/usr/bin/env python3
# RETIRED (#186, 2026-11-12): replaced by tools/m11/component-check.py native. Kept, not deleted (#181).
"""M9 remaining sidebar/card parity: private HEAD export, incremental debug only, no window/backend."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--suite', choices=['all', 'rest', 'native', 'normie', 'scene'], default='all')
p.add_argument('--directory', type=Path, default=Path('/tmp/sol-m9-normie-rest-26103011'))
p.add_argument('--baseline', action='store_true', help='HEAD implementation plus current new verifier; parity assertions are expected to fail')
a = p.parse_args()
repo = Path(__file__).resolve().parents[3]
base = a.directory.resolve()
base.mkdir(parents=True, exist_ok=True)
root = base / ('baseline-source' if a.baseline else 'source')
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
if not root.exists():
    root.mkdir()
    archive = subprocess.Popen(['git', 'archive', head], cwd=repo, stdout=subprocess.PIPE)
    subprocess.run(['tar', '-x', '-C', str(root)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait(): raise SystemExit('git archive failed')
    (base / (root.name + '-head.txt')).write_text(head + '\n')
# The shared worktree's unrelated App/composer/motion edits never enter this build.
names = ['Normie/NormieSidebarRestVerification.swift']
if not a.baseline:
    names += ['Normie/NormieSidebarCell.swift', 'Normie/NormieSidebarChrome.swift',
              'Normie/NormieSidebarParityVerification.swift', 'Native/NativeTranscriptCard.swift']
for name in names:
    src = repo / 'Sources/OrganicShell' / name
    target = root / 'Sources/OrganicShell' / name
    if not target.exists() or target.read_bytes() != src.read_bytes(): target.write_bytes(src.read_bytes())
(base / ('baseline-overlay.json' if a.baseline else 'overlay.json')).write_text(json.dumps(
    {name: hashlib.sha256((root / 'Sources/OrganicShell' / name).read_bytes()).hexdigest() for name in names}, indent=2))
env = os.environ.copy()
env['NORMIE_CHECK_CONFIGURATION'] = 'debug'
env['NORMIE_REST_REFERENCE'] = str(repo / 'runs/parity-m9ef-105708/normie-product.png')
env.setdefault('M9_SIDEBAR_PRODUCT', str(repo / 'runs/parity-205445/normie-product.png'))

def run(command, logfile, *, environment=env):
    with logfile.open('w') as log:
        r = subprocess.run(command, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
    print(logfile.read_text()[-10000:], flush=True)
    return r.returncode

suites = ['rest', 'native', 'normie', 'scene'] if a.suite == 'all' else [a.suite]
status = 0
for suite in suites:
    if suite == 'scene':
        if a.baseline: p.error('baseline is for component comparisons')
        scratch = base / 'build-app-optimized-files'
        # Debug driver, optimized individual files, no -whole-module-optimization or release build.
        if run(['swift', 'build', '-c', 'debug', '-Xswiftc', '-O', '--package-path', str(root),
                '--scratch-path', str(scratch), '--skip-update'], base / 'app-build-optimized-files.log'):
            raise SystemExit(1)
        for scale in [1, 2]:
            e = {**env, 'SELFTEST_SCALES': str(scale)}
            status |= run([str(scratch / 'debug/OrganicShell'), '--selftest', str(base / f'selftest-{scale}x')],
                          base / f'selftest-{scale}x.log', environment=e)
        continue
    suffix = '-baseline' if a.baseline else ''
    build = base / ('build-' + suite + suffix)
    build.mkdir(exist_ok=True)
    groups = ['Core', 'Native', 'Engine'] + (['Orb', 'Tools', 'Normie'] if suite != 'native' else [])
    files = sorted(str(f) for group in groups for f in (root / 'Sources/OrganicShell' / group).glob('*.swift')
                   if f.name != 'CoreSettingsController.swift')
    flag = {'native': 'M1_SELFTEST', 'normie': 'NORMIE_SELFTEST', 'rest': 'M9_NORMIE_REST_SELFTEST'}[suite]
    mapping = {'': {'swift-dependencies': str(build / 'master.swiftdeps')}}
    for f in files:
        b = build / Path(f).stem
        mapping[f] = {'object': str(b) + '.o', 'swift-dependencies': str(b) + '.swiftdeps', 'dependencies': str(b) + '.d'}
    mp = build / 'output-file-map.json'
    text = json.dumps(mapping, sort_keys=True)
    if not mp.exists() or mp.read_text() != text: mp.write_text(text)
    command = ['swiftc', '-swift-version', '6', '-parse-as-library', '-Onone', '-incremental',
               '-enable-batch-mode', '-j', '4', '-output-file-map', str(mp), '-module-name', 'RestChecks', '-D', flag]
    if a.baseline: command += ['-D', 'M9_REST_BASELINE']
    command += files + ['-o', str(build / 'verify')]
    (build / 'command.json').write_text(json.dumps(command, indent=2))
    if run(command, build / 'compile.log'): raise SystemExit(1)
    out = base / ('result-' + suite + suffix)
    out.mkdir(exist_ok=True)
    status |= run([str(build / 'verify'), str(out)], base / (suite + suffix + '.log'))
raise SystemExit(status)
