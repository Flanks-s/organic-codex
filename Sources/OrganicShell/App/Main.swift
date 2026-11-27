import AppKit

// Organic Shell v2 · first scene: Organic Auto brief↔full with the dock (spec §12, step 1).




@main enum Main {
    @MainActor static func main() {
        let o = Options.parse()
        let appearanceVerification = ProcessInfo.processInfo.environment["VERIFY_APPLICATION_APPEARANCE"]
        // Test runs only (--selftest, appearance verification, or --demo-input with --output): a crash ends in _exit(70) with its trace in
        // the run's output folder instead of the system crash dialog, which takes the front from every later run (11-06 on
        // the MBA). Hand runs keep the normal system crash report. CrashGuard.swift, Claude.
        if let dir = appearanceVerification ?? o.selftest ?? (o.demoInput != nil ? o.output : nil) { CrashGuard.install(directory: dir) }
        // --launch-plan: what this command line would start, printed before anything is created (no Core, no window).
        if CommandLine.arguments.contains("--launch-plan") {
            print("launch-plan liveCore=\(o.usesLiveCore) mock=\(o.mock) paused=\(o.mockPaused) playback=\(o.live) labs=\(o.labs) automated=\(o.automated)")
            exit(0)
        }
        // The first shared access must create the subclass required by the lifetime fixture.
        let app: NSApplication
        if o.selftest != nil, ProcessInfo.processInfo.environment["SELFTEST_WINDOW_LIFETIME"] == "1" {
            app = WindowLifetimeTestApplication.shared
        } else {
            app = ModeProbeApplication.shared
        }
        // Keep all AppKit surfaces on Native's dark appearance, including live contrast changes.
        app.appearance = NativeDisplayOptions.appearance
        NativeDisplayOptions.shared.observe {
            app.appearance = NativeDisplayOptions.appearance
        }
        if let dir = o.selftest, ProcessInfo.processInfo.environment["SELFTEST_WINDOW_LIFETIME"] == "1" {
            exit(AppWindowLifetimeVerification.run(to: dir))
        }
        if let dir = o.selftest, ProcessInfo.processInfo.environment["SELFTEST_NO_WINDOW"] == "1" {
            exit(AppNoWindowVerification.run(to: dir))
        }
        if let dir = o.selftest, ProcessInfo.processInfo.environment["VERIFY_PANEL_ESCAPE"] == "1" {
            exit(PanelEntryVerification.run(to: dir, escapeOnly: true))
        }
        if let dir = o.selftest, ProcessInfo.processInfo.environment["VERIFY_PANEL_ENTRY"] == "1" {
            exit(PanelEntryVerification.run(to: dir))
        }
        if let dir = o.selftest {
            exit(SelfTest.run(to: dir, size: CGSize(width: o.width, height: o.height)))
        }
        if let dir = o.offscreen {
            Offscreen.run(to: dir, hz: o.offscreenHz, size: CGSize(width: o.width, height: o.height), target: o.offscreenTarget)
            return
        }
        ModeSignposts.receiptsEnabled = o.output != nil
        app.setActivationPolicy(.regular)
        if let dir = appearanceVerification { exit(ApplicationAppearanceVerification.run(to: dir)) }
        if let dir = ProcessInfo.processInfo.environment["VERIFY_RICH_BRIEF"] {
            exit(RichBriefVerification.run(to: dir))
        }
        let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu(title: "Organic Shell")
        sub.addItem(NSMenuItem(title: "Quit Organic Shell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = sub; menu.addItem(item); app.mainMenu = menu
        let controller = AppController(o)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor private enum PanelEntryVerification {
    static func run(to path: String, escapeOnly: Bool = false) -> Int32 {
        var checks = 0
        var findings: [String] = []
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { findings.append(name) }
        }
        if !escapeOnly { checkSheet(check: check) }
        if let screen = NSScreen.screens.first {
            checkWindow(screen, escapeOnly: escapeOnly, check: check)
        } else { check(false, "fixture.screen") }
        for finding in findings { print("FINDING \(finding)") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let json: [String: Any] = ["checks": checks, "findings": findings, "mockOnly": true]
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("panel-entry.json"))
        } catch { check(false, "fixture.report: \(error.localizedDescription)") }
        print("\(checks) checks")
        return findings.isEmpty ? 0 : 1
    }

    private static func checkSheet(check: (Bool, String) -> Void) {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let sheet = SheetCustomizeChat(clock: OverlayManualClock())
        let host = OverlayView(frame: CGRect(x: 0, y: 0, width: 780, height: 640))
        sheet.present(name: "Fixture", identity: .assigned(0), level: 0.4, in: host)
        let choices = BodyIdentityAdapter.choices
        check(sheet.symbolButtons.count == 24, "sheet.body.count")
        for (id, button) in zip(choices, sheet.symbolButtons) {
            check(button.toolTip == id.capitalized, "sheet.tooltip.\(id)")
        }
        sheet.selectBody("haumea")
        check(descendants(sheet).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Haumea" },
              "sheet.selected.haumea")
        sheet.dismiss(reason: .cancelled, animated: false)
    }

    private static func checkWindow(_ screen: NSScreen, escapeOnly: Bool, check: (Bool, String) -> Void) {
        var options = Options()
        options.mock = true
        options.mockPaused = true
        options.ambient = false
        let suite = "Panel.Entry." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "fixture.defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppController(options, windowDefaults: defaults, presentsWindows: false)
        let replay = MockReplay(store: app.store)
        replay.start(live: false)
        app.mock = replay
        app.runtime = MockConversationRuntime(store: app.store, replay: replay, animatePlayback: false)
        let window = OrganicWindow(app: app, frame: CGRect(x: 0, y: 0, width: 1280, height: 820),
            screen: screen, members: ["A", "B", "C", "D", "E", "F"], normie: false, o: options)
        app.windows = [window]
        defer {
            if !window.isClosed { window.window.close() }
            app.runtime.shutdown()
        }
        let scene = window.scene
        let menuClock = OverlayManualClock()
        scene.orbMenu = OrbContextMenu(scene: scene, clock: menuClock)
        var time = CACurrentMediaTime()
        scene.now = { time }
        scene.dock.motionTime = { time }
        scene.pressedButtons = { 1 }
        scene.manualSettle = true
        scene.verificationPresented = true
        func settle() {
            time = max(time + 1, scene.transitionEnd + 1)
            scene.clock.onFrame?(time)
            scene.settle()
            scene.clock.invalidate()
        }
        func panel() -> FunctionPanelWindowOwner? {
            window.window.contentView?.subviews.compactMap { ($0 as? FunctionPanelWindowHost)?.owner }.first
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint, after: Double = 0) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: scene.dockView.convert(point, to: nil), modifierFlags: [],
                timestamp: time + after, windowNumber: window.window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        func center(_ header: HeaderIsland) -> CGPoint {
            let r = scene.dockView.convert(header.planetButton.bounds, from: header.planetButton)
            return CGPoint(x: r.midX, y: r.midY)
        }
        func resetPanels() {
            panel()?.retire()
            scene.customizeSheet.dismiss(reason: .cancelled, animated: false)
            settle()
        }
        func choose(_ item: OrbMenuAction, at point: CGPoint, id: String) {
            _ = scene.orbInput.begin(event(.rightMouseDown, at: point), id: id) { _ in }
            check(scene.orbMenu.state.isOpen && panel()?.isOpen != true, "menu.rightClick.\(item)")
            menuClock.advance(by: 0.06)
            scene.orbMenu.state.hover(row: item.rawValue)
            scene.orbMenu.state.choose()
            menuClock.advance(by: 0.12)
        }
        settle()
        check(app.live == nil && app.core == nil && !options.usesLiveCore, "fixture.mockOnly")
        if escapeOnly {
            checkEscape(in: window, check: check)
            return
        }
        guard let target = scene.conversation(scene.current), let header = scene.nodes[target.id]?.island else {
            check(false, "fixture.column")
            return
        }
        check(panel() == nil, "window.dormant")
        choose(.customize, at: center(header), id: target.id)
        check(panel()?.isOpen == true && panel()?.stage?.state.option == 0, "menu.customize.appearance")
        check(!scene.customizeSheet.isShowing, "menu.customize.noSheet")
        check(!header.hostPresentation.acceptsInput && !header.planetButton.participates, "header.pause.input")
        let source = (header as AnyObject) as? any HeaderIslandHoldSource
        check(source?.headerHolds.tokens.isEmpty == false, "header.pause.ledger")
        let anotherHolder = NSObject()
        let resume = source?.headerHolds.suspend([HeaderIslandHold.Role.interaction], by: anotherHolder)
        if var config = header.configuration {
            config.notices = .init()
            header.now = { time }
            header.configure(config)
            config.notices = .init(journal: [.init(id: 100, kind: .command, text: "Fixture work")])
            header.configure(config)
            header.sampleMotion(at: time + 0.5)
            check(header.pulseProbe?["event"] as? String == "command", "header.pause.pulseArrives")
            for frame in 1...40 { header.sampleMotion(at: time + 0.5 + Double(frame) * 0.1) }
            check(header.pulseProbe?["event"] as? String != "command", "header.pause.pulseExpires")
        } else { check(false, "fixture.pulse") }
        panel()?.retire()
        check(source?.headerHolds.tokens.count == 1 && !header.hostPresentation.acceptsInput, "header.release.onlyOwn")
        resume?()
        check(header.hostPresentation.acceptsInput, "header.release.input")
        resetPanels()

        choose(.rename, at: center(header), id: target.id)
        check(panel()?.isOpen == true && panel()?.stage?.state.editingTitle == true, "menu.rename.editing")
        panel()?.stage?.setTitleDraft("Panel fixture renamed")
        panel()?.stage?.commitTitle()
        check(target.title == "Panel fixture renamed", "menu.rename.mockWrite")
        resetPanels()

        func pressHeader(_ h: HeaderIsland, id: String, duration: Double, drag: Bool = false, cancel: Bool = false) {
            let point = center(h)
            let started = scene.orbInput.begin(event(.leftMouseDown, at: point), id: id, header: h) { _ in
                h.planetButton.performClick(nil)
            }
            check(started && scene.orbInput.isPressed, "gesture.armed")
            check(panel()?.isOpen != true, "gesture.noMouseDownOpen")
            if drag {
                let displaced = CGPoint(x: point.x + 20, y: point.y)
                scene.orbInput.dragged(event(.leftMouseDragged, at: displaced, after: 0.01))
            }
            if cancel { scene.orbInput.cancel() }
            scene.orbInput.released(event(.leftMouseUp, at: point, after: duration))
            check(!scene.orbInput.isPressed, "gesture.released")
        }
        pressHeader(header, id: target.id, duration: 0.05)
        check(panel()?.isOpen == true && panel()?.stage?.state.page == .overview, "header.short.overview")
        resetPanels()
        for (duration, drag, cancel, name) in [(0.05, true, false, "drag"), (0.31, false, false, "long"),
                                               (0.05, false, true, "cancel")] {
            pressHeader(header, id: target.id, duration: duration, drag: drag, cancel: cancel)
            check(panel()?.isOpen != true, "header.\(name).closed")
            resetPanels()
        }

        if let brief = scene.columns.first(where: { !scene.isFull($0.conversation.id) }), let island = brief.island {
            let id = brief.conversation.id
            // Exercise the same fallback as RootView when the visible planet's native control is inactive.
            island.setPresentationActive(false)
            let point = center(island)
            let routed = scene.routeOrbInput(event(.leftMouseDown, at: point)) { window.click($0) }
            check(routed && panel()?.isOpen != true && scene.current != id, "header.brief.armed")
            scene.orbInput.released(event(.leftMouseUp, at: point, after: 0.05))
            island.setPresentationActive(true)
            check(scene.current == id && scene.isFull(id), "header.brief.enters")
            check(panel()?.isOpen != true, "header.brief.waitsForSettle")
            if scene.isMoving { scene.settle() }
            check(panel()?.isOpen != true, "header.brief.earlySettle")
            settle()
            let opened = panel()
            check(opened?.isOpen == true && opened?.stage?.state.page == .overview
                && opened?.snapshot?.input.id == id && scene.current == id, "header.brief.settledOverview")
            let ticket = opened?.generation
            settle()
            check(ticket != nil && opened?.generation == ticket, "header.brief.opensOnce")
            resetPanels()
        } else { check(false, "fixture.briefHeader") }

        if let brief = scene.columns.first(where: { !scene.isFull($0.conversation.id) }), let island = brief.island {
            let id = brief.conversation.id
            pressHeader(island, id: id, duration: 0.05)
            check(scene.current == id && panel()?.isOpen != true, "header.brief.nativeEnters")
            scene.orbInput.cancel()
            settle()
            check(panel()?.isOpen != true, "header.brief.cancelPending")
            resetPanels()
        } else { check(false, "fixture.briefNativeHeader") }

        if let id = scene.order.last(where: { scene.dock.items[$0]?.role == .orb }) {
            scene.setPeeking(id)
            scene.peekNode.setHeaderVisible(true)
            let point = center(scene.peekNode.header)
            check(scene.shownPeek == id && scene.peekNode.headerVisible, "fixture.peek")
            check(scene.routeOrbInput(event(.leftMouseDown, at: point)) { _ in }, "peek.armed")
            scene.orbInput.released(event(.leftMouseUp, at: point, after: 0.05))
            check(scene.shownPeek == nil && panel()?.isOpen != true, "peek.closesBeforeOverview")
            settle()
            let opened = panel()
            check(opened?.isOpen == true && opened?.stage?.state.page == .overview
                && opened?.snapshot?.input.id == id && scene.current == id, "peek.settledOverview")
            let ticket = opened?.generation
            settle()
            check(ticket != nil && opened?.generation == ticket, "peek.opensOnce")
        } else { check(false, "fixture.peekMember") }
        panel()?.retire()

        if let next = scene.nodes[scene.current]?.island {
            pressHeader(next, id: scene.current, duration: 0.05)
        }
        let modePanel = panel()
        check(modePanel?.isOpen == true, "mode.fixture.open")
        window.shell.setMode(.normie, animated: false)
        check(window.shell.mode == .normie, "fixture.normieMode")
        check(modePanel?.isOpen == false && modePanel?.stage == nil, "mode.retires")
        if let conversation = scene.conversation(scene.current) {
            window.workbench.sidebar.onCustomize?(conversation)
        }
        check(scene.customizeSheet.isShowing && modePanel?.isOpen != true, "normie.customize.sheet")
        scene.customizeSheet.dismiss(reason: .cancelled, animated: false)
        window.shell.setMode(.organic, animated: false)
        settle()
        if let next = scene.nodes[scene.current]?.island {
            pressHeader(next, id: scene.current, duration: 0.05)
        }
        let closePanel = panel()
        check(closePanel?.isOpen == true, "close.fixture.open")
        window.window.close()
        check(window.isClosed && closePanel?.isOpen == false && closePanel?.stage == nil, "close.retires")
    }

    private static func checkEscape(in window: OrganicWindow, check: (Bool, String) -> Void) {
        let scene = window.scene
        let dock = scene.dock
        let trailingOrb = dock.restingTargets.filter { !$0.bar }.max { $0.slot < $1.slot }
        guard let target = scene.conversation(scene.current), let sun = scene.sunHover,
              let id = trailingOrb?.id, let orb = scene.conversation(id) else {
            check(false, "fixture.escape.targets")
            return
        }
        func escape() {
            let key = "\u{1b}"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: CACurrentMediaTime(), windowNumber: window.window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 53) else {
                check(false, "fixture.escape.event")
                return
            }
            NSApp.postEvent(event, atStart: true)
            guard let next = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true),
                  next.window === window.window, next.keyCode == 53 else {
                check(false, "fixture.escape.dispatch")
                return
            }
            NSApp.sendEvent(next)
        }
        func tidePhase() -> String? { dock.tideLightProbe["phase"] as? String }
        let thread = orb.backendThreadID ?? orb.id
        dock.prepareTideMaterialNow()
        scene.store.apply(.init(id: 9_101, time: scene.now(), method: "turn/started",
            params: ["threadId": .string(thread), "turn": ["id": "orb-detail-tide"]]))
        scene.store.apply(.init(id: 9_102, time: scene.now(), method: "core/approvalRequested", params: [
            "threadId": .string(thread), "approvalId": "orb-detail-approval", "request": [
                "method": "item/commandExecution/requestApproval", "params": [
                    "command": "printf fixture", "availableDecisions": ["accept", "decline"]]]]))
        check(tidePhase() == "holding" && !scene.tideHasForegroundSurface, "fixture.escape.tideArmed")
        check(window.openFunctionPanel(target, destination: .overview), "fixture.escape.overviewOpen")
        escape()
        check(window.functionPanelOwner?.isOpen == false, "escape.tide.overviewClosed")
        check(tidePhase() == "holding", "escape.tide.keepsNotice")
        window.retireFunctionPanels()
        escape()
        check(tidePhase() == "returning", "escape.tide.ownsEscapeAfterClose")
        dock.retireTide()

        sun.llClick()
        check(sun.isShowing && sun.state.mode == .panel(.account) && sun.readout["monitors"] as? Int == 1,
              "fixture.escape.sunArmed")
        check(window.openFunctionPanel(target, destination: .overview), "fixture.escape.layersOpen")
        check(!sun.isShowing, "escape.sun.retiresOnOpen")
        sun.llClick()
        check(!sun.isShowing, "escape.sun.reentryBlocked")
        sun.retire()
        guard let owner = window.functionPanelOwner, let stage = owner.stage else {
            check(false, "fixture.escape.stage")
            return
        }
        stage.selectPage(.files)
        stage.toggleOption(0)
        stage.beginTitle()
        check(stage.state.editingTitle && stage.state.option == 0, "fixture.escape.editAndOption")
        escape()
        check(owner.isOpen && !stage.state.editingTitle && stage.state.option == 0, "escape.layers.edit")
        escape()
        check(owner.isOpen && stage.state.option == nil && stage.state.page == .files, "escape.layers.option")
        escape()
        check(owner.isOpen && stage.state.page == .overview, "escape.layers.overview")
        escape()
        check(!owner.isOpen, "escape.layers.closed")
        check(!window.window.isVisible, "fixture.escape.offscreen")
    }
}
