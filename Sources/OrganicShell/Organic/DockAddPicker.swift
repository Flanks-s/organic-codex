import Foundation

/// Model only. History loading uses the runtime's exact sidebar page API, never board fixtures.
@MainActor final class DockAddPicker {
    struct Candidate: Equatable { let id: String; let title: String; let updated: Date }
    enum Row: Equatable { case newConversation, conversation(Candidate), loadFailure }
    enum Choice: Equatable { case newConversation, conversation(String), retry }
    private let store: ConversationStore
    private let loadPage: () async throws -> Void
    private let morePages: () -> Bool
    var memberIDs: Set<String> = []
    var otherWindowIDs: Set<String> = []
    var inFlightIDs: Set<String> = []
    private(set) var query = ""
    private(set) var rows: [Row] = [.newConversation]
    private(set) var focus = 0
    private(set) var loading = false
    private(set) var failed = false
    private var generation: UInt64 = 0
    private var pageTask: Task<Bool, Never>?
    private var wheelAccumulation = 0.0, lastNotch = -Double.infinity, lastWheel = -Double.infinity
    var errorTitle: String? { failed ? "Can't load conversations" : nil }
    var retryTitle: String { "Retry" }
    var noMatches: Bool { !loading && !failed && !hasMore && !rows.contains { if case .conversation = $0 { true } else { false } } }
    var hasMore: Bool { morePages() }

    init(store: ConversationStore, loadPage: @escaping () async throws -> Void, hasMore: @escaping () -> Bool) {
        self.store = store; self.loadPage = loadPage; self.morePages = hasMore
        reload(); focus = min(1, rows.count - 1)
    }
    convenience init(runtime: LiveConversationRuntime) {
        self.init(store: runtime.store, loadPage: { try await runtime.loadMoreHistory() }, hasMore: { runtime.hasMoreHistory() })
    }
    func reload() {
        let selected = rows.indices.contains(focus) ? rows[focus] : nil
        let excluded = memberIDs.union(otherWindowIDs).union(inFlightIDs)
        let history: [Conversation] = store.conversations
        let filtered: [Conversation] = history.filter { c in
            guard !c.archived, !excluded.contains(c.id), !c.id.isEmpty else { return false }
            return query.isEmpty || c.title.lowercased().contains(query)
        }
        let values: [Conversation] = filtered.sorted { left, right in
            if left.updated == right.updated { return left.id < right.id }
            return left.updated > right.updated
        }
        let conversationRows: [Row] = values.map { c in
            Row.conversation(Candidate(id: c.id, title: c.title, updated: c.updated))
        }
        rows = [.newConversation] + conversationRows
        if failed { rows.append(.loadFailure) }
        if let selected, let index = rows.firstIndex(where: { Self.sameIdentity($0, selected) }) { focus = index }
        else { focus = min(rows.count - 1, max(0, focus)) }
    }
    func search(_ value: String) async {
        generation &+= 1
        query = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); reload(); focus = min(1, rows.count - 1)
        // Core thread/list has no verified server-search contract. Continue through all unloaded history.
        if !query.isEmpty { await loadRemainingSearch() }
    }
    private func loadRemainingSearch() async {
        let epoch = generation
        while epoch == generation, !query.isEmpty, morePages(), !failed {
            let loaded = await nextPage()
            if !loaded { break }
            await Task.yield()
        }
    }
    @discardableResult func nextPage() async -> Bool {
        if let pageTask { return await pageTask.value }
        guard morePages() else { reload(); return false }
        loading = true
        let task = Task { [self] in
            do { try await loadPage(); failed = false; return true }
            catch { failed = true; return false }
        }
        pageTask = task
        let result = await task.value
        pageTask = nil; loading = false; reload()
        return result
    }
    func retry() async { failed = false; _ = await nextPage(); if !query.isEmpty { await loadRemainingSearch() } }
    func moveFocus(_ step: Int) { focus = min(rows.count - 1, max(0, focus + step)) }
    /// Revalidate IDs against the live store and ownership at the instant of selection.
    func chooseFocused(hasMarkedText: Bool = false) -> Choice? {
        guard !hasMarkedText, rows.indices.contains(focus) else { return nil }
        switch rows[focus] {
        case .newConversation: return .newConversation
        case .loadFailure: return .retry
        case .conversation(let row):
            guard let c = store.conversation(row.id), c.id == row.id, !c.archived,
                  !memberIDs.contains(c.id), !otherWindowIDs.contains(c.id), !inFlightIDs.contains(c.id) else { reload(); return nil }
            return .conversation(c.id)
        }
    }
    /// The same step/debounce/idle reset as OverlayModelPicker.wheel; no copied board `acc` field.
    func wheel(deltaY: Double, precise: Bool, at time: Double) {
        let delta = -deltaY * (precise ? 1 : 40)
        guard delta != 0 else { return }
        if time - lastWheel >= 1.1 { wheelAccumulation = 0 }
        lastWheel = time
        var step = 0
        if abs(delta) >= 40 { step = delta > 0 ? 1 : -1; wheelAccumulation = 0 }
        else {
            if (wheelAccumulation > 0) != (delta > 0) { wheelAccumulation = 0 }
            wheelAccumulation += delta
            if abs(wheelAccumulation) >= 60 { step = wheelAccumulation > 0 ? 1 : -1; wheelAccumulation = 0 }
        }
        if step != 0, time - lastNotch > 0.045 { lastNotch = time; moveFocus(step) }
    }
    func retire() { generation &+= 1 }
    private static func sameIdentity(_ a: Row, _ b: Row) -> Bool {
        switch (a, b) {
        case (.newConversation, .newConversation), (.loadFailure, .loadFailure): true
        case (.conversation(let a), .conversation(let b)): a.id == b.id
        default: false
        }
    }
}

/// The window owns one instance and shares it between Cmd+N, the satellite and picker in B.
@MainActor final class DockAddDraftIdentity {
    private(set) var conversation: Conversation?
    func obtain(runtime: any ConversationRuntime, current: Conversation?, existing: Conversation? = nil) -> Conversation {
        func unsent(_ c: Conversation) -> Bool { c.backendThreadID == nil && !c.sending && !c.items.contains { $0.rowKind == .user } }
        if let existing, unsent(existing) { conversation = existing; return existing }
        if let conversation, unsent(conversation) { return conversation }
        let c = runtime.createUnsentConversation(title: "New Chat", projectID: current?.projectID, deviceID: current?.deviceID ?? "mac")
        c.cwd = current?.cwd ?? c.cwd; c.next = current?.next ?? runtime.store.newChatSettings; c.settings = c.next
        conversation = c; return c
    }
    func discardEmpty() {
        if let c = conversation, c.backendThreadID == nil, c.draft.isEmpty, c.attachments.isEmpty { conversation = nil }
    }
}
