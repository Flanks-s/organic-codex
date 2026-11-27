import Foundation

struct SidechatQuote: Equatable, Identifiable, Sendable {
    let id: String
    let source: String
    let summary: String
    let anchorTurnID: String?
    let order: Int

    init?(_ row: JSONValue) {
        guard row["attachmentType"] == "organicSidechatQuote", let key = row["identityKey"]?.stringValue,
              let payload = row["payload"], let source = payload["source"]?.stringValue,
              let summary = payload["summary"]?.stringValue, let order = payload["order"]?.intValue else { return nil }
        id = key
        self.source = source
        self.summary = summary
        self.order = order
        anchorTurnID = payload["anchorTurnId"]?.stringValue
    }
}

@MainActor final class SidechatRuntime {
    static let presentationPrefix = "sidechat-memory:"
    static let refreshMethods: Set<String> = [
        "config/batchWrite", "config/mcpServer/reload", "experimentalFeature/enablement/set", "plugin/install",
        "plugin/uninstall", "mcpServer/oauth/login", "account/login/start", "account/gatewayOAuth/login",
        "accountSession/switch", "account/logout",
    ]

    @MainActor final class Chat {
        let id: String
        let parentID: String
        fileprivate let lease: String
        fileprivate let instance: String
        fileprivate var projection: Conversation
        fileprivate var revision = 0
        fileprivate var cursor = 0
        fileprivate var terminal: String?
        fileprivate var candidate: (turn: String, item: String)?
        fileprivate var sending = false
        fileprivate var starting: String?
        fileprivate(set) var lastAnswer: String?
        fileprivate(set) var draft = ""
        var items: [TranscriptItem] { projection.items }
        var approvals: [Approval] { projection.approvals }
        var userInput: UserInputRequest? { projection.userInput }
        var running: Bool { sending || starting != nil || projection.running }
        var activeTurnID: String? { projection.activeTurnID }
        var stopped: Bool { projection.lastTurnInterrupted || projection.error == .stopped }

        fileprivate init(id: String, parent: String, lease: String, instance: String) {
            self.id = id
            parentID = parent
            self.lease = lease
            self.instance = instance
            projection = Conversation(id: SidechatRuntime.presentationPrefix + id, title: "Sidechat")
        }

        fileprivate var body: [String: JSONValue] {
            ["instanceId": .string(instance), "threadId": .string(id), "lease": .string(lease)]
        }
    }

    struct CloseTarget: Equatable {
        let id: String
        let parentID: String?
        let hasContent: Bool
        let running: Bool
        let hasDraft: Bool
        var needsConfirmation: Bool { hasContent || running || hasDraft }
    }

    private let client: any CoreTransport
    private let clock: any CoreRuntimeClock
    private var instance: String?
    private var enabled = false
    private var shuttingDown = false
    private var opening = 0
    private var archiving: Set<String> = []
    private var polling: [String: Task<Void, Never>] = [:]
    private var responding: Set<String> = []
    private(set) var closing: Set<String> = []
    private(set) var chats: [String: Chat] = [:]
    var changed: ((String?) -> Void)?
    private var observers: [UUID: (String?) -> Void] = [:]
    var available: Bool { enabled }

    func observe(_ observer: @escaping (String?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify(_ parentID: String?) {
        changed?(parentID)
        for observer in Array(observers.values) { observer(parentID) }
    }
    var didSendQuote: ((String, SidechatQuote) -> Void)?
    var guardsSettings: Bool { enabled || !chats.isEmpty }
    var needsShutdown: Bool { opening > 0 || !chats.isEmpty }
    var confirmArchive: (@MainActor ([CloseTarget]) async -> Bool)?

    convenience init(baseURL: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.init(client: CoreClient(baseURL: baseURL, session: URLSession(configuration: configuration)))
    }

    init(client: any CoreTransport, clock: any CoreRuntimeClock = CoreSystemClock()) {
        self.client = client
        self.clock = clock
    }

    isolated deinit {
        for task in polling.values { task.cancel() }
    }

    func bind(instance new: String?, available: Bool) {
        if instance != new || !available {
            for chat in Array(chats.values) { forget(chat) }
        }
        instance = new
        enabled = available && new != nil && !shuttingDown
    }

    private func post(_ action: String, _ body: [String: JSONValue],
                      timeout: TimeInterval = 40) async throws -> JSONValue {
        do {
            return try await client.request("POST", path: "/sidechat/" + action, body: .object(body), timeout: timeout)
        } catch let error as CoreError {
            throw CoreError(code: error.code, message: error.message, data: nil,
                            httpStatus: error.httpStatus, requestSent: error.requestSent)
        }
    }

    func open(parentID: String) async throws -> Chat {
        guard enabled, let instance, !archiving.contains(parentID) else {
            throw CoreWire.failure("Sidechat is unavailable.")
        }
        opening += 1
        defer { opening -= 1 }
        let result = try await post("open", ["parentThreadId": .string(parentID), "instanceId": .string(instance)])
        guard result["parentThreadId"] == .string(parentID), let id = result["threadId"]?.stringValue,
              let lease = result["lease"]?.stringValue else { throw CoreWire.failure("Invalid sidechat lease.") }
        let chat = Chat(id: id, parent: parentID, lease: lease, instance: instance)
        guard self.instance == instance, enabled, !Task.isCancelled, !archiving.contains(parentID) else {
            _ = try? await post("close", chat.body, timeout: 8)
            throw CancellationError()
        }
        chats[id] = chat
        polling[id] = Task { [weak self, weak chat] in
            var failures = 0
            while !Task.isCancelled, let self, let chat, self.chats[chat.id] === chat {
                do {
                    var body = chat.body
                    body["since"] = .number(Double(chat.cursor))
                    let page = try await self.post("events", body)
                    guard self.chats[chat.id] === chat, !Task.isCancelled else { return }
                    try self.consume(page, for: chat)
                    failures = 0
                } catch {
                    if Task.isCancelled || self.chats[chat.id] !== chat { return }
                    if let code = (error as? CoreError)?.code, [-32010, -32602].contains(code) {
                        self.forget(chat)
                        return
                    }
                    if failures == 0 { self.resetReplay(chat) }
                    try? await self.clock.sleep(seconds: CoreReconnectPolicy().delay(attempt: failures))
                    failures += 1
                }
            }
        }
        notify(chat.parentID)
        return chat
    }

    private func consume(_ page: JSONValue, for chat: Chat) throws {
        guard let rows = page["events"]?.arrayValue, page["cursor"]?.intValue == chat.cursor + rows.count else {
            throw CoreWire.failure("Invalid sidechat event page.")
        }
        let events = try rows.enumerated().map { offset, row in
            guard let id = row["id"]?.intValue, id == chat.cursor + offset + 1,
                  let method = row["method"]?.stringValue else {
                throw CoreWire.failure("Invalid sidechat event sequence.")
            }
            return CoreEvent(id: id, time: row["time"]?.doubleValue, method: method, params: row["params"] ?? .null)
        }
        for event in events {
            apply(event, to: chat)
            chat.cursor = event.id
        }
        if !rows.isEmpty { notify(chat.parentID) }
    }

    private func apply(_ event: CoreEvent, to chat: Chat) {
        let p = event.params
        guard p["threadId"] == .string(chat.id) else { return }
        if event.method == "core/approvalRequested" {
            guard p["parentThreadId"] == .string(chat.parentID), p["source"] == "app-server",
                  p["canRememberAuthorization"] == false else { return }
        }
        if event.method == "turn/started" {
            chat.candidate = nil
            chat.lastAnswer = nil
        }
        if event.method == "item/completed", let item = p["item"], item["type"] == "agentMessage",
           item["phase"] == nil || item["phase"] == .null || item["phase"] == "final_answer",
           let text = item["text"]?.stringValue, Self.hasText(text),
           let turn = p["turnId"]?.stringValue, let id = item["id"]?.stringValue {
            chat.candidate = (turn, id)
        }
        if event.method == "turn/completed", let turn = p["turn"]?["id"]?.stringValue {
            chat.terminal = turn
            if chat.starting == turn { chat.starting = nil }
            chat.lastAnswer = p["turn"]?["status"] == "completed" && chat.candidate?.turn == turn
                ? chat.candidate?.item : nil
        }
        EventReducer.apply(event, to: chat.projection)
    }

    private func resetReplay(_ chat: Chat) {
        chat.cursor = 0
        chat.candidate = nil
        chat.lastAnswer = nil
        chat.projection = Conversation(id: Self.presentationPrefix + chat.id, title: "Sidechat")
        notify(chat.parentID)
    }

    private func forget(_ chat: Chat) {
        polling.removeValue(forKey: chat.id)?.cancel()
        chats[chat.id] = nil
        chat.draft = ""
        resetReplay(chat)
    }

    func edit(_ chat: Chat, text: String) {
        guard chats[chat.id] === chat, !closing.contains(chat.id), !archiving.contains(chat.parentID) else { return }
        chat.draft = text
        chat.revision += 1
        notify(chat.parentID)
    }

    func send(_ chat: Chat, anchor: String? = nil) async throws {
        guard chats[chat.id] === chat, !chat.running, !closing.contains(chat.id),
              !archiving.contains(chat.parentID), Self.hasText(chat.draft) else {
            throw CoreWire.failure("Sidechat has no available send.")
        }
        let revision = chat.revision
        var body = chat.body
        body["text"] = .string(chat.draft)
        body["anchor"] = anchor.map(JSONValue.string)
        chat.sending = true
        notify(chat.parentID)
        defer {
            chat.sending = false
            notify(chat.parentID)
        }
        let result = try await post("send", body)
        guard chats[chat.id] === chat else { return }
        if let id = result["turn"]?["id"]?.stringValue, result["turn"]?["status"] == "inProgress",
           chat.terminal != id { chat.starting = id }
        if chat.revision == revision { chat.draft = "" }
    }

    func stop(_ chat: Chat) async throws {
        guard chats[chat.id] === chat else { return }
        _ = try await post("stop", chat.body)
    }

    func close(_ chat: Chat) async throws {
        guard chats[chat.id] === chat else { return }
        forget(chat)
        _ = try await post("close", chat.body, timeout: shuttingDown ? 8 : 40)
    }

    func shutdown() async {
        shuttingDown = true
        enabled = false
        while opening > 0 && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        for chat in Array(chats.values) { try? await close(chat) }
    }

    func chats(for parentID: String) -> [Chat] {
        chats.values.filter { $0.parentID == parentID }.sorted { $0.id < $1.id }
    }

    func archiveTargets(parentIDs: Set<String>) -> [CloseTarget] {
        chats.values.filter { parentIDs.contains($0.parentID) }.sorted { $0.id < $1.id }.map { chat in
            CloseTarget(id: chat.id, parentID: chat.parentID, hasContent: !chat.items.isEmpty,
                        running: chat.running, hasDraft: Self.hasText(chat.draft))
        }
    }

    func withArchive<T>(_ parents: Set<String>, confirm: (@MainActor ([CloseTarget]) async -> Bool)? = nil,
                        commit: @MainActor () async throws -> T) async throws -> T {
        guard archiving.isDisjoint(with: parents) else { throw CoreWire.failure("An archive is already in progress.") }
        archiving.formUnion(parents)
        defer { archiving.subtract(parents) }
        let instance = self.instance
        let targets = archiveTargets(parentIDs: parents)
        if targets.contains(where: \.needsConfirmation) {
            let allowed = await (confirm ?? confirmArchive)?(targets) == true
            guard allowed else { throw CancellationError() }
            guard archiveTargets(parentIDs: parents) == targets else {
                throw CoreWire.failure("Sidechats changed. Review the archive again.")
            }
        }
        try Task.checkCancellation()
        guard instance == self.instance else { throw SettingsDataError.stale }
        return try await commit()
    }

    func reply(parentID: String, approvalID: String, response: JSONValue) async throws {
        guard let chat = chats(for: parentID).first(where: { chat in
            chat.approvals.contains { $0.id == approvalID } || chat.userInput?.id == approvalID
        }), response.objectValue != nil, response["_meta"]?["persist"] == nil,
              !closing.contains(chat.id), responding.insert(approvalID).inserted else {
            throw CoreWire.failure("Sidechat approval is no longer available.")
        }
        defer { responding.remove(approvalID) }
        if let card = chat.approvals.first(where: { $0.id == approvalID }),
           let reason = CoreResponseValidation.approval(response, request: card) { throw CoreWire.failure(reason) }
        var body = chat.body
        body["approvalId"] = .string(approvalID)
        body["response"] = response
        _ = try await post("approval", body)
        if chats[chat.id] === chat {
            chat.projection.approvals.removeAll { $0.id == approvalID }
            if chat.projection.userInput?.id == approvalID { chat.projection.userInput = nil }
            notify(chat.parentID)
        }
    }

    func sendToMain(_ chat: Chat) async throws -> SidechatQuote {
        guard chats[chat.id] === chat, !chat.running, !closing.contains(chat.id), let answer = chat.lastAnswer else {
            throw CoreWire.failure("Wait for the sidechat answer to finish.")
        }
        var body = chat.body
        body["answerId"] = .string(answer)
        body["parentThreadId"] = .string(chat.parentID)
        let result = try await post("send-main", body)
        guard instance == chat.instance, let row = result["quote"], let quote = SidechatQuote(row) else {
            throw CoreWire.failure("No sidechat quote receipt.")
        }
        didSendQuote?(chat.parentID, quote)
        return quote
    }

    func quotes(parentID: String) async throws -> [SidechatQuote] {
        var params: [String: JSONValue] = ["threadId": .string(parentID), "limit": 100]
        var quotes: [String: SidechatQuote] = [:]
        while true {
            let result = try await client.rpc("thread/attachment/list", params: params)
            for row in result["data"]?.arrayValue ?? [] {
                if let quote = SidechatQuote(row) { quotes[quote.id] = quote }
            }
            guard let next = result["nextCursor"]?.stringValue else {
                return quotes.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            }
            params["cursor"] = .string(next)
        }
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshSettings(_ method: String, params: JSONValue, qualify: @MainActor () throws -> Void,
                         confirm: (@MainActor ([CloseTarget]) async -> Bool)?) async throws -> JSONValue {
        guard let instance else { throw CoreWire.failure("Sidechat settings require a bound Core instance.") }
        var body: [String: JSONValue] = ["instanceId": .string(instance), "method": .string(method), "params": params]
        try qualify()
        var result = try await post("settings", body)
        while let rows = result["sidechats"]?.arrayValue {
            let targets = rows.compactMap { previewTarget($0) }
            guard targets.count == rows.count else { throw CoreWire.failure("Invalid sidechat closure preview.") }
            if targets.contains(where: \.needsConfirmation) {
                guard let confirm, await confirm(targets) else { throw CancellationError() }
                if rows.compactMap({ previewTarget($0) }) != targets { continue }
            }
            try Task.checkCancellation()
            try qualify()
            guard self.instance == instance else { throw SettingsDataError.stale }
            body["confirm"] = .array(rows)
            let ids = Set(targets.map(\.id))
            closing.formUnion(ids)
            notify(nil)
            defer {
                closing.subtract(ids)
                notify(nil)
            }
            result = try await post("settings", body)
            if result["sidechats"] == nil {
                for id in ids {
                    if let chat = chats[id], chat.instance == instance { forget(chat) }
                }
            }
        }
        return result
    }

    private func previewTarget(_ row: JSONValue) -> CloseTarget? {
        guard let id = row["threadId"]?.stringValue, let content = row["hasContent"]?.boolValue,
              let running = row["running"]?.boolValue else { return nil }
        return CloseTarget(id: id, parentID: chats[id]?.parentID, hasContent: content, running: running,
                           hasDraft: Self.hasText(chats[id]?.draft ?? ""))
    }
}
