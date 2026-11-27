import Foundation

enum BrowserPageID: String, CaseIterable, Codable, Sendable { case a, t, g, s, n }

struct BrowserMockPage: Equatable, Sendable {
    let id: BrowserPageID
    let scheme: String
    let host: String
    let port: String
    let path: String
    let title: String
    var url: String { host.isEmpty ? "" : scheme + "://" + host + port + path }
    var isLoopback: Bool { ["127.0.0.1", "localhost", "::1"].contains(host) }
}

enum BrowserPermission: Int, CaseIterable, Sendable { case ask, allow, deny }
enum BrowserPermissionKey: String, CaseIterable, Sendable { case camera, microphone, location }
struct BrowserCookieGroup: Equatable, Sendable {
    let domain: String
    let names: [String]
    var removed = false
}
struct BrowserMockSite: Equatable, Sendable {
    var camera: BrowserPermission = .ask
    var microphone: BrowserPermission = .ask
    var location: BrowserPermission = .ask
    var popups = 0
    var autoplay = 1
    var cookies: [BrowserCookieGroup]
    var cookieCount: Int { cookies.filter { !$0.removed }.reduce(0) { $0 + $1.names.count } }
}

struct BrowserPendingNavigation: Equatable, Sendable {
    let page: BrowserPageID
    let revision: UInt64
    let began: Double
    let duration: Double
    let historyIndex: Int?
    let appendsHistory: Bool
}
struct BrowserMockTab: Equatable, Sendable {
    let id: String
    let slot: Int
    var history: [BrowserPageID]
    var historyIndex = 0
    var navigationRevision: UInt64 = 0
    var pending: BrowserPendingNavigation?
    var committed: BrowserPageID { history[historyIndex] }
    var displayed: BrowserPageID { pending?.page ?? committed }
    var canGoBack: Bool { historyIndex > 0 && pending == nil }
    var canGoForward: Bool { historyIndex + 1 < history.count && pending == nil }
}

struct BrowserHomeEvent: Equatable, Sendable {
    let name: String
    let sessionGeneration: UInt64
    let tabID: String
    let navigationRevision: UInt64
    let eventID: UInt64
    let time: Double
    /// Explicit permission for the finite Browser-only Earth arrival effect.
    let rotationRequested: Bool
}

struct BrowserSessionState: Equatable, Sendable {
    var generation: UInt64 = 0
    var enabled = false
    var full = true
    var tabs: [BrowserMockTab] = []
    var selectedTabID: String?
    var sites: [String: BrowserMockSite] = [:]
    var annotationEnabled = false
    var homeEvents: [BrowserHomeEvent] = []
    var issue: String?
    var lastEventID: UInt64 = 0
    var source: BrowserEventSource = .mock
    var liveTabs: [BrowserLiveTab] = []
    var debugSuppressed = false
    var selectedLiveTab: BrowserLiveTab? { liveTabs.first { $0.id == selectedTabID } }
    var tabIDs: [String] { source == .live ? liveTabs.map(\.id) : tabs.map(\.id) }
    var visibleTabSlots: Set<Int> { source == .live ? Set(0..<min(5,liveTabs.count)) : Set(tabs.map(\.slot)) }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }
    var selectedTab: BrowserMockTab? { selectedIndex.map { tabs[$0] } }
    var committedPage: BrowserPageID? { selectedTab?.committed }
    var displayedPage: BrowserPageID? { selectedTab?.displayed }
    var site: BrowserMockSite? { displayedPage.flatMap { MockBrowserSeed.pages[$0] }.flatMap { sites[$0.host] } }
    var validationFailures: [String] {
        if source == .live {
            var result: [String] = []
            if !tabs.isEmpty || !sites.isEmpty || annotationEnabled { result.append("live session contains mock capabilities") }
            if Set(liveTabs.map(\.id)).count != liveTabs.count { result.append("duplicate live tab identity") }
            if liveTabs.isEmpty ? selectedTabID != nil : selectedLiveTab == nil { result.append("invalid live selection") }
            if enabled != (!liveTabs.isEmpty && !debugSuppressed) { result.append("invalid live visibility") }
            return result
        }
        guard enabled else { return tabs.isEmpty && selectedTabID == nil ? [] : ["disabled session retains tabs"] }
        var result: [String] = []
        if tabs.isEmpty || selectedIndex == nil { result.append("enabled session has no selected tab") }
        if Set(tabs.map(\.id)).count != tabs.count || Set(tabs.map(\.slot)).count != tabs.count { result.append("duplicate tab identity") }
        if tabs.count > 5 { result.append("tab capacity exceeded") }
        for tab in tabs {
            if !(0..<5).contains(tab.slot) { result.append("invalid tab slot") }
            if tab.history.isEmpty || !tab.history.indices.contains(tab.historyIndex) { result.append("invalid tab history") }
            if let pending = tab.pending, pending.revision != tab.navigationRevision { result.append("pending revision mismatch") }
        }
        return result
    }
}

enum BrowserEventSource: String, Sendable { case mock, live }
enum BrowserBackendAttribution: String, Sendable { case builtinBrowserMock, ownedChromium, officialProvider }
struct BrowserEventMetadata: Equatable, Sendable {
    let source: BrowserEventSource
    let backend: BrowserBackendAttribution
    let sessionGeneration: UInt64
    let tabID: String?
    let navigationRevision: UInt64?
    let eventID: UInt64
    let time: Double
}
enum BrowserEventPayload: Equatable, Sendable {
    case liveSnapshot(tabs: [BrowserLiveTab], selected: String?, hydrate: Bool, suppressed: Bool)
    case liveDisconnected
    case opened(tabs: [BrowserMockTab], selected: String, sites: [String: BrowserMockSite], full: Bool)
    case closed
    case presentation(Bool)
    case navigationStarted(BrowserPendingNavigation)
    case navigationCommitted(BrowserPageID)
    case navigationStopped
    case selectedTab(String)
    case addedTab(BrowserMockTab)
    case closedTab(String)
    case permission(BrowserPermissionKey, BrowserPermission)
    case popups(Int)
    case autoplay(Int)
    case removedCookies(Int?)
    case annotation(Bool)
    case homeArrived(rotationRequested: Bool)
    case issue(String?)
}
struct BrowserSessionEvent: Equatable, Sendable {
    let metadata: BrowserEventMetadata
    let payload: BrowserEventPayload
}
enum BrowserEventDisposition: Equatable { case accepted, duplicate, rejected(String) }

enum BrowserMockAction: Equatable, Sendable {
    case optionOpen, back, forward, reload, link
    case siteInformation, manageCookies, cookieBack, done, background
    case permission(BrowserPermissionKey, BrowserPermission), popups, autoplay
    case removeCookie(Int), removeAllCookies
    case annotation, external, extensions, options
    case selectTab(String), closeTab(String), newTab
}
enum BrowserMockInput: Equatable, Sendable {
    case action(BrowserMockAction)
    case hover(String?, Bool)
    case pointer(Double, Double)
    case reset
}
enum BrowserMockScene: String, CaseIterable, Sendable {
    case dock, open, rest, load, back, site, anno, tabs, egg
    var title: String {
        switch self {
        case .dock: "In Dock"; case .open: "Option click"; case .rest: "At rest"
        case .load: "Address and loading"; case .back: "Back and forward"; case .site: "Website settings"
        case .anno: "Annotation mode"; case .tabs: "Tab satellites"; case .egg: "Home event"
        }
    }
}
