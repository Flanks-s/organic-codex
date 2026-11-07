#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Real split/layout/leases in an NSWindow that is never ordered. No App or input driver is launched.
@MainActor enum ModeFadeClosureVerification {
    static func run(to output:URL,performance:Bool=false) throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:],states:[[String:Any]]=[]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        func wait(_ t:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:t))}
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false);for c in store.conversations {c.running=false;c.sending=false;c.loading=false}
        let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle = !performance
        let organic=RootView(frame:CGRect(origin:.zero,size:size));organic.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=organic.bounds;organic.addSubview(plane)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:organic,scene:scene,workbench:workbench,mode:.organic)
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentViewController=shell
        shell.installToolbar(in:window);window.contentView?.superview?.layoutSubtreeIfNeeded()
        let defaults=UserDefaults.standard,key="toggle.simulateReduceMotion",saved=defaults.object(forKey:key)
        defaults.set(false,forKey:key)
        defer {
            if let saved {defaults.set(saved,forKey:key)} else {defaults.removeObject(forKey:key)}
            shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()
        }
        let simulatedHz=Double(ProcessInfo.processInfo.environment["M1131_SIM_HZ"] ?? "") ?? 120
        let driver=Timer(timeInterval:1/simulatedHz,repeats:true) {_ in MainActor.assumeIsolated {
            let now=CACurrentMediaTime()
            if performance {scene.frame(now)}
            else {
                // manualSettle pins column geometry, not the Dock's real editing/hover spring.
                // Sample that native owner before asking the flight to match its current lift.
                scene.dock.frame(at:now,elapsed:.infinity)
            }
            if shell.flight.running {shell.flight.verificationDisplayAdvance(at:shell.flight.elapsed)}
        }}
        RunLoop.main.add(driver,forMode:.common);defer {driver.invalidate()}
        func rest(_ value:Bool) {
            shell.settlePendingMode();shell.flight.cancel();shell.flight.manualTime=nil
            shell.verificationFlightSettle(asOrganic:value);shell.verificationRepairRest(value ? .organic:.normie)
            scene.settle();window.contentView?.superview?.layoutSubtreeIfNeeded();shell.verificationForgetContentCandidate()
        }
        func sample(_ label:String) {var s=shell.verificationFadeClosureState;s["label"]=label;states.append(s)}
        func shown()->String {shell.mode == .normie ? workbench.selectedConversation?.id ?? "":scene.current}
        func composer()->NativeComposer? {shell.mode == .normie ? workbench.detail.composer:scene.composers.existingComposer(for:scene.current)}
        func checkTyping(_ label:String) {
            let c=composer(),before=c?.text ?? "",responder=window.firstResponder
            check(c != nil && responder === c?.textView,"focus belongs to the displayed composer: "+label)
            if let text=responder as? NSTextView {text.insertText("x",replacementRange:text.selectedRange())}
            check(c?.text != before,"typing reaches the actual first responder: "+label)
        }
        if performance {
            let kind=ProcessInfo.processInfo.environment["M1131_PERF_KIND"] ?? "stream"
            let quiet=kind.contains("quiet"),burst=kind.contains("burst")
            rest(true)
            if !quiet {for id in ["A","D"] {store.conversation(id)?.running=true};seed.start(live:true)}
            // OrganicWindow's initial idle geometry preparation runs before InputRun's first key.
            // Hidden windows do not receive that visible-window idle observer; drive only that same
            // geometry preparation explicitly, without taking a warm picture during streaming.
            shell.verificationWarmGeometryForClosure();wait(quiet ? 1.8:0.05)
            let meter=ModeFlightRoundThirteenVerification.Meter();var stalls:[[String:Double]]=[]
            meter.onGap={start,end in if end-start>0.05 {stalls.append(["began":start,"end":end,"ms":(end-start)*1000])}}
            ModeSignposts.receiptsEnabled=true;meter.start()
            var keys:[[String:Any]]=[],work:[[String:Any]]=[]
            shell.onTurnCost={phase,ms in work.append(["key":keys.count,"phase":phase,"ms":ms,"ended":CACurrentMediaTime()])}
            func press(_ label:String) {
                let start=CACurrentMediaTime(),target:WindowShell.Mode=shell.mode == .normie ? .organic:.normie
                shell.setMode(target)
                keys.append(["label":label,"at":start,"to":target.rawValue,"commandMS":(CACurrentMediaTime()-start)*1000])
            }
            press("initial to normie");wait(2.3)
            if burst {
                for gap in [0.12,0.3] {
                    for index in 0..<10 {press("burst \(gap) \(index)");wait(gap)}
                    wait(2.3)
                    if shell.mode != .normie {press("burst settle");wait(2.3)}
                }
            } else {
            press("forward");wait(2.3);press("reverse");wait(2.3)
            for ms in [80,280,540,950,1300] {
                press("f go");wait(Double(ms)/1000);press("f back");wait(2.3)
                press("to organic");wait(2.3)
                press("r go");wait(Double(ms)/1000);press("r back");wait(2.3)
                press("to normie");wait(2.3)
            }
            press("toggle go");wait(0.54);press("toggle back");wait(0.04);press("toggle again");wait(2.3)
            press("end");wait(2.3)
            }
            meter.stop();seed.stopPlayback();shell.onTurnCost=nil
            let maximum=meter.intervals.max() ?? 0,over=meter.intervals.filter {$0>50}.count
            check(keys.count == (burst ? 21:37),"performance driver includes every key in the requested scene")
            check(maximum <= (burst ? 106:82) && over <= (burst ? 6:29),"mode performance stays inside the MBP submission limits")
            check(!shell.flight.running && shell.mode == .normie,"streaming mode-orrery ends with settled Normie")
            try JSONSerialization.data(withJSONObject:["kind":kind,"manualSettle":scene.manualSettle,"sceneFramesDriven":true,"checks":checks,"findings":failures.count,"failures":failures,"keys":keys,"work":work,"stalls":stalls,"receipt":ModeSignposts.receipt,"maximumGapMS":maximum,"over50":over,"captures":shell.verificationContentCaptureCosts,"fadeLatencies":shell.verificationContentFadeLatencies,"firstSubmitMS":shell.verificationRound14State["firstSubmitMS"] ?? []],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fade-performance.json"))
            print("Fade streaming performance: \(keys.count) keys, max \(maximum) ms, over50 \(over), findings \(failures.count)")
            return failures.isEmpty ? 0:1
        }
        // Cold wait keeps the complete source composer/ink together. There is no legacy empty-glass flight.
        rest(false);shell.verificationWarmGeometryForClosure();workbench.detail.composer?.focus()
        shell.flight.verificationDropPreparedResources() // Preserve all production callbacks while forcing a cold allocation.
        let bakesBefore=ModeFlightGlyphStage.verificationInkRasterizationCount
        var coldCaptures:[String]=[]
        NativeViewBitmap.verificationCaptureObserver={coldCaptures.append(String(describing:type(of:$0)))}
        shell.setMode(.organic)
        NativeViewBitmap.verificationCaptureObserver=nil
        let inspector=NSToolbarItem(itemIdentifier:.toggleInspector);inspector.action=NSSelectorFromString("toggleInspector:")
        check(shell.validateToolbarItem(inspector),"Show Inspector keeps the displayed Normie enabled state during the cold wait")
        check(coldCaptures.isEmpty,"the first flight command performs no NSView glyph snapshot on a cache miss")
        check(ModeFlightGlyphStage.verificationInkRasterizationCount == bakesBefore,"the cold key performs zero glyph rasterization, including small CGContext work")
        facts["inkAtlas"]=ModeFlightGlyphStage.verificationInkAtlas
        facts["coldKeyCaptureViews"]=coldCaptures
        facts["tripEligible"]=shell.verificationClosureTripEligible
        for delay in [0.0,0.04,0.06,0.05] {
            wait(delay);sample("cold.wait")
            let state=shell.verificationFadeClosureState
            check(state["composerFlight"] as? Bool == false,"empty composer glass never flies independently of its ink")
            if state["opening"] as? Bool == true {check((state["materialAlpha"] as? CGFloat ?? 0)>0.999,"cold wait retains native composer glass under its ink")}
        }
        wait(2.3);check(!shell.flight.running,"cold forward flight terminates")
        checkTyping("cold forward")
        rest(false);shell.verificationDropFlightPreparation();shell.setMode(.organic);shell.verificationFlightAdmit()
        check(shell.verificationColdAdmissionReadiness.last == true,"cold native admission consumes a completely prepared target instead of a synchronous fallback")
        wait(2.1)
        // A source Pulse remains the same native surface until its content curtain has covered it.
        rest(true)
        if let c=store.conversation(scene.current),let header=scene.columns.first(where:{$0.conversation.id == c.id})?.island {
            store.apply(.init(id:900001,time:nil,method:"turn/started",params:["threadId":.string(c.id),"turn":["id":"closure-pulse"]]))
            scene.changed(c);scene.restIslands();header.sampleMotion(at:CACurrentMediaTime()+0.6)
            let before=header.pulseProbe
            check(before != nil,"header fixture has a visible status capsule before taking its source picture")
            shell.setMode(.normie);shell.verificationFlightAdmit()
            check(header.pulseProbe != nil,"cold O→N admission does not replace the source status capsule with the title form")
            shell.settlePendingMode();c.running=false
        } else {check(false,"header fixture has a retained native island")}
        // The exact production menu sequence: during capture and after native admission, in both directions.
        var selectionRows:[[String:Any]]=[]
        for (initial,delay,index) in [(false,0.15,1),(true,0.15,2),(false,0.9,3),(true,0.9,0)] {
            rest(initial)
            let focused=initial ? scene.composers.existingComposer(for:scene.current):workbench.detail.composer
            focused?.focus();let target:WindowShell.Mode=initial ? .normie:.organic
            shell.setMode(target);wait(delay)
            let ids=scene.order;guard ids.indices.contains(index) else {check(false,"selection fixture has four members");continue}
            let id=ids[index];shell.verificationFadeMember(id);wait(2.4)
            sample("select.\(target.rawValue).\(delay)")
            selectionRows.append(["mode":target.rawValue,"at":delay,"expected":id,"shown":shown(),"running":shell.flight.running])
            check(shown() == id,"member intent survives capture/admission: \(target.rawValue) \(delay)")
            check(!shell.flight.running,"member command leaves no running flight")
            checkTyping("member \(target.rawValue) \(delay)")
        }
        facts["mode-select"]=selectionRows
        // Enable Reduce Motion inside an active photo session, then reverse and alternate exactly as the driver does.
        rest(false);workbench.detail.composer?.focus();shell.setMode(.organic);wait(0.3);defaults.set(true,forKey:key)
        shell.setMode(.normie);wait(0.3);sample("reduce.turn")
        for target in [WindowShell.Mode.organic,.normie,.organic] {
            shell.setMode(target);wait(0.15);sample("reduce.\(target.rawValue)")
            let state=shell.verificationFadeClosureState
            check(shell.mode == target && !shell.flight.running,"Reduce Motion lands in the requested mode without a flight")
            check(state["session"] as? Bool == false && state["opening"] as? Bool == false && state["epoch"] as? Bool == false && state["gate"] as? Bool == false,"Reduce Motion leaves exactly one settled switch state")
            check(state["focusConversation"] as? String == "none","Reduce Motion cannot reuse a stale focus identity")
            checkTyping("reduce \(target.rawValue)")
        }
        defaults.set(false,forKey:key);shell.setMode(.normie);wait(2.4);sample("reduce.off")
        check(shell.mode == .normie && !shell.flight.running,"turning Reduce Motion off restores the normal production flight")
        checkTyping("reduce off")
        var modeType:[[String:Any]]=[]
        func typeCase(_ name:String) {
            let target=composer(),before=target?.text ?? "",responder=window.firstResponder
            if let text=responder as? NSTextView {text.insertText("mode-type",replacementRange:text.selectedRange())}
            let ok=target != nil && target?.text != before && responder === target?.textView
            check(ok,"mode-type "+name);modeType.append(["label":name,"ok":ok])
        }
        rest(false);workbench.detail.composer?.focus();typeCase("a")
        shell.setMode(.organic);wait(2.3);scene.composers.existingComposer(for:scene.current)?.focus();typeCase("c")
        shell.setMode(.normie);wait(2.3);typeCase("e")
        shell.setMode(.organic);wait(2.3);typeCase("f")
        shell.setMode(.normie);wait(0.28);shell.setMode(.organic);wait(2.3);typeCase("g")
        shell.setMode(.normie);wait(2.3);typeCase("h")
        shell.setMode(.organic);wait(0.28);shell.setMode(.normie);wait(2.3);typeCase("i")
        facts["mode-type"]=modeType
        // A late O→N reversal must attenuate the real Dock bars with the same phase, not a second retirement clock.
        for initial in [false,true] {for turn in [1.011,1.297] {
            rest(initial);(initial ? scene.composers.existingComposer(for:scene.current):workbench.detail.composer)?.focus()
            shell.setMode(initial ? .normie:.organic);wait(turn);shell.setMode(initial ? .organic:.normie);wait(0.03)
            check(shell.verificationClosureSidebarCutout != nil,"the opaque body/photo excludes the resident sidebar backdrop")
            let bars=shell.verificationFadeDockBars
            if !initial {check(!bars.isEmpty,"PhotoN's upper Dock bars have the body-phase owner after late reversal")}
            else {check(scene.dockView.layer?.mask == nil,"LiveN covers the Dock exactly once, with no second attenuation")}
            for bar in initial ? []:bars {
                let phase=bar.animation(forKey:"mode.content.phase") as? CAKeyframeAnimation
                check(phase != nil && phase?.keyPath == "opacity","bar material and ink share the reversible body opacity clock")
            }
            wait(2.2);check(!shell.flight.running,"late reversal finishes its carriers")
        }}
        // Full WindowShell freeze -> native handoff -> catchup -> subsequent live delta, with tail intent intact.
        for initial in [false,true] {
            rest(initial)
            guard let c=store.conversation(scene.current),let native=sessions.existingTranscript(for:c.id) else {check(false,"tail fixture has a retained viewport");continue}
            native.scrollToEnd();c.running=true
            shell.setMode(initial ? .normie:.organic);wait(0.1)
            if let last=c.items.indices.last {c.items[last].text += String(repeating:"stream tail\n",count:32)}
            store.changed(c);wait(2.4)
            let catchupDeadline=Date(timeIntervalSinceNow:Double("stream tail\n".count*32)/8*native.verificationModeReplayInterval+0.75)
            while native.modeContentIsCatchingUp,Date()<catchupDeadline {wait(0.02)}
            check(!native.modeContentIsCatchingUp && native.readerFollowsEnd && native.isAtEnd,"complete mode handoff and catchup retain tail following")
            if let last=c.items.indices.last {c.items[last].text += "next normal packet\n"};store.changed(c);wait(0.1)
            check(native.readerFollowsEnd && native.isAtEnd,"normal streaming after catchup still follows the latest line")
            c.running=false
        }
        // Two viewports in one window cannot each spend a full packet budget in the same cycle.
        let catchups=(0..<2).map {i -> NativeTranscript in
            let c=Conversation(id:"closure.packet.\(i)",title:"Packets")
            c.items=[TranscriptItem(id:"packet",kind:.assistant,text:"start ",running:true)];c.running=true
            let native=NativeTranscript(conversation:c);native.frame=CGRect(x:300,y:50,width:400,height:180)
            shell.view.addSubview(native);native.refresh(allowHidden:true);native.beginModeContentEpoch()
            c.items[0].text += String(repeating:"packet ",count:40);c.revision+=1;native.endModeContentEpoch();return native
        }
        wait(0.45)
        let packets=catchups.flatMap(\.verificationModeCatchupPackets).sorted {$0[0]<$1[0]}
        let interval=window.screen.map {DisplayProfile.of($0).frameInterval} ?? 1/60
        var frameBudgets:[Int:Double]=[:]
        for packet in packets {
            let frame=packet.count>2 ? Int(packet[2]):Int(floor(packet[0]/interval))
            frameBudgets[frame,default:0]+=packet[1]
        }
        check(packets.count>=3 && packets.allSatisfy {$0[1]<=8},"catchup uses bounded native stream packets")
        check(frameBudgets.values.allSatisfy {$0<=8},"split viewports share a display cycle instead of firing parallel 120 Hz callbacks")
        facts["catchupPackets"]=packets;catchups.forEach {$0.dispose();$0.removeFromSuperview()}
        rest(false)
        shell.verificationAfterPictureJoin={
            shell.verificationAfterPictureJoin=nil
            window.setContentSize(CGSize(width:1111,height:777));shell.viewDidLayout()
        }
        shell.setMode(.organic);wait(1.3)
        check(shell.mode == .normie && shell.verificationComparisonState["photo"] as? Bool == false && !shell.flight.running,"a worker result invalidated by resize keeps the complete source owner instead of publishing stale pixels")
        window.setContentSize(size);scene.resize(to:size,live:false);window.contentView?.superview?.layoutSubtreeIfNeeded()
        facts["captures"]=shell.verificationContentCaptureCosts;facts["work"]=shell.verificationContentWorkCosts
        facts["fadeLatencies"]=shell.verificationContentFadeLatencies;facts["firstSubmitMS"]=shell.verificationRound14State["firstSubmitMS"]
        check(!window.isVisible,"the complete split NSWindow is never displayed")
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"states":states,"facts":facts],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fade-closure.json"))
        print("M11.31 fade closure: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
}
#endif
