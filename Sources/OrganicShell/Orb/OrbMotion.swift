import QuartzCore
import SwiftUI

enum OrbTuning {
    static let ambient = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    static let wobble: CGFloat = 1.2
    static let liquidPeriod = 3.0
    static let deepen = 0.8
    static let satelliteSize: CGFloat = 0.38
    static let orbitRadius: CGFloat = 0.68
    static let flatten = 0.3
    static let tilt = -18.0 * Double.pi / 180
    static let slow = 0.45, fast = 2.6
    static let alertHeight = 5.0, alertPeriod = 3.0, breathPeriod = 2.8
}

/// QA1673 timing, restricted to a component-owned layer whose normal speed is one.
/// A shared media-time sample is used for all three planes, so front/back cannot drift on pause.
enum OrbMotion {
    static func completionKeyframes()->(values:[Double],duration:Double) {
        let timeline=KeyframeTimeline(initialValue:0.0) {
            SpringKeyframe(1,duration:0.16,spring:.snappy)
            SpringKeyframe(0,duration:0.5,spring:.bouncy)
        }
        return ((0...80).map { timeline.value(time:Double($0)/80*timeline.duration) },timeline.duration)
    }
    static func setAnimationsPaused(_ paused: Bool, on layer: CALayer, at now: CFTimeInterval) {
        if paused {
            guard layer.speed != 0 else { return }
            let held = layer.convertTime(now, from: nil)
            layer.speed = 0
            layer.timeOffset = held
        } else {
            guard layer.speed == 0 else { return }
            let held = layer.timeOffset
            layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
            layer.beginTime = layer.convertTime(now, from: nil) - held
        }
    }

    static func spring(_ key: String, from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: key)
        a.mass = 1; a.stiffness = pow(2 * .pi / 0.30, 2)
        a.damping = 2 * 0.70 * sqrt(a.stiffness)
        a.fromValue = from; a.toValue = to; a.duration = a.settlingDuration
        return a
    }

    static func alertHop() -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "position.y")
        let duration = 2 * OrbTuning.alertPeriod + 0.5
        let height = OrbTuning.alertHeight
        var times: [NSNumber] = [0], values: [Double] = [0]
        for start in [0.0, OrbTuning.alertPeriod] {
            for (offset, value) in [(0.0, 0.0), (0.11, -height), (0.22, 0.0), (0.33, -height*0.4), (0.44, 0.0)] {
                if start + offset == 0 { continue }
                times.append(NSNumber(value: (start + offset) / duration)); values.append(value)
            }
        }
        times.append(1); values.append(0)
        a.values = values; a.keyTimes = times; a.duration = duration
        a.isAdditive = true; a.calculationMode = .cubic
        a.preferredFrameRateRange = OrbTuning.ambient
        return a
    }
}
