import Foundation

/// Unreleased interactions are opt-in. Checks may enable one capability without changing the others.
@MainActor struct OrganicFeatureAvailability {
    var conversationOrbTear = false
    static var current = OrganicFeatureAvailability()
}
