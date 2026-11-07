#if NORMIE_SELFTEST
import AppKit

private final class NormieComponentTransport:CoreTransport,@unchecked Sendable {
    let reply:@Sendable(String,String,JSONValue?)async throws->JSONValue
    init(_ reply:@escaping @Sendable(String,String,JSONValue?)async throws->JSONValue){self.reply=reply}
    func request(_ method:String,path:String,body:JSONValue?,timeout:TimeInterval?)async throws->JSONValue{try await reply(method,path,body)}
    func events(since:Int,threadID:String?)->AsyncThrowingStream<CoreEvent,Error>{AsyncThrowingStream{$0.finish()}}
}
@MainActor private final class NormieTerminalFixture {
    var requests:[(String,JSONValue?)]=[],failOutput=false
    var transport:any CoreTransport{NormieComponentTransport{[self] _,path,body in try await reply(path,body)}}
    func reply(_ path:String,_ body:JSONValue?)throws->JSONValue{
        requests.append((path,body))
        if path.hasPrefix("/terminal/output") {if failOutput{throw CoreWire.failure("Recorded read failure")};return ["chunks":[],"running":true,"lastSequence":0]}
        if path == "/terminal/close"{return [:]}
        if path == "/terminal/sessions"{return ["sessions":[]]}
        throw CoreWire.failure("Unexpected fixture request: "+path)
    }
}
@MainActor enum NormieComponentFixVerification {
    static func run(directory:URL,check:(Bool,String)->Void) async throws {
        func tree(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(tree)}
        let builder=NormieMenuBuilder(context:{.init()},perform:{_,_ in})
        let menu=builder.makeMainMenu()
        func items(_ m:NSMenu)->[NSMenuItem]{m.items.flatMap{[$0]+($0.submenu.map(items) ?? [])}}
        let fixed=items(menu).filter{["focused","split","nextPane","previousPane","terminal","customize"].contains($0.representedObject as? String ?? "")}
        check(fixed.count == 6 && fixed.allSatisfy{$0.identifier?.rawValue.hasPrefix("shortcut.") == false},"C01 actual layout/session commands are fixed menu items")
        check(items(menu).first{$0.representedObject as? String == "rename"}?.identifier?.rawValue == "shortcut.rename","C01 actual editable commands retain shortcut identifiers")
        let split=fixed.first{$0.representedObject as? String == "split"}!
        builder.applyShortcuts(["split":"⌘K","rename":"⌥⌘R"])
        check(split.keyEquivalent == "\\" && split.keyEquivalentModifierMask == [.command,.option],"C01 applyShortcuts cannot overwrite a fixed layout command")

        let chats=(0..<70).map{index in let c=Conversation(id:"scroll-\(index)",title:"Chat \(index)");c.updated=Date(timeIntervalSince1970:Double(70-index));return c}
        let store=ConversationStore(conversations:chats),model=NormieSidebarModel(store:store,current:"scroll-50")
        model.search("Chat")
        let sidebar=NormieSidebarController(model:model);sidebar.loadViewIfNeeded();sidebar.view.frame=CGRect(x:0,y:0,width:260,height:400);sidebar.viewDidLayout();sidebar.reload()
        sidebar.scrollView.contentView.scroll(to:.zero);sidebar.scrollView.reflectScrolledClipView(sidebar.scrollView.contentView)
        for _ in 0..<5{model.refresh()}
        check(sidebar.scrollView.contentView.bounds.minY == 0,"C02 streaming refresh leaves manually scrolled sidebar at the top")
        model.select("scroll-60")
        check(sidebar.scrollView.contentView.bounds.minY>0,"C02 changing current still reveals the selected conversation")
        sidebar.scrollView.contentView.scroll(to:CGPoint(x:0,y:120));let offset=sidebar.scrollView.contentView.bounds.origin
        model.refresh();check(sidebar.scrollView.contentView.bounds.origin == offset,"C02 repeated unchanged focus preserves a nonzero reading offset")
        for chat in chats.prefix(60){chat.archived=true};model.refresh()
        check(sidebar.scrollView.contentView.bounds.minY<=max(0,sidebar.table.frame.height-sidebar.scrollView.contentSize.height)+1,"C02 removing other rows clamps retained offset \(sidebar.scrollView.contentView.bounds.minY) to remaining list \(sidebar.table.frame.height)/\(sidebar.scrollView.contentSize.height)")

        let saved=NativeAppearance.current;defer{NativeAppearance.apply(saved)}
        NativeAppearance.apply(.init());check(NormieCodeStyle.nativeCurrent.fillAlpha == 0.10,"C18 Canopy diff retains 10% fill")
        let c=Conversation(id:"diff",title:"Diff");c.changes=[.init(path:"file.swift",added:1,removed:1,lines:[.init(kind:.added,text:"new"),.init(kind:.removed,text:"old")])]
        let diffStore=ConversationStore(conversations:[c]),inspector=NormieInspectorController(store:diffStore,actions:.init());inspector.loadViewIfNeeded();inspector.view.frame=CGRect(x:0,y:0,width:320,height:420);inspector.viewDidLayout();inspector.show(c);inspector.showChanges();inspector.toggleFile("file.swift")
        var look=NativeAppearance.current;look.code.added = .systemGreen;look.code.removed = .systemPurple;look.code.text = .white;NativeAppearance.apply(look)
        check(inspector.codeStyle.fillAlpha == 0.16,"C18 explicit code palette changes diff fill to 16%")
        let diff=tree(inspector.view).compactMap{$0 as? NormieDiffTextView}.first!
        let alphas=(0..<diff.attributedString().length).compactMap{(diff.attributedString().attribute(.backgroundColor,at:$0,effectiveRange:nil) as? NSColor)?.alphaComponent}
        check(!alphas.isEmpty && alphas.allSatisfy{abs($0-0.16)<0.001},"C18 existing rendered diff recolors actual text background to 16%")

        let live=Conversation(id:"terminal",title:"Live");live.isLiveConversation=true;live.backendThreadID="recorded-thread"
        let liveStore=ConversationStore(conversations:[live]);liveStore.usesLiveCore=true
        let fixture=NormieTerminalFixture(),controller=CoreTerminalController();controller.configure(client:fixture.transport,store:liveStore)
        controller.restoreDescriptors([["id":"pty-one","threadId":"recorded-thread","cwd":"/fixture/one","running":true],["id":"pty-two","threadId":"recorded-thread","cwd":"/fixture/two","running":true]],store:liveStore)
        let pane=NormieTerminalPane(frame:CGRect(x:0,y:0,width:720,height:220));pane.presentationActive=true;pane.setController(controller);pane.configure(live,store:liveStore);pane.layoutSubtreeIfNeeded()
        let sessions=controller.sessions(for:live.id)
        check(fixture.requests.isEmpty,"C07 configuring pane does not open or probe a backend")
        check(!pane.sessionPicker.isHidden && pane.sessionPicker.menu?.items.filter{!$0.isHidden}.count == 2,"C07 restored sessions are offered by the native selector")
        check(pane.selectSession(sessions[1].id) && controller.active(for:live.id) === sessions[1],"C07 selector changes the active restored session")
        check(pane.selectSession(sessions[0].id) && controller.active(for:live.id) === sessions[0],"C07 switching back retains the first session")
        check(!pane.selectSession(UUID()),"C07 selector rejects a foreign session")
        fixture.failOutput=true;await sessions[0].catchUp();pane.layoutSubtreeIfNeeded()
        check(!pane.reconnectButton.isHidden && sessions[0].error != nil,"C07 recoverable output error shows Reconnect")
        fixture.failOutput=false;pane.reconnectActiveSession()
        for _ in 0..<20_000{if sessions[0].error == nil{break};await Task.yield()}
        check(sessions[0].error == nil && pane.reconnectButton.isHidden,"C07 Reconnect catches up the same backend session")
        pane.endActiveSession()
        for _ in 0..<20_000{if !sessions[0].running{break};await Task.yield()}
        check(!sessions[0].running && fixture.requests.last?.0 == "/terminal/close" && fixture.requests.last?.1?["id"] == "pty-one","C07 End closes only the active PTY")
        check(sessions[1].running,"C07 ending one PTY does not close its sibling")
        var hidden=0;pane.onClose={hidden+=1};let requests=fixture.requests.count;pane.closeButton.performClick(nil)
        check(hidden == 1 && fixture.requests.count == requests,"C07 Hide Terminal keeps sessions alive")
        pane.isHidden=true;check(!pane.selectSession(sessions[1].id),"C07 hidden pane rejects stale session actions");pane.isHidden=false
        for scale:CGFloat in [1,2]{try NormieVerification.write(NativeViewBitmap.capture(pane,scale:scale),to:directory.appendingPathComponent("component-live-terminal@\(Int(scale))x.png"))}
        let controls=tree(pane).filter{$0 is NSControl};check(controls.allSatisfy{($0 as? NSButton)?.isBordered != true && ($0 as? NSTextField)?.isBezeled != true},"C07 session controls have no system bezel")
        check(pane.sessionPicker.accessibilityRole() == .popUpButton && pane.endButton.accessibilityLabel() == "End this terminal session","C07 selector and End expose native AX semantics")
        pane.dispose()
        #if COMPONENT_STORE_SELFTEST
        let a=Conversation(id:"delete-undo",title:"Permanently deleted"),b=Conversation(id:"survivor",title:"Survivor")
        let deletionStore=ConversationStore(conversations:[a,b]),workbench=NormieWorkbench(store:deletionStore,sessions:NativeComposerSessions(),current:a.id)
        workbench.sidebarModel.archive(a.id)
        check(workbench.sidebarModel.canUndoArchive && workbench.archiveUndoManager.canUndo,"delete integration starts with a real archive Undo")
        try deletionStore.remove(ids:[a.id])
        check(deletionStore.conversation(a.id) == nil && !workbench.sidebarModel.canUndoArchive && !workbench.archiveUndoManager.canUndo,"delete invalidates Sidebar and native Undo tokens through store observers")
        check(!workbench.undoArchive() && deletionStore.conversation(a.id) == nil,"deleted conversation cannot be revived by old Undo")
        let replacement=Conversation(id:a.id,title:"Replacement");replacement.archived=true;deletionStore.add(replacement)
        check(!workbench.undoArchive() && replacement.archived,"old Undo cannot unarchive a replacement sharing the ID")
        try deletionStore.remove(ids:[b.id])
        check(workbench.selectedConversation == nil && workbench.sidebarModel.current == nil,"deleting the last visible active chat retires Normie selection into New Chat")
        workbench.dispose()
        #endif
    }
}
#endif
