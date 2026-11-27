#!/usr/bin/env python3
# RETIRED (#186, 2026-11-12): replaced by tools/m11/component-check.py native, overlay (overlay: debt #75). Kept, not deleted (#181).
"""M9 Organic/component offscreen gates. Never launches App/Main or connects a backend.
Each compiler reads an immutable worktree input copy; source hashes are retained with the report.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('suites', nargs='*', choices=['native','normie','overlay','island','organic','scene'])
    parser.add_argument('--output', type=Path, default=Path('/tmp/sol-m9-organic-verification'))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    source = repo / 'Sources/OrganicShell'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    base = ['Core','Native','Orb','Tools','Normie','Island','Overlay','Sheets','Engine','Organic']
    groups = {'native':['Core','Native','Engine'], 'normie':['Core','Native','Engine','Orb','Tools','Normie'],
              'overlay':['Core','Native','Engine','Overlay'], 'island':['Core','Native','Engine','Orb','Tools','Normie','Island'],
              'organic':base, 'scene':base}
    flags = {'native':'M1','normie':'NORMIE','overlay':'OVERLAY','island':'ISLAND','organic':'ORGANIC'}
    for suite in args.suites or groups:
        inputs = output / 'inputs' / suite
        inputs.mkdir(parents=True, exist_ok=True)
        files, hashes = [], {}
        candidates = [p for g in groups[suite] for p in sorted((source / g).glob('*.swift'))
                      if p.name != 'CoreSettingsController.swift']
        if suite in ['organic','scene']:
            candidates += [source / 'App/SelfTest.swift', source / 'App/Offscreen.swift']
        for p in candidates:
            relative = p.relative_to(source)
            content = p.read_bytes()
            copy = inputs / relative
            copy.parent.mkdir(parents=True, exist_ok=True)
            copy.write_bytes(content)
            files.append(str(copy))
            hashes[str(relative)] = hashlib.sha256(content).hexdigest()
        if suite == 'scene':
            driver = inputs / 'OffscreenDriver.swift'
            driver.write_text('import AppKit\n@main @MainActor enum SceneGate { static func main() { exit(SelfTest.run(to: CommandLine.arguments[1], size: CGSize(width:1280,height:820))) } }\n')
            files.append(str(driver))
        (output / (suite + '-inputs.json')).write_text(json.dumps(hashes, indent=2) + '\n')
        binary = output / (suite + '-selftest')
        command = ['swiftc','-swift-version','6','-O','-whole-module-optimization','-target','arm64-apple-macosx26.0']
        if suite in flags:
            command += ['-D', flags[suite] + '_SELFTEST']
        command += files + ['-o', str(binary)]
        log = output / (suite + '-compile.log')
        print('Compiling', suite, flush=True)
        with log.open('w') as handle:
            result = subprocess.run(command, cwd=repo, stdout=handle, stderr=subprocess.STDOUT)
        if result.returncode:
            print(log.read_text()[-10000:]); raise SystemExit(result.returncode)
        result_dir = output / suite
        result_dir.mkdir(exist_ok=True)
        log = output / (suite + '-run.log')
        with log.open('w') as handle:
            result = subprocess.run([str(binary), str(result_dir)], cwd=repo, env=os.environ.copy(),
                                    stdout=handle, stderr=subprocess.STDOUT)
        print(log.read_text()[-7000:], flush=True)
        if result.returncode:
            raise SystemExit(result.returncode)
    print('Offscreen gates passed:', output)


if __name__ == '__main__':
    main()
