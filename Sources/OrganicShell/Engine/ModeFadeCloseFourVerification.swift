#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Real native owners plus deterministic display tickets. No window is ever ordered.
@MainActor enum ModeFadeCloseFourVerification {
    static func run(to output:URL) throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        func wait(_ seconds:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:max(0,seconds)))}
        let host=NSView(frame:CGRect(x:0,y:0,width:1280,height:820))
        ModeSignposts.receiptsEnabled=true
        var ticketFacts:[[String:Any]]=[]
        for hz in [60.0,120.0] {for delay in [0.002,0.004] {
            ModeContentWorkBoundary.verificationManualTickets=true
            let interval=1/hz,origin=CACurrentMediaTime()+0.01
            var starts:[Double]=[],budgets:[Double]=[],nearDeadline:[Double]=[]
            let trace=ModeSignposts.Trace()
            ModeSignposts.withTrace(trace) {
                for _ in 0..<3 {ModeContentWorkBoundary.schedule(in:host,interval:interval) {
                    starts.append(CACurrentMediaTime())
                    budgets.append(ModeContentWorkBoundary.captureBudget())
                                        nearDeadline.append(ModeContentWorkBoundary.captureBudget(at:starts.last!+interval-0.001))
                }}
            }
            for index in 0..<3 {
                let tick=origin+Double(index)*interval
                wait(tick-CACurrentMediaTime())
                ModeContentWorkBoundary.verificationDisplayTicket(timestamp:tick,target:tick+interval,interval:interval)
                let late=CACurrentMediaTime()+delay
                while CACurrentMediaTime()<late {} // Delayed AppKit commit, after the callback and before work begins.
                wait(0.001)
                let count=starts.count
                ModeContentWorkBoundary.verificationDisplayTicket(timestamp:tick,target:tick+interval,interval:interval)
                wait(0.0005)
                check(starts.count == count,"a one physical timestamp never executes two items at \(hz) Hz / \(delay*1000) ms")
            }
            check(starts.count == 3,"a every next display cycle remains eligible after a \(delay*1000) ms late start at \(hz) Hz")
            if hz == 60 {check(budgets.count == 3 && budgets.allSatisfy {$0>0.0055 && $0<=0.006},"b available 60 Hz deadlines grant a six millisecond capture budget")}
            check(!nearDeadline.isEmpty && nearDeadline.allSatisfy {$0<=0.0001},"b a nearly exhausted execution cycle cannot receive a fresh paint budget")
            ticketFacts.append(["hz":hz,"delayMS":delay*1000,"starts":starts,"budgets":budgets,"nearDeadline":nearDeadline])
            ModeContentWorkBoundary.cancel(in:host);ModeContentWorkBoundary.verificationManualTickets=false
        }}
        facts["tickets"]=ticketFacts
        var timerStarts:[Double]=[]
        ModeContentWorkBoundary.schedule(in:host,interval:1/60) {timerStarts.append(CACurrentMediaTime())}
        ModeContentWorkBoundary.schedule(in:host,interval:1/60) {timerStarts.append(CACurrentMediaTime())}
        wait(0.07)
        check(timerStarts.count == 2 && timerStarts[1]-timerStarts[0]>=0.015,"a hidden-window timers retain their elapsed-time spacing")
        ModeContentWorkBoundary.cancel(in:host)

        let pixel=CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let photo=ModeWarmPicture(mode:"normie",revision:"R0",image:pixel.makeImage()!,size:CGSize(width:2,height:2),scale:1,captureMS:0,maximumSliceMS:0)
        for alpha in [0.0,0.04,0.47,0.78,0.96,1.0] {
            let session=ModeContentSession(photo:photo,target:"organic",time:1000,trace:nil)
            session.turn(to:"normie",at:1000.1,presentedAlpha:alpha)
            let initial=ModeContentSession.alpha(session.progress(at:1000.1)),next=ModeContentSession.alpha(session.progress(at:1000.1+1/60))
            check(abs(initial-alpha)<0.000001 && next>=initial,"v4 a presentation sample \(alpha) reverses from the visible phase on its first frame")
            if alpha == 0 || alpha == 1 {check(session.progress(at:1000.1) == alpha,"v4 opaque presentation endpoints remain exact mount fences")}
        }

        // A Pulse event is already near expiry when the body epoch starts.
        let model=Conversation(id:"close4.pulse",title:"Stable source header")
        let header=HeaderIsland();var time=CACurrentMediaTime()+3600
        header.now={time};header.noticeWallTime={1000}
        var input=HeaderIslandConfiguration.conversation(model,variant:.full,columnWidth:507,band:44,ambient:false,scale:2)
        input.notices = .init();header.configure(input)
        input.notices = .init(journal:[ConversationNotice(id:1,kind:.command,text:"Running a source command")]);header.configure(input)
        for _ in 0..<540 {time+=1/240;header.sampleMotion(at:time)}
        let before=header.pulseProbe ?? [:],beforeInk=header.snapshot(scale:2)
        header.setModeContentFrozen(true)
        for _ in 0..<300 {time+=1/240;header.sampleMotion(at:time)}
        let after=header.pulseProbe ?? [:]
        check(before["mode"] as? String == "bloom","v1 the source fixture contains a visible two-line status capsule")
        check(after["mode"] as? String == before["mode"] as? String && after["rect"] as? [Double] == before["rect"] as? [Double],"v1 a frozen body epoch retains the source capsule ink geometry across its expiry")
        let afterInk=header.snapshot(scale:2)
        let beforeBytes=beforeInk.dataProvider!.data! as Data,afterBytes=afterInk.dataProvider!.data! as Data
        check(beforeInk.width == afterInk.width && beforeInk.height == afterInk.height && beforeBytes == afterBytes,"v1 the frozen source header retains identical glyph pixels through expiry")
        Offscreen.write(beforeInk,output.appendingPathComponent("pulse-before.png"));Offscreen.write(afterInk,output.appendingPathComponent("pulse-frozen.png"))
        facts["pulse"]=["before":before,"after":after,"pixelsEqual":beforeBytes == afterBytes]
        input.variant = .brief;input.columnWidth=317;header.configure(input)
        header.setModeContentFrozen(false)
        check(header.pulseProbe != nil,"v1 a header variant prepared behind the picture resumes its real content without waiting for a new store event")
        header.dispose()

        let c=Conversation(id:"close4.stream",title:"Normal stream cadence")
        c.items=[TranscriptItem(id:"stream",turnID:"t",kind:.assistant,text:String(repeating:"A stable source line.\n",count:30)+"Tail",status:"running")];c.running=true
        let native=NativeTranscript(conversation:c);native.frame=CGRect(x:0,y:0,width:500,height:180)
        native.verificationWindowVisible=true;native.refresh(allowHidden:true)
        native.scrollOffset=CGPoint(x:0,y:100000)
        native.verificationManualModeCatchup=true;native.verificationPacedModeCatchup=true
        var replayNow=CACurrentMediaTime();native.verificationModeReplayNow={replayNow}
        native.beginModeContentEpoch();let prefix=native.verificationModeText
        c.items[0].text += "\nNext line of streamed text.\nOne more normal source row.\n";c.revision+=1
        native.endModeContentEpoch();let releaseTime=replayNow
        replayNow+=0.01;native.verificationModeCatchupStep()
        check(native.verificationModeText == prefix,"v2 cancelling a cold picture never publishes a stream row in its first display cycle")
        replayNow=releaseTime+native.verificationModeReplayInterval+0.002
        let oldOffset=native.verificationModeScrollOrigin,sourceInk=NativeViewBitmap.capture(native,scale:2)
        native.verificationModeCatchupStep();let first=native.verificationModeText
        let movement=native.verificationModeScrollOrigin-oldOffset
        let animation=native.verificationModeScrollAnimation as? CABasicAnimation
        check(movement>0,"v2 the first replay packet really introduces a new visible source line")
        check(animation != nil && abs((animation?.fromValue as? Double ?? -1000)-movement)<0.01 && animation!.duration>=0.05,"v2 native scroll compensation preserves the previously displayed glyph positions on the first replay frame")
        if let animation,movement>0 {
            let t=CACurrentMediaTime()+3600
            func tree(compensated:Bool)->CALayer {
                let canvas=CALayer();canvas.frame=native.bounds;canvas.isGeometryFlipped=true
                let glyphs=CALayer();glyphs.frame=canvas.bounds;glyphs.contents=sourceInk;glyphs.contentsScale=2;canvas.addSublayer(glyphs)
                if compensated {
                    glyphs.frame.origin.y -= movement
                    let phase=animation.copy() as! CABasicAnimation;phase.beginTime=t;phase.fillMode = .both;phase.isRemovedOnCompletion=false
                    glyphs.add(phase,forKey:"replay")
                }
                return canvas
            }
            // Attach complete trees before CARenderer's warm-up, as the production carrier readback does.
            let beforeRenderer=OffscreenRenderer(size:native.bounds.size,host:tree(compensated:false),scale:2)
            let renderer=OffscreenRenderer(size:native.bounds.size,host:tree(compensated:true),scale:2)
            let reference=beforeRenderer.render(at:t),displayed=renderer.render(at:t)
            let pixels=zip(reference,displayed).reduce(0){$0+($1.0 == $1.1 ? 0:1)}
            check(pixels == 0,"v2 the production scroll clock preserves every preceding glyph pixel on its first frame")
            facts["scrollFirstFrameChangedBytes"]=pixels
            Offscreen.write(renderer.image(reference),output.appendingPathComponent("scroll-before.png"));Offscreen.write(renderer.image(displayed),output.appendingPathComponent("scroll-first.png"))
        } else {check(false,"v2 the production scroll clock preserves every preceding glyph pixel on its first frame")}
        check(!native.scrollView.hasVerticalScroller,"v2 reflected replay scrolling cannot flash an overlay scroller")
        replayNow+=1/60;native.verificationModeCatchupStep()
        check(native.verificationModeText == first,"v3 consecutive display cycles cannot accelerate the normal source stream")
        let count=first[0].count
        replayNow+=native.verificationModeReplayInterval;native.verificationModeCatchupStep()
        check(native.verificationModeText[0].count == count+8,"v3 one normal replay interval releases only one eight-character packet")
        facts["stream"]=["interval":native.verificationModeReplayInterval,"movement":movement,"duration":animation?.duration ?? 0,"packets":native.verificationModeCatchupPackets]
        native.dispose()

        let paused=Conversation(id:"close4.paused-scroll",title:"Paused scroll")
        paused.items=[TranscriptItem(id:"same",kind:.assistant,text:"No new delta",running:true)]
        let pausedNative=NativeTranscript(conversation:paused);pausedNative.frame=CGRect(x:0,y:0,width:500,height:180)
        pausedNative.verificationWindowVisible=true;pausedNative.refresh(allowHidden:true)
        let document=pausedNative.scrollView.documentView!;document.wantsLayer=true;document.layer?.setValue(7,forKeyPath:"transform.translation.y")
        pausedNative.beginModeContentEpoch();pausedNative.endModeContentEpoch()
        check(abs((document.layer?.value(forKeyPath:"transform.translation.y") as? NSNumber)?.doubleValue ?? 100)<0.001,"v2 ending a second freeze without new text never leaves a permanent document displacement")
        check(pausedNative.verificationModeScrollAnimation != nil,"v2 a paused scroll resumes continuously even when its epoch has no new text")
        pausedNative.dispose()

        let timed=Conversation(id:"close4.paced",title:"Wall clock replay")
        timed.items=[TranscriptItem(id:"text",kind:.assistant,text:"Prefix ",running:true)];timed.running=true
        let timedNative=NativeTranscript(conversation:timed);timedNative.frame=CGRect(x:0,y:0,width:500,height:180)
        timedNative.verificationWindowVisible=true;timedNative.refresh(allowHidden:true);timedNative.beginModeContentEpoch()
        timed.items[0].text+=String(repeating:"abcdefgh",count:10);timed.revision+=1
        timedNative.endModeContentEpoch();wait(0.55)
        let packets=timedNative.verificationModeCatchupPackets
        check(packets.count>=3 && packets.count<=4 && zip(packets,packets.dropFirst()).allSatisfy {$1[0]-$0[0]>=0.10},"v3 real timer replay follows the source cadence instead of four rows in a short display burst")
        facts["timedReplay"]=packets;timedNative.dispose()

        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false);for c in store.conversations {c.running=false;c.sending=false;c.loading=false}
        let sessions=NativeTranscriptSessions(store:store),scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=false
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=root.bounds;root.addSubview(plane)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic)
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentViewController=shell;shell.installToolbar(in:window)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let timer=Timer(timeInterval:1/120,repeats:true) {_ in MainActor.assumeIsolated {scene.frame(CACurrentMediaTime());if shell.flight.running {shell.flight.verificationDisplayAdvance(at:shell.flight.elapsed)}}}
        RunLoop.main.add(timer,forMode:.common)
        defer {timer.invalidate();shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        var commit=0,phases:[[String:Any]]=[]
        let observer=CFRunLoopObserverCreateWithHandler(nil,CFRunLoopActivity.beforeWaiting.rawValue,true,CFIndex.max-2) {_,_ in MainActor.assumeIsolated {commit+=1}}!
        CFRunLoopAddObserver(CFRunLoopGetMain(),observer,.commonModes);defer {CFRunLoopRemoveObserver(CFRunLoopGetMain(),observer,.commonModes)}
        shell.onTurnCost={phase,ms in phases.append(["phase":phase,"ms":ms,"commit":commit])}
        shell.setMode(.normie)
        let deadline=Date(timeIntervalSinceNow:4)
        while shell.verificationContentSessionState["active"] as? Bool != true,Date()<deadline {wait(0.002)}
        func phaseCommit(_ name:String)->Int? {phases.first {$0["phase"] as? String == name}?["commit"] as? Int}
        check(phaseCommit("native.normie-selection") != nil && phaseCommit("native.normie-selection") == phaseCommit("native.normie-editor") && phaseCommit("native.normie-editor") == phaseCommit("native.normie-chrome"),"c tiny selection and chrome work share the editor preparation commit")
        let heavy=["picture.install","native.detach","native.normie-editor","native.normie-layout","native.admission","native.ready-layout"].compactMap(phaseCommit)
        check(heavy.count == 6 && zip(heavy,heavy.dropFirst()).allSatisfy {$0<$1},"c picture installation, editor, layout and admission retain separate commit opportunities")
        let oldPhase=shell.verificationContentPhase
        wait(0.04)
        var checkedAt:Double?,installedPhase:CAKeyframeAnimation?
        shell.onTurnCost={phase,_ in
            if phase == "flight.submit" {checkedAt=CACurrentMediaTime();installedPhase=shell.verificationContentPhase;Thread.sleep(forTimeInterval:0.04)}
        }
        shell.setMode(.organic);shell.onTurnCost=nil
        let newPhase=shell.verificationContentPhase
        check(installedPhase != nil && installedPhase?.beginTime != oldPhase?.beginTime && installedPhase?.beginTime == newPhase?.beginTime,"v4 the reversed content clock is already installed before flight reconstruction completes")
        check(newPhase != nil && (newPhase!.beginTime <= (checkedAt ?? 0)),"v4 a reversal never waits until after the blocked flight submission to install its first frame")
        facts["nativePhases"]=phases;facts["turn"]=["before":oldPhase?.beginTime ?? 0,"duringFlight":installedPhase?.beginTime ?? 0,"after":newPhase?.beginTime ?? 0,"flightCheckedAt":checkedAt ?? 0]
        check(!window.isVisible,"all native layout checks use a never-ordered window")
        facts["receipt"]=ModeSignposts.receipt
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"facts":facts],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fade-close4.json"))
        print("Fade close 4: \(checks)/\(failures.count)");return failures.isEmpty ? 0:1
    }
}
#endif
