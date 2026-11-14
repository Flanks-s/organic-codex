import AppKit
import UserNotifications

extension AppController {
    /// B-stage window entry point; retain and cancel the token with the window. A-stage adds no subscribers.
    func observeAccountUsage(_ change: @escaping (AccountUsage) -> Void) -> AccountUsageObservation {
        store.observeAccountUsage(change)
    }
    /// The app keeps arrivals in the store even when there is no presentation owner.
    func watchArrivals() { store.onAdd = { [weak self] c in self?.front?.scene.admit(c, reason: "arrival") } }

    func startLive() {
        let service = CoreService.shared
        core = service
        let live = LiveConversationRuntime(store: store, client: service.client, service: service)
        self.live = live
        installLiveBrowser(client: service.client)
        connectBrowserMutations()
        runtime = live
        // Shown in any window (a column, Normie's selection, the strip): its reads are kept current.
        live.isShown = { [weak self] id in
            self?.windows.contains { w in w.strip?.shown == id || (w.shell.mode == .normie ? w.workbench.selectedConversation?.id == id : w.scene.members.contains { $0.id == id }) } ?? false
        }
        live.onStateChange = { [weak self] in self?.liveBrowser?.connectionChanged(self?.live?.isConnected == true); self?.windows.forEach { $0.workbench.refresh() } }
        // Settings owns its own Usage snapshot, not ConversationStore's quota fields.
        // A local read/clear refreshes legacy quota visuals and invalidates the Settings cache.
        // This Settings-only notification never enters the runtime stream or advances its cursor.
        live.onAccountUsageChange = { [weak self] in
            guard let self else { return }
            self.windows.forEach { window in
                window.scene.dock.refreshOrbs()
                if window.scene.meController.isQuotaPresented { window.scene.meController.update(window.scene.meModel()) }
            }
            self.liveSettings.receive(.init(id: 0, time: nil, method: "account/rateLimits/updated", params: [:]))
        }
        // One SSE stream: Settings, artifacts and terminals hear it from the runtime.
        live.onEvent = { [weak self] e in self?.liveSettings.receive(e); self?.liveArtifacts.receive(e); self?.liveTerminals.receive(e); self?.liveBrowser?.receive(e) }
        // Revert's native confirmation belongs to the window (CORE-M7): the runtime reviews, the window asks.
        live.onRevertRequested = { [weak self, weak live] card, c in
            live?.revertReviewed(card, in: c) { paths, staged, worktree in
                await self?.confirmRevert(paths: paths, staged: staged, worktree: worktree, of: c) ?? false
            }
        }
        connectLive()
    }

    /// Tools keeps its own tab selection; only its mutation result invalidates the shared browser list.
    func connectBrowserMutations() {
        liveArtifacts.onBrowserMutated = { [weak self] in self?.liveBrowser?.noteShellMutation() }
    }

    private func connectLive() {
        connection?.cancel()
        connection = Task { @MainActor [weak self] in
            guard let self, let live = self.live, let service = self.core else { return }
            do {
                try await service.connect()
                try await live.load()
                self.configureLiveControllers()
                live.start()
                self.restoreLive()
                self.watchArrivals()
            } catch {
                self.liveError = error.localizedDescription
                self.windows.forEach { $0.workbench.refresh() }
                self.presentLiveError(error)
            }
        }
    }

    /// Settings, Tools and the terminal on the live Core (the product's configureLocalSettings): Settings' Reconnect
    /// connects and loads again.
    private func configureLiveControllers() {
        guard let live, let service = core else { return }
        let endpoint = service.baseURL.absoluteString
        installNotificationHooks()
        liveSettings.configure(client: service.client, runtime: live, endpoint: endpoint, service: service) { [weak self] in
            try await service.connect(); try await live.load(); live.start()
            self?.configureLiveControllers()
        }
        settings?.session.setSource(liveSettings)
        liveArtifacts.configure(client: service.client, runtime: live, endpoint: endpoint)
        liveArtifacts.setLocalPathsAvailable(service.isLocalBackend)
        liveArtifacts.onOpenURL = { NSWorkspace.shared.open($0) }
        liveArtifacts.onDeliver = { [weak self] value, done in
            guard let self else { done(.failed("The app is closing.")); return }
            self.deliver(value, done)
        }
        liveArtifacts.revealConversation = { [weak self] id in self?.revealConversation(id) }
        liveTerminals.configure(client: service.client, store: store)
        // Settings ▸ Storage / Configuration open the verified local Core's own data folder or a file it named, as the
        // product does (f136); a remote or unverified Core opens nothing.
        liveSettings.onOpenLocal = { [weak service] url in
            guard let service, service.isLocalBackend else { throw CoreWire.failure("This Core has not been verified as the local instance.") }
            var directory: ObjCBool = false
            let target = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory),
                  !directory.boolValue || target.path == service.dataDirectory.standardizedFileURL.path else {
                throw CoreWire.failure("\(target.lastPathComponent) is not available on this Mac.")
            }
            NSWorkspace.shared.open(target)
        }
        // Settings ▸ Connections saves the address for the next launch (product CoreSettingsController.saveEndpoint):
        // this run keeps its connection, and nothing switches to a local Core on its own (f153).
        liveSettings.onSaveEndpoint = { url in UserDefaults.standard.set(url.absoluteString, forKey: "core.url") }
        for w in windows { attachLive(w) }
    }

    /// macOS notifications for the Core's scheduled tasks (SETTINGS-ASYNC-S1 §2; f129, f152), installed before the
    /// controller is configured: the status is only read, permission is asked only from Settings' button, and a
    /// notification goes out only when macOS allows it and the global or per-task policy does.
    private func installNotificationHooks() {
        liveSettings.onPermissionStatus = {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: "Allowed"
            case .denied: "Not allowed"
            case .notDetermined: "Not determined"
            @unknown default: "Not reported"
            }
        }
        liveSettings.onPermissionRequest = { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        liveSettings.onDeliverNotification = { [weak self] value in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return .notAuthorized("macOS has not authorized notifications.") }
            guard let id = value["id"]?.stringValue else { return .suppressed }
            // The policy as it is now, after the await, just before the request.
            guard !Task.isCancelled, let policy = self?.settings?.session.preferences.notificationPolicy,
                  policy.allows(jobID: value["jobId"]?.stringValue, status: value["status"]?.stringValue) else { return .suppressed }
            let content = UNMutableNotificationContent()
            content.title = value["title"]?.stringValue ?? "Organic Codex"
            content.body = value["message"]?.stringValue ?? value["body"]?.stringValue ?? "A scheduled task updated."
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return .delivered
        }
    }

    /// A window's share of the Live Core: the terminal controller, and Open in's proof that this Core is the local
    /// instance (f025). Again after a reconnect; a window opened later takes it when it opens.
    func attachLive(_ w: OrganicWindow) {
        guard live != nil, let service = core else { return }
        w.workbench.setTerminalController(liveTerminals)
        w.workbench.openIn.identity = service.localIdentity
    }

    /// Every send's receipt passes here; a Tools Send waiting on that UUID finishes with the same result.
    func submissionFinished(_ id: UUID, _ result: CoreSubmissionResult) { deliveries.removeValue(forKey: id)?(result) }

    /// Into the destination fixed when the Tools operation began, never the current selection: its retained editor takes
    /// the attachments (merged by id) and the source envelope merged into its text as it is now. Send then goes out from
    /// that editor under the delivery's UUID and finishes on the real receipt.
    func deliver(_ value: CoreArtifactDelivery, _ done: @escaping @MainActor (CoreSubmissionResult) -> Void) {
        guard let c = store.conversation(value.destinationID), !c.archived,
              let composer = windows.lazy.compactMap({ $0.scene.composers.existingComposer(for: c.id) }).first else {
            done(.failed("The destination conversation is no longer open.")); return
        }
        // The input method owns marked text; replacing it would drop what is being typed.
        guard !composer.isComposing else { done(.failed("Finish typing in that conversation, then try again.")); return }
        var merged = composer.attachments
        for a in value.attachments where !merged.contains(where: { $0.id == a.id }) { merged.append(a) }
        composer.attachments = merged; c.attachments = merged
        composer.setText(value.composeDraft(current: composer.text))
        store.changed(c)
        guard value.send else { done(.accepted); return }
        deliveries[value.id] = done
        if !composer.submit(id: value.id) {
            deliveries[value.id] = nil
            done(.failed("That conversation can't send right now. The artifact is attached to its draft."))
        }
    }

    /// OrganicApplication's revert dialog, as a sheet on the window holding the conversation: every path, then the
    /// staged and working-tree diffs that the confirmed hash covers.
    private func confirmRevert(paths: [String], staged: String, worktree: String, of c: Conversation) async -> Bool {
        let alert = NSAlert(); alert.messageText = "Revert \(paths.count) files?"
        alert.informativeText = paths.joined(separator: "\n") + "\n\nThis restores these files and their staged changes to HEAD."
        alert.addButton(withTitle: "Revert"); alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 260)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = "Staged changes\n" + staged + "\nWorking tree changes\n" + worktree; scroll.documentView = text; alert.accessoryView = scroll
        let owner = windows.first { $0.scene.members.contains { $0.id == c.id } } ?? front
        // The product uses an application-modal confirmation when no conversation window owns it.
        guard let owner else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: owner.window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// Tools asks to show a conversation (capture approvals): the window holding it, else the front window takes it.
    private func revealConversation(_ id: String) {
        guard let c = store.conversation(id) else { return }
        if let w = windows.first(where: { $0.scene.members.contains { $0.id == id } }) { w.reveal(id); return }
        // Product revealConversation opens an empty conversation window when none remains.
        guard let w = front ?? openConversationWindow(members: []) else { return }
        w.scene.admit(c, reason: "reveal"); w.reveal(id)
    }

    /// Keep connection errors in liveError while the app has no conversation window.
    func presentLiveError(_ error: Error, present: @MainActor (NSAlert, NSWindow) -> Void = { $0.beginSheetModal(for: $1) }) {
        guard let window = windows.first?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Organic Core is not available"
        alert.informativeText = error.localizedDescription + "\n\nThe window stays open without it. Settings ▸ Connections can reconnect."
        alert.addButton(withTitle: "OK")
        present(alert, window)
    }

    func showTools(_ section: ToolsRootView.Section, conversation: String?) {
        tools.present(section: section, conversationID: conversation)
    }

    /// A local option changed in Settings: the windows take it now.
    /// A local preference changed in Settings, named as SettingsPreferences names it (`organic.fullyFocused`,
    /// `keys.newChat`, `numberShortcuts`, …); its stored value is already written.
    func settingChanged(_ key: String) {
        if key.hasPrefix("keys.") || key == "numberShortcuts" { applyShortcuts(); return }
        if key.hasPrefix("look.") { applyLook(); return }
        for w in windows {
            switch key {
            case "organic.fullyFocused": w.scene.fullyFocused = UserDefaults.standard.bool(forKey: "toggle.fullyFocused")
            case "organic.playfulSummaries", "organic.simulateReduceMotion", "organic.identityLiquid": w.scene.reduceMotionChanged()
            case "followUpDefault": store.followUpDefault = AutoScene.followUpDefault; w.scene.applyFollowUpDefault()
            case "organic.organicFullBleed": w.scene.applyCardBands()
            default: break
            }
        }
    }

    /// Fully Focused from a menu (OWC toggleFullyFocused → Tuning.shared; AP15): through Settings' preference when it is
    /// there, so every window and its switch follow; else every window at once.
    func setFullyFocused(_ on: Bool) {
        if let p = settings?.session.preferences { p.set("organic.fullyFocused", .bool(on)) }
        else { UserDefaults.standard.set(on, forKey: "toggle.fullyFocused"); for w in windows { w.scene.fullyFocused = on } }
    }

    /// General ▸ Default access (AP11): what a new chat starts with.
    var defaultAccess: Access {
        switch settings?.session.preferences["general.access"].settingsText {
        case "read": .readOnly
        case "full": .full
        default: .auto
        }
    }

    /// Keyboard Shortcuts (f142): the menus take the keys set for their commands and ⌘1–9 its choice (Sol's
    /// NormieMenuBuilder.applyShortcuts); Send Message's keys go to every composer (SettingsModel.sendKeys: none set
    /// is ⌘↩, and plain ↩ then adds a line).
    func applyShortcuts() {
        guard let p = settings?.session.preferences else { return }
        var bindings: [String: String] = [:]
        for item in NativeSettingsCatalog.shortcuts where NormieCommand(rawValue: item.id) != nil { bindings[item.id] = p.effectiveKey(item.id) }
        menus.applyShortcuts(bindings, numberShortcuts: p["numberShortcuts"].settingsText != "off")
        // Edit ▸ Undo is configurable (MainMenu shortcut.undo; AP09): marked so it is not a fixed key, and given its keys.
        func undoItem(_ m: NSMenu?) -> NSMenuItem? {
            for i in m?.items ?? [] { if i.action == Selector(("undo:")) { return i }; if let f = undoItem(i.submenu) { return f } }
            return nil
        }
        if let undo = undoItem(NSApp.mainMenu) {
            undo.identifier = .init("shortcut.undo")
            (undo.keyEquivalent, undo.keyEquivalentModifierMask) = NormieMenuBuilder.keyEquivalent(p.effectiveKey("undo"))
        }
        AutoScene.sendShortcut = Self.sendShortcut(p.effectiveKey("send"))
        for w in windows { w.scene.composers.sendShortcut = AutoScene.sendShortcut; w.scene.applySendShortcut() }
    }

    /// Settings ▸ Appearance (f132–f133): the transcripts, composers and Normie update in place (Sol's
    /// NativeAppearance); each scene takes the glass and makes its captures again. Dark only.
    func applyLook() {
        guard let p = settings?.session.preferences else { return }
        let change = NativeAppearance.apply(p.nativeLook)
        for w in windows { w.scene.lookChanged(change) }
    }

    /// "⌘↩", "↩", "⇧↩", "⌥↩", "⌃↩" as the composer's shortcut; anything else (a letter key) is not one the composer
    /// can take, and leaves ⌘↩.
    static func sendShortcut(_ combo: String) -> NativeComposerSendShortcut {
        let (key, modifiers) = NormieMenuBuilder.keyEquivalent(combo)
        guard let code = keyCode(key) else { return .commandReturn }
        return NativeComposerSendShortcut(keyCode: code, modifiers: modifiers)
    }

    /// The ANSI key code for a key equivalent as the menus spell it (a lowercase character or a function key's
    /// private-use character), so Send Message can be any combination Settings accepts (ComposerEditor KeyCombo; AP08).
    static func keyCode(_ key: String) -> UInt16? {
        let table: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\r": 36, "l": 37, "j": 38, "'": 39, "k": 40,
            ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50, "\u{8}": 51, "\u{7f}": 117]
        if let code = table[key] { return code }
        guard let u = key.unicodeScalars.first?.value, key.unicodeScalars.count == 1 else { return nil }
        let functionKeys: [Int: UInt16] = [NSLeftArrowFunctionKey: 123, NSRightArrowFunctionKey: 124, NSDownArrowFunctionKey: 125,
            NSUpArrowFunctionKey: 126, NSF1FunctionKey: 122, NSF2FunctionKey: 120, NSF3FunctionKey: 99, NSF4FunctionKey: 118,
            NSF5FunctionKey: 96, NSF6FunctionKey: 97, NSF7FunctionKey: 98, NSF8FunctionKey: 100, NSF9FunctionKey: 101,
            NSF10FunctionKey: 109, NSF11FunctionKey: 103, NSF12FunctionKey: 111]
        return functionKeys[Int(u)]
    }

    /// A red event while the app is in the background asks for attention; coming back to the app ends it (product
    /// OrganicApplication: engine.onRedEvent, spec §10.2).
    func watchRedEvents() {
        for c in store.conversations { redSeen[c.id] = c.redEvents }
        store.observe { [weak self] c in
            guard let self else { return }
            let before = self.redSeen[c.id] ?? 0
            self.redSeen[c.id] = c.redEvents
            if c.redEvents > before, !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        }
    }

    // MARK: Core ↔ composer (CORE-M7: one mapping each way, no re-reading the mutable conversation)

    /// A new conversation for New Chat's first send, not yet in the store: titled with the first line, the next identity.
    func newConversation(titled text: String, context: NormieNewChatContext = NormieNewChatContext()) -> Conversation? {
        created += 1
        let title = text.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0.prefix(60)) } ?? "New Chat"
        let c = Conversation(id: "new-\(created)", title: title)
        c.identityIndex = store.nextIdentity()
        c.access = defaultAccess
        c.projectID = context.projectID
        c.deviceID = context.deviceID
        c.updated = Date()
        return c
    }
}
