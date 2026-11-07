#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Frozen materials, warm scheduling and tail following use a never-ordered production window.
@MainActor enum ModeContentComparisonVerification {
    static func run(to output:URL) throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],frames:[[String:Any]]=[],facts:[String:Any]=[:]
        func check(_ value:Bool,_ name:String) {checks+=1;if !value {failures.append(name);print("FAIL: "+name)}}
        func wait(_ t:Double) {RunLoop.main.run(until:Date(timeIntervalSinceNow:t))}
        let size=CGSize(width:1280,height:820),store=ConversationStore(),seed=MockReplay(store:store)
        seed.start(live:false)
        for c in store.conversations {c.running=false;c.sending=false;c.loading=false}
        let sessions=NativeTranscriptSessions(store:store)
        let scene=AutoScene(size:size,store:store,profile:ModeOrreryFlightVerification.profile,scale:2,transcriptSessions:sessions)
        scene.ambient=false;scene.manualSettle=true
        let root=NSView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
        // Match the production root direction without involving the normal application entry point.
        let organic=ComparisonRoot(frame:root.bounds);organic.wantsLayer=true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=organic.bounds;organic.addSubview(plane)}
        let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:store.conversations.first?.id,transcriptSessions:sessions)
        _=workbench.composerForHandoff();scene.install();scene.settle()
        // WindowShell's product root type is supplied by the offscreen executable, never App.main.
        let shell=makeShell(root:organic,scene:scene,workbench:workbench,size:size)
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.contentViewController=shell
        shell.installToolbar(in:window);window.contentView?.superview?.layoutSubtreeIfNeeded()
        defer {shell.disposeModePreparation();shell.flight.shutdown();window.contentViewController=nil;workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();seed.stopPlayback()}
        let driver=Timer(timeInterval:1/120,repeats:true) {_ in MainActor.assumeIsolated {if shell.flight.running {shell.flight.advance(at:shell.flight.elapsed)}}}
        RunLoop.main.add(driver,forMode:.common);defer {driver.invalidate()}
        func rest(_ organic:Bool) {
            shell.settlePendingMode();shell.flight.cancel();shell.verificationFlightSettle(asOrganic:organic);shell.verificationRepairRest(organic ? .organic:.normie)
            window.contentView?.superview?.layoutSubtreeIfNeeded();scene.settle()
        }
        func sample(_ label:String) {
            var state=shell.verificationComparisonState;state["label"]=label;frames.append(state)
            let width=state["width"] as? CGFloat ?? 0
            check(width>0 && width<=NormieSidebarMetrics.maximumWidth,"shared sidebar never fills the window at "+label)
        }
            rest(false);wait(0.65);shell.verificationForgetContentCandidate()
            let started=CACurrentMediaTime(),count=shell.verificationContentCaptureCosts.count
            // Repeat requests faster than the debounce: the original deadline must survive unchanged.
            for _ in 0..<25 {shell.verificationScheduleWarmCandidate();wait(0.05)}
            let deadline=Date(timeIntervalSinceNow:4)
            while shell.verificationContentCapturing,Date()<deadline {wait(0.01)}
            check(shell.verificationContentCaptureCosts.count>count,"quiet repeated warm requests cannot starve capture")
            facts["warmRequestElapsedMS"]=(CACurrentMediaTime()-started)*1000
            shell.setMode(.organic);shell.verificationFlightAdmit();sample("photo")
            let materials=shell.verificationComparisonState["materials"] as? [[String:Any]] ?? []
            facts["materials"]=materials
            check(materials.contains {($0["id"] as? String)?.contains("composer") == true},"frozen Normie picture retains a composer material")
            check(materials.contains {($0["id"] as? String)?.contains("approval") == true},"frozen Normie picture retains an approval material")
            check(materials.allSatisfy {$0["hasInk"] as? Bool == true},"every frozen material has independently captured ink")
            let ink=shell.verificationComparisonState["inkPixels"] as? [Int] ?? []
            check(ink.count == materials.count && ink.allSatisfy {$0>10},"glass ink images contain real nontransparent text and controls")
            facts["inkPixels"]=ink
            if let contents=shell.verificationComparisonPhoto.imageLayer.contents,CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image=contents as! CGImage
                let bitmap=NSBitmapImageRep(cgImage:image)
                check((bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.alphaComponent ?? 0)>0.999,"the frozen source bitmap is opaque behind independent glass")
            } else {check(false,"a complete frozen source bitmap is installed")}

            if let contents=shell.verificationComparisonPhoto.imageLayer.contents {Offscreen.write(contents as! CGImage,output.appendingPathComponent("picture-body.png"))}
            for (i,image) in shell.verificationComparisonMaterialImages.enumerated() {Offscreen.write(image,output.appendingPathComponent("picture-ink-\(i).png"))}

            let host=shell.verificationComparisonPhoto
            check(!host.subviews.contains {$0 is NativeComposer || $0 is NativeTranscriptCard},"a picture never borrows live editors or cards")
            shell.setMode(.normie);wait(0.3);sample("photo.turn")
            let after=shell.verificationComparisonState["materials"] as? [[String:Any]] ?? []
            check(after.count == materials.count || shell.verificationComparisonState["photo"] as? Bool == false,"reversal retains material ownership until the picture retires")
            // Exercise the production cold path after its source material has been hidden by the glass flight.
            rest(false);_ = workbench.detail.composer?.setText("Frozen source TOP\nBottom 271")
            shell.verificationForgetContentCandidate()
            shell.setMode(.organic);shell.verificationFlightAdmit();sample("cold.photo")
            let cold=shell.verificationComparisonState
            let coldMaterials=cold["materials"] as? [[String:Any]] ?? [],coldInk=cold["inkPixels"] as? [Int] ?? []
            check(coldMaterials.contains {($0["id"] as? String)?.contains("composer") == true} && coldMaterials.contains {($0["id"] as? String)?.contains("approval") == true},"cold flight capture retains both native material surfaces")
            check(coldInk.count>=2 && coldInk.allSatisfy {$0>10},"cold capture preserves real composer and approval ink after takeoff")
            facts["coldMaterials"]=coldMaterials;facts["coldInkPixels"]=coldInk
            for (i,image) in shell.verificationComparisonMaterialImages.enumerated() {Offscreen.write(image,output.appendingPathComponent("cold-ink-\(i).png"))}
            facts["captures"]=shell.verificationContentCaptureCosts
        // Independent tail-follow fixture crosses many lines; previous round stayed at its old reading anchor.
        let c=Conversation(id:"comparison.stream",title:"Stream")
        c.items=[TranscriptItem(id:"stream",turnID:"stream",kind:.assistant,text:String(repeating:"line\n",count:30),status:"running")];c.running=true
        let transcript=NativeTranscript(conversation:c);transcript.frame=CGRect(x:0,y:0,width:500,height:180);transcript.verificationWindowVisible=true
        defer {transcript.dispose()}
        transcript.refresh(allowHidden:true);transcript.scrollToEnd();transcript.verificationManualModeCatchup=true;transcript.beginModeContentEpoch()
        c.items[0].text += String(repeating:"new line\n",count:40);c.revision+=1;transcript.endModeContentEpoch()
        for _ in 0..<100 {transcript.verificationModeCatchupStep()}
        check(!transcript.modeContentIsCatchingUp && transcript.isAtEnd && transcript.readerFollowsEnd,"fade catchup restores the original tail-follow intent")
        check(!window.isVisible,"all checks use a never-ordered real NSWindow")
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"frames":frames,"facts":facts],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("comparison.json"))
        print("M11.31 comparison: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
    private static func makeShell(root:NSView,scene:AutoScene,workbench:NormieWorkbench,size:CGSize)->WindowShell {
        let product=RootView(frame:CGRect(origin:.zero,size:size));product.wantsLayer=true
        for plane in root.subviews {product.addSubview(plane)}
        return WindowShell(organic:product,scene:scene,workbench:workbench,mode:.organic)
    }
    private final class ComparisonRoot:NSView {override var isFlipped:Bool {true}}
    private static func pixelDifference(_ a:CGImage,_ b:CGImage)->Int {
        guard a.width == b.width,a.height == b.height else {return max(a.width*a.height,b.width*b.height)}
        func rgba(_ image:CGImage)->[UInt8] {
            var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
            bytes.withUnsafeMutableBytes {buffer in
                let c=CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            };return bytes
        }
        let x=rgba(a),y=rgba(b);return stride(from:0,to:x.count,by:4).reduce(0) {n,i in n+(x[i..<i+4].elementsEqual(y[i..<i+4]) ? 0:1)}
    }
}
#endif
