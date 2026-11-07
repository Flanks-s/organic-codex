#if M1_SELFTEST
import AppKit

@MainActor enum NativeM8Verification {
    static func run(output:URL,check:(Bool,String)->Void)throws{
        func descendants(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(descendants)}
        let options=NativeDisplayOptions.shared
        options.setVerificationState(.init(increaseContrast:false,reduceTransparency:false))
        defer{options.setVerificationState(nil)}
        var notifications=0
        let observer=options.observe{notifications+=1};defer{options.removeObserver(observer)}
        let c=Conversation(id:"m8-native",title:"Retained")
        c.items=[TranscriptItem(id:"retained-row",kind:.assistant,text:"Initial text",running:false)]
        let store=ConversationStore(conversations:[c],projects:[],devices:[])
        let transcript=NativeTranscript(conversation:c,store:store)
        transcript.frame=CGRect(x:0,y:0,width:620,height:440);transcript.refresh()
        let before=transcript.rowConfigurationCount(itemID:"retained-row")
        transcript.isHidden=true;c.items[0].text="Latest hidden revision";c.items[0].revision+=1;store.changed(c)
        check(transcript.rowConfigurationCount(itemID:"retained-row")==before,"M8 hidden transcript defers row rebuilding")
        transcript.isHidden=false
        check(transcript.rowConfigurationCount(itemID:"retained-row")==before+1,"M8 showing transcript applies the latest revision once")
        transcript.verificationWindowVisible=false
        c.items[0].text="Latest window revision";c.items[0].revision+=1;store.changed(c)
        check(transcript.rowConfigurationCount(itemID:"retained-row")==before+1,"M8 ordered-out window defers transcript layout")
        transcript.verificationWindowVisible=true
        check(transcript.rowConfigurationCount(itemID:"retained-row")==before+2,"M8 returning window consumes the latest deferred revision")
        let composer=NativeComposer(conversation:c,store:store)
        composer.frame=CGRect(x:0,y:0,width:620,height:112);composer.layoutMode = .growing
        _ = composer.setText("Retained draft");let editor=composer.textView,undo=editor.undoManager
        composer.isHidden=true;c.running=true;store.changed(c)
        check(!composer.state.running,"M8 hidden composer defers store projection")
        composer.isHidden=false;check(composer.state.running && composer.text=="Retained draft","M8 resumed composer applies model without replacing the draft")
        c.running=false;store.changed(c)
        let choices:[JSONValue]=["accept","acceptForSession",["acceptWithExecpolicyAmendment":["execpolicy_amendment":["git","status"]]],["applyNetworkPolicyAmendment":["network_policy_amendment":["host":"example.org","action":"allow"]]],"decline","cancel",["futureDecision":["scope":"exact"]]]
        let approval=Approval(id:"offered",title:"Run command",command:"git status",note:"Review scopes",acceptLabel:"Allow",toolItemID:"tool",method:"item/commandExecution/requestApproval",request:["params":["availableDecisions":.array(choices)]])
        let card=NativeTranscriptCard();let rail=NativeInteractionSurface(frame:CGRect(x:0,y:0,width:620,height:600));rail.addSubview(card)
        var responses:[JSONValue]=[]
        card.configureApproval(approval,width:600,enabled:true,respondValue:{responses.append($0)},action:{_ in})
        let labels=descendants(card).compactMap{($0 as? NSButton)?.title}
        for value in choices{check(labels.contains(NativeApprovalDecisions.title(value)),"M8 exact offered decision: "+NativeApprovalDecisions.title(value))}
        check(!labels.contains("Allow"),"M8 offered decisions do not synthesize an Accept fallback")
        for value in choices.dropLast(){check(card.chooseDecision(value),"M8 choose an offered known response");check(responses.last == ["decision":value],"M8 preserves exact response JSON")}
        check(!card.chooseDecision("not offered"),"M8 rejects unoffered decisions")
        var confirm:((Bool)->Void)?
        card.reviewUnknownDecision={_,done in confirm=done}
        let unknown=choices.last!,count=responses.count
        check(card.chooseDecision(unknown) && responses.count==count,"M8 unknown response requires explicit review")
        confirm?(false);check(responses.count==count,"M8 review cancellation sends nothing")
        _ = card.chooseDecision(unknown);confirm?(true);confirm?(true)
        check(responses.count==count+1 && responses.last == ["decision":unknown],"M8 review callback is single use and keeps JSON")
        _ = card.chooseDecision(unknown);rail.invalidateAccessibilityLease();confirm?(true)
        check(responses.count==count+1,"M8 stale review cannot act after a presentation lease ends")
        _ = card.chooseDecision(unknown);card.isHidden=true;confirm?(true)
        check(responses.count==count+1,"M8 hidden approval rejects a delayed review")
        card.isHidden=false
        let baseRevision=options.revision
        for state in [NativeDisplayOptions.State(increaseContrast:true,reduceTransparency:false),.init(increaseContrast:false,reduceTransparency:true),.init(increaseContrast:true,reduceTransparency:true)]{
            options.setVerificationState(state)
            check(options.state==state,"M8 workspace notification updates options")
            check(NativePalette.bubble.alphaComponent==1 && NativePalette.codeFill.alphaComponent==1,"M8 custom transcript plates become opaque")
            check(NativeDisplayOptions.plate(.systemTeal,alpha:0.12).alphaComponent==1,"M8 wash proxy becomes an opaque plate")
            check(composer.textView === editor && editor.undoManager === undo && composer.text=="Retained draft","M8 display options preserve editor draft and Undo")
            let freshComposer=NativeComposer(),freshTranscript=NativeTranscript(conversation:c)
            check(freshComposer.appearance?.name == NativeDisplayOptions.appearance?.name && freshTranscript.appearance?.name == NativeDisplayOptions.appearance?.name,"M8 new retained controls honor options already enabled at creation")
        }
        check(notifications==3 && options.revision==baseRevision+3,"M8 display changes notify retained views once per semantic change")
        options.setVerificationState(.init(increaseContrast:false,reduceTransparency:false))
        check(NativePalette.bubble.alphaComponent<1,"M8 transparency returns when both flags turn off")
        for scale in [CGFloat(1),2]{
            for contrast in [false,true]{
                options.setVerificationState(.init(increaseContrast:contrast,reduceTransparency:false))
                for (name,view) in [("approval-scopes",card as NSView),("composer-growing",composer as NSView),("transcript-accessible",transcript as NSView)]{
                    view.layoutSubtreeIfNeeded();let image=VerificationRaster.capture(view,scale:scale)
                    check(image.width==Int(view.bounds.width*scale),"M8 native bitmap width")
                    try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(name)-\(contrast ? "contrast":"normal")@\(Int(scale))x.png"))
                    let canvas=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    let rect=CGRect(x:0,y:0,width:image.width,height:image.height)
                    canvas.setFillColor(CGColor(gray:0.12,alpha:1));canvas.fill(rect);canvas.draw(image,in:rect)
                    try NSBitmapImageRep(cgImage:canvas.makeImage()!).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(name)-\(contrast ? "contrast":"normal")-canvas@\(Int(scale))x.png"))
                }
            }
        }
        c.approvals=[approval];transcript.refresh()
        let retiredCard=descendants(transcript).compactMap{$0 as? NativeTranscriptCard}.first!
        let retiredButton=descendants(retiredCard).compactMap{$0 as? NSButton}.first!
        transcript.dispose();let disposedCount=transcript.rowConfigurationCount(itemID:"retained-row")
        check(!retiredButton.accessibilityPerformPress(),"M8 retained raw control AX rejects disposed card actions")
        check(!retiredCard.chooseDecision("accept"),"M8 disposed card withdraws even outside its old root")
        retiredButton.performClick(nil);check(c.approvals.count==1,"M8 dispose cannot turn a delayed callback into a mock decision")
        c.items[0].text="Disposed update";store.changed(c);transcript.refresh()
        check(transcript.rowConfigurationCount(itemID:"retained-row")==disposedCount && !transcript.presentationActive,"M8 dispose withdraws and detaches transcript updates")
        check(NSApp.windows.allSatisfy{!$0.isVisible},"M8 verification opens no windows")
    }
}
#endif
