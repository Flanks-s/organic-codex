#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Supplies only a key-window context for the inherited AppKit target resolver without showing a window.
@MainActor final class NormieInspectorVerificationApplication: NSApplication {
    var inspectorWindow:NSWindow?
    override var keyWindow:NSWindow? { inspectorWindow ?? super.keyWindow }
}

/// Exercises the system split command and the actual inspector without an app controller, visible window or transport.
@MainActor enum NormieInspectorVerification {
    private static var builtInScreen: NSScreen {
        NSScreen.screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
            return CGDisplayIsBuiltin(CGDirectDisplayID(id.uint32Value)) != 0
        }!
    }
    static func idle61(output: URL, check: (Bool, String) -> Void) throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func tree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(tree) }
        let screen = builtInScreen
        let diagnose = ProcessInfo.processInfo.environment["IDLE61_DIAGNOSE"] == "1"
        let size = CGSize(width:1280,height:820), store = ConversationStore()
        let replay = MockReplay(store:store); replay.start(live:false)
        let c = store.conversation("A")!; c.running = true
        c.error = nil; c.approvals = []; c.question = nil; c.userInput = nil
        c.plan = [.init(id:"idle61-plan",title:"Idle61 running step")]
        c.satellites = [.init(id:"idle61-child",face:"•ᴗ•",title:"Idle61 running child")]
        let sessions = NativeTranscriptSessions(store:store)
        let scene = AutoScene(size:size,store:store,profile:.init(name:"idle61",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),scale:screen.backingScaleFactor,transcriptSessions:sessions)
        scene.ambient = false; scene.manualSettle = true
        let root = RootView(frame:CGRect(origin:.zero,size:size)); root.wantsLayer = true
        for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] { plane.frame = root.bounds; root.addSubview(plane) }
        scene.install(); scene.settle()
        let workbench = NormieWorkbench(store:store,sessions:scene.composers,current:"A",transcriptSessions:sessions)
        let shell = WindowShell(organic:root,scene:scene,workbench:workbench,mode:.normie)
        let window = NSWindow(contentRect:CGRect(origin:screen.visibleFrame.origin,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:true,screen:screen)
        window.isReleasedWhenClosed = false; window.contentViewController = shell
        var states: [[String:Any]] = []
        for (index,mode) in [WindowShell.Mode.normie,.organic,.normie,.organic].enumerated() {
            if index == 0 { shell.apply(mode,in:window) }
            else { shell.setMode(mode,animated:false) }
            check(shell.mode == mode,"IDLE61 \(index) actual mode switch commits \(mode.rawValue)")
            if mode == .normie { shell.split.splitViewItems.last!.isCollapsed = false }
            shell.view.layoutSubtreeIfNeeded(); workbench.inspector.viewDidLayout()
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
            let spinners = tree(window.contentView!).compactMap { $0 as? NormieSidebarSpinner }
            var records: [[String:Any]] = []
            for (i,spinner) in spinners.enumerated() {
                var ancestors: [[String:Any]] = [], cursor: NSView? = spinner
                while let view = cursor {
                    ancestors.append(["class":String(describing:type(of:view)),"isHidden":view.isHidden,
                        "alpha":view.alphaValue,"layerOpacity":view.layer?.opacity ?? 1,
                        "translationX":view.layer?.value(forKeyPath:"transform.translation.x") as? NSNumber ?? 0,
                        "contentView":view === window.contentView])
                    if view === window.contentView { break }; cursor = view.superview
                }
                records.append(["index":i,"identifier":spinner.identifier?.rawValue ?? "",
                    "owner":String(describing:type(of:spinner.superview!)),
                    "hidden":spinner.isHiddenOrHasHiddenAncestor,"animating":spinner.verificationAnimating,"window":spinner.window != nil,"ancestors":ancestors])
                print("IDLE61 \(index) \(mode.rawValue) spinner \(i): hidden=\(spinner.isHiddenOrHasHiddenAncestor) animating=\(spinner.verificationAnimating) " + ancestors.map { "\($0["class"]!)(hidden=\($0["isHidden"]!),opacity=\($0["layerOpacity"]!),x=\($0["translationX"]!))" }.joined(separator:" -> "))
            }
            states.append(["mode":mode.rawValue,"index":index,"spinners":records])
            check(!window.isVisible,"IDLE61 \(index) window never shown")
            if !diagnose {
                check(!spinners.isEmpty,"IDLE61 \(index) real shell contains indicators")
                if mode == .organic {
                    check(spinners.allSatisfy { !$0.verificationAnimating },"IDLE61 \(index) Organic stops every indicator")
                    c.title += " updated"; store.changed(c)
                    check(tree(window.contentView!).compactMap { $0 as? NormieSidebarSpinner }.allSatisfy { !$0.verificationAnimating },"IDLE61 \(index) Organic reconfigured rows stay stopped")
                } else {
                    for (name,host) in [("sidebar",workbench.sidebar.view),("inspector",workbench.inspector.view)] {
                        if host.isHiddenOrHasHiddenAncestor {
                            check(tree(host).compactMap { $0 as? NormieSidebarSpinner }.allSatisfy { !$0.verificationAnimating },"IDLE61 \(index) Normie \(name) hidden native root stays stopped")
                            // The shell retains a hidden inspector root after returning from Organic.
                            // Explicitly show this fixture to exercise the visible inspector's lifecycle too.
                            host.isHidden = false
                        }
                        let visible = tree(host).compactMap { $0 as? NormieSidebarSpinner }.filter { !$0.isHiddenOrHasHiddenAncestor }
                        check(visible.count == (name == "inspector" ? 2:1) && visible.allSatisfy(\.verificationAnimating),"IDLE61 \(index) Normie \(name) visible running indicators animate")
                        host.isHidden = true
                        check(visible.allSatisfy { !$0.verificationAnimating },"IDLE61 \(index) \(name) ancestor hide stops indicators")
                        host.isHidden = false
                        check(visible.allSatisfy(\.verificationAnimating),"IDLE61 \(index) \(name) ancestor unhide restarts indicators")
                        for (i,spinner) in visible.enumerated() {
                            let owner = spinner.superview!
                            owner.isHidden = true
                            check(!spinner.verificationAnimating,"IDLE61 \(index) \(name) \(i) owner hide stops indicator")
                            owner.isHidden = false
                            check(spinner.verificationAnimating,"IDLE61 \(index) \(name) \(i) owner unhide restarts indicator")
                            spinner.isHidden = true
                            check(!spinner.verificationAnimating,"IDLE61 \(index) \(name) \(i) self hide stops indicator")
                            spinner.isHidden = false
                            check(spinner.verificationAnimating,"IDLE61 \(index) \(name) \(i) self unhide restarts indicator")
                            spinner.removeFromSuperview()
                            check(!spinner.verificationAnimating,"IDLE61 \(index) \(name) \(i) leaving window stops indicator")
                            owner.addSubview(spinner)
                            check(spinner.verificationAnimating,"IDLE61 \(index) \(name) \(i) entering window restarts indicator")
                        }
                    }
                    let side = tree(workbench.sidebar.view).compactMap { $0 as? NormieSidebarSpinner }.filter { !$0.isHiddenOrHasHiddenAncestor }
                    workbench.sidebarVisible = false
                    check(side.allSatisfy { !$0.verificationAnimating },"IDLE61 \(index) sidebar presentation withdrawal stops indicators without hiding")
                    workbench.sidebarVisible = true
                    check(side.allSatisfy(\.verificationAnimating),"IDLE61 \(index) sidebar presentation restoration restarts indicators")
                    workbench.inspector.presentationActive = false
                    check(tree(workbench.inspector.view).compactMap { $0 as? NormieSidebarSpinner }.allSatisfy { !$0.verificationAnimating },"IDLE61 \(index) inspector presentation withdrawal stops indicators")
                    workbench.inspector.presentationActive = true
                    c.running = false; c.satellites[0].done = true; store.changed(c)
                    check(tree(window.contentView!).compactMap { $0 as? NormieSidebarSpinner }.allSatisfy { !$0.verificationAnimating },"IDLE61 \(index) completed conversation and sub-agent stop every indicator")
                    c.running = true; c.satellites[0].done = false; store.changed(c)
                    for (name,host) in [("sidebar",workbench.sidebar.view),("inspector",workbench.inspector.view)] {
                        let active = tree(host).compactMap { $0 as? NormieSidebarSpinner }.filter { !$0.isHiddenOrHasHiddenAncestor }
                        check(!active.isEmpty && active.allSatisfy(\.verificationAnimating),"IDLE61 \(index) \(name) resuming work restarts indicators")
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject:["screen":screen.localizedName,"scale":screen.backingScaleFactor,"hz":screen.maximumFramesPerSecond,"states":states],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("idle61-spinners.json"))
        shell.disposeModePreparation(); workbench.dispose(); scene.disposeTranscriptPresentation()
        window.contentViewController = nil; window.close()
    }
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try idle61(output:output.appendingPathComponent("idle61"),check:check)
        var states: [[String: Any]] = []
        func tree(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(tree) }
        func labels(_ inspector: NormieInspectorController) -> [String] {
            tree(inspector.view).compactMap { ($0 as? NSTextField)?.stringValue }
        }
        func contentInk(_ image: CGImage, scale: CGFloat) -> Int {
            let bytes = image.dataProvider!.data! as Data
            var count = 0
            for y in Int(64*scale)..<min(image.height,Int(500*scale)) {
                for x in Int(14*scale)..<max(Int(14*scale),image.width-Int(14*scale)) {
                    let i = y*image.bytesPerRow+x*4
                    if min(bytes[i],bytes[i+1],bytes[i+2]) > 110 && bytes[i+3] > 200 { count += 1 }
                }
            }
            return count
        }
        func layout(_ shell: WindowShell) {
            shell.view.needsLayout = true; shell.view.layoutSubtreeIfNeeded()
            shell.workbench.inspector.viewDidLayout()
        }
        func toggle(_ shell: WindowShell) {
            shell.split.toggleInspector(nil)
            // Let AppKit finish its existing split animation before checking exposure and closed pixels.
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.35)); layout(shell)
        }
        func record(_ shell: WindowShell, _ name: String, scale: CGFloat) {
            let inspector = shell.workbench.inspector, document = inspector.scrollView.documentView!
            states.append(["name":name,"scale":scale,"collapsed":shell.split.splitViewItems.last!.isCollapsed,
                "active":inspector.presentationActive,"renderCount":inspector.renderCount,
                "view":NSStringFromRect(inspector.view.frame),"scroll":NSStringFromRect(inspector.scrollView.frame),
                "document":NSStringFromRect(document.frame),"children":document.subviews.count,"labels":labels(inspector),
                "textFrames":tree(inspector.view).compactMap { view -> [String:Any]? in
                    guard let label = view as? NSTextField else { return nil }
                    return ["text":label.stringValue,"frame":NSStringFromRect(label.frame),"wraps":label.cell?.wraps ?? false]
                }])
            Offscreen.write(NativeViewBitmap.capture(shell.split.view,scale:scale),output.appendingPathComponent(name+"-split@\(Int(scale))x.png"))
            if !shell.split.splitViewItems.last!.isCollapsed {
                Offscreen.write(NativeViewBitmap.capture(inspector.view,scale:scale),output.appendingPathComponent(name+"@\(Int(scale))x.png"))
            }
        }
        for scale: CGFloat in [1,2] {
            let prefix = "M11.28 \(Int(scale))x "
            let store = ConversationStore(), replay = MockReplay(store:store); replay.start(live:false)
            let size = CGSize(width:1280,height:820), sessions = NativeTranscriptSessions(store:store)
            let scene = AutoScene(size:size,store:store,profile:.init(name:"inspector",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),scale:scale,transcriptSessions:sessions)
            scene.ambient = false; scene.manualSettle = true
            let root = RootView(frame:CGRect(origin:.zero,size:size)); root.wantsLayer = true
            for plane in [scene.sceneView,scene.nativePlane,scene.peekNode.view,scene.dockView,scene.overlayPlane] { plane.frame = root.bounds; root.addSubview(plane) }
            scene.install(); scene.settle()
            let workbench = NormieWorkbench(store:store,sessions:scene.composers,current:"A",transcriptSessions:sessions)
            let shell = WindowShell(organic:root,scene:scene,workbench:workbench,mode:.normie)
            _ = shell.view; shell.view.frame = root.bounds; workbench.refresh(); layout(shell)
            let inspector = workbench.inspector, item = shell.split.splitViewItems.last!, c = store.conversation("A")!
            (inspector.view as? NormieView)?.verificationScale = scale
            check(item.isCollapsed && !inspector.presentationActive,prefix+"starts suspended and collapsed")
            check(inspector.renderCount == 0,prefix+"collapsed inspector does no cold content work")
            // This is the responder action used by NSToolbarItem.toggleInspector, not WindowShell.toggleInspector().
            toggle(shell)
            check(!item.isCollapsed && inspector.presentationActive && workbench.inspectorVisible,prefix+"system toolbar action enables content")
            check(inspector.view.frame.width >= 280 && inspector.view.frame.height > 0,prefix+"mounted inspector has nonzero product width")
            check(inspector.scrollView.frame.width > 0 && inspector.scrollView.frame.height > 0,prefix+"scroll viewport has nonzero dimensions")
            check(inspector.scrollView.documentView!.frame.width > 0 && inspector.scrollView.documentView!.frame.height > 0,prefix+"document has nonzero dimensions")
            check(["Status","Git","Goal","Progress","Context","Sub-agents"].allSatisfy(labels(inspector).contains),prefix+"mock displays all product sections")
            let status = tree(inspector.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Status" }
            if let status {
                let point = status.convert(CGPoint(x:status.bounds.midX,y:status.bounds.midY),to:shell.view)
                let hit = shell.view.hitTest(point)
                check(hit?.isDescendant(of:inspector.view) == true,prefix+"content is exposed through the actual shell hierarchy")
            } else { check(false,prefix+"Status heading exists for exposure check") }
            check(contentInk(NativeViewBitmap.capture(inspector.view,scale:scale),scale:scale) > Int(100*scale*scale),prefix+"actual mounted content paints ink below the heading")
            record(shell,"system-open",scale:scale)
            let originalTitle = c.title
            for cycle in 0..<3 {
                toggle(shell)
                check(item.isCollapsed && !inspector.presentationActive,prefix+"system close \(cycle) suspends rendering")
                let renders = inspector.renderCount
                c.title = "Inspector update \(cycle)"; store.changed(c)
                check(inspector.renderCount == renders,prefix+"hidden updates do not render")
                toggle(shell)
                check(labels(inspector).contains(c.title),prefix+"reopen \(cycle) shows the newest conversation data")
            }
            c.title = originalTitle; store.changed(c)
            inspector.showChanges(); inspector.toggleFile(c.changes.first!.path); layout(shell)
            check(tree(inspector.view).contains { $0 is NormieDiffTextView },prefix+"Changes mounts the existing selectable diff")
            check(labels(inspector).contains("Goal") && labels(inspector).contains("Context"),prefix+"Changes expands inside Status rather than replacing it")
            record(shell,"changes",scale:scale)
            inspector.showStatus(); inspector.motion.clock.manualTime = 1000
            c.plan.append(.init(id:"inspector-motion",title:"Inspector plan update",done:false)); store.changed(c)
            check(!inspector.motion.motions.isEmpty,prefix+"residual check starts with real in-flight inspector proxies")
            toggle(shell)
            check(inspector.motion.motions.isEmpty && !inspector.motion.clock.running,prefix+"closing retires motion proxies and clock")
            check(tree(inspector.view).allSatisfy { $0.isHiddenOrHasHiddenAncestor },prefix+"closed content has no exposed descendants")
            record(shell,"closed-after-motion",scale:scale)
            let closed = NativeViewBitmap.capture(shell.split.view,scale:scale).dataProvider!.data! as Data
            toggle(shell)
            check(inspector.view.alphaValue == 1 && labels(inspector).contains("Inspector plan update"),prefix+"reopen retains current content at full opacity")
            toggle(shell)
            let closedAgain = NativeViewBitmap.capture(shell.split.view,scale:scale).dataProvider!.data! as Data
            check(closed == closedAgain,prefix+"repeated close leaves identical actual split pixels with no residual")
            toggle(shell)
            inspector.motion.clock.manualTime = nil
            for cycle in 0..<2 {
                shell.prepareModeSwitch(reason:"inspector.roundtrip")
                var held = 0
                check(shell.verificationAdmitOrganic(heldAtCommit:&held),prefix+"roundtrip \(cycle) uses Organic admission")
                check(item.isCollapsed && !inspector.presentationActive,prefix+"Organic keeps the product's collapsed-inspector policy")
                shell.toggleInspector()
                check(item.isCollapsed,prefix+"Organic rejects the window inspector command")
                shell.split.toggleInspector(nil)
                check(item.isCollapsed,prefix+"Organic rejects the system inspector command")
                workbench.requestInspector(shown:true)
                check(!workbench.inspectorVisible && item.isCollapsed,prefix+"Organic rejects workbench inspector requests")
                let command = NSMenuItem(title:"Inspector",action:#selector(NSSplitViewController.toggleInspector(_:)),keyEquivalent:"i")
                check(!shell.split.validateUserInterfaceItem(command),prefix+"Organic disables system inspector menu validation")
                var context = NormieMenuContext(); context.normie = false
                check(!context.enabled(.inspector),prefix+"Organic disables the application inspector menu")
                shell.verificationAdmitNormie(); shell.verificationFinishNormieReplay(); layout(shell)
                toggle(shell)
                check(inspector.presentationActive && labels(inspector).contains("Inspector plan update"),prefix+"roundtrip \(cycle) reopens current Status content")
                record(shell,"roundtrip-\(cycle)",scale:scale)
            }
            check(workbench.newChat(),prefix+"empty-state fixture enters New Chat")
            layout(shell)
            check(labels(inspector).contains("Nothing Yet") && labels(inspector).contains("Status appears once the chat starts."),prefix+"New Chat has the product empty state")
            record(shell,"new-chat",scale:scale)
            _ = workbench.select("A")
            for width: CGFloat in [280,320,420] {
                // A separate unparented controller avoids capturing outside the mounted split's 280 pt clip.
                let sample = NormieInspectorController(store:store,actions:.init())
                sample.loadViewIfNeeded(); sample.view.frame.size = CGSize(width:width,height:820)
                (sample.view as? NormieView)?.verificationScale = scale
                sample.show(c); sample.viewDidLayout()
                let document = sample.scrollView.documentView!
                let plates = document.subviews.filter { $0.identifier?.rawValue.hasPrefix("section/") == true }
                check(document.frame.width == sample.scrollView.contentSize.width && document.frame.width == width,prefix+"\(Int(width))pt reflows in the same layout pass")
                check(plates.count == 5 && plates.allSatisfy { $0.frame.minX == 14 && $0.frame.maxX == width-14 },prefix+"\(Int(width))pt uses product grouped margins")
                check(document.subviews.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 },prefix+"\(Int(width))pt has no zero-size content")
                let image = NativeViewBitmap.capture(sample.view,scale:scale)
                check(contentInk(image,scale:scale) > Int(100*scale*scale),prefix+"\(Int(width))pt paints actual content below the heading")
                Offscreen.write(image,output.appendingPathComponent("width-\(Int(width))@\(Int(scale))x.png"))
            }
            let window=NSWindow(contentRect:CGRect(origin:builtInScreen.visibleFrame.origin,size:size),styleMask:[.titled,.resizable],backing:.buffered,defer:true,screen:builtInScreen)
            window.isReleasedWhenClosed=false;window.contentViewController=shell
            check(window.makeFirstResponder(window) && window.firstResponder === window,prefix+"window is first responder without being shown")
            let selector=#selector(NSSplitViewController.toggleInspector(_:))
            let command=NSMenuItem(title:"Inspector",action:selector,keyEquivalent:"i")
            let toolbarItem=NSToolbarItem(itemIdentifier:.toggleInspector);toolbarItem.action=selector
            let application=NSApp as? NormieInspectorVerificationApplication
            application?.inspectorWindow=window
            let target=NSApp.target(forAction:selector,to:nil,from:toolbarItem) as? WindowShell
            if application != nil {check(target === shell,prefix+"AppKit resolves the window content controller with a window first responder")}
            check(shell.responds(to:selector) && shell.validateUserInterfaceItem(command) && shell.validateToolbarItem(toolbarItem),prefix+"window content controller forwards Normie inspector validation")
            let wasCollapsed=item.isCollapsed
            shell.toggleInspector(toolbarItem);RunLoop.main.run(until:Date(timeIntervalSinceNow:0.35))
            check(item.isCollapsed != wasCollapsed,prefix+"window responder forwards the action to the split")
            shell.verificationAdmittedMode(.organic)
            check(!shell.validateUserInterfaceItem(command) && !shell.validateToolbarItem(toolbarItem),prefix+"window rejects Organic inspector validation")
            let organicCollapsed=item.isCollapsed;shell.toggleInspector(toolbarItem)
            check(item.isCollapsed == organicCollapsed,prefix+"window responder preserves the Organic action guard")
            shell.verificationAdmittedMode(.normie)
            states.append(["name":"window-responder","scale":scale,"firstResponderIsWindow":window.firstResponder === window,"targetResolved":target === shell,"globalTargetResolved":NSApp.target(forAction:selector,to:nil,from:toolbarItem) != nil,"visible":window.isVisible])
            application?.inspectorWindow=nil
            window.contentViewController=nil;window.close()
            shell.disposeModePreparation(); workbench.dispose(); scene.disposeTranscriptPresentation()
        }
        // A local live-shaped store exercises the same projections; no LiveConversationRuntime or transport is created.
        let c = Conversation(id:"live-inspector",title:"Live inspector fixture"); c.isLiveConversation = true; c.backendThreadID = "fixture-thread"
        c.items = [.init(id:"request",turnID:"fixture-turn",kind:.user,text:"Inspect the real conversation model")]
        let store = ConversationStore(conversations:[c],devices:MockSeed.devices); store.usesLiveCore = true
        let inspector = NormieInspectorController(store:store,actions:.init()); inspector.loadViewIfNeeded()
        inspector.view.frame = CGRect(x:0,y:0,width:320,height:820); inspector.viewDidLayout(); inspector.show(c)
        check(labels(inspector).contains("Context usage has not been reported"),"M11.28 live missing usage is explicit content")
        check(!labels(inspector).contains("Progress") && !labels(inspector).contains("Sub-agents"),"M11.28 live absent optional data creates no fabricated sections")
        EventReducer.apply(.init(id:1,time:nil,method:"turn/plan/updated",params:["turnId":"fixture-turn","plan":[["step":"Reported Core plan","status":"in_progress"]]]),to:c)
        EventReducer.apply(.init(id:2,time:nil,method:"thread/tokenUsage/updated",params:["tokenUsage":["last":["totalTokens":1234],"modelContextWindow":272000]]),to:c)
        c.branch = "fixture-branch"; c.gitDiffHash = "fixture-review"; c.gitPaths = ["file.swift"]
        c.changes = [.init(path:"file.swift",added:1,removed:1,lines:[.init(kind:.added,text:"new"),.init(kind:.removed,text:"old")])]
        c.satellites = [.init(id:"fixture-child",face:"•ᴗ•",threadID:"fixture-child",title:"Reported child task")]
        inspector.show(c)
        check(labels(inspector).contains("Reported Core plan") && labels(inspector).contains("1,234 of 272,000 tokens"),"M11.28 live reducer projections reach Status")
        check(labels(inspector).contains("Sub-agents"),"M11.28 live child projection reaches Status")
        inspector.showChanges(); inspector.toggleFile("file.swift")
        check(tree(inspector.view).compactMap { $0 as? NormieDiffTextView }.first?.string.contains("new") == true,"M11.28 live reviewed diff reaches Changes")
        check(labels(inspector).contains("Changes") && !labels(inspector).contains("Goal"),"M11.28 standalone island Changes retains its focused content contract")
        Offscreen.write(NativeViewBitmap.capture(inspector.view,scale:2),output.appendingPathComponent("live-shaped@2x.png"))
        try revisionChecks(output:output,check:check)
        try thirdRoundChecks(output:output,check:check)
        try JSONSerialization.data(withJSONObject:states,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("states.json"))
        check(NSApp.windows.allSatisfy { !$0.isVisible },"M11.28 creates no visible windows")
    }
    private static func revisionChecks(output: URL, check: (Bool,String) -> Void) throws {
        func labels(_ inspector:NormieInspectorController) -> [NSTextField] { inspector.scrollView.documentView!.subviews.compactMap{$0 as? NSTextField} }
        var measurements:[[String:Any]]=[]
        let store=ConversationStore(), replay=MockReplay(store:store);replay.start(live:false)
        let c=store.conversation("A")!, original=c.items
        let chinese=String(repeating:"检查右侧状态栏的中文目标在窄窗口中的换行、完整统计和第三行省略号。",count:4)
        for scale:CGFloat in [1,2] {for width:CGFloat in [280,320,420] {for language in ["en","zh"] {
            c.items=original
            if language == "zh",let i=c.items.firstIndex(where:{$0.kind == .user}) {c.items[i].text=chinese}
            let inspector=NormieInspectorController(store:store,actions:.init(),inlineChanges:true)
            inspector.loadViewIfNeeded();inspector.view.frame=CGRect(x:0,y:0,width:width,height:820)
            (inspector.view as? NormieView)?.verificationScale=scale;inspector.show(c);inspector.viewDidLayout()
            let tag="M11.28b \(Int(scale))x \(Int(width)) \(language) "
            let statistics=labels(inspector).first{$0.stringValue.contains("steps ·") && $0.stringValue.contains("sub-agents")}
            let goal=labels(inspector).first{$0.stringValue == c.items.first(where:{$0.kind == .user})?.text}
            check(statistics != nil && goal != nil,tag+"has real Goal text and statistics fixtures")
            if let statistics,let cell=statistics.cell,let goal,let goalCell=goal.cell {
                let required=ceil(cell.cellSize(forBounds:CGRect(x:0,y:0,width:statistics.frame.width,height:10000)).height)
                check(statistics.frame.height>=required,tag+"statistics fits the actual NSTextField cell layout")
                let plate=inspector.scrollView.documentView!.subviews.first{$0.identifier?.rawValue.hasPrefix("section/Goal/") == true}!
                check(plate.frame.maxY>=statistics.frame.minY+required+8,tag+"Goal card clears the last statistics line")
                check(goal.maximumNumberOfLines == 3 && goalCell.truncatesLastVisibleLine,tag+"three-line Goal requests native last-line ellipsis")
                check(goal.frame.height>=ceil(goalCell.cellSize(forBounds:CGRect(x:0,y:0,width:goal.frame.width,height:10000)).height),tag+"Goal fits the line-limited cell height")
                measurements.append(["tag":tag,"statisticsFrame":NSStringFromRect(statistics.frame),"cellHeight":required,"goalFrame":NSStringFromRect(goal.frame),"truncatesLastVisibleLine":goalCell.truncatesLastVisibleLine])
            }
            if let row=inspector.scrollView.documentView!.subviews.compactMap({$0 as? NormieInspectorChangesButton}).first {
                check(abs(row.trailingRect.maxX-row.bounds.maxX)<0.01,tag+"diff counts are pinned to the trailing edge")
            }
            Offscreen.write(NativeViewBitmap.capture(inspector.view,scale:scale),output.appendingPathComponent("revision-\(language)-\(Int(width))@\(Int(scale))x.png"))
        }}}
        c.items=original
        let stopped=Conversation(id:"stopped",title:"Stopped fixture")
        stopped.items=[.init(id:"request",turnID:"stopped-turn",kind:.user,text:"Do the work"),.init(id:"partial",turnID:"stopped-turn",kind:.assistant,text:"Partial result")]
        stopped.lastTurnInterrupted=true;stopped.running=false
        let status=NormieInspectorController(store:.init(conversations:[stopped]),actions:.init())
        status.loadViewIfNeeded();status.view.frame=CGRect(x:0,y:0,width:320,height:820);status.show(stopped);status.viewDidLayout()
        check(labels(status).contains{$0.stringValue == "Stopped"} && !labels(status).contains{$0.stringValue == "Complete"},"M11.28b interrupted work remains Stopped")
        let waiting=Conversation(id:"spinner",title:"Spinner fixture");waiting.running=true;waiting.question="Answer first"
        waiting.plan=[.init(id:"step",title:"Unfinished step",done:false)]
        let spinner=NormieInspectorController(store:.init(conversations:[waiting]),actions:.init())
        spinner.loadViewIfNeeded();spinner.view.frame=CGRect(x:0,y:0,width:320,height:820);spinner.show(waiting);spinner.viewDidLayout()
        let priorStatus=waiting.status,priorRenders=spinner.renderCount
        check(spinner.scrollView.documentView!.subviews.contains{$0 is NormieSidebarSpinner},"M11.28b running waiting fixture actually displays a Progress spinner")
        waiting.running=false;spinner.show(waiting)
        check(waiting.status == priorStatus,"M11.28b stop fixture retains the same Asking status and plan")
        check(spinner.renderCount>priorRenders && !spinner.scrollView.documentView!.subviews.contains{$0 is NormieSidebarSpinner},"M11.28b running-only change replaces the Progress spinner")
        let empty=NormieInspectorController(store:.init(),actions:.init());empty.loadViewIfNeeded()
        empty.view.frame=CGRect(x:0,y:0,width:320,height:820);empty.show(nil);empty.viewDidLayout()
        let sparkles=empty.scrollView.documentView!.subviews.compactMap{$0 as? NormieInspectorSymbol}.first{$0.name == "sparkles"}!
        let title=labels(empty).first{$0.stringValue == "Nothing Yet"}!
        check(sparkles.pointSize == 24 && abs(title.frame.minY-sparkles.frame.maxY-6)<0.01,"M11.28b New Chat uses a 24pt symbol and 6pt title gap")
        let live=Conversation(id:"task-copy",title:"Task copy");live.satellites=[.init(id:"child",face:"^-^")]
        let liveStore=ConversationStore(conversations:[live]);liveStore.usesLiveCore=true
        let agents=NormieInspectorController(store:liveStore,actions:.init());agents.loadViewIfNeeded();agents.view.frame=CGRect(x:0,y:0,width:320,height:820);agents.show(live);agents.viewDidLayout()
        check(agents.scrollView.documentView!.subviews.compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()?.contains(SheetSubAgentCopy.task(0)) == true},"M11.28b missing child thread ID uses the product task description even in a live-shaped store")
        try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("revision-text-metrics.json"))
    }
    private static func thirdRoundChecks(output:URL,check:(Bool,String)->Void) throws {
        let store=ConversationStore(),replay=MockReplay(store:store);replay.start(live:false)
        let c=store.conversation("A")!
        c.branch="feature/"+String(repeating:"very-long-branch-name-",count:12)
        for scale:CGFloat in [1,2] {
            let inspector=NormieInspectorController(store:store,actions:.init(),inlineChanges:true)
            inspector.loadViewIfNeeded();inspector.view.frame=CGRect(x:0,y:0,width:280,height:820)
            (inspector.view as? NormieView)?.verificationScale=scale
            inspector.show(c);inspector.viewDidLayout();inspector.view.layoutSubtreeIfNeeded()
            let branch=inspector.scrollView.documentView!.subviews.compactMap{$0 as? NormieInspectorBranchButton}.first!
            check(branch.titleRect.maxX+3<=branch.chevron.frame.minX && branch.chevron.frame.maxX<=branch.bounds.maxX,"M11.28c \(Int(scale))x long branch reserves separate title and chevron bounds")
            check(branch.titleRect.width>0 && branch.frame.width == 228,"M11.28c \(Int(scale))x 280pt branch retains its full-row hit target")
            Offscreen.write(NativeViewBitmap.capture(inspector.view,scale:scale),output.appendingPathComponent("long-branch@\(Int(scale))x.png"))
            let window=NSWindow(contentRect:CGRect(origin:builtInScreen.visibleFrame.origin,size:inspector.view.frame.size),styleMask:[.titled],backing:.buffered,defer:true,screen:builtInScreen)
            window.isReleasedWhenClosed=false;window.contentViewController=inspector
            check(inspector.beginCommit(),"M11.28c commit fixture opens the real form")
            inspector.motion.settle()
            let field=inspector.scrollView.documentView!.subviews.compactMap{$0 as? NormieField}.first!
            field.stringValue="Keep this in-progress commit message"
            check(window.makeFirstResponder(field),"M11.28c hidden window starts editing the commit field")
            let editor=field.currentEditor() as? NSTextView
            check(editor != nil,"M11.28c commit fixture has a native field editor")
            editor?.setSelectedRange(NSRange(location:5,length:4))
            let responder=window.firstResponder,selection=editor?.selectedRange(),renders=inspector.renderCount
            c.running=true;inspector.show(c)
            check(inspector.scrollView.documentView!.subviews.contains{$0 is NormieSidebarSpinner},"M11.28c open commit form receives the running Progress spinner")
            c.running=false;c.lastTurnInterrupted=true;inspector.show(c)
            let labels=inspector.scrollView.documentView!.subviews.compactMap{$0 as? NSTextField}
            check(inspector.renderCount>renders && labels.contains{$0.stringValue == "Stopped"} && !inspector.scrollView.documentView!.subviews.contains{$0 is NormieSidebarSpinner},"M11.28c open commit form updates Goal and retires the spinner")
            check(field.superview != nil && inspector.scrollView.documentView!.subviews.contains{$0 === field} && field.stringValue == "Keep this in-progress commit message","M11.28c updates retain the same commit field and entered text")
            check(window.firstResponder === responder && field.currentEditor() === editor && editor?.selectedRange() == selection,"M11.28c updates preserve the native editor focus and selection")
            window.contentViewController=nil;window.close();inspector.motion.settle()
        }
    }

}
#endif
