import AppKit
import QuartzCore

/// M10.1: semantic entrance/replacement only. Translation keeps the existing exposure path.
enum M10DockZoom: String {
    case accum, gauss
    static var selected: Self { Self(rawValue: ProcessInfo.processInfo.environment["M10_DOCK_ZOOM"] ?? "accum") ?? .accum }
    @MainActor static var gaussian: Bool { selected == .gauss && M10DockMotion.enabled && !Motion.reduce }
}

/// One native content drawing, no copied backing tree. The caller never supplies glass or a container.
@MainActor final class M10DockGaussian {
    private var effect: ContentGaussianTransition?
    private weak var source: CALayer?
    private let clock = SceneClock()
    func show(_ visible: Bool, content: CALayer, at time: Double, initiallyVisible: Bool? = nil,
              spotlight: Bool = false, duration:Double = 0.1, fadesContent:Bool=true) {
        if source !== content {
            reset(); source = content
            var configuration:ContentGaussianTransition.Configuration=spotlight ? .spotlight:.system
            configuration.fadesContent=fadesContent
            effect = ContentGaussianTransition(content: content, clock: clock,
                initiallyVisible: initiallyVisible ?? !visible, configuration: configuration)
        }
        effect?.configuration.duration=duration
        effect?.configuration.fadesContent=fadesContent
        effect?.setVisible(visible, at: time)
    }
    func settle(at time: Double) { _ = effect?.settle(at: time) }
    func reset() { effect?.setVisible(true, animated: false); effect = nil; source = nil }
    var endTime: Double { effect?.endTime ?? 0 }
    func pose(at time:Double) -> ContentGaussianTransition.Pose? { effect?.pose(at:time) }
}
