#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Round four observes the production ink tree, effective opacity, native admission and retained owners.
@MainActor enum ModeFlightRoundFourVerification {
    static func run(to output:URL,reference:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failed=0,failures:[String]=[],categories:[String:Int]=[:],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failed+=1;categories[String(name.prefix(2)),default:0]+=1;if failures.count<1000 {failures.append(name);print("FAIL: "+name)}}}
        let size=CGSize(width:1280,height:820),rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real
        let avatar=(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar)
        let profile=ModeOrreryFlightVerification.profile,seed=MockSeed.make()
        func tokens(_ forward:Bool)->[ModeFlight.Token] {(0..<6).map {i in
            .init(id:i<3 ? "header."+seed[i].id:seed[i].id,conversation:seed[i],from:forward ? rows[i]:real[i],to:forward ? real[i]:rows[i],start:0,absorbed:!forward)
        }}
        let board=try JSONDecoder().decode([ModeOrreryFlightVerification.Frame].self,from:Data(contentsOf:reference))
        var alphaError=0.0,blurError=0.0
        var glyphCSV=["forward,time,id,row,boardRow,glass,boardGlass,effectiveGlyph,blur,boardBlur,rowDepth,glassDepth"]
        var firstCommitLeads:[Double]=[]
        for forward in [true,false] {
            let f=ModeFlight();f.manualTime={1000};f.verificationServerMotion=true;f.resize(to:size)
            f.start(toOrganic:forward,avatar:forward ? avatar:(avatar.1,avatar.0),initials:"LL",tokens:tokens(forward),composer:nil,reduceMotion:false)
            for frame in board where frame.fwd == forward {
                f.sample(at:frame.t,profile:profile)
                let states=Dictionary(uniqueKeysWithValues:f.verificationOrreryState(at:frame.t).map {($0["id"] as! String,$0)})
                for i in 0..<6 {
                    let expected=frame.tokens[seed[i].id]!,id=tokens(forward)[i].id
                    guard expected.vis,!expected.landed,let state=states[id] else {continue}
                    let row=(state["rowOpacity"] as! NSNumber).doubleValue
                    let glass=(state["glassOpacity"] as! NSNumber).doubleValue
                    let ink=(state["effectiveGlyphOpacity"] as! NSNumber).doubleValue
                    let blur=(state["rowRadius"] as! NSNumber).doubleValue
                    alphaError=max(alphaError,abs(ink-expected.gl));blurError=max(blurError,abs(blur-6*(1-expected.rw)))
                    glyphCSV.append("\(forward),\(frame.t),\(id),\(row),\(expected.rw),\(glass),\(expected.gl),\(ink),\(blur),\(6*(1-expected.rw)),\(state["rowDepth"]!),\(state["depth"]!)")
                    check(abs(row-expected.rw)<1e-6,"A1 board row alpha \(forward) \(frame.t) \(id)")
                    check(abs(glass-expected.gl)<1e-6 && abs(ink-expected.gl)<1e-6,"A2 board glass and effective glyph alpha once \(forward) \(frame.t) \(id)")
                    check(abs(blur-6*(1-expected.rw))<1e-6,"A3 board one Gaussian radius \(forward) \(frame.t) \(id)")
                    if expected.rw>0 {
                        check((state["rowDepth"] as! NSNumber).doubleValue>(state["depth"] as! NSNumber).doubleValue,"A4 actual row ink is in front of its glass \(forward) \(frame.t) \(id)")
                    }
                }
            }
            f.shutdown()
        }
        facts["maximumEffectiveAlphaError"]=alphaError;facts["maximumBlurError"]=blurError
        try (glyphCSV.joined(separator:"\n")+"\n").write(to:output.appendingPathComponent("glyph-alpha-comparison.csv"),atomically:true,encoding:.utf8)
        // A slow bake must not skip the first 45 ms of either the path or appearance clock.
        for forward in [true,false] {
            let f=ModeFlight();f.resize(to:size);f.verificationBeforeServerCommit={Thread.sleep(forTimeInterval:0.045)}
            f.start(toOrganic:forward,avatar:forward ? avatar:(avatar.1,avatar.0),initials:"LL",tokens:tokens(forward),composer:nil,reduceMotion:false)
            let lead=f.verificationInitialLead
            firstCommitLeads.append(lead*1000)
            for token in tokens(forward) {
                if let layer=f.verificationServerLayers[token.id] {
                    let point=centre(layer,at:0)
                    check(hypot(point.x-token.from.midX,point.y-token.from.midY)<1e-6,"B0 first server pose is the actual source at t=0")
                }
            }
            check(lead>=0,"B1 first visible commit starts at t=0 after a 45 ms bake: \(lead)")
            check(!f.sourceOwnerNeedsCommit,"B2 native source and moving copy never overlap at first commit")
            let epoch=f.verificationServerLayers["me"]?.animation(forKey:"mode.server.translation")?.beginTime ?? 0
            for layer in f.verificationRowLayers.values {
                let inkEpoch=layer.animation(forKey:"mode.orrery.appearance")?.beginTime ?? -1
                check(abs(inkEpoch-epoch)<1e-6,"B3 row and position share the final post-bake server epoch")
            }
            f.shutdown()
        }
        facts["firstCommitLeadMS"]=firstCommitLeads
        // D1: an already returned row remains native-owned after an earlier row is archived/reordered.
        var now=2000.0
        let retired=ModeFlight();retired.manualTime={now};retired.resize(to:size)
        retired.start(toOrganic:false,avatar:(avatar.1,avatar.0),initials:"LL",tokens:tokens(false),composer:nil,reduceMotion:false)
        retired.advance(at:1.33)
        let handed=retired.verificationOrreryState(at:1.33).filter {$0["hidden"] as? Bool == true}.map {$0["id"] as! String}
        check(!handed.isEmpty,"D1 fixture has returned native rows")
        now+=1.33
        retired.updateEndpoints(rows:Dictionary(uniqueKeysWithValues:seed.enumerated().map {($0.element.id,rows[$0.offset].offsetBy(dx:0,dy:-32))}),real:Dictionary(uniqueKeysWithValues:tokens(false).map {($0.id,$0.from)}),avatar:(avatar.1,avatar.0))
        for id in handed {check(retired.arrived(id,at:0),"D1 retired row remains native-visible throughout a reorder correction \(id)")}
        now+=0.01
        let afterReorder=retired.activeTokens.map {ModeFlight.Token(id:$0.id,conversation:$0.conversation,from:$0.to,to:$0.from,start:0,absorbed:false)}
        retired.start(toOrganic:true,avatar:avatar,initials:"LL",tokens:afterReorder,composer:nil,reduceMotion:false)
        for state in retired.verificationOrreryState(at:0) where handed.contains(state["id"] as! String) {
            let token=afterReorder.first {$0.id == state["id"] as! String}!
            let actual=NSRectFromString(state["rowFrame"] as! String)
            check(MotionStep.edge(actual,token.from.offsetBy(dx:-3,dy:-1))<0.001,"D9 a new turn takes row ink from its current native position after reorder")
        }
        retired.shutdown()
        // D2: 20 ms after a turn, a fast native admission changes size, position and header/Dock keys.
        var maxVelocityError=0.0
        for forward in [true,false] {
            now=3000
            let f=ModeFlight();f.manualTime={now};f.verificationServerMotion=true;f.resize(to:size)
            f.start(toOrganic:forward,avatar:forward ? avatar:(avatar.1,avatar.0),initials:"LL",tokens:tokens(forward),composer:nil,reduceMotion:false)
            now+=0.54;f.advance(at:0.54)
            f.start(toOrganic:!forward,avatar:forward ? (avatar.1,avatar.0):avatar,initials:"LL",tokens:tokens(!forward),composer:nil,reduceMotion:false)
            now+=0.02;f.advance(at:0.02)
            let prior=Dictionary(uniqueKeysWithValues:f.verificationServerLayers.keys.map {($0,f.verificationPoseVelocity($0,at:0.02))})
            let oldPoints=f.verificationServerLayers.mapValues {centre($0,at:0.02)}
            let changedReal=Dictionary(uniqueKeysWithValues:seed.enumerated().map {($0.element.id,real[$0.offset].insetBy(dx:-7,dy:-4).offsetBy(dx:60,dy:-12))})
            let changedRows=Dictionary(uniqueKeysWithValues:seed.enumerated().map {($0.element.id,rows[$0.offset].offsetBy(dx:4,dy:12))})
            let changedAvatar=(avatar.0.offsetBy(dx:7,dy:0),avatar.1.insetBy(dx:-4,dy:-4))
            f.updateEndpoints(rows:changedRows,real:changedReal,avatar:forward ? (changedAvatar.1,changedAvatar.0):changedAvatar)
            for (id,layer) in f.verificationServerLayers {
                let oldID=id == "me" ? id:(tokens(forward).first {$0.conversation.id == id}?.id ?? id)
                guard let a=prior[oldID],let p=oldPoints[oldID] else {check(false,"D2 stable identity retains old velocity \(id)");continue}
                let b=f.verificationPoseVelocity(id,at:0),q=centre(layer,at:0)
                let error=hypot(a.x-b.x,a.y-b.y);maxVelocityError=max(maxVelocityError,error)
                check(hypot(q.x-p.x,q.y-p.y)<0.5,"D2 endpoint refresh preserves displayed position \(forward) \(id)")
                check(error<max(15,hypot(a.x,a.y)*0.02),"D2 endpoint refresh retains active velocity residual \(forward) \(id): \(error)")
            }
            f.shutdown()
        }
        facts["maximumRefreshVelocityErrorPTPerSecond"]=maxVelocityError
        // D6: change accessibility motion policy in the same process after a translated Orrery carrier.
        let reduced=ModeFlight();reduced.manualTime={4000};reduced.resize(to:size)
        reduced.start(toOrganic:true,avatar:avatar,initials:"LL",tokens:tokens(true),composer:nil,reduceMotion:false)
        reduced.advance(at:reduced.duration+0.01)
        reduced.start(toOrganic:false,avatar:(avatar.1,avatar.0),initials:"LL",tokens:tokens(false),composer:nil,reduceMotion:true)
        let actualAvatar=reduced.verificationGlass[0].1.convert(reduced.verificationGlass[0].1.bounds,to:reduced.view)
        check(MotionStep.edge(actualAvatar,avatar.1)<0.001,"D6 reduce motion clears the permanent carrier's Orrery origin")
        reduced.shutdown()
        // D7: a native endpoint delayed beyond the former hard timeout cannot lose the last visible owner.
        let cold=ModeFlight();cold.manualTime={5000};cold.resize(to:size)
        var owner=false;cold.destinationOwnerVisible={_ in owner}
        cold.start(toOrganic:true,avatar:avatar,initials:"LL",tokens:tokens(true),composer:nil,reduceMotion:false)
        let end=cold.duration
        cold.advance(at:end+1.1)
        check(cold.running && cold.verificationWaitingForOwner && !cold.view.isHidden,"D7 late admission parks the display link and retains its visible owner")
        check(cold.verificationOrreryState(at:end+1.1).allSatisfy {$0["hidden"] as? Bool == false},"D7 no cold planet disappears at the one-second timeout")
        owner=true;cold.destinationDidMount();cold.advance(at:end+1.1)
        check(cold.running,"D7 first native commit keeps the one-frame fence")
        cold.advance(at:end+2.02)
        check(!cold.running && cold.view.isHidden,"D7 native mount wakes and completes the parked handoff")
        cold.shutdown()
        // Native admission checks use real time before CARenderer's future-clock readbacks.
        let content=try windowChecks(output:output,check:check,facts:&facts)
        try contentRender(content,output:output,check:check,facts:&facts)
        try inkRender(output:output,check:check)
        let result:[String:Any]=["checks":checks,"findingCount":failed,"failures":failures,"failureCategories":categories,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round4-verification.json"))
        print("M11.31 round 4: \(checks) checks, \(failed) findings")
        return failed == 0 ? 0:1
    }
    /// Native visibility can change without a host event; the bounded parked probe must close the fence.
    static func silentOwnerBoundary(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let f=ModeFlight();f.manualTime={1000};f.resize(to:CGSize(width:1280,height:820))
        var nativeVisible=false;f.destinationOwnerVisible={_ in nativeVisible}
        let c=MockSeed.make()[0],row=ModeOrreryFlightVerification.rows[0],real=ModeOrreryFlightVerification.real[0]
        f.start(toOrganic:true,avatar:(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar),initials:"LL",tokens:[.init(id:"A",conversation:c,from:row,to:real,start:0,absorbed:false)],composer:nil,reduceMotion:false)
        let time=f.duration+1.1;f.advance(at:time)
        nativeVisible=true
        // No destinationDidMount, layout, store publication or manual frame.
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.25))
        let state=f.verificationOrreryState(at:time)
        let flyingVisible=state.contains {($0["hidden"] as? Bool) == false && (($0["glassOpacity"] as? NSNumber)?.doubleValue ?? 0)>0.99}
        let findings=(flyingVisible && nativeVisible) || f.running ? 1:0
        let result:[String:Any]=["checks":1,"findings":findings,"parked":f.verificationWaitingForOwner,"flyingVisible":flyingVisible,"nativeVisible":nativeVisible,"flightFinished":!f.running,"fallback":"10 Hz, at most 20 parked probes; one native exposure fence"]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("silent-owner-boundary.json"))
        f.shutdown();print("M11.31 silent owner boundary: 1 check, \(findings) open finding")
        return findings == 0 ? 0:1
    }

    private static func centre(_ layer:CALayer,at time:Double)->CGPoint {
        guard let group=layer.animation(forKey:"mode.server.translation") as? CAAnimationGroup else {return layer.position}
        func axis(_ name:String)->Double {
            guard let a=group.animations?.compactMap({$0 as? CAKeyframeAnimation}).first(where:{$0.keyPath == "position."+name}),let values=a.values as? [NSNumber] else {return 0}
            let t=min(Double(values.count-1),max(0,time/group.duration*Double(values.count-1))),i=min(values.count-2,Int(t)),u=t-Double(i)
            return values[i].doubleValue+(values[i+1].doubleValue-values[i].doubleValue)*u
        }
        return CGPoint(x:axis("x")+(0.5-layer.anchorPoint.x)*layer.bounds.width,y:axis("y")+(0.5-layer.anchorPoint.y)*layer.bounds.height)
    }
    private static func velocity(_ layer:CALayer,at time:Double)->CGPoint {
        let a=centre(layer,at:time),b=centre(layer,at:time+1/240)
        return CGPoint(x:(b.x-a.x)*240,y:(b.y-a.y)*240)
    }
    private static func windowChecks(output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) throws -> (fade:CAAnimation?,delay:Double,native:Double) {
        let store=ConversationStore(),size=CGSize(width:1280,height:820)
        let replay=MockReplay(store:store);replay.start(live:false)
        let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:.init(name:"offscreen",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),scale:1,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(plane);plane.frame=root.bounds}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();replay.stopPlayback()}
        var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
        shell.verificationFlightSettle(asOrganic:false);_=workbench.select("A")
        shell.prepareModeSwitch(reason:"m1131d.normie.A")
        shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit()
        now+=0.28;shell.flight.advance(at:0.28)
        let original=shell.verificationContentSessionState
        let initialLease=shell.verificationContentLeaseGeneration
        let start=CACurrentMediaTime();shell.verificationFlightToggle(toOrganic:false)
        let fade=shell.verificationContentPhase
        let values=fade?.values as? [NSNumber] ?? []
        check(shell.verificationTurnSidebarSingleOwner,"C1 resident native sidebar owns material and ink")
        check(shell.verificationHasSidebarProxy == false,"C2 no sidebar bitmap or stationary avatar is baked into body")
        check(values.count>2 && zip(values,values.dropFirst()).allSatisfy {$0.doubleValue<=$1.doubleValue+1e-8},"C3 actual reversible content phase is monotonic")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        check(shell.verificationContentLeaseGeneration == initialLease,"C4 no native mount occurs while both representations contribute")
        check(shell.verificationContentSessionState["photoID"] as? String == original["photoID"] as? String,"C0 a turn never replaces its fixed picture")
        shell.verificationFlightAdmit()
        check(shell.verificationContentSessionState["liveMode"] as? String == original["liveMode"] as? String,"C5 live identity remains fixed until final endpoint")
        check(shell.verificationContentSessionState["oldPicture"] as? Bool == false,"C6 legacy holes and restoreSource are absent")
        check(shell.verificationContentLeaseGeneration == initialLease,"C7 no second admission is queued by a turn")
        let content=(fade:fade as CAAnimation?,delay:0.0,native:0.220)
        facts["turnBodyCommandMS"]=(CACurrentMediaTime()-start)*1000
        now+=0.12;shell.flight.advance(at:0.12);_=workbench.select("B")
        shell.verificationFlightToggle(toOrganic:true)
        check(shell.verificationContentSessionState["photoID"] as? String == original["photoID"] as? String,"C8 selection invalidates next candidate without changing active identity")
        shell.verificationFinishContentSession()
        let selectedEnd=shell.flight.duration;now+=selectedEnd
        shell.flight.advance(at:selectedEnd);shell.flight.advance(at:selectedEnd+shell.flight.presentationInterval)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        check(scene.current == "B","C9 current selection B is applied by normal navigation after frozen presentation ends")
        // A completed reverse starts from the actual source, with no one-frame native F overlap.
        shell.flight.cancel();shell.verificationFlightSettle(asOrganic:true)
        shell.verificationFlightToggle(toOrganic:false)
        check(!shell.flight.sourceOwnerNeedsCommit && !shell.flight.organicSourceAtRest("F",at:0),"B4 reverse first frame has exactly one source/copy owner")
        check(shell.verificationReverseSourcesHidden,"B5 actual native reverse source glass is hidden in the first commit")
        shell.verificationFlightAdmit()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.25))
        // Use the now-admitted production endpoints for the partial-retirement fixture. Initial
        // cold-layout correction is independent and would otherwise postpone every retirement to T.
        let stableTokens=shell.flight.activeTokens,stableAvatar=shell.flight.avatarEndpoints(toOrganic:false)!
        shell.flight.cancel()
        shell.flight.start(toOrganic:false,avatar:stableAvatar,initials:"LL",tokens:stableTokens,composer:nil,reduceMotion:false)
        now+=1.35;shell.flight.advance(at:1.33);shell.flight.advance(at:1.35)
        let returned=shell.flight.verificationOrreryState(at:1.35).filter {$0["hidden"] as? Bool == true}.map {$0["id"] as! String}
        try JSONSerialization.data(withJSONObject:["native":shell.verificationRowDiagnostics,"flight":shell.flight.verificationOrreryState(at:1.35)],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("returned-row-diagnostic.json"))
        check(!returned.isEmpty,"D8 actual sidebar has returned native row owners before archival")
        _=try store.remove(ids:["A"])
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
        // A windowless NSTableView does not materialize new visible cells after reloadData by itself.
        for index in workbench.sidebar.model.rows.indices {_=workbench.sidebar.table.view(atColumn:0,row:index,makeIfNecessary:true)}
        workbench.sidebar.table.layoutSubtreeIfNeeded()
        shell.verificationRefreshFlightEndpoints();shell.flight.advance(at:0)
        try JSONSerialization.data(withJSONObject:["native":shell.verificationRowDiagnostics,"flight":shell.flight.verificationOrreryState(at:0)],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("after-archive-diagnostic.json"))
        for id in returned where id != "A" && id != "header.A" {
            check(shell.verificationFlightNativeOwner(id),"D8 archived predecessor cannot hide an already returned native row \(id)")
        }
        shell.flight.cancel()
        // A real native mount may trail the nominal rail, within the bounded 300 ms safety deadline.
        shell.verificationFlightSettle(asOrganic:false)
        shell.prepareModeSwitch(reason:"m1131d.parked.native")
        shell.verificationFlightToggle(toOrganic:true)
        let late=shell.flight.duration+0.1;now+=late;shell.flight.advance(at:late)
        check(shell.flight.running && !shell.flight.view.isHidden,"D0 actual window retains the carrier before the native deadline")
        shell.verificationFlightAdmit();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.30))
        check(!shell.flight.verificationWaitingForOwner || shell.flight.verificationOrreryState(at:late).contains {$0["hidden"] as? Bool == false},"D0 native mount either wakes the fence or retains the still-unexposed flying owner")
        // The new third column also has a scene admission clock; the offscreen host has no PulseDriver.
        scene.settle();shell.verificationFinishContentSession();shell.verificationRefreshFlightEndpoints()
        // The parked production probe may already have advanced beyond T. Never run the shared clock backwards.
        let settled=max(shell.flight.duration,shell.flight.verificationOwnerFenceState["_last"] ?? 0)
        shell.flight.advance(at:settled+0.02);shell.flight.advance(at:settled+0.04);shell.flight.advance(at:settled+0.06)
        try JSONSerialization.data(withJSONObject:["duration":settled,"fence":shell.flight.verificationOwnerFenceState,"state":shell.flight.debugState,"nativeOwners":shell.verificationFlightNativeOwners,"native":shell.verificationRowDiagnostics,"flight":shell.flight.verificationOrreryState(at:settled+0.04)],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("parked-native-diagnostic.json"))
        func tree(_ view:NSView)->[[String:Any]] {
            var result:[[String:Any]]=[],next:NSView?=view
            while let node=next {
                result.append(["type":String(describing:type(of:node)),"hidden":node.isHidden,"alpha":node.alphaValue,"opacity":node.layer?.opacity ?? -1,"presented":node.layer?.presentation()?.opacity ?? -1,"frame":NSStringFromRect(node.frame),"mask":node.layer?.mask.map{NSStringFromRect($0.bounds)} ?? "none"]);next=node.superview
            }
            return result
        }
        var details:[[String:Any]]=[]
        for column in scene.columns {if let island=column.island {details.append(["id":column.conversation.id,"kind":"header","glass":tree(island.orb.glassView),"ink":tree(island.orb.frontView)])}}
        for (id,item) in scene.dock.items {details.append(["id":id,"kind":"dock","role":String(describing:item.role),"glass":tree(item.glass),"ink":tree(item.decoration.frontView),"bar":tree(item.barFace),"owner":shell.verificationFlightNativeOwner(id)])}
        try JSONSerialization.data(withJSONObject:details,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("parked-native-tree.json"))
        check(!shell.flight.running && shell.verificationFlightNativeOwners,"D0 late actual native owners complete the parked flight")
        // Two commands before queued content work executes must keep the original native destination.
        shell.verificationFlightSettle(asOrganic:false);shell.prepareModeSwitch(reason:"m1131d.double")
        shell.verificationFlightToggle(toOrganic:true);now+=0.28;shell.flight.advance(at:0.28)
        var supersededAdmissions=0;shell.verificationBeforeTurnAdmission={supersededAdmissions+=1}
        shell.verificationFlightToggle(toOrganic:false);shell.verificationFlightToggle(toOrganic:true)
        shell.verificationFlightAdmit()
        check(shell.verificationFlightPresentation["admittedOrganic"] == true,"C double command admits only its final Organic destination")
        check(supersededAdmissions == 0,"C consecutive turns never queue native admission inside a content session")
        shell.verificationBeforeTurnAdmission=nil;shell.flight.cancel()
        return content
    }
    /// Replay the actual opacity command with a zero-cost native batch at its real admission permission.
    /// A hot native batch may finish immediately. Its permission must already be safe for every pixel.
    /// Colored fields expose a discontinuity; glass is absent from this content-only probe.
    private static func contentRender(_ content:(fade:CAAnimation?,delay:Double,native:Double),output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        guard let original=content.fade else {check(false,"C pixels need the production turn opacity command");return}
        var maximumStep=0.0,maximumSwapError=0.0,samples:[[String:Double]]=[]
        for scale:CGFloat in [1,2] {
            let root=CALayer(),native=CALayer(),curtain=CALayer()
            root.isGeometryFlipped=true;root.backgroundColor=NSColor.black.cgColor
            native.frame=CGRect(x:0,y:0,width:96,height:64);native.backgroundColor=NSColor.blue.cgColor
            curtain.frame=native.frame;curtain.backgroundColor=NSColor.green.cgColor;curtain.opacity=1
            root.addSublayer(native);root.addSublayer(curtain)
            let epoch=VerificationClock.renderOrigin
            let fade=original.copy() as! CAAnimation;fade.beginTime=epoch+content.delay
            curtain.add(fade,forKey:"mode.source.turn")
            let renderer=OffscreenRenderer(size:CGSize(width:96,height:64),host:root,scale:scale)
            let oracle=CALayer(),oracleNative=CALayer(),oracleCurtain=CALayer()
            oracleNative.frame=native.frame;oracleNative.backgroundColor=NSColor.blue.cgColor
            oracleCurtain.frame=curtain.frame;oracleCurtain.backgroundColor=NSColor.green.cgColor;oracleCurtain.opacity=1
            oracle.addSublayer(oracleNative);oracle.addSublayer(oracleCurtain)
            oracleCurtain.add(fade,forKey:"mode.source.turn")
            let oracleRenderer=OffscreenRenderer(size:CGSize(width:96,height:64),host:oracle,scale:scale)
            var swapError=0.0
            var previous=0.0,monotonic=true,largest=0.0,swapped=false
            for i in 0...72 {
                let time=Double(i)/240
                if time>=content.native && !swapped {
                    CATransaction.begin();CATransaction.setDisableActions(true);native.backgroundColor=NSColor.green.cgColor;CATransaction.commit();swapped=true
                }
                let bytes=renderer.render(at:epoch+time),index=(Int(32*scale)*renderer.w+Int(48*scale))*4
                let alpha=Double(bytes[index+1])/255
                let expected=Double(oracleRenderer.render(at:epoch+time)[index+1])/255
                swapError=max(swapError,abs(alpha-expected))
                if i>0 {largest=max(largest,abs(alpha-previous));if alpha+1/255<previous {monotonic=false}}
                previous=alpha;samples.append(["scale":Double(scale),"time":time,"alpha":alpha,"authoredAlpha":expected])
            }
            maximumStep=max(maximumStep,largest);maximumSwapError=max(maximumSwapError,swapError)
            check(swapError<=1/255,"C native ownership swap cannot change content pixels \(scale)x: \(swapError)")
            check(monotonic,"C pixels have monotonic content alpha \(scale)x")
            check(largest<=0.065,"C native swap has no one-frame content hard cut \(scale)x: \(largest)")
            check(previous>0.999,"C content crossfade reaches the requested destination \(scale)x")
        }
        facts["maximumContentAlphaStep240Hz"]=maximumStep
        facts["maximumNativeSwapAlphaError"]=maximumSwapError
        try JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("content-alpha-readback.json"))
    }

    private static func inkRender(output:URL,check:(Bool,String)->Void) throws {
        let seed=MockSeed.make(),row=ModeOrreryFlightVerification.rows[0],real=ModeOrreryFlightVerification.real[0]
        for scale:CGFloat in [1,2] {
            let f=ModeFlight();f.manualTime={1000};f.resize(to:CGSize(width:1280,height:820))
            f.start(toOrganic:true,avatar:(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar),initials:"LL",tokens:[.init(id:"A",conversation:seed[0],from:row,to:real,start:0,absorbed:false)],composer:nil,reduceMotion:false)
            for time in [0.0125,0.0458333333333,0.08] {
                f.sample(at:time,profile:ModeOrreryFlightVerification.profile)
                guard let actual=f.verificationRowLayers["A"],let bitmap=actual.sublayers?.first else {check(false,"A5 actual owned row bitmap is mounted");continue}
                func render(_ depth:CGFloat)->[UInt8] {
                    let root=CALayer();root.isGeometryFlipped=true;root.backgroundColor=NSColor.black.cgColor
                    let ink=CALayer();ink.bounds=actual.bounds;ink.position=CGPoint(x:32,y:32);ink.opacity=actual.opacity;ink.zPosition=depth;ink.transform=actual.transform
                    let image=CALayer();image.frame=bitmap.frame;image.contents=bitmap.contents;image.contentsScale=bitmap.contentsScale;ink.addSublayer(image)
                    let glass=CALayer();glass.frame=CGRect(x:24,y:24,width:16,height:16);glass.backgroundColor=NSColor(white:0.2,alpha:1).cgColor;glass.zPosition=7
                    root.addSublayer(glass);root.addSublayer(ink)
                    let renderer=OffscreenRenderer(size:CGSize(width:64,height:64),host:root,scale:scale)
                    return renderer.render(at:VerificationClock.renderOrigin)
                }
                // The oracle only changes ordering; it never recaptures or redraws the native glyph.
                check(render(actual.zPosition) == render(7.01),"A5 owned bitmap readback preserves board front-to-back order \(scale)x \(time)")
            }
            f.shutdown()
        }
    }
}
#endif
