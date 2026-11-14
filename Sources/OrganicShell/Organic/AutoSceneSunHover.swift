import AppKit
import QuartzCore

@MainActor final class SunHoverController {
    private weak var scene: AutoScene?
    let node = SunHoverNode()
    private(set) var state: SunHoverState
    private var panelMotion = SunHoverPanelMotion(source: .zero)
    let cache = SunHoverAttentionCache()
    var attention: SunHoverAttentionProjection { cache.projection }
    var attentionSnapshot: SunHoverAttention { cache.value }
    private(set) var usage: AccountUsage
    private var clock: (any SunHoverFrameDriving)?
#if M1139_CHECK
    var frameDriverFactory: ((NSView, @escaping () -> Void) -> (any SunHoverFrameDriving)?)?
    var verificationHasMotion: Bool { state.needsFrames || (panelVisible && panelMotion.needsFrames(at: now())) }
    private(set) var verificationPointerWork = 0
#endif
    private var timer: Timer?, monitor: Any?
    private var notifications: [NSObjectProtocol] = [], windowNotifications: [NSObjectProtocol] = []
    private var displayObservation: UUID?
    var accountObservation: AccountUsageObservation?
    private weak var window: NSWindow?
    private var windowToken = UUID(), generation = 0
    private var panelKind: SunHoverPanel?, panelVisible = false, contentDirty = true
    private(set) var panelSource = CGPoint.zero
    private var pointer: CGPoint?
    private var rendering = false, disposed = false, framesActive = false, retired = true, dragFolding = false
    private var lastUsageKey = ""
    private var memberIDs: Set<String> = []
    private var idleEntryBounds = CGRect.null
    private(set) var nativeTicks = 0, timerDeliveries = 0, monitorEvents = 0, retireWork = 0, pointerTransitions = 0
    private(set) var lastEventConsumed = false
    var isShowing: Bool { !retired }
    static let exposed: Set<SunHoverSatellite> = [.search, .sidebar, .usage, .settings]
    var command: ((SunHoverAction) -> Void)?
    var pointerOverride: (() -> CGPoint?)?
    var now: () -> Double
    init(scene: AutoScene) {
        self.scene = scene; now = { [weak scene] in scene?.now() ?? CACurrentMediaTime() }
        usage = scene.store.accountUsage
        state = SunHoverState(reduceMotion: Motion.reduce, clock: { [weak scene] in scene?.now() ?? CACurrentMediaTime() })
        node.exposed = Self.exposed
        node.mountGlass = { [weak scene] surface in scene?.dock.mountSunHoverGlass([surface]) }
        node.mountRing = { [weak scene] in scene?.dock.mountSunHoverRing($0) }
        node.onPointer = { [weak self] in self?.pointerChanged($0) }
        node.onActivate = { [weak self] in self?.activate($0) }
        node.permits = { [weak self] in self?.canActivate($0) == true }
        node.onWindow = { [weak self] in self?.attach($0) }
        node.frame = scene.overlayPlane.bounds; node.autoresizingMask = [.width, .height]; node.isHidden = true
        scene.overlayPlane.addSubview(node)
        scene.dock.sunHoverBadge = { [weak self] in self?.badge }
        scene.dock.sunHoverTideCanResume = { [weak self, weak scene] in
            guard let self, !self.disposed, let scene else { return false }
            return scene.sunHoverTideDeliveryEnabled
        }
        scene.dock.onMeMeasurementChanged = { [weak self] in self?.geometryChanged() }
        scene.dock.sunHoverBlocksPointer = { [weak self] point in
            guard let self, !self.retired, let geometry = self.geometry, let measurement = self.scene?.dock.meMeasurement else { return false }
            return !self.node.regions(at: point, state: self.state, geometry: geometry, ll: measurement.frame, badge: self.badge != nil, badgeFrame: self.scene?.dock.sunHoverBadgeRect).isEmpty
        }
        displayObservation = OrbDisplayEnvironment.shared.observe { [weak self] in
            guard let self else { return }; self.node.panel.displayOptionsChanged()
            if !self.retired { self.contentDirty = true; self.render() }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: Notification.Name("Organic.ModePreparationInputsChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.disposed else { return }
                if self.retired { self.scene?.dock.resumeSunHoverTide(source: "input") }
                else if self.isBlocked { self.retire() }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retire(resumeTide: false) }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scene?.dock.resumeSunHoverTide(source: "menu") }
        })
        refreshData()
    }
    isolated deinit {
        timer?.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) }; clock?.invalidate()
        accountObservation?.cancel(); (notifications + windowNotifications).forEach(NotificationCenter.default.removeObserver)
        if let displayObservation { OrbDisplayEnvironment.shared.removeObserver(displayObservation) }
    }
    var badge: OrbBadge? { attentionSnapshot.badge }
    private var geometry: SunHoverGeometry? {
        guard let scene, let measurement = scene.dock.meMeasurement else { return nil }
        return .init(llCenter: measurement.center, dockBaseline: measurement.center.y, bounds: scene.overlayPlane.bounds, backingScale: scene.scale)
    }
    private var actualPointer: CGPoint? {
        if let pointerOverride { return pointerOverride() }
        if let window { return window.isKeyWindow ? node.convert(window.mouseLocationOutsideOfEventStream, from: nil) : nil }
        return pointer ?? scene?.lastPointer
    }
    private var isBlocked: Bool {
        guard let scene else { return true }
        let blockingDrag = scene.drag.map { $0.id != DockNode.meID || ($0.began && !dragFolding) } ?? false
        return disposed || scene.modeHandoffActive || !scene.presented || blockingDrag || scene.tearing != nil || scene.isAskingCompare
            || scene.orbInput.isPressed || scene.orbMenu.state.isOpen
            || scene.overlays.values.contains { $0.modelPicker.isShowing || $0.sendOptions.isShowing || $0.capturesSendPress }
            || scene.nodes.values.contains { $0.island?.state.editing == true }
    }
    private func attach(_ next: NSWindow?) {
        guard !disposed, window !== next else { return }
        retire(); window = next; windowToken = UUID()
        windowNotifications.forEach(NotificationCenter.default.removeObserver); windowNotifications = []
        if let next {
            let token = windowToken
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                windowNotifications.append(NotificationCenter.default.addObserver(forName: name, object: next, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { guard let self, self.windowToken == token else { return }; self.retire() }
                })
            }
        }
    }
    func bindAccountUsage(_ observe: (@escaping (AccountUsage) -> Void) -> AccountUsageObservation) {
        accountObservation?.cancel()
        accountObservation = observe { [weak self] in self?.accountChanged($0) }
    }
    func accountChanged(_ value: AccountUsage) {
        guard !disposed, usage != value else { return }
        let liquidChanged = usage.primary.used != value.primary.used || usage.secondary.used != value.secondary.used
        usage = value
        if liquidChanged { scene?.dock.refreshOrbs() }
        if !retired { contentDirty = true; render(); schedule() }
    }
    func refreshData(changed: Conversation? = nil, force: Bool = false) {
        guard !disposed, let scene else { return }
        if changed == nil { memberIDs = Set(scene.members.map(\.id)) }
        let changedValue = cache.update(store: scene.store, members: memberIDs, changed: changed, force: force)
        if changedValue { scene.dock.refreshOrbs() }
        if changedValue || changed == nil { updateIdleEntryBounds() }
        guard !retired else { return }
        let current = scene.scheme.draft ? nil : scene.conversation(scene.focusTarget)
        let used = (current?.exactTokensUsed).map { String($0) } ?? "unreported"
        let limit = (current?.contextLimit).map { String($0) } ?? "unreported"
        let usageKey = "\(current?.id ?? "")|\(used)|\(limit)|\(scene.scheme.draft)"
        let usageChanged = state.mode == .panel(.usage) && usageKey != lastUsageKey
        if changedValue && state.mode == .panel(.attention) || usageChanged {
            lastUsageKey = usageKey; contentDirty = true; render(); schedule()
        }
    }
    func reductionChanged() {
        retire(); state = SunHoverState(reduceMotion: Motion.reduce, clock: { [weak self] in self?.now() ?? CACurrentMediaTime() })
    }
    func geometryChanged() {
        updateIdleEntryBounds()
        guard !retired, !disposed, !rendering else { return }
        render(updateDock: false)
        if !dragFolding { pointerChanged(actualPointer) }
    }
    func didInstallDock() { refreshData() }
    private func updateIdleEntryBounds() {
        guard let measurement = scene?.dock.meMeasurement else { idleEntryBounds = .null; return }
        let ll = measurement.frame
        idleEntryBounds = ll.insetBy(dx: min(0, (ll.width - 48) / 2), dy: min(0, (ll.height - 48) / 2))
        if badge != nil { idleEntryBounds = idleEntryBounds.union(SunHoverNode.badgeHitRect(scene?.dock.sunHoverBadgeRect ?? SunHoverNode.badgeRect(ll: ll))) }
    }
    func pointerChanged(_ point: CGPoint?) {
        guard !disposed else { return }
        pointer = point
        if retired && !(point.map { idleEntryBounds.contains($0) } ?? false) {
            if state.suppressed || !state.regions.isEmpty { state.pointer(in: []) }
            return
        }
#if M1139_CHECK
        verificationPointerWork += 1
#endif
        guard let scene, let geometry, let measurement = scene.dock.meMeasurement else { return }
        guard !dragFolding, !isBlocked, window?.isKeyWindow != false else { if !retired && !dragFolding { retire() }; return }
        let next = node.regions(at: point, state: state, geometry: geometry, ll: measurement.frame, badge: badge != nil, badgeFrame: scene.dock.sunHoverBadgeRect)
        guard next != state.regions || (state.suppressed && !next.contains(.ll)) else { return }
        pointerTransitions += 1
        state.pointer(in: next)
        if retired && (state.mode != .idle || (!state.suppressed && state.regions.contains(.ll))) { begin() }
        if retired && state.mode == .idle { return }
        synchronizeMode(); render(); schedule()
    }
    private func begin() {
        retired = false; node.isHidden = false
        holdDockPose()
        scene?.peekTimer?.cancel(); scene?.peekTimer = nil; scene?.dismissPeek()
        scene?.dock.beginSunHoverTideDeferral()
        scene?.orbHint.cancel(); scene?.meController.dismiss()
    }
    func llClick() {
        guard !isBlocked else { return }
        state.pointer(in: [.ll]); state.llClick()
        if retired { begin() }
        synchronizeMode(); render(); schedule()
    }
    func dragBegan() {
        guard !retired, let scene else { return }
        dragFolding = true; scene.dock.takeSunHoverDiameterForDrag()
        state.dragBegan(); synchronizeMode(); render(); schedule()
    }
    private var access: SunHoverAccess {
        .init(account: usage, available: command == nil ? [.usage, .settings] : Self.exposed,
              disabledInLayout: scene?.scheme.mode == .focused ? [.newChat] : [],
              accountActions: command == nil ? [] : [.profile, .settings, .shortcuts, .collapse, .signOut])
    }
    private func canActivate(_ key: SunHoverSatellite) -> Bool { Self.exposed.contains(key) && !isBlocked && access.satellites[key.rawValue].enabled }
    func activate(_ key: SunHoverSatellite) {
        guard canActivate(key), state.canClick(key) else { return }
        let action = state.click(key); synchronizeMode(); render(); schedule()
        if let action { dispatch(action) }
    }
    private func dispatch(_ action: SunHoverAction) {
        guard let scene else { return }
        if case .conversation(let id) = action {
            let ids = Set(scene.members.map(\.id))
            guard let selected = attention.snapshot(store: scene.store, memberIDs: ids, at: Date().timeIntervalSince1970).rows.first(where: { $0.conversationID == id }) else {
                refreshData(force: true); synchronizeMode(); render(); schedule(); return
            }
            retire(resumeTide: false)
            let before = scene.generation
            if !scene.scheme.draft, scene.scheme.mode == .focused, scene.scheme.split.contains(id), scene.focusTarget != id {
                scene.focusMember(id)
            } else if scene.scheme.draft || scene.focusTarget != id { scene.swapOrb(id) }
            let shown = !scene.scheme.draft && (scene.focusTarget == id || (scene.generation != before && scene.fullIDs.contains(id)))
            if shown {
                _ = attention.activate(id, store: scene.store, memberIDs: ids, at: Date().timeIntervalSince1970)
                for sourceID in Set(selected.events.filter { $0.severity <= .runningError }.map(\.sourceID)) {
                    if let source = scene.store.conversation(sourceID) { scene.store.changed(source) }
                }
            }
            refreshData(force: true)
            scene.dock.resumeSunHoverTide(source: "command")
        } else { retire(resumeTide: false); command?(action); scene.dock.resumeSunHoverTide(source: "command") }
    }
    private var wantsDockHold: Bool {
        state.mode != .idle || state.needsFrames || (!state.suppressed && state.regions.contains(.ll))
    }
    private func holdDockPose() {
        if !retired && wantsDockHold {
            scene?.dock.beginSunHoverDockHold(at: now())
        }
    }
    private func synchronizeMode() {
        holdDockPose()
        guard let geometry else { return }
        let next: SunHoverPanel? = { if case .panel(let kind) = state.mode { return kind }; return nil }()
        if next != panelKind {
            contentDirty = true
            if let next {
                panelVisible = true
                let source: CGPoint
                if next == .usage, let frame = node.satelliteFrames[.usage] { source = CGPoint(x: frame.midX, y: frame.midY) }
                else if next == .attention { source = CGPoint(x: geometry.llCenter.x + 17, y: geometry.llCenter.y - 17) }
                else { source = geometry.llCenter }
                panelSource = source
                panelMotion.show(next, source: source, geometry: geometry, attentionCount: attentionSnapshot.conversationCount, accountHeight: SunHoverPanelView.accountHeight, at: now())
            } else { panelMotion.close(at: now()) }
            panelKind = next
        }
        if state.mode != .idle { installMonitor() }
    }
    private func render(updateDock: Bool = true) {
        guard !retired, !disposed, !rendering, let scene else { return }
        rendering = true; defer { rendering = false }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        if updateDock { scene.dock.setSunHover(diameterDelta: dragFolding ? 0 : 6 * state.sun.value(at: now()), label: usage.percentage, mix: state.number.value(at: now()), at: now()) }
        guard let geometry, let measurement = scene.dock.meMeasurement else { return }
        var titles = access.satellites.map(\.title); titles[4] = "Usage " + usage.percentage
        node.sample(state: state, geometry: geometry, diameter: measurement.diameter, usage: usage, titles: titles)
        let pose = panelMotion.pose(at: now(), geometry: geometry)
        node.panel.frame = pose.rect; node.panel.glass.cornerRadius = pose.radius
        node.panel.alphaValue = pose.opacity; node.panel.isHidden = !panelVisible || pose.opacity < 0.001
        if let panelKind, contentDirty {
            contentDirty = false
            let current = scene.scheme.draft ? nil : scene.conversation(scene.focusTarget)
            let identities = Dictionary(uniqueKeysWithValues: scene.members.map { ($0.id, orbIdentity(of: $0)) })
            let rows = node.panel.configure(kind: panelKind, access: access, usage: .init(account: usage, current: current), attention: attentionSnapshot, identities: identities)
            state.setPanelRows(rows)
            node.panel.activate = { [weak self] action in
                guard let self, self.state.mode == .panel(panelKind), let row = self.node.panel.rows.first(where: { $0.actionValue == action }), self.state.rowVisibility(row.id, at: self.now()) > 0.5 else { return }
                if case .conversation(let id) = action {
                    guard self.state.selectConversation(id, isStillActionable: { [weak self] id in self?.attentionSnapshot.rows.contains { $0.conversationID == id } == true }) != nil else { return }
                } else if !self.access.accountItems.contains(where: { $0.action == action && $0.enabled }) { return }
                self.dispatch(action)
            }
        }
        node.panel.layoutSubtreeIfNeeded(); node.panel.sampleRows(state: state)
        pointerShield.reconcile()
    }
    private lazy var pointerShield: NativePointerShield = {
        let shield = NativePointerShield(plane: node)
        if let scene { shield.setScopes([scene.nativePlane, scene.dockView, scene.peekNode.view]) }
        shield.pointer = { [weak self] in self?.actualPointer }
        shield.contains = { [weak self] point in
            guard let self, !self.retired else { return false }
            return self.node.target(at: point) != nil || (!self.node.panel.isHidden && self.node.panel.frame.contains(point))
        }
        return shield
    }()
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard !disposed, !retired else { return }
        if state.needsFrames || (panelVisible && panelMotion.needsFrames(at: now())) {
            if clock == nil, scene?.manualSettle != true {
                let next = makeFrameDriver { [weak self] in guard let self else { return }; self.nativeTicks += 1; self.advance() }
                guard let next, next.isRunning else { next?.invalidate(); retire(); return }
                clock = next
            }
            framesActive = true
        } else {
            framesActive = false; clock?.invalidate(); clock = nil
            if state.mode == .idle && !wantsDockHold { finish() }
        }
        if let deadline = state.nextDeadline, scene?.manualSettle != true, !retired {
            let token = windowToken, captured = generation
            let next = Timer(timeInterval: max(0.001, deadline - now()), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }; self.timerDeliveries += 1
                    guard self.windowToken == token, self.generation == captured, !self.disposed else { return }
                    self.timer = nil; self.advance()
                }
            }
            timer = next; RunLoop.main.add(next, forMode: .common)
        }
    }
    private func makeFrameDriver(_ deliver: @escaping () -> Void) -> (any SunHoverFrameDriving)? {
#if M1139_CHECK
        if let frameDriverFactory { return frameDriverFactory(node, deliver) }
#endif
        return SunHoverViewFrameDriver(view: node, deliver: deliver)
    }
    func advance() {
        guard !disposed, !retired else { return }
        if isBlocked { retire(); return }
        state.tick(); synchronizeMode(); render(); schedule()
    }
    private func installMonitor() {
        guard monitor == nil, let window = node.window else { return }
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .pressure]) { [weak self] event in
            guard let self, event.window === self.window else { return event }; self.monitorEvents += 1
            let result: NSEvent? = {
            if event.type == .pressure { return nil }
            if self.isBlocked { self.retire(); return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    if let input = self.window?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return event }
                    return self.escape() ? nil : event
                }
                if event.modifierFlags.contains(.command) { self.retire() }; return event
            }
            if event.type == .scrollWheel { return event }
            let point = self.node.convert(event.locationInWindow, from: nil)
            if self.scene?.isMe(at: point) == true { return event }
            if self.node.target(at: point) != nil || !self.node.panel.isHidden && self.node.panel.frame.contains(point) { return event }
            // A planet press must reach the shared input owner; an outside-click dismissal cannot eat pickup.
            if event.type == .leftMouseDown,let scene=self.scene,
               scene.orbInputTarget(at:scene.dockView.convert(event.locationInWindow,from:nil)) != nil {
                scene.orbInput.yieldSunHoverPress();self.retire(resumeTide:false);return event
            }
            if self.state.outsideClick() { self.state.pointer(in: []); self.synchronizeMode(); self.render(); self.schedule(); return nil }
            return event
            }()
            self.lastEventConsumed = result == nil
            return result
        }
    }
    private func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    @discardableResult func escape() -> Bool {
        switch state.escape() {
        case .ignored: return false
        case .cancelComposition: return true
        case .closedLayer: synchronizeMode(); render(); schedule(); return true
        }
    }
    private func finish(resumeTide: Bool = true) {
        node.retire(); node.isHidden = true; panelKind = nil; panelVisible = false
        removeMonitor(); retired = true; dragFolding = false
        scene?.dock.setSunHover(diameterDelta: 0, label: usage.percentage, mix: 0, at: now())
        pointerShield.reconcile(); scene?.dock.endSunHoverTideDeferral(resume: resumeTide)
        if let scene {
            let t = now(), duration = scene.dock.endSunHoverDockHold(at: now(), pointer: actualPointer)
            if duration > 0 { scene.runClock(until: t + duration) }
        }
    }
    func retire(resumeTide: Bool = true) {
        guard !retired else { return }
        retireWork += 1
        let suppress: Bool
        if let geometry, let scene, let measurement = scene.dock.meMeasurement {
            suppress = node.regions(at: actualPointer, state: state, geometry: geometry, ll: measurement.frame, badge: badge != nil, badgeFrame: scene.dock.sunHoverBadgeRect).contains(.ll)
        } else { suppress = false }
        generation += 1; timer?.invalidate(); timer = nil; removeMonitor(); clock?.invalidate(); clock = nil; framesActive = false
        state.retire(suppressUntilExit: suppress); panelMotion.close(at: now()); finish(resumeTide: resumeTide)
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; retire(resumeTide: false)
        accountObservation?.cancel(); accountObservation = nil
        (notifications + windowNotifications).forEach(NotificationCenter.default.removeObserver); notifications = []; windowNotifications = []
        if let displayObservation { OrbDisplayEnvironment.shared.removeObserver(displayObservation) }; displayObservation = nil
        scene?.dock.onMeMeasurementChanged = nil; scene?.dock.sunHoverBadge = nil; scene?.dock.sunHoverBlocksPointer = nil
        scene?.dock.sunHoverTideCanResume = nil; pointerOverride = nil
#if M1139_CHECK
        frameDriverFactory = nil
#endif
        node.dispose()
    }
    var readout: [String: Any] {
        ["phase": String(describing: state.mode), "satellites": node.visibleSatellites.map(\.rawValue), "labels": node.visibleLabels.map(\.rawValue),
         "panel": panelKind?.rawValue ?? "none", "pickerPhase": "unavailable", "pickerRows": 0, "dealPhase": "unavailable", "dealOwner": "none",
         "draftID": scene?.scheme.draft == true ? AutoScene.draftID : "none", "timers": timer == nil ? 0 : 1, "monitors": monitor == nil ? 0 : 1,
         "displayLinks": clock?.isRunning == true ? 1 : 0, "dockHeld": scene?.dock.sunHoverDockHeld == true, "generation": generation, "windowToken": windowToken.uuidString,
         "attentionCount": attentionSnapshot.badgeCount, "attentionIDs": attentionSnapshot.rows.map(\.conversationID), "projections": cache.projections,
         "samples": node.samples, "axBuilds": node.axBuilds, "inkBuilds": node.inkBuilds, "nodeHidden": node.isHidden, "nativeTicks": nativeTicks, "timerDeliveries": timerDeliveries,
         "monitorEvents": monitorEvents, "lastEventConsumed": lastEventConsumed, "retireWork": retireWork, "pointerTransitions": pointerTransitions, "suppressed": state.suppressed, "accountVersion": usage.version,
         "llFrame": scene?.dock.meMeasurement.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
         "panelFrame": node.panel.isHidden ? [] : [node.panel.frame.minX, node.panel.frame.minY, node.panel.frame.width, node.panel.frame.height]]
    }
}

extension AutoScene {
    var sunHoverTideDeliveryEnabled: Bool { presented && !isMoving && !modeHandoffActive && (verificationPresented ?? (restOnSnapshot || sceneView.window?.isKeyWindow != false)) }
    var sunHoverReadout: [String: Any] { sunHover?.readout ?? ["phase": "unavailable", "timers": 0, "monitors": 0, "displayLinks": 0] }
}
