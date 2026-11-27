import AppKit

/// The island owns hit testing; the scene owns queue order, Tear, haptics and the display-link clock.
/// Keeping this protocol in Island lets windowless/component hosts use the header without Organic.
@MainActor protocol IslandOrbDragGesture: AnyObject {
    func dragged(with event: NSEvent)
    func released(with event: NSEvent)
    func cancel()
}

@MainActor protocol IslandOrbDragProvider: AnyObject {
    func routeOrbInput(from island: HeaderIsland, event: NSEvent) -> Bool
    func beginOrbDrag(from island: HeaderIsland, event: NSEvent) -> (any IslandOrbDragGesture)?
    @discardableResult func cancelOrbDrag() -> Bool
    func prepareOrbDrag(from island:HeaderIsland)
}
extension IslandOrbDragProvider {
    func routeOrbInput(from island: HeaderIsland, event: NSEvent) -> Bool { false }
    @discardableResult func cancelOrbDrag()->Bool { false }
    func prepareOrbDrag(from island:HeaderIsland) {}
}

extension HeaderIsland {
    /// Search only the closest shared canvas, never other windows or a process-global scene registry.
    func orbDragProvider() -> (any IslandOrbDragProvider)? {
        var ancestor = superview
        while let parent = ancestor {
            for sibling in parent.subviews {
                if let provider = sibling as? any IslandOrbDragProvider { return provider }
            }
            ancestor = parent.superview
        }
        return nil
    }
}
