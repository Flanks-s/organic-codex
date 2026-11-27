import AppKit
import QuartzCore

/// One temporary native mount. The session, editor and ordinary callbacks remain the conversation's.
@MainActor final class PeekReplyHost: NSView {
    let id: String
    let composer: NativeComposer
    weak var parent: NSView?
    private(set) var token: NativeComposerHostInteraction.HostToken?
    private(set) var active = true
    private(set) var holdsPeek = false
    var onRetire: ((PeekReplyHost) -> Void)?
    var onHold: (() -> Void)?
    var onGeometry: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var returnComposer: ((NativeComposer) -> Void)?
    private var focusWork: DispatchWorkItem?
    override var isFlipped: Bool { true }
    init(id: String, composer: NativeComposer, size: CGSize, parent: NSView? = nil) {
        self.id = id; self.composer = composer
        self.parent = parent
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; autoresizesSubviews = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func install() {
        token = composer.installHostInteraction(in: parent ?? self, callbacks: .init(
            onCancel: { [weak self] in self?.onCancel?() },
            onHostMove: { [weak self] _ in self?.retire(returning: false) },
            didSubmit: { [weak self] _ in self?.focusAfterSubmit() },
            onStateChange: { [weak self] state in
                guard let self, self.active else { return }
                let held = state.focused || state.composing || state.choosingAttachments
                if self.holdsPeek != held { self.holdsPeek = held; self.onHold?() }
            }))
    }
    var isCurrent: Bool { active && token.map(composer.isHostInteractionCurrent) == true }
    var isColumn: Bool { parent != nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isCurrent, let hit = super.hitTest(point) else { return nil }
        return hit === composer || hit === self ? self : hit
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { focusReply() }
    func focusReply() {
        guard isCurrent else { return }
        window?.makeKey(); composer.focus()
    }
    private func focusAfterSubmit() {
        focusWork?.cancel()
        guard let window = composer.window else { return }
        let expected = window.firstResponder
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.isCurrent, self.composer.window === window, window.isKeyWindow,
                  window.firstResponder === expected || window.firstResponder === window else { return }
            self.composer.focus()
        }
        focusWork = work; DispatchQueue.main.async(execute: work)
    }
    /// No scheduled cleanup owns a newer mount: retirement is synchronous and object-scoped.
    func retire(returning: Bool = true, fadeDuration: Double = 0) {
        guard active else { return }
        active = false; focusWork?.cancel(); focusWork = nil
        setAccessibilityChildren([])
        let exit = fadeDuration > 0 && returning && !isColumn
            ? NativeViewBitmap.capture(self, scale: window?.backingScaleFactor ?? 2)
            : nil
        if let token { _ = composer.revokeHostInteraction(token) }; token = nil
        holdsPeek = false
        if returning, composer.superview === (parent ?? self) { returnComposer?(composer) }
        if let exit, let layer {
            let ink = CALayer(); ink.frame = bounds; ink.contents = exit; layer.addSublayer(ink)
            // The existing reply viewport owns the single fade; cleanup owns only this old snapshot.
            DispatchQueue.main.asyncAfter(deadline: .now()+fadeDuration) { [weak self] in self?.removeFromSuperview() }
        } else { removeFromSuperview() }
        onGeometry?(.zero); onRetire?(self)
        onRetire = nil; onHold = nil; onGeometry = nil; onCancel = nil; returnComposer = nil
    }
    func place(origin: CGPoint, visible: CGRect, in plane: NSView) {
        guard isCurrent else { return }
        if let parent {
            onGeometry?(parent.convert(composer.frame, to: plane).intersection(visible))
            return
        }
        if frame.origin != origin { setFrameOrigin(origin) }
        onGeometry?(convert(bounds, to: plane).intersection(visible))
    }
}
