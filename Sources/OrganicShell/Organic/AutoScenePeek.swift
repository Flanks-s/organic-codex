import AppKit
import QuartzCore

extension AutoScene {

    func pointer(_ p: CGPoint?) {
        prewarmActivity()
        lastPointer = p
        let admitted = p.flatMap { peekNode.coversPointer($0) ? nil : $0 }
        dock.hoverGrip(admitted)
        meHover(drag == nil ? admitted : nil)
        peekNode.pointerShield.reconcile()
        let t = now()
        runClock(until: t + dock.pointer(p, now: t))
        updateHoverRegions(p)
    }

    private func updateHoverRegions(_ p: CGPoint?) {
        var next: [String: String?] = [:]
        if let p {
            if !peekNode.coversPointer(p), let node = dock.hoverNode(at: p) { next["orb." + node.id] = node.orb ? node.id : nil }
            if peekOpen, let g = shownPeek.flatMap(peekGeometry), (g.peek.blur.contains(p) || peekNode.coversPointer(p)) { next["peek.surface"] = .some(nil) }
        }
        for r in hoverRegions where next[r] == nil { hoverRegion(r, inside: false) }
        for (r, orb) in next where !hoverRegions.contains(r) {
            // Pointed at, a red event has been seen: its reminder stops hopping (OrganicDockProjection hover; B12).
            if r.hasPrefix("orb."), let c = conversation(String(r.dropFirst(4))), c.redSeen != c.redEvents { c.redSeen = c.redEvents; store.changed(c) }
            hoverRegion(r, inside: true, orb: orb)
        }
    }

    /// Hover opens a peek after 0.25 s on an orb (Auto only; not while dragging or with a button down) and closes it
    /// 0.4 s after the pointer has left every region.
    private func hoverRegion(_ region: String, inside: Bool, orb: String? = nil) {
        if inside { hoverRegions.insert(region) } else { hoverRegions.remove(region) }
        peekTimer?.cancel(); peekTimer = nil
        guard !isDragging, !dock.isHoldingMe else { return }
        if inside, let orb, scheme.mode == .auto, peeking != orb, pressedButtons() == 0 {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.hoverRegions.contains(region), !self.isDragging, !self.dock.isHoldingMe,
                      self.scheme.mode == .auto, self.pressedButtons() == 0 else { return }
                self.peekOrigin = self.dock.frame(of: orb)
                self.setPeeking(orb)
            }
            peekTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekOpenDelay, execute: w)
        } else if hoverRegions.isEmpty, peeking != nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.hoverRegions.isEmpty else { return }
                self.setPeeking(nil)
            }
            peekTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekCloseDelay, execute: w)
        }
    }

    /// The peek asked for changed (WindowModel.peeking → peekChanged): open now, its content 100 ms later; closing, the
    /// content goes first (0.07 s), the capsule and halo 60 ms later, and what showed 240 ms after that.
    func setPeeking(_ id: String?) {
        guard id != peeking || (id == nil && shownPeek != nil && peekOpen) else { return }
        peeking = id
        peekStage.forEach { $0.cancel() }; peekStage = []
        if let id, conversation(id) != nil, peekGeometry(id) != nil {
            if shownPeek != id { peekContentVisible = false }
            shownPeek = id; peekOpen = true
            for other in prewarmed.values { unstage(other) }
            prewarmed = [:];lastPrewarmClear="setPeeking"
            projectPeek(contentDuration: nil)
            stage(after: 0.1) { $0.peekContentVisible = true; $0.projectPeek(contentDuration: 0.12) }
            // The same Dock node becomes the bottom capsule. Reveal the passive top endpoint only after its
            // original planet is fully veiled, including a close/open reversal. Reuse the Dock's authored duration.
            stage(after: dock.items[id]?.veil.duration ?? 0) { s in
                guard s.peekOpen, s.shownPeek == id, let item = s.dock.items[id], item.veil.to == 1 else { return }
                // The frame sampler may last have painted just before the veil's deadline.
                item.decoration.setVeil(1)
                s.peekNode.setHeaderVisible(true, duration: 0.12)
            }
        } else {
            peeking = nil
            guard shownPeek != nil else { return }
            peekContentVisible = false
            projectPeek(contentDuration: 0.07)
            peekNode.fadeLyrics()
            stage(after: 0.06) { s in
                s.peekOpen = false; s.projectPeek(contentDuration: nil)
                s.stage(after: 0.24) { s in s.shownPeek = nil; s.peekOrigin = nil; s.projectPeek(contentDuration: nil); s.settleHoverAfterPeek() }
            }
        }
    }

    private func stage(after seconds: Double, _ run: @escaping (AutoScene) -> Void) {
        let w = DispatchWorkItem { [weak self] in if let self { run(self) } }
        peekStage.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// The peeked orb, and the halo, capsule, lyrics and row over it (OrganicDockBridge.peekGeometry).
    private func peekGeometry(_ id: String) -> (orb: CGRect, peek: AutoLayout.Peek)? {
        let n = layout.columns.count
        guard let index = order.dropFirst(n).firstIndex(of: id) else { return nil }
        let k = index - n
        guard layout.orbs.indices.contains(k) else { return nil }
        let orb = peekOrigin ?? layout.orbs[k]
        return (orb, layout.peek(over: orb, size: size, satelliteRows: 1, satellite: orb.width * 0.38, metrics: metrics))
    }

    /// Immutable fog assets only: no native header allocation or extra WindowServer glass at rest.
    func warmPeekImagesInIdle(_ idle: M11IdlePreparation) async throws {
        var sizes: Set<PeekHalo.Key> = []
        for id in order.dropFirst(layout.columns.count) {
            guard let g = peekGeometry(id)?.peek else { continue }
            let key = PeekHalo.Key(size: PeekNode.preparedImageSize(geometry: g, scale: scale), scale: scale)
            guard sizes.insert(key).inserted else { continue }
            try await idle.step("peek.images.lookup") {}
            idle.finish() // distance-field and gradient assembly run off the main actor
            await PeekHalo.prepare(key)
            try await idle.step("peek.images.ready") {}
        }
    }

    /// A click on an open peek's halo is the peek's (NativeDockPeekContent's surface; organic audit B06): not the
    /// columns' under it. A satellite in its row opens that sub-agent's read-only window (SatelliteOpener; B07).
    /// Returns whether the click was taken.
    func peekClick(at p: CGPoint) -> Bool {
        guard let id = shownPeek, peekNode.coversPointer(p) else { return false }
        if let c = conversation(id), let sub = peekRow.first(where: { hypot($0.value - p.x, peekRowY - p.y) <= 12 })?.key {
            subAgentWindows.present(subagentID: sub, of: c)
        }
        return true
    }

    /// Puts the peek state on screen: the dock's bud and face, and the halo.
    private func projectPeek(contentDuration: Double?) {
        let g = shownPeek.flatMap(peekGeometry)
        var rows: [String: CGFloat] = [:]
        if let id = shownPeek, let c = conversation(id), let g {
            // OrganicDockBridge.peekRow: running then finished, as many as fit, centred under the capsule.
            let ordered = c.satellites.filter { !$0.done } + c.satellites.filter(\.done)
            let cell: CGFloat = 24
            let shown = Array(ordered.prefix(max(1, Int((g.peek.capsule.width - 24) / cell))))
            let start = g.peek.capsule.midX - CGFloat(shown.count - 1) * cell / 2
            for (i, s) in shown.enumerated() { rows[s.id] = start + CGFloat(i) * cell }
        }
        dock.projectPeek(shown: g == nil ? nil : shownPeek, open: peekOpen, capsule: g?.peek.capsule ?? .zero, rows: rows,
                         rowY: (g?.peek.rowsTop ?? 0) + 12)
        peekRow = peekOpen ? rows : [:]; peekRowY = (g?.peek.rowsTop ?? 0) + 12
        if let id=shownPeek,let c=conversation(id),let g,peekOpen,!c.satellitesRetired {
            peekNode.satellites(c.satellites.map{OrbSatellite(id:$0.id,face:$0.face,done:$0.done,finishedOrder:$0.finishedOrder)},
                                positions:rows,rowY:peekRowY,diameter:g.orb.width*0.38) { [weak self] sub,point in
                self?.subAgentWindows.present(subagentID:sub,of:c,at:point)
            }
        } else {peekNode.clearSatellites()}
        if let d = contentDuration { dock.peekContent(visible: peekContentVisible, duration: d) }
        if let id = shownPeek, let c = conversation(id), let g {
            if peekOpen, peekNode.shown != id || contentDuration == nil && !peekContentVisible { peekNode.open(c, geometry: g.peek, showHeader: false) }
            else if !peekOpen { peekNode.retract() }
        } else if peekNode.shown != nil {
            peekNode.clear()
            // The dock held its magnification while the peek showed: it follows the pointer again.
            let t = now()
            runClock(until: t + dock.pointer(lastPointer, now: t))
            DispatchQueue.main.async { [weak self] in self?.requestPrewarm() }
        }
        let shield = peekNode.pointerShield
        shield.setScopes([nativePlane, dockView])
        shield.contains = { [weak peekNode] in peekNode?.coversPointer($0) == true }
        shield.pointer = { [weak self] in
            guard let self else { return nil }
            if let window = self.peekNode.view.window {
                return window.isKeyWindow ? self.peekNode.view.convert(window.mouseLocationOutsideOfEventStream, from: nil) : nil
            }
            return self.lastPointer
        }
        peekNode.view.click = { [weak self] in _ = self?.peekClick(at: $0) }
        peekNode.view.scroll = { [weak self] in _ = self?.peekScroll($0, at: $1) }
        shield.reconcile(force: true)
        let admitted = shield.pointer().flatMap { peekNode.coversPointer($0) ? nil : $0 }
        dock.hoverGrip(admitted)
        meHover(drag == nil ? admitted : nil)
        runClock(until: max(now() + 0.5, dock.peekSettles))
    }

    /// A scroll over an open peek's halo reads back through its brief. Whether it took the scroll.
    func peekScroll(_ dy: CGFloat, at p: CGPoint) -> Bool {
        guard peekNode.containsPointerSurface(p) else { return false }
        if peekOpen { peekNode.scroll(by: dy) }
        return true
    }

    /// Force Click on an orb: its peek opens without the hover's wait (Auto only).
    func forcePeek(at p: CGPoint) {
        guard scheme.mode == .auto, !isDragging, let node = dock.hoverNode(at: p), node.orb else { return }
        peekTimer?.cancel(); peekTimer = nil
        peekOrigin = dock.frame(of: node.id)
        setPeeking(node.id)
    }

    /// Ends a peek at once, without its staged close: a transition or a resize takes the bud's glass over where it is.
    func dismissPeek() {
        peekTimer?.cancel(); peekTimer = nil
        guard shownPeek != nil || peeking != nil else { return }
        peekStage.forEach { $0.cancel() }; peekStage = []
        peeking = nil; shownPeek = nil; peekOpen = false; peekContentVisible = false; peekOrigin = nil
        peekNode.dismiss()
        dock.projectPeek(shown: nil, open: false, capsule: .zero, rows: [:], rowY: 0)
        peekNode.pointerShield.reconcile(force: true)
        settleHoverAfterPeek()
    }

    /// A peek holds the Dock's magnification and ignores the pointer. Once it is gone, the pointer's last word counts:
    /// one that left meanwhile would otherwise keep the orbs magnified until it moved over the window again.
    private func settleHoverAfterPeek() {
        let t = now()
        runClock(until: t + dock.pointer(lastPointer, now: t))
    }

    var peekState: [String: Any] {
        ["peeking": peeking ?? "", "shown": shownPeek ?? "", "open": peekOpen, "content": peekContentVisible,
         "capsule": dock.peekCapsuleFrame.map(NSStringFromRect) ?? ""]
    }
}
