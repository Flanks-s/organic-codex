import AppKit

/// The temporary comparison mode is content-only. Containers NEVER regain the old illegal wash copies.
enum OverlayZoom: String {
    case accum, gauss
    @MainActor static var verificationOverride: Self?
    @MainActor static var selected: Self { verificationOverride ?? Self(rawValue: ProcessInfo.processInfo.environment["OVERLAY_ZOOM"] ?? "accum") ?? .accum }
    @MainActor static func gaussian(reduceMotion: Bool) -> Bool { OverlayExposure.enabled && selected == .gauss && !reduceMotion }
}

/// Layer-only entry for the host's Peek rows as well as native overlays. Pass ONLY content; glass/plates are siblings.
/// Owns one Engine driver-B transition; the host calls settle from its existing completion path.
@MainActor final class OverlayContentAppearance {
    let transition: ContentGaussianTransition
    init(content: CALayer, clock: SceneClock, initiallyVisible: Bool = false,
         configuration: ContentGaussianTransition.Configuration = .system) {
        transition = ContentGaussianTransition(content: content, clock: clock, initiallyVisible: initiallyVisible, configuration: configuration)
    }
    @discardableResult func setVisible(_ visible: Bool, at time: Double, animated: Bool = true) -> Double {
        transition.setVisible(visible, at: time, animated: animated && OverlayExposure.enabled)
        return transition.endTime ?? time
    }
    @discardableResult func settle(at time: Double) -> Bool { transition.settle(at: time) }
}

/// An Engine-timestamped fade with NO filter, for glass and combined plate controls. No presentation reads or frame timer.
@MainActor final class OverlayContainerFade {
    private let layer: CALayer
    private let base: Float
    private var plan: ContentGaussianTransition.Plan?
    private var resting: Double
    init(_ layer: CALayer, initiallyVisible: Bool) { self.layer=layer;base=layer.opacity;resting=initiallyVisible ? 1:0 }
    func setVisible(_ visible: Bool, at time: Double, animated: Bool) {
        let from=plan?.pose(at:time).opacity ?? resting, to=visible ? 1.0:0
        let velocity=plan?.velocity(at:time).opacity ?? 0
        layer.removeAnimation(forKey:"overlay.appearance.fade");layer.opacity=base*Float(to)
        resting=to
        guard animated else {plan=nil;return}
        let p=ContentGaussianTransition.Plan(began:time,duration:0.1,rate:240,from:.init(radius:0,opacity:from,scale:1),to:.init(radius:0,opacity:to,scale:1),initialVelocity:.init(radius:0,opacity:velocity,scale:0))
        plan=p
        let timeline=Timeline(began:time,duration:0.1,rate:240)
        let a=CAKeyframeAnimation(keyPath:"opacity");a.values=timeline.times.map{NSNumber(value:Double(base)*p.pose(at:time+$0).opacity)}
        a.keyTimes=timeline.linearKeys;a.duration=0.1;a.beginTime=layer.convertTime(time,from:nil);a.fillMode = .both
        layer.add(a,forKey:"overlay.appearance.fade")
    }
}

@MainActor final class OverlayAppearanceBank {
    private var content:[ObjectIdentifier:OverlayContentAppearance]=[:]
    private var containers:[ObjectIdentifier:OverlayContainerFade]=[:]
    private var cleanup:OverlayCancellation?
    private var visibleAlpha:[ObjectIdentifier:CGFloat]=[:]
    func set(_ views:[NSView],visible:Bool,scene:SceneClock,at time:Double,clock:any OverlayClock,animated:Bool) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        for view in views {
            if view.layer == nil {view.wantsLayer=true}
            guard let layer=view.layer else {continue}
            let id=ObjectIdentifier(layer)
            if layer.name == nil {layer.name="overlay.appearance.content"}
            if content[id]==nil || content[id]?.transition.plan == nil {
                let alpha = visible ? (view.alphaValue > 0 ? view.alphaValue : visibleAlpha[id] ?? 1) : view.alphaValue
                visibleAlpha[id]=alpha;layer.opacity=Float(alpha)
                content[id]=OverlayContentAppearance(content:layer,clock:scene,initiallyVisible:!visible)
            }
            _=content[id]?.setVisible(visible,at:time,animated:animated)
            // AppKit may restore alpha from the NSView on a later frame/layout. Keep its MODEL in sync;
            // the Engine keyframes, not alphaValue, still own the interpolated presentation.
            view.alphaValue=CGFloat(layer.opacity)
        }
        CATransaction.commit()
        cleanup?.cancel()
        // Lifecycle cleanup only; Engine's CA keyframes own EVERY interpolated frame.
        cleanup=clock.schedule(after:animated ? 0.1:0) { [weak self] in self?.settle(at:time+0.1) }
    }
    func fade(_ views:[NSView],visible:Bool,at time:Double,animated:Bool) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        for view in views {
            if view.layer == nil {view.wantsLayer=true}
            guard let layer=view.layer else {continue}
            let id=ObjectIdentifier(layer)
            if layer.name == nil {layer.name="overlay.appearance.container"}
            ReplicaContainerAudit.register(layer,material:.container,note:"Unfiltered fade; never replicated")
            if containers[id]==nil {containers[id]=OverlayContainerFade(layer,initiallyVisible:!visible)}
            containers[id]?.setVisible(visible,at:time,animated:animated)
            view.alphaValue=CGFloat(layer.opacity)
        }
        CATransaction.commit()
    }
    #if OVERLAY_SELFTEST
    func verificationPoses(at time:Double)->[ContentGaussianTransition.Pose] {content.values.map {$0.transition.pose(at:time)}}
    #endif
    func settle(at time:Double) {content.values.forEach {_=$0.settle(at:time)}}
    func retire() {cleanup?.cancel();cleanup=nil;content.values.forEach {_=$0.setVisible(false,at:0,animated:false)}}
}
