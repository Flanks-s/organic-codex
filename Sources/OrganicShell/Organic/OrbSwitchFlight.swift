import AppKit
import QuartzCore

/// New OrbSwitch02 motion only; no existing layout, Dock or hover spring is retuned.
@MainActor final class OrbSwitchFlight {
    @MainActor final class Flight {
        let conversation: Conversation, orb: OrbComponent
        var start: CGRect, control1 = CGPoint.zero, control2Offset = CGPoint.zero
        var began: Double, delay: Double, last: Double
        var x: Double, y: Double, diameter: Double
        var vx = 0.0, vy = 0.0, vd = 0.0
        var collapsing = false
        var fixed: CGRect?
        init(_ c: Conversation, rect: CGRect, at time: Double, delay: Double) {
            conversation = c; start = rect; began = time; last = time; self.delay = delay
            x = rect.midX; y = rect.midY; diameter = rect.width
            orb = OrbComponent(id: "orb-switch.\(c.id)")
        }
        var rect: CGRect { CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter) }
    }
    private weak var scene: AutoScene?
    let view = AutoScene.PassThrough()
    private(set) var flights: [String: Flight] = [:]
    static let duration = 0.580, outgoingDelay = 0.035
    init(scene: AutoScene) { self.scene = scene; view.wantsLayer = true }
    func pose(_ id: String) -> CGRect? { flights[id]?.rect }
    func hit(at point: CGPoint) -> String? {
        let candidates = flights.values.filter { !$0.collapsing && $0.rect.insetBy(dx:-6,dy:-6).contains(point) }
        return candidates.max { a,b in
            let za = a.orb.glassView.layer?.zPosition ?? 0, zb = b.orb.glassView.layer?.zPosition ?? 0
            if za != zb { return za < zb }
            return (view.subviews.firstIndex(of:a.orb.glassView) ?? 0) < (view.subviews.firstIndex(of:b.orb.glassView) ?? 0)
        }?.conversation.id
    }
    func start(_ c: Conversation, from rect: CGRect, to target: CGRect, incoming: Bool, collapse: Bool = false, fixed: Bool = false) {
        guard let scene else { return }
        let time = scene.now()
        let f = flights[c.id] ?? Flight(c, rect: rect, at: time, delay: incoming ? 0 : Self.outgoingDelay)
        let wasCollapsing = f.collapsing
        f.start = f.rect; f.began = time; f.last = time; f.delay = incoming ? 0 : Self.outgoingDelay; f.collapsing = collapse
        f.fixed = fixed ? target:nil
        for ink in [f.orb.frontView,f.orb.backView,f.orb.glassView.contentView].compactMap({$0}) {
            ink.alphaValue = 1
            if collapse { OrbSwitchSurfaceMotion.blur(ink,radius:10,showing:false,duration:0.14) }
            else if wasCollapsing { OrbSwitchSurfaceMotion.blur(ink,radius:10,showing:true,duration:0.14) }
        }
        let dx = target.midX - f.x, dy = target.midY - f.y, length = hypot(dx, dy)
        if length >= 24 {
            var nx = -dy / length, ny = dx / length
            if ny > 0 { nx = -nx; ny = -ny }
            func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(scene.sizeForOrb.width - 24, max(24,p.x)), y: min(scene.sizeForOrb.height - 20,max(40,p.y))) }
            f.control1 = clamp(CGPoint(x: f.x + dx * 0.10 + nx * length * 0.26, y: f.y + dy * 0.10 + ny * length * 0.26))
            let p2 = clamp(CGPoint(x: f.x + dx * 0.58 + nx * length * 0.14, y: f.y + dy * 0.58 + ny * length * 0.14))
            f.control2Offset = CGPoint(x: p2.x - target.midX, y: p2.y - target.midY)
        } else { f.control1 = CGPoint(x: f.x,y: f.y); f.control2Offset = .zero }
        flights[c.id] = f
        if view.superview == nil { view.frame = scene.overlayPlane.bounds; scene.overlayPlane.addSubview(view) }
        var config = OrbConfiguration(content: .identity(orbIdentity(of: c)), drawingSize: 56)
        config.ambient = false
        f.orb.configure(config); f.orb.setCanvasSize(view.bounds.size)
        for plane in [f.orb.backView, f.orb.glassView, f.orb.frontView] {
            if plane.superview == nil { view.addSubview(plane) }
            plane.layer?.zPosition = collapse || fixed || length < 24 ? 10:(incoming ? 12:11)
        }
        scene.runClock(until: time + 1.6)
        frame(time)
    }
    func frame(_ time: Double) {
        guard let scene else { return }
        for (id, f) in flights {
            let target = f.collapsing ? f.start.offsetBy(dx: 0,dy: -18) : (f.fixed ?? scene.orbEndpoint(id))
            guard let target else { retire(id); continue }
            let dt = max(0, time - f.last), elapsed = time - f.began
            let q = min(1,max(0,(elapsed - f.delay) / Self.duration))
            if q >= 1 { for plane in [f.orb.backView,f.orb.glassView,f.orb.frontView] { plane.layer?.zPosition = 10 } }
            let u = OverlayCurve(0.32,0,0.2,1,Self.duration).value(at: q), n = 1-u
            let p0 = CGPoint(x:f.start.midX,y:f.start.midY), p2 = CGPoint(x:target.midX + f.control2Offset.x,y:target.midY + f.control2Offset.y)
            let gx = f.collapsing ? target.midX : n*n*n*p0.x + 3*n*n*u*f.control1.x + 3*n*u*u*p2.x + u*u*u*target.midX
            let gy = f.collapsing ? target.midY : n*n*n*p0.y + 3*n*n*u*f.control1.y + 3*n*u*u*p2.y + u*u*u*target.midY
            let gd = f.collapsing ? 0 : f.start.width + (target.width-f.start.width)*u*u*(3-2*u)
            let position = f.collapsing ? (0.26,1.0) : (0.09,0.9), size = f.collapsing ? (0.26,1.0) : (0.16,0.9)
            (f.x,f.vx) = Spring(from:f.x,to:gx,velocity:f.vx,response:position.0,damping:position.1,epsilon:0.001).sample(dt)
            (f.y,f.vy) = Spring(from:f.y,to:gy,velocity:f.vy,response:position.0,damping:position.1,epsilon:0.001).sample(dt)
            (f.diameter,f.vd) = Spring(from:f.diameter,to:gd,velocity:f.vd,response:size.0,damping:size.1,epsilon:0.001).sample(dt)
            f.last = time
            let r = f.rect
            f.orb.glassView.frame = r; f.orb.glassView.cornerRadius = max(0,r.width/2)
            f.orb.glassView.contentView?.frame = f.orb.glassView.bounds; f.orb.setFrame(r)
            if f.collapsing {
                let glyph = Spring(from:1,to:0,response:0.14,damping:1,epsilon:0.001).sample(elapsed).value
                for ink in [f.orb.frontView,f.orb.backView,f.orb.glassView.contentView].compactMap({$0}) { ink.alphaValue = max(0,glyph) }
            }
            hideOriginal(id, true)
            if f.collapsing ? f.diameter < 0.5 : (q >= 1 && hypot(f.x-target.midX,f.y-target.midY)<0.004 && abs(f.diameter-target.width)<0.004 && max(abs(f.vx),abs(f.vy),abs(f.vd))<0.04) { retire(id) }
        }
        if flights.isEmpty { view.removeFromSuperview() }
    }
    private func hideOriginal(_ id: String, _ hidden: Bool) {
        guard let scene else { return }
        scene.nodes[id]?.island?.setOrbCarried(hidden)
        if scene.peekNode.header.configuration?.id == id { scene.peekNode.header.setOrbCarried(hidden) }
        if !hidden || scene.dock.items[id]?.role == .orb { scene.dock.setHidden(id, hidden) }
    }
    private func retire(_ id: String) {
        guard let f = flights.removeValue(forKey: id) else { return }
        hideOriginal(id, false); f.orb.dispose()
        for plane in [f.orb.backView,f.orb.glassView,f.orb.frontView] { plane.removeFromSuperview() }
    }
    func cancel() { for id in Array(flights.keys) { retire(id) }; view.removeFromSuperview() }
}
