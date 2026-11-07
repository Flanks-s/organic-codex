import AppKit

/// The Debug panel's snapshot as the harness tuning the scenes read (Organic/ProductMath Tuning): Auto layout, the dock's
/// metrics, the brief ↔ full morph and the Auto, queue and Focused springs. Peek, Tear, window grow, Orb, approval-card
/// and mode-flight values have no consumer in the scene yet and stay at their constants (DEBUG-MOCK-S4 §Organic).
@MainActor final class SceneTuningHost: DebugTuningHost {
    var windows: () -> [OrganicWindow] = { [] }
    static let map: [(DebugTuningParameter, HarnessTuningKey)] = [
        (.autoFullMin, .autoFullMin), (.autoFullShare, .autoFullShare), (.autoBriefComfort, .autoBriefComfort), (.autoLastBarMin, .autoLastBarMin),
        (.autoBriefMin, .autoBriefMin), (.autoBriefMax, .autoBriefMax), (.autoBriefShare, .autoBriefShare),
        (.morphBurst, .morphBurst), (.morphSwirl, .morphSwirl), (.morphPop, .morphPop), (.morphStagger, .morphStagger),
        (.dockHeightRatio, .dockHeightRatio), (.dockMinHeight, .dockMinHeight), (.dockMaxHeight, .dockMaxHeight), (.dockBottom, .dockBottom),
        (.dockGapRatio, .dockGapRatio), (.dockOrbGap, .dockOrbGap), (.dockOrbRest, .dockOrbRest), (.dockMagnify, .dockMagnify),
        (.dockMagnifyReach, .dockMagnifyReach), (.dockMe, .dockMe), (.dockHoverRise, .dockHoverRise),
        (.autoResponse, .autoResponse), (.autoDamping, .autoDamping), (.queueResponse, .queueResponse), (.queueDamping, .queueDamping),
        (.focusResponse, .focusResponse), (.focusDamping, .focusDamping)]
    func applyDebugTuning(_ snapshot: DebugTuningSnapshot) {
        let values = Dictionary(uniqueKeysWithValues: Self.map.map { ($0.1, snapshot[$0.0]) })
        guard Tuning.shared.apply(values) else { return }
        for w in windows() { w.scene.tuningChanged() }
    }
}
