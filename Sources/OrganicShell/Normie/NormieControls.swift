import AppKit

@MainActor enum NormieDrawing {
    static var background: NSColor { NativePalette.canvas }
    static func identity(_ c:Conversation)->OrbIdentity { BodyIdentityAdapter.identity(index:c.identityIndex,symbol:c.identitySymbol,tint:c.identityTint) }
    static func pixel(_ value: CGFloat, scale: CGFloat) -> CGFloat { (value * max(1, scale)).rounded()/max(1, scale) }
    static func rect(_ r: CGRect, scale: CGFloat) -> CGRect {
        let x = pixel(r.minX, scale: scale), y = pixel(r.minY, scale: scale)
        return CGRect(x: x, y: y, width: pixel(r.maxX, scale: scale)-x, height: pixel(r.maxY, scale: scale)-y)
    }
    static func label(_ text: String = "", size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NormieLabel {
        let label = NormieLabel(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = NativePalette.label
        label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        label.setAccessibilityRole(.staticText)
        return label
    }
    static func button(_ text: String, action: @escaping () -> Void) -> NormieButton {
        let b = NormieButton(); b.title = text; b.run = action
        b.font = .systemFont(ofSize: 12); b.setAccessibilityLabel(text); return b
    }
}

@MainActor class NormieView: NSView {
    var verificationScale: CGFloat?
    /// Offscreen injection only; live views use AppKit's inherited safeAreaRect.
    var verificationSafeAreaInsets: NSEdgeInsets?
    var contentSafeRect: CGRect {
        guard let i = verificationSafeAreaInsets else { return safeAreaRect }
        return CGRect(x: bounds.minX+i.left, y: bounds.minY+(isFlipped ? i.top:i.bottom),
                      width: max(0,bounds.width-i.left-i.right), height: max(0,bounds.height-i.top-i.bottom))
    }
    var scale: CGFloat { verificationScale ?? window?.backingScaleFactor ?? 2 }
    var fill: NSColor? { didSet { needsDisplay = true } }
    /// A deterministic material proxy only for a windowless render. NSGlassEffectView's backdrop is server-owned.
    var canopy=false{didSet{needsDisplay=true}}
    var onDisplayOptionsChange:(()->Void)?
    var onAppearanceChange:(()->Void)?
    private var displayObservation:UUID?
    private var appearanceObservation:UUID?
    var offscreenGlassRect: CGRect? { didSet { if offscreenGlassRect != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); appearance = NativeDisplayOptions.appearance
        displayObservation=NativeDisplayOptions.shared.observe{[weak self] in self?.displayOptionsDidChange()}
        appearanceObservation=NativeAppearance.observe{[weak self] in self?.nativeAppearanceDidChange()}
        autoresizesSubviews = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit{if let displayObservation{NativeDisplayOptions.shared.removeObserver(displayObservation)};if let appearanceObservation{NativeAppearance.removeObserver(appearanceObservation)}}
    func nativeAppearanceDidChange(){if fill == NativeAppearance.previous.canvas{fill=NativeAppearance.current.canvas};NativeAppearance.recolor(self);onAppearanceChange?();needsLayout=true;needsDisplay=true}
    func displayOptionsDidChange(){appearance=NativeDisplayOptions.appearance;onDisplayOptionsChange?();func redraw(_ v:NSView){v.needsDisplay=true;v.subviews.forEach(redraw)};redraw(self)}
    override func draw(_ dirtyRect: NSRect) {
        if let fill { fill.setFill(); bounds.fill() }
        if canopy,!NativeDisplayOptions.shared.state.reducesEffects {
            NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:bounds).addClip();let side=max(bounds.width,bounds.height)
            let look=NativeAppearance.current,custom=look.background != nil
            let moss=custom ? look.accentColor.withAlphaComponent(0.15):NSColor(srgbRed:0x57/255,green:0xc2/255,blue:0x7a/255,alpha:0.13)
            let teal=custom ? (look.wash ?? .systemTeal).withAlphaComponent(0.11):NSColor(srgbRed:0x3b/255,green:0xaf/255,blue:0xc2/255,alpha:0.10)
            for (color,point,radius) in [(moss,CGPoint(x:bounds.maxX,y:0),side*0.75),(teal,CGPoint(x:0,y:bounds.maxY),side*0.80)]{NSGradient(starting:color,ending:color.withAlphaComponent(0))?.draw(fromCenter:point,radius:0,toCenter:point,radius:radius,options:[])};NSGraphicsContext.restoreGraphicsState()
        }
        if window == nil, let rect=offscreenGlassRect {
            NativeDisplayOptions.plate(alpha:0.08).setFill()
            let plate=NSBezierPath(roundedRect:rect,xRadius:20,yRadius:20);plate.fill()
            NativeDisplayOptions.plate(alpha:NativeDisplayOptions.shared.state.increaseContrast ? 0.5:0.10).setStroke();plate.lineWidth=0.5;plate.stroke()
        }
    }
    func place(_ v: NSView, _ r: CGRect) {
        let frame = NormieDrawing.rect(r, scale: scale)
        if v.frame != frame { v.frame = frame }
    }
}

/// §7.5: every field/button introduced here overrides draw and has no system bezel.
@MainActor final class NormieLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}
@MainActor final class NormieField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; isBezeled = false; drawsBackground = false
        focusRingType = .none; font = .systemFont(ofSize: 13)
        setAccessibilityElement(true); setAccessibilityRole(.textField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}
@MainActor class NormieButton: NSButton {
    var run: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; target = self; action = #selector(fire)
        contentTintColor=NativePalette.label
        focusRingType = .none
        title = ""; setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
    @objc private func fire() { run?() }
}

@MainActor final class NormiePlanetView: NormieView {
    var identity = OrbIdentity.assigned(0) { didSet { if identity != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        BodyFaceDrawing.draw(identity.resolvedBodyID,in:bounds)
    }
}

struct NormieAccount: Equatable {
    /// The product's account until a Core reports one (SettingsModel: "Louis L.", Plus; initials from the name), in
    /// the prototype and before Live's account arrives (M9; replaces DECISIONS #4's "LO").
    static let prototype = NormieAccount(initials: "LL", name: "Louis L.", plan: "Plus", daybreak: true)
    var initials = "ME"
    var name = "Codex Account"
    var plan = ""
    var daybreak = false
    var fullyFocused = false
}

@MainActor final class NormieAvatarView: NormieView {
    var initials = "ME" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds)
        NSGradient(starting: NSColor(srgbRed: 0x78/255, green: 0xd8/255, blue: 0xa6/255, alpha: 1),
                   ending: NSColor(srgbRed: 0x2b/255, green: 0x8a/255, blue: 0x7a/255, alpha: 1))!.draw(in: path, angle: 90)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (initials as NSString).size(withAttributes: attributes)
        (initials as NSString).draw(at: CGPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
    }
}

/// ProfileCapsule's 16 × 8 sunrise horizon, clipped to its upper 4.5 pt (SidebarView:334).
@MainActor final class NormieAccountHorizon: NormieView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: 4.5)).addClip()
        let glow = NSShadow(); glow.shadowColor = NSColor(srgbRed: 1, green: 0xb3/255, blue: 0x5c/255, alpha: 0.45)
        glow.shadowBlurRadius = 3; glow.shadowOffset = CGSize(width: 0, height: 2); glow.set()
        NSColor(srgbRed: 1, green: 0xc7/255, blue: 0x7a/255, alpha: 1).setStroke()
        let path = NSBezierPath(ovalIn: CGRect(x: 0.8, y: 0.8, width: max(0, bounds.width-1.6), height: 14.4))
        path.lineWidth = 1.6; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor final class NormieAccountView: NormieView {
    let avatar = NormieAvatarView()
    let name = NormieDrawing.label(size: 13, weight: .medium), plan = NormieDrawing.label(size: 10)
    let daybreak = NormieAccountHorizon()
    let button = NormieButton()
    var account = NormieAccount() { didSet { refresh() } }
    var onOpen: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [avatar, name, plan, daybreak, button] { addSubview(v) }
        button.run = { [weak self] in self?.onOpen?() }
        plan.textColor = NativePalette.secondaryLabel; plan.isHidden = true
        name.textColor = NormieSidebarMetrics.primary
        onAppearanceChange = { [weak self] in self?.name.textColor = NormieSidebarMetrics.primary }
        avatar.setAccessibilityHidden(true); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func refresh() {
        avatar.initials = account.initials; name.stringValue = account.name; plan.stringValue = account.plan
        daybreak.isHidden = !account.daybreak
        button.setAccessibilityLabel("\(account.name), \(account.plan). Account and settings")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        place(avatar, CGRect(x: 7, y: 7, width: 26, height: 26))
        place(name, CGRect(x: 39, y: 12, width: max(0, bounds.width-67), height: 20))
        place(plan, CGRect(x: 41, y: 24, width: max(0, bounds.width-72), height: 15))
        place(daybreak, CGRect(x: bounds.width-28, y: 16, width: 16, height: 8)); button.frame = bounds
    }
}

@MainActor final class NormieClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        let scale = window?.backingScaleFactor ?? 2
        r.origin.x = NormieDrawing.pixel(r.origin.x, scale: scale); r.origin.y = NormieDrawing.pixel(r.origin.y, scale: scale)
        return r
    }
}

@MainActor final class NormieEdgeFade: NormieView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color = NormieDrawing.background
        NSGradient(starting: color, ending: color.withAlphaComponent(0))?.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: 9), angle: 90)
        NSGradient(starting: color.withAlphaComponent(0), ending: color)?.draw(in: CGRect(x: 0, y: max(0, bounds.height-18), width: bounds.width, height: 18), angle: 90)
    }
}

/// Live material remains NSGlassEffectView. The root draws the documented offscreen proxy behind this view.
@MainActor final class NormieComposerGlass: NSGlassEffectView {
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}
