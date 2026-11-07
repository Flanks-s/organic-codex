#if M11_MODE_SELFTEST
import AppKit
import QuartzCore
import Darwin

/// A real, never-ordered NSWindow exercises AppKit's actual split layout engine.
@MainActor enum ModeFlightRoundElevenVerification {
    final class Marker:NSView {
        override var isFlipped:Bool {true}
        override func draw(_ dirtyRect:NSRect) {NSColor.red.setFill();bounds.fill()}
    }
    static func run(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        let root=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:320,height:192));root.wantsLayer=true
        let marker=Marker(frame:root.bounds);marker.wantsLayer=true;root.addSubview(marker)
        root.alphaValue=0;root.layer?.opacity=0
        let canonical=ModeSurfaceBuilder(root,scale:1,includeWindowFrame:false,presentation:true,normalizeRootOpacity:true)
        while !canonical.ready {canonical.step()}
        let normalized=canonical.finish()!.flattened(),pixel=ModeFlightRoundEightVerification.rgb(normalized,x:160,y:96)
        check(pixel.0>240 && pixel.1<10,"B2 cold canonical photo keeps body ink when the mounted mode root is temporarily transparent")
        Offscreen.write(normalized,output.appendingPathComponent("canonical-body.png"))
        // A native glass's own CA ink must not be erased by that same material's footprint.
        root.alphaValue=1;root.layer?.opacity=1;marker.removeFromSuperview()
        let glass=NSGlassEffectView(frame:CGRect(x:40,y:50,width:240,height:80)),content=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:240,height:80))
        content.wantsLayer=true;glass.contentView=content;root.addSubview(glass)
        let ink=CALayer();ink.frame=CGRect(x:30,y:20,width:40,height:30);ink.backgroundColor=NSColor.red.cgColor;content.layer?.addSublayer(ink)
        let input=ModeSurfaceBuilder(root,scale:1,includeWindowFrame:false)
        while !input.ready {input.step()}
        let inputImage=input.finish()!.flattened(),inputPixel=ModeFlightRoundEightVerification.rgb(inputImage,x:90,y:85)
        check(inputPixel.0>240 && inputPixel.1<10,"B4 glass footprint clips ancestor canvases, preserving its internal CA text/control ink")
        Offscreen.write(inputImage,output.appendingPathComponent("input-ink.png"))
        let large=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:1280,height:820));large.wantsLayer=true
        let builder=ModeSurfaceBuilder(large,scale:1,includeWindowFrame:false)
        var completed=false,slices=0
        let started=CACurrentMediaTime()
        builder.completeInSlices(valid:{true},onSlice:{_ in slices+=1}) {_ in completed=true}
        while !completed,CACurrentMediaTime()-started<1 {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.0005))}
        let wall=(CACurrentMediaTime()-started)*1000
        check(completed && wall<65,"B1 cold source scheduling does not add a fixed 2ms timer for every tile: \(wall)ms")
        facts["coldEmptyWallMS"]=wall;facts["coldEmptySlices"]=slices
        try nativeCacheChecks(check:check,facts:&facts)
        let result:[String:Any]=["checks":checks,"findings":failures.count,"failures":failures,"facts":facts]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("round11-verification.json"))
        print("M11.31 round 11: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    private static func nativeCacheChecks(check:(Bool,String)->Void,facts:inout [String:Any]) throws {
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false);let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=root.bounds;root.addSubview(plane)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        let shell=WindowShell(organic:root,scene:scene,workbench:workbench,mode:.organic);_=shell.view
        defer {shell.disposeModePreparation();shell.flight.shutdown();workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        var now=CACurrentMediaTime();shell.flight.manualTime={now};shell.flight.verificationServerMotion=true
        shell.verificationFlightSettle(asOrganic:true);shell.prepareModeSwitch(reason:"round11.cache")
        var transferNotifications=0
        shell.verificationTargetObservation={_,_ in
            guard transferNotifications == 0,let transcript=sessions.transcripts.values.first,
                  let pinned=transcript.subviews.compactMap({$0 as? NSScrollView}).first(where:{$0 !== transcript.scrollView}) else {return}
            transferNotifications+=1
            // Native layout emits a bounds notification while moving the mounted transcript.
            NotificationCenter.default.post(name:NSView.boundsDidChangeNotification,object:pinned.contentView)
        }
        shell.verificationFlightToggle(toOrganic:false);shell.verificationFlightAdmit()
        shell.verificationTargetObservation=nil
        facts["transferNotifications"]=transferNotifications;facts["validAfterAdmission"]=shell.verificationReusablePictureModes
        let activePicture=shell.verificationContentSessionState["photoID"] as? String
        check(transferNotifications == 1 && activePicture != nil,"B1 the active Organic photo survives Native capture-revision notifications during admission")
        now+=0.54;shell.flight.advance(at:0.54)
        let began=CACurrentMediaTime();shell.verificationFlightToggle(toOrganic:true)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.025))
        check(shell.verificationContentPhase != nil && shell.verificationContentSessionState["photoID"] as? String == activePicture,"B3 returning direction commits the same picture phase without capture or mount")
        facts["turnFirstProbeMS"]=(CACurrentMediaTime()-began)*1000
        shell.verificationFlightAdmit()
        check(shell.verificationFlightPresentation["pending"] == false,"B2 turning back has no pending native admission inside the fixed session")
        // A real content edit must still invalidate that photo; the transfer rekey is never unconditional.
        if let conversation=workbench.selectedConversation {conversation.draft += " edited"}
        check(shell.verificationContentSessionState["photoID"] as? String == activePicture,"B1 changed content cannot evict the active picture epoch")
    }
    static func runLayout(to output:URL) throws -> Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let library=ProcessInfo.processInfo.environment["M1131_EXCEPTION_BRIDGE"] ?? "/tmp/organic-m1131k/libModeExceptionBridge.dylib"
        guard let handle=dlopen(library,RTLD_NOW),let symbol=dlsym(handle,"M11CatchLayout") else {throw NSError(domain:"ModeExceptionBridge",code:1)}
        typealias Catch = @convention(c) (UnsafeMutableRawPointer,@convention(block)(Int)->Void,Int)->UnsafePointer<CChar>?
        let guarded=unsafeBitCast(symbol,to:Catch.self)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1280,height:820),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua)
        let root=ModeFlight.Plane(frame:CGRect(x:0,y:0,width:1280,height:820));root.wantsLayer=true
        let controller=NSViewController();controller.view=root;window.contentViewController=controller
        let split=NSSplitViewController(),sidebar=NSViewController(),body=NSViewController()
        sidebar.view=ModeFlight.Plane();body.view=ModeFlight.Plane()
        let item=NSSplitViewItem(sidebarWithViewController:sidebar);item.minimumThickness=240;item.maximumThickness=400
        split.addSplitViewItem(item);split.addSplitViewItem(NSSplitViewItem(viewController:body))
        controller.addChild(split);split.view.frame=root.bounds;split.view.autoresizingMask=[.width,.height];root.addSubview(split.view)
        let front=ModeFlight.Plane(frame:root.bounds);root.addSubview(front)
        let bitmap=NativeViewBitmap.capture(ModeFlight.Plane(frame:CGRect(x:0,y:0,width:280,height:820)),scale:1),texture=ModeTurnSidebar()
        let theme=window.contentView!.superview!
        var phases=0,moved=false
        let mutate:@convention(block)(Int)->Void = {phase in MainActor.assumeIsolated {
            phases+=1
            if phase%2 == 0 {
                item.isCollapsed=false
                var ancestor=sidebar.view.superview,native:NSGlassEffectView?
                while let current=ancestor {if let glass=current as? NSGlassEffectView {native=glass;break};ancestor=current.superview}
                let nativeParent=native?.superview
                texture.begin(bitmap,source:sidebar.view,in:root,below:front,rect:CGRect(x:0,y:0,width:280,height:820),alpha:1,incoming:phase%4 == 0,scale:1)
                moved = moved || !sidebar.view.isDescendant(of:split.view) || (native != nil && native?.superview !== nativeParent)
                item.isCollapsed=phase%4 != 0
                split.view.setFrameSize(CGSize(width:1280+CGFloat(phase%6),height:820+CGFloat(phase%8)))
            } else {texture.finish();item.isCollapsed=false}
        }}
        let exception=guarded(Unmanaged.passUnretained(theme).toOpaque(),mutate,40).map {String(cString:$0)}
        let result:[String:Any]=["checks":3,"findings":exception == nil && !moved && !window.isVisible ? 0:1,"exception":exception ?? "","phases":phases,"movedSystemContent":moved,"windowVisible":window.isVisible]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("window-layout.json"))
        print("Hidden NSWindow layout: \(phases) phases; exception=\(exception != nil); visible=\(window.isVisible)")
        // A caught Objective-C exception can leave an invalid AppKit graph. The CLI owns it until process exit.
        _=Unmanaged.passRetained(window)
        return result["findings"] as? Int == 0 ? 0:1
    }
}
#endif
