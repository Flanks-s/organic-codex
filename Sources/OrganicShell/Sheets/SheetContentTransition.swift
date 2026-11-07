import AppKit
import QuartzCore

/// #56/#63: appearance is Gaussian by default; the legacy comparison contains glyphs only.
enum SheetZoom: String {
    case accum,gauss
    static var selected:Self {Self(rawValue:ProcessInfo.processInfo.environment["M10_SHEET_ZOOM"] ?? "accum") ?? .accum}
}

@MainActor enum SheetInkCapture {
    struct Bitmap {let image:CGImage;let rect:CGRect}
    struct Pair {let original:CGImage,plates:CGImage,ink:CGImage;let exceptionalPixels:Int}
    static func bytes(_ image:CGImage)->[UInt8] {
        var b=[UInt8](repeating:0,count:image.width*image.height*4)
        b.withUnsafeMutableBytes {p in let c=CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))};return b
    }
    static func image(_ bytes:[UInt8],width:Int,height:Int)->CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
    }
    /// Source-over foreground recovered from two draws of the SAME native tree. Never colour-key a plate.
    static func split(_ original:CGImage,plates:CGImage)->Pair {
        precondition(original.width==plates.width && original.height==plates.height)
        let a=bytes(original),b=bytes(plates);var g=[UInt8](repeating:0,count:a.count),exceptions=0
        for i in stride(from:0,to:a.count,by:4) {
            if a[i]==b[i] && a[i+1]==b[i+1] && a[i+2]==b[i+2] && a[i+3]==b[i+3] {continue}
            let aa=Double(a[i+3])/255,ab=Double(b[i+3])/255
            var alpha=ab<1 ? max(0,min(1,(aa-ab)/(1-ab))):0
            // Font smoothing can change RGB without changing quantized alpha on a translucent plate.
            // Enforce valid premultiplied foreground on EVERY pixel, not only when B is opaque.
            for c in 0..<3 {let x=Double(a[i+c])/255,y=Double(b[i+c])/255;alpha=max(alpha,x>=y ? (x-y)/max(1e-9,1-y):(y-x)/max(1e-9,y))}
            if aa+1/255<ab {exceptions+=1}
            let q=min(255,max(0,Int((alpha*255).rounded())));g[i+3]=UInt8(q)
            for c in 0..<3 {g[i+c]=UInt8(min(q,max(0,Int((Double(a[i+c])-Double(b[i+c])*(1-Double(q)/255)).rounded()))))}
        }
        return Pair(original:image(a,width:original.width,height:original.height),plates:image(b,width:plates.width,height:plates.height),ink:image(g,width:original.width,height:original.height),exceptionalPixels:exceptions)
    }
    static func capture(_ view:NSView,scale:CGFloat)->Pair {
        var restore:[()->Void]=[]
        func sample(_ v:NSView) {
            if let dots=v as? SheetActivityDots {restore.append(dots.samplePresentationForCapture())}
            else {for child in v.subviews {sample(child)}}
        }
        sample(view)
        func mark(_ v:NSView) {v.needsDisplay=true;for c in v.subviews {mark(c)}}
        func mute(_ v:NSView) {
            if let label=v as? NSTextField {let old=label.textColor;label.textColor = .clear;restore.append{label.textColor=old}}
            if v is NSImageView {let a=v.alphaValue;v.alphaValue=0;restore.append{v.alphaValue=a}}
            for c in v.subviews {mute(c)}
        }
        let old=SheetStyle.capturesPlates
        CATransaction.begin();CATransaction.setDisableActions(true)
        SheetStyle.capturesPlates=false;mark(view);let a=NativeViewBitmap.capture(view,scale:scale)
        SheetStyle.capturesPlates=true;mute(view);mark(view);let b=NativeViewBitmap.capture(view,scale:scale)
        for undo in restore.reversed() {undo()};SheetStyle.capturesPlates=old;mark(view);view.displayIfNeeded()
        CATransaction.commit();return split(a,plates:b)
    }
    /// Tight at backing-pixel alpha bounds; the destination is flipped AppKit coordinates.
    static func trim(_ image:CGImage,scale:CGFloat)->Bitmap? {
        let b=bytes(image),w=image.width,h=image.height;var x0=w,y0=h,x1 = -1,y1 = -1
        for y in 0..<h {for x in 0..<w where b[(y*w+x)*4+3]>0 {x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)}}
        guard x1>=x0,let crop=image.cropping(to:CGRect(x:x0,y:y0,width:x1-x0+1,height:y1-y0+1)) else {return nil}
        return Bitmap(image:crop,rect:CGRect(x:CGFloat(x0)/scale,y:CGFloat(y0)/scale,width:CGFloat(x1-x0+1)/scale,height:CGFloat(y1-y0+1)/scale))
    }
}

/// Native controls keep their hit testing/AX. During motion only, their two drawings are replaced by ONE
/// unfiltered plate sibling and a tightly cropped glyph plane. No view/container/filter is below a replicator.
@MainActor final class SheetContentTransition {
    let root=CALayer(),planes=CALayer(),reference=CALayer(),plates=CALayer(),foreground=CALayer(),trail=ChordTrail()
    private(set) var effect:ContentGaussianTransition?
    private(set) var capture:SheetInkCapture.Pair?
    private weak var content:NSView?
    private var hidden:[(NSView,Bool)]=[]
    private(set) var mode=SheetZoom.gauss
    private(set) var active=false
    private(set) var lastExposure=ExposureSample.still
    private(set) var commitTime=0.0
    private var configuration=ContentGaussianTransition.Configuration.system
    private var backingScale:CGFloat=1
    private var pivot=CGPoint.zero
    private var rowSources:[(CGRect,CALayer)]=[]
    private var rowAnimationGroups:[(CALayer,CALayer)]=[]
    private var preparing=false
    let sceneClock:SceneClock
    init(clock:SceneClock) {sceneClock=clock;root.name="sheet.content.transition";plates.name="sheet.plates.unfiltered";foreground.name="sheet.glyphs.single";root.addSublayer(planes);planes.addSublayer(plates);planes.addSublayer(foreground);root.addSublayer(reference)}
    func begin(in view:NSView,mode:SheetZoom,configuration:ContentGaussianTransition.Configuration,visible:Bool,at time:Double?=nil,scale:CGFloat,pivot:CGPoint,rows:[(CGRect,CALayer)]=[],preservingEffect:Bool=false) {
        guard !preparing else {return};preparing=true;defer {preparing=false}
        let previous=preservingEffect ? effect:nil
        if preservingEffect {for (v,a) in hidden {v.layer?.isHidden=a};hidden=[];root.removeFromSuperlayer()} else {finish()}
        content=view;self.mode=mode;self.configuration=configuration;backingScale=scale;self.pivot=pivot;rowSources=rows
        CATransaction.begin();CATransaction.setDisableActions(true)
        let pair=SheetInkCapture.capture(view,scale:scale);capture=pair
        root.anchorPoint = .zero;root.frame=view.bounds;planes.anchorPoint = .zero;planes.frame=view.bounds;reference.anchorPoint = .zero;reference.frame=view.bounds;plates.anchorPoint = .zero;plates.frame=view.bounds;plates.contents=nil;plates.sublayers=nil
        ReplicaContainerAudit.register(plates,material:.container,note:"Native plate-only drawing; unfiltered sibling")
        let region=view.bounds
        foreground.bounds=region;foreground.position=pivot;foreground.anchorPoint=CGPoint(x:(pivot.x-region.minX)/region.width,y:(pivot.y-region.minY)/region.height)
        foreground.sublayers=nil;if !preservingEffect {foreground.opacity=1;foreground.transform=CATransform3DIdentity}
        if !preservingEffect {trail.reset();lastExposure = .still};trail.layer.sublayers=nil
        let inkRoot=mode == .accum ? trail.layer:foreground
        if mode == .accum {foreground.addSublayer(trail.layer)}
        func append(_ image:CGImage,to parent:CALayer,offset:CGPoint,ink:Bool) {
            let layer=CALayer();layer.anchorPoint = .zero;layer.contentsScale=scale
            if ink {guard let bitmap=SheetInkCapture.trim(image,scale:scale) else {return};layer.contents=bitmap.image;layer.frame=bitmap.rect.offsetBy(dx:offset.x,dy:offset.y)}
            else {layer.contents=image;layer.frame=CGRect(origin:offset,size:CGSize(width:CGFloat(image.width)/scale,height:CGFloat(image.height)/scale))}
            ReplicaContainerAudit.register(layer,material:ink ? .glyph:.container,note:ink ? "Same-source foreground matte; plate pixels removed, alpha-tight crop":"Native plate-only drawing; never filtered/replicated")
            parent.addSublayer(layer)
        }
        rowAnimationGroups=[]
        var inkBytes=SheetInkCapture.bytes(pair.ink),plateBytes=SheetInkCapture.bytes(pair.plates)
        for (rect,source) in rows {
            let rect=rect.intersection(view.bounds);guard !rect.isEmpty else {continue}
            let px=CGRect(x:(rect.minX*scale).rounded(),y:(rect.minY*scale).rounded(),width:(rect.width*scale).rounded(),height:(rect.height*scale).rounded())
            guard let g=pair.ink.cropping(to:px),let p=pair.plates.cropping(to:px) else {continue}
            for (image,parent,isInk) in [(g,inkRoot,true),(p,plates,false)] {
                let group=CALayer();parent.addSublayer(group);append(image,to:group,offset:rect.origin,ink:isInk)
                rowAnimationGroups.append((source,group))
                for key in source.animationKeys() ?? [] where key=="overlay.opacity" || key=="overlay.transform.translation.y" {
                    if let animation=source.animation(forKey:key) {group.add(animation,forKey:key)}
                }
            }
            for y in Int(px.minY)..<Int(px.maxY) {for x in Int(px.minX)..<Int(px.maxX) {let i=(y*pair.ink.width+x)*4;for c in 0..<4 {inkBytes[i+c]=0;plateBytes[i+c]=0}}}
        }
        append(SheetInkCapture.image(inkBytes,width:pair.ink.width,height:pair.ink.height),to:inkRoot,offset:.zero,ink:true)
        append(SheetInkCapture.image(plateBytes,width:pair.plates.width,height:pair.plates.height),to:plates,offset:.zero,ink:false)
        // Preparation may take longer than the 100ms effect. Never let it consume the animation's budget.
        let time=time ?? sceneClock.mediaTime();commitTime=time
        if !preservingEffect {
            planes.removeAllAnimations();reference.removeAllAnimations();planes.opacity=1;reference.opacity=0;reference.contents=nil
            if !visible {
                // Exact native sharp endpoint, with an exclusive (never overlapping) CA handoff to the matte.
                // This is one reference pose, not a second exposure, container replica or filtered background.
                reference.contents=pair.original;reference.contentsScale=scale
                ReplicaContainerAudit.register(reference,material:.container,note:"Single untreated endpoint reference; exclusive of the processing planes")
                for (layer,values) in [(reference,[1,0]),(planes,[0,1])] {
                    let gate=CAKeyframeAnimation(keyPath:"opacity");gate.values=values;gate.keyTimes=[0,0.000001,1];gate.calculationMode = .discrete
                    gate.duration=configuration.duration;gate.beginTime=layer.convertTime(time,from:nil);gate.fillMode = .both;gate.isRemovedOnCompletion=false;layer.add(gate,forKey:"sheet.endpoint.handoff")
                }
            }
        }
        for v in view.subviews {v.wantsLayer=true;hidden.append((v,v.layer?.isHidden ?? false));v.layer?.isHidden=true}
        view.layer?.addSublayer(root);active=true
        if mode == .gauss {if let previous {effect=previous} else {effect=ContentGaussianTransition(content:foreground,clock:sceneClock,initiallyVisible:!visible,configuration:configuration);effect?.setVisible(visible,at:time)}}
        if let end=effect?.endTime {sceneClock.run(until:end)}
        CATransaction.commit()
    }
    func refresh(rows:[(CGRect,CALayer)]?=nil) {
        guard active,!preparing,let content else {return}
        begin(in:content,mode:mode,configuration:configuration,visible:true,at:sceneClock.mediaTime(),scale:backingScale,pivot:CGPoint(x:content.bounds.midX,y:pivot.y>0 ? content.bounds.height:0),rows:rows ?? rowSources,preservingEffect:true)
    }
    func copyRowAnimations() {
        for (source,group) in rowAnimationGroups {
            for key in ["overlay.opacity","overlay.transform.translation.y"] {
                if let a=source.animation(forKey:key)?.copy() as? CAAnimation {a.beginTime=group.convertTime(source.convertTime(a.beginTime,to:nil),from:nil);group.add(a,forKey:key)}
            }
        }
    }
    isolated deinit {finish()}
    /// Legacy driver-B comparison, using only the detached, alpha-tight glyph textures.
    func animateAccumulation(duration:Double,at time:Double,profile:DisplayProfile,pose:(Double)->CGRect) {
        guard active,mode == .accum else {return}
        let base=CGRect(origin:.zero,size:root.bounds.size),count=max(2,Int(ceil(duration/profile.frameInterval))+1)
        let times=(0..<count).map{min(duration,Double($0)*profile.frameInterval)}
        var copies:[Any]=[],colors:[Any]=[],transforms:[Any]=[],active=false
        for (i,t) in times.enumerated() {
            let a=pose(t),b=pose(max(0,t-profile.frameInterval)),scale=a.width/max(1,base.width)
            let old=CGRect(x:(b.minX-a.minX)/scale,y:(b.minY-a.minY)/scale,width:b.width/scale,height:b.height/scale)
            var metric=profile;metric.mmPerPoint *= Double(scale)
            var settings=M10FExposure.settings(now:base,earlier:old);settings.spacing /= max(1,scale)
            let e=i==count-1 ? .still:M10FExposure.sample(now:base,earlier:old,profile:metric,settings:settings)
            active=active || e.count>1;copies.append(e.count);colors.append(e.instanceColor);transforms.append(NSValue(caTransform3D:M10FExposure.chord(now:base,earlier:old,sample:e)))
        }
        guard active else {return}
        let n=M10FExposure.keys("instanceCount",copies,duration:duration,times:times);n.calculationMode = .discrete
        let g=CAAnimationGroup();g.animations=[n,M10FExposure.keys("instanceColor",colors,duration:duration,times:times),M10FExposure.keys("instanceTransform",transforms,duration:duration,times:times)]
        g.duration=duration;g.beginTime=trail.layer.convertTime(time,from:nil);g.fillMode = .backwards;trail.layer.add(g,forKey:"sheet.legacy.accum")
    }
    func setVisible(_ visible:Bool,at time:Double) {effect?.setVisible(visible,at:time);if let end=effect?.endTime {sceneClock.run(until:end)}}
    func finish() {
        CATransaction.begin();CATransaction.setDisableActions(true)
        for (v,a) in hidden {v.layer?.isHidden=a};hidden=[];root.removeFromSuperlayer();foreground.removeAllAnimations();foreground.filters=nil
        effect=nil;trail.layer.removeAllAnimations();trail.reset();lastExposure = .still;reference.removeAllAnimations();reference.contents=nil;reference.opacity=0;planes.removeAllAnimations();planes.opacity=1;capture=nil;content=nil;active=false;CATransaction.commit()
    }
    func settle(at time:Double) {_ = effect?.settle(at:time)}
    func accumulate(now:CGRect,earlier:CGRect,profile:DisplayProfile) {
        guard active,mode == .accum else {return}
        let base=CGRect(origin:.zero,size:root.bounds.size),s=now.width/max(1,base.width)
        let old=CGRect(x:(earlier.minX-now.minX)/s,y:(earlier.minY-now.minY)/s,width:earlier.width/s,height:earlier.height/s)
        var metric=profile;metric.mmPerPoint *= Double(s)
        var settings=M10FExposure.settings(now:base,earlier:old);settings.spacing /= max(1,s)
        let sample=M10FExposure.sample(now:base,earlier:old,profile:metric,settings:settings)
        lastExposure=sample
        M10FExposure.apply(sample,to:trail,now:base,earlier:old)
    }
}
