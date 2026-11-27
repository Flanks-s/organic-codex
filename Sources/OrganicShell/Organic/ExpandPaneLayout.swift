import AppKit

/// Coordinates are in the flipped parent host. Geometry is independent of the pane's content source.
struct ExpandPaneLayout: Equatable {
    let pane: CGRect
    let anchor: CGPoint
    let moon: CGPoint
    let mouth: CGPoint
    let overlaysParent: Bool

    static func resolve(in host: CGRect, parent: CGRect, selection: CGRect?, scale: CGFloat,
                        onRight preferredSide: Bool? = nil) -> Self {
        let grid = max(1, scale)
        let inset = min(16, min(host.width, host.height) / 4)
        let safe = host.insetBy(dx: inset, dy: inset)
        let gap = CGFloat(18)
        let right = safe.maxX - parent.maxX - gap
        let left = parent.minX - safe.minX - gap
        let onRight = preferredSide ?? (right >= 300 || right >= left)
        let available = onRight ? right : left
        let overlaid = available < 280
        let width = min(350, overlaid ? safe.width : available)
        let height = min(652, safe.height)
        let x = overlaid ? safe.maxX - width : onRight ? parent.maxX + gap : parent.minX - gap - width

        func snap(_ value: CGFloat) -> CGFloat { (value * grid).rounded() / grid }

        let y = min(max(safe.minY, parent.minY), safe.maxY - height)
        let rect = CGRect(x: snap(x), y: snap(y), width: snap(width), height: snap(height))
        let row = selection ?? CGRect(x: parent.midX, y: parent.midY, width: 0, height: 0)
        let nearX = onRight ? parent.maxX : parent.minX
        let anchor = CGPoint(x: snap(min(safe.maxX, max(safe.minX, nearX))),
                             y: snap(min(safe.maxY, max(safe.minY, row.midY))))
        let moon = CGPoint(x: snap(min(safe.maxX - 10, max(safe.minX + 10, nearX))),
                           y: snap(min(safe.maxY - 12, max(safe.minY + 12, anchor.y - 25))))
        let mouth = CGPoint(x: rect.midX, y: rect.minY + min(14, rect.height / 2))
        return .init(pane: rect, anchor: anchor, moon: moon, mouth: mouth, overlaysParent: overlaid)
    }
}
