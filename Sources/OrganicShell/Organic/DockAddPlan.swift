import Foundation

/// Capacity verdict and Add lease transaction, with no scene mutations. B applies these values to its one writer.
struct DockAddPlan {
    static let pitches = [56.0, 56, 56, 56, 56, 44, 50, 42, 42]
    static let briefCounts = [0, 0, 0, 0, 0, 0, 1, 1, 2]
    struct Column {
        let id: String
        let role: DockSlotLeases.Role
        let bar: CGRect
        var draftText = ""
        var hasAttachments = false
        var hasMarkedText = false
        var reclaimed = false
        var protection: Set<DockSlotLeases.Reason> = []
        var reasons: Set<DockSlotLeases.Reason> {
            var result = protection
            if !draftText.isEmpty { result.insert(.draft) }
            if hasAttachments { result.insert(.attachment) }
            if hasMarkedText { result.insert(.markedText) }
            if reclaimed { result.insert(.reclaimed) }
            return result
        }
    }
    struct Context {
        let bounds: CGRect
        let llCenter: CGPoint
        let dockBaseline: Double
        let rightCenterX: Double
        /// Actual free/requisitionable Dock rail, supplied by the layout; smaller windows reduce capacity by fit.
        let availableRow: ClosedRange<Double>
        let columns: [Column]
    }
    struct Layout {
        let count: Int
        let pitch: Double
        let requisitioned: [String]
        let slots: [CGPoint]
        let extraLeftHop: Double
    }
    enum Failure: Equatable {
        case full, duplicate, stale, reservationBusy
        case temporarilyUnavailable(Set<DockSlotLeases.Reason>)
        var title: String? {
            switch self {
            case .full: "The Dock is full"
            case .duplicate: "Already in this window"
            case .stale: "Conversation is no longer available"
            case .reservationBusy, .temporarilyUnavailable: nil
            }
        }
    }
    enum Verdict { case allowed(Layout), blocked(Failure) }
    private static let transientReasons: Set<DockSlotLeases.Reason> = [.focus, .hover, .grace, .choosingAttachment, .submitting, .occupied, .staleGeneration]

    /// The table defines N0...8. No unapproved extrapolation beyond its last row.
    static func layout(count: Int, context: Context) -> Verdict {
        let verdict = capacityLayout(count: count, context: context)
        guard case .blocked(.full) = verdict else { return verdict }
        let transient = context.columns.reduce(into: Set<DockSlotLeases.Reason>()) { $0.formUnion($1.reasons.intersection(transientReasons)) }
        guard !transient.isEmpty else { return verdict }
        let columns = context.columns.map { column in
            var c = column; c.protection.subtract(transientReasons); return c
        }
        let relaxed = Context(bounds: context.bounds, llCenter: context.llCenter, dockBaseline: context.dockBaseline,
                              rightCenterX: context.rightCenterX, availableRow: context.availableRow, columns: columns)
        if case .allowed = capacityLayout(count: count, context: relaxed) { return .blocked(.temporarilyUnavailable(transient)) }
        return verdict
    }
    private static func capacityLayout(count: Int, context: Context) -> Verdict {
        guard (0...8).contains(count) else { return .blocked(.full) }
        if count == 0 { return .allowed(.init(count: 0, pitch: 56, requisitioned: [], slots: [], extraLeftHop: 0)) }
        func sharesRow(_ column: Column) -> Bool {
            context.dockBaseline + 16 + 12 > column.bar.minY && context.dockBaseline - 16 - 12 < column.bar.maxY
        }
        let eligible = context.columns.reversed().filter { sharesRow($0) && $0.role == .brief && $0.reasons.isEmpty }
        let minimum = context.columns.contains(where: sharesRow) ? briefCounts[count] : 0
        guard eligible.count >= minimum else { return .blocked(.full) }
        // Try only as much extra requisition as the real width needs; protected/full columns are never shrunk.
        for needed in minimum...eligible.count {
            let selected = Array(eligible.prefix(needed)), selectedIDs = Set(selected.map(\.id))
            let pitch = needed > minimum ? 42 : pitches[count]
            var hop = count >= 8 ? 42.0 : 0
            if count >= 8, let nearest = selected.first {
                let nominalRight = context.rightCenterX - pitch * Double(count - 1) + 16
                hop = max(42, nominalRight - (nearest.bar.minX - 12))
            }
            let slots = (0..<count).map { index -> CGPoint in
                let rank = count - 1 - index
                return .init(x: context.rightCenterX - pitch * Double(rank) - (rank >= 7 ? hop : 0), y: context.dockBaseline)
            }
            guard slots.allSatisfy({ p in
                p.x - 16 >= context.availableRow.lowerBound && p.x + 16 <= context.availableRow.upperBound
                    && p.x - 16 >= context.bounds.minX + 10 && p.x + 16 <= context.bounds.maxX - 10
                    && p.x - 16 >= context.llCenter.x + SunHoverParameters.llOpenDiameter / 2 + 12
            }) else { continue }
            // Distinct requisitioned glass has 12 pt clearance. An unrequisitioned last bar may tighten to 96.
            let fits = context.columns.allSatisfy { column in
                guard sharesRow(column) else { return true }
                if selectedIDs.contains(column.id) {
                    let center = column.bar.minX + 16
                    return slots.allSatisfy { abs($0.x - center) >= 44 }
                }
                guard let leftmost = slots.first, leftmost.x + 16 > column.bar.minX else { return true }
                let usable = leftmost.x - 16 - 24 - column.bar.minX
                return usable >= (column.role == .full ? column.bar.width : min(96, column.bar.width))
            }
            if fits { return .allowed(.init(count: count, pitch: pitch, requisitioned: selected.map(\.id), slots: slots, extraLeftHop: hop)) }
        }
        return .blocked(.full)
    }

    enum Phase: Equatable { case flying, reserved, landed, cancelled }
    enum Exit { case escape, appDeactivated, windowClosed }
    struct Deal {
        let id: String
        let lease: DockSlotLeases.Token?
        let layout: Layout
        let startedAt: Double
        let reduceMotion: Bool
        var phase: Phase = .flying
        var kicked = false
    }
    private(set) var deals: [String: Deal] = [:]
    private var leaseOwner: String?
    var inFlightIDs: Set<String> { Set(deals.values.filter { $0.phase == .flying || $0.phase == .reserved }.map(\.id)) }
    /// B calls this when Dock membership/capacity falls; Tide callbacks never release committed Add space.
    @discardableResult mutating func updateCapacity(dockCount: Int, context: Context, leases: inout DockSlotLeases) -> Verdict {
        let verdict = Self.layout(count: dockCount, context: context)
        if case .allowed(let layout) = verdict { _ = leases.updateAddCapacity(requiredBriefs: layout.requisitioned.count) }
        return verdict
    }

    /// Obtain a cancellable Add reservation immediately; commit/member insertion happens at 0.66, never earlier.
    mutating func begin(id: String, memberIDs: Set<String>, dockCount: Int, context: Context,
                        leases: inout DockSlotLeases, at time: Double, reduceMotion: Bool = false, isAvailable: (String) -> Bool) -> Verdict {
        guard !memberIDs.contains(id), deals[id] == nil else { return .blocked(.duplicate) }
        guard !id.isEmpty, isAvailable(id) else { return .blocked(.stale) }
        // DockSlotLeases has one uncommitted Add owner. Avoid invisible queued deals or shared-token rollback.
        guard !deals.values.contains(where: { $0.phase == .flying }) else { return .blocked(.reservationBusy) }
        let verdict = Self.layout(count: dockCount + 1, context: context)
        guard case .allowed(let layout) = verdict else { return verdict }
        if leaseOwner == nil { leaseOwner = "LLAdd-" + UUID().uuidString }
        let chosen = Set(layout.requisitioned)
        // Add's capacity solver skips full/protected bars; the shared lease still arbitrates ownership/grace.
        let candidates = context.columns.reversed().filter { chosen.contains($0.id) }.map {
            DockSlotLeases.Candidate(id: $0.id, role: $0.role, protection: $0.reasons)
        }
        var token: DockSlotLeases.Token?
        if !chosen.isEmpty {
            let decision = leases.request(owner: leaseOwner!, purpose: .add, count: chosen.count,
                                          candidates: candidates, capacityAllows: true, at: time)
            guard decision.status == .granted, let granted = decision.lease?.token else {
                let transient = decision.reasons.intersection(Self.transientReasons)
                return .blocked(transient.isEmpty ? .full : .temporarilyUnavailable(transient))
            }
            token = granted
        }
        deals[id] = .init(id: id, lease: token, layout: layout, startedAt: time, reduceMotion: reduceMotion)
        return verdict
    }
    enum AbortReason: String { case capacityChanged, conversationUnavailable, leaseRejected, escape, windowClosed }
    struct Abort: Equatable { let conversationID: String; let reason: AbortReason }
    struct Receipt {
        var insertID: String? = nil
        var landedID: String? = nil
        var kick: Double = 0
        var aborted: Abort? = nil
        var cancelled: Bool { aborted != nil }
    }
    private mutating func abort(_ deal: Deal, reason: AbortReason, leases: inout DockSlotLeases) -> Receipt {
        if let token = deal.lease { _ = leases.release(token) }
        deals[deal.id] = nil
        return .init(aborted: .init(conversationID: deal.id, reason: reason))
    }
    /// A one-shot receipt also reports refusal at the reservation boundary, so B can dissolve and restore the ID.
    mutating func advance(id: String, context: Context, at time: Double, leases: inout DockSlotLeases,
                          isAvailable: (String) -> Bool) -> Receipt {
        guard var deal = deals[id], deal.phase != .cancelled, deal.phase != .landed else { return .init() }
        let elapsed = max(0, time - deal.startedAt + 1e-9)
        var inserted: String?, landed: String?, kick = 0.0
        if deal.phase == .flying, elapsed >= LLDockDeal.reserve {
            guard case .allowed(let current) = Self.layout(count: deal.layout.count, context: context),
                  Set(current.requisitioned) == Set(deal.layout.requisitioned) else {
                return abort(deal, reason: .capacityChanged, leases: &leases)
            }
            guard isAvailable(id) else { return abort(deal, reason: .conversationUnavailable, leases: &leases) }
            if let token = deal.lease, !leases.commitAdd(token) {
                return abort(deal, reason: .leaseRejected, leases: &leases)
            }
            deal.phase = .reserved; inserted = id
        }
        if deal.phase == .reserved, elapsed >= LLDockDeal.exit, !deal.kicked { deal.kicked = true; kick = deal.reduceMotion ? 0 : 26 }
        if deal.phase == .reserved, elapsed >= LLDockDeal.duration { deal.phase = .landed; landed = id }
        deals[id] = deal
        return .init(insertID: inserted, landedID: landed, kick: kick)
    }
    mutating func exit(_ reason: Exit, id: String, context: Context, at time: Double, leases: inout DockSlotLeases,
                       isAvailable: (String) -> Bool) -> Receipt {
        guard let deal = deals[id] else { return .init() }
        if reason == .appDeactivated { return .init() }
        if deal.phase == .flying, time - deal.startedAt + 1e-9 < LLDockDeal.reserve {
            return abort(deal, reason: reason == .escape ? .escape : .windowClosed, leases: &leases)
        }
        let receipt = advance(id: id, context: context, at: reason == .windowClosed ? max(time, deal.startedAt + LLDockDeal.duration) : time,
                              leases: &leases, isAvailable: isAvailable)
        return receipt
    }
    mutating func forgetLanded(_ id: String) { if deals[id]?.phase == .landed { deals[id] = nil } }
}
