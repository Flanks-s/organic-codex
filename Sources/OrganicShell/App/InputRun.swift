import AppKit

/// CoreGraphics has no public way to say where in a window an event falls.
@_silgen_name("CGEventSetWindowLocation") private func setEventWindowLocation(_ event: CGEvent, _ point: CGPoint)

/// Real-path checks for press gestures (user 10-31, DECISIONS #81). Every exit of a press goes through AppKit's own event
/// queue (`NSApp.postEvent`), so window routing, hit testing, local monitors and the views' mouse handlers all run, unlike
/// the older demos, which call the scene directly. After each path nothing may be left: no panel, no carrier, no hidden
/// orb, no gesture still active.
///
/// How this differs from a real mouse: the cursor does not move, so tracking areas and `NSEvent.mouseLocation` see the
/// real pointer, and `NSEvent.pressedMouseButtons` stays 0. Reports must say so.
///
/// `--demo-input all` or `--demo-input "esc.dock,tear-back.full"`; results in the receipt's composeLog, read by
/// tools/m11/input-check.py.
extension AppController {
    func demoInput(_ spec: String) { InputRun(app: self, spec: spec).start() }
}

/// One display-link callback for InputRun.syncFlash: runs `fire` with the link, then stops.
@MainActor private final class SyncTick: NSObject {
    /// Points in from the window's top-right corner (x from the right edge, y from the top).
    static let inset = CGPoint(x: 14, y: 6)
    var fire: ((CADisplayLink) -> Void)?
    @objc func tick(_ link: CADisplayLink) { link.invalidate(); let f = fire; fire = nil; f?(link) }
}

@MainActor final class InputRun {
    /// dock: an orb in the Dock. bar: the planet on a Dock bar. grip: a bar's grip. full / brief: a column's header planet.
    enum Source: String, CaseIterable { case dock, bar, grip, full, brief }

    fileprivate let app: AppController
    private let spec: Set<String>
    private static var current: InputRun?
    private var eventNumber = 0
    private var pointer = CGPoint.zero
    private var pointerWindow: OrganicWindow?
    private var found = 0, ran = 0, skipped = 0
    private var strayTranscripts: [String: Int] = [:]
    private var pointerMark: NSView?
    private var followSamples: [[Any]] = [], followID = "", followBegan = 0.0
    private var peekSamples: [[Double]] = [], peekWatchID = "", peekOpened = -1.0, peekLetGo = 0.0
    private var jumpSamples: [[String: Any]] = [], jumpBegan = 0.0
    /// Stands in for NSEvent.pressedMouseButtons: the cursor is not really pressed.
    private var held = false
    private var tearBegan = false
    private var window: OrganicWindow { app.main }
    private var scene: AutoScene { app.scene }

    init(app: AppController, spec: String) {
        self.app = app
        self.spec = Set(spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    func start() {
        Self.current = self
        Task { @MainActor in
            if self.spec.contains("trash-wiring") {
                let driver = TrashWiringRun(app: self.app, window: self.window, io: .init(
                    prepare: {
                        self.pointerWindow = self.window
                        for w in self.app.windows { w.scene.pressedButtons = { [weak self] in self?.held == true ? 1 : 0 } }
                    },
                    press: { await self.press($0) }, carry: { await self.carry(to: $0, over: $1) },
                    release: { self.release() },
                    mouse: { type, p in
                        self.pointer = p; self.markPointer()
                        self.post(type, at: p, pressure: type == .leftMouseUp || type == .rightMouseUp || type == .mouseMoved ? 0 : 1)
                    },
                    key: { self.key($0, $1, $2) }, pointer: { self.pointer },
                    activate: { self.activate() }, sleep: { await self.sleep($0) },
                    sync: { await self.syncFlash() }, log: { self.log($0, $1) }))
                let summary = await driver.run()
                self.log("done", ["spec": "trash-wiring", "ran": summary.ran, "skipped": summary.skipped,
                                  "findings": summary.findings, "checks": summary.checks, "seconds": summary.seconds])
                let tail = min(15, max(0, Double(ProcessInfo.processInfo.environment["INPUT_TAIL"] ?? "") ?? 1))
                await self.sleep(tail)
                // As with trash-proto, WinRec2 must finish before --quit-after ends a recorded app.
                if self.app.o.quitAfter == nil { NSApp.terminate(nil) }
                return
            }
            self.undoLeftReduce()
            await self.sleep(1.0)
            // INPUT_AGE_MINUTES: the mock's conversations as long as after that many minutes of play, as in a session left open.
            if let minutes = Double(ProcessInfo.processInfo.environment["INPUT_AGE_MINUTES"] ?? ""), let mock = self.app.mock {
                let ticks = Int(minutes * 60 / mock.playbackSettings.tickInterval)
                mock.setPaused(true); mock.advance(ticks: ticks); mock.setPaused(false)
                self.log("aged", ["ticks": ticks, "items": self.scene.members.map(\.items.count)])
            }
            // INPUT_QUIET=1: nothing streams or runs (playback paused, every running mock turn stopped), as a window left
            // alone after its work is done, so idle preparation can finish before the first press.
            if ProcessInfo.processInfo.environment["INPUT_QUIET"] == "1", let mock = self.app.mock {
                mock.setPaused(true)
                for c in self.app.store.conversations where c.running { mock.stop(c) }
                self.log("quiet", ["running": self.app.store.conversations.filter(\.running).count,
                                   "sending": self.app.store.conversations.filter(\.sending).count])
            }
            for w in self.app.windows { w.scene.pressedButtons = { [weak self] in self?.held == true ? 1:0 } }
            self.activate()
            if self.spec.contains("keep-app-arrange") { await self.keepAppArrange(); return }
            if self.spec.contains("keep-app") { await self.keepApp(); return }
            if self.spec.contains("keep-app-live") { await self.keepAppLive(); return }
            if self.spec.contains("dock-hover") { await self.dockHover(); NSApp.terminate(nil); return }
            // M11.37 r1: the native trash prototype on a stage over the window (TrashProtoRun). No terminate: --quit-after
            // ends the app after the recording, which never finalizes if the app goes first.
            if self.spec.contains("trash-proto") {
                await TrashProtoRun(window: self.window.window, output: self.app.o.output, log: { self.log($0, $1) }).run(); return
            }
            // INPUT_NO_WATCH=1: idle-cost runs. The stray-transcript watcher is a 120 Hz timer that wakes the main run loop
            // (11-06: it inflated idle app CPU and fed the mode-preparation observer on every pass).
            if ProcessInfo.processInfo.environment["INPUT_NO_WATCH"] != "1" {
                self.watchStrayTranscripts()
                self.watchFocus()
            }
            await self.syncFlash()
            // Idle preparation runs before the first press, as it would for a person.
            await self.sleep(Double(ProcessInfo.processInfo.environment["INPUT_LEAD"] ?? "") ?? 3.0)
            await self.enterScheme()
            self.log("baseline", ["state": self.state(), "backing": self.window.window.backingScaleFactor, "sceneScale": self.scene.scale,
                                  "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"])
            // A run whose window is not key tests a different app: 11-06 a system alert held the MBA's front from about
            // 05:36 and 53 runs went through without Tide or the editing lift. Try once more, then stop and say so.
            if ProcessInfo.processInfo.environment["INPUT_INACTIVE"] != "1", !self.window.window.isKeyWindow {
                self.activate(); await self.sleep(0.5)
                if !self.window.window.isKeyWindow {
                    self.log("abort", ["reason": "window not key at baseline", "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"])
                    NSApp.terminate(nil); return
                }
            }
            // INPUT_CRASH_PROBE=abort|trap: an end-to-end check of the test-run CrashGuard (11-06), crashing right after baseline.
            switch ProcessInfo.processInfo.environment["INPUT_CRASH_PROBE"] {
            case "abort": self.log("crash-probe", ["mode": "abort"]); abort()
            case "trap": self.log("crash-probe", ["mode": "trap"]); let n: Int? = Int("not a number"); _ = n!
            default: break
            }
            await self.runAll()
            self.log("done", ["ran": self.ran, "skipped": self.skipped, "findings": self.found])
            await self.sleep(Double(ProcessInfo.processInfo.environment["INPUT_TAIL"] ?? "") ?? 0.5)
            NSApp.terminate(nil)
        }
    }

    /// INPUT_SCHEME=focused or split: the same paths from Focused or a three-part Split, as a person gets there by Dock menus.
    private func enterScheme() async {
        let scheme = ProcessInfo.processInfo.environment["INPUT_SCHEME"] ?? ""
        guard scheme == "focused" || scheme == "split" else { return }
        scene.enterFocused(scene.current, reason: "input-run")
        await sleep(1.4)
        if scheme == "split" {
            for id in scene.order.filter({ $0 != scene.current }).prefix(2) { scene.graft(id, at: 9, reason: "input-run"); await sleep(1.4) }
        }
    }

    private func wants(_ name: String) -> Bool { spec.contains("all") || spec.contains(name) }

    /// M11.31: the Normie ↔ Organic flight (board Main, D 0.3) by ⌃⌘S as a person presses it: both ways from rest, turned back
    /// 80/280/540/950/1300 ms into either direction, and toggled twice in a row (back at .54 s, forward again .04 s later).
    /// Each key is logged, so a recording can be cut at the board's moments. Six planets take 1.68 s, so rests are 2.3 s.
    /// Needs the window key. INPUT_MODE_REST overrides the rest (a quiet window needs about 4 s for its idle picture);
    /// main-thread stalls over 20 ms are logged (watchStalls) as in mode-turn-ten.
    private func modeOrrery() async {
        let rest = Double(ProcessInfo.processInfo.environment["INPUT_MODE_REST"] ?? "") ?? 2.3
        func press(_ label: String) { modeKey(); log("mode-orrery " + label, ["to": window.shell.mode == .normie ? "organic" : "normie"]) }
        if window.shell.mode != .normie { modeKey(); await sleep(rest) }
        watchStalls()
        log("mode-orrery start", ["columns": scene.columns.count, "orbs": scene.order.count])
        press("forward"); await sleep(rest)
        press("reverse"); await sleep(rest)
        for ms in [80, 280, 540, 950, 1300] {
            press("forward turn-\(ms) go"); await sleep(Double(ms) / 1000); press("forward turn-\(ms) back"); await sleep(rest)
            press("to organic"); await sleep(rest)
            press("reverse turn-\(ms) go"); await sleep(Double(ms) / 1000); press("reverse turn-\(ms) back"); await sleep(rest)
            press("to normie"); await sleep(rest)
        }
        press("toggle go"); await sleep(0.54); press("toggle back"); await sleep(0.04); press("toggle again"); await sleep(rest)
        press("end"); await sleep(rest)
        log("mode-orrery done", ["mode": window.shell.mode == .normie ? "normie" : "organic"])
    }

    /// M11.31 round 7: ten turn-backs in a row (⌃⌘S every 0.12 s, then every 0.3 s), where the window photos are
    /// flattened from the fourth on; logs every main-thread stall over 20 ms (watchStalls) while it runs. Needs the window key.
    /// INPUT_MODE_REST overrides the rest; INPUT_TURN_GAPS="0.12,0.3,0.7" adds runs at other gaps (0.7 s lets a cold
    /// picture finish between keys).
    private func modeTurnTen() async {
        let env = ProcessInfo.processInfo.environment
        let rest = Double(env["INPUT_MODE_REST"] ?? "") ?? 2.3
        let gaps = (env["INPUT_TURN_GAPS"] ?? "0.12,0.3").split(separator: ",").compactMap { Double($0) }
        if window.shell.mode != .normie { modeKey(); await sleep(rest) }
        watchStalls()
        for gap in gaps {
            let label = gap == 0.12 ? "fast" : gap == 0.3 ? "slow" : "gap \(gap)"
            for k in 0..<10 { modeKey(); log("mode-turn-ten \(label) \(k)", ["to": window.shell.mode == .normie ? "organic" : "normie"]); await sleep(gap) }
            await sleep(rest)
            if window.shell.mode != .normie { modeKey(); await sleep(rest) }
        }
        log("mode-turn-ten done", ["mode": window.shell.mode == .normie ? "normie" : "organic"])
    }

    /// M11.31 round 14 (Advisor): after every switch and every turn-back the keyboard goes back where it was in that mode.
    /// Normie's composer and then Organic's current composer get the focus by hand; after that only ⌃⌘S moves between
    /// them: plain switches each way, then turn-backs at 0.28 s each way, one letter typed once the flight is over (counted:
    /// it must land in the composer the mode shows for its current conversation), and one 0.4 s after the key, mid flight
    /// (logged only). Mock text only.
    /// Needs the window key.
    private func modeType() async {
        let rest = 2.3
        // The same conversation's composer is one object in both modes (it moves with the mode), so a letter is judged by
        // the composer the current mode shows for its current conversation, not by which mode's accessor saw it.
        func target() -> NativeComposer? {
            window.shell.mode == .normie ? window.workbench.detail.composer : scene.conversation(scene.current).map { scene.composer(for: $0) }
        }
        func normie() -> String { window.workbench.detail.composer?.text ?? "-" }
        func organic() -> String { scene.conversation(scene.current).map { scene.composer(for: $0).text } ?? "-" }
        func mode() -> String { window.shell.mode == .normie ? "normie" : "organic" }
        func typeLetter(_ c: String, _ label: String, expect: String?) async {
            let t = target(), before = (t?.text ?? "", normie(), organic())
            key(0, c); await sleep(0.15)
            let landed = t != nil && t?.text != before.0 ? "composer" : normie() != before.1 || organic() != before.2 ? "another composer" : "nowhere"
            if let expect { ran += 1; if landed != expect { found += 1 } }
            log("mode-type \(label)", ["letter": c, "landed": landed, "expect": expect ?? "(logged only)", "mode": mode(),
                "first": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"])
        }
        if window.shell.mode != .normie { modeKey(); await sleep(rest) }
        window.workbench.detail.composer?.focus(); await sleep(0.3)
        await typeLetter("a", "normie focused by hand", expect: "composer")
        modeKey(); await sleep(0.4); await typeLetter("b", "to organic, mid flight", expect: nil); await sleep(rest)
        if let c = scene.conversation(scene.current) { scene.composer(for: c).focus() }; await sleep(0.3)
        await typeLetter("c", "organic focused by hand", expect: "composer")
        modeKey(); await sleep(0.4); await typeLetter("d", "to normie, mid flight", expect: nil); await sleep(rest)
        await typeLetter("e", "to normie, after the flight", expect: "composer")
        modeKey(); await sleep(rest); await typeLetter("f", "to organic, after the flight", expect: "composer")
        modeKey(); await sleep(0.28); modeKey(); await sleep(rest); await typeLetter("g", "organic, turned back at 0.28 s", expect: "composer")
        modeKey(); await sleep(rest); await typeLetter("h", "to normie again, after the flight", expect: "composer")
        modeKey(); await sleep(0.28); modeKey(); await sleep(rest); await typeLetter("i", "normie, turned back at 0.28 s", expect: "composer")
        modeKey(); await sleep(0.28); modeKey(); await sleep(0.4); await typeLetter("j", "normie, turned back, mid flight", expect: nil); await sleep(rest)
        log("mode-type done", ["mode": mode(), "normie": normie().suffix(12).description, "organic": organic().suffix(12).description])
    }

    /// M11.31 fade (Advisor 11-05; Sol's review 9, item 2): ⌘1–9 pressed while a switch is still taking its picture (0.15 s
    /// after ⌃⌘S), and again after the content has handed over (0.9 s). Organic ⌘n makes the nth member in screen order
    /// current (a column full or an orb landed); Normie ⌘n selects it. When the flight is over, the one picked must be the
    /// one shown, and a letter typed then must land in its composer (counted). Mock text only. Needs the window key.
    private func modeSelect() async {
        let rest = 2.3
        func mode() -> String { window.shell.mode == .normie ? "normie" : "organic" }
        func shown() -> String? { window.shell.mode == .normie ? window.workbench.selectedConversation?.id : scene.current }
        func composer() -> NativeComposer? {
            window.shell.mode == .normie ? window.workbench.detail.composer : scene.conversation(scene.current).map { scene.composer(for: $0) }
        }
        func member(_ n: Int) -> String? {
            let order = scene.order
            guard order.indices.contains(n - 1) else { return nil }
            key(UInt16([18, 19, 20, 21, 23][n - 1]), "\(n)", [.command])
            return order[n - 1]
        }
        func check(_ label: String, expect: String?, letter: String) async {
            let c = composer(), before = c?.text ?? ""
            key(0, letter); await sleep(0.15)
            let landed = c != nil && c?.text != before, ok = expect != nil && shown() == expect && landed && !window.shell.flight.running
            ran += 1; if !ok { found += 1 }
            log("mode-select \(label)", ["mode": mode(), "expect": expect ?? "-", "shown": shown() ?? "-", "letter": letter,
                "landed": landed ? "composer" : "nowhere", "flightRunning": window.shell.flight.running, "ok": ok,
                "first": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"])
        }
        if window.shell.mode != .normie { modeKey(); await sleep(rest) }
        guard scene.order.count >= 4 else { log("mode-select skipped", ["members": scene.order.count]); return }
        watchStalls()
        window.workbench.detail.composer?.focus(); await sleep(0.3)
        modeKey(); await sleep(0.15); var picked = member(2); log("mode-select pressed", ["to": "organic", "member": 2, "at": 0.15])
        await sleep(rest); await check("to organic, ⌘2 during the picture", expect: picked, letter: "k")
        modeKey(); await sleep(0.15); picked = member(3); log("mode-select pressed", ["to": "normie", "member": 3, "at": 0.15])
        await sleep(rest); await check("to normie, ⌘3 during the picture", expect: picked, letter: "l")
        // ⌘4 timing sweep (Advisor 11-06): INPUT_SELECT_LATE moves the ⌘4 press, default 0.9 s after the switch key.
        let late = Double(ProcessInfo.processInfo.environment["INPUT_SELECT_LATE"] ?? "") ?? 0.9
        modeKey(); await sleep(late); picked = member(4); log("mode-select pressed", ["to": "organic", "member": 4, "at": late])
        await sleep(rest); await check("to organic, ⌘4 after the handover", expect: picked, letter: "m")
        modeKey(); await sleep(0.9); picked = member(1); log("mode-select pressed", ["to": "normie", "member": 1, "at": 0.9])
        await sleep(rest); await check("to normie, ⌘1 after the handover", expect: picked, letter: "n")
        log("mode-select done", ["mode": mode()])
    }

    /// M11.31 fade (Advisor 11-05; Sol's review 9, item 8): Reduce Motion turned on in the middle of a flight, with the app's
    /// own switch for it (`toggle.simulateReduceMotion`, Settings' preview; never the system setting), then switches and a
    /// turn-back with it on, then off again mid flight. Every switch must end in the mode asked for with no flight left
    /// running, and a letter typed then must land in the shown composer (counted). The switch is put back as it was; a
    /// marker undoes it at the next driver start if the app was stopped in between. Mock text only. Needs the window key.
    private func modeReduce() async {
        let rest = 2.3, d = UserDefaults.standard, k = "toggle.simulateReduceMotion"
        let was = d.object(forKey: k)
        d.set(was == nil ? "absent" : (d.bool(forKey: k) ? "on" : "off"), forKey: Self.reduceMarker)
        defer { if let was { d.set(was, forKey: k) } else { d.removeObject(forKey: k) }; d.removeObject(forKey: Self.reduceMarker) }
        func mode() -> String { window.shell.mode == .normie ? "normie" : "organic" }
        func composer() -> NativeComposer? {
            window.shell.mode == .normie ? window.workbench.detail.composer : scene.conversation(scene.current).map { scene.composer(for: $0) }
        }
        func check(_ label: String, expect: String, letter: String) async {
            let c = composer(), before = c?.text ?? ""
            key(0, letter); await sleep(0.15)
            let landed = c != nil && c?.text != before, ok = mode() == expect && landed && !window.shell.flight.running
            ran += 1; if !ok { found += 1 }
            log("mode-reduce \(label)", ["mode": mode(), "expect": expect, "letter": letter, "landed": landed ? "composer" : "nowhere",
                "flightRunning": window.shell.flight.running, "reduce": Motion.reduce, "ok": ok])
        }
        d.set(false, forKey: k)
        if window.shell.mode != .normie { modeKey(); await sleep(rest) }
        watchStalls()
        window.workbench.detail.composer?.focus(); await sleep(0.3)
        modeKey(); await sleep(0.3); d.set(true, forKey: k); log("mode-reduce on", ["at": 0.3, "flightRunning": window.shell.flight.running])
        await sleep(rest); await check("to organic, on at 0.3 s", expect: "organic", letter: "p")
        modeKey(); await sleep(rest); await check("to normie, on", expect: "normie", letter: "q")
        modeKey(); await sleep(0.2); modeKey(); await sleep(rest); await check("turned back at 0.2 s, on", expect: "normie", letter: "r")
        modeKey(); await sleep(0.3); d.set(false, forKey: k); log("mode-reduce off", ["at": 0.3, "flightRunning": window.shell.flight.running])
        await sleep(rest); await check("to organic, off at 0.3 s", expect: "organic", letter: "s")
        modeKey(); await sleep(rest); await check("to normie, off", expect: "normie", letter: "t")
        log("mode-reduce done", ["mode": mode()])
    }
    static let reduceMarker = "inputRun.simulateReduceMotionWas"
    /// A run stopped inside mode-reduce left the app's simulate switch as the scene set it: put back what it was.
    private func undoLeftReduce() {
        let d = UserDefaults.standard
        guard let was = d.string(forKey: Self.reduceMarker) else { return }
        if was == "absent" { d.removeObject(forKey: "toggle.simulateReduceMotion") } else { d.set(was == "on", forKey: "toggle.simulateReduceMotion") }
        d.removeObject(forKey: Self.reduceMarker); log("mode-reduce undone", ["was": was])
    }

    /// M11.28: the Normie inspector opened by the toolbar's system button (the user's path, not the menu), then closed and
    /// opened fast, across three round trips to Organic, by ⌥⌘I, on a New Chat, after another app, and dragged to 280/420 wide.
    /// Each step logs what the inspector holds (its labels; mock text only). Needs the window key.
    private func inspectorReal() async {
        let w = window
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.action == #selector(NSSplitViewController.toggleInspector(_:)) { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        func labels(_ v: NSView) -> [String] {
            var out: [String] = []
            if let t = v as? NSTextField, !t.isHidden, !t.stringValue.isEmpty { out.append(t.stringValue) }
            for s in v.subviews where !s.isHidden { out += labels(s) }
            return out
        }
        func state(_ label: String) {
            let ins = w.workbench.inspector, text = ins.isViewLoaded ? labels(ins.view) : []
            log("inspector-real \(label)", ["shown": w.shell.inspectorShown, "workbench": w.workbench.inspectorVisible,
                "active": ins.presentationActive, "frame": ins.isViewLoaded ? NSStringFromRect(ins.view.frame) : "",
                "labels": text.count, "first": Array(text.prefix(5)), "mode": w.shell.mode == .normie ? "normie" : "organic",
                "button": find(w.window.contentView?.superview ?? w.window.contentView!).map { b in
                    NSStringFromRect(b.convert(b.bounds, to: nil)) + (b.isHiddenOrHasHiddenAncestor ? " hidden" : "") + (b.window == nil ? " no window" : "") } ?? "none"])
        }
        func validation(_ label: String) {
            let root = w.window.contentView?.superview ?? w.window.contentView!
            let b = find(root), action = #selector(NSSplitViewController.toggleInspector(_:))
            let item = w.window.toolbar?.items.first { $0.itemIdentifier == .toggleInspector }
            let target = NSApp.target(forAction: action, to: b?.target, from: b) as AnyObject?
            var direct: [String: Any] = [:]
            if let v = target as? NSUserInterfaceValidations, let item { direct["validateUserInterfaceItem"] = v.validateUserInterfaceItem(item) }
            if let t = target as? NSToolbarItemValidation, let item { direct["validateToolbarItem"] = t.validateToolbarItem(item) }
            let split = w.shell.split, ins = split.splitViewItems.last
            var info: [String: Any] = direct
            info["buttonEnabled"] = b?.isEnabled ?? false
            info["buttonTarget"] = b?.target.map { String(describing: type(of: $0)) } ?? "nil"
            info["itemEnabled"] = item?.isEnabled ?? false
            info["itemAction"] = item?.action.map(NSStringFromSelector) ?? "nil"
            info["resolvedTarget"] = target.map { String(describing: type(of: $0)) } ?? "nil"
            info["canCollapse"] = ins?.canCollapse ?? false
            info["collapsed"] = ins?.isCollapsed ?? true
            info["min"] = Double(ins?.minimumThickness ?? 0)
            info["max"] = Double(ins?.maximumThickness ?? 0)
            info["width"] = Double(ins?.viewController.view.frame.width ?? 0)
            info["splitDelegate"] = split.splitView.delegate.map { String(describing: type(of: $0)) } ?? "nil"
            info["firstResponder"] = w.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            log("inspector-real validation \(label)", info)
        }
        func click() async {
            guard let b = find(w.window.contentView?.superview ?? w.window.contentView!) else { log("inspector-real no button"); return }
            let p = w.scene.dock.view.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), from: b)
            pointerWindow = w; hover(p); await press(p); await sleep(0.06); release(); hover(nil)
        }
        func drag(toWidth width: CGFloat) async {
            let ins = w.workbench.inspector.view, frame = w.scene.dock.view.convert(ins.bounds, from: ins)
            let p = CGPoint(x: frame.minX - 0.5, y: frame.midY)
            hover(p); await press(p); await carry(to: CGPoint(x: frame.maxX - width, y: p.y), over: 0.5); release(); hover(nil)
            await sleep(0.8)
        }
        if w.shell.mode != .normie { modeKey(); await sleep(1.6) }
        state("normie, closed")
        await click(); await sleep(0.9); state("toolbar open")
        await click(); await sleep(0.9); state("toolbar closed")
        await click(); await sleep(0.9); state("toolbar reopened")
        for _ in 0..<5 { await click(); await sleep(0.15) }
        await sleep(0.9); state("five fast clicks")
        if !w.shell.inspectorShown { await click(); await sleep(0.9) }
        for round in 1...3 {
            modeKey(); await sleep(1.6); state("organic \(round)")
            if round == 3 { key(34, "i", [.option, .command]); await sleep(0.9); state("organic option-cmd-i") }
            modeKey(); await sleep(1.6); state("normie again \(round)")
            if !w.shell.inspectorShown { await click(); await sleep(0.9) }
            state("open after round \(round)")
        }
        key(34, "i", [.option, .command]); await sleep(0.9); state("option-cmd-i")
        key(34, "i", [.option, .command]); await sleep(0.9); state("option-cmd-i again")
        let before = w.workbench.selectedConversation?.id
        command(45, "n"); await sleep(1.2); state("new chat")
        if let before { w.workbench.select(before); await sleep(0.9); state("back to the conversation") }
        if let other = app.store.conversations.first(where: { $0.id != before && !$0.archived })?.id {
            w.workbench.select(other); await sleep(0.9); state("another conversation")
        }
        otherApp(); await sleep(1.0); state("other app"); activate(); await sleep(1.0); state("back")
        validation("before drags")
        await drag(toWidth: 280); state("dragged to 280"); validation("at 280")
        await drag(toWidth: 420); state("dragged to 420"); validation("at 420")
        await click(); await sleep(0.9); state("closed at the end")
        if w.shell.inspectorShown { await click(); await sleep(0.9); state("closed at the end, second click") }
        if w.shell.inspectorShown { key(34, "i", [.option, .command]); await sleep(0.9); state("closed at the end by option-cmd-i") }
    }

    /// M11.30: Auto → Focused → Auto by ⇧⌘Return (MainMenu Focus), then one turned back after 0.15 s, so a recording shows
    /// the Dock's three bubbles and the capsule handing over both ways. Needs the window key.
    private func schemeRound() async {
        for (label, wait) in [("focus", 1.8), ("auto", 1.8), ("focus", 0.15), ("auto reversed", 1.8), ("focus", 1.8), ("auto", 1.8)] {
            key(36, "\r", [.command, .shift]); await sleep(0.02)
            log("scheme-round \(label)", ["focused": scene.isFocused, "dock": scene.order.compactMap { scene.dock.frame(of: $0).map { [$0.minX, $0.width] } }])
            await sleep(wait)
        }
    }

    /// M11.25 and M11.26 on the mock: the Peek's island hovered, pinned and let go, its Reply field clicked, typed in and left, its orb clicked and dragged.
    /// A posted move doesn't reach tracking areas, so the island's hover is told directly (`reconcilePointerHover`); the clicks and keys are real events.
    private func peekFull(_ q: CGPoint) async {
        func peek() -> [String: Any] {
            let h = scene.peekNode.header
            return ["open": scene.peekOpen, "shown": scene.shownPeek ?? "", "expanded": h.state.expanded, "pinned": h.state.pinned, "current": scene.current]
        }
        func capsule() -> CGPoint { let r = scene.peekNode.view.convert(scene.peekNode.header.geometry.capsule, from: scene.peekNode.header); return CGPoint(x: r.midX, y: r.midY) }
        func planet() -> CGPoint { let r = scene.peekNode.view.convert(scene.peekNode.header.geometry.planet, from: scene.peekNode.header); return CGPoint(x: r.midX, y: r.midY) }
        func click(_ p: CGPoint) async { hover(p); await press(p); await sleep(0.06); release(); await sleep(0.4) }
        func open() async { hover(q); await sleep(1.2); log("peek-full open", peek()) }
        func draft() -> String { scene.shownPeek.flatMap { self.scene.conversation($0) }.map { self.scene.composer(for: $0).text } ?? "" }

        await open()
        let g = scene.peekNode.header.geometry.capsule; scene.peekNode.header.reconcilePointerHover(CGPoint(x: g.midX, y: g.midY)); await sleep(0.6); log("peek-full island hovered", peek())
        await click(capsule()); log("peek-full island clicked", peek())
        hover(nil); await sleep(1.0); log("peek-full pinned, pointer away", peek())
        escape(); await sleep(0.3); hover(nil); await sleep(1.0); log("peek-full esc, pointer away", peek())

        await open()
        guard let id = scene.shownPeek, let field = scene.dock.frame(of: id) else { log("peek-full no reply field"); return }
        await click(CGPoint(x: field.midX, y: field.midY)); log("peek-full field clicked", peek().merging(["first": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? ""]) { $1 })
        for c in "hi" { key(0, String(c)); await sleep(0.08) }
        await sleep(0.3); log("peek-full typed", peek().merging(["draft": draft()]) { $1 })
        hover(nil); await sleep(1.0); log("peek-full typed, pointer away", peek())
        escape(); await sleep(0.8); log("peek-full esc", peek())
        await open(); log("peek-full back", peek().merging(["draft": draft()]) { $1 })

        await click(planet()); await sleep(0.8); log("peek-full orb clicked", peek())
        await open()
        let from = planet()
        hover(from); await press(from); await carry(by: CGSize(width: -300, height: 0), over: 0.6); release(); await sleep(1.0)
        log("peek-full orb dragged", peek().merging(["order": scene.order]) { $1 })
    }

    /// M11.30 in a real window: a Peek opened on an orb whose glass is still springing back (a Split identity dragged and let
    /// go, or Esc, then Auto at once), kept open past the spring's end, then a column switch or a reorder with the pointer
    /// still on the Dock. The Peek item's glass is read every 1/120 s from the let-go; a jump on the change's first frame
    /// shows as one step far larger than its neighbours. Only Dock API that HEAD has, so an only-M11.31 build still compiles.
    private func peekRelease() async {
        for variant in ["up.switch", "esc.switch", "up.reorder", "esc.reorder", "drop.switch", "drop.reorder"] {
            ran += 1; pointerWindow = window
            let name = "peek-release.\(variant)"
            if scene.isFocused { scene.leaveFocused(reason: "input-run"); await sleep(1.6) }
            // drop.*: an orb picked up in Auto (long press), carried 20 pt along the Dock and let go with the pointer kept
            // on it. Hovering it then opens its Peek 0.25 s later, while its own release still springs back (0.34 s):
            // the stacked state M11.43 is about. Leaving Split (the other variants) takes too long for that since M11.30.
            let drop = variant.hasPrefix("drop")
            if drop {
                hover(nil); await sleep(0.8)
                guard let p = point(.dock) else { skipped += 1; log(name, ["skipped": "no orb"]); continue }
                hover(p); await press(p); await sleep(0.32)
                await carry(by: CGSize(width: -20, height: 0), over: 0.3)
                release()
            } else {
                scene.enterFocused(scene.current, reason: "input-run"); await sleep(1.4)
                for id in scene.order.filter({ $0 != scene.current }).prefix(2) { scene.graft(id, at: 9, reason: "input-run"); await sleep(1.4) }
                guard let p = point(.bar) else { skipped += 1; log(name, ["skipped": "no identity"]); continue }
                hover(p); await press(p); await sleep(0.32)
                await carry(by: CGSize(width: 0, height: -40), over: 0.3)
                if variant.hasPrefix("esc") { escape(); await sleep(0.05) }
                release(); await sleep(0.03)
            }
            peekSamples = []; peekWatchID = ""; peekOpened = -1; peekLetGo = CACurrentMediaTime()
            // The orb to watch: the one let go (drop), or the first orb in order, which point(.dock) aims at.
            guard var q = point(.dock), let orb = scene.order.first(where: { scene.dock.items[$0]?.role == .orb }) else {
                skipped += 1; log(name, ["skipped": "no orb"]); continue
            }
            if drop, let g = scene.dock.items[orb]?.glass.frame { q = CGPoint(x: g.midX, y: g.midY) }
            peekWatchID = orb; hover(q)
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                let t = CACurrentMediaTime() - self.peekLetGo
                if self.peekOpened < 0, self.scene.peekOpen { self.peekOpened = t }
                guard let g = self.scene.dock.items[self.peekWatchID]?.glass.frame else { return }
                self.peekSamples.append([t, Double(g.minX), Double(g.minY), Double(g.width), Double(g.height)])
            } }
            RunLoop.main.add(timer, forMode: .common)
            var leaveAt = 0.0, spring = scene.dock.items[orb]?.spring.duration ?? 0
            if !drop {
                await sleep(0.2)
                leaveAt = CACurrentMediaTime() - peekLetGo; spring = scene.dock.items[orb]?.spring.duration ?? 0
                scene.leaveFocused(reason: "input-run")
                // A pointer resting since Split sends no moves, and the Dock only hovers on moves: wiggle half a point every
                // frame from the moment Auto begins, so the Peek's delay starts at once (the release lasts about 0.34 s).
                // A Peek only starts when an orb's hover region is entered in Auto (AutoScenePeek.hoverRegion), and the
                // pointer has been on this orb since Split: off the Dock for a frame, so Auto sees it enter.
                hover(nil); await sleep(1.0 / 60)
            }
            let wiggleBegan = CACurrentMediaTime(); var side: CGFloat = 0.5
            // On the orb wherever Auto puts it (its Split slot is elsewhere since M11.30), until the Peek opens: an open
            // Peek's glass would move the aim away.
            while CACurrentMediaTime() - wiggleBegan < 1.6 {
                if !scene.peekOpen, let g = scene.dock.items[orb]?.glass.frame { q = CGPoint(x: g.midX, y: g.midY) }
                hover(CGPoint(x: q.x + side, y: q.y)); side = -side
                await sleep(1.0 / 60)
            }
            // Past the spring's end with the Peek open and the pointer still on its orb, so the Dock's hover is not zero.
            let shown = scene.shownPeek ?? "", changeAt = CACurrentMediaTime() - peekLetGo
            if variant.hasSuffix("switch") {
                let i = scene.columns.indices.first { $0 != scene.fullIndex && scene.columns[$0].conversation.id != peekWatchID } ?? 0
                scene.switchTo(i, reason: "input-run")
            } else if let k = scene.members.firstIndex(where: { $0.id != peekWatchID }) {
                scene.moveMember(scene.members[k].id, by: k + 1 < scene.members.count ? 1 : -1)
            }
            await sleep(1.2)
            timer.invalidate()
            log(name, ["peekOpened": peekOpened, "leaveAt": leaveAt, "orbSpring": spring, "peek": peekWatchID, "shown": shown, "changeAt": changeAt,
                       "stillOrb": scene.dock.items[peekWatchID]?.role == .orb,
                       "order": scene.order, "glass": peekSamples])
            hover(nil); await sleep(1.0)
            report(name)
        }
    }

    /// M11.30: does a glass outline jump on screen when a Peek opens, or Split begins, while the Auto layout is still
    /// moving? The offscreen audit saw neighbours' drawn frames change by up to 45 and 53 pt there with their logical
    /// rects unchanged, but it records no alpha. Every Dock glass's written frame, alpha and hidden state every 1/120 s;
    /// dock-jumps.py finds the one-sample jumps of visible glass. One row: each Dock glass's x, y, width, height, alpha, hidden.
    private func sampleDockGlass() {
        // Effective alpha: every view up the chain, the on-screen (presentation) opacity while one animates.
        func effectiveAlpha(_ view: NSView) -> Double {
            var a = 1.0, v: NSView? = view
            while let s = v { a *= Double(s.layer?.presentation()?.opacity ?? s.layer?.opacity ?? Float(s.alphaValue)); v = s.superview }
            return a
        }
        var row: [String: Any] = ["t": CACurrentMediaTime() - jumpBegan]
        for (id, item) in scene.dock.items {
            let g = item.glass
            row[id] = [Double(g.frame.minX), Double(g.frame.minY), Double(g.frame.width), Double(g.frame.height), effectiveAlpha(g), g.isHiddenOrHasHiddenAncestor ? 1 : 0]
        }
        jumpSamples.append(row)
    }
    /// Variants: a Peek opened and Split begun while the layout moves (a column switch just before) and at rest; an orb
    /// torn out of the window and brought back to the Dock; a Split identity grabbed, let go, then Auto (it turns into an orb).
    private func dockJumps() async {
        for variant in ["peek-layout", "peek-rest", "split-layout", "split-rest", "tear", "identity"] {
            ran += 1; pointerWindow = window
            if scene.isFocused { scene.leaveFocused(reason: "input-run"); await sleep(1.6) }
            hover(nil); await sleep(0.8)
            if variant == "identity" {
                scene.enterFocused(scene.current, reason: "input-run"); await sleep(1.4)
                for id in scene.order.filter({ $0 != scene.current }).prefix(2) { scene.graft(id, at: 9, reason: "input-run"); await sleep(1.4) }
            }
            jumpSamples = []; jumpBegan = CACurrentMediaTime()
            let began = jumpBegan
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sampleDockGlass() } }
            RunLoop.main.add(timer, forMode: .common)
            await sleep(0.2)
            var switchAt = -1.0, actAt = 0.0, opened = -1.0
            if variant.hasSuffix("-layout") {
                let i = scene.columns.indices.first { $0 != scene.fullIndex } ?? 0
                switchAt = CACurrentMediaTime() - began
                scene.switchTo(i, reason: "input-run")
            }
            switch variant {
            case "peek-layout", "peek-rest":
                // The pointer onto an orb at once, moving half a point a frame, so the Peek opens while the layout moves.
                if let q = point(.dock) {
                    actAt = CACurrentMediaTime() - began; var side: CGFloat = 0.5
                    while CACurrentMediaTime() - began < actAt + 1.6 {
                        hover(CGPoint(x: q.x + side, y: q.y)); side = -side
                        if opened < 0, scene.peekOpen { opened = CACurrentMediaTime() - began }
                        await sleep(1.0 / 60)
                    }
                }
            case "split-layout", "split-rest":
                if variant == "split-layout" { await sleep(0.12) }
                actAt = CACurrentMediaTime() - began
                scene.enterFocused(scene.current, reason: "input-run"); await sleep(0.05)
                if let id = scene.order.first(where: { $0 != scene.current }) { scene.graft(id, at: 9, reason: "input-run") }
                await sleep(1.6)
            case "tear":
                if let p = point(.dock) {
                    hover(p); await press(p); await sleep(0.32)
                    await carry(to: outside(p), over: 0.5); await sleep(0.5)
                    actAt = CACurrentMediaTime() - began
                    await carry(to: p, over: 0.5); await sleep(0.2); release()
                    await sleep(1.6)
                }
            default:
                if let p = point(.bar) {
                    actAt = CACurrentMediaTime() - began
                    hover(p); await press(p); await sleep(0.4)
                    await carry(by: CGSize(width: 0, height: -40), over: 0.3); release(); await sleep(0.03)
                    scene.leaveFocused(reason: "input-run"); await sleep(1.6)
                }
            }
            timer.invalidate()
            log("dock-jumps.\(variant)", ["switchAt": switchAt, "actAt": actAt, "peekOpened": opened, "samples": jumpSamples])
            hover(nil); await sleep(1.0)
        }
    }

    /// M11.30: LL dragged along the Dock row into the first bar, then let go, cancelled with Esc, or taken back out
    /// first (round 17's review: the bar kept being trimmed instead of joining). LL is the Dock's first node frame.
    private func meDrag() async {
        watchStalls()
        for variant in ["drop", "esc", "back"] {
            ran += 1; pointerWindow = window
            guard let me = scene.dockFrames.first,
                  let bar = scene.order.compactMap({ scene.dock.items[$0] }).filter({ $0.role == .bar }).map(\.glass.frame).min(by: { $0.minX < $1.minX })
            else { skipped += 1; log("me-drag.\(variant)", ["skipped": "no LL or bar"]); continue }
            let p = CGPoint(x: me.midX, y: me.midY), into = CGPoint(x: bar.minX + 60, y: me.midY)
            log("me-drag.\(variant) begin", ["me": NSStringFromRect(me), "bar": NSStringFromRect(bar)])
            hover(p); await press(p); await sleep(0.32)
            await carry(to: into, over: 0.8); await sleep(0.4)
            switch variant {
            case "esc": escape(); await sleep(0.3); release()
            case "back": await carry(to: p, over: 0.6); await sleep(0.2); release()
            default: release()
            }
            hover(nil); await sleep(1.6)
            log("me-drag.\(variant) end", ["scheme": scene.isFocused ? "focused" : "auto"])
            report("me-drag.\(variant)")
        }
    }

    /// M11.43: LL picked up at rest in Auto without touching the first bar, held, drifted sideways a fraction of a point,
    /// and let go where it is. LL only lifts after 6 pt (pointerDragged), so it is lifted 7 pt straight up first; its
    /// 1.1× growth then steps the first bar aside (the Advisor's listed exception: that frame only, at most the growth,
    /// 12 pt on the pixel grid, no join). Drifting toward the bar stays short of the join (raw gap 10.2 → 9.6 pt). Run
    /// with DOCK_FRAME_LOG for the per-frame gap; letting go in place also shows the release step (0.9 pt in 78dd23f).
    private func meHold() async {
        watchStalls()
        for variant in ["still", "toward", "away"] {
            ran += 1; pointerWindow = window
            if scene.isFocused { scene.leaveFocused(reason: "input-run"); await sleep(1.6) }
            guard let me = scene.dockFrames.first else { skipped += 1; log("me-hold.\(variant)", ["skipped": "no LL"]); continue }
            let p = CGPoint(x: me.midX, y: me.midY), up = CGPoint(x: p.x, y: p.y - 7)
            let side: CGFloat = variant == "toward" ? 1 : variant == "away" ? -1 : 0
            hover(p); await sleep(0.4)
            log("me-hold.\(variant) press", ["me": NSStringFromRect(me)])
            await press(p); await carry(to: up, over: 0.12); await sleep(0.4)
            log("me-hold.\(variant) lifted", ["me": NSStringFromRect(scene.dockFrames.first ?? .zero)])
            for d in [0.25, 0.5, 0.6] as [CGFloat] {
                await carry(to: CGPoint(x: up.x + side * d, y: up.y), over: 0.2); await sleep(0.3)
                log("me-hold.\(variant) drift", ["by": side * d])
            }
            release(); log("me-hold.\(variant) let go")
            hover(nil); await sleep(1.4)
            log("me-hold.\(variant) end", ["scheme": scene.isFocused ? "focused" : "auto"])
            report("me-hold.\(variant)")
        }
    }

    private func runAll() async {
        for source in Source.allCases {
            let s = source.rawValue
            await path("hold.\(s)", source) { p in await self.press(p); await self.sleep(0.4); self.release() }
            await path("nudge.\(s)", source) { p in await self.press(p); await self.carry(by: self.inward(p, 30), over: 0.2); self.release() }
            await path("reorder.\(s)", source) { p in
                await self.press(p); await self.carry(by: CGSize(width: p.x > self.scene.size.width / 2 ? -420 : 420, height: 0), over: 0.5); self.release()
            }
            await path("esc.\(s)", source) { p in
                await self.press(p); await self.carry(by: self.inward(p, 120), over: 0.3)
                self.escape(); await self.sleep(0.25); self.release()
            }
            await path("resign.\(s)", source) { p in
                await self.press(p); await self.carry(by: self.inward(p, 120), over: 0.3)
                self.otherApp(); await self.sleep(0.5); self.release(); await self.sleep(0.2); self.activate()
            }
            await path("tear-back.\(s)", source) { p in
                await self.press(p); await self.carry(to: self.outside(p), over: 0.5)
                await self.carry(to: self.dockRow(near: p), over: 0.5); self.release()
            }
            // A person's flick: up into the reading area and let go, all within the gap's transition.
            for (label, up, hold) in [("flick-one", 0, 0.30), ("flick-one-long", 0, 1.2), ("flick-fast", 0.08, 0.05), ("flick-mid", 0.12, 0.30), ("flick-slow", 0.2, 0.9)] {
                await path("\(label).\(s)", source) { p in
                    await self.press(p); await self.carry(to: CGPoint(x: self.scene.size.width * 0.5, y: self.scene.size.height * 0.56), over: up)
                    await self.sleep(hold); self.release()
                }
            }
            await path("tear-title.\(s)", source) { p in
                await self.press(p); await self.carry(to: self.outside(p), over: 0.5)
                await self.carry(to: CGPoint(x: self.scene.size.width / 2, y: 12), over: 0.4); self.release()
            }
            await path("tear-esc.\(s)", source) { p in
                await self.press(p); await self.carry(to: self.outside(p), over: 0.5)
                self.escape(); await self.sleep(0.25); self.release()
            }
            await path("tear-lost-release.\(s)", source) { p in
                // The release never arrives: the button goes up while another app has the pointer.
                await self.press(p); await self.carry(to: self.outside(p), over: 0.5)
                self.otherApp(); await self.sleep(0.3); self.held = false; await self.sleep(0.6); self.activate()
            }
            await path("tear-mode.\(s)", source) { p in
                await self.press(p); await self.carry(to: self.outside(p), over: 0.5)
                // Only a tear refuses the switch. A press that did not tear (no grip in Split) has nothing to test here.
                if self.scene.isTearing { self.modeKey() }
                await self.sleep(0.5); self.escape(); await self.sleep(0.25); self.release()
            }
            await path("tear-resign.\(s)", source, windows: 2) { p in
                await self.press(p); await self.carry(to: self.outside(p), over: 0.5)
                tearBegan = self.scene.isTearing
                self.otherApp(); await self.sleep(0.5); self.release(); await self.sleep(0.2); self.activate()
            }
            await path("press-landing.\(s)", source) { p in
                await self.press(p); await self.carry(by: self.inward(p, 90), over: 0.25); self.release()
                await self.sleep(0.06)
                if let q = self.point(source) { await self.press(q); await self.carry(by: self.inward(q, 60), over: 0.2); self.release() }
            }
            await path("mode-carry.\(s)", source) { p in
                await self.press(p); await self.carry(by: self.inward(p, 120), over: 0.3)
                self.modeKey(); await self.sleep(0.9); self.release(); await self.sleep(1.2); self.modeKey()
            }
            await path("switch-carry.\(s)", source) { p in
                await self.press(p); await self.carry(by: self.inward(p, 120), over: 0.3)
                self.numberKey("2"); await self.sleep(0.5); self.release()
            }
        }
        // The press the first stuck orb followed in the 10-30 recording (24.05 s): the empty part of the full column's
        // transcript, then a quick move left.
        for (label, x, y) in [("transcript-mid", 0.43, 0.62), ("transcript-low", 0.43, 0.8), ("transcript-text", 0.35, 0.3)] {
            await path(label, .dock) { _ in
                let c = self.scene.columns.first { $0.conversation.id == self.scene.current }?.target ?? .zero
                let q = CGPoint(x: c.minX + c.width * (x - 0.27) / 0.45, y: self.scene.size.height * y)
                self.hover(q); await self.press(q); await self.carry(by: CGSize(width: -160, height: -40), over: 0.18); await self.sleep(0.25); self.release()
            }
        }
        // Normie and back, then each column full in turn (user 11-01: a full column stayed empty for 14 s on real threads,
        // because the mode commit had unmounted the brief columns' transcripts). `.brief` picks a brief column in Normie,
        // `.dock` a Dock conversation, which sends a column to the Dock; `.land` brings that column back before anything else.
        if wants("mode-return") { await modeReturn("mode-return") { nil } }
        if wants("mode-return.brief") { await modeReturn("mode-return.brief") { self.scene.columns.first { $0.conversation.id != self.scene.current }?.conversation.id } }
        for (name, land) in [("mode-return.dock", false), ("mode-return.land", true)] where wants(name) {
            await modeReturn(name, land: land) { self.scene.order.dropFirst(self.scene.columns.count).first }
        }
        if wants("mode-return.going") { await modeReturnGoing() }
        if wants("orb-follow") { await orbFollow() }
        if spec.contains("scheme-round") { await schemeRound() }
        if spec.contains("inspector-real") { await inspectorReal() }
        if spec.contains("mode-orrery") { await modeOrrery() }
        if spec.contains("mode-turn-ten") { await modeTurnTen() }
        if spec.contains("mode-type") { await modeType() }
        if spec.contains("mode-select") { await modeSelect() }
        if spec.contains("mode-reduce") { await modeReduce() }
        if spec.contains("pointer-sweep") { await pointerSweep() }
        // M11.33 Pulse: events into the store as the Core shapes them (PulseDriver, written by Sol); hover is a posted mouse move.
        if spec.contains(where: { $0.hasPrefix("p-pulse") }) {
            await PulseDriver(app: app, window: window, log: { self.log($0, $1) }, sleep: { await self.sleep($0) },
                              hover: { self.post(.mouseMoved, at: $0 ?? CGPoint(x: -100, y: -100), pressure: 0) },
                              click: { await self.press($0); self.release(); await self.sleep(0.02) }, escape: { self.escape() }).run(spec)
        }
        // A Tide run must keep key through cleanup. p-tide-app-switch resigns on purpose and p-tide-close closes the window,
        // so only those two may lose it.
        let tideKeyToken = spec.contains(where: { $0.hasPrefix("p-tide") }) && !spec.contains("p-tide-app-switch")
            && !spec.contains("p-tide-close") ? beginKeyLossWatch(during: "tide") : nil
        // M11.34 Tide (TideDriver, written by Sol): mock-only events into the store; filters its own p-tide-* specs.
        await TideDriver(app: app, window: window, log: { self.log($0, $1) }, sleep: { await self.sleep($0) },
                         hover: { self.post(.mouseMoved, at: $0 ?? CGPoint(x: -100, y: -100), pressure: 0) },
                         click: { await self.press($0); self.release(); await self.sleep(0.02) }, escape: { self.escape() }).run(spec)
        endKeyLossWatch(tideKeyToken)
        // p-tide-close closes the window: nothing after it has a window to drive. The r7 and r8 close runs trapped in
        // columnsInTurn on the MBA (11-06), and a window.isVisible guard there did not catch it.
        if spec.contains("p-tide-close") { return }
        if spec.contains("reorder-drag") { await reorderDrag() }
        if spec.contains("flight-wheel") { await flightWheel() }
        if spec.contains("picker-wheel") { await pickerWheel() }
        if spec.contains("orbit-retire") { await orbitRetire() }
        // A transfer or Collapse completes a pending switch at once, with no flight to end.
        if wants("mode-return.settle") { await modeReturn("mode-return.settle", settle: true) { nil } }
        // An activity line around the start of a switch: before it, in the same moment, and during it. Reads every island on
        // every frame, since a line with no glass under it lasts only as long as the motion (board 261031j, 1 switch of 24).
        if wants("notify-switch") {
            for (label, offset) in [("before", -0.5), ("start", 0.0), ("during", 0.15)] {
                for target in [true, false] {
                    ran += 1
                    let next = (scene.fullIndex + 1) % scene.columns.count
                    guard let column = target ? (scene.columns.indices.contains(next) ? scene.columns[next] : nil) : scene.columns.first(where: { $0.conversation.id == scene.current }) else { continue }
                    func notify() { column.conversation.question = column.conversation.question == nil ? "A question" : nil; scene.store.changed(column.conversation); if let i = scene.columns.firstIndex(where: { $0 === column }) { column.configureIsland(column.islandVariant, width: scene.columns[i].target.width) } }
                    if offset < 0 { notify(); await sleep(-offset) }
                    let began = CACurrentMediaTime()
                    hover(CGPoint(x: scene.columns[next].target.midX, y: scene.size.height * 0.5))
                    let q = CGPoint(x: scene.columns[next].target.midX, y: scene.size.height * 0.5)
                    await press(q); await sleep(0.03); release()
                    if offset == 0 { notify() }
                    var outside = 0, sent = offset >= 0 && offset == 0
                    while CACurrentMediaTime() - began < 1.5 {
                        if !sent, CACurrentMediaTime() - began > offset { notify(); sent = true }
                        for island in scene.columns.compactMap(\.island) where island.eventOutsideCapsule { outside += 1 }
                        await sleep(1.0 / 120)
                    }
                    let left = outside > 0 ? ["activity line with no glass under it on \(outside) samples"] : []
                    found += left.count
                    log("notify-switch \(label) \(target ? "going-full" : "going-brief")", ["findings": left, "state": state()])
                    await sleep(4)
                    if column.conversation.question != nil { column.conversation.question = nil; scene.store.changed(column.conversation) }
                    await sleep(1)
                }
            }
        }
        if ["long-seq", "long-switch", "long-scroll", "long-arrange", "long-resize"].contains(where: wants) { await longSequence() }
        // Peek open and closed in a loop, for Animation Hitches (M13.2 adds two pieces of glass while it is open).
        if spec.contains("peek-loop"), let q = point(.dock) {
            for k in 0..<8 {
                log("peek-loop", ["k": k]); hover(q); await sleep(1.0)
                log("peek-loop open", ["k": k, "peek": scene.dock.hasPeek]); hover(nil); await sleep(0.8)
            }
        }
        if spec.contains("peek-full"), let q = point(.dock) { await peekFull(q) }
        if spec.contains("peek-release") { await peekRelease() }
        if spec.contains("dock-jumps") { await dockJumps() }
        if spec.contains("me-drag") { await meDrag() }
        if spec.contains("me-hold") { await meHold() }
        // M11.36 orb switch and orb menu (decision #132): mock only, the scene stops at once without a mock.
        if spec.contains("orb-switch") { await orbSwitch() }
        // M11.39 LL hover (decision #136): mock only, the scene stops at once without a mock.
        if spec.contains("sun-hover") { await sunHoverScene() }
        if spec.contains("long-wheel") { await wheelTrials() }
        if spec.contains("long-early") { await earlyWheelTrials() }
        if spec.contains("long-goal") { await goalFlightTrials() }
        if spec.contains("long-slide") { await slideTrials() }
        // Switching columns as a person does: the pointer rests on a brief column for a while, then a click. Reports how
        // long from the press to the commit, and whether the prepared switch was used (input-switches.py).
        if wants("switch-seq") {
            for pass in 0..<2 { for wait in [4.0, 2.0, 1.0, 0.5, 0.25, 0.12] {
                let i = scene.columns.indices.filter { $0 != scene.fullIndex }.first ?? 0
                let c = scene.columns[i].target, q = CGPoint(x: c.midX, y: scene.size.height * 0.5)
                // A real pointer sends moved events all the way: the old hover prepared the whole switch in each of them.
                let began = CACurrentMediaTime(); var wiggle: CGFloat = 0
                while CACurrentMediaTime() - began < wait { wiggle = -wiggle + 1; hover(CGPoint(x: q.x + wiggle, y: q.y)); await sleep(1.0 / 60) }
                log("switch press", ["wait": wait, "pass": pass, "to": scene.columns[i].conversation.id])
                await press(q); await sleep(0.03); release()
                await sleep(1.1)
            } }
        }
        // Every orb flight of a mode switch, each way: where each token was on every frame, for the per-type frame sheets
        // the user will mark up (M11.2, tools/m11/flight-sheets.swift). flight-log.json lands beside the receipt.
        if wants("flights") {
            var kinds: [String: String] = [:], samples: [[String: Any]] = []
            for (id, item) in scene.dock.items { kinds["planet." + id] = item.role == .bar ? "bar" : "dock-orb" }
            for island in scene.columns.compactMap(\.island) {
                guard let id = island.configuration?.id else { continue }
                kinds["planet.header." + id] = id == scene.current ? "header-full" : "header-brief"
            }
            kinds["me"] = "me"; kinds["composer"] = "composer"
            func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
            var leg = 0
            window.shell.flight.onExposureSample = { s in
                samples.append(["leg": leg, "id": s.id, "t": s.time, "now": rect(s.now), "painted": rect(s.painted)])
            }
            for k in 0..<2 {
                leg = k
                log("flight leg", ["leg": k, "to": k == 0 ? "normie" : "organic"])
                modeKey(); await sleep(1.8)
            }
            window.shell.flight.onExposureSample = nil
            if let out = app.o.output, (try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)) != nil, let data = try? JSONSerialization.data(withJSONObject: ["kinds": kinds, "samples": samples, "size": [scene.size.width, scene.size.height]]) {
                try? data.write(to: URL(fileURLWithPath: out + "/flight-log.json"))
            }
        }
        // A click on a brief island's title: its activity line must still go when its time is up, and the keyboard stays put.
        if wants("island-click") {
            if let i = scene.columns.compactMap(\.island).first(where: { $0.configuration?.id != scene.current }) {
                let r = scene.dock.view.convert(i.geometry.capsule, from: i)
                await press(CGPoint(x: r.midX, y: r.midY)); await sleep(0.04); release(); await sleep(0.3)
                log("island clicked", ["focus": i.state.focused, "pinned": i.state.pinned, "expanded": i.state.expanded, "firstResponderIsTitle": window.window.firstResponder === i.titleButton])
                await press(CGPoint(x: r.midX, y: r.midY)); await sleep(0.04); release(); await sleep(0.3)
                log("island clicked again", ["focus": i.state.focused, "pinned": i.state.pinned, "expanded": i.state.expanded])
            }
        }
        // M11.10: an expanded island owns its glass. Every point of the capsule must reach the island, for a full column and a brief one,
        // and a text-selecting drag across it must not select the transcript under it.
        if wants("island-layer") {
            for full in [true, false] {
                ran += 1
                guard let i = scene.columns.compactMap(\.island).first(where: { !$0.isHiddenOrHasHiddenAncestor && ($0.configuration?.id == scene.current) == full }),
                      let column = scene.columns.first(where: { $0.island === i }), let root = window.window.contentView, let frame = root.superview else { continue }
                var left: [String] = []
                let compact = scene.dock.view.convert(i.geometry.capsule, from: i)
                let center = CGPoint(x: compact.midX, y: compact.midY)
                hover(center); await press(center); await sleep(0.04); release(); await sleep(0.7)
                if !i.state.expanded { left.append("the island didn't expand on a click") }
                let glass = scene.dock.view.convert(i.geometry.capsule, from: i)
                var through = 0, off = 0, samples = 0
                for fx in stride(from: 0.08, through: 0.92, by: 0.12) {
                    for fy in stride(from: 0.1, through: 0.9, by: 0.16) {
                        let p = CGPoint(x: glass.minX + glass.width * fx, y: glass.minY + glass.height * fy)
                        guard let hit = frame.hitTest(frame.convert(p, from: scene.dock.view)) else { off += 1; samples += 1; continue }
                        samples += 1
                        if scene.columns.contains(where: { hit.isDescendant(of: $0.native) }) { through += 1 }
                        else if !hit.isDescendant(of: i) { off += 1 }
                    }
                }
                if through > 0 { left.append("\(through) of \(samples) points of the expanded capsule reach a transcript") }
                if off > 0 { left.append("\(off) of \(samples) points of the expanded capsule miss the island") }
                let from = CGPoint(x: glass.minX + glass.width * 0.2, y: glass.minY + glass.height * 0.8), selectedBefore = selectedCharacters(in: column.native)
                hover(from); await press(from); await carry(by: CGSize(width: glass.width * 0.5, height: 0), over: 0.2); release(); await sleep(0.2)
                let selected = selectedCharacters(in: column.native) - selectedBefore
                if selected != 0 { left.append("a drag on the glass selected \(selected) characters of the transcript") }
                found += left.count
                log("island-layer \(full ? "full" : "brief")", ["findings": left, "expanded": i.state.expanded, "glass": NSStringFromRect(glass), "samples": samples, "state": state()])
                await sleep(0.6)
                escape(); await sleep(0.5); hover(nil); await sleep(0.3)
            }
        }
        // How long each island stays in its wider states while the mock streams, with nothing pressed (M11.5).
        if wants("island-watch") {
            for _ in 0..<120 {
                log("island", ["islands": scene.columns.compactMap(\.island).map { i in
                    ["id": i.configuration?.id ?? "", "shape": "\(i.state.shape)", "event": i.state.activity?.text ?? "", "hover": i.state.hovering, "focus": i.state.focused, "pinned": i.state.pinned] as [String: Any]
                }])
                await sleep(0.25)
            }
        }
        // The cold mode-switch source picture (M11.2's white band, 10-30 41.15 s): built at rest and with the Dock's nodes
        // hidden as a flight hides them. Writes each picture and counts near-white pixels.
        if wants("white-probe") {
            func probe(_ name: String) async {
                let root = window.shell.view
                let b = ModeSurfaceBuilder(root, scale: window.window.backingScaleFactor, includeWindowFrame: false, excluding: [window.shell.flight.view])
                while !b.ready { b.step(); await sleep(0.001) }
                guard let picture = b.finish() else { return }
                let image = picture.flattened()
                var white = 0
                if let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) {
                    let bpr = image.bytesPerRow
                    for y in stride(from: 0, to: image.height, by: 2) { for x in stride(from: 0, to: image.width, by: 2) {
                        let o = y * bpr + x * 4
                        if p[o] > 235, p[o + 1] > 235, p[o + 2] > 235 { white += 1 }
                    } }
                }
                log("white probe", ["name": name, "white": white])
                if let out = app.o.output, (try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)) != nil, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out + "/source-\(name).png"))
                }
            }
            await probe("rest")
            let ids = scene.order
            for id in ids { scene.setDockHidden(id, true) }
            await probe("dock-hidden")
            for id in ids { scene.setDockHidden(id, false) }
            scene.enterFocused(scene.current, reason: "probe"); await sleep(1.4)
            await probe("focused")
            scene.leaveFocused(reason: "probe"); await sleep(1.4)
            await probe("after-focused")
            for id in ids { scene.setDockHidden(id, true) }
            await probe("after-focused-hidden")
            for id in ids { scene.setDockHidden(id, false) }
        }
        // The protected motion (planets between their orbit and the island), on the column that has sub-agents: open and
        // close its island twice, then leave the mock to bring its own activity lines.
        if wants("island-orbit") {
            let islands = scene.columns.compactMap(\.island)
            if let i = scene.columns.first(where: { $0.conversation.id == "A" })?.island ?? islands.first {
                let r = scene.dock.view.convert(i.geometry.capsule, from: i)
                log("island orbit", ["id": i.configuration?.id ?? ""])
                for _ in 0..<2 {
                    await press(CGPoint(x: r.midX, y: r.midY)); await sleep(0.04); release(); await sleep(1.6)
                    let open = scene.dock.view.convert(i.geometry.capsule, from: i)
                    await press(CGPoint(x: open.midX, y: min(open.midY, r.midY))); await sleep(0.04); release(); await sleep(1.6)
                }
            }
        }
        // A window dragged to a screen of another density, at this screen's real density afterwards: the scale the scene
        // thinks it has goes wrong first (what a real drag did to the old fixed scale), then follows the window again.
        // Needs no second screen, so the first half is also the negative control for the fix's mechanism.
        if wants("backing") {
            let real = window.window.backingScaleFactor
            scene.backingChanged(real == 2 ? 1 : 2)
            await sleep(1.5)
            for k in 0..<2 { await clickNextColumn(); await sleep(1.6); log("backing wrong \(k)") }
            scene.backingChanged(real)
            await sleep(1.5)
            for k in 0..<2 { await clickNextColumn(); await sleep(1.6); log("backing right \(k)") }
        }
        // Peek opens on hover. The driver calls what RootView.mouseMoved calls: tracking areas only see the real cursor.
        let peekExits: [(String, (CGPoint) async -> Void)] = [
            ("leave", { _ in self.hover(nil) }),
            ("press-orb", { p in await self.press(p); await self.sleep(0.08); self.release() }),
            ("drag-orb", { p in await self.press(p); await self.carry(by: self.inward(p, 200), over: 0.3); self.release() }),
            ("flick-orb", { p in await self.press(p); await self.carry(to: CGPoint(x: p.x - 160, y: self.scene.size.height * 0.56), over: 0.1); await self.sleep(0.3); self.release() }),
            ("tear-orb", { p in await self.press(p); await self.carry(to: self.outside(p), over: 0.3); self.escape(); await self.sleep(0.2); self.release() }),
            ("click-column", { _ in
                let c = (self.scene.columns.first { $0.conversation.id != self.scene.current }?.target.midX) ?? 200
                let q = CGPoint(x: c, y: self.scene.size.height * 0.5)
                self.hover(q); await self.press(q); await self.sleep(0.05); self.release()
            }),
            ("switch-key", { _ in self.numberKey("2") }),
            ("mode", { _ in self.modeKey(); await self.sleep(1.5); self.modeKey() }),
            ("grip", { _ in
                guard let q = self.point(.grip) else { return }
                self.hover(q); await self.press(q); await self.carry(by: CGSize(width: 40, height: -200), over: 0.15); await self.sleep(0.3); self.release()
            }),
        ]
        for (label, exit) in peekExits {
            await path("peek-\(label)", .dock) { p in
                self.hover(p); await self.sleep(0.75)
                self.log("peek open", ["peek": self.scene.dock.hasPeek])
                await exit(p); self.hover(nil)
            }
        }
        for source in [Source.dock, .bar] {
            let s = source.rawValue
            // Focused and Split decide on the drop: into the capsule grafts, out of it ungrafts, anything else goes back.
            await path("out-of-capsule.\(s)", source) { p in
                await self.press(p); await self.carry(by: CGSize(width: -40, height: -70), over: 0.3); self.release()
            }
            await path("over-capsule.\(s)", source) { p in
                await self.press(p); await self.carry(by: CGSize(width: -220, height: -6), over: 0.4); self.release()
            }
        }
        await path("mode.round", .dock) { _ in self.modeKey(); await self.sleep(1.6); self.modeKey() }
        // New window, merge into it, then everything back: run once, they change how many windows there are.
        await path("tear-desktop.dock", .dock, windows: 2) { p in
            await self.press(p); await self.carry(to: self.desktop(), over: 0.7); self.release(); await self.sleep(0.8)
        }
        await path("tear-merge.dock", .dock, windows: 2) { p in
            guard let other = self.app.windows.last, other !== self.window else { return }
            await self.press(p); await self.carry(to: self.outside(p), over: 0.4)
            await self.carry(to: self.point(inMiddleOf: other), over: 0.5); self.release(); await self.sleep(0.5)
        }
        if wants("tear-merge.dock") { await mergeBack() }
        // Whatever ran above: what a column doesn't hold shows only when it goes full.
        await columnsInTurn("columns-in-turn")
    }

    /// `pick`, in Normie: the conversation to select there before coming back. Stays read-only, so real threads can run it.
    private func modeReturn(_ name: String, land: Bool = false, settle: Bool = false, pick: () -> String?) async {
        watchStalls()
        let before = scene.columns.map(\.conversation.id)
        window.shell.setMode(.normie); await sleep(3)
        if let id = pick() {
            let picked = window.shell.workbench.select(id)
            log(name + " picked", ["id": id, "picked": picked]); await sleep(1)
        }
        log(name + " back")
        window.shell.setMode(.organic)
        if settle { await sleep(0.05); window.shell.settlePendingMode() }
        await sleep(Double(ProcessInfo.processInfo.environment["INPUT_RETURN_REST"] ?? "") ?? 3)
        report(name + " rest")
        if land {
            if let gone = scene.order.dropFirst(scene.columns.count).first(where: before.contains) {
                log(name + " landing", ["id": gone]); scene.land(gone, reason: "input-run"); await sleep(1.8)
                report(name + " landed")
            } else { skipped += 1; log(name, ["skipped": "no column went to the Dock"]) }
        }
        await columnsInTurn(name)
    }

    /// M11.14. A conversation picked in Normie comes back full in the last column. A click elsewhere sends it to the Dock, and two more
    /// clicks each land before the last one settled (81.66, 82.41, 83.135 s in the user's 11-01 recording, whose transcript then stood over
    /// the other columns until 83.900 s). Three paces, each from a fresh visit.
    private func modeReturnGoing() async {
        let name = "mode-return.going"
        watchStalls()
        for pace in [0.72, 0.6, 0.45] {
            ran += 1
            window.shell.setMode(.normie); await sleep(3)
            guard let id = scene.order.dropFirst(scene.columns.count).first else { skipped += 1; log(name, ["skipped": "nothing in the Dock"]); window.shell.setMode(.organic); await sleep(3); return }
            log(name + " picked", ["id": id, "picked": window.shell.workbench.select(id), "pace": pace]); await sleep(1)
            window.shell.setMode(.organic); await sleep(3)
            report(name + " rest")
            for slot in [1, 2, 1] {
                await clickColumn(min(slot, scene.columns.count - 1))
                log(name + " clicked", ["slot": slot, "leaving": Array(scene.leaving.keys), "visitorInColumns": scene.columns.contains { $0.conversation.id == id }])
                await sleep(max(0, pace - 0.13))
            }
            await sleep(1.8)
            report(name + " \(pace)")
        }
    }

    /// M11.8 on real threads: read up until the last message stands mid-viewport, go to another column, come back and keep the wheel going. The goal
    /// flies back to where the reader left it, the transcript takes over mid-flight, and the wheel carries the flight. Reads, every frame, whether that
    /// really happened. Clicks and wheel steps only; nothing typed, nothing sent.
    private func goalFlightTrials() async {
        watchStalls()
        for (name, lines, steps) in [("up", Int32(3), 6), ("down", Int32(-3), 6), ("far", Int32(3), 14), ("up", Int32(3), 6), ("down", Int32(-3), 6), ("far", Int32(3), 14), ("up", Int32(3), 6), ("down", Int32(-3), 6), ("far", Int32(3), 14)] {
            let back = scene.fullIndex, column = scene.columns[back], native = column.native, id = column.conversation.id
            // The same goals the snapshot flies: the brief's own, not simply the last message.
            let width = max(column.target.width, 200), layout = column.modeBrief(column.boundedSummary(columnWidth: width), width: max(60, width - 40), columnWidth: width)
            let goals = layout.parts.compactMap { part -> String? in if case .goal(let g) = part.anchor, part.block != nil { return g }; return nil }
            guard let goalID = goals.last, scene.columns.count > 1 else {
                skipped += 1; log("long-goal \(name) no goal", ["id": id]); await clickColumn((back + 1) % max(1, scene.columns.count)); await sleep(1.4); continue
            }
            ran += 1
            native.scrollToItem(itemID: goalID); await sleep(0.5)
            if let f = native.itemFrame(itemID: goalID) { native.scrollOffset.y = max(0, f.midY - native.bounds.height / 2) }
            await sleep(0.5)
            let text = native.itemNearViewport(goalID) ? native.textSnapshot(itemID: goalID, scale: scene.scale) : nil
            let before = Double(native.scrollOffset.y), goalInView = text.map { native.bounds.contains($0.rect) } ?? false
            log("long-goal \(name) place", ["id": id, "goals": goals.count, "rect": text.map { NSStringFromRect($0.rect) } ?? "none", "bounds": NSStringFromRect(native.bounds), "inView": goalInView])
            await clickColumn((back + 1) % scene.columns.count); await sleep(1.4)
            let switched = scene.switches.count
            await clickColumn(back)
            var waited = 0
            while scene.switches.count == switched, waited < 120 { await sleep(1.0 / 240); waited += 1 }
            let began = CACurrentMediaTime(), q = CGPoint(x: column.target.midX, y: scene.size.height * 0.5)
            var flew = 0, heldFlights = 0, firstHeld: Double?, firstFlight: Double?, posted = 0, offsets: [[Double]] = [], gates: [[String: Any]] = []
            while CACurrentMediaTime() - began < 1.5 {
                let t = CACurrentMediaTime() - began
                if t > 0.12, posted < steps, t > 0.12 + Double(posted) * 0.07 { wheel(at: q, lines: lines); posted += 1 }
                let live = scene.flights[id]?.count ?? 0
                if live > 0 { flew = max(flew, live); if firstFlight == nil { firstFlight = t } }
                if column.hasContinuedTranscriptFlights { heldFlights += 1; if firstHeld == nil { firstHeld = t } }
                // Why the flights did or didn't stay on: the conditions of canContinueTranscriptFlights, read once a frame while they can still matter.
                if live > 0, !column.transcriptHandoff.handedOff, gates.count < 40 {
                    let st = scene.now() - scene.began, nodes = scene.flights[id] ?? [], view = column.transcriptViewportFrame(at: st)
                    let band = CGRect(x: view.minX, y: view.minY + 16, width: view.width, height: max(0, view.height - 44))
                    let boxes = nodes.map { $0.continuationBounds(rect: column.rect.sample(st).rect, form: column.form.sample(st).value, lyricSize: column.lyricSize) }
                    gates.append(["t": st, "prepared": column.transcriptHandoff.preparedFlightVisibility != nil, "presence": column.presence.sample(st).value, "can": column.canContinueTranscriptFlights(at: st, flights: nodes),
                                  "wheel": column.transcriptWheelReady(at: st, flights: nodes), "band": NSStringFromRect(band), "out": zip(nodes, boxes).filter { !band.contains($0.1) }.map { "\($0.0.line.look) \(NSStringFromRect($0.1))" }, "looks": nodes.map { "\($0.line.look)" }])
                }
                if offsets.last?[1] != Double(native.scrollOffset.y) { offsets.append([t, Double(native.scrollOffset.y)]) }
                await sleep(1.0 / 240)
            }
            await sleep(0.4)
            report("long-goal \(name)")
            log("long-goal \(name) read", ["id": id, "goalInView": goalInView, "before": before, "flew": flew, "firstFlight": firstFlight ?? -1, "continued": heldFlights, "firstContinued": firstHeld ?? -1, "shown": column.transcriptHandoff.handoffTime.map { $0 - scene.began } ?? -1, "offsets": offsets, "began": began, "after": Double(native.scrollOffset.y), "gates": gates])
            native.scrollToEnd(); await sleep(0.5)
            await clickColumn((back + 1) % scene.columns.count); await sleep(1.4)
        }
    }

    /// M11.16: the model picker under a wheel with detents. Slow enough to see one step settle, then faster, a reversal, then the pause that returns it to the list.
    /// Changes the mock's model for this run, so mock only.
    private func pickerWheel() async {
        ran += 1
        guard let overlay = scene.overlay(for: scene.current) else { skipped += 1; log("picker-wheel", ["skipped": "no overlay"]); return }
        _ = overlay.presentModelPicker(); await sleep(0.8)
        let q = CGPoint(x: scene.columns[scene.fullIndex].target.midX, y: scene.size.height - 200)
        for (name, steps, lines, gap) in [("slow-down", 4, Int32(-1), 0.5), ("slow-up", 4, Int32(1), 0.5), ("mid", 6, Int32(-1), 0.12), ("fast", 8, Int32(1), 0.06), ("reverse", 4, Int32(-1), 0.12), ("back", 4, Int32(1), 0.12)] {
            log("picker-wheel \(name)", ["began": CACurrentMediaTime()])
            for _ in 0..<steps { wheel(at: q, lines: lines); await sleep(gap) }
            if name == "fast" { await sleep(0.3) }
        }
        await sleep(1.6)
        log("picker-wheel settled", ["began": CACurrentMediaTime()])
        escape(); await sleep(0.8)
        report("picker-wheel")
    }

    /// M11.8: the transcript takes over while flights still fly, and the wheel goes on: several detents during the flight, both ways, so the flights ride
    /// the scroll to the fades. Frames from a recording; stray transcripts and what the flights left are read as everywhere else.
    private func flightWheel() async {
        watchStalls()
        for (name, up) in [("up", 3), ("down", -3), ("up-long", 3)] {
            for k in 0..<3 {
                ran += 1
                let next = (scene.fullIndex + 1) % max(1, scene.columns.count), began = CACurrentMediaTime()
                let c = scene.columns[next], q = CGPoint(x: c.target.midX, y: scene.size.height * 0.5)
                log("flight-wheel \(name) \(k) begin", ["began": began, "id": c.conversation.id])
                await clickColumn(next)
                await sleep(0.1)
                for _ in 0..<(name == "up-long" ? 10 : 4) { wheel(at: q, lines: Int32(up)); await sleep(0.06) }
                await sleep(1.4)
                report("flight-wheel \(name) \(k)")
            }
        }
    }

    /// M11.11: two columns' text while they trade places (user 11-01: slow, fast back and forth as at 11.86-16.29 s in their recording, a release,
    /// Esc). Nothing is torn off, typed or sent, so it can run on real threads. Frames and main-thread turns are read from the recording and the receipt.
    private func reorderDrag() async {
        watchStalls()
        for source in [Source.grip, .full, .brief] {
            for variant in ["slow", "fast", "esc"] {
                guard let p = point(source) else { skipped += 1; log("reorder-drag", ["skipped": source.rawValue]); continue }
                ran += 1; pointerWindow = window
                let name = "reorder-drag.\(source.rawValue).\(variant)", began = CACurrentMediaTime()
                let far = scene.columns.map(\.target.midX).max { abs($0 - p.x) < abs($1 - p.x) } ?? p.x - 300
                log(name + " begin", ["from": NSStringFromPoint(p), "began": began])
                hover(p); await press(p); await sleep(0.32)
                switch variant {
                case "slow": await carry(to: CGPoint(x: far, y: p.y), over: 1.6); await sleep(0.3); release()
                case "fast":
                    for _ in 0..<5 { await carry(to: CGPoint(x: far, y: p.y), over: 0.35); await carry(to: p, over: 0.35) }
                    await carry(to: CGPoint(x: far, y: p.y), over: 0.35); release()
                default: await carry(to: CGPoint(x: far, y: p.y), over: 0.8); escape(); await sleep(0.3); release()
                }
                hover(nil); await sleep(1.6)
                log(name + " end", ["ended": CACurrentMediaTime()])
                report(name)
            }
        }
    }

    /// M11.11: is what the pointer drags under the pointer? The same moves from a bar's grip and from a header's planet, read on every frame:
    /// where the pointer is, where the dragged node is, and the phase. A ring on screen marks the pointer in recordings (postEvent moves no cursor).
    private final class PointerMark: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private func markPointer() {
        guard let pointerMark else { return }
        pointerMark.frame = CGRect(x: pointer.x - 9, y: pointer.y - 9, width: 18, height: 18)
    }
    private func readFollow() {
        guard !app.windows.isEmpty else { return }
        if followID.isEmpty { followID = scene.pressedNode ?? "" }
        let item = scene.dock.items[followID], r = item.map { $0.motion.rect ?? $0.glass.frame } ?? .zero
        followSamples.append([CACurrentMediaTime() - followBegan, Double(pointer.x), Double(pointer.y), Double(r.midX), Double(r.midY), Double(r.width), Double(r.height), scene.isDragging, scene.isTearing, scene.columns.count])
    }
    private func orbFollow() async {
        let mark = PointerMark(frame: .zero)
        mark.wantsLayer = true; mark.layer?.borderColor = NSColor.systemRed.cgColor; mark.layer?.borderWidth = 2; mark.layer?.cornerRadius = 9
        scene.overlayPlane.addSubview(mark); pointerMark = mark
        defer { pointerMark = nil; mark.removeFromSuperview() }
        for source in [Source.grip, .full, .brief] {
            for variant in ["away-back", "away-drop", "esc", "sideways"] {
                guard let p = point(source) else { skipped += 1; log("orb-follow", ["skipped": source.rawValue]); continue }
                ran += 1; pointerWindow = window
                let name = "orb-follow.\(source.rawValue).\(variant)"
                // Away from where it started: up from a bar at the window's foot, down from a header at its head.
                let away: CGFloat = source == .grip ? -1 : 1
                let began = CACurrentMediaTime()
                followSamples = []; followID = ""; followBegan = began
                let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readFollow() } }
                RunLoop.main.add(timer, forMode: .common)
                log(name + " begin", ["from": NSStringFromPoint(p), "t": began])
                hover(p); await press(p); await sleep(0.32)
                switch variant {
                case "esc":
                    await carry(by: CGSize(width: 0, height: 40 * away), over: 0.4); await sleep(0.3)
                    escape(); await sleep(0.3); release()
                case "sideways":
                    let others = scene.columns.first { $0.conversation.id != followID }?.target.midX ?? p.x - 300
                    await carry(to: CGPoint(x: others, y: p.y), over: 0.8); await sleep(0.3); release()
                default:
                    await carry(by: CGSize(width: 0, height: 40 * away), over: 0.4); await sleep(0.3)
                    await carry(by: CGSize(width: 0, height: 130 * away), over: 0.6); await sleep(0.5)
                    if variant == "away-back" { await carry(to: p, over: 0.6); await sleep(0.3) }
                    release()
                }
                hover(nil); await sleep(1.4)
                timer.invalidate()
                mark.isHidden = true; mark.removeFromSuperview()
                let left = leftovers(expectedWindows: 1) + transcriptFindings() + strayFindings()
                scene.overlayPlane.addSubview(mark); mark.isHidden = false
                found += left.count
                log(name, ["findings": left, "id": followID, "samples": followSamples, "state": state()])
                if !left.isEmpty { await recover() }
                await sleep(0.8)
            }
        }
    }

    /// A run whose window loses key mid-run, cleanup included, is flagged instead of silently half-valid (Advisor a223460,
    /// after Tide r10's reclaim lost key to another app during its cleanup). Logs "lost-key"; receipt-summary.py then
    /// prints NOT KEY, which stops the MBA lane.
    private func beginKeyLossWatch(during: String) -> NSObjectProtocol? {
        guard ProcessInfo.processInfo.environment["INPUT_INACTIVE"] != "1" else { return nil }
        return NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("lost-key", ["during": during, "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?",
                                       "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"])
            }
        }
    }
    private func endKeyLossWatch(_ token: NSObjectProtocol?) { if let token { NotificationCenter.default.removeObserver(token) } }

    /// M11.47 follow-up (Advisor 056fee0): one real satellite retire-hide for Opus, without the Debug menu. A sub-agent
    /// satellite goes onto the current column's conversation, stays 3 s, then the turn completes: the header holds the
    /// finished moon about 2 s and hides it at its next turn to the back. Mock only.
    private func orbitRetire() async {
        let id = scene.current
        guard let mock = app.mock else { log("orbit-retire skipped", ["reason": "no mock"]); return }
        // Ambient motion stops 8 s after the last input (OrganicWindow.updateAmbient), which froze the moons through the
        // whole retire window on 11-07. Unless ORBIT_RETIRE_NUDGE=0, a pointer move outside the dock every 2 s keeps the
        // window "in use", as a person moving the mouse would; it lands on no control, so nothing hovers.
        let nudge = ProcessInfo.processInfo.environment["ORBIT_RETIRE_NUDGE"] != "0"
        var nudges = 0
        func hold(_ seconds: Double) async {
            guard nudge else { await sleep(seconds); return }
            var left = seconds
            while left > 0 {
                post(.mouseMoved, at: CGPoint(x: -100, y: -100), pressure: 0); nudges += 1
                let step = min(2.0, left); await sleep(step); left -= step
            }
        }
        log("orbit-retire add", ["id": id, "ok": mock.inject(.addSatellite, into: id), "nudge": nudge])
        await hold(3.0)
        log("orbit-retire complete", ["id": id, "ok": mock.inject(.complete, into: id)])
        await hold(Double(ProcessInfo.processInfo.environment["ORBIT_RETIRE_HOLD"] ?? "") ?? 8.0)
        log("orbit-retire end", ["nudges": nudges])
    }

    /// M11.31 observer-only gate (Advisor 11-07): the beforeWaiting observer's cost with a moving pointer, not only timer
    /// wakes. mouseMoved at 120 Hz back and forth along the header islands' orbs, the Dock orbs and the bar, for
    /// POINTER_SWEEP_SECONDS (default 16), 0.5 s per leg; each step also goes through the window's hover path, since posted
    /// moves don't reach tracking areas. Hover and tracking state change on the way, which is what the preparation keys
    /// depend on. Mock only; no press, no dwell.
    private func pointerSweep() async {
        var stops: [CGPoint] = []
        for source in [Source.full, .brief] { if let p = point(source) { stops.append(p) } }
        for id in scene.order {
            if let item = scene.dock.items[id], item.role == .orb { stops.append(CGPoint(x: item.glass.frame.midX, y: item.glass.frame.midY)) }
        }
        if let p = point(.bar) { stops.append(p) }
        guard stops.count >= 2 else { log("pointer-sweep skipped", ["stops": stops.count]); return }
        let seconds = Double(ProcessInfo.processInfo.environment["POINTER_SWEEP_SECONDS"] ?? "") ?? 16
        let began = CACurrentMediaTime()
        var posted = 0, legs = 0
        log("pointer-sweep begin", ["stops": stops.count, "seconds": seconds])
        while CACurrentMediaTime() - began < seconds {
            let a = stops[legs % stops.count], b = stops[(legs + 1) % stops.count]
            for k in 1...60 {
                let f = CGFloat(k) / 60, p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                post(.mouseMoved, at: p, pressure: 0); hover(p); posted += 1
                await sleep(1.0 / 120)
            }
            legs += 1
        }
        hover(nil)
        log("pointer-sweep end", ["posted": posted, "legs": legs, "seconds": CACurrentMediaTime() - began])
    }

    /// What takes the key window or the app's activation, with the step it happened in: 14 Focused paths ran without a key window and
    /// were put down to someone using the Mac, twice, at the same step. Only names, for the receipt.
    private func watchFocus() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let event = note.name.rawValue
                nonisolated(unsafe) let sender = note.object
                MainActor.assumeIsolated {
                    let object = (sender as? NSWindow).map { "\(type(of: $0)) \($0.windowNumber)" } ?? ""
                    self?.logFocus(event, object)
                }
            }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? "?"
            MainActor.assumeIsolated { self?.logFocus("appActivated", app) }
        }
    }
    private func logFocus(_ event: String, _ object: String) {
        // Quitting closes the windows and these still fire: `window` would index an empty list (21 crash reports, all after the receipt).
        guard !app.windows.isEmpty else { return }
        log("focus", ["event": event, "object": object, "active": NSApp.isActive, "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none",
                      "ours": window.window.isKeyWindow, "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", "responder": window.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"])
    }

    /// M11.14: a transcript drawing over the columns though it belongs to no full column. It lasted one motion and was gone by settle, where
    /// every other check looks, so this reads every frame. Reported, and cleared, by the next `report` or `path`.
    private func watchStrayTranscripts() {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readStrayTranscripts() } }
        RunLoop.main.add(timer, forMode: .common)
    }
    private func readStrayTranscripts() {
        guard !app.windows.isEmpty, window.shell.mode == .organic, scene.transcriptsPresented, !scene.inModeHandoff else { return }
        for (id, node) in scene.nodes where node.ownsNative && !node.native.isHiddenOrHasHiddenAncestor && node.native.layer?.isHidden != true {
            if !scene.columns.contains(where: { $0 === node }) { strayTranscripts["\(id), not in the columns", default: 0] += 1 }
            else if node.form.to < 0.5 { strayTranscripts["\(id), a brief column", default: 0] += 1 }
        }
    }
    private func strayFindings() -> [String] {
        defer { strayTranscripts = [:] }
        return strayTranscripts.map { "transcript shown on \($0.value) samples: \($0.key)" }.sorted()
    }

    /// Clicks through the other columns, reading what each shows once it is full. In Focused and Split they are all full already.
    private func columnsInTurn(_ name: String) async {
        guard window.shell.mode == .organic, !scene.composingNew else { return }
        ran += 1
        let count = scene.isFocused ? 0 : scene.columns.count - 1
        for k in 0..<max(0, count) {
            await clickColumn((scene.fullIndex + 1) % scene.columns.count); await sleep(1.8)
            report("\(name) \(k)")
        }
        if count <= 0 { report(name) }
    }

    private func report(_ step: String) {
        let left = transcriptFindings() + strayFindings()
        found += left.count
        log(step, ["findings": left, "state": state(), "transcripts": transcriptsRead(),
                   "idle": scene.idlePrewarmOutcome, "prepared": Array(scene.prewarmed.keys), "missed": scene.prewarmMissReasons])
    }

    private func path(_ name: String, _ source: Source, windows: Int = 1, _ body: (CGPoint) async -> Void) async {
        guard wants(name) else { return }
        guard let p = point(source) else { skipped += 1; log(name, ["skipped": "no \(source.rawValue) source"]); return }
        ran += 1
        pointerWindow = window
        log(name + " begin", ["from": NSStringFromPoint(p)])
        await body(p)
        // The longest spring here is about a second; give it room, then read what is left.
        await sleep(Double(ProcessInfo.processInfo.environment["INPUT_SETTLE"] ?? "") ?? 1.7)
        // A press that can't tear from here (no grip in Split) leaves no second window to expect.
        let left = leftovers(expectedWindows: name.hasPrefix("tear-resign") && !tearBegan ? 1 : windows) + transcriptFindings() + strayFindings()
        found += left.count
        log(name, ["findings": left, "state": state(), "transcripts": transcriptsRead()])
        // A path that left something must not fail the next ones too; the report already has it.
        if windows > 1 && !name.hasPrefix("tear-desktop") && !name.hasPrefix("tear-merge") { await mergeBack() }
        if !left.isEmpty { await recover() }
    }

    private func clickNextColumn() async {
        let i = scene.columns.indices.filter { $0 != scene.fullIndex }.first ?? 0
        await clickColumn(i)
    }

    private func clickColumn(_ i: Int) async {
        let c = scene.columns[i].target, q = CGPoint(x: c.midX, y: scene.size.height * 0.5)
        hover(q); await sleep(0.1)
        await press(q); await sleep(0.03); release()
    }

    /// What a person does to a long conversation, real threads included (tools/m11/long-real.sh): switch columns cold and
    /// warm, after a rest and at speed, read up the history, change the arrangement, resize. Nothing here types, focuses a
    /// composer or sends. Every main-thread turn over 20 ms lands in the receipt as a "stall" (tools/m11/long-check.py).
    private func longSequence() async {
        watchStalls()
        func step(_ name: String) {
            log("long " + name, ["current": scene.current, "items": scene.members.first { $0.id == scene.current }?.items.count ?? 0])
        }
        func next() -> Int { (scene.fullIndex + 1) % max(1, scene.columns.count) }
        let all = wants("long-seq")
        if all || wants("long-switch") {
            for k in 0..<3 { step("cold-\(k)"); await clickColumn(next()); await sleep(1.6) }
            for k in 0..<3 { step("warm-\(k)"); await clickColumn(next()); await sleep(1.6) }
            await sleep(4)
            for k in 0..<3 { step("rested-\(k)"); await clickColumn(next()); await sleep(5) }
            for k in 0..<6 { step("fast-\(k)"); await clickColumn(next()); await sleep(0.45) }
            await sleep(2)
        }
        // Reads up the history at a trackpad's pace, then leaves and comes back.
        if all || wants("long-scroll"), let native = scene.columns.first(where: { $0.conversation.id == scene.current })?.native {
            step("scroll-up")
            for _ in 0..<120 { native.scrollOffset.y -= 60; await sleep(1.0 / 120) }
            await sleep(1)
            step("scrolled-away"); let back = scene.fullIndex; await clickColumn(next()); await sleep(2)
            step("scrolled-back"); await clickColumn(back); await sleep(2)
            step("scrolled-away-2"); await clickColumn(next()); await sleep(2)
            step("scrolled-back-2"); await clickColumn(back); await sleep(2)
        }
        if all || wants("long-arrange") {
            for _ in 0..<(all ? 1 : 3) {
                step("focused"); scene.enterFocused(scene.current, reason: "input-run"); await sleep(2)
                let others = scene.members.map(\.id).filter { $0 != scene.current }
                for (k, id) in others.prefix(2).enumerated() { step("graft-\(k)"); scene.graft(id, at: 9, reason: "input-run"); await sleep(2) }
                for (k, id) in others.prefix(2).enumerated().reversed() { step("ungraft-\(k)"); scene.ungraft(id, reason: "input-run"); await sleep(2) }
                step("auto"); scene.leaveFocused(reason: "input-run"); await sleep(2)
            }
        }
        if all || wants("long-resize") {
            step("resize")
            let frame = window.window.frame
            for k in 0...120 {
                var f = frame; f.size.width -= 200 * sin(.pi * CGFloat(k) / 120)
                window.window.setFrame(f, display: true); await sleep(1.0 / 60)
            }
            window.window.setFrame(frame, display: true); await sleep(2)
        }
        step("end")
    }

    /// The user's freeze (11-01): after a change of width a long conversation doesn't answer for about 0.5 s, and their mouse
    /// wheel has detents. Each change of width with one wheel step at a set delay: when the motion is done to the eye, when
    /// the real transcript takes over, whether the step moves it or is lost, and how far the settle slide goes.
    /// Read by tools/m11/wheel-check.py. Scene calls, except the click, as in long-arrange. Types nothing, sends nothing.
    private func wheelTrials() async {
        watchStalls()
        func nextFull() -> Int { (scene.fullIndex + 1) % max(1, scene.columns.count) }
        for delay in [0.2, 0.4, 0.6, 0.85] {
            for pass in 0..<2 { await widthTrial("click", delay, pass) { await self.clickColumn(nextFull()) } }
            await widthTrial("focused-in", delay, 0) { self.scene.enterFocused(self.scene.current, reason: "input-run") }
            let others = scene.members.map(\.id).filter { $0 != scene.current }
            for (k, id) in others.prefix(2).enumerated() { await widthTrial("graft", delay, k) { self.scene.graft(id, at: 9, reason: "input-run") } }
            for (k, id) in others.prefix(2).enumerated().reversed() { await widthTrial("ungraft", delay, k) { self.scene.ungraft(id, reason: "input-run") } }
            await widthTrial("focused-out", delay, 0) { self.scene.leaveFocused(reason: "input-run") }
        }
    }

    /// M11.8: a wheel step well before the motion ends, one per change of width. How long until the reader sees the transcript move, and which
    /// of the hand-off's conditions was the last to open (user 11-01: input should come back 10-15% before the motion finishes).
    private func earlyWheelTrials() async {
        watchStalls()
        func nextFull() -> Int { (scene.fullIndex + 1) % max(1, scene.columns.count) }
        for delay in [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35] {
            for pass in 0..<3 { await widthTrial("click", delay, pass) { await self.clickColumn(nextFull()) } }
            await widthTrial("focused-in", delay, 0) { self.scene.enterFocused(self.scene.current, reason: "input-run") }
            let others = scene.members.map(\.id).filter { $0 != scene.current }
            for (k, id) in others.prefix(2).enumerated() { await widthTrial("graft", delay, k) { self.scene.graft(id, at: 9, reason: "input-run") } }
            for (k, id) in others.prefix(2).enumerated().reversed() { await widthTrial("ungraft", delay, k) { self.scene.ungraft(id, reason: "input-run") } }
            await widthTrial("focused-out", delay, 0) { self.scene.leaveFocused(reason: "input-run") }
        }
    }

    /// The settle slide (user 11-01, 96.42 s: 60 pt, 0.4 s after the motion looked done): the picture's offset against the transcript's at
    /// settle. Read up by some detents, leave, come back; leave soon after arriving too, while heights are still being refined.
    private func slideTrials() async {
        watchStalls()
        func next() -> Int { (scene.fullIndex + 1) % max(1, scene.columns.count) }
        for detents in [0, 1, 2, 5, 12] {
            for away in [0.25, 1.6] {
                let back = scene.fullIndex, column = scene.columns[back]
                let q = CGPoint(x: column.target.midX, y: scene.size.height * 0.5)
                for _ in 0..<detents { wheel(at: q, lines: 3); await sleep(0.12) }
                await sleep(0.4)
                log("slide left", ["detents": detents, "fromEnd": Double(column.native.distanceFromEnd), "follows": column.native.followsEnd])
                await clickColumn(next()); await sleep(0.85 + away)
                await widthTrial("back-\(detents)-\(away)", 9, 0) { await self.clickColumn(back) }
            }
        }
    }

    private func widthTrial(_ kind: String, _ delay: Double, _ pass: Int, change: () async -> Void) async {
        let settled = scene.settles.count, switched = scene.switches.count
        await change()
        var began = CACurrentMediaTime(), waited = 0
        while scene.switches.count == switched, waited < 60 { await sleep(1.0 / 240); waited += 1 }
        if scene.switches.count > switched, let at = scene.lastSwitch?["at"] as? Double { began = at }
        let last = scene.lastSwitch ?? [:]
        // The column the eye is on: full now, and the widest of them in Focused and Split.
        func subject() -> ColumnNode? { scene.columns.filter { scene.isFull($0.conversation.id) }.max { $0.target.width < $1.target.width } }
        guard let column = subject() else { return }
        let native = column.native, point = CGPoint(x: column.target.midX, y: scene.size.height * 0.5)
        let before = native.scrollOffset.y, picture = column.applied
        var posted: Double?, hit = "", hiddenAtPost = false, reached = [8.0: 0.0, 2.0: 0.0, 1.0: 0.0, 0.5: 0.0, 0.25: 0.0]
        var shown: Double?, settledAt: Double?, moves: [[Double]] = [], offset = before, slide: Double?, atSettle: [Double] = []
        // The last moment each condition of ColumnNode.transcriptReady was still closed. It reads the same springs, with other limits beside them.
        var closed: [String: Double] = [:]
        func readGates(at t: Double, _ elapsed: Double) {
            let r = column.rect, reach = Double(max(r.target.width, r.target.height))
            func left(_ s: Spring, _ moving: Bool) -> Double { let v = s.sample(t); return abs(v.value - s.to) + (moving ? abs(v.velocity) * s.response / (2 * .pi) : 0) }
            func error(_ moving: Bool) -> Double {
                max(left(r.x, moving) + left(r.w, moving), left(r.y, moving) + left(r.h, moving), left(column.form, moving) * reach, left(column.presence, moving) * reach)
            }
            var flight = 0.0
            for f in scene.flights[column.conversation.id] ?? [] {
                let pose = f.screenPose(rect: r.sample(t).rect, form: column.form.sample(t).value), end = f.screenPose(rect: r.target, form: 1)
                let extent = max(f.line.source.width, f.line.source.height, f.line.destination.width, f.line.destination.height)
                flight = max(flight, Double(max(abs(pose.origin.x - end.origin.x), abs(pose.origin.y - end.origin.y)) + abs(pose.scale - end.scale) * extent))
            }
            let reflow = column.fullReflow.map { $0.progress(at: t) < 1 - 0.00001 } ?? false
            for (name, open) in [("place8", error(false) <= 8), ("speed8", error(true) <= 8), ("place16", error(false) <= 16), ("speed16", error(true) <= 16),
                                 ("place24", error(false) <= 24), ("speed24", error(true) <= 24), ("flight1.5", flight <= 1.5), ("flight4", flight <= 4), ("flight8", flight <= 8), ("reflow", !reflow)] where !open {
                closed[name] = elapsed
            }
        }
        while CACurrentMediaTime() - began < 1.5 {
            let now = CACurrentMediaTime()
            if now - began < 1.2 { readGates(at: scene.now() - scene.began, now - began) }
            if posted == nil, now - began >= delay {
                posted = now - began; hiddenAtPost = native.isHidden
                let q = scene.dock.view.convert(point, to: nil)
                hit = window.window.contentView?.hitTest(q).map { String(describing: type(of: $0)) } ?? "nil"
                wheel(at: point, lines: 3)
            }
            let t = scene.now() - scene.began
            let edge = scene.columns.map { Double(MotionStep.edge($0.rect.sample(t).rect, $0.target)) }.max() ?? 0
            for (limit, _) in reached where edge > limit { reached[limit] = now - began }
            if shown == nil, !native.isHidden, native.layer?.isHidden != true { shown = now - began }
            if settledAt == nil, scene.settles.count > settled { settledAt = (scene.settles.last ?? now) - began; atSettle = [Double(native.scrollOffset.y), Double(native.contentHeight), Double(native.distanceFromEnd)] }
            if slide == nil, let a = native.layer?.animation(forKey: "column.settle.slide") as? CABasicAnimation { slide = (a.fromValue as? NSNumber)?.doubleValue }
            let y = Double(native.scrollOffset.y)
            if abs(y - offset) > 0.25 { moves.append([now - began, y]); offset = y }
            await sleep(1.0 / 240)
        }
        log("wheel \(kind)", ["kind": kind, "delay": delay, "pass": pass, "id": column.conversation.id, "items": column.conversation.items.count,
                              "posted": posted ?? -1, "hit": hit, "hiddenAtPost": hiddenAtPost, "before": Double(before), "moves": moves, "settled": settledAt ?? -1,
                              "shown": shown ?? -1, "slide": slide ?? 0, "atSettle": atSettle, "reached": reached.map { [$0.key, $0.value] }, "fromEnd": Double(native.distanceFromEnd),
                              "duration": last["durationSeconds"] ?? 0, "compile": last["compileMs"] ?? 0, "prewarmed": last["prewarmed"] ?? false,
                              "picture": picture.map { [Double($0.offset), Double($0.content)] } ?? [], "fullColumns": scene.columns.filter { scene.isFull($0.conversation.id) }.count,
                              "closed": closed, "commitAt": began, "reflowed": closed["reflow"] != nil])
        // Back to the end, as the next change of width would find it after reading the latest.
        native.scrollToEnd()
        await sleep(1.0)
    }

    private var stallObserver: CFRunLoopObserver?
    /// Logs main-thread turns over 20 ms, from waking up to going back to sleep.
    private func watchStalls() {
        guard stallObserver == nil else { return }
        var woke = CACurrentMediaTime()
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { woke = now; return }
            guard now - woke > 0.02 else { return }
            let began = woke
            MainActor.assumeIsolated { self?.log("stall", ["ms": (now - began) * 1000, "began": began]) }
        }
        stallObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func mergeBack() async {
        guard app.windows.count > 1 else { return }
        app.mergeWindows(into: window)
        await sleep(1.2)
        log("merged back", ["state": state()])
    }

    private func recover() async {
        held = false
        escape(); await sleep(0.3) // a Customize sheet a press in Split opened
        for w in app.windows { w.scene.cancelDrag(); w.scene.dock.headerOrbDragging?.cancelImmediately() }
        await sleep(0.8)
        if window.shell.mode != .organic { modeKey(); await sleep(1.5) }
        await mergeBack()
        activate()
        await sleep(0.5)
    }

    // MARK: M11.36 orb switch (orb-switch, Claude for lane A 11-09, decision #132)
    //
    // Option-click, right-click, Control-click and the keyboard on the orb menu, all through the real RootView /
    // HeaderIsland entries by posted events. Mock only: input-run.sh always passes --mock, and the scene stops at once
    // if there is no mock, because Rename, Archive and Fork change a person's Codex threads.
    private var orbChecks: [[String: Any]] = []

    private func orbCheck(_ name: String, _ pass: Bool, _ extra: [String: Any] = [:]) {
        var e = extra; e["name"] = name; e["pass"] = pass
        orbChecks.append(e)
        log("orb-switch check", e.merging(["state": state()]) { a, _ in a })
    }

    private func orbMenuState() -> [String: Any] {
        let s = scene.orbMenu.state
        return ["open": s.isOpen, "submenu": s.submenu, "selected": s.selected ?? -1, "selectedColumn": s.selectedColumn ?? -1,
                "columns": s.columns.map { "\($0.id)\($0.checked ? "*" : "")" }]
    }

    private func dockOrbIDs() -> [String] { scene.order.filter { scene.dock.items[$0]?.role == .orb } }
    private func columnIDs() -> [String] { scene.columns.map { $0.conversation.id } }
    /// Where the orb is now, as the product poses it (flight, Peek header or Dock slot; Sol's OrbInputVerification
    /// aims the same way). The r3 runs aimed at the Dock item's glass frame and missed D by 56 pt.
    private func dockOrbPoint(_ id: String) -> CGPoint? {
        guard scene.dock.items[id]?.role == .orb, let r = scene.orbPose(id) else { return nil }
        let p = CGPoint(x: r.midX, y: r.midY)
        aim(id, p, ["pose": rectList(r), "glass": rectList(scene.dock.items[id]?.glass.frame ?? .zero)])
        return p
    }
    /// The header planet a person sees and clicks: its planet button. The r3 runs aimed at draggableOrbRect (the orb
    /// glass view's frame, converted as if it were in island coordinates), and both brief-header clicks hit nothing.
    private func headerOrbPoint(_ id: String) -> CGPoint? {
        guard let i = scene.columns.first(where: { $0.conversation.id == id })?.island, !i.isHiddenOrHasHiddenAncestor else { return nil }
        let b = scene.dock.view.convert(i.planetButton.bounds, from: i.planetButton)
        let p = CGPoint(x: b.midX, y: b.midY)
        aim(id, p, ["button": rectList(b), "draggable": rectList(scene.dock.view.convert(i.draggableOrbRect, from: i)), "canDragOrb": i.canDragOrb])
        return p
    }
    private func rectList(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    /// Diagnostics: what the product's own orb hit test and AppKit's hit test find at the point about to be clicked.
    private func aim(_ id: String, _ p: CGPoint, _ extra: [String: Any]) {
        let w = window.window, q = toWindow(p)
        let hit = w.contentView.flatMap { $0.hitTest(q) }.map { String(describing: type(of: $0)) } ?? "nil"
        var e = extra; e["id"] = id; e["target"] = scene.orbInputTarget(at: p) ?? "nil"; e["hitView"] = hit; e["at"] = [Double(p.x), Double(p.y)]
        log("orb-switch aim", e)
    }
    /// A left click with modifier keys held from mouse-down to mouse-up (the gesture policy reads them at mouse-down).
    private func modifiedClick(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) async {
        hover(p); pointer = p; markPointer()
        postMouse(.leftMouseDown, at: p, flags: flags); await sleep(0.06)
        if !flags.isEmpty {
            log("orb-switch pressed", ["flags": Int(flags.rawValue), "orbPressed": scene.orbInput.isPressed,
                                       "menuOpen": scene.orbMenu.state.isOpen, "dragging": scene.isDragging])
        }
        postMouse(.leftMouseUp, at: p, pressure: 0, flags: flags); await sleep(0.05)
    }
    /// INPUT_ORB_CG=1: a modified click is built as a CGEvent with its flags and handed to AppKit through
    /// NSEvent(cgEvent:), as `wheel` does, instead of the NSEvent factory (the r3 run on 11-09: Option and Control
    /// clicks from the factory changed nothing, while the same clicks without modifiers worked). Never posted to the
    /// system: the real pointer and the user's input stay untouched.
    private func postMouse(_ type: NSEvent.EventType, at p: CGPoint, pressure: Float = 1, flags: NSEvent.ModifierFlags) {
        guard ProcessInfo.processInfo.environment["INPUT_ORB_CG"] == "1", !flags.isEmpty else { post(type, at: p, pressure: pressure, flags: flags); return }
        let kinds: [NSEvent.EventType: (CGEventType, CGMouseButton)] = [
            .leftMouseDown: (.leftMouseDown, .left), .leftMouseUp: (.leftMouseUp, .left),
            .rightMouseDown: (.rightMouseDown, .right), .rightMouseUp: (.rightMouseUp, .right)]
        guard let kind = kinds[type] else { post(type, at: p, pressure: pressure, flags: flags); return }
        let (cgType, button) = kind
        let w = (pointerWindow ?? window).window, q = toWindow(p)
        let screen = w.convertPoint(toScreen: q), top = NSScreen.screens.first?.frame.maxY ?? 0
        guard let e = CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: CGPoint(x: screen.x, y: top - screen.y), mouseButton: button) else {
            log("orb-switch post-failed", ["type": Int(type.rawValue), "flags": Int(flags.rawValue), "route": "cg"]); return
        }
        var f: CGEventFlags = []
        if flags.contains(.option) { f.insert(.maskAlternate) }
        if flags.contains(.control) { f.insert(.maskControl) }
        if flags.contains(.command) { f.insert(.maskCommand) }
        if flags.contains(.shift) { f.insert(.maskShift) }
        e.flags = f
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
        e.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(w.windowNumber))
        setEventWindowLocation(e, CGPoint(x: q.x, y: w.frame.height - q.y))
        guard let ns = NSEvent(cgEvent: e) else { log("orb-switch post-failed", ["type": Int(type.rawValue), "route": "nsevent"]); return }
        NSApp.postEvent(ns, atStart: false)
    }
    private func rightClick(_ p: CGPoint, hold: Double = 0.06) async {
        hover(p); pointer = p; markPointer()
        post(.rightMouseDown, at: p); await sleep(hold)
        post(.rightMouseUp, at: p, pressure: 0); await sleep(0.05)
    }
    private func arrow(_ code: UInt16) {
        let chars: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
        key(code, chars[code].flatMap { UnicodeScalar($0) }.map { String(Character($0)) } ?? "", [.function, .numericPad])
    }
    private func returnKey() { key(36, "\r") }
    /// The centre of a main-menu row, in scene points (OrbContextMenu.rowRect: separators after Peek, Customize and Fork).
    private func menuRowPoint(_ action: OrbMenuAction) -> CGPoint {
        let m = scene.orbMenu.main.frame, row = action.rawValue
        let separators = [3, 5, 7].filter { row >= $0 }.count
        let local = CGPoint(x: 5 + 113, y: 38 + CGFloat(row * 24 + separators * 9) + 12)
        return scene.dock.view.convert(CGPoint(x: m.minX + local.x, y: m.minY + local.y), from: scene.orbMenu)
    }
    /// The rows Down reaches from nothing, once around the menu: what a person can pick with the keyboard. Read from
    /// the menu's own selection rather than from OrbMenuAction, so it holds however the menu decides a row is disabled.
    private func keyboardRows() async -> [Int] {
        var seen: [Int] = []
        for _ in 0...OrbMenuAction.allCases.count {
            arrow(125); await sleep(0.08)
            guard let s = scene.orbMenu.state.selected, !seen.contains(s) else { break }
            seen.append(s)
        }
        return seen
    }
    private func settleOrbs() async {
        await sleep(0.3)
        for _ in 0..<40 where scene.isMoving { await sleep(0.05) }
        await sleep(0.4)
    }

    private func orbSwitch() async {
        guard app.mock != nil else { log("orb-switch abort", ["reason": "no mock: this scene never runs on a live Core"]); return }
        requireKey("orb-switch")
        // Diagnostics (11-09 r3 run): every mouse button event the app dispatches during the scene, with its flags.
        let probe = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                self.log("orb-switch event", ["type": Int(e.type.rawValue), "flags": Int(flags.rawValue), "option": flags.contains(.option),
                                              "control": flags.contains(.control), "ours": e.window === self.window.window,
                                              "at": [Double(e.locationInWindow.x), Double(e.locationInWindow.y)]])
            }
            return e
        }
        defer { if let probe { NSEvent.removeMonitor(probe) } }
        if scene.isFocused { scene.leaveFocused(reason: "input-run"); await sleep(1.6) }
        await settleOrbs()
        log("orb-switch begin", ["columns": columnIDs(), "dockOrbs": dockOrbIDs(), "current": scene.current, "state": state()])

        // 1. Option-click a Dock orb: it takes the full column, the full one goes to the clicked orb's Dock slot.
        //    1a on an orb at rest, 1b on one a live Tide presents (M11.34 Q2: Option-click or the orb menu goes to it;
        //    a plain click there toggles the pin).
        let tideOrb = dockOrbIDs().first { scene.dock.tideOwns($0) }
        if let id = dockOrbIDs().first(where: { $0 != tideOrb }), let p = dockOrbPoint(id) {
            let full = scene.current, slot = scene.order.firstIndex(of: id)
            await modifiedClick(p, .option); await settleOrbs()
            orbCheck("option-dock", scene.current == id && scene.order.firstIndex(of: full) == slot && scene.dock.items[full]?.role == .orb,
                     ["id": id, "full": full, "slot": slot ?? -1])
        } else { orbCheck("option-dock", false, ["reason": "no Dock orb at rest"]) }
        if let id = tideOrb, scene.dock.tideOwns(id), let p = dockOrbPoint(id) {
            let full = scene.current, slot = scene.order.firstIndex(of: id)
            await modifiedClick(p, .option); await settleOrbs()
            orbCheck("option-dock-tide", scene.current == id && scene.order.firstIndex(of: full) == slot,
                     ["id": id, "full": full, "slot": slot ?? -1])
        } else { log("orb-switch skip", ["what": "option-dock-tide", "reason": "no live Tide on a Dock orb"]) }

        // 2. Option-click a brief column's planet: it becomes full, the column order stays.
        if let id = columnIDs().first(where: { $0 != scene.current }), let p = headerOrbPoint(id) {
            let before = columnIDs()
            await modifiedClick(p, .option); await settleOrbs()
            orbCheck("option-brief", scene.current == id && columnIDs() == before, ["id": id, "before": before, "after": columnIDs()])
        } else { orbCheck("option-brief", false, ["reason": "no brief column"]) }

        // 3. Option-click the full planet: a bounce, no change. 4. Option-Command on a Dock orb: nothing at all.
        let full = scene.current, order = scene.order
        if let p = headerOrbPoint(full) {
            await modifiedClick(p, .option); await settleOrbs()
            orbCheck("option-full", scene.current == full && scene.order == order, ["id": full])
        }
        if let id = dockOrbIDs().first, let p = dockOrbPoint(id) {
            await modifiedClick(p, [.option, .command]); await settleOrbs()
            orbCheck("option-command-dock", scene.current == full && scene.order == order && !scene.orbMenu.state.isOpen, ["id": id])
        }

        // 5. Right-click a Dock orb: the menu opens; the keyboard skips New Sidechat and Remove (M11.41 / M11.37); Esc
        //    closes the menu. Then the Fork row on an orb with history (M11.36b, mock only): a whole-thread fork joins the
        //    Dock as a new orb, the columns and the full one stay, and its history is the source's from the start.
        if let id = dockOrbIDs().first, let p = dockOrbPoint(id) {
            await rightClick(p); await sleep(0.25)
            let open = scene.orbMenu.state.isOpen, menu = orbMenuState()
            orbCheck("right-click-opens", open, ["id": id, "menu": menu])
            let reached = await keyboardRows()
            let skipped = OrbMenuAction.allCases.filter { !reached.contains($0.rawValue) }.map(\.title)
            orbCheck("disabled-rows", open && Set(skipped) == ["New Sidechat", "Remove from Organic"], ["reached": reached, "skipped": skipped])
            escape(); await sleep(0.3)
            orbCheck("esc-closes", !scene.orbMenu.state.isOpen)
        }
        // A conversation whose only turn is still running (mock D) has no completed history: Fork adds nothing and
        // says so next to the orb. Skipped when no Dock orb is in that state.
        if let id = dockOrbIDs().first(where: { scene.conversation($0).map { !$0.items.isEmpty && $0.completedForkItems.isEmpty } == true }),
           let p = dockOrbPoint(id) {
            let order = scene.order, columns = columnIDs(), full = scene.current
            await rightClick(p); await sleep(0.25)
            let open = scene.orbMenu.state.isOpen
            if open { await modifiedClick(menuRowPoint(.fork), []) }
            var toast = ""
            for _ in 0..<40 {
                await sleep(0.05)
                if scene.orbToast.superview != nil { toast = scene.orbToast.label.stringValue; break }
            }
            await sleep(0.5)
            orbCheck("fork-no-history-toast", open && scene.order == order && columnIDs() == columns && scene.current == full
                     && !scene.orbMenu.state.isOpen && toast.contains("No completed history"), ["id": id, "toast": toast])
            // Let the toast expire so it cannot sit over the next orb's click.
            for _ in 0..<160 { if scene.orbToast.superview == nil { break }; await sleep(0.05) }
        }
        // The fork's history is the source's completed history, captured right before the click (a turn may finish
        // while the menu is open, so the snapshot after the fork is accepted too), and a prefix of the source's rows.
        if let id = dockOrbIDs().first(where: { scene.conversation($0).map { !$0.completedForkItems.isEmpty } == true }),
           let p = dockOrbPoint(id), let source = scene.conversation(id) {
            let order = scene.order, columns = columnIDs(), full = scene.current
            await rightClick(p); await sleep(0.25)
            let open = scene.orbMenu.state.isOpen
            let before = source.completedForkItems.map(\.text)
            if open { await modifiedClick(menuRowPoint(.fork), []) }
            var fork: String?
            for _ in 0..<80 {
                await sleep(0.05)
                fork = scene.order.first { !order.contains($0) }
                if fork != nil { break }
            }
            await settleOrbs()
            let f = fork.flatMap { scene.conversation($0) }
            let after = source.completedForkItems.map(\.text)
            let sourceTexts = source.items.map(\.text), forkTexts = f?.items.map(\.text) ?? []
            let prefix = !forkTexts.isEmpty && forkTexts.count <= sourceTexts.count && Array(sourceTexts.prefix(forkTexts.count)) == forkTexts
            orbCheck("fork-adds-dock-orb", open && fork != nil && fork.map { scene.dock.items[$0]?.role == .orb } == true
                     && columnIDs() == columns && scene.current == full && !scene.orbMenu.state.isOpen,
                     ["id": id, "fork": fork ?? "nil", "title": f?.title ?? "", "columns": columnIDs(), "full": scene.current,
                      "toast": scene.orbToast.superview == nil ? "" : scene.orbToast.label.stringValue])
            orbCheck("fork-whole-history", prefix && (forkTexts == before || forkTexts == after),
                     ["id": id, "sourceItems": sourceTexts.count, "completed": before.count, "forkItems": forkTexts.count])
        } else { orbCheck("fork-adds-dock-orb", false, ["reason": "no Dock orb with completed history"]) }

        // 6. Keyboard: Down selects Swap, Right opens its submenu, Return swaps into the first free column.
        if let id = dockOrbIDs().first, let p = dockOrbPoint(id) {
            await rightClick(p); await sleep(0.25)
            arrow(125); await sleep(0.1); arrow(124); await sleep(0.2)
            let menu = orbMenuState(), cols = scene.orbMenu.state.columns
            let target = scene.orbMenu.state.selectedColumn.flatMap { cols.indices.contains($0) ? cols[$0].id : nil }
            returnKey(); await sleep(0.35); await settleOrbs()
            orbCheck("keyboard-swap-into-column", target != nil && columnIDs().contains(id) && target.map { !columnIDs().contains($0) } == true
                     && !scene.orbMenu.state.isOpen, ["id": id, "target": target ?? "nil", "menu": menu, "columns": columnIDs()])
        }

        // 7. Control-click a brief planet opens the same menu; Down three times reaches Peek; Return peeks.
        if let id = columnIDs().first(where: { $0 != scene.current }), let p = headerOrbPoint(id) {
            await modifiedClick(p, .control); await sleep(0.25)
            let open = scene.orbMenu.state.isOpen
            for _ in 0..<3 { arrow(125); await sleep(0.08) }
            let selected = scene.orbMenu.state.selected
            returnKey(); await sleep(0.8)
            orbCheck("control-click-peek", open && selected == OrbMenuAction.peek.rawValue && scene.peeking == id,
                     ["id": id, "selected": selected ?? -1, "peeking": scene.peeking ?? "nil"])
            scene.dismissPeek(); await sleep(0.6)
        }

        // 8. Right button held onto Rename…, released after 0.4 s: Customize Chat opens (mock), Esc leaves it unchanged.
        if let id = dockOrbIDs().first, let p = dockOrbPoint(id), let c = scene.conversation(id) {
            let title = c.title
            hover(p); pointer = p; markPointer(); post(.rightMouseDown, at: p); await sleep(0.12)
            let q = scene.orbMenu.state.isOpen ? menuRowPoint(.rename) : p
            for k in 1...24 {
                let f = CGFloat(k) / 24; pointer = CGPoint(x: p.x + (q.x - p.x) * f, y: p.y + (q.y - p.y) * f); markPointer()
                post(.rightMouseDragged, at: pointer); await sleep(1 / 120)
            }
            await sleep(0.2); post(.rightMouseUp, at: pointer, pressure: 0); await sleep(0.8)
            let sheet = scene.customizeSheet.isShowing
            orbCheck("right-hold-rename-opens-customize", sheet, ["id": id])
            escape(); await sleep(0.6)
            if scene.customizeSheet.isShowing { scene.customizeSheet.dismiss(); await sleep(0.6) }
            orbCheck("rename-cancelled-unchanged", c.title == title && !scene.customizeSheet.isShowing, ["id": id])
        }

        // 9. Archive from the menu (Up from nothing selects the last enabled row), then Undo on the toast. Mock only.
        if let id = dockOrbIDs().last, let p = dockOrbPoint(id), let c = scene.conversation(id) {
            let slot = scene.order.firstIndex(of: id)
            await rightClick(p); await sleep(0.25)
            arrow(126); await sleep(0.1)
            let selected = scene.orbMenu.state.selected
            returnKey(); await sleep(0.4); await settleOrbs()
            orbCheck("archive", selected == OrbMenuAction.archive.rawValue && c.archived && !scene.order.contains(id) && scene.orbToast.superview != nil,
                     ["id": id, "selected": selected ?? -1])
            let b = scene.orbToast.undoButton
            if b.superview != nil, !b.isHidden {
                let r = scene.dock.view.convert(b.bounds, from: b)
                await modifiedClick(CGPoint(x: r.midX, y: r.midY), []); await sleep(0.4); await settleOrbs()
            }
            orbCheck("archive-undo", !c.archived && scene.order.firstIndex(of: id) == slot, ["id": id, "slot": slot ?? -1, "now": scene.order.firstIndex(of: id) ?? -1])
        }

        // 10. A click outside an open menu closes it and does not reach what is under it.
        if let id = dockOrbIDs().first, let p = dockOrbPoint(id) {
            let current = scene.current, order = scene.order
            await rightClick(p); await sleep(0.25)
            let open = scene.orbMenu.state.isOpen
            let outside = CGPoint(x: scene.size.width * 0.5, y: scene.size.height * 0.45)
            await modifiedClick(outside, []); await sleep(0.4)
            orbCheck("outside-click-closes-no-passthrough", open && !scene.orbMenu.state.isOpen && scene.current == current && scene.order == order)
        }

        // 11. Open in Focused from the keyboard (Down twice), then back to Auto.
        if let id = dockOrbIDs().first, let p = dockOrbPoint(id) {
            await rightClick(p); await sleep(0.25)
            arrow(125); await sleep(0.08); arrow(125); await sleep(0.08)
            returnKey(); await sleep(0.4); await settleOrbs()
            orbCheck("keyboard-open-in-focused", scene.isFocused && scene.current == id, ["id": id])
            if scene.isFocused { scene.leaveFocused(reason: "input-run"); await sleep(1.6) }
        }
        // Leftovers only with the pointer off the Dock (hover lifts the node under it) and once the scene says it has
        // stopped moving: a node still springing home is not left over.
        hover(nil); await settleOrbs()

        // A live Tide (a mock notice, every ~20 s) lays the Dock out itself: its owner widens and its neighbours make room,
        // so their frames are not their spring slots (M11.36b real-window run b1, 11-10). Those positions belong to M11.34's
        // own gates; here they are logged apart, and every other leftover still fails the scene.
        let tides = scene.dock.items.keys.filter { scene.dock.tideHasNotice($0) }.sorted()
        var left = leftovers(expectedWindows: 1), tideLaid: [String] = []
        if !tides.isEmpty { tideLaid = left.filter { $0.hasPrefix("dock node ") && $0.contains(" stands at ") }; left.removeAll { tideLaid.contains($0) } }
        let failed = orbChecks.filter { ($0["pass"] as? Bool) != true }.compactMap { $0["name"] as? String }
        log("orb-switch summary", ["checks": orbChecks.count, "failed": failed, "leftovers": left, "tides": tides, "tideLaid": tideLaid, "state": state()])
    }

    // MARK: M11.39 LL hover (sun-hover, Claude for lane B 11-10, decision #136)
    //
    // The LL hover through the product's own entries. Pointer moves are posted and also handed to SunHoverNode the way
    // its tracking area hands them on (posted moves never reach tracking areas; Peek above does the same through
    // RootView's path). Clicks and keys are posted events, so the window's hit test, the node's mouseDown and the
    // controller's local monitor all run. Mock only: Profile, Sign Out and the attention swap act on conversations.
    // SUN_EXPECT lists the satellites the build exposes (default 2,3,4,5: B step one hides New Chat and Add).
    private var sunChecks: [[String: Any]] = []

    private func sunCheck(_ name: String, _ pass: Bool, _ extra: [String: Any] = [:]) {
        var e = extra; e["name"] = name; e["pass"] = pass
        sunChecks.append(e)
        log("sun-hover check", e.merging(["sun": scene.sunHoverReadout]) { a, _ in a })
    }
    private var sunReadout: [String: Any] { scene.sunHoverReadout }
    private func sunPhase() -> String { sunReadout["phase"] as? String ?? "?" }
    private func sunSatellites() -> [Int] { sunReadout["satellites"] as? [Int] ?? [] }
    private func sunLabels() -> [Int] { sunReadout["labels"] as? [Int] ?? [] }
    private func sunPanel() -> String { sunReadout["panel"] as? String ?? "?" }
    private func sunIdleResources() -> Bool {
        ["timers", "monitors", "displayLinks"].allSatisfy { (sunReadout[$0] as? Int) == 0 }
    }
    private var sunExpected: [Int] {
        let raw = ProcessInfo.processInfo.environment["SUN_EXPECT"] ?? "2,3,4,5"
        return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
    /// The geometry the controller builds from the LL the Dock measures (AutoSceneSunHover.geometry), in overlay points.
    private func sunGeometry() -> SunHoverGeometry? {
        guard let m = scene.dock.meMeasurement else { return nil }
        return SunHoverGeometry(llCenter: m.center, dockBaseline: m.center.y, bounds: scene.overlayPlane.bounds, backingScale: scene.scale)
    }
    private func sunPoint(_ overlay: CGPoint) -> CGPoint { scene.dock.view.convert(overlay, from: scene.overlayPlane) }
    private func llPoint() -> CGPoint? { sunGeometry().map { sunPoint($0.llCenter) } }
    private func satellitePoint(_ raw: Int) -> CGPoint? {
        guard let g = sunGeometry(), let key = SunHoverSatellite(rawValue: raw) else { return nil }
        return sunPoint(g.satelliteCenter(key))
    }
    /// The badge as the board places it: LL centre + (17, -17) (SunHover02 showPanel('attention', SUN_X + 17, SUN_Y - 17)).
    private func badgePoint() -> CGPoint? { sunGeometry().map { sunPoint(CGPoint(x: $0.llCenter.x + 17, y: $0.llCenter.y - 17)) } }
    private func sunAway() -> CGPoint { CGPoint(x: scene.size.width * 0.5, y: scene.size.height * 0.4) }

    /// One pointer step: posted (RootView and anything else on the event path), the scene's hover path, and the node's
    /// tracking callback with the window point converted as its mouseMoved converts it.
    private func sunStep(_ p: CGPoint) {
        pointer = p; markPointer()
        post(.mouseMoved, at: p, pressure: 0)
        hover(p)
        if let node = scene.sunHover?.node { node.onPointer?(node.convert(toWindow(p), from: nil)) }
    }
    /// `each` runs after every step (sampling what moves while the pointer travels).
    private func sunMove(to q: CGPoint, over seconds: Double, each: (() -> Void)? = nil) async {
        let a = pointer, steps = max(1, Int(seconds * 120))
        for k in 1...steps {
            let f = CGFloat(k) / CGFloat(steps), e = f * f * (3 - 2 * f)
            sunStep(CGPoint(x: a.x + (q.x - a.x) * e, y: a.y + (q.y - a.y) * e))
            each?()
            await sleep(1 / 120)
        }
    }
    /// Shown satellites' centre y, the badge's and the LL's frames, in the Dock view's points (#160: none of them may move
    /// under the pointer while the hover prepares or shows).
    /// How far the resting badge centre lies inside the badge's actual hit region (negative: outside; no badge: -1).
    private func sunRestMargin(_ rest: CGRect, _ now: CGRect?) -> CGFloat {
        guard let now else { return -1 }
        let r = SunHoverNode.badgeHitRect(now), c = CGPoint(x: rest.midX, y: rest.midY)
        return min(c.x - r.minX, r.maxX - c.x, c.y - r.minY, r.maxY - c.y)
    }
    private func sunPlaces() -> (satellites: [Int: CGFloat], badge: CGRect?, ll: CGRect?) {
        var out: [Int: CGFloat] = [:]
        if let node = scene.sunHover?.node {
            for (key, r) in node.satelliteFrames { out[key.rawValue] = scene.dock.view.convert(r, from: node).midY }
        }
        return (out, scene.dock.sunHoverBadgeRect, scene.dock.meMeasurement?.frame)
    }
    /// Rest on a point while a person's hand trembles by a fraction of a point (moves keep arriving).
    private func sunRest(_ seconds: Double) async {
        let p = pointer, began = CACurrentMediaTime()
        var k = 0
        while CACurrentMediaTime() - began < seconds {
            k += 1; sunStep(CGPoint(x: p.x + (k % 2 == 0 ? 0.3 : -0.3), y: p.y)); await sleep(1 / 30)
        }
        sunStep(p)
    }
    private func sunClick(_ p: CGPoint) async {
        await sunMove(to: p, over: 0.08)
        await press(p); await sleep(0.05); release(); await sleep(0.05)
    }
    /// Visible panel rows with their accessibility label and centre, in scene points.
    private func sunRows() -> [(label: String, at: CGPoint)] {
        guard let panel = scene.sunHover?.node.panel, !panel.isHidden else { return [] }
        var out: [(label: String, at: CGPoint)] = []
        func walk(_ v: NSView) {
            for s in v.subviews {
                if let r = s as? SunHoverPanelView.Row, !r.isHiddenOrHasHiddenAncestor, r.alphaValue > 0.5 {
                    let b = scene.dock.view.convert(r.bounds, from: r)
                    out.append((r.accessibilityLabel() ?? "", CGPoint(x: b.midX, y: b.midY)))
                }
                walk(s)
            }
        }
        walk(panel)
        return out
    }
    /// Opens the hover from far away: the pointer comes in to the LL and rests; true once the exposed satellites show.
    private func sunOpen() async -> Bool {
        guard let ll = llPoint() else { return false }
        if hypot(pointer.x - ll.x, pointer.y - ll.y) < 30 { await sunMove(to: sunAway(), over: 0.15); await sunRest(0.5) }
        await sunMove(to: ll, over: 0.2); await sunRest(0.6)
        return Set(sunSatellites()) == Set(sunExpected)
    }
    private func sunLeave() async {
        await sunMove(to: sunAway(), over: 0.12); await sunRest(1.0)
    }

    private func sunHoverScene() async {
        guard app.mock != nil else { log("sun-hover abort", ["reason": "no mock: this scene never runs on a live Core"]); return }
        requireKey("sun-hover")
        if scene.isFocused { scene.leaveFocused(reason: "input-run"); await sleep(1.6) }
        await settleOrbs()
        guard scene.sunHover != nil, let ll = llPoint() else { log("sun-hover abort", ["reason": "no SunHover controller or no LL"]); return }
        let expected = sunExpected
        // The controller reads the real mouse location (retire suppression, geometry changes, the native shield).
        // This driver posts events and leaves the real pointer alone, so it supplies the point it is driving.
        scene.sunHover?.pointerOverride = { [weak self] in
            guard let self, let node = self.scene.sunHover?.node else { return nil }
            return node.convert(self.toWindow(self.pointer), from: nil)
        }
        pointer = sunAway(); sunStep(pointer); await sunRest(0.5)
        log("sun-hover begin", ["ll": [Double(ll.x), Double(ll.y)], "expected": expected, "columns": columnIDs(), "current": scene.current, "sun": sunReadout])
        // 0. At rest, before any hover: the corner badge sits on the LL (Sol r4's offscreen idle capture drew the LL's
        //    front decoration, glow and badge, at the window's origin; the recording shows what a real window does).
        if let badge = scene.dock.sunHoverBadgeRect, let frame = scene.dock.meMeasurement?.frame {
            sunCheck("idle-badge-on-ll", abs(badge.maxX - frame.maxX - 3) < 1 && abs(badge.minY - frame.minY + 3) < 1,
                     ["badge": [Double(badge.minX), Double(badge.minY), Double(badge.width), Double(badge.height)],
                      "ll": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]])
        }

        // 1. The first entry after the window was set up (attach retires the controller with the pointer outside;
        //    r1 review item 1: the suppression it sets was never cleared). Timeline of the satellites every 50 ms.
        await sunMove(to: ll, over: 0.2)
        var timeline: [[Any]] = [], firstAll: Double?
        let entered = CACurrentMediaTime()
        while CACurrentMediaTime() - entered < 1.2 {
            let t = CACurrentMediaTime() - entered, s = sunSatellites()
            timeline.append([Double(Int(t * 1000)) / 1000, s, sunPhase()])
            if firstAll == nil && Set(s) == Set(expected) { firstAll = t }
            sunStep(CGPoint(x: ll.x + (timeline.count % 2 == 0 ? 0.3 : -0.3), y: ll.y)); await sleep(0.05)
        }
        sunCheck("first-entry-opens", firstAll != nil && firstAll! < 0.8, ["allAt": firstAll ?? -1, "timeline": timeline])

        // 2. Along the arc to each exposed satellite: exactly that one label, never two. On the way (#160) no satellite's
        //    centre y, nor the LL's centre, may move: the pointer leaves the Dock and the Dock must not fall back. The badge
        //    follows the opened 42 pt LL by 3 pt (#188), so it is not frozen; instead its resting centre must stay inside
        //    the badge's actual hit region, at least 2 pt from every edge, for the whole hover.
        var labelsSeen: [[Int]] = [], twoAtOnce = false
        let rest = sunPlaces()
        var ySpread: [Int: (lo: CGFloat, hi: CGFloat)] = [:], badgeMargin = CGFloat.infinity, llMoved: CGFloat = 0, samples = 0
        let sample = { [self] in
            let now = sunPlaces(); samples += 1
            for (k, y) in now.satellites { let s = ySpread[k] ?? (y, y); ySpread[k] = (min(s.lo, y), max(s.hi, y)) }
            if let a = rest.badge { badgeMargin = min(badgeMargin, sunRestMargin(a, now.badge)) }
            if let a = rest.ll, let b = now.ll { llMoved = max(llMoved, hypot(b.midX - a.midX, b.midY - a.midY)) }
        }
        for raw in expected {
            guard let p = satellitePoint(raw) else { continue }
            await sunMove(to: p, over: 0.25, each: sample)
            let began = CACurrentMediaTime()
            while CACurrentMediaTime() - began < 0.45 { if sunLabels().count > 1 { twoAtOnce = true }; sunStep(p); sample(); await sleep(1 / 30) }
            labelsSeen.append(sunLabels())
        }
        sunCheck("one-label-per-satellite", !twoAtOnce && labelsSeen == expected.map { [$0] }, ["seen": labelsSeen, "twoAtOnce": twoAtOnce])
        let spread = ySpread.mapValues { Double($0.hi - $0.lo) }
        sunCheck("satellites-hold-y-on-the-way", samples > 0 && Set(expected).isSubset(of: Set(ySpread.keys)) && spread.values.allSatisfy { $0 < 0.5 }
                    && badgeMargin >= 2 && llMoved < 0.5,
                 ["ySpread": Dictionary(uniqueKeysWithValues: spread.map { (String($0.key), $0.value) }), "badgeMargin": Double(badgeMargin.isFinite ? badgeMargin : -1),
                  "llMoved": Double(llMoved), "samples": samples,
                  "restY": Dictionary(uniqueKeysWithValues: rest.satellites.map { (String($0.key), Double($0.value)) })])

        // 3. Leaving: the 260 ms grace keeps it open, then everything folds and the controller keeps nothing running.
        await sunMove(to: sunAway(), over: 0.06)
        let graceOpen = !sunSatellites().isEmpty
        await sunRest(1.2)
        sunCheck("leave-grace-then-fold", graceOpen && sunSatellites().isEmpty && sunLabels().isEmpty && sunPhase() == "idle",
                 ["openRightAfterLeaving": graceOpen])
        sunCheck("idle-holds-nothing", sunIdleResources() && sunPanel() == "none")

        // 4. Badge dwell opens attention; rows match the badge count (conversations, not events), at most six visible.
        if let b = badgePoint() {
            await sunMove(to: b, over: 0.2); await sunRest(0.45)
            // #160: the Dock no longer rises under a preparing or open hover; the badge only follows the opened LL by 3 pt
            // (#188), so a pointer aimed at its resting point opens attention (counted since the #160 patch round), with
            // the resting centre at least 2 pt inside the badge's hit region.
            let margin = rest.badge.map { sunRestMargin($0, scene.dock.sunHoverBadgeRect) } ?? -1
            sunCheck("badge-at-rest-point-opens", sunPanel() == "attention" && margin >= 2,
                     ["point": [Double(b.x), Double(b.y)], "margin": Double(margin),
                      "badge": (scene.dock.sunHoverBadgeRect).map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } ?? []])
            // Then as a hand does: follow the badge to where it is now.
            if sunPanel() != "attention", let r = scene.dock.sunHoverBadgeRect {
                await sunMove(to: sunPoint(CGPoint(x: r.midX, y: r.midY)), over: 0.12); await sunRest(0.45)
            }
            let ids = sunReadout["attentionIDs"] as? [String] ?? [], count = sunReadout["attentionCount"] as? Int ?? -1
            let rows = sunRows()
            sunCheck("badge-opens-attention", sunPanel() == "attention" && count == ids.count && count > 0 && rows.count == min(6, count),
                     ["count": count, "ids": ids, "rows": rows.map { $0.label }])
            // 5. A row swaps its conversation in and closes the panel.
            if sunPanel() == "attention", let first = ids.first, let row = rows.first {
                await sunClick(row.at); await sleep(0.6); await settleOrbs()
                sunCheck("attention-row-swaps-in", scene.current == first && sunPanel() == "none", ["id": first, "row": row.label, "current": scene.current])
            } else { sunCheck("attention-row-swaps-in", false, ["reason": "no attention row"]) }
        } else { sunCheck("badge-opens-attention", false, ["reason": "no LL"]) }
        await sunLeave()

        // 6. A click on the LL without moving opens account; resting there keeps it open (r1 review item 1, second half).
        if await sunOpen(), let p = llPoint() {
            await press(p); await sleep(0.05); release(); await sleep(0.4)
            let opened = sunPanel() == "account"
            await sunRest(1.2)
            sunCheck("ll-click-account-stays", opened && sunPanel() == "account", ["openedAtFirst": opened])
            // 7. Esc closes the top layer only: panel, then satellites; on the LL it stays shut until the pointer leaves.
            escape(); await sleep(0.35)
            let afterOne = (sunPanel(), sunSatellites())
            escape(); await sunRest(0.9)
            let afterTwo = (sunPanel(), sunSatellites())
            await sunMove(to: sunAway(), over: 0.12); await sunRest(0.5)
            let reopened = await sunOpen()
            sunCheck("esc-layers-and-suppression", afterOne.0 == "none" && Set(afterOne.1) == Set(expected) && afterTwo.0 == "none"
                     && afterTwo.1.isEmpty && reopened, ["afterOne": [afterOne.0, afterOne.1] as [Any], "afterTwo": [afterTwo.0, afterTwo.1] as [Any], "reopened": reopened])
        } else { sunCheck("ll-click-account-stays", false, ["reason": "hover did not open"]) }
        await sunLeave()

        // 8. Usage satellite opens Usage; a click outside closes it and does not reach what is under it.
        if expected.contains(SunHoverSatellite.usage.rawValue), await sunOpen(), let u = satellitePoint(SunHoverSatellite.usage.rawValue) {
            await sunClick(u); await sleep(0.4)
            let opened = sunPanel() == "usage"
            let current = scene.current, order = scene.order, columns = columnIDs()
            await press(sunAway()); await sleep(0.05); release(); await sleep(0.5)
            sunCheck("usage-panel-and-outside-click", opened && sunPanel() == "none" && scene.current == current && scene.order == order
                     && columnIDs() == columns && scene.peeking == nil, ["opened": opened])
        }
        await sunLeave()

        // 9. Settings satellite opens account.
        if expected.contains(SunHoverSatellite.settings.rawValue), await sunOpen(), let s = satellitePoint(SunHoverSatellite.settings.rawValue) {
            await sunClick(s); await sleep(0.4)
            sunCheck("settings-satellite-account", sunPanel() == "account")
            escape(); await sleep(0.3); escape(); await sleep(0.3)
        }
        await sunLeave()

        // 10. Pressing the LL and moving past the drag threshold folds the satellites (FOLD, not a cut) and opens no panel.
        if await sunOpen(), let p = llPoint() {
            hover(p); await press(p); await carry(to: CGPoint(x: p.x, y: p.y - 10), over: 0.1)
            var trace: [[Any]] = []
            let began = CACurrentMediaTime()
            while CACurrentMediaTime() - began < 0.5 { trace.append([Double(Int((CACurrentMediaTime() - began) * 1000)) / 1000, sunSatellites()]); await sleep(1 / 30) }
            await carry(to: p, over: 0.15); release(); await sleep(0.2)
            await sunMove(to: sunAway(), over: 0.1); await settleOrbs(); await sunRest(0.6)
            sunCheck("ll-drag-folds", sunSatellites().isEmpty && sunPanel() == "none" && !scene.isFocused && !scene.isDragging, ["trace": trace])
        }

        // 11. Search and Sidebar go to Normie through the existing mode switch; Search then holds a text field's focus.
        for (name, raw) in [("search", SunHoverSatellite.search.rawValue), ("sidebar", SunHoverSatellite.sidebar.rawValue)] where expected.contains(raw) {
            guard await sunOpen(), let p = satellitePoint(raw) else { sunCheck("\(name)-goes-normie", false, ["reason": "hover did not open"]); continue }
            await sunClick(p); await sleep(3.0)
            let responder = NSApp.keyWindow?.firstResponder
            let typing = responder is NSTextView || responder is NSTextField
            let normie = window.shell.mode == .normie
            sunCheck("\(name)-goes-normie", normie && (name != "search" || typing),
                     ["mode": window.shell.mode.rawValue, "responder": responder.map { String(describing: type(of: $0)) } ?? "nil"])
            if window.shell.mode == .normie { modeKey(); await sleep(3.0) }
            await settleOrbs()
            hover(nil)
        }

        // 12. Losing key while open: everything folds and the controller holds no timer, monitor or display link.
        if await sunOpen() {
            otherApp(); await sleep(0.8)
            let folded = sunSatellites().isEmpty && sunPanel() == "none" && sunIdleResources()
            activate(); await sleep(0.8)
            sunCheck("resign-key-cleans-up", folded)
            requireKey("sun-hover after the app switch")
        }

        // 13. In and out quickly three times, then a real rest: it still opens.
        if let p = llPoint() {
            for _ in 0..<3 { await sunMove(to: p, over: 0.08); await sunMove(to: sunAway(), over: 0.08) }
            await sunMove(to: p, over: 0.15); await sunRest(0.6)
            sunCheck("quick-passes-then-rest-opens", Set(sunSatellites()) == Set(expected))
        }

        // Leftovers with the pointer far away once the scene stops moving (InputRun.leftovers counts a visible overlay).
        await sunLeave(); hover(nil); await settleOrbs()
        sunCheck("final-idle", sunPhase() == "idle" && sunIdleResources())
        // The mock keeps sending notices: the ones deferred while the hover was open are replayed when it closes, and a
        // Tide displaces Dock orbs by design. That is not a hover leftover. Record it, dismiss it the way Escape would,
        // and judge the leftovers once it has returned.
        let tideAtEnd = "\(scene.dock.tideProbe["phase"] ?? "idle") \(scene.dock.tideProbe["owner"] ?? "")"
        let leftWithTide = leftovers(expectedWindows: 1)
        var tideWait = 0.0
        if !leftWithTide.isEmpty {
            while tideWait < 8, !leftovers(expectedWindows: 1).isEmpty {
                _ = scene.dock.dismissTide(); await sleep(0.25); tideWait += 0.25
            }
        }
        let left = leftovers(expectedWindows: 1)
        let failed = sunChecks.filter { ($0["pass"] as? Bool) != true }.compactMap { $0["name"] as? String }
        log("sun-hover summary", ["checks": sunChecks.count, "failed": failed, "leftovers": left, "tideAtEnd": tideAtEnd,
                                  "leftoversWithTide": leftWithTide, "tideWait": tideWait, "state": state(), "sun": sunReadout])
    }

    // MARK: Pointer and keys

    private func toWindow(_ p: CGPoint) -> CGPoint { (pointerWindow ?? window).scene.dock.view.convert(p, to: nil) }

    private func post(_ type: NSEvent.EventType, at p: CGPoint, pressure: Float = 1, flags: NSEvent.ModifierFlags = []) {
        eventNumber += 1
        let w = pointerWindow ?? window
        guard let e = NSEvent.mouseEvent(with: type, location: toWindow(p), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: pressure) else {
            log("post-failed", ["type": Int(type.rawValue), "flags": Int(flags.rawValue)]); return
        }
        NSApp.postEvent(e, atStart: false)
    }

    private func press(_ p: CGPoint) async {
        pointer = p; held = true; markPointer()
        post(.leftMouseDown, at: p)
        await sleep(0.02)
    }

    private func carry(by d: CGSize, over seconds: Double) async {
        await carry(to: CGPoint(x: pointer.x + d.width, y: pointer.y + d.height), over: seconds)
    }

    private func carry(to q: CGPoint, over seconds: Double) async {
        let a = pointer, steps = max(1, Int(seconds * 120))
        for k in 1...steps {
            let f = CGFloat(k) / CGFloat(steps), e = f * f * (3 - 2 * f)
            pointer = CGPoint(x: a.x + (q.x - a.x) * e, y: a.y + (q.y - a.y) * e)
            markPointer()
            post(.leftMouseDragged, at: pointer)
            await sleep(1 / 120)
        }
    }

    /// One detent of a mouse wheel, not precise and with no phase, through AppKit's queue. Positive lines read up the history.
    private func wheel(at p: CGPoint, lines: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        let w = window.window, q = toWindow(p)
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(w.windowNumber))
        setEventWindowLocation(event, CGPoint(x: q.x, y: w.frame.height - q.y))
        if let e = NSEvent(cgEvent: event) { NSApp.postEvent(e, atStart: false) }
    }

    private func hover(_ p: CGPoint?) {
        if let p { window.hover(p) } else { scene.pointer(nil) }
    }

    private func release() { held = false; post(.leftMouseUp, at: pointer, pressure: 0) }

    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: (NSApp.keyWindow ?? window.window).windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(e, atStart: false)
    }
    private func escape() { key(53, "\u{1b}") }
    private func modeKey() { requireKey("mode key"); key(1, "s", [.control, .command]) }
    /// Every measured press needs the window key (11-06, Advisor): a key lost mid-run aborts it like a non-key baseline.
    private func requireKey(_ what: String) {
        // Any of our windows will do: a torn-off window may hold key mid-carry.
        guard ProcessInfo.processInfo.environment["INPUT_INACTIVE"] != "1", !app.windows.contains(where: { $0.window.isKeyWindow }) else { return }
        log("abort", ["reason": "window not key at \(what)", "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"])
        NSApp.terminate(nil)
    }
    private func numberKey(_ n: String) { key(UInt16(n == "2" ? 19 : 18), n) }

    /// A real change of active app, as a person's ⌘-Tab would make.
    private func otherApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }

    private func activate() {
        // INPUT_INACTIVE=1: someone else may be using this Mac. Paths that need the window key can't run like this.
        if ProcessInfo.processInfo.environment["INPUT_INACTIVE"] == "1" { return }
        NSApp.activate(ignoringOtherApps: true)
        window.window.makeKeyAndOrderFront(nil)
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    // MARK: Where things are

    private func point(_ source: Source) -> CGPoint? {
        let dock = scene.dock
        switch source {
        case .dock:
            guard let r = scene.order.compactMap({ id -> CGRect? in
                guard let item = dock.items[id], item.role == .orb else { return nil }
                return item.glass.frame
            }).first else { return nil }
            return CGPoint(x: r.midX, y: r.midY)
        case .bar:
            guard let item = scene.order.compactMap({ dock.items[$0] }).last(where: { $0.role == .bar && $0.identityOpacity.to > 0 }) else { return nil }
            return CGPoint(x: item.identityFrame.midX, y: item.identityFrame.midY)
        case .grip:
            guard let item = scene.order.compactMap({ dock.items[$0] }).last(where: { $0.role == .bar }) else { return nil }
            return CGPoint(x: item.glass.frame.midX, y: item.glass.frame.minY)
        case .full, .brief:
            let isFull = source == .full
            // Not canDragOrb: an idle window's islands are asleep until a press wakes them, as a real press does.
            guard let i = scene.columns.compactMap(\.island).first(where: { !$0.isHiddenOrHasHiddenAncestor && ($0.configuration?.id == scene.current) == isFull }) else { return nil }
            let r = dock.view.convert(i.draggableOrbRect, from: i)
            return CGPoint(x: r.midX, y: r.midY)
        }
    }

    /// A step along the row that stays inside the window: past its edge a press tears instead.
    private func inward(_ p: CGPoint, _ d: CGFloat) -> CGSize { CGSize(width: p.x > scene.size.width / 2 ? -d : d, height: 0) }
    /// Past the window's top edge, straight above the press: tears from a Dock node and from a column's header alike.
    private func outside(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: -60) }
    private func dockRow(near p: CGPoint) -> CGPoint {
        let me = scene.dockFrames.first ?? CGRect(x: p.x, y: scene.size.height - 40, width: 0, height: 0)
        return CGPoint(x: p.x, y: me.midY)
    }
    /// Empty desktop beside the window, on its screen, in scene points.
    private func desktop() -> CGPoint {
        let frame = window.window.frame, vis = window.window.screen?.visibleFrame ?? frame
        let screen = CGPoint(x: max(vis.minX + 30, frame.minX - 90), y: frame.midY)
        return scene.dock.view.convert(window.window.convertPoint(fromScreen: screen), from: nil)
    }
    private func point(inMiddleOf other: OrganicWindow) -> CGPoint {
        let f = other.window.frame
        return scene.dock.view.convert(window.window.convertPoint(fromScreen: CGPoint(x: f.midX, y: f.midY)), from: nil)
    }

    // MARK: What is left

    private func state() -> [String: Any] {
        let dock = scene.dock
        let panels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible && !$0.isSheet }
        let cg = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
            .map { ["layer": $0[kCGWindowLayer as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]] as [String: Any] }
        return [
            "mode": "\(window.shell.mode)", "current": scene.current, "order": scene.order, "windows": app.windows.count,
            "tearing": scene.isTearing, "dragging": scene.isDragging, "moving": scene.isMoving,
            "header": dock.headerOrbDragging?.phase.rawValue ?? "none", "headerReturns": dock.headerReturnCount,
            "panels": panels.map { NSStringFromRect($0.frame) }, "cgWindows": cg,
            "overlay": scene.overlayPlane.subviews.filter { !$0.isHidden }.map { String(describing: type(of: $0)) },
            "carried": scene.columns.compactMap(\.island).filter(\.orbIsCarried).compactMap { $0.configuration?.id },
            "dockHidden": dock.items.filter { $0.value.glass.layer?.isHidden == true }.map(\.key),
            "key": window.window.isKeyWindow, "alpha": window.window.alphaValue, "ambient": scene.ambientRunning,
            "visible": window.window.occlusionState.contains(.visible),
            "islands": scene.columns.compactMap(\.island).map { i in
                ["id": i.configuration?.id ?? "", "can": i.canDragOrb, "hidden": i.isHiddenOrHasHiddenAncestor, "active": i.configuration?.active ?? false, "alpha": i.alphaValue] as [String: Any]
            },
        ]
    }

    private func leftovers(expectedWindows: Int) -> [String] {
        var out: [String] = []
        let dock = scene.dock
        let panels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible && !$0.isSheet }
        if !panels.isEmpty { out.append("panel left on screen: \(panels.map { NSStringFromRect($0.frame) })") }
        if scene.isTearing { out.append("scene still tearing") }
        if scene.isDragging { out.append("scene still dragging") }
        if let phase = dock.headerOrbDragging?.phase, phase != .idle { out.append("header gesture \(phase.rawValue)") }
        if dock.headerReturnCount != 0 { out.append("\(dock.headerReturnCount) header returns unfinished") }
        // M11.37 keeps its trash passage in the overlay for the scene's lifetime (AutoSceneTrash.init) and hides only its
        // children, so it is a leftover only while it carries, prompts or is pressed. The type name is checked first so the
        // lazy trash controller is never created by this check.
        let overlay = scene.overlayPlane.subviews.filter { view in
            guard !view.isHidden else { return false }
            if String(describing: type(of: view)) == "OrbTrashPassage", view === scene.orbTrash.presentation.view {
                return scene.orbTrash.hasForegroundSurface
            }
            return true
        }
        if !overlay.isEmpty { out.append("overlay has \(overlay.map { String(describing: type(of: $0)) })") }
        let carried = scene.columns.compactMap(\.island).filter(\.orbIsCarried).compactMap { $0.configuration?.id }
        if !carried.isEmpty { out.append("header orb still carried: \(carried)") }
        let hidden = dock.items.filter { $0.value.glass.layer?.isHidden == true }.map(\.key)
        if !hidden.isEmpty, window.shell.mode == .organic { out.append("dock node hidden: \(hidden)") }
        if !scene.isMoving, window.shell.mode == .organic {
            // Everything visible stands where its spring ends: a node left at the pointer shows up here, whatever the flags say.
            for (id, item) in dock.items where item.glass.layer?.isHidden != true && item.glass.alphaValue > 0.01 {
                let end = item.spring.target, now = item.glass.frame
                if abs(end.midX - now.midX) > 2 || abs(end.midY - now.midY) > 12 { out.append("dock node \(id) stands at \(NSStringFromRect(now)), its slot is \(NSStringFromRect(end))") }
            }
        }
        if app.windows.count != expectedWindows { out.append("\(app.windows.count) windows, expected \(expectedWindows)") }
        if window.window.alphaValue < 0.99 { out.append("window alpha \(window.window.alphaValue)") }
        return out
    }

    /// What `leftovers` can't see: a column can stand in its place with nothing in it (a full column stayed empty for 14 s
    /// in the user's 11-01 recording, through nine rounds of recordings and a matrix that only looked for what was left over).
    /// Every column on screen must hold its transcript, or it has nothing to show the moment it goes full. A full column
    /// must be showing it, over the column, with ink in it. At rest only: during a motion pictures stand in for the view.
    private func transcriptFindings() -> [String] {
        guard window.shell.mode == .organic, scene.transcriptsPresented, !scene.isMoving, !scene.inModeHandoff else { return [] }
        var out: [String] = []
        for column in scene.columns where column.hasSnapshotContent {
            let id = column.conversation.id, native = column.native
            guard column.ownsNative else {
                out.append("column \(id) holds no transcript: \(scene.isFull(id) ? "its full form is empty" : "it can't be prepared for going full")")
                continue
            }
            guard scene.isFull(id) else { continue }
            if native.isHiddenOrHasHiddenAncestor || native.layer?.isHidden == true || native.alphaValue < 0.99 { out.append("full column \(id): transcript hidden") }
            if native.superview !== scene.nativePlane || native.window !== window.window { out.append("full column \(id): transcript not in this window's plane") }
            let over = native.frame.intersection(column.target)
            if over.width < native.frame.width * 0.8 || over.width < column.target.width * 0.5 || over.height < 100 { out.append("full column \(id): transcript at \(NSStringFromRect(native.frame)), column at \(NSStringFromRect(column.target))") }
            if let mask = native.layer?.mask, mask.bounds.height < native.bounds.height - 1 { out.append("full column \(id): fade mask \(NSStringFromRect(mask.bounds)) over \(NSStringFromRect(native.bounds))") }
            if ink(native) < Self.blankInk { out.append("full column \(id): transcript draws nothing") }
            // Text above the glass of an expanded island, and selectable through it (user 11-01): the transcript stood over the plane's islands.
            let plane = scene.nativePlane.subviews
            if let n = plane.firstIndex(where: { $0 === native }), let i = scene.columns.compactMap(\.island).compactMap({ island in plane.firstIndex(where: { $0 === island }) }).min(), n > i {
                out.append("full column \(id): transcript over an island (\(n) over \(i) of \(plane.count))")
            }
        }
        return out
    }
    private func selectedCharacters(in view: NSView) -> Int {
        ((view as? NSTextView)?.selectedRange().length ?? 0) + view.subviews.reduce(0) { $0 + selectedCharacters(in: $1) }
    }
    /// The share of a capture that isn't its background, under which a transcript counts as blank. The shortest mock
    /// conversation, a few rows, stays well above this (the receipts' `transcripts`).
    private static let blankInk = 0.002

    private func transcriptsRead() -> [[String: Any]] {
        scene.columns.map { column in
            let id = column.conversation.id, full = scene.isFull(id)
            return ["id": id, "full": full, "owns": column.ownsNative, "hidden": column.native.isHidden, "items": column.conversation.items.count,
                    "frame": NSStringFromRect(column.native.frame), "ink": full ? ink(column.native) : -1, "atEnd": column.native.isAtEnd,
                    "offset": Double(column.native.scrollOffset.y), "content": Double(column.native.contentHeight)]
        }
    }

    /// Drawn the way the column's own captures are, through the view's layer and its mask. Hidden flags don't reach this.
    private func ink(_ view: NSView) -> Double {
        guard view.bounds.width > 1, view.bounds.height > 1, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage, let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data), image.bitsPerPixel == 32 else { return 0 }
        var buckets = [Int](repeating: 0, count: 32), total = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let o = y * image.bytesPerRow + x * 4
                // Premultiplied or transparent, the background lands in one bucket and ink doesn't.
                buckets[(Int(p[o]) * 2 + Int(p[o + 1]) * 5 + Int(p[o + 2])) / 8 / 8] += 1
                total += 1
            }
        }
        let background = buckets.indices.max { buckets[$0] < buckets[$1] } ?? 0
        let near = buckets.indices.filter { abs($0 - background) <= 1 }.reduce(0) { $0 + buckets[$1] }
        return Double(total - near) / Double(max(1, total))
    }

    private func log(_ step: String, _ extra: [String: Any] = [:]) {
        var e = extra; e["step"] = step; e["t"] = CACurrentMediaTime()
        app.composeLog.append(e)
    }

    /// INPUT_SYNC=1: three 16 pt white squares near the window's top-right corner, 50 ms each, above the product's views
    /// (on the theme frame, outside what a mode picture captures), each put in by a display-link callback and logged with
    /// that frame's targetTimestamp. WinRec's ptsSeconds start at 0, so this maps a recording onto the receipt's
    /// CACurrentMediaTime clock to within a frame. Runs before the first press, so clips cut at the keys leave it out.
    /// input-run.sh starts WinRec 2.2 s after the app, so the squares wait 2.5 s more to land inside the recording.
    private func syncFlash() async {
        guard ProcessInfo.processInfo.environment["INPUT_SYNC"] == "1", let frame = window.window.contentView?.superview,
              let host = frame.layer else { return }
        await sleep(2.5)
        let tick = SyncTick()
        for i in 0..<3 {
            let square = CALayer()
            square.backgroundColor = NSColor.white.cgColor
            square.frame = CGRect(x: frame.bounds.width - SyncTick.inset.x - 16,
                                  y: frame.isFlipped ? SyncTick.inset.y : frame.bounds.height - SyncTick.inset.y - 16, width: 16, height: 16)
            let shown: (CFTimeInterval, CFTimeInterval) = await withCheckedContinuation { done in
                tick.fire = { link in
                    CATransaction.begin(); CATransaction.setDisableActions(true); host.addSublayer(square); CATransaction.commit()
                    done.resume(returning: (link.timestamp, link.targetTimestamp))
                }
                let l = frame.displayLink(target: tick, selector: #selector(SyncTick.tick(_:)))
                l.add(to: .main, forMode: .common)
            }
            log("sync", ["index": i, "linkTimestamp": shown.0, "targetTimestamp": shown.1,
                         "square": [square.frame.minX, square.frame.minY, 16, 16], "flipped": frame.isFlipped])
            await sleep(0.05)
            CATransaction.begin(); CATransaction.setDisableActions(true); square.removeFromSuperlayer(); CATransaction.commit()
            await sleep(0.45)
        }
    }
    fileprivate func keepAppLog(_ step: String, _ extra: [String: Any]) { log(step, extra) }
    fileprivate func keepAppSleep(_ seconds: Double) async { await sleep(seconds) }
    fileprivate func keepAppEnterScheme() async { await enterScheme() }
    fileprivate func keepAppType(_ text: String) async {
        for c in text { key(0, String(c)); await sleep(0.05) }
    }
}

/// M11.20 in a real window. Run with ORGANIC_PERSIST=1, on the mock's own record. Nothing here uses `window` or `scene`, which need a
/// window, while there is none. INPUT_KEEP=first ends in ⌘Q with no window open; INPUT_KEEP=relaunch starts from what that kept.
/// tools/m11/keep-app-run.sh runs them in turn and compares the logged records.
extension InputRun {
    private func logRecord(_ step: String, _ extra: [String: Any] = [:]) {
        var e = extra
        e["windows"] = app.windows.count; e["visible"] = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.count
        e["footprint"] = keepAppFootprint()
        if let w = app.windows.first {
            e["record"] = (try? JSONEncoder().encode(SavedWindow.make(w))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            e["order"] = w.scene.order; e["key"] = w.window.isKeyWindow
        }
        keepAppLog(step, e)
    }
    private func keepAppFootprint() -> Double {
        var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
    private func keepAppCPU() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }
    /// What a click on the Dock icon sends: LaunchServices reopens the running instance.
    private func dockReopen() async {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [Bundle.main.bundlePath]
        try? p.run()
        await keepAppSleep(1.6)
    }
    private func closeFront() async { app.windows.first?.window.performClose(nil); await keepAppSleep(0.8) }
    /// A key equivalent with no window to route through; the menu takes it.
    private func command(_ code: UInt16, _ chars: String) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    func keepApp() async {
        let env = ProcessInfo.processInfo.environment
        await keepAppSleep(Double(env["INPUT_KEEP_LEAD"] ?? "") ?? 2.0)
        // INPUT_KEEP=syskey: a key from outside the app (tools/m11/keep-app-syskey.sh), through the window server rather than NSApp.postEvent.
        if env["INPUT_KEEP"] == "syskey" {
            logRecord("sys before")
            await closeFront(); logMenu("sys closed")
            await keepAppSleep(10)
            logRecord("sys after"); logMenu("sys after menu")
            NSApp.terminate(nil)
            return
        }
        if env["INPUT_KEEP"] == "relaunch" {
            logRecord("relaunched")
            if env["INPUT_KEEP_CYCLES"] == "1" {
                await closeFront()
                await keepAppSleep(10)
                let c0 = keepAppCPU(), t0 = CACurrentMediaTime()
                await keepAppSleep(30)
                logRecord("no window cpu", ["cpu": (keepAppCPU() - c0) / (CACurrentMediaTime() - t0)])
                await dockReopen()
                for i in 1...20 {
                    await closeFront(); await dockReopen(); logRecord("cycle", ["cycle": i])
                }
            }
            await closeFront(); logRecord("closed for cmd-n")
            command(45, "n"); await keepAppSleep(1.6); logRecord("cmd-n")
            await keepAppType("draft")
            await keepAppSleep(0.4); logRecord("draft typed")
            await closeFront(); logRecord("closed draft")
            await dockReopen(); logRecord("draft back")
            logRecord("end"); NSApp.terminate(nil)
            return
        }
        // A real arrangement to bring back: Organic, every mock conversation. An empty record opens as Normie on the latest one.
        if env["INPUT_KEEP_NORMIE"] != "1", let w = app.windows.first {
            w.shell.setMode(.organic, animated: false)
            for id in MockSeed.windowMembers where !w.scene.members.contains(where: { $0.id == id }) {
                if let c = app.store.conversation(id) { w.scene.admit(c, reason: "keep-app") }
            }
            await keepAppSleep(1.4)
            if env["INPUT_SCHEME"] == nil, let second = w.scene.order.dropFirst().first { w.scene.show(second); await keepAppSleep(1.2) }
        }
        await keepAppEnterScheme()
        if let w = app.windows.first {
            w.window.setFrame(CGRect(origin: CGPoint(x: w.window.frame.minX + 40, y: w.window.frame.minY + 10), size: CGSize(width: 1160, height: 760)), display: true)
            await keepAppSleep(0.8)
        }
        logRecord("before close")
        await closeFront(); logRecord("closed")
        await keepAppSleep(1.0); logRecord("still here")
        await dockReopen(); logRecord("reopened")
        await dockReopen(); logRecord("reopened again")
        if let w = app.windows.first {
            w.window.setFrame(w.window.frame.offsetBy(dx: 30, dy: 20), display: true)
            await keepAppSleep(0.8)
        }
        if env["INPUT_KEEP_EXTRA"] == "1" { await closeAwkwardly() }
        logRecord("before quit")
        await closeFront(); logRecord("closed for quit")
        command(12, "q")
    }

    /// Closing the last window at the awkward moments: while its columns move, during a mode flight, with Settings open.
    private func closeAwkwardly() async {
        if let w = app.windows.first, let other = w.scene.order.first(where: { $0 != w.scene.current }) {
            w.scene.show(other); await keepAppSleep(0.08)
            await closeFront(); logRecord("closed while moving")
            await dockReopen(); logRecord("back after moving")
        }
        if let w = app.windows.first {
            w.shell.setMode(w.shell.mode == .normie ? .organic : .normie); await keepAppSleep(0.15)
            await closeFront(); logRecord("closed in a mode flight")
            await dockReopen(); logRecord("back after a mode flight")
            if let w = app.windows.first { w.shell.setMode(.organic, animated: false); await keepAppSleep(0.8) }
        }
        app.settings?.show(); await keepAppSleep(1.0)
        await closeFront(); logRecord("closed with settings open", ["settings": NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.map(\.title)])
        await dockReopen(); logRecord("back with settings open")
        NSApp.windows.filter { w in w.isVisible && !app.windows.contains { $0.window === w } && !(w is NSPanel) }.forEach { $0.close() }
        await keepAppSleep(0.6); logRecord("settings closed")
    }

    /// The zero-window ⌘N on a real Core (read-only, nothing typed or sent): what the menu item says, the posted event, then the menu directly.
    func keepAppLive() async {
        await keepAppSleep(Double(ProcessInfo.processInfo.environment["INPUT_LEAD"] ?? "") ?? 12)
        logRecord("live before")
        await closeFront(); logMenu("live closed")
        command(45, "n"); await keepAppSleep(2.0); logRecord("live cmd-n posted")
        if app.windows.isEmpty {
            let handled = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                           characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45).map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
            await keepAppSleep(2.0); logRecord("live cmd-n menu", ["handled": handled])
        }
        logMenu("live after")
        if !app.windows.isEmpty { await closeFront() }
        await dockReopen(); logRecord("live reopened")
        await keepAppSleep(0.5)
        // INPUT_KEEP_QUIT=window: the user's path, ⌘Q with the window open and just moved. tools/m11/long-real.sh keeps what that saved in record-after.json.
        if ProcessInfo.processInfo.environment["INPUT_KEEP_QUIT"] == "window", let w = app.windows.first {
            w.window.setFrame(w.window.frame.offsetBy(dx: 30, dy: -20), display: true); await keepAppSleep(0.6)
            logRecord("live before quit")
        } else {
            if !app.windows.isEmpty { await closeFront() }
            logRecord("live closed for quit")
        }
        command(12, "q")
    }

    /// M11.20 on the live Core, the hand test's path: the windows as restored, arranged, moved, ⌘Q. INPUT_SCHEME is the arrangement;
    /// INPUT_ARRANGE=none only logs what came back. tools/m11/long-real.sh keeps what the quit saved in record-after.json, and LONG_RECORD starts the next run from it.
    func keepAppArrange() async {
        await keepAppSleep(Double(ProcessInfo.processInfo.environment["INPUT_LEAD"] ?? "") ?? 12)
        logRecord("arrange restored")
        // Who closes a window on the way out, if anything does: several windows must all reach the record.
        // The receipt is written first thing in willTerminate, so this goes to its own file, next to it.
        let trail = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["INPUT_TRAIL"] ?? "/dev/null"))
        func note(_ s: String) { let old = (try? String(contentsOf: trail, encoding: .utf8)) ?? ""; try? (old + s + "\n").write(to: trail, atomically: false, encoding: .utf8) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { n in
            note("window closes: \((n.object as? NSWindow)?.frame ?? .zero)\n" + Thread.callStackSymbols.prefix(30).joined(separator: "\n"))
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in note("willTerminate") }
        if ProcessInfo.processInfo.environment["INPUT_ARRANGE"] != "none" {
            await keepAppEnterScheme(); await keepAppSleep(1.0)
            if let w = app.windows.first { w.window.setFrame(w.window.frame.offsetBy(dx: 30, dy: -20), display: true); await keepAppSleep(0.6) }
            logRecord("arrange before quit")
        }
        logRecord("arrange quitting")
        if ProcessInfo.processInfo.environment["INPUT_QUIT"] == "terminate" { NSApp.terminate(nil); return }
        command(12, "q"); await keepAppSleep(3)
        logRecord("arrange still here after quit")
    }

    /// What the New Chat item says with no window: the first place a dead ⌘N shows.
    private func logMenu(_ step: String) {
        func walk(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) } }
        NSApp.mainMenu?.update()
        let n = (NSApp.mainMenu.map(walk) ?? []).first { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }
        logRecord(step, ["active": NSApp.isActive, "keyWindow": NSApp.keyWindow != nil, "menu": NSApp.mainMenu != nil,
                         "item": n?.title ?? "none", "enabled": n?.isEnabled ?? false, "target": n?.target.map { String(describing: type(of: $0)) } ?? "nil",
                         "action": n?.action.map { NSStringFromSelector($0) } ?? "nil"])
    }

    /// Across the Dock's orbs and back at a person's speed, then resting on one: M11.29, what the glass does while hover magnifies.
    func dockHover() async {
        await keepAppSleep(Double(ProcessInfo.processInfo.environment["INPUT_LEAD"] ?? "") ?? 3.0)
        await keepAppEnterScheme()
        guard let w = app.windows.first else { return }
        let orbs = w.scene.order.compactMap { id -> CGRect? in
            guard let item = w.scene.dock.items[id], item.role == .orb else { return nil }
            return item.glass.frame
        }
        guard let first = orbs.first, let last = orbs.last else { keepAppLog("dock-hover", ["orbs": 0]); return }
        // Under the orbs, as in the user's recording: the Dock magnifies but no orb is pointed at, so no Peek opens.
        let y = first.maxY + (Double(ProcessInfo.processInfo.environment["INPUT_HOVER_DY"] ?? "") ?? 14), from = first.midX - 70, to = last.midX + 30
        for (seconds, pause) in [(2.4, 1.2), (0.9, 1.2), (0.35, 1.2)] {
            for pair in [(from, to), (to, from)] {
                keepAppLog("dock-hover sweep", ["seconds": seconds])
                let steps = Int(seconds * 60)
                for i in 0...steps {
                    w.hover(CGPoint(x: pair.0 + (pair.1 - pair.0) * CGFloat(i) / CGFloat(steps), y: y))
                    await keepAppSleep(1.0 / 60)
                }
                keepAppLog("dock-hover rest", ["pause": pause]); await keepAppSleep(pause)
            }
        }
        await keepAppSleep(0.5)
    }
}
