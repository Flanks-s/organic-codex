#if CORE_SELFTEST
import Foundation

private actor SidechatFixture: CoreTransport {
    private var calls: [String: [JSONValue]] = [:]

    nonisolated func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func requests(_ path: String) -> [JSONValue] { calls[path] ?? [] }

    func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
        calls[path, default: []].append(body ?? .null)
        switch path {
        case "/sidechat/open":
            return ["threadId": "child", "parentThreadId": "parent", "lease": "lease", "cursor": 0]
        case "/sidechat/events":
            let since = body?["since"]?.intValue ?? 0
            if since == 0 {
                let request: JSONValue = ["method": "item/commandExecution/requestApproval",
                                          "params": ["command": "fixture", "availableDecisions": ["accept", "cancel"]]]
                let params: [String: JSONValue] = ["threadId": "child", "parentThreadId": "parent", "request": request,
                    "approvalId": "side-approval", "source": "app-server", "canRememberAuthorization": false]
                var remembered = params
                remembered["approvalId"] = "remember-approval"
                remembered["canRememberAuthorization"] = true
                return ["cursor": 2, "events": [
                    ["id": 1, "method": "core/approvalRequested", "params": .object(params)],
                    ["id": 2, "method": "core/approvalRequested", "params": .object(remembered)]]]
            }
            try await Task.sleep(for: .seconds(30))
            return ["cursor": .number(Double(since)), "events": []]
        case "/sidechat/settings":
            if body?["confirm"] != nil { return [:] }
            return ["sidechats": [["threadId": "child", "hasContent": false, "running": false]]]
        case "/sidechat/approval": return ["responded": "side-approval"]
        case "/sidechat/close", "/app-server/plugins/list": return [:]
        default: throw CoreWire.failure("Unexpected fixture request")
        }
    }
}

@MainActor enum SidechatVerification {
    static func run(check: (Bool, String) -> Void) async throws {
        let wire = SidechatFixture()
        let runtime = SidechatRuntime(client: wire)
        runtime.bind(instance: "fixture", available: true)
        let chat = try await runtime.open(parentID: "parent")
        for _ in 0..<20_000 {
            if !chat.approvals.isEmpty { break }
            await Task.yield()
        }
        guard let card = chat.approvals.first else { throw CoreWire.failure("Missing private approval") }
        check(runtime.chats(for: "other").isEmpty, "sidechat approval belongs to the originating parent")
        check(card.cuaChatApprovalResponse == nil, "sidechat card offers no remembered authorization")
        check(chat.approvals.map(\.id) == ["side-approval"], "sidechat rejects canRememberAuthorization approval cards")
        let persistent: JSONValue = ["decision": "accept", "_meta": ["persist": true]]
        do {
            try await runtime.reply(parentID: "parent", approvalID: card.id, response: persistent)
        } catch let error as CoreError where error.message == "Sidechat approval is no longer available." {}
        let rejectedWrites = await wire.requests("/sidechat/approval")
        check(rejectedWrites.isEmpty && chat.approvals.contains { $0.id == card.id }, "sidechat rejects _meta.persist")
        let response: JSONValue = ["decision": "accept"]
        try await runtime.reply(parentID: "parent", approvalID: card.id, response: response)
        let privateWrites = await wire.requests("/sidechat/approval")
        let publicWrites = await wire.requests("/approvals/side-approval")
        check(privateWrites.first?["threadId"] == "child" && privateWrites.first?["response"] == response,
              "approval keeps original response and child lease")
        check(publicWrites.isEmpty && chat.approvals.isEmpty, "private approval clears without ordinary persistence")

        let draft = "P2_SWIFT_PRIVATE_DRAFT_925D"
        runtime.edit(chat, text: draft)
        let ghost = Conversation(id: SidechatRuntime.presentationPrefix + chat.id, title: "Private")
        ghost.draft = chat.draft
        let publicChat = Conversation(id: "parent", title: "Parent")
        let store = ConversationStore(conversations: [publicChat, ghost])
        let storage = CoreMemoryStorage()
        let presentation = LocalPresentationState(store: store, scope: "p2-fixture", storage: storage)
        presentation.setWindows([.init(id: ghost.id, payload: ["draft": .string(draft)])])
        try presentation.save()
        check(!storage.values.values.contains { String(decoding: $0, as: UTF8.self).contains(draft) },
              "private drafts are excluded from stored conversations and windows")
        let row = TranscriptItem(id: "answer", turnID: "turn", kind: .assistant, text: "Parent reply")
        let attachment: JSONValue = ["attachmentType": "organicSidechatQuote", "identityKey": "quote",
                                     "payload": ["source": "Sidechat A", "summary": "Answer", "anchorTurnId": "turn",
                                                 "order": 0]]
        guard let quote = SidechatQuote(attachment) else { throw CoreWire.failure("Invalid fixture quote") }
        check(TranscriptPresentation.rows(items: [row], quotes: [quote]) == [.item(row), .quote(quote)]
              && publicChat.draft.isEmpty, "quote appears after the parent turn in the transcript only")

        let settings = CoreSettingsController()
        settings.configure(client: wire, endpoint: "fixture")
        settings.sidechats = runtime
        var targets: [SidechatRuntime.CloseTarget] = []
        settings.confirmSidechatClosure = { preview in
            targets = preview
            return false
        }
        let change = SettingsOperation(kind: .pluginUninstall, payload: ["pluginId": "fixture"],
                                       scope: .init(endpoint: "fixture", device: "mac"))
        _ = try await settings.perform(change)
        let requests = await wire.requests("/sidechat/settings")
        check(targets.count == 1 && targets.first?.hasDraft == true, "local draft requires settings confirmation")
        check(requests.count == 1 && requests.first?["confirm"] == nil && chat.draft == draft,
              "cancel preserves the draft and sends no settings write")
        settings.confirmSidechatClosure = { _ in true }
        _ = try await settings.perform(change)
        let submitted = await wire.requests("/sidechat/settings")
        check(submitted.last?["confirm"]?.arrayValue?.count == 1 && runtime.chats.isEmpty,
              "accept sends the inspected list and retires the closed lease")
        await runtime.shutdown()
    }
}
#endif
