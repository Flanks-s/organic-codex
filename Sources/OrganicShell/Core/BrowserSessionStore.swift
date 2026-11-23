import Foundation

/// Receipts retain their source and backend attribution at the store boundary.
@MainActor protocol BrowserSessionTransport: AnyObject {
    var state: BrowserSessionState { get }
    @discardableResult func apply(_ event: BrowserSessionEvent) -> BrowserEventDisposition
}

@MainActor final class BrowserSessionStore: BrowserSessionTransport {
    private(set) var state = BrowserSessionState()
    private var observers: [UUID: (BrowserSessionState, BrowserSessionEvent) -> Void] = [:]
    private(set) var acceptedEvents = 0
    var observerCount: Int { observers.count }
    func observe(_ callback: @escaping (BrowserSessionState, BrowserSessionEvent) -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }

    @discardableResult func apply(_ event: BrowserSessionEvent) -> BrowserEventDisposition {
        let m = event.metadata
        if m.source == .live { return applyLive(event) }
        guard m.source == .mock, m.backend == .builtinBrowserMock else { return .rejected("invalid backend attribution") }
        guard m.time.isFinite else { return .rejected("invalid event time") }
        if case .opened = event.payload {
            guard m.sessionGeneration > state.generation else { return .duplicate }
        } else {
            guard state.enabled, m.sessionGeneration == state.generation else { return .rejected("stale session") }
            guard m.eventID > state.lastEventID else { return .duplicate }
        }
        var next = state
        switch event.payload {
        case .liveSnapshot, .liveDisconnected: return .rejected("live payload attributed to mock")
        case .opened(let tabs, let selected, let sites, let full):
            next = BrowserSessionState(generation: m.sessionGeneration, enabled: true, full: full, tabs: tabs,
                                       selectedTabID: selected, sites: sites)
        case .closed:
            next = BrowserSessionState(generation: state.generation)
        case .presentation(let full): next.full = full
        case .navigationStarted(let pending):
            guard let i = next.tabs.firstIndex(where: { $0.id == m.tabID }), next.selectedTabID == m.tabID,
                  m.navigationRevision == next.tabs[i].navigationRevision + 1,
                  pending.revision == m.navigationRevision, pending.duration > 0, pending.duration.isFinite, pending.began.isFinite else { return .rejected("invalid navigation start") }
            if let index = pending.historyIndex {
                guard !pending.appendsHistory, next.tabs[i].history.indices.contains(index), next.tabs[i].history[index] == pending.page else { return .rejected("invalid history target") }
            } else if !pending.appendsHistory, pending.page != next.tabs[i].committed { return .rejected("invalid reload target") }
            next.tabs[i].navigationRevision = pending.revision; next.tabs[i].pending = pending
        case .navigationCommitted(let page):
            // Receipts may only commit the navigation that still owns the selected tab.
            guard let i = next.tabs.firstIndex(where: { $0.id == m.tabID }), next.selectedTabID == m.tabID,
                  let pending = next.tabs[i].pending, pending.revision == m.navigationRevision,
                  next.tabs[i].navigationRevision == m.navigationRevision, pending.page == page else { return .rejected("stale navigation receipt") }
            if pending.appendsHistory {
                next.tabs[i].history = Array(next.tabs[i].history.prefix(next.tabs[i].historyIndex + 1)) + [page]
                next.tabs[i].historyIndex = next.tabs[i].history.count - 1
            } else if let index = pending.historyIndex {
                guard next.tabs[i].history.indices.contains(index), next.tabs[i].history[index] == page else { return .rejected("invalid history receipt") }
                next.tabs[i].historyIndex = index
            }
            next.tabs[i].pending = nil
        case .navigationStopped:
            guard let i = next.selectedIndex, next.tabs[i].id == m.tabID,
                  next.tabs[i].navigationRevision == m.navigationRevision else { return .rejected("stale stop") }
            next.tabs[i].pending = nil; next.tabs[i].navigationRevision &+= 1
        case .selectedTab(let id):
            guard next.tabs.contains(where: { $0.id == id }) else { return .rejected("missing tab") }
            if next.selectedTabID != id, let i = next.selectedIndex, next.tabs[i].pending != nil { next.tabs[i].pending = nil; next.tabs[i].navigationRevision &+= 1 }
            next.selectedTabID = id
        case .addedTab(let tab):
            guard next.tabs.count < 5, !next.tabs.contains(where: { $0.id == tab.id || $0.slot == tab.slot }) else { return .rejected("tab capacity or identity") }
            if let i = next.selectedIndex { next.tabs[i].pending = nil; next.tabs[i].navigationRevision &+= 1 }
            next.tabs.append(tab); next.selectedTabID = tab.id
        case .closedTab(let id):
            guard next.tabs.count > 1, let i = next.tabs.firstIndex(where: { $0.id == id }) else { return .rejected("last or missing tab") }
            next.tabs.remove(at: i)
            if next.selectedTabID == id { next.selectedTabID = next.tabs[min(i, next.tabs.count - 1)].id }
        case .permission(let key, let value):
            guard let host = selectedHost(next, metadata: m), var site = next.sites[host] else { return .rejected("missing site") }
            switch key { case .camera: site.camera = value; case .microphone: site.microphone = value; case .location: site.location = value }
            next.sites[host] = site
        case .popups(let value), .autoplay(let value):
            guard (0...2).contains(value), let host = selectedHost(next, metadata: m), var site = next.sites[host] else { return .rejected("invalid site option") }
            if case .popups = event.payload { site.popups = value } else { site.autoplay = value }; next.sites[host] = site
        case .removedCookies(let index):
            guard let host = selectedHost(next, metadata: m), var site = next.sites[host] else { return .rejected("missing cookie site") }
            if let index { guard site.cookies.indices.contains(index) else { return .rejected("missing cookie group") }; site.cookies[index].removed = true }
            else { for i in site.cookies.indices { site.cookies[i].removed = true } }
            next.sites[host] = site
        case .annotation(let enabled): next.annotationEnabled = enabled
        case .homeArrived(let rotationRequested):
            guard let tab = next.selectedTab, tab.id == m.tabID,
                  tab.navigationRevision == m.navigationRevision, MockBrowserSeed.pages[tab.committed]?.isLoopback == true else { return .rejected("invalid home event") }
            next.homeEvents.append(.init(name: "browser.homeArrived", sessionGeneration: m.sessionGeneration, tabID: tab.id,
                                         navigationRevision: tab.navigationRevision, eventID: m.eventID, time: m.time, rotationRequested: rotationRequested))
            next.homeEvents = Array(next.homeEvents.suffix(32))
        case .issue(let value): next.issue = value
        }
        guard next.validationFailures.isEmpty else { return .rejected(next.validationFailures.joined(separator: "; ")) }
        next.lastEventID = m.eventID; state = next; acceptedEvents += 1
        for id in Array(observers.keys) { observers[id]?(state, event) }
        return .accepted
    }
    private func applyLive(_ event: BrowserSessionEvent) -> BrowserEventDisposition {
        let m = event.metadata
        guard m.backend == .ownedChromium, m.time.isFinite else { return .rejected("invalid live backend attribution") }
        guard m.sessionGeneration >= state.generation else { return .rejected("stale live generation") }
        if m.sessionGeneration == state.generation, m.eventID <= state.lastEventID { return .duplicate }
        var next = state
        if next.source != .live || m.sessionGeneration != next.generation {
            next = BrowserSessionState(generation: m.sessionGeneration, source: .live)
        }
        switch event.payload {
        case .liveSnapshot(let tabs, let selected, _, let suppressed):
            next.liveTabs = tabs; next.selectedTabID = selected; next.debugSuppressed = suppressed
            next.enabled = !tabs.isEmpty && !suppressed; next.issue = nil
        case .liveDisconnected:
            next = BrowserSessionState(generation: m.sessionGeneration, source: .live)
        case .selectedTab(let id):
            guard next.liveTabs.contains(where: { $0.id == id }) else { return .rejected("missing live tab") }
            next.selectedTabID = id
        case .issue(let issue): next.issue = issue
        case .homeArrived(let requested):
            guard let tab = next.selectedLiveTab, tab.id == m.tabID, tab.revision == m.navigationRevision,
                  BrowserSessionState.isLoopback(tab.url) else { return .rejected("invalid live home event") }
            next.homeEvents.append(.init(name: "browser.homeArrived", sessionGeneration: m.sessionGeneration,
                tabID: tab.id, navigationRevision: tab.revision, eventID: m.eventID, time: m.time, rotationRequested: requested))
            next.homeEvents = Array(next.homeEvents.suffix(32))
        default: return .rejected("mock capability on live source")
        }
        guard next.validationFailures.isEmpty else { return .rejected(next.validationFailures.joined(separator: "; ")) }
        next.lastEventID = m.eventID; state = next; acceptedEvents += 1
        for id in Array(observers.keys) { observers[id]?(state, event) }
        return .accepted
    }
    private func selectedHost(_ state: BrowserSessionState, metadata: BrowserEventMetadata) -> String? {
        guard let tab = state.selectedTab, tab.id == metadata.tabID, tab.navigationRevision == metadata.navigationRevision else { return nil }
        return MockBrowserSeed.pages[tab.displayed]?.host
    }
}
