import Foundation

struct OrganicRemovalReceipt: Codable, Equatable {
    enum Source: String, Codable { case trash, contextMenu, accessibility }
    enum DraftEffect: String, Codable { case none, discardEmpty, retainSession }
    struct Position: Codable, Equatable {
        var column: OrganicMemberLayout.Column?
        var index: Int
        var bank: OrganicMemberLayout.Bank
        var dockIndex: Int
        var leftNeighbor: String?
        var rightNeighbor: String?
    }
    var id: UUID
    var windowID: UUID
    var endpointScope: String
    var sessionID: UUID
    var source: Source
    var member: OrganicMemberLayout.Member
    var mode: OrganicMemberLayout.Mode
    var position: Position
    var previousCurrent: String
    var successor: String
    var selectionRevision: UInt64
    var committedRevision: UInt64
    var draftEffect: DraftEffect
    struct WeightChange: Codable, Equatable { var before: Double; var after: Double }
    var survivorWeights: [String: WeightChange]
}

/// A current-capacity verdict from the shared SunHover/Add adapter, evaluated at Undo time.
/// Eligible briefs must already pass DockSlotLeases protection, contiguity and Add ownership checks.
struct OrganicUndoCapacity {
    struct BriefOffer {
        var members: [String]
        var dockLimitAfterRequisition: Int
    }
    var dockLimit: Int
    var admittedAddReservations: Int = 0
    var briefOffers: [BriefOffer] = []
    var maxColumns: Int
    var columnReturnAllowed = true
    var dockLimitAfterColumnReturn: Int? = nil
    var addProtectedMembers: Set<String> = []
    var tideToken: DockSlotLeases.Token? = nil
}

enum OrganicRemovePolicy {
    enum Rejection: String, Error { case lastColumn, missingMember, archived, unavailableDraft, invalidLayout, staleSession }
    struct Removal {
        var layout: OrganicMemberLayout
        var receipt: OrganicRemovalReceipt
    }
    struct Restoration {
        var layout: OrganicMemberLayout
        var identityPreference: OrganicMemberLayout.IdentityPreference?
        var requisitionedBriefs: [String]
        var revokeTide: DockSlotLeases.Token?
    }
    enum Availability: Equatable { case available, archived, missing, anotherWindow, draftSession(String) }
    enum Undo {
        case restored(Restoration)
        case alreadyPresent
        case full
        case unavailable
    }

    /// New Chat is local. Whitespace, attachments and uncommitted IME text all preserve its editor session.
    static func draftState(text: String, attachmentCount: Int, hasMarkedText: Bool, sessionAvailable: Bool) -> OrganicMemberLayout.Draft {
        guard sessionAvailable else { return .unavailable }
        return !text.isEmpty || attachmentCount > 0 || hasMarkedText ? .retained : .empty
    }

    static func eligibility(_ id: String, in layout: OrganicMemberLayout) -> Rejection? {
        guard layout.isValid else { return .invalidLayout }
        guard let member = layout.members.first(where: { $0.id == id }) else { return .missingMember }
        guard !member.archived else { return .archived }
        guard member.draft != .unavailable,
              member.draft == .none || member.draftToken != nil else { return .unavailableDraft }
        if layout.columns.contains(where: { $0.member == id }), layout.columns.count <= 1 { return .lastColumn }
        return nil
    }

    static func remove(_ id: String, from layout: OrganicMemberLayout, source: OrganicRemovalReceipt.Source,
                       sessionID: UUID, receiptID: UUID = UUID()) -> Result<Removal, Rejection> {
        if let rejection = eligibility(id, in: layout) { return .failure(rejection) }
        let member = layout.members.first { $0.id == id }!
        let columnIndex = layout.columns.firstIndex { $0.member == id }
        let bank = [OrganicMemberLayout.Bank.parked, .left, .right].first { layout[$0].contains(id) } ?? layout.ordinaryBank
        let index = columnIndex ?? layout[bank].firstIndex(of: id)!
        let neighbors = columnIndex == nil ? layout[bank] : layout.columns.map(\.member)
        let dockIndex = columnIndex == nil ? index : min(index, layout[layout.ordinaryBank].count)
        var next = layout
        let weightTotal = layout.columns.reduce(0) { $0 + $1.weight }
        if columnIndex != nil { next.normalize() }
        next.members.removeAll { $0.id == id }
        for b in [OrganicMemberLayout.Bank.left, .right, .parked] { next[b].removeAll { $0 == id } }
        if let i = columnIndex {
            let removed = next.columns[i]
            if layout.current == id && next.columns.count > 1 {
                let successorIndex = i + 1 < next.columns.count ? i + 1 : i - 1
                next.current = next.columns[successorIndex].member
                // The successor inherits the full column's width before survivors normalize.
                if layout.mode == .auto {
                    let weight = next.columns[successorIndex].weight
                    next.columns[successorIndex].weight = removed.weight
                    next.columns[i].weight = weight
                }
            }
            next.columns.remove(at: i)
            next.vacancies.removeAll { $0.id == removed.id }
            next.vacancies.append(.init(id: removed.id, lineage: removed.lineage))
            next.normalize()
        }
        next.revision &+= 1
        let effect: OrganicRemovalReceipt.DraftEffect = member.draft == .empty ? .discardEmpty : member.draft == .retained ? .retainSession : .none
        let receipt = OrganicRemovalReceipt(id: receiptID, windowID: layout.windowID, endpointScope: layout.endpointScope,
            sessionID: sessionID, source: source, member: member, mode: layout.mode,
            position: .init(column: columnIndex.map { i in
                var slot = layout.columns[i]; slot.weight /= weightTotal; return slot
            }, index: index, bank: bank, dockIndex: dockIndex,
                            leftNeighbor: index > 0 ? neighbors[index - 1] : nil,
                            rightNeighbor: index + 1 < neighbors.count ? neighbors[index + 1] : nil),
            previousCurrent: layout.current, successor: next.current, selectionRevision: layout.selectionRevision,
            committedRevision: next.revision, draftEffect: effect,
            survivorWeights: Dictionary(uniqueKeysWithValues: next.columns.map { slot in
                (slot.id, .init(before: layout.columns.first { $0.id == slot.id }!.weight / (columnIndex == nil ? 1 : weightTotal), after: slot.weight))
            }))
        return .success(.init(layout: next, receipt: receipt))
    }

    /// No receipt is consulted by Add. No Undo reservation is created by Remove.
    static func addHasRoom(in layout: OrganicMemberLayout, capacity: OrganicUndoCapacity) -> Bool {
        layout.left.count + layout.right.count + layout.parked.count + capacity.admittedAddReservations < capacity.dockLimit
    }

    static func undo(_ receipt: OrganicRemovalReceipt, in layout: OrganicMemberLayout,
                     availability: Availability, capacity: OrganicUndoCapacity) -> Undo {
        guard layout.isValid, receipt.windowID == layout.windowID, receipt.endpointScope == layout.endpointScope else { return .unavailable }
        if layout.members.contains(where: { $0.id == receipt.member.id }) { return .alreadyPresent }
        guard !receipt.member.archived else { return .unavailable }
        var restoredMember = receipt.member
        if receipt.member.draft == .none {
            guard availability == .available else { return .unavailable }
        } else {
            // An empty draft's old session was discarded. Only an explicitly supplied fresh local session can return.
            guard case .draftSession(let token) = availability,
                  !layout.members.contains(where: { $0.draft != .none }),
                  !token.isEmpty,
                  (receipt.member.draft == .empty ? receipt.member.draftToken != token : receipt.member.draftToken == token) else { return .unavailable }
            restoredMember.draftToken = token
        }
        var next = layout
        let p = receipt.position
        let restoreColumn = p.column.map { slot in
            layout.mode == receipt.mode && capacity.columnReturnAllowed && layout.columns.count < capacity.maxColumns
                && layout.left.count + layout.right.count + layout.parked.count + capacity.admittedAddReservations
                    <= (capacity.dockLimitAfterColumnReturn ?? capacity.dockLimit)
                && layout.vacancies.contains { $0.id == slot.id && $0.lineage == slot.lineage }
                && !layout.columns.contains { $0.id == slot.id }
        } ?? false
        var requisitioned: [String] = []
        if restoreColumn, let slot = p.column {
            next.normalize()
            // Preserve all current widths relative to one another; add only the removed slot's share.
            let share = slot.weight
            guard share > 0 && share < 1 else { return .unavailable }
            let unchanged = next.columns.count == receipt.survivorWeights.count && next.columns.allSatisfy {
                abs((receipt.survivorWeights[$0.id]?.after ?? -.infinity) - $0.weight) < 1e-9
            }
            for i in next.columns.indices {
                next.columns[i].weight = unchanged ? receipt.survivorWeights[next.columns[i].id]!.before : next.columns[i].weight * (1 - share)
            }
            next.columns.insert(.init(id: slot.id, lineage: slot.lineage, member: receipt.member.id, weight: share),
                                at: min(max(0,p.index), next.columns.count))
            next.vacancies.removeAll { $0.id == slot.id }
            if layout.selectionRevision == receipt.selectionRevision && layout.current == receipt.successor {
                next.current = receipt.previousCurrent
            }
            next.normalize()
        } else {
            let used = layout.left.count + layout.right.count + layout.parked.count + capacity.admittedAddReservations
            // Capacity is geometric, not one extra slot per brief. SunHover supplies measured prefix offers.
            if used + 1 > capacity.dockLimit {
                guard let offer = capacity.briefOffers.first(where: { offer in
                    !offer.members.isEmpty && Set(offer.members).count == offer.members.count
                        && offer.members.count < layout.columns.count
                        && used + 1 + offer.members.count <= offer.dockLimitAfterRequisition
                        && offer.members.allSatisfy { id in
                            id != layout.current && !capacity.addProtectedMembers.contains(id)
                                && layout.columns.contains { $0.member == id }
                        }
                }) else { return .full }
                requisitioned = offer.members
            }
            for id in requisitioned {
                next.columns.removeAll { $0.member == id }
                next[next.ordinaryBank].append(id)
            }
            next.normalize()
            let bank = layout.mode == receipt.mode ? p.bank : layout.ordinaryBank
            let index = p.column == nil ? p.index : p.dockIndex
            next[bank].insert(receipt.member.id, at: min(max(0, index), next[bank].count))
        }
        next.members.append(restoredMember)
        next.revision &+= 1
        return .restored(.init(layout: next, identityPreference: receipt.member.identity,
                              requisitionedBriefs: requisitioned, revokeTide: capacity.tideToken))
    }
}
