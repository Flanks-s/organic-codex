import AppKit
import QuartzCore

/// Exercise the filter attached by HeaderIsland with CA's renderer, independently of cacheDisplay.
@MainActor enum IslandEventRenderingVerification {
    static func run(to output:URL,check:(Bool,String)->Void) {
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var records=[[String:Any]]()
        for scale:CGFloat in [1,2] {
            let header=HeaderIsland(),root=IslandPlane(frame:CGRect(x:0,y:0,width:400,height:300))
            root.addSubview(header)
            var time=CACurrentMediaTime()+3600
            header.now={time};header.motionExposure.enabled=false
            header.configure(.init(id:"render-phase",title:"Filter rendering",columnWidth:400,band:44,ambient:false,scale:scale))
            header.receive(.init(kind:.approval,text:"1 approval needs you",at:time),at:time)
            let began=time,layer=header.eventButton.layer!,size=layer.bounds.size
            // A fixed edge isolates blur from opacity, translation, text rasterization and the live mask.
            let w=Int(size.width*scale),h=Int(size.height*scale),edge=w/2
            let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                                  space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x:edge,y:0,width:w-edge,height:h))
            let probe=context.makeImage()!
            let host=CALayer(),renderer=OffscreenRenderer(size:size,host:host,scale:scale)
            host.backgroundColor=NSColor.black.cgColor;host.addSublayer(layer)
            var errors=[Double](),last=[UInt8]()
            for (index,dt) in [0.08,0.095,0.11,0.125,0.14,0.155,0.169999,0.18].enumerated() {
                time=began+dt;header.sampleMotion(at:time)
                CATransaction.begin();CATransaction.setDisableActions(true)
                layer.frame=CGRect(origin:.zero,size:size);layer.opacity=1;layer.mask=nil
                layer.sublayers?.forEach{$0.isHidden=true};layer.contents=probe;layer.contentsScale=scale
                CATransaction.commit()
                let pixels=renderer.render(at:time)
                var error=0.0
                for y in (h/3)..<(2*h/3) {for x in (edge-Int(8*scale))..<(edge+Int(8*scale)) {
                    error+=abs(Double(pixels[(y*w+x)*4])-(x<edge ? 0:255))
                }}
                error /= Double(max(1,h/3))*Double(scale)
                if let previous=errors.last {check(error<=previous+0.01,"M11.21 rendered blur decreases @\(scale)x sample \(index): \(previous) -> \(error)")}
                errors.append(error);last=pixels
                records.append(["scale":scale,"time":dt,"edgeError":error])
                renderer.write(pixels,output.appendingPathComponent("edge-\(index)@\(Int(scale))x.png"))
            }
            check(errors.first!>20,"M11.21 renderer actually sees the initial blur @\(scale)x")
            check(zip(errors,errors.dropFirst()).filter{$0.0-$0.1>0.1}.count>=3,"M11.21 rendered blur has multiple decreasing samples @\(scale)x")
            check(errors[errors.count-2]<1,"M11.21 final filtered sample is sharp before teardown @\(scale)x")
            check(header.eventButton.layer?.filters?.isEmpty != false,"M11.21 endpoint removes its filter @\(scale)x")
            // Reinstall the same CA filter at zero, then disable/remove it: no raster or pixel change.
            let zero=OverlayFilter.make("gaussianBlur",values:["name":"zeroProbe","inputRadius":0,"enabled":true])!
            layer.filters=[zero];let zeroPixels=renderer.render(at:time+0.01)
            layer.setValue(false,forKeyPath:"filters.zeroProbe.enabled");let disabled=renderer.render(at:time+0.02)
            layer.filters=nil;let removed=renderer.render(at:time+0.03)
            check(last==zeroPixels && zeroPixels==disabled && disabled==removed,"M11.21 zero/disabled/removed filter pixels are identical @\(scale)x")
            // The button's backing layer is attached to CARenderer now, so cacheDisplay would
            // capture an empty AppKit backing. Draw its actual native ink into an independent input.
            context.clear(CGRect(x:0,y:0,width:w,height:h));context.saveGState()
            context.translateBy(x:0,y:CGFloat(h));context.scaleBy(x:scale,y:-scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
            header.eventButton.draw(header.eventButton.bounds)
            NSGraphicsContext.restoreGraphicsState();context.restoreGState()
            let ink=context.makeImage()!
            layer.contents=ink
            let sharpInk=renderer.render(at:time+0.04)
            layer.filters=[zero];layer.setValue(true,forKeyPath:"filters.zeroProbe.enabled")
            let filteredInk=renderer.render(at:time+0.05)
            layer.setValue(false,forKeyPath:"filters.zeroProbe.enabled")
            let disabledInk=renderer.render(at:time+0.06)
            layer.filters=nil;let removedInk=renderer.render(at:time+0.07)
            check(stride(from:0,to:sharpInk.count,by:4).filter{max(sharpInk[$0],sharpInk[$0+1],sharpInk[$0+2])>16}.count>20,"M11.21 teardown probe contains native text @\(scale)x")
            check(sharpInk==filteredInk && filteredInk==disabledInk && disabledInk==removedInk,"M11.21 native text zero/disabled/removed filter pixels are identical @\(scale)x")
            renderer.write(removedInk,output.appendingPathComponent("text-endpoint@\(Int(scale))x.png"))
            layer.removeFromSuperlayer();header.dispose();withExtendedLifetime(root){}
        }
        try? JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("blur-pixels.json"))
    }
}
