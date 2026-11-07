import AppKit
import QuartzCore

/// Offscreen seeds and production-control lifecycle checks, also run by the normal selftest.
@MainActor enum OrbRetainedControlVerification {
    static func run(scale: CGFloat, check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 120)); host.wantsLayer = true
        let root = host.layer!
        func audit() -> [OrbInvisibleAnimationVerification.Finding] {
            OrbInvisibleAnimationVerification.findings(in: [host], scenario: "visibility-definition", at: CACurrentMediaTime())
        }
        let front = CALayer(), back = CALayer()
        for (index, copy) in [front, back].enumerated() {
            copy.opacity = 0; root.addSublayer(copy)
            let gate = CAKeyframeAnimation(keyPath: "opacity")
            gate.values = index == 0 ? [0, 1, 0] : [1, 0, 1]
            gate.keyTimes = [0, 0.5, 1]; gate.calculationMode = .discrete; gate.duration = 2; gate.repeatCount = .infinity
            copy.add(gate, forKey: "alternating-copy")
        }
        check(audit().isEmpty, "definition seed: alternating visible copies pass")
        front.removeFromSuperlayer(); back.removeFromSuperlayer()
        let zero = CALayer(); root.addSublayer(zero)
        let loop = CABasicAnimation(keyPath: "opacity"); loop.fromValue = 0; loop.toValue = 0
        loop.duration = 1; loop.repeatCount = .infinity; zero.add(loop, forKey: "zero-to-zero")
        check(audit().map(\.key) == ["zero-to-zero"], "definition seed: zero-to-zero infinite opacity fails")
        zero.removeFromSuperlayer()
        let groupedZero = CALayer(); root.addSublayer(groupedZero)
        let group = CAAnimationGroup(); group.animations = [loop]; group.duration = 1; group.repeatCount = .infinity
        groupedZero.add(group, forKey: "grouped-zero-to-zero")
        check(audit().count == 2, "definition does not exempt an animated layer or an infinite group")
        groupedZero.removeFromSuperlayer()
        let maskOwner = CALayer(), mask = CALayer(); root.addSublayer(maskOwner); maskOwner.opacity = 0; maskOwner.mask = mask
        let spin = CABasicAnimation(keyPath: "transform.rotation.z"); spin.fromValue = 0; spin.toValue = 6.28
        spin.duration = 1; spin.repeatCount = .infinity; mask.add(spin, forKey: "hidden-mask")
        check(audit().map(\.key) == ["hidden-mask"], "definition includes a mask owner's ancestry")
        maskOwner.removeFromSuperlayer()
        func basic(_ from: Double?, _ to: Double?, _ by: Double?, _ expected: Double, _ name: String) {
            let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = from; a.toValue = to; a.byValue = by
            check(abs(OrbAnimationVisibility.maximum(0.2, animations: [a]) - expected) < 1e-9, "definition basic " + name)
        }
        basic(0.1, 0.7, nil, 0.7, "from/to")
        basic(0.1, nil, 0.3, 0.4, "from/by")
        basic(nil, 0.5, 0.3, 0.5, "to/by")
        basic(nil, nil, 0.3, 0.5, "by/model")
        basic(nil, 0.7, nil, 0.7, "to/model")
        basic(0.7, nil, nil, 0.7, "from/model")
        let outer = CALayer(), inner = CALayer(); root.addSublayer(outer); outer.addSublayer(inner)
        outer.opacity = 0.2; inner.opacity = 0.04
        check(!OrbAnimationVisibility.state(layer: inner, view: host).isVisible, "definition multiplies nonzero ancestor opacity below 0.01")
        inner.opacity = 0.06
        check(OrbAnimationVisibility.state(layer: inner, view: host).isVisible, "definition keeps product above 0.01")
        outer.isHidden = true
        check(!OrbAnimationVisibility.state(layer: inner, view: host).isVisible, "definition detects hidden ancestor")
        let hidden = CABasicAnimation(keyPath: "hidden"); hidden.fromValue = true; hidden.toValue = false; hidden.duration = 2
        outer.add(hidden, forKey: "hidden-transition")
        check(OrbAnimationVisibility.state(layer: inner, view: host).isVisible, "definition permits animated hidden state")
        outer.removeFromSuperlayer()

        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let voice = NativeComposerVoiceWaveform(frame: CGRect(x: 10, y: 10, width: 36, height: 30))
        let shortcut = SettingsButton(frame: CGRect(x: 60, y: 10, width: 120, height: 30))
        shortcut.style = .shortcut; shortcut.title = "Record shortcut"
        host.addSubview(voice); host.addSubview(shortcut)
        // Keep the paused clock fixed and nonzero; zero is Core Animation's implicit-begin sentinel.
        let epoch = VerificationRaster.epoch + 3600
        root.speed = 0; root.timeOffset = epoch
        voice.active = true; shortcut.recordingShortcut = true; host.layoutSubtreeIfNeeded()
        let bars = voice.layer?.sublayers ?? []
        func loops() -> [CAAnimation] {
            bars.compactMap { $0.animation(forKey: "composer.voice") } + [shortcut.layer?.animation(forKey: "shortcut.recording")].compactMap { $0 }
        }
        let epochs = loops().map(\.beginTime)
        check(loops().count == 8, "retained controls visible: seven bars and recording pulse run")
        check(Set(epochs.dropLast()).count == 1, "retained waveform bars share one initial epoch")
        for (name, hide, show) in [
            ("ancestor view alpha", { host.alphaValue = 0 }, { host.alphaValue = 1 }),
            ("ancestor layer opacity", { root.opacity = 0 }, { root.opacity = 1 }),
            ("window alpha", { window.alphaValue = 0 }, { window.alphaValue = 1 }),
            ("ancestor hidden", { host.isHidden = true }, { host.isHidden = false }),
            ("fractional opacity product", { host.alphaValue = 0.005 }, { host.alphaValue = 1 })
        ] as [(String, () -> Void, () -> Void)] {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hide(); root.timeOffset += 0.375
            CATransaction.commit()
            check(loops().isEmpty, "retained controls stop: " + name)
            check(audit().isEmpty, "retained controls audit clean: " + name)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            show(); root.timeOffset += 0.625
            CATransaction.commit()
            check(loops().count == 8, "retained controls resume: " + name)
            check(loops().map(\.beginTime) == epochs, "retained controls preserve shared elapsed phase: " + name)
        }
        voice.isHidden = true; shortcut.isHidden = true
        check(loops().isEmpty, "retained controls stop on own hidden state")
        voice.isHidden = false; shortcut.isHidden = false
        check(loops().count == 8 && loops().map(\.beginTime) == epochs, "retained controls resume on own unhide")
        let transparent = NSView(frame: host.bounds); transparent.wantsLayer = true; transparent.alphaValue = 0
        host.addSubview(transparent); transparent.addSubview(voice); transparent.addSubview(shortcut)
        check(loops().isEmpty, "retained controls rebind under transparent parent")
        transparent.alphaValue = 1
        check(loops().count == 8, "retained controls observe replacement parent")
        root.speed = 1; root.timeOffset = 0
        let renderer = OffscreenRenderer(size: host.bounds.size, host: root, scale: scale)
        var fadeCompletions = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08; context.allowsImplicitAnimation = true
            context.completionHandler = { MainActor.assumeIsolated { fadeCompletions += 1 } }
            host.animator().alphaValue = 0
        }
        check(loops().count == 8, "retained controls keep running during an AppKit fade")
        func pump(_ duration: Double) {
            let end = CACurrentMediaTime() + duration
            while CACurrentMediaTime() < end {
                _ = renderer.render(at: CACurrentMediaTime())
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            }
        }
        pump(0.2)
        check(loops().isEmpty, "retained controls stop after the AppKit fade completes")
        check(fadeCompletions == 1, "retained visibility preserves the existing fade completion")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08; context.allowsImplicitAnimation = true
            host.animator().alphaValue = 1
        }
        pump(0.02)
        check(loops().count == 8, "retained controls rejoin during an AppKit reveal")
        pump(0.15)
        check(loops().map(\.beginTime) == epochs, "retained controls keep their original epoch across an AppKit fade")
        voice.active = false; shortcut.recordingShortcut = false
        check(loops().isEmpty, "retained controls semantic stop clears all loops")
        window.contentView = nil
    }
}
