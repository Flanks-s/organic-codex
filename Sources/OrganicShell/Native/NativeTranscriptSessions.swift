import AppKit

/// One owner per window, shared by Normie and Organic. It retains the actual viewport/TextKit graph, not a copy of
/// scroll/selection state. A released Session is the transferable unit for Move to New Window and Tear/Merge.
@MainActor final class NativeTranscriptSessions {
    @MainActor final class Session {
        let transcript: NativeTranscript
        var conversation: Conversation { transcript.conversation }
        fileprivate weak var owner: NativeTranscriptSessions?
        fileprivate weak var host: NSView?
        fileprivate var generation: UInt64 = 0
        fileprivate var onUnmount: (() -> Void)?
        fileprivate init(_ transcript: NativeTranscript) { self.transcript = transcript }
        isolated deinit { transcript.dispose(); transcript.removeFromSuperview() }
    }
    /// Weak on purpose: a delayed source callback cannot keep a removed conversation/view graph alive.
    @MainActor struct Lease {
        fileprivate weak var session: Session?
        fileprivate let generation: UInt64
        var isCurrent: Bool {
            guard let session, session.owner != nil, session.generation == generation,
                  let host = session.host, session.transcript.superview === host,
                  !session.transcript.isDisposed else { return false }
            return true
        }
        var transcript: NativeTranscript? { isCurrent ? session?.transcript : nil }
        /// Undo only the admitting host's presentation changes before another host takes the view.
        /// An old lease cannot install cleanup on the new mount.
        @discardableResult func onUnmount(_ cleanup: @escaping () -> Void) -> Bool {
            guard isCurrent else { return false }
            session?.onUnmount = cleanup
            return true
        }
        /// Hosts sample their own motion clock. This only places the admitted view, with no implicit animation/focus.
        @discardableResult func place(_ rect: CGRect) -> Bool {
            guard let transcript else { return false }
            let scale = max(1, transcript.window?.backingScaleFactor ?? 1)
            let x = (rect.minX * scale).rounded() / scale, y = (rect.minY * scale).rounded() / scale
            let frame = CGRect(x: x, y: y, width: max(1, (rect.maxX * scale).rounded() / scale - x),
                               height: max(1, (rect.maxY * scale).rounded() / scale - y))
            if transcript.frame != frame {
                NSAnimationContext.beginGrouping(); NSAnimationContext.current.duration = 0
                NSAnimationContext.current.allowsImplicitAnimation = false
                transcript.frame = frame
                NSAnimationContext.endGrouping()
            }
            return true
        }
        /// Freeze a source before its snapshot without removing its pixels; reactivation consumes deferred changes.
        @discardableResult func setActive(_ active: Bool) -> Bool {
            guard let transcript else { return false }
            transcript.presentationActive = active
            return true
        }
        fileprivate var canAct: Bool { isCurrent && session?.transcript.presentationActive == true }
        @discardableResult func setVisible(_ visible: Bool) -> Bool {
            guard let transcript else { return false }
            transcript.isHidden = !visible
            return true
        }
    }
    @MainActor struct Configuration {
        var decisionCardsInline = true
        var decisionCardsAtBottom = false
        weak var messageDraftTarget: NativeComposer?
        var onUserMessageAction: ((NativeUserMessageAction) -> Void)?
        var onEditMessage: ((TranscriptItem) -> Void)?
        var onForkMessage: ((TranscriptItem) -> Void)?
        var onApproval: ((Approval, ApprovalAction) -> Void)?
        var onApprovalValue: ((Approval, JSONValue) -> Void)?
        var onAnswer: ((UserInputRequest, [String: [String]]) -> Void)?
        var onReviewChanges: ((TranscriptItem) -> Void)?
        var onRevertChanges: ((TranscriptItem) -> Void)?
    }
    private(set) var modeMountGeneration:UInt64=0
    var modeContentMountLocked=false
    private var modeContentMountPermission=0
    var modeContentNativeAdmissionAllowed:Bool {modeContentMountPermission>0}
    func withModeContentMountPermission(_ body:()->Bool)->Bool {
        modeContentMountPermission+=1;defer {modeContentMountPermission-=1};return body()
    }
    var onModeContentCatchupFinished:((String)->Void)?
    private var modeContentModels:[String:Conversation]?
    func beginModeContentEpoch(_ conversations:[Conversation]) {
        guard modeContentModels == nil else {return}
        let models=Dictionary(uniqueKeysWithValues:conversations.map {($0.id,ModeContentEpoch.copy(retained[$0.id]?.transcript.modeContentRenderedValue ?? $0))})
        modeContentModels=models
        for session in retained.values {session.transcript.beginModeContentEpoch(snapshot:models[session.conversation.id])}
    }
    func modePresentationValue(_ conversation:Conversation)->Conversation {modeContentModels?[conversation.id] ?? retained[conversation.id]?.transcript.modeContentPresentationValue ?? conversation}
    func endModeContentEpoch() {
        modeContentModels=nil
        for session in retained.values {session.transcript.endModeContentEpoch()}
    }
    private var retained: [String: Session] = [:]
    private weak var store: ConversationStore?
    private var observation: UUID?
    private(set) var isDisposed = false
    var transcripts: [String: NativeTranscript] { retained.mapValues(\.transcript) }
    var count: Int { retained.count }
    var canHandoff: Bool { !isDisposed && retained.values.allSatisfy { $0.transcript.canHandoff } }

    init(store: ConversationStore? = nil) {
        self.store = store
        observation = store?.observe { [weak self, weak store] c in
            guard let self, let session = self.retained[c.id],
                  store?.conversation(c.id) !== session.conversation else { return }
            self.removeConversation(c.id)
        }
    }
    isolated deinit {
        if let observation { store?.removeObserver(observation) }
        for session in retained.values { retire(session); session.transcript.dispose() }
    }
    func existingTranscript(for identity: String) -> NativeTranscript? { retained[identity]?.transcript }
    /// Lookup never steals a mount. Same ID with a different model is a replacement, never an old selection/session.
    func transcript(for conversation: Conversation, store suppliedStore: ConversationStore? = nil) -> NativeTranscript {
        precondition(!isDisposed, "A disposed transcript owner cannot create sessions")
        if let existing = retained[conversation.id], existing.conversation === conversation { return existing.transcript }
        removeConversation(conversation.id)
        let transcript = NativeTranscript(conversation: conversation, store: suppliedStore ?? store)
        transcript.onModeContentCatchupFinished={ [weak self] in self?.onModeContentCatchupFinished?(conversation.id) }
        if let snapshot=modeContentModels?[conversation.id] {transcript.beginModeContentEpoch(snapshot:snapshot)}
        transcript.presentationActive = false; transcript.isHidden = true
        let session = Session(transcript); session.owner = self; retained[conversation.id] = session
        return transcript
    }
    /// Claim only at the host's semantic handoff (after its source screenshot, before target admission).
    /// nil means an active menu/selection gesture/IME or a pending native approval review must finish first.
    func mount(_ conversation: Conversation, in host: NSView, frame: CGRect? = nil, configuration: Configuration = .init(),
               store: ConversationStore? = nil, visible:Bool=true) -> Lease? {
        guard !isDisposed else { return nil }
        let transcript = transcript(for: conversation, store: store)
        guard transcript.canHandoff, let session = retained[conversation.id] else { return nil }
        if modeContentMountLocked,modeContentMountPermission == 0 {
            guard session.host === host,transcript.superview === host else {return nil}
            let lease=Lease(session:session,generation:session.generation)
            if let frame {_=lease.place(frame)}
            return lease
        }
        retire(session)
        modeMountGeneration &+= 1
        session.host = host
        let lease = Lease(session: session, generation: session.generation)
        host.addSubview(transcript)
        if let frame { _ = lease.place(frame) }
        else if transcript.frame.width <= 0, host.bounds.width > 0 { _ = lease.place(host.bounds) }
        // Hide while installing callbacks and the inline/external-card policy; one deferred refresh on admission.
        transcript.configurePresentation {
            transcript.decisionCardsInline = configuration.decisionCardsInline
            transcript.decisionCardsAtBottom = configuration.decisionCardsAtBottom
            transcript.messageDraftTarget = configuration.messageDraftTarget
            if let action = configuration.onUserMessageAction { transcript.onUserMessageAction = { if lease.canAct { action($0) } } }
            if let action = configuration.onEditMessage { transcript.onEditMessage = { if lease.canAct { action($0) } } }
            if let action = configuration.onForkMessage { transcript.onForkMessage = { if lease.canAct { action($0) } } }
            if let action = configuration.onApproval { transcript.onApproval = { if lease.canAct { action($0, $1) } } }
            if let action = configuration.onApprovalValue { transcript.onApprovalValue = { if lease.canAct { action($0, $1) } } }
            if let action = configuration.onAnswer { transcript.onAnswer = { if lease.canAct { action($0, $1) } } }
            if let action = configuration.onReviewChanges { transcript.onReviewChanges = { if lease.canAct { action($0) } } }
            if let action = configuration.onRevertChanges { transcript.onRevertChanges = { if lease.canAct { action($0) } } }
        }
        transcript.presentationActive = true; transcript.isHidden = !visible
        return lease
    }
    /// Revoking an old mount is harmless after another host acquired it. This never disposes the session.
    @discardableResult func unmount(_ lease: Lease) -> Bool {
        guard lease.isCurrent, let session = lease.session, session.owner === self else { return false }
        retire(session); return true
    }
    private func retire(_ session: Session) {
        session.generation &+= 1; session.host = nil
        let cleanup = session.onUnmount; session.onUnmount = nil
        cleanup?()
        let view = session.transcript
        view.presentationActive = false; view.isHidden = true
        view.invalidateAccessibilityLease(); view.clearPresentationCallbacks(); view.retireExternalDecisionCards(); view.removeFromSuperview()
    }
    /// Transfer without disposal. A rejected adopt leaves the transferable Session untouched in the caller's hands.
    func release(_ identity: String) -> Session? {
        guard let session = retained[identity], session.transcript.canHandoff else { return nil }
        session.transcript.endModeContentEpoch()
        retire(session); retained[identity] = nil; session.owner = nil
        return session
    }
    @discardableResult func adopt(_ session: Session) -> Bool {
        guard !isDisposed, session.owner == nil, !session.transcript.isDisposed,
              retained[session.conversation.id] == nil,
              store == nil || store?.conversation(session.conversation.id) === session.conversation else { return false }
        session.transcript.onModeContentCatchupFinished={ [weak self,weak session] in if let id=session?.conversation.id {self?.onModeContentCatchupFinished?(id)} }
        session.generation &+= 1; session.owner = self; retained[session.conversation.id] = session
        return true
    }
    /// A target can have a cold cache from a previous sidebar selection. Replace that cache, never the moving view.
    /// Preflight both sessions; a refused transfer leaves both owners and mounts untouched.
    @discardableResult func transfer(_ identity: String, to destination: NativeTranscriptSessions) -> Bool {
        guard destination !== self, !isDisposed, !destination.isDisposed else { return false }
        guard let session = retained[identity] else { return true }
        guard session.transcript.canHandoff,
              destination.store == nil || destination.store?.conversation(identity) === session.conversation,
              destination.retained[identity]?.transcript.canHandoff != false else { return false }
        let cached = destination.release(identity)
        guard let moving = release(identity) else {
            if let cached { _ = destination.adopt(cached) }; return false
        }
        guard destination.adopt(moving) else {
            _ = adopt(moving); if let cached { _ = destination.adopt(cached) }; return false
        }
        // cached is now unowned: its deinit disposes just that superseded graph.
        return true
    }
    /// Archive/hide is NOT removal. Only permanent removal, a replaced model, or the final owning window's close.
    func removeConversation(_ identity: String) {
        guard let session = retained.removeValue(forKey: identity) else { return }
        retire(session); session.owner = nil; session.transcript.dispose()
    }
    func dispose() {
        guard !isDisposed else { return }; isDisposed = true
        if let observation { store?.removeObserver(observation); self.observation = nil }
        for id in Array(retained.keys) { removeConversation(id) }
    }
}
