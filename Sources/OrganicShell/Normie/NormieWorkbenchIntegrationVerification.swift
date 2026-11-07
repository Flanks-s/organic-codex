#if NORMIE_SELFTEST
import AppKit

@MainActor enum NormieM8Verification {
    static func run(directory:URL,check:(Bool,String)->Void)throws{
        let options=NativeDisplayOptions.shared
        options.setVerificationState(.init(increaseContrast:false,reduceTransparency:false));defer{options.setVerificationState(nil)}
        let banner=NormieOfflineBanner(frame:CGRect(x:0,y:0,width:620,height:62))
        banner.stringValue="This Mac is offline.\nThis is the last loaded copy. You can keep writing; sending is off until it reconnects."
        check(banner.accessibilityLabel()?.contains("last loaded copy")==true,"M8 offline banner exports a combined semantic label")
        for scale in [CGFloat(1),2]{for contrast in [false,true]{options.setVerificationState(.init(increaseContrast:contrast,reduceTransparency:false));NormieVerification.layout(banner,scale:scale);try NormieVerification.write(NativeViewBitmap.capture(banner,scale:scale),to:directory.appendingPathComponent("offline-banner-\(contrast ? "contrast":"normal")@\(Int(scale))x.png"));check(banner.appearance?.name == NativeDisplayOptions.appearance?.name,"M8 offline banner responds live to contrast")}}
        options.setVerificationState(.init(increaseContrast:false,reduceTransparency:false))
        let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        let wb=NormieWorkbench(store:store,sessions:NativeComposerSessions(),current:"A")
        let canvas=NormieView(frame:CGRect(x:0,y:0,width:1280,height:820));canvas.fill=NormieDrawing.background
        for controller in [wb.sidebar as NSViewController,wb.detail,wb.inspector]{canvas.addSubview(controller.view)}
        wb.sidebar.view.frame=CGRect(x:0,y:0,width:260,height:820)
        wb.detail.view.frame=CGRect(x:260,y:0,width:700,height:820)
        wb.inspector.view.frame=CGRect(x:960,y:0,width:320,height:820)
        wb.refresh()
        var changes:[Bool]=[];wb.onTerminalShownChange={changes.append($0)}
        let composer=wb.detail.composer!,editor=composer.textView
        _ = composer.setText("Draft before terminal");editor.setSelectedRange(NSRange(location:6,length:6));let undo=editor.undoManager
        check(!wb.isTerminalShown && wb.terminalMenuTitle=="Show Terminal","M8 terminal starts hidden")
        wb.setTerminalShown(true,animated:false);NormieVerification.layout(canvas,scale:2)
        let pane=wb.detail.terminalPane,transcript=wb.detail.transcripts["A"]!
        check(wb.isTerminalShown && changes==[true],"M8 terminal target and callback open once")
        let paneInDetail=pane.convert(pane.bounds,to:wb.detail.view)
        check(paneInDetail.height==220 && paneInDetail.maxY==820,"M8 terminal is 220pt at the detail bottom")
        check(transcript.frame.height>0 && transcript.frame.maxY<=composer.frame.minY,"M8 transcript remains above composer")
        check(wb.detail.composerDockRect.maxY<=paneInDetail.minY,"M8 glass composer stays above terminal")
        check(wb.inspector.view.frame.height==820,"M8 system inspector remains full height beside the terminal")
        check(pane.terminal != nil && pane.terminal?.superview === pane,"M8 mock uses the existing Tools renderer")
        check(!pane.add.isEnabled && pane.closeButton.accessibilityRole() == .button,"M8 prototype plus is disabled and Close is an AX button")
        check(pane.inputField.accessibilityRole() == .textField && pane.accessibilityRole() == .group,"M8 terminal input and panel AX roles")
        let originalHistory=pane.mock!.history
        check(originalHistory.count==min(8,store.conversation("A")!.items.filter{$0.rowKind == .tool(.command)}.count),"M8 mock starts with conversation command history")
        check(pane.runMock("echo hello") && pane.mock!.history.last?.command=="echo hello","M8 input is retained as a prototype command")
        check(pane.mock!.history.last!.output.contains("prototype runs nothing"),"M8 commands explicitly report no execution")
        let model=pane.mock!,renderer=pane.terminal!
        wb.setTerminalShown(false,animated:false);NormieVerification.layout(canvas,scale:2)
        check(pane.isHidden && !pane.presentationActive && !pane.runMock("hidden"),"M8 hidden terminal rejects input")
        check(composer.textView === editor && composer.text=="Draft before terminal" && editor.undoManager === undo && editor.selectedRange()==NSRange(location:6,length:6),"M8 toggling preserves draft editor, selection and Undo")
        wb.setTerminalShown(true,animated:false);NormieVerification.layout(canvas,scale:2)
        check(pane.mock === model && pane.terminal === renderer,"M8 reopen retains mock history and renderer")
        wb.setTerminalShown(true,animated:false);check(changes==[true,false,true],"M8 redundant show does not notify again")
        _ = wb.select("B");NormieVerification.layout(canvas,scale:2)
        check(pane.mock !== model,"M8 each conversation has separate terminal history")
        _ = wb.select("A");NormieVerification.layout(canvas,scale:2)
        check(pane.mock === model && pane.mock!.history.last?.command=="echo hello","M8 conversation round trip restores history")
        check(pane.runMock("clear") && pane.mock!.history.isEmpty,"M8 clear hides original and typed history")
        check(!pane.runMock(" \n "),"M8 whitespace does not append a command")
        check(!NormieMockTerminal.visible("echo\u{1b}[31m\u{7}").contains("\u{1b}"),"M8 prototype input cannot inject ANSI escapes")
        for (available,expected) in [(CGFloat(820),CGFloat(220)),(450,210),(240,0),(100,0)]{check(NormieTerminalMotion.height(available:available)==expected,"M8 terminal preserves 240pt for transcript and composer")}
        let opening=NormieTerminalMotion(start:0,target:1,velocity:0)
        check(NormieTerminalMotion.response==0.32 && NormieTerminalMotion.damping==0.88,"M8 product terminal spring constants")
        check(opening.value(at:0)==0 && abs(opening.value(at:0.85)-1)<0.002,"M8 terminal spring reaches its target")
        let time=0.12,position=opening.value(at:0.12),speed=opening.speed(at:0.12)
        let reverse=NormieTerminalMotion(start:position,target:0,velocity:speed)
        check(abs(reverse.value(at:0)-opening.value(at:time))<1e-8 && abs(reverse.speed(at:0)-speed)<1e-6,"M8 reversing spring preserves position and velocity")
        let count=store.conversations.count
        check(wb.newChat(projectID:"fn"),"M8 terminal can coexist with a new draft")
        NormieVerification.layout(canvas,scale:2)
        check(pane.isHidden && !pane.presentationActive && store.conversations.count==count,"M8 new chat has no terminal session or eager conversation")
        let textLabels=descendants(wb.detail.newChatView).compactMap{($0 as? NSTextField)?.stringValue}
        check(textLabels.contains(where:{$0.contains("Field Notes")}) && !wb.detail.newChatView.isHidden,"M8 empty state names the selected context")
        _ = wb.select("A");NormieVerification.layout(canvas,scale:2)
        check(!pane.isHidden && pane.mock === model,"M8 selecting an existing chat restores shown terminal")
        let c=store.conversation("A")!
        c.isLiveConversation=true;pane.refresh()
        check(pane.mock == nil && pane.terminal == nil && !pane.runMock("live must not mock"),"M8 unconnected Live route never falls back to prototype execution")
        let unconfigured=CoreTerminalController();wb.setTerminalController(unconfigured);pane.openLiveTerminal()
        check(unconfigured.sessions(for:c.id).isEmpty,"M8 unconfigured controller cannot open a backend session")
        c.isLiveConversation=false;wb.setTerminalController(nil);pane.refresh()
        c.approvals=[Approval(id:"current-approval",title:"Current approval",command:"git status",note:"",acceptLabel:"Allow",toolItemID:"")];store.changed(c);wb.refresh();NormieVerification.layout(canvas,scale:2)
        let activeCards=descendants(wb.detail.view).compactMap{$0 as? NativeTranscriptCard}.filter{!$0.isHiddenOrHasHiddenAncestor}
        check(activeCards.count>=2,"M8 current and background approval cards share the composer rail")
        check(!descendants(transcript).contains{$0 is NativeTranscriptCard},"M8 Normie transcript does not duplicate rail decisions")
        let firstCard=activeCards.min{a,b in a.convert(a.bounds,to:wb.detail.view).minY<b.convert(b.bounds,to:wb.detail.view).minY}!
        check(firstCard.accessibilityLabel()?.contains("Current approval")==true,"M8 current conversation decisions precede background decisions")
        var context=wb.menuContext
        let menus=NormieMenuBuilder(context:{context},perform:{_,_ in})
        let menu=menus.makeMainMenu(demo:true)
        let terminalItem=flatten(menu).first{$0.representedObject as? String == NormieCommand.terminal.rawValue}!
        _ = menus.validateMenuItem(terminalItem)
        check(terminalItem.title=="Hide Terminal" && terminalItem.keyEquivalent=="j","M8 terminal menu title and shortcut reflect target state")
        context.normie=false;check(!menus.validateMenuItem(terminalItem),"M8 terminal menu is unavailable in Organic")
        wb.setTerminalShown(false,animated:false);wb.isNormie=false;wb.setTerminalShown(true,animated:false)
        check(!wb.isTerminalShown,"M8 Workbench refuses to open terminal outside Normie")
        wb.isNormie=true;wb.setTerminalShown(true,animated:false)
        _ = pane.runMock("pwd")
        for scale in [CGFloat(1),2]{
            for (name,state) in [("normal",NativeDisplayOptions.State(increaseContrast:false,reduceTransparency:false)),("contrast",.init(increaseContrast:true,reduceTransparency:false)),("opaque",.init(increaseContrast:false,reduceTransparency:true))]{
                options.setVerificationState(state);NormieVerification.layout(canvas,scale:scale)
                check((wb.detail.view as! NormieView).canopy,"M8 detail owns the product canopy")
                check(NormieVerification.plainControls(canvas,skipNative:false).isEmpty,"M8 terminal and complete reused tree contain no plain controls")
                check(NormieVerification.controlsWithoutDrawOverride(canvas,skipNative:false).isEmpty,"M8 all terminal controls override draw without a bezel")
                let image=NativeViewBitmap.capture(canvas,scale:scale)
                check(image.width==1280*Int(scale) && image.height==820*Int(scale),"M8 terminal screenshot scale")
                try NormieVerification.write(image,to:directory.appendingPathComponent("terminal-inspector-\(name)@\(Int(scale))x.png"))
            }
        }
        let wash=NormieView(frame:CGRect(x:0,y:0,width:300,height:200));wash.fill = .windowBackgroundColor;wash.canopy=true
        options.setVerificationState(.init(increaseContrast:false,reduceTransparency:false));let normal=NativeViewBitmap.capture(wash,scale:1)
        options.setVerificationState(.init(increaseContrast:false,reduceTransparency:true));let opaque=NativeViewBitmap.capture(wash,scale:1)
        wash.canopy=false;let plain=NativeViewBitmap.capture(wash,scale:1)
        check(opaque.dataProvider!.data! as Data == plain.dataProvider!.data! as Data,"M8 reduced transparency removes canopy pixels")
        check(normal.dataProvider!.data! as Data != plain.dataProvider!.data! as Data,"M8 normal detail retains the product canopy")
        wb.dispose()
        check(wb.detail.transcripts.isEmpty && pane.terminal == nil && pane.mock == nil && !pane.presentationActive,"M8 dispose detaches observers, transcript and terminal content")
        check(renderer.onInput == nil,"M8 disposed renderer cannot forward retained input callbacks")
        check(NSApp.windows.allSatisfy{!$0.isVisible},"M8 all checks remain offscreen")
    }
    static func descendants(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(descendants)}
    static func flatten(_ m:NSMenu)->[NSMenuItem]{m.items.flatMap{[$0]+($0.submenu.map(flatten) ?? [])}}
}
#endif
