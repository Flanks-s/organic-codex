import AppKit
import QuartzCore

@MainActor enum OrbSwitchSurfaceMotion {
    static func blur(_ view: NSView, radius: Double, showing: Bool, duration: Double) {
        guard !Motion.reduce else { return }
        view.wantsLayer = true
        guard let filter = OverlayFilter.make("gaussianBlur",values:["name":"orbContentBlur","inputRadius":showing ? 0 : radius,"enabled":true]) else { return }
        view.layer?.filters = [filter]
        let animation = CAKeyframeAnimation(keyPath:"filters.orbContentBlur.inputRadius")
        animation.values = (0...12).map { i in
            let t = Double(i)/12, k = t*t*(3-2*t)
            return radius * (showing ? 1-k : k)
        }
        animation.duration = duration; view.layer?.add(animation,forKey:"orb.content.blur")
    }
}

/// Glass stays sharp. Only the authored menu content participates in the entrance/exit treatment.
@MainActor final class OrbContextMenu: NSView {
    final class Plate: NSView {
        let glass = NSGlassEffectView(), ink = Ink()
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true
            glass.style = .regular; glass.cornerRadius = 12
            glass.tintColor = NSColor(white: 0.18, alpha: 0.78)
            glass.contentView = ink; addSubview(glass)
            layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.5
            layer?.shadowRadius = 18; layer?.shadowOffset = CGSize(width: 0, height: -14)
            setAccessibilityElement(true); setAccessibilityRole(.menu)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func layout() { super.layout(); glass.frame = bounds; ink.frame = bounds }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    final class Ink: NSView {
        var paint: ((CGRect) -> Void)?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { paint?(bounds) }
    }
    final class Item: NSAccessibilityElement {
        var press: (() -> Bool)?
        override func accessibilityPerformPress() -> Bool { press?() ?? false }
    }
    let state: OrbContextMenuState
    let main = Plate(), child = Plate()
    private weak var scene: AutoScene?
    private weak var target: Conversation?
    private var monitor: Any?, removal: OverlayCancellation?, childRemoval: OverlayCancellation?
    private var previousResponder: NSResponder?
    private var lastPointer = CGPoint.zero, triangleOrigin = CGPoint.zero
    private var openedWithRight = false
    private(set) var anchor = CGPoint.zero
    private var wasSubmenu = false
    private var dismissing = false
    private var mainItems: [Item] = [], childItems: [Item] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(scene: AutoScene, clock: any OverlayClock = OverlaySystemClock()) {
        self.scene = scene; state = OrbContextMenuState(clock: clock)
        super.init(frame: .zero); wantsLayer = true; appearance = NSAppearance(named: .darkAqua)
        addSubview(main); addSubview(child); child.isHidden = true
        setAccessibilityElement(false)
        main.ink.paint = { [weak self] in self?.paintMain($0) }
        child.ink.paint = { [weak self] in self?.paintChild($0) }
        state.changed = { [weak self] in self?.synchronize() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present(_ c: Conversation, at point: CGPoint, in host: NSView, right: Bool) {
        dismiss(animated: false); removal?.cancel(); removal = nil
        wasSubmenu = false; child.isHidden = true
        guard let scene else { return }
        target = c; anchor = point; openedWithRight = right
        frame = host.bounds; autoresizingMask = [.width, .height]; host.addSubview(self)
        main.frame = OrbMenuGeometry.main(at: point, in: bounds); main.layoutSubtreeIfNeeded()
        previousResponder = window?.firstResponder; window?.makeFirstResponder(self)
        state.execute = { [weak self, weak c] action, column in
            guard let self, let c, self.scene?.conversation(c.id) === c, !c.archived,
                  self.scene?.store.conversation(c.id) === c,
                  self.scene?.members.contains(where: { $0 === c }) == true else { return }
            self.scene?.performOrbAction(action, conversation: c, column: column, anchor: self.anchor)
        }
        var columns = scene.columns.map { OrbContextMenuState.Column(id: $0.conversation.id, name: $0.conversation.title, checked: $0.conversation === c) }
        if scene.scheme.draft { columns.insert(.init(id:AutoScene.draftID,name:"New Chat",checked:false),at:min(columns.count,scene.layout.fullColumn)) }
        state.permits = { [weak scene,weak c] action in
            guard action == .remove else { return true }
            guard let scene,let c else { return false };return scene.orbTrash.eligibility(c.id)==nil
        }
        state.open(columns: columns); makeAccessibility(c)
        animate(main, showing: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .rightMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window, self.state.isOpen else { return event }
            if event.type == .keyDown {
                if OrbContextMenuState.navigationKeys.contains(event.keyCode) { self.state.key(event.keyCode); return nil }
                return event.modifierFlags.contains(.command) ? event:nil
            }
            let p = self.convert(event.locationInWindow, from: nil)
            if event.type == .rightMouseDown || event.type == .leftMouseDown && event.modifierFlags.contains(.control) {
                if let scene = self.scene, let id = scene.orbInputTarget(at: p) { scene.openOrbMenu(id, at: p, event: event) }
                else { self.dismiss() }
                return nil
            }
            if event.type == .leftMouseDown {
                self.hover(p)
                if self.main.frame.contains(p) || self.state.submenu && self.child.frame.contains(p) { self.state.choose() }
                else { self.dismiss() }
                return nil
            }
            if event.type == .rightMouseUp { self.hover(p); if self.openedWithRight { self.state.choose(rightRelease: true) }; return nil }
            if event.type == .scrollWheel { return nil }
            self.hover(p); return nil
        }
        lastPointer = point; triangleOrigin = point
    }
    func validateTarget() {
        guard state.isOpen else { return }
        guard let scene, let target, scene.conversation(target.id) === target, !target.archived,
              scene.store.conversation(target.id) === target,
              scene.members.contains(where: { $0 === target }), !scene.modeHandoffActive else { dismiss(); return }
    }
    func dismiss(animated: Bool = true) {
        guard !dismissing else { return }
        dismissing = true; defer { dismissing = false }
        childRemoval?.cancel(); childRemoval = nil
        let mounted = superview != nil
        state.dismiss()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if mounted {
            if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
            previousResponder = nil
            if animated {
                animate(main, showing: false); if !child.isHidden { animate(child, showing: false) }
                removal?.cancel(); removal = state.clock.schedule(after: 0.08) { [weak self] in self?.removeFromSuperview() }
            } else { removal?.cancel(); removal = nil; removeFromSuperview() }
        }
    }
    private func synchronize() {
        guard state.isOpen else {
            if monitor != nil { dismiss() }
            return
        }
        if state.submenu && !wasSubmenu {
            childRemoval?.cancel(); childRemoval = nil
            child.frame = OrbMenuGeometry.child(of: main.frame, count: state.columns.count, in: bounds)
            child.layoutSubtreeIfNeeded(); child.isHidden = false; animate(child, showing: true)
            if let target { makeAccessibility(target) }
        } else if !state.submenu, wasSubmenu {
            animate(child, showing: false)
            childRemoval = state.clock.schedule(after:0.08) { [weak self] in self?.child.isHidden = true; self?.childRemoval = nil }
        } else if !state.submenu, childRemoval == nil { child.isHidden = true }
        wasSubmenu = state.submenu
        main.ink.needsDisplay = true; child.ink.needsDisplay = true
    }
    private func animate(_ plate: Plate, showing: Bool) {
        let duration = showing ? 0.1 : 0.08
        OrbSwitchSurfaceMotion.blur(plate.ink,radius:8,showing:showing,duration:duration)
        let curve = OverlayCurve(0.3333, 0, 0.6667, 1, duration)
        OverlayMotion.animate(plate.layer!, "opacity", from: showing ? 0 : plate.layer!.presentation()?.opacity ?? 1, to: showing ? 1 : 0, curve: curve, enabled: !Motion.reduce)
        OverlayMotion.animate(plate.layer!, "transform.scale", from: showing ? 0.96 : 1, to: showing ? 1 : 0.96, curve: curve, enabled: !Motion.reduce)
        // The anchor is the pointer-facing corner, including menus flipped above/left.
        let point = plate === child
            ? CGPoint(x:child.frame.midX < main.frame.midX ? 1:0,y:min(1,max(0,(main.frame.minY+45-child.frame.minY)/child.frame.height)))
            : CGPoint(x: anchor.x >= plate.frame.midX ? 1 : 0, y: anchor.y >= plate.frame.midY ? 1 : 0)
        let old = plate.frame; plate.layer?.anchorPoint = point; plate.frame = old
    }
    private func rowRect(_ row: Int) -> CGRect {
        let separators = [3, 5, 7].filter { row >= $0 }.count
        return CGRect(x: 5, y: 38 + CGFloat(row * 24 + separators * 9), width: 226, height: 24)
    }
    func hover(_ p: CGPoint) {
        defer { lastPointer = p }
        if state.submenu, child.frame.contains(p) {
            let row = Int((p.y - child.frame.minY - 5) / 24)
            state.hover(row: 0, column: row); return
        }
        let row = OrbMenuAction.allCases.first { rowRect($0.rawValue).offsetBy(dx: main.frame.minX, dy: main.frame.minY).contains(p) }?.rawValue
        let protecting = state.submenu && OrbMenuGeometry.inTriangle(p, origin: triangleOrigin, edge: child.frame, right: child.frame.midX > main.frame.midX)
        if row == 0 { triangleOrigin = p }
        state.hover(row: row, towardSubmenu: protecting && row != 0)
    }
    private func text(_ text: String, _ rect: CGRect, size: CGFloat = 13, alpha: CGFloat = 0.92, weight: NSFont.Weight = .regular, align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = align
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: p])
    }
    private func highlight(_ rect: CGRect) {
        guard let target else { return }
        orbIdentity(of: target).tint.color.withAlphaComponent(0.26).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
    private func paintMain(_ bounds: CGRect) {
        guard let target else { return }
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.addPath(OrbCelestialGlyph(symbol:orbIdentity(of:target).symbol).path(in:CGRect(x:14,y:9,width:14,height:14)).cgPath)
            context.setStrokeColor(orbIdentity(of:target).tint.color.cgColor); context.setLineWidth(1.1); context.strokePath(); context.restoreGState()
        }
        text(target.title, CGRect(x: 35, y: 9, width: 187, height: 18), size: 12, alpha: 0.55, weight: .semibold)
        NSColor.white.withAlphaComponent(0.1).setFill(); CGRect(x:14,y:33,width:208,height:1).fill()
        for action in OrbMenuAction.allCases {
            let r = rowRect(action.rawValue)
            if state.selected == action.rawValue, state.enabled(action), state.highlightVisible { highlight(r) }
            text(action.title, r.insetBy(dx: 9, dy: 3), alpha: state.enabled(action) ? 0.92 : 0.3)
            if action == .swap {
                text("⌥Click",CGRect(x:168,y:r.minY+4,width:42,height:18),size:12,alpha:0.4)
                text("›", CGRect(x: r.maxX - 16, y: r.minY + 2, width: 10, height: 18), alpha: 0.55)
            }
            if [3, 5, 7].contains(action.rawValue) {
                NSColor.white.withAlphaComponent(0.1).setFill(); CGRect(x: 14, y: r.minY - 5, width: 208, height: 1).fill()
            }
        }
    }
    private func paintChild(_ bounds: CGRect) {
        for (i, column) in state.columns.enumerated() {
            let r = CGRect(x: 5, y: 5 + CGFloat(i) * 24, width: 290, height: 24)
            if state.selectedColumn == i, state.highlightVisible { highlight(r) }
            let shortcut = target.map { scene?.dock.items[$0.id]?.role == .orb && scene?.focusTarget == column.id } ?? false
            text("Column \(i + 1)", CGRect(x: 34, y: r.minY + 3, width: 88, height: 18), alpha: column.checked ? 0.3 : 0.92)
            text(column.name, CGRect(x: 122, y: r.minY + 4, width: shortcut ? 116:160, height: 18), size: 12, alpha: column.checked ? 0.3 : 0.4, align: .right)
            if shortcut { text("⌥Click",CGRect(x:246,y:r.minY+4,width:42,height:18),size:12,alpha:0.4) }
            if column.checked { text("✓", CGRect(x: 14, y: r.minY + 3, width: 12, height: 18), alpha: 0.55) }
        }
    }
    private func makeAccessibility(_ c: Conversation) {
        main.setAccessibilityLabel(c.title); child.setAccessibilityLabel(OrbMenuAction.swap.title)
        func item(_ title: String, enabled: Bool, plate: Plate, rect: CGRect, press: @escaping () -> Void) -> Item {
            let e = Item(); e.setAccessibilityRole(.menuItem); e.setAccessibilityLabel(title); e.setAccessibilityEnabled(enabled)
            e.setAccessibilityParent(plate); e.setAccessibilityFrame(NSAccessibility.screenRect(fromView: plate, rect: rect))
            e.press = { [weak self] in guard let self, enabled, self.state.acceptsInput else { return false }; press(); return true }
            return e
        }
        mainItems = OrbMenuAction.allCases.map { action in
            item(action.title, enabled: state.enabled(action), plate: main, rect: rowRect(action.rawValue)) { [weak self] in self?.state.hover(row: action.rawValue); self?.state.choose() }
        }
        childItems = state.columns.enumerated().map { i, column in
            item("Column \(i + 1), \(column.name)", enabled: !column.checked, plate: child, rect: CGRect(x: 5, y: 5 + CGFloat(i) * 24, width: 290, height: 24)) { [weak self] in self?.state.hover(row: 0, column: i); self?.state.choose() }
        }
        main.setAccessibilityChildren(mainItems); child.setAccessibilityChildren(childItems)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { superview != nil && bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) { dismiss() }
    override func keyDown(with event: NSEvent) {
        if OrbContextMenuState.navigationKeys.contains(event.keyCode) { state.key(event.keyCode) }
        else if event.modifierFlags.contains(.command) { super.keyDown(with:event) }
    }
    func dispose() { dismiss(animated: false); target = nil }
}

@MainActor final class OrbActionToast: NSView {
    let glass = NSGlassEffectView(), content = NSView(), label = NSTextField(labelWithString: ""), undoButton = SheetButton(frame: .zero)
    let clock: any OverlayClock
    private var expiry: OverlayCancellation?, removal: OverlayCancellation?
    private var undoAction: (() -> Void)?
    private(set) var expiresAt = 0.0
    override var isFlipped: Bool { true }
    init(clock: any OverlayClock = OverlaySystemClock()) {
        self.clock = clock; super.init(frame: .zero); wantsLayer = true
        glass.style = .regular; glass.cornerRadius = 16; glass.contentView = content; addSubview(glass)
        content.addSubview(label); content.addSubview(undoButton)
        label.font = .systemFont(ofSize: 12,weight: .medium); label.textColor = .white
        undoButton.title = "Undo"; undoButton.drawsPlate = false; undoButton.accent = true
        undoButton.invoke = { [weak self] in self?.undo() }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present(_ text: String, anchor: CGPoint, in host: NSView, undo: (() -> Void)? = nil) {
        dismiss(); removal?.cancel(); removal = nil; label.stringValue = text; undoAction = undo
        let width = min(host.bounds.width - 24,max(80,label.intrinsicContentSize.width + 28 + (undo == nil ? 0 : 46)))
        frame = CGRect(x:max(12,min(host.bounds.width-width-12,anchor.x-width/2)),y:anchor.y>100 ? anchor.y-44 : anchor.y+20,width:width,height:32)
        glass.frame = bounds; content.frame = bounds
        label.frame = CGRect(x:14,y:8,width:width-28-(undo == nil ? 0:46),height:18)
        undoButton.frame = CGRect(x:width-56,y:4,width:46,height:24); undoButton.isHidden = undo == nil
        host.addSubview(self); alphaValue = 1
        OrbSwitchSurfaceMotion.blur(content,radius:6,showing:true,duration:0.1)
        let duration = undo == nil ? 2.4 : 5.0
        expiresAt = clock.now + duration
        expiry = clock.schedule(after:duration) { [weak self] in self?.dismiss(animated:true) }
        OverlayMotion.animate(layer!,"opacity",from:0,to:1,curve:OverlayCurve(0.3333,0,0.6667,1,0.1),enabled:!Motion.reduce)
        OverlayMotion.animate(layer!,"transform.scale",from:0.96,to:1,curve:OverlayCurve(0.3333,0,0.6667,1,0.1),enabled:!Motion.reduce)
    }
    func undo() { let action = undoAction; dismiss(); action?() }
    func dismiss(animated: Bool = false) {
        expiry?.cancel(); expiry = nil; undoAction = nil
        removal?.cancel(); removal = nil
        if animated, superview != nil {
            OrbSwitchSurfaceMotion.blur(content,radius:6,showing:false,duration:0.08)
            OverlayMotion.animate(layer!,"opacity",from:1,to:0,curve:OverlayCurve(0.3333,0,0.6667,1,0.08),enabled:!Motion.reduce)
            removal = clock.schedule(after:0.08) { [weak self] in self?.removeFromSuperview() }
        } else { removeFromSuperview() }
    }
}

@MainActor final class OrbHoverHint {
    private weak var scene: AutoScene?
    private let clock: any OverlayClock
    let view = AutoScene.PassThrough(), glass = NSGlassEffectView(), content = NSView()
    let title = NSTextField(labelWithString:""), detail = NSTextField(labelWithString:"Option-click to swap")
    private var wait: OverlayCancellation?
    private var id: String?, hoveredID: String?, began = 0.0
    private var amount = Spring.rest(0), x = Spring.rest(0), lastX = 0.0
    private(set) var visible = false
    init(scene: AutoScene, clock: any OverlayClock = OverlaySystemClock()) {
        self.scene = scene; self.clock = clock; view.wantsLayer = true
        glass.style = .regular; glass.cornerRadius = 14; glass.contentView = content; view.addSubview(glass)
        for label in [title,detail] { label.font = .systemFont(ofSize:12); label.textColor = .white; content.addSubview(label) }
        detail.textColor = NSColor.white.withAlphaComponent(0.55)
    }
    func pointer(_ p: CGPoint?) {
        guard let scene else { return }
        let candidate = p.flatMap(scene.orbInputTarget).flatMap { id -> String? in
            guard id != scene.current, scene.scheme.mode == .auto, !scene.isHolding, !scene.orbMenu.state.isOpen else { return nil }
            return id
        }
        guard candidate != hoveredID else { return }
        wait?.cancel(); wait = nil
        hide(); hoveredID = candidate
        guard let candidate else { return }
        wait = clock.schedule(after:0.26) { [weak self] in
            guard let self, let scene = self.scene, self.hoveredID == candidate, let c = scene.conversation(candidate), !c.archived,
                  !scene.isHolding, !scene.orbMenu.state.isOpen else { return }
            self.id = candidate; self.title.stringValue = c.title; self.visible = true
            self.retarget(1); self.frame(scene.now())
            OrbSwitchSurfaceMotion.blur(self.content,radius:6,showing:true,duration:0.26)
        }
    }
    private func retarget(_ value: Double) {
        guard let scene else { return }
        let time = scene.now(), current = amount.sample(time-began)
        amount = Spring(from:current.value,to:value,velocity:current.velocity,response:0.26,damping:0.84,epsilon:0.001)
        began = time; scene.runClock(until:time+amount.duration+0.02)
    }
    func hide() { if visible { visible = false; retarget(0) } }
    func cancel() { wait?.cancel(); wait = nil; id = nil; hoveredID = nil; visible = false; amount = .rest(0); view.removeFromSuperview() }
    func frame(_ time: Double) {
        guard let scene else { return }
        let k = max(0,min(1,amount.sample(time-began).value))
        guard k > 0.001, let id, let rect = scene.orbEndpoint(id) else { if !visible { view.removeFromSuperview() }; return }
        let mounting = view.superview == nil
        if mounting { view.frame = scene.overlayPlane.bounds; scene.overlayPlane.addSubview(view) }
        let two = !scene.orbSwapLearned, height: CGFloat = two ? 46:28
        let width = max(title.intrinsicContentSize.width+28,two ? 136:0)
        let targetX = min(scene.sizeForOrb.width-width-12,max(12,rect.midX-width/2))
        if targetX != x.to {
            let current = x.sample(time-lastX)
            x = Spring(from:mounting ? targetX : current.value,to:targetX,velocity:current.velocity,response:0.2,damping:0.9,epsilon:0.01); lastX = time
        }
        let y = scene.dock.items[id]?.role == .orb ? rect.minY-8-height : (scene.nodes[id]?.island.map { scene.overlayPlane.convert($0.geometry.capsule,from:$0).maxY+8 } ?? rect.maxY+8)
        let w = 24+(width-24)*k, h = 24+(height-24)*k
        glass.frame = CGRect(x:x.sample(time-lastX).value+(width-w)/2,y:y+(height-h)/2,width:w,height:h)
        glass.cornerRadius = min(14,h/2); content.frame = glass.bounds
        title.frame = CGRect(x:14,y:6,width:width-28,height:16); detail.frame = CGRect(x:14,y:23,width:width-28,height:16); detail.isHidden = !two
        view.alphaValue = min(1,k/0.4); content.alphaValue = max(0,min(1,(k-0.45)/0.55))
    }
}
