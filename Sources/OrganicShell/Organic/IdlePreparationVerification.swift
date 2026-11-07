import AppKit
import QuartzCore

/// Exercises the production idle job through --selftest's existing early-return entry; no App controller/window.
@MainActor enum M11PrewarmVerification {
    static func run(to out:URL)->(checks:Int,findings:[String]) {
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var checks=0,findings:[String]=[],reports:[[String:Any]]=[]
        @MainActor func check(_ ok:Bool,_ message:String) {checks+=1;if !ok {findings.append(message);print("FINDING",message)}}
        @MainActor func pump(_ seconds:Double,until ready:()->Bool={false}) {
            let end=Date().addingTimeInterval(seconds)
            while Date()<end && !ready() {_=RunLoop.main.run(mode:.default,before:min(end,Date().addingTimeInterval(0.002)))}
        }
        for shared in [false,true] {for scale:CGFloat in [1,2] {autoreleasepool {
            let tag="\(Int(scale))x-\(shared ? "shared":"owned")",store=ConversationStore()
            let replay=MockReplay(store:store);replay.start(live:false)
            let scene=AutoScene(size:CGSize(width:1080,height:760),store:store,
                profile:.init(name:"M11 120 Hz fixture",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,
                transcriptSessions:shared ? NativeTranscriptSessions():nil)
            scene.pressedButtons={0};scene.manualSettle=true;scene.verificationIdlePrewarm=true;scene.verificationPresented=true;scene.ambient=false
            var time=CACurrentMediaTime()+3600;scene.now={time};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            if shared {scene.setTranscriptPresentationActive(true)}
            defer {scene.disposeTranscriptPresentation()}
            @MainActor func settle() {time=max(time,scene.transitionEnd+0.1);scene.clock.onFrame?(time);scene.settle();CATransaction.flush()}
            settle()
            let frames=scene.columns.map{$0.native.frame},hidden=scene.columns.map{$0.native.isHidden},masks=scene.columns.map{$0.native.layer?.mask}
            M10ColumnWorkTrace.reset();scene.prewarm()
            pump(12,until:{scene.idlePrewarmOutcome=="completed"})
            check(scene.idlePrewarmOutcome=="completed","idle job completes \(tag): \(scene.idlePrewarmOutcome)")
            let slices=scene.idlePrewarmSlices,maxSlice=slices.map(\.ms).max() ?? 0
            check(!slices.isEmpty,"idle path executed measured slices \(tag)")
            check(maxSlice<=8,"every resumed slice <=8ms \(tag): \(maxSlice)")
            check(zip(scene.columns,frames).allSatisfy{$0.form.to<0.5 || $0.native.frame==$1} && scene.columns.map{$0.native.isHidden}==hidden,"idle capture restores native geometry/visibility \(tag)")
            check(zip(scene.columns,masks).allSatisfy{$0.native.layer?.mask === $1},"idle capture restores original masks \(tag)")
            check(!M10ColumnWorkTrace.events.contains{$0.name=="scene.prepare" || $0.name=="column.viewport"},"idle job never calls monolithic prepare/capture \(tag)")
            let idleEvents=M10ColumnWorkTrace.events
            print("IDLE",tag,"slices",slices.count,"max",maxSlice,"slowest",slices.sorted{$0.ms>$1.ms}.prefix(4).map{"\($0.name) \(($0.ms*10).rounded()/10)"},"unsupported",idleEvents.filter{$0.name=="scene.prewarm.unsupported"}.map(\.fields))
            scene.switchTo(1,reason:"idle-verification")
            check(scene.lastSwitch?["prewarmed"] as? Bool == true,"switch consumes sliced plan \(tag)")
            check(scene.isMoving,"warm switch starts before input returns \(tag)")
            check(scene.columns.flatMap{$0.bakedPresence}.isEmpty,"sharp idle plan allocates no presence replicas \(tag)")
            let audit=scene.scene.sublayers?.filter{$0.name=="organic.flights"}.flatMap{ReplicaContainerAudit.inspect($0,scenario:"idle-prewarmed",frame:0,time:time,includeDormant:false)} ?? []
            check(scene.scene.sublayers?.contains{$0.name=="organic.flights"} == true,"replica audit visits the flight plane \(tag)")
            check(audit.isEmpty,"sliced plan passes replica container audit \(tag): \(audit.count)")
            settle()
            scene.prewarm();pump(12,until:{scene.idlePrewarmOutcome=="completed"})
            M10ColumnWorkTrace.reset();scene.newChat()
            check(scene.lastSwitch?["prewarmed"] as? Bool == true,"New Chat opening consumes automatic plan \(tag): \(M10ColumnWorkTrace.events.filter{$0.name=="scene.prewarm.lookup"}.map(\.fields))")
            settle();scene.prewarm();pump(12,until:{scene.idlePrewarmOutcome=="completed"})
            let cancelSlices=scene.idlePrewarmSlices
            check(!cancelSlices.isEmpty && cancelSlices.allSatisfy{$0.ms<=8},"automatic cancel preparation slices <=8ms \(tag): \(cancelSlices.map(\.ms).max() ?? 0)")
            M10ColumnWorkTrace.reset();scene.cancelNewChat()
            check(scene.lastSwitch?["prewarmed"] as? Bool == true,"cancel consumes automatic plan \(tag)")
            check(!M10ColumnWorkTrace.events.contains{$0.name=="scene.prepare"},"automatic cancel hit has no synchronous prepare \(tag)")
            settle()
            // Interrupt a real in-progress job with pointer input; it must stay quiet rather than finish in input.
            scene.prewarm();pump(2,until:{scene.idlePrewarmOutcome=="running"})
            M10ColumnWorkTrace.reset();let inputStart=CACurrentMediaTime();scene.pointer(CGPoint(x:40,y:100));let inputMs=(CACurrentMediaTime()-inputStart)*1000
            pump(0.08)
            check(!M10ColumnWorkTrace.events.contains{$0.name=="scene.prewarm.slice"},"pointer input suspends all idle slices for the quiet period \(tag)")
            check(inputMs<8,"pointer callback never drains a cold plan \(tag): \(inputMs)")
            // A model publication cancels the continuation. Native refresh remains its existing separate path.
            store.changed(scene.columns[0].conversation)
            M10ColumnWorkTrace.reset();pump(0.08)
            check(!M10ColumnWorkTrace.events.contains{$0.name=="scene.prewarm.slice"},"stream publication yields before another idle slice \(tag)")
            // Input during incomplete preparation uses the exact existing synchronous fallback immediately.
            scene.columns[0].conversation.revision+=1
            scene.switchTo(0,reason:"idle-incomplete")
            check(scene.lastSwitch?["prewarmed"] as? Bool == false,"invalid/incomplete plan uses cold fallback \(tag)")
            check(scene.isMoving && M10ColumnWorkTrace.events.contains{$0.name=="scene.prepare"},"cold fallback begins motion in input callback \(tag)")
            reports.append(["lookup":M10ColumnWorkTrace.events.filter{$0.name=="scene.prewarm.lookup"}.map(\.fields),"tag":tag,"maxSliceMs":maxSlice,"inputMs":inputMs,"cancelSlices":cancelSlices.map{["phase":$0.name,"ms":$0.ms]},"slices":slices.map{["phase":$0.name,"ms":$0.ms]},
                "unsupported":idleEvents.filter{$0.name=="scene.prewarm.unsupported"}.map(\.fields)])
        }}}
        M10ColumnWorkTrace.active=false
        try? JSONSerialization.data(withJSONObject:["checks":checks,"findings":findings,"reports":reports,
            "boundary":"offscreen main-thread CPU/idle cancellation and structure; no presented-frame or live-input timing claim"],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
        return (checks,findings)
    }
}
