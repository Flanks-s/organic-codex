import Foundation

struct SplitPresentationRole: Hashable {
    let window: UUID
    let member: String
    let role: String
    let generation: UInt64
    var key: String { "\(window.uuidString):\(member.utf8.count):\(member):\(role)" }
}
@MainActor final class SplitPresentationRoles {
    /// A registry belongs to one presentation lifetime; advance revokes every old token.
    private(set) var generation: UInt64 = 0
    private let leases = SplitPaintLease()
    func advance() {
        for token in leases.owners {
            _ = leases.release(token)
        }
        generation += 1
    }
    func claim(_ role: SplitPresentationRole, by holder: AnyObject,
               actor: SplitPaintLease.Actor) -> SplitPaintLease.Token? {
        guard role.generation == generation, !role.member.isEmpty, !role.role.isEmpty else {
            return nil
        }
        return leases.claim(role.key, by: holder, actor: actor)
    }
    func holds(_ role: SplitPresentationRole, token: SplitPaintLease.Token) -> Bool {
        role.generation == generation && token.role == role.key && leases.validates(token)
    }
    @discardableResult func release(_ role: SplitPresentationRole, token: SplitPaintLease.Token) -> Bool {
        guard holds(role, token: token) else {
            return false
        }
        return leases.release(token)
    }
}
