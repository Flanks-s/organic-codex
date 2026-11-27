#if M11_MODE_SELFTEST && M11_TIDE_MODE_SELFTEST
import AppKit
import QuartzCore

/// The production mode switch, source epoch, native admission and finite server fade, in a never-ordered window.
@MainActor enum DockTideModeVerification {
    static func run(to output:URL)throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        ModelCatalog.models=ModelCatalog.mockModels
        var checks=0,failures:[String]=[],rows:[[String:Any]]=[]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        let replay=MockReplay(store:store);replay.start(live:true);_=replay.setPaused(true)
        for c in store.conversations where c.running {replay.stop(c)}
        let sessions=NativeTranscriptSessions(store:store),size=CGSize(width:1280,height:820)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true;scene.verificationPresented=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for view in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {view.frame=root.bounds;root.addSubview(view)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:"A",transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install(members:MockSeed.windowMembers);scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic)
        let window=NSWindow(contentRect:root.bounds,styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentViewController=shell;shell.view.frame=root.bounds;shell.installToolbar(in:window)
        scene.setTranscriptPresentationActive(true);scene.dock.prepareTideMaterialNow()
        defer {shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();replay.stopPlayback();window.close()}
        var pending=false,until = -Double.infinity
        scene.dock.onNeedsFrames={d in pending=true;until=max(until,CACurrentMediaTime()+d)}
        scene.dock.onNeedsFramesUntil={t in pending=true;until=max(until,t)}
        let timer=Timer(timeInterval:1/120,repeats:true) {_ in MainActor.assumeIsolated {
            let now=CACurrentMediaTime()
            if let due=scene.dock.tideLightProbe["nextWakeAt"] as? Double,due<=now {scene.dock.serviceTideDeadline()}
            if pending || now<=until {pending=false;scene.frame(now+1/120)}
            if shell.flight.running {shell.flight.verificationDisplayAdvance(at:shell.flight.elapsed)}
        }}
        RunLoop.main.add(timer,forMode:.common);defer {timer.invalidate()}
        var serial=1000
        func emit(_ method:String,_ params:JSONValue) {serial+=1;var p=params.objectValue!;p["threadId"]="D";store.apply(.init(id:serial,time:Date().timeIntervalSince1970,method:method,params:.object(p)))}
        emit("turn/started",["turn":["id":"tide-mode-r9"]])
        emit("core/approvalRequested",["approvalId":"tide-mode-r9","title":"Allow mode fixture?","request":["method":"item/commandExecution/requestApproval","params":["command":"printf fixture","availableDecisions":["decline","accept"]]]])
        RunLoop.main.run(until:Date(timeIntervalSinceNow:1))
        let source=scene.dock.items.mapValues{$0.glass.frame}
        check(scene.dock.tideLightProbe["phase"] as? String=="holding","a real notice is displayed before the mode action")
        let body=scene.dock.items["B"]!.glass,scale=window.backingScaleFactor
        let builder=ModeSurfaceBuilder(body,scale:scale,includeWindowFrame:false,presentation:true,photoInk:true)
        while !builder.ready {builder.step()}
        let bodyInk=builder.finish()!.flattened(),bodyRect=body.convert(body.bounds,to:scene.nativePlane)
        let began=CACurrentMediaTime();shell.setMode(.normie)
        let photo=scene.nativePlane.subviews.first {$0.identifier?.rawValue=="mode.departure.picture"}
        check(photo != nil,"the lifecycle entry immediately owns one outgoing Tide photo")
        var samePhotoCurve=false
        if let fade=photo?.layer?.animation(forKey:"mode.departure.fade") as? CABasicAnimation,let timing=fade.timingFunction {
            var first:[Float]=[0,0],second:[Float]=[0,0]
            timing.getControlPoint(at:1,values:&first);timing.getControlPoint(at:2,values:&second)
            samePhotoCurve=fade.keyPath=="opacity" && abs(fade.duration-0.22)<1e-9
                && (fade.fromValue as? NSNumber)?.doubleValue==1 && (fade.toValue as? NSNumber)?.doubleValue==0
                && abs(first[0]-0.42)<1e-6 && first[1]==0 && abs(second[0]-0.58)<1e-6 && second[1]==1
        }
        check(samePhotoCurve,"the attachment shares the outgoing body photo's existing 220 ms ease-in-out recipe")
        let backSources=photo?.subviews.first {$0.identifier?.rawValue=="mode.departure.ink.behindMaterial"}?.layer?.name ?? ""
        let frontSources=photo?.subviews.first {$0.identifier?.rawValue=="mode.departure.ink.foreground"}?.layer?.name ?? ""
        check(backSources.contains("tide.halo") && !frontSources.contains("tide.halo"),"the frozen halo keeps its real layer order below native material and text")
        let input=scene.dock.tideLightProbe["presentation"] as? [String:Any] ?? [:]
        check(input["interactive"] as? Bool==false,"the accepted lifecycle frame closes all Tide hit targets")
        let protectedIDs=["C","D","E","F"]
        check(protectedIDs.allSatisfy {scene.dock.items[$0]!.glass.layer?.isHidden==true},"original native Tide surfaces are suppressed before the first mode frame")
        if let photo {
            func materials(_ v:NSView)->[NSGlassEffectView] {(v as? NSGlassEffectView).map{[$0]} ?? v.subviews.flatMap(materials)}
            let glass=materials(photo)
            let frames=glass.map {$0.convert($0.bounds,to:scene.nativePlane)}
            check(protectedIDs.allSatisfy {id in frames.contains {MotionStep.edge($0,source[id]!)<0.001}},"the outgoing photo retains the displayed capsule, borrowed body and displaced neighbour glass")
            check(glass.count>=16 && glass.allSatisfy {$0.layer?.mask==nil && ($0.layer?.filters?.isEmpty ?? true)},"the outgoing photo preserves all native tail pieces without a glass mask or blur")
            func controls(_ v:NSView)->Int {(v is NSButton ? 1:0)+v.subviews.reduce(0){$0+controls($1)}}
            check(controls(photo)==0,"the frozen photo owns no live native action controls")
            check(photo.hitTest(CGPoint(x:photo.frame.midX,y:photo.frame.midY))==nil,"the outgoing photo cannot receive pointer input")
            try compareBody(bodyInk,rect:bodyRect,photo:photo,host:scene.nativePlane,scale:scale,to:output,check:check)

        } else {
            check(false,"the outgoing photo retains the displayed capsule, borrowed body and displaced neighbour glass")
            check(false,"the outgoing photo preserves all native tail pieces without a glass mask or blur")
            check(false,"actual photo pixels fade continuously and are empty at 220 ms")
            check(false,"the frozen photo owns no live native action controls")
            check(false,"the outgoing photo cannot receive pointer input")
            check(false,"the outgoing photo keeps visible native text and button ink")
            check(false,"native body ink keeps its source orientation and pixels in the outgoing photo")
        }
        var samples=0,expiredVisible=false,reappeared=false,sourceRevealed=false
        for tick in 0..<240 {
            let at=began+Double(tick)/120
            RunLoop.main.run(until:Date(timeIntervalSinceNow:max(0,at-CACurrentMediaTime())))
            let age=CACurrentMediaTime()-began
            let attached=photo?.superview != nil
            if age>=0.22+1/120 {expiredVisible = expiredVisible || attached}
            if age>=0.3,attached {reappeared=true}
            if scene.dock.tideLightProbe["phase"] as? String=="frozen" {
                samples+=1
                sourceRevealed = sourceRevealed || protectedIDs.contains {scene.dock.items[$0]!.glass.layer?.isHidden != true}
            }
            rows.append(["t":age,"epoch":scene.modeContentEpochFrozen,"mode":shell.mode.rawValue,"dock":scene.dock.tideLightProbe,"photoAttached":attached,"sourceVisibility":Dictionary(uniqueKeysWithValues:protectedIDs.map {id in
                let g=scene.dock.items[id]!.glass
                return (id,["hidden":g.isHidden,"layerHidden":g.layer?.isHidden ?? false,"alpha":g.alphaValue,"rect":DockTideShape.rect(g.frame)] as [String:Any])
            }),"C":DockTideShape.rect(scene.dock.items["C"]!.glass.frame),"D":DockTideShape.rect(scene.dock.items["D"]!.glass.frame),"nativeOwner":shell.verificationFadeClosureState])
        }
        check(samples>0,"the real mode entry retains its model until the host handoff endpoint")
        check(!expiredVisible && !reappeared,"the actual outgoing photo is detached by 220 ms plus one frame and never returns")
        check(!sourceRevealed,"flight and native-admission writers never reveal the suppressed source")
        check(shell.mode == .normie && !shell.flight.running && !scene.modeContentEpochFrozen,"the real mode action completes its native admission")
        let cold=shell.verificationContentFadeLatencies.first
        check(cold?["path"] as? String=="cold" && (cold?["ms"] as? Double ?? .infinity)<=768,"cold Organic-to-Normie admission with Tide stays within 768 ms")
        rows.append(["case":"cold-admission","latencies":shell.verificationContentFadeLatencies])
        check(scene.dock.tideLightProbe["phase"] as? String=="idle" && scene.dock.tideAnimationDiagnostics["tideRequestsDisplayFrames"] as? Bool==false,"Normie owns the endpoint without a hidden Tide clock")
        check(store.conversation("D")!.approvals.contains{$0.id=="tide-mode-r9"},"mode retirement leaves the original pending request unanswered")
        // Pixel export can be expensive; never put the verifier's GPU/file work inside a live mode transition.
        if let photo {try renderPhoto(photo,at:began,to:output,check:check)}
        shell.setMode(.organic);RunLoop.main.run(until:Date(timeIntervalSinceNow:2.2))
        scene.dock.prepareTideMaterialNow()
        emit("core/approvalRequested",["approvalId":"tide-mode-turn-r9","title":"Allow turn fixture?","request":["method":"item/commandExecution/requestApproval","params":["command":"printf fixture","availableDecisions":["decline","accept"]]]])
        RunLoop.main.run(until:Date(timeIntervalSinceNow:1))
        check(scene.dock.tideLightProbe["phase"] as? String=="holding","a fresh real notice is present before mode reversal")
        shell.setMode(.normie);RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04));shell.setMode(.organic)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:2.5))
        check(shell.mode == .organic && !scene.modeContentEpochFrozen && !shell.flight.running,"the real mode reversal returns to an admitted Organic endpoint")
        check(scene.dock.tideLightProbe["phase"] as? String=="idle" && scene.dock.items["C"]!.glass.frame.width==scene.dock.items["C"]!.target.width,"a reversed mode retires old pin/lease and restores ordinary native glass")
        let reveal=scene.dock.tideAnimationDiagnostics["tideRequestsDisplayFrames"] as? Bool
        check(reveal==false && store.conversation("D")!.approvals.contains{$0.id=="tide-mode-turn-r9"},"mode reversal leaves neither a Tide clock nor a synthetic answer")
        try actualClose(to:&rows,output:output,check:check)
        check(!window.isVisible && NSApp.windows.allSatisfy{!$0.isVisible},"mode verification never orders a window")
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures,"source":source.mapValues(DockTideShape.rect),"frozenSamples":samples,"rows":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-mode.json"))
        print("Tide real mode: \(checks)/\(failures.count)");return failures.isEmpty ? 0:1
    }
    private static func compareBody(_ original:CGImage,rect:CGRect,photo:NSView,host:NSView,scale:CGFloat,to output:URL,check:(Bool,String)->Void)throws {
        let plane=photo.subviews.first {$0.identifier?.rawValue=="mode.departure.ink.material"}
        let content=plane?.layer?.sublayers?.first?.contents
        guard let content,CFGetTypeID(content as CFTypeRef)==CGImage.typeID else {check(false,"native body ink keeps its source orientation and pixels in the outgoing photo");return}
        let image=content as! CGImage,r=photo.convert(rect,from:host)
        guard let crop=image.cropping(to:CGRect(x:r.minX*scale,y:r.minY*scale,width:r.width*scale,height:r.height*scale)) else {check(false,"native body ink keeps its source orientation and pixels in the outgoing photo");return}
        func pixels(_ image:CGImage)->[UInt8] {
            let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:image.colorSpace!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
        }
        let a=pixels(original),b=pixels(crop)
        let error=zip(a,b).map {abs(Int($0)-Int($1))}.max() ?? 255
        check(original.width==crop.width && original.height==crop.height && error<=1,"native body ink keeps its source orientation and pixels in the outgoing photo")
        Offscreen.write(original,output.appendingPathComponent("body-source.png"));Offscreen.write(crop,output.appendingPathComponent("body-photo.png"))
        try JSONSerialization.data(withJSONObject:["sourceSize":[original.width,original.height],"photoSize":[crop.width,crop.height],"maximumByteError":error],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("body-pixels.json"))
    }
    /// Borrow only the process-owned outgoing picture. Native WindowServer material itself is not rasterized.
    private static func renderPhoto(_ photo:NSView,at time:Double,to output:URL,check:(Bool,String)->Void)throws {
        guard let layer=photo.layer else {check(false,"actual photo pixels fade continuously and are empty at 220 ms");return}
        let parent=layer.superlayer,index=parent?.sublayers?.firstIndex(of:layer) ?? 0
        let anchor=layer.anchorPoint,bounds=layer.bounds,position=layer.position,transform=layer.transform,flipped=layer.isGeometryFlipped
        let backdrop=CALayer();backdrop.bounds=photo.bounds;backdrop.backgroundColor=NSColor.black.cgColor
        layer.position=CGPoint(x:layer.bounds.width*layer.anchorPoint.x,y:layer.bounds.height*layer.anchorPoint.y)
        backdrop.addSublayer(layer)
        let renderer=OffscreenRenderer(size:photo.bounds.size,host:backdrop,scale:2)
        for (index,view) in photo.subviews.enumerated() {
            for child in view.layer?.sublayers ?? [] {
                if let content=child.contents,CFGetTypeID(content as CFTypeRef)==CGImage.typeID {
                    Offscreen.write(content as! CGImage,output.appendingPathComponent("departure-ink-\(index).png"))
                }
            }
        }
        let offsets=[1.0/120,0.055,0.11,0.165,0.22,0.22+1/120]
        var totals:[Double]=[],whiteInk=0
        for t in offsets {
            let pixels=renderer.render(at:time+t)
            if t==offsets[0] {whiteInk=stride(from:0,to:pixels.count,by:4).filter {pixels[$0]>200 && pixels[$0+1]>200 && pixels[$0+2]>200}.count}
            totals.append(stride(from:0,to:pixels.count,by:4).reduce(0){$0+Double(pixels[$1])+Double(pixels[$1+1])+Double(pixels[$1+2])})
            renderer.write(pixels,output.appendingPathComponent("departure-\(Int((t*1000).rounded())).png"))
        }
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer();parent?.insertSublayer(layer,at:UInt32(index))
        layer.anchorPoint=anchor;layer.bounds=bounds;layer.position=position;layer.transform=transform;layer.isGeometryFlipped=flipped
        CATransaction.commit()
        let descending=zip(totals,totals.dropFirst()).allSatisfy {$0+1 >= $1}
        let middle=totals[2]/max(1,totals[0])
        check(whiteInk>30,"the outgoing photo keeps visible native text and button ink")
        check(totals[0]>1000 && descending && middle>0.30 && middle<0.70 && totals.last==0,"actual photo pixels fade continuously and are empty at 220 ms")
        try JSONSerialization.data(withJSONObject:["offsets":offsets,"rgbOverBlack":totals,"whiteInkPixels":whiteInk,"midpointRatio":middle],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("departure-pixels.json"))
    }
    private static func actualClose(to rows:inout [[String:Any]],output:URL,check:(Bool,String)->Void)throws {
        let domain="Tide.Close."+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        defer {defaults.removePersistentDomain(forName:domain)}
        var options=Options();options.mock=true;options.live=false;options.ambient=false;options.output=output.path
        let app=AppController(options,windowDefaults:defaults,presentsWindows:false)
        let replay=MockReplay(store:app.store);replay.start(live:true);_=replay.setPaused(true)
        for c in app.store.conversations where c.running {replay.stop(c)}
        app.mock=replay;app.runtime=MockConversationRuntime(store:app.store,replay:replay,animatePlayback:false)
        let w=OrganicWindow(app:app,frame:CGRect(x:0,y:0,width:1280,height:820),screen:NSScreen.main!,members:MockSeed.windowMembers,normie:false,o:options)
        app.windows=[w];w.scene.verificationPresented=true;w.scene.manualSettle=true
        let timer=Timer(timeInterval:1/120,repeats:true) {_ in MainActor.assumeIsolated {w.scene.frame(CACurrentMediaTime()+1/120)}}
        RunLoop.main.add(timer,forMode:.common)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:1.2));w.scene.settle();w.scene.ends = -1;w.scene.dock.prepareTideMaterialNow()
        app.store.apply(.init(id:9001,time:Date().timeIntervalSince1970,method:"turn/started",params:["threadId":"F","turn":["id":"tide-close-r9"]]))
        app.store.apply(.init(id:9002,time:Date().timeIntervalSince1970,method:"core/approvalRequested",params:["threadId":"F","approvalId":"tide-close-r9","title":"Allow close fixture?","request":["method":"item/commandExecution/requestApproval","params":["command":"printf fixture","availableDecisions":["decline","accept"]]]]))
        RunLoop.main.run(until:Date(timeIntervalSinceNow:1));timer.invalidate()
        check(w.scene.dock.tideLightProbe["phase"] as? String=="holding","real OrganicWindow owns a real Tide before close")
        let before=w.scene.dock.tideLightProbe
        check((before["minimumGap"] as? Double ?? 0)>=12,"the real closing window's rightmost Tide retains 12 pt before detachment")
        let at=CACurrentMediaTime();w.window.performClose(nil)
        check(w.isClosed && app.windows.isEmpty && w.window.delegate==nil,"performClose runs OrganicWindow.windowWillClose and releases its application owner")
        check(w.window.contentView==nil && w.window.contentViewController==nil && w.root.window==nil,"the closing call detaches the entire compositor root before it returns")
        check(w.scene.clock.onFrame==nil && w.scene.dock.tideLightProbe["phase"] as? String=="idle","real close invalidates the scene display link and Tide in the same call")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
        check(w.scene.dock.tideAnimationDiagnostics["tideRequestsDisplayFrames"] as? Bool==false && !w.window.isVisible,"late close callbacks cannot retain a Tide clock or window")
        rows.append(["case":"actual-OrganicWindow-close","elapsed":CACurrentMediaTime()-at,"before":before,"after":w.scene.dock.tideLightProbe,"rootDetached":w.root.window==nil,"closed":w.isClosed])
        replay.stopPlayback();app.runtime.shutdown()
    }

}
#endif
