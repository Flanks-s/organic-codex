import Foundation

/// A finite input script and an in-memory transport. Its owner supplies elapsed time; it owns no clock.
@MainActor final class MockBrowserReplay {
    struct Step: Equatable { let time: Double; let input: BrowserMockInput }
    let store: BrowserSessionStore
    private(set) var time = 0.0
    private(set) var scene: BrowserMockScene = .rest
    private(set) var script: [Step] = []
    private(set) var scriptIndex = 0
    private(set) var emitted: [BrowserSessionEvent] = []
    private var serial: UInt64 = 0
    private var nextTabSerial = 3
    private var inputObservers: [UUID: (BrowserMockInput, Double) -> Void] = [:]
    /// This permission is independent of the global static-body motion switches.
    let homeRotationEnabled: Bool
    var enabled: Bool { store.state.enabled }
    var hasPendingInput: Bool { scriptIndex < script.count || store.state.tabs.contains { $0.pending != nil } }
    var inputObserverCount: Int { inputObservers.count }

    init(store: BrowserSessionStore = BrowserSessionStore(), homeRotationEnabled: Bool = true) { self.store = store; self.homeRotationEnabled = homeRotationEnabled }
    @discardableResult func enable() -> Bool { if !enabled { play(.rest) }; return enabled }
    func disable() {
        if enabled { emit(.closed) }
        script = []; scriptIndex = 0; broadcast(.reset)
    }
    func observeInputs(_ callback: @escaping (BrowserMockInput, Double) -> Void) -> UUID {
        let id = UUID(); inputObservers[id] = callback; return id
    }
    func removeInputObserver(_ id: UUID) { inputObservers[id] = nil }
    func setIssue(_ issue: String?) { guard enabled else { return }; emit(.issue(issue)) }
    private func broadcast(_ input: BrowserMockInput) {
        for id in Array(inputObservers.keys) { inputObservers[id]?(input, time) }
    }

    func play(_ scene: BrowserMockScene) {
        self.scene = scene; time = 0; scriptIndex = 0; nextTabSerial = 3
        var tabs = MockBrowserSeed.tabs
        if scene == .back { tabs[0].history = [.a, .t]; tabs[0].historyIndex = 1 }
        let selected = scene == .egg ? tabs[2].id : tabs[0].id
        emit(.opened(tabs: tabs, selected: selected, sites: MockBrowserSeed.sites, full: scene != .dock && scene != .open),
             generation: store.state.generation + 1)
        broadcast(.reset)
        script = Self.steps(for: scene)
    }
    func advance(by interval: Double) {
        guard enabled, interval.isFinite, interval >= 0 else { return }
        advance(to: time + interval)
    }
    func advance(to target: Double) {
        guard enabled, target.isFinite, target >= time else { return }
        while scriptIndex < script.count, script[scriptIndex].time <= target {
            let step = script[scriptIndex]; settleNavigations(until: step.time); time = step.time; scriptIndex += 1
            dispatch(step.input)
        }
        settleNavigations(until: target); time = target
    }
    func interact(_ input: BrowserMockInput) {
        guard enabled else { return }
        script = []; scriptIndex = 0; dispatch(input)
    }
    private func dispatch(_ input: BrowserMockInput) {
        if case .action(let action) = input { perform(action) }
        broadcast(input)
    }
    private func perform(_ action: BrowserMockAction) {
        guard let tab = store.state.selectedTab else { return }
        switch action {
        case .optionOpen: emit(.presentation(!store.state.full))
        case .back:
            if tab.canGoBack { navigate(tab.history[tab.historyIndex - 1], duration: 0.6, historyIndex: tab.historyIndex - 1) }
        case .forward:
            if tab.canGoForward { navigate(tab.history[tab.historyIndex + 1], duration: 0.6, historyIndex: tab.historyIndex + 1) }
        case .reload:
            if tab.pending != nil { emit(.navigationStopped) }
            else if tab.committed != .n { navigate(tab.committed, duration: 1.2) }
        case .link:
            if !store.state.annotationEnabled, tab.committed == .a { navigate(.t, duration: 2.4, appends: true) }
        case .annotation: emit(.annotation(!store.state.annotationEnabled))
        case .permission(let key, let value): emit(.permission(key, value))
        case .popups: if let site = store.state.site { emit(.popups((site.popups + 1) % 3)) }
        case .autoplay: if let site = store.state.site { emit(.autoplay((site.autoplay + 1) % 3)) }
        case .removeCookie(let index): emit(.removedCookies(index))
        case .removeAllCookies: emit(.removedCookies(nil))
        case .selectTab(let id):
            let before = MockBrowserSeed.pages[tab.committed]
            if emit(.selectedTab(id)) == .accepted, let current = store.state.selectedTab,
               before?.isLoopback == false, before?.host.isEmpty == false,
               MockBrowserSeed.pages[current.committed]?.isLoopback == true { emit(.homeArrived(rotationRequested: homeRotationEnabled)) }
        case .closeTab(let id): emit(.closedTab(id))
        case .newTab:
            let used = Set(store.state.tabs.map(\.slot))
            if let slot = (0..<5).first(where: { !used.contains($0) }) {
                let id = "browser-tab-\(nextTabSerial)"; nextTabSerial += 1
                emit(.addedTab(.init(id: id, slot: slot, history: [.n])))
            }
        case .siteInformation, .manageCookies, .cookieBack, .done, .background, .external, .extensions, .options: break
        }
    }
    /// Explicit mock navigation input for detached rendering/transport checks, never a URL loader.
    func navigateMockPage(_ page: BrowserPageID, duration: Double = 0.6) {
        guard enabled, MockBrowserSeed.pages[page] != nil else { return }
        navigate(page, duration: duration, appends: true)
    }
    private func navigate(_ page: BrowserPageID, duration: Double, historyIndex: Int? = nil, appends: Bool = false) {
        guard let tab = store.state.selectedTab else { return }
        let revision = tab.navigationRevision + 1
        emit(.navigationStarted(.init(page: page, revision: revision, began: time, duration: duration,
                                      historyIndex: historyIndex, appendsHistory: appends)), revision: revision)
    }
    private func settleNavigations(until target: Double) {
        guard let tab = store.state.selectedTab, let pending = tab.pending, pending.began + pending.duration <= target else { return }
        time = max(time, pending.began + pending.duration)
        let previous = MockBrowserSeed.pages[tab.committed]
        if emit(.navigationCommitted(pending.page), tabID: tab.id, revision: pending.revision) == .accepted,
           previous?.isLoopback == false, previous?.host.isEmpty == false,
           MockBrowserSeed.pages[pending.page]?.isLoopback == true { emit(.homeArrived(rotationRequested: homeRotationEnabled)) }
    }
    @discardableResult private func emit(_ payload: BrowserEventPayload, generation: UInt64? = nil,
                                         tabID: String? = nil, revision: UInt64? = nil) -> BrowserEventDisposition {
        serial &+= 1
        let tab = store.state.selectedTab
        let event = BrowserSessionEvent(metadata: .init(source: .mock, backend: .builtinBrowserMock,
            sessionGeneration: generation ?? store.state.generation, tabID: tabID ?? tab?.id,
            navigationRevision: revision ?? tab?.navigationRevision, eventID: serial, time: time), payload: payload)
        let result = store.apply(event)
        if result == .accepted { emitted.append(event); emitted = Array(emitted.suffix(256)) }
        return result
    }

    static func steps(for scene: BrowserMockScene) -> [Step] {
        func action(_ t: Double, _ a: BrowserMockAction) -> Step { .init(time: t, input: .action(a)) }
        func hover(_ t: Double, _ name: String?, _ on: Bool = true) -> Step { .init(time: t, input: .hover(name, on)) }
        switch scene {
        case .dock, .rest: return []
        case .open: return [action(2.4, .optionOpen)]
        case .load: return [action(1.8, .link), hover(2.95, "island"), hover(4.15, "reload"), hover(7.15, "reload", false)]
        case .back: return [hover(1.3, "island"), hover(2.65, "back"), action(3.55, .back), hover(5.25, "forward"), hover(7.45, "forward", false)]
        case .site: return [hover(1.4, "site"), action(2, .siteInformation), action(3.9, .permission(.camera, .allow)),
            action(5.2, .autoplay), action(6.7, .manageCookies), action(8.4, .removeCookie(1)),
            action(10, .removeAllCookies), action(12, .done), action(14.2, .siteInformation)]
        case .anno: return [hover(1.4, "earth"), hover(2.85, "annotation"), action(3.75, .annotation),
            .init(time: 5.55, input: .pointer(160, 230)), hover(5.55, "annotation", false),
            .init(time: 6.95, input: .pointer(190, 400)), .init(time: 8.45, input: .pointer(460, 330)),
            .init(time: 9.85, input: .pointer(470, 505))]
        case .tabs: return [hover(1.4, "moon:browser-tab-1"), action(3.7, .selectTab("browser-tab-1")),
            hover(6.1, "moon:browser-tab-0"), action(8.3, .newTab), hover(9.3, "tabs", false)]
        case .egg: return [hover(1.9, "moon:browser-tab-0"), action(4.2, .selectTab("browser-tab-0")), hover(5.5, "tabs", false)]
        }
    }
    static func duration(for scene: BrowserMockScene) -> Double {
        switch scene { case .dock, .rest: 1; case .open: 4; case .load, .back: 9; case .site: 16; case .anno: 12; case .tabs: 11; case .egg: 8 }
    }
}

