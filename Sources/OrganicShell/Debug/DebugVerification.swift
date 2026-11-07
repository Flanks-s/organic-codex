#if DEBUG_SELFTEST
import AppKit
import ObjectiveC

/// Standalone Core + Native + Orb + Debug. No NSWindow allocation or app event loop.
@main @MainActor enum DebugVerification {
    static func main() async throws {
        _ = NSApplication.shared;NSApp.appearance=NSAppearance(named:.darkAqua)
        let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/sol-debug-verification")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var failures:[String]=[],checks=0
        func check(_ value:@autoclosure()->Bool,_ message:String){checks+=1;if !value(){failures.append(message)}}
        await DebugMockVerification.run(check:{check($0,$1)})
        let store=ConversationStore(),mock=MockReplay(store:store);mock.verificationArrivalIDs=true;mock.start(live:false)
        let session=DebugSession(store:store,replay:mock,initiallyPaused:true)
        check(session.canInject && session.paused,"demo session admits mock controls without starting a timer")
        check(!session.select("missing") && session.select("F") && session.selectedID == "F","conversation selection validates identity")
        let c=store.conversation("F")!
        var changed=0;let observation=store.observe{_ in changed+=1}
        let count=mock.emitted;check(session.step() && mock.emitted>count && session.ticks == 1,"Step advances actual Core MockReplay")
        check(session.setPaused(false) && !session.step(),"running clock rejects Step")
        check(session.setPaused(true) && session.paused,"pause stops the driver clock")
        check(session.setBackgroundEvents(false) && !session.backgroundEvents,"background event switch")
        check(session.inject(.approval) && c.approvals.count == 1 && c.running,"approval injection creates a Core approval and running tool")
        check(c.approvals.first?.request["method"]?.stringValue == "item/commandExecution/requestApproval","approval retains ordinary Core request method")
        check(!session.inject(.approval),"blocked approval does not duplicate requests")
        check(session.inject(.question) && c.userInput?.questions.count == 1 && c.question != nil && !c.running && c.approvals.isEmpty,"question settles previous run and carries structured options")
        check(session.inject(.errorRunning) && c.running && c.error == .running && c.redEvents>0,"retrying error injection")
        check(session.inject(.errorStopped) && !c.running && c.error == .stopped,"stopped error injection")
        let completions=c.completions
        check(session.inject(.complete) && !c.running && c.error == nil && c.completions == completions+1 && c.unread,"completion settles and marks unread")
        c.contextUsed=0.9;let updated=c.updated,compactions=c.compactions
        check(session.inject(.compaction) && c.compactions == compactions+1 && c.contextUsed<0.9 && c.updated == updated,"compaction does not reorder sidebar")
        check(session.inject(.addSatellite) && c.satellites.count == 1 && !c.satellitesRetired && c.updated == updated,"satellite injection retains sidebar order")
        check(session.inject(.satelliteDone) && c.satellites.first?.done == true && c.satellites.first?.finishedOrder != nil,"satellite completion is stable")
        check(!session.inject(.satelliteDone),"no running satellite produces no fabricated completion")
        c.contextUsed=0.95;check(session.inject(.contextUp) && c.contextUsed == 1,"context injection clamps at 100 percent")
        var arrivals:[String]=[];session.onArrive={arrivals.append($0.id)}
        let arrival=session.arrive();check(arrival != nil && store.conversation(arrival!.id) === arrival && arrivals == [arrival!.id],"arrival uses store and host routing callback")
        check(changed>8,"injections notify existing store observers");store.removeObserver(observation)
        let before=c.items,revision=c.revision
        store.usesLiveCore=true
        for event in DebugInjection.allCases{check(!session.inject(event,into:c.id),"Live blocks \(event.rawValue)")}
        check(!session.step() && !session.setPaused(false) && !session.setBackgroundEvents(true) && session.arrive() == nil,"Live blocks all mock business routes")
        check(c.items == before && c.revision == revision,"Live rejects without mutating model")
        store.usesLiveCore=false;c.isLiveConversation=true
        check(!session.canInject && !session.step() && !session.inject(.complete,into:c.id),"mixed Live conversation blocks replay ownership")
        c.isLiveConversation=false
        let noMock=DebugSession(store:store,replay:nil);check(!noMock.canInject && !noMock.step(),"missing mock interface does not fabricate playback")

        let tuning=session.tuning
        check(Set(DebugTuningParameter.all.map(\.key)).count == DebugTuningParameter.all.count,"tuning keys are unique")
        for p in DebugTuningParameter.all {
            check(tuning[p] == p.defaultValue,"default \(p.key)")
            _ = tuning.set(p.key,p.range.upperBound+100);check(tuning[p] == p.range.upperBound,"upper clamp \(p.key)")
            _ = tuning.set(p.key,p.range.lowerBound-100);check(tuning[p] == p.range.lowerBound,"lower clamp \(p.key)")
        }
        check(!tuning.set("missing",1) && !tuning.set("orb.size",.nan),"unknown and nonfinite tuning rejected")
        var parameterNotifications=0,toggleNotifications=0;tuning.onChange={_,_ in parameterNotifications+=1};tuning.onToggle={_,_ in toggleNotifications+=1}
        _ = tuning.set("orb.size",48);_ = tuning.toggle("fullyFocused")
        check(parameterNotifications == 1 && toggleNotifications == 1 && !tuning.toggle("missing"),"tuning callbacks and toggle admission")
        let json=try JSONSerialization.jsonObject(with:tuning.exportJSON(at:Date(timeIntervalSince1970:0))) as! [String:Any]
        check((json["params"] as? [String:Double])?["orb.size"] == 48 && json["conversations"] == nil && json["requests"] == nil,"JSON exports only tuning, never request secrets")
        tuning.reset();check(DebugTuningParameter.all.allSatisfy{tuning[$0] == $0.defaultValue} && tuning.toggles["fullyFocused"] == false,"Reset All restores product tuning defaults")

        var p=TransitionLabParameters();p.fullWidth = .infinity;p.briefWidth=900;p.height=1;p.burst = -1;p.swirl=200;p.pop=5;p.stagger=1;p.normalize()
        check(p.fullWidth == 620 && p.briefWidth == 420 && p.height == 420 && p.burst == 0 && p.swirl == 90 && p.pop == 0.4 && p.stagger == 0.12,"transition parameter normalization")
        var transport=TransitionLabTransport();p=TransitionLabParameters()
        transport.scrub(0.4);check(transport.form == 0.4 && !transport.playing,"scrub exact form")
        transport.nudge(-0.02);check(abs(transport.form-0.38)<1e-8 && transport.towardBrief,"nudge changes direction")
        transport.scrub(-8);check(transport.form == 0,"scrub lower clamp");transport.scrub(.nan);check(transport.form == 0,"nonfinite scrub ignored")
        transport.play(toBrief:false);transport.advance(0.1,parameters:p);let normal=transport.form
        transport.slow=10;transport.play(toBrief:false);transport.advance(1,parameters:p);check(abs(normal-transport.form)<1e-8,"tenfold slow playback")
        transport.play(toBrief:true);transport.advance(0.1,parameters:p);let midpoint=transport.form;transport.play(toBrief:false,fromEndpoint:false);check(transport.form == midpoint && !transport.towardBrief,"reverse keeps current form")
        transport.slow=1;transport.loop=true;transport.play(toBrief:true);transport.advance(10,parameters:p);check(transport.playing && !transport.towardBrief && transport.form == 0,"loop alternates direction at endpoint")
        transport.stop();let stopped=transport.form;transport.advance(1,parameters:p);check(transport.form == stopped && !transport.playing,"stop freezes transport")
        check(TransitionLabTransport.filmstrip.count == 22 && TransitionLabTransport.filmstrip.first!.1 == 1 && TransitionLabTransport.filmstrip.last!.1 == 1,"22-frame bidirectional filmstrip")
        for preset in LabSpringPreset.all {
            let spring=LabSpring(response:preset.response,damping:preset.damping),end=spring.truncatedEnd(distance:preset.distance),fit=LabFittedCurve.fit(spring,distance:preset.distance)
            check(abs(spring.value(0))<1e-8 && abs(spring.value(spring.settlingTime)-1)<0.001,"system spring endpoints \(preset.name)")
            check(end>0 && end<=spring.settlingTime+0.001 && fit.duration == end,"truncated / fitted timing \(preset.name)")
            check(abs(fit.value(0))<1e-8 && abs(fit.value(end)-1)<1e-8,"fitted endpoints \(preset.name)")
        }
        var sr=SpringLabRequest();sr.response = .nan;sr.distance=999;sr.runs=100;sr.slow=0;sr.normalize();check(sr.response == 0.42 && sr.distance == 600 && sr.runs == 12 && sr.slow == 1,"spring parameter admission")
        var sim=SpringLabSimulation();sim.play(SpringLabRequest());sim.advance(0.1);let interrupted=sim.values;sim.interrupt();check(sim.values == interrupted && sim.request.target == 0,"spring interrupt retains current positions")
        sim.advance(10);check(sim.values.allSatisfy{abs($0)<1e-8} && !sim.playing,"spring interruption settles to new target")
        var trace=LabSpringTrace();trace.append(time:0,value:0,busyMilliseconds:1);trace.append(time:0.002,value:1,busyMilliseconds:2);trace.append(time:0.1,value:99.9,busyMilliseconds:3);trace.append(time:0.2,value:100,busyMilliseconds:4);trace.append(time:0.3,value:100,busyMilliseconds:5)
        let stats=trace.result(variant:.system,target:100,scale:2)
        check(stats.frames == 4 && stats.tailFrames == 2 && stats.busyMilliseconds == 14,"trace coalesces evaluations and reports tail draw cost")
        check(LabSpringTrace.median([stats,stats]) == stats && LabSpringTrace.median([]) == nil,"measurement median")

        let transitionHost=DebugFakeTransitionHost(),springHost=DebugFakeSpringHost()
        let tools=DebugTools(store:store,mock:mock,initiallyPaused:true,transitionHost:transitionHost,springHost:springHost)
        check(NSApp.windows.allSatisfy{!$0.isVisible},"tools construction presents no windows")
        let menu=tools.menuItems()
        check(menu.count == 5 && menu.prefix(4).map(\.keyEquivalent) == ["d","o","t","p"],"menu entry keys")
        check(menu.prefix(4).allSatisfy{$0.keyEquivalentModifierMask == [.shift,.option,.command] && $0.target === tools},"menu modifiers and target lifetime")
        let panelController=tools.controller(.debug),panel=panelController.acquireContent() as! DebugPanelPage
        panel.view.frame.size=CGSize(width:440,height:760);panel.view.layoutSubtreeIfNeeded()
        check(panel.active && panel.view.accessibilityRole() == .group,"Debug panel AX group")
        let buttons=descendants(panel.view).compactMap{$0 as? DebugButton},sliders=descendants(panel.view).compactMap{$0 as? DebugSlider}
        check(buttons.allSatisfy{$0.accessibilityLabel()?.isEmpty == false} && sliders.allSatisfy{$0.accessibilityRole() == .slider && $0.accessibilityLabel()?.isEmpty == false},"buttons and sliders have native AX semantics")
        store.usesLiveCore=true;panel.refresh();check(buttons.filter{DebugInjection.allCases.map(\.rawValue).contains($0.title)}.allSatisfy{!$0.isEnabled},"Live UI injection is disabled")
        store.usesLiveCore=false;panel.refresh()
        let slider=DebugSlider("Keyboard test",value:0.5,range:0...1);panel.form.add(slider,height:44)
        check(slider.accessibilityPerformIncrement() && slider.value>0.5 && slider.accessibilityPerformDecrement() && abs(slider.value-0.5)<1e-8,"AX slider changes")
        let right=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124)!
        slider.keyDown(with:right);check(slider.value>0.5,"Right arrow adjusts focused slider")
        slider.isHidden=true;check(!slider.accessibilityPerformIncrement(),"hidden slider cannot act");slider.isHidden=false
        slider.isEnabled=false;let disabledValue=slider.value;slider.keyDown(with:right);check(slider.value == disabledValue,"disabled slider rejects keyboard writes");slider.isEnabled=true
        var pressed=0;let b=DebugButton("Keyboard test",action:{pressed+=1});panel.form.add(b)
        let space=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!
        b.keyDown(with:space);check(pressed == 1,"Space activates focused button action")
        b.isEnabled=false;check(!b.accessibilityPerformPress() && pressed == 1,"disabled button AX action rejects")

        panel.form.needsLayout=true;panel.form.layoutSubtreeIfNeeded();let keys=panel.form.keyboardControls
        check(keys.count>20 && zip(keys,keys.dropFirst()).allSatisfy{$0.0.nextKeyView === $0.1},"Tab order follows visual form and event grid")

        let transition=tools.controller(.transition).acquireContent() as! TransitionLabPage
        check(transitionHost.attaches == 1 && transitionHost.requests.count>0,"transition host attach and initial render")
        transition.scrub(0.25);check(transitionHost.requests.last?.form == 0.25 && transitionHost.requests.last?.frozen == true,"scrub passes exact frozen form to host")
        transition.parameters.burst=52;transition.nudge(0.02);check(transitionHost.requests.last?.parameters.burst == 52,"host receives current tuning")
        transition.play(toBrief:true);transition.advance(0.1);check(transitionHost.requests.last?.towardBrief == true && transitionHost.requests.last?.form != 1,"play calls host at intermediate form");transition.stop()
        let outline=transition.form.rows.compactMap{$0.0 as? DebugButton}.first{$0.title == "Outline anchors and paths"}!
        check(outline.activate() && transition.stage.outlines && transitionHost.requests.last?.outlines == true,"outlines toggle updates host and stage")
        let filmstrip=output.appendingPathComponent("filmstrip");try transition.exportFilmstrip(to:filmstrip,scale:1)
        let exported=try FileManager.default.contentsOfDirectory(atPath:filmstrip.path)
        check(exported.filter{$0.hasSuffix(".png")}.count == 22 && exported.contains("manifest.json"),"filmstrip writes both directions plus manifest")
        let manifest=try String(contentsOf:filmstrip.appendingPathComponent("manifest.json"),encoding:.utf8);check(manifest.contains("Fake host for verification"),"filmstrip preserves rendering provenance")
        let missing=TransitionLabPage(store:store,host:nil);_ = missing.view;missing.activate()
        do{try missing.exportFilmstrip(to:output.appendingPathComponent("missing"),scale:1);check(false,"missing host must reject export")}catch{check(true,"missing host export rejected")};missing.deactivate()
        let spring=tools.controller(.spring).acquireContent() as! SpringLabPage
        check(springHost.attaches == 1,"Spring host attach")
        spring.request.realColumn=true;spring.play();spring.advance(0.1);spring.interrupt()
        check(springHost.plays.count == 1 && springHost.interrupts.count == 1 && springHost.frames>0,"real-column play, frame and interrupt delegate to host")
        let measured=try await spring.measureHost();check(measured.count == 3 && springHost.measures == 1 && measured.allSatisfy{$0.provenance == "Fake host for verification"},"real-column measurement uses host result without relabeling")
        spring.stop();check(springHost.stops>0,"Spring stop reaches host")
        spring.setSpotlight(true);spring.spotlight.layoutSubtreeIfNeeded();check(spring.spotlight.containers.count == 3,"three separate native glass experiments")
        spring.play();spring.advance(1.7);check(spring.spotlight.out == false,"Spotlight alternates every 1.6 seconds");spring.stop()
        check(spring.form.rows.compactMap{$0.0 as? DebugButton}.first{$0.title == "Lab"}?.valueText == "Spotlight glass","programmatic Spotlight route updates selected Lab menu")
        let orb=tools.controller(.orb).acquireContent() as! OrbLabPage
        check(orb.tiles.count == store.conversations.count*3+13,"Orb Lab reuses all conversation states plus 13 identities")
        check(Set(orb.tiles.suffix(13).map{$0.caption}).count == 13,"all 13 identity labels")
        for scale:CGFloat in [1,2]{try save(orb.snapshot(scale:scale),output.appendingPathComponent("orb-default@\(Int(scale))x.png"))}
        orb.context=0.91;orb.reduceMotion=true;orb.rows=true;orb.refresh()
        check(orb.tiles.prefix(store.conversations.count*3).allSatisfy{$0.configuration.context == 0.91 && $0.configuration.reduceMotion && $0.configuration.satelliteMode == .rows},"Orb liquid / rows / Reduce Motion calibration")
        for (name,page) in [("debug",panel as DebugPageController),("transition",transition),("spring",spring),("orb",orb)] {
            check(plainControls(page.view).isEmpty,"§7.5 runtime draw tree \(name)")
            for scale:CGFloat in [1,2]{let image=page.snapshot(scale:scale);try save(image,output.appendingPathComponent("\(name)@\(Int(scale))x.png"));check(image.width == Int(page.view.bounds.width*scale) && image.height == Int(page.view.bounds.height*scale),"snapshot dimensions \(name) \(scale)x")}
        }
        spring.setSpotlight(false);spring.request.realColumn=false;spring.applyPreset(0);spring.play();spring.advance(0.1);spring.stop()
        for scale:CGFloat in [1,2]{try save(spring.snapshot(scale:scale),output.appendingPathComponent("spring-lanes@\(Int(scale))x.png"))}
        for scale:CGFloat in [1,2]{try save(NativeViewBitmap.capture(orb.board,scale:scale),output.appendingPathComponent("orb-board@\(Int(scale))x.png"))}
        try PlainControlSourceAuditVerification.run(component:"Debug",evidenceDirectory:output) { check($0,$1) }
        let displayOptions=NativeDisplayOptions.shared
        defer{displayOptions.setVerificationState(nil)}
        for state in [NativeDisplayOptions.State(increaseContrast:true,reduceTransparency:false),.init(increaseContrast:false,reduceTransparency:true)]{
            displayOptions.setVerificationState(state)
            check(NativeDisplayOptions.plate(alpha:0.18).alphaComponent==1,"f201 Debug plates become opaque after workspace notification")
            check(spring.view.appearance?.name == NativeDisplayOptions.appearance?.name,"f201 Debug roots update their retained appearance")
            for scale:CGFloat in [1,2]{let image=spring.snapshot(scale:scale);try save(image,output.appendingPathComponent("spring-\(state.increaseContrast ? "contrast":"opaque")@\(Int(scale))x.png"));check(image.width==Int(spring.view.bounds.width*scale),"f201 Debug accessible capture")}
        }
        tools.releaseAllContent()
        check(!panel.active && !transition.active && !spring.active && !orb.active && orb.tiles.isEmpty,"closing withdraws content, observers and Orb animations")
        check(!slider.accessibilityPerformIncrement(),"released page rejects retained control AX actions")
        check(transitionHost.detaches == 1 && springHost.detaches == 1 && spring.spotlight.containers.isEmpty,"closing detaches hosts and glass")
        check(tools.controller(.debug).page == nil && tools.controller(.orb).page == nil,"window shells retain no hidden content")
        weak var released:DebugPageController?;weak var releasedView:NSView?
        autoreleasepool{let shell=DebugToolWindow(title:"Release",size:CGSize(width:440,height:500),autosave:"verification"){DebugPanelPage(session:session)};let page=shell.acquireContent();released=page;releasedView=page.view;shell.releaseContent()}
        check(released == nil && releasedView == nil,"controller and view actually deallocate on close")
        let reacquired=tools.controller(.transition).acquireContent();check(reacquired !== transition && transitionHost.attaches == 2,"reopening creates fresh content")
        tools.releaseAllContent();session.stopClock()
        check(NSApp.windows.allSatisfy{!$0.isVisible} && panel.view.window == nil && orb.view.window == nil,"verification opens no windows")
        let report="Debug verification: \(checks) checks, \(failures.count) failures\n"+failures.map{"  "+$0}.joined(separator:"\n")+"\nOffscreen glass uses a neutral proxy; compositor refraction, real-window text parity and menu tracking require host recording.\n"
        try report.write(to:output.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8);print(report);if !failures.isEmpty{exit(1)}
    }
    static func descendants(_ root:NSView)->[NSView]{[root]+root.subviews.flatMap(descendants)}
    static func plainControls(_ root:NSView)->[NSView]{descendants(root).filter{v in
        guard v is NSTextField || v is NSButton else{return false};guard let cls=object_getClass(v),let method=class_getInstanceMethod(cls,#selector(NSView.draw(_:))),let base=class_getInstanceMethod(v is NSButton ? NSButton.self:NSTextField.self,#selector(NSView.draw(_:)))else{return true};return method_getImplementation(method) == method_getImplementation(base)
    }}
    static func save(_ image:CGImage,_ url:URL)throws{try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:url,options:.atomic)}
}
@MainActor final class DebugFakeTransitionHost:TransitionLabHost {
    var attaches=0,detaches=0,requests:[TransitionLabRequest]=[]
    func transitionLabAttach(){attaches+=1}
    func transitionLabDetach(){detaches+=1}
    func transitionLabRender(_ request:TransitionLabRequest,size:CGSize,scale:CGFloat)->TransitionLabFrame {
        requests.append(request)
        let context=CGContext(data:nil,width:max(1,Int(size.width*scale)),height:max(1,Int(size.height*scale)),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemTeal.withAlphaComponent(0.2).cgColor);context.fill(CGRect(x:20,y:20,width:request.interpolatedWidth*scale/2,height:size.height*scale-40))
        return .init(image:context.makeImage(),anchors:[.init(name:"title",full:CGRect(x:30,y:20,width:250,height:32),brief:CGRect(x:20,y:20,width:120,height:32))],paths:[.init(name:"title",points:[CGPoint(x:150,y:40),CGPoint(x:120,y:90),CGPoint(x:80,y:40)])],provenance:"Fake host for verification")
    }
}
@MainActor final class DebugFakeSpringHost:SpringLabHost {
    var attaches=0,detaches=0,stops=0,frames=0,measures=0
    var plays:[SpringLabRequest]=[],interrupts:[SpringLabRequest]=[]
    func springLabAttach(){attaches+=1};func springLabDetach(){detaches+=1};func springLabStop(){stops+=1}
    func springLabPlay(_ request:SpringLabRequest){plays.append(request)}
    func springLabInterrupt(_ request:SpringLabRequest){interrupts.append(request)}
    func springLabFrame(size:CGSize,scale:CGFloat)->CGImage?{frames+=1;return nil}
    func springLabMeasure(_ request:SpringLabRequest) async throws->[SpringLabMeasurement]{measures+=1;return LabSpringVariant.allCases.map{.init(variant:$0,frames:90,tailFrames:30,duration:1.5,visibleEnd:1,busyMilliseconds:15,tailBusyMilliseconds:3,provenance:"Fake host for verification")}}
}
#endif
