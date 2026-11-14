import Foundation

extension MockReplay {
    @discardableResult func setBrowserMockEnabled(_ enabled: Bool) -> Bool {
        guard canPlay else { browserReplay?.disable(); browserReplay = nil; return false }
        if enabled { if browserReplay == nil { browserReplay = MockBrowserReplay() }; return browserReplay?.enable() == true }
        browserReplay?.disable(); browserReplay = nil; return true
    }
}
