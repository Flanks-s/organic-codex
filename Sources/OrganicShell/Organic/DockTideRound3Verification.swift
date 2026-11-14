#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

@MainActor enum DockTideRound3Verification {
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var reports:[[String:Any]]=[]
        for room2 in [false,true] {
            let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
            scene.restOnSnapshot=true;scene.ambient=false;scene.manualSettle=true;scene.install(members:MockSeed.windowMembers)
            let dock=scene.dock;var now=CACurrentMediaTime()+100
            dock.motionTime={now};dock.prepareTideMaterialNow();dock.setTideCapacityFixture(room2 ? 461:nil)
            let prepared=dock.tideProbe["preparedTailViews"] as? [String:Int] ?? [:]
            check(!prepared.isEmpty && prepared.values.allSatisfy{$0==TideTailBudget.pieces},"native parts are ready before delivery: \(room2)")
            var until=0.0,callbackPending=false,requests:[Double]=[]
            dock.onNeedsFrames={duration in requests.append(duration);until=max(until,now+duration);callbackPending=true}
            dock.onNeedsFramesUntil={end in until=max(until,end);callbackPending=true}
            let target=dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.first!.id
            let originalTint=dock.items["C"]!.glass.tintColor
            let began=now
            store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":.string(target),"turn":["id":"tide-r3"]]))
            store.apply(.init(id:2,time:10,method:"item/started",params:["threadId":.string(target),"turnId":"tide-r3","item":["id":"cmd","type":"commandExecution","command":"swift build -c release"]]))
            check(scene.idleMotionUntil>CACurrentMediaTime()+0.20,"active Tide defers unrelated idle preparation without requesting long display work")
            var holdingCallbacks=0,rows:[[String:Any]]=[],firstWidth=0.0,firstReady=false
            for frame in 1...660 {
                let t=Double(frame)/60;now=began+t
                if frame==120 {store.apply(.init(id:3,time:12,method:"item/completed",params:["threadId":.string(target),"turnId":"tide-r3","item":["id":"cmd","type":"commandExecution","command":"swift build -c release"]]))}
                if let due=dock.tideProbe["nextWakeAt"] as? Double,due<=now {dock.serviceTideDeadline()}
                if callbackPending {
                    callbackPending=false;dock.frame(at:now,elapsed:.infinity)
                    callbackPending=until>=now
                    if (t>=3.5 && t<=4.3) || (t>=5 && t<=8.4) {holdingCallbacks+=1}
                    if frame==1 {
                        let shapes=(dock.tideProbe["material"] as? [String:Any])?["shapes"] as? [[String:Any]] ?? []
                        firstReady=shapes.allSatisfy{($0["allocatedTailViews"] as? Int)==TideTailBudget.pieces} && !shapes.isEmpty
                        let bubbles=dock.tideProbe["bubbles"] as? [[String:Any]] ?? []
                        let raw=bubbles.first{($0["id"] as? String)=="C"}?["raw"] as? [CGFloat] ?? []
                        let physical=dock.items["C"]!.glass.frame
                        firstWidth=physical.width
                        firstReady = firstReady && raw.count==4 && abs(physical.minX-raw[0])<0.01 && abs(physical.minY-raw[1])<0.01 && abs(physical.height-raw[3])<0.01
                    }
                }
                if frame==1 {
                    let opacity=dock.tideProbe["ownerOriginalOpacity"] as? Double ?? -1
                    check(opacity>0 && opacity<1,"normal owner badge leaves continuously over .07 seconds: \(room2)")
                }
                if frame==60 {check(abs(Double(dock.items["C"]!.glass.tintColor?.alphaComponent ?? 0)-0.92)<0.001,"native tint carries the R2 chroma compensation: \(room2)")}
                if frame==12 {
                    let faces=dock.tideProbe["faces"] as? [String:[String:Any]] ?? [:]
                    check((faces["C"]?["bodyBlur"] as? Double ?? 0)>0,"borrowed glyph body receives entrance blur: \(room2)")
                }
                if frame==540,!room2 {check(dock.items["C"]!.glass.tintColor == originalTint,"restored brief reaches its original tint before tail cleanup")}
                if [1,60,120,180,240,300,480,511,540,600,660].contains(frame) {
                    var row=dock.tideProbe;row["offset"]=t;rows.append(row)
                }
            }
            check(requests.allSatisfy{$0<=1.0/60},"Tide never requests frames for its occupancy duration: \(room2)")
            check(holdingCallbacks==0,"visually settled Tide requests zero display callbacks: \(room2), \(holdingCallbacks)")
            check(firstReady && abs(firstWidth-155.301179093235)<0.1,"first board pose uses existing native pieces: \(room2), \(firstWidth)")
            check(dock.tideProbe["arrivalGlassAllocations"] as? Int == 0,"event/display delivery allocates zero native tail views: \(room2)")
            let writes=dock.tideProbe["glassWrites"] as? [String:Int] ?? [:]
            check(writes["still"]==0,"visually settled Tide commits zero glass writes: \(room2), \(writes)")
            check(dock.tideProbe["phase"] as? String == "idle","deadline wakes natural return while the display link sleeps: \(room2)")
            reports.append(["room2":room2,"holdingCallbacks":holdingCallbacks,"requests":requests,"samples":rows])
            scene.disposeTranscriptPresentation()
        }
        let cold=DockCapsuleVerification.Fixture(scale:2,exposure:false)
        cold.store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"D","turn":["id":"cold"]]))
        cold.dock.receiveTide(cold.all[3]);cold.now+=1.0/60;cold.dock.frame(at:cold.now,elapsed:.infinity)
        check(cold.dock.tideProbe["arrivalGlassAllocations"] as? Int == 0 && cold.dock.items["C"]!.glass.frame.width<159,"cold first frame defers tail allocation and still applies its body pose")
        cold.now+=0.4;cold.dock.frame(at:cold.now,elapsed:.infinity)
        check(cold.dock.tideProbe["owner"] as? String == "D","partial cold warmup never indexes an unavailable native part")
        let resting=DockCapsuleVerification.Fixture(scale:2,exposure:false)
        resting.dock.prepareTideMaterialNow()
        resting.store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"D","turn":["id":"resting"]]))
        resting.dock.receiveTide(resting.all[3]);resting.now+=1.8;resting.dock.frame(at:resting.now,elapsed:.infinity)
        let before=(resting.dock.tideProbe["glassWrites"] as? [String:Int])?["still"]
        for _ in 0..<3 {resting.dock.frame(at:resting.now,elapsed:.infinity);resting.dock.refreshWords()}
        let after=(resting.dock.tideProbe["glassWrites"] as? [String:Int])?["still"]
        check(before != nil && after==before,"unrelated callbacks commit zero unchanged Tide glass writes")
        let f=DockCapsuleVerification.Fixture(scale:2,exposure:false)
        f.dock.prepareTideMaterialNow()
        let c=f.dock.restingTargets.first{$0.id=="C"}!.rect
        let badgeBefore=f.dock.items["C"]!.decoration.verificationConfiguration?.badge
        check(f.dock.stageTideMaterialProbe([.init(owner:"C",body:CGRect(x:c.minX,y:c.midY-18,width:36,height:36))]),"static face fixture mounts")
        let faces=f.dock.tideMaterialProbe["faces"] as? [String:[String:Any]] ?? [:]
        check(faces["C"]?["badge"] as? Bool == false && faces["C"]?["opacity"] as? Double == 1,"static Tide face has no badge")
        check(f.dock.items["C"]!.decoration.verificationConfiguration?.badge == badgeBefore,"Tide preserves the normal orb's badge configuration")
        let shapes=f.dock.tideMaterialProbe["shapes"] as? [[String:Any]] ?? []
        check(shapes.first?["shadowOutsideGlassContainer"] as? Bool == true,"shadow lives outside the material container")
        f.dock.clearTideMaterialProbe()
        check(f.dock.items["C"]!.decoration.verificationConfiguration?.badge == badgeBefore,"normal badge remains available after Tide")
        check(NSApp.windows.allSatisfy{!$0.isVisible},"round3 opens no visible windows")
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round3.json"))
    }
}
#endif
