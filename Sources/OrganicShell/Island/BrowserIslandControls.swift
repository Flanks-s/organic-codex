import AppKit
import CoreText
import CoreImage

@MainActor enum BrowserPaint {
    static let ink = NSColor(white: 1, alpha: 0.92), secondary = NSColor(white: 1, alpha: 0.55), tertiary = NSColor(white: 1, alpha: 0.35)
    static let sky = NSColor(srgbRed: 93 / 255, green: 180 / 255, blue: 240 / 255, alpha: 1)
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static func text(_ text: String, _ rect: CGRect, size: Double = 13, weight: NSFont.Weight = .regular,
                     color: NSColor = ink, alignment: NSTextAlignment = .left, monospaced: Bool = false) {
        guard let cg = NSGraphicsContext.current?.cgContext, rect.width > 0 else { return }
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, size, nil)
        let resolved = (color.usingColorSpace(.deviceRGB) ?? .white).cgColor
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolved])
        var line = CTLineCreateWithAttributedString(string)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))
            line = CTLineCreateTruncatedLine(line, rect.width, .end, token) ?? line
        }
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let offset = alignment == .center ? max(0, (rect.width - width) / 2) : alignment == .right ? max(0, rect.width - width) : 0
        cg.saveGState(); cg.clip(to: rect); cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: rect.minX + offset, y: rect.minY + ceil(CTFontGetAscent(ctFont)))
        CTLineDraw(line, cg); cg.restoreGState()
    }
    static func plate(_ rect: CGRect, radius: Double, color: NSColor, stroke: NSColor? = nil) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius); color.setFill(); path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 0.5; path.stroke() }
    }
    static func glass(_ rect: CGRect, radius: Double, annotation: Double = 0, shadow: Bool = true) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        if shadow { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.28); s.shadowBlurRadius = 10; s.shadowOffset = CGSize(width: 0, height: -6); s.set() }
        let k = BrowserIslandMath.clamp(annotation)
        plate(rect, radius: radius, color: NSColor(srgbRed: (50 + 15 * k) / 255, green: (52 + 44 * k) / 255, blue: (50 + 65 * k) / 255, alpha: 1), stroke: NSColor.white.withAlphaComponent(0.30))
        NSGraphicsContext.restoreGraphicsState()
    }
    static func symbol(_ name: String, rect: CGRect, color: NSColor = ink) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium).applying(.init(paletteColors: [color]))) else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    /// The same finite Gaussian ink treatment is used by native drawing and offscreen captures.
    static func inkGroup(in rect: CGRect, alpha: Double, blur: Double, scale: Double = 1, draw: () -> Void) {
        guard alpha > 0.001, rect.width > 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        if blur < 0.05 {
            cg.saveGState(); cg.setAlpha(alpha); cg.translateBy(x: rect.midX, y: rect.midY); cg.scaleBy(x: scale, y: scale); cg.translateBy(x: -rect.midX, y: -rect.midY); draw(); cg.restoreGState(); return
        }
        let backing = NSGraphicsContext.current?.cgContext.ctm.a ?? 1, density = max(1, min(2, abs(backing)))
        let padded = rect.insetBy(dx: -8, dy: -8)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(padded.width * density)), pixelsHigh: Int(ceil(padded.height * density)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let target = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = target
        target.cgContext.scaleBy(x: density, y: density); target.cgContext.translateBy(x: -padded.minX, y: padded.maxY); target.cgContext.scaleBy(x: 1, y: -1)
        draw(); target.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return }
        let ci = CIImage(cgImage: image).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * density])
        guard let output = context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)) else { return }
        cg.saveGState(); cg.setAlpha(alpha); cg.translateBy(x: rect.midX, y: rect.midY); cg.scaleBy(x: scale, y: scale); cg.translateBy(x: -rect.midX, y: -rect.midY)
        NSImage(cgImage: output, size: padded.size).draw(in: padded, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil); cg.restoreGState()
    }
}

@MainActor final class BrowserActionButton: NSControl {
    var title = "", symbol: String?, caption: String?
    var invoke: (() -> Void)?, hover: ((Bool) -> Void)?
    var optionInvoke: (() -> Void)?
    var dismiss: (() -> Void)?
    var participates = true { didSet { setAccessibilityHidden(!participates); setAccessibilityElement(participates) } }
    var inkAlpha = 1.0, inkBlur = 0.0, inkScale = 1.0, selected = false
    var drawsHighlight = true, plateOpacity = 0.0, selectionStyle = "sky"
    var textAlignment: NSTextAlignment = .center
    var secondarySymbol: String?, symbolBlend = 0.0
    var leadingSymbol: String?, shortcut: String?
    private var enabledStorage = true
    override var isEnabled: Bool { get { enabledStorage } set { enabledStorage = newValue; needsDisplay = true } }
    private var inside = false, pressed = false, focused = false, tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { participates && isEnabled && !isHiddenOrHasHiddenAncestor }
    override init(frame: NSRect) { super.init(frame: frame); cell = nil; setAccessibilityRole(.button); focusRingType = .none }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(label: String, enabled: Bool, selected: Bool = false) {
        title = label; isEnabled = enabled; self.selected = selected
        setAccessibilityLabel(label); setAccessibilityEnabled(enabled); setAccessibilityValue(selected ? "On" : nil); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        BrowserPaint.inkGroup(in: bounds, alpha: inkAlpha, blur: inkBlur, scale: inkScale) {
            if self.plateOpacity > 0 { BrowserPaint.plate(self.bounds, radius: 6, color: NSColor.white.withAlphaComponent(self.plateOpacity)) }
            if self.selected && self.selectionStyle != "none" { BrowserPaint.plate(self.bounds.insetBy(dx: 2, dy: 2), radius: 10, color: self.selectionStyle == "sky" ? BrowserPaint.sky : NSColor.white.withAlphaComponent(0.19)) }
            else if self.drawsHighlight && self.inside && self.isEnabled { BrowserPaint.plate(self.bounds, radius: 12, color: NSColor.white.withAlphaComponent(0.10)) }
            let color = self.isEnabled ? BrowserPaint.ink : BrowserPaint.tertiary
            let icon = CGRect(x: self.bounds.midX - 8, y: self.bounds.midY - 8, width: 16, height: 16)
            if let symbol = self.symbol { BrowserPaint.inkGroup(in: icon, alpha: 1 - self.symbolBlend, blur: 5 * self.symbolBlend, scale: 1 - 0.2 * self.symbolBlend) { BrowserPaint.symbol(symbol, rect: icon, color: color) } }
            if let symbol = self.secondarySymbol { BrowserPaint.inkGroup(in: icon, alpha: self.symbolBlend, blur: 5 * (1 - self.symbolBlend), scale: 0.8 + 0.2 * self.symbolBlend) { BrowserPaint.symbol(symbol, rect: icon, color: color) } }
            if let symbol = self.leadingSymbol {
                let r = CGRect(x: 10, y: self.bounds.midY - 8, width: 16, height: 16)
                BrowserPaint.plate(r, radius: 4, color: NSColor.white.withAlphaComponent(0.10)); BrowserPaint.symbol(symbol, rect: r.insetBy(dx: 2, dy: 2), color: color)
            }
            if let caption = self.caption {
                var r = self.bounds.insetBy(dx: 7, dy: max(0, (self.bounds.height - 16) / 2))
                // Permission segments use their entire 42 pt slot, as on the adopted board.
                if self.selectionStyle == "none" { r.origin.x = 0; r.size.width = self.bounds.width }
                if self.leadingSymbol != nil { r.origin.x = 35; r.size.width = max(0, self.bounds.width - 42) }
                if self.shortcut != nil { r.size.width = max(0, r.width - 40) }
                BrowserPaint.text(caption, r, size: self.leadingSymbol == nil ? 12 : 13, weight: self.selected ? .semibold : .regular, color: color, alignment: self.textAlignment)
            }
            if let shortcut = self.shortcut { BrowserPaint.text(shortcut, CGRect(x: self.bounds.width - 42, y: self.bounds.midY - 8, width: 30, height: 18), size: 12, color: BrowserPaint.tertiary, alignment: .right) }
            if self.window?.firstResponder === self { BrowserPaint.plate(self.bounds.insetBy(dx: 1, dy: 1), radius: 10, color: .clear, stroke: .keyboardFocusIndicatorColor) }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { inside = true; needsDisplay = true; if participates { hover?(true) } }
    override func mouseExited(with event: NSEvent) { inside = false; needsDisplay = true; if participates { hover?(focused) } }
    override func becomeFirstResponder() -> Bool { guard acceptsFirstResponder else { return false }; focused = true; hover?(true); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { focused = false; if participates { hover?(inside) }; needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) { pressed = participates && isEnabled }
    override func mouseUp(with event: NSEvent) {
        let fire = pressed && bounds.contains(convert(event.locationInWindow, from: nil)); pressed = false
        if fire { if event.modifierFlags.contains(.option), let optionInvoke { optionInvoke() } else { performClick(nil) } }
    }
    override func performClick(_ sender: Any?) { if acceptsFirstResponder { invoke?() } }
    override func accessibilityPerformPress() -> Bool { guard acceptsFirstResponder else { return false }; invoke?(); return true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { dismiss?() } else if [36, 49].contains(event.keyCode) { performClick(nil) } else { super.keyDown(with: event) } }
    func retire() {
        participates = false; invoke = nil; optionInvoke = nil; hover = nil; dismiss = nil; pressed = false; inside = false; focused = false; isHidden = true; nextKeyView = nil; setAccessibilityCustomActions(nil)
        if let tracking { removeTrackingArea(tracking) }; tracking = nil
    }
}
