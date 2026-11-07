import Foundation

/// Conservative invalidation hints. They describe a committed model mutation, never a request to mutate it.
/// Unknown, multi-row, history and local edit operations use structural. Legacy observers remain unchanged.
enum ConversationChange: Equatable, Sendable {
    case itemAppended(itemID: String)
    case itemChanged(itemID: String)
    case structural
    var itemID: String? {
        switch self { case .itemAppended(let id), .itemChanged(let id): id; case .structural: nil }
    }
}

@MainActor final class ConversationStore {
    private(set) var conversations: [Conversation] = []
    private(set) var projects: [Project] = []
    private(set) var devices: [Device] = []
    var usesLiveCore = false
    private var localProjectPaths = false
    private var projectAliases: [String: String] = [:]
    /// Numeric values drive the liquid; availability is separate so an unknown limit is never "0% used".
    var quotaFiveHourReported = true
    var quotaWeekReported = true
    var quotaFiveHourResetsAt: Date?
    var quotaWeekResetsAt: Date?
    var quotaFiveHourWindowMinutes: Int? = 300
    var quotaWeekWindowMinutes: Int? = 10_080
    var quotaBothReported: Bool { quotaFiveHourReported && quotaWeekReported }
    var quotaAnyReported: Bool { quotaFiveHourReported || quotaWeekReported }
    var quotaMenuSummary: String {
        guard quotaAnyReported else { return "Usage not reported" }
        let remaining = Int(((1 - min(1, max(0, quotaTightest))) * 100).rounded())
        return quotaBothReported ? "\(remaining)% left" : "\(remaining)% left in reported limit"
    }
    /// Usage limits used, 0…1. me's liquid shows the tighter reported limit (spec §10.5).
    var quotaFiveHour = 0.34 { didSet { showQuota() } }
    var quotaWeek = 0.58 { didSet { showQuota() } }
    var quotaTightest: Double { max(quotaFiveHourReported ? quotaFiveHour : 0, quotaWeekReported ? quotaWeek : 0) }
    /// The limits in whole percents, for what shows them (me's liquid shows the tighter one): the mock spends a little
    /// of them on every tick, and views reading the exact values were drawn again on every one.
    private(set) var quotaShown = 0.58
    private(set) var quotaFiveHourShown = 0.34
    private(set) var quotaWeekShown = 0.58
    private func showQuota() {
        func shown(_ v: Double) -> Double { Double(Conversation.percent(v)) / 100 }
        if shown(quotaTightest) != quotaShown { quotaShown = shown(quotaTightest) }
        if shown(quotaFiveHour) != quotaFiveHourShown { quotaFiveHourShown = shown(quotaFiveHour) }
        if shown(quotaWeek) != quotaWeekShown { quotaWeekShown = shown(quotaWeek) }
    }
    func clearCoreQuota() {
        quotaFiveHourReported = false; quotaWeekReported = false
        quotaFiveHourResetsAt = nil; quotaWeekResetsAt = nil
        quotaFiveHourWindowMinutes = nil; quotaWeekWindowMinutes = nil
        quotaFiveHour = 0; quotaWeek = 0
    }
    func applyCoreRateLimits(_ response: JSONValue) {
        let legacy = response["rateLimits"] ?? response
        let buckets = response["rateLimitsByLimitId"]?.objectValue
        let limitID = legacy["limitId"]?.stringValue
        let matching = limitID.flatMap { buckets?[$0] }
        let snapshot = buckets?["codex"] ?? matching ?? legacy
        let primary = snapshot["primary"]
        let secondary = snapshot["secondary"]
        quotaFiveHourReported = primary?["usedPercent"]?.doubleValue != nil
        quotaWeekReported = secondary?["usedPercent"]?.doubleValue != nil
        quotaFiveHourResetsAt = primary?["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        quotaWeekResetsAt = secondary?["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        quotaFiveHourWindowMinutes = primary?["windowDurationMins"]?.intValue
        quotaWeekWindowMinutes = secondary?["windowDurationMins"]?.intValue
        quotaFiveHour = min(1, max(0, (primary?["usedPercent"]?.doubleValue ?? 0) / 100))
        quotaWeek = min(1, max(0, (secondary?["usedPercent"]?.doubleValue ?? 0) / 100))
    }
    /// Model settings for a New Chat before it exists.
    var newChatSettings = ModelSettings()
    /// While Codex is working, a sent message steers the reply by default (user decision 2026-10-24; the
    /// prototype's Settings default was Queue). Long-press Send picks the other one per message.
    var followUpDefault: FollowUp = .steer

    init(conversations: [Conversation] = [], projects: [Project] = [], devices: [Device] = []) {
        self.conversations = conversations; self.projects = projects; self.devices = devices
    }

    func project(_ id: String?) -> Project? {
        guard let id else { return nil }
        let resolved = projectAliases[id] ?? id
        return projects.first { $0.id == resolved }
    }
    func device(_ id: String) -> Device? { devices.first { $0.id == id } }
    /// The chat's device is offline: its transcript is the last loaded copy, and sending is off until it reconnects.
    func isOffline(_ c: Conversation) -> Bool { !(device(c.deviceID)?.online ?? true) }
    func togglePin(project id: String) {
        let resolved = projectAliases[id] ?? id
        guard let i = projects.firstIndex(where: { $0.id == resolved }) else { return }
        projects[i].pinned.toggle()
    }

    @discardableResult func addProject(_ incoming: Project) -> Project {
        var project = incoming
        if let path = project.path { project.path = canonicalProjectPath(path) }
        let existing = projects.firstIndex {
            $0.id == project.id || (localProjectPaths && $0.deviceID == project.deviceID && project.path != nil && $0.path == project.path)
        }
        if let i = existing {
            // History discovery must not reset the user's pin, display name or color.
            projects[i].pinned = projects[i].pinned || project.pinned
            if projects[i].path == nil { projects[i].path = project.path }
            if projects[i].colorHex == nil { projects[i].colorHex = project.colorHex }
            projectAliases[project.id] = projects[i].id
            return projects[i]
        }
        projects.append(project)
        return project
    }
    func canonicalProjectPath(_ path: String) -> String {
        guard localProjectPaths else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    /// Only bootstrap's verified machine identity permits resolving backend paths on this Mac.
    func normalizeProjects(isLocalBackend: Bool) {
        localProjectPaths = isLocalBackend
        guard isLocalBackend else { return }
        let previous = projects
        projects = []
        for project in previous { addProject(project) }
        for c in conversations {
            if let cwd = c.cwd { c.cwd = canonicalProjectPath(cwd) }
            if let id = c.projectID { c.projectID = project(id)?.id ?? id }
        }
    }
    func updateProjects(_ values: [Project]) { projects = values; normalizeProjects(isLocalBackend: localProjectPaths) }
    static let devicesDidChange=Notification.Name("Organic.ConversationStore.DevicesDidChange")
    func updateDevices(_ values: [Device]) {
        guard devices != values else {return};devices=values
        NotificationCenter.default.post(name:Self.devicesDidChange,object:self)
    }
    func backendConversation(_ id: String) -> Conversation? { conversations.first { $0.backendThreadID == id } }
    func nextIdentity() -> Int {
        let used=Set(conversations.map { ConversationIdentity.resolved(index:$0.identityIndex,symbol:$0.identitySymbol,tint:$0.identityTint) })
        for index in 0..<ConversationIdentity.combinationCount where !used.contains(ConversationIdentity.assigned(index)) { return index }
        // The product's 13×13 palette repeats after 169. Stay finite when it is entirely occupied.
        return max(ConversationIdentity.combinationCount,(conversations.map(\.identityIndex).max() ?? -1)+1)
    }

    func setOnline(_ id: String, _ online: Bool) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        guard devices[i].online != online else {return}
        devices[i].online = online
        NotificationCenter.default.post(name:Self.devicesDidChange,object:self)
    }

    var onChange: ((Conversation) -> Void)?
    private var changeObservers: [UUID: (Conversation, ConversationChange) -> Void] = [:]
    private var observers: [UUID: (Conversation) -> Void] = [:]
    /// Owner-lifetime diagnostics without exposing callbacks or conversation data.
    var observationCount: Int { observers.count + changeObservers.count }

    /// A conversation joined the store after launch (a background arrival, f036); windows decide where it goes.
    var onAdd: ((Conversation) -> Void)?
    func add(_ c: Conversation) {
        guard conversation(c.id) == nil else { return }
        conversations.append(c)
        onAdd?(c)
    }
    func conversation(_ id: String) -> Conversation? { conversations.first { $0.id == id || $0.backendThreadID == id } }

    /// Local library removal, after the host has confirmed deletion. Canonical IDs only; no backend I/O or Undo.
    /// Remove the entire batch before publishing, so every observer sees the same final library.
    @discardableResult func remove(ids:Set<String>) throws -> [Conversation] {
        let available=Set(conversations.map(\.id))
        guard ids.isSubset(of:available) else {throw CoreWire.failure("A conversation selected for deletion is no longer in this library.")}
        let removed=conversations.filter{ids.contains($0.id)}
        for c in removed{c.archived=true;if c.archivedAt == nil{c.archivedAt=Date()}}
        conversations.removeAll{ids.contains($0.id)}
        for c in removed{publish(c)}
        return removed
    }

    @discardableResult func observe(_ change: @escaping (Conversation) -> Void) -> UUID {
        let id = UUID(); observers[id] = change; return id
    }
    /// Typed observers run before legacy UI observers, so snapshot consumers see the refreshed transcript.
    @discardableResult func observeChanges(_ change: @escaping (Conversation, ConversationChange) -> Void) -> UUID {
        let id = UUID(); changeObservers[id] = change; return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil; changeObservers[id] = nil }
    func changed(_ c: Conversation, change: ConversationChange = .structural) {
        c.notices.reconcile(in: c)
        // Retained windows, streaming tasks and old Undo callbacks cannot reintroduce a removed/replaced model.
        guard conversations.contains(where:{$0 === c}) else{return}
        publish(c, change: change)
    }
    private func publish(_ c:Conversation, change: ConversationChange = .structural) {
        c.revision += 1
        c.summaryIndex?.changed(c, change: change)
        let revision = c.revision
        for callback in Array(changeObservers.values) {
            // A nested publication may have superseded this hint. Never send a stale precise invalidation.
            callback(c, c.revision == revision ? change : .structural)
        }
        onChange?(c)
        for callback in Array(observers.values) { callback(c) }
    }
    func apply(_ e: CoreEvent) {
        let p = e.params
        if e.method == "account/rateLimits/updated" {
            applyCoreRateLimits(p)
            for c in conversations { changed(c) }
            return
        }
        guard let id = p["threadId"]?.stringValue ?? p["thread"]?["id"]?.stringValue,
              let c = conversation(id) else { return }
        let change = EventReducer.applyReportingChange(e, to: c)
        changed(c, change: change)
    }
}
