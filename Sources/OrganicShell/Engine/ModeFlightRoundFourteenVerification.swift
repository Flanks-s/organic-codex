#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Real, never-ordered windows exercise split layout, responder identity and production flight retirement.
@MainActor enum ModeFlightRoundFourteenVerification {
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:],states:[[String:Any]]=[]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        func wait(_ seconds:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:seconds))}
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
        shell.installToolbar(in:window);window.contentView?.superview?.layoutSubtreeIfNeeded()
        defer {shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        func rest(_ organic:Bool) {shell.flight.cancel();shell.verificationFlightSettle(asOrganic:organic);shell.verificationRepairRest(organic ? .organic:.normie);window.contentView?.superview?.layoutSubtreeIfNeeded()}
        func prepare() {
            // A faster picture is not evidence that the independent idle geometry/token batch has finished.
            shell.verificationWarmGeometryForClosure();shell.verificationWaitForWarmContent()
        }
        var widths:[Double]=[],firstSubmits:[String:Double]=[:],firstWork:[String:[String]]=[:]
        ModeSignposts.receiptsEnabled=true
        for initialOrganic in [false,true] {
            rest(initialOrganic);prepare();if !initialOrganic {facts["chromeTree"]=shell.verificationChromeTree}
            let host=shell.verificationNativeSidebarHost,width=host?.bounds.width ?? 0,parent=host?.superview
            let composer=initialOrganic ? scene.composers.existingComposer(for:scene.current):workbench.detail.composer
            composer?.focus();let responder=window.firstResponder
            let trace=ModeSignposts.Trace(),workIndex=shell.verificationContentWorkCosts.count
            ModeSignposts.withTrace(trace) {shell.verificationFlightToggle(toOrganic:!initialOrganic)}
            firstWork[initialOrganic ? "organic-to-normie":"normie-to-organic"]=shell.verificationContentWorkCosts.dropFirst(workIndex).compactMap {$0["phase"] as? String}
            firstSubmits[initialOrganic ? "organic-to-normie":"normie-to-organic"]=(shell.verificationRound14State["firstSubmitMS"] as? [Double])?.last ?? -1
            shell.verificationFlightAdmit()
            for frame in 0..<28 {
                wait(0.012);window.contentView?.superview?.layoutSubtreeIfNeeded()
                let current=host?.bounds.width ?? 0;widths.append(Double(current))
                check(abs(current-width)<0.5 && current<=NormieSidebarMetrics.maximumWidth,"6 every native commit retains the sidebar allocation \(initialOrganic) \(frame)")
                check(host === shell.verificationNativeSidebarHost && host?.superview === parent,"6 split item identity and layout engine remain fixed")
            }
            check(shell.verificationChromePhase != nil,"8 the native toolbar shares the fixed smoothstep clock")
            check(window.firstResponder === responder,"3 shared native editor keeps the actual responder after admission")
            if let composer {let text=composer.text;composer.textView.insertText(" mode-type",replacementRange:composer.textView.selectedRange());check(composer.text.contains("mode-type") && composer.text != text,"3 immediate typing reaches the original editor while its picture session is active")}
            shell.verificationFlightToggle(toOrganic:initialOrganic);wait(0.26)
            check(window.firstResponder === responder,"3 reversal restores the same editor, not scene.current by inference")
            let search=workbench.sidebar.searchField;window.makeFirstResponder(search)
            wait(0.26)
            check(window.firstResponder === search || search.currentEditor() === window.firstResponder,"3 a later Search focus intent survives endpoint callbacks")
            shell.settlePendingMode();check(!shell.modeContentInputBlocked,"10 explicit collapse settlement releases the epoch and lease shield")
            states.append(shell.verificationRound14State)
        }
        rest(true);shell.verificationDropFlightPreparation()
        shell.verificationFlightToggle(toOrganic:false)
        let pendingSearch=workbench.sidebar.searchField;workbench.perform(.search)
        shell.verificationFlightAdmit()
        check(window.firstResponder === pendingSearch || pendingSearch.currentEditor() === window.firstResponder,"3 Search focus requested before cold admission is not overwritten")
        shell.settlePendingMode()
        // The actual responder can belong to the other Split member, or to the one retained draft.
        rest(true);scene.enterFocused(scene.current,reason:"round14.focus");scene.settle();scene.splitWithNext();scene.settle()
        if let identity=scene.scheme.split.first(where:{$0 != scene.current}),let editor=scene.composers.existingComposer(for:identity) {
            editor.focus();let responder=window.firstResponder
            shell.verificationFlightToggle(toOrganic:false);shell.verificationFlightAdmit()
            check(window.firstResponder === responder && workbench.selectedConversation?.id == identity,"3 Split handoff follows the editor being edited, including the other segment")
            shell.settlePendingMode()
        } else {check(false,"3 Split fixture exposes a second retained editor")}
        scene.leaveFocused(reason:"round14.focus.end");scene.settle();rest(false)
        _=workbench.newChat();let draft=workbench.detail.composer;draft?.focus();let draftResponder=window.firstResponder
        shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit()
        check(window.firstResponder === draftResponder && draft?.identity == nil,"3 the unbound draft retains its editor identity across admission")
        if let draft {
            draft.textView.setMarkedText("marked",selectedRange:NSRange(location:6,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            let owner=window.firstResponder,previousMode=shell.mode;shell.setMode(.normie)
            check(window.firstResponder === owner && draft.textView.hasMarkedText() && shell.mode == previousMode,"3 an IME transition never replaces the responder or marked text")
            draft.textView.unmarkText()
        }
        shell.settlePendingMode();scene.cancelNewChat();scene.settle();_ = workbench.cancelNewChat();rest(false)

        // Stream while no command is pending: invalidation must never schedule standing bitmap work.
        rest(false);shell.startModePreparation();let count=shell.verificationContentCaptureCosts.count
        let model=store.conversations[0];model.running=true
        for _ in 0..<8 {model.items[model.items.count-1].text += " delta";store.changed(model);wait(0.13)}
        check(shell.verificationContentCaptureCosts.count == count && !shell.verificationContentCapturing,"2 continuous streaming causes zero background warm captures")
        model.running=false;store.changed(model)
        // The native endpoint must release a real flight via advance -> finish, without cancel().
        rest(false);prepare();shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit()
        // The flight is fast-forwarded below; its independent resident sidebar must first cross its real 0.60 s clock.
        wait(0.65)
        for i in 0..<5 {shell.flight.advance(at:shell.flight.duration+Double(i)*0.10);wait(0.03)}
        states.append(shell.verificationRound14State)
        if shell.flight.running {facts["retirementRows"]=shell.verificationRowDiagnostics;facts["retirementFlight"]=shell.flight.verificationOrreryState(at:shell.flight.ownerTime)}
        check(!shell.flight.running,"9 complete native endpoints finish the production flight without cancellation")
        let oldID=shell.verificationContentSessionState["sessionID"] as? String
        shell.verificationFlightToggle(toOrganic:false);shell.verificationFlightAdmit()
        let nextID=shell.verificationContentSessionState["sessionID"] as? String
        check(oldID == nil && nextID != nil,"9 the next landed command opens a fresh picture session")
        // A fresh, immutable two-times picture is joined on a worker; batches are separated by frame deadlines.
        shell.settlePendingMode();rest(false);shell.verificationPrepareContentPicture()
        let deadline=Date(timeIntervalSinceNow:4)
        while shell.verificationContentCapturing,Date()<deadline {wait(0.002)}
        if let capture=shell.verificationContentCaptureCosts.last {
            check(capture["scale"] as? CGFloat == 2,"5 default picture resolution is the native two-times scale")
            let costs=capture["slicesMS"] as? [Double] ?? [],times=capture["sliceTimes"] as? [Double] ?? []
            check(!costs.isEmpty && (costs.max() ?? 0)<=7.5,"4 measured cold draw batches fit a six millisecond adaptive budget plus one indivisible draw margin")
            let intervals=capture["sliceIntervals"] as? [Double] ?? Array(repeating:shell.flight.presentationInterval,count:times.count)
            check(zip(times.indices.dropLast(),zip(times,times.dropFirst())).allSatisfy {index,pair in pair.1-pair.0>=intervals[index]*0.9},"4 separate capture batches cross their sampled display deadlines")
            facts["capture"]=capture
        } else {check(false,"4 a complete cold picture is available")}
        // The hidden window has a production advance driver; no test cancels or fast-forwards these twenty keys.
        var burstFacts:[[String:Any]]=[]
        for startsOrganic in [false,true] {
            rest(startsOrganic);prepare()
            let meter=ModeFlightRoundThirteenVerification.Meter();meter.start()
            let driver=Timer(timeInterval:1/120,repeats:true) { _ in MainActor.assumeIsolated {
                if shell.flight.running {shell.flight.advance(at:shell.flight.elapsed)}
            }}
            RunLoop.main.add(driver,forMode:.common)
            let startIndex=shell.verificationContentWorkCosts.count
            for command in 0..<20 {
                shell.verificationFlightToggle(toOrganic:command%2 == 0 ? !startsOrganic:startsOrganic)
                wait(command<10 ? 0.120:0.300)
            }
            wait(2);driver.invalidate();meter.stop()
            let peak=meter.intervals.max() ?? 0,over=meter.intervals.filter {$0>50}.count
            burstFacts.append(["startsOrganic":startsOrganic,"maximumMainGapMS":peak,"over50":over,"intervalsMS":meter.intervals,"work":Array(shell.verificationContentWorkCosts.dropFirst(startIndex)),"state":shell.verificationContentSessionState,"flightRunning":shell.flight.running,"queue":ModeContentWorkBoundary.verificationState])
            check(peak<=106 && over<=6,"4 twenty-key main-thread stalls do not exceed HEAD: \(startsOrganic) \(peak) ms / \(over)")
            check(!shell.flight.running && shell.verificationContentSessionState["active"] as? Bool == false,"9 twenty-key production flights and content sessions all converge")
            shell.settlePendingMode()
        }
        facts["bursts"]=burstFacts

        let events=ModeSignposts.receipt["events"] as? [[String:Any]] ?? []
        let key=events.firstIndex {$0["phase"] as? String == "ModeContentKey"} ?? 0
        let submit=events[key...].firstIndex {$0["phase"] as? String == "ModeFlightFirstSubmit"} ?? key
        let workBefore=events[key..<submit].filter {($0["detail"] as? String)?.contains("phase=epoch.freeze") == true || $0["phase"] as? String == "ModePhotoCapture"}
        check(workBefore.isEmpty,"1 no epoch freeze or picture work precedes the first flight submit")
        // Synthetic phase events cannot exhaust receipt capacity; operational events remain present.
        let log=ModeSignposts.Trace()
        for _ in 0..<40000 {log.record("ModeOrbFrame",detail:"planet")};log.record("Round14End")
        check((ModeSignposts.receipt["events"] as? [[String:Any]])?.last?["phase"] as? String == "Round14End","12 per-frame orb diagnostics cannot evict a final receipt")
        for (direction,work) in firstWork {check(work.first == "flight.submit","1 first key submits flight before any epoch/native/capture work: \(direction)")}
        for (direction,ms) in firstSubmits {check(ms>=0 && ms<=1000.0/120,"1 first server command fits the next 120 Hz vsync: \(direction) \(ms) ms")}
        facts["firstWorkOrder"]=firstWork;facts["firstSubmitMS"]=firstSubmits;facts["sidebarWidths"]=widths
        facts["workCosts"]=shell.verificationContentWorkCosts;facts["captures"]=shell.verificationContentCaptureCosts
        facts["fadeLatencies"]=shell.verificationContentFadeLatencies;facts["events"]=events
        check(!window.isVisible,"real layout checks never display the NSWindow")
        // A normal eight-character store delta is the independent pixel oracle for each catchup frame.
        let c=Conversation(id:"round14.stream",title:"Stream"),reference=Conversation(id:"round14.reference",title:"Stream")
        c.items=[TranscriptItem(id:"stream",turnID:"stream",kind:.assistant,text:"Prefix ",status:"running")];c.running=true;reference.running=true;reference.items=c.items
        let stream=NativeTranscript(conversation:c),normal=NativeTranscript(conversation:reference)
        defer {stream.dispose();normal.dispose()}
        for native in [stream,normal] {native.frame=CGRect(x:0,y:0,width:500,height:240);native.verificationWindowVisible=true;native.refresh(allowHidden:true)}
        stream.verificationManualModeCatchup=true;stream.beginModeContentEpoch();c.items[0].text += String(repeating:"abcdefgh",count:16);c.items[0].status="completed";c.running=false;c.revision+=1;stream.endModeContentEpoch()
        var pixels:[Int]=[]
        for frame in 0..<16 {
            stream.verificationModeCatchupStep();reference.items[0].text += "abcdefgh";if frame == 15 {reference.items[0].status="completed";reference.running=false};reference.revision+=1;normal.refresh(preservingOffset:true,allowHidden:true)
            check(stream.verificationModeText == reference.items.map(\.text),"7 frame \(frame) exposes only one normal streaming delta")
            let a=NativeViewBitmap.capture(stream,scale:2),b=NativeViewBitmap.capture(normal,scale:2)
            let ad=a.dataProvider!.data! as Data,bd=b.dataProvider!.data! as Data
            let different=zip(ad,bd).reduce(0){$0+($1.0 == $1.1 ? 0:1)};pixels.append(different)
            check(different == 0,"7 catchup frame \(frame) equals a normally streamed native frame pixel for pixel")
            if frame == 0 || frame == 15 {Offscreen.write(a,output.appendingPathComponent("catchup-\(frame).png"));Offscreen.write(b,output.appendingPathComponent("normal-stream-\(frame).png"))}
            if frame == 3 {let prefix=stream.verificationModeText;stream.beginModeContentEpoch();stream.endModeContentEpoch();check(stream.verificationModeText == prefix,"7 a second freeze retains the displayed prefix")}
        }
        facts["streamPixelDifferences"]=pixels
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"facts":facts,"states":states],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round14-verification.json"))
        print("M11.31 round 14: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
}
#endif
