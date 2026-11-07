#!/usr/bin/env python3
"""M10.1 static pixels, isolated inputs and retained debug objects. Never launches an App."""
from pathlib import Path
import argparse,subprocess,json,hashlib,os
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--build',type=Path,default=Path('/tmp/sol-m101-overlay-static-build'))
p.add_argument('--output',type=Path,default=Path('runs/m10.1-overlay/static'))
a=p.parse_args();root=a.source.resolve();build=a.build.resolve();out=a.output.resolve();src=root/'Sources/OrganicShell'
build.mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
probe = r'''
import AppKit
@main @MainActor enum Probe {
 static func pixels(_ url:URL)->[UInt8] {
  let image=NSBitmapImageRep(data:try! Data(contentsOf:url))!.cgImage!
  let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
  return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
 }
 static func main() throws {
  #if M101_CURRENT
  if CommandLine.arguments[1] == "switches" {
   let value:[String:Any] = ["mode":OverlayZoom.selected.rawValue,"enabled":OverlayExposure.enabled,"gaussian":OverlayZoom.gaussian(reduceMotion:false),"reduced":OverlayZoom.gaussian(reduceMotion:true)]
   print(String(data:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),encoding:.utf8)!);return
  }
  #endif
  if CommandLine.arguments[1] == "compare" {
   let a=URL(fileURLWithPath:CommandLine.arguments[2]),b=URL(fileURLWithPath:CommandLine.arguments[3])
   var rows:[[String:Any]]=[]
   for url in try FileManager.default.contentsOfDirectory(at:a,includingPropertiesForKeys:nil).filter({$0.pathExtension=="png"}).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
    let x=pixels(url),y=pixels(b.appendingPathComponent(url.lastPathComponent));var count=0,peak=0
    for i in x.indices {let d=abs(Int(x[i])-Int(y[i]));if d>0{count+=1;peak=max(peak,d)}}
    rows.append(["image":url.lastPathComponent,"changedBytes":count,"maxDelta":peak])
   }
   try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[4]));return
  }
  _=NSApplication.shared;NSApp.appearance=NSAppearance(named:.darkAqua)
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let host=OverlayView(frame:CGRect(x:0,y:0,width:1080,height:900)),clock=OverlayManualClock()
  func rest(_ view:NSView) { view.layer?.removeAllAnimations();view.subviews.forEach(rest) }
  func save(_ view:NSView,_ name:String)throws {
   view.layoutSubtreeIfNeeded();clock.advance(by:3);rest(view)
   func walk(_ v:NSView)->[[String:String]] { [["type":String(describing:type(of:v)),"frame":NSStringFromRect(v.frame),"bounds":NSStringFromRect(v.bounds),"layerTransform":String(describing:v.layer?.transform),"shadow":String(describing:v.layer?.shadowPath),"clip":String(describing:v.layer?.masksToBounds)]]+v.subviews.flatMap(walk) }
   try JSONSerialization.data(withJSONObject:walk(view),options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent(name+"-geometry.json"))
   for scale:CGFloat in [1,2] {let image=NativeViewBitmap.capture(view,scale:scale);try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("\(name)-\(Int(scale))x.png"))}
  }
  var settings=ModelSettings();settings.modelID="g61sol";settings.effort = .ultra;settings.speed = .ultrafast
  let picker=OverlayModelPicker(clock:clock);picker.configure(settings:settings,models:ModelCatalog.mockModels)
  let anchor=CGRect(x:650,y:830,width:158,height:28);picker.present(anchor:anchor,in:host);picker.reasoning.stopAmbient()
  try save(picker,"picker-ultra");_=picker.selectModel(ModelCatalog.mockModels.first!.id);picker.reasoning.stopAmbient();try save(picker,"picker-other")
  picker.dismiss();clock.advance(by:3)
  let send=OverlaySendOptions(clock:clock);send.present(anchor:anchor,in:host);try save(send,"send-steer")
  _=send.handleKey(.up);try save(send,"send-queue");send.dismiss();clock.advance(by:3)
  assert(NSApp.windows.allSatisfy{!$0.isVisible})
 }
}
'''
probeFile=build/'Probe.swift'
if not probeFile.exists() or probeFile.read_text()!=probe:probeFile.write_text(probe)
# Baseline commit was captured BEFORE exporting HEAD at the start of this task.
repo=Path(__file__).resolve().parents[3]
commit='713156bbe2295a92f0851cbabed86316d4e3d37a'
baseline=build/'baseline-source';baseline.mkdir(exist_ok=True)
for name in subprocess.check_output(['git','ls-tree','-r','--name-only',commit,'--','Sources/OrganicShell/Overlay'],cwd=repo,text=True).splitlines():
 if name.endswith('.swift'):
  f=baseline/Path(name).name;data=subprocess.check_output(['git','show',commit+':'+name],cwd=repo)
  if not f.exists() or f.read_bytes()!=data:f.write_bytes(data)
deps=[str(f) for group in ['Engine','Core','Native'] for f in sorted((src/group).glob('*.swift')) if f.name!='CoreSettingsController.swift']
for label,overlay in [('baseline',baseline),('current',src/'Overlay')]:
 folder=build/label;folder.mkdir(exist_ok=True)
 files=deps+[str(f) for f in sorted(overlay.glob('*.swift'))]+[str(probeFile)]
 fm={'':{'swift-dependencies':str(folder/'master.swiftdeps')}}
 for f in files:
  n=folder/(Path(f).parent.name+'-'+Path(f).stem);fm[f]={'object':str(n)+'.o','swift-dependencies':str(n)+'.swiftdeps','dependencies':str(n)+'.d'}
 m=folder/'outputs.json';value=json.dumps(fm,sort_keys=True)
 if not m.exists() or m.read_text()!=value:m.write_text(value)
 with (out/(label+'-compile.log')).open('w') as log:r=subprocess.run(['swiftc','-swift-version','6','-Onone','-incremental','-enable-batch-mode','-j','4',*(['-D','M101_CURRENT'] if label=='current' else []),'-parse-as-library','-output-file-map',str(m),*files,'-o',str(folder/'verify')],stdout=log,stderr=subprocess.STDOUT)
 if r.returncode:print((out/(label+'-compile.log')).read_text()[-10000:]);raise SystemExit(r.returncode)
 subprocess.run([str(folder/'verify'),str(out/label)],check=True)
 if label=='current':subprocess.run([str(folder/'verify'),str(out/'disabled')],env=dict(os.environ,OVERLAY_EXPOSURE='0'),check=True)
for name,x,y in [('head','baseline','current'),('switch','disabled','current')]:
 path=out/(name+'-diff.json')
 subprocess.run([str(build/'current/verify'),'compare',str(out/x),str(out/y),str(path)],check=True)
 rows=json.loads(path.read_text());print(name,'images',len(rows),'changedBytes',sum(r['changedBytes'] for r in rows),'maxDelta',max(r['maxDelta'] for r in rows))
 if any(r['changedBytes'] for r in rows):raise SystemExit(1)
(out/'baseline-source.json').write_text(json.dumps({'commit':commit,'dependencies':'same private HEAD Engine/Core/Native'},indent=2))

# Separate processes exercise the actual environment parser; no verification override or App launch.
results=[]
for mode,enabled in [(None,None),('invalid',None),('accum',None),('gauss',None),('gauss','0'),('accum','0')]:
 env={k:v for k,v in os.environ.items() if k not in ['OVERLAY_ZOOM','OVERLAY_EXPOSURE']}
 if mode is not None:env['OVERLAY_ZOOM']=mode
 if enabled is not None:env['OVERLAY_EXPOSURE']=enabled
 value=json.loads(subprocess.check_output([str(build/'current/verify'),'switches'],env=env,text=True))
 expected='gauss' if mode=='gauss' else 'accum'
 assert value=={'mode':expected,'enabled':enabled!='0','gaussian':expected=='gauss' and enabled!='0','reduced':False},value
 results.append({'requested':mode,'exposure':enabled,'actual':value})
(out/'switch-parser.json').write_text(json.dumps(results,indent=2))
print('switch parser: 6 processes, 0 findings')
