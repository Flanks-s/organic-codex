import AppKit
import QuartzCore

extension AutoScene {
    func openSidechat(parent: Conversation, chat: SidechatRuntime.Chat,
                      configure: (SidechatPanePresentation) -> Void) {
        if !columns.contains(where: { $0.conversation === parent }) {
            if isFocused {
                performOrbAction(.focused, conversation: parent, column: nil, anchor: .zero)
            } else {
                enterFocused(parent.id, reason: "sidechat-parent")
            }
        }
        guard columns.contains(where: { $0.conversation === parent }) else { return }
        foldSidechat()
        removeSidechat()
        let host = SidechatPanePresentation(now: { [weak self] in self?.now() ?? CACurrentMediaTime() })
        sidechatPane = host
        sidechatParentID = parent.id
        sidechatChatID = chat.id
        host.frame = nativePlane.bounds
        host.autoresizingMask = [.width, .height]
        nativePlane.addSubview(host, positioned: .above, relativeTo: nil)
        host.pane.apply(chat, parentTitle: parent.title)
        configure(host)
        host.pane.onFold = { [weak self, weak host] in
            host?.fold()
            self?.sidechatMotionChanged()
        }
        host.moon.invoke = { [weak self, weak host] in
            guard let host else { return }
            if host.folded { host.open() } else { host.fold() }
            self?.sidechatMotionChanged()
        }
        sidechatMenuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: host.moon.menu, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sidechatMotionChanged() }
        }
        host.pane.setAccessibilityCustomActions([.init(name: "Fold") { [weak self, weak host] in
            guard let host, !host.folded, !host.closed else { return false }
            host.fold()
            self?.sidechatMotionChanged()
            return true
        }])
        placeSidechat()
        host.open()
        sidechatMotionChanged()
    }

    func placeSidechat(at time: Double? = nil) {
        guard let host = sidechatPane, let id = sidechatParentID else { return }
        guard let index = columns.firstIndex(where: { $0.conversation.id == id }),
              layout.columns.indices.contains(index) else {
            if !host.folded { host.fold() }
            if sidechatReserve > 0 {
                DispatchQueue.main.async { [weak self, weak host] in
                    guard let self, self.sidechatPane === host else { return }
                    self.restoreSidechatSpace()
                }
            }
            if host.hasMotion { runClock(until: now() + 0.6) }
            return
        }
        let target = layout.columns[index]
        if !host.folded || host.sidechatStructure == nil {
            let direct = ExpandPaneLayout.resolve(in: nativePlane.bounds, parent: target, selection: nil, scale: scale)
            let settled = sidechatPlacement(parent: target, columns: layout.columns, parentIndex: index)
            host.sidechatStructure = (direct.moon.x >= target.midX, settled.overlaysParent)
        }
        guard let structure = host.sidechatStructure else { return }
        var parent = target
        if let time, began >= 0 {
            let rect = columns[index].rect.sample(time - began).rect
            parent.origin.x = rect.minX
            parent.size.width = rect.width
        }
        let sampled = sidechatPlacement(parent: parent, columns: layout.columns, parentIndex: index,
                                        onRight: structure.onRight)
        let placement = ExpandPaneLayout(pane: sampled.pane, anchor: sampled.anchor, moon: sampled.moon,
                                         mouth: sampled.mouth, overlaysParent: structure.overlaysParent)
        guard placement != sidechatPlacementCache else { return }
        sidechatPlacementCache = placement
        host.place(placement)
    }

    func sidechatPlacement(parent: CGRect, columns: [CGRect], parentIndex: Int,
                           onRight: Bool? = nil) -> ExpandPaneLayout {
        let direct = ExpandPaneLayout.resolve(in: nativePlane.bounds, parent: parent, selection: nil, scale: scale,
                                              onRight: onRight)
        let collision = columns.enumerated().contains { $0.offset != parentIndex && $0.element.intersects(direct.pane) }
        guard collision else { return direct }
        let group = columns.reduce(parent) { $0.union($1) }
        let outside = ExpandPaneLayout.resolve(in: nativePlane.bounds, parent: group, selection: nil, scale: scale)
        if outside.overlaysParent {
            var pane = outside.pane
            let inset = min(16, min(nativePlane.bounds.width, nativePlane.bounds.height) / 4)
            pane.origin.x = min(pane.minX, max(nativePlane.bounds.minX + inset, parent.maxX - pane.width))
            return ExpandPaneLayout(pane: pane, anchor: direct.anchor, moon: direct.moon,
                                    mouth: CGPoint(x: pane.midX, y: outside.mouth.y), overlaysParent: true)
        }
        return ExpandPaneLayout(pane: outside.pane, anchor: direct.anchor, moon: direct.moon,
                                mouth: outside.mouth, overlaysParent: outside.overlaysParent)
    }

    func canReserveSidechat(_ amount: CGFloat) -> Bool {
        guard let id = sidechatParentID, amount > 0, size.width > amount else { return false }
        let previous = sidechatReserve
        sidechatReserve = amount
        let (target, targetOrder) = arrange(members, current: current)
        sidechatReserve = previous
        let shown = Array(targetOrder.prefix(target.columns.count))
        guard shown == columns.map({ $0.conversation.id }), let index = shown.firstIndex(of: id),
              target.columns.indices.contains(index) else { return false }
        if scheme.mode == .focused && scheme.split.count == 2 && !target.separateInputs { return false }
        let minimum: CGFloat
        if target.focused {
            let floor = FocusLayout(size: .zero, segments: target.columns.count, leftOrbs: 0, rightOrbs: 0,
                                    satellites: false, metrics: metrics)
            minimum = floor.columns.first?.width ?? 0
        } else {
            minimum = metrics.fullMin
        }
        guard target.focused || target.columns.indices.contains(target.fullColumn) else { return false }
        let full = target.focused ? target.columns : [target.columns[target.fullColumn]]
        guard full.allSatisfy({ $0.width >= minimum && $0.minX >= 0 && $0.maxX <= size.width - amount }) else {
            return false
        }
        let placement = sidechatPlacement(parent: target.columns[index], columns: target.columns, parentIndex: index)
        return !placement.overlaysParent && !target.columns.contains { $0.intersects(placement.pane) }
    }

    func makeSidechatSpace() {
        guard sidechatReserve == 0, let id = sidechatParentID,
              let index = columns.firstIndex(where: { $0.conversation.id == id }),
              layout.columns.indices.contains(index) else { return }
        let placement = sidechatPlacement(parent: layout.columns[index], columns: layout.columns, parentIndex: index)
        guard placement.overlaysParent else { return }
        let amount = placement.pane.width + 18 + 16
        guard canReserveSidechat(amount) else { return }
        sidechatReserve = amount
        commitSidechatLayout(reason: "sidechat-make-way")
    }

    func restoreSidechatSpace() {
        guard sidechatReserve > 0 else { return }
        sidechatReserve = 0
        commitSidechatLayout(reason: "sidechat-restore")
    }

    private func commitSidechatLayout(reason: String) {
        let start = CACurrentMediaTime()
        let plan = prepare(members: members, current: current, at: now(), deferVisibleReflow: true)
        commit(plan, reason: reason, prewarmed: false, start: start)
    }

    func sidechatMotionChanged() {
        if sidechatPane?.folded == true { restoreSidechatSpace() }
        else { makeSidechatSpace() }
        guard sidechatPane?.hasMotion == true else { return }
        runClock(until: now() + 0.6)
    }

    func foldSidechat() {
        sidechatPane?.fold()
        sidechatMotionChanged()
    }

    func removeSidechat(restore: Bool = true) {
        if restore { restoreSidechatSpace() } else { sidechatReserve = 0 }
        if let observer = sidechatMenuObserver { NotificationCenter.default.removeObserver(observer) }
        sidechatMenuObserver = nil
        sidechatPane?.dispose()
        sidechatPane = nil
        sidechatPlacementCache = nil
        sidechatParentID = nil
        sidechatChatID = nil
    }
}
