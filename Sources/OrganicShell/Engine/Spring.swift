import CoreGraphics
import Foundation

/// One channel of an analytic damped spring (SwiftUI-style response and damping fraction), starting with a
/// velocity so a retarget continues the current motion. Same closed form as the product's NativeDockSpring.
/// Spec §3.1: every pose is evaluated in closed form at a frame's target timestamp, never integrated.
struct Spring: Sendable {
    let from: Double, to: Double, velocity: Double
    let response: Double, damping: Double
    /// Seconds until visible motion is over (spec §3.2): from then on the remaining distance and the
    /// speed × response / 2π term both stay under `epsilon`. Past it the channel reads exactly `to`.
    let duration: Double

    init(from: Double, to: Double, velocity: Double = 0, response: Double, damping: Double, epsilon: Double) {
        let r = max(0.01, response), z = abs(damping - 1) <= 0.0001 ? 1 : max(0.01, damping)
        let open = Spring(from: from, to: to, velocity: velocity, response: r, damping: z, duration: .infinity)
        self.init(from: from, to: to, velocity: velocity, response: r, damping: z, duration: open.settle(epsilon: max(1e-6, epsilon)))
    }

    private init(from: Double, to: Double, velocity: Double, response: Double, damping: Double, duration: Double) {
        self.from = from; self.to = to; self.velocity = velocity
        self.response = response; self.damping = damping; self.duration = duration
    }

    /// Largest on-screen step allowed when a spring snaps to rest, in points.
    static let restEpsilon = 0.05

    /// A spring that is already at rest at `value`.
    static func rest(_ value: Double) -> Spring { Spring(from: value, to: value, response: 1, damping: 1, epsilon: 1) }

    func sample(_ t: Double) -> (value: Double, velocity: Double) {
        guard t > 0 else { return (from, velocity) }
        if t >= duration { return (to, 0) }
        let w = 2 * Double.pi / response, z = damping
        let a = from - to, v = velocity, decay = exp(-z * w * t)
        if z < 1 - 0.0001 {
            let d = w * (1 - z * z).squareRoot(), b = (v + z * w * a) / d
            let wave = a * cos(d * t) + b * sin(d * t)
            return (to + decay * wave, decay * (-z * w * wave - a * d * sin(d * t) + b * d * cos(d * t)))
        } else if z <= 1 + 0.0001 {
            let b = v + w * a
            return (to + decay * (a + b * t), decay * (b - w * (a + b * t)))
        }
        let d = (z * z - 1).squareRoot(), r1 = -w * (z - d), r2 = -w * (z + d)
        let c1 = (v - r2 * a) / (r1 - r2), c2 = a - c1
        return (to + c1 * exp(r1 * t) + c2 * exp(r2 * t), r1 * c1 * exp(r1 * t) + r2 * c2 * exp(r2 * t))
    }

    /// Called on an unbounded copy: the last time either term was still above epsilon, on a 2 ms scan.
    private func settle(epsilon: Double) -> Double {
        guard from != to || velocity != 0 else { return 0 }
        var t = 0.0, last = 0.0
        let step = 0.002, k = response / (2 * .pi)
        while t < 4 {
            t += step
            let (x, v) = sample(t)
            if abs(x - to) >= epsilon || abs(v) * k >= epsilon { last = t }
            if t - last > 0.3 { break }
        }
        return last + step
    }
}

/// Four springs sharing one response and damping: a rectangle's origin and size.
struct RectSpring: Sendable {
    let x: Spring, y: Spring, w: Spring, h: Spring
    var duration: Double { max(x.duration, y.duration, w.duration, h.duration) }

    init(from: CGRect, to: CGRect, velocity: CGRect = .zero, response: Double, damping: Double) {
        // The last step to rest must not show on sharp text at 1×: 0.05 pt (self-test, 2026-10-28: 0.25 pt
        // snaps showed as one-frame spikes).
        let extent = Double(max(from.width, from.height, to.width, to.height, 1))
        let e = min(Spring.restEpsilon, 0.002 * extent)
        x = Spring(from: from.minX, to: to.minX, velocity: velocity.minX, response: response, damping: damping, epsilon: e)
        y = Spring(from: from.minY, to: to.minY, velocity: velocity.minY, response: response, damping: damping, epsilon: e)
        w = Spring(from: from.width, to: to.width, velocity: velocity.width, response: response, damping: damping, epsilon: e)
        h = Spring(from: from.height, to: to.height, velocity: velocity.height, response: response, damping: damping, epsilon: e)
    }

    static func rest(_ r: CGRect) -> RectSpring { RectSpring(from: r, to: r, response: 1, damping: 1) }

    /// The rectangle and its velocity (origin and size rates, pt/s) at `t`.
    func sample(_ t: Double) -> (rect: CGRect, velocity: CGRect) {
        let a = x.sample(t), b = y.sample(t), c = w.sample(t), d = h.sample(t)
        return (CGRect(x: a.value, y: b.value, width: c.value, height: d.value),
                CGRect(x: a.velocity, y: b.velocity, width: c.velocity, height: d.velocity))
    }

    var target: CGRect { CGRect(x: x.to, y: y.to, width: w.to, height: h.to) }
}
