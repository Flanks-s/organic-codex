import AppKit

/// macOS 26 sidebar metrics, calibrated against SidebarView at 240 × 820, 1× / 2×.
/// Keep the window's split constraints in App consistent with these public host constants.
@MainActor enum NormieSidebarMetrics {
    static let minimumWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 400
    static let preferredThicknessFraction = CGFloat(280.0 / 1280.0)
    static let rowHeight: CGFloat = 32
    static let firstSectionHeight: CGFloat = 20
    static let sectionHeight: CGFloat = 32
    static let nestedTitleX: CGFloat = 35 // NSTextField's two-point text inset gives 37.
    static let titleX: CGFloat = 48
    static let iconX: CGFloat = 26
    static let trailingInset: CGFloat = 16
    static var primary: NSColor { NativeAppearance.current.foreground == nil ? .white : NativePalette.label }
    static var secondary: NSColor { NativeAppearance.current.foreground == nil ? .white.withAlphaComponent(0.355) : NativePalette.secondaryLabel }
    static var tertiary: NSColor { NativeAppearance.current.foreground == nil ? .white.withAlphaComponent(0.27) : NativePalette.tertiaryLabel }
    static var selection: NSColor { NativeDisplayOptions.plate(.white, alpha: 0.07) }
}

/// A clear child of NSSplitViewItem(sidebarWithViewController:). The split owns the system
/// sidebar material, just as it does behind the product's transparent NSHostingView.
/// The proxy is ONLY for cacheDisplay without a window: WindowServer owns live vibrancy.
@MainActor final class NormieSidebarSurface: NormieView {
    var accountTop: CGFloat = 0
    var searchBottom: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        if NativeDisplayOptions.shared.state.reducesEffects {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
        } else if window == nil {
            NSColor(srgbRed: 0.153, green: 0.169, blue: 0.176, alpha: 1).setFill(); bounds.fill()
            NSGradient(starting: .clear, ending: NSColor(srgbRed: 0.15, green: 0.34, blue: 0.36, alpha: 0.12))?
                .draw(in: bounds, angle: -90)
        }
        // safeAreaBar's one-backing-pixel separators, without an opaque canvas over the material.
        NSColor.white.withAlphaComponent(NativeDisplayOptions.shared.state.increaseContrast ? 0.3 : 0.08).setFill()
        let pixel = 1 / scale
        if searchBottom > 0 { CGRect(x: 0, y: searchBottom, width: bounds.width, height: pixel).fill() }
        if accountTop > 0 { CGRect(x: 0, y: accountTop - pixel, width: bounds.width, height: pixel).fill() }
    }
}

/// Symbols use their own draw path, so native and flight/cacheDisplay captures agree (§7.5).
@MainActor final class NormieSidebarSymbol: NormieView {
    private var rendered: NSImage?
    var symbol = "" { didSet { if oldValue != symbol { rendered = nil; needsDisplay = true } } }
    var pointSize: CGFloat = 13 { didSet { if oldValue != pointSize { rendered = nil; needsDisplay = true } } }
    var tint: NSColor = .labelColor { didSet { if oldValue != tint { rendered = nil; needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if symbol == "circle.fill" { tint.setFill(); NSBezierPath(ovalIn: bounds).fill(); return }
        if rendered == nil {
            guard !symbol.isEmpty, let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))?
                .withSymbolConfiguration(.preferringMonochrome()) else { return }
            if symbol == "folder" || symbol == "folder.fill" {
                rendered = source
            } else {
                // Keep the established raster path for the other sidebar symbols. Its 1×
                // optical compensation is measured separately below; preserve filled knockouts.
                let color = tint
                rendered = NSImage(size:source.size,flipped:false) { rect in
                    source.draw(in:rect); color.setFill(); rect.fill(using:.sourceIn); return true
                }
            }
        }
        guard let image = rendered else { return }
        // Draw the configured symbol at its native point size. Scaling its padded NSImage canvas
        // down to the optical 14/16 pt slot made the product's icons two pixels too small.
        var size = image.size, offset = CGPoint.zero
        switch symbol {
        case "magnifyingglass" where pointSize == 13: size.width += 1; size.height -= 1; offset.x = 1.5
        case "folder", "folder.fill": offset = CGPoint(x: 0, y: -1)
        case "exclamationmark.triangle.fill": size.height -= 1; offset.y = -1
        case "hand.raised.fill": offset.y = -1
        case "questionmark.bubble.fill": offset = CGPoint(x: -1, y: -1)
        default: break
        }
        // SF Symbols choose a different low-resolution optical representation at 1×.
        // Preserve the measured 2× glyph, while matching the HP 1× reference separately.
        if scale == 1 {
            if symbol == "magnifyingglass", pointSize == 13 { size.width -= 2; size.height += 1 }
            if symbol == "exclamationmark.triangle.fill" { size.width -= 2; offset.y += 1 }
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rect = NormieDrawing.rect(CGRect(x: bounds.midX-size.width/2+offset.x,
                                              y: bounds.midY-size.height/2+offset.y,
                                              width:size.width,height:size.height),scale:scale)
        if symbol == "folder" || symbol == "folder.fill" {
            // Tint the folder vector at the actual backing scale, without an intermediate image.
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.beginTransparencyLayer(auxiliaryInfo:nil)
            image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            tint.setFill(); rect.fill(using:.sourceIn)
            context.endTransparencyLayer()
        } else {
            image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
    }
}

@MainActor final class NormieSidebarSpinner: NSProgressIndicator {
    var running = false { didSet { syncAnimation() } }
    var presented = true { didSet { syncAnimation() } }
    private(set) var verificationAnimating = false
    /// Native sidebar hosts can leave the screen through opacity/translation without being hidden.
    static func setPresented(_ presented: Bool, in view: NSView) {
        if let spinner = view as? NormieSidebarSpinner { spinner.presented = presented }
        for child in view.subviews { setPresented(presented, in: child) }
    }
    private func syncAnimation() {
        if window != nil && !isHiddenOrHasHiddenAncestor && running && presented {
            startAnimation(nil)
        } else {
            stopAnimation(nil)
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncAnimation() }
    override func viewDidHide() { super.viewDidHide(); syncAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); syncAnimation() }
    override func startAnimation(_ sender: Any?) {
        verificationAnimating = true
        super.startAnimation(sender)
    }
    override func stopAnimation(_ sender: Any?) {
        verificationAnimating = false
        super.stopAnimation(sender)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard window == nil else { super.draw(dirtyRect); return }
        // A frozen mini spinner, because an offscreen indicator never starts a WindowServer clock.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let path = NSBezierPath(); path.lineWidth = 1.25; path.lineCapStyle = .round
            path.move(to: CGPoint(x: center.x + cos(angle) * 2.2, y: center.y + sin(angle) * 2.2))
            path.line(to: CGPoint(x: center.x + cos(angle) * 4.5, y: center.y + sin(angle) * 4.5))
            NSColor.secondaryLabelColor.withAlphaComponent(CGFloat(i + 1) / 8).setStroke(); path.stroke()
        }
    }
}

/// SidebarView uses IdentityGlyph(size: 15, weight: 2.2) inside a 16 pt slot.
/// The generic NormiePlanetView is also used outside the sidebar, so keep this optical size local.
@MainActor final class NormieSidebarIdentity: NormieView {
    var identity = OrbIdentity.assigned(0) { didSet { if identity != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        let rect = CGRect(x:bounds.midX-7.5,y:bounds.midY-7.5,width:15,height:15)
        BodyFaceDrawing.draw(identity.resolvedBodyID,in:rect)
    }
}
