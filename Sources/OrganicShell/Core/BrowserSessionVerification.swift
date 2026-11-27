import Foundation

/// Shared assertions for the component runner and mutation fixtures; no external process is started.
@MainActor enum BrowserSessionVerification {
    static func run(_ check: (Bool, String) -> Void) {
        let r = MockBrowserReplay(homeRotationEnabled: false); check(!r.enabled && r.store.observerCount == 0, "default mock has no session or subscriptions")
        r.enable(); check(r.store.state.validationFailures.isEmpty, "seed state is valid")
        check(r.store.state.tabs.count == 3 && r.store.state.committedPage == .a, "seed has three tabs and page a")
        check(r.store.state.site?.cookieCount == 6, "seed has six cookies")
        let eventsBefore = r.store.acceptedEvents
        if let event = r.emitted.last { check(r.store.apply(event) == .duplicate, "duplicate event is rejected") }
        check(r.store.acceptedEvents == eventsBefore, "duplicate produces no motion notification")
        let s = r.store.state
        let invalid = BrowserSessionEvent(metadata: .init(source: .mock, backend: .ownedChromium, sessionGeneration: s.generation,
            tabID: s.selectedTabID, navigationRevision: 0, eventID: 999, time: 0), payload: .annotation(true))
        check(r.store.apply(invalid) == .rejected("invalid backend attribution"), "owned Chromium cannot be attributed builtin mock")
        check(!r.store.state.annotationEnabled, "invalid backend cannot mutate state")
        r.interact(.action(.back)); check(r.store.state.selectedTab?.historyIndex == 0, "back disabled at history start")
        r.interact(.action(.link)); check(r.store.state.committedPage == .a && r.store.state.displayedPage == .t, "pending address is separate from committed page")
        check(r.store.state.selectedTab?.canGoBack == false, "history actions blocked while loading")
        let pendingBefore = r.store.state.selectedTab?.pending
        r.interact(.action(.selectTab(r.store.state.selectedTabID!)))
        check(r.store.state.selectedTab?.pending == pendingBefore, "selecting the current tab preserves its navigation")
        r.interact(.action(.reload)); check(r.store.state.committedPage == .a && r.store.state.displayedPage == .a, "stop restores committed address")
        r.advance(by: 4); check(r.store.state.committedPage == .a, "stopped receipt cannot commit later")
        r.interact(.action(.link)); r.advance(by: 2.4)
        check(r.store.state.committedPage == .t && r.store.state.selectedTab?.history == [.a, .t], "link commits history once")
        r.interact(.action(.back)); r.advance(by: 0.6); check(r.store.state.committedPage == .a, "back commits cached page")
        r.interact(.action(.forward)); r.advance(by: 0.6); check(r.store.state.committedPage == .t, "forward commits cached page")
        check(r.store.state.selectedTab?.canGoForward == false, "forward disabled at history end")
        let history = r.store.state.selectedTab?.history
        r.interact(.action(.reload)); r.advance(by: 1.2)
        check(r.store.state.selectedTab?.history == history, "reload does not append history")
        r.interact(.action(.selectTab("browser-tab-1")))
        check(r.store.state.committedPage == .g && r.store.state.selectedTab?.history == [.g], "each tab owns its history")
        r.interact(.action(.selectTab("browser-tab-0")))
        r.interact(.action(.removeCookie(1))); check(r.store.state.site?.cookieCount == 4, "cookie group removal produces four cookies")
        r.interact(.action(.removeAllCookies)); check(r.store.state.site?.cookieCount == 0, "remove all cookies produces empty site")
        for key in BrowserPermissionKey.allCases {
            for value in BrowserPermission.allCases {
                r.interact(.action(.permission(key, value)))
                let site = r.store.state.site
                let actual = key == .camera ? site?.camera : key == .microphone ? site?.microphone : site?.location
                check(actual == value, "permission \(key.rawValue) accepts \(value.rawValue)")
            }
        }
        let oldPop = r.store.state.site?.popups ?? -1, oldAuto = r.store.state.site?.autoplay ?? -1
        for _ in 0..<3 { r.interact(.action(.popups)); r.interact(.action(.autoplay)) }
        check(r.store.state.site?.popups == oldPop && r.store.state.site?.autoplay == oldAuto, "site option cycles have three choices")
        r.interact(.action(.annotation)); check(r.store.state.annotationEnabled, "annotation enables")
        let page = r.store.state.committedPage; r.interact(.action(.link)); check(r.store.state.committedPage == page && r.store.state.selectedTab?.pending == nil, "annotation intercepts page link")
        r.interact(.action(.annotation)); check(!r.store.state.annotationEnabled, "annotation disables")
        for _ in 0..<3 { r.interact(.action(.newTab)) }
        check(r.store.state.tabs.count == 5, "new tab capacity is five")
        check(r.store.state.committedPage == .n, "new tab selects empty page")
        r.interact(.action(.reload)); check(r.store.state.selectedTab?.pending == nil, "empty page cannot reload")
        while r.store.state.tabs.count > 1 { r.interact(.action(.closeTab(r.store.state.tabs.last!.id))) }
        r.interact(.action(.closeTab(r.store.state.tabs[0].id))); check(r.store.state.tabs.count == 1, "last tab refuses close")

        r.play(.rest); r.interact(.action(.link))
        let pending = r.store.state.selectedTab!.pending!, tabID = r.store.state.selectedTabID!
        r.interact(.action(.selectTab("browser-tab-1")))
        let stale = BrowserSessionEvent(metadata: .init(source: .mock, backend: .builtinBrowserMock, sessionGeneration: r.store.state.generation,
            tabID: tabID, navigationRevision: pending.revision, eventID: r.store.state.lastEventID + 1, time: 8), payload: .navigationCommitted(.t))
        let saved = r.store.state
        check(r.store.apply(stale) != .accepted, "late receipt is rejected after selecting another tab")
        check(r.store.state == saved && r.store.state.committedPage == .g, "late receipt cannot overwrite the new tab address")
        r.play(.rest); check(r.store.apply(stale) != .accepted, "old session receipt is rejected")
        for scene in BrowserMockScene.allCases {
            r.play(scene); r.advance(to: MockBrowserReplay.duration(for: scene))
            check(r.store.state.validationFailures.isEmpty, "scene \(scene.rawValue) finishes in a valid state")
            check(!r.hasPendingInput, "scene \(scene.rawValue) has no timed input left")
            check(r.emitted.allSatisfy { $0.metadata.source == .mock && $0.metadata.backend == .builtinBrowserMock }, "scene \(scene.rawValue) has mock attribution")
            if scene == .egg {
                check(r.store.state.homeEvents.count == 1, "home scene records one named arrival")
                check(r.store.state.homeEvents.first?.name == "browser.homeArrived" && r.store.state.homeEvents.first?.rotationRequested == false, "home event is named and has rotation disabled")
                check(r.store.state.homeEvents.first?.tabID == "browser-tab-0", "home event identifies its tab")
            }
        }
        r.disable(); check(!r.enabled && r.store.state.tabs.isEmpty && !r.hasPendingInput, "disable retires session and pending input")
        let empty = BrowserSessionStore()
        let missing = BrowserSessionEvent(metadata: .init(source: .mock, backend: .builtinBrowserMock, sessionGeneration: 1,
            tabID: nil, navigationRevision: nil, eventID: 1, time: 0), payload: .opened(tabs: [], selected: "missing", sites: [:], full: true))
        check(empty.apply(missing) != .accepted && !empty.state.enabled, "missing selected state is rejected")
    }

    static func displayContract(_ state: BrowserSessionState, attribution: BrowserBackendAttribution,
                                _ check: (Bool, String) -> Void) {
        check(state.enabled && state.selectedTabID != nil, "display contract requires an enabled selected state")
        check(state.validationFailures.isEmpty, "display contract requires valid state")
        check(attribution == .builtinBrowserMock, "display contract requires builtin-browser mock attribution")
    }
}
