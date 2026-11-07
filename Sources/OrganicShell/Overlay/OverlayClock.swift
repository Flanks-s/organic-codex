import AppKit

@MainActor final class OverlayCancellation {
    private var cancelAction: (() -> Void)?
    init(_ action: @escaping () -> Void = {}) { cancelAction = action }
    func cancel() { cancelAction?(); cancelAction = nil }
}
@MainActor protocol OverlayClock: AnyObject {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> OverlayCancellation
}
@MainActor final class OverlaySystemClock: OverlayClock {
    var now: TimeInterval { CACurrentMediaTime() }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> OverlayCancellation {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common)
        return OverlayCancellation { timer.invalidate() }
    }
}
/// Deterministic clock for pointer-hold, wheel idle, dismissal and word-animation cleanup; never sleeps.
@MainActor final class OverlayManualClock: OverlayClock {
    private struct Entry { let id: UUID; let deadline: TimeInterval; let sequence: Int; let action: @MainActor () -> Void }
    private var entries: [Entry] = []
    private var sequence = 0
    private(set) var now: TimeInterval = 0
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> OverlayCancellation {
        let id = UUID(); sequence += 1
        entries.append(Entry(id: id, deadline: now + max(0, delay), sequence: sequence, action: action))
        return OverlayCancellation { [weak self] in self?.entries.removeAll { $0.id == id } }
    }
    func advance(by delta: TimeInterval) {
        let target = now + max(0, delta)
        while let next = entries.filter({ $0.deadline <= target + 1e-9 }).min(by: { ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence) }) {
            entries.removeAll { $0.id == next.id }; now = next.deadline; next.action()
        }
        now = target
    }
}
