import AppKit

/// Collapse (f050–f053; product CollapseView and NativeCollapseDock, docs/reference/COLLAPSE-SPEC-26102909.md): the window
/// as a narrow companion at the screen's right. One conversation shown — its header (collapse variant), transcript,
/// context row and composer — over a rail of the working set's orbs and me's rail. A click on an orb changes only what
/// the strip shows; dragging me to the rail's left end (or swiping left) brings the window back.
@MainActor final class CollapseStrip: NSView {
    override var isFlipped: Bool { true }

    private let store: ConversationStore
    private let sessions: NativeComposerSessions
    private(set) var members: [Conversation]
    private(set) var shown: String
    private let scale: CGFloat
    private let island = HeaderIsland()
    private var washes: [CAGradientLayer] = []
    private var transcripts: [String: NativeTranscript] = [:]
    private let transcriptSessions: NativeTranscriptSessions?
    private var transcriptLeases: [String: NativeTranscriptSessions.Lease] = [:]
    private let context = NativeLabel(labelWithString: "")
    private let composerHost = NSView()
    private let agents = AgentRows()
    /// A sub-agent's dot clicked: its read-only window (the scene's SheetSubAgentWindows).
    var onOpenSubAgent: ((Conversation, String) -> Void)?
    /// The rows' "…": the sub-agents sheet, upward from the rows (strip coordinates).
    var onMoreSubAgents: ((Conversation, CGRect) -> Void)?
    /// me's right-click "Account…": the account menu at me (strip coordinates).
    var onAccountMenu: ((CGRect) -> Void)?
    /// New Chat's first send: the conversation made from its words (the app's), and its send (the runtime's).
    var onCreateChat: ((String, NormieNewChatContext) -> Conversation?)?
    /// New Chat's project and device: the window's (the scene's draftContext), chosen here too.
    var newChatContext = NormieNewChatContext()
    var onNewChatContext: ((NormieNewChatContext) -> Void)?
    private lazy var draftContextRow: DraftContextRow = {
        let row = DraftContextRow(store: store)
        row.onChange = { [weak self] in self?.newChatContext = $0; self?.onNewChatContext?($0) }
        return row
    }()
    var onSendNew: ((Conversation, NativeComposerSubmission, @escaping @MainActor (NativeComposerCompletion) -> Void) -> Bool)?
    /// The new conversation joins the window's working set.
    var onJoin: ((Conversation) -> Void)?
    private var draft: (token: NativeComposerSessions.DraftToken, seed: HeaderIsland)?
    private lazy var draftPlaceholder = Conversation(id: AutoScene.draftID, title: "New Chat")
    var isDrafting: Bool { draft != nil }
    private let railContainer = NSGlassEffectContainerView(), railContent = DockNode.Passage()
    private var orbs: [String: (glass: NSGlassEffectView, decoration: OrbComponent)] = [:]
    private var railScroll: CGFloat = 0
    private let meRail = CALayer(), landing = CALayer()
    private let hint = NativeLabel(labelWithString: "swipe to go back")
    private let me = NSGlassEffectView()
    private var meDecoration: OrbComponent?
    var motionProfile: DisplayProfile?
    var motionEnabled = true
    var motionTime: (() -> Double)?
    var onMotionFrame: ((M10DockFrame) -> Void)?
    private let meMotion = M10DockHistory(), overlayMotion = M10DockHistory()
    private var railMotion: [String: M10DockHistory] = [:]
    private var overlayRise: (spring: Spring, began: Double)?
    private var exposureProfile: DisplayProfile { M10DockMotion.profile(for: self, override: motionProfile) }
    private var usesExposure: Bool { motionEnabled && M10DockMotion.enabled && !Motion.reduce }
    private func motionNow() -> Double { motionTime?() ?? CACurrentMediaTime() }

    /// me's drag along its rail (≤ 0), whether it reached the end, and its spring back.
    private var drag: (start: CGFloat, offset: CGFloat, armed: Bool)?
    private var back = Spring.rest(0), backBegan = 0.0
    private var link: CADisplayLink?
    private var swiping = false
    /// The strip asks for the window back (me reached the end of its rail and was let go).
    var onRestore: (() -> Void)?
    /// What the shown conversation is, for commands (collapsedSelection ?? current).
    var onSelect: ((String) -> Void)?
    /// The header's host actions (AutoScene.wireIsland), for each conversation shown (organic audit B01).
    var onWireIsland: ((HeaderIsland, String) -> Void)? { didSet { if !shown.isEmpty { onWireIsland?(island, shown) } } }
    /// Each transcript the strip makes, once, with the conversation's editor (the scene's wireTranscript).
    var onWireTranscript: ((NativeTranscript, Conversation, NativeComposer) -> Void)? {
        didSet { if transcriptSessions == nil { for t in transcripts.values { onWireTranscript?(t, t.conversation, sessions.composer(for: t.conversation, store: store)) } } }
    }
    var onTranscriptConfiguration: ((Conversation, NativeComposer) -> NativeTranscriptSessions.Configuration)? {
        didSet { if transcriptSessions != nil, !shown.isEmpty { show(shown, animated: false) } }
    }
    /// For demos: the header, and how many sub-agent dots the rows hold.
    var testIsland: HeaderIsland { island }
    var testAgentCount: Int { agents.satellites.count }
    /// An island event reveals the transcript: to its latest.
    func revealLatest() { transcripts[shown]?.scrollToEnd() }

    init(store: ConversationStore, sessions: NativeComposerSessions, members: [Conversation], shown: String, scale: CGFloat,
         transcriptSessions: NativeTranscriptSessions? = nil) {
        self.store = store; self.sessions = sessions; self.members = members; self.shown = shown; self.scale = scale
        self.transcriptSessions = transcriptSessions
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Look.canvas.cgColor
        appearance = NSAppearance(named: .darkAqua)
        // The Canopy canvas, as in Organic (CanopyCanvas shows during Collapse): moss from the top right, teal from the
        // bottom left.
        for (color, alpha) in [(Look.moss, Look.mossAlpha), (Look.teal, Look.tealAlpha)] {
            let wash = CAGradientLayer()
            wash.type = .radial
            wash.colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
            wash.startPoint = CGPoint(x: 0.5, y: 0.5); wash.endPoint = CGPoint(x: 1, y: 1)
            wash.isHidden = Look.plainCanvas
            layer?.addSublayer(wash); washes.append(wash)
        }
        displayOptionsChanged()
        addSubview(island)
        context.font = .systemFont(ofSize: 11, weight: .medium); context.textColor = Look.secondary
        addSubview(context)
        composerHost.wantsLayer = true
        addSubview(composerHost)
        agents.onOpen = { [weak self] id in
            guard let self, let c = self.members.first(where: { $0.id == self.shown }) ?? self.store.conversation(self.shown) else { return }
            self.onOpenSubAgent?(c, id)
        }
        agents.onMore = { [weak self] in
            guard let self, let c = self.members.first(where: { $0.id == self.shown }) ?? self.store.conversation(self.shown) else { return }
            self.onMoreSubAgents?(c, self.agents.frame)
        }
        addSubview(agents)
        railContainer.spacing = 10
        railContainer.contentView = railContent
        addSubview(railContainer)
        meRail.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        landing.backgroundColor = NSColor(white: 1, alpha: 0.5).cgColor
        layer?.addSublayer(meRail); layer?.addSublayer(landing)
        hint.font = .systemFont(ofSize: 13, weight: .medium); hint.textColor = Look.secondary; hint.alignment = .center
        addSubview(hint)
        me.style = .regular
        addSubview(me)
        let decoration = OrbComponent(id: "collapse.me", glassView: me)
        decoration.configure(makeMeConfiguration(store: store, initials: NormieAccount.prototype.initials, drawingSize: 36, backingScale: scale, reduceMotion: Motion.reduce, ambient: true, isKeyWindow: true))
        addSubview(decoration.backView, positioned: .below, relativeTo: me)
        addSubview(decoration.frontView, positioned: .above, relativeTo: me)
        meDecoration = decoration
        observation = store.observe { [weak self] c in self?.storeChanged(c) }
        rebuildOrbs()
        show(shown, animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Out of the strip: the composer goes back to its owner (the scene remounts it), the decorations are released.
    func dispose() {
        for lease in transcriptLeases.values { _ = transcriptSessions?.unmount(lease) }
        transcriptLeases = [:]; transcripts = [:]
        link?.invalidate(); link = nil
        if let o = observation { store.removeObserver(o); observation = nil }
        for o in orbs.values { o.decoration.dispose() }
        meDecoration?.dispose()
        composerHost.subviews.forEach { $0.removeFromSuperview() }
    }

    func setMembers(_ next: [Conversation]) {
        members = next
        if !members.contains(where: { $0.id == shown }), let first = members.first { show(first.id, animated: false) }
        if members.isEmpty { showNothing() }
        rebuildOrbs(); needsLayout = true
    }

    /// No member left (the last one archived): nothing is projected, not the one that went (WindowModel.remove;
    /// organic audit B03).
    private func showNothing() {
        if draft != nil { endDraft(keepWords: true) }
        shown = ""
        island.isHidden = true; agents.isHidden = true; context.isHidden = true
        for (id, t) in transcripts {
            if transcriptSessions != nil { if let lease = transcriptLeases[id] { _ = transcriptSessions?.unmount(lease) } }
            else { t.isHidden = true }
        }
        transcriptLeases = [:]
        composerHost.subviews.forEach { $0.removeFromSuperview() }
    }

    /// The store changed: the shown conversation's header, sub-agents and context, and the rail's badges follow it
    /// (CollapseView observes the same store; organic audit B02).
    private var observation: UUID?
    private func storeChanged(_ c: Conversation) {
        guard members.contains(where: { $0.id == c.id }) else { return }
        configureOrbs()
        guard c.id == shown, draft == nil else { return }
        agents.satellites = c.satellitesRetired ? [] : c.satellites
        needsLayout = true
    }

    /// Ambient motion (key, visible, used lately: the window's), for the rail, me and the header (B17).
    private var ambientRunning = true
    func setAmbientRunning(_ on: Bool) {
        guard on != ambientRunning else { return }
        meMotion.reset(); overlayMotion.reset(); railMotion.values.forEach { $0.reset() }
        ambientRunning = on
        configureOrbs(); configureMe(); needsLayout = true
    }
    private func configureMe() {
        meDecoration?.configure(makeMeConfiguration(store: store, initials: NormieAccount.prototype.initials, drawingSize: 36, backingScale: scale, reduceMotion: Motion.reduce,
                                                    ambient: ambientRunning, isKeyWindow: window?.isKeyWindow ?? true))
    }

    private func rebuildOrbs() {
        let ids = Set(members.map(\.id))
        for (id, o) in orbs where !ids.contains(id) { o.glass.removeFromSuperview(); o.decoration.dispose(); orbs[id] = nil; railMotion[id] = nil }
        for c in members where orbs[c.id] == nil {
            let g = NSGlassEffectView(); g.style = .regular
            railContent.addSubview(g)
            let d = OrbComponent(id: "collapse." + c.id, glassView: g)
            addSubview(d.backView, positioned: .below, relativeTo: railContainer)
            addSubview(d.frontView, positioned: .above, relativeTo: railContainer)
            orbs[c.id] = (g, d); railMotion[c.id] = M10DockHistory()
        }
        configureOrbs()
    }

    /// Satellites stripped; a badge on every orb but the shown one (NativeCollapseDock).
    private func configureOrbs() {
        for c in members {
            guard let o = orbs[c.id] else { continue }
            var cfg = makeOrbConfiguration(c, drawingSize: 36, backingScale: scale, reduceMotion: Motion.reduce, ambient: ambientRunning, isKeyWindow: window?.isKeyWindow ?? true)
            cfg.satellites = []
            if c.id == shown { cfg.badge = nil }
            o.decoration.configure(cfg)
        }
    }

    /// Shows `id` (collapsedSelection): its header, transcript and composer; the window's arrangement does not change.
    func show(_ id: String, animated: Bool) {
        guard let c = members.first(where: { $0.id == id }) ?? store.conversation(id) else { return }
        if draft != nil { endDraft(keepWords: true) }
        island.isHidden = false; agents.isHidden = false; context.isHidden = false
        let previous = transcripts[shown]
        if let previous, previous !== transcripts[id], !previous.canHandoff { return }
        let made = transcripts[id] == nil
        let t = transcriptSessions?.transcript(for: c, store: store) ?? transcripts[id] ?? NativeTranscript(conversation: c, store: store)
        if let owner = transcriptSessions {
            let composer = sessions.composer(for: c, store: store)
            let config = onTranscriptConfiguration?(c, composer) ?? .init()
            guard let lease = owner.mount(c, in: self, configuration: config) else { return }
            transcriptLeases[id] = lease
        }
        let oldID = shown
        shown = id
        if previous == nil || previous !== transcripts[id] { onWireIsland?(island, id) }
        transcripts[id] = t
        if made, transcriptSessions == nil { onWireTranscript?(t, c, sessions.composer(for: c, store: store)) }
        if t.superview == nil { addSubview(t, positioned: .below, relativeTo: island) }
        t.isHidden = false
        if animated, previous !== t, let layer = t.layer {
            // easeOut 0.12 (NativeCollapseDock orb click).
            let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0; a.toValue = 1; a.duration = 0.12
            a.timingFunction = CAMediaTimingFunction(name: .easeOut); layer.add(a, forKey: "collapse.show")
        }
        if previous !== t {
            if let owner = transcriptSessions, let old = transcriptLeases.removeValue(forKey: oldID) { owner.unmount(old) }
            else if transcriptSessions == nil { previous?.isHidden = true }
        }
        let composer = sessions.composer(for: c, store: store)
        composerHost.subviews.filter { $0 !== composer }.forEach { $0.removeFromSuperview() }
        if composer.superview !== composerHost { composer.removeFromSuperview(); composerHost.addSubview(composer) }
        composer.isHidden = false; composer.alphaValue = 1
        agents.satellites = c.satellitesRetired ? [] : c.satellites
        agents.tint = Look.identity[c.identityIndex % Look.identity.count]
        let device = store.devices.first { $0.id == c.deviceID }?.name ?? "This Mac"
        let project = c.projectID.flatMap { p in store.projects.first { $0.id == p }?.name } ?? "No Project"
        context.stringValue = "\(project) · \(device)"
        configureOrbs()
        needsLayout = true
        onSelect?(id)
    }

    // MARK: New Chat (CollapseView composingNew; spec §4)

    /// New Chat in the strip: the seed and its name where the transcript goes, its project and device, the draft's
    /// composer; the window's arrangement does not change. The overlay closes first.
    func beginNewChat() {
        if overlay != nil { closeOverlay() }
        if draft != nil { (composerHost.subviews.first as? NativeComposer)?.focus(); return }
        let (composer, token) = sessions.draft()
        composer.sendShortcut = AutoScene.sendShortcut
        let seed = HeaderIsland()
        seed.configure(.conversation(draftPlaceholder, variant: .newChat, columnWidth: 192, band: 0, reduceMotion: Motion.reduce, ambient: ambientRunning, scale: scale))
        addSubview(seed, positioned: .above, relativeTo: island)
        draft = (token, seed)
        composer.onCancel = { [weak self] in self?.cancelNewChat() }
        composer.onSubmit = { [weak self, weak composer] request in
            guard let self, let composer else { return }
            if !self.sendNewChat(request) { composer.completeSubmission(request.id, outcome: .failed("New Chat could not start the conversation.")) }
        }
        composerHost.subviews.filter { $0 !== composer }.forEach { $0.removeFromSuperview() }
        if composer.superview !== composerHost { composer.removeFromSuperview(); composerHost.addSubview(composer) }
        composer.isHidden = false; composer.alphaValue = 1
        island.isHidden = true; agents.isHidden = true
        if let owner = transcriptSessions, let lease = transcriptLeases.removeValue(forKey: shown) { owner.unmount(lease) }
        else if transcriptSessions == nil { transcripts[shown]?.isHidden = true }
        setRailHidden(true)
        context.isHidden = true
        draftContextRow.context = newChatContext
        if draftContextRow.superview == nil { addSubview(draftContextRow) }
        draftContextRow.isHidden = false
        if !Motion.reduce, let layer = seed.layer {
            let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0; a.toValue = 1; a.duration = 0.12
            a.timingFunction = CAMediaTimingFunction(name: .easeOut); layer.add(a, forKey: "collapse.seed")
        }
        needsLayout = true; layoutSubtreeIfNeeded()
        composer.focus()
    }

    /// Esc or a click on an orb: the strip shows its conversation again; the draft's words stay for next time.
    func cancelNewChat() {
        guard draft != nil else { return }
        endDraft(keepWords: true)
        show(shown, animated: true)
    }

    private func endDraft(keepWords: Bool) {
        guard let d = draft else { return }
        draft = nil
        d.seed.removeFromSuperview()
        if let composer = composerHost.subviews.first as? NativeComposer, composer.onCancel != nil { composer.onCancel = nil; composer.onSubmit = nil }
        island.isHidden = false; agents.isHidden = false
        context.isHidden = false; draftContextRow.isHidden = true
        setRailHidden(false)
    }

    /// The first send: the conversation is made, joins the working set and is shown, with the same editor (spec §4).
    private func sendNewChat(_ request: NativeComposerSubmission) -> Bool {
        guard store.device(newChatContext.deviceID)?.online ?? true else { return false }
        guard let d = draft, let c = onCreateChat?(request.text, newChatContext), let composer = sessions.promoteDraft(d.token, to: c, store: store) else { return false }
        composer.onCancel = nil; composer.onSubmit = nil
        endDraft(keepWords: false)
        if !store.conversations.contains(where: { $0.id == c.id }) { store.add(c) }
        onJoin?(c)
        if !members.contains(where: { $0.id == c.id }) { members.append(c); rebuildOrbs() }
        show(c.id, animated: true)
        if let send = onSendNew {
            _ = send(c, request) { [weak composer] outcome in composer?.completeSubmission(request.id, outcome: outcome) }
        } else {
            composer.completeSubmission(request.id, outcome: .failed("Nothing can send yet."))
        }
        composer.focus()
        return true
    }

    /// While drafting, the rail of conversations is not there, only me's rail (NativeCollapseDock; organic audit B22).
    private func setRailHidden(_ hidden: Bool) {
        railContainer.isHidden = hidden
        for o in orbs.values { o.decoration.backView.isHidden = hidden; o.decoration.frontView.isHidden = hidden }
    }

    /// Increase Contrast or Reduce Transparency changed: the washes go or come back (f201).
    func displayOptionsChanged() {
        configureOrbs(); configureMe(); needsLayout = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let themed = Look.themedCanvas
        layer?.backgroundColor = themed.canvas.cgColor
        for (w, (color, alpha)) in zip(washes, themed.washes) {
            w.isHidden = Look.plainCanvas
            w.colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0, let c = members.first(where: { $0.id == shown }) ?? store.conversation(shown) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let side = max(w, h)
        for (k, (wash, radius)) in zip(washes, [CGFloat(0.75), 0.80]).enumerated() {
            let r = side * radius, c = k == 0 ? CGPoint(x: w, y: 0) : CGPoint(x: 0, y: h)
            wash.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
        // Header + transcript: full, width W, height max(120, H − 266), top bleed 52, collapse variant.
        let top = max(120, h - 266)
        // New Chat's seed where the transcript goes: centred at (W / 2, top / 2 + 26) (NewChatHero).
        if let seed = draft?.seed {
            let g = seed.motionGeometry(variant: .newChat, columnWidth: 192)
            seed.endMotion()
            seed.frame = CGRect(x: ((w - 192) / 2).rounded(), y: (top / 2 + 26 - g.height / 2).rounded(), width: 192, height: g.height)
        }
        island.configure(.conversation(c, variant: .collapse, columnWidth: w, band: HeaderIslandVariant.band(bleedTop: 52), reduceMotion: Motion.reduce,
                                       ambient: ambientRunning, scale: scale, identitySymbol: c.identitySymbol, identityTint: c.identityTint))
        island.endMotion()
        island.setFrameOrigin(.zero)
        let contentTop = island.motionGeometry(variant: .collapse, columnWidth: w).contentTop - 20
        if let t = transcripts[shown] {
            let size = CGSize(width: (w * scale).rounded() / scale, height: max(1, top - contentTop))
            if transcriptSessions != nil {
                _ = transcriptLeases[shown]?.place(CGRect(origin: CGPoint(x: 0, y: contentTop), size: size))
            } else if t.frame.size != size {
                let first = t.frame.size == .zero
                t.setFrameSize(size); t.refresh(preservingOffset: nil); t.layoutSubtreeIfNeeded()
                if first { t.scrollToEnd() }
            }
            if transcriptSessions == nil { t.setFrameOrigin(CGPoint(x: 0, y: contentTop)) }
        }
        context.sizeToFit()
        context.frame = CGRect(x: 16, y: h - 254 + ((22 - context.frame.height) / 2).rounded(), width: w - 32, height: context.frame.height)
        if draft != nil { draftContextRow.frame = CGRect(x: 10, y: h - 254, width: w - 26, height: 22) }
        // Sub-agents: (W − 56) × 48 at y = H − 168, two rows of 24 pt cells.
        agents.frame = CGRect(x: 28, y: h - 168, width: max(0, w - 56), height: 48)
        // The composer: x 16, y H − 224, (W − 32) × 48, no grip, no glass.
        composerHost.frame = CGRect(x: 16, y: h - 224, width: w - 32, height: 48)
        if let composer = composerHost.subviews.first as? NativeComposer {
            composer.targetWidth = w - 32
            composer.frame = composerHost.bounds
        }
        // The orb rail: (16, H − 112, W − 32, 44); 36 pt orbs 52 apart, centred, clipped to the rail.
        let rail = CGRect(x: 16, y: h - 112, width: w - 32, height: 44)
        railContainer.frame = rail; railContent.frame = railContainer.bounds
        railContainer.layer?.masksToBounds = true
        let span = CGFloat(members.count) * 52 - 16
        let start = max(0, (rail.width - span) / 2) - railScroll
        for (i, c) in members.enumerated() {
            guard let o = orbs[c.id] else { continue }
            let r = CGRect(x: start + CGFloat(i) * 52, y: 4, width: 36, height: 36)
            let f = railMotion[c.id]?.update(r.offsetBy(dx: rail.minX, dy: rail.minY), at: motionNow(),
                name: "collapse.orb."+c.id, profile: exposureProfile, enabled: usesExposure)
            let painted = f?.painted ?? r.offsetBy(dx: rail.minX, dy: rail.minY)
            o.glass.frame = painted.offsetBy(dx: -rail.minX, dy: -rail.minY)
            o.glass.cornerRadius = min(painted.width, painted.height)/2
            o.decoration.setCanvasSize(bounds.size)
            o.decoration.setFrame(painted)
            if let f { onMotionFrame?(f); M10DockMotion.onOrbFrame?(o.decoration, f, exposureProfile) }
        }
        // me's rail: (16, H − 60, W − 32, 52), radius 26, label 6 %; me 36 pt, its centre 26 pt from the rail's right end.
        let meRailRect = CGRect(x: 16, y: h - 60, width: w - 32, height: 52)
        meRail.frame = meRailRect; meRail.cornerRadius = 26
        let p = progress
        landing.frame = CGRect(x: meRailRect.minX + 17, y: meRailRect.midY - 2, width: 18, height: 4); landing.cornerRadius = 2
        landing.opacity = Float(0.2 + 0.6 * p)
        hint.frame = CGRect(x: meRailRect.minX + 18, y: meRailRect.midY - 9, width: meRailRect.width - 36, height: 18)
        hint.alphaValue = 0.42 * (1 - p)
        placeMe()
        meDecoration?.setCanvasSize(bounds.size)
        layoutOverlay()
        CATransaction.commit()
    }

    private var travel: CGFloat { max(0, bounds.width - 32 - 52) }
    private var offset: CGFloat {
        if let d = drag { return d.offset }
        return CGFloat(back.sample(motionNow() - backBegan).value)
    }
    private var progress: CGFloat { travel > 0 ? min(1, max(0, -offset / travel)) : 0 }

    private func placeMe() {
        let railRect = CGRect(x: 16, y: bounds.height - 60, width: bounds.width - 32, height: 52)
        let c = CGPoint(x: railRect.maxX - 26 + offset, y: railRect.midY)
        let r = CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36)
        let f = meMotion.update(r, at: motionNow(), name: "collapse.me", profile: exposureProfile, enabled: usesExposure)
        me.frame = f.painted; me.cornerRadius = min(f.painted.width, f.painted.height)/2
        meDecoration?.setFrame(f.painted)
        if let d = meDecoration { M10DockMotion.onOrbFrame?(d, f, exposureProfile) }
        onMotionFrame?(f)
        landing.opacity = Float(0.2 + 0.6 * progress)
        hint.alphaValue = 0.42 * (1 - progress)
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        // me's rail takes the pointer ahead of everything (NativeDockScene: the me rail's hit first), the orbs are clicks.
        if overlay == nil, bounds.height > 0, CGRect(x: 16, y: bounds.height - 112, width: bounds.width - 32, height: 104).contains(p) { return self }
        return super.hitTest(point)
    }

    /// Right-click on me: only "Account…", which opens the account menu at me (NativeCollapseDock makeMeMenu).
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard me.frame.insetBy(dx: -4, dy: -4).contains(p) else { super.rightMouseDown(with: event); return }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Account…") { [weak self] in guard let self else { return }; self.onAccountMenu?(self.me.frame) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if me.frame.insetBy(dx: -4, dy: -4).contains(p) { drag = (p.x, 0, false); return }
        let rail = CGRect(x: 16, y: bounds.height - 112, width: bounds.width - 32, height: 44)
        if rail.contains(p), let c = members.first(where: { orbs[$0.id]?.glass.frame.offsetBy(dx: rail.minX, dy: rail.minY).contains(p) == true }) {
            show(c.id, animated: true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - d.start
        guard abs(dx) >= 4 || d.offset != 0 else { return }
        d.offset = min(0, max(-travel, dx))
        // Armed at the end (6 pt short of it): a level-change tick.
        let armed = -d.offset >= travel - 6
        if armed && !d.armed { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        d.armed = armed
        drag = d
        placeMe()
    }

    override func mouseUp(with event: NSEvent) { release() }

    private func release() {
        guard let d = drag else { return }
        drag = nil
        // A click on me (no drag): the sidebar overlay (CollapseView).
        if d.offset == 0, !d.armed { toggleOverlay(); return }
        // me always springs back (0.32 / 0.82); armed, the window comes back.
        back = Spring(from: Double(d.offset), to: 0, response: 0.32, damping: 0.82, epsilon: Spring.restEpsilon)
        backBegan = motionNow()
        runBack()
        if d.armed { onRestore?() }
    }

    override func scrollWheel(with event: NSEvent) {
        let rail = CGRect(x: 16, y: bounds.height - 112, width: bounds.width - 32, height: 44)
        let p = convert(event.locationInWindow, from: nil)
        // A swipe on me's rail (precise, no momentum, mostly sideways as it begins) drags me (NativeCollapseDock).
        let meRail = CGRect(x: 16, y: bounds.height - 60, width: bounds.width - 32, height: 52)
        if event.hasPreciseScrollingDeltas, event.momentumPhase == [] {
            if event.phase == .began, meRail.contains(p), abs(event.scrollingDeltaX) > 1.5 * abs(event.scrollingDeltaY) { drag = (0, 0, false); swiping = true }
            if swiping, var d = drag {
                d.offset = min(0, max(-travel, d.offset + event.scrollingDeltaX))
                let armed = -d.offset >= travel - 6
                if armed && !d.armed { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
                d.armed = armed; drag = d; placeMe()
                if event.phase == .ended || event.phase == .cancelled {
                    swiping = false
                    if event.phase == .cancelled { drag?.armed = false }
                    if drag?.offset == 0 { drag = nil } else { release() }
                }
                return
            }
        }
        guard rail.contains(p), abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { super.scrollWheel(with: event); return }
        let limit = max(0, CGFloat(members.count) * 52 - 8 - rail.width)
        railScroll = min(limit, max(0, railScroll - event.scrollingDeltaX))
        needsLayout = true
    }

    private func runBack() {
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common); link = l
        }
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        placeMe()
        if overlayRise != nil { layoutOverlay() }
        if motionNow() - backBegan > back.duration, overlayRise == nil { l.isPaused = true }
    }

    /// Esc: the overlay closes first, then the draft (spec §4).
    override func cancelOperation(_ sender: Any?) {
        if let d = drag {
            // NativeCollapseDock's cancelled release: disarmed, back to its place, the coming mouse-up consumed.
            drag = nil; swiping = false
            back = Spring(from: Double(d.offset), to: 0, response: 0.32, damping: 0.82, epsilon: Spring.restEpsilon)
            backBegan = motionNow(); runBack()
        } else if overlay != nil { closeOverlay() }
        else if draft != nil { cancelNewChat() }
        else { nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender) }
    }

    /// Smart zoom (a two-finger double tap) brings the window back (f050).
    override func smartMagnify(with event: NSEvent) { onRestore?() }

    // MARK: The sidebar overlay (f052)

    private var overlay: (scrim: Scrim, panel: NSGlassEffectView, close: NativeButton, title: NativeButton, sidebar: NormieSidebarController, model: NormieSidebarModel)?

    /// A full-strip 12 % scrim (a click closes) under a glass panel (W − 24, from y 60 to H − 70, radius 24) holding
    /// the sidebar on its own model of the same store, the shown conversation selected. Opens on 0.30 / 0.88 (fade and
    /// 12 pt rise), closes easeOut 0.12. A choice shows that conversation in the strip.
    func toggleOverlay() { overlay == nil ? openOverlay() : closeOverlay() }

    private func openOverlay() {
        let scrim = Scrim(frame: bounds)
        scrim.onClick = { [weak self] in self?.closeOverlay() }
        let panel = NSGlassEffectView()
        panel.style = .regular
        panel.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
        panel.cornerRadius = 24
        let content = Flipped(); content.wantsLayer = true
        panel.contentView = content
        // The top row: New Chat (it closes the overlay and opens the draft in the strip) and ✕.
        let title = NativeButton(frame: .zero)
        title.title = "New Chat"
        title.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        title.imagePosition = .imageLeading; title.font = .systemFont(ofSize: 13, weight: .medium)
        title.contentTintColor = Look.ink
        title.target = self; title.action = #selector(newChatClicked)
        let close = NativeButton(frame: .zero)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        close.contentTintColor = Look.secondary; close.imagePosition = .imageOnly
        close.target = self; close.action = #selector(closeClicked)
        let model = NormieSidebarModel(store: store, current: shown)
        let sidebar = NormieSidebarController(model: model)
        _ = sidebar.view
        sidebar.account = .prototype
        model.onSelection = { [weak self] id in
            guard let self, let id else { return }
            self.show(id, animated: true); self.closeOverlay()
        }
        content.addSubview(title); content.addSubview(close); content.addSubview(sidebar.view)
        addSubview(scrim); addSubview(panel)
        overlay = (scrim, panel, close, title, sidebar, model)
        layoutOverlay()
        let reduce = Motion.reduce
        let frames = M10DockRowTrail.frames(distance: 12, response: 0.30, damping: 0.88, profile: exposureProfile)
        if usesExposure, frames.contains(where: { $0.2.gate > 0 }) {
            overlayRise = (Spring(from: 12, to: 0, response: 0.30, damping: 0.88, epsilon: 0.00001), motionNow())
            overlayMotion.reset(); runBack()
        }
        for (layer, rise) in [(scrim.layer, false), (panel.layer, true)] as [(CALayer?, Bool)] {
            guard let layer else { continue }
            let fade = CASpringAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            let omega = 2 * Double.pi / 0.30
            fade.mass = 1; fade.stiffness = omega * omega; fade.damping = 2 * 0.88 * omega; fade.duration = reduce ? 0 : fade.settlingDuration
            layer.add(fade, forKey: "collapse.overlay.in")
            if rise && !reduce && overlayRise == nil {
                let up = CASpringAnimation(keyPath: "transform.translation.y"); up.fromValue = 12; up.toValue = 0
                up.mass = 1; up.stiffness = fade.stiffness; up.damping = fade.damping; up.duration = up.settlingDuration
                layer.add(up, forKey: "collapse.overlay.rise")
            }
        }
    }

    @objc private func closeClicked() { closeOverlay() }
    @objc private func newChatClicked() { beginNewChat() }

    private func closeOverlay() {
        guard let o = overlay else { return }
        overlay = nil; overlayRise = nil; overlayMotion.reset()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduce ? 0 : 0.12; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            o.scrim.animator().alphaValue = 0; o.panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { o.scrim.removeFromSuperview(); o.panel.removeFromSuperview() } })
    }

    private func layoutOverlay() {
        guard let o = overlay else { return }
        o.scrim.frame = bounds
        let panel = CGRect(x: 12, y: 60, width: bounds.width - 24, height: max(120, bounds.height - 70 - 60))
        if let rise = overlayRise {
            let now = motionNow(), dy = CGFloat(rise.spring.sample(now-rise.began).value)
            let logical = panel.offsetBy(dx: 0, dy: dy)
            let f = overlayMotion.update(logical, at: now, name: "collapse.overlay", profile: exposureProfile, enabled: usesExposure)
            o.panel.frame = f.painted // real glass geometry; never transform or replicate glass.
            o.panel.contentView?.frame = CGRect(x: logical.minX-f.painted.minX, y: logical.minY-f.painted.minY, width: panel.width, height: panel.height)
            onMotionFrame?(f)
            if now-rise.began >= rise.spring.duration { overlayRise = nil }
        } else {
            o.panel.frame = panel
            o.panel.contentView?.frame = CGRect(origin: .zero, size: panel.size)
        }
        o.title.sizeToFit()
        o.title.frame.origin = CGPoint(x: 14, y: ((44 - o.title.frame.height) / 2).rounded())
        o.close.frame = CGRect(x: panel.width - 12 - 28, y: 8, width: 28, height: 28)
        o.sidebar.view.frame = CGRect(x: 0, y: 44, width: panel.width, height: panel.height - 44)
    }

    final class Flipped: NSView { override var isFlipped: Bool { true } }

    /// The shown conversation's sub-agents in two rows of 24 pt cells with 16 pt dots (CollapseMoons): running in the
    /// first row from the left, finished in the second from the right with the latest first. A row that does not fit
    /// shows one fewer and a "…" (after the running, before the finished) that opens the sheet. A dot opens its window.
    // MARK: VoiceOver (f197; NativeCollapseDock accessibility, organic audit B18)

    private var accessibilityNodes: [String: DockElement] = [:]
    override func accessibilityChildren() -> [Any]? {
        func element(_ key: String, _ frame: @escaping () -> CGRect, label: String, press: @escaping () -> Bool) -> DockElement {
            let e = accessibilityNodes[key] ?? DockElement()
            e.host = self; e.setAccessibilityRole(.button); e.frameInHost = frame; e.press = press
            e.setAccessibilityLabel(label)
            accessibilityNodes[key] = e
            return e
        }
        var out: [DockElement] = []
        if !railContainer.isHidden {
            for c in members {
                guard let o = orbs[c.id] else { continue }
                let e = element("orb." + c.id, { [weak self, weak g = o.glass] in g.flatMap { g in self.map { g.convert(g.bounds, to: $0) } } ?? .zero },
                                label: AutoScene.spokenLabel(c) + (c.id == shown ? ", shown" : "")) { [weak self] in self?.show(c.id, animated: true); return true }
                out.append(e)
            }
        }
        let me = element("me", { [weak self] in self?.me.frame ?? .zero }, label: "Me. Chats and account") { [weak self] in self?.toggleOverlay(); return true }
        me.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Restore Window") { [weak self] in self?.onRestore?(); return true }])
        out.append(me)
        if !agents.isHidden, let c = members.first(where: { $0.id == shown }) {
            for (k, cell) in agents.cellFrames.enumerated() {
                let s = c.satellites.first { $0.id == cell.id }
                out.append(element("agent." + cell.id, { [weak self] in self.map { strip in strip.agents.convert(cell.rect, to: strip) } ?? .zero },
                                   label: "Sub-agent \(k + 1), \(s?.done == true ? "done" : "running")") { [weak self] in self?.agents.onOpen?(cell.id); return true })
            }
            for (k, r) in agents.moreFrames.enumerated() {
                out.append(element("more.\(k)", { [weak self] in self.map { strip in strip.agents.convert(r, to: strip) } ?? .zero },
                                   label: "All sub-agents") { [weak self] in self?.agents.onMore?(); return true })
            }
        }
        return (super.accessibilityChildren() ?? []) + out
    }

    final class AgentRows: NSView {
        var satellites: [Satellite] = [] { didSet { needsDisplay = true } }
        var tint = NSColor.white { didSet { needsDisplay = true } }
        var onOpen: ((String) -> Void)?
        var onMore: (() -> Void)?
        override var isFlipped: Bool { true }
        private var cells: [(id: String, rect: CGRect)] = []
        private var more: [CGRect] = []
        var cellFrames: [(id: String, rect: CGRect)] { cells }
        var moreFrames: [CGRect] { more }

        override func draw(_ dirtyRect: NSRect) {
            cells = []; more = []
            let fit = max(1, Int(bounds.width / 24))
            let running = satellites.filter { !$0.done }
            let done = satellites.filter(\.done).sorted { ($0.finishedOrder ?? 0) > ($1.finishedOrder ?? 0) }
            for (row, list) in [running, done].enumerated() {
                let trailing = row == 1, overflow = list.count > fit
                let shown = overflow ? Array(list.prefix(fit - 1)) : list
                for (k, s) in shown.enumerated() { cells.append((s.id, cell(row, k, trailing: trailing))) }
                if overflow { more.append(cell(row, shown.count, trailing: trailing)) }
            }
            for r in more {
                let text = NSAttributedString(string: "…", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: Look.secondary])
                let size = text.size()
                text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
            }
            for (id, r) in cells {
                guard let s = satellites.first(where: { $0.id == id }) else { continue }
                let dot = r.insetBy(dx: 4, dy: 4)
                // SatelliteDot: running on the accent at 0.9, finished gray at 0.85, a white 0.18 hairline, the face white
                // (0.75 when finished) — not the conversation's colour (organic audit B23).
                (s.done ? NSColor.gray.withAlphaComponent(0.85) : NativeAppearance.current.accentColor.withAlphaComponent(0.9)).setFill()
                let circle = NSBezierPath(ovalIn: dot)
                circle.fill()
                NSColor(white: 1, alpha: 0.18).setStroke(); circle.lineWidth = 0.5; circle.stroke()
                let face = NSFont.systemFont(ofSize: dot.width * 0.34, weight: .semibold)
                let text = NSAttributedString(string: s.face, attributes: [.font: NSFont(descriptor: face.fontDescriptor.withDesign(.rounded) ?? face.fontDescriptor, size: face.pointSize) ?? face,
                                                                           .foregroundColor: NSColor(white: 1, alpha: s.done ? 0.75 : 1)])
                let size = text.size()
                text.draw(at: CGPoint(x: dot.midX - size.width / 2, y: dot.midY - size.height / 2))
            }
        }

        private func cell(_ row: Int, _ k: Int, trailing: Bool) -> CGRect {
            let x = trailing ? bounds.width - CGFloat(k + 1) * 24 : CGFloat(k) * 24
            return CGRect(x: x, y: CGFloat(row) * 24, width: 24, height: 24)
        }

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if more.contains(where: { $0.contains(p) }) { onMore?(); return }
            if let c = cells.first(where: { $0.rect.contains(p) }) { onOpen?(c.id) }
        }
    }

    final class Scrim: NSView {
        var onClick: (() -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor(white: 0, alpha: 0.12).cgColor }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    /// For demos: me carried to the end of its rail and let go.
    func dragMeToEnd() {
        drag = (0, -travel, true)
        placeMe()
        release()
    }
}
