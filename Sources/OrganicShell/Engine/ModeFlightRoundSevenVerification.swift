#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Production-owner and retained-photo regressions. No window, application launch or live Core.
@MainActor enum ModeFlightRoundSevenVerification {
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let seed=MockSeed.make(),size=CGSize(width:1280,height:820)
        let rows=ModeOrreryFlightVerification.rows,real=ModeOrreryFlightVerification.real
        let avatars=(ModeOrreryFlightVerification.sidebarAvatar,ModeOrreryFlightVerification.dockAvatar)
        for changedID in [false,true] {
            let flight=ModeFlight();flight.manualTime={1000};flight.resize(to:size)
            let warm=(0..<6).map {i in ModeFlight.Token(id:seed[i].id,conversation:seed[i],from:rows[i],to:real[i],start:0,absorbed:false)}
            flight.prewarm(tokens:warm)
            // Include every plane child, including resources that will never enter activeTokens.
            let warmMaterials=flight.verificationAllMaterialViews.dropFirst(2)
            check(warmMaterials.count == 6 && warmMaterials.allSatisfy {$0.alphaValue == 0},"R1 all warmed planet containers have zero material contribution")
            let actual=warm.prefix(3).enumerated().map {i,t in ModeFlight.Token(id:changedID && i == 0 ? "header."+t.id:t.id,conversation:t.conversation,from:t.from,to:t.to,start:0,absorbed:false)}
            flight.start(toOrganic:true,avatar:avatars,initials:"LL",tokens:actual,composer:nil,reduceMotion:false)
            check(flight.verificationAllMaterialViews.count == actual.count+2,"R1 subset/endpoint changes leave no unconsumed material planes")
            check(flight.activeTokens.count == 3,"R1 active plan retains all requested planets")
            flight.shutdown()
        }
        try windowChecks(check:check,facts:&facts)
        let host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),source=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:248,height:820)),front=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
        host.wantsLayer=true;source.wantsLayer=true;host.addSubview(source);host.addSubview(front)
        let texture=ModeTurnSidebar(),bitmap=image(CGSize(width:248,height:820),.clear)
        texture.begin(bitmap,source:source,in:host,below:front,rect:source.frame,alpha:0,incoming:true,scale:1)
        let group=texture.verificationMaterial.animation(forKey:"mode.turn.material") as? CAAnimationGroup
        let position=group?.animations?.compactMap {$0 as? CABasicAnimation}.first {$0.keyPath == "position"}
        let origin=(position?.fromValue as? NSValue)?.pointValue
        check(origin?.x == -248,"R3 an absent sidebar material enters from the authored -248 origin")
        check(abs((group?.duration ?? 0)-0.25)<1e-8,"R3 sidebar duration remains 250 ms")
        facts["hiddenSidebarOriginX"]=origin?.x ?? 999
        for state in [NativeDisplayOptions.State(increaseContrast:false,reduceTransparency:true),.init(increaseContrast:true,reduceTransparency:false)] {
            NativeDisplayOptions.shared.setVerificationState(state)
            check(texture.verificationMaterial.backgroundColor?.alpha == 1,"A1 reduced effects use an opaque native sidebar background")
        }
        NativeDisplayOptions.shared.setVerificationState(nil);texture.finish()
        try compositionChecks(output:output,check:check,facts:&facts)
        let result:[String:Any]=["checks":checks,"findings":failures.count,"failures":failures,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round7-verification.json"))
        print("M11.31 round 7: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    private static func windowChecks(check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:ConversationStore())
        let seeded=MockReplay(store:store);seeded.start(live:false)
        let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:1,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(plane);plane.frame=root.bounds}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seeded.stopPlayback();seed.stopPlayback()}
        shell.verificationFlightSettle(asOrganic:false)
        let sidebar=workbench.sidebar,table=sidebar.table,clip=sidebar.scrollView.contentView
        sidebar.prepareModeLayout(size:CGSize(width:260,height:360),safeRect:CGRect(x:0,y:0,width:260,height:360))
        let index=sidebar.model.rows.firstIndex {$0.conversationID != nil}!
        table.scrollRowToVisible(index);table.layoutSubtreeIfNeeded()
        let cell=table.view(atColumn:0,row:index,makeIfNecessary:true) as! NormieSidebarCell
        let conversation=store.conversation(sidebar.model.rows[index].conversationID!)!
        let target=cell.planet.convert(cell.planet.bounds,to:shell.view).offsetBy(dx:3,dy:1)
        let real=CGRect(x:900,y:100,width:40,height:40),avatars=(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar)
        var now=1000.0;shell.flight.manualTime={now}
        shell.flight.onFrame={t in shell.verificationPublishFlightOwners(at:t)}
        shell.flight.start(toOrganic:false,avatar:avatars,initials:"LL",tokens:[.init(id:conversation.id,conversation:conversation,from:real,to:target,start:0,absorbed:true)],composer:nil,reduceMotion:false)
        let plan=ModeOrreryFlight.Plan(forward:false,row:target,real:real,rank:0,lastRank:0,avatarFrom:avatars.0,avatarTo:avatars.1)
        now=1000+plan.handoff-0.001;shell.flight.advance(at:plan.handoff-0.001)
        let before=cell.planet.convert(cell.planet.bounds,to:shell.view)
        // Move the real clip synchronously, but do not yield to the coalesced endpoint task.
        clip.setBoundsOrigin(CGPoint(x:clip.bounds.minX,y:clip.bounds.minY+12))
        sidebar.onModeEndpointVisibilityChanged?()
        now=1000+plan.handoff+0.001;shell.flight.advance(at:plan.handoff+0.001)
        let moved=cell.planet.convert(cell.planet.bounds,to:shell.view)
        let ink=shell.flight.verificationRowLayers[conversation.id]?.opacity ?? 0
        check(abs(moved.minY-before.minY)>1,"R2 the native cell actually moved before endpoint reconstruction")
        check(cell.planet.isHidden || ink<0.001,"R2 arrival during a deferred scroll refresh never exposes two separated glyphs")
        facts["scrollNativeHiddenBeforeRefresh"]=cell.planet.isHidden
        shell.flight.cancel()
        // A native identity with only half its geometry covered cannot retire a complete flying owner.
        let base=cell.planet.frame
        cell.planet.isHidden=false
        for fraction:CGFloat in [0.25,0.5,0.75] {
            let local=CGRect(x:clip.bounds.minX+20,y:clip.bounds.minY-cell.planet.bounds.height*fraction,width:16,height:16)
            cell.planet.frame=cell.convert(local,from:clip)
            let endpoint=cell.planet.convert(cell.planet.bounds,to:shell.view).offsetBy(dx:3,dy:1)
            shell.flight.start(toOrganic:false,avatar:avatars,initials:"LL",tokens:[.init(id:conversation.id,conversation:conversation,from:real,to:endpoint,start:0,absorbed:true)],composer:nil,reduceMotion:false)
            cell.planet.isHidden=false
            check(!shell.verificationFlightNativeOwner(conversation.id),"R5 partial native coverage is not a complete destination owner")
            shell.flight.cancel()
        }
        cell.planet.frame=base
        let fadeLocal=CGRect(x:clip.bounds.minX+20,y:clip.bounds.minY+1,width:16,height:16)
        cell.planet.frame=cell.convert(fadeLocal,from:clip)
        check(!sidebar.fullyCoversFlightIdentity(cell.planet),"R5 scroll fade boundary cannot retire full-brightness flying ink")
        cell.planet.frame=base
    }
    private static func compositionChecks(output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        var records:[[String:Any]]=[]
        for scale:CGFloat in [1,2] {
            let size=CGSize(width:1280,height:820),host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),front=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
            host.wantsLayer=true;host.addSubview(front)
            let plate=ModeHandoffPlate(frame:host.bounds)
            func picture(_ i:Int)->ModeSurfacePicture {
                let bitmap=image(CGSize(width:size.width*scale,height:size.height*scale),i%2 == 0 ? .red:.blue)
                return ModeSurfacePicture(tiles:[.init(rect:CGRect(origin:.zero,size:size),image:bitmap)],glasses:[],size:size,scale:scale)
            }
            plate.hold(picture(0),in:host,below:front,holes:[])
            var maxBytes=0,maxDepth=0,maxLayers=0,maxGroups=0,maxError=0
            var maximumRestoreMS=0.0
            for turn in 1...10 {
                let before=render(plate,scale:scale,at:CACurrentMediaTime())
                let target=picture(turn),started=CACurrentMediaTime()
                plate.restoreSource(target,in:host,below:front,holes:[])
                maximumRestoreMS=max(maximumRestoreMS,(CACurrentMediaTime()-started)*1000)
                let fade=plate.verificationImageLayer!.animation(forKey:"mode.source.turn")!
                let after=render(plate,scale:scale,at:fade.beginTime)
                let error=zip(before,after).map {abs(Int($0)-Int($1))}.max() ?? 0
                maxError=max(maxError,error)
                check(error<=2,"R4 composition compaction preserves the first displayed pixels \(scale)x turn \(turn)")
                let deadline=Date(timeIntervalSinceNow:3)
                while plate.verificationFlattenPending,Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.001))}
                let stats=plate.verificationCompositionStats
                maxBytes=max(maxBytes,stats.bytes);maxDepth=max(maxDepth,stats.depth);maxLayers=max(maxLayers,stats.layers);maxGroups=max(maxGroups,stats.groups)
                check(stats.groups<=3 && stats.depth<=12 && stats.layers<=30,"R4 ten rapid turns keep the photo tree bounded")
                check(stats.bytes<=Int(size.width*scale)*Int(size.height*scale)*4*6,"R4 retained photo pixels stay within six surfaces")
                plate.verificationImageLayer?.removeAllAnimations();plate.verificationImageLayer?.opacity=0.35
            }
            records.append(["scale":scale,"maxBytes":maxBytes,"maxDepth":maxDepth,"maxLayers":maxLayers,"maxGroups":maxGroups,"maximumChangedChannel":maxError,"maximumRestoreMS":maximumRestoreMS])
            plate.presentationInterval=1/120
            let before=CACurrentMediaTime();plate.revealDestination {}
            let command=plate.verificationContentFadeLayer?.animation(forKey:"mode.source.handoff")
            let lead=(command?.beginTime ?? 0)-before
            check(lead>=1/120-0.001 && lead<1/120+0.004,"A2 ordinary reveal reserves one actual 120 Hz interval")
            plate.clear();check(plate.verificationCompositionStats.groups == 0,"R4 clearing releases composition groups")
        }
        facts["tenTurnComposition"]=records
    }
    private static func render(_ view:NSView,scale:CGFloat,at time:Double)->[UInt8] {
        func copyLayer(_ source:CALayer)->CALayer {
            let target=CALayer();target.frame=source.frame;target.opacity=source.opacity;target.contents=source.contents;target.contentsScale=source.contentsScale;target.backgroundColor=source.backgroundColor;target.isHidden=source.isHidden
            for key in source.animationKeys() ?? [] {target.add(source.animation(forKey:key)!,forKey:key)}
            for child in source.sublayers ?? [] {target.addSublayer(copyLayer(child))};return target
        }
        func copyView(_ source:NSView)->CALayer {
            let target=CALayer();target.frame=source.frame;target.opacity=source.layer?.opacity ?? Float(source.alphaValue);target.isHidden=source.isHidden;target.backgroundColor=source.layer?.backgroundColor
            if let layer=source.layer {
                for key in layer.animationKeys() ?? [] {target.add(layer.animation(forKey:key)!,forKey:key)}
                let children=Set(source.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
                for child in layer.sublayers ?? [] where !children.contains(ObjectIdentifier(child)) {target.addSublayer(copyLayer(child))}
            }
            for child in source.subviews {target.addSublayer(copyView(child))};return target
        }
        let root=copyView(view);root.frame=CGRect(origin:.zero,size:view.bounds.size)
        return OffscreenRenderer(size:view.bounds.size,host:root,scale:scale).render(at:time)
    }
    private static func image(_ size:CGSize,_ color:NSColor)->CGImage {
        let c=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(color.cgColor);c.fill(CGRect(origin:.zero,size:size));return c.makeImage()!
    }
}
#endif
