import Foundation

enum MockBrowserSeed {
    static let pages: [BrowserPageID: BrowserMockPage] = [
        .a: .init(id: .a, scheme: "http", host: "127.0.0.1", port: ":8765", path: "/preview/sidebar", title: "Orbit Lab · Sidebar"),
        .t: .init(id: .t, scheme: "http", host: "127.0.0.1", port: ":8765", path: "/tokens/spacing?theme=dark&density=compact&platform=macos", title: "Spacing tokens"),
        .g: .init(id: .g, scheme: "http", host: "localhost", port: ":6006", path: "/?path=/story/sidebar--compact", title: "Component gallery"),
        .s: .init(id: .s, scheme: "https", host: "staging.orbit.test", port: "", path: "/releases/0.1.2", title: "Orbit 0.1.2 · Release notes"),
        .n: .init(id: .n, scheme: "", host: "", port: "", path: "", title: "New Tab")
    ]
    static var tabs: [BrowserMockTab] {
        [.init(id: "browser-tab-0", slot: 0, history: [.a]),
         .init(id: "browser-tab-1", slot: 1, history: [.g]),
         .init(id: "browser-tab-2", slot: 2, history: [.s])]
    }
    static var sites: [String: BrowserMockSite] {
        ["127.0.0.1": .init(location: .deny, cookies: [
            .init(domain: "127.0.0.1", names: ["session", "csrftoken", "theme"]),
            .init(domain: "auth.orbit.test", names: ["sid", "remember"]),
            .init(domain: "cdn.orbit.test", names: ["edge-cache"])]),
         "localhost": .init(cookies: [.init(domain: "localhost", names: ["gallery-addons", "theme"])]),
         "staging.orbit.test": .init(camera: .deny, microphone: .deny, location: .deny, popups: 1, autoplay: 2, cookies: [
            .init(domain: "staging.orbit.test", names: ["session", "csrftoken", "locale", "theme"]),
            .init(domain: "auth.orbit.test", names: ["sid", "remember"])])]
    }
}
