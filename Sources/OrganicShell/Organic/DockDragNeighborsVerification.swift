#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Exercise the production preview spring with the same 0.35 s legs as reorder-drag.*.fast.
@MainActor enum DockDragNeighborsVerification {
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for exposure in [false,true] {for hz in [60.0,120.0] {for carrier in ["bar-A","bar-B","grip","me"] {
            let all=Array(MockSeed.make().prefix(6)),store=ConversationStore(conversations:all,projects:MockSeed.projects,devices:MockSeed.devices)
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
            scene.ambient=false;scene.manualSettle=true;scene.dock.motionEnabled=exposure
            var now=1000.0;scene.now={now};scene.dock.motionTime={now};scene.install();scene.dock.editing=true
            func plain(_ duration:Double) {let count=max(1,Int(ceil(duration*hz)));for _ in 0..<count {now += duration/Double(count);scene.frame(now)}}
            plain(0.8)
            let heldIndex=carrier=="bar-A" ? 0:(carrier=="bar-B" ? 1:2),id=carrier=="me" ? DockNode.meID:all[heldIndex].id
            if carrier=="me" {
                var next=scene.members;next.swapAt(0,1)
                scene.commit(scene.prepare(members:next,current:scene.current,at:now,spring:AutoScene.previewSpring),reason:"r20-me-moving-neighbours",prewarmed:false,start:CACurrentMediaTime())
                plain(0.05)
            }
            let source=carrier=="me" ? scene.dock.mePaintedFrame:scene.dock.items[id]!.glass.frame
            let start=CGPoint(x:source.midX,y:carrier=="me" ? source.midY:source.minY)
            scene.drag=AutoScene.Drag(id:id,start:start,began:true,insertAt:heldIndex,before:scene.members,beforeCurrent:scene.current)
            if carrier=="me" {scene.dock.holdMe(at:start)} else {scene.dock.hold(id,at:start,now:now,spring:AutoScene.queueSpring)}
            let excluded=carrier=="me" ? "me":"item."+id
            var frames=0,moves=0,bad=0,llBad=0,llSamples=0,overshoot=0
            var minimum=Double.infinity,state:[String:Bool]=[:],flips:[String:Int]=[:],joined:[String:Int]=[:]
            var failures:[[String:Any]]=[]
            func sample() {
                now += 1/hz;scene.frame(now);frames += 1
                let parts=scene.dock.physicalGlassSnapshot.filter{!$0.hidden && $0.id != excluded}
                for i in parts.indices {for j in parts.indices where j>i {
                    let a=parts[i],b=parts[j]
                    guard min(a.frame.maxY,b.frame.maxY)-max(a.frame.minY,b.frame.minY)>min(a.frame.height,b.frame.height)*0.25 else {continue}
                    let key=[a.id,b.id].sorted().joined(separator:"|"),gap=Double(DockGlassTopology.gap(a.frame,b.frame)),connected=gap<=10
                    minimum=min(minimum,gap)
                    if let old=state[key],old != connected {flips[key,default:0] += 1}
                    if connected && state[key] != true {joined[key,default:0] += 1}
                    state[key]=connected
                    if gap<12-0.001 {
                        bad += 1
                        if failures.count<40 {failures.append(["time":now,"pair":key,"gap":gap,"a":DockHandoffVerification.vector(a.frame),"b":DockHandoffVerification.vector(b.frame)])}
                    }
                    if DockGlassTopology.gap(a.logical,b.logical)<10 {overshoot += 1}
                    if a.id=="me" || b.id=="me" {llSamples += 1;if connected {llBad += 1}}
                }}
            }
            for _ in 0..<Int(ceil(0.32*hz)) {sample()}
            let far=carrier=="me" ? CGFloat(250):(start.x>640 ? CGFloat(335):CGFloat(1002))
            var x=start.x
            for _ in 0..<5 {for goal in [far,start.x] {
                let origin=x,count=Int(ceil(0.35*hz))
                for k in 1...count {
                    x=origin+(goal-origin)*CGFloat(k)/CGFloat(count)
                    scene.pointerDragged(CGPoint(x:x,y:start.y));moves += 1;sample()
                }
            }}
            for _ in 0..<Int(ceil(0.4*hz)) {sample()}
            let previews=scene.switches.filter{($0["reason"] as? String)=="drag-preview"}.count
            let tag="R20 non-carried neighbours carrier=\(carrier) exposure=\(exposure) hz=\(hz)"
            check(frames>Int(3.5*hz) && moves>=Int(3.5*hz),tag+" has real display callbacks and pointer moves")
            check(carrier=="me" || previews>=5,tag+" uses real AutoScene insertion previews: \(previews)")
            check(bad==0,tag+" final native pairs retain 12pt clearance: \(bad), minimum=\(minimum)")
            check(joined.isEmpty,tag+" no non-carried pair joins: \(joined)")
            if carrier != "bar-B" {check(overshoot>0,tag+" actually crosses the logical fusion distance: \(overshoot)")}
            check(llBad==0 && (carrier=="me" || llSamples>0),tag+" LL never joins a moving neighbour: \(llBad)")
            scene.cancelDrag();plain(1.5)
            rows.append(["carrier":carrier,"exposure":exposure,"hz":hz,"frames":frames,"moves":moves,"previews":previews,
                "minimumNativeGap":minimum,"badClearanceSamples":bad,"nonCarriedJoins":joined,"fusionFlips":flips,"LLJoins":llBad,
                "logicalOverlapSamples":overshoot,"firstFailures":failures])
            scene.clock.invalidate();scene.disposeTranscriptPresentation()
        }}}
        check(rows.count==16,"R20 executes all 16 native preview sequences")
        check(NSApp.windows.allSatisfy{!$0.isVisible},"R20 preview checks show no window")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("drag-neighbours.json"))
    }
}
#endif
