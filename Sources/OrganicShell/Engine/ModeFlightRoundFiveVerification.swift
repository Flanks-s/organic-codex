#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Production-path regressions for parked owners, surface geometry and CA submission boundaries.
@MainActor enum ModeFlightRoundFiveVerification {
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let size=CGSize(width:1280,height:820),row=ModeOrreryFlightVerification.rows[0],real=ModeOrreryFlightVerification.real[0]
        let avatars=(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar)
        // A real clip-view bounds event must finish a parked return even at unchanged endpoint coordinates.
        let conversations=(0..<32).map {i in let c=Conversation(id:"scroll.\(i)",title:"Scroll \(i)");c.pinned=true;return c}
        let store=ConversationStore(conversations:conversations)
        let sidebar=NormieSidebarController(model:NormieSidebarModel(store:store,current:conversations[0].id))
        sidebar.model.showMore("pinned");sidebar.model.showMore("pinned")
        _=sidebar.view;sidebar.prepareModeLayout(size:CGSize(width:260,height:300),safeRect:CGRect(x:0,y:0,width:260,height:300))
        let table=sidebar.table,clip=sidebar.scrollView.contentView
        let conversation=store.conversation(sidebar.model.rows.compactMap(\.conversationID).first!)!
        let index=sidebar.model.rows.firstIndex {$0.conversationID == conversation.id}!
        table.scrollRowToVisible(index);table.layoutSubtreeIfNeeded()
        let offset=clip.bounds.origin
        let native=table.view(atColumn:0,row:index,makeIfNecessary:true) as! NormieSidebarCell
        let target=native.planet.convert(native.planet.bounds,to:sidebar.view).offsetBy(dx:3,dy:1)
        let f=ModeFlight();f.manualTime={1000};f.resize(to:size)
        var events=0
        f.destinationOwnerVisible={id in
            if id == "me" {return true}
            guard table.rect(ofRow:index).intersects(clip.bounds),let cell=table.view(atColumn:0,row:index,makeIfNecessary:false) as? NormieSidebarCell else {return false}
            return !cell.planet.isHidden
        }
        f.onFrame={t in (table.view(atColumn:0,row:index,makeIfNecessary:false) as? NormieSidebarCell)?.planet.isHidden = !f.arrived("scroll",at:t)}
        sidebar.onModeEndpointVisibilityChanged={
            events+=1
            f.updateEndpoints(rows:[conversation.id:target],real:["scroll":real],avatar:(avatars.1,avatars.0))
        }
        f.start(toOrganic:false,avatar:(avatars.1,avatars.0),initials:"LL",tokens:[.init(id:"scroll",conversation:conversation,from:real,to:target,start:0,absorbed:true)],composer:nil,reduceMotion:false)
        clip.scroll(to:CGPoint(x:0,y:max(0,table.frame.height-clip.bounds.height)));sidebar.scrollView.reflectScrolledClipView(clip)
        facts["scrollGeometry"]=["table":NSStringFromRect(table.frame),"clip":NSStringFromRect(clip.bounds),"row":NSStringFromRect(table.rect(ofRow:index)),"initialOffset":NSStringFromPoint(offset)]
        if table.rect(ofRow:index).intersects(clip.bounds) {print("SCROLL GEOMETRY",facts["scrollGeometry"]!)}
        check(!table.rect(ofRow:index).intersects(clip.bounds),"R1 target row is genuinely outside the clip viewport")
        f.advance(at:f.duration+0.02);f.advance(at:f.duration+0.05);f.advance(at:f.duration+1.1)
        check(f.verificationWaitingForOwner,"R1 scrolled-out return parks with last visible row ink")
        // Exhaust the finite fallback before scrolling back: the ordinary native event must work on its own.
        RunLoop.main.run(until:Date(timeIntervalSinceNow:2.15))
        check(!f.verificationOwnerProbeActive,"R1 parked fallback stops after twenty probes")
        let before=events
        clip.scroll(to:offset);sidebar.scrollView.reflectScrolledClipView(clip);table.layoutSubtreeIfNeeded()
        _=table.view(atColumn:0,row:index,makeIfNecessary:true)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.08))
        check(events>before,"R1 native sidebar scrolling publishes endpoint visibility")
        check(!f.running && f.view.isHidden && (table.view(atColumn:0,row:index,makeIfNecessary:false) as? NormieSidebarCell)?.planet.isHidden == false,"R1 unchanged scroll-back retires flying ink into the visible native planet")
        facts["scrollEvents"]=events;f.shutdown();sidebar.onModeEndpointVisibilityChanged=nil
        // A native mount on the final allowed probe must retain its one-frame completion fence.
        let finalProbe=ModeFlight();finalProbe.manualTime={1500};finalProbe.resize(to:size)
        var readyAt=Double.infinity
        finalProbe.destinationOwnerVisible={_ in CACurrentMediaTime()>=readyAt}
        finalProbe.start(toOrganic:true,avatar:avatars,initials:"LL",tokens:[],composer:nil,reduceMotion:false)
        finalProbe.advance(at:finalProbe.duration+1.1);readyAt=CACurrentMediaTime()+1.96
        RunLoop.main.run(until:Date(timeIntervalSinceNow:2.15))
        check(!finalProbe.running && !finalProbe.verificationOwnerProbeActive,"R1 native mount on the final bounded probe completes its exposure fence")
        finalProbe.shutdown()
        // Removing the last waiting token cannot strand a paused display link or block subsequent prewarming.
        for removal in ["archive","delete","filter"] {
            let c=Conversation(id:"waiting",title:"Waiting"),library=ConversationStore()
            library.add(c)
            let flight=ModeFlight();flight.manualTime={2000};flight.resize(to:size)
            var exists=true
            flight.conversationIsLive={candidate in library.conversation(candidate.id) === candidate}
            flight.destinationExists={_ in exists}
            flight.destinationOwnerVisible={$0 == "me"}
            flight.start(toOrganic:false,avatar:(avatars.1,avatars.0),initials:"LL",tokens:[.init(id:"waiting",conversation:c,from:real,to:row,start:0,absorbed:true)],composer:nil,reduceMotion:false)
            let end=flight.duration
            flight.advance(at:end+0.02);flight.advance(at:end+0.05);flight.advance(at:end+1.1)
            check(flight.running && flight.verificationWaitingForOwner,"R2 \(removal) begins with a parked final token")
            if removal == "archive" {c.archived=true}
            else if removal == "delete" {_ = try library.remove(ids:[c.id])}
            else {exists=false}
            flight.updateEndpoints(rows:[c.id:row],real:["waiting":real],avatar:(avatars.1,avatars.0))
            check(!flight.running && flight.activeTokens.isEmpty && !flight.verificationOwnerProbeActive,"R2 \(removal) completes after pruning with unchanged geometry")
            flight.shutdown()
        }
        let cancelled=ModeFlight();cancelled.manualTime={2500};cancelled.resize(to:size)
        cancelled.destinationOwnerVisible={_ in false}
        cancelled.start(toOrganic:true,avatar:avatars,initials:"LL",tokens:[],composer:nil,reduceMotion:false)
        let cancelledEnd=cancelled.duration+1.1;cancelled.advance(at:cancelledEnd)
        check(cancelled.verificationOwnerProbeActive,"R2 cancellation begins with an armed parked probe")
        cancelled.cancel();cancelled.advance(at:cancelledEnd+0.1)
        check(!cancelled.running && !cancelled.verificationWaitingForOwner && !cancelled.verificationOwnerProbeActive,"R2 a queued frame after cancellation cannot resurrect a parked probe")
        cancelled.shutdown()
        try windowChecks(output:output,check:check,facts:&facts)
        // A texture must adapt to both width and height, keeping its original authored retirement deadline.
        for incoming in [false,true] {
            let host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size));host.wantsLayer=true
            let source=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:260,height:820));source.wantsLayer=true
            let foreground=ModeFlight.Plane(frame:host.bounds);host.addSubview(source);host.addSubview(foreground)
            let texture=ModeTurnSidebar(),bitmap=image(CGSize(width:320,height:940))
            texture.begin(bitmap,source:source,in:host,below:foreground,rect:source.frame,alpha:1,incoming:incoming,scale:1)
            let deadline=texture.verificationEnd
            check(texture.needsResize(host:CGSize(width:1400,height:940),source:CGSize(width:320,height:940)),"R3 live texture detects window and sidebar resize")
            texture.resize(bitmap,host:CGSize(width:1400,height:940),source:CGSize(width:320,height:940),scale:1)
            check(texture.view.bounds.size == CGSize(width:1400,height:940) && texture.verificationImage.bounds.size == CGSize(width:320,height:940),"R3 new texture covers the resized host and full sidebar")
            check(texture.verificationImage.position.x == (incoming ? 0:-320),"R3 native handoff target follows resized sidebar width")
            check(abs(texture.verificationEnd-deadline)<1e-9,"R3 resize preserves the board's original 250 ms deadline")
            check(texture.verificationSingleOwner,"R3 native source remains suppressed through resize")
            texture.finish();check(source.layer?.opacity == 1 && texture.view.superview == nil,"R3 native ownership restores atomically")
        }
        // Check the entire intersecting region, not just avatar centers.
        let host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),foreground=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
        host.wantsLayer=true;host.addSubview(foreground)
        let plate=ModeHandoffPlate(frame:host.bounds),holes=[avatars.0,avatars.1].map {$0.insetBy(dx:-3,dy:-3)}
        plate.hold(image(size),in:host,below:foreground,holes:holes)
        let paths=holes.map {CGPath(ellipseIn:$0,transform:nil)}
        check(plate.verificationHoles?.contains(CGPoint(x:38,y:778),using:.evenOdd) == false,"R4 avatar overlap at (38,778) is transparent")
        var overlapSamples=0
        for y in stride(from:CGFloat(748.25),through:816,by:0.5) {
            for x in stride(from:CGFloat(16.25),through:88,by:0.5) {
                let point=CGPoint(x:x,y:y),inside=paths.filter {$0.contains(point,using:.winding)}.count
                if inside == 2 {overlapSamples+=1}
                check((plate.verificationHoles?.contains(point,using:.evenOdd) ?? true) == (inside == 0),"R4 mask is complement of the endpoint-hole union \(x),\(y)")
            }
        }
        facts["overlapSamples"]=overlapSamples;check(overlapSamples>0,"R4 regression samples the intersection interior")
        plate.openRect=CGRect(x:0,y:740,width:40,height:80);plate.updateHoles(holes)
        check(plate.verificationHoles?.contains(CGPoint(x:38,y:778),using:.evenOdd) == false,"R4 sidebar rectangle and ellipse also subtract their union")
        plate.clear()
        // Stall after resource generation, immediately before the final initial transaction submission.
        var leads:[Double]=[]
        for forward in [false,true] {
            let flight=ModeFlight();flight.resize(to:size)
            flight.verificationBeforeInitialCommit={Thread.sleep(forTimeInterval:0.1)}
            flight.start(toOrganic:forward,avatar:forward ? avatars:(avatars.1,avatars.0),initials:"LL",tokens:[.init(id:"A",conversation:MockSeed.make()[0],from:forward ? row:real,to:forward ? real:row,start:0,absorbed:!forward)],composer:nil,reduceMotion:false)
            let lead=flight.verificationInitialLead;leads.append(lead*1000)
            check(lead>=0,"R7 initial CA submission retains t=0 after a 100 ms post-bake stall \(forward): \(lead)")
            check(flight.verificationServerLayers["A"]?.animation(forKey:"mode.server.translation") != nil,"R7 server receives actual initial motion commands")
            flight.shutdown()
        }
        facts["initialCommitLeadMS"]=leads
        let result:[String:Any]=["checks":checks,"findings":failures.count,"failures":failures,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round5-verification.json"))
        print("M11.31 round 5: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    private static func image(_ size:CGSize)->CGImage {
        let c=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor.gray.cgColor);c.fill(CGRect(origin:.zero,size:size));return c.makeImage()!
    }
    private static func windowChecks(output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let store=ConversationStore(),size=CGSize(width:1280,height:820)
        // MockReplay seeds this isolated store; no live runtime or persistent library is consulted.
        let seeded=MockReplay(store:store);seeded.start(live:false)
        let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:1,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(plane);plane.frame=root.bounds}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seeded.stopPlayback()}
        check(workbench.sidebar.onModeEndpointVisibilityChanged != nil && scene.onModeEndpointVisibilityChanged != nil,"R1 actual WindowShell subscribes to native endpoint notifications")
        let device=store.devices[0],revisions=store.conversations.map(\.revision)
        let pictureBefore=shell.verificationFlightDeviceKey,preparedBefore=shell.verificationPreparationDeviceKey
        store.setOnline(device.id,!device.online)
        check(store.conversations.map(\.revision) == revisions,"R5 disconnect regression changes no conversation revision")
        check(pictureBefore != shell.verificationFlightDeviceKey,"R5 device online status invalidates cached source pixels")
        check(preparedBefore != shell.verificationPreparationDeviceKey,"R5 device online status also invalidates prepared source pixels")
        facts["deviceKeyBefore"]=pictureBefore;facts["deviceKeyAfter"]=shell.verificationFlightDeviceKey
        var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
        shell.verificationFlightSettle(asOrganic:false);shell.prepareModeSwitch(reason:"round5.turn")
        shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit()
        now+=0.28;shell.flight.advance(at:0.28);shell.verificationFlightToggle(toOrganic:false)
        let firstTextureDeadline=Date(timeIntervalSinceNow:0.4)
        while !shell.verificationTurnSidebarSingleOwner,Date()<firstTextureDeadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.003))}
        // Model fallback is authoritative in a windowless host. Mutate it during the queued bake gap.
        // In a real window the same production lookup reads the compositor's presentation layer instead.
        var expected=CGPoint.zero,expectedAlpha:Float=0
        let native=shell.verificationNativeSidebarHost != nil
        shell.verificationBeforeTurnSidebarCommit={
            Thread.sleep(forTimeInterval:0.07)
            let layer=shell.verificationTurnSidebarImage
            CATransaction.begin();CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            if native {layer.setValue(CGFloat(-73),forKeyPath:"transform.translation.x")} else {layer.position=CGPoint(x:-73,y:0)}
            layer.opacity=native ? 1:0.37
            CATransaction.commit()
            let shown=layer.presentation() ?? layer
            expected=native ? CGPoint(x:CGFloat(shown.value(forKeyPath:"transform.translation.x") as? NSNumber ?? 0),y:0):shown.position
            expectedAlpha=shown.opacity
        }
        now+=0.08;shell.verificationFlightToggle(toOrganic:true)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.10))
        guard let group=shell.verificationTurnSidebarImage.animation(forKey:"mode.turn.sidebar") as? CAAnimationGroup else {check(false,"R6 replacement sidebar installs a CA command");return}
        let position=group.animations?.compactMap {$0 as? CABasicAnimation}.first {$0.keyPath == (native ? "transform.translation.x":"position")}
        let opacity=group.animations?.compactMap {$0 as? CABasicAnimation}.first {$0.keyPath == "opacity"}
        let from=native ? (position?.fromValue as? NSNumber).map{CGPoint(x:CGFloat($0.doubleValue),y:0)}:(position?.fromValue as? NSValue)?.pointValue
        check(from.map {hypot($0.x-expected.x,$0.y-expected.y)<0.5} ?? false,"R6 consecutive turn samples sidebar position after the queued bake gap")
        check(abs(((opacity?.fromValue as? NSNumber)?.floatValue ?? -1)-expectedAlpha)<0.001,"R6 consecutive turn samples sidebar opacity at replacement")
        // Exercise the real WindowShell layout integration, not just the texture component.
        shell.view.setFrameSize(CGSize(width:1400,height:940))
        if native {shell.split.splitView.setPosition(320,ofDividerAt:0);shell.split.view.layoutSubtreeIfNeeded()}
        else {workbench.sidebar.view.setFrameSize(CGSize(width:320,height:940))}
        shell.viewDidLayout()
        check(shell.verificationTurnSidebarImage.bounds.size == workbench.sidebar.view.bounds.size,"R3 actual WindowShell layout resizes its active sidebar texture")
        shell.verificationBeforeTurnSidebarCommit=nil
        facts["sidebarReplacementExpected"]=NSStringFromPoint(expected)
        shell.flight.cancel()
    }
}
#endif
