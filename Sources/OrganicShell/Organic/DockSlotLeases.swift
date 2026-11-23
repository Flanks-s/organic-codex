import Foundation

/// Window-local ownership of the contiguous brief space next to the Dock.
/// Callers supply a capacity verdict; this model never edits conversation membership.
struct DockSlotLeases {
    enum Purpose: String { case tide, add }
    enum Role: Equatable { case full, brief }
    enum Reason: String, CaseIterable, Hashable {
        case fullColumn, draft, attachment, focus, hover, markedText, choosingAttachment
        case submitting, reclaimed, grace, occupied, capacity, insufficientSpace, staleGeneration
    }
    struct Candidate {
        let id: String
        let role: Role
        var protection: Set<Reason> = []
    }
    struct Token: Equatable {
        let owner: String
        let generation: UInt64
        let purpose: Purpose
    }
    struct Lease: Equatable {
        let token: Token
        let briefs: [String]
        var committed = false
    }
    enum Status: String { case granted, reduced, full }
    struct Decision {
        let status: Status
        let lease: Lease?
        let reasons: Set<Reason>
        let revoked: Token?
        var allowsRefusalKnock: Bool { !reasons.contains(.markedText) }
    }

    static let protectionGrace = 0.9
    private(set) var generation: UInt64 = 0
    private(set) var tide: Lease?
    private(set) var add: Lease?
    private var addBeforeReservation: Lease?
    private var protection: [String: Set<Reason>] = [:]
    private var protectedUntil: [String: Double] = [:]

    /// Publish input changes when they happen, including the transition out of protection.
    mutating func updateProtection(_ reasons: Set<Reason>, for id: String, at time: Double) {
        let previous = protection[id] ?? []
        protection[id] = reasons
        if !previous.isEmpty && reasons.isEmpty { protectedUntil[id] = time + Self.protectionGrace }
        if !reasons.isEmpty, tide?.briefs.contains(id) == true { invalidateTide() }
    }

    /// Candidates are ordered from the Dock toward the left. A blocked item ends the usable prefix.
    mutating func request(owner: String, purpose: Purpose, count: Int, candidates: [Candidate],
                          capacityAllows: Bool? = nil, at time: Double) -> Decision {
        if let current=tide,candidates.contains(where:{c in
            current.briefs.contains(c.id) && (c.role != .brief || !c.protection.union(protection[c.id] ?? []).isEmpty
                || time < (protectedUntil[c.id] ?? -.infinity))
        }) { invalidateTide() }
        guard count >= 0, (purpose == .add ? capacityAllows == true : capacityAllows != false),
              Set(candidates.map(\.id)).count == candidates.count else {
            return .init(status: .full, lease: nil, reasons: [.capacity], revoked: nil)
        }
        if let add {
            if !add.committed || (purpose == .add && add.token.owner != owner) {
                if purpose == .add,add.token.owner == owner,add.briefs.count == count {
                    return .init(status:.granted,lease:add,reasons:[],revoked:nil)
                }
                return .init(status: .full, lease: nil, reasons: [.occupied], revoked: nil)
            }
            if purpose == .add, count < add.briefs.count {
                return .init(status:.full,lease:nil,reasons:[.capacity],revoked:nil)
            }
            if purpose == .add, count == add.briefs.count {
                let revoked=tide?.token
                if tide != nil { invalidateTide() }
                return .init(status:.granted,lease:add,reasons:[],revoked:revoked)
            }
        }
        if purpose == .tide, let tide, tide.token.owner != owner {
            return .init(status: .full, lease: nil, reasons: [.occupied], revoked: nil)
        }
        var available: [String] = purpose == .add ? (add?.briefs ?? []):[], reasons: Set<Reason> = []
        for c in candidates {
            if available.count == count { break }
            if add?.briefs.contains(c.id) == true { continue }
            guard c.role == .brief else { reasons.insert(.fullColumn); break }
            let held = c.protection.union(protection[c.id] ?? [])
            if !held.isEmpty { reasons.formUnion(held); break }
            if time < (protectedUntil[c.id] ?? -.infinity) { reasons.insert(.grace); break }
            available.append(c.id)
        }
        if available.count < count { reasons.insert(.insufficientSpace) }
        guard count == 0 || !available.isEmpty else {
            if purpose == .tide { invalidateTide() }
            return .init(status: .full, lease: nil, reasons: reasons, revoked: nil)
        }
        if purpose == .add, available.count != count {
            return .init(status: .full, lease: nil, reasons: reasons, revoked: nil)
        }
        if purpose == .tide, let tide, tide.briefs == available {
            return .init(status: available.count == count ? .granted : .reduced,
                         lease: tide, reasons: reasons, revoked: nil)
        }
        let revoked = tide?.token
        generation &+= 1
        let lease = Lease(token: .init(owner: owner, generation: generation, purpose: purpose), briefs: available)
        if purpose == .add { addBeforeReservation=add; tide = nil; add = lease } else { tide = lease }
        return .init(status: available.count == count ? .granted : .reduced,
                     lease: lease, reasons: reasons, revoked: revoked)
    }

    /// Read-only Undo capacity: Add retains ownership and no reservation is created.
    func undoPrefixes(candidates:[Candidate],at time:Double)->[[String]] {
        guard add?.committed != false else { return [] }
        var prefix:[String]=[],result:[[String]]=[]
        for c in candidates {
            guard c.role == .brief,add?.briefs.contains(c.id) != true,
                  c.protection.union(protection[c.id] ?? []).isEmpty,
                  time >= (protectedUntil[c.id] ?? -.infinity) else { break }
            prefix.append(c.id);result.append(prefix)
        }
        return result
    }

    func nextProtectionRelease(after time:Double)->Double? {protectedUntil.values.filter{$0>time}.min()}

    func owns(_ token: Token) -> Bool { tide?.token == token || add?.token == token }

    /// Add preallocation already invalidates Tide. Commit only changes the Add cancellation contract.
    @discardableResult mutating func commitAdd(_ token: Token) -> Bool {
        guard token.purpose == .add, add?.token == token else { return false }
        if add?.briefs.isEmpty == true { add=nil;addBeforeReservation=nil;return true }
        add?.committed = true
        addBeforeReservation=nil
        return true
    }

    /// A callback can release only its current token, never a replacement owner's space.
    @discardableResult mutating func release(_ token: Token) -> Bool {
        if tide?.token == token { invalidateTide(); return true }
        if add?.token == token, add?.committed == false {
            generation &+= 1
            add=addBeforeReservation.map { .init(token:.init(owner:$0.token.owner,generation:generation,purpose:.add),briefs:$0.briefs,committed:true) }
            addBeforeReservation=nil
            return true
        }
        return false
    }

    /// Capacity falling, not a Tide callback, is what restores an Add-requisitioned brief.
    @discardableResult mutating func updateAddCapacity(requiredBriefs: Int) -> Bool {
        guard let current = add, current.committed, requiredBriefs < current.briefs.count else { return false }
        if tide != nil { invalidateTide() }
        generation &+= 1
        if requiredBriefs <= 0 { add = nil }
        else {
            add = .init(token: .init(owner: current.token.owner, generation: generation, purpose: .add),
                        briefs: Array(current.briefs.prefix(requiredBriefs)), committed: current.committed)
        }
        return true
    }

    mutating func retire() { tide = nil; generation &+= 1 }
    private mutating func invalidateTide() { tide = nil; generation &+= 1 }
}
