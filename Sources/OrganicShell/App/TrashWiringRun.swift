import AppKit
import QuartzCore
import Darwin
import CoreGraphics

/// A mock-only recording driver. All gestures use InputRun's posted AppKit events.
/// Fixture configuration pauses the mock and isolates the education preference; it never edits scene membership or Scheme.
@MainActor final class TrashWiringRun {
    struct IO {
        let prepare: () -> Void
        let press: (CGPoint) async -> Void
        let carry: (CGPoint, Double) async -> Void
        let release: () -> Void
        let mouse: (NSEvent.EventType, CGPoint) -> Void
        let key: (UInt16, String, NSEvent.ModifierFlags) -> Void
        let pointer: () -> CGPoint
        let activate: () -> Void
        let sleep: (Double) async -> Void
        let sync: () async -> Void
        let log: (String, [String: Any]) -> Void
    }
    struct Summary { let ran: Int, skipped: Int, findings: Int, checks: Int; let seconds: Double }
    enum Source: String, CaseIterable { case dock, full, brief, side, parked, peek }
    private static let stepNames = Source.allCases.map { "source." + $0.rawValue } + [
        "tide.drag", "tide.short-click", "tide.text-drag", "tide.right-menu",
        "undo-glyph", "armed-pull-away", "hit.orb.inner-2", "hit.orb.outer+2", "hit.arm.inner-2", "hit.arm.outer+2",
        "hover.tide", "hover.ll", "menu.remove", "tide.inactive-first-mouse", "final-cleanup"
    ]
    private struct Target { let id: String; let point: CGPoint }
    private struct Snapshot {
        let members: Set<String>, order: [String], columns: [String], hidden: Set<String>
        let current: String, removals: Int, undos: Int, ownershipFailures: Int
    }
    private struct Notice { let id: String, turn: String }
    private let app: AppController, window: OrganicWindow, io: IO
    private let only: [String]
    private var scene: AutoScene { window.scene }
    private var ran = 0, skipped = 0, findings = 0, checks = 0
    private var step = "setup", stepChecks = 0, stepFindings = 0
    private var began = 0.0, deadline = 0.0, serial = 0
    private var observation: Task<Void, Never>?, monitor: Any?
    private var signature = "", sawPickup = false, sawFree = false
    private var baseTrashChildren: Set<ObjectIdentifier> = []
    private var activeNotice: Notice?
    private var initial: Snapshot?
    private var inputStopped = false

    init(app: AppController, window: OrganicWindow, io: IO) {
        self.app = app; self.window = window; self.io = io
        only = (ProcessInfo.processInfo.environment["TRASH_WIRING_ONLY"] ?? "").split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func selected(_ name: String) -> Bool {
        name == "final-cleanup" || only.isEmpty || only.contains { name.hasPrefix($0) }
    }

    func run() async -> Summary {
        began = CACurrentMediaTime(); deadline = began + 325
        guard !app.o.usesLiveCore, !app.store.usesLiveCore,
              let runtime = app.runtime as? MockConversationRuntime, let replay = app.mock,
              runtime.store === app.store, runtime.replay === replay, replay.canPlay,
              !app.store.conversations.contains(where: \.isLiveConversation) else {
            begin("refused"); check(false, "A mock-only store, replay and runtime are required"); end()
            return summary()
        }
        guard !OrganicFeatureAvailability.current.conversationOrbTear,
              ProcessInfo.processInfo.environment["INPUT_INACTIVE"] != "1" else {
            begin("refused"); check(false, "Tear must be disabled and INPUT_INACTIVE must be unset"); end()
            return summary()
        }
        let unknown = only.filter { prefix in !Self.stepNames.contains { $0.hasPrefix(prefix) } }
        guard unknown.isEmpty else {
            begin("refused"); check(false, "ONLY prefixes must match known step names", ["unknown": unknown]); end(); return summary()
        }
        io.prepare()
        let suiteName = "M1137.TrashWiring." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            begin("refused"); check(false, "Cannot create isolated preference suite"); end(); return summary()
        }
        let preferences = scene.orbTrash.preferences
        scene.orbTrash.preferences = OrganicRemovePreferences(defaults: defaults)
        defer {
            observation?.cancel(); observation = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let notice = activeNotice { complete(notice) }
            scene.orbTrash.preferences = preferences
            defaults.removePersistentDomain(forName: suiteName)
        }
        replay.setPaused(true)
        for c in app.store.conversations where c.running { replay.stop(c) }
        io.activate(); await pause(0.8)
        if window.shell.mode != .organic { io.key(1, "s", [.control, .command]); await pause(2) }
        guard window.shell.mode == .organic, window.window.isKeyWindow else {
            begin("refused"); check(false, "An Organic key window is required"); end(); return summary()
        }
        baseTrashChildren = Set(scene.orbTrash.presentation.view.subviews.map(ObjectIdentifier.init))
        installObservation()
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        record("baseline", ["members": scene.members.map(\.id), "size": [scene.size.width, scene.size.height],
                            "machNumer": timebase.numer, "machDenom": timebase.denom,
                            "syntheticCursor": true, "systemPressedButtons": NSEvent.pressedMouseButtons,
                            "reduceMotion": Motion.reduce, "mock": true, "maxSeconds": 325,
                            "only": only, "selectedSteps": Self.stepNames.filter { selected($0) }])
        await io.sync()
        await pause(min(10, max(0, Double(ProcessInfo.processInfo.environment["INPUT_LEAD"] ?? "") ?? 3)))
        await clearSurfaces()
        initial = snapshot()

        for kind in Source.allCases {
            guard selected("source." + kind.rawValue) else { continue }
            guard budget() else { skip("source." + kind.rawValue, inputStopReason); continue }
            begin("source." + kind.rawValue)
            if let target = await prepare(kind) { await removeAndUndo(target) }
            else { unavailable("No eligible " + kind.rawValue + " source through the product UI") }
            end(); await between()
        }
        await tideCases(["drag", "short-click", "text-drag", "right-menu"])
        await undoAndDisarm()
        await hitCases()
        await hoverCases()
        await menuRemove()
        // Last input step: without HID input the WindowServer does not hand key focus back after a resign,
        // even though AppKit reports the app active (w1g key-attempt diagnostics).
        await tideCases(["inactive-first-mouse"])
        if activeNotice != nil { _ = await finishTide() }
        if !inputStopped { _ = await auto() }
        begin("final-cleanup")
        if let initial {
            check(Set(scene.members.map(\.id)) == initial.members, "The full sequence preserves its original membership after every Undo")
            checkCleanup(before: initial)
        }
        end()
        record("summary", ["ran": ran, "skipped": skipped, "findings": findings, "checks": checks,
                           "seconds": CACurrentMediaTime() - began, "mock": true, "inputStopped": inputStopped])
        return summary()
    }

    private func summary() -> Summary {
        .init(ran: ran, skipped: skipped, findings: findings, checks: checks, seconds: CACurrentMediaTime() - began)
    }
    private var inputStopReason: String { inputStopped ? "Window did not regain key; subsequent input stopped" : "Recording time budget exhausted" }
    private func budget() -> Bool { !inputStopped && CACurrentMediaTime() < deadline - 8 }
    private func pause(_ seconds: Double) async { await io.sleep(max(0, min(seconds, deadline - CACurrentMediaTime()))) }
    private func until(_ seconds: Double, _ ready: () -> Bool) async -> Bool {
        let end = min(deadline, CACurrentMediaTime() + seconds)
        while !ready(), CACurrentMediaTime() < end { await pause(1.0 / 60) }
        return ready()
    }
    private func between() async { await pause(0.8) }
    private func begin(_ name: String) {
        step = name; ran += 1; stepChecks = checks; stepFindings = findings
        signature = ""; sawPickup = false; sawFree = false
        record("begin", state())
    }
    private func end() {
        record("end", state().merging(["checks": checks - stepChecks, "findings": findings - stepFindings]) { _, b in b })
    }
    private func skip(_ name: String, _ reason: String) { begin(name); unavailable(reason); end() }
    private func unavailable(_ reason: String) { skipped += 1; ran -= 1; record("skipped", ["reason": reason]) }
    private func check(_ pass: Bool, _ name: String, _ details: [String: Any] = [:]) {
        checks += 1; if !pass { findings += 1 }
        record("check", details.merging(["name": name, "passed": pass]) { _, b in b })
    }
    private func record(_ event: String, _ details: [String: Any] = [:]) {
        var row = details; row["stepName"] = step; row["event"] = event
        row["machTicks"] = String(mach_absolute_time()); row["machSeconds"] = CACurrentMediaTime()
        io.log("trash-wiring " + step + " " + event, row)
    }
    private func installObservation() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window.window else { return }
                self.record("dispatched-event", ["type": event.type.rawValue, "eventTimestamp": event.timestamp,
                                                  "keyCode": event.type == .keyDown ? Int(event.keyCode) : -1,
                                                  "flags": event.modifierFlags.rawValue,
                                                  "keyWindow": self.window.window.isKeyWindow])
            }
            return event
        }
        observation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                await self.io.sleep(1.0 / 60)
            }
        }
    }
    private func sample() {
        let trash = scene.orbTrash, phase = trash.state.phase.rawValue, owner = trash.output?.pose.owner.rawValue ?? "none"
        let next = "\(phase)/\(owner)/\(scene.orbInput.isPressed)/\(scene.isDragging)/\(scene.drag?.freeCarry == true)"
        if next != signature { signature = next; record("observed-transition", state()) }
        if trash.state.phase == .emerging { record("undo-frame", state()) }
        if scene.isDragging && !sawPickup { sawPickup = true; record("pickup-observed", state()) }
        if scene.drag?.freeCarry == true && !sawFree { sawFree = true; record("row-exit-observed", state()) }
    }
    private func state() -> [String: Any] {
        let t = scene.orbTrash, p = io.pointer(), pose = t.output?.pose
        return ["members": scene.members.map(\.id), "columns": scene.columns.map { $0.conversation.id },
                "current": scene.current, "pressed": scene.orbInput.isPressed, "dragging": scene.isDragging,
                "freeCarry": scene.drag?.freeCarry ?? false, "carrying": t.isCarrying,
                "phase": t.state.phase.rawValue, "owner": pose?.owner.rawValue ?? "none",
                "pointer": [p.x, p.y], "can": pose.map { rect($0.can) } ?? [],
                "carrier": pose.map { rect($0.carrier) } ?? [],
                "red": pose?.redTint ?? 0, "glyphAlpha": pose?.glyphAlpha ?? 0, "iconAlpha": pose?.iconAlpha ?? 0,
                "removals": t.successfulRemovals, "undos": t.successfulUndos, "journalStarted": t.journal.started,
                "prompt": t.journal.prompt?.rawValue ?? "none", "remaining": t.journal.remaining,
                "proxyHidden": t.presentation.proxy.isHidden, "keyWindow": window.window.isKeyWindow,
                "inputStopped": inputStopped,
                "tideOwner": scene.dock.tideLightProbe["owner"] ?? "none",
                "sunHover": scene.sunHover?.isShowing ?? false]
    }
    private func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    private func center(_ r: CGRect) -> CGPoint { .init(x: r.midX, y: r.midY) }
    private func aim(_ p: CGPoint) -> [String: Any] {
        let q = scene.dockView.convert(p, to: nil)
        let hit = window.window.contentView.flatMap { $0.hitTest(q) }
        return ["at": [p.x, p.y], "hitView": hit.map { String(describing: type(of: $0)) } ?? "none",
                "orbHit": scene.orbInputTarget(at: p) ?? "none"]
    }
    private func geometry() -> OrbTrashGeometry {
        // Same expression as AutoSceneTrash.step; a local keeps CGFloat -> Double out of the optional chain.
        let last = scene.layout.orbs.max(by: { $0.maxX < $1.maxX })?.midX ?? scene.sizeForOrb.width - 46
        return .init(bounds: scene.dockView.bounds, lastSlotX: last, dockBaseline: scene.layout.me.midY)
    }
    private func hiddenIDs() -> Set<String> {
        Set(scene.dock.items.compactMap { id, item in
            guard !scene.dock.tideOwns(id), scene.shownPeek != id else { return nil }
            let hidden = item.glass.isHidden || item.glass.layer?.isHidden == true
            let paintHidden = item.role == .orb && (item.decoration.frontView.isHidden || item.decoration.backView.isHidden)
            return hidden || paintHidden ? id : nil
        })
    }
    private func snapshot() -> Snapshot {
        .init(members: Set(scene.members.map(\.id)), order: scene.order, columns: scene.columns.map { $0.conversation.id },
              hidden: hiddenIDs(), current: scene.current, removals: scene.orbTrash.successfulRemovals,
              undos: scene.orbTrash.successfulUndos, ownershipFailures: scene.orbTrash.ownershipFailures)
    }
    private func checkCleanup(before: Snapshot) {
        let t = scene.orbTrash, extra = Set(t.presentation.view.subviews.map(ObjectIdentifier.init)).subtracting(baseTrashChildren)
        let hidden = hiddenIDs().subtracting(before.hidden)
        let carried = scene.columns.compactMap(\.island).filter(\.orbIsCarried)
        let panels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible && !$0.isSheet }
        check(!scene.orbInput.isPressed && scene.drag == nil && !scene.dock.isHolding && !scene.isTearing,
              "Gesture owners are clear", state())
        check(!t.isCarrying && t.state.phase == .hidden && t.presentation.proxy.isHidden
              && t.presentation.allGlass.allSatisfy(\.isHidden) && extra.isEmpty,
              "No carrier, proxy, orphan proxy planes or trash glass", ["extraPlanes": extra.count, "probe": t.presentation.probe])
        check(hidden.isEmpty && carried.isEmpty && scene.dock.headerReturnCount == 0,
              "No newly hidden Dock or carried header orb", ["hidden": Array(hidden), "carried": carried.count])
        check((scene.dock.headerOrbDragging?.phase == .idle || scene.dock.headerOrbDragging == nil)
              && panels.isEmpty && app.windows.count == 1 && !scene.orbMenu.state.isOpen,
              "No header gesture, panel, menu or extra conversation window", ["panels": panels.count, "windows": app.windows.count])
        check(t.ownershipFailures == before.ownershipFailures, "Applied handoffs keep a single owner")
    }
    private func escape() { io.key(53, "\u{1b}", []) }
    private func click(_ p: CGPoint) async { await io.press(p); await pause(0.055); io.release(); await pause(0.12) }
    private func clearSurfaces() async {
        guard !inputStopped else { return }
        io.mouse(.mouseMoved, CGPoint(x: scene.size.width * 0.5, y: scene.size.height * 0.4))
        // Allow each product dismissal to finish before addressing a queued notice.
        for _ in 0..<8 {
            escape(); await pause(0.25)
            let phase = scene.dock.tideLightProbe["phase"] as? String ?? "idle"
            let side = scene.dock.tideSideProbe.contains { $0["active"] as? Bool == true }
            if phase == "idle", !side, !scene.orbMenu.state.isOpen, !scene.peekOpen,
               scene.sunHover?.isShowing != true, !scene.orbInput.isPressed,
               scene.orbTrash.state.phase == .hidden { break }
        }
        await pause(0.65)
    }
    private func auto() async -> Bool {
        await clearSurfaces()
        if scene.isFocused { io.key(36, "\r", [.command, .shift]); await pause(1.4) }
        return !scene.isFocused && !scene.scheme.draft
    }
    private func dockTarget(excluding excluded: Set<String> = []) -> Target? {
        scene.order.compactMap { id -> Target? in
            guard !excluded.contains(id), scene.dock.items[id]?.role == .orb,
                  !scene.dock.tideOwns(id), scene.shownPeek != id,
                  scene.orbTrash.eligibility(id) == nil, let r = scene.orbPose(id) else { return nil }
            return .init(id: id, point: center(r))
        }.first
    }
    private func headerTarget(_ id: String) -> Target? {
        guard let island = scene.columns.first(where: { $0.conversation.id == id })?.island,
              !island.isHiddenOrHasHiddenAncestor, scene.orbTrash.eligibility(id) == nil else { return nil }
        return .init(id: id, point: center(scene.dockView.convert(island.planetButton.bounds, from: island.planetButton)))
    }
    private func prepare(_ kind: Source) async -> Target? {
        guard await auto() else { return nil }
        switch kind {
        case .dock: return dockTarget()
        case .full: return headerTarget(scene.current)
        case .brief: return scene.columns.first(where: { !scene.isFull($0.conversation.id) }).flatMap { headerTarget($0.conversation.id) }
        case .parked:
            guard let id = scene.scheme.parked.first, let r = scene.orbPose(id), scene.orbTrash.eligibility(id) == nil else { return nil }
            return .init(id: id, point: center(r))
        case .side:
            // The product's Split menu key establishes real segments and side banks.
            record("split-menu-key-posted", ["shortcut": "Option-Command-Backslash"])
            io.key(42, "\\", [.command, .option]); await pause(1.5)
            record("split-menu-result", ["focused": scene.isFocused, "segments": scene.scheme.split])
            guard scene.isFocused, scene.scheme.split.count > 1,
                  let id = (scene.scheme.left + scene.scheme.right).first, let r = scene.orbPose(id),
                  scene.orbTrash.eligibility(id) == nil else { return nil }
            return .init(id: id, point: center(r))
        case .peek:
            guard let target = dockTarget(), await choose(.peek, target: target) else { return nil }
            guard await until(1.5, { self.scene.peekNode.headerVisible && self.scene.shownPeek == target.id }) else {
                check(false, "Product Peek command exposes its header endpoint"); return nil
            }
            let button = scene.peekNode.header.planetButton
            return .init(id: target.id, point: center(scene.dockView.convert(button.bounds, from: button)))
        }
    }
    private func choose(_ action: OrbMenuAction, target: Target) async -> Bool {
        record("menu-down-posted", ["id": target.id, "action": action.title])
        io.mouse(.rightMouseDown, target.point); await pause(0.06)
        io.mouse(.rightMouseUp, target.point); await pause(0.2)
        guard scene.orbMenu.state.isOpen, scene.orbMenu.state.enabled(action) else {
            record("menu-unavailable", ["action": action.title, "open": scene.orbMenu.state.isOpen]); escape(); return false
        }
        // Navigate by posted keys, observing the product's selection; never assign menu state.
        for _ in 0..<OrbMenuAction.allCases.count + 1 {
            if scene.orbMenu.state.submenu {
                io.key(123, "\u{f702}", [.function, .numericPad]); await pause(0.025)
            }
            if scene.orbMenu.state.selected == action.rawValue { break }
            io.key(125, "\u{f701}", [.function, .numericPad]); await pause(0.025)
        }
        guard scene.orbMenu.state.selected == action.rawValue else { escape(); return false }
        io.key(36, "\r", []); record("menu-selection-posted", ["action": action.title]); await pause(0.25)
        return true
    }
    private func pickup(_ target: Target) async -> Bool {
        record("down-posted", aim(target.point).merging(["id": target.id]) { _, b in b })
        await io.press(target.point)
        let pressed = await until(0.12, { self.scene.orbInput.isPressed })
        record("down-observed", state())
        guard pressed else {
            check(false, "Posted down reaches the unified orb controller"); escape(); io.release(); await pause(0.8); return false
        }
        let dx: CGFloat = target.point.x < scene.size.width / 2 ? 8.1 : -8.1
        await io.carry(.init(x: target.point.x + dx, y: target.point.y), 0.12)
        record("8pt-crossed", state())
        let grab = scene.drag?.grab ?? .zero, row = scene.drag?.sourceRow ?? target.point.y
        let y = row + grab.y + (row > scene.size.height / 2 ? -45 : 45)
        await io.carry(.init(x: target.point.x + dx, y: y), 0.65)
        record("45pt-row-exit", state())
        check(scene.orbInput.isPressed && scene.drag?.freeCarry == true, "Conversation orb enters free carry after leaving its row")
        return scene.orbInput.isPressed && scene.drag?.freeCarry == true
    }
    private func moveSemantic(_ p: CGPoint, over seconds: Double) async {
        let grab = scene.drag?.grab ?? .zero
        await io.carry(.init(x: p.x + grab.x, y: p.y + grab.y), seconds)
    }
    private func arm() async -> Bool {
        await moveSemantic(geometry().target, over: 0.9)
        let armed = await until(0.5, { self.scene.orbTrash.state.phase == .armed })
        record("arm", state()); check(armed, "Trash is armed while the real press is held")
        await pause(0.6); return armed
    }
    private func undo(_ id: String, dwell: Double = 0) async -> Bool {
        let p = scene.orbTrash.presentation
        guard await until(1, { (!p.undo.isHidden || !p.toastUndo.isHidden) && self.scene.orbTrash.journal.started }) else {
            check(false, "Product Undo button is present and journal has started"); return false
        }
        record("undo-visible", state()); await pause(dwell)
        let button = p.undo.isHidden ? p.toastUndo : p.undo
        let point = center(scene.dockView.convert(button.bounds, from: button))
        record("undo-down-posted", ["id": id, "at": [point.x, point.y]])
        await click(point); record("undo-clicked", state())
        return true
    }
    private func removeAndUndo(_ target: Target, undoDwell: Double = 0, preservingLayout: Bool = false) async {
        let before = snapshot(), object = app.store.conversation(target.id)
        guard await pickup(target), await arm() else {
            escape(); io.release(); await pause(1.2); checkCleanup(before: before); return
        }
        // The shared policy restores the committed position at removal, including any accepted row preview.
        let atDrop = snapshot()
        if preservingLayout {
            check(atDrop.columns == before.columns && atDrop.order == before.order && atDrop.current == before.current,
                  "Tide pickup preserves the pre-press layout through arm")
        }
        record("up-posted", state()); io.release(); await pause(1.2); record("after-remove", state())
        let removed = !scene.members.contains { $0.id == target.id }
        check(removed && scene.orbTrash.successfulRemovals == before.removals + 1, "One release removes exactly this member")
        check(app.store.conversation(target.id) === object && object?.archived == false, "The mock conversation survives unarchived")
        if removed, await undo(target.id, dwell: undoDwell) {
            await pause(max(1.2, undoDwell)); record("after-undo", state())
            check(Set(scene.members.map(\.id)) == before.members && scene.orbTrash.successfulUndos == before.undos + 1,
                  "Undo restores the same member set exactly once")
            let expected = preservingLayout ? before : atDrop
            check(scene.order == expected.order && scene.columns.map { $0.conversation.id } == expected.columns && scene.current == expected.current,
                  preservingLayout ? "Tide Undo restores the pre-press columns, order and current"
                                   : "Undo restores the committed slots, order and current observed at release")
        }
        await pause(0.2); checkCleanup(before: before)
    }

    // MARK: Tide through the product's Core-shaped mock event ingress

    private func emit(_ method: String, _ params: JSONValue) {
        serial += 1
        app.store.apply(.init(id: serial, time: Date().timeIntervalSince1970, method: method, params: params))
    }
    /// Tide borrows only the uninterrupted brief prefix immediately to the left of its orb bank.
    private var tideBriefTail: [String] {
        let bars = scene.dock.restingTargets.filter { $0.bar }.sorted { $0.rect.minX > $1.rect.minX }
        return bars.prefix { scene.dock.items[$0.id]?.full == false }.map { $0.id }
    }
    private var tideIdle: Bool {
        (scene.dock.tideLightProbe["phase"] as? String ?? "idle") == "idle"
            && !scene.dock.tideSideProbe.contains { $0["active"] as? Bool == true }
    }
    private func tideSetupProbe() -> [String: Any] {
        ["focused": scene.isFocused, "current": scene.current, "enabled": scene.sunHoverTideDeliveryEnabled,
         "focusTarget": scene.dock.focusTarget ?? "none", "briefTail": tideBriefTail,
         "bars": scene.dock.restingTargets.filter { $0.bar }.map { target -> [String: Any] in
             let item = scene.dock.items[target.id], editor = item?.composer, c = item?.conversation
             return ["id": target.id, "full": item?.full ?? true, "rect": rect(target.rect),
                     "draft": !(c?.draft.isEmpty ?? true), "attachment": !(c?.attachments.isEmpty ?? true),
                     "editorFocused": editor?.editorFocused ?? false, "markedText": editor?.isComposing ?? false,
                     "choosingAttachment": editor?.isChoosingAttachments ?? false,
                     "submitting": c?.sending ?? false]
         }, "tide": scene.dock.tideLightProbe, "diagnostics": scene.dock.tideAnimationDiagnostics]
    }
    private func prepareTide() async -> Bool {
        guard await auto(), !TideCompositePolicy.control, let first = scene.order.first else {
            check(false, "Primary Tide requires Auto and the product Tide policy", tideSetupProbe()); return false
        }
        guard activeNotice == nil, tideIdle else {
            check(false, "The previous fixture turn and Tide retire before another arrival", tideSetupProbe()); return false
        }
        // Show Conversation 1 is a product menu shortcut. It makes the left column full, leaving briefs next to the bank.
        record("tide-prerequisite-select-first", tideSetupProbe())
        io.key(18, "1", [.command])
        var ready = await until(3, { self.scene.current == first && !self.scene.isMoving && !self.tideBriefTail.isEmpty })
        if !ready {
            // A product Focus round trip can rebuild a stale layout certificate without assigning Scheme or columns.
            io.key(36, "\r", [.command, .shift])
            let focused = await until(3, { self.scene.isFocused && !self.scene.isMoving })
            if focused { io.key(36, "\r", [.command, .shift]) }
            ready = await until(3, { !self.scene.isFocused && !self.scene.isMoving && !self.tideBriefTail.isEmpty })
        }
        guard ready else {
            check(false, "The product menu exposes a rightmost brief for Tide", tideSetupProbe()); return false
        }
        // Move real text focus to the full composer so a previously focused brief can become borrowable.
        if let editor = scene.dock.items[scene.current]?.composer?.textView,
           !editor.isHiddenOrHasHiddenAncestor, !editor.bounds.isEmpty {
            await click(center(scene.dockView.convert(editor.bounds, from: editor)))
        }
        io.mouse(.mouseMoved, CGPoint(x: scene.size.width * 0.5, y: scene.size.height * 0.4))
        await pause(DockSlotLeases.protectionGrace + 0.1)
        record("tide-prerequisites-ready", tideSetupProbe())
        let enabled = scene.sunHoverTideDeliveryEnabled && !scene.isFocused && !tideBriefTail.isEmpty && tideIdle
        check(enabled, "Tide has a contiguous brief, settled layout and enabled delivery", tideSetupProbe())
        return enabled
    }
    private func startTide() async -> Notice? {
        guard await prepareTide(),
              let target = scene.dock.restingTargets.filter({ !$0.bar && !scene.scheme.parked.contains($0.id)
                  && scene.orbTrash.eligibility($0.id) == nil }).sorted(by: { $0.rect.minX < $1.rect.minX }).first,
              app.store.conversation(target.id)?.isLiveConversation == false else { return nil }
        serial = max(serial, Int(CACurrentMediaTime() * 1_000_000))
        let notice = Notice(id: target.id, turn: "trash-wiring-" + UUID().uuidString); activeNotice = notice
        emit("turn/started", ["threadId": .string(notice.id), "turn": ["id": .string(notice.turn)]])
        emit("item/started", ["threadId": .string(notice.id), "turnId": .string(notice.turn),
                              "item": ["id": .string(notice.turn + "-command"), "type": "commandExecution", "command": "Mock trash wiring command"]])
        record("mock-tide-arrival", ["id": notice.id, "turn": notice.turn])
        guard await until(8, {
            let probe = self.scene.dock.tideLightProbe
            let presentation = probe["presentation"] as? [String: Any] ?? [:]
            let width = self.scene.dock.trashCarrier(notice.id)?.rect.width ?? 0
            return probe["owner"] as? String == notice.id && self.scene.dock.tideOwns(notice.id)
                && probe["motionBusy"] as? Bool == false && presentation["interactive"] as? Bool == true
                && width > 80 && presentation["autoLeadRect"] != nil && presentation["haloOnly"] as? Bool != true
        }) else {
            record("tide-timeout", ["id": notice.id, "turn": notice.turn, "tide": scene.dock.tideLightProbe,
                                    "setup": tideSetupProbe(), "timeoutSeconds": 8])
            check(false, "Mock event reaches the product's primary Tide", ["tide": scene.dock.tideLightProbe]); return nil
        }
        await pause(0.3); record("tide-stable", ["tide": scene.dock.tideLightProbe]); return notice
    }
    private func complete(_ notice: Notice) {
        guard app.store.conversation(notice.id)?.activeTurnID == notice.turn else { return }
        emit("turn/completed", ["threadId": .string(notice.id), "turn": ["id": .string(notice.turn), "status": "interrupted"]])
        record("mock-tide-retired", ["id": notice.id, "turn": notice.turn, "fixtureOnly": true])
    }
    @discardableResult private func finishTide() async -> Bool {
        if let notice = activeNotice { complete(notice); activeNotice = nil }
        // Completion still goes through Core-shaped mock input; posted Esc dismisses the remaining finite notice.
        await clearSurfaces()
        let retired = await until(8, { self.tideIdle })
        record("tide-cleanup", ["retired": retired, "activeFixtureTurn": activeNotice?.turn ?? "none",
                                "tide": scene.dock.tideLightProbe])
        check(retired, "The fixture turn completes and Tide is idle before the next step", ["tide": scene.dock.tideLightProbe])
        return retired
    }
    private func tideTarget(_ notice: Notice) -> Target? {
        scene.orbPose(notice.id).map { Target(id: notice.id, point: center($0)) }
    }
    private func tideCases(_ names: [String]) async {
        for name in names {
            guard selected("tide." + name) else { continue }
            guard budget() else { skip("tide." + name, inputStopReason); continue }
            begin("tide." + name)
            guard let notice = await startTide(), let target = tideTarget(notice) else {
                unavailable("No stable primary Tide on an eligible mock Dock orb")
                await finishTide(); end(); await between(); continue
            }
            let before = snapshot()
            switch name {
            case "drag": await removeAndUndo(target, preservingLayout: true)
            case "short-click":
                record("down-posted", state()); await click(target.point); await pause(0.25)
                let presentation = scene.dock.tideLightProbe["presentation"] as? [String: Any] ?? [:]
                check(presentation["pinned"] as? Bool == true, "Short click preserves Tide pin/open behavior", ["presentation": presentation])
                check(!sawPickup && !sawFree && !scene.orbInput.isPressed && !scene.isDragging && !scene.orbTrash.isCarrying,
                      "Short click never enters carry")
                check(Set(scene.members.map(\.id)) == before.members && scene.orbTrash.successfulRemovals == before.removals,
                      "Short click removes nothing")
            case "text-drag":
                if let r = scene.dock.trashCarrier(notice.id)?.rect, r.width > 80 {
                    let p = CGPoint(x: r.maxX - 24, y: r.midY)
                    record("down-posted", ["at": [p.x, p.y], "region": "notice-text"]); await io.press(p)
                    await io.carry(.init(x: p.x - 60, y: p.y), 0.65)
                    record("text-60pt", state())
                    check(!scene.orbInput.isPressed && scene.drag == nil && !scene.orbTrash.isCarrying,
                          "Text drag does not acquire the unified controller while held")
                    io.release(); await pause(0.4)
                    check(!sawPickup && !sawFree && !scene.orbInput.isPressed && !scene.isDragging && !scene.orbTrash.isCarrying,
                          "Tide text never becomes an orb carry")
                    check(Set(scene.members.map(\.id)) == before.members && scene.orbTrash.successfulRemovals == before.removals,
                          "Text drag removes nothing")
                } else { unavailable("Primary Tide has no measurable text carrier") }
            case "right-menu":
                io.mouse(.rightMouseDown, target.point); record("right-down-posted", state()); await pause(0.06)
                io.mouse(.rightMouseUp, target.point); await pause(0.25)
                check(scene.orbMenu.state.isOpen, "Right click opens the product orb menu")
                check(scene.orbMenu.state.enabled(.remove) == (scene.orbTrash.eligibility(notice.id) == nil), "Remove shares current eligibility")
                await pause(0.8); escape()
            default:
                record("before-resign", state()); NSApp.deactivate()
                _ = await until(0.5, { !self.window.window.isKeyWindow })
                record("nonkey-down-posted", state()); await io.press(target.point)
                record("nonkey-down-observed", state()); await pause(0.06); io.release(); await pause(0.3)
                record("nonkey-observation-only", state().merging(["observationOnly": true, "tide": scene.dock.tideLightProbe]) { _, b in b })
                await restoreKeyWindow()
            }
            await finishTide(); checkCleanup(before: before); end(); await between()
        }
    }

    private func keyDiagnostics(attempt: String) -> [String: Any] {
        func describe(_ w: NSWindow?) -> String {
            guard let w else { return "none" }
            return "\(type(of: w)) level=\(w.level.rawValue) visible=\(w.isVisible) canKey=\(w.canBecomeKey)"
        }
        let own = window.window
        return ["attempt": attempt, "active": NSApp.isActive, "ownKey": own.isKeyWindow, "appKeyIsOwn": NSApp.keyWindow === own, "ownMain": own.isMainWindow,
                "ownCanKey": own.canBecomeKey, "ownVisible": own.isVisible, "ownMiniaturized": own.isMiniaturized,
                "appKey": describe(NSApp.keyWindow), "appMain": describe(NSApp.mainWindow),
                "modal": describe(NSApp.modalWindow), "attached": describe(own.attachedSheet),
                "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
                "windows": NSApp.windows.filter { $0.isVisible }.map { describe($0) + ($0 === own ? " own" : "") }]
    }

    private func restoreKeyWindow() async {
        // Activation is asynchronous. Show the existing product window only after the app is active.
        io.activate()
        var active = await until(3, { NSApp.isActive })
        if !active { io.activate(); active = await until(3, { NSApp.isActive }) }
        if active { window.show(focus: false) }
        var restored = await until(3, { NSApp.isActive && self.window.window.isKeyWindow })
        record("key-attempt", keyDiagnostics(attempt: "show"))
        if !restored {
            // Cooperative activation can leave the app active without a key window; ask again through the newer APIs.
            NSApp.activate()
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.window.makeKeyAndOrderFront(nil)
            restored = await until(3, { NSApp.isActive && self.window.window.isKeyWindow })
            record("key-attempt", keyDiagnostics(attempt: "running-application"))
        }
        if !restored {
            window.window.makeKey()
            restored = await until(2, { NSApp.isActive && self.window.window.isKeyWindow })
            record("key-attempt", keyDiagnostics(attempt: "make-key"))
        }
        record("key-restored", state().merging(["active": NSApp.isActive, "restored": restored]) { _, b in b })
        check(restored, "The product window regains key before any subsequent input")
        if !restored { inputStopped = true; record("input-stopped", ["reason": "Window did not regain key"]) }
    }

    private func undoAndDisarm() async {
        if selected("undo-glyph") {
            if budget() {
                begin("undo-glyph")
                if let target = await prepare(.dock) { await removeAndUndo(target, undoDwell: 1.5) }
                else { unavailable("No eligible Dock source") }
                end(); await between()
            } else { skip("undo-glyph", inputStopReason) }
        }
        guard selected("armed-pull-away") else { return }
        guard budget() else { skip("armed-pull-away", inputStopReason); return }
        begin("armed-pull-away")
        guard let target = await prepare(.dock) else { unavailable("No eligible Dock source"); end(); return }
        let before = snapshot()
        if await pickup(target), await arm() {
            let can = geometry().target
            await moveSemantic(.init(x: can.x - 110, y: can.y), over: 0.9); await pause(0.5)
            record("disarmed", state())
            check(scene.orbTrash.state.phase != .armed && (scene.orbTrash.output?.pose.redTint ?? 1) < 0.05,
                  "Pulling away releases armed red treatment")
        } else { escape() }
        record("up-posted", state()); io.release(); await pause(1.2)
        check(Set(scene.members.map(\.id)) == before.members && scene.orbTrash.successfulRemovals == before.removals, "Disarmed release removes nothing")
        checkCleanup(before: before); end(); await between()
    }
    private func hitCases() async {
        for outside in [false, true] {
            let name = outside ? "hit.orb.outer+2" : "hit.orb.inner-2"
            guard selected(name) else { continue }
            guard budget() else { skip(name, inputStopReason); continue }
            begin(name)
            guard let target = await prepare(.dock), let r = scene.orbPose(target.id) else { unavailable("No Dock disc"); end(); continue }
            let before = snapshot(), p = CGPoint(x: r.midX, y: r.midY - r.width / 2 + (outside ? -2 : 2))
            record("down-posted", ["at": [p.x, p.y], "disc": rect(r)]); await io.press(p)
            await pause(0.08)
            let pressedOnDown = scene.orbInput.isPressed
            _ = await pickupContinuation(from: p)
            let pickedUp = sawPickup || scene.isDragging || scene.drag?.freeCarry == true
            record("hit-result-observation", state().merging(["pressedOnDown": pressedOnDown, "pickedUp": pickedUp,
                                                              "observationOnly": true]) { _, b in b })
            escape(); io.release(); await pause(1.2)
            check(Set(scene.members.map(\.id)) == before.members, "Hit probe removes nothing"); checkCleanup(before: before); end(); await between()
        }
        for outside in [false, true] {
            let name = outside ? "hit.arm.outer+2" : "hit.arm.inner-2"
            guard selected(name) else { continue }
            guard budget() else { skip(name, inputStopReason); continue }
            begin(name)
            guard let target = await prepare(.dock) else { unavailable("No Dock source"); end(); continue }
            let before = snapshot()
            if await pickup(target) {
                let can = geometry().target
                await moveSemantic(.init(x: can.x - 110, y: can.y), over: 0.6); await pause(0.2)
                await moveSemantic(.init(x: can.x - OrbTrashParameters.armRadius + (outside ? -2 : 2), y: can.y), over: 0.7)
                await pause(0.6); record("arm-boundary-result", state())
                check((scene.orbTrash.state.phase == .armed) == !outside, "Arm boundary uses the unmagnetized semantic center")
            } else { escape() }
            // These boundary probes return through Esc rather than consuming an Undo slot.
            escape(); record("up-posted", state()); io.release(); await pause(1.2)
            check(Set(scene.members.map(\.id)) == before.members, "Arm probe removes nothing"); checkCleanup(before: before); end(); await between()
        }
    }
    private func pickupContinuation(from p: CGPoint) async -> Bool {
        await io.carry(.init(x: p.x + 8.1, y: p.y), 0.12); record("8pt-crossed", state())
        let grab = scene.drag?.grab ?? .zero, row = scene.drag?.sourceRow ?? p.y
        await io.carry(.init(x: p.x + 8.1, y: row + grab.y - 45), 0.65); record("45pt-row-exit", state())
        return scene.drag?.freeCarry == true
    }
    private func hoverCases() async {
        if selected("hover.tide") {
            if budget() {
                begin("hover.tide")
                let before = snapshot()
                if let notice = await startTide(), let target = dockTarget(excluding: [notice.id]) {
                    record("tide-before-other-orb-down", ["tide": scene.dock.tideLightProbe]); await removeAndUndo(target)
                } else { unavailable("No primary Tide plus a different eligible orb") }
                await finishTide(); checkCleanup(before: before); end(); await between()
            } else { skip("hover.tide", inputStopReason) }
        }
        guard selected("hover.ll") else { return }
        guard budget() else { skip("hover.ll", inputStopReason); return }
        begin("hover.ll")
        let before = snapshot()
        if await auto() { await physicalLLHover() }
        else { check(false, "LL hover has an Auto window"); unavailable("No Auto window for LL") }
        await clearSurfaces(); checkCleanup(before: before); end(); await between()
    }
    private func physicalCursorInDock() -> CGPoint {
        let inWindow = window.window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return scene.dockView.convert(inWindow, from: nil)
    }
    private func warpCursor(to point: CGPoint) async -> Bool {
        guard let primary = NSScreen.screens.first else { check(false, "Cursor warp requires a screen"); return false }
        let cocoa = window.window.convertPoint(toScreen: scene.dockView.convert(point, to: nil))
        // AppKit is bottom-up in points; Quartz global cursor coordinates are top-down from the primary screen.
        let quartz = CGPoint(x: cocoa.x, y: primary.frame.maxY - cocoa.y)
        let result = CGWarpMouseCursorPosition(quartz)
        record("cursor-warp", ["dock": [point.x, point.y], "quartz": [quartz.x, quartz.y], "error": result.rawValue])
        check(result == .success, "Physical cursor warp succeeds")
        guard result == .success else { return false }
        io.mouse(.mouseMoved, point)
        let reached = await until(0.5, {
            let actual = self.physicalCursorInDock()
            return hypot(actual.x-point.x, actual.y-point.y) <= 2
        })
        let screenReadback = NSEvent.mouseLocation, actual = physicalCursorInDock()
        let ll = scene.dock.meMeasurement?.frame ?? .zero
        record("cursor-readback", ["screen": [screenReadback.x, screenReadback.y], "dock": [actual.x, actual.y],
                                   "requestedDock": [point.x, point.y], "ll": rect(ll), "insideLL": ll.contains(actual),
                                   "errorPoints": Double(hypot(actual.x-point.x, actual.y-point.y))])
        check(reached, "NSEvent cursor readback reaches the requested Dock point")
        return reached
    }
    private func physicalLLHover() async {
        guard let original = CGEvent(source: nil)?.location, let frame = scene.dock.meMeasurement?.frame else {
            check(false, "LL measurement and the original physical cursor are available"); unavailable("Cannot establish LL cursor fixture"); return
        }
        defer {
            let result = CGWarpMouseCursorPosition(original)
            record("cursor-restored", ["quartz": [original.x, original.y], "error": result.rawValue])
            check(result == .success, "Physical cursor returns to its original position")
        }
        // Leave LL first, clearing the product's Esc suppression before entering it again.
        guard await warpCursor(to: CGPoint(x: scene.size.width * 0.5, y: scene.size.height * 0.4)) else { return }
        await pause(0.2)
        let point = center(frame)
        guard await warpCursor(to: point) else { return }
        let insideLL = (scene.dock.meMeasurement?.frame ?? .zero).contains(physicalCursorInDock())
        check(insideLL, "The read-back physical cursor is inside the current LL frame")
        guard insideLL else { return }
        for _ in 0..<24 { io.mouse(.mouseMoved, point); await pause(1.0 / 30) }
        let shown = await until(3, { self.scene.sunHover?.isShowing == true })
        record("ll-hover-observed", ["sun": scene.sunHoverReadout, "physical": true])
        check(shown, "A real cursor over LL exposes product hover", ["sun": scene.sunHoverReadout])
        guard shown else { unavailable("Physical LL hover did not open"); return }
        await pause(0.8)
        guard let target = dockTarget() else { unavailable("No eligible orb beside LL hover"); return }
        // Move naturally from LL to the orb and press within the product's hover grace; no tracking callback is invoked.
        guard await warpCursor(to: target.point) else { return }
        record("ll-before-orb-down", ["sun": scene.sunHoverReadout, "id": target.id])
        await removeAndUndo(target)
    }
    private func menuRemove() async {
        guard selected("menu.remove") else { return }
        guard budget() else { skip("menu.remove", inputStopReason); return }
        begin("menu.remove")
        guard let target = await prepare(.dock) else { unavailable("No eligible Dock source"); end(); return }
        let before = snapshot()
        if await choose(.remove, target: target) {
            await pause(1.2); record("menu-after-remove", state())
            check(!scene.members.contains { $0.id == target.id } && scene.orbTrash.successfulRemovals == before.removals + 1,
                  "Menu Remove commits exactly once")
            if await undo(target.id) { await pause(1.2) }
            check(Set(scene.members.map(\.id)) == before.members && scene.orbTrash.successfulUndos == before.undos + 1,
                  "Menu Remove uses the product Undo")
        } else { check(false, "Eligible Remove can be selected in the product menu") }
        await clearSurfaces(); checkCleanup(before: before); end(); await between()
    }
}
