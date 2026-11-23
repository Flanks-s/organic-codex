import Foundation

struct FunctionPanelGeometry {
    static let stageWidth: CGFloat = 598
    static let panel = CGRect(x: 66, y: 264, width: 491, height: 464)
    static let leftStations: [CGFloat] = [46, 80, 114, 148, 182]
    static let bodyPitch: CGFloat = 21
    static let bodySlots = 8
    static let titleLimits: ClosedRange<CGFloat> = 112...320
    let origin: CGPoint
    let viewport: CGRect

    init(viewport: CGRect, column: CGRect) {
        self.viewport = viewport
        origin = CGPoint(x: min(max(viewport.minX, column.midX - Self.stageWidth / 2),
                                max(viewport.minX, viewport.maxX - Self.stageWidth)), y: viewport.minY)
    }
    func placed(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: origin.x, dy: origin.y) }
    static func leftX(_ y: CGFloat) -> CGFloat { arcX(y, rx: 115, ry: 170, left: true) }
    static func rightX(_ y: CGFloat) -> CGFloat { arcX(y, rx: 140, ry: 190, left: false) }
    private static func arcX(_ y: CGFloat, rx: CGFloat, ry: CGFloat, left: Bool) -> CGFloat {
        let k = (y - 130) / ry
        return 170 + (left ? -1 : 1) * rx * sqrt(max(0, 1 - k * k))
    }
    static func orb(_ progress: Double) -> CGRect {
        let p = CGFloat(progress), diameter = 56 + 94 * p
        let center = 311.5 + (170 - 311.5) * p
        return CGRect(x: center - diameter / 2, y: 52 - 12 * p, width: diameter, height: diameter)
    }
    static func titleWidth(_ title: String, measured: CGFloat) -> CGFloat {
        min(titleLimits.upperBound, max(titleLimits.lowerBound, 188 + measured))
    }
    static func title(width: CGFloat, progress: Double) -> CGRect {
        let p = CGFloat(progress), center = 311 + (170 - 311) * p
        return CGRect(x: center - width / 2, y: 104 + 82 * p, width: width, height: 32)
    }
    static func paneHeight(_ page: FunctionPanelPage, covers: Int = 9, selectedCover: Bool = false) -> CGFloat {
        switch page {
        case .overview: 252
        case .library: min(464, selectedCover ? 208 + CGFloat(Int(ceil(Double(max(0, covers - 1)) / 2))) * 28 + 12
                                           : 44 + CGFloat(max(1, Int(ceil(Double(covers) / 3)))) * 113 + 6)
        case .files: 456
        case .background: 64
        case .outputs: 350
        }
    }
    static func chips(page: FunctionPanelPage, hover: FunctionPanelPage?) -> [(FunctionPanelPage, CGRect)] {
        let others = FunctionPanelPage.navigation.filter { $0 != page }
        let widths: [CGFloat] = others.map { $0 == .overview ? 88 : $0 == hover ? $0.expandedWidth : 26 }
        var x = 170 - (widths.reduce(0, +) + CGFloat(max(0, others.count - 1)) * 8) / 2
        return zip(others, widths).map { item, width in
            defer { x += width + 8 }
            return (item, CGRect(x: x, y: 228, width: width, height: 26))
        }
    }
    struct BodySlot {
        let index: Int
        let frame: CGRect
        let clipped: Bool
    }
    static func bodySlots(count: Int, offset: Int) -> [BodySlot] {
        let start = min(max(0, offset), max(0, count - bodySlots))
        return (max(0, start - 1)..<min(count, start + bodySlots + 1)).map { index in
            let fringe = index < start || index >= start + bodySlots
            let diameter: CGFloat = fringe ? 9 : 22
            let y = 48 + CGFloat(index - start) * bodyPitch
            return BodySlot(index: index, frame: CGRect(x: leftX(y) - diameter / 2, y: y - diameter / 2,
                                                       width: diameter, height: diameter), clipped: fringe)
        }.filter { $0.frame.minY >= 32 }
    }
    static func librarySlot(index: Int, selected: Bool, tile: Bool, tileIndex: Int) -> CGRect {
        if selected { return CGRect(x: 16, y: 44, width: 260, height: 150) }
        if tile { return CGRect(x: 16 + CGFloat(tileIndex % 2) * 236, y: 208 + CGFloat(tileIndex / 2) * 28, width: 35.1,
                height: 20.25) }
        return CGRect(x: 16 + CGFloat(index % 3) * 157.3, y: 44 + CGFloat(index / 3) * 113, width: 144.3, height: 83.25)
    }
    static func fileCard(index: Int, selected: Int, count: Int) -> (CGRect, CGFloat) {
        let depth = selected - index
        let y: CGFloat = index <= selected ? 28 + CGFloat(index) * 26 : 450 - CGFloat(count - index) * 26
        return (CGRect(x: 34 - CGFloat(max(0, depth)) * 2, y: y, width: 423, height: 266),
                depth > 0 ? -1.2 * CGFloat(depth) : -0.5 * CGFloat(depth))
    }
    static func outputCard(index: Int, selected: Int) -> CGRect {
        let x = 245.5 - 108 + CGFloat(index - selected) * 232
        let rect = CGRect(x: x, y: 16, width: 216, height: 272)
        return index == selected ? rect : CGRect(x: x + 10.8, y: 43.2, width: 194.4, height: 244.8)
    }
    static func outputRadius(selected: Bool) -> CGFloat { selected ? 12 : 10.8 }
    static func finishedTaskBack(index: Int, y: CGFloat) -> CGRect {
        CGRect(x: 88, y: y + CGFloat(min(index, 2)) * 6, width: 447, height: 36)
    }
    static func subagentBlocks(count: Int, expanded: Int?) -> [CGRect] {
        var y: CGFloat = expanded == nil ? 16 : 8
        return (0..<count).map { index in
            let height: CGFloat = expanded == nil ? 72 : expanded == index ? 192 : 22
            let frame = CGRect(x: rightX(y + height / 2) - 16, y: y, width: 284, height: height)
            y += height + (expanded == nil ? 6 : 5)
            return frame
        }
    }
}
