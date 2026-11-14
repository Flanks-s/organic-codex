import AppKit
import SwiftUI

@MainActor enum SheetStyle {
    /// Capture-only foreground matte. Always restored in the same main-thread transaction.
    static var capturesPlates=false
    static func spring(response: Double, damping: Double) -> CASpringAnimation {
        let a = CASpringAnimation(), omega = 2 * Double.pi / response
        a.mass = 1; a.stiffness = omega * omega; a.damping = 2 * damping * omega; a.duration = a.settlingDuration; return a
    }
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NativeLabel {
        let v = NativeLabel(labelWithString: text); v.font = .systemFont(ofSize: size, weight: weight)
        v.textColor = secondary ? .secondaryLabelColor : .labelColor; v.lineBreakMode = .byTruncatingTail
        return v
    }
    static func snap(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let s = max(1, scale)
        return CGRect(x: (rect.minX * s).rounded() / s, y: (rect.minY * s).rounded() / s,
                      width: ceil(rect.width * s) / s, height: ceil(rect.height * s) / s)
    }
    static func text(_ text: String, in rect: CGRect, size: CGFloat, color: NSColor = .labelColor, weight: NSFont.Weight = .regular, align: NSTextAlignment = .left) {
        guard !capturesPlates else {return}
        let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p])
    }
    static func glyph(_ identity: OrbIdentity, in rect: CGRect, weight: CGFloat = 1.8) {
        guard !capturesPlates else {return}
        BodyFaceDrawing.draw(identity.resolvedBodyID,in:rect)
    }
}

/// No NSButtonCell, native bezel or asynchronous material/tint path. Text and plate share one draw/cache path.
@MainActor class SheetButton: NSControl {
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var invoke: (() -> Void)?
    var onVisualChange:(()->Void)?
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "Selected" : "") } }
    var accent = false { didSet { needsDisplay = true } }
    var destructive = false { didSet { needsDisplay = true } }
    var drawsPlate = true { didSet { needsDisplay = true } }
    var drawContent: ((CGRect) -> Void)?
    private(set) var hovered = false
    private var tracking: NSTrackingArea?
    private var armed = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; focusRingType = .none; font = .systemFont(ofSize: 12, weight: .medium)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    convenience init(_ title: String, action: @escaping () -> Void) { self.init(frame: .zero); self.title = title; invoke = action }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); tracking = t; addTrackingArea(t)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true;onVisualChange?() }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true;onVisualChange?() }
    override func draw(_ dirtyRect: NSRect) {
        if drawsPlate {
            let color: NSColor = selected || accent ? .controlAccentColor : .white
            color.withAlphaComponent(isEnabled ? (armed ? 0.28 : selected || accent ? 0.18 : hovered ? 0.11 : 0.07) : 0.025).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        if let drawContent { drawContent(bounds) }
        else {
            let color: NSColor = !isEnabled ? .tertiaryLabelColor : destructive ? .systemRed : .labelColor
            let h = (font ?? .systemFont(ofSize: 12)).boundingRectForFont.height
            SheetStyle.text(title, in: CGRect(x: 4, y: ((bounds.height - h) / 2).rounded(), width: bounds.width - 8, height: h + 3), size: font?.pointSize ?? 12, color: color, weight: .medium, align: .center)
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.8).setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7); p.lineWidth = 1; p.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { armed = isEnabled; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { armed = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseUp(with event: NSEvent) { let fire = armed && bounds.contains(convert(event.locationInWindow, from: nil)); armed = false; needsDisplay = true; if fire { performClick(nil) } }
    override func performClick(_ sender: Any?) { if isEnabled && !isHiddenOrHasHiddenAncestor { invoke?() } }
    override func keyDown(with event: NSEvent) { if event.keyCode == 49 { performClick(nil) } else { super.keyDown(with: event) } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled && !isHiddenOrHasHiddenAncestor else { return false }; performClick(nil); return true }
}

@MainActor final class SheetField: NativeLabel {
    override init(frame: NSRect) {
        super.init(frame: frame); isEditable = true; isSelectable = true; isBezeled = false; isBordered = false
        drawsBackground = false; focusRingType = .none; font = .systemFont(ofSize: 13); textColor = .labelColor
        usesSingleLineMode = true; lineBreakMode = .byClipping
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}
@MainActor final class SheetSecretField: NativeSecureField {
    override init(frame: NSRect) {
        super.init(frame: frame); isEditable = true; isSelectable = true; isBezeled = false; isBordered = false
        drawsBackground = false; focusRingType = .none; font = .systemFont(ofSize: 13); textColor = .labelColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}
@MainActor final class SheetFieldPlate: OverlayView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.065).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        NSColor.white.withAlphaComponent(0.1).setStroke(); let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7); p.lineWidth = 1; p.stroke()
    }
}

@MainActor final class SheetCard: OverlayView {
    private(set) var content = M10FInkPlane(frame:.zero,accumulating:false)
    private let glass = NSGlassEffectView()
    var radius: CGFloat = 24 { didSet { needsLayout = true; needsDisplay = true } }
    var tintColor: NSColor? { get { glass.tintColor } set { glass.tintColor = newValue } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        glass.style = .regular
        addSubview(glass); addSubview(content); content.wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.25; layer?.shadowRadius = 18; layer?.shadowOffset = CGSize(width: 0, height: 8)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Before installing descendants. Customize contains its own glass preview and deliberately keeps plain backing.
    func enableInkAccumulation() {
        guard !content.accumulates else { return }
        precondition(content.subviews.isEmpty,"Choose ink backing before mounting content")
        let old=content;content=M10FInkPlane(frame:old.frame);old.removeFromSuperview();addSubview(content)
    }
    private(set) var motionGlassRect: CGRect?
    private var motionRadiusScale:CGFloat=1
    func placeMotionGlass(_ rect: CGRect?,scale:CGFloat=1) {
        motionGlassRect=rect
        motionRadiusScale=scale
        glass.frame=rect ?? bounds
        glass.cornerRadius=min(radius*scale,min(glass.frame.width,glass.frame.height)/2)
    }
    override func layout() { super.layout(); placeMotionGlass(motionGlassRect,scale:motionRadiusScale); content.frame = bounds }
    override func draw(_ dirtyRect: NSRect) {
        if window == nil { NSColor.textBackgroundColor.withAlphaComponent(0.96).setFill(); let r=motionGlassRect ?? bounds;let radius=min(radius*motionRadiusScale,min(r.width,r.height)/2);NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() }
    }
}

@MainActor final class SheetClipView: NSClipView {
    private var grid: CGFloat { max(1, window?.backingScaleFactor ?? 1) }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        r.origin = CGPoint(x: (r.minX * grid).rounded() / grid, y: (r.minY * grid).rounded() / grid); return r
    }
    override func setBoundsOrigin(_ newOrigin: NSPoint) { super.setBoundsOrigin(CGPoint(x: (newOrigin.x * grid).rounded() / grid, y: (newOrigin.y * grid).rounded() / grid)) }
    override func scroll(to newOrigin: NSPoint) { super.scroll(to: CGPoint(x: (newOrigin.x * grid).rounded() / grid, y: (newOrigin.y * grid).rounded() / grid)) }
}
@MainActor final class SheetScrollView: NSScrollView {
    override init(frame: NSRect) { super.init(frame: frame); contentView = SheetClipView(frame: .zero); contentView.drawsBackground = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); contentView.scroll(to: contentView.bounds.origin) }
}

@MainActor final class SheetIdentityGlyphView: OverlayView {
    var identity = OrbIdentity.assigned(0) { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { SheetStyle.glyph(identity, in: bounds, weight: max(1, bounds.width / 10)) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor final class SheetSatellitePortrait: OverlayView {
    var face = "•ᴗ•" { didSet { needsDisplay = true } }
    var done = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (done ? NSColor.systemGray : .controlAccentColor).withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn: bounds).fill()
        SheetStyle.text(face, in: CGRect(x: 0, y: (bounds.height / 2 - 8).rounded(), width: bounds.width, height: 18), size: 12, color: .white, weight: .semibold, align: .center)
    }
}
@MainActor final class SheetIdentityPreview: OverlayView {
    private let glass = NSGlassEffectView()
    private let ink = SheetIdentityPreviewInk(frame: .zero)
    var identity: OrbIdentity { get { ink.identity } set { ink.identity = newValue } }
    var level: Double { get { ink.level } set { ink.level = newValue } }
    override init(frame: NSRect) {
        super.init(frame: frame); glass.style = .regular; glass.contentView = ink; addSubview(glass); setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); glass.frame = bounds; glass.cornerRadius = bounds.width / 2; ink.frame = bounds }
}
@MainActor private final class SheetIdentityPreviewInk: OverlayView {
    private let body=BodyPresentationLeaf()
    private var windowObservations: [NSObjectProtocol]=[]
    var identity = OrbIdentity.assigned(0) { didSet { needsDisplay = true; updateBody() } }
    var level = 0.3 { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame:frame); wantsLayer=true; layer?.addSublayer(body.layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); updateBody() }
    override func viewDidHide() { super.viewDidHide(); updateBody() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateBody() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in windowObservations { NotificationCenter.default.removeObserver(token) }; windowObservations=[]
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification] {
                windowObservations.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.updateBody() } })
            }
        }
        updateBody()
    }
    private func updateBody() {
        guard bounds.width>0 else { return }
        let visible = !isHiddenOrHasHiddenAncestor && window?.isVisible == true && window?.isMiniaturized != true && window?.occlusionState.contains(.visible) == true
        body.configure(bodyID:identity.resolvedBodyID,outer:bounds.width,drawingSize:bounds.width,scale:window?.backingScaleFactor ?? 2,unknown:false,visible:visible,keyWindow:window?.isKeyWindow ?? false)
        body.setGeometry(view:self,center:CGPoint(x:bounds.midX,y:bounds.midY))
    }
    isolated deinit { for token in windowObservations { NotificationCenter.default.removeObserver(token) }; body.dispose() }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).addClip()
        NSColor.white.withAlphaComponent(0.065).setFill(); bounds.fill()
        identity.bodyTintColor.withAlphaComponent(0.32).setFill()
        let h = bounds.height * CGFloat(min(1, max(0, level.isFinite ? level : 0)))
        CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.2).setStroke(); let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
    }
}
