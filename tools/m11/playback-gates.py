#!/usr/bin/env python3
"""Windowless Native + M10-A gates in private incremental debug/per-file-O packages."""
from pathlib import Path
import argparse,json,subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('suite',choices=['native','m10','dock','organic'])
p.add_argument('output',type=Path)
p.add_argument('--cache',type=Path,required=True)
p.add_argument('--compile-only',action='store_true')
p.add_argument('--baseline',type=Path,help='git-show product sources for a separate baseline cache')
a=p.parse_args();root=Path(__file__).resolve().parents[2];src=root/'Sources/OrganicShell'
a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
package=a.cache.resolve()/a.suite;sources=package/'Sources'/'Gate';sources.mkdir(parents=True,exist_ok=True)
files=[f for group in ['Engine','Core','Native','Orb'] for f in sorted((src/group).glob('*.swift')) if f.name != 'CoreSettingsController.swift']
files += [src/f for f in ['Normie/NormieControls.swift','Normie/NormieSidebarChrome.swift','Organic/Look.swift','Organic/TextLayout.swift','Organic/ProductMath.swift','Organic/OrbBridge.swift']]
flag={'native':'M1_SELFTEST','m10':'M10_MODE_SELFTEST','dock':'M10_DOCK_SELFTEST','organic':'ORGANIC_SELFTEST'}[a.suite]
if a.suite=='native':
    # Native only uses the model epoch copier. App flight hosts pull in their own App layer.
    files=[f for f in files if f.parent.name!='Engine' or not f.name.startswith('Mode') or f.name=='ModeContentEpoch.swift']
    files=[f for f in files if f.parent.name!='Orb' or not f.name.endswith('Verification.swift')]
    files += [src/'Settings/SettingsDataSource.swift']
elif a.suite=='m10':files += [src/f for f in ['App/ModeFlight.swift','App/ModeExposure.swift','App/ModeExposureVerification.swift','Debug/ModeSignposts.swift']]
if a.suite in ['dock','organic']:
    files=[f for group in ['Engine','Core','Native','Orb','Normie','Organic','Tools','Island','Overlay','Sheets'] for f in sorted((src/group).glob('*.swift')) if f.name != 'CoreSettingsController.swift']
    files += [src/f for f in ['App/SelfTest.swift','App/LongConversationVerification.swift','App/Offscreen.swift','App/ModeSwitchPreparation.swift','App/ModeFlight.swift','App/ModeExposure.swift','Debug/ModeSignposts.swift']]
for old in sources.iterdir():
    if old.is_symlink():old.unlink()
baseline=json.loads(a.baseline.read_text()) if a.baseline else {}
for f in files:
    original=baseline.get(f.relative_to(root).as_posix())
    target=f
    if original is not None:
        target=package/'baseline'/f.name;target.parent.mkdir(exist_ok=True)
        if not target.exists() or target.read_text()!=original:target.write_text(original)
    (sources/f.name).symlink_to(target)
# App/ stays out of the gates. HeaderPulseThirdVerification's fixture (M11.33) only needs RootView as a flipped container.
stub=sources/'GateRootView.swift'
if a.suite in ['dock','organic']:
    stub.write_text('import AppKit\nfinal class RootView: NSView { override var isFlipped: Bool { true } }\n')
elif stub.exists():stub.unlink()
manifest='''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"PlaybackGate",platforms:[.macOS(.v26)],targets:[.executableTarget(name:"Gate",swiftSettings:[.define("%s"),.unsafeFlags(["-O"])])])
'''%flag
(package/'Package.swift').write_text(manifest)
with (a.output/'build.log').open('w') as log:
    subprocess.run(['swift','build','--package-path',str(package),'-c','debug','-j','4'],stdout=log,stderr=subprocess.STDOUT,check=True)
bin=Path(subprocess.check_output(['swift','build','--package-path',str(package),'-c','debug','--show-bin-path'],text=True).strip())/'Gate'
if a.compile_only:print(bin);raise SystemExit(0)
with (a.output/'run.log').open('w') as log:
    proc=subprocess.Popen([str(bin),str(a.output)],stdout=log,stderr=subprocess.STDOUT)
    code=proc.wait()
print((a.output/'run.log').read_text()[-2000:]);raise SystemExit(code)
