// Copied from System Animation's Model/FocusLayout.swift (not shared), without the satellite rows Shell v2 draws
// elsewhere.
import CoreGraphics

/// Focused / Split geometry (spec §6.2–6.4), in the detail view's top-left coordinates.
/// The bar or capsule is pinned under the main content, centred; it does not move when orbs come and go
/// unless they no longer fit beside it. Orbs line up outward on both sides.
struct FocusLayout: Equatable {
    /// One transcript column per capsule segment, aligned with it.
    var columns: [CGRect] = []
    var capsule: CGRect = .zero
    var segments: [CGRect] = []
    /// x of each divider between segments.
    var dividers: [CGFloat] = []
    /// me, embedded at the capsule's left end (36 pt).
    var me: CGRect = .zero
    var leftOrbs: [CGRect] = []
    var rightOrbs: [CGRect] = []

    init() {}

    /// How many segments Split has room for at a width: each needs FocusLayout's narrowest, 220 pt, and the window's
    /// other `members` become orbs beside the capsule, which need room too, at the 0.6 size they may close up to
    /// (2026-10-25 Astra r3: at 720 pt, three segments left the orbs outside the window).
    static func capacity(width: CGFloat, members: Int = 0, metrics m: AutoLayout.Metrics) -> Int {
        let most = max(1, Int((max(0, width - 2 * m.inset) + m.gap) / (220 + m.gap)))
        for n in stride(from: members > 0 ? min(most, members) : most, through: 1, by: -1) {
            let perSide = CGFloat((max(0, members - n) + 1) / 2)
            let side = perSide > 0 ? m.orbGap + perSide * (m.orb * 0.6 + 4) + 6 : m.inset
            if CGFloat(n) * 220 + CGFloat(n - 1) * m.gap + 2 * side <= width { return n }
        }
        return 1
    }

    init(size: CGSize, segments n: Int, leftOrbs l: Int, rightOrbs r: Int, satellites: Bool, metrics m: AutoLayout.Metrics) {
        let n = max(1, n)
        // me sits in the bar at its own size (36 in a 48 bar; it was 90 % of the bar, 52 pt in a tall window).
        let embedded = min(m.me, m.barHeight - 4)
        // The sub-agents' row lives in the dock's bottom margin, the same in every arrangement: it never lifts the capsule
        // (2026-10-25, the user: two rows pushed it up).
        let satelliteBand: CGFloat = 0
        let rowY = size.height - m.bottomInset - satelliteBand - m.barHeight / 2
        let content = max(0, size.width - 2 * m.inset)
        let reserve = CGFloat(max(l, r)) * (m.orb + m.orbGap) + m.orbGap
        let available = max(320, content - 2 * reserve)
        // Focused keeps Canopy's reading width (740 + dock margins); Split shares the width evenly.
        let cap: CGFloat = n == 1 ? 768 : 740
        let per = max(220, min(cap, (available - CGFloat(n - 1) * m.gap) / CGFloat(n)))
        let total = per * CGFloat(n) + CGFloat(n - 1) * m.gap
        let x0 = (size.width - total) / 2
        let top = m.topInset, bottom = rowY - m.barHeight / 2 - m.dockGap
        for i in 0..<n {
            let x = x0 + CGFloat(i) * (per + m.gap)
            columns.append(CGRect(x: x, y: top, width: per, height: max(0, bottom - top)))
            let left = i == 0 ? x0 : x - m.gap / 2
            let right = i == n - 1 ? x0 + total : x + per + m.gap / 2
            segments.append(CGRect(x: left, y: rowY - m.barHeight / 2, width: right - left, height: m.barHeight))
            if i > 0 { dividers.append(x - m.gap / 2) }
        }
        capsule = CGRect(x: x0, y: rowY - m.barHeight / 2, width: total, height: m.barHeight)
        me = CGRect(x: x0 + (m.barHeight - embedded) / 2, y: rowY - embedded / 2, width: embedded, height: embedded)
        // Orbs that would run past the window's edge close up: smaller, down to 0.6 of their size, then overlapping, so
        // every one stays in the window and in reach (2026-10-25 review r2: a narrow Split put them off the window).
        func side(_ count: Int, room: CGFloat) -> (size: CGFloat, step: CGFloat) {
            let span = CGFloat(count) * m.orb + CGFloat(max(0, count - 1)) * m.orbGap
            guard count > 0, span > room else { return (m.orb, m.orb + m.orbGap) }
            let scale = max(0, room) / span
            if scale >= 0.6 { return (m.orb * scale, (m.orb + m.orbGap) * scale) }
            let size = m.orb * 0.6
            return (size, count > 1 ? max(0, room - size) / CGFloat(count - 1) : 0)
        }
        let edge: CGFloat = 6
        let left = side(l, room: x0 - m.orbGap - edge), right = side(r, room: size.width - edge - (x0 + total + m.orbGap))
        for k in 0..<l {
            let midX = x0 - m.orbGap - left.size / 2 - CGFloat(k) * left.step
            leftOrbs.append(CGRect(x: midX - left.size / 2, y: rowY - left.size / 2, width: left.size, height: left.size))
        }
        for k in 0..<r {
            let midX = x0 + total + m.orbGap + right.size / 2 + CGFloat(k) * right.step
            rightOrbs.append(CGRect(x: midX - right.size / 2, y: rowY - right.size / 2, width: right.size, height: right.size))
        }
    }

    /// The orbs under the pointer (the macOS Dock's magnification, as in Auto): each grows toward `orbMagnified` with
    /// a cosine falloff over `magnifyReach` resting slots, up from where it rests; each side re-packs outward from the
    /// capsule, so the capsule never moves.
    func magnified(pointerX x: CGFloat?, amount: CGFloat, metrics m: AutoLayout.Metrics) -> FocusLayout {
        guard let x, amount > 0.001, m.orbMagnified > m.orb, !(leftOrbs.isEmpty && rightOrbs.isEmpty) else { return self }
        let reach = max(1, m.magnifyReach) * (m.orb + m.orbGap)
        func size(_ r: CGRect) -> CGFloat {
            let d = abs(x - r.midX) / reach
            return r.width + (m.orbMagnified - m.orb) * (r.width / m.orb) * (d < 1 ? (cos(d * .pi) + 1) / 2 : 0) * amount
        }
        // A side closed up to fit the window grows in place: re-packed outward, its outer orbs would leave it again.
        func grown(_ r: CGRect) -> CGRect {
            let s = size(r)
            return CGRect(x: r.midX - s / 2, y: r.maxY - s, width: s, height: s)
        }
        var out = self
        if leftOrbs.first.map({ $0.width < m.orb - 0.5 }) ?? false {
            out.leftOrbs = leftOrbs.map(grown)
        } else {
            var cursor = capsule.minX - m.orbGap
            out.leftOrbs = leftOrbs.map { r in
                let s = size(r)
                defer { cursor -= s + m.orbGap }
                return CGRect(x: cursor - s, y: r.maxY - s, width: s, height: s)
            }
        }
        if rightOrbs.first.map({ $0.width < m.orb - 0.5 }) ?? false {
            out.rightOrbs = rightOrbs.map(grown)
        } else {
            var cursor = capsule.maxX + m.orbGap
            out.rightOrbs = rightOrbs.map { r in
                let s = size(r)
                defer { cursor += s + m.orbGap }
                return CGRect(x: cursor, y: r.maxY - s, width: s, height: s)
            }
        }
        return out
    }

    /// Where the dock is when it has risen, as Auto's (`AutoLayout.raised`): the capsule, its segments, me and the orbs
    /// `hoverRise` higher, sizes unchanged. The columns keep their place.
    func raised(_ q: CGFloat, metrics m: AutoLayout.Metrics) -> FocusLayout {
        let rise = m.hoverRise * q
        guard rise > 0.01 else { return self }
        var out = self
        out.capsule = capsule.offsetBy(dx: 0, dy: -rise)
        out.segments = segments.map { $0.offsetBy(dx: 0, dy: -rise) }
        out.me = me.offsetBy(dx: 0, dy: -rise)
        out.leftOrbs = leftOrbs.map { $0.offsetBy(dx: 0, dy: -rise) }
        out.rightOrbs = rightOrbs.map { $0.offsetBy(dx: 0, dy: -rise) }
        return out
    }

    /// Where a dropped orb joins the capsule: before the first segment whose centre is right of `x`.
    func graftIndex(at x: CGFloat) -> Int { segments.firstIndex { x < $0.midX } ?? segments.count }
}
