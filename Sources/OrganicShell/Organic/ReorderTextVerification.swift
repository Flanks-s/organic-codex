#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

extension M10DockVerification {
    /// Render each column independently at the same scene timestamp. A bright foreground pixel
    /// (> 72/255 over a cleared black camera) is a conservative readable-ink mask.
    /// Two such masks must never share a pixel. Plates count too, making this stricter than OCR.
    static func reorderText(output:URL) throws {
        var records=[[String:Any]]()
        for name in ["slow-drop","rapid-drop","slow-escape","rapid-escape"] where ProcessInfo.processInfo.environment["M1111_TEXT_CASE"].map({$0 == name}) ?? true {
            let f=HeaderFixture(scale:1);defer{f.dispose()}
            f.scene.restOnSnapshot=true
            for c in f.scene.columns {c.restOnSnapshot=true;c.showRest(full:c.isFull)}
            let canvas=CALayer(),renderer=OffscreenRenderer(size:f.scene.size,host:canvas)
            var cameras=[String:(CALayer,OffscreenRenderer)]()
            let frameDir=output.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:frameDir,withIntermediateDirectories:true)
            func camera(_ id:String)->(CALayer,OffscreenRenderer) {
                if let found=cameras[id] {return found}
                let root=CALayer()
                root.backgroundColor=NSColor.black.cgColor
                let r=OffscreenRenderer(size:f.scene.size,host:root)
                cameras[id]=(root,r);return (root,r)
            }
            let id=f.scene.columns[0].conversation.id,r=f.scene.dock.items[id]!.glass.frame
            let down=CGPoint(x:r.midX,y:r.minY)
            check(f.scene.pointerDown(down),"\(name) original bar press")
            f.scene.pointerDragged(CGPoint(x:down.x+8,y:down.y))
            var maximum=0,badFrames=0,frames=0,sheet=[CGImage](),badIndices=[Int]()
            var rows="frame,overlap,rects\n"
            func sample() {
                f.tick()
                let columns=f.scene.columns + Array(f.scene.leaving.values)
                var masks=[[UInt8]]()
                for c in columns {
                    let (root,r)=camera(c.conversation.id)
                    CATransaction.begin();CATransaction.setDisableActions(true)
                    if c.card.superlayer !== root {root.addSublayer(c.card)}
                    for n in f.scene.flights[c.conversation.id] ?? [] {if n.replicator.superlayer !== root {root.addSublayer(n.replicator)}}
                    if let island=c.island,!island.isHiddenOrHasHiddenAncestor {
                        check(island.motionGlyphMaterial.alphaValue==1,"\(name) reorder preserves capsule title opacity at frame \(frames)")
                        check(island.eventButton.isHidden || island.eventButton.alphaValue==1,"\(name) reorder preserves capsule event opacity at frame \(frames)")
                        // Header captions are intentionally outside the transcript readability mask.
                        // Visible steady captions must retain their opacity throughout a crossing; hidden activity has no ink.
                        if frames%18==0 {
                            Offscreen.write(island.snapshot(scale:1),output.appendingPathComponent("\(name)-title-\(c.conversation.id)-\(frames).png"))
                        }
                    }
                    CATransaction.commit()
                    masks.append(r.render(at:f.time))
                }
                var overlap=0
                for y in 0..<min(renderer.h,650) {for x in 0..<renderer.w {
                    let p=(y*renderer.w+x)*4
                    let readable=masks.filter{max($0[p],$0[p+1],$0[p+2])>72 && $0[p+3]>46}.count
                    if readable>1 {overlap+=1}
                }}
                func composite()->[UInt8] {
                    let context=CGContext(data:nil,width:renderer.w,height:renderer.h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.setFillColor(Look.canvas.cgColor);context.fill(CGRect(x:0,y:0,width:renderer.w,height:renderer.h))
                    context.setBlendMode(.screen)
                    for mask in masks {context.draw(renderer.image(mask),in:CGRect(x:0,y:0,width:renderer.w,height:renderer.h))}
                    let result=context.makeImage()!
                    // Convert the CGContext result to the renderer's BGRA contract.
                    let data=CGContext(data:nil,width:renderer.w,height:renderer.h,bitsPerComponent:8,bytesPerRow:renderer.w*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                    data.draw(result,in:CGRect(x:0,y:0,width:renderer.w,height:renderer.h))
                    return Array(UnsafeBufferPointer(start:data.data!.assumingMemoryBound(to:UInt8.self),count:renderer.w*renderer.h*4))
                }
                let pixels=composite()
                renderer.write(pixels,frameDir.appendingPathComponent(String(format:"%03d.png",frames)))
                if overlap>maximum || frames%18==0 {
                    if overlap>maximum {renderer.write(pixels,output.appendingPathComponent("\(name)-worst.png"))}
                    if frames%18==0 {sheet.append(renderer.image(pixels))}
                }
                rows += "\(frames),\(overlap),\(columns.map{NSStringFromRect($0.rect.sample(max(0,f.time-f.scene.began)).rect)}.joined(separator:";"))\n"
                maximum=max(maximum,overlap);if overlap>0 {badFrames+=1;badIndices.append(frames)};frames+=1
            }
            let rapid=name.hasPrefix("rapid"),count=rapid ? 48:72
            for k in 0...count {
                let u=Double(k)/Double(count)
                let q=rapid ? (sin(u * .pi * 6 - .pi/2)+1)/2:u
                f.scene.pointerDragged(CGPoint(x:down.x+8+(880-down.x-8)*q,y:down.y));sample()
            }
            if name.hasSuffix("escape") {f.scene.cancelDrag()}
            else {_=f.scene.pointerUp(CGPoint(x:880,y:down.y))}
            for _ in 0..<80 {sample()}
            f.scene.settle();sample()
            check(maximum==0,"\(name) readable foreground overlap: \(maximum) pixels in \(badFrames)/\(frames) frames")
            try rows.write(to:output.appendingPathComponent("\(name)-frames.csv"),atomically:true,encoding:.utf8)
            Offscreen.sheet(sheet,to:output.appendingPathComponent("\(name)-sheet.png"))
            records.append(["case":name,"frames":frames,"overlapFrames":badFrames,"maxOverlapPixels":maximum,"badIndices":badIndices])
        }
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("reorder-text.json"))
    }
}
#endif
