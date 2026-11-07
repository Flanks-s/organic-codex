import AppKit

/// UI lifetime owner. Keep this with the scene/window and reuse each view across full/brief/motion mounts.
/// It owns no windows, timers, global key monitors or implicit focus requests.
@MainActor final class NativeComposerSessions {
    struct DraftToken: Equatable { fileprivate let generation: UInt64 }
    private var retained: [String: NativeComposer] = [:]
    private var draftComposer: NativeComposer?
    private(set) var draftGeneration: UInt64 = 0
    /// Send Message's keys for composers made from now on (the draft is made on first New Chat, after the app applied them).
    var onModeHandoffGuardChanged:(()->Void)?
    private func wireModeGuard(_ composer:NativeComposer) {composer.onModeHandoffGuardChanged={ [weak self] in self?.onModeHandoffGuardChanged?() }}
    private var modeContentEpochFrozen=false
    func setModeContentEpochFrozen(_ frozen:Bool) {
        modeContentEpochFrozen=frozen
        for composer in retained.values {composer.setModeContentEpochFrozen(frozen)}
        draftComposer?.setModeContentEpochFrozen(frozen)
    }
    var modeContentCanHandoff:Bool {retained.values.allSatisfy {!$0.isComposing && !$0.isChoosingAttachments} && draftComposer?.isComposing != true && draftComposer?.isChoosingAttachments != true}
    var sendShortcut: NativeComposerSendShortcut?

    func composer(for conversation: Conversation, store: ConversationStore? = nil) -> NativeComposer {
        if let existing = retained[conversation.id] { return existing }
        let composer = NativeComposer(conversation: conversation, store: store)
        wireModeGuard(composer)
        if let sendShortcut { composer.sendShortcut = sendShortcut }
        composer.setModeContentEpochFrozen(modeContentEpochFrozen)
        retained[conversation.id] = composer; return composer
    }
    func existingComposer(for identity: String) -> NativeComposer? { retained[identity] }
    /// A conversation moves to another window (f002, Claude): its editor leaves this owner with its text, selection,
    /// marked text and Undo, out of the view tree, for the other window's sessions to `adopt`.
    func release(_ identity: String) -> NativeComposer? {
        guard let composer = retained.removeValue(forKey: identity) else { return nil }
        composer.onModeHandoffGuardChanged=nil;composer.setModeContentEpochFrozen(false)
        composer.onStopRequest = nil; composer.onRefreshHistory = nil
        composer.invalidateAccessibilityLease();composer.removeFromSuperview()
        return composer
    }
    func adopt(_ composer: NativeComposer, for identity: String) {
        guard retained[identity] == nil else { return }
        wireModeGuard(composer);composer.setModeContentEpochFrozen(modeContentEpochFrozen)
        composer.invalidateAccessibilityLease();retained[identity] = composer
    }
    /// Reopening the same draft keeps text, attachments, selection, marked text and Undo intact.
    func draft() -> (composer: NativeComposer, token: DraftToken) {
        if draftComposer == nil { draftComposer = NativeComposer();wireModeGuard(draftComposer!); if let sendShortcut { draftComposer?.sendShortcut = sendShortcut };draftComposer?.setModeContentEpochFrozen(modeContentEpochFrozen) }
        return (draftComposer!, DraftToken(generation: draftGeneration))
    }
    func isCurrentDraft(_ token: DraftToken) -> Bool { token.generation == draftGeneration && draftComposer != nil }
    /// First-send promotion reuses the same editor. The next draft has a fresh root and UndoManager.
    /// Stale callbacks must present their token and cannot promote a later draft.
    @discardableResult func promoteDraft(_ token: DraftToken, to conversation: Conversation, store: ConversationStore? = nil) -> NativeComposer? {
        guard isCurrentDraft(token), retained[conversation.id] == nil, let composer = draftComposer else { return nil }
        // Binding synchronizes the model; preserve an active composition rather than replaying its string.
        conversation.draft = composer.text; conversation.attachments = composer.attachments
        conversation.access = composer.access; conversation.next = composer.settings
        guard composer.bind(to: conversation, store: store) else { return nil }
        retained[conversation.id] = composer; draftComposer = nil; draftGeneration &+= 1
        return composer
    }
    /// Explicit discard is refused during composition and while a send is pending.
    @discardableResult func discardDraft(_ token: DraftToken) -> Bool {
        guard isCurrentDraft(token), let composer = draftComposer, !composer.isComposing, !composer.hasPendingSubmission else { return false }
        composer.invalidateAccessibilityLease();draftComposer = nil; draftGeneration &+= 1; return true
    }
    @discardableResult func removeConversation(_ identity: String) -> Bool {
        guard let composer = retained[identity], !composer.isComposing, !composer.hasPendingSubmission else { return false }
        composer.invalidateAccessibilityLease();retained[identity] = nil; return true
    }
}
