import AppKit

@MainActor enum OverlayStyle {
    static let ultra = [NSColor(srgbRed: 0x8b / 255, green: 0x5c / 255, blue: 0xf6 / 255, alpha: 1),
                        NSColor(srgbRed: 0xe1 / 255, green: 0x52 / 255, blue: 0xc4 / 255, alpha: 1),
                        NSColor(srgbRed: 1, green: 0xb3 / 255, blue: 0x5c / 255, alpha: 1)]
    static let dawn = [NSColor(srgbRed: 0xe9 / 255, green: 0x77 / 255, blue: 0x3a / 255, alpha: 1),
                       NSColor(srgbRed: 0xf6 / 255, green: 0xa9 / 255, blue: 0x5a / 255, alpha: 1),
                       NSColor(srgbRed: 1, green: 0xd7 / 255, blue: 0x9a / 255, alpha: 1)]
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NativeLabel {
        let label = NativeLabel(labelWithString: text); label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor; label.lineBreakMode = .byClipping; label.wantsLayer = true
        return label
    }
    static func linear(_ colors: [NSColor], in rect: CGRect) {
        // One colour is a fill: a one-stop CGGradient drew nothing, and the slider's accent fill never showed (M9).
        if colors.count == 1 { colors[0].setFill(); rect.fill(); return }
        guard !colors.isEmpty, let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.midY), end: CGPoint(x: rect.maxX, y: rect.midY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    static func symbolGradient(_ colors: [NSColor], bounds: CGRect, scale: CGFloat, draw: () -> Void) {
        guard let destination = NSGraphicsContext.current?.cgContext,
              let mask = CGContext(data: nil, width: max(1, Int(ceil(bounds.width * scale))), height: max(1, Int(ceil(bounds.height * scale))), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { draw(); return }
        mask.scaleBy(x: scale, y: scale); mask.translateBy(x: 0, y: bounds.height); mask.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: mask, flipped: true); draw(); NSGraphicsContext.restoreGraphicsState()
        guard let image = mask.makeImage(), let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        destination.saveGState(); destination.translateBy(x: 0, y: bounds.height); destination.scaleBy(x: 1, y: -1); destination.clip(to: bounds, mask: image)
        destination.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX + 10, y: bounds.midY + 12), end: CGPoint(x: bounds.midX - 10, y: bounds.midY - 12), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        destination.restoreGState()
    }
}

/// A label's own draw path makes its alpha mask. The gradient spans the entire word, even for separate letters.
@MainActor final class OverlayGradientLabel: NativeLabel {
    var gradient: [NSColor] = [] { didSet { needsDisplay = true } }
    var wordSpan: CGRect? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard !gradient.isEmpty, let destination = NSGraphicsContext.current?.cgContext else { super.draw(dirtyRect); return }
        let scale = max(1, window?.backingScaleFactor ?? abs(destination.ctm.a))
        guard let mask = CGContext(data: nil, width: max(1, Int(ceil(bounds.width * scale))), height: max(1, Int(ceil(bounds.height * scale))), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        mask.scaleBy(x: scale, y: scale); mask.translateBy(x: 0, y: bounds.height); mask.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: mask, flipped: true)
        super.draw(dirtyRect); NSGraphicsContext.restoreGraphicsState()
        guard let image = mask.makeImage() else { return }
        destination.saveGState()
        destination.translateBy(x: 0, y: bounds.height); destination.scaleBy(x: 1, y: -1)
        destination.clip(to: bounds, mask: image)
        OverlayStyle.linear(gradient, in: wordSpan ?? bounds)
        destination.restoreGState()
    }
}

@MainActor final class OverlayBackdrop: OverlayView {
    private let backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init() ?? CALayer()
    private let feather = CAGradientLayer()
    private let wash = OverlayWash()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        backdrop.setValue(1.0, forKey: "scale")
        backdrop.filters = [OverlayFilter.make("colorSaturate", values: ["inputAmount": 1.5]),
                            OverlayFilter.make("gaussianBlur", values: ["inputRadius": 22, "inputNormalizeEdges": true])].compactMap { $0 }
        feather.type = .radial; feather.startPoint = CGPoint(x: 0.5, y: 0.5); feather.endPoint = CGPoint(x: 1, y: 1)
        feather.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.7).cgColor, NSColor.clear.cgColor]
        feather.locations = [0, 0.62, 0.8, 1]; backdrop.mask = feather
        layer?.addSublayer(backdrop); wash.wantsLayer = true; addSubview(wash)
        wash.layer?.shadowColor = NSColor.black.cgColor; wash.layer?.shadowOpacity = 0.42
        wash.layer?.shadowRadius = 18; wash.layer?.shadowOffset = CGSize(width: 0, height: 16)
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        backdrop.anchorPoint = layer?.anchorPoint ?? .zero; backdrop.frame = bounds; feather.frame = backdrop.bounds
        if wash.frame != bounds { let t = wash.layer?.transform; wash.frame = bounds; if let t { wash.layer?.transform = t } }; CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func stopExposure() {}
    func prepareGaussian() {
        layoutSubtreeIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for node in [backdrop, wash.layer!] { node.removeAllAnimations(); node.transform = CATransform3DIdentity }
        CATransaction.commit()
    }
    func transition(from start: CGFloat, to end: CGFloat, curve: OverlayCurve, enabled: Bool) {
        layoutSubtreeIfNeeded()
        for node in [backdrop, wash.layer!] {
            let dx = bounds.width * (0.5 - node.anchorPoint.x), dy = bounds.height * (0.85 - node.anchorPoint.y)
            OverlayMotion.animate(node, "transform.scale", from: start, to: end, curve: curve, enabled: enabled, retarget: end != 1)
            OverlayMotion.animate(node, "transform.translation.x", from: (1 - start) * dx, to: (1 - end) * dx, curve: curve, enabled: enabled, retarget: end != 1)
            OverlayMotion.animate(node, "transform.translation.y", from: (1 - start) * dy, to: (1 - end) * dy, curve: curve, enabled: enabled, retarget: end != 1)
        }
    }
    func springIn(enabled: Bool) {
        layoutSubtreeIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for node in [backdrop, wash.layer!] {
            let dx = bounds.width * (0.5 - node.anchorPoint.x), dy = bounds.height * (0.85 - node.anchorPoint.y)
            for (key, from, to) in [("transform.scale", CGFloat(0.55), CGFloat(1)), ("transform.translation.x", 0.45 * dx, 0), ("transform.translation.y", 0.45 * dy, 0)] {
                node.setValue(to, forKeyPath: key)
                let a = OverlayMotion.sendSpring(); a.keyPath = key; a.fromValue = from; a.toValue = to
                a.beginTime = node.convertTime(OverlayMotion.mediaTime(for: node), from: nil)
                if enabled { node.add(a, forKey: "overlay.send.spring." + key) }
            }
        }
        let fade = OverlayMotion.sendSpring(); fade.keyPath = "opacity"; fade.fromValue = 0; fade.toValue = 1
        layer?.opacity = 1; if enabled { layer?.add(fade, forKey: "overlay.send.spring.opacity") }
        CATransaction.commit()
    }
}
@MainActor private final class OverlayWash: OverlayView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.translateBy(x: bounds.midX, y: bounds.midY); context.scaleBy(x: bounds.width / 2, y: bounds.height / 2)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.textBackgroundColor.withAlphaComponent(0.46).cgColor, NSColor.textBackgroundColor.withAlphaComponent(0.30).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 0.6, 1])!
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        // Canopy.swift:7–16, exact dark tokens #57C27A / #3BAFC2.
        for (point, color, radius) in [(CGPoint(x: 0.24, y: -0.4), NSColor(srgbRed: 0x57 / 255, green: 0xc2 / 255, blue: 0x7a / 255, alpha: 0.13), CGFloat(0.58)), (CGPoint(x: -0.36, y: 0.56), NSColor(srgbRed: 0x3b / 255, green: 0xaf / 255, blue: 0xc2 / 255, alpha: 0.10), CGFloat(0.46))] {
            let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color.cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
        }
        context.setBlendMode(.destinationIn)
        let mask = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.7).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 0.62, 0.8, 1])!
        context.drawRadialGradient(mask, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: .drawsAfterEndLocation)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// Real glass while held; the white rest thumb and rim also have a deterministic cache drawing path.
@MainActor final class OverlayLens: OverlayView {
    private let glass = NSGlassEffectView()
    private let rim = OverlayLensRim()
    private var motion: OverlayGlassMotion?
    func move(to rect: CGRect, curve: OverlayCurve, clock: any OverlayClock, animated: Bool) {
        if motion == nil { motion = OverlayGlassMotion(view: self, clock: clock) }
        motion?.place(rect, curve: curve, animated: animated)
    }
    var targetMotionFrame: CGRect { motion?.target ?? frame }
    func stopMotion() { motion?.stop() }
    func retireMotion() { motion?.finish() }
    var held = false { didSet { glass.isHidden = !held; needsDisplay = true } }
    var ultra = false { didSet { needsDisplay = true } }
    /// The speed lens (ModelPicker.lensView): regular glass with no tint and no rim, always held.
    var plain = false { didSet { glass.style = plain ? .regular : .clear; glass.tintColor = plain ? nil : .white.withAlphaComponent(0.14); rim.isHidden = plain; needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        glass.style = .clear; glass.tintColor = .white.withAlphaComponent(0.14)
        glass.contentView = rim; glass.isHidden = true; addSubview(glass); setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); glass.frame = bounds; glass.cornerRadius = bounds.height / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.shadowColor = ultra && !held ? OverlayStyle.ultra[1].cgColor : NSColor.black.cgColor
        layer?.shadowOpacity = ultra && !held ? 0.55 : held ? 0.16 : 0.3
        layer?.shadowRadius = ultra && !held ? 10 : held ? 6 : 3
        layer?.shadowOffset = CGSize(width: 0, height: ultra && !held ? 0 : held ? 3 : 2)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        if !held {
            NSColor.white.setFill()
            if bounds.width == bounds.height { NSBezierPath(ovalIn: bounds).fill() }
            else { NSBezierPath(roundedRect: bounds, xRadius: min(bounds.width, bounds.height) / 2, yRadius: min(bounds.width, bounds.height) / 2).fill() }
        }
        else if window == nil { if plain { NSColor.white.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() } else { rim.draw(bounds) } }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor private final class OverlayLensRim: OverlayView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2); path.lineWidth = 1; path.stroke()
    }
}
