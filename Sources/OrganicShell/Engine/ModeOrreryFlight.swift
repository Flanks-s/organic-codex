import Foundation

/// Main.dc.html, planet3 (D 0.3). Coordinates are window points, with a top-left origin.
/// This sampler owns no views, spring parameters, native leases or application clock.
enum ModeOrreryFlight {
    static let stage = 0.16, lap = 0.38, stagger = lap / 6

    struct Pose {
        var rect: CGRect
        var glass: Double = 1
        var row: Double = 0
        var visible = true
        var landed = false
        var depth = 7.0
    }

    struct Plan {
        let forward: Bool
        let row: CGRect, real: CGRect
        let rank: Int, lastRank: Int
        let avatarFrom: CGRect, avatarTo: CGRect
        var departure: Double { (forward ? stage : 0) + stagger * Double(forward ? rank : lastRank - rank) }
        var entry: Double { departure + (forward ? 0.26 : 0.30) }
        var exit: Double { entry + lap }
        var arrival: Double { exit + (forward ? 0.42 : 0.36) }
        var handoff: Double { arrival + (forward ? 0 : stage) }
        var duration: Double {
            (forward ? stage + 0.26 + lap + 0.42 + 0.14 : 0.30 + lap + 0.36 + 0.20)
                + stagger * Double(lastRank)
        }

        func avatar(at time: Double) -> CGRect {
            ModeOrreryFlight.avatar(at: time, forward: forward, from: avatarFrom, to: avatarTo)
        }

        func pose(at time: Double) -> Pose {
            let t = max(0, time), start = forward ? row.center : real.center, goal = forward ? real.center : row.center
            let radiusX = forward ? 36.0 : 21.0, radiusY = forward ? 20.0 : 12.0
            let nominal = forward ? 20.0 : 15.0, direction = forward ? 1.0 : -1.0
            let angle = forward ? -Double.pi / 2 - 0.35 : -0.2
            func ring(_ tt: Double) -> (point: CGPoint, tangent: CGPoint, z: Double) {
                let theta = angle + direction * 2 * .pi / lap * (tt - exit)
                let c = avatar(at: tt).center, ct = cos(-0.2), st = sin(-0.2)
                let x = radiusX * cos(theta), y = radiusY * sin(theta)
                let dx = -direction * radiusX * sin(theta), dy = direction * radiusY * cos(theta)
                return (CGPoint(x: c.x + x * ct - y * st, y: c.y + x * st + y * ct),
                        CGPoint(x: dx * ct - dy * st, y: dx * st + dy * ct), sin(theta))
            }
            func size(_ z: Double) -> Double { nominal * (1 + 0.18 * z) }
            var c: CGPoint, s: Double, glass = 1.0, rowStrength = 0.0, visible = true, landed = false, depth = 7.0
            if forward && t < stage {
                let k = smooth(t / stage)
                c = row.center; s = row.width + (22 - row.width) * k; glass = k; rowStrength = 1 - k
            } else if t < departure {
                c = start; s = forward ? 22 : real.width
            } else if t < entry {
                let p = ring(entry), u = bezier(0.35, 0, 0.7, 0.85, (t - departure) / (forward ? 0.26 : 0.30))
                let speed = max(1e-12, hypot(p.tangent.x, p.tangent.y))
                let length = min(forward ? 40.0 : 24.0, distance(p.point, start) * 0.35)
                c = cubic(start, mix(start, p.point, 0.3),
                          CGPoint(x: p.point.x - p.tangent.x / speed * length, y: p.point.y - p.tangent.y / speed * length), p.point, u)
                let from = forward ? 22.0 : real.width; s = from + (size(p.z) - from) * u
            } else if t < exit {
                let p = ring(t); c = p.point; s = size(p.z); depth = p.z < 0 ? 5 : 7
            } else if t < arrival {
                let p = ring(exit), u = bezier(0.2, 0.25, 0.18, 1, (t - exit) / (forward ? 0.42 : 0.36))
                let speed = max(1e-12, hypot(p.tangent.x, p.tangent.y))
                let length = min(forward ? 120.0 : 90.0, distance(goal, p.point) * 0.3)
                c = cubic(p.point, CGPoint(x: p.point.x + p.tangent.x / speed * length, y: p.point.y + p.tangent.y / speed * length),
                          mix(goal, p.point, 0.22), goal, u)
                let s0 = size(p.z), mid = s0 + (22 - s0) * min(1, u * 3)
                s = forward && u >= 2 / 3 ? 22 + (real.width - 22) * (u - 2 / 3) * 3 : mid
            } else if forward {
                c = real.center; s = real.width; landed = true; visible = t < arrival + 0.12
            } else if t < handoff {
                let k = smooth((t - arrival) / stage)
                c = row.center; s = 22 + (row.width - 22) * k; glass = 1 - k; rowStrength = k
            } else {
                c = row.center; s = row.width; visible = false; landed = true; glass = 0; rowStrength = 1
            }
            return Pose(rect: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s),
                        glass: glass, row: rowStrength, visible: visible, landed: landed, depth: depth)
        }
    }

    /// A reversal rewinds the very same authored path, including content and depth. It never rebuilds
    /// a new incoming curve from a sampled rectangle. Repeated toggles retain the original timeline.
    struct Clock {
        var origin = 0.0, rate = 1.0, duration = 0.0
        func time(at elapsed: Double) -> Double { min(duration, max(0, origin + rate * elapsed)) }
        var remaining: Double { rate > 0 ? duration - origin : origin }
        mutating func reverse(at elapsed: Double) { origin = time(at: elapsed); rate = -rate }
    }

    static func smooth(_ x: Double) -> Double { let k = min(1, max(0, x)); return k * k * (3 - 2 * k) }
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }; if x >= 1 { return 1 }
        func f(_ a: Double, _ b: Double, _ s: Double) -> Double { 3 * (1-s) * (1-s) * s * a + 3 * (1-s) * s * s * b + s*s*s }
        var lo = 0.0, hi = 1.0
        // Match the board's inversion, including its precision, for independent frame comparisons.
        for _ in 0..<22 { let m = (lo + hi) / 2; if f(x1, x2, m) < x { lo = m } else { hi = m } }
        return f(y1, y2, (lo + hi) / 2)
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
    private static func mix(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint { CGPoint(x: a.x+(b.x-a.x)*u, y:a.y+(b.y-a.y)*u) }
    private static func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ u: Double) -> CGPoint {
        let m = 1-u, c0=m*m*m, c1=3*m*m*u, c2=3*m*u*u, c3=u*u*u
        return CGPoint(x:c0*a.x+c1*b.x+c2*c.x+c3*d.x, y:c0*a.y+c1*b.y+c2*c.y+c3*d.y)
    }

    /// The board's 6ea3220 LL log, interpolated exactly as rec(). Each coordinate is mapped between
    /// the actual sidebar/dock endpoints, so resized windows and changed layouts retain exact landings.
    static func avatar(at time: Double, forward: Bool, from: CGRect, to: CGRect) -> CGRect {
        let log = forward ? avatarForward : avatarReverse
        let start = log[0], end = log[log.count-1]
        let t = max(0, time)
        if t >= end[0] { return to }
        let i = log.indices.dropFirst().first { log[$0][0] >= t } ?? log.count-1
        let a=log[i-1], b=log[i], k=(t-a[0])/(b[0]-a[0])
        func progress(_ j: Int) -> Double { (a[j]+(b[j]-a[j])*k-start[j])/(end[j]-start[j]) }
        return CGRect(x:from.minX+(to.minX-from.minX)*progress(1), y:from.minY+(to.minY-from.minY)*progress(2),
                      width:from.width+(to.width-from.width)*progress(3), height:from.height+(to.height-from.height)*progress(4))
    }
    private static let avatarForward: [[Double]] = [[0,17,777,26,26],[0.086,21.8,765.5,29.7,29.7],[0.139,25.4,756.9,32.5,32.5],[0.187,27.7,751.5,34.2,34.2],[0.233,29.0,748.3,35.2,35.2],[0.273,29.7,746.8,35.7,35.7],[0.315,30.0,746.0,36.0,36.0],[0.356,30.1,745.7,36.1,36.1],[0.395,30.1,745.7,36.1,36.1],[0.431,30.1,745.7,36.1,36.1],[0.465,30.1,745.8,36.1,36.1],[0.502,30.1,745.8,36.1,36.1],[0.536,30,745.9,36,36],[0.569,30,745.9,36,36],[0.602,30,746.0,36,36],[0.636,30,746,36,36],[0.669,30,746,36,36],[0.686,30,746,36,36]]
    private static let avatarReverse: [[Double]] = [[0,30,746,36,36],[0.036,28.8,748.9,35.1,35.1],[0.074,26.1,755.4,33.0,33.0],[0.223,18.2,774.1,26.9,26.9],[0.257,17.5,775.7,26.4,26.4],[0.302,17.1,776.8,26.1,26.1],[0.336,16.9,777.2,25.9,25.9],[0.369,16.9,777.3,25.9,25.9],[0.402,16.9,777.3,25.9,25.9],[0.436,16.9,777.3,25.9,25.9],[0.469,16.9,777.2,25.9,25.9],[0.502,16.9,777.2,25.9,25.9],[0.536,17,777.1,26,26],[0.569,17,777.1,26,26],[0.602,17,777.0,26,26],[0.636,17,777,26,26],[0.669,17,777,26,26],[0.686,17,777,26,26]]
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

/// Reserved integration seam for D 0.3's composer-to-bubbles work. The Dock must own its sharp
/// glass topology; ModeFlight may provide a clock, but must never mount a second glass over it.
struct ModeFlightDockRequest {
    let toOrganic: Bool
    let mediaTime: Double
    let composer: (from: CGRect, to: CGRect, slot: Int)?
    let reversing: Bool
}

@MainActor protocol ModeFlightDockBridge: AnyObject {
    var materialIsVisible: Bool { get }
    var materialHasLanded: Bool { get }
    func beginModeFlight(_ request: ModeFlightDockRequest)
    func sampleModeFlight(elapsed: Double)
    func endModeFlight(landed: Bool)
}
