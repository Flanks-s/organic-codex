import Foundation

/// App/Organic implement this on each scene (or its window adapter). Keep the snapshot
/// and read it when building the next motion; receiving a change must invalidate prewarming.
@MainActor protocol DebugTuningHost: AnyObject {
    func applyDebugTuning(_ snapshot: DebugTuningSnapshot)
}

/// Retain one per scene, not per panel. Replays the current settings for newly created windows;
/// closing a Debug panel does not detach a scene. A retired host is held weakly.
@MainActor final class DebugTuningBinding {
    private let tuning: DebugTuning
    private var observation: UUID?
    init(tuning: DebugTuning, host: any DebugTuningHost) {
        self.tuning = tuning
        observation = tuning.observe { [weak host] snapshot in host?.applyDebugTuning(snapshot) }
    }
    func invalidate() {
        if let observation { tuning.removeObserver(observation) }; observation = nil
    }
    isolated deinit { if let observation { tuning.removeObserver(observation) } }
}
