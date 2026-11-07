import AppKit
import QuartzCore

@MainActor final class AppController: NSObject, NSApplicationDelegate {
    let o: Options
    /// Every conversation window (f002); the app remains running when this list is empty.
    var windows: [OrganicWindow] = []
    /// First-window conveniences for demos; product callbacks use the optional `front`.
    var main: OrganicWindow { windows[0] }
    var window: NSWindow { main.window }
    var scene: AutoScene { main.scene }
    var shell: WindowShell { main.shell }
    var workbench: NormieWorkbench { main.workbench }
    /// The window menu commands and arrivals go to: the key one, else the first.
    var front: OrganicWindow? { windows.first { $0.window.isKeyWindow } ?? windows.first }
    /// The application owns its menu even after the last conversation window closes.
    let menus = NormieMenuBuilder(context: { NormieMenuContext(supported: []) }, perform: { _, _ in })
    let store = ConversationStore()
    var mock: MockReplay?
    /// What sends, stops and creates: the live Core on a normal launch (f001), the mock over `mock` for demos, tests,
    /// timed runs and --mock.
    var runtime: any ConversationRuntime = MockConversationRuntime(store: ConversationStore())
    var demoTimer: Timer?
    var saved = false

    let windowDefaults: UserDefaults
    let presentsWindows: Bool
    var startupRestorePending = true
    /// AppKit closes windows after the termination snapshot; those closes must not replace it.
    private(set) var isTerminating = false
    init(_ o: Options, windowDefaults: UserDefaults = .standard, presentsWindows: Bool = true) {
        self.o = o; self.windowDefaults = windowDefaults; self.presentsWindows = presentsWindows
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = launchScreen
        let visible = screen.visibleFrame
        let size = CGSize(width: min(o.width, visible.width - 40), height: min(o.height, visible.height - 40))
        let liveCore = o.usesLiveCore
        if liveCore {
            startLive()
        } else {
            // The product's whole demo library in the sidebar (history and archive too); the window still opens on A–F.
            let replay = MockReplay(store: store, includeSidebarHistory: true)
            replay.start(live: false)
            mock = replay
            runtime = MockConversationRuntime(store: store, replay: replay)
            // PARITY_DRAFT (M9 captures): the same words in every conversation's composer, as the product's copy does.
            if let text = ProcessInfo.processInfo.environment["PARITY_DRAFT"] { for c in store.conversations { c.draft = text } }
        }
        // The windows as they were when the app last quit (f003), on a screen that can show them; else one window.
        // Live: one window in New Chat now, the saved ones once the conversations have loaded (restoreLive).
        let saved = automated || liveCore ? [] : windowRecords()
        if liveCore {
            let first = OrganicWindow(app: self, frame: CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
                                      screen: screen, members: [], normie: true, o: o)
            windows = [first]
        } else { _ = restoreWindows(saved, present: false) }
        let first = windows[0]
        // `--float` (recordings on the one display someone is also using): the window above the others, never
        // activated, so a covered window cannot stop drawing mid-recording and no key focus is taken.
        if o.float || o.inactive {
            if o.float { first.window.level = .floating; first.window.orderFrontRegardless() }
            // Never key: captures compare both apps in the same state, and the person at the Mac keeps the focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.deactivate() }
        }
        // A background arrival joins the window in front (f036); Live: only once the history has loaded.
        if !liveCore { watchArrivals() }
        installMainMenu()
        // Settings (M8, Sol's Settings/): one owner for the app; Settings… (⌘,) and the account menu open it. Its
        // Organic options reach the windows' scenes as they change.
        // The windows' own store: Archived Chats lists, restores and archives the same conversations (app audit AP03).
        // Delete removes them from the store for good; a window still holding one lets it go without an Undo toast.
        installSettings()
        applyShortcuts()
        applyLook()
        watchRedEvents()
        // Debug tools (Sol's Debug/, demo only): the panel and the Orb, Transition and Spring Labs under a Debug menu.
        // Each Lab moves a real column on a stage of its own (LabStage), never a window's.
        let debug = DebugTools(store: store, mock: mock, initiallyPaused: o.mockPaused, transitionHost: transitionStage, springHost: springStage)
        debugTools = debug
        // The panel's layout, morph and spring values reach every window's scene (DEBUG-MOCK-S4; f009).
        tuningHost.windows = { [weak self] in self?.windows ?? [] }
        tuningBinding = debug.bindTuning(to: tuningHost)
        let debugMenu = NSMenu(title: "Debug")
        for item in debug.menuItems() { debugMenu.addItem(item) }
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        NSApp.mainMenu?.insertItem(debugItem, at: max(0, (NSApp.mainMenu?.numberOfItems ?? 1) - 1))
        NSApp.servicesMenu = menus.servicesMenu
        NSApp.windowsMenu = menus.windowsMenu
        NSApp.helpMenu = menus.helpMenu
        presentRestoredWindows(saved)
        if o.live { mock?.start(live: true) }
        for lab in o.labs {
            switch lab {
            case "--orb-lab": debug.toggleOrbLab()
            case "--transition-lab": debug.toggleTransitionLab()
            case "--spring-lab": debug.toggleSpringLab()
            default: debug.showSpotlightLab()
            }
        }
        if o.demo { toggleDemo() }
        if o.demoHover { demoHover() }
        if o.demoSwap {
            // Each column in turn becomes full; once it rests, native view ↔ its own capture every 0.5 s with nothing
            // else moving. A window recording gets a frame only when the window changes, so any frame between
            // swaps is a difference.
            var tick = 0
            swapTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let phase = tick % 10, column = (tick / 10) % self.scene.columns.count; tick += 1
                    if phase == 0 {
                        self.scene.showCaptures(false); self.scene.switchTo(column, reason: "demo-swap")
                        self.swapLog.append(["t": CACurrentMediaTime(), "switch": column])
                    } else if phase >= 4 {
                        let on = phase % 2 == 0
                        self.scene.showCaptures(on); self.swapLog.append(["t": CACurrentMediaTime(), "captures": on, "column": column])
                    }
                }
            }
        }
        if o.demoCompose { demoCompose() }
        if o.demoLand { demoLand() }
        if o.demoDrag { demoDrag() }
        if o.demoDragHeader { demoDragHeader() }
        if o.demoResize { demoResize() }
        if o.demoOverlays { demoOverlays() }
        if o.demoMe { demoMe() }
        if o.demoPeek { demoPeek() }
        if o.demoMode || o.demoModeMenu || o.demoModeKey { demoMode() }
        if o.demoAudit { demoAudit() }
        if o.demoAudit2 { demoAudit2() }
        if o.demoOrganicActions { demoOrganicActions() }
        if o.demoLiveHooks { demoLiveHooks() }
        if o.demoFocus { demoFocusContinuity() }
        if o.demoLiveWrite { demoLiveWrite() }
        if o.demoPersist { demoPersist() }
        if o.demoTuning { demoTuning() }
        if o.demoAcceptance { demoAcceptance() }
        if o.demoLook {
            // Settings ▸ Appearance: clear glass, a theme of its own, larger text; then back to the defaults (f132–f133).
            let p = { self.settings?.session.preferences }
            let steps: [(Double, () -> Void)] = [
                (1.5, { p()?.set("look.glass", .string("clear")) }),
                (3.0, { p()?.set("look.theme", .string(ProcessInfo.processInfo.environment["DEMO_THEME"] ?? "dracula")) }),
                (4.5, { p()?.set("look.text", .number(1.3)); p()?.set("look.size", .number(15)) }),
                (6.5, { p()?.resetAppearance() }),
                (7.2, { self.composeLog.append(["step": "after reset", "textScale": NativeAppearance.current.textScale,
                                                "background": NativeAppearance.current.background?.description ?? "nil",
                                                "theme": p()?["look.theme"].settingsText ?? "?"]) }),
            ]
            for (t, run) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } } }
        }
        if o.demoFullScreenCollapse {
            // Full screen, then Collapse: it leaves full screen first and collapses after; Restore goes back (COLLAPSE-SPEC §1, §6).
            func log(_ step: String) {
                func find(_ m: NSMenu?) -> NSMenuItem? {
                    for i in m?.items ?? [] { if i.identifier?.rawValue == "shortcut.collapse" { return i }; if let f = find(i.submenu) { return f } }
                    return nil
                }
                self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "fullScreen": self.window.styleMask.contains(.fullScreen),
                                        "menu": find(NSApp.mainMenu)?.title ?? "?",
                                        "collapsed": self.main.isCollapsed, "frame": NSStringFromRect(self.window.frame)])
            }
            let steps: [(Double, String, () -> Void)] = [(0.8, "full screen", { self.window.toggleFullScreen(nil) }), (3.0, "collapse", { self.main.command(.collapse, tag: 0) }),
                                                         (3.2, "collapsing", {}), (5.5, "collapsed", {}), (6.0, "restore", { self.main.command(.restore, tag: 0) }), (9.0, "restored", {})]
            for (t, step, run) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run(); log(step) } } }
        }
        if o.demoTerminal {
            // Normie, then ⌘J: the bottom terminal with the chat's commands; a typed line gets the prototype's answer (f026, f167).
            let steps: [(Double, () -> Void)] = [(0.6, { self.shell.setMode(.normie, animated: false) }), (1.2, { self.main.workbench.perform(.terminal) }),
                                                 (3.5, { self.main.workbench.perform(.terminal) })]
            for (t, run) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } } }
        }
        if o.demoModeReverse {
            // Normie, then Hide Sidebar and Show Sidebar again 0.2 s into it: the planets turn back where they are (#12).
            // DEMO_RAPID=1: three round trips 0.15 s apart instead (b090), ending in Normie.
            let rapid = ProcessInfo.processInfo.environment["DEMO_RAPID"] == "1"
            var flips: [(Double, () -> Void)] = []
            for i in 0..<(rapid ? 6 : 2) {
                let mode: WindowShell.Mode = i % 2 == 0 ? .organic : .normie
                let t: Double = rapid ? 2.0 + 0.15 * Double(i) : 2.0 + 0.2 * Double(i)
                flips.append((t, { self.shell.setMode(mode) }))
            }
            let steps: [(Double, () -> Void)] = [(0.8, { self.shell.setMode(.normie, animated: false) })] + flips + [
                                                 (2.3, { self.composeLog.append(["step": "2.3", "sidebar": self.shell.sidebarState]) }),
                                                 (2.6, { self.composeLog.append(["step": "2.6", "sidebar": self.shell.sidebarState]) }),
                                                 (3.0, { self.composeLog.append(["step": "3.0", "sidebar": self.shell.sidebarState]) }),
                                                 (3.5, { self.composeLog.append(["step": "3.5", "mode": "\(self.shell.mode)", "sidebar": self.shell.sidebarState,
                                                                                  "flight": self.shell.flight.debugState]) })]
            for (t, run) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } } }
        }
        if o.demoCompare { demoCompare() }
        if o.demoTear { demoTear() }
        if let spec = o.demoInput { demoInput(spec) }
        if o.demoMember {
            // ⌘2 (a column goes full), then ⌘5 (an orb lands).
            for (t, tag) in [(1.0, 1), (2.5, 4)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    self.main.command(.member, tag: tag)
                    self.composeLog.append(["t": CACurrentMediaTime(), "step": "member \(tag + 1)", "current": self.scene.current, "order": self.scene.order])
                } }
            }
        }
        // PARITY_STATE (M9 captures): one state a second after launch, by the steps the product's copy takes for it
        // (its stepFocusDemo, cyclePeek, stepPickerDemo, coordinator.newChat).
        if let state = ProcessInfo.processInfo.environment["PARITY_STATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated {
                let scene = self.scene
                switch state {
                case "focused": scene.enterFocused(scene.current, reason: "parity")
                case "split":
                    scene.enterFocused(scene.current, reason: "parity")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated {
                        if let id = scene.order.first(where: { $0 != scene.current }) { scene.graft(id, at: 1, reason: "parity") }
                    } }
                case "picker":
                    if self.shell.mode == .normie { _ = self.main.normieComposerBinding?.presentModelPicker() }
                    else { _ = scene.overlay(for: scene.current)?.presentModelPicker() }
                case "peek":
                    let orbs = Array(scene.order.dropFirst(scene.columns.count))
                    if orbs.count > 1 { scene.setPeeking(orbs[1]) }
                case "newchat": self.main.command(.newChat, tag: 0)
                default: break
                }
            } }
        }
        // `--settings <pane>`: Settings open at that pane, as the product's flag (M9 captures).
        if let pane = o.settingsPane {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated {
                // A fresh history: the first page has nothing to go Back to (the toolbar's back/forward capsule).
                self.settings?.show(pane: pane, resetHistory: true)
                if self.o.float, let w = self.settings?.window { w.level = .floating; w.orderFrontRegardless() }
                // On the `--display` screen too (captures on the test screen), centred there.
                if !self.o.display.isEmpty, let w = self.settings?.window,
                   let area = NSScreen.screens.first(where: { $0.localizedName.lowercased().contains(self.o.display.lowercased()) })?.visibleFrame {
                    w.setFrameOrigin(CGPoint(x: area.midX - w.frame.width / 2, y: area.midY - w.frame.height / 2))
                }
            } }
        }
        if o.demoSettings {
            // Settings… on its Organic pane; its window number goes to the output for recording it on its own.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated {
                self.settings?.show(pane: "organic")
                if let out = self.o.output, let n = self.settings?.window?.windowNumber { try? "\(n)".write(toFile: out + "/settings-window.txt", atomically: true, encoding: .utf8) }
            } }
        }
        if o.demoTools {
            // Tools… (the menu's Artifacts & Annotations), then each page in turn; its window number goes to the output.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated {
                self.front?.command(.artifacts, tag: 0)
                if let out = self.o.output, let n = self.tools.window?.windowNumber { try? "\(n)".write(toFile: out + "/tools-window.txt", atomically: true, encoding: .utf8) }
            } }
            for (i, section) in [ToolsRootView.Section.browser, .capture, .terminal, .artifacts].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.8 + Double(i) * 1.5) { MainActor.assumeIsolated { self.tools.present(section: section) } }
            }
        }
        if o.demoLabs { demoLabs() }
        if o.demoScrollProbe { demoScrollProbe() }
        if o.demoDeliver { demoDeliver() }
        if o.demoLiveTerminal { demoLiveTerminal() }
        if o.demoAccess { demoAccess() }
        if o.demoCustomize {
            // The planet's Customize on B, then Done with a new name, symbol and colour (f073, f122).
            let b = { self.scene.order.dropFirst().first ?? "" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { self.scene.customize(b()) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { MainActor.assumeIsolated {
                self.scene.demoCustomize(b(), SheetChatCustomization(name: "Copy review, renamed", symbol: OrbCelestialBody.allCases[5], tint: OrbTint.allCases[9]))
            } }
        }
        if o.demoCollapse {
            // ⌥⌘↓, show another member in the strip, then me dragged to the rail's end: back (f050–f053).
            let steps: [(Double, String, () -> Void)] = [
                (1.0, "collapse", { self.main.command(.collapse, tag: 0) }),
                (2.2, "open the sidebar overlay", { self.main.strip?.toggleOverlay() }),
                (3.4, "close it", { self.main.strip?.toggleOverlay() }),
                (4.0, "show C", { if let c = self.scene.members.dropFirst(2).first { self.main.strip?.show(c.id, animated: true) } }),
                (5.2, "drag me to the end", { self.main.strip?.dragMeToEnd() }),
                (7.2, "rest", {}),
            ]
            for (t, step, run) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    run()
                    self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "collapsed": self.main.isCollapsed, "frame": NSStringFromRect(self.window.frame),
                                            "shown": self.main.strip?.shown ?? "", "current": self.scene.current])
                } }
            }
        }
        if o.demoCollapseNew {
            // Collapsed: the overlay's New Chat, type, Esc (back to the shown chat, words kept), ⌘N, send: the new
            // conversation joins and shows; then the sub-agents sheet from the rows (COLLAPSE-SPEC §3, §4).
            func draft() -> NativeComposer { self.scene.composers.draft().composer }
            let steps: [(Double, String, () -> Void)] = [
                (1.0, "collapse", { self.main.command(.collapse, tag: 0) }),
                (2.0, "open the sidebar overlay", { self.main.strip?.toggleOverlay() }),
                (2.8, "overlay New Chat", { self.main.strip?.beginNewChat() }),
                (3.6, "type", { draft().setText("Sketch the collapse onboarding") }),
                (4.2, "esc", { self.main.strip?.cancelNewChat() }),
                (5.0, "new chat again", { self.main.command(.newChat, tag: 0) }),
                (5.8, "send", { draft().submit() }),
                (7.4, "show A", { if let a = self.scene.members.first { self.main.strip?.show(a.id, animated: true) } }),
                (8.0, "sub-agents sheet", { if let strip = self.main.strip, let a = self.scene.members.first { self.scene.showSubAgents(a.id, from: CGRect(x: 28, y: strip.bounds.height - 168, width: strip.bounds.width - 56, height: 48), upward: true, in: strip) } }),
                (9.4, "rest", {}),
            ]
            for (t, step, run) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    run()
                    self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "collapsed": self.main.isCollapsed, "drafting": self.main.strip?.isDrafting ?? false,
                                            "shown": self.main.strip?.shown ?? "", "members": self.scene.members.map(\.id),
                                            "stripMembers": self.main.strip?.members.map(\.id) ?? []])
                } }
            }
        }
        if o.demoNewChat {
            // ⌘N, type, Esc (the words stay), ⌘N again, send: a conversation in the draft's slot (f047, f048).
            func draft() -> NativeComposer { self.scene.composers.draft().composer }
            let steps: [(Double, String, () -> Void)] = [
                (1.0, "new chat", { self.main.command(.newChat, tag: 0) }),
                (2.4, "type", { draft().setText("Draft a plan for the onboarding tour") }),
                (3.0, "esc", { self.scene.cancelNewChat() }),
                (4.4, "new chat again", { self.main.command(.newChat, tag: 0) }),
                (5.6, "send", { draft().submit() }),
                (7.6, "rest", {}),
            ]
            for (t, step, run) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    run()
                    self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "composing": self.scene.composingNew, "current": self.scene.current,
                                            "order": self.scene.order, "draft": self.scene.composers.draft().composer.text])
                } }
            }
        }
        if o.demoWindows {
            // Move the full conversation to a new window, type in it there, then merge every window back (f002, f188).
            let steps: [(Double, String, () -> Void)] = [
                // What the menu command does once its window is key (A14); a demo launched with `open -g` never is.
                (1.5, "move to new window", { self.moveToNewWindow(self.main.scene.focusTarget, from: self.main) }),
                (3.0, "type in the new window", { if let w = self.windows.last, w !== self.main, let id = w.scene.members.first?.id { w.scene.composers.existingComposer(for: id)?.setText("typed in the new window") } }),
                (4.5, "merge", { self.mergeWindows(into: self.main) }),
                (6.0, "move again", { self.moveToNewWindow(self.main.scene.focusTarget, from: self.main) }),
                // The new window's only member moves on: another window grows and the emptied one closes.
                (7.5, "move the only member", { if let w = self.windows.last, w !== self.main { self.moveToNewWindow(w.scene.members.first?.id, from: w) } }),
                (9.5, "rest", {}),
            ]
            for (t, step, run) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    run()
                    let ws = self.windows.map { w in w.scene.members.map(\.id).joined(separator: ",") }
                    let drafts = self.windows.flatMap { w in w.scene.members.compactMap { c in w.scene.composers.existingComposer(for: c.id).map { "\(c.id):\($0.text)" } } }
                    self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "windows": ws, "composers": drafts])
                } }
            }
        }
        if o.demoArchive {
            // ⌘⌫ on the second column in Organic, then Undo from the toast.
            let steps: [(Double, String, () -> Void)] = [
                (1.5, "archive B", { if let b = self.scene.order.dropFirst().first { _ = self.workbench.select(b); self.workbench.perform(.archive) } }),
                (3.5, "undo", { _ = self.scene.onUndoArchive?() }),
                (5.5, "rest", {}),
            ]
            for (t, step, run) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    run(); self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "order": self.scene.order, "current": self.scene.current])
                } }
            }
        }
        if o.demoSplit {
            // Focused on A, B grafted in (Split), then ⌃Tab, ⌃Tab, ⌃⇧Tab, and a click on a column: who has the focus each time.
            let steps: [(Double, String, () -> Void)] = [
                (1.0, "focused", { self.scene.enterFocused(self.scene.current, reason: "demo") }),
                (2.0, "graft", { if let b = self.scene.order.dropFirst().first { self.scene.graft(b, at: 1, reason: "demo") } }),
                (3.0, "ctrl-tab", { self.command(.nextPane, tag: 0) }),
                (3.5, "ctrl-tab", { self.command(.nextPane, tag: 0) }),
                (4.0, "ctrl-shift-tab", { self.command(.previousPane, tag: 0) }),
                (4.5, "click first column", { let f = self.scene.columnState.first { ($0["slot"] as? Int) == 0 }; if f != nil { self.scene.focusColumn(0) } }),
                (5.0, "rest", {}),
            ]
            for (t, step, run) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    run()
                    DispatchQueue.main.async {
                        self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "target": self.scene.focusTarget,
                                                "selected": self.workbench.selectedConversation?.id ?? "", "split": self.scene.isFocused])
                    }
                } }
            }
        }
        if o.demoRefuse {
            // Focused, then ⌘N twice (refused: the capsule shakes), then Auto again.
            for (t, run) in [(1.0, { self.scene.enterFocused(self.scene.current, reason: "demo") }), (2.2, { self.command(.newChat, tag: 0) }),
                             (3.0, { self.command(.newChat, tag: 0) }), (4.0, { self.scene.leaveFocused(reason: "demo") })] as [(Double, () -> Void)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } }
            }
        }
        if o.demoBloom { for t in [1.5, 3.5] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.scene.bloomDock() } } }
        if o.hide.contains("dock") { first.scene.dockView.isHidden = true }
        if o.hide.contains("native") { first.scene.nativePlane.isHidden = true }
        if o.hide.contains("scene") { first.scene.sceneView.isHidden = true }
        for (name, view) in [("remove-scene", first.scene.sceneView), ("remove-native", first.scene.nativePlane), ("remove-dock", first.scene.dockView)] where o.hide.contains(name) {
            view.removeFromSuperview()
        }
        if let q = o.quitAfter { DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) } }
    }

    func click(_ p: CGPoint) { main.click(p) }
    func hover(_ p: CGPoint) { main.hover(p) }
    func command(_ command: NormieCommand, tag: Int) { main.command(command, tag: tag) }

    func installSettings(preferences: SettingsPreferences = SettingsPreferences()) {
        let removeConversations: (Set<String>) throws -> Void = { [weak self] ids in
            guard let self else { return }
            for w in self.windows { for id in ids where w.scene.members.contains(where: { $0.id == id }) { w.scene.remove(id, reason: "deleted") } }
            _ = try self.store.remove(ids: ids)
        }
        settings = NativeSettingsWindowController.install(dataSource: SettingsDemoDataSource(store: store, removeConversations: removeConversations),
                                                          preferences: preferences)
        settings?.session.onLocalChange = { [weak self] key, _ in self?.settingChanged(key) }
    }

    private(set) var settings: NativeSettingsWindowController?
    private(set) var debugTools: DebugTools?
    private let tuningHost = SceneTuningHost()
    private var tuningBinding: DebugTuningBinding?
    // MARK: Live Core (f001, f168–f181; docs/reference/CORE-M7-26102909.md, App 接线)

    /// v2's own Core (127.0.0.1:18794, ~/Library/Application Support/Organic Shell v2/Core; launched from the bundled
    /// OrganicCore when none answers), the Codex App Server under it on the user's own login.
    var live: LiveConversationRuntime?
    var core: CoreService?
    var liveError: String?
    let liveSettings = CoreSettingsController()
    let liveArtifacts = CoreArtifactsController()
    let liveTerminals = CoreTerminalController()
    var connection: Task<Void, Never>?

    /// Tools' Attach / Send (TOOLS-M8 交付合同): completions waiting on a composer's send, by its submission UUID.
    var deliveries: [UUID: @MainActor (CoreSubmissionResult) -> Void] = [:]
    /// The Labs' hosts (the Labs hold them weakly).
    private lazy var transitionStage = LabStage(store: store)
    private lazy var springStage = LabStage(store: store)

    /// Tools (f155–f162, Sol's Tools/): one window for the app, made on first use. Without a Live Core its artifacts
    /// are in-memory demo files and Browser, Appshots and the terminal say they are unavailable (DECISIONS #20).
    private(set) lazy var tools = live == nil
        ? ToolsWindowController(artifacts: CoreArtifactsController(), terminal: CoreTerminalController(), demo: ToolsDemoArtifacts())
        : ToolsWindowController(artifacts: liveArtifacts, terminal: liveTerminals)
    var redSeen: [String: Int] = [:]
    var created = 0
    var tearing: TearSession?
    var tearWatch: Timer?

    /// A synthetic pointer sweeps along the dock and leaves, logging me's and the orbs' frames.
    var hoverLog: [[String: Any]] = []
    var hoverTimer: Timer?, swapTimer: Timer?
    var swapLog: [[String: Any]] = []
    var composeLog: [[String: Any]] = []
    static var headerDragPoint = CGPoint.zero

    func applicationWillTerminate(_ n: Notification) {
        isTerminating = true
        save()
        // The live runtime saves its presentation and stops reading; the Core keeps running what it runs.
        // Quitting redraws nothing: its state changes would refresh every workbench on the way out.
        live?.onStateChange = nil
        if !automated { saveWindows() }
        live?.shutdown()
    }
    var automated: Bool { o.automated }
    var resizeLog: [[String: Any]] = []
}
