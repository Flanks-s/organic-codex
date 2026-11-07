import CoreGraphics
import Foundation

/// A geometric approximation of container fusion, applied after the original exposure calculation.
/// Logical poses and exposure profiles remain unchanged. Only facing glass edges are constrained.
final class DockGlassTopology {
    struct Shape {
        let id: String
        let logical: CGRect
        let target: CGRect
        let painted: CGRect
        let locked: Bool
        init(id: String, logical: CGRect, target: CGRect, painted: CGRect, locked: Bool = false) {
            self.id=id;self.logical=logical;self.target=target;self.painted=painted;self.locked=locked
        }
    }
    // Diagnostic capture is active only inside an opt-in display-frame scope.
    private var capturesFrameLog = false
    private var frameLogPairSteps: [[String: Any]] = []
    private(set) var frameLogPasses: [[String: Any]] = []
    func beginFrameLog() { capturesFrameLog = true; frameLogPasses.removeAll(keepingCapacity: true) }
    func endFrameLog() { capturesFrameLog = false; frameLogPasses.removeAll(keepingCapacity: true) }
    private func captureFrameLog(_ shapes: [Shape], paint: [String: CGRect], spacing: CGFloat, monotonic: Bool, time: Double, cached: Bool, carriedIDs:Set<String>) {
        let horizontal = shapes.sorted { $0.logical.midX < $1.logical.midX }
        var rows: [[String: Any]] = []
        for i in shapes.indices { for j in shapes.indices where j > i {
            let a = shapes[i], b = shapes[j], pair = pairs[a.id + "|" + b.id]
            let pa = paint[a.id] ?? a.painted, pb = paint[b.id] ?? b.painted
            let ai = horizontal.firstIndex(where: { $0.id == a.id })!, bi = horizontal.firstIndex(where: { $0.id == b.id })!
            rows.append(["a": a.id, "b": b.id, "adjacentByLogicalX": abs(ai-bi) == 1,
                         "logicalGap": Self.gap(a.logical,b.logical), "targetGap": Self.gap(a.target,b.target),
                         "paintedGapBefore": Self.gap(a.painted,b.painted), "paintedGapResolved": Self.gap(pa,pb),
                         "connected": pair.map { $0.connected as Any } ?? NSNull(),
                         "changedInTransition": pair.map { $0.changed as Any } ?? NSNull(),
                         "destinationConnected": Self.gap(a.target,b.target) <= spacing,
                         "connectionPolicy":carriedIDs.isEmpty ? "layout":(carriedIDs.contains(a.id) || carriedIDs.contains(b.id) ? "pointer":"target"),
                         "aEdgesLimited": pa != a.painted, "bEdgesLimited": pb != b.painted])
        } }
        frameLogPasses.append(["time":time,"began":began.isFinite ? began as Any : NSNull(),
            "monotonic":monotonic,"sameFrameRetargetCache":cached,"spacing":spacing,
            "hysteresis":Self.hysteresis,"clearance":Self.clearance,"safeMarginEnabled":Self.safeMarginEnabled,"finalResidual":finalResidual,"pairs":rows,"pairSteps":frameLogPairSteps,
            "groups":shapes.map { ["id":$0.id,"logical":DockFrameLog.rect($0.logical),"target":DockFrameLog.rect($0.target),
                                  "paintedBefore":DockFrameLog.rect($0.painted),"resolved":DockFrameLog.rect(paint[$0.id] ?? $0.painted)] as [String:Any] }])
    }
    private struct Pair { var connected: Bool; var changed = false }
    private var pairs: [String: Pair] = [:]
    private var began = -Double.infinity
    private var lastTime: Double?
    private var lastLogical: [String: CGRect] = [:]
    private var lastPaint: [String: CGRect] = [:]
    static let hysteresis: CGFloat = 0.5
    static let safeMarginEnabled = ProcessInfo.processInfo.environment["DOCK_SAFE_MARGIN"] != "0"
    static let clearance: CGFloat = 0.125
    static let separatedGap: CGFloat = 12
    static let connectedOverlap: CGFloat = 1
    private(set) var finalResidual: CGFloat = 0
    func connected(_ a: String, _ b: String) -> Bool? { pairs[[a,b].sorted().joined(separator:"|")]?.connected }

    /// Project facing edges together. A node's left and right boundaries are independent variables.
    /// This horizontal Dock contract includes every physical part when the owner bounds are applied.
    private func projectContours(_ shapes: [Shape], paint: inout [String: CGRect]) {
        let ordered = shapes.sorted { $0.logical.midX < $1.logical.midX }
        let locked=Set(shapes.filter(\.locked).map(\.id))
        for shape in shapes where shape.locked { paint[shape.id]=shape.painted }
        struct Constraint { let left: String; let right: String; let connected: Bool }
        var constraints: [Constraint] = []
        for i in ordered.indices { for j in ordered.indices where j > i {
            let a=ordered[i], b=ordered[j]
            let vertical=min(a.logical.maxY,b.logical.maxY)-max(a.logical.minY,b.logical.minY)
            guard vertical > min(a.logical.height,b.logical.height)*0.25,
                  let joined=connected(a.id,b.id) else { continue }
            constraints.append(Constraint(left:a.id,right:b.id,connected:joined))
        } }
        // Alternating projection converges shared-edge constraints; verify the whole result afterwards.
        for _ in 0..<64 {
            var maximum: CGFloat = 0
            for c in constraints {
                guard var a=paint[c.left], var b=paint[c.right] else { continue }
                let gap=b.minX-a.maxX
                let correction=c.connected ? max(0,gap+Self.connectedOverlap) : max(0,Self.separatedGap-gap)
                maximum=max(maximum,correction)
                guard correction > 1e-8 else { continue }
                let leftShare=locked.contains(c.left) ? 0 : (locked.contains(c.right) ? correction:correction/2)
                let rightShare=locked.contains(c.right) ? 0 : correction-leftShare
                if c.connected { a.size.width += leftShare; b.origin.x -= rightShare; b.size.width += rightShare }
                else {
                    let trimA=min(leftShare,max(0,a.width-0.01)), trimB=min(rightShare,max(0,b.width-0.01))
                    a.size.width -= trimA; b.origin.x += trimB; b.size.width -= trimB
                }
                paint[c.left]=a;paint[c.right]=b
            }
            if maximum < 1e-7 { break }
        }
        finalResidual=0
        for c in constraints {
            guard let a=paint[c.left],let b=paint[c.right] else {continue}
            let gap=b.minX-a.maxX
            finalResidual=max(finalResidual,c.connected ? max(0,gap+Self.connectedOverlap):max(0,Self.separatedGap-gap))
        }
    }

    func reset() { pairs = [:]; began = -Double.infinity; lastTime = nil; lastLogical = [:]; lastPaint = [:] }
    func begin(at time: Double) { began = time; for key in pairs.keys { pairs[key]?.changed = false } }
    /// A visible segment identity becomes the same owner's side orb; inherit its physical pair states.
    func adoptIdentity(_ identity: String, as owner: String) {
        for (key,value) in Array(pairs) {
            let ids=key.components(separatedBy:"|")
            guard ids.count==2,ids.contains(identity) else {continue}
            let other=ids[0]==identity ? ids[1]:ids[0]
            guard other != owner else {continue}
            pairs[[owner,other].sorted().joined(separator:"|")]=value
        }
    }
    func shiftClock(by delta: Double) { if began.isFinite { began += delta }; if lastTime != nil { lastTime! += delta } }
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(max(0, max(a.minX - b.maxX, b.minX - a.maxX)),
              max(0, max(a.minY - b.maxY, b.minY - a.maxY)))
    }

    func resolve(_ shapes: [Shape], spacing: CGFloat, monotonic: Bool, at time: Double, carriedIDs:Set<String> = []) -> [String: CGRect] {
        finalResidual = 0
        if capturesFrameLog { frameLogPairSteps.removeAll(keepingCapacity: true) }
        let sorted = shapes.sorted { $0.id < $1.id }
        var paint = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.painted) })
        let loggedCacheHit = capturesFrameLog && monotonic && abs(time-began)<1e-9 && lastTime == time
        defer {
            if capturesFrameLog {
                captureFrameLog(sorted, paint: paint, spacing: spacing, monotonic: monotonic, time: time,
                                cached: loggedCacheHit,carriedIDs:carriedIDs)
            }
        }
        defer { lastTime = time; lastLogical = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id,$0.logical) }); lastPaint = paint }
        if !Self.safeMarginEnabled, monotonic, abs(time-began)<1e-9, lastTime == time {
            // Retargeting in the same display frame cannot change already presented glass bounds.
            for shape in sorted {
                if let old=lastLogical[shape.id], let prior=lastPaint[shape.id],
                   max(abs(old.minX-shape.logical.minX),abs(old.minY-shape.logical.minY),abs(old.width-shape.logical.width),abs(old.height-shape.logical.height))<1e-6 {
                    paint[shape.id] = prior
                }
            }
            return paint
        }
        guard sorted.count > 1 else { return paint }
        for i in 0..<(sorted.count - 1) {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j], key = a.id + "|" + b.id
                let distance = Self.gap(a.logical, b.logical)
                var pair = pairs[key] ?? Pair(connected: distance <= spacing)
                let destination = Self.gap(a.target, b.target) <= spacing
                let followsTarget = !carriedIDs.isEmpty && !carriedIDs.contains(a.id) && !carriedIDs.contains(b.id)
                let directed = monotonic
                if followsTarget {
                    // Only a changed layout destination can change a non-carried pair during a drag.
                    // Spring overshoot and shutter extension cannot create a temporary connection.
                    if pair.connected != destination {pair.connected=destination;pair.changed=true}
                } else if (!directed || time > began + 1e-9) && (!directed || !pair.changed) {
                    if pair.connected && distance > spacing + Self.hysteresis && (!directed || !destination) {
                        pair.connected = false; pair.changed = true
                    } else if !pair.connected && distance < spacing - Self.hysteresis && (!directed || destination) {
                        pair.connected = true; pair.changed = true
                    }
                }
                pairs[key] = pair
                var pa = paint[a.id]!, pb = paint[b.id]!
                let logInput = capturesFrameLog ? (pa, pb) : nil
                let actual = Self.gap(pa, pb)
                if !pair.connected && actual < spacing + Self.clearance {
                    // Remove only exposure facing the neighbour. Retain the furthest safe fraction.
                    let dx = max(0, max(a.logical.minX - b.logical.maxX, b.logical.minX - a.logical.maxX))
                    let dy = max(0, max(a.logical.minY - b.logical.maxY, b.logical.minY - a.logical.maxY))
                    let horizontal = dx >= dy
                    func facing(_ p: CGRect, _ logical: CGRect, _ other: CGRect, _ fraction: CGFloat) -> CGRect {
                        var l = p.minX, r = p.maxX, t = p.minY, d = p.maxY
                        if dx > 0 || horizontal {
                            if logical.midX < other.midX { r = min(p.maxX,logical.maxX) + max(0,p.maxX-logical.maxX) * fraction }
                            else { l = max(p.minX,logical.minX) + min(0,p.minX-logical.minX) * fraction }
                        }
                        if dy > 0 || !horizontal {
                            if logical.midY < other.midY { d = min(p.maxY,logical.maxY) + max(0,p.maxY-logical.maxY) * fraction }
                            else { t = max(p.minY,logical.minY) + min(0,p.minY-logical.minY) * fraction }
                        }
                        return CGRect(x: l, y: t, width: max(0.01, r-l), height: max(0.01, d-t))
                    }
                    let ca = facing(pa, a.logical, b.logical, 0), cb = facing(pb, b.logical, a.logical, 0)
                    if Self.gap(ca, cb) >= spacing + Self.clearance {
                        var low: CGFloat = 0, high: CGFloat = 1
                        for _ in 0..<16 {
                            let k = (low + high)/2
                            if Self.gap(facing(pa,a.logical,b.logical,k), facing(pb,b.logical,a.logical,k)) >= spacing + Self.clearance { low = k }
                            else { high = k }
                        }
                        pa = facing(pa,a.logical,b.logical,low); pb = facing(pb,b.logical,a.logical,low)
                    } else {
                        // A latched separation survives the spring's small endpoint rebound. This is paint only.
                        pa = ca; pb = cb
                        let otherGap = horizontal ? max(0,max(pa.minY-pb.maxY,pb.minY-pa.maxY)) : max(0,max(pa.minX-pb.maxX,pb.minX-pa.maxX))
                        let required = sqrt(max(0,pow(spacing + Self.clearance,2)-otherGap*otherGap))
                        let current = horizontal ? max(pa.minX-pb.maxX,pb.minX-pa.maxX) : max(pa.minY-pb.maxY,pb.minY-pa.maxY)
                        let trim = max(0,required-current)/2
#if M10_DOCK_SELFTEST
                        if trim > 3, ProcessInfo.processInfo.environment["TOPOLOGY_DEBUG"] == "1" { print("TOPOLOGY TRIM \(key) \(trim) logical=\(distance)") }
#endif
                        if horizontal {
                            if a.logical.midX < b.logical.midX { pa.size.width = max(0.01,pa.width-trim); pb.origin.x += trim; pb.size.width = max(0.01,pb.width-trim) }
                            else { pb.size.width = max(0.01,pb.width-trim); pa.origin.x += trim; pa.size.width = max(0.01,pa.width-trim) }
                        } else {
                            if a.logical.midY < b.logical.midY { pa.size.height = max(0.01,pa.height-trim); pb.origin.y += trim; pb.size.height = max(0.01,pb.height-trim) }
                            else { pb.size.height = max(0.01,pb.height-trim); pa.origin.y += trim; pa.size.height = max(0.01,pa.height-trim) }
                        }
                    }
                } else if pair.connected && actual > spacing {
                    // The same half-point hysteresis keeps an established neck through a small rebound.
                    let dx = max(0,max(pa.minX-pb.maxX,pb.minX-pa.maxX)), dy = max(0,max(pa.minY-pb.maxY,pb.minY-pa.maxY))
                    let amount = max(0,actual-spacing+Self.clearance)/2
                    let x = amount*dx/max(0.01,actual), y = amount*dy/max(0.01,actual)
                    if pa.midX < pb.midX { pa.size.width += x; pb.origin.x -= x; pb.size.width += x }
                    else { pb.size.width += x; pa.origin.x -= x; pa.size.width += x }
                    if pa.midY < pb.midY { pa.size.height += y; pb.origin.y -= y; pb.size.height += y }
                    else { pb.size.height += y; pa.origin.y -= y; pa.size.height += y }
                }
                paint[a.id] = pa; paint[b.id] = pb
                if let input = logInput {
                    frameLogPairSteps.append(["a":a.id,"b":b.id,"logicalGap":distance,
                        "paintedGapBefore":actual,"paintedGapAfter":Self.gap(pa,pb),
                        "connected":pair.connected,"changedInTransition":pair.changed,"monotonic":directed,
                        "connectionPolicy":followsTarget ? "target":(carriedIDs.isEmpty ? "layout":"pointer"),
                        "destinationConnected":destination,"aEdgesLimited":pa != input.0,"bEdgesLimited":pb != input.1,
                        "aBefore":DockFrameLog.rect(input.0),"bBefore":DockFrameLog.rect(input.1),
                        "aAfter":DockFrameLog.rect(pa),"bAfter":DockFrameLog.rect(pb)])
                }
            }
        }
        if Self.safeMarginEnabled { projectContours(sorted,paint:&paint) }
        return paint
    }
}

extension RectSpring {
    /// CGRect geometry accessors standardize negative sizes. A velocity is four signed rates instead.
    /// Keep this correction local to Dock retargeting; other animation paths retain their existing API.
    init(dockFrom from: CGRect, to: CGRect, velocity: CGRect = .zero, response: Double, damping: Double) {
        let extent = Double(max(from.width, from.height, to.width, to.height, 1))
        let e = min(Spring.restEpsilon, 0.002 * extent)
        x = Spring(from: from.minX, to: to.minX, velocity: velocity.origin.x, response: response, damping: damping, epsilon: e)
        y = Spring(from: from.minY, to: to.minY, velocity: velocity.origin.y, response: response, damping: damping, epsilon: e)
        w = Spring(from: from.width, to: to.width, velocity: velocity.size.width, response: response, damping: damping, epsilon: e)
        h = Spring(from: from.height, to: to.height, velocity: velocity.size.height, response: response, damping: damping, epsilon: e)
    }
}
