import CoreGraphics
import Foundation

/// Read once per process. Zero is the body-only performance control.
enum TideTailBudget {
    static let pieces:Int = {
        let n=Int(ProcessInfo.processInfo.environment["M11_TIDE_TAIL_PIECES"] ?? "") ?? 12
        return [0,8,12,17].contains(n) ? n:12
    }()
}

/// Physical rounded geometry, shared by native placement and detached verification.
struct TideContour {
    struct Part: Equatable {
        let rect: CGRect
        let radius: CGFloat
    }
    let body: Part
    let tail: [Part]
    var parts: [Part] { [body] + tail }
    var bounds: CGRect { tail.reduce(body.rect) { $0.union($1.rect) } }

    init(body rect: CGRect, tailAmount: Double, lean: Double, horizontalVelocity: Double = 0, retracting: Bool = false) {
        let radius = min(rect.width, rect.height) / 2
        body = .init(rect: rect, radius: radius)
        let k = max(0, tailAmount)
        guard k >= 0.02,TideTailBudget.pieces>0 else { tail = []; return }
        let angle = lean + max(-16, min(16, -horizontalVelocity * 0.05))
        let a0 = (angle - 34) * .pi / 180, a1 = angle * .pi / 180
        let center = CGPoint(x: rect.minX + radius, y: rect.midY)
        // Native fusion retains a minimum root. During retreat move that root into its own body.
        let pull=retracting ? max(0,1-min(1,k/0.3))*6:0
        let root = CGPoint(x: center.x + sin(a0) * (radius - 3-pull), y: center.y - cos(a0) * (radius - 3-pull))
        let tip = CGPoint(x: center.x + sin(a1) * (radius + 16 * k-pull), y: center.y - cos(a1) * (radius + 16 * k-pull))
        let length = hypot(tip.x - root.x, tip.y - root.y)
        let control = CGPoint(x: root.x + sin(a0) * length * 0.62, y: root.y - cos(a0) * length * 0.62)
        var discs: [Part] = [], previous: CGPoint?
        // Adaptive overlap keeps even the 1.2 pt tip physically connected, without a mask or painted fill.
        for i in 0...256 {
            let u = Double(i) / 256 * 0.76, v = 1 - u
            let p = CGPoint(x: v * v * root.x + 2 * v * u * control.x + u * u * tip.x,
                            y: v * v * root.y + 2 * v * u * control.y + u * u * tip.y)
            // R1 screen measurements: dense sub-1.9 pt discs grow into a 4–4.5 pt rod.
            // Stop before the goo-erased SVG end and compensate the fused narrow segment.
            let rootBlend = max(0, 1-u/0.35)
            let narrow = min(1,max(0,(u-0.40)/0.25))
            let r = max(0.6, 0.6 + (5.5 * min(1, 0.5 + 0.5 * k) - 0.6) * pow(v, 1.6)
                        + 0.55*rootBlend*rootBlend - 0.95*narrow)
            let spacing = max(0.12, (2 * r - 1) * 0.85)
            if previous == nil || hypot(p.x - previous!.x, p.y - previous!.y) >= spacing || i == 256 {
                discs.append(.init(rect: CGRect(x: p.x-r, y: p.y-r, width: 2*r, height: 2*r), radius: r))
                previous = p
            }
        }
        // Find the smallest uniform radius allowance that can retain a connected subset.
        // The one-point native overlap stays invariant at every debug budget; no large alternating tip discs.
        func chain(_ extra:CGFloat)->[Int] {
            guard !discs.isEmpty else{return []}
            var ids=[0],i=0
            while i<discs.count-1 {
                var next=i+1
                for j in (i+1)..<discs.count {
                    let a=discs[i],b=discs[j]
                    if a.radius+b.radius+2*extra-hypot(a.rect.midX-b.rect.midX,a.rect.midY-b.rect.midY)>=1 {next=j}else{break}
                }
                ids.append(next);i=next
            }
            return ids
        }
        let minimumExtra=(1..<max(1,discs.count)).map {i in
            let a=discs[i-1],b=discs[i]
            return max(0,(1+hypot(a.rect.midX-b.rect.midX,a.rect.midY-b.rect.midY)-a.radius-b.radius)/2)
        }.max() ?? 0
        if discs.count>TideTailBudget.pieces {
            var low:CGFloat=minimumExtra,high:CGFloat=8
            for _ in 0..<24 {let mid=(low+high)/2;if chain(mid).count<=TideTailBudget.pieces {high=mid}else{low=mid}}
            let indices=chain(high+1e-7),extra=high+1e-7
            discs=indices.map {i in let b=discs[i],r=b.radius+extra;return .init(rect:CGRect(x:b.rect.midX-r,y:b.rect.midY-r,width:2*r,height:2*r),radius:r)}
        } else if minimumExtra>0 {
            discs=discs.map {b in let r=b.radius+minimumExtra+1e-6;return .init(rect:CGRect(x:b.rect.midX-r,y:b.rect.midY-r,width:2*r,height:2*r),radius:r)}
        }
        tail = discs
    }

    private init(body:Part,tail:[Part]) {self.body=body;self.tail=tail}
    func limited(to count:Int)->TideContour {TideContour(body:body,tail:Array(tail.prefix(count)))}

    /// Conservative view-envelope clearance includes every tail part and spring overshoot.
    func envelopeGap(to rect: CGRect) -> CGFloat {
        parts.map { Self.gap($0.rect, rect) }.min() ?? .infinity
    }

    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(max(0, max(a.minX-b.maxX, b.minX-a.maxX)), max(0, max(a.minY-b.maxY, b.minY-a.maxY)))
    }

    /// Notification-only admission. Protected neighbours and ordinary orbs are immutable obstacles.
    static func admit(_ proposed: CGRect, obstacles: [CGRect], clearance: CGFloat = 12) -> CGRect? {
        func fits(_ r: CGRect) -> Bool { obstacles.allSatisfy { gap(r, $0) >= clearance } }
        if fits(proposed) { return proposed }
        let minimum = max(32, proposed.height)
        guard proposed.width >= minimum else { return nil }
        var lo = minimum, hi = proposed.width
        func width(_ w: CGFloat) -> CGRect { CGRect(x: proposed.maxX-w, y: proposed.minY, width: w, height: proposed.height) }
        guard fits(width(lo)) else { return nil }
        for _ in 0..<48 { let mid = (lo+hi)/2; if fits(width(mid)) { lo=mid } else { hi=mid } }
        return width(lo)
    }
}
