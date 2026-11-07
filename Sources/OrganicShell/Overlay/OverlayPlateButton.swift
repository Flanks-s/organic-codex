import AppKit

/// A drawn capsule, not an NSButtonCell. A filtered ancestor must never receive a native button's deferred
/// material/tint backing as its first frame. Text, symbol and plate enter the same bitmap in draw(_:).
@MainActor final class OverlayPlateButton: NSControl {
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var image: NSImage? { didSet { needsDisplay = true } }
    var contentTintColor: NSColor? { didSet { needsDisplay = true } }
    /// The icon's own colour (DaybreakButton: dawn icon, primary title); nil follows the title.
    var imageTintColor: NSColor? { didSet { needsDisplay = true } }
    /// Content from this inset instead of centred (DaybreakButton's .padding(.leading, 10)).
    var leadingInset: CGFloat? { didSet { needsDisplay = true } }
    /// The natural width with the product's 10 / 12 pt insets, for a plate sized to its content.
    var naturalWidth: CGFloat {
        let size = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold)])
        return ceil(10 + iconSize.width + (title.isEmpty || image == nil ? 0 : 6) + size.width + 12)
    }
    private var iconSize: CGSize {
        guard let image else { return .zero }
        if image.isTemplate, let symbol = image.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) { return symbol.size }
        return CGSize(width: 14, height: 14)
    }
    var fillColors: [NSColor] = [] { didSet { needsDisplay = true } }
    var invoke: (() -> Void)?
    private var armed = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        font = .systemFont(ofSize: 12, weight: .semibold); focusRingType = .none
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { armed = false; needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if fillColors.isEmpty { NSColor.white.withAlphaComponent(armed ? 0.14 : 0.08).setFill(); shape.fill() }
        else { NSGraphicsContext.saveGraphicsState(); shape.addClip(); OverlayStyle.linear(fillColors, in: bounds); NSGraphicsContext.restoreGraphicsState() }
        let color = (contentTintColor ?? .labelColor).withAlphaComponent(isEnabled ? 1 : 0.35)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        let iconSize = self.iconSize, icon = iconSize.width, gap: CGFloat = title.isEmpty || image == nil ? 0 : 6
        let scale = max(1, window?.backingScaleFactor ?? abs(NSGraphicsContext.current?.cgContext.ctm.a ?? 1))
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let x = snap(leadingInset ?? (bounds.midX - (size.width + icon + gap) / 2))
        if let image {
            // SF Symbol tint is a drawing operation, not contentTintColor's asynchronous button-cell machinery.
            let rect = CGRect(x: x, y: snap(bounds.midY - iconSize.height / 2), width: icon, height: iconSize.height)
            let symbol = image.isTemplate ? image.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? image : image
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (imageTintColor?.withAlphaComponent(isEnabled ? 1 : 0.35) ?? color).setFill(); rect.fill(using: .sourceAtop)
            NSGraphicsContext.current?.cgContext.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
        }
        (title as NSString).draw(at: CGPoint(x: x + icon + gap, y: snap(bounds.midY - size.height / 2)), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { armed = isEnabled; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { armed = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let commit = armed && bounds.contains(convert(event.locationInWindow, from: nil)); armed = false; needsDisplay = true
        if commit { performClick(nil) }
    }
    override func performClick(_ sender: Any?) { if isEnabled && !isHiddenOrHasHiddenAncestor { invoke?() } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled && !isHiddenOrHasHiddenAncestor else { return false }; performClick(nil); return true }
}
