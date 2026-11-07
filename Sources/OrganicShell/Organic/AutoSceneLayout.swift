import AppKit
import QuartzCore

extension AutoScene {
    /// Auto, or Focused / Split: the conversations sharing the capsule, left to right, and the orbs either side
    /// (WindowModel splitMembers, banks).
    enum Mode: Equatable { case auto, focused }
    struct Scheme: Equatable {
        var mode = Mode.auto
        var split: [String] = []
        var left: [String] = [], right: [String] = []
        /// Auto with New Chat's draft open (WindowModel.composingNew): the draft is the full column at the right.
        var draft = false
        /// Members parked right of me (WindowModel.parked): the briefs the draft squeezed out, kept there by its send.
        var parked: [String] = []
    }
    var fullIndex: Int { columns.firstIndex { $0.conversation.id == current } ?? 0 }
    var isFocused: Bool { scheme.mode == .focused }

    /// Canopy washes (Canopy.swift:30-51): moss from the top right, teal from the bottom left, sized by the longer side.
    func layoutWashes() {
        let side = max(size.width, size.height)
        for w in washes {
            let r = side * w.radius, centre = w.topRight ? CGPoint(x: size.width, y: 0) : CGPoint(x: 0, y: size.height)
            w.layer.frame = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
        }
    }

    /// Full transcripts use the current header variant's reserve, including in Split.
    func fullContentTop(for scheme:Scheme)->CGFloat {
        let variant:HeaderIslandVariant=scheme.mode == .focused && scheme.split.count>1 ? .split(focused:true):.full
        return variant.metrics(band:HeaderIslandVariant.band(bleedTop:52)).contentTop
    }

    /// The layout and display order for a working set and its full member (AutoLayout.swift:183; WindowModel
    /// displayOrder: a full member past the columns shows in the last one).
    func arrange(_ members: [Conversation], current: String, scheme next: Scheme? = nil) -> (AutoLayout, [String]) {
        let ids = members.map(\.id)
        let sch = next ?? scheme
        if sch.mode == .focused {
            // Focused / Split: the capsule centred under its columns, the others as orbs either side in the order they
            // took on the way in; a member that arrives meanwhile joins the shorter side, the right one on a tie.
            let split = sch.split.filter(ids.contains)
            var left = sch.left.filter { ids.contains($0) && !split.contains($0) }, right = sch.right.filter { ids.contains($0) && !split.contains($0) && !left.contains($0) }
            for id in ids where !split.contains(id) && !left.contains(id) && !right.contains(id) {
                if left.count < right.count { left.append(id) } else { right.append(id) }
            }
            let f = FocusLayout(size: size, segments: split.count, leftOrbs: left.count, rightOrbs: right.count, satellites: false, metrics: metrics)
            var l = AutoLayout()
            l.columns = f.columns; l.bars = f.segments; l.me = f.me; l.orbs = f.leftOrbs + f.rightOrbs; l.focused = true
            return (snapped(l), split + left + right)
        }
        let parked = sch.parked.filter(ids.contains)
        let rest = ids.filter { !parked.contains($0) }
        if sch.draft { return draftArrangement(rest, current: current, parked: parked) }
        if !parked.isEmpty { return autoArrangement(rest, current: current, parked: parked) }
        var n = AutoLayout(size: size, count: ids.count, fullIndex: 0, metrics: metrics).columns.count
        var l = AutoLayout()
        var order = ids
        for _ in 0..<2 {
            order = Self.displayOrder(ids, current: current, columns: n)
            l = snapped(AutoLayout(size: size, count: ids.count, fullIndex: order.firstIndex(of: current) ?? 0, metrics: metrics))
            if l.columns.count == n { break }
            n = l.columns.count
        }
        return (l, order)
    }

    /// Auto with members parked right of me (OrganicDockBridge.arrange): the columns, then the parked, then the bank.
    private func autoArrangement(_ ids: [String], current: String, parked: [String]) -> (AutoLayout, [String]) {
        let first = snapped(AutoLayout(size: size, count: ids.count, fullIndex: ids.firstIndex(of: current), leading: parked.count, metrics: metrics))
        let order = Self.displayOrder(ids, current: current, columns: first.columns.count)
        let l = order == ids ? first
            : snapped(AutoLayout(size: size, count: order.count, fullIndex: order.firstIndex(of: current), leading: parked.count, metrics: metrics))
        let n = l.columns.count
        return (l, Array(order.prefix(n)) + parked + Array(order.dropFirst(n)))
    }

    /// New Chat's arrangement (OrganicDockBridge.draftArrangement): the draft joins as the full column at the right;
    /// a column that showed before and no longer fits is parked right of me, nearest first (each parked orb takes a
    /// 58 pt rail, so up to four more passes). The draft's column and bar come out of the layout for the scene to draw.
    private func draftArrangement(_ rest: [String], current: String, parked: [String]) -> (AutoLayout, [String]) {
        let before = parked.isEmpty ? arrange(rest.compactMap(conversation), current: current, scheme: Scheme()) : autoArrangement(rest, current: current, parked: parked)
        let shown = Array(before.1.prefix(before.0.columns.count))
        var displaced: [String] = []
        func attempt() -> (AutoLayout, [String]) {
            autoArrangement(rest.filter { !displaced.contains($0) } + [Self.draftID], current: Self.draftID, parked: parked + displaced)
        }
        var a = attempt()
        for _ in 0..<4 {
            let columns = Set(a.1.prefix(a.0.columns.count))
            let out = shown.filter { !columns.contains($0) && !displaced.contains($0) }
            if out.isEmpty { break }
            displaced += out
            a = attempt()
        }
        var (l, order) = a
        if let k = order.firstIndex(of: Self.draftID), k < l.columns.count {
            l.draftColumn = l.columns.remove(at: k); l.draftBar = l.bars.remove(at: k); order.remove(at: k)
            l.fullColumn = l.columns.count
        }
        return (l, order)
    }

    static func displayOrder(_ ids: [String], current: String, columns: Int) -> [String] {
        guard let i = ids.firstIndex(of: current), i >= columns, columns > 0 else { return ids }
        var out = ids
        out.remove(at: i)
        out.insert(current, at: columns - 1)
        return out
    }

    /// Columns and their bars at rest have their edges on the backing pixel grid. A native transcript at a fractional
    /// place or size is resampled on screen and its capture is not, so the two differ at every swap.
    private func snapped(_ l: AutoLayout) -> AutoLayout {
        func edge(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        func rect(_ r: CGRect) -> CGRect { CGRect(x: edge(r.minX), y: edge(r.minY), width: edge(r.maxX) - edge(r.minX), height: edge(r.maxY) - edge(r.minY)) }
        var l = l; l.columns = l.columns.map(rect); l.bars = l.bars.map(rect); return l
    }

    /// Full bleed: the carrier spans the window's height; the logical column only places content.
    func carrier(_ logical: CGRect) -> CGRect { CGRect(x: logical.minX, y: 0, width: logical.width, height: size.height) }

    /// Settings ▸ Organic ▸ Full-bleed Organic canvas (`toggle.organicFullBleed`, on by default); off, columns are cards
    /// between the title bar and the dock (ColumnNode.cardBand).
    static var fullBleed: Bool { UserDefaults.standard.object(forKey: "toggle.organicFullBleed") as? Bool ?? true }
    func cardBand(_ logical: CGRect) -> ClosedRange<CGFloat>? { Self.fullBleed ? nil : logical.minY...logical.maxY }
    /// The setting changed, or the layout under it: each column's card follows.
    func applyCardBands() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, column) in columns.enumerated() where layout.columns.indices.contains(i) { column.cardBand = cardBand(layout.columns[i]) }
        CATransaction.commit()
    }

    /// The full form's width for the column in slot `i`: Auto's full column, or in Focused / Split the column's own.
    func fullWidth(_ i: Int, _ l: AutoLayout) -> CGFloat {
        guard !l.columns.isEmpty else { return 0 }
        // With the draft open no column is full; a member's full width is the draft's.
        guard l.columns.indices.contains(l.fullColumn) else { return l.draftColumn?.width ?? l.columns.map(\.width).max() ?? 0 }
        return l.focused && i < l.columns.count ? l.columns[i].width : l.columns[l.fullColumn].width
    }
    /// Whether a conversation shows full: Auto's current one, or every member of the capsule.
    func isFull(_ id: String, _ sch: Scheme? = nil, current c: String? = nil) -> Bool {
        let sch = sch ?? scheme
        return sch.mode == .focused ? sch.split.contains(id) : !sch.draft && id == (c ?? current)
    }
    var fullIDs: Set<String> { scheme.mode == .focused ? Set(scheme.split) : scheme.draft ? [] : [current] }
    func briefWidth(_ i: Int, _ l: AutoLayout) -> CGFloat {
        // Focused / Split has no brief columns: a column's brief would take Auto's usual width there.
        guard !l.columns.isEmpty, !l.focused else { return 300 }
        let i = min(i, l.columns.count - 1)
        let others = l.columns.indices.filter { $0 != l.fullColumn }
        return i != l.fullColumn ? l.columns[i].width : (others.first.map { l.columns[$0].width } ?? 300)
    }

    func column(at point: CGPoint) -> Int? {
        if let i = layout.columns.firstIndex(where: { carrier($0).contains(point) && point.y < $0.maxY + 10 }) { return i }
        return layout.bars.firstIndex { $0.insetBy(dx: 0, dy: -6).contains(point) }
    }

    // MARK: Split focus (f041)

    /// The conversation commands act on: in Split the member whose editor has focus, else the full one.
    var focusTarget: String {
        guard scheme.mode == .focused, let r = sceneView.window?.firstResponder as? NSView else { return current }
        return scheme.split.first { id in composers.existingComposer(for: id).map { r.isDescendant(of: $0) } == true } ?? current
    }
    func tellTarget() { let t = focusTarget; if t != toldTarget { toldTarget = t; onTarget?(t) } }

    /// ⌃Tab / ⌃⇧Tab: the next or previous segment's editor takes the focus, so the first key goes there.
    func focusPane(_ step: Int) {
        guard scheme.mode == .focused, scheme.split.count > 1 else { return }
        let i = scheme.split.firstIndex(of: focusTarget) ?? 0
        focusMember(scheme.split[(i + step + scheme.split.count) % scheme.split.count])
    }
    /// A click on a Split column gives its segment the focus.
    func focusColumn(_ index: Int) {
        guard scheme.mode == .focused, columns.indices.contains(index), scheme.split.contains(columns[index].conversation.id) else { return }
        focusMember(columns[index].conversation.id)
    }
    func focusMember(_ id: String) {
        composers.existingComposer(for: id)?.focus()
        tellTarget()
        if !isMoving { restIslands() }
    }

    /// Split with Next Conversation (OWC splitWithNext): from Auto, Focused on the shown one first; then the next orb on
    /// the right (else the left) joins the capsule, while it has room.
    func splitWithNext() {
        if scheme.mode == .auto { enterFocused(current, reason: "menu") }
        guard scheme.mode == .focused, let next = scheme.right.first ?? scheme.left.first else { return }
        graft(next, at: scheme.split.count, reason: "menu")
    }

    /// The window narrowed past what the capsule holds: its last segments go back to being orbs (WindowModel.fitSplit;
    /// audit A08). Called once a resize has laid out.
    func fitSplit() {
        guard scheme.mode == .focused, scheme.split.count > 1 else { return }
        let limit = max(1, FocusLayout.capacity(width: size.width, members: members.count, metrics: metrics))
        guard scheme.split.count > limit else { return }
        var next = scheme
        while next.split.count > limit, let last = next.split.last {
            next.split.removeLast()
            if next.left.count < next.right.count { next.left.insert(last, at: 0) } else { next.right.insert(last, at: 0) }
            if let pair = compare, pair.left == last || pair.right == last { compare = nil; compareAsk = nil; dock.setMeDivider(nil) }
        }
        let full = next.split.contains(current) ? current : next.split[0]
        transition(to: members, current: full, scheme: next, spring: Self.focusSpring, reason: "fit-split")
    }

    // MARK: Focused / Split (f038–f042; WindowModel enterFocused, graft, ungraft, exitToAuto)

    /// The product's Focused spring (Tuning focusResponse / focusDamping: me lands, the capsule forms).
    static var focusSpring: (response: Double, damping: Double) { Tuning.shared.focusSpring }

    /// One conversation takes the window: its column centred at reading width, its bar the capsule with me at its left
    /// end, every other one an orb on the side it is on now (left of it left, nearest nearest), so none crosses the
    /// capsule on the way.
    func enterFocused(_ id: String, reason: String) {
        guard scheme.mode == .auto, members.contains(where: { $0.id == id }) else { return }
        // Sides as they are on screen, left to right: parked orbs just right of me, the columns, the bank
        // (WindowModel.previewSides; audit A11).
        let parked = scheme.parked.filter { p in members.contains { $0.id == p } }
        let screen = parked + order.filter { !parked.contains($0) }
        guard let k = screen.firstIndex(of: id) else { return }
        autoSnapshot = (members, current, parked)
        let next = Scheme(mode: .focused, split: [id], left: Array(screen[..<k].reversed()), right: Array(screen[(k + 1)...]))
        transition(to: members, current: id, scheme: next, spring: Self.focusSpring, reason: reason)
    }

    /// Back to Auto as it was before Focused; conversations that arrived meanwhile keep their place at the end.
    func leaveFocused(reason: String) {
        compare = nil; compareAsk = nil
        guard scheme.mode == .focused else { return }
        let snapshot = autoSnapshot ?? (members, scheme.split.first ?? current, [])
        let kept = snapshot.members.filter { m in members.contains { $0 === m } }
        let next = kept + members.filter { m in !kept.contains { $0 === m } }
        let full = next.contains { $0.id == snapshot.current } ? snapshot.current : (next.first?.id ?? "")
        autoSnapshot = nil
        // Parked as they were (the full one is no longer parked).
        let parked = snapshot.parked.filter { p in p != full && next.contains { $0.id == p } }
        transition(to: next, current: full, scheme: Scheme(parked: parked), spring: Self.focusSpring, reason: reason)
    }

    /// An orb dropped into the capsule joins it at `index` (Split, f040), while the capsule has room for another segment.
    func graft(_ id: String, at index: Int, reason: String) {
        guard scheme.mode == .focused, !scheme.split.contains(id), members.contains(where: { $0.id == id }) else { return }
        let limit = FocusLayout.capacity(width: size.width, members: members.count, metrics: metrics)
        guard scheme.split.count < limit else { return }
        var next = scheme
        next.split.insert(id, at: min(max(0, index), next.split.count))
        next.left.removeAll { $0 == id }; next.right.removeAll { $0 == id }
        transition(to: members, current: id, scheme: next, spring: Self.focusSpring, reason: reason)
    }

    /// A segment dragged out of the capsule becomes an orb again; one left means Focused (f042).
    func ungraft(_ id: String, reason: String) {
        guard scheme.mode == .focused, scheme.split.count > 1, let i = scheme.split.firstIndex(of: id) else { return }
        if let pair = compare, pair.left == id || pair.right == id { compare = nil; dock.setMeDivider(nil) }
        var next = scheme
        next.split.remove(at: i)
        if next.left.count < next.right.count { next.left.insert(id, at: 0) } else { next.right.insert(id, at: 0) }
        let full = current == id ? next.split[min(i, next.split.count - 1)] : current
        transition(to: members, current: full, scheme: next, spring: Self.focusSpring, reason: reason)
    }
}
