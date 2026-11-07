#!/usr/bin/env python3
"""M10-F: immutable inputs, offscreen only; no App/Main, network transport or real backend."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,default=Path('runs/m10-draft-subagent'))
p.add_argument('--suite',choices=['motion','sheets','orb','organic'],default='motion')
p.add_argument('--baseline-ref',default='f760de9',help='Committed pre-M10-F Orb endpoint baseline (read only)')
p.add_argument('--input-root',type=Path,help='Optional immutable source tree for regression isolation; never edited')
p.add_argument('--disable-f',action='store_true',help='Diagnostic only: disable just F exposure in the copied inputs')
a=p.parse_args()
repo=Path(__file__).resolve().parents[3]
out=(repo/a.output).resolve();out.mkdir(parents=True,exist_ok=True)
owned=[]
def run(command,**kwargs):
    child=subprocess.Popen(command,**kwargs)
    entry={'pid':child.pid,'command':command};owned.append(entry)
    try:
        code=child.wait();entry['exitCode']=code
        return subprocess.CompletedProcess(command,code)
    finally:
        if child.poll() is None:
            child.terminate();child.wait();entry['terminatedByPID']=child.pid
        (out/(a.suite+'-processes.json')).write_text(json.dumps(owned,indent=2)+'\n')
source=a.input_root.resolve() if a.input_root else repo/'Sources/OrganicShell';inputs=out/('inputs-'+a.suite)
if a.suite=='orb':
    baseline=out/'inputs-orb-m9';baseline_files=[]
    names=subprocess.check_output(['git','ls-tree','-r','--name-only',a.baseline_ref,'--','Sources/OrganicShell/Orb','Sources/OrganicShell/Engine'],cwd=repo,text=True).splitlines()
    baseline_hashes={}
    for name in names:
        if not name.endswith('.swift'):continue
        data=subprocess.check_output(['git','show',a.baseline_ref+':'+name],cwd=repo)
        dest=baseline/Path(name).relative_to('Sources/OrganicShell');dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
        baseline_files.append(str(dest));baseline_hashes[name]=hashlib.sha256(data).hexdigest()
    (out/'orb-m9-baseline.json').write_text(json.dumps({'ref':a.baseline_ref,'files':baseline_hashes},indent=2)+'\n')
    binary=out/'orb-m9-check'
    with (out/'orb-m9-compile.log').open('w') as log:
        result=run(['swiftc','-swift-version','6','-O','-whole-module-optimization','-D','ORB_SELFTEST','-target','arm64-apple-macosx26.0',*baseline_files,'-o',str(binary)],cwd=repo,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode:
        print((out/'orb-m9-compile.log').read_text()[-10000:]);raise SystemExit(result.returncode)
    result=run([str(binary),str(out/'m9-orb')],cwd=repo)
    if result.returncode:raise SystemExit(result.returncode)
groups=['Core','Native','Orb','Tools','Normie','Island','Overlay','Sheets','Engine','Organic']
if a.suite=='orb':groups=['Orb','Engine']
files=[];hashes={}
paths=[f for g in groups for f in sorted((source/g).glob('*.swift')) if f.name!='CoreSettingsController.swift']
if a.suite!='orb':paths += [source/'App/SelfTest.swift',source/'App/Offscreen.swift']
for f in paths:
    rel=f.relative_to(source);data=f.read_bytes()
    if a.disable_f and str(rel) in ['Orb/OrbComponent.swift','Organic/DraftColumn.swift','Sheets/SheetMotion.swift','Sheets/SheetToasts.swift']:
        data,count=re.subn(rb'(var exposureEnabled\s*=\s*)true',rb'\g<1>false',data,count=1)
        if count != 1:raise SystemExit('Missing diagnostic exposure switch: '+str(rel))
    dest=inputs/rel;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
    files.append(str(dest));hashes[str(rel)]=hashlib.sha256(data).hexdigest()
(out/(a.suite+'-inputs.json')).write_text(json.dumps(hashes,indent=2)+'\n')
flag={'motion':'M10_F','sheets':'SHEETS','orb':'ORB','organic':'ORGANIC'}[a.suite]
binary=out/(a.suite+'-check')
command=['swiftc','-swift-version','6','-O','-whole-module-optimization','-D',flag+'_SELFTEST','-target','arm64-apple-macosx26.0',*files,'-o',str(binary)]
with (out/(a.suite+'-compile.log')).open('w') as log:
    result=run(command,cwd=repo,stdout=log,stderr=subprocess.STDOUT)
if result.returncode:
    print((out/(a.suite+'-compile.log')).read_text()[-12000:]);raise SystemExit(result.returncode)
result=run([str(binary),str(out)],cwd=repo)
raise SystemExit(result.returncode)
