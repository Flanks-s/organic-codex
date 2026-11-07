import AppKit

@MainActor final class OverlaySpeedSelector: OverlayView {
    let buttons: [OverlayButton]
    let label = OverlayGradientLabel(labelWithString: "Standard")
    private let lens = OverlayLens()
    private let clock: any OverlayClock
    private(set) var value: Speed = .standard
    private(set) var allowed: [Speed] = []
    private(set) var isDragging = false
    var onSelect: ((Speed) -> Void)?
    var reduceMotion = false
    private var dragX: CGFloat?
    private var previous: (CGFloat, Double)?
    private var stretch: CGFloat = 0
    private var idle: OverlayCancellation?
    private var entrance: OverlayCancellation?
    var glassAppearanceView: NSView { lens }
    func enter(curve: OverlayCurve, delay: Double, animated: Bool, contentGaussian: Bool = false) {
        entrance?.cancel()
        guard animated else { return }
        // Keep text's final layout: changing the selector width re-centred its 12pt label by half pixels.
        // Only the actual glass lens changes dimensions. It shares its normal motion owner with scrubbing.
        needsLayout=true;layoutSubtreeIfNeeded()
        let end=lens.targetMotionFrame
        let start=CGRect(x:end.minX+end.width*0.03,y:end.minY+16+end.height*0.03,width:end.width*0.94,height:end.height*0.94)
        lens.move(to:start,curve:curve,clock:clock,animated:false)
        if !contentGaussian {
            for button in buttons {OverlayMotion.animate(button.layer!, "transform.scale", from:0.94,to:1,curve:curve,delay:delay,retarget:false)}
            OverlayMotion.animate(label.layer!, "transform.scale", from:0.94,to:1,curve:curve,delay:delay,retarget:false)
            OverlayMotion.animate(layer!, "opacity", from:0,to:1,curve:curve,delay:delay,retarget:false)
        }
        entrance=clock.schedule(after:delay){[weak self] in guard let self else{return};self.lens.move(to:end,curve:curve,clock:self.clock,animated:true)}
    }
    func stopMotion() { entrance?.cancel(); entrance=nil; lens.stopMotion() }
    func retireMotion() { entrance?.cancel(); entrance=nil; lens.retireMotion() }
    var stops: [CGFloat] { [bounds.width / 6, bounds.width / 2, bounds.width * 5 / 6] }
    init(clock: any OverlayClock) {
        self.clock = clock; buttons = Speed.allCases.map { _ in OverlayButton(frame: .zero) }
        super.init(frame: .zero); wantsLayer = true
        lens.plain = true; addSubview(lens)
        for (i, button) in buttons.enumerated() {
            button.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: Speed.allCases[i].label)
            button.symbolConfiguration = .init(pointSize: 20, weight: .medium)
            button.setAccessibilityLabel(Speed.allCases[i].label)
            button.invoke = { [weak self] in self?.select(Speed.allCases[i]) }
            addSubview(button)
        }
        label.font = .systemFont(ofSize: 12); label.alignment = .center; label.wantsLayer = true; addSubview(label)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Speed")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(value: Speed, allowed: [Speed]) {
        self.allowed = Speed.allCases.filter(allowed.contains)
        self.value = self.allowed.contains(value) ? value : self.allowed.first ?? .standard
        label.stringValue = self.value.label
        label.gradient = self.value == .ultrafast ? OverlayStyle.ultra : []
        label.textColor = self.value == .ultrafast ? .white : self.value == .standard ? .secondaryLabelColor : .labelColor
        label.font = .systemFont(ofSize: 12, weight: self.value == .standard ? .regular : .semibold)
        for (i, button) in buttons.enumerated() {
            let speed = Speed.allCases[i], available = self.allowed.contains(speed), lit = available && speed.rawValue <= self.value.rawValue
            button.isEnabled = available
            button.image = NSImage(systemSymbolName: lit ? "bolt.fill" : "bolt", accessibilityDescription: speed.label)
            button.contentTintColor = lit ? (self.value == .standard ? .labelColor : self.value == .fast ? .systemYellow : OverlayStyle.ultra[1]) : .tertiaryLabelColor
            button.symbolGradient = lit && self.value == .ultrafast ? Array(OverlayStyle.ultra.reversed()) : []
            button.layer?.shadowColor = (self.value == .fast ? NSColor.systemYellow : OverlayStyle.ultra[1]).cgColor
            button.layer?.shadowOpacity = lit && self.value != .standard ? 0.35 : 0; button.layer?.shadowRadius = 4; button.layer?.shadowOffset = .zero
            button.alphaValue = available ? 1 : 0.25
            button.toolTip = available ? speed.label : speed.label + " is not available for this model"
            button.setAccessibilityHelp(button.toolTip)
        }
        setAccessibilityValue(self.value.label + ". Available: " + self.allowed.map(\.label).joined(separator: ", "))
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout(); let grid = max(1, window?.backingScaleFactor ?? 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * grid).rounded() / grid }
        let x = dragX ?? stops[value.rawValue - 1]
        let heldScale: CGFloat = isDragging ? 1.06 : 1
        lens.held = true
        let rect = CGRect(x: snap(x - 36 * heldScale), y: snap(24 - 22 * heldScale), width: ceil(72 * heldScale * grid) / grid, height: ceil(44 * heldScale * grid) / grid)
        lens.move(to: rect, curve: OverlayMotion.lensSlide, clock: clock, animated: !reduceMotion)
        for (i, button) in buttons.enumerated() { button.frame = CGRect(x: snap(stops[i] - 36), y: 2, width: 72, height: 44) }
        label.frame = CGRect(x: 0, y: 52, width: snap(bounds.width), height: 19)
        lens.layoutSubtreeIfNeeded()
    }
    @discardableResult func select(_ speed: Speed) -> Bool {
        guard allowed.contains(speed) else { return false }
        if speed != value { value = speed; configure(value: speed, allowed: allowed); onSelect?(speed) }
        needsLayout = true; layoutSubtreeIfNeeded(); return true
    }
    func pointerDown(x: CGFloat) { isDragging = true; previous = (x, clock.now); pointerDragged(x: x) }
    func pointerDragged(x: CGFloat) {
        guard isDragging else { return }
        let at = min(stops[2], max(stops[0], x)), index = stops.indices.min { abs(stops[$0] - at) < abs(stops[$1] - at) } ?? 0
        guard allowed.contains(Speed.allCases[index]) else { isDragging = false; dragX = nil; stretch = 0; needsLayout = true; layoutSubtreeIfNeeded(); return }
        if let previous, clock.now > previous.1 {
            let profile = OverlayExposure.profile(for: self)
            let step = abs(at - previous.0) / CGFloat(clock.now - previous.1) * profile.frameInterval
            let sample = ExposureSample(now: CGPoint(x: step, y: 0), earlier: .zero, frameInterval: profile.frameInterval, mmPerPoint: profile.mmPerPoint, settings: ExposureSettings())
            stretch = sample.gate // Not multiplied into the geometry; lens.move is the single stretch pass.
        }
        previous = (at, clock.now); dragX = at; _ = select(Speed.allCases[index])
        idle?.cancel(); idle = clock.schedule(after: 0.08) { [weak self] in self?.stretch = 0; self?.needsLayout = true; self?.layoutSubtreeIfNeeded() }
        NSCursor.arrow.set()
    }
    func pointerUp() { idle?.cancel(); isDragging = false; dragX = nil; stretch = 0; previous = nil; needsLayout = true; layoutSubtreeIfNeeded() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The entire bolt strip scrubs, including disabled tiers; unsupported values never commit.
        let p = convert(point, from: superview)
        return bounds.contains(p) && p.y < 48 ? self : super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { pointerDown(x: convert(event.locationInWindow, from: nil).x) }
    override func mouseDragged(with event: NSEvent) { pointerDragged(x: convert(event.locationInWindow, from: nil).x) }
    override func mouseUp(with event: NSEvent) { pointerUp() }
    override func accessibilityPerformIncrement() -> Bool { step(1) }
    override func accessibilityPerformDecrement() -> Bool { step(-1) }
    private func step(_ delta: Int) -> Bool {
        guard let i = allowed.firstIndex(of: value), allowed.indices.contains(i + delta) else { return false }
        return select(allowed[i + delta])
    }
}
