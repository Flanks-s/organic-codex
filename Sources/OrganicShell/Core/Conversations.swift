import Foundation

typealias ConversationID = String

enum ToolKind: Equatable, Sendable { case command, fileChange, toolCall, webSearch, other }
enum NoticeKind: Equatable, Sendable { case error, warning, info }
enum RowKind: Equatable, Sendable {
    case user, assistant, reasoning, tool(ToolKind), notice(NoticeKind)
}

typealias TranscriptItem = Conversation.Item

struct Approval: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var command: String
    var note: String
    var acceptLabel: String
    /// The tool row that waits on this approval.
    var toolItemID: String
    var method: String = ""
    var request: JSONValue = .null
    var source: String = ""
    var submitting = false

    /// Core grants this application across CUA tools in one backend chat only.
    /// An arbitrary MCP elicitation (even an empty form) cannot acquire this scope.
    var cuaApplicationForChatApproval: String? {
        guard source == "cua", method == "elicitation/create",
              request["params"]?["_meta"]?["connector_id"]?.stringValue == "computer-use",
              let app = request["params"]?["_meta"]?["tool_params"]?["app"]?.stringValue, !app.isEmpty,
              let schema = request["params"]?["requestedSchema"], schema["type"]?.stringValue == "object",
              schema["properties"]?.objectValue?.isEmpty == true,
              schema["required"]?.arrayValue?.isEmpty != false else { return nil }
        return app
    }
    var cuaChatApprovalResponse: JSONValue? {
        guard cuaApplicationForChatApproval != nil else { return nil }
        return ["action": "accept", "content": [:], "_meta": ["persist": "session"]]
    }
}

struct PlanStep: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var done = false
}

struct Commit: Equatable, Sendable {
    var message: String
    var hash: String
    var at: Date
}

struct Satellite: Identifiable, Equatable, Sendable {
    let id: String
    var face: String
    var done = false
    /// When it finished, in order (Astra r5 R6): rows and the sheet show the latest finished, not the first started.
    var finishedOrder: Int?
    var threadID: String? = nil
    var title: String? = nil
    var items: [TranscriptItem] = []
}

extension Array where Element == Satellite {
    /// The finished ones, first to finish first (those finished without an order, as they were started).
    var finishedInOrder: [Satellite] {
        filter(\.done).enumerated().sorted { ($0.element.finishedOrder ?? $0.offset, $0.offset) < ($1.element.finishedOrder ?? $1.offset, $1.offset) }
            .map(\.element)
    }
}

enum ErrorState: Equatable, Sendable {
    /// An error happened and the agent keeps running (`!`).
    case running
    /// An error stopped the agent (`x_x`).
    case stopped
}

enum Access: String, CaseIterable, Sendable {
    case readOnly = "Read Only", auto = "Auto", full = "Full Access"
}

struct Project: Identifiable, Equatable, Sendable, Codable {
    let id: String
    var name: String
    var deviceID: String
    var colorHex: String?
    var pinned = false
    var path: String? = nil
}

struct Device: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case mac, pc, server }
    let id: String
    var name: String
    var kind: Kind
    var online = true
    var isLocal: Bool { kind == .mac && id == "mac" }
    var symbol: String {
        switch kind {
        case .mac: "laptopcomputer"
        case .pc: "pc"
        case .server: "server.rack"
        }
    }
}

/// One file a conversation changed, for the Changes inspector (Canopy 2026-10-22).
struct FileChange: Identifiable, Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Sendable { case context, added, removed }
        var kind: Kind
        var text: String
    }
    var id: String { path }
    var path: String
    var added: Int
    var removed: Int
    var lines: [Line]
}

/// The scene-facing API is retained while richer Core rows travel alongside it.
@MainActor final class Conversation: Identifiable {
    enum Kind: String, Sendable { case user, assistant, reasoning, command, tool }
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        var turnID: String = ""
        var rowKind: RowKind
        var text: String
        var status: String?
        var revision = 0
        var timestamp: Date?

        var kind: Kind {
            get {
                switch rowKind {
                case .user: .user
                case .assistant: .assistant
                case .reasoning: .reasoning
                case .tool(.command): .command
                default: .tool
                }
            }
            set {
                rowKind = switch newValue {
                case .user: .user
                case .assistant: .assistant
                case .reasoning: .reasoning
                case .command: .tool(.command)
                case .tool: .tool(.toolCall)
                }
            }
        }
        var running: Bool {
            get { ["running", "inProgress", "in_progress", "started", "active"].contains(status ?? "") }
            set { if newValue { status = "running" } else if running { status = nil } }
        }

        init(id: String, kind: Kind, text: String, running: Bool) {
            self.id = id; self.rowKind = .assistant; self.text = text
            self.status = running ? "running" : nil
            self.kind = kind
        }
        init(id: String, turnID: String, kind: RowKind, text: String, status: String? = nil,
             revision: Int = 0, timestamp: Date? = nil) {
            self.id = id; self.turnID = turnID; self.rowKind = kind; self.text = text
            self.status = status; self.revision = revision; self.timestamp = timestamp
        }
    }
    let id: ConversationID
    /// Stable UI identity is independent of the asynchronously created Core thread.
    var isLiveConversation = false
    var backendThreadID: String?
    var activeTurnID: String?
    var notices = ConversationNoticeFeed()
    var orbActivity = ConversationActivity()
    var phaseFacts = ConversationPhaseFacts()
    weak var phaseStore: ConversationStore?
    var cwd: String?
    var historyLoaded = false
    var loading = false
    var operationError: String?
    var sendOutcomeUnknown = false
    var userInput: UserInputRequest?
    var exactTokensUsed: Int?
    var contextLimit: Int?
    /// Planet symbol and colour (spec §10.1); the user can change both.
    var identityIndex = 0
    /// Local presentation overrides, independent of Orb/SwiftUI enum types.
    var identitySymbol: String?
    var identityTint: String?
    var title: String
    var projectID: String?
    var deviceID: String
    var updated: Date
    var pinned = false
    /// Archived chats leave the sidebar and every window; Undo (or Archived Chats, later) brings them back.
    /// A running chat keeps running.
    var archived = false
    var archivedAt: Date?
    /// Files changed so far (the Changes inspector).
    var changes: [FileChange] = []
    /// The Git branch the chat works on, and its last commit (mock; the Status inspector's Git tools).
    var branch = "main"
    var gitRoot: String?
    var gitDiffHash: String?
    var gitPaths: [String] = []
    var gitBusy = false
    var gitError: String?
    var lastCommit: Commit?
    /// The chat's plan, as Codex and ZCode show it: steps ticked off as turns finish (the Status inspector's Progress).
    var plan: [PlanStep] = []
    /// Tokens in the context window (272K), for the context ring and the Goal line.
    /// Tokens in the context window, as shown (whole percents of it, see `contextPercent`; Astra r8 #1).
    var reportedTokensUsed: Int? { exactTokensUsed }
    var contextUsageReported: Bool { exactTokensUsed != nil && contextLimit != nil }
    var tokensUsed: Int { (isLiveConversation || backendThreadID != nil) ? (exactTokensUsed ?? 0) : contextPercent * (contextLimit ?? 272_000) / 100 }
    var contextDescription: String {
        if isLiveConversation || backendThreadID != nil {
            guard let used = exactTokensUsed else { return "Context usage has not been reported" }
            if let limit = contextLimit { return "\(used.formatted()) of \(limit.formatted()) tokens" }
            return "\(used.formatted()) tokens · context limit not reported"
        }
        if let limit = contextLimit { return "\(tokensUsed.formatted()) of \(limit.formatted()) tokens" }
        return "\(tokensUsed.formatted()) of 272,000 tokens"
    }

    var summaryIndex: SummaryLogIndex?
    var items: [TranscriptItem] = []
    private var transcriptItemPositions: [String: Int] = [:]
    /// Validated on every hit: public array replacement/reorder cannot leave a stale ID lookup.
    /// The active tail costs O(1), including the first event after a snapshot; older active items cache once.
    func transcriptItemIndex(_ id: String) -> Int? {
        if let last = items.indices.last, items[last].id == id { return last }
        if let i = transcriptItemPositions[id], items.indices.contains(i), items[i].id == id { return i }
        let i = items.firstIndex { $0.id == id }
        transcriptItemPositions[id] = i
        return i
    }

    private(set) var draftRevision: UInt64 = 0
    var draft = "" { didSet { if draft != oldValue { draftRevision &+= 1 } } }
    var access: Access = .auto
    /// Settings the last message used, and the ones the next message will use (spec: model picker).
    var settings = ModelSettings()
    var next = ModelSettings()
    var attachments: [Attachment] = [] { didSet { if attachments != oldValue { draftRevision &+= 1 } } }
    /// Follow-ups waiting for the running reply to finish (Queue).
    var queued: [QueuedMessage] = []
    /// Dictation is typing into the draft (mock).
    var dictating = false
    /// Voice conversation: nil when off; otherwise what has been heard so far (mock).
    var voice: String?

    var running = false
    var sending = false
    var stopping = false
    /// Bumped by each stop the user asked for, once it lands: the turn ending then is not "Done", however briefly
    /// `stopping` was seen (Astra r7 #6).
    var stops = 0
    var lastTurnInterrupted = false
    var approvals: [Approval] = []
    var question: String?
    var error: ErrorState?
    /// Completed turns the user has not looked at yet (green count).
    var completions = 0
    var unread = false
    /// Context window used, 0…1.
    var contextUsed: Double = 0 { didSet { let p = Self.percent(contextUsed); if p != contextPercent { contextPercent = p } } }
    /// `contextUsed` in whole percents, for what shows it (rings, liquids, the island): a running agent's context grows
    /// by a fraction of a percent on every tick, and views that read the exact value were drawn again on every one
    /// (2026-10-26 idle review).
    private(set) var contextPercent = 0
    var contextShown: Double { Double(contextPercent) / 100 }
    static func percent(_ value: Double) -> Int { Int((min(1, max(0, value)) * 100).rounded()) }
    /// Bumped by each compaction; the orb spins its liquid once per bump.
    var compactions = 0
    var satellites: [Satellite] = []
    /// The turn finished: satellites make one last pass behind the orb and stay hidden until the next turn.
    var satellitesRetired = false
    /// How busy the agent is right now, 0 (idle) … 1 (streaming output). Drives satellite speed.
    var pace = 0.0
    /// Red events so far, and how many of them the user has seen (hovered). The orb bounces while they differ.
    var redEvents = 0
    var redSeen = 0

    var revision = 0
    init(id: String, title: String) {
        self.id = id; self.title = title; self.deviceID = "mac"; self.updated = Date(timeIntervalSince1970: 0)
    }
    convenience init(id: String, identityIndex: Int, title: String, projectID: String?, deviceID: String = "mac",
                     updated: Date, contextUsed: Double, items: [TranscriptItem] = []) {
        self.init(id: id, title: title)
        self.identityIndex = identityIndex; self.projectID = projectID; self.deviceID = deviceID
        self.updated = updated; self.contextUsed = contextUsed; self.items = items
        contextPercent = Self.percent(contextUsed)
    }
    var goal: String { items.last { $0.kind == .user }?.text ?? title }
    var state: SummaryLog.State {
        if !approvals.isEmpty { return .waiting }
        if error == .stopped { return .failedStopped }
        if error == .running { return .failedRunning }
        if question != nil || userInput != nil { return .asking }
        if running { return .running }
        return summarySource.lastTurnHasWork(self) ? .done : .idle
    }
    var status: String {
        switch state {
        case .waiting: "Waiting for your approval"
        case .failedStopped: "Error · Stopped"
        case .failedRunning: "Error · Still running"
        case .asking: "Waiting for your answer"
        case .running: TranscriptPresentation.activityPhrase(items: items, running: running, sending: sending,
                                                             stopping: stopping, waiting: false) ?? "Working…"
        case .done: lastTurnInterrupted ? "Stopped" : "Done"
        case .idle: "Idle"
        }
    }
    var needsYou: Bool { !approvals.isEmpty || question != nil || userInput != nil }
    var runningSatellites: Int { satellites.filter { !$0.done }.count }

    /// The orb badge (spec §10.2): the most urgent tone wins, red > yellow > green.
    var badge: Badge? {
        switch error {
        case .stopped: return Badge(tone: .red, symbol: .stopped)
        case .running: return Badge(tone: .red, symbol: .error)
        case nil: break
        }
        if !approvals.isEmpty { return Badge(tone: .yellow, symbol: .count(approvals.count)) }
        if question != nil { return Badge(tone: .yellow, symbol: .question) }
        if completions > 0 { return Badge(tone: .green, symbol: .count(completions)) }
        return nil
    }
    /// A red event the user has not hovered yet.
    var redUnseen: Bool { badge?.tone == .red && redEvents > redSeen }
}

/// Symbol = what happened, tone = whether it needs you (spec §10.2).
struct Badge: Equatable, Sendable {
    enum Tone: Int, Comparable, Sendable {
        case green, yellow, red
        static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }
    enum Symbol: Equatable, Sendable {
        case count(Int), question, error, stopped
        var text: String {
            switch self {
            case .count(let n): n > 99 ? "99+" : "\(n)"
            case .question: "?"
            case .error: "!"
            case .stopped: "x_x"
            }
        }
    }
    var tone: Tone
    var symbol: Symbol

    /// VoiceOver wording.
    var meaning: String {
        switch (tone, symbol) {
        case (.red, .stopped): "error, stopped"
        case (.red, _): "error, still running"
        case (.yellow, .question): "asking you a question"
        case (.yellow, .count(let n)): n == 1 ? "1 approval waiting" : "\(n) approvals waiting"
        case (.green, .count(let n)): n == 1 ? "1 finished turn" : "\(n) finished turns"
        default: ""
        }
    }
}
