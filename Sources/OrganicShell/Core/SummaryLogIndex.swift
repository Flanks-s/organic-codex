import Foundation

/// Structural summary index, separate from paraphrasing and typography. Precise publications replay only the
/// changed suffix; a viewport asks for only its lines. No transcript arrays are retained (avoids delta-time COW).
@MainActor final class SummaryLogIndex {
    private struct Identity: Equatable { var id: String, turn: String, kind: RowKind }
    private struct State {
        var goal: Int?, start: Int?, thought: Int?, lastInput: Int?, opener: String?, activity: Int?
        var worked = false, hasWork = false, lines = 0
    }
    private enum Line { case goal(Int), input(Int), stretch(String, Int, Bool) }
    private var revision = -1, count = 0
    private var turn: String?, hasUser = false
    private var identities: [Identity] = [], indices: [Int] = [], positions: [Int: Int] = [:]
    private var byTurn: [String: [Int]] = [:]
    private var checkpoints: [State] = [], state = State(), lines: [Line] = []
    private var workTurns = Set<String>()
    private var plain: [String: (String, Paraphrase)] = [:], playful: [String: (String, Paraphrase)] = [:]
    private(set) var rebuilds = 0, replayedItems = 0

    private func identity(_ item: TranscriptItem) -> Identity { .init(id: item.id, turn: item.turnID, kind: item.rowKind) }
    func changed(_ c: Conversation, change: ConversationChange) {
        guard revision == c.revision - 1, let id = change.itemID, let i = c.transcriptItemIndex(id) else { revision = -1; return }
        if c.items.count == count, identities.indices.contains(i), identities[i] == identity(c.items[i]) {
            if let position = positions[i] {
                state = checkpoints[position]
                lines.removeSubrange(state.lines..<lines.count)
                checkpoints.removeSubrange(position..<checkpoints.count)
                for index in indices[position...] { consume(index, c) }
            }
        } else if c.items.count == count + 1, i == count {
            let item = c.items[i]
            identities.append(identity(item)); byTurn[item.turnID, default: []].append(i)
            if item.rowKind != .user { workTurns.insert(item.turnID) }
            let nextTurn = item.rowKind == .user || !hasUser ? item.turnID : turn
            hasUser = hasUser || item.rowKind == .user
            if nextTurn == turn {
                if item.turnID == turn { positions[i] = indices.count; indices.append(i); consume(i, c) }
            } else {
                turn = nextTurn; indices = byTurn[item.turnID] ?? []; positions = [:]; checkpoints = []; lines = []; state = State()
                for (position, index) in indices.enumerated() { positions[index] = position; consume(index, c) }
            }
            count += 1
        } else { revision = -1; return }
        revision = c.revision
    }
    private func ensure(_ c: Conversation) {
        guard revision != c.revision || count != c.items.count else { return }
        rebuilds += 1; revision = c.revision; count = c.items.count
        let user = c.items.last(where: { $0.kind == .user })
        hasUser = user != nil; turn = user?.turnID ?? c.items.last?.turnID
        workTurns = Set(c.items.lazy.filter { $0.rowKind != .user }.map(\.turnID))
        identities = c.items.map(identity); byTurn = [:]; indices = []; positions = [:]; checkpoints = []; lines = []; state = State()
        for i in c.items.indices { byTurn[c.items[i].turnID, default: []].append(i) }
        plain = [:]; playful = [:]
        for i in c.items.indices where c.items[i].turnID == turn {
            positions[i] = indices.count; indices.append(i); consume(i, c)
        }
    }
    private func consume(_ i: Int, _ c: Conversation) {
        checkpoints.append(state); replayedItems += 1
        let item = c.items[i]
        if item.rowKind == .user {
            if state.goal == nil { state.goal = i; lines.append(.goal(i)) } else { lines.append(.input(i)) }
            if state.opener == nil { state.opener = item.id }; state.lastInput = i
        } else {
            state.hasWork = true
            if TranscriptPresentation.isActivity(item.rowKind) {
                if state.start == nil { state.start = i }
                if item.rowKind == .reasoning { state.thought = i }
                state.worked = true; state.activity = i
            } else if item.rowKind == .assistant {
                if state.start == nil { state.start = i }
                if !TranscriptPresentation.presentation(for: item).isProgress {
                    lines.append(.stretch("after:" + (state.opener ?? c.items[state.start ?? i].id), i, state.worked))
                    state.start = nil; state.thought = nil; state.worked = false; state.opener = item.id
                }
            }
        }
        state.lines = lines.count
    }
    private func status(_ c: Conversation) -> SummaryLog.State {
        if !c.approvals.isEmpty { return .waiting }
        if c.error == .stopped { return .failedStopped }; if c.error == .running { return .failedRunning }
        if c.question != nil || c.userInput != nil { return .asking }
        if c.running { return .running }; return state.hasWork ? .done : .idle
    }
    private func open(_ c: Conversation, playful: Bool) -> SummaryLog.Stretch? {
        guard state.start != nil || (c.running && state.opener != nil) else { return nil }
        let fresh = state.thought.flatMap { (state.lastInput ?? -1) < $0 ? $0 : nil }
        let narration = fresh.map { paraphrase(c.items[$0], playful: playful) }
        let s = status(c)
        guard narration != nil || s == .running || s == .failedRunning else { return nil }
        return .init(id: "after:" + (state.opener ?? c.items[state.start ?? 0].id), answerID: nil, workedFor: nil, narration: narration, order: Int.max)
    }
    private func paraphrase(_ item: TranscriptItem, playful usePlayful: Bool) -> Paraphrase {
        if let cached = (usePlayful ? playful : plain)[item.id], cached.0 == item.text { return cached.1 }
        let value = MockBrief.paraphrase(item.text, of: item.id, playful: usePlayful)
        if usePlayful { playful[item.id] = (item.text, value) } else { plain[item.id] = (item.text, value) }
        return value
    }
    func lastTurnHasWork(_ c: Conversation) -> Bool {
        ensure(c)
        return c.items.last.map { workTurns.contains($0.turnID) } ?? false
    }
    func lineCount(_ c: Conversation) -> Int { ensure(c); return lines.count + (open(c, playful: false) == nil ? 0 : 1) }
    func log(_ c: Conversation, playful: Bool, range: Range<Int>? = nil, limit: Int? = nil) -> SummaryLog {
        ensure(c)
        let pending = open(c, playful: playful), total = lines.count + (pending == nil ? 0 : 1)
        let requested = range ?? max(0, total - (limit ?? total))..<total
        let lower = max(0, min(total, requested.lowerBound)), upper = max(lower, min(total, requested.upperBound))
        var log = SummaryLog(); log.state = status(c)
        if let i = state.activity, TranscriptPresentation.presentation(for: c.items[i]).isProgress {
            log.activity = .init(itemID: c.items[i].id, parts: TranscriptPresentation.activityParts(c.items[i], presentation: TranscriptPresentation.presentation(for: c.items[i])))
        }
        for k in lower..<upper {
            if k == lines.count { if let pending { log.stretches.append(pending) }; continue }
            switch lines[k] {
            case .goal(let i):
                let item = c.items[i]; log.goal = .init(itemID: item.id, text: (item.text as NSString).substring(with: TranscriptPresentation.firstLine(of: item.text as NSString)))
            case .input(let i):
                let item = c.items[i]; log.inputs.append(.init(itemID: item.id, text: (item.text as NSString).substring(with: TranscriptPresentation.firstLine(of: item.text as NSString)), order: i))
            case .stretch(let id, let i, let worked):
                log.stretches.append(.init(id: id, answerID: c.items[i].id, workedFor: worked ? TranscriptPresentation.workedFor(index: i, items: c.items) : nil, narration: paraphrase(c.items[i], playful: playful), order: i))
            }
        }
        return log
    }
}

extension Conversation {
    var summarySource: SummaryLogIndex {
        if let summaryIndex { return summaryIndex }
        let value = SummaryLogIndex(); summaryIndex = value; return value
    }
}
