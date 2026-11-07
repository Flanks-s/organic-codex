import AppKit

enum SheetDismissReason: Equatable, Sendable {
    case programmatic, outside, escape, selection, confirmed, cancelled, replaced, windowResigned, anchorInvalidated
}

/// One modal M4 surface per host. A replacement retires its predecessor synchronously, including event monitors.
@MainActor class SheetSurface: OverlayView {
    private final class Slot { weak var host: NSView?; weak var surface: SheetSurface?; init(_ host: NSView, _ surface: SheetSurface) { self.host = host; self.surface = surface } }
    private static var active: [ObjectIdentifier: Slot] = [:]
    let card = SheetCard(frame: .zero)
    let clock: any OverlayClock
    private(set) var isShowing = false
    private(set) var isDismissing = false
    private(set) var anchorRect = CGRect.zero
    var reduceMotion = false
    var dismissesOnOutside = true
    var onDismiss: ((SheetDismissReason) -> Void)?
    var initialResponder: NSView? { self }
    var appearanceStartsHidden:Bool {false}
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    var grid: CGFloat { max(1, window?.backingScaleFactor ?? 1) }
    private var monitor: Any?, resignation: NSObjectProtocol?
    private var removal: OverlayCancellation?
    private weak var savedResponder: NSResponder?
    private var epoch = 0
    init(clock: any OverlayClock = OverlaySystemClock()) {
        self.clock = clock; super.init(frame: .zero); wantsLayer = true
        appearance = NSAppearance(named: .darkAqua); addSubview(card)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true; layoutSubtreeIfNeeded() }
    isolated deinit { removal?.cancel(); if let monitor { NSEvent.removeMonitor(monitor) }; if let resignation { NotificationCenter.default.removeObserver(resignation) } }
    func present(anchor: CGRect, in host: NSView) {
        if let previousHost = superview, previousHost !== host, Self.active[ObjectIdentifier(previousHost)]?.surface === self { Self.active.removeValue(forKey: ObjectIdentifier(previousHost)) }
        let old = Self.active[ObjectIdentifier(host)]?.surface
        Self.active = Self.active.filter { $0.value.host != nil && $0.value.surface != nil }
        let slot = Slot(host, self); Self.active[ObjectIdentifier(host)] = slot
        if let old, old !== self { old.dismiss(reason: .replaced, animated: false) }
        guard Self.active[ObjectIdentifier(host)] === slot else { return } // A callback presented a newer modal.
        epoch += 1; removal?.cancel(); removal = nil; removeMonitors()
        if !isShowing { savedResponder = host.window?.firstResponder }
        if superview !== host { removeFromSuperview(); host.addSubview(self, positioned: .above, relativeTo: nil) }
        frame = host.bounds; autoresizingMask = [.width, .height]; anchorRect = snapped(convert(anchor, from: host))
        isShowing = true; isDismissing = false; isHidden = false
        card.layer?.removeAllAnimations(); card.content.layer?.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true); card.layer?.opacity = appearanceStartsHidden ? 0:1; card.content.layer?.transform = CATransform3DIdentity; CATransaction.commit()
        needsLayout = true; layoutSubtreeIfNeeded(); card.displayIfNeeded(); installMonitors(); animateIn()
        if let initialResponder { window?.makeFirstResponder(initialResponder) }
        window?.invalidateCursorRects(for: self); NSCursor.arrow.set()
    }
    func dismiss() { dismiss(reason: .programmatic) }
    func dismiss(reason: SheetDismissReason, animated: Bool = true) {
        guard isShowing else { return }
        if isDismissing { if !animated { finish() }; return }
        let generation = epoch
        isDismissing = true; willDismiss(reason: reason); onDismiss?(reason)
        guard epoch == generation, isShowing, isDismissing else { return }
        if !animated || reduceMotion { finish(); return }
        animateOut()
        removal = clock.schedule(after: 0.16) { [weak self] in guard let self, self.epoch == generation else { return }; self.finish() }
    }
    func willDismiss(reason: SheetDismissReason) {}
    func didFinish() {}
    func handleKey(_ key: OverlayKey) -> Bool { if key == .escape { dismiss(reason: .escape); return true }; return false }
    @discardableResult func outsideClick(at point: CGPoint) -> Bool {
        guard isShowing else { return false }
        if isDismissing { return true }
        guard !card.frame.contains(point) else { return false }
        if dismissesOnOutside { dismiss(reason: .outside) }
        return true
    }
    func snapped(_ rect: CGRect) -> CGRect { SheetStyle.snap(rect, scale: grid) }
    func anchored(size: CGSize, upward: Bool, gap: CGFloat = 10) -> CGRect {
        let w = max(1, min(size.width, bounds.width - 24)), h = max(1, min(size.height, bounds.height - 24))
        let x = min(max(12, anchorRect.midX - w / 2), max(12, bounds.width - 12 - w))
        let y = upward ? max(12, anchorRect.minY - gap - h) : min(anchorRect.maxY + gap, max(12, bounds.height - 12 - h))
        return snapped(CGRect(x: x, y: y, width: w, height: h))
    }
    func animateIn() { if let layer = card.layer { OverlayMotion.animate(layer, "opacity", from: 0, to: 1, curve: OverlayMotion.ease(0.16), enabled: !reduceMotion) } }
    func animateOut() { if let layer = card.layer { OverlayMotion.animate(layer, "opacity", from: 1, to: 0, curve: OverlayMotion.ease(0.16), enabled: !reduceMotion) } }
    func snapshot(scale: CGFloat) -> CGImage {
        layoutSubtreeIfNeeded()
        func samples(_ view: NSView) -> [() -> Void] { (view as? SheetActivityDots).map { [$0.samplePresentationForCapture()] } ?? view.subviews.flatMap(samples) }
        let restore = samples(self); defer { restore.reversed().forEach { $0() } }
        return NativeViewBitmap.capture(self, scale: scale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return isDismissing ? self : super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) { _ = outsideClick(at: convert(event.locationInWindow, from: nil)) }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    private func finish() {
        removal?.cancel(); removal = nil; removeMonitors()
        let owner = window
        let responderView = (owner?.firstResponder as? NSView) ?? ((owner?.firstResponder as? NSTextView)?.delegate as? NSView)
        let owned = responderView?.isDescendant(of: self) == true || ((owner?.firstResponder as? NSTextView)?.delegate as? NSView)?.isDescendant(of: self) == true
        if owned, let savedResponder { owner?.makeFirstResponder(savedResponder) }
        if let host = superview, Self.active[ObjectIdentifier(host)]?.surface === self { Self.active.removeValue(forKey: ObjectIdentifier(host)) }
        isShowing = false; isDismissing = false; didFinish(); removeFromSuperview(); savedResponder = nil
    }
    private func installMonitors() {
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak window] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let window, self.isShowing, event.window === window else { return false }
                if event.type != .keyDown { return self.outsideClick(at: self.convert(event.locationInWindow, from: nil)) }
                if self.isDismissing { return true }
                guard let key = OverlayKey.from(code: event.keyCode, modifiers: event.modifierFlags) else { return false }
                if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
                return self.handleKey(key)
            }
            return consumed ? nil : event
        }
        resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.dismissesOnOutside else { return }; self.dismiss(reason: .windowResigned) }
        }
    }
    private func removeMonitors() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; if let resignation { NotificationCenter.default.removeObserver(resignation); self.resignation = nil } }
}
