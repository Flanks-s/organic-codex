#!/usr/bin/env python3
# RETIRED (#186, 2026-11-12): replaced by tools/m11/component-check.py overlay (does not complete yet: debt #75). Kept, not deleted (#181).
"""Windowless M10.1 check: retained debug objects, isolated HEAD archive plus Overlay-owned files only."""
import argparse, subprocess, json, hashlib
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--build',type=Path,default=Path('/tmp/sol-m101-overlay-build'))
p.add_argument('--output',type=Path,default=Path('runs/m10.1-overlay'))
p.add_argument('--fast-pixels',action='store_true')
p.add_argument('--timing',action='store_true',help='One optimized WMO cost-only binary, separate from retained debug objects')
a=p.parse_args();root=a.source.resolve();build=a.build.resolve();out=a.output.resolve();src=root/'Sources/OrganicShell'
build.mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
files=[str(f) for group in ['Engine','Core','Native','Overlay'] for f in sorted((src/group).glob('*.swift')) if f.name!='CoreSettingsController.swift']
fm={'':{'swift-dependencies':str(build/'master.swiftdeps')}}
for f in files:
 b=build/(Path(f).parent.name+'-'+Path(f).stem);fm[f]={'object':str(b)+'.o','swift-dependencies':str(b)+'.swiftdeps','dependencies':str(b)+'.d'}
mapfile=build/'outputs.json';value=json.dumps(fm,sort_keys=True)
if not mapfile.exists() or mapfile.read_text()!=value:mapfile.write_text(value)
signature=json.dumps({str(Path(f).relative_to(root)):hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files},indent=2)
(out/'inputs.json').write_text(signature)
if a.timing:
 binary=build/'timing-verify';stamp=build/'timing-inputs.json'
 if not binary.exists() or not stamp.exists() or stamp.read_text()!=signature:
  with (out/'timing-compile.log').open('w') as log:r=subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-O','-whole-module-optimization','-module-name','OverlayCost','-D','OVERLAY_SELFTEST',*files,'-o',str(binary)],stdout=log,stderr=subprocess.STDOUT)
  if r.returncode:print((out/'timing-compile.log').read_text()[-10000:]);raise SystemExit(r.returncode)
  stamp.write_text(signature)
 subprocess.run([str(binary),str(out),'--cost-only'],check=True)
 raise SystemExit(0)
cmd=['swiftc','-swift-version','6','-parse-as-library','-Onone','-incremental','-enable-batch-mode','-j','4','-output-file-map',str(mapfile),'-module-name','OverlayCheck','-D','OVERLAY_SELFTEST',*files,'-o',str(build/'verify')]
with (out/'compile.log').open('w') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:print((out/'compile.log').read_text()[-10000:]);raise SystemExit(r.returncode)
if a.fast_pixels:
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip();stamp=build/'optimized-pixels.json'
 if not stamp.exists() or stamp.read_text()!=signature:
  with (out/'pixel-compile.log').open('w') as log:
   for name in ['OverlayExposureVerification.swift','OverlayMaterialVerification.swift']:
    primary=next(f for f in files if Path(f).name==name)
    r=subprocess.run(['swiftc','-frontend','-c','-sdk',sdk,'-parse-as-library','-swift-version','6','-O','-module-name','OverlayCheck','-D','OVERLAY_SELFTEST','-primary-file',primary,*[f for f in files if f!=primary],'-o',fm[primary]['object']],stdout=log,stderr=subprocess.STDOUT)
    if r.returncode:print((out/'pixel-compile.log').read_text()[-10000:]);raise SystemExit(r.returncode)
  stamp.write_text(signature)
 with (out/'pixel-link.log').open('w') as log:r=subprocess.run(['swiftc',*[fm[f]['object'] for f in files],'-o',str(build/'verify')],stdout=log,stderr=subprocess.STDOUT)
 if r.returncode:print((out/'pixel-link.log').read_text()[-10000:]);raise SystemExit(r.returncode)
import os
env=dict(os.environ,M10_FRAMES='1')
with (out/'run.log').open('w') as log:
 proc=subprocess.Popen([str(build/'verify'),str(out)],env=env,stdout=log,stderr=subprocess.STDOUT)
 (out/'pid.txt').write_text(str(proc.pid));result=proc.wait()
print((out/'run.log').read_text()[-10000:]);raise SystemExit(result)
