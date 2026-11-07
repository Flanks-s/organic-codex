import AppKit

/// Retain with the window. Host can use this root or install sidebar/detail/inspector into its own split controller.
@MainActor final class NormieWorkbench: NSViewController {
    let store: ConversationStore, sessions: NativeComposerSessions, actions: NormieActions
    let sidebar: NormieSidebarController, detail: NormieDetailController, inspector: NormieInspectorController
    var transcriptSessions: NativeTranscriptSessions { detail.transcriptSessions }
    let sidebarModel: NormieSidebarModel
    private(set) var composingNew = false
    private(set) var newContext = NormieNewChatContext()
    private let devicePicker = NewChatDevicePicker()
    private var observation: UUID?
    private var modeContentEpochFrozen=false,modeContentRefreshPending=false
    func setModeContentEpochFrozen(_ frozen:Bool) {
        modeContentEpochFrozen=frozen
        detail.setModeContentInputBlocked(frozen)
        if !frozen,modeContentRefreshPending {modeContentRefreshPending=false;refresh()}
    }
    private func storePresentationChanged() {
        if NormieIdleMotionCapture.orreryEnabled {detail.invalidateIdleMotionPictures()}
        if modeContentEpochFrozen {modeContentRefreshPending=true;return}
        refresh()
    }
    private var updating = false, selecting = false
    private var ownedSubmit: Set<ObjectIdentifier> = []
    private var ownedStop: Set<ObjectIdentifier> = []
    private var ownedRefresh: Set<ObjectIdentifier> = []
    private var ownedContext: Set<ObjectIdentifier> = []
    private var delivered: Set<UUID> = []
    private var defaultSplit: NSSplitViewController?
    private var inspectorCollapseObservation: NSKeyValueObservation?
    let archiveUndoManager: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
    private final class ArchiveUndoToken: NSObject {
        let id: String
        weak var original: Conversation?
        weak var manager: UndoManager?
        init(id: String, original: Conversation, manager: UndoManager) { self.id = id; self.original = original; self.manager = manager }
    }
    private var undoTokens: [ArchiveUndoToken] = []
    private var undoingArchive = false
    var onSelection: ((String?) -> Void)?
    var onModeSearchFocus:(()->Bool)?
    /// Host owns exactly one OverlayComposerBinding for this mount; nil withdraws its event monitor and popovers.
    var onComposerPresentationChange:((NativeComposer?,NSView?)->Void)?{didSet{detail.republishComposerPresentation()}}
    func refreshComposerPresentationBinding(){detail.republishComposerPresentation()}
    var onNotice: ((String) -> Void)?
    var account = NormieAccount() { didSet { sidebar.account = account;if account != oldValue,sidebar.isViewLoaded {NotificationCenter.default.post(name:Notification.Name("Organic.ModePreparationInputsChanged"),object:sidebar.view)} } }
    var sidebarVisible = true
    var inspectorVisible = false { didSet { updateInspectorPresentation() } }
    /// The window owns the split when it mounts our three controllers separately. State is committed before this
    /// callback; the host should show/hide its inspector, rather than toggle it blindly. Nil uses our standalone split.
    var onInspectorRequest: ((Bool) -> Void)?
    var isNormie = true { didSet {
        if !isNormie { devicePicker.close() }
        if NormieIdleMotionCapture.orreryEnabled {detail.setModePresentationActive(isNormie)}
        updateInspectorPresentation()
    } }
    var isCollapsed = false { didSet { updateInspectorPresentation() } }
    private func updateInspectorPresentation() { inspector.presentationActive = inspectorVisible && isNormie && !isCollapsed }
    var isTerminalShown:Bool{detail.isTerminalShown}
    var onTerminalShownChange:((Bool)->Void)?
    var terminalMenuTitle:String{isTerminalShown ? "Hide Terminal":"Show Terminal"}
    var terminalToolbarSymbol:String{"apple.terminal"}
    var terminalToolbarToolTip:String{"Toggle Terminal (⌘J)"}
    func setTerminalShown(_ shown:Bool,animated:Bool=true){guard isNormie || !shown else{return};detail.setTerminalShown(shown,animated:animated)}
    func setTerminalController(_ controller:CoreTerminalController?){detail.setTerminalController(controller)}
    var memberOrder: [String] = []
    var rowFrames: [String: CGRect] { sidebar.rowFrames }
    var avatarFrame: CGRect? { sidebar.avatarFrame }
    var selectedConversation: Conversation? {
        guard !composingNew, let id = sidebarModel.current, let c = store.conversation(id), !c.archived else { return nil }; return c
    }
    var canHandoff: Bool { detail.composer?.isComposing != true && detail.composer?.isChoosingAttachments != true && !detail.terminalPane.isComposing && detail.canHandoffTranscripts }
    lazy var menus = NormieMenuBuilder(context: { [weak self] in self?.menuContext ?? NormieMenuContext(supported: []) }, perform: { [weak self] command, tag in self?.perform(command, tag: tag) })
    lazy var openIn = NormieOpenIn(store: store, selected: { [weak self] in self?.selectedConversation }, notice: { [weak self] in self?.notice($0) })

    init(store: ConversationStore, sessions: NativeComposerSessions, current: String? = nil, actions: NormieActions = NormieActions(), transcriptSessions: NativeTranscriptSessions? = nil) {
        self.store = store; self.sessions = sessions; self.actions = actions
        let initial = current ?? store.conversations.filter { !$0.archived }.max(by: { $0.updated < $1.updated })?.id
        sidebarModel = NormieSidebarModel(store: store, current: initial)
        sidebar = NormieSidebarController(model: sidebarModel)
        detail = NormieDetailController(store: store, sessions: sessions, actions: actions, transcriptSessions: transcriptSessions)
        inspector = NormieInspectorController(store: store, actions: actions, inlineChanges: true)
        super.init(nibName: nil, bundle: nil)
        updateInspectorPresentation()
        composingNew = initial == nil
        memberOrder = store.conversations.filter { !$0.archived }.map(\.id)
        wire()
        observation = store.observe { [weak self] _ in self?.storePresentationChanged() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        let store = store, observation = observation
        if let observation { Task { @MainActor in store.removeObserver(observation) } }
    }
    override func loadView() {
        let root = NormieView(); root.fill = NormieDrawing.background; view = root
        let split = NSSplitViewController(); defaultSplit = split
        let side = NSSplitViewItem(sidebarWithViewController: sidebar); side.minimumThickness = NormieSidebarMetrics.minimumWidth; side.maximumThickness = NormieSidebarMetrics.maximumWidth
        let body = NSSplitViewItem(viewController: detail); body.minimumThickness = 300
        let status = NSSplitViewItem(inspectorWithViewController: inspector)
        status.minimumThickness = 280; status.maximumThickness = 420
        status.preferredThicknessFraction = 320.0 / 1280.0; status.isCollapsed = !inspectorVisible
        split.addSplitViewItem(side); split.addSplitViewItem(body); split.addSplitViewItem(status)
        inspectorCollapseObservation = status.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
            let shown = !item.isCollapsed
            MainActor.assumeIsolated { self?.inspectorVisible = shown }
        }
        addChild(split); root.addSubview(split.view)
        refresh()
    }
    override func viewDidLayout() { super.viewDidLayout(); defaultSplit?.view.frame = view.bounds }
    private func wire() {
        sidebarModel.hasMoreHistory = { [weak self] in self?.actions.hasMoreHistory?() ?? false }
        sidebarModel.onLoadMoreHistory = { [weak self] done in
            guard let load = self?.actions.loadMoreHistory else { done(.failure(CoreWire.failure("History pagination is not connected to Core."))); return }
            load(done)
        }
        sidebarModel.onSelection = { [weak self] id in
            guard let self, !self.selecting else { return }
            if self.modeContentEpochFrozen,!self.transcriptSessions.modeContentNativeAdmissionAllowed {self.modeContentRefreshPending=true;return}
            self.composingNew = id == nil
            if let id, let c = self.store.conversation(id) {
                if let mark = self.actions.markSeen { mark(c) }
                else if !self.store.usesLiveCore && (c.unread || c.completions > 0 || c.redSeen != c.redEvents) {
                    c.unread = false; c.completions = 0; c.redSeen = c.redEvents; self.store.changed(c)
                }
            }
            self.refreshDetail(); self.onSelection?(id)
        }
        sidebarModel.canLeaveSelection = { [weak self] in self?.canHandoff ?? true }
        sidebarModel.onPin = { [weak self] c, value in
            guard let self else { return }
            if let action = self.actions.pin { action(c, value) }
            else if !self.store.usesLiveCore { c.pinned = value; self.store.changed(c) }
            else { self.notice("Pin is not connected to Core.") }
        }
        sidebarModel.onArchive = { [weak self] c, value in
            guard let self else { return }
            if let action = self.actions.archive { action(c, value) }
            else if !self.store.usesLiveCore { c.archived = value; c.archivedAt = value ? .now : nil; self.store.changed(c) }
            else { self.notice("Archive is not connected to Core.") }
        }
        sidebarModel.onRename = { [weak self] c, title in
            guard let self else { return }
            if let action = self.actions.rename { action(c, title) }
            else if !self.store.usesLiveCore { c.title = title; self.store.changed(c) }
            else { self.notice("Rename is not connected to Core.") }
        }
        sidebarModel.onArchiveNotice = { [weak self] id, title in
            guard let self, let original = self.store.conversation(id) else { return }
            let manager = self.sidebar.view.window?.undoManager ?? self.archiveUndoManager
            let token = ArchiveUndoToken(id: id, original: original, manager: manager); self.undoTokens.append(token)
            let opensGroup = manager.groupingLevel == 0
            if opensGroup { manager.beginUndoGrouping() }
            manager.registerUndo(withTarget: token) { [weak self] _ in MainActor.assumeIsolated { _ = self?.undoArchive() } }
            manager.setActionName("Archive")
            if opensGroup { manager.endUndoGrouping() }
            self.detail.showNotice("Archived “\(title)”", undo: true)
        }
        sidebar.undoArchive = { [weak self] in _ = self?.undoArchive() }
        sidebar.onNewChatInProject = { [weak self] project in _ = self?.newChat(projectID: project) }
        sidebar.onAccount = { [weak self] in
            guard let self else { return }
            self.menus.makeAccountMenu(account: self.account, quotaSummary: self.store.quotaMenuSummary)
                .popUp(positioning: nil, at: CGPoint(x: 10, y: 0), in: self.sidebar.accountView)
        }
        detail.onTerminalShownChange={[weak self] value in self?.onTerminalShownChange?(value)}
        detail.onUndo = { [weak self] in _ = self?.undoArchive() }
        detail.onReview = { [weak self] in self?.reviewChanges() }
        detail.onContextChange = { [weak self] value in self?.newContext = value }
        detail.onSelectConversation = { [weak self] id in _ = self?.select(id) }
        detail.onConfigureComposer = { [weak self] composer, c, token in self?.bindComposer(composer, conversation: c, token: token) }
        detail.onComposerPresentationChange={[weak self] composer,host in self?.onComposerPresentationChange?(composer,host)}
        inspector.notice = { [weak self] text in self?.notice(text) }
    }
    func refresh() {
        guard !updating else { return }; updating = true; defer { updating = false }
        // Settings may restore or permanently remove a chat while its archive toast and native Undo action survive.
        // A replacement object with the same ID is a different chat; neither path may revive the old object (b030).
        let invalid = Set(undoTokens.filter { token in
            guard let c = store.conversation(token.id) else { return true }
            return c !== token.original || !c.archived
        }.map(\.id))
        if !undoingArchive, !invalid.isEmpty { invalidateUndo(for: invalid) }
        if let id = sidebarModel.current, store.conversation(id)?.archived != false, canHandoff {
            let next = store.conversations.filter { !$0.archived }.max(by: { $0.updated < $1.updated })?.id
            sidebarModel.select(next)
        }
        sidebarModel.refresh(); refreshDetail()
    }
    private func refreshDetail() {
        // The inactive mode has no native lease to refresh. Its next admission refreshes the selected
        // conversation explicitly; streaming deltas only invalidate its optional motion resources.
        if NormieIdleMotionCapture.orreryEnabled,!isNormie {return}
        let probe = ModeSignposts.current
        let cold = probe != nil && !detail.isViewLoaded
        probe?.record("NormieDetailRefresh", .begin, detail: cold ? "cold; includes first loadView if show loads it" : "loaded")
        defer { probe?.record("NormieDetailRefresh", .end) }
        if sidebar.account != account { sidebar.account = account }
        if composingNew { detail.showDraft(newContext); inspector.show(nil) }
        else { detail.show(selectedConversation); inspector.show(selectedConversation) }
    }
    @discardableResult func select(_ id: String) -> Bool {
        guard canHandoff, store.conversation(id)?.archived == false else { return false }
        sidebarModel.select(id); return true
    }
    /// The window's New Chat context before the first New Chat (the product's demo window: "spw").
    func useNewChatContext(_ context: NormieNewChatContext) {
        guard context != newContext else { return }
        newContext = context; if composingNew { refreshDetail() }
    }
    private func showDevices(from view: NSView, rect: CGRect) {
        devicePicker.show(from: view, rect: rect) { [self] done in detail.newChatView.makeDeviceCards(done: done) }
    }
    @discardableResult func newChat(projectID: String? = nil) -> Bool {
        guard !modeContentEpochFrozen || transcriptSessions.modeContentNativeAdmissionAllowed else {return false}
        guard canHandoff else { return false }
        if let p = store.project(projectID) {
            guard store.device(p.deviceID)?.online == true else { notice("This device is offline."); return false }
            newContext = NormieNewChatContext(projectID: p.id, deviceID: p.deviceID)
        } else if store.device(newContext.deviceID)?.online != true, let d = store.devices.first(where: \.online) {
            newContext = NormieNewChatContext(projectID: nil, deviceID: d.id)
        }
        selecting = true; sidebarModel.select(nil); selecting = false
        // The product's New Chat puts the keyboard in its composer.
        composingNew = true; refreshDetail(); detail.composer?.focus(); onSelection?(nil)
        if let composer = detail.composer {
            devicePicker.scheduleParityOpen(from: composer.contextRow) { [weak self, weak composer] in
                guard self?.isNormie == true, self?.composingNew == true else { return }
                composer?.contextRow.deviceChip.run?()
            }
        }
        return true
    }
    @discardableResult func cancelNewChat(discard: Bool = false) -> Bool {
        guard canHandoff else { return false }
        if discard, let token = detail.draftToken, !sessions.discardDraft(token) { return false }
        if let id = store.conversations.filter({ !$0.archived }).max(by: { $0.updated < $1.updated })?.id { return select(id) }
        composingNew = false; detail.show(nil); return true
    }
    private func bindComposer(_ composer: NativeComposer, conversation c: Conversation?, token: NativeComposerSessions.DraftToken?) {
        let id = ObjectIdentifier(composer)
        // Existing scene callbacks remain owned by that scene. Host can explicitly configure the shared session.
        if composer.onSubmit == nil || ownedSubmit.contains(id) {
            ownedSubmit.insert(id)
            composer.onSubmit = { [weak self, weak composer] request in
                guard let self, let composer else { return }; self.submit(request, composer: composer, token: token)
            }
        }
        if let c, actions.interrupt != nil {
            ownedStop.insert(id)
            composer.onStopRequest = { [weak self, weak c] request, done in
                guard let self, let c, self.store.conversation(c.id) === c, let interrupt = self.actions.interrupt else {
                    done(.failed("The stop target is no longer owned by this window.")); return
                }
                interrupt(c, request, done)
            }
        }
        if let c, composer.onRefreshHistory == nil || ownedRefresh.contains(id) {
            ownedRefresh.insert(id)
            composer.onRefreshHistory = actions.refreshHistory == nil ? nil : { [weak self, weak c] in
                guard let self, let c, self.store.conversation(c.id) === c else { return }
                self.actions.refreshHistory?(c)
            }
        }
        if composer.onStop == nil, let c, actions.stop != nil || !store.usesLiveCore {
            composer.onStop = { [weak self, weak composer] in
                guard let self else { return }
                if let stop = self.actions.stop { stop(c) }
                else { c.running = false; c.stopping = false; c.lastTurnInterrupted = true; c.stops += 1; self.store.changed(c); composer?.completeStopRequest() }
            }
        }
        if c == nil || composer.onContext == nil || ownedContext.contains(id) {
            ownedContext.insert(id)
            composer.onContext = { [weak self, weak composer] in
                guard let self, let composer else { return }
                if composer.identity == nil { self.detail.newChatView.makeProjectMenu().popUp(positioning: nil, at: .zero, in: composer.contextButton) }
                else { self.inspector.showStatus(); self.requestInspector(shown: true) }
            }
        }
        if c == nil {
            composer.contextRow.onProject = { [weak self] view, rect in
                self?.detail.newChatView.makeProjectMenu().popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY + 2), in: view)
            }
            composer.contextRow.onDevice = { [weak self] view, rect in self?.showDevices(from: view, rect: rect) }
        } else { composer.contextRow.onProject = nil; composer.contextRow.onDevice = nil }
        actions.configureComposer?(composer, c)
        if !store.usesLiveCore,c?.isLiveConversation != true{_ = composer.enableVoiceDemo()}
    }
    private func submit(_ request: NativeComposerSubmission, composer: NativeComposer, token: NativeComposerSessions.DraftToken?) {
        guard !delivered.contains(request.id) else { return }
        let c: Conversation
        if let identity = request.identity, let existing = store.conversation(identity), !existing.archived { c = existing }
        else {
            guard request.identity == nil, let token, sessions.isCurrentDraft(token), composingNew,
                  store.device(newContext.deviceID)?.online == true else {
                composer.completeSubmission(request.id, outcome: .failed("The draft context is no longer current.")); return
            }
            let requestedContext = newContext
            let created: Conversation?
            if let factory = actions.create { created = factory(requestedContext, request) }
            else if !store.usesLiveCore {
                let title = request.text.split(separator: "\n").first.map(String.init) ?? "New Chat"
                created = Conversation(id: "normie-"+UUID().uuidString, title: String(title.prefix(80)))
            } else { created = nil }
            guard composingNew, newContext == requestedContext, sessions.isCurrentDraft(token), let created, !created.archived else {
                composer.completeSubmission(request.id, outcome: .failed("New Chat could not be created in the current draft context.")); return
            }
            created.projectID = requestedContext.projectID; created.deviceID = requestedContext.deviceID; created.updated = .now
            guard sessions.promoteDraft(token, to: created, store: store) === composer else {
                composer.completeSubmission(request.id, outcome: .failed("The draft was already promoted or cancelled.")); return
            }
            c = created; store.add(c); composingNew = false; sidebarModel.select(c.id)
        }
        guard !store.isOffline(c) else { composer.completeSubmission(request.id, outcome: .failed("This device is offline. Your draft is kept.")); return }
        delivered.insert(request.id)
        if let handler = actions.submit {
            handler(c, request) { [weak self, weak composer] outcome in
                guard let composer, composer.completeSubmission(request.id, outcome: outcome) else { return }
                self?.refresh()
            }
        } else if !store.usesLiveCore {
            c.items.append(TranscriptItem(id: request.id.uuidString, turnID: "normie-prototype", kind: .user, text: request.text))
            c.updated = .now; store.changed(c); composer.completeSubmission(request.id, outcome: .accepted)
        } else { composer.completeSubmission(request.id, outcome: .failed("Sending is not connected to Core.")) }
    }
    @discardableResult func undoArchive() -> Bool {
        guard canHandoff, !undoingArchive else { return false }
        undoingArchive = true
        defer { undoingArchive = false; refresh() }
        let result = sidebarModel.undoArchive()
        if result {
            if let token = undoTokens.popLast() { token.manager?.removeAllActions(withTarget: token) }
            detail.dismissArchiveNotice()
        }
        return result
    }
    func invalidateUndo(for ids: Set<String>) {
        let dismissToast = undoTokens.last.map { ids.contains($0.id) } ?? false
        sidebarModel.invalidateUndo(for: ids)
        for token in undoTokens where ids.contains(token.id) { token.manager?.removeAllActions(withTarget: token) }
        undoTokens.removeAll { ids.contains($0.id) }
        if dismissToast { detail.dismissArchiveNotice() }
    }
    @objc func undo(_ sender: Any?) { _ = undoArchive() }
    func notice(_ message: String) { detail.showNotice(message, undo: false); onNotice?(message) }
    func reviewChanges() {
        inspector.show(selectedConversation); inspector.showChanges(); requestInspector(shown: true)
    }
    func requestInspector(shown: Bool) {
        guard !shown || isNormie else { return }
        if shown { inspector.loadViewIfNeeded() }
        inspectorVisible = shown
        if let onInspectorRequest { onInspectorRequest(shown) }
        else { defaultSplit?.splitViewItems.last?.isCollapsed = !shown }
    }
    private func withdrawRecoveryBindings() {
        guard let composer = detail.composer else { return }
        let id = ObjectIdentifier(composer)
        if ownedStop.remove(id) != nil { composer.onStopRequest = nil }
        if ownedRefresh.remove(id) != nil { composer.onRefreshHistory = nil }
    }
    func composerForHandoff() -> NativeComposer? { withdrawRecoveryBindings(); return detail.composerForHandoff() }
    /// These phases are called only with an opaque source picture and an explicit native mount permit.
    /// Keep the model selection independent of the editor/inspector's expensive native work.
    func prepareModeContentSelection(_ id:String,draft:Bool,context:NormieNewChatContext) {
        isNormie=true;sidebarVisible=true
        selecting=true;defer {selecting=false}
        composingNew=draft
        if draft {newContext=context;sidebarModel.select(nil)} else {sidebarModel.select(id)}
    }
    func prepareModeContentEditor() {
        if composingNew {detail.showDraft(newContext)} else {detail.show(selectedConversation)}
        detail.remountComposer()
    }
    func prepareModeContentChrome() {
        sidebarModel.refresh()
        if sidebar.account != account {sidebar.account=account}
        inspector.show(composingNew ? nil:selectedConversation)
    }
    func remountComposer() { detail.remountComposer() }
    func setTranscriptPresentationActive(_ active: Bool) { detail.setTranscriptPresentationActive(active) }
    func prepareForSnapshot() {
        if isViewLoaded { view.layoutSubtreeIfNeeded() }
        sidebar.view.layoutSubtreeIfNeeded(); detail.view.layoutSubtreeIfNeeded(); inspector.view.layoutSubtreeIfNeeded()
        detail.prepareTranscriptSnapshots()
        detail.composer?.layoutSubtreeIfNeeded(); if isViewLoaded { view.displayIfNeeded() }
    }
    func snapshot(scale: CGFloat) -> CGImage { prepareForSnapshot(); return NativeViewBitmap.capture(view, scale: scale) }
    func snapshot(of host: NSView, scale: CGFloat) -> CGImage { prepareForSnapshot(); host.layoutSubtreeIfNeeded(); return NativeViewBitmap.capture(host, scale: scale) }
    var menuContext: NormieMenuContext {
        let c = selectedConversation
        var supported: Set<NormieCommand> = [.newChat, .search, .sidebar, .inspector, .terminal, .focus, .attach, .latest, .rename, .pin, .unread, .archive, .member]
        if actions.stop != nil || detail.composer?.onStop != nil { supported.insert(.stop) }
        if store.usesLiveCore {
            if actions.pin == nil { supported.remove(.pin) }
            if actions.archive == nil { supported.remove(.archive) }
            if actions.rename == nil { supported.remove(.rename) }
        }
        if actions.command != nil { supported.formUnion(actions.externalCommands) }
        return NormieMenuContext(hasConversation: c != nil, composingNew: composingNew, running: c?.running ?? false,
            stopping: c?.stopping ?? false, online: c.map { !store.isOffline($0) } ?? (store.device(newContext.deviceID)?.online ?? false),
            pinned: c?.pinned ?? false, collapsed: isCollapsed, sidebarVisible: sidebarVisible, inspectorVisible: inspectorVisible, terminalShown:isTerminalShown, normie: isNormie,
            memberCount: availableMembers.count, canAttach: detail.composer?.canChangeAttachments ?? false, supported: supported)
    }
    func perform(_ command: NormieCommand, tag: Int = 0) {
        if modeContentEpochFrozen,[NormieCommand.newChat,.focus,.attach,.inspector,.terminal].contains(command) {return}
        guard menuContext.enabled(command, tag: tag) else { return }
        if actions.externalCommands.contains(command), let handler = actions.command { handler(command, tag); return }
        let c = selectedConversation
        switch command {
        case .newChat: _ = newChat()
        case .search: if onModeSearchFocus?() != true {sidebar.focusSearch()}
        case .sidebar:
            defaultSplit?.toggleSidebar(nil); sidebarVisible.toggle()
        case .inspector:
            requestInspector(shown: !inspectorVisible)
        case .terminal:setTerminalShown(!isTerminalShown)
        case .focus: detail.composer?.focus()
        case .attach: detail.composer?.chooseAttachments()
        case .latest: if let c { detail.transcripts[c.id]?.scrollToEnd() }
        case .stop: _ = detail.composer?.requestStop()
        case .rename: if let c { sidebarModel.beginRename(c.id) }
        case .pin: if let c { sidebarModel.pin(c.id) }
        case .unread: if let c { c.unread = true; store.changed(c) }
        case .archive: if let c { sidebarModel.archive(c.id) }
        case .member: if availableMembers.indices.contains(tag) { _ = select(availableMembers[tag]) }
        default: actions.command?(command, tag)
        }
    }
    private var availableMembers: [String] { memberOrder.filter { store.conversation($0)?.archived == false } }
    func dispose() {
        onInspectorRequest = nil
        sidebarModel.cancelHistoryPaging()
        if let observation { store.removeObserver(observation); self.observation = nil }
        for token in undoTokens { token.manager?.removeAllActions(withTarget: token) }; undoTokens = []
        withdrawRecoveryBindings()
        detail.disposeTerminal();detail.disposeTranscripts();detail.newChatView.invalidateWorkspaceRequests(); _ = detail.composerForHandoff()
    }
}
