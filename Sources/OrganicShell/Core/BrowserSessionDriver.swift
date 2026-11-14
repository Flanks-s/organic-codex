import Foundation

struct BrowserLiveTab: Equatable, Sendable {
    let id: String
    let url: String
    let title: String
    let revision: UInt64
}

extension BrowserSessionState {
    static func isLoopback(_ address: String) -> Bool {
        guard let host = URLComponents(string: address)?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }
}

/// A shared data owner supplies state; window owners supply presentation time.
@MainActor protocol BrowserSessionDriver: AnyObject {
    var store: BrowserSessionStore { get }
    var time: Double { get }
    var enabled: Bool { get }
    var isLive: Bool { get }
    func interact(_ input: BrowserMockInput)
    func observeInputs(_ callback: @escaping (BrowserMockInput, Double) -> Void) -> UUID
    func removeInputObserver(_ id: UUID)
}

extension MockBrowserReplay: BrowserSessionDriver {
    var isLive: Bool { false }
}
