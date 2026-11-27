import Foundation

/// A transient claim, never a second membership store. Ordinary commits invalidate pending preparation.
@MainActor final class OrganicStructureOwner {
    struct Claim: Equatable {
        let id: UUID
        let window: UUID
        let revision: UInt64
        let generation: UInt64
    }
    private var pending: Claim?
    private var active: UUID?
    private(set) var generation: UInt64 = 0
    private(set) var commits = 0
    func claim(window: UUID, revision: UInt64) -> Claim? {
        guard pending == nil, active == nil else { return nil }
        let value = Claim(id: UUID(), window: window, revision: revision, generation: generation)
        pending = value
        return value
    }
    func validate(_ claim: Claim, window: UUID, revision: UInt64) -> Bool {
        pending == claim && active == nil && claim.window == window
            && claim.revision == revision && claim.generation == generation
    }
    func cancel(_ claim: Claim) {
        if pending == claim { pending = nil }
    }
    func beginCommit(claim: Claim? = nil) -> UUID? {
        guard active == nil else { return nil }
        if let claim, !validate(claim, window: claim.window, revision: claim.revision) { return nil }
        let ticket = UUID()
        active = ticket
        pending = nil
        return ticket
    }
    func beginOrdinaryCommit() {
        pending = nil
        generation &+= 1
    }
    func finishCommit(_ ticket: UUID?) {
        if let ticket {
            guard active == ticket else { return }
            active = nil
            generation &+= 1
        }
        commits += 1
    }
}
