import Foundation

enum SunHoverSatellite: Int, CaseIterable, Sendable {
    case newChat, addToDock, search, sidebar, usage, settings
}
enum SunHoverPanel: String, Sendable { case attention, usage, account }
enum SunHoverMode: Equatable, Sendable { case idle, open, panel(SunHoverPanel), picker }

/// Semantic inputs contain identities, never a retained row number, view, window or responder.
enum SunHoverAction: Equatable, Sendable {
    case newChat, search, sidebar, profile, settings, shortcuts, collapse, signOut
    case conversation(String)
}

/// Window-local state. The caller supplies a monotonic clock and drives tick(); there are no timers/monitors here.
@MainActor final class SunHoverState {
    enum Region: Hashable { case ll, badge, satellite(SunHoverSatellite), label(SunHoverSatellite), zone, panel, picker }
    enum EscapeResult { case ignored, cancelComposition, closedLayer }
    private let clock: () -> Double
    let reduceMotion: Bool
    private(set) var mode: SunHoverMode = .idle
    private(set) var regions: Set<Region> = []
    private(set) var suppressed = false
    private var outsideSince: Double?, llSince: Double?, badgeSince: Double?, returnSince: Double?
    private var panelLeft = false
    private var heldLabelUntil: Double = -.infinity
    private var desiredLabel: SunHoverSatellite?
    private(set) var activeLabel: SunHoverSatellite?
    private(set) var satellites = SunHoverSatellite.allCases.map { _ in SunHoverMotion(0) }
    private(set) var labels = SunHoverSatellite.allCases.map { _ in SunHoverMotion(0) }
    private(set) var number = SunHoverMotion(0)
    private(set) var sun = SunHoverMotion(0)
    private(set) var ring = SunHoverMotion(0)
    private(set) var panel = SunHoverMotion(0)
    private(set) var pickerTop = SunHoverMotion(0), pickerBottom = SunHoverMotion(0)
    private(set) var pickerWidth = SunHoverMotion(0), pickerSearch = SunHoverMotion(0)
    private(set) var panelKind: SunHoverPanel?
    private(set) var panelChangedAt: Double = 0
    private(set) var panelRowIDs: [String] = []
    private var exitingRows: [String: (Double, Double)] = [:]
    private var enteringRows: [String: Double] = [:]
    private(set) var foldStartedAt: Double?
    private var foldPending = false

    init(reduceMotion: Bool = false, clock: @escaping () -> Double) {
        self.clock = clock; self.reduceMotion = reduceMotion
    }
    var now: Double { clock() }
    var showsNumber: Bool { number.target == 1 }
    var hasPendingFold: Bool { foldPending }
    var ringDrawsImmediately: Bool { reduceMotion }
    var searchCanTakeFocus: Bool { mode == .picker && pickerSearch.value(at: now) > 0.004 }

    /// The host sleeps between semantic deadlines. Settled hover never needs a display callback.
    var nextDeadline: Double? {
        let t = now
        var deadlines: [Double] = []
        if mode != .idle && mode != .picker, let outsideSince { deadlines.append(outsideSince + SunHoverParameters.grace) }
        if mode == .open && !suppressed, let badgeSince { deadlines.append(badgeSince + SunHoverParameters.badgeDwell) }
        if mode != .idle, let llSince { deadlines.append(llSince + SunHoverParameters.numberDwell) }
        if case .panel = mode, let returnSince { deadlines.append(returnSince + SunHoverParameters.sunBack) }
        if heldLabelUntil.isFinite { deadlines.append(heldLabelUntil) }
        return deadlines.filter { $0 > t + 1e-9 }.min()
    }
    var needsFrames: Bool {
        let channels = satellites + labels + [sun, ring, number, panel, pickerTop, pickerBottom, pickerWidth, pickerSearch]
        return hasPendingFold || channels.contains { $0.isMoving(at: now) }
            || enteringRows.values.contains { now < $0 + SunHoverParameters.rowIn }
            || exitingRows.values.contains { now < $0.1 + SunHoverParameters.rowOut }
    }

    func pointer(in next: Set<Region>) {
        let t = now
        if next.contains(.ll), !regions.contains(.ll) { llSince = t }
        if !next.contains(.ll) { llSince = nil; if suppressed { suppressed = false } }
        if next.contains(.badge), !regions.contains(.badge) { badgeSince = t }
        if !next.contains(.badge) { badgeSince = nil }
        if case .panel = mode {
            if !next.contains(.ll) { panelLeft = true; returnSince = nil }
            else if panelLeft && !regions.contains(.ll) { returnSince = t }
        }
        let hovered = SunHoverSatellite.allCases.first { next.contains(.satellite($0)) || next.contains(.label($0)) }
        if let hovered { desiredLabel = hovered; heldLabelUntil = .infinity }
        else if desiredLabel != nil, heldLabelUntil == .infinity { heldLabelUntil = t + SunHoverParameters.labelGrace }
        regions = next
        if next.isEmpty { if outsideSince == nil { outsideSince = t } } else { outsideSince = nil }
        if mode == .idle, !suppressed, next.contains(.ll) { setMode(.open, at: t) }
        tick()
    }

    func tick() {
        let t = now
        if mode != .picker, let outsideSince, t - outsideSince + 1e-9 >= SunHoverParameters.grace {
            dismiss(at: t, suppress: false)
        }
        if mode == .open, !suppressed, let badgeSince, t - badgeSince + 1e-9 >= SunHoverParameters.badgeDwell { showPanel(.attention) }
        if case .panel = mode, let returnSince, t - returnSince + 1e-9 >= SunHoverParameters.sunBack { setMode(.open, at: t) }
        let numeric = (mode != .idle && llSince.map { t - $0 + 1e-9 >= SunHoverParameters.numberDwell } == true)
            || (mode == .open && regions.contains(.satellite(.usage))) || mode == .panel(.usage)
        number.aim(numeric ? 1 : 0, at: t, spring: SunHoverParameters.number)
        updateLabels(at: t)
        if foldPending, labels.allSatisfy({ $0.value(at: t) <= SunHoverParameters.labelGone }) { beginFold(at: t) }
    }

    private func updateLabels(at t: Double) {
        if t >= heldLabelUntil { desiredLabel = nil }
        let wanted = mode == .open ? desiredLabel : nil
        for key in SunHoverSatellite.allCases where key != wanted {
            labels[key.rawValue].aim(0, at: t, spring: SunHoverParameters.labelOut)
            if labels[key.rawValue].value(at: t) <= SunHoverParameters.labelGone { labels[key.rawValue] = SunHoverMotion(0) }
        }
        if let activeLabel, activeLabel != wanted, labels[activeLabel.rawValue].value(at: t) <= SunHoverParameters.labelPass {
            self.activeLabel = nil
        }
        if let wanted, labelMayOpen(wanted, at: t),
           SunHoverSatellite.allCases.filter({ $0 != wanted }).allSatisfy({ labels[$0.rawValue].value(at: t) <= SunHoverParameters.labelPass }) {
            activeLabel = wanted
            // Reentering the same closing label must reverse it, not leave its target at zero.
            labels[wanted.rawValue].aim(1, at: t, spring: SunHoverParameters.label)
        }
    }
    func labelMayOpen(_ key: SunHoverSatellite, at t: Double) -> Bool {
        let i = key.rawValue
        return (max(0, i - 1)...min(5, i + 1)).allSatisfy {
            abs(satellites[$0].value(at: t) - 1) * SunHoverParameters.arcLengths[$0] <= SunHoverParameters.labelSettle
        }
    }
    func canClick(_ key: SunHoverSatellite) -> Bool {
        mode == .open && !foldPending && satellites[key.rawValue].value(at: now) > 0.6
    }
    func canClickLabel(_ key: SunHoverSatellite) -> Bool {
        canClick(key) && activeLabel == key && labels[key.rawValue].value(at: now) > 0.5
    }
    func llClick() { if mode == .picker { setMode(.open, at: now) } else { showPanel(.account) } }
    func click(_ key: SunHoverSatellite) -> SunHoverAction? {
        guard canClick(key) else { return nil }
        switch key {
        case .usage: showPanel(.usage); return nil
        case .settings: showPanel(.account); return nil
        case .addToDock: setMode(.picker, at: now); return nil
        case .newChat: dismiss(at: now, suppress: true); return .newChat
        case .search: dismiss(at: now, suppress: true); return .search
        case .sidebar: dismiss(at: now, suppress: true); return .sidebar
        }
    }
    func showPanel(_ kind: SunHoverPanel) {
        panelLeft = !regions.contains(.ll); returnSince = nil; panelKind = kind
        setMode(.panel(kind), at: now)
    }
    func setPanelRows(_ ids: [String]) {
        let t = now, unique = ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for id in panelRowIDs where !unique.contains(id) { exitingRows[id] = (rowVisibility(id, at: t), t); enteringRows[id] = nil }
        for (i, id) in unique.enumerated() where !panelRowIDs.contains(id) {
            enteringRows[id] = t + SunHoverParameters.rowDelay + Double(i) * SunHoverParameters.rowStagger
            exitingRows[id] = nil
        }
        panelRowIDs = unique
    }
    func rowVisibility(_ id: String, at t: Double) -> Double {
        if let (initial, end) = exitingRows[id] { return initial * (1 - SunHoverGeometry.smooth((t - end) / SunHoverParameters.rowOut)) }
        guard let start = enteringRows[id] else { return 0 }
        return SunHoverGeometry.smooth((t - start) / SunHoverParameters.rowIn)
    }
    func selectConversation(_ id: String, isStillActionable: (String) -> Bool) -> SunHoverAction? {
        guard mode == .panel(.attention), panel.value(at: now) > 0.5, panelRowIDs.contains(id),
              rowVisibility(id, at: now) > 0.5, isStillActionable(id) else { return nil }
        dismiss(at: now, suppress: true); return .conversation(id)
    }
    func escape(hasMarkedText: Bool = false) -> EscapeResult {
        if mode == .picker && hasMarkedText { return .cancelComposition }
        switch mode {
        case .panel, .picker: setMode(.open, at: now); suppressed = true; badgeSince = nil; returnSince = nil
        case .open: dismiss(at: now, suppress: true)
        case .idle: return .ignored
        }
        return .closedLayer
    }
    /// The host consumes the outside click if this returns true.
    func outsideClick() -> Bool { guard mode != .idle else { return false }; dismiss(at: now, suppress: true); return true }
    func dragBegan() { dismiss(at: now, suppress: true) }
    func retire(suppressUntilExit: Bool = true) { regions = []; dismiss(at: now, suppress: suppressUntilExit) }
    private func dismiss(at t: Double, suppress: Bool) {
        setMode(.idle, at: t); suppressed = suppress
        llSince = nil; badgeSince = nil; returnSince = nil; outsideSince = nil
    }
    private func setMode(_ next: SunHoverMode, at t: Double) {
        guard next != mode else { return }
        let old = mode; mode = next
        sun.aim(next == .idle ? 0 : 1, at: t, spring: SunHoverParameters.sun)
        ring.aim(next == .idle ? 0 : 1, at: t, spring: SunHoverParameters.ring, instant: reduceMotion)
        let isPanel: Bool = { if case .panel = next { return true }; return false }()
        panel.aim(isPanel ? 1 : 0, at: t, spring: isPanel ? SunHoverParameters.panel : SunHoverParameters.panelOut)
        panelChangedAt = t
        if !isPanel { setPanelRows([]) }
        let picking = next == .picker, wasPicking = old == .picker
        if wasPicking && !picking { outsideSince = regions.isEmpty ? t : nil }
        if picking || wasPicking {
            let hold = picking ? 0 : SunHoverParameters.closeHold
            pickerTop.aim(picking ? 1 : 0, at: t, delay: hold, spring: picking ? SunHoverParameters.pickerTop : SunHoverParameters.panelOut)
            pickerBottom.aim(picking ? 1 : 0, at: t, delay: (picking ? 0.03 : hold), spring: picking ? SunHoverParameters.pickerBottom : SunHoverParameters.panelOut)
            pickerWidth.aim(picking ? 1 : 0, at: t, delay: (picking ? 0.05 : hold), spring: picking ? SunHoverParameters.pickerWidth : SunHoverParameters.panelOut)
            pickerSearch.aim(picking ? 1 : 0, at: t, delay: (picking ? 0.16 : 0), spring: picking ? SunHoverParameters.search : SunHoverParameters.panelOut)
        }
        desiredLabel = nil; heldLabelUntil = -.infinity
        for i in labels.indices { labels[i].aim(0, at: t, spring: SunHoverParameters.labelOut) }
        if next == .open {
            foldPending = false; foldStartedAt = nil
            for i in satellites.indices {
                satellites[i].aim(1, at: t, delay: (reduceMotion ? 0 : Double(5 - i) * 0.04),
                                  spring: SunHoverParameters.deal, fadeDuration: reduceMotion ? 0.12 : nil)
            }
        } else { foldPending = true; tickFold(at: t) }
    }
    private func tickFold(at t: Double) {
        if labels.allSatisfy({ $0.value(at: t) <= SunHoverParameters.labelGone }) { beginFold(at: t) }
    }
    private func beginFold(at t: Double) {
        foldPending = false; foldStartedAt = t
        for i in satellites.indices {
            let keep = mode == .picker && i == SunHoverSatellite.addToDock.rawValue
            satellites[i].aim(keep ? 1 : 0, at: t, delay: (reduceMotion ? 0 : Double(i) * 0.022),
                              spring: SunHoverParameters.fold, fadeDuration: reduceMotion ? 0.12 : nil)
        }
    }
}
