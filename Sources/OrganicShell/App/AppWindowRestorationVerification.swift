import AppKit

/// Production callbacks driven with ordered-out windows and isolated mock/live presentation storage.
@MainActor enum AppWindowRestorationVerification {
    static var probes: [(String, AppWindowLifetimeVerification.Weak<AnyObject>)] = []
    private static func capture(_ app: AppController) {
        for w in app.windows {
            var objects: [(String, AnyObject)] = [("window", w), ("scene", w.scene), ("root", w.root), ("clock", w.scene.clock)]
            objects += w.transcriptSessions.transcripts.values.map { ("transcript", $0 as AnyObject) }
            objects += w.scene.members.compactMap { w.scene.composers.existingComposer(for: $0.id) }.map { ("composer", $0 as AnyObject) }
            if w.workbench.composingNew || w.scene.composingNew { objects.append(("draft", w.scene.composers.draft().composer)) }
            probes += objects.map { ($0.0, .init($0.1)) }
        }
    }
    private struct NoNetwork: CoreTransport {
        func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
            throw CoreWire.failure("Network is forbidden in window restoration verification")
        }
        func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> { AsyncThrowingStream { $0.finish() } }
    }
    static func run(app: AppController, options: Options, defaults: UserDefaults, screen: NSScreen,
                    check: (Bool, String) -> Void) {
        let catalog = ModelCatalog.models
        defer { ModelCatalog.models = catalog }
        func closeAll(_ app: AppController) { capture(app); for w in app.windows { w.window.close() }; AppWindowLifetimeVerification.drain() }
        func records(_ app: AppController) -> [SavedWindow] { app.windowRecords().map(\.saved) }
        func same(_ a: SavedWindow, _ b: SavedWindow) -> Bool {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(a)) == (try? encoder.encode(b))
        }
        check(!app.applicationShouldTerminateAfterLastWindowClosed(NSApp), "1: AppKit must not terminate after last window")
        let latest = app.store.conversations.filter { !$0.archived }.max { $0.updated < $1.updated }!.id
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        check(app.windows.count == 1 && app.windows.first?.scene.current == latest, "3: Empty reopen uses startup latest-chat fallback")
        var errorPresentations = 0
        let connectionError = CoreWire.failure("Synthetic connection error")
        app.presentLiveError(connectionError) { _, target in
            errorPresentations += 1
            check(target === app.windows.first?.window, "6: Connection error targets an existing window")
        }
        let timers = (0..<3).map { _ in Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in } }
        app.demoTimer = timers[0]; app.hoverTimer = timers[1]; app.swapTimer = timers[2]
        closeAll(app)
        check(timers.allSatisfy { !$0.isValid }, "7: Last close cancels app-owned window demo timers")
        app.liveError = connectionError.localizedDescription
        app.presentLiveError(connectionError) { _, _ in errorPresentations += 1 }
        check(errorPresentations == 1 && app.liveError == connectionError.localizedDescription,
              "6: Zero-window connection error stays in state without presenting an alert")
        let frame = CGRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                           width: min(1100, screen.visibleFrame.width - 40), height: min(720, screen.visibleFrame.height - 40))
        for (name, normie, split, draft) in [("auto", false, [String](), false), ("focused", false, ["C"], false),
                                           ("split", false, ["C", "A"], false), ("normie-draft", true, [], true),
                                           ("organic-draft", false, [], true)] {
            defaults.removeObject(forKey: SavedWindow.key("mock"))
            let record = SavedWindow(frame: [frame.minX, frame.minY, frame.width, frame.height], normie: normie,
                                     members: ["C", "A", "B", "D"], current: "C", layout: split.isEmpty ? nil : "focused",
                                     split: split.isEmpty ? nil : split, splitFocus: split.last,
                                     composingNew: draft, draft: draft ? "Unsent window draft \(name)" : nil,
                                     project: draft ? "spw" : nil, device: "mac")
            _ = app.restoreWindows([.init(saved: record)], present: false)
            AppWindowLifetimeVerification.drain()
            guard let w = app.windows.first else { check(false, "3: Restored owner exists \(name)"); continue }
            capture(app)
            let expected = SavedWindow.make(w), order = w.scene.order
            check(w.shell.mode == (normie ? .normie : .organic), "3: Initial restored mode \(name)")
            check(w.scene.scheme.split == split, "3: Initial restored split \(name)")
            check(!w.window.isVisible, "Fixture remains ordered out \(name)")
            w.window.close()
            check(records(app).count == 1 && same(records(app)[0], expected), "2: Last close saves intact state before teardown \(name)")
            app.saveWindows()
            check(records(app).count == 1 && same(records(app)[0], expected), "2: Zero-window save preserves record \(name)")
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            AppWindowLifetimeVerification.drain()
            if let restored = app.windows.first {
                capture(app)
                let actual = SavedWindow.make(restored)
                check(same(actual, expected), "3: Dock restores complete saved state \(name)")
                check(restored.scene.order == order, "3: Dock restores column order \(name)")
                check(restored.window.frame == frame, "3: Dock restores frame \(name)")
                check(!draft || restored.scene.composers.draft().composer.text == record.draft, "3: Dock restores unsent draft \(name)")
                _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
                check(app.windows.count == 1, "3: Repeated Dock callback never duplicates \(name)")
                restored.window.setFrameOrigin(CGPoint(x: frame.minX + 8, y: frame.minY + 8))
                let changed = SavedWindow.make(restored)
                restored.window.close()
                _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                AppWindowLifetimeVerification.drain() // Split focus is restored asynchronously after construction.
                check(app.windows.first.map { same(SavedWindow.make($0), changed) } == true, "3: Close/reopen consumes the newest state \(name)")
            } else { check(false, "3: Dock must recreate owner \(name)") }
            closeAll(app)
        }
        // Closing A from a two-window set must leave only B in the durable set.
        defaults.removeObject(forKey: SavedWindow.key("mock"))
        let a = SavedWindow(frame: [frame.minX, frame.minY, frame.width, frame.height], normie: true, members: ["A"], current: "A")
        let b = SavedWindow(frame: a.frame, normie: true, members: ["B"], current: "B")
        _ = app.restoreWindows([.init(saved: a), .init(saved: b)], present: false)
        app.windows.first?.window.close()
        check(records(app).count == 1 && records(app).first?.members == ["B"], "2: Closing one of two saves only the survivor")
        closeAll(app)
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        check(app.windows.count == 1 && app.windows.first?.scene.members.map(\.id) == ["B"], "2: Earlier closed window never returns")
        closeAll(app)
        app.installMainMenu()
        check(app.menus.context().enabled(.newChat), "4: Zero-window Cmd+N is enabled")
        app.menus.perform(.newChat, 0)
        check(app.windows.count == 1 && app.windows.first?.workbench.composingNew == true, "4: Cmd+N creates a fresh draft owner")
        check(app.windows.first?.scene.members.isEmpty == true, "4: Cmd+N does not restore the closed working set")
        closeAll(app)
        app.watchArrivals()
        let before = records(app)
        let arrival = Conversation(id: "background-no-window", title: "Background arrival")
        app.store.add(arrival)
        check(app.store.conversation(arrival.id) === arrival && app.windows.isEmpty, "6: Background arrival stays in store without a window")
        check(records(app).count == before.count, "6: Background arrival leaves retained records intact")

        let liveApp = AppController(options, windowDefaults: defaults, presentsWindows: false)
        let replay = MockReplay(store: liveApp.store); replay.start(live: false)
        let memory = CoreMemoryStorage()
        let previousStore = ConversationStore()
        let previous = Conversation(id: "prior-local-draft", title: "Prior unsent text")
        previous.draft = "Keep this before Core connects"; previousStore.add(previous)
        let previousState = LocalPresentationState(store: previousStore, scope: "window-fixture", storage: memory)
        do { try previousState.save() } catch { check(false, "Could not prepare prior local draft fixture") }
        let presentation = LocalPresentationState(store: liveApp.store, scope: "window-fixture", storage: memory)
        liveApp.live = LiveConversationRuntime(store: liveApp.store, client: NoNetwork(), presentation: presentation)
        for device in liveApp.store.devices { liveApp.store.setOnline(device.id, true) }
        _ = liveApp.restoreWindows([.init(saved: b)], present: false)
        capture(liveApp)
        liveApp.windows.first?.window.close()
        let recoveredStore = ConversationStore()
        let loaded = LocalPresentationState(store: recoveredStore, scope: "window-fixture", storage: memory)
        loaded.restore()
        check(recoveredStore.conversation(previous.id)?.draft == previous.draft, "2: Closing before Core load preserves earlier local chat drafts")
        check(loaded.windows.count == 1 && SavedWindow.from(loaded.windows[0])?.members == ["B"], "2: Live last-close record is synchronously durable")
        liveApp.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let afterQuit = LocalPresentationState(store: liveApp.store, scope: "window-fixture", storage: memory)
        check(afterQuit.windows.count == 1, "2: Live zero-window quit cannot overwrite saved windows")
        check(app.windows.isEmpty && liveApp.windows.isEmpty && NSApp.windows.allSatisfy { !$0.isVisible }, "All functional checks remain offscreen")
        AppLiveWindowRestorationVerification.run(defaults: defaults, screen: screen, check: check)
        AppWindowTerminationVerification.run(defaults: defaults, screen: screen, check: check)
    }
}
