#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Native owner regressions exercise real admission, shared views and a never-ordered window.
@MainActor enum ModeFlightRoundTwelveVerification {
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],states:[[String:Any]]=[]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false);let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=root.bounds;root.addSubview(plane)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic)
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentViewController=shell
        window.toolbar=NSToolbar(identifier:"round12.hidden");window.contentView?.superview?.layoutSubtreeIfNeeded()
        defer {shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
        func rest(_ organic:Bool) {shell.flight.cancel();shell.verificationFlightSettle(asOrganic:organic);shell.verificationRepairRest(organic ? .organic:.normie)}
        func record(_ label:String) {var state=shell.verificationNativeOwnerState;state["stage"]=label;states.append(state)}
        func owned(_ organic:Bool)->Bool {
            let value=shell.verificationNativeOwnerState
            return value["admitted"] as? String == (organic ? "organic":"normie") && value["normieHidden"] as? Bool == organic && value["organicHidden"] as? Bool == !organic
        }
        rest(false);record("initial.completeNormie")
        shell.prepareModeSwitch(reason:"round12.orphan")
        shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit();record("normal.organicAdmission")
        check(owned(true),"P0 normal admission publishes symmetric native root visibility")
        now+=0.08;shell.flight.advance(at:0.08);shell.verificationFlightToggle(toOrganic:false)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        now+=0.04;shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit();record("doubleTurn.returnOrganic")
        check(owned(true),"P0 already-admitted Organic cannot leave an opaque Normie shell in front")
        if let native=sessions.existingTranscript(for:scene.current) {check(native.isDescendant(of:root),"P0 selected transcript remains in the Organic owner after the double turn")}
        else {check(false,"P0 selected transcript exists")}
        let composer=scene.composers.existingComposer(for:scene.current)
        check(composer?.isDescendant(of:root) == true,"P0 selected composer belongs to the same Organic owner")
        check(!shell.verificationToolbarExposed,"P0 already-admitted Organic repairs toolbar ownership")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.3));record("doubleTurn.afterOldCompletions")
        check(owned(true),"P0 obsolete fade completions cannot restore the abandoned root")
        // A real terminal field editor begins IME after the opening command, before Native admission.
        rest(false);workbench.setTerminalShown(true,animated:false);shell.prepareModeSwitch(reason:"round12.guard")
        let native=sessions.existingTranscript(for:workbench.selectedConversation?.id ?? ""),previousHost=native?.superview
        shell.verificationFlightToggle(toOrganic:true)
        let field=workbench.detail.terminalPane.inputField
        window.makeFirstResponder(field)
        let editor=field.currentEditor() as? NSTextView
        editor?.setMarkedText("guard",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        check(workbench.detail.terminalPane.isComposing,"P0 fixture starts actual terminal IME between opening and admission")
        shell.verificationFlightAdmit();record("rejected.organicAdmission")
        check(owned(false),"P0 rejected Native commit preserves admitted Normie and its complete roots")
        check(native?.superview === previousHost && native?.isDescendant(of:shell.split.view) == true,"P0 rejected Native commit leaves the shared transcript with its original owner")
        check(shell.verificationToolbarExposed,"P0 rejected Native commit retains Normie chrome")
        editor?.unmarkText();window.makeFirstResponder(nil);workbench.setTerminalShown(false,animated:false)
        // The same destination is fully exposed along its ancestor chain, but a sibling root covers it.
        rest(true);window.contentView?.superview?.layoutSubtreeIfNeeded();CATransaction.flush()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
        if let column=scene.columns.first,let orb=column.island?.orb {
            let id="header."+column.conversation.id,real=M10SidebarExposure.presentedRect(orb.glassView,in:shell.view)
            shell.flight.start(toOrganic:true,avatar:(ModeOrreryFlightVerification.sidebarAvatar,scene.meRest),initials:"LL",tokens:[.init(id:id,conversation:column.conversation,from:CGRect(x:30,y:160,width:32,height:32),to:real,start:0,absorbed:false)],composer:nil,reduceMotion:false)
            shell.flight.onFrame={t in shell.verificationPublishFlightOwners(at:t)}
            shell.verificationCoverBody(true)
            let blockedTime=shell.flight.duration+0.02
            now+=blockedTime;shell.flight.advance(at:blockedTime);record("sibling.coveringOrganic")
            check(!shell.verificationEndpointOwner(id),"P4 a visible sibling Normie root blocks Organic endpoint ownership")
            check(shell.flight.verificationHeldConversationIDs.contains(column.conversation.id),"P4 the last carrier survives while its native endpoint is covered")
            shell.verificationCoverBody(false);CATransaction.flush()
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
            check(shell.verificationEndpointOwner(id),"P4 the real endpoint becomes eligible once its covering sibling is hidden")
            shell.flight.destinationDidMount();now+=0.1;shell.flight.advance(at:blockedTime+0.1)
            now+=0.05;shell.flight.advance(at:blockedTime+0.15)
            check(!shell.flight.verificationHeldConversationIDs.contains(column.conversation.id),"P4 the existing exposure fence retires the carrier after the covering sibling disappears")
        } else {check(false,"P4 real header fixture exists")}
        // The same system sidebar wrapper carries both glass and text through repeated commands and layout.
        rest(false)
        let stableHost=shell.verificationNativeSidebarHost,stableParent=stableHost?.superview,stableSurface=workbench.sidebar.view
        func glass(_ view:NSView)->NSGlassEffectView? {
            if let glass=view as? NSGlassEffectView {return glass}
            for child in view.subviews {if let found=glass(child) {return found}}
            return nil
        }
        let stableGlass=stableHost.flatMap(glass)
        check(stableHost != nil && stableGlass != nil,"P3 the moving surface is the original system sidebar item, not a proxy")
        var maximumRowOffsetError=0.0,allParentsStable=true,allAlphaShared=true,noProxy=true
        func innerAlpha(_ node:NSView,under host:NSView)->Float {
            var current:NSView?=node,result:Float=1
            while let view=current,view !== host {result *= view.layer?.opacity ?? Float(view.alphaValue);current=view.superview}
            return current === host ? result:-1
        }
        shell.prepareModeSwitch(reason:"round12.nativeSidebar")
        for turn in 0..<20 {
            shell.verificationFlightToggle(toOrganic:turn%2 == 0)
            if turn == 5 || turn == 12 {
                window.setContentSize(CGSize(width:turn == 5 ? 1400:1180,height:turn == 5 ? 940:790))
                window.contentView?.superview?.layoutSubtreeIfNeeded();shell.viewDidLayout()
            }
            let pause=turn<10 ? 0.12:0.3
            RunLoop.main.run(until:Date(timeIntervalSinceNow:pause));now+=pause;shell.flight.advance(at:shell.flight.elapsed)
            allParentsStable = allParentsStable && shell.verificationNativeSidebarHost === stableHost && stableHost?.superview === stableParent && workbench.sidebar.view === stableSurface
            noProxy = noProxy && !shell.verificationHasSidebarProxy
            if let host=stableHost,let material=stableGlass {
                allParentsStable = allParentsStable && glass(host) === material && material.isDescendant(of:host) && stableSurface.isDescendant(of:host)
                allAlphaShared = allAlphaShared && abs(innerAlpha(material,under:host)-innerAlpha(stableSurface,under:host))<0.0001
                let layer=host.layer!,mediaTime=CACurrentMediaTime()
                let expected:CGFloat
                // Compare both clocks at the same timestamp. A cached presentation may belong to the preceding vsync.
                if let group=layer.animation(forKey:"mode.turn.sidebar") as? CAAnimationGroup,
                   let move=group.animations?.compactMap({$0 as? CABasicAnimation}).first(where:{$0.keyPath == "transform.translation.x"}) {
                    let a=(move.fromValue as? NSNumber)?.doubleValue ?? 0,b=(move.toValue as? NSNumber)?.doubleValue ?? 0
                    var first:[Float]=[0,0],second:[Float]=[1,1]
                    group.timingFunction?.getControlPoint(at:1,values:&first)
                    group.timingFunction?.getControlPoint(at:2,values:&second)
                    expected=CGFloat(a+(b-a)*ModeOrreryFlight.bezier(Double(first[0]),Double(first[1]),Double(second[0]),Double(second[1]),(mediaTime-group.beginTime)/group.duration))
                } else {expected=CGFloat(layer.value(forKeyPath:"transform.translation.x") as? NSNumber ?? 0)}
                maximumRowOffsetError=max(maximumRowOffsetError,abs(Double((shell.flight.rowSidebarOffset?(mediaTime) ?? 0)-expected)))
            }
        }
        shell.verificationFlightAdmit();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.3))
        check(allParentsStable,"P3 glass, content and moving host keep their exact identities and parents through twenty turns and resize")
        check(allAlphaShared,"P3 material and text have the same native ancestor opacity with no independent proxy alpha")
        check(noProxy,"P3 no sidebar bitmap or material proxy ever enters the window tree")
        check(maximumRowOffsetError<0.5,"P3 row ink uses the native host's displayed translation: \(maximumRowOffsetError)pt")
        check(stableGlass?.isDescendant(of:stableHost ?? NSView()) == true,"P3 the settled surface is the same system material after the last boundary")
        check(!NSApp.windows.contains(where:{$0.isVisible}),"P0/P3/P4 all real NSWindows remain hidden")

        let result:[String:Any]=["checks":checks,"findings":failures.count,"failures":failures,"states":states,"maximumRowOffsetError":maximumRowOffsetError]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round12-verification.json"))
        print("M11.31 round 12: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
}
#endif
