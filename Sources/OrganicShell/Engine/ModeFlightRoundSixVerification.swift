#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Observe the material owner, not just its NSGlassEffectView descendant's nominal opacity.
@MainActor enum ModeFlightRoundSixVerification {
    static func run(to output:URL,reference:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:],categories:[String:Int]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {categories[String(name.prefix(2)),default:0]+=1;if failures.count<200 {failures.append(name);print("FAIL: "+name)}}}
        let seed=MockSeed.make(),size=CGSize(width:1280,height:820),rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real
        let avatars=(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar)
        let board=try JSONDecoder().decode([ModeOrreryFlightVerification.Frame].self,from:Data(contentsOf:reference))
        try windowChecks(output:output,check:check,facts:&facts)
        try notificationCheck(check:check)
        var maximumMaterialError=0.0,readbacks:[[String:Any]]=[]
        for forward in [true,false] {
            let f=ModeFlight();f.manualTime={1000};f.verificationServerMotion=true;f.resize(to:size)
            let tokens=(0..<6).map {i in ModeFlight.Token(id:seed[i].id,conversation:seed[i],from:forward ? rows[i]:real[i],to:forward ? real[i]:rows[i],start:0,absorbed:!forward)}
            f.destinationOwnerVisible={_ in false}
            f.start(toOrganic:forward,avatar:forward ? avatars:(avatars.1,avatars.0),initials:"LL",tokens:tokens,composer:nil,reduceMotion:false)
            for frame in board where frame.fwd == forward {
                f.sample(at:frame.t,profile:ModeOrreryFlightVerification.profile)
                for token in tokens {
                    let expected=frame.tokens[token.id]!
                    guard let material=f.verificationMaterialViews[token.id] else {check(false,"G5 material owner exists");continue}
                    let actual=Double(material.alphaValue)
                    let expectedMaterial = !forward && !expected.vis ? 0:expected.gl
                    maximumMaterialError=max(maximumMaterialError,abs(actual-expectedMaterial))
                    // AppKit's merged SDF belongs to this container, outside the leaf glass layer.
                    let group=material.layer?.animation(forKey:"mode.orrery.appearance") as? CAAnimationGroup
                    let channel=group?.animations?.compactMap {$0 as? CAKeyframeAnimation}.first {$0.keyPath == "opacity"}
                    let values=channel?.values as? [NSNumber]
                    let index=min((values?.count ?? 1)-1,Int((frame.t*240).rounded()))
                    check(values.map {abs($0[index].doubleValue-expectedMaterial)<1e-6} ?? false,"G7 server material channel owns the authored fade")
                    check(abs(actual-expectedMaterial)<1e-6,"G6 merged material alpha matches board \(forward) \(frame.t) \(token.id)")
                }
            }
            for time in [0.0,0.0125,0.08,1.04,1.12,1.20,1.4,1.7] {
                f.sample(at:time,profile:ModeOrreryFlightVerification.profile)
                guard let actual=f.verificationMaterialViews[seed[0].id] else {continue}
                // The explicitly labelled SDF proxy copies the PRODUCTION material ancestor alpha chain.
                // WindowServer refraction itself cannot be reproduced in a windowless CARenderer.
                let root=CALayer();root.backgroundColor=NSColor.black.cgColor
                let material=CALayer();material.frame=CGRect(x:12,y:12,width:40,height:40);material.backgroundColor=NSColor.white.cgColor
                material.opacity=Float(actual.alphaValue);root.addSublayer(material)
                let epoch=CACurrentMediaTime()+3600
                if let group=actual.layer?.animation(forKey:"mode.orrery.appearance")?.copy() as? CAAnimation {
                    group.beginTime=epoch;material.add(group,forKey:"production.material")
                }
                let render=OffscreenRenderer(size:CGSize(width:64,height:64),host:root)
                let bytes=render.render(at:epoch+time)
                let pixel=Double(bytes[(32*64+32)*4])/255
                let expected=ModeOrreryFlight.Plan(forward:forward,row:rows[0],real:real[0],rank:0,lastRank:5,avatarFrom:forward ? avatars.0:avatars.1,avatarTo:forward ? avatars.1:avatars.0).pose(at:time).glass
                check(abs(pixel-expected)<=1/255+1e-6,"G7 material readback follows the authored fade \(forward) \(time)")
                readbacks.append(["forward":forward,"time":time,"material":actual.alphaValue,"pixel":pixel,"expected":expected])
            }
            f.shutdown()
        }
        facts["maximumMaterialAlphaError"]=maximumMaterialError
        // A visible native endpoint and the flying material must never both contribute a full surface.
        let flight=ModeFlight();flight.manualTime={2000};flight.resize(to:size)
        var native=false;flight.destinationOwnerVisible={_ in native}
        flight.start(toOrganic:true,avatar:avatars,initials:"LL",tokens:[.init(id:"A",conversation:seed[0],from:rows[0],to:real[0],start:0,absorbed:false)],composer:nil,reduceMotion:false)
        let arrival=ModeOrreryFlight.Plan(forward:true,row:rows[0],real:real[0],rank:0,lastRank:0,avatarFrom:avatars.0,avatarTo:avatars.1).arrival
        flight.advance(at:arrival+0.01);native=true;flight.advance(at:arrival+0.02)
        let contribution=Double(flight.verificationMaterialViews["A"]?.alphaValue ?? 0)+1
        check(contribution<=1.00001,"G8 native handoff has one material contribution during its content fence")
        flight.shutdown();facts["handoffSurfaceContributions"]=contribution
        // The real sliding texture animates its ink alpha above an opaque moving material footprint.
        let host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),source=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:248,height:820)),front=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
        host.wantsLayer=true;source.wantsLayer=true;host.addSubview(source);host.addSubview(front)
        let texture=ModeTurnSidebar(),bitmap=image(CGSize(width:248,height:820),color:.clear)
        texture.begin(bitmap,source:source,in:host,below:front,rect:source.frame,alpha:0.2,incoming:true,scale:1)
        let actual=texture.verificationRoot
        let imageLayer=texture.verificationImage
        let material=texture.verificationMaterial
        check((material.backgroundColor?.alpha ?? 0)>=0.95 && material.opacity>0.999 && imageLayer.opacity<=1,"C4 sliding sidebar retains its native material footprint below fading ink")
        check(!texture.needsResize(host:CGSize(width:1380,height:820),source:source.bounds.size),"B3 changing only the right window edge requires no sidebar bitmap rebuild")
        texture.finish()
        try contentReadback(output:output,check:check,facts:&facts)
        measureTurns(facts:&facts)
        try JSONSerialization.data(withJSONObject:readbacks,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("material-readback.json"))
        let result:[String:Any]=["checks":checks,"findings":categories.values.reduce(0,+),"failureCategories":categories,"failures":failures,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round6-verification.json"))
        print("M11.31 round 6: \(checks) checks, \(categories.values.reduce(0,+)) findings")
        return categories.isEmpty ? 0:1
    }
    private static func notificationCheck(check:(Bool,String)->Void) throws {
        let f=ModeFlight();f.manualTime={3000};f.resize(to:CGSize(width:1280,height:820))
        let native=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:40,height:40)),host=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:64,height:64))
        host.addSubview(native);native.wantsLayer=true;native.layer?.opacity=0.998
        f.destinationOwnerVisible={_ in native.superview != nil && (native.layer?.opacity ?? 0)>=0.999}
        f.start(toOrganic:true,avatar:(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar),initials:"LL",tokens:[],composer:nil,reduceMotion:false)
        f.advance(at:f.duration+1.1);f.destinationDidMount()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.001) {native.layer?.opacity=1}
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.055))
        check(!f.running,"E2 a notification before opacity commit completes without waiting for the 100 ms probe")
        f.shutdown()
    }
    private static func windowChecks(output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let store=ConversationStore(),size=CGSize(width:1280,height:820),replay=MockReplay(store:ConversationStore())
        let seed=MockReplay(store:store);seed.start(live:false)
        let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:1,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(plane);plane.frame=root.bounds}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback();replay.stopPlayback()}
        var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
        shell.verificationFlightSettle(asOrganic:false);shell.prepareModeSwitch(reason:"round6.early")
        shell.verificationFlightToggle(toOrganic:true);shell.verificationFlightAdmit()
        now+=0.08;shell.flight.advance(at:0.08);shell.verificationFlightToggle(toOrganic:false)
        let textureDeadline=Date(timeIntervalSinceNow:0.4)
        while !shell.verificationTurnSidebarSingleOwner,Date()<textureDeadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.003))}
        now+=0.10;shell.flight.advance(at:0.10)
        shell.verificationFlightAdmit()
        let side=workbench.sidebar.view
        let held=Set(shell.flight.activeTokens.filter {t in shell.flight.verificationOrreryState(at:0.10).contains {$0["id"] as? String == t.id && $0["hidden"] as? Bool == false}}.map {$0.conversation.id})
        check(!held.isEmpty && shell.verificationTurnSidebarSingleOwner,"B1 returned rows are still flight-owned under the active sidebar texture")
        let bitmap=shell.verificationSidebarForeground()
        let expected=ModeSurfaceBuilder(side,scale:scene.scale,includeWindowFrame:false,excluding:[workbench.sidebar.accountView.avatar]+workbench.sidebar.hiddenFlightSourceViews+workbench.sidebar.flightSourceViews(for:held),detached:workbench.sidebar.preparedModeDrawingRows)
        while !expected.ready {expected.step()}
        let oracle=expected.finish()!.flattened(),a=bitmap.dataProvider!.data! as Data,b=oracle.dataProvider!.data! as Data
        let different=zip(a,b).filter {$0 != $1}.count
        check(different == 0,"B1 rebaked bitmap excludes glyphs whose flying owner has not retired")
        facts["sidebarOwnedInkChangedBytes"]=different
        let before=shell.verificationSidebarBakeCount
        for i in 0..<8 {
            workbench.sidebar.view.setFrameSize(CGSize(width:260+Double(i),height:820+Double(i)))
            shell.viewDidLayout()
        }
        check(shell.verificationSidebarBakeCount == before,"B3 same-frame layout requests never synchronously rebake the sidebar")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
        check(shell.verificationSidebarBakeCount-before<=1,"B3 same-frame resize requests coalesce into one bitmap")
        facts["maximumSidebarBakeMS"]=shell.verificationSidebarBakeMaximumMS
        facts["coalescedSidebarBakes"]=shell.verificationSidebarBakeCount-before
        shell.flight.cancel()
    }
    private static func contentReadback(output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        var maximumInitialError=0.0,maximumStep=0.0
        for scale:CGFloat in [1,2] {
            let size=CGSize(width:96,height:64),host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),front=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
            host.wantsLayer=true;host.layer?.backgroundColor=NSColor.blue.cgColor;host.addSubview(front)
            // A different cached target must preserve all currently displayed source contributions at t=0.
            let hot=ModeHandoffPlate(frame:host.bounds)
            hot.hold(image(size,color:.red),in:host,below:front,holes:[]);hot.verificationImageLayer?.opacity=0.35
            let beforeHot=viewTree(hot)
            hot.restoreSource(ModeSurfacePicture(image:image(size,color:.green)),in:host,below:front,holes:[]) {}
            let afterHot=viewTree(hot),hotEpoch=CACurrentMediaTime()+3600
            func rebase(_ root:CALayer,_ epoch:Double) {
                for key in root.animationKeys() ?? [] {if let a=root.animation(forKey:key)?.copy() as? CAAnimation {a.beginTime=epoch;root.add(a,forKey:key)}}
                for child in root.sublayers ?? [] {rebase(child,epoch)}
            }
            rebase(afterHot,hotEpoch)
            let prior=CALayer(),next=CALayer();prior.backgroundColor=NSColor.blue.cgColor;next.backgroundColor=NSColor.blue.cgColor
            prior.addSublayer(beforeHot);next.addSublayer(afterHot)
            let aRenderer=OffscreenRenderer(size:size,host:prior,scale:scale),bRenderer=OffscreenRenderer(size:size,host:next,scale:scale)
            let hotA=aRenderer.render(at:hotEpoch),hotB=bRenderer.render(at:hotEpoch),hotIndex=(Int(32*scale)*aRenderer.w+Int(48*scale))*4
            let hotError=(0..<4).map {abs(Int(hotA[hotIndex+$0])-Int(hotB[hotIndex+$0]))}.max() ?? 0
            check(hotError<=1,"C4 a new cached photo starts from the displayed composition without an initial hard cut")
            hot.clear()
            let plate=ModeHandoffPlate(frame:host.bounds)
            plate.hold(image(size,color:.red),in:host,below:front,holes:[])
            plate.verificationImageLayer?.opacity=0.35
            plate.pinNativeBackdrop(ModeSurfacePicture(image:image(size,color:.blue)),in:host,below:front,holes:[])
            check(plate.verificationPinnedNative,"C4 cold admission pins a clean native backing without baking the old photo")
            host.layer?.backgroundColor=NSColor.green.cgColor
            // AppKit does not attach an unwindowed view's backing subtree automatically. Mirror its actual
            // view/layer order and opacity into CARenderer, retaining every production animation command.
            let epoch=CACurrentMediaTime()+3600
            let initialRoot=CALayer();initialRoot.backgroundColor=NSColor.green.cgColor;initialRoot.addSublayer(viewTree(plate))
            plate.revealDestination(duration:0.14) {}
            let layer=plate.verificationContentFadeLayer
            check(layer?.animation(forKey:"mode.source.handoff") != nil,"C4 entire cold composition has a fade command")
            let fadingRoot=CALayer();fadingRoot.backgroundColor=NSColor.green.cgColor;fadingRoot.addSublayer(viewTree(plate))
            func retime(_ root:CALayer) {
                for key in root.animationKeys() ?? [] {
                    if let command=root.animation(forKey:key)?.copy() as? CAAnimation {command.beginTime=epoch;root.add(command,forKey:key)}
                }
                for child in root.sublayers ?? [] {retime(child)}
            }
            retime(fadingRoot)
            let firstRenderer=OffscreenRenderer(size:size,host:initialRoot,scale:scale)
            let renderer=OffscreenRenderer(size:size,host:fadingRoot,scale:scale)
            let first=firstRenderer.render(at:epoch),index=(Int(32*scale)*renderer.w+Int(48*scale))*4
            let initialError=Double(first[index+1])/255
            maximumInitialError=max(maximumInitialError,initialError)
            check(initialError<=1/255,"C4 native mode replacement cannot alter the held composition \(scale)x")
            var previous=0.0
            for i in 0...40 {
                let bytes=renderer.render(at:epoch+Double(i)/240),green=Double(bytes[index+1])/255
                if i>0 {maximumStep=max(maximumStep,abs(green-previous));check(green+1/255>=previous,"C4 cold composition follows one monotonic crossfade")}
                previous=green
            }
            check(previous>0.999,"C4 cold composition reaches the clean live destination")
            plate.clear()
        }
        check(maximumStep<=0.065,"C4 cold content has no hard-cut alpha step")
        facts["coldNativeReplacementAlphaError"]=maximumInitialError;facts["maximumColdAlphaStep240Hz"]=maximumStep
    }
    private static func layerTree(_ source:CALayer)->CALayer {
        let copy=CALayer();copy.bounds=source.bounds;copy.anchorPoint=source.anchorPoint;copy.position=source.position
        copy.opacity=source.opacity;copy.isHidden=source.isHidden;copy.zPosition=source.zPosition
        copy.backgroundColor=source.backgroundColor;copy.contents=source.contents;copy.contentsScale=source.contentsScale
        copy.transform=source.transform;copy.masksToBounds=source.masksToBounds
        for key in source.animationKeys() ?? [] {if let command=source.animation(forKey:key) {copy.add(command,forKey:key)}}
        for child in source.sublayers ?? [] {copy.addSublayer(layerTree(child))}
        return copy
    }
    private static func viewTree(_ source:NSView)->CALayer {
        let result=CALayer();result.frame=source.frame;result.bounds=source.bounds
        result.opacity=source.layer?.opacity ?? Float(source.alphaValue)
        result.isHidden=source.isHidden || source.layer?.isHidden == true;result.zPosition=source.layer?.zPosition ?? 0
        result.backgroundColor=source.layer?.backgroundColor;result.contents=source.layer?.contents
        if let layer=source.layer {
            for key in layer.animationKeys() ?? [] {if let command=layer.animation(forKey:key) {result.add(command,forKey:key)}}
            let native=Set(source.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
            for child in layer.sublayers ?? [] where !native.contains(ObjectIdentifier(child)) {result.addSublayer(layerTree(child))}
        }
        for child in source.subviews {result.addSublayer(viewTree(child))}
        return result
    }

    private static func measureTurns(facts:inout [String:Any]) {
        let seed=MockSeed.make(),rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real
        let avatar=(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar)
        var values:[[String:Any]]=[]
        for (forward,cut) in [(true,0.28),(false,0.95)] {
            var now=1000.0
            let f=ModeFlight();f.manualTime={now};f.resize(to:CGSize(width:1280,height:820))
            func tokens(_ direction:Bool)->[ModeFlight.Token] {(0..<6).map {i in .init(id:seed[i].id,conversation:seed[i],from:direction ? rows[i]:real[i],to:direction ? real[i]:rows[i],start:0,absorbed:!direction)}}
            f.start(toOrganic:forward,avatar:forward ? avatar:(avatar.1,avatar.0),initials:"LL",tokens:tokens(forward),composer:nil,reduceMotion:false)
            f.sample(at:cut,profile:ModeOrreryFlightVerification.profile);now+=cut
            f.start(toOrganic:!forward,avatar:forward ? (avatar.1,avatar.0):avatar,initials:"LL",tokens:tokens(!forward),composer:nil,reduceMotion:false)
            var peak=0.0
            for i in 0...Int(ceil(f.duration*240)) {let v=f.verificationPoseVelocity(forward ? "A":"C",at:Double(i)/240);peak=max(peak,hypot(v.x,v.y))}
            func centre()->CGPoint {
                guard let state=f.verificationOrreryState(at:f.elapsed).first(where:{$0["id"] as? String == (forward ? "A":"C")}),let r=state["frame"] as? [CGFloat] else {return .zero}
                return CGPoint(x:r[0]+r[2]/2,y:r[1]+r[3]/2)
            }
            f.sample(at:0,profile:ModeOrreryFlightVerification.profile);let first=centre()
            f.sample(at:1/60,profile:ModeOrreryFlightVerification.profile);let second=centre()
            let index=forward ? 0:2
            let authored=ModeOrreryFlight.Plan(forward:forward,row:rows[index],real:real[index],rank:index,lastRank:5,avatarFrom:forward ? avatar.0:avatar.1,avatarTo:forward ? avatar.1:avatar.0)
            var boardPeak=0.0
            for i in 0..<Int(ceil(authored.duration*240)) {
                let a=authored.pose(at:Double(i)/240).rect,b=authored.pose(at:Double(i+1)/240).rect
                boardPeak=max(boardPeak,hypot(b.midX-a.midX,b.midY-a.midY)*240/1000)
            }
            values.append(["forward":forward,"cut":cut,"peakTurnPTPerMS":peak/1000,"firstTurnStep60HzPT":hypot(second.x-first.x,second.y-first.y),"boardPeakPTPerMS":boardPeak]);f.shutdown()
        }
        facts["turnMeasurements"]=values
    }

    private static func image(_ size:CGSize,color:NSColor)->CGImage {
        let c=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(color.cgColor);c.fill(CGRect(origin:.zero,size:size));return c.makeImage()!
    }
}
#endif
