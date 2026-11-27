import AppKit

/// Unreleased interactions are opt-in. Checks may enable one capability without changing the others.
struct OrganicFeatureAvailability: Equatable {
    var conversationOrbTear = false
    var windowTear = false
    var collapse = false
    var dictation = false
    var haptics = false

    @MainActor static var current = startup(ProcessInfo.processInfo.environment)

    /// Launch overrides only enable capabilities; they never persist in user preferences.
    static func startup(_ environment: [String: String]) -> Self {
        var result = Self()
        let names = environment["ORGANIC_ENABLE_FEATURES", default: ""].split(separator: ",")
        for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            switch name {
            case "tear":
                result.windowTear = true
                result.conversationOrbTear = true
            case "window-tear": result.windowTear = true
            case "conversation-orb-tear": result.conversationOrbTear = true
            case "collapse": result.collapse = true
            case "dictation": result.dictation = true
            case "haptics": result.haptics = true
            default: break
            }
        }
        return result
    }

    func allowsTear(conversationOrb: Bool) -> Bool {
        conversationOrb ? conversationOrbTear : windowTear
    }
}

/// All product haptics pass through this seam. Checks replace the performer without touching hardware.
@MainActor enum OrganicHaptics {
    static var performer: (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard OrganicFeatureAvailability.current.haptics else { return }
        performer(pattern)
    }
}
