import Foundation

/// Explicit window layout input. An adapter must describe base roles, never Tide's temporary appearance.
struct OrganicMemberLayout: Codable, Equatable {
    enum Mode: String, Codable { case auto, focused }
    enum Bank: String, Codable { case left, right, parked }
    enum Draft: String, Codable { case none, empty, retained, unavailable }
    struct IdentityPreference: Codable, Equatable {
        // M11.44 consumes these through ConversationIdentity.resolved(index:symbol:tint:).
        // This is a preference snapshot, not an allocator or an occupancy table.
        var identityIndex: Int
        var symbol: String?
        var tint: String?
    }
    struct Member: Codable, Equatable {
        var id: String
        var title: String
        var archived = false
        var draft: Draft = .none
        var draftToken: String?
        var identity: IdentityPreference? = nil
    }
    struct Column: Codable, Equatable {
        var id: String
        var lineage: UInt64
        var member: String
        var weight: Double
    }
    struct Vacancy: Codable, Equatable {
        var id: String
        var lineage: UInt64
        // Position certificates consume no capacity and render no empty column.
    }
    var windowID: UUID
    var endpointScope: String
    var mode: Mode = .auto
    var members: [Member]
    var columns: [Column]
    var left: [String] = []
    var right: [String] = []
    var parked: [String] = []
    var vacancies: [Vacancy] = []
    var current: String
    var selectionRevision: UInt64 = 0
    var revision: UInt64 = 0

    subscript(bank: Bank) -> [String] {
        get { switch bank { case .left: left; case .right: right; case .parked: parked } }
        set { switch bank { case .left: left = newValue; case .right: right = newValue; case .parked: parked = newValue } }
    }
    var ordinaryBank: Bank { .right }
    var orderedIDs: [String] { columns.map(\.member) + parked + left + right }
    var isValid: Bool {
        let ids = members.map(\.id), places = orderedIDs
        return !columns.isEmpty && Set(ids).count == ids.count && Set(places).count == places.count
            && Set(ids) == Set(places) && columns.contains { $0.member == current }
            && Set(columns.map(\.id)).count == columns.count
            && columns.reduce(0, { $0 + $1.weight }).isFinite
            && columns.allSatisfy { $0.weight.isFinite && $0.weight > 0 }
    }
    mutating func normalize() {
        let total = columns.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return }
        for i in columns.indices { columns[i].weight /= total }
    }
}
