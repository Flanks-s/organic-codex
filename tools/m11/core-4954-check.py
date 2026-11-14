#!/usr/bin/env python3
"""Windowless CoreVerification runner. Invoke on MBA only through tools/mac.

The cache is an owned, disposable SwiftPM package; no app-server is launched.
"""
import argparse
from pathlib import Path
import subprocess
import os
import json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('output', type=Path)
p.add_argument('--cache', type=Path, required=True)
p.add_argument('--only', action='store_true')
p.add_argument('--baseline', type=Path, help='Original product sources exported with git show; current verification is retained')
p.add_argument('--mutation', choices=['49', '50', '51', '52', '53', '54'])
p.add_argument('--skip-debt', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
out = a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
package = a.cache.resolve(); sources = package / 'Sources/Gate'; sources.mkdir(parents=True, exist_ok=True)
src = root / 'Sources/OrganicShell'
files = list((src / 'Core').glob('*.swift'))
files += [src / 'Settings/SettingsDataSource.swift']
# M11.44: Core's saved-state and mock migration call BodyIdentityMigration (Bodies/), which takes a BodyCatalogue
# (Bodies/BodyProfile.swift; Foundation and simd only). Without them the package does not compile and no check runs
# (11-10, ci/infra-152-1). Debt #65 replaces this hand-kept list.
files += [src / 'Bodies/BodyIdentityMigration.swift', src / 'Bodies/BodyProfile.swift']
overrides = json.loads(a.baseline.read_text()) if a.baseline else {}
mutations = {
    '49': ('LiveConversationRuntime.swift', 'try? await read(c, includeSatellites: false)', '// mutation: reconciliation removed'),
    '50': ('LiveConversationRuntime.swift', '} else if !c.sendOutcomeUnknown, c.draftRevision == recoveryRevision {', '} else if !c.sendOutcomeUnknown {'),
    '51': ('HistoryReplay.swift', 'c.exactTokensUsed = state.exactTokensUsed; c.contextLimit = state.contextLimit', '// mutation: usage merge removed'),
    '52': ('HistoryReplay.swift', 'mergeSatellites(into: c, snapshot: snapshot, replaceLifecycle: replaceLifecycle)', 'if replaceLifecycle { c.satellites = state.satellites; c.satellitesRetired = state.satellitesRetired }'),
    '53': ('LocalPresentationState.swift', 'if let reason = writeProtection { throw CoreWire.failure(reason) }', 'if false, let reason = writeProtection { throw CoreWire.failure(reason) }'),
    '54': ('MockBrief.swift', 'if fence != nil { continue }', '// mutation: fenced body admitted'),
}
for f in files:
    relative = str(f.relative_to(root))
    content = overrides.get(relative)
    if a.mutation and f.name == mutations[a.mutation][0]:
        _, old, new = mutations[a.mutation]
        content = f.read_text() if content is None else content
        assert content.count(old) == 1, 'mutation must modify exactly one production site'
        content = content.replace(old, new)
    target = f
    if content is not None:
        target = package / 'overlay' / f.name; target.parent.mkdir(exist_ok=True)
        if not target.exists() or target.read_text() != content: target.write_text(content)
    link = sources / f.name
    if link.is_symlink() and link.resolve() != target.resolve(): link.unlink()
    if not link.exists(): link.symlink_to(target)
manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"Core4954",platforms:[.macOS(.v26)],targets:[.executableTarget(name:"Gate",swiftSettings:[.define("CORE_SELFTEST"),.unsafeFlags(["-O", "-warnings-as-errors"])])])
'''
target = package / 'Package.swift'
if not target.exists() or target.read_text() != manifest: target.write_text(manifest)
with (out / 'build.log').open('w') as log:
    result = subprocess.run(['swift', 'build', '--package-path', str(package), '-c', 'debug', '-j', '4'], stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print((out / 'build.log').read_text()[-12000:]); raise SystemExit(result.returncode)
binary = Path(subprocess.check_output(['swift', 'build', '--package-path', str(package), '-c', 'debug', '--show-bin-path'], text=True).strip()) / 'Gate'
env = dict(os.environ)
if a.only: env['CORE_4954_ONLY'] = '1'
if a.skip_debt: env['CORE_4954_SKIP'] = '1'
with (out / 'check.log').open('w') as log:
    result = subprocess.run([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
print((out / 'check.log').read_text())
raise SystemExit(result.returncode)
