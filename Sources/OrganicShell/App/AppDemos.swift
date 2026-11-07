import AppKit
import QuartzCore

extension AppController {
    /// For the Labs: the Transition Lab exports its 22-form filmstrip and plays both ways; then the Spring Lab plays its
    /// real column and measures it. Each window's number goes to the output for recording it on its own.
    func demoLabs() {
        guard let debug = debugTools, let out = o.output else { return }
        func after(_ t: Double, _ f: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { f() } }
        }
        func note(_ name: String, _ text: String) { try? text.write(toFile: out + "/" + name, atomically: true, encoding: .utf8) }
        after(1.0) {
            debug.toggleTransitionLab()
            let c = debug.controller(.transition)
            if let n = c.window?.windowNumber { note("transition-window.txt", "\(n)") }
            guard let page = c.page as? TransitionLabPage else { note("labs-error.txt", "no transition page"); return }
            do { try page.exportFilmstrip(to: URL(fileURLWithPath: out + "/filmstrip"), scale: 2) } catch { note("labs-error.txt", "\(error)") }
        }
        after(2.5) { (debug.controller(.transition).page as? TransitionLabPage)?.play(toBrief: true) }
        after(4.0) { (debug.controller(.transition).page as? TransitionLabPage)?.play(toBrief: false) }
        after(5.5) {
            debug.toggleTransitionLab()
            debug.toggleSpringLab()
            let c = debug.controller(.spring)
            if let n = c.window?.windowNumber { note("spring-window.txt", "\(n)") }
        }
        after(6.5) {
            guard let page = debug.controller(.spring).page as? SpringLabPage else { note("labs-error.txt", "no spring page"); return }
            page.request.realColumn = true
            page.play()
        }
        after(7.0) { (debug.controller(.spring).page as? SpringLabPage)?.interrupt() }
        after(9.0) {
            guard let page = debug.controller(.spring).page as? SpringLabPage else { return }
            page.request.runs = 3
            Task { @MainActor in
                do {
                    let m = try await page.measureHost()
                    let rows = m.map { ["variant": $0.variant.rawValue, "frames": $0.frames, "tailFrames": $0.tailFrames, "duration": $0.duration,
                                        "visibleEnd": $0.visibleEnd, "busyMs": $0.busyMilliseconds, "tailBusyMs": $0.tailBusyMilliseconds,
                                        "provenance": $0.provenance] as [String: Any] }
                    if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: out + "/spring-measure.json")) }
                } catch { note("labs-error.txt", "measure: \(error)") }
            }
        }
    }

    /// For the dock's other ways in (f008, f057, f073, f197): me hovered (the quota card), VoiceOver's dock and the two
    /// right-click menus written out, then an orb pressed and a bar's Focus action performed, as VoiceOver would.
    func demoAccess() {
        guard let out = o.output else { return }
        var log: [[String: Any]] = []
        func after(_ t: Double, _ f: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { f() } }
        }
        func centre(_ r: CGRect?) -> CGPoint { CGPoint(x: r?.midX ?? 0, y: r?.midY ?? 0) }
        func dock() -> [[String: Any]] {
            scene.dockAccessibilityChildren().compactMap { $0 as? DockElement }.map {
                ["label": $0.accessibilityLabel() ?? "", "actions": ($0.accessibilityCustomActions() ?? []).map(\.name),
                 "frame": NSStringFromRect($0.frameInHost())] as [String: Any]
            }
        }
        func menu(_ m: NSMenu?) -> [[String: Any]] {
            (m?.items ?? []).map { ["title": $0.title, "state": $0.state == .on, "submenu": $0.submenu?.items.count ?? 0, "separator": $0.isSeparatorItem] as [String: Any] }
        }
        func write() {
            if let d = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: out + "/access.json")) }
        }
        after(0.9) {
            func find(_ m: NSMenu?, _ title: String) -> NSMenuItem? {
                for i in m?.items ?? [] { if i.title == title { return i }; if let f = find(i.submenu, title) { return f } }
                return nil
            }
            let keys = ["New Chat", "Archive Chat", "Collapse to Side", "Toggle Sidebar"].map { t -> String in
                let i = find(NSApp.mainMenu, t); return "\(t)=\(i?.keyEquivalent.debugDescription ?? "nil")/\(i?.keyEquivalentModifierMask.rawValue ?? 0)"
            }
            let send = self.scene.composers.existingComposer(for: self.scene.current)?.sendShortcut
            log.append(["step": "shortcuts", "menu": keys, "send": send.map { "\($0.keyCode)/\($0.modifiers.rawValue)" } ?? "nil"])
        }
        after(1.0) { self.scene.pointer(centre(self.scene.dock.meFrame)) }
        after(1.8) { log.append(["step": "me hovered 0.8 s", "quotaCard": self.scene.meController.isQuotaPresented]) }
        after(2.2) { self.scene.pointer(nil); log.append(["step": "pointer away", "quotaCard": self.scene.meController.isQuotaPresented]) }
        after(2.5) {
            log.append(["step": "auto", "dock": dock(), "meMenu": menu(self.scene.contextMenu(at: centre(self.scene.dock.meFrame)))])
            if let orb = self.scene.order.dropFirst(self.scene.columns.count).first {
                log.append(["step": "orb menu", "orb": orb, "menu": menu(self.scene.contextMenu(at: centre(self.scene.dock.frame(of: orb))))])
                let e = self.scene.dockAccessibilityChildren().compactMap { $0 as? DockElement }.first { $0.accessibilityLabel()?.hasPrefix(self.scene.conversation(orb)?.title ?? "?") == true }
                log.append(["step": "press orb", "orb": orb, "pressed": e?.accessibilityPerformPress() ?? false])
            }
            write()
        }
        after(4.0) {
            log.append(["step": "after press", "current": self.scene.current, "order": self.scene.order])
            let bar = self.scene.dockAccessibilityChildren().compactMap { $0 as? DockElement }.first { $0.accessibilityLabel()?.hasPrefix("Move") == true }
            let focus = bar?.accessibilityCustomActions()?.first { $0.name == "Focus" }
            log.append(["step": "bar Focus", "bar": bar?.accessibilityLabel() ?? "", "performed": focus?.handler?() ?? false])
            write()
        }
        after(5.5) { log.append(["step": "focused", "isFocused": self.scene.isFocused, "dock": dock()]); write() }
    }

    /// For the audit's fixes (docs/reference/ORGANIC-AUDIT-26102909.md): each step logs what it should have changed.
    func demoAudit() {
        func after(_ t: Double, _ step: String, _ f: @escaping @MainActor () -> [String: Any]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                var e = f(); e["step"] = step; e["t"] = CACurrentMediaTime(); self.composeLog.append(e)
            } }
        }
        let s = { self.scene }
        func state() -> [String: Any] { ["focused": s().isFocused, "draft": s().composingNew, "members": s().members.map(\.id), "current": s().current, "order": s().order] }
        // A03: an Organic draft takes the menus' target away from the chat it covers.
        after(1.0, "A03 organic draft", { self.main.command(.newChat, tag: 0)
            let c = self.main.workbench.menus.context()
            return ["archiveEnabled": c.enabled(.archive), "renameEnabled": c.enabled(.rename), "stopEnabled": c.enabled(.stop)] })
        // A13: the draft's project goes into the conversation its first send makes.
        after(1.6, "A13 send with a project", {
            let p = self.store.projects.first
            s().draftContext = NormieNewChatContext(projectID: p?.id, deviceID: p?.deviceID ?? "mac")
            s().composers.draft().composer.setText("audit draft"); s().composers.draft().composer.submit()
            return [:] })
        after(2.6, "A13 made", { let c = self.store.conversation(s().current); return ["current": s().current, "project": c?.projectID ?? "nil", "device": c?.deviceID ?? "nil", "wanted": self.store.projects.first?.id ?? "nil"] })
        // A04: Normie's draft is Organic's after Hide Sidebar, and back.
        after(3.2, "A04 normie draft", { self.shell.setMode(.normie, animated: false); _ = self.main.workbench.newChat(); return ["normieDraft": self.main.workbench.composingNew] })
        after(3.8, "A04 to organic", { self.shell.setMode(.organic, animated: false); return state() })
        after(4.6, "A04 back to normie", { self.shell.setMode(.normie, animated: false); return ["normieDraft": self.main.workbench.composingNew] })
        after(5.2, "A04 settle", { _ = self.main.workbench.cancelNewChat(); self.shell.setMode(.organic, animated: false); s().cancelNewChat(); return state() })
        // A07: Focused on the current, then it is archived: back to Auto, and New Chat opens again.
        after(6.0, "A07 focused", { s().enterFocused(s().current, reason: "audit"); return state() })
        after(7.0, "A07 archive it", { s().remove(s().current, reason: "audit"); return state() })
        after(8.0, "A07 new chat", { s().newChat(); return state() })
        after(8.6, "A07 cancel", { s().cancelNewChat(); return state() })
        // A08: three segments, then a narrow window: the capsule gives back what it cannot hold.
        after(9.4, "A08 split of three", {
            s().enterFocused(s().order[0], reason: "audit")
            return [:] })
        after(10.2, "A08 graft", { let o = s().order; s().graft(o[1], at: 1, reason: "audit"); return [:] })
        after(11.0, "A08 graft", { let o = s().order.filter { !s().scheme.split.contains($0) }; s().graft(o[0], at: 2, reason: "audit"); return ["split": s().scheme.split] })
        after(12.0, "A08 narrow", { var f = self.window.frame; f.size.width = 720; self.window.setFrame(f, display: true); return [:] })
        after(12.4, "A08 resized", { s().resize(to: self.main.root.bounds.size, live: false); return [:] })
        after(13.4, "A08 fitted", { ["split": s().scheme.split, "width": self.main.root.bounds.width] })
        // A15: one place along the queue.
        after(14.0, "A15 move", { s().leaveFocused(reason: "audit"); return [:] })
        after(15.0, "A15 before", { state() })
        after(15.2, "A15 moved", { let id = s().order.last ?? ""; s().moveMember(id, by: -1); return ["moved": id] })
        after(16.2, "A15 after", { state() })
        // A01: Move keeps the very editor.
        after(16.8, "A01 move", {
            let id = s().current
            let before = s().composers.existingComposer(for: id).map { ObjectIdentifier($0).hashValue } ?? 0
            s().composers.existingComposer(for: id)?.setText("typed before the move")
            // Directly: a scripted run has no key window, and the menu path requires this one to be it (A14).
            self.moveToNewWindow(id, from: self.main)
            let w = self.windows.last
            let afterID = w?.scene.composers.existingComposer(for: id).map { ObjectIdentifier($0).hashValue } ?? -1
            return ["sameEditor": before == afterID, "text": w?.scene.composers.existingComposer(for: id)?.text ?? "", "windows": self.windows.count] })
        after(18.0, "end", { [:] })
    }

    /// For the second audits' fixes (docs/reference/APP-AUDIT-26102909.md, ORGANIC-AUDIT2-26102909.md).
    /// Organic columns' transcripts act through the window's actions (f176, f082, f091): an approval, a question, Undo
    /// on a changes card, Edit and Fork, each called the way the transcript's own buttons call them. Mock only.
    func demoOrganicActions() {
        func column(_ id: String) -> ColumnNode? { scene.columns.first { $0.conversation.id == id } }
        func after(_ t: Double, _ step: String, _ f: @escaping @MainActor () -> [String: Any]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                var e = f(); e["step"] = step; self.composeLog.append(e)
            } }
        }
        after(1.0, "show B", { self.scene.show("B"); return [:] })
        after(2.4, "approve B", {
            guard let c = self.store.conversation("B"), let a = c.approvals.first, let t = column("B")?.native else { return ["missing": true] }
            let wired = t.onApproval != nil
            t.onApproval?(a, .accept)
            return ["wired": wired, "approvalsLeft": c.approvals.count, "running": c.running] })
        after(2.8, "show C", { self.scene.show("C"); return [:] })
        after(4.2, "answer C", {
            guard let c = self.store.conversation("C"), let t = column("C")?.native else { return ["missing": true] }
            let request = c.userInput ?? c.question.map { UserInputRequest(id: "fixture-question:" + c.id, questions: [.init(id: "answer", header: "Question", prompt: $0, options: [])]) }
            guard let request else { return ["noQuestion": true] }
            let wired = t.onAnswer != nil
            t.onAnswer?(request, Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, ["Keep the sheet"]) }))
            return ["wired": wired, "questionLeft": c.question != nil || c.userInput != nil] })
        after(4.6, "show F", { self.scene.show("F"); return [:] })
        after(6.0, "undo, edit, fork in F", {
            guard let c = self.store.conversation("F"), let t = column("F")?.native else { return ["missing": true] }
            var e: [String: Any] = ["revertWired": t.onRevertChanges != nil, "forkWired": t.onForkMessage != nil, "editTarget": t.messageDraftTarget != nil]
            if let card = c.items.first(where: { $0.id == "F-t1-changes" }) {
                t.onRevertChanges?(card)
                e["reverted"] = c.items.first { $0.id == card.id }?.status == TranscriptPresentation.changesReverted
            }
            if let user = c.items.first(where: { $0.rowKind == .user }) {
                e["edited"] = t.messageDraftTarget?.stageUserMessageDraft(user) ?? false
                e["draftIsMessage"] = self.scene.composer(for: c).text == user.text
                let before = Set(self.store.conversations.map(\.id))
                t.onForkMessage?(user)
                let fork = self.store.conversations.first { !before.contains($0.id) }
                e["fork"] = fork?.title ?? ""; e["forkShown"] = fork.map { self.scene.current == $0.id } ?? false
                e["forkHeldBy"] = fork.map { f in self.windows.filter { $0.scene.members.contains { $0.id == f.id } }.count } ?? 0
            }
            return e })
        // f077: an open Status panel follows its conversation (retitled here through the store).
        func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
        after(7.0, "open status", { self.scene.columns.first { $0.conversation.id == self.scene.current }?.island?.openPanel(.status); return [:] })
        after(8.0, "retitle with panel open", {
            guard let c = self.store.conversation(self.scene.current), let panel = self.scene.columns.first(where: { $0.conversation === c })?.island?.panelContent?(.status) else { return ["noPanel": true] }
            let before = texts(panel.view).contains(c.title)
            c.title = "Retitled for f077"; self.store.changed(c)
            return ["inWindow": panel.view.window != nil, "showedTitleBefore": before, "showsNewTitle": texts(panel.view).contains("Retitled for f077")] })
        // f175: Stop in Organic goes under the editor's request UUID and its receipt ends the pending stop.
        after(10.2, "stop a running column", {
            guard let c = self.scene.columns.map(\.conversation).first(where: { $0.running }) ?? self.store.conversations.first(where: { $0.running }) else { return ["noneRunning": true] }
            if !self.scene.columns.contains(where: { $0.conversation === c }) { self.scene.show(c.id) }
            let composer = self.scene.composer(for: c)
            let wired = composer.onStopRequest != nil
            return ["id": c.id, "wired": wired, "requested": composer.requestStop(), "runningAfterRequest": c.running] })
        after(11.4, "after stop receipt", {
            guard let c = self.store.conversations.first(where: { $0.stopping || !$0.running && $0.operationError == nil }) else { return [:] }
            return ["running": self.store.conversations.filter(\.running).map(\.id), "stopping": self.store.conversations.filter(\.stopping).map(\.id), "sample": c.id] })
        // f121, f177: an open sub-agent window follows its parent: done, and then its history as it arrives.
        func shown(_ id: String) -> [String: Any] {
            let p = self.scene.subAgentWindows.history(subagentID: id)?.projection
            return ["running": p?.running ?? false, "rows": p?.items.map(\.id) ?? []]
        }
        after(9.0, "open sub-agent", {
            guard let a = self.store.conversation("A"), let s = a.satellites.first(where: { !$0.done }) else { return ["noSatellite": true] }
            return ["opened": self.scene.subAgentWindows.present(subagentID: s.id, of: a), "id": s.id, "before": shown(s.id)] })
        after(9.6, "sub-agent done, history arrives", {
            guard let a = self.store.conversation("A"), let id = self.scene.subAgentWindows.openIDs.first, let i = a.satellites.firstIndex(where: { $0.id == id }) else { return ["none": true] }
            a.satellites[i].done = true; self.store.changed(a)
            let done = shown(id)
            a.satellites[i].items = [.init(id: "child-1", turnID: "t", kind: .assistant, text: "Found it.")]; self.store.changed(a); self.store.changed(a)
            return ["afterDone": done, "afterHistory": shown(id)] })
    }

    /// Live hooks, read only (f025, f136, f153): each window's Open in proof and decision (nothing opened), Settings
    /// offering Open Local and Save Address, Open Local refusing what is not the Core's to open, and a window moved out
    /// taking the proof and the terminal. With --live-core.
    func demoLiveHooks() {
        func state(_ w: OrganicWindow) -> [String: Any] {
            let decision = w.workbench.openIn.decision(application: "Finder")
            let shown: String
            switch decision { case .open(let url, _): shown = "open " + url.path; case .denied(let m): shown = "denied " + m; case .prototype(let m): shown = "prototype " + m }
            return ["verified": w.workbench.openIn.identity?.verified ?? false, "finder": shown,
                    "terminal": w.workbench.detail.terminalPane.add.isEnabled]
        }
        func wait(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                guard self.live?.isConnected == true, let c = self.store.conversation(self.main.scene.current), c.historyLoaded else { if tries > 0 { wait(tries - 1) }; return }
                var e: [String: Any] = ["step": "connected", "local": self.core?.isLocalBackend ?? false, "main": state(self.main),
                                        "openLocal": self.liveSettings.supportedOperations.contains(.openLocal),
                                        "endpointSave": self.liveSettings.supportedOperations.contains(.endpointSave)]
                let open = self.liveSettings.onOpenLocal
                Task { @MainActor in
                    for (tag, url) in [("missing", URL(fileURLWithPath: "/nonexistent-organic-check")), ("otherDirectory", URL(fileURLWithPath: NSTemporaryDirectory()))] {
                        do { try await open?(url); e[tag] = "opened (wrong)" } catch { e[tag] = "refused: " + error.localizedDescription }
                    }
                    self.composeLog.append(e)
                    // f015: one more page of history through the window's action (a read).
                    let before = self.store.conversations.count, more = self.main.actions.hasMoreHistory?() ?? false
                    let paged: String = await withCheckedContinuation { done in
                        guard let load = self.main.actions.loadMoreHistory else { done.resume(returning: "not wired"); return }
                        load { result in done.resume(returning: (try? result.get()) != nil ? "ok" : "failed") }
                    }
                    self.composeLog.append(["step": "history page", "hadMore": more, "result": paged, "before": before, "after": self.store.conversations.count,
                                            "moreNow": self.main.actions.hasMoreHistory?() ?? false])
                    // A second member, so the move leaves this window open (no Core state changes).
                    if let other = self.store.conversations.first(where: { $0.id != c.id && !$0.archived }) { self.main.scene.admit(other, reason: "demo") }
                    self.composeLog.append(["step": "before move", "allowsTransfer": self.main.allowsTransfer, "members": self.main.scene.members.count])
                    self.moveToNewWindow(c.id, from: self.main)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let moved = self.windows.first { $0 !== self.main && $0.scene.members.contains { $0.id == c.id } }
                        self.composeLog.append(["step": "moved", "windows": self.windows.count, "new": moved.map(state) ?? [:]])
                    }
                }
            }
        }
        wait(60)
    }

    /// Typing goes on across Hide / Show Sidebar (f027, f030, f031, f101): the editor keeps the keyboard, an IME
    /// composition and the selection through three quick reversals, and the next characters land where the user was.
    /// Mock; the composition is set through NSTextInputClient as an input method sets it.
    func demoFocusContinuity() {
        var view: NativeComposerTextView?
        func state(_ tag: String) -> [String: Any] {
            guard let v = view else { return ["step": tag, "noEditor": true] }
            return ["step": tag, "mode": "\(self.shell.mode)", "firstResponder": self.main.window.firstResponder === v, "marked": v.hasMarkedText(),
                    "markedRange": NSStringFromRange(v.markedRange()), "selection": NSStringFromRange(v.selectedRange()), "text": v.string,
                    "inWindow": v.window === self.main.window, "moving": self.shell.flight.debugState]
        }
        let steps: [(Double, () -> Void)] = [
            (0.8, {
                self.shell.setMode(.normie, animated: false)
                guard let composer = self.main.workbench.detail.composer else { self.composeLog.append(["noComposer": true]); return }
                let v = composer.textView; view = v
                self.main.window.makeFirstResponder(v)
                v.string = ""; v.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
                v.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                self.composeLog.append(state("composing in Normie"))
            }),
            (1.5, { self.shell.setMode(.organic) }), (1.65, { self.shell.setMode(.normie) }), (1.8, { self.shell.setMode(.organic) }),
            (3.6, {
                self.composeLog.append(state("Organic, settled"))
                view?.insertText("中", replacementRange: view?.markedRange() ?? NSRange(location: NSNotFound, length: 0))
                view?.insertText("文", replacementRange: NSRange(location: NSNotFound, length: 0))
                self.composeLog.append(state("typed in Organic"))
            }),
            (4.0, { self.shell.setMode(.normie) }),
            (5.6, {
                self.composeLog.append(state("Normie, settled"))
                view?.insertText("。", replacementRange: NSRange(location: NSNotFound, length: 0))
                self.composeLog.append(state("typed in Normie"))
                view?.string = ""
            }),
        ]
        for (t, run) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } } }
    }

    /// Live writes in one throwaway conversation (approved by the user, 10-29): Send, Stop, an approval, and Undo on the
    /// changes card, all in a throwaway git repository (LIVE_TEST_REPO). Each step waits on the conversation's own state
    /// and is logged; the app quits when done. With --live-core. Nothing else of the user's is touched.
    func demoLiveWrite() {
        guard let repo = ProcessInfo.processInfo.environment["LIVE_TEST_REPO"], repo.hasPrefix("/") else { composeLog.append(["step": "no LIVE_TEST_REPO"]); return }
        var c: Conversation?
        let marker = "checked by Organic Animation"
        func log(_ step: String, _ extra: [String: Any] = [:]) {
            var e = extra; e["step"] = step; e["t"] = CACurrentMediaTime()
            if let c { e["running"] = c.running; e["error"] = c.operationError ?? ""; e["unknown"] = c.sendOutcomeUnknown; e["items"] = c.items.count; e["approvals"] = c.approvals.count }
            composeLog.append(e)
        }
        func wait(_ timeout: Double, _ ready: @escaping () -> Bool, _ then: @escaping (Bool) -> Void) {
            let start = CACurrentMediaTime()
            func poll() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if ready() { then(true) } else if CACurrentMediaTime() - start > timeout { then(false) } else { poll() }
                }
            }
            poll()
        }
        var lagReport: (() -> [String: Any])?
        func finish() { log("done", ["lag": lagReport?() ?? [:]]); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
        func tail() -> [String] { (c?.items.suffix(4) ?? []).map { "\($0.rowKind) [\($0.status ?? "-")] " + String($0.text.prefix(90)) } }
        func send(_ text: String, access: Access) -> Bool {
            guard let c else { return false }
            let k = scene.composer(for: c); k.setAccess(access); k.setText(text); return k.submit()
        }
        func readme() -> String { (try? String(contentsOfFile: repo + "/README.md", encoding: .utf8)) ?? "" }
        func turnOver() -> Bool { guard let c else { return true }; return !c.running && !c.sending }

        wait(90, { self.live?.isConnected == true && !self.store.conversations.isEmpty }) { ok in
            guard ok, let live = self.live else { log("not connected"); finish(); return }
            // How far behind the Core each streamed delta is handled (Core's event time → this app's receive).
            var lags: [Double] = []
            let forward = live.onEvent
            live.onEvent = { e in
                if e.method == "item/agentMessage/delta", let t = e.time { lags.append(Date().timeIntervalSince1970 - t) }
                forward?(e)
            }
            lagReport = {
                let sorted = lags.sorted()
                func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : (sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000).rounded() }
                return ["deltas": sorted.count, "lagMsP50": q(0.5), "lagMsP90": q(0.9), "lagMsMax": q(1)]
            }
            // The same throwaway conversation each run (LIVE_TEST_THREAD); else one is made in the test repository.
            let title = "Organic Animation · live test"
            let thread = ProcessInfo.processInfo.environment["LIVE_TEST_THREAD"]
            let reused = self.store.conversations.first { $0.backendThreadID != nil && $0.backendThreadID == thread && !$0.archived }
            let made = reused ?? live.createUnsentConversation(title: title, projectID: nil)
            if reused == nil { made.cwd = repo; made.next.effort = .low; made.settings = made.next; self.store.add(made) }
            c = made
            self.main.reveal(made.id)
            log(reused == nil ? "created" : "reused", ["shown": self.main.workbench.selectedConversation?.id == made.id, "cwd": made.cwd ?? ""])
            // LIVE_TEST_REVERT=1: only Undo on the last changes card already in the conversation (nothing is sent).
            if ProcessInfo.processInfo.environment["LIVE_TEST_REVERT"] != nil {
                // After the history read and its changes refresh (a revert while git is busy does nothing, as the product's).
                wait(60, { made.historyLoaded && !made.gitBusy && !made.loading }) { _ in
                    guard let card = made.items.last(where: { $0.rowKind == .tool(.fileChange) && $0.text.contains("  +") }) else { log("revert: no changes card", ["tail": tail()]); finish(); return }
                    log("revert: requested", ["card": card.text, "readmeHasLine": readme().contains(marker), "status": card.status ?? ""])
                    self.main.actions.revertTranscript?(made, card)
                    wait(40, { self.main.window.attachedSheet != nil || made.operationError != nil }) { _ in
                        guard let sheet = self.main.window.attachedSheet else { log("revert: no confirmation", ["tail": tail()]); finish(); return }
                        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
                        func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
                        let all = sheet.contentView.map(buttons) ?? []
                        log("revert: confirmation", ["buttons": all.map(\.title), "text": (sheet.contentView.map(texts) ?? []).joined(separator: " | ").prefix(300)])
                        all.first { $0.title == "Revert" }?.performClick(nil)
                        wait(40, { !readme().contains(marker) && made.items.contains { $0.id == card.id && $0.status == TranscriptPresentation.changesReverted } }) { reverted in
                            log("revert done", ["ok": reverted, "readmeHasLine": readme().contains(marker), "cardStatus": made.items.first { $0.id == card.id }?.status ?? ""])
                            finish()
                        }
                    }
                }
                return
            }
            // LIVE_TEST_STREAM=1: only one long streamed answer, for timing how fast the deltas are handled.
            if ProcessInfo.processInfo.environment["LIVE_TEST_STREAM"] != nil {
                let base = made.items.count
                log("stream: send", ["submitted": send("Count from 1 to 300, one number per line. Do not use any tools.", access: .auto)])
                wait(180, { turnOver() && made.items.count > base + 1 }) { ok in
                    log("stream done", ["ok": ok, "answerLength": made.items.last { $0.rowKind == .assistant }?.text.count ?? 0, "lag": lagReport?() ?? [:]])
                    finish()
                }
                return
            }
            // 1. Send: one short answer, finished on its receipt.
            var base = made.items.count
            wait(60, { (made.backendThreadID == nil || made.historyLoaded) && self.scene.composer(for: made).state.online }) { _ in
            base = made.items.count
            log("send", ["submitted": send("Reply with exactly one word: pong", access: .auto)])
            wait(150, { turnOver() && made.items.dropFirst(base).contains { $0.rowKind == .assistant && $0.text.lowercased().contains("pong") } }) { ok in
                log("send done", ["ok": ok, "thread": made.backendThreadID ?? "", "tail": tail()])
                // 2. Stop: a long answer, stopped while it streams.
                base = made.items.count
                log("stop: send", ["submitted": send("Count from 1 to 400, one number per line. Do not use any tools.", access: .auto)])
                wait(120, { made.running && (made.items.dropFirst(base).last { $0.rowKind == .assistant }?.text.count ?? 0) > 40 }) { streaming in
                    let k = self.scene.composer(for: made)
                    log("stop: request", ["streaming": streaming, "requested": k.requestStop()])
                    wait(90, { turnOver() }) { stopped in
                        log("stop done", ["lag": lagReport?() ?? [:], "ok": stopped, "answerLength": made.items.last { $0.rowKind == .assistant }?.text.count ?? 0, "stopping": made.stopping, "tail": tail()])
                        // 3. Approval: Read Only, so writing README.md asks first; accepted through the window's actions.
                        let edit = "Append one line with the exact text `\(marker)` to the end of README.md in the current directory, using your file editing tool. Do nothing else."
                        let k = self.scene.composer(for: made); k.setAccess(.readOnly); k.setText(edit)
                        // The editor takes the next message once the stopped turn has really ended (Core's turn/completed).
                        wait(60, { k.canSend }) { ready in
                        log("approval: send", ["ready": ready, "submitted": k.submit(), "stopping": made.stopping, "composerStopping": k.state.stopping,
                                               "sending": k.state.sending, "loading": k.state.loading, "online": k.state.online, "unknown": k.state.outcomeUnknown])
                        wait(240, { !made.approvals.isEmpty || (turnOver() && made.items.last?.rowKind != .user) }) { _ in
                            guard let a = made.approvals.first else { log("approval: none asked", ["tail": tail(), "readme": readme().contains(marker)]); finish(); return }
                            log("approval: asked", ["title": a.title, "method": a.method, "command": String(a.command.prefix(120))])
                            self.main.actions.approval?(made, a, .accept)
                            wait(240, { turnOver() && made.approvals.isEmpty }) { done in
                                log("approval done", ["ok": done, "readmeHasLine": readme().contains(marker), "tail": tail()])
                                // 4. Undo on the changes card: the window reviews the diff and asks; the demo confirms.
                                guard let card = made.items.last(where: { $0.rowKind == .tool(.fileChange) && $0.text.contains("  +") }) else { log("revert: no changes card", ["tail": tail()]); finish(); return }
                                self.main.actions.revertTranscript?(made, card)
                                log("revert: requested", ["card": card.text])
                                wait(40, { self.main.window.attachedSheet != nil }) { asked in
                                    guard asked, let sheet = self.main.window.attachedSheet else { log("revert: no confirmation", ["tail": tail()]); finish(); return }
                                    func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
                                    let all = sheet.contentView.map(buttons) ?? []
                                    log("revert: confirmation", ["buttons": all.map(\.title)])
                                    all.first { $0.title == "Revert" }?.performClick(nil)
                                    wait(40, { !readme().contains(marker) && made.items.contains { $0.id == card.id && $0.status == TranscriptPresentation.changesReverted } }) { reverted in
                                        log("revert done", ["ok": reverted, "readmeHasLine": readme().contains(marker), "cardStatus": made.items.first { $0.id == card.id }?.status ?? ""])
                                        finish()
                                    }
                                }
                            }
                        }
                        }
                    }
            }
                }
            }
        }
    }

    /// Sets up what f003 must bring back (run with ORGANIC_PERSIST=1, then launch again): PERSIST_CASE=split puts
    /// Organic in Focused with A and B split and B's editor holding the keyboard; PERSIST_CASE=draft leaves Normie in New
    /// Chat with unsent words in a project. Mock only.
    func demoPersist() {
        let w = main
        let steps: [(Double, () -> Void)]
        if ProcessInfo.processInfo.environment["PERSIST_CASE"] == "reset" {
            // Back to a plain window: the draft emptied and the latest conversation shown (after a check, before a real launch).
            steps = [(6.0, { let k = w.scene.composers.draft().composer; k.setText(""); k.attachments = []
                             if let latest = self.store.conversations.filter({ !$0.archived }).max(by: { $0.updated < $1.updated }) { w.scene.admit(latest, reason: "reset"); w.reveal(latest.id) } })]
        } else if ProcessInfo.processInfo.environment["PERSIST_CASE"] == "livedraft", let file = ProcessInfo.processInfo.environment["PERSIST_FILE"] {
            // Live: New Chat in Normie with words and a local file, once the history has loaded.
            steps = [(6.0, { _ = w.workbench.newChat(projectID: nil) }),
                     (6.6, { let k = w.scene.composers.draft().composer; k.setText("unsent words with a file")
                             k.attachments = [Attachment(id: "f179-note", name: "f179-note.txt", symbol: "doc.text", url: URL(fileURLWithPath: file), mimeType: "text/plain")] })]
        } else if ProcessInfo.processInfo.environment["PERSIST_CASE"] == "frame" {
            // Live: moved and resized once the history has loaded (the first window opens centred before that).
            steps = [(6.0, { var f = w.window.frame; f.origin.x -= 120; f.origin.y -= 50; f.size = CGSize(width: 1100, height: 700); w.window.setFrame(f, display: true) })]
        } else if ProcessInfo.processInfo.environment["PERSIST_CASE"] == "draft" {
            steps = [(0.8, { self.shell.setMode(.normie, animated: false) }),
                     (1.4, { _ = w.workbench.newChat(projectID: self.store.projects.first?.id) }),
                     (2.0, { w.scene.composers.draft().composer.setText("unsent words for f003") })]
        } else {
            steps = [(0.8, { self.shell.setMode(.organic, animated: false) }),
                     (1.4, { w.scene.enterFocused("A", reason: "demo") }),
                     (2.6, { w.scene.graft("B", at: 1, reason: "demo") }),
                     (3.8, { if let b = self.store.conversation("B") { w.scene.composer(for: b).focus() } })]
        }
        for (t, run) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } } }
    }

    /// The Debug panel's values reach the scene (f009): the dock's bottom margin moves the dock at rest, a slower Auto
    /// spring makes the next switch longer, and Reset puts both back. Mock.
    func demoTuning() {
        let s = { self.scene }
        func state(_ step: String) -> [String: Any] {
            ["step": step, "meY": s().meRest.minY, "lastDuration": (s().lastSwitch?["durationSeconds"] as? Double) ?? 0]
        }
        let tuning = { self.debugTools?.session.tuning }
        let steps: [(Double, () -> Void)] = [
            (1.0, { self.composeLog.append(state("defaults")); s().switchTo(1, reason: "tuning-before") }),
            (2.5, { self.composeLog.append(state("switched at defaults"))
                    tuning()?.set(DebugTuningParameter.dockBottom.key, 70); tuning()?.set(DebugTuningParameter.autoResponse.key, 0.9) }),
            (3.0, { self.composeLog.append(state("tuned at rest")); s().switchTo(0, reason: "tuning-after") }),
            (5.0, { self.composeLog.append(state("switched tuned")); tuning()?.reset() }),
            (5.5, { self.composeLog.append(state("reset at rest")); s().switchTo(1, reason: "tuning-reset") }),
            (7.0, { self.composeLog.append(state("switched after reset")) }),
        ]
        for (t, run) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } } }
    }

    func demoAudit2() {
        func after(_ t: Double, _ step: String, _ f: @escaping @MainActor () -> [String: Any]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                var e = f(); e["step"] = step; self.composeLog.append(e)
            } }
        }
        let s = { self.scene }, w = { self.main }
        // AP01: an approval answered through the actions reaches the runtime, and the turn goes on.
        after(0.8, "AP01 approve", {
            guard let c = self.store.conversations.first(where: { !$0.approvals.isEmpty }), let a = c.approvals.first else { return ["none": true] }
            w().actions.approval?(c, a, .accept)
            return ["id": c.id, "approvalsLeft": c.approvals.count, "running": c.running] })
        // AP06, AP05: the Conversation menu in Organic.
        after(1.6, "AP06 split with next", { w().command(.split, tag: 0); return ["focused": s().isFocused, "split": s().scheme.split] })
        after(2.6, "AP06 again", { w().command(.split, tag: 0); return ["split": s().scheme.split] })
        after(3.4, "back", { s().leaveFocused(reason: "audit"); return [:] })
        after(4.4, "AP05 customize", { w().command(.customize, tag: 0); return ["menuEnabled": w().workbench.menus.context().enabled(.customize)] })
        // AP15: Fully Focused from the menu reaches Settings' preference.
        after(5.0, "AP15 fully focused", { w().command(.fullyFocused, tag: 0)
            return ["scene": s().fullyFocused, "pref": self.settings?.session.preferences["organic.fullyFocused"].boolValue ?? false] })
        after(5.4, "AP15 back", { w().command(.fullyFocused, tag: 0); return ["scene": s().fullyFocused] })
        // AP10: the follow-up default reaches the store.
        after(5.8, "AP10 queue", { self.settings?.session.preferences.set("followUpDefault", .string("queue")); return ["store": "\(self.store.followUpDefault)"] })
        after(6.0, "AP10 back", { self.settings?.session.preferences.set("followUpDefault", .string("steer")); return ["store": "\(self.store.followUpDefault)"] })
        // AP08: a non-Return Send shortcut is kept.
        after(6.2, "AP08 send", { let k = AppController.sendShortcut("⌥⌘K"); return ["keyCode": Int(k.keyCode), "modifiers": Int(k.modifiers.rawValue)] })
        // B12: pointing at an orb marks its red events seen.
        after(6.4, "B12 hover", {
            guard let id = s().order.dropFirst(s().columns.count).first, let c = s().conversation(id), let f = s().dock.frame(of: id) else { return [:] }
            c.redEvents += 1; self.store.changed(c)
            s().pointer(CGPoint(x: f.midX, y: f.midY)); s().pointer(nil)
            return ["redSeen": c.redSeen, "redEvents": c.redEvents] })
        // B11: an editor with the keyboard keeps the dock up.
        after(7.0, "B11 editing", { s().dock.editing = true; return ["editing": s().dock.editing] })
        after(7.8, "B11 rise", { let r = s().dock.meFrame?.minY ?? 0; s().dock.editing = false; return ["meTop": r, "rest": s().dock.meRest.minY] })
        // B01, B02, B19: Collapse's header writes back, follows the store; an offline device stops the first send.
        after(8.6, "collapse", { w().command(.collapse, tag: 0); return [:] })
        after(9.8, "B01 rename", {
            guard let strip = w().strip, let c = s().conversation(strip.shown) else { return [:] }
            strip.testIsland.actions.rename?("Renamed in Collapse")
            return ["title": c.title] })
        after(10.2, "B02 satellites", {
            guard let strip = w().strip, let c = s().conversation(strip.shown) else { return [:] }
            c.satellites.append(Satellite(id: "audit-sat", face: "AU")); self.store.changed(c)
            return ["rows": strip.testAgentCount] })
        after(10.6, "B19 offline", {
            guard let strip = w().strip else { return [:] }
            let device = self.store.devices.first { !$0.online }
            strip.newChatContext = NormieNewChatContext(projectID: nil, deviceID: device?.id ?? "mac")
            strip.beginNewChat()
            let online = device.map { self.store.device($0.id)?.online ?? true } ?? true
            s().composers.draft().composer.setText("offline audit"); s().composers.draft().composer.submit()
            return ["device": device?.id ?? "-", "online": online, "drafting": strip.isDrafting, "members": strip.members.count] })
        after(11.0, "restore", { w().command(.restore, tag: 0); return [:] })
        after(12.0, "AP02 inspector", { self.shell.setMode(.normie, animated: false); w().workbench.requestInspector(shown: true)
            return ["shown": w().shell.inspectorShown, "workbench": w().workbench.inspectorVisible] })
        after(12.6, "AP02 again", { w().workbench.requestInspector(shown: true); return ["shown": w().shell.inspectorShown] })
        after(13.0, "end", { [:] })
    }

    func demoHover() {
        let y = scene.size.height - 40, start = CACurrentMediaTime()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = CACurrentMediaTime() - start
                if t < 3 {
                    let x = self.scene.size.width * CGFloat(0.55 + 0.45 * t / 3)
                    self.scene.pointer(CGPoint(x: x, y: y))
                } else if t < 3.05 { self.scene.pointer(CGPoint(x: 600, y: 300)) }
                if Int(t * 60) % 6 == 0 {
                    self.hoverLog.append(["t": t, "frames": self.scene.dockFrames.map { [$0.minX, $0.minY, $0.width] }])
                }
                if t > 4 { self.hoverTimer?.invalidate(); self.hoverTimer = nil }
            }
        }
    }

    /// Types into the full composer, sends, switches away and back, and leaves a draft in a brief bar, logging every
    /// composer's state at each step. Text goes in through the editor's own input path (insertText), not setText.
    func demoCompose() {
        func log(_ step: String) {
            var row: [String: Any] = ["t": CACurrentMediaTime(), "step": step, "full": scene.fullIndex,
                                      "firstResponder": String(describing: type(of: window.firstResponder as Any))]
            for column in scene.columns {
                let c = column.conversation
                guard let composer = scene.composers.existingComposer(for: c.id) else { continue }
                row[c.id] = ["text": composer.text, "draft": c.draft, "hidden": composer.isHidden, "alpha": composer.alphaValue,
                             "frame": NSStringFromRect(composer.convert(composer.bounds, to: nil)), "focused": window.firstResponder === composer.textView,
                             "items": c.items.count]
            }
            composeLog.append(row)
        }
        func composer(_ i: Int) -> NativeComposer? { scene.composers.existingComposer(for: scene.columns[i].conversation.id) }
        let steps: [(Double, String, () -> Void)] = [
            (1.0, "focus and type in A", { composer(0)?.focus(); composer(0)?.textView.insertText("Tighten the dock spacing", replacementRange: NSRange(location: NSNotFound, length: 0)) }),
            (2.0, "send A", { _ = composer(0)?.submit() }),
            (3.0, "switch to B", { self.scene.switchTo(1, reason: "demo-compose") }),
            (4.5, "type a draft in B", { composer(1)?.focus(); composer(1)?.textView.insertText("Draft for B\nsecond line", replacementRange: NSRange(location: NSNotFound, length: 0)) }),
            (5.5, "switch to A", { self.scene.switchTo(0, reason: "demo-compose") }),
            (7.0, "rest", {}),
        ]
        // A second's lead, so a recorder started after launch catches the first step.
        for (t, step, run) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + t) { MainActor.assumeIsolated { run(); log(step) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + t + 0.9) { MainActor.assumeIsolated { log(step + " +0.9 s") } }
        }
    }

    /// Long-history check: once the visible transcript holds a long history, it steps through fixed offsets 1.5 s apart.
    func demoScrollProbe() {
        let offsets: [CGFloat] = [0, 4000, 8000, 12000, 16000, 20000, 32000, 48000, 64000, .greatestFiniteMagnitude]
        func find(_ v: NSView) -> NativeTranscript? {
            if let t = v as? NativeTranscript, !t.isHiddenOrHasHiddenAncestor { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        func step(_ i: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                guard let t = self.windows.first?.window.contentView.flatMap(find), t.contentHeight > 10000 else { step(i); return }
                guard i < offsets.count else { return }
                t.scrollOffset = CGPoint(x: 0, y: offsets[i])
                self.composeLog.append(["t": CACurrentMediaTime(), "step": "scroll \(i)", "offset": t.scrollOffset.y, "content": t.contentHeight])
                step(i + 1)
            }
        }
        step(0)
    }
    /// Live Tools delivery, local only (nothing is sent): Attach into the shown conversation's editor, then the same editor
    /// put back as it was; a destination that is gone fails. Logged into composeLog.
    func demoDeliver() {
        func attempt(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let id = self.main.scene.current
                guard self.live?.isConnected == true, let c = self.store.conversation(id), c.historyLoaded,
                      let composer = self.main.scene.composers.existingComposer(for: id) else { if tries > 0 { attempt(tries - 1) }; return }
                let text = composer.text, attachments = composer.attachments
                let file = Attachment(id: "demo-deliver-1", name: "deliver-check.png", symbol: "photo")
                self.deliver(CoreArtifactDelivery(destinationID: id, attachments: [file, file], send: false)) { result in
                    self.composeLog.append(["step": "attach", "result": String(describing: result), "attachments": composer.attachments.map(\.id),
                                            "conversation": c.attachments.map(\.id), "textKept": composer.text == text])
                    composer.attachments = attachments; c.attachments = attachments; composer.setText(text); self.store.changed(c)
                    self.composeLog.append(["step": "restored", "attachments": composer.attachments.map(\.id), "textKept": composer.text == text])
                }
                self.deliver(CoreArtifactDelivery(destinationID: "no-such-conversation", attachments: [file], send: true)) { result in
                    self.composeLog.append(["step": "gone", "result": String(describing: result)])
                }
            }
        }
        attempt(40)
    }
    /// Live terminal through SwiftTerm: once the shown chat is read, ⌘J, an explicit Open (the user's login shell in the
    /// Core's PTY), one harmless echo, then End session so no shell is left behind. Logged into composeLog.
    func demoLiveTerminal() {
        func at(_ t: Double, _ step: String, _ run: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in run(); self?.composeLog.append(["t": CACurrentMediaTime(), "step": step]) }
        }
        func wait(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let id = self.main.scene.current
                guard self.live?.isConnected == true, let c = self.store.conversation(id), c.historyLoaded else { if tries > 0 { wait(tries - 1) }; return }
                let pane = self.main.workbench.detail.terminalPane
                at(0.5, "show terminal") {
                    // In front without activating (no key focus taken), so the recording sees SwiftTerm draw.
                    self.main.window.orderFrontRegardless()
                    self.main.workbench.setTerminalShown(true)
                }
                at(1.5, "open") { pane.openLiveTerminal() }
                at(5, "echo") { self.liveTerminals.active(for: id)?.send("echo organic-$((6*7))\r") }
                at(8, "output") {
                    let session = self.liveTerminals.active(for: id)
                    self.composeLog.append(["step": "session", "running": session?.running ?? false, "error": session?.error ?? "",
                                            "tail": String((session?.output ?? "").suffix(300)), "sessions": self.liveTerminals.sessions(for: id).count])
                    // What the terminal view itself parsed, and whether the window was visible (SwiftTerm, like the
                    // product, stops drawing while the window is fully covered).
                    func find(_ v: NSView) -> NSView? {
                        if String(describing: type(of: v)) == "ToolsSwiftTermView", !v.isHiddenOrHasHiddenAncestor { return v }
                        for s in v.subviews { if let t = find(s) { return t } }
                        return nil
                    }
                    let window = self.main.window
                    if let view = window.contentView.flatMap(find) {
                        let text = (view.accessibilityValue() as? String) ?? ""
                        self.composeLog.append(["step": "terminal view", "visible": window.occlusionState.contains(.visible),
                                                "size": NSStringFromSize(view.bounds.size),
                                                "buffer": String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))])
                    } else { self.composeLog.append(["step": "terminal view", "found": false]) }
                }
                at(9, "end session") { if let s = self.liveTerminals.active(for: id) { Task { await s.close() } } }
                at(11, "hide terminal") {
                    self.composeLog.append(["step": "after close", "running": self.liveTerminals.active(for: id)?.running ?? false])
                    self.main.workbench.setTerminalShown(false)
                }
            }
        }
        wait(60)
    }
    /// The first orb lands in the last brief slot, the one it displaced lands back, then the landed one goes full and
    /// back: the dock's glass changes between orb and bar under real system glass (driver A), logged per step.
    func demoLand() {
        var landed = "", displaced = ""
        let steps: [(Double, String, () -> Void)] = [
            (1.0, "land first orb", {
                let n = self.scene.columns.count
                guard self.scene.order.count > n else { return }
                landed = self.scene.order[n]
                displaced = self.scene.columns.last { $0.conversation.id != self.scene.current }?.conversation.id ?? ""
                self.scene.land(landed, reason: "demo-land")
            }),
            (2.5, "make it full", { self.scene.activate(landed, reason: "demo-land") }),
            (4.0, "back to the first", { self.scene.switchTo(0, reason: "demo-land") }),
            (5.5, "land the displaced back", { self.scene.land(displaced, reason: "demo-land") }),
            (7.0, "rest", {}),
        ]
        for (t, step, run) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + t) { MainActor.assumeIsolated {
                run(); self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "columns": self.scene.columnState, "dock": self.scene.dockFrames.map(NSStringFromRect)])
            } }
        }
    }

    /// Queue drags with a synthetic pointer, through the same press / drag / release calls a mouse makes: the first
    /// orb held (long press) and carried left of the first bar; then the first bar by its grip carried to the right end;
    /// then an orb carried and cancelled (Escape). Logs the working set and the dock after each.
    /// M10.4: the orb at the top of a column dragged like a Dock orb. Long press and carry the full column's orb across
    /// the columns; press the current brief's (7.9 then 8 pt) and carry it left; carry the full one out to the Dock's
    /// overflow; carry one and Esc; a short press opens Customize. Headers are looked up anew for each leg.
    func demoDragHeader() {
        M104HeaderOrbDragging.install(in: scene) // idempotent; for scenes the window has not wired yet
        let drag = { self.scene.dock.headerOrbDragging }
        func island(full: Bool) -> HeaderIsland? {
            let all = self.scene.columns.compactMap(\.island)
            return all.first { ($0.configuration?.id == self.scene.current) == full && $0.canDragOrb } ?? all.first { $0.canDragOrb }
        }
        func point(_ i: HeaderIsland) -> CGPoint {
            let r = self.scene.dock.view.convert(i.draggableOrbRect, from: i); return CGPoint(x: r.midX, y: r.midY)
        }
        func at(_ t: Double, _ run: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { run() } }
        }
        func carry(from t0: Double, seconds: Double, to b: @escaping () -> CGPoint) {
            var a = CGPoint.zero
            let steps = Int(seconds * 120)
            at(t0) { a = self.lastHeaderDragPoint }
            for k in 1...steps {
                let f = Double(k) / Double(steps), e = f * f * (3 - 2 * f)
                at(t0 + seconds * f) {
                    let target = b()
                    let p = CGPoint(x: a.x + (target.x - a.x) * e, y: a.y + (target.y - a.y) * e)
                    self.lastHeaderDragPoint = p; drag()?.move(to: p)
                }
            }
        }
        func press(_ t: Double, full: Bool) {
            at(t) { self.scene.setAmbientRunning(true) // a press from a real pointer has already woken it
                guard let i = island(full: full) else { return }
                let p = point(i); self.lastHeaderDragPoint = p; _ = drag()?.begin(from: i, at: p) }
        }
        func nudge(_ t: Double, _ dx: CGFloat) {
            at(t) { self.lastHeaderDragPoint.x += dx; drag()?.move(to: self.lastHeaderDragPoint) }
        }
        func drop(_ t: Double) { at(t) { _ = drag()?.end(at: self.lastHeaderDragPoint) } }
        let size = scene.dock.view.bounds.size
        press(1.5, full: true); carry(from: 1.8, seconds: 0.8) { CGPoint(x: size.width - 120, y: self.lastHeaderDragPoint.y) }; drop(3.0)
        press(4.8, full: false); nudge(5.1, -7.9); nudge(5.15, -0.1); carry(from: 5.2, seconds: 0.7) { CGPoint(x: 70, y: self.lastHeaderDragPoint.y) }; drop(6.1)
        press(7.6, full: true); carry(from: 7.9, seconds: 0.8) {
            let d = self.scene.dockFrames.last ?? CGRect(x: size.width - 40, y: size.height - 40, width: 0, height: 0)
            return CGPoint(x: d.midX, y: d.midY) }; drop(8.9)
        press(10.5, full: true); carry(from: 10.8, seconds: 0.7) { CGPoint(x: size.width / 2, y: self.lastHeaderDragPoint.y) }
        at(11.7) { drag()?.cancel() }
        press(13.2, full: true); drop(13.3)
    }
    var lastHeaderDragPoint: CGPoint { get { Self.headerDragPoint } set { Self.headerDragPoint = newValue } }
    func demoDrag() {
        var t = 1.0
        func at(_ dt: Double, _ step: String, _ run: @escaping () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                run(); self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "columns": self.scene.columnState,
                                               "order": self.scene.order, "dock": self.scene.dockFrames.map(NSStringFromRect)])
            } }
        }
        func carry(from a: CGPoint, to b: CGPoint, over seconds: Double, label: String) {
            let steps = Int(seconds * 60)
            for k in 1...steps {
                let f = Double(k) / Double(steps), e = f * f * (3 - 2 * f)
                let p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
                at(1 / 60, k == steps ? label : "", { self.scene.pointerDragged(p) })
            }
        }
        let firstOrb = scene.dockFrames.dropFirst().first.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        let row = firstOrb.y
        at(0, "press first orb", { _ = self.scene.pointerDown(firstOrb) })
        at(0.4, "held (long press)", {})
        carry(from: firstOrb, to: CGPoint(x: 60, y: row - 6), over: 1.2, label: "carried left")
        at(0.3, "drop", { _ = self.scene.pointerUp(CGPoint(x: 60, y: row - 6)) })
        at(1.2, "press first bar's grip", {
            let bar = self.scene.barFrames.first ?? .zero
            _ = self.scene.pointerDown(CGPoint(x: bar.midX, y: bar.minY + 2))
        })
        at(0.05, "move 10 pt", { let bar = self.scene.barFrames.first ?? .zero; self.scene.pointerDragged(CGPoint(x: bar.midX + 10, y: bar.minY + 2)) })
        let startBar = scene.barFrames.first ?? .zero
        carry(from: CGPoint(x: startBar.midX + 10, y: row), to: CGPoint(x: 1250, y: row + 4), over: 1.4, label: "carried right")
        at(0.3, "drop", { _ = self.scene.pointerUp(CGPoint(x: 1250, y: row + 4)) })
        at(1.2, "press an orb", { let o = self.scene.dockFrames.dropFirst().first ?? .zero; _ = self.scene.pointerDown(CGPoint(x: o.midX, y: o.midY)) })
        at(0.4, "held", {})
        carry(from: firstOrb, to: CGPoint(x: 500, y: row), over: 0.8, label: "carried")
        at(0.3, "escape", { self.scene.cancelDrag() })
        at(1.2, "rest", {})
    }

    /// The window narrowed from its width to 760 pt as by dragging its right edge (live), the drag ended, then widened
    /// back the same way, then a switch: everything lies out again at each step, and moves as before afterwards.
    func demoResize() {
        let start = window.frame
        func sweep(from a: CGFloat, to b: CGFloat, at t0: Double) {
            let steps = 45
            for k in 0...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t0 + Double(k) / 30) { MainActor.assumeIsolated {
                    self.main.resizingLive = k < steps
                    var f = start; f.size.width = a + (b - a) * CGFloat(k) / CGFloat(steps)
                    self.window.setFrame(f, display: true)
                    if k == steps { self.main.resizingLive = false; self.main.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification)) }
                } }
            }
        }
        sweep(from: start.width, to: 760, at: 1.5)
        sweep(from: 760, to: start.width, at: 4.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { MainActor.assumeIsolated { self.scene.switchTo(1, reason: "demo-resize") } }
    }

    /// The full composer's model picker opened at its model button, stepped through with the arrow keys and closed;
    /// then Send's Queue / Steer options opened over Send and closed.
    func demoOverlays() {
        // DEMO_NORMIE=1: the same in Normie, through its composer's binding.
        let normie = ProcessInfo.processInfo.environment["DEMO_NORMIE"] == "1"
        if normie { shell.setMode(.normie, animated: false) }
        // DEMO_CORE_MODELS=<model/list result file>: the catalog as a live Core reports it, the shown chat on its default.
        if let path = ProcessInfo.processInfo.environment["DEMO_CORE_MODELS"], let data = FileManager.default.contents(atPath: path),
           let list = try? JSONDecoder().decode(JSONValue.self, from: data) {
            let values = list["result"]?["data"]?.arrayValue ?? []
            ModelCatalog.models = ModelCatalog.coreModels(values)
            let preferred = values.first { $0["isDefault"]?.boolValue == true }?["id"]?.stringValue ?? ModelCatalog.models.first?.id ?? ""
            for c in store.conversations {
                var next = c.next; next.modelID = preferred; next.effort = ModelCatalog.defaultEffort(ModelCatalog.model(preferred)); c.next = next; c.settings = next
                store.changed(c)
            }
        }
        func binding() -> (OverlayComposerBinding, NativeComposer)? {
            if normie { return main.normieComposerBinding.flatMap { b in scene.composers.existingComposer(for: scene.current).map { (b, $0) } } }
            guard let b = scene.overlay(for: scene.current), let c = scene.composers.existingComposer(for: scene.current) else { return nil }
            return (b, c)
        }
        func anchor(_ view: NSView) -> CGRect { scene.overlayPlane.convert(view.bounds, from: view) }
        let steps: [(Double, String, () -> Void)] = [
            // What a click on the model button does: configured from the editor's settings, then presented.
            (1.5, "open model picker", { _ = binding()?.0.presentModelPicker() }),
            (2.6, "down", { _ = binding()?.0.modelPicker.handleKey(.down) }),
            (3.2, "down", { _ = binding()?.0.modelPicker.handleKey(.down) }),
            (4.0, "close picker", { binding()?.0.modelPicker.dismiss() }),
            (5.0, "open send options", { if let (b, c) = binding() { b.sendOptions.present(anchor: anchor(c.sendButton), in: self.scene.overlayPlane) } }),
            (6.5, "close send options", { binding()?.0.sendOptions.dismiss() }),
            (7.5, "rest", {}),
        ]
        for (t, step, run) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + t) { MainActor.assumeIsolated { run(); self.composeLog.append(["t": CACurrentMediaTime(), "step": step]) } }
        }
    }

    /// Peek with a synthetic pointer, through the same hover and click calls a mouse makes: rest on the first orb (it
    /// opens), move up into its halo (it stays), leave (it closes); rest on the second orb, slide to the third (it moves
    /// over), then click its capsule (it lands). Logs the peek state every 50 ms.
    func demoPeek() {
        scene.pressedButtons = { 0 }
        var t = 1.0, last = CGPoint(x: 600, y: 300)
        func at(_ dt: Double, _ step: String, _ run: @escaping () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                run(); if !step.isEmpty { self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "peek": self.scene.peekState, "order": self.scene.order]) }
            } }
        }
        func glide(to target: @escaping () -> CGPoint, over seconds: Double, label: String) {
            let steps = Int(seconds * 60)
            var from = CGPoint.zero, q = CGPoint.zero
            at(0, "", { from = last; q = target() })
            for k in 1...steps {
                let f = Double(k) / Double(steps), e = f * f * (3 - 2 * f)
                at(1 / 60, k == steps ? label : "", {
                    let p = CGPoint(x: from.x + (q.x - from.x) * e, y: from.y + (q.y - from.y) * e)
                    last = p; self.hover(p)
                })
            }
        }
        func orb(_ k: Int) -> () -> CGPoint { { let o = self.scene.dockFrames.dropFirst(k + 1).first ?? .zero; return CGPoint(x: o.midX, y: o.midY) } }
        at(0, "start", { self.hover(last) })
        glide(to: orb(0), over: 0.5, label: "on the first orb")
        at(1.2, "open", {})
        glide(to: { CGPoint(x: last.x, y: last.y - 160) }, over: 0.4, label: "up into the halo")
        at(1.0, "still open", {})
        glide(to: { CGPoint(x: 300, y: 300) }, over: 0.4, label: "away")
        at(1.0, "closed", {})
        glide(to: orb(1), over: 0.5, label: "on the second orb")
        at(1.0, "open", {})
        glide(to: orb(2), over: 0.25, label: "on the third orb")
        at(1.0, "moved over", {})
        var capsule = CGPoint.zero
        at(0, "", { if let r = self.scene.peekCapsuleFrame { capsule = CGPoint(x: r.midX, y: r.midY) } })
        glide(to: { capsule }, over: 0.3, label: "on its capsule")
        at(0.4, "click", {
            let pressed = self.scene.pointerDown(capsule)
            if !pressed { self.click(capsule) } else if self.scene.pointerUp(capsule) == false { self.click(capsule) }
        })
        at(1.5, "rest", {})
        for k in 0..<240 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(k) * 0.05) { MainActor.assumeIsolated {
                self.composeLog.append(["t": CACurrentMediaTime(), "peek": self.scene.peekState])
            } }
        }
    }

    /// Normie and back, twice: the second time Normie has selected another conversation, which Organic then shows full.
    func demoMode() {
        func trigger(_ target: WindowShell.Mode) {
            if o.demoModeKey {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                            timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber,
                                            context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)
                if let event { NSApp.sendEvent(event) }
                else { composeLog.append(["step": "demo-mode-key event creation failed"]) }
            } else if o.demoModeMenu {
                // Account menu's .sidebar item uses the same builder/action/command as the human's me menu.
                // In Normie its account menu omits .sidebar, so use the main menu's corresponding item on the return.
                func find(_ menu: NSMenu) -> (NSMenu, Int)? {
                    for (i, item) in menu.items.enumerated() {
                        if item.representedObject as? String == NormieCommand.sidebar.rawValue { return (menu, i) }
                        if let sub = item.submenu, let found = find(sub) { return found }
                    }
                    return nil
                }
                let menu = shell.mode == .organic
                    ? workbench.menus.makeAccountMenu(account: workbench.account, quotaSummary: store.quotaMenuSummary, organic: true)
                    : NSApp.mainMenu
                if let menu, let (owner, index) = find(menu) {
                    ModeSignposts.withInput("demo.menu.performAction", useCurrentEvent: false) { owner.performActionForItem(at: index) }
                }
                else { composeLog.append(["step": "demo-mode-menu sidebar item missing"]) }
            } else { shell.setMode(target) }
        }
        // DEMO_FOLD_PROJECTS=1: every project folded first, so its members have no visible row (f029).
        if ProcessInfo.processInfo.environment["DEMO_FOLD_PROJECTS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated {
                for p in self.store.projects { self.workbench.sidebarModel.toggleProject(p.id) }
            } }
        }
        // DEMO_MODE_LEAD=<s>: sit in Organic that long first, so the first switch can use the prewarm a person's would.
        let lead = Double(ProcessInfo.processInfo.environment["DEMO_MODE_LEAD"] ?? "") ?? 0
        let steps: [(Double, String, () -> Void)] = [
            (lead + 1.5, "to normie", { trigger(.normie) }),
            (lead + 3.0, "select another", { if let other = self.store.conversations.dropFirst(2).first { _ = self.workbench.select(other.id) } }),
            (lead + 4.5, "to organic", { trigger(.organic) }),
            (lead + 6.5, "rest", {}),
        ]
        for (t, step, run) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                run(); self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "mode": "\(self.shell.mode)", "current": self.scene.current,
                                               "order": self.scene.order, "columns": self.scene.columnState])
            } }
        }
    }

    /// Split A | B, me carried onto the divider (asked), confirmed, then A sends: B gets the same message (f043).
    func demoCompare() {
        UserDefaults.standard.set(false, forKey: "compare.neverAsk")
        var t = 1.0
        func at(_ dt: Double, _ step: String, _ run: @escaping () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                run()
                let counts = self.store.conversations.prefix(3).map { "\($0.id):\($0.items.count)" }.joined(separator: " ")
                if !step.isEmpty { self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "asking": self.scene.isAskingCompare, "comparing": self.scene.isComparing, "items": counts]) }
            } }
        }
        var meStart = CGPoint.zero, target = CGPoint.zero
        at(0, "focused", { self.scene.enterFocused(self.scene.current, reason: "demo") })
        at(1.0, "split", { if let b = self.scene.order.dropFirst().first { self.scene.graft(b, at: 1, reason: "demo") } })
        at(1.2, "press me", {
            let me = self.scene.dockFrames.first ?? .zero
            meStart = CGPoint(x: me.midX, y: me.midY)
            let bars = self.scene.barFrames
            if bars.count > 1 { target = CGPoint(x: (bars[0].maxX + bars[1].minX) / 2, y: bars[0].midY) }
            _ = self.scene.pointerDown(meStart)
        })
        for k in 1...48 {
            at(1 / 60, k == 48 ? "on the divider" : "", { let f = Double(k) / 48, e = f * f * (3 - 2 * f)
                self.scene.pointerDragged(CGPoint(x: meStart.x + (target.x - meStart.x) * e, y: meStart.y + (target.y - meStart.y) * e)) })
        }
        at(0.2, "drop", { _ = self.scene.pointerUp(target) })
        at(1.2, "confirm", { self.scene.confirmCompare() })
        at(1.0, "send from A", {
            guard let a = self.scene.columnState.first.flatMap({ $0["id"] as? String }), let composer = self.scene.composers.existingComposer(for: a) else { return }
            composer.setText("Compare: which is faster?"); composer.submit()
        })
        at(1.5, "rest", {})
    }

    /// Tear with a synthetic pointer: the first orb pulled up off the dock (it tears), carried left onto the desktop and
    /// dropped (a window grows); then the next orb carried onto that window and dropped (it merges).
    func demoTear() {
        var t = 1.0
        func at(_ dt: Double, _ step: String, _ run: @escaping () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                run()
                if !step.isEmpty {
                    self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "tearing": self.scene.isTearing,
                                            "windows": self.windows.map { $0.scene.members.map(\.id).joined(separator: ",") }])
                }
            } }
        }
        var from = CGPoint.zero, last = CGPoint.zero
        func carry(to target: @escaping () -> CGPoint, over seconds: Double, label: String) {
            var a = CGPoint.zero, b = CGPoint.zero
            at(0, "", { a = last; b = target() })
            let slow = Double(ProcessInfo.processInfo.environment["DEMO_SLOW"] ?? "") ?? 1
            let steps = Int(seconds * slow * 60)
            for k in 1...steps {
                at(1 / 60, k == steps ? label : "", { let f = Double(k) / Double(steps), e = f * f * (3 - 2 * f)
                    last = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e); self.scene.pointerDragged(last) })
            }
        }
        func pick(_ label: String) {
            at(0, label, { let o = self.scene.dockFrames.dropFirst().first ?? .zero; from = CGPoint(x: o.midX, y: o.midY); last = from; _ = self.scene.pointerDown(from) })
            at(0.35, "", {})
        }
        pick("press first orb")
        carry(to: { CGPoint(x: from.x, y: from.y - 160) }, over: 0.4, label: "pulled up")
        carry(to: { CGPoint(x: -260, y: from.y - 260) }, over: 0.7, label: "over the desktop")
        at(0.2, "drop on desktop", { _ = self.scene.pointerUp(last) })
        at(1.6, "", {})
        pick("press next orb")
        carry(to: { CGPoint(x: from.x, y: from.y - 160) }, over: 0.4, label: "pulled up")
        carry(to: {
            guard let w2 = self.windows.last, w2 !== self.main else { return last }
            let c = CGPoint(x: w2.window.frame.midX, y: w2.window.frame.midY)
            return self.main.root.convert(self.main.window.convertPoint(fromScreen: c), from: nil)
        }, over: 0.7, label: "over the new window")
        at(0.2, "drop on it", { _ = self.scene.pointerUp(last) })
        at(1.5, "rest", {})
    }

    /// me carried onto the second bar and dropped: Focused on it; then carried up out of the capsule: Auto again.
    func demoMe() {
        var t = 1.0
        func at(_ dt: Double, _ step: String, _ run: @escaping () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                run(); if !step.isEmpty { self.composeLog.append(["t": CACurrentMediaTime(), "step": step, "focused": self.scene.isFocused, "order": self.scene.order]) }
            } }
        }
        func carry(_ a: @escaping () -> CGPoint, _ b: @escaping () -> CGPoint, over seconds: Double, label: String) {
            let steps = Int(seconds * 60)
            for k in 1...steps {
                let f = Double(k) / Double(steps), e = f * f * (3 - 2 * f)
                at(1 / 60, k == steps ? label : "", { let p = a(), q = b(); self.scene.pointerDragged(CGPoint(x: p.x + (q.x - p.x) * e, y: p.y + (q.y - p.y) * e)) })
            }
        }
        var meStart = CGPoint.zero, target = CGPoint.zero
        at(0, "press me", {
            let me = self.scene.dockFrames.first ?? .zero
            meStart = CGPoint(x: me.midX, y: me.midY)
            let bar = self.scene.barFrames.dropFirst().first ?? .zero
            target = CGPoint(x: bar.midX, y: bar.midY)
            _ = self.scene.pointerDown(meStart)
        })
        carry({ meStart }, { target }, over: 1.0, label: "carried onto the second bar")
        at(0.2, "drop", { _ = self.scene.pointerUp(target) })
        at(1.6, "press me in the capsule", { let me = self.scene.dockFrames.first ?? .zero; meStart = CGPoint(x: me.midX, y: me.midY); _ = self.scene.pointerDown(meStart) })
        carry({ meStart }, { CGPoint(x: meStart.x + 40, y: meStart.y - 160) }, over: 0.8, label: "carried up out")
        at(0.2, "drop", { _ = self.scene.pointerUp(CGPoint(x: meStart.x + 40, y: meStart.y - 160)) })
        at(1.6, "rest", {})
    }

    func toggleDemo() {
        if let t = demoTimer { t.invalidate(); demoTimer = nil; return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: o.demoInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scene.columns.count > 1 else { return }
                self.scene.switchTo((self.scene.fullIndex + 1) % self.scene.columns.count, reason: "demo")
            }
        }
    }
}
