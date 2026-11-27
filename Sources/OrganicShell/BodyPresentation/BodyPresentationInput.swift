import AppKit

/// LL and center use the same top-down coordinate space. No clock or event serial belongs in this input.
struct BodyPresentationInput: Equatable {
    var bodyID: String
    var outer: CGFloat
    var scale: Int
    var ll: CGPoint
    var center: CGPoint
    var unknown = false
    var visible = true
    var keyWindow = true
    var rasterOuter: CGFloat? = nil
    var degrees: Float { Float(atan2(center.y - ll.y, ll.x - center.x) * 180 / .pi) }
    var bin: Int { BodyProfile.current.quantizedDirection(degrees).index }
    /// Choose once from the host's maximum drawing extent, never from its animated frame.
    var tier: Int { [16,22,26,32,36,44,48,56,64].first { CGFloat($0)>=min(64,max(outer,rasterOuter ?? outer)) } ?? 64 }
    var groupKey: String { "\(bodyID)-d\(tier)-s\(scale)-u\(unknown ? 1:0)" }
    var spriteKey: String { "\(bodyID)-d\(tier)-s\(scale)-l\(bin)-u\(unknown ? 1:0)" }
}

/// One weak anchor per scene tree. Conversion through the common root also works for detached test trees.
@MainActor final class BodyLightRegistry {
    static let shared = BodyLightRegistry()
    private final class Anchor {
        weak var owner: AnyObject?
        weak var view: NSView?
        weak var tree: NSView?
        var point: CGPoint
        var worldPoint: CGPoint
        init(owner: AnyObject, view: NSView, point: CGPoint, tree: NSView, worldPoint: CGPoint) { self.owner=owner; self.view=view; self.point=point; self.tree=tree; self.worldPoint=worldPoint }
    }
    private final class Listener {
        weak var leaf: BodyPresentationLeaf?
        init(_ leaf: BodyPresentationLeaf) { self.leaf=leaf }
    }
    private var anchors: [Anchor] = []
    private var listeners: [Listener] = []
    func register(_ leaf: BodyPresentationLeaf) { listeners.append(Listener(leaf)) }
    func remove(_ owner: AnyObject) {
        anchors.removeAll { $0.owner == nil || $0.owner === owner }
        listeners.removeAll { $0.leaf == nil || $0.leaf === owner }
    }
    private func root(_ view: NSView) -> NSView {
        var root=view
        while let parent=root.superview { root=parent }
        return root
    }
    func setAnchor(owner: AnyObject, view: NSView, point: CGPoint) {
        let tree=root(view),worldPoint=root(view).convert(point,from:view)
        anchors.removeAll { $0.owner == nil || $0.view == nil }
        if let old=anchors.first(where: { $0.owner === owner }) {
            guard old.view !== view || old.point != point || old.tree !== tree || old.worldPoint != worldPoint else { return }
            old.view=view; old.point=point; old.tree=tree; old.worldPoint=worldPoint
        } else { anchors.append(Anchor(owner:owner,view:view,point:point,tree:tree,worldPoint:worldPoint)) }
        listeners.removeAll { $0.leaf == nil }
        for item in listeners { item.leaf?.refreshLight() }
    }
    func coordinates(view: NSView, center: CGPoint) -> (ll: CGPoint, center: CGPoint) {
        let tree=root(view)
        func down(_ point: CGPoint, from source: NSView) -> CGPoint {
            let p=tree.convert(point,from:source)
            return tree.isFlipped ? p : CGPoint(x:p.x,y:tree.bounds.maxY-p.y)
        }
        let center=down(center,from:view)
        if let anchor=anchors.last(where: { $0.view.map { root($0) === tree } == true }),let source=anchor.view {
            return (down(anchor.point,from:source),center)
        }
        // Detached proxies have no LL. A canonical direction keeps equivalent offscreen endpoints identical.
        return (CGPoint(x:center.x-1,y:center.y-1),center)
    }
}
