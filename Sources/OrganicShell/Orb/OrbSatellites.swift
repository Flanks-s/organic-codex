import AppKit
import QuartzCore

/// Each moon has one clock for its two copies. No timer, display link, layout, or per-frame Swift.
@MainActor final class OrbSatellites {
    let back = CALayer(), front = CALayer()
    @MainActor private final class RetirementCompletion: NSObject, CAAnimationDelegate {
        let finish: @MainActor () -> Void
        init(_ finish: @escaping @MainActor () -> Void) { self.finish = finish }
        nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
            guard flag else { return }
            Task { @MainActor [weak self] in self?.finish() }
        }
    }
    private struct HeldAnimation {
        let layer: CALayer, key: String, animation: CAAnimation
    }
    private final class Pair {
        let backClock = CALayer(), frontClock = CALayer()
        let backDot = CALayer(), frontDot = CALayer()
        let backPose=CALayer(),frontPose=CALayer()
        let backInk=CAReplicatorLayer(),frontInk=CAReplicatorLayer()
        let backFace = CATextLayer(), frontFace = CATextLayer()
        var drawingKey = ""
        var geometrySize: CGFloat = 0
        var index = -1
        var retired = false
        var initialized = false
        var mode: OrbSatelliteMode = .orbit
        var rowTarget: CGPoint?
        var shape:OrbOrbitShape?
        var exposureSpeed:Double?
        var admitted = true
        var hidden = false
        var held: [HeldAnimation] = []
        var retirementEnd: Double?
        var retirementCompletion: RetirementCompletion?
        init() {
            backClock.addSublayer(backPose);frontClock.addSublayer(frontPose)
            backPose.addSublayer(backDot);frontPose.addSublayer(frontDot)
            backDot.addSublayer(backInk);frontDot.addSublayer(frontInk)
            backInk.addSublayer(backFace);frontInk.addSublayer(frontFace)
            backInk.instanceCount=1;frontInk.instanceCount=1
        }
    }
    private var pairs: [String: Pair] = [:]
    private var visible = true
    private let metrics: OrbMetrics
    var onExposureInvalidated:((CALayer)->Void)?
    init(metrics: OrbMetrics) { self.metrics = metrics }

    func configure(_ satellites: [OrbSatellite], size: CGFloat, scale: CGFloat, retired: Bool, mode requestedMode: OrbSatelliteMode,
                   reduceMotion: Bool, now: CFTimeInterval, diameter: CGFloat? = nil, visibleIDs: Set<String>? = nil,
                   shape:OrbOrbitShape?=nil,accent:NSColor?=nil,followStagger:Double=0.02,
                   motionProfile:DisplayProfile?=nil,motionScale:CGFloat=1) {
        let mode: OrbSatelliteMode = retired ? .orbit : requestedMode
        let rows = rowTargets(satellites, size: size)
        let ids = Set(satellites.map(\.id))
        for id in Array(pairs.keys) where !ids.contains(id) {
            pairs[id]?.backClock.removeFromSuperlayer(); pairs[id]?.frontClock.removeFromSuperlayer(); pairs[id] = nil
        }
        // First occurrence wins for malformed duplicate input; never create two clocks for the same ID.
        var seen: Set<String> = []
        for (index, satellite) in satellites.enumerated() where seen.insert(satellite.id).inserted {
            let pair = pairs[satellite.id] ?? {
                let p = Pair(); pairs[satellite.id] = p
                back.addSublayer(p.backClock); front.addSublayer(p.frontClock)
                return p
            }()
            // Keep the clocks advancing while hidden. Reattaching the original animation uses their
            // current local time, including every pace change and any existing ambient pause.
            let wasHidden = pair.hidden
            restore(pair, at: now)
            let pace = satellite.pace.isFinite ? min(1, max(0, satellite.pace)) : 0
            let speed = mode != .orbit && pair.initialized ? Double(pair.backClock.speed)
                : max(retired ? (OrbTuning.slow + OrbTuning.fast) / 2 : 0,
                      OrbTuning.slow + (OrbTuning.fast - OrbTuning.slow) * pace)
            // The parent motion roots can already be paused. Rebase in THEIR local time, not wall time.
            let hostNow = back.convertTime(now, from: nil)
            let phase = pair.initialized ? pair.backClock.convertTime(hostNow, from: back) : 0
            for clock in [pair.backClock, pair.frontClock] {
                clock.beginTime = hostNow; clock.timeOffset = phase; clock.speed = Float(speed)
            }
            let d = max(1, diameter ?? shape?.diameter ?? size * OrbTuning.satelliteSize)
            let opaque=OrbDisplayEnvironment.shared.options.opaqueSurfaces
            let accent=accent ?? NSColor.controlAccentColor
            let key = "\(satellite.face)|\(satellite.done)|\(size)|\(scale)|\(d)|\(opaque)|\(NSAppearance.currentDrawing().name.rawValue)|\(accent.usingColorSpace(.sRGB)?.description ?? "")"
            if pair.drawingKey != key {
                pair.drawingKey = key
                for (dot, face) in [(pair.backDot, pair.backFace), (pair.frontDot, pair.frontFace)] {
                    metrics.value.textLayouts += 1
                    dot.bounds = CGRect(x: 0, y: 0, width: d, height: d); dot.cornerRadius = d/2
                    dot.backgroundColor = OrbDisplayEnvironment.surface(satellite.done ? .systemGray:accent,opacity:satellite.done ? 0.85:0.9).cgColor
                    dot.borderWidth = 0.5; dot.borderColor = OrbDisplayEnvironment.surface(.white,opacity:0.18).cgColor
                    let font = NSFont.systemFont(ofSize: d*0.34, weight: .semibold)
                    face.font = font; face.fontSize = font.pointSize; face.string = satellite.face
                    face.foregroundColor = NSColor.white.withAlphaComponent(satellite.done && !opaque ? 0.75 : 1).cgColor
                    face.alignmentMode = .center; face.contentsScale = scale*2
                    let h = font.ascender - font.descender
                    face.frame = CGRect(x: 0, y: (d-h)/2, width: d, height: h)
                }
            }
            let geometryChanged = pair.geometrySize != size || pair.index != index || pair.shape != shape
            for dot in [pair.backDot,pair.frontDot] {
                dot.shadowOpacity=opaque || mode == .orbit ? 0:(NSAppearance.currentDrawing().bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? 0.26:0.14)
                dot.shadowColor=NSColor.black.cgColor; dot.shadowRadius=4; dot.shadowOffset=CGSize(width:0,height:2)
                dot.shadowPath=CGPath(ellipseIn:dot.bounds,transform:nil)
            }
            let wasOut = pair.mode != .orbit
            if mode == .orbit && (geometryChanged || wasOut) {
                pair.geometrySize = size; pair.index = index
                for (dot, clock, isFront,solid,ink) in [(pair.backPose, pair.backClock, false,pair.backDot,pair.backInk), (pair.frontPose, pair.frontClock, true,pair.frontDot,pair.frontInk)] {
                    let departure = wasOut && pair.initialized ? dot.presentation()?.position ?? dot.position : nil
                    dot.removeAllAnimations()
                    metrics.value.orbitBuilds += 1
                    dot.add(orbit(index: index, size: size, front: isFront,shape:shape), forKey: "orbit")
                    solid.removeAnimation(forKey:"m10F.solid");ink.removeAnimation(forKey:"m10F.ink")
                    onExposureInvalidated?(solid);onExposureInvalidated?(ink)
                    let angle = Double(index)*2.399 + phase*Self.rate(index)
                    dot.position = Self.point(angle: angle, size: size,shape:shape)
                    dot.opacity = (sin(angle) > 0) == isFront ? 1 : 0
                    dot.setAffineTransform(CGAffineTransform(scaleX: 0.9+0.1*sin(angle), y: 0.9+0.1*sin(angle)))
                    if let departure, !reduceMotion {
                        let delta = CGPoint(x: departure.x-dot.position.x, y: departure.y-dot.position.y)
                        let settle = CASpringAnimation(keyPath: "position")
                        settle.isAdditive = true; settle.fromValue = NSValue(point: delta); settle.toValue = NSValue(point: .zero)
                        settle.damping = 18; settle.duration = settle.settlingDuration
                        realTime(settle, clock: clock, now: now)
                        dot.add(settle, forKey: "settle")
                        if let profile=motionProfile {
                            let springX=Spring(from:delta.x,to:0,response:2 * .pi/10,damping:0.9,epsilon:1e-12)
                            let springY=Spring(from:delta.y,to:0,response:2 * .pi/10,damping:0.9,epsilon:1e-12)
                            OrbSatelliteExposure.install(solid:solid,ink:ink,diameter:d,duration:settle.duration,timing:settle,profile:profile,displayScale:motionScale) { t in
                                let p=Self.motionPose(index:index,size:size,shape:shape,time:phase+t*speed)
                                return (CGPoint(x:p.0.x+springX.sample(t).value,y:p.0.y+springY.sample(t).value),p.1)
                            }
                        }
                    } else if let profile=motionProfile,!reduceMotion {
                        let timing=CAAnimation();timing.beginTime=1e-6
                        OrbSatelliteExposure.install(solid:solid,ink:ink,diameter:d,duration:2 * .pi/Self.rate(index),timing:timing,profile:profile,speed:speed,loop:true,displayScale:motionScale) { t in
                            Self.motionPose(index:index,size:size,shape:shape,time:t)
                        }
                    }
                }
                pair.rowTarget = nil
            } else if mode == .orbit,pair.exposureSpeed != speed,let profile=motionProfile,!reduceMotion {
                let timing=CAAnimation();timing.beginTime=1e-6
                for (solid,ink) in [(pair.backDot,pair.backInk),(pair.frontDot,pair.frontInk)] {
                    onExposureInvalidated?(solid);onExposureInvalidated?(ink)
                    OrbSatelliteExposure.install(solid:solid,ink:ink,diameter:d,duration:2 * .pi/Self.rate(index),timing:timing,profile:profile,speed:speed,loop:true,displayScale:motionScale) { t in Self.motionPose(index:index,size:size,shape:shape,time:t) }
                }
            } else if mode != .orbit {
                let relative: CGPoint
                switch mode {
                case .rows: relative = rows[satellite.id] ?? .zero
                case .follow(let targets): relative = targets[satellite.id] ?? .zero
                case .orbit: relative = .zero
                }
                let target = CGPoint(x: size/2+relative.x, y: size/2+relative.y)
                if pair.mode != mode || geometryChanged || pair.rowTarget != target {
                    for (dot, clock, isFront,solid,ink) in [(pair.backPose, pair.backClock, false,pair.backDot,pair.backInk), (pair.frontPose, pair.frontClock, true,pair.frontDot,pair.frontInk)] {
                        let from = wasHidden && pair.mode == .orbit
                            ? Self.motionPose(index: pair.index, size: pair.geometrySize, shape: pair.shape, time: phase - 1e-6).0
                            : dot.presentation()?.position ?? dot.position
                        dot.removeAllAnimations(); dot.position = target; dot.opacity = isFront ? 1 : 0
                        dot.setAffineTransform(.identity)
                        solid.removeAnimation(forKey:"m10F.solid");ink.removeAnimation(forKey:"m10F.ink")
                        onExposureInvalidated?(solid);onExposureInvalidated?(ink)
                        if pair.initialized && !reduceMotion {
                            let row = CASpringAnimation(keyPath: "position")
                            row.fromValue = NSValue(point: from); row.toValue = NSValue(point: target)
                            row.damping = 16; row.duration = row.settlingDuration
                            let delay:Double
                            if case .follow=mode { delay=Double(index)*max(0,followStagger) } else { delay=0 }
                            realTime(row, clock: clock, now: now,delay:delay)
                            dot.add(row, forKey: "row")
                            if let profile=motionProfile {
                                let x=Spring(from:from.x,to:target.x,response:2 * .pi/10,damping:0.8,epsilon:1e-12)
                                let y=Spring(from:from.y,to:target.y,response:2 * .pi/10,damping:0.8,epsilon:1e-12)
                                OrbSatelliteExposure.install(solid:solid,ink:ink,diameter:d,duration:row.duration,timing:row,profile:profile,displayScale:motionScale) { t in (CGPoint(x:x.sample(t).value,y:y.sample(t).value),1) }
                            }
                        }
                    }
                }
                pair.rowTarget = target; pair.geometrySize = size; pair.index = index
            }
            if retired && reduceMotion {
                pair.retirementEnd = nil; pair.retirementCompletion = nil
                for clock in [pair.backClock, pair.frontClock] { clock.opacity = 0; clock.removeAnimation(forKey: "retire") }
            } else if retired && !pair.retired {
                let angle = Double(index)*2.399 + phase*Self.rate(index)
                let target = Double.pi + 2 * .pi * ceil((angle - .pi)/(2 * .pi))
                let wait = max(0, (target-angle)/Self.rate(index))
                pair.retirementEnd = phase + max(0.0001, wait)
                let completion = retirementCompletion(for: pair)
                pair.retirementCompletion = completion
                for clock in [pair.backClock, pair.frontClock] {
                    clock.opacity = 0
                    let hide = CAKeyframeAnimation(keyPath: "opacity")
                    hide.values = [1, 1, 0]; hide.keyTimes = [0, 0.999999, 1]
                    hide.duration = max(0.0001, wait); hide.beginTime = phase
                    hide.calculationMode = .discrete; hide.fillMode = .backwards
                    if clock === pair.backClock { hide.delegate = completion }
                    clock.add(hide, forKey: "retire")
                }
            } else if !retired {
                pair.retirementEnd = nil; pair.retirementCompletion = nil
                for clock in [pair.backClock, pair.frontClock] { clock.opacity = 1; clock.removeAnimation(forKey: "retire") }
            }
            pair.admitted = visibleIDs?.contains(satellite.id) ?? true
            if !pair.admitted {
                pair.backClock.opacity = 0; pair.frontClock.opacity = 0
            }
            pair.initialized = true; pair.retired = retired; pair.mode = mode; pair.shape=shape;pair.exposureSpeed=speed
            updateVisibility(pair, at: now)
        }
    }

    /// The host supplies whole-decoration visibility (for example a retained Dock orb at opacity zero).
    /// This only reacts to visibility edges; it does not sample or drive the orbit on the CPU.
    func setVisible(_ value: Bool, at now: CFTimeInterval) {
        guard visible != value else { return }
        visible = value
        for pair in pairs.values { updateVisibility(pair, at: now) }
    }

    private func retirementCompletion(for pair: Pair) -> RetirementCompletion {
        RetirementCompletion { [weak self, weak pair] in
            guard let self, let pair, pair.retired else { return }
            self.updateVisibility(pair, at: CACurrentMediaTime())
        }
    }

    /// A newly authored carry needs the source's clocked orbit even when that source is transparent.
    func animationEntries(on layer: CALayer) -> [(String, CAAnimation)] {
        var entries = (layer.animationKeys() ?? []).compactMap { key in layer.animation(forKey: key).map { (key, $0) } }
        let installed = Set(entries.map { $0.0 })
        for pair in pairs.values {
            entries += pair.held.filter { $0.layer === layer && !installed.contains($0.key) }.map { ($0.key, $0.animation) }
        }
        return entries
    }

    func discardHeldExposure() {
        for pair in pairs.values { pair.held.removeAll { $0.key.hasPrefix("m10F.") } }
    }

    /// Generic phase transfer has just copied the submitted/held animations. Bind a retirement callback
    /// to its new owner, then apply the recipient's visibility instead of copying the source's opacity.
    func synchronizeVisibility(from source: OrbSatellites, at now: CFTimeInterval) {
        for (id, pair) in pairs {
            guard let original = source.pairs[id] else { continue }
            pair.retirementEnd = original.retirementEnd
            if pair.retired, pair.retirementEnd != nil {
                let completion = retirementCompletion(for: pair)
                pair.retirementCompletion = completion
                // Installed animations are immutable; bind only a detached copy to the new owner.
                if let hide = pair.backClock.animation(forKey: "retire")?.copy() as? CAAnimation {
                    hide.delegate = completion; pair.backClock.add(hide, forKey: "retire")
                }
            }
            pair.held.removeAll(); pair.hidden = false
            updateVisibility(pair, at: now)
        }
    }

    private func updateVisibility(_ pair: Pair, at now: CFTimeInterval) {
        let retiring = pair.retirementEnd.map { pair.backClock.convertTime(now, from: nil) < $0 } ?? false
        if visible && pair.admitted && (!pair.retired || retiring) { restore(pair, at: now) }
        else { hide(pair) }
    }

    private func hide(_ pair: Pair) {
        guard !pair.hidden else { return }
        pair.hidden = true
        func hold(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] {
                if let animation = layer.animation(forKey: key) {
                    pair.held.append(HeldAnimation(layer: layer, key: key, animation: animation))
                }
            }
            onExposureInvalidated?(layer)
            layer.removeAllAnimations()
            for child in layer.sublayers ?? [] { hold(child) }
        }
        hold(pair.backClock); hold(pair.frontClock)
    }

    private func restore(_ pair: Pair, at now: CFTimeInterval) {
        guard pair.hidden else { return }
        pair.hidden = false
        for item in pair.held {
            let a = item.animation
            let elapsed = (item.layer.convertTime(now, from: nil) - a.beginTime) * Double(a.speed) + a.timeOffset
            // Finite transitions that ended offscreen must not be replayed on reveal.
            if !a.isRemovedOnCompletion || elapsed < a.duration * Double(a.repeatCount + 1) {
                item.layer.add(a, forKey: item.key)
            }
        }
        pair.held.removeAll()
    }

    func dispose() {
        for pair in pairs.values {
            pair.retirementCompletion = nil
            hide(pair); pair.held.removeAll()
            pair.backClock.removeFromSuperlayer(); pair.frontClock.removeFromSuperlayer()
        }
        pairs.removeAll()
    }

    private func rowTargets(_ satellites: [OrbSatellite], size: CGFloat) -> [String: CGPoint] {
        let d = size*OrbTuning.satelliteSize, gap = d*0.12
        let finished = satellites.enumerated().filter { $0.element.done }.sorted {
            let a = $0.element.finishedOrder ?? $0.offset, b = $1.element.finishedOrder ?? $1.offset
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let groups = [satellites.filter { !$0.done }, finished].filter { !$0.isEmpty }
        var result: [String: CGPoint] = [:]
        for (row, group) in groups.enumerated() {
            for (column, satellite) in group.enumerated() {
                result[satellite.id] = CGPoint(x: (CGFloat(column)-CGFloat(group.count-1)/2)*(d+gap),
                                              y: size/2+d/2+gap+CGFloat(row)*(d+gap))
            }
        }
        return result
    }

    /// Orbit time is radians. Scale finite row/settle springs back to real seconds, while parent pause still holds.
    private func realTime(_ a: CAAnimation, clock: CALayer, now: CFTimeInterval,delay:Double=0) {
        a.beginTime = clock.convertTime(now, from: nil)+delay*Double(clock.speed); a.speed = 1/max(0.001, clock.speed)
        a.fillMode = .backwards
    }

    private static func rate(_ index: Int) -> Double { 1 + 0.09 * Double(index % 3) }
    /// Exactly the existing 72-segment CA orbit, including its depth scale, not a different circular path.
    static func motionPose(index:Int,size:CGFloat,shape:OrbOrbitShape?,time:Double)->(CGPoint,CGFloat) {
        let f=(time*rate(index)/(2 * .pi)).truncatingRemainder(dividingBy:1)
        let u=(f<0 ? f+1:f)*72,i=Int(floor(u)),a=Double(index)*2.399+Double(i)*2 * .pi/72,b=a+2 * .pi/72,k=CGFloat(u-Double(i))
        let p=point(angle:a,size:size,shape:shape),q=point(angle:b,size:size,shape:shape)
        return (CGPoint(x:p.x+(q.x-p.x)*k,y:p.y+(q.y-p.y)*k),CGFloat(0.9+0.1*sin(a))+CGFloat(0.1*(sin(b)-sin(a)))*k)
    }
    static func point(angle: Double, size: CGFloat,shape:OrbOrbitShape?=nil) -> CGPoint {
        let radius=Double(shape?.radius ?? size*OrbTuning.orbitRadius),flatten=shape?.flatten ?? OrbTuning.flatten
        let tilt=shape.map { $0.tiltDegrees*Double.pi/180 } ?? OrbTuning.tilt
        let x=radius*cos(angle),y=radius*flatten*sin(angle)
        return CGPoint(x:Double(size)/2+x*cos(tilt)-y*sin(tilt),y:Double(size)/2+x*sin(tilt)+y*cos(tilt))
    }

    private func orbit(index: Int, size: CGFloat, front: Bool,shape:OrbOrbitShape?) -> CAAnimationGroup {
        let angles = (0...72).map { Double(index)*2.399 + 2 * .pi * Double($0)/72 }
        let p = CAKeyframeAnimation(keyPath: "position")
        p.values = angles.map { NSValue(point: Self.point(angle: $0, size: size,shape:shape)) }
        let s = CAKeyframeAnimation(keyPath: "transform.scale")
        s.values = angles.map { 0.9 + 0.1*sin($0) }
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = angles.map { (sin($0) > 0) == front ? 1.0 : 0.0 }; o.calculationMode = .discrete
        let group = CAAnimationGroup(); group.animations = [p, s, o]
        group.duration = 2 * .pi / Self.rate(index); group.beginTime = 1e-6
        group.repeatCount = .infinity; group.isRemovedOnCompletion = false
        group.preferredFrameRateRange = OrbTuning.ambient
        return group
    }

    #if ORB_SELFTEST || ISLAND_SELFTEST
    func phases(at now: CFTimeInterval) -> [(Double, Double)] {
        pairs.keys.sorted().compactMap { key in
            guard let p = pairs[key] else { return nil }
            return (p.backClock.convertTime(now, from: nil), p.frontClock.convertTime(now, from: nil))
        }
    }
    func sampleModels(phase: Double) {
        for pair in pairs.values where pair.mode == .orbit {
            let angle = Double(pair.index)*2.399 + Self.rate(pair.index)*phase
            for (dot, isFront) in [(pair.backPose, false), (pair.frontPose, true)] {
                dot.position = Self.point(angle: angle, size: pair.geometrySize,shape:pair.shape)
                dot.opacity = (sin(angle) > 0) == isFront ? 1 : 0
            }
        }
    }
    var geometry: [String: (front: CGPoint, back: CGPoint, frontOpacity: Float, backOpacity: Float)] {
        pairs.mapValues { p in (p.frontPose.position, p.backPose.position, p.frontPose.opacity, p.backPose.opacity) }
    }
    #endif
}
