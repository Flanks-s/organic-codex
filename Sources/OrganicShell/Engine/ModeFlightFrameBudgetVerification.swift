#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Identical windowless production loops can be compiled against the fourth, seventh and current sources.
@MainActor enum ModeFlightFrameBudgetVerification {
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var records:[[String:Any]]=[]
        for (label,cut) in [("reverse",-1.0),("r80",0.08),("r540",0.54),("f280",0.28)] {
            let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:ConversationStore())
            let seeded=MockReplay(store:store);seeded.start(live:false)
            let sessions=NativeTranscriptSessions(store:store)
            let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
            scene.ambient=false;scene.manualSettle=true
            let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
            for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(plane);plane.frame=root.bounds}
            let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
            _=workbench.composerForHandoff();scene.install();scene.settle()
            let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic)
            // The resident system sidebar needs a real layout engine, even though the window stays unshown.
            let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua)
            window.contentViewController=shell;shell.installToolbar(in:window)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
            let forward=label == "f280"
            shell.verificationFlightSettle(asOrganic:!forward);shell.prepareModeSwitch(reason:"frame-budget")
            shell.verificationFlightToggle(toOrganic:forward);shell.verificationFlightAdmit()
            if cut>=0 {now+=cut;shell.flight.advance(at:cut);shell.verificationFlightToggle(toOrganic:!forward);shell.verificationFlightAdmit()}
            let start=now
            var components:[String:[Double]]=[:],wall:[Double]=[],activeWall:[Double]=[],framePhases:[String:Double]=[:]
            shell.flight.onExposureCost={name,value in framePhases[name,default:0]+=value*1000}
            for frame in 0..<220 {
                let displayDeadline=Date(timeIntervalSinceNow:1/120)
                now=start+Double(frame)/120
                framePhases=[:];let active=shell.flight.running
                let began=CACurrentMediaTime();shell.flight.advance(at:Double(frame)/120)
                let elapsed=(CACurrentMediaTime()-began)*1000
                wall.append(elapsed);if active {activeWall.append(elapsed)}
                let queued=CACurrentMediaTime()
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.0001))
                framePhases["main.queuedWork"]=(CACurrentMediaTime()-queued)*1000
                if active {for (name,value) in framePhases {components[name,default:[]].append(value)}}
                // Let the real endpoint work ticket commit; a fast synthetic loop cannot skip 300 ms of work boundaries.
                RunLoop.main.run(until:displayDeadline)
            }
            func stats(_ values:[Double])->[String:Any] {
                let sorted=values.sorted();guard !sorted.isEmpty else {return ["count":0]}
                return ["count":values.count,"meanMS":values.reduce(0,+)/Double(values.count),"p95MS":sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))],"maxMS":sorted.last!]
            }
            var phases:[String:Any]=[:];for (name,values) in components {phases[name]=stats(values)}
            records.append(["label":label,"wall":stats(wall),"activeWall":stats(activeWall),"phases":phases,"windowVisible":window.isVisible])
            shell.flight.onExposureCost=nil;shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seeded.stopPlayback();seed.stopPlayback()
        }
        try JSONSerialization.data(withJSONObject:["cases":records],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("frame-budget.json"))
        print("M11.31 production frame budget: \(records.count) sequences")
        return 0
    }
}
#endif
