import Foundation

/// Shared semantic facts for Pulse, Tide and Constellation. Presentation never inspects command text.
enum NoticeHalo: String, Equatable, Sendable {
    case none, card, column

    static func classify(_ notice: ConversationNotice) -> Self {
        switch notice.kind {
        case .done, .approval, .question:
            return notice.kind == .approval && approvalLeavesSandbox(notice.request, workspace: notice.workspace) ? .column : .card
        case .stoppedError: return .column
        case .context: return (notice.context ?? 0) >= 0.9 ? .column : .none
        default: return .none
        }
    }

    /// Only explicit request fields establish scope. Unknown scope stays card-sized.
    static func approvalLeavesSandbox(_ request: JSONValue, workspace: String?) -> Bool {
        let p = request["params"] ?? request
        if p["sandbox_permissions"]?.stringValue == "require_escalated"
            || p["sandboxPermissions"]?.stringValue == "requireEscalated"
            || p["requiresElevation"]?.boolValue == true
            || p["networkAccess"]?.boolValue == true { return true }
        let permissions = p["permissions"] ?? p["additionalPermissions"]
        if permissions?["network"]?["enabled"]?.boolValue == true
            || permissions?["networkAccess"]?.boolValue == true { return true }
        if p["writesOutsideWorkspace"]?.boolValue == true { return true }
        let paths = permissions?["fileSystem"]?["write"]?.arrayValue
            ?? permissions?["file_system"]?["write"]?.arrayValue
            ?? p["writableRoots"]?.arrayValue ?? []
        guard let workspace, workspace.hasPrefix("/") else { return false }
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.path
        return paths.compactMap(\.stringValue).contains { path in
            // A relative or otherwise unresolved path supplies no evidence of an escape.
            guard path.hasPrefix("/") else { return false }
            let target = URL(fileURLWithPath: path).standardizedFileURL.path
            return target != root && !target.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }
}

enum ConversationNoticeAction: Equatable, Sendable {
    case approval(String, JSONValue)
    case answer(String, [String: [String]])
    case review
}

struct ConversationNotice: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case command, step, spawn, finish, tests, approval, question, retryingError, stoppedError, done, context, compacted, reply
    }
    struct Button: Equatable, Sendable {
        var title: String
        var action: ConversationNoticeAction
    }
    var id: Int = 0
    var kind: Kind
    var text: String
    var requestID: String?
    var request: JSONValue = .null
    var workspace: String?
    var context: Double?
    var buttons: [Button] = []
    var progress: Double?
    var submitting = false
    var halo: NoticeHalo { NoticeHalo.classify(self) }
    var urgent: Bool {
        [.approval, .question, .retryingError, .stoppedError].contains(kind) || halo == .column
    }
    var hold: Double {
        switch kind {
        case .command, .done: 3
        case .step, .tests, .context, .compacted: 2.4
        case .spawn: 2
        case .finish: 2.2
        case .approval, .question: 7
        case .retryingError, .stoppedError: 5
        case .reply: 1.8
        }
    }
}

struct ConversationNoticeSnapshot: Equatable {
    var journal: [ConversationNotice] = []
    var pending: [ConversationNotice] = []
    var running = false
    var startedAt: Double?
    var endedAt: Double?
    var progress: Double?
    var terminalStatus: String?
    var turnID: String?
}

/// Bounded, per-conversation event projection. Mock store.apply and the live reducer share this exact path.
/// History's apply-only API deliberately does not replay old notifications as fresh arrivals.
struct ConversationNoticeFeed {
    private(set) var journal: [ConversationNotice] = []
    private var serial = 0
    private var startedAt: Double?, endedAt: Double?
    private var contextBand = 0
    private var activeCommand: String?
    private var lastTurnID: String?
    private var terminalTurnID: String?
    private var testProgress: Double?
    private var terminalStatus: String?
    private var satelliteStates: [String: Bool]?

    private mutating func emit(_ notice: ConversationNotice) {
        serial += 1
        var notice = notice; notice.id = serial
        journal.append(notice)
        if journal.count > 32 { journal.removeFirst(journal.count - 32) }
    }

    @MainActor mutating func consume(_ event: CoreEvent, in c: Conversation) {
        let p = event.params
        let turn = p["turnId"]?.stringValue ?? p["turn"]?["id"]?.stringValue
        if let turn, let current = lastTurnID, current != turn, event.method != "turn/started" { return }
        switch event.method {
        case "turn/started":
            guard turn != lastTurnID else { return }
            lastTurnID = turn; terminalTurnID = nil; terminalStatus = nil
            startedAt = event.time ?? Date().timeIntervalSince1970; endedAt = nil; testProgress = nil; satelliteStates = [:]
            emit(.init(kind: .command, text: "Working"))
        case "turn/completed":
            guard let turn, terminalTurnID != turn else { return }
            terminalTurnID = turn; endedAt = event.time ?? Date().timeIntervalSince1970; testProgress = nil
            let status = p["turn"]?["status"]?.stringValue
            terminalStatus = status
            if status == "failed" {
                emit(.init(kind: .stoppedError, text: p["turn"]?["error"]?["message"]?.stringValue ?? "Stopped by an error"))
            } else if status == "completed", !c.lastTurnInterrupted {
                let elapsed = startedAt.map { max(0, (endedAt ?? $0) - $0) }
                let time = elapsed.map { " in \(Int($0) / 60)m \(Int($0) % 60)s" } ?? ""
                let files = c.changes.isEmpty ? "" : " · \(c.changes.count) files changed"
                emit(.init(kind: .done, text: "Done" + time + files))
            }
        case "item/started", "item/completed":
            guard let item = p["item"] else { return }
            let completed = event.method == "item/completed"
            switch item["type"]?.stringValue {
            case "commandExecution":
                let command = item["command"]?.stringValue ?? "Command"
                activeCommand = item["id"]?.stringValue
                emit(.init(kind: completed ? .step : .command, text: completed ? "Finished · " + command : "Running " + command))
            case "fileChange" where completed:
                emit(.init(kind: .step, text: "Edited " + (item["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue }.joined(separator: ", ") ?? "files")))
            default: break
            }
        case "item/commandExecution/outputDelta":
            if p["itemId"]?.stringValue == activeCommand,
               let index = journal.indices.last, journal[index].kind == .command,
               let id = activeCommand, let row = c.transcriptItemIndex(id) {
                let lines = c.items[row].text.split(separator: "\n").filter { !$0.isEmpty }
                if let last = lines.last { journal[index].text = String(last.suffix(240)) }
            }
        case "turn/plan/updated":
            if !c.plan.isEmpty { emit(.init(kind: .step, text: "Plan steps \(c.plan.filter(\.done).count)/\(c.plan.count) complete")) }
        case "core/approvalRequested":
            if let id = p["approvalId"]?.stringValue,
               let notice = Self.pending(in: c).first(where: { $0.requestID == id }) { emit(notice) }
        case "core/approvalResponded": emit(.init(kind: .reply, text: "Response received"))
        case "core/approvalExpired": emit(.init(kind: .reply, text: "Request expired"))
        case "error":
            emit(.init(kind: p["willRetry"]?.boolValue == true ? .retryingError : .stoppedError,
                       text: (p["willRetry"]?.boolValue == true ? "Error · still working: " : "Stopped: ") + (c.operationError ?? "Core error")))
        case "thread/tokenUsage/updated":
            guard let used = c.exactTokensUsed, let limit = c.contextLimit, limit > 0 else { return }
            let fraction = Double(used) / Double(limit), band = fraction >= 0.9 ? 2 : fraction >= 0.8 ? 1 : 0
            if band > contextBand { emit(.init(kind: .context, text: "Context \(Int((fraction * 100).rounded()))% used", context: fraction)) }
            contextBand = band
        case "thread/compacted":
            contextBand = 0
            emit(.init(kind: .compacted, text: "Context compacted"))
        case "core/pulseProgress":
            // Synthetic producer until Core supplies structured test counts. Never inferred from output text.
            guard let done = p["completed"]?.intValue, let total = p["total"]?.intValue, total > 0, done >= 0, done <= total else { return }
            testProgress = done < total ? Double(done) / Double(total) : nil
            emit(.init(kind: .tests, text: "Tests \(done)/\(total)", progress: Double(done) / Double(total)))
        default: break
        }
    }

    @MainActor func snapshot(in c: Conversation) -> ConversationNoticeSnapshot {
        .init(journal: journal, pending: Self.pending(in: c), running: c.running, startedAt: startedAt, endedAt: endedAt,
              progress: testProgress, terminalStatus: terminalStatus, turnID: lastTurnID)
    }

    /// History establishes a baseline without producing arrivals. Keep the journal cursor monotonic.
    @MainActor mutating func restore(in c: Conversation, started: Double? = nil, ended: Double? = nil,
                                     confirmedTurn: String? = nil, status: String? = nil) {
        if let active=c.activeTurnID {
            // Metadata is usable only when its source identity matches the merged active turn.
            let started = confirmedTurn == active ? started : nil
            let ended = confirmedTurn == active ? ended : nil
            if lastTurnID != active {
                lastTurnID=active; terminalTurnID=nil; terminalStatus=nil
                activeCommand=nil; testProgress=nil; startedAt=started; endedAt=ended
            } else {
                if let started { startedAt=started }; if let ended { endedAt=ended }
            }
        } else if let confirmedTurn, let status, ["completed","failed","interrupted"].contains(status) {
            if lastTurnID != confirmedTurn { startedAt=started; endedAt=ended }
            else { if let started { startedAt=started }; if let ended { endedAt=ended } }
            lastTurnID=confirmedTurn; terminalTurnID=confirmedTurn; terminalStatus=status
            activeCommand=nil; testProgress=nil
        } else if terminalTurnID == nil {
            lastTurnID=nil; terminalStatus=nil; startedAt=nil; endedAt=nil; activeCommand=nil; testProgress=nil
        }
        // Classification must not use contextShown, which rounds 899/1000 to 90 percent.
        let fraction: Double
        if let used=c.exactTokensUsed, let limit=c.contextLimit, limit>0 { fraction=Double(used)/Double(limit) }
        else { fraction=0 }
        contextBand = fraction >= 0.9 ? 2 : fraction >= 0.8 ? 1 : 0
        satelliteStates = Dictionary(c.satellites.map { ($0.id, $0.done) }, uniquingKeysWith: { _, new in new })
    }

    /// Child completions and HTTP reconciliation publish model changes without a new parent Core event.
    @MainActor mutating func reconcile(in c: Conversation) {
        let next = Dictionary(c.satellites.map { ($0.id, $0.done) }, uniquingKeysWith: { _, new in new })
        defer { satelliteStates = next }
        guard let previous = satelliteStates else { return }
        let running = c.satellites.filter { !$0.done }.count
        if next.contains(where: { previous[$0.key] == false && $0.value }) {
            emit(.init(kind: .finish, text: "Sub-agent finished · \(running) running"))
        } else if next.contains(where: { previous[$0.key] == nil && !$0.value }) {
            emit(.init(kind: .spawn, text: "Sub-agent started · \(running) running"))
        }
    }

    @MainActor static func pending(in c: Conversation) -> [ConversationNotice] {
        var result = c.approvals.map { approval -> ConversationNotice in
            let choices = approval.request["params"]?["availableDecisions"]?.arrayValue ?? ["accept", "decline", "cancel"]
            var buttons: [ConversationNotice.Button] = []
            // Complex permissions/forms keep their complete existing transcript UI and original JSON contract.
            if approval.method.contains("requestApproval"), approval.method != "item/permissions/requestApproval",
               choices.contains("decline"), choices.contains("accept") {
                buttons = [.init(title: "Deny", action: .approval(approval.id, ["decision": "decline"])),
                           .init(title: approval.acceptLabel, action: .approval(approval.id, ["decision": "accept"]))]
            } else { buttons = [.init(title: "Review request", action: .review)] }
            return .init(kind: .approval, text: approval.title + " " + approval.command, requestID: approval.id,
                         request: approval.request, workspace: c.cwd, buttons: buttons, submitting: approval.submitting)
        }
        if let q = c.userInput {
            let buttons: [ConversationNotice.Button]
            if q.questions.count == 1, let question = q.questions.first, !question.isSecret, question.options.count == 2 {
                buttons = question.options.map { .init(title: $0.label, action: .answer(q.id, [question.id: [$0.label]])) }
            } else { buttons = [.init(title: "Answer question", action: .review)] }
            result.append(.init(kind: .question, text: q.questions.map(\.prompt).joined(separator: " · "), requestID: q.id, buttons: buttons, submitting: q.submitting))
        }
        return result
    }
}
