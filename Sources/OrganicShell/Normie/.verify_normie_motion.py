#!/usr/bin/env python3
"""M10-C windowless checks. Compiles to /tmp; never launches the app or any backend."""
from pathlib import Path
import argparse
import subprocess
import os
import hashlib

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--suite',choices=['motion','native','normie'],default='motion')
p.add_argument('--motion-source',help='Read only the two motion implementation files from a Git ref; run the CURRENT regression checks')
p.add_argument('--dependency-source',help='Read non-motion dependencies from the recorded Git ref, for a fair A/B against the recorded app; never checkout')
p.add_argument('--incremental-release',action='store_true',help='Optimized per-file incremental build, preserving objects; no repeat WMO')
p.add_argument('--configuration',choices=['debug','release'],default='debug',help='Persistent incremental debug by default; optimized WMO only for the final timing run')
p.add_argument('--build-directory',type=Path,default=Path('/tmp/sol-m10c-handoff-build'))
p.add_argument('--motion-directory',type=Path,help='Frozen worktree motion source, without checkout; current verifier and other dependencies')
p.add_argument('--region-probe',action='store_true',help='Exact motion pixels with full versus tight glyph textures')
p.add_argument('--startup-probe',action='store_true',help='Opening first 120Hz frames, CPU attribution and replicated texture area')
p.add_argument('--alpha-probe',action='store_true',help='Replay real-window opaque cached canvas, verify glass ink keeps transparent blank pixels')
p.add_argument('--handoff-probe',action='store_true',help='Only approval material continuity and 120Hz handback regression')
p.add_argument('--probe',action='store_true',help='Run only the windowless live-layer pipeline regression')
p.add_argument('--baseline',action='store_true',help='Read HEAD into /tmp for an unchanged baseline; never changes the worktree')
p.add_argument('--output',type=Path,default=Path('runs/m10-composer'))
a=p.parse_args()
if (a.probe or a.handoff_probe or a.alpha_probe or a.startup_probe or a.region_probe or a.motion_source or a.motion_directory) and a.suite!='motion':p.error('motion probes require --suite motion')
if a.motion_source and a.motion_directory:p.error('choose --motion-source OR --motion-directory')
root=Path(__file__).resolve().parents[3];out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
groups=['Core','Native','Engine']+(['Orb','Tools','Normie'] if a.suite!='native' else [])
suffix=a.suite+('-deps-'+a.dependency_source[:12] if a.dependency_source else '')+('-frozen' if a.motion_directory else '')+('-baseline' if a.baseline else '')+('-source-'+a.motion_source[:12].replace('/','_') if a.motion_source else '')
revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip() if a.baseline else None
build=a.build_directory.resolve()/suffix/a.configuration;build.mkdir(parents=True,exist_ok=True)
snapshot=build/'sources';snapshot.mkdir(parents=True,exist_ok=True)
files=[]
for group in groups:
    if a.dependency_source:
        names=subprocess.check_output(['git','ls-tree','-r','--name-only',a.dependency_source,'--','Sources/OrganicShell/'+group],cwd=root,text=True).splitlines()
        group_files=[root/n for n in names if n.endswith('.swift')]
    else:group_files=list((root/'Sources/OrganicShell'/group).glob('*.swift'))
    for f in sorted(group_files):
        if f.name=='CoreSettingsController.swift':continue
        target=snapshot/(group+'-'+f.name)
        from_ref=revision if a.baseline else a.motion_source if group=='Normie' and f.name in ['NormieMotion.swift','NormieDetail.swift'] else None
        if a.dependency_source and not (group=='Normie' and f.name in ['NormieMotion.swift','NormieMotionVerification.swift']):from_ref=a.dependency_source
        frozen=a.motion_directory/f.name if a.motion_directory and group=='Normie' and f.name in ['NormieMotion.swift','NormieDetail.swift'] else None
        if frozen and frozen.exists():
            content=frozen.read_bytes()
        elif from_ref:
            data=subprocess.run(['git','show',from_ref+':'+str(f.relative_to(root))],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
            if data.returncode:continue
            content=data.stdout
        else:content=f.read_bytes()
        if not target.exists() or target.read_bytes()!=content:target.write_bytes(content)
        files.append(str(target))
binary=build/'verify'
flag={'motion':'M10_COMPOSER_SELFTEST','native':'M1_SELFTEST','normie':'NORMIE_SELFTEST'}[a.suite]
import json
filemap={'':{'swift-dependencies':str(build/'master.swiftdeps')}}
for f in files:
    base=build/Path(f).stem;filemap[f]={'object':str(base)+'.o','swift-dependencies':str(base)+'.swiftdeps','dependencies':str(base)+'.d'}
mapfile=build/'output-file-map.json';maptext=json.dumps(filemap,sort_keys=True)
if not mapfile.exists() or mapfile.read_text()!=maptext:mapfile.write_text(maptext)
optimization=['-O','-whole-module-optimization'] if a.configuration=='release' and not a.incremental_release else ['-O' if a.configuration=='release' else '-Onone','-incremental','-enable-batch-mode','-j','4','-output-file-map',str(mapfile)]
inputs={'configuration':a.configuration,'dependencySource':a.dependency_source,'optimization':optimization,'motionDirectory':str(a.motion_directory) if a.motion_directory else None,'sources':{Path(f).name:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files}}
input_text=json.dumps(inputs,indent=2,sort_keys=True)
(out/'inputs.json').write_text(input_text)
build_input=build/'successful-inputs.json'
cached=a.configuration=='release' and binary.exists() and build_input.exists() and build_input.read_text()==input_text
with (out/'compile.log').open('w') as log:
    if cached:
        log.write('Reuse unchanged optimized selftest from '+str(binary)+'\n');result=subprocess.CompletedProcess([],0)
    else:
        result=subprocess.run(['swiftc','-swift-version','6','-parse-as-library',*optimization,'-module-name','NormieMotionCheck','-D',flag,*files,'-o',str(binary)],cwd=root,stdout=log,stderr=subprocess.STDOUT)
        if result.returncode==0:build_input.write_text(input_text)
if result.returncode:
    print((out/'compile.log').read_text()[-18000:]);raise SystemExit(result.returncode)
env=os.environ.copy()
if a.probe:env['NORMIE_STACK_PROBE']='1'
if a.handoff_probe:env['NORMIE_HANDOFF_PROBE']='1'
if a.alpha_probe:env['NORMIE_ALPHA_PROBE']='1'
if a.startup_probe:env['NORMIE_STARTUP_PROBE']='1'
if a.region_probe:env['NORMIE_INK_REGION_PROBE']='1'
env['NORMIE_CHECK_CONFIGURATION']=a.configuration
with (out/'run.log').open('w') as log:
    process=subprocess.Popen([str(binary),str(out)],cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    for line in process.stdout:
        print(line,end='',flush=True);log.write(line)
    result=process.wait()
raise SystemExit(result)
