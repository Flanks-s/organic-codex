import AppKit
import CoreText

/// Borderless, capture-consistent replacement for the composer's three pull-down buttons.
/// The first item is the presentation label, just as for the previous pullsDown NSPopUpButton;
/// it is hidden from the real NSMenu. All other items retain their original target/actions.
@MainActor final class NativeComposerMenuButton: NSControl {
    struct SegmentBlend {
        let from: NSImage, to: NSImage
        var progress: CGFloat
    }
    var segmentBlend: SegmentBlend? { didSet { needsDisplay = true } }
    private var presentationItem: NSMenuItem?
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var drawingFont: NSFont? = .systemFont(ofSize: 11)
    override var font: NSFont? { get { drawingFont } set { drawingFont = newValue; needsDisplay = true } }
    private var drawingEnabled = true
    override var isEnabled: Bool { get { drawingEnabled } set { drawingEnabled = newValue; needsDisplay = true; setAccessibilityEnabled(newValue) } }
    var contentTintColor: NSColor?
    var horizontalPadding: CGFloat = 4
    var chevronSpacing: CGFloat = 6
    /// FocusedSegmentControls gives the model and editor equal proposals. SwiftUI's Text then returns the
    /// width of the truncated line, leaving its unused share to the editor. Other menu buttons keep their sizing.
    var segmentLabelSizing = false
    private static let segmentChevron = NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil)?
        .withSymbolConfiguration(.init(pointSize:8,weight:.bold))
    private var drawingScale: CGFloat { max(1,window?.backingScaleFactor ?? (superview as? NativeComposer)?.controlScale ?? 2) }
    private var chevronWidth: CGFloat {
        segmentLabelSizing ? ceil((Self.segmentChevron?.alignmentRect.width ?? 9.5)*drawingScale)/drawingScale : 8
    }
    var symbolTintColor: NSColor?
    var isBordered = false
    private var drawingPressed = false
    var autoenablesItems: Bool {
        get { menu?.autoenablesItems ?? false }
        set { menu?.autoenablesItems = newValue }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = nil; menu = NSMenu(); menu?.autoenablesItems = false
        font = .systemFont(ofSize: 11); focusRingType = .none
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func removeAllItems() { presentationItem = nil; menu?.removeAllItems(); needsDisplay = true }
    func addItem(withTitle title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isHidden = true; presentationItem = item; menu?.addItem(item); needsDisplay = true
    }
    func item(at index: Int) -> NSMenuItem? { menu?.item(at: index) }
    func itemTitle(at index: Int) -> String { item(at: index)?.title ?? "" }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    func reconcilePointerHover(_ point: CGPoint?) {
        let inside = point.map { visibleRect.contains($0) && NativePointerShield.permits(self, localPoint: $0) } ?? false
        guard hovering != inside else { return }; hovering = inside; needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { hovering = NativePointerShield.permits(self, localPoint: convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func mouseDown(with event: NSEvent) { performClick(self) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 125 { performClick(self) }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled,window != nil,NativeInteractionSurface.permits(self)else{return false};performClick(self);return true
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled,NativeInteractionSurface.permits(self) else{return}
        drawingPressed = true; needsDisplay = true
        openMenu()
        drawingPressed = false; needsDisplay = true
    }
    private func openMenu() {
        guard isEnabled,window != nil,NativeInteractionSurface.permits(self)else{return}
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }
    /// ModelButton and AccessMenu take their intrinsic label width, not a fraction of the dock.
    var preferredWidth: CGFloat {
        if segmentLabelSizing { return width(fittingLabelProposal: .greatestFiniteMagnitude) }
        let width = ((presentationItem?.title ?? "") as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:13)]).width
        return ceil(width + (presentationItem?.image == nil ? 0:17) + (horizontalPadding*2+8+chevronSpacing))
    }
    func width(fittingLabelProposal proposal: CGFloat) -> CGFloat {
        let extra = horizontalPadding*2 + chevronWidth + chevronSpacing + (presentationItem?.image == nil ? 0:17)
        let attributes: [NSAttributedString.Key:Any] = [.font:font ?? .systemFont(ofSize:13)]
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:presentationItem?.title ?? "",attributes:attributes))
        let token=CTLineCreateWithAttributedString(NSAttributedString(string:"…",attributes:attributes))
        let offered=max(0,proposal-extra)
        let fitted=CTLineCreateTruncatedLine(line,Double(offered),.end,token)
        let width=fitted.map { CGFloat(CTLineGetTypographicBounds($0,nil,nil,nil)) } ?? 0
        return extra + ceil(width*drawingScale)/drawingScale
    }
    override func draw(_ dirtyRect: NSRect) {
        if let blend = segmentBlend {
            for (image, alpha) in [(blend.from, 1-blend.progress), (blend.to, blend.progress)] where alpha > 0 {
                image.draw(in: CGRect(origin:.zero,size:image.size), from:.zero, operation:.sourceOver,
                           fraction:alpha,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.none])
            }
            return
        }
        let scale = drawingScale
        func p(_ n: CGFloat) -> CGFloat { (n * scale).rounded() / scale }
        if isEnabled && (hovering || drawingPressed) {
            NativeDisplayOptions.plate(alpha:drawingPressed ? 0.14 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let base = contentTintColor ?? NSColor.secondaryLabelColor
        let color = base.withAlphaComponent(base.alphaComponent * (isEnabled ? 1 : 0.45))
        let chevronWidth = self.chevronWidth, padding = horizontalPadding
        var x = padding
        if let icon = presentationItem?.image {
            let size: CGFloat = 13
            let baseIcon=symbolTintColor ?? base
            let iconColor=baseIcon.withAlphaComponent(baseIcon.alphaComponent*(isEnabled ? 1:0.45))
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.init(paletteColors: [iconColor]))
            let copy = icon.withSymbolConfiguration(configuration) ?? icon
            color.set(); copy.draw(in: CGRect(x: p(x), y: p((bounds.height-size)/2), width: size, height: size),
                                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                                  hints: [.interpolation: NSImageInterpolation.high])
            x += size + (presentationItem?.title.isEmpty == false ? 4 : 0)
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        // SwiftUI Text does not tighten by default. NSString's truncating paragraph otherwise squeezes
        // the glyph spacing before adding its ellipsis, so a correctly measured label still paints differently.
        if segmentLabelSizing { style.tighteningFactorForTruncation = 0 }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: style]
        let text = presentationItem?.title ?? ""
        let textHeight = ceil((font ?? .systemFont(ofSize: 11)).boundingRectForFont.height)
        let spacing = segmentLabelSizing ? chevronSpacing : 2
        (text as NSString).draw(in: CGRect(x: p(x), y: p((bounds.height-textHeight)/2), width: max(0, p(bounds.width-x-chevronWidth-padding-spacing)), height: textHeight), withAttributes: attributes)
        let path = NSBezierPath(); path.lineWidth = 1
        let cx = p(bounds.maxX-padding-chevronWidth/2), cy = p(bounds.midY)
        path.move(to: NSPoint(x: cx-2, y: cy+1)); path.line(to: NSPoint(x: cx, y: cy-1)); path.line(to: NSPoint(x: cx+2, y: cy+1)); color.setStroke(); path.stroke()
    }
}

extension NativeComposerMenuButton: NativePointerHoverClient {}
