import AppKit

/// The window composition root supplies the original column state and its exact restoration.
@MainActor struct FunctionPanelColumnAccess {
    let views: () -> [NSView]
    let isPaused: () -> Bool
    let suspend: () -> (() -> Void)
    let admitsFocus: (NSView) -> Bool
}

struct FunctionPanelWindowEnvironment: Equatable {
    let viewport: CGRect
    let column: CGRect
    let visible: Bool
    let scale: Int
    let reduced: Bool
}

/// Transparent modal layer. Uncovered neighbours remain painted but cannot receive input.
@MainActor final class FunctionPanelWindowHost: FunctionPanelPlane {
    weak var owner: FunctionPanelWindowOwner?
    private var monitor: Any?
    private var shield: NativePointerShield?
    private(set) var stage: FunctionPanelView?
    func install(_ stage: FunctionPanelView) { self.stage = stage }
    var covered: CGRect {
        guard let stage else { return .zero }
        return CGRect(x: stage.frame.minX + stage.geometry.origin.x, y: stage.frame.minY,
                      width: FunctionPanelGeometry.stageWidth, height: FunctionPanelGeometry.panel.maxY)
    }
    func mount(_ stage: FunctionPanelView, scopes: [NSView]) {
        self.stage = stage
        isHidden = false
        addSubview(stage)
        let shield = NativePointerShield(plane: self)
        self.shield = shield
        shield.setScopes(scopes)
        shield.contains = { [weak self] _ in self?.isHidden == false }
        shield.pointer = { [weak self] in
            guard let self, let window = self.window else { return nil }
            return self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        shield.reconcile(force: true)
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                          .leftMouseUp, .rightMouseUp, .otherMouseUp,
                                          .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .scrollWheel, .mouseMoved]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.route(event) == nil
            }
            return consumed ? nil : event
        }
    }
    /// Also used by offscreen checks with real NSEvents; nil means the popup consumed the event.
    func route(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        return route(event, at: convert(event.locationInWindow, from: nil))
    }
    func route(_ event: NSEvent, at local: CGPoint) -> NSEvent? {
        guard !isHidden, let stage else { return event }
        owner?.synchronize()
        guard !isHidden else { return nil }
        if event.type == .keyDown {
            if event.keyCode == 48 || event.keyCode == 53 {
                stage.keyDown(with: event)
                return nil
            }
            let focused = window?.firstResponder as? NSView
            let editor = stage.nameField.currentEditor()
            if focused?.isDescendant(of: stage) != true && window?.firstResponder !== editor {
                stage.focus("orb")
                return nil
            }
            return event
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            if !covered.contains(local) { owner?.dismiss() }
            return covered.contains(local) && owner?.isOpen == true ? event : nil
        }
        let target = hitTest(convert(local, to: superview)) ?? self
        switch event.type {
        case .scrollWheel: target.scrollWheel(with: event)
        case .mouseMoved: target.mouseMoved(with: event)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: target.mouseDragged(with: event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: target.mouseUp(with: event)
        default: break
        }
        return nil
    }
    func unmount() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isHidden = true
        shield?.reconcile(force: true)
        shield?.setScopes([])
        shield = nil
        stage?.removeFromSuperview()
        stage = nil
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        return stage?.hitTest(local) ?? self
    }
    override func mouseDown(with event: NSEvent) {
        if !covered.contains(convert(event.locationInWindow, from: nil)) { owner?.dismiss() }
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func accessibilityChildren() -> [Any]? { isHidden ? [] : stage.map { [$0 as Any] } ?? [] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard !isHidden, let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return bounds.contains(local) ? (stage as NSView?) ?? self : nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { owner?.retire() }
    }
    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
