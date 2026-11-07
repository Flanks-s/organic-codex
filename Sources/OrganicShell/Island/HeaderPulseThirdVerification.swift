import AppKit
import QuartzCore

/// Third-review inputs preserve the host's ordering, including its real mode and ambient entry points.
@MainActor enum HeaderPulseThirdVerification {
    static func run(check:(Bool,String)->Void,evidence:inout [[String:Any]]) {
        for status in ["completed","failed","interrupted"] {
            let c=Conversation(id:"terminal",title:"Terminal"),store=ConversationStore()
            store.add(c)
            store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"terminal","turn":["id":"T"]]))
            store.apply(.init(id:2,time:20,method:"turn/completed",params:["threadId":"terminal","turn":["id":"T","status":.string(status)]]))
            let replay=HistoryReplay(conversation:c,cursor:2,seeded:true)
            let snapshot:JSONValue=["turns":[["id":"T","status":.string(status),"items":[]]]]
            EventReducer.hydrate(snapshot,into:c);replay.merge(into:c,snapshot:snapshot)
            let restored=c.notices.snapshot(in:c),count=c.notices.journal.count
            check(restored.turnID == "T" && restored.terminalStatus == status,"T1 automatic-read projection retains terminal \(status)")
            check(restored.startedAt == 10 && restored.endedAt == 20,"T1 automatic-read projection retains confirmed clock \(status)")
            store.apply(.init(id:3,time:21,method:"turn/completed",params:["threadId":"terminal","turn":["id":"T","status":.string(status)]]))
            check(c.notices.journal.count == count,"T1 restored terminal still deduplicates completion \(status)")
        }
        do {
            let c=Conversation(id:"context",title:"Context"),store=ConversationStore();store.add(c)
            func tokens(_ id:Int,_ used:Int) {store.apply(.init(id:id,time:nil,method:"thread/tokenUsage/updated",params:["threadId":"context","tokenUsage":["last":["totalTokens":.number(Double(used))],"modelContextWindow":1000]]))}
            tokens(1,899)
            EventReducer.hydrate(["turns":[]],into:c)
            let replay=HistoryReplay(conversation:c,cursor:1,seeded:true);replay.merge(into:c,snapshot:["turns":[]])
            let count=c.notices.journal.count;tokens(2,900)
            check(c.notices.journal.count == count+1 && c.notices.journal.last?.halo == .column,"T2 899/1000 restore then 900/1000 emits the first whole-column notice")
        }
        do {
            let f=fixture(),scene=f.scene,c=scene.columns[0].conversation
            var time=CACurrentMediaTime()+3600
            for column in scene.columns {column.island?.now={time}}
            time+=8.01;scene.setAmbientRunning(false)
            for (i,method) in ["turn/started","core/approvalRequested","error"].enumerated() {
                let params:JSONValue = method == "turn/started" ? ["turn":["id":"idle"]] : method == "error" ? ["message":"Synthetic failure","willRetry":false] : ["approvalId":"idle-request","request":["method":"item/commandExecution/requestApproval","params":["command":"Synthetic","availableDecisions":["accept","decline"]]]]
                var p=params.objectValue!;p["threadId"] = .string(c.id)
                scene.store.apply(.init(id:100+i,time:time,method:method,params:.object(p)))
                let event=c.notices.journal.last?.kind.rawValue
                check(scene.columns[0].island?.pulseProbe?["event"] as? String == event,"T3 event survives eight-second ambient pause: \(method)")
            }
            scene.disposeTranscriptPresentation();withExtendedLifetime(f) {}
        }
        do {
            let f=fixture(),scene=f.scene
            var time=CACurrentMediaTime()+3600;scene.now={time}
            scene.enterFocused(scene.current,reason:"pulse-test");time+=10;scene.settle()
            scene.splitWithNext();time+=10;scene.settle();scene.manualSettle=false
            check(!scene.isMoving && scene.columns.count>1,"T5 actual Split is at rest before consecutive deltas")
            guard let column=scene.columns.first,let header=column.island else {check(false,"T5 Split fixture is mounted");return}
            let menu=header.titleButton.menu,c=column.conversation
            var replacements=0
            for i in 0..<100 {
                scene.store.apply(.init(id:1000+i,time:nil,method:"item/agentMessage/delta",params:["threadId":.string(c.id),"turnId":"split-turn","itemId":"split-message","delta":"x"]))
                if header.titleButton.menu !== menu {replacements+=1}
            }
            check(header.configuration?.notices == nil,"T5 actual Split header does not consume notices")
            check(replacements == 0,"T5 100 consecutive Split deltas do not synchronously rebuild header menus")
            evidence.append(["third":"split","deltas":100,"immediateMenuReplacements":replacements])
            scene.disposeTranscriptPresentation();withExtendedLifetime(f) {}
        }
        check(NSApp.windows.allSatisfy{!$0.isVisible},"T3 synchronous regression creates no visible window")
    }

    /// Run in a fresh process before any other Header/bitmap checks to distinguish cold work from reuse.
    static func coldProbe(warm:Bool)->[String:Any] {
        _ = NSApplication.shared
        let began=CACurrentMediaTime(),header=HeaderIsland(),host=IslandPlane(frame:CGRect(x:0,y:0,width:507,height:320))
        let window=NSWindow(contentRect:host.bounds,styleMask:.borderless,backing:.buffered,defer:true)
        window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(header)
        var time=CACurrentMediaTime()
        header.now={time}
        var input=HeaderIslandConfiguration(id:"fresh-cold",title:"Fresh process Pulse",columnWidth:507,ambient:false)
        input.notices = .init();header.configure(input)
        let constructionMS=(CACurrentMediaTime()-began)*1000
        if warm { for _ in 0..<20 {RunLoop.current.run(until:Date().addingTimeInterval(0.002))} }
        let pulse=header.subviews.compactMap{$0 as? HeaderPulsePresentation}.first!
        let before=pulse.probe
        input.notices?.journal=[.init(id:1,kind:.command,text:"Synthetic first command")];header.configure(input)
        var costs:[Double]=[],retained:[NSObject]=[],identities:Set<ObjectIdentifier>=[]
        func collect(_ view:NSView) {
            for value in view.layer?.filters ?? [] {if let filter=value as? NSObject {retained.append(filter);identities.insert(ObjectIdentifier(filter))}}
            for child in view.subviews {collect(child)}
        }
        for _ in 0..<120 {
            time+=1/240;let start=CACurrentMediaTime();header.sampleMotion(at:time);costs.append((CACurrentMediaTime()-start)*1000);collect(pulse)
        }
        let result:[String:Any]=["warmRequested":warm,"constructionMS":constructionMS,"before":before,"after":pulse.probe,"sampleMS":costs,"uniqueContentFilters":identities.count,"visibleWindow":window.isVisible,
                                "scope":"Fresh-process AppKit construction, idle content caches and manual samples; no visible WindowServer composition."]
        header.dispose();window.close();withExtendedLifetime(retained) {};return result
    }

    struct Fixture {
        let store:ConversationStore,scene:AutoScene,root:RootView
        let replay:MockReplay
    }
    static func fixture(sessions:Bool=false)->Fixture {
        let store=ConversationStore()
        let bound=MockReplay(store:store);bound.start(live:false);_ = bound.setPaused(true)
        let shared=sessions ? NativeTranscriptSessions(store:store):nil
        let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:.init(name:"Pulse third review",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),scale:1,transcriptSessions:shared)
        scene.manualSettle=true;scene.ambient=false
        if !sessions {scene.verificationPresented=true}
        let root=RootView(frame:CGRect(x:0,y:0,width:1280,height:820));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=root.bounds;root.addSubview(plane)}
        scene.install();scene.clock.invalidate();scene.settle()
        return .init(store:store,scene:scene,root:root,replay:bound)
    }
}

#if PULSE_THIRD_SELFTEST
private actor PulseHistoryTransport:CoreTransport {
    let status:String
    private(set) var reads=0
    init(status:String) {self.status=status}
    func request(_ method:String,path:String,body:JSONValue?,timeout:TimeInterval?) async throws -> JSONValue {
        if body?["method"]?.stringValue == "thread/read" {
            reads+=1
            return ["thread":["id":"backend","turns":[["id":"T","status":.string(status),"items":[]]]]]
        }
        if path == "/health" {return ["name":"Organic Codex Core","backendConnected":true,"lastEventId":2,"pendingApprovals":[]]}
        if path.hasPrefix("/events.json") {return []}
        return [:]
    }
    nonisolated func events(since:Int,threadID:String?)->AsyncThrowingStream<CoreEvent,Error> {AsyncThrowingStream{$0.finish()}}
}
@MainActor private func spinIdleWarmup() {
    for _ in 0..<20 { RunLoop.current.run(until:Date().addingTimeInterval(0.002)) }
}
@main @MainActor enum PulseThirdVerificationMain {
    static func main() async {
        let path=CommandLine.arguments.dropFirst().first ?? "/tmp/organic-m1133d/third"
        if ProcessInfo.processInfo.environment["PULSE_COLD_ONLY"] == "1" {
            try? FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
            let result=HeaderPulseThirdVerification.coldProbe(warm:ProcessInfo.processInfo.environment["PULSE_COLD_WARM"] == "1")
            if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path).appendingPathComponent("cold.json"))}
            print("PULSE COLD",result["uniqueContentFilters"] ?? -1);exit(0)
        }
        var code=HeaderPulseVerification.run(to:path),checks=0,failures:[String]=[],rows:[[String:Any]]=[]
        func check(_ passed:Bool,_ label:String) {checks+=1;if !passed {failures.append(label);code=1;print("FINDING",label)}}
        for status in ["completed","failed"] {
            let c=Conversation(id:"runtime",title:"Runtime"),store=ConversationStore();c.backendThreadID="backend";c.isLiveConversation=true;store.add(c)
            let transport=PulseHistoryTransport(status:status),presentation=LocalPresentationState(store:store,scope:"pulse-third",storage:CoreMemoryStorage())
            let runtime=LiveConversationRuntime(store:store,client:transport,presentation:presentation);runtime.isShown={_ in true}
            runtime.receive(.init(id:1,time:10,method:"turn/started",params:["threadId":"backend","turn":["id":"T"]]))
            runtime.receive(.init(id:2,time:20,method:"turn/completed",params:["threadId":"backend","turn":["id":"T","status":.string(status)]]))
            for _ in 0..<500 {if await transport.reads>0 && !c.loading {break};await Task.yield()}
            let snapshot=c.notices.snapshot(in:c)
            check(await transport.reads>0,"T1 real completion schedules automatic runtime read \(status)")
            check(snapshot.terminalStatus == status && snapshot.startedAt == 10 && snapshot.endedAt == 20,"T1 automatic runtime read preserves confirmed terminal and clock \(status)")
            rows.append(["third":"runtime","status":status,"reads":await transport.reads,"terminal":snapshot.terminalStatus ?? "none","start":snapshot.startedAt ?? -1,"end":snapshot.endedAt ?? -1])
        }
        for animated in [false,true] {
            let f=HeaderPulseThirdVerification.fixture(sessions:true),scene=f.scene
            let workbench=NormieWorkbench(store:f.store,sessions:scene.composers,current:scene.current,transcriptSessions:scene.transcriptSessions)
            let shell=WindowShell(organic:f.root,scene:scene,workbench:workbench,mode:.organic)
            let window=NSWindow(contentRect:f.root.bounds,styleMask:.borderless,backing:.buffered,defer:true);window.isReleasedWhenClosed=false;window.contentViewController=shell
            _=shell.view;scene.setTranscriptPresentationActive(true);shell.split.view.isHidden=true
            let c=scene.columns[0].conversation,header=scene.columns[0].island!
            f.store.apply(.init(id:9000,time:nil,method:"turn/started",params:["threadId":.string(c.id),"turn":["id":"mode"]]))
            header.togglePin();check(header.pulseClockRunning,"T4 shown source Pulse link runs before real mode entry")
            if animated {shell.prepareModeSwitch(reason:"pulse-third")}
            shell.setMode(.normie,animated:animated)
            // An unshown window has no production display callback. Sample the real flight to admit its target.
            if animated {shell.flight.sample(at:0.02,profile:.init(name:"pulse-offscreen",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0))}
            let until=CACurrentMediaTime()+10
            while (shell.mode != .normie || scene.transcriptsPresented) && CACurrentMediaTime()<until {try? await Task.sleep(for:.milliseconds(10))}
            check(shell.mode == .normie && !scene.transcriptsPresented,"T4 real WindowShell setMode reaches Normie (animated=\(animated))")
            check(!header.pulseClockRunning && header.pulseProbe == nil,"T4 real mode retirement stops hidden Pulse link (animated=\(animated))")
            shell.setMode(.organic,animated:false)
            check(header.pulseProbe?["mode"] as? String != "expanded","T4 return to Organic does not revive the source pin")
            check(!window.isVisible,"T4 mode-switch host is never ordered onscreen")
            scene.disposeTranscriptPresentation();window.close();withExtendedLifetime(f) {}
        }
        #if !PULSE_THIRD_OLD_INPUT
        do {
            let header=HeaderIsland(),host=IslandPlane(frame:CGRect(x:0,y:0,width:507,height:320))
            let window=NSWindow(contentRect:host.bounds,styleMask:.borderless,backing:.buffered,defer:true);window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(header)
            var input=HeaderIslandConfiguration(id:"cold",title:"Cold Pulse",columnWidth:507,ambient:false)
            input.notices = .init();header.configure(input)
            spinIdleWarmup()
            let pulse=header.subviews.compactMap{$0 as? HeaderPulsePresentation}.first!
            let warm=pulse.probe
            check(warm["warmSlices"] as? Int == 10,"T6 actual beforeWaiting observer prewarms ten content layers")
            input.notices?.journal=[.init(id:1,kind:.command,text:"Synthetic cold command")];header.configure(input)
            let first=CACurrentMediaTime()
            for i in 1...48 {header.sampleMotion(at:first+Double(i)/240)}
            let after=pulse.probe
            check(after["filterBuilds"] as? Int == 10,"T6 first Pulse reuses prewarmed filters without frame allocations")
            rows.append(["third":"cold","warm":warm,"after":after,"scope":"Unshown AppKit content caches and sample CPU; WindowServer shader/composition costs require Claude's cold visible recording."])
            header.dispose();window.close()
        }
        #endif
        let result:[String:Any]=["checks":checks,"failures":failures,"evidence":rows]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path).appendingPathComponent("third.json"))}
        print("PULSE THIRD \(checks) checks \(failures.count) findings, exit \(code)");exit(code)
    }
}
#endif
