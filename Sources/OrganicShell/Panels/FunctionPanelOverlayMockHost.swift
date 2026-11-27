import AppKit

/// #213 review host only. No Scene, Dock or application entry constructs this view.
@MainActor final class FunctionPanelOverlayMockHost: FunctionPanelPlane {
    let stage: FunctionPanelView
    let owner: FunctionPanelBodyOwner
    let shield: FunctionPanelOverlayShield
    let column: CGRect
    let scale: Int
    private(set) var neighbours: [FunctionPanelNeighbourProbe] = []
    private var savedResponder: NSResponder?
    private(set) var overlayOpen = false
    private var captured: NSView?
    init(split: Bool, scale: Int) {
        self.scale = scale
        column = CGRect(x: split ? 480 : 0, y: 32, width: split ? 480 : 360, height: 820)
        let viewport = CGRect(x: 0, y: 0, width: 960, height: 820)
        stage = FunctionPanelView(input: FunctionPanelFixtures.input(), viewport: viewport, column: column,
            reduced: true, automatic: false)
        owner = FunctionPanelBodyOwner(resources: BodyResources())
        shield = FunctionPanelOverlayShield(frame: CGRect(x: 0, y: 0, width: 960, height: 852))
        super.init(frame: shield.frame)
        appearance = NSAppearance(named: .darkAqua)
        let columns = split ? [CGRect(x: 0, y: 0, width: 480, height: 852)] :
            [CGRect(x: 360, y: 0, width: 300, height: 852), CGRect(x: 660, y: 0, width: 300, height: 852)]
        for (index, rect) in columns.enumerated() {
            for row in 0..<6 {
                let cell = FunctionPanelNeighbourProbe(frame: CGRect(x: rect.minX + 8, y: 80 + CGFloat(row) * 96,
                        width: rect.width - 16, height: 60))
                cell.label = "Column \(index + 1), item \(row + 1)"; neighbours.append(cell); addSubview(cell)
            }
        }
        for (index, rect) in columns.enumerated() {
            let cell = FunctionPanelNeighbourProbe(frame: CGRect(x: rect.minX + (split ? 402 : 10), y: 690, width: 60,
                    height: 28))
            cell.label = "Column \(index + 1) covered action"; neighbours.append(cell); addSubview(cell)
        }
        let lower = FunctionPanelNeighbourProbe(frame: CGRect(x: split ? 402 : 378, y: 780, width: 60, height: 28))
        lower.label = "Neighbour below stage"; neighbours.append(lower); addSubview(lower)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        shield.setAccessibilityElement(false)
        stage.wantsLayer = true; stage.layer?.masksToBounds = true
        stage.frame.origin.y = 32
        shield.stage = stage; shield.addSubview(stage); addSubview(shield)
        owner.receive = { [weak stage] in stage?.updateBodySnapshot($0) }
        stage.onAction = { [weak self] action in if action == .closed { self?.dismiss() } }
        stage.onPresentation = { [weak self] _ in
            guard let self else { return }
            if self.overlayOpen && !self.stage.state.isOpen { self.dismiss() }
        }
        shield.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var covered: CGRect { CGRect(x: stage.geometry.origin.x, y: 32, width: 598,
            height: FunctionPanelGeometry.panel.maxY) }
    func present() {
        guard !overlayOpen else { return }
        savedResponder = window?.firstResponder; overlayOpen = true
        shield.region = covered; shield.isHidden = false
        for cell in neighbours { cell.expose(outside: covered) }
        stage.open(at: 0); stage.focus("orb")
        owner.present(FunctionPanelTextureMockHost.phase(scale: scale), candidates: [], currentEntry: true)
    }
    func dismiss() {
        guard overlayOpen else { return }
        overlayOpen = false; captured = nil; shield.isHidden = true
        stage.retire(); owner.close()
        for cell in neighbours { cell.expose(outside: nil) }
        if let savedResponder { window?.makeFirstResponder(savedResponder) }
        savedResponder = nil
    }
    /// Dispatch real NSEvents via AppKit hit testing; the protected stage takes over an entering drag.
    /// The check never orders its backing NSWindow onto a desktop.
    @discardableResult func dispatch(_ event: NSEvent, at location: NSPoint? = nil) -> NSView? {
        let point = location ?? convert(event.locationInWindow, from: nil)
        let hit = hit(at: point)
        let dragging = event.type == .leftMouseDragged || event.type == .leftMouseUp
        if let held = captured, overlayOpen && covered.contains(point) && dragging,
           !(held === shield || held.isDescendant(of: shield)) { captured = hit }
        let target = dragging ? captured ?? hit : hit
        switch event.type {
        case .leftMouseDown: captured = target; target?.mouseDown(with: event)
        case .leftMouseUp: target?.mouseUp(with: event); captured = nil
        case .leftMouseDragged: target?.mouseDragged(with: event)
        case .mouseMoved: target?.mouseMoved(with: event)
        case .scrollWheel: target?.scrollWheel(with: event)
        default: break
        }
        return target
    }
    /// NSView.hitTest takes its superview's coordinates, including the window content view's Y flip.
    func hit(at point: NSPoint) -> NSView? { hitTest(convert(point, to: superview)) }
    var neighbourTabStops: [FunctionPanelNeighbourProbe] { neighbours.filter { $0.acceptsFirstResponder } }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        if overlayOpen && covered.contains(local) { return stage }
        return neighbours.first { !$0.isHidden && $0.frame.contains(local) } ?? self
    }
    override func accessibilityChildren() -> [Any]? {
        (overlayOpen ? [stage] : []) + neighbours.filter { !$0.isHidden }.map { $0 as NSView }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.105, green: 0.11, blue: 0.105, alpha: 1).setFill(); bounds.fill()
        for (i, colour) in [UInt32(0xe15a55), 0xe4b34b, 0x62bc5b].enumerated() {
            FunctionPanelPaint.colour(colour).setFill()
            NSBezierPath(ovalIn: CGRect(x: CGFloat(16 + i * 19), y: 18, width: 11, height: 11)).fill()
        }
        NSColor.white.withAlphaComponent(0.15).setFill()
        CGRect(x: column.minX == 0 ? column.maxX : column.minX, y: 32, width: 1, height: 820).fill()
    }
}

@MainActor final class FunctionPanelOverlayShield: FunctionPanelPlane {
    weak var stage: FunctionPanelView?
    var region = CGRect.zero
    private(set) var received: [NSEvent.EventType] = []
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, region.contains(convert(point, from: superview)) else { return nil }
        return stage?.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) { received.append(event.type) }
    override func mouseUp(with event: NSEvent) { received.append(event.type) }
    override func mouseDragged(with event: NSEvent) { received.append(event.type) }
    override func mouseMoved(with event: NSEvent) { received.append(event.type) }
    override func scrollWheel(with event: NSEvent) { received.append(event.type) }
}

/// Retains original identity/focus while exposing only the uncovered rectangle to hit testing and AX.
@MainActor final class FunctionPanelNeighbourProbe: FunctionPanelPlane {
    let originalFrame: CGRect
    var label = "" { didSet { setAccessibilityLabel(label) } }
    private(set) var received: [NSEvent.EventType] = []
    override init(frame: CGRect) {
        originalFrame = frame; super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func expose(outside cover: CGRect?) {
        var exposed = originalFrame
        if let cover, originalFrame.intersects(cover) {
            if cover.minX <= originalFrame.minX {
                exposed.origin.x = min(originalFrame.maxX, cover.maxX)
                exposed.size.width = originalFrame.maxX - exposed.minX
            } else { exposed.size.width = max(0, cover.minX - originalFrame.minX) }
        }
        frame = exposed; isHidden = exposed.width == 0
        setAccessibilityHidden(isHidden); setAccessibilityElement(!isHidden)
    }
    override func accessibilityFrame() -> NSRect {
        guard !isHiddenOrHasHiddenAncestor, let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
    override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && bounds.width > 0 }
    override func becomeFirstResponder() -> Bool { acceptsFirstResponder }
    override func mouseDown(with event: NSEvent) { received.append(event.type); window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) { received.append(event.type) }
    override func mouseDragged(with event: NSEvent) { received.append(event.type) }
    override func mouseMoved(with event: NSEvent) { received.append(event.type) }
    override func scrollWheel(with event: NSEvent) { received.append(event.type) }
    override func draw(_ dirtyRect: NSRect) {
        // Keep the neighbouring content in its original position; only the exposed fragment is drawn.
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let original = CGRect(x: originalFrame.minX - frame.minX, y: 0, width: originalFrame.width,
            height: originalFrame.height)
        FunctionPanelPaint.plate(original, radius: 12, fill: NSColor(white: 0.2, alpha: 1))
        FunctionPanelPaint.text(label, original.insetBy(dx: 12, dy: 20), size: 12)
    }
}
