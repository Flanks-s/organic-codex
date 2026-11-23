#if M1139_CHECK
import Foundation

private final class UsageTransport: CoreTransport, @unchecked Sendable {
    let handler: @Sendable (String) async throws -> JSONValue
    init(_ handler: @escaping @Sendable (String) async throws -> JSONValue) { self.handler = handler }
    func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
        try await handler(body?["method"]?.stringValue ?? path)
    }
    func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> { .init { $0.finish() } }
}
@MainActor private final class UsageBackend {
    var name = "Account A", failAccount = false, failLimits = false, loggedOut = false
    var holdMethod: String?, held: CheckedContinuation<JSONValue, Error>?, heldValue: JSONValue?
    var calls: [String] = []
    var limits: JSONValue = ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 21, "windowDurationMins": 120]]]
    func request(_ method: String) async throws -> JSONValue {
        calls.append(method)
        let value: JSONValue
        switch method {
        case "account/read":
            if failAccount { throw CoreWire.failure("fixture account failure") }
            value = loggedOut ? ["account": nil] : ["account": ["email": .string(name), "planType": "plus"]]
        case "account/rateLimits/read":
            if failLimits { throw CoreWire.failure("fixture limits failure") }; value = limits
        default: throw CoreWire.failure("Unexpected fixture RPC: " + method)
        }
        if method == holdMethod {
            heldValue = value
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        return value
    }
    func release() { let c = held; held = nil; holdMethod = nil; c?.resume(returning: heldValue ?? [:]) }
    func failHeld() { let c = held; held = nil; holdMethod = nil; c?.resume(throwing: CoreWire.failure("fixture old read failure")) }
}

@MainActor enum AccountUsageVerification {
    static func run(_ check: (Bool, String) -> Void) async {
        let store = ConversationStore(), backend = UsageBackend()
        let transport = UsageTransport { method in try await backend.request(method) }
        let presentation = LocalPresentationState(store: store, scope: "m1139-private", storage: CoreMemoryStorage())
        let live = LiveConversationRuntime(store: store, client: transport, presentation: presentation)
        var updates: [AccountUsage] = [], threadUpdates = 0
        let observer = store.observeAccountUsage { updates.append($0) }
        let threadObserver = store.observe { _ in threadUpdates += 1 }
        live.receive(.init(id: 1, time: 1, method: "account/rateLimits/updated", params: ["rateLimits": ["primary": ["usedPercent": 0, "windowDurationMins": 120]]]))
        check(updates.count == 2 && threadUpdates == 0 && store.conversations.isEmpty, "quota: independent empty-store push notifies without thread delta")
        check(updates.last?.primary.used == 0 && updates.last?.primary.reported == true && updates.last?.secondary.used == nil, "quota: real zero differs from missing secondary")
        check(store.accountUsage.primary.title(fallback: "Primary") == "2 hours" && store.accountUsage.primary.resetsAt == nil, "quota: returned minutes name the window; no fabricated reset")
        live.receive(.init(id: 2, time: 2, method: "account/rateLimits/updated", params: ["rateLimits": ["secondary": ["usedPercent": 73, "windowDurationMins": 90]]]))
        check(store.accountUsage.primary.used == nil && store.accountUsage.secondary.used == 0.73 && store.accountUsage.percentage == "73%", "quota: missing primary; tightest is reported secondary used")
        check(abs((store.accountUsage.secondary.remaining ?? 0) - 0.27) < 1e-9 && store.accountUsage.secondary.title(fallback: "Secondary") == "90 minutes", "quota: remaining and used are not reversed")
        let beforeEmpty = updates.count
        live.receive(.init(id: 3, time: 3, method: "account/rateLimits/updated", params: [:]))
        check(updates.count == beforeEmpty + 1 && store.accountUsage.percentage == "—" && store.accountUsage.primary.description == "Not reported", "quota: fieldless push publishes unknown, never 0%")
        store.applyCoreRateLimits(["rateLimits": ["limitId": "other", "primary": ["usedPercent": 80]], "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 32], "secondary": ["usedPercent": 87, "resetsAt": 200]]]])
        check(store.accountUsage.tightest?.used == 0.87 && store.accountUsage.primary.limitID == "codex" && store.accountUsage.secondary.resetsAt == Date(timeIntervalSince1970: 200), "quota: codex bucket and tightest retain limit ID and real reset")
        store.applyCoreRateLimits(["primary": ["usedPercent": 15, "limitId": "primary-id"], "secondary": ["usedPercent": 65, "limitId": "secondary-id"]])
        check(store.accountUsage.primary.limitID == "primary-id" && store.accountUsage.secondary.limitID == "secondary-id", "quota: each window retains its own reported limit ID")
        await live.refreshAccountUsage()
        check(store.accountUsage.identity.name == "Account A" && store.accountUsage.identity.plan == "plus" && store.accountUsage.identity.source == .live, "account: live identity is typed from account/read")
        backend.name = "Account silently changed"; backend.limits = ["primary": ["usedPercent": 36]]
        let beforeIdentityChange = updates.count
        await live.refreshAccountUsage()
        let identityChange = updates.dropFirst(beforeIdentityChange).filter { $0.identity.name == "Account silently changed" }
        check(identityChange.first?.primary.used == nil && identityChange.last?.primary.used == 0.36, "account: account/read discovers identity change without publishing old-account usage")
        backend.name = "Account A"; await live.refreshAccountUsage()
        backend.failLimits = true; await live.refreshAccountUsage()
        check(store.accountUsage.tightest == nil && store.accountUsage.identity.name == "Account A", "account: failed limits read clears and publishes without discarding valid identity")
        backend.failAccount = true; await live.refreshAccountUsage()
        check(store.accountUsage.identity.source == .unknown && store.accountUsage.percentage == "—", "account: account read failure removes old name and usage")
        backend.failAccount = false; backend.failLimits = false; await live.refreshAccountUsage()
        backend.holdMethod = "account/read"
        let beforeFailure = Task { await live.refreshAccountUsage() }
        for _ in 0..<2000 { if backend.held != nil { break }; await Task.yield() }
        backend.holdMethod = nil; backend.failAccount = true; await live.refreshAccountUsage()
        backend.release(); await beforeFailure.value
        check(store.accountUsage.identity == .unknown && store.accountUsage.tightest == nil, "epoch: account read failure invalidates already-pending older reads")
        backend.failAccount = false; backend.failLimits = false
        for method in ["account/read", "account/rateLimits/read"] {
            backend.name = "Account A"; backend.holdMethod = method
            backend.limits = ["primary": ["usedPercent": 21]]
            let old = Task { await live.refreshAccountUsage() }
            for _ in 0..<2000 { if backend.held != nil { break }; await Task.yield() }
            check(backend.held != nil, "epoch: delayed \(method) reached suspended transport")
            live.invalidateAccountUsage()
            check(store.accountUsage.identity == .unknown && updates.last?.tightest == nil, "epoch: clear publishes unknown immediately")
            backend.holdMethod = nil; backend.name = "Account B"
            backend.limits = ["primary": ["usedPercent": 64, "windowDurationMins": 60]]
            await live.refreshAccountUsage()
            backend.release(); await old.value
            check(store.accountUsage.identity.name == "Account B" && store.accountUsage.primary.used == 0.64, "epoch: old-account \(method) cannot overwrite new identity or limits")
        }
        backend.holdMethod = "account/rateLimits/read"
        let oldLimits = Task { await live.refreshAccountUsage() }
        for _ in 0..<2000 { if backend.held != nil { break }; await Task.yield() }
        live.receive(.init(id: 4, time: 4, method: "account/rateLimits/updated", params: ["primary": ["usedPercent": 91]]))
        backend.release(); await oldLimits.value
        check(store.accountUsage.primary.used == 0.91, "epoch: newer push supersedes same-account slow read")
        backend.holdMethod = "account/read"
        let obsoleteFailure = Task { await live.refreshAccountUsage() }
        for _ in 0..<2000 { if backend.held != nil { break }; await Task.yield() }
        backend.holdMethod = nil; backend.limits = ["primary": ["usedPercent": 88]]
        await live.refreshAccountUsage(); backend.failHeld(); await obsoleteFailure.value
        check(store.accountUsage.identity.name == "Account B" && store.accountUsage.primary.used == 0.88, "epoch: older failed read cannot clear a newer successful read of the same account")
        backend.loggedOut = true
        live.receive(.init(id: 5, time: 5, method: "account/updated", params: [:]))
        for _ in 0..<2000 { await Task.yield(); if live.account != .null { break } }
        check(store.accountUsage.identity == .unknown && store.accountUsage.tightest == nil, "account: account/updated logout clears old account and limits")
        backend.loggedOut = false; backend.name = "Account C"; await live.refreshAccountUsage()
        check(store.accountUsage.identity.name == "Account C", "account: reconnect refresh restores the current account")
        let beforeClear = updates.count; live.shutdown()
        check(updates.count > beforeClear && store.accountUsage.identity == .unknown, "account: shutdown invalidates pending reads and publishes clear")
        let beforeCancel = updates.count; observer.cancel(); observer.cancel(); store.clearCoreQuota()
        check(store.accountUsageObservationCount == 0 && updates.count == beforeCancel, "observer: cancel is immediate, removable and idempotent")
        store.removeObserver(threadObserver)
        let mock = ConversationStore()
        check(mock.accountUsage.identity.source == .prototype && mock.accountUsage.identity.name == "Louis L.", "account: mock prototype is explicitly labelled")
        check(AccountUsageIdentity(accountRead: ["account": ["type": "apiKey"]]).name == nil, "account: missing live name never falls back to prototype")
        check(zip(updates, updates.dropFirst()).allSatisfy { $0.version < $1.version }, "observer: published immutable versions increase")
        await interleavings(check)
    }
}

@MainActor private final class UsageGateClock: CoreRuntimeClock {
    var delays: [Double] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []
    var pendingCount: Int { waiters.count }
    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation(); delays.append(seconds)
        try await withCheckedThrowingContinuation { waiters.append($0) }
        try Task.checkCancellation()
    }
    func step() { let current = waiters; waiters = []; for waiter in current { waiter.resume() } }
}
private final class InterleavedUsageTransport: CoreTransport, @unchecked Sendable {
    let backend: InterleavedUsageBackend
    init(_ backend: InterleavedUsageBackend) { self.backend = backend }
    func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
        try await backend.request(body?["method"]?.stringValue ?? path)
    }
    func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> {
        .init { sink in Task { @MainActor in self.backend.attach(sink) } }
    }
}
@MainActor private final class InterleavedUsageBackend {
    var instance = "fixture-server", high = 0, subscriptions = 0, threadReads = 0, accountReads = 0
    var accountFailures = 0, limitFailures = 0
    var holdMethod: String?, held: CheckedContinuation<JSONValue, Error>?, heldValue: JSONValue?
    private var sinks: [AsyncThrowingStream<CoreEvent, Error>.Continuation] = []
    private var events: [CoreEvent] = []
    func attach(_ sink: AsyncThrowingStream<CoreEvent, Error>.Continuation) { subscriptions += 1; sinks.append(sink) }
    func closeStream() { for sink in sinks { sink.finish() }; sinks = [] }
    func emitName(_ name: String) {
        high += 1
        let event = CoreEvent(id: high, time: Double(high), method: "thread/name/updated", params: ["threadId":"fixture-thread", "name":.string(name)])
        events.append(event); for sink in sinks { sink.yield(event) }
    }
    func request(_ method: String) async throws -> JSONValue {
        let value: JSONValue
        switch method {
        case "/health": value = ["name":"Organic Codex Core", "backendConnected":true, "instanceId":.string(instance), "lastEventId":.number(Double(high)), "pendingApprovals":[], "sessions":[["id":"fixture-thread", "loaded":true]]]
        case "/capabilities": value = [:]
        case "/sessions": value = [["id":"fixture-thread", "loaded":true, "name":"Fixture"]]
        case "thread/list", "model/list": value = ["data":[]]
        case "thread/read": threadReads += 1; value = ["thread":["id":"fixture-thread", "turns":[]]]
        case "account/read":
            accountReads += 1
            if accountFailures > 0 { accountFailures -= 1; throw CoreWire.failure("fixture account temporarily unavailable") }
            value = ["account":["email":"fixture-account", "planType":"plus"]]
        case "account/rateLimits/read":
            if limitFailures > 0 { limitFailures -= 1; throw CoreWire.failure("fixture limits temporarily unavailable") }
            value = ["primary":["usedPercent":21,"windowDurationMins":120]]
        default:
            guard method.hasPrefix("/events.json") else { throw CoreWire.failure("Unexpected interleaving route: " + method) }
            value = .array(try events.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) })
        }
        if holdMethod == method { heldValue = value; return try await withCheckedThrowingContinuation { held = $0 } }
        return value
    }
    func release() { let continuation = held; held = nil; holdMethod = nil; continuation?.resume(returning: heldValue ?? [:]) }
}
@MainActor extension AccountUsageVerification {
    private static func until(_ predicate: () -> Bool) async {
        for _ in 0..<5000 { if predicate() { return }; await Task.yield() }
    }
    private static func fixture() -> (LiveConversationRuntime, InterleavedUsageBackend, UsageGateClock) {
        let store = ConversationStore(), backend = InterleavedUsageBackend(), clock = UsageGateClock()
        let presentation = LocalPresentationState(store: store, scope: "interleaved-usage-fixture", storage: CoreMemoryStorage())
        let live = LiveConversationRuntime(store: store, client: InterleavedUsageTransport(backend), presentation: presentation, clock: clock)
        live.isShown = { $0 == "fixture-thread" }; return (live, backend, clock)
    }
    private static func cleanup(_ live: LiveConversationRuntime, _ backend: InterleavedUsageBackend, _ clock: UsageGateClock) async {
        live.shutdown(); backend.release(); backend.closeStream(); clock.step()
        for _ in 0..<20 { await Task.yield() }
    }
    static func interleavings(_ check: (Bool, String) -> Void) async {
        do {
            let (live, backend, clock) = fixture()
            try await live.load(); live.start()
            await until { backend.subscriptions == 1 && live.store.accountUsage.primary.used == 0.21 }
            backend.holdMethod = "/capabilities"
            var completed = false
            let reload = Task { try? await live.load(); completed = true }
            await until { backend.held != nil }
            check(backend.held != nil, "recovery: load pauses in actual transport")
            backend.closeStream(); await until { !live.isConnected }
            check(!live.isConnected, "recovery: stream ended while load was suspended")
            backend.release(); await until { completed && live.store.accountUsage.primary.used == 0.21 }
            check(completed && live.store.accountUsage.primary.used == 0.21, "recovery: load surviving stream loss never stays unknown without a push")
            await reload.value; await cleanup(live, backend, clock)
        } catch { check(false, "recovery: fixture load failed: " + error.localizedDescription) }
        do {
            let (live, backend, clock) = fixture()
            try await live.load(); await until { live.store.accountUsage.primary.used == 0.21 }
            let reads = backend.accountReads
            backend.instance = "replacement-fixture-server"
            guard let c = live.store.conversation("fixture-thread") else { check(false,"recovery: fixture thread missing"); return }
            live.refresh(c)
            await until { backend.accountReads > reads && backend.threadReads > 0 && !c.loading && live.store.accountUsage.primary.used == 0.21 }
            check(backend.accountReads > reads && backend.threadReads > 0 && live.store.accountUsage.primary.used == 0.21, "recovery: refresh thread reset also recovers account usage")
            await cleanup(live, backend, clock)
        } catch { check(false, "recovery: reset fixture failed: " + error.localizedDescription) }
        for method in ["account/read", "account/rateLimits/read"] {
            do {
                let (live, backend, clock) = fixture()
                try await live.load(); live.start()
                await until { backend.subscriptions == 1 && live.store.accountUsage.primary.used == 0.21 }
                let before = backend.threadReads
                var notified = 0, settingsInvalidations = 0
                live.onStateChange = { if live.store.quotaFiveHourReported && live.store.quotaFiveHour == 0.21 { notified += 1 } }
                live.onAccountUsageChange = { if live.store.quotaFiveHourReported { settingsInvalidations += 1 } }
                backend.holdMethod = method; backend.closeStream()
                await until { !live.isConnected && clock.pendingCount > 0 }; clock.step()
                await until { backend.held != nil && backend.subscriptions >= 2 && backend.threadReads > before }
                check(backend.held != nil && backend.subscriptions >= 2 && backend.threadReads > before, "nonblocking: slow " + method + " does not block subscription or thread reread")
                backend.emitName("stream-while-account-held")
                await until { live.store.conversation("fixture-thread")?.title == "stream-while-account-held" }
                check(backend.held != nil && live.store.conversation("fixture-thread")?.title == "stream-while-account-held", "nonblocking: live thread event arrives before " + method + " returns")
                notified = 0; settingsInvalidations = 0
                backend.release(); await until { live.store.accountUsage.primary.used == 0.21 }
                check(live.store.accountUsage.primary.used == 0.21 && notified > 0 && settingsInvalidations > 0, "refresh-notify: reread notifies existing quota consumers after " + method)
                live.onStateChange = nil; live.onAccountUsageChange = nil
                await cleanup(live, backend, clock)
            } catch { check(false, "nonblocking: fixture failed: " + error.localizedDescription) }
        }
        for failure in ["account", "limits"] {
            do {
                let (live, backend, clock) = fixture()
                try await live.load(); live.start()
                await until { backend.subscriptions == 1 && live.store.accountUsage.primary.used == 0.21 }
                let reads = backend.accountReads
                if failure == "account" { backend.accountFailures = 1 } else { backend.limitFailures = 1 }
                backend.closeStream(); await until { !live.isConnected && clock.pendingCount > 0 }; clock.step()
                await until { backend.subscriptions >= 2 && backend.accountReads > reads && clock.pendingCount > 0 }
                check(backend.subscriptions >= 2 && backend.accountReads > reads && clock.pendingCount > 0 && clock.delays.last == live.reconnectPolicy.initial,
                      "retry: reconnect " + failure + " failure backs off without blocking stream")
                backend.emitName("stream-during-" + failure + "-retry")
                await until { live.store.conversation("fixture-thread")?.title == "stream-during-" + failure + "-retry" }
                check(live.store.conversation("fixture-thread")?.title == "stream-during-" + failure + "-retry", "retry: stream remains live while account retry sleeps")
                let threadReads = backend.threadReads
                if let c = live.store.conversation("fixture-thread") { live.refresh(c) }
                await until { backend.threadReads > threadReads && live.store.conversation("fixture-thread")?.loading == false }
                check(backend.threadReads > threadReads && live.store.conversation("fixture-thread")?.loading == false,
                      "retry: thread refresh completes during account backoff")
                clock.step(); await until { live.store.accountUsage.primary.used == 0.21 }
                check(backend.accountReads >= reads + 2 && live.store.accountUsage.primary.used == 0.21, "retry: " + failure + " failure recovers without a push or new reconnect")
                await cleanup(live, backend, clock)
            } catch { check(false, "retry: fixture failed: " + error.localizedDescription) }
        }
    }
}
#endif
