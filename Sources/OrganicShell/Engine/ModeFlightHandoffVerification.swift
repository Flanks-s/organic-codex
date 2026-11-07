#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Exercises the production advance/retirement path, real destination views and live mutations.
@MainActor enum ModeFlightHandoffVerification {
    static func run(to output: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[[String:Any]]=[]
        func check(_ value: Bool,_ name: String) { checks+=1;if !value { failures.append(name);print("FAIL: "+name) } }
        let size=CGSize(width:1280,height:820),profile=ModeOrreryFlightVerification.profile
        let rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real
        let seed=MockSeed.make()
        func plan(_ forward: Bool,_ shift: CGFloat = 0) -> [ModeFlight.Token] {
            (0..<6).map { i in
                let end=real[i].offsetBy(dx:shift,dy:shift/3),row=rows[i].offsetBy(dx:0,dy:shift/2)
                return .init(id:i<3 ? "header."+seed[i].id:seed[i].id,conversation:seed[i],from:forward ? row:end,to:forward ? end:row,start:0.08+Double(i)*0.04,absorbed:!forward)
            }
        }
        if !ModeFlight.orreryEnabled {
            let f=ModeFlight();f.manualTime={1000};f.resize(to:size)
            f.start(toOrganic:false,avatar:(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar),initials:"LL",tokens:plan(false),composer:nil,reduceMotion:false)
            check(plan(false).allSatisfy { f.arrived($0.id,at:0) },"legacy absorbed tokens preserve immediate arrived semantics")
            f.shutdown()
        } else {
            for forward in [true,false] {
                for cut in [0.08,0.28,0.54,0.95,1.30] {
                    var now=1000.0
                    let f=ModeFlight();f.manualTime={now};f.verificationServerMotion=true;f.resize(to:size)
                    let avatar=forward ? (ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar):(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar)
                    f.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan(forward),composer:nil,reduceMotion:false)
                    let objects=f.verificationGlass.map { ObjectIdentifier($0.1) }
                    var before:[String:CGRect]=[:],after:[String:CGRect]=[:]
                    f.onExposureSample={before[$0.id]=$0.now};f.advance(at:cut)
                    now+=cut;f.onExposureSample={after[$0.id]=$0.now}
                    f.start(toOrganic:!forward,avatar:(avatar.1,avatar.0),initials:"LL",tokens:plan(!forward),composer:nil,reduceMotion:false)
                    check(objects == f.verificationGlass.map {ObjectIdentifier($0.1)},"native glass survives turn \(forward) \(cut)")
                    for (id,rect) in before { check(after[id].map {MotionStep.edge(rect,$0)<1e-7} ?? false,"continuous turn \(forward) \(cut) \(id)") }
                    check(abs(f.duration-cut)<1e-7,"turn uses remaining original phase \(forward) \(cut)")
                    check(f.verificationServerLayers.values.allSatisfy {$0.animation(forKey:"mode.server.translation") != nil},"turned paths remain on render server")
                    let turnDuration=f.duration
                    f.advance(at:turnDuration+0.001)
                    check(!f.running && f.view.isHidden,"production advance retires turned leg \(forward) \(cut)")
                    facts.append(["forward":forward,"cut":cut,"remaining":turnDuration])
                    f.shutdown()
                }
                // Actual mounted target views own the destination, including late/cold admission.
                var now=2000.0,admitted=false
                let f=ModeFlight();f.manualTime={now};f.verificationServerMotion=true;f.resize(to:size)
                let host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size));host.wantsLayer=true
                let native=plan(forward).map { token -> NSView in
                    let v=NormieSidebarIdentity(frame:token.to);v.identity=NormieDrawing.identity(token.conversation);v.isHidden=true;host.addSubview(v);return v
                }
                let avatar=forward ? (ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar):(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar)
                f.destinationOwnerVisible={ id in
                    if id == "me" { return admitted }
                    guard let i=plan(forward).firstIndex(where:{$0.id == id}) else {return false}
                    return admitted && !native[i].isHidden && native[i].superview === host && native[i].alphaValue == 1
                }
                f.onFrame={ time in
                    guard admitted else {return}
                    for (i,t) in plan(forward).enumerated() {native[i].isHidden = !f.arrived(t.id,at:time)}
                }
                f.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan(forward),composer:nil,reduceMotion:false)
                f.sample(at:0,profile:profile)
                let initial=f.verificationOrreryState(at:0)
                check(initial.allSatisfy { $0["rowBitmapReady"] as? Bool == true },"glyph is baked before first presentation")
                for (i,state) in initial.enumerated() {
                    let rect=NSRectFromString(state["rowFrame"] as! String)
                    check(MotionStep.edge(rect,rows[i].offsetBy(dx:-3,dy:-1))<1e-8,"real sidebar glyph anchor \(forward) \(i)")
                    check(state["rowStationary"] as? Bool == true,"row stays outside moving carrier through server stall")
                }
                // A stalled main thread can cross the whole return stage without moving the row anchor.
                f.advance(at:1.07)
                for state in f.verificationOrreryState(at:1.07) {check(state["rowStationary"] as? Bool == true,"stalled return glyph has fixed window coordinates")}
                let end=f.duration
                f.advance(at:end+0.1)
                check(f.running && !f.view.isHidden,"cold admission preserves final visible owner")
                check(f.verificationOrreryState(at:end+0.1).allSatisfy { !($0["hidden"] as! Bool) && (($0["glassOpacity"] as! CGFloat)>0.99 || (($0["rowOpacity"] as? NSNumber)?.doubleValue ?? 0)>0.99) },"all cold endpoint owners remain visibly painted past T")
                admitted=true;f.advance(at:end+0.2)
                check(f.running,"native ownership crosses one compositor commit before flight retires")
                check(native.allSatisfy {!$0.isHidden},"real mounted native endpoints are exposed")
                f.advance(at:end+0.2+1/60)
                check(!f.running && native.allSatisfy {!$0.isHidden},"advance to finish leaves actual visible owners")
                f.shutdown();now+=10

                // Resize while flying, then reverse despite a different geometry/key set.
                let r=ModeFlight();r.manualTime={now};r.verificationServerMotion=true;r.resize(to:size)
                r.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan(forward),composer:nil,reduceMotion:false)
                var old:[String:CGRect]=[:],new:[String:CGRect]=[:]
                r.onExposureSample={old[$0.id]=$0.now};r.sample(at:0.54,profile:profile);now+=0.54
                let shifted=plan(forward,100)
                r.onExposureSample={new[$0.id]=$0.now}
                r.resize(to:CGSize(width:1380,height:880))
                r.updateEndpoints(rows:Dictionary(uniqueKeysWithValues:shifted.map {($0.conversation.id,forward ? $0.from:$0.to)}),real:Dictionary(uniqueKeysWithValues:shifted.map {($0.id,forward ? $0.to:$0.from)}),avatar:avatar)
                new=[:];r.sample(at:r.elapsed,profile:profile)
                for (id,rect) in old {check(new[id].map {MotionStep.edge(rect,$0)<1e-7} ?? false,"resize carries actual pose \(id)")}
                check(r.activeTokens.allSatisfy { token in shifted.first(where:{$0.id == token.id}).map {MotionStep.edge($0.to,token.to)<1e-8} ?? false },"resize refreshes every production destination")
                for token in shifted {
                    let group=r.verificationServerLayers[token.id]?.animation(forKey:"mode.server.translation") as? CAAnimationGroup
                    let channels=group?.animations?.compactMap {$0 as? CAKeyframeAnimation} ?? []
                    let x=(channels.first(where:{$0.keyPath == "position.x"})?.values?.last as? NSNumber)?.doubleValue
                    let y=(channels.first(where:{$0.keyPath == "position.y"})?.values?.last as? NSNumber)?.doubleValue
                    check(x.flatMap { xx in y.map {hypot(xx+(0.5-(r.verificationServerLayers[token.id]?.anchorPoint.x ?? 0))*1380-token.to.midX,$0+(0.5-(r.verificationServerLayers[token.id]?.anchorPoint.y ?? 0))*880-token.to.midY)<1e-7} } ?? false,"resized CA path lands at refreshed endpoint \(token.id)")
                }
                old=new;new=[:]
                r.start(toOrganic:!forward,avatar:(avatar.1,avatar.0),initials:"LL",tokens:Array(plan(!forward,100).dropLast()),composer:nil,reduceMotion:false)
                check(abs(r.duration-0.54)<1e-7,"geometry and ID mismatch cannot restart complete leg")
                for (id,rect) in old where id != "planet."+plan(forward).last!.id {check(new[id].map {MotionStep.edge(rect,$0)<1e-7} ?? false,"resize turn retains pose \(id)")}
                check(r.activeTokens.count == 5,"removed endpoint is not resurrected during turn")
                r.advance(at:r.duration+0.001);check(!r.running,"resized turn reaches new endpoints and finishes")
                r.shutdown()

                let semantic=ModeFlight();semantic.manualTime={now};semantic.verificationServerMotion=true;semantic.resize(to:size)
                let endpoint=OrbComponent(id:"semantic.endpoint")
                endpoint.configure(makeOrbConfiguration(seed[0],drawingSize:56,backingScale:2,reduceMotion:true,ambient:false,isKeyWindow:true))
                semantic.endpointOrb={ id in id == "header."+seed[0].id || id == seed[0].id ? endpoint:nil }
                semantic.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan(forward),composer:nil,reduceMotion:false)
                let nativeIDs=semantic.verificationGlass.map {ObjectIdentifier($0.1)}
                endpoint.configure(makeOrbConfiguration(seed[0],drawingSize:44,backingScale:2,reduceMotion:true,ambient:false,isKeyWindow:true))
                semantic.sample(at:0.54,profile:profile)
                check(nativeIDs == semantic.verificationGlass.map {ObjectIdentifier($0.1)},"semantic admission refresh retains warmed native glass")
                check(semantic.verificationOrreryState(at:0.54).allSatisfy {$0["endpointConfigurationMatches"] as? Bool == true},"semantic drawing still matches actual endpoint after retained-material refresh")
                let semPlan=plan(forward)
                var relocated=Dictionary(uniqueKeysWithValues:semPlan.map {($0.id,forward ? $0.to:$0.from)})
                relocated[seed[0].id]=relocated.removeValue(forKey:semPlan[0].id)
                semantic.updateEndpoints(rows:Dictionary(uniqueKeysWithValues:semPlan.map {($0.conversation.id,forward ? $0.from:$0.to)}),real:relocated,avatar:avatar)
                check(semantic.activeTokens.first?.id == seed[0].id,"resize can move the same conversation from header to Dock")
                check(nativeIDs == semantic.verificationGlass.map {ObjectIdentifier($0.1)},"header to Dock retarget preserves native material identity")
                semantic.shutdown();endpoint.dispose()

                if forward {
                    let c=ModeFlight();c.manualTime={now};c.verificationServerMotion=true;c.resize(to:size)
                    c.start(toOrganic:true,avatar:avatar,initials:"LL",tokens:plan(true),composer:(CGRect(x:376,y:686,width:768,height:120),CGRect(x:78,y:740,width:1004,height:48),0),reduceMotion:false)
                    var beforeComposer: CGRect?,afterComposer: CGRect?
                    c.onExposureSample={if $0.id == "composer" {beforeComposer=$0.now}}
                    c.sample(at:0.28,profile:profile);now+=0.28
                    c.onExposureSample={if $0.id == "composer" {afterComposer=$0.now}}
                    let shifted=plan(true,80)
                    c.updateEndpoints(rows:Dictionary(uniqueKeysWithValues:shifted.map {($0.conversation.id,$0.from)}),real:Dictionary(uniqueKeysWithValues:shifted.map {($0.id,$0.to)}),avatar:avatar)
                    check(beforeComposer.flatMap { a in afterComposer.map {MotionStep.edge(a,$0)<1e-8} } ?? false,"resize keeps deferred legacy composer phase")
                    c.start(toOrganic:false,avatar:(avatar.1,avatar.0),initials:"LL",tokens:plan(false,80),composer:nil,reduceMotion:false)
                    check(c.verificationGlass.first(where:{$0.0 == "composer"})?.1.isHidden == true,"turn cancels outgoing legacy composer as before")
                    c.shutdown()
                }

                // Mutation cancels stale identities immediately; it must not paint a recycled row.
                let d=ModeFlight();d.manualTime={now};d.resize(to:size)
                var live=Set(seed.map(\.id));d.conversationIsLive={live.contains($0.id)}
                d.start(toOrganic:forward,avatar:avatar,initials:"LL",tokens:plan(forward),composer:nil,reduceMotion:false)
                live.remove(seed[0].id);seed[1].archived=true
                d.advance(at:0.54)
                check(d.activeTokens.count == 4 && !d.activeTokens.contains(where:{$0.conversation === seed[0] || $0.conversation === seed[1]}),"deleted and archived tokens release obsolete row ownership")
                seed[1].archived=false;d.shutdown()
            }
            stalledRowChecks(output:output,check:check)
            try windowPresentationChecks(check:check)
        }
        let result:[String:Any] = ["checks":checks,"failures":failures,"turns":facts,"legacy":!ModeFlight.orreryEnabled]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("handoff-verification.json"))
        print("M11.31 round 2: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }

    /// Borrow production row geometry and its actual parent transform/CA path. No main-thread
    /// sample is allowed between these render-server frames across the return glyph stage.
    private static func stalledRowChecks(output: URL,check:(Bool,String)->Void) {
        for scale: CGFloat in [1,2] {
            let f=ModeFlight();f.manualTime={1000};f.verificationServerMotion=true
            f.resize(to:CGSize(width:1280,height:820))
            let seed=MockSeed.make(),rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real
            let tokens=(0..<6).map { i in ModeFlight.Token(id:seed[i].id,conversation:seed[i],from:real[i],to:rows[i],start:0,absorbed:true) }
            f.start(toOrganic:false,avatar:(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar),initials:"LL",tokens:tokens,composer:nil,reduceMotion:false)
            f.sample(at:0.70,profile:ModeOrreryFlightVerification.profile)
            guard let row=f.verificationRowLayers[tokens[5].id],let carrier=f.verificationServerLayers[tokens[5].id] else {check(false,"stalled row layers exist");continue}
            let root=CALayer();root.isGeometryFlipped=true;root.backgroundColor=NSColor.black.cgColor
            let marker=CALayer();marker.bounds=row.bounds;marker.position=row.position;marker.anchorPoint=row.anchorPoint;marker.transform=row.transform
            let red=CALayer();red.frame=CGRect(x:4,y:4,width:8,height:8);red.backgroundColor=NSColor.red.cgColor;marker.addSublayer(red)
            if row.superlayer === carrier {
                let parent=CALayer();parent.bounds=carrier.bounds;parent.position=carrier.position;parent.anchorPoint=carrier.anchorPoint;parent.transform=carrier.transform
                if let animation=carrier.animation(forKey:"mode.server.translation") {parent.add(animation,forKey:"mode.server.translation")}
                parent.addSublayer(marker);root.addSublayer(parent)
            } else {root.addSublayer(marker)}
            let renderer=OffscreenRenderer(size:CGSize(width:1280,height:820),host:root,scale:scale)
            for time in [1.08,1.16] {
                let bytes=renderer.render(at:1000+time)
                var sx=0.0,sy=0.0,n=0.0
                for y in 0..<renderer.h {for x in 0..<renderer.w {let i=(y*renderer.w+x)*4
                    if bytes[i+2]>100 && bytes[i+1]<20 {sx+=Double(x);sy+=Double(y);n+=1}
                }}
                let expected=CGPoint(x:rows[5].midX-3,y:rows[5].midY-1)
                let error=n>0 ? hypot(sx/n/scale-expected.x,sy/n/scale-expected.y):Double.infinity
                check(error<1,"actual CA row stays at its native glyph anchor through stalled return \(scale)x \(time): \(error)")
                Offscreen.write(renderer.image(bytes),output.appendingPathComponent("stalled-row-\(Int(scale))x-\(Int(time*1000)).png"))
            }
            f.shutdown()
        }
    }

    private static func windowPresentationChecks(check:(Bool,String)->Void) throws {
        for forward in [true,false] {
            for cut in [0.08,0.28,0.54,0.95,1.30] {
                let store=ConversationStore(),size=CGSize(width:1280,height:820)
                let mock=MockReplay(store:store);mock.start(live:false)
                let sessions=NativeTranscriptSessions(store:store)
                let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
                scene.ambient=false;scene.manualSettle=true
                let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
                for v in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {v.frame=root.bounds;root.addSubview(v)}
                let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
                _=workbench.composerForHandoff();scene.install();scene.settle()
                let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
                var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
                shell.verificationFlightSettle(asOrganic:!forward)
                shell.prepareModeSwitch(reason:"m1131b.fixture")
                shell.verificationFlightToggle(toOrganic:forward)
                let openingDuration=shell.flight.duration
                if cut>=0.95 {shell.verificationFlightAdmit()}
                shell.flight.advance(at:cut);now+=cut
                shell.verificationFlightToggle(toOrganic:!forward)
                let immediate=shell.verificationFlightPresentation
                check(immediate["organic"] == !forward,"turn changes requested presentation before deferred native admission \(forward) \(cut)")
                shell.verificationFlightAdmit()
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.18))
                let state=shell.verificationFlightPresentation
                check(state["organic"] == !forward && state["pending"] == false && (shell.verificationContentSessionState["active"] as? Bool == true || state["admittedOrganic"] == !forward),"fixed live/photo presentation follows requested turn \(forward) \(cut)")
                if cut == 0.54 {
                    now+=0.04;shell.flight.advance(at:0.04)
                    shell.verificationFlightToggle(toOrganic:forward)
                    shell.verificationFlightAdmit()
                    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.18))
                    let resumed=shell.verificationFlightPresentation
                    check(resumed["admittedOrganic"] == forward && resumed["pending"] == false,"native presentation follows second rapid turn \(forward)")
                    check(abs(shell.flight.duration-(openingDuration-cut+0.04))<0.05,"second native turn keeps original flight phase \(forward)")
                }
                let duration=shell.flight.duration
                for i in 0...Int(ceil((duration+0.15)*120)) {shell.flight.advance(at:Double(i)/120)}
                // Endpoint admission is deliberately outside the display-link transaction. Let its
                // real commit job run, then cross the existing native exposure fence with advance.
                for i in 1...4 {
                    RunLoop.main.run(until:Date(timeIntervalSinceNow:shell.flight.presentationInterval*1.1))
                    shell.flight.advance(at:duration+0.15+Double(i)*shell.flight.presentationInterval*1.1)
                }
                if shell.flight.running {
                    let diagnostic:[String:Any]=["forward":forward,"cut":cut,"native":shell.verificationRowDiagnostics,"flight":shell.flight.verificationOrreryState(at:duration+0.15)]
                    if let data=try? JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8) {print("HANDOFF_DIAGNOSTIC "+text)}
                }
                check(!shell.flight.running,"real native owners permit production finish \(forward) \(cut)")
                check(shell.verificationFlightNativeOwners,"actual native endpoints remain visible after turn \(forward) \(cut)")
                shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();mock.stopPlayback()
            }
        }
    }
}
#endif
