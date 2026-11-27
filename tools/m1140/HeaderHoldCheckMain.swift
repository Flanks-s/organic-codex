import Foundation

@MainActor final class HeaderHoldFixture: HeaderIslandHoldHost {
    let root = NSObject()
    var x = ["a": CGFloat(0), "b": CGFloat(1)]
    var active = ["a": true, "b": true]
    var hidden = ["a": false, "b": false]
    var headerHoldRoles: [String] { ["a", "b"] }
    func headerHoldCoordinateRoot(for role: String) -> AnyObject? { root }
    func headerHoldOriginalPlacement(for role: String) -> HeaderIslandHold.Placement? {
        .init(root: root, frame: CGRect(x: x[role]!, y: 0, width: 1, height: 1),
              hidden: hidden[role]!, interactive: active[role]!)
    }
    func headerHoldAffectedRoles(for role: String, write: HeaderIslandHold.Write) -> Set<String> { [role] }
    func headerHoldApply(_ pose: HeaderIslandHold.Placement, role: String, write: HeaderIslandHold.Write) {
        if write == .geometry { x[role] = pose.frame.minX }
        if write == .interaction { active[role] = pose.interactive }
        if write == .visibility { hidden[role] = pose.hidden }
    }
}
@main @MainActor enum HeaderHoldCheck {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ value: Bool, _ category: String) {
        checks += 1
        if !value { failures.append(category) }
    }
    static func main() throws {
        let holders = [NSObject(), NSObject(), NSObject()]
        var releasedHost: HeaderHoldFixture? = .init()
        let orphan = HeaderIslandHold(host: releasedHost!)
        check(orphan.canWrite("unlisted", write: .geometry), "hold.fail-open")
        _ = orphan.claim("a", by: holders[0], writes: [.geometry])
        releasedHost = nil
        check(orphan.canWrite("a", write: .geometry) && orphan.findings == ["unlisted": [.geometry]], "hold.fail-open")
        for order in [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]] {
            let h = HeaderHoldFixture()
            let l = HeaderIslandHold(host: h)
            let t = holders.map { l.claim("a", by: $0, writes: [.interaction])! }
            for (index, next) in order.enumerated() {
                check(l.release(t[next]) && !l.release(t[next]), "hold.count")
                check(l.tokens.count == 2 - index && h.active["a"] == (index == 2), "hold.count")
                check(l.canWrite("a", write: .interaction) == (index == 2), "hold.count")
            }
        }
        for reason: HeaderIslandHold.Reason in [.targetChanged, .disposed] {
            let h = HeaderHoldFixture()
            let l = HeaderIslandHold(host: h)
            var revoked = 0
            let pose = HeaderIslandHold.Placement(root: h.root, frame: CGRect(x: 20, y: 0, width: 1, height: 1))
            var hiddenPose = pose
            hiddenPose.hidden = true
            let a = l.claim("a", by: holders[0], writes: [.geometry, .visibility], initial: hiddenPose)!
            let b = l.claim("b", by: holders[1], writes: [.interaction], revoked: { _, _ in revoked += 1 })!
            check(!l.canWrite("a", write: .visibility) && h.hidden["a"] == true && h.x["a"] == 20, "hold.release")
            l.release(a)
            check(h.x["a"] == 0 && h.hidden["a"] == false && h.active["b"] == false, "hold.release")
            _ = l.claim("a", by: holders[0], writes: [.geometry], initial: pose, revoked: { _, _ in revoked += 1 })
            l.invalidate(reason)
            check(l.tokens.isEmpty && !l.validates(b) && revoked == 2, "hold.dispose")
            check(h.x["a"] == 0 && h.active["b"] == true && !l.release(b), "hold.dispose")
            if reason == .targetChanged {
                let fresh = l.claim("b", by: holders[1], writes: [.interaction])!
                check(!l.release(b) && l.validates(fresh), "hold.stale")
            } else { check(l.claim("b", by: holders[1], writes: [.interaction]) == nil, "hold.dispose") }
        }
        let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("report.json")
        let data = try JSONSerialization.data(withJSONObject: ["checks": checks, "failures": failures])
        try data.write(to: out)
        exit(failures.isEmpty ? 0 : 1)
    }
}
