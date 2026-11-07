import AppKit
import QuartzCore

/// The Debug Labs' scene host (Debug/LabContracts.swift; f011, f012): one real column of a conversation, offscreen,
/// moved by the scene's own driver B — ColumnNode's tracks and its flights' — and drawn by CARenderer at the Lab's time.
/// The Lab's springs and flight style apply to this stage only; no window's scene is touched. The island and the glass
/// are AppKit views and do not draw offscreen: the column wears its drawn header, as in the self-test.
/// One stage per Lab, so the two never move each other's column.
@MainActor final class LabStage: TransitionLabHost, SpringLabHost {
    private let store: ConversationStore
    private let host = CALayer()
    /// The native transcript's superview: a column lays it out and captures it without a window.
    private let plane = NSView()
    private let profile = DisplayProfile.of(NSScreen.main ?? NSScreen.screens[0])
    private var column: ColumnNode?
    private var flights: [FlightNode] = []
    private var renderer: OffscreenRenderer?
    private var rendered: (size: CGSize, scale: CGFloat)?
    private struct Key: Equatable { let id: String; let full, brief, height, x, scale: CGFloat }
    private var key: Key?
    /// The media time every installed track begins at; renders ask for times after it.
    private let origin = 1000.0

    init(store: ConversationStore) {
        self.store = store
        host.backgroundColor = Look.canvas.cgColor
    }

    // MARK: Transition Lab

    func transitionLabDetach() { teardown() }

    func transitionLabRender(_ request: TransitionLabRequest, size: CGSize, scale: CGFloat) -> TransitionLabFrame {
        var p = request.parameters; p.normalize()
        let full = CGFloat(p.fullWidth), brief = CGFloat(p.briefWidth), height = min(CGFloat(p.height), size.height).rounded()
        let x = max(0, ((size.width - full) / 2).rounded())
        let r = renderer(size, scale)
        guard let n = column(request.conversationID, full: full, brief: brief, height: height, x: x, scale: scale) else {
            return TransitionLabFrame(image: nil, provenance: "No conversation to show")
        }
        let start = request.towardBrief ? 1.0 : 0.0, target = 1 - start
        let spring = Spring(from: start, to: target, response: p.response, damping: p.damping, epsilon: Spring.restEpsilon / max(1, Double(full - brief)))
        let style = MorphFlightStyle(burst: CGFloat(p.burst), swirl: p.swirl, pop: CGFloat(p.pop), stagger: p.stagger)
        install(n, form: { spring.sample($0).value }, duration: spring.duration, towardBrief: request.towardBrief, style: style,
                full: full, brief: brief, height: height, x: x)
        // The first time the spring reaches the asked form (it may overshoot past it later).
        let want = min(1, max(0, request.form))
        var t = spring.duration, τ = 0.0
        while τ < spring.duration {
            let v = spring.sample(τ).value
            if request.towardBrief ? v <= want : v >= want { t = τ; break }
            τ += 0.0005
        }
        let image = r.image(r.render(at: origin + t))

        func header(_ c: CGRect) -> CGRect { CGRect(x: x + c.minX - c.width / 2, y: c.minY, width: c.width, height: c.height) }
        let hf = n.header(width: full, form: 1), hb = n.header(width: brief, form: 0)
        var anchors = [LabAnchor(name: "Column", full: CGRect(x: x, y: 0, width: full, height: height), brief: CGRect(x: x, y: 0, width: brief, height: height)),
                       LabAnchor(name: "Planet", full: header(hf.planet), brief: header(hb.planet)),
                       LabAnchor(name: "Name", full: header(hf.capsule), brief: header(hb.capsule))]
        anchors += n.pieces.enumerated().map { k, piece in
            LabAnchor(name: "\(piece.look) \(k + 1)", full: piece.source.offsetBy(dx: x, dy: 0), brief: piece.destination.offsetBy(dx: x, dy: 0))
        }
        // Each flight's anchor point (trailing for a goal, leading for a narration, else its centre) along its plan.
        let paths = flights.enumerated().map { k, node in
            LabPath(name: "\(node.line.look) \(k + 1)", points: (0...40).map { i in
                let f = start + (target - start) * Double(i) / 40
                return node.screenPose(rect: CGRect(x: x, y: 0, width: brief + (full - brief) * CGFloat(f), height: height), form: f).origin
            })
        }
        return TransitionLabFrame(image: image, anchors: anchors, paths: paths,
                                  provenance: "Production driver B · column and flight tracks at the Lab's spring · CARenderer (drawn header; no island or glass)")
    }

    // MARK: Spring Lab

    /// What the real column is doing: a curve from where it was to the request's target, on the Lab's clock.
    private struct Motion {
        var request: SpringLabRequest
        var from: Double
        var value: (Double) -> Double
        var duration: Double
        var wallStart: Double
        var frozen: Double?
        var installed: Key?
        func elapsed(_ now: Double) -> Double { frozen ?? (now - wallStart) / request.slow }
    }
    private var motion: Motion?

    func springLabPlay(_ request: SpringLabRequest) {
        var r = request; r.normalize()
        start(r, from: r.from, velocity: r.initialVelocity)
    }

    /// From where the column is now, at its speed there, to the request's target.
    func springLabInterrupt(_ request: SpringLabRequest) {
        var r = request; r.normalize()
        guard let m = motion else { start(r, from: r.from, velocity: r.initialVelocity); return }
        let t = m.elapsed(CACurrentMediaTime()), dt = 0.001
        let v = m.value(min(t, m.duration)), velocity = t < m.duration ? (m.value(t + dt) - m.value(t)) / dt : 0
        start(r, from: v, velocity: velocity)
    }

    func springLabStop() {
        guard var m = motion else { return }
        if m.frozen == nil { m.frozen = min(m.elapsed(CACurrentMediaTime()), m.duration) }
        motion = m
    }

    func springLabDetach() { motion = nil; teardown() }

    func springLabFrame(size: CGSize, scale: CGFloat) -> CGImage? {
        let r = motion?.request ?? SpringLabRequest()
        let brief: CGFloat = 250, full = brief + CGFloat(r.distance), height = size.height.rounded()
        let x = max(0, ((size.width - full) / 2).rounded())
        let renderer = renderer(size, scale)
        guard let n = column(r.conversationID, full: full, brief: brief, height: height, x: x, scale: scale) else { return nil }
        guard var m = motion else {
            install(n, form: { _ in r.from }, duration: 0, towardBrief: false, style: .tuned, full: full, brief: brief, height: height, x: x)
            return renderer.image(renderer.render(at: origin))
        }
        if m.installed != key {
            install(n, form: m.value, duration: m.duration, towardBrief: m.request.target < m.from, style: .tuned, full: full, brief: brief, height: height, x: x)
            m.installed = key; motion = m
        }
        return renderer.image(renderer.render(at: origin + min(m.elapsed(CACurrentMediaTime()), m.duration + 0.05)))
    }

    /// Every variant, `runs` times each, on this stage: the main thread's cost of compiling the column's driver B, and
    /// CARenderer's cost per frame at the display's rate. Medians per variant. Not a display or commit measurement.
    func springLabMeasure(_ request: SpringLabRequest) async throws -> [SpringLabMeasurement] {
        var r = request; r.normalize()
        // A request already at its target (after an interrupt, say) measures the whole move to it from the other end.
        if abs(r.target - r.from) < 1e-9 { r.from = r.target > 0.5 ? 0 : 1; r.initialVelocity = 0 }
        let scale = NSScreen.main?.backingScaleFactor ?? 2, hz = (1 / profile.frameInterval).rounded()
        let brief: CGFloat = 250, full = brief + CGFloat(r.distance), size = CGSize(width: full + 80, height: 640)
        let renderer = renderer(size, scale)
        guard let n = column(r.conversationID, full: full, brief: brief, height: size.height, x: 40, scale: scale) else {
            throw LabExportError.hostUnavailable
        }
        var out: [SpringLabMeasurement] = []
        for variant in LabSpringVariant.allCases {
            var q = r; q.variant = variant
            let c = curve(q, from: q.from, velocity: q.initialVelocity, scale: scale)
            var runs: [SpringLabMeasurement] = []
            for _ in 0..<q.runs {
                try Task.checkCancellation()
                let t0 = CACurrentMediaTime()
                install(n, form: c.value, duration: c.duration, towardBrief: q.target < q.from, style: .tuned, full: full, brief: brief, height: size.height, x: 40)
                CATransaction.flush()
                let compile = (CACurrentMediaTime() - t0) * 1000
                let frames = max(1, Int((c.duration * hz).rounded(.up)))
                // Visible motion ends once the column stays within half a pixel of its target.
                let half = 0.5 / Double(scale) / max(1, q.distance)
                var visibleEnd = 0.0
                for i in 0...frames where abs(c.value(Double(i) / hz) - q.target) >= half { visibleEnd = Double(i + 1) / hz }
                visibleEnd = min(visibleEnd, c.duration)
                var busy = compile, tail = 0.0
                for i in 1...frames {
                    let s = CACurrentMediaTime()
                    _ = renderer.render(at: origin + Double(i) / hz)
                    let ms = (CACurrentMediaTime() - s) * 1000
                    busy += ms
                    if Double(i) / hz > visibleEnd { tail += ms }
                }
                runs.append(SpringLabMeasurement(variant: variant, frames: frames, tailFrames: max(0, frames - Int((visibleEnd * hz).rounded(.up))),
                                                 duration: c.duration, visibleEnd: visibleEnd, busyMilliseconds: busy, tailBusyMilliseconds: tail,
                                                 provenance: "Host offscreen column · driver B compile + CARenderer per frame at \(Int(hz)) Hz (not display or commit)",
                                                 subject: "Real column"))
                await Task.yield()
            }
            func median<T: Comparable>(_ v: [T]) -> T { v.sorted()[v.count / 2] }
            var m = runs[0]
            m.frames = median(runs.map(\.frames)); m.tailFrames = median(runs.map(\.tailFrames))
            m.duration = median(runs.map(\.duration)); m.visibleEnd = median(runs.map(\.visibleEnd))
            m.busyMilliseconds = median(runs.map(\.busyMilliseconds)); m.tailBusyMilliseconds = median(runs.map(\.tailBusyMilliseconds))
            out.append(m)
        }
        if var m = motion { m.installed = nil; motion = m }
        return out
    }

    private func start(_ r: SpringLabRequest, from: Double, velocity: Double) {
        let c = curve(r, from: from, velocity: velocity, scale: rendered?.scale ?? 2)
        motion = Motion(request: r, from: from, value: c.value, duration: c.duration, wallStart: CACurrentMediaTime(), frozen: nil, installed: nil)
    }

    /// The variant's form over time, from `from` (at `velocity`, form per second) to the request's target: the system
    /// spring's whole tail, the same cut where it stays within half a pixel (TruncatedSpring), or the fitted Bézier.
    private func curve(_ r: SpringLabRequest, from: Double, velocity: Double, scale: CGFloat) -> (value: (Double) -> Double, duration: Double) {
        let span = r.target - from, lab = LabSpring(response: r.response, damping: r.damping)
        guard abs(span) > 1e-9 else { return ({ _ in r.target }, 0) }
        let v0 = velocity / span, distance = r.distance * abs(span)
        switch r.variant {
        case .system:
            let d = lab.settlingTime
            return ({ t in t >= d ? r.target : from + span * lab.value(t, velocity: v0) }, d)
        case .truncated:
            // TruncatedSpring on the actual motion: the last time it is half a pixel (or 0.002) from rest or moves that
            // much per response, with its initial velocity (organic audit B20).
            let threshold = min(0.002, 0.5 / Double(max(1, scale)) / max(0.001, distance))
            var d = 0.0, t = 0.0
            while t < lab.settlingTime {
                if abs(1 - lab.value(t, velocity: v0)) >= threshold || abs(lab.velocity(t, initial: v0)) * r.response / (2 * .pi) >= threshold { d = t }
                t += 0.001
            }
            d += 0.001
            return ({ t in t >= d ? r.target : from + span * lab.value(t, velocity: v0) }, d)
        case .fitted:
            let c = LabFittedCurve.fit(lab, distance: distance, scale: Double(scale))
            return ({ t in from + span * c.value(t) }, c.duration)
        }
    }

    // MARK: The stage

    /// The renderer for a viewport; a new size or scale makes a new one.
    private func renderer(_ size: CGSize, _ scale: CGFloat) -> OffscreenRenderer {
        if let renderer, let r = rendered, r.size == size, r.scale == scale { return renderer }
        host.removeFromSuperlayer()
        let r = OffscreenRenderer(size: size, host: host, scale: scale)
        renderer = r; rendered = (size, scale)
        return r
    }

    /// The column for a conversation and geometry, made again when either changes.
    private func column(_ id: String, full: CGFloat, brief: CGFloat, height: CGFloat, x: CGFloat, scale: CGFloat) -> ColumnNode? {
        guard let c = store.conversations.first(where: { $0.id == id }) ?? store.conversations.first else { return nil }
        let k = Key(id: c.id, full: full, brief: brief, height: height, x: x, scale: scale)
        if k == key, let column { return column }
        removeColumn()
        let n = ColumnNode(c, store: store, identity: Look.identity[c.identityIndex % Look.identity.count],
                           rect: CGRect(x: x, y: 0, width: full, height: height), full: true, scale: scale, logicalBottom: height - 70)
        n.restOnSnapshot = true
        n.ambient = false
        plane.addSubview(n.native)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.addSublayer(n.card)
        CATransaction.commit()
        column = n; key = k
        return n
    }

    /// Puts the column at the curve's end and starts its driver B and its flights' from `origin`, as a transition
    /// committed by the scene does (AutoScene.prepare / commit), one exposure of smear included.
    private func install(_ n: ColumnNode, form: (Double) -> Double, duration: Double, towardBrief: Bool, style: MorphFlightStyle,
                         full: CGFloat, brief: CGFloat, height: CGFloat, x: CGFloat) {
        let timeline = Timeline(began: 0, duration: duration, rate: Timeline.rate(frameInterval: profile.frameInterval))
        let exposure = ExposureSettings(), back = exposure.shutter * profile.frameInterval
        func rect(_ f: Double) -> CGRect { CGRect(x: x, y: 0, width: brief + (full - brief) * CGFloat(f), height: height) }
        let forms = timeline.map(form), earlier = timeline.map { form(max(0, $0 - back)) }
        let rects = forms.map(rect)
        let end = duration > 0 ? forms.last! : form(0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        n.removeAnimations()
        n.rect = .rest(rect(end)); n.form = .rest(end)
        n.apply(n.snapshot(fullWidth: full, briefWidth: brief))
        n.place(rect(end), form: end)
        n.showRest(full: end > 0.5)
        for f in flights { f.replicator.removeFromSuperlayer() }
        flights = []
        if duration > 0 {
            n.hideGoal()
            let pieces = n.pieces, lyricSize = n.lyricSize
            let centre = MorphFlightMath.centre(pieces.map { towardBrief ? $0.source : $0.destination })
            flights = pieces.enumerated().map { k, piece in
                let look: MorphLook = switch piece.look {
                case .goal: .goal("", lyricSize: lyricSize, current: true)
                case .worked: .worked("")
                case .activity: .activity([], dots: false)
                case .segment: .segment(BriefLine(words: [], lyricSize: lyricSize, current: true))
                }
                let element = MorphElement(id: "lab-\(k)", look: look, target: .fixture, line: piece.lyricLines - 1 - piece.lyricLine)
                let plan = MorphFlightMath.makePlan(element: element, from: piece.source, to: piece.destination, towardBrief: towardBrief,
                                                    style: style, span: full, centre: centre, present: true)
                return FlightNode(line: piece, plan: plan, bounds: host.bounds, scale: n.card.contentsScale)
            }
            var tracks = n.tracks(timeline, rects: rects, forms: forms)
            for f in flights {
                host.addSublayer(f.replicator)
                tracks += f.tracks(timeline, rects: rects, forms: forms, earlierRects: earlier.map(rect), earlierForms: earlier,
                                   lyricSize: lyricSize, profile: profile, exposure: exposure)
            }
            for t in tracks { t.start(at: origin) }
        }
        CATransaction.commit()
    }

    private func removeColumn() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        column?.removeAnimations()
        column?.card.removeFromSuperlayer()
        for f in flights { f.replicator.removeFromSuperlayer() }
        CATransaction.commit()
        column?.native.removeFromSuperview()
        column = nil; flights = []; key = nil
        if var m = motion { m.installed = nil; motion = m }
    }

    private func teardown() {
        removeColumn()
        host.removeFromSuperlayer()
        renderer = nil; rendered = nil
    }
}
