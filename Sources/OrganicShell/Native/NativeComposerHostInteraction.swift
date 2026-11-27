import AppKit

/// Temporary UI policy only. The retained composer still owns draft, Undo and submissions.
@MainActor final class NativeComposerHostInteraction {
    struct HostToken: Equatable { fileprivate let id = UUID() }
    enum Move: Equatable { case superview, window, hidden, replaced }
    struct State: Equatable {
        var focused: Bool, composing: Bool, choosingAttachments: Bool, pendingSubmission: Bool
    }
    struct Callbacks {
        var onFocusChange: ((Bool) -> Void)?
        var onCancel: (() -> Void)?
        var onHostMove: ((Move) -> Void)?
        var didSubmit: ((NativeComposerSubmission) -> Void)?
        var onStateChange: ((State) -> Void)?
    }
    let token = HostToken()
    weak var host: NSView?
    let windowIdentity: ObjectIdentifier?
    let identity: String?
    let placeholder: String
    let callbacks: Callbacks
    private var lastState: State?
    init(composer: NativeComposer, host: NSView, placeholder: String, callbacks: Callbacks) {
        self.host = host; windowIdentity = composer.window.map(ObjectIdentifier.init); identity = composer.identity
        self.placeholder = placeholder; self.callbacks = callbacks
    }
    func matches(_ composer: NativeComposer) -> Bool {
        host != nil && composer.superview === host && composer.window.map(ObjectIdentifier.init) == windowIdentity && composer.identity == identity
    }
    func publishState(_ composer: NativeComposer) {
        let value = State(focused: composer.editorFocused, composing: composer.isComposing,
                          choosingAttachments: composer.isChoosingAttachments, pendingSubmission: composer.hasPendingSubmission)
        guard value != lastState else { return }
        lastState = value; callbacks.onStateChange?(value)
    }
}

extension NativeComposer {
    /// Mount first, then install. A later install supersedes the old token without touching ordinary callbacks.
    @discardableResult func installHostInteraction(in host: NSView, placeholder: String = "Reply…",
        callbacks: NativeComposerHostInteraction.Callbacks = .init()) -> NativeComposerHostInteraction.HostToken {
        precondition(superview === host, "Install temporary interaction after mounting the retained composer")
        let previous = hostInteraction
        let next = NativeComposerHostInteraction(composer: self, host: host, placeholder: placeholder, callbacks: callbacks)
        hostInteraction = next
        refreshHostPresentation()
        previous?.callbacks.onHostMove?(.replaced)
        if hostInteraction === next { next.publishState(self) }
        return next.token
    }
    @discardableResult func revokeHostInteraction(_ token: NativeComposerHostInteraction.HostToken) -> Bool {
        guard hostInteraction?.token == token else { return false }
        hostInteraction = nil; refreshHostPresentation(); return true
    }
    func isHostInteractionCurrent(_ token: NativeComposerHostInteraction.HostToken) -> Bool {
        hostInteraction?.token == token && hostInteraction?.matches(self) == true
    }
    var hostPlaceholder: String? { hostInteraction?.matches(self) == true ? hostInteraction?.placeholder : nil }
    func hostFocusChanged(_ focused: Bool, from observed: NativeComposerHostInteraction?) {
        guard let observed, hostInteraction === observed, observed.matches(self) else { return }
        observed.callbacks.onFocusChange?(focused)
        hostStateChanged()
    }
    func hostCancelled(from observed: NativeComposerHostInteraction?) {
        guard let observed, hostInteraction === observed, observed.matches(self) else { return }
        observed.callbacks.onCancel?()
    }
    func hostSubmitted(_ submission: NativeComposerSubmission, from observed: NativeComposerHostInteraction?) {
        guard let observed, hostInteraction === observed, observed.matches(self) else { return }
        observed.callbacks.didSubmit?(submission)
    }
    func hostStateChanged() {
        guard let current = hostInteraction, current.matches(self) else { return }
        current.publishState(self)
    }
    func hostMoved(_ reason: NativeComposerHostInteraction.Move) {
        guard let observed = hostInteraction else { return }
        if reason == .hidden || !observed.matches(self) { _ = revokeHostInteraction(observed.token) }
        observed.callbacks.onHostMove?(reason)
    }
}
