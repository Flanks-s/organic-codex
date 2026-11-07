// Independent port of System Animation Model/Tuning.swift; values are local to this tool.
import Foundation

/// A runtime-adjustable number. Each spike adds the parameters it actually uses.
struct DebugTuningParameter: Identifiable, Sendable {
    let key: String
    let group: String
    let label: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    var id: String { key }
}

extension DebugTuningParameter {
    static let mockTick = DebugTuningParameter(key: "mock.tick", group: "Mock engine", label: "Tick interval (s)",
                                      range: 0.05...2, defaultValue: 0.25)
    static let mockCharsPerTick = DebugTuningParameter(key: "mock.charsPerTick", group: "Mock engine", label: "Streamed characters per tick",
                                              range: 2...120, defaultValue: 16)
    static let mockEventInterval = DebugTuningParameter(key: "mock.eventInterval", group: "Mock engine", label: "Background event every (s)",
                                               range: 3...120, defaultValue: 20)
    static let approvalDuration = DebugTuningParameter(key: "spring.approval.duration", group: "Spring · approval card", label: "Duration (s)",
                                              range: 0.05...1.2, defaultValue: 0.35)
    static let approvalBounce = DebugTuningParameter(key: "spring.approval.bounce", group: "Spring · approval card", label: "Bounce",
                                            range: 0...0.6, defaultValue: 0.15)

    // S1 tear probe: drag, detach and window growth (also used by S6).
    static let tearLongPress = DebugTuningParameter(key: "tear.longPress", group: "Tear · drag", label: "Long press (s)",
                                           range: 0.05...1, defaultValue: 0.25)
    static let tearLiftScale = DebugTuningParameter(key: "tear.liftScale", group: "Tear · drag", label: "Lift scale",
                                           range: 1...1.4, defaultValue: 1.12)
    static let tearDragThreshold = DebugTuningParameter(key: "tear.dragThreshold", group: "Tear · drag", label: "Drag threshold (pt)",
                                               range: 1...40, defaultValue: 8)
    static let tearPreDragFollow = DebugTuningParameter(key: "tear.preDragFollow", group: "Tear · drag", label: "Pre-drag follow (0 stuck – 1 free)",
                                               range: 0...1, defaultValue: 0.4)
    static let tearBand = DebugTuningParameter(key: "tear.band", group: "Tear · drag", label: "Queue band half-height (pt)",
                                      range: 10...80, defaultValue: 30)
    static let tearDetach = DebugTuningParameter(key: "tear.detach", group: "Tear · drag", label: "Detach distance (pt)",
                                        range: 20...240, defaultValue: 90)
    static let tearStretch = DebugTuningParameter(key: "tear.stretch", group: "Tear · drag", label: "Stretch damping (pt)",
                                         range: 5...150, defaultValue: 45)
    static let tearGlassSpacing = DebugTuningParameter(key: "tear.glassSpacing", group: "Tear · drag", label: "Glass merge spacing (pt)",
                                              range: 0...80, defaultValue: 10)
    static let tearResponse = DebugTuningParameter(key: "spring.tear.response", group: "Spring · tear", label: "Response (s)",
                                          range: 0.05...1.2, defaultValue: 0.3)
    static let tearDamping = DebugTuningParameter(key: "spring.tear.damping", group: "Spring · tear", label: "Damping fraction",
                                         range: 0.2...1.2, defaultValue: 0.78)
    static let growDuration = DebugTuningParameter(key: "grow.duration", group: "Window grow · route A", label: "Duration (s)",
                                          range: 0.05...1.5, defaultValue: 0.38)
    static let growC1x = DebugTuningParameter(key: "grow.c1x", group: "Window grow · route A", label: "Curve c1 x", range: 0...1, defaultValue: 0.3)
    static let growC1y = DebugTuningParameter(key: "grow.c1y", group: "Window grow · route A", label: "Curve c1 y", range: 0...1.5, defaultValue: 0.6)
    static let growC2x = DebugTuningParameter(key: "grow.c2x", group: "Window grow · route A", label: "Curve c2 x", range: 0...1, defaultValue: 0.2)
    static let growC2y = DebugTuningParameter(key: "grow.c2y", group: "Window grow · route A", label: "Curve c2 y", range: 0...1.5, defaultValue: 1)
    static let growStart = DebugTuningParameter(key: "grow.start", group: "Window grow · route A", label: "Start size (pt)",
                                       range: 40...300, defaultValue: 72)
    static let growFade = DebugTuningParameter(key: "grow.fade", group: "Window grow · route A", label: "Content fade-in from grow start (s)",
                                      range: 0...1, defaultValue: 0.18)

    // S2 orb component (spec §10.1–10.3).
    static let orbSize = DebugTuningParameter(key: "orb.size", group: "Orb", label: "Queue orb size (pt)", range: 24...64, defaultValue: 40)
    static let orbLiquidWobble = DebugTuningParameter(key: "orb.liquidWobble", group: "Orb", label: "Liquid wobble (pt at 40 pt)",
                                             range: 0...4, defaultValue: 1.2)
    static let orbLiquidDeepen = DebugTuningParameter(key: "orb.liquidDeepen", group: "Orb", label: "Liquid deepens at (context used)",
                                             range: 0.5...1, defaultValue: 0.8)
    static let orbSatelliteSize = DebugTuningParameter(key: "orb.satSize", group: "Orb · satellites", label: "Satellite size (× orb)",
                                              range: 0.25...0.6, defaultValue: 0.38)
    static let orbSatelliteMinSpeed = DebugTuningParameter(key: "orb.satMinSpeed", group: "Orb · satellites", label: "Slowest (rad/s)",
                                                  range: 0...3, defaultValue: 0.45)
    static let orbSatelliteMaxSpeed = DebugTuningParameter(key: "orb.satMaxSpeed", group: "Orb · satellites", label: "Fastest (rad/s)",
                                                  range: 0.5...8, defaultValue: 2.6)
    static let orbOrbitTilt = DebugTuningParameter(key: "orb.orbitTilt", group: "Orb · satellites", label: "Orbit tilt (°)",
                                          range: -60...60, defaultValue: -18)
    static let orbOrbitWidth = DebugTuningParameter(key: "orb.orbitWidth", group: "Orb · satellites", label: "Orbit radius (× orb)",
                                           range: 0.5...1.2, defaultValue: 0.68)
    static let orbOrbitFlatten = DebugTuningParameter(key: "orb.orbitFlatten", group: "Orb · satellites", label: "Orbit height (× radius)",
                                             range: 0.05...1, defaultValue: 0.3)
    static let orbAlertBounce = DebugTuningParameter(key: "orb.alertBounce", group: "Orb · red alert", label: "Bounce height (pt)",
                                            range: 0...16, defaultValue: 5)
    static let orbAlertPeriod = DebugTuningParameter(key: "orb.alertPeriod", group: "Orb · red alert", label: "Bounce every (s)",
                                            range: 0.6...6, defaultValue: 3)
    static let orbBreathPeriod = DebugTuningParameter(key: "orb.breathPeriod", group: "Orb · red alert", label: "Breathing period (s)",
                                             range: 1...6, defaultValue: 2.8)
    static let orbHoverResponse = DebugTuningParameter(key: "spring.orbHover.response", group: "Spring · orb hover", label: "Response (s)",
                                              range: 0.05...1.2, defaultValue: 0.34)
    static let orbHoverDamping = DebugTuningParameter(key: "spring.orbHover.damping", group: "Spring · orb hover", label: "Damping fraction",
                                             range: 0.2...1.2, defaultValue: 0.74)

    // S3 Auto layout and queue (spec §6.1).
    static let autoFullMin = DebugTuningParameter(key: "auto.fullMin", group: "Auto layout", label: "Full column min (pt)",
                                         range: 320...900, defaultValue: 480)
    static let autoFullShare = DebugTuningParameter(key: "auto.fullShare", group: "Auto layout", label: "Full column min (share of width)",
                                           range: 0.2...0.8, defaultValue: 0.4)
    static let autoBriefComfort = DebugTuningParameter(key: "auto.briefComfort", group: "Auto layout", label: "Capacity: brief width counted (pt)",
                                              range: 200...600, defaultValue: 300)
    static let autoLastBarMin = DebugTuningParameter(key: "auto.lastBarMin", group: "Auto layout", label: "Last bar min beside orbs (pt)",
                                            range: 100...400, defaultValue: 160)
    static let autoBriefMin = DebugTuningParameter(key: "auto.briefMin", group: "Auto layout", label: "Brief column min (pt)",
                                          range: 160...400, defaultValue: 220)
    static let autoBriefMax = DebugTuningParameter(key: "auto.briefMax", group: "Auto layout", label: "Brief column max (pt)",
                                          range: 220...700, defaultValue: 420)
    static let autoBriefShare = DebugTuningParameter(key: "auto.briefShare", group: "Auto layout", label: "Brief share of width",
                                            range: 0.1...0.5, defaultValue: 0.25)
    static let autoResponse = DebugTuningParameter(key: "spring.auto.response", group: "Spring · Auto columns", label: "Response (s)",
                                          range: 0.05...1.2, defaultValue: 0.42)
    static let autoDamping = DebugTuningParameter(key: "spring.auto.damping", group: "Spring · Auto columns", label: "Damping fraction",
                                         range: 0.2...1.2, defaultValue: 0.86)
    /// Brief ↔ full (2026-10-25 discussion): the anchored elements ride the column width's spring above.
    static let morphBurst = DebugTuningParameter(key: "morph.burst", group: "Brief ↔ full", label: "Burst out before the fling (pt)",
                                        range: 0...80, defaultValue: 28)
    static let morphSwirl = DebugTuningParameter(key: "morph.swirl", group: "Brief ↔ full", label: "Swirl of the burst (°)",
                                        range: -90...90, defaultValue: 35)
    static let morphPop = DebugTuningParameter(key: "morph.pop", group: "Brief ↔ full", label: "Landing pop (extra scale)",
                                      range: 0...0.4, defaultValue: 0.12)
    static let morphStagger = DebugTuningParameter(key: "morph.stagger", group: "Brief ↔ full", label: "Stagger (share of the way)",
                                          range: 0...0.12, defaultValue: 0.035)
    static let queueResponse = DebugTuningParameter(key: "spring.queue.response", group: "Spring · queue", label: "Response (s)",
                                           range: 0.05...1.2, defaultValue: 0.3)
    static let queueDamping = DebugTuningParameter(key: "spring.queue.damping", group: "Spring · queue", label: "Damping fraction",
                                          range: 0.2...1.2, defaultValue: 0.8)
    static let queueSwipeStep = DebugTuningParameter(key: "queue.swipeStep", group: "Spring · queue", label: "Trackpad swipe per step (pt)",
                                            range: 10...120, defaultValue: 36)
    static let modeResponse = DebugTuningParameter(key: "spring.mode.response", group: "Spring · Normie ↔ Organic", label: "Avatar flight response (s)",
                                          range: 0.1...1.2, defaultValue: 0.45)
    static let modeDamping = DebugTuningParameter(key: "spring.mode.damping", group: "Spring · Normie ↔ Organic", label: "Avatar flight damping",
                                         range: 0.3...1.2, defaultValue: 0.82)

    // S4 peek (spec §7).
    static let peekOpenDelay = DebugTuningParameter(key: "peek.openDelay", group: "Peek", label: "Open after hover (s)",
                                           range: 0...1, defaultValue: 0.25)
    static let peekCloseDelay = DebugTuningParameter(key: "peek.closeDelay", group: "Peek", label: "Close after leaving (s)",
                                            range: 0...1.5, defaultValue: 0.4)
    static let peekRecedeScale = DebugTuningParameter(key: "peek.recedeScale", group: "Peek", label: "Covered: scale",
                                             range: 0.9...1, defaultValue: 0.98)
    static let peekRecedeDim = DebugTuningParameter(key: "peek.recedeDim", group: "Peek", label: "Covered: darken",
                                           range: 0...0.3, defaultValue: 0.08)
    static let peekSquashResponse = DebugTuningParameter(key: "spring.peekSquash.response", group: "Peek", label: "Squash spring response (s)",
                                                range: 0.05...1, defaultValue: 0.26)
    static let peekSquashDamping = DebugTuningParameter(key: "spring.peekSquash.damping", group: "Peek", label: "Squash spring damping",
                                               range: 0.2...1.2, defaultValue: 0.5)
    static let peekResponse = DebugTuningParameter(key: "spring.peek.response", group: "Peek", label: "Ghost open spring (s)",
                                          range: 0.05...1, defaultValue: 0.3)

    // S5 Focused / Split (spec §6.2–6.4).
    static let focusResponse = DebugTuningParameter(key: "spring.focus.response", group: "Spring · Focused / Split", label: "Response (s)",
                                           range: 0.05...1.2, defaultValue: 0.4)
    static let focusDamping = DebugTuningParameter(key: "spring.focus.damping", group: "Spring · Focused / Split", label: "Damping fraction",
                                          range: 0.2...1.2, defaultValue: 0.82)
    static let graftReach = DebugTuningParameter(key: "graft.reach", group: "Spring · Focused / Split", label: "Graft: snap distance to bar (pt)",
                                        range: 0...80, defaultValue: 24)
    static let focusExitDistance = DebugTuningParameter(key: "focus.exitDistance", group: "Spring · Focused / Split",
                                               label: "me / segment drag-out distance (pt)", range: 10...160, defaultValue: 44)

    // Organic dock proportions (2026-10-24 review: follow the drawings' ratios to window height).
    static let dockHeightRatio = DebugTuningParameter(key: "dock.heightRatio", group: "Dock", label: "Dock height (× window height)",
                                             range: 0.04...0.12, defaultValue: 0.071)
    static let dockMinHeight = DebugTuningParameter(key: "dock.minHeight", group: "Dock", label: "Dock height min (pt)",
                                           range: 32...64, defaultValue: 40)
    static let dockMaxHeight = DebugTuningParameter(key: "dock.maxHeight", group: "Dock", label: "Dock height max (pt)",
                                           range: 44...96, defaultValue: 48)
    /// Under the dock: the sub-agents' row (4 + 24 pt) and 4 pt more, the same in Auto, Focused and Split, so moons
    /// coming and going never move the dock (2026-10-26, Astra's r3 shared geometry).
    static let dockBottom = DebugTuningParameter(key: "dock.bottom", group: "Dock", label: "Bottom margin (pt)",
                                        range: 12...48, defaultValue: 32)
    static let dockGapRatio = DebugTuningParameter(key: "dock.gapRatio", group: "Dock", label: "Gap above dock (× window height)",
                                          range: 0.01...0.08, defaultValue: 0.033)
    static let dockOrbGap = DebugTuningParameter(key: "dock.orbGap", group: "Dock", label: "Orb spacing (× orb size)",
                                        range: 0.2...1.5, defaultValue: 0.75)
    /// Dock magnification (2026-10-24 review r3, the macOS Dock's): orbs rest small and grow toward the pointer.
    static let dockOrbRest = DebugTuningParameter(key: "dock.orbRest", group: "Dock", label: "Orb at rest (× bar height)",
                                         range: 0.4...1, defaultValue: 0.67)
    static let dockMagnify = DebugTuningParameter(key: "dock.magnify", group: "Dock", label: "Orb magnified (× bar height)",
                                         range: 0.6...1.6, defaultValue: 1.0)
    static let dockMagnifyReach = DebugTuningParameter(key: "dock.magnifyReach", group: "Dock", label: "Magnification reach (orb slots)",
                                              range: 1...5, defaultValue: 2.4)
    /// The dock rises while it is typed in or under the pointer (2026-10-25, the user): a 48 pt dock lifts 12 pt, all of
    /// it together, its sizes unchanged (growing the bars re-laid out the editor on every frame: the focus lag in the
    /// user's review). me rests at 36 pt.
    static let dockMe = DebugTuningParameter(key: "dock.me", group: "Dock", label: "me (× bar height)",
                                    range: 0.5...1, defaultValue: 0.75)
    static let dockHoverRise = DebugTuningParameter(key: "dock.hoverRise", group: "Dock", label: "Typing / hover: dock rises (pt)",
                                           range: 0...30, defaultValue: 12)

    static let all: [DebugTuningParameter] = [.mockTick, .mockCharsPerTick, .mockEventInterval, .approvalDuration, .approvalBounce,
                                     .tearLongPress, .tearDragThreshold, .tearPreDragFollow, .tearLiftScale, .tearBand, .tearDetach, .tearStretch, .tearGlassSpacing,
                                     .tearResponse, .tearDamping,
                                     .growDuration, .growC1x, .growC1y, .growC2x, .growC2y, .growStart, .growFade,
                                     .orbSize, .orbLiquidWobble, .orbLiquidDeepen,
                                     .orbSatelliteSize, .orbSatelliteMinSpeed, .orbSatelliteMaxSpeed, .orbOrbitTilt, .orbOrbitWidth, .orbOrbitFlatten,
                                     .orbAlertBounce, .orbAlertPeriod, .orbBreathPeriod, .orbHoverResponse, .orbHoverDamping,
                                     .autoFullMin, .autoFullShare, .autoBriefComfort, .autoBriefMin, .autoBriefMax, .autoBriefShare, .autoLastBarMin,
                                     .autoResponse, .autoDamping, .morphBurst, .morphSwirl, .morphPop, .morphStagger, .queueResponse, .queueDamping, .queueSwipeStep,
                                     .modeResponse, .modeDamping,
                                     .peekOpenDelay, .peekCloseDelay, .peekRecedeScale, .peekRecedeDim,
                                     .peekSquashResponse, .peekSquashDamping, .peekResponse,
                                     .focusResponse, .focusDamping, .graftReach, .focusExitDistance,
                                     .dockHeightRatio, .dockMinHeight, .dockMaxHeight, .dockBottom, .dockGapRatio, .dockOrbGap,
                                     .dockOrbRest, .dockMagnify, .dockMagnifyReach, .dockMe, .dockHoverRise]
}


/// A single immutable application transaction. Hosts read the same snapshot for all
/// spring/geometry/flight values when compiling a motion; Reset cannot expose half defaults.
struct DebugTuningSnapshot: Equatable, Sendable {
    let values: [String: Double]
    let toggles: [String: Bool]
    static let defaults = DebugTuningSnapshot(
        values: Dictionary(uniqueKeysWithValues: DebugTuningParameter.all.map { ($0.key, $0.defaultValue) }),
        toggles: ["simulateReduceMotion":false,"playfulSummaries":true,"organicFullBleed":true,
                  "identityLiquid":true,"fullyFocused":false,"forceClickPeek":true])
    subscript(_ parameter: DebugTuningParameter) -> Double { values[parameter.key] ?? parameter.defaultValue }
    var playback: MockPlaybackSettings {
        let count = self[.mockCharsPerTick]
        let characters = count.isFinite ? Int(min(120,max(2,count))) : 16
        return MockPlaybackSettings(tickInterval:self[.mockTick], charactersPerTick:characters,
                                    backgroundEventInterval:self[.mockEventInterval]).normalized
    }
}

@MainActor final class DebugTuning {
    private(set) var values = DebugTuningSnapshot.defaults.values
    private(set) var toggles = DebugTuningSnapshot.defaults.toggles
    private(set) var revision: UInt64 = 0
    /// Legacy per-key callbacks remain available. Observers do not overwrite these hooks.
    var onChange: ((String,Double) -> Void)?
    var onToggle: ((String,Bool) -> Void)?
    private var observers: [UUID: (DebugTuningSnapshot) -> Void] = [:]
    private var publishing = false, pendingPublish = false
    var snapshot: DebugTuningSnapshot { .init(values:values, toggles:toggles) }
    subscript(_ p: DebugTuningParameter) -> Double { values[p.key] ?? p.defaultValue }
    @discardableResult func observe(deliverInitial: Bool = true, _ apply: @escaping (DebugTuningSnapshot) -> Void) -> UUID {
        let token = UUID(); observers[token] = apply
        if deliverInitial { apply(snapshot) }; return token
    }
    func removeObserver(_ token: UUID) { observers[token] = nil }
    @discardableResult func set(_ key: String, _ value: Double) -> Bool {
        guard value.isFinite, let p = DebugTuningParameter.all.first(where: { $0.key == key }) else { return false }
        var v = min(p.range.upperBound, max(p.range.lowerBound, value))
        if key == DebugTuningParameter.mockCharsPerTick.key { v = v.rounded(.towardZero) }
        guard values[key] != v else { return true }
        values[key] = v; revision &+= 1; onChange?(key,v); publish(); return true
    }
    @discardableResult func toggle(_ key: String) -> Bool {
        guard let old = toggles[key] else { return false }
        toggles[key] = !old; revision &+= 1; onToggle?(key,!old); publish(); return true
    }
    func reset() {
        let before = snapshot, defaults = DebugTuningSnapshot.defaults
        guard before != defaults else { return }
        values = defaults.values; toggles = defaults.toggles; revision &+= 1
        // All fields already contain defaults before any callback can inspect them.
        for p in DebugTuningParameter.all where before.values[p.key] != values[p.key] { onChange?(p.key,self[p]) }
        for key in toggles.keys.sorted() where before.toggles[key] != toggles[key] { onToggle?(key,toggles[key]!) }
        publish()
    }
    private func publish() {
        pendingPublish = true
        guard !publishing else { return }
        publishing = true; defer { publishing = false }
        while pendingPublish {
            pendingPublish = false; let next = snapshot
            for (token, apply) in Array(observers) where observers[token] != nil { apply(next) }
        }
    }
    func exportJSON(at date: Date = Date()) -> Data {
        (try? JSONSerialization.data(withJSONObject:["exportedAt":ISO8601DateFormatter().string(from:date),
            "params":values.mapValues { ($0*10000).rounded()/10000 },"toggles":toggles],
            options:[.prettyPrinted,.sortedKeys])) ?? Data()
    }
}
