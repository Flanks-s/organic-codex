import AppKit

/// One window (product OrganicWindowController, f002): its own working set, scene, Normie workbench and composer
/// sessions, over the app's one store. The app keeps a list of them; a conversation and its editor can move between
/// them.
@MainActor final class OrganicWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let scene: AutoScene
    var browserOwner: BrowserOrbWindowOwner?
    var browserApp: AppController? { app }
    var browserCanPresent: Bool { !isClosed && collapsed == nil }
    let shell: WindowShell
    let workbench: NormieWorkbench
    let transcriptSessions: NativeTranscriptSessions
    let root: RootView
    let actions = NormieActions()
    private weak var app: AppController?
    private var workbenchDisposed = false
    /// Retire source editor callbacks before a target installs its own. Final close must not withdraw the moved
    /// editor's target bindings through Normie's retained reference to that same composer.
    func prepareConversationTransfer(_ id: String, closing: Bool) {
        shell.settlePendingMode()
        if closing { shell.freezeTranscriptSourceForTransfer(); disposeWorkbenchForClose() }
        else if workbench.detail.composer?.identity == id { _ = workbench.composerForHandoff() }
    }
    func disposeWorkbenchForClose() {
        guard !workbenchDisposed else { return }; workbenchDisposed = true
        shell.disposeModePreparation()
        scene.dock.headerOrbDragging?.dispose()
        workbench.dispose()
    }
    /// The resize demo stands in for a person dragging the window's edge: its steps count as a live resize.
    var resizingLive = false
    private var parityScheduled = false

    /// `members`: the working set it opens with (nil: every conversation). `frame`: in screen coordinates.
    init(app: AppController, frame: CGRect, screen: NSScreen, members: [String]?, normie: Bool, o: Options,
         transferredTranscripts: [NativeTranscriptSessions.Session] = []) {
        self.app = app
        let store = app.store
        transcriptSessions = NativeTranscriptSessions(store: store)
        for session in transferredTranscripts { precondition(transcriptSessions.adopt(session), "A new window must adopt the released transcript before constructing hosts") }
        let size = frame.size
        window = ModeContentWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false, screen: screen)
        window.contentMinSize = CGSize(width: 560, height: 520)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Dark mode only for now, like the product (user, 2026-10-28).
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        scene = AutoScene(size: size, store: store, profile: .of(screen), scale: screen.backingScaleFactor, transcriptSessions: transcriptSessions)
        // The product's demo window drafts New Chat in Synthetic preview workspace (WindowModel.newChatProject "spw");
        // Live starts in none (M9: v2 said No Project).
        if !store.usesLiveCore, let p = store.project("spw") { scene.draftContext = NormieNewChatContext(projectID: p.id, deviceID: p.deviceID) }
        scene.blockMain = o.block
        scene.ambient = o.ambient
        root = RootView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        let bare = o.hide.contains("bare")
        if !bare { for v in [scene.sceneView, scene.nativePlane, scene.peekNode.view, scene.dockView, scene.overlayPlane] { v.frame = root.bounds; root.addSubview(v) } }
        // The scene lays its planes out itself when the window resizes.
        root.autoresizesSubviews = false
        // Normie and Organic in one window, sharing the store and the composer sessions (WindowShell).
        actions.externalCommands = Self.windowCommands
        let first = members?.first ?? store.conversations.first?.id
        workbench = NormieWorkbench(store: store, sessions: scene.composers, current: first, actions: actions, transcriptSessions: transcriptSessions)
        workbench.useNewChatContext(scene.draftContext)
        scene.composers.sendShortcut = AutoScene.sendShortcut
        // me is the product's account until Core has one (NormieAccount.prototype); the sidebar's capsule says the same.
        workbench.account = .prototype
        shell = WindowShell(organic: root, scene: scene, workbench: workbench, mode: normie ? .normie : .organic)
        super.init()
        root.owner = self
        window.delegate = self
        actions.command = { [weak self] command, tag in self?.command(command, tag: tag) }
        // me's account menu (OrbMeController.Action): the window's commands, or the workbench's.
        scene.meController.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .newChat: self.command(.newChat, tag: 0)
            case .showSidebar: ModeSignposts.withInput("menu.me.sidebar") { self.command(.sidebar, tag: 0) }
            case .collapse: self.command(.collapse, tag: 0)
            case .fullyFocused: self.command(.fullyFocused, tag: 0)
            case .settings: self.command(.settings, tag: 0)
            case .profile: self.command(.profile, tag: 0)
            case .usage: self.command(.usage, tag: 0)
            case .shortcuts: self.command(.shortcuts, tag: 0)
            case .signOut: self.command(.signOut, tag: 0)
            }
        }
        scene.sunHover?.command = { [weak self] action in
            guard let self, !self.isClosed else { return }
            switch action {
            case .search: self.command(.search, tag: 0)
            case .sidebar: self.command(.sidebar, tag: 0)
            case .profile: self.command(.profile, tag: 0)
            case .settings: self.command(.settings, tag: 0)
            case .shortcuts: self.command(.shortcuts, tag: 0)
            case .collapse: self.command(.collapse, tag: 0)
            case .signOut: self.command(.signOut, tag: 0)
            case .newChat, .conversation: break
            }
        }
        scene.sunHover?.bindAccountUsage(app.observeAccountUsage)
        scene.onStatus = { [weak self] in self?.statusText() ?? "" }
        // Sends and stops go to the app's runtime (mock or live) and finish on their receipts (CORE-M7 App 接线).
        scene.onSubmit = { [weak app] c, request, finish in
            guard let app else { finish(.failed("The app is closing.")); return false }
            return app.runtime.submit(CoreSubmission(request), in: c) { finish(NativeComposerCompletion($0.result)); app.submissionFinished(request.id, $0.result) }
        }
        // Stop goes under the editor's own request UUID and finishes on its receipt (f175); Refresh history only reads (f180).
        let interrupt: (Conversation, UUID, @escaping @MainActor (NativeComposerCompletion) -> Void) -> Void = { [weak app] c, id, finish in
            guard let app else { finish(.failed("The app is closing.")); return }
            app.runtime.interrupt(c, id: id) { finish(NativeComposerCompletion($0.result)) }
        }
        scene.onStopRequest = interrupt
        actions.interrupt = interrupt
        scene.onRefreshHistory = { [weak app] c in app?.runtime.refresh(c) }
        actions.refreshHistory = { [weak app] c in app?.runtime.refresh(c) }
        actions.submit = { [weak app] c, request, finish in
            guard let app else { finish(.failed("The app is closing.")); return }
            _ = app.runtime.submit(CoreSubmission(request), in: c) { finish(NativeComposerCompletion($0.result)); app.submissionFinished(request.id, $0.result) }
        }
        // Normie's first send: titled with its first line, as Organic's (WindowCoordinator; app audit AP13).
        actions.create = { [weak app] context, request in
            let title = request.text.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0.prefix(60)) } ?? "New Chat"
            return app?.runtime.createUnsentConversation(title: title, projectID: context.projectID, deviceID: context.deviceID)
        }
        // Approvals and questions go to the runtime, which lets the turn go on (NormieDetailView → engine.respond; AP01).
        actions.approval = { [weak app] c, approval, action in app?.runtime.respond(approval, in: c, action: action) }
        actions.approvalValue = { [weak app] c, approval, value in app?.runtime.respond(approval, in: c, response: value) }
        actions.answer = { [weak app] c, request, answers in app?.runtime.answer(request, in: c, answers: answers) }
        // Fork from a message: the fork shows in this window unless another already holds it (NormieDetailView.act).
        // Undo on a changes card: the runtime's revert (Live confirms on the window holding it; f091).
        actions.fork = { [weak app, weak self] c, item in
            guard let app, let self, let fork = app.runtime.fork(c, at: item.id) else { return }
            (app.windows.first { $0.scene.members.contains { $0.id == fork.id } } ?? self).reveal(fork.id)
        }
        scene.onForkWhole = { [weak app, weak self] c, _, finish in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, let runtime = app?.runtime else { return }
                let result: Result<Conversation, Error>
                do { result = .success(try await runtime.forkWhole(c)) }
                catch { result = .failure(error) }
                guard !self.isClosed else { return }
                finish(result)
            }
        }
        actions.revertTranscript = { [weak app] c, item in app?.runtime.revert(item, in: c) }
        // Live: what Normie does to a conversation goes to the Core (CORE-M7 App 接线): seen (which reads its history),
        // pin, archive, rename, fork, compact, commit. The mock keeps its local handling.
        if let live = app.live {
            // The sidebar's Show More reads the Core's next history page; the Core keeps the cursor (f015).
            actions.hasMoreHistory = { [weak live] in live?.hasMoreHistory() ?? false }
            actions.loadMoreHistory = { [weak live] finish in
                guard let live else { finish(.failure(CoreWire.failure("The live runtime is unavailable."))); return }
                Task { @MainActor in
                    do { try await live.loadMoreHistory(); finish(.success(())) } catch { finish(.failure(error)) }
                }
            }
            actions.markSeen = { c in live.markSeen(c) }
            actions.pin = { c, on in live.setPinned(c, pinned: on) }
            actions.archive = { c, on in live.setArchived(c, archived: on) }
            actions.rename = { c, title in live.rename(c, title: title) }
            actions.compact = { c in live.compactNow(c) }
            actions.commit = { c, message, review in if review.isCurrent(c) { live.commit(c, message: message) } }
            // What Organic shows is read too; its headers rename through the Core.
            scene.onShown = { c in live.markSeen(c) }
            scene.onRename = { c, title in live.rename(c, title: title) }
            scene.onIdentityChanged = { [store = app.store] c in
                do { try live.presentation.setIdentity(c, symbol: c.identitySymbol, tint: c.identityTint) }
                catch { c.operationError = "Couldn't save this chat's look: \(error.localizedDescription)"; store.changed(c) }
            }
        }
        // The Status inspector's sub-agent rows open their read-only windows (AP23).
        actions.subAgent = { [weak self] c, s in self?.scene.subAgentWindows.present(subagentID: s.id, of: c) }
        actions.referencePreview = { [weak app] target, c in
            await app?.liveArtifacts.referencePreview(target, in: c) ?? .init(state: .unavailable, message: "Preview is unavailable.")
        }
        actions.referenceWeb = { [weak app] url in
            if let open = app?.liveArtifacts.onOpenURL { open(url) } else { NSWorkspace.shared.open(url) }
        }
        // A new draft starts with General ▸ Default access, once per draft editor (AP11).
        actions.configureComposer = { [weak app] composer, c in
            guard c == nil, let app, !OrganicWindow.defaulted.contains(ObjectIdentifier(composer)) else { return }
            OrganicWindow.defaulted.insert(ObjectIdentifier(composer))
            if composer.text.isEmpty { composer.access = app.defaultAccess }
        }
        actions.stop = { [weak app] c in app?.runtime.interrupt(c, id: UUID()) { _ in } }
        // New Chat's first send makes the conversation (titled with its first line), the scene sends it as a member.
        scene.onCreate = { [weak app] text, context in app?.newConversation(titled: text, context: context) }
        scene.onMembersChange = { [weak self] members in self?.strip?.setMembers(members) }
        scene.onCompact = { [weak app] c in app?.runtime.compactNow(c) }
        scene.onLookChanged = { [weak self] in self?.strip?.displayOptionsChanged() }
        // A dock node torn out of this window goes to the app's one tear session (f182).
        scene.onTear = { [weak app, weak self] e in if let app, let self { app.tear(e, from: self) } }
        shell.view.frame = CGRect(origin: .zero, size: size)
        window.contentViewController = shell
        window.setContentSize(size)
        shell.installToolbar(in: window)
        scene.islandActions = actions
        scene.onUndoArchive = { [weak self] in self?.workbench.undoArchive() ?? false }
        if !bare { scene.install(members: members) }
        // Menu commands act on what Organic shows (Split: the segment being typed into), told at rest.
        workbench.memberOrder = scene.order
        // Commands follow the presentation: in Organic the window takes Search, Rename, Customize and Jump to Latest
        // (OWC searchChats, renameChat; app audit AP04, AP05, AP17); the window title follows what shows (AP16).
        shell.onModeChange = { [weak self] mode in
            guard let self else { return }
            self.browserOwner?.modeChanged(mode)
            self.actions.externalCommands = mode == .organic ? Self.windowCommands.union(Self.organicCommands) : Self.windowCommands
            DispatchQueue.main.async { [weak self] in self?.shell.refreshTitle() }
        }
        if !normie { actions.externalCommands = Self.windowCommands.union(Self.organicCommands) }
        reconcileBrowserOrb()
        titleObservation = store.observe { [weak self] c in
            guard let self, c.id == (self.shell.mode == .normie ? self.workbench.selectedConversation?.id : self.scene.focusTarget) else { return }
            self.shell.refreshTitle()
        }
        // Review and the composer's context open the window's inspector, never closing it (app audit AP02).
        workbench.onInspectorRequest = { [weak self] shown in
            guard let self, self.shell.inspectorShown != shown else { return }
            self.shell.toggleInspector()
        }
        // Normie's composer gets the same press-and-hold Send as a full bar (f106; OverlayComposerBinding), one binding per
        // mount, withdrawn when it goes.
        workbench.onComposerPresentationChange = { [weak self] composer, host in
            guard let self else { return }
            self.normieComposerBinding?.disconnect(); self.normieComposerBinding = nil
            guard let composer, let host, host.window != nil else { return }
            self.normieComposerBinding = OverlayComposerBinding(composer: composer, host: host)
        }
        // A conversation lives in one window: picked in this sidebar while another window holds it, that window shows it
        // in front and this one keeps what it showed (WindowCoordinator.show; audit A06).
        workbench.onSelection = { [weak self, weak app] id in
            self?.shell.refreshTitle()
            guard let self, let app, let id, !self.scene.members.contains(where: { $0.id == id }),
                  let owner = app.windows.first(where: { $0 !== self && $0.scene.members.contains(where: { $0.id == id }) }) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.scene.members.contains(where: { $0.id == self.scene.current }) { _ = self.workbench.select(self.scene.current) }
                owner.reveal(id)
            }
        }
        // The sidebar's Customize… (its context menu): the sheet for the chat it was asked on, not the current one.
        workbench.sidebar.onCustomize = { [weak self] c in guard let self else { return }; self.scene.customize(c.id, in: self.workbench.detail.view) }
        M104HeaderOrbDragging.install(in: scene)
        scene.dock.focusTargetProvider = { [weak scene = self.scene] in scene?.focusTarget }
        scene.dock.focusTarget = scene.focusTarget
        scene.onTarget = { [weak self] id in
            guard let self else { return }
            self.scene.dock.focusTarget = id
            guard self.shell.mode == .organic else { return }
            self.workbench.memberOrder = self.scene.order
            _ = self.workbench.select(id)
        }
        // Opened directly in Organic: the dock appears with its bloom (f066).
        if !bare && !normie { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scene.bloomDock() } }
        window.setFrameOrigin(frame.origin)
    }

    func show(focus normie: Bool) {
        guard !isClosed else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(normie ? nil : root)
        watchAmbient()
        shell.startModePreparation()
        shell.prepareNormie()
        workbench.refreshComposerPresentationBinding()
        // Normie opens with its composer focused, as the product's dock does (its 1.5 pt focus ring shows).
        if normie, shell.mode == .normie { DispatchQueue.main.async { [weak self] in self?.workbench.detail.composer?.focus() } }
        scheduleSplitParityState()
    }

    /// Capture-only recipes, scheduled once on the window the user already opened. Main's existing states stay there.
    private func scheduleSplitParityState() {
        let env = ProcessInfo.processInfo.environment
        guard !parityScheduled, app?.windows.first === self,
              let raw = env["PARITY_STATE"], let state = NativeComposerParityState(rawValue: raw) else { return }
        parityScheduled = true
        func interval(_ key: String, fallback: Double) -> Double {
            guard let raw = env[key], let value = Double(raw), value.isFinite else { return fallback }
            return max(0.5, value)
        }
        let delay = interval("PARITY_STATE_DELAY", fallback: 1), gap = interval("PARITY_STATE_STEP", fallback: 1.2)
        for (index, step) in state.steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + gap * Double(index)) { [weak self] in
                guard let self else { return }
                self.applySplitParityStep(step)
                print("PARITY_STATE \(raw) step \(index + 1)/\(state.steps.count) \(step)")
            }
        }
    }

    private func applySplitParityStep(_ step: NativeComposerParityState.Step) {
        let ids = scene.columns.map { $0.conversation.id }
        switch step {
        case .focused:
            shell.setMode(.organic)
            scene.enterFocused(scene.current, reason: "parity-split")
        case .graftNext:
            if let id = scene.order.first(where: { !ids.contains($0) }) { scene.graft(id, at: ids.count, reason: "parity-split") }
        case .select(let index):
            if ids.indices.contains(index) { scene.focusMember(ids[index]) }
        case .remove(let index):
            if ids.indices.contains(index) { scene.ungraft(ids[index], reason: "parity-split") }
        case .dragIdentity(let index):
            guard ids.indices.contains(index), let item = scene.dock.items[ids[index]], item.identityFrame.width > 0 else { return }
            let frame = item.identityFrame, start = CGPoint(x: frame.midX, y: frame.midY)
            // Outside the capsule's 44 pt exit zone, inside the window's 90 pt tear zone.
            let end = CGPoint(x: start.x, y: start.y - 80)
            guard scene.pointerDown(start) else { return }
            scene.pointerDragged(end)
            _ = scene.pointerUp(end)
        case .normie: shell.setMode(.normie)
        case .organic: shell.setMode(.organic)
        }
    }

    func statusText() -> String {
        var s = "Organic Shell v2 · Auto · \(scene.profile.summary) · 曝光 \(scene.exposure.enabled ? "开" : "关") \(Int(scene.exposure.shutter * 360))° · 堵主线程 \(scene.blockMain ? "开" : "关")"
        if let last = scene.lastSwitch {
            s += String(format: " · 上次切换 %.0f ms，%d 段飞行，峰值 %.0f pt/帧，编译 %.1f ms",
                        (last["durationSeconds"] as? Double ?? 0) * 1000, last["flights"] as? Int ?? 0,
                        last["peakStepPtPerFrame"] as? Double ?? 0, last["compileMs"] as? Double ?? 0)
        }
        return s + "    点列或 1–4 切换 · A 自动 · E 曝光 · S 快门 · B 堵主线程"
    }

    func click(_ p: CGPoint) {
        guard !isClosed else { return }
        browserOwner?.prepareForSceneInput()
        if scene.isMe(at: p) { scene.meClicked(); return }
        if scene.isFocused, let i = scene.column(at: p) { scene.focusColumn(i); return }
        if let c = scene.orb(at: p) { scene.land(c.id, reason: "click") }
        else if let i = scene.column(at: p) { scene.switchTo(i, reason: "click") }
    }

    /// Pointing at a brief column prepares its switch, if streaming made the prepared one stale.
    func hover(_ p: CGPoint) {
        guard !isClosed else { return }
        scene.pointer(p)
        if let i = scene.column(at: p), i != scene.fullIndex { scene.prewarm(i) }
    }

    /// Menu commands the window owns rather than the workbench (NormieActions.externalCommands).
    func command(_ command: NormieCommand, tag: Int) {
        browserOwner?.prepareForSceneInput()
        defer { reconcileBrowserOrb() }
        if shell.modeContentInputBlocked,[NormieCommand.newChat,.focus,.attach,.inspector,.terminal,.moveWindow,.mergeWindows].contains(command) {return}
        guard !isClosed else { return }
        switch command {
        // Collapsed, Show Sidebar is the strip's overlay; the window's own mode stays (OWC:80; audit A12).
        case .sidebar:
            ModeSignposts.withInput("menu.sidebar.command") {
                if let strip { strip.toggleOverlay() } else { shell.toggleSidebar(nil) }
            }
        case .fullyFocused: app?.setFullyFocused(!scene.fullyFocused)
        case .inspector: shell.toggleInspector()
        case .split: if shell.mode == .organic { scene.splitWithNext() }
        // The account's other entries open their Settings panes (MenuPopUp; AP07); Sign Out asks there.
        case .profile: app?.settings?.show(pane: "profile")
        case .usage: app?.settings?.show(pane: "usage")
        case .shortcuts: app?.settings?.show(pane: "shortcuts")
        case .signOut: app?.settings?.show(pane: "account")
        case .search:
            // Search shows the sidebar first, then its field (OWC searchChats).
            shell.setMode(.normie)
            DispatchQueue.main.async { [weak self] in self?.workbench.perform(.search) }
        case .rename: scene.beginRename(scene.focusTarget)
        case .customize: scene.customize(scene.focusTarget)
        case .latest: scene.jumpToLatest(scene.focusTarget)
        case .nextPane: scene.focusPane(1)
        case .previousPane: scene.focusPane(-1)
        case .newChat:
            // Organic Auto's New Chat column is M5 (f048, f078); Focused and Split refuse it (f049). Collapsed, the strip
            // has its own draft (COLLAPSE-SPEC §4).
            if let strip { strip.beginNewChat(); return }
            if shell.mode == .normie { workbench.newChat() } else { scene.newChat() }
        case .focused:
            guard shell.mode == .organic else { return }
            if scene.isFocused { scene.leaveFocused(reason: "menu") } else { scene.enterFocused(scene.current, reason: "menu") }
        case .moveWindow:
            // Only from this window in front (a Settings, Tools or sub-agent window may be key; audit A14).
            guard NSApp.keyWindow === window else { NSSound.beep(); return }
            app?.moveToNewWindow(shell.mode == .organic ? scene.focusTarget : workbench.selectedConversation?.id, from: self)
        case .mergeWindows:
            guard NSApp.keyWindow === window else { NSSound.beep(); return }
            app?.mergeWindows(into: self)
        case .collapse: collapseToSide(shell.mode == .organic ? scene.focusTarget : workbench.selectedConversation?.id)
        case .restore: restoreFromSide()
        case .settings: app?.settings?.show()
        case .artifacts, .browser, .appshots:
            // Tools (f155): the app's one window, on the page asked for, for the conversation in front.
            let section: ToolsRootView.Section = command == .artifacts ? .artifacts : command == .browser ? .browser : .capture
            app?.showTools(section, conversation: shell.mode == .organic ? scene.focusTarget : workbench.selectedConversation?.id)
        case .member:
            // ⌘1–9: the nth member in screen order. Organic shows it (a column goes full, an orb lands); Normie selects it.
            shell.selectModeMember(at:tag)
        default: break
        }
    }

    // MARK: Collapse (f050–f053; docs/reference/COLLAPSE-SPEC-26102909.md)

    private struct Collapsed {
        let strip: CollapseStrip
        let frame: NSRect, level: NSWindow.Level, mode: WindowShell.Mode, current: String
        /// It was full screen: the restore goes back to it.
        var fullScreen = false
    }
    private var collapsed: Collapsed?
    private var restoring = false
    /// Full screen first exits; the collapse follows once it has (COLLAPSE-SPEC §1; OWC windowDidExitFullScreen).
    private var collapseAfterFullScreen: String?
    var isCollapsed: Bool { collapsed != nil }
    /// While collapsed: the window's own frame, mode and current to restore to, and what the strip shows (for saving).
    var collapsedState: (frame: NSRect, mode: WindowShell.Mode, current: String, shown: String)? {
        collapsed.map { ($0.frame, $0.mode, $0.current, $0.strip.shown) }
    }
    /// For demos: the strip, while collapsed.
    var strip: CollapseStrip? { collapsed?.strip }

    /// To the screen's right third (at least 320 pt), floating, showing `id`; the window's arrangement is kept to come
    /// back to. Refused (a beep) without a member to show, or when already collapsed.
    func collapseToSide(_ id: String?, fromFullScreen: Bool = false) {
        browserOwner?.retire();browserOwner=nil
        // The draft has no command target (WindowModel commandTarget): nothing to collapse to.
        if shell.mode == .organic, scene.composingNew { NSSound.beep(); return }
        if window.styleMask.contains(.fullScreen), let id, collapsed == nil {
            collapseAfterFullScreen = id
            window.toggleFullScreen(nil)
            return
        }
        guard collapsed == nil, !restoring, transcriptSessions.canHandoff, let id, scene.members.contains(where: { $0.id == id }),
              let screen = NSScreen.screens.max(by: { $0.frame.intersection(window.frame).area < $1.frame.intersection(window.frame).area }) ?? window.screen
        else { NSSound.beep(); return }
        shell.settlePendingMode()
        guard !shell.modeContentInputBlocked else {return}
        shell.flight.cancel()
        let snap = (frame: window.frame, level: window.level, mode: shell.mode, current: scene.current)
        // The real sidebar folds (the window is Organic underneath); a draft and a peek close.
        if shell.mode == .normie { shell.setMode(.organic, animated: false) }
        guard shell.mode == .organic else { return }
        scene.setTranscriptPresentationActive(false)
        scene.dismissPeek()
        let vis = screen.visibleFrame
        let width = min(vis.width, max(320, (vis.width / 3).rounded()))
        let target = NSRect(x: vis.maxX - width, y: vis.minY, width: width, height: vis.height)
        window.contentMinSize = CGSize(width: 320, height: 520)
        window.level = .floating
        // Laid out once at the strip's size, anchored top-trailing while the frame moves.
        let size = window.contentRect(forFrameRect: target).size
        let strip = CollapseStrip(store: scene.store, sessions: scene.composers, members: scene.members, shown: id, scale: screen.backingScaleFactor,
                                  transcriptSessions: transcriptSessions)
        strip.sunHoverBadge = { [weak scene] changed in
            scene?.sunHover?.refreshData(changed: changed)
            return scene?.sunHover?.badge
        }
        strip.frame = CGRect(x: shell.view.bounds.width - size.width, y: 0, width: size.width, height: size.height)
        strip.onRestore = { [weak self] in self?.restoreFromSide() }
        strip.onSelect = { [weak self] id in _ = self?.workbench.select(id) }
        strip.onOpenSubAgent = { [weak self] c, id in self?.scene.subAgentWindows.present(subagentID: id, of: c) }
        // Its header answers as the scene's do: Rename, Customize, panels, events, sub-agents (organic audit B01).
        strip.onTranscriptConfiguration = { [weak self] c, composer in self?.scene.transcriptConfiguration(for: c, composer: composer) ?? .init() }
        strip.onWireIsland = { [weak self, weak strip] island, id in
            self?.scene.wireIsland(island, for: id, sheets: { strip }, reveal: { strip?.revealLatest() })
        }
        strip.onMoreSubAgents = { [weak self, weak strip] c, rows in self?.scene.showSubAgents(c.id, from: rows, upward: true, in: strip) }
        strip.onAccountMenu = { [weak self, weak strip] me in
            guard let self, let strip else { return }
            self.scene.meController.update(self.scene.meModel())
            self.scene.meController.presentAccountMenu(anchor: me, in: strip)
        }
        // New Chat in the strip: the app makes the conversation, the scene takes it into the working set and its sends.
        strip.onCreateChat = { [weak app] text, context in app?.newConversation(titled: text, context: context) }
        strip.newChatContext = scene.draftContext
        strip.onNewChatContext = { [weak self] in self?.scene.draftContext = $0 }
        strip.onSendNew = { [weak self] c, request, finish in self?.scene.onSubmit?(c, request, finish) ?? false }
        strip.onJoin = { [weak self] c in guard let self else { return }; _ = self.scene.composer(for: c); self.scene.admit(c, reason: "collapse-new-chat") }
        collapsed = Collapsed(strip: strip, frame: snap.frame, level: snap.level, mode: snap.mode, current: snap.current, fullScreen: fromFullScreen)
        shell.setCollapsed(strip)
        let reduce = Motion.reduce
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
            window.animator().setFrame(target, display: true)
        }
    }

    /// Back: the window grows to its old frame first (0.36 s), still showing the strip; then the arrangement returns and
    /// the dock appears, in the mode it was in.
    func restoreFromSide() {
        guard let c = collapsed, !restoring, transcriptSessions.canHandoff else { return }
        restoring = true
        window.level = c.level
        let reduce = Motion.reduce
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0 : 0.36
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
            self.window.animator().setFrame(c.frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishRestore(c) }
        })
    }

    private func finishRestore(_ c: Collapsed) {
        restoring = false
        window.contentMinSize = CGSize(width: 720, height: 520)
        c.strip.dispose(); c.strip.removeFromSuperview()
        collapsed = nil
        shell.setCollapsed(nil)
        if let content = window.contentView { scene.resize(to: content.bounds.size, live: false) }
        scene.remountComposers()
        scene.bloomDock()
        if c.mode == .normie { shell.setMode(.normie, animated: false) }
        window.makeFirstResponder(c.mode == .normie ? nil : root)
        if c.fullScreen { window.toggleFullScreen(nil) }
    }

    func key(_ e: NSEvent) -> Bool {
        guard !isClosed else { return false }
        if browserOwner?.full == true,e.keyCode == 53 {browserOwner?.toggleFull();return true}
        browserOwner?.prepareForSceneInput()
        // Space while a dock node is held: Collapse to it (f050; not while typing: the root only sees keys no editor took).
        if e.keyCode == 49, !e.isARepeat, e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, let id = scene.pressedNode {
            scene.cancelDrag(); collapseToSide(id); return true
        }
        // With Settings' "collapse on hover + Space" on, pointing at a bar or orb in Auto is enough (the root only sees
        // Space when no input has the keyboard; OrganicWindowController collapseOnHoverSpace).
        if e.keyCode == 49, !e.isARepeat, e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           UserDefaults.standard.bool(forKey: "settings.collapseOnHoverSpace"), shell.mode == .organic, !scene.isFocused,
           let id = scene.dockNode(at: root.convert(window.mouseLocationOutsideOfEventStream, from: nil)), id != DockNode.meID {
            collapseToSide(id); return true
        }
        // ⇧⌘Return: Focused on the full conversation, and back (MainMenu Focus).
        if e.keyCode == 36, e.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift] {
            if scene.isFocused { scene.leaveFocused(reason: "key") } else { scene.enterFocused(scene.current, reason: "key") }
            return true
        }
        guard let c = e.charactersIgnoringModifiers?.lowercased(), e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch c {
        case "1", "2", "3", "4", "5": scene.switchTo(Int(c)! - 1, reason: "key")
        case "a": app?.toggleDemo()
        case "e": scene.exposure.enabled.toggle()
        case "s": scene.exposure.shutter = scene.exposure.shutter > 0.75 ? 0.5 : 1
        case "b": scene.blockMain.toggle()
        default: return false
        }
        scene.updateStatus()
        return true
    }

    // MARK: Ambient motion (f202) and Reduce Motion (f199)

    private var idle: DispatchWorkItem?
    private var eventMonitor: Any?, reduceObserver: NSObjectProtocol?

    /// Listens for what holds the ambient motion: key, occlusion, miniaturize, and 8 s without input; and for the
    /// system's Reduce Motion.
    func watchAmbient() {
        guard !isClosed else { return }
        guard eventMonitor == nil else { activity(); return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]) { [weak self] e in
            if e.window === self?.window { self?.activity() }
            return e
        }
        reduceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scene.reduceMotionChanged(); self?.strip?.displayOptionsChanged() }
        }
        activity()
    }

    private func activity() {
        lastInput = CACurrentMediaTime()
        updateAmbient()
        scene.updateEditing()
    }

    /// Ambient motion runs while the window is key, visible and used in the last 8 s; idle is measured from the last
    /// input, whatever asks, and its end is scheduled for what is left (OWC updateAmbient; app audit AP22).
    private var lastInput = 0.0
    private func updateAmbient(idle _: Bool = false) {
        browserOwner?.visibilityChanged()
        let left = 8 - (CACurrentMediaTime() - lastInput)
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        let running = visible && window.isKeyWindow && left > 0
        scene.setAmbientRunning(running)
        strip?.setAmbientRunning(running)
        idle?.cancel(); idle = nil
        guard running else { return }
        let w = DispatchWorkItem { [weak self] in self?.updateAmbient() }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.01, execute: w)
    }

    func windowDidBecomeKey(_ n: Notification) {
        // The screen a window was opened for is not always the one it ends up on (a restored frame, a second display).
        scene.backingChanged(window.backingScaleFactor)
        activity(); titleCollapseItem(fullScreen: window.styleMask.contains(.fullScreen))
    }
    /// In full screen the menu says what Collapse will do first (OWC:809-812).
    private func titleCollapseItem(fullScreen: Bool) {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.identifier?.rawValue == "shortcut.collapse" { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        find(NSApp.mainMenu)?.title = fullScreen ? "Exit Full Screen and Collapse" : "Collapse to Side"
    }
    func windowDidEnterFullScreen(_ n: Notification) { titleCollapseItem(fullScreen: true) }
    func windowDidExitFullScreen(_ n: Notification) {
        titleCollapseItem(fullScreen: false)
        guard let id = collapseAfterFullScreen else { return }
        collapseAfterFullScreen = nil
        collapseToSide(id, fromFullScreen: true)
    }
    func windowDidResignKey(_ n: Notification) {
        scene.sunHover?.retire()
        scene.orbTrash.suspend()
        updateAmbient(); scene.updateEditing()
        // A held node goes home when the window loses key, as a header's does. A tear is already between windows.
        if !scene.isTearing { scene.cancelDrag() }
    }
    func windowDidChangeOcclusionState(_ n: Notification) { updateAmbient() }
    func windowDidChangeBackingProperties(_ n: Notification) { scene.backingChanged(window.backingScaleFactor) }
    func windowDidMiniaturize(_ n: Notification) { updateAmbient() }
    func windowDidDeminiaturize(_ n: Notification) { activity() }

    // MARK: NSWindowDelegate

    private(set) var isClosed = false
    func windowWillClose(_ n: Notification) {
        guard !isClosed else { return }
        isClosed = true
        browserOwner?.retire();browserOwner=nil
        scene.orbTrash.close()
        app?.closing(self)
        shell.flight.shutdown()
        shell.clearTranscriptStandIns()
        strip?.dispose()
        scene.disposeTranscriptPresentation()
        disposeWorkbenchForClose()
        transcriptSessions.dispose()
        if let t = titleObservation { scene.store.removeObserver(t); titleObservation = nil }
        normieComposerBinding?.disconnect(); normieComposerBinding = nil
        idle?.cancel(); idle = nil
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        if let r = reduceObserver { NSWorkspace.shared.notificationCenter.removeObserver(r); reduceObserver = nil }
        app?.closed(self)
        window.contentViewController = nil
        window.contentView = nil
        window.delegate = nil
    }

    /// Growing from a torn orb or the menu's Move (f185): the scene lays out once at the end.
    var growing = false
    private(set) var normieComposerBinding: OverlayComposerBinding?
    private var titleObservation: UUID?
    /// Draft editors already given the default access.
    static var defaulted = Set<ObjectIdentifier>()
    /// Menu commands the window always owns, and those it owns in Organic only (NormieActions.externalCommands).
    static let windowCommands: Set<NormieCommand> = [.sidebar, .focused, .newChat, .fullyFocused, .moveWindow, .mergeWindows, .collapse,
        .restore, .settings, .member, .artifacts, .browser, .appshots, .inspector, .split, .profile, .usage, .shortcuts, .signOut]
    static let organicCommands: Set<NormieCommand> = [.search, .rename, .customize, .latest]
    /// Whether conversations may leave or join this window now (OrganicWindowController.allowsConversationWindowTransfer):
    /// not in a draft, collapsed or coming back, growing, full screen, or with a node held.
    var allowsTransfer: Bool {
        shell.allowsModeContentTransfer && !scene.composingNew && !workbench.composingNew && transcriptSessions.canHandoff && !isCollapsed && !restoring && !growing && !window.styleMask.contains(.fullScreen)
            && !scene.isHolding
    }
    /// New Chat's unsent words or attachments, whichever presentation opened it (WindowCoordinator.hasUnboundDraft;
    /// audit A05).
    var hasUnboundDraft: Bool {
        if scene.hasUnboundDraft { return true }
        guard let t = workbench.detail.draftToken, scene.composers.isCurrentDraft(t) else { return false }
        let c = scene.composers.draft().composer
        return !c.text.isEmpty || !c.attachments.isEmpty
    }

    /// Shows `id`, which this window holds, in front: in the strip, in Normie or in the scene.
    func reveal(_ id: String) {
        if let strip { strip.show(id, animated: true) }
        else if shell.mode == .normie { workbench.memberOrder = scene.order; _ = workbench.select(id) }
        else { scene.show(id) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResize(_ n: Notification) {
        guard let content = window.contentView, !growing else { return }
        // Collapsed: the strip keeps its size, anchored top-trailing; the scene under it waits for the restore.
        if let c = collapsed {
            c.strip.setFrameOrigin(CGPoint(x: content.bounds.width - c.strip.frame.width, y: 0))
            return
        }
        let start = CACurrentMediaTime()
        ModeSignposts.measure("OrganicResizeCaptureBakeKeyframes", detail: "inclusive AutoScene.resize; no internal per-column hooks") {
            scene.resize(to: content.bounds.size, live: window.inLiveResize || resizingLive)
        }
        app?.resizeLog.append(["t": start, "width": content.bounds.width, "ms": (CACurrentMediaTime() - start) * 1000, "live": window.inLiveResize || resizingLive])
    }

    func windowDidEndLiveResize(_ n: Notification) {
        guard let content = window.contentView else { return }
        // A person resizing the strip: it follows the window.
        if let c = collapsed { c.strip.frame = content.bounds; return }
        scene.resize(to: content.bounds.size, live: false)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
