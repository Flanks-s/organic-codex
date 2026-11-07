#if CORE_SELFTEST
import Foundation

// All requests are intercepted in memory. No sockets, backend processes, application or windows.
private struct FixtureRequest: Sendable {
    var method: String, path: String, body: JSONValue?
    var rpc: String? { body?["method"]?.stringValue }
    var params: JSONValue { body?["params"] ?? [:] }
}
private final class FixtureTransport: CoreTransport, @unchecked Sendable {
    struct Script: Sendable { var events: [CoreEvent] = []; var finish = false; var failure: CoreError? }
    private let lock = NSLock()
    private var cursors: [Int] = [], scripts: [Script] = []
    private var sinks: [AsyncThrowingStream<CoreEvent, Error>.Continuation] = []
    let handler: @Sendable (FixtureRequest) async throws -> JSONValue
    init(_ handler: @escaping @Sendable (FixtureRequest) async throws -> JSONValue) { self.handler = handler }
    func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue { try await handler(.init(method: method, path: path, body: body)) }
    func enqueue(_ script: Script) { lock.withLock { scripts.append(script) } }
    var subscriptions: [Int] { lock.withLock { cursors } }
    func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> {
        AsyncThrowingStream { sink in
            let script = lock.withLock { cursors.append(since); sinks.append(sink); return scripts.isEmpty ? Script() : scripts.removeFirst() }
            for e in script.events where e.id > since { sink.yield(e) }
            if let error = script.failure { sink.finish(throwing: error) } else if script.finish { sink.finish() }
        }
    }
    func emit(_ e: CoreEvent) { for sink in lock.withLock({ sinks }) { sink.yield(e) } }
    func close() { for sink in lock.withLock({ sinks }) { sink.finish() } }
}
private actor FixtureClock: CoreRuntimeClock {
    private(set) var delays: [TimeInterval] = []
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var cancelled: Set<UUID> = []
    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delays.append(seconds)
                if cancelled.remove(id) != nil { continuation.resume(throwing: CancellationError()) } else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { if let i = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: i).1.resume(throwing: CancellationError()) } else { cancelled.insert(id) } }
    func advance() { if !waiters.isEmpty { waiters.removeFirst().1.resume() } }
}
private struct ImmediateClock: CoreRuntimeClock { func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation(); await Task.yield() } }
@MainActor private final class FixtureLauncher: CoreProcessLaunching {
    var isRunning = false, hasExited = false, launches = 0
    func launch(_ configuration: CoreEndpointConfiguration) throws { launches += 1; isRunning = true }
}
@MainActor private final class FixtureBackend {
    var high = 0, instance = "fixture-instance", connected = true, name = "Organic Codex Core"
    var pending: [JSONValue] = [], sessions: [JSONValue] = []
    var modelPages: [String: JSONValue] = ["": ["data": [["id": "wire-sol", "displayName": "Sol Live", "isDefault": true, "supportedReasoningEfforts": [["reasoningEffort": "high"], ["reasoningEffort": "ultra"]], "defaultReasoningEffort": "high", "serviceTiers": ["priority"], "availableAccessPrograms": ["cyber": ["daybreakBlue"]]]]]]
    var history: [String: JSONValue] = ["active:": ["data": []], "archived:": ["data": []]]
    var threads: [String: JSONValue] = [:], log: [CoreEvent] = [], requests: [FixtureRequest] = []
    var failures: [String: Error] = [:]
    var before: ((FixtureRequest) async throws -> JSONValue?)?
    var nextThread = "created-thread", nextTurn = "accepted-turn"
    var health: JSONValue { ["name": .string(name), "backendConnected": .bool(connected), "instanceId": .string(instance), "pid": 4242, "dataDir": "/fixture/core", "lastEventId": .number(Double(high)), "sessions": .array(sessions), "pendingApprovals": .array(pending), "authorizationCount": 2] }
    var capabilities: JSONValue = ["version": "fixture-v7", "features": ["scheduler": ["available": true, "version": "deployed-v1", "authorization": "unverified"], "voice": ["available": false, "reason": "not connected"]]]
    func respond(_ r: FixtureRequest) async throws -> JSONValue {
        requests.append(r)
        let key = r.rpc ?? r.path
        if let result = try await before?(r) { return result }
        if let error = failures[key] { throw error }
        switch key {
        case "/health": return health
        case "/capabilities": return capabilities
        case "/sessions": return .array(sessions)
        case "/authorizations": return r.method == "GET" ? ["grants": []] : ["id": "new-grant"]
        case "thread/list": return history[(r.params["archived"] == true ? "archived:" : "active:") + (r.params["cursor"]?.stringValue ?? "")] ?? ["data": []]
        case "model/list": return modelPages[r.params["cursor"]?.stringValue ?? ""] ?? ["data": []]
        case "account/read": return ["account": nil]
        case "account/rateLimits/read": return [:]
        case "thread/read": return ["thread": threads[r.params["threadId"]?.stringValue ?? ""] ?? ["id": r.params["threadId"] ?? "", "turns": []]]
        case "thread/start": return ["thread": ["id": .string(nextThread), "turns": []]]
        case "thread/resume", "turn/interrupt", "thread/name/set", "thread/archive", "thread/unarchive": return [:]
        case "turn/start":
            let tid = r.params["threadId"]?.stringValue ?? ""
            var object = threads[tid]?.objectValue ?? ["id": .string(tid)]
            var turns = object["turns"]?.arrayValue ?? []
            turns.append(["id": .string(nextTurn), "status": "inProgress", "items": []]); object["turns"] = .array(turns)
            threads[tid] = .object(object)
            return ["turn": ["id": .string(nextTurn), "status": "inProgress"]]
        case "turn/steer": return ["turn": ["id": r.params["expectedTurnId"] ?? .string(nextTurn), "status": "inProgress"]]
        default:
            if r.path.hasPrefix("/approvals/") || r.path.hasPrefix("/authorizations/") { return [:] }
            if r.path.hasPrefix("/events.json"), let components = URLComponents(string: r.path) {
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let since = Int(query["since"] ?? "0") ?? 0, limit = Int(query["limit"] ?? "100") ?? 100
                return .array(try log.filter { $0.id > since && ($0.params["threadId"]?.stringValue == query["threadId"]) }.prefix(limit).map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) })
            }
            throw CoreWire.failure("Unexpected fixture request: " + key)
        }
    }
    func count(_ key: String) -> Int { requests.filter { ($0.rpc ?? $0.path) == key }.count }
    func event(_ id: Int, _ method: String, _ params: JSONValue) -> CoreEvent { .init(id: id, time: Double(id), method: method, params: params) }
    func runtime(clock: any CoreRuntimeClock = ImmediateClock(), storage: CoreMemoryStorage = CoreMemoryStorage()) -> (LiveConversationRuntime, FixtureTransport) {
        let store = ConversationStore()
        let t = FixtureTransport { [self] in try await respond($0) }
        return (LiveConversationRuntime(store: store, client: t, presentation: LocalPresentationState(store: store, scope: "fixture", storage: storage), clock: clock), t)
    }
}
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response: (Int, Data, String) = (200, Data(), "application/json")
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static func prepare(_ value: String, status: Int = 200, mime: String = "application/json") { lock.withLock { response = (status, Data(value.utf8), mime) } }
    static var lastRequest: URLRequest? { lock.withLock { recorded.last } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var snapshot = request
        if snapshot.httpBody == nil, let stream = snapshot.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            snapshot.httpBody = bytes
        }
        let (status, data, mime) = Self.lock.withLock { Self.recorded.append(snapshot); return Self.response }
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct CoreVerification {
    private static var checks = 0, findings: [String] = []
    private static func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { findings.append(label); print("FINDING: " + label) } }
    private static func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS " + name) } catch { check(false, name + ": " + error.localizedDescription) }
    }
    private static func wait(_ label: String, _ predicate: () -> Bool) async {
        for _ in 0..<20_000 { if predicate() { return }; await Task.yield() }
        check(false, "Timed out: " + label)
    }
    private static func turn(_ id: String, _ status: String, _ items: [JSONValue]) -> JSONValue { ["id": .string(id), "status": .string(status), "items": .array(items)] }
    private static func row(_ id: String, _ text: String, type: String = "agentMessage", clientID: UUID? = nil) -> JSONValue {
        var r: [String: JSONValue] = ["id": .string(id), "type": .string(type), "text": .string(text)]
        if let clientID { r["clientId"] = .string(clientID.uuidString.lowercased()) }; return .object(r)
    }
    static func main() async {
        let previous = ModelCatalog.models
        await run("wire, HTTP envelopes and intercepted SSE", wire)
        await run("revert paths inside the repository", revertPaths)
        await run("endpoint ownership, health and capabilities", ownership)
        await run("history paging, resume, live capabilities and unknown usage", history)
        await run("Read/SSE watermarks, baselines and late lifecycle", watermarks)
        await run("UUID sends, snapshots, steer, failure and ambiguity", submissions)
        await run("durable queue, delivery, stopping and failed queue recovery", queueAndStop)
        await run("approval/question restoration and response validation", approvals)
        await run("sub-agent events and parent projection", children)
        await run("reconnect, cursor, backoff and backend epoch", reconnect)
        await run("presentation identity, isolation and restart reconciliation", persistence)
        await run("S3 private attachment sidecars, migration and failure atomicity") { try CoreAttachmentVerification.run(check: check) }
        await run("S3 sidecar-backed submission inputs and unreadable payload rejection", attachmentSubmissions)
        await run("first-free identity assignment and custom identities", identityAssignment)
        await run("M8 settings protocol, pagination and acknowledged writes", m8Settings)
        await run("S1 observable Settings, permission and injected notifications") {try await CoreSettingsAsyncVerification.run(check:check)}
        await run("C08–C10 Settings thread options, Browser envelope and child routes", settingsComponentContracts)
        await run("precise store changes, compatibility, mock and Live replay gates", changeNotifications)
        await run("permanent library removal, observer consistency and terminal selection", componentStoreRemoval)
        await run("M8 artifacts, annotations, delivery and capture recovery", m8Artifacts)
        await run("M8 terminal ownership, restoration, cursor and input", m8Terminal)
        ModelCatalog.models = ModelCatalog.mockModels
        await run("unchanged mock replay and common runtime protocol", mocks)
        await run("S4 single mock source, injected clock, controls and Live refusal") { await MockPlaybackVerification.run(check:check) }
        ModelCatalog.models = previous
        print("CORE_SELFTEST: \(checks) checks, \(findings.count) findings")
        if !findings.isEmpty { exit(1) }
    }
    private static func changeNotifications() async throws {
        let c = Conversation(id: "typed", title: "Typed changes"), store = ConversationStore(conversations: [c])
        var changes: [ConversationChange] = [], oldCalls = 0, onChangeCalls = 0
        let old = store.observe { _ in oldCalls += 1 }
        let typed = store.observeChanges { _, change in changes.append(change) }
        store.onChange = { _ in onChangeCalls += 1 }
        var serial = 0
        func send(_ method: String, _ fields: JSONValue = [:], _ expected: ConversationChange = .structural) {
            serial += 1; var fields = fields.objectValue ?? [:]; fields["threadId"] = .string(c.id)
            store.apply(.init(id: serial, time: 100, method: method, params: .object(fields)))
            check(changes.last == expected, "store kind: " + method + " / " + String(describing: expected))
        }
        for type in ["userMessage", "agentMessage", "reasoning", "commandExecution", "fileChange", "mcpToolCall", "collabAgentToolCall", "contextCompaction"] {
            let item: JSONValue = ["id": .string(type), "type": .string(type), "text": "Recorded", "command": "printf fixture"]
            send("item/started", ["item": item, "turnId": "t"], .itemChanged(itemID: type))
            send("item/completed", ["item": item, "turnId": "t"], .itemChanged(itemID: type))
        }
        for method in ["item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta"] {
            send(method, ["itemId": "agentMessage", "delta": " tail"], .itemAppended(itemID: "agentMessage"))
            send(method, ["itemId": .string(method), "delta": "initial"], .itemChanged(itemID: method))
            send(method, ["itemId": "agentMessage"])
        }
        for method in ["turn/started", "turn/completed", "thread/restored", "thread/started", "thread/name/updated", "thread/tokenUsage/updated", "turn/plan/updated", "core/approvalRequested", "core/approvalResponded", "core/approvalExpired", "thread/compacted", "core/fixtureState", "error", "account/rateLimits/updated", "unknown/futureEvent"] { send(method) }
        send("item/completed", ["item": ["id": "fileChange", "type": "fileChange", "changes": [["path": "fixture.swift", "diff": "+new"]]], "turnId": "t"])
        send("item/completed", ["item": ["id": "agentMessage", "type": "userMessage", "text": "changed kind"], "turnId": "t"])
        send("item/started", ["item": ["type": "agentMessage"]])
        send("item/agentMessage/delta", ["itemId": "", "delta": "invalid"])
        store.changed(c); check(changes.last == .structural, "unhinted local edit/fork/revert reload is structural")
        check(oldCalls == changes.count && onChangeCalls == changes.count, "legacy observe/onChange receive exactly one full Conversation per publication")
        store.removeObserver(typed); let count = changes.count; store.changed(c)
        check(changes.count == count && oldCalls == count + 1, "one removeObserver API removes typed tokens without changing legacy tokens")
        store.removeObserver(old)
        // Cached lookups validate IDs after reorder/replacement; a dirty ID can never update an old position.
        _ = c.transcriptItemIndex("agentMessage"); c.items.reverse()
        check(c.transcriptItemIndex("agentMessage").map { c.items[$0].id } == "agentMessage", "item lookup survives reorder")
        c.items = [.init(id: "replacement", turnID: "new", kind: .assistant, text: "new")]
        check(c.transcriptItemIndex("agentMessage") == nil && c.transcriptItemIndex("replacement") == 0, "item lookup survives edit/reload replacement")
        var nested: [ConversationChange] = [], reentered = false
        let a = store.observeChanges { _, hint in
            nested.append(hint)
            if !reentered { reentered = true; c.title = "nested"; store.changed(c) }
        }
        let b = store.observeChanges { _, hint in nested.append(hint) }
        store.changed(c, change: .itemAppended(itemID: "replacement"))
        check(nested.filter { $0 == .structural }.count >= 2, "nested publication supersedes precise hints conservatively")
        store.removeObserver(a); store.removeObserver(b)

        let mockStore = ConversationStore(), mock = MockReplay(store: mockStore)
        var lastHint: ConversationChange = .structural, mockEvents = 0, mockAppends = 0
        let token = mockStore.observeChanges { _, hint in lastHint = hint }
        mock.onEvent = { event in
            mockEvents += 1
            if let id = event.params["item"]?["id"]?.stringValue, ["item/started", "item/completed"].contains(event.method) {
                check(lastHint == .itemChanged(itemID: id), "mock lifecycle preserves dirty ID")
            } else if let id = event.params["itemId"]?.stringValue, event.params["delta"]?.stringValue != nil {
                mockAppends += 1; check(lastHint == .itemAppended(itemID: id) || lastHint == .itemChanged(itemID: id), "mock delta preserves dirty ID")
            } else { check(lastHint == .structural, "mock metadata is structural") }
        }
        mock.start(live: false); for _ in 0..<40 { _ = mock.step() }
        check(mockEvents > 0 && mockAppends > 0, "mock seed and tick paths both exercised")
        mockStore.removeObserver(token)

        let backend = FixtureBackend(), (runtime, _) = backend.runtime()
        let chat = runtime.conversation(threadID: "typed-live")
        var live: [ConversationChange] = []
        let liveToken = runtime.store.observeChanges { model, hint in if model === chat { live.append(hint) } }
        func receive(_ id: Int, _ method: String, _ fields: JSONValue) {
            var p = fields.objectValue ?? [:]; p["threadId"] = "typed-live"; p["turnId"] = "t"
            runtime.receive(.init(id: id, time: 100, method: method, params: .object(p)))
        }
        receive(1, "turn/started", [:]); receive(2, "item/started", ["item": row("answer", "")])
        receive(3, "item/agentMessage/delta", ["itemId": "answer", "delta": "**live**"])
        check(live.suffix(3) == [.structural, .itemChanged(itemID: "answer"), .itemAppended(itemID: "answer")], "Live applies same classifier after watermark gates")
        let published = live.count
        receive(3, "item/agentMessage/delta", ["itemId": "answer", "delta": "duplicate"])
        check(live.count == published && chat.items.last?.text == "**live**", "duplicate SSE produces no hint and no duplicate bytes")
        receive(4, "item/completed", ["item": row("answer", "**live**")])
        check(live.last == .itemChanged(itemID: "answer"), "Live completion carries ID")
        receive(5, "turn/completed", ["turn": ["id": "t", "status": "interrupted"]])
        let terminal = live.count
        receive(6, "item/agentMessage/delta", ["itemId": "answer", "delta": "late"])
        check(live.count == terminal && chat.items.last?.text == "**live**", "late terminal delta cannot revive completed rows or publish a dirty hint")
        backend.threads["typed-live"] = ["id": "typed-live", "turns": [turn("t", "completed", [row("answer", "restored")])]]
        backend.high = 6
        try await runtime.read(chat, includeSatellites: false)
        check(live.last == .structural && chat.items.last?.text == "restored", "history reload publishes structural after replay/merge")
        let reloadStart = live.count
        backend.before = { r in
            if r.rpc == "thread/read" {
                runtime.receive(.init(id: 7, time: 100, method: "item/started", params: ["threadId": "typed-live", "turnId": "new-turn", "item": row("buffered", "Buffered replay")]))
            }
            return nil
        }
        try await runtime.read(chat, includeSatellites: false)
        check(live.dropFirst(reloadStart).allSatisfy { $0 == .structural } && chat.items.last?.id == "buffered", "events buffered across history reload publish structural, never stale item hints")
        runtime.store.removeObserver(liveToken); runtime.shutdown()
    }

    /// Revert's paths: the App Server's absolute file paths become paths inside the repository Core's git routes take.
    private static func revertPaths() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "organic-revert-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: tmp) }
        let real = tmp.resolvingSymlinksInPath().path
        check(LiveConversationRuntime.repositoryRelative(real + "/README.md", root: real) == "README.md", "revert path: absolute file inside the repository")
        check(LiveConversationRuntime.repositoryRelative(real + "/a/b.swift", root: real) == "a/b.swift", "revert path: nested file")
        check(LiveConversationRuntime.repositoryRelative("/tmp/../private/tmp/x", root: "/private/tmp") == "x", "revert path: resolves dot-dot and /tmp")
        check(LiveConversationRuntime.repositoryRelative("/etc/hosts", root: real) == nil, "revert path: outside the repository is refused")
        check(LiveConversationRuntime.repositoryRelative(real + "-other/x", root: real) == nil, "revert path: a sibling with the same prefix is outside")
        check(LiveConversationRuntime.repositoryRelative("docs/a.md", root: real) == "docs/a.md", "revert path: already relative stays")
    }
    private static func identityAssignment() async throws {
        func fixture(id:String,identityIndex:Int,title:String)->Conversation { let c=Conversation(id:id,title:title); c.identityIndex=identityIndex; return c }
        let store=ConversationStore()
        for index in 0..<52 {
            check(store.nextIdentity() == index,"first-free assignment \(index)")
            store.add(fixture(id:"identity-\(index)",identityIndex:index,title:"Identity"))
        }
        check(Set((0..<52).map(ConversationIdentity.assigned)).count == 52,"first52 symbol/tint combinations never repeat")
        let sparse=ConversationStore(conversations:[fixture(id:"one",identityIndex:1,title:"One"),fixture(id:"three",identityIndex:3,title:"Three")])
        check(sparse.nextIdentity() == 0,"identity allocation fills the first unused combination")
        let changed=fixture(id:"custom",identityIndex:0,title:"Custom"); changed.identitySymbol="mars"; changed.identityTint="rust"
        let custom=ConversationStore(conversations:[changed])
        check(custom.nextIdentity() == 0,"custom identity releases its original assigned pair")
        let occupied=fixture(id:"other",identityIndex:77,title:"Other"); occupied.identitySymbol="mercury"; occupied.identityTint="silver"; custom.add(occupied)
        check(custom.nextIdentity() == 1,"custom identity also occupies its actual symbol/tint combination")
        let archived=fixture(id:"archived",identityIndex:0,title:"Archived"); archived.archived=true
        check(ConversationStore(conversations:[archived]).nextIdentity() == 1,"archived conversations keep their identity as in product")
        let all=ConversationStore(conversations:(0..<169).map { fixture(id:"all-\($0)",identityIndex:$0,title:"All") })
        check(all.nextIdentity() == 169,"fully occupied finite palette cannot hang allocation")
        check(ConversationIdentity.resolved(index:4,symbol:"unknown",tint:"unknown") == ConversationIdentity.assigned(4),"invalid stored identity names preserve the index fallback")
    }
    private static func wire() async throws {
        let value: JSONValue = ["null": nil, "bool": true, "int": 7, "decimal": 1.5, "unicode": "首句 🌅", "array": [1, "a"], "object": ["k": "v"]]
        check(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value, "JSON typed round trip")
        check(value["missing"] == nil && value["null"] == .null, "missing differs from null")
        check(value["decimal"]?.intValue == nil && value["bool"]?.intValue == nil, "strict integer and boolean decoding")
        let e = CoreEvent(id: 12, time: 1.25, method: "item/agentMessage/delta", params: ["threadId": "t", "delta": "首句 🌅"])
        let json = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        let data = Data(("\u{FEFF}: heartbeat\r\nid: 12\r\nevent: \(e.method)\r\ndata: \(json)\r\n\r\n").utf8)
        for chunkSize in [1, 2, 3, 7, 31, data.count] {
            var parser = CoreSSEParser(since: 11), events: [CoreEvent] = []
            for start in stride(from: 0, to: data.count, by: chunkSize) { events += try parser.append(data.subdata(in: start..<min(data.count, start + chunkSize))) }
            check(events == [e] && parser.lastEventID == 12, "split CRLF/UTF8/BOM chunk \(chunkSize)")
            check(try parser.append(data).isEmpty, "exclusive cursor deduplicates \(chunkSize)")
        }
        var partial = CoreSSEParser(since: 11)
        _ = try partial.append(Data("id: 12\ndata: \(json)\n".utf8)); partial.finish()
        check(partial.lastEventID == 11, "EOF partial frame never commits cursor")
        var multi = CoreSSEParser()
        check(try multi.append(Data("data: {\"id\":13,\ndata: \"method\":\"notice\",\"params\":{},\"time\":null}\n\n".utf8)).first?.id == 13, "multiline data frame")
        for envelope in ["id: 99\n", "event: wrong\n"] {
            var p = CoreSSEParser(); do { _ = try p.append(Data((envelope + "data: " + json + "\n\n").utf8)); check(false, "mismatched envelope rejected") } catch { check(p.lastEventID == 0, "bad envelope cursor stays unchanged") }
        }
        var malformed = CoreSSEParser(); do { _ = try malformed.append(Data([100, 97, 116, 97, 58, 32, 255, 10])); check(false, "invalid UTF8 rejected") } catch { check(true, "invalid UTF8 rejected") }
        check(CoreWire.segment("a/b ?#&") == "a%2Fb%20%3F%23%26", "opaque approval path encoding")
        let query = URLComponents(string: CoreWire.eventPage(threadID: "a&b?#/首", since: 17))!
        check(query.queryItems?.first?.value == "a&b?#/首", "opaque history thread query encoding")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = CoreClient(baseURL: URL(string: "http://core.invalid:1")!, session: session)
        FixtureURLProtocol.prepare("{\"result\":null}")
        check(try await client.request(path: "/null") == .null, "HTTP explicit null success")
        FixtureURLProtocol.prepare("{\"result\":{\"ok\":true}}")
        check(try await client.rpc("thread/start", params: ["key": "首句"]) == ["ok": true], "RPC envelope decoded")
        let request = FixtureURLProtocol.lastRequest!
        check(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type") == "application/json", "RPC method and content type")
        check(try JSONDecoder().decode(JSONValue.self, from: request.httpBody!) == ["method": "thread/start", "params": ["key": "首句"]], "RPC exact body")
        for (body, status, code) in [("{\"error\":{\"code\":-42,\"message\":\"denied\",\"data\":{\"why\":true}}}",200,-42), ("{\"error\":{\"code\":401,\"message\":\"expired\"}}",401,401), ("broken",502,0), ("{}",200,0), ("bad json",200,0)] {
            FixtureURLProtocol.prepare(body, status: status)
            do { _ = try await client.request(path: "/failure"); check(false, "bad HTTP rejected") } catch let error as CoreError { check(error.httpStatus == status && (error.code ?? 0) == code, "preserve Core status/code \(status)/\(code)") }
        }
        let count = FixtureURLProtocol.lastRequest
        do { _ = try await client.request(path: "http://other.invalid/rpc"); check(false, "cross origin rejected") } catch { check(FixtureURLProtocol.lastRequest == count, "cross origin never requested") }
        FixtureURLProtocol.prepare("id: 12\nevent: \(e.method)\ndata: \(json)\n\n", mime: "text/event-stream")
        var streamed: [CoreEvent] = []
        for try await event in client.events(since: 11, threadID: "t&x") { streamed.append(event) }
        check(streamed == [e], "URLSession SSE bytes parsed")
        check(FixtureURLProtocol.lastRequest?.value(forHTTPHeaderField: "Last-Event-ID") == "11", "SSE Last-Event-ID header")
        check(URLComponents(url: FixtureURLProtocol.lastRequest!.url!, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "t&x", "SSE query percent encoding")
        check(CoreWire.isAmbiguous(URLError(.timedOut)), "network timeout is unknown")
        check(!CoreWire.isAmbiguous(CoreError(code: 400, message: "invalid", data: nil, httpStatus: 400)), "explicit validation failure is known")
    }
    private static func ownership() async throws {
        let data = URL(fileURLWithPath: "/fixture/core", isDirectory: true)
        let defaultConfig = try CoreEndpointConfiguration.resolve(arguments: [], savedURL: nil, dataDirectory: data)
        check(defaultConfig.managesLocalCore && defaultConfig.baseURL.port == 18794, "only implicit endpoint owns launch")
        for config in [try CoreEndpointConfiguration.resolve(arguments: ["--core-url", "http://127.0.0.1:19999"], savedURL: nil, dataDirectory: data), try CoreEndpointConfiguration.resolve(arguments: [], savedURL: "http://localhost:17777", dataDirectory: data), try CoreEndpointConfiguration.resolve(arguments: [], savedURL: nil, explicitURL: URL(string: "https://remote.invalid:3"), dataDirectory: data)] {
            check(!config.managesLocalCore, "explicit/saved endpoint never launches substitute")
            let launcher = FixtureLauncher(), t = FixtureTransport { _ in throw URLError(.cannotConnectToHost) }
            let service = CoreService(configuration: config, transport: t, launcher: launcher, clock: ImmediateClock(), marker: { nil })
            do { try await service.connect(); check(false, "unreachable explicit service fails") } catch { check(launcher.launches == 0, "unreachable explicit service starts no process") }
        }
        for url in ["file:///tmp/core", "", "http:"] {
            do { _ = try CoreEndpointConfiguration.resolve(arguments: ["--core-url", url], savedURL: nil, dataDirectory: data); check(false, "invalid endpoint rejected") } catch { check(true, "invalid endpoint rejected") }
        }
        let explicit = try CoreEndpointConfiguration.resolve(arguments: ["--core-url"], savedURL: "not a URL", explicitURL: URL(string: "http://core.invalid:9"), dataDirectory: data)
        check(explicit.baseURL.host == "core.invalid" && !explicit.managesLocalCore, "explicit endpoint wins over malformed lower-priority settings")
        let b = FixtureBackend(); let marker: JSONValue = ["instanceId": "fixture-instance", "pid": 4242]
        check(CoreLocalIdentity(health: b.health, localMarker: marker, dataDirectory: data).verified, "matching local marker is proof")
        for bad: JSONValue? in [nil, ["instanceId": "other", "pid": 4242], ["instanceId": "fixture-instance", "pid": 0], ["instanceId": "", "pid": 4242], ["instanceId": "fixture-instance", "pid": 2]] {
            check(!CoreLocalIdentity(health: b.health, localMarker: bad, dataDirectory: data).verified, "marker mismatch cannot prove locality")
        }
        check(!CoreLocalIdentity(health: b.health, localMarker: marker, dataDirectory: URL(fileURLWithPath: "/different")).verified, "data directory mismatch")
        let launcher = FixtureLauncher(); var first = true
        b.before = { r in if r.path == "/health" && first { first = false; throw URLError(.cannotConnectToHost) }; return nil }
        let service = CoreService(configuration: defaultConfig, transport: FixtureTransport { try await b.respond($0) }, launcher: launcher, clock: ImmediateClock(), marker: { marker })
        try await service.connect()
        check(launcher.launches == 1 && service.state == .connected && service.isLocalBackend, "owned missing listener launches once with verified identity")
        check(service.runtimeVersion == "fixture-v7" && service.schedulerVersion == "deployed-v1", "deployed versions retained truthfully")
        check(service.authorizationCount == 2 && service.capability("voice").available == false, "authorization count and disabled capability")
        check(service.capability("absent").available == nil, "unknown capability stays unknown")
        let auth = try await service.readAuthorizations()
        check(auth == ["grants": []], "authorization read preserves backend payload")
        _ = try await service.grantAuthorization(threadID: "t", app: "Safari", connectorID: "computer-use", tools: ["click"])
        check(b.requests.last?.body == ["threadId": "t", "app": "Safari", "connectorId": "computer-use", "tools": ["click"]], "explicit authorization scope preserved")
        _ = try await service.revokeAuthorization("id/ ?")
        check(b.requests.last?.path == "/authorizations/id%2F%20%3F" && b.requests.last?.method == "DELETE", "authorization revoke encodes opaque ID")
        b.capabilities = ["version": "fixture-v8", "features": ["scheduler": ["available": false, "reason": "not deployed"]]]
        try await service.refreshCapabilities()
        check(service.runtimeVersion == "fixture-v8" && service.schedulerVersion == nil && service.capability("scheduler").available == false, "capability refresh doesn't invent scheduler version")
        service.disconnect(); check(launcher.isRunning && service.state == .disconnected, "disconnect never terminates owned backend")
        b.before = nil; b.name = "other"
        let denied = CoreService(configuration: defaultConfig, transport: FixtureTransport { try await b.respond($0) }, launcher: FixtureLauncher(), marker: { nil })
        do { try await denied.connect(); check(false, "wrong service rejected") } catch { check(denied.state != .connected, "wrong service rejected without launch") }
        b.name = "Organic Codex Core"; b.connected = false
        do { try await denied.connect(); check(false, "disconnected runtime rejected") } catch { check(true, "disconnected runtime rejected") }
    }
    private static func history() async throws {
        let b = FixtureBackend(); b.high = 50
        b.sessions = [["id": "session", "name": "Real session", "loaded": false, "active": nil]]
        b.history["active:"] = ["data": [["id": "old", "preview": "Old", "updatedAt": 10]], "nextCursor": "page2"]
        b.history["active:page2"] = ["data": [["id": "older", "name": "Older"]]]
        b.history["archived:"] = ["data": [["id": "archived", "name": "Archive"]]]
        b.modelPages[""] = ["data": [["id": "unknown-effort", "displayName": "Official Name", "serviceTiers": [["id": "ultrafast"]]]], "nextCursor": "models2"]
        b.modelPages["models2"] = ["data": [["id": "wire-sol", "displayName": "Sol Live", "isDefault": true, "supportedReasoningEfforts": ["high"], "defaultReasoningEffort": "high", "serviceTiers": ["priority"]]]]
        let (r, _) = b.runtime(); try await r.load()
        check(r.eventCursor == 50 && r.isConnected, "bootstrap anchors event cursor before reads")
        check(r.store.conversations.count == 3, "sessions and active/archived first pages hydrated")
        check(r.hasMoreHistory() && r.historyCursor() == "page2" && !r.hasMoreHistory(archived: true), "public pagination state")
        try await r.loadMoreHistory(); check(!r.hasMoreHistory() && r.store.backendConversation("older") != nil, "second page and exhausted state")
        let requests = b.count("thread/list"); try await r.loadMoreHistory(); check(b.count("thread/list") == requests, "exhausted history issues no request")
        check(r.store.backendConversation("archived")?.archived == true, "archived truth from backend")
        check(ModelCatalog.models.map(\.name) == ["Official Name", "Sol Live"], "all model pages preserve official names")
        check(ModelCatalog.model("unknown-effort").efforts.isEmpty && ModelCatalog.defaultEffort(ModelCatalog.model("unknown-effort")) == .none, "unknown efforts don't invent High")
        check(ModelCatalog.model("unknown-effort").availableSpeeds == [.standard, .ultrafast], "advertised object tiers only")
        check(!r.store.quotaAnyReported && r.store.quotaMenuSummary == "Usage not reported", "missing quota stays unavailable")
        let context = r.store.backendConversation("session")!
        context.contextLimit = 12345
        check(!context.contextUsageReported && context.contextDescription == "Context usage has not been reported", "known context limit doesn't fabricate zero used")
        context.exactTokensUsed = 123
        check(context.reportedTokensUsed == 123 && context.tokensUsed == 123 && context.contextUsageReported && context.contextDescription.hasPrefix("123 of"), "live token count stays exact without rounding percent")
        r.receive(b.event(51, "account/rateLimits/updated", ["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 24, "windowDurationMins": 300]]]]))
        check(r.store.quotaFiveHourReported && !r.store.quotaWeekReported && r.store.quotaFiveHour == 0.24, "partial quota reports only its actual window")
        let c = r.store.backendConversation("session")!; c.next.modelID = "wire-sol"; c.next.effort = .high
        var ack: CoreSubmissionReceipt?
        _ = r.submit(.init(identity: c.id, text: "resume", settings: c.next), in: c) { ack = $0 }
        await wait("resume accepted") { ack != nil }
        check(b.count("thread/resume") == 1 && b.count("turn/start") == 1 && ack?.result == .accepted, "unloaded history resumes before sending")
        let order = b.requests.compactMap(\.rpc)
        check(order.firstIndex(of: "thread/resume")! < order.firstIndex(of: "turn/start")!, "resume order precedes turn")
        let unsupported = c.next; c.next.modelID = "removed-model"
        try await r.load(); check(c.next.modelID == "removed-model", "refresh never silently substitutes retired selection")
        c.next = unsupported; r.shutdown()
        let paging = FixtureBackend(); paging.history["active:"] = ["data": [], "nextCursor": "loop"]; paging.history["active:loop"] = ["data": [], "nextCursor": "loop"]
        let (p, _) = paging.runtime(); try await p.load()
        do { try await p.loadMoreHistory(); check(false, "repeated cursor rejected") } catch { check(p.historyCursor() == "loop", "repeated cursor retains recoverable position") }; p.shutdown()
    }
    private static func watermarks() async throws {
        let b = FixtureBackend(), (r, _) = b.runtime(); try await r.load()
        let c = r.conversation(threadID: "t&?#首")
        b.threads[c.backendThreadID!] = ["id": .string(c.backendThreadID!), "turns": [turn("turn1", "inProgress", [row("answer", "Snapshot whole answer")])]]
        b.log = [b.event(1, "item/agentMessage/delta", ["threadId": .string(c.backendThreadID!), "turnId": "turn1", "itemId": "answer", "delta": "tail"])]
        b.high = 1
        var loadingStates: [Bool] = []; let observation = r.store.observe { chat in if chat.id == c.id { loadingStates.append(chat.loading) } }
        try await r.read(c, includeSatellites: false)
        r.store.removeObserver(observation)
        check(loadingStates.first == true && loadingStates.last == false, "plain models publish both read loading transitions")
        check(c.items.first?.text == "Snapshot whole answer", "unversioned partial delta cannot truncate snapshot")
        check(r.readWatermark(threadID: c.backendThreadID!) == 1, "read high water committed")
        r.receive(b.event(1, "item/agentMessage/delta", ["threadId": .string(c.backendThreadID!), "itemId": "answer", "delta": "duplicate"]))
        check(c.items.first?.text == "Snapshot whole answer", "SSE at read watermark skipped")
        r.receive(b.event(2, "item/agentMessage/delta", ["threadId": .string(c.backendThreadID!), "turnId": "turn1", "itemId": "answer", "delta": "+new"]))
        check(c.items.first?.text == "Snapshot whole answer+new", "new SSE delta applied once")
        b.high = 3; b.log.append(b.event(3, "turn/completed", ["threadId": .string(c.backendThreadID!), "turn": ["id": "turn1", "status": "completed"]]))
        b.threads[c.backendThreadID!] = ["id": .string(c.backendThreadID!), "turns": [turn("turn1", "completed", [row("answer", "Terminal complete text")])]]
        try await r.read(c, includeSatellites: false)
        check(!c.running && c.items.first?.text == "Terminal complete text", "terminal snapshot beats stale seeded text")
        r.receive(b.event(4, "turn/started", ["threadId": .string(c.backendThreadID!), "turn": ["id": "turn1"]]))
        check(!c.running, "late lifecycle cannot resurrect terminal turn")
        r.receive(b.event(5, "item/started", ["threadId": .string(c.backendThreadID!), "turnId": "turn1", "item": row("answer", "stale started")]))
        r.receive(b.event(6, "item/agentMessage/delta", ["threadId": .string(c.backendThreadID!), "turnId": "turn1", "itemId": "answer", "delta": "late"] ))
        check(c.items.first?.text == "Terminal complete text", "late started/delta cannot corrupt terminal row baseline")
        b.high = 6
        let revision = c.items.first!.revision
        try await r.read(c, includeSatellites: false)
        check(c.items.first?.revision == revision, "unchanged snapshot preserves row revision")
        b.failures["thread/read"] = CoreWire.failure("fixture read failed")
        let watermark = r.readWatermark(threadID: c.backendThreadID!)
        do { try await r.read(c); check(false, "read failure surfaced") } catch { check(!c.loading && r.readWatermark(threadID: c.backendThreadID!) == watermark, "failed read does not commit watermark or stick loading") }
        b.failures = [:]
        b.before = { request in request.rpc == "thread/read" ? [:] : nil }
        do { try await r.read(c); check(false, "malformed thread history rejected") } catch { check(r.readWatermark(threadID: c.backendThreadID!) == watermark, "malformed read cannot advance history watermark") }
        b.before = nil
        let interleaved = r.conversation(threadID: "interleaved")
        var injected = false
        b.before = { request in
            if request.rpc == "thread/read", request.params["threadId"] == "interleaved", !injected {
                injected = true
                r.receive(b.event(10, "item/started", ["threadId": "interleaved", "turnId": "i-turn", "item": row("i-row", "buffered")]))
            }
            return nil
        }
        b.high = 8; try await r.read(interleaved, includeSatellites: false)
        check(interleaved.items.first?.text == "buffered" && r.readWatermark(threadID: "interleaved") == 10, "SSE buffered above read high watermark reapplied")
        b.before = nil
        // A completion after an incomplete snapshot permits exactly one bounded follow-up.
        let final = r.conversation(threadID: "final"); b.high = 20
        b.threads["final"] = ["id": "final", "turns": [turn("final-turn", "inProgress", [])]]
        b.log = [b.event(20, "turn/completed", ["threadId": "final", "turn": ["id": "final-turn", "status": "completed"]])]
        let count = b.count("thread/read"); try await r.read(final, includeSatellites: false)
        await wait("one follow-up read") { b.count("thread/read") >= count + 2 }
        for _ in 0..<100 { await Task.yield() }
        check(b.count("thread/read") == count + 2 && !final.running, "completion follow-up bounded to one snapshot")
        r.shutdown()
        let epochBackend = FixtureBackend(), (epochRuntime, _) = epochBackend.runtime(); try await epochRuntime.load()
        let epochChat = epochRuntime.conversation(threadID: "epoch-read")
        var releaseOldRead: CheckedContinuation<JSONValue, Never>?
        epochBackend.before = { request in
            if request.rpc == "thread/read" { return await withCheckedContinuation { releaseOldRead = $0 } }; return nil
        }
        let oldRead = Task { do { try await epochRuntime.read(epochChat, includeSatellites: false); return false } catch { return true } }
        await wait("old epoch read in flight") { releaseOldRead != nil }
        epochRuntime.receive(epochBackend.event(90, "item/started", ["threadId": "epoch-read", "turnId": "old-turn", "item": row("old-row", "old buffered content")]))
        epochBackend.instance = "replacement"; epochBackend.high = 1
        try await epochRuntime.reload()
        releaseOldRead?.resume(returning: ["thread": ["id": "epoch-read", "turns": []]])
        check(await oldRead.value && epochChat.items.isEmpty && !epochChat.loading, "backend epoch invalidates both old read and buffered old SSE")
        epochRuntime.shutdown()
    }
    private static func ready(storage: CoreMemoryStorage = CoreMemoryStorage()) async throws -> (FixtureBackend, LiveConversationRuntime, FixtureTransport, Conversation) {
        let b = FixtureBackend(), (r, t) = b.runtime(storage: storage); try await r.load()
        let c = r.createUnsentConversation(title: "Unsent", projectID: nil); r.store.add(c)
        return (b, r, t, c)
    }
    private static func submissions() async throws {
        let (b, r, _, c) = try await ready()
        check(c.backendThreadID == nil && b.count("thread/start") == 0 && b.count("turn/start") == 0, "two-phase identity is unsent")
        let file = Attachment(id: "file1", name: "memory.txt", symbol: "doc", input: ["type": "text", "text": "attached"])
        c.draft = "first"; c.attachments = [file]
        let id = UUID(), s = CoreSubmission(id: id, identity: c.id, text: "first", attachments: [file], settings: c.next)
        var receipt: CoreSubmissionReceipt?, callbacks = 0
        check(r.submit(s, in: c) { receipt = $0; callbacks += 1 }, "send admitted")
        c.draft = "new typing"; c.next.effort = .ultra
        await wait("first acceptance") { receipt != nil }
        check(receipt?.id == id && receipt?.result == .accepted && receipt?.acceptance == .backend, "same UUID backend acceptance")
        check(b.count("thread/start") == 1 && b.count("turn/start") == 1, "first message creates then submits once")
        check(c.draft == "new typing" && c.attachments.isEmpty && c.settings.effort == .high, "immutable snapshot and newer draft retained")
        let write = b.requests.first { $0.rpc == "turn/start" }!
        check(write.params["clientUserMessageId"] == .string(id.uuidString) && write.params["effort"] == "high", "wire UUID and captured effort")
        check(write.params["input"]?.arrayValue?.count == 2 && write.params["serviceTierForTurn"] == "default", "attachment input and standard tier")
        _ = r.submit(s, in: c) { receipt = $0; callbacks += 1 }
        check(b.count("turn/start") == 1 && callbacks == 2, "same UUID returns cached receipt without repeat write")
        var mismatch: CoreSubmissionReceipt?
        check(!r.submit(.init(id: id, identity: c.id, text: "different", settings: c.next), in: c) { mismatch = $0 }, "UUID reuse with changed payload rejected")
        if case .failed = mismatch?.result { check(true, "changed UUID snapshot gives failed") } else { check(false, "changed UUID snapshot gives failed") }
        let steerID = UUID(); var steer: CoreSubmissionReceipt?
        let captured = c.activeTurnID
        _ = r.submit(.init(id: steerID, identity: c.id, action: .steer, text: "direction", settings: c.next, waitingForTurnID: captured), in: c) { steer = $0 }
        await wait("steer acceptance") { steer != nil }
        check(b.count("turn/steer") == 1 && b.requests.last?.params["expectedTurnId"] == .string(captured!), "steer uses exact captured turn")
        var stale: CoreSubmissionReceipt?
        check(!r.submit(.init(identity: c.id, action: .steer, text: "late", settings: c.next, waitingForTurnID: "old-turn"), in: c) { stale = $0 }, "stale captured turn rejected")
        check(b.count("turn/steer") == 1 && stale != nil, "stale steer sent no RPC")
        var wrong: CoreSubmissionReceipt?
        check(!r.submit(.init(identity: "other", text: "wrong", settings: c.next), in: c) { wrong = $0 }, "identity mismatch blocked")
        check(wrong != nil, "identity mismatch returns matching receipt")
        r.shutdown()
        for (failure, unknown) in [(CoreError(code: 400, message: "invalid model", data: nil, httpStatus: 400) as Error, false), (URLError(.networkConnectionLost) as Error, true), (CoreError(code: 500, message: "server broke", data: nil, httpStatus: 500) as Error, true)] {
            let (backend, runtime, _, chat) = try await ready(); chat.backendThreadID = "existing"; chat.draft = "keep draft"
            backend.failures["turn/start"] = failure
            let snapshot = CoreSubmission(identity: chat.id, text: "keep draft", settings: chat.next); var result: CoreSubmissionReceipt?
            _ = runtime.submit(snapshot, in: chat) { result = $0 }; await wait("submission failure") { result != nil }
            check(chat.sendOutcomeUnknown == unknown && chat.draft == "keep draft", "failure preserves draft and ambiguity classification")
            if unknown { if case .outcomeUnknown = result?.result { check(true, "transport/server unknown receipt") } else { check(false, "transport/server unknown receipt") } }
            else { if case .failed = result?.result { check(true, "explicit failed receipt") } else { check(false, "explicit failed receipt") } }
            _ = runtime.submit(snapshot, in: chat) { _ in }; check(backend.count("turn/start") == 1, "failed/unknown UUID never blindly repeated")
            if unknown {
                backend.failures = [:]
                try await runtime.read(chat, includeSatellites: false)
                check(chat.sendOutcomeUnknown, "history without receipt does not infer failure")
                backend.threads["existing"] = ["id": "existing", "turns": [turn("receipt-turn", "completed", [row("receipt", "keep draft", type: "userMessage", clientID: snapshot.id)])]]
                try await runtime.read(chat, includeSatellites: false)
                check(!chat.sendOutcomeUnknown && runtime.receipt(for: snapshot.id)?.result == .accepted, "late history receipt resolves unknown by UUID")
            }
            runtime.shutdown()
        }
        let (reentrant, rr, _, rc) = try await ready(); rc.backendThreadID = "reentrant"
        var release: CheckedContinuation<JSONValue, Never>?, second: CoreSubmissionReceipt?
        reentrant.before = { request in
            if request.rpc == "turn/steer" { return await withCheckedContinuation { release = $0 } }
            return nil
        }
        _ = rr.submit(.init(identity: rc.id, text: "first", settings: rc.next), in: rc) { result in
            if result.result == .accepted {
                _ = rr.submit(.init(identity: rc.id, action: .steer, text: "second", settings: rc.next, waitingForTurnID: rc.activeTurnID), in: rc) { second = $0 }
            }
        }
        await wait("reentrant submit reaches held RPC") { release != nil }
        check(rc.sending && second == nil, "first completion cannot clear a reentrant second send's pending flag")
        release?.resume(returning: ["turnId": "accepted-turn"])
        await wait("reentrant submit accepted") { second != nil }
        check(second?.result == .accepted && !rc.sending, "nested immutable submission settles independently")
        rr.shutdown()
        let (race, live, _, chat) = try await ready(); chat.backendThreadID = "receipt-race"
        var callbackCount = 0, raceReceipt: CoreSubmissionReceipt?
        race.before = { request in
            if request.rpc == "turn/start" {
                let uuid = UUID(uuidString: request.params["clientUserMessageId"]!.stringValue!)!
                live.receive(race.event(1, "item/completed", ["threadId": "receipt-race", "turnId": "receipt-turn", "item": row("received", "receipt first", type: "userMessage", clientID: uuid)]))
                throw URLError(.timedOut)
            }; return nil
        }
        _ = live.submit(.init(identity: chat.id, text: "receipt first", settings: chat.next), in: chat) { raceReceipt = $0; callbackCount += 1; chat.sending = false; chat.draft = "typed after receipt" }
        await wait("receipt race settles") { !chat.sending }
        check(raceReceipt?.result == .accepted && callbackCount == 1 && !chat.sendOutcomeUnknown && chat.draft == "typed after receipt", "SSE receipt wins over later HTTP timeout and composer state changes exactly once")
        live.shutdown()
        let storage = CoreMemoryStorage(); storage.writeError = CoreWire.failure("disk full")
        let (fail, blocked, _, target) = try await ready(storage: storage); var failReceipt: CoreSubmissionReceipt?
        check(!blocked.submit(.init(identity: target.id, text: "durable", settings: target.next), in: target) { failReceipt = $0 }, "unsaved intent rejected before remote mutation")
        check(fail.count("thread/start") == 0 && fail.count("turn/start") == 0 && failReceipt != nil, "storage failure made no backend writes"); blocked.shutdown()
        let (creation, cr, _, cc) = try await ready(); creation.failures["thread/start"] = URLError(.timedOut)
        var creationReceipt: CoreSubmissionReceipt?
        _ = cr.submit(.init(identity: cc.id, text: "create once", settings: cc.next), in: cc) { creationReceipt = $0 }
        await wait("ambiguous creation") { creationReceipt != nil }
        check(cc.backendThreadID == nil && cc.sendOutcomeUnknown && creation.count("thread/start") == 1 && creation.count("turn/start") == 0, "ambiguous thread creation does not submit or retry")
        try cr.adoptCreatedThread("inspected-history-thread", for: cc)
        check(cc.backendThreadID == "inspected-history-thread" && cc.sendOutcomeUnknown, "explicit adoption doesn't silently resend")
        cr.resolveUnknownAfterReview(cc); check(!cc.sendOutcomeUnknown && creation.count("thread/start") == 1, "manual review unlocks without resend"); cr.shutdown()
    }
    private static func queueAndStop() async throws {
        let (b, r, _, c) = try await ready(); c.backendThreadID = "queue"; c.running = true; c.activeTurnID = "previous"; c.draft = "queued text"
        let s = CoreSubmission(identity: c.id, action: .queue, text: c.draft, settings: c.next, waitingForTurnID: "previous")
        var receipt: CoreSubmissionReceipt?
        check(r.submit(s, in: c) { receipt = $0 }, "queue admitted")
        check(receipt?.result == .accepted && receipt?.acceptance == .durableLocalQueue && c.queued.count == 1, "queue acknowledgment means durable local acceptance")
        check(c.draft.isEmpty && b.count("turn/start") == 0 && b.count("turn/steer") == 0, "queue doesn't send before preceding completion")
        b.high = 1; b.threads["queue"] = ["id": "queue", "turns": [turn("previous", "completed", [])]]
        r.receive(b.event(1, "turn/completed", ["threadId": "queue", "turn": ["id": "previous", "status": "completed"]]))
        await wait("queue delivered") { b.count("turn/start") == 1 && !c.sending }
        check(c.queued.isEmpty && b.requests.first(where: { $0.rpc == "turn/start" })?.params["clientUserMessageId"] == .string(s.id.uuidString), "queue retains submission UUID on real dispatch")
        check(r.receipt(for: s.id)?.acceptance == .backend, "queue receipt upgrades after backend acceptance")
        var stopReceipt: CoreSubmissionReceipt?, stopCallbacks = 0; let stopID = UUID()
        r.interrupt(c, id: stopID) { stopReceipt = $0; stopCallbacks += 1 }
        await wait("stop accepted") { stopReceipt != nil }
        check(stopReceipt?.result == .accepted && c.stopping, "interrupt response doesn't fake terminal turn")
        r.interrupt(c, id: stopID) { _ in stopCallbacks += 1 }
        check(b.count("turn/interrupt") == 1 && stopCallbacks == 2, "same stop UUID doesn't repeat interrupt")
        let active = c.activeTurnID ?? "accepted-turn"
        b.high = 2; b.threads["queue"] = ["id": "queue", "turns": [turn(active, "interrupted", [])]]
        let terminal = b.event(2, "turn/completed", ["threadId": "queue", "turn": ["id": .string(active), "status": "interrupted"]])
        b.log.append(terminal); r.receive(terminal)
        await wait("terminal stop reconciles buffered read") { !c.loading && !c.running && !c.stopping }
        check(!c.running && !c.stopping && c.lastTurnInterrupted, "actual terminal event owns stopped lifecycle")
        r.shutdown()
        let storage = CoreMemoryStorage(), (f, fr, _, fc) = try await ready(storage: storage)
        fc.running = true; fc.activeTurnID = "wait"; fc.draft = "keep queue draft"; storage.writeError = CoreWire.failure("full")
        var failed: CoreSubmissionReceipt?
        check(!fr.submit(.init(identity: fc.id, action: .queue, text: fc.draft, settings: fc.next, waitingForTurnID: "wait"), in: fc) { failed = $0 }, "queue save failure rejected")
        check(fc.queued.isEmpty && fc.draft == "keep queue draft" && f.count("turn/start") == 0 && failed != nil, "queue rollback preserves composer")
        storage.writeError = nil; fc.draft = ""
        fc.queued = [.init(id: UUID().uuidString, text: "first", settings: fc.next, waitingForTurnID: "wait"), .init(id: UUID().uuidString, text: "second", settings: fc.next, waitingForTurnID: "wait")]
        fc.backendThreadID = "failed-queue"; fc.running = true; fc.activeTurnID = "wait"
        f.high = 1; f.threads["failed-queue"] = ["id": "failed-queue", "turns": [turn("wait", "failed", [])]]
        let failedTurn = f.event(1, "turn/completed", ["threadId": "failed-queue", "turn": ["id": "wait", "status": "failed"]])
        f.log = [failedTurn]; fr.receive(failedTurn)
        check(fc.queued.allSatisfy { $0.deliveryError != nil } && f.count("turn/start") == 0, "failed preceding turn blocks all dependent queued entries")
        fc.queued[0].deliveryError = "preceding turn failed"
        let first = fc.queued[0]; fr.restoreQueuedToDraft(first, in: fc)
        check(fc.draft == "first" && fc.queued.count == 1 && fc.queued.first?.deliveryError != nil, "manual recovery never skips failed front to send successor")
        fr.shutdown()
        let (stopped, sr, _, sc) = try await ready(); sc.backendThreadID = "ambiguous-stop"; sc.running = true; sc.activeTurnID = "stop-turn"
        stopped.failures["turn/interrupt"] = URLError(.timedOut)
        var stopOutcome: CoreSubmissionReceipt?; let stopUUID = UUID()
        sr.interrupt(sc, id: stopUUID) { stopOutcome = $0 }; await wait("ambiguous stop") { stopOutcome != nil }
        if case .outcomeUnknown = stopOutcome?.result { check(sc.stopping, "ambiguous stop remains pending, not falsely failed") } else { check(false, "ambiguous stop classification") }
        sr.interrupt(sc, id: stopUUID) { _ in }; check(stopped.count("turn/interrupt") == 1, "ambiguous stop not retried")
        stopped.high = 1; stopped.threads["ambiguous-stop"] = ["id": "ambiguous-stop", "turns": [turn("stop-turn", "interrupted", [])]]
        let completion = stopped.event(1, "turn/completed", ["threadId": "ambiguous-stop", "turn": ["id": "stop-turn", "status": "interrupted"]]); stopped.log = [completion]; sr.receive(completion)
        check(sr.receipt(for: stopUUID)?.result == .accepted && !sc.stopping, "late interrupted event reconciles unknown stop")
        sr.shutdown()
        let (race, raceRuntime, _, raceChat) = try await ready(); raceChat.backendThreadID = "stop-race"; raceChat.running = true; raceChat.activeTurnID = "race-turn"
        race.before = { request in
            if request.rpc == "turn/interrupt" {
                let event = race.event(1, "turn/completed", ["threadId": "stop-race", "turn": ["id": "race-turn", "status": "interrupted"]])
                race.high = 1; race.log = [event]; race.threads["stop-race"] = ["id": "stop-race", "turns": [turn("race-turn", "interrupted", [])]]
                raceRuntime.receive(event); throw URLError(.timedOut)
            }; return nil
        }
        var raceReceipt: CoreSubmissionReceipt?; let raceID = UUID()
        raceRuntime.interrupt(raceChat, id: raceID) { raceReceipt = $0 }
        await wait("stop race ack") { raceReceipt != nil }
        for _ in 0..<100 { await Task.yield() }
        check(raceReceipt?.result == .accepted && raceRuntime.receipt(for: raceID)?.result == .accepted && raceChat.operationError == nil, "stop terminal receipt wins over later HTTP timeout")
        raceRuntime.shutdown()
    }
    private static func approvals() async throws {
        let b = FixtureBackend(), (r, _) = b.runtime(); try await r.load(); let c = r.conversation(threadID: "approval-thread")
        let schema: JSONValue = ["type": "object", "required": ["count", "name"], "additionalProperties": false, "properties": ["count": ["type": "integer", "minimum": 1, "maximum": 5], "name": ["type": "string", "minLength": 2], "mode": ["type": "string", "enum": ["safe", "fast"]]]]
        let elicitation: JSONValue = ["approvalId": "form/id ?&", "threadId": "approval-thread", "request": ["method": "elicitation/create", "params": ["requestedSchema": schema]]]
        let question: JSONValue = ["approvalId": "questions", "threadId": "approval-thread", "request": ["method": "item/tool/requestUserInput", "params": ["questions": [["id": "stable-secret", "header": "Secret", "question": "Token?", "isSecret": true], ["id": "stable-choice", "question": "Mode?", "options": [["label": "Safe", "description": "Read only"]]]]]]]
        b.pending = [elicitation, question]; b.high = 2
        b.log = [b.event(1, "core/approvalRequested", elicitation), b.event(2, "core/approvalRequested", question)]
        try await r.read(c, includeSatellites: false)
        check(c.approvals.count == 1 && c.approvals.first?.id == "form/id ?&", "elicitation restored from health")
        check(c.userInput?.questions.map(\.id) == ["stable-secret", "stable-choice"] && c.userInput?.questions.first?.isSecret == true, "question IDs and secret preserved")
        check(c.userInput?.questions.last?.options.first?.description == "Read only", "option description restored")
        let approval = c.approvals[0]
        let before = b.requests.count
        r.respond(approval, in: c, response: ["action": "accept", "content": ["count": 0, "name": "x"]])
        check(!c.approvals[0].submitting && b.requests.count == before, "invalid form prevented before HTTP")
        for (value, valid) in [(["count": 2, "name": "Sol", "mode": "safe"] as JSONValue, true), (["count": 1.5, "name": "Sol"], false), (["count": 2], false), (["count": 2, "name": "Sol", "extra": true], false), (["count": 2, "name": "Sol", "mode": "invented"], false)] {
            check((CoreResponseValidation.schema(value, against: schema) == nil) == valid, "required/type/range/enum/additional property validation")
        }
        check(CoreResponseValidation.schema("abc", against: ["type": "string", "pattern": "^[0-9]+$"]) != nil, "schema regex validation")
        check(CoreResponseValidation.schema([1, 1], against: ["type": "array", "uniqueItems": true, "items": ["type": "integer"]]) != nil, "schema unique array validation")
        check(CoreResponseValidation.schema("x", against: ["oneOf": []]) != nil, "oneOf rejects zero matching branches")
        check(CoreResponseValidation.schema("x", against: ["not": ["unsupported": true]]) != nil, "unknown constraint cannot hide inside negation")
        check(CoreResponseValidation.schema(nil, against: ["type": ["string", "null"]]) == nil, "nullable union schema")
        check(CoreResponseValidation.schema(0.3, against: ["type": "number", "multipleOf": 0.1]) == nil, "numeric schema interval tolerance")
        let path = "/approvals/" + CoreWire.segment(approval.id)
        b.failures[path] = CoreError(code: 409, message: "expired", data: nil, httpStatus: 409)
        r.respond(approval, in: c, response: ["action": "accept", "content": ["count": 2, "name": "Sol"]])
        await wait("approval error") { c.approvals.first?.submitting == false && b.count(path) == 1 }
        check(c.approvals.count == 1, "failed answer retains form for refresh/retry")
        b.failures = [:]
        r.respond(approval, in: c, response: ["action": "accept", "content": ["count": 2, "name": "Sol"]])
        await wait("valid approval") { c.approvals.isEmpty }
        check(b.count(path) == 2, "valid schema response reaches opaque approval path")
        let request = c.userInput!
        r.answer(request, in: c, answers: ["stable-secret": ["token"]])
        check(c.userInput?.submitting == false && b.count("/approvals/questions") == 0, "incomplete questions never sent")
        r.answer(request, in: c, answers: ["stable-secret": ["token"], "stable-choice": ["Safe"]])
        await wait("question answer") { c.userInput == nil }
        check(b.requests.last?.body == ["answers": ["stable-secret": ["answers": ["token"]], "stable-choice": ["answers": ["Safe"]]]], "wire answers retain original IDs")
        b.pending = []; try await r.read(c, includeSatellites: false)
        check(c.approvals.isEmpty && c.userInput == nil, "old event replay cannot resurrect answered approval or question")
        let dynamic = Approval(id: "dynamic", title: "Allow?", command: "cmd", note: "", acceptLabel: "Accept", toolItemID: "tool", method: "item/commandExecution/requestApproval", request: ["params": ["availableDecisions": ["decline", ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["ls"]]]]]])
        check(CoreResponseValidation.approval(["decision": "accept"], request: dynamic) != nil, "dynamic decision list rejects unavailable accept")
        check(CoreResponseValidation.approval(["decision": ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["ls"]]]], request: dynamic) == nil, "structured dynamic decision retained exactly")
        r.shutdown()
    }
    private static func children() async throws {
        let b = FixtureBackend(), (r, _) = b.runtime(); try await r.load()
        let parent = r.conversation(threadID: "parent")
        r.receive(b.event(1, "item/started", ["threadId": "parent", "turnId": "parent-turn", "item": ["id": "collab", "type": "collabAgentToolCall", "receiverThreadIds": ["child"], "prompt": "Investigate", "agentsStates": ["child": ["status": "running"]]]]))
        check(parent.satellites.count == 1 && parent.satellites[0].threadID == "child", "real child thread identifier projected")
        r.receive(b.event(2, "turn/started", ["threadId": "child", "turn": ["id": "child-turn"]]))
        r.receive(b.event(3, "item/completed", ["threadId": "child", "turnId": "child-turn", "item": row("child-row", "Real child output")]))
        check(parent.satellites[0].items.first?.text == "Real child output", "child SSE projects actual history into satellite")
        b.high = 4; b.threads["child"] = ["id": "child", "turns": [turn("child-turn", "completed", [row("child-row", "Real child output")])]]
        r.receive(b.event(4, "turn/completed", ["threadId": "child", "turn": ["id": "child-turn", "status": "completed"]]))
        check(parent.satellites[0].done && parent.satellites[0].finishedOrder == 0, "child terminal event updates completion order")
        let rev = parent.revision; r.receive(b.event(4, "item/completed", ["threadId": "child", "item": row("duplicate", "ignored")]))
        check(parent.revision == rev, "duplicate child event emits no projection change")
        r.shutdown()
    }
    private static func reconnect() async throws {
        let b = FixtureBackend(), clock = FixtureClock(), (r, t) = b.runtime(clock: clock)
        try await r.load(); b.high = 7; t.enqueue(.init(events: [b.event(7, "notice", [:])], finish: true)); t.enqueue(.init(finish: true)); t.enqueue(.init(finish: true))
        r.start(); await wait("initial stream EOF") { t.subscriptions.count == 1 && !r.isConnected }
        for _ in 0..<1000 { if await clock.delays.count == 1 { break }; await Task.yield() }
        check(await clock.delays == [1.5], "initial reconnect delay is 1.5s")
        await clock.advance(); await wait("cursor reconnect") { t.subscriptions.count == 2 && !r.isConnected }
        for _ in 0..<1000 { if await clock.delays.count == 2 { break }; await Task.yield() }
        check(t.subscriptions == [0, 7], "reconnect uses last complete exclusive cursor")
        check(await clock.delays == [1.5, 3], "successive empty connections back off exponentially")
        await clock.advance(); await wait("third empty reconnect") { t.subscriptions.count == 3 && !r.isConnected }
        for _ in 0..<1000 { if await clock.delays.count == 3 { break }; await Task.yield() }
        check(await clock.delays == [1.5, 3, 6], "third reconnect delay")
        b.instance = "new-epoch"; b.high = 0
        await clock.advance(); await wait("new backend epoch") { t.subscriptions.count == 4 }
        check(t.subscriptions.last == 0, "new Core epoch resets old cursor")
        r.shutdown(); check(!r.isStreaming, "shutdown cancels reader without backend shutdown")
        check(!b.requests.contains(where: { $0.path.contains("shutdown") }), "window lifecycle never shuts down Core")
        let policy = CoreReconnectPolicy(); check(policy.delay(attempt: 20) == 30 && policy.delay(attempt: -1) == 1.5, "backoff bounded at 30s")
        let (failed, _) = b.runtime(); b.connected = false
        do { try await failed.load(); check(false, "unhealthy initial load rejected") } catch { check(!failed.isConnected, "initial error exposes disconnected state") }
        b.connected = true; try await failed.load(); check(failed.isConnected, "explicit retry recovers connection"); failed.shutdown()
    }
    private static func persistence() async throws {
        let storage = CoreMemoryStorage(), (b, r, _, c) = try await ready(storage: storage)
        c.backendThreadID = "saved-thread"; c.draft = "saved draft"; c.running = true; c.activeTurnID = "never-persist-turn"; c.pinned = true
        c.attachments = [.init(id: "memory", name: "memory.txt", symbol: "doc", input: ["type": "text", "text": "inline fixture"], persistedInputPath: "/not-read/sidecar")]
        c.items = [.init(id: "not-persisted", turnID: "never-persist-turn", kind: .assistant, text: "not cached as truth")]
        c.approvals = [.init(id: "not-persisted", title: "pending", command: "", note: "", acceptLabel: "", toolItemID: "")]
        try r.presentation.setIdentity(c, symbol: "sun.max.fill", tint: "#FFAA33")
        r.presentation.setWindows([.init(id: "window", payload: ["frame": [1, 2, 3, 4], "members": [.string(c.id)]])]); try r.presentation.save()
        let store2 = ConversationStore(), state2 = LocalPresentationState(store: store2, scope: "fixture", storage: storage)
        state2.restore(); let saved = store2.conversation(c.id)!
        check(saved.identitySymbol == "sun.max.fill" && saved.identityTint == "#FFAA33" && saved.identityIndex == c.identityIndex, "persistent custom identity with index fallback")
        check(saved.draft == "saved draft" && saved.pinned && saved.attachments.first?.input == c.attachments.first?.input, "draft pin and inline attachment restored")
        check(saved.items.isEmpty && saved.approvals.isEmpty && !saved.running && saved.activeTurnID == nil, "local presentation never fabricates transcript, approval or running truth")
        check(state2.localID(forBackend: "saved-thread") == c.id && state2.windows.first?.id == "window", "stable UI identity and opaque window state")
        let separate = ConversationStore(), separateState = LocalPresentationState(store: separate, scope: "different-endpoint", storage: storage); separateState.restore()
        check(separate.conversations.isEmpty, "endpoint local state never leaks across Core hosts")
        try state2.setIdentity(saved, symbol: nil, tint: nil)
        check(saved.identitySymbol == nil && saved.identityTint == nil && saved.identityIndex == c.identityIndex, "nil identity returns to original index")
        r.shutdown()
        let outboundStorage = CoreMemoryStorage()
        let (out, live, _, chat) = try await ready(storage: outboundStorage); chat.backendThreadID = "uncertain"
        out.failures["turn/start"] = URLError(.timedOut); let id = UUID(); var receipt: CoreSubmissionReceipt?
        _ = live.submit(.init(id: id, identity: chat.id, text: "uncertain send", settings: chat.next), in: chat) { receipt = $0 }
        await wait("persist uncertain") { receipt != nil }; try live.presentation.save()
        // Rehydrate using the exact serialized bytes, not a runtime object or a backend data directory.
        let restoredStore = ConversationStore()
        let state = LocalPresentationState(store: restoredStore, scope: "fixture", storage: outboundStorage)
        let tr = FixtureTransport { try await out.respond($0) }
        let restored = LiveConversationRuntime(store: restoredStore, client: tr, presentation: state)
        out.failures = [:]; out.threads["uncertain"] = ["id": "uncertain", "turns": [turn("settled", "completed", [row("receipt", "uncertain send", type: "userMessage", clientID: id)])]]
        try await restored.load(); let recovered = restoredStore.conversation(chat.id)!
        check(!recovered.sendOutcomeUnknown && recovered.draft.isEmpty && restored.receipt(for: id)?.result == .accepted, "restart reconciles persisted outbound UUID using real history")
        check(out.count("turn/start") == 1, "restart reconciliation never replays prior mutation")
        live.shutdown(); restored.shutdown()
        let queueStorage = CoreMemoryStorage(), (qb, qr, _, qc) = try await ready(storage: queueStorage)
        qc.backendThreadID = "restored-queue"; qc.running = true; qc.activeTurnID = "predecessor"; qc.draft = "survives restart"
        let queued = CoreSubmission(identity: qc.id, action: .queue, text: qc.draft, settings: qc.next, waitingForTurnID: "predecessor")
        _ = qr.submit(queued, in: qc) { _ in }; qr.shutdown()
        let queueStore = ConversationStore(), queueState = LocalPresentationState(store: queueStore, scope: "fixture", storage: queueStorage)
        let queueRuntime = LiveConversationRuntime(store: queueStore, client: FixtureTransport { try await qb.respond($0) }, presentation: queueState)
        qb.threads["restored-queue"] = ["id": "restored-queue", "turns": [turn("predecessor", "inProgress", [])]]
        try await queueRuntime.load(); let restoredQueueChat = queueStore.conversation(qc.id)!
        check(restoredQueueChat.queued.count == 1 && restoredQueueChat.draft.isEmpty && qb.count("turn/start") == 0, "durable queue restores without replaying an active predecessor")
        var retainedReceipt: CoreSubmissionReceipt?
        _ = queueRuntime.submit(queued, in: restoredQueueChat) { retainedReceipt = $0 }
        check(restoredQueueChat.queued.count == 1 && retainedReceipt?.acceptance == .durableLocalQueue, "restored queue UUID retry doesn't duplicate local queue")
        qb.high = 1; qb.threads["restored-queue"] = ["id": "restored-queue", "turns": [turn("predecessor", "completed", [])]]
        let finished = qb.event(1, "turn/completed", ["threadId": "restored-queue", "turn": ["id": "predecessor", "status": "completed"]]); qb.log = [finished]
        queueRuntime.receive(finished)
        await wait("restored queue delivery") { qb.count("turn/start") == 1 && restoredQueueChat.queued.isEmpty }
        check(qb.count("thread/resume") == 1 && qb.count("turn/start") == 1, "restored queue resumes real thread and dispatches once after completion")
        queueRuntime.shutdown()
        let throttleStore = ConversationStore(), throttleMemory = CoreMemoryStorage(), throttleClock = FixtureClock()
        let throttleState = LocalPresentationState(store: throttleStore, scope: "throttle", storage: throttleMemory, clock: throttleClock)
        let typing = Conversation(id: "typing", title: "Typing"); throttleStore.add(typing); throttleState.observe()
        typing.draft = "first draft"; throttleStore.changed(typing)
        for _ in 0..<1000 { if await throttleClock.delays.count == 1 { break }; await Task.yield() }
        for _ in 0..<20 { typing.draft += "."; throttleStore.changed(typing) }
        check(await throttleClock.delays == [0.2], "continuous notifications coalesce instead of starving local autosave")
        await throttleClock.advance()
        await wait("coalesced draft saved") { !throttleMemory.values.isEmpty }
        let firstBytes = throttleMemory.values
        throttleMemory.writeError = CoreWire.failure("must not write transcript-only change")
        typing.items.append(.init(id: "stream", turnID: "turn", kind: .assistant, text: "streaming"))
        try throttleState.save()
        check(throttleMemory.values == firstBytes, "transcript-only changes skip serialization and storage writes")
        let recoveredTyping = ConversationStore(); LocalPresentationState(store: recoveredTyping, scope: "throttle", storage: throttleMemory).restore()
        check(recoveredTyping.conversation("typing")?.draft == typing.draft, "coalesced save contains latest editor contents")
        let corrupt = CoreMemoryStorage(); corrupt.values["organic.shell.presentation.v2." + Data("corrupt".utf8).base64EncodedString()] = Data("invalid".utf8)
        let broken = LocalPresentationState(store: ConversationStore(), scope: "corrupt", storage: corrupt)
        check(broken.lastError != nil, "corrupt local presentation reports recoverable error")
        check(b.count("thread/start") == 0, "saving identity never starts backend thread")
    }
    private static func attachmentSubmissions() async throws {
        let (backend, runtime, _, chat) = try await ready()
        defer { runtime.shutdown() }
        let payload: JSONValue = ["type": "text", "text": "restored attachment input"]
        let reference = try runtime.presentation.attachmentInputs.persist(payload, scope: "fixture")
        let attachment = Attachment(id: "restored-file", name: "restored.txt", symbol: "doc", persistedInputPath: reference)
        var receipt: CoreSubmissionReceipt?
        _ = runtime.submit(.init(identity: chat.id, text: "with sidecar", attachments: [attachment], settings: chat.next), in: chat) { receipt = $0 }
        await wait("sidecar submission accepted") { receipt != nil }
        check(receipt?.result == .accepted, "S3 reference-only input can be sent using the scoped resolver")
        let parts = backend.requests.last(where: { $0.rpc == "turn/start" })?.params["input"]?.arrayValue ?? []
        check(parts.contains(payload) && backend.count("/attachments") == 0, "S3 hydrated input uses the original wire part without uploading again")
        let (badBackend, badRuntime, _, badChat) = try await ready()
        defer { badRuntime.shutdown() }
        var failed: CoreSubmissionReceipt?
        let missing = Attachment(id: "missing", name: "missing.txt", symbol: "doc", persistedInputPath: "/not-read/foreign")
        badChat.draft = "keep this draft"; badChat.attachments = [missing]
        _ = badRuntime.submit(.init(identity: badChat.id, text: badChat.draft, attachments: [missing], settings: badChat.next), in: badChat) { failed = $0 }
        await wait("missing sidecar rejected") { failed != nil }
        if case .failed = failed?.result { check(true, "S3 unreadable payload fails explicitly") } else { check(false, "S3 unreadable payload fails explicitly") }
        check(badBackend.count("thread/start") == 0 && badBackend.count("turn/start") == 0 && badChat.draft == "keep this draft" && badChat.attachments.count == 1, "S3 missing input cannot create a thread, submit a turn or discard the draft")
    }
    private static func mocks() async throws {
        let oldStore = ConversationStore(), newStore = ConversationStore()
        let old = MockReplay(store: oldStore), adapter = MockConversationRuntime(store: newStore, animatePlayback: false)
        let runtime: any ConversationRuntime = adapter
        old.start(live: false); runtime.start(); old.advance(ticks: 80); adapter.replay.advance(ticks: 80)
        check(old.emitted == adapter.replay.emitted && oldStore.conversations.count == newStore.conversations.count, "mock adapter preserves existing emitted events")
        for c in oldStore.conversations {
            let other = newStore.conversation(c.id)!
            check(c.items.map(\.text) == other.items.map(\.text) && c.running == other.running && c.approvals == other.approvals, "mock fixture unchanged for " + c.id)
        }
        let unsent = runtime.createUnsentConversation(title: "Two stage", projectID: nil, deviceID: "mac")
        check(newStore.conversation(unsent.id) == nil && unsent.items.isEmpty, "mock shares two-phase unsent contract")
        newStore.add(unsent); var receipt: CoreSubmissionReceipt?
        let id = UUID(); _ = runtime.submit(.init(id: id, identity: unsent.id, text: "same protocol", settings: unsent.next), in: unsent) { receipt = $0 }
        check(receipt?.id == id && receipt?.result == .accepted && unsent.running, "mock uses same immutable submission/receipt interface")
        runtime.shutdown(); old.stopPlayback()
    }
    private static func componentStoreRemoval() async throws {
        let a=Conversation(id:"remove-a",title:"Archived"),b=Conversation(id:"remove-b",title:"Active"),c=Conversation(id:"keep",title:"Keep")
        a.archived=true;a.backendThreadID="backend-a";b.draft="Retained until retired"
        let store=ConversationStore(conversations:[a,b,c])
        var changes:[String]=[],callbacks:[String]=[],atomic=true
        store.onChange={callbacks.append($0.id)}
        let token=store.observe{changed in changes.append(changed.id);atomic = atomic && store.conversation(a.id) == nil && store.conversation(b.id) == nil && changed.archived}
        let removed=try store.remove(ids:[a.id,b.id])
        check(removed.count == 2 && removed[0] === a && removed[1] === b,"remove returns the original objects in library order")
        check(store.conversations.count == 1 && store.conversation(c.id) === c,"remove changes the same library, leaving unrelated objects intact")
        check(atomic && changes == [a.id,b.id] && callbacks == changes,"remove publishes only after the whole batch is absent and retired")
        check(a.archived && b.archived && a.revision == 1 && b.revision == 1,"removed retained models are archived and publish one revision each")
        check(b.draft == "Retained until retired" && c.revision == 0,"remove does not edit unrelated state or retained drafts")
        let count=changes.count;a.archived=false;store.changed(a)
        check(changes.count == count && a.revision == 1,"late callbacks on removed models cannot publish or revive library state")
        let replacement=Conversation(id:a.id,title:"Replacement");store.add(replacement);store.changed(a)
        check(store.conversation(a.id) === replacement && changes.count == count,"stale object cannot publish through an ID replacement")
        do{_ = try store.remove(ids:[c.id,"missing"]);check(false,"unknown deletion must fail")}catch{check(store.conversation(c.id) === c && changes.count == count,"invalid batch is rejected before any partial mutation")}
        do{_ = try store.remove(ids:["backend-a"]);check(false,"backend alias is not canonical")}catch{check(store.conversation(replacement.id) === replacement,"removal accepts canonical library IDs only")}
        check(try store.remove(ids:[]).isEmpty,"empty removal is a no-op")
        store.removeObserver(token)
        let f=CoreControllerFixture(),terminal=CoreTerminalController();terminal.configure(client:f.transport,store:store)
        terminal.restoreDescriptors([["id":"recorded-one","conversationId":.string(c.id),"cwd":"/fixture","running":true],["id":"recorded-two","conversationId":.string(c.id),"cwd":"/fixture","running":true]],store:store)
        var selections=0;let observation=terminal.observe{selections+=1};let sessions=terminal.sessions(for:c.id)
        terminal.selected[c.id]=sessions[1].id
        check(selections == 1 && terminal.active(for:c.id) === sessions[1],"terminal selection notifies all retained panes")
        terminal.selected[c.id]=sessions[1].id
        check(selections == 1,"unchanged terminal selection emits no redundant observer update")
        terminal.removeObserver(observation)
    }
    private static func settingsComponentContracts() async throws {
        let f=CoreControllerFixture(),c=CoreSettingsController(),scope=SettingsScope(endpoint:"fixture",device:"mac")
        let active=Conversation(id:"local-identity",title:"Existing chat"); active.backendThreadID="backend-thread"
        let archived=Conversation(id:"archived-local",title:"Archived"); archived.backendThreadID="archived-backend"; archived.archived=true
        let draft=Conversation(id:"unsent-local",title:"Draft")
        let emptyID=Conversation(id:"empty-local",title:"No backend identity"); emptyID.backendThreadID=""
        let store=ConversationStore(conversations:[active,archived,draft,emptyID])
        let runtime=MockConversationRuntime(store:store,animatePlayback:false); defer { runtime.shutdown() }
        c.configure(client:f.transport,runtime:runtime,endpoint:"fixture")
        for pane in ["appshots","scheduler"] {
            let result=try await c.read(.init(pane:pane,scope:scope))
            let options=result.snapshots["threads"]?.arrayValue ?? []
            check(options.count == 1,"C08 \(pane) omits archived, draft and empty backend identities")
            check(options.first?["backendThreadID"] == "backend-thread" && options.first?["id"] == "local-identity","C08 \(pane) preserves local and backend IDs separately")
            check(options.first?["title"] == "Existing chat" && options.first?["archived"] == false,"C08 \(pane) exposes product thread-option fields")
            check(result.snapshots["threads"] == c["threads"],"C08 \(pane) return value and retained snapshot agree")
        }
        active.title="Renamed"; draft.backendThreadID="promoted-backend"
        _ = try await c.read(.init(pane:"appshots",scope:scope))
        check(c["threads"].arrayValue?.map { $0["title"]?.stringValue ?? "" } == ["Renamed","Draft"],"C08 Refresh sees rename and first-send promotion in store order")
        active.archived=true; draft.archived=true
        _ = try await c.read(.init(pane:"scheduler",scope:scope))
        check(c["threads"] == [],"C08 Refresh clears options when all backend threads are archived")
        _ = try await c.perform(.init(kind:.unarchive,payload:["id":"backend-thread"],scope:scope))
        check(c["threads"].arrayValue?.first?["backendThreadID"] == "backend-thread","C08 acknowledged unarchive returns refreshed options")
        f.before={ request in
            guard request.key == "thread/list" else { return nil }; return ["data":[["id":"backend-thread"]]]
        }
        _ = try await c.perform(.init(kind:.archiveAll,scope:scope))
        check(c["threads"] == [],"C08 acknowledged archive-all removes options")
        c.configure(client:f.transport,endpoint:"fixture")
        let noStore=try await c.read(.init(pane:"appshots",scope:scope))
        check(noStore.snapshots["threads"] == [],"C08 no runtime returns explicit empty array, never stale options")

        // The wire envelope remains inspectable; Settings' existing records helper reads the data alias.
        f.before={ request in
            guard request.key == "/browser/tabs" else { return nil }; return ["tabs":.array(f.tabs),"generation":7]
        }
        let browser=try await c.read(.init(pane:"browser",scope:scope))
        let tabs=browser.snapshots["tabs"] ?? .null
        check(tabs["data"] == .array(f.tabs),"C09 Browser wrapper exposes a Settings-readable data array")
        check(tabs["tabs"] == .array(f.tabs) && tabs["generation"] == 7,"C09 original tabs and metadata survive normalization")
        check(tabs["data"]?.arrayValue?.first?["tabId"] == "tab&1","C09 tab IDs are not renamed or fabricated")
        f.tabs=[]
        _ = try await c.read(.init(pane:"browser",scope:scope))
        check(c["tabs"]["data"] == [],"C09 actual empty tabs clears a previously loaded list")
        for legacy:JSONValue in [["data":[["tabId":"legacy-data"]]],[["tabId":"legacy-array"]]] {
            f.before={ request in guard request.key == "/browser/tabs" else { return nil }; return legacy }
            _ = try await c.read(.init(pane:"browser",scope:scope))
            check(c["tabs"] == legacy,"C09 existing data/array response remains readable and unchanged")
        }
        let acknowledged=c["tabs"]
        f.before={ request in guard request.key == "/browser/tabs" else { return nil }; return ["tabs":"invalid"] }
        let invalid=try await c.read(.init(pane:"browser",scope:scope))
        check(invalid.snapshots["tabs"] == nil && invalid.notice?.contains("tabs list") == true,"C09 malformed wrapper is an error, not an empty success")
        check(c["tabs"] == acknowledged,"C09 malformed wrapper retains last acknowledged tabs")

        let skills:JSONValue=["data":[["cwd":"/fixture","skills":[["name":"Recorded skill","path":"/fixture/SKILL.md"]]]]]
        f.before={ request in guard request.key == "/app-server/skills/list" else { return nil }; return skills }
        c.configure(client:f.transport,endpoint:"fixture")
        for pass in 0..<2 {
            let start=f.requests.count
            let result=try await c.read(.init(pane:"plugins/skills",scope:scope))
            check(result.snapshots["skills"] == skills,"C10 direct Skills/Refresh \(pass) loads without visiting parent")
            let calls=Array(f.requests.dropFirst(start))
            check(calls.filter { $0.key == "/app-server/skills/list" }.count == 1 && calls.last?.body?["forceReload"] == true,"C10 Skills \(pass) requests a forced fresh discovery")
            check(!calls.contains { ["mcpServerStatus/list","/app-server/plugins/list"].contains($0.key) },"C10 Skills \(pass) does not load unrelated catalogs")
        }
        c.configure(client:f.transport,endpoint:"fixture")
        for pass in 0..<2 {
            let start=f.requests.count
            let result=try await c.read(.init(pane:"plugins/mcp",scope:scope))
            check(result.snapshots["mcp"]?["data"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["first","second"],"C10 direct MCP/Refresh \(pass) reads every cursor page")
            let calls=Array(f.requests.dropFirst(start))
            check(calls.filter { $0.key == "mcpServerStatus/list" }.map { $0.params["cursor"] } == [nil,"mcp-2"],"C10 MCP \(pass) starts fresh then follows nextCursor")
            check(result.snapshots["config"] != nil && calls.contains { $0.key == "config/read" && $0.params["includeLayers"] == true },"C10 MCP \(pass) also loads writable config layers")
        }
        f.before=nil
        f.failures["/app-server/skills/list"]=CoreWire.failure("fixture discovery denied")
        let failure=try await c.read(.init(pane:"plugins/skills",scope:scope))
        check(failure.notice?.contains("fixture discovery denied") == true && failure.snapshots["skills"] == nil,"C10 subroute loading failures remain visible")
    }
    private static func m8Settings() async throws {
        let f=CoreControllerFixture(),c=CoreSettingsController(),scope=SettingsScope(endpoint:"fixture",device:"mac")
        c.configure(client:f.transport,endpoint:"fixture")
        let provider:any SettingsDataSource=c
        let result=try await provider.read(.init(pane:"configuration",scope:scope))
        check(provider.mode == .live && result.snapshots["models"]?["data"]?.arrayValue?.count == 2,"SettingsDataSource live adapter reads all model pages")
        check(result.capabilities["voice"] == nil && result.capabilities["scheduler"]?.available == false,"unknown capability omitted instead of fabricated availability")
        check(!provider.localFilesAvailable && !provider.supportedOperations.contains(.demo) && !provider.supportedOperations.contains(.openLocal),"live rejects demo and unverified local effects")
        _ = try await c.read(.init(pane:"plugins",scope:scope))
        check(c["mcp"]["data"]?.arrayValue?.count == 2,"MCP status consumes all cursor pages")
        let edited:JSONValue=["edits":[["keyPath":"model","value":"model2","mergeStrategy":"replace"]],"filePath":"/fixture/config.toml","expectedVersion":"v1","reloadUserConfig":true]
        let write=try await c.perform(.init(kind:.configWrite,payload:edited,scope:scope))
        check(write.snapshots["config"]?["layers"]?.arrayValue?.first?["version"] == "v2","config only publishes acknowledged readback")
        check(f.requests.first(where: { $0.key == "config/batchWrite" })?.params == edited,"preserve expectedVersion and exact edits")
        do { _ = try await c.perform(.init(kind:.configWrite,payload:edited,scope:scope)); check(false,"stale config version rejected") } catch { check(c["config"]["layers"]?.arrayValue?.first?["version"] == "v2","failed write retains acknowledged snapshot") }
        let before=f.requests.count
        do { _ = try await c.read(.init(pane:"account",scope:.init(endpoint:"other",device:"mac"))); check(false,"stale endpoint rejected") } catch { check(f.requests.count == before,"stale endpoint reaches no service") }
        do { _ = try await c.read(.init(pane:"account",scope:.init(endpoint:"fixture",device:"pc"))); check(false,"wrong device rejected") } catch { check(f.requests.count == before,"selected foreign device never silently targets Core host") }
        let login=try await c.perform(.init(kind:.login,scope:scope)); check(login.browserURL?.hasPrefix("https://") == true && c.pendingLoginID == "login-1","sign in returns browser URL without opening an application")
        _ = try await c.perform(.init(kind:.cancelLogin,scope:scope)); check(c.pendingLoginID == nil,"cancel sign-in uses matching pending ID")
        f.failures["/capture/hotkey"]=CoreWire.failure("shortcut unavailable")
        do { _ = try await c.perform(.init(kind:.hotkeyWrite,payload:["enabled":true],scope:scope)); check(false,"hotkey failure surfaced") } catch { check(c["hotkey"] == .null,"no optimistic hotkey enabled state") }
        f.failures=[:]
        var saved:URL?; c.onSaveEndpoint={ saved=$0 }
        _ = try await c.perform(.init(kind:.endpointSave,payload:["url":"https://core.example.invalid"],scope:scope)); check(saved?.host == "core.example.invalid","endpoint preference is a host callback")
        for address in ["file:///tmp/core","https://user:pass@core.invalid","https://core.invalid/path"] {
            do { _ = try await c.perform(.init(kind:.endpointSave,payload:["url":.string(address)],scope:scope)); check(false,"invalid endpoint preference blocked") } catch { check(true,"invalid endpoint preference blocked") }
        }
        var notices=0; c.onNotification={ _ in notices+=1 }; c.jobNotificationPolicies["job"]="failed"
        c.receive(.init(id:1,time:nil,method:"core/notification",params:["jobId":"job","status":"completed"]))
        c.receive(.init(id:2,time:nil,method:"core/notification",params:["jobId":"job","status":"submissionUnknown"]))
        check(notices == 1,"notification failure policy includes unknown submissions")
        f.repeatModelCursor=true
        let loop=try await c.read(.init(pane:"configuration",scope:scope)); check(loop.notice?.contains("cursor") == true,"repeated catalog cursor is visible and bounded")
        var permissionCalls=0; c.onPermissionRequest={ permissionCalls+=1; return false }
        _ = try await c.perform(.init(kind:.notificationPermission,scope:scope)); check(permissionCalls == 1 && c.notificationPermission == "Not allowed","permission request is explicit and reflects denial")
        var invalidated=Set<String>(); c.onInvalidation={ invalidated.formUnion($0) }; let requestCount=f.requests.count
        c.receive(.init(id:3,time:nil,method:"account/updated",params:[:]))
        check(invalidated == ["account","profile","usage"] && f.requests.count == requestCount,"pull-only Settings source invalidates host panes without duplicate background reads")
        let writes=f.count("config/batchWrite")
        f.before={ request in
            if request.key == "config/read" { f.before=nil; c.configure(client:f.transport,endpoint:"new-endpoint") }
            return nil
        }
        do { _ = try await c.perform(.init(kind:.configWrite,payload:["edits":[["keyPath":"model","value":"next"]]],scope:scope)); check(false,"endpoint switch must invalidate pending config read") }
        catch { check(f.count("config/batchWrite") == writes && c.snapshots.isEmpty,"endpoint switch during prerequisite read prevents a later write") }
        let archivedStore=ConversationStore(),chat=Conversation(id:"archive-chat",title:"Archive chat"); chat.backendThreadID="t1"; archivedStore.add(chat)
        let archiveRuntime=MockConversationRuntime(store:archivedStore,animatePlayback:false),archiveSource=CoreSettingsController()
        archiveSource.configure(client:f.transport,runtime:archiveRuntime,endpoint:"fixture")
        _ = try await archiveSource.perform(.init(kind:.archiveAll,scope:scope))
        check(chat.archived,"archive-all ack updates the real store without a second runtime RPC")
        f.failures["thread/unarchive"]=CoreWire.failure("rejected")
        do { _ = try await archiveSource.perform(.init(kind:.unarchive,payload:["id":"t1"],scope:scope)); check(false,"rejected unarchive must fail") }
        catch { check(chat.archived,"failed unarchive retains acknowledged store state") }
        f.failures=[:]; _ = try await archiveSource.perform(.init(kind:.unarchive,payload:["id":"t1"],scope:scope))
        check(!chat.archived,"unarchive ack updates the destination store")
        archiveRuntime.shutdown()
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("sol-core-skill-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let source=temporary.appendingPathComponent("fixture-skill",isDirectory:true),config=temporary.appendingPathComponent("fake-core/config.toml")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let marker=Data("# Recorded skill fixture\n".utf8); try marker.write(to:source.appendingPathComponent("SKILL.md"))
        let installed=config.deletingLastPathComponent().appendingPathComponent("skills/fixture-skill/SKILL.md")
        let discovered:JSONValue=["data":[["skills":[["path":.string(installed.path)]]]]]
        _ = try await CoreSkillFolderInstaller.install(source:source,configPath:config.path) { discovered }
        check(try Data(contentsOf:installed) == marker,"local skill installer copies into only the explicit temporary config root")
        do { _ = try await CoreSkillFolderInstaller.install(source:source,configPath:config.path) { discovered }; check(false,"skill overwrite must fail") }
        catch { check(try Data(contentsOf:installed) == marker,"local skill install never replaces an existing directory") }
        let invalid=temporary.appendingPathComponent("missing-marker",isDirectory:true)
        try FileManager.default.createDirectory(at:invalid,withIntermediateDirectories:true)
        do { _ = try await CoreSkillFolderInstaller.install(source:invalid,configPath:config.path) { discovered }; check(false,"missing skill marker must fail") }
        catch { check(!FileManager.default.fileExists(atPath:config.deletingLastPathComponent().appendingPathComponent("skills/missing-marker").path),"invalid skill folder causes no destination copy") }
        let otherRoot=temporary.appendingPathComponent("undiscovered/config.toml")
        do { _ = try await CoreSkillFolderInstaller.install(source:source,configPath:otherRoot.path) { ["data":[]] }; check(false,"unreported skill discovery must fail") }
        catch { check(error.localizedDescription.contains("not discovered") && FileManager.default.fileExists(atPath:otherRoot.deletingLastPathComponent().appendingPathComponent("skills/fixture-skill/SKILL.md").path),"copied but undiscovered skill reports the real partial result") }
    }
    private static func m8Artifacts() async throws {
        let f=CoreControllerFixture(),store=ConversationStore()
        let first=Conversation(id:"dest1",title:"First"),second=Conversation(id:"dest2",title:"Second"); first.backendThreadID="t1"; second.backendThreadID="t2"; store.add(first); store.add(second)
        let runtime=MockConversationRuntime(store:store,animatePlayback:false),c=CoreArtifactsController(storage:CoreMemoryStorage())
        c.configure(client:f.transport,runtime:runtime,endpoint:"fixture"); c.conversationID=first.id
        c.refreshArtifacts(); await wait("M8 artifacts list") { !c.busy && c.artifacts.count == 2 }
        c.select("text"); await wait("M8 artifact bytes") { c.selectedData != nil }
        check(String(data:c.selectedData!,encoding:.utf8)?.contains("Recorded artifact") == true,"preview uses downloaded content, never backend path")
        c.comment="Shared comment"; c.quote="Notes"; c.addAnnotation(); await wait("M8 annotation write") { !c.busy && c.annotations.count == 1 }
        let note=c.annotations[0]
        c.receive(.init(id:1,time:nil,method:"preview/annotationCreated",params:note)); check(c.annotations.count == 1,"HTTP/SSE annotation creation deduplicates ID")
        let envelope=CoreArtifactsController.envelope(artifact:c.selected!,annotations:c.annotations,request:"Please inspect")
        check(CoreArtifactsController.envelope(artifact:c.selected!,annotations:c.annotations,request:envelope) == envelope,"shared annotation envelope composes without duplicate notes")
        check(envelope.contains("text-sha") && envelope.contains("originThreadId"),"annotation envelope retains source hash and thread")
        var deliveries:[CoreArtifactDelivery]=[]
        c.onDeliver={ value,finish in deliveries.append(value); finish(.accepted) }
        c.attachSelected(send:true); c.conversationID=second.id
        await wait("M8 artifact delivery") { !c.busy && !deliveries.isEmpty }
        check(deliveries[0].destinationID == first.id && deliveries[0].send && deliveries[0].attachments.count == 2,"artifact delivery captures destination and returns prepared inputs")
        check(first.attachments.isEmpty && first.draft.isEmpty && runtime.replay.emitted == 0,"controller never mutates composer or sends by Bool")
        check(deliveries[0].composeDraft(current:"New typing").hasSuffix("New typing"),"host can merge annotations with the current retained draft")
        c.deleteAnnotation(note); await wait("M8 annotation delete") { !c.busy && c.annotations.isEmpty }
        let raced:JSONValue=["id":"raced-note","artifactId":"text","text":"arrived while loading"]
        f.before={ request in
            if request.method == "GET",URLComponents(string:request.path)?.path == "/preview/annotations" {
                f.before=nil; f.annotations.append(raced)
                c.receive(.init(id:999,time:nil,method:"preview/annotationCreated",params:raced))
                return []
            }
            return nil
        }
        c.select("text"); await wait("M8 annotation load race") { c.selectedData != nil }
        check(c.annotations.contains(raced),"SSE annotation during HTTP load survives an older annotation snapshot")
        var changed=c.selected!.raw.objectValue!; changed["sha256"]="new-content-sha"
        f.content["text"]=Data("Changed artifact bytes".utf8)
        c.receive(.init(id:1000,time:nil,method:"preview/artifactRegistered",params:.object(changed)))
        await wait("M8 selected artifact revision") { c.selectedData == Data("Changed artifact bytes".utf8) }
        check(c.selected?.sha == "new-content-sha","selected artifact SHA changes reload preview bytes")
        c.receiveGeneratedImage(["id":"generated","fileId":"opaque-file-id","status":"completed"],threadID:"t1")
        let placeholder=c.artifacts.first { $0.generatedItemID == "generated" }!
        check(placeholder.previewUnavailable && placeholder.path.isEmpty,"bare generated file ID remains an honest unavailable placeholder")
        let uploads=f.count("/attachments")
        c.receiveGeneratedImage(["id":"generated","fileId":"opaque-file-id","result":.string(f.png.base64EncodedString())],threadID:"t1")
        await wait("M8 generated inline image") { c.artifacts.contains { $0.generatedItemID == "generated" && !$0.previewUnavailable } }
        check(f.count("/attachments") == uploads+1,"inline generated bytes register once")
        c.receiveGeneratedImage(["id":"generated","result":.string(f.png.base64EncodedString())],threadID:"t1")
        check(f.count("/attachments") == uploads+1,"replayed generated event never uploads twice")
        check(CoreArtifact(raw:["id":"x","input":["large":"payload"],"dataBase64":"large"]).raw["input"] == nil,"artifact metadata doesn't retain heavy input bytes")
        c.conversationID=first.id; let requestID=UUID().uuidString; try c.trackCapture(requestID:requestID,target:first)
        let response:JSONValue=["id":"capture-fixture","clientRequestId":.string(requestID),"threadId":"t1","success":true,"contentItems":[["type":"inputImage","imageUrl":.string("data:image/png;base64,"+f.png.base64EncodedString())]],"source":["app":"Fixture"]]
        c.conversationID=second.id; try await c.reconcileCapture(response,requestID:requestID); try await c.reconcileCapture(response,requestID:requestID)
        check(deliveries.count == 2 && deliveries.last?.destinationID == first.id && !c.hasPendingCapture,"capture recovery uses original destination and deduplicates HTTP/SSE")
        let mismatch=UUID().uuidString; try c.trackCapture(requestID:mismatch,target:first)
        do { try await c.reconcileCapture(["clientRequestId":.string(mismatch),"threadId":"t2","success":true],requestID:mismatch); check(false,"wrong capture destination rejected") } catch { check(c.hasPendingCapture && deliveries.count == 2,"mismatched capture stays recoverable without attaching") }
        c.receive(CoreEvent(id:1,time:nil,method:"core/approvalRequested",params:["threadId":"t1"]))
        c.receive(CoreEvent(id:2,time:nil,method:"core/captureFailed",params:["clientRequestId":.string(mismatch),"threadId":"t1","message":"timed out"]))
        check(!c.hasPendingCapture && c.error == "timed out" && c.captureSummary == "Capture did not complete.","a failed capture clears its request and no longer says it waits for permission")
        c.refreshTabs(); await wait("M8 browser tabs") { !c.busy }; c.selectBrowserTab("tab&1"); c.inspectBrowser(); await wait("M8 DOM") { !c.busy && !c.browserSnapshot.isEmpty }
        check(c.browserSnapshot.hasPrefix("Recorded DOM"),"browser uses explicit Core snapshot")
        c.screenshotBrowser(attach:true); await wait("M8 browser screenshot") { !c.busy && c.browserImage != nil }
        check(deliveries.last?.destinationID == second.id && deliveries.last?.attachments.count == 2,"browser screenshot includes source metadata in delivery")
        let memory=CoreMemoryStorage(); memory.writeError=CoreWire.failure("disk full")
        let failed=CoreArtifactsController(storage:memory); failed.configure(client:f.transport,runtime:runtime,endpoint:"fixture")
        do { try failed.trackCapture(requestID:UUID().uuidString,target:first); check(false,"unsaved capture intent blocked") } catch { check(!failed.hasPendingCapture,"capture cannot start before its request ID is persisted") }
        runtime.shutdown()
    }
    private static func m8Terminal() async throws {
        let f=CoreControllerFixture(),store=ConversationStore(),c=Conversation(id:"terminal-owner",title:"Owner"); c.backendThreadID="terminal-thread"; c.cwd="/fixture"; store.add(c)
        f.terminalDescriptors=[["id":"restored&pty","threadId":"terminal-thread","cwd":"/fixture","running":true],["id":"foreign","threadId":"other","cwd":"/fixture","running":true],["id":"legacy","cwd":"/fixture","running":true]]
        f.chunks["restored&pty"]=[["sequence":1,"data":"restored output\r\n"]]; f.terminalRunning["restored&pty"]=true
        let clock=FixtureClock(),terminal=CoreTerminalController(clock:clock); terminal.configure(client:f.transport,store:store)
        check(await terminal.restore() && terminal.sessions.count == 1,"restore matches IDs, never same-directory foreign shells")
        let session=terminal.active(for:c.id)!
        check(session.output.contains("restored output") && f.count("/terminal/open") == 0,"restore fetches cursor output without opening replacement")
        let event=CoreEvent(id:1,time:nil,method:"core/terminalOutput",params:["sessionId":"restored&pty","sequence":2,"data":"next"])
        terminal.receive(event); terminal.receive(event)
        check(session.sequence == 2 && session.output.hasSuffix("next"),"PTY sequence deduplicates event replay")
        f.chunks["restored&pty"]?.append(contentsOf:[["sequence":2,"data":"next"],["sequence":3,"data":"missed"],["sequence":4,"data":"later"]])
        terminal.receive(.init(id:2,time:nil,method:"core/terminalOutput",params:["sessionId":"restored&pty","sequence":4,"data":"later"]))
        await wait("M8 terminal gap catchup") { session.sequence == 4 }
        check(session.output.hasSuffix("nextmissedlater"),"sequence gap catches up before buffered event")
        session.send(String(repeating:"🌅",count:20000))
        await wait("M8 input chunks") { f.count("/terminal/write") == 2 }
        check(f.requests.filter { $0.key == "/terminal/write" }.allSatisfy { ($0.body?["data"]?.stringValue?.utf8.count ?? 0)<=65536 },"PTY UTF8 input chunks respect64KiB limit")
        let boundary=String(repeating:"a",count:65535)+"e\u{301}🌅"
        let start=f.count("/terminal/write"); session.send(boundary)
        await wait("PTY combining scalar boundary") { f.count("/terminal/write") == start+2 }
        let reconstructed=f.requests.filter { $0.key == "/terminal/write" }.dropFirst(start).compactMap { $0.body?["data"]?.stringValue }.joined()
        check(Data(reconstructed.utf8) == Data(boundary.utf8),"PTY byte queue preserves combining scalars across chunk boundaries")
        f.failures["/terminal/write"]=URLError(.timedOut); session.send("printf fixture\r")
        await wait("M8 input ambiguity") { session.error != nil }; let writes=f.count("/terminal/write")
        for _ in 0..<100 { await Task.yield() }; check(f.count("/terminal/write") == writes && session.error?.contains("not replayed") == true,"ambiguous terminal input never repeats commands")
        session.resize(columns:90,rows:30); session.resize(columns:100,rows:40)
        for _ in 0..<1000 { if await clock.delays.contains(0.05) { break }; await Task.yield() }; await clock.advance()
        await wait("M8 resize") { f.count("/terminal/resize") == 1 }
        check(f.requests.last(where: { $0.key == "/terminal/resize" })?.body?["cols"] == 100,"resize coalesces to latest geometry")
        f.truncated=true; await session.catchUp()
        check(session.output.contains("Older terminal output is no longer available"),"truncated PTY history is disclosed instead of fabricated")
        f.failures=[:]; await session.close(); check(!session.running && f.count("/terminal/close") == 1,"explicit close ends only the selected owned PTY")
        let isolated=CoreTerminalSession(conversationID:c.id,cwd:"/fixture",client:f.transport)
        f.failures["/terminal/open"]=URLError(.timedOut); await isolated.open(); await isolated.open()
        check(isolated.openOutcomeUnknown && f.count("/terminal/open") == 1,"ambiguous PTY creation cannot automatically open a replacement")
    }

}
#endif
