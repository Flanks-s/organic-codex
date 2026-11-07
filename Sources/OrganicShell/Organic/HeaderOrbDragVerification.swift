#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

extension M10DockVerification {
    @MainActor final class HeaderFixture {
        let root=IslandPlane(frame:CGRect(x:0,y:0,width:1080,height:760))
        let scene:AutoScene
        let drag:M104HeaderOrbDragging
        var time=CACurrentMediaTime()+3600
        init(scale:CGFloat,members:[String]?=nil,shared:Bool=false) {
            let store=ConversationStore();MockReplay(store:store).start(live:false)
            scene=AutoScene(size:root.bounds.size,store:store,profile:profile,scale:scale,transcriptSessions:shared ? NativeTranscriptSessions():nil)
            if shared {scene.setTranscriptPresentationActive(true)}
            drag=M104HeaderOrbDragging.install(in:scene)
            scene.now={ [weak self] in self?.time ?? CACurrentMediaTime() }
            scene.dock.motionTime={ [weak self] in self?.time ?? CACurrentMediaTime() }
            scene.dock.motionProfile=profile;scene.manualSettle=true;scene.ambient=false
            for v in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(v)}
            root.appearance=NSAppearance(named:.darkAqua)
            scene.install(members:members);scene.clock.invalidate();scene.settle()
            if ProcessInfo.processInfo.environment["M1111_HEADER_NESTED"] == "1" {
                let plane=IslandPlane(frame:root.bounds);scene.nativePlane.addSubview(plane)
                for island in scene.columns.compactMap(\.island) {plane.addSubview(island)}
            }
        }
        var headers:[HeaderIsland] {scene.columns.compactMap(\.island)}
        func point(_ island:HeaderIsland)->CGPoint {
            let r=scene.dock.view.convert(island.draggableOrbRect,from:island)
            return CGPoint(x:r.midX,y:r.midY)
        }
        func tick(_ dt:Double=1/60) {time+=dt;scene.clock.onFrame?(time)}
        func settle() {for _ in 0..<120 {tick()};scene.settle();tick()}
        func dispose() {drag.dispose();scene.clock.invalidate()}
    }

    static func headerDragging(output:URL) async throws {
        var records=[[String:Any]]()
        for scale:CGFloat in [1,2] {for which in [0,1] {
            for action in ["overflow","escape","tear-drop","tear-escape","outside","merge","swap","short","resign","switch"] {
                var traces=[[String:Any]](),poses=[[CGRect]]()
                for headerEntry in [false,true] {
                    let tearCase=action.hasPrefix("tear") || action == "merge" || action == "outside"
                    let f=HeaderFixture(scale:scale,members:tearCase ? ["A","B"]:(action == "overflow" ? ["A","B","C"]:nil));defer{f.dispose()}
                    let c=f.scene.columns[which],id=c.conversation.id,island=c.island!
                    let home=f.scene.dock.items[id]!.glass.frame
                    let grip=CGPoint(x:home.midX,y:home.minY),down=headerEntry ? f.point(island):grip
                    var pointer=down,maxDistance:CGFloat=0
                    var clicks=0;island.actions.customize={clicks+=1}
                    let original=island.snapshot(scale:scale),members=f.scene.members.map(\.id)
                    var phases=[String](),frames=[CGRect](),tears=[String](),springRows=[[[Double]]]()
                    f.scene.switches=[];f.scene.pressedButtons={1}
                    let destination=HeaderFixture(scale:scale,members:["C"]);defer{destination.dispose()}
                    f.scene.onTear={event in
                        switch event {
                        case .begin:tears.append("begin")
                        case .move:tears.append("move")
                        case .drop:
                            tears.append("drop")
                            if action == "merge" {destination.scene.receive(f.scene.store.conversation(id)!,at:1)}
                            f.scene.endTear(kept:action != "merge")
                        case .cancel:tears.append("cancel");f.scene.endTear(kept:true)
                        }
                    }
                    func event(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent {
                        NSEvent.mouseEvent(with:type,location:f.scene.dock.view.convert(point,to:nil),modifierFlags:[],timestamp:f.time,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                    }
                    if headerEntry {island.planetButton.mouseDown(with:event(.leftMouseDown,down))}
                    else {check(f.scene.pointerDown(down),"original bar hit target")}
                    check(f.scene.isHolding,"\(action) \(id) \(headerEntry ? "NSEvent header":"bar") press @\(scale)x")
                    if !headerEntry {check(original.dataProvider?.data==island.snapshot(scale:scale).dataProvider?.data,"bar down leaves header paint unchanged")}
                    func capture() {
                        phases.append(f.scene.isTearing ? "tearing":(f.scene.isHolding ? (f.scene.isDragging ? "carrying":"pressed"):"idle"))
                        springRows.append((f.scene.columns + Array(f.scene.leaving.values)).sorted{$0.conversation.id < $1.conversation.id}.map{[$0.rect.x.response,$0.rect.x.damping,$0.form.response,$0.form.damping,$0.presence.response,$0.presence.damping,$0.presence.to]})
                        f.tick();frames.append(f.scene.dock.items[id]?.glass.frame ?? .zero)
                        if f.scene.isDragging && !f.scene.isTearing {
                            let r=f.scene.dock.items[id]!.glass.frame,distance=hypot(pointer.x-r.midX,pointer.y-r.midY)
                            maxDistance=max(maxDistance,distance)
                            check(distance<=60,"physical pointer reaches carried item: \(distance) pt (limit 60)")
                            check(island.orbIsCarried == headerEntry,"only the picked-up header paint is hidden")
                        }
                    }
                    func move(_ dx:CGFloat,_ dy:CGFloat=0) {
                        let p=CGPoint(x:down.x+dx,y:down.y+dy);pointer=p
                        if headerEntry {island.planetButton.mouseDragged(with:event(.leftMouseDragged,p))} else {f.scene.pointerDragged(p)}
                        capture()
                    }
                    capture();move(7.9);check(!f.scene.isDragging,"7.9 pt waits")
                    var end=down
                    if action != "short" {
                        move(8);check(f.scene.isDragging,"8 pt picks up")
                        check(f.scene.dock.items[id]?.role == .orb,"pickup takes the actual bar and changes it to an orb")
                        let otherLayout=f.scene.arrange(f.scene.members.filter{$0.id != id},current:f.scene.current).0
                        let overflowX=(otherLayout.bars+otherLayout.orbs).map(\.midX).max()!+1
                        let dx:CGFloat=tearCase ? 12:(action == "overflow" ? overflowX-grip.x:(which==0 ? 440:-440))
                        for k in 0...24 {move(8+(dx-8)*CGFloat(k)/24)}
                        check(f.scene.dock.items[id]!.glass.frame.width < home.width*0.8,"the actual bar shape contracts during hold")
                        end=CGPoint(x:down.x+dx,y:down.y)
                        if tearCase {
                            if action == "outside" {move(dx+f.scene.size.width+20);move(dx+f.scene.size.width+30);end.x+=f.scene.size.width+30}
                            else {move(dx,140);move(dx,150);end.y+=150}
                            check(f.scene.isTearing && f.scene.columns.count==1,"full/brief column contracts: one remaining column + Tear orb")
                            check(!f.scene.columns.contains{$0.conversation.id==id},"held conversation leaves shown columns")
                            check(f.scene.leaving[id]?.presence.to == 0 && (f.scene.leaving[id]?.presence.duration ?? 0)>0,"column has a complete shrinking presence spring")
                        } else if action == "swap" {for k in 0...24 {move(dx+(8-dx)*CGFloat(k)/24)};end.x=down.x+8}
                        if ["escape","tear-escape"].contains(action) {if headerEntry {island.planetButton.cancelOperation(nil)} else {f.scene.cancelDrag()}}
                        else if action == "resign" || action == "switch" {f.scene.cancelDrag()}
                        else {if headerEntry {island.planetButton.mouseUp(with:event(.leftMouseUp,end))} else {_=f.scene.pointerUp(end)}}
                    } else {
                        if headerEntry {island.planetButton.mouseUp(with:event(.leftMouseUp,down))} else {_=f.scene.pointerUp(down)}
                        check(clicks == (headerEntry ? 1:0),"short header click retains Customize; bar click belongs to its host")
                    }
                    capture();f.settle();capture()
                    check(!f.scene.isHolding && !f.scene.isTearing && !f.scene.dock.isHolding,"input and paint ownership released")
                    if action == "overflow" {
                        check(!f.scene.columns.contains{$0.conversation.id==id} && f.scene.dock.items[id]?.role == .orb,"full/brief lands fully contracted as a Dock orb")
                        check(f.scene.current != id,"contracted full passes current to another member")
                    }
                    if ["escape","resign","switch","tear-drop","tear-escape","outside","short"].contains(action) {check(f.scene.members.map(\.id)==members,"cancel / no reorder restores members")}
                    let trace:[String:Any]=["phases":phases,"reasons":f.scene.switches.compactMap{$0["reason"] as? String},"members":f.scene.members.map(\.id),"current":f.scene.current,"columns":f.scene.columns.map{$0.conversation.id},"role":String(describing:f.scene.dock.items[id]?.role),"tears":tears,"springs":springRows,"destination":destination.scene.members.map(\.id)]
                    traces.append(trace);poses.append(frames)
                    records.append(["kind":"paint","action":action,"which":which,"scale":scale,"header":headerEntry,"maxPointerDistance":maxDistance,"frames":frames.map{[$0.minX,$0.minY,$0.width,$0.height]}])
                }
                check(NSDictionary(dictionary:traces[0]).isEqual(to:traces[1]),"\(action) full/brief \(which) phases/reasons/results/springs parity @\(scale)x")
                let delta=zip(poses[0],poses[1]).map{MotionStep.edge($0,$1)}.max() ?? 0
                check(delta.isFinite,"\(action) physical paint has finite geometry")
                records.append(["action":action,"which":which,"scale":scale,"bar":traces[0],"header":traces[1],"maxDockEdgeDifference":delta])
            }
        }}
        for headerEntry in [false,true] {
            let f=HeaderFixture(scale:1);defer{f.dispose()}
            let h=f.headers[0],r=f.scene.dock.items["A"]!.glass.frame,p=headerEntry ? f.point(h):CGPoint(x:r.midX,y:r.minY)
            _ = headerEntry ? f.drag.begin(from:h,at:p):f.scene.pointerDown(p)
            try await Task.sleep(for:.milliseconds(300))
            check(f.scene.isDragging,"same stationary 250 ms long press")
            f.scene.cancelDrag();f.settle()
        }
        let parityChecks=checks
        try physicalHeaderCarry(output:output)
        try JSONSerialization.data(withJSONObject:["parityAndExisting":parityChecks,"physicalCarry":checks-parityChecks],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("header-check-groups.json"))
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible windows")
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("header-verification.json"))
    }
    /// Byte comparison evidence for ordinary (non-drag) switch and reversal, on a fixed clock.
    static func ordinaryFrames(output:URL) throws {
        NSApp.appearance=NSAppearance(named:.darkAqua)
        for scale:CGFloat in [1,2] {
            let f=HeaderFixture(scale:scale);defer{f.dispose()}
            f.time=100_000_000;f.scene.restOnSnapshot=true
            for c in f.scene.nodes.values {c.restOnSnapshot=true;c.showRest(full:c.isFull)}
            for h in f.headers {h.now={ [weak f] in f?.time ?? 0 }}
            // A view-owned backing layer may be reclaimed by AppKit during native header capture.
            // Keep the actual scene layers under a standalone renderer root instead.
            let host=CALayer(),renderer=OffscreenRenderer(size:f.scene.size,host:host,scale:scale)
            host.backgroundColor=Look.canvas.cgColor;host.addSublayer(f.scene.scene)
            var headers=[String:CALayer]()
            func shot(_ k:Int) {
                CATransaction.begin();CATransaction.setDisableActions(true)
                for h in f.scene.nodes.values.compactMap(\.island) {
                    guard let id=h.configuration?.id else {continue}
                    let layer=headers[id] ?? CALayer();headers[id]=layer;layer.anchorPoint = .zero
                    layer.isHidden=h.isHiddenOrHasHiddenAncestor
                    if !layer.isHidden {layer.frame=h.frame;layer.contents=h.snapshot(scale:scale);layer.opacity=Float(h.alphaValue)}
                    if layer.superlayer !== host {host.addSublayer(layer)}
                }
                CATransaction.commit()
                let pixels=renderer.render(at:f.time)
                if k==0 {check(stride(from:0,to:pixels.count,by:4).filter{max(pixels[$0],pixels[$0+1],pixels[$0+2])>72}.count>1000,"ordinary control contains real visible scene ink")}
                renderer.write(pixels,output.appendingPathComponent(String(format:"ordinary-%02d@%dx.png",k,Int(scale))))
            }
            shot(0);f.scene.switchTo(1,reason:"ordinary-pixel-control")
            for k in 1...72 {
                if k == 12 {f.scene.switchTo(0,reason:"ordinary-pixel-reverse")}
                f.tick();shot(k)
            }
            f.scene.settle();f.tick();shot(73)
            check(NSApp.windows.allSatisfy{!$0.isVisible},"ordinary pixel control has no visible window")
        }
    }

}
#endif
