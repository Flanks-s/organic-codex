import AppKit

/// Only attention inputs invalidate the window projection. Transcript text/updated dates never do.
@MainActor final class SunHoverAttentionCache {
    private var members: Set<String> = [], inputs: [String: String] = [:]
    private var errorKeys: [String: [String]] = [:]
    private(set) var dependencies: Set<String> = []
    private(set) var projections = 0
    private(set) var value = SunHoverAttention(rows: [])
    let projection = SunHoverAttentionProjection()
    private func signature(_ c: Conversation) -> String {
        let approvals = c.approvals.map { "\($0.id):\($0.title):\($0.command)" }
        let question = c.userInput.map { "\($0.id):\($0.questions.map(\.prompt))" } ?? c.question ?? ""
        return "\(c.archived)|\(c.backendThreadID ?? "")|\(String(describing: c.error))|\(c.redEvents)|\(c.activeTurnID ?? "")|\(c.operationError ?? "")|\(approvals)|\(question)|\(c.satellites.compactMap(\.threadID))|\(c.title)"
    }
    @discardableResult func update(store: ConversationStore, members next: Set<String>, changed: Conversation? = nil, force: Bool = false) -> Bool {
        if !force, next == members, let changed {
            guard dependencies.contains(changed.id) || dependencies.contains(changed.backendThreadID ?? "") else { return false }
            let reviewed = errorKeys[changed.id]?.contains { store.attentionErrorWasReviewed(sourceID: changed.id, key: $0) } == true
            guard inputs[changed.id] != signature(changed) || reviewed else { return false }
        } else if !force, next == members, changed == nil { return false }
        members = next; dependencies = next; inputs = [:]
        var pending = Array(next), visited = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let c = store.conversation(id) ?? store.backendConversation(id) else { continue }
            dependencies.insert(c.id); if let tid = c.backendThreadID { dependencies.insert(tid) }
            inputs[c.id] = signature(c)
            for child in c.satellites.compactMap(\.threadID) { dependencies.insert(child); pending.append(child) }
        }
        projections += 1
        let fresh = projection.snapshot(store: store, memberIDs: next, at: Date().timeIntervalSince1970)
        errorKeys = [:]
        for row in fresh.rows {
            for event in row.events where event.severity <= .runningError { errorKeys[event.sourceID, default: []].append(event.key) }
        }
        let changedValue = value.rows != fresh.rows; value = fresh
        return changedValue
    }
}

extension SunHoverAttention {
    var badge: OrbBadge? {
        guard badgeCount > 0 else { return nil }
        return .init(tone: rows.contains { $0.mostSevere.severity <= .runningError } ? .red : .yellow, symbol: .count(badgeCount))
    }
}
