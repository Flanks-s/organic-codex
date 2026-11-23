#if M1137_TRASH_CHECK
import AppKit
import QuartzCore

/// Input assertions use the production r4 DispatchWindow, postEvent, hitTest and responder dispatch.
@MainActor enum OrbTrashIntegrationVerification {
    static var checks=0, inputChecks=0, valueChecks=0
    static var findings:[String]=[], rows:[[String:Any]]=[]
    static func check(_ condition:Bool,_ label:String,input:Bool=true) {
        checks+=1;if input { inputChecks+=1 } else { valueChecks+=1 }
        rows.append(["name":label,"pass":condition,"kind":input ? "dispatch":"value"])
        if !condition { findings.append(label) }
    }
    @MainActor final class Fixture {
        let base:OrbInputVerification.Fixture
        let suite="trash-wiring-"+UUID().uuidString
        var lastDownPressed=false,lastDownHit=""
        var scene:AutoScene { base.scene }
        init(width:CGFloat=1280) {
            base=OrbInputVerification.Fixture(width:width)
            _=base.useAppKitDispatch()
            // Even a Tear-enabled mutant must never construct the application's floating panel.
            scene.onTear={ _ in }
            scene.orbTrash.preferences = .init(defaults:UserDefaults(suiteName:suite)!)
            scene.clock.invalidate()
        }
        func dispose() { base.dispose();UserDefaults.standard.removePersistentDomain(forName:suite) }
        func send(_ type:NSEvent.EventType,_ point:CGPoint) { base.dispatch(base.event(type,at:point)) }
        func advance(_ seconds:Double) {
            for _ in 0..<max(1,Int(seconds*60)) {
                base.time+=1/60
                if let due=scene.dock.tideLightProbe["nextWakeAt"] as? Double,due<=base.time { scene.dock.serviceTideDeadline() }
                scene.frame(base.time);scene.clock.invalidate()
            }
        }
        func down(_ id:String,offset:CGPoint = .zero)->CGPoint {
            let r=scene.orbPose(id)!,p=CGPoint(x:r.midX+offset.x,y:r.midY+offset.y)
            let event=base.event(.leftMouseDown,at:p)
            lastDownHit=base.useAppKitDispatch().contentView?.hitTest(event.locationInWindow).map {String(describing:type(of:$0))} ?? "none"
            base.dispatch(event);lastDownPressed=scene.orbInput.isPressed;return p
        }
        var can:CGPoint {
            .init(x:scene.dock.restingTargets.max(by:{$0.rect.maxX<$1.rect.maxX})!.rect.midX,y:scene.layout.me.midY-68)
        }
        @discardableResult func carry(_ id:String,offset:CGPoint = .zero)->CGPoint {
            let start=down(id,offset:offset)
            let p=CGPoint(x:can.x-52+offset.x,y:can.y+offset.y)
            if abs(p.y-start.y)<=OrbTrashParameters.reorderBand {
                send(.leftMouseDragged,.init(x:start.x,y:start.y-45));advance(0.15)
            }
            base.time+=0.02;send(.leftMouseDragged,p);advance(1.15)
            return p
        }
        func drop(_ id:String)->CGPoint { let p=carry(id);send(.leftMouseUp,p);advance(1.1);return p }
        func click(_ button:NSButton) {
            let rect=scene.dockView.convert(button.bounds,from:button)
            _=base.dispatchedClick(at:CGPoint(x:rect.midX,y:rect.midY))
        }
        func add(_ id:String)->Conversation {
            let c=Conversation(id:id,title:"Fixture arrival");scene.store.add(c);scene.admit(c,reason:"fixture-add");return c
        }
        func tide(_ id:String) {
            scene.dock.prepareTideMaterialNow()
            scene.store.apply(.init(id:10001,time:base.time,method:"turn/started",params:["threadId":.string(id),"turn":["id":"trash-fixture-turn"]]))
            scene.store.apply(.init(id:10002,time:base.time,method:"item/started",params:["threadId":.string(id),"turnId":"trash-fixture-turn","item":["id":"trash-fixture-command","type":"commandExecution","command":"fixture command"]]))
            advance(1)
        }
    }
    static func equal(_ a:OrganicMemberLayout,_ b:OrganicMemberLayout)->Bool {
        a.members.map(\.id)==b.members.map(\.id) && a.columns.map(\.member)==b.columns.map(\.member)
            && zip(a.columns,b.columns).allSatisfy { abs($0.weight-$1.weight)<1e-9 }
            && a.left==b.left && a.right==b.right && a.parked==b.parked && a.current==b.current
    }
    static func run()->[String:Any] {
        checks=0;inputChecks=0;valueChecks=0;findings=[];rows=[]
        OrganicFeatureAvailability.current.conversationOrbTear=false
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.current,p=f.down(id)
            var tears=0;s.onTear={ event in
                tears+=1
                if case .begin = event,ProcessInfo.processInfo.environment["M1137_LEGACY_ORDER_PROBE"] == "1" {
                    let panel=NSPanel(contentRect:.init(x:0,y:0,width:80,height:80),styleMask:.borderless,backing:.buffered,defer:false)
                    panel.isReleasedWhenClosed=false;panel.orderFrontRegardless()
                    check(!panel.isVisible,"window-ordering: legacy mocked panel never becomes visible",input:false)
                    panel.close()
                }
            }
            let q=CGPoint(x:p.x+8,y:p.y+140)
            f.send(.leftMouseDragged,q);f.advance(0.35)
            check(tears==0,"no-legacy-tear: dispatched header stays inside this window beyond 90pt")
            if tears>0 { f.base.key(53);return receipt() }
            let frame=s.dock.trashCarrier(id)?.rect
            check(frame.map{hypot($0.midX-q.x,$0.midY-q.y)<2} == true,"free-follow: header follows the complete vertical delta")
            f.base.key(53)
        }
        for kind in ["dock","full","brief","side","parked","peek"] {
            let f=Fixture();defer { f.dispose() }
            let s=f.scene
            if kind=="side" { s.enterFocused(s.current,reason:"fixture-side");f.base.settle() }
            if kind=="parked" { var next=s.scheme;next.parked=[s.order.last!];s.transition(to:s.members,current:s.current,scheme:next,spring:AutoScene.queueSpring,reason:"fixture-parked");f.base.settle() }
            let id=kind == "dock" || kind == "peek" ? s.order.last!:kind == "full" ? s.current:kind == "side" ? s.scheme.right.first!:kind == "parked" ? s.scheme.parked[0]:s.columns.last!.conversation.id
            if kind=="peek" { s.setPeeking(id);s.peekNode.setHeaderVisible(true,duration:0) }
            let original=s.orbTrash.project()!,c=s.store.conversation(id)!
            let identity=(c.identityIndex,c.identitySymbol,c.identityTint),running=c.running
            c.draft="Retained local draft"
            let itemCount=c.items.count
            var tears=0;s.onTear={ _ in tears+=1 }
            let p=f.carry(id)
            let anchor=s.dock.restingTargets.map{$0.rect}.max(by:{$0.maxX<$1.maxX})!.midX
            check(abs((s.orbTrash.output?.pose.can.midX ?? 0)-anchor)<=OrbTrashParameters.lean+0.01,"fixed-anchor: \(kind) uses the rightmost slot, independent of dictionary order")
            check(s.orbInput.isPressed && s.isDragging,"\(kind): r4 dispatch owns pickup")
            check(s.orbTrash.output?.pose.phase == .armed,"\(kind): free carrier reaches armed trash")
            check(s.orbTrash.ownershipChecks>0 && s.orbTrash.ownershipFailures==0,"single-owner: \(kind) never shows two applied native carriers")
            check(s.orbTrash.presentation.handoffDiscontinuity<1e-6,"single-owner: \(kind) inherits this batch pose exactly")
            check(tears==0,"no-legacy-tear: \(kind) stays in window")
            let before=s.orbTrash.successfulRemovals
            f.send(.leftMouseUp,p);f.advance(1.1)
            check(s.orbTrash.successfulRemovals==before+1,"single-up: \(kind) removes exactly once")
            check(!s.switches.suffix(2).contains { ($0["reason"] as? String)=="drag-drop" },"single-up: ordinary drop does not also commit")
            let expected=try! OrganicRemovePolicy.remove(id,from:original,source:.trash,sessionID:UUID()).get()
            check(equal(s.orbTrash.project()!,expected.layout),"\(kind): member/column/weight/banks/current match shared policy")
            check(s.store.conversation(id) === c && !c.archived && c.running==running,"\(kind): store conversation and task survive")
            check(c.draft=="Retained local draft" && c.items.count==itemCount,"\(kind): draft and transcript are not cleared")
            check(c.identityIndex==identity.0 && c.identitySymbol==identity.1 && c.identityTint==identity.2,"\(kind): identity stays on same conversation")
            check(s.orbTrash.journal.started && s.orbTrash.journal.prompt == .education,"present-clock: \(kind) starts journal after absorption")
            let left=s.orbTrash.journal.remaining;f.advance(0.25)
            check(s.orbTrash.journal.remaining<left-0.2,"present-clock: \(kind) education timer advances")
            f.send(.leftMouseUp,p)
            check(s.orbTrash.successfulRemovals==before+1,"single-up: duplicate up cannot remove twice")
            f.click(s.orbTrash.presentation.undo);f.advance(1.2)
            check(s.members.contains{$0 === c} && s.orbTrash.successfulUndos==1,"\(kind): dispatched Undo restores same conversation")
            check(s.columns.map{$0.conversation.id}==original.columns.map(\.member),"\(kind): original column slot returns")
            rows.append(["source":kind,"originalColumns":original.columns.map(\.member),"returnedColumns":s.columns.map{$0.conversation.id},"returnedBanks":s.orbTrash.project().map{["left":$0.left,"right":$0.right,"parked":$0.parked]} ?? [:]])
            check(!s.orbInput.isPressed && !s.dock.isHolding,"\(kind): drop releases input and Dock owners")
            check(f.base.app.core==nil && f.base.app.live==nil && !f.base.app.o.usesLiveCore,"\(kind): fixture has no real Core")
            check(f.base.dispatchWindow?.orderAttempts==0 && f.base.dispatchWindow?.hasOnscreenSurface==false,"\(kind): DispatchWindow stays unordered")
        }
        for distance in [43.9,44.0,44.1] {
            let f=Fixture();defer { f.dispose() };let id=f.scene.order.last!,p=f.down(id)
            f.send(.leftMouseDragged,.init(x:p.x,y:p.y-distance));f.advance(0.1)
            check(f.scene.drag?.freeCarry == (distance>44),"free-band: \(distance)pt uses strict 44 boundary")
            f.base.key(53)
        }
        for (distance,duration,pickup) in [(7.9,0.249,false),(8.0,0.249,true),(0.0,0.250,true)] {
            let f=Fixture();defer { f.dispose() };let id=f.scene.order.last!
            f.base.click(id,flags:.option,distance:distance,duration:duration)
            check(f.scene.switches.contains{($0["reason"] as? String)=="orb-swap"} != pickup,"pickup: \(distance)pt / \(duration)s")
        }
        for distance in [59.9,60,60.1,73.9,74,74.1] {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,offset=CGPoint(x:12,y:0)
            if distance>70 { _=f.carry(id,offset:offset) }
            else {
                _=f.down(id,offset:offset)
                f.send(.leftMouseDragged,.init(x:f.can.x-90+offset.x,y:f.can.y));f.advance(1.1)
            }
            f.send(.leftMouseDragged,.init(x:f.can.x-distance+offset.x,y:f.can.y));f.advance(0.6)
            check((s.orbTrash.output?.pose.phase == .armed) == (distance<60 || distance>70 && distance<=74),"semantic-hit-dispatch: \(distance)pt uses unmagnetized center and grab")
            f.base.key(53)
        }
        for ending in ["near","leave","outside","return","edge-in","edge-out"] {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,initial=Set(s.members.map(\.id))
            var p=f.carry(id),tears=0;s.onTear={ _ in tears+=1 }
            if ending=="near" { p=CGPoint(x:f.can.x-80,y:f.can.y) }
            if ending=="leave" { p=CGPoint(x:f.can.x-100,y:f.can.y) }
            if ending=="outside" || ending=="return" { p=CGPoint(x:s.sizeForOrb.width+1,y:400) }
            if ending=="edge-in" { p=CGPoint(x:s.sizeForOrb.width-1,y:400) }
            if ending=="edge-out" { p=CGPoint(x:-1,y:400) }
            f.send(.leftMouseDragged,p);f.advance(0.4)
            if ending=="return" { p=CGPoint(x:f.can.x-52,y:f.can.y);f.send(.leftMouseDragged,p);f.advance(0.5) }
            f.send(.leftMouseUp,p);f.advance(0.9)
            check(tears==0,"no-legacy-tear: \(ending) never calls Tear")
            check(Set(s.members.map(\.id)) == (ending=="return" ? initial.subtracting([id]):initial),"return-boundary: \(ending) has one intended result")
        }
        for point in [CGPoint(x:20,y:20),CGPoint(x:640,y:20),CGPoint(x:1260,y:20),
                      CGPoint(x:20,y:410),CGPoint(x:1260,y:410),
                      CGPoint(x:20,y:800),CGPoint(x:640,y:800),CGPoint(x:1260,y:800)] {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,original=Set(s.members.map(\.id))
            var callbacks=0;s.onTear={ _ in callbacks+=1 }
            _=f.down(id);f.send(.leftMouseDragged,point);f.advance(0.2)
            check(callbacks==0 && !s.isTearing,"no-legacy-tear: interior direction \(point) never tears")
            f.send(.leftMouseUp,point);f.advance(0.8)
            check(Set(s.members.map(\.id))==original,"return-boundary: interior direction \(point) returns without removal")
        }
        for focused in [false,true] {
            let f=Fixture(width:640);defer { f.dispose() };let s=f.scene
            if focused { s.enterFocused(s.current,reason:"fixture-focus");f.base.settle() }
            let id=s.current,initial=Set(s.members.map(\.id)),p=f.carry(id)
            check(s.orbTrash.output?.pose.phase == .disabled,"last-column: disabled bucket focused=\(focused)")
            check(s.orbTrash.output?.disabledMessage==OrganicRemoveJournal.lastColumnMessage,"last-column: disabled explanation focused=\(focused)")
            check(s.orbTrash.presentation.presentedNotice==OrganicRemoveJournal.lastColumnMessage,"last-column: native disabled explanation is visible")
            check(s.orbTrash.output?.pose.nubs.isEmpty==true && s.orbTrash.output?.pose.redTint==0,"last-column: no connection or red focused=\(focused)")
            f.send(.leftMouseUp,p);f.advance(0.7)
            check(Set(s.members.map(\.id))==initial,"release-eligibility: last column remains focused=\(focused)")
        }
        for reason in ["escape","resign","close"] {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,p=f.carry(id)
            let added=f.add("arrival-"+reason)
            if reason=="escape" { f.base.key(53) }
            if reason=="resign" { NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:f.base.dispatchWindow) }
            if reason=="close" { f.base.owner.window.close() }
            f.send(.leftMouseUp,p);f.advance(0.2)
            check(s.members.contains{$0 === added},"cancel-keeps-add: \(reason) preserves concurrent arrival")
            check(!s.orbInput.isPressed && !s.dock.isHolding && !s.orbTrash.isCarrying,"cancel-cleanup: \(reason) releases all owners")
            check(s.orbTrash.presentation.allGlass.allSatisfy(\.isHidden),"cancel-cleanup: \(reason) retires trash glass")
            check(s.orbTrash.output==nil && s.orbTrash.state.phase == .hidden && !s.clock.keepRunning,"cancel-cleanup: \(reason) has no trash frame request")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.columns.last!.conversation.id
            _=f.carry(id)
            let added=(0..<4).map { Conversation(id:"cancel-header-\($0)",title:"Header arrival") }
            let arrival=s.store.onAdd;s.store.onAdd=nil
            added.forEach(s.store.add)
            s.store.onAdd=arrival
            s.transition(to:s.members+added,current:s.current,scheme:s.scheme,spring:AutoScene.queueSpring,reason:"fixture-header-demoted")
            check(!s.columns.contains{$0.conversation.id==id},"cancel-header: fixture demotes held header through concurrent Add",input:false)
            f.base.key(53);f.advance(1.2)
            check(s.members.contains{$0.id==id} && added.allSatisfy{c in s.members.contains{$0 === c}},"cancel-keeps-add: held header preserves latest members")
            check(s.dock.items[id]?.role == .orb,"cancel-header: returns to latest bank instead of obsolete header")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.current,p=f.carry(id)
            let only=s.store.conversation(id)!
            s.transition(to:[only],current:id,scheme:AutoScene.Scheme(),spring:AutoScene.queueSpring,reason:"fixture-concurrent-removal")
            f.advance(0.05)
            let bucket=s.orbTrash.output?.pose.can ?? .zero
            check(s.orbInput.isPressed && s.drag?.freeCarry==true && s.orbTrash.isCarrying && hypot(p.x-bucket.midX,p.y-bucket.midY)<OrbTrashParameters.armRadius,
                  "release-setup: concurrent single-column commit leaves the drop inside the fixed bucket")
            f.send(.leftMouseUp,p);f.advance(0.3)
            check(s.members.count==1 && s.members[0] === only && s.orbTrash.successfulRemovals==0,"release-eligibility: rechecks latest last column on up")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,p=f.carry(id)
            let staleUp=f.base.event(.leftMouseUp,at:p)
            f.base.key(53);f.advance(1)
            let q=f.carry(id);f.base.dispatch(staleUp)
            check(s.orbInput.isPressed && s.isDragging && s.orbTrash.successfulRemovals==0,"late-up: old gesture cannot release a newer pressed owner")
            f.send(.leftMouseUp,q);f.advance(1)
            check(s.orbTrash.successfulRemovals==1 && !s.orbInput.isPressed,"late-up: current gesture still commits exactly once")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,original=s.orbTrash.project()!
            let r=s.orbPose(id)!,p=CGPoint(x:r.midX,y:r.midY)
            _=f.base.dispatchedClick(at:p,right:true)
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.07))
            let menu=s.orbMenu.main.frame,choice=CGPoint(x:menu.midX,y:menu.minY+269)
            f.send(.mouseMoved,choice);f.send(.leftMouseDown,choice)
            let deadline=CACurrentMediaTime()+1
            while s.orbMenu.superview != nil,CACurrentMediaTime()<deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01)) }
            f.advance(0.6)
            check(s.orbTrash.successfulRemovals==1,"menu-remove: r4 dispatched menu commits Remove")
            let expected=try! OrganicRemovePolicy.remove(id,from:original,source:.contextMenu,sessionID:UUID()).get()
            check(equal(s.orbTrash.project()!,expected.layout),"menu-remove: matches drag/shared-policy result")
            check(s.orbTrash.journal.started && s.orbTrash.journal.prompt != nil,"menu-remove: uses Remove prompt and Undo journal")
            f.click(s.orbTrash.presentation.undo);f.advance(0.8)
            check(s.members.contains{$0.id==id},"menu-remove: dispatched Undo restores menu removal")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!;_ = f.drop(id)
            let receipt=s.orbTrash.journal.receipt?.id,kept=s.members
            let additions=(0..<24).map { Conversation(id:"capacity-\($0)",title:"Capacity fixture") }
            additions.forEach(s.store.add)
            s.transition(to:kept+additions,current:s.current,scheme:s.scheme,spring:AutoScene.queueSpring,reason:"fixture-full")
            let remaining=s.orbTrash.journal.remaining
            f.click(s.orbTrash.presentation.undo)
            check(s.orbTrash.output?.disabledMessage==OrganicRemoveJournal.fullMessage,"undo-full: displays The Dock is full")
            check(s.orbTrash.presentation.presentedNotice==OrganicRemoveJournal.fullMessage,"undo-full: native notice updates at a stationary pose")
            check(s.orbTrash.journal.receipt?.id==receipt && s.orbTrash.journal.remaining<=remaining,"undo-full: retains receipt without extending expiry")
            s.transition(to:kept,current:s.current,scheme:s.scheme,spring:AutoScene.queueSpring,reason:"fixture-space")
            f.click(s.orbTrash.presentation.undo);f.advance(0.8)
            check(s.members.contains{$0.id==id},"undo-full: retries within original deadline")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.current;_ = f.drop(id)
            s.enterFocused(s.current,reason:"fixture-destroy-slot");f.base.settle()
            let current=s.current
            f.click(s.orbTrash.presentation.undo);f.advance(0.8)
            check(s.members.filter{$0.id==id}.count==1 && !s.scheme.split.contains(id),"undo-bank-fallback: vanished slot returns once to bank")
            check(s.current==current,"undo-bank-fallback: preserves current in changed mode")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!;_ = f.drop(id)
            let add=f.add("undo-arrival"),fork=f.add("undo-fork")
            let next=s.columns.first!.conversation.id;s.activate(next,reason:"fixture-current");f.base.settle()
            let selected=s.current
            f.click(s.orbTrash.presentation.undo);f.advance(0.8)
            check(s.members.contains{$0 === add} && s.members.contains{$0 === fork},"undo-keeps-add: later Add and Fork survive")
            check(s.current==selected,"undo-keeps-current: later selection survives")
            check(s.members.filter{$0.id==id}.count==1,"undo-keeps-add: removed conversation returns once")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!;_ = f.drop(id)
            let left=s.orbTrash.journal.remaining
            let r=s.orbTrash.output?.pose.bubble ?? .zero;f.send(.mouseMoved,.init(x:r.midX,y:r.midY));f.advance(0.5)
            check(abs(s.orbTrash.journal.remaining-left)<0.04,"prompt-pause: hovering pauses education")
            f.base.key(48);let focused=s.orbTrash.journal.remaining;f.advance(0.4)
            check(abs(s.orbTrash.journal.remaining-focused)<0.04,"prompt-pause: keyboard focus pauses education")
            f.click(s.orbTrash.presentation.never)
            check(s.orbTrash.journal.prompt == .toast && abs(s.orbTrash.journal.remaining-left)<0.04,"prompt-never: switches to toast without restarting")
            check(s.orbTrash.preferences.suppressEducation,"prompt-never: writes isolated installation preference")
            f.base.key(53)
            check(s.orbTrash.journal.prompt==nil && s.orbTrash.journal.canUndo,"foreground: Esc closes UI but keeps journal")
            check(!s.orbTrash.hasForegroundSurface,"foreground: journal alone is not foreground")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!
            s.orbTrash.preferences.suppress();_ = f.drop(id)
            check(s.orbTrash.journal.prompt == .toast && s.orbTrash.journal.remaining<=5,"toast-clock: suppressed education presents five-second toast")
            check(s.tideHasForegroundSurface,"foreground: interactive Undo toast precedes Tide")
            f.advance(5.1)
            check(!s.orbTrash.journal.canUndo,"toast-clock: expires from present deadline")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene;_ = f.drop(s.order.last!)
            let receipt=s.orbTrash.journal.receipt?.id,remaining=s.orbTrash.journal.remaining
            s.beginModeHandoff();f.advance(0.5)
            check(s.orbTrash.journal.prompt==nil && s.orbTrash.output==nil,"mode-close: closes transient trash presentation",input:false)
            check(s.orbTrash.journal.receipt?.id==receipt && s.orbTrash.journal.remaining<remaining,"mode-close: retains journal without resetting its expiry",input:false)
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,c=s.store.conversation(id)!
            _ = f.drop(id);s.admit(c,reason:"fixture-already-present")
            f.click(s.orbTrash.presentation.undo)
            check(s.members.filter{$0 === c}.count==1 && !s.orbTrash.journal.canUndo,"undo-already-present: never duplicates a current member")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!
            s.sunHover?.llClick()
            let before=s.orbPose(id)!;let p=f.down(id)
            f.send(.leftMouseDragged,.init(x:p.x+8,y:p.y))
            let after=s.dock.trashCarrier(id)!.rect
            check(s.sunHover?.isShowing != true,"ll-yields: conversation pickup retires hover")
            check(s.orbInput.isPressed && s.isDragging,"ll-yields: original first down reaches the drag owner")
            check(abs(before.midX-after.midX)<1 && abs(before.midY-after.midY)<1,"ll-yields: first carried frame inherits physical pose")
            f.base.key(53)
            s.sunHover?.llClick();let current=s.current,columns=s.columns.map{$0.conversation.id}
            f.base.click(id,flags:[])
            check(s.current==current && s.columns.map{$0.conversation.id}==columns,"ll-yields: short click keeps the old dismissal-only behavior")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,owner=s.order.last!
            f.tide(owner)
            let token=s.dock.trashLeaseFacts().tide
            let id=s.order.dropFirst(s.layout.columns.count).first { $0 != owner }!
            _=f.down(id)
            check(s.orbInput.isPressed && s.tideHasForegroundSurface,"foreground: pressed planet owns input before the pickup threshold")
            f.base.key(53)
            check(!s.orbInput.isPressed && s.dock.trashLeaseFacts().tide==token,"foreground: Esc cancels the planet press before dismissing Tide")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,owner=s.order.last!
            f.tide(owner)
            let token=s.dock.trashLeaseFacts().tide
            check(token != nil,"tide-precise: fixture owns a Tide token",input:false)
            let id=s.order.dropFirst(s.layout.columns.count).first { $0 != owner }!
            let p=f.carry(id);f.send(.leftMouseUp,p)
            check(s.dock.trashLeaseFacts().tide==token,"tide-precise: unrelated Tide token survives Remove")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,owner=s.order.last!
            f.tide(owner)
            let token=s.dock.trashLeaseFacts().tide
            let origin=s.orbPose(owner) ?? .zero
            let p=f.carry(owner)
            check(f.lastDownPressed,"tide-precise: dispatched lead down owns the shared controller")
            let native=s.dock.trashCarrier(owner)?.rect ?? .zero
            rows.append(["fixture":"tide-owner-before-up","downHit":f.lastDownHit,"pressedAfterDown":f.lastDownPressed,"origin":[origin.minX,origin.minY,origin.width,origin.height],"native":[native.minX,native.minY,native.width,native.height],"free":s.drag?.freeCarry ?? false,"phase":s.orbTrash.state.phase.rawValue,"carrierOwner":s.orbTrash.output?.pose.owner.rawValue ?? "none","clearance":String(describing:s.dock.trashClearance(owner)),"pressed":s.orbInput.isPressed])
            f.send(.leftMouseUp,p)
            check(s.orbTrash.successfulRemovals==1 && !s.members.contains{$0.id==owner},"tide-precise: owner is actually removed by dispatched trash up")
            rows.append(["fixture":"remove-tide-owner","owner":owner,"tokenBefore":String(describing:token),"tokenAfter":String(describing:s.dock.trashLeaseFacts().tide),"removals":s.orbTrash.successfulRemovals,"phase":s.orbTrash.state.phase.rawValue,"memberRemains":s.members.contains{$0.id==owner},"tide":s.dock.tideLightProbe])
            check(token != nil && s.dock.trashLeaseFacts().tide != token,"tide-precise: affected owner token is invalidated")
        }
        do {
            let f=Fixture();defer {f.dispose()};let s=f.scene,id=s.order.last!
            f.tide(id);let p=f.down(id)
            check(s.orbInput.isPressed,"tide-click: lead down uses the shared input owner")
            f.send(.leftMouseUp,p);f.advance(0.1)
            let presentation=s.dock.tideLightProbe["presentation"] as? [String:Any] ?? [:]
            check(presentation["pinned"] as? Bool == true && !s.orbInput.isPressed && s.orbTrash.successfulRemovals==0,
                  "tide-click: short release preserves the original pin action")
        }
        do {
            let f=Fixture();defer {f.dispose()};let s=f.scene,id=s.order.last!
            f.tide(id);let rect=s.dock.trashCarrier(id)!.rect,p=CGPoint(x:rect.maxX-24,y:rect.midY)
            f.send(.leftMouseDown,p);let end=CGPoint(x:p.x-80,y:p.y-60)
            f.send(.leftMouseDragged,end);f.advance(0.2);f.send(.leftMouseUp,end)
            check(!s.orbInput.isPressed && s.drag==nil && s.orbTrash.state.phase == .hidden,
                  "tide-text: notice text keeps its own press and never starts a planet carry")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene
            let candidates=(0..<16).map { Conversation(id:"protected-add-\($0)",title:"Protected Add") }
            let originalBriefs=s.columns.filter{!s.isFull($0.conversation.id)}.map{$0.conversation.id}
            // Select a real column displacement; an Add that fits naturally owns no brief capacity.
            let count=(1...candidates.count).first { n in
                let (next,order)=s.arrange(s.members+Array(candidates.prefix(n)),current:s.current)
                return originalBriefs.filter{!order.prefix(next.bars.count).contains($0)}.count==1
            } ?? candidates.count
            let additions=Array(candidates.prefix(count))
            let arrival=s.store.onAdd;s.store.onAdd=nil
            additions.forEach(s.store.add)
            s.store.onAdd=arrival
            let admitted=s.admitWithTideSlots(additions,owner:"fixture-add",capacityAllows:true)
            f.advance(0.8)
            let before=s.dock.trashLeaseFacts()
            rows.append(["fixture":"committed-add","arrivals":count,"admitted":admitted,"protected":Array(before.add),"probe":s.dock.tideAddProbe])
            check(admitted && before.addToken != nil && !before.add.isEmpty,"add-precise: fixture owns committed Add space",input:false)
            let id=s.order.dropFirst(s.layout.columns.count).first { !before.add.contains($0) }!
            let p=f.carry(id);f.send(.leftMouseUp,p)
            let after=s.dock.trashLeaseFacts()
            check(before.addToken==after.addToken && before.add==after.add,"add-precise: valid Add lease survives Remove")
        }
        do {
            let f=Fixture();defer { f.dispose() };let s=f.scene,id=s.order.last!,p=f.carry(id)
            check(s.tideHasForegroundSurface,"foreground: carrying owns input ahead of Tide")
            f.send(.leftMouseUp,p)
            check(!s.orbTrash.hasForegroundSurface,"foreground: sinking alone does not own foreground")
            f.advance(1.1)
            check(s.tideHasForegroundSurface,"foreground: education owns input ahead of Tide")
            f.click(s.orbTrash.presentation.undo)
            check(!s.orbTrash.hasForegroundSurface,"foreground: emerging alone does not own foreground")
        }
        valueBoundaries()
        check(NSApp.windows.allSatisfy{!$0.isVisible},"isolation: all integration fixtures stay offscreen",input:false)
        return receipt()
    }
    static func receipt()->[String:Any] {
        return ["checks":checks,"inputChecks":inputChecks,"valueChecks":valueChecks,"findings":findings,"records":rows,
                "realCoreConnections":0,"inputEntry":"OrbInputVerification.DispatchWindow","reduceMotion":Motion.reduce,
                "reduceTransparency":NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency]
    }
    static func valueBoundaries() {
        // Boundary assertions target semantic center, not the magnetized carrier. No event claim is made here.
        let g=OrbTrashGeometry(bounds:.init(x:0,y:0,width:1280,height:820),lastSlotX:1234,dockBaseline:764)
        for distance in [59.9,60,60.1,73.9,74,74.1] {
            var state=OrbTrashState()
            var input=OrbTrashState.Input(event:.begin(UUID()),semanticCenter:.init(x:1100,y:696),nativeCarrier:.init(x:1081,y:677,width:38,height:38),geometry:g)
            _=state.step(input,at:0);input.event = .move;_ = state.step(input,at:2)
            if distance>70 { input.semanticCenter = .init(x:1182,y:696);_ = state.step(input,at:2.1) }
            input.semanticCenter = .init(x:1234-distance,y:696)
            let p=state.step(input,at:3).pose
            check((p.phase == .armed) == (distance<60 || distance>=70 && distance<=74),"semantic-hit: \(distance)pt arm/out",input:false)
        }
        var leases=DockSlotLeases()
        let candidates=[DockSlotLeases.Candidate(id:"brief",role:.brief)]
        let add=leases.request(owner:"add",purpose:.add,count:1,candidates:candidates,capacityAllows:true,at:0)
        _=leases.commitAdd(add.lease!.token)
        check(leases.undoPrefixes(candidates:candidates,at:1).isEmpty && leases.owns(add.lease!.token),"undo-capacity: protects committed Add and creates no reservation",input:false)
    }
}
#endif
