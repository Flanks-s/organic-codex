import Foundation
import CoreGraphics

/// A value certificate for one explicit pair; it publishes nothing while being inspected or prepared.
enum SplitPresentationLayout {
    static let version = 1
    static let minimumInput: CGFloat = 220
    struct Plan {
        let source: OrganicMemberLayout
        var split: [String]
        var right: [String]
        var current: String
        let size: CGSize
        let metrics: AutoLayout.Metrics
        var presentationVersion = version
        var isValid: Bool {
            let all = split + right
            return source.isValid && presentationVersion == version && (1...2).contains(split.count)
                && size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
                && split.contains(current) && all.count == source.members.count && Set(all).count == all.count
                && Set(all) == Set(source.members.map(\.id))
                && split.allSatisfy { id in
                    source.members.contains { $0.id == id && !$0.archived && $0.draft == .none }
                }
        }
    }
    static func geometry(size: CGSize, bankCount: Int, metrics m: AutoLayout.Metrics) -> AutoLayout? {
        guard size.width.isFinite, size.height.isFinite, bankCount >= 0 else { return nil }
        let half = size.width / 2
        let gap = max(CGFloat(12), m.gap)
        let middle = max(m.inset, (m.me + 24) / 2)
        let step = m.orb + max(CGFloat(12), m.orbGap)
        let bankWidth = bankCount == 0 ? 0 : CGFloat(bankCount) * step - max(CGFloat(12), m.orbGap)
        let y = size.height - m.bottomInset - m.barHeight
        let leftX = m.inset + m.me + gap
        let rightEnd = size.width - m.inset - (bankCount == 0 ? 0 : bankWidth + max(CGFloat(12), m.orbGap))
        let left = CGRect(x: leftX, y: y, width: half - middle - leftX, height: m.barHeight)
        let right = CGRect(x: half + middle, y: y, width: rightEnd - half - middle, height: m.barHeight)
        guard left.width >= minimumInput, right.width >= minimumInput, right.minX - left.maxX >= 12,
              y > m.topInset + m.dockGap else { return nil }
        var result = AutoLayout()
        result.focused = true
        result.separateInputs = true
        result.capacity = 2
        result.columns = [0, half].map { x in
            CGRect(x: x, y: m.topInset, width: half, height: y - m.dockGap - m.topInset)
        }
        result.bars = [left, right]
        result.me = CGRect(x: m.inset, y: y + (m.barHeight - m.me) / 2, width: m.me, height: m.me)
        result.orbs = (0..<bankCount).map { i in
            CGRect(x: size.width - m.inset - bankWidth + CGFloat(i) * step,
                   y: y + (m.barHeight - m.orb) / 2, width: m.orb, height: m.orb)
        }
        return result
    }
    static func makeSplit(receiving: String, incoming: String, layout: OrganicMemberLayout,
                          size: CGSize, metrics: AutoLayout.Metrics, restoring: Bool = false) -> Plan? {
        guard layout.isValid, receiving != incoming,
              [receiving, incoming].allSatisfy({ id in
                  layout.members.contains { $0.id == id && !$0.archived && $0.draft == .none }
              }), restoring || layout.mode != .focused || !layout.columns.map(\.member).contains(incoming),
              geometry(size: size, bankCount: layout.members.count - 2, metrics: metrics) != nil else { return nil }
        let pair = [receiving, incoming]
        let displaced = layout.columns.map(\.member).filter { !pair.contains($0) }
        let bank = Array(layout.left.reversed()) + layout.parked + layout.right
        return Plan(source: layout, split: pair, right: displaced + bank.filter { !pair.contains($0) },
                    current: receiving, size: size, metrics: metrics)
    }
    static func next(receiving: String, screen: [String], layout: OrganicMemberLayout) -> String? {
        guard !(layout.mode == .focused && layout.columns.count >= 2),
              let i = screen.firstIndex(of: receiving) else { return nil }
        return i + 1 < screen.count ? screen[i + 1] : (i > 0 ? screen[i - 1] : nil)
    }
    static func restored(split saved: [String], current: String, focus: String?, left: [String]?, right: [String]?,
                         layout: OrganicMemberLayout, size: CGSize, metrics: AutoLayout.Metrics) -> Plan? {
        let ids = layout.members.filter { !$0.archived && $0.draft == .none }.map(\.id)
        var seen = Set<String>()
        let old = saved.filter { ids.contains($0) && seen.insert($0).inserted }
        guard !old.isEmpty else { return nil }
        let selected = old.contains(current) ? current : old[0]
        let i = old.firstIndex(of: selected)!
        let j = i + 1 < old.count ? i + 1 : max(0, i - 1)
        let pair = old.count <= 2 ? old : [old[min(i, j)], old[max(i, j)]]
        let bank = left != nil || right != nil ? Array((left ?? []).reversed()) + (right ?? []) : []
        let order = old.filter { !pair.contains($0) } + bank + layout.members.map(\.id)
        seen = Set(pair)
        let rest = order.filter { ids.contains($0) && seen.insert($0).inserted }
        if pair.count == 2, geometry(size: size, bankCount: rest.count, metrics: metrics) != nil {
            return Plan(source: layout, split: pair, right: rest, current: selected, size: size, metrics: metrics)
        }
        let keep = focus.flatMap { pair.contains($0) ? $0 : nil } ?? selected
        return Plan(source: layout, split: [keep], right: pair.filter { $0 != keep } + rest,
                    current: keep, size: size, metrics: metrics)
    }
}
