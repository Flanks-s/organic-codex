import AppKit
import QuartzCore

/// Visibility over an animation cycle, rather than the opacity at a single front/back handoff.
@MainActor enum OrbAnimationVisibility {
    static func animations(_ layer: CALayer, property: String) -> [CAPropertyAnimation] {
        func collect(_ animation: CAAnimation) -> [CAPropertyAnimation] {
            if let group = animation as? CAAnimationGroup { return (group.animations ?? []).flatMap(collect) }
            guard let propertyAnimation = animation as? CAPropertyAnimation,
                  propertyAnimation.keyPath == property else { return [] }
            return [propertyAnimation]
        }
        return (layer.animationKeys() ?? []).flatMap { key in layer.animation(forKey: key).map(collect) ?? [] }
    }

    static func maximum(_ model: Double, animations: [CAPropertyAnimation]) -> Double {
        var replacements: [Double] = [], additions: [Double] = []
        for animation in animations {
            let values: [Double]
            if let keyframe = animation as? CAKeyframeAnimation {
                values = (keyframe.values ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            } else if let basic = animation as? CABasicAnimation {
                let from = (basic.fromValue as? NSNumber)?.doubleValue
                let to = (basic.toValue as? NSNumber)?.doubleValue
                let by = (basic.byValue as? NSNumber)?.doubleValue
                let start = from ?? (to.flatMap { end in by.map { end - $0 } } ?? (basic.isAdditive ? 0 : model))
                let end = to ?? by.map { start + $0 } ?? model
                values = [start, end]
            } else { continue }
            guard let maximum = values.max() else { continue }
            if animation.isAdditive { additions.append(maximum) } else { replacements.append(maximum) }
        }
        return min(1, max(0, (replacements.max() ?? model) + additions.reduce(0, +)))
    }

    struct State {
        var maximumOpacity = 1.0
        var hiddenBy: [String] = []
        var isVisible: Bool { maximumOpacity >= 0.01 && hiddenBy.isEmpty }
    }

    static func state(layer: CALayer?, view: NSView?, ancestors: [CALayer] = [], includesAnimations: Bool = true) -> State {
        var result = State(), seenLayers = Set<ObjectIdentifier>()
        func animations(_ layer: CALayer, property: String) -> [CAPropertyAnimation] {
            includesAnimations ? Self.animations(layer, property: property) : []
        }
        func includeLayers(_ layer: CALayer?) {
            var currentLayer = layer
            while let current = currentLayer {
                guard seenLayers.insert(ObjectIdentifier(current)).inserted else { break }
                let name = current.name ?? String(describing: type(of: current))
                result.maximumOpacity *= maximum(Double(current.opacity), animations: animations(current, property: "opacity"))
                if current.isHidden && animations(current, property: "hidden").isEmpty { result.hiddenBy.append(name + ".isHidden") }
                currentLayer = current.superlayer
            }
        }
        includeLayers(layer)
        for ancestor in ancestors { includeLayers(ancestor) }
        var currentView = view
        while let current = currentView {
            // AppKit can defer connecting a backing layer until commit; the NSView ancestry already exists.
            includeLayers(current.layer)
            let opacity = current.layer.map { animations($0, property: "opacity") + animations($0, property: "alphaValue") } ?? []
            result.maximumOpacity *= maximum(Double(current.alphaValue), animations: opacity)
            if current.isHidden && (current.layer.map { animations($0, property: "hidden").isEmpty } ?? true) {
                result.hiddenBy.append(String(describing: type(of: current)) + ".isHidden")
            }
            currentView = current.superview
        }
        if let window = view?.window {
            // AppKit's window alpha is a separate compositor multiplier, not its content layer opacity.
            let opacity = window.contentView?.superview?.layer.map { animations($0, property: "alphaValue") } ?? []
            result.maximumOpacity *= maximum(Double(window.alphaValue), animations: opacity)
        }
        if result.maximumOpacity < 0.01 { result.hiddenBy.append("maximumOpacityProduct=\(result.maximumOpacity)<0.01") }
        result.hiddenBy = Array(Set(result.hiddenBy)).sorted()
        return result
    }

    /// Only removable, finite transitions have an end to wait for. The outer group's clock owns removal.
    static func completionDelay(layer: CALayer, at now: CFTimeInterval) -> CFTimeInterval? {
        func affectsVisibility(_ animation: CAAnimation) -> Bool {
            if let group = animation as? CAAnimationGroup { return (group.animations ?? []).contains(where: affectsVisibility) }
            return ["opacity", "alphaValue", "hidden"].contains((animation as? CAPropertyAnimation)?.keyPath ?? "")
        }
        let localNow = layer.convertTime(now, from: nil)
        let rate = layer.convertTime(now + 1, from: nil) - localNow
        guard rate.isFinite && rate > 0 else { return nil } // A paused layer has no wall-clock deadline.
        return (layer.animationKeys() ?? []).compactMap { key -> CFTimeInterval? in
            guard let animation = layer.animation(forKey: key), affectsVisibility(animation),
                  animation.isRemovedOnCompletion, animation.speed != 0,
                  animation.repeatCount < .greatestFiniteMagnitude else { return nil }
            let cycle = animation.duration * (animation.autoreverses ? 2 : 1)
            let duration = animation.repeatDuration > 0 ? animation.repeatDuration : cycle * (animation.repeatCount > 0 ? Double(animation.repeatCount) : 1)
            guard duration.isFinite && duration > 0 else { return nil }
            // Until commit resolves the implicit-begin sentinel, only the attachment is trustworthy.
            guard animation.beginTime != 0 else { return 1 / 60 }
            let end = animation.speed > 0 ? duration : 0
            let remaining = (animation.beginTime + (end - animation.timeOffset) / Double(animation.speed) - localNow) / rate
            guard remaining.isFinite && remaining < Double(Int.max) / 1e9 - 1 else { return nil }
            // A late commit/removal can outlive its nominal end. Re-arm only while it remains attached.
            return max(0, remaining) + 1 / 60
        }.min()
    }
}

/// Observe retained native controls without a display link or an idle polling timer.
/// The owner rebinds after mounting; KVO covers view, backing-layer and window visibility changes.
@MainActor final class OrbAnimationVisibilityObservation {
    private var observations: [NSKeyValueObservation] = []
    private weak var view: NSView?
    private let changed: () -> Void
    private var completionRefresh: DispatchWorkItem?
    private var refreshQueued = false
    init(view: NSView, changed: @escaping () -> Void) { self.view = view; self.changed = changed }
    private func notifyChange() {
        let context = NSAnimationContext.current
        guard context.allowsImplicitAnimation else { changed(); return }
        // AppKit sets the model before installing its fade. Inspect after installation, then after its duration.
        // Do not replace AppKit's completion handler or alter the parent's animation.
        if !refreshQueued {
            refreshQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.refreshQueued = false; self.changed()
            }
        }
        scheduleCompletionRefresh(after: max(0, context.duration) + 1 / 60)
    }
    private func scheduleCompletionRefresh(after delay: CFTimeInterval) {
        completionRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshAfterAnimation() } }
        completionRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: refresh)
    }
    private func refreshAfterAnimation() {
        completionRefresh = nil
        changed()
        guard isObserving, let view,
              OrbAnimationVisibility.state(layer: view.layer, view: view).isVisible,
              !OrbAnimationVisibility.state(layer: view.layer, view: view, includesAnimations: false).isVisible else { return }
        var layers: [CALayer] = [], seen = Set<ObjectIdentifier>(), current: NSView? = view
        func includeLayers(_ layer: CALayer?) {
            var next = layer
            while let layer = next, seen.insert(ObjectIdentifier(layer)).inserted {
                layers.append(layer); next = layer.superlayer
            }
        }
        while let ancestor = current { includeLayers(ancestor.layer); current = ancestor.superview }
        includeLayers(view.window?.contentView?.superview?.layer)
        let now = CACurrentMediaTime()
        if let delay = layers.compactMap({ OrbAnimationVisibility.completionDelay(layer: $0, at: now) }).min() {
            scheduleCompletionRefresh(after: delay)
        }
    }
    var isObserving: Bool { !observations.isEmpty }
    func stop() { observations.removeAll(); completionRefresh?.cancel(); completionRefresh = nil }
    func rebind() {
        observations.removeAll()
        var current = view, seen = Set<ObjectIdentifier>()
        func observeLayer(_ layer: CALayer) {
            guard seen.insert(ObjectIdentifier(layer)).inserted else { return }
            observations.append(layer.observe(\.opacity, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            })
            observations.append(layer.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            })
        }
        while let ancestor = current {
            observations.append(ancestor.observe(\.superview, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.rebind(); self?.changed() }
            })
            observations.append(ancestor.observe(\.layer, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.rebind(); self?.changed() }
            })
            observations.append(ancestor.observe(\.alphaValue, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            })
            observations.append(ancestor.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            })
            var layer = ancestor.layer
            while let next = layer { observeLayer(next); layer = next.superlayer }
            current = ancestor.superview
        }
        if let window = view?.window {
            observations.append(window.observe(\.alphaValue, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            })
        }
    }
}
