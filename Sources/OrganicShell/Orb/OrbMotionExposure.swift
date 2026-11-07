import AppKit
import QuartzCore

/// M10-F. Geometry is expressed in displayed points; no nominal-screen constants enter production sampling.
enum M10FExposure {
    @MainActor static func profile(for view: NSView) -> DisplayProfile {
        DisplayProfile.of(view.window?.screen ?? NSScreen.main ?? NSScreen.screens[0])
    }
    static var settings: ExposureSettings {
        var s = ExposureSettings()
        // A window-width draft sweep can need more than forty copies at 60 Hz. Never trade spacing for a cap.
        s.maxCopies = 1024
        return s
    }
    /// Preserve the complete smoothstep, including a positive sweep smaller than the engine's 0.01 pt guard.
    /// This converges to two coincident, opaque-composite copies instead of dropping a just-open gate to zero.
    static func sample(now:CGRect,earlier:CGRect,profile:DisplayProfile,settings:ExposureSettings)->ExposureSample {
        var s=ExposureSample(now:now,earlier:earlier,frameInterval:profile.frameInterval,mmPerPoint:profile.mmPerPoint,settings:settings)
        if s.gate>0,s.count==1 {
            s.count=2;s.alpha=CGFloat(1-sqrt(0.1*Double(s.gate)));s.delayStep=Double(s.gate)*settings.shutter*profile.frameInterval
        }
        return s
    }
    static func stretch(now:CGRect,earlier:CGRect,profile:DisplayProfile,settings:ExposureSettings = M10FExposure.settings)->CGRect {
        let rect=MotionStretch.rect(now:now,earlier:earlier,profile:profile,settings:settings)
        guard rect==now,settings.enabled else { return rect }
        let a=CGPoint(x:now.midX,y:now.midY),b=CGPoint(x:earlier.midX,y:earlier.midY)
        let s=ExposureSample(now:a,earlier:b,frameInterval:profile.frameInterval,mmPerPoint:profile.mmPerPoint,settings:settings)
        guard s.gate>0 else { return now }
        let dx=(b.x-a.x)*s.gate,dy=(b.y-a.y)*s.gate
        return CGRect(x:now.minX+min(0,dx),y:now.minY+min(0,dy),width:now.width+abs(dx),height:now.height+abs(dy))
    }
    @MainActor static func apply(_ sample:ExposureSample,to trail:ChordTrail,now:CGRect,earlier:CGRect) {
        trail.layer.instanceCount=sample.count
        trail.layer.instanceTransform=chord(now:now,earlier:earlier,sample:sample)
        trail.layer.instanceColor=NSColor(white:1,alpha:sample.alpha).cgColor
    }
    /// The exact nth root of the affine map between two rectangles. ChordTrail supplies the sample/weights;
    /// this corrects its compound translation when a zoom and a translation share an off-centre pivot.
    static func chord(now: CGRect, earlier: CGRect, sample: ExposureSample) -> CATransform3D {
        guard sample.count > 1, now.width > 0, now.height > 0 else { return CATransform3DIdentity }
        let g = sample.gate, n = CGFloat(sample.count - 1)
        let target = CGRect(x: now.minX + (earlier.minX-now.minX)*g,
                            y: now.minY + (earlier.minY-now.minY)*g,
                            width: now.width + (earlier.width-now.width)*g,
                            height: now.height + (earlier.height-now.height)*g)
        func axis(_ a: CGFloat, _ b: CGFloat, _ origin: CGFloat, _ target: CGFloat) -> (CGFloat, CGFloat) {
            let scale = max(0.001, b/a), root = pow(scale, 1/n), translation = target-scale*origin
            return (root, abs(scale-1) < 1e-9 ? translation/n : translation*(root-1)/(scale-1))
        }
        let x = axis(now.width, target.width, now.minX, target.minX)
        let y = axis(now.height, target.height, now.minY, target.minY)
        return CATransform3DMakeAffineTransform(CGAffineTransform(a: x.0, b: 0, c: 0, d: y.0, tx: x.1, ty: y.1))
    }
    /// Allow for the largest, rather than average, gap of geometric zoom copies (all gaps <= 1.5 displayed pt).
    static func settings(now: CGRect, earlier: CGRect) -> ExposureSettings {
        var s = settings
        let ratios = [earlier.width/max(0.001,now.width), earlier.height/max(0.001,now.height)]
        let factor = ratios.reduce(CGFloat(1)) { result, r in
            let f = abs(r-1) < 1e-6 ? 1 : max(1,r)*abs(log(max(0.001,r)))/abs(r-1)
            return max(result,f)
        }
        s.spacing /= factor * 1.001
        return s
    }
    static func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x:center.x-size.width/2,y:center.y-size.height/2,width:size.width,height:size.height)
    }
    @MainActor static func keys(_ path: String, _ values: [Any], duration: Double,times:[Double]?=nil) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath:path); a.values=values
        a.keyTimes = times?.map { NSNumber(value:$0/max(1e-9,duration)) } ?? values.indices.map { NSNumber(value:Double($0)/Double(max(1,values.count-1))) }
        a.duration=duration; a.calculationMode = .linear
        return a
    }
    /// Finite driver-B ink motion. Replication is inside the current native pose, so old rectangles are first
    /// pulled back into that pose's coordinates. No display-link callback or glass copies.
    @MainActor static func install(on ink:M10FInkPlane, duration:Double, begin:Double,
                                   profile:DisplayProfile, pose:(Double)->CGRect) {
        ink.layer?.removeAnimation(forKey:"m10F.exposure");ink.trail.reset()
        let count=max(2,Int(ceil(duration/profile.frameInterval))+1),base=CGRect(origin:.zero,size:ink.bounds.size)
        guard base.width>0 else { return }
        var copies:[Any]=[],colors:[Any]=[],transforms:[Any]=[],hasExposure=false
        let times=(0..<count).map{min(duration,Double($0)*profile.frameInterval)}
        for i in 0..<count {
            let t=times[i],a=pose(t),b=pose(max(0,t-profile.frameInterval))
            let scale=a.width/base.width
            let old=CGRect(x:(b.minX-a.minX)/scale,y:(b.minY-a.minY)/scale,width:b.width/scale,height:b.height/scale)
            var metric=profile;metric.mmPerPoint *= Double(scale)
            var settings=settings(now:base,earlier:old);settings.spacing /= max(1,scale)
            let sample=i==count-1 ? .still:sample(now:base,earlier:old,profile:metric,settings:settings)
            hasExposure = hasExposure || sample.count>1
            copies.append(sample.count);colors.append(sample.instanceColor)
            transforms.append(NSValue(caTransform3D:chord(now:base,earlier:old,sample:sample)))
        }
        guard hasExposure else { return }
        let n=keys("instanceCount",copies,duration:duration,times:times);n.calculationMode = .discrete
        let c=keys("instanceColor",colors,duration:duration,times:times),t=keys("instanceTransform",transforms,duration:duration,times:times)
        let group=CAAnimationGroup();group.animations=[n,c,t];group.duration=duration
        group.beginTime=begin;group.fillMode = .backwards
        ink.trail.layer.add(group,forKey:"m10F.exposure")
    }
    @MainActor static func glyphMotion(trail:ChordTrail,duration:Double,timing:CAAnimation,profile:DisplayProfile,
                                       pose:(Double)->CGRect) {
        trail.layer.removeAnimation(forKey:"m10F.glyph");trail.reset()
        let count=max(2,Int(ceil(duration/profile.frameInterval))+1)
        var copies:[Any]=[],colors:[Any]=[],transforms:[Any]=[],active=false
        let times=(0..<count).map{min(duration,Double($0)*profile.frameInterval)}
        for i in 0..<count {
            let t=times[i],a=pose(t),b=pose(max(0,t-profile.frameInterval))
            let s=sample(now:a,earlier:b,profile:profile,settings:settings(now:a,earlier:b))
            active=active || s.count>1;copies.append(s.count);colors.append(s.instanceColor)
            transforms.append(NSValue(caTransform3D:chord(now:a,earlier:b,sample:s)))
        }
        guard active else { return }
        let n=keys("instanceCount",copies,duration:duration,times:times);n.calculationMode = .discrete
        let g=CAAnimationGroup();g.animations=[n,keys("instanceColor",colors,duration:duration,times:times),keys("instanceTransform",transforms,duration:duration,times:times)]
        g.duration=duration;g.beginTime=timing.beginTime;g.speed=timing.speed;g.fillMode=timing.fillMode
        trail.layer.add(g,forKey:"m10F.glyph")
    }
}

/// A non-glass backing. Native descendants keep their original controls, hit testing and AX identities.
/// In a sheet it contains labels/rows only, never the glass sibling.
@MainActor final class M10FInkPlane: NSView {
    let trail = ChordTrail()
    let accumulates:Bool
    private(set) var exposureSample=ExposureSample.still
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder:Bool { false }
    override func becomeFirstResponder()->Bool { false }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.arrow) }
    override func cursorUpdate(with event:NSEvent) { NSCursor.arrow.set() }
    override func makeBackingLayer() -> CALayer { accumulates ? trail.layer:CALayer() }
    override init(frame:NSRect) { accumulates=true;super.init(frame:frame); wantsLayer=true; trail.settings=M10FExposure.settings }
    init(frame:NSRect,accumulating:Bool) { accumulates=accumulating;super.init(frame:frame);wantsLayer=true;trail.settings=M10FExposure.settings }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func resetExposure() { trail.reset();exposureSample = .still }
    func expose(now:CGRect, earlier:CGRect, profile:DisplayProfile, enabled:Bool) {
        guard enabled, bounds.width>0, now.width>0 else { resetExposure(); return }
        let scale=now.width/bounds.width
        let old=CGRect(x:(earlier.minX-now.minX)/scale,y:(earlier.minY-now.minY)/scale,
                       width:earlier.width/scale,height:earlier.height/scale)
        let local=CGRect(origin:.zero,size:bounds.size)
        var metric=profile; metric.mmPerPoint *= Double(scale)
        trail.settings=M10FExposure.settings(now:local,earlier:old)
        // Spacing is in displayed points too.
        trail.settings.spacing /= max(1,scale)
        trail.update(now:local,earlier:old,profile:metric)
        exposureSample=M10FExposure.sample(now:local,earlier:old,profile:metric,settings:trail.settings)
        M10FExposure.apply(exposureSample,to:trail,now:local,earlier:old)
    }
}
