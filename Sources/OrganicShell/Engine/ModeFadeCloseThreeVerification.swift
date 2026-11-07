#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// A hidden real split window. A responder gap and a stale field editor are legal AppKit migration states.
@MainActor enum ModeFadeCloseThreeVerification {
    @MainActor final class Window:NSWindow {
        var responderGap=false
        override var firstResponder:NSResponder? {responderGap ? nil:super.firstResponder}
    }
    static func run(to output:URL) throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],observations:[[String:Any]]=[]
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
        let window=Window(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentViewController=shell
        shell.installToolbar(in:window);window.contentView?.superview?.layoutSubtreeIfNeeded()
        var binding:OverlayComposerBinding?
        workbench.onComposerPresentationChange={composer,host in
            binding?.disconnect();binding=nil
            if let composer,let host,host.window != nil {binding=OverlayComposerBinding(composer:composer,host:host)}
        }
        scene.onTarget={id in scene.dock.focusTarget=id;guard shell.mode == .organic else {return};workbench.memberOrder=scene.order;_=workbench.select(id)}
        let timer=Timer(timeInterval:1/120,repeats:true) {_ in MainActor.assumeIsolated {
            scene.frame(CACurrentMediaTime());if shell.flight.running {shell.flight.verificationDisplayAdvance(at:shell.flight.elapsed)}
        }}
        RunLoop.main.add(timer,forMode:.common)
        defer {timer.invalidate();binding?.disconnect();workbench.onComposerPresentationChange=nil;scene.onTarget=nil;shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        func rest(_ organic:Bool) {
            shell.settlePendingMode();shell.flight.cancel();shell.verificationFlightSettle(asOrganic:organic);shell.verificationRepairRest(organic ? .organic:.normie)
            scene.settle();window.contentView?.superview?.layoutSubtreeIfNeeded();shell.verificationForgetContentCandidate()
        }
        rest(true);scene.show("B");scene.remountComposers();wait(0.05)
        window.responderGap=true
        shell.verificationCloseThreeRestoreFocus("B",target:.organic)
        window.responderGap=false
        window.makeFirstResponder(NSTextView(frame:.zero));wait(0.18)
        check(window.firstResponder === scene.composers.existingComposer(for:"B")?.textView,"a transient nil responder never consumes the deferred member focus request")
        // An automatic focus in the source editor is not a new user selection.
        scene.show("B");scene.remountComposers();window.makeFirstResponder(scene.composers.existingComposer(for:"A")?.textView)
        shell.verificationCloseThreeRestoreFocus("B",target:.organic);wait(0.18)
        check(window.firstResponder === scene.composers.existingComposer(for:"B")?.textView,"automatic source-editor focus cannot override the explicit member command")
        let looseHost=NSView(frame:CGRect(x:0,y:0,width:0,height:820)),looseRoot=NSView(frame:CGRect(origin:.zero,size:size))
        looseHost.wantsLayer=true;looseRoot.addSubview(looseHost)
        let sidebar=ModeTurnSidebar();let sideTime=1000.0;sidebar.now={sideTime}
        sidebar.bindNative(host:looseHost,content:looseHost,in:looseRoot);sidebar.settleNative(incoming:false)
        looseHost.setFrameSize(CGSize(width:240,height:820));sidebar.moveNative(incoming:true)
        check(abs(sidebar.rowOffset(at:sideTime)+248)<0.01,"first sidebar entry starts beyond its allocated width after initial split layout")
        sidebar.finish()
        rest(true)
        var sourceHides=0,work:[[String:Any]]=[],commit=0,sidebarAtEpoch:Bool?
        let observer=root.observe(\.isHidden,options:[.old,.new]) {_,change in MainActor.assumeIsolated {
            if shell.modeContentInputBlocked,change.oldValue == false,change.newValue == true {sourceHides+=1}
        }}
        let boundaryObserver=CFRunLoopObserverCreateWithHandler(nil,CFRunLoopActivity.beforeWaiting.rawValue,true,CFIndex.max-2) {_,_ in MainActor.assumeIsolated {commit+=1}}!
        CFRunLoopAddObserver(CFRunLoopGetMain(),boundaryObserver,.commonModes)
        defer {observer.invalidate();CFRunLoopRemoveObserver(CFRunLoopGetMain(),boundaryObserver,.commonModes)}
        shell.onTurnCost={phase,ms in
            work.append(["phase":phase,"ms":ms,"commit":commit])
            if phase == "epoch.freeze" {sidebarAtEpoch=shell.verificationClosureSidebarCutout != nil}
        }
        shell.setMode(.normie)
        let deadline=Date(timeIntervalSinceNow:4)
        while shell.verificationContentSessionState["active"] as? Bool != true,Date()<deadline {wait(0.002)}
        check(shell.verificationContentSessionState["active"] as? Bool == true,"clean return reaches its prepared live fade")
        check(sidebarAtEpoch == true,"the sidebar samples the same uncovered backdrop during cold wait and native admission")
        let cards=workbench.detail.verificationCloseThreeCards
        observations.append(["phase":"fade.start","cards":cards,"state":shell.verificationContentSessionState])
        check(cards>0,"all Normie approval cards are mounted before the first fade frame")
        check(sourceHides == 0,"native admission never hides the Organic base or resets a visible status capsule")
        let phases=["picture.install","native.detach","native.normie-editor","native.normie-layout","native.admission","native.ready-layout"]
        let steps=phases.compactMap {phase in work.first {$0["phase"] as? String == phase}}
        check(steps.count == phases.count,"native content retains explicit editor/layout/admission heavy phases")
        check(zip(steps,steps.dropFirst()).allSatisfy {($0["commit"] as? Int ?? 0)<($1["commit"] as? Int ?? 0)},"picture installation and every heavy native admission phase occupy distinct commit opportunities")
        observations.append(["phase":"prepared","work":work,"sourceHides":sourceHides,"sidebarAtEpoch":sidebarAtEpoch ?? false])
        shell.onTurnCost=nil
        wait(1.8)
        check(workbench.detail.verificationCloseThreeCards == cards,"flight completion never introduces an absent approval rail")
        // Exercise the actual 0.15 s menu route with the same gap at the final native focus commit.
        scene.show("A");rest(false);workbench.detail.composer?.focus()
        ModeFadeCloseTwoVerification.beforeSelectedFocus={
            ModeFadeCloseTwoVerification.beforeSelectedFocus=nil;window.responderGap=true
            DispatchQueue.main.asyncAfter(deadline:.now()+0.016) {window.responderGap=false}
        }
        shell.setMode(.organic);wait(0.15)
        let router=MemberRouter(shell:shell),item=NSMenuItem(title:"B",action:#selector(MemberRouter.member(_:)),keyEquivalent:"2")
        item.target=router;item.tag=1;_=NSApp.sendAction(item.action!,to:item.target,from:item);wait(2.3)
        check(scene.current == "B" && !shell.flight.running,"the .15 s menu command selects B and retires its flight")
        let target=scene.composers.existingComposer(for:"B"),before=target?.text ?? ""
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:window.windowNumber,context:nil,characters:"k",charactersIgnoringModifiers:"k",isARepeat:false,keyCode:40)!
        window.firstResponder?.keyDown(with:event)
        check(window.firstResponder === target?.textView && target?.text != before,"a real native keyDown after the member handover reaches B despite a field-editor gap")
        observations.append(["phase":"member .15","first":window.firstResponder.map {String(describing:type(of:$0))} ?? "nil","shown":scene.current,"flight":shell.flight.running])
        ModeFadeCloseTwoVerification.beforeSelectedFocus=nil
        rest(false);shell.verificationWaitForWarmContent()
        var inspectorEnabled:[Bool]=[]
        let inspectorItem=NSMenuItem(title:"Inspector",action:#selector(WindowShell.toggleInspector(_:)),keyEquivalent:"")
        shell.onTurnCost={phase,_ in if phase == "native.admission" {inspectorEnabled.append(shell.validateUserInterfaceItem(inspectorItem))}}
        shell.setMode(.organic)
        let fadeDeadline=Date(timeIntervalSinceNow:3)
        while shell.verificationContentSessionState["active"] as? Bool != true,Date()<fadeDeadline {wait(0.002)}
        check(inspectorEnabled == [true],"Show Inspector retains the source enabled state until its shared fade begins")
        shell.onTurnCost=nil
        wait(0.055)
        let previousPhase=shell.verificationContentPhase
        var submitEnd=0.0
        shell.onTurnCost={phase,_ in if phase == "flight.submit" {Thread.sleep(forTimeInterval:0.065);submitEnd=CACurrentMediaTime()}}
        shell.setMode(.normie);shell.onTurnCost=nil
        let phase=shell.verificationContentPhase
        check(phase != nil && phase!.beginTime<submitEnd-0.05,"content reversal is submitted before flight reconstruction can consume another display cycle")
        func opacity(_ animation:CAKeyframeAnimation?,at time:Double)->Double {
            guard let animation,let values=animation.values as? [NSNumber],values.count>1 else {return -1}
            let index=min(Double(values.count-1),max(0,(time-animation.beginTime)/animation.duration*Double(values.count-1)))
            let lower=Int(floor(index)),upper=min(values.count-1,lower+1),f=index-Double(lower)
            return values[lower].doubleValue*(1-f)+values[upper].doubleValue*f
        }
        let displayedAt=phase?.beginTime ?? CACurrentMediaTime(),oldAlpha=opacity(previousPhase,at:displayedAt),newAlpha=opacity(phase,at:displayedAt)
        check(abs(oldAlpha-newAlpha)<0.12,"the committed reversal begins at the preceding server phase before a 65 ms flight block")
        observations.append(["phase":"turn","submitEnd":submitEnd,"beginTime":phase?.beginTime ?? -1,"displayedAt":displayedAt,"oldAlpha":oldAlpha,"newAlpha":newAlpha,"state":shell.verificationContentSessionState])
        wait(2)
        // Hold the endpoint fence so a late return is still a live flight when the next key arrives.
        rest(false);shell.verificationWaitForWarmContent()
        let nativeFence=shell.flight.destinationOwnerVisible
        shell.flight.destinationOwnerVisible={_ in false}
        shell.setMode(.organic);wait(0.95);shell.setMode(.normie)
        let endpointDeadline=Date(timeIntervalSinceNow:1)
        while shell.verificationFlightPresentation["admittedOrganic"] != false,Date()<endpointDeadline {wait(0.003)}
        check(shell.verificationContentSessionState["active"] as? Bool == true && shell.flight.running,"late-turn fixture retains its completed picture endpoint and pending flight fence")
        var insideKey=false,mountInsideKey=false
        shell.onTurnCost={phase,_ in if insideKey,phase == "native.mount" {mountInsideKey=true}}
        insideKey=true;shell.setMode(.organic);insideKey=false;shell.onTurnCost=nil
        check(!mountInsideKey,"a late key never migrates native content in the same frame as flight submission")
        shell.flight.destinationOwnerVisible=nativeFence;shell.flight.destinationDidMount();wait(2)
        // A store publication can precede the source's next display cycle. Freeze the displayed
        // prefix, then cancel a cold opening; the ordinary catchup clock owns the accumulated tail.
        rest(false)
        if let c=workbench.selectedConversation,let native=sessions.existingTranscript(for:c.id) {
            native.refresh(allowHidden:true)
            let rendered=native.verificationModeText
            c.items[c.items.count-1].text += String(repeating:" pending",count:40);store.changed(c)
            sessions.beginModeContentEpoch(store.conversations)
            check(native.verificationModeText == rendered,"a new epoch starts at the rendered prefix rather than the unpresented store tail")
            native.verificationManualModeCatchup=true;sessions.endModeContentEpoch()
            let before=native.verificationModeText.joined().count;native.verificationModeCatchupStep()
            check(native.verificationModeText.joined().count-before<=8,"an abandoned source freeze replays at most one normal stream packet per frame")
            native.verificationManualModeCatchup=false
        } else {check(false,"rendered-prefix fixture has its actual source transcript")}
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"observations":observations,"visible":window.isVisible],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fade-close3.json"))
        print("Fade close three: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    @MainActor private final class MemberRouter:NSObject {
        let shell:WindowShell
        init(shell:WindowShell) {self.shell=shell}
        @objc func member(_ sender:NSMenuItem) {shell.selectModeMember(at:sender.tag)}
    }
}
#endif
