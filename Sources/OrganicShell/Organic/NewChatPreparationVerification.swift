import AppKit
import QuartzCore

/// Extends SELFTEST_COLUMN_WORK; no new runtime switch, window, app controller or Core connection.
@MainActor enum M11NewChatVerification {
    static func run(to out:URL)->(checks:Int,findings:[String]) {
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var checks=0,findings:[String]=[],rows:[[String:Any]]=[]
        func check(_ ok:Bool,_ message:String) {checks+=1;if !ok {findings.append(message);print("FINDING",message)}}
        func count(_ name:String)->Int {M10ColumnWorkTrace.events.filter{$0.name==name}.count}
        for scale:CGFloat in [1,2] {autoreleasepool {
            let store=ConversationStore()
            let replay=MockReplay(store:store);replay.start(live:false)
            let scene=AutoScene(size:CGSize(width:1080,height:760),store:store,
                profile:.init(name:"M11 120 Hz fixture",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale)
            scene.manualSettle=true;scene.restOnSnapshot=true;scene.ambient=false;scene.verificationPresented=true
            var time=CACurrentMediaTime()+3600;scene.now={time};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            @MainActor func settle() {time=max(time,scene.transitionEnd+0.1);scene.clock.onFrame?(time);scene.settle();CATransaction.flush()}
            settle()
            let renderer=OffscreenRenderer(size:scene.size,host:scene.sceneView.layer!,scale:scale)
            let initial=renderer.render(at:time)
            scene.prewarm()
            let warm=renderer.render(at:time)
            check(initial==warm,"New Chat opening prewarm preserves all resting pixels \(scale)x")
            scene.newChat();settle()
            let draft=renderer.render(at:time)
            scene.prewarm()
            check(draft==renderer.render(at:time),"cancel prewarm preserves all resting pixels \(scale)x")
            let input=time
            M10ColumnWorkTrace.reset();scene.cancelNewChat()
            check(scene.lastSwitch?["prewarmed"] as? Bool == true,"pixel fixture cancel hits \(scale)x")
            check(scene.transitionEnd>input && count("scene.prepare")==0,"cancel commits immediately without deferred prepare \(scale)x")
            let first=renderer.render(at:input)
            let startDiff=renderer.tileDiff(draft,first).value
            check(startDiff<SelfTest.popThreshold,"cancel frame zero retains the existing continuity budget \(scale)x: \(startDiff)")
            settle()
            let cancelled=renderer.render(at:time)
            let endDiff=renderer.tileDiff(initial,cancelled).value
            check(endDiff<0.01,"cancel round trip keeps resting endpoint pixels \(scale)x: \(endDiff)")
            rows.append(["scale":scale,"cancelStartDiff":startDiff,"cancelEndpointDiff":endDiff])
            if startDiff>=SelfTest.popThreshold {renderer.write(draft,out.appendingPathComponent("cancel-before-\(Int(scale))x.png"));renderer.write(first,out.appendingPathComponent("cancel-first-\(Int(scale))x.png"))}
            if endDiff>=0.01 {renderer.write(initial,out.appendingPathComponent("rest-before-\(Int(scale))x.png"));renderer.write(cancelled,out.appendingPathComponent("rest-after-\(Int(scale))x.png"))}

            settle();scene.newChat();settle();scene.prewarm()
            scene.onCreate={text,_ in
                let c=Conversation(id:"pixel-send-\(Int(scale))",title:text);c.identityIndex=store.nextIdentity();return c
            }
            scene.onSubmit={c,request,done in let accepted=replay.send(c,text:request.text);done(accepted ? .accepted:.failed("fixture rejected"));return accepted}
            let composer=scene.composers.draft().composer
            composer.setText("Verify the first-send endpoint")
            check(composer.submit(),"pixel fixture first send accepted \(scale)x")
            let until=Date().addingTimeInterval(0.2)
            while Date()<until && composer.hasPendingSubmission {_=RunLoop.main.run(mode:.default,before:min(until,Date().addingTimeInterval(0.005)))}
            time=max(time+1.4,scene.transitionEnd+0.1);scene.clock.onFrame?(time);scene.settle()
            let sent=renderer.render(at:time)
            let layout=scene.layout,full=scene.layout.fullColumn
            for (i,column) in scene.columns.enumerated() {
                let others=layout.columns.indices.filter{$0 != full}
                let brief=i != full ? layout.columns[i].width:(others.first.map{layout.columns[$0].width} ?? 300)
                column.renderDisplay(fullWidth:layout.columns[full].width,briefWidth:brief,force:true)
                column.showRest(full:column.conversation.id==scene.current)
            }
            let rebuilt=renderer.render(at:time)
            let sendDiff=renderer.tileDiff(sent,rebuilt).value
            check(sendDiff<0.01,"first-send endpoint equals ordinary rest layout \(scale)x: \(sendDiff)")
            check(scene.dock.items[scene.current]?.ownComposer === composer && composer.alphaValue==1,"first-send endpoint retains its full native editor \(scale)x")
            rows.append(["scale":scale,"sendEndpointDiff":sendDiff])
            if sendDiff>=0.01 {renderer.write(sent,out.appendingPathComponent("send-settled-\(Int(scale))x.png"));renderer.write(rebuilt,out.appendingPathComponent("send-rebuilt-\(Int(scale))x.png"))}

            scene.newChat();settle();scene.prewarm()
            // A parked member is part of cancellation's target even when absent from source columns.
            let parked=scene.members.first{c in !scene.columns.contains{$0.conversation === c}}!
            parked.revision+=1
            M10ColumnWorkTrace.reset();scene.cancelNewChat()
            check(scene.lastSwitch?["prewarmed"] as? Bool == false && count("scene.prepare")==1,"parked member revision invalidates cancel plan \(scale)x")
            settle();scene.newChat();settle();scene.prewarm()
            scene.resize(to:CGSize(width:1082,height:760),live:false)
            M10ColumnWorkTrace.reset();scene.cancelNewChat()
            check(scene.lastSwitch?["prewarmed"] as? Bool == false && count("scene.prepare")==1,"resize invalidates cancel plan \(scale)x")
            settle();scene.newChat()
            time+=0.08;scene.clock.onFrame?(time)
            M10ColumnWorkTrace.reset();scene.cancelNewChat()
            check(scene.lastSwitch?["prewarmed"] as? Bool == false && count("scene.prepare")==1,"interrupted cancel prepares from its current springs \(scale)x")
            check(scene.isMoving,"interrupted cancel starts in the input callback \(scale)x")


        }}
        M10ColumnWorkTrace.active=false
        let report:[String:Any]=["checks":checks,"findings":findings,"rows":rows,
            "boundary":"offscreen CARenderer endpoint pixels and deterministic cache/commit checks; no presented-frame claim"]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
        return (checks,findings)
    }
}
