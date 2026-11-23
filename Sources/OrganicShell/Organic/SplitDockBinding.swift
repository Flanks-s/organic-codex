import AppKit

/// References are exported by the real host; this contract never mounts or copies paint.
@MainActor final class SplitDockBinding {
    /// The provider exports its actual Part object and leaf, never a freshly rendered substitute.
    struct Part {
        let instance: AnyObject
        let source: NSView
        let paint: CALayer
    }
    enum Paint {
        case native(NativeComposer)
        case part(Part)
        var source: NSView {
            switch self {
            case .native(let view): return view
            case .part(let part): return part.source
            }
        }
    }
    let role: SplitPresentationRole
    let glass: NSGlassEffectView
    let paint: Paint
    let inkHost: NSView
    let orb: OrbComponent
    let root: NSView
    private var parents: [[ObjectIdentifier]] = []
    private var views: [NSView] { [glass, paint.source, inkHost, orb.glassView, orb.frontView, orb.backView, root] }
    init?(role: SplitPresentationRole, glass: NSGlassEffectView, paint: Paint,
          inkHost: NSView, orb: OrbComponent, root: NSView) {
        self.role = role
        self.glass = glass
        self.paint = paint
        self.inkHost = inkHost
        self.orb = orb
        self.root = root
        parents = tree()
        guard validates() else {
            return nil
        }
    }
    private static func path(_ object: AnyObject) -> [ObjectIdentifier] {
        var result: [ObjectIdentifier] = []
        var next: AnyObject? = object
        while let current = next {
            result.append(ObjectIdentifier(current))
            if let view = current as? NSView {
                next = view.superview
            } else {
                next = (current as? CALayer)?.superlayer
            }
        }
        return result
    }
    private func tree() -> [[ObjectIdentifier]] {
        var result = views.map { Self.path($0) }
        if case .part(let part) = paint {
            result.append(Self.path(part.paint))
        }
        return result
    }
    func validates() -> Bool {
        guard let window = root.window, glass.window === window,
              paint.source.isDescendant(of: inkHost), tree() == parents,
              views.allSatisfy({ $0 === root || $0.isDescendant(of: root) }) else {
            return false
        }
        if case .part(let part) = paint {
            guard let layer = root.layer, Self.path(part.paint).contains(ObjectIdentifier(layer)) else {
                return false
            }
        }
        return true
    }
    /// An unheld binding returns before reading poses and never writes a view or layer property.
    func sample(token: SplitPaintLease.Token,
                registry: SplitPresentationRoles) -> (glass: CGRect, ink: CGRect)? {
        guard registry.holds(role, token: token), token.holder == ObjectIdentifier(self), validates() else {
            return nil
        }
        let ink: CGRect
        switch paint {
        case .native(let native):
            ink = native.convert(native.bounds, to: root)
        case .part(let part):
            guard let layer = root.layer else {
                return nil
            }
            ink = layer.convert(part.paint.bounds, from: part.paint)
        }
        return (glass.convert(glass.bounds, to: root), ink)
    }
}
