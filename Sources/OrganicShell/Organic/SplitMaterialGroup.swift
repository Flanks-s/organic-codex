import AppKit
/// The outer host is deliberately outside the native fusion container.
@MainActor final class SplitMaterialGroup {
    let id: String
    let outer: NSView
    let container: NSGlassEffectContainerView
    let content: NSView
    private(set) var members: [ObjectIdentifier: NSGlassEffectView] = [:]
    init(id: String, frame: CGRect) {
        self.id = id
        outer = NSView(frame: frame); outer.wantsLayer = true
        container = NSGlassEffectContainerView(frame: outer.bounds)
        container.spacing = 10
        content = NSView(frame: outer.bounds); content.wantsLayer = true
        container.contentView = content
        outer.addSubview(container)
    }
    init?(id: String, retaining container: NSGlassEffectContainerView, in host: NSView) {
        guard container.superview === host, let content = container.contentView else { return nil }
        self.id = id
        self.outer = host
        self.container = container
        self.content = content
    }
    func register(_ glass: NSGlassEffectView) -> Bool {
        guard container.superview === outer, container.contentView === content,
              glass.superview === content else { return false }
        members[ObjectIdentifier(glass)] = glass
        return true
    }
    func contains(_ glass: NSGlassEffectView) -> Bool {
        container.superview === outer && container.contentView === content
            && glass.superview === content && members[ObjectIdentifier(glass)] === glass
    }
    func bindAtBirth(_ surface: NSGlassEffectView) -> Bool {
        guard surface.superview == nil else { return false }
        if NativeDisplayOptions.shared.state.reducesEffects {
            surface.tintColor = NativeDisplayOptions.plate(alpha: 0.12)
        }
        content.addSubview(surface)
        members[ObjectIdentifier(surface)] = surface
        return true
    }
    /// No motion-time reparenting. This method is only reachable through a settled owner.
    fileprivate func remove(_ surface: NSGlassEffectView) {
        members.removeValue(forKey: ObjectIdentifier(surface))
        surface.removeFromSuperview()
    }
    func retire(_ surface: NSGlassEffectView) -> Bool {
        guard members[ObjectIdentifier(surface)] === surface, surface.superview === content else { return false }
        remove(surface); return surface.superview == nil
    }
    static func transferAtEndpoint(_ surface: NSGlassEffectView, from: SplitMaterialGroup,
                                   to: SplitMaterialGroup, settled: Bool) -> Bool {
        guard settled, from.members[ObjectIdentifier(surface)] === surface,
              from.outer.frame == to.outer.frame else { return false }
        if from === to { return true }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let frame = surface.frame
        from.remove(surface)
        let bound = to.bindAtBirth(surface)
        surface.frame = frame
        CATransaction.commit()
        return bound
    }
}
