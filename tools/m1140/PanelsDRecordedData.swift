import AppKit

@MainActor final class FunctionPanelDStorage: CorePresentationStorage {
    let memory = CoreMemoryStorage()
    var writes = 0
    func read(key: String) throws -> Data? { try memory.read(key: key) }
    func write(_ data: Data, key: String) throws { writes += 1; try memory.write(data, key: key) }
}

/// The existing Sheet window seam, with no NSWindow and no orderFront call.
@MainActor final class FunctionPanelDWindow: SheetWindowHandle {
    let host: NSView = OverlayView(frame: CGRect(x: 0, y: 0, width: 420, height: 440))
    var title = "", presents = 0
    func present(at point: CGPoint?) { presents += 1 }
    func presentSheet(for parent: NSWindow) { preconditionFailure("No real windows in D") }
    func dismiss() {}
}

/// Same Store.apply/EventReducer recording as C. Only the allowlisted, in-process transport receives writes.
@MainActor final class FunctionPanelDRecordedData {
    let data = FunctionPanelCRecordedData()
    let wire = CoreControllerFixture()
    let storage = FunctionPanelDStorage()
    let presentation: LocalPresentationState
    let runtime: LiveConversationRuntime
    let windows: SheetSubAgentWindows
    var opens = 0
    var current: Conversation?
    var connected: Bool { get { runtime.isConnected } set { runtime.isConnected = newValue } }
    var capabilities: Set<String> = []
    var owner: FunctionPanelActionOwner!
    var child: Conversation { data.store.conversation("child-0")! }
    var satelliteID: String { data.conversation.satellites.first { $0.threadID == "child-0" }!.id }
    var body: String { BodyIdentityAdapter.choices.first { $0 != data.conversation.identitySymbol }! }
    var colour: String { BodyTintCatalogue.legacy.first { $0.id != data.conversation.identityTint }!.id }
    var operations: [FunctionPanelAction] { [.body(body), .fork, .stop, .openSubagent(satelliteID),
            .stopSubagent(satelliteID), .colour(colour)] }
    init() {
        presentation = LocalPresentationState(store: data.store, scope: "m1140-d-isolated", storage: storage,
                                              attachmentInputs: storage.memory.attachmentInputs)
        presentation.restore()
        runtime = LiveConversationRuntime(store: data.store, client: wire.transport, presentation: presentation)
        runtime.isConnected = true // Recorded connection acknowledgement; never start/load/connect a service.
        windows = SheetSubAgentWindows(factory: { _ , _ in FunctionPanelDWindow() })
        current = data.conversation
        windows.onOpen = { [weak self] _ in self?.opens += 1 }
        // Activate the real child through the reducer, never by assigning running/activeTurnID.
        data.emit("turn/started", ["turn": ["id": "child-active"]], thread: "child-0")
        let completed: JSONValue = ["id": "done", "status": "completed", "items": [
            ["id": "u1", "type": "userMessage", "content": [["type": "inputText", "text": "Question"]]],
            ["id": "a1", "type": "agentMessage", "text": "Answer"]]]
        wire.before = { [weak self] request in
            guard let self else { throw CoreWire.failure("Fixture closed") }
            let allowed = ["thread/read", "thread/fork", "turn/interrupt", "/health",
                           "thread/name/set", "thread/compact/start", "thread/archive", "thread/unarchive"]
            precondition(allowed.contains(request.key), "D must never send a model request")
            if let error = self.wire.failures[request.key] { throw error }
            switch request.key {
            case "thread/read": return ["thread": ["id": "t1", "name": "First", "turns": [completed]]]
            case "thread/fork": return ["thread": ["id": .string("fork-\(self.wire.count("thread/fork"))"),
                    "name": "First", "turns": [completed]]]
            case "turn/interrupt": return [:]
            case "thread/name/set", "thread/compact/start": return [:]
            default: return nil
            }
        }
        data.conversation.draft = "Unsent draft must survive"
        data.conversation.next.modelID = "recorded-next-model"
        data.conversation.next.effort = .high
        capabilities = Set(["fork", "stop", "sub.open." + satelliteID,
                "sub.stop." + satelliteID] + BodyIdentityAdapter.choices.map { "body." + $0 })
        capabilities.formUnion(BodyTintCatalogue.legacy.map { "colour." + $0.id })
        owner = FunctionPanelActionOwner(conversation: data.conversation, store: data.store, runtime: runtime,
            presentation: presentation, windows: windows, current: { [weak self] in self?.current },
            connected: { [weak self] in self?.connected == true }, capabilities: {
                [weak self] in self?.capabilities ?? [] },
            colours: BodyTintCatalogue.legacy.map { .init(id: $0.id, name: $0.name, bodyName: "",
                    hex: UInt32($0.hex.dropFirst(), radix: 16)!) })
    }
    func host(_ resources: BodyResources, scale: Int) -> FunctionPanelActionHost {
        FunctionPanelActionHost(conversation: data.conversation, store: data.store, resources: resources, scale: scale,
            commands: owner, read: { [weak self] _ in self?.data.sources ?? .init(id: "closed", revision: 0,
                    connected: false) })
    }
    func fail(_ action: FunctionPanelAction) -> String {
        let reason = "Recorded rejection · \(FunctionPanelActionOwner.key(action)!)"
        let error = CoreError(code: 409, message: reason, data: nil, httpStatus: 409)
        switch action {
        case .body, .colour: storage.memory.writeError = error
        case .fork: wire.failures["thread/fork"] = error
        case .stop, .stopSubagent: wire.failures["turn/interrupt"] = error
        case .openSubagent:
            let other = Conversation(id: "other-parent", title: "Other parent")
            other.isLiveConversation = true; other.satellites = data.conversation.satellites
            _ = windows.present(subagentID: satelliteID, of: other)
            return "The child conversation could not be opened."
        default: preconditionFailure("Not a connected D operation")
        }
        return reason
    }
}
