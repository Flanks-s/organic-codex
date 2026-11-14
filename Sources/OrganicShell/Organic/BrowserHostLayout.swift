import AppKit

/// A numeric trailing rail, outside conversation membership and the Tide/add lease namespace.
struct BrowserHostLayout {
    let layout: AutoLayout
    let order: [String]
    let dock: CGRect

    @MainActor static func make(ids: [String], current: String, scheme: AutoScene.Scheme, size: CGSize,
                     metrics: AutoLayout.Metrics, scale: CGFloat, hasConstraint: Bool, hasLease: Bool) -> Self? {
        guard scheme.mode == .auto, !scheme.draft, scheme.parked.isEmpty, !hasConstraint, !hasLease,
              !ids.isEmpty, ids.contains(current), size.width >= 640, size.height >= 520 else { return nil }
        let rail: CGFloat = 58
        let available = CGSize(width: size.width - rail, height: size.height)
        var n = AutoLayout(size: available, count: ids.count, fullIndex: 0, metrics: metrics).columns.count
        var order = ids, layout = AutoLayout()
        for _ in 0..<2 {
            order = AutoScene.displayOrder(ids, current: current, columns: n)
            layout = AutoLayout(size: available, count: ids.count, fullIndex: order.firstIndex(of: current), metrics: metrics)
            if layout.columns.count == n { break }
            n = layout.columns.count
        }
        guard let full = layout.columns.indices.first(where: { order[$0] == current }),
              layout.columns[full].width >= 340 else { return nil }
        func snap(_ r: CGRect) -> CGRect {
            let a = CGPoint(x: (r.minX*scale).rounded()/scale, y: (r.minY*scale).rounded()/scale)
            return CGRect(x: a.x, y: a.y, width: (r.maxX*scale).rounded()/scale-a.x, height: (r.maxY*scale).rounded()/scale-a.y)
        }
        layout.columns = layout.columns.map(snap); layout.bars = layout.bars.map(snap)
        let dock = snap(CGRect(x: size.width-metrics.inset-32, y: layout.me.midY-16, width: 32, height: 32))
        return .init(layout: layout, order: order, dock: dock)
    }
}
