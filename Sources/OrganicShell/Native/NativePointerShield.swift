import AppKit

/// Tracking areas do not follow hit-test occlusion. A scene supplies one shield for both paths.
@MainActor protocol NativePointerHoverClient: AnyObject {
    func reconcilePointerHover(_ point: CGPoint?)
}

@MainActor final class NativePointerShield {
    private static let shields = NSHashTable<NativePointerShield>.weakObjects()
    weak var plane: NSView?
    private let scopes = NSHashTable<NSView>.weakObjects()
    var contains: (CGPoint) -> Bool = { _ in false }
    var pointer: () -> CGPoint? = { nil }
    private var wasCovered = false

    init(plane: NSView) { self.plane = plane; Self.shields.add(self) }
    func setScopes(_ views: [NSView]) { scopes.removeAllObjects(); views.forEach { scopes.add($0) } }
    private func owns(_ view: NSView) -> Bool {
        scopes.allObjects.contains { view === $0 || view.isDescendant(of: $0) }
    }
    static func permits(_ view: NSView, localPoint: CGPoint? = nil) -> Bool {
        for shield in shields.allObjects where shield.owns(view) {
            guard let plane = shield.plane else { continue }
            let p = localPoint.map { plane.convert($0, from: view) } ?? shield.pointer()
            if let p, shield.contains(p) { return false }
        }
        return true
    }
    /// Reconcile on a coverage edge, including a stationary pointer when Peek opens or closes.
    func reconcile(force: Bool = false) {
        guard let plane else { return }
        let p = pointer(), covered = p.map(contains) ?? false
        guard force || covered != wasCovered else { return }
        wasCovered = covered
        func visit(_ view: NSView) {
            if let client = view as? any NativePointerHoverClient {
                let local = p.map { view.convert($0, from: plane) }
                let inside = !view.isHiddenOrHasHiddenAncestor && local.map { view.visibleRect.contains($0) } == true
                client.reconcilePointerHover(inside && !covered ? local : nil)
            }
            view.subviews.forEach(visit)
        }
        scopes.allObjects.forEach(visit)
    }
}
