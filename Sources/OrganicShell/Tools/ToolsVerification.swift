#if TOOLS_SELFTEST
import AppKit
import ObjectiveC
import Darwin

@main @MainActor enum ToolsVerification {
    static var checks=0,findings:[String]=[]
    static func check(_ value:Bool,_ text:String) { checks+=1; if !value { findings.append(text); print("FINDING: "+text); fflush(nil) } }
    static func wait(_ name:String,_ predicate:()->Bool) async {
        for _ in 0..<20000 { if predicate() { return }; await Task.yield() }; check(false,"Timed out: "+name)
    }
    static func write(_ image:CGImage,_ path:URL) throws { try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:path) }
    static func views(_ root:NSView)->[NSView] { [root]+root.subviews.flatMap(views) }
    static func audit(_ root:NSView) {
        let selector=#selector(NSView.draw(_:))
        for view in views(root) {
            if view is NSTextField || view is NSButton || view is NSTextView {
                let cls=type(of:view),base:AnyClass=view is NSButton ? NSButton.self:view is NSTextField ? NSTextField.self:NSTextView.self
                let actual=class_getInstanceMethod(cls,selector).map(method_getImplementation),ordinary=class_getInstanceMethod(base,selector).map(method_getImplementation)
                check(actual != ordinary,"§7.5 draw override: "+String(describing:cls))
                if let button=view as? NSButton { check(!button.isBordered,"no system button bezel") }
                if let field=view as? NSTextField { check(!field.isBordered && !field.isBezeled,"no system field bezel") }
            }
        }
    }
    static func event(_ code:UInt16,_ chars:String="",_ flags:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)!
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.appearance=NSAppearance(named:.darkAqua)
        ToolsDisplayEnvironment.shared.setOverride(.init()); defer { ToolsDisplayEnvironment.shared.setOverride(nil) }
        let directory=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/sol-tools-m8-results",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let fake=CoreControllerFixture(),store=ConversationStore(),c=Conversation(id:"tools-target",title:"Tools target")
        c.backendThreadID="t1"; c.cwd="/fixture"; store.add(c)
        fake.png=makeImage()
        fake.terminalDescriptors=[["id":"recorded-pty","threadId":"t1","cwd":"/fixture","running":true]]
        fake.terminalRunning["recorded-pty"]=true
        fake.chunks["recorded-pty"]=[["sequence":1,"data":"Recorded PTY\r\n\u{1b}[32mCore-owned session\u{1b}[0m\r\n"]]
        let runtime=MockConversationRuntime(store:store,animatePlayback:false),controller=CoreArtifactsController(storage:CoreMemoryStorage()),terminal=CoreTerminalController()
        controller.configure(client:fake.transport,runtime:runtime,endpoint:"fixture"); terminal.configure(client:fake.transport,store:store)
        var delivered:[CoreArtifactDelivery]=[]; controller.onDeliver={ value,finish in delivered.append(value); finish(.accepted) }
        let windowOwner=ToolsWindowController(artifacts:controller,terminal:terminal),root=windowOwner.content
        check(windowOwner.window == nil && !windowOwner.isPresented,"constructing Tools never creates or shows a window")
        root.setDestination(c.id)
        await wait("initial artifacts") { !controller.busy && controller.artifacts.count == 2 }
        root.selectArtifact("text"); await wait("text preview") { controller.selectedData != nil }
        root.update(); root.layoutSubtreeIfNeeded()
        check(root.preview.kind == .text && root.preview.text.string.contains("Recorded artifact"),"native read-only text preview loads Core bytes")
        check(!root.preview.text.isEditable && !root.preview.text.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")),"preview AX is read-only")
        root.comment.stringValue="UI annotation"; root.comment.onEdit?("UI annotation"); root.save.performClick(nil)
        await wait("annotation Save") { !controller.busy && controller.annotations.count == 1 }
        check(root.annotationList.rows.count == 1,"shared annotation updates native list")
        if let row=root.annotationList.accessibilityChildren()?.first as? NSAccessibilityElement { check(row.accessibilityPerformPress(),"AX annotation row forwards native selection") }
        root.deleteNote.performClick(nil); await wait("annotation delete") { !controller.busy && controller.annotations.isEmpty }
        root.attach.performClick(nil); await wait("artifact attach") { !controller.busy && delivered.count == 1 }
        check(delivered[0].destinationID == c.id && !delivered[0].send,"Attach hands prepared input to host")
        root.send.performClick(nil); await wait("artifact send") { !controller.busy && delivered.count == 2 }
        check(delivered[1].send && runtime.replay.emitted == 0,"Send delegates completion without runtime Bool acknowledgement")
        root.artifactList.select(0); root.artifactList.keyDown(with:event(125)); check(root.artifactList.selectedID == root.artifactList.rows.last?.id,"native artifact arrows select next row")
        audit(root)
        for scale:CGFloat in [1,2] {
            root.verificationScale=scale
            for view in views(root) { (view as? ToolsView)?.verificationScale=scale }
            root.frame=CGRect(x:0,y:0,width:1000,height:740); root.setDestination(c.id)
            root.selectSection(.artifacts); await wait("capture artifacts section") { !controller.busy }; root.selectArtifact("text"); await wait("capture text content") { controller.selectedData != nil }; root.update(); root.layoutSubtreeIfNeeded()
            try write(root.snapshot(scale:scale),directory.appendingPathComponent("artifacts@\(Int(scale))x.png"))
            for section in [ToolsRootView.Section.browser,.capture,.terminal] {
                root.selectSection(section); await wait("section settled") { !controller.busy }
                if section == .browser {
                    controller.selectBrowserTab("tab&1"); controller.inspectBrowser(); await wait("browser DOM fixture") { !controller.busy }
                    controller.screenshotBrowser(); await wait("browser image fixture") { !controller.busy }
                }
                if section == .terminal { check(await terminal.restore(),"terminal section restores a recorded Core PTY") }
                for view in views(root) { (view as? ToolsView)?.verificationScale=scale }
                root.update(); root.layoutSubtreeIfNeeded()
                #if canImport(SwiftTerm)
                if section == .terminal,let surface=views(root).compactMap({ $0 as? ToolsTerminalSurface }).first {
                    await wait("SwiftTerm replay buffer") { (surface.terminal.accessibilityValue() as? String)?.contains("Core-owned session") == true }
                    check((surface.terminal.accessibilityValue() as? String)?.contains("Recorded PTY") == true,"SwiftTerm receives replay before first host layout without one-cell wrapping")
                }
                #endif
                try write(root.snapshot(scale:scale),directory.appendingPathComponent("\(section.rawValue.lowercased())@\(Int(scale))x.png"))
            }
            root.frame.size=CGSize(width:780,height:560)
            root.selectSection(.browser); await wait("narrow browser") { !controller.busy }; root.layoutSubtreeIfNeeded()
            check([root.readPage,root.shot,root.attachShot,root.external].allSatisfy { root.bounds.contains($0.frame) },"minimum width keeps all browser actions inside Tools")
            check(root.performKeyEquivalent(with:event(18,"1",.command)) && root.section == .artifacts,"Cmd-1 selects artifacts through native key-equivalent routing")
            await wait("key equivalent section") { !controller.busy }
            root.selectArtifact("image"); await wait("artifact region fixture") { controller.selectedData != nil }; root.layoutSubtreeIfNeeded()
            root.preview.selectRegion(from:root.preview.imageRect.origin,to:CGPoint(x:root.preview.imageRect.midX,y:root.preview.imageRect.midY))
            let artifactRegion=controller.region
            root.selectSection(.browser); await wait("browser region isolation") { !controller.busy }; root.layoutSubtreeIfNeeded()
            root.preview.selectRegion(from:.zero,to:CGPoint(x:20,y:20))
            check(artifactRegion != nil && controller.region == artifactRegion,"browser screenshot cannot overwrite artifact annotation geometry")
            root.selectSection(.artifacts); await wait("artifact region restoration") { !controller.busy }; root.layoutSubtreeIfNeeded()
            check(root.preview.region == artifactRegion,"returning to artifact restores its retained selection region")
            let longText=String(repeating:"Long recorded preview line\n",count:120)
            root.preview.configure(artifact:CoreArtifact(raw:["id":"long","mimeType":"text/plain"]),data:Data(longText.utf8))
            root.layoutSubtreeIfNeeded(); root.preview.layoutSubtreeIfNeeded()
            check(root.preview.text.frame.height>root.preview.textScroll.contentSize.height,"long text grows the native scroll document")
            let clip=root.preview.textScroll.contentView
            clip.scroll(to:CGPoint(x:0,y:29.3))
            check(abs(clip.bounds.minY*scale-(clip.bounds.minY*scale).rounded())<0.0001,"scroll offset stays on backing pixels")
            let preview=ToolsArtifactPreview(frame:CGRect(x:0,y:0,width:600,height:320)); preview.verificationScale=scale
            let imageData=makeImage()
            preview.configure(artifact:CoreArtifact(raw:["id":"fixture-image","mimeType":"image/png","name":"Image"]),data:imageData)
            check(preview.kind == .image && preview.imageRect.width>0,"native image format")
            preview.selectRegion(from:CGPoint(x:preview.imageRect.minX-50,y:preview.imageRect.minY-30),to:CGPoint(x:preview.imageRect.maxX+40,y:preview.imageRect.maxY+50))
            check(preview.region?["x"] == 0 && preview.region?["y"] == 0 && preview.region?["width"] == 1 && preview.region?["height"] == 1 && preview.region?["origin"] == "top-left","region clamps to normalized image coordinates")
            try write(preview.snapshot(scale:scale),directory.appendingPathComponent("preview-image@\(Int(scale))x.png"))
            preview.configure(artifact:CoreArtifact(raw:["id":"fixture-pdf","mimeType":"application/pdf","name":"PDF"]),data:makePDF())
            check(preview.kind == .pdf && preview.pageCount == 2,"native PDF loads all pages")
            preview.showPage(2); check(preview.page == 2,"PDF page selection retains annotation page"); preview.showPage(999); check(preview.page == 2,"PDF page upper bound")
            try write(preview.snapshot(scale:scale),directory.appendingPathComponent("preview-pdf@\(Int(scale))x.png"))
            preview.configure(artifact:CoreArtifact(raw:["id":"fixture-html","mimeType":"text/html","name":"HTML"]),data:Data("<!doctype html><html><body><h1>Recorded HTML</h1><p>No external resources.</p></body></html>".utf8))
            check(preview.kind == .html,"HTML uses native WebKit endpoint")
            preview.configure(artifact:CoreArtifact(raw:["id":"fixture-csv","mimeType":"text/csv","name":"CSV"]),data:Data("name,value\nfirst,1\nsecond,2\n".utf8))
            check(preview.kind == .text && preview.text.string.contains("second,2"),"CSV and code use selectable native text")
            preview.configure(artifact:CoreArtifact(raw:["id":"unknown","mimeType":"application/octet-stream"]),data:Data([0xff,0xfe,0xff]))
            check(preview.kind == .binary,"binary format doesn't invent a preview")
            audit(preview)
            let demo=ToolsDemoArtifacts(),demoOwner=ToolsWindowController(artifacts:CoreArtifactsController(storage:CoreMemoryStorage()),terminal:CoreTerminalController(),demo:demo),demoRoot=demoOwner.content
            demoRoot.verificationScale=scale; for view in views(demoRoot) { (view as? ToolsView)?.verificationScale=scale }
            demoRoot.selectArtifact("demo-notes"); demoRoot.layoutSubtreeIfNeeded()
            check(!demoRoot.attach.isEnabled && !demoRoot.send.isEnabled,"demo cannot claim live artifact delivery")
            for section in [ToolsRootView.Section.browser,.capture,.terminal] {
                demoRoot.selectSection(section)
                if section == .browser { check(!demoRoot.openPage.isEnabled,"demo browser doesn't create owned tabs") }
                if section == .capture { check(!demoRoot.capture.isEnabled,"demo doesn't request capture permissions") }
                if section == .terminal { check(!demoRoot.newTerminal.isEnabled,"demo doesn't spawn a shell") }
            }
            demoRoot.selectSection(.artifacts); demoRoot.layoutSubtreeIfNeeded(); try write(demoRoot.snapshot(scale:scale),directory.appendingPathComponent("demo@\(Int(scale))x.png")); audit(demoRoot)
            var demoUpdates=0; let token=demo.observe { demoUpdates+=1 }
            demo.add(artifact:"demo-notes",text:"Shared demo note",quote:"",region:nil)
            demo.delete(artifact:"demo-notes",id:demo.annotations["demo-notes"]!.last!["id"]!.stringValue!)
            check(demoUpdates == 2,"shared demo annotations notify every observer on create and delete"); demo.removeObserver(token)
        }
        root.selectSection(.artifacts); await wait("accessible artifact section") { !controller.busy }
        root.selectArtifact("text"); await wait("accessible preview") { controller.selectedData != nil }; root.update(); root.layoutSubtreeIfNeeded()
        let selection=root.artifactList.selectedID,previewKind=root.preview.kind,oldFrame=root.preview.frame
        var displayChanges=0; let displayToken=ToolsDisplayEnvironment.shared.observe { displayChanges+=1 }
        for options in [ToolsDisplayEnvironment.Options(increaseContrast:true),.init(reduceTransparency:true),.init(increaseContrast:true,reduceTransparency:true)] {
            ToolsDisplayEnvironment.shared.setOverride(options)
            check(root.preview.layer?.backgroundColor?.alpha == 1,"display options make retained preview background opaque")
            check(ToolsDisplayEnvironment.surface(.white,opacity:0.055).alphaComponent == 1,"display options make Tools decorative plates opaque")
            check(root.artifactList.selectedID == selection && root.preview.kind == previewKind && root.preview.frame == oldFrame,"Workspace display notification preserves Tools selection, content and geometry")
            check(root.appearance?.name == NSAppearance(named:options.increaseContrast ? .accessibilityHighContrastDarkAqua:.darkAqua)?.name,"Tools requests the system high-contrast appearance when enabled (OS may resolve its fallback)")
            for scale:CGFloat in [1,2] {
                for view in views(root) { (view as? ToolsView)?.verificationScale=scale }
                try write(root.snapshot(scale:scale),directory.appendingPathComponent("a11y-\(options.increaseContrast ? "contrast":"transparency")-\(options.reduceTransparency)@\(Int(scale))x.png"))
            }
        }
        check(displayChanges == 3,"Tools receives live Workspace display notifications")
        ToolsDisplayEnvironment.shared.removeObserver(displayToken); ToolsDisplayEnvironment.shared.setOverride(.init())
        var buffer=ToolsTerminalBuffer(columns:8,rows:3)
        buffer.feed("one\r\ntwo"); check(buffer.screen[1][0].text == "t","terminal CRLF returns to first column")
        buffer.feed("\u{1b}["); buffer.feed("31mR\u{1b}[0m"); check(buffer.screen[1][3].foreground == 1,"ANSI CSI survives split chunks")
        buffer.feed("\u{1b}[2J\u{1b}[Hhome"); check(buffer.screen[0][0].text == "h","terminal clear and cursor home")
        buffer.feed("\u{1b}]2;Fixture"); buffer.feed(" title\u{7}"); check(buffer.title == "Fixture title","OSC title incremental parse")
        buffer.feed("\u{1b}[?1049hother\u{1b}[?1049l"); check(buffer.screen[0][0].text == "h","alternate screen restores primary buffer")
        buffer.resize(columns:10,rows:4); check(buffer.screen.count == 4 && buffer.screen.allSatisfy { $0.count == 10 },"terminal resize preserves rectangular grid")
        let view=ToolsTerminalView(frame:CGRect(x:0,y:0,width:800,height:320)); view.layoutSubtreeIfNeeded(); view.feed("Native terminal\r\n\u{1b}[32mrecorded output\u{1b}[0m")
        for (code,value) in [(UInt16(36),"\r"),(126,"\u{1b}[A"),(51,"\u{7f}"),(48,"\t")] { check(view.input(for:event(code)) == value,"terminal keyboard encoding\(code)") }
        check(view.input(for:event(8,"c",.control)) == "\u{3}","native Ctrl-C encoding")
        check(!view.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")) && (view.accessibilityValue() as? String)?.contains("recorded output") == true,"terminal exposes rendered read-only AX text")
        view.selectAll(nil); check(view.selectedText.contains("Native terminal"),"terminal native Select All selects rendered text")
        for scale:CGFloat in [1,2] { view.verificationScale=scale; view.needsLayout=true; view.layoutSubtreeIfNeeded(); try write(view.snapshot(scale:scale),directory.appendingPathComponent("terminal-renderer@\(Int(scale))x.png")) }
        try await pty(directory:directory)
        try await ToolsPDFVerification.run(directory:directory)
        check(windowOwner.window == nil && NSApp.windows.isEmpty,"all verification remains windowless")
        try PlainControlSourceAuditVerification.run(component:"Tools",evidenceDirectory:directory) { check($0,$1) }
        let renderer=ToolsTerminalSurface.fullVTCompatibility ? "SwiftTerm adapter linked: buffer/AX/delegate/state checked. Its windowless cacheDisplay omits glyphs, also reproduced with an unmodified TerminalView; PNGs are NOT a SwiftTerm renderer parity pass.\n":"Basic renderer: native 1x/2x cacheDisplay images generated. Full VT/TUI requires the documented SwiftTerm dependency.\n"
        let report="Tools verification: \(checks) checks, \(findings.count) findings\n"+findings.map { "FAIL: "+$0 }.joined(separator:"\n")+"\nWindow count: \(NSApp.windows.count). Core requests: in-memory only. PTY subprocess: /usr/bin/printf only.\n"+renderer+"HTML state uses WKWebView; no real-window WebKit/glass/VoiceOver parity claim.\n"
        try report.write(to:directory.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8); print(report)
        runtime.shutdown(); if !findings.isEmpty { exit(1) }
    }
    static func makeImage()->Data {
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:320,pixelsHigh:180,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
        NSColor.systemTeal.setFill(); CGRect(x:0,y:0,width:320,height:180).fill(); NSColor.systemOrange.setFill(); NSBezierPath(ovalIn:CGRect(x:90,y:25,width:140,height:130)).fill(); NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using:.png,properties:[:])!
    }
    static func makePDF()->Data {
        let data=NSMutableData(),consumer=CGDataConsumer(data:data as CFMutableData)!
        var box=CGRect(x:0,y:0,width:320,height:400); let context=CGContext(consumer:consumer,mediaBox:&box,nil)!
        for index in 0..<2 { context.beginPDFPage(nil); context.setFillColor((index == 0 ? NSColor.systemBlue:NSColor.systemGreen).cgColor); context.fill(CGRect(x:30,y:30,width:260,height:340)); context.endPDFPage() }; context.closePDF(); return data as Data
    }
    static func pty(directory:URL) async throws {
        var master:Int32=0,slave:Int32=0,size=winsize(ws_row:24,ws_col:80,ws_xpixel:0,ws_ypixel:0)
        guard openpty(&master,&slave,nil,nil,&size) == 0 else { throw CoreWire.failure("openpty failed") }
        defer { Darwin.close(master); Darwin.close(slave) }
        _ = fcntl(master,F_SETFL,O_NONBLOCK); _ = fcntl(slave,F_SETFL,O_NONBLOCK)
        func writeFD(_ descriptor:Int32,_ value:String) throws { let data=Data(value.utf8); let count=data.withUnsafeBytes { Darwin.write(descriptor,$0.baseAddress,data.count) }; if count != data.count { throw CoreWire.failure("PTY write failed") } }
        func readFD(_ descriptor:Int32,contains:String) async -> String {
            var text="",bytes=[UInt8](repeating:0,count:4096)
            for _ in 0..<200 { let count=Darwin.read(descriptor,&bytes,bytes.count); if count>0 { text += String(decoding:bytes.prefix(count),as:UTF8.self); if text.contains(contains) { return text } }; try? await Task.sleep(for:.milliseconds(5)) }; return text
        }
        try writeFD(master,"from master\n"); let input=await readFD(slave,contains:"from master"); check(input.contains("from master"),"real PTY master write reaches slave")
        try writeFD(slave,"from slave\n"); let output=await readFD(master,contains:"from slave"); check(output.contains("from slave"),"real PTY slave output reaches master")
        size.ws_col=101; size.ws_row=37; check(ioctl(master,TIOCSWINSZ,&size) == 0,"PTY TIOCSWINSZ succeeds")
        var actual=winsize(); check(ioctl(slave,TIOCGWINSZ,&actual) == 0 && actual.ws_col == 101 && actual.ws_row == 37,"PTY dimensions reach slave")
        let temporary=directory.appendingPathComponent("pty",isDirectory:true); try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/printf"); process.arguments=["PTY printf fixture\\n"]; process.currentDirectoryURL=temporary
        let handle=FileHandle(fileDescriptor:slave,closeOnDealloc:false); process.standardInput=handle; process.standardOutput=handle; process.standardError=handle
        try process.run(); process.waitUntilExit(); let printed=await readFD(master,contains:"PTY printf fixture")
        check(process.terminationStatus == 0 && printed.contains("PTY printf fixture"),"only harmless printf subprocess in temporary working directory")
    }
}
#endif
