import AppKit
import QuartzCore

extension AutoScene {
    // MARK: New Chat (f047, f048, f078; docs/reference/NEWCHAT-SPEC-26102909.md)

    var composingNew: Bool { scheme.draft }
    /// New Chat's words or attachments not yet sent (WindowCoordinator.hasUnboundDraft): the window keeps them.
    var hasUnboundDraft: Bool {
        guard let t = draftToken, composers.isCurrentDraft(t) else { return false }
        let c = composers.draft().composer
        return !c.text.isEmpty || !c.attachments.isEmpty
    }
    private func requestDraftHeaderWarm() {
        draftHeaderWarmTask?.cancel()
        guard scheme.draft else {return}
        let task=DispatchWorkItem { [weak self] in
            guard let self,self.scheme.draft else {return}
            self.draftHeaderWarmTask=nil
            self.prewarmActivity()
        }
        draftHeaderWarmTask=task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:task)
    }
    func warmNewChatIsland() {
        guard !restOnSnapshot,let rect=layout.draftColumn else {return}
        let island:HeaderIsland
        if let ready=spareNewChatIsland {island=ready}
        else {
            let work=M10ColumnWorkTrace.scope("scene.warmNewChatIsland");defer{work.end()}
            island=HeaderIsland();island.isHidden=true;nativePlane.addSubview(island);spareNewChatIsland=island
        }
        let title=draftComposer?.text.split(separator:"\n",omittingEmptySubsequences:true).first.map {String($0.prefix(60))} ?? "New Chat"
        spareNewChatIdentity.title=title
        spareNewChatIdentity.identityIndex=store.nextIdentity()
        island.motionProfile=profile;island.motionExposure=exposure
        let config=HeaderIslandConfiguration.conversation(spareNewChatIdentity,variant:.full,columnWidth:rect.width,
            band:HeaderIslandVariant.band(bleedTop:52),reduceMotion:Motion.reduce,ambient:ambient,
            isKeyWindow:sceneView.window?.isKeyWindow ?? true,scale:scale)
        if island.configuration != config {
            island.configure(config)
            if let seed=draftColumn.map({$0.island.frame.minY+44}) {
                _=island.beginPromotion(seedCenterY:seed)
                island.endPromotion()
            }
        }
    }

    /// ⌘N in Auto: the draft comes in as the full column at the right; every member's column turns brief, the ones that
    /// no longer fit park right of me. Already open, it only takes the focus again.
    func newChat() {
        guard scheme.mode == .auto else { refuseNewChat(); return }
        if scheme.draft { draftComposer?.focus(); return }
        dismissPeek()
        var next = scheme; next.draft = true
        transition(to: members, current: current, scheme: next, spring: Tuning.shared.autoSpring, reason: "new-chat")
        guard let column = layout.draftColumn, let bar = layout.draftBar else { return }
        let (composer, token) = composers.draft()
        draftToken = token
        if observedDraftComposer !== composer {
            let previous=composer.onChange
            composer.onChange={ [weak self] text in previous?(text);self?.requestDraftHeaderWarm() }
            observedDraftComposer=composer
        }
        composer.sendShortcut = Self.sendShortcut
        composer.onCancel = { [weak self] in self?.cancelNewChat() }
        composer.onSubmit = { [weak self, weak composer] request in
            guard let self, let composer else { return }
            if !self.sendNewChat(request) { composer.completeSubmission(request.id, outcome: .failed("New Chat could not start the conversation.")) }
        }
        let d = draftColumn ?? DraftColumn(placeholder: draftPlaceholder, store: store, scale: scale)
        draftColumn = d
        d.contextRow.context = draftContext
        d.contextRow.onChange = { [weak self] in self?.draftContext = $0 }
        d.onClose = { [weak self] in self?.cancelNewChat() }
        if d.superview == nil { nativePlane.addSubview(d) }
        d.lay(column)
        d.enter(windowWidth: size.width, now: CACurrentMediaTime())
        dock.showDraftBar(composer, at: bar)
        composer.focus()
        runClock(until: max(ends, d.settles))
    }

    /// A switch closes the draft without a transition of its own: the switch's carries the arrangement back.
    func closeDraftForSwitch() {
        scheme.draft = false
        dock.hideDraftBar()
        draftComposer?.removeFromSuperview()
        draftColumn?.leave(windowWidth: size.width, now: CACurrentMediaTime())
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="closeDraftForSwitch"
    }

    var draftComposer: NativeComposer? { draftToken.flatMap { composers.isCurrentDraft($0) ? composers.draft().composer : nil } }

    /// Esc (not composing marked text) or the close button: the draft goes back out to the right, the members come
    /// back as they were; its words, project and device stay for the next time.
    func cancelNewChat() {
        M10ColumnWorkTrace.beginWindow("newchat-cancel")
        let work=M10ColumnWorkTrace.scope("scene.cancelNewChat");defer{work.end()}
        guard scheme.draft else { return }
        var next = scheme; next.draft = false
        dock.hideDraftBar()
        draftComposer?.removeFromSuperview()
        draftColumn?.leave(windowWidth: size.width, now: CACurrentMediaTime())
        transition(to: members, current: current, scheme: next, spring: Tuning.shared.autoSpring, reason: "new-chat-cancel")
        runClock(until: max(ends, draftColumn?.settles ?? 0))
        sceneView.window?.makeFirstResponder(nil)
        composers.existingComposer(for: current)?.focus()
    }

    /// The first send (f048): a real conversation in the draft's slot, still full, with the same editor; the parked
    /// orbs stay parked, nothing else moves. The draft column goes at once; the conversation's column comes in where it
    /// was.
    private func sendNewChat(_ request: NativeComposerSubmission) -> Bool {
        M10ColumnWorkTrace.beginWindow("first-send")
        let work=M10ColumnWorkTrace.scope("scene.firstSend");defer{work.end()}
        // Not on a device that went offline: the draft stays, nothing is made (WindowCoordinator; organic audit B19).
        guard store.device(draftContext.deviceID)?.online ?? true else { return false }
        let create=M10ColumnWorkTrace.scope("scene.firstSend.create")
        guard scheme.draft, let token = draftToken, let c = onCreate?(request.text, draftContext) else {create.end();return false}
        create.end()
        let promotion=M10ColumnWorkTrace.scope("scene.firstSend.bindComposer")
        guard let composer = composers.promoteDraft(token, to: c, store: store) else {promotion.end();return false}
        draftToken = nil
        composer.onCancel = nil
        composer.onSubmit = nil
        _ = self.composer(for: c)
        promotion.end()
        let draftBar=M10ColumnWorkTrace.scope("scene.firstSend.adoptBar")
        var next = scheme
        next.draft = false
        // Freeze the parked orbs (OrganicDockBridge.sendNewChat: model.parked = ids[columns..].prefix(leading)).
        next.parked = Array(order.dropFirst(layout.columns.count).prefix(layout.leading))
        joining = c
        defer { joining = nil }
        let joined = members + [c]
        let (l, o) = arrange(joined, current: c.id, scheme: next)
        dock.ensureItems(for: joined, layout: l, order: o)
        dock.adoptDraftBar(as: c.id)
        draftBar.end()
        // Where the seed's planet is, for the header to rise from (header-local: the draft column starts at y 0).
        let seedCenterY = draftColumn.map { $0.island.frame.minY + 44 }
        // The seed stays 50 ms more: the rising header's glass takes a frame or two to draw, and two blank frames
        // showed between them (recording, 10-29). They overlap where the seed is.
        if let d = draftColumn { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { d.removeFromSuperview() } }
        draftColumn = nil
        committingDraftComposer=(c.id,composer)
        defer {committingDraftComposer=nil}
        transition(to: joined, current: c.id, scheme: next, spring: Tuning.shared.autoSpring, reason: "new-chat-send")
        if let y = seedCenterY, let column = nodes[c.id] {
            let header=M10ColumnWorkTrace.scope("scene.firstSend.promoteHeader")
            column.beginPromotion(seedCenterY: y, now: now())
            _ = column.promotionFrame(at: now(), x: column.rect.sample(0).rect.minX, width: column.rect.target.width)
            runClock(until: max(ends, now() + 1.25))
            header.end()
        }
        // The full visual handoff, including the seed's first promotion pose and retained editor, is submitted
        // in this input callback. Publish/send in a separate bounded turn; neither plan nor animation start waits
        // for store observers or a synchronous mock completion that clears and measures the editor again.
        CATransaction.flush()
        let store=self.store,send=onSubmit
        DispatchQueue.main.async { [weak composer] in
            let publication=M10ColumnWorkTrace.scope("scene.firstSend.publish");defer{publication.end()}
            if !store.conversations.contains(where:{$0.id==c.id}) {store.add(c)}
            if let send {
                _=send(c,request) { [weak composer] outcome in composer?.completeSubmission(request.id,outcome:outcome) }
            } else {composer?.completeSubmission(request.id,outcome:.failed("Nothing can send yet."))}
        }
        composer.focus()
        return true
    }

    /// me waits on the divider while the confirmation asks (280 pt, anchored at the divider).
    func askCompare(at i: Int) {
        guard let capsule = dock.capsule, dock.dividers.indices.contains(i) else { return }
        compareAsk = i
        dock.setMeDivider(dock.dividers[i])
        let x = dock.dividers[i]
        compareSheet.present(anchor: CGRect(x: x - 1, y: capsule.minY + 7, width: 2, height: capsule.height - 14), in: overlayPlane,
                             neverAsk: UserDefaults.standard.bool(forKey: "compare.neverAsk"))
    }

    func startCompare(at i: Int) {
        guard scheme.split.indices.contains(i + 1), dock.dividers.indices.contains(i) else { return }
        compare = (scheme.split[i], scheme.split[i + 1])
        compareAsk = nil
        dock.setMeDivider(dock.dividers[i])
        runClock(until: dock.meSettles)
    }

    /// For demos: what Return in the confirmation does.
    func confirmCompare() { if let i = compareAsk { compareSheet.dismiss(); startCompare(at: i) } }
    var isComparing: Bool { compare != nil }
    var isAskingCompare: Bool { compareAsk != nil }

    /// A request copied for the other side of a Compare: same words, settings and files; that side's identity and turn.
    static func mirror(_ r: NativeComposerSubmission, to other: Conversation) -> NativeComposerSubmission {
        let action: NativeComposerAction = other.running ? (r.action == .queue ? .queue : .steer) : .send
        return NativeComposerSubmission(id: UUID(), identity: other.id, action: action, text: r.text, attachments: r.attachments,
                                        settings: r.settings, access: r.access, waitingForTurnID: other.running ? other.activeTurnID : nil)
    }

    /// The other half of a Compare pair, if `id` is in one.
    func comparePartner(of id: String) -> Conversation? {
        guard let pair = compare, scheme.mode == .focused, pair.left == id || pair.right == id else { return nil }
        return conversation(pair.left == id ? pair.right : pair.left)
    }

    /// ⌘N in Focused or Split (f049): no draft; the capsule shakes its head (not under Reduce Motion) and VoiceOver hears why.
    func refuseNewChat() {
        if !Motion.reduce { dock.refuse(); runClock(until: now() + 0.3) }
        if let window = sceneView.window {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: "Leave Focused to start a new chat.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
