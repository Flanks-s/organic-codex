import AppKit

@MainActor final class OverlaySendOptions: OverlaySurface {
    enum PressState: Equatable { case idle, holding, opened, cancelled }
    private var viewportSize: CGSize?
    private let backdrop = OverlayBackdrop(), content = OverlayView()
    private let caption = OverlayStyle.label("", size: 11, weight: .semibold)
    private var rows: [FollowUp: OverlaySendRow] = [:]
    private(set) var choice: FollowUp = .steer
    private(set) var pressState: PressState = .idle
    private(set) var contentRect = CGRect.zero
    var defaultChoice: FollowUp = .steer
    var running = true
    var canSend: () -> Bool = { true }
    var onSelect: ((FollowUp) -> Void)?
    var onShortPress: (() -> Void)?
    var onPressStateChange: ((Bool) -> Void)?
    private var hold: OverlayCancellation?
    private weak var pendingHost: NSView?
    private var pendingAnchor = CGRect.zero, pendingPointer = CGPoint.zero
    private var armed: (FollowUp, CGRect)?
    private var pointerTracking: NSTrackingArea?
    override var interactiveRects: [CGRect] { rows.values.map { convert($0.bounds, from: $0) } }
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        super.init(clock: clock)
        for view in [backdrop, content] { view.wantsLayer = true; addSubview(view) }
        content.addSubview(caption); caption.textColor = .secondaryLabelColor; caption.maximumNumberOfLines = 2; caption.cell?.wraps = true
        for option in [FollowUp.queue, .steer] {
            let row = OverlaySendRow(); rows[option] = row; content.addSubview(row)
            row.invoke = { [weak self] in self?.commit(option) }
        }
        setAccessibilityLabel("Send options")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func present(anchor: CGRect, in host: NSView) { choice = defaultChoice; armed = nil; viewportSize = nil; super.present(anchor: anchor, in: host) }
    @discardableResult func beginPress(anchor: CGRect, in host: NSView, pointer: CGPoint) -> Bool {
        guard canSend(), pressState == .idle || pressState == .cancelled else { return false }
        hold?.cancel(); pendingAnchor = anchor; pendingPointer = pointer; pendingHost = host
        pressState = .holding; onPressStateChange?(true)
        hold = clock.schedule(after: OverlayMotion.hold) { [weak self, weak host] in
            guard let self, let host, self.pressState == .holding else { return }
            guard self.canSend() else { self.cancelPress(); return }
            self.present(anchor: self.pendingAnchor, in: host); self.pressState = .opened
            self.pointerMoved(at: self.convert(self.pendingPointer, from: host))
            if self.window != nil { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        }
        return true
    }
    /// Host coordinates, before and after the 350 ms opening deadline.
    func continuePress(at point: CGPoint) {
        pendingPointer = point
        if pressState == .opened, let host = pendingHost { pointerMoved(at: convert(point, from: host)) }
    }
    func endPress(at point: CGPoint) {
        hold?.cancel(); onPressStateChange?(false)
        let state = pressState; pressState = .idle
        guard state != .cancelled, canSend() else { return }
        if state == .holding {
            if pendingAnchor.contains(point) { if let onShortPress { onShortPress() } else { onSelect?(defaultChoice) } }
        } else if state == .opened, let host = pendingHost {
            let p = convert(point, from: host)
            if let (option, rect) = armed, rect.contains(p) { commit(option) }
            else if let option = option(at: p) { commit(option) }
        }
    }
    func cancelPress() { hold?.cancel(); hold = nil; pressState = .cancelled; armed = nil; onPressStateChange?(false) }
    func pointerMoved(at point: CGPoint) {
        guard isShowing, !isDismissing else { return }
        NSCursor.arrow.set()
        // Keep the row armed until the pointer leaves its hit band while the selected lyric glides into focus.
        if let (_, rect) = armed, rect.contains(point) { return }
        guard let option = option(at: point), let rect = rowRect(option)?.insetBy(dx: -20, dy: -5) else { armed = nil; return }
        armed = (option, rect); setChoice(option)
    }
    func option(at point: CGPoint) -> FollowUp? {
        guard point.x > contentRect.minX - 20, point.x < contentRect.maxX + 20,
              point.y > contentRect.minY - 10, point.y < contentRect.minY + 88 else { return nil }
        return point.y < contentRect.minY + 37 ? (choice == .steer ? .queue : .steer) : choice
    }
    func rowRect(_ option: FollowUp) -> CGRect? { rows[option].map { convert($0.bounds, from: $0) } }
    private func setChoice(_ choice: FollowUp) { guard choice != self.choice else { return }; self.choice = choice; update(animated: true) }
    private func commit(_ option: FollowUp) {
        guard isShowing, !isDismissing, canSend() else { return }
        hold?.cancel(); pressState = .idle; onPressStateChange?(false); onSelect?(option); dismiss(reason: .selection)
    }
    override func handleKey(_ key: OverlayKey) -> Bool {
        guard isShowing, !isDismissing else { return false }
        switch key {
        case .up, .down: armed = nil; setChoice(choice == .steer ? .queue : .steer)
        case .enter: commit(choice)
        case .escape: dismiss(reason: .escape)
        default: break
        }
        return true
    }
    override func layout() { super.layout(); if viewportSize != bounds.size { update(animated: false) } }
    private func update(animated: Bool) {
        guard isShowing else { return }; viewportSize = bounds.size
        let x = min(max(anchorRect.maxX + 8 - 300, 12), max(12, bounds.width - 312))
        contentRect = snapped(CGRect(x: x, y: anchorRect.minY - 14 - 116, width: 300, height: 116)); content.frame = contentRect
        for option in [FollowUp.queue, .steer] {
            let row = rows[option]!, old = row.frame.minY
            let oldSize = row.title.font?.pointSize ?? 28
            let current = option == choice
            row.configure(option, current: current)
            row.frame = snapped(CGRect(x: 0, y: current ? 42 : 0, width: 300, height: current ? 40 : 28))
            row.prepareMotion()
            OverlayMotion.animate(row.motionLayer, "transform.translation.y", from: old - row.frame.minY, to: 0, curve: OverlayMotion.glide, enabled: animated && !reduceMotion)
            OverlayMotion.animate(row.motionLayer, "transform.scale", from: oldSize / (current ? 28 : 19), to: 1, curve: OverlayMotion.grow, enabled: animated && !reduceMotion)
            OverlayMotion.animate(row.motionLayer, "opacity", from: current ? 0.34 : 1, to: current ? 1 : 0.34, curve: OverlayMotion.ease(0.35), enabled: animated && !reduceMotion)
            row.accumulate(enabled: animated && !reduceMotion)
        }
        caption.stringValue = !running ? "Nothing is running, so either one sends now." : choice == .steer ? "Your message joins the reply that’s running." : "Your message waits and sends when this reply ends."
        caption.frame = snapped(CGRect(x: 0, y: 86, width: 300, height: 30))
        backdrop.frame = snapped(CGRect(x: contentRect.minX - 150, y: contentRect.midY + 30 - 168, width: 600, height: 336)); backdrop.layoutSubtreeIfNeeded()
    }
    override func animateIn() {
        CATransaction.begin(); CATransaction.setDisableActions(true); content.layer?.opacity = 1; content.layer?.setValue(0, forKeyPath: "transform.translation.y"); CATransaction.commit()
        if usesGaussian {
            rows.values.forEach { $0.resetExposure() }
            contentAppearance(Array(rows.values) + [caption], visible: true)
            backdrop.prepareGaussian(); containerAppearance([backdrop], visible: true)
            return
        }
        for (i, option) in [FollowUp.queue, .steer].enumerated() { OverlayMotion.entrance(rows[option]!, order: 1 - i, enabled: !reduceMotion) }
        OverlayMotion.animate(caption.layer!, "opacity", from: 0, to: 1, curve: OverlayMotion.rise, enabled: !reduceMotion, retarget: false)
        backdrop.springIn(enabled: !reduceMotion)
    }
    override func animateOut() {
        if usesGaussian {
            rows.values.forEach { $0.resetExposure() }
            contentAppearance(Array(rows.values) + [caption], visible: false)
            containerAppearance([backdrop], visible: false)
            return
        }
        OverlayMotion.animate(content.layer!, "opacity", from: 1, to: 0, curve: OverlayCurve(0.42, 0, 1, 1, 0.18), enabled: !reduceMotion)
        OverlayMotion.animate(content.layer!, "transform.translation.y", from: 0, to: 10, curve: OverlayCurve(0.42, 0, 1, 1, 0.18), enabled: !reduceMotion)
        OverlayMotion.animate(backdrop.layer!, "opacity", from: 1, to: 0, curve: OverlayMotion.blurOut, enabled: !reduceMotion)
        backdrop.transition(from: 1, to: 0.55, curve: OverlayMotion.blurOut, enabled: !reduceMotion)
    }
    override func willDismiss(reason: OverlayDismissReason) { cancelPress() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, bounds.contains(convert(point, from: superview)) else { return nil }
        if isDismissing { return self }
        let p = convert(point, from: superview)
        for row in rows.values where convert(row.bounds, from: row).contains(p) { return row }
        return self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if pointerTracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            pointerTracking = area; addTrackingArea(area)
        }
    }
    override func mouseMoved(with event: NSEvent) { pointerMoved(at: convert(event.locationInWindow, from: nil)) }
}

@MainActor final class OverlaySendRow: OverlayAccumulatingView {
    let title = OverlayStyle.label("", size: 28, weight: .bold), detail = OverlayStyle.label("", size: 15, weight: .semibold)
    var invoke: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; ink.addSubview(title); ink.addSubview(detail); setAccessibilityElement(true); setAccessibilityRole(.button) }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ option: FollowUp, current: Bool) {
        title.stringValue = option == .steer ? "Steer" : "Queue"; title.font = .systemFont(ofSize: current ? 28 : 19, weight: .bold)
        detail.stringValue = option == .steer ? "joins this reply" : "after this reply"; detail.font = .systemFont(ofSize: current ? 15 : 12, weight: .semibold); detail.textColor = .labelColor.withAlphaComponent(0.6)
        let width = ceil(title.attributedStringValue.size().width) + 4, height: CGFloat = current ? 40 : 28
        title.frame = CGRect(x: 0, y: 0, width: width, height: height)
        detail.frame = CGRect(x: width + 8, y: current ? 9 : 4, width: 190, height: current ? 28 : 22)
        setAccessibilityLabel(title.stringValue + ", " + detail.stringValue); setAccessibilityValue(current ? "Selected" : "")
    }
    override func mouseDown(with event: NSEvent) { invoke?() }
    override func accessibilityPerformPress() -> Bool { invoke?(); return true }
}
