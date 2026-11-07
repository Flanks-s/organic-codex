import AppKit

/// Static working dots using the existing compact metrics. No idle CA light or breath clock.
@MainActor final class SheetActivityDots: OverlayView {
    private let dots = [SheetActivityDot(frame: .zero), SheetActivityDot(frame: .zero), SheetActivityDot(frame: .zero)]
    var still = false { didSet { if oldValue != still { restart() } } }
    var suspended = false { didSet { if oldValue != suspended { restart() } } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; for dot in dots { addSubview(dot) }; setAccessibilityElement(false); restart()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); let s = max(1, window?.backingScaleFactor ?? 1), d = floor(2.5 * s) / s, width = 3 * d + 4
        for (i, dot) in dots.enumerated() { dot.frame = SheetStyle.snap(CGRect(x: (12 - width) / 2 + CGFloat(i) * (d + 2), y: (12 - d) / 2, width: d, height: d), scale: s) }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restart() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true; layoutSubtreeIfNeeded() }
    override var isHidden: Bool { didSet { if oldValue != isHidden { restart() } } }
    private func restart() {
        layer?.removeAnimation(forKey: "sheets.dots.breathe"); dots.forEach { $0.layer?.removeAllAnimations() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for dot in dots { dot.alphaValue = 0.62 * 0.78 }
        layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }
    /// cacheDisplay uses model alpha. Sample the live presentation alpha for a synchronous surface capture;
    /// restoring in the same disabled-actions transaction leaves the render-server animation uninterrupted.
    func samplePresentationForCapture() -> () -> Void {
        let values = dots.map(\.alphaValue)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for dot in dots { if let value = dot.layer?.presentation()?.opacity { dot.alphaValue = CGFloat(value) } }
        return { [weak self] in if let self { for (i, dot) in self.dots.enumerated() { dot.alphaValue = values[i] } }; CATransaction.commit() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor private final class SheetActivityDot: OverlayView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { guard !SheetStyle.capturesPlates else {return};NSColor.labelColor.setFill(); NSBezierPath(ovalIn: bounds).fill() }
}
