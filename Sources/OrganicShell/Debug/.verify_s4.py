#!/usr/bin/env python3
# RETIRED (#186, 2026-11-12): historical comparison. Kept, not deleted (#181).
"""S4 isolated verification: git archive baseline + only this task's Core/Debug files.

No app launch, real transport, or backend data directories. Standalone suites use
fixtures; Tools' only PTY child is a harmless command in its temporary output.
"""
import argparse
import io
from pathlib import Path
import shutil
import subprocess
import tarfile

GROUPS = {
    'core': ['Core'], 'debug': ['Core', 'Native', 'Orb', 'Debug'],
    'native': ['Core', 'Native'], 'normie': ['Core', 'Native', 'Orb', 'Tools', 'Normie'],
    'settings': ['Core', 'Native', 'Settings'], 'overlay': ['Core', 'Native', 'Overlay'],
    'tools': ['Core', 'Tools'], 'island': ['Core', 'Native', 'Orb', 'Tools', 'Normie', 'Island'],
    'header_ax': ['Core', 'Native', 'Orb', 'Tools', 'Normie', 'Island', 'Debug'],
}
FLAGS = dict(core='CORE', debug='DEBUG', native='M1', normie='NORMIE', settings='SETTINGS',
             overlay='OVERLAY', tools='TOOLS', island='ISLAND', header_ax='HEADER_AX')
CORE_FILES = ['MockPlayback.swift', 'MockReplay.swift', 'MockPlaybackVerification.swift', 'CoreVerification.swift']

def run(command, cwd, log):
    print('RUN', ' '.join(map(str, command)), flush=True)
    with log.open('w') as handle:
        result = subprocess.run(list(map(str, command)), cwd=cwd, stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-16000:], flush=True)
        raise SystemExit(result.returncode)
    print(log.read_text()[-2000:], flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='674ae833f225b82d8565a4da9521fe150c5cd1e9')
    parser.add_argument('--output', type=Path, default=Path('/tmp/sol-s4-verification'))
    parser.add_argument('--suite', nargs='+', choices=list(GROUPS), default=['core', 'debug'])
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    if not output.is_relative_to(Path('/tmp').resolve()):
        raise SystemExit('S4 verification output must be under /tmp')
    output.mkdir(parents=True, exist_ok=True)
    private = output/'repo'
    if private.exists():
        raise SystemExit('Use a fresh output directory; an existing private checkout is never overwritten.')
    private.mkdir()
    archive = subprocess.check_output(['git', 'archive', args.baseline], cwd=source)
    with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
        for member in contents.getmembers():
            if not (private/member.name).resolve().is_relative_to(private) or member.issym() or member.islnk():
                raise ValueError('Unsafe archive member: '+member.name)
        contents.extractall(private)
    for name in CORE_FILES:
        relative = Path('Sources/OrganicShell/Core')/name
        shutil.copy2(source/relative, private/relative)
    for path in (source/'Sources/OrganicShell/Debug').glob('*.swift'):
        shutil.copy2(path, private/path.relative_to(source))
    (output/'baseline.txt').write_text(subprocess.check_output(['git','rev-parse',args.baseline],cwd=source,text=True))
    print('PRIVATE', private, flush=True)
    if args.prepare_only:
        return
    suites = list(GROUPS) if args.all else args.suite
    for suite in suites:
        files = sorted({p for group in GROUPS[suite] for p in (private/'Sources/OrganicShell'/group).glob('*.swift')})
        dependency = private/'Sources/OrganicShell/Settings/SettingsDataSource.swift'
        if dependency not in files:
            files.append(dependency)
        binary = output/(suite+'-selftest')
        command = ['swiftc','-swift-version','6','-D',FLAGS[suite]+'_SELFTEST','-parse-as-library','-target','arm64-apple-macosx26.0']
        command += ['-warnings-as-errors'] if suite == 'core' else ['-O']
        run(command+files+['-o',binary], private, output/(suite+'-compile.log'))
        result = output/suite
        result.mkdir(exist_ok=True)
        run([binary,result] if suite != 'core' else [binary], private, output/(suite+'-results.log'))
    if args.build:
        run(['swift','build','-c','release','--scratch-path',output/'build-sol-s4','-j','2'],private,output/'release-build.log')
    print('S4 verification complete:', output)

if __name__ == '__main__':
    main()
