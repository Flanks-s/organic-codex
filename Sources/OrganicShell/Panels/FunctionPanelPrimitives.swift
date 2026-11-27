import AppKit
import CoreText

@MainActor enum FunctionPanelPaint {
    static func colour(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    static func text(_ text: String, _ rect: CGRect, size: CGFloat = 12, alpha: CGFloat = 0.9,
                     weight: NSFont.Weight = .regular, align: NSTextAlignment = .left, mono: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = align
        paragraph.lineBreakMode = rect.height > size * 1.8 ? .byWordWrapping : .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: size,
                    weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                                                             .paragraphStyle: paragraph])
    }
    static func wrappedHeight(_ text: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: 1000),
            options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .paragraphStyle: paragraph])
        return max(19, ceil(rect.height))
    }
    static func plate(_ rect: CGRect, radius: CGFloat, fill: NSColor, border: Bool = true) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if border { NSColor.white.withAlphaComponent(0.15).setStroke(); path.lineWidth = 0.5; path.stroke() }
    }
}

/// One shaped, complete line. Drawing and inspection retain the very same CTLine;
/// no rectangular clipping is used to conceal overflow or parts of glyphs.
@MainActor struct FunctionPanelTrackText {
    static let truncatesOverflow = true
    let agentID: String
    let role: String
    let source: String
    let line: CTLine
    let row: CGRect
    let band: CGRect
    let item: CGRect
    let baseline: CGPoint
    let fragment: CGRect
    let glyphs: CGRect
    let truncated: Bool

    init(_ source: String, agentID: String, role: String, row: CGRect, band: CGRect, item: CGRect,
         size: CGFloat, alpha: CGFloat, weight: NSFont.Weight = .regular) {
        self.agentID = agentID; self.role = role; self.source = source
        self.row = row; self.band = band; self.item = item
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
        // Each history entry occupies one visual line, including explicit newlines.
        let single = source.components(separatedBy: .newlines).joined(separator: " ")
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: single,
                attributes: attributes) as CFAttributedString)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…",
                attributes: attributes) as CFAttributedString)
        let available = max(0, row.width - 2)
        truncated = Self.truncatesOverflow && CTLineGetTypographicBounds(full, nil, nil, nil) > Double(available)
        line = truncated ? CTLineCreateTruncatedLine(full, Double(available), .end, token) ?? token : full
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        baseline = CGPoint(x: row.minX + 1, y: row.minY + (row.height - ascent - descent - leading) / 2 + ascent)
        fragment = CGRect(x: baseline.x, y: baseline.y - ascent, width: width, height: ascent + descent + leading)
        let ink = CTLineGetImageBounds(line, nil)
        glyphs = CGRect(x: baseline.x + ink.minX, y: baseline.y - ink.maxY, width: ink.width, height: ink.height)
    }
    func draw() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: baseline.x, y: baseline.y); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity; context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

@MainActor class FunctionPanelPlane: NSView {
    override var isFlipped: Bool { true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override init(frame: NSRect) { super.init(frame: frame) }
}

@MainActor final class FunctionPanelInk: FunctionPanelPlane {
    var commands: [() -> Void] = []
    override func draw(_ dirtyRect: NSRect) { for command in commands { command() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native glass is kept separate from text. The underlay also makes windowless structure captures readable.
/// Windowless PNGs do not certify WindowServer's native material; a window host uses the very same glass view.
@MainActor final class FunctionPanelGlass: FunctionPanelPlane {
    let material = NSGlassEffectView()
    var radius: CGFloat = 24 { didSet { material.cornerRadius = radius; needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        material.style = .regular
        material.tintColor = NSColor(srgbRed: 0.22, green: 0.23, blue: 0.22, alpha: 0.52)
        material.contentView = FunctionPanelPlane(frame: .zero)
        addSubview(material)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); if material.superview === self { material.frame = bounds } }
    override func draw(_ dirtyRect: NSRect) {
        FunctionPanelPaint.plate(bounds.insetBy(dx: 0.3, dy: 0.3), radius: radius,
                                 fill: NSColor(srgbRed: 0.22, green: 0.23, blue: 0.22, alpha: 0.88))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class FunctionPanelButton: NSControl {
    var label = "" { didSet { setAccessibilityLabel(label); needsDisplay = true } }
    var symbol: String?
    var invoke: (() -> Void)?
    var hover: ((Bool) -> Void)?
    var key: ((UInt16) -> Bool)?
    var onFocus: ((Bool) -> Void)?
    var customPaint: ((CGRect) -> Void)?
    var selected = false
    var focused = false
    var circular = false
    var filled = true
    var pointerInside = false
    var inkInset: CGFloat = 0
    private var enabledValue = true
    override var isEnabled: Bool {
        get { enabledValue }
        set { enabledValue = newValue; setAccessibilityEnabled(newValue); needsDisplay = true }
    }
    var live = true {
        didSet { setAccessibilityHidden(!live); setAccessibilityElement(live) }
    }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { live && isEnabled && !isHiddenOrHasHiddenAncestor }
    override init(frame: NSRect) {
        super.init(frame: frame); cell = nil; focusRingType = .none
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if inkInset > 0 { NSBezierPath(ovalIn: bounds.insetBy(dx: inkInset, dy: inkInset)).addClip() }
        if filled {
            FunctionPanelPaint.plate(bounds.insetBy(dx: 0.5, dy: 0.5), radius: circular ? bounds.height / 2 : min(12,
                    bounds.height / 2),
                                     fill: NSColor.white.withAlphaComponent(
                                         selected ? 0.19 : pointerInside ? 0.13 : 0.065))
        }
        if let customPaint { customPaint(bounds) }
        else if let symbol, bounds.width < 48, let image = NSImage(systemSymbolName: symbol,
            accessibilityDescription: nil) {
            image.withSymbolConfiguration(.init(pointSize: 12, weight: .medium).applying(.init(paletteColors: [.white]))
            )?.draw(in: CGRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14))
        } else { FunctionPanelPaint.text(label, bounds.insetBy(dx: 7, dy: max(0, (bounds.height - 15) / 2)), size: 11.5,
                weight: .medium, align: .center) }
        if focused {
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: circular ? bounds.height / 2 : 8, yRadius: circular ? bounds.height / 2 : 8)
            path.lineWidth = 1.5; path.stroke()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard live, !isHidden, isEnabled else { return nil }
        let local = convert(point, from: superview)
        if circular {
            let x = (local.x - bounds.midX) / max(1, bounds.width / 2)
            let y = (local.y - bounds.midY) / max(1, bounds.height / 2)
            if x * x + y * y > 1 { return nil }
        }
        return super.hitTest(point)
    }
    var onBeginIntent: (() -> Void)?
    private var nativePress = false
    override func mouseDown(with event: NSEvent) {
        if live { window?.makeFirstResponder(self); if event.clickCount <= 1 { onBeginIntent?() }; invoke?() }
    }
    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder else { return false }
        let result = super.becomeFirstResponder()
        if result { focused = true; onFocus?(true); needsDisplay = true }
        return result
    }
    override func resignFirstResponder() -> Bool {
        focused = false; onFocus?(false); needsDisplay = true
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        if key?(event.keyCode) == true { return }
        if [36, 49, 76].contains(event.keyCode) {
            if !event.isARepeat { onBeginIntent?() }
            nativePress = true; _ = accessibilityPerformPress(); nativePress = false
        }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard live, isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        if !nativePress { onBeginIntent?() } // One explicit AX command is a fresh gesture.
        invoke?(); return true
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        tracking = next; addTrackingArea(next); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; hover?(true); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; hover?(false); needsDisplay = true }
}
