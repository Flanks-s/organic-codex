import AppKit

/// Local native fixture content only. There is no URL loader, WebView, or send-to-Core action.
@MainActor final class BrowserPageMock: NSView {
    let page: BrowserPageID
    var annotationRect: CGRect?
    var annotationEnabled = false
    var annotationOpacity = 0.0
    var inkOpacity = 1.0
    var link: (() -> Void)?, pointer: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(page: BrowserPageID) { self.page = page; super.init(frame: BrowserIslandMetrics.page); wantsLayer = true; layer?.cornerRadius = 16; layer?.masksToBounds = true; setAccessibilityRole(.group); setAccessibilityLabel(MockBrowserSeed.pages[page]?.title) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        let blur = 10 * (1 - inkOpacity), scale = 0.985 + 0.015 * inkOpacity
        BrowserPaint.inkGroup(in: bounds, alpha: inkOpacity, blur: blur, scale: scale) {
            BrowserPaint.plate(self.bounds, radius: 16, color: NSColor(srgbRed: 17 / 255, green: 19 / 255, blue: 21 / 255, alpha: 1), stroke: NSColor.white.withAlphaComponent(0.12)); self.drawContent()
        }
        if let r = annotationRect, annotationOpacity > 0 {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.setAlpha(annotationOpacity)
            let outline = NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4), xRadius: 9, yRadius: 9); outline.lineWidth = 1.5; BrowserPaint.sky.setStroke(); outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func drawContent() {
        if page == .n {
            BrowserPaint.text("Tools", CGRect(x: 0, y: 234, width: 570, height: 14), size: 11, weight: .semibold, color: BrowserPaint.tertiary, alignment: .center)
            for (i, name) in ["Files", "Terminal", "New page"].enumerated() {
                let r = CGRect(x: 117 + i * 116, y: 260, width: 104, height: 84)
                BrowserPaint.plate(r, radius: 14, color: NSColor.white.withAlphaComponent(0.06))
                BrowserPaint.symbol(["folder", "terminal", "doc.badge.plus"][i], rect: CGRect(x: r.midX - 10, y: r.minY + 20.5, width: 20, height: 20), color: BrowserPaint.secondary)
                BrowserPaint.text(name, CGRect(x: r.minX, y: r.minY + 49.5, width: 104, height: 18), size: 12, alignment: .center)
            }; return
        }
        let name = page == .g ? "Component gallery" : page == .s ? "Orbit" : "orbit-lab"
        BrowserPaint.plate(CGRect(x: 18, y: 14, width: 16, height: 16), radius: page == .g ? 4 : 8, color: .clear, stroke: page == .s ? .systemYellow : page == .g ? .systemPurple : .systemGreen)
        BrowserPaint.text(name, CGRect(x: 42, y: 13, width: 150, height: 18), weight: .semibold)
        let chip = page == .s ? "staging" : page == .g ? "6006" : "dev"
        let nameWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        let chipWidth = (chip as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 12
        BrowserPaint.plate(CGRect(x: 50 + nameWidth, y: 13, width: chipWidth, height: 18), radius: 5, color: NSColor.white.withAlphaComponent(0.08))
        BrowserPaint.text(chip, CGRect(x: 56 + nameWidth, y: 14, width: chipWidth - 12, height: 16), size: 11, color: BrowserPaint.secondary)
        if page != .g {
            for (i, item) in (page == .s ? ["Releases", "Builds"] : ["Preview", "Tokens", "Logs"]).enumerated() {
                BrowserPaint.text(item, CGRect(x: 378 + i * 60, y: 14, width: 60, height: 18), size: 12, color: (page == .t ? i == 1 : i == 0) ? BrowserPaint.ink : BrowserPaint.secondary)
            }
        }
        NSColor.white.withAlphaComponent(0.07).setFill(); CGRect(x: 0, y: 43, width: 570, height: 1).fill()
        if page == .g {
            NSColor.white.withAlphaComponent(0.025).setFill(); CGRect(x: 0, y: 45, width: 160, height: 533).fill()
            for (i, s) in ["SIDEBAR", "Compact", "Regular", "Wide", "PROFILE", "Capsule", "Avatar"].enumerated() {
                if i == 1 { BrowserPaint.plate(CGRect(x: 10, y: 88, width: 140, height: 26), radius: 6, color: NSColor.white.withAlphaComponent(0.08)) }
                BrowserPaint.text(s, CGRect(x: 20, y: 66 + i * 27, width: 125, height: 20), size: i == 0 || i == 4 ? 10 : 12, color: BrowserPaint.secondary)
            }
            heading("Compact", subtitle: "Sidebar / Compact", x: 184)
            sidebar(CGRect(x: 184, y: 132, width: 362, height: 236), rows: 5, gallery: true)
            table([("Control", "Value"), ("density", "compact"), ("rows", "8"), ("selected", "2")], rect: CGRect(x: 184, y: 388, width: 362, height: 120)); return
        }
        if page == .s {
            heading("Orbit 0.1.2", subtitle: "Release notes · built 11-03 21:40", x: 24)
            let lines = ["Sidebar rows follow the system metrics.", "The profile capsule clears the list by 12 pt.", "The New Chat sheet is gone; a new chat opens in place.", "Approval copy was reviewed and linted.", "The search index rebuilds in smaller batches."]
            for (i, s) in lines.enumerated() { BrowserPaint.text("•  " + s, CGRect(x: 24, y: 136 + i * 34, width: 500, height: 25), size: 13) }; return
        }
        if page == .t {
            heading("Spacing", subtitle: "6 tokens · dark · compact · macOS", x: 24)
            table([("Token", "pt"), ("row.height", "28"), ("row.gap", "6"), ("glyph.size", "16"), ("capsule.clearance", "12"), ("sidebar.width", "240"), ("list.inset", "10")], rect: CGRect(x: 24, y: 132, width: 522, height: 210))
        } else {
            heading("Sidebar", subtitle: "Compact · 28 pt rows · 8 items", x: 24)
            sidebar(CGRect(x: 24, y: 132, width: 300, height: 372), rows: 8)
            table([("Token", "pt"), ("Row height", "28"), ("Row gap", "6"), ("Glyph", "16"), ("Capsule clearance", "12")], rect: CGRect(x: 348, y: 132, width: 198, height: 148))
            BrowserPaint.plate(CGRect(x: 348, y: 324, width: 198, height: 64), radius: 12, color: NSColor.white.withAlphaComponent(0.05))
            BrowserPaint.text("Spacing tokens ›", CGRect(x: 362, y: 336, width: 174, height: 20), weight: .semibold, color: BrowserPaint.sky)
            BrowserPaint.text("Every spacing value in this build", CGRect(x: 362, y: 357, width: 174, height: 18), size: 11, color: BrowserPaint.secondary)
        }
        BrowserPaint.text("●  Rebuilt in \(page == .t ? 198 : 212) ms · Hot reload connected", CGRect(x: 24, y: 532, width: 500, height: 22), size: 11, color: BrowserPaint.secondary)
    }
    private func heading(_ text: String, subtitle: String, x: Double) {
        BrowserPaint.text(text, CGRect(x: x, y: 66, width: 350, height: 30), size: 22, weight: .bold)
        BrowserPaint.text(subtitle, CGRect(x: x, y: 98, width: 370, height: 20), size: 12, color: BrowserPaint.secondary)
    }
    private func sidebar(_ r: CGRect, rows: Int, gallery: Bool = false) {
        BrowserPaint.plate(r, radius: 12, color: NSColor(srgbRed: 26 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1), stroke: NSColor.white.withAlphaComponent(0.08))
        let widths = gallery ? [96.0, 120, 80, 108, 70] : [92.0, 128, 74, 110, 86, 140, 64, 102]
        for i in 0..<rows {
            let y = r.minY + (gallery ? 14 : 12) + Double(i) * 34
            if i == 1 { BrowserPaint.plate(CGRect(x: r.minX + 10, y: y, width: r.width - (gallery ? 160 : 20), height: 28), radius: 7, color: NSColor.white.withAlphaComponent(0.08)) }
            BrowserPaint.plate(CGRect(x: r.minX + 20, y: y + 7, width: 14, height: 14), radius: 7, color: NSColor.white.withAlphaComponent(0.20))
            BrowserPaint.plate(CGRect(x: r.minX + 44, y: y + 11, width: widths[i], height: 6), radius: 3, color: NSColor.white.withAlphaComponent(0.18))
        }
        if !gallery { BrowserPaint.plate(CGRect(x: r.minX + 10, y: r.maxY - 46, width: r.width - 20, height: 36), radius: 18, color: NSColor.white.withAlphaComponent(0.07)) }
    }
    private func table(_ entries: [(String, String)], rect: CGRect) {
        for (i, row) in entries.enumerated() {
            let y = rect.minY + Double(i) * 28
            BrowserPaint.text(row.0, CGRect(x: rect.minX, y: y + 5, width: rect.width - 44, height: 20), size: i == 0 ? 11 : page == .t ? 11.5 : 12, color: BrowserPaint.secondary, monospaced: page == .t && i > 0)
            BrowserPaint.text(row.1, CGRect(x: rect.maxX - 44, y: y + 5, width: 44, height: 20), size: 12, weight: .semibold, alignment: .right)
            NSColor.white.withAlphaComponent(0.06).setFill(); CGRect(x: rect.minX, y: y + 27, width: rect.width, height: 1).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); tracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) { pointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointer?(nil) }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if page == .a && !annotationEnabled && CGRect(x: 348, y: 324, width: 198, height: 64).contains(p) { link?() }
    }
    override func resetCursorRects() { if annotationEnabled { addCursorRect(bounds, cursor: .crosshair) } }
    func retire() {
        pointer = nil; link = nil; setAccessibilityHidden(true); setAccessibilityElement(false); isHidden = true
        if let tracking { removeTrackingArea(tracking) }; tracking = nil; discardCursorRects()
    }
}
