import AppKit
import QuartzCore

/// Organic Auto: columns over a dock, one column full. A brief↔full switch is one committed transition:
/// columns, transcript fades, brief reveals and the goal's flights (with their exposure) go to the render
/// server as keyframes in one transaction (driver B); only the glass bars follow frame by frame (driver A).
@MainActor final class AutoScene {
    final class PassThrough: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// The scene came on screen (its window, or an ancestor shown again: Hide Sidebar, Restore).
        var onPresented: (() -> Void)?
        override func viewDidUnhide() { super.viewDidUnhide(); onPresented?() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { onPresented?() } }
    }

    /// Hosts the columns' native transcripts between the scene and the dock; empty space passes clicks on.
    final class NativePlane: NSView {
        override var isFlipped: Bool { true }
        private var insertingSubview = false
        // Admission order must not lift selectable ink above an existing island, draft or spare header.
        // Keep headers directly in this plane; insert once at the semantic mount, never sort motion frames
        // (native subview reordering invalidates glass materials). Normie's separate hosts keep their policy.
        override func addSubview(_ view: NSView) {
            // AppKit's positioned insertion calls this primitive before applying the requested order.
            if insertingSubview { super.addSubview(view); return }
            addSubview(view, positioned: .above, relativeTo: nil)
        }
        override func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo otherView: NSView?) {
            if insertingSubview { super.addSubview(view); return }
            insertingSubview = true; defer { insertingSubview = false }
            let transcript = view is NativeTranscript
            super.addSubview(view, positioned: transcript ? .below : place, relativeTo: transcript ? nil : otherView)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { let v = super.hitTest(point); return v === self ? nil : v }
    }

    let sceneView = PassThrough()
    let nativePlane = NativePlane()
    let transcriptSessions: NativeTranscriptSessions?
    var transcriptsPresented: Bool
    /// No window (tests, offscreen renders): show native captures at rest instead of the views.
    var restOnSnapshot = false
    let dockView = DockNode.Passage()
    /// Over everything: the model picker and Send's options (Sol's Overlay/) and their shield; empty space passes on.
    let overlayPlane = NativePlane()
    var overlays: [String: OverlayComposerBinding] = [:]
    /// Peek's halo and lyrics (f045), between the native transcripts and the dock.
    let peekNode: PeekNode
    let scene = CALayer()
    let cards = CALayer(), flightsPlane = CALayer()
    let statusLine = CATextLayer()
    let dock: DockNode
    let clock = SceneClock()
    lazy var orbInput = OrbInputController(scene: self)
    lazy var orbMenu = OrbContextMenu(scene: self)
    lazy var orbFlights = OrbSwitchFlight(scene: self)
    lazy var orbToast = OrbActionToast()
    lazy var orbHint = OrbHoverHint(scene: self)
    lazy var orbTrash = AutoSceneTrash(scene:self)
    var sunHover: SunHoverController?
    var orbSwapLearned = false
    var orbMenuPeekColumn: String?
    var orbPressOrigin: CGRect?
    var orbArchivePositions: [String: OrbArchivePosition] = [:]
    /// Whole-history fork: Core must omit beforeTurnId and return a newly identified conversation.
    var onForkWhole: ((Conversation, OrbWholeForkRequest, @escaping (Result<Conversation, Error>) -> Void) -> Void)?

    let store: ConversationStore
    private var observation: UUID?
    var modeContentEpochFrozen=false
    var modeContentEpochPending=Set<String>()
    /// The working set in queue order (product WindowModel.members) and the full one; the layout shows them in
    /// display order (`order`): the first `layout.columns.count` as columns, the rest as orbs.
    var members: [Conversation] = []
    var current = ""
    static let draftID = "organic.new-chat"
    var scheme = Scheme()
    /// Auto as it was when Focused began, to go back to (WindowModel autoSnapshot).
    var autoSnapshot: (members: [Conversation], current: String, parked: [String])?
    var order: [String] = []
    /// Every conversation shown as a column so far, kept with its native session while it is an orb (f099).
    var nodes: [String: ColumnNode] = [:]
    /// The columns on screen in slot order, and those shrinking away while a transition runs.
    var columns: [ColumnNode] = []
    var leaving: [String: ColumnNode] = [:]
    var layout = AutoLayout()
    var metrics = AutoLayout.Metrics()
    /// Fully Focused (f044, Tuning toggle.fullyFocused): Focused and Split hold the dock still.
    var fullyFocused = UserDefaults.standard.bool(forKey: "toggle.fullyFocused") {
        didSet { UserDefaults.standard.set(fullyFocused, forKey: "toggle.fullyFocused"); dock.still = isFocused && fullyFocused }
    }
    var flights: [String: [FlightNode]] = [:]
    var began = -1.0, ends = -1.0, generation = 0
    var dirty = Set<String>()
    /// Columns whose content changed at rest, rendered together on the next tick (`flushRenders`).
    var pendingRenders = Set<String>()
    var renderScheduled = false
    var pendingMovingRenders=Set<String>(),movingRenderScheduled=false
    var modeHandoffActive=false
    var prewarmRequested=false,prewarmScheduled=false
    var prewarmQueue:[String]?
    var prewarmTask:DispatchWorkItem?
    var idlePrewarmTask:Task<Void,Never>?
    var idlePrewarmEpoch=0
    var idleInputMonitor:Any?
    var idleMotionUntil = -Double.infinity
    var lastPrewarmActivity = -Double.infinity
    var preferredPrewarm:String?
    var prewarmMissReasons:[String:String]=[:]
    var lastPrewarmClear="initial"
    var idlePrewarmSlices:[(name:String,ms:Double)]=[]
    var verificationIdlePrewarm=false
    var idlePrewarmOutcome="not-requested"

    /// On screen: only then is a column's content worth rendering at once. Tests have no window and render at once.
    /// Offscreen admission only; production derives this from its visible scene/window.
    var verificationPresented:Bool?
    private(set) var size: CGSize
    var washes: [(layer: CAGradientLayer, radius: CGFloat, topRight: Bool)] = []
    var scale: CGFloat
    var profile: DisplayProfile
    var exposure = ExposureSettings()
    /// M10-D comparison switch only. The existing flight exposure and the other M10 tasks stay independent.
    var columnExposureEnabled = ProcessInfo.processInfo.environment["M10_COLUMNS"] != "0"
    var columnZoomStyle=M10ColumnZoom.selected
    var columnMotionPlans: [String: M10ColumnPlan] = [:]
    var blockMain = false
    var switches: [[String: Any]] = []
    var onModeEndpointVisibilityChanged:(()->Void)?
    weak var browserPort: (any BrowserHostPort)?
    var onStatus: (() -> String)?
    /// The scene's clock. Tests replace it with a virtual one and settle by hand.
    var now: () -> Double = { CACurrentMediaTime() }
    var manualSettle = false

    init(size: CGSize, store: ConversationStore, profile: DisplayProfile, scale: CGFloat, transcriptSessions: NativeTranscriptSessions? = nil) {
        self.size = size; self.store = store; self.profile = profile; self.scale = scale
        self.transcriptSessions = transcriptSessions; transcriptsPresented = transcriptSessions == nil
        dock = DockNode(view: dockView, scale: scale)
        peekNode = PeekNode(size: size, scale: scale)
        dockView.routeOrbInput = { [weak self] island, event in
            guard let self, let id = island.configuration?.id else { return false }
            if event.type == .leftMouseUp, self.orbInput.isPressed { self.orbInput.released(event); return true }
            if event.type == .leftMouseDragged, self.orbInput.isPressed { self.orbInput.dragged(event); return true }
            guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return false }
            return self.orbInput.begin(event, id: id, header: island) { [weak island] _ in island?.planetButton.performClick(nil) }
        }
        dockView.routeTideOrbInput = { [weak self] id, event in
            guard let self,self.members.contains(where:{$0.id == id}) else { return false }
            if event.type == .leftMouseUp,self.orbInput.isPressed { self.orbInput.released(event); return true }
            if event.type == .leftMouseDragged,self.orbInput.isPressed { self.orbInput.dragged(event); return true }
            guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return false }
            return self.orbInput.begin(event,id:id,ordinary:{ _ in })
        }
        dockView.routeTidePlanetInput = { [weak self] id,event,target in
            guard let self,self.members.contains(where:{$0.id==id}) else {return false}
            let onClick=target.onPress
            let observe:((NSEvent)->Void)?=OrbGesturePolicy.action(event) == .ordinary
                ? { [weak target] event in target?.onPointer?(event) }:nil
            return self.orbInput.begin(event,id:id,tidePlanet:true,observePointer:observe,ordinary:{ [weak self] _ in
                if self?.dock.tideHasNotice(id)==true {onClick?()}
            })
        }
        dockView.orbInputContains = { [weak self] point in self?.orbInputTarget(at:point) != nil }
        dockView.cancelOrbInput = { [weak self] in
            guard let self,self.orbInput.isPressed else { return false }
            self.orbInput.cancel(); return true
        }
        let host = CALayer()
        sceneView.layer = host
        sceneView.wantsLayer = true
        sceneView.onPresented = { [weak self] in self?.presentDirty();self?.requestPrewarm() }
        scene.anchorPoint = .zero
        scene.bounds = CGRect(origin: .zero, size: size)
        // y runs down: AppKit already flips a flipped view's hosting layer, so the scene itself is not flipped.
        scene.backgroundColor = Look.canvas.cgColor
        host.addSublayer(scene)
        // Canopy washes (Canopy.swift:30-51): moss from the top right, teal from the bottom left.
        for (color, alpha, radius, topRight) in [(Look.moss, Look.mossAlpha, CGFloat(0.75), true), (Look.teal, Look.tealAlpha, CGFloat(0.80), false)] {
            let wash = CAGradientLayer()
            wash.type = .radial
            wash.colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
            wash.startPoint = CGPoint(x: 0.5, y: 0.5); wash.endPoint = CGPoint(x: 1, y: 1)
            scene.addSublayer(wash)
            washes.append((wash, radius, topRight))
        }
        layoutWashes()
        showWashes()
        flightsPlane.name="organic.flights"
        for l in [cards, flightsPlane, dock.layer] { l.anchorPoint = .zero; l.frame = scene.bounds; scene.addSublayer(l) }
        statusLine.anchorPoint = .zero
        statusLine.frame = CGRect(x: 24, y: 16, width: size.width - 48, height: 18)
        statusLine.fontSize = 11.5
        statusLine.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        statusLine.foregroundColor = Look.secondary.cgColor
        statusLine.contentsScale = scale
        // A development readout (display, refresh, the last switch's cost); the product has none (M9). `--status` shows it.
        statusLine.isHidden = !ProcessInfo.processInfo.arguments.contains("--status")
        scene.addSublayer(statusLine)
        dockView.wantsLayer = true
        nativePlane.wantsLayer = true
        // Sized here, not only by the window: a native view outside its plane's bounds captures nothing.
        for v in [sceneView, nativePlane, dockView, overlayPlane] { v.frame = CGRect(origin: .zero, size: size) }
        peekNode.view.appearance = NSAppearance(named: .darkAqua)
        overlayPlane.appearance = NSAppearance(named: .darkAqua)
        // Dark only (user, 2026-10-28); explicit, so captures without a window resolve the same colours.
        nativePlane.appearance = NSAppearance(named: .darkAqua)
        clock.onFrame = { [weak self] target in self?.frame(target) }
        dockView.accessibilityNodes = { [weak self] in self?.dockAccessibilityChildren() ?? [] }
        // Every window's scene watches the one store; arrivals go where the app sends them (f036).
        observation = store.observe { [weak self] c in self?.changed(c) }
        sunHover = SunHoverController(scene: self)
        dock.onTrashFrame = { [weak self] in self?.orbTrash.frame($0) }
        dock.onTrashApplied = { [weak self] in self?.orbTrash.didApplyFrame() }
    }

    /// The window changed size (f013): everything lies out again at rest for it. `live` while the user is still
    /// dragging the edge: no captures then (they are only for motion), made with the prewarm when the resize ends. A
    /// transition in flight ends first. (The product retargets it from where it is; not yet here.)
    func resize(to newSize: CGSize, live: Bool) {
        guard transcriptSessions?.isDisposed != true else { return }
        guard newSize.width > 100, newSize.height > 100 else { return }
        let changed = newSize != size
        if changed { sunHover?.retire(resumeTide: false); orbInput.cancel(); orbMenu.dismiss(); orbFlights.cancel(); orbHint.cancel() }
        if drag != nil { cancelDrag() }
        if isMoving { settle() }
        size = newSize
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scene.bounds = CGRect(origin: .zero, size: size)
        for l in [cards, flightsPlane, dock.layer] { l.frame = scene.bounds }
        layoutWashes()
        statusLine.frame = CGRect(x: 24, y: 16, width: size.width - 48, height: 18)
        for v in [sceneView, nativePlane, dockView, overlayPlane] { v.frame = CGRect(origin: .zero, size: size) }
        dismissPeek()
        peekNode.resize(to: size)
        metrics = AutoLayout.Metrics.tuned(for: size)
        (layout, order) = arrange(members, current: current)
        let shown = Array(order.prefix(layout.columns.count))
        // Columns that no longer fit go to orbs at once, and those that now fit come in (a resize has no transition).
        for column in columns where !shown.contains(column.conversation.id) {
            column.card.removeFromSuperlayer(); column.separator.removeFromSuperlayer()
            column.suspendNative()
        }
        columns = shown.enumerated().map { i, id in node(id, slot: i, in: layout) }
        for (i, column) in columns.enumerated() {
            if column.card.superlayer == nil { cards.addSublayer(column.card); cards.addSublayer(column.separator) }
            column.removeAnimations()
            column.reshape(sceneHeight: size.height, logicalBottom: layout.columns[i].maxY)
            column.rect = .rest(carrier(layout.columns[i]))
            column.form = .rest(isFull(column.conversation.id) ? 1 : 0)
            column.presence = .rest(1)
            column.showPresent()
            column.place(column.rect.target, form: column.form.to)
            if live && !restOnSnapshot { column.restLayout(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout)) }
            else { column.renderDisplay(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout), force: true) }
            column.showRest(full: isFull(column.conversation.id))
            column.separator.opacity = i < columns.count - 1 ? 1 : 0
        }
        CATransaction.commit()
        applyCardBands()
        restIslands()
        dock.relayout(layout, metrics: metrics, order: order.compactMap(conversation), full: fullIDs)
        browserPort?.resized(in: self)
        if scheme.draft, let c = layout.draftColumn, let b = layout.draftBar, let composer = draftComposer {
            draftColumn?.lay(c); dock.showDraftBar(composer, at: b)
        }
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="resize"
        if !live { dock.resumeSunHoverTide(source: "resize"); DispatchQueue.main.async { [weak self] in if changed {self?.fitSplit()};self?.requestPrewarm() } }
    }

    /// `members`: the working set this window opens with, in order (nil: every conversation in the store).
    func install(members ids: [String]? = nil) {
        guard transcriptSessions?.isDisposed != true else { return }
        // Nothing fades in: layers added or changed outside a transition never animate implicitly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        metrics = AutoLayout.Metrics.tuned(for: size)
        members = ids.map { $0.compactMap(store.conversation) } ?? store.conversations
        if !members.contains(where: { $0.id == current }) { current = members.first?.id ?? "" }
        (layout, order) = arrange(members, current: current)
        for node in nodes.values {
            node.card.removeFromSuperlayer(); node.separator.removeFromSuperlayer()
            if transcriptSessions != nil { node.unmountNative() } else { node.native.removeFromSuperview() }
        }
        nodes = [:]; leaving = [:]
        columns = order.prefix(layout.columns.count).enumerated().map { i, id in
            let column = node(id, slot: i, in: layout)
            cards.addSublayer(column.card); cards.addSublayer(column.separator)
            return column
        }
        for (i, column) in columns.enumerated() {
            column.renderDisplay(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout))
            column.showRest(full: isFull(column.conversation.id))
            column.separator.opacity = i < columns.count - 1 ? 1 : 0
        }
        restIslands()
        dock.composerFor = { [weak self] c in self!.composer(for: c) }
        dock.ambient = ambient
        peekNode.ambient = ambient
        dock.install(layout, metrics: metrics, order: order.compactMap(conversation), full: fullIDs, store: store)
        browserPort?.installed(in: self)
        sunHover?.didInstallDock()
        dock.onNeedsFrames = { [weak self] d in guard let self else { return }; self.runClock(until: self.now() + d) }
        dock.onNeedsFramesUntil = { [weak self] end in self?.runClock(until: end) }
        // Match the existing idle-prewarm quiet period without extending the display deadline.
        dock.onTideMotion = { [weak self] in guard let self else{return};self.idleMotionUntil=max(self.idleMotionUntil,self.now()+0.25) }
        dock.onTidePointer = { [weak self] point in self?.pointer(point) }
        dock.tideCanDismiss = { [weak self] in self?.tideHasForegroundSurface == false }
        dock.tideContentObstacles = { [weak self] in self?.tideDecisionObstacles ?? [] }
        dock.onTideReadingRoom = { [weak self] rects in self?.makeTideReadingRoom(rects) }
        dock.onTideReclaim = { [weak self] id in self?.reclaimTideBrief(id) }
        dock.onTideAction = { [weak self] id,action in self?.performTideAction(action,for:id) }
        dock.tideWarmAllowed = { [weak self] in guard let self else{return false};return self.presented && !self.isMoving && !self.modeHandoffActive && self.idlePrewarmTask == nil }
        dock.cancelHeldPress = { [weak self] in guard let self,self.drag != nil else { return false }; self.cancelDrag(); return true }
        clock.attach(to: sceneView)
        bindOverlays()
        updateStatus()
        DispatchQueue.main.async { [weak self] in self?.requestPrewarm() }
    }

    /// A working-set member, or one about to join (an arrival is prepared before it is a member).
    func conversation(_ id: String) -> Conversation? { members.first { $0.id == id } ?? store.conversation(id) ?? (joining?.id == id ? joining : nil) }
    /// New Chat's conversation between its first send and the store taking it.
    var joining: Conversation?

    /// The column node for a conversation, made the first time it is a column (at `slot` of `layout`).
    func node(_ id: String, slot i: Int, in l: AutoLayout, preparingMode: Bool = false) -> ColumnNode {
        if let n = nodes[id] { if !preparingMode { admitTranscript(n) }; return n }
        let work=M10ColumnWorkTrace.scope("scene.makeColumn",["id":id]);defer{work.end()}
        let c = conversation(id)!
        let column = ColumnNode(c, store: store, identity: Look.identity[c.identityIndex % Look.identity.count], rect: carrier(l.columns[i]),
                                full: isFull(id), scale: scale, logicalBottom: l.columns[i].maxY, transcriptSessions: transcriptSessions)
        column.motionProfile=profile;column.motionExposure=exposure
        column.motionExposure.enabled=exposure.enabled && columnExposureEnabled
        column.restOnSnapshot = restOnSnapshot
        column.ambient = ambient
        if !preparingMode { onShown?(c) }
        column.cardBand = cardBand(l.columns[i])
        if transcriptSessions == nil {
            wireTranscript(column.native, for: c, composer: composer(for: c))
            nativePlane.addSubview(column.native)
        } else if !preparingMode {
            if joining === c {
                let top=column.fullContentTop-18
                let frame=CGRect(x:l.columns[i].minX,y:top,width:fullWidth(i,l),height:l.columns[i].maxY+22-top)
                admitTranscript(column,frame:frame)
            } else {admitTranscript(column)}
        }
        if !restOnSnapshot { attachIsland(to: column) }
        nodes[id] = column
        return column
    }
    func disposeTranscriptPresentation() {
        browserPort?.retire(); browserPort = nil
        orbTrash.close()
        sunHover?.dispose(); sunHover = nil
        orbInput.dispose(); orbMenu.dispose(); orbFlights.cancel(); orbToast.dismiss(); orbHint.cancel()
        dock.retireTide()
        longPress?.cancel(); longPress = nil
        peekTimer?.cancel(); peekTimer = nil
        peekStage.forEach { $0.cancel() }; peekStage = []
        overlays.values.forEach { $0.disconnect() }; overlays = [:]
        for island in nativePlane.subviews.compactMap({ $0 as? HeaderIsland }) { island.dispose(); island.removeFromSuperview() }
        spareNewChatIsland?.dispose()
        peekNode.header.dispose()
        bridges = [:]
        discardNewChatPreparation()
        if let idleInputMonitor {NSEvent.removeMonitor(idleInputMonitor);self.idleInputMonitor=nil}
        spareNewChatIsland?.removeFromSuperview();spareNewChatIsland=nil
        draftHeaderWarmTask?.cancel();draftHeaderWarmTask=nil
        setTranscriptPresentationActive(false)
        clock.invalidate(); clock.onFrame = nil; sceneView.onPresented = nil
        if let observation { store.removeObserver(observation); self.observation = nil }
        cancelIdlePreparation();prewarmTask?.cancel();prewarmTask=nil;prewarmRequested=false;prewarmQueue=nil
        nodes = [:]; columns = []; leaving = [:]; pendingRenders = [];pendingMovingRenders=[]; dirty = []
    }

    // MARK: Header islands (M5)

    /// The window's workbench actions, for the islands' Status and Changes panels (Normie's inspector, one per island).
    var islandActions: NormieActions?
    var bridges: [ObjectIdentifier: IslandBridge] = [:]
    /// Read-only sub-agent windows, one per sub-agent, opened from a satellite (Sol's Sheets, f121).
    let subAgentWindows = SheetSubAgentWindows()
    /// The sub-agents sheet (f120), me's account menu and quota card (f008, f057), VoiceOver's dock (f197):
    /// DockAccess.swift.
    lazy var subAgentsSheet = SheetSubAgents()
    lazy var meController = OrbMeController(model: meModel())
    var meHovered = false
    var accessibilityNodes: [String: DockElement] = [:]

    /// Organic's archive toast, just above the dock (DetailRoot: bottomInset + barHeight + 14), with Undo (f123).
    var onUndoArchive: (() -> Bool)?
    lazy var archiveToast = SheetArchiveUndoToast()
    var archivedOut = Set<String>()

    /// Customize Chat (f073, f122): Sol's sheet over the scene (or `host`); Done renames and keeps the symbol and tint
    /// (Core's identitySymbol / identityTint), which the header and the dock then show. Cancel writes nothing.
    lazy var customizeSheet = SheetCustomizeChat()

    /// One composer per conversation for the scene's life (f101): its editor, selection and Undo survive every
    /// switch. Sending and stopping go to the host's runtime, which says whether it took the request.
    let composers = NativeComposerSessions()
    /// Sends a composer's request; `finish` is its receipt (CORE-M7: the Bool only says the runtime took the request in,
    /// not that the backend accepted it). Stop finishes when its interrupt's receipt comes back.
    var onSubmit: ((Conversation, NativeComposerSubmission, @escaping @MainActor (NativeComposerCompletion) -> Void) -> Bool)?
    /// Stop under the request's own UUID, finished by its actual receipt (a failed or unknown Stop clears only its own
    /// pending; NativeComposer.onStopRequest, f175).
    var onStopRequest: ((Conversation, UUID, @escaping @MainActor (NativeComposerCompletion) -> Void) -> Void)?
    /// Refresh history, from the editor's recovery button after an operation error or an unknown send (f180).
    var onRefreshHistory: ((Conversation) -> Void)?
    /// Ambient motion (the brief's "…" dots). Tests turn it off before install, so frames change only with transitions.
    var ambient = true
    /// When each transition came to rest (media time), for receipts.
    var settles: [Double] = []
    /// Send Message's keys (Settings ▸ Keyboard Shortcuts, the app's applyShortcuts); ⌘↩ until it says.
    static var sendShortcut = NativeComposerSendShortcut.commandReturn

    var prewarmed: [String: Prepared] = [:]
    var newChatPreparation: (key: NewChatPreparationKey, plan: Prepared)?
    static let prewarmRevisionFields=["order","current","frameInterval","mmPerPoint","columnExposure","exposureEnabled","shutter","zoomStyle",
        "width","height","appearance","display","reduceMotion","playful","mode","draft","split","left","right","parked","models"]

    /// Computes the transition to `nextMembers` with `nextCurrent` full as of `now`, without touching the screen.
    /// Where the last prepare spent its time (ms), for receipts.
    var prepareBreakdown: [String: Double] = [:]
    var draftColumn: DraftColumn?
    /// Allocate the next native header while the draft is resting. It is hidden and owns no conversation actions
    /// until first send binds it to the real column; no backend conversation is created by warming.
    var spareNewChatIsland: HeaderIsland?
    var spareNewChatPromotionWarmConfig:HeaderIslandConfiguration?
    weak var observedDraftComposer: NativeComposer?
    var draftHeaderWarmTask: DispatchWorkItem?
    lazy var spareNewChatIdentity=Conversation(id:"organic.prepared-new-chat",title:"New Chat")
    var draftToken: NativeComposerSessions.DraftToken?
    var committingDraftComposer: (id:String,composer:NativeComposer)?
    lazy var draftPlaceholder = Conversation(id: Self.draftID, title: "New Chat")
    /// The first send: the app makes the conversation (not sending yet; the scene sends it once it is a member).
    var onCreate: ((String, NormieNewChatContext) -> Conversation?)?
    /// New Chat's project and device, kept for the next draft too (WindowModel newChatProject / newChatDevice).
    var draftContext = NormieNewChatContext()
    /// The look changed: Collapse's strip follows it.
    var onLookChanged: (() -> Void)?
    /// A conversation came on screen (a column, the full one): the live Core reads its history.
    var onShown: ((Conversation) -> Void)?
    /// A header renamed its conversation (the live Core's rename; else the store directly).
    var onRename: ((Conversation, String) -> Void)?
    /// Customize wrote identitySymbol / identityTint (the live runtime keeps them in its presentation state).
    var onIdentityChanged: ((Conversation) -> Void)?
    /// Compact Now from an island's Context panel.
    var onCompact: ((Conversation) -> Void)?
    /// The working set changed (an arrival, an archive, a send from a draft): Collapse's strip follows it.
    var onMembersChange: (([Conversation]) -> Void)?

    // MARK: Compare (f043; OrganicDockBridge.dropMe / startCompare / send)

    /// Two neighbouring Split members that every send goes to together.
    var compare: (left: String, right: String)?
    var compareAsk: Int?
    lazy var compareSheet: SheetCompareConfirmation = {
        let sheet = SheetCompareConfirmation()
        sheet.onNeverAskChange = { UserDefaults.standard.set($0, forKey: "compare.neverAsk") }
        sheet.onConfirm = { [weak self] _ in guard let self, let i = self.compareAsk else { return }; self.startCompare(at: i) }
        sheet.onCancel = { [weak self] in
            guard let self else { return }
            self.compareAsk = nil; self.dock.setMeDivider(nil); self.runClock(until: self.dock.meSettles)
        }
        return sheet
    }()
    /// Told when the command target changes: at rest after a transition, or at once when Split's focus moves.
    var onTarget: ((String) -> Void)?
    var toldTarget = ""

    // MARK: Ambient motion and Reduce Motion (f199, f202)

    /// Off while the window is not key, occluded, minimized or idle for 8 s; the clocks hold their phase and go on from
    /// it. The conversations' content keeps streaming.
    var ambientRunning = true

    // MARK: Queue reorder by trackpad (f037; OWC handleQueueSwipe, spec §10.4)

    /// Two fingers across a bar or an orb in Auto move it along the queue, one place per 36 pt; a scroll event, so the
    /// pointer stays put. Claimed once mostly sideways; its momentum is swallowed (audit A15).
    var swipe: (id: String, accumulated: CGFloat, claimed: Bool)?
    static let swipeStep: CGFloat = 36
    static let prewarmInputMask:NSEvent.EventTypeMask=[.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.scrollWheel,.magnify,.rotate,.swipe]
    var reorderTextCandidate:String?
    var reorderTextHeld:String?
    var reorderTextRects:[String:RectSpring]=[:]
    var drag: Drag?
    var longPress: DispatchWorkItem?
    var meHoverTarget: String?
    static let previewSpring = (response: 0.25, damping: 0.80)

    /// Set by the mouse paths only: the demos and VoiceOver call pointerDown themselves, with no button held.
    var pressFromPointer = false
    /// The press ended without its release (Esc, a mode switch, the window losing key). Its later mouse-up is no click.
    var pressCancelled = false
    var buttonUpSince: Double?
    var onTear: ((TearEvent) -> Void)?
    var tearing: (id: String, before: [Conversation], current: String)?
    var tearBeforeScheme:Scheme?

    // MARK: Peek (f045–f046; OrganicDockBridge.hoverRegion, peekChanged, peekGeometry)

    /// The regions under the pointer, as the product's hover callbacks name them: a dock node ("orb.<id>", an orb's or a
    /// bar grip's) and, while a peek is open, its halo ("peek.surface").
    var hoverRegions = Set<String>()
    var peekTimer: DispatchWorkItem?
    var peekStage: [DispatchWorkItem] = []
    /// The orb the pointer asked to peek at (WindowModel.peeking), and what shows (shownPeek, peekOpen, content).
    var peeking: String?
    var shownPeek: String?, peekOpen = false, peekContentVisible = false
    var peekOrigin: CGRect?
    var lastPointer: CGPoint?
    /// Mouse buttons held down (tests and demos drive the pointer without any).
    var pressedButtons: () -> Int = { NSEvent.pressedMouseButtons }
    static let peekOpenDelay = 0.25, peekCloseDelay = 0.4
    var peekRow: [String: CGFloat] = [:], peekRowY: CGFloat = 0

    /// The harness tuning changed (the Debug panel): what was prepared ahead used the old values, and at rest the
    /// layout takes the new metrics now; a transition that is running keeps its springs and lays out anew when it settles.
    var tuningPending = false
}

extension AutoScene {
    func beginModeHandoff() {
        sunHover?.retire(resumeTide: false)
        orbInput.cancel(); orbTrash.suspend(); orbMenu.dismiss(); orbFlights.cancel(); orbToast.dismiss(); orbHint.cancel()
        dock.freezeTideForMode(fading:modeContentEpochFrozen)
        modeHandoffActive=true;cancelIdlePreparation();prewarmTask?.cancel();prewarmTask=nil;prewarmScheduled=false
    }
    var inModeHandoff:Bool {modeHandoffActive}
    func endModeHandoff() {
        // The frozen source remains the photo's owner until M11.31 releases its content epoch.
        if transcriptsPresented {dock.finishTideModeHandoff()} else {dock.retireTide()}
        modeHandoffActive=false
        dock.resumeSunHoverTide(source: "handoff")
        M10ColumnModeProbe.measure("OrganicAdmitTranscripts") {admitUnmountedTranscripts(columns)}
        if prewarmRequested,transcriptsPresented {requestPrewarm()}
    }
    func suspendModePresentation() {
        sunHover?.retire()
        orbInput.cancel(); orbTrash.suspend(); orbMenu.dismiss(); orbFlights.cancel(); orbToast.dismiss(); orbHint.cancel()
        if !modeContentEpochFrozen {dock.retireTide()}
        if !modeContentEpochFrozen {for column in nodes.values {column.island?.setPulsePresentationRetired(true)}}
        guard transcriptSessions?.isDisposed != true else{return}
        M10ColumnModeProbe.measure("OrganicModeSuspend") {
            transcriptsPresented=false
            cancelIdlePreparation();prewarmTask?.cancel();prewarmTask=nil;prewarmRequested=false;prewarmScheduled=false;prewarmQueue=nil
            for p in prewarmed.values {unstage(p)};prewarmed=[:];lastPrewarmClear="suspendModePresentation"
            for column in nodes.values {column.suspendNativeForMode()}
        }
    }
    /// A rest-mode endpoint, separate from an internal column morph. Values and detached resources only;
    /// the source keeps its shared viewports, editors, decision cards, focus and callbacks until commit.
    struct ModeTargetKey: Equatable {
        let size: CGSize, scale: CGFloat, appearance: Int, display: Int
        let sourceCurrent: String, selected: String, focus: String, scheme: Scheme, members: [String]
        let models: [ObjectIdentifier], revisions: [Int]
    }
    final class ModeTargetPlan {
        let key: ModeTargetKey, members: [Conversation], current: String, scheme: Scheme
        let layout: AutoLayout, order: [String]
        var columns: [(ColumnNode, ColumnNode.Snapshot)] = []
        var headers: [ModeHeaderEndpoint] = []
        var dockEndpoints: [(id: String, conversation: Conversation, rect: CGRect, absorbed: Bool)] = []
        var nextColumn = 0
        var dockPrepared=false
        var preparedHeaders:Set<String>=[]
        var preparedLateSelection=false
        var ready: Bool { nextColumn == layout.columns.count && dockPrepared }
        var me: CGRect { layout.me }
        init(key: ModeTargetKey, members: [Conversation], current: String, scheme: Scheme, layout: AutoLayout, order: [String]) {
            self.key=key; self.members=members; self.current=current; self.scheme=scheme; self.layout=layout; self.order=order
        }
    }
    private func modeTargetKey(_ selected: String) -> ModeTargetKey {
        let targetMembers = members.contains { $0.id == selected } ? members : members + [store.conversation(selected)].compactMap { $0 }
        return .init(size:size, scale:scale, appearance:NativeAppearance.revision, display:NativeDisplayOptions.shared.revision,
                     sourceCurrent:current,selected:selected,focus:focusTarget,scheme:scheme, members:targetMembers.map(\.id),
                     models:targetMembers.map(ObjectIdentifier.init), revisions:targetMembers.map(\.revision))
    }
    func beginModeTarget(selected: String) -> ModeTargetPlan? {
        guard !isMoving, !composingNew, let selectedModel=conversation(selected), !selectedModel.archived else { return nil }
        let key=modeTargetKey(selected)
        let nextMembers=key.members.compactMap(store.conversation)
        let targetCurrent=scheme.mode == .auto ? selected:current
        let (next, nextOrder)=arrange(nextMembers,current:targetCurrent)
        let plan=ModeTargetPlan(key:key,members:nextMembers,current:targetCurrent,scheme:scheme,layout:next,order:nextOrder)
        for (i,id) in nextOrder.prefix(next.columns.count).enumerated() {
            guard let c=conversation(id) else{continue}
            let r=carrier(next.columns[i]),full=isFull(id,scheme,current:targetCurrent)
            let variant:HeaderIslandVariant=scheme.mode == .focused ? (scheme.split.count>1 ? .split(focused:id == focusTarget):.full):(full ? .full:.brief)
            let g=HeaderIslandGeometry.make(variant:variant,columnWidth:r.width,state:.init(band:HeaderIslandVariant.band(bleedTop:52),scale:scale))
            plan.headers.append(.init(id:id,conversation:c,rect:g.planet.offsetBy(dx:r.minX,dy:0)))
        }
        for (j,id) in nextOrder.dropFirst(next.columns.count).enumerated() {
            if let c=conversation(id), j<next.orbs.count {plan.dockEndpoints.append((id,c,next.orbs[j],false))}
        }
        return plan
    }
    func modeTargetIsValid(_ plan: ModeTargetPlan) -> Bool {
        let actual=modeTargetKey(plan.key.selected)
        guard modeContentEpochFrozen else {return plan.key == actual}
        let frozen=ModeTargetKey(size:actual.size,scale:actual.scale,appearance:actual.appearance,display:actual.display,
            sourceCurrent:actual.sourceCurrent,selected:actual.selected,focus:actual.focus,scheme:actual.scheme,
            members:actual.members,models:actual.models,revisions:plan.key.revisions)
        return plan.key == frozen
    }
    /// One column per idle slice. No native layout/capture is performed, including for the selected full column.
    @discardableResult func prepareModeTargetStep(_ plan: ModeTargetPlan) -> Bool {
        guard modeTargetIsValid(plan), !plan.ready else { return plan.ready }
        guard plan.nextColumn < plan.layout.columns.count else {
            // Only hidden Dock geometry/labels: never borrow an editor from the visible Normie source.
            if !transcriptsPresented {
                M10ColumnModeProbe.measure("PrewarmOrganicDockGeometry") {
                    let factory=dock.composerFor;dock.composerFor=nil;defer{dock.composerFor=factory}
                    dock.ensureItems(for:plan.members,layout:plan.layout,order:plan.order)
                    dock.relayout(plan.layout,metrics:metrics,order:plan.order.compactMap(conversation),full:[])
                }
            }
            plan.dockPrepared=true;return true
        }
        let i=plan.nextColumn, id=plan.order[i]
        let column=M10ColumnModeProbe.measure("OrganicModeNodePrepare",detail:id) {node(id,slot:i,in:plan.layout,preparingMode:true)}
        let snapshot=column.prepareModeDisplay(fullWidth:fullWidth(i,plan.layout),briefWidth:briefWidth(i,plan.layout),contentTop:fullContentTop(for:plan.scheme))
        plan.columns.append((column,snapshot)); plan.nextColumn += 1
        // Configure only an invisible Organic header. Never alter the currently displayed Organic endpoint.
        if !transcriptsPresented || !columns.contains(where:{$0 === column}), let island=column.island {
            let full=isFull(id,plan.scheme,current:plan.current)
            let variant:HeaderIslandVariant=plan.scheme.mode == .focused ? (plan.scheme.split.count>1 ? .split(focused:id == focusTarget):.full):(full ? .full:.brief)
            M10ColumnModeProbe.measure("OrganicModeHeaderPrepare",detail:id) {
                column.configureIsland(variant,width:carrier(plan.layout.columns[i]).width)
                column.placeIsland(carrier(plan.layout.columns[i]),shown:!transcriptsPresented)
            }
            plan.preparedHeaders.insert(id)
            let glass=island.orb.glassView
            if let index=plan.headers.firstIndex(where:{$0.id==id}) {plan.headers[index] = .init(id:id,conversation:column.conversation,rect:glass.convert(glass.bounds,to:nativePlane))}
        }
        return plan.ready
    }
    /// Prepare an unused selected viewport at its final geometry, while its frozen epoch is retained.
    /// A visible column is never moved here; this is the late-selection path after the body fade ends.
    @discardableResult func prepareHiddenModeSelection(_ plan:ModeTargetPlan,id:String)->Bool {
        guard plan.ready,modeTargetIsValid(plan),modeContentEpochFrozen,transcriptsPresented,
              transcriptSessions?.modeContentNativeAdmissionAllowed == true,
              let index=plan.columns.firstIndex(where:{$0.0.conversation.id == id}) else {return false}
        let (column,snapshot)=plan.columns[index]
        guard column.native.isHiddenOrHasHiddenAncestor || column.native.superview == nil else {return true}
        let rect=snapshot.area.offsetBy(dx:carrier(plan.layout.columns[index]).minX,dy:carrier(plan.layout.columns[index]).minY)
        var mounted=false
        CATransaction.begin();CATransaction.setDisableActions(true);defer {CATransaction.commit()}
        column.native.isHidden=true
        column.native.configurePresentation(allowHidden:true) {
            mounted=column.mountNative(in:nativePlane,configuration:transcriptConfiguration(for:column.conversation,composer:composer(for:column.conversation)),frame:rect,visible:false)
        }
        if mounted {plan.preparedLateSelection=true}
        return mounted
    }
    /// A complete source picture covers both phases. Run the Dock's native commit on a separate display turn.
    func finishModeContentDockCommit() {
        dock.ensureItems(for:members,layout:layout,order:order)
        M10ColumnModeProbe.measure("OrganicModeDockCommit") {
            dock.settleContent(full:fullIDs)
            dock.remountComposers()
        }
        updateStatus()
        DispatchQueue.main.async { [weak self] in self?.requestPrewarm() }
    }
    /// The caller has preserved the source. Mount just visible full viewports at their FINAL frame, once.
    /// NativeTranscript's existing configurePresentation batches policy + geometry into one final-width refresh.
    @discardableResult func commitModeTarget(_ plan: ModeTargetPlan,includeDock:Bool=true) -> Bool {
        guard plan.ready, modeTargetIsValid(plan), transcriptSessions?.canHandoff != false else { return false }
        return M10ColumnModeProbe.measure("OrganicModeCommit") {
            cancelIdlePreparation();prewarmTask?.cancel(); prewarmTask=nil; prewarmRequested=false; prewarmScheduled=false; prewarmQueue=nil
            for p in prewarmed.values { unstage(p) }; prewarmed=[:];lastPrewarmClear="commitModeTarget"
            let nextNodes=plan.columns.map { $0.0 }
            // The frozen epoch already owns unchanged brief columns. Reapplying their glyph trees
            // is work unrelated to the selected viewport and would also expose a newer store summary.
            let preservedBriefs:Set<ObjectIdentifier> = plan.preparedLateSelection && modeContentEpochFrozen
                ? Set(plan.columns.enumerated().compactMap {i,pair in
                    let (column,snapshot)=pair,id=column.conversation.id
                    guard columns.contains(where:{$0 === column}),!isFull(id),!isFull(id,plan.scheme,current:plan.current),
                          column.rect.target == carrier(plan.layout.columns[i]),column.nativeArea == snapshot.area,
                          column.applied?.visual == snapshot.key.visual,column.scale == plan.key.scale,
                          column.form.duration == 0,column.presence.duration == 0,!column.hasFullReflow,!column.isPromoting else {return nil}
                    return ObjectIdentifier(column)
                }):[]
            for old in columns where !nextNodes.contains(where:{$0 === old}) {
                old.unmountNative(); old.card.removeFromSuperlayer();old.separator.removeFromSuperlayer();old.island?.isHidden=true
            }
            members=plan.members;current=plan.current;scheme=plan.scheme;layout=plan.layout;order=plan.order
            sunHover?.refreshData()
            transcriptsPresented=true; columns=nextNodes
            for column in columns { column.island?.setPulsePresentationRetired(false) }
            CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
            for (i,pair) in plan.columns.enumerated() {
                let (column,snapshot)=pair, full=isFull(column.conversation.id)
                if preservedBriefs.contains(ObjectIdentifier(column)) {
                    column.separator.opacity=i<columns.count-1 ? 1:0
                    continue
                }
                column.reshape(sceneHeight:size.height,logicalBottom:layout.columns[i].maxY)
                column.removeAnimations();column.rect = .rest(carrier(layout.columns[i]));column.form = .rest(full ? 1:0);column.presence = .rest(1)
                if column.card.superlayer == nil {cards.addSublayer(column.card);cards.addSublayer(column.separator)}
                // place() also places the native viewport. A staged selection already has its final
                // frame: do not lay it out at the node's old/empty nativeArea before applying this snapshot.
                if plan.preparedLateSelection {column.nativeArea=snapshot.area}
                column.showPresent();column.place(column.rect.target,form:column.form.to)
                if full {
                    let rect=snapshot.area.offsetBy(dx:column.rect.target.minX,dy:column.rect.target.minY)
                    column.native.configurePresentation {
                        _=column.mountNative(in:nativePlane,configuration:transcriptConfiguration(for:column.conversation,composer:composer(for:column.conversation)),frame:rect)
                        column.apply(snapshot);column.showRest(full:true)
                    }
                } else {
                    // A late member intent retains unchanged hidden brief owners instead of tearing
                    // them down now and rebuilding them in endModeHandoff on the following frame.
                    if !plan.preparedLateSelection || !column.ownsNative {column.unmountNative()}
                    column.apply(snapshot);column.showRest(full:false)
                }
                column.separator.opacity=i<columns.count-1 ? 1:0
            }
            applyCardBands()
            for column in columns {
                if !plan.preparedHeaders.contains(column.conversation.id) {
                    column.configureIsland(islandVariant(for:column.conversation.id),width:column.rect.target.width)
                    column.placeIsland(column.rect.target,shown:true)
                } else {column.island?.isHidden=false}
            }
            for column in nodes.values where !columns.contains(where:{$0 === column}) {column.island?.isHidden=true}
            if includeDock {finishModeContentDockCommit()}
            return true
        }
    }
}

@MainActor struct ModeHeaderEndpoint {
    let id: String, conversation: Conversation, rect: CGRect
    var tokenID: String { "header." + id }
}
