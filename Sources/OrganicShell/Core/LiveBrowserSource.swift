import Foundation

/// One App-owned, event-driven view of Core's independent Chromium. No poller or private SSE stream.
@MainActor final class LiveBrowserSource: BrowserSessionDriver {
    struct Capture: Sendable {
        let generation: UInt64
        let tab: BrowserLiveTab
        let image: Data
        let uploaded: JSONValue
        let metadata: JSONValue
    }
    let store = BrowserSessionStore()
    private let client: any CoreTransport
    private let clock: any CoreRuntimeClock
    private let timestamp: @MainActor () -> Double
    private var debounce: Task<Void, Never>?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private var requestRevision: UInt64 = 0
    private var eventSerial: UInt64 = 0
    private var lastCoreEvent = -1
    private var runtimePID: Int?
    private var hasSnapshot = false
    private var connectionHydrated = false
    private var preferredSelection: String?
    private var inputRevision: UInt64 = 0
    private var operationIssue: String?
    private var captures = 0
    private var runtimeConnection = false
    private(set) var connected = false
    private(set) var disposed = false
    private(set) var forcedOff = false
    private(set) var requestsStarted = 0
    private(set) var listRequestsStarted = 0
    private(set) var droppedReceipts = 0
    private(set) var acceptedSnapshots = 0
    var homeRotationEnabled = true
    var reduceMotion = false
    var onChange: ((BrowserSessionState, Bool) -> Void)?
    var onWillDisconnect: (() -> Void)?
    var enabled: Bool { store.state.enabled }
    var isLive: Bool { true }
    var time: Double { timestamp() }
    var activeTimerCount: Int { debounce == nil ? 0 : 1 }
    var pendingTaskCount: Int { jobs.count + activeTimerCount + captures }

    init(client: any CoreTransport, clock: any CoreRuntimeClock = CoreSystemClock(),
         now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.client = client; self.clock = clock; self.timestamp = now
    }

    /// Repeated runtime state callbacks do not manufacture a reconnect after core/closed.
    func connectionChanged(_ online: Bool) {
        guard !disposed, runtimeConnection != online else { return }
        runtimeConnection = online
        if online {
            connected = true; connectionHydrated = false; beginGeneration(); triggerRefresh()
        } else { disconnect() }
    }

    /// Tools and the Earth controls share the existing bounded refresh window.
    func noteShellMutation() {
        guard connected, !disposed else { return }
        triggerRefresh()
    }

    /// The normal conversation-event path takes only this method switch and returns.
    func receive(_ event: CoreEvent) {
        guard !disposed else { return }
        switch event.method {
        case "core/backendDisconnected", "backendDisconnected", "core/closed":
            disconnect()
        case "browser/runtimeStarted":
            guard connected, event.id > lastCoreEvent else { return }
            lastCoreEvent = event.id
            let pid = event.params["pid"]?.intValue
            if runtimePID != pid || hasSnapshot { beginGeneration(); runtimePID = pid }
            triggerRefresh()
        case "browser/result":
            guard connected, event.params["backend"]?.stringValue == "independent-chromium",
                  event.id > lastCoreEvent else { return }
            lastCoreEvent = event.id; triggerRefresh()
        default: return
        }
    }

    private func beginGeneration() {
        if hasSnapshot || enabled { onWillDisconnect?() }
        generation &+= 1; requestRevision &+= 1; hasSnapshot = false; preferredSelection = nil
        operationIssue = nil
        debounce?.cancel(); debounce = nil
        for task in jobs.values { task.cancel() }
        emit(.liveDisconnected)
    }

    private func disconnect() {
        guard connected || hasSnapshot || enabled || debounce != nil else { return }
        // Restore leases and first responders before the shared empty state removes any presentation.
        connected = false; runtimePID = nil; lastCoreEvent = -1
        beginGeneration()
    }

    /// A single bounded 100 ms window, opened only by one of the four authorized triggers.
    private func triggerRefresh() {
        guard connected, !disposed else { return }
        requestRevision &+= 1
        guard debounce == nil else { return }
        let epoch = generation, clock = self.clock
        debounce = Task { @MainActor [weak self] in
            do { try await clock.sleep(seconds: 0.1) } catch { return }
            guard let self, !self.disposed, self.connected, self.generation == epoch else { return }
            self.debounce = nil; self.fetchTabs(epoch: epoch, revision: self.requestRevision)
        }
    }

    private func fetchTabs(epoch: UInt64, revision: UInt64) {
        let id = UUID(); listRequestsStarted += 1; requestsStarted += 1
        jobs[id] = Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.jobs[id] = nil }
            do {
                let result = try await self.client.request(path: "/browser/tabs")
                guard !Task.isCancelled, self.connected, !self.disposed,
                      self.generation == epoch, self.requestRevision == revision else {
                    self.droppedReceipts += 1; return
                }
                try self.accept(result, revision: revision)
            } catch {
                guard !Task.isCancelled, self.generation == epoch, self.requestRevision == revision else { return }
                self.emit(.issue(error.localizedDescription))
            }
        }
    }

    private func accept(_ result: JSONValue, revision: UInt64) throws {
        guard result["backend"]?.stringValue == "independent-chromium",
              let values = result["tabs"]?.arrayValue else { throw CoreWire.failure("Invalid Codex background browser tabs response.") }
        let before = store.state, old = Dictionary(uniqueKeysWithValues: before.liveTabs.map { ($0.id,$0) })
        var ids = Set<String>()
        let tabs: [BrowserLiveTab] = try values.map { value in
            guard let id = value["tabId"]?.stringValue, !id.isEmpty, ids.insert(id).inserted,
                  let url = value["url"]?.stringValue, let title = value["title"]?.stringValue else {
                throw CoreWire.failure("Invalid Codex background browser tab metadata.")
            }
            let previous = old[id]
            let changed = previous?.url != url || previous?.title != title
            return BrowserLiveTab(id: id, url: url, title: title,
                revision: changed ? (previous?.revision ?? 0) + 1 : previous!.revision)
        }
        let selected = [preferredSelection,before.selectedTabID].compactMap { $0 }.first { id in tabs.contains { $0.id == id } } ?? tabs.first?.id
        let hydrate = !connectionHydrated
        connectionHydrated = true
        preferredSelection = nil; hasSnapshot = true; acceptedSnapshots += 1
        emit(.liveSnapshot(tabs: tabs, selected: selected, hydrate: hydrate, suppressed: forcedOff), hydrate: hydrate)
        if let operationIssue { emit(.issue(operationIssue)) }
        guard !hydrate, let selected, let current = tabs.first(where: { $0.id == selected }),
              BrowserSessionState.isLoopback(current.url) else { return }
        let prior = old[selected]
        if prior == nil || (prior?.url != current.url && prior.map { !BrowserSessionState.isLoopback($0.url) } == true) {
            emit(.homeArrived(rotationRequested: homeRotationEnabled && !reduceMotion), tab: current)
        }
    }

    func setForcedOff(_ value: Bool) {
        guard forcedOff != value, !disposed else { return }; forcedOff = value
        if value { onWillDisconnect?() }
        emit(.liveSnapshot(tabs: store.state.liveTabs, selected: store.state.selectedTabID, hydrate: true, suppressed: value), hydrate: true)
    }

    func interact(_ input: BrowserMockInput) {
        guard connected, !disposed, case .action(let action) = input else { return }
        switch action {
        case .selectTab(let id):
            inputRevision &+= 1; preferredSelection = nil; emit(.selectedTab(id))
        case .newTab: mutate(path: "/browser/open", body: ["url":"about:blank"])
        case .closeTab(let id):
            guard store.state.liveTabs.contains(where: { $0.id == id }) else { return }
            mutate(path: "/browser/close", body: ["tabId":.string(id)])
        default: return
        }
    }

    private func mutate(path: String, body: JSONValue) {
        inputRevision &+= 1
        let intent = inputRevision
        operationIssue = nil
        let id = UUID(), epoch = generation; requestsStarted += 1
        jobs[id] = Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.jobs[id] = nil }
            do {
                let result = try await self.client.request("POST", path: path, body: body)
                guard !Task.isCancelled, self.connected, self.generation == epoch else { return }
                if path == "/browser/open", self.inputRevision == intent { self.preferredSelection = result["tabId"]?.stringValue }
            } catch {
                guard !Task.isCancelled, self.generation == epoch else { return }
                if self.inputRevision == intent {
                    self.operationIssue = error.localizedDescription
                    self.emit(.issue(error.localizedDescription))
                }
            }
            // An explicit rejection also receives one authoritative reconciliation; no optimistic tab was inserted.
            guard self.connected, self.generation == epoch, !self.disposed else { return }
            self.triggerRefresh()
        }
    }

    func capture(threadID: String?) async throws -> Capture {
        guard connected, !disposed, let tab = store.state.selectedLiveTab else { throw CoreWire.failure("No browser tab is selected.") }
        captures += 1; defer { captures -= 1 }
        let epoch = generation
        requestsStarted += 1
        let shot = try await client.request("POST", path: "/browser/screenshot", body: ["tabId":.string(tab.id)])
        try checkCapture(epoch: epoch, tab: tab)
        guard let encoded = shot["data"]?.stringValue, let image = Data(base64Encoded: encoded), !image.isEmpty,
              shot["tabId"]?.stringValue == tab.id else { throw CoreWire.failure("Invalid browser screenshot response.") }
        var body: [String:JSONValue] = ["name":"Browser screenshot.png", "mimeType":shot["mimeType"] ?? "image/png", "dataBase64":.string(encoded)]
        if let threadID { body["threadId"] = .string(threadID) }
        requestsStarted += 1
        let uploaded = try await client.request("POST", path: "/attachments", body: .object(body))
        try checkCapture(epoch: epoch, tab: tab)
        return Capture(generation: epoch, tab: tab, image: image, uploaded: uploaded, metadata: shot["metadata"] ?? .null)
    }

    private func checkCapture(epoch: UInt64, tab: BrowserLiveTab) throws {
        guard !Task.isCancelled, connected, !disposed, generation == epoch, store.state.selectedLiveTab == tab else {
            throw CoreWire.failure("The browser page changed before its screenshot arrived.")
        }
    }

    func isCurrent(_ capture: Capture) -> Bool {
        connected && !disposed && generation == capture.generation && store.state.selectedLiveTab == capture.tab
    }

    func reportIssue(_ message: String?) { emit(.issue(message)) }
    func observeInputs(_ callback: @escaping (BrowserMockInput, Double) -> Void) -> UUID { UUID() }
    func removeInputObserver(_ id: UUID) {}

    private func emit(_ payload: BrowserEventPayload, tab: BrowserLiveTab? = nil, hydrate: Bool = false) {
        eventSerial &+= 1
        let event = BrowserSessionEvent(metadata: .init(source: .live, backend: .ownedChromium,
            sessionGeneration: generation, tabID: tab?.id ?? store.state.selectedTabID,
            navigationRevision: tab?.revision, eventID: eventSerial, time: time), payload: payload)
        if store.apply(event) == .accepted { onChange?(store.state, hydrate) }
    }

    func dispose() {
        guard !disposed else { return }; disconnect(); disposed = true
        debounce?.cancel(); debounce = nil; for task in jobs.values { task.cancel() }
        onChange = nil; onWillDisconnect = nil
    }
    func drain() async { while !jobs.isEmpty { for task in Array(jobs.values) { await task.value } } }
}
