import AppKit
import QuartzCore
import CoreImage

/// Product NativeHeaderIslandTextPhase controlsIn/controlsOut (.1 delay, .09 easeOut), interrupted from the
/// current alpha. Keep semantic controls separate from glass geometry and from M10's motion exposure.
struct IslandControlsFade {
    var from:CGFloat,to:CGFloat,began:Double
    func value(at time:Double)->CGFloat {
        let t=max(0,min(1,(time-began-0.1)/0.09));var lo=0.0,hi=1.0
        for _ in 0..<20 {let u=(lo+hi)/2,x=3*0.58*(1-u)*u*u+u*u*u;if x<t{lo=u}else{hi=u}}
        let u=(lo+hi)/2,k=CGFloat(3*(1-u)*u*u+u*u*u)
        return t<=0 ? from:t>=1 ? to:from+(to-from)*k
    }
    func complete(at time:Double)->Bool {time>=began+0.19}
}

/// cacheDisplay has no compositing server. Quartz's image translation snaps its reconstruction kernel at a half
/// pixel even with high interpolation (measured alpha 63→192 for a 0.4→0.6px translation). The moving-only proxy
/// uses the same linear texture reconstruction as CA, with no extra blur or changes to the stationary capture.
@MainActor enum IslandGlyphBitmapPose {
    private static let context=CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
    static func image(_ glyphs:CGImage,transform:CGAffineTransform,width:Int,height:Int)->CGImage? {
        context.createCGImage(CIImage(cgImage:glyphs).transformed(by:transform),from:CGRect(x:0,y:0,width:width,height:height))
    }
}

/// M10-D native glyph material. The original controls (and their authored blur/opacity animations) remain children;
/// no glass is a descendant. One identity instance is exactly the old native drawing, including selection and AX.
@MainActor final class IslandGlyphPlane: NSView {
    let trail=ChordTrail()
    private(set) var sample=ExposureSample.still
    var textureScale:CGFloat=2
    var forceTextureExposure=false
    var warmingEnabled=ProcessInfo.processInfo.environment["M10_COLUMNS"] != "0"
    let textureTrail=CAReplicatorLayer() // first label; retained for the offscreen material fixture
    private weak var suppressedPose:NSView?
    private var texturesInstalled=false
    private var poseOpacity:Float=1
    private struct Stamp:Equatable {
        var text:String,font:String,size:CGFloat,bounds:CGRect,color:NSColor?,appearance:NSAppearance.Name,scale:CGFloat
    }
    private struct Sprite {
        var stamp:Stamp
        let layer:CALayer,carrier:CALayer,replicator:CAReplicatorLayer,pose:CALayer
        var animations:[String:Double]=[:],filters=""
    }
    private var sprites:[ObjectIdentifier:Sprite]=[:]
    private var captures:[ObjectIdentifier:(stamp:Stamp,image:CGImage)]=[:]
    // Promotion visits title→New Chat→title, then gives the outgoing drawing a new NSView identity.
    // Keep a small pool by complete drawing stamp, so both drawings remain prepared across that handoff.
    private var recentCaptures:[(stamp:Stamp,image:CGImage)]=[]
    private(set) var captureCount=0
    private(set) var captureTimeMs=0.0
    var textureCosts:[String:Int] {
        var replicas=0,pixels=0,source=0,filters=0
        for s in sprites.values where !s.carrier.isHidden && !s.replicator.isHidden {
            let n=s.replicator.instanceCount
            if let value=s.layer.contents {let image=value as! CGImage,area=image.width*image.height;source+=area;pixels+=n*area}
            replicas+=n
            if !(s.carrier.filters ?? []).isEmpty {filters+=Int(ceil(s.carrier.bounds.width*textureScale)*ceil(s.carrier.bounds.height*textureScale))}
        }
        return ["captures":captureCount,"sprites":sprites.count,"replicas":replicas,"replicatedPixels":pixels,"sourcePixels":source,"filteredPixels":filters]
    }
    private func stamp(_ label:NSTextField,_ scale:CGFloat)->Stamp {
        Stamp(text:label.stringValue,font:label.font?.fontName ?? "",size:label.font?.pointSize ?? 13,bounds:label.bounds,color:label.textColor,appearance:label.effectiveAppearance.name,scale:scale)
    }
    private func bitmap(_ label:NSTextField,stamp:Stamp,native:CALayer,saved:Float)->CGImage {
        let id=ObjectIdentifier(label)
        if let cached=captures[id],cached.stamp==stamp {return cached.image}
        if let cached=recentCaptures.last(where:{$0.stamp==stamp}) {captures[id]=cached;return cached.image}
        let alpha=label.alphaValue,prior=native.opacity
        native.opacity=saved;label.alphaValue=1
        let began=CACurrentMediaTime()
        let image=NativeViewBitmap.capture(label,scale:stamp.scale)
        captureTimeMs+=(CACurrentMediaTime()-began)*1000
        label.alphaValue=alpha;native.opacity=prior
        captures[id]=(stamp,image);recentCaptures.append((stamp,image))
        if recentCaptures.count>8 {recentCaptures.removeFirst(recentCaptures.count-8)}
        captureCount+=1;return image
    }
    /// Prepare a compact endpoint's authored drawing without reconfiguring the live header/state/editor.
    /// IslandLabel draws only these attributes; the copy uses its exact draw(_:) path and backing scale.
    @discardableResult func warmDrawing(of label:IslandLabel,font:NSFont,bounds:CGRect)->CGImage? {
        guard warmingEnabled,(window != nil || forceTextureExposure) else {return nil}
        var wanted=stamp(label,window?.backingScaleFactor ?? textureScale)
        wanted.font=font.fontName;wanted.size=font.pointSize;wanted.bounds=bounds
        if let cached=recentCaptures.last(where:{$0.stamp==wanted}) {return cached.image}
        let copy=IslandLabel(labelWithString:label.stringValue)
        copy.appearance=label.effectiveAppearance;copy.font=font;copy.textColor=label.textColor
        copy.alignment=label.alignment;copy.lineBreakMode=label.lineBreakMode
        copy.isBordered=false;copy.isBezeled=false;copy.drawsBackground=false;copy.wantsLayer=true
        copy.frame=CGRect(origin:.zero,size:bounds.size);copy.bounds=bounds
        guard let layer=copy.layer else {return nil}
        let image=bitmap(copy,stamp:wanted,native:layer,saved:1)
        captures[ObjectIdentifier(copy)]=nil
        return image
    }

    /// Cache the native drawing at rest, never on the first high-speed display-link callback. No layout/flush.
    func warmTextures() {
        guard warmingEnabled,(window != nil || forceTextureExposure),sample.count<=1,let source=subviews.first,let native=source.layer else{return}
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        let scale=window?.backingScaleFactor ?? textureScale,saved=suppressedPose==nil ? native.opacity:poseOpacity
        var keep:Set<ObjectIdentifier>=[]
        for case let label as NSTextField in source.subviews where !label.isHidden && label.bounds.width>0 && label.bounds.height>0 {
            keep.insert(ObjectIdentifier(label));_=bitmap(label,stamp:stamp(label,scale),native:native,saved:saved)
        }
        captures=captures.filter{keep.contains($0.key)}
    }
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();if window != nil {warmTextures()}}
    func reset() {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        trail.reset();sample = .still;restoreNative()
        for id in Array(sprites.keys) {
            sprites[id]?.layer.removeAllAnimations();sprites[id]?.carrier.removeAllAnimations();sprites[id]?.animations=[:]
        }
    }
    private func restoreNative() {
        guard texturesInstalled else{return}
        texturesInstalled=false
        suppressedPose?.layer?.opacity=poseOpacity;suppressedPose=nil
        for s in sprites.values {s.carrier.isHidden=true;s.replicator.isHidden=true;s.replicator.instanceCount=1}
        textureTrail.isHidden=true;textureTrail.instanceCount=1
    }
    override var isFlipped:Bool {true}
    override func makeBackingLayer()->CALayer {CALayer()}
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true;autoresizesSubviews=false;setAccessibilityElement(false)
        textureTrail.isHidden=true;trail.settings.spacing=1.25;trail.settings.maxCopies=2048
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    override func hitTest(_ point:NSPoint)->NSView? {nil}

    func update(now:CGRect,earlier:CGRect,profile:DisplayProfile,settings:ExposureSettings,epoch:Double?=nil) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        trail.settings=settings;trail.settings.spacing=1.25;trail.settings.maxCopies=2048
        let wasActive=sample.count>1
        // This plane computes a refined chord below. Updating ChordTrail first submitted a second, unused
        // sample/transform/color and nested transaction on every motion frame, then immediately overwrote it.
        var s=ExposureSample(now:now,earlier:earlier,frameInterval:profile.frameInterval,mmPerPoint:profile.mmPerPoint,settings:trail.settings)
        if s.gate>0,s.count==1 {s.count=2;s.alpha=CGFloat(1-sqrt(0.1*Double(s.gate)));s.delayStep=Double(s.gate)*profile.frameInterval}
        sample=s
        guard s.count>1,now.width>0,now.height>0 else{if wasActive {trail.reset()};restoreNative();return}
        let interval=Double(s.count-1)*s.delayStep,g=s.gate,rx=1+(earlier.width/now.width-1)*g,ry=1+(earlier.height/now.height-1)*g
        var coverage=now.insetBy(dx:-8,dy:-8)
        if let source=subviews.first,let native=source.layer,let parent=layer {
            let labels=source.subviews.filter{($0 is NSTextField) && !$0.isHidden}
            let box=labels.reduce(CGRect.null){$0.union($1.frame.insetBy(dx:-4,dy:-4))}
            if !box.isNull {coverage=coverage.union(native.convert(box,to:parent))}
        }
        var t=CATransform3DIdentity
        while true {
            let n=CGFloat(s.count-1),sx=pow(max(0.001,rx),1/n),sy=pow(max(0.001,ry),1/n)
            func sum(_ r:CGFloat,_ total:CGFloat)->CGFloat {abs(r-1)<1e-8 ? n:(total-1)/(r-1)}
            let dx=(earlier.midX-now.midX)*g/sum(sx,rx),dy=(earlier.midY-now.midY)*g/sum(sy,ry)
            t=CATransform3DMakeTranslation(now.midX+dx,now.midY+dy,0)
            t=CATransform3DScale(t,sx,sy,1);t=CATransform3DTranslate(t,-now.midX,-now.midY,0)
            var total=CATransform3DMakeTranslation(now.midX+(earlier.midX-now.midX)*g,now.midY+(earlier.midY-now.midY)*g,0)
            total=CATransform3DScale(total,rx,ry,1);total=CATransform3DTranslate(total,-now.midX,-now.midY,0)
            let step=CATransform3DGetAffineTransform(t),last=coverage.applying(CATransform3DGetAffineTransform(total))
            let spacing=max(MotionStep.edge(coverage,coverage.applying(step)),MotionStep.edge(last.applying(step.inverted()),last))
            if spacing<=1.4 {break};s.count+=1
        }
        s.alpha=CGFloat(1-pow(0.1*Double(g),1/Double(s.count)));s.delayStep=interval/Double(s.count-1)
        sample=s;trail.layer.instanceCount=s.count;trail.layer.instanceColor=NSColor(white:1,alpha:s.alpha).cgColor
        trail.layer.instanceTransform=t
        if window != nil || forceTextureExposure {installTextures(epoch:epoch)}
    }

    /// Native drawing is cached once per revision. Authored Gaussian blur is applied ONCE after each label's
    /// accumulated glyphs, outside its replicator. It never becomes a per-copy filter/backing/mask pass.
    private func installTextures(epoch:Double?) {
        guard let source=subviews.first,let native=source.layer,let parent=layer else{return}
        let saved=suppressedPose == nil ? native.opacity:poseOpacity,scale=window?.backingScaleFactor ?? textureScale
        let o=native.convert(CGPoint.zero,to:parent),x=native.convert(CGPoint(x:1,y:0),to:parent),y=native.convert(CGPoint(x:0,y:1),to:parent)
        let pose=CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y)
        var global=trail.layer.instanceTransform
        // Conjugate the screen-space exposure into the native glyph coordinates. The outer carrier keeps the
        // original glyph pose, so authored Gaussian radii scale exactly as they did under glyphPose.
        global.m41=(global.m41+(global.m11-1)*pose.tx)/max(0.001,pose.a)
        global.m42=(global.m42+(global.m22-1)*pose.ty)/max(0.001,pose.d)
        let n=CGFloat(sample.count-1),sx=pow(global.m11,n),sy=pow(global.m22,n)
        func sum(_ r:CGFloat,_ total:CGFloat)->CGFloat {abs(r-1)<1e-8 ? n:(total-1)/(r-1)}
        let total=CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:global.m41*sum(global.m11,sx),ty:global.m42*sum(global.m22,sy))
        var kept:Set<ObjectIdentifier>=[]
        for case let label as NSTextField in source.subviews {
            guard !label.isHidden else{continue}
            let id=ObjectIdentifier(label);kept.insert(id)
            let stamp=self.stamp(label,scale)
            let fresh=sprites[id]==nil
            let r=fresh ? (sprites.isEmpty ? textureTrail:CAReplicatorLayer()):sprites[id]!.replicator
            var sprite=sprites[id] ?? Sprite(stamp:stamp,layer:CALayer(),carrier:CALayer(),replicator:r,pose:CALayer())
            if fresh {
                for l in [sprite.layer,sprite.carrier,r,sprite.pose] {l.anchorPoint = .zero;l.contentsScale=scale}
                r.name="island.baked-ink";r.addSublayer(sprite.pose);sprite.pose.addSublayer(sprite.layer)
                sprite.carrier.addSublayer(r);parent.addSublayer(sprite.carrier)
            }
            if fresh || sprite.stamp != stamp {
                sprite.layer.contents=bitmap(label,stamp:stamp,native:native,saved:saved);sprite.stamp=stamp
            }
            for node in [sprite.carrier,r,sprite.pose] where node.contentsScale != scale {node.contentsScale=scale}
            let l=sprite.layer;if l.contentsScale != scale {l.contentsScale=scale}
            if l.frame != label.frame {l.frame=label.frame}
            l.opacity=Float(label.alphaValue);l.transform=label.layer?.transform ?? CATransform3DIdentity
            let keys=label.layer?.animationKeys() ?? [],hasBlur=keys.contains{$0.contains("blur")}
            let filters=(label.layer?.filters ?? []).compactMap { value->CIFilter? in
                guard let f=value as? CIFilter else{return nil}
                if f.name=="islandRenameBlur",!hasBlur,(f.value(forKey:kCIInputRadiusKey) as? NSNumber)?.doubleValue==0 {return nil}
                return f
            }
            let filterKey=filters.map{String(ObjectIdentifier($0).hashValue)}.joined(separator:",")
            if sprite.filters != filterKey {sprite.carrier.filters=filters.map{$0.copy()};sprite.filters=filterKey}
            for key in sprite.animations.keys where !keys.contains(key) {
                l.removeAnimation(forKey:key);sprite.carrier.removeAnimation(forKey:key);sprite.animations[key]=nil
            }
            for key in keys {
                guard let animation=label.layer?.animation(forKey:key) else{continue}
                let began=animation.beginTime==0 ? (epoch ?? CACurrentMediaTime()):animation.beginTime
                if sprite.animations[key] != began {
                    let a=animation.copy() as! CAAnimation;a.beginTime=began
                    let target=((a as? CAPropertyAnimation)?.keyPath?.hasPrefix("filters.")==true || key.contains("blur")) ? sprite.carrier:l
                    target.add(a,forKey:key);sprite.animations[key]=began
                }
            }
            let box=label.frame.insetBy(dx:-4,dy:-4)
            let canvas=box.union(box.applying(total)).insetBy(dx:filters.isEmpty ? 0:-20,dy:filters.isEmpty ? 0:-20)
            if sprite.carrier.bounds != canvas {sprite.carrier.bounds=canvas}
            let anchor=CGPoint(x:-canvas.minX/canvas.width,y:-canvas.minY/canvas.height)
            if sprite.carrier.anchorPoint != anchor {sprite.carrier.anchorPoint=anchor}
            if sprite.carrier.position != .zero {sprite.carrier.position = .zero}
            let transform=CATransform3DMakeAffineTransform(pose)
            if !CATransform3DEqualToTransform(sprite.carrier.transform,transform) {sprite.carrier.transform=transform}
            if sprite.carrier.isHidden {sprite.carrier.isHidden=false}
            let boxBounds=CGRect(origin:.zero,size:box.size)
            if r.bounds != boxBounds {r.bounds=boxBounds};if r.position != box.origin {r.position=box.origin}
            if sprite.pose.bounds != .zero {sprite.pose.bounds = .zero}
            let position=CGPoint(x:-box.minX,y:-box.minY)
            if sprite.pose.position != position {sprite.pose.position=position}
            if !CATransform3DIsIdentity(sprite.pose.transform) {sprite.pose.transform=CATransform3DIdentity}
            var step=global;step.m41 += (step.m11-1)*box.minX;step.m42 += (step.m22-1)*box.minY
            r.instanceTransform=step;r.instanceCount=sample.count;r.instanceColor=trail.layer.instanceColor;r.isHidden=false
            sprites[id]=sprite
        }
        for id in Array(sprites.keys) where !kept.contains(id) {sprites[id]?.carrier.removeFromSuperlayer();sprites[id]=nil}
        guard !kept.isEmpty else{restoreNative();return}
        if suppressedPose==nil {suppressedPose=source;poseOpacity=saved}
        texturesInstalled=true
        if native.opacity != 0 {native.opacity=0}
    }
}

/// Glass uses real frames only. Resize can move the edges with no centre displacement, so supplement the common
/// MotionStretch centre sweep by the uncovered edge sweep (zoom is never applied as a transform to glass).
enum IslandGlassExposure {
    static func frame(now: CGRect, earlier: CGRect, profile: DisplayProfile, settings: ExposureSettings) -> CGRect {
        let sample = ExposureSample(now: now, earlier: earlier, frameInterval: profile.frameInterval, mmPerPoint: profile.mmPerPoint, settings: settings)
        guard sample.gate > 0 else { return now }
        var r = MotionStretch.rect(now: now, earlier: earlier, profile: profile, settings: settings)
        let covered = hypot(r.width-now.width,r.height-now.height)
        let missing = max(0,sample.length-covered)
        if abs(earlier.midX-now.midX)+abs(earlier.width-now.width) >= abs(earlier.midY-now.midY)+abs(earlier.height-now.height) {
            let required=sqrt(max(0,sample.length*sample.length-pow(r.height-now.height,2)))
            let extra=missing>0 ? max(0,required-(r.width-now.width)):0
            if earlier.midX <= now.midX { r.origin.x -= extra }; r.size.width += extra
        } else {
            let required=sqrt(max(0,sample.length*sample.length-pow(r.width-now.width,2)))
            let extra=missing>0 ? max(0,required-(r.height-now.height)):0
            if earlier.midY <= now.midY { r.origin.y -= extra }; r.size.height += extra
        }
        return MotionStretch.limited(r,now:now)
    }
}

struct IslandMotionRecord {
    var material: String
    var now: CGRect, earlier: CGRect, treated: CGRect
    var sample: ExposureSample
    var shutter:Double=1
    var fields: [String: Any] {
        let glyphs=material == "island.name"
        return ["id":material,"rect":NSStringFromRect(now),"earlier":NSStringFromRect(earlier),"treated":NSStringFromRect(treated),
         "stepPt":MotionStep.edge(now,earlier)/CGFloat(max(0.0001,shutter)),"gate":sample.gate,"lengthPt":sample.length,"copies":glyphs ? sample.count:1,
         "spacingPt":glyphs && sample.count>1 ? sample.length/CGFloat(sample.count-1):0,
         "treatment":glyphs ? "glyph accumulation":"real frame stretch"]
    }
}

/// A local display link is active only for standalone expansion/lobe. Column motion is already sampled by the
/// scene's display link. Offscreen tests call sampleMotion(at:) explicitly; no Timer and no window is required.
@MainActor final class IslandMotionClock: NSObject {
    private var link: CADisplayLink?
    var isRunning: Bool { link != nil }
    var tick: ((Double)->Void)?
    func start(in view: NSView) {
        guard link == nil, view.window != nil else { return }
        let link = view.displayLink(target:self,selector:#selector(frame(_:)))
        self.link=link; link.add(to:.main,forMode:.common)
    }
    @objc private func frame(_ link: CADisplayLink) { tick?(link.targetTimestamp) }
    func stop() { link?.invalidate(); link=nil }
    isolated deinit { link?.invalidate() }
}
