#!/usr/bin/env python3
"""Offscreen checks in a full HEAD export; only changed Settings files are overlaid. Retains incremental debug objects."""
from pathlib import Path
import argparse, hashlib, io, json, os, shutil, subprocess, tarfile


def extract(repo, ref, target, paths=()):
    archive=subprocess.check_output(['git','archive',ref,*paths],cwd=repo)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            destination=(target/member.name).resolve()
            if not destination.is_relative_to(target.resolve()) or member.issym() or member.islnk():
                raise ValueError('Unsafe archive')
        tar.extractall(target)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('suite',choices=['all','settings','native','overlay'],nargs='?',default='settings')
    p.add_argument('--baseline',default='HEAD')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--reuse',action='store_true',help='Reuse the pinned export and incremental build directory')
    p.add_argument('--reference',type=Path)
    p.add_argument('--reference-2x',type=Path)
    p.add_argument('--appearance-reference',type=Path)
    p.add_argument('--before',type=Path)
    p.add_argument('--settings-baseline',help='Read-only baseline render, without worktree overlays')
    a=p.parse_args();repo=Path(__file__).resolve().parents[3];out=a.output.resolve()
    if out==repo or out.is_relative_to(repo):p.error('Use an output outside the shared repository.')
    out.mkdir(parents=True,exist_ok=True);frozen=out/'source';pin=out/'baseline.json'
    if frozen.exists() and not a.reuse:p.error('Use --reuse for the existing private export.')
    if pin.exists():
        head=json.loads(pin.read_text())['commit']
    else:
        head=subprocess.check_output(['git','rev-parse',a.baseline],cwd=repo,text=True).strip()
        extract(repo,head,frozen);pin.write_text(json.dumps({'commit':head})+'\n')
    base=frozen/'Sources/OrganicShell'
    # No current Native / Core / Overlay / Engine files enter the export. Other writers may be mid-edit.
    previous=json.loads((out/'source-manifest.json').read_text()).get('overlays',[]) if (out/'source-manifest.json').exists() else []
    for name in previous:
        destination=frozen/name
        original=subprocess.run(['git','show',head+':'+name],cwd=repo,capture_output=True)
        if original.returncode == 0:destination.write_bytes(original.stdout)
        else:destination.unlink(missing_ok=True)
    changed=[]
    if a.settings_baseline:
        extract(repo,a.settings_baseline,frozen,['Sources/OrganicShell/Settings'])
    else:
        tracked=subprocess.check_output(['git','diff','--name-only',head,'--','Sources/OrganicShell/Settings'],cwd=repo,text=True).splitlines()
        untracked=subprocess.check_output(['git','ls-files','--others','--exclude-standard','--','Sources/OrganicShell/Settings'],cwd=repo,text=True).splitlines()
        for name in sorted(set(tracked+untracked)):
            source=repo/name;destination=frozen/name
            if source.is_file():destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,destination)
            else:destination.unlink(missing_ok=True)
            changed.append(name)
    manifest={str(f.relative_to(frozen)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(base.rglob('*.swift'))}
    (out/'source-manifest.json').write_text(json.dumps({'commit':head,'overlays':changed,'files':manifest},indent=2)+'\n')
    env=dict(os.environ);env['SETTINGS_PARITY_REFERENCE']=str((a.reference or repo/'runs/parity-settings-all').resolve())
    env['SETTINGS_M9C_REFERENCE']=str((a.reference_2x or repo/'runs/parity-settings-m9c2-044931').resolve())
    env['SETTINGS_TEXT_APPEARANCE_REFERENCE']=str((a.appearance_reference or repo/'runs/parity-m9ef-105708').resolve())
    if a.before:env['SETTINGS_M9C_BASELINE']=str(a.before.resolve())
    suites=['settings','native','overlay'] if a.suite=='all' else [a.suite]
    failed=[];results={}
    for suite in suites:
        groups={'settings':['Core','Native','Settings'],'native':['Core','Native'],'overlay':['Engine','Core','Native','Overlay']}[suite]
        files=[f for group in groups for f in sorted((base/group).glob('*.swift')) if f.name!='CoreSettingsController.swift' or suite=='settings']
        flags={'settings':'SETTINGS','native':'M1','overlay':'OVERLAY'}
        build=out/'build'/suite;build.mkdir(parents=True,exist_ok=True)
        output_map={'':{'swift-dependencies':str(build/'master.swiftdeps')}}
        for f in files:
            stem=f.parent.name+'-'+f.stem
            output_map[str(f)]={'object':str(build/(stem+'.o')),'swift-dependencies':str(build/(stem+'.swiftdeps')),'dependencies':str(build/(stem+'.d'))}
        mapping=build/'output-file-map.json';mapping.write_text(json.dumps(output_map,indent=2))
        binary=out/(suite+'-selftest');log=out/(suite+'-compile.log');result=out/suite;result.mkdir(exist_ok=True)
        command=['swiftc','-swift-version','6','-Onone','-g','-incremental','-enable-batch-mode','-j','4','-module-name',suite.title()+'Selftest','-output-file-map',str(mapping),'-module-cache-path',str(out/'build/module-cache'),'-D',flags[suite]+'_SELFTEST','-target','arm64-apple-macosx26.0',*map(str,files),'-o',str(binary)]
        with log.open('w') as h:r=subprocess.run(command,cwd=frozen,stdout=h,stderr=subprocess.STDOUT)
        if r.returncode:
            errors=[line for line in log.read_text().splitlines() if 'error:' in line];print('\n'.join(errors[-30:]),flush=True);failed.append(suite);results[suite]={'compile':r.returncode};continue
        with (out/(suite+'-run.log')).open('w') as h:r=subprocess.run([str(binary),str(result)],cwd=frozen,env=env,stdout=h,stderr=subprocess.STDOUT)
        print((out/(suite+'-run.log')).read_text()[-12000:],flush=True)
        results[suite]={'compile':0,'run':r.returncode}
        if r.returncode:failed.append(suite)
    if 'settings' in suites and (out/'settings/m9/m9c-measurements.json').exists():
        metrics=json.loads((out/'settings/m9/m9c-measurements.json').read_text())
        table=['# Offscreen Settings text parity','',
               'Mean absolute sRGB channel error (%), against fixed original 2× product PNGs. Content: x≥220pt, y≥52pt. This is not the real-window red-difference percentage.','',
               '| Pane | Body before | Body after | Sidebar before | Sidebar after |','| --- | ---: | ---: | ---: | ---: |']
        for pane,m in metrics['panes'].items():
            numbers=[f"{m[k]:.4f}" if k in m else '—' for k in ['before','after','sidebarBefore','sidebarAfter']]
            table.append('| '+pane+' | '+' | '.join(numbers)+' |')
        table+=['','The same directory contains settings-<pane>-m9c-comparison@2x.png (v2 | product) and text-measurements.json (individual translations and glyph bounds).']
        (out/'settings/m9/text-summary.md').write_text('\n'.join(table)+'\n')
    (out/'suite-status.json').write_text(json.dumps(results,indent=2)+'\n')
    print('Frozen HEAD:',head,'\nSettings overlays:',*changed,'\nReports:',out,sep='\n',flush=True)
    if failed:raise SystemExit('Failed suites: '+', '.join(failed))
if __name__=='__main__':main()
