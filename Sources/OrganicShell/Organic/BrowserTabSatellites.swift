import AppKit
import QuartzCore

/// Tabs have their own identifiers and lifecycle; no Conversation satellite is created.
@MainActor final class BrowserTabSatellites {
    struct Moon {
        var radius = BrowserIslandSpring(0), opacity = BrowserIslandSpring(0), angle = BrowserIslandSpring(0)
        var targetAngle = 0.0, outgoingUntil = 0.0, on = false
    }
    private(set) var moons: [String: Moon] = [:]
    private(set) var phase = 0.5
    private var lastTime = 0.0
    private var order: [String] = []
    private var pairs: [String: (CALayer, CALayer)] = [:]
    private var visible = false
    private var paused = false
    private var earthFrame = CGRect.zero
    let back = CALayer(), front = CALayer()
    var repeatAnimationCount: Int {
        pairs.values.reduce(0) { n, pair in n + [pair.0, pair.1].filter { $0.animation(forKey: "browser.tab.orbit") != nil }.count }
    }
    var busy: Bool { moons.values.contains { $0.radius.busy || $0.opacity.busy || $0.angle.busy || $0.outgoingUntil > lastTime } }
    func configure(_ state: BrowserSessionState, at time: Double, reset: Bool = false) {
        let ids = state.tabIDs, list = ids.filter { $0 != state.selectedTabID }
        if reset {
            for id in Array(moons.keys) where !ids.contains(id) {
                if let pair = pairs.removeValue(forKey: id) { removeOrbit(pair); pair.0.removeFromSuperlayer(); pair.1.removeFromSuperlayer() }; moons[id] = nil
            }
        }
        for id in moons.keys.filter({ !ids.contains($0) }) {
            if var moon = moons[id], moon.on { moon.on = false; moon.targetAngle = -Double.pi / 2 - phase; moon.outgoingUntil = time + 0.32; moons[id] = moon }
        }
        for id in ids {
            var moon = moons[id] ?? Moon(); let was = moon.on
            moon.on = id != state.selectedTabID
            if let index = list.firstIndex(of: id) {
                var target = 2 * Double.pi * Double(index) / Double(max(1, list.count)) + 0.35
                if !was && !reset { moon.angle.snap(-Double.pi / 2 - phase); moon.radius.snap(0.3); moon.opacity.snap(0) }
                target += (round((moon.angle.value - target) / (2 * .pi))) * 2 * .pi; moon.targetAngle = target; moon.outgoingUntil = 0
                if reset { moon.angle.snap(target); moon.radius.snap(1); moon.opacity.snap(1) }
            } else if was && !reset {
                var target = -Double.pi / 2 - phase; target += round((moon.angle.value - target) / (2 * .pi)) * 2 * .pi
                moon.targetAngle = target; moon.outgoingUntil = time + 0.32
            } else if reset { moon.radius.snap(0); moon.opacity.snap(0) }
            moons[id] = moon
            if pairs[id] == nil { let a = CALayer(), b = CALayer(); a.name = "browser.tab.back.\(id)"; b.name = "browser.tab.front.\(id)"; back.addSublayer(a); front.addSublayer(b); pairs[id] = (a, b) }
        }
        order = ids; if reset { phase = 0.5; lastTime = time }
    }
    func sample(at time: Double, paused: Bool, reduced: Bool) {
        let dt = max(0, time - lastTime); lastTime = time
        let sampledPresentation = visible && repeatAnimationCount > 0 && synchronizePresentationPhase()
        self.paused = paused || reduced
        if !self.paused && !sampledPresentation { phase += dt * 2 * .pi / 18 }
        if reduced { phase = 0.5 }
        for id in Array(moons.keys) {
            guard var moon = moons[id] else { continue }
            moon.angle.target = moon.targetAngle
            if moon.on { moon.radius.target = 1; moon.opacity.target = 1 }
            else if time >= moon.outgoingUntil || reduced { moon.radius.target = 0; moon.opacity.target = 0 }
            moon.angle.step(dt, response: moon.on ? 0.55 : 0.32, damping: moon.on ? 0.88 : 0.90, reduced: reduced)
            moon.radius.step(dt, response: moon.on ? 0.42 : 0.30, damping: moon.on ? 0.86 : 0.95, reduced: reduced)
            moon.opacity.step(dt, response: moon.on ? 0.30 : 0.26, damping: 0.95, reduced: reduced)
            moons[id] = moon
            if !order.contains(id) && moon.opacity.value == 0 && moon.radius.value == 0 {
                if let pair = pairs.removeValue(forKey: id) { removeOrbit(pair); pair.0.removeFromSuperlayer(); pair.1.removeFromSuperlayer() }
                moons[id] = nil
            }
        }
    }
    func pose(_ id: String, earth: CGRect) -> (center: CGPoint, diameter: Double, opacity: Double, front: Bool)? {
        guard let moon = moons[id], moon.opacity.value > 0.01 else { return nil }
        let p = phase + moon.angle.value, angle = -18.0 * Double.pi / 180, r = moon.radius.value
        let x = (earth.width / 2 + 10) * cos(p) * r, y = 16 * sin(p) * r
        return (.init(x: earth.midX + x * cos(angle) - y * sin(angle), y: earth.midY + x * sin(angle) + y * cos(angle)),
                12 * (0.55 + 0.45 * BrowserIslandMath.clamp(moon.opacity.value)), BrowserIslandMath.clamp(moon.opacity.value), sin(p) > 0 && r > 0.9)
    }
    func render(earth: CGRect, images: BrowserBodyImages, scale: Int) {
        earthFrame = earth
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        for (id, pair) in pairs {
            guard let pose = pose(id, earth: earth) else { pair.0.isHidden = true; pair.1.isHidden = true; removeOrbit(pair); continue }
            for (i, layer) in [pair.0, pair.1].enumerated() {
                layer.isHidden = (i == 1) != pose.front; layer.opacity = Float(pose.opacity)
                layer.bounds = CGRect(x: 0, y: 0, width: pose.diameter, height: pose.diameter); layer.position = pose.center
                layer.cornerRadius = pose.diameter / 2; layer.borderWidth = 0.5; layer.borderColor = NSColor.white.withAlphaComponent(0.34).cgColor
                layer.shadowColor = NSColor.black.cgColor; layer.shadowOpacity = 0.4; layer.shadowRadius = 6; layer.shadowOffset = CGSize(width: 0, height: 2)
                layer.contents = images.image("moon", outer: 12, scale: scale, center: pose.center); layer.contentsScale = CGFloat(scale)
                if !visible || paused || busy { layer.removeAnimation(forKey: "browser.tab.orbit") }
                else {
                    layer.isHidden = false
                    if layer.animation(forKey: "browser.tab.orbit") == nil, let moon = moons[id], moon.on {
                        installOrbit(on: layer, front: i == 1, moon: moon, earth: earth)
                    }
                }
            }
        }
    }
    /// Detached offscreen hosts sample explicitly. A real visible host alone may retain an orbit animation.
    func setVisible(_ visible: Bool) {
        if self.visible && !visible { _ = synchronizePresentationPhase() }
        self.visible = visible; if !visible { for pair in pairs.values { removeOrbit(pair) } }
    }
    func hit(at point: CGPoint) -> (id: String, center: CGPoint)? {
        guard visible else { return nil }
        for id in order {
            guard let pair = pairs[id] else { continue }
            for layer in [pair.1, pair.0] {
                guard !layer.isHidden, let picture = layer.presentation(), picture.opacity > 0.9 else { continue }
                let center = picture.position
                if hypot(point.x - center.x, point.y - center.y) <= 12 { return (id, center) }
            }
        }
        return nil
    }
    private func synchronizePresentationPhase() -> Bool {
        guard earthFrame.width > 0 else { return false }
        let tilt = -18.0 * Double.pi / 180
        for id in order {
            guard let pair = pairs[id], let moon = moons[id], moon.on, !moon.angle.busy else { continue }
            for layer in [pair.0, pair.1] where layer.animation(forKey: "browser.tab.orbit") != nil {
                guard let picture = layer.presentation(), picture.opacity > 0.9 else { continue }
                let dx = picture.position.x - earthFrame.midX, dy = picture.position.y - earthFrame.midY
                let x = (dx * cos(tilt) + dy * sin(tilt)) / (earthFrame.width / 2 + 10)
                let y = (-dx * sin(tilt) + dy * cos(tilt)) / 16
                let current = atan2(y, x) - moon.angle.value
                phase = current + round((phase - current) / (2 * .pi)) * 2 * .pi
                return true
            }
        }
        return false
    }
    private func installOrbit(on layer: CALayer, front: Bool, moon: Moon, earth: CGRect) {
        let position = CAKeyframeAnimation(keyPath: "position"), opacity = CAKeyframeAnimation(keyPath: "opacity")
        var points: [NSValue] = [], alphas: [NSNumber] = []
        let tilt = -18.0 * Double.pi / 180
        for i in 0...180 {
            let p = phase + moon.angle.value + Double(i) * 2 * Double.pi / 180
            let x = (earth.width / 2 + 10) * cos(p), y = 16 * sin(p)
            points.append(NSValue(point: CGPoint(x: earth.midX + x * cos(tilt) - y * sin(tilt), y: earth.midY + x * sin(tilt) + y * cos(tilt))))
            alphas.append(NSNumber(value: (sin(p) > 0) == front ? 1.0 : 0.0))
        }
        position.values = points; position.calculationMode = .linear; opacity.values = alphas; opacity.calculationMode = .discrete
        let orbit = CAAnimationGroup(); orbit.animations = [position, opacity]; orbit.duration = 18; orbit.repeatCount = .infinity
        orbit.isRemovedOnCompletion = true; layer.add(orbit, forKey: "browser.tab.orbit")
    }
    private func removeOrbit(_ pair: (CALayer, CALayer)) { pair.0.removeAnimation(forKey: "browser.tab.orbit"); pair.1.removeAnimation(forKey: "browser.tab.orbit") }
    func dispose() { setVisible(false); back.sublayers = nil; front.sublayers = nil; pairs = [:]; moons = [:]; order = [] }
}
