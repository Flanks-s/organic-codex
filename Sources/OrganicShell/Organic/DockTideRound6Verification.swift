#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Store, native actions and real scene lifecycle entries; no duplicate notification model in the test.
@MainActor enum DockTideRound6Verification {
    @MainActor final class Fixture {
        let store:ConversationStore,replay:MockReplay,scene:AutoScene
        let runtime:MockConversationRuntime,actions=NormieActions()
        var now=VerificationClock.modelOrigin,serial=10,callbacks=0,pendingFrame=false
        var submitted:[String]=[],responses:[String]=[]
        var submittedAnswers:[String:[String]] = [:]
        let turn="tide-r6"
        var target="D"
        var dock:DockNode {scene.dock}
        init(scale:CGFloat=2) {
            store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
            replay=MockReplay(store:store);runtime=MockConversationRuntime(store:store,replay:replay,animatePlayback:false)
            replay.start(live:true);_=replay.setPaused(true)
            for c in store.conversations where c.running {replay.stop(c)}
            scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:scale)
            scene.restOnSnapshot=true;scene.ambient=true;scene.manualSettle=true
            scene.islandActions=actions;scene.install(members:MockSeed.windowMembers)
            scene.now={ [weak self] in self?.now ?? VerificationClock.modelOrigin };dock.motionTime=scene.now;dock.prepareTideMaterialNow()
            dock.onNeedsFrames={ [weak self] _ in self?.pendingFrame=true }
            dock.onNeedsFramesUntil={ [weak self] _ in self?.pendingFrame=true }
            actions.approvalValue={ [weak self] c,request,response in
                guard let self else{return};self.submitted.append(request.id);self.runtime.respond(request,in:c,response:response)
            }
            actions.answer={ [weak self] c,request,answers in
                guard let self else{return};self.submitted.append(request.id);self.submittedAnswers=answers;self.runtime.answer(request,in:c,answers:answers)
            }
            replay.onEvent={ [weak self] event in
                if event.method=="core/approvalResponded",let id=event.params["approvalId"]?.stringValue {self?.responses.append(id)}
            }
        }
        func emit(_ method:String,_ params:JSONValue) {
            serial+=1;var p=params.objectValue ?? [:];p["threadId"] = .string(target)
            store.apply(.init(id:serial,time:now,method:method,params:.object(p)))
        }
        func start() {emit("turn/started",["turn":["id":.string(turn)]])}
        func command() {emit("item/started",["turnId":.string(turn),"item":["id":"command","type":"commandExecution","command":"swift build"]])}
        func approval(_ id:String,outside:Bool=false) {
            var p:JSONValue=["itemId":"command","command":"printf fixture","availableDecisions":["accept","decline"]]
            if outside {var o=p.objectValue!;o["sandbox_permissions"]="require_escalated";p = .object(o)}
            emit("core/approvalRequested",["approvalId":.string(id),"title":"Allow fixture?","request":["method":"item/commandExecution/requestApproval","params":p]])
        }
        func question(complex:Bool=false) {
            emit("core/approvalRequested",["approvalId":"question-r6","request":["method":"item/tool/requestUserInput","params":["questions":[["id":"scope-r6","question":"Include the fixture?","isSecret":.bool(complex),"options":[["label":"Leave out"],["label":"Include"]]]]]]])
        }
        func pump(_ duration:Double,hz:Double=120) {
            let n=max(1,Int(ceil(duration*hz))),dt=duration/Double(n)
            for _ in 0..<n {
                now+=dt
                if let due=dock.tideLightProbe["nextWakeAt"] as? Double,due<=now {dock.serviceTideDeadline()}
                if pendingFrame {pendingFrame=false;callbacks+=1;dock.frame(at:now,elapsed:.infinity)}
            }
        }
        func force() {dock.frame(at:now,elapsed:.infinity)}
        var p:[String:Any] {dock.tideProbe}
        var ink:[String:Any] {p["presentation"] as? [String:Any] ?? [:]}
        func button(_ title:String)->NSButton? {
            func visit(_ v:NSView)->NSButton? {
                if let b=v as? NSButton,b.title==title,!b.isHiddenOrHasHiddenAncestor {return b}
                for child in v.subviews {if let b=visit(child) {return b}};return nil
            }
            return visit(dock.view)
        }
        func close() {scene.disposeTranscriptPresentation();runtime.shutdown()}
    }
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var reports:[[String:Any]]=[]
        // Every semantic notice goes through the same Core reducer and its journal.
        for event in ["command","step","spawn","finish","tests","approval","question","retryingError","stoppedError","done","context88","context90","compacted"] {
            let f=Fixture();f.start()
            switch event {
            case "command":f.command()
            case "step":f.emit("item/completed",["turnId":.string(f.turn),"item":["id":"file","type":"fileChange","changes":[["path":"Fixture.swift","diff":"-old\n+new"]]]])
            case "spawn","finish":
                f.emit("item/started",["turnId":.string(f.turn),"item":["id":"agent","type":"collabAgentToolCall","receiverThreadIds":["tide-child"],"agentsStates":["tide-child":["status":"running"]]]])
                if event=="finish" {f.emit("item/completed",["turnId":.string(f.turn),"item":["id":"agent","type":"collabAgentToolCall","receiverThreadIds":["tide-child"],"agentsStates":["tide-child":["status":"completed"]]]])}
            case "tests":f.emit("core/pulseProgress",["completed":3,"total":7])
            case "approval":f.approval("approval-r6")
            case "question":f.question()
            case "retryingError":f.emit("error",["turnId":.string(f.turn),"message":"Fixture error","willRetry":true])
            case "stoppedError","done":f.emit("turn/completed",["turn":["id":.string(f.turn),"status":.string(event=="done" ? "completed":"failed"),"error":["message":"Fixture stopped"]]])
            case "context88","context90":f.emit("thread/tokenUsage/updated",["tokenUsage":["last":["totalTokens":.number(event=="context88" ? 880:900)],"modelContextWindow":1000]])
            default:f.emit("thread/compacted",[:])
            }
            let kind=event.hasPrefix("context") ? "context":event
            f.pump(0.8)
            check(f.p["event"] as? String==kind,"Core notice reaches Tide: "+event)
            check(f.p["arrivalContentAllocations"] as? Int==0,"notice delivery reuses prewarmed controls: "+event)
            let halo=event=="approval" || event=="question" || event=="done" ? "card":event=="stoppedError" || event=="context90" ? "column":"none"
            check(f.ink["halo"] as? String==halo,"shared halo classification: "+event)
            let buttons=f.ink["buttons"] as? [[String:Any]] ?? []
            if event=="approval" || event=="question" {check(buttons.count==2 && buttons.allSatisfy{$0["enabled"] as? Bool==true},"native offered actions are enabled: "+event)}
            if event=="stoppedError" {
                check(buttons.map{$0["title"] as? String}==["Review error"],"stopped work offers Review error, never fake Retry")
                f.button("Review error")?.performClick(nil)
                check(f.scene.current=="D" && f.responses.isEmpty,"Review error opens the complete conversation without retrying")
            }
            check((f.p["minimumGap"] as? Double ?? 0)>=11.999,"action/pill and all actual tails retain 12 pt: "+event)
            reports.append(["event":event,"probe":f.p]);f.close()
        }
        for scale:CGFloat in [1,2] {
            let f=Fixture(scale:scale);f.start();f.approval("expiry")
            f.pump(2.5);let before=f.callbacks
            let paints=f.ink["contentUpdates"] as? Int
            for _ in 0..<5 {f.force()}
            check(paints != nil && paints==f.ink["contentUpdates"] as? Int,"unchanged ambient callbacks rewrite no Tide content surfaces: \(scale)x")
            f.pump(1)
            check(f.callbacks==before,"settled action requests zero display frames: \(scale)x")
            let counters=f.p["glassWrites"] as? [String:Int] ?? [:]
            check(counters["still"]==0,"settled action writes zero glass: \(scale)x")
            f.pump(3.49)
            check(f.p["event"] as? String=="approval","action remains until 7 s: \(scale)x")
            f.pump(0.03)
            check(f.p["event"] as? String=="" && (f.ink["actionAlpha"] as? Double ?? 0)>0,"outgoing action retains title/buttons throughout its fade: \(scale)x")
            check((f.ink["buttons"] as? [[String:Any]] ?? []).allSatisfy{$0["enabled"] as? Bool==false},"fading actions cannot submit after hold: \(scale)x")
            f.pump(0.1)
            check((f.ink["actionAlpha"] as? Double ?? -1)==0 && (f.p["occupancyRemaining"] as? Double ?? 0)>4,"7 s event and 11.9 s occupancy are independent: \(scale)x")
            f.pump(5.9)
            check(f.p["phase"] as? String=="idle","action occupancy naturally returns: \(scale)x")
            check(f.store.conversation("D")?.approvals.count==1,"expired presentation keeps the unanswered request: \(scale)x")
            f.close()
        }
        for column in [false,true] {
            let f=Fixture();f.start();f.approval("halo-alpha",outside:column)
            f.pump(0.18);let early=f.ink["haloAlpha"] as? Double ?? -1
            f.pump(0.06);let middle=f.ink["haloAlpha"] as? Double ?? -1
            f.pump(0.76);let late=f.ink["haloAlpha"] as? Double ?? -1
            check(early==0 && middle>0 && middle<1 && late==1,"halo follows the content entrance, never a hard switch: \(column)")
            let r=f.dock.items["D"]!.glass.frame,h=f.ink["haloRect"] as? [CGFloat] ?? []
            let spread=column ? 32.0:0
            check(h.count==4 && abs(h[0]-(r.minX-spread))<0.01 && abs(h[1]-(r.minY-8))<0.01 && abs(h[2]-(r.width+2*spread))<0.01 && abs(h[3]-max(90,r.height+32))<0.01,"halo is anchored only to its own notice shape: \(column)")
            f.pump(6.02)
            let fading=f.ink["haloAlpha"] as? Double ?? -1
            check(fading>0 && fading<1,"halo exits through .07 s content fade: \(column)")
            f.close()
        }
        let multi=Fixture();multi.start();multi.approval("oldest");multi.pump(0.3);multi.approval("newest",outside:true);multi.pump(0.8)
        check(multi.ink["requestID"] as? String=="newest","new urgent request replaces the displayed action")
        check((multi.p["pending"] as? [[String:Any]])?.count==2,"pending retains both request IDs")
        multi.command();multi.force()
        check(multi.ink["requestID"] as? String=="newest","ordinary command cannot replace an urgent action")
        let stale=multi.store.conversation("D")!.approvals.first{$0.id=="newest"}!
        let button=multi.button("Allow")
        check(button != nil,"native Allow hit target exists")
        button?.performClick(nil)
        multi.actions.approvalValue?(multi.store.conversation("D")!,stale,["decision":"accept"])
        multi.pump(0.05)
        check(abs(multi.dock.items["B"]!.glass.frame.width-36)<0.01,"reply gives back unneeded space with the natural .07 delay, not the user-reclaim recipe")
        multi.pump(0.15)
        check(multi.responses.filter{$0=="newest"}.count==1,"native and complete interfaces submit the same request only once")
        check(multi.store.conversation("D")!.approvals.map(\.id)==["oldest"],"reply removes only its own original request ID")
        multi.pump(1.7)
        check(multi.ink["requestID"] as? String=="oldest","after reply hold the oldest unanswered request is displayed")
        reports.append(["multi":multi.p,"submitted":multi.submitted,"responses":multi.responses]);multi.close()
        for complex in [false,true] {
            let f=Fixture();f.start();f.question(complex:complex);f.pump(0.8)
            let rows=f.ink["buttons"] as? [[String:Any]] ?? []
            check(rows.count==(complex ? 1:2),"complex question routes to full interface: \(complex)")
            if !complex {
                f.button("Include")?.performClick(nil);f.pump(0.1)
                check(f.responses==["question-r6"] && f.submittedAnswers==["scope-r6":["Include"]],"native question choice preserves request and answer IDs")
            } else {
                f.button("Answer question")?.performClick(nil)
                check(f.scene.current=="D" && f.responses.isEmpty,"complex Review opens the existing complete Q&A interface")
            }
            f.close()
        }
        let hover=Fixture();hover.start();hover.command();hover.pump(1)
        let r=hover.dock.items["D"]!.glass.frame
        _=hover.dock.pointer(CGPoint(x:r.midX,y:r.midY),now:hover.now)
        let remaining=hover.p["eventRemaining"] as? Double ?? 0
        hover.pump(2)
        check(abs((hover.p["eventRemaining"] as? Double ?? -1)-remaining)<0.01,"hover pauses event and occupancy immediately")
        check(hover.ink["hovering"] as? Bool==true && hover.ink["detailAlpha"] as? Double==1,"hover dwell shows the conversation title and status without continuous frames")
        _=hover.dock.pointer(nil,now:hover.now);hover.pump(0.1)
        _=hover.dock.pointer(CGPoint(x:r.midX,y:r.midY),now:hover.now);hover.pump(0.05)
        check(hover.ink["hovering"] as? Bool==true,"quick exit/reentry retains the hover grace")
        hover.close()
        let reclaim=Fixture();reclaim.start();reclaim.command();reclaim.pump(1)
        let borrowed=reclaim.dock.items["C"]!.glass.frame,original=reclaim.dock.restingTargets.first{$0.id=="C"}!.rect
        _=reclaim.dock.pointer(CGPoint(x:borrowed.midX,y:borrowed.midY),now:reclaim.now);reclaim.pump(1.0/60)
        let first=reclaim.dock.items["C"]!.glass.frame
        check(first.width>36 && first.width<original.width,"reclaim preserves the current pose instead of snapping the editor")
        let bubbles=reclaim.p["bubbles"] as? [[String:Any]] ?? []
        check((bubbles.first{$0["id"] as? String=="C"}?["tail"] as? Double ?? 2)<1,"reclaim releases the tail first")
        reclaim.pump(0.8)
        check(abs(reclaim.dock.items["C"]!.glass.frame.width-original.width)<0.05,"fast reclaim returns the retained editor")
        _=reclaim.dock.pointer(nil,now:reclaim.now);reclaim.pump(0.89)
        check(reclaim.p["level"] as? Int==0,"reclaimed brief remains protected for .9 s")
        reclaim.pump(0.02)
        check(reclaim.p["level"] as? Int==1,"brief becomes borrowable after protection grace")
        reclaim.close()
        for marked in [false,true] {
            let f=Fixture();let c=f.store.conversation("C")!,editor=NativeComposer()
            f.dock.items["C"]!.composer=editor;c.draft="   "
            if marked {editor.textView.setMarkedText("候",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
            let width=f.dock.items["C"]!.target.width,contentWidth=f.dock.items["C"]!.barFace.frame.width
            f.start();f.command();f.pump(0.08)
            check(f.p["level"] as? Int==0,"protected brief cannot be requisitioned: IME \(marked)")
            let current=f.dock.items["C"]!.glass.frame.width
            check(marked ? abs(current-width)<0.01:current<width-0.3 && current>width-2,"refusal knocks glass once and never knocks marked text: \(marked)")
            check(f.dock.items["C"]!.barFace.frame.width==contentWidth,"refusal does not reflow input content: \(marked)")
            f.close()
        }
        for entry in ["handoff","suspend","presentation"] {
            let f=Fixture();f.start();f.approval("lifecycle");f.pump(1)
            if entry=="handoff" {
                let visible=f.dock.items["D"]!.glass.frame,borrowed=f.dock.items["C"]!.glass.frame
                f.scene.beginModeHandoff();f.pendingFrame=false
                f.now+=0.2;f.force()
                check(f.p["phase"] as? String=="frozen" && !f.pendingFrame,"mode preparation freezes without scheduling another Tide frame")
                check(f.dock.items["D"]!.glass.frame==visible && f.dock.items["C"]!.glass.frame==borrowed,"mode capture retains the exact visible notification and borrowed source poses")
                let identity=f.dock.frame(of:"D") ?? .zero
                check(abs(identity.width-min(visible.width,visible.height))<0.001 && identity.height==identity.width && abs(identity.minX-visible.minX)<0.001,"mode flight source is the visible planet, never the full notification capsule")
                f.button("Allow")?.performClick(nil)
                check(f.store.conversation("D")?.approvals.count==1,"frozen mode source cannot submit a retained native action")
                f.scene.suspendModePresentation()
            }
            if entry=="suspend" {f.scene.suspendModePresentation()}
            if entry=="presentation" {f.scene.setTranscriptPresentationActive(false)}
            check(f.dock.tideAnimationDiagnostics["tideRequestsDisplayFrames"] as? Bool==false,"real lifecycle entry retires Tide clock: "+entry)
            check((f.dock.tideMaterialProbe["shapes"] as? [[String:Any]])?.isEmpty==true,"real lifecycle entry parks physical tails: "+entry)
            check(f.store.conversation("D")?.approvals.count==1,"retirement preserves pending and sends no response: "+entry)
            f.close()
        }
        let barrier=Fixture();barrier.scene.show("C");barrier.dock.prepareTideMaterialNow();barrier.dock.setTideCapacityFixture(800)
        barrier.start();barrier.command();barrier.pump(1)
        check(barrier.p["level"] as? Int==0,"a full input between the bank and brief bubbles is a contiguous-space barrier")
        check((barrier.p["ownerOriginalOpacity"] as? Double ?? 0)==1,"orb-only notification preserves its unique ordinary status badge")
        check(!barrier.dock.tideOwns("D"),"an orb-only fallback keeps ordinary Peek and land ownership")
        barrier.close()
        let http=Fixture();http.start();http.approval("http-old");http.approval("http-new");http.pump(0.8)
        let httpChat=http.store.conversation("D")!
        httpChat.approvals.removeAll{$0.id=="http-new"};http.store.changed(httpChat)
        http.pump(0.1)
        check(http.p["event"] as? String=="reply","HTTP acknowledgement without streamed reply starts a real response hold")
        check(http.ink["halo"] as? String=="none","response fade releases the previous request halo classification")
        http.pump(1.8)
        check(http.ink["requestID"] as? String=="http-old","HTTP acknowledgement resumes the oldest remaining request")
        http.close()
        let waterline=Fixture();waterline.start();waterline.command();waterline.pump(0.8)
        waterline.dock.refreshOrbs()
        func face()->[String:Any] {(waterline.dock.tideMaterialProbe["faces"] as? [String:[String:Any]])?["D"] ?? [:]}
        check(face()["running"] as? Bool==true,"prewarmed Tide face follows the live running identity")
        waterline.emit("turn/completed",["turn":["id":.string(waterline.turn),"status":"completed"]])
        waterline.emit("thread/tokenUsage/updated",["tokenUsage":["last":["totalTokens":880],"modelContextWindow":1000]])
        waterline.dock.refreshOrbs()
        check(face()["running"] as? Bool==false && face()["context"] as? Double==0.88,"prewarmed Tide face follows the reported terminal context")
        waterline.close()
        let submitting=Fixture();submitting.start();submitting.approval("submitting");submitting.pump(0.8)
        submitting.store.conversation("D")!.approvals[0].submitting=true;submitting.store.changed(submitting.store.conversation("D")!)
        submitting.pump(1.0/60)
        check(submitting.button("Allow")?.isEnabled==false,"shared in-flight state disables Tide without a new journal event")
        submitting.button("Allow")?.performClick(nil)
        check(submitting.responses.isEmpty,"submitting actions cannot emit another response")
        submitting.close()
        let live=Fixture();live.start();live.emit("core/pulseProgress",["completed":3,"total":7]);live.pump(9)
        check(live.p["phase"] as? String=="holding" && live.p["motionBusy"] as? Bool==false,"reported unfinished progress retains occupancy without continuous frames")
        let liveFrames=live.callbacks;live.pump(1)
        check(live.callbacks==liveFrames,"unchanged progress requests no display callbacks")
        live.emit("turn/completed",["turn":["id":.string(live.turn),"status":"interrupted"]]);live.pump(1.5)
        check(live.p["phase"] as? String=="idle","terminal reconciliation releases progress even without another notice")
        live.close()
        let clickReclaim=Fixture();clickReclaim.start();clickReclaim.command();clickReclaim.pump(1)
        let clickRect=clickReclaim.dock.items["C"]!.glass.frame
        let point=CGPoint(x:clickRect.midX,y:clickRect.midY)
        let hit=clickReclaim.dock.view.hitTest(clickReclaim.dock.view.convert(point,to:clickReclaim.dock.view.superview))
        check(hit != nil,"borrowed face has a native reclaim hit target")
        let down=NSEvent.mouseEvent(with:.leftMouseDown,location:clickReclaim.dock.view.convert(point,to:nil),modifierFlags:[],timestamp:clickReclaim.now,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        hit?.mouseDown(with:down)
        let up=NSEvent.mouseEvent(with:.leftMouseUp,location:down.locationInWindow,modifierFlags:[],timestamp:clickReclaim.now,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:0)!
        hit?.mouseUp(with:up);clickReclaim.pump(0.1)
        let reclaimPose=clickReclaim.dock.items["C"]!.glass.frame
        check(reclaimPose.width>36 && reclaimPose.width<clickReclaim.dock.items["C"]!.target.width,"click first plays the board reclaim before activating the column")
        let epoch=clickReclaim.dock.makeTransitionEpoch(at:clickReclaim.now)
        check(epoch.worldItems["C"]==reclaimPose && epoch.items["C"]?.rect.width==reclaimPose.width,"layout source epoch uses the actual retained reclaim pose")
        clickReclaim.pump(0.2)
        check(clickReclaim.scene.current=="C","native borrowed-face click activates the retained conversation editor")
        clickReclaim.close()
        let cancelled=Fixture();cancelled.start();cancelled.approval("cancelled-mode");cancelled.pump(0.6)
        cancelled.scene.beginModeHandoff();cancelled.scene.endModeHandoff();cancelled.pump(1.5)
        check(cancelled.p["phase"] as? String=="idle" && cancelled.store.conversation("D")?.approvals.count==1,"cancelled mode handoff releases frozen geometry without reviving pin or answering")
        cancelled.close()
        for (from,to) in [("D","E"),("E","D"),("D","F"),("F","D"),("E","F"),("F","E")] {
            let f=Fixture();f.target=from;f.start();f.approval("cross-first");f.pump(0.9)
            f.target=to;f.start();f.approval("cross-new",outside:true)
            var minimum=Double.infinity,complete=true
            for _ in 0..<180 {
                f.pump(1.0/120)
                minimum=min(minimum,f.p["minimumGap"] as? Double ?? 0)
                complete=complete && (f.p["nodes"] as? [String:Any])?.count==3
            }
            check(f.p["owner"] as? String==to && f.p["level"] as? Int==2,"cross-conversation urgent replacement acquires its own lease: \(from)→\(to)")
            check(complete,"replacement keeps every ordinary orb represented: \(from)→\(to)")
            check(minimum>=11.999,"replacement retains every physical 12 pt gap: \(from)→\(to), \(minimum)")
            check((f.p["pending"] as? [[String:Any]])?.count==2,"cross-conversation pending IDs remain independent")
            f.button("Allow")?.performClick(nil);f.pump(1.9)
            check(f.p["owner"] as? String==from && f.ink["requestID"] as? String=="cross-first","reply resumes the oldest unanswered conversation")
            reports.append(["from":from,"to":to,"minimum":minimum,"probe":f.p]);f.close()
        }
        // AppKit's local input monitor and real NSWindow lifecycle, with a hidden window only.
        for entry in ["escape","outside","resign","close"] {
            let f=Fixture()
            let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1280,height:820),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
            let host=NSView(frame:CGRect(x:0,y:0,width:1280,height:820));window.contentView=host
            host.addSubview(f.scene.sceneView);host.addSubview(f.dock.view)
            f.start();f.approval("window-pending");f.pump(0.8)
            if entry=="escape" || entry=="outside" {
                let event:NSEvent
                if entry=="escape" {
                    event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:f.now,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
                } else {
                    let point=f.dock.view.convert(CGPoint(x:20,y:200),to:nil)
                    event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:f.now,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                }
                NSApp.postEvent(event,atStart:true)
                if let next=NSApp.nextEvent(matching:entry=="escape" ? .keyDown:.leftMouseDown,until:Date(timeIntervalSinceNow:0.02),inMode:.default,dequeue:true) {NSApp.sendEvent(next)}
                check(f.p["phase"] as? String=="returning","real local monitor consumes the top Tide dismissal: "+entry)
                f.pump(1.5)
            } else if entry=="resign" {window.resignKey();f.pump(1.5)}
            else {window.close()}
            check(f.p["phase"] as? String=="idle","real window input/lifecycle retires Tide: "+entry)
            check(f.store.conversation("D")?.approvals.count==1 && f.responses.isEmpty,"window dismissal sends no synthetic answer: "+entry)
            if entry=="resign" {
                f.scene.restOnSnapshot=false
                f.command();f.pump(0.2)
                check(f.p["phase"] as? String=="idle","a non-key window cannot reopen Tide on a later Core event")
            }
            check(!window.isVisible,"window fixture remains offscreen: "+entry)
            f.close();window.contentView=nil;if entry != "close" {window.close()}
        }
        let modal=Fixture()
        let modalWindow=NSWindow(contentRect:CGRect(x:0,y:0,width:1280,height:820),styleMask:.borderless,backing:.buffered,defer:false)
        modalWindow.isReleasedWhenClosed=false
        let modalHost=NSView(frame:CGRect(x:0,y:0,width:1280,height:820));modalWindow.contentView=modalHost
        modalHost.addSubview(modal.dock.view);modalHost.addSubview(modal.scene.overlayPlane)
        modal.start();modal.approval("under-sheet");modal.pump(0.8)
        let sheet=SheetSurface();sheet.present(anchor:CGRect(x:400,y:400,width:100,height:20),in:modal.scene.overlayPlane)
        let modalEsc=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:modal.now,windowNumber:modalWindow.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        NSApp.postEvent(modalEsc,atStart:true)
        if let next=NSApp.nextEvent(matching:.keyDown,until:Date(timeIntervalSinceNow:0.02),inMode:.default,dequeue:true) {NSApp.sendEvent(next)}
        check(sheet.isDismissing,"Esc reaches the actual top sheet")
        check(modal.p["phase"] as? String=="holding","one Esc never dismisses both the sheet and Tide")
        sheet.dismiss(reason:.programmatic,animated:false);modal.close();modalWindow.contentView=nil;modalWindow.close()
        let previous=UserDefaults.standard.object(forKey:"toggle.simulateReduceMotion")
        UserDefaults.standard.set(true,forKey:"toggle.simulateReduceMotion")
        let reduced=Fixture();reduced.start();reduced.approval("reduce");reduced.pump(1.0/60)
        check(Motion.reduce,"Reduce Motion test uses the real product input")
        check(reduced.p["motionBusy"] as? Bool==false,"Reduce Motion reaches the valid geometry without spring frames")
        check(reduced.ink["actionAlpha"] as? Double==1,"Reduce Motion preserves offered actions")
        check(DockTideAnimationAudit.snapshot([("dock",reduced.dock.view)])["runningLoops"] as? Int==0,"reduced Tide installs no loop")
        reduced.close();if let previous {UserDefaults.standard.set(previous,forKey:"toggle.simulateReduceMotion")}else {UserDefaults.standard.removeObject(forKey:"toggle.simulateReduceMotion")}
        check(NSApp.windows.allSatisfy{!$0.isVisible},"round6 opens no visible window")
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round6.json"))
    }
}
#endif
