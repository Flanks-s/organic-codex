import AppKit
import QuartzCore

/// A windowless audit of the submitted tree. No animation key, component or hidden ancestor is exempt.
@MainActor enum OrbInvisibleAnimationVerification {
    struct Finding {
        let scenario: String, path: String, key: String, animationPath: String, hiddenBy: [String]
        let time: Double
        var identity: String { "\(scenario)|\(path)|\(key)|\(animationPath)|\(hiddenBy.joined(separator: ","))" }
        var json: [String: Any] {
            ["scenario": scenario, "layer": path, "key": key, "animation": animationPath,
             "hiddenBy": hiddenBy, "time": time]
        }
    }

    static func unbounded(_ animation: CAAnimation) -> Bool {
        !animation.repeatCount.isFinite || animation.repeatCount >= Float.greatestFiniteMagnitude
            || !animation.repeatDuration.isFinite
    }

    static func findings(in roots: [NSView], scenario: String, at time: Double) -> [Finding] {
        var viewByLayer: [ObjectIdentifier: NSView] = [:], views: [NSView] = [], seenViews = Set<ObjectIdentifier>()
        func register(_ view: NSView) {
            guard seenViews.insert(ObjectIdentifier(view)).inserted else { return }
            views.append(view)
            if let layer = view.layer { viewByLayer[ObjectIdentifier(layer)] = view }
            for child in view.subviews { register(child) }
        }
        for root in roots { register(root) }
        var result: [Finding] = [], seenLayers = Set<ObjectIdentifier>()
        func walk(_ layer: CALayer, path: String, owner: NSView, ancestors: [CALayer] = []) {
            guard seenLayers.insert(ObjectIdentifier(layer)).inserted else { return }
            let view = viewByLayer[ObjectIdentifier(layer)] ?? owner
            let visibility = OrbAnimationVisibility.state(layer: layer, view: view, ancestors: ancestors)
            func inspect(_ animation: CAAnimation, key: String, animationPath: String) {
                if unbounded(animation), !visibility.isVisible {
                    result.append(Finding(scenario: scenario, path: path, key: key, animationPath: animationPath,
                                          hiddenBy: visibility.hiddenBy, time: time))
                }
                for (index, child) in ((animation as? CAAnimationGroup)?.animations ?? []).enumerated() {
                    inspect(child, key: key, animationPath: animationPath + "/\(index)")
                }
            }
            for key in layer.animationKeys() ?? [] {
                if let animation = layer.animation(forKey: key) { inspect(animation, key: key, animationPath: key) }
            }
            if let mask = layer.mask { walk(mask, path: path + "/mask", owner: view, ancestors: ancestors + [layer]) }
            for (index, child) in (layer.sublayers ?? []).enumerated() {
                walk(child, path: path + "/\(child.name ?? String(describing: type(of: child)))[\(index)]", owner: view, ancestors: ancestors)
            }
        }
        for (index, view) in views.enumerated() {
            if let layer = view.layer { walk(layer, path: "\(type(of: view))[\(index)]", owner: view) }
        }
        return result
    }

    static func retainedSatelliteFindings(scale: CGFloat) -> [Finding] {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200)); host.wantsLayer = true
        let orb = OrbComponent(id: "invisible-animation-audit")
        var input = OrbConfiguration(content: .identity(.assigned(0)), drawingSize: 56,
                                     satellites: [.init(id: "retained-moon", face: "S")], backingScale: scale)
        orb.configure(input)
        for view in [orb.backView, orb.glassView, orb.frontView] { host.addSubview(view) }
        var result: [Finding] = []
        func sample(_ name: String) {
            result += findings(in: [host], scenario: "retained-satellite-\(name)-\(Int(scale))x", at: CACurrentMediaTime())
        }
        sample("visible-depth-copy")
        orb.setOpacity(0); sample("Dock-opacity-zero")
        input.satelliteVisibleIDs = []; orb.configure(input); orb.setOpacity(1); sample("visibleIDs")
        input.satelliteVisibleIDs = nil; input.satellitesRetired = true; input.reduceMotion = true
        orb.configure(input); sample("retired")
        orb.dispose()
        return result
    }

    /// Exercise the other production repeat owners as well as the Organic scene. Windows stay unshown;
    /// opacity and hidden state are real NSView/CALayer ancestors, not a fabricated animation fixture.
    static func retainedControlFindings(scale: CGFloat) -> [Finding] {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 120)); host.wantsLayer = true
        window.contentView = host
        let voice = NativeComposerVoiceWaveform(frame: CGRect(x: 10, y: 10, width: 36, height: 30))
        let shortcut = SettingsButton(frame: CGRect(x: 60, y: 10, width: 120, height: 30))
        shortcut.style = .shortcut; shortcut.title = "Record shortcut"
        host.addSubview(voice); host.addSubview(shortcut)
        voice.active = true; shortcut.recordingShortcut = true
        host.layoutSubtreeIfNeeded()
        var result: [Finding] = []
        func sample(_ name: String) {
            result += findings(in: [host], scenario: "retained-controls-\(name)-\(Int(scale))x", at: CACurrentMediaTime())
        }
        host.alphaValue = 0; sample("ancestor-alpha-zero")
        host.alphaValue = 1; host.layer?.opacity = 0; sample("ancestor-layer-opacity-zero")
        host.layer?.opacity = 1; window.alphaValue = 0; sample("window-alpha-zero")
        window.alphaValue = 1; host.isHidden = true; sample("ancestor-hidden")
        voice.active = false; shortcut.recordingShortcut = false
        window.contentView = nil
        return result
    }
}
