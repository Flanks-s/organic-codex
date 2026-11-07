import AppKit

/// Source is the native glyph's OWN paint, never a card/plate/background. The audit still verifies alpha/crop.
@MainActor enum OverlayGlyphBitmap {
    struct Bitmap { let image: CGImage; let rect: CGRect }
    static func crop(_ image: CGImage, bounds: CGRect) -> Bitmap? {
        let w=image.width,h=image.height
        let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        let p=c.data!.assumingMemoryBound(to:UInt8.self)
        var x0=w,y0=h,x1=0,y1=0
        for y in 0..<h {for x in 0..<w where p[(y*w+x)*4+3]>0 {x0=min(x0,x);y0=min(y0,y);x1=max(x1,x+1);y1=max(y1,y+1)}}
        guard x1>x0,y1>y0,let cut=c.makeImage()?.cropping(to:CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)) else {return nil}
        return Bitmap(image:cut,rect:CGRect(x:bounds.minX+CGFloat(x0)*bounds.width/CGFloat(w),y:bounds.minY+CGFloat(y0)*bounds.height/CGFloat(h),
                                            width:CGFloat(x1-x0)*bounds.width/CGFloat(w),height:CGFloat(y1-y0)*bounds.height/CGFloat(h)))
    }
    static func ownPaint(_ view:NSView,scale:CGFloat)->Bitmap? {
        let image:CGImage
        if let ink=view as? OverlayInkView,let paint=ink.paint {
            let clone=OverlayInkView(frame:view.bounds);clone.paint=paint
            image=NativeViewBitmap.capture(clone,scale:scale)
        } else if view is NSTextField {
            image=NativeViewBitmap.capture(view,scale:scale)
        } else {return nil}
        return crop(image,bounds:view.bounds)
    }
}

/// Moving native glyphs stay single. Each copied leaf is a tight CGImage with pure pose ancestors.
/// A SINGLE current Gaussian and opacity are applied AFTER that leaf's replicator, never inside it.
@MainActor final class OverlayGlyphExposure {
    private let root=CALayer()
    private var originals:[CALayer]=[]
    private(set) var frames:[OverlayExposureFrame]=[]
    private(set) var peakPixels=0
    init(view:OverlayAccumulatingView,profile:DisplayProfile,origin:Double=CACurrentMediaTime()) {
        #if OVERLAY_SELFTEST
        let start=CACurrentMediaTime()
        defer {OverlayExposure.preparationTimesMS.append((CACurrentMediaTime()-start)*1000)}
        #endif
        root.anchorPoint = .zero;root.frame=view.bounds;root.name="overlay.glyph-exposure"
        view.layer?.addSublayer(root)
        let scale=max(1,view.window?.backingScaleFactor ?? 2)
        func visit(_ node:NSView,chain:[CALayer]) {
            guard !node.isHidden,let source=node.layer else {return}
            let layers=chain+[source]
            if let bitmap=OverlayGlyphBitmap.ownPaint(node,scale:scale) {append(bitmap,layers:layers,profile:profile,origin:origin)}
            node.subviews.forEach {visit($0,chain:layers)}
        }
        CATransaction.begin();CATransaction.setDisableActions(true)
        visit(view.ink,chain:[])
        CATransaction.commit()
    }
    private func append(_ bitmap:OverlayGlyphBitmap.Bitmap,layers:[CALayer],profile:DisplayProfile,origin:Double) {
        let paths=layers.map {OverlayExposure.path(of:$0,origin:origin)}
        let duration=paths.map(\.duration).max() ?? 0
        func rect(_ t:Double)->CGRect {
            var r=bitmap.rect
            for p in paths.reversed() {
                let f=p.rect(at:t),sx=f.width/max(1e-9,p.bounds.width),sy=f.height/max(1e-9,p.bounds.height)
                r=CGRect(x:f.minX+(r.minX-p.bounds.minX)*sx,y:f.minY+(r.minY-p.bounds.minY)*sy,width:r.width*sx,height:r.height*sy)
            };return r
        }
        let samples=OverlayExposure.frames(duration:duration,profile:profile,enabled:true,rect:rect)
        guard samples.contains(where:{$0.sample.count>1}),let last=samples.last,last.time>0 else {return}
        if (samples.map{$0.sample.stepPt}.max() ?? 0)>(frames.map{$0.sample.stepPt}.max() ?? 0) {frames=samples}
        let visible=CALayer(),effect=CALayer(),rep=CAReplicatorLayer()
        for l in [visible,effect,rep] {l.anchorPoint = .zero;l.frame=root.bounds}
        visible.opacity=0;visible.name="overlay.exposure-gate";effect.name="overlay.single-filter"
        root.addSublayer(visible);visible.addSublayer(effect);effect.addSublayer(rep)
        var parent:CALayer=rep
        for source in layers {
            let copy=CALayer();copy.bounds=source.bounds;copy.position=source.position;copy.anchorPoint=source.anchorPoint;copy.transform=source.transform
            parent.addSublayer(copy)
            for key in source.animationKeys() ?? [] {
                if let a=source.animation(forKey:key) as? CAPropertyAnimation,a.keyPath?.hasPrefix("transform.")==true {
                    let track=a.copy() as! CAAnimation
                    let global=a.beginTime==0 ? origin:source.convertTime(a.beginTime,to:nil)
                    track.beginTime=copy.convertTime(global,from:nil);copy.add(track,forKey:key)
                }
            }
            parent=copy
        }
        let texture=CALayer();texture.anchorPoint = .zero;texture.frame=bitmap.rect;texture.contents=bitmap.image;texture.contentsScale=CGFloat(bitmap.image.width)/bitmap.rect.width
        texture.name="overlay.tight-glyph"
        ReplicaContainerAudit.register(texture,material:.glyph,note:"Native label/own lyric draw, transparent alpha, tight crop; filters outside copies")
        parent.addSublayer(texture)
        func track(_ layer:CALayer,_ key:String,_ values:[NSNumber],discrete:Bool) {
            let a=CAKeyframeAnimation(keyPath:key);a.values=discrete ? Array(values.dropLast()):values
            a.keyTimes=samples.enumerated().map {NSNumber(value:$0.offset==0 ? 0:$0.offset==samples.count-1 ? 1:max(0,($0.element.time-0.000001)/last.time))}
            a.calculationMode=discrete ? .discrete:.linear;a.duration=last.time;a.beginTime=layer.convertTime(origin,from:nil)
            layer.add(a,forKey:"overlay.exposure."+key)
        }
        track(visible,"opacity",samples.map{NSNumber(value:$0.sample.count>1 ? 1:0)},discrete:true)
        if let native=layers.last {
            originals.append(native)
            track(native,"hidden",samples.map{NSNumber(value:$0.sample.count>1)},discrete:true)
        }
        let alpha=samples.map {f in paths.enumerated().reduce(1.0) {v,p in v*Double(p.element.scalars["opacity"]?.value(at:f.time) ?? CGFloat(layers[p.offset].opacity))}}
        track(effect,"opacity",alpha.map{NSNumber(value:$0)},discrete:false)
        // Combine existing Gaussian radii, rather than copying filter nodes under the replicator.
        let radius=samples.map {f in sqrt(paths.enumerated().reduce(0.0) {sum,p in
            var r=0.0
            for filter in layers[p.offset].filters ?? [] {
                guard let o=filter as? NSObject,o.responds(to:NSSelectorFromString("name")),let name=o.value(forKey:"name") as? String else {continue}
                let key="filters."+name+".inputRadius"
                if let animated=p.element.scalars[key] {r+=pow(Double(animated.value(at:f.time)),2)}
                else if o.responds(to:NSSelectorFromString("inputRadius")) {r+=pow((o.value(forKey:"inputRadius") as? NSNumber)?.doubleValue ?? 0,2)}
            };return sum+r
        })}
        if radius.contains(where:{$0>0}),let blur=OverlayFilter.make("gaussianBlur",values:["inputRadius":0,"name":"overlayReplicaBlur"]) {
            effect.filters=[blur];track(effect,"filters.overlayReplicaBlur.inputRadius",radius.map{NSNumber(value:$0)},discrete:false)
        }
        OverlayExposure.write(rep,frames:samples,origin:origin)
        peakPixels=max(peakPixels,(samples.map{$0.sample.count}.max() ?? 1)*bitmap.image.width*bitmap.image.height)
    }
    func reset() {
        originals.forEach {$0.removeAnimation(forKey:"overlay.exposure.hidden")};originals=[]
        root.removeFromSuperlayer();root.sublayers?.forEach{$0.removeFromSuperlayer()};frames=[]
    }
}
