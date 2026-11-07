import AppKit
import Synchronization

/// Reproduce Live startup: construct an empty Normie owner, hydrate the store, then call restoreLive.
@MainActor enum AppLiveWindowRestorationVerification {
    private final class NoNetwork: CoreTransport {
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }
        func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
            count.withLock { $0 += 1 }
            throw CoreWire.failure("Network is forbidden in Live restoration verification")
        }
        func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> {
            count.withLock { $0 += 1 }
            return AsyncThrowingStream { $0.finish() }
        }
    }
    static func run(defaults: UserDefaults, screen: NSScreen, check: (Bool, String) -> Void) {
        let catalog = ModelCatalog.models
        defer { ModelCatalog.models = catalog }
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX + 30, y: visible.minY + 30,
                           width: min(1120, visible.width - 60), height: min(740, visible.height - 60))
        let payloadFrame: [Double] = [frame.minX, frame.minY, frame.width, frame.height]
        let attachment = Attachment(id: "live-draft-file", name: "Unsent attachment", symbol: "doc")
        for normie in [false, true] {
            for scenario in ["auto", "focused", "split", "stale-flag", "stale-empty-text", "text-draft", "file-draft", "empty-draft", "multi", "collapsed", "fallback"] {
                autoreleasepool {
                    let label = "Live restore \(normie ? "Normie" : "Organic") \(scenario)"
                    let draft = ["text-draft", "file-draft", "empty-draft"].contains(scenario)
                    let split = scenario == "focused" ? ["C"] : scenario == "split" ? ["C", "A"] : []
                    let members = scenario == "empty-draft" ? [] : scenario == "split" ? ["C", "B", "A"] : ["C", "A", "B"]
                    let record = SavedWindow(frame: payloadFrame, normie: normie, members: members, current: members.first ?? "",
                                             collapsed: scenario == "collapsed" ? true : nil, selection: scenario == "collapsed" ? "A" : nil,
                                             layout: split.isEmpty ? nil : "focused", split: split.isEmpty ? nil : split, splitFocus: split.last,
                                             composingNew: draft || scenario.hasPrefix("stale"),
                                             draft: scenario == "text-draft" ? "Unsent Live startup text" : scenario == "stale-empty-text" ? "" : nil,
                                             project: nil, device: "mac")
                    let memory = CoreMemoryStorage()
                    let seed = LocalPresentationState(store: ConversationStore(), scope: label, storage: memory)
                    func state(_ s: SavedWindow, index: Int) -> LocalPresentationState.WindowState {
                        let payload = try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(s))
                        return .init(id: "window-\(index)", payload: payload,
                                     files: scenario == "file-draft" ? [.init(attachment)] : nil)
                    }
                    var states = scenario == "fallback" ? [] : [state(record, index: 0)]
                    if scenario == "multi" {
                        let second = SavedWindow(frame: [frame.minX + 8, frame.minY + 8, frame.width, frame.height],
                                                 normie: !normie, members: ["D", "E"], current: "E")
                        states.append(state(second, index: 1))
                    }
                    seed.setWindows(states)
                    do { try seed.save() } catch { check(false, label + " prepares local presentation") }
                    let app = AppController(Options(), windowDefaults: defaults, presentsWindows: false)
                    let transport = NoNetwork()
                    let presentation = LocalPresentationState(store: app.store, scope: label, storage: memory)
                    let live = LiveConversationRuntime(store: app.store, client: transport, presentation: presentation)
                    app.live = live; app.runtime = live
                    let first = OrganicWindow(app: app, frame: frame, screen: screen, members: [], normie: true, o: app.o)
                    app.windows = [first]
                    check(first.workbench.composingNew && first.scene.members.isEmpty, label + " starts from the real Live placeholder")
                    app.store.updateDevices([Device(id: "mac", name: "Fixture Core host", kind: .server, online: true)])
                    for (index, id) in ["A", "B", "C", "D", "E", "F"].enumerated() {
                        let c = Conversation(id: id, title: "Hydrated " + id)
                        c.isLiveConversation = true
                        c.updated = Date(timeIntervalSince1970: 1_000 + Double(index))
                        app.store.add(c)
                    }
                    let latest = app.store.conversations.filter { !$0.archived }.max { $0.updated < $1.updated }?.id ?? ""
                    check(!latest.isEmpty && app.store.usesLiveCore, label + " hydrates a Live store without mock playback")
                    app.restoreLive()
                    AppWindowLifetimeVerification.drain(0.12)
                    check(app.windows.first === first, label + " reuses the initial owner")
                    let expectedMode: WindowShell.Mode = scenario == "fallback" ? .normie : normie ? .normie : .organic
                    check(first.shell.mode == expectedMode, label + " restores mode")
                    let activeDraft = first.shell.mode == .normie ? first.workbench.composingNew : first.scene.composingNew
                    check(activeDraft == draft, label + " restores draft state")
                    if !draft {
                        let expectedCurrent = scenario == "fallback" ? latest : record.current
                        check(first.scene.current == expectedCurrent, label + " restores the saved current")
                        check(first.workbench.selectedConversation != nil &&
                              (!split.isEmpty && first.shell.mode == .organic || first.workbench.selectedConversation?.id == expectedCurrent),
                              label + " selects an existing conversation instead of the placeholder")
                        check(!first.scene.composingNew && !first.workbench.composingNew, label + " clears both placeholder draft flags")
                        check(SavedWindow.make(first).composingNew != true, label + " cannot persist a phantom draft")
                    } else {
                        check(SavedWindow.make(first).composingNew == true, label + " keeps a genuine New Chat")
                        if scenario == "text-draft" {
                            check(first.scene.composers.draft().composer.text == record.draft, label + " preserves unsent text")
                        } else if scenario == "file-draft" {
                            check(first.scene.composers.draft().composer.attachments.map(\.id) == [attachment.id], label + " preserves unsent attachments")
                        }
                    }
                    if scenario != "fallback" {
                        check(first.scene.members.map(\.id) == members, label + " restores members in order")
                        check(first.window.frame == frame, label + " restores frame")
                    }
                    check(first.scene.scheme.split == split, label + " restores Focused or Split")
                    if scenario == "split" {
                        check(first.scene.scheme.left.isEmpty && first.scene.scheme.right == ["B"], label + " preserves the original Split orb banks")
                    }
                    if let payload = try? JSONEncoder().encode(SavedWindow.make(first)), let text = String(data: payload, encoding: .utf8) {
                        print("LIVE-RESTORE \(label): sceneDraft=\(first.scene.composingNew) workbenchDraft=\(first.workbench.composingNew) \(text)")
                    }
                    if let focus = split.last { check(first.scene.focusTarget == focus, label + " restores Split focus") }
                    if scenario == "multi" {
                        check(app.windows.count == 2 && app.windows[1].scene.current == "E" && app.windows[1].workbench.selectedConversation?.id == "E",
                              label + " restores the second owner and its selection")
                        check(app.windows[1].shell.mode == (normie ? .organic : .normie), label + " restores the second mode")
                    }
                    if scenario == "collapsed" {
                        // The visibility gate skips deferred collapse in this hidden fixture; exercise its production target directly.
                        first.collapseToSide(record.selection)
                        AppWindowLifetimeVerification.drain(0.4)
                        check(first.isCollapsed && first.strip?.shown == "A", label + " can collapse the restored non-draft owner")
                        let saved = SavedWindow.make(first)
                        check(saved.collapsed == true && saved.normie == normie && saved.current == record.current && saved.frame == record.frame,
                              label + " retains the normal presentation under Collapse")
                    }
                    let count = app.windows.count
                    app.restoreLive()
                    check(app.windows.count == count, label + " restores once")
                    check(transport.calls == 0 && app.core == nil && NSApp.windows.allSatisfy { !$0.isVisible }, label + " stays offscreen without Core")
                    for w in app.windows { w.window.close() }
                    if !draft && scenario != "multi" && scenario != "collapsed" {
                        check(app.windowRecords().first?.saved.composingNew != true, label + " persists a clean last-close record")
                    }
                    if scenario == "fallback" {
                        app.installMainMenu()
                        let menu = NSApp.mainMenu!
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                    characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
                        check(NSApp.keyWindow == nil, label + " has no key window before menu routing")
                        check(menu.performKeyEquivalent(with: event), label + " native menu accepts synthetic Cmd+N")
                        check(app.windows.count == 1 && app.windows.first?.workbench.composingNew == true && app.windows.first?.scene.members.isEmpty == true,
                              label + " Live Cmd+N creates a fresh draft without a Core request")
                        check(transport.calls == 0 && NSApp.mainMenu === menu && NSApp.windows.allSatisfy { !$0.isVisible },
                              label + " menu creation remains local and hidden")
                        for w in app.windows { w.window.close() }
                        // A byte-identical snapshot is cached, so change local state before forcing a write error.
                        app.store.conversation("F")?.draft = "Force a distinct local presentation snapshot"
                        memory.writeError = CoreWire.failure("Synthetic presentation write failure")
                        let unsaved = app.newChatWindow(present: false)
                        check(unsaved != nil && app.windows.count == 1 && unsaved?.workbench.composingNew == true,
                              label + " persistence failure cannot silently discard the new owner")
                        check(app.liveError != nil && transport.calls == 0, label + " records a local save error without a Core call")
                        memory.writeError = nil
                        for w in app.windows { w.window.close() }
                    }
                    live.shutdown()
                    AppWindowLifetimeVerification.drain()
                }
            }
        }
    }
}
