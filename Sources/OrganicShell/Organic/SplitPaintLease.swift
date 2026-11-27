import AppKit

/// An exclusive drawing right, confined to the main actor that commits AppKit changes.
@MainActor final class SplitPaintLease {
    enum Actor: String { case native, part, surface }
    struct Token: Equatable {
        let role: String
        let generation: UInt64
        let holder: ObjectIdentifier
        let actor: Actor
    }
    private var serial: UInt64 = 0
    private var held: [String: Token] = [:]
    func claim(_ role: String, by holder: AnyObject, actor: Actor) -> Token? {
        guard held[role] == nil else { return nil }
        serial += 1
        let token = Token(role: role, generation: serial, holder: ObjectIdentifier(holder), actor: actor)
        held[role] = token
        return token
    }
    func validates(_ token: Token) -> Bool { held[token.role] == token }
    @discardableResult func release(_ token: Token) -> Bool {
        guard validates(token) else { return false }
        held.removeValue(forKey: token.role)
        return true
    }
    /// Caller surrounds both relinquish and acquire with the same disabled-actions transaction.
    func handoff(_ token: Token, to holder: AnyObject, actor: Actor) -> Token? {
        guard release(token) else { return nil }
        return claim(token.role, by: holder, actor: actor)
    }
    var owners: [Token] { Array(held.values) }
}
