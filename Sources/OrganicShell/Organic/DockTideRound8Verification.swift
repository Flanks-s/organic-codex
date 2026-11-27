#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Native contour, posted-window input and render-server publication regressions from the R6 recording.
@MainActor enum DockTideRound8Verification {
    private final class FilterAuditLayer:CALayer {
        var radii:[Double]=[]
        override func setValue(_ value:Any?,forKeyPath keyPath:String) {
            if keyPath == "filters.tideInk.inputRadius",let value=value as? Double {radii.append(value)}
            super.setValue(value,forKeyPath:keyPath)
        }
    }
    static func run(to output:URL,check:(Bool,String)->Void)throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for scale:CGFloat in [1,2] {
            let f=DockTideRound6Verification.Fixture(scale:scale)
            f.start();f.approval("stagger");f.pump(0.05)
            check(abs(f.dock.items["B"]!.glass.frame.width-305)<0.05,"same-publication turn placeholder preserves B's .09 s delay: \(scale)x")
            f.pump(0.95)
            let lead=f.ink["autoLeadRect"] as? [CGFloat] ?? []
            check(lead.count==4 && lead[2]==14 && lead[3]==14,"Auto action uses the small vector glyph, not a 48 pt disc: \(scale)x")
            let band=f.ink["bandRect"] as? [CGFloat] ?? []
            check(band.count==4 && abs(band[3]-48*0.12)<0.01 && (f.ink["bandAlpha"] as? Double ?? 0)>0.29 && f.ink["liquidMaskAttached"] as? Bool==false,"action's static tide band matches the board's 12% / .3: \(scale)x")
            f.approval("urgent",outside:true);f.force()
            check(f.ink["halo"] as? String=="card","a new halo scope retains the old shape on arrival: \(scale)x")
            f.pump(0.04)
            let oldAlpha=f.ink["haloAlpha"] as? Double ?? -1
            check(oldAlpha>0 && oldAlpha<1,"old halo fades before scope replacement: \(scale)x")
            f.pump(0.08)
            let newAlpha=f.ink["haloAlpha"] as? Double ?? -1
            check(f.ink["halo"] as? String=="column" && newAlpha>0 && newAlpha<1,"new scope enters through intermediate content alpha: \(scale)x")
            f.close()
            let refused=DockTideRound6Verification.Fixture(scale:scale)
            refused.store.conversation("C")!.draft=" "
            refused.start();refused.command()
            var previous=refused.dock.items["D"]!.glass.frame,maxWidthStep=0.0,minGap=Double.infinity
            for _ in 0..<240 {
                refused.pump(1.0/120);let rect=refused.dock.items["D"]!.glass.frame
                maxWidthStep=max(maxWidthStep,abs(rect.width-previous.width));previous=rect
                minGap=min(minGap,refused.p["minimumGap"] as? Double ?? 0)
                rows.append(["case":"protected-pill","scale":scale,"time":refused.now,"rect":DockTideShape.rect(rect),"minimumGap":refused.p["minimumGap"] ?? -1,"worstPair":refused.p["worstPair"] ?? "","nodes":refused.dock.items.mapValues{DockTideShape.rect($0.glass.frame)}])
            }
            let bound=DockTideRound7Verification.widthBound(32,68,(0.42,0.80))
            check(maxWidthStep<=bound,"refused native pill never snaps to orb or back: \(scale)x \(maxWidthStep) <= \(bound)")
            check(abs(previous.width-68)<0.05 && minGap>=11.999,"refused pill reaches 68 while retaining 12 pt: \(scale)x")
            refused.close()
            let reclaim=DockTideRound6Verification.Fixture(scale:scale)
            reclaim.start();reclaim.command();reclaim.pump(1)
            let c=reclaim.dock.items["C"]!.glass.frame,a=reclaim.dock.items["A"]!.glass.frame
            _=reclaim.dock.pointer(CGPoint(x:c.midX,y:c.midY),now:reclaim.now)
            reclaim.pump(0.08)
            let restored=reclaim.dock.items["C"]!.glass.frame,grip=reclaim.dock.items["C"]!.grip
            check(restored.width>36 && restored.width<160,"hover reclaim keeps the displayed glass spring: \(scale)x")
            check(abs(reclaim.dock.items["A"]!.glass.frame.minY-a.minY)<0.001,"hover reclaim never raises the ordinary bottom row: \(scale)x")
            check(!grip.isHidden && grip.opacity>0 && grip.opacity<1,"reclaim handle follows the retained content fade: \(scale)x")
            rows.append(["case":"reclaim","scale":scale,"rect":DockTideShape.rect(restored),"gripAlpha":grip.opacity,"fullBar":DockTideShape.rect(reclaim.dock.items["A"]!.glass.frame)])
            reclaim.close()
            let reply=DockTideRound6Verification.Fixture(scale:scale)
            reply.start();reply.approval("reply-clock");reply.pump(2)
            reply.button("Allow")?.performClick(nil);reply.pump(0.1)
            let remaining=reply.p["occupancyRemaining"] as? Double ?? 100
            check(remaining>2.85 && remaining<3.06,"reply resets occupancy to 1.8 * 1.7 rather than extending the old timer: \(scale)x")
            reply.pump(4.6)
            check(reply.p["phase"] as? String=="idle","reply naturally returns before fixture cleanup: \(scale)x")
            reply.close()
            let stopped=DockTideRound6Verification.Fixture(scale:scale)
            stopped.start();stopped.emit("error",["message":"Fixture stopped","willRetry":false]);stopped.pump(1)
            check(stopped.p["level"] as? Int==1 && abs(stopped.dock.items["D"]!.glass.frame.width-192)<0.05,"one-button stopped card borrows one brief and stays 192 pt: \(scale)x")
            check(stopped.button("Review error") != nil,"the compact stopped card keeps the real Review action: \(scale)x")
            stopped.close()
        }
        for kind in ["approval","live"] {try deadline(kind,to:&rows,check:check)}
        for mode in ["auto","focused","split","parked"] {try postedHover(mode,to:&rows,check:check)}
        for mode in ["focused","split","parked"] {imeEscape(mode,check:check)}
        retiredInput(check:check)
        let filterLayer=FilterAuditLayer();var filter:NSObject?
        for radius in stride(from:8.0,through:0.5,by:-0.5) {DockTidePresentation.ink(filterLayer,opacity:0.5,blur:radius,scale:1,filter:&filter);CATransaction.flush()}
        check(filterLayer.radii.count>=14 && (filterLayer.radii.last ?? 100)<1,"every intermediate blur radius is published through the installed CA layer path")
        DockTidePresentation.ink(filterLayer,opacity:1,blur:0,scale:1,filter:&filter)
        check(filterLayer.filters?.isEmpty != false,"settled content releases its filter surface")
        let question=DockTideRound6Verification.Fixture();question.start();question.question();question.pump(0.8)
        question.emit("core/approvalRequested",["approvalId":"second-question","request":["method":"item/tool/requestUserInput","params":["questions":[["id":"second-choice","question":"Another fixture?","options":[["label":"No"],["label":"Yes"]]]]]]])
        question.force();question.store.changed(question.store.conversation("D")!);question.force()
        let warnings=question.p["questionWarnings"] as? [[String:String]] ?? []
        check(warnings.count==1 && warnings[0]["previousRequestID"]=="question-r6" && warnings[0]["incomingRequestID"]=="second-question","Q4 logs both question IDs once without a second pending UI slot")
        check(question.store.conversation("D")?.userInput?.id=="second-question" && (question.p["pending"] as? [[String:Any]])?.count==1,"diagnostic preserves Core's existing single-question contract")
        question.close()
        let idle=DockTideRound6Verification.Fixture()
        let task=Task<Void,Never> {try? await Task.sleep(for:.seconds(1))}
        idle.scene.idlePrewarmTask=task
        check(idle.dock.tideWarmAllowed?()==false,"Tide glass construction yields while transcript idle preparation owns the main-thread slices")
        task.cancel();idle.scene.idlePrewarmTask=nil;idle.close()
        check(NSApp.windows.allSatisfy{!$0.isVisible},"round8 never orders a window onscreen")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round8.json"))
    }
    private static func deadline(_ kind:String,to rows:inout [[String:Any]],check:(Bool,String)->Void)throws {
        let f=DockTideRound6Verification.Fixture();f.start()
        if kind=="approval" {f.approval("timer-latency")}else {f.emit("core/pulseProgress",["completed":7,"total":7])}
        var frameUntil=f.now,previous=f.dock.items["D"]!.glass.frame,maxClosingStep=0.0,firstClosingStep:Double?
        f.dock.onNeedsFrames={duration in f.pendingFrame=true;frameUntil=max(frameUntil,f.now+duration)}
        f.dock.onNeedsFramesUntil={time in f.pendingFrame=true;frameUntil=max(frameUntil,time)}
        let began=f.now
        for tick in 0..<1800 {
            f.now=began+Double(tick+1)/120
            // Deterministic timer lateness from the observed recording; display callbacks still run at 120 Hz.
            let probe=f.dock.tideLightProbe
            let timer=probe["nextTimerAt"] as? Double ?? probe["nextWakeAt"] as? Double
            if let timer,f.now>=timer+0.060 {f.dock.serviceTideDeadline()}
            if f.now<frameUntil {f.pendingFrame=true}
            if f.pendingFrame {
                f.pendingFrame=false;f.dock.frame(at:f.now,elapsed:.infinity)
                let rect=f.dock.items["D"]!.glass.frame,step=previous.width-rect.width
                if f.now-began>6.9,step>0.01 {if firstClosingStep==nil {firstClosingStep=step};maxClosingStep=max(maxClosingStep,step)}
                rows.append(["case":"deadline-"+kind,"t":f.now-began,"rect":DockTideShape.rect(rect),"probe":f.dock.tideLightProbe]);previous=rect
            }
        }
        let bound=DockTideRound7Verification.widthBound(458,32,(0.50,0.86))
        check(maxClosingStep<=bound,"late timer does not skip a native retreat step: \(kind) \(maxClosingStep) <= \(bound)")
        check((firstClosingStep ?? 100)<bound,"first retreat frame starts within one display step: \(kind)")
        check(f.p["phase"] as? String=="idle","both deadline phases finish after the latency fixture: \(kind)")
        f.close()
    }
    private static func postedHover(_ mode:String,to rows:inout [[String:Any]],check:(Bool,String)->Void)throws {
        let f=DockTideRound6Verification.Fixture()
        if mode=="parked" {var scheme=f.scene.scheme;scheme.parked=["D"];f.scene.transition(to:f.scene.members,current:f.scene.current,scheme:scheme,spring:Tuning.shared.autoSpring,reason:"posted-hover")}
        else if mode != "auto" {f.scene.enterFocused("A",reason:"posted-hover");if mode=="split" {f.scene.graft("B",at:1,reason:"posted-hover")}}
        f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
        // Post into the visible card on the outer right orb; an inner Split orb can have no admitted card.
        if mode != "auto" && mode != "parked" {f.target=f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.last!.id}
        let host=NSView(frame:f.dock.view.bounds),window=NSWindow(contentRect:f.dock.view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(f.dock.view);window.acceptsMouseMovedEvents=true
        f.start();f.command();f.pump(1)
        let side=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target}
        let r=mode=="auto" ? f.dock.items[f.target]!.glass.frame : {
            let a=side?["card"] as? [CGFloat] ?? [];return a.count==4 ? CGRect(x:a[0],y:a[1],width:a[2],height:a[3]):.zero
        }()
        func post(_ p:CGPoint) {
            let location=f.dock.view.convert(p,to:nil)
            let event=NSEvent.mouseEvent(with:.mouseMoved,location:location,modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
            window.postEvent(event,atStart:false)
            while let next=NSApp.nextEvent(matching:.mouseMoved,until:.distantPast,inMode:.default,dequeue:true) {NSApp.sendEvent(next)}
        }
        let before=mode=="auto" ? f.dock.tideLightProbe:(side ?? [:])
        post(CGPoint(x:r.midX,y:r.midY));f.pump(0.5)
        let probe=mode=="auto" ? f.ink:(f.dock.tideSideProbe.first{$0["owner"] as? String==f.target}?["presentation"] as? [String:Any] ?? [:])
        check(probe["inside"] as? Bool==true && probe["hovering"] as? Bool==true,"posted NSWindow mouseMoved enters real Tide hover: "+mode)
        let p=mode=="auto" ? f.dock.tideLightProbe:(f.dock.tideSideProbe.first{$0["owner"] as? String==f.target} ?? [:])
        check(abs((p["eventRemaining"] as? Double ?? -10)-(before["eventRemaining"] as? Double ?? 10))<0.01 && abs((p["occupancyRemaining"] as? Double ?? -10)-(before["occupancyRemaining"] as? Double ?? 10))<0.01,"posted hover freezes both clocks: "+mode)
        rows.append(["case":"posted-hover-"+mode,"probe":p,"presentation":probe])
        post(CGPoint(x:10,y:10));f.pump(0.3)
        check(!window.isVisible,"posted hover requires no onscreen window: "+mode)
        window.close();f.close()
    }
    private static func imeEscape(_ mode:String,check:(Bool,String)->Void) {
        let f=DockTideRound6Verification.Fixture()
        if mode=="parked" {var scheme=f.scene.scheme;scheme.parked=["D"];f.scene.transition(to:f.scene.members,current:f.scene.current,scheme:scheme,spring:Tuning.shared.autoSpring,reason:"ime-side")}
        else {f.scene.enterFocused("A",reason:"ime-side");if mode=="split" {f.scene.graft("B",at:1,reason:"ime-side")}}
        f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
        // Exercise IME priority over an actually visible Side command on the outer right orb.
        if mode != "parked" {f.target=f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.last!.id}
        let host=NSView(frame:f.dock.view.bounds),window=NSWindow(contentRect:f.dock.view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(f.dock.view)
        let composer=NativeComposer();composer.frame=CGRect(x:0,y:0,width:300,height:48);host.addSubview(composer)
        f.start();f.command();f.pump(1)
        _=window.makeFirstResponder(composer.textView)
        composer.textView.setMarkedText("composing",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        check(window.firstResponder === composer.textView && composer.textView.hasMarkedText(),"IME fixture owns the native window responder: "+mode)
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        window.postEvent(event,atStart:false)
        if let next=NSApp.nextEvent(matching:.keyDown,until:.distantPast,inMode:.default,dequeue:true) {NSApp.sendEvent(next)}
        f.pump(0.1)
        let side=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target}
        check(side?["event"] as? String=="command" && side?["returning"] as? Bool==false,"IME Escape keeps its priority over Side dismissal: "+mode)
        composer.textView.unmarkText();window.close();f.close()
    }

    private static func retiredInput(check:(Bool,String)->Void) {
        let f=DockTideRound6Verification.Fixture(),host=NSView(frame:CGRect(x:0,y:0,width:1280,height:820))
        let window=NSWindow(contentRect:host.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(f.dock.view)
        var calls=0;let previous=f.dock.onTidePointer
        f.dock.onTidePointer={point in calls+=1;previous?(point)}
        func post(_ point:CGPoint=CGPoint(x:10,y:10)) {
            let event=NSEvent.mouseEvent(with:.mouseMoved,location:f.dock.view.convert(point,to:nil),modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
            window.postEvent(event,atStart:false)
            if let next=NSApp.nextEvent(matching:.mouseMoved,until:.distantPast,inMode:.default,dequeue:true) {NSApp.sendEvent(next)}
        }
        let c=f.dock.items["C"]!.glass.frame,overC=CGPoint(x:c.midX,y:c.midY)
        post(overC);check(calls==0,"ordinary window mouse traffic does not enter an inactive Tide route")
        f.start();f.command();f.pump(1)
        check(f.p["level"] as? Int==0,"ordinary window motion still protects the brief on the next notification")
        post(overC);f.pump(0.1);f.dock.retireTide();post()
        f.command();f.pump(1.1)
        check(f.p["level"] as? Int==1,"moving away while Tide is retired clears stale hover protection before the next lease")
        f.scene.suspendModePresentation();calls=0
        post();check(calls==0,"real presentation suspension prevents window motion from waking the retired Organic tree")
        window.close();f.close()
    }

}
#endif
