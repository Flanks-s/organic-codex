import AppKit
import QuartzCore

/// M10-E. The analytic pose remains the input to springs, hit testing and subsequent gestures. Only paint grows.
/// The four-corner step also catches a bar whose centre barely moves while one edge sweeps hundreds of points.
struct M10DockFrame {
    var name: String
    var time: Double
    var rect: CGRect
    var earlier: CGRect
    var painted: CGRect
    var exposure: ExposureSample
    var mmPerPoint: Double
    var treatmentEnabled = true
    var stepMM: Double { Double(MotionStep.edge(rect, earlier)) * mmPerPoint }
}

@MainActor enum M10DockMotion {
    static var enabled = ProcessInfo.processInfo.environment["DOCK_EXPOSURE"] != "0"
    static let orbExposureEnabled = ProcessInfo.processInfo.environment["M10_DOCK_ORBS"] != "0"
    static let dell = DisplayProfile(name: "Dell M10-E 60 Hz", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
    /// Optional bridge to M10-F's decoration-only exposure. No private Orb layers are inspected by Dock.
    /// Rectangles are in the component's common back/front plane; glass has ALREADY received its real frame.
    static var onOrbFrame: ((OrbComponent, M10DockFrame, DisplayProfile) -> Void)? = { orb, frame, profile in
        orb.exposeGlyphs(now: frame.rect, earlier: frame.earlier, profile: profile,
                         enabled: enabled && frame.treatmentEnabled && orbExposureEnabled)
    }

    static func profile(for view: NSView, override: DisplayProfile?) -> DisplayProfile {
        if let override { return override }
        if let screen = view.window?.screen ?? NSScreen.main { return .of(screen) }
        return dell // Detached/offscreen only. Live windows always use their own screen.
    }

    static func settings(for step: CGFloat, enabled: Bool) -> ExposureSettings {
        var s = ExposureSettings(); s.enabled = enabled
        // 40 copies is a default, not a licence to leave gaps on a fast drag. Per-copy spacing stays <= 1.5 pt.
        s.maxCopies = max(s.maxCopies, 1 + Int(ceil(step / s.spacing)))
        return s
    }

    static func exposure(now: CGRect, earlier: CGRect, profile: DisplayProfile, settings: ExposureSettings) -> ExposureSample {
        var s = ExposureSample(now: now, earlier: earlier, frameInterval: profile.frameInterval, mmPerPoint: profile.mmPerPoint, settings: settings)
        // The common helper has a 0.01 pt numerical guard. Refusal crosses onset by only .02 mm on two Dell frames:
        // its tail is .00185 pt. Preserve even that tail, rather than introducing a second, unapproved onset.
        if s.gate > 0, s.length > 0, s.count == 1 {
            s.count = 2; s.alpha = 1-sqrt(0.1*s.gate); s.delayStep = Double(s.gate)*profile.frameInterval
        }
        return s
    }

    @discardableResult static func update(_ trail: ChordTrail, now: CGRect, earlier: CGRect,
                                         profile: DisplayProfile, enabled: Bool) -> ExposureSample {
        trail.settings = settings(for: MotionStep.edge(now,earlier), enabled: enabled)
        trail.update(now: now, earlier: earlier, profile: profile)
        let s = exposure(now: now, earlier: earlier, profile: profile, settings: trail.settings)
        if s.count > 1, trail.sample.count == 1, now.width > 0, now.height > 0 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            var t = CATransform3DMakeTranslation(now.midX,now.midY,0)
            t = CATransform3DTranslate(t,(earlier.midX-now.midX)*s.gate,(earlier.midY-now.midY)*s.gate,0)
            t = CATransform3DScale(t,pow(max(0.01,earlier.width/now.width),s.gate),pow(max(0.01,earlier.height/now.height),s.gate),1)
            t = CATransform3DTranslate(t,-now.midX,-now.midY,0)
            trail.layer.instanceCount = 2; trail.layer.instanceTransform = t
            trail.layer.instanceColor = NSColor(white:1,alpha:s.alpha).cgColor
        }
        return s
    }

    static func frame(name: String, now: CGRect, earlier: CGRect, time: Double,
                      profile: DisplayProfile, enabled: Bool) -> M10DockFrame {
        let step = MotionStep.edge(now, earlier)
        let settings = settings(for: step, enabled: enabled)
        let exposure = exposure(now: now, earlier: earlier, profile: profile, settings: settings)
        // MotionStretch takes a centre displacement. Use the farthest corner's equivalent displacement so pure
        // width/scale changes get exactly the SAME physical gate as glyphs. The leading edge stays where it is.
        let a = [CGPoint(x: now.minX, y: now.minY), CGPoint(x: now.maxX, y: now.minY),
                 CGPoint(x: now.minX, y: now.maxY), CGPoint(x: now.maxX, y: now.maxY)]
        let b = [CGPoint(x: earlier.minX, y: earlier.minY), CGPoint(x: earlier.maxX, y: earlier.minY),
                 CGPoint(x: earlier.minX, y: earlier.maxY), CGPoint(x: earlier.maxX, y: earlier.maxY)]
        var index = 0
        for i in 1..<4 where hypot(a[i].x-b[i].x, a[i].y-b[i].y) > hypot(a[index].x-b[index].x, a[index].y-b[index].y) { index = i }
        let previous = now.offsetBy(dx: b[index].x-a[index].x, dy: b[index].y-a[index].y)
        var painted = MotionStretch.rect(now: now, earlier: previous, profile: profile, settings: settings)
        if exposure.length > 0, painted == now {
            let dx=(previous.midX-now.midX)*exposure.gate,dy=(previous.midY-now.midY)*exposure.gate
            painted=MotionStretch.limited(CGRect(x:now.minX+min(0,dx),y:now.minY+min(0,dy),width:now.width+abs(dx),height:now.height+abs(dy)),now:now)
        }
        return .init(name: name, time: time, rect: now, earlier: earlier, painted: painted,
                     exposure: exposure, mmPerPoint: profile.mmPerPoint, treatmentEnabled: enabled)
    }
}

/// One observation per display frame. No interpolated replacement for a dropped frame, no velocity limiter.
@MainActor final class M10DockHistory {
    private(set) var rect: CGRect?
    private var earlier: CGRect?
    private var time: Double?
    var observationTime: Double? {time}
    func shiftClock(by delta: Double) {if time != nil {time! += delta}}
    func reset(_ rect: CGRect? = nil) { self.rect = rect; earlier = rect; time = nil }
    /// A commit adopts the last written observation, including its incoming shutter sample.
    /// Only its epoch changes; the next advancing callback consumes history normally.
    func adoptEpoch(at now: Double) { if time != nil { time = now } }
    func update(_ next: CGRect, at now: Double, name: String, profile: DisplayProfile, enabled: Bool) -> M10DockFrame {
        let previous: CGRect
        if let t = time, now >= t, now-t < profile.frameInterval * 0.25 {
            previous = earlier ?? rect ?? next // layout/hit feedback in the SAME frame must not consume exposure twice.
        } else if let t = time, now < t {
            previous = next // A new clock epoch. Visibility owners reset explicitly; long frame gaps are NEVER suppressed.
        } else { previous = rect ?? next }
        earlier = previous; rect = next; time = now
        return M10DockMotion.frame(name: name, now: next, earlier: previous, time: now, profile: profile, enabled: enabled)
    }
}

/// Native paint is captured when its semantic content/layout changes, never on every frame. The native source remains
/// mounted (selection, responder, AX and callbacks stay native); only its layer's paint is withdrawn while gated.
/// Do not pass a glass view or a view containing glass. Editors under IME must not be passed here either.
@MainActor final class M10DockGlyph {
    let trail = ChordTrail()
    private let image = CALayer()
    private weak var source: NSView?
    private var bitmap: CGImage?
    private var inkRect=CGRect.zero
    private var scale: CGFloat = 1
    private var key = ""
    init() {
        trail.layer.anchorPoint = .zero; trail.layer.isHidden = true
        image.anchorPoint = .zero; trail.layer.addSublayer(image)
    }
    var isActive: Bool { !trail.layer.isHidden && trail.layer.instanceCount > 1 }
    @discardableResult func prepare(_ view: NSView, key: String, scale: CGFloat, imageOverride: (() -> CGImage)? = nil) -> Bool {
        guard self.key != key || self.scale != scale || bitmap == nil else { return false }
        reset(); self.source = view; self.key = key; self.scale = scale
        guard view.bounds.width > 0, view.bounds.height > 0 else { bitmap = nil; return true }
        let full=imageOverride?() ?? M10DockPicture.draw(view,scale:scale,plates:false)
        let tight=full.flatMap{M10DockPicture.tight($0,scale:scale)}
        bitmap=tight?.image;inkRect=tight?.rect ?? .zero
        image.contents = bitmap; image.contentsScale = scale
        ReplicaContainerAudit.register(image,material:.glyph,note:"Dock own-draw transparent glyphs; tight independent alpha storage")
        return true
    }
    func update(_ view: NSView, in host: NSView, world: CGRect, earlier: CGRect, profile: DisplayProfile, enabled: Bool, hideSource: Bool = true, opacity: Float = 1) {
        let sourceOpacity = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
        guard bitmap != nil, enabled, sourceOpacity*opacity > 0, !view.isHidden,
              MotionStep.edge(world, earlier) * profile.mmPerPoint > 1.08 else { reset(); return }
        guard let parent = host.layer else { reset(); return }
        if trail.layer.superlayer !== parent { parent.addSublayer(trail.layer) }
        let local = view.convert(view.bounds, to: host)
        trail.layer.frame = host.bounds
        let sx=local.width/max(1,view.bounds.width),sy=local.height/max(1,view.bounds.height)
        image.frame=CGRect(x:local.minX+inkRect.minX*sx,y:local.minY+inkRect.minY*sy,width:inkRect.width*sx,height:inkRect.height*sy)
        image.opacity = sourceOpacity*opacity
        let applied = M10DockMotion.update(trail, now: local, earlier: CGRect(x: local.minX + earlier.minX-world.minX,
                                               y: local.minY + earlier.minY-world.minY,
                                               width: earlier.width, height: earlier.height), profile: profile, enabled: enabled)
        trail.layer.isHidden = applied.count == 1
        view.layer?.isHidden = hideSource && applied.count > 1
        source = view
    }
    func reset() {
        source?.layer?.isHidden = false
        trail.reset(); trail.layer.isHidden = true
    }
}

/// Render-server exposure for Peek's EXISTING row entrance. The native 3 pt blur and opacity tracks are untouched.
/// Typical 18 pt / .55 s entrances stay below onset on Dell; a faster/longer path still gets continuous accumulation.
@MainActor enum M10DockRowTrail {
    static func frames(distance: CGFloat, response: Double, damping: Double, profile: DisplayProfile) -> [(Double, CGRect, ExposureSample)] {
        let spring = Spring(from: Double(distance), to: 0, response: response, damping: damping, epsilon: 0.00001)
        let count = max(1, Int(ceil(spring.duration/profile.frameInterval)))
        return (0...count).map { i in
            let t = min(spring.duration, Double(i)*profile.frameInterval)
            let now = CGRect(x: 0, y: spring.sample(t).value, width: 200, height: 22)
            let before = CGRect(x: 0, y: spring.sample(max(0, t-profile.frameInterval)).value, width: 200, height: 22)
            let s = M10DockMotion.settings(for: MotionStep.edge(now,before), enabled: M10DockMotion.enabled)
            return (t,now,M10DockMotion.exposure(now: now, earlier: before, profile: profile, settings: s))
        }
    }
    static func install(on row: CALayer, distance: CGFloat, response: Double, damping: Double,
                        profile: DisplayProfile, begin: Double) -> CAReplicatorLayer? {
        if M10DockZoom.gaussian {
            for key in ["opacity", "filters.peekBlur.inputRadius"] { row.removeAnimation(forKey: "peek.entrance." + key) }
            row.filters = nil
            let effect = ContentGaussianTransition(content: row, clock: SceneClock(), initiallyVisible: false)
            effect.setVisible(true, at: begin)
            // Captures only this controller; no per-frame layout or baking, and stale completions cannot clear a new plan.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, begin-CACurrentMediaTime()) + 0.11) { effect.settle() }
            return nil
        }
        let samples = frames(distance: distance, response: response, damping: damping, profile: profile)
        guard samples.contains(where: { $0.2.count > 1 }), let parent = row.superlayer,
              let duration = samples.last?.0, duration > 0 else { return nil }
        let trail = CAReplicatorLayer(); trail.anchorPoint = .zero; trail.frame = parent.bounds
        parent.insertSublayer(trail, above: row); trail.addSublayer(row)
        trail.instanceCount = 1; trail.instanceColor = NSColor.white.cgColor
        let normalized = samples.map { NSNumber(value: $0.0/duration) }
        for (key, values) in [("instanceCount",samples.map { NSNumber(value: $0.2.count) as Any }),
                              ("instanceDelay",samples.map { NSNumber(value: $0.2.delayStep) as Any }),
                              ("instanceColor",samples.map { $0.2.instanceColor as Any })] {
            let a = CAKeyframeAnimation(keyPath: key)
            if key == "instanceCount" { a.values = Array(values.dropLast()); a.calculationMode = .discrete }
            else { a.values = values; a.calculationMode = .linear }
            a.keyTimes = normalized; a.duration = duration; a.beginTime = trail.convertTime(begin, from: nil)
            trail.add(a, forKey: "m10.dock."+key)
        }
        return trail
    }
}

/// A CA glyph bitmap can be accumulated directly, without a native snapshot. The original hierarchy is restored as
/// soon as the gate closes. This is used for user-scrolled Peek lines; dots are deliberately NOT put in a replicator.
@MainActor final class M10DockLayerGlyph {
    let trail = ChordTrail()
    private weak var glyph: CALayer?
    private weak var parent: CALayer?
    func update(_ glyph: CALayer, world: CGRect, earlier: CGRect, profile: DisplayProfile, enabled: Bool) {
        let settings = M10DockMotion.settings(for: MotionStep.edge(world, earlier), enabled: enabled)
        let sample = M10DockMotion.exposure(now: world, earlier: earlier, profile: profile, settings: settings)
        guard sample.count > 1 else { reset(); return }
        if self.glyph !== glyph {
            reset(); self.glyph = glyph; parent = glyph.superlayer
            if let parent { trail.layer.anchorPoint = .zero; trail.layer.frame = parent.bounds; parent.insertSublayer(trail.layer, above: glyph); trail.layer.addSublayer(glyph) }
        }
        let local = glyph.frame
        M10DockMotion.update(trail, now: local, earlier: local.offsetBy(dx: earlier.minX-world.minX, dy: earlier.minY-world.minY), profile: profile, enabled: enabled)
    }
    func reset() {
        if let glyph, let parent, glyph.superlayer === trail.layer { parent.insertSublayer(glyph, above: trail.layer) }
        trail.layer.removeFromSuperlayer(); trail.reset(); glyph = nil; parent = nil
    }
}
