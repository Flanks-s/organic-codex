import AppKit
import QuartzCore

enum OrbDockBank: Equatable { case left, right, parked }

extension AutoScene {
    var sizeForOrb: CGSize { sceneView.bounds.size }
    private func orbFocusedEditor() -> String? {
        let id = focusTarget
        guard let responder = sceneView.window?.firstResponder as? NSView,
              let composer = composers.existingComposer(for:id),responder.isDescendant(of:composer) else { return nil }
        return id
    }
    private func followOrbEditor(_ previous: String?) {
        guard let previous,previous != current,let c = conversation(current),!c.archived else { return }
        composer(for:c).focus()
    }
    func orbInputTarget(at p: CGPoint) -> String? {
        if let id = orbFlights.hit(at:p) { return id }
        if peekNode.headerVisible, let id = shownPeek,
           peekNode.view.convert(peekNode.header.draggableOrbRect, from: peekNode.header).contains(p) { return id }
        for column in columns {
            if let island = column.island, !island.isHiddenOrHasHiddenAncestor,
               dockView.convert(island.draggableOrbRect, from: island).contains(p) { return column.conversation.id }
        }
        return dock.hoverNode(at: p).flatMap { $0.orb ? $0.id : nil }
    }
    func orbEndpoint(_ id: String) -> CGRect? {
        if let column = columns.first(where: { $0.conversation.id == id }), let island = column.island {
            return dockView.convert(island.draggableOrbRect, from: island)
        }
        return dock.frame(of: id)
    }
    func orbPose(_ id: String) -> CGRect? {
        if let flight = orbFlights.pose(id) { return flight }
        if peekNode.headerVisible,shownPeek == id { return dockView.convert(peekNode.header.draggableOrbRect,from:peekNode.header) }
        return orbEndpoint(id)
    }

    @discardableResult func routeOrbInput(_ event: NSEvent, ordinary: @escaping (CGPoint) -> Void) -> Bool {
        guard let id = orbInputTarget(at: dockView.convert(event.locationInWindow, from: nil)) else { return false }
        if shownPeek == id,peekNode.headerVisible,OrbGesturePolicy.action(event) == .ordinary {
            return orbInput.begin(event,id:id,ordinary:{ [weak self] point in _=self?.peekClick(at:point) })
        }
        return orbInput.begin(event, id: id, ordinary: ordinary)
    }
    func openOrbMenu(_ id: String, at p: CGPoint, event: NSEvent) {
        guard drag == nil, tearing == nil, let c = conversation(id), !c.archived else { return }
        orbInput.attach(event.window ?? sceneView.window)
        peekTimer?.cancel(); peekTimer = nil
        orbMenu.present(c, at: p, in: overlayPlane, right: event.type == .rightMouseDown || event.modifierFlags.contains(.control))
    }
    func bounceOrb(_ id: String) {
        guard let rect = orbPose(id), let c = conversation(id) else { return }
        orbFlights.start(c, from: rect, to: rect, incoming: true, fixed: true)
        orbFlights.flights[id]?.vy -= 110
    }
    func swapOrb(_ id: String, into targetID: String? = nil) {
        guard let c = conversation(id), !c.archived, members.contains(where: { $0 === c }) else { return }
        let editing = orbFocusedEditor()
        if scheme.draft, targetID == nil || targetID == Self.draftID {
            if hasUnboundDraft { bounceOrb(id); return }
            // The empty draft has no occupant to demote. The incoming conversation takes its full slot.
            let origin = orbPose(id), slot = layout.fullColumn
            let sourceWasColumn = columns.contains { $0.conversation.id == id }
            closeDraftForSwitch()
            if sourceWasColumn {
                transition(to:order.compactMap(conversation),current:id,scheme:scheme,spring:Tuning.shared.autoSpring,reason:"orb-swap")
                orbSwapLearned = true
                followOrbEditor(editing)
                return
            }
            var ids = order.filter { $0 != id }
            var next = scheme; next.parked.removeAll { $0 == id }
            ids.insert(id,at:min(ids.count,slot))
            transition(to:ids.compactMap(conversation),current:id,scheme:next,spring:Tuning.shared.autoSpring,reason:"orb-swap")
            orbSwapLearned = true
            if let origin, let end = orbEndpoint(id), !Motion.reduce { orbFlights.start(c,from:origin,to:end,incoming:true) }
            followOrbEditor(editing)
            return
        }
        if targetID == nil,scheme.mode == .focused,scheme.split.contains(id) { bounceOrb(id); return }
        let target = targetID ?? (scheme.mode == .focused ? focusTarget : current)
        if target == id { bounceOrb(id); return }
        let shown = columns.map { $0.conversation.id }
        // Normalize Auto's logical order before exchanging slots, including a promoted tail member.
        let ordered = scheme.mode == .auto ? order : members.map(\.id)
        guard var plan = OrbSwitchPlan.make(source: id, target: target, members: ordered, current: scheme.mode == .focused ? focusTarget:current,
                                            scheme: scheme, columns: shown, explicitColumn: targetID != nil) else { return }
        if scheme.mode == .focused, targetID == nil { plan.current = id }
        let sourceRect = orbPose(id), targetRect = orbPose(target), sourceWasColumn = shown.contains(id)
        dismissPeek()
        transition(to: plan.members.compactMap(conversation), current: plan.current, scheme: plan.scheme,
                   spring: scheme.mode == .focused ? Self.focusSpring : Tuning.shared.autoSpring, reason: "orb-swap")
        // Focused's return snapshot follows the same exchange, so leaving Focused does not resurrect old slots.
        if !sourceWasColumn, var snapshot = autoSnapshot,
           let a = snapshot.members.firstIndex(where: { $0.id == id }), let b = snapshot.members.firstIndex(where: { $0.id == target }) {
            snapshot.members.swapAt(a,b)
            if snapshot.current == target { snapshot.current = id }
            snapshot.parked = snapshot.parked.map { $0 == id ? target : ($0 == target ? id : $0) }
            autoSnapshot = snapshot
        }
        orbSwapLearned = true
        if !sourceWasColumn, !Motion.reduce {
            if let sourceRect, let end = orbEndpoint(id) { orbFlights.start(c, from: sourceRect, to: end, incoming: true) }
            if let targetRect, let end = orbEndpoint(target), let outgoing = conversation(target) { orbFlights.start(outgoing, from: targetRect, to: end, incoming: false) }
        }
        followOrbEditor(editing)
    }
    func performOrbAction(_ action: OrbMenuAction, conversation c: Conversation, column: String?, anchor: CGPoint) {
        guard conversation(c.id) === c, !c.archived, members.contains(where: { $0 === c }) else { return }
        switch action {
        case .swap: if let column { swapOrb(c.id, into: column) }
        case .focused:
            let editing = orbFocusedEditor()
            dismissPeek()
            compare = nil; compareAsk = nil; dock.setMeDivider(nil)
            if isFocused {
                var next = scheme
                let old = next.split.filter { $0 != c.id }
                next.split = [c.id]; next.left.removeAll { $0 == c.id }; next.right.removeAll { $0 == c.id }
                next.right = old + next.right
                transition(to: members, current: c.id, scheme: next, spring: Self.focusSpring, reason: "orb-focused")
            } else { enterFocused(c.id, reason: "orb-menu") }
            followOrbEditor(editing)
        case .peek:
            if let p = dock.frame(of: c.id), dock.items[c.id]?.role == .orb { peekOrigin = p; setPeeking(c.id) }
            else {
                // A menu Peek reads the same summary above its existing bar; it never replaces the editor or column.
                orbMenuPeekColumn = c.id
                setPeeking(c.id)
            }
        case .rename, .customize: customize(c.id)
        case .archive: archiveOrb(c, at: anchor)
        case .fork:
            let origin = orbPose(c.id)
            guard let onForkWhole else { orbToast.present("Fork is unavailable",anchor:anchor,in:overlayPlane); return }
            // This seam deliberately cannot call the message-level fork that supplies beforeTurnId.
            onForkWhole(c,OrbWholeForkRequest(threadID:c.backendThreadID ?? c.id)) { [weak self, weak c] result in
                guard let self, let c, self.conversation(c.id) === c, !c.archived,
                      self.members.contains(where: { $0 === c }) else { return }
                let pose = self.orbPose(c.id) ?? origin
                switch result {
                case .success(let fork):
                    self.addOrbToDock(fork, at: self.order.count, origin: pose, reason: "orb-fork")
                case .failure(let error):
                    let point = pose.map { CGPoint(x:$0.midX,y:$0.midY) } ?? anchor
                    self.orbToast.present(error.localizedDescription,anchor:point,in:self.overlayPlane)
                }
            }
        case .remove: _=orbTrash.remove(c.id,source:.contextMenu)
        case .sidechat: break
        }
    }
    struct OrbArchivePosition {
        let conversation: Conversation
        let members: [Conversation], current: String, scheme: Scheme
        let columnIDs: [String]
        let snapshot: (members: [Conversation], current: String, parked: [String])?
        let dockIndex: Int, anchor: CGPoint
        let identityIndex: Int, identitySymbol: String?, identityTint: String?
        var removedMembers: [String] = [], removedScheme = Scheme(), removedCurrent = ""
        var removedColumns: [String] = []
        var undoRequested = false
    }
    func archiveOrb(_ c: Conversation, at point: CGPoint) {
        let editing = orbFocusedEditor()
        let rect = orbPose(c.id)
        let n = layout.columns.count
        orbArchivePositions[c.id] = OrbArchivePosition(conversation:c,members:members,current:current,scheme:scheme,columnIDs:columns.map{$0.conversation.id},
            snapshot:autoSnapshot,dockIndex:max(0,(order.firstIndex(of:c.id) ?? n)-n),anchor:point,
            identityIndex:c.identityIndex,identitySymbol:c.identitySymbol,identityTint:c.identityTint)
        if let archive = islandActions?.archive { archive(c,true) }
        else if !c.isLiveConversation { c.archived = true; store.changed(c) }
        else { orbArchivePositions.removeValue(forKey:c.id); orbToast.present("Archive is unavailable",anchor:point,in:overlayPlane); return }
        if c.archived, let rect { orbFlights.start(c,from:rect,to:rect,incoming:true,collapse:true) }
        if c.archived { followOrbEditor(editing) }
    }
    func orbDidArchive(_ id: String) {
        guard var saved = orbArchivePositions[id] else { return }
        saved.removedMembers = members.map(\.id); saved.removedScheme = scheme; saved.removedCurrent = current
        saved.removedColumns = columns.map{$0.conversation.id}
        orbArchivePositions[id] = saved
        orbToast.present("Archived \(saved.conversation.title)",anchor:saved.anchor,in:overlayPlane,undo:{ [weak self] in self?.undoOrbArchive(id) })
    }
    func undoOrbArchive(_ id: String) {
        guard var saved = orbArchivePositions[id], conversation(id) === saved.conversation, saved.conversation.archived else { return }
        saved.undoRequested = true; orbArchivePositions[id] = saved
        if let archive = islandActions?.archive { archive(saved.conversation,false) }
        else if !saved.conversation.isLiveConversation { saved.conversation.archived = false; store.changed(saved.conversation) }
    }
    @discardableResult func restoreOrbArchive(_ c: Conversation) -> Bool {
        guard let saved = orbArchivePositions.removeValue(forKey:c.id), c === saved.conversation else { return false }
        let editing = orbFocusedEditor()
        let origin = orbFlights.pose(c.id)
        archivedOut.remove(c.id); archiveToast.dismiss()
        let identity = ConversationIdentity.resolved(index:saved.identityIndex,symbol:saved.identitySymbol,tint:saved.identityTint)
        let occupied = store.conversations.contains { other in
            other !== c && !other.archived && ConversationIdentity.resolved(index:other.identityIndex,symbol:other.identitySymbol,tint:other.identityTint) == identity
        }
        if occupied { c.identityIndex = store.nextIdentity(); c.identitySymbol = nil; c.identityTint = nil }
        else { c.identityIndex = saved.identityIndex; c.identitySymbol = saved.identitySymbol; c.identityTint = saved.identityTint }
        // A failed archive rolls back through the same store publication as a successful Undo.
        var restored = false
        if members.map(\.id) == saved.removedMembers, scheme == saved.removedScheme, current == saved.removedCurrent {
            autoSnapshot = saved.snapshot
            transition(to:saved.members,current:saved.current,scheme:saved.scheme,spring:Tuning.shared.autoSpring,reason:"orb-unarchive")
            restored = true
        } else if saved.columnIDs.contains(c.id),columns.map({$0.conversation.id}) == saved.removedColumns,
                  scheme.mode == saved.scheme.mode,scheme.draft == saved.scheme.draft {
            // Unrelated Dock arrivals do not destroy a reserved column slot.
            let available = Set(members.map(\.id)+[c.id])
            let ids = saved.columnIDs + order.filter { !saved.columnIDs.contains($0) }
            var next = scheme
            if isFocused { next.split = saved.scheme.split.filter(available.contains) }
            let full = current == saved.removedCurrent ? saved.current:current
            let models = ids.compactMap(conversation)
            let trial = arrange(models,current:full,scheme:next)
            if saved.columnIDs.allSatisfy(available.contains),Array(trial.1.prefix(trial.0.columns.count)) == saved.columnIDs {
                transition(to:models,current:full,scheme:next,spring:Tuning.shared.autoSpring,reason:"orb-unarchive-slot")
                restored = true
            }
        }
        if restored {
            if let origin,let end = orbEndpoint(c.id),!Motion.reduce { orbFlights.start(c,from:origin,to:end,incoming:true) }
        } else {
            var bank: OrbDockBank?, index = saved.dockIndex
            if scheme.mode == saved.scheme.mode {
                if let k = saved.scheme.left.firstIndex(of:c.id) { bank = .left; index = k }
                else if let k = saved.scheme.right.firstIndex(of:c.id) { bank = .right; index = k }
                else if let k = saved.scheme.parked.firstIndex(of:c.id) { bank = .parked; index = k }
            }
            addOrbToDock(c,at:index,origin:origin,reason:"orb-unarchive-fallback",bank:bank)
        }
        if occupied { onIdentityChanged?(c) }
        followOrbEditor(editing)
        return true
    }
    func addOrbToDock(_ c: Conversation, at index: Int, origin: CGRect?, reason: String, bank: OrbDockBank? = nil) {
        guard !members.contains(where: { $0.id == c.id }), !c.archived else { return }
        let n = layout.columns.count
        var ids = order; ids.insert(c.id,at:min(ids.count,n+max(0,index)))
        joining = c; defer { joining = nil }
        var next = scheme
        if scheme.mode == .focused {
            let left = bank == .left || bank == nil && next.left.count < next.right.count
            if left { next.left.insert(c.id,at:min(next.left.count,max(0,index))) }
            else { next.right.insert(c.id,at:min(next.right.count,max(0,index))) }
        }
        else {
            if bank == .parked {
                var parked = next
                parked.parked.insert(c.id,at:min(parked.parked.count,max(0,index)))
                let trial = arrange(ids.compactMap(conversation),current:current,scheme:parked)
                if Array(trial.1.prefix(trial.0.columns.count)) == columns.map({$0.conversation.id}) { next = parked }
            }
            let trial = arrange(ids.compactMap(conversation),current:current,scheme:next)
            if trial.1.prefix(trial.0.columns.count).contains(c.id) { next.parked.append(c.id) }
        }
        transition(to:ids.compactMap(conversation),current:current,scheme:next,spring:Tuning.shared.autoSpring,reason:reason)
        if let origin, let end = orbEndpoint(c.id), !Motion.reduce { orbFlights.start(c,from:origin,to:end,incoming:true) }
    }
}
