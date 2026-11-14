import AppKit

enum OrbMenuAction: Int, CaseIterable {
    case swap, focused, peek, rename, customize, sidechat, fork, archive, remove
    var title: String { ["Swap into Column", "Open in Focused", "Peek", "Rename…", "Customize…", "New Sidechat", "Fork", "Archive", "Remove from Organic"][rawValue] }
    var enabled: Bool { self != .sidechat }
}

/// Scheduling is independent of AppKit tracking loops, so cancellation also cancels a pending blink.
@MainActor final class OrbContextMenuState {
    static let navigationKeys: Set<UInt16> = [36,76,49,48,53,123,124,125,126]
    struct Column { let id: String, name: String; let checked: Bool }
    let clock: any OverlayClock
    var changed: (() -> Void)?
    var execute: ((OrbMenuAction, String?) -> Void)?
    var permits: ((OrbMenuAction)->Bool)?
    func enabled(_ action:OrbMenuAction)->Bool { action.enabled && (permits?(action) ?? true) }
    private(set) var isOpen = false, submenu = false, blinking = false, highlightVisible = true
    private(set) var selected: Int?, selectedColumn: Int?
    private(set) var columns: [Column] = []
    private(set) var openedAt = 0.0
    private(set) var generation = 0
    private var dwell: OverlayCancellation?, blink: OverlayCancellation?, protection: OverlayCancellation?
    private var protecting = false
    init(clock: any OverlayClock = OverlaySystemClock()) { self.clock = clock }
    var acceptsInput: Bool { isOpen && !blinking && clock.now - openedAt >= 0.05 - 1e-9 }
    func open(columns: [Column]) {
        dismiss(); generation += 1; self.columns = columns; isOpen = true; openedAt = clock.now
        selected = nil; selectedColumn = nil; submenu = false; highlightVisible = true; changed?()
    }
    func dismiss() {
        generation += 1; dwell?.cancel(); blink?.cancel(); protection?.cancel()
        dwell = nil; blink = nil; protection = nil; protecting = false
        isOpen = false; submenu = false; blinking = false; selected = nil; selectedColumn = nil; changed?()
    }
    func hover(row: Int?, column: Int? = nil, towardSubmenu: Bool = false) {
        guard acceptsInput else { return }
        let row = row.flatMap { OrbMenuAction(rawValue: $0).map(enabled) == true ? $0 : nil }
        if towardSubmenu, submenu, column == nil {
            if protecting { return }
            protecting = true
            let token = generation
            protection = clock.schedule(after: 0.3) { [weak self] in
                guard let self, self.generation == token else { return }
                self.protecting = false; self.submenu = false; self.selected = row; self.selectedColumn = nil; self.changed?()
            }
            return
        }
        protection?.cancel(); protection = nil; protecting = false
        if let column {
            selectedColumn = columns.indices.contains(column) && !columns[column].checked ? column : nil
            changed?(); return
        }
        if selected == row { return }
        dwell?.cancel(); selectedColumn = nil; selected = row
        if row == 0 {
            let token = generation
            dwell = clock.schedule(after: 0.12) { [weak self] in
                guard let self, self.generation == token, self.selected == 0 else { return }
                self.submenu = true; self.changed?()
            }
        } else { submenu = false }
        changed?()
    }
    func key(_ code: UInt16) {
        guard isOpen else { return }
        if code == 53 { dismiss(); return }
        if code == 48 { return }
        guard acceptsInput else { return }
        switch code {
        case 125, 126:
            let step = code == 125 ? 1 : -1
            if submenu {
                let choices = columns.indices.filter { !columns[$0].checked }
                selectedColumn = Self.next(selectedColumn, choices: choices, step: step)
            } else {
                let choices = OrbMenuAction.allCases.filter(enabled).map(\.rawValue)
                selected = Self.next(selected, choices: choices, step: step)
            }
            changed?()
        case 124:
            if selected == 0 { dwell?.cancel(); submenu = true; selectedColumn = columns.indices.first { !columns[$0].checked }; changed?() }
        case 123: submenu = false; selectedColumn = nil; changed?()
        case 36, 76, 49: choose()
        default: break
        }
    }
    private static func next(_ value: Int?, choices: [Int], step: Int) -> Int? {
        guard !choices.isEmpty else { return nil }
        guard let value, let index = choices.firstIndex(of: value) else { return step > 0 ? choices.first : choices.last }
        return choices[(index + step + choices.count) % choices.count]
    }
    func choose(rightRelease: Bool = false) {
        guard acceptsInput, !rightRelease || clock.now - openedAt >= 0.180 - 1e-9 else { return }
        let action: OrbMenuAction, column: String?
        if submenu {
            guard let i = selectedColumn, columns.indices.contains(i), !columns[i].checked else { return }
            action = .swap; column = columns[i].id
        } else {
            guard let selected, let item = OrbMenuAction(rawValue: selected), enabled(item) else { return }
            if item == .swap { key(124); return }
            action = item; column = nil
        }
        blinking = true; highlightVisible = false; changed?()
        let token = generation
        blink = clock.schedule(after: 0.05) { [weak self] in
            guard let self, self.generation == token, self.isOpen else { return }
            self.highlightVisible = true; self.changed?()
            self.blink = self.clock.schedule(after: 0.05) { [weak self] in
                guard let self, self.generation == token, self.isOpen else { return }
                let run = self.execute; self.dismiss(); run?(action, column)
            }
        }
    }
}

enum OrbMenuGeometry {
    static func main(at point: CGPoint, in bounds: CGRect) -> CGRect {
        let size = CGSize(width: 236, height: 286)
        let x = point.x + size.width > bounds.maxX - 10 ? point.x - size.width : point.x
        let y = point.y + size.height > bounds.maxY - 10 ? point.y - size.height : point.y
        return clamped(CGRect(origin: CGPoint(x: x, y: y), size: size), in: bounds)
    }
    static func child(of main: CGRect, count: Int, in bounds: CGRect) -> CGRect {
        let size = CGSize(width: 300, height: CGFloat(count) * 24 + 10)
        let right = main.maxX - 3
        return clamped(CGRect(x: right + size.width > bounds.maxX - 10 ? main.minX - size.width + 3 : right,
                              y: main.minY + 33, width: size.width, height: size.height), in: bounds)
    }
    static func clamped(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: max(bounds.minX + 10, min(bounds.maxX - rect.width - 10, rect.minX)),
               y: max(bounds.minY + 10, min(bounds.maxY - rect.height - 10, rect.minY)), width: rect.width, height: rect.height)
    }
    static func inTriangle(_ p: CGPoint, origin a: CGPoint, edge: CGRect, right: Bool) -> Bool {
        let x = right ? edge.minX : edge.maxX
        let b = CGPoint(x: x, y: edge.minY - 6), c = CGPoint(x: x, y: edge.maxY + 6)
        func cross(_ u: CGPoint, _ v: CGPoint, _ w: CGPoint) -> CGFloat { (u.x - w.x) * (v.y - w.y) - (v.x - w.x) * (u.y - w.y) }
        let d = [cross(p,a,b), cross(p,b,c), cross(p,c,a)]
        return !(d.contains { $0 < 0 } && d.contains { $0 > 0 })
    }
}
