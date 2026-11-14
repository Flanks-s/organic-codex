import Foundation

/// Arrival order is shared by the hover backlog and side cards waiting for material warmup.
struct SunHoverTideBacklog {
    struct Key: Hashable { let owner: String; let notice: Int }
    struct Entry { let owner: String; let notice: ConversationNotice; let order: Int }
    private(set) var isDeferring = false
    private(set) var entries: [Entry] = []
    private var keys: Set<Key> = [], sideOrder: [Key: Int] = [:], serial = 0
    var isEmpty: Bool { entries.isEmpty }
    mutating func recordSide(_ notices: [ConversationNotice], owner: String) {
        for notice in notices {
            let key = Key(owner: owner, notice: notice.id)
            if sideOrder[key] == nil { serial += 1; sideOrder[key] = serial }
        }
    }
    mutating func forgetSide(_ notices: [ConversationNotice], owner: String) {
        for notice in notices { sideOrder[Key(owner: owner, notice: notice.id)] = nil }
    }
    mutating func discardSide() { sideOrder = [:] }
    mutating func begin(sideQueued: [String: [ConversationNotice]]) {
        isDeferring = true
        for (owner, notices) in sideQueued {
            for notice in notices {
                let key = Key(owner: owner, notice: notice.id)
                if keys.insert(key).inserted {
                    serial += 1
                    entries.append(.init(owner: owner, notice: notice, order: sideOrder[key] ?? serial))
                }
            }
        }
        sideOrder = [:]; entries.sort { $0.order < $1.order }
    }
    mutating func append(_ notices: [ConversationNotice], owner: String) {
        for notice in notices where keys.insert(Key(owner: owner, notice: notice.id)).inserted {
            serial += 1; entries.append(.init(owner: owner, notice: notice, order: serial))
        }
    }
    mutating func end() { isDeferring = false }
    mutating func drain() -> [Entry] { let result = entries; entries = []; keys = []; return result }
}
