import AppKit

/// Spatial alpha affects the compositor's material; child-glass alpha does not.
/// Regions include the exposure margin but must stop at the shared free-space boundary.
@MainActor final class SplitSpatialMaterialMask {
    struct Region {
        let role: String
        let rect: CGRect
        let alpha: Float
    }
    let layer = CALayer()
    private let outside = CAShapeLayer()
    private var islands: [CAShapeLayer] = []
    private var regions: [Region] = []
    private weak var group: SplitMaterialGroup?
    init(group: SplitMaterialGroup) {
        self.group = group
        layer.frame = group.outer.bounds
        outside.frame = layer.bounds; outside.fillColor = NSColor.white.cgColor
        outside.path = CGPath(rect: layer.bounds, transform: nil)
        outside.fillRule = .evenOdd; layer.addSublayer(outside)
        group.outer.layer?.mask = layer
    }
    @discardableResult func apply(_ regions: [Region]) -> Bool {
        guard let group else { return false }
        for (i, region) in regions.enumerated() {
            guard !region.rect.isEmpty, region.alpha.isFinite, (0...1).contains(region.alpha),
                  !regions.dropFirst(i + 1).contains(where: { $0.rect.intersects(region.rect) }) else { return false }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = group.outer.bounds; outside.frame = layer.bounds
        let path = CGMutablePath(); path.addRect(layer.bounds)
        for region in regions { path.addRect(region.rect) }
        outside.path = path
        while islands.count < regions.count {
            let island = CAShapeLayer(); island.fillColor = NSColor.white.cgColor
            layer.addSublayer(island); islands.append(island)
        }
        for (i, island) in islands.enumerated() {
            island.isHidden = i >= regions.count
            if i < regions.count {
                island.frame = layer.bounds
                island.path = CGPath(rect: regions[i].rect, transform: nil)
                island.opacity = regions[i].alpha
            }
        }
        CATransaction.commit()
        self.regions = regions
        return true
    }
    @discardableResult func retire(_ role: String) -> Bool { apply(regions.filter { $0.role != role }) }
    func clear() {
        if group?.outer.layer?.mask === layer { group?.outer.layer?.mask = nil }
    }
}
