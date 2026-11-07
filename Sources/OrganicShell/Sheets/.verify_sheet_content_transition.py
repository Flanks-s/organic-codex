#!/usr/bin/env python3
"""Windowless M10.1-F checks. Read only an explicit private HEAD archive, keep incremental debug objects."""
from pathlib import Path
import argparse,subprocess,json,hashlib,os
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--build',type=Path,required=True)
p.add_argument('--output',type=Path,default=Path('runs/m10.1-sheets'))
p.add_argument('--suite',choices=['gaussian','sheets','switches'],default='gaussian')
p.add_argument('--timing',action='store_true',help='One optimized WMO build, only after debug functional checks')
a=p.parse_args();root=a.source.resolve();src=root/'Sources/OrganicShell';out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
build=a.build.resolve()/((a.suite if a.suite!='switches' else 'gaussian')+('-timing' if a.timing else '-debug'));build.mkdir(parents=True,exist_ok=True)
files=[str(f) for g in ['Core','Native','Orb','Tools','Normie','Island','Overlay','Sheets','Engine','Organic'] for f in sorted((src/g).glob('*.swift')) if f.name!='CoreSettingsController.swift']
files += [str(src/'App'/f) for f in ['SelfTest.swift','Offscreen.swift']]+[str(src/'Debug/ModeSignposts.swift')]
flag='SHEETS_SELFTEST' if a.suite=='sheets' else 'SHEETS_M101_SELFTEST';module='M101SheetsCheck'
inputs=json.dumps({str(Path(f).relative_to(root)):hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files},indent=2)
tag=a.suite+('-timing' if a.timing else '-debug');(out/(tag+'-inputs.json')).write_text(inputs)
processes=[]
def run(cmd,log,env=None):
 with log.open('w') as h:
  child=subprocess.Popen(cmd,stdout=h,stderr=subprocess.STDOUT,env=env);entry={'pid':child.pid,'command':cmd};processes.append(entry)
  try:entry['exitCode']=child.wait()
  finally:
   if child.poll() is None:child.terminate();child.wait()
   (out/(tag+'-processes.json')).write_text(json.dumps(processes,indent=2))
 if entry['exitCode']:
  print(log.read_text()[-12000:]);raise SystemExit(entry['exitCode'])
if a.timing:
 run(['swiftc','-swift-version','6','-parse-as-library','-O','-whole-module-optimization','-module-name',module,'-D',flag,*files,'-o',str(build/'verify')],out/(tag+'-compile.log'))
else:
 mapping={'':{'swift-dependencies':str(build/'master.swiftdeps')}}
 for f in files:
  b=build/(Path(f).parent.name+'-'+Path(f).stem);mapping[f]={'object':str(b)+'.o','swift-dependencies':str(b)+'.swiftdeps','dependencies':str(b)+'.d'}
 m=build/'outputs.json';value=json.dumps(mapping,sort_keys=True)
 if not m.exists() or m.read_text()!=value:m.write_text(value)
 run(['swiftc','-swift-version','6','-parse-as-library','-Onone','-incremental','-enable-batch-mode','-j','4','-module-name',module,'-D',flag,'-output-file-map',str(m),*files,'-o',str(build/'verify')],out/(tag+'-compile.log'))
 # Only the expensive verifier/Metal pixel routines and the matte/crop helper get per-primary-file -O.
 # All other production objects remain debug; this is not a release/WMO cost claim.
 stamp=build/'optimized-pixels-v2.json'
 if not stamp.exists() or stamp.read_text()!=inputs:
  sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
  for name in ['SelfTest.swift','SheetContentTransition.swift','SheetsVerification.swift' if a.suite=='sheets' else 'SheetGaussianVerification.swift']:
   primary=next(f for f in files if Path(f).name==name)
   run(['swiftc','-frontend','-c','-sdk',sdk,'-parse-as-library','-swift-version','6','-O','-module-name',module,'-D',flag,'-primary-file',primary,*[f for f in files if f!=primary],'-o',mapping[primary]['object']],out/(tag+'-'+name+'.log'))
  stamp.write_text(inputs)
 run(['swiftc',*[mapping[f]['object'] for f in files],'-o',str(build/'verify')],out/(tag+'-link.log'))
if a.suite=='switches':
 for i,values in enumerate([{}, {'M10_SHEET_ZOOM':'gauss'}, {'M10_SHEET_ZOOM':'accum'}, {'M10_SHEET_ZOOM':'invalid'}, {'M10_SHEET_ZOOM':'gauss','M10_DRAFT_EXPOSURE':'0'}, {'M10_SHEET_ZOOM':'accum','M10_DRAFT_EXPOSURE':'0'}]):
  environment=os.environ.copy();environment.pop('M10_SHEET_ZOOM',None);environment.pop('M10_DRAFT_EXPOSURE',None);environment.update(values)
  log=out/(tag+str(i)+'-run.log');run([str(build/'verify'),str(out),tag],log,env=environment);print(log.read_text())
else:
 run([str(build/'verify'),str(out),tag],out/(tag+'-run.log'));print((out/(tag+'-run.log')).read_text()[-10000:])
