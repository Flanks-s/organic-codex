import AppKit

struct OverlayCurve: Equatable, Sendable {
    let x1: Float, y1: Float, x2: Float, y2: Float
    let duration: Double
    init(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ duration: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2; self.duration = duration
    }
    var timing: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: x1, y1, x2, y2) }
    /// The curve's value at `fraction` of its duration, as CAMediaTimingFunction evaluates it (for frame-driven motion).
    func value(at fraction: Double) -> Double {
        let x = min(1, max(0, fraction))
        let ax = 1 + 3 * Double(x1) - 3 * Double(x2), bx = 3 * Double(x2) - 6 * Double(x1), cx = 3 * Double(x1)
        let ay = 1 + 3 * Double(y1) - 3 * Double(y2), by = 3 * Double(y2) - 6 * Double(y1), cy = 3 * Double(y1)
        func sx(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        var t = x
        for _ in 0..<8 {
            let dx = (3 * ax * t + 2 * bx) * t + cx, error = sx(t) - x
            if abs(error) < 1e-7 { break }
            if abs(dx) < 1e-6 { break }
            t -= error / dx
        }
        if abs(sx(t) - x) > 1e-5 {
            var lo = 0.0, hi = 1.0; t = x
            for _ in 0..<40 { if sx(t) < x { lo = t } else { hi = t }; t = (lo + hi) / 2 }
        }
        return ((ay * t + by) * t + cy) * t
    }
}
/// Product LyricKit.swift:26–59 and SendOptions.swift:31,126. Values are copied, not retuned.
enum OverlayMotion {
    static let glide = OverlayCurve(0.22, 1.2, 0.36, 1, 0.55)
    static let grow = OverlayCurve(0.3, 1.2, 0.5, 1, 0.4)
    static let rise = OverlayCurve(0.2, 1, 0.35, 1, 0.42)
    static let morphIn = OverlayCurve(0.2, 1.28, 0.36, 1, 0.46)
    static let morphOut = OverlayCurve(0.5, 0, 0.8, 0.4, 0.22)
    static let blurIn = OverlayCurve(0.2, 1, 0.3, 1, 0.38)
    static let blurOut = OverlayCurve(0.42, 0, 1, 1, 0.23)
    static let closeFade = OverlayCurve(0.42, 0, 1, 1, 0.16)
    static let closeSink = OverlayCurve(0.42, 0, 1, 1, 0.20)
    static let closeExtras = OverlayCurve(0, 0, 0.58, 1, 0.05)
    static let glideFast = OverlayCurve(0.2, 1.15, 0.35, 1, 0.38)
    static let growFast = OverlayCurve(0.3, 1.2, 0.5, 1, 0.3)
    static let capIn = OverlayCurve(0.25, 1.3, 0.45, 1, 0.5)
    static let knob = OverlayCurve(0.3, 1.4, 0.5, 1, 0.26)
    static let fill = OverlayCurve(0.3, 1.4, 0.5, 1, 0.30)
    static let thicken = OverlayCurve(0.3, 1.35, 0.5, 1, 0.20)
    static let lens = OverlayCurve(0.3, 1.5, 0.5, 1, 0.22)
    static let lensSlide = OverlayCurve(0.3, 1.4, 0.5, 1, 0.32)
    static let letterIn = OverlayCurve(0.2, 1.3, 0.4, 1, 0.46)
    static let letterOut = OverlayCurve(0.5, 0, 0.8, 0.5, 0.22)
    static let stagger = 0.028
    static let hold = 0.350
    static func ease(_ seconds: Double) -> OverlayCurve { OverlayCurve(0.25, 0.1, 0.25, 1, seconds) }
    static func sendSpring() -> CASpringAnimation { spring(response: 0.36, damping: 0.84) }
    static func pressSpring() -> CASpringAnimation { spring(response: 0.22, damping: 0.55) }
    private static func spring(response: Double, damping: Double) -> CASpringAnimation {
        let a = CASpringAnimation(); let omega = 2 * Double.pi / response
        a.mass = 1; a.stiffness = omega * omega; a.damping = 2 * damping * omega; a.duration = a.settlingDuration
        return a
    }
    @MainActor private static let sceneOwners = NSMapTable<CALayer, OverlaySurface>.weakToWeakObjects()
    @MainActor static func register(_ surface: OverlaySurface) { func add(_ v:NSView) {if let layer=v.layer {sceneOwners.setObject(surface,forKey:layer)};v.subviews.forEach(add)};add(surface) }
    @MainActor static func mediaTime(for view: NSView) -> Double {
        var node: NSView? = view
        while let current = node {
            if let surface=current as? OverlaySurface { return surface.sceneTime?() ?? surface.sceneClock.mediaTime() }
            node=current.superview
        }
        return CACurrentMediaTime()
    }
    @MainActor static func registerContainingSurface(for view: NSView) {
        var node: NSView? = view
        while let current=node {if let surface=current as? OverlaySurface {register(surface);return};node=current.superview}
    }
    @MainActor static func mediaTime(for layer: CALayer) -> Double {
        var node: CALayer? = layer
        while let current = node {
            if let surface = sceneOwners.object(forKey:current) ?? current.delegate as? OverlaySurface { return surface.sceneTime?() ?? surface.sceneClock.mediaTime() }
            node = current.superlayer
        }
        return CACurrentMediaTime()
    }
    /// Sample the submitted CA track before changing its coordinate space. This also works before the
    /// render server has produced a presentation layer, and with the offscreen scene's virtual clock.
    @MainActor static func scalar(_ layer: CALayer, _ key: String) -> CGFloat {
        let path = OverlayExposure.path(of: layer, origin: mediaTime(for: layer))
        return path.scalars[key]?.value(at: 0) ?? (layer.value(forKeyPath: key) as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    }
    @MainActor static func animate(_ layer: CALayer, _ key: String, from: Any, to: Any, curve: OverlayCurve, delay: Double = 0, enabled: Bool = true, retarget: Bool = true) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let previous = retarget ? (layer.presentation()?.value(forKeyPath: key) ?? from) : from
        layer.setValue(to, forKeyPath: key)
        if enabled {
            let a = CABasicAnimation(keyPath: key); a.fromValue = previous; a.toValue = to
            a.duration = curve.duration; a.timingFunction = curve.timing
            a.beginTime = layer.convertTime(mediaTime(for: layer), from: nil) + delay; a.fillMode = .backwards
            layer.add(a, forKey: "overlay." + key)
            if key.hasPrefix("filters."), key.hasSuffix(".inputRadius") {
                OverlayFilter.enabledTrack(on: layer, radiusKey: key, begin: a.beginTime, duration: a.duration, final: (to as? NSNumber)?.doubleValue ?? 0)
            }
        } else { layer.removeAnimation(forKey: "overlay." + key) }
        CATransaction.commit()
    }
    @MainActor static func entrance(_ view: NSView, order: Int = 0, blur: CGFloat = 4, rise: CGFloat = 18, scale: CGFloat = 1,
                                    curve: OverlayCurve = OverlayMotion.rise, delay: Double = 0, enabled: Bool = true) {
        (view as? OverlayAccumulatingView)?.prepareMotion()
        guard let layer = (view as? OverlayAccumulatingView)?.motionLayer ?? view.layer else { return }
        let d = delay + Double(order) * stagger
        animate(layer, "transform.translation.y", from: rise, to: 0, curve: curve, delay: d, enabled: enabled, retarget: false)
        if scale != 1 { animate(layer, "transform.scale", from: scale, to: 1, curve: curve, delay: d, enabled: enabled, retarget: false) }
        animate(layer, "opacity", from: 0, to: layer.opacity, curve: curve, delay: d, enabled: enabled, retarget: false)
        OverlayFilter.installBlur(on: layer)
        if layer.filters?.isEmpty == false { animate(layer, "filters.overlayBlur.inputRadius", from: blur, to: 0, curve: curve, delay: d, enabled: enabled, retarget: false) }
        (view as? OverlayAccumulatingView)?.accumulate(enabled: enabled && OverlayZoom.selected == .accum)
    }
}

@MainActor enum OverlayFilter {
    static var available: Bool { NSClassFromString("CAFilter") != nil }
    static func make(_ type: String, values: [String: Any]) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("filterWithType:")),
              let value = cls.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject else { return nil }
        for (key, item) in values { value.setValue(item, forKey: key) }
        return value
    }
    /// Without edge normalisation: with it, a layer over nothing composited white inside and black around its corners
    /// while the radius was above 0 (Daybreak's white flash in the window, Claude, 2026-10-29; Peek's black boxes).
    static func enabledTrack(on layer: CALayer, radiusKey: String, begin: Double, duration: Double, final: Double) {
        let key = radiusKey.replacingOccurrences(of: ".inputRadius", with: ".enabled")
        layer.setValue(final > 0, forKeyPath: key)
        let a = CAKeyframeAnimation(keyPath: key); a.values = [true, final > 0]
        a.keyTimes = [0, NSNumber(value: max(0, 1 - 1 / (240 * max(0.01, duration)))), 1]
        a.calculationMode = .discrete; a.duration = duration; a.beginTime = begin; a.fillMode = .backwards
        layer.add(a, forKey: "overlay." + key)
    }
    static func installBlur(on layer: CALayer) {
        guard layer.filters?.isEmpty != false else { return }
        if let filter = make("gaussianBlur", values: ["inputRadius": 0, "name": "overlayBlur", "enabled": false]) { layer.filters = [filter] }
    }
}
