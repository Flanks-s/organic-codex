import AppKit

enum SheetToastDismissReason: Equatable, Sendable { case close, undo, timeout, replaced, programmatic }

/// Only the capsule hits; the rest of the host stays interactive. Closing pixels retain their hit until fade ends.
@MainActor class SheetToast: OverlayView {
    private final class Slot { weak var host: NSView?; weak var toast: SheetToast?; init(_ host: NSView, _ toast: SheetToast) { self.host = host; self.toast = toast } }
    private static var active: [ObjectIdentifier: Slot] = [:]
    let card = SheetCard(frame: .zero)
    private let label = SheetStyle.label("", size: 13)
    let undoButton = SheetButton(frame: .zero), closeButton = SheetButton(frame: .zero)
    let clock: any OverlayClock
    private(set) var isShowing = false, isDismissing = false
    private(set) var anchorRect = CGRect.zero
    var reduceMotion = false
    /// M10_DRAFT_EXPOSURE=0: off, for live on/off comparisons.
    var exposureEnabled = ProcessInfo.processInfo.environment["M10_DRAFT_EXPOSURE"] != "0" {
        didSet {if !exposureEnabled {contentRemoval?.cancel();contentRemoval=nil;contentTransition?.finish();contentTransition=nil}}
    }
    var motionProfile:DisplayProfile?
    var zoom=SheetZoom.selected
    var sceneClock=SceneClock()
    private(set) var contentTransition:SheetContentTransition?
    private var contentRemoval:OverlayCancellation?
    var onDismiss: ((SheetToastDismissReason) -> Void)?
    private var undoAction: (() -> Void)?
    private var expiry: OverlayCancellation?, removal: OverlayCancellation?
    private var generation = 0
    private var appearanceBegan:Double?
    init(clock: any OverlayClock = OverlaySystemClock()) {
        self.clock = clock; super.init(frame: .zero); appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true; card.radius = 16; addSubview(card)
        for view in [label, undoButton, closeButton] { card.content.addSubview(view) }
        undoButton.title = "Undo"; undoButton.drawsPlate = false; undoButton.accent = true
        undoButton.drawContent = { rect in SheetStyle.text("Undo", in: CGRect(x: 0, y: 4, width: rect.width, height: 20), size: 13, color: .controlAccentColor, weight: .semibold, align: .center) }
        undoButton.invoke = { [weak self] in self?.undo() }
        closeButton.title = "×"; closeButton.drawsPlate = false; closeButton.setAccessibilityLabel("Dismiss")
        closeButton.invoke = { [weak self] in self?.dismiss(reason: .close) }
        for button in [undoButton,closeButton] {button.onVisualChange = { [weak self] in self?.contentTransition?.refresh() }}
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true; layoutSubtreeIfNeeded() }
    isolated deinit { expiry?.cancel(); removal?.cancel();contentRemoval?.cancel();contentTransition?.finish() }
    func present(text: String, anchor: CGRect, in host: NSView, duration: TimeInterval? = nil, undo: (() -> Void)? = nil) {
        if let previousHost = superview, previousHost !== host, Self.active[ObjectIdentifier(previousHost)]?.toast === self { Self.active.removeValue(forKey: ObjectIdentifier(previousHost)) }
        let old = Self.active[ObjectIdentifier(host)]?.toast
        Self.active = Self.active.filter { $0.value.host != nil && $0.value.toast != nil }
        let slot = Slot(host, self); Self.active[ObjectIdentifier(host)] = slot
        if let old, old !== self { old.dismiss(reason: .replaced, animated: false) }
        guard Self.active[ObjectIdentifier(host)] === slot else { return }
        generation += 1; expiry?.cancel(); removal?.cancel(); undoAction = undo
        if superview !== host { removeFromSuperview(); host.addSubview(self, positioned: .above, relativeTo: nil) }
        frame = host.bounds; autoresizingMask = [.width, .height]; anchorRect = convert(anchor, from: host)
        if !reduceMotion,window != nil {CATransaction.begin();CATransaction.setDisableActions(true);card.layer?.opacity=0;CATransaction.commit()}
        label.stringValue = text; undoButton.isHidden = undo == nil; isShowing = true; isDismissing = false
        contentRemoval?.cancel();contentTransition?.finish();contentTransition=nil
        card.layer?.removeAllAnimations();card.content.layer?.removeAllAnimations();card.content.layer?.transform=CATransform3DIdentity;card.content.resetExposure(); needsLayout = true; layoutSubtreeIfNeeded()
        if !reduceMotion,window != nil {startContent(visible:true)}
        let t=contentTransition?.commitTime ?? sceneClock.mediaTime(),curve=OverlayCurve(0.3,1.15,0.5,1,0.35)
        appearanceBegan=t
        SheetMotionAnimation.animate(card.layer!,"opacity",from:0,to:1,curve:curve,at:t,enabled:!reduceMotion)
        SheetMotionAnimation.animate(card.content.layer!,"transform.translation.y",from:8,to:0,curve:curve,at:t,enabled:!reduceMotion)
        SheetMotionAnimation.animate(card.content.layer!,"transform.scale",from:0.98,to:1,curve:curve,at:t,enabled:!reduceMotion)
        if let duration { let id = generation; expiry = clock.schedule(after: duration) { [weak self] in guard let self, self.generation == id else { return }; self.dismiss(reason: .timeout) } }
        setAccessibilityLabel(text)
    }
    /// Also used by the offscreen verifier with an explicit scene timestamp (never creates a window).
    func startContent(visible:Bool,at time:Double?=nil) {
        guard exposureEnabled,!reduceMotion else {return}
        if contentTransition == nil {
            let content=SheetContentTransition(clock:sceneClock);contentTransition=content
            content.begin(in:card.content,mode:zoom,configuration:.system,visible:visible,at:time,scale:max(1,window?.backingScaleFactor ?? 1),pivot:card.content.layer?.anchorPoint == .zero ? .zero:CGPoint(x:card.bounds.midX,y:card.bounds.midY))
        } else {contentTransition?.setVisible(visible,at:time ?? sceneClock.mediaTime())}
        let time=time ?? contentTransition?.commitTime ?? sceneClock.mediaTime()
        if visible,zoom == .accum {
            let rect=card.bounds,curve=OverlayCurve(0.3,1.15,0.5,1,0.35),anchor=card.content.layer!.anchorPoint
            contentTransition?.animateAccumulation(duration:curve.duration,at:time,profile:motionProfile ?? M10FExposure.profile(for:self)) {t in
                let p=CGFloat(curve.value(at:t/curve.duration)),s=0.98+0.02*p
                return CGRect(x:anchor.x*rect.width*(1-s),y:anchor.y*rect.height*(1-s)+8*(1-p),width:rect.width*s,height:rect.height*s)
            }
        }
        if visible {
            let lifetime=zoom == .gauss ? ContentGaussianTransition.Configuration.system.duration:0.35
            let id=generation;contentRemoval?.cancel();contentRemoval=clock.schedule(after:lifetime) { [weak self] in
                guard let self,self.generation==id,!self.isDismissing else {return}
                self.contentTransition?.settle(at:time+lifetime);self.contentTransition?.finish();self.contentTransition=nil;self.contentRemoval=nil
            }
        }
    }
    override func layout() {
        super.layout(); let scale = max(1, window?.backingScaleFactor ?? 1)
        let textWidth = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
        // 4 pt beyond the text: the label's own inset truncated it at exactly its width (Claude, HP recording 10-29).
        let w = min(max(1, bounds.width - 24), ceil(textWidth) + 4 + 14 + 10 + 28 + (undoAction == nil ? 0 : 56))
        card.frame = SheetStyle.snap(CGRect(x: min(max(12, anchorRect.midX - w / 2), max(12, bounds.width - 12 - w)), y: max(12, anchorRect.minY - 10 - 32), width: w, height: 32), scale: scale)
        card.layoutSubtreeIfNeeded(); closeButton.frame = SheetStyle.snap(CGRect(x: w - 28, y: 5, width: 22, height: 22), scale: scale)
        undoButton.frame = SheetStyle.snap(CGRect(x: w - 84, y: 2, width: 50, height: 28), scale: scale)
        label.frame = SheetStyle.snap(CGRect(x: 14, y: 7, width: max(1, w - 14 - 38 - (undoAction == nil ? 0 : 56)), height: 19), scale: scale)
    }
    func openingOpacity(at time:Double)->Float {
        guard let began=appearanceBegan else {return 1}
        return Float(min(1,max(0,OverlayCurve(0.3,1.15,0.5,1,0.35).value(at:max(0,time-began)/0.35))))
    }
    func undo() { guard isShowing, !isDismissing, let undoAction else { return }; dismiss(reason: .undo); undoAction() }
    func dismiss() { dismiss(reason: .programmatic) }
    func dismiss(reason: SheetToastDismissReason, animated: Bool = true) {
        guard isShowing else { return }
        if isDismissing { if !animated { finish() }; return }
        let id = generation
        isDismissing = true; expiry?.cancel(); expiry = nil; onDismiss?(reason)
        guard generation == id, isShowing, isDismissing else { return }
        if !animated || reduceMotion { finish(); return }
        contentRemoval?.cancel();contentRemoval=nil
        if zoom == .gauss {startContent(visible:false)}
        let t=contentTransition?.effect?.plan?.began ?? sceneClock.mediaTime()
        SheetMotionAnimation.animate(card.layer!, "opacity", from: zoom == .gauss && exposureEnabled ? openingOpacity(at:t):1, to: 0, curve: OverlayCurve(0, 0, 0.58, 1, 0.2),at:t, enabled: true)
        removal = clock.schedule(after: 0.2) { [weak self] in guard let self, self.generation == id else { return }; self.finish() }
    }
    private func finish() {
        removal?.cancel(); removal = nil; undoAction = nil
        contentRemoval?.cancel();contentRemoval=nil;contentTransition?.finish();contentTransition=nil
        card.content.layer?.removeAnimation(forKey:"m10F.exposure");card.content.trail.reset()
        if let host = superview, Self.active[ObjectIdentifier(host)]?.toast === self { Self.active.removeValue(forKey: ObjectIdentifier(host)) }
        isShowing = false; isDismissing = false; removeFromSuperview()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard isShowing, !isHidden, card.frame.contains(local) else { return nil }
        return isDismissing ? self : super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    func snapshot(scale: CGFloat) -> CGImage { layoutSubtreeIfNeeded(); return NativeViewBitmap.capture(self, scale: scale) }
}

@MainActor final class SheetArchiveUndoToast: SheetToast {
    var onUndo: (() -> Void)?
    func present(archivedTitle: String, anchor: CGRect, in host: NSView) { super.present(text: "“\(archivedTitle)” archived", anchor: anchor, in: host, undo: { [weak self] in self?.onUndo?() }) }
}
@MainActor final class SheetNotice: SheetToast {
    func present(message: String, anchor: CGRect, in host: NSView) { super.present(text: message, anchor: anchor, in: host, duration: 3) }
}
