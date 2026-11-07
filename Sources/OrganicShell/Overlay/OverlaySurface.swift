import AppKit

enum OverlayKey: Sendable {
    case up, down, left, right, enter, escape
    static func from(code: UInt16, modifiers: NSEvent.ModifierFlags) -> OverlayKey? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch code { case 126: return .up; case 125: return .down; case 123: return .left; case 124: return .right; case 36, 76: return .enter; case 53: return .escape; default: return nil }
    }
}
enum OverlayDismissReason: Sendable { case programmatic, outside, escape, enter, selection, windowResigned }

@MainActor class OverlayView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}
@MainActor final class OverlayButton: NativeButton {
    var invoke: (() -> Void)?
    var plate = false { didSet { needsDisplay = true } }
    var fillColors: [NSColor] = [] { didSet { needsDisplay = true } }
    var symbolGradient: [NSColor] = [] { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); target = self; action = #selector(pressed)
        font = .systemFont(ofSize: 12, weight: .semibold); focusRingType = .none
        wantsLayer = true
    }
    convenience init(_ title: String, action: @escaping () -> Void) { self.init(frame: .zero); self.title = title; invoke = action }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if !symbolGradient.isEmpty {
            OverlayStyle.symbolGradient(symbolGradient, bounds: bounds, scale: max(1, window?.backingScaleFactor ?? abs(NSGraphicsContext.current?.cgContext.ctm.a ?? 1))) { super.draw(dirtyRect) }
            return
        }
        if !fillColors.isEmpty {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).addClip()
            OverlayStyle.linear(fillColors, in: bounds); NSGraphicsContext.restoreGraphicsState()
        } else if plate { NSColor.white.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
        super.draw(dirtyRect)
    }
    @objc private func pressed() { if isEnabled && !isHiddenOrHasHiddenAncestor { invoke?() } }
}

/// Mount this as the last subview of the full modal region, above the Dock too. No window or focus is created.
@MainActor class OverlaySurface: OverlayView {
    let clock: any OverlayClock
    private(set) var isShowing = false
    private(set) var isDismissing = false
    private(set) var anchorRect = CGRect.zero
    var reduceMotion = false
    /// Driver B uses this Engine scene clock. Host may inject its window's existing clock before presentation.
    var sceneClock = SceneClock()
    /// Offline scenes inject a shared virtual CA timestamp; live uses the Engine media timestamp.
    var sceneTime: (() -> Double)?
    private(set) var appearanceTime: Double = 0
    let appearanceEffects = OverlayAppearanceBank()
    var usesGaussian: Bool { OverlayZoom.gaussian(reduceMotion: reduceMotion) }
    /// Inject only for deterministic offscreen checks; real windows resolve their own DisplayProfile.
    var exposureProfile: DisplayProfile?
    var onDismiss: ((OverlayDismissReason) -> Void)?
    var grid: CGFloat { max(1, window?.backingScaleFactor ?? 1) }
    var interactiveRects: [CGRect] { [] }
    private var keyMonitor: Any?
    private var resignation: NSObjectProtocol?
    private var removal: OverlayCancellation?
    private var generation = 0
    private var tracking: NSTrackingArea?
    init(clock: any OverlayClock = OverlaySystemClock()) {
        self.clock = clock; super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = false
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignation { NotificationCenter.default.removeObserver(resignation) }
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            func retire(_ view: NSView) {
                (view as? OverlayBackdrop)?.stopExposure()
                (view as? OverlaySpeedSelector)?.retireMotion()
                (view as? OverlayLens)?.retireMotion()
                (view as? OverlayAccumulatingView)?.resetExposure()
                view.subviews.forEach(retire)
            }
            retire(self); appearanceEffects.retire()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }
    func present(anchor: CGRect, in host: NSView) {
        // Mount, paint and the first Engine Gaussian pose must reach the server in ONE commit.
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        generation += 1; removal?.cancel(); removal = nil
        removeMonitors()
        if superview !== host { removeFromSuperview(); host.addSubview(self, positioned: .above, relativeTo: nil) }
        frame = host.bounds; autoresizingMask = [.width, .height]
        anchorRect = snapped(convert(anchor, from: host))
        isShowing = true; isDismissing = false; isHidden = false
        layer?.removeAllAnimations(); layer?.opacity = 1
        needsLayout = true; layoutSubtreeIfNeeded()
        if reduceMotion { removeViewAnimations(self) }
        OverlayMotion.register(self)
        appearanceTime = sceneTime?() ?? sceneClock.mediaTime()
        installMonitors(); animateIn()
        window?.invalidateCursorRects(for: self); NSCursor.arrow.set()
    }
    func dismiss() { dismiss(reason: .programmatic) }
    func dismiss(reason: OverlayDismissReason) {
        guard isShowing, !isDismissing else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        appearanceTime = sceneTime?() ?? sceneClock.mediaTime()
        isDismissing = true; willDismiss(reason: reason); animateOut()
        onDismiss?(reason)
        let epoch = generation
        removal = clock.schedule(after: reduceMotion ? 0 : 0.23) { [weak self] in
            guard let self, self.generation == epoch, self.isDismissing else { return }
            self.isShowing = false; self.isDismissing = false; self.removeMonitors(); self.removeFromSuperview()
        }
    }
    /// Does not redispatch the event. Return true means the underlying scene must not handle it.
    @discardableResult func outsideClick(at point: CGPoint) -> Bool {
        guard isShowing, !interactiveRects.contains(where: { $0.contains(point) }) else { return false }
        dismiss(reason: .outside); return true
    }
    func handleKey(_ key: OverlayKey) -> Bool { false }
    func contentAppearance(_ views: [NSView], visible: Bool) {
        appearanceEffects.set(views, visible: visible, scene: sceneClock, at: appearanceTime, clock: clock, animated: !reduceMotion && OverlayExposure.enabled)
    }
    func containerAppearance(_ views: [NSView], visible: Bool) {
        appearanceEffects.fade(views, visible: visible, at: appearanceTime, animated: !reduceMotion && OverlayExposure.enabled)
    }
    func animateIn() {}
    func animateOut() {}
    func willDismiss(reason: OverlayDismissReason) {}
    func snapped(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX * grid).rounded() / grid, y: (rect.minY * grid).rounded() / grid,
               width: ceil(rect.width * grid) / grid, height: ceil(rect.height * grid) / grid)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        if isDismissing { return self }
        return super.hitTest(point) ?? self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { _ = outsideClick(at: convert(event.locationInWindow, from: nil)) }
    override func rightMouseDown(with event: NSEvent) { _ = outsideClick(at: convert(event.locationInWindow, from: nil)) }
    override func otherMouseDown(with event: NSEvent) { _ = outsideClick(at: convert(event.locationInWindow, from: nil)) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
            tracking = area; addTrackingArea(area)
        }
    }
    func snapshot(scale: CGFloat) -> CGImage { layoutSubtreeIfNeeded(); return NativeViewBitmap.capture(self, scale: scale) }
    private func installMonitors() {
        guard let window else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak window] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let window, self.isShowing, event.window === window else { return false }
                if event.type != .keyDown {
                    if self.isDismissing { return true }
                    return self.outsideClick(at: self.convert(event.locationInWindow, from: nil))
                }
                let key = OverlayKey.from(code: event.keyCode, modifiers: event.modifierFlags)
                if let key, self.isDismissing || self.handleKey(key) { return true }
                return false
            }
            return consumed ? nil : event
        }
        resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(reason: .windowResigned) }
        }
    }
    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let resignation { NotificationCenter.default.removeObserver(resignation); self.resignation = nil }
    }
    private func removeAnimations(_ layer: CALayer) { layer.removeAllAnimations(); layer.sublayers?.forEach(removeAnimations) }
    private func removeViewAnimations(_ view: NSView) { if let layer = view.layer { removeAnimations(layer) }; view.subviews.forEach(removeViewAnimations) }
}
