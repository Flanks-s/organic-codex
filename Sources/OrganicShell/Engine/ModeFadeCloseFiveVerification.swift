#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Native menu routing without rest repair between keys, in a window that is never ordered.
@MainActor enum ModeFadeCloseFiveVerification {
    static func run(to output:URL) throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        ModeSignposts.receiptsEnabled=true
        var checks=0,failures:[String]=[],facts:[[String:Any]]=[]
        func check(_ v:Bool,_ name:String) {checks+=1;if !v {failures.append(name);print("FAIL: "+name)}}
        func wait(_ t:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:max(0,t)))}
        let only=ProcessInfo.processInfo.environment["M1131_R5_CASE"] ?? "all"
        if only == "all" || only == "budget" {
            let host=NSView(frame:CGRect(x:0,y:0,width:1280,height:820))
            ModeContentWorkBoundary.verificationManualTickets=true
            defer {ModeContentWorkBoundary.cancel(in:host);ModeContentWorkBoundary.verificationManualTickets=false}
            for hz in [60.0,120.0] {
                let interval=1/hz;var budgets:[Double]=[]
                for delay in [0.002,0.004,0.006] {
                    ModeContentWorkBoundary.schedule(in:host,interval:interval) {
                        budgets.append(ModeContentWorkBoundary.captureBudget())
                    }
                    let now=CACurrentMediaTime()
                    // A display callback may enter late; work still needs its measured CPU window.
                    ModeContentWorkBoundary.verificationDisplayTicket(timestamp:now-interval+delay,target:now+delay,interval:interval)
                    wait(0.001)
                }
                let budget=budgets.isEmpty ? 0:budgets.reduce(0,+)/Double(budgets.count)
                let jobs=budget>0 ? Int(ceil(0.165/budget)):10000
                check(budgets.count == 3,"budget receives all distinct tickets at \(hz) Hz")
                check(budgets.allSatisfy {$0 >= (hz == 120 ? 0.0039:0.0059)},"budget grants real work time despite a late callback at \(hz) Hz")
                check(budgets.allSatisfy {$0 <= interval-0.002+0.00001},"budget retains two milliseconds of work-cycle commit margin at \(hz) Hz")
                check(jobs <= (hz == 120 ? 43:29),"budget processes 165 ms within the bounded cycle count at \(hz) Hz")
                facts.append(["kind":"budget","hz":hz,"budgetsMS":budgets.map {$0*1000},"workMS":165,"cycles":jobs,"wallMS":Double(jobs)*interval*1000])
                var remaining=0.165,costs:[Double]=[],grants:[Double]=[],margins:[Double]=[],cycles=0
                let workOrigin=CACurrentMediaTime()+0.01
                while remaining>0.00001,cycles<220 {
                    wait(workOrigin+Double(cycles)*interval-CACurrentMediaTime())
                    let stamp=CACurrentMediaTime(),target=stamp+interval*0.75
                    ModeContentWorkBoundary.schedule(in:host,interval:interval) {
                        let began=CACurrentMediaTime(),grant=ModeContentWorkBoundary.captureBudget(at:began)
                        grants.append(grant*1000)
                        let duration=min(remaining,max(0,grant-0.0001)),end=began+duration
                        while CACurrentMediaTime()<end {}
                        remaining-=duration;let cost=CACurrentMediaTime()-began
                        costs.append(cost*1000);margins.append((interval-max(0.002,interval*0.15)-cost)*1000)
                    }
                    ModeContentWorkBoundary.verificationDisplayTicket(timestamp:stamp-interval*0.25,target:target,interval:interval)
                    let late=stamp+0.003;while CACurrentMediaTime()<late {}
                    wait(0.001);cycles+=1
                }
                check(remaining<0.00001,"budget really executes all 165 ms at \(hz) Hz")
                check(cycles <= (hz == 120 ? 44:30),"budget actual 165 ms work has bounded tickets at \(hz) Hz")
                check(margins.allSatisfy {$0>=0},"budget every measured slice leaves the cycle commit reserve at \(hz) Hz")
                facts.append(["kind":"work165","hz":hz,"cycles":cycles,"grantsMS":grants,"costsMS":costs,"marginsMS":margins,"remainingMS":remaining*1000,"measuredWallMS":(CACurrentMediaTime()-workOrigin)*1000])

            }
        }
        if only != "budget" {
            let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
            seed.start(live:false)
            let sessions=NativeTranscriptSessions(store:store),scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
            scene.ambient=false;scene.manualSettle=false
            let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
            for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=root.bounds;root.addSubview(plane)}
            let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
            _=workbench.composerForHandoff();scene.install();scene.settle()
            let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic)
            let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentViewController=shell;shell.installToolbar(in:window)
            window.contentView?.superview?.layoutSubtreeIfNeeded();window.makeKey()
            scene.dock.focusTargetProvider={scene.focusTarget}
            scene.onTarget={id in scene.dock.focusTarget=id;guard shell.mode == .organic else {return};workbench.memberOrder=scene.order;_=workbench.select(id)}
            var binding:OverlayComposerBinding?
            workbench.onComposerPresentationChange={composer,host in
                binding?.disconnect();binding=nil
                if let composer,let host,host.window != nil {binding=OverlayComposerBinding(composer:composer,host:host)}
            }
            var nativeRepaintArmed=false,repainted:Set<String>=[],repairHeld:[String:Bool]=[:]
            let replayPaint=ProcessInfo.processInfo.environment["M1131_R5_REPAINT"] == "1"
            // Observe the production exposure frame, not a slower timer after the owner may have retired.
            // Only a live carrier can receive this callback; hide its native paint once, then observe repair.
            shell.flight.onExposureSample={sample in
                guard replayPaint,nativeRepaintArmed,shell.flight.running else {return}
                let id=sample.id == "me" ? "me":String(sample.id.dropFirst("planet.".count))
                guard ["D","E","F","me"].contains(id) else {return}
                if repainted.contains(id),repairHeld[id] == nil,shell.verificationEndpointOwner(id) {
                    repairHeld[id]=id == "me" ? shell.flight.debugState["avatarHidden"] as? Bool == false:shell.flight.heldConversationIDs.contains(id)
                }
                if !repainted.contains(id),shell.verificationEndpointOwner(id) {
                    repainted.insert(id)
                    if id == "me" {scene.setMeHidden(true)} else {scene.setDockHidden(id,true)}
                }
            }
            let timer=Timer(timeInterval:1/60,repeats:true) {_ in MainActor.assumeIsolated {
                scene.frame(CACurrentMediaTime());if shell.flight.running {shell.flight.verificationDisplayAdvance(at:shell.flight.elapsed)}
            }}
            RunLoop.main.add(timer,forMode:.common)
            defer {timer.invalidate();binding?.disconnect();workbench.onComposerPresentationChange=nil;scene.onTarget=nil;shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
            let router=Router(shell:shell)
            func toggle() {let item=NSMenuItem(title:"Mode",action:#selector(Router.mode(_:)),keyEquivalent:"s");item.target=router;_=NSApp.sendAction(item.action!,to:item.target,from:item)}
            func member(_ index:Int) {let item=NSMenuItem(title:"Member",action:#selector(Router.member(_:)),keyEquivalent:String(index+1));item.target=router;item.tag=index;_=NSApp.sendAction(item.action!,to:item.target,from:item)}
            func chain(_ v:NSView)->[[String:Any]] {
                var rows:[[String:Any]]=[],node:NSView?=v
                while let v=node {rows.append(["type":String(describing:type(of:v)),"hidden":v.isHidden,"alpha":v.alphaValue,"opacity":v.layer?.opacity ?? -1,"presented":v.layer?.presentation()?.opacity ?? -1,"frame":NSStringFromRect(v.convert(v.bounds,to:shell.view)),"animations":v.layer?.animationKeys() ?? []]);node=v.superview}
                return rows
            }
            func inspect(_ label:String,_ expected:String,_ target:WindowShell.Mode) {
                let shown=target == .organic ? scene.current:workbench.selectedConversation?.id ?? ""
                let composer=target == .organic ? scene.composers.existingComposer(for:expected):workbench.detail.composer
                let before=composer?.text ?? "",event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:window.windowNumber,context:nil,characters:"q",charactersIgnoringModifiers:"q",isARepeat:false,keyCode:12)!
                window.firstResponder?.keyDown(with:event)
                let typed=window.firstResponder === composer?.textView && composer?.text != before
                check(shell.mode == target && shown == expected && !shell.flight.running && typed,"driver \(label) mode, selection, retirement and real keyDown")
                if replayPaint,nativeRepaintArmed,target == .organic,expected == "D" {
                    for id in ["D","E","F"] {
                        let item=scene.dock.items[id]
                        check(repainted.contains(id) && item?.glass.isHidden == false && item?.glass.layer?.isHidden != true && item?.decoration.frontView.isHidden == false,"ownership a late native \(id) paint is reconciled before carrier retirement")
                    }
                    check(repainted.contains("me") && !shell.flight.running,"ownership a late native avatar paint cannot park the flight")
                    for id in ["D","E","F","me"] {check(repairHeld[id] == true,"ownership repaired \(id) waits for a fresh displayed owner before retirement")}

                }
                var state:[String:Any]=["kind":"driver","label":label,"wanted":expected,"shown":shown,"mode":shell.mode.rawValue,"running":shell.flight.running,"typed":typed,"first":window.firstResponder.map {String(describing:type(of:$0))} ?? "nil","owners":shell.verificationCloseTwoOwners,"state":shell.verificationContentSessionState,"dock":chain(scene.dockView),"held":Array(shell.flight.heldConversationIDs).sorted(),"fence":shell.flight.verificationOwnerFenceState]
                state["tokens"]=shell.flight.activeTokens.map {["id":$0.id,"from":NSStringFromRect($0.from),"to":NSStringFromRect($0.to),"absorbed":$0.absorbed] as [String:Any]}
                state["items"]=scene.dock.items.mapValues {chain($0.glass)};state["repainted"]=Array(repainted).sorted();state["repairHeld"]=repairHeld;facts.append(state)
            }
            seed.start(live:true)
            toggle();wait(2.3);workbench.detail.composer?.focus();wait(0.3)
            toggle();wait(0.15);member(1);wait(2.3);inspect("N-O .15 member2","B",.organic);wait(0.15)
            toggle();wait(0.15);member(2);wait(2.3);inspect("O-N .15 member3","C",.normie);wait(0.15)
            nativeRepaintArmed=true;toggle();wait(0.9);member(3);wait(2.5);inspect("N-O .90 member4","D",.organic)
            if only == "all" {
                toggle();wait(0.9);member(0);wait(2.5);inspect("O-N .90 member1","A",.normie)
                for index in [0,1,2] {
                    toggle();wait(0.9);member(index);wait(2.5);inspect("symmetric organic member\(index+1)",scene.order[index],.organic)
                    toggle();wait(2.3)
                }
            }
            check(!window.isVisible,"driver never orders a native window")
        }
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"facts":facts,"receipt":ModeSignposts.receipt],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fade-close5.json"))
        print("Fade close 5: \(checks)/\(failures.count)");return failures.isEmpty ? 0:1
    }
    @MainActor private final class Router:NSObject {
        let shell:WindowShell
        init(shell:WindowShell) {self.shell=shell}
        @objc func mode(_ sender:NSMenuItem) {shell.setMode(shell.mode == .normie ? .organic:.normie)}
        @objc func member(_ sender:NSMenuItem) {shell.selectModeMember(at:sender.tag)}
    }
}
#endif
