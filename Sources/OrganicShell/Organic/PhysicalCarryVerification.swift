#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

extension M10DockVerification {
    final class CarryPointerDot:NSView {
        override func draw(_ dirtyRect:NSRect) {NSColor.systemRed.setFill();NSBezierPath(ovalIn:bounds).fill()}
    }
    static func tearOffsetConvergence(initial:CGPoint,at began:Double,label:String,output:URL) {
        let spring=AutoScene.queueSpring,target=CGPoint(x:0,y:-4)
        var motion=DragCarryGeometry.TearOffset(from:initial,to:target,at:began,spring:spring)
        check(motion.x.response==spring.response && motion.y.response==spring.response && motion.x.damping==spring.damping && motion.y.damping==spring.damping,"tear offset retains queue response/damping")
        var csv="frame,time,pointer_x,pointer_y,center_x,center_y,distance,rounded_distance,old_distance\n"
        var lastDistance:CGFloat=0,maxBarDifference:CGFloat=0
        for frame in 0...90 {
            let elapsed=Double(frame)/60,t=began+elapsed
            // Include a stationary first half: display frames must continue without mouse events.
            let p=frame<45 ? CGPoint(x:501.25,y:410.75):CGPoint(x:501.25+CGFloat(frame-45)*3.1,y:410.75+CGFloat(sin(elapsed*4))*17)
            let offset=motion.advance(at:t),center=DragCarryGeometry.screenCenter(pointer:p,offset:offset)
            let rounded=CGPoint(x:(center.x-72).rounded()+72,y:(center.y-72).rounded()+72)
            let distance=hypot(center.x-p.x,center.y-p.y),roundedDistance=hypot(rounded.x-p.x,rounded.y-p.y)
            if frame==0 {check(offset==initial,"tear first frame retains the exact handoff offset")}
            if elapsed>=0.3 {check(distance<=8,"header tear returns to pickup distance after 0.3 s: \(distance)")}
            if elapsed>=0.6 {check(roundedDistance<=5,"header tear is under pointer after 0.6 s: \(roundedDistance)")}
            lastDistance=distance
            // The bar branch never creates an offset spring or display clock. Its old panel formula is unchanged.
            let barOffset=CGPoint(x:0,y:24),old=CGPoint(x:p.x,y:p.y-24)
            let bar=DragCarryGeometry.screenCenter(pointer:p,offset:barOffset)
            let error=hypot(old.x-bar.x,old.y-bar.y);maxBarDifference=max(maxBarDifference,error)
            check(error==0,"bar tear center remains bit-for-bit identical on every frame")
            csv+="\(frame),\(elapsed),\(p.x),\(p.y),\(center.x),\(center.y),\(distance),\(roundedDistance),\(hypot(initial.x,initial.y))\n"
        }
        check(lastDistance==4,"header tear settles to its original four-point pickup offset")
        for action in ["drop","escape","merge"] {for elapsed in [0.0,1.0/60,0.1,0.25] {
            var interrupted=DragCarryGeometry.TearOffset(from:initial,to:target,at:began,spring:spring)
            let shown=interrupted.advance(at:began+elapsed)
            // The display target timestamp can lead a mouse event. Ending must not rewind the spring.
            interrupted.stop(at:began+elapsed-1.0/120)
            check(interrupted.advance(at:began+elapsed)==shown,"\(action) freezes the last displayed offset without a jump")
            for k in 1...12 {
                check(interrupted.advance(at:began+elapsed+Double(k)/60)==shown,"\(action) cannot drift after offset animation stops")
            }
            interrupted.stop(at:began+elapsed+2)
            check(interrupted.advance(at:began+elapsed+3)==shown,"\(action) repeated retirement preserves the frozen pose")
        }}
        try? csv.write(to:output.appendingPathComponent("tear-offset-\(label).csv"),atomically:true,encoding:.utf8)
        let row:[String:Any]=["initialDistance":hypot(initial.x,initial.y),"finalDistance":lastDistance,"springSeconds":motion.duration,"barMaxDifference":maxBarDifference]
        try? JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tear-offset-\(label).json"))
    }
    static func physicalHeaderCarry(output:URL) throws {
        var rows=[[String:Any]]()
        for scale:CGFloat in [1,2] {for which in [0,1] {for action in ["drop","escape","back-drop","tear-down","tear-up"] {
            let saved=OrganicFeatureAvailability.current.conversationOrbTear
            OrganicFeatureAvailability.current.conversationOrbTear=action.hasPrefix("tear") || action == "merge"
            defer { OrganicFeatureAvailability.current.conversationOrbTear=saved }
            let f=HeaderFixture(scale:scale,members:["A","B"]);defer{f.dispose()}
            let island=f.headers[which],id=island.configuration!.id,down=f.point(island)
            func event(_ kind:NSEvent.EventType,_ p:CGPoint)->NSEvent {
                NSEvent.mouseEvent(with:kind,location:f.scene.dock.view.convert(p,to:nil),modifierFlags:[],timestamp:f.time,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            var tearCenter:CGPoint?,tearDistance:CGFloat=0,pointer=down,maxDistance:CGFloat=0,returnDistance:CGFloat=0
            f.scene.pressedButtons={1}
            f.scene.onTear={ e in
                if case .begin(_,let p,_,_)=e {
                    let r=f.scene.dock.items[id]!.glass.frame
                    tearCenter=CGPoint(x:r.midX,y:r.midY);tearDistance=abs(p.y-down.y)
                }
            }
            island.planetButton.mouseDown(with:event(.leftMouseDown,down))
            for k in 1...36 {
                let dx:CGFloat=action == "back-drop" ? CGFloat(k<=18 ? k:36-k):CGFloat(min(k,16))
                let dy:CGFloat=action == "tear-down" ? CGFloat(k)*3:(action == "tear-up" ? -CGFloat(k)*3:CGFloat(sin(Double(k)/8))*20)
                pointer=CGPoint(x:down.x+dx,y:down.y+dy)
                island.planetButton.mouseDragged(with:event(.leftMouseDragged,pointer))
                if k==3,f.scene.isDragging,!f.scene.isTearing {
                    let r=f.scene.dock.items[id]!.glass.frame
                    check(hypot(r.midX-pointer.x,r.midY-pointer.y)<=60,"pickup is under pointer before the first display-link tick")
                }
                f.tick()
                if !f.scene.isTearing,f.scene.isDragging {
                    let r=f.scene.dock.items[id]!.glass.frame,d=hypot(r.midX-pointer.x,r.midY-pointer.y)
                    maxDistance=max(maxDistance,d)
                    check(d<=60,"header physical pickup/follow <= bar envelope (60 pt): \(d)")
                    check(island.orbIsCarried,"header has one carried paint owner")
                }
                if scale==1,[1,12,24,31].contains(k),["drop","escape","tear-down"].contains(action) {
                    let cursor=CarryPointerDot(frame:CGRect(x:pointer.x-5,y:pointer.y-5,width:10,height:10))
                    f.root.addSubview(cursor)
                    let marked=NativeViewBitmap.capture(f.root,scale:scale);cursor.removeFromSuperview()
                    Offscreen.write(marked,output.appendingPathComponent("carry-\(which)-\(action)-\(k).png"))
                }
                if f.scene.isTearing {break}
            }
            if action.hasPrefix("tear") {
                check(tearCenter != nil,"real pointer tears from header row")
                check(action == "tear-up" || tearDistance>90,"downward tear never uses virtual grip/window boundary")
                if let center=tearCenter {
                    let expected=CGPoint(x:pointer.x,y:down.y-4+(pointer.y-down.y)*0.4)
                    check(hypot(center.x-expected.x,center.y-expected.y)<0.001,"tear begins at last carried center without a jump")
                    // Same offset conversion consumed by TearSession; screen y reverses local y.
                    let screen=CGPoint(x:pointer.x,y:1000-pointer.y),offset=CGPoint(x:center.x-pointer.x,y:center.y-pointer.y)
                    let panel=DragCarryGeometry.screenCenter(pointer:screen,offset:offset)
                    check(hypot(panel.x-center.x,panel.y-(1000-center.y))<0.001,"panel handoff preserves physical center")
                    tearOffsetConvergence(initial:offset,at:f.time,label:"\(Int(scale))x-\(which)-\(action)",output:output)
                }
                for _ in 0..<120 {f.tick()}
                check(island.orbIsCarried,"tear retains hidden header through the column's settle time")
                f.scene.endTear(kept:true);f.scene.cancelDrag();f.tick()
                if island.alphaValue<0.999 {check(island.orbIsCarried && f.scene.dock.headerReturnCount>0,"tear return retains carried paint until the header is opaque")}
                f.settle()
                check(!island.orbIsCarried && f.scene.dock.headerReturnCount==0,"tear Esc returns paint to header without bottom flight")
            } else {
                if action == "escape" {island.planetButton.cancelOperation(nil)}
                else {island.planetButton.mouseUp(with:event(.leftMouseUp,pointer))}
                check(f.scene.dock.headerReturnCount==1 && island.orbIsCarried,"column drop/Esc returns the same item to its hidden header")
                check(f.scene.idleMotionUntil>=f.time+0.1,"display clock remains admitted through header landing")
                for _ in 0..<100 {
                    f.tick()
                    if f.scene.dock.headerReturnCount>0 {
                        let r=f.scene.dock.items[id]!.glass.frame,target=f.point(island)
                        returnDistance=max(returnDistance,hypot(r.midX-target.x,r.midY-target.y))
                        check(abs(r.midY-target.y)<100,"header landing never crosses to bottom Dock")
                    }
                }
                f.scene.settle();f.tick()
                check(!island.orbIsCarried && f.scene.dock.headerReturnCount==0,"header paint restored after landing")
            }
            rows.append(["scale":scale,"which":which,"action":action,"maxPointerDistance":maxDistance,"tearAtDy":tearDistance,"maxReturnDistance":returnDistance])
        }}}
        // Another pickup must not snap an earlier return to its destination.
        do {
            let f=HeaderFixture(scale:1,members:["A","B"]);defer{f.dispose()}
            let a=f.headers[0],b=f.headers[1],aid=a.configuration!.id,bid=b.configuration!.id
            let glass=f.scene.dock.items[aid]!.glass
            for h in [a,b] {
                let p=f.point(h)
                check(f.drag.begin(from:h,at:p),"next header accepts pickup during another return")
                f.drag.move(to:CGPoint(x:p.x+18,y:p.y));f.tick()
                _=f.drag.end(at:CGPoint(x:p.x+18,y:p.y));f.tick()
            }
            check(f.scene.dock.headerReturnCount==2 && a.orbIsCarried && b.orbIsCarried,"two existing items keep their own continuous return")
            let r=f.scene.dock.items[aid]!.glass.frame,p=CGPoint(x:r.midX,y:r.midY)
            check(f.scene.pointerDown(p),"returning Dock paint can be regrabbed through common hit path")
            f.scene.pointerDragged(CGPoint(x:p.x+8,y:p.y));f.tick()
            let picked=f.scene.dock.items[aid]!.glass.frame
            check(hypot(picked.midX-p.x-8,picked.midY-p.y)<=60,"regrab stays at the actual paint, without a bottom-row jump")
            check(f.scene.dock.items[aid]!.glass === glass,"regrab retains original Dock item identity")
            f.scene.cancelDrag();f.settle()
            check(!a.orbIsCarried && !b.orbIsCarried && f.scene.dock.headerReturnCount==0,"all interrupted returns release header paint")
            check(f.scene.dock.items[bid] != nil,"independent returning member is retained")
        }
        do {
            let f=HeaderFixture(scale:1,members:["A","B"]);defer{f.dispose()}
            let h=f.headers[1],p=f.point(h)
            _=f.drag.begin(from:h,at:p);f.drag.move(to:CGPoint(x:p.x+8,y:p.y));f.tick()
            _=f.drag.end(at:CGPoint(x:p.x+8,y:p.y));f.tick()
            check(f.scene.dock.headerReturnCount==1,"demotion probe begins with a returning brief")
            for id in ["C","D","E","F"] {f.scene.admit(f.scene.store.conversation(id)!,reason:"return-retarget-admit")}
            f.scene.land("F",reason:"return-retarget-land")
            check(!f.scene.columns.contains{$0.conversation.id=="B"} && f.scene.dock.headerReturnCount==0,"return changes to the Dock when its column becomes overflow")
            f.settle()
            check(f.scene.dock.items["B"]?.role == .orb && !h.orbIsCarried,"demoted return lands once and releases header paint")
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("physical-carry.json"))
    }
}
#endif
