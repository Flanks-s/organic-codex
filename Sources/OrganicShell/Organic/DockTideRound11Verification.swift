#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Visibility evidence must reject a native control that hit-testing alone would admit.
@MainActor enum DockTideRound11Verification {
    static func run(to output:URL,check:(Bool,String)->Void)throws {
        NativeAppearance.apply(.init())
        let root=RootView(frame:CGRect(x:0,y:0,width:1280,height:820));root.wantsLayer=true
        let window=NSWindow(contentRect:root.bounds,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=root
        defer {window.contentView=nil;window.close()}
        let host=NativeInteractionSurface(frame:CGRect(x:20,y:20,width:500,height:500))
        host.wantsLayer=true;host.verificationWindowVisible=true;root.addSubview(host)
        let card=NativeTranscriptCard(frame:.zero)
        let approval=MockSeed.make().first {$0.id == "B"}!.approvals[0]
        card.configureApproval(approval,width:360,enabled:true,action:{_ in})
        host.addSubview(card);card.frame.origin=CGPoint(x:20,y:20)
        guard let button=TideRunVisibility.buttons(in:card).first else {check(false,"the actual approval card offers Run");return}
        var rows:[[String:Any]]=[]
        func sample(_ name:String)->[String:Any] {
            CATransaction.flush()
            var row=TideRunVisibility.inspect(button,window:window,relativeTo:root);row["case"]=name;rows.append(row);return row
        }
        let visible=sample("visible")
        check(visible["passed"] as? Bool == true,"a mounted native approval Run control is visible and hit-testable")
        check(visible["hitClass"] as? String == "NativeCardButton","receipt records the actual native hit class")
        check(visible["inWindow"] as? Bool == true && visible["cardInWindow"] as? Bool == true,"both card and control belong to the expected window")
        check((visible["effectiveAlpha"] as? Double ?? 0)>0,"the native ancestor chain has positive effective alpha")

        CATransaction.begin();CATransaction.setDisableActions(true);host.layer?.opacity=0;CATransaction.commit()
        let transparent=sample("transparent-layer")
        check(transparent["hitClass"] as? String == "NativeCardButton","a zero-alpha backing layer can still return the real native button from hitTest")
        check(transparent["passed"] as? Bool == false && transparent["effectiveAlpha"] as? Double == 0,"zero-alpha native paint cannot pass by hitTest alone")
        CATransaction.begin();CATransaction.setDisableActions(true);host.layer?.opacity=1;host.layer?.isHidden=true;CATransaction.commit()
        let hiddenLayer=sample("hidden-layer")
        check(hiddenLayer["passed"] as? Bool == false && hiddenLayer["layerHidden"] as? Bool == true,"a hidden native backing ancestor is rejected")
        host.layer?.isHidden=false;host.isHidden=true
        let hiddenView=sample("hidden-view")
        check(hiddenView["passed"] as? Bool == false && hiddenView["hidden"] as? Bool == true,"a hidden view ancestor is rejected")
        host.isHidden=false;host.alphaValue=0
        check(sample("zero-view-alpha")["passed"] as? Bool == false,"a zero-alpha view ancestor is rejected")
        host.alphaValue=1;let origin=host.frame.origin;host.setFrameOrigin(CGPoint(x:1500,y:20))
        let clipped=sample("outside-content")
        check(clipped["passed"] as? Bool == false && (clipped["visibleWindowRect"] as? [CGFloat]) == [0,0,0,0],"a native button outside the window content clip is rejected")
        host.setFrameOrigin(origin);card.removeFromSuperview()
        check(sample("detached")["passed"] as? Bool == false,"a detached retained decision card is rejected")
        host.addSubview(card)
        let blocker=NSView(frame:root.bounds);root.addSubview(blocker)
        check(sample("covered-hit")["passed"] as? Bool == false,"a different hit target cannot impersonate NativeCardButton")
        blocker.removeFromSuperview()
        check(sample("restored")["passed"] as? Bool == true,"restoring the real card restores its visible native action")
        check(!window.isVisible,"Run visibility verification never orders a window")
        try inactiveNormie(to:output,check:check)
        try JSONSerialization.data(withJSONObject:["rows":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("run-visibility.json"))
    }

    /// Admit the same idle-layout branch as a visible window without ever ordering a WindowServer surface.
    private final class EligibilityWindow:NSWindow {
        override var isVisible:Bool {true}
        override var isKeyWindow:Bool {true}
    }
    private static func inactiveNormie(to output:URL,check:(Bool,String)->Void)throws {
        var rows:[[String:Any]]=[]
        for scale:CGFloat in [1,2] {
            let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
            let sessions=NativeTranscriptSessions(store:store),size=CGSize(width:1280,height:820)
            let scene=AutoScene(size:size,store:store,profile:M10DockMotion.dell,scale:scale,transcriptSessions:sessions)
            scene.ambient=false;scene.manualSettle=true;scene.restOnSnapshot=true
            let root=RootView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
            let window=EligibilityWindow(contentRect:root.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=root
            let workbench=NormieWorkbench(store:store,sessions:scene.composers,current:"B",transcriptSessions:sessions)
            defer {workbench.dispose();scene.disposeTranscriptPresentation();sessions.dispose();window.contentView=nil;window.close()}
            workbench.detail.motionClock.manualTime=CACurrentMediaTime()
            workbench.view.frame=root.bounds;root.addSubview(workbench.view)
            workbench.detail.setTranscriptPresentationActive(true);workbench.detail.show(store.conversation("B"))
            workbench.view.layoutSubtreeIfNeeded();workbench.detail.view.layoutSubtreeIfNeeded()
            workbench.detail.beginModeHandoff();workbench.isNormie=false;workbench.detail.setTranscriptPresentationActive(false)
            workbench.view.isHidden=true
            for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] {plane.frame=root.bounds;root.addSubview(plane)}
            scene.setTranscriptPresentationActive(true)
            scene.install(members:MockSeed.windowMembers);scene.enterFocused("A",reason:"tide-r11-owner");scene.settle()
            scene.graft("B",at:1,reason:"tide-r11-owner");scene.settle();scene.showCaptures(false)
            workbench.detail.endModeHandoff();workbench.detail.view.needsLayout=true;workbench.detail.view.layoutSubtreeIfNeeded()
            guard let column=scene.columns.first(where:{$0.conversation.id == "B"}),
                  let button=TideRunVisibility.buttons(in:column.native).first else {
                check(false,"the Split fixture mounts B's canonical native Run card: \(scale)x");continue
            }
            let before=TideRunVisibility.inspect(button,window:window,relativeTo:root)
            store.apply(.init(id:991,time:Date().timeIntervalSince1970,method:"core/approvalRequested",params:["threadId":"D","approvalId":"tide-r11-other","title":"Allow fixture?","request":["method":"item/commandExecution/requestApproval","params":["itemId":"D-4","command":"printf fixture","availableDecisions":["decline","accept"]]]]))
            workbench.detail.view.needsLayout=true;workbench.detail.view.layoutSubtreeIfNeeded();CATransaction.flush()
            let after=TideRunVisibility.inspect(button,window:window,relativeTo:root)
            check(before["passed"] as? Bool == true,"Split owns the canonical B Run card before the unrelated request: \(scale)x")
            check(after["effectiveAlpha"] as? Double == 1,"inactive Normie layout cannot zero Organic's retained approval ink: \(scale)x")
            check(after["passed"] as? Bool == true,"the real Run card remains visible and clickable after hidden idle layout: \(scale)x")
            check(workbench.detail.activeMotionProxies.isEmpty,"inactive Normie creates no approval carry owner: \(scale)x")
            check(!window.occlusionState.contains(.visible),"visibility admission never orders a WindowServer surface: \(scale)x")
            rows.append(["scale":scale,"before":before,"after":after,"normie":workbench.isNormie,"proxyCount":workbench.detail.activeMotionProxies.count])
        }
        try JSONSerialization.data(withJSONObject:["rows":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("inactive-normie.json"))
    }
}
#endif
