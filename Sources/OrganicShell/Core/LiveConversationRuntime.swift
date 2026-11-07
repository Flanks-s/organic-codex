import Foundation

@MainActor final class LiveConversationRuntime: ConversationRuntime {
    let store: ConversationStore
    let client: any CoreTransport
    var connectionStatus = "Connecting to Organic Core…" { didSet { onStateChange?() } }
    var isConnected = false { didSet { onStateChange?() } }
    var account: JSONValue = .null
    var lastError: String? { didSet { onStateChange?() } }
    var isShown: (ConversationID) -> Bool = { _ in false }
    var onRedEvent: (Conversation) -> Void = { _ in }
    private var stream: Task<Void, Never>?
    var isStreaming: Bool { stream != nil }
    private var cursor = 0
    private var loaded = false
    private var historyCursors: [Bool: String] = [:]
    private var historyExhausted: Set<Bool> = []
    private var pendingCreations = 0
    private var orphanEvents: [CoreEvent] = []
    private var normallyCompletedQueueTurns: Set<String> = []
    private var queuedDispatches: Set<String> = []
    private var resumeNeeded: Set<String> = []
    private var knownLoadedThreads: Set<String> = []
    private var completedTurns: Set<String> = []
    private var terminalSnapshotTurns: Set<String> = []
    private var terminalStatuses: [String: String] = [:]
    private var requestedStops: Set<String> = []
    private var pendingResponses: Set<String> = []
    private var outbound: [String: (ConversationID, QueuedMessage)] = [:]
    private var acknowledged: Set<String> = []
    private var steeringMessages: Set<String> = []
    private var loadingThreads: Set<String> = []
    private var bufferedEvents: [String: [CoreEvent]] = [:]
    private var hydratedThreads: Set<String> = []
    private var replayItemBaselines: [String: Set<String>] = [:]
    private var threadWatermarks: [String: Int] = [:]

    let service: CoreService?
    let clock: any CoreRuntimeClock
    let presentation: LocalPresentationState
    var reconnectPolicy = CoreReconnectPolicy()
    var onStateChange: (() -> Void)?
    var onEvent: ((CoreEvent) -> Void)?
    var onAttachmentRequested: ((Conversation) -> Void)?
    var onRevertRequested: ((TranscriptItem, Conversation) -> Void)?
    var onSubmissionReconciled: ((CoreSubmissionReceipt) -> Void)?
    private var receipts: [UUID: CoreSubmissionReceipt] = [:]
    private var submissions: [UUID: CoreSubmission] = [:]
    private var submissionOwners: [UUID: String] = [:]
    private var completions: [UUID: [(CoreSubmissionReceipt) -> Void]] = [:]
    private var serverInstance: String?
    private var readEpoch = 0
    private var restored = false
    private var paging: Set<Bool> = []
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var stoppingIDs: [UUID: String] = [:]
    private(set) var capabilities: JSONValue = .null
    var eventCursor: Int { cursor }
    func readWatermark(threadID: String) -> Int? { threadWatermarks[threadID] }
    func hasMoreHistory(archived: Bool = false) -> Bool { !historyExhausted.contains(archived) }
    func historyCursor(archived: Bool = false) -> String? { historyCursors[archived] }
    func receipt(for id: UUID) -> CoreSubmissionReceipt? { receipts[id] }

    /// A window may close before connect/load completes. Preserve previously saved local drafts before writing.
    func saveWindowPresentation(_ windows: [LocalPresentationState.WindowState]) throws {
        restorePresentation()
        presentation.setWindows(windows)
        try presentation.save()
    }

    private func restorePresentation() {
        guard !restored else { return }; restored = true
        presentation.restore(); presentation.observe()
        for id in presentation.accepted { receipts[id] = .init(id: id, result: .accepted, acceptance: .backend) }
        for c in store.conversations {
            if let tid = c.backendThreadID { resumeNeeded.insert(tid) }
            for submission in presentation.restoredOutbound(in: c) {
                submissions[submission.id] = submission; submissionOwners[submission.id] = c.id
                outbound[submission.id.uuidString] = (c.id, message(submission))
                receipts[submission.id] = .init(id: submission.id, result: .outcomeUnknown("Restored send needs a receipt from history."))
            }
        }
    }
    private func checkedHealth() async throws -> JSONValue {
        if let service { try await service.checkHealth(); return service.health }
        let health = try await client.request(path: "/health")
        guard health["name"]?.stringValue == "Organic Codex Core", health["backendConnected"]?.boolValue == true else { throw failure("The configured endpoint is not a connected Organic Core.") }
        return health
    }
    private func reconcilePending(_ health: JSONValue, only c: Conversation? = nil) {
        guard let pending = health["pendingApprovals"]?.arrayValue else { return }
        let targets = c.map { [$0] } ?? store.conversations
        for chat in targets { chat.approvals = []; chat.userInput = nil; chat.question = nil }
        for p in pending {
            guard let tid = p["threadId"]?.stringValue, c == nil || c?.backendThreadID == tid else { continue }
            EventReducer.approval(p, in: conversation(threadID: tid))
        }
        for chat in targets {
            for i in chat.approvals.indices { chat.approvals[i].submitting = pendingResponses.contains(chat.approvals[i].id) }
            if let id = chat.userInput?.id { chat.userInput?.submitting = pendingResponses.contains(id) }
            store.changed(chat)
        }
    }
    private func noteServer(_ health: JSONValue) -> Bool {
        let instance = health["instanceId"]?.stringValue
        let previousHigh = max(cursor, threadWatermarks.values.max() ?? 0)
        let reset = (serverInstance != nil && instance != nil && instance != serverInstance) || (health["lastEventId"]?.intValue ?? previousHigh) < previousHigh
        if let instance { serverInstance = instance }
        if reset {
            readEpoch += 1; bufferedEvents = [:]
            cursor = 0; threadWatermarks = [:]; hydratedThreads = []; replayItemBaselines = [:]
            completedTurns = []; terminalSnapshotTurns = []; terminalStatuses = [:]; knownLoadedThreads = []; normallyCompletedQueueTurns = []; historyCursors = [:]; historyExhausted = []
            for c in store.conversations { c.historyLoaded = false; if let tid = c.backendThreadID { resumeNeeded.insert(tid) } }
        }
        return reset
    }

    init(store: ConversationStore, client: any CoreTransport, service: CoreService? = nil,
         presentation: LocalPresentationState? = nil, clock: any CoreRuntimeClock = CoreSystemClock()) {
        self.store = store; self.client = client; self.service = service; self.clock = clock
        let scope = service?.baseURL.absoluteString ?? (client as? CoreClient)?.baseURL.absoluteString ?? "injected-core"
        self.presentation = presentation ?? LocalPresentationState(store: store, scope: scope)
        store.usesLiveCore = true
        for c in store.conversations { c.branch = ""; c.isLiveConversation = true }
        ModelCatalog.models = []; store.newChatSettings.modelID = ""; store.clearCoreQuota()
        store.updateDevices([Device(id: "mac", name: "Core Host", kind: .server, online: false)])
    }

    /// Capture the event high-water mark before hydration; start() replays everything after it.
    func load() async throws {
        restorePresentation()
        let health = try await checkedHealth()
        _ = noteServer(health)
        capabilities = try await client.request(path: "/capabilities")
        store.normalizeProjects(isLocalBackend: (service?.isLocalBackend ?? false))
        if !loaded { cursor = health["lastEventId"]?.intValue ?? 0 }
        let sessions = try await client.request(path: "/sessions")
        for session in sessions.arrayValue ?? [] {
            guard let id = session["id"]?.stringValue else { continue }
            let c = conversation(threadID: id, title: session["name"]?.stringValue ?? session["title"]?.stringValue)
            c.cwd = session["cwd"]?.stringValue.map(store.canonicalProjectPath)
            c.activeTurnID = session["active"]?.stringValue
            c.running = c.activeTurnID != nil
            if let model = session["model"]?.stringValue { c.settings.modelID = model; if c.next.modelID.isEmpty { c.next.modelID = model } }
            if session["loaded"]?.boolValue == true { knownLoadedThreads.insert(id); resumeNeeded.remove(id) }
            else { knownLoadedThreads.remove(id); resumeNeeded.insert(id) }
            if let cwd = c.cwd {
                let projectID = "cwd:" + cwd
                c.projectID = store.addProject(Project(id: projectID, name: URL(fileURLWithPath: cwd).lastPathComponent, deviceID: "mac", path: cwd)).id
            }
            // Transcript history is loaded on selection, not for every sidebar row.
        }
        try await loadMoreHistory()
        try await loadMoreHistory(archived: true)
        var modelValues: [JSONValue] = []
        var modelCursor: String?; var seen: Set<String> = []
        repeat {
            let catalog = try await client.rpc("model/list", params: modelCursor.map { ["cursor": .string($0)] } ?? [:])
            modelValues += catalog["data"]?.arrayValue ?? []
            modelCursor = catalog["nextCursor"]?.stringValue
            if let next = modelCursor, !seen.insert(next).inserted { throw failure("Core repeated a model-list cursor.") }
        } while modelCursor != nil
        ModelCatalog.models = ModelCatalog.coreModels(modelValues)
        if store.newChatSettings.modelID.isEmpty, let preferred = modelValues.first(where: { $0["isDefault"]?.boolValue == true })?["id"]?.stringValue ?? ModelCatalog.models.first?.id {
            store.newChatSettings.modelID = preferred
            store.newChatSettings.effort = ModelCatalog.defaultEffort(ModelCatalog.model(preferred))
        }
        // A removed model remains visible by ID; changing it requires a user's choice.
        for c in store.conversations where c.next.modelID.isEmpty { c.next = store.newChatSettings }
        account = try await client.rpc("account/read")
        do { applyLimits(try await client.rpc("account/rateLimits/read")) } catch { store.clearCoreQuota(); lastError = error.localizedDescription }
        reconcilePending(health)
        store.updateDevices([Device(id: "mac", name: (service?.isLocalBackend ?? false) ? "This Mac" : "Core Host", kind: (service?.isLocalBackend ?? false) ? .mac : .server, online: true)])
        loaded = true; isConnected = true; connectionStatus = "Connected to Organic Core"
        for c in store.conversations {
            store.changed(c)
            if c.backendThreadID != nil && (c.sendOutcomeUnknown || !c.queued.isEmpty) { try await read(c, includeSatellites: false) }
        }
    }

    func loadMoreHistory(archived: Bool = false) async throws {
        guard !historyExhausted.contains(archived), paging.insert(archived).inserted else { return }
        defer { paging.remove(archived) }
        var params: [String: JSONValue] = ["limit": 50, "archived": .bool(archived), "sortKey": "updated_at"]
        if let cursor = historyCursors[archived] { params["cursor"] = .string(cursor) }
        let result = try await client.rpc("thread/list", params: params)
        for thread in result["data"]?.arrayValue ?? [] {
            guard let tid = thread["id"]?.stringValue else { continue }
            let c = conversation(threadID: tid, title: thread["name"]?.stringValue ?? thread["preview"]?.stringValue)
            c.archived = archived; c.cwd = (thread["cwd"]?.stringValue ?? c.cwd).map(store.canonicalProjectPath)
            if let time = thread["updatedAt"]?.doubleValue { c.updated = Date(timeIntervalSince1970: time) }
            if !knownLoadedThreads.contains(tid) { resumeNeeded.insert(tid) }
            if let cwd = c.cwd {
                let pid = "cwd:" + cwd
                c.projectID = store.addProject(Project(id: pid, name: URL(fileURLWithPath: cwd).lastPathComponent, deviceID: "mac", path: cwd)).id
            }
        }
        if let next = result["nextCursor"]?.stringValue, !next.isEmpty {
            guard next != historyCursors[archived] else { throw failure("Core repeated a history cursor; no page was skipped.") }
            historyCursors[archived] = next
        } else { historyExhausted.insert(archived); historyCursors[archived] = nil }
        for c in store.conversations { store.changed(c) }
    }

    func start() {
        guard stream == nil else { return }
        stream = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    if !loaded { try await load() }
                    let reconnecting = !isConnected
                    let health = try await checkedHealth()
                    let reset = noteServer(health)
                    isConnected = true; store.setOnline("mac", true); connectionStatus = "Connected to Organic Core"
                    reconcilePending(health)
                    for session in health["sessions"]?.arrayValue ?? [] {
                        guard let id = session["id"]?.stringValue else { continue }
                        if session["loaded"]?.boolValue == true { knownLoadedThreads.insert(id); resumeNeeded.remove(id) }
                        else { knownLoadedThreads.remove(id); resumeNeeded.insert(id) }
                        if let c = store.backendConversation(id) {
                            c.activeTurnID = session["active"]?.stringValue; c.running = c.activeTurnID != nil
                            if !c.running { c.stopping = false }; store.changed(c)
                        }
                    }
                    if reconnecting || reset {
                        for c in store.conversations where isShown(c.id) && c.backendThreadID != nil { try await read(c) }
                    }
                    // Global stream: Core's thread filter would omit account/authorization/capability events.
                    let streamEpoch = readEpoch
                    for try await event in client.events(since: cursor) {
                        try Task.checkCancellation()
                        guard streamEpoch == readEpoch else { break }
                        receive(event); attempt = 0
                    }
                    isConnected = false; store.setOnline("mac", false); connectionStatus = "Reconnecting to Organic Core…"
                } catch {
                    if Task.isCancelled { return }
                    isConnected = false; store.setOnline("mac", false); lastError = error.localizedDescription
                    connectionStatus = "Reconnecting: \(error.localizedDescription)"
                }
                do { try await clock.sleep(seconds: reconnectPolicy.delay(attempt: attempt)) } catch { return }
                attempt += 1
            }
        }
    }

    func shutdown() {
        stream?.cancel(); stream = nil
        // Do not cancel an in-flight write and report it failed. A late receipt can still reconcile it.
        do { try presentation.save() } catch { lastError = error.localizedDescription }
        isConnected = false; connectionStatus = "Disconnected"
    }

    @discardableResult func conversation(threadID: String, title: String? = nil) -> Conversation {
        if let c = store.backendConversation(threadID) { return c }
        let c = Conversation(id: presentation.localID(forBackend: threadID) ?? threadID, identityIndex: store.nextIdentity(), title: title ?? "Chat \(threadID.suffix(8))", projectID: nil, updated: Date(), contextUsed: 0)
        c.branch = ""; c.isLiveConversation = true
        c.settings.modelID = ""; c.next = store.newChatSettings
        c.backendThreadID = threadID
        presentation.apply(to: c)
        store.add(c)
        return c
    }

    func read(_ c: Conversation, includeSatellites: Bool = true, allowFinalSnapshot: Bool = true) async throws {
        guard let tid = c.backendThreadID, !loadingThreads.contains(tid) else { return }
        loadingThreads.insert(tid); c.loading = true; store.changed(c)
        let epoch = readEpoch
        let seeded = hydratedThreads.contains(tid)
        let replay = HistoryReplay(conversation: c, cursor: seeded ? (threadWatermarks[tid] ?? 0) : 0, seeded: seeded, trustedItemIDs: replayItemBaselines[tid] ?? [])
        var acceptedWatermark: Int?
        defer {
            loadingThreads.remove(tid); c.loading = false
            let events = bufferedEvents.removeValue(forKey: tid) ?? []
            if acceptedWatermark != nil && seeded {
                for event in replay.completed { finish(event, in: c, refresh: false) }
            }
            for event in events where event.id > (acceptedWatermark ?? -1) { apply(event, to: c, replaying: true) }
            if acceptedWatermark != nil {
                if replay.needsFinalSnapshot && allowFinalSnapshot {
                    // The watermark is already committed. This one follow-up cannot replay
                    // the same completion and recursively schedule another read.
                    Task { [weak self] in
                        do { try await self?.read(c, includeSatellites: false, allowFinalSnapshot: false) }
                        catch { self?.report(error, in: c) }
                    }
                } else { deliverQueued(c) }
            }
            store.changed(c)
            if epoch != readEpoch && isShown(c.id) {
                Task { [weak self] in do { try await self?.read(c) } catch { self?.report(error, in: c) } }
            }
        }
        let result = try await client.rpc("thread/read", params: ["threadId": .string(tid), "includeTurns": true])
        guard result["thread"]?.objectValue != nil, result["thread"]?["id"]?.stringValue == tid else { throw failure("Core returned no matching thread history; the read watermark was not advanced.") }
        let health = try await checkedHealth()
        guard epoch == readEpoch, serverInstance == nil || health["instanceId"]?.stringValue == nil || serverInstance == health["instanceId"]?.stringValue else { throw failure("Core restarted during history loading. Refresh its connection and history.") }
        guard let high = health["lastEventId"]?.intValue, high >= replay.cursor else { throw failure("Core returned no valid history watermark. Refresh its connection before retrying.") }
        var since = replay.cursor
        while since < high {
            let page = try await client.request(path: CoreWire.eventPage(threadID: tid, since: since))
            let events = try await Task.detached {
                try (page.arrayValue ?? []).map { try JSONDecoder().decode(CoreEvent.self, from: JSONEncoder().encode($0)) }
            }.value
            for event in events { replay.apply(event, through: high) }
            guard let last = events.last, events.count == 100, last.id < high else { break }
            guard last.id > since else { throw failure("Core event pagination did not advance.") }
            since = last.id
            await Task.yield()
        }
        guard epoch == readEpoch else { throw failure("Core restarted during event replay. Refresh history.") }
        if let thread = result["thread"] {
            EventReducer.hydrate(thread, into: c)
            for turn in thread["turns"]?.arrayValue ?? [] {
                for item in turn["items"]?.arrayValue ?? [] { acknowledge(item, turnID: turn["id"]?.stringValue) }
            }
        }
        replay.merge(into: c, snapshot: result["thread"])
        reconcilePending(health, only: c)
        replayItemBaselines[tid] = replay.authoritativeItemIDs
        for turn in result["thread"]?["turns"]?.arrayValue ?? [] {
            if let id = turn["id"]?.stringValue, let status = turn["status"]?.stringValue {
                if ["completed", "interrupted", "failed"].contains(status) { terminalSnapshotTurns.insert(id); terminalStatuses[id] = status }
                recordQueueOutcome(turn: id, status: status, in: c, stopped: requestedStops.contains(id))
            }
        }
        for event in replay.completed {
            if let turn = event.params["turn"], let id = turn["id"]?.stringValue, let status = turn["status"]?.stringValue {
                recordQueueOutcome(turn: id, status: status, in: c, stopped: requestedStops.contains(id))
            }
        }
        if let active = c.activeTurnID, let status = terminalStatuses[active] {
            c.activeTurnID = nil; c.running = false; c.stopping = false; c.lastTurnInterrupted = status == "interrupted"
            for i in c.items.indices where c.items[i].turnID == active && c.items[i].status == "running" {
                c.items[i].status = status == "interrupted" ? "interrupted" : status == "failed" ? "failed" : nil; c.items[i].revision += 1
            }
        }
        if let active = c.activeTurnID { advanceEligibleQueue(in: c, to: active) }
        let snapshotStatuses = result["thread"]?["turns"]?.arrayValue ?? []
        let knownTurns = Set(snapshotStatuses.filter { ["inProgress", "completed", "interrupted", "failed"].contains($0["status"]?.stringValue ?? "") }.compactMap { $0["id"]?.stringValue }).union(replay.lifecycleTurnIDs)
        for i in c.queued.indices where c.queued[i].deliveryError == nil {
            if let waiting = c.queued[i].waitingForTurnID, !knownTurns.contains(waiting), !normallyCompletedQueueTurns.contains(waiting) {
                c.queued[i].deliveryError = "The preceding turn could not be confirmed in history. Restore this message to send it manually."
            }
        }
        Task { [weak self] in await self?.refreshChanges(c) }
        hydratedThreads.insert(tid); threadWatermarks[tid] = high; acceptedWatermark = high
        if includeSatellites { loadSatellites(c) }
    }

    func receive(_ event: CoreEvent) {
        guard event.id > cursor else { return }
        cursor = event.id; onEvent?(event)
        if event.method == "account/rateLimits/updated" { applyLimits(event.params); onStateChange?(); return }
        if event.method == "account/updated" {
            store.clearCoreQuota()
            Task { [weak self] in
                guard let self else { return }
                do { applyLimits(try await client.rpc("account/rateLimits/read")) }
                catch { lastError = error.localizedDescription }
            }
        }
        let tid = event.params["threadId"]?.stringValue ?? event.params["thread"]?["id"]?.stringValue
        guard let tid else { return }
        if store.backendConversation(tid) == nil && pendingCreations > 0 { orphanEvents.append(event); return }
        let c = conversation(threadID: tid)
        if loadingThreads.contains(tid) { bufferedEvents[tid, default: []].append(event); return }
        if event.id > (threadWatermarks[tid] ?? -1) { apply(event, to: c) }
    }

    private func apply(_ event: CoreEvent, to c: Conversation, replaying: Bool = false) {
        if let tid = c.backendThreadID {
            guard event.id > (threadWatermarks[tid] ?? -1) else { return }
            threadWatermarks[tid] = event.id
            if ["item/started", "item/completed"].contains(event.method), let id = event.params["item"]?["id"]?.stringValue {
                replayItemBaselines[tid, default: []].insert(id)
            }
        }
        if event.method == "item/completed", event.params["item"]?["type"]?.stringValue == "fileChange" {
            Task { [weak self] in await self?.refreshChanges(c) }
        }
        let wasRunning = c.running
        // A late lifecycle notification cannot revive a terminal turn already hydrated from history.
        let turnID = event.params["turnId"]?.stringValue ?? event.params["turn"]?["id"]?.stringValue
        if event.method == "turn/started", let turnID, (completedTurns.contains(turnID) || terminalStatuses[turnID] != nil) { return }
        if let turnID, terminalStatuses[turnID] != nil, event.method == "item/started" || event.params["delta"] != nil { return }
        let change = EventReducer.applyReportingChange(event, to: c)
        if event.method == "turn/started", let active = c.activeTurnID { advanceEligibleQueue(in: c, to: active) }
        if let item = event.params["item"] { acknowledge(item, turnID: event.params["turnId"]?.stringValue) }
        if event.method == "turn/completed" { finish(event, in: c, refresh: true) }
        if event.method == "error" { onRedEvent(c) }
        for parent in store.conversations {
            if let index = parent.satellites.firstIndex(where: { $0.threadID == c.backendThreadID }) {
                parent.satellites[index].items = c.items
                if wasRunning && !c.running && !parent.satellites[index].done {
                    parent.satellites[index].done = true
                    parent.satellites[index].finishedOrder = (parent.satellites.compactMap(\.finishedOrder).max() ?? -1) + 1
                }
                store.changed(parent)
            }
        }
        if event.method == "item/completed", event.params["item"]?["type"]?.stringValue == "collabAgentToolCall" { loadSatellites(c) }
        if wasRunning && !c.running { persistDraft(c) }
        store.changed(c, change: replaying ? .structural : change)
    }

    private func loadSatellites(_ c: Conversation) {
        for satellite in c.satellites {
            guard let tid = satellite.threadID else { continue }
            let child = conversation(threadID: tid, title: satellite.title)
            Task { [weak self] in
                do {
                    if !child.historyLoaded { try await self?.read(child, includeSatellites: false) }
                    if let i = c.satellites.firstIndex(where: { $0.threadID == tid }) { c.satellites[i].items = child.items; self?.store.changed(c) }
                } catch { self?.report(error, in: child) }
            }
        }
    }

    private func finish(_ event: CoreEvent, in c: Conversation, refresh: Bool) {
        guard let turn = event.params["turn"]?["id"]?.stringValue, completedTurns.insert(turn).inserted else { return }
        let stopped = requestedStops.remove(turn) != nil
        let status = event.params["turn"]?["status"]?.stringValue ?? ""
        recordQueueOutcome(turn: turn, status: status, in: c, stopped: stopped)
        if status == "completed" && !stopped {
            if !isShown(c.id) { c.completions += 1; c.unread = true }
            if refresh { deliverQueued(c) } // Hydration releases its queue after reconciliation.
        }
        if refresh { Task { [weak self] in do { try await self?.read(c) } catch { self?.report(error, in: c) } } }
    }

    private func acknowledge(_ item: JSONValue, turnID: String? = nil) {
        guard item["type"]?.stringValue == "userMessage", let rawID = item["clientId"]?.stringValue else { return }
        let id = UUID(uuidString: rawID)?.uuidString ?? rawID
        let located: (Conversation, QueuedMessage)?
        if let (cid, message) = outbound[id], let c = store.conversation(cid) { located = (c, message) }
        else if let c = store.conversations.first(where: { $0.queued.contains { $0.id == id } }),
                let message = c.queued.first(where: { $0.id == id }) { located = (c, message) }
        else { located = nil }
        guard let (c, message) = located else { return }
        let fromQueue = queuedDispatches.contains(id) || c.queued.contains { $0.id == id }
        // Transport bookkeeping cannot depend on c.sending: composer completion is allowed to change it.
        if let uuid = UUID(uuidString: id), operations[uuid] != nil { acknowledged.insert(id) }
        let wasSteering = steeringMessages.remove(id) != nil
        if outbound.removeValue(forKey: id) != nil { c.sending = false }
        queuedDispatches.remove(id); c.sendOutcomeUnknown = false; c.operationError = nil
        if fromQueue {
            if let turnID, let waiting = message.waitingForTurnID {
                for i in c.queued.indices where c.queued[i].id != id && c.queued[i].waitingForTurnID == waiting && c.queued[i].deliveryError == nil { c.queued[i].waitingForTurnID = turnID }
            }
            c.queued.removeAll { $0.id == id }
        } else {
            if c.draft == message.text { c.draft = "" }
            let ids = Set(message.attachments.map(\.id)); c.attachments.removeAll { ids.contains($0.id) }
        }
        if !wasSteering { c.settings = message.settings }
        if let uuid = UUID(uuidString: id) { presentation.clearOutbound(uuid, in: c); presentation.recordAccepted(uuid) }
        persistDraft(c)
        if let uuid = UUID(uuidString: id) { complete(uuid, result: .accepted, acceptance: .backend) }
    }

    private func applyLimits(_ value: JSONValue) {
        store.applyCoreRateLimits(value)
    }

    private func message(_ s: CoreSubmission) -> QueuedMessage {
        .init(id: s.id.uuidString, text: s.text, attachments: s.attachments, settings: s.settings, access: s.access, waitingForTurnID: s.waitingForTurnID)
    }
    private func complete(_ id: UUID, result: CoreSubmissionResult, acceptance: CoreSubmissionReceipt.Acceptance? = nil) {
        let receipt = CoreSubmissionReceipt(id: id, result: result, acceptance: acceptance)
        let previous = receipts[id]; receipts[id] = receipt
        let callbacks = completions.removeValue(forKey: id) ?? []
        for callback in callbacks { callback(receipt) }
        if callbacks.isEmpty, previous != receipt { onSubmissionReconciled?(receipt) }
    }
    @discardableResult func submit(_ s: CoreSubmission, in c: Conversation, completion: @escaping @MainActor (CoreSubmissionReceipt) -> Void) -> Bool {
        if let original = submissions[s.id], original != s || submissionOwners[s.id] != c.id {
            completion(.init(id: s.id, result: .failed("A submission UUID cannot be reused with a different snapshot or chat."))); return false
        }
        if stoppingIDs[s.id] != nil { completion(.init(id: s.id, result: .failed("This UUID belongs to an interrupt request."))); return false }
        if let queued = c.queued.first(where: { UUID(uuidString: $0.id) == s.id }), submissions[s.id] == nil {
            guard queued.text == s.text, queued.attachments == s.attachments, queued.settings == s.settings, queued.access == s.access, s.action == .queue else {
                completion(.init(id: s.id, result: .failed("This UUID belongs to a different queued snapshot."))); return false
            }
            completion(.init(id: s.id, result: .accepted, acceptance: .durableLocalQueue)); return true
        }
        if let receipt = receipts[s.id] { completion(receipt); return receipt.result == .accepted }
        if submissions[s.id] != nil { completions[s.id, default: []].append(completion); return true }
        submissions[s.id] = s; submissionOwners[s.id] = c.id; completions[s.id] = [completion]
        func reject(_ reason: String) -> Bool { complete(s.id, result: .failed(reason)); return false }
        guard s.identity == nil || s.identity == c.id else { return reject("Submission identity does not match this chat.") }
        guard isConnected, !store.isOffline(c), !c.sending, !c.loading, !c.sendOutcomeUnknown else { return reject("Wait for the connection and history to be ready; an unresolved send must be reviewed first.") }
        guard !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !s.attachments.isEmpty else { return reject("The submission is empty.") }
        guard ModelCatalog.models.contains(where: { $0.id == s.settings.modelID }) else { return reject("Choose an available model before sending.") }
        let model = s.settings.model
        guard model.efforts.isEmpty || model.efforts.contains(s.settings.effort) else { return reject("The selected reasoning effort is not advertised by this model.") }
        guard model.availableSpeeds.contains(s.settings.speed) else { return reject("The selected speed is not advertised by this model.") }
        guard !s.settings.daybreak || model.cyberPrograms?.contains("daybreakBlue") == true else { return reject("Daybreak is not advertised for this model and account.") }
        if s.action == .steer {
            guard c.running, let active = c.activeTurnID, active == s.waitingForTurnID else { return reject("The captured turn is no longer active. Refresh before steering.") }
        }
        if s.action == .send && c.running { return reject("This chat already has an active turn. Choose Steer or Queue explicitly.") }
        let queued = message(s)
        if s.action == .queue && c.running {
            guard let turn = c.activeTurnID, turn == s.waitingForTurnID else { return reject("The queued message must name its preceding active turn.") }
            let previousDraft = c.draft, previousFiles = c.attachments
            c.queued.append(queued)
            if c.draft == s.text { c.draft = "" }
            let ids = Set(s.attachments.map(\.id)); c.attachments.removeAll { ids.contains($0.id) }
            do { try presentation.save() } catch {
                c.queued.removeAll { $0.id == queued.id }; c.draft = previousDraft; c.attachments = previousFiles
                return reject("The queue could not be saved: " + error.localizedDescription)
            }
            store.changed(c)
            complete(s.id, result: .accepted, acceptance: .durableLocalQueue)
            return true
        }
        // Save the immutable write intent BEFORE any backend mutation. Never automatically resend it.
        presentation.setOutbound(s, in: c)
        do { try presentation.save() } catch {
            presentation.clearOutbound(s.id, in: c); return reject("The send intent could not be saved: " + error.localizedDescription)
        }
        dispatch(queued, in: c, followUp: s.action == .steer ? .steer : .queue)
        return true // admission only; completion carries the backend result
    }
    @discardableResult func send(_ c: Conversation, text: String, followUp: FollowUp = .steer) -> Bool {
        let action: CoreSubmissionAction = c.running ? (followUp == .queue ? .queue : .steer) : .send
        return submit(.init(identity: c.id, action: action, text: text, attachments: c.attachments, settings: c.next, access: c.access, waitingForTurnID: c.activeTurnID), in: c) { _ in }
    }

    private func dispatch(_ message: QueuedMessage, in c: Conversation, followUp: FollowUp, fromQueue: Bool = false) {
        if fromQueue { queuedDispatches.insert(message.id) }
        if fromQueue, let uuid = UUID(uuidString: message.id) {
            let s = CoreSubmission(id: uuid, identity: c.id, action: .queue, text: message.text, attachments: message.attachments, settings: message.settings, access: message.access, waitingForTurnID: message.waitingForTurnID)
            presentation.setOutbound(s, in: c)
            do { try presentation.save() } catch {
                presentation.clearOutbound(uuid, in: c)
                if let i = c.queued.firstIndex(where: { $0.id == message.id }) { c.queued[i].deliveryError = "The queued send intent could not be saved: " + error.localizedDescription }
                queuedDispatches.remove(message.id); store.changed(c); return
            }
        }
        c.sending = true; c.operationError = nil
        outbound[message.id] = (c.id, message)
        persistDraft(c)
        let operationID = UUID(uuidString: message.id) ?? UUID()
        operations[operationID] = Task { [weak self] in
            guard let self else { return }
            defer { operations[operationID] = nil }
            do {
                guard ModelCatalog.models.contains(where: { $0.id == message.settings.modelID }) else { throw failure("Choose an available model before sending.") }
                let model = message.settings.model
                guard model.efforts.isEmpty || model.efforts.contains(message.settings.effort) else { throw failure("The queued reasoning effort is no longer advertised by this model.") }
                let tier: String?
                switch message.settings.speed {
                case .standard: tier = nil
                case .fast: tier = model.serviceTiers.first(where: { $0 == "fast" || $0 == "priority" })
                case .ultrafast: tier = model.serviceTiers.first(where: { $0 == "ultrafast" })
                }
                guard message.settings.speed == .standard || tier != nil else { throw failure("The selected speed is not advertised by this model. Select an available speed.") }
                guard !message.settings.daybreak || model.cyberPrograms?.contains("daybreakBlue") == true else { throw failure("Daybreak is not advertised for this model and account.") }
                let attachments = try message.attachments.map { try presentation.resolveAttachment($0) }
                guard !attachments.contains(where: { $0.input == nil && $0.url == nil }) else { throw failure("An attachment could not be restored. Remove it and attach the file again before sending.") }
                let thread = try await ensureThread(c, settings: message.settings, access: message.access)
                var input: [JSONValue] = []
                if !message.text.isEmpty { input.append(["type": "text", "text": .string(message.text)]) }
                for attachment in attachments {
                    if let ready = attachment.input { input.append(ready); continue }
                    guard let url = attachment.url else { throw failure("The attachment has no readable file: \(attachment.name)") }
                    let dataBase64 = try await Task.detached {
                        try Data(contentsOf: url).base64EncodedString()
                    }.value
                    var body: [String: JSONValue] = ["name": .string(attachment.name), "dataBase64": .string(dataBase64), "threadId": .string(thread)]
                    if let mime = attachment.mimeType { body["mimeType"] = .string(mime) }
                    let uploaded = try await client.request("POST", path: "/attachments", body: .object(body))
                    guard let part = uploaded["input"] else { throw failure("Core returned no input for \(attachment.name).") }
                    input.append(part)
                    if fromQueue, let q = c.queued.firstIndex(where: { $0.id == message.id }),
                       let i = c.queued[q].attachments.firstIndex(where: { $0.id == attachment.id }) { c.queued[q].attachments[i].input = part }
                    else if !fromQueue, let i = c.attachments.firstIndex(where: { $0.id == attachment.id }) { c.attachments[i].input = part }
                }
                var params: [String: JSONValue] = ["threadId": .string(thread), "input": .array(input), "clientUserMessageId": .string(message.id)]
                let steering = followUp == .steer && !fromQueue
                if steering { steeringMessages.insert(message.id) }
                if steering {
                    guard c.running, let active = c.activeTurnID, active == message.waitingForTurnID else { throw failure("The captured turn is no longer active. Refresh before steering.") }
                    params["expectedTurnId"] = .string(active)
                } else {
                    params["model"] = .string(model.wireModel ?? message.settings.modelID)
                    params["serviceTierForTurn"] = .string(tier ?? "default")
                    if message.settings.daybreak { params["cyberAccessProgram"] = "daybreakBlue" }
                    if message.settings.model.efforts.contains(message.settings.effort) { params["effort"] = .string(message.settings.effort.rawValue) }
                    params["approvalPolicy"] = .string(message.access == .full ? "never" : "on-request")
                    params["sandboxPolicy"] = sandbox(message.access, cwd: c.cwd)
                }
                // A write is attempted exactly once. Transport ambiguity blocks further sends until explicit refresh.
                let result: JSONValue
                do { result = try await client.rpc(steering ? "turn/steer" : "turn/start", params: params) }
                catch { if isAmbiguous(error) && !acknowledged.contains(message.id) { c.sendOutcomeUnknown = true }; throw error }
                if acknowledged.remove(message.id) != nil { return } // SSE settled this write; a later HTTP result cannot overwrite a newer submission.
                let responseTurnID = result["turn"]?["id"]?.stringValue ?? result["turnId"]?.stringValue
                guard responseTurnID != nil else {
                    c.sendOutcomeUnknown = true
                    throw failure("Core did not return the accepted turn ID. Refresh history before sending again.")
                }
                if steering, responseTurnID != message.waitingForTurnID {
                    c.sendOutcomeUnknown = true; throw failure("Core returned a different turn for the captured steer request. Review history.")
                }
                if let id = responseTurnID {
                    advanceEligibleQueue(in: c, to: id)
                    let status = result["turn"]?["status"]?.stringValue
                    if let status, ["completed", "interrupted", "failed"].contains(status) { recordQueueOutcome(turn: id, status: status, in: c, stopped: requestedStops.contains(id)) }
                    c.activeTurnID = (status == nil || status == "inProgress") && !completedTurns.contains(id) && terminalStatuses[id] == nil ? id : nil
                    c.running = c.activeTurnID != nil
                }
                if !steering { c.settings = message.settings }
                if fromQueue { c.queued.removeAll { $0.id == message.id } }
                else {
                    if c.draft == message.text { c.draft = "" }
                    let ids = Set(message.attachments.map(\.id)); c.attachments.removeAll { ids.contains($0.id) }
                }
                queuedDispatches.remove(message.id)
                if let id = UUID(uuidString: message.id) { presentation.clearOutbound(id, in: c); presentation.recordAccepted(id) }
                c.sending = false; c.error = nil; c.updated = Date()
                outbound[message.id] = nil; acknowledged.remove(message.id); steeringMessages.remove(message.id)
                persistDraft(c)
                if let id = UUID(uuidString: message.id) { complete(id, result: .accepted, acceptance: .backend) }
                if !c.running { deliverQueued(c) }
            } catch {
                if acknowledged.remove(message.id) != nil { return } // An actual receipt already owns the result, including composer reentrancy.
                c.sending = false
                let result: CoreSubmissionResult = c.sendOutcomeUnknown ? .outcomeUnknown(error.localizedDescription) : .failed(error.localizedDescription)
                if let id = UUID(uuidString: message.id), !c.sendOutcomeUnknown { presentation.clearOutbound(id, in: c) }
                if !c.sendOutcomeUnknown { outbound[message.id] = nil; steeringMessages.remove(message.id); queuedDispatches.remove(message.id) }
                if fromQueue {
                    if let index = c.queued.firstIndex(where: { $0.id == message.id }) { c.queued[index].deliveryError = error.localizedDescription }
                    else { var retained = message; retained.deliveryError = error.localizedDescription; c.queued.insert(retained, at: 0) }
                } else {
                    if c.draft.isEmpty { c.draft = message.text }
                    for a in message.attachments where !c.attachments.contains(where: { $0.id == a.id }) { c.attachments.append(a) }
                }
                report(error, in: c); persistDraft(c)
                if let id = UUID(uuidString: message.id) { complete(id, result: result) }
            }
        }
    }

    private func sandbox(_ access: Access, cwd: String?) -> JSONValue {
        switch access {
        case .readOnly: return ["type": "readOnly"]
        case .full: return ["type": "dangerFullAccess"]
        case .auto: return ["type": "workspaceWrite", "writableRoots": .array(cwd.map { [.string($0)] } ?? []), "networkAccess": false, "excludeTmpdirEnvVar": false, "excludeSlashTmp": false]
        }
    }

    private func flushOrphans() {
        guard pendingCreations == 0 else { return }
        let pending = orphanEvents; orphanEvents = []
        for event in pending {
            if let tid = event.params["threadId"]?.stringValue ?? event.params["thread"]?["id"]?.stringValue { apply(event, to: conversation(threadID: tid)) }
        }
    }

    private func ensureThread(_ c: Conversation, settings: ModelSettings, access: Access) async throws -> String {
        if let tid = c.backendThreadID {
            if resumeNeeded.contains(tid) { _ = try await client.rpc("thread/resume", params: ["threadId": .string(tid)]); resumeNeeded.remove(tid); knownLoadedThreads.insert(tid) }
            return tid
        }
        var params: [String: JSONValue] = ["model": .string(settings.model.wireModel ?? settings.modelID), "approvalPolicy": .string(access == .full ? "never" : "on-request"), "sandbox": .string(access == .full ? "danger-full-access" : access == .readOnly ? "read-only" : "workspace-write")]
        if let cwd = c.cwd { params["cwd"] = .string(cwd) }
        pendingCreations += 1
        defer {
            pendingCreations -= 1
            flushOrphans()
        }
        let result: JSONValue
        do { result = try await client.rpc("thread/start", params: params) }
        catch { if isAmbiguous(error) { c.sendOutcomeUnknown = true }; throw error }
        guard let tid = result["thread"]?["id"]?.stringValue else { c.sendOutcomeUnknown = true; throw failure("Core did not return the created thread ID. Check history before retrying.") }
        knownLoadedThreads.insert(tid)
        c.backendThreadID = tid; c.cwd = result["thread"]?["cwd"]?.stringValue ?? c.cwd
        c.historyLoaded = true
        return tid
    }

    func createUnsentConversation(title: String, projectID: String?, deviceID: String = "mac") -> Conversation {
        let c = Conversation(id: UUID().uuidString, identityIndex: store.nextIdentity(), title: title, projectID: projectID, deviceID: deviceID, updated: Date(), contextUsed: 0)
        c.branch = ""; c.isLiveConversation = true; c.cwd = store.project(projectID)?.path
        c.next = store.newChatSettings; c.settings = c.next
        return c // Local identity only. Host promotes/inserts it before exactly one submit.
    }
    func createConversation(title: String, projectID: String?, deviceID: String = "mac", firstMessage: String, attachments: [Attachment] = []) -> Conversation {
        let c = createUnsentConversation(title: title, projectID: projectID, deviceID: deviceID)
        c.draft = firstMessage; c.attachments = attachments; store.add(c); _ = send(c, text: firstMessage)
        return c
    }
    func stop(_ c: Conversation) { interrupt(c, id: UUID()) { _ in } }
    func interrupt(_ c: Conversation, id: UUID, completion: @escaping @MainActor (CoreSubmissionReceipt) -> Void) {
        if submissions[id] != nil { completion(.init(id: id, result: .failed("This UUID belongs to a message submission."))); return }
        if let r = receipts[id] { completion(r); return }
        if stoppingIDs[id] != nil { completions[id, default: []].append(completion); return }
        guard let tid = c.backendThreadID, let turn = c.activeTurnID, !c.stopping else {
            completion(.init(id: id, result: .failed("There is no interruptible active turn."))); return
        }
        stoppingIDs[id] = turn; completions[id] = [completion]
        c.stopping = true; requestedStops.insert(turn); store.changed(c)
        for i in c.queued.indices where c.queued[i].waitingForTurnID == turn && c.queued[i].deliveryError == nil {
            c.queued[i].deliveryError = "Stop was requested for the preceding turn. Restore this message to send it manually."
        }
        persistDraft(c)
        operations[id] = Task {
            defer { operations[id] = nil }
            do {
                _ = try await client.rpc("turn/interrupt", params: ["threadId": .string(tid), "turnId": .string(turn)])
                if receipts[id]?.result == .accepted { return }
                complete(id, result: .accepted, acceptance: .backend)
                // Keep stopping until Core reports turn/completed.
            } catch {
                if receipts[id]?.result == .accepted { return } // A terminal SSE/history receipt may precede this HTTP error.
                let ambiguous = isAmbiguous(error)
                if !ambiguous { c.stopping = false; requestedStops.remove(turn) }
                report(error, in: c)
                complete(id, result: ambiguous ? .outcomeUnknown(error.localizedDescription) : .failed(error.localizedDescription))
            }
        }
    }
    /// Only after the user has inspected refreshed history. This does not retry a write.
    func resolveUnknownAfterReview(_ c: Conversation) {
        guard !c.sending, !c.loading else { return }
        for (id, value) in outbound where value.0 == c.id {
            if let uuid = UUID(uuidString: id) { presentation.clearOutbound(uuid, in: c) }
            outbound[id] = nil
        }
        c.sendOutcomeUnknown = false; c.operationError = nil; persistDraft(c)
    }
    /// Explicitly bind an ambiguous creation to a thread selected by the user from real history.
    func adoptCreatedThread(_ threadID: String, for c: Conversation) throws {
        guard c.backendThreadID == nil, c.sendOutcomeUnknown, !threadID.isEmpty,
              store.backendConversation(threadID) == nil else { throw failure("Choose an unclaimed history thread for this unresolved creation.") }
        c.backendThreadID = threadID; resumeNeeded.insert(threadID); persistDraft(c)
    }

    func respond(_ approval: Approval, in c: Conversation, action: ApprovalAction) {
        guard let index = c.approvals.firstIndex(where: { $0.id == approval.id }), !c.approvals[index].submitting, !pendingResponses.contains(approval.id) else { return }
        let word = action == .accept ? "accept" : action == .decline ? "decline" : "cancel"
        var response: JSONValue
        if approval.method == "item/permissions/requestApproval" {
            response = ["permissions": action == .accept ? approval.request["params"]?["permissions"] ?? .object([:]) : .object([:]), "scope": "turn"]
        } else if approval.method == "elicitation/create" {
            // A schema with required fields needs a form, not an empty synthetic acceptance.
            let required = approval.request["params"]?["requestedSchema"]?["required"]?.arrayValue ?? []
            if action == .accept && !required.isEmpty { report(failure("This request needs additional form fields. Decline or cancel it; empty approval was not sent."), in: c); return }
            response = ["action": .string(word), "content": action == .accept ? .object([:]) : .null]
        } else if approval.method.contains("requestApproval") {
            if let choices = approval.request["params"]?["availableDecisions"]?.arrayValue, !choices.contains(.string(word)) {
                report(failure("This approval does not offer the selected decision."), in: c); return
            }
            response = ["decision": .string(word)]
        } else { report(failure("Unsupported approval response: \(approval.method). No response was sent."), in: c); return }
        if let error = CoreResponseValidation.approval(response, request: approval) { report(failure(error), in: c); return }
        pendingResponses.insert(approval.id)
        c.approvals[index].submitting = true; store.changed(c)
        Task {
            defer { pendingResponses.remove(approval.id) }
            do { _ = try await client.request("POST", path: "/approvals/\(CoreWire.segment(approval.id))", body: response); c.approvals.removeAll { $0.id == approval.id }; store.changed(c) }
            catch { if let i = c.approvals.firstIndex(where: { $0.id == approval.id }) { c.approvals[i].submitting = false }; report(error, in: c) }
        }
    }

    func respond(_ approval: Approval, in c: Conversation, response: JSONValue) {
        guard let index = c.approvals.firstIndex(where: { $0.id == approval.id }), !c.approvals[index].submitting, !pendingResponses.contains(approval.id) else { return }
        if let error = CoreResponseValidation.approval(response, request: approval) { report(failure(error), in: c); return }
        pendingResponses.insert(approval.id)
        c.approvals[index].submitting = true; store.changed(c)
        Task {
            defer { pendingResponses.remove(approval.id) }
            do { _ = try await client.request("POST", path: "/approvals/\(CoreWire.segment(approval.id))", body: response); c.approvals.removeAll { $0.id == approval.id }; store.changed(c) }
            catch { if let i = c.approvals.firstIndex(where: { $0.id == approval.id }) { c.approvals[i].submitting = false }; report(error, in: c) }
        }
    }

    /// Re-fetch discovery pages and backend metadata without discarding drafts or retrying writes.
    func reload() async throws {
        historyCursors = [:]; historyExhausted = []
        try await load()
    }

    func refresh(_ c: Conversation) {
        guard c.backendThreadID != nil else { report(failure("This creation has an unknown outcome. Inspect the history before creating another chat."), in: c); return }
        Task {
            do {
                let health = try await checkedHealth()
                _ = noteServer(health)
                capabilities = try await client.request(path: "/capabilities")
                try await read(c)
                isConnected = true; store.setOnline("mac", true); connectionStatus = "Connected to Organic Core"
                // Absence of a receipt is not proof of failure; read() reconciles any actual clientId receipt.
                if !c.sendOutcomeUnknown { c.operationError = nil }
                // read() used a newer health watermark; do not overwrite its pending approvals with this earlier health.
                store.changed(c)
            } catch { report(error, in: c) }
        }
    }

    func answer(_ request: UserInputRequest, in c: Conversation, answers: [String: [String]]) {
        guard c.userInput?.id == request.id, c.userInput?.submitting != true, !pendingResponses.contains(request.id) else { return }
        if let error = CoreResponseValidation.answers(answers, request: request) { report(failure(error), in: c); return }
        pendingResponses.insert(request.id)
        c.userInput?.submitting = true; store.changed(c)
        let values = answers.mapValues { JSONValue.object(["answers": .array($0.map(JSONValue.string))]) }
        Task {
            defer { pendingResponses.remove(request.id) }
            do { _ = try await client.request("POST", path: "/approvals/\(CoreWire.segment(request.id))", body: ["answers": .object(values)]); if c.userInput?.id == request.id { c.userInput = nil; c.question = nil }; store.changed(c) }
            catch { if c.userInput?.id == request.id { c.userInput?.submitting = false }; report(error, in: c) }
        }
    }

    func markSeen(_ c: Conversation) {
        c.completions = 0; c.unread = false; store.changed(c)
        if !c.historyLoaded { Task { do { try await read(c) } catch { report(error, in: c) } } }
    }
    func rename(_ c: Conversation, title: String) {
        guard let tid = c.backendThreadID else { c.title = title; persistDraft(c); return }
        let before = c.title; c.title = title; store.changed(c)
        Task { do { _ = try await client.rpc("thread/name/set", params: ["threadId": .string(tid), "name": .string(title)]) }
            catch { if c.title == title { c.title = before }; report(error, in: c) } }
    }
    func setArchived(_ c: Conversation, archived: Bool) {
        let before = c.archived; c.archived = archived; c.archivedAt = archived ? Date() : nil; persistDraft(c)
        guard let tid = c.backendThreadID else { return }
        Task { do { _ = try await client.rpc(archived ? "thread/archive" : "thread/unarchive", params: ["threadId": .string(tid)]) }
            catch { if c.archived == archived { c.archived = before; c.archivedAt = nil }; report(error, in: c) } }
    }
    func setPinned(_ c: Conversation, pinned: Bool) {
        c.pinned = pinned
        persistDraft(c)
    }
    func attach(_ c: Conversation) {
        if let onAttachmentRequested { onAttachmentRequested(c) }
        else { report(failure("Attach files through the window's native file picker."), in: c) }
    }
    func removeAttachment(_ a: Attachment, from c: Conversation) { c.attachments.removeAll { $0.id == a.id }; persistDraft(c) }
    func fork(_ c: Conversation, at itemID: String) -> Conversation? {
        guard let tid = c.backendThreadID, let index = c.items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let fork = Conversation(id: UUID().uuidString, identityIndex: store.nextIdentity(), title: "Fork of \(c.title)", projectID: c.projectID, deviceID: c.deviceID, updated: Date(), contextUsed: c.contextUsed)
        fork.branch = ""; fork.isLiveConversation = true
        fork.cwd = c.cwd; fork.settings = c.settings; fork.next = c.next; fork.draft = c.items[index].text; fork.loading = true
        store.add(fork)
        pendingCreations += 1
        Task {
            defer { pendingCreations -= 1; flushOrphans(); persistDraft(fork) }
            do {
                let result = try await client.rpc("thread/fork", params: ["threadId": .string(tid), "beforeTurnId": .string(c.items[index].turnID), "deferGoalContinuation": true])
                guard let thread = result["thread"], let id = thread["id"]?.stringValue else { throw failure("Core did not return the forked thread.") }
                fork.backendThreadID = id
                EventReducer.hydrate(thread, into: fork)
                resumeNeeded.insert(id); fork.loading = false
            } catch { fork.loading = false; fork.sendOutcomeUnknown = true; report(error, in: fork) }
        }
        return fork
    }
    func compactNow(_ c: Conversation) {
        guard let tid = c.backendThreadID else { return }
        Task { do { _ = try await client.rpc("thread/compact/start", params: ["threadId": .string(tid)]) } catch { report(error, in: c) } }
    }
    func refreshChanges(_ c: Conversation) async {
        guard let cwd = c.cwd, !c.gitBusy else { return }
        c.gitBusy = true; store.changed(c)
        defer { c.gitBusy = false; store.changed(c) }
        do {
            let status = try await client.request("POST", path: "/workspace/git/status", body: ["cwd": .string(cwd)])
            let files = status["files"]?.arrayValue ?? []
            let paths = Array(Set(files.flatMap { [$0["path"]?.stringValue, $0["originalPath"]?.stringValue].compactMap { $0 } })).sorted()
            c.gitRoot = status["root"]?.stringValue; c.branch = status["branch"]?.stringValue ?? "Detached HEAD"
            guard !paths.isEmpty else { c.changes = []; c.gitPaths = []; c.gitDiffHash = nil; c.gitError = nil; return }
            let body: JSONValue = ["cwd": .string(cwd), "paths": .array(paths.map(JSONValue.string))]
            let diff = try await client.request("POST", path: "/workspace/git/diff", body: body)
            let staged = try await client.request("POST", path: "/workspace/git/diff", body: ["cwd": .string(cwd), "paths": .array(paths.map(JSONValue.string)), "staged": true])
            guard diff["diffHash"] == staged["diffHash"] else { throw failure("Files changed while loading the diff. Refresh before committing.") }
            let text = (staged["diff"]?.stringValue ?? "") + (diff["diff"]?.stringValue ?? "")
            c.changes = Self.parseGitDiff(text, paths: files.compactMap { $0["path"]?.stringValue })
            c.gitPaths = paths; c.gitDiffHash = diff["diffHash"]?.stringValue
            c.gitError = diff["truncated"]?.boolValue == true || staged["truncated"]?.boolValue == true ? "The diff is truncated. Review the complete files before committing." : nil
        } catch { c.gitError = error.localizedDescription; c.gitDiffHash = nil; c.gitRoot = nil; c.branch = "" }
    }

    static func parseGitDiff(_ text: String, paths: [String]) -> [FileChange] {
        var current: String?
        var lines: [String: [FileChange.Line]] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                current = paths.first { line.hasSuffix(" b/" + $0) || line.hasSuffix(" b/" + $0 + "\"") }
            }
            guard let path = current else { continue }
            let kind: FileChange.Line.Kind = line.hasPrefix("+") && !line.hasPrefix("+++") ? .added : line.hasPrefix("-") && !line.hasPrefix("---") ? .removed : .context
            lines[path, default: []].append(.init(kind: kind, text: line))
        }
        return paths.map { path in
            let value = lines[path] ?? []
            return .init(path: path, added: value.filter { $0.kind == .added }.count, removed: value.filter { $0.kind == .removed }.count, lines: value)
        }
    }

    func commit(_ c: Conversation, message: String) {
        guard let cwd = c.cwd, let hash = c.gitDiffHash, !c.gitBusy, c.gitError == nil, !c.gitPaths.isEmpty else { report(failure("Refresh and review the complete Changes diff before committing."), in: c); return }
        let paths = c.gitPaths; c.gitBusy = true
        Task {
            do {
                let result = try await client.request("POST", path: "/workspace/git/commit", body: ["cwd": .string(cwd), "paths": .array(paths.map(JSONValue.string)), "message": .string(message), "expectedDiffHash": .string(hash)])
                if let hash = result["commit"]?.stringValue { c.lastCommit = Commit(message: message, hash: hash, at: Date()) }
            } catch { report(error, in: c) }
            c.gitBusy = false
            await refreshChanges(c)
        }
    }

    func revert(_ card: TranscriptItem, in c: Conversation) {
        guard let onRevertRequested else { report(failure("Review and confirmation must be supplied by the window before reverting files."), in: c); return }
        onRevertRequested(card, c)
    }
    /// The window's confirmed revert (OrganicApplication's flow, the dialog moved to the host): the card's files plus their
    /// rename sources, the complete staged and working-tree diffs under one hash, the host's confirmation over exactly
    /// those, then POST revert with that hash. Anything changed or truncated in between reverts nothing.
    func revertReviewed(_ card: TranscriptItem, in c: Conversation,
                        confirm: @escaping @MainActor (_ paths: [String], _ staged: String, _ worktree: String) async -> Bool) {
        guard let cwd = c.cwd, !c.gitBusy else { return }
        let requested = card.text.split(separator: "\n").compactMap { line -> String? in
            guard let marker = line.range(of: "  +") ?? line.range(of: "  −") else { return nil }
            return String(line[..<marker.lowerBound])
        }
        guard !requested.isEmpty else { report(failure("This card does not identify the files to revert."), in: c); return }
        c.gitBusy = true; store.changed(c)
        Task {
            do {
                let status = try await client.request("POST", path: "/workspace/git/status", body: ["cwd": .string(cwd)])
                // The App Server names a changed file by its absolute path; Core's git routes take paths inside the
                // repository (the product sends the absolute ones and Core refuses them, 10-29 Live check).
                let root = status["root"]?.stringValue ?? cwd
                let inside = requested.map { Self.repositoryRelative($0, root: root) }
                guard !inside.contains(nil) else { throw failure("A changed file is outside this repository. No files were reverted.") }
                let relative = inside.compactMap { $0 }
                let records = status["files"]?.arrayValue ?? []
                let originals = records.filter { relative.contains($0["path"]?.stringValue ?? "") }.compactMap { $0["originalPath"]?.stringValue }
                let paths = Array(Set(relative + originals)).sorted()
                let diff = try await client.request("POST", path: "/workspace/git/diff", body: ["cwd": .string(cwd), "paths": .array(paths.map(JSONValue.string))])
                let staged = try await client.request("POST", path: "/workspace/git/diff", body: ["cwd": .string(cwd), "paths": .array(paths.map(JSONValue.string)), "staged": true])
                guard let hash = diff["diffHash"]?.stringValue, hash == staged["diffHash"]?.stringValue,
                      diff["truncated"]?.boolValue != true, staged["truncated"]?.boolValue != true else {
                    throw failure("The complete diff changed or could not be loaded. No files were reverted.")
                }
                if await confirm(paths, staged["diff"]?.stringValue ?? "", diff["diff"]?.stringValue ?? "") {
                    _ = try await client.request("POST", path: "/workspace/git/revert", body: ["cwd": .string(cwd), "paths": .array(paths.map(JSONValue.string)), "expectedDiffHash": .string(hash)])
                    if let i = c.items.firstIndex(where: { $0.id == card.id }) { c.items[i].status = TranscriptPresentation.changesReverted; c.items[i].revision += 1 }
                }
            } catch { report(error, in: c) }
            c.gitBusy = false; store.changed(c)
            await refreshChanges(c)
        }
    }
    /// `path` inside the repository at `root`, both with symlinks resolved (/tmp is /private/tmp); nil when outside.
    static func repositoryRelative(_ path: String, root: String) -> String? {
        guard path.hasPrefix("/") else { return path }
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
        let file = resolved(path), base = resolved(root)
        guard file.hasPrefix(base + "/") else { return nil }
        return String(file.dropFirst(base.count + 1))
    }
    func toggleDictation(_ c: Conversation) { report(failure("Use macOS Dictation in the text editor; Organic voice input is not connected."), in: c) }
    func startVoice(_ c: Conversation) { report(failure("Audio capture is not connected in this shell."), in: c) }
    func endVoice(_ c: Conversation) { c.voice = nil; store.changed(c) }
    func sendVoice(_ c: Conversation) { if let text = c.voice { _ = send(c, text: text) } }

    private func recordQueueOutcome(turn: String, status: String, in c: Conversation, stopped: Bool) {
        if status == "interrupted" {
            for (id, target) in stoppingIDs where target == turn { complete(id, result: .accepted, acceptance: .backend) }
        }
        if ["completed", "interrupted", "failed"].contains(status) { terminalStatuses[turn] = status }
        if status == "completed" && !stopped { normallyCompletedQueueTurns.insert(turn) }
        else if stopped || status == "interrupted" || status == "failed" {
            normallyCompletedQueueTurns.remove(turn)
            for i in c.queued.indices where c.queued[i].waitingForTurnID == turn && c.queued[i].deliveryError == nil {
                c.queued[i].deliveryError = "The preceding turn was stopped or failed. Restore this message to send it manually."
            }
        }
    }
    private func advanceEligibleQueue(in c: Conversation, to active: String) {
        for i in c.queued.indices where c.queued[i].deliveryError == nil {
            if let waiting = c.queued[i].waitingForTurnID, waiting != active, normallyCompletedQueueTurns.contains(waiting) {
                c.queued[i].waitingForTurnID = active
            }
        }
    }
    private func deliverQueued(_ c: Conversation) {
        guard isConnected, !c.running, !c.sending, !c.sendOutcomeUnknown, let next = c.queued.first,
              next.deliveryError == nil, let waiting = next.waitingForTurnID,
              normallyCompletedQueueTurns.contains(waiting) else { return }
        dispatch(next, in: c, followUp: .steer, fromQueue: true)
    }
    func canRestoreQueuedToDraft(_ message: QueuedMessage, in c: Conversation) -> Bool {
        c.draft.isEmpty && c.attachments.isEmpty && !c.sending && !c.loading && !c.sendOutcomeUnknown &&
        c.queued.contains { $0.id == message.id && ($0.deliveryError != nil || $0.waitingForTurnID == nil) }
    }
    func restoreQueuedToDraft(_ message: QueuedMessage, in c: Conversation) {
        guard canRestoreQueuedToDraft(message, in: c), let saved = c.queued.first(where: { $0.id == message.id }) else { return }
        c.draft = saved.text; c.attachments = saved.attachments; c.next = saved.settings; c.access = saved.access
        c.queued.removeAll { $0.id == saved.id }
        // Recovering a failed front entry is an explicit manual handoff. Do not skip it
        // by automatically releasing later entries against an older completed turn.
        for i in c.queued.indices where c.queued[i].deliveryError == nil {
            c.queued[i].deliveryError = "An earlier queued message was restored. Restore this message when the composer is empty."
        }
        c.operationError = nil
        persistDraft(c)
    }
    private func persistDraft(_ c: Conversation) {
        store.changed(c)
        do { try presentation.save() } catch { lastError = error.localizedDescription }
    }
    private func isAmbiguous(_ error: Error) -> Bool { CoreWire.isAmbiguous(error) }
    private func failure(_ message: String) -> CoreError { CoreError(code: nil, message: message, data: nil, httpStatus: nil) }
    private func report(_ error: Error, in c: Conversation) {
        c.operationError = error.localizedDescription + (c.sendOutcomeUnknown ? " The send outcome is unknown; check history before sending again." : "")
        c.error = c.running ? .running : .stopped
        c.redEvents += 1; onRedEvent(c)
        c.items.append(TranscriptItem(id: "local-error-" + UUID().uuidString, turnID: c.activeTurnID ?? "", kind: .notice(.error), text: c.operationError!))
        store.changed(c)
    }
}
