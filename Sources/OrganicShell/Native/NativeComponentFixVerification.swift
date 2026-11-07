#if M1_SELFTEST
import AppKit

@MainActor enum NativeComponentFixVerification {
    static func run(output:URL,check:(Bool,String)->Void) throws {
        func tree(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(tree)}
        func capture(_ view:NSView,_ name:String)throws{for scale:CGFloat in [1,2]{let image=VerificationRaster.capture(view,scale:scale),rep=NSBitmapImageRep(cgImage:image);try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("component-\(name)@\(Int(scale))x.png"))
            let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(white:0.055,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:image.width,height:image.height));context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            try NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("component-\(name)-canvas@\(Int(scale))x.png"))
        }}
        let saved=NativeAppearance.current;defer{NativeAppearance.apply(saved)}
        NativeAppearance.apply(.init())
        let c=Conversation(id:"reading-anchor",title:"Reading")
        c.items=(0..<35).map{.init(id:"line-\($0)",turnID:"reading",kind:.assistant,text:String(repeating:"Readable paragraph with **markdown** and wrapping. ",count:18))}
        let transcript=NativeTranscript(conversation:c);transcript.frame=CGRect(x:0,y:0,width:780,height:280);transcript.refresh(preservingOffset:false)
        transcript.scrollToItem(itemID:"line-10")
        let rows=transcript.scrollView.documentView!.subviews.compactMap{$0 as? NativeTranscriptRow}
        let anchor=rows.first{$0.item.id == "line-10"}!
        transcript.scrollOffset=CGPoint(x:0,y:anchor.frame.minY+3)
        let relative=anchor.frame.minY-transcript.scrollOffset.y
        transcript.setSelectedRange(NSRange(location:2,length:7),itemID:anchor.item.id)
        transcript.frame.size.width=430;transcript.layoutSubtreeIfNeeded()
        check(abs(anchor.frame.minY-transcript.scrollOffset.y-relative)<1.01,"C03 narrowing preserves the first visible message and intra-row offset")
        // A hidden Stop button not laid out yet: its indicator gets an empty rect, never CGRect.null.
        check([CGRect.zero,CGRect(x:3,y:3,width:8,height:30),CGRect(x:0,y:0,width:30,height:30)].allSatisfy{let r=NativeComposer.indicatorRect(in:$0);return !r.isNull && !r.isInfinite && r.width>=0},"composer progress indicators never get a null rect")
        check(transcript.selectedRange(itemID:anchor.item.id) == NSRange(location:2,length:7),"C03 reflow preserves selection")
        var look=NativeAppearance.current;look.textScale=1.5;NativeAppearance.apply(look)
        check(abs(anchor.frame.minY-transcript.scrollOffset.y-relative)<1.01,"C03 text-size change preserves the reading anchor")
        transcript.isHidden=true;look.textScale=1.3;NativeAppearance.apply(look);transcript.isHidden=false
        check(abs(anchor.frame.minY-transcript.scrollOffset.y-relative)<1.01,"C03 deferred font reflow restores the same reading anchor when a hidden chat returns")
        let frozen=transcript.scrollOffset;c.items[0].text+=String(repeating:" more content",count:60);transcript.refresh(preservingOffset:true)
        check(transcript.scrollOffset == frozen,"C03 explicit flight refresh still freezes pixel offset")
        transcript.scrollToEnd();transcript.frame.size.width=620
        check(transcript.isAtEnd,"C03 resizing a bottom-following transcript still follows end")
        transcript.scrollToEnd();transcript.scrollOffset = .zero
        let latest=tree(transcript).compactMap{$0 as? NSButton}.first{$0.title == "Jump to Latest"}!
        check(!transcript.newContentWhileAway && !latest.isHidden,"C04 long completed history offers Jump without new messages")
        latest.performClick(nil);check(transcript.isAtEnd && latest.isHidden,"C04 visible Jump returns to end and disappears")
        transcript.scrollOffset=CGPoint(x:0,y:transcript.contentHeight-transcript.scrollView.contentSize.height-100)
        check(latest.isHidden,"C04 history within one viewport stays unobstructed")
        transcript.scrollToEnd()
        transcript.dispose()

        NativeAppearance.apply(.init())
        let approval=NativeTranscriptCard(),parent=NativeFlippedView(frame:CGRect(x:0,y:0,width:640,height:800));parent.addSubview(approval)
        let command=(0..<100).map{"echo harmless-\($0)"}.joined(separator:"\n")
        approval.configureApproval(.init(id:"long",title:"Run this command?",command:command,note:"Recorded request",acceptLabel:"Allow",toolItemID:""),width:640){_ in}
        let scroll=approval.subviews.compactMap{$0 as? NSScrollView}.first!
        check(scroll.frame.height == 136 && approval.frame.height<320,"C05 command scroll is capped at 136 while decisions remain compact")
        check((scroll.documentView as? NSTextView)?.string == command && scroll.documentView!.frame.height>136,"C05 full command remains selectable inside the inner viewport")
        check(approval.subviews.compactMap{$0 as? NSButton}.allSatisfy{$0.frame.maxY<320},"C05 long command cannot push decision buttons below its viewport")
        scroll.contentView.scroll(to:CGPoint(x:0,y:300.7));check(scroll.contentView.bounds.minY.rounded() == scroll.contentView.bounds.minY,"C05 inner scroll stays on the backing grid")
        try capture(approval,"approval")

        let question=NativeTranscriptCard();parent.addSubview(question)
        let request=UserInputRequest(id:"multi",questions:[.init(id:"explanation",header:"Explain",prompt:"Your explanation",options:[]),.init(id:"secret",header:"",prompt:"Secret",options:[],isSecret:true)])
        var answers:[String:[String]]?,heightChanges=0
        question.onHeightChange={heightChanges+=1}
        question.configureQuestion(request,width:640){answers=$0}
        let field=question.subviews.compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue == "explanation"}!
        let secret=question.subviews.compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue == "secret"}!
        let oldHeight=question.frame.height
        field.stringValue="First line\nSecond line\nThird line\nFourth line";question.controlTextDidChange(.init(name:NSControl.textDidChangeNotification,object:field))
        check(field.frame.height>50 && question.frame.height>oldHeight && heightChanges == 1,"C06 four-line answer grows field and notifies parent layout")
        check(field.superview === question && field.stringValue.contains("Fourth line"),"C06 resizing retains the same native answer control and its contents")
        let cap=field.frame.height;field.stringValue+="\nFifth\nSixth";question.controlTextDidChange(.init(name:NSControl.textDidChangeNotification,object:field))
        check(field.frame.height == cap,"C06 answers stop growing after four lines without truncating stored text")
        secret.stringValue="hidden\nsecret";question.controlTextDidChange(.init(name:NSControl.textDidChangeNotification,object:secret))
        check(secret is NativeSecureField && secret.frame.height == 18,"C06 secret remains a one-line secure field")
        let submit=question.subviews.compactMap{$0 as? NSButton}.first{$0.title == "Submit answer"}!
        submit.performClick(nil);check(answers?["explanation"] == [field.stringValue] && answers?["secret"] == [secret.stringValue],"C06 multiline answers retain exact question IDs and values")
        try capture(question,"question")
        field.stringValue="one";question.controlTextDidChange(.init(name:NSControl.textDidChangeNotification,object:field))
        check(field.frame.height == 18,"C06 deleting lines shrinks the answer field")

        for kind:RowKind in [.user,.assistant,.tool(.command)] {
            let row=NativeTranscriptRow();parent.addSubview(row)
            let item=TranscriptItem(id:"copy-\(String(describing:kind))",turnID:"copy",kind:kind,text:"**Raw** message\n`code`")
            row.configure(item,sourceItem:item,index:0,items:[item],width:640,expanded:true)
            check(row.menu?.items.contains{$0.title == "Copy Message"} == true && row.body.menu === row.menu,"C17 \(kind) row and body expose Copy Message")
            let pasteboard=NSPasteboard.withUniqueName();defer{pasteboard.releaseGlobally()}
            check(row.copyMessage(to:pasteboard) && pasteboard.string(forType:.string) == item.text,"C17 \(kind) Copy Message keeps raw markdown, not rendered text")
            row.isHidden=true;check(!row.copyMessage(to:pasteboard),"C17 hidden row refuses a stale Copy action")
        }
        let changes=NativeTranscriptRow();parent.addSubview(changes)
        var item=TranscriptItem(id:"changes",turnID:"changes",kind:.notice(.info),text:"Sources/View.swift  +2 −1",status:TranscriptPresentation.changesStatus)
        check(TranscriptPresentation.isChangesCard(item),"C19 fixture is a changes summary")
        changes.onReview={};changes.onRevert={}
        changes.configure(item,sourceItem:item,index:0,items:[item],width:640,expanded:false)
        let review=changes.subviews.compactMap{$0 as? NSButton}.first{$0.title == "Review"}!,undo=changes.subviews.compactMap{$0 as? NSButton}.first{$0.title == "Undo"}!
        check(review.frame.midY<changes.body.frame.minY && undo.frame.midY<changes.body.frame.minY,"C19 Review and Undo sit in the meta row above the body")
        let rowHeight=changes.frame.height;item.status=TranscriptPresentation.changesReverted
        changes.configure(item,sourceItem:item,index:0,items:[item],width:640,expanded:false)
        check(undo.isHidden && !review.isHidden && changes.frame.height == rowHeight,"C19 Reverted hides Undo without reserving a lower action row")
        try capture(changes,"changes")

        var accent=NativeAppearance.current;accent.accent=NSColor(srgbRed:0.2,green:0.4,blue:0.8,alpha:1);NativeAppearance.apply(accent)
        let composer=NativeComposer();composer.frame=CGRect(x:0,y:0,width:640,height:48);parent.addSubview(composer)
        _ = composer.setText("Send");composer.layoutSubtreeIfNeeded();composer.measureNow()
        check(type(of:composer.sendButton) == NativePrimaryButton.self && type(of:composer.voiceButton) == NativePrimaryButton.self,"C16 Send and Voice share the custom accent circle renderer")
        for button in [composer.sendButton,composer.voiceButton] {
            let savedFrame=button.frame,savedHidden=button.isHidden,savedEnabled=button.isEnabled
            button.isHidden=false
            button.frame=CGRect(x:0,y:0,width:28,height:28)
            for enabled in [true,false] {button.isEnabled=enabled
                for scale:CGFloat in [1,2]{let image=VerificationRaster.capture(button,scale:scale)
                    let ctx=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));let bytes=ctx.data!.assumingMemoryBound(to:UInt8.self),index=(Int(3*scale)*image.width+Int(14*scale))*4
                    check(abs(Int(bytes[index+3])-(enabled ? 255:115))<=1,"C16 \(scale)x primary circle uses \(enabled ? "solid":"45%") accent alpha")
                }
            }
            button.frame=savedFrame;button.isHidden=savedHidden;button.isEnabled=savedEnabled
        }
        try capture(composer,"composer")
        composer.state.voice="heard"
        check(!composer.voiceButton.drawsAccentCircle && composer.sendButton.drawsAccentCircle,"C16 active Voice keeps the borderless End action beside its accent Send")
    }
}
#endif
