#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Exercise fixed picture identity, native mounts, frozen model epochs and the real hidden split hierarchy.
@MainActor enum ModeFlightRoundThirteenVerification {
    @MainActor final class Meter {
        var intervals:[Double]=[],last=0.0
        var onGap:((Double,Double)->Void)?
        var timer:Timer?
        func start() {
            last=CACurrentMediaTime()
            let timer=Timer(timeInterval:0.005,repeats:true) { [weak self] _ in MainActor.assumeIsolated {
                guard let self else {return};let now=CACurrentMediaTime();self.intervals.append((now-self.last)*1000);self.onGap?(self.last,now);self.last=now
            }}
            self.timer=timer;RunLoop.main.add(timer,forMode:.common)
        }
        func stop() {timer?.invalidate();timer=nil}
        func reset() {intervals=[];last=CACurrentMediaTime()}
    }
    final class Markers:NSView {
        var usesFlippedCoordinates=true
        override var isFlipped:Bool {usesFlippedCoordinates}
        override func draw(_ rect:NSRect) {
            NSColor.black.setFill();bounds.fill()
            let top:CGFloat=usesFlippedCoordinates ? 0:bounds.height-18,bottom:CGFloat=usesFlippedCoordinates ? bounds.height-18:0
            for (color,x,y) in [(NSColor.red,CGFloat(0),top),(.green,bounds.width-18,top),(.blue,CGFloat(0),bottom),(.yellow,bounds.width-18,bottom)] {
                color.setFill();CGRect(x:x,y:y,width:18,height:18).fill()
            }
            let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.white]
            ("FIRST R0" as NSString).draw(at:CGPoint(x:24,y:usesFlippedCoordinates ? 2:bounds.height-20),withAttributes:attributes)
            ("LAST R0" as NSString).draw(at:CGPoint(x:24,y:usesFlippedCoordinates ? bounds.height-20:2),withAttributes:attributes)
        }
    }
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var count=0,failures:[String]=[],facts:[String:Any]=[:],samples:[[String:Any]]=[]
        func check(_ value:Bool,_ name:String) {count+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let c=CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:0,y:0,width:80,height:60));let image=c.makeImage()!
        for source in ["normie","organic"] {
            let target=source == "normie" ? "organic":"normie"
            for turn in [0.08,0.28,0.54,0.95,1.30] {
                let photo=ModeWarmPicture(mode:source,revision:"R0",image:image,size:CGSize(width:80,height:60),scale:1,captureMS:0,maximumSliceMS:0)
                let session=ModeContentSession(photo:photo,target:target,time:100,trace:nil)
                for frame in 0...Int(turn*240) {
                    let t=Double(frame)/240,u=session.progress(at:100+t),a=ModeContentSession.alpha(u)
                    let expected=source == "normie" ? 1-ModeContentSession.alpha(min(1,t/0.220)):ModeContentSession.alpha(min(1,t/0.220))
                    check(abs(a-expected)<1e-11,"board smoothstep \(source) t=\(t)")
                }
                let u=session.progress(at:100+turn),id=session.photoID,live=session.liveMode
                session.turn(to:source,at:100+turn)
                check(abs(session.progress(at:100+turn)-u)<1e-12,"turn alpha is continuous at \(source) \(turn)")
                check(session.photoID == id && session.liveMode == live,"turn preserves representation at \(source) \(turn)")
                check(session.atDestination(102+turn),"turned progress reaches its endpoint")
            }
            for spacing in [0.120,0.300] {for turns in [9,10] {
                let photo=ModeWarmPicture(mode:source,revision:"R0",image:image,size:CGSize(width:80,height:60),scale:1,captureMS:0,maximumSliceMS:0)
                let session=ModeContentSession(photo:photo,target:target,time:0,trace:nil),id=session.photoID
                for turn in 1...turns {
                    let time=Double(turn)*spacing,before=session.progress(at:time)
                    session.turn(to:turn%2 == 1 ? source:target,at:time)
                    check(session.progress(at:time) == before && session.photoID == id && session.liveMode == target,"ten/odd turn keeps fixed picture and live root")
                }
            }}
        }
        // Independent AppKit cacheDisplay reference, including both root coordinate conventions.
        for flipped in [true,false] {
            let marker=Markers(frame:CGRect(x:0,y:0,width:320,height:192));marker.usesFlippedCoordinates=flipped;marker.wantsLayer=true
            let rep=marker.bitmapImageRepForCachingDisplay(in:marker.bounds)!
            marker.cacheDisplay(in:marker.bounds,to:rep)
            let reference=rep.cgImage!
            let builder=ModeSurfaceBuilder(marker,scale:1,includeWindowFrame:false,opaqueBody:true)
            while !builder.ready {builder.step()}
            let actual=builder.finish()!.flattened()
            for point in [(8,8),(312,8),(8,184),(312,184)] {
                let a=ModeFlightRoundEightVerification.rgb(actual,x:point.0,y:point.1),b=ModeFlightRoundEightVerification.rgb(reference,x:point.0*reference.width/320,y:point.1*reference.height/192)
                check(abs(a.0-b.0)+abs(a.1-b.1)+abs(a.2-b.2)<=3,"four asymmetric capture markers match independent AppKit reference \(flipped) \(point)")
            }
            let photo=ModeWarmPicture(mode:"normie",revision:"R0",image:actual,size:marker.bounds.size,scale:1,captureMS:0,maximumSliceMS:0)
            let retained=ModeContentPictureView(frame:marker.bounds);retained.install(photo)
            let shown=ModeFlightRoundEightVerification.render(retained,at:CACurrentMediaTime()+1000)
            for point in [(8,8),(312,8),(8,184),(312,184)] {
                let a=ModeFlightRoundEightVerification.rgb(shown,x:point.0,y:point.1),b=ModeFlightRoundEightVerification.rgb(reference,x:point.0*reference.width/320,y:point.1*reference.height/192)
                check(abs(a.0-b.0)+abs(a.1-b.1)+abs(a.2-b.2)<=3,"retained picture keeps marker orientation \(flipped) \(point)")
            }
            Offscreen.write(shown,output.appendingPathComponent("retained-markers-\(flipped).png"))
            Offscreen.write(actual,output.appendingPathComponent("body-markers-\(flipped).png"))
            Offscreen.write(reference,output.appendingPathComponent("reference-markers-\(flipped).png"))
        }
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
        window.toolbar=NSToolbar(identifier:"round13.hidden");window.contentView?.superview?.layoutSubtreeIfNeeded()
        defer {shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        func wait(_ seconds:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:seconds))}
        func rest(_ organic:Bool) {shell.flight.cancel();shell.verificationFlightSettle(asOrganic:organic);shell.verificationRepairRest(organic ? .organic:.normie);window.contentView?.superview?.layoutSubtreeIfNeeded()}
        func prepare() {
            shell.verificationWarmGeometryForClosure()
            wait(0.15)
            for _ in 0..<3 {
                shell.verificationPrepareContentPicture();let deadline=Date(timeIntervalSinceNow:4)
                while shell.verificationContentCapturing,Date()<deadline {wait(0.001)}
                if shell.verificationContentImage != nil {return}
                let replayDeadline=Date(timeIntervalSinceNow:4)
                while sessions.transcripts.values.contains(where:{$0.modeContentIsCatchingUp}),Date()<replayDeadline {wait(0.02)}
                wait(0.02)
            }
        }
        let meter=Meter();meter.start();defer {meter.stop()}
        var commandMS:[Double]=[],burstPerformance:[[String:Any]]=[]
        for startOrganic in [false,true] {
            rest(startOrganic);prepare()
            check(shell.verificationContentImage != nil,"real complete native owner publishes a warm picture")
            let host=shell.verificationNativeSidebarHost,parent=host?.superview
            meter.reset()
            let begin=CACurrentMediaTime();shell.verificationFlightToggle(toOrganic:!startOrganic);commandMS.append((CACurrentMediaTime()-begin)*1000)
            let deadline=Date(timeIntervalSinceNow:4)
            while shell.verificationContentSessionState["active"] as? Bool != true,Date()<deadline {wait(0.002)}
            var first=shell.verificationContentSessionState;first["stage"]="start";samples.append(first)
            check(first["active"] as? Bool == true,"real switch installs the fixed representation")
            check(first["oldPicture"] as? Bool == false,"new path never installs the legacy picture stack")
            let id=first["photoID"] as? String,live=first["liveMode"] as? String
            for turn in 0..<20 {
                wait(turn<10 ? 0.120:0.300)
                let target=turn%2 == 0 ? startOrganic:!startOrganic
                let start=CACurrentMediaTime();shell.verificationFlightToggle(toOrganic:target);commandMS.append((CACurrentMediaTime()-start)*1000)
                let state=shell.verificationContentSessionState;samples.append(state)
                check(state["photoID"] as? String == id && state["liveMode"] as? String == live,"production turn keeps fixed picture and live owner")
                check(state["midPhaseMounts"] as? Int == 0 && state["captures"] as? Int == 0,"production turn never mounts between covered endpoints or captures")
                check(state["organicOpacity"] as? Float == 1,"Organic base remains fully opaque")
                check(shell.verificationNativeSidebarHost === host && host?.superview === parent,"native sidebar instance and parent remain fixed")
                if turn == 3,let model=store.conversations.first {
                    let native=sessions.existingTranscript(for:model.id),revision=native?.renderedRevision
                    if !model.items.isEmpty {model.items[model.items.count-1].text += " epoch streaming"};store.changed(model)
                    native?.refresh(allowHidden:true)
                    check(native?.renderedRevision == revision,"store streaming cannot drain into a frozen live epoch")
                    shell.verificationInvalidateContent("streaming")
                    check(shell.verificationContentSessionState["photoID"] as? String == id,"streaming invalidates only the next warm candidate")
                }
            }
            wait(0.23);shell.flight.cancel();shell.verificationFinishContentSession()
            burstPerformance.append(["initialOrganic":startOrganic,"intervalsMS":meter.intervals,"maximumMS":meter.intervals.max() ?? 0,"over50":meter.intervals.filter {$0>50}.count])
            check(shell.verificationContentSessionState["active"] as? Bool == false,"final endpoint retires the single picture")
        }
        rest(false);shell.verificationDropFlightPreparation()
        shell.verificationFlightToggle(toOrganic:true)
        check(shell.flight.running,"cache miss submits flight before capture or native admission")
        let coldDeadline=Date(timeIntervalSinceNow:4)
        while shell.verificationContentSessionState["active"] as? Bool != true,Date()<coldDeadline {wait(0.002)}
        let cold=shell.verificationContentSessionState,coldID=cold["photoID"] as? String
        wait(0.08)
        let resizeLease=shell.verificationContentLeaseGeneration
        window.setContentSize(CGSize(width:1400,height:940));window.contentView?.superview?.layoutSubtreeIfNeeded()
        scene.resize(to:CGSize(width:1400,height:940),live:true);shell.viewDidLayout()
        check(shell.verificationContentSessionState["photoID"] as? String == coldID && shell.verificationContentLeaseGeneration == resizeLease,"actual mid-phase resize preserves picture identity and does not remount leases")
        window.appearance=NSAppearance(named:.aqua);shell.viewDidLayout()
        check(shell.verificationContentSessionState["photoID"] as? String == coldID,"actual window appearance change cannot evict an active picture")
        window.appearance=NSAppearance(named:.darkAqua)
        check(coldID != nil,"cache miss produces one complete source picture off the key stack")
        for reason in ["resize","scale","appearance","scroll","typing","approval"] {
            shell.verificationInvalidateContent(reason)
            check(shell.verificationContentSessionState["photoID"] as? String == coldID,"configuration changes never replace ActivePicture: \(reason)")
        }
        let lease=shell.verificationContentLeaseGeneration
        shell.verificationFlightToggle(toOrganic:false);wait(0.04)
        check(shell.verificationContentLeaseGeneration == lease,"a stale opening completion cannot remount after reversal")
        shell.flight.cancel();shell.verificationFinishContentSession()
        check(shell.verificationContentSessionState["active"] as? Bool == false,"odd reversal ends at its original complete native owner")
        // A rejected first mount retains the source owner rather than publishing a desired mode.
        rest(false);workbench.setTerminalShown(true,animated:false);prepare();shell.verificationFlightToggle(toOrganic:true)
        let terminal=workbench.detail.terminalPane.inputField
        window.makeFirstResponder(terminal)
        let editor=terminal.currentEditor() as? NSTextView
        editor?.setMarkedText("guard",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        wait(0.10)
        check(shell.verificationContentSessionState["active"] as? Bool == false && shell.verificationNativeOwnerState["admitted"] as? String == "normie","a refused native mount preserves the old complete owner")
        editor?.unmarkText();window.makeFirstResponder(nil);workbench.setTerminalShown(false,animated:false)
        window.setContentSize(size);scene.resize(to:size,live:false);window.contentView?.superview?.layoutSubtreeIfNeeded();shell.viewDidLayout()
        // Capture costs at selectable raster scales, from both complete native modes.
        for scale in [0.5,0.75,1.0,2.0] {
            setenv("M11_MODE_PHOTO_SCALE",String(scale),1)
            for organic in [false,true] {rest(organic);prepare();if let image=shell.verificationContentImage {check(image.width == Int(ceil(size.width*scale)),"resolution switch controls actual picture pixels")}}
        }
        unsetenv("M11_MODE_PHOTO_SCALE")
        meter.stop()
        facts["bursts"]=burstPerformance
        facts["heartbeatMS"]=meter.intervals;facts["heartbeatMaximumMS"]=meter.intervals.max() ?? 0
        facts["heartbeatOver50"]=meter.intervals.filter {$0>50}.count
        facts["workCosts"]=shell.verificationContentWorkCosts;facts["fadeLatencies"]=shell.verificationContentFadeLatencies
        facts["captures"]=shell.verificationContentCaptureCosts;facts["invalidations"]=shell.verificationContentInvalidations
        facts["commandMS"]=commandMS;facts["maximumCommandMS"]=commandMS.max() ?? 0
        check(!window.isVisible,"the real NSWindow was never displayed")
        try JSONSerialization.data(withJSONObject:["checks":count,"findings":failures.count,"failures":failures,"facts":facts,"samples":samples],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round13-verification.json"))
        print("M11.31 round 13: \(count) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
}
#endif
