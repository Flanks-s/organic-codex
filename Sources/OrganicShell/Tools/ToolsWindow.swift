import AppKit

@MainActor final class ToolsDemoArtifacts {
    var artifacts:[CoreArtifact]=[],data:[String:Data]=[:],annotations:[String:[JSONValue]]=[:]
    var onChange:(()->Void)?
    private var observers:[UUID:()->Void]=[:]
    func observe(_ callback:@escaping ()->Void)->UUID { let id=UUID(); observers[id]=callback; return id }
    func removeObserver(_ id:UUID) { observers[id]=nil }
    private func notify() { onChange?(); for callback in Array(observers.values) { callback() } }
    init() {
        let id="demo-notes"
        artifacts=[CoreArtifact(raw:["id":.string(id),"name":"Preview notes · demo","mimeType":"text/markdown","bytes":90,"sha256":"demo-only"])]
        data[id]=Data("# Preview notes\n\nThis is an in-memory demo artifact.\nNo Core, browser, capture or shell is running.\n".utf8)
    }
    func add(artifact:String,text:String,quote:String,region:JSONValue?) {
        var note:[String:JSONValue]=["id":.string(UUID().uuidString),"artifactId":.string(artifact),"text":.string(text),"quote":.string(quote),"kind":"comment"]
        note["geometry"]=region; annotations[artifact,default:[]].append(.object(note)); notify()
    }
    func delete(artifact:String,id:String) { annotations[artifact]?.removeAll { $0["id"]?.stringValue == id }; notify() }
}

/// No window is constructed by init/content loading. Host calls present explicitly after wiring delivery.
@MainActor final class ToolsWindowController:NSObject,NSWindowDelegate {
    let content:ToolsRootView
    private(set) var window:NSWindow?
    var isPresented:Bool { window?.isVisible == true }
    init(artifacts:CoreArtifactsController,terminal:CoreTerminalController,demo:ToolsDemoArtifacts?=nil) { content=ToolsRootView(artifacts:artifacts,terminal:terminal,demo:demo); super.init() }
    func present(section:ToolsRootView.Section = .artifacts,conversationID:String?=nil) {
        if let conversationID { content.setDestination(conversationID) }; content.selectSection(section)
        if window == nil {
            let w=NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            w.title="Organic · Tools"; w.minSize=CGSize(width:780,height:560); w.isReleasedWhenClosed=false; w.contentView=content; w.delegate=self; w.center(); window=w
        }
        window?.makeKeyAndOrderFront(nil)
    }
    func dismiss() { window?.orderOut(nil) }
    func windowWillClose(_ notification:Notification) { /* Core owns sessions. Never close PTYs because this view disappears. */ }
}

@MainActor final class ToolsRootView:ToolsView {
    enum Section:String,CaseIterable { case artifacts="Artifacts",browser="Browser",capture="Appshots",terminal="Terminal" }
    let controller:CoreArtifactsController,terminals:CoreTerminalController,demo:ToolsDemoArtifacts?
    private(set) var section=Section.artifacts
    private(set) var destinationID="",selectedArtifactID="",selectedAnnotationID:String?
    var defaultWorkingDirectory:((Conversation)->String?)?
    let preview=ToolsArtifactPreview(frame:.zero),artifactList=ToolsList(frame:.zero),annotationList=ToolsList(frame:.zero),browserList=ToolsList(frame:.zero)
    let artifactScroll=ToolsScrollView(),annotationScroll=ToolsScrollView(),browserScroll=ToolsScrollView(),domScroll=ToolsScrollView()
    let dom=ToolsTextView(frame:.zero)
    let destination=ToolsButton("Choose a chat"),status=ToolsLabel(),heading=ToolsLabel("Shared artifacts",size:14,weight:.semibold)
    let refreshButton=ToolsButton("Refresh"),openOriginal=ToolsButton("Open file"),attach=ToolsButton("Attach to draft"),send=ToolsButton("Send to chat")
    let quote=ToolsField("Quoted text (optional)"),comment=ToolsField("Comment"),save=ToolsButton("Save"),deleteNote=ToolsButton("Delete annotation"),clearRegion=ToolsButton("Clear region")
    let url=ToolsField("https://…"),openPage=ToolsButton("Open page"),closeTab=ToolsButton("Close owned tab"),readPage=ToolsButton("Read page"),shot=ToolsButton("Screenshot"),attachShot=ToolsButton("Attach screenshot"),external=ToolsButton("Open in browser")
    let windowSource=ToolsButton("Window"),screenSource=ToolsButton("Screen"),app=ToolsField("Application bundle ID or path"),capture=ToolsButton("Capture to draft"),recover=ToolsButton("Recover capture"),approve=ToolsButton("Approve in conversation")
    let captureHelp=ToolsLabel("Permissions are reviewed in the destination chat, through Core and normal macOS prompts.")
    let cwd=ToolsField("Backend working directory"),newTerminal=ToolsButton("New terminal"),nextTerminal=ToolsButton("Next session"),closeTerminal=ToolsButton("End session"),terminalHelp=ToolsLabel()
    private var tabButtons:[Section:ToolsButton]=[:],surfaces:[UUID:ToolsTerminalSurface]=[:]
    private var currentSurface:ToolsTerminalSurface?
    private var artifactObservation:UUID?,terminalObservation:UUID?,demoObservation:UUID?
    var currentConversation:Conversation? { controller.conversations.first { $0.id == destinationID } }
    var isDemo:Bool { demo != nil }
    var artifactValues:[CoreArtifact] { demo?.artifacts ?? controller.artifacts }
    var selectedArtifact:CoreArtifact? { artifactValues.first { $0.id == selectedArtifactID } }
    var noteValues:[JSONValue] { demo?.annotations[selectedArtifactID] ?? (isDemo ? []:controller.annotations) }
    init(artifacts:CoreArtifactsController,terminal:CoreTerminalController,demo:ToolsDemoArtifacts?=nil) {
        controller=artifacts; terminals=terminal; self.demo=demo; super.init(frame:CGRect(x:0,y:0,width:1000,height:740))
        for s in Section.allCases { let b=ToolsButton(s.rawValue); b.invoke={ [weak self] in self?.selectSection(s) }; tabButtons[s]=b; addSubview(b) }
        for (scroll,document) in [(artifactScroll,artifactList),(annotationScroll,annotationList),(browserScroll,browserList),(domScroll,dom)] { scroll.documentView=document; scroll.hasVerticalScroller=true; scroll.drawsBackground=false; addSubview(scroll) }
        let views:[NSView]=[preview,destination,status,heading,refreshButton,openOriginal,attach,send,quote,comment,save,deleteNote,clearRegion,url,openPage,closeTab,readPage,shot,attachShot,external,windowSource,screenSource,app,capture,recover,approve,captureHelp,cwd,newTerminal,nextTerminal,closeTerminal,terminalHelp]
        for v in views { addSubview(v) }
        status.textColor = .secondaryLabelColor; status.maximumNumberOfLines=2; captureHelp.maximumNumberOfLines=4; terminalHelp.maximumNumberOfLines=3
        destination.invoke={ [weak self] in self?.showDestinationMenu() }; refreshButton.invoke={ [weak self] in self?.reload() }
        artifactList.onSelect={ [weak self] in self?.selectArtifact($0) }; annotationList.onSelect={ [weak self] id in self?.selectedAnnotationID=id; self?.update() }
        openOriginal.invoke={ [weak self] in self?.controller.openOriginal() }
        attach.invoke={ [weak self] in self?.deliverSelected(send:false) }; send.invoke={ [weak self] in self?.deliverSelected(send:true) }
        quote.onEdit={ [weak self] in self?.controller.quote=$0 }; comment.onEdit={ [weak self] in self?.controller.comment=$0; self?.update() }
        save.invoke={ [weak self] in self?.saveAnnotation() }; comment.onReturn=save.invoke
        deleteNote.invoke={ [weak self] in self?.deleteAnnotation() }; clearRegion.invoke={ [weak self] in self?.preview.clearRegion() }
        preview.onRegion={ [weak self] value in guard let self,self.section == .artifacts else { return }; self.controller.region=value; self.clearRegion.isEnabled = value != nil }
        preview.onQuote={ [weak self] value in guard let self,self.section == .artifacts else { return }; self.controller.quote=value; self.quote.update(value) }
        preview.onPage={ [weak self] in guard let self,self.section == .artifacts else { return }; self.controller.page=$0 }; preview.onOpenURL={ [weak self] in self?.controller.onOpenURL?($0) }
        url.onEdit={ [weak self] in self?.controller.browserURL=$0 }; url.onReturn={ [weak self] in self?.controller.openBrowser() }
        openPage.invoke=url.onReturn; closeTab.invoke={ [weak self] in self?.controller.closeBrowserTab() }; readPage.invoke={ [weak self] in self?.controller.inspectBrowser() }
        shot.invoke={ [weak self] in self?.controller.screenshotBrowser() }; attachShot.invoke={ [weak self] in self?.controller.screenshotBrowser(attach:true) }; external.invoke={ [weak self] in self?.controller.openBrowserExternally() }
        browserList.onSelect={ [weak self] in self?.controller.selectBrowserTab($0); self?.update() }
        windowSource.invoke={ [weak self] in self?.controller.captureMode="window"; self?.update() }; screenSource.invoke={ [weak self] in self?.controller.captureMode="screen"; self?.update() }
        app.onEdit={ [weak self] in self?.controller.captureApp=$0 }; capture.invoke={ [weak self] in self?.controller.captureToDraft() }; recover.invoke={ [weak self] in self?.controller.recoverCaptures() }; approve.invoke={ [weak self] in self?.controller.showCaptureApprovals() }
        newTerminal.invoke={ [weak self] in self?.openTerminal() }; nextTerminal.invoke={ [weak self] in self?.cycleTerminal() }; closeTerminal.invoke={ [weak self] in guard let self,let s=self.terminals.active(for:self.destinationID) else { return }; Task { await s.close() } }
        artifactObservation=controller.observe { [weak self] in self?.update() }; terminalObservation=terminals.observe { [weak self] in self?.update() }; demoObservation=demo?.observe { [weak self] in self?.update() }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Tools"); selectSection(.artifacts)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { if let artifactObservation { controller.removeObserver(artifactObservation) }; if let terminalObservation { terminals.removeObserver(terminalObservation) }; if let demoObservation { demo?.removeObserver(demoObservation) } }
    func setDestination(_ id:String) { destinationID=id; controller.conversationID=id; if let c=currentConversation { cwd.update(c.cwd ?? defaultWorkingDirectory?(c) ?? "") }; update() }
    private func showDestinationMenu() {
        let menu=NSMenu(); menu.autoenablesItems=false
        for c in controller.conversations { let item=ToolsDestinationItem(c.title) { [weak self] in self?.setDestination(c.id) }; item.state=c.id == destinationID ? .on:.off; menu.addItem(item) }
        menu.popUp(positioning:nil,at:CGPoint(x:0,y:destination.bounds.height),in:destination)
    }
    func selectSection(_ next:Section) { section=next; update(); if !isDemo { reload() } }
    func reload() {
        guard !isDemo else { update(); return }
        switch section {
        case .artifacts: controller.refreshArtifacts()
        case .browser: controller.refreshTabs()
        case .capture: controller.recoverCaptures()
        case .terminal: Task { _ = await terminals.restore(); update() }
        }
    }
    func selectArtifact(_ id:String) {
        selectedArtifactID=id; selectedAnnotationID=nil
        if !isDemo { controller.select(id) } else { controller.quote=""; controller.comment=""; controller.region=nil }
        update()
    }
    private func deliverSelected(send:Bool) {
        if isDemo { controller.notice="Demo artifacts are in memory. Attach/Send is available when a Live destination is connected."; return }
        controller.attachSelected(send:send)
    }
    private func saveAnnotation() {
        let value=comment.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); guard !value.isEmpty,selectedArtifact?.previewUnavailable == false else { return }
        if let demo { demo.add(artifact:selectedArtifactID,text:value,quote:quote.stringValue,region:preview.region); comment.stringValue=""; controller.comment=""; update() }
        else { controller.comment=value; controller.quote=quote.stringValue; controller.addAnnotation() }
    }
    private func deleteAnnotation() {
        guard let id=selectedAnnotationID else { return }
        if let demo { demo.delete(artifact:selectedArtifactID,id:id) }
        else if let note=noteValues.first(where: { $0["id"]?.stringValue == id }) { controller.deleteAnnotation(note) }
    }
    private func openTerminal() {
        guard !isDemo,let conversation=currentConversation else { return }
        let path=cwd.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        Task { _ = await terminals.open(for:conversation,cwd:path.isEmpty ? nil:path); update() }
    }
    private func cycleTerminal() {
        let values=terminals.sessions(for:destinationID); guard !values.isEmpty else { return }
        let current=values.firstIndex { $0.id == terminals.active(for:destinationID)?.id } ?? 0
        terminals.selected[destinationID]=values[(current+1)%values.count].id; update()
    }
    func update() {
        if !isDemo { selectedArtifactID=controller.selectedID }
        preview.allowsRegionSelection=section == .artifacts
        for (s,b) in tabButtons { b.active=s == section }
        destination.title=currentConversation.map { "Destination: "+$0.title } ?? "Choose a chat"; destination.needsDisplay=true
        status.stringValue=isDemo ? "Demo · in-memory artifacts. No Core, browser, capture or shell is running.":controller.error ?? controller.notice ?? (controller.busy ? "Loading…":"")
        status.textColor=controller.error == nil || isDemo ? .secondaryLabelColor:.systemRed
        let groups:[[NSView]]=[
            [artifactScroll,annotationScroll,preview,heading,openOriginal,attach,send,quote,comment,save,deleteNote,clearRegion],
            [url,openPage,closeTab,readPage,shot,attachShot,external,browserScroll,domScroll],
            [windowSource,screenSource,app,capture,recover,approve,captureHelp],
            [cwd,newTerminal,nextTerminal,closeTerminal,terminalHelp]]
        for (index,views) in groups.enumerated() { for view in views { view.isHidden = Section.allCases[index] != section } }
        currentSurface?.isHidden=true
        switch section {
        case .artifacts:
            artifactList.rows=artifactValues.map { .init(id:$0.id,title:$0.name,detail:$0.previewUnavailable ? "Preview unavailable · "+($0.generationStatus ?? "received"):$0.mime+" · "+ByteCountFormatter.string(fromByteCount:Int64($0.bytes),countStyle:.file)) }
            artifactList.selectedID=selectedArtifactID
            let bytes=demo?.data[selectedArtifactID] ?? (isDemo ? nil:controller.selectedData)
            preview.configure(artifact:selectedArtifact,data:bytes)
            preview.restoreRegion(controller.region)
            preview.restorePDFPage(controller.page)
            heading.stringValue=selectedArtifact?.name ?? "Shared artifacts"
            annotationList.rows=noteValues.enumerated().map { .init(id:$0.element["id"]?.stringValue ?? String($0.offset),title:$0.element["text"]?.stringValue ?? "",detail:$0.element["quote"]?.stringValue ?? ($0.element["page"]?.intValue.map { "Page "+String($0) } ?? "Shared annotation")) }
            annotationList.selectedID=selectedAnnotationID
            quote.update(controller.quote); comment.update(controller.comment)
            quote.isEnabled=selectedArtifact?.previewUnavailable == false; comment.isEnabled=quote.isEnabled
            openOriginal.isEnabled = !isDemo && controller.localPathsAvailable && selectedArtifact?.previewUnavailable == false && selectedArtifact?.path.isEmpty == false
            attach.isEnabled = !isDemo && bytes != nil && currentConversation != nil && controller.onDeliver != nil && !controller.busy; send.isEnabled=attach.isEnabled
            save.isEnabled=selectedArtifact != nil && selectedArtifact?.previewUnavailable == false && !comment.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !controller.busy
            deleteNote.isEnabled=selectedAnnotationID != nil && !controller.busy; clearRegion.isEnabled=preview.region != nil
        case .browser:
            url.update(controller.browserURL); browserList.rows=(isDemo ? []:controller.tabs).compactMap { tab in guard let id=tab["tabId"]?.stringValue else { return nil }; return .init(id:id,title:tab["title"]?.stringValue ?? "Untitled",detail:tab["url"]?.stringValue ?? "") }; browserList.selectedID=controller.selectedTabID
            dom.string=isDemo ? "Browser automation requires Live Core. No browser runtime was started.":controller.browserSnapshot
            if !isDemo,let bytes=controller.browserImage {
                preview.isHidden=false
                preview.configure(artifact:CoreArtifact(raw:["id":.string("browser:"+controller.selectedTabID),"mimeType":"image/png","name":"Browser screenshot"]),data:bytes)
            }
            openPage.isEnabled = !isDemo && !controller.busy
            for b in [closeTab,readPage,shot,external] { b.isEnabled = !isDemo && !controller.selectedTabID.isEmpty && !controller.busy }
            attachShot.isEnabled=shot.isEnabled && currentConversation != nil && controller.onDeliver != nil
        case .capture:
            windowSource.active=controller.captureMode == "window"; screenSource.active=controller.captureMode == "screen"; app.update(controller.captureApp)
            for b in [windowSource,screenSource] { b.isEnabled = !isDemo && !controller.busy }
            app.isEnabled = !isDemo && controller.captureMode == "window"
            capture.isEnabled = !isDemo && controller.onDeliver != nil && !controller.busy && !controller.hasPendingCapture && currentConversation?.backendThreadID != nil
            recover.isEnabled = !isDemo && controller.hasPendingCapture; approve.isEnabled=recover.isEnabled
            captureHelp.stringValue=isDemo ? "Appshots require Live Core. No capture, application permission or screen recording request was made.":controller.captureSummary+"\nPermissions are reviewed in the original destination chat, through Core and normal macOS prompts."
        case .terminal:
            newTerminal.isEnabled = !isDemo && terminals.isConfigured && currentConversation != nil
            let active=terminals.active(for:destinationID); closeTerminal.isEnabled=active?.running == true; nextTerminal.isEnabled=terminals.sessions(for:destinationID).count>1
            terminalHelp.stringValue=isDemo ? "Terminal requires Live Core. No shell has been started.":terminals.restorationError ?? active?.error ?? (ToolsTerminalSurface.fullVTCompatibility ? "Core-owned PTY · SwiftTerm":"Core-owned PTY · basic terminal compatibility")
            if let active {
                let surface=surfaces[active.id] ?? ToolsTerminalSurface(frame:.zero)
                if surface.superview == nil { addSubview(surface); surfaces[active.id]=surface }; surface.bind(active); surface.isHidden=false; currentSurface=surface
            }
        }
        needsLayout=true; needsDisplay=true
    }
    override func layout() {
        super.layout(); let w=bounds.width,h=bounds.height,left:CGFloat=244,right:CGFloat=272,rw=max(1,w-right-16)
        for (index,s) in Section.allCases.enumerated() { place(tabButtons[s]!,CGRect(x:16+CGFloat(index)*100,y:16,width:94,height:28)) }
        place(destination,CGRect(x:max(430,w-300),y:16,width:min(284,w-446),height:28)); place(status,CGRect(x:16,y:51,width:w-130,height:34)); place(refreshButton,CGRect(x:w-106,y:52,width:90,height:26))
        place(artifactScroll,CGRect(x:16,y:96,width:left,height:max(1,h-112))); artifactList.frame.size.width=artifactScroll.contentSize.width
        place(heading,CGRect(x:right,y:96,width:rw-106,height:24)); place(openOriginal,CGRect(x:w-112,y:94,width:96,height:26))
        place(preview,CGRect(x:right,y:130,width:rw,height:max(120,h-378)))
        let bottom=max(260,h-238)
        place(quote,CGRect(x:right,y:bottom,width:rw,height:27)); place(comment,CGRect(x:right,y:bottom+35,width:rw-80,height:27)); place(save,CGRect(x:w-88,y:bottom+35,width:72,height:27))
        place(annotationScroll,CGRect(x:right,y:bottom+72,width:rw,height:78)); annotationList.frame.size.width=annotationScroll.contentSize.width
        place(deleteNote,CGRect(x:right,y:bottom+156,width:140,height:24)); place(clearRegion,CGRect(x:right+148,y:bottom+156,width:100,height:24))
        place(attach,CGRect(x:w-282,y:h-42,width:132,height:28)); place(send,CGRect(x:w-142,y:h-42,width:126,height:28))
        place(url,CGRect(x:16,y:96,width:max(80,w-254),height:28)); place(openPage,CGRect(x:w-226,y:96,width:100,height:28)); place(closeTab,CGRect(x:w-118,y:96,width:102,height:28))
        place(browserScroll,CGRect(x:16,y:138,width:left,height:h-154)); browserList.frame.size.width=browserScroll.contentSize.width
        let browserButtonWidth=(rw-24)/4
        for (index,b) in [readPage,shot,attachShot,external].enumerated() { place(b,CGRect(x:right+CGFloat(index)*(browserButtonWidth+8),y:138,width:browserButtonWidth,height:28)) }
        if section == .browser,!preview.isHidden {
            let imageHeight=min(CGFloat(280),max(120,(h-210)/2)); place(preview,CGRect(x:right,y:180,width:rw,height:imageHeight)); place(domScroll,CGRect(x:right,y:190+imageHeight,width:rw,height:max(1,h-206-imageHeight)))
        } else { place(domScroll,CGRect(x:right,y:180,width:rw,height:h-196)) }
        dom.fit(in:domScroll,scale:pixelScale)
        place(windowSource,CGRect(x:24,y:105,width:100,height:28)); place(screenSource,CGRect(x:132,y:105,width:100,height:28)); place(app,CGRect(x:24,y:147,width:w-48,height:28))
        place(capture,CGRect(x:24,y:191,width:150,height:30)); place(recover,CGRect(x:184,y:191,width:140,height:30)); place(approve,CGRect(x:334,y:191,width:190,height:30)); place(captureHelp,CGRect(x:24,y:239,width:w-48,height:140))
        place(cwd,CGRect(x:16,y:96,width:max(100,w-430),height:28)); place(newTerminal,CGRect(x:w-398,y:96,width:120,height:28)); place(nextTerminal,CGRect(x:w-270,y:96,width:120,height:28)); place(closeTerminal,CGRect(x:w-142,y:96,width:126,height:28))
        place(terminalHelp,CGRect(x:16,y:132,width:w-32,height:48)); if let currentSurface { place(currentSurface,CGRect(x:16,y:188,width:w-32,height:max(1,h-204))) }
    }
    override func draw(_ dirtyRect:NSRect) { NSColor(srgbRed:0.105,green:0.112,blue:0.108,alpha:1).setFill(); bounds.fill() }
    override func keyDown(with event:NSEvent) {
        if selectTab(with:event) { return }
        super.keyDown(with:event)
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool { selectTab(with:event) || super.performKeyEquivalent(with:event) }
    private func selectTab(with event:NSEvent)->Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,let digit=Int(event.charactersIgnoringModifiers ?? ""),(1...4).contains(digit) else { return false }
        selectSection(Section.allCases[digit-1]); return true
    }
}
private final class ToolsDestinationItem:NSMenuItem {
    let invoke:()->Void
    init(_ title:String,_ action:@escaping ()->Void) { invoke=action; super.init(title:title,action:#selector(run),keyEquivalent:""); target=self }
    required init(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { invoke() }
}
