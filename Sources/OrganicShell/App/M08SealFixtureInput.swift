import AppKit

#if !M10_DOCK_SELFTEST && !ORGANIC_SELFTEST && !ORB_SELFTEST
#if !ISLAND_SELFTEST && !M9_SPLIT_SELFTEST && !M11_MODE_SELFTEST
/// The baseline helper compiles this same file, so both sides use one fixture recipe.
@MainActor enum M08SealFixtureInput {
    static let width: CGFloat = 1280
    static let clock: Double = 100_000_000
    static let members = ["A", "B", "C", "D", "E", "F"]

    struct Target {
        let id: String
        let header: HeaderIsland?
        let point: CGPoint
    }

    static func make(mode: String) -> OrbInputVerification.Fixture {
        ModelCatalog.models = ModelCatalog.mockModels
        let fixture = OrbInputVerification.Fixture(width: width)
        fixture.time = clock
        fixture.settle()
        let scene = fixture.scene
        if mode != "auto" {
            scene.enterFocused(scene.current, reason: "m08-seal")
            if mode == "split" { scene.graft("B", at: 1, reason: "m08-seal") }
            fixture.settle()
        }
        return fixture
    }

    static func target(scene: AutoScene, entry: String) -> Target? {
        // Dock restingTargets comes from Dictionary.values; never let hash order choose the dragged member.
        let targets = scene.order.compactMap { id in scene.dockTargets.first { $0.id == id } }
        if entry == "orb-peek" {
            guard let item = targets.first(where: { $0.id != DockNode.meID && !$0.bar }) else {
                return nil
            }
            scene.setPeeking(item.id)
            scene.peekNode.setHeaderVisible(true, duration: 0)
            let header = scene.peekNode.header
            let rect = scene.dockView.convert(header.draggableOrbRect, from: header)
            return Target(id: item.id, header: header, point: CGPoint(x: rect.midX, y: rect.midY))
        }
        if entry == "orb-bar" {
            guard let target = targets.first(where: {
                $0.bar && (scene.dock.items[$0.id]?.identityOpacity.to ?? 0) > 0
            }), let item = scene.dock.items[target.id] else { return nil }
            return Target(id: target.id, header: nil,
                          point: CGPoint(x: item.identityFrame.midX, y: item.identityFrame.midY))
        }
        if entry.contains("header") || entry == "orb-full" || entry == "orb-brief" {
            let brief = entry == "orb-brief" || entry == "header-brief"
            guard let column = scene.columns.first(where: {
                ($0.conversation.id != scene.current) == brief
            }), let header = column.island else { return nil }
            let rect = scene.dockView.convert(header.draggableOrbRect, from: header)
            return Target(id: column.conversation.id, header: header,
                          point: CGPoint(x: rect.midX, y: rect.midY))
        }
        if entry == "grip" {
            // Match InputRun's physical bar grip, rather than its resting identity target.
            guard let item = scene.order.compactMap({ scene.dock.items[$0] }).last(where: {
                $0.role == .bar
            }) else { return nil }
            return Target(id: item.conversation.id, header: nil,
                          point: CGPoint(x: item.glass.frame.midX, y: item.glass.frame.minY + 2))
        }
        guard let item = targets.first(where: {
            $0.id != DockNode.meID && $0.bar == (entry == "member")
        }) else { return nil }
        return Target(id: item.id, header: nil,
                      point: CGPoint(x: item.rect.midX, y: item.bar ? item.rect.minY : item.rect.midY))
    }

    static func trajectory(scene: AutoScene, point: CGPoint, edge: String) -> (inside: CGPoint, outside: CGPoint) {
        let outside = edge == "top" ? CGPoint(x: point.x, y: -120)
            : CGPoint(x: scene.size.width + 180, y: point.y)
        return (CGPoint(x: scene.size.width * 0.65, y: point.y), outside)
    }

    static func receipt(fixture: OrbInputVerification.Fixture, target: Target, edge: String) -> [String: Any] {
        let scene = fixture.scene
        let path = trajectory(scene: scene, point: target.point, edge: edge)
        return ["models": ModelCatalog.models.map(\.id), "members": scene.members.map(\.id),
                "current": scene.current, "size": [scene.size.width, scene.size.height], "time": fixture.time,
                "id": target.id, "header": target.header != nil, "releaseAfter": 0.4,
                "press": [target.point.x, target.point.y], "inside": [path.inside.x, path.inside.y],
                "outside": [path.outside.x, path.outside.y]]
    }
}
#endif
#endif
