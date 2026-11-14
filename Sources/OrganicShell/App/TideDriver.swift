import AppKit
import QuartzCore

/// Mock-only event playback and native material comparison.
@MainActor struct TideDriver {
    let app: AppController
    let window: OrganicWindow
    let log: (String, [String: Any]) -> Void
    let sleep: (Double) async -> Void
    let hover: (CGPoint?) -> Void
    let click: (CGPoint) async -> Void
    let escape: () -> Void

    private enum ProbeMode: String {
        case light, inventory
        static let selected=ProbeMode(rawValue:ProcessInfo.processInfo.environment["M11_TIDE_PROBE"] ?? "") ?? .light
    }

    func run(_ spec: Set<String>) async {
        let lifecycleNames=["p-tide-app-switch","p-tide-mode","p-tide-close"]
        let names=["p-tide-shape","p-tide-room2","p-tide-control","p-tide-still","p-tide-still-room2","p-tide-loop","p-tide-peek"]
        guard names.contains(where:spec.contains) || lifecycleNames.contains(where:spec.contains) || TideFeatureDriver.accepts(spec) else { return }
        guard !app.o.usesLiveCore,!app.store.usesLiveCore,
              let runtime=app.runtime as? MockConversationRuntime,let replay=app.mock,
              runtime.store === app.store,runtime.replay === replay,replay.canPlay else {
            log("tide-driver-refused",["reason":"A mock-only store and runtime are required."]);return
        }
        guard window.shell.mode == .organic,!window.scene.isFocused else {
            log("tide-driver-refused",["reason":"The material fixture needs an Organic Auto window."]);return
        }
        _=replay.setPaused(true)
        hover(nil);await sleep(0.95)
        let scene=window.scene,dock=scene.dock
        defer {dock.endTideAnimationTrial();dock.clearTideMaterialProbe();_=replay.setPaused(true)}
        if TideFeatureDriver.accepts(spec) {
            let sequence=TideFeatureDriver(store:app.store,scene:scene,log:log,sleep:sleep,hover:hover,click:click,escape:escape)
            let restore=sequence.observe(actions:window.actions,replay:replay)
            defer {restore()}
            await sequence.run(spec)
            hover(nil);await sleep(0.95)
        }
        for name in names where spec.contains(name) {
            if name == "p-tide-control",!TideCompositePolicy.control {
                log("tide-driver-refused",["path":name,"reason":"Use M11_TIDE_CONTROL=1 for a matched no-Tide measurement."]);continue
            }
            if name == "p-tide-shape" || name == "p-tide-room2" || name == "p-tide-control" {
                await dynamic(name,scene:scene);continue
            }
            if name.hasPrefix("p-tide-still") {await dynamic(name,scene:scene)}
            let briefs=dock.restingTargets.filter{$0.bar && !scene.isFull($0.id)}.sorted{$0.rect.minX>$1.rect.minX}
            let orbs=dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}
            guard let c=briefs.first,let target=orbs.first,app.store.conversation(target.id)?.isLiveConversation == false,
                  name != "p-tide-still-room2" || briefs.count>=2 else {
                log("tide-driver-refused",["path":name,"reason":"The required synthetic brief/orb targets are missing."]);continue
            }
            let origin=CACurrentMediaTime(),turn="tide-material-\(UUID().uuidString)"
            let eventID=Int(origin*1_000_000),wall=Date().timeIntervalSince1970
            if name == "p-tide-loop" {
            app.store.apply(.init(id:eventID,time:wall,method:"turn/started",params:["threadId":.string(target.id),"turn":["id":.string(turn)]]))
            app.store.apply(.init(id:eventID+1,time:wall,method:"item/started",params:["threadId":.string(target.id),"turnId":.string(turn),"item":["id":.string(turn+"-command"),"type":"commandExecution","command":"printf tide-material-fixture"]]))
            }
            defer {
                dock.endTideAnimationTrial()
                if app.store.conversation(target.id)?.activeTurnID == turn {
                    app.store.apply(.init(id:eventID+2,time:Date().timeIntervalSince1970,method:"turn/completed",
                        params:["threadId":.string(target.id),"turn":["id":.string(turn),"status":"interrupted"]]))
                    log("tide-driver-fixture-retired",["target":target.id,"turnID":turn,"mock":true])
                }
            }
            log(name == "p-tide-loop" ? "tide-driver-arrival":"tide-driver-material-arrival",["path":name,"event":name == "p-tide-loop" ? "ordinary-orb-liquid":"static-material","target":target.id,"turnID":turn,
                "plannedAt":origin,"actualAt":CACurrentMediaTime(),"mock":true,"validationOnly":true,
                "manualMaterialFixture":true,"nativeFusionVerified":false])
            var poses=[TideMaterialPose(owner:c.id,body:CGRect(x:c.rect.minX,y:c.rect.midY-18,width:36,height:36))]
            if name == "p-tide-still-room2" {
                let b=briefs[1]
                poses=[.init(owner:b.id,body:CGRect(x:b.rect.minX,y:b.rect.midY-18,width:36,height:36)),
                       .init(owner:c.id,body:CGRect(x:b.rect.minX+48,y:c.rect.midY-18,width:36,height:36),lean:54)]
            }
            guard dock.stageTideMaterialProbe(poses) else {
                log("tide-driver-refused",["path":name,"reason":"The native fixture does not clear every other owner by 12 pt."]);continue
            }
            if name == "p-tide-loop" {
                guard dock.beginTideAnimationTrial(owner:target.id) else {log("tide-driver-refused",["path":name,"reason":"The loop ablation requires an ordinary synthetic orb."]);continue}
            }
            let steps:[Double]=name == "p-tide-peek" ? [0,0.06,0.30,0.60,1,1.12,1.30,1.60,2,3,4] : [0,1/60,0.06,0.13,0.30,0.60,1,2,4]
            let requestedHold=Double(ProcessInfo.processInfo.environment["TIDE_STILL_HOLD"] ?? "") ?? 4
            let hold=name.hasPrefix("p-tide-still") || name == "p-tide-loop" ? max(4,requestedHold):4
            let extra=(3...max(4,Int(hold))).map(Double.init).filter{$0<=hold}+[hold]
            for offset in Array(Set(steps+extra)).sorted() {
                let due=origin+offset
                await sleep(max(0,due-CACurrentMediaTime()))
                if name == "p-tide-peek" {
                    if offset == 1 {scene.setPeeking(target.id)}
                    if offset == 1.12,orbs.count>1 {scene.setPeeking(orbs[1].id)}
                }
                let probeBegan=CACurrentMediaTime()
                var probe=ProbeMode.selected == .light ? dock.tideMaterialLightProbe:dock.tideMaterialProbe
                probe["path"]=name;probe["plannedAt"]=due;probe["actualAt"]=CACurrentMediaTime()
                probe["arrivalAt"]=origin;probe["plannedOffset"]=offset;probe["peek"]=scene.peekState
                probe["staticFixture"]=true;probe["measurementPhase"]=name == "p-tide-loop" ? "ordinary-orb-loop-ablation":"static-material-after-terminal"
                addDiagnostics(to:&probe,scene:scene,inventory:[1.0,hold].contains(offset))
                probe["probeTotalMS"]=(CACurrentMediaTime()-probeBegan)*1000
                log("tideProbe",probe)
            }
            if name == "p-tide-peek" {scene.setPeeking(nil);await sleep(0.8)}
            // TIDE_STILL_HOLD (Claude) retains its meaning: duration of the static-material phase.
            dock.endTideAnimationTrial()
            dock.clearTideMaterialProbe()
            log("tide-driver-material-end",["path":name,"plannedAt":origin+hold+(name == "p-tide-peek" ? 0.8:0),"actualAt":CACurrentMediaTime(),"validationOnly":true])
            await sleep(0.8)
        }
        for name in lifecycleNames where spec.contains(name) {await lifecycle(name,scene:scene)}
    }
    private func lifecycle(_ path:String,scene:AutoScene) async {
        let orbs=scene.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}
        let index=path=="p-tide-close" ? max(0,orbs.count-1):path=="p-tide-app-switch" ? min(1,max(0,orbs.count-1)):0
        guard orbs.indices.contains(index),let c=app.store.conversation(orbs[index].id),!c.isLiveConversation else{return}
        hover(nil);window.window.makeFirstResponder(nil);scene.dock.retireTide();await sleep(0.95)
        let origin=CACurrentMediaTime(),turn="tide-driver-lifecycle-\(UUID().uuidString)",serial=Int(origin*1_000_000)
        app.store.apply(.init(id:serial,time:Date().timeIntervalSince1970,method:"turn/started",params:["threadId":.string(c.id),"turn":["id":.string(turn)]]))
        app.store.apply(.init(id:serial+1,time:Date().timeIntervalSince1970,method:"item/started",params:["threadId":.string(c.id),"turnId":.string(turn),"item":["id":.string(turn+"-command"),"type":"commandExecution","command":"printf lifecycle-fixture"]]))
        log("tide-driver-arrival",["path":path,"target":c.id,"turnID":turn,"plannedAt":origin,"actualAt":CACurrentMediaTime(),"mock":true])
        var enteredAt:Double?,minimumGap=Double.infinity,exitChecked=false,deadlineChecked=false,fadeDeadline:Double?
        // DECISIONS #120 (Claude, lane C, 11-08): "one display frame" is a frame of the screen this window is on
        // (1/60 s on the MBA built-in, 1/120 s on the MBP built-in); 1/120 s when AppKit gives the window no screen.
        let exitScreen=window.window.screen,frameMargin=exitScreen.map {$0.minimumRefreshInterval} ?? 1/120
        let screenDetails:[String:Any]=["screen":exitScreen?.localizedName ?? "none","maxFPS":exitScreen?.maximumFramesPerSecond ?? 0,
                                        "backingScale":Double(exitScreen?.backingScaleFactor ?? 0),"marginMS":frameMargin*1000]
        // screenState boxes "opacity" as Any: a Double while the photo is attached, an Int 0 once it is detached
        // (`attached ? opacity:0`). Read every number through NSNumber; a missing or non-numeric value fails the check.
        func exitNumber(_ value:Any?)->Double? {(value as? NSNumber)?.doubleValue}
        func exitDetails(_ enteredAt:Double,deadline:Double,surfaces:[[String:Any]])->[String:Any] {
            let now=CACurrentMediaTime()
            return screenDetails.merging(["elapsed":now-enteredAt,"deadline":deadline,"lateMS":(now-deadline)*1000,"surfaces":surfaces]) {a,_ in a}
        }
        for offset in ([0.0,0.3,0.7,0.8,0.9,0.95,1,1.008333333,1.016666667,1.05,1.07,1.1,1.12,1.2,1.22,1.23,1.3,1.368,1.463,1.5,1.8,2,2.5,3] as [Double]) {
            if path=="p-tide-mode",let enteredAt {
                // The departure fade's own deadline: its start plus its duration (enteredAt + 0.22 s if no surface says).
                if fadeDeadline==nil {
                    fadeDeadline=window.shell.modeDepartureScreenStates.compactMap {s->Double? in
                        guard let start=exitNumber(s["started"]),let duration=exitNumber(s["duration"]) else{return nil}
                        return start+duration
                    }.max()
                }
                let deadline=fadeDeadline ?? enteredAt+0.22
                // (a) At the deadline nothing of the photo may be visible: effective opacity 0, no source showing. No margin.
                if !deadlineChecked,origin+offset>deadline {
                    while CACurrentMediaTime()<deadline {await sleep(max(0.0005,deadline-CACurrentMediaTime()))}
                    deadlineChecked=true
                    let surfaces=window.shell.modeDepartureScreenStates
                    // DECISIONS #122: "transparent" means zero after 10-bit quantization (opacity * 1023 < 0.5); visibleSources stays 0.
                    let opacityLimit=0.5/1023
                    let invisible = !surfaces.isEmpty && surfaces.allSatisfy {(exitNumber($0["opacity"]).map {$0<opacityLimit} ?? false) && exitNumber($0["visibleSources"])==0}
                    log("tide-driver-check",["path":path,"passed":invisible,"label":"Mode source photo is fully transparent at its 220 ms deadline","details":exitDetails(enteredAt,deadline:deadline,surfaces:surfaces).merging(["opacityLimit":opacityLimit,"opacities":surfaces.map {exitNumber($0["opacity"]) ?? -1}]) {a,_ in a}])
                }
                // (b) One real display frame later the photo is detached as well (the original check, now with that margin).
                if !exitChecked,origin+offset>deadline+frameMargin {
                    while CACurrentMediaTime()<deadline+frameMargin {await sleep(max(0.0005,deadline+frameMargin-CACurrentMediaTime()))}
                    exitChecked=true
                    let surfaces=window.shell.modeDepartureScreenStates
                    let gone=surfaces.allSatisfy {$0["attached"] as? Bool==false && ($0["visibleSources"] as? Int ?? 0)==0}
                    log("tide-driver-check",["path":path,"passed":gone,"label":"Mode source is absent after 220 ms plus one display frame","details":exitDetails(enteredAt,deadline:deadline,surfaces:surfaces)])
                }
            }
            await sleep(max(0,origin+offset-CACurrentMediaTime()))
            if offset==1 {
                enteredAt=CACurrentMediaTime()
                switch path {
                case "p-tide-mode":window.shell.setMode(.normie)
                case "p-tide-close":window.window.performClose(nil)
                default:NSApp.deactivate()
                }
                log("tide-driver-lifecycle-entry",["path":path,"entry":path=="p-tide-mode" ? "WindowShell.setMode(.normie)":path=="p-tide-close" ? "NSWindow.performClose":"NSApplication.deactivate","actualAt":enteredAt ?? CACurrentMediaTime(),"returnedAt":CACurrentMediaTime(),"plannedAt":origin+offset])
            }
            var p=scene.dock.tideLightProbe;p["path"]=path;p["plannedAt"]=origin+offset;p["actualAt"]=CACurrentMediaTime();p["plannedOffset"]=offset;p["actualOffset"]=CACurrentMediaTime()-origin
            if p["phase"] as? String != "idle",let gap=p["minimumGap"] as? Double {minimumGap=min(minimumGap,gap)}
            p["departureSurfaces"]=window.shell.modeDepartureScreenStates
            p["inventorySampled"]=false;p["keyWindow"]=window.window.isKeyWindow;p["visible"]=window.window.isVisible;p["mode"]=window.shell.mode == .organic ? "organic":"normie";log("tideProbe",p)
            if offset==2.5 {
                let inactive=path=="p-tide-mode" ? window.shell.modeDepartureScreenStates.allSatisfy {$0["attached"] as? Bool==false && ($0["visibleSources"] as? Int ?? 0)==0} : p["phase"] as? String=="idle" && !(p["side"] as? [[String:Any]] ?? []).contains{$0["active"] as? Bool==true}
                log("tide-driver-check",["path":path,"passed":inactive,"label":"Real lifecycle entry removes the displayed Tide","details":["probe":p]])
                log("tide-driver-check",["path":path,"passed":minimumGap.isFinite && minimumGap>=12,"label":"Every sampled lifecycle contour preserves at least 12 pt","details":["minimumGap":minimumGap.isFinite ? minimumGap:0]])
            }
        }
        app.store.apply(.init(id:serial+2,time:Date().timeIntervalSince1970,method:"turn/completed",params:["threadId":.string(c.id),"turn":["id":.string(turn),"status":"interrupted"]]))
        if path=="p-tide-mode" {
            window.shell.setMode(.organic)
            let timeout=CACurrentMediaTime()+4
            repeat {await sleep(0.05)} while (window.shell.flight.running || scene.modeContentEpochFrozen) && CACurrentMediaTime()<timeout
            await sleep(0.05)
        }
        if path=="p-tide-app-switch" {NSApp.activate(ignoringOtherApps:true);window.window.makeKeyAndOrderFront(nil);await sleep(0.5)}
        // Close is intentionally last when several lifecycle specs are requested.
    }
    private func dynamic(_ path:String,scene:AutoScene) async {
        scene.dock.setTideCapacityFixture(path.contains("room2") ? 461:nil)
        defer {scene.dock.setTideCapacityFixture(nil)}
        guard let target=scene.dock.restingTargets.filter({!$0.bar}).sorted(by:{$0.rect.minX<$1.rect.minX}).first else{return}
        let start=CACurrentMediaTime(),turn="tide-driver-\(UUID().uuidString)",item=turn+"-command"
        var serial=Int(start*1_000_000)
        func emit(_ method:String,_ params:JSONValue) {
            serial+=1;app.store.apply(.init(id:serial,time:Date().timeIntervalSince1970,method:method,params:params))
            log("tide-driver-event",["path":path,"method":method,"target":target.id,"turnID":turn,"plannedAt":start+(method == "item/completed" ? 2:method == "turn/completed" ? 10.5:0),"plannedOffset":method == "item/completed" ? 2.0:method == "turn/completed" ? 10.5:0,"actualAt":CACurrentMediaTime(),"manualMaterialFixture":false,"mockCapacityDemand":path.contains("room2") ? 461:192])
        }
        emit("turn/started",["threadId":.string(target.id),"turn":["id":.string(turn)]])
        emit("item/started",["threadId":.string(target.id),"turnId":.string(turn),"item":["id":.string(item),"type":"commandExecution","command":"swift build -c release"]])
        log("tide-driver-arrival",["path":path,"event":"command","target":target.id,"turnID":turn,"plannedAt":start,"actualAt":CACurrentMediaTime(),"mock":true,"manualMaterialFixture":false,"measurementPhase":TideCompositePolicy.control ? "matched-control":"real-tide"])

        let offsets:[Double]=[0.0,1/60,0.05,0.07,0.09,0.13,0.19,0.30,0.39,0.60,1,1.5,2,2.03,2.08,2.5,3,4,4.4,5,6,7,8,8.45,8.5,8.57,8.66,8.73,8.96,9,9.3,10,10.5]
        for offset in offsets {
            await sleep(max(0,start+offset-CACurrentMediaTime()))
            if offset == 2 {emit("item/completed",["threadId":.string(target.id),"turnId":.string(turn),"item":["id":.string(item),"type":"commandExecution","command":"swift build -c release"]])}
            let probeBegan=CACurrentMediaTime()
            var probe=ProbeMode.selected == .light ? scene.dock.tideLightProbe:scene.dock.tideProbe
            probe["path"]=path;probe["plannedAt"]=start+offset;probe["actualAt"]=CACurrentMediaTime();probe["plannedOffset"]=offset
            probe["target"]=target.id;probe["turnID"]=turn;probe["manualMaterialFixture"]=false
            probe["measurementPhase"]=TideCompositePolicy.control ? "matched-control":"real-tide";probe["staticFixture"]=false
            addDiagnostics(to:&probe,scene:scene,inventory:[2.5,9.3].contains(offset))
            probe["probeTotalMS"]=(CACurrentMediaTime()-probeBegan)*1000
            log("tideProbe",probe)
        }
        emit("turn/completed",["threadId":.string(target.id),"turn":["id":.string(turn),"status":"interrupted"]])
        await sleep(0.5)
    }

    private func addDiagnostics(to probe:inout [String:Any],scene:AutoScene,inventory:Bool) {
        let began=CACurrentMediaTime()
        let inventory=inventory && ProbeMode.selected == .inventory
        probe["probeMode"]=ProbeMode.selected.rawValue
        probe["inventorySampled"]=inventory
        probe["animationPolicy"]=scene.dock.tideAnimationDiagnostics
        if inventory {
        let inventoryBegan=CACurrentMediaTime()
        let orbRoots:[(String,NSView)]=scene.dock.items.keys.sorted().flatMap{id -> [(String,NSView)] in
            guard let item=scene.dock.items[id] else{return []}
            return [("dock."+id+".glass",item.glass),("dock."+id+".back",item.decoration.backView),("dock."+id+".front",item.decoration.frontView)]
        }
        probe["animationAudit"]=DockTideAnimationAudit.snapshot(orbRoots+[("dock",scene.dock.view),("scene",scene.sceneView),("native",scene.nativePlane),("overlay",scene.overlayPlane)])
        let islands:[(String,Any)]=scene.nodes.compactMap{id,node in node.island.map{("header."+id,$0)}}
        probe["runtimeClocks"]=DockTideAnimationAudit.clocks([("app",app),("window",window),("sceneOwner",scene),("scene",scene.clock),("me",scene.meController)]+scene.dock.tideClockOwners+islands)
        probe["inventoryMS"]=(CACurrentMediaTime()-inventoryBegan)*1000
        }
        probe["mockPlaybackActive"]=app.mock?.isPlaybackActive ?? false
        probe["sceneAmbientRunning"]=scene.ambientRunning
        probe["sceneClock"]=["keepRunning":scene.clock.keepRunning,"callbacks":scene.clock.log.fields]
        probe["sceneTasks"]=["peekPending":scene.peekTimer != nil,"prewarmPending":scene.prewarmTask != nil,"idlePreparationPending":scene.idlePrewarmTask != nil]
        probe["diagnosticMS"]=(CACurrentMediaTime()-began)*1000
    }
}

/// The feature sequence is shared with the windowless harness; only posted input belongs to InputRun.
@MainActor final class TideFeatureDriver {
    static let events=["approval","approval-outside","question","question-complex","stopped","done","context-88","context-90","compacted","agent-up","agent-down","tests","retry"]
    static let interactions=["live","multi","reply","review","question-review","question-reply","question-decline","hover","reclaim","refuse","refuse-ime","esc","reduce","pin-protected","add","side","q4"]
    static let deferred:[String]=[]
    static func accepts(_ spec:Set<String>)->Bool {
        spec.contains("p-tide-features") || (events+interactions+deferred).contains{spec.contains("p-tide-"+$0)}
    }
    let store:ConversationStore,scene:AutoScene
    let log:(String,[String:Any])->Void,sleep:(Double)async->Void,hover:(CGPoint?)->Void,click:(CGPoint)async->Void,escape:()->Void
    var serial=Int(CACurrentMediaTime()*1_000_000),checks=0,findings=0
    var responses:[String]=[],submissions:[String]=[]
    private weak var replay:MockReplay?
    init(store:ConversationStore,scene:AutoScene,log:@escaping(String,[String:Any])->Void,sleep:@escaping(Double)async->Void,
         hover:@escaping(CGPoint?)->Void,click:@escaping(CGPoint)async->Void,escape:@escaping()->Void) {
        self.store=store;self.scene=scene;self.log=log;self.sleep=sleep;self.hover=hover;self.click=click;self.escape=escape
    }
    private static func object(_ value:JSONValue)->Any {
        guard let data=try? JSONEncoder().encode(value),let object=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed) else{return NSNull()}
        return object
    }
    func observe(actions:NormieActions,replay:MockReplay)->()->Void {
        self.replay=replay
        let approval=actions.approvalValue,answer=actions.answer,event=replay.onEvent
        let warning=scene.dock.questionDiagnostics.onWarning
        scene.dock.questionDiagnostics.onWarning={ [weak self] row in
            warning?(row)
            var fields:[String:Any]=row;fields["actualAt"]=CACurrentMediaTime()
            self?.log("tide-driver-question-warning",fields)
        }
        actions.approvalValue={ [weak self] c,request,value in
            if request.id.hasPrefix("tide-driver-") {
                self?.submissions.append(request.id)
                self?.log("tide-driver-submit",["target":c.id,"requestID":request.id,"response":Self.object(value),"mock":true])
            }
            approval?(c,request,value)
        }
        actions.answer={ [weak self] c,request,answers in
            if request.id.hasPrefix("tide-driver-") {
                self?.submissions.append(request.id)
                self?.log("tide-driver-submit",["target":c.id,"requestID":request.id,"answerIDs":answers.keys.sorted(),"answers":answers,"mock":true])
            }
            answer?(c,request,answers)
        }
        replay.onEvent={ [weak self] e in
            if e.method=="core/approvalResponded",let id=e.params["approvalId"]?.stringValue,id.hasPrefix("tide-driver-") {
                self?.responses.append(id);self?.log("tide-driver-response",["requestID":id,"eventID":e.id,"method":e.method,"mock":true])
            }
            event?(e)
        }
        return {actions.approvalValue=approval;actions.answer=answer;replay.onEvent=event;self.scene.dock.questionDiagnostics.onWarning=warning}
    }
    func wire(_ method:String,_ params:JSONValue,target:String,path:String,plannedAt:Double) {
        serial+=1;var p=params.objectValue ?? [:];p["threadId"] = .string(target)
        let before=CACurrentMediaTime()
        store.apply(.init(id:serial,time:Date().timeIntervalSince1970,method:method,params:.object(p)))
        log("tide-driver-event",["path":path,"target":target,"eventID":serial,"method":method,"plannedAt":plannedAt,"actualAt":before,"applyMS":(CACurrentMediaTime()-before)*1000,"params":Self.object(.object(p)),"mock":true])
    }
    private func approval(_ request:String,target:String,path:String,at:Double,outside:Bool=false) {
        var params:JSONValue=["itemId":"tide-command","command":"printf tide-fixture","availableDecisions":["accept","decline"]]
        if outside {var p=params.objectValue!;p["sandbox_permissions"]="require_escalated";params = .object(p)}
        wire("core/approvalRequested",["approvalId":.string(request),"title":"Allow synthetic fixture?","request":["method":"item/commandExecution/requestApproval","params":params]],target:target,path:path,plannedAt:at)
    }
    private func event(_ name:String,request:String,target:String,turn:String,path:String,at:Double) {
        let name=name=="q4" ? "question":name=="review" ? "stopped":name=="question-review" ? "question-complex":["question-reply","question-decline"].contains(name) ? "question":name
        switch name {
        case "approval","approval-outside","multi","reply","pin-protected":approval(request,target:target,path:path,at:at,outside:name=="approval-outside")
        case "question","question-complex":
            wire("core/approvalRequested",["approvalId":.string(request),"request":["method":"item/tool/requestUserInput","params":["questions":[["id":"tide-scope","header":"Scope","question":"Include the synthetic fixture?","isSecret":.bool(name=="question-complex"),"options":[["label":"Leave out"],["label":"Include"]]]]]]],target:target,path:path,plannedAt:at)
        case "stopped","done":wire("turn/completed",["turn":["id":.string(turn),"status":.string(name=="done" ? "completed":"failed"),"error":["message":"Synthetic work-stopping failure"]]],target:target,path:path,plannedAt:at)
        case "context-88","context-90":wire("thread/tokenUsage/updated",["tokenUsage":["last":["totalTokens":.number(name=="context-88" ? 880:900)],"modelContextWindow":1000]],target:target,path:path,plannedAt:at)
        case "compacted":wire("thread/compacted",[:],target:target,path:path,plannedAt:at)
        case "tests","live":wire("core/pulseProgress",["completed":3,"total":7],target:target,path:path,plannedAt:at)
        case "retry":wire("error",["turnId":.string(turn),"message":"Synthetic retryable error","willRetry":true],target:target,path:path,plannedAt:at)
        case "agent-up","agent-down":
            wire("item/started",["turnId":.string(turn),"item":["id":"tide-agent","type":"collabAgentToolCall","receiverThreadIds":["tide-driver-child"],"agentsStates":["tide-driver-child":["status":"running"]]]],target:target,path:path,plannedAt:at)
            if name=="agent-down" {wire("item/completed",["turnId":.string(turn),"item":["id":"tide-agent","type":"collabAgentToolCall","receiverThreadIds":["tide-driver-child"],"agentsStates":["tide-driver-child":["status":"completed"]]]],target:target,path:path,plannedAt:at)}
        default:wire("item/started",["turnId":.string(turn),"item":["id":"tide-command","type":"commandExecution","command":"swift build -c release"]],target:target,path:path,plannedAt:at)
        }
    }
    private func check(_ value:Bool,_ label:String,path:String,details:[String:Any]=[:]) {
        checks+=1;if !value {findings+=1}
        log("tide-driver-check",["path":path,"label":label,"passed":value,"details":details])
    }
    /// Debt #57 (Claude, 11-09): a real click on B's Run button while a warm capture holds the mode-content epoch must
    /// reach the button. Real window only (`--d57-warm-click` with p-tide-side): offscreen hosts may never start the
    /// display-driven warm capture. Waits for a natural freeze (AutoScene.modeContentEpochFrozen mirrors
    /// WindowShell.contentEpochHeld), then sends mouse down/up through NSWindow.sendEvent, the same path a user's click
    /// takes. A witness counts the dispatched action and forwards it. When the frozen click is swallowed, a control click
    /// after the release must reach the button, so a failure points at the freeze and not at the harness.
    /// One real click on a native button: mouse down/up through NSWindow.sendEvent, the path a user's click takes. The
    /// caller installs the witness; the row records the freeze state before and after, the hit-test class and how many
    /// times the button's action arrived (Claude, 11-09: shared by the D57 check and the Split opening check, #139).
    private func realButtonClick(_ button:NSButton,column:ColumnNode,window:NSWindow,witness:D57ActionWitness,phase:String,path:String,event:String)->[String:Any] {
        let held=scene.modeContentEpochFrozen,blocked=column.native.modeContentInputBlocked,before=witness.count
        let point=button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:nil),now=CACurrentMediaTime()
        let hit=window.contentView?.hitTest(window.contentView?.superview?.convert(point,from:nil) ?? point)
        guard let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:now,windowNumber:window.windowNumber,context:nil,eventNumber:5701,clickCount:1,pressure:1),
              let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:now+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:5702,clickCount:1,pressure:0) else {
            return ["phase":phase,"eventCreated":false]
        }
        window.postEvent(up,atStart:false);window.sendEvent(down)
        if let pending=NSApp.nextEvent(matching:.leftMouseUp,until:.distantPast,inMode:.default,dequeue:true) {window.sendEvent(pending)}
        let row:[String:Any]=["phase":phase,"at":now,"contentEpochHeld":held,"modeContentInputBlocked":blocked,
                              "heldAfter":scene.modeContentEpochFrozen,"hitClass":hit.map{String(describing:type(of:$0))} ?? "nil",
                              "dispatched":witness.count-before,"forwarded":witness.forwards,"keyWindow":window.isKeyWindow,"windowPoint":[point.x,point.y]]
        var logged=row;logged["path"]=path;log(event,logged)
        return row
    }
    /// Waits up to 10 s for a warm-capture freeze. When the warm picture is already current nothing freezes on its own
    /// (11-09 r2: the capture before Split finished because hover no longer cancels it). After 1.5 s the fixture nudges the
    /// store once with a finished turn on an off-screen history conversation, so the existing invalidation and 0.6 s
    /// schedule start a fresh warm capture. Returns what it waited and whether and where it nudged (logged as `step`).
    private func awaitWarmFreeze(path:String,step:String) async -> [String:Any] {
        let waitStart=CACurrentMediaTime()
        var nudge:[String:Any]=["nudged":false]
        while !scene.modeContentEpochFrozen && CACurrentMediaTime()-waitStart<10 {
            if nudge["nudged"] as? Bool != true,CACurrentMediaTime()-waitStart>1.5,
               let quiet=store.conversations.first(where:{$0.id.hasPrefix("H")})?.id ?? store.conversations.first(where:{$0.id != "B"})?.id {
                let turn="d57-nudge-\(UUID().uuidString)"
                nudge=["nudged":true,"target":quiet,"at":CACurrentMediaTime()-waitStart]
                wire("turn/started",["turn":["id":.string(turn)]],target:quiet,path:path,plannedAt:CACurrentMediaTime())
                await sleep(0.05)
                wire("turn/completed",["turn":["id":.string(turn),"status":"completed"]],target:quiet,path:path,plannedAt:CACurrentMediaTime())
            }
            await sleep(0.002)
        }
        let row:[String:Any]=["waited":CACurrentMediaTime()-waitStart,"nudge":nudge,"frozen":scene.modeContentEpochFrozen]
        var logged=row;logged["path"]=path;log(step,logged)
        return row
    }
    private func d57WarmFreezeClick(path:String) async {
        guard let column=scene.columns.first(where:{$0.conversation.id=="B"}),
              let button=TideRunVisibility.buttons(in:column.native).first,let window=button.window else {
            check(false,"D57 fixture has B's real Run button in a window",path:path);return
        }
        let witness=D57ActionWitness(button)
        button.target=witness;button.action=#selector(D57ActionWitness.pressed(_:))
        defer {button.target=witness.originalTarget;button.action=witness.originalAction}
        func click(_ phase:String)->[String:Any] {
            realButtonClick(button,column:column,window:window,witness:witness,phase:phase,path:path,event:"d57-warm-click")
        }
        let wait=await awaitWarmFreeze(path:path,step:"d57-freeze-wait")
        guard scene.modeContentEpochFrozen else {
            check(false,"D57 a warm capture froze the mode content within 10 s",path:path,details:wait);return
        }
        let frozen=click("frozen")
        let held=frozen["contentEpochHeld"] as? Bool == true
        check(held,"D57 the click was sent while the mode content was frozen",path:path,details:frozen)
        check(held && frozen["dispatched"] as? Int == 1,"D57 a click on B's Run during a warm-capture freeze reaches the button",path:path,details:frozen)
        if frozen["dispatched"] as? Int != 1 {
            let releaseStart=CACurrentMediaTime()
            while scene.modeContentEpochFrozen && CACurrentMediaTime()-releaseStart<10 {await sleep(0.002)}
            await sleep(0.05)
            let control=click("released")
            check(control["contentEpochHeld"] as? Bool == false && control["dispatched"] as? Int == 1,"D57 control: the same click after the release reaches the button",path:path,details:control)
        }
        await sleep(0.2)
    }
    private func press(_ label:String,path:String) async {
        let p=scene.dock.tideLightProbe["presentation"] as? [String:Any] ?? [:]
        let row=(p["buttons"] as? [[String:Any]] ?? []).first{$0["title"] as? String==label}
        guard let rect=row?["rect"] as? [CGFloat],rect.count==4,row?["enabled"] as? Bool==true else {
            check(false,"Offered native button exists: "+label,path:path,details:["probe":p]);return
        }
        let point=CGPoint(x:rect[0]+rect[2]/2,y:rect[1]+rect[3]/2)
        log("tide-driver-click",["path":path,"title":label,"requestID":p["requestID"] as? String ?? "","point":[point.x,point.y],"actualAt":CACurrentMediaTime()])
        await click(point);hover(nil)
    }
    func run(_ spec:Set<String>) async {
        let all=spec.contains("p-tide-features")
        for name in Self.deferred where spec.contains("p-tide-"+name) || all {
            log("tide-driver-unavailable",["path":"p-tide-"+name,"reason":"Deferred to the next implementation round; this path is not a passing check."])
        }
        for name in Self.events+Self.interactions where all || spec.contains("p-tide-"+name) {
            if name=="add" {await runAdd()}else if name=="side" {await runSide()}else{await runPath(name)}
        }
        log("tide-driver-feature-summary",["checks":checks,"findings":findings,"mock":true])
    }
    private func runSide() async {
        let path="p-tide-side",savedMembers=scene.members,savedCurrent=scene.current,savedScheme=scene.scheme
        let members=savedMembers
        hover(nil);scene.sceneView.window?.makeFirstResponder(nil);scene.dock.retireTide()
        scene.transition(to:members,current:savedCurrent,scheme:savedScheme,spring:Tuning.shared.autoSpring,reason:"tide-side-capacity-fixture")
        await sleep(1.6)
        for mode in ["focused","split","parked"] {
            if scene.isFocused {scene.leaveFocused(reason:"tide-side-driver-return");await sleep(1.4)}
            if mode=="parked" {
                var next=AutoScene.Scheme();next.parked=Array(savedMembers.filter{$0.id != savedCurrent}.prefix(2).map(\.id))
                scene.transition(to:savedMembers,current:savedCurrent,scheme:next,spring:Tuning.shared.autoSpring,reason:"tide-side-parked-capacity-fixture")
            } else {
                scene.enterFocused(savedCurrent,reason:"tide-side-driver")
                if mode=="split" {await sleep(1.4);scene.graft("B",at:1,reason:"tide-side-run-fixture")}
            }
            await sleep(1.7)
            if mode=="split" {
                if let b=store.conversation("B"),!b.approvals.contains(where:{$0.id=="B-ap1"}) {
                    wire("core/approvalRequested",["approvalId":"B-ap1","title":"Run this command?","request":["method":"item/commandExecution/requestApproval","params":["itemId":"B-2","command":"Scripts/lint-copy.sh native/Approval*.strings","availableDecisions":["decline","accept"]]]],target:"B",path:path,plannedAt:CACurrentMediaTime())
                    await sleep(0.15)
                }
                // Present the retained native transcript, rather than its quiet-run snapshot.
                scene.showCaptures(false)
                scene.columns.first(where:{$0.conversation.id=="B"})?.native.layoutSubtreeIfNeeded()
            }
            scene.dock.prepareTideMaterialNow();await sleep(0.05)
            let full=scene.layout.bars.reduce(scene.layout.bars.first ?? .zero){$0.union($1)}
            let targets=scene.dock.restingTargets.filter{target in !target.bar && scene.members.contains{$0.id==target.id} && (mode != "parked" || scene.scheme.parked.contains(target.id))}
            let side=targets.filter{$0.rect.midX>full.midX}.sorted{$0.rect.minX<$1.rect.minX}
            let selected=side.count>=2 ? [side[0],side[side.count-1]]:Array(targets.prefix(2))
            guard let first=selected.first,let c=store.conversation(first.id),!c.isLiveConversation else{check(false,"Side fixture has a synthetic orb",path:path);continue}
            func nativeRunEvidence()->[[String:Any]] {
                guard mode=="split",let column=scene.columns.first(where:{$0.conversation.id=="B"}) else{return []}
                return TideRunVisibility.buttons(in:column.native).map {button in
                    var row=TideRunVisibility.inspect(button,window:scene.dock.view.window,relativeTo:scene.dock.view)
                    row["target"]="B";row["requestID"]="B-ap1";row["columnFull"]=column.isFull
                    row["ownsNative"]=column.ownsNative;row["restOnSnapshot"]=column.restOnSnapshot
                    row["nativeActive"]=column.native.presentationActive;row["modelRevision"]=column.conversation.revision
                    row["renderedRevision"]=column.native.renderedRevision
                    row["passed"]=(row["passed"] as? Bool == true) && column.isFull && column.ownsNative && !column.restOnSnapshot
                    return row
                }
            }
            // DECISIONS #123 (Claude): the mode-content freeze state read in the same main-actor turn as the hit test.
            // AutoScene.modeContentEpochFrozen mirrors WindowShell.contentEpochHeld (set in holdContentEpoch, cleared in
            // releaseContentEpoch); modeContentInputBlocked is B's transcript surface flag that rejects the hit while frozen.
            func modeFreezeEvidence(_ buttons:[[String:Any]])->[String:Any] {
                var details:[String:Any]=["buttons":buttons,"contentEpochHeld":scene.modeContentEpochFrozen,"freezeSampledAt":CACurrentMediaTime()]
                if let column=scene.columns.first(where:{$0.conversation.id=="B"}) {details["modeContentInputBlocked"]=column.native.modeContentInputBlocked}
                else {details["modeContentInputBlocked"]=NSNull()}
                return details
            }
            if mode=="split",CommandLine.arguments.contains("--d57-warm-click") {
                await d57WarmFreezeClick(path:path)
                return
            }
            if mode=="split" {
                // Check verification only (Claude, 11-09): TIDE_SPLIT_OPENING_FREEZE=1 holds the opening moment until a warm
                // capture freezes, so the real-click branch below is exercised on purpose (positive and pre-#57 negative).
                var openingWait:[String:Any]?
                if ProcessInfo.processInfo.environment["TIDE_SPLIT_OPENING_FREEZE"] == "1" {
                    openingWait=await awaitWarmFreeze(path:path,step:"tide-split-opening-freeze-wait")
                }
                let buttons=nativeRunEvidence()
                var details=modeFreezeEvidence(buttons)
                if let openingWait {details["openingFreezeWait"]=openingWait}
                log("tide-driver-native-run",["path":path,"section":mode,"buttons":buttons,"actualAt":CACurrentMediaTime(),"contentEpochHeld":details["contentEpochHeld"] ?? NSNull(),"modeContentInputBlocked":details["modeContentInputBlocked"] ?? NSNull()])
                var passed=TideRunVisibility.passed(buttons)
                // DECISIONS #139 (Claude, 11-09): since debt #57 (4d46205) a warm-capture freeze still shields hit testing by
                // design; real input releases it before dispatch. So when the probe misses during a freeze, the opening
                // moment is judged by one real click through NSWindow.sendEvent. The witness only counts the arrival and does
                // not forward it, so B's request stays unanswered for the rest of the path. Not frozen and missed still fails.
                if !passed,details["contentEpochHeld"] as? Bool == true,
                   let column=scene.columns.first(where:{$0.conversation.id=="B"}),
                   let button=TideRunVisibility.buttons(in:column.native).first,let window=button.window {
                    let witness=D57ActionWitness(button);witness.forwards=false
                    button.target=witness;button.action=#selector(D57ActionWitness.pressed(_:))
                    let row=realButtonClick(button,column:column,window:window,witness:witness,phase:"split-opening",path:path,event:"tide-driver-opening-click")
                    button.target=witness.originalTarget;button.action=witness.originalAction
                    details["probeMissedDuringFreeze"]=true;details["realClick"]=row
                    passed=row["dispatched"] as? Int == 1
                }
                check(passed,"Split presents B's real enabled Run button",path:path,details:details)
            }
            let start=CACurrentMediaTime(),turn="tide-driver-side-turn-\(UUID().uuidString)",request="tide-driver-side-request-\(UUID().uuidString)"
            wire("turn/started",["turn":["id":.string(turn)]],target:c.id,path:path,plannedAt:start)
            event("command",request:request,target:c.id,turn:turn,path:path,at:start)
            log("tide-driver-arrival",["path":path,"section":mode,"target":c.id,"turnID":turn,"plannedAt":start,"actualAt":CACurrentMediaTime(),"mock":true,"capacityFixture":true])
            for offset in ([0.0,1/60,0.04,0.07,0.10,0.20,0.30,0.6,0.8,1,1.1,1.5,2,2.1,2.5,3,3.3,4,5,6,6.1,6.3,7.5] as [Double]) {
                await sleep(max(0,start+offset-CACurrentMediaTime()))
                if offset==0.6,let p=scene.dock.tideSideProbe.first(where:{$0["owner"] as? String==c.id}),let r=p["orb"] as? [CGFloat],r.count==4 {hover(CGPoint(x:r[0]+r[2]/2,y:r[1]+r[3]/2))}
                if offset==0.8 {hover(nil)}
                if offset==1 {approval(request,target:c.id,path:path,at:start+offset,outside:false)}
                if offset==2,selected.count>1 {
                    wire("turn/started",["turn":["id":.string(turn+"-second")]],target:selected[1].id,path:path,plannedAt:start+offset)
                    event("command",request:"",target:selected[1].id,turn:turn+"-second",path:path,at:start+offset)
                }
                if offset==3,selected.count>1 {approval(request+"-second",target:selected[1].id,path:path,at:start+offset,outside:true)}
                if offset==6 {escape();hover(nil)}
                let p=scene.dock.tideSideProbe
                log("tideProbe",["path":path,"section":mode,"target":c.id,"side":p,"plannedAt":start+offset,"actualAt":CACurrentMediaTime(),"plannedOffset":offset,"actualOffset":CACurrentMediaTime()-start,"inventorySampled":false])
                if offset==0.8 {check(p.contains{$0["owner"] as? String==c.id && $0["visible"] as? Bool==true},"Real mode routes its notice to TideSide B: \(mode)",path:path)}
                if offset==5 {
                    let live=p.filter{$0["visible"] as? Bool==true && (($0["card"] as? [CGFloat])?[2] ?? 0)>=149}
                    check(live.count>=2,"Same side shows two complete native cards: \(mode)",path:path,details:["side":live])
                    check(live.filter{($0["card"] as? [CGFloat])?[3]==88}.count==2,"Both narrow side actions reach 88 pt: \(mode)",path:path)
                    check(live.allSatisfy{($0["formAlpha"] as? Double ?? 0)>0.999},"Both side action contents finish entering: \(mode)",path:path)
                }
                if mode=="split",[2.5,3,4,5].contains(offset) {
                    let evidence=nativeRunEvidence(),hit=evidence.map {$0["nativeHit"] as? Bool == true},details=modeFreezeEvidence(evidence)
                    log("tide-driver-native-run",["path":path,"section":mode,"plannedAt":start+offset,"actualAt":CACurrentMediaTime(),"plannedOffset":offset,"hitTested":true,"hitResults":hit,"buttons":evidence])
                    check(TideRunVisibility.passed(evidence),offset==5 ? "B's real Run button stays hit-testable beside both Side cards":"B's real Run card remains visible at +\(offset) s",path:path,details:details)
                }
            }
            let retreatAt=CACurrentMediaTime()
            _=scene.dock.dismissTide()
            for tick in 1...50 {
                if !scene.dock.tideSideProbe.contains(where:{$0["active"] as? Bool==true}) {break}
                await sleep(max(0,retreatAt+Double(tick)*0.05-CACurrentMediaTime()))
            }
            check(!scene.dock.tideSideProbe.contains(where:{$0["active"] as? Bool==true}),"Side cleanup finishes its finite retreat before fixture teardown: \(mode)",path:path)
            for target in selected {
                for pending in store.conversation(target.id)?.notices.snapshot(in:store.conversation(target.id)!).pending ?? [] where pending.requestID?.hasPrefix("tide-driver-")==true {
                    wire("core/approvalExpired",["approvalId":.string(pending.requestID!)],target:target.id,path:path,plannedAt:CACurrentMediaTime())
                }
                wire("turn/completed",["turn":["id":.string(target.id==c.id ? turn:turn+"-second"),"status":"interrupted"]],target:target.id,path:path,plannedAt:CACurrentMediaTime())
            }
            scene.dock.retireTide()
        }
        if scene.isFocused {scene.leaveFocused(reason:"tide-side-driver-return");await sleep(1.3)}
        scene.transition(to:savedMembers,current:savedCurrent,scheme:savedScheme,spring:Tuning.shared.autoSpring,reason:"tide-side-driver-restore")
        await sleep(1.5)
    }
    private func runAdd() async {
        let path="p-tide-add",dock=scene.dock,savedMembers=scene.members,savedCurrent=scene.current,savedScheme=scene.scheme
        guard let target=dock.restingTargets.first(where:{!$0.bar}),let c=store.conversation(target.id),!c.isLiveConversation else{return}
        hover(nil);scene.sceneView.window?.makeFirstResponder(nil);dock.retireTide();await sleep(0.95)
        let start=CACurrentMediaTime(),turn="tide-driver-turn-\(UUID().uuidString)"
        wire("turn/started",["turn":["id":.string(turn)]],target:c.id,path:path,plannedAt:start)
        event("command",request:"",target:c.id,turn:turn,path:path,at:start)
        var additions:[Conversation]=[],displaced:[String]=[]
        for index in 0..<12 {
            let added=Conversation(id:"tide-driver-add-\(UUID().uuidString)",title:"Add fixture \(index+1)")
            additions.append(added)
            let (layout,order)=scene.arrange(savedMembers+additions,current:savedCurrent)
            displaced=Array(scene.order.prefix(scene.layout.bars.count)).filter{!scene.isFull($0) && !order.prefix(layout.bars.count).contains($0)}
            if !displaced.isEmpty {break}
        }
        // Register synthetic capacity candidates without the host's unrelated background-arrival admission.
        // The single capacity caller below must own membership and the Add reservation atomically.
        let arrival=store.onAdd;store.onAdd=nil
        for added in additions {store.add(added)}
        store.onAdd=arrival
        log("tide-driver-arrival",["path":path,"target":c.id,"turnID":turn,"plannedAt":start,"actualAt":CACurrentMediaTime(),"mock":true,"capacityFixture":true,"added":additions.map(\.id),"displaced":displaced])
        for offset in ([0.0,0.3,0.6,0.8,1,1.016666667,1.05,1.07,1.13,1.3,1.6,2,2.5,3,3.5,4,5] as [Double]) {
            await sleep(max(0,start+offset-CACurrentMediaTime()))
            if offset==1 {check(scene.admitWithTideSlots(additions,owner:"tide-driver-add",capacityAllows:true),"Approved Add reserves and commits the canonical capacity layout",path:path)}
            if offset==2,let id=displaced.first,let r=dock.frame(of:id) {hover(CGPoint(x:r.midX,y:r.midY))}
            if offset==2.5 {hover(nil)}
            if offset==3.5,let id=displaced.first,let r=dock.frame(of:id) {
                log("tide-driver-click",["path":path,"target":id,"point":[r.midX,r.midY],"actualAt":CACurrentMediaTime()]);await click(CGPoint(x:r.midX,y:r.midY));hover(nil)
            }
            var p=dock.tideLightProbe;p["add"]=dock.tideAddProbe;p["physicalAdd"]=dock.tideAddPhysicalProbe;p["inventorySampled"]=false;p["path"]=path;p["plannedAt"]=start+offset;p["actualAt"]=CACurrentMediaTime();p["plannedOffset"]=offset;p["actualOffset"]=CACurrentMediaTime()-start
            p["current"]=scene.current;p["order"]=scene.order;p["columns"]=scene.layout.columns.count;p["peek"]=scene.peekState;p["displacedBodies"]=displaced.compactMap{ id in dock.items[id].map{["id":id,"rect":DockTideShape.rect($0.glass.frame)]}}
            p["orbs"]=dock.restingTargets.filter{!$0.bar}.map{["id":$0.id,"rect":DockTideShape.rect($0.rect)]};log("tideProbe",p)
            if offset==0.6 || offset==0.8 {
                let rect=p["rect"] as? [CGFloat] ?? []
                check(p["phase"] as? String != "idle" && rect.count==4 && rect[0]>=0 && rect[0]+rect[2]<=dock.view.bounds.width+0.01,"Add's initial notice remains inside the live Dock viewport until preallocation",path:path,details:["probe":p])
            }
            if offset==2 {check(dock.tideAddProbe["committed"] as? Bool==true,"Tide retirement preserves the committed Add lease",path:path)}
            if offset==4,let id=displaced.first {check(scene.order.prefix(scene.layout.columns.count).contains(id),"Add's former brief lands through the ordinary orb click",path:path)}
        }
        hover(nil);dock.retireTide()
        wire("turn/completed",["turn":["id":.string(turn),"status":"interrupted"]],target:c.id,path:path,plannedAt:CACurrentMediaTime())
        scene.transition(to:savedMembers,current:savedCurrent,scheme:savedScheme,spring:Tuning.shared.autoSpring,reason:"tide-driver-add-restore")
        await sleep(1.4)
    }
    private func runPath(_ name:String) async {
        let path="p-tide-"+name,dock=scene.dock,previousCurrent=scene.current
        guard let target=dock.restingTargets.filter({!$0.bar && !scene.scheme.parked.contains($0.id)}).sorted(by:{$0.rect.minX<$1.rect.minX}).first,
              let c=store.conversation(target.id),!c.isLiveConversation else {
            log("tide-driver-refused",["path":path,"reason":"A synthetic Auto Dock orb is required."]);return
        }
        hover(nil);scene.sceneView.window?.makeFirstResponder(nil);dock.retireTide()
        for pending in c.notices.snapshot(in:c).pending {
            if let id=pending.requestID,id.hasPrefix("tide-driver-") {wire("core/approvalExpired",["approvalId":.string(id)],target:c.id,path:path,plannedAt:CACurrentMediaTime())}
        }
        // Resetting fixtures still goes through Core; no board percentage is shown as live data.
        wire("thread/tokenUsage/updated",["tokenUsage":["last":["totalTokens":100],"modelContextWindow":1000]],target:c.id,path:path,plannedAt:CACurrentMediaTime())
        let borrowed=dock.restingTargets.filter{$0.bar && !scene.isFull($0.id)}.sorted{$0.rect.minX>$1.rect.minX}.first
        let brief=borrowed.flatMap{store.conversation($0.id)},draft=brief?.draft
        let oldEditor=borrowed.flatMap{dock.items[$0.id]?.composer}
        var markedEditor:NativeComposer?
        let previousReduce=UserDefaults.standard.object(forKey:"toggle.simulateReduceMotion")
        if name=="reduce" {UserDefaults.standard.set(true,forKey:"toggle.simulateReduceMotion");scene.reduceMotionChanged()}
        if name.hasPrefix("refuse") || name=="pin-protected" {
            brief?.draft="   "
            if let brief {store.changed(brief)}
            if name=="refuse-ime",let borrowed {
                let editor=NativeComposer();markedEditor=editor;dock.items[borrowed.id]?.composer=editor
                editor.textView.setMarkedText("候",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            }
        }
        await sleep(0.95)
        let start=CACurrentMediaTime(),turn="tide-driver-turn-\(UUID().uuidString)",request="tide-driver-request-\(UUID().uuidString)"
        defer {
            hover(nil);dock.retireTide()
            if let brief,let draft {brief.draft=draft;store.changed(brief)}
            if let borrowed,markedEditor != nil {markedEditor?.textView.unmarkText();dock.items[borrowed.id]?.composer=oldEditor}
            if name=="reduce" {
                if let previousReduce {UserDefaults.standard.set(previousReduce,forKey:"toggle.simulateReduceMotion")}else{UserDefaults.standard.removeObject(forKey:"toggle.simulateReduceMotion")}
                scene.reduceMotionChanged()
            }
            for pending in c.notices.snapshot(in:c).pending where pending.requestID?.hasPrefix("tide-driver-")==true {
                wire("core/approvalExpired",["approvalId":.string(pending.requestID!)],target:c.id,path:path,plannedAt:CACurrentMediaTime())
            }
            if c.activeTurnID==turn {wire("turn/completed",["turn":["id":.string(turn),"status":"interrupted"]],target:c.id,path:path,plannedAt:CACurrentMediaTime())}
            else if c.running {replay?.stop(c)}
            dock.retireTide()
            if scene.current != previousCurrent {scene.show(previousCurrent)}
            // A quiet fixture restore has no flight endpoint to publish the new command target.
            scene.tellTarget()
        }
        wire("turn/started",["turn":["id":.string(turn)]],target:c.id,path:path,plannedAt:start)
        event(name,request:request,target:c.id,turn:turn,path:path,at:start)
        log("tide-driver-arrival",["path":path,"event":name,"target":c.id,"turnID":turn,"requestID":request,"plannedAt":start,"actualAt":CACurrentMediaTime(),"mock":true,"manualMaterialFixture":false])
        let action=["approval","approval-outside","question","question-complex","stopped"].contains(name)
        let duration=action ? 13.1:["live","pin-protected","add","side"].contains(name) ? 10:Self.events.contains(name) ? 9.6:8.0
        let offsets=Array(Set([0.0,1/60,0.05,0.07,0.13,0.19,0.30,0.6,0.8,1,1.03,1.10,1.28,1.5,1.8,2,2.03,2.14,2.5,3,3.05,3.10,3.3,3.44,3.8,3.95,4,4.5,5,6,6.95,7,7.02,7.08,7.14,7.5,8,8.5,9.3,9.6,10,11.85,11.9,11.97,12.06,12.4,13.1].filter{$0<=duration})).sorted()
        for offset in offsets {
            await sleep(max(0,start+offset-CACurrentMediaTime()))
            if name=="live",[2.0,5.0].contains(offset) {
                wire("core/pulseProgress",["completed":.number(offset==2 ? 5:7),"total":7],target:c.id,path:path,plannedAt:start+offset)
            }
            if name=="multi" {
                if offset==0.6 {approval(request+"-new",target:c.id,path:path,at:start+offset,outside:true)}
                if offset==0.8 {event("command",request:request,target:c.id,turn:turn,path:path,at:start+offset)}
                if offset==2 {await press("Allow",path:path)}
                if offset==4.5 {await press("Deny",path:path)}
            }
            if name=="q4",offset==0.6 {event("question",request:request+"-second",target:c.id,turn:turn,path:path,at:start+offset)}
            if name=="reply",offset==2 {await press("Allow",path:path)}
            if name=="review",offset==2 {await press("Review error",path:path)}
            if name=="question-review",offset==2 {await press("Answer question",path:path)}
            if name=="question-reply",offset==2 {await press("Include",path:path)}
            if name=="question-decline",offset==2 {await press("Leave out",path:path)}
            if name=="reclaim",offset==1,let id=borrowed?.id,let r=dock.frame(of:id) {hover(CGPoint(x:r.midX,y:r.midY))}
            if name=="reclaim",offset==1.10,let id=borrowed?.id,let r=dock.frame(of:id) {await click(CGPoint(x:r.midX,y:r.midY))}
            if name=="reclaim",offset==3 {hover(nil)}
            if name=="hover" {
                if [1.0,3.10].contains(offset),let r=dock.frame(of:c.id) {hover(CGPoint(x:r.midX,y:r.midY))}
                if [3.0,3.3].contains(offset) {hover(nil)}
            }
            if name.hasPrefix("refuse"),offset==3 {brief?.draft="";markedEditor?.textView.unmarkText();_=markedEditor?.setText("");if let brief {store.changed(brief)}}
            if name=="pin-protected" {
                if [0.8,4.0].contains(offset),let r=dock.frame(of:c.id) {await click(CGPoint(x:r.midX,y:r.midY))}
                if offset==6 {escape();hover(nil)}
            }
            if name=="esc" {
                if offset==1,let r=dock.frame(of:c.id) {await click(CGPoint(x:r.midX,y:r.midY))}
                if offset==2 {escape();hover(nil)}
                if offset==4 {event("command",request:request,target:c.id,turn:turn,path:path,at:start+offset)}
                if offset==5 {await click(CGPoint(x:30,y:200));hover(nil)}
            }
            let began=CACurrentMediaTime()
            var probe=dock.tideLightProbe
            probe["path"]=path;probe["target"]=c.id;probe["turnID"]=turn;probe["activeTurnID"]=c.activeTurnID ?? "";probe["plannedAt"]=start+offset;probe["actualAt"]=CACurrentMediaTime();probe["plannedOffset"]=offset;probe["actualOffset"]=CACurrentMediaTime()-start
            probe["samplingDriftMS"]=(CACurrentMediaTime()-start-offset)*1000
            probe["measurementPhase"]="real-tide-feature";probe["probeMode"]="light";probe["inventorySampled"]=false;probe["reduceMotion"]=Motion.reduce
            probe["probeTotalMS"]=(CACurrentMediaTime()-began)*1000
            log("tideProbe",probe)
            if offset==0.8 {
                check(probe["owner"] as? String==c.id,"Core event has the target UI ID",path:path,details:["probe":probe])
                if action {let p=probe["presentation"] as? [String:Any] ?? [:];check(!(p["buttons"] as? [[String:Any]] ?? []).isEmpty,"Action offers native buttons",path:path)}
            }
            if offset==1.5,name=="q4" {
                let warnings=dock.questionDiagnostics.warnings.filter{$0["previousRequestID"]==request && $0["incomingRequestID"]==request+"-second"}
                check(warnings.count==1,"Second question logs both request IDs once",path:path,details:["warnings":warnings])
            }
            if offset==1.5,name=="hover" {check((probe["presentation"] as? [String:Any])?["detailAlpha"] as? Double==1,"Hover shows the title and status after dwell",path:path,details:["probe":probe])}
            if offset==1.5,name=="reclaim" {check(probe["level"] as? Int==0 || scene.current==borrowed?.id,"Hover/click returns the borrowed editor",path:path,details:["probe":probe])}
            if offset==3.8,name.hasPrefix("refuse") {check(probe["level"] as? Int==0,"Protection grace prevents immediate reborrow",path:path)}
            if offset==3.95,name.hasPrefix("refuse") {check(probe["level"] as? Int==1,"Brief becomes borrowable after .9 s grace",path:path,details:["probe":probe])}
            if offset==7.5,["esc","pin-protected","add","side"].contains(name) {check(probe["phase"] as? String=="idle","Esc and outside click both retire the notice",path:path,details:["probe":probe])}
            if offset==0.8,name=="reduce" {check(probe["motionBusy"] as? Bool==false,"Real Reduce Motion input reaches rest",path:path)}
            if offset==3.95,name=="multi" {check((probe["presentation"] as? [String:Any])?["requestID"] as? String==request,"Oldest unanswered resumes after reply hold",path:path,details:["probe":probe])}
        }
        if name=="review" || name=="question-review" {check(scene.current==c.id,"Review opens the full existing conversation interface",path:path)}
        if ["question-reply","question-decline"].contains(name) {check(responses.filter{$0==request}.count==1,"Original question ID receives exactly one mock response",path:path)}
        if name=="reply" {check(responses.filter{$0==request}.count==1,"Original approval ID receives exactly one mock response",path:path)}
        if name=="multi" {check(responses.filter{$0==request || $0==request+"-new"}.count==2,"Both pending IDs are answered independently",path:path)}
        if action {
            check(dock.tideLightProbe["phase"] as? String=="idle","Action returns after its actual occupancy deadline",path:path,details:["actualOffset":CACurrentMediaTime()-start,"probe":dock.tideLightProbe])
        }
        // Cleanup is a separately logged finite notification retreat, never a hidden fixture reset.
        log("tide-driver-cleanup-begin",["path":path,"plannedAt":start+duration,"actualAt":CACurrentMediaTime(),"probe":dock.tideLightProbe])
        if c.activeTurnID==turn {wire("turn/completed",["turn":["id":.string(turn),"status":"interrupted"]],target:c.id,path:path,plannedAt:CACurrentMediaTime())}
        for pending in c.notices.snapshot(in:c).pending where pending.requestID?.hasPrefix("tide-driver-")==true {
            wire("core/approvalExpired",["approvalId":.string(pending.requestID!)],target:c.id,path:path,plannedAt:CACurrentMediaTime())
        }
        hover(nil);_=dock.dismissTide();await sleep(1.1)
        log("tide-driver-cleanup-end",["path":path,"actualAt":CACurrentMediaTime(),"probe":dock.tideLightProbe])
    }
}

/// Debt #57 check (Claude, 11-09): counts the Run button's action and forwards it to the original target.
@MainActor final class D57ActionWitness:NSObject {
    let originalTarget:AnyObject?
    let originalAction:Selector?
    var count=0
    /// false: only count the arrival, so a probe click leaves the scenario state unchanged (DECISIONS #139).
    var forwards=true
    init(_ button:NSButton) {originalTarget=button.target;originalAction=button.action;super.init()}
    @objc func pressed(_ sender:Any?) {count+=1;if forwards,let originalAction {_=NSApp.sendAction(originalAction,to:originalTarget,from:sender)}}
}
