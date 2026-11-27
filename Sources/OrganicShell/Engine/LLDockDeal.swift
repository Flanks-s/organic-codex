import Foundation

/// SunHover02 LAP, with its own elapsed clock. It has no mode-flight switch or reversal dependency.
enum LLDockDeal {
    static let condense = 0.16, entry = 0.42, reserve = 0.66, exit = 0.80, duration = 1.22
    enum Owner: String { case flight, dock }
    struct Pose {
        let center: CGPoint
        let diameter: Double
        let glyph: Double
        let opacity: Double
        let depth: Int
        let owner: Owner
        let needsReservation: Bool
        let kick: Double
    }
    struct Plan {
        let conversationID: String
        let source: CGPoint
        let reduceMotion: Bool
        func pose(at time: Double, llCenter: CGPoint, dockSlot: CGPoint) -> Pose {
            let t = max(0, time)
            if t >= duration {
                return .init(center: dockSlot, diameter: 32, glyph: 1, opacity: 1, depth: 10, owner: .dock, needsReservation: true, kick: 0)
            }
            if reduceMotion {
                return .init(center: dockSlot, diameter: 32, glyph: 1, opacity: SunHoverGeometry.smooth((t - reserve) / 0.12),
                             depth: 18, owner: .flight, needsReservation: t >= reserve, kick: 0)
            }
            func size(_ z: Double) -> Double { 20 * (1 + 0.18 * z) }
            let center: CGPoint, diameter: Double, glyph: Double, depth: Int
            if t < condense {
                let q = SunHoverGeometry.smooth(t / condense)
                center = source; diameter = 16 + 6 * q; glyph = q; depth = 30
            } else if t < entry {
                let p = ring(at: entry, center: llCenter), u = bezier(0.35, 0, 0.7, 0.85, (t - condense) / 0.26)
                let speed = max(1e-12, hypot(p.tangent.x, p.tangent.y)), length = min(40, distance(source, p.point) * 0.35)
                center = cubic(source, mix(source, p.point, 0.3),
                               .init(x: p.point.x - p.tangent.x / speed * length, y: p.point.y - p.tangent.y / speed * length), p.point, u)
                diameter = 22 + (size(p.z) - 22) * u; glyph = 1; depth = 30
            } else if t < exit {
                let p = ring(at: t, center: llCenter)
                center = p.point; diameter = size(p.z); glyph = 1; depth = p.z < 0 ? 15 : 18
            } else {
                let p = ring(at: exit, center: llCenter), u = bezier(0.2, 0.25, 0.18, 1, (t - exit) / 0.42)
                let speed = max(1e-12, hypot(p.tangent.x, p.tangent.y)), length = min(120, distance(p.point, dockSlot) * 0.3)
                center = cubic(p.point, .init(x: p.point.x + p.tangent.x / speed * length, y: p.point.y + p.tangent.y / speed * length - 40),
                               .init(x: dockSlot.x + (p.point.x - dockSlot.x) * 0.22, y: dockSlot.y + (p.point.y - dockSlot.y) * 0.22 - 90), dockSlot, u)
                diameter = u >= 2/3 ? 22 + 10 * (u - 2/3) * 3 : size(p.z) + (22 - size(p.z)) * min(1, u * 3)
                glyph = 1; depth = 18
            }
            return .init(center: center, diameter: diameter, glyph: glyph, opacity: 1, depth: depth,
                         owner: .flight, needsReservation: t >= reserve, kick: t >= exit ? 26 : 0)
        }
    }
    static func ring(at time: Double, center: CGPoint) -> (point: CGPoint, tangent: CGPoint, z: Double) {
        let a = -Double.pi / 2 - 0.35 + 2 * Double.pi / 0.38 * (time - exit), ct = cos(-0.2), st = sin(-0.2)
        let x = 36 * cos(a), y = 20 * sin(a), dx = -36 * sin(a), dy = 20 * cos(a)
        return (.init(x: center.x + x * ct - y * st, y: center.y + x * st + y * ct),
                .init(x: dx * ct - dy * st, y: dx * st + dy * ct), sin(a))
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private static func mix(_ a: CGPoint, _ b: CGPoint, _ q: Double) -> CGPoint { .init(x: a.x + (b.x-a.x)*q, y: a.y + (b.y-a.y)*q) }
    private static func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ q: Double) -> CGPoint {
        let m = 1-q
        return .init(x: m*m*m*a.x + 3*m*m*q*b.x + 3*m*q*q*c.x + q*q*q*d.x,
                     y: m*m*m*a.y + 3*m*m*q*b.y + 3*m*q*q*c.y + q*q*q*d.y)
    }
    private static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        guard x > 0 else { return 0 }; guard x < 1 else { return 1 }
        func f(_ a: Double, _ b: Double, _ t: Double) -> Double { 3*(1-t)*(1-t)*t*a + 3*(1-t)*t*t*b + t*t*t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 { let m = (lo+hi)/2; if f(x1,x2,m) < x { lo=m } else { hi=m } }
        return f(y1,y2,(lo+hi)/2)
    }
}
