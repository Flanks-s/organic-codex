import AppKit

/// User-approved acceptance runs against the live Core (USER-ACCEPTANCE-26102917, group three; approved 10-29): each
/// case drives the window's own paths in the throwaway test conversation (LIVE_TEST_THREAD, its workspace the throwaway
/// repository) or a temporary directory, logs into the receipt's composeLog, and quits when done. ACCEPT_CASE picks the
/// case. With --live-core.
extension AppController {
    func demoAcceptance() {
        let name = ProcessInfo.processInfo.environment["ACCEPT_CASE"] ?? ""
        let run = AcceptanceRun(app: self, name: name)
        run.start()
    }
}

@MainActor final class AcceptanceRun {
    let app: AppController
    let name: String
    private(set) var test: Conversation?
    private static var current: AcceptanceRun?
    init(app: AppController, name: String) { self.app = app; self.name = name }

    func log(_ step: String, _ extra: [String: Any] = [:]) {
        var e = extra; e["step"] = step; e["t"] = CACurrentMediaTime()
        if let c = test { e["running"] = c.running; e["error"] = c.operationError ?? ""; e["items"] = c.items.count }
        app.composeLog.append(e)
    }
    /// Polls every 0.5 s until `ready` or `timeout` seconds.
    func wait(_ timeout: Double, _ ready: @escaping () -> Bool, _ then: @escaping (Bool) -> Void) {
        let start = CACurrentMediaTime()
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if ready() { then(true) } else if CACurrentMediaTime() - start > timeout { then(false) } else { poll() }
            }
        }
        poll()
    }
    func finish() { log("done"); Self.current = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) } }
    var turnOver: Bool { guard let c = test else { return true }; return !c.running && !c.sending }
    func tail(_ n: Int = 4) -> [String] { (test?.items.suffix(n) ?? []).map { "\($0.rowKind) [\($0.status ?? "-")] " + String($0.text.prefix(100)) } }

    func start() {
        Self.current = self
        log("acceptance", ["case": name])
        wait(90, { [app] in app.live?.isConnected == true && !app.store.conversations.isEmpty }) { [self] ok in
            guard ok else { log("not connected"); finish(); return }
            let thread = ProcessInfo.processInfo.environment["LIVE_TEST_THREAD"]
            guard let c = app.store.conversations.first(where: { $0.backendThreadID != nil && $0.backendThreadID == thread }) else {
                log("no test conversation", ["thread": thread ?? ""]); finish(); return
            }
            test = c
            app.main.reveal(c.id)
            wait(60, { c.historyLoaded && !c.loading && !c.gitBusy }) { [self] _ in
                switch name {
                case "artifacts": artifacts(c)
                case "send-artifact": sendExisting(c)
                case "skills": skills()
                case "computer": computer(c)
                case "computer-revoke": computerRevoke(c)
                case "capture": capture(c)
                case "appshots": appshots(c)
                case "hotkey-on": hotkey(c, on: true)
                case "hotkey-off": hotkey(c, on: false)
                case "browser": browser(c)
                case "changes": changes(c)
                case "terminal": terminal(c)
                case "terminal-reopen": terminalReopen(c)
                case "reconnect": reconnect(c)
                default: log("unknown case"); finish()
                }
            }
        }
    }

    /// The editor's own send path, as a click on Send does.
    func send(_ text: String, in c: Conversation, access: Access = .auto) -> Bool {
        let k = app.scene.composer(for: c); k.setAccess(access); k.setText(text)
        return k.submit()
    }

    // MARK: f147 — Install skill folder from a temporary directory, disable and enable it; the run removes what it added.

    private func skills() {
        guard let settings = app.settings else { log("f147 no settings window"); finish(); return }
        let manager = FileManager.default, tag = "organic-accept-" + UUID().uuidString.prefix(8).lowercased()
        let temp = manager.temporaryDirectory.appending(path: tag, directoryHint: .isDirectory)
        let missing = temp.appending(path: "no-skill-file", directoryHint: .isDirectory), valid = temp.appending(path: tag, directoryHint: .isDirectory)
        do {
            try manager.createDirectory(at: missing, withIntermediateDirectories: true)
            try "Not a skill.".write(to: missing.appending(path: "README.md"), atomically: true, encoding: .utf8)
            try manager.createDirectory(at: valid, withIntermediateDirectories: true)
            try "---\nname: \(tag)\ndescription: Temporary Organic Animation acceptance-test skill; removed right after the test.\n---\n\nDo not use this skill.\n"
                .write(to: valid.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        } catch { log("f147 temp folders", ["failure": "\(error)"]); finish(); return }
        settings.show(pane: "plugins/skills")
        let s = settings.session
        func skill() -> JSONValue? {
            s.records("skills").flatMap { $0["skills"]?.arrayValue ?? [] }.first { $0["name"]?.stringValue == tag }
        }
        func row() -> SettingsRow? { SettingsPanels.make(s).first { $0.kind == .toggle && $0.title == tag } }
        func config() -> Bool { (try? String(contentsOf: manager.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml"), encoding: .utf8))?.contains(tag) == true }
        Task { @MainActor [self] in
            for _ in 0..<200 where s.busy.contains("read:plugins/skills") { try? await Task.sleep(for: .milliseconds(50)) }
            await s.loadNow()
            let button = SettingsPanels.make(s).first { $0.id == "skills.install" }
            log("f147 pane", ["mode": "\(s.mode)", "installEnabled": button?.enabled ?? false, "configPath": s.configPath ?? "", "skills": s.records("skills").flatMap { $0["skills"]?.arrayValue ?? [] }.count])
            await s.installSkillFolder(missing).value
            log("f147 missing SKILL.md", ["writeError": s.errors["write"] ?? "", "installedAnything": skill() != nil])
            await s.installSkillFolder(valid).value
            let installed = skill(), path = installed?["path"]?.stringValue ?? ""
            log("f147 install", ["writeError": s.errors["write"] ?? "", "notice": s.notice ?? "", "path": path, "enabled": installed?["enabled"]?.boolValue ?? false,
                                 "onDisk": manager.fileExists(atPath: path), "row": row() != nil])
            await s.installSkillFolder(valid).value
            log("f147 same name again", ["writeError": s.errors["write"] ?? ""])
            // Disable through the row's toggle, as a click does; while the write runs the toggle is disabled.
            row()?.perform?(.bool(false))
            var busyDisabled: Bool?
            for _ in 0..<200 where !s.busy.contains("write") { await Task.yield() }
            if s.busy.contains("write") { busyDisabled = row()?.enabled == false }
            for _ in 0..<600 where s.busy.contains("write") { try? await Task.sleep(for: .milliseconds(50)) }
            log("f147 disable", ["writeError": s.errors["write"] ?? "", "rowDisabledWhileBusy": busyDisabled.map { "\($0)" } ?? "not observed",
                                 "enabled": skill()?["enabled"]?.boolValue ?? true, "inConfig": config()])
            row()?.perform?(.bool(true))
            for _ in 0..<200 where !s.busy.contains("write") { await Task.yield() }
            for _ in 0..<600 where s.busy.contains("write") { try? await Task.sleep(for: .milliseconds(50)) }
            log("f147 enable", ["writeError": s.errors["write"] ?? "", "enabled": skill()?["enabled"]?.boolValue ?? false, "inConfig": config()])
            // Clean up: only the folder this run installed (its unique name under the Core's skills folder) and the temp folders.
            if !path.isEmpty, path.contains("/.codex/skills/" + tag + "/") {
                try? manager.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
            try? manager.removeItem(at: temp)
            await s.loadNow()
            log("f147 cleanup", ["installedFolderGone": !manager.fileExists(atPath: path), "tempGone": !manager.fileExists(atPath: temp.path),
                                 "listed": skill() != nil, "inConfig": config(), "tag": tag])
            finish()
        }
    }

    // MARK: f149 — Computer Use: the test chat allows one app for the chat and declines another; after reopening, Revoke.

    private func grantList(_ s: SettingsSession) -> [JSONValue] { s.records("authorizations") }
    private func grantNames(_ s: SettingsSession) -> [String] {
        grantList(s).map { "\($0["app"]?.stringValue ?? "?")@\(($0["threadId"]?.stringValue ?? "").prefix(8)) \($0["id"]?.stringValue ?? "")" }
    }
    private func openComputerPane(_ then: @escaping (SettingsSession) -> Void) {
        guard let settings = app.settings else { log("f149 no settings window"); finish(); return }
        settings.show(pane: "computer")
        let s = settings.session
        Task { @MainActor [self] in
            for _ in 0..<200 where s.busy.contains("read:computer") { try? await Task.sleep(for: .milliseconds(50)) }
            await s.loadNow()
            log("f149 settings", ["capability": s.capabilities["nativeComputer"].map { $0.available ? "available" : ($0.reason ?? "unavailable") } ?? "not reported",
                                  "defaultAccess": s.config("computer_use.default_app_access")?.settingsText ?? "(unset)", "grants": grantNames(s)])
            then(s)
        }
    }

    private func computer(_ c: Conversation) {
        openComputerPane { [self] s in
            // A turn left running by an earlier run (its approvals come back from Core) is finished first, declining.
            log("f149 leftover", ["running": c.running, "approvals": c.approvals.map { $0.cuaApplicationForChatApproval ?? $0.method }])
            let leftover: (@escaping () -> Void) -> Void = { [self] next in
                guard c.running || !c.approvals.isEmpty else { next(); return }
                useApp("TextEdit", allow: false, in: c, prompt: nil, then: next)
            }
            leftover { [self] in
                useApp("Calculator", allow: true, in: c, prompt: "Use the organic_cua computer-use tool to look at the Calculator app (open it if it is not open) and tell me the number it shows. Do not change anything in it. Reply with just that number.") { [self] in
                    useApp("TextEdit", allow: false, in: c, prompt: "Use the organic_cua computer-use tool to look at the TextEdit app. If access is declined, do not try any other way; reply with the single word: declined.") { [self] in
                        Task { @MainActor [self] in
                            await s.loadNow()
                            let mine = grantList(s).filter { $0["threadId"]?.stringValue == c.backendThreadID }
                            log("f149 grants after", ["grants": grantNames(s),
                                                      "calculatorForTestChat": mine.contains { $0["app"]?.stringValue?.lowercased().contains("calculator") == true },
                                                      "textEditForTestChat": mine.contains { $0["app"]?.stringValue?.lowercased().contains("textedit") == true }])
                            finish()
                        }
                    }
                }
            }
        }
    }

    /// One turn that has the model use `target` through the computer-use tool (`prompt` nil: the turn already running).
    /// Every computer-use approval for `target` is answered as the card's buttons do (Allow for this chat, or Decline);
    /// any other approval is declined.
    private func useApp(_ target: String, allow: Bool, in c: Conversation, prompt: String?, then: @escaping () -> Void) {
        let base = c.items.count
        if let prompt { log("f149 \(target) send", ["submitted": send(prompt, in: c, access: .readOnly)]) }
        else { log("f149 \(target) running turn", ["approvals": c.approvals.count]) }
        var answered = 0
        func next() {
            wait(300, { [self] in c.approvals.contains { !$0.submitting } || (turnOver && (prompt == nil || c.items.count > base + 1)) }) { [self] _ in
                guard let a = c.approvals.first(where: { !$0.submitting }) else {
                    let tools = c.items.dropFirst(base).filter { "\($0.rowKind)".contains("tool") }.map { "\($0.rowKind) [\($0.status ?? "-")] " + String($0.text.prefix(90)) }
                    log("f149 \(target) turn over", ["answered": answered, "tools": tools, "tail": tail(2)]); then(); return
                }
                answered += 1
                let forTarget = a.cuaApplicationForChatApproval?.lowercased().contains(target.lowercased()) == true
                log("f149 \(target) approval \(answered)", ["title": a.title, "method": a.method, "source": a.source, "app": a.cuaApplicationForChatApproval ?? "",
                                                             "command": String(a.command.prefix(140)), "answer": forTarget && allow ? "allow for this chat" : "decline"])
                if forTarget, allow, let response = a.cuaChatApprovalResponse { app.main.actions.approvalValue?(c, a, response) }
                else { app.main.actions.approval?(c, a, .decline) }
                if answered >= 6 { log("f149 \(target) too many approvals; stopping the turn"); app.main.actions.stop?(c) }
                next()
            }
        }
        next()
    }

    /// Run after reopening: the grant from `computer` is listed; Revoke through the panel's row and its confirmation.
    private func computerRevoke(_ c: Conversation) {
        openComputerPane { [self] s in
            let before = grantList(s)
            guard let grant = before.first(where: { $0["threadId"]?.stringValue == c.backendThreadID && $0["app"]?.stringValue?.lowercased().contains("calculator") == true }),
                  let id = grant["id"]?.stringValue else { log("f149 no Calculator grant to revoke"); finish(); return }
            let row = SettingsPanels.make(s).first { $0.id == "revoke." + id }
            row?.perform?(.null)
            Task { @MainActor [self] in
                guard let pending = s.confirmation else { log("f149 revoke asked nothing", ["row": row != nil]); finish(); return }
                log("f149 revoke asks", ["title": pending.title, "message": pending.message, "confirm": pending.confirm])
                let done = await s.resolveConfirmation(id: pending.id, confirmed: true)
                await s.loadNow()
                let after = grantList(s).compactMap { $0["id"]?.stringValue }
                log("f149 revoke", ["ok": done, "writeError": s.errors["write"] ?? "", "gone": !after.contains(id),
                                    "othersUnchanged": after == before.compactMap { $0["id"]?.stringValue }.filter { $0 != id }, "grants": grantNames(s)])
                finish()
            }
        }
    }

    // MARK: f161 — Appshots to a draft: the permission is asked in the destination chat; while it waits another chat is in
    // front and Tools is reopened on another destination; once allowed the result lands in the original draft, once.

    private func draftShots(_ c: Conversation) -> [String] { app.scene.composer(for: c).attachments.map(\.name).filter { $0.hasPrefix("Appshot") } }
    private func clearShots(_ c: Conversation, keeping before: [String]) {
        let composer = app.scene.composer(for: c)
        composer.attachments.removeAll { !before.contains($0.id) }; c.attachments = composer.attachments; app.store.changed(c)
    }

    private func capture(_ c: Conversation) {
        let tools = app.liveArtifacts, composer = app.scene.composer(for: c), before = composer.attachments.map(\.id)
        guard let other = app.store.conversations.first(where: { $0.id != c.id && !$0.archived && $0.backendThreadID != nil }) else { log("f161 no other chat"); finish(); return }
        app.showTools(.capture, conversation: c.id)
        tools.captureMode = "window"; tools.captureApp = "Calculator"
        // Tools refreshes when shown; its Capture button waits for that, so does this.
        wait(30, { !tools.busy }) { [self] _ in
        tools.captureToDraft()
        log("f161 capture", ["busy": tools.busy, "summary": tools.captureSummary])
        wait(180, { c.approvals.contains { !$0.submitting } || !tools.hasPendingCapture }) { [self] _ in
            guard let a = c.approvals.first(where: { !$0.submitting }) else {
                log("f161 no permission asked", ["pending": tools.hasPendingCapture, "toolsError": tools.error ?? "", "summary": tools.captureSummary, "draft": draftShots(c)])
                clearShots(c, keeping: before); finish(); return
            }
            log("f161 asked in the test chat", ["app": a.cuaApplicationForChatApproval ?? "", "command": String(a.command.prefix(120)), "summary": tools.captureSummary])
            app.main.reveal(other.id)
            app.tools.window?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                app.showTools(.capture, conversation: other.id)
                log("f161 while waiting", ["pending": tools.hasPendingCapture, "destinationIsTestChat": tools.captureDestinationID == c.id,
                                           "pickerIsOther": tools.conversationID == other.id, "toolsShown": app.tools.isPresented, "summary": tools.captureSummary])
                // Allow once (no grant) from the test chat's cards: one capture asks for the app, then for its window state.
                var allowed = 0
                @MainActor func allowNext(_ a: Approval) {
                    allowed += 1
                    log("f161 allow once \(allowed)", ["app": a.cuaApplicationForChatApproval ?? "", "command": String(a.command.prefix(80))])
                    app.main.actions.approval?(c, a, .accept)
                    wait(240, { !tools.hasPendingCapture || c.approvals.contains { !$0.submitting && $0.id != a.id } }) { [self] _ in
                        if tools.hasPendingCapture, allowed < 4, let more = c.approvals.first(where: { !$0.submitting && $0.id != a.id }) { allowNext(more); return }
                        delivered()
                    }
                }
                @MainActor func delivered() {
                    log("f161 delivered", ["done": !tools.hasPendingCapture, "allowed": allowed, "testDraft": draftShots(c), "otherDraft": draftShots(other), "toolsError": tools.error ?? "", "summary": tools.captureSummary])
                    tools.recoverCaptures()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                        log("f161 after Recover", ["testDraft": draftShots(c), "pending": tools.hasPendingCapture])
                        clearShots(c, keeping: before)
                        log("f161 draft cleared", ["testDraft": draftShots(c)])
                        app.main.reveal(c.id); finish()
                    }
                }
                allowNext(a)
            }
        }
        }
    }

    // MARK: f150 — Appshots settings: no chat, no shortcut; enable for the test chat, switch mode, disable. Then a
    // full-display capture, which needs Screen Recording for Organic Capture: denied or not yet granted must not pass
    // as success.

    private func appshots(_ c: Conversation) {
        guard let settings = app.settings, let thread = c.backendThreadID else { log("f150 no settings or thread"); finish(); return }
        settings.show(pane: "appshots")
        let s = settings.session, tools = app.liveArtifacts
        func status() -> [String: Any] {
            let h = s.snapshots["hotkey"]
            return ["enabled": h?["enabled"]?.boolValue ?? false, "mode": h?["mode"]?.stringValue ?? "", "thread": String((h?["threadId"]?.stringValue ?? "").prefix(8)),
                    "status": h?["status"]?.settingsText ?? "", "shortcut": h?["shortcut"]?.settingsText ?? "", "hotkeyError": h?["error"]?.settingsText ?? "", "writeError": s.errors["write"] ?? ""]
        }
        func press(_ id: String) async {
            SettingsPanels.make(s).first { $0.id == id }?.perform?(.null)
            for _ in 0..<200 where !s.busy.contains("write") { await Task.yield() }
            for _ in 0..<300 where s.busy.contains("write") { try? await Task.sleep(for: .milliseconds(50)) }
        }
        Task { @MainActor [self] in
            for _ in 0..<200 where s.busy.contains("read:appshots") { try? await Task.sleep(for: .milliseconds(50)) }
            await s.loadNow()
            s.setDraft("capture.thread", ""); s.changed()
            log("f150 pane", ["status": status(), "captureScreen": s.capabilities["captureScreen"]?.available ?? false, "captureHotkey": s.capabilities["captureHotkey"]?.available ?? false,
                              "enableWithoutChat": SettingsPanels.make(s).first { $0.id == "capture.update" }?.enabled ?? false])
            s.setDraft("capture.thread", thread); s.setDraft("capture.mode", "window"); s.changed()
            await press("capture.update")
            log("f150 enabled (window)", ["status": status()])
            s.setDraft("capture.mode", "screen"); s.changed()
            await press("capture.update")
            log("f150 updated (screen)", ["status": status()])
            await press("capture.disable")
            log("f150 disabled", ["status": status(), "disableRowGone": !SettingsPanels.make(s).contains { $0.id == "capture.disable" }])
            // Full display through Tools.
            let before = app.scene.composer(for: c).attachments.map(\.id)
            app.showTools(.capture, conversation: c.id)
            tools.captureMode = "screen"; tools.captureApp = ""
            for _ in 0..<600 where tools.busy { try? await Task.sleep(for: .milliseconds(50)) }
            tools.captureToDraft()
            wait(120, { !tools.hasPendingCapture && !tools.busy }) { [self] done in
                log("f150 full display", ["done": done, "draft": draftShots(c), "toolsError": String((tools.error ?? "").prefix(400)), "summary": tools.captureSummary])
                clearShots(c, keeping: before)
                finish()
            }
        }
    }

    /// f150's real press: Settings ▸ Appshots enables the shortcut (full display, the test chat) and the app quits; the
    /// shortcut lives in Core, so it stays armed until `hotkey-off` disables it the same way.
    private func hotkey(_ c: Conversation, on: Bool) {
        guard let settings = app.settings, let thread = c.backendThreadID else { log("f150 no settings or thread"); finish(); return }
        settings.show(pane: "appshots")
        let s = settings.session
        Task { @MainActor [self] in
            for _ in 0..<200 where s.busy.contains("read:appshots") { try? await Task.sleep(for: .milliseconds(50)) }
            await s.loadNow()
            if on { s.setDraft("capture.thread", thread); s.setDraft("capture.mode", "screen"); s.changed() }
            let id = on ? "capture.update" : "capture.disable"
            let row = SettingsPanels.make(s).first { $0.id == id }
            row?.perform?(.null)
            for _ in 0..<200 where !s.busy.contains("write") { await Task.yield() }
            for _ in 0..<300 where s.busy.contains("write") { try? await Task.sleep(for: .milliseconds(50)) }
            let h = s.snapshots["hotkey"]
            log("f150 hotkey \(on ? "on" : "off")", ["row": row != nil, "enabled": h?["enabled"]?.boolValue ?? false, "mode": h?["mode"]?.stringValue ?? "",
                                                   "thread": String((h?["threadId"]?.stringValue ?? "").prefix(8)), "writeError": s.errors["write"] ?? ""])
            finish()
        }
    }

    // MARK: f160 — Tools ▸ Browser: two owned tabs, Read and Screenshot on each (switching clears the other's), Attach,
    // Open externally once, Close one (the other stays); the run closes what it opened and clears the draft.

    private func browser(_ c: Conversation) {
        let tools = app.liveArtifacts, composer = app.scene.composer(for: c), before = composer.attachments.map(\.id)
        var opened: [URL] = []
        let external = tools.onOpenURL
        tools.onOpenURL = { url in opened.append(url); external?(url) }
        app.showTools(.browser, conversation: c.id)
        func idle() async { for _ in 0..<1200 where tools.busy { try? await Task.sleep(for: .milliseconds(50)) } }
        func coreTabs() -> [String] { tools.tabs.compactMap { $0["tabId"]?.stringValue } }
        Task { @MainActor [self] in
            await idle()
            tools.browserURL = "https://example.com"; tools.openBrowser(); await idle()
            let first = tools.selectedTabID
            tools.browserURL = "https://example.org"; tools.openBrowser(); await idle()
            let second = tools.selectedTabID
            log("f160 two tabs", ["first": first, "second": second, "tabs": tools.tabs.map { $0["url"]?.stringValue ?? "?" }, "toolsError": tools.error ?? ""])
            tools.selectBrowserTab(first); tools.inspectBrowser(); await idle(); tools.screenshotBrowser(); await idle()
            let firstRead = tools.browserSnapshot, firstShot = tools.browserImage?.count ?? 0
            tools.selectBrowserTab(second)
            let cleared = tools.browserSnapshot.isEmpty && tools.browserImage == nil
            tools.inspectBrowser(); await idle(); tools.screenshotBrowser(attach: true); await idle()
            log("f160 read and screenshot", ["firstRead": String(firstRead.prefix(80)), "firstShotBytes": firstShot, "switchClears": cleared,
                                             "secondRead": String(tools.browserSnapshot.prefix(80)), "secondShotBytes": tools.browserImage?.count ?? 0,
                                             "draft": composer.attachments.filter { !before.contains($0.id) }.map(\.name), "toolsError": tools.error ?? ""])
            tools.openBrowserExternally()
            tools.closeBrowserTab(); await idle()
            tools.refreshTabs(); await idle()
            log("f160 close one", ["opened": opened.map(\.absoluteString), "coreTabs": coreTabs(), "secondGone": !coreTabs().contains(second),
                                   "firstStays": coreTabs().contains(first), "toolsError": tools.error ?? ""])
            tools.selectBrowserTab(first); tools.closeBrowserTab(); await idle(); tools.refreshTabs(); await idle()
            clearShots(c, keeping: before)
            composer.attachments.removeAll { !before.contains($0.id) }; c.attachments = composer.attachments; app.store.changed(c)
            tools.onOpenURL = external
            log("f160 cleanup", ["coreTabs": coreTabs(), "draftAdded": composer.attachments.filter { !before.contains($0.id) }.count])
            finish()
        }
    }

    // MARK: f024 — Changes in the test chat's throwaway repository: a change, its reviewed diff, Commit; then a change
    // made after the review commits nothing (Core refuses the old diff hash). The run restores the file it left changed.

    private func changes(_ c: Conversation) {
        guard let live = app.live, let cwd = c.cwd, cwd.contains("live-test-repo") else { log("f024 no throwaway repository", ["cwd": c.cwd ?? ""]); finish(); return }
        let file = URL(fileURLWithPath: cwd).appending(path: "acceptance-f024.txt")
        func write(_ line: String) { let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""; try? (old + line + "\n").write(to: file, atomically: true, encoding: .utf8) }
        func git(_ args: [String]) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", cwd] + args
            let out = Pipe(); p.standardOutput = out; p.standardError = out; try? p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        Task { @MainActor [self] in
            let head = git(["rev-parse", "--short", "HEAD"])
            write("first change \(Date())")
            await live.refreshChanges(c)
            let review = NormieGitReview(c)
            log("f024 reviewed", ["head": head, "files": c.changes.map { "\($0.path) +\($0.added) −\($0.removed)" }, "hash": String((c.gitDiffHash ?? "").prefix(10)), "gitError": c.gitError ?? ""])
            app.main.actions.commit?(c, "Acceptance f024: reviewed change", review)
            for _ in 0..<200 where c.gitBusy || c.lastCommit == nil { try? await Task.sleep(for: .milliseconds(100)) }
            log("f024 committed", ["lastCommit": c.lastCommit?.hash ?? "", "gitHead": git(["log", "-1", "--format=%h %s"]), "changesAfter": c.changes.count, "error": c.operationError ?? ""])
            // A second change is reviewed, then a third lands before Commit: the reviewed hash no longer matches.
            write("second change")
            await live.refreshChanges(c)
            let stale = NormieGitReview(c), before = git(["rev-parse", "HEAD"])
            write("third change, after the review")
            c.operationError = nil
            app.main.actions.commit?(c, "Acceptance f024: must be refused", stale)
            for _ in 0..<200 where c.gitBusy || c.operationError == nil { try? await Task.sleep(for: .milliseconds(100)) }
            for _ in 0..<50 where c.gitBusy { try? await Task.sleep(for: .milliseconds(100)) }
            log("f024 stale review", ["refused": git(["rev-parse", "HEAD"]) == before, "error": c.operationError ?? "", "changesStillThere": c.changes.count,
                                      "status": git(["status", "--short"])])
            _ = git(["checkout", "--", "acceptance-f024.txt"])
            await live.refreshChanges(c)
            log("f024 restored", ["status": git(["status", "--short"]), "changes": c.changes.count, "log": git(["log", "-2", "--format=%h %s"])])
            finish()
        }
    }

    // MARK: f163, f165, f166 — Live PTYs in the test chat's throwaway directory, through Normie's terminal pane.

    private func swiftTermText() -> String {
        func find(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)) == "ToolsSwiftTermView", !v.isHiddenOrHasHiddenAncestor { return v }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return (app.main.window.contentView.flatMap(find)?.accessibilityValue() as? String) ?? ""
    }
    private static func pid(_ text: String, tag: String) -> String? {
        guard let r = text.range(of: tag + "-[0-9]+", options: [.regularExpression, .backwards]) else { return nil }
        return String(text[r].dropFirst(tag.count + 1))
    }
    private func until(_ timeout: Double, _ ready: @escaping () -> Bool) async -> Bool {
        let start = CACurrentMediaTime()
        while !ready() { if CACurrentMediaTime() - start > timeout { return false }; try? await Task.sleep(for: .milliseconds(100)) }
        return true
    }

    private func terminal(_ c: Conversation) {
        let terms = app.liveTerminals, pane = app.main.workbench.detail.terminalPane
        guard c.cwd?.contains("live-test-repo") == true else { log("f163 no throwaway directory", ["cwd": c.cwd ?? ""]); finish(); return }
        app.main.window.orderFrontRegardless()
        app.main.workbench.setTerminalShown(true)
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(800))
            // Sessions from earlier runs come back with the restore; only the ones this run opens count.
            _ = await terms.restore()
            let existing = Set(terms.sessions(for: c.id).map(\.id)), token = String(UUID().uuidString.prefix(6)).lowercased()
            pane.openLiveTerminal()
            _ = await until(15) { terms.sessions(for: c.id).contains { !existing.contains($0.id) && $0.running } }
            guard let a = terms.sessions(for: c.id).first(where: { !existing.contains($0.id) }) else { log("f163 no session"); finish(); return }
            // f163: colours, scrolling, Ctrl-C.
            a.send("echo pid-$$; printf '\\033[31mred\\033[0m \\033[32mgreen\\033[0m\\n'; seq 1 300\r")
            _ = await until(10) { a.output.contains("\n300") }
            try? await Task.sleep(for: .milliseconds(500))
            let shown = swiftTermText(), pidA = Self.pid(a.output, tag: "pid")
            log("f163 colours and scrolling", ["pid": pidA ?? "", "escapesInStream": a.output.contains("\u{1b}[31m"), "viewHasWords": shown.contains("red green"),
"viewHas300": shown.contains("300"), "viewHas1": shown.contains("\n1\n") || shown.hasPrefix("1\n"),
                                               "columns": a.columns, "rows": a.rows])
            a.send("sleep 30\r"); try? await Task.sleep(for: .seconds(1)); a.send("\u{3}"); a.send("echo after-ctrl-c\r")
            let interrupted = await until(5) { a.output.contains("after-ctrl-c\r\n") || a.output.hasSuffix("after-ctrl-c") || a.output.components(separatedBy: "after-ctrl-c").count > 2 }
            log("f163 Ctrl-C", ["interrupted": interrupted, "tail": String(a.output.suffix(120))])
            // Two sessions: B opened, A selected again; outputs stay apart.
            pane.openLiveTerminal()
            _ = await until(15) { terms.sessions(for: c.id).contains { !existing.contains($0.id) && $0.id != a.id && $0.running } }
            guard let b = terms.sessions(for: c.id).first(where: { !existing.contains($0.id) && $0.id != a.id }) else { log("f163 no second session"); finish(); return }
            b.send("echo pid-$$ session-b\r")
            _ = await until(8) { b.output.contains("session-b\r\n") || b.output.components(separatedBy: "session-b").count > 2 }
            let pidB = Self.pid(b.output, tag: "pid")
            _ = pane.selectSession(a.id); try? await Task.sleep(for: .milliseconds(500))
            log("f163 two sessions", ["pidA": pidA ?? "", "pidB": pidB ?? "", "separate": pidA != nil && pidA != pidB, "aHasB": a.output.contains("session-b"),
                                      "selectedIsA": terms.active(for: c.id)?.id == a.id, "viewShowsA": swiftTermText().contains("after-ctrl-c")])
            // Hide and show: the same PTY.
            app.main.workbench.setTerminalShown(false); try? await Task.sleep(for: .milliseconds(600))
            app.main.workbench.setTerminalShown(true); try? await Task.sleep(for: .milliseconds(600))
            a.send("echo pid-$$ still\r")
            _ = await until(6) { a.output.components(separatedBy: " still").count > 2 }
            log("f163 hide and show", ["sameSession": terms.active(for: c.id)?.id == a.id, "samePid": Self.pid(a.output, tag: "pid") == pidA, "backend": a.backendID ?? ""])
            // f165: numbered output read again from Core adds nothing twice.
            a.send("for i in $(seq 1 50); do echo line-$i; done\r")
            _ = await until(8) { a.output.contains("line-50") }
            try? await Task.sleep(for: .milliseconds(300))
            // Lines as the terminal shows them: escape sequences and carriage returns removed.
            let count = { a.output.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "")
                .split(separator: "\n").filter { $0.range(of: "^line-[0-9]+$", options: .regularExpression) != nil }.count }
            let before = count(), sequence = a.sequence
            await a.catchUp()
            log("f165 read again", ["linesBefore": before, "linesAfter": count(), "sequence": sequence, "sequenceAfter": a.sequence])
            // f166: half a line typed, resized and the pane closed and opened while it waits, then finished.
            a.send("printf 'half-")
            for (k, size) in [(100, 30), (60, 20), (132, 40), (80, 24)].enumerated() {
                a.resize(columns: size.0, rows: size.1); try? await Task.sleep(for: .milliseconds(120))
                if k == 1 { app.main.workbench.setTerminalShown(false); try? await Task.sleep(for: .milliseconds(300)); app.main.workbench.setTerminalShown(true) }
            }
            a.send("line-done\\n'\r")
            let whole = await until(6) { a.output.components(separatedBy: "half-line-done\r\n").count == 2 }
            log("f166 resize while typing", ["whole": whole, "tail": String(a.output.suffix(160)), "columns": a.columns, "rows": a.rows, "error": a.error ?? ""])
            // End only B.
            _ = pane.selectSession(b.id); pane.endActiveSession()
            _ = await until(6) { !b.running }
            a.send("echo pid-$$ after-end\r")
            let aAlive = await until(6) { a.output.contains("after-end") }
            log("f166 End", ["bRunning": b.running, "aStillAnswers": aAlive])
            try? String(a.output).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACCEPT_DUMP"] ?? "/dev/null"), atomically: true, encoding: .utf8)
            // A stays running for `terminal-reopen` (f164), which closes it.
            a.send("echo pid-$$ keep-\(token)\r")
            _ = await until(6) { a.output.components(separatedBy: "keep-\(token)").count > 2 }
            app.main.workbench.setTerminalShown(false)
            log("f163 left for f164", ["aRunning": a.running, "running": terms.sessions(for: c.id).filter(\.running).count])
            finish()
        }
    }

    /// f164: after a restart the client restores the Core's sessions; the one selected is the PTY it was (same PID, its
    /// own output). The first run leaves one session running; this run reads it and closes it.
    private func terminalReopen(_ c: Conversation) {
        let terms = app.liveTerminals
        Task { @MainActor [self] in
            let restored = await terms.restore()
            let mine = terms.sessions(for: c.id)
            // The running session the last `terminal` run marked (keep-<token>).
            let marked = mine.last { $0.running && $0.output.range(of: "keep-[0-9a-f]{6}", options: .regularExpression) != nil }
            log("f164 restored", ["ok": restored, "sessions": mine.count, "running": mine.filter(\.running).count, "marked": marked != nil,
                                  "markedPid": marked.flatMap { Self.pid($0.output, tag: "pid") } ?? "", "error": terms.restorationError ?? ""])
            guard let s = marked else { finish(); return }
            app.main.window.orderFrontRegardless()
            app.main.workbench.setTerminalShown(true)
            try? await Task.sleep(for: .milliseconds(800))
            let picked = app.main.workbench.detail.terminalPane.selectSession(s.id)
            log("f164 pick in the pane", ["picked": picked])
            let before = Self.pid(s.output, tag: "pid"), mark = String(UUID().uuidString.prefix(6)).lowercased()
            s.send("echo now-$$ \(mark)\r")
            let arrived = await until(6) { s.output.components(separatedBy: mark).count > 2 }
            log("f164 same PTY", ["arrived": arrived, "pidBefore": before ?? "", "pidNow": Self.pid(s.output, tag: "now") ?? "",
                                  "selected": terms.active(for: c.id)?.id == s.id, "otherOutputHasMark": mine.filter { $0.id != s.id }.contains { $0.output.contains(mark) }])
            await s.close()
            app.main.workbench.setTerminalShown(false)
            finish()
        }
    }

    // MARK: f171 — the connection drops (the forwarder in front of Core is killed for a few seconds, see
    // scratchpad f171/proxy.py) while the test chat's terminal prints a numbered line every 0.25 s: the status says so,
    // the client reconnects by itself, and the lines from the gap are read back once each; the history stays as it was.

    private func reconnect(_ c: Conversation) {
        guard let live = app.live else { finish(); return }
        let terms = app.liveTerminals
        Task { @MainActor [self] in
            _ = await terms.restore()
            guard let s = await terms.open(for: c, cwd: c.cwd) else { log("f171 no terminal", ["error": terms.restorationError ?? ""]); finish(); return }
            _ = await until(10) { s.running }
            let items = c.items.map(\.id)
            s.send("for i in $(seq 1 80); do echo tick-$i; sleep 0.25; done\r")
            var states: [[String: Any]] = [], last: Bool? = nil, startedAt = CACurrentMediaTime()
            while CACurrentMediaTime() - startedAt < 32 {
                if live.isConnected != last {
                    last = live.isConnected
                    states.append(["t": ((CACurrentMediaTime() - startedAt) * 100).rounded() / 100, "connected": live.isConnected, "status": live.connectionStatus, "offline": app.store.isOffline(c)])
                }
                if s.output.contains("tick-80\r\n"), CACurrentMediaTime() - startedAt > 25 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let clean = s.output.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "")
            let ticks = clean.split(separator: "\n").filter { $0.range(of: "^tick-[0-9]+$", options: .regularExpression) != nil }.map(String.init)
            log("f171 connection", ["states": states, "lastError": live.lastError ?? ""])
            log("f171 terminal through the gap", ["lines": ticks.count, "distinct": Set(ticks).count, "complete": Set(ticks) == Set((1...80).map { "tick-\($0)" }),
                                                   "inOrder": ticks == (1...80).map { "tick-\($0)" }, "sessionError": s.error ?? ""])
            log("f171 history", ["sameItems": c.items.map(\.id) == items, "items": c.items.count, "historyLoaded": c.historyLoaded, "operationError": c.operationError ?? ""])
            await s.close()
            finish()
        }
    }

    // MARK: f162, f159 — a generated image becomes an artifact; Tools attaches it to the test chat, then sends it.

    private func artifacts(_ c: Conversation) {
        let tools = app.liveArtifacts
        let before = Set(tools.artifacts.map(\.id)), base = c.items.count
        log("f162 send", ["submitted": send("Use your image generation tool to make a small simple picture: one green circle on a white background. Then reply with the single word: done.", in: c)])
        wait(300, { [self] in turnOver && c.items.count > base + 1 }) { [self] ended in
            let generated = c.items.dropFirst(base).filter { "\($0.rowKind)".contains("tool") }.map { "\($0.rowKind) [\($0.status ?? "-")] " + String($0.text.prefix(80)) }
            log("f162 turn", ["ended": ended, "tools": generated, "tail": tail()])
            wait(30, { tools.artifacts.contains { !before.contains($0.id) && $0.raw["generatedItemId"] != nil && !$0.previewUnavailable } }) { [self] registered in
                let made = tools.artifacts.filter { !before.contains($0.id) }
                log("f162 artifact", ["registered": registered, "error": tools.error ?? "",
                                      "new": made.map { ["name": $0.name, "mime": $0.mime, "bytes": $0.bytes, "path": $0.path, "generated": $0.raw["generatedItemId"]?.stringValue ?? "",
                                                         "previewUnavailable": $0.previewUnavailable, "sha": String($0.sha.prefix(12))] }])
                guard let image = made.first(where: { $0.raw["generatedItemId"] != nil && !$0.previewUnavailable }) else { finish(); return }
                attachAndSend(image, to: c)
            }
        }
    }

    /// f159 again with the image already generated in the test chat (no new generation).
    private func sendExisting(_ c: Conversation) {
        let tools = app.liveArtifacts
        tools.refreshArtifacts()
        wait(30, { tools.artifacts.contains { $0.threadID == c.backendThreadID && $0.mime == "image/png" } }) { [self] found in
            guard found, let image = tools.artifacts.first(where: { $0.threadID == c.backendThreadID && $0.mime == "image/png" }) else {
                log("f159 no image artifact", ["count": tools.artifacts.count]); finish(); return
            }
            log("f159 reuse", ["name": image.name, "bytes": image.bytes])
            attachAndSend(image, to: c)
        }
    }

    private func attachAndSend(_ image: CoreArtifact, to c: Conversation) {
        let tools = app.liveArtifacts
        tools.showArtifacts(conversation: c)
        tools.conversationID = c.id
        tools.select(image.id)
        wait(30, { tools.selectedData != nil }) { [self] loaded in
            log("f159 selected", ["loaded": loaded, "bytes": tools.selectedData?.count ?? 0, "destination": tools.conversationID == c.id])
            let composer = app.scene.composer(for: c)
            let draftBefore = composer.attachments.map(\.id)
            tools.attachSelected(send: false)
            wait(30, { composer.attachments.contains { $0.id == "artifact:" + image.id } || tools.error != nil }) { [self] attached in
                log("f159 attach", ["attached": attached, "error": tools.error ?? "", "notice": tools.notice ?? "",
                                    "draft": composer.attachments.map(\.name), "before": draftBefore])
                // Another conversation in front: the attachment stays with the test chat's draft.
                let other = app.store.conversations.first { $0.id != c.id && !$0.archived }
                if let other { app.main.reveal(other.id) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    let otherDraft = other.map { app.scene.composer(for: $0).attachments.map(\.id) } ?? []
                    log("f159 other chat shown", ["other": other?.title ?? "", "testDraftKeeps": composer.attachments.contains { $0.id == "artifact:" + image.id },
                                                  "otherDraftHasIt": otherDraft.contains("artifact:" + image.id)])
                    // Send: what Attach put in the draft goes with the message (Tools' Send).
                    composer.attachments = []; c.attachments = []; app.store.changed(c)
                    app.main.reveal(c.id)
                    let base = c.items.count
                    tools.conversationID = c.id
                    tools.attachSelected(send: true)
                    wait(240, { [self] in (c.items.count > base + 1 && turnOver) || tools.error != nil }) { [self] sent in
                        let user = c.items.dropFirst(base).first { $0.rowKind == .user }
                        log("f159 send", ["sent": sent, "error": tools.error ?? "", "notice": tools.notice ?? "",
                                          "userMessage": String(user?.text.prefix(160) ?? ""), "tail": tail(3)])
                        finish()
                    }
                }
            }
        }
    }
}
