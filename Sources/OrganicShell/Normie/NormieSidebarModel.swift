import Foundation

enum NormieSidebarRow: Equatable {
    case group(String), project(String), conversation(String, project: String?), more(String)
    var key: String {
        switch self {
        case .group(let s): "group:"+s
        case .project(let s): "project:"+s
        case .conversation(let s, _): "chat:"+s
        case .more(let s): "more:"+s
        }
    }
    var conversationID: String? { if case .conversation(let id, _) = self { id } else { nil } }
}

enum NormieSidebarKey: Equatable { case up, down, home, end, left, right, activate, escape, archive }

/// Independent port of SidebarView's grouping/reveal rules. UI never owns a second conversation copy.
@MainActor final class NormieSidebarModel {
    let store: ConversationStore
    private(set) var query = ""
    private(set) var current: String?
    private(set) var focusedRowKey: String?
    private(set) var rows: [NormieSidebarRow] = []
    private(set) var groupOpen = ["Pinned": true, "Projects": true, "Recents": false]
    private(set) var projectOpen: [String: Bool] = [:]
    private(set) var limits: [String: Int] = [:]
    private(set) var renaming: String?
    var renameText = ""
    private struct ArchiveRecord { var id: String; weak var original: Conversation?; var selection: String?; var archivedAt: Date? }
    private var archiveUndo: [ArchiveRecord] = []
    /// Backend operations are injected; defaults mutate the existing mock models.
    var onPin: ((Conversation, Bool) -> Void)?
    var onArchive: ((Conversation, Bool) -> Void)?
    var onRename: ((Conversation, String) -> Void)?
    var onSelection: ((String?) -> Void)?
    var onChange: (() -> Void)?
    static let historyPageKey = "__core_history__"
    var hasMoreHistory: (() -> Bool)?
    var onLoadMoreHistory: ((@escaping @MainActor (Result<Void, Error>) -> Void) -> Void)?
    private(set) var historyLoading = false
    private(set) var historyError: String?
    private var historyRequest: UUID?
    var hasHistoryPage: Bool { historyLoading || historyError != nil || hasMoreHistory?() == true }
    var onArchiveNotice: ((String, String) -> Void)?
    var canLeaveSelection: () -> Bool = { true }
    var canUndoArchive: Bool {
        archiveUndo.contains { record in
            guard let c = store.conversation(record.id) else { return false }
            return c === record.original && c.archived
        }
    }

    init(store: ConversationStore, current: String? = nil) {
        self.store = store; self.current = current
        if let current { reveal(current) }; rebuild()
    }
    var live: [Conversation] { store.conversations.filter { !$0.archived } }
    private func sorted(_ values: [Conversation]) -> [Conversation] {
        values.sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
    }
    func chats(in project: Project) -> [Conversation] {
        sorted(live.filter { store.project($0.projectID)?.id == project.id && !$0.pinned })
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }
    func limit(_ key: String) -> Int { limits[key] ?? 5 }
    func isOpen(_ project: Project) -> Bool {
        !query.isEmpty || (projectOpen[project.id] ?? (project.pinned || chats(in: project).contains { Self.hasStatus($0) }))
    }
    func isGroupOpen(_ key: String) -> Bool { !query.isEmpty || groupOpen[key] == true }

    func rebuild() {
        var result: [NormieSidebarRow] = []
        let projects = store.projects.filter { query.isEmpty || matches($0.name) || chats(in: $0).contains { matches($0.title) } }
        let pinned = sorted(live.filter { $0.pinned && matches($0.title) })
        func appendChats(_ values: [Conversation], key: String, project: String?) {
            let visible = query.isEmpty ? Array(values.prefix(limit(key))) : values
            result += visible.map { .conversation($0.id, project: project) }
            if query.isEmpty && values.count > visible.count { result.append(.more(key)) }
        }
        func appendProject(_ p: Project) {
            result.append(.project(p.id))
            if isOpen(p) {
                let values = chats(in: p).filter { matches(p.name) || matches($0.title) }
                appendChats(values, key: p.id, project: p.id)
            }
        }
        let pinnedProjects = projects.filter(\.pinned)
        if !pinnedProjects.isEmpty || !pinned.isEmpty {
            result.append(.group("Pinned"))
            if isGroupOpen("Pinned") {
                pinnedProjects.forEach(appendProject)
                appendChats(pinned, key: "pinned", project: nil)
            }
        }
        let other = projects.filter { !$0.pinned }
        if !other.isEmpty {
            result.append(.group("Projects"))
            if isGroupOpen("Projects") { other.forEach(appendProject) }
        }
        let recent = sorted(live.filter { !$0.pinned && store.project($0.projectID) == nil && matches($0.title) })
        if !recent.isEmpty || query.isEmpty {
            result.append(.group("Recents"))
            if isGroupOpen("Recents") { appendChats(recent, key: "recents", project: nil) }
        }
        // Global cursor: it can yield any project/pinned group, including when every loaded group has <5 rows.
        if hasHistoryPage { result.append(.more(Self.historyPageKey)) }
        rows = result
        if let focusedRowKey, !rows.contains(where: { $0.key == focusedRowKey }) { self.focusedRowKey = nil }
    }
    func refresh() { rebuild(); onChange?() }
    func search(_ value: String) { query = value.trimmingCharacters(in: .whitespacesAndNewlines); refresh() }
    func toggleGroup(_ key: String) { groupOpen[key] = !(groupOpen[key] ?? true); refresh() }
    func toggleProject(_ id: String) {
        guard let p = store.project(id) else { return }; projectOpen[id] = !isOpen(p); refresh()
    }
    func showMore(_ key: String) {
        if key == Self.historyPageKey { requestHistoryPage(); return }
        let oldMore = rows.firstIndex(of: .more(key))
        let wasFocused = focusedRowKey == NormieSidebarRow.more(key).key
        limits[key] = limit(key)+20; rebuild()
        if wasFocused, let oldMore, rows.indices.contains(oldMore) { focusedRowKey = rows[oldMore].key }
        onChange?()
    }
    @discardableResult func requestHistoryPage() -> Bool {
        guard !historyLoading, hasMoreHistory?() == true || historyError != nil, let load = onLoadMoreHistory else { return false }
        let request = UUID(); historyRequest = request; historyLoading = true; historyError = nil; refresh()
        load { [weak self] result in
            guard let self, self.historyRequest == request else { return }
            self.historyRequest = nil; self.historyLoading = false
            if case .failure(let error) = result { self.historyError = error.localizedDescription }
            self.refresh()
        }
        return true
    }
    /// Closing/replacing the host retires UI callbacks; it does not cancel or invent a Core page acknowledgement.
    func cancelHistoryPaging() { historyRequest = nil; historyLoading = false; historyError = nil }
    func historyTitle() -> String {
        historyLoading ? "Loading conversations…" : historyError != nil ? "Retry loading conversations" : "Show More Conversations"
    }
    func focus(_ row: NormieSidebarRow) {
        if let id = row.conversationID { select(id) }
        else { focusedRowKey = row.key; refresh() }
    }
    func activate(_ row: NormieSidebarRow) {
        switch row {
        case .group(let id): toggleGroup(id)
        case .project(let id): toggleProject(id)
        case .more(let id): showMore(id)
        case .conversation(let id, _): select(id)
        }
    }
    func reveal(_ id: String) {
        guard let c = store.conversation(id), !c.archived else { return }
        let values: [Conversation], key: String
        if c.pinned {
            groupOpen["Pinned"] = true; key = "pinned"; values = sorted(live.filter(\.pinned))
        } else if let p = store.project(c.projectID) {
            groupOpen[p.pinned ? "Pinned" : "Projects"] = true; projectOpen[p.id] = true
            key = p.id; values = chats(in: p)
        } else {
            groupOpen["Recents"] = true; key = "recents"
            values = sorted(live.filter { !$0.pinned && store.project($0.projectID) == nil })
        }
        if let index = values.firstIndex(where: { $0.id == c.id }), index >= limit(key) { limits[key] = index+1 }
    }
    func select(_ id: String?) {
        guard id == current || canLeaveSelection() else { return }
        if let id, store.conversation(id)?.archived != false { return }
        if renaming != nil { finishRename() }
        current = id; focusedRowKey = id.map { NormieSidebarRow.conversation($0, project: nil).key }
        if let id { reveal(id) }; refresh(); onSelection?(id)
    }
    func keyboard(_ key: NormieSidebarKey) {
        let ids = rows.compactMap(\.conversationID)
        switch key {
        case .up, .down:
            guard !rows.isEmpty else { return }
            let index = focusedRowKey.flatMap { key in rows.firstIndex { $0.key == key } }
                ?? current.flatMap { id in rows.firstIndex { $0.conversationID == id } }
            let next = key == .up ? max(0, (index ?? rows.count)-1) : min(rows.count-1, (index ?? -1)+1)
            focus(rows[next])
        case .home, .end:
            guard !ids.isEmpty else { return }
            let i = current.flatMap { ids.firstIndex(of: $0) }
            let next: Int
            switch key {
            case .home: next = 0
            case .end: next = ids.count-1
            default: next = i ?? 0
            }
            select(ids[next])
        case .left, .right:
            let focused = focusedRowKey.flatMap { key in rows.first { $0.key == key } }
            if case .group(let group)? = focused {
                groupOpen[group] = key == .right; refresh()
            } else if case .project(let id)? = focused {
                projectOpen[id] = key == .right; refresh()
            } else if let c = current.flatMap(store.conversation), let p = store.project(c.projectID), !c.pinned {
                projectOpen[p.id] = key == .right
                if key == .left { focusedRowKey = NormieSidebarRow.project(p.id).key }
                refresh()
            }
        case .escape: if renaming != nil { cancelRename() } else { search("") }
        case .archive: if let current { archive(current) }
        case .activate:
            if let focused = focusedRowKey.flatMap({ key in rows.first { $0.key == key } }) { activate(focused) }
            else if let current { select(current) }
        }
    }
    func pin(_ id: String) {
        guard let c = store.conversation(id), !c.archived else { return }
        let value = !c.pinned
        if let onPin { onPin(c, value) } else { c.pinned = value; store.changed(c) }
        if let current { reveal(current) }; refresh()
    }
    func pinProject(_ id: String) { store.togglePin(project: id); if let current { reveal(current) }; refresh() }
    func archive(_ id: String, at now: Date = .now) {
        guard let c = store.conversation(id), !c.archived else { return }
        guard current != id || canLeaveSelection() else { return }
        archiveUndo.append(ArchiveRecord(id: id, original: c, selection: current, archivedAt: c.archivedAt))
        if let onArchive { onArchive(c, true) } else { c.archived = true; c.archivedAt = now; store.changed(c) }
        guard c.archived else { archiveUndo.removeLast(); refresh(); return }
        if current == id { current = sorted(live.filter { $0.id != id }).first?.id; onSelection?(current) }
        if let current { reveal(current) }; refresh(); onArchiveNotice?(c.id, c.title)
    }
    /// Deleted models are skipped rather than resurrected from a retained object (b030).
    @discardableResult func undoArchive() -> Bool {
        while let record = archiveUndo.popLast() {
            guard let c = store.conversation(record.id), c === record.original, c.archived else { continue }
            if let onArchive { onArchive(c, false) } else { c.archived = false; c.archivedAt = record.archivedAt; store.changed(c) }
            guard !c.archived else { archiveUndo.append(record); return false }
            let target = record.selection.flatMap { store.conversation($0)?.archived == false ? $0 : nil }
            current = target ?? c.id
            if let current { reveal(current) }; refresh(); onSelection?(current); return true
        }
        return false
    }
    /// Call when Core permanently deletes IDs, including a backend tombstone before history removes the model.
    func invalidateUndo(for ids: Set<String>) { archiveUndo.removeAll { ids.contains($0.id) } }
    func beginRename(_ id: String) {
        guard canLeaveSelection(), let c = store.conversation(id), !c.archived else { return }
        renaming = id; renameText = c.title; reveal(id); refresh()
    }
    func finishRename() {
        guard let id = renaming else { return }; renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, let c = store.conversation(id), !c.archived {
            if let onRename { onRename(c, name) } else { c.title = name; store.changed(c) }
        }
        refresh()
    }
    func cancelRename() { renaming = nil; renameText = ""; refresh() }
    static func hasStatus(_ c: Conversation) -> Bool { c.error != nil || c.needsYou || c.running || c.unread }
    static func status(_ c: Conversation, now: Date = .now) -> String {
        if let e = c.error { return e == .stopped ? "Error, stopped" : "Error, still running" }
        if !c.approvals.isEmpty { return "Approval requested" }
        if c.question != nil || c.userInput != nil { return "Question" }
        if c.running { return "Running" }
        if c.unread { return "New reply" }
        return shortAge(c.updated, now: now)
    }
    static func shortAge(_ date: Date, now: Date = .now) -> String {
        let m = Int(now.timeIntervalSince(date)/60)
        switch m { case ..<1: return "now"; case ..<60: return "\(m)m"; case ..<1440: return "\(m/60)h"; case ..<10080: return "\(m/1440)d"; default: return "\(m/10080)w" }
    }
}
