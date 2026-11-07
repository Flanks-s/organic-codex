#if M10_DOCK_SELFTEST
import AppKit

/// Pointer motion within one insertion position must not consume a layout handoff's one-way budget.
@MainActor enum DockDragTopologyVerification {
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for exposure in [false,true] {for hz in [60.0,120.0] {
            let w=DockHandoffVerification.Walk(name:"held-pointer",exposure:exposure),f=w.f
            w.cadence=1/hz;w.setup("rest")
            let id=f.all[1].id,neighbor=f.all[2].id,item=f.dock.items[id]!,other=f.dock.items[neighbor]!
            func pointer(_ center:CGPoint)->CGPoint {
                let row=f.layout.me.midY-f.dock.rise
                return CGPoint(x:center.x,y:row+(center.y-row+4)/0.4)
            }
            let source=item.glass.frame
            f.dock.hold(id,at:pointer(CGPoint(x:source.midX,y:source.midY)),now:f.now,spring:(0.3,0.8));w.tick();w.advance(0.8)
            let epoch=f.began,order=f.order
            for cycle in 0..<5 {for close in [true,false] {
                let target=other.motion.rect ?? other.glass.frame,d=item.motion.rect!.width
                // Overlap already satisfies the unchanged 1 pt connection margin.
                let gap:CGFloat=close ? -2:CGFloat(60+55*cycle)
                let center=CGPoint(x:target.minX-gap-d/2,y:target.midY)
                f.dock.moveHeld(to:pointer(center));w.tick(w.cadence)
                let raw=other.motion.rect!,native=other.glass.frame,held=item.glass.frame
                let growth=max(0,native.width-raw.width),actualGap=DockGlassTopology.gap(held,native)
                let connected=f.dock.topologyConnected(id,neighbor)
                let tag="R19 held pointer exposure=\(exposure) hz=\(hz) cycle=\(cycle) close=\(close)"
                check(growth<0.001,tag+" neighbour does not stretch: \(growth)")
                check(connected == close,tag+" follows the current logical gap")
                check(close ? actualGap<=10:actualGap>=12-0.001,tag+" native fusion does not stick: \(actualGap)")
                rows.append(["path":"held-pointer","exposure":exposure,"hz":hz,"cycle":cycle,"close":close,"growth":growth,"gap":actualGap,"connected":connected ?? false,"raw":DockHandoffVerification.vector(raw),"native":DockHandoffVerification.vector(native)])
            }}
            check(f.began==epoch && f.order==order,"R19 five pointer sweeps have no commit or insertion change")
            f.dock.release();w.commit(f.auto());w.advance(1.5)
            check(!f.dock.isHolding,"R19 held pointer release completes")
        }}
        for exposure in [false,true] {for hz in [60.0,120.0] {for escape in [false,true] {
            let all=Array(MockSeed.make().prefix(6)),store=ConversationStore(conversations:all,projects:MockSeed.projects,devices:MockSeed.devices)
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
            scene.ambient=false;scene.manualSettle=true;scene.dock.motionEnabled=exposure
            var now=1000.0;scene.now={now};scene.dock.motionTime={now};scene.install()
            scene.dock.editing=true;scene.frame(now)
            func advance(_ duration:Double) {let n=max(1,Int(ceil(duration*hz)));for _ in 0..<n {now += duration/Double(n);scene.frame(now)}}
            advance(1)
            let home=scene.dock.mePaintedFrame,p=CGPoint(x:home.midX,y:home.midY),id=scene.members[0].id
            let bar=scene.dock.items[id]!,destinationX=scene.dock.items[id]!.glass.frame.minX+100
            scene.drag=AutoScene.Drag(id:DockNode.meID,start:p,began:true,before:scene.members,beforeCurrent:scene.current)
            scene.dock.holdMe(at:p);scene.frame(now)
            var maximumCut:CGFloat=0,joined=false
            for step in 1...16 {
                let center=CGPoint(x:p.x+(destinationX-p.x)*CGFloat(step)/16,y:p.y)
                scene.dock.moveMe(to:center);advance(1/hz)
                if step>=12 {
                    let raw=bar.motion.rect!,native=bar.glass.frame
                    maximumCut=max(maximumCut,abs(native.minX-raw.minX),abs(native.maxX-raw.maxX))
                    joined = joined || (scene.dock.topologyConnected("me",id)==true && DockGlassTopology.gap(scene.dock.mePaintedFrame,native)<=10)
                }
            }
            let tag="R19 me into bar exposure=\(exposure) hz=\(hz) escape=\(escape)"
            check(maximumCut<0.001,tag+" bar retains its raw contour: \(maximumCut)")
            check(joined,tag+" can fuse with the bar")
            if escape {scene.cancelDrag()} else {
                scene.dock.moveMe(to:p);advance(1/hz);_=scene.pointerUp(p)
            }
            advance(2)
            let homeGap=DockGlassTopology.gap(scene.dock.mePaintedFrame,bar.glass.frame)
            check(!scene.dock.isHoldingMe && scene.drag==nil,tag+" real drop/Esc releases me")
            check(homeGap>=12-0.001 && scene.dock.topologyConnected("me",id)==false,tag+" restores separated home: \(homeGap)")
            rows.append(["path":"me-into-bar","exposure":exposure,"hz":hz,"escape":escape,"maximumCut":maximumCut,"joined":joined,"restoredGap":homeGap])
            scene.clock.invalidate();scene.disposeTranscriptPresentation()
        }}}
        for exposure in [false,true] {for hz in [60.0,120.0] {
            let w=DockHandoffVerification.Walk(name:"peek-tail-pickup",exposure:exposure),f=w.f
            w.cadence=1/hz;w.setup("peek-protected")
            w.event("hover-out") {_=f.dock.pointer(nil,now:f.now)};w.advance(0.013)
            w.event("hover-in") {let r=f.dock.items[f.all[4].id]!.regular;_=f.dock.pointer(CGPoint(x:r.midX,y:r.midY),now:f.now)}
            w.event("grab") {
                let r=f.dock.items[f.all[0].id]!.glass.frame,row=f.layout.me.midY-f.dock.rise
                f.dock.hold(f.all[0].id,at:CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4),now:f.now,spring:(0.3,0.8))
            }
            let event=w.rows.last!,parts=event["parts"] as! [[String:Any]]
            let maximum=parts.filter {p in p["positionChecked"] as! Bool && (p["beforeRaw"] as! [Double]) == (p["afterRaw"] as! [Double])}
                .compactMap{$0["positionError"] as? Double}.max() ?? 0
            check(maximum<0.001,"R19 Peek tail pickup rebases visible raw-stable native exposure=\(exposure) hz=\(hz): \(maximum)")
            rows.append(["path":"peek-tail-pickup","exposure":exposure,"hz":hz,"maximumNativeError":maximum,"event":event])
        }}
        check(NSApp.windows.allSatisfy{!$0.isVisible},"R19 pointer regressions show no window")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("drag-topology.json"))
    }
}
#endif
