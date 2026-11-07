#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// The unshown window runs the same target callback and scene clock as OrganicWindow.
@MainActor enum ModeFadeCloseTwoVerification {
    static var beforeSelectedFocus:(()->Void)?
    static func run(to output:URL) throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],rows:[[String:Any]]=[]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        func wait(_ t:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:t))}
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false);for c in store.conversations {c.running=false;c.sending=false;c.loading=false}
        let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=false
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=root.bounds;root.addSubview(plane)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic)
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentViewController=shell
        shell.installToolbar(in:window);window.contentView?.superview?.layoutSubtreeIfNeeded();window.makeKey()
        // Exactly the production onTarget body; selection callbacks must not detach the focused editor.
        scene.dock.focusTargetProvider={scene.focusTarget}
        scene.onTarget={id in
            scene.dock.focusTarget=id
            guard shell.mode == .organic else {return}
            workbench.memberOrder=scene.order;_=workbench.select(id)
        }
        var nativeMountInsideFlight=false
        let timer=Timer(timeInterval:1/120,repeats:true) {_ in MainActor.assumeIsolated {
            scene.frame(CACurrentMediaTime())
            if shell.flight.running {
                let before=sessions.modeMountGeneration
                shell.flight.verificationDisplayAdvance(at:shell.flight.elapsed)
                if sessions.modeMountGeneration != before {nativeMountInsideFlight=true}
            }
        }}
        RunLoop.main.add(timer,forMode:.common)
        defer {timer.invalidate();scene.onTarget=nil;shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        func rest(_ organic:Bool) {
            shell.settlePendingMode();shell.flight.cancel();shell.verificationFlightSettle(asOrganic:organic);shell.verificationRepairRest(organic ? .organic:.normie)
            scene.settle();window.contentView?.superview?.layoutSubtreeIfNeeded();shell.verificationForgetContentCandidate()
        }
        // NSMenuItem target/action is the same member command entry point, not a direct fixture selection.
        var commit=0,work:[[String:Any]]=[],sourceCoverChecks:[Bool]=[]
        let commitObserver=CFRunLoopObserverCreateWithHandler(nil,CFRunLoopActivity.beforeWaiting.rawValue,true,CFIndex.max-2) {_,_ in MainActor.assumeIsolated {commit+=1}}!
        CFRunLoopAddObserver(CFRunLoopGetMain(),commitObserver,.commonModes)
        defer {CFRunLoopRemoveObserver(CFRunLoopGetMain(),commitObserver,.commonModes)}
        shell.onTurnCost={phase,ms in
            work.append(["phase":phase,"ms":ms,"commit":commit,"time":CACurrentMediaTime()])
            if ["native.columns","native.dock"].contains(phase) {sourceCoverChecks.append(scene.columns.allSatisfy {($0.island?.layer?.opacity ?? 0) == 0})}
        }
        let router=MemberRouter(shell:shell,scene:scene,workbench:workbench)
        func pressMember(_ index:Int) {
            let item=NSMenuItem(title:"Member",action:#selector(MemberRouter.member(_:)),keyEquivalent:String(index+1));item.target=router;item.tag=index
            _=NSApp.sendAction(item.action!,to:item.target,from:item)
        }
        rest(false)
        seed.start(live:true)
        for (initial,delay,index) in [(false,0.15,1),(true,0.15,2),(false,0.9,3),(true,0.9,0)] {
            let composer=initial ? scene.composers.existingComposer(for:scene.current):workbench.detail.composer;composer?.focus()
            let wanted:WindowShell.Mode=initial ? .normie:.organic
            if !initial,index == 1 {
                beforeSelectedFocus={
                    beforeSelectedFocus=nil
                    guard let composer=scene.composers.existingComposer(for:"B"),let host=composer.superview else {return}
                    // The real Dock's native mount can follow its semantic/current commit. Keep the
                    // editor absent for one asynchronous mount instead of treating model identity as readiness.
                    composer.removeFromSuperview()
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.08) {host.addSubview(composer)}
                }
            }
            shell.setMode(wanted);wait(delay);let expected=scene.order[index];pressMember(index);wait(2.4)
            // Keep the complete callback order alive after the flight itself retires.
            scene.tellTarget();wait(0.1)
            let shown=wanted == .organic ? scene.current:workbench.selectedConversation?.id ?? ""
            let editor=wanted == .organic ? scene.composers.existingComposer(for:shown):workbench.detail.composer
            let responder=window.firstResponder,before=editor?.text ?? ""
            if let text=responder as? NSTextView {text.insertText("close2",replacementRange:text.selectedRange())}
            let focused=editor != nil && responder === editor?.textView && editor?.text != before
            check(shown == expected,"member selects the requested conversation with production target callbacks \(wanted) \(delay)")
            check(!shell.flight.running,"member leaves a completed flight \(wanted) \(delay)")
            check(focused,"typing reaches the visible native composer after target callbacks \(wanted) \(delay)")
            var row=shell.verificationFadeClosureState;row["expected"]=expected;row["firstResponder"]=responder.map {String(describing:type(of:$0))} ?? "nil";row["owners"]=shell.verificationCloseTwoOwners;rows.append(row)
        }
        beforeSelectedFocus=nil
        for warm in [false,true] {
            rest(false);seed.stopPlayback();for c in store.conversations {c.running=false;c.sending=false;c.loading=false}
            if warm {shell.verificationWaitForWarmContent()}
            let start=work.count
            shell.setMode(.organic);wait(1.9)
            let jobs=Array(work.dropFirst(start))
            let installed=jobs.first {$0["phase"] as? String == "picture.install"}
            let admitted=jobs.first {$0["phase"] as? String == "native.admission"}
            check(installed != nil && admitted != nil,"phase-boundary fixture completes its picture and native admission \(warm)")
            check((admitted?["commit"] as? Int ?? -1) > (installed?["commit"] as? Int ?? -1),"picture registration and native admission cross an AppKit/CA commit \(warm)")
        }
        rest(false);nativeMountInsideFlight=false
        shell.setMode(.organic);wait(0.95);shell.setMode(.normie);wait(0.8)
        check(!nativeMountInsideFlight,"shared native leases never migrate inside a flight display-link transaction")
        rest(false);shell.verificationWaitForWarmContent();shell.setMode(.organic);shell.verificationFlightAdmit()
        let mask=shell.verificationClosureSidebarCutout,bar=shell.verificationFadeDockBars.first
        let maskTime=(mask?.animation(forKey:"mode.content.sidebar-cutout"))?.beginTime
        let dockTime=(bar?.animation(forKey:"mode.content.phase"))?.beginTime
        check(maskTime != nil && dockTime != nil,"layout-cache fixture has both production server clocks")
        for _ in 0..<20 {shell.viewDidLayout()}
        check(mask?.animation(forKey:"mode.content.sidebar-cutout")?.beginTime == maskTime,"unchanged layout never reinstalls the sidebar cutout clock")
        check(bar?.animation(forKey:"mode.content.phase")?.beginTime == dockTime,"unchanged layout never reinstalls the Dock phase clock")
        // A guard can begin between the newly separate source-detach and native-admission jobs.
        rest(false);workbench.setTerminalShown(true,animated:false)
        var injected=false
        shell.onTurnCost={phase,ms in
            work.append(["phase":phase,"ms":ms,"commit":commit,"time":CACurrentMediaTime()])
            if phase == "native.detach",!injected {
                injected=true;let field=workbench.detail.terminalPane.inputField;window.makeFirstResponder(field)
                (field.currentEditor() as? NSTextView)?.setMarkedText("guard",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            }
        }
        shell.setMode(.organic)
        let guardDeadline=Date(timeIntervalSinceNow:4)
        while (!injected || shell.modeContentInputBlocked),Date()<guardDeadline {wait(0.005)}
        let field=workbench.detail.terminalPane.inputField,editor=field.currentEditor() as? NSTextView
        check(injected,"late-IME fixture reaches the separate source detach commit")
        check(shell.mode == .normie && !shell.flight.running && !shell.modeContentInputBlocked,"late IME admission refusal restores the complete original native owner")
        check(editor?.hasMarkedText() == true,"source restoration preserves terminal IME and its actual field editor")
        editor?.unmarkText();window.makeFirstResponder(nil);workbench.setTerminalShown(false,animated:false)
        shell.onTurnCost=nil
        check(!sourceCoverChecks.isEmpty,"prepared native columns and Dock are observed at their real commit boundaries")
        check(sourceCoverChecks.allSatisfy {$0},"the complete source picture covers native headers throughout the staged commits")
        // A native Pulse may dim after one identity's handoff while later identities are still airborne.
        // Retirement is an acknowledged transfer, not a permanently repeated native opacity requirement.
        let flight=ModeFlight();var time=1000.0,dimmed=false
        flight.manualTime={time};flight.resize(to:size)
        let models=MockSeed.make(),r=ModeOrreryFlightVerification.rows,o=ModeOrreryFlightVerification.real
        let tokens=(0..<6).map {i in ModeFlight.Token(id:models[i].id,conversation:models[i],from:r[i],to:o[i],start:0.08+Double(i)*0.04,absorbed:false)}
        flight.destinationOwnerVisible={id in id != models[0].id || !dimmed}
        flight.start(toOrganic:true,avatar:(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar),initials:"LL",tokens:tokens,composer:nil,reduceMotion:false)
        let end=flight.duration
        for frame in 0...Int(ceil((end+0.1)*120)) {
            let t=Double(frame)/120;time=1000+t;flight.advance(at:t)
            if !flight.heldConversationIDs.contains(models[0].id),flight.running {dimmed=true}
        }
        check(dimmed,"native-opacity negative actually changes an already handed-off endpoint")
        check(!flight.running,"native opacity after a completed transfer cannot keep the flight/session alive")
        flight.shutdown()
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"rows":rows,"work":work,"key":window.isKeyWindow,"visible":window.isVisible],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fade-close2.json"))
        print("Fade close two: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    @MainActor private final class MemberRouter:NSObject {
        let shell:WindowShell,scene:AutoScene,workbench:NormieWorkbench
        init(shell:WindowShell,scene:AutoScene,workbench:NormieWorkbench) {self.shell=shell;self.scene=scene;self.workbench=workbench}
        @objc func member(_ sender:NSMenuItem) {
            shell.selectModeMember(at:sender.tag)
        }
    }
}
#endif
