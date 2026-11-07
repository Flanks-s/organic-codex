import AppKit

/// Product RollingWord: per-letter direction, .253/.207 incoming legs, .024/.005 staggering, whole-word gradient.
@MainActor final class OverlayRollingWord: OverlayView {
    let clock: any OverlayClock
    var reduceMotion = false
    private(set) var text = ""
    private(set) var direction: CGFloat = 1
    private var pointSize: CGFloat = 28
    private(set) var letters: [OverlayGradientLabel] = []
    private var outgoing: [OverlayGradientLabel] = []
    private var cleanup: OverlayCancellation?
    init(clock: any OverlayClock) { self.clock = clock; super.init(frame: .zero); wantsLayer = true; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @discardableResult func set(_ value: String, ultra: Bool, animated: Bool, size: CGFloat = 28) -> CGFloat {
        if value == text && pointSize == size {
            for label in letters { label.gradient = ultra ? OverlayStyle.ultra : []; label.textColor = ultra ? .white : .secondaryLabelColor }
            return frame.width
        }
        OverlayMotion.registerContainingSurface(for: self)
        let order = Effort.allCases.map(\.label)
        direction = (order.firstIndex(of: value) ?? 0) >= (order.firstIndex(of: text) ?? 0) ? 1 : -1
        let animate = animated && !reduceMotion && !text.isEmpty
        cleanup?.cancel(); outgoing.forEach(Self.removeLetter); outgoing = letters; letters = []
        text = value; pointSize = size
        let height = ceil(40 * size / 28)
        let font = NSFont.systemFont(ofSize: size, weight: .medium), grid = max(1, window?.backingScaleFactor ?? 1)
        let chars = value.map(String.init), widths = chars.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let width = ceil((widths.reduce(0, +) + 4) * grid) / grid
        var x: CGFloat = 0
        for (index, char) in chars.enumerated() {
            let label = OverlayGradientLabel(labelWithString: char); label.font = font; label.textColor = ultra ? .white : .secondaryLabelColor
            label.gradient = ultra ? OverlayStyle.ultra : []; label.wantsLayer = true
            label.frame = CGRect(x: (x * grid).rounded() / grid, y: 0, width: ceil((widths[index] + 4) * grid) / grid, height: height)
            label.wordSpan = CGRect(x: -label.frame.minX, y: 0, width: width, height: height)
            let host = OverlayAccumulatingView(frame: CGRect(x: 0, y: 0, width: width, height: height))
             host.ink.addSubview(label); addSubview(host); letters.append(label)
            host.layoutSubtreeIfNeeded()
            if animate, let layer = label.layer {
                keyframes(layer, key: "transform.translation.y", values: [0.62 * size * direction, -0.07 * size * direction, 0], delay: Double(index) * 0.024)
                keyframes(layer, key: "transform.scale", values: [0.92, 1.02, 1], delay: Double(index) * 0.024)
                keyframes(layer, key: "opacity", values: [0, 1, 1], delay: Double(index) * 0.024)
                OverlayFilter.installBlur(on: layer)
                if layer.filters?.isEmpty == false { keyframes(layer, key: "filters.overlayBlur.inputRadius", values: [7, 0, 0], delay: Double(index) * 0.024) }
            }
            if animate, let host = label.superview?.superview as? OverlayAccumulatingView { host.accumulate(carrier: label.layer, enabled: !reduceMotion) }
            x += widths[index]
        }
        frame.size = CGSize(width: width, height: height)
        if animate {
            for (i, label) in outgoing.enumerated() {
                guard let layer = label.layer else { continue }
                let delay = Double(i) * 0.005
                OverlayMotion.animate(layer, "transform.translation.y", from: 0, to: -0.55 * size * direction, curve: OverlayMotion.letterOut, delay: delay)
                OverlayMotion.animate(layer, "transform.scale", from: 1, to: 0.94, curve: OverlayMotion.letterOut, delay: delay)
                OverlayMotion.animate(layer, "opacity", from: 1, to: 0, curve: OverlayMotion.letterOut, delay: delay)
                OverlayFilter.installBlur(on: layer)
                if layer.filters?.isEmpty == false { OverlayMotion.animate(layer, "filters.overlayBlur.inputRadius", from: 0, to: 7, curve: OverlayMotion.letterOut, delay: delay) }
            }
            for label in outgoing { (label.superview?.superview as? OverlayAccumulatingView)?.accumulate(carrier: label.layer, enabled: !reduceMotion) }
            let old = outgoing
            cleanup = clock.schedule(after: 0.5) { old.forEach(Self.removeLetter) }
        } else { outgoing.forEach(Self.removeLetter); outgoing = [] }
        return width
    }
    private static func removeLetter(_ label: OverlayGradientLabel) {
        if let host = label.superview?.superview as? OverlayAccumulatingView { host.removeFromSuperview() }
        else { label.removeFromSuperview() }
    }
    private func keyframes(_ layer: CALayer, key: String, values: [CGFloat], delay: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.setValue(values.last!, forKeyPath: key)
        let a = CAKeyframeAnimation(keyPath: key); a.values = values; a.keyTimes = [0, 0.55, 1]
        a.timingFunctions = [OverlayMotion.letterIn.timing, OverlayMotion.letterIn.timing]; a.duration = 0.46
        a.beginTime = layer.convertTime(OverlayMotion.mediaTime(for: self), from: nil) + delay; a.fillMode = .backwards
        layer.add(a, forKey: "overlay.word." + key)
        if key.hasPrefix("filters.") { OverlayFilter.enabledTrack(on: layer, radiusKey: key, begin: a.beginTime, duration: a.duration, final: Double(values.last!)) }
        CATransaction.commit()
    }
}

@MainActor final class OverlayLyricRow: OverlayAccumulatingView {
    let name = OverlayStyle.label("", size: 28, weight: .bold)
    let version = OverlayStyle.label("", size: 28, weight: .semibold)
    let word: OverlayRollingWord
    private let unavailable = OverlayStyle.label("Not with Daybreak", size: 16, weight: .medium)
    private let content = OverlayView()
    private let fontInk = OverlayInkView()
    var fontLayer: CALayer { fontInk.layer! }
    private var bitmaps: [CGFloat: CGImage] = [:]
    private struct Signature: Equatable { let model: ModelCatalog.Model; let effort: Effort; let current: Bool; let available: Bool; let reason: String }
    private var signature: Signature?
    var isCurrent: Bool { signature?.current == true }
    private(set) var renderScale: CGFloat = 1
    var invoke: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var available = true
    private var tracking: NSTrackingArea?
    init(clock: any OverlayClock) {
        word = OverlayRollingWord(clock: clock); super.init(frame: .zero); wantsLayer = true
        fontInk.wantsLayer = true; fontInk.layer?.name = "overlay.lyric-font"
        ink.addSubview(fontInk); fontInk.addSubview(content)
        fontInk.paint = { [weak self] in self?.drawLyric($0) }
        for view in [name, version, word, unavailable] { content.addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ model: ModelCatalog.Model, effort: Effort, current: Bool, available: Bool, reduceMotion: Bool, animateWord: Bool, unavailableReason: String = "Not with Daybreak") {
        word.reduceMotion = reduceMotion
        let next = Signature(model: model, effort: effort, current: current, available: available, reason: unavailableReason)
        guard signature != next else { return }
        signature = next; bitmaps = [:]
        renderScale = current ? 1 : 19 / 28
        // Like the product, every lyric is laid out at 28 pt. The small line reuses these native pixels at 19/28.
        // Product lyric: .padding(.vertical, 3), before the 19/28 transform of an unselected line.
        let size: CGFloat = 28, height: CGFloat = 40, gap: CGFloat = 6, textTop: CGFloat = 3
        name.font = .systemFont(ofSize: size, weight: .bold); version.font = .systemFont(ofSize: size, weight: .semibold)
        self.available = available; name.stringValue = model.name; version.stringValue = model.version.isEmpty ? "" : "GPT-" + model.version
        version.textColor = NSColor.labelColor.withAlphaComponent(current ? 0.6 : 0.72)
        let grid = max(1, window?.backingScaleFactor ?? 1)
        let versionWidth = version.stringValue.isEmpty ? 0 : ceil(version.attributedStringValue.size().width * grid) / grid + 4
        version.frame = CGRect(x: 0, y: textTop, width: versionWidth, height: height)
        // HStack(spacing: 6) is 6 pt glyph to glyph; each label here pads its text 2 pt on both sides.
        let x = versionWidth == 0 ? 0 : versionWidth + gap - 4
        let nameWidth = ceil(name.attributedStringValue.size().width * grid) / grid + 4
        name.frame = CGRect(x: x, y: textTop, width: nameWidth, height: height)
        word.reduceMotion = reduceMotion; _ = word.set(effort.label, ultra: effort == .ultra, animated: animateWord, size: size)
        word.frame.origin = CGPoint(x: name.frame.maxX + gap - 4, y: textTop); word.isHidden = !available
        unavailable.isHidden = available
        unavailable.stringValue = unavailableReason
        unavailable.font = .systemFont(ofSize: 16, weight: .medium)
        unavailable.frame = CGRect(x: name.frame.maxX + gap - 4, y: 7 + textTop, width: 210, height: 26)
        content.frame = CGRect(x: 0, y: 0, width: max(348, available ? word.frame.maxX : unavailable.frame.maxX), height: 40)
        content.isHidden = !current; fontInk.needsDisplay = true
        setAccessibilityLabel(model.full + " · " + (available ? effort.label : unavailableReason))
        setAccessibilityValue(current ? "Selected" : "")
        toolTip = available ? model.full : model.full + ": " + unavailableReason
        if animateWord && !reduceMotion, let layer = name.layer {
            let a = CAKeyframeAnimation(keyPath: "transform.translation.y"); a.values = [0, -1.5, 0]; a.keyTimes = [0, 0.3, 1]; a.duration = 0.42
            a.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.3, 1.6, 0.5, 1), CAMediaTimingFunction(controlPoints: 0.3, 1.6, 0.5, 1)]
            a.beginTime=layer.convertTime(OverlayMotion.mediaTime(for:self),from:nil)
            layer.add(a, forKey: "overlay.jolt")
            let scale = a.copy() as! CAKeyframeAnimation; scale.keyPath = "transform.scale"; scale.values = [1, 1.012, 1]; layer.add(scale, forKey: "overlay.jolt.scale")
        }
    }
    override func layout() { super.layout(); prepareFont() }
    func prepareFont() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Top-leading font scaling is independent of the line's leading-centred depth transform.
        let transform = fontLayer.transform; fontLayer.transform = CATransform3DIdentity
        fontInk.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 40)
        fontLayer.anchorPoint = .zero; fontLayer.position = .zero
        fontLayer.transform = transform
        CATransaction.commit()
    }
    private func drawLyric(_ dirtyRect: NSRect) {
        guard renderScale != 1 else { return }
        let scale = max(1, window?.backingScaleFactor ?? abs(NSGraphicsContext.current?.cgContext.ctm.a ?? 1))
        let bitmap: CGImage
        if let cached = bitmaps[scale] { bitmap = cached }
        else {
            content.isHidden = false
            bitmap = NativeViewBitmap.capture(content, scale: scale)
            content.isHidden = true; bitmaps[scale] = bitmap
        }
        let image = NSImage(cgImage: bitmap, size: content.bounds.size)
        image.draw(in: CGRect(x: 0, y: 0, width: content.bounds.width * renderScale, height: content.bounds.height * renderScale),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    override func mouseDown(with event: NSEvent) { if available { invoke?() } }
    override func accessibilityPerformPress() -> Bool { guard available else { return false }; invoke?(); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            tracking = area; addTrackingArea(area)
        }
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
