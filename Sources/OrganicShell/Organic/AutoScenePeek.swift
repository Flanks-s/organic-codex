import AppKit
import QuartzCore

extension AutoScene {

    var dockOverlayBlocked: Bool { overlays.values.contains { $0.holdsOverlay } }

    func pointer(_ p: CGPoint?) {
        orbHint.pointer(dockOverlayBlocked ? nil : p)
        prewarmActivity()
        lastPointer = p
        let admitted = p.flatMap { peekNode.coversPointer($0) ? nil : $0 }
        dock.hoverGrip(admitted)
        meHover(drag == nil ? admitted : nil)
        peekNode.pointerShield.reconcile()
        let t = now()
        let duration = dock.pointer(p, now: t, overlayBlocked: dockOverlayBlocked)
        if duration > 0 { runClock(until: t + duration) }
        updateHoverRegions(dockOverlayBlocked ? nil : p)
    }

    func updateHoverRegions(_ p: CGPoint?) {
        let wasHeld=hoverRegions.contains("peek.island")
        var next: [String: String?] = [:]
        if let p {
            if !peekNode.coversPointer(p), let node = dock.hoverNode(at: p) { next["orb." + node.id] = node.orb ? node.id : nil }
            if peekOpen, let g = shownPeek.flatMap(peekGeometry),
               (g.peek.blur.contains(p) || peekNode.coversPointer(p) || peekReplyFrame?.contains(p) == true) {
                next["peek.surface"] = .some(nil)
            }
        }
        if peekInteractionHolds {next["peek.island"] = .some(nil)}
        for r in hoverRegions where next[r] == nil { hoverRegion(r, inside: false) }
        for (r, orb) in next where !hoverRegions.contains(r) {
            // Pointed at, a red event has been seen: its reminder stops hopping (OrganicDockProjection hover; B12).
            if r.hasPrefix("orb."), let c = conversation(String(r.dropFirst(4))), c.redSeen != c.redEvents { c.redSeen = c.redEvents; store.changed(c) }
            hoverRegion(r, inside: true, orb: orb)
        }
        if wasHeld,!peekInteractionHolds,let entry=next.first(where:{$0.key.hasPrefix("orb.") && $0.value != peeking}) {
            hoverRegion(entry.key,inside:true,orb:entry.value)
        }
    }

    /// Presentation owns the semantic hold; only pointer input replaces pointer-region ownership.
    func syncPeekIslandHold() {
        let held=peekInteractionHolds
        guard hoverRegions.contains("peek.island") != held else {return}
        hoverRegion("peek.island",inside:held)
        if !held,let region=hoverRegions.first(where:{$0.hasPrefix("orb.")}),String(region.dropFirst(4)) != peeking {
            hoverRegion(region,inside:true,orb:String(region.dropFirst(4)))
        }
    }

    /// Hover opens a peek after 0.25 s on an orb (Auto only; not while dragging or with a button down) and closes it
    /// 0.4 s after the pointer has left every region.
    private func hoverRegion(_ region: String, inside: Bool, orb: String? = nil) {
        if inside { hoverRegions.insert(region) } else { hoverRegions.remove(region) }
        peekTimer?.cancel(); peekTimer = nil
        guard !isDragging, !dock.isHoldingMe, !dockOverlayBlocked else { return }
        if inside, let orb, !peekInteractionHolds, !dock.tideOwns(orb), scheme.mode == .auto, peeking != orb, pressedButtons() == 0 {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.hoverRegions.contains(region), !self.isDragging, !self.dock.isHoldingMe,
                      self.scheme.mode == .auto, !self.peekInteractionHolds, !self.dock.tideOwns(orb),
                      !self.dockOverlayBlocked, self.pressedButtons() == 0 else { return }
                self.peekOrigin = self.dock.frame(of: orb)
                self.setPeeking(orb)
            }
            peekTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekOpenDelay, execute: w)
        } else if hoverRegions.isEmpty, peeking != nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.hoverRegions.isEmpty,!self.peekInteractionHolds else { return }
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
        if id != nil { orbHint.cancel() }
        if id != peekReply?.id { retirePeekReply(animated: id == nil) }
        if let id,id != orbMenuPeekColumn { orbMenuPeekColumn = nil }
        if let id,dock.tideHasNotice(id) {dock.retireTide()}
        peeking = id
        peekStage.forEach { $0.cancel() }; peekStage = []
        if let id, conversation(id) != nil, peekGeometry(id) != nil {
            clock.onFrame = { [weak self] target in
                guard let self else { return }
                self.frame(target)
                if self.peekOpen, let id=self.shownPeek, self.dock.browserDockPort?.coversMember(id)==true { self.dismissPeek() }
            }
            if shownPeek != id { peekContentVisible = false }
            shownPeek = id; peekOpen = true
            for other in prewarmed.values { unstage(other) }
            prewarmed = [:];lastPrewarmClear="setPeeking"
            projectPeek(contentDuration: nil)
            stage(after: 0.1) { $0.peekContentVisible = true; $0.projectPeek(contentDuration: 0.12) }
            // The same Dock node becomes the bottom capsule. Reveal the ordinary top endpoint only after its
            // original planet is fully veiled, including a close/open reversal. Reuse the Dock's authored duration.
            stage(after: dock.items[id]?.veil.duration ?? 0) { s in
                guard s.peekOpen, s.shownPeek == id, let item = s.dock.items[id], item.veil.to == 1 else { return }
                // The frame sampler may last have painted just before the veil's deadline.
                item.decoration.setVeil(1)
                s.peekNode.setHeaderVisible(true, duration: 0.12)
            }
        } else {
            retirePeekReply()
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
        if orbMenuPeekColumn == id,columns.contains(where:{$0.conversation.id == id}),let bar = dock.frame(of:id) {
            let orb = CGRect(x:bar.midX-16,y:bar.maxY-32,width:32,height:32)
            return (orb,layout.peek(over:orb,size:size,satelliteRows:0,satellite:12,metrics:metrics))
        }
        let n = layout.columns.count
        guard let index = order.dropFirst(n).firstIndex(of: id) else { return nil }
        let k = index - n
        guard layout.orbs.indices.contains(k) else { return nil }
        let orb = peekOrigin ?? layout.orbs[k]
        return (orb, layout.peek(over: orb, size: size, satelliteRows: 0, satellite: orb.width * 0.38, metrics: metrics))
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

    /// Blank Peek surface consumes its clicks; ordinary controls own their native actions.
    /// Returns whether the click was taken.
    func peekClick(at p: CGPoint) -> Bool {
        guard shownPeek != nil, peekNode.coversPointer(p) else { return false }
        return true
    }

    /// Puts the peek state on screen: the dock's bud and face, and the halo.
    private func projectPeek(contentDuration: Double?) {
        let g = shownPeek.flatMap(peekGeometry)
        if let id=shownPeek,peekOpen {wirePeekIsland(id)}
        dock.projectPeek(shown: g == nil || orbMenuPeekColumn == shownPeek ? nil : shownPeek, open: peekOpen,
                         capsule:g?.peek.capsule ?? .zero,rows:[:],rowY:0)
        peekRow=[:];peekRowY=0
        if let d = contentDuration { dock.peekContent(visible: peekContentVisible, duration: d) }
        if let id = shownPeek, let c = conversation(id), let g {
            if peekOpen, peekNode.shown != id || contentDuration == nil && !peekContentVisible { peekNode.open(c, geometry: g.peek, showHeader: orbMenuPeekColumn == id) }
            else if !peekOpen { peekNode.retract() }
            peekNode.setHeaderPresentationActive(ambientRunning)
        } else if peekNode.shown != nil {
            peekNode.clear()
            orbMenuPeekColumn = nil
            // The dock held its magnification while the peek showed: it follows the pointer again.
            let t = now()
            runClock(until: t + dock.pointer(lastPointer, now: t, overlayBlocked: dockOverlayBlocked))
            DispatchQueue.main.async { [weak self] in self?.requestPrewarm() }
        }
        projectPeekReply(id: g == nil ? nil : shownPeek, size: g?.peek.capsule.size ?? .zero)
        if let replyFrame = peekReplyFrame { peekNode.setReplyPassage(replyFrame) }
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
        peekNode.view.orbInput = { [weak self] event in
            guard let self else { return false }
            let point = self.dockView.convert(event.locationInWindow, from: nil)
            guard let id = self.orbInputTarget(at: point), id == self.shownPeek else { return false }
            return self.orbInput.begin(event,id:id,ordinary:{ [weak self] _ in self?.openPeekConversation(id) })
        }
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
        retirePeekReply()
        peekTimer?.cancel(); peekTimer = nil
        guard shownPeek != nil || peeking != nil else { return }
        peekStage.forEach { $0.cancel() }; peekStage = []
        peeking = nil; shownPeek = nil; peekOpen = false; peekContentVisible = false; peekOrigin = nil
        orbMenuPeekColumn = nil
        peekNode.dismiss()
        dock.projectPeek(shown: nil, open: false, capsule: .zero, rows: [:], rowY: 0)
        peekNode.pointerShield.reconcile(force: true)
        settleHoverAfterPeek()
    }

    /// A peek holds the Dock's magnification and ignores the pointer. Once it is gone, the pointer's last word counts:
    /// one that left meanwhile would otherwise keep the orbs magnified until it moved over the window again.
    private func settleHoverAfterPeek() {
        let t = now()
        runClock(until: t + dock.pointer(lastPointer, now: t, overlayBlocked: dockOverlayBlocked))
    }

    var peekState: [String: Any] {
        ["peeking": peeking ?? "", "shown": shownPeek ?? "", "open": peekOpen, "content": peekContentVisible,
         "capsule": dock.peekCapsuleFrame.map(NSStringFromRect) ?? ""]
    }
}
