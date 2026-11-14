import AppKit
import QuartzCore

@MainActor private final class OrbTrashPassage: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }
}

/// A retained prototype surface, deliberately independent of the shared Dock container.
/// The caller supplies poses and the existing physical carrier. No clock, monitor, window or Core is created here.
@MainActor final class OrbTrashPresentation {
    let view: NSView = OrbTrashPassage()
    let container = NSGlassEffectContainerView()
    private let material = OrbTrashPassage(), ink = OrbTrashPassage()
    let can = NSGlassEffectView(), proxy = NSGlassEffectView()
    let nubs = [NSGlassEffectView(), NSGlassEffectView()]
    let bubble = NSGlassEffectView(), toast = NSGlassEffectView()
    let tailParts = (0..<16).map { _ in NSGlassEffectView() }
    private let halo = CAGradientLayer()
    private let icon = OrbTrashIcon()
    private let glyph = NSTextField(labelWithString: "☿")
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "It stays in the sidebar with the same planet.")
    private let toastTitle = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "The last column stays")
    let undo = NSButton(title: "Undo", target: nil, action: nil)
    let never = NSButton(title: "Don’t show again", target: nil, action: nil)
    let toastUndo = NSButton(title: "Undo", target: nil, action: nil)
    private(set) var lastPose: OrbTrashState.Pose?
    private var lastNotice:String?,lastTitle:String?
    private var lastDraft:OrganicMemberLayout.Draft?
    var presentedNotice:String? { notice.isHidden ? nil:notice.stringValue }
    private(set) var writes = 0
    private(set) var ownerSamples: [Int] = []
    private(set) var handoffDiscontinuity = 0.0
    var onUndo: (() -> Void)?, onNever: (() -> Void)?, onDismiss: (() -> Void)?
    var drawsPrototypeGlyph=true
    let closeButton=NSButton(title:"Close",target:nil,action:nil)

    init(bounds: CGRect) {
        view.frame = bounds; view.wantsLayer = true
        view.layer?.masksToBounds = false
        container.frame = bounds; material.frame = bounds; ink.frame = bounds
        container.spacing = 10; container.contentView = material
        view.addSubview(container); view.addSubview(ink)
        halo.type = .radial; halo.colors = [NSColor.systemRed.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        halo.locations = [0, 1]; halo.startPoint = .init(x:0.5,y:0.5); halo.endPoint = .init(x:1,y:1)
        view.layer?.insertSublayer(halo, at: 0)
        for (i, glass) in allGlass.enumerated() {
            glass.identifier = .init("trash.prototype.\(i)")
            glass.style = .regular; glass.isHidden = true; material.addSubview(glass)
        }
        ink.addSubview(icon)
        for label in [glyph,title,body,toastTitle,notice] {
            label.textColor = .white; label.font = .systemFont(ofSize:12); ink.addSubview(label)
        }
        glyph.alignment = .center; glyph.font = .systemFont(ofSize:22)
        title.font = .systemFont(ofSize:13,weight:.semibold); title.lineBreakMode = .byTruncatingTail
        body.textColor = NSColor.white.withAlphaComponent(0.55)
        notice.textColor = NSColor.white.withAlphaComponent(0.65)
        for button in [undo,never,toastUndo,closeButton] {
            button.bezelStyle = .inline; button.font = .systemFont(ofSize:12,weight:.medium)
            button.target = icon; button.action = #selector(OrbTrashIcon.press(_:)); ink.addSubview(button)
        }
        icon.action = { [weak self] button in
            guard let self else { return }
            if button === self.never { self.onNever?() }
            else if button === self.closeButton { self.onDismiss?() } else { self.onUndo?() }
        }
        ink.isHidden=true;halo.isHidden=true
    }
    func resize(_ bounds:CGRect) {
        for plane in [view,container,material,ink] { plane.frame=bounds }
    }
    var allGlass: [NSGlassEffectView] { [can,proxy] + nubs + [bubble,toast] + tailParts }

    /// One transaction hides the old physical owner and installs the new one at the sampled pose.
    /// Alpha is never used to retire glass. Reapplying an identical pose performs no native writes.
    func apply(_ output: OrbTrashState.Output, source: NSGlassEffectView, title text: String,
               draft: OrganicMemberLayout.Draft = .none, sourcePose:CGRect? = nil, writeSource: ((CGRect?,Bool)->Void)? = nil) {
        let p = output.pose
        guard lastPose != p || lastNotice != output.disabledMessage || lastTitle != text || lastDraft != draft else { return }
        let old = lastPose
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if old?.owner != p.owner, p.owner == .trash, old?.owner == .source {
            let actual = sourcePose ?? source.superview.map { view.convert(source.frame,from:$0) } ?? source.frame
            handoffDiscontinuity = max(handoffDiscontinuity,hypot(actual.midX-p.carrier.midX,actual.midY-p.carrier.midY),
                                       abs(actual.width-p.carrier.width),abs(actual.height-p.carrier.height))
        }
        if let writeSource { writeSource(p.owner == .source && !p.hidden ? p.carrier:nil,p.owner != .source) }
        else {
            // Mutation check changes this line to leave the source visible.
            source.isHidden = p.owner != .source
            if p.owner == .source && !p.hidden { source.frame = source.superview.map { $0.convert(p.carrier,from:view) } ?? p.carrier }
        }
        ink.isHidden=false;halo.isHidden=false
        put(can, p.hidden ? nil : p.can, radius: p.can.width/2)
        can.tintColor = p.redTint > 0 ? NSColor.systemRed.withAlphaComponent(p.redTint) : nil
        put(proxy, p.owner == .trash && p.carrier.width > 0.5 && !p.hidden ? p.carrier : nil, radius:min(p.carrier.width,p.carrier.height)/2)
        for i in nubs.indices { put(nubs[i], p.nubs.indices.contains(i) ? p.nubs[i] : nil, radius:p.nubs.indices.contains(i) ? p.nubs[i].width/2 : 0) }
        put(bubble,p.bubble,radius:OrbTrashParameters.bubbleRadius)
        put(toast,p.toast,radius:16)
        let strips = Self.tailRects(p.tail, count:tailParts.count)
        for i in tailParts.indices { put(tailParts[i],strips.indices.contains(i) ? strips[i] : nil,radius:1) }
        halo.frame = p.can.insetBy(dx:-24,dy:-24)
        halo.opacity = Float(p.hidden ? 0 : p.haloAlpha)
        halo.transform = CATransform3DMakeScale(p.haloScale,p.haloScale,1)
        icon.frame = p.can; icon.angle = p.lidDegrees; icon.inkAlpha = p.iconAlpha; icon.iconScale = p.iconScale
        icon.isHidden = p.hidden; icon.needsDisplay = true
        glyph.frame = p.carrier.insetBy(dx:0,dy:max(0,(p.carrier.height-28)/2))
        glyph.font = .systemFont(ofSize:max(1,22*p.carrier.width/38))
        glyph.alphaValue = p.glyphAlpha; glyph.isHidden = !drawsPrototypeGlyph || p.owner == .none || p.hidden
        if let r = p.bubble {
            title.stringValue = "\(text) left Organic"
            body.stringValue = draft == .none ? "It stays in the sidebar with the same planet." : draft == .empty ? "The empty draft was closed." : "Your draft stays on this device."
            title.frame = .init(x:r.minX+14,y:r.minY+12,width:r.width-28,height:18)
            body.frame = .init(x:r.minX+14,y:r.minY+35,width:r.width-28,height:36)
            undo.frame = .init(x:r.minX+14,y:r.maxY-36,width:48,height:26)
            never.frame = .init(x:r.minX+74,y:r.maxY-36,width:130,height:26)
        }
        closeButton.frame = p.bubble.map { CGRect(x:$0.maxX-58,y:$0.minY+8,width:50,height:22) } ?? .zero
        for v in [title,body,undo,never,closeButton] { v.isHidden = p.bubble == nil; v.alphaValue = p.contentAlpha }
        if let r = p.toast {
            toastTitle.stringValue = "\(text) left Organic"
            toastTitle.frame = .init(x:r.minX+14,y:r.minY+8,width:r.width-80,height:18)
            toastUndo.frame = .init(x:r.maxX-60,y:r.minY+3,width:48,height:26)
        }
        for v in [toastTitle,toastUndo] { v.isHidden = p.toast == nil }
        notice.stringValue=output.disabledMessage ?? ""
        notice.isHidden = output.disabledMessage == nil
        notice.frame = .init(x:p.can.maxX-170,y:p.can.minY-35,width:180,height:22)
        lastPose = p;lastNotice=output.disabledMessage;lastTitle=text;lastDraft=draft
        ownerSamples.append((source.isHidden ? 0:1) + (proxy.isHidden ? 0:1))
    }
    private func put(_ glass: NSGlassEffectView, _ rect: CGRect?, radius: Double) {
        if let rect, rect.width > 0, rect.height > 0 {
            if glass.frame != rect { glass.frame = rect; writes += 1 }
            if glass.cornerRadius != radius { glass.cornerRadius = radius; writes += 1 }
            if glass.isHidden { glass.isHidden = false; writes += 1 }
        } else if !glass.isHidden || glass.frame != .zero {
            glass.isHidden = true; glass.frame = .zero; writes += 1
        }
    }
    static func tailRects(_ triangle: [CGPoint], count: Int) -> [CGRect] {
        guard triangle.count == 3 else { return [] }
        let top = triangle[0].y, tip = triangle[2], h = tip.y-top
        guard h > 0 else { return [] }
        return (0..<count).map { i in
            let t = Double(i)/Double(count), bottom = min(h,h*Double(i+1)/Double(count)+OrbTrashParameters.connectedOverlap)
            let w = max(1,(triangle[1].x-triangle[0].x)*(1-t))
            return .init(x:tip.x-w/2,y:top+h*t,width:w,height:bottom-h*t)
        }
    }
    func retire(source: NSGlassEffectView) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for g in allGlass { g.isHidden = true; g.frame = .zero }
        ink.isHidden = true; halo.isHidden = true
        CATransaction.commit(); lastPose = nil;lastNotice=nil;lastTitle=nil;lastDraft=nil
    }
    var probe: [String:Any] {
        ["independentContainer":true,"spacing":container.spacing,"visibleParts":allGlass.filter{!$0.isHidden}.count,
         "materialWrites":writes,"ownerCounts":ownerSamples,"handoffDiscontinuity":handoffDiscontinuity,
         "glassFilters":allGlass.reduce(0){$0+($1.layer?.filters?.count ?? 0)},
         "parts":allGlass.filter{!$0.isHidden}.map{["id":$0.identifier?.rawValue ?? "","rect":[$0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height]] as [String:Any]}]
    }
}

@MainActor private final class OrbTrashIcon: NSView {
    var angle = 0.0, inkAlpha = 0.88, iconScale = 1.0
    var action: ((NSButton) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    @objc func press(_ sender: NSButton) { action?(sender) }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let base = NSAffineTransform()
        base.translateX(by:bounds.midX-11*iconScale,yBy:bounds.midY-11*iconScale)
        base.scale(by:iconScale); base.concat()
        NSColor.white.withAlphaComponent(inkAlpha).setStroke()
        let body = NSBezierPath()
        body.move(to:.init(x:5.4,y:6.2));body.line(to:.init(x:6.25,y:17.7))
        body.curve(to:.init(x:7.85,y:19.2),controlPoint1:.init(x:6.3,y:18.6),controlPoint2:.init(x:6.9,y:19.2))
        body.line(to:.init(x:14.15,y:19.2));body.curve(to:.init(x:15.75,y:17.7),controlPoint1:.init(x:15,y:19.2),controlPoint2:.init(x:15.7,y:18.6))
        body.line(to:.init(x:16.6,y:6.2))
        for x in [9.2,12.8] { body.move(to:.init(x:x,y:10));body.line(to:.init(x:x,y:15.6)) }
        body.lineWidth=1.5;body.lineCapStyle = .round;body.lineJoinStyle = .round;body.stroke()
        let hinge = NSAffineTransform();hinge.translateX(by:18,yBy:6);hinge.rotate(byDegrees:angle);hinge.translateX(by:-18,yBy:-6);hinge.concat()
        let lid=NSBezierPath();lid.move(to:.init(x:3.6,y:6));lid.line(to:.init(x:18.4,y:6))
        lid.move(to:.init(x:8.4,y:6));lid.line(to:.init(x:8.4,y:4.4))
        lid.curve(to:.init(x:9.6,y:3.2),controlPoint1:.init(x:8.4,y:3.7),controlPoint2:.init(x:8.9,y:3.2))
        lid.line(to:.init(x:12.4,y:3.2));lid.curve(to:.init(x:13.6,y:4.4),controlPoint1:.init(x:13.1,y:3.2),controlPoint2:.init(x:13.6,y:3.7));lid.line(to:.init(x:13.6,y:6))
        lid.lineWidth=1.5;lid.lineCapStyle = .round;lid.lineJoinStyle = .round;lid.stroke()
    }
}
