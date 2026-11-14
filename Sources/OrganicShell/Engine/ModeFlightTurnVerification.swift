#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Third-round regressions use the production clock, carriers, CA commands and advance/finish path.
@MainActor enum ModeFlightTurnVerification {
    static func run(to output: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[[String:Any]]=[]
        var maximumGap=0.0,maximumStepRatio=0.0
        func check(_ value: Bool,_ name: String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let size=CGSize(width:1280,height:820),seed=MockSeed.make()
        let rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real
        let avatar=(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar)
        let profile=DisplayProfile(name:"60Hz",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
        func plan(_ forward: Bool)->[ModeFlight.Token] {(0..<6).map {i in
            .init(id:i<3 ? "header."+seed[i].id:seed[i].id,conversation:seed[i],from:forward ? rows[i]:real[i],to:forward ? real[i]:rows[i],start:0,absorbed:!forward)
        }}
        func frames(_ flight: ModeFlight,_ time: Double)->[String:CGRect] {
            var result:[String:CGRect]=[:];flight.onExposureSample={result[$0.id]=$0.now}
            flight.sample(at:time,profile:profile);flight.onExposureSample=nil;return result
        }
        for forward in [true,false] {
            for cut in [0.08,0.28,0.54,0.95,1.30] {
                var now=1000.0
                let f=ModeFlight();f.manualTime={now};f.verificationServerMotion=true;f.resize(to:size)
                let trip=forward ? avatar:(avatar.1,avatar.0)
                f.start(toOrganic:forward,avatar:trip,initials:"LL",tokens:plan(forward),composer:nil,reduceMotion:false)
                _=frames(f,max(0,cut-0.1))
                // No main-thread sample during the artificial stall. The compositor still reaches cut.
                Thread.sleep(forTimeInterval:0.1);now+=cut
                let expected=Dictionary(uniqueKeysWithValues:plan(forward).enumerated().map {i,t in
                    (t.id,ModeOrreryFlight.Plan(forward:forward,row:rows[i],real:real[i],rank:i,lastRank:5,avatarFrom:trip.0,avatarTo:trip.1).pose(at:cut).rect)
                })
                let oldPaths=f.verificationServerLayers
                let oldLL=oldPaths["me"].flatMap {serverCentre($0,at:cut)}
                var prior:[String:CGPoint]=[:],velocity:[String:CGPoint]=[:]
                for t in plan(forward) {
                    guard let layer=oldPaths[t.id] else {continue}
                    prior[t.id]=serverCentre(layer,at:cut)
                    if let a=serverCentre(layer,at:max(0,cut-1/240)),let b=prior[t.id] {velocity[t.id]=CGPoint(x:(b.x-a.x)*240,y:(b.y-a.y)*240)}
                }
                f.start(toOrganic:!forward,avatar:(trip.1,trip.0),initials:"LL",tokens:plan(!forward),composer:nil,reduceMotion:false)
                let turned=frames(f,0)
                check(oldLL.flatMap {a in turned["me"].map {hypot(a.x-$0.midX,a.y-$0.midY)<0.5}} ?? false,"A LL uses the displayed server pose after a 100 ms stall")
                for t in plan(forward) {
                    guard let a=prior[t.id],let b=turned["planet."+t.id],let e=expected[t.id] else {check(false,"turn owns every live planet");continue}
                    maximumGap=max(maximumGap,hypot(a.x-b.midX,a.y-b.midY))
                    check(hypot(a.x-b.midX,a.y-b.midY)<0.5,"A server pose survives 100 ms stall \(forward) \(cut) \(t.id)")
                    check(hypot(b.midX-e.midX,b.midY-e.midY)<0.001,"A turn uses current server time, not last main frame")
                    if let layer=f.verificationServerLayers[t.id],let c=serverCentre(layer,at:1/240),let v=velocity[t.id] {
                        // The first new frame stays within one ordinary 60 Hz displacement.
                        let step=hypot(c.x-a.x,c.y-a.y),budget=max(0.5,hypot(v.x,v.y)/60*1.15)
                        maximumStepRatio=max(maximumStepRatio,step/budget)
                        if hypot(v.x,v.y)>50 && step>0.01 {
                            let alignment=((c.x-a.x)*v.x+(c.y-a.y)*v.y)/(step*hypot(v.x,v.y))
                            check(alignment>0.2,"A first turned frame retains incoming velocity before deceleration")
                        }
                        check(step<=budget,"A first turned server frame is continuous \(forward) \(cut) \(t.id): \(step)/\(budget)")
                    }
                }
                facts.append(["direction":forward,"cut":cut,"stallMS":100])
                f.advance(at:f.duration+0.001);check(!f.running,"A production advance finishes the turn")
                f.shutdown()
            }
            var now=2000.0
            let f=ModeFlight();f.manualTime={now};f.verificationServerMotion=true;f.resize(to:size)
            f.start(toOrganic:forward,avatar:forward ? avatar:(avatar.1,avatar.0),initials:"LL",tokens:plan(forward),composer:nil,reduceMotion:false)
            // A carrier has one absolute position, local geometry, and no counter-transform to race AppKit.
            for (id,layer) in f.verificationServerLayers {
                let group=layer.animation(forKey:"mode.server.translation") as? CAAnimationGroup
                let commands=group?.animations?.compactMap {$0 as? CAKeyframeAnimation} ?? []
                check(commands.contains {$0.keyPath == "position.x" && !$0.isAdditive} && CATransform3DIsIdentity(layer.transform),"B absolute point carrier has no additive first-frame counter \(id)")
            }
            let before=frames(f,0.54);now+=0.54
            let resized=Dictionary(uniqueKeysWithValues:plan(forward).map {t in
                let r=forward ? t.to:t.from
                return (t.id,CGRect(x:r.minX+75,y:r.minY-30,width:r.width+24,height:r.height+12))
            })
            let resizedRows=Dictionary(uniqueKeysWithValues:plan(forward).map {t in
                let r=forward ? t.from:t.to
                return (t.conversation.id,CGRect(x:r.minX+10,y:r.minY-10,width:r.width+8,height:r.height+4))
            })
            let largeAvatar=(CGRect(x:avatar.0.minX+20,y:avatar.0.minY,width:avatar.0.width+8,height:avatar.0.height+8),CGRect(x:avatar.1.minX,y:avatar.1.minY-20,width:avatar.1.width+24,height:avatar.1.height+24))
            f.updateEndpoints(rows:resizedRows,real:resized,avatar:forward ? largeAvatar:(largeAvatar.1,largeAvatar.0))
            let after=frames(f,0)
            for (id,r) in before {check(after[id].map {MotionStep.edge(r,$0)<0.001} ?? false,"E2 signed size delta preserves pose \(id)")}
            f.shutdown()
        }
        // Partial retirement must stay terminal during same-direction endpoint refresh.
        var now=3000.0
        let f=ModeFlight();f.manualTime={now};f.verificationServerMotion=true;f.resize(to:size)
        f.start(toOrganic:true,avatar:avatar,initials:"LL",tokens:plan(true),composer:nil,reduceMotion:false)
        f.advance(at:1.30)
        let retired=Set(f.verificationOrreryState(at:1.30).filter {$0["hidden"] as? Bool == true}.map {$0["id"] as! String})
        check(!retired.isEmpty,"E3 fixture has partially handed-off native owners")
        now+=1.30
        f.updateEndpoints(rows:Dictionary(uniqueKeysWithValues:plan(true).map {($0.conversation.id,$0.from)}),real:Dictionary(uniqueKeysWithValues:plan(true).map {($0.id,$0.to.offsetBy(dx:80,dy:10))}),avatar:avatar)
        f.advance(at:0)
        check(f.verificationOrreryState(at:0).filter {retired.contains($0["id"] as! String)}.allSatisfy {$0["hidden"] as? Bool == true},"E3 resize cannot resurrect retired flight glass")
        f.shutdown()
        let filtered=ModeFlight();filtered.manualTime={4000};filtered.resize(to:size)
        var visible=Set(seed.map(\.id));filtered.destinationExists={visible.contains($0)}
        filtered.destinationOwnerVisible={_ in false}
        filtered.start(toOrganic:false,avatar:(avatar.1,avatar.0),initials:"LL",tokens:plan(false),composer:nil,reduceMotion:false)
        visible.remove(seed[0].id);filtered.advance(at:0.54)
        check(!filtered.activeTokens.contains {$0.conversation === seed[0]},"E1 filtered target releases its flight owner")
        filtered.advance(at:filtered.duration+1.1)
        check(filtered.running && filtered.verificationWaitingForOwner && !filtered.view.isHidden,"E1 unavailable admission parks without withdrawing its last owner")
        filtered.shutdown()
        // Native ink owns the visible contribution while the flying carrier crosses its retirement fence.
        let ink=ModeFlight();ink.manualTime={5000};ink.verificationServerMotion=true;ink.resize(to:size)
        var admitted=false;ink.destinationOwnerVisible={_ in admitted}
        ink.start(toOrganic:false,avatar:(avatar.1,avatar.0),initials:"LL",tokens:plan(false),composer:nil,reduceMotion:false)
        let end=ink.duration
        ink.advance(at:end+0.05);admitted=true;ink.advance(at:end+0.10)
        check(ink.verificationOrreryState(at:end+0.10).allSatisfy {($0["rowHidden"] as? Bool) == false && (($0["rowOpacity"] as? NSNumber)?.doubleValue ?? 1)<0.01 && $0["nativeOwnerVisible"] as? Bool == true},"D/E7 native row ink has one visible contribution during the handoff fence")
        seed[0].identitySymbol="saturn";seed[0].identityTint="gold"
        ink.advance(at:end+0.105)
        check(ink.verificationOrreryState(at:end+0.105).allSatisfy {$0["rowIdentityMatches"] as? Bool == true},"E6 live identity/tint replaces cached return bitmap")
        let rowLayer=ink.verificationRowLayers[plan(false)[0].id]
        func pixels()->Data? {
            guard let contents=rowLayer?.sublayers?.first?.contents ?? rowLayer?.contents else {return nil}
            return (contents as! CGImage).dataProvider?.data as Data?
        }
        let oldPixels=pixels();seed[0].identityTint="cyan";ink.advance(at:end+0.11)
        check(ink.verificationOrreryState(at:end+0.11).allSatisfy {$0["rowIdentityMatches"] as? Bool == true} && pixels() != oldPixels,"E6 tint-only mutation rebakes actual return ink pixels")
        ink.shutdown();seed[0].identitySymbol=nil;seed[0].identityTint=nil
        for scale:CGFloat in [1,2] {
            let host=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:1280,height:820));host.wantsLayer=true
            let stage=ModeFlightGlyphStage(conversation:seed[0],in:host)
            var pose=ModeOrreryFlight.Plan(forward:true,row:rows[0],real:real[0],rank:0,lastRank:5,avatarFrom:avatar.0,avatarTo:avatar.1).pose(at:0)
            stage.refresh(conversation:seed[0],scale:scale)
            stage.sample(pose,row:rows[0]);stage.line.needsDisplay=true;stage.line.displayIfNeeded()
            check(stage.bitmap.contents != nil && stage.bitmap.superlayer === stage.line.layer,"D eager ink survives AppKit first display \(scale)x")
            check(stage.line.layer?.opacity == 1 && !stage.line.isHidden,"D first departure glyph stays fully bright")
            pose.row=0.5;stage.sample(pose,row:rows[0])
            check(stage.line.layer?.filters?.count == 1,"D ink owns exactly one Gaussian")
            stage.reset()
        }
        // Keep live-clock content admission ahead of CARenderer's deliberately future virtual clock.
        let windowMetrics=try windowChecks(check:check)
        try carrierRenderChecks(output:output,check:check)
        let result:[String:Any]=["checks":checks,"failures":failures,"stalls":facts,"maximumServerGapPT":maximumGap,"maximumFirstStepBudgetRatio":maximumStepRatio,"window":windowMetrics]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("turn-verification.json"))
        print("M11.31 round 3: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    private static func carrierRenderChecks(output: URL,check:(Bool,String)->Void) throws {
        let size=CGSize(width:1280,height:820),seed=MockSeed.make()
        var readbacks:[[String:Any]]=[]
        let row=ModeOrreryFlightVerification.rows[0],real=ModeOrreryFlightVerification.real[0]
        for scale:CGFloat in [1,2] {for forward in [true,false] {
            let epoch=VerificationClock.renderOrigin
            var clock=epoch
            let f=ModeFlight();f.manualTime={clock};f.verificationServerMotion=true;f.resize(to:size)
            let avatar=(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar)
            f.start(toOrganic:forward,avatar:forward ? avatar:(avatar.1,avatar.0),initials:"LL",tokens:[.init(id:"A",conversation:seed[0],from:forward ? row:real,to:forward ? real:row,start:0,absorbed:!forward)],composer:nil,reduceMotion:false)
            guard let actual=f.verificationServerLayers["A"],let glass=f.verificationGlass.first(where:{$0.0 == "planet.A"})?.1,
                  let plane=actual.delegate as? NSView else {check(false,"B actual native carrier is available");continue}
            let root=CALayer();root.isGeometryFlipped=true;root.backgroundColor=NSColor.black.cgColor
            let host=CALayer();host.bounds=actual.bounds;host.anchorPoint=actual.anchorPoint;host.position=actual.position;host.transform=actual.transform
            let rect=glass.convert(glass.bounds,to:plane)
            let ink=CALayer();ink.frame=CGRect(x:rect.midX-4,y:rect.midY-4,width:8,height:8);ink.backgroundColor=NSColor.red.cgColor
            host.addSublayer(ink);root.addSublayer(host)
            if let command=actual.animation(forKey:"mode.server.translation") {host.add(command,forKey:"mode.server.translation")}
            let renderer=OffscreenRenderer(size:size,host:root,scale:scale)
            for time in [0.0,1.0/60,2.0/60] {
                let bytes=renderer.render(at:epoch+time)
                var x=0.0,y=0.0,n=0.0
                for yy in 0..<renderer.h {for xx in 0..<renderer.w {let i=(yy*renderer.w+xx)*4
                    if bytes[i+2]>100 && bytes[i+1]<20 {x+=Double(xx);y+=Double(yy);n+=1}
                }}
                let expected=serverCentre(actual,at:time)!
                let error=n>0 ? hypot(x/n/scale-expected.x,y/n/scale-expected.y):Double.infinity
                check(error<1,"B actual carrier readback at first frames \(scale)x \(forward) \(time): \(error)")
                if time == 0 {Offscreen.write(renderer.image(bytes),output.appendingPathComponent("carrier-first-\(Int(scale))x-\(forward).png"))}
            }
            func centre(_ bytes:[UInt8])->CGPoint? {
                var x=0.0,y=0.0,n=0.0
                for yy in 0..<renderer.h {for xx in 0..<renderer.w {let i=(yy*renderer.w+xx)*4
                    if bytes[i+2]>100 && bytes[i+1]<20 {x+=Double(xx);y+=Double(yy);n+=1}
                }}
                return n>0 ? CGPoint(x:x/n/scale,y:y/n/scale):nil
            }
            f.sample(at:0.44,profile:ModeOrreryFlightVerification.profile)
            Thread.sleep(forTimeInterval:0.1);clock+=0.54
            let beforePixels=renderer.render(at:clock),before=centre(beforePixels)
            let oldPosition=serverCentre(actual,at:0.54)!,oldNext=serverCentre(actual,at:0.54+1/60)!
            f.start(toOrganic:!forward,avatar:forward ? (avatar.1,avatar.0):avatar,initials:"LL",tokens:[.init(id:"A",conversation:seed[0],from:forward ? real:row,to:forward ? row:real,start:0,absorbed:forward)],composer:nil,reduceMotion:false)
            host.bounds=actual.bounds;host.anchorPoint=actual.anchorPoint;host.position=actual.position;host.transform=actual.transform
            let turnedRect=glass.convert(glass.bounds,to:plane)
            ink.frame=CGRect(x:turnedRect.midX-4,y:turnedRect.midY-4,width:8,height:8)
            if let command=actual.animation(forKey:"mode.server.translation") {host.add(command,forKey:"mode.server.translation")}
            let afterPixels=renderer.render(at:clock+1/240),after=centre(afterPixels)
            let step=before.flatMap {a in after.map {hypot($0.x-a.x,$0.y-a.y)}} ?? .infinity
            let budget=max(1,hypot(oldNext.x-oldPosition.x,oldNext.y-oldPosition.y))+1
            readbacks.append(["scale":scale,"forward":forward,"stallMS":100,"stepPT":step,"budgetPT":budget,"epoch":epoch])
            check(step<=budget,"A actual CARenderer first turn frame after 100 ms main stall \(scale)x \(forward): \(step)/\(budget)")
            let expected=serverCentre(actual,at:1/240)!
            check(after.map {hypot($0.x-expected.x,$0.y-expected.y)<1} ?? false,"A rendered turn matches the committed CA command")
            Offscreen.write(renderer.image(beforePixels),output.appendingPathComponent("turn-stall-before-\(Int(scale))x-\(forward).png"))
            Offscreen.write(renderer.image(afterPixels),output.appendingPathComponent("turn-stall-after-\(Int(scale))x-\(forward).png"))
            f.shutdown()
        }}
        try JSONSerialization.data(withJSONObject:readbacks,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("carrier-render.json"))
    }

    private static func windowChecks(check:(Bool,String)->Void) throws -> [String:Double] {
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
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();mock.stopPlayback()}
        var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
        shell.verificationFlightSettle(asOrganic:true)
        // Reproduce a reentry while hidden sidebar layout and idle prewarm are both unavailable.
        shell.verificationDropFlightPreparation()
        workbench.sidebar.view.setFrameSize(CGSize(width:240,height:0))
        shell.verificationFlightToggle(toOrganic:false)
        check(shell.flight.activeTokens.count == 6,"C cold reentry obtains all six planets without idle prewarm")
        shell.verificationFlightAdmit()
        workbench.sidebar.search("__m1131_filter_no_row__")
        shell.flight.advance(at:0.30)
        check(shell.flight.activeTokens.isEmpty,"E1 actual sidebar search removes live target rows and their flight owners")
        let searchEnd=shell.flight.duration;now+=searchEnd+0.02
        shell.flight.advance(at:searchEnd+0.02)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:2*shell.flight.presentationInterval))
        shell.flight.advance(at:searchEnd+0.08)
        check(!shell.flight.running || shell.flight.verificationWaitingForOwner,"E1 actual search sequence cannot leave an active display link polling")
        workbench.sidebar.search("")
        shell.flight.cancel();shell.verificationFlightSettle(asOrganic:false)
        _=workbench.select("A")
        shell.prepareModeSwitch(reason:"m1131c.selection.A")
        shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit()
        now+=0.54;shell.flight.advance(at:0.54)
        shell.verificationFlightToggle(toOrganic:false);shell.verificationFlightAdmit()
        now+=0.12;shell.flight.advance(at:0.12)
        _=workbench.select("B")
        var heavyRan=false
        shell.verificationBeforeTurnAdmission={heavyRan=true;Thread.sleep(forTimeInterval:0.1)}
        let command=CACurrentMediaTime();shell.verificationFlightToggle(toOrganic:true)
        let cost=CACurrentMediaTime()-command
        check(!heavyRan && cost<0.060,"A turn is committed before injected 100 ms Native work: \(cost*1000) ms")
        check(shell.verificationContentSessionState["active"] as? Bool == true,"A the fixed representation stays active after direction changes")
        check(shell.verificationSourceTurning || shell.verificationTurnCachedSelection == nil,"A valid target fade is committed or invalid pixels wait for protected capture")
        shell.verificationFlightAdmit()
        check(!heavyRan,"A a turn performs no native admission, including an injected heavy hook")
        shell.verificationFinishContentSession()
        let selectedEnd=shell.flight.duration;now+=selectedEnd
        shell.flight.advance(at:selectedEnd);shell.flight.advance(at:selectedEnd+shell.flight.presentationInterval)
        check(scene.current == "B","E4 selection between reversals rebuilds the Organic target for B")
        check(shell.verificationFlightPresentation["admittedOrganic"] == true,"A actual native destination follows the new direction")
        shell.verificationBeforeTurnAdmission=nil
        shell.flight.cancel()
        shell.verificationFlightSettle(asOrganic:false)
        shell.prepareModeSwitch(reason:"m1131c.composer")
        shell.verificationFlightToggle(toOrganic:true)
        shell.verificationFlightAdmit()
        check(shell.verificationComposerPublisher(),"E5 native full bar waits for its composer's own handoff")
        let count=shell.flight.activeTokens.count
        shell.flight.cancel();shell.verificationFlightSettle(asOrganic:true)
        // No 0.6 s preparation grace period is needed for the next direction.
        shell.verificationDropFlightPreparation();shell.verificationFlightToggle(toOrganic:false)
        check(shell.flight.activeTokens.count == count && count>0,"C immediate next leg retains planets after a completed admission")
        return ["turnCommandMS":cost*1000,"injectedNativeStallMS":100]
    }

    /// Read the actual CA position command. Legacy additive commands include their model counter.
    private static func serverCentre(_ layer: CALayer,at time: Double)->CGPoint? {
        guard let group=layer.animation(forKey:"mode.server.translation") as? CAAnimationGroup else {return nil}
        let channels=group.animations?.compactMap {$0 as? CAKeyframeAnimation} ?? []
        func value(_ axis:String)->Double? {
            guard let key=channels.first(where:{$0.keyPath == "position."+axis || $0.keyPath == "transform.translation."+axis}),let values=key.values as? [NSNumber],values.count>1 else {return nil}
            let u=min(Double(values.count-1),max(0,time/group.duration*Double(values.count-1)))
            let i=min(values.count-2,Int(u)),k=u-Double(i)
            return values[i].doubleValue+(values[i+1].doubleValue-values[i].doubleValue)*k
        }
        guard let x=value("x"),let y=value("y") else {return nil}
        let absolute=channels.contains {$0.keyPath == "position.x"}
        return CGPoint(x:x+(absolute ? (0.5-layer.anchorPoint.x)*layer.bounds.width:0),y:y+(absolute ? (0.5-layer.anchorPoint.y)*layer.bounds.height:0))
    }
}
#endif
