#!/usr/bin/env python3
# RETIRED (#186, 2026-11-12): replaced by tools/m11/component-check.py split, split-model, native, overlay (overlay: debt #75). Kept, not deleted (#181).
"""Export HEAD, overlay this round's NativeComposer implementation/checks, and build incrementally without windows/Core.
--suite model --baseline measures the committed implementation with the new checks; failures demonstrate the regression.
"""
from pathlib import Path
import argparse, hashlib, io, json, subprocess, tarfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,default=Path('/tmp/sol-m9e-check'))
p.add_argument('--baseline',action='store_true')
p.add_argument('--skip-compile',action='store_true')
p.add_argument('--suite',choices=['split','native','normie','overlay','orb','app','m10','model'],default='split')
p.add_argument('--optimize-pixels',action='store_true',help='Use per-file -O within the retained debug build; never enables whole-module optimization.')
p.add_argument('--orb-regression-before',action='store_true',help='Restore only the two diagnosed M9-E regressions in the private export; checks must fail.')
a=p.parse_args()
root=Path(__file__).resolve().parents[3];out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
owned=['Native/NativeComposerControls.swift','Native/NativeComposerMenuButton.swift',
       'Native/NativeComposerModelSizingVerification.swift']
repo=out/'repo';src=repo/'Sources/OrganicShell';target='OrganicShell' if a.suite=='app' else ('SplitCheck' if a.suite=='split' else a.suite.title()+'Check');binary=out/'build/debug'/target
if not a.skip_compile:
    repo.mkdir(exist_ok=True)
    revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    (out/'revision.txt').write_text(revision+'\n')
    archive=subprocess.check_output(['git','archive',revision],cwd=root)
    def put(path, data):
        path.parent.mkdir(parents=True,exist_ok=True)
        if not path.exists() or path.read_bytes()!=data: path.write_bytes(data)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        archived=set(tar.getnames())
        for member in tar.getmembers():
            if member.name=='Package.swift' and a.suite!='app': continue
            if member.isfile() and (a.baseline or member.name not in ['Sources/OrganicShell/'+f for f in owned]):
                put(repo/member.name,tar.extractfile(member).read())
    if a.baseline:
        for f in owned:
            if 'Sources/OrganicShell/'+f not in archived: (src/f).unlink(missing_ok=True)
    if not a.baseline:
        for f in owned:put(src/f,(root/'Sources/OrganicShell'/f).read_bytes())
    if a.orb_regression_before:
        for f,old,new in [('Organic/DockNode.swift','let content = DockNode.Passage()','let content = NSView()'),
                          ('Organic/DockNode.swift','let k = max(metrics.orb, metrics.orbMagnified, 1) / max(1, r.width)','let k = max(metrics.orb, 1) / max(1, r.width)')]:
            text=(src/f).read_text()
            if old not in text: raise ValueError('Regression fixture anchor missing: '+old)
            put(src/f,text.replace(old,new,1).encode())
    put(src/'Native/NativeComposerModelSizingVerification.swift',(root/'Sources/OrganicShell/Native/NativeComposerModelSizingVerification.swift').read_bytes())
    put(src/'Native/NativeComposerSplitVerification.swift',Path(__file__).with_name('NativeComposerSplitVerification.swift').read_bytes())
    groups=['Core','Native','Orb','Tools','Normie','Island','Overlay','Sheets','Engine','Organic']
    files=[f for g in groups for f in sorted((src/g).glob('*.swift')) if f.name!='CoreSettingsController.swift']
    files += [src/'App/SelfTest.swift',src/'App/Offscreen.swift']
    if a.suite=='app': files=sorted(src.rglob('*.swift'))
    (out/'inputs.json').write_text(json.dumps({str(f.relative_to(src)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
    defines=[{'split':'M9_SPLIT_SELFTEST','native':'M1_SELFTEST','normie':'NORMIE_SELFTEST','overlay':'OVERLAY_SELFTEST','orb':'ORB_SELFTEST','app':'','m10':'M10_DOCK_SELFTEST','model':'M9_MODEL_SELFTEST'}[a.suite]]+(['M9_SPLIT_BASELINE'] if a.baseline else [])
    manifest='// swift-tools-version: 6.2\nimport PackageDescription\nlet package=Package(name:'+json.dumps(target)+',platforms:[.macOS(.v26)],targets:[.executableTarget(name:'+json.dumps(target)+',path:"Sources/OrganicShell",sources:'+json.dumps([str(f.relative_to(src)) for f in files])+',swiftSettings:['+','.join('.define('+json.dumps(d)+')' for d in defines)+'])])\n'
    if a.suite!='app': put(repo/'Package.swift',manifest.encode())
    command=['swift','build','--package-path',str(repo),'--scratch-path',str(out/'build'),'-c','debug','--jobs','4']
    if a.optimize_pixels: command += ['-Xswiftc','-O']
    with (out/'compile.log').open('w') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
    if r.returncode:print((out/'compile.log').read_text()[-16000:]);raise SystemExit(r.returncode)
if a.suite=='app':
    print('Built only (no launch):',binary)
    raise SystemExit(0)
with (out/'run.log').open('w') as log:r=subprocess.run([str(binary),str(out)],cwd=repo,stdout=log,stderr=subprocess.STDOUT)
print((out/'run.log').read_text()[-16000:]);raise SystemExit(r.returncode)
