import AppKit

@MainActor protocol SunHoverFrameDriving: AnyObject {
    var isRunning: Bool { get }
    func invalidate()
}

/// The product follows the owning view's presentation clock and visibility.
@MainActor final class SunHoverViewFrameDriver: SunHoverFrameDriving {
    private let clock = SceneClock()
    private(set) var isRunning = false
    init(view: NSView, deliver: @escaping () -> Void) {
        guard view.window != nil else { return }
        clock.onFrame = { [weak self] _ in guard self?.isRunning == true else { return }; deliver() }
        clock.attach(to: view); isRunning = true; clock.keepRunning = true
    }
    isolated deinit { invalidate() }
    func invalidate() { isRunning = false; clock.keepRunning = false; clock.invalidate(); clock.onFrame = nil }
}
