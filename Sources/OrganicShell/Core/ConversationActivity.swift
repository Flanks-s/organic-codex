import Foundation

/// Live event identity for finite orb feedback. History hydration does not advance this projection.
struct ConversationActivity {
    private(set) var serial: UInt64 = 0
    private var seen: [Int] = []
    private var turnID: String?
    private var completedSteps: Set<Int> = []

    @MainActor mutating func consume(_ event: CoreEvent, in c: Conversation) {
        let p = event.params
        guard !seen.contains(event.id) else { return }
        let incomingTurn = p["turnId"]?.stringValue ?? p["turn"]?["id"]?.stringValue
        if event.method != "turn/started", let incomingTurn, let turnID, incomingTurn != turnID { return }
        if let turn = p["turnId"]?.stringValue ?? p["turn"]?["id"]?.stringValue,
           let active = c.activeTurnID, turn != active { return }
        let relevant: Bool
        switch event.method {
        case "turn/started":
            if incomingTurn != turnID { completedSteps.removeAll(); turnID = incomingTurn }
            relevant = true
        case "turn/completed", "core/approvalRequested", "error": relevant = true
        case "item/started":
            let type = p["item"]?["type"]?.stringValue
            relevant = type == "commandExecution" || (type == "fileChange" && p["item"]?["changes"]?.arrayValue?.isEmpty == false)
        case "item/completed": relevant = p["item"]?["id"]?.stringValue != nil && p["item"]?["type"]?.stringValue != "userMessage"
        case "turn/plan/updated":
            let completed = Set((p["plan"]?.arrayValue ?? []).enumerated().compactMap { index, step in
                step["status"]?.stringValue == "completed" ? index : nil
            })
            relevant = !completed.subtracting(completedSteps).isEmpty
            completedSteps.formUnion(completed)
        // Streaming text, reasoning, command output and patch output never animate the liquid.
        default: relevant = false
        }
        guard relevant else { return }
        seen.append(event.id)
        if seen.count > 64 { seen.removeFirst(seen.count - 64) }
        serial &+= 1
    }
}
