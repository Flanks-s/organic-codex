import AppKit
import QuartzCore

/// M10.1 / DECISIONS #56. A content-only, single-layer driver-B transition.
/// The caller owns layout, glass, clipping and the scene's settle callback. Never pass a glass/container tree.
@MainActor final class ContentGaussianTransition {
    struct Pose: Equatable, Sendable {
        var radius: Double
        var opacity: Double
        var scale: Double
        static let visible = Pose(radius: 0, opacity: 1, scale: 1)
    }
    struct Configuration: Sendable {
        var duration = 0.1
        /// CA's private gaussianBlur inputRadius, in layer points; not a measured Gaussian sigma.
        var radius = 4.0
        var hiddenScale = 1.0
        /// For semantic children whose existing unfiltered parent owns the fade. Avoid double-fading ink.
        var fadesContent = true
        var sampleRate = 240.0
        static let system = Configuration()
        static var spotlight: Configuration { var c = Self(); c.hiddenScale = 1.07; return c }
        var hidden: Pose { Pose(radius: radius, opacity: fadesContent ? 0:1, scale: hiddenScale) }
    }
    struct Plan: Sendable {
        let began: Double, duration: Double, rate: Double
        let from: Pose, to: Pose
        let initialVelocity: Pose
        /// Hermite continuation preserves the interrupted pose AND feeds its current velocity into the new leg.
        /// Both evaluation methods use the same linear table as CA, rather than reading presentation().
        private func raw(at elapsed: Double) -> Pose {
            let d=max(0.0001,duration-1/rate),u=min(1,max(0,elapsed/d))
            let p=u*u*(3-2*u),v=u*(1-u)*(1-u)*d
            return Pose(radius:max(0,from.radius+(to.radius-from.radius)*p+initialVelocity.radius*v),
                        opacity:min(1,max(0,from.opacity+(to.opacity-from.opacity)*p+initialVelocity.opacity*v)),
                        scale:from.scale+(to.scale-from.scale)*p+initialVelocity.scale*v)
        }
        private func segment(at time: Double) -> (Double,Double,Double) {
            let elapsed=min(duration,max(0,time-began))
            let lo=min(duration,floor(elapsed*rate)/rate),hi=min(duration,lo+1/rate)
            return (lo,hi,hi>lo ? (elapsed-lo)/(hi-lo):1)
        }
        func pose(at time: Double) -> Pose {
            let (lo,hi,f)=segment(at:time),a=raw(at:lo),b=raw(at:hi)
            return Pose(radius:a.radius+(b.radius-a.radius)*f,opacity:a.opacity+(b.opacity-a.opacity)*f,
                        scale:a.scale+(b.scale-a.scale)*f)
        }
        func velocity(at time: Double) -> Pose {
            guard time>=began,time<began+duration-1/rate else { return Pose(radius:0,opacity:0,scale:0) }
            let (lo,hi,_)=segment(at:time),a=raw(at:lo),b=raw(at:hi),d=max(1e-9,hi-lo)
            return Pose(radius:(b.radius-a.radius)/d,opacity:(b.opacity-a.opacity)/d,scale:(b.scale-a.scale)/d)
        }

    }
    let layer: CALayer
    let clock: SceneClock
    var configuration: Configuration
    private(set) var plan: Plan?
    private(set) var resting: Pose
    private let baseOpacity: Float
    private let baseTransform: CATransform3D
    private let filterName = "m101ContentGaussian" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let animationKey = "shell.m101.content"
    private var blur: NSObject?
    private(set) var filterAvailable = true

    init(content layer: CALayer, clock: SceneClock, initiallyVisible: Bool = true,
         configuration: Configuration = .system) {
        self.layer = layer; self.clock = clock; self.configuration = configuration
        baseOpacity = layer.opacity; baseTransform = layer.transform
        resting = initiallyVisible ? .visible : configuration.hidden
        write(resting, sharp: true)
    }

    func pose(at time: Double? = nil) -> Pose { plan?.pose(at: time ?? clock.mediaTime()) ?? resting }
    var endTime: Double? { plan.map { $0.began + $0.duration } }

    /// Use the SAME media timestamp as the rest of the scene commit. No display link or timer is installed.
    @discardableResult func setVisible(_ visible: Bool, at time: Double? = nil, animated: Bool = true) -> Plan? {
        let t = time ?? clock.mediaTime(), from = pose(at: t), target = visible ? Pose.visible : configuration.hidden
        let velocity = plan?.velocity(at: t) ?? Pose(radius: 0, opacity: 0, scale: 0)
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        layer.removeAnimation(forKey: animationKey)
        guard animated, from != target, configuration.duration > 0 else {
            plan = nil; resting = target; write(target, sharp: true); return nil
        }
        let rate = max(120, configuration.sampleRate)
        let p = Plan(began: t, duration: max(configuration.duration, 1/rate), rate: rate, from: from, to: target, initialVelocity: velocity)
        plan = p; resting = target
        installBlur()
        // Model holds the endpoint. A retained fill holds it until the scene settles/removes our animation.
        write(target, sharp: false)
        let timeline = Timeline(began: t, duration: p.duration, rate: max(120, configuration.sampleRate))
        let poses = timeline.times.map { p.pose(at: t + $0) }
        func key(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path); a.values = values; a.keyTimes = timeline.linearKeys
            a.duration = timeline.duration; a.calculationMode = .linear; return a
        }
        var channels = [key("opacity", poses.map { NSNumber(value: Double(baseOpacity)*$0.opacity) }),
                        key("transform", poses.map { NSValue(caTransform3D: transform($0.scale)) })]
        if blur != nil {
            channels.append(key("filters.\(filterName).inputRadius", poses.map { NSNumber(value: $0.radius) }))
            let enabled = CAKeyframeAnimation(keyPath: "filters.\(filterName).enabled")
            enabled.values = [from.radius > 0 && from.opacity > 0, true, false]
            enabled.keyTimes = [0, 0.000001, NSNumber(value: 1 - 1 / (rate * p.duration)), 1]
            enabled.calculationMode = .discrete; enabled.duration = timeline.duration;channels.append(enabled)
        }
        let group = CAAnimationGroup(); group.animations = channels; group.duration = timeline.duration
        group.beginTime = layer.convertTime(t, from: nil); group.fillMode = .both; group.isRemovedOnCompletion = false
        layer.add(group, forKey: animationKey)
        return p
    }

    /// Old/new controllers each own ONE layer. Invoke with the scene's shared timestamp, in one transaction.
    static func replace(old: ContentGaussianTransition, new: ContentGaussianTransition, at time: Double,
                        animated: Bool = true) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        old.setVisible(false, at: time, animated: animated); new.setVisible(true, at: time, animated: animated)
        CATransaction.commit()
    }

    /// Call from the scene's existing completion/settle path. Stale completion callbacks cannot clear a new plan.
    @discardableResult func settle(at time: Double? = nil) -> Bool {
        let t = time ?? clock.mediaTime()
        guard let p = plan, t >= p.began + p.duration else { return false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        resting = p.to; plan = nil; layer.removeAnimation(forKey: animationKey); write(resting, sharp: true)
        CATransaction.commit(); return true
    }

    /// Cancels at the analytically evaluated pose (including a mid-transition blur); no presentation-layer read.
    func freeze(at time: Double? = nil) {
        let current = pose(at: time)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plan = nil; resting = current; layer.removeAnimation(forKey: animationKey)
        write(current, sharp: current.radius == 0 || current.opacity == 0)
        CATransaction.commit()
    }
    private func transform(_ scale: Double) -> CATransform3D { CATransform3DScale(baseTransform, scale, scale, 1) }
    private func installBlur() {
        guard blur == nil else { return }
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("filterWithType:")),
              let filter = cls.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else {
            filterAvailable = false; return
        }
        filter.setValue(filterName, forKey: "name"); filter.setValue(0, forKey: "inputRadius")
        // Deliberately leave inputNormalizeEdges off, as Overlay/Peek do (avoids a dark/white edge flash).
        blur = filter; layer.filters = (layer.filters ?? []) + [filter]
    }
    private func write(_ p: Pose, sharp: Bool) {
        layer.opacity = baseOpacity * Float(p.opacity); layer.transform = transform(p.scale)
        if sharp {
            if blur != nil {
                layer.filters = layer.filters?.filter { item in
                    guard let object=item as? NSObject,object.responds(to:NSSelectorFromString("name")) else { return true }
                    return object.value(forKey:"name") as? String != filterName
                }
                blur = nil
            }
        } else { installBlur(); layer.setValue(p.radius, forKeyPath: "filters.\(filterName).inputRadius") }
    }
}

extension SceneClock {
    /// Driver B and driver A use Core Animation media time. Offline callers pass their scene's virtual time explicitly.
    func mediaTime() -> Double { CACurrentMediaTime() }
}

extension ContentGaussianTransition {
    /// A narrowly scoped fallback for content under a deliberately paused ambient ancestor. The host's
    /// EXISTING driver-A clock supplies media time; no timer, layout or bitmap capture is installed here.
    /// Keep the analytic Plan so interruption/settle obey exactly the same curve as driver B.
    func sampleModel(at time:Double) {
        guard plan != nil else{return}
        let p=pose(at:time)
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey:animationKey)
        write(p,sharp:p.radius==0 || p.opacity==0)
        CATransaction.commit()
    }
}
