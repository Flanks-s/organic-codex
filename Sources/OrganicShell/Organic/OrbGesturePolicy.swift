import AppKit

enum OrbGesturePolicy {
    enum Action: Equatable { case ordinary, swap, menu, reserved }
    static func action(_ event: NSEvent) -> Action {
        action(flags: event.modifierFlags, right: event.type == .rightMouseDown)
    }
    static func action(flags: NSEvent.ModifierFlags, right: Bool = false) -> Action {
        if right || flags.contains(.control) { return .menu }
        if flags.contains(.option) { return flags.intersection([.command, .shift]).isEmpty ? .swap : .reserved }
        return .ordinary
    }
}

/// One input owner per scene. The original Dock state machine still owns pickup, drop and its springs.
@MainActor final class OrbInputController {
    private weak var scene: AutoScene?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var notifications: [NSObjectProtocol] = []
    private var target: Conversation?
    private weak var header: HeaderIsland?
    private weak var clickHeader: HeaderIsland?
    private var ordinary: ((CGPoint) -> Void)?
    private var pointerObserver: ((NSEvent) -> Void)?
    private var action = OrbGesturePolicy.Action.ordinary
    private(set) var isPressed = false
    private var pressPoint = CGPoint.zero
    private var pressedAt = 0.0
    private var pendingHoverDismissal=false,suppressClick=false
    func yieldSunHoverPress() { pendingHoverDismissal=true }
    init(scene: AutoScene) { self.scene = scene }
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        notifications.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        cancel()
        notifications.forEach(NotificationCenter.default.removeObserver); notifications = []
        self.window = window
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel(); self?.scene?.orbTrash.suspend(); self?.scene?.orbMenu.dismiss() }
            })
        }
    }

    @discardableResult func begin(_ event: NSEvent, id: String, header: HeaderIsland? = nil,
                                 tidePlanet: Bool = false,
                                 observePointer: ((NSEvent) -> Void)? = nil, ordinary: @escaping (CGPoint) -> Void) -> Bool {
        let hoverDismissal=pendingHoverDismissal;pendingHoverDismissal=false
        guard let scene, scene.tearing == nil, !scene.isDragging, let c = scene.conversation(id), !c.archived else { return false }
        attach(event.window ?? scene.sceneView.window)
        cancel()
        let p = scene.dockView.convert(event.locationInWindow, from: nil)
        let selected = OrbGesturePolicy.action(event)
        scene.orbHint.cancel()
        if selected == .menu { if !hoverDismissal { scene.openOrbMenu(id, at:p,event:event) };return true }
        scene.orbMenu.dismiss()
        observePointer?(event)
        let pickup=scene.orbPose(id)
        let dragHeader=header.flatMap { $0 === scene.peekNode.header ? nil:$0 }
        if let dragHeader {
            guard M104HeaderOrbDragging.install(in: scene).begin(from: dragHeader, at: p) else { return false }
        } else {
            let direct = scene.dock.draggable(at:p) == id
            if !scene.pointerDown(p,member:direct ? nil:id) { return false }
        }
        scene.markConversationOrbPress(p,pickup:pickup)
        scene.drag?.tidePlanetOrigin = tidePlanet
        scene.pressFromPointer = true
        scene.orbPressOrigin = scene.orbFlights.pose(id) ?? (scene.shownPeek == id && scene.peekNode.headerVisible ? scene.orbPose(id):nil)
        target = c; self.header = dragHeader;self.clickHeader=header; self.ordinary = ordinary; action = selected
        pressPoint = p; pressedAt = event.timestamp; isPressed = true;suppressClick=hoverDismissal
        pointerObserver=observePointer
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown, .pressure]) { [weak self] event in
            guard let self, event.window === self.window, self.isPressed else { return event }
            if event.type == .leftMouseDragged { self.dragged(event); return nil }
            if event.type == .leftMouseUp { self.released(event); return nil }
            if event.type == .rightMouseDown { return nil }
            if event.type == .pressure, self.action != .ordinary { return nil }
            if event.type == .keyDown, event.keyCode == 53 { self.cancel(); return nil }
            return event
        }
        return true
    }
    func dragged(_ event: NSEvent) {
        guard isPressed, let scene else { return }
        pointerObserver?(event)
        let p = scene.dockView.convert(event.locationInWindow, from: nil)
        if header != nil { scene.dock.headerOrbDragging?.move(to: p) } else { scene.pointerDragged(p) }
    }
    func released(_ event: NSEvent) {
        guard isPressed, event.timestamp >= pressedAt, let scene else { return }
        pointerObserver?(event)
        let p = scene.dockView.convert(event.locationInWindow, from: nil)
        // Event timestamps close the threshold gap when the hold timer has not run yet.
        if !scene.isDragging, event.timestamp - pressedAt >= 0.250 || hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= 8 {
            scene.pointerDragged(p)
            if !scene.isDragging { scene.beginDrag(at: p) }
        }
        if scene.drag?.conversationOrb == true,scene.isDragging,!OrganicFeatureAvailability.current.conversationOrbTear { scene.pointerDragged(p) }
        let wasDragging = scene.isDragging
        let c = target, selected = action, click = ordinary
        let inside = clickHeader.map { scene.dockView.convert($0.draggableOrbRect, from: $0).contains(p) } ?? true
        if header != nil { _ = scene.dock.headerOrbDragging?.end(at: p, performClick: false) }
        else { _ = scene.pointerUp(p) }
        let cancelled = scene.pressCancelled,hoverDismissal=suppressClick
        finish()
        guard !wasDragging, !cancelled,!hoverDismissal, inside, let c, scene.conversation(c.id) === c, scene.store.conversation(c.id) === c, !c.archived else { return }
        switch selected {
        case .ordinary: click?(p)
        case .swap: scene.swapOrb(c.id)
        case .menu, .reserved: break
        }
    }
    func cancel() {
        if isPressed { scene?.dock.headerOrbDragging?.cancel(); scene?.cancelDrag() }
        finish()
    }
    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        clickHeader?.planetButton.endPointerGesture()
        isPressed = false; target = nil; header = nil;clickHeader=nil; ordinary = nil;pointerObserver=nil;suppressClick=false
        scene?.orbPressOrigin = nil
    }
    func dispose() {
        cancel(); notifications.forEach(NotificationCenter.default.removeObserver); notifications = []; window = nil
    }
}
