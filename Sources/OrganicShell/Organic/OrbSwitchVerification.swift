import AppKit

#if !M10_DOCK_SELFTEST && !ORGANIC_SELFTEST && !ORB_SELFTEST && !ISLAND_SELFTEST && !M9_SPLIT_SELFTEST && !M11_MODE_SELFTEST
@MainActor enum OrbSwitchVerification {
    static func verifyForkEnabled(check: (Bool,String) -> Void) {
        let clock = OverlayManualClock()
        let menu = OrbContextMenuState(clock: clock)
        var actions: [OrbMenuAction] = []
        menu.execute = { action, _ in actions.append(action) }
        menu.open(columns: []); clock.advance(by: 0.2)
        check(OrbMenuAction.fork.enabled, "whole-history Fork is enabled")
        menu.hover(row: OrbMenuAction.fork.rawValue)
        check(menu.selected == OrbMenuAction.fork.rawValue, "Fork can be hovered and selected")
        menu.choose(); clock.advance(by: 0.1)
        check(!menu.isOpen && actions == [.fork], "clicking Fork executes once and closes the menu")
        menu.open(columns: []); clock.advance(by: 0.2)
        menu.hover(row: OrbMenuAction.customize.rawValue); menu.key(125)
        check(menu.selected == OrbMenuAction.fork.rawValue, "Down skips Sidechat and reaches Fork")
        menu.key(126)
        check(menu.selected == OrbMenuAction.customize.rawValue, "Up from Fork skips Sidechat")
        menu.hover(row: OrbMenuAction.fork.rawValue); menu.choose(rightRelease: true); clock.advance(by: 0.1)
        check(!menu.isOpen && actions == [.fork,.fork], "held right release executes Fork once")
        menu.open(columns: []); clock.advance(by: 0.2)
        var visited: [Int] = []
        for _ in 0..<8 { menu.key(125); if let selected = menu.selected { visited.append(selected) } }
        check(visited == [0,1,2,3,4,6,7,8], "keyboard cycle includes eligible Remove and skips Sidechat")
        menu.dismiss()
    }
    static func run(check: (Bool,String) -> Void) {
        verifyForkEnabled(check: check)
        let clock = OverlayManualClock(), menu = OrbContextMenuState(clock:OverlayManualClock())
        // Every scheduled boundary uses the same deterministic clock as production state.
        let state = OrbContextMenuState(clock:clock)
        let columns = (0..<3).map { OrbContextMenuState.Column(id:"\($0)",name:"Chat \($0)",checked:$0 == 1) }
        var actions: [OrbMenuAction] = []
        state.execute = { action,_ in actions.append(action) }
        state.open(columns:columns); clock.advance(by:0.05)
        check(OrbMenuAction.allCases.count == 9 && OrbMenuAction.allCases.filter { !$0.enabled } == [.sidechat],"nine menu rows, only Sidechat statically disabled; Remove uses eligibility")
        state.hover(row:0); clock.advance(by:0.119); check(!state.submenu,"119ms is before submenu dwell")
        clock.advance(by:0.001); check(state.submenu,"120ms opens submenu")
        state.hover(row:3,towardSubmenu:true); clock.advance(by:0.299); check(state.submenu,"triangle protects for 299ms")
        clock.advance(by:0.001); check(!state.submenu,"triangle expires at 300ms")
        state.hover(row:3); state.choose(); check(state.blinking && !state.highlightVisible,"selection starts with 50ms dark blink")
        clock.advance(by:0.05); check(state.highlightVisible && actions.isEmpty,"50ms light phase does not execute")
        state.dismiss(); clock.advance(by:1); check(actions.isEmpty,"cancelled blink never executes")
        state.open(columns:columns); clock.advance(by:0.05); state.hover(row:4); state.choose(); state.choose(); clock.advance(by:0.1)
        check(actions == [.customize],"double selection executes once after 50+50ms")
        state.open(columns:columns); clock.advance(by:0.179); state.hover(row:3); state.choose(rightRelease:true)
        check(!state.blinking,"right release at 179ms does not select")
        clock.advance(by:0.001); state.choose(rightRelease:true); check(state.blinking,"right release at 180ms selects")
        state.dismiss(); clock.advance(by:1)
        state.open(columns:columns); clock.advance(by:0.05); state.key(126)
        let eligibleLast=state.selected
        state.permits={ $0 != .remove };state.open(columns:columns);clock.advance(by:0.05);state.key(126)
        let ineligibleLast=state.selected
        state.permits=nil;state.open(columns:columns);clock.advance(by:0.05);state.key(126)
        check(eligibleLast == 8 && ineligibleLast == 7 && state.selected == 8,"up wraps through Remove exactly when shared eligibility permits")
        state.key(125); check(state.selected == 0,"down wraps to first item")
        state.key(124); check(state.submenu && state.selectedColumn == 0,"right opens immediately and skips checked row")
        state.key(125); check(state.selectedColumn == 2,"submenu skips its checked column")
        state.key(125); check(state.selectedColumn == 0,"submenu wraps")
        state.key(123); check(!state.submenu,"left closes child")
        state.key(48); check(state.isOpen,"Tab is swallowed")
        state.key(53); check(!state.isOpen && !state.submenu,"Escape closes both menus")
        for key: UInt16 in [36,76,49] {
            state.open(columns:columns); clock.advance(by:0.05); state.key(125); state.key(125); state.key(key); clock.advance(by:0.1)
            check(actions.last == .focused,"keyboard-only selection via \(key == 49 ? "Space":"Enter")")
        }
        for count in 1...3 {
            state.open(columns:Array(columns.prefix(count))); clock.advance(by:0.05); state.hover(row:0); state.key(124)
            check(state.columns.count == count,"submenu uses actual \(count) columns")
        }
        state.dismiss(); menu.dismiss()
        let bounds = CGRect(x:0,y:0,width:1280,height:820)
        for p in [CGPoint(x:0,y:0),CGPoint(x:1280,y:0),CGPoint(x:0,y:820),CGPoint(x:1280,y:820)] {
            let main = OrbMenuGeometry.main(at:p,in:bounds), child = OrbMenuGeometry.child(of:main,count:3,in:bounds)
            check(bounds.insetBy(dx:10,dy:10).contains(main),"main menu stays inside edge at \(p)")
            check(bounds.insetBy(dx:10,dy:10).contains(child),"submenu stays inside edge at \(p)")
            check(p.x < 100 || main.maxX <= p.x,"right-edge main flips left")
            check(p.y < 100 || main.maxY <= p.y,"bottom-edge main flips up")
        }
        let toast = OrbActionToast(clock:clock), host = NSView(frame:bounds)
        toast.present("Done",anchor:CGPoint(x:300,y:200),in:host)
        check(abs(toast.expiresAt-clock.now-2.4)<0.00001,"ordinary toast lasts 2.4s")
        clock.advance(by:2.4); clock.advance(by:0.08); check(toast.superview == nil,"toast removes after 80ms exit")
        var undo = 0; toast.present("Archived",anchor:CGPoint(x:300,y:200),in:host,undo:{undo+=1})
        check(abs(toast.expiresAt-clock.now-5)<0.00001,"Undo toast lasts 5s")
        toast.undo(); toast.undo(); check(undo == 1,"Undo executes once")
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            let clock = OverlayManualClock()
            f.scene.orbMenu = OrbContextMenu(scene:f.scene,clock:clock)
            let c = f.scene.members.last!, point = f.point(c.id)
            _ = f.dispatchedClick(at:point,right:true)
            let menu = f.scene.orbMenu
            let items = menu.main.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            check(menu.main.accessibilityRole() == .menu,"custom menu AX role is menu")
            check(items.count == 9 && items.allSatisfy { $0.accessibilityRole() == .menuItem },"nine AX menuItems")
            check(items.map { $0.accessibilityLabel() ?? "" } == OrbMenuAction.allCases.map(\.title),"AX names match painted row labels")
            let eligibleRemove=items.count == 9 && items[8].isAccessibilityEnabled()
            let permits=menu.state.permits
            menu.state.permits={ action in action != .remove && (permits?(action) ?? true) }
            // Advance scheduled product work until the actual input gate and replacement snapshot are ready.
            func until(_ ready:()->Bool)->Bool {
                let deadline=clock.now+1
                while !ready(),clock.now<deadline {clock.advance(by:min(1.0/120,deadline-clock.now))}
                return ready()
            }
            let inputReady=until {menu.state.acceptsInput}
            menu.state.hover(row:0)
            let refreshed=until {
                guard let old=items.first,
                      let next=(menu.main.accessibilityChildren() as? [NSAccessibilityElement])?.first else {return false}
                return next !== old
            }
            let ineligibleItems=menu.main.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            let ineligibleRemove=ineligibleItems.count == 9 && !ineligibleItems[8].isAccessibilityEnabled()
            menu.state.permits=permits
            menu.state.key(123)
            check(inputReady && refreshed && items.count == 9 && !items[5].isAccessibilityEnabled() && items[6].isAccessibilityEnabled() && eligibleRemove && ineligibleRemove,"AX Remove follows shared eligibility; Sidechat stays disabled")
            check(items.count == 9 && items[6].accessibilityPerformPress(), "AX press accepts Fork")
            check(menu.state.selected == 6 && menu.state.blinking, "AX Fork uses the shared selection blink")
            menu.dismiss(animated:false)
            _ = f.dispatchedClick(at:point,right:true); clock.advance(by:0.2)
            menu.state.hover(row:0); clock.advance(by:0.12)
            let childItems = menu.child.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            check(childItems.first?.accessibilityFrame() == NSAccessibility.screenRect(fromView:menu.child,rect:CGRect(x:5,y:5,width:290,height:24)),"submenu AX frame follows its flipped visible position")
            menu.state.key(123); clock.advance(by:0.079)
            check(!menu.child.isHidden && !menu.state.submenu,"submenu exit stays painted but stops taking input before 80ms")
            clock.advance(by:0.001)
            check(menu.child.isHidden,"submenu exit hides at 80ms")
            menu.state.key(124); menu.state.key(123); clock.advance(by:0.04); menu.state.key(124); clock.advance(by:0.04)
            check(menu.state.submenu && !menu.child.isHidden,"reopening child cancels its old exit scheduler")
            menu.state.hover(row:3); menu.state.choose()
            // Isolate the new notification owner; the window delegate must not make this assertion pass by disposing the scene.
            let window = f.dispatchWindow!, delegate = window.delegate; window.delegate = nil
            NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:window)
            window.delegate = delegate
            clock.advance(by:1)
            check(!menu.state.isOpen && !f.scene.customizeSheet.isShowing,"close cancels pending selection blink")
            _ = f.dispatchedClick(at:point,right:true)
            let old = f.scene.current
            let outside = CGPoint(x:20,y:400)
            let hit = f.scene.overlayPlane.hitTest(outside)
            _ = f.dispatchedClick(at:outside)
            check(hit === menu && !menu.state.isOpen && f.scene.current == old,"outside click hits shield, closes and never lands through it")
            clock.advance(by:0.08)
            _ = f.dispatchedClick(at:point,right:true)
            clock.advance(by:0.05); menu.state.hover(row:4); menu.state.choose()
            c.archived = true; f.app.store.changed(c); clock.advance(by:1)
            check(!menu.state.isOpen && !f.scene.customizeSheet.isShowing,"archive during open menu cancels target and pending action")
        }
        for width: CGFloat in [650,960,1280] {
            let f = OrbInputVerification.Fixture(width:width); defer { f.dispose() }
            let scene = f.scene, source = scene.order.last!, outgoing = scene.current, slot = scene.order.firstIndex(of:source)!
            let columns = scene.columns.map { $0.conversation.id }
            scene.swapOrb(source)
            check(scene.current == source && scene.order[slot] == outgoing,"\(columns.count)-column transaction trades exact slots")
            check(Set(scene.members.map(\.id)).count == 6,"transaction retains all members")
            let newSource = scene.order.last!
            scene.swapOrb(newSource)
            check(scene.current == newSource,"interrupted second click commits latest transaction")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            let scene = f.scene, source = scene.order.last!
            scene.enterFocused(scene.current,reason:"fixture"); f.settle()
            let outgoing = scene.current, oldLeft = scene.scheme.left, oldRight = scene.scheme.right
            scene.swapOrb(source)
            check(scene.scheme.split == [source] && scene.current == source,"Focused capsule swaps membership")
            check(scene.scheme.left == oldLeft.map { $0 == source ? outgoing:$0 } && scene.scheme.right == oldRight.map { $0 == source ? outgoing:$0 },"Focused outgoing takes source bank slot")
            scene.graft(scene.scheme.right.first!,at:1,reason:"fixture"); f.settle()
            let target = scene.focusTarget, other = scene.order.last!
            scene.swapOrb(other)
            check(scene.scheme.split.contains(other) && !scene.scheme.split.contains(target),"Split swaps its current segment")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            f.scene.newChat(); f.settle(); let id = f.scene.order.last!
            f.scene.draftComposer?.setText("Keep my draft")
            f.scene.swapOrb(id)
            check(f.scene.composingNew && f.scene.hasUnboundDraft,"nonempty New Chat refuses swap")
            check(f.scene.draftComposer?.text == "Keep my draft","refused swap preserves text")
            f.scene.draftComposer?.setText(""); f.scene.swapOrb(id)
            check(!f.scene.composingNew && f.scene.current == id,"empty New Chat is discarded for swap")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            f.scene.newChat(); f.settle()
            f.scene.draftComposer?.attachments = [Attachment(id:"fixture-attachment",name:"mock.txt",symbol:"doc")]
            let id = f.scene.order.last!
            f.scene.swapOrb(id)
            check(f.scene.composingNew && f.scene.draftComposer?.attachments.count == 1,"attachment-only draft refuses swap without losing attachment")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            let source = f.scene.members.last!, other = f.scene.members.first!, identity = orbIdentity(of:source)
            f.scene.archiveOrb(source,at:CGPoint(x:300,y:300))
            other.identityIndex = source.identityIndex; other.identitySymbol = source.identitySymbol; other.identityTint = source.identityTint
            f.scene.undoOrbArchive(source.id)
            check(orbIdentity(of:source) != identity && orbIdentity(of:other) == identity,"Undo allocates a free identity if original planet and color were taken")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            let source = f.scene.columns.first!.conversation, original = f.scene.columns.map{$0.conversation.id}
            f.scene.archiveOrb(source,at:CGPoint(x:300,y:300))
            let arrival = Conversation(id:"fixture-arrival",title:"Unrelated arrival")
            arrival.identityIndex = f.app.store.nextIdentity()
            f.app.store.add(arrival); f.scene.addOrbToDock(arrival,at:10,origin:nil,reason:"fixture-arrival")
            f.scene.undoOrbArchive(source.id)
            check(f.scene.columns.map({$0.conversation.id}) == original && f.scene.members.contains{$0 === arrival},"Undo retains its column slot after unrelated Dock arrival")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            f.scene.enterFocused("C",reason:"fixture"); f.settle()
            let sourceID = f.scene.scheme.left.first!, source = f.scene.conversation(sourceID)!
            f.scene.archiveOrb(source,at:CGPoint(x:300,y:300))
            let arrival = Conversation(id:"fixture-focused-arrival",title:"Unrelated arrival")
            f.app.store.add(arrival); f.scene.addOrbToDock(arrival,at:10,origin:nil,reason:"fixture-arrival")
            let columns = f.scene.columns.map{$0.conversation.id}
            f.scene.undoOrbArchive(sourceID)
            check(f.scene.scheme.left.first == sourceID && f.scene.columns.map({$0.conversation.id}) == columns,"Undo retains existing Focused left-bank slot after arrival")
        }
        do {
            let f = OrbInputVerification.Fixture(width:1600); defer { f.dispose() }
            var scheme = f.scene.scheme; scheme.parked = ["C"]
            f.scene.transition(to:f.scene.members,current:f.scene.current,scheme:scheme,spring:Tuning.shared.autoSpring,reason:"fixture-parked"); f.settle()
            let source = f.scene.conversation("C")!
            f.scene.archiveOrb(source,at:CGPoint(x:300,y:300))
            let arrival = Conversation(id:"fixture-parked-arrival",title:"Unrelated arrival")
            f.app.store.add(arrival); f.scene.addOrbToDock(arrival,at:10,origin:nil,reason:"fixture-arrival")
            let columns = f.scene.columns.map{$0.conversation.id}
            f.scene.undoOrbArchive(source.id)
            check(f.scene.scheme.parked.first == source.id && f.scene.columns.map({$0.conversation.id}) == columns,"Undo retains existing parked slot without displacing current columns")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            let c = f.scene.members.first!, before = f.scene.order
            f.scene.performOrbAction(.peek,conversation:c,column:nil,anchor:CGPoint(x:300,y:300))
            check(f.scene.shownPeek == c.id && f.scene.order == before,"menu Peek on column opens summary without replacing columns")
            f.scene.dismissPeek()
            f.scene.performOrbAction(.focused,conversation:c,column:nil,anchor:CGPoint(x:300,y:300))
            check(f.scene.isFocused && f.scene.scheme.split == [c.id],"Open in Focused enters real Focused layout")
        }
        do {
            let f = OrbInputVerification.Fixture(); defer { f.dispose() }
            let scene = f.scene, first = scene.current
            scene.enterFocused(first,reason:"fixture"); f.settle()
            let second = scene.scheme.right.first!
            scene.graft(second,at:1,reason:"fixture"); f.settle()
            scene.focusMember(first)
            check(scene.focusTarget == first,"Split fixture focuses actual first segment editor")
            let split = scene.scheme.split
            scene.swapOrb(second)
            check(scene.scheme.split == split && scene.focusTarget == first,"Option on already-full Split orb only bounces")
            let incoming = scene.order.last!
            scene.swapOrb(incoming)
            check(scene.scheme.split.contains(incoming) && !scene.scheme.split.contains(first),"Split swap targets native current instead of stale stored current")
            check(scene.focusTarget == incoming && f.owner.window.firstResponder === scene.composers.existingComposer(for:incoming)?.textView,"Split editing focus follows incoming conversation")
        }
        motion(check:check)
    }
    static func motion(check: (Bool,String) -> Void) {
        let screen = NSScreen.screens.first { s in
            let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
            return CGDisplayIsBuiltin(n.uint32Value) != 0
        }!
        let profile = DisplayProfile.of(screen), dt = profile.frameInterval
        for scale: CGFloat in [1,2] {
            let store = ConversationStore(); MockReplay(store:store).start(live:false)
            let scene = AutoScene(size:CGSize(width:1280,height:820),store:store,profile:profile,scale:scale)
            let host = NSView(frame:CGRect(x:0,y:0,width:1280,height:820))
            for view in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] { host.addSubview(view) }
            scene.manualSettle = true; scene.ambient = false
            var time = CACurrentMediaTime()+100
            scene.now = { time }; scene.dock.motionTime = { time }
            scene.install(members:["A","B","C","D","E","F"]); scene.clock.invalidate(); scene.settle()
            let original = scene.current, incoming = scene.order.last!
            scene.swapOrb(incoming)
            check(OrbSwitchFlight.duration == 0.580 && scene.orbFlights.flights[original]?.delay == 0.035,"580ms path and 35ms outgoing delay @\(scale)x")
            check(scene.orbFlights.flights[incoming]?.orb.glassView.layer?.zPosition == 12 && scene.orbFlights.flights[original]?.orb.glassView.layer?.zPosition == 11,"incoming z12 over outgoing z11 @\(scale)x")
            for _ in 0..<Int(0.18/dt) { time += dt; scene.clock.onFrame?(time) }
            let before = scene.orbFlights.flights[original]!, x = before.x, y = before.y, vx = before.vx, vy = before.vy
            scene.swapOrb(original)
            let after = scene.orbFlights.flights[original]!
            check(abs(after.x-x)<0.00001 && abs(after.y-y)<0.00001,"interruption preserves position @\(scale)x")
            check(abs(after.vx-vx)<0.00001 && abs(after.vy-vy)<0.00001,"interruption preserves velocity @\(scale)x")
            for _ in 0..<Int(2/dt) { time += dt; scene.clock.onFrame?(time) }
            check(scene.orbFlights.flights.isEmpty,"crossing flight retires at actual \(dt)s frame interval @\(scale)x")
            check(scene.columns.allSatisfy { $0.island?.orbIsCarried != true },"retirement releases real header orb @\(scale)x")
            scene.disposeTranscriptPresentation()
        }
    }
}
#endif
