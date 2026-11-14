import Foundation

/// A temporary projection at an explicit Core event watermark. Used only while hydrating one chat.
/// Existing native objects remain alive; snapshots provide history that predates Core's event log.
@MainActor final class HistoryReplay {
    let state: Conversation
    private(set) var turnIDs: Set<String> = []
    private(set) var cursor: Int
    private(set) var completed: [CoreEvent] = []
    private(set) var authoritativeItemIDs: Set<String> = []
    private(set) var partialItemIDs: Set<String> = []
    private(set) var needsFinalSnapshot = false
    private var completedItemIDs: Set<String> = []
    private var hasLifecycle = false
    private var starts: [CoreEvent] = []
    private var latestLifecycle: CoreEvent?
    private var baselineNotice: ConversationNoticeSnapshot?
    private(set) var lifecycleTurnIDs: Set<String> = []
    private let initialCursor: Int
    private var metadataCursors: [String: Int] = [:]
    private var collabEvents: [CoreEvent] = []

    init(conversation c: Conversation, cursor: Int, seeded: Bool, trustedItemIDs: Set<String>? = nil) {
        self.cursor = cursor
        initialCursor = cursor
        state = Conversation(id: c.id, title: c.title)
        state.projectID = c.projectID; state.updated = c.updated; state.contextUsed = c.contextUsed
        if seeded {
            state.phaseFacts=c.phaseFacts
            baselineNotice = c.notices.snapshot(in: c)
            authoritativeItemIDs = trustedItemIDs ?? Set(c.items.map(\.id))
            state.items = c.items; state.satellites = c.satellites; state.satellitesRetired = c.satellitesRetired; state.activeTurnID = c.activeTurnID; state.running = c.running
            state.approvals = c.approvals; state.userInput = c.userInput; state.question = c.question
            state.stopping = c.stopping; state.stops = c.stops; state.lastTurnInterrupted = c.lastTurnInterrupted; state.error = c.error
            turnIDs = Set(c.items.map(\.turnID).filter { !$0.isEmpty })
            hasLifecycle = true
        }
        state.plan = c.plan; state.exactTokensUsed = c.exactTokensUsed; state.contextLimit = c.contextLimit
    }

    /// Separate per-field cursors admit buffered SSE missing from an event page,
    /// without applying older usage/plan over a newer event already replayed.
    func applyMetadata(_ event: CoreEvent, through high: Int) {
        guard ["turn/plan/updated", "thread/tokenUsage/updated"].contains(event.method),
              event.id > (metadataCursors[event.method] ?? initialCursor), event.id <= high else { return }
        metadataCursors[event.method] = event.id
        EventReducer.apply(event, to: state)
    }

    func apply(_ event: CoreEvent, through highWatermark: Int) {
        guard event.id > cursor, event.id <= highWatermark else { return }
        cursor = event.id
        if let turn = event.params["turnId"]?.stringValue ?? event.params["turn"]?["id"]?.stringValue { turnIDs.insert(turn) }
        if event.method == "turn/started" || event.method == "turn/completed" {
            hasLifecycle = true
            if let turn = event.params["turnId"]?.stringValue ?? event.params["turn"]?["id"]?.stringValue { lifecycleTurnIDs.insert(turn) }
        }
        if event.method == "turn/started" || (event.method == "turn/completed" && (state.activeTurnID == nil || state.activeTurnID == (event.params["turnId"]?.stringValue ?? event.params["turn"]?["id"]?.stringValue))) {
            latestLifecycle = event
        }
        if event.method == "turn/started" { starts.append(event) }
        if event.method == "turn/completed" { completed.append(event) }
        if ["item/started", "item/completed"].contains(event.method), let id = event.params["item"]?["id"]?.stringValue {
            authoritativeItemIDs.insert(id)
            partialItemIDs.remove(id)
            if event.method == "item/completed" { completedItemIDs.insert(id) }
        } else if let id = event.params["itemId"]?.stringValue, event.params["delta"]?.stringValue != nil, !authoritativeItemIDs.contains(id) {
            partialItemIDs.insert(id)
        }
        if ["item/started", "item/completed"].contains(event.method), event.params["item"]?["type"]?.stringValue == "collabAgentToolCall" { collabEvents.append(event) }
        if ["turn/plan/updated", "thread/tokenUsage/updated"].contains(event.method) { applyMetadata(event, through: highWatermark) }
        else { EventReducer.apply(event, to: state) }
    }

    func merge(into c: Conversation, snapshot: JSONValue? = nil) {
        let snapshotTurns = snapshot?["turns"]?.arrayValue ?? []
        let orderedIDs = snapshotTurns.compactMap { $0["id"]?.stringValue }
        let terminalIDs = Set(snapshotTurns.filter { ["completed", "interrupted", "failed"].contains($0["status"]?.stringValue ?? "") }.compactMap { $0["id"]?.stringValue })
        let completedIDs = Set(completed.compactMap { event -> String? in
            guard let turn = event.params["turn"], ["completed", "interrupted", "failed"].contains(turn["status"]?.stringValue ?? "") else { return nil }
            return turn["id"]?.stringValue
        })
        needsFinalSnapshot = snapshotTurns.contains { turn in
            guard turn["status"]?.stringValue == "inProgress", let id = turn["id"]?.stringValue, completedIDs.contains(id) else { return false }
            let items = turn["items"]?.arrayValue ?? []
            return items.isEmpty || items.contains { item in
                guard let itemID = item["id"]?.stringValue else { return true }
                return !authoritativeItemIDs.contains(itemID)
            }
        }
        let old = Dictionary(uniqueKeysWithValues: c.items.map { ($0.id, $0) })
        let replayRows = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: state.items, by: \.turnID)
        var inserted: Set<String> = []
        var output: [TranscriptItem] = []
        let snapshotGroups = Dictionary(grouping: c.items, by: \.turnID)
        // A lifecycle event or an unversioned delta does not establish complete item content.
        // Keep snapshot siblings and ordering; only a proven item baseline may replace a row.
        for row in c.items where inserted.insert(row.turnID).inserted {
            let rows = snapshotGroups[row.turnID] ?? []
            let ids = Set(rows.map(\.id))
            output += rows.map { previous in
                guard authoritativeItemIDs.contains(previous.id), let replacement = replayRows[previous.id] else { return previous }
                // An old partial stream must not truncate an already terminal snapshot.
                if terminalIDs.contains(previous.turnID), !completedItemIDs.contains(previous.id) { return previous }
                return replacement
            }
            output += (grouped[row.turnID] ?? []).filter { !ids.contains($0.id) }
        }
        for row in state.items where !inserted.contains(row.turnID) { output.append(row) }
        var terminalReplay: [String: String] = [:]
        for event in completed {
            if let turn = event.params["turn"], let id = turn["id"]?.stringValue,
               let status = turn["status"]?.stringValue, ["completed", "interrupted", "failed"].contains(status) {
                terminalReplay[id] = status
            }
        }
        // Completion owns status for its own rows even when another turn is now active.
        // It supplies no authority to replace those rows' text.
        for i in output.indices where output[i].status == "running" {
            if let status = terminalReplay[output[i].turnID] { output[i].status = status == "interrupted" ? "interrupted" : nil }
        }
        for i in output.indices {
            if let previous = old[output[i].id] {
                output[i].revision = previous.revision
                output[i].timestamp = previous.timestamp ?? output[i].timestamp
                if output[i] != previous { output[i].revision += 1 }
            }
        }
        c.items = output
        // Terminal snapshot rows are immutable baselines; active snapshot-only rows remain
        // untrusted on subsequent reads because thread/read has no event watermark.
        for row in c.items where terminalIDs.contains(row.turnID) {
            authoritativeItemIDs.insert(row.id); partialItemIDs.remove(row.id)
        }
        var replaceLifecycle = hasLifecycle
        if let candidate = state.activeTurnID {
            // A turn ID cannot become running again after its terminal snapshot. A genuinely
            // new turn absent from the snapshot is still allowed when replay observed its start.
            if terminalIDs.contains(candidate) { replaceLifecycle = false }
            else if let snapshotActive = c.activeTurnID, snapshotActive != candidate {
                if let candidateIndex = orderedIDs.firstIndex(of: candidate), let activeIndex = orderedIDs.firstIndex(of: snapshotActive), candidateIndex < activeIndex {
                    replaceLifecycle = false
                } else if !lifecycleTurnIDs.contains(candidate) { replaceLifecycle = false }
            }
        } else if let snapshotActive = c.activeTurnID, !lifecycleTurnIDs.contains(snapshotActive) {
            // Completion of an unrelated older turn cannot clear a newer active snapshot.
            replaceLifecycle = false
        }
        if replaceLifecycle {
            c.activeTurnID = state.activeTurnID; c.running = state.running; c.stopping = state.stopping; c.stops = max(c.stops, state.stops); c.lastTurnInterrupted = state.lastTurnInterrupted
        }
        mergeSatellites(into: c, snapshot: snapshot, replaceLifecycle: replaceLifecycle)
        c.approvals = state.approvals; c.userInput = state.userInput; c.question = state.question
        if metadataCursors["turn/plan/updated"] != nil { c.plan = state.plan }
        if metadataCursors["thread/tokenUsage/updated"] != nil {
            c.exactTokensUsed = state.exactTokensUsed; c.contextLimit = state.contextLimit
            c.contextUsed = state.contextUsed
        }
        let terminal = snapshotTurns.last { ["completed","failed","interrupted"].contains($0["status"]?.stringValue ?? "") }
        let replayIdentity = latestLifecycle.flatMap { $0.params["turnId"]?.stringValue ?? $0.params["turn"]?["id"]?.stringValue }
        let replayStatus = latestLifecycle?.method == "turn/completed" ? latestLifecycle?.params["turn"]?["status"]?.stringValue : nil
        var replayTerminal = replaceLifecycle && ["completed","failed","interrupted"].contains(replayStatus ?? "") ? replayIdentity : nil
        if let id = replayTerminal, !lifecycleTurnIDs.contains(id) { replayTerminal = nil }
        if let id = replayTerminal, let replayIndex = orderedIDs.firstIndex(of: id),
           let terminalID = terminal?["id"]?.stringValue, let terminalIndex = orderedIDs.firstIndex(of: terminalID), replayIndex < terminalIndex {
            replayTerminal = nil
        }
        // Select identity first. A snapshot row from another turn never supplies clock values.
        let identity = c.activeTurnID ?? replayTerminal ?? terminal?["id"]?.stringValue
        let recovered = snapshotTurns.first { $0["id"]?.stringValue == identity }
        let usesReplay = replaceLifecycle && identity.map { $0 == state.activeTurnID || lifecycleTurnIDs.contains($0) } == true
        let baseline = baselineNotice?.turnID == identity ? baselineNotice : nil
        let start = usesReplay ? starts.last { ($0.params["turnId"]?.stringValue ?? $0.params["turn"]?["id"]?.stringValue) == identity }?.time ?? baseline?.startedAt ?? recovered?["startedAt"]?.doubleValue : recovered?["startedAt"]?.doubleValue
        let end = usesReplay ? completed.last { ($0.params["turnId"]?.stringValue ?? $0.params["turn"]?["id"]?.stringValue) == identity }?.time ?? baseline?.endedAt ?? recovered?["completedAt"]?.doubleValue : recovered?["completedAt"]?.doubleValue
        let status = replayTerminal == identity && replayTerminal != nil ? replayStatus : recovered?["status"]?.stringValue
        c.notices.restore(in: c, started: start, ended: c.activeTurnID == nil ? end : nil,
                          confirmedTurn: identity, status: status)
        c.phaseFacts.mergeHistory(state.phaseFacts,turnID:identity,status:status,in:c)
    }

    private func mergeSatellites(into c: Conversation, snapshot: JSONValue?, replaceLifecycle: Bool) {
        let turns = snapshot?["turns"]?.arrayValue ?? []
        let snapshotTurn = turns.last(where: { $0["status"]?.stringValue == "inProgress" })?["id"]?.stringValue ?? turns.last?["id"]?.stringValue
        let replayTurn = latestLifecycle.flatMap { $0.params["turnId"]?.stringValue ?? $0.params["turn"]?["id"]?.stringValue } ?? state.activeTurnID
        let selectedTurn = replaceLifecycle ? replayTurn ?? snapshotTurn : snapshotTurn
        if replaceLifecycle, selectedTurn != snapshotTurn {
            c.satellites = state.satellites
        } else {
            // hydrate owns the snapshot baseline. Only actual collab events may
            // override it; the copied seed is not a new event for the same turn.
            let updates = collabEvents.filter { ($0.params["turnId"]?.stringValue ?? $0.params["turn"]?["id"]?.stringValue) == selectedTurn }
            if !updates.isEmpty {
                let projection = Conversation(id: c.id, title: c.title); projection.satellites = c.satellites
                for event in updates {
                    if let item = event.params["item"] {
                        EventReducer.upsert(item, turnID: selectedTurn ?? "", in: projection, completed: event.method == "item/completed", time: event.time)
                    }
                }
                c.satellites = projection.satellites
            }
            for i in c.satellites.indices {
                if let old = state.satellites.first(where: { $0.id == c.satellites[i].id }) {
                    c.satellites[i].items = old.items
                    if old.done && c.satellites[i].done { c.satellites[i].finishedOrder = old.finishedOrder }
                }
            }
        }
        if replaceLifecycle { c.satellitesRetired = state.satellitesRetired }
    }
}
