#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Windowless production turns, immutable-worker composition and clipped-native ownership.
@MainActor enum ModeFlightRoundNineVerification {
    @MainActor private final class Heartbeat {
        var intervals:[Double]=[],last=0.0
        var timer:Timer?
        func begin() {
            last=CACurrentMediaTime()
            let value=Timer(timeInterval:0.005,repeats:true) { [weak self] _ in MainActor.assumeIsolated {
                guard let self else {return};let now=CACurrentMediaTime();self.intervals.append((now-self.last)*1000);self.last=now
            }}
            timer=value;RunLoop.main.add(value,forMode:.common)
        }
        func stop() {timer?.invalidate();timer=nil}
    }
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        for scale:CGFloat in [1,2] {try composition(scale:scale,output:output,check:check,facts:&facts);cornerReference(scale:scale,output:output,check:check,facts:&facts)}
        check(abs(ModeHandoffPlate.resolveCommitInterval(measured:1/120,sameScreen:false,nominal:1/60)-1/60)<1e-10,"B3 a new 60 Hz screen invalidates the previous 120 Hz interval")
        check(abs(ModeHandoffPlate.resolveCommitInterval(measured:1/60,sameScreen:false,nominal:1/120)-1/120)<1e-10,"B3 a new 120 Hz screen invalidates the previous 60 Hz interval")
        try nativeChecks(check:check,facts:&facts)
        let result:[String:Any]=["checks":checks,"findings":failures.count,"failures":failures,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round9-verification.json"))
        print("M11.31 round 9: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    private static func wait(_ seconds:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:seconds))}
    private static func drain(_ plate:ModeHandoffPlate) {
        let end=Date(timeIntervalSinceNow:4)
        while plate.verificationFlattenPending,Date()<end {wait(0.001)}
    }
    private static func picture(_ size:CGSize,_ scale:CGFloat)->ModeSurfacePicture {
        let c=CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x:scale,y:scale)
        c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));c.fill(CGRect(x:0,y:size.height-20,width:size.width,height:20))
        c.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1));c.fill(CGRect(x:0,y:0,width:size.width,height:20))
        return ModeSurfacePicture(tiles:[.init(rect:CGRect(origin:.zero,size:size),image:c.makeImage()!)],glasses:[],size:size,scale:scale)
    }
    private static func composition(scale:CGFloat,output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let size=CGSize(width:1280,height:820),host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size)),front=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
        host.wantsLayer=true;host.addSubview(front)
        let plate=ModeHandoffPlate(frame:host.bounds),photo=picture(size,scale)
        plate.hold(photo,in:host,below:front,holes:[])
        plate.addCardPlates([CGRect(x:80,y:80,width:160,height:100)])
        var main:[Double]=[],phases:[[String:Double]]=[],peakBytes=0,peakDepth=0
        // The production stack is frozen before a new fade, including the card's real plate layer.
        for turn in 0..<20 {
            let began=CACurrentMediaTime();plate.restoreSource(photo,in:host,below:front,holes:[])
            main.append((CACurrentMediaTime()-began)*1000)
            let before=plate.verificationCompositionStats;peakBytes=max(peakBytes,before.bytes);peakDepth=max(peakDepth,before.depth)
            if turn == 3 {
                check(plate.verificationFlattenPending,"A \(scale)x threshold schedules an asynchronous worker")
                check(main.last!<25,"A \(scale)x fourth turn does not synchronously rasterize the window")
            }
            wait(turn<10 ? 0.12:0.3)
            phases.append(plate.compositionCosts)
        }
        drain(plate)
        check(!plate.verificationFlattenPending,"A \(scale)x background composition completes")
        check((plate.compositionCosts["composeBackgroundMS"] ?? 0)>0,"A \(scale)x composition ran on the worker")
        check((main.max() ?? 999)<106,"A \(scale)x retained-photo main work stays below HEAD's 106 ms stall")
        check(peakBytes<=Int(size.width*scale)*Int(size.height*scale)*4*8,"A \(scale)x twenty paced turns retain at most eight bitmap surfaces")
        check(peakDepth<=18,"A \(scale)x twenty paced turns keep bounded hierarchy depth")
        let snapshot=ModePhotoSnapshot.capture(plate,size:size,scale:scale)
        let bitmap=snapshot.render()!
        Offscreen.write(bitmap,output.appendingPathComponent("worker-\(Int(scale))x.png"))
        let top=ModeFlightRoundEightVerification.rgb(bitmap,x:10*Int(scale),y:5*Int(scale))
        let bottom=ModeFlightRoundEightVerification.rgb(bitmap,x:10*Int(scale),y:815*Int(scale))
        check(top.0>200 && top.1<40 && bottom.1>200 && bottom.0<40,"B/C \(scale)x retained and asynchronously flattened photos keep top/bottom orientation")
        // Corner and border checks use the production addCardPlates layer inside the retained stack.
        let corner=rgba(bitmap,x:80*Int(scale),y:80*Int(scale)),inside=rgba(bitmap,x:100*Int(scale),y:100*Int(scale))
        let edge=rgba(bitmap,x:160*Int(scale),y:80*Int(scale))
        check(corner.3<8 && inside.3>8,"B2 \(scale)x continuous card corner is not filled as a rectangle")
        check(edge.3>inside.3+25,"B2 \(scale)x one-backing-pixel card border survives compaction")
        facts["composition\(Int(scale))x"]=["mainMS":main,"phases":phases,"peakBytes":peakBytes,"peakDepth":peakDepth,"cardCornerRGBA":[corner.0,corner.1,corner.2,corner.3],"cardInteriorRGBA":[inside.0,inside.1,inside.2,inside.3],"cardEdgeRGBA":[edge.0,edge.1,edge.2,edge.3]]
        // A retained partial reveal is the same photo route used by f80/r280's next keypress.
        plate.revealDestination(duration:0.14) {}
        wait(0.04)
        for restart in 0..<2 {
            plate.restoreSource(photo,in:host,below:front,holes:[])
            let fade=plate.verificationImageLayer?.animation(forKey:"mode.source.turn")
            let shown=ModeFlightRoundEightVerification.render(plate,at:(fade?.beginTime ?? CACurrentMediaTime())+0.09)
            let a=ModeFlightRoundEightVerification.rgb(shown,x:10,y:5),b=ModeFlightRoundEightVerification.rgb(shown,x:10,y:815)
            check(a.0>a.1+100 && b.1>b.0+100,"C3 retained-reveal restart \(restart) keeps the unified photo orientation")
        }
        for _ in 0..<4 {plate.restoreSource(photo,in:host,below:front,holes:[])}
        let applied=plate.verificationCompositionsApplied
        plate.setFrameSize(CGSize(width:size.width,height:size.height+1));drain(plate)
        check(plate.verificationCompositionsApplied == applied,"A \(scale)x worker rejects an obsolete viewport size")
        plate.setFrameSize(size)
        // A reset cancels the job's lease. It may finish in the background but cannot resurrect old pixels.
        for _ in 0..<4 {plate.restoreSource(photo,in:host,below:front,holes:[])}
        plate.clear();wait(0.2)
        check(plate.picture == nil && plate.superview == nil && plate.verificationCompositionStats.groups == 0,"A \(scale)x stale worker cannot replace a cleared generation")
    }
    private static func cornerReference(scale:CGFloat,output:URL,check:(Bool,String)->Void,facts:inout [String:Any]) {
        let size=CGSize(width:200,height:140),host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size));host.wantsLayer=true
        let card=CALayer();card.frame=CGRect(x:20,y:20,width:160,height:100);card.cornerRadius=18;card.cornerCurve = .continuous
        card.backgroundColor=CGColor(gray:1,alpha:1);card.borderColor=CGColor(gray:0,alpha:1);card.borderWidth=1/scale
        ModePhotoSnapshot.cacheDecoration(card,scale:scale)
        host.layer?.addSublayer(card)
        let snapshot=ModePhotoSnapshot.capture(host,size:size,scale:scale)
        let worker=snapshot.render()!
        Offscreen.write(worker,output.appendingPathComponent("corner-worker-\(Int(scale))x.png"))
        let native=CALayer(),part=CALayer();native.frame=host.bounds
        part.frame=card.frame;part.cornerRadius=card.cornerRadius;part.cornerCurve=card.cornerCurve
        part.backgroundColor=card.backgroundColor;part.borderColor=card.borderColor;part.borderWidth=card.borderWidth
        native.addSublayer(part)
        let renderer=OffscreenRenderer(size:size,host:native,scale:scale)
        let pixels=renderer.render(at:CACurrentMediaTime())
        renderer.write(pixels,output.appendingPathComponent("corner-native-\(Int(scale))x.png"))
        var maximumBoundaryError=0
        for y in [0,1,2,3,5,8,12,17,20,25,28] {
            let yy=(20+y)*Int(scale)
            let native=(0..<32*Int(scale)).first {pixels[(yy*renderer.w+20*Int(scale)+$0)*4+3]>128} ?? 0
            let composed=(0..<32*Int(scale)).first {rgba(worker,x:20*Int(scale)+$0,y:yy).3>128} ?? 0
            maximumBoundaryError=max(maximumBoundaryError,abs(native-composed))
        }
        check(maximumBoundaryError<=1,"B2 cached native continuous decoration stays within one backing pixel of CARenderer")
        facts["cornerBoundaryError\(Int(scale))x"]=maximumBoundaryError
    }
    private static func rgba(_ image:CGImage,x:Int,y:Int)->(Int,Int,Int,Int) {
        let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let p=c.data!.assumingMemoryBound(to:UInt8.self),i=(y*image.width+x)*4
        return (Int(p[i]),Int(p[i+1]),Int(p[i+2]),Int(p[i+3]))
    }
    private static func nativeChecks(check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false)
        let sessions=NativeTranscriptSessions(store:store),scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {root.addSubview(plane);plane.frame=root.bounds}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        shell.verificationFlightSettle(asOrganic:false)
        let sidebar=workbench.sidebar,table=sidebar.table,clip=sidebar.scrollView.contentView
        sidebar.prepareModeLayout(size:CGSize(width:260,height:180),safeRect:CGRect(x:0,y:0,width:260,height:180))
        let conversationRows=sidebar.model.rows.indices.filter {sidebar.model.rows[$0].conversationID != nil}
        let index=conversationRows[max(0,conversationRows.count/2-1)]
        table.scrollRowToVisible(index);table.layoutSubtreeIfNeeded()
        let cell=table.view(atColumn:0,row:index,makeIfNecessary:true) as! NormieSidebarCell
        let conversation=store.conversation(sidebar.model.rows[index].conversationID!)!
        let avatars=(ModeOrreryFlightVerification.dockAvatar,ModeOrreryFlightVerification.sidebarAvatar),real=CGRect(x:900,y:100,width:40,height:40)
        var now=1000.0;shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
        shell.flight.onFrame={t in shell.verificationPublishFlightOwners(at:t)}
        for offset:CGFloat in [-8,1,clip.bounds.height-10] {
            let natural=cell.planet.convert(cell.planet.bounds,to:table)
            clip.setBoundsOrigin(CGPoint(x:clip.bounds.minX,y:natural.minY-offset))
            NotificationCenter.default.post(name:NSView.boundsDidChangeNotification,object:clip)
            let nativeGradient=sidebar.scrollView.layer?.mask as? CAGradientLayer
            let edgeColor=(offset == 1 ? nativeGradient?.colors?.first:nativeGradient?.colors?.last)
            check(edgeColor.map {($0 as! CGColor).alpha<0.001} ?? false,"B1 fixture scrolls a real cell into an active native fade/clip edge")
            let target=cell.planet.convert(cell.planet.bounds,to:shell.view).offsetBy(dx:3,dy:1)
            shell.flight.start(toOrganic:false,avatar:avatars,initials:"LL",tokens:[.init(id:conversation.id,conversation:conversation,from:real,to:target,start:0,absorbed:true)],composer:nil,reduceMotion:false)
            let plan=ModeOrreryFlight.Plan(forward:false,row:target,real:real,rank:0,lastRank:0,avatarFrom:avatars.0,avatarTo:avatars.1)
            shell.flight.advance(at:plan.handoff-0.03)
            check(shell.flight.verificationRowLayers[conversation.id]?.mask != nil,"B1 partial/faded row uses the native viewport before handoff")
            if let rowLayer=shell.flight.verificationRowLayers[conversation.id],let mask=rowLayer.mask,let gradient=mask.sublayers?.first as? CAGradientLayer {
                let viewport=sidebar.scrollView.convert(sidebar.scrollView.bounds,to:shell.view)
                let shownViewport=rowLayer.convert(mask.frame,to:rowLayer.superlayer)
                check(MotionStep.edge(shownViewport,viewport)<0.01,"B1 flight coverage uses the complete native viewport, preserving Gaussian extents")
                let parentClock=rowLayer.animation(forKey:"mode.orrery.appearance") as? CAAnimationGroup
                let maskClock=mask.animation(forKey:"mode.row.coverage") as? CAAnimationGroup
                let parentScale=parentClock?.animations?.compactMap {$0 as? CAKeyframeAnimation}.first {$0.keyPath == "transform.scale"}?.values as? [NSNumber]
                let inverseScale=maskClock?.animations?.compactMap {$0 as? CAKeyframeAnimation}.first {$0.keyPath == "transform.scale"}?.values as? [NSNumber]
                let invariant=zip(parentScale ?? [],inverseScale ?? []).allSatisfy {abs($0.doubleValue*$1.doubleValue-1)<1e-10}
                check(parentScale?.isEmpty == false && parentScale?.count == inverseScale?.count && invariant,"B1 server row and viewport scales remain complementary through a main-thread stall")
                let native=sidebar.scrollView.layer?.mask as? CAGradientLayer
                check(native == nil || (gradient.locations == native?.locations && gradient.colors?.count == native?.colors?.count),"B1 Native and flight use identical native fade stops")
            } else {check(false,"B1 flight has an inspectable native gradient");check(false,"B1 native viewport is shared");check(false,"B1 server mask clock exists")}

            // Cross the real exposure fence before the bounded 300 ms missing-owner deadline.
            let end=shell.flight.duration;now+=end+0.02;shell.flight.advance(at:end+0.02)
            now+=0.05;shell.flight.advance(at:end+0.07)
            check(!shell.flight.running,"B1 a stationary partial/faded native row completes advance-to-finish")
            check(!cell.planet.isHidden,"B1 the clipped native row owns the final ink")
            shell.flight.cancel()
        }
        // Real production command/admission/sidebar phases, without waiting for each admission before the next command.
        shell.verificationFlightSettle(asOrganic:true);shell.flight.manualTime=nil
        shell.prepareModeSwitch(reason:"round9.ten-turn")
        var phases:[String:[Double]]=[:],commands:[Double]=[],events:[[String:Any]]=[]
        shell.onTurnCost={ [weak shell] name,value in
            phases[name,default:[]].append(value)
            events.append(["generation":shell?.verificationTurnGeneration ?? 0,"phase":name,"milliseconds":value,"mediaTime":CACurrentMediaTime()])
        }
        let heartbeat=Heartbeat();heartbeat.begin()
        for turn in 0..<20 {
            let began=CACurrentMediaTime();shell.verificationFlightToggle(toOrganic:turn%2 != 0)
            commands.append((CACurrentMediaTime()-began)*1000)
            wait(turn<10 ? 0.12:0.3)
            shell.flight.advance(at:shell.flight.elapsed)
        }
        wait(0.6);heartbeat.stop()
        check((heartbeat.intervals.max() ?? 999)<106,"A production main-loop heartbeat has no stall beyond HEAD's 106 ms")
        check((commands.max() ?? 999)<106,"A production twenty-turn command work stays below HEAD's 106 ms stall")
        facts["productionTurns"]=["commandsMS":commands,"mainPhasesMS":phases,"mainEvents":events,"heartbeatIntervalsMS":heartbeat.intervals]
        shell.onTurnCost=nil;shell.flight.cancel()
        let source=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:248,height:820)),front=ModeFlight.Plane(frame:root.bounds)
        source.wantsLayer=true;source.appearance=NSAppearance(named:.darkAqua);root.addSubview(source);root.addSubview(front)
        let texture=ModeTurnSidebar(),photo=picture(CGSize(width:248,height:820),1).tiles[0].image
        let previous=NSAppearance.current;NSAppearance.current=NSAppearance(named:.aqua)
        NativeDisplayOptions.shared.setVerificationState(.init(increaseContrast:false,reduceTransparency:true))
        texture.begin(photo,source:source,in:root,below:front,rect:source.frame,alpha:0,incoming:true,scale:1)
        var expected:CGColor!
        source.effectiveAppearance.performAsCurrentDrawingAppearance {expected=NSColor.windowBackgroundColor.withAlphaComponent(1).cgColor}
        check(texture.verificationMaterial.backgroundColor == expected,"B4 reduced effects resolve under the native source appearance, not ambient Aqua")
        NativeDisplayOptions.shared.setVerificationState(nil);NSAppearance.current=previous;texture.finish()
    }
}
#endif
