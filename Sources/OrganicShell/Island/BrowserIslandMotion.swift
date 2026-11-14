import AppKit

/// The board's response/damping integrator, with retained velocity and a finite rest threshold.
struct BrowserIslandSpring {
    var value: Double
    var velocity = 0.0
    var target: Double
    init(_ value: Double) { self.value = value; target = value }
    var busy: Bool { value != target || velocity != 0 }
    mutating func snap(_ value: Double) { self.value = value; target = value; velocity = 0 }
    mutating func step(_ dt: Double, response: Double, damping: Double, reduced: Bool) {
        if reduced { snap(target); return }; guard busy, dt > 0 else { return }
        let omega = 6.2832 / response, n = max(1, Int(ceil(dt * 240))), h = dt / Double(n)
        for _ in 0..<n { velocity += (omega * omega * (target - value) - 2 * damping * omega * velocity) * h; value += velocity * h }
        if abs(target - value) < 0.002 && abs(velocity) < 0.02 { snap(target) }
    }
}

@MainActor final class BrowserIslandMotion {
    enum Mode: String { case address, site, cookies, tabs }
    private(set) var mode: Mode = .address
    private(set) var retiringMode: Mode?
    private var cardExitBegan = 0.0
    private var retiringViewBegan = 0.0
    private var active = false
    var contentMode: Mode { mode == .address ? retiringMode ?? .address : mode }
    private(set) var snapshot = BrowserSessionState()
    private(set) var time = 0.0
    private(set) var address = BrowserAddressLayout(host: "", rest: "", placeholder: true, width: 242)
    private(set) var rowOpacity = 1.0
    private(set) var pageOpacities: [BrowserPageID: Double] = [:]
    private(set) var label: String?
    private(set) var labelKey: String?
    private(set) var annotationHit: Int?
    private(set) var annotationOutline: Int?, annotationOpacity = 0.0
    private(set) var transcriptOpacity = 0.0, placeholderAmount = 1.0
    private(set) var pagePresence = 1.0
    var labelTextOpacity: Double { reduceMotion ? 1 : BrowserIslandMath.smooth((time - labelTextBegan) / 0.12) }
    var labelFrame: CGRect? {
        guard let key = labelKey else { return nil }
        let p = labelPresence.value, anchor = labelAnchor(key), direction = ["site", "reload", "back", "forward"].contains(key) ? 1.0 : -1.0
        let x = BrowserIslandMath.lerp(anchor.x, labelX.value, p), y = BrowserIslandMath.lerp(anchor.y - direction * 18, anchor.y, p)
        return CGRect(x: x - labelWidth.value / 2, y: y - 12, width: labelWidth.value, height: 24)
    }
    private(set) var spaceRejected = false
    private(set) var width = BrowserIslandSpring(242), height = BrowserIslandSpring(32), radius = BrowserIslandSpring(16)
    private(set) var addressWidth = BrowserIslandSpring(242), presence = BrowserIslandSpring(1)
    private(set) var lobes = [BrowserIslandSpring(0), BrowserIslandSpring(0), BrowserIslandSpring(0)]
    private(set) var labelPresence = BrowserIslandSpring(0), labelX = BrowserIslandSpring(0), labelWidth = BrowserIslandSpring(60)
    private(set) var cookieHeights = [BrowserIslandSpring(44), BrowserIslandSpring(44), BrowserIslandSpring(44)]
    private(set) var cookieOpacity = [1.0, 1.0, 1.0], emptyHeight = BrowserIslandSpring(0)
    private(set) var tabHeights = (0..<5).map { BrowserIslandSpring($0 < 3 ? 32 : 0) }
    private(set) var tabOpacity = [1.0, 1.0, 1.0, 0.0, 0.0]
    private(set) var loadingProgress = 0.0, loadingOpacity = 0.0, stopAmount = 0.0, annotationAmount = 0.0
    private(set) var viewBegan = 0.0, viewOpacity = 0.0
    private(set) var flightBegan: Double?, flightIncoming = true
    private var deadlines: [String: Double] = [:]
    private var cookieRemovals: [Int: Double] = [:]
    private var systemInside = false, tabsInside = false
    private var labelWanted: String?, rowTarget: BrowserPageID?, rowSwap: Double?, rowHold = 0.0
    private var lobeBegan = 0.0, lobeWanted = false
    private var loadCompleted: Double?, wantedPage: BrowserPageID?
    private var labelTextBegan = 0.0, temporaryLabel = false
    private(set) var permissionPositions = [0.0, 0.0, 2.0]
    private var permissionMoves: [Int: (Double, Double, Double)] = [:]
    private var annotationMove: (Double, Double, Double)?, outlineMove: (Double, Double, Double)?
    var available = CGRect(x: 30, y: 0, width: 580, height: 736)
    var hostDockCenter: CGPoint?
    var hostDockDiameter = 32.0
    var hostAdmissionFrame: CGRect?
    private var hostEarthFrom: CGRect?, hostReturnFrom: CGRect?
    var reduceMotion = false
    var pendingTaskCount: Int { deadlines.count }
    var orbitPaused: Bool { tabsInside || mode == .tabs || reduceMotion }
    var isBusy: Bool {
        width.busy || height.busy || radius.busy || addressWidth.busy || presence.busy || lobes.contains(where: \.busy) ||
        labelPresence.busy || labelX.busy || labelWidth.busy || cookieHeights.contains(where: \.busy) || emptyHeight.busy ||
        tabHeights.contains(where: \.busy) || rowSwap != nil || rowOpacity < 1 || flightBegan != nil ||
        loadCompleted != nil || snapshot.selectedTab?.pending != nil || !cookieRemovals.isEmpty ||
        (mode != .address && time < viewBegan + 0.52) || pageOpacities.values.contains { $0 > 0 && $0 < 1 } ||
        annotationAmount != (snapshot.annotationEnabled ? 1 : 0) || stopAmount != (snapshot.selectedTab?.pending == nil ? 0 : 1) ||
        loadingOpacity > 0 || annotationOpacity != (snapshot.annotationEnabled && annotationHit != nil ? 1 : 0) ||
        pagePresence != (pageVisible ? 1 : 0) || transcriptOpacity != (pageVisible ? 0 : 1) || placeholderAmount != (pageVisible ? 1 : 0) ||
        labelPresence.value > 0 && time < labelTextBegan + 0.12 ||
        !permissionMoves.isEmpty || tabOpacity.enumerated().contains { i, k in k != (snapshot.visibleTabSlots.contains(i) ? 1 : 0) }
    }
    var needsSamples: Bool { active && (isBusy || !deadlines.isEmpty || retiringMode != nil) }
    var nextDeadline: Double? { deadlines.values.min() }
    var full: Bool {
        if let began = flightBegan, time - began < 0.52 { return !flightIncoming }; return snapshot.full
    }
    var pageVisible: Bool {
        if let began = flightBegan { return time - began < 0.30 ? !flightIncoming : flightIncoming }; return snapshot.full
    }
    var capsule: CGRect {
        let p = BrowserIslandMath.clamp(presence.value, 0, 1.05), w = max(0, width.value * min(1, p)), h = min(height.value, w)
        let y = p >= 1 ? 104 : BrowserIslandMath.lerp(96, 120, BrowserIslandMath.smooth(p)) - h / 2
        return CGRect(x: 311.5 - w / 2, y: y, width: w, height: h)
    }
    var earthFrame: CGRect {
        if let dock = hostDockCenter {
            return hostFlight(from: hostEarthFrom, dock: dock, incoming: true)
        }
        if let began = flightBegan {
            return BrowserIslandMath.flight(from: flightIncoming ? BrowserIslandMetrics.dock : BrowserIslandMetrics.center,
                to: flightIncoming ? BrowserIslandMetrics.center : BrowserIslandMetrics.dock,
                diameterA: flightIncoming ? 32 : 56, diameterB: flightIncoming ? 56 : 32,
                sign: flightIncoming ? 1 : -1, time: time - began, delay: flightIncoming ? 0.06 : 0.12)
        }
        let c = snapshot.full ? BrowserIslandMetrics.center : BrowserIslandMetrics.dock, d = snapshot.full ? 56.0 : 32.0
        return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    }
    var mercuryFrame: CGRect {
        if let dock = hostDockCenter {
            return hostFlight(from: hostReturnFrom, dock: dock, incoming: false)
        }
        if let began = flightBegan {
            return BrowserIslandMath.flight(from: flightIncoming ? BrowserIslandMetrics.center : BrowserIslandMetrics.dock,
                to: flightIncoming ? BrowserIslandMetrics.dock : BrowserIslandMetrics.center,
                diameterA: flightIncoming ? 56 : 32, diameterB: flightIncoming ? 32 : 56,
                sign: flightIncoming ? -1 : 1, time: time - began, delay: flightIncoming ? 0.12 : 0.06)
        }
        let c = snapshot.full ? BrowserIslandMetrics.dock : BrowserIslandMetrics.center, d = snapshot.full ? 32.0 : 56.0
        return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
    }
    func reset(_ state: BrowserSessionState, at time: Double = 0) {
        hostEarthFrom = nil; hostReturnFrom = nil
        cancel(); active = true; self.time = time; snapshot = state; mode = .address; rowOpacity = 1
        let page = state.displayedPage ?? .a
        address = state.source == .live ? .live(state.selectedLiveTab?.url ?? "") : .make(MockBrowserSeed.pages[page]!)
        rowTarget = state.source == .live ? nil : page
        width.snap(state.full ? address.width : 188); addressWidth.snap(address.width); height.snap(32); radius.snap(16); presence.snap(1)
        wantedPage = state.committedPage; pageOpacities = Dictionary(uniqueKeysWithValues: BrowserPageID.allCases.map { ($0, $0 == state.committedPage ? 1 : 0) })
        syncCookieRows(state); for i in 0..<5 { let on = state.visibleTabSlots.contains(i); tabHeights[i].snap(on ? 32 : 0); tabOpacity[i] = on ? 1 : 0 }
        annotationAmount = state.annotationEnabled ? 1 : 0; annotationHit = nil; spaceRejected = false
        annotationOutline = nil; annotationOpacity = 0; transcriptOpacity = state.full ? 0 : 1; pagePresence = state.full ? 1 : 0; placeholderAmount = state.full ? 1 : 0
        annotationMove = nil; outlineMove = nil
        permissionPositions = [state.site?.camera.rawValue ?? 0, state.site?.microphone.rawValue ?? 0, state.site?.location.rawValue ?? 2].map(Double.init); permissionMoves = [:]
    }
    func receive(_ state: BrowserSessionState, event: BrowserSessionEvent) {
        if case .opened = event.payload { reset(state, at: event.metadata.time); return }
        let previous = snapshot; snapshot = state
        if !state.enabled { cancel(); return }
        if previous.annotationEnabled != state.annotationEnabled { annotationMove = (annotationAmount, state.annotationEnabled ? 1 : 0, event.metadata.time) }
        let choices = [state.site?.camera.rawValue ?? 0, state.site?.microphone.rawValue ?? 0, state.site?.location.rawValue ?? 2].map(Double.init)
        for i in 0..<3 where (permissionMoves[i]?.1 ?? permissionPositions[i]) != choices[i] {
            permissionMoves[i] = (permissionPositions[i], choices[i], event.metadata.time)
        }
        if previous.full != state.full { flightBegan = event.metadata.time; flightIncoming = state.full; closeCard(); systemInside = false; labelWanted = nil }
        if previous.displayedPage != state.displayedPage { rowTarget = state.displayedPage; rowSwap = event.metadata.time }
        if state.source == .live, previous.selectedLiveTab != state.selectedLiveTab {rowSwap=event.metadata.time}
        if previous.committedPage != state.committedPage { wantedPage = state.committedPage }
        if previous.selectedTab?.pending != nil && state.selectedTab?.pending == nil {
            if case .navigationCommitted = event.payload { loadCompleted = event.metadata.time } else { loadCompleted = nil }
        }
        if previous.selectedTabID != state.selectedTabID {
            if case .closedTab = event.payload { } else { closeCard() }
            syncCookieRows(state); annotationHit = nil
        }
        if case .removedCookies(let index) = event.payload {
            let indices = index.map { [$0] } ?? (0..<3).filter { previous.site?.cookies.indices.contains($0) == true && previous.site?.cookies[$0].removed == false }
            for (offset, i) in indices.enumerated() { cookieRemovals[i] = event.metadata.time + Double(offset) * 0.06 }
        }
    }
    /// Local window presentation never emits a shared session event.
    func presentHost(full: Bool, at time: Double) {
        sample(at: time)
        guard snapshot.full != full else { return }
        let earth = earthFrame, returning = mercuryFrame
        snapshot.full = full
        closeCard(); systemInside = false; labelWanted = nil
        if reduceMotion { reset(snapshot, at: time); return }
        hostEarthFrom = earth; hostReturnFrom = returning
        flightBegan = time; flightIncoming = full
    }
    private func hostFlight(from start: CGRect?, dock: CGPoint, incoming earth: Bool) -> CGRect {
        if earth,!snapshot.full,flightBegan == nil,let hostAdmissionFrame {return hostAdmissionFrame}
        let atHeader = earth ? snapshot.full : !snapshot.full
        let target = atHeader ? BrowserIslandMetrics.center : dock
        let diameter = atHeader ? 56.0 : hostDockDiameter
        if let began = flightBegan, let start {
            return BrowserIslandMath.flight(from: CGPoint(x: start.midX, y: start.midY), to: target,
                diameterA: start.width, diameterB: diameter, sign: atHeader ? 1 : -1,
                time: time-began, delay: atHeader ? 0.06 : 0.12)
        }
        return CGRect(x: target.x-diameter/2, y: target.y-diameter/2, width: diameter, height: diameter)
    }
    private func syncCookieRows(_ state: BrowserSessionState) {
        for i in 0..<3 { let on = state.site.map { $0.cookies.indices.contains(i) && !$0.cookies[i].removed } ?? false; cookieHeights[i].snap(on ? 44 : 0); cookieOpacity[i] = on ? 1 : 0 }
        emptyHeight.snap(state.site?.cookieCount == 0 ? 40 : 0); cookieRemovals = [:]
    }
    func input(_ input: BrowserMockInput, at time: Double) {
        sample(at: time)
        switch input {
        case .reset: reset(snapshot, at: time)
        case .pointer(let x, let y):
            annotationHit = Self.annotationBlock(at: CGPoint(x: x, y: y), page: snapshot.committedPage, enabled: snapshot.annotationEnabled)
            if let annotationHit { annotationOutline = annotationHit }
        case .hover(let key, let inside): hover(key, inside: inside)
        case .action(let action):
            switch action {
            case .siteInformation: if mode == .site || mode == .cookies { closeCard() } else if snapshot.site != nil { open(.site) }
            case .manageCookies: open(.cookies)
            case .cookieBack, .done: open(.site)
            case .background: closeCard()
            case .selectTab, .newTab: closeCard()
            case .annotation: if !snapshot.annotationEnabled { annotationHit = nil }; syncLabel()
            case .external: flash("external", "Opened in your default browser")
            case .extensions: flash("extensions", "No extensions installed")
            case .options: flash("options", "Zoom, Reader and Translate")
            default: break
            }
        }
        retarget()
        if reduceMotion { sample(at: time) }
    }
    private func hover(_ key: String?, inside: Bool) {
        guard let key else { systemInside = false; tabsInside = false; deadlines["systemOut"] = time + 0.28; deadlines["tabsOut"] = time + 0.30; return }
        if key.hasPrefix("moon:") || key == "tabs" {
            guard snapshot.full, flightBegan == nil else { return }
            tabsInside = inside
            if inside { deadlines["tabsOut"] = nil; if mode == .address { deadlines["tabsIn"] = time + 0.10 } }
            else { deadlines["tabsIn"] = nil; deadlines["tabsOut"] = time + 0.30 }
            return
        }
        if snapshot.source == .live {return}
        guard snapshot.full, flightBegan == nil else { return }
        if inside { systemInside = true; deadlines["systemOut"] = nil }
        else { deadlines["systemOut"] = time + 0.28 }
        if Self.labels[key] != nil {
            if inside { labelWanted = key; deadlines["labelOut"] = nil; deadlines["labelIn"] = time + (labelKey == nil ? 0.35 : 0.05) }
            else if labelWanted == key { labelWanted = nil; deadlines["labelIn"] = nil; deadlines["labelOut"] = time + 0.10 }
        }
    }
    private func open(_ next: Mode) {
        let targetHeight = next == .site ? 296.0 : next == .cookies ? cookieHeight : tabHeight, targetWidth = next == .tabs ? 300.0 : 320.0
        let rect = CGRect(x: 311.5 - targetWidth / 2, y: 104, width: targetWidth, height: targetHeight)
        guard available.contains(rect) else {
            spaceRejected = true; labelWanted = nil; labelKey = nil; label = nil; temporaryLabel = false; labelPresence.target = 0
            deadlines["labelIn"] = nil; deadlines["labelOut"] = nil; deadlines["temporaryLabel"] = nil
            return
        }
        if mode != .address && mode != next { retiringMode = mode; retiringViewBegan = viewBegan; cardExitBegan = time }
        mode = next; viewBegan = time; viewOpacity = 1; systemInside = false; labelWanted = nil; labelKey = nil; labelPresence.target = 0
        deadlines["labelIn"] = nil; deadlines["labelOut"] = nil
    }
    func closeCard() {
        if mode != .address { retiringMode = reduceMotion ? nil : mode; retiringViewBegan = viewBegan; cardExitBegan = time }
        mode = .address; tabsInside = false; deadlines["tabsIn"] = nil; deadlines["tabsOut"] = nil
    }
    private var cookieHeight: Double { 70 + cookieHeights.reduce(0) { $0 + $1.value } + emptyHeight.value + 50 }
    private var tabHeight: Double { 40 + tabHeights.reduce(0) { $0 + $1.value } + 47 }
    private func flash(_ key: String, _ text: String) {
        labelKey = key; labelWanted = key; label = text; temporaryLabel = true; labelTextBegan = time
        deadlines["temporaryLabel"] = time + 1.6; systemInside = true; deadlines["systemOut"] = nil
    }
    private func syncLabel() {
        guard let key = labelKey, !temporaryLabel else { return }
        let next = key == "reload" && snapshot.selectedTab?.pending != nil ? "Stop" : key == "annotation" && snapshot.annotationEnabled ? "Annotation Mode · On" : Self.labels[key]
        if label != next { label = next; labelTextBegan = time }
    }
    private func retarget() {
        addressWidth.target = address.width
        width.target = mode == .site || mode == .cookies ? 320 : mode == .tabs ? 300 : full ? address.width : 188
        height.target = mode == .site ? 296 : mode == .cookies ? cookieHeight : mode == .tabs ? tabHeight : 32
        radius.target = mode == .address ? 16 : 20
        let left = 311.5 - addressWidth.value / 2, right = 311.5 + addressWidth.value / 2
        let toolsAndNavigation = CGRect(x: left - 82, y: 56, width: max(493.5, right + 42) - (left - 82), height: 80)
        let wanted = snapshot.source != .live && systemInside && mode == .address && snapshot.full && flightBegan == nil && available.contains(toolsAndNavigation)
        if wanted != lobeWanted { lobeWanted = wanted; lobeBegan = time }
        for i in 0..<3 {
            let delay = wanted ? [0.0, 0.05, 0.11][i] : [0.06, 0.03, 0.0][i]
            if reduceMotion || time - lobeBegan >= delay { lobes[i].target = wanted ? 1 : 0 }
        }
        let permitted = labelKey != nil && mode == .address && snapshot.full && flightBegan == nil &&
            (labelKey == "site" || lobes[labelKey == "back" || labelKey == "forward" ? 0 : labelKey == "reload" ? 1 : 2].value >= 0.85)
        labelPresence.target = permitted && (labelWanted == labelKey || temporaryLabel) ? 1 : 0
        if let key = labelKey, let text = label {
            labelWidth.target = Double((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 20
            let x = labelAnchor(key).x
            labelX.target = BrowserIslandMath.clamp(x, max(44, available.minX) + labelWidth.target / 2, min(594, available.maxX) - labelWidth.target / 2)
            if labelX.value == 0 { labelX.snap(labelX.target); labelWidth.snap(labelWidth.target) }
        }
    }
    func sample(at target: Double) {
        guard target.isFinite, target >= time else { return }
        let delta = target - time
        if delta > 1.0 / 120 {
            let count = Int(ceil(delta * 120))
            let start = time
            for i in 1...count { sampleStep(at: start + Double(i) * delta / Double(count)) }
        } else { sampleStep(at: target) }
    }
    private func sampleStep(at nextTime: Double) {
        let dt = nextTime - time; time = nextTime
        for (i, move) in permissionMoves {
            let p = reduceMotion ? 1 : min(1, (time - move.2) / 0.30)
            permissionPositions[i] = BrowserIslandMath.lerp(move.0, move.1, BrowserIslandMath.bezier(p, (0.22, 1, 0.36, 1)))
            if p >= 1 { permissionMoves[i] = nil }
        }
        for (key, deadline) in deadlines.sorted(by: { $0.key < $1.key }) where deadline <= time {
            deadlines[key] = nil
            switch key {
            case "systemOut": systemInside = false
            case "tabsIn": if tabsInside && mode == .address { open(.tabs) }
            case "tabsOut": if !tabsInside && mode == .tabs { closeCard() }
            case "labelIn": if let wanted = labelWanted {
                let upper = ["annotation", "external", "extensions", "options"]
                if let current = labelKey, upper.contains(current) != upper.contains(wanted) { labelPresence.snap(0); labelX.snap(0) }
                labelKey = wanted; labelTextBegan = time; temporaryLabel = false; syncLabel()
            }
            case "labelOut": labelWanted = nil
            case "temporaryLabel": temporaryLabel = false; labelWanted = nil; systemInside = false; syncLabel()
            default: break
            }
        }
        if let began = flightBegan {
            let t = time - began
            presence.target = t >= 0.52 || t < 0.09 ? 1 : 0
            if t >= 0.82 || reduceMotion { flightBegan = nil; presence.target = 1 }
        } else { presence.target = 1 }
        if let began = rowSwap {
            if time - began < 0.09 && !reduceMotion { rowOpacity = max(0, 1 - (time - began) / 0.09) }
            else {
                if snapshot.source == .live {address = .live(snapshot.selectedLiveTab?.url ?? "")}
                else if let page = rowTarget { address = .make(MockBrowserSeed.pages[page]!) }
                rowSwap = nil; rowHold = time + (reduceMotion ? 0 : 0.04); rowOpacity = 0
            }
        } else if time >= rowHold, abs(addressWidth.value - address.width) < 14 || mode != .address { rowOpacity = reduceMotion ? 1 : min(1, rowOpacity + dt / 0.12) }
        for (i, began) in cookieRemovals where reduceMotion || time >= began {
            cookieOpacity[i] = reduceMotion ? 0 : max(0, 1 - (time - began) / 0.10)
            if cookieOpacity[i] < 0.4 { cookieHeights[i].target = 0 }
        }
        emptyHeight.target = snapshot.site?.cookieCount == 0 ? 40 : 0
        for i in 0..<5 {
            let on = snapshot.visibleTabSlots.contains(i); tabHeights[i].target = on ? 32 : 0
            tabOpacity[i] = reduceMotion ? (on ? 1 : 0) : on ? min(1, tabOpacity[i] + dt / 0.14) : max(0, tabOpacity[i] - dt / 0.10)
        }
        if reduceMotion {
            for i in 0..<3 { cookieHeights[i].snap(cookieHeights[i].target) }; emptyHeight.snap(emptyHeight.target)
            for i in 0..<5 { tabHeights[i].snap(tabHeights[i].target) }
        }
        retarget()
        width.step(dt, response: mode == .address ? 0.30 : 0.34, damping: mode == .address ? 0.90 : 0.80, reduced: reduceMotion)
        addressWidth.step(dt, response: 0.34, damping: 0.80, reduced: reduceMotion)
        height.step(dt, response: mode == .address ? 0.30 : 0.42, damping: mode == .address ? 0.90 : 0.84, reduced: reduceMotion)
        radius.step(dt, response: 0.42, damping: 0.84, reduced: reduceMotion)
        presence.step(dt, response: presence.target == 1 ? 0.36 : 0.20, damping: presence.target == 1 ? 0.80 : 0.95, reduced: reduceMotion)
        for i in 0..<3 { lobes[i].step(dt, response: lobes[i].target == 1 ? 0.40 : 0.30, damping: lobes[i].target == 1 ? 0.78 : 0.92, reduced: reduceMotion); cookieHeights[i].step(dt, response: 0.32, damping: 0.90, reduced: reduceMotion) }
        emptyHeight.step(dt, response: 0.32, damping: 0.90, reduced: reduceMotion)
        for i in 0..<5 { tabHeights[i].step(dt, response: 0.30, damping: 0.90, reduced: reduceMotion) }
        labelPresence.step(dt, response: 0.32, damping: 0.80, reduced: reduceMotion)
        labelX.step(dt, response: 0.28, damping: 0.86, reduced: reduceMotion); labelWidth.step(dt, response: 0.28, damping: 0.86, reduced: reduceMotion)
        for i in cookieRemovals.keys.filter({ cookieHeights[$0].value == 0 }) { cookieRemovals[i] = nil }
        viewOpacity = mode == .address ? 0 : 1
        if reduceMotion || time - cardExitBegan >= 0.09 { retiringMode = nil }
        let otherVisible = pageOpacities.contains { $0.key != wantedPage && $0.value > 0 }
        for page in BrowserPageID.allCases {
            let k = pageOpacities[page] ?? 0
            pageOpacities[page] = reduceMotion ? (page == wantedPage ? 1 : 0) : page == wantedPage ? (otherVisible ? k : min(1, k + dt / 0.16)) : max(0, k - dt / 0.09)
        }
        if let pending = snapshot.selectedTab?.pending {
            loadCompleted = nil
            loadingProgress = 0.08 + 0.82 * (1 - exp(-2.6 * max(0, time - pending.began) / pending.duration)); loadingOpacity = min(1, loadingOpacity + dt / 0.10)
        } else if let completed = loadCompleted {
            loadingProgress = min(1, loadingProgress + dt / 0.18); loadingOpacity = max(0, 1 - (time - completed - 0.18) / 0.30)
            if loadingOpacity == 0 || reduceMotion { loadCompleted = nil; loadingOpacity = 0; loadingProgress = 0 }
        } else { loadingOpacity = max(0, loadingOpacity - dt / 0.12) }
        let stop = snapshot.selectedTab?.pending != nil, anno = snapshot.annotationEnabled
        stopAmount = reduceMotion ? (stop ? 1 : 0) : stop ? min(1, stopAmount + dt / 0.10) : max(0, stopAmount - dt / 0.10)
        if let move = annotationMove {
            let p = reduceMotion ? 1 : min(1, max(0, (time - move.2) / 0.26))
            annotationAmount = BrowserIslandMath.lerp(move.0, move.1, BrowserIslandMath.bezier(p, (0.25, 0.1, 0.25, 1)))
            if p == 1 { annotationMove = nil }
        } else { annotationAmount = anno ? 1 : 0 }
        let outlineTarget = anno && annotationHit != nil ? 1.0 : 0.0
        if outlineTarget != (outlineMove?.1 ?? annotationOpacity) { outlineMove = (annotationOpacity, outlineTarget, time - dt) }
        if let move = outlineMove {
            let p = reduceMotion ? 1 : min(1, max(0, (time - move.2) / 0.12))
            annotationOpacity = BrowserIslandMath.lerp(move.0, move.1, BrowserIslandMath.bezier(p, (0.25, 0.1, 0.25, 1)))
            if p == 1 { outlineMove = nil }
        }
        if annotationOpacity == 0 { annotationOutline = nil }
        let showPage = pageVisible
        pagePresence = reduceMotion ? (showPage ? 1 : 0) : showPage ? min(1, pagePresence + dt / 0.16) : max(0, pagePresence - dt / 0.09)
        transcriptOpacity = reduceMotion ? (showPage ? 0 : 1) : showPage ? max(0, transcriptOpacity - dt / 0.14) : min(1, transcriptOpacity + dt / 0.20)
        placeholderAmount = reduceMotion ? (showPage ? 1 : 0) : showPage ? min(1, placeholderAmount + dt / 0.24) : max(0, placeholderAmount - dt / 0.24)
        syncLabel()
    }
    func cancel() {
        active = false; retiringMode = nil; permissionMoves = [:]; annotationMove = nil; outlineMove = nil
        deadlines.removeAll(); cookieRemovals.removeAll(); flightBegan = nil; rowSwap = nil; loadCompleted = nil
        systemInside = false; tabsInside = false; labelWanted = nil; labelKey = nil; label = nil
        lobes = [BrowserIslandSpring(0), BrowserIslandSpring(0), BrowserIslandSpring(0)]; labelPresence.snap(0)
        labelX.snap(0); labelWidth.snap(60); loadingOpacity = 0; loadingProgress = 0; stopAmount = 0
    }
    func rowAlpha(_ index: Int, for view: Mode? = nil) -> Double {
        let retiring = view != nil && view == retiringMode
        let opacity = retiring ? max(0, 1 - (time - cardExitBegan) / 0.09) : viewOpacity
        let began = retiring ? retiringViewBegan : viewBegan
        return reduceMotion ? (retiring ? 0 : 1) : min(opacity, BrowserIslandMath.smooth((time - began - 0.10 - Double(index) * 0.035) / 0.14))
    }
    func labelAnchor(_ key: String) -> CGPoint {
        let left = 311.5 - addressWidth.value / 2, right = 311.5 + addressWidth.value / 2
        switch key {
        case "back": return CGPoint(x: left - 10 - 72 + 19.5, y: 156)
        case "forward": return CGPoint(x: left - 10 - 19.5, y: 156)
        case "reload": return CGPoint(x: right + 26, y: 156)
        case "site": return CGPoint(x: left + 18, y: 156)
        default: let i = ["annotation", "external", "extensions", "options"].firstIndex(of: key) ?? 0; return CGPoint(x: 389.5 + Double(i) * 28, y: 36)
        }
    }
    func lobePose(_ index: Int) -> BrowserLobePose {
        let p = lobes[index].value, left = 311.5 - addressWidth.value / 2, right = 311.5 + addressWidth.value / 2
        let rect = index == 0 ? CGRect(x: left - 82, y: 104, width: 72, height: 32) : index == 1 ? CGRect(x: right + 10, y: 104, width: 32, height: 32) : BrowserIslandMetrics.tools
        let start = index == 0 ? CGPoint(x: left + 12, y: 120) : index == 1 ? CGPoint(x: right - 12, y: 120) : BrowserIslandMetrics.toolsOrigin
        let x = BrowserIslandMath.lerp(start.x, rect.midX, p), y = BrowserIslandMath.lerp(start.y, rect.midY, p)
        let w = BrowserIslandMath.lerp(16, rect.width, p), h = BrowserIslandMath.lerp(16, 32, min(1.03, p * 1.3))
        let alpha = BrowserIslandMath.smooth((p - 0.55) / 0.30)
        return .init(frame: CGRect(x: x - w / 2, y: y - h / 2, width: max(0, w), height: max(0, h)),
                     neckStart: CGPoint(x: index == 0 ? left + 4 : index == 1 ? right - 4 : start.x, y: start.y),
                     neckEnd: CGPoint(x: x + (index == 0 ? w / 2 - h / 2 : -w / 2 + h / 2), y: y),
                     neckWidth: 15 * (1 - BrowserIslandMath.smooth((p - 0.30) / 0.45)) * min(1, p * 6),
                     contentAlpha: alpha, contentScale: 0.9 + 0.1 * alpha, contentBlur: 6 * (1 - alpha))
    }
    static let labels = ["back": "Back", "forward": "Forward", "reload": "Reload", "site": "View Site Information", "annotation": "Annotation Mode", "external": "Open in External Browser", "extensions": "Extensions", "options": "Browser Options"]
    static let annotationBlocks = [CGRect(x: 24, y: 66, width: 260, height: 52), CGRect(x: 24, y: 132, width: 300, height: 372), CGRect(x: 348, y: 132, width: 198, height: 148), CGRect(x: 348, y: 324, width: 198, height: 64), CGRect(x: 24, y: 528, width: 260, height: 22)]
    static func annotationBlock(at point: CGPoint, page: BrowserPageID?, enabled: Bool) -> Int? {
        guard enabled, page == .a else { return nil }; let local = CGPoint(x: point.x - 14, y: point.y - 150)
        return annotationBlocks.indices.last { annotationBlocks[$0].contains(local) }
    }
}
