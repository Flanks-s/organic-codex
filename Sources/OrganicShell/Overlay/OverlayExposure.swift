import AppKit

/// M10.1: AppKit's native tree is NEVER under a replicator. Only tight, transparent glyph textures are copied.
@MainActor class OverlayAccumulatingView: OverlayView {
    let ink = OverlayInkView()
    private(set) var exposureFrames: [OverlayExposureFrame] = []
    private var glyphExposure: OverlayGlyphExposure?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; ink.wantsLayer = true; addSubview(ink)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var motionLayer: CALayer { ink.layer! }
    override func layout() { super.layout(); prepareMotion() }
    func prepareMotion() {
        guard ink.frame != bounds else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let transform = ink.layer?.transform; ink.frame = bounds
        if let transform { ink.layer?.transform = transform }
        CATransaction.commit()
    }
    func resetExposure() {
        glyphExposure?.reset(); glyphExposure = nil; exposureFrames = []
        func retire(_ view: NSView) {
            if let child = view as? OverlayAccumulatingView { child.resetExposure() }
            else { view.subviews.forEach(retire) }
        }
        ink.subviews.forEach(retire)
    }
    func accumulate(carrier: CALayer? = nil, enabled: Bool = true) {
        prepareMotion(); resetExposure()
        guard enabled && OverlayExposure.enabled else { return }
        let effect = OverlayGlyphExposure(view: self, profile: OverlayExposure.profile(for: self), origin: OverlayMotion.mediaTime(for: self))
        glyphExposure = effect; exposureFrames = effect.frames
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { resetExposure() }
        super.viewWillMove(toSuperview: newSuperview)
    }
}
@MainActor final class OverlayInkView: OverlayView {
    var paint: ((NSRect) -> Void)?
    override func draw(_ dirtyRect: NSRect) { paint?(dirtyRect) }
}

/// Kept for source compatibility; containers no longer acquire any exposure texture or copies (#56).
@MainActor final class OverlaySnapshotExposure {
    let layer = CALayer()
    init() { layer.opacity = 0 }
    func reset() { layer.removeAllAnimations(); layer.sublayers?.forEach { $0.removeFromSuperlayer() }; layer.removeFromSuperlayer() }
    static func bitmap(_ view: NSView) -> CGImage { NativeViewBitmap.capture(view, scale: 1) }
    func install(view: NSView, enabled: Bool) { reset() }
}

struct OverlayExposureFrame {
    var time: Double
    var rect: CGRect
    var sample: ExposureSample
    var spacing: CGFloat
    var coverage: CGFloat
}

/// The very same CA scalar paths, evaluated once when submitted, not on the main thread each frame.
struct OverlayScalarPath {
    var values: [CGFloat], times: [Double], curves: [OverlayCurve], start: Double, duration: Double
    var spring: (omega: Double, damping: Double, velocity: Double)?
    func value(at time: Double) -> CGFloat {
        guard let first = values.first, let last = values.last else { return 0 }
        if time <= start { return first }; if time >= start + duration { return last }
        let t = (time - start) / max(1e-9, duration)
        if let s = spring {
            let seconds = time - start, a = s.omega * s.damping
            let wd = s.omega * sqrt(max(1e-9, 1 - s.damping * s.damping))
            let progress = 1 - exp(-a * seconds) * (cos(wd * seconds) + (a - s.velocity) / wd * sin(wd * seconds))
            return first + (last - first) * progress
        }
        let i = max(0, min(values.count - 2, times.lastIndex(where: { $0 <= t }) ?? 0))
        let u = (t - times[i]) / max(1e-9, times[i + 1] - times[i])
        let p = curves.isEmpty ? u : curves[min(i, curves.count - 1)].value(at: u)
        return values[i] + (values[i + 1] - values[i]) * p
    }
}

struct OverlayBoxPath {
    var bounds: CGRect, position: CGPoint, anchor: CGPoint
    var scalars: [String: OverlayScalarPath]
    var modelScaleX: CGFloat = 1, modelScaleY: CGFloat = 1
    var duration: Double { scalars.values.map { $0.start + $0.duration }.max() ?? 0 }
    func rect(at time: Double) -> CGRect {
        func v(_ key: String, _ fallback: CGFloat) -> CGFloat { scalars[key]?.value(at: time) ?? fallback }
        let uniform = scalars["transform.scale"] != nil
        let scale = v("transform.scale", 1), sx = scale * v("transform.scale.x", uniform ? 1 : modelScaleX), sy = scale * v("transform.scale.y", uniform ? 1 : modelScaleY)
        let p = CGPoint(x: position.x + v("transform.translation.x", 0), y: position.y + v("transform.translation.y", 0))
        return CGRect(x: p.x - anchor.x * bounds.width * sx, y: p.y - anchor.y * bounds.height * sy,
                      width: bounds.width * sx, height: bounds.height * sy)
    }
}

@MainActor private final class OverlayExposureRecord {
    let origin: Double, frames: [OverlayExposureFrame]
    init(origin: Double, frames: [OverlayExposureFrame]) { self.origin = origin; self.frames = frames }
    func at(_ time: Double) -> OverlayExposureFrame? { frames.last(where: { $0.time <= time }) }
}

@MainActor enum OverlayExposure {
    private static let records = NSMapTable<CAReplicatorLayer, OverlayExposureRecord>.weakToStrongObjects()
    static var enabled = ProcessInfo.processInfo.environment["OVERLAY_EXPOSURE"] != "0"
    #if OVERLAY_SELFTEST
    static var preparationTimesMS: [Double] = []
    #endif
    static let dell = DisplayProfile(name: "Dell 60 Hz verification", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
    static func profile(for view: NSView) -> DisplayProfile {
        var node: NSView? = view
        while let current = node {
            if let surface = current as? OverlaySurface, let profile = surface.exposureProfile { return profile }
            node = current.superview
        }
        if let screen = view.window?.screen ?? NSScreen.main { return DisplayProfile.of(screen) }
        return dell // Headless only; tests explicitly inject Dell, never infer the host's screen.
    }
    static func path(of layer: CALayer, origin: Double) -> OverlayBoxPath {
        var scalars: [String: OverlayScalarPath] = [:]
        for name in (layer.animationKeys() ?? []).sorted() where !name.hasPrefix("overlay.exposure.") {
            guard let animation = layer.animation(forKey: name) as? CAPropertyAnimation, let key = animation.keyPath,
                  (key.hasPrefix("transform.") || key == "opacity" || (key.hasPrefix("filters.") && key.hasSuffix(".inputRadius"))), animation.duration > 0 else { continue }
            let start = animation.beginTime == 0 ? 0 : animation.beginTime - layer.convertTime(origin, from: nil)
            let curve: (CAMediaTimingFunction?) -> OverlayCurve = { timing in
                guard let timing else { return .init(0, 0, 1, 1, 1) }
                var a = [Float](repeating: 0, count: 2), b = a
                timing.getControlPoint(at: 1, values: &a); timing.getControlPoint(at: 2, values: &b)
                return .init(a[0], a[1], b[0], b[1], 1)
            }
            if let a = animation as? CABasicAnimation, let from = a.fromValue as? NSNumber, let to = a.toValue as? NSNumber {
                var p = OverlayScalarPath(values: [CGFloat(truncating: from), CGFloat(truncating: to)], times: [0, 1],
                                          curves: [curve(a.timingFunction)], start: start, duration: a.duration)
                if let a = a as? CASpringAnimation {
                    let omega = sqrt(a.stiffness / a.mass)
                    p.spring = (omega, a.damping / (2 * sqrt(a.stiffness * a.mass)), a.initialVelocity)
                }
                scalars[key] = p
            } else if let a = animation as? CAKeyframeAnimation, let values = a.values as? [NSNumber], values.count >= 2 {
                scalars[key] = .init(values: values.map { CGFloat(truncating: $0) },
                                     times: a.keyTimes?.map(\.doubleValue) ?? values.indices.map { Double($0) / Double(values.count - 1) },
                                     curves: (a.timingFunctions ?? []).map { curve($0) }, start: start, duration: a.duration)
            }
        }
        return .init(bounds: layer.bounds, position: layer.position, anchor: layer.anchorPoint, scalars: scalars, modelScaleX: layer.transform.m11, modelScaleY: layer.transform.m22)
    }
    static func frames(path: OverlayBoxPath, profile: DisplayProfile, enabled: Bool) -> [OverlayExposureFrame] {
        frames(duration: path.duration, profile: profile, enabled: enabled, rect: { path.rect(at: $0) })
    }
    static func frames(duration: Double, profile: DisplayProfile, enabled: Bool, rect: (Double) -> CGRect) -> [OverlayExposureFrame] {
        let dt = profile.frameInterval, end = max(0, duration), rate = max(120, 2 / dt)
        var settings = ExposureSettings(); settings.enabled = enabled; settings.maxCopies = 512
        let count = max(1, Int(ceil((end + dt) * rate)))
        return (0...count).map { i in
            let time = Double(i) / rate, now = rect(time), earlier = rect(max(0, time - dt))
            var sample = ExposureSample(now: now, earlier: earlier, frameInterval: dt, mmPerPoint: profile.mmPerPoint, settings: settings)
            guard sample.count > 1 else { return .init(time: time, rect: now, sample: sample, spacing: 0, coverage: 0) }
            // A time fraction is not a distance fraction on an accelerating curve. Solve the actual look-back, then
            // increase copies until every adjacent pair on that exact CA path is within 1.5 pt (including zoom).
            let goal = sample.length
            var lo = 0.0, hi = dt
            for _ in 0..<22 {
                let mid = (lo + hi) / 2
                if MotionStep.edge(now, rect(max(0, time - mid))) < goal { lo = mid } else { hi = mid }
            }
            // The composed leaf path can reverse inside one frame; never let a non-monotone bisection
            // undershoot the requested exposure. The full physical frame is the conservative valid bound.
            if MotionStep.edge(now, rect(max(0, time - hi))) + 1e-7 < goal { hi = dt }
            var n = sample.count, spacing: CGFloat = 0
            repeat {
                spacing = 0
                for k in 1..<n {
                    spacing = max(spacing, MotionStep.edge(rect(max(0, time - hi * Double(k - 1) / Double(n - 1))),
                                                         rect(max(0, time - hi * Double(k) / Double(n - 1)))))
                }
                if spacing > settings.spacing + 1e-6 { n += 1 }
            } while spacing > settings.spacing + 1e-6 && n < settings.maxCopies
            sample.count = n; sample.delayStep = hi / Double(n - 1)
            sample.alpha = CGFloat(1 - pow(0.1 * Double(sample.gate), 1 / Double(n)))
            return .init(time: time, rect: now, sample: sample, spacing: spacing,
                         coverage: MotionStep.edge(now, rect(max(0, time - hi))))
        }
    }
    @discardableResult static func install(on layer: CAReplicatorLayer, carrier: CALayer, profile: DisplayProfile,
                                           enabled: Bool, origin: Double = CACurrentMediaTime()) -> [OverlayExposureFrame] {
        #if OVERLAY_SELFTEST
        let prepStart = CACurrentMediaTime()
        defer { preparationTimesMS.append((CACurrentMediaTime() - prepStart) * 1000) }
        #endif
        reset(layer)
        func restoreNested(_ node: CALayer) {
            if let child = node as? CAReplicatorLayer, let saved = records.object(forKey: child) {
                write(child, frames: saved.frames, origin: saved.origin)
            }
            node.sublayers?.forEach(restoreNested)
        }
        carrier.sublayers?.forEach(restoreNested)
        guard enabled && Self.enabled else { return [] }
        let path = path(of: carrier, origin: origin), samples = frames(path: path, profile: profile, enabled: true)
        guard samples.contains(where: { $0.sample.count > 1 }), let last = samples.last, last.time > 0 else { return samples }
        let record = OverlayExposureRecord(origin: origin, frames: samples)
        records.setObject(record, forKey: layer)
        // Suppress nested exposure ONLY while the parent is gated. Late staggered letters keep their own
        // exposure after the parent slows down; cancelling their whole timeline silently lost that tail.
        func maskNested(_ node: CALayer) {
            if let child = node as? CAReplicatorLayer, let saved = records.object(forKey: child) {
                let end = max(last.time, saved.origin - origin + (saved.frames.last?.time ?? 0))
                let rate = max(120, 2 / profile.frameInterval), n = Int(ceil(end * rate))
                let merged = (0...n).map { i -> OverlayExposureFrame in
                    let t = Double(i) / rate
                    var frame = saved.at(origin + t - saved.origin) ?? .init(time: t, rect: .zero, sample: .still, spacing: 0, coverage: 0)
                    frame.time = t
                    if (record.at(t)?.sample.count ?? 1) > 1 { frame.sample = .still; frame.spacing = 0; frame.coverage = 0 }
                    return frame
                }
                write(child, frames: merged, origin: origin)
            }
            node.sublayers?.forEach(maskNested)
        }
        carrier.sublayers?.forEach(maskNested)
        write(layer, frames: samples, origin: origin)
        return samples
    }
    static func write(_ layer: CAReplicatorLayer, frames samples: [OverlayExposureFrame], origin: Double) {
        guard let last = samples.last, last.time > 0 else { return }
        // CA stores discrete key times at float precision. At an exact display boundary it could select
        // the previous envelope (one extra smear frame below onset). Bias interior envelope keys by 1us;
        // geometry, duration, and endpoint keys are unchanged.
        let times = samples.enumerated().map { i, frame in
            NSNumber(value: i == 0 ? 0 : i == samples.count - 1 ? 1 : max(0, (frame.time - 0.000001) / last.time))
        }
        func track(_ key: String, _ values: [Any], discrete: Bool) {
            let a = CAKeyframeAnimation(keyPath: key); a.values = discrete ? Array(values.dropLast()) : values; a.duration = last.time
            a.beginTime = layer.convertTime(origin, from: nil); a.calculationMode = discrete ? .discrete : .linear
            a.keyTimes = times
            layer.add(a, forKey: "overlay.exposure." + key)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track("instanceCount", samples.map { NSNumber(value: $0.sample.count) }, discrete: true)
        track("instanceDelay", samples.map { NSNumber(value: $0.sample.delayStep) }, discrete: true)
        track("instanceColor", samples.map { $0.sample.instanceColor }, discrete: true)
        CATransaction.commit()
    }
    static func reset(_ layer: CAReplicatorLayer) {
        records.removeObject(forKey: layer)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for key in layer.animationKeys() ?? [] where key.hasPrefix("overlay.exposure.") { layer.removeAnimation(forKey: key) }
        layer.instanceCount = 1; layer.instanceDelay = 0; layer.instanceTransform = CATransform3DIdentity; layer.instanceColor = NSColor.white.cgColor
        CATransaction.commit()
    }
}

/// A glass sweep uses the farthest corner's physical gate. Direction comes from its centre; unlike a glyph it is
/// one real, longer frame with semicircular ends. Text keeps the NOMINAL geometry, never the stretched glass's size.
enum OverlayGlassExposure {
    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let grid = max(1, scale)
        let x = floor(rect.minX * grid) / grid, y = floor(rect.minY * grid) / grid
        return CGRect(x: x, y: y, width: ceil(rect.maxX * grid) / grid - x, height: ceil(rect.maxY * grid) / grid - y)
    }
    static func rect(now: CGRect, earlier: CGRect, profile: DisplayProfile, enabled: Bool = true) -> CGRect {
        var settings = ExposureSettings(); settings.enabled = enabled
        let sample = ExposureSample(now: now, earlier: earlier, frameInterval: profile.frameInterval, mmPerPoint: profile.mmPerPoint, settings: settings)
        guard sample.count > 1 else { return now }
        var dx = earlier.midX - now.midX, dy = earlier.midY - now.midY
        if hypot(dx, dy) < 1e-8 { dx = earlier.width - now.width; dy = earlier.height - now.height }
        let length = hypot(dx, dy); guard length > 1e-8 else { return now }
        // Feed MotionStretch a centre displacement equal to the edge sweep, so grow-only motion is gated too.
        let edge = sample.stepPt
        let proxy = now.offsetBy(dx: dx / length * edge, dy: dy / length * edge)
        return MotionStretch.rect(now: now, earlier: proxy, profile: profile, settings: settings)
    }
}

/// Only real frame changes for a view containing NSGlassEffectView. Retargets from the sampled nominal pose;
/// no layer scale, no glass in a replicator, and no second velocity stretch from pointer events.
@MainActor final class OverlayGlassMotion: NSObject {
    private weak var view: NSView?
    private let clock: any OverlayClock
    private var link: CADisplayLink?, tick: OverlayCancellation?
    private var run: (from: CGRect, to: CGRect, start: Double, curve: OverlayCurve)?
    private(set) var nominal: CGRect = .zero
    private(set) var target: CGRect = .zero
    var onFrame: ((CGRect) -> Void)?
    init(view: NSView, clock: any OverlayClock) { self.view = view; self.clock = clock }
    func place(_ rect: CGRect, curve: OverlayCurve, animated: Bool) {
        if target == rect && (run != nil || nominal == rect) { return }
        let from = run.map { pose($0, at: clock.now) } ?? nominal
        stop(); target = rect
        guard animated, from.width > 0, let view, view.superview != nil else { nominal = rect; apply(rect, earlier: rect); return }
        run = (from, rect, clock.now, curve); nominal = from; apply(from, earlier: from)
        if clock is OverlaySystemClock {
            let link = view.displayLink(target: self, selector: #selector(frame)); link.add(to: .main, forMode: .common); self.link = link
        } else { schedule() }
    }
    private func pose(_ r: (from: CGRect, to: CGRect, start: Double, curve: OverlayCurve), at time: Double) -> CGRect {
        let p = CGFloat(r.curve.value(at: (time - r.start) / r.curve.duration))
        return CGRect(x: r.from.minX + (r.to.minX - r.from.minX) * p, y: r.from.minY + (r.to.minY - r.from.minY) * p,
                      width: r.from.width + (r.to.width - r.from.width) * p, height: r.from.height + (r.to.height - r.from.height) * p)
    }
    @objc private func frame() {
        guard let run, let view, view.superview != nil else { stop(); return }
        let profile = OverlayExposure.profile(for: view)
        nominal = pose(run, at: clock.now)
        apply(nominal, earlier: pose(run, at: max(run.start, clock.now - profile.frameInterval)))
        if clock.now >= run.start + run.curve.duration { nominal = run.to; apply(nominal, earlier: nominal); stop() }
        else if link == nil { schedule() }
    }
    private func apply(_ rect: CGRect, earlier: CGRect) {
        guard let view else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let grid = max(1, view.window?.backingScaleFactor ?? 1)
        let nominal = OverlayGlassExposure.pixelAligned(rect, scale: grid)
        let previous = OverlayGlassExposure.pixelAligned(earlier, scale: grid)
        view.frame = OverlayGlassExposure.pixelAligned(OverlayGlassExposure.rect(now: nominal, earlier: previous, profile: OverlayExposure.profile(for: view), enabled: OverlayExposure.enabled), scale: grid)
        view.needsLayout = true; view.layoutSubtreeIfNeeded(); onFrame?(view.frame); CATransaction.commit()
    }
    private func schedule() { tick = clock.schedule(after: 1 / 60) { [weak self] in self?.frame() } }
    func finish() {
        stop()
        guard target.width > 0 else { return }
        nominal = target; apply(target, earlier: target)
    }
    func stop() { link?.invalidate(); link = nil; tick?.cancel(); tick = nil; run = nil }
}
