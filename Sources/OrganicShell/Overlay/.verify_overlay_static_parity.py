#!/usr/bin/env python3
"""Compare settled native pixels to the last committed Overlay, with identical current Core/Native dependencies."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil

repo = Path(__file__).resolve().parents[3]
BASELINE = '9dd9614610f3cc3995614b08333242386bb96c92'  # M9 Overlay; never compare a future M10 commit to itself.
output = repo / 'runs/m10-overlay/static'
output.mkdir(parents=True, exist_ok=True)
(output / 'baseline-source.json').write_text(json.dumps({'commit': BASELINE, 'scope':'committed Overlay vs working Overlay, identical frozen Core/Native/Engine'},indent=2)+'\n')
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
with tempfile.TemporaryDirectory(prefix='sol-m10-overlay-static-') as tmp:
    tmp = Path(tmp)
    swift = tmp / 'Probe.swift'
    swift.write_text(probe)
    committed = tmp / 'Overlay'
    committed.mkdir()
    names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', BASELINE, '--', 'Sources/OrganicShell/Overlay'], cwd=repo, text=True).splitlines()
    for name in names:
        if name.endswith('.swift'):
            (committed / Path(name).name).write_bytes(subprocess.check_output(['git', 'show', BASELINE + ':' + name], cwd=repo))
    source = repo / 'Sources/OrganicShell'
    frozen = tmp / 'current'
    frozen.mkdir()
    deps = []
    for group in ['Engine', 'Core', 'Native', 'Overlay']:
        folder = frozen / group
        folder.mkdir()
        for p in sorted((source/group).glob('*.swift')):
            if p.name != 'CoreSettingsController.swift':
                q = folder / p.name
                shutil.copy2(p, q)
                if group != 'Overlay':
                    deps.append(str(q))
    for label, overlay in [('baseline', committed), ('current', frozen/'Overlay')]:
        binary = tmp / (label + '-probe')
        with (output / (label+'-compile.log')).open('w') as log:
            subprocess.run(['swiftc', '-swift-version', '6', '-O', '-parse-as-library', *deps,
                            *map(str, sorted(overlay.glob('*.swift'))), str(swift), '-o', str(binary)],
                           cwd=repo, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run([str(binary), str(output/label)], cwd=repo, check=True)
        if label == 'current':
            subprocess.run([str(binary), str(output/'disabled')], cwd=repo, env=dict(os.environ, OVERLAY_EXPOSURE='0'), check=True)
    for name, a, b in [('m9', 'baseline', 'current'), ('switch', 'disabled', 'current')]:
        result = output/(name+'-diff.json')
        subprocess.run([str(binary), 'compare', str(output/a), str(output/b), str(result)], check=True)
        rows = json.loads(result.read_text())
        print(name, 'images', len(rows), 'changedBytes', sum(r['changedBytes'] for r in rows), 'maxDelta', max(r['maxDelta'] for r in rows))
        if any(r['changedBytes'] for r in rows):
            raise SystemExit(1)
