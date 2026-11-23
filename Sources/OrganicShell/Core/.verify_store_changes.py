#!/usr/bin/env python3
# RETIRED (#186, 2026-11-12): replaced by tools/m11/component-check.py native, settings, overlay (overlay: debt #75). Kept, not deleted (#181).
"""Offscreen checks in a frozen HEAD archive. Retains per-suite debug incremental object caches.
Run from a private work/baseline checkout, with the output directory as the second positional argument.
No runtime environment or application switches are added.
"""
from pathlib import Path
import json, subprocess, sys
suite, output = sys.argv[1], Path(sys.argv[2]).resolve()
source = Path(__file__).resolve().parents[1]
repo = source.parents[1]
if subprocess.run(['git','rev-parse','--is-inside-work-tree'],cwd=repo,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0:
    raise SystemExit('Run this checker from a private git archive, never the shared worktree.')
if not output.is_relative_to(Path('/tmp').resolve()):
    raise SystemExit('Verification artifacts must stay under /tmp.')
groups = {'core':['Core','Settings'], 'native':['Core','Engine','Native'],
          'normie':['Core','Engine','Native','Orb','Tools','Normie'],
          'settings':['Core','Engine','Native','Settings'], 'overlay':['Core','Engine','Native','Overlay'],
          'benchmark':['Core','Engine','Native']}
flags = {'core':'CORE_SELFTEST', 'native':'M1_SELFTEST','normie':'NORMIE_SELFTEST',
         'settings':'SETTINGS_SELFTEST','overlay':'OVERLAY_SELFTEST','benchmark':'NATIVE_STREAM_BENCHMARK'}
build = output / (suite+'-build'); build.mkdir(parents=True, exist_ok=True)
files = [p for g in groups[suite] for p in sorted((source/g).glob('*.swift'))
         if (p.name != 'CoreSettingsController.swift' or suite in ['core','settings'])
         and (suite != 'core' or g != 'Settings' or p.name == 'SettingsDataSource.swift')]
if suite == 'normie':
    files.append(source/'Debug/ModeSignposts.swift')
# Baseline has no scan counter: its old refresh scans the prefix on every successful incremental pass.
if suite == 'benchmark' and 'historyScanCount' not in (source/'Native/NativeTranscript.swift').read_text():
    compat = build/'BaselineCounter.swift'; compat.write_text('import AppKit\nextension NativeTranscript { var historyScanCount: Int { fullIndexRebuildCount + incrementalRefreshCount } }\n')
    files.append(compat)
    # Use the identical measure() function in both builds. Only the post-change assertions/other benchmarks
    # are omitted in baseline, whose Native implementation has no typed API or new verification entry point.
    fixture = source/'Native/NativeTranscriptStoreBenchmark.swift'
    baseline_main = build/'BaselineBenchmark.swift'
    code = fixture.read_text()
    baseline_main.write_text(code[:code.index('        var findings:')]+'    }\n}\n#endif\n')
    files = [p for p in files if p.name not in ['NativeTranscriptStreamVerification.swift','NativeTranscriptStoreBenchmark.swift']]
    files.append(baseline_main)
filemap = {'': {'swift-dependencies':str(build/'master.swiftdeps')}}
for p in files:
    stem = p.parent.name+'_'+p.stem
    filemap[str(p)] = {'object':str(build/(stem+'.o')), 'swift-dependencies':str(build/(stem+'.swiftdeps')), 'dependencies':str(build/(stem+'.d'))}
mapfile = build/'outputs.json'; mapfile.write_text(json.dumps(filemap))
binary = output/(suite+'-selftest')
cmd = ['swiftc','-swift-version','6','-parse-as-library','-target','arm64-apple-macosx26.0',
       '-incremental','-enable-batch-mode','-j','4','-emit-executable','-emit-module','-module-name', 'StoreChecks_'+suite,
       '-emit-module-path',str(build/'Checks.swiftmodule'),'-output-file-map',str(mapfile),
       '-O' if suite == 'benchmark' else '-Onone','-g','-D',flags[suite],*map(str,files),'-o',str(binary)]
(output/(suite+'-command.json')).write_text(json.dumps(cmd,indent=2))
with (output/(suite+'-compile.log')).open('w') as log:
    result = subprocess.run(cmd,cwd=repo,stdout=log,stderr=subprocess.STDOUT)
if result.returncode:
    print((output/(suite+'-compile.log')).read_text()[-16000:]); sys.exit(result.returncode)
resultdir = output/(suite+'-result'); resultdir.mkdir(exist_ok=True)
cmd = [str(binary)] if suite == 'core' else [str(binary),str(resultdir)]
with (output/(suite+'-results.log')).open('w') as log:
    result = subprocess.run(cmd,cwd=repo,stdout=log,stderr=subprocess.STDOUT)
print((output/(suite+'-results.log')).read_text()[-22000:]); sys.exit(result.returncode)
