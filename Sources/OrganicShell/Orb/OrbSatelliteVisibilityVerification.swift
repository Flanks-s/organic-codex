#if ORB_SELFTEST
import AppKit
import QuartzCore

/// Real satellite layers and clock mappings, with no visible window, Core process or per-frame product driver.
@MainActor enum OrbSatelliteVisibilityVerification {
    static func run(to output: URL, check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        var rows: [[String: Any]] = []
        func record(_ value: Bool, _ name: String) { check(value, name); rows.append(["check": name, "passed": value]) }
        func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap { layers($0) } }
        func animations(_ satellites: OrbSatellites) -> [CAAnimation] {
            (layers(satellites.back) + layers(satellites.front)).flatMap { l in (l.animationKeys() ?? []).compactMap { l.animation(forKey: $0) } }
        }
        func orbits(_ satellites: OrbSatellites) -> Int {
            (layers(satellites.back) + layers(satellites.front)).filter { $0.animation(forKey: "orbit") != nil }.count
        }
        let profile = DisplayProfile(name: "visibility", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
        // Keep the pixel clock fixed and nonzero, using the Split verification epoch.
        let epoch = VerificationRaster.epoch + 3600
        for pace in [0.0, 0.5, 1.0] {
            let tested = OrbSatellites(metrics: OrbMetrics()), reference = OrbSatellites(metrics: OrbMetrics())
            var moons = [OrbSatellite(id: "moon", face: "S", pace: pace)]
            func configure(_ s: OrbSatellites, at t: Double, shown: Bool) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                s.configure(moons, size: 56, scale: 2, retired: false, mode: .orbit, reduceMotion: false,
                            now: epoch + t, visibleIDs: shown ? nil : [], motionProfile: profile)
            }
            configure(tested, at: 0, shown: true); configure(reference, at: 0, shown: true)
            record(orbits(tested) == 2, "visible pair retains both continuous orbits at pace \(pace)")
            configure(tested, at: 0.375, shown: false); configure(reference, at: 0.375, shown: true)
            record(animations(tested).isEmpty, "hidden pair has no orbit or exposure animation at pace \(pace)")
            moons[0].pace = 1 - pace
            configure(tested, at: 1.25, shown: false); configure(reference, at: 1.25, shown: true)
            record(animations(tested).isEmpty, "hidden pace update cannot restart animations at pace \(pace)")
            configure(tested, at: 4.125, shown: true); configure(reference, at: 4.125, shown: true)
            let a = tested.phases(at: epoch + 4.125), b = reference.phases(at: epoch + 4.125)
            record(a.count == 1 && a[0].0 == b[0].0 && a[0].1 == b[0].1 && a[0].0 == a[0].1,
                   "revealed pair rejoins the uninterrupted common clock at pace \(pace)")
            record(orbits(tested) == 2, "reveal restores continuous orbits at pace \(pace)")
            let begins = (layers(tested.back) + layers(tested.front)).compactMap { $0.animation(forKey: "orbit")?.beginTime }
            record(begins == [1e-6, 1e-6], "reveal keeps the original orbit epoch at pace \(pace)")
            func canvas(_ s: OrbSatellites) -> CALayer {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                let root = CALayer(); root.bounds = CGRect(x: 0, y: 0, width: 160, height: 160)
                // Give both render targets a defined opaque backdrop before comparing exact bytes.
                root.backgroundColor = CGColor(gray: 0, alpha: 1)
                root.addSublayer(s.back); root.addSublayer(s.front)
                s.back.position = CGPoint(x: 52, y: 52); s.front.position = s.back.position
                return root
            }
            let testedRenderer = OffscreenRenderer(size: CGSize(width: 160, height: 160), host: canvas(tested), scale: 2)
            let referenceRenderer = OffscreenRenderer(size: CGSize(width: 160, height: 160), host: canvas(reference), scale: 2)
            record(testedRenderer.render(at: epoch + 4.125) == referenceRenderer.render(at: epoch + 4.125),
                   "revealed pixels equal an uninterrupted orbit at pace \(pace)")
        }
        for behavior in ["complete", "pause", "cancel"] {
            let tested = OrbSatellites(metrics: OrbMetrics()), moon = OrbSatellite(id: "retiring", face: "R")
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 160)); host.wantsLayer = true
            let root = host.layer!; root.addSublayer(tested.back); root.addSublayer(tested.front)
            tested.back.position = CGPoint(x: 52, y: 52); tested.front.position = tested.back.position
            let renderer = OffscreenRenderer(size: CGSize(width: 160, height: 160), host: root)
            func configure(_ retired: Bool) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                tested.configure([moon], size: 56, scale: 2, retired: retired, mode: .orbit,
                                 reduceMotion: false, now: CACurrentMediaTime())
            }
            configure(false)
            // Put the fixture just before the existing back-side retirement gate; do not change its duration.
            let now = CACurrentMediaTime()
            for host in [tested.back, tested.front] {
                for clock in host.sublayers ?? [] {
                    clock.beginTime = host.convertTime(now, from: nil); clock.timeOffset = .pi - 0.16
                }
            }
            configure(true)
            record(orbits(tested) == 2 && animations(tested).contains { $0 is CAKeyframeAnimation && $0.repeatCount == 0 },
                   "retirement keeps orbiting until the finite back-side gate (\(behavior))")
            func pump(_ duration: Double) {
                let end = CACurrentMediaTime() + duration
                while CACurrentMediaTime() < end {
                    _ = renderer.render(at: CACurrentMediaTime())
                    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
                }
                CATransaction.flush()
            }
            if behavior == "pause" {
                let time = CACurrentMediaTime()
                for host in [tested.back, tested.front] { OrbMotion.setAnimationsPaused(true, on: host, at: time) }
                pump(0.2)
                record(orbits(tested) == 2, "paused retirement cannot finish on a wall-clock deadline")
                let resume = CACurrentMediaTime()
                for host in [tested.back, tested.front] { OrbMotion.setAnimationsPaused(false, on: host, at: resume) }
            } else if behavior == "cancel" { configure(false) }
            pump(0.3)
            rows.append(["behavior": behavior, "remainingAnimations": animations(tested).map { ["type": String(describing: type(of: $0)), "begin": $0.beginTime, "duration": $0.duration, "repeat": String($0.repeatCount)] }, "phase": tested.phases(at: CACurrentMediaTime()).map { [$0.0, $0.1] }])
            record(behavior == "cancel" ? orbits(tested) == 2 : animations(tested).isEmpty,
                   behavior == "cancel" ? "cancelled retirement cannot remove a newly visible orbit" : "completed retirement leaves no animation (\(behavior))")
        }
        let orb = OrbComponent(id: "visibility-host")
        var input = OrbConfiguration(content: .identity(.assigned(0)), drawingSize: 56,
                                     satellites: [.init(id: "host-moon", face: "S")], ambient: true)
        orb.configure(input)
        func orbOrbits() -> Int { orb.verificationLayers.flatMap { layers($0) }.filter { $0.animation(forKey: "orbit") != nil }.count }
        orb.setOpacity(0)
        record(orbOrbits() == 0, "transparent Dock ancestor retains no orbit")
        if let carrier = orb.prepareDragDecoration() {
            let count = carrier.verificationLayers.flatMap { layers($0) }.filter { $0.animation(forKey: "orbit") != nil }.count
            record(count == 2 && orbOrbits() == 0, "visible carry restores the hidden source's clocked orbit without waking its source")
            carrier.dispose()
        } else { record(false, "visible carry restores the hidden source's clocked orbit without waking its source") }
        orb.setOpacity(1)
        record(orbOrbits() == 2, "Dock reveal restores both continuous orbits")
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200)); parent.wantsLayer = true
        parent.addSubview(orb.backView); parent.addSubview(orb.glassView); parent.addSubview(orb.frontView)
        parent.isHidden = true
        record(orbOrbits() == 0, "hidden NSView ancestor retains no orbit")
        parent.isHidden = false
        record(orbOrbits() == 2, "unhidden NSView ancestor restores both continuous orbits")
        input.satellitesRetired = true; input.reduceMotion = true; orb.configure(input)
        record(orbOrbits() == 0, "Reduce Motion retirement removes the orbit immediately")
        input.satellitesRetired = false; input.reduceMotion = false; orb.configure(input)
        record(orbOrbits() == 2, "retired pair can become visible and continuous again")
        orb.dispose()
        let exposure = OrbComponent(id: "hidden-exposure-policy")
        exposure.motionProfile = profile
        exposure.configure(.init(content: .identity(.assigned(0)), drawingSize: 56,
                                 satellites: [.init(id: "fast", face: "F", pace: 1)],
                                 orbitShape: .init(diameter: 12, radius: 200, flatten: 0.3, tiltDegrees: -18)))
        func exposureCount() -> Int {
            exposure.verificationLayers.flatMap { layers($0) }.flatMap { $0.animationKeys() ?? [] }.filter { $0.hasPrefix("m10F.") }.count
        }
        record(exposureCount() > 0, "large-radius fixture actually submits satellite exposure")
        exposure.setOpacity(0); exposure.exposureEnabled = false; exposure.setOpacity(1)
        record(exposureCount() == 0, "disabling exposure while hidden cannot resurrect cached exposure on reveal")
        exposure.dispose()
        runRetiringPreparation(check: record)
        record(!NSApp.windows.contains(where: \.isVisible), "satellite visibility verification never orders a window")
        try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("satellite-visibility.json"))
    }

    /// Reproduce the idle preparation race with a pending retire gate. A paused parent makes the
    /// construction deterministic; both real CA callbacks must still complete after it resumes.
    static func runRetiringPreparation(check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }
        func submitted(_ orb: OrbComponent) -> [CALayer] { orb.verificationLayers.flatMap(layers) }
        func orbits(_ orb: OrbComponent) -> Int { submitted(orb).filter { $0.animation(forKey: "orbit") != nil }.count }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 160)); host.wantsLayer = true
        let renderer = OffscreenRenderer(size: host.bounds.size, host: host.layer!, scale: 1)
        let source = OrbComponent(id: "retiring-preparation")
        var input = OrbConfiguration(content: .identity(.assigned(0)), drawingSize: 56,
                                     satellites: [.init(id: "pending-retire", face: "R", pace: 0.5)], ambient: true)
        // Render owned planes directly; AppKit backing layers have a separate hosting clock.
        for layer in source.verificationLayers { host.layer!.addSublayer(layer) }
        source.configure(input); source.setCanvasSize(host.bounds.size)
        source.setFrame(CGRect(x: 50, y: 50, width: 56, height: 56))
        let now = CACurrentMediaTime()
        for pose in submitted(source) where pose.animation(forKey: "orbit") != nil {
            if let clock = pose.superlayer {
                clock.beginTime = clock.superlayer!.convertTime(now, from: nil); clock.timeOffset = .pi - 0.16
            }
        }
        input.satellitesRetired = true; source.configure(input)
        source.verificationPause(true, at: CACurrentMediaTime())
        _ = renderer.render(at: CACurrentMediaTime())
        let sourceRetire = submitted(source).compactMap { $0.animation(forKey: "retire") }.first { $0.delegate != nil }
        check(sourceRetire != nil && orbits(source) == 2, "retiring preparation starts with a pending retire gate and both orbits")
        let conversation = Conversation(id: "retiring-preparation", title: "Retiring preparation")
        let flight = ModeFlight(); flight.resize(to: host.bounds.size); flight.endpointOrb = { _ in source }
        host.addSubview(flight.view)
        let token = ModeFlight.Token(id: conversation.id, conversation: conversation,
                                     from: CGRect(x: 50, y: 50, width: 56, height: 56),
                                     to: CGRect(x: 150, y: 50, width: 32, height: 32), start: 0, absorbed: false)
        flight.prewarm(tokens: [token])
        check(flight.preparedTokenCount == 1, "retiring preparation: ModeFlight.prewarm copies a retiring orb without an exception")
        check(orbits(source) == 2, "retiring prewarm leaves the original pending orbit intact")
        guard let carry = source.prepareDragDecoration() else {
            check(false, "retiring preparation creates a direct drag decoration"); flight.shutdown(); source.dispose(); return
        }
        for layer in carry.verificationLayers { host.layer!.addSublayer(layer) }
        let carryRetire = submitted(carry).compactMap { $0.animation(forKey: "retire") }.first { $0.delegate != nil }
        check(carryRetire != nil && carryRetire?.delegate !== sourceRetire?.delegate,
              "retiring drag decoration owns an independent retirement callback")
        check(orbits(carry) == 2, "retiring drag decoration keeps orbiting before the back-side gate")
        _ = renderer.render(at: CACurrentMediaTime())
        let resume = CACurrentMediaTime(); source.verificationPause(false, at: resume); carry.verificationPause(false, at: resume)
        let end = CACurrentMediaTime() + 0.35
        while CACurrentMediaTime() < end {
            _ = renderer.render(at: CACurrentMediaTime())
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        check(orbits(source) == 0,
              "retiring preparation preserves the original retirement callback")
        check(orbits(carry) == 0,
              "retiring preparation delivers the copied retirement callback")
        flight.shutdown(); carry.dispose(); source.dispose()
    }
}
#endif
