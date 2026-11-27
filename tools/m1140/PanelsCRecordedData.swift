import AppKit

/// Reuses the repository's recorded controller payloads and CoreVerification's
/// Question/Answer, printf fixture and fixture.swift protocol rows through Store.apply.
/// Only identity/routing bootstrap is assigned directly; transcript/facts are reducer-owned.
@MainActor final class FunctionPanelCRecordedData {
    let store = ConversationStore(conversations: [])
    let conversation: Conversation
    var sources: FunctionPanelReadSources
    private var serial = 100
    init(recordHistory: Bool = true) {
        conversation = Conversation(id: "t1", title: "First")
        let controller = CoreControllerFixture()
        sources = .init(id: "CoreControllerFixture/preview/artifacts", revision: 1,
                        artifacts: .known(controller.artifacts.map(CoreArtifact.init(raw:))), model: .unavailable,
                        fileEvidence: ["fixture.swift": .init(threadID: "t1", complete: true, reportedLines: ["+new"])])
        conversation.isLiveConversation = true; conversation.backendThreadID = "t1"
        store.add(conversation)
        guard recordHistory else { return }
        emit("thread/restored", ["thread": ["id": "t1", "name": "First", "turns": [["id": "done", "status": "completed",
                    "items": [
            ["id": "u1", "type": "userMessage", "text": "Question"],
            ["id": "commandExecution", "type": "commandExecution", "command": "printf fixture",
                "aggregatedOutput": "Recorded", "status": "completed"],
            ["id": "a1", "type": "agentMessage", "text": "Answer", "status": "completed"]]]]]])
        emit("item/completed", ["turnId": "done", "item": ["id": "fileChange", "type": "fileChange",
                    "changes": [["path": "fixture.swift", "diff": "+new"]]]])
        emit("turn/started", ["turn": ["id": "one"]])
        plan(2, 7)
        emit("thread/tokenUsage/updated", ["tokenUsage": ["last": ["totalTokens": 900], "modelContextWindow": 1000]])
        for index in 0..<3 {
            let id = "child-\(index)", child = Conversation(id: "child-\(index)", title: "Recorded child \(index + 1)")
            child.isLiveConversation = true; child.backendThreadID = id; store.add(child)
            emit("thread/restored", ["thread": ["id": .string(id), "name": .string(child.title),
                        "turns": [["id": "child-turn", "status": "completed", "items": [
                ["id": "child-answer", "type": "agentMessage", "text": .string(["Recorded item is complete",
                            "Command output is available", "Diff ownership was verified"][index])]]]]]], thread: id)
            emit("item/started", ["turnId": "one", "item": ["id": .string("collab-\(index)"),
                        "type": "collabAgentToolCall", "receiverThreadIds": [.string(id)]]])
        }
        // The saved-window read is a replay, so the real bridge supplies animate=false.
        // Existing reducer rows remain; no phase fact or transcript row is assigned by hand.
        let restoredPlan: [JSONValue] = (0..<7).map { ["step": .string("Step \($0)"),
                "status": .string($0 < 2 ? "completed" : "pending")] }
        let restoredChildren: [JSONValue] = (0..<3).map { ["id": .string("collab-\($0)"), "type": "collabAgentToolCall",
                "receiverThreadIds": [.string("child-\($0)")]] }
        emit("thread/restored", ["thread": ["id": "t1", "name": "First", "turns": [
            ["id": "done", "status": "completed", "items": []],
            ["id": "one", "status": "inProgress", "plan": .array(restoredPlan), "items": .array(restoredChildren)]]]])
    }
    func emit(_ method: String, _ payload: [String: JSONValue], thread: String = "t1") {
        serial += 1; var p = payload; p["threadId"] = .string(thread)
        store.apply(.init(id: serial, time: Double(serial), method: method, params: .object(p)))
    }
    func plan(_ completed: Int, _ count: Int, turn: String = "one") {
        emit("turn/plan/updated", ["turnId": .string(turn), "plan": .array((0..<count).map {
                    ["step": .string("Step \($0)"), "status": .string($0 < completed ? "completed" : "pending")] })])
    }
}

/// Cost-only convenience wrapper. All phase replacements still traverse Store/Reducer.
@MainActor final class FunctionPanelCCostHost: FunctionPanelLiveHost {
    let data: FunctionPanelCRecordedData
    // B's cost probe reduces stage motion but explicitly animates the phase reversal.
    override var allowsPhaseAnimation: Bool { true }
    init(resources: BodyResources, scale: Int, reduced: Bool = true) {
        let data = FunctionPanelCRecordedData(); self.data = data
        super.init(conversation: data.conversation, store: data.store, resources: resources, scale: scale,
            reduced: reduced, read: { _ in data.sources })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setPhase(_ input: FunctionPanelPhaseInput) {
        if data.conversation.phaseFacts.turnID != input.turnID { data.emit("turn/started",
                ["turn": ["id": .string(input.turnID)]]) }
        let count = 100, completed = Int((Double(input.event.value.fraction ?? 0) * 100).rounded())
        data.plan(completed, count, turn: input.turnID)
        refresh()
    }
}
