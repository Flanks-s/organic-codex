#!/usr/bin/env python3
"""N3 isolated -O component checks. Dependencies come from git HEAD, never concurrent Core/Debug edits."""
import argparse
import io
from pathlib import Path
import shutil
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['prepare', 'compile', 'run'])
parser.add_argument('suite', nargs='?', choices=['native', 'normie', 'settings', 'overlay', 'benchmark'], default='native')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--baseline', default='2a87c8c')
parser.add_argument('--before', action='store_true')
args = parser.parse_args()
project = Path(__file__).resolve().parents[3]
root = args.output.resolve(); root.mkdir(parents=True, exist_ok=True)
if args.action == 'prepare':
    commit = subprocess.check_output(['git', 'rev-parse', args.baseline], cwd=project, text=True).strip()
    for name in ['repo', 'baseline-repo']:
        dest = root / name
        if dest.exists(): shutil.rmtree(dest)
        dest.mkdir()
        archive = subprocess.check_output(['git', 'archive', commit], cwd=project)
        with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
            for member in contents.getmembers():
                if member.issym() or member.islnk() or dest not in (dest / member.name).resolve().parents:
                    raise ValueError('Unsafe archive member: ' + member.name)
            contents.extractall(dest)
    for group in ['Native', 'Normie']:
        dest = root / 'repo/Sources/OrganicShell' / group
        shutil.rmtree(dest); shutil.copytree(project / 'Sources/OrganicShell' / group, dest)
    fixture = 'Sources/OrganicShell/Native/NativeTranscriptStreamVerification.swift'
    shutil.copy2(project / fixture, root / 'baseline-repo' / fixture)
    (root / 'baseline.txt').write_text(commit + '\n')
    print('Private snapshot:', root, 'dependencies:', commit)
    raise SystemExit(0)

repo = root / ('baseline-repo' if args.before else 'repo')
source = repo / 'Sources/OrganicShell'
groups = {'native': ['Core', 'Native'], 'normie': ['Core', 'Native', 'Orb', 'Tools', 'Normie'],
          'settings': ['Core', 'Native', 'Settings'], 'overlay': ['Core', 'Native', 'Overlay'], 'benchmark': ['Core', 'Native']}
flags = {'native': 'M1_SELFTEST', 'normie': 'NORMIE_SELFTEST', 'settings': 'SETTINGS_SELFTEST', 'overlay': 'OVERLAY_SELFTEST', 'benchmark': 'NATIVE_STREAM_BENCHMARK'}
label = ('baseline-' if args.before else '') + args.suite
binary = root / (label + '-O'); result = root / (label + '-result'); result.mkdir(exist_ok=True)
log = root / (label + '-' + args.action + '.log')
if args.action == 'compile':
    files = [str(p) for g in groups[args.suite] for p in sorted((source / g).glob('*.swift'))
             if p.name != 'CoreSettingsController.swift' or args.suite == 'settings']
    command = ['swiftc', '-swift-version', '6', '-O', '-D', flags[args.suite], '-target', 'arm64-apple-macosx26.0', *files, '-o', str(binary)]
    (root / (label + '-command.txt')).write_text('\n'.join(command) + '\n')
else:
    command = [str(binary), str(result)]
with log.open('w') as handle:
    completed = subprocess.run(command, cwd=repo, stdout=handle, stderr=subprocess.STDOUT)
print(label, args.action, completed.returncode, log, flush=True)
if completed.returncode or args.action == 'run': print(log.read_text()[-18000:])
raise SystemExit(completed.returncode)
