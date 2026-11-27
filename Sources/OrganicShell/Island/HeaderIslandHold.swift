import Foundation
import QuartzCore

/// Shared contract for S4, Panels E1 and M11.35 S3; no Header/Pulse writer is installed here.
/// Token identifies one role/generation/holder. Holders may overlap, including the same role.
/// Host owns coordinate roots and atomic role mapping; no private Header field is inspected.
/// S4 configure: invalidate(.targetChanged) BEFORE replacing target/root or restoring Pulse content.
/// S4 render/placeMotion: canWrite(role, write:) gates ONLY geometry/visibility assignments.
/// S4 restorePulseContent: gate each restored role's visibility, then run normal Pulse bookkeeping.
/// S4 setOrbCarried: retain logical carried state, gate planet geometry/visibility assignments.
/// S4 dispose: invalidate(.disposed) BEFORE teardown; continue the original whole cleanup frame.
/// Never gate Pulse state, rhythm, timers, transitions or lifecycle calls. No early whole-frame return.
/// All claim/place/release/invalidate calls share the caller's disabled-actions display transaction.
/// Header ancestors declare their affected roles so a parent write cannot move a held descendant.
/// E1 suspend(): claim interaction on the host roles; return a closure releasing only these tokens.
/// Header interaction apply must combine the ledger with current lifecycle/active/carried eligibility.
/// Whole-Header canAct uses Role.interaction; leaf holds gate their own controls, not the whole island.
/// Do NOT call setPresentationActive(false) for this pause: it would also suspend Pulse.
/// Listed roles are unique, ancestor-first and stable until invalidation; every listed role has a pose/root.
/// Original and transport poses use that same stable external root; host converts to actual parents.
/// Original-placement queries exclude all current holds (especially aggregate interaction pauses).
/// Apply only the named field, preserving other fields; never mutate Pulse state in apply.
/// After restoration, normal writers may project current state in the same transaction; no Pulse reset.
/// Parent geometry commits reapply held descendant poses in host order in the same transaction.
/// Original roots stay alive until invalidation; invalidate before detaching or changing those roots.
@MainActor protocol HeaderIslandHoldHost: AnyObject {
    var headerHoldRoles: [String] { get }
    func headerHoldCoordinateRoot(for role: String) -> AnyObject?
    func headerHoldOriginalPlacement(for role: String) -> HeaderIslandHold.Placement?
    func headerHoldAffectedRoles(for role: String, write: HeaderIslandHold.Write) -> Set<String>
    func headerHoldApply(_ pose: HeaderIslandHold.Placement, role: String, write: HeaderIslandHold.Write)
}

/// S4 exposes one stored/lazy ledger per island; all three clients use this same instance.
@MainActor protocol HeaderIslandHoldSource: HeaderIslandHoldHost {
    var headerHolds: HeaderIslandHold { get }
}

@MainActor final class HeaderIslandHold {
    /// Stable shared names. Controls exclude the separately named planet/event/satellite leaves.
    enum Role {
        static let root = "header.root"
        static let capsule = "header.capsule"
        static let lobe = "header.lobe"
        static let title = "header.title"
        static let planet = "header.planet"
        static let controls = "header.controls"
        static let event = "header.event"
        static let pulse = "header.pulse"
        static let interaction = "header.interaction"
        static func satellite(_ id: String) -> String { "header.satellite/" + id }
    }
    enum Write: Hashable { case geometry, visibility, interaction }
    enum Reason: Equatable { case targetChanged, disposed }
    struct Token: Hashable {
        let role: String
        let generation: UUID
        let holder: ObjectIdentifier
    }
    /// Geometry is expressed in root coordinates; host maps an atomic role to its actual view/layer group.
    struct Placement {
        weak var root: AnyObject?
        var frame: CGRect = .zero
        var bounds: CGRect = .zero
        var transform: CATransform3D = CATransform3DIdentity
        var hidden = false
        var opacity: CGFloat = 1
        var interactive = true
    }
    private struct Entry {
        let token: Token
        let writes: Set<Write>
        var pose: Placement?
        let revoked: (Token, Reason) -> Void
    }
    private weak var host: (any HeaderIslandHoldHost)?
    private var entries: [Entry] = []
    private var originals: [String: [Write: Placement]] = [:]
    private var revoking = false
    private var disposed = false
    var tokens: [Token] { entries.map(\.token) }
    init(host: any HeaderIslandHoldHost) { self.host = host }
#if CHECK_PACKAGE_WHOLE_TREE
    /// Each unlisted-role query records its role/write; absent hosts never record a finding.
    private(set) var findings: [String: [Write]] = [:]
#endif

    /// Admission for ordinary Header writers, not permission to stop a lifecycle/state update.
    /// Missing hosts and unlisted roles have no holds and remain writable (fail-open).
    func canWrite(_ role: String, write: Write) -> Bool {
#if CHECK_PACKAGE_WHOLE_TREE
        // Check-only observation; production admission and unknown-role claim rejection stay unchanged.
        if let host, !host.headerHoldRoles.contains(role) { findings[role, default: []].append(write) }
#endif
        guard !entries.isEmpty else { return true }
        guard let host, host.headerHoldRoles.contains(role) else { return true }
        let affected = host.headerHoldAffectedRoles(for: role, write: write).union([role])
        return !entries.contains { affected.contains($0.token.role) && $0.writes.contains(write) }
    }
    func validates(_ token: Token) -> Bool { entries.contains { $0.token == token } }
    func originalPlacement(_ role: String, write: Write) -> Placement? { originals[role]?[write] }

    /// Capture each field on its first hold; a later holder cannot overwrite another field's baseline.
    /// Latest transport geometry wins; hidden/opacity restrictions intersect; interaction holds all pause.
    func claim(_ role: String, by holder: AnyObject, writes: Set<Write>,
               initial: Placement? = nil, revoked: @escaping (Token, Reason) -> Void = { _, _ in }) -> Token? {
        guard !disposed, !revoking, !writes.isEmpty, let host, host.headerHoldRoles.contains(role),
              let original = host.headerHoldOriginalPlacement(for: role),
              accepts(original, role: role) else { return nil }
        if let initial, !accepts(initial, role: role) { return nil }
        for write in writes where originals[role]?[write] == nil {
            originals[role, default: [:]][write] = original
        }
        let token = Token(role: role, generation: UUID(), holder: ObjectIdentifier(holder))
        entries.append(Entry(token: token, writes: writes, pose: initial, revoked: revoked))
        apply(role, writes: writes)
        return token
    }
    /// Initial placement uses the same validation as later updates; stale/foreign tokens cannot place.
    @discardableResult func place(_ token: Token, at pose: Placement) -> Bool {
        guard let index = entries.firstIndex(where: { $0.token == token }), accepts(pose, role: token.role) else {
            return false
        }
        entries[index].pose = pose
        apply(token.role, writes: entries[index].writes)
        return true
    }
    @discardableResult func release(_ token: Token) -> Bool {
        guard let index = entries.firstIndex(where: { $0.token == token }) else { return false }
        let entry = entries[index]
        entries.remove(at: index)
        apply(token.role, writes: entry.writes)
        return true
    }
    /// Additive pause only; does not change geometry, paint visibility or Pulse's lifecycle.
    func suspend(_ roles: [String], by holder: AnyObject,
                 revoked: @escaping (Token, Reason) -> Void = { _, _ in }) -> () -> Void {
        let held = Set(roles).compactMap { claim($0, by: holder, writes: [.interaction], revoked: revoked) }
        return { [weak self] in
            for token in held { self?.release(token) }
        }
    }
    /// Invalidate before target/root changes or dispose. Clear authority before restoring/notifying.
    /// Reentrant claims are rejected until all original placements and revocations have completed.
    func invalidate(_ reason: Reason, roles: Set<String>? = nil) {
        guard !revoking else { return }
        revoking = true
        if reason == .disposed { disposed = true }
        let old: [Entry]
        if let roles {
            old = entries.filter { roles.contains($0.token.role) }
            entries.removeAll { roles.contains($0.token.role) }
        } else {
            old = entries
            entries.removeAll() // Hold.invalidate
        }
        for role in host?.headerHoldRoles ?? [] where roles?.contains(role) != false {
            for (write, pose) in originals.removeValue(forKey: role) ?? [:] {
                host?.headerHoldApply(pose, role: role, write: write)
            }
        }
        for entry in old { entry.revoked(entry.token, reason) }
        revoking = false
    }
    private func accepts(_ pose: Placement, role: String) -> Bool {
        guard let root = pose.root, let current = host?.headerHoldCoordinateRoot(for: role) else { return false }
        return root === current
    }
    private func apply(_ changedRole: String, writes: Set<Write>) {
        guard let host else { return }
        for write in writes {
            let affected = host.headerHoldAffectedRoles(for: changedRole, write: write).union([changedRole])
            for role in host.headerHoldRoles where affected.contains(role) {
                guard var pose = originals[role]?[write] else { continue }
                let active = entries.filter { $0.token.role == role && $0.writes.contains(write) }
                switch write {
                case .geometry:
                    if let latest = active.compactMap(\.pose).last { pose = latest }
                case .visibility:
                    for candidate in active.compactMap(\.pose) {
                        pose.hidden = pose.hidden || candidate.hidden
                        pose.opacity = min(pose.opacity, candidate.opacity)
                    }
                case .interaction:
                    if !active.isEmpty { pose.interactive = false }
                }
                host.headerHoldApply(pose, role: role, write: write)
                if active.isEmpty { originals[role]?[write] = nil }
                if originals[role]?.isEmpty == true { originals[role] = nil }
            }
        }
    }
    isolated deinit { invalidate(.disposed) }
}
