import AppKit
import QuartzCore

/// M10-A: a transient paint treatment, never a new logical pose or a motion clock.
/// The switch is also the real-window A/B control; it changes no curves or hand-off times.
@MainActor enum M10ModeExposure {
    static let enabled = ProcessInfo.processInfo.environment["M10_MODE_EXPOSURE"] != "0"
    // Isolate compositor costs in serial real-window A/B recordings; all default to enabled.
    static let glyphsEnabled = ProcessInfo.processInfo.environment["M10_MODE_GLYPHS"] != "0"
    static let stretchEnabled = ProcessInfo.processInfo.environment["M10_MODE_STRETCH"] != "0"
    static let sidebarEnabled = ProcessInfo.processInfo.environment["M10_MODE_SIDEBAR"] != "0"


    static func glyphBitmap(size: CGSize, scale: CGFloat, draw: (CGRect) -> Void) -> CGImage {
        let w = max(1, Int(ceil(size.width * scale))), h = max(1, Int(ceil(size.height * scale)))
        let c = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x:0,y:CGFloat(h));c.scaleBy(x:scale,y:-scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:c,flipped:true)
        draw(CGRect(origin:.zero,size:size))
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()!
    }

    static func profile(for view: NSView, interval: Double? = nil) -> DisplayProfile {
        var p = view.window?.screen.map(DisplayProfile.of)
            ?? DisplayProfile(name: "offscreen", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
        if let interval, interval.isFinite, interval > 0 { p.frameInterval = interval }
        return p
    }

    static func sample(_ now: CGRect, _ earlier: CGRect, profile: DisplayProfile, enabled: Bool) -> ExposureSample {
        var settings = ExposureSettings(); settings.enabled = enabled
        // Mode trips can cross hundreds of points in a frame. The flight default's 40-copy ceiling would
        // violate the 1.5 pt spacing contract here. Work is still O(1) on the main thread.
        settings.maxCopies = max(settings.maxCopies, 1 + Int(ceil(MotionStep.edge(now, earlier) / settings.spacing)))
        var value = ExposureSample(now: now, earlier: earlier, frameInterval: profile.frameInterval,
                                   mmPerPoint: profile.mmPerPoint, settings: settings)
        if value.gate > 0, value.count == 1 {
            value.count = 2
            value.alpha = CGFloat(1 - pow(0.1 * Double(value.gate), 0.5))
        }
        return value
    }

    static func stretch(_ now: CGRect, _ earlier: CGRect, profile: DisplayProfile, enabled: Bool) -> CGRect {
        guard enabled, stretchEnabled else { return now }
        // Glass cannot enter a zoom replicator. Gate on the corner sweep too, and express it as a real
        // trailing-side size change. Normally its direction is the centre's motion; at a pure resize the
        // farthest moving corner defines the direction. The unprocessed logical pose is never changed.
        let step = MotionStep.edge(now, earlier)
        var dx = earlier.midX - now.midX, dy = earlier.midY - now.midY
        if hypot(dx, dy) < 1e-9 {
            let corners = [(earlier.minX - now.minX, earlier.minY - now.minY),
                           (earlier.maxX - now.maxX, earlier.maxY - now.maxY)]
            if let p = corners.max(by: { hypot($0.0, $0.1) < hypot($1.0, $1.1) }) { dx = p.0; dy = p.1 }
        }
        let d = hypot(dx, dy)
        guard d > 1e-9 else { return now }
        let back = now.offsetBy(dx: dx * step / d, dy: dy * step / d)
        let stretched = MotionStretch.rect(now: now, earlier: back, profile: profile)
        let g = sample(now, earlier, profile: profile, enabled: true).gate
        guard stretched == now, g > 0 else { return stretched }
        // Retain the continuous mathematical tail below MotionStretch's 0.01 pt arithmetic guard.
        let x = dx * step / d * g, y = dy * step / d * g
        return MotionStretch.limited(CGRect(x: now.minX + min(0, x), y: now.minY + min(0, y),
                                            width: now.width + abs(x), height: now.height + abs(y)), now: now)
    }
}

/// Screen geometry is semantic state, not a per-frame CoreGraphics query. The measured refresh interval
/// still updates on every callback, including after moving the window to another display.
@MainActor final class M10ModeDisplayProfile {
    private weak var screen: NSScreen?
    private var screenFrame = CGRect.zero
    private var profile = DisplayProfile(name: "offscreen", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
    func sample(for view: NSView, interval: Double? = nil) -> DisplayProfile {
        if let next = view.window?.screen, next !== screen || next.frame != screenFrame {
            screen = next; screenFrame = next.frame; profile = DisplayProfile.of(next)
        }
        if let interval, interval > 0, interval.isFinite { profile.frameInterval = interval }
        return profile
    }
}

/// Native content stays OUTSIDE the replicator. During exposure only one flattened transparent texture
/// enters ChordTrail: never AppKit backing layers, masks, live shadows, filters or a window-sized surface.
@MainActor final class M10ModeGlyphTrail: NSView {
    let trail = ChordTrail()
    private(set) var exposure = ExposureSample.still
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private let flattened = CALayer()
    private var suppressed: [(CALayer, Float)] = []
    var freezesContent = false
    var bitmapProvider: ((CGFloat) -> CGImage)?
    private var cached: CGImage?
    private(set) var flattenedPixels = 0
    var flattenedImage: CGImage? { cached }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = false
        autoresizesSubviews = false
        layer?.addSublayer(trail.layer)
        trail.layer.anchorPoint = .zero
        trail.layer.addSublayer(flattened)
        flattened.isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(now: CGRect, earlier: CGRect, profile: DisplayProfile, enabled: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let s = M10ModeExposure.sample(now, earlier, profile: profile, enabled: enabled && M10ModeExposure.glyphsEnabled)
        if s.count == 1 {
            if exposure.count > 1 { reset() }
            // Real native content owns untreated pixels. Keep its original contentView geometry there.
            for v in subviews where v.frame != bounds { v.frame = bounds }
            exposure = s
            return
        }
        trail.settings.enabled = enabled
        trail.settings.maxCopies = max(40, s.count)
        trail.update(now: now, earlier: earlier, profile: profile)
        exposure = s
        guard s.count > 1, now.width > 0, now.height > 0 else { return }
        // A source-only view needs geometry once for a cold bake, not on every frame while suppressed.
        if freezesContent, cached == nil {
            for v in subviews where v.frame != bounds { v.frame = bounds }
        }
        flattenNativeContent(in: now)
        // Tight bounds: a sidebar texture must not turn into a full-window intermediate per instance.
        trail.layer.bounds = now
        trail.layer.position = now.origin
        // ChordTrail's independent centre increments compound with scale. Use the affine root of the
        // gated earlier box so its final copy really reaches that box, including simultaneous zoom/translation.
        // This is local to M10-A; Engine's API and driver-B instanceDelay are untouched.
        let g = s.gate
        let end = CGRect(x: now.minX + (earlier.minX - now.minX) * g,
                         y: now.minY + (earlier.minY - now.minY) * g,
                         width: now.width + (earlier.width - now.width) * g,
                         height: now.height + (earlier.height - now.height) * g)
        func root(_ count: Int) -> CGAffineTransform {
            func axis(_ ratio: CGFloat, _ a: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat) {
                let k = pow(max(0.000001, ratio), 1 / CGFloat(count - 1))
                let full = b - ratio * a
                return (k, abs(ratio - 1) < 1e-9 ? full / CGFloat(count - 1) : full * (k - 1) / (ratio - 1))
            }
            let x = axis(end.width / now.width, now.midX, end.midX)
            let y = axis(end.height / now.height, now.midY, end.midY)
            return CGAffineTransform(a: x.0, b: 0, c: 0, d: y.0, tx: x.1, ty: y.1)
        }
        var count = s.count, transform = root(count)
        // Scale compounds geometrically; bound the largest adjacent-corner step, not just the mean.
        for _ in 0..<8 {
            let inverse = transform.inverted()
            let gap = max(MotionStep.edge(now, now.applying(transform)), MotionStep.edge(end.applying(inverse), end))
            if gap <= 1.5 + 1e-7 { break }
            count = max(count + 1, 1 + Int(ceil(CGFloat(count - 1) * gap / 1.5)))
            transform = root(count)
        }
        exposure.count = count
        exposure.alpha = CGFloat(1 - pow(0.1 * Double(g), 1 / Double(count)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trail.layer.instanceCount = count
        trail.layer.instanceTransform = CATransform3DMakeAffineTransform(transform)
        trail.layer.instanceColor = NSColor(white: 1, alpha: exposure.alpha).cgColor
        CATransaction.commit()
    }

    private func flattenNativeContent(in box: CGRect) {
        guard bitmapProvider != nil || !subviews.isEmpty else { return } // Sidebar already supplies a plain immutable CGImage layer.
        let scale = window?.backingScaleFactor ?? 2
        if cached == nil || !freezesContent {
            for (l, opacity) in suppressed { l.opacity = opacity }
            let probe = ModeSignposts.current
            probe?.record("M10GlyphBake", .begin)
            defer { probe?.record("M10GlyphBake", .end) }
            if let bitmapProvider { cached = bitmapProvider(scale) }
            else {
                // Flying planets are configured with reduceMotion/ambient=false; bake their fixed ink once.
                // Render at least 48 pt across so the same texture covers every flying size at native backing.
                let factor = max(scale, 48 * scale / max(box.width, box.height))
                let w = max(1, Int(ceil(box.width * factor))), h = max(1, Int(ceil(box.height * factor)))
                if let c = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) {
                    c.scaleBy(x:factor,y:factor);c.translateBy(x:-box.minX,y:-box.minY)
                    for v in subviews {
                        // Orb decorations are layer-hosted model ink. A view display flush here would
                        // force NSWindow layout in the middle of the display-link callback.
                        c.saveGState();c.translateBy(x:v.frame.minX,y:v.frame.minY)
                        v.layer?.render(in:c);c.restoreGState()
                    }
                    cached = c.makeImage()
                }
            }
        }
        if suppressed.isEmpty { suppressed = subviews.compactMap { v in v.layer.map { ($0,$0.opacity) } } }
        for (l, _) in suppressed { l.opacity = 0 }
        flattened.contents = cached; flattened.frame = box; flattened.isHidden = false
        flattenedPixels = (cached?.width ?? 0) * (cached?.height ?? 0)
    }

    func reset() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        trail.reset(); exposure = .still
        for (l, opacity) in suppressed { l.opacity = opacity }
        suppressed.removeAll(); cached = nil; flattened.contents = nil; flattened.isHidden = true; flattenedPixels = 0
    }
}

/// The sidebar's content-only cache, over the real split's system material. It follows AppKit's PRESENTED
/// geometry and alpha; it neither animates the split nor replaces its hit/AX/focus ownership.
@MainActor final class M10SidebarExposure: NSObject {
    let plane = ModeFlight.Plane()
    let glyphs = M10ModeGlyphTrail(frame: .zero)
    let image = CALayer()
    /// Only this tight content group inherits the sidebar fade; the full-window hit-through plane stays opaque.
    let renderingLayer = CALayer()
    var enabled = M10ModeExposure.enabled
    private(set) var lease: UUID?
    private(set) var lastStep: CGFloat = 0
    private(set) var droppedSample = false
    private weak var source: NSView?, host: NSView?
    private var link: CADisplayLink?
    private var previous: CGRect?, lastTime: Double?
    private var savedOpacity: Float = 1
    private var covered = false, handedBack = false
    private let display = M10ModeDisplayProfile()

    override init() {
        super.init()
        plane.wantsLayer = true; plane.setAccessibilityElement(false)
        renderingLayer.anchorPoint = .zero
        plane.layer?.addSublayer(renderingLayer)
        renderingLayer.addSublayer(glyphs.trail.layer)
        glyphs.trail.layer.addSublayer(image)
        image.contentsGravity = .resize; image.contentsScale = 1
        plane.isHidden = true
    }

    @discardableResult func begin(source: NSView, in host: NSView, below: NSView? = nil, driven: Bool = true, scale: CGFloat? = nil, prepared:CGImage?=nil,foreground:(()->CGImage)?=nil) -> UUID? {
        let probe = ModeSignposts.current
        probe?.record("M10SidebarPrepare", .begin)
        defer { probe?.record("M10SidebarPrepare", .end) }
        finish()
        guard enabled, M10ModeExposure.sidebarEnabled, source.bounds.width > 0, source.bounds.height > 0 else { return nil }
        // A sidebar may gain native glass in a later M9 round. Never quietly put its glass in a replicator.
        func glass(_ v: NSView) -> Bool { v is NSGlassEffectView || v.subviews.contains(where: glass) }
        guard !glass(source) else { return nil }
        self.source = source; self.host = host
        source.wantsLayer = true; savedOpacity = source.layer?.opacity ?? 1
        let backingScale = host.window?.backingScaleFactor ?? scale ?? 1
        if let prepared, prepared.width == Int(ceil(source.bounds.width * backingScale)), prepared.height == Int(ceil(source.bounds.height * backingScale)) {
            ModeSignposts.current?.record("M10SidebarCacheHit")
            image.contents = prepared
        } else {
            image.contents = ModeSignposts.measure("M10SidebarSnapshot") {foreground?() ?? NativeViewBitmap.capture(source,scale:backingScale)}
        }
        image.contentsScale = backingScale
        plane.frame = host.bounds
        host.addSubview(plane, positioned: .below, relativeTo: below)
        plane.layer?.zPosition=ModePlaneOrder.sidebar
        lease = UUID(); previous = Self.presentedRect(source, in: host); lastTime = nil; handedBack = false
        if driven {
            let next = host.displayLink(target: self, selector: #selector(tick(_:)))
            ModeSignposts.frameRange(next)
            next.add(to: .main, forMode: .common); link = next
        }
        return lease
    }

    func rebase() {
        guard let source, let host else { return }
        previous = host.convert(source.bounds, from: source); lastTime = nil
    }

    /// Exposed for deterministic offscreen checks: the same operation the display-link callback uses.
    func sample(rect: CGRect, at time: Double, profile: DisplayProfile, alpha: Float = 1) {
        guard lease != nil, let source else { return }
        let earlier = previous ?? rect
        lastStep = MotionStep.edge(rect, earlier)
        droppedSample = lastTime.map { time - $0 > 1.5 * profile.frameInterval } ?? false
        // Do not turn a missed frame into a longer shutter and conceal a stall. Resume from this pose instead.
        let local = CGRect(origin:.zero,size:rect.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.frame = local
        renderingLayer.bounds = local; renderingLayer.position = rect.origin
        renderingLayer.opacity = alpha * savedOpacity
        plane.layer?.opacity = 1
        glyphs.update(now:local, earlier:droppedSample ? local : earlier.offsetBy(dx:-rect.minX,dy:-rect.minY),
                      profile:profile,enabled:enabled)
        previous = rect; lastTime = time
        // Once it has handed back to the real view it stays handed back: a late step re-covered it for one frame at the end.
        if covered, glyphs.exposure.count <= 1 { handedBack = true }
        let shouldCover = glyphs.exposure.count > 1 && !handedBack
        plane.isHidden = !shouldCover
        if shouldCover != covered {
            source.layer?.opacity = shouldCover ? 0 : savedOpacity
            covered = shouldCover
        }
        CATransaction.commit()
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let host else { finish(); return }
        advance(at: l.targetTimestamp, profile: display.sample(for: host, interval: l.targetTimestamp - l.timestamp))
    }

    /// WindowShell calls this from ModeFlight's existing display-link callback. The optional standalone
    /// display link above is for other hosts; mode switches explicitly use driven:false.
    func advance(at time: Double, profile: DisplayProfile) {
        guard lease != nil else { return }
        guard let source, let host, source.window != nil, host.window != nil, host.bounds == plane.frame else { finish(); return }
        let rect = Self.presentedRect(source, in: host)
        var alpha: Float = 1
        var v = source.superview
        while let node = v, node !== host {
            alpha *= node.layer?.presentation()?.opacity ?? Float(node.alphaValue)
            v = node.superview
        }
        sample(rect: rect, at: time, profile: profile, alpha: alpha)
    }

    static func presentedRect(_ source: NSView, in host: NSView) -> CGRect {
        // NSSplitView's driver-A layout writes live NSView frames. Prefer those unless an ancestor
        // really has a compositor geometry animation; always sampling presentation would lag driver A.
        var node = source.layer, animated = false
        while let layer = node, layer !== host.layer {
            for key in layer.animationKeys() ?? [] {
                if let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath,
                   ["position", "bounds", "transform"].contains(where: { path.hasPrefix($0) }) { animated = true }
            }
            node = layer.superlayer
        }
        if animated, let from = source.layer?.presentation(), let to = host.layer?.presentation() {
            return to.convert(from.bounds, from: from)
        }
        return host.convert(source.bounds, from: source)
    }

    /// An old collapse completion cannot retire the overlay of a newer Show Sidebar leg.
    func finish(_ expected: UUID? = nil) {
        if let expected, expected != lease { return }
        link?.invalidate(); link = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if covered { source?.layer?.opacity = savedOpacity }
        covered = false; glyphs.reset(); plane.isHidden = true; plane.removeFromSuperview()
        image.contents = nil
        CATransaction.commit()
        lease = nil; previous = nil; lastTime = nil; source = nil; host = nil
    }
}

struct M10ModeFrameSample {
    let id: String
    let time: Double
    let now: CGRect, earlier: CGRect, painted: CGRect
    let exposure: ExposureSample
    let instanceTransform: CATransform3D
    var step: CGFloat { MotionStep.edge(now, earlier) }
    var stretch: CGFloat {
        hypot(max(abs(painted.minX - now.minX), abs(painted.maxX - now.maxX)),
              max(abs(painted.minY - now.minY), abs(painted.maxY - now.maxY)))
    }
}

/// A compositor budget, not a claim that a cheap property setter implies a cheap presented frame.
/// At 2×, bound texture reads / blended quads and forbid per-copy offscreen effects or AppKit backing trees.
@MainActor struct M10ModeRenderBudget {
    var replicatedPixels: Double = 0
    var sampledTexturePixels: Double = 0
    var maxIntermediatePixels: Double = 0
    var violations: [String] = []
    static let pixelLimit = 32.0 * 1024 * 1024

    static func inspect(_ root: CALayer, scale: CGFloat) -> M10ModeRenderBudget {
        var result = Self()
        func ink(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            let name = String(describing: type(of: layer))
            if layer.shadowOpacity > 0 { result.violations.append("live shadow: " + name) }
            if !(layer.filters ?? []).isEmpty || !(layer.backgroundFilters ?? []).isEmpty {
                result.violations.append("live filter: " + name)
            }
            if name.lowercased().contains("backdrop") || name.lowercased().contains("glass") {
                result.violations.append("backdrop/glass: " + name)
            }
            if layer.delegate is NSView { result.violations.append("AppKit backing layer: " + name) }
            if layer is CAShapeLayer || layer is CATextLayer || layer is CAGradientLayer {
                result.violations.append("unflattened ink: " + name)
            }
            if layer.mask != nil { result.violations.append("live mask: " + name) }
            for child in layer.sublayers ?? [] { ink(child) }
        }
        func walk(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            if layer.opacity < 1, !(layer.sublayers ?? []).isEmpty {
                result.maxIntermediatePixels = max(result.maxIntermediatePixels, Double(layer.bounds.width*layer.bounds.height*scale*scale))
            }
            if let r = layer as? CAReplicatorLayer, r.instanceCount > 1 {
                let area = Double(r.bounds.width * r.bounds.height * scale * scale)
                result.replicatedPixels += area * Double(r.instanceCount)
                func texturePixels(_ layer: CALayer) -> Double {
                    guard !layer.isHidden,layer.opacity > 0 else { return 0 }
                    let image: CGImage?
                    if let contents=layer.contents,CFGetTypeID(contents as CFTypeRef)==CGImage.typeID {
                        image = (contents as! CGImage)
                    } else { image = nil }
                    return Double((image?.width ?? 0) * (image?.height ?? 0)) + (layer.sublayers ?? []).reduce(0) { $0 + texturePixels($1) }
                }
                result.sampledTexturePixels += texturePixels(r) * Double(r.instanceCount)
                for child in r.sublayers ?? [] { ink(child) }
            }
            for child in layer.sublayers ?? [] { walk(child) }
        }
        walk(root)
        if max(result.replicatedPixels,result.sampledTexturePixels) > pixelLimit { result.violations.append("replicated pixel budget > 32 MiPixels") }
        return result
    }
}
