import AppKit
import QuartzCore

extension AutoScene {

    /// The overflow conversation whose orb is under `point`.
    func orb(at point: CGPoint) -> Conversation? { dock.orb(at: point) }

    /// Makes the column in slot `index` full.
    func switchTo(_ index: Int, reason: String) {
        guard index >= 0, index < columns.count else { return }
        activate(columns[index].conversation.id, reason: reason)
    }

    /// Makes a column's conversation full. At rest it uses the switch prepared ahead, if its content still holds;
    /// interrupting continues every spring from its current value and velocity.
    func activate(_ id: String, reason: String) {
        M10ColumnWorkTrace.beginWindow("auto")
        let work=M10ColumnWorkTrace.scope("scene.activate",["id":id,"moving":isMoving]);defer{work.end()}
        // Showing a member closes the draft (WindowModel: composingNew = false), keeping its words.
        if scheme.draft, columns.contains(where: { $0.conversation.id == id }) { closeDraftForSwitch() }
        guard scheme.mode == .auto, id != current, columns.contains(where: { $0.conversation.id == id }) else { return }
        if let screen=sceneView.window?.screen {profile=DisplayProfile.of(screen)}
        let start = CACurrentMediaTime()
        var p = prewarmed[id]
        let hit = p != nil && !isMoving && p!.fromRest && p!.revisions == revisions && !dock.hasPeek
        tracePrewarmLookup(id:id,plan:p,hit:hit)
        for (key, other) in prewarmed where !(hit && key == id) { unstage(other) }
        prewarmed = [:];lastPrewarmClear="activate"
        if !hit { p = prepare(members: members, current: id, at: now()) }
        commit(p!, reason: reason, prewarmed: hit, start: start)
    }

    /// Shows `id` full at rest without a transition: the window comes back from Normie on the conversation it showed.
    /// Not yet in the working set, it joins it.
    func show(_ id: String) {
        guard let c = conversation(id), !c.archived, scheme.mode == .auto else { return }
        dismissPeek()
        if isMoving { settle() }
        let joining = !members.contains { $0.id == id }
        guard joining || id != current else { return }
        if joining { members.append(c) }
        current = id
        if joining { let (l, o) = arrange(members, current: current); dock.ensureItems(for: members, layout: l, order: o) }
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="show"
        resize(to: size, live: false)
        DispatchQueue.main.async { [weak self] in self?.requestPrewarm() }
    }
    var dockTargets: [(id: String, rect: CGRect, bar: Bool, slot: Int)] { dock.restingTargets }
    var meRest: CGRect { dock.meRest }
    var meFrame: CGRect? { dock.meFrame }
    func dockFrame(of id: String) -> CGRect? { dock.frame(of: id) }
    func setMeHidden(_ hidden: Bool) { dock.setMeHidden(hidden) }
    func setDockHidden(_ id: String, _ hidden: Bool) { dock.setHidden(id, hidden) }
    /// A dock node is held (pressed or dragged).
    var isHolding: Bool { drag != nil }

    /// The dock appears without every planet flying in (f066): bars settle, the other orbs bud from the bars.
    func bloomDock(excluding ids: Set<String> = []) {
        guard !Motion.reduce else { return }
        dock.bloom(excluding: ids)
        runClock(until: dock.bloomSettles + 0.02)
    }

    /// The dock comes in with Organic: opacity 0 → 1 over 0.22 s, ease in-out (NativeWindowDockMount).
    func fadeDockIn() {
        guard let layer = dockView.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1; a.duration = 0.22
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "mode.dock")
    }

    /// An overflow orb lands in the last brief slot; that slot's conversation becomes the first orb. When only the
    /// full column fits, the orb becomes full instead (WindowModel.land, f035).
    func land(_ id: String, reason: String) {
        guard scheme.mode == .auto else { return }
        if scheme.draft { closeDraftForSwitch() }
        let n = layout.columns.count
        var ids = Self.displayOrder(members.map(\.id), current: current, columns: n)
        guard let i = ids.firstIndex(of: id), i >= n else { return }
        var nextCurrent = current
        if let slot = (0..<n).last(where: { ids[$0] != current }) {
            ids.remove(at: i)
            let demoted = ids[slot]
            ids[slot] = id
            ids.insert(demoted, at: min(n, ids.count))
        } else {
            ids.remove(at: i); ids.insert(id, at: 0); nextCurrent = id
        }
        let start = CACurrentMediaTime()
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="land"
        commit(prepare(members: ids.compactMap(conversation), current: nextCurrent, at: now()), reason: reason, prewarmed: false, start: start)
    }

    /// A conversation joins the working set at its end (f036): the last brief column while there is room, else the last
    /// orb. Nothing already there moves out of order, and the full one and its input stay as they are.
    func admit(_ c: Conversation, reason: String) {
        guard !c.archived, !members.contains(where: { $0.id == c.id }) else { return }
        let start = CACurrentMediaTime()
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="admit"
        commit(prepare(members: members + [c], current: current.isEmpty ? c.id : current, at: now()), reason: reason, prewarmed: false, start: start)
    }

    /// A conversation leaves the working set (archived, f017 / f054). Its column shrinks away and its glass goes to a
    /// point; when it was full, the nearest other member becomes full.
    func remove(_ id: String, reason: String) {
        guard let i = members.firstIndex(where: { $0.id == id }) else { return }
        if reason == "archived", let c = conversation(id) { showArchiveToast(c.title); archivedOut.insert(id) }
        var next = members; next.remove(at: i)
        var nextCurrent = current
        if id == current {
            let shownIDs = Set(order.prefix(layout.columns.count))
            nextCurrent = (next.indices.sorted { abs($0 - i) < abs($1 - i) }.map { next[$0].id }.first { shownIDs.contains($0) }) ?? next.first?.id ?? ""
        }
        // Focused / Split, Compare and parking let go of it (WindowModel.remove; audit A07): no segment left is Auto as it
        // was, one left is Focused on it.
        var nextScheme = scheme
        nextScheme.parked.removeAll { $0 == id }
        nextScheme.left.removeAll { $0 == id }; nextScheme.right.removeAll { $0 == id }
        if let pair = compare, pair.left == id || pair.right == id { compare = nil; compareAsk = nil; dock.setMeDivider(nil) }
        if scheme.mode == .focused, let k = scheme.split.firstIndex(of: id) {
            nextScheme.split.remove(at: k)
            if nextScheme.split.isEmpty {
                let snapshot = autoSnapshot ?? (next, nextCurrent, [])
                let kept = snapshot.members.filter { m in next.contains { $0 === m } }
                next = kept + next.filter { m in !kept.contains { $0 === m } }
                nextCurrent = next.contains { $0.id == snapshot.current } ? snapshot.current : (next.first?.id ?? "")
                nextScheme = Scheme(parked: snapshot.parked.filter { p in p != nextCurrent && next.contains { $0.id == p } })
                autoSnapshot = nil
            } else if nextCurrent == id || !nextScheme.split.contains(nextCurrent) {
                nextCurrent = nextScheme.split[min(k, nextScheme.split.count - 1)]
            }
        }
        let start = CACurrentMediaTime()
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="remove"
        commit(prepare(members: next, current: nextCurrent, scheme: nextScheme, at: now()), reason: reason, prewarmed: false, start: start)
    }

    // MARK: Conversation menu in Organic (app audit AP05, AP06, AP17)

    /// Jump to Latest: the column showing `id` scrolls its own transcript to the end (never Normie's).
    func jumpToLatest(_ id: String) { if let node = nodes[id], node.ownsNative { node.native.scrollToEnd() } }

    /// Rename Chat…: the shown column's island edits its name; a conversation that is only an orb gets Customize
    /// (OWC renameChat).
    func beginRename(_ id: String) {
        if let island = columns.first(where: { $0.conversation.id == id })?.island, !island.isHidden { island.beginRename() }
        else { customize(id) }
    }
    func queueSwipe(_ event: NSEvent, at p: CGPoint) -> Bool {
        guard scheme.mode == .auto, !scheme.draft, event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] { return swipe?.claimed == true }
        if event.phase == .began || event.phase == .mayBegin {
            swipe = order.first { dock.frame(of: $0)?.insetBy(dx: -4, dy: -6).contains(p) == true }.map { ($0, 0, false) }
            return false
        }
        guard var s = swipe else { return false }
        if event.phase == .ended || event.phase == .cancelled { swipe = nil; return s.claimed }
        if !s.claimed {
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { swipe = nil; return false }
            s.claimed = true
        }
        s.accumulated += event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
        if abs(s.accumulated) >= Self.swipeStep {
            let direction = s.accumulated > 0 ? 1 : -1
            s.accumulated -= CGFloat(direction) * Self.swipeStep
            moveMember(s.id, by: direction)
        }
        swipe = s
        return true
    }

    /// One place along the queue (WindowModel.moveMember): moved on purpose, it is no longer parked.
    func moveMember(_ id: String, by step: Int) {
        guard let i = members.firstIndex(where: { $0.id == id }), members.indices.contains(i + step) else { return }
        var next = members; next.swapAt(i, i + step)
        var sch = scheme; sch.parked.removeAll { $0 == id }
        transition(to: next, current: current, scheme: sch, spring: Self.queueSpring, reason: "queue-swipe")
    }

    // MARK: Queue drag (reference §E 拖拽; f037, f063, f064)

    /// A member pressed in the dock: where, the working set before (the model does not change until the drop), and
    /// where it would land now.
    struct Drag {
        let id: String, start: CGPoint
        var pointerOffset=CGPoint.zero
        var headerOrigin=false
        var began = false, insertAt = 0
        let before: [Conversation], beforeCurrent: String
    }
    /// The product's queue spring (Tuning queueResponse / queueDamping) and the landing preview's (OrganicDockBridge).
    static var queueSpring: (response: Double, damping: Double) { Tuning.shared.queueSpring }

    /// A press on the dock. Returns whether it may become a drag; the release then says whether it was a click.
    func pointerDown(_ p: CGPoint, member: String? = nil) -> Bool {
        pressFromPointer = false; pressCancelled = false; buttonUpSince = nil
        guard drag == nil, tearing == nil, let id = member ?? dock.draggable(at: p),
              member == nil || (members.contains { $0.id == id } && dock.items[id] != nil) else { return false }
        drag = Drag(id: id, start: p, before: members, beforeCurrent: current)
        // A header press acts at the corresponding bar grip. Preserve pointer deltas, x insertion,
        // and all Dock decisions. Paint and tear tests retain the physical pointer.
        if member != nil || dock.hasHeaderReturn(id), let item=dock.items[id] {
            let grip=dock.hasHeaderReturn(id) ? CGPoint(x:item.target.midX,y:item.target.minY):(item.identityOpacity.to>0 ? CGPoint(x:item.identityFrame.midX,y:item.identityFrame.midY):CGPoint(x:item.glass.frame.midX,y:item.glass.frame.minY))
            drag?.pointerOffset=CGPoint(x:grip.x-p.x,y:grip.y-p.y)
            drag?.headerOrigin=true
        }
        // me only moves after 6 pt; a press that stays put is a click on the account (NativeDockScene down).
        guard id != DockNode.meID else { meController.setDragging(true); return true }
        // A long press (0.25 s) or 8 pt of movement picks it up (Tuning tearLongPress, tearDragThreshold).
        let w = DispatchWorkItem { [weak self] in self?.beginDrag(at: p) }
        longPress = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        return true
    }

    func pointerDragged(_ pointer: CGPoint) {
        guard let d = drag else { return }
        let p=pointer.offsetBy(d.pointerOffset)
        if d.id == DockNode.meID {
            if !d.began, hypot(pointer.x - d.start.x, pointer.y - d.start.y) >= 6 {
                drag?.began = true; setPeeking(nil); dock.holdMe(at: d.start); clock.keepRunning = true
            }
            if drag?.began == true {
                dock.moveMe(to: p)
                // Over a bar or orb it would land on: an alignment tick, once per target (f195).
                let target = dock.meTarget(at: p)
                if target != meHoverTarget { meHoverTarget = target; if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) } }
            }
            return
        }
        if !d.began, hypot(pointer.x - d.start.x, pointer.y - d.start.y) >= 8 { beginDrag(at: pointer) }
        guard var d = drag, d.began else { return }
        if tearing != nil { onTear?(.move(pointer)); return }
        // Out of the window, or 90 pt off the dock's row (the raw pointer, not the damped node): it tears loose (f182).
        let row = d.headerOrigin ? d.start.y : (scheme.mode == .focused ? (dock.capsule?.midY ?? layout.me.midY) : layout.me.midY)
        dock.moveHeld(to: pointer)
        if onTear != nil, !CGRect(origin: .zero, size: size).contains(pointer) || abs(pointer.y - row) > 90 { beginTear(d, at: pointer, row: row); return }
        runClock(until: max(ends, now() + 0.6))
        // Focused / Split previews nothing while carrying: the drop decides (OrganicDockBridge.updateQueueDrag).
        guard scheme.mode == .auto else { return }
        let at = insertion(at: p.x, dragging: d.id)
        guard at != d.insertAt else { return }
        d.insertAt = at; drag = d
        let landing = self.landing(d)
        commit(prepare(members: landing.members, current: landing.current, at: now(), spring: Self.previewSpring), reason: "drag-preview", prewarmed: false, start: CACurrentMediaTime())
    }

    /// Whether the press was a drag (it is dropped where its preview stands) rather than a click.
    func pointerUp(_ pointer: CGPoint) -> Bool {
        longPress?.cancel(); longPress = nil
        meController.setDragging(false)
        guard let d = drag else { return false }
        let p=pointer.offsetBy(d.pointerOffset)
        drag = nil
        guard d.began else { return false }
        if tearing != nil { onTear?(.drop(pointer)); return true }
        if d.id == DockNode.meID {
            // Dropped on a bar or orb: Focused on it. In Focused, dropped out of the capsule (44 pt round it): Auto.
            clock.keepRunning = false
            let target = dock.meTarget(at: p)
            dock.releaseMe()
            if scheme.mode == .auto, let target { enterFocused(target, reason: "me-drop") }
            else if scheme.mode == .focused, let capsule = dock.capsule {
                // On a Split divider: Compare (asked, unless "Don't ask again"); out of the capsule: Auto; else home.
                if scheme.split.count > 1, let i = dock.dividers.firstIndex(where: { abs($0 - p.x) < 22 && abs(p.y - capsule.midY) < 30 }) {
                    if UserDefaults.standard.bool(forKey: "compare.neverAsk") { startCompare(at: i) } else { askCompare(at: i) }
                } else if !capsule.insetBy(dx: -44, dy: -44).contains(p) {
                    leaveFocused(reason: "me-drag-out")
                } else {
                    compare = nil; dock.setMeDivider(nil)
                    if let i = layout.bars.firstIndex(where: { $0.contains(p) }), scheme.split.indices.contains(i) { focusMember(scheme.split[i]) }
                }
            }
            runClock(until: max(ends, dock.meSettles))
            return true
        }
        dock.moveHeld(to: pointer)
        let proposed = self.landing(d)
        let (proposedLayout,proposedOrder) = arrange(proposed.members,current:proposed.current)
        let staysInColumn:Bool
        if scheme.mode == .focused {
            let capsule=dock.capsule ?? .zero
            staysInColumn=scheme.split.contains(d.id) ? (scheme.split.count==1 || capsule.insetBy(dx:-8,dy:-44).contains(p)):capsule.insetBy(dx:-24,dy:-24).contains(p)
        } else {staysInColumn=proposedOrder.prefix(proposedLayout.columns.count).contains(d.id)}
        dock.release(toHeader:d.headerOrigin && staysInColumn)
        clock.keepRunning = false
        defer {onTarget?(focusTarget)}
        if scheme.mode == .focused {
            // Into the capsule: a segment there (graft); a segment out of it: an orb again (ungraft); else back.
            let capsule = dock.capsule ?? .zero
            if !scheme.split.contains(d.id), capsule.insetBy(dx: -24, dy: -24).contains(p) {
                var f = FocusLayout(); f.segments = layout.bars
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                graft(d.id, at: f.graftIndex(at: p.x), reason: "drag-graft")
            } else if scheme.split.count>1,scheme.split.contains(d.id), !capsule.insetBy(dx: -8, dy: -44).contains(p) {
                ungraft(d.id, reason: "drag-ungraft")
            } else {
                transition(to: members, current: current, scheme: scheme, spring: Self.queueSpring, reason: "drag-back")
            }
            return true
        }
        let landing = self.landing(d)
        commit(prepare(members: landing.members, current: landing.current, at: now(), spring: Self.queueSpring), reason: "drag-drop", prewarmed: false, start: CACurrentMediaTime())
        return true
    }

    /// Escape: everything goes back to where it was before the press.
    func cancelDrag() {
        longPress?.cancel(); longPress = nil
        guard let d = drag else { return }
        drag = nil
        pressCancelled = true
        guard d.began else { return }
        if tearing != nil { onTear?(.cancel); return }
        if d.id == DockNode.meID { clock.keepRunning = false; dock.releaseMe(); runClock(until: dock.meSettles); return }
        dock.release(toHeader:d.headerOrigin); clock.keepRunning = false
        commit(prepare(members: d.before, current: d.beforeCurrent, at: now(), spring: Self.queueSpring), reason: "drag-cancel", prewarmed: false, start: CACurrentMediaTime())
    }

    var isDragging: Bool { drag?.began == true }
    /// A release that never reaches this window (another app took the pointer mid-drag) would leave the press held for
    /// good, and a tear's panel on screen with it. The button stays up a moment first: the release may still be queued.
    func endPressIfButtonReleased() {
        guard pressFromPointer, drag != nil, pressedButtons() == 0 else { buttonUpSince = nil; return }
        let t = CACurrentMediaTime()
        guard let since = buttonUpSince else { buttonUpSince = t; return }
        if t - since > 0.2 { buttonUpSince = nil; cancelDrag() }
    }

    // MARK: Tear (f182–f186; docs/reference/TEAR-SPEC-26102909.md)

    /// A held node out of the dock: where it left (the press, the dock's row), then the pointer, the drop, or Esc. The
    /// app's TearSession carries it across windows; `endTear` says how it ended.
    enum TearEvent { case begin(id: String, pointer: CGPoint, row: CGFloat, press: CGPoint), move(CGPoint), drop(CGPoint), cancel }
    var isTearing: Bool { tearing != nil }

    private func beginTear(_ d: Drag, at p: CGPoint, row: CGFloat) {
        tearing = (d.id, d.before, d.beforeCurrent)
        tearBeforeScheme=scheme
        if d.headerOrigin {dock.heldFrame(at:now())}
        dock.release(forTear:true); clock.keepRunning = false
        dock.setHidden(d.id, true)
        // The gap closes: the others' arrangement (OrganicDockBridge.othersArrangement), the held node invisible.
        let others = d.before.filter { $0.id != d.id }
        if !others.isEmpty {
            var current = d.beforeCurrent == d.id ? others[0].id : d.beforeCurrent
            var next=scheme
            if next.mode == .focused {
                let slot=next.split.firstIndex(of:d.id) ?? 0
                next.split.removeAll{$0==d.id}
                next.left.removeAll{$0==d.id};next.right.removeAll{$0==d.id}
                if next.split.isEmpty {
                    // Removing the last Focused segment returns the surviving members to Auto, as remove does.
                    next=Scheme(parked:(autoSnapshot?.parked ?? []).filter { parked in
                        parked != current && others.contains{$0.id==parked}
                    })
                } else if !next.split.contains(current) {current=next.split[min(slot,next.split.count-1)]}
            }
            commit(prepare(members: others, current: current, scheme:next,at: now(), spring: Tuning.shared.autoSpring), reason: "tear-gap", prewarmed: false, start: CACurrentMediaTime())
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onTear?(.begin(id: d.id, pointer: p, row: row, press: d.start))
        if tearing == nil {cancelDrag()}
    }

    /// The tear is over. `kept`: it came back (Esc, a drop on its own row, nowhere to go): the gap reopens on the queue
    /// spring. Otherwise it went to another window: it stays out of this one.
    func endTear(kept: Bool) {
        guard let t = tearing else { return }
        tearing = nil
        let before=tearBeforeScheme;tearBeforeScheme=nil
        dock.setHidden(t.id, false)
        dock.endHeaderTear(kept:kept)
        guard kept else {
            if before?.mode == .focused,scheme.mode == .auto {autoSnapshot=nil}
            return
        }
        commit(prepare(members: t.before, current: t.current,scheme:before,at: now(), spring: Self.queueSpring), reason: "tear-back", prewarmed: false, start: CACurrentMediaTime())
    }

    /// A conversation dropped here from another window (Merge): inserted where it was dropped and made current.
    func receive(_ c: Conversation, at index: Int) {
        guard !members.contains(where: { $0.id == c.id }) else { return }
        var next = members
        next.insert(c, at: min(max(0, index), next.count))
        let start = CACurrentMediaTime()
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="receive"
        commit(prepare(members: next, current: c.id, at: now(), spring: Self.queueSpring), reason: "merge", prewarmed: false, start: start)
    }

    /// The member whose dock node (a bar's grip, an orb) is under `p`, if any.
    func dockNode(at p: CGPoint) -> String? { dock.hoverNode(at: p)?.id }

    /// How many of the dock's bars and orbs are left of `x` (TearSession's insertion index).
    func insertionIndex(at x: CGFloat) -> Int { (layout.bars + layout.orbs).filter { $0.midX < x }.count }
    /// The dock node under a press, held or about to be (Space then collapses to it, f050).
    var pressedNode: String? { drag.map(\.id).flatMap { $0 == DockNode.meID ? nil : $0 } }

    private func beginDrag(at p: CGPoint) {
        guard var d = drag, !d.began else { return }
        longPress?.cancel(); longPress = nil
        d.began = true
        reorderTextCandidate=d.id
        d.insertAt = order.firstIndex(of: d.id) ?? 0
        drag = d
        for other in prewarmed.values { unstage(other) }
        prewarmed = [:];lastPrewarmClear="beginDrag"
        setPeeking(nil)
        dock.hold(d.id, at: p, now: now(), spring: Self.queueSpring, header: d.headerOrigin ? nodes[d.id]?.island:nil, originRow:d.start.y)
        // Picked up (f195): the trackpad's generic tap; the system setting can turn it off, the visuals stand alone.
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        clock.keepRunning = true
    }

    /// Where the held member would go: how many of the others' bars and orbs (laid out without it) are left of `x`.
    private func insertion(at x: CGFloat, dragging id: String) -> Int {
        let others = (drag?.before ?? members).filter { $0.id != id }
        let (l, _) = arrange(others, current: drag?.beforeCurrent ?? current)
        return (l.bars + l.orbs).filter { $0.midX < x }.count
    }

    /// The working set if it landed now (WindowModel.landing): the others in their display order with the held one at
    /// `insertAt`. A full member dropped where it would be an orb passes full width to the first other one.
    private func landing(_ d: Drag) -> (members: [Conversation], current: String) {
        guard let held = d.before.first(where: { $0.id == d.id }) else { return (d.before, d.beforeCurrent) }
        var list = d.before.filter { $0.id != d.id }
        let others = arrange(list, current: d.beforeCurrent).1
        if d.insertAt < others.count, let i = list.firstIndex(where: { $0.id == others[d.insertAt] }) { list.insert(held, at: i) } else { list.append(held) }
        var full = d.beforeCurrent
        if full == d.id {
            let (l, _) = arrange(list, current: d.id)
            if let i = list.firstIndex(where: { $0.id == d.id }), i >= l.columns.count { full = list.first { $0.id != d.id }?.id ?? full }
        }
        return (list, full)
    }

    var dockFrames: [CGRect] { dock.nodeFrames }
    var peekCapsuleFrame: CGRect? { dock.peekCapsuleFrame }
    /// The bars' frames on screen, in slot order.
    var barFrames: [CGRect] { order.prefix(layout.bars.count).compactMap { dock.items[$0]?.glass.frame } }
}

private extension CGPoint {
    func offsetBy(_ offset:CGPoint)->CGPoint {CGPoint(x:x+offset.x,y:y+offset.y)}
}
