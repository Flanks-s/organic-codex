#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

@MainActor enum DockTideRound4Verification {
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var reports:[[String:Any]]=[]
        for room2 in [false,true] {
            let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
            let replay=MockReplay(store:store);for c in store.conversations where c.running {replay.stop(c)}
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
            scene.restOnSnapshot=true;scene.ambient=true;scene.manualSettle=true;scene.install(members:MockSeed.windowMembers)
            let dock=scene.dock;var now=CACurrentMediaTime()+100;dock.motionTime={now};dock.prepareTideMaterialNow();dock.setTideCapacityFixture(room2 ? 461:nil)
            var requested=0;dock.onNeedsFrames={_ in requested+=1};dock.onNeedsFramesUntil={_ in requested+=1}
            store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"D","turn":["id":"r4"]]))
            store.apply(.init(id:2,time:10,method:"item/started",params:["threadId":"D","turnId":"r4","item":["id":"cmd","type":"commandExecution","command":"swift build"]]))
            for _ in 0..<180 {now+=1.0/60;dock.frame(at:now,elapsed:.infinity)}
            let roots=[("dock",dock.view),("scene",scene.sceneView),("native",scene.nativePlane)]
            var row:[String:Any]=["room2":room2,"beforeWake":DockTideAnimationAudit.snapshot(roots)]
            check(dock.tideProbe["motionBusy"] as? Bool == false,"actual Tide has reached visual rest: \(room2)")
            dock.setAmbientRunning(false);dock.setAmbientRunning(true)
            let after=DockTideAnimationAudit.snapshot(roots);row["afterWake"]=after
            check(after["runningLoops"] as? Int == 0,"ambient wake cannot restart a hidden Tide owner's infinite liquid: \(room2)")
            let clocks=DockTideAnimationAudit.clocks([("scene",scene.clock)]+dock.tideClockOwners)
            row["clocks"]=clocks
            check(clocks["activeDisplayLinks"] as? Int == 0,"settled Tide owns no running display link: \(room2)")
            let before=requested
            now+=0.5;dock.serviceTideDeadline()
            check(before==requested,"settled ownership and ambient wake request no display frames: \(room2)")
            dock.retireTide();dock.refreshOrbs()
            let returned=DockTideAnimationAudit.snapshot(roots);row["afterRetire"]=returned
            check((returned["filters"] as? [[String:Any]] ?? []).allSatisfy{($0["type"] as? String) != "gaussianBlur" || ($0["enabled"] as? Bool) != true},"retiring Tide detaches its Gaussian surfaces: \(room2)")
            reports.append(row);scene.disposeTranscriptPresentation()
        }
        let trialStore=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        let replay=MockReplay(store:trialStore);for c in trialStore.conversations where c.running {replay.stop(c)}
        let trialScene=AutoScene(size:CGSize(width:1280,height:820),store:trialStore,profile:M10DockMotion.dell,scale:2)
        trialScene.restOnSnapshot=true;trialScene.ambient=true;trialScene.manualSettle=true;trialScene.install(members:MockSeed.windowMembers)
        let dock=trialScene.dock;dock.prepareTideMaterialNow()
        trialStore.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"D","turn":["id":"loop"]]))
        trialStore.apply(.init(id:2,time:10,method:"item/started",params:["threadId":"D","turnId":"loop","item":["id":"cmd","type":"commandExecution","command":"swift build"]]))
        let c=dock.restingTargets.first{$0.id=="C"}!.rect
        check(dock.stageTideMaterialProbe([.init(owner:"C",body:CGRect(x:c.minX,y:c.midY-18,width:36,height:36))]),"old still fixture mounts after retiring real Tide")
        let roots=[("dock",dock.view)]
        let ordinary=DockTideAnimationAudit.snapshot(roots)
        let priorWaves=(ordinary["animations"] as? [[String:Any]] ?? []).filter{($0["key"] as? String)=="wobble" && ($0["running"] as? Bool)==true}
        check(dock.tideAnimationDiagnostics["tideRequestsDisplayFrames"] as? Bool == false,"ordinary ink is independent of the Tide clock")
        let originalParents=dock.items["D"]!.glass.contentView!.subviews
        check(dock.beginTideAnimationTrial(owner:"D"),"explicit mock loop ablation starts")
        let during=DockTideAnimationAudit.snapshot(roots)
        let waves=(during["animations"] as? [[String:Any]] ?? []).filter{($0["key"] as? String)=="wobble" && ($0["running"] as? Bool)==true}
        switch TideAnimationMode.selected {
        case .static:
            check(waves.isEmpty,"static ablation stops the ordinary liquid clock")
            dock.setAmbientRunning(false);dock.setAmbientRunning(true)
            check(DockTideAnimationAudit.snapshot(roots)["runningLoops"] as? Int == 0,"ambient wake respects static diagnostic ownership")
        case .board:check(waves.count==priorWaves.count,"board diagnostics preserve the independent ambient policy")
        case .lowrate:check(waves.count==priorWaves.count,"lowrate diagnostics do not manufacture a loop")
        case .offglass:
            check(waves.count==priorWaves.count,"offglass diagnostics do not manufacture a loop")
            check(!priorWaves.isEmpty || dock.items["D"]!.glass.contentView!.subviews.count == originalParents.count,"offglass retains all content when no looping face exists")
        }
        dock.endTideAnimationTrial()
        check(dock.items["D"]!.glass.contentView!.subviews.elementsEqual(originalParents,by:{$0 === $1}),"loop ablation restores original content views in order")
        let after=DockTideAnimationAudit.snapshot(roots)
        let returnedWaves=(after["animations"] as? [[String:Any]] ?? []).filter{($0["key"] as? String)=="wobble" && ($0["running"] as? Bool)==true}
        check(returnedWaves.count==priorWaves.count,"ending diagnostics restores the independent ambient policy")
        reports.append(["trialMode":TideAnimationMode.selected.rawValue,"ordinary":ordinary,"duringTrial":during,"afterTrial":after])
        trialScene.disposeTranscriptPresentation()
        check(NSApp.windows.allSatisfy{!$0.isVisible},"round4 opens no visible windows")
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round4.json"))
    }
}
#endif
