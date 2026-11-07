import AppKit
import QuartzCore

extension AutoScene {
    func columnRenderBudget() -> M10ColumnRenderBudget { M10ColumnRenderBudget.inspect(cards, scale: scale, frameInterval:profile.frameInterval) }
    var columnTransitionNodes:[ColumnNode] { columns + leaving.values }
    func columnInkFrames() -> [[[String: Any]]] { (columns + leaving.values).flatMap(\.bakedInkFrames) }
    var presented: Bool { verificationPresented ?? ((transcriptSessions == nil || transcriptsPresented) && (restOnSnapshot || (sceneView.window != nil && !sceneView.isHiddenOrHasHiddenAncestor))) }
    func columnMotionFrames(at mediaTime: Double) -> [M10ColumnFrame] {
        columnMotionPlans.keys.sorted().flatMap { columnMotionPlans[$0]!.frames(at:mediaTime-began) }
    }

    /// The washes go under Increase Contrast or Reduce Transparency (f201); the canvas and washes take the theme's.
    func showWashes() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let themed = Look.themedCanvas
        scene.backgroundColor = themed.canvas.cgColor
        for (w, (color, alpha)) in zip(washes, themed.washes) {
            w.layer.isHidden = Look.plainCanvas
            w.layer.colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
    }

    func admitTranscript(_ column: ColumnNode, frame:CGRect? = nil, visible:Bool=true) {
        guard transcriptSessions != nil, transcriptsPresented else { return }
        defer {onModeEndpointVisibilityChanged?()}
        _ = column.mountNative(in: nativePlane, configuration: transcriptConfiguration(for: column.conversation, composer: composer(for: column.conversation)),frame:frame,visible:visible)
    }
    /// A mode commit mounts only what is full then (commitModeTarget), and a node back from the Dock still has its retired
    /// lease. Such a column has nothing to show when it goes full: its transcript stayed empty until the next mode change,
    /// 14 s in the user's 11-01 recording. Hidden and without layout: whoever needs it next lays it out for its width.
    func admitUnmountedTranscripts(_ columns: [ColumnNode]) {
        for column in columns where !column.ownsNative {
            admitTranscript(column, visible: false)
            column.setNative(visible: false)
        }
    }
    /// Only a semantic mode/Collapse admission can claim the views; background resize/store/prewarm cannot.
    func setTranscriptPresentationActive(_ active: Bool) {
        if !modeContentEpochFrozen {for column in nodes.values {column.island?.setPulsePresentationRetired(!active)}}
        guard let transcriptSessions, !transcriptSessions.isDisposed else { return }
        transcriptsPresented = active
        for p in prewarmed.values { unstage(p) }; prewarmed = [:];lastPrewarmClear="setTranscriptPresentationActive"
        if !active {cancelIdlePreparation();for n in nodes.values {n.unmountNative()};return}
        for (i, n) in columns.enumerated() {
            admitTranscript(n)
            if isMoving { n.render(fullWidth:fullWidth(i,layout),briefWidth:briefWidth(i,layout),force:true) }
            else { n.renderDisplay(fullWidth:fullWidth(i,layout),briefWidth:briefWidth(i,layout),force:true) }
            if !isMoving { n.showRest(full: isFull(n.conversation.id)) }
        }
        requestPrewarm()
    }
    /// A target may have a cold node for a session superseded by release/adopt.
    func discardTranscriptColumn(_ id: String) {
        guard let node = nodes[id], node.native !== transcriptSessions?.existingTranscript(for: id) else { return }
        node.unmountNative(); node.card.removeFromSuperlayer(); node.separator.removeFromSuperlayer()
        nodes[id] = nil; columns.removeAll { $0 === node }; leaving[id] = nil
        for p in prewarmed.values { unstage(p) }; prewarmed = [:];lastPrewarmClear="discardTranscriptColumn"
    }

    func transcriptConfiguration(for c: Conversation, composer: NativeComposer?) -> NativeTranscriptSessions.Configuration {
        var config = NativeTranscriptSessions.Configuration()
        config.decisionCardsInline = false
        config.decisionCardsAtBottom = !c.approvals.isEmpty || c.userInput != nil
        let actions = islandActions
        config.messageDraftTarget = composer
        config.onApproval = actions?.approval.map { act in { [weak c] approval, action in if let c { act(c, approval, action) } } }
        config.onApprovalValue = actions?.approvalValue.map { act in { [weak c] approval, value in if let c { act(c, approval, value) } } }
        config.onAnswer = actions?.answer.map { act in { [weak c] request, answers in if let c { act(c, request, answers) } } }
        config.onForkMessage = actions?.fork.map { act in { [weak c] item in if let c { act(c, item) } } }
        config.onRevertChanges = actions?.revertTranscript.map { act in { [weak c] item in if let c { act(c, item) } } }
        return config
    }

    /// A column's transcript acts as Normie's does, through the window's actions (product TranscriptView.onAction):
    /// approvals and questions go to the runtime under their own request ids (f176), Fork makes the fork and shows it,
    /// Undo on a changes card goes to the runtime's revert, which the window confirms in Live (f091), and Edit stages
    /// the message in the conversation's own editor (f082). Collapse's strip wires its transcripts the same way.
    func wireTranscript(_ t: NativeTranscript, for c: Conversation, composer: NativeComposer?) {
        let actions = islandActions
        t.configurePresentation {
            t.onApproval = actions?.approval.map { act in { [weak c] approval, action in if let c { act(c, approval, action) } } }
            t.onApprovalValue = actions?.approvalValue.map { act in { [weak c] approval, value in if let c { act(c, approval, value) } } }
            t.onAnswer = actions?.answer.map { act in { [weak c] request, answers in if let c { act(c, request, answers) } } }
            t.onForkMessage = actions?.fork.map { act in { [weak c] item in if let c { act(c, item) } } }
            t.onRevertChanges = actions?.revertTranscript.map { act in { [weak c] item in if let c { act(c, item) } } }
            t.messageDraftTarget = composer
        }
    }
    /// Each island's panels bridge, with the conversation it shows: every island of a conversation (a column's, the
    /// Collapse strip's) refreshes when it changes (f077). An island that is gone drops its bridge.
    struct IslandBridge { weak var island: HeaderIsland?; let id: String; let bridge: HeaderIslandInspectorBridge }
    func showArchiveToast(_ title: String) {
        guard sceneView.window != nil else { return }
        archiveToast.onUndo = { [weak self] in _ = self?.onUndoArchive?() }
        let y = size.height - metrics.bottomInset - metrics.barHeight - 4
        archiveToast.present(archivedTitle: title, anchor: CGRect(x: size.width / 2 - 1, y: y, width: 2, height: 1), in: overlayPlane)
    }

    func attachIsland(to column: ColumnNode) {
        let work=M10ColumnWorkTrace.scope("scene.makeIsland",["id":column.conversation.id]);defer{work.end()}
        let island:HeaderIsland
        if joining === column.conversation,let ready=spareNewChatIsland {island=ready;spareNewChatIsland=nil}
        else {island=HeaderIsland()}
        nativePlane.addSubview(island)
        column.attachIsland(island)
        let id = column.conversation.id
        // An event reveals its column: a brief one becomes full, Split's segment takes the focus, and the transcript
        // goes to its latest (ColumnHeader reveal: splitFocus, jumpRequest; organic audit B04).
        wireIsland(island, for: id, sheets: { [weak self] in self?.overlayPlane }, reveal: { [weak self] in
            guard let self else { return }
            if self.scheme.mode == .auto, id != self.current { self.activate(id, reason: "island") }
            else if self.scheme.mode == .focused, self.scheme.split.contains(id), id != self.focusTarget { self.focusMember(id) }
            self.jumpToLatest(id)
        })
        island.actions.expansion = { [weak self, weak column] open, _ in
            // One open island per window; the callback must not retain its owning column.
            guard let self, let column, open else { return }
            for other in self.nodes.values where other !== column { other.island?.setExpanded(false) }
        }
    }

    /// The host's side of a column header island (ColumnHeader's actions), for the scene's columns and Collapse's strip:
    /// its panels (Normie's inspector), events (`reveal` the transcript; a satellite opens its window), the sub-agents
    /// sheet and Customize over `sheets`, Compact, and Rename written back (organic audit B01).
    func wireIsland(_ island: HeaderIsland, for id: String, sheets: @escaping () -> NSView?, reveal: @escaping () -> Void) {
        guard let c = conversation(id) else { return }
        let bridge = HeaderIslandInspectorBridge(conversation: c, store: store, actions: islandActions ?? NormieActions())
        bridges = bridges.filter { $0.value.island != nil }
        bridges[ObjectIdentifier(island)] = IslandBridge(island: island, id: id, bridge: bridge)
        island.panelContent = { [bridge] in bridge.content(for: $0) }
        island.actions.noticeAction = { [weak self] action in
            guard let self,let c=self.conversation(id),!self.store.isOffline(c),!c.archived else{return}
            switch action {
            case .approval(let requestID,let response):
                guard let approval=c.approvals.first(where:{$0.id == requestID}),!approval.submitting,
                      CoreResponseValidation.approval(response,request:approval) == nil else{return}
                self.islandActions?.approvalValue?(c,approval,response)
            case .answer(let requestID,let answers):
                guard let question=c.userInput,question.id == requestID,!question.submitting,
                      CoreResponseValidation.answers(answers,request:question) == nil else{return}
                self.islandActions?.answer?(c,question,answers)
            case .review:reveal()
            }
        }
        island.actions.openSatellite = { [weak self] sub, point in
            guard let self,let c=self.conversation(id) else{return}
            self.subAgentWindows.present(subagentID:sub,of:c,at:point)
        }
        island.actions.route = { [weak self] route in
            guard let self else { return }
            switch route {
            case .satellite(let sub): if let c = self.conversation(id) { self.subAgentWindows.present(subagentID: sub, of: c) }
            case .transcript: reveal()
            case .panel: break
            }
        }
        // Sub-agents (the menu, spawn, the satellites' "…"): the sheet from the island, downward (SubAgentsOpener, f120).
        island.actions.subAgents = { [weak self, weak island] anchor, select in
            guard let self, let from = island?.superview, let host = sheets() else { return }
            self.showSubAgents(id, from: host.convert(anchor, from: from), upward: false, select: select, in: host)
        }
        island.actions.customize = { [weak self] in self?.customize(id, in: sheets()) }
        // The Context panel's Compact Now goes to the runtime (f077).
        island.actions.compact = { [weak self] in if let self, let c = self.conversation(id) { self.onCompact?(c) } }
        island.actions.rename = { [weak self] title in
            guard let self, let c = self.conversation(id) else { return }
            if let rename = self.onRename { rename(c, title) } else { c.title = title; self.store.changed(c) }
        }
    }
    func customize(_ id: String, in host: NSView? = nil) {
        let host = host ?? overlayPlane
        guard let c = conversation(id), host.window != nil else { return }
        customizeSheet.onDone = { [weak self] r in self?.applyCustomization(id, r) }
        customizeSheet.onCancel = {}
        customizeSheet.present(name: c.title, identity: orbIdentity(of: c), level: c.contextUsed, in: host)
    }

    func applyCustomization(_ id: String, _ r: SheetChatCustomization) {
        guard let c = conversation(id) else { return }
        if r.name != c.title { if let onRename { onRename(c, r.name) } else { c.title = r.name } }
        c.identitySymbol = String(describing: r.symbol); c.identityTint = String(describing: r.tint)
        store.changed(c)
        onIdentityChanged?(c)
        dock.refreshOrbs()
    }
    /// For demos: what Done does, and the sheet away.
    func demoCustomize(_ id: String, _ r: SheetChatCustomization) { customizeSheet.dismiss(); applyCustomization(id, r) }

    /// The variant a member's header shows in the arrangement: full or brief in Auto, full in Focused, Split's otherwise.
    func islandVariant(for id: String) -> HeaderIslandVariant {
        if scheme.mode == .focused { return scheme.split.count > 1 ? .split(focused: id == focusTarget) : .full }
        return isFull(id) ? .full : .brief
    }

    /// Every column's island at rest, where its column is; the others hidden.
    func restIslands() {
        for column in columns where !column.isPromoting {
            column.configureIsland(islandVariant(for: column.conversation.id), width: column.rect.target.width)
            column.placeIsland(column.rect.target, shown: true)
        }
        for column in nodes.values where !columns.contains(where: { $0 === column }) { column.island?.isHidden = true }
    }

    /// The overlays follow which composers can be used: one binding per full bar's composer (OVERLAY-M2). `leaving`
    /// only lets go of those no longer full (at a commit, so an open picker closes as its bar goes).
    func bindOverlays(leaving: Bool = false) {
        let full = fullIDs
        for (id, b) in overlays where !full.contains(id) { b.disconnect(); overlays[id] = nil }
        guard !leaving else { return }
        for id in full where overlays[id] == nil {
            guard let composer = composers.existingComposer(for: id) else { continue }
            overlays[id] = OverlayComposerBinding(composer: composer, host: overlayPlane)
        }
    }
    /// The full composer's overlays (for demos and tests).
    func overlay(for id: String) -> OverlayComposerBinding? { overlays[id] }
    /// Settings ▸ General ▸ Follow-up (`settings.followUpDefault`): while a turn runs, a send steers it or queues.
    static var followUpDefault: FollowUp { UserDefaults.standard.string(forKey: "settings.followUpDefault") == "queue" ? .queue : .steer }
    func applyFollowUpDefault() { for c in members { composers.existingComposer(for: c.id)?.followUpDefault = Self.followUpDefault } }
    func applySendShortcut() {
        for c in members { composers.existingComposer(for: c.id)?.sendShortcut = Self.sendShortcut }
        draftComposer?.sendShortcut = Self.sendShortcut
    }

    func composer(for c: Conversation) -> NativeComposer {
        let composer = composers.composer(for: c, store: store)
        if composer.followUpDefault != Self.followUpDefault { composer.followUpDefault = Self.followUpDefault }
        if composer.sendShortcut != Self.sendShortcut { composer.sendShortcut = Self.sendShortcut }
        guard composer.onSubmit == nil else { return composer }
        composer.onSubmit = { [weak self, weak composer, weak c] request in
            guard let self, let c else { return }
            guard let send = self.onSubmit else { composer?.completeSubmission(request.id, outcome: .failed("Nothing can send yet.")); return }
            let taken = send(c, request) { [weak composer] outcome in composer?.completeSubmission(request.id, outcome: outcome) }
            // Compare: the same words go to the other side as its own request (its own UUID and identity, its own turn).
            if taken, let other = self.comparePartner(of: c.id) { _ = send(other, Self.mirror(request, to: other)) { _ in } }
        }
        composer.onStopRequest = { [weak self, weak c] id, finish in
            guard let self, let c, let stop = self.onStopRequest else { finish(.failed("Nothing can stop this yet.")); return }
            stop(c, id, finish)
        }
        composer.onRefreshHistory = { [weak self, weak c] in if let self, let c { self.onRefreshHistory?(c) } }
        return composer
    }

    func remountComposers() { dock.remountComposers() }

    /// An editor arriving from another window (Move, Merge, Tear; WindowCoordinator.commitTransfer): it replaces any this
    /// window made for the conversation meanwhile, and answers to this scene from now on, not its old window's sends,
    /// stops and Compare (audit A01, A02).
    func adoptComposer(_ composer: NativeComposer, for id: String) {
        if let made = composers.existingComposer(for: id), made !== composer {
            _ = composers.release(id)
            made.removeFromSuperview()
        }
        composer.onSubmit = nil; composer.onStop = nil; composer.onStopRequest = nil; composer.onRefreshHistory = nil
        composers.adopt(composer, for: id)
        if let c = conversation(id) { _ = self.composer(for: c) }
        remountComposers()
    }
    func setAmbientRunning(_ on: Bool) {
        guard on != ambientRunning else { return }
        ambientRunning = on
        dock.setAmbientRunning(on)
        for column in nodes.values { column.setAmbientRunning(on) }
    }

    /// The system's Reduce Motion changed: liquids, satellites, dots and hops still (or moving again) at once; flights
    /// and the mode's fades read it when they start.
    /// Settings ▸ Appearance changed (NativeAppearance.apply): the glass takes its style and tint; a transition in
    /// flight ends, every column's captures are made again with the new look, and nothing prepared ahead is kept.
    /// The window now backs at another density (dragged to another screen). The scale was fixed when the window opened:
    /// captures came out at the new density but were cut and placed at the old one, so flying text landed at half size
    /// or doubled, and stayed so until the transition settled (user 10-30, built-in 2× to an external 1×).
    func backingChanged(_ next: CGFloat) {
        guard next > 0, next != scale else { return }
        scale = next
        statusLine.contentsScale = next
        peekNode.scale = next
        if drag != nil { cancelDrag() }
        dismissPeek()
        if isMoving { settle() }
        discardNewChatPreparation()
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="backingChanged"
        for column in nodes.values { column.backingChanged(next) }
        reduceMotionChanged()
    }

    func lookChanged(_ change: NativeAppearance.Change) {
        discardNewChatPreparation()
        dock.setGlass(clear: change.clearGlass, tint: change.glassTint)
        showWashes()
        onLookChanged?()
        guard change.redrawSnapshots else { return }
        if isMoving { settle() }
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="lookChanged"
        for column in nodes.values { column.invalidateCaptures() }
        reduceMotionChanged()
    }

    func reduceMotionChanged() {
        discardNewChatPreparation()
        showWashes()
        dock.refreshOrbs()
        restIslands()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, column) in columns.enumerated() { column.renderDisplay(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout), force: true); column.showRest(full: isFull(column.conversation.id)) }
        CATransaction.commit()
        prewarmActivity()
    }

    /// Shows the full column's native capture in place of the view (or back), to compare the two on screen.
    func showCaptures(_ on: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, c) in columns.enumerated() {
            if on { c.render(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout)) }
            c.restOnSnapshot = on; c.showRest(full: c.isFull)
        }
        CATransaction.commit()
    }

    /// The pointer moved over the scene (nil: it left).
    /// One of the dock's editors has the keyboard in the key window: the dock stays up (B11).
    func updateEditing() {
        let w = sceneView.window
        dock.editing = w?.isKeyWindow == true && (w?.firstResponder as? NSView)?.isDescendant(of: dockView) == true
    }

    func changed(_ c: Conversation) {
        if modeContentEpochFrozen || transcriptSessions?.existingTranscript(for:c.id)?.modeContentIsCatchingUp == true {modeContentEpochPending.insert(c.id);return}
        prewarmActivity() // every delta invalidates unfinished work, including offscreen/nonmember publications
        let work=M10ColumnWorkTrace.scope("scene.changed",["id":c.id,"moving":isMoving]);defer{work.end()}
        if meController.isQuotaPresented { meController.update(meModel()) }
        // Open sub-agent windows follow their parent: its satellites' history as read or streamed (f121, f177).
        subAgentWindows.refresh(parent: c)
        // An open panel follows the conversation; a closed one renders when it opens (content(for:)).
        for entry in bridges.values where entry.id == c.id && entry.island != nil && entry.bridge.isPresented {
            entry.bridge.update(c)
        }
        if c.archived, members.contains(where: { $0.id == c.id }) { remove(c.id, reason: "archived"); return }
        // Undo brings an archived member back, full again (the selection it had).
        if !c.archived, archivedOut.remove(c.id) != nil { archiveToast.dismiss(); admit(c, reason: "unarchived"); return }
        dock.refreshOrbs()
        guard let i = columns.firstIndex(where: { $0.conversation === c }) else { dock.refreshWords(); return }
        // Off screen (Normie shows, or the window is not up yet): the column waits until the scene is seen again. On
        // screen at rest: a streaming answer changes the conversation many times a second, and each render captures the
        // whole column for the next transition; the changes of one tick render once (a recording fell 12 s behind a
        // fast answer while Normie showed and Organic rendered every delta, 10-29).
        if !presented { dirty.insert(c.id); return }
        if !isMoving {
            let column=columns[i]
            let variant=islandVariant(for:c.id)
            let next=c.notices.snapshot(in:c)
            if (variant == .full || variant == .brief), column.island?.configuration?.notices != next {
                column.configureIsland(islandVariant(for:c.id),width:column.rect.target.width)
            }
        }
        if isMoving {
            // Leaving content stays frozen; entering content stays live (reference §B, §D), without scrolling.
            let column = columns[i]
            guard column.form.to > 0.5 else { dirty.insert(c.id); return }
            pendingMovingRenders.insert(c.id)
            guard !movingRenderScheduled else { return }
            movingRenderScheduled=true
            DispatchQueue.main.async { [weak self] in self?.flushMovingRenders() }
            return
        }
        if manualSettle { renderAtRest(i); return }
        pendingRenders.insert(c.id)
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flushRenders() }
    }

    /// Presentation publications coalesce, never semantic Core events/receipts. NativeTranscript's own observer
    /// remains live. A real flight/reflow still gets its current base before the next transaction commits.
    private func flushMovingRenders() {
        movingRenderScheduled=false
        let ids=pendingMovingRenders;pendingMovingRenders=[]
        guard presented else {dirty.formUnion(ids);return}
        for (i,column) in columns.enumerated() where ids.contains(column.conversation.id) {
            guard isMoving else {renderAtRest(i);continue}
            guard column.form.to>0.5 else {dirty.insert(column.conversation.id);continue}
            // The flights on their way were cut for the picture under them. A newer picture hides the sources of flights
            // that never left and leaves holes for the ones still landing: half lines gone, Thinking over Thought for 8s
            // (board 10-31). It takes over at settle.
            if flights[column.conversation.id] != nil {dirty.insert(column.conversation.id);continue}
            CATransaction.begin();CATransaction.setDisableActions(true)
            if column.hasFullReflow {
                column.render(fullWidth:fullWidth(i,layout),briefWidth:briefWidth(i,layout),holdScroll:true)
            } else {
                column.renderDisplay(fullWidth:fullWidth(i,layout),briefWidth:briefWidth(i,layout),holdScroll:true)
            }
            CATransaction.commit()
        }
    }

    /// The columns that changed since the last tick, as they are now; a transition that started meanwhile takes them
    /// at its settle instead.
    private func flushRenders() {
        renderScheduled = false
        let ids = pendingRenders; pendingRenders = []
        guard presented else { dirty.formUnion(ids); return }
        if isMoving { dirty.formUnion(ids); return }
        for (i, column) in columns.enumerated() where ids.contains(column.conversation.id) { renderAtRest(i) }
    }

    private func renderAtRest(_ i: Int) {
        let id = columns[i].conversation.id
        CATransaction.begin(); CATransaction.setDisableActions(true)
        columns[i].renderDisplay(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout))
        columns[i].showRest(full: isFull(id))
        CATransaction.commit()
        columns[i].configureIsland(islandVariant(for: id), width: columns[i].rect.target.width)
        dock.refreshWords()
    }
    func tuningChanged() {
        discardNewChatPreparation()
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="tuningChanged"
        guard !isMoving else { tuningPending = true; return }
        resize(to: size, live: false)
        if !restOnSnapshot { DispatchQueue.main.async { [weak self] in self?.requestPrewarm() } }
    }

    /// Back on screen: what changed while away, rendered now (unless a transition is running; its settle does it).
    func presentDirty() {
        guard !dirty.isEmpty, !isMoving, presented else { return }
        defer {onModeEndpointVisibilityChanged?()}
        let ids = dirty; dirty = []
        for (i, column) in columns.enumerated() where ids.contains(column.conversation.id) { renderAtRest(i) }
    }

    func updateStatus() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        statusLine.string = onStatus?() ?? ""
        CATransaction.commit()
    }

    var lastSwitch: [String: Any]? { switches.last }

    /// The columns' state for receipts and tests: who is in which slot, and whether each card is in the tree and visible.
    var columnState: [[String: Any]] {
        (columns + leaving.values).map { c in
            ["id": c.conversation.id, "slot": columns.firstIndex { $0 === c } ?? -1, "inTree": c.card.superlayer != nil,
             "opacity": c.modelOpacity, "presence": c.presence.to, "form": c.form.to, "card": NSStringFromRect(c.card.frame), "m10BakeMs": c.exposureBakeMs, "m10CopiesMax": c.bakedPeakCopies,
             "m10SourcePixels": c.bakedPresence.reduce(0) { $0 + ($1.ink.contents.map { let image=$0 as! CGImage; return image.width*image.height } ?? 0) }]
        }
    }
}
