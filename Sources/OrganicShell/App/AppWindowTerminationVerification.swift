import AppKit
import Synchronization

/// AppKit sends willTerminate before closing its windows. Keep that order without terminating the test process.
@MainActor enum AppWindowTerminationVerification {
    private final class NoNetwork: CoreTransport {
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }
        func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
            count.withLock { $0 += 1 }
            throw CoreWire.failure("Network is forbidden in termination verification")
        }
        func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> {
            count.withLock { $0 += 1 }
            return AsyncThrowingStream { $0.finish() }
        }
    }
    static func run(defaults: UserDefaults, screen: NSScreen, check: (Bool, String) -> Void) {
        func encoded(_ records: [SavedWindow]) -> Data? {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(records)
        }
        let visible = screen.visibleFrame
        let frame: [Double] = [visible.minX + 30, visible.minY + 30, min(1080, visible.width - 80), min(700, visible.height - 80)]
        let input: JSONValue = .object(["type": .string("input_text"), "text": .string("Unsent synthetic attachment")])
        let chatInput: JSONValue = .object(["type": .string("input_text"), "text": .string("Unsent conversation attachment")])
        let chatFile = Attachment(id: "quit-chat-file", name: "Conversation file", symbol: "doc", input: chatInput)
        let file = Attachment(id: "quit-draft-file", name: "Unsent file", symbol: "doc", input: input)
        for liveMode in [false, true] {
            for scenario in ["auto", "focused", "split-draft", "manual"] {
                autoreleasepool {
                    let label = "Quit windows \(liveMode ? "Live" : "mock") \(scenario)"
                    var options = Options(); options.mock = true; options.live = false; options.ambient = false
                    let app = AppController(options, windowDefaults: defaults, presentsWindows: false)
                    let transport = NoNetwork(), memory = CoreMemoryStorage()
                    let presentation = LocalPresentationState(store: app.store, scope: label, storage: memory)
                    if liveMode {
                        let live = LiveConversationRuntime(store: app.store, client: transport, presentation: presentation)
                        app.live = live; app.runtime = live
                        app.store.updateDevices([Device(id: "mac", name: "Fixture host", kind: .server, online: true)])
                        for id in ["A", "B", "C", "D"] {
                            let c = Conversation(id: id, title: "Termination " + id)
                            c.isLiveConversation = true; app.store.add(c)
                        }
                    } else {
                        let replay = MockReplay(store: app.store); replay.start(live: false)
                    }
                    app.store.conversation("A")?.draft = "Unsent conversation draft"
                    app.store.conversation("A")?.attachments = [chatFile]
                    let split = scenario == "focused" ? ["C"] : scenario == "split-draft" ? ["C", "A"] : []
                    let organic = SavedWindow(frame: frame, normie: false, members: ["C", "B", "A"], current: "C",
                                              layout: split.isEmpty ? nil : "focused", split: split.isEmpty ? nil : split,
                                              splitFocus: split.last)
                    let draft = scenario == "split-draft"
                    let normie = SavedWindow(frame: [frame[0] + 12, frame[1] + 12, frame[2] - 20, frame[3] - 20],
                                             normie: true, members: ["D"], current: "D", composingNew: draft,
                                             draft: draft ? "Unsent New Chat draft" : nil, device: draft ? "mac" : nil)
                    _ = app.restoreWindows([.init(saved: organic), .init(saved: normie, files: liveMode && draft ? [file] : [])], present: false)
                    AppWindowLifetimeVerification.drain(0.12)
                    let owners = app.windows
                    let expected = owners.map(SavedWindow.make)
                    check(owners.count == 2 && owners[0].shell.mode == .organic && owners[1].shell.mode == .normie,
                          label + " has two owners in different modes")
                    check((expected.first?.split ?? []) == split, label + " starts with the requested layout")
                    @MainActor func durable() -> [SavedWindow] {
                        if liveMode {
                            return LocalPresentationState(store: ConversationStore(), scope: label, storage: memory).windows.compactMap(SavedWindow.from)
                        }
                        return SavedWindow.load(scope: app.windowScope, defaults: defaults)
                    }
                    @MainActor func matches(_ expected: [SavedWindow], _ phase: String) {
                        let actual = durable()
                        check(encoded(actual) == encoded(expected), label + " preserves every record field " + phase)
                        print("QUIT-WINDOWS \(label) \(phase): records=\(actual.count) expected=\(expected.count)")
                    }
                    if scenario == "manual" {
                        owners[0].window.close()
                        matches([expected[1]], "after manual first close")
                        owners[1].window.close()
                        matches([expected[1]], "after manual last close")
                        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                        matches([expected[1]], "after zero-window termination")
                    } else {
                        // Queue a store-triggered save before the termination snapshot.
                        if liveMode { presentation.observe(); presentation.scheduleSave() }
                        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                        matches(expected, "after willTerminate")
                        let sidecars = memory.attachmentInputs.values
                        // Also exercise the opposite AppKit window enumeration order.
                        let closing = scenario == "auto" ? owners : Array(owners.reversed())
                        for (index, owner) in closing.enumerated() {
                            owner.window.close()
                            matches(expected, "after termination close \(index + 1)")
                            if liveMode, let c = app.store.conversation("A") {
                                app.store.changed(c)
                                AppWindowLifetimeVerification.drain(0.25)
                                matches(expected, "after delayed presentation save \(index + 1)")
                            }
                        }
                        if liveMode {
                            app.live?.shutdown()
                            matches(expected, "after repeated runtime shutdown")
                            let recoveredStore = ConversationStore()
                            let recovered = LocalPresentationState(store: recoveredStore, scope: label, storage: memory)
                            recovered.restore()
                            check(recoveredStore.conversation("A")?.draft == "Unsent conversation draft", label + " keeps conversation draft after teardown")
                            check(recoveredStore.conversation("A")?.attachments.first?.input == chatInput, label + " keeps conversation attachment input")
                            check(memory.attachmentInputs.values == sidecars && !sidecars.isEmpty, label + " keeps all committed sidecar inputs")
                            if draft {
                                let files = recovered.restoreAttachments(recovered.windows.last?.files ?? [])
                                check(files.first?.input == input && files.first?.id == file.id, label + " keeps New Chat attachment input")
                            }
                            check(presentation.lastError == nil && app.live?.lastError == nil, label + " completes presentation writes without error")
                        }
                    }
                    check(app.windows.isEmpty, label + " still removes every closed owner")
                    check(owners.allSatisfy { !$0.window.isVisible && $0.window.delegate == nil && $0.window.contentView == nil },
                          label + " cleans up every hidden window")
                    check(transport.calls == 0, label + " never contacts Core")
                }
            }
        }
    }
}
