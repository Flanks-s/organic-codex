#if M1_SELFTEST
import AppKit

@MainActor enum NativeAXLookVerification {
    static func run(output:URL,check:(Bool,String)->Void)throws{
        let initial=NativeAppearance.current;defer{NativeAppearance.apply(initial)}
        func descendants(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(descendants)}
        func tree(_ p:NativeInteractionProxy,depth:Int=0)->[NativeInteractionProxy]{guard depth<12 else{return []};return [p]+(p.accessibilityChildren() ?? []).compactMap{$0 as? NativeInteractionProxy}.flatMap{tree($0,depth:depth+1)}}
        let c=Conversation(id:"ax-look",title:"AX and appearance")
        c.items=[.init(id:"user",turnID:"t",kind:.user,text:"Keep a real selection."),.init(id:"command",turnID:"t",kind:.tool(.command),text:"swift build\nActual tool output",status:"running"),.init(id:"answer",turnID:"t",kind:.assistant,text:"Actual body\n```swift\nlet answer = 42\n```")]
        c.approvals=[Approval(id:"approval",title:"Nested approval",command:"swift build",note:"Exact request",acceptLabel:"Allow",toolItemID:"command")]
        let transcript=NativeTranscript(conversation:c)
        transcript.frame=CGRect(x:0,y:0,width:720,height:900);transcript.verificationAXScreenOrigin=CGPoint(x:100,y:200);transcript.refresh(preservingOffset:false);transcript.scrollOffset = .zero
        let table=transcript.scrollView.documentView as! NativeTranscriptTable
        let user=descendants(transcript).compactMap{$0 as? NativeTranscriptRow}.first{$0.item.id == "user"}!
        user.body.setSelectedRange(NSRange(location:2,length:5))
        // Relations queried before children must not give the same logical row a different proxy or parent.
        let directTable=transcript.proxy(table,parent:transcript,adoptParent:false)!
        let selected=directTable.accessibilitySelectedRows()!.first as! NativeInteractionProxy
        let directText=transcript.proxy(user.body,parent:transcript,adoptParent:false)!
        let roots=(transcript.accessibilityChildren() ?? []).compactMap{$0 as? NativeInteractionProxy}
        let publicTree=roots.flatMap{tree($0)}
        check(roots.contains{$0.accessibilityRole() == .scrollArea},"f196 cold public root exports a scroll area")
        let publicTable=publicTree.first{$0.accessibilityRole() == .table}
        check(publicTable === directTable,"b076 table retains canonical identity across relation and child queries")
        let publicRows=(publicTable?.accessibilityRows() ?? []).compactMap{$0 as? NativeInteractionProxy}
        check(directTable.accessibilityAttributeNames().contains(.rows) && selected.accessibilityAttributeNames().contains(.rowIndexRange),"f196 public legacy inventories advertise table and row relations")
        check(publicRows.count==4 && publicRows.allSatisfy{$0.accessibilityRole() == .row},"f196 table exports message, nested tool and approval rows")
        check(publicRows.contains{$0 === selected} && selected.accessibilityParent() as? NativeInteractionProxy === directTable,"b076 selected row queried first keeps its canonical table parent")
        check(publicTree.contains{$0 === directText},"b076 text queried first is the same proxy in the public tree")
        check(publicTree.contains{($0.accessibilityValue() as? String)?.contains("Actual body")==true},"b081 public tree contains actual body text")
        check(publicTree.contains{($0.accessibilityValue() as? String)?.contains("swift build")==true},"b081 public tree contains nested command text")
        check(publicTree.contains{$0.accessibilityLabel()?.contains("Nested approval")==true},"b081 public tree contains a nested approval")
        check(directText.accessibilitySelectedText()=="ep a " && directText.accessibilitySelectedTextRange()==NSRange(location:2,length:5),"f196 readable value and selected range")
        directText.setAccessibilitySelectedTextRanges([NSValue(range:NSRange(location:1,length:4))])
        check(user.body.selectedRange()==NSRange(location:1,length:4),"f196 modern selection writes reach native text")
        directText.accessibilitySetValue(NSValue(range:NSRange(location:3,length:2)),forAttribute:.selectedTextRange)
        check(user.body.selectedRange()==NSRange(location:3,length:2),"f196 legacy selection writes reach native text")
        let source=user.body.string
        for selector in ["setAccessibilityValue:","setAccessibilitySelectedText:"]{check(!directText.responds(to:NSSelectorFromString(selector)) && !directText.isAccessibilitySelectorAllowed(NSSelectorFromString(selector)),"b081 readonly source denies content setter "+selector)}
        directText.setAccessibilityValue("wrong");directText.setAccessibilitySelectedText("wrong");directText.accessibilitySetValue("wrong",forAttribute:.value)
        check(user.body.string==source,"b081 rejected writes preserve actual content")
        for node in [directText,directTable,selected]{
            for (name,action) in [("Pick",NSAccessibility.Action.pick),("Confirm",.confirm),("Increment",.increment),("Delete",.delete)]{check(!node.responds(to:NSSelectorFromString("accessibilityPerform"+name)) && !node.accessibilityActionNames().contains(action),"b081 semantic tree does not invent "+name)}
        }
        let root=NativeInteractionSurface(frame:CGRect(x:0,y:0,width:400,height:200));root.verificationAXScreenOrigin = .zero
        let title=NativeButton(title:"Cold title",target:nil,action:nil);title.frame=CGRect(x:10,y:10,width:160,height:30);title.setAccessibilityLabel("Cold title");title.setAccessibilityHelp("Rename conversation");root.addSubview(title)
        let cold=(root.accessibilityChildren() ?? []).compactMap{$0 as? NativeInteractionProxy}.first!
        check(cold.accessibilityLabel()=="Cold title" && cold.accessibilityHelp()=="Rename conversation","b086 cold bridge exports distinct title and help before a warm update")
        let custom=NativeAXLookActions();let customProxy=root.proxy(custom,parent:root)!
        let actions=customProxy.accessibilityCustomActions()!
        check(actions.map(\.name)==["Rename","Rename"],"b087 duplicate names retain two ordered actions")
        custom.generation=2;check(actions[0].handler?()==true && actions[1].handler?()==true && custom.calls==[20,21],"b087 rebuilt source getters dispatch current ordered slots")
        custom.names=["Changed"];check(actions[0].handler?()==false,"b087 changed inventory invalidates an old action")
        custom.names=["Rename","Rename"];let retiring=customProxy.accessibilityCustomActions()![0];root.presentationActive=false
        check(retiring.handler?()==false,"b087 retired source refuses an old action")

        let composer=NativeComposer(conversation:c);composer.frame=CGRect(x:0,y:0,width:720,height:112);composer.layoutMode = .growing;_ = composer.setText("Keep draft and Undo");composer.textView.setSelectedRange(NSRange(location:2,length:4))
        let editor=composer.textView,undo=editor.undoManager,selection=user.body.selectedRange()
        let hidden=NativeTranscript(conversation:c);hidden.frame=transcript.frame;hidden.refresh();hidden.isHidden=true
        let hiddenCount=hidden.rowConfigurationCount(itemID:"user")
        var look=NativeAppearance.Look();look.textScale=1.3;look.clearGlass=true;look.background=NSColor(srgbRed:0.08,green:0.11,blue:0.16,alpha:1);look.foreground=NSColor(srgbRed:0.9,green:0.82,blue:0.7,alpha:1);look.accent = .systemPink;look.code.fontID="menlo";look.code.pointSize=16;look.code.text = .systemCyan;look.code.added = .systemGreen;look.code.removed = .systemRed
        let change=NativeAppearance.apply(look)
        check(change.redrawSnapshots && change.geometryChanged && change.effectiveMode=="dark" && change.clearGlass,"f132 resolved host change reports geometry, captures and dark-only mode")
        check(descendants(transcript).contains{$0 === user} && user.body.selectedRange()==selection,"f084 appearance keeps row/text identity and selection")
        check(composer.textView === editor && editor.undoManager === undo && composer.text=="Keep draft and Undo" && editor.selectedRange()==NSRange(location:2,length:4),"f132 appearance keeps composer editor, draft, selection and Undo")
        check(abs((editor.font?.pointSize ?? 0)-16.9)<0.01,"f132 composer follows body text scale")
        check(hidden.rowConfigurationCount(itemID:"user")==hiddenCount && hidden.refreshDeferred,"f084 hidden transcript defers appearance layout")
        hidden.prepareForSnapshot();check(!hidden.refreshDeferred && hidden.rowConfigurationCount(itemID:"user")>hiddenCount,"f084 explicit snapshot preparation flushes deferred appearance even while hidden")
        hidden.isHidden=false;check(hidden.rowConfigurationCount(itemID:"user")>hiddenCount && hidden.codeStyle.fontID=="menlo","f084 hidden transcript restores current style")
        let answer=descendants(transcript).compactMap{$0 as? NativeTranscriptRow}.first{$0.item.id == "answer"}!
        let codeText=answer.body.textStorage!,codeRange=(codeText.string as NSString).range(of:"let answer")
        let codeFont=codeText.attribute(.font,at:codeRange.location,effectiveRange:nil) as! NSFont
        check(codeFont.fontName.contains("Menlo") && abs(codeFont.pointSize-20.8)<0.01,"f084 code uses font, code size and body scale in real TextKit storage")
        check(abs(((answer.flightView(.workedDivider) as? NSTextField)?.font?.pointSize ?? 0)-14.95)<0.01,"f084 metadata and Worked-for flight labels follow the same body scale")
        check(NativeComposer().textView.font?.pointSize==editor.font?.pointSize && NativeTranscript(conversation:c).codeStyle==look.code,"f132 newly created retained views inherit the current look")
        let same=NativeAppearance.apply(look);check(!same.redrawSnapshots && !same.geometryChanged && same.revision==change.revision,"f132 identical look is a semantic no-op")
        // Resolve retained approval-button tint after every appearance observer has run.
        NativeAppearance.recolor(transcript)
        for scale:CGFloat in [1,2]{
            let flight=transcript.flightSource(.activityText,itemID:"command",scale:scale)!
            let command=descendants(transcript).compactMap{$0 as? NativeTranscriptRow}.first{$0.item.id == "command"}!
            let direct=NativeViewBitmap.capture(command.body,scale:scale)
            check(flight.image.dataProvider?.data == direct.dataProvider?.data,"f084 flight source uses the same themed native glyphs at \(scale)x")
            try save(transcript.snapshot(scale:scale),output.appendingPathComponent("ax-look-transcript@\(Int(scale))x.png"))
            try save(NativeViewBitmap.capture(composer,scale:scale),output.appendingPathComponent("ax-look-composer@\(Int(scale))x.png"))
        }
        var orange=look;orange.accent = .systemOrange;NativeAppearance.apply(orange)
        let warningHost=NativeFlippedView(frame:CGRect(x:0,y:0,width:100,height:30)),warning=NativeLabel(labelWithString:"Warning");warning.textColor = .systemOrange;warningHost.addSubview(warning)
        orange.accent = .systemBlue;NativeAppearance.apply(orange)
        check(warning.textColor == .systemOrange,"f132 accent change preserves independently coloured semantic warnings")
        transcript.presentationActive=false
        check(directText.accessibilityFrame().isEmpty && directText.accessibilityChildren()?.isEmpty != false,"f196 retiring presentation withdraws the complete semantic tree")
        check(NSApp.windows.allSatisfy{!$0.isVisible},"AX/look checks never present a window")
    }
    private static func save(_ image:CGImage,_ url:URL)throws{let canvas=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;let rect=CGRect(x:0,y:0,width:image.width,height:image.height);canvas.setFillColor(NativePalette.canvas.cgColor);canvas.fill(rect);canvas.draw(image,in:rect);try NSBitmapImageRep(cgImage:canvas.makeImage()!).representation(using:.png,properties:[:])!.write(to:url)}
}

@MainActor private final class NativeAXLookActions:NSObject,@unchecked Sendable {
    var generation=1,names=["Rename","Rename"],calls:[Int]=[]
    @objc func accessibilityFrame()->CGRect{CGRect(x:20,y:60,width:100,height:30)}
    @objc func accessibilityRole()->NSAccessibility.Role{.button}
    @objc func accessibilityCustomActions()->[NSAccessibilityCustomAction]{names.indices.map{i in NSAccessibilityCustomAction(name:names[i],handler:{[weak self] in self?.fire(i) ?? false})}}
    private nonisolated func fire(_ ordinal:Int)->Bool{MainActor.assumeIsolated{calls.append(generation*10+ordinal);return true}}
}
#endif
