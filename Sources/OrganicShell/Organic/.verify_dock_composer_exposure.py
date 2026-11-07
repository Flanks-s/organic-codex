#!/usr/bin/env python3
"""M10-G windowless checks against an isolated git-archive HEAD + only Dock-owned files. Persistent debug objects."""
from pathlib import Path
import argparse, subprocess, json, hashlib
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True,help='Private HEAD archive; never reads peer worktree source')
p.add_argument('--probe',action='store_true')
p.add_argument('--fast-pixels',action='store_true',help='Keep production objects debug; optimize only SelfTest and the pixel verifier primary files')
p.add_argument('--switches',action='store_true')
p.add_argument('--suite',choices=['dock','orb','scene'],default='dock')
p.add_argument('--build',type=Path,default=Path('/tmp/sol-m10g-check-build'))
p.add_argument('--output',type=Path,default=Path('runs/m10-dock-hooks'))
a=p.parse_args();root=a.source.resolve();src=root/'Sources/OrganicShell';out=a.output.resolve()/a.suite;out.mkdir(parents=True,exist_ok=True)
build=a.build.resolve()/('orb' if a.suite=='orb' else 'dock');build.mkdir(parents=True,exist_ok=True)
groups=['Engine','Orb'] if a.suite=='orb' else ['Core','Native','Orb','Tools','Normie','Island','Overlay','Sheets','Engine','Organic']
files=[str(f) for group in groups for f in sorted((src/group).glob('*.swift')) if f.name!='CoreSettingsController.swift']
if a.suite!='orb':files += [str(src/'App'/name) for name in ['SelfTest.swift','Offscreen.swift']]
flag='ORB_SELFTEST' if a.suite=='orb' else 'M10_DOCK_SELFTEST'
filemap={'':{'swift-dependencies':str(build/'master.swiftdeps')}}
for f in files:
 b=build/(Path(f).parent.name+'-'+Path(f).stem);filemap[f]={'object':str(b)+'.o','swift-dependencies':str(b)+'.swiftdeps','dependencies':str(b)+'.d'}
m=build/'outputs.json';value=json.dumps(filemap,sort_keys=True)
if not m.exists() or m.read_text()!=value:m.write_text(value)
(out/'inputs.json').write_text(json.dumps({str(Path(f).relative_to(root)):hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files},indent=2))
cmd=['swiftc','-swift-version','6','-parse-as-library','-Onone','-incremental','-enable-batch-mode','-j','4','-output-file-map',str(m),'-module-name','M10DockCheck','-D',flag,*files,'-o',str(build/'verify')]
with (out/'compile.log').open('w') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:print((out/'compile.log').read_text()[-14000:]);raise SystemExit(r.returncode)
if a.fast_pixels and a.suite!='orb':
    sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
    # Swift debug production objects stay unchanged. Only CPU-heavy image comparison/Metal readback test
    # primary files use -O, without WMO. Cache by EVERY dependency's source hash for repeatability.
    stamp=build/'pixel-optimized-inputs.json';signature=(out/'inputs.json').read_text()
    if not stamp.exists() or stamp.read_text()!=signature:
        with (out/'pixel-compile.log').open('w') as log:
            for name in ['SelfTest.swift','DockMotionVerification.swift']:
                primary=next(f for f in files if Path(f).name==name)
                r=subprocess.run(['swiftc','-frontend','-c','-sdk',sdk,'-parse-as-library','-swift-version','6','-O','-module-name','M10DockCheck','-D',flag,'-primary-file',primary,*[f for f in files if f!=primary],'-o',filemap[primary]['object']],stdout=log,stderr=subprocess.STDOUT)
                if r.returncode:print((out/'pixel-compile.log').read_text()[-10000:]);raise SystemExit(r.returncode)
        stamp.write_text(signature)
    with (out/'pixel-link.log').open('w') as log:r=subprocess.run(['swiftc',*[filemap[f]['object'] for f in files],'-o',str(build/'verify')],stdout=log,stderr=subprocess.STDOUT)
    if r.returncode:print((out/'pixel-link.log').read_text()[-10000:]);raise SystemExit(r.returncode)
with (out/'run.log').open('w') as log:
 proc=subprocess.Popen([str(build/'verify'),str(out)]+(['--scene'] if a.suite=='scene' else ['--switches'] if a.switches else ['--hooks-probe'] if a.probe else []),stdout=log,stderr=subprocess.STDOUT)
 (out/'pid.txt').write_text(str(proc.pid));result=proc.wait()
print((out/'run.log').read_text()[-14000:]);raise SystemExit(result)
