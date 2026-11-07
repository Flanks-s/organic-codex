import AppKit

@MainActor final class OverlayReasoningSlider: OverlayView {
    private let track = OverlayTrack(), lens = OverlayLens()
    private let fill = OverlayTrack()
    private let tickMarks = OverlayTrack()
    private(set) var levels: [Effort] = []
    private(set) var value: Effort = .high
    private(set) var isDragging = false
    private(set) var lensStretch: CGFloat = 0
    var onSelect: ((Effort) -> Void)?
    var reduceMotion = false
    private var ambientEnabled = true
    private var dragX: CGFloat?
    private var daybreak = false
    private var lastPointer: (x: CGFloat, time: Double)?
    private var idle: OverlayCancellation?
    private let clock: any OverlayClock
    var stops: [CGFloat] {
        let width = max(30, bounds.width)
        return levels.indices.map { levels.count > 1 ? 15 + (width - 30) * CGFloat($0) / CGFloat(levels.count - 1) : width / 2 }
    }
    init(clock: any OverlayClock) {
        self.clock = clock; super.init(frame: .zero); wantsLayer = true
        for view in [track, fill, tickMarks, lens] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Reasoning")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(levels: [Effort], value: Effort, daybreak: Bool) {
        // A model capability change ends the old pointer capture. Reconfiguring the same
        // levels during a live snap must keep the current drag and lens continuous.
        if self.levels != levels {
            idle?.cancel();idle=nil;isDragging=false;dragX=nil;lensStretch=0;lastPointer=nil
        }
        self.levels = levels
        self.daybreak = daybreak
        self.value = levels.contains(value) ? value : levels.first ?? .high
        track.colors = [.white.withAlphaComponent(0.12)]
        // The app's accent, as the product's appAccent (not the system's).
        fill.colors = self.value == .ultra ? [NativePalette.accent] + OverlayStyle.ultra : daybreak ? OverlayStyle.dawn : [NativePalette.accent]
        fill.ultra = self.value == .ultra; fill.animateAmbient = ambientEnabled && !reduceMotion
        track.ultraTail = levels.last == .ultra && levels.count > 1 ? 1 - 1 / CGFloat(levels.count - 1) : nil
        lens.ultra = self.value == .ultra
        setAccessibilityValue(levels.isEmpty ? "No supported reasoning levels" : self.value.label)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout(); let grid = max(1, window?.backingScaleFactor ?? 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * grid).rounded() / grid }
        let thickness: CGFloat = isDragging ? 34 : 30
        let at = dragX ?? (levels.firstIndex(of: value).flatMap { stops.indices.contains($0) ? stops[$0] : nil } ?? 15)
        let oldFill = fill.frame.width, oldTrack = track.frame.height
        track.frame = CGRect(x: 0, y: snap((bounds.height - thickness) / 2), width: snap(bounds.width), height: thickness)
        fill.frame = CGRect(x: 0, y: track.frame.minY, width: snap(at + 15), height: thickness)
        let w: CGFloat = isDragging ? 40 : 26
        let h: CGFloat = isDragging ? 30 : 26
        lens.held = isDragging
        let lensRect = CGRect(x: snap(at - w / 2), y: snap((bounds.height - h) / 2), width: ceil(w * grid) / grid, height: ceil(h * grid) / grid)
        tickMarks.frame = track.frame; tickMarks.ticks = stops; tickMarks.knob = at; tickMarks.needsDisplay = true
        if oldFill > 0 && !isDragging {
            OverlayMotion.animate(fill.layer!, "bounds.size.width", from: oldFill, to: fill.frame.width, curve: OverlayMotion.fill, enabled: !reduceMotion)
            let position = fill.layer!.position.x
            OverlayMotion.animate(fill.layer!, "position.x", from: position + (oldFill - fill.frame.width) * fill.layer!.anchorPoint.x, to: position, curve: OverlayMotion.fill, enabled: !reduceMotion)
        }
        if oldTrack > 0 {
            OverlayMotion.animate(track.layer!, "transform.scale.y", from: oldTrack / thickness, to: 1, curve: OverlayMotion.thicken, enabled: !reduceMotion)

        }
        lens.move(to: lensRect, curve: isDragging ? OverlayMotion.lens : OverlayMotion.knob, clock: clock, animated: !reduceMotion)
        fill.layoutSubtreeIfNeeded(); lens.layoutSubtreeIfNeeded()
    }
    func pointerDown(x: CGFloat) { guard !levels.isEmpty else { return }; isDragging = true; lastPointer = (x, clock.now); pointerDragged(x: x) }
    func pointerDragged(x: CGFloat) {
        guard isDragging, let first = stops.first, let last = stops.last else { return }
        let clipped = min(last, max(first, x))
        if let old = lastPointer, clock.now > old.time {
            let profile = OverlayExposure.profile(for: self)
            let step = abs(clipped - old.x) / CGFloat(clock.now - old.time) * profile.frameInterval
            let sample = ExposureSample(now: CGPoint(x: step, y: 0), earlier: .zero, frameInterval: profile.frameInterval, mmPerPoint: profile.mmPerPoint, settings: ExposureSettings())
            lensStretch = min(0.32, sample.gate * step / 40) // Diagnostic only: one physical stretch, in lens.move.
        }
        lastPointer = (clipped, clock.now); dragX = clipped
        if let i = stops.indices.min(by: { abs(stops[$0] - clipped) < abs(stops[$1] - clipped) }) { select(levels[i]) }
        idle?.cancel(); idle = clock.schedule(after: 0.08) { [weak self] in self?.lensStretch = 0; self?.needsLayout = true; self?.layoutSubtreeIfNeeded() }
        needsLayout = true; layoutSubtreeIfNeeded(); NSCursor.arrow.set()
    }
    func pointerUp() { guard isDragging else { return }; idle?.cancel(); isDragging = false; dragX = nil; lensStretch = 0; lastPointer = nil; needsLayout = true; layoutSubtreeIfNeeded() }
    private func select(_ effort: Effort) {
        guard levels.contains(effort), effort != value else { return }
        value = effort; configure(levels: levels, value: effort, daybreak: daybreak); onSelect?(effort); setAccessibilityValue(effort.label)
    }
    @discardableResult func step(_ delta: Int) -> Bool {
        guard let i = levels.firstIndex(of: value), !levels.isEmpty else { return false }
        let next = levels[min(max(0, i + delta), levels.count - 1)]; select(next)
        needsLayout = true; layoutSubtreeIfNeeded(); return true
    }
    override func accessibilityPerformIncrement() -> Bool { step(1) }
    override func accessibilityPerformDecrement() -> Bool { step(-1) }
    override func mouseDown(with event: NSEvent) { pointerDown(x: convert(event.locationInWindow, from: nil).x) }
    override func mouseDragged(with event: NSEvent) { pointerDragged(x: convert(event.locationInWindow, from: nil).x) }
    override func mouseUp(with event: NSEvent) { pointerUp() }
    func stopAmbient() { ambientEnabled = false; fill.animateAmbient = false; fill.stopAmbient(); lens.stopMotion() }
    func resumeAmbient() { ambientEnabled = true; fill.animateAmbient = !reduceMotion; fill.needsLayout = true; fill.layoutSubtreeIfNeeded() }
}

/// The exact Ultra colors/twinkle timings from product bundle.css:321–330. Entirely render-server driven.
@MainActor private final class OverlayTrack: OverlayView {
    var colors: [NSColor] = [] { didSet { needsDisplay = true } }
    var ultra = false { didSet { needsLayout = true } }
    var animateAmbient = true
    var ultraTail: CGFloat?
    var ticks: [CGFloat] = []
    var knob: CGFloat = 0
    private let aurora = CAGradientLayer(), sparks = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.addSublayer(aurora); layer?.addSublayer(sparks)
        aurora.startPoint = CGPoint(x: 0, y: 0.5); aurora.endPoint = CGPoint(x: 1, y: 0.5)
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).addClip()
        OverlayStyle.linear(colors, in: bounds)
        if let tail = ultraTail {
            let r = CGRect(x: bounds.width * tail, y: 0, width: bounds.width * (1 - tail), height: bounds.height)
            OverlayStyle.linear([.clear] + OverlayStyle.ultra.map { $0.withAlphaComponent(0.3) }, in: r)
        }
        for x in ticks {
            (x < knob - 6 ? NSColor.white.withAlphaComponent(0.7) : .labelColor.withAlphaComponent(0.28)).setFill()
            NSBezierPath(ovalIn: CGRect(x: x - 3, y: bounds.midY - 3, width: 6, height: 6)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2; layer?.masksToBounds = true
        aurora.frame = bounds; aurora.colors = ([NativePalette.accent] + OverlayStyle.ultra).map(\.cgColor)
        aurora.isHidden = !ultra; sparks.frame = bounds; sparks.isHidden = !ultra
        // M11.47 keeps the authored gradient, without an idle aurora or sparkle clock.
        aurora.locations=[0,0.38,0.68,1]
        stopAmbient()
        CATransaction.commit()
    }
    func stopAmbient() { aurora.removeAllAnimations(); sparks.sublayers?.forEach { $0.removeFromSuperlayer() } }
}
