#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

extension M10DockVerification {
    /// Real island mouse events, the shared Dock gesture, and its actual paint owners; no NSWindow.
    static func headerDragFollowup(output:URL) throws {
        var records=[[String:Any]]()
        for scale:CGFloat in [1,2] {for which in [0,1] {for top in [false,true] {
            let f=HeaderFixture(scale:scale);defer{f.dispose()}
            let h=f.headers[which],id=h.configuration!.id,item=f.scene.dock.items[id]!
            let before=item.chromeHost.frame,down=top ? f.point(h):CGPoint(x:item.glass.frame.midX,y:item.glass.frame.minY)
            func event(_ type:NSEvent.EventType,_ p:CGPoint)->NSEvent {
                NSEvent.mouseEvent(with:type,location:f.scene.dock.view.convert(p,to:nil),modifierFlags:[],timestamp:f.time,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            if top {h.planetButton.mouseDown(with:event(.leftMouseDown,down))} else {_=f.scene.pointerDown(down)}
            let p=CGPoint(x:down.x+8,y:down.y)
            if top {h.planetButton.mouseDragged(with:event(.leftMouseDragged,p))} else {f.scene.pointerDragged(p)}
            let began=f.time
            for k in 0...18 {
                if k>0 {f.tick(1/120)}
                let chrome=item.chromeHost.frame,face=item.faceOpacity(at:f.time)
                if top {
                    if f.time-began<0.1 {check(chrome.minY==before.minY,"header pickup keeps fading composer/words on their original Dock row")}
                    check(face==1,"header pickup preserves the already-visible orb face from its first frame")
                    check(item.glass.alphaValue>0.999,"header pickup has a visible carried glass")
                }
                records.append(["kind":"chrome","top":top,"scale":scale,"which":which,"frame":k,
                    "chrome":[chrome.minX,chrome.minY,chrome.width,chrome.height],"face":face,
                    "glass":[item.glass.frame.minX,item.glass.frame.minY,item.glass.frame.width,item.glass.frame.height]])
            }
            f.scene.cancelDrag();f.settle()
        }}}
        for scale:CGFloat in [1,2] {for split in [false,true] {for which in 0..<(split ? 2:1) {
            for action in ["back","out","escape","resign","tear-back","tear-escape","merge","short"] {
            let saved=OrganicFeatureAvailability.current.conversationOrbTear
            OrganicFeatureAvailability.current.conversationOrbTear=action.hasPrefix("tear") || action == "merge"
            defer { OrganicFeatureAvailability.current.conversationOrbTear=saved }
                var traces=[[String:Any]]()
                for top in [false,true] {
                    let f=HeaderFixture(scale:scale,members:["A","B","C"]);defer{f.dispose()}
                    f.scene.enterFocused("A",reason:"fixture-focus");f.settle()
                    if split {f.scene.graft("B",at:1,reason:"fixture-split");f.settle()}
                    let c=f.scene.columns[which],id=c.conversation.id,h=c.island!,item=f.scene.dock.items[id]!
                    let grip=item.identityOpacity.to>0 ? CGPoint(x:item.identityFrame.midX,y:item.identityFrame.midY):CGPoint(x:item.glass.frame.midX,y:item.glass.frame.minY)
                    let down=top ? f.point(h):grip
                    var clicks=0;h.actions.customize={clicks+=1}
                    func event(_ type:NSEvent.EventType,_ p:CGPoint)->NSEvent {
                        NSEvent.mouseEvent(with:type,location:f.scene.dock.view.convert(p,to:nil),modifierFlags:[],timestamp:f.time,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                    }
                    var tears=[String]()
                    f.scene.onTear={ e in
                        switch e {
                        case .begin:tears.append("begin")
                        case .move:tears.append("move")
                        case .drop:tears.append("drop");f.scene.endTear(kept:action != "merge")
                        case .cancel:tears.append("cancel");f.scene.endTear(kept:true)
                        }
                    }
                    f.scene.switches=[];f.scene.pressedButtons={1}
                    if top {
                        let press=event(.leftMouseDown,down)
                        // A parentless flipped root's hitTest takes the unflipped base coordinates,
                        // just like the NSEvent; a native-plane hitTest takes flipped root coordinates.
                        let hit=f.root.hitTest(press.locationInWindow)
                        check(hit === h.planetButton,"Focused/Split physical hit reaches the header orb")
                        hit?.mouseDown(with:press)
                    } else {
                        // The first Focused segment has no physical grip. This is its shared member entry.
                        if !f.scene.pointerDown(down) {
                            check(f.scene.pointerDown(down,member:id),"Focused/Split shared Dock member press")
                            f.scene.drag?.headerOrigin=false;f.scene.drag?.pointerOffset = .zero
                        }
                    }
                    check(f.scene.isHolding,"Focused/Split orb press enters the shared gesture")
                    var pointer=down
                    func move(_ dx:CGFloat,_ dy:CGFloat=0) {
                        pointer=CGPoint(x:down.x+dx,y:down.y+dy)
                        if top {h.planetButton.mouseDragged(with:event(.leftMouseDragged,pointer))} else {f.scene.pointerDragged(pointer)}
                        f.tick()
                    }
                    if action != "short" {
                        move(8)
                        check(f.scene.isDragging,"Focused/Split orb crosses the same eight-point pickup threshold")
                        if top {
                            check(h.orbIsCarried && item.glass.alphaValue>0.999,"Focused/Split top pickup has exactly one visible carried owner")
                            check(hypot(item.glass.frame.midX-pointer.x,item.glass.frame.midY-pointer.y)<=60,"Focused/Split carried item is under the real pointer")
                            check((item.identity?.glassView.alphaValue ?? 0)<0.001,"Focused/Split alternate Dock identity is hidden during header carry")
                        }
                        let capsule=f.scene.dock.capsule!
                        let dx:CGFloat=action == "out" ? capsule.maxX+30-grip.x:20
                        for k in 1...12 {move(8+(dx-8)*CGFloat(k)/12)}
                        if action.hasPrefix("tear") || action == "merge" {
                            move(dx,140);check(f.scene.isTearing,"Focused/Split top and Dock entries both tear")
                        }
                        if ["escape","resign","tear-escape"].contains(action) {
                            if top {f.drag.cancel()} else {f.scene.cancelDrag()}
                        } else {
                            if top {h.planetButton.mouseUp(with:event(.leftMouseUp,pointer))} else {_=f.scene.pointerUp(pointer)}
                            if top,!split,action == "out" {
                                check(f.scene.dock.headerReturnCount==1,"the last Focused segment lands back in its header without a bottom flight")
                            }
                        }
                    } else {
                        if top {h.planetButton.mouseUp(with:event(.leftMouseUp,down))} else {_=f.scene.pointerUp(down)}
                        check(clicks==(top ? 1:0),"Focused/Split short header click retains Customize")
                    }
                    f.settle()
                    check(!f.scene.isHolding && !f.scene.isTearing && !f.scene.dock.isHolding,"Focused/Split releases input ownership")
                    check(!h.orbIsCarried,"Focused/Split restores the source paint after landing/cancel")
                    check(f.scene.scheme.split.allSatisfy { member in f.scene.members.contains{$0.id==member} },"Focused/Split tear cannot leave a detached member in the source scheme")
                    if action == "out",!split {
                        check(item.role == .bar && item.full,"the last Focused segment returns to its complete bar instead of remaining an orb")
                    }
                    if action == "short" {
                        h.now={ [weak f] in f?.time ?? 0 }
                        h.hover(true,at:f.time);h.advance(to:f.time+0.279)
                        check(h.state.hovering && !h.state.expanded,"Focused/Split hover retains its original opening delay")
                        h.advance(to:f.time+0.281)
                        check(h.state.expanded,"Focused/Split hover still expands the island")
                        h.hover(false,at:f.time+0.3);h.setExpanded(false)
                        h.titleButton.performClick(nil)
                        check(h.state.expanded && h.state.pinned,"Focused/Split caption click still pins expansion")
                        h.escape();check(!h.state.expanded && !h.state.pinned,"Focused/Split expanded island still closes on Esc")
                    }
                    if action == "out",split {
                        check(!f.scene.scheme.split.contains(id),"Split outward drop ungrafts the same member")
                        let orb=f.scene.dock.items[id]!.glass.frame
                        check(f.scene.pointerDown(CGPoint(x:orb.midX,y:orb.midY)),"ungrafted Dock orb retains its physical hit target")
                        let target=f.scene.dock.capsule!
                        f.scene.pointerDragged(CGPoint(x:target.midX,y:target.midY))
                        _=f.scene.pointerUp(CGPoint(x:target.midX,y:target.midY));f.settle()
                        check(f.scene.scheme.split.contains(id),"ungrafted member can graft back through the same Dock path")
                    }
                    traces.append(["members":f.scene.members.map(\.id),"current":f.scene.current,"split":f.scene.scheme.split,
                        "columns":f.scene.columns.map{$0.conversation.id},"reasons":f.scene.switches.compactMap{$0["reason"] as? String},"tears":tears])
                }
                check(NSDictionary(dictionary:traces[0]).isEqual(to:traces[1]),"Focused/Split \(action) top/Dock decisions and results match")
                records.append(["kind":"focused","scale":scale,"split":split,"which":which,"action":action,"traces":traces])
            }
        }}}
        check(NSApp.windows.allSatisfy{!$0.isVisible},"header followup opens no visible window")
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("header-followup.json"))
    }
}
#endif
