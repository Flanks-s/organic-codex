import AppKit

/// Window-local presentation only. The scene never owns a browser session or a synthetic conversation.
@MainActor protocol BrowserHostPort: AnyObject {
    func project(members: [Conversation], current: String, scheme: AutoScene.Scheme, size: CGSize,
                 metrics: AutoLayout.Metrics, scale: CGFloat, protected: (AutoLayout, [String])?,
                 hasConstraint: Bool, hasLease: Bool) -> (AutoLayout, [String])?
    func installed(in scene: AutoScene)
    func resized(in scene: AutoScene)
    func committed(in scene: AutoScene, layout: AutoLayout)
    func retire()
}

@MainActor protocol BrowserDockPort: AnyObject {
    func hidesGlass(_ glass: NSGlassEffectView) -> Bool
    func coversMember(_ id: String) -> Bool
    func frame(at time: Double)
}
