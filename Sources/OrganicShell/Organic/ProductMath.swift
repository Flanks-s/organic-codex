import AppKit
import CoreGraphics
import Foundation

// PRODUCT MATH — copied unchanged from Smear Lab 26102802's OriginalMath.swift (Sol's extraction of the
// current product's Auto layout, dock magnification and morph flight math), so Shell v2 starts from the same
// endpoints, timing and semantics. Shell v2 changes go in their own files, not here.

// Synthetic content topology only; these shims do not import production models or stores.
struct ActivityPart: Equatable { let text: String }
struct BriefLine: Equatable {
    struct Word: Equatable { let text: String; let spaceBefore: Bool; let kept: Bool }
    let words: [Word]; let lyricSize: CGFloat; let current: Bool
}
enum MorphLook: Equatable { case worked(String), activity([ActivityPart], dots: Bool), goal(String, lyricSize: CGFloat, current: Bool), segment(BriefLine) }
enum MorphTarget: Equatable { case fixture }
struct MorphElement: Identifiable, Equatable { let id: String; let look: MorphLook; let target: MorphTarget; var line = 0 }
enum HarnessTuningKey: Hashable, CaseIterable { case autoBriefComfort, autoBriefMax, autoBriefMin, autoBriefShare, autoFullMin, autoFullShare, autoLastBarMin, dockBottom, dockGapRatio, dockHeightRatio, dockHoverRise, dockMagnify, dockMagnifyReach, dockMaxHeight, dockMe, dockMinHeight, dockOrbGap, dockOrbRest, morphBurst, morphPop, morphStagger, morphSwirl, autoResponse, autoDamping, queueResponse, queueDamping, focusResponse, focusDamping }
/// The product's harness tuning: the scene's layout metrics, morph style and springs, at their defaults unless the
/// Debug panel set them (Debug/DebugTuningBinding; f009). Shared by every window, as the panel's settings are.
@MainActor final class Tuning {
    static let shared = Tuning()
    private let defaults: [HarnessTuningKey: Double] = [.autoBriefComfort: 300, .autoBriefMax: 420, .autoBriefMin: 220, .autoBriefShare: 0.25, .autoFullMin: 480, .autoFullShare: 0.4, .autoLastBarMin: 160, .dockBottom: 32, .dockGapRatio: 0.033, .dockHeightRatio: 0.071, .dockHoverRise: 12, .dockMagnify: 1.0, .dockMagnifyReach: 2.4, .dockMaxHeight: 48, .dockMe: 0.75, .dockMinHeight: 40, .dockOrbGap: 0.75, .dockOrbRest: 0.67, .morphBurst: 28, .morphPop: 0.12, .morphStagger: 0.035, .morphSwirl: 35,
        .autoResponse: Motion.response, .autoDamping: Motion.damping, .queueResponse: 0.30, .queueDamping: 0.80, .focusResponse: 0.40, .focusDamping: 0.82]
    private var overrides: [HarnessTuningKey: Double] = [:]
    subscript(_ key: HarnessTuningKey) -> Double { overrides[key] ?? defaults[key]! }
    /// Takes these values (a default drops its override); true when anything changed.
    func apply(_ values: [HarnessTuningKey: Double]) -> Bool {
        var next = overrides
        for (key, value) in values { next[key] = value == defaults[key] ? nil : value }
        guard next != overrides else { return false }
        overrides = next; return true
    }
    var autoSpring: (response: Double, damping: Double) { (self[.autoResponse], self[.autoDamping]) }
    var queueSpring: (response: Double, damping: Double) { (self[.queueResponse], self[.queueDamping]) }
    var focusSpring: (response: Double, damping: Double) { (self[.focusResponse], self[.focusDamping]) }
}

struct MorphFlightStyle: Equatable {
    /// How far an element bursts out of its place before it is flung on (0: a straight glide).
    var burst: CGFloat
    /// The burst's turn away from straight out, in degrees, the same way for every element, so a stack of them fans out
    /// and swings round onto its places like the satellites' fling instead of moving along its own line.
    var swirl: Double
    /// The landing pop, as extra scale at its peak.
    var pop: CGFloat
    /// Each line leaves this much of the way after the one below it; a line's words follow one another a quarter as fast.
    var stagger: Double

    @MainActor static var tuned: MorphFlightStyle {
        let t = Tuning.shared
        return MorphFlightStyle(burst: t[.morphBurst], swirl: t[.morphSwirl], pop: t[.morphPop], stagger: t[.morphStagger])
    }
}


// PRIVATE CANDIDATE — not compiled or integrated. FlightPlan below is moved verbatim
// from ColumnMorph.swift; the accompanying patch makes the SwiftUI Lab and native
// surface call the same factory/pose/phase/reveal functions.

enum MorphFlightMath {
    typealias Centre = (point: CGPoint, count: Int)
    struct Pose {
        let origin: CGPoint
        let scale: CGFloat
        let opacity: Double
        /// Unit anchor in the already prepared look's local top-left coordinate system.
        let anchor: CGPoint
    }
    struct Phase { let opacity: Double; let scale: CGFloat }
    struct Reveal { let opacity: Double; let offsetY: CGFloat; let blurRadius: CGFloat; let scale: CGFloat }
    enum RevealStyle: String { case gaussSlide = "gauss-slide", gauss, slide }
    /// Read once per process so every prepared plan and its interruption use the same treatment.
    static let revealStyle = RevealStyle(rawValue: ProcessInfo.processInfo.environment["M11_REVEAL_STYLE"] ?? "gauss-slide") ?? .gaussSlide
    static let revealSlide: Double = {
        guard let raw = ProcessInfo.processInfo.environment["M11_REVEAL_SLIDE_PT"],
              let value = Double(raw), value.isFinite else { return 6 }
        return value
    }()
    static func revealPose(_ t: Double, full: Bool, moves: Bool = true, style: RevealStyle = revealStyle) -> Reveal {
        let remaining = 1 - t
        let gaussian = moves && style != .slide
        return Reveal(opacity: t,
                      offsetY: !full && moves ? CGFloat(remaining * (style == .slide ? 10 : (style == .gaussSlide ? revealSlide : 0))) : 0,
                      blurRadius: gaussian ? CGFloat(10 * remaining) : 0,
                      scale: gaussian ? 1 + CGFloat((full ? 0.02 : 0.04) * remaining) : 1)
    }

    static func centre(_ departures: [CGRect]) -> Centre? {
        guard !departures.isEmpty else { return nil }
        let n = CGFloat(departures.count)
        return (CGPoint(x: departures.map(\.midX).reduce(0, +) / n,
                        y: departures.map(\.midY).reduce(0, +) / n), departures.count)
    }

    static func makePlan(element: MorphElement, from t: CGRect, to b: CGRect,
                         towardBrief: Bool, style: MorphFlightStyle, span: CGFloat,
                         centre: Centre?, present: Bool) -> FlightPlan {
        let departure = towardBrief ? t : b
        let c = centre?.point ?? CGPoint(x: departure.midX, y: departure.midY)
        let dx = departure.midX - c.x, dy = departure.midY - c.y, length = hypot(dx, dy)
        let straight = (centre?.count ?? 0) < 2 || length < 1
            ? CGVector(dx: 0, dy: -1) : CGVector(dx: dx / length, dy: dy / length)
        let turn = style.swirl * .pi / 180
        var away = CGVector(dx: straight.dx * cos(turn) - straight.dy * sin(turn),
                            dy: straight.dx * sin(turn) + straight.dy * cos(turn))
        if departure.minX + away.dx * style.burst < 0 || departure.maxX + away.dx * style.burst > span { away.dx = -away.dx }
        let travel = self.travel(t, b)
        let burst = style.burst * travel
        let handle = CGPoint(x: departure.minX + away.dx * burst * 2.25,
                             y: departure.minY + away.dy * burst * 2.25)
        let (c1, c2) = towardBrief ? (handle, b.origin) : (t.origin, handle)
        let anchor: FlightPlan.Anchor = switch element.look {
        case .segment: .leading
        case .goal: .trailing
        default: .center
        }
        return FlightPlan(p0: t.origin, c1: c1, c2: c2, p1: b.origin, towardBrief: towardBrief,
                          delay: min(0.5, min(Double(element.line), 6) * style.stagger * Double(travel)),
                          travel: Double(travel), pop: style.pop, present: present,
                          fromWidth: t.width, toWidth: b.width, anchor: anchor)
    }

    /// Presentation-only endpoint movement. The accepted departure/group and original
    /// direction remain inputs; no packet, native view or indicator is involved.
    @discardableResult static func updateDestination(_ next: CGRect, element: MorphElement,
        from: CGRect, destination: inout CGRect, plan: inout FlightPlan,
        style: MorphFlightStyle, span: CGFloat, centre: Centre?) -> Bool {
        guard destination != next else { return false }
        destination = next
        plan = makePlan(element: element, from: from, to: next,
                        towardBrief: plan.towardBrief, style: style, span: span,
                        centre: centre, present: plan.present)
        return true
    }

    static func travel(_ t: CGRect, _ b: CGRect) -> CGFloat {
        CGFloat(smoothstep(4, 40, Double(hypot(b.minX - t.minX, b.minY - t.minY))))
    }

    static func pose(_ plan: FlightPlan, form: Double) -> Pose {
        let u = plan.u(form), qi = plan.progress(form)
        let origin = plan.point(u)
        // Only the goal width correction clamps u. Cubic extrapolation, phase scale
        // and dim continue through the analytic spring's overshoot unchanged.
        let clamped = min(1, max(0, u))
        let x = plan.anchor == .trailing
            ? origin.x + (plan.fromWidth + (plan.toWidth - plan.fromWidth) * clamped) - plan.toWidth
            : origin.x
        let pop = 1 + plan.pop * CGFloat(plan.travel) * CGFloat(sin(.pi * min(1, max(0, (qi - 0.7) / 0.3))))
        let anchor: CGPoint = switch plan.anchor {
        case .leading: CGPoint(x: 0, y: 0)
        case .trailing: CGPoint(x: 1, y: 0)
        case .center: CGPoint(x: 0.5, y: 0.5)
        }
        return Pose(origin: CGPoint(x: x, y: origin.y), scale: pop,
                    opacity: plan.present ? 1 : 1 - smoothstep(0.55, 0.95, qi), anchor: anchor)
    }

    static func phase(_ plan: FlightPlan, form: Double, range: ClosedRange<Double>? = nil,
                      out: Bool = false, dim: (from: Double, to: Double)? = nil,
                      scale: CGFloat? = nil) -> Phase {
        let u = Double(plan.u(form))
        let fade = range.map { r in out ? 1 - smoothstep(r.lowerBound, r.upperBound, u)
                                         : smoothstep(r.lowerBound, r.upperBound, u) } ?? 1
        let level = dim.map { $0.from + ($0.to - $0.from) * u } ?? 1
        return Phase(opacity: fade * level, scale: scale.map { $0 + (1 - $0) * CGFloat(u) } ?? 1)
    }

    static func segmentRange(kept: Bool, ownOrdinal: Int) -> ClosedRange<Double> {
        if kept { return 0.14...0.36 }
        let end = 0.92, start = min(end - 0.15, 0.5 + 0.03 * Double(min(ownOrdinal, 10)))
        return start...end
    }

    static func lyricLevel(current: Bool, hovering: Bool) -> Double {
        current ? 1 : (hovering ? 0.62 : 0.34)
    }

    static func transcriptOpacity(form: Double, on: Bool) -> Double {
        on ? smoothstep(0.45, 0.9, form) : 1
    }

    static func reveal(amount: Double, order: Int, on: Bool, moves: Bool = true) -> Reveal {
        let start = min(0.62, 0.35 + 0.06 * Double(min(order, 5)))
        let t = on ? smoothstep(start, min(1, start + 0.35), amount) : 1
        return revealPose(t, full: false, moves: moves)
    }
}

/// One element's flight, decided when the change begins: where it goes (a cubic sampled by distance), when it leaves,
/// how it pops, which edge it keeps. `u` is how far along it is, 0 at its place in the transcript, 1 in the brief.
struct FlightPlan {
    enum Anchor { case leading, trailing, center }
    let p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint
    let towardBrief: Bool
    let delay: Double
    let travel: Double
    let pop: CGFloat
    let present: Bool
    let fromWidth: CGFloat
    let toWidth: CGFloat
    let anchor: Anchor
    private let samples: [CGPoint]

    init(p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint, towardBrief: Bool, delay: Double, travel: Double, pop: CGFloat,
         present: Bool, fromWidth: CGFloat, toWidth: CGFloat, anchor: Anchor) {
        self.p0 = p0; self.c1 = c1; self.c2 = c2; self.p1 = p1; self.towardBrief = towardBrief; self.delay = delay
        self.travel = travel; self.pop = pop; self.present = present; self.fromWidth = fromWidth; self.toWidth = toWidth
        self.anchor = anchor
        samples = Self.table(p0, c1, c2, p1).samples
    }

    /// Progress on its own clock, each line a little after the one below; past 1 is the spring's overshoot.
    func progress(_ form: Double) -> Double {
        let q = towardBrief ? 1 - form : form
        return q >= 1 ? q : max(0, (q - delay) / max(0.001, 1 - delay))
    }
    func u(_ form: Double) -> CGFloat {
        let qi = progress(form)
        return CGFloat(towardBrief ? qi : 1 - qi)
    }

    func point(_ u: CGFloat) -> CGPoint {
        guard u > 0, u < 1, samples.count > 1 else { return Self.cubic(p0, c1, c2, p1, u) }
        let x = u * CGFloat(samples.count - 1), i = Int(x), f = x - CGFloat(i)
        let a = samples[i], b = samples[min(i + 1, samples.count - 1)]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// The cubic sampled at 25 points evenly spaced by distance along it.
    struct Table {
        let samples: [CGPoint]
        let p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint
        func point(_ u: CGFloat) -> CGPoint {
            guard u > 0, u < 1, samples.count > 1 else { return FlightPlan.cubic(p0, c1, c2, p1, u) }
            let x = u * CGFloat(samples.count - 1), i = Int(x), f = x - CGFloat(i)
            let a = samples[i], b = samples[min(i + 1, samples.count - 1)]
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
    }

    nonisolated static func table(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint) -> Table {
        let steps = 48
        var points: [CGPoint] = [], lengths: [CGFloat] = [0]
        for i in 0...steps { points.append(cubic(p0, c1, c2, p1, CGFloat(i) / CGFloat(steps))) }
        for i in 1...steps { lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = lengths[steps]
        guard total > 0.5 else { return Table(samples: [], p0: p0, c1: c1, c2: c2, p1: p1) }
        var out: [CGPoint] = [], j = 1
        for k in 0...24 {
            let goal = CGFloat(k) / 24 * total
            while j < steps && lengths[j] < goal { j += 1 }
            let within = (goal - lengths[j - 1]) / max(0.0001, lengths[j] - lengths[j - 1])
            let a = points[j - 1], b = points[j]
            out.append(CGPoint(x: a.x + (b.x - a.x) * within, y: a.y + (b.y - a.y) * within))
        }
        return Table(samples: out, p0: p0, c1: c1, c2: c2, p1: p1)
    }

    nonisolated static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let s = 1 - t, a = s * s * s, b = 3 * s * s * t, c = 3 * s * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x, y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }
}



/// Auto layout geometry (spec §6.1), in the detail view's top-left coordinates. Pure math, no views.
/// Columns span the content width; the queue sits under them: me under the first column's left end,
/// orbs under the last column's right end, and each bar under its own column.
struct AutoLayout: Equatable {
    struct Metrics: Equatable {
        var inset: CGFloat = 16
        var gap: CGFloat = 12
        var me: CGFloat = 40
        var orb: CGFloat = 40
        var barHeight: CGFloat = 40
        var bottomInset: CGFloat = 14
        var topInset: CGFloat = 52
        var fullMin: CGFloat = 480
        /// The full column keeps at least this share of the content width (and never less than `fullMin`).
        var fullShare: CGFloat = 0.4
        var briefMin: CGFloat = 220
        var briefMax: CGFloat = 420
        /// Capacity counts briefs at this width; once there, they squeeze down to `briefMin` before the last one
        /// becomes an orb (2026-10-24 review r3: one 560 pt divisor per column dropped to two columns too early).
        var briefComfort: CGFloat = 300
        /// A brief column's preferred share of the content width.
        var briefShare: CGFloat = 0.25
        /// The last bar never gets shorter than this to make room for orbs (a brief bar holds a title and a status).
        var lastBarMin: CGFloat = 160
        /// Between orbs, and between the last bar and the first orb: wide enough that two busy orbs'
        /// satellites do not run into each other.
        var orbGap: CGFloat = 30
        /// Between the columns and the dock.
        var dockGap: CGFloat = 12
        /// An orb's diameter right under the pointer, and how many resting orb slots the magnification reaches.
        var orbMagnified: CGFloat = 40
        var magnifyReach: CGFloat = 2.4
        /// While typed in or under the pointer, the whole dock rises this much (its sizes stay).
        var hoverRise: CGFloat = 0
    }

    /// Members shown as columns (the first `columns.count` members); the rest are orbs.
    var columns: [CGRect] = []
    /// One bar per column, aligned with it.
    var bars: [CGRect] = []
    var me: CGRect = .zero
    var orbs: [CGRect] = []
    /// How many of `orbs`, at the front, are parked right of me (briefs New Chat squeezed out, Astra r3 E); the rest
    /// are the ordinary bank at the right end.
    var leading = 0
    var capacity = 1
    /// Which column is full width.
    var fullColumn = 0
    /// New Chat's draft (f047): its column and bar, taken out of `columns` and `bars` (the scene draws them itself).
    var draftColumn: CGRect?, draftBar: CGRect?
    /// Shell v2: this is Focused or Split's arrangement (FocusLayout), where every column is full at its own width.
    var focused = false

    /// Peek (2026-10-24 review r3): the model picker's surface, a blur halo with the content floating on it, right above
    /// the orb. When the column above the orb is a brief, the halo takes that brief's frame. When it is the full column
    /// (briefs on the left, the orb at the right end under the full one), a brief-sized halo is estimated and floats on
    /// the full column over the orb, instead of jumping to a brief across the window. Inside it, bottom up: the
    /// satellites' rows, the conversation's input capsule (the orb opens into it), then its status as lyrics.
    struct Peek: Equatable {
        /// The halo's core: the content sits in it; the blur feathers out past it.
        var blur: CGRect
        var capsule: CGRect
        /// Lyrics and status, above the capsule.
        var lyrics: CGRect
        /// Top of the satellite rows, under the capsule.
        var rowsTop: CGFloat
        /// The brief column whose frame the halo takes, if it took one.
        var column: Int?
    }

    func peek(over orb: CGRect, size: CGSize, satelliteRows rows: Int, satellite d: CGFloat, metrics m: Metrics) -> Peek {
        let above = columns.indices.first { columns[$0].minX - m.gap / 2 <= orb.midX && orb.midX <= columns[$0].maxX + m.gap / 2 }
            ?? columns.indices.last
        let target = above.flatMap { $0 == fullColumn ? nil : $0 }
        let content = max(0, size.width - 2 * m.inset)
        let top = columns.first?.minY ?? m.topInset, bottom = columns.first?.maxY ?? (size.height - m.bottomInset - m.barHeight - m.dockGap)
        let blur: CGRect
        if let target {
            blur = columns[target]
        } else {
            // Over the full column (Astra r3 D): 360 pt wide within the column, its summary up to 560 pt tall and scrolling
            // beyond, centred over the orb and kept inside the column.
            let host = above.map { columns[$0] } ?? CGRect(x: m.inset, y: top, width: content, height: max(0, bottom - top))
            let w = max(min(220, host.width), min(360, host.width - 24))
            let rowsHeight = rows > 0 ? Self.peekRow : 0
            let chrome = 16 + rowsHeight + m.barHeight + 10
            let available = max(0, host.height - chrome - 12)
            let h = min(host.height, min(available, 560, max(280, 0.72 * available)) + chrome)
            let x = min(max(orb.midX - w / 2, host.minX), host.maxX - w)
            blur = CGRect(x: x, y: host.maxY - h, width: w, height: h)
        }
        let pad: CGFloat = 16
        let rowsHeight = rows > 0 ? Self.peekRow : 0
        let capsule = CGRect(x: blur.minX + pad, y: blur.maxY - pad - rowsHeight - m.barHeight,
                             width: max(m.barHeight, blur.width - 2 * pad), height: m.barHeight)
        let lyrics = CGRect(x: blur.minX, y: blur.minY, width: blur.width, height: max(0, capsule.minY - 10 - blur.minY))
        return Peek(blur: blur, capsule: capsule, lyrics: lyrics, rowsTop: capsule.maxY + 4, column: target)
    }

    /// Under a peek's capsule: one 24 pt row of moons and its 4 pt gap, reserved whether it has moons or not, so the
    /// capsule never moves with them (Astra r5 R4).
    static let peekRow: CGFloat = 28

    /// Columns that fit: the full column at its floor, then as many briefs at their comfortable width as the rest takes.
    /// The dock under the pointer (the macOS Dock's magnification). Each orb grows toward `orbMagnified` with a cosine
    /// falloff over `magnifyReach` resting slots from the pointer (`amount` fades the whole effect in and out). The orbs
    /// re-pack around the one nearest the pointer but stay inside their own stretch of the dock (plus half the gap
    /// before them): the growth comes out of the gaps between them, so the bars never move. Driven by the resting
    /// centres, so the pointer never chases what it moves.
    func magnified(pointerX x: CGFloat?, amount: CGFloat, metrics m: Metrics) -> AutoLayout {
        guard let x, amount > 0.001, !orbs.isEmpty, m.orbMagnified > m.orb else { return self }
        // Each bank in its own stretch: the parked ones right of me grow inside their reserved slots.
        var out = self
        out.orbs = Self.magnify(Array(orbs.prefix(leading)), pointerX: x, amount: amount, metrics: m, slotted: true)
            + Self.magnify(Array(orbs.dropFirst(leading)), pointerX: x, amount: amount, metrics: m, slotted: false)
        return out
    }

    /// One bank of orbs magnified (see `magnified`). A slotted bank (the parked one) has 48 + 10 pt per orb reserved, so
    /// each grows in its own slot.
    private static func magnify(_ orbs: [CGRect], pointerX x: CGFloat, amount: CGFloat, metrics m: Metrics, slotted: Bool) -> [CGRect] {
        guard !orbs.isEmpty else { return [] }
        let n = orbs.count
        let slot = m.orb + m.orbGap, reach = max(1, m.magnifyReach) * slot
        let sizes = orbs.map { orb -> CGFloat in
            let d = abs(x - orb.midX) / reach
            let f = d < 1 ? (cos(d * .pi) + 1) / 2 : 0
            return m.orb + (m.orbMagnified - m.orb) * f * amount
        }
        let lo = orbs[0].minX - m.orbGap / 2, hi = orbs[n - 1].maxX
        let total = sizes.reduce(0, +)
        var mids = Array(repeating: CGFloat(0), count: n)
        if total + CGFloat(n - 1) * m.orbGap <= hi - lo {
            let k = orbs.indices.min { abs(orbs[$0].midX - x) < abs(orbs[$1].midX - x) } ?? 0
            mids[k] = orbs[k].midX
            for i in stride(from: k + 1, to: n, by: 1) { mids[i] = mids[i - 1] + sizes[i - 1] / 2 + m.orbGap + sizes[i] / 2 }
            for i in stride(from: k - 1, through: 0, by: -1) { mids[i] = mids[i + 1] - sizes[i + 1] / 2 - m.orbGap - sizes[i] / 2 }
            let right = mids[n - 1] + sizes[n - 1] / 2, left = mids[0] - sizes[0] / 2
            let shift = right > hi ? hi - right : (left < lo ? lo - left : 0)
            mids = mids.map { $0 + shift }
        } else if slotted {
            mids = orbs.map(\.midX)
        } else {
            // Not enough room at the usual gap: the gaps close up evenly, never below 4 pt.
            let gap = n > 1 ? max(4, (hi - lo - total) / CGFloat(n - 1)) : 0
            var cursor = hi
            for i in stride(from: n - 1, through: 0, by: -1) { mids[i] = cursor - sizes[i] / 2; cursor -= sizes[i] + gap }
        }
        if slotted { mids = orbs.map(\.midX) }
        return orbs.indices.map { i in
            // Growing up from where it rests, as Dock icons do, never down toward the window's edge.
            CGRect(x: mids[i] - sizes[i] / 2, y: orbs[i].maxY - sizes[i], width: sizes[i], height: sizes[i])
        }
    }

    /// Width a parked orb reserves right of me: room to magnify to 48 pt, and 10 pt to the next.
    static let parkedSlot: CGFloat = 58

    /// Where the dock is when it has risen, `q` from 0 to 1 (2026-10-25): every bar, orb and me `hoverRise` higher, sizes
    /// unchanged; the columns keep their place, the dock rises over them (full bleed). The views rise by an offset
    /// (`DockHover.rise`); this is for what has to know where they are, hit targets most of all.
    func raised(_ q: CGFloat, metrics m: Metrics) -> AutoLayout {
        let rise = m.hoverRise * q
        guard rise > 0.01 else { return self }
        var out = self
        out.bars = bars.map { $0.offsetBy(dx: 0, dy: -rise) }
        out.orbs = orbs.map { $0.offsetBy(dx: 0, dy: -rise) }
        out.me = me.offsetBy(dx: 0, dy: -rise)
        return out
    }

    /// One bar of the risen dock (New Chat's draft bar, outside the layout).
    static func raised(_ bar: CGRect, _ q: CGFloat, metrics m: Metrics) -> CGRect { bar.offsetBy(dx: 0, dy: -m.hoverRise * q) }

    static func capacity(width: CGFloat, metrics m: Metrics) -> Int {
        let content = width - 2 * m.inset
        return max(1, 1 + Int(((content - m.fullFloor(content) + m.gap) / (m.briefComfort + m.gap)).rounded(.down)))
    }

    init() {}

    /// `fullIndex` is the column shown full; the others are brief.
    /// `leading` orbs are parked right of me, before the bars; the columns start after their rail and keep their bars
    /// aligned. They come first in `orbs`.
    init(size: CGSize, count: Int, fullIndex: Int?, leading parked: Int = 0, metrics m: Metrics) {
        let rail = CGFloat(parked) * Self.parkedSlot
        capacity = Self.capacity(width: size.width - rail, metrics: m)
        let content = max(0, size.width - 2 * m.inset - rail)
        let rowY = size.height - m.bottomInset - m.barHeight / 2
        me = CGRect(x: m.inset, y: rowY - m.me / 2, width: m.me, height: m.me)
        leading = parked
        for k in 0..<parked {
            let midX = me.maxX + m.gap + 24 + CGFloat(k) * Self.parkedSlot
            orbs.append(CGRect(x: midX - m.orb / 2, y: rowY - m.orb / 2, width: m.orb, height: m.orb))
        }

        // No conversations (the last archived, or New Chat's draft before its slot is added): me and the parked rail
        // only, no columns (Astra r6 #1: an empty working set indexed an empty layout).
        guard count > 0 else { return }
        // Orbs sit under the last column's right end. When they would leave its bar too short, that
        // column widens and the full column gives the room (the only case where orbs move columns).
        var (n, brief) = Self.fit(width: content, count: min(capacity, count), metrics: m)
        var widths: [CGFloat] = []
        while true {
            let fullAt = fullIndex.map { $0 < n ? $0 : 0 } ?? 0
            fullColumn = fullAt
            widths = (0..<n).map { $0 == fullAt ? 0 : brief }
            let orbCount = count - n
            if orbCount > 0 && fullAt != n - 1 {
                widths[n - 1] = max(brief, Self.orbsWidth(orbCount, m) + m.orbGap + m.lastBarMin)
            }
            widths[fullAt] = content - widths.reduce(0, +) - CGFloat(n - 1) * m.gap
            if widths[fullAt] >= m.fullFloor(content) || n == 1 { break }
            n -= 1
        }
        let top = m.topInset, bottom = rowY - m.barHeight / 2 - m.dockGap
        var x = m.inset + rail
        for w in widths {
            columns.append(CGRect(x: x, y: top, width: w, height: max(0, bottom - top)))
            x += w + m.gap
        }

        let orbCount = count - n
        let orbsWidth = Self.orbsWidth(orbCount, m)
        var ox = size.width - m.inset - orbsWidth
        for _ in 0..<orbCount {
            orbs.append(CGRect(x: ox, y: rowY - m.orb / 2, width: m.orb, height: m.orb))
            ox += m.orb + m.orbGap
        }
        for (i, column) in columns.enumerated() {
            var left = column.minX, right = column.maxX
            if i == 0 { left = me.maxX + m.gap + rail }
            if i == n - 1 && orbCount > 0 { right = min(right, size.width - m.inset - orbsWidth - m.orbGap) }
            bars.append(CGRect(x: left, y: rowY - m.barHeight / 2, width: max(m.barHeight, right - left), height: m.barHeight))
        }
        // A full last column whose input me and the orbs would leave too short to type in (a narrow window, New Chat's
        // draft with many others, parked orbs; Astra r3 E, r6 R3: four parked at 560 pt left it 248 pt): me, the parked
        // orbs and the others go in a rail just above it, and it takes the window's width. The window is laid out
        // without the parked rail first.
        if fullColumn == n - 1, orbCount > 0 || parked > 0, let bar = bars.last, bar.width < Self.fullBarMin {
            var alt = parked > 0 ? AutoLayout(size: size, count: count, fullIndex: fullIndex, leading: 0, metrics: m) : self
            // Without the parked rail there may be room for another column: the bank is what is left (Astra r7 #11).
            alt.liftIntoRail(parked: parked, bank: count - alt.columns.count, size: size, metrics: m)
            self = alt
        }
    }

    /// me and every orb in one row above the input, left to right (parked ones first), packed closer when they do not
    /// fit the window; the bars lose me's room at the left and the orbs' at the right.
    private mutating func liftIntoRail(parked: Int, bank: Int, size: CGSize, metrics m: Metrics) {
        let rowY = size.height - m.bottomInset - m.barHeight / 2
        let y = rowY - m.barHeight / 2 - m.orbGap / 2 - m.orb / 2
        let count = parked + bank
        let step = count == 0 ? 0 : min(m.orb + m.orbGap, (size.width - 2 * m.inset - m.me) / CGFloat(count))
        me = CGRect(x: m.inset, y: y - m.me / 2, width: m.me, height: m.me)
        orbs = (0..<count).map { k in
            CGRect(x: me.maxX + step * CGFloat(k + 1) - m.orb, y: y - m.orb / 2, width: m.orb, height: m.orb)
        }
        leading = parked
        bars = bars.indices.map { i in
            let left = i == 0 ? m.inset : columns[i].minX
            let right = i == bars.count - 1 ? size.width - m.inset : columns[i].maxX
            return CGRect(x: left, y: bars[i].minY, width: max(m.barHeight, right - left), height: bars[i].height)
        }
    }

    /// The narrowest a full column's input gets beside the orbs before they move up out of its way.
    static let fullBarMin: CGFloat = 280

    /// How many columns fit in `width`, and the brief width. Narrow windows squeeze briefs first,
    /// then turn a column into an orb.
    private static func fit(width: CGFloat, count: Int, metrics m: Metrics) -> (columns: Int, brief: CGFloat) {
        var n = max(1, count)
        var brief = min(m.briefMax, max(m.briefMin, width * m.briefShare))
        let floor = m.fullFloor(width)
        while n > 1 {
            if width - CGFloat(n - 1) * (brief + m.gap) >= floor { break }
            let squeezed = (width - floor) / CGFloat(n - 1) - m.gap
            if squeezed >= m.briefMin { brief = squeezed; break }
            n -= 1
        }
        return (min(n, count), brief)
    }

    private static func orbsWidth(_ count: Int, _ m: Metrics) -> CGFloat {
        count > 0 ? CGFloat(count) * m.orb + CGFloat(count - 1) * m.orbGap : 0
    }
}

extension AutoLayout.Metrics {
    /// The live metrics for a window of `size` (spec drawings, 2026-10-24 review). In every Organic drawing
    /// the window is 850 × 560 with a 40-unit dock, 30 below it and ~18 above it: the dock is 7.1 % of the
    /// window's height, its bottom margin 5.4 %, its top gap 3.3 %. me, bars and orbs share the dock height.
    /// Clamped so very small or very large windows stay usable.
    @MainActor static func tuned(for size: CGSize) -> Self {
        let t = Tuning.shared
        var m = Self()
        let h = (size.height * t[.dockHeightRatio]).clamped(t[.dockMinHeight], t[.dockMaxHeight]).rounded()
        m.barHeight = h
        m.me = (h * t[.dockMe]).rounded()
        m.hoverRise = t[.dockHoverRise]
        // Orbs rest small and magnify toward the pointer (the macOS Dock); the layout counts them at rest.
        m.orb = (h * t[.dockOrbRest]).rounded()
        m.orbMagnified = (h * t[.dockMagnify]).rounded()
        m.magnifyReach = t[.dockMagnifyReach]
        // 2 % since the 2026-10-24 review (the drawings' 5.4 % read as too tall).
        m.bottomInset = t[.dockBottom]
        m.gap = max(10, (h * 0.24).rounded())
        m.inset = (size.width * 0.0235).clamped(16, 36).rounded()
        m.orbGap = (m.orb * t[.dockOrbGap]).rounded()
        m.fullMin = t[.autoFullMin]; m.fullShare = t[.autoFullShare]
        m.briefMin = t[.autoBriefMin]; m.briefMax = t[.autoBriefMax]; m.briefShare = t[.autoBriefShare]
        m.briefComfort = t[.autoBriefComfort]; m.lastBarMin = t[.autoLastBarMin]
        // Columns end one dock-gap above the dock (3.3 % of the height); the layout adds `gap` itself.
        m.dockGap = (size.height * t[.dockGapRatio]).clamped(14, 36).rounded()
        return m
    }
}

extension AutoLayout.Metrics {
    /// The narrowest the full column gets for a content width.
    func fullFloor(_ content: CGFloat) -> CGFloat { Swift.max(fullMin, content * fullShare) }
}

extension CGFloat {
    func clamped(_ low: Double, _ high: Double) -> CGFloat { Swift.min(CGFloat(high), Swift.max(CGFloat(low), self)) }
}

enum NativeMorphWordFlow {
    static func arrange(width: CGFloat, sizes: [CGSize], spaceBefore: [Bool], space: CGFloat)
        -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        precondition(sizes.count == spaceBefore.count)
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for i in sizes.indices {
            let size = sizes[i], spaced = spaceBefore[i]
            var gap = spaced && x > 0 ? space : 0
            if spaced, x > 0, x + gap + size.width > width + 0.5 { y += line; x = 0; line = 0; gap = 0 }
            points.append(CGPoint(x: x + gap, y: y))
            x += gap + size.width; line = max(line, size.height); widest = max(widest, x)
        }
        return (points, widest, y + line)
    }
}
