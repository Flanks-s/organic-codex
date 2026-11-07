import Foundation

/// Synthetic playback only. No network, process, or backend-data-directory access.
/// Defaults are the original A–F replay's cadence and the product's background-event interval.
struct MockPlaybackSettings: Equatable, Sendable {
    var tickInterval: TimeInterval = 0.25
    var charactersPerTick: Int = 16
    var backgroundEventInterval: TimeInterval = 20

    var normalized: Self {
        var value = self
        value.tickInterval = tickInterval.isFinite ? min(2, max(0.05, tickInterval)) : 0.25
        value.charactersPerTick = min(120, max(2, charactersPerTick))
        value.backgroundEventInterval = backgroundEventInterval.isFinite ? min(120, max(3, backgroundEventInterval)) : 20
        return value
    }
}

/// Same nine events as the product MockEngine. Debug is a client of this mock source,
/// never a second producer with its own timer.
enum MockInjection: String, CaseIterable {
    case approval = "Approval Request", question = "Question"
    case errorRunning = "Error · Still Running", errorStopped = "Error · Stopped"
    case complete = "Complete", compaction = "Compaction"
    case addSatellite = "Add Sub-agent", satelliteDone = "Sub-agent Done", contextUp = "Context +15%"
}
