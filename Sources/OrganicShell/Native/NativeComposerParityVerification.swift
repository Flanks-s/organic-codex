#if M1_SELFTEST
import AppKit

/// The PARITY_DRAFT fixtures are identical to tools/parity/capture.py. No window, backend, or app launch.
@MainActor enum NativeComposerM9Verification {
    static let english = "Tighten the sidebar rows to the system metrics, then check that the profile capsule still clears the list when the window is at its narrowest width and the inspector is open on the right side of the detail pane."
    static let chinese = "把侧栏的行高收紧到系统的标准值，然后检查窗口最窄、右侧检查器打开时，个人资料胶囊是否仍然不会挡住列表。"
    static func run(output: URL, check: (Bool,String) -> Void) throws {
        let folder = output.appendingPathComponent("m9-composer")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let look=NativeAppearance.current,models=ModelCatalog.models
        defer { NativeAppearance.apply(look);ModelCatalog.models=models }
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var log:[[String:Any]]=[]
        var comparisons:[[String:Any]]=[]
        func rect(_ r:CGRect)->[CGFloat]{[r.minX,r.minY,r.width,r.height]}
        func lines(_ view:NSTextView)->[String] {
            guard let manager=view.layoutManager,let container=view.textContainer else{return []}
            manager.ensureLayout(for:container)
            let source=view.string as NSString
            var result:[String]=[]
            manager.enumerateLineFragments(forGlyphRange:manager.glyphRange(for:container)){_,_,_,glyphs,_ in
                let range=manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
                result.append(source.substring(with:range))
            }
            return result
        }
        func compare(_ image:CGImage,_ name:String)throws {
            let isApproval=name.hasPrefix("approval-")
            let isOrganic=name.hasPrefix("organic-")
            let suffix=name.hasSuffix("long") ? "-long":name.hasSuffix("zh") ? "-zh":""
            let sourceName=(isOrganic ? "organic":"normie")+suffix+"-product.png"
            let source=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("runs/parity-205445/"+sourceName)
            guard let data=try? Data(contentsOf:source),let rep=NSBitmapImageRep(data:data),let full=rep.cgImage else{return}
            check(full.width==1280 && full.height==820,"M9 supplied product reference is1280x820 "+sourceName)
            let inputHeight:CGFloat=suffix == "-long" ? 128:120
            let crop: CGRect
            if isOrganic { crop=CGRect(x:78,y:740,width:516,height:48) }
            else if isApproval { crop=CGRect(x:376,y:806-inputHeight-12-142,width:768,height:142) }
            else { crop=CGRect(x:376,y:806-inputHeight,width:768,height:inputHeight) }
            guard let product=full.cropping(to:crop) else{return}
            try NSBitmapImageRep(cgImage:product).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+"-product.png"))
            check(product.width==image.width && product.height==image.height,"M9 product/v2 comparison has identical crop dimensions "+name)
            let color=CGColorSpace(name:CGColorSpace.sRGB)!
            func rgba(_ image:CGImage)->[UInt8] {
                let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
                return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
            }
            let a=rgba(product),b=rgba(image);var diff=[UInt8](repeating:255,count:a.count),error=0,maximum=0
            for i in stride(from:0,to:min(a.count,b.count),by:4) {
                for k in 0..<3 {let d=abs(Int(a[i+k])-Int(b[i+k]));error+=d;maximum=max(maximum,d);diff[i+k]=UInt8(min(255,d*4))}
            }
            if isApproval {
                func ink(_ bytes:[UInt8],_ roi:CGRect,_ threshold:UInt8)->CGRect? {
                    var minX=product.width,minY=product.height,maxX = -1,maxY = -1
                    for y in Int(roi.minY)..<Int(roi.maxY) {for x in Int(roi.minX)..<Int(roi.maxX) {
                        let i=(y*product.width+x)*4
                        if min(bytes[i],bytes[i+1],bytes[i+2])>threshold {minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)}
                    }}
                    return maxX<minX ? nil:CGRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1)
                }
                for (part,roi,threshold) in [("Title",CGRect(x:36,y:14,width:160,height:20),UInt8(170)),("Source",CGRect(x:14,y:35,width:350,height:20),UInt8(110)),("Command",CGRect(x:14,y:55,width:500,height:25),UInt8(170)),("Note",CGRect(x:14,y:80,width:300,height:18),UInt8(110))] {
                    let expected=ink(a,roi,threshold),actual=ink(b,roi,threshold)
                    let difference=zip(expected.map{[$0.minX,$0.minY,$0.width,$0.height]} ?? [],actual.map{[$0.minX,$0.minY,$0.width,$0.height]} ?? []).map{abs($0-$1)}.max() ?? 999
                    check(expected != nil && actual != nil && difference<=1,"M9 reference approval "+part+" ink within1 backing pixel "+name+"; expected "+String(describing:expected)+", actual "+String(describing:actual))
                }
                func runs(_ bytes:[UInt8])->[[Int]] {
                    var result:[[Int]]=[],start:Int?
                    for x in 0..<product.width {
                        let i=(115*product.width+x)*4,v=[Int(bytes[i]),Int(bytes[i+1]),Int(bytes[i+2])]
                        let filled=v.min()!>90 && v.max()!-v.min()!<40
                        if filled {if start==nil{start=x}}else if let s=start {if x-s>35{result.append([s,x-s])};start=nil}
                    }
                    return result
                }
                check(runs(a)==[[554,66],[628,70],[706,48]] && runs(b)==runs(a),"M9 reference approval painted button spans are pixel-exact "+name)
            }
            let provider=CGDataProvider(data:Data(diff) as CFData)!
            let difference=CGImage(width:product.width,height:product.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:product.width*4,space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            try NSBitmapImageRep(cgImage:difference).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+"-diff-x4.png"))
            let side=CGContext(data:nil,width:product.width*2+8,height:product.height,bitsPerComponent:8,bytesPerRow:0,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            side.setFillColor(NSColor.darkGray.cgColor);side.fill(CGRect(x:0,y:0,width:product.width*2+8,height:product.height))
            side.draw(product,in:CGRect(x:0,y:0,width:product.width,height:product.height));side.draw(image,in:CGRect(x:product.width+8,y:0,width:image.width,height:image.height))
            try NSBitmapImageRep(cgImage:side.makeImage()!).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+"-compare.png"))
            comparisons.append(["state":name,"product":sourceName,"crop":[crop.minX,crop.minY,crop.width,crop.height],"rgbMeanAbsoluteError":Double(error)/Double(product.width*product.height*3),"maxChannelError":maximum,"note":"Left=real product window; right=v2 offscreen native controls with neutral glass proxy. This is not a real-window pixel-equivalence assertion."])
        }
        func save(_ view:NSView,_ name:String,_ scale:CGFloat)throws {
            view.layoutSubtreeIfNeeded()
            let image=NativeViewBitmap.capture(view,scale:scale)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+"@\(Int(scale))x.png"))
            check(image.width==Int(view.bounds.width*scale) && image.height==Int(view.bounds.height*scale),"M9 capture dimensions \(name) \(scale)x")
            if scale == 1 { try compare(image,name) }
        }
        for scale:CGFloat in [1,2] {
            let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
            let c=store.conversation("A")!,other=store.conversation("B")!
            let composer=NativeComposer(conversation:c,store:store)
            composer.sendShortcut = .commandReturn;composer.onStop={};composer.verificationScale=scale
            let editor=composer.textView,undo=editor.undoManager
            let canvas=NativeComposerM9Canvas(frame:CGRect(x:0,y:0,width:768,height:120))
            canvas.addSubview(composer)
            for (name,draft) in [("empty",""),("long",english),("zh",chinese)] {
                _ = composer.setText(draft)
                // Explicitly arrive from a bar; this catches the old targetWidth re-admission bug.
                composer.targetWidth=516;composer.fixedHeight=48
                let height=composer.prepareNormieLayout(width:768,detailHeight:760)
                canvas.frame.size=CGSize(width:768,height:height);composer.frame=canvas.bounds
                canvas.plate=composer.frame;canvas.radius=20
                composer.textView.onFocusChange?(true)
                let textLines=lines(editor)
                check(composer.layoutMode == .growing && composer.targetWidth == nil,"M9 Normie admission stays growing \(name)/\(scale)x")
                check(composer.scrollView.frame.minX==14 && composer.scrollView.frame.width==740,"M9 1280 window gives 768 dock / 740 full-width body \(name)/\(scale)x")
                check(composer.scrollView.frame.minY==36 && editor.textContainerInset.height==6,"M9 context top32 + gap4, editor inset6 \(name)/\(scale)x")
                check(composer.accessButton.frame.minY==height-40 && (composer.sendButton.isHidden ? composer.voiceButton:composer.sendButton).frame.midY==height-26,"M9 separate bottom control row \(name)/\(scale)x")
                check(composer.scrollView.frame.maxY+4<=composer.accessButton.frame.minY,"M9 body cannot overlap control row \(name)/\(scale)x")
                check(composer.placeholder=="Message Codex — ⌘↩ to send","M9 running Normie keeps product placeholder")
                check(composer.textView.font?.pointSize==13 && composer.modelButton.font?.pointSize==13,"M9 editor and model use13pt")
                check(composer.contextRow.project.stringValue=="Synthetic preview workspace" && composer.workspace.branch==c.branch,"M9 context retains workspace/branch/device")
                check(composer.workspace.status.contains("3 sub-agents") && !composer.contextRow.spinner.isHidden,"M9 running status includes mini spinner and three satellites")
                check(!composer.contextButton.isHidden && composer.contextRing.frame.size==CGSize(width:15,height:15),"M9 Normie existing chat keeps15pt context ring")
                check(name != "long" || textLines.count==2,"M9 supplied long English is two full-width lines \(scale)x, got \(textLines.count)")
                check(name != "zh" || textLines.count==1,"M9 supplied Chinese fits one full-width line")
                check(composer.stopButton.normie,"M9 growing Stop uses bordered-circle plate")
                check(composer.textView.textColor == NSColor.textColor,"M9 default editor uses ComposerEditor native textColor")
                check(name != "long" || height==128,"M9 long English dock is128pt, got \(height)")
                check(name != "empty" || height==120,"M9 empty running dock is120pt")
                check(name != "empty" || (!composer.voiceButton.isHidden && composer.sendButton.isHidden),"M9 empty running Normie offers Voice, not Send")
                check(name == "empty" || (!composer.sendButton.isHidden && composer.voiceButton.isHidden),"M9 nonempty Normie offers accent Send")
                check(composer.modelButton.itemTitle(at:0)=="GPT-6.1 Sol · High","M9 wide model label includes official name and effort")
                try save(canvas,"normie-"+name,scale)
                let dockFrame=CGRect(x:376,y:820-14-height,width:768,height:height)
                log.append(["state":"normie-"+name,"scale":scale,"window":[1280,820],"dock":rect(dockFrame),"body":rect(composer.scrollView.frame),"controlsY":composer.accessButton.frame.minY,"lineCount":textLines.count,"lines":textLines,"projectFrame":rect(composer.contextRow.project.frame),"projectFont":composer.contextRow.project.font!.pointSize])
                // Approval source and its actions live inside the same 768 pt glass, not in an external row.
                let card=NativeTranscriptCard(),approval=other.approvals[0]
                var routes=0,decisions:[ApprovalAction]=[]
                card.configureApproval(approval,width:1040){decisions.append($0)}
                card.setApprovalSource(.init(project:"Synthetic preview workspace",conversation:other.title,isOtherConversation:true),showConversation:{routes+=1})
                let plate=card.approvalPlateRect
                let cardCanvas=NativeComposerM9Canvas(frame:CGRect(x:0,y:0,width:768,height:card.frame.height))
                cardCanvas.addSubview(card);card.frame.origin.x = -plate.minX
                let buttons=card.subviews.compactMap{$0 as? NSButton},link=buttons.first{$0.title=="Show Conversation"}!
                let actions=buttons.filter{["Cancel","Decline",approval.acceptLabel].contains($0.title)}.sorted{$0.frame.minX<$1.frame.minX}
                check(plate.width==768 && card.frame.height==142,"M9 rail approval is768x142, got \(plate)/\(card.frame.height)")
                check(link.frame.minY>14 && link.frame.maxY<card.subviews.compactMap{$0 as? NSScrollView}.first!.frame.minY,"M9 source line is between title and command inside card")
                check(actions.map(\.title)==["Cancel","Decline",approval.acceptLabel] && actions.last!.frame.maxX==plate.maxX-14,"M9 Cancel/Decline/Run preserve order and align right14")
                check(actions.allSatisfy{$0.frame.height==26 && $0.frame.insetBy(dx:0,dy:1).maxY<=card.frame.height-14},"M9 decision frame26, painted plate24 and14pt bottom inset")
                check(actions.map{$0.frame.width} == [66,70,48],"M9 approval uses product regular13pt button widths66/70/48")
                link.performClick(nil);check(routes==1 && decisions.isEmpty,"M9 Show Conversation routes once and never approves")
                let command=card.subviews.compactMap{$0 as? NSScrollView}.first!
                check(command.frame.height==16 && (command.documentView as? NSTextView)?.string==approval.command,"M9 single-line command stays complete and selectable")
                try save(cardCanvas,"approval-"+name,scale)
                log.append(["state":"approval-"+name,"scale":scale,"plate":rect(plate),"height":card.frame.height,"buttonFrames":actions.map{rect($0.frame)},"windowTop":dockFrame.minY-12-card.frame.height])
                let longRequest=Approval(id:"m9-long-command",title:approval.title,command:String(repeating:"printf harmless\n",count:80),note:approval.note,acceptLabel:approval.acceptLabel,toolItemID:"")
                card.configureApproval(longRequest,width:1040){decisions.append($0)}
                check(card.subviews.compactMap{$0 as? NSScrollView}.first?.frame.height==136 && card.frame.height<300,"M9 rail caps a long command136 while decisions remain visible")
                card.setApprovalSource(.init(project:"Synthetic preview workspace",conversation:other.title,isOtherConversation:true,canShowConversation:false))
                let unavailable=card.subviews.compactMap{$0 as? NSButton}.first{$0.title=="Show Conversation"}!
                unavailable.performClick(nil);check(!unavailable.isEnabled && routes==1,"M9 archived source cannot reveal a conversation")
                card.setApprovalSource(nil)
                check(card.approvalSource==nil && card.approvalPlateRect.width==740,"M9 return to inline clears Normie presentation without changing request")
            }
            // Growing max =84+280; overflow is inside the editor, never over the controls/context.
            _ = composer.setText(String(repeating:english+"\n",count:30))
            let cap=composer.prepareNormieLayout(width:768,detailHeight:760)
            check(cap==364 && composer.scrollView.frame.height==280,"M9 long draft clamps editor280 / dock364")
            check(composer.scrollView.hasVerticalScroller && composer.textView.frame.height>280,"M9 capped body retains native scrolling")
            // Deliberately preserve the existing attachment-only send path. Product ComposerDock's
            // empty-text Voice branch ignores attachments even though its canSend includes them.
            _ = composer.setText("")
            composer.attachments=[.init(id:"m9-file",name:"fixture.txt",symbol:"doc",input:["type":"text","text":"fixture"])]
            _ = composer.prepareNormieLayout(width:768,detailHeight:760)
            check(!composer.sendButton.isHidden && composer.voiceButton.isHidden && composer.canSend,"M9 exception2: attachment-only draft keeps Send instead of hiding it behind Voice")
            composer.attachments=[]
            _ = composer.setText(english)
            composer.targetWidth=516;composer.fixedHeight=48;composer.frame=CGRect(x:0,y:0,width:516,height:48)
            composer.needsLayout=true;composer.layoutSubtreeIfNeeded();composer.measureNow()
            canvas.frame.size=CGSize(width:516,height:48);canvas.plate=canvas.bounds;canvas.radius=24;composer.frame=canvas.bounds
            check(composer.contextButton.isHidden && composer.contextRow.isHidden,"M9 full bar has neither context ring nor workspace row")
            check(composer.textView.textContainerInset.height==12,"M9 FullBar keeps product12pt one-line inset while long drafts scroll")
            check(composer.modelButton.itemTitle(at:0)=="Sol · High","M9 compact full bar preserves effort label")
            check(composer.scrollView.frame.width>=245 && composer.measuredHeight==48,"M9 full bar gives reclaimed ring space to native text")
            check(editor===composer.textView && undo===editor.undoManager && editor.string==english,"M9 Normie/bar morph keeps native editor, Undo and full draft")
            try save(canvas,"organic-long",scale)
            for (name,draft) in [("empty",""),("zh",chinese)] {
                _ = composer.setText(draft);composer.needsLayout=true;composer.layoutSubtreeIfNeeded();composer.measureNow()
                try save(canvas,"organic-"+name,scale)
            }
            c.approvals=other.approvals;composer.refresh();_ = composer.prepareNormieLayout(width:768,detailHeight:760)
            check(composer.workspace.statusMark=="hand.raised.fill" && composer.contextRow.spinner.isHidden,"M9 own approval substitutes orange hand for activity spinner")
            let parent=NativeComposerM9Canvas(frame:CGRect(x:0,y:0,width:768,height:120));let draft=NativeComposer();parent.addSubview(draft)
            _ = draft.prepareNormieLayout(width:768,detailHeight:760)
            check(draft.contextButton.isHidden,"M9 New Chat has no conversation context ring")
        }
        let data=try JSONSerialization.data(withJSONObject:log,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:folder.appendingPathComponent("geometry.json"))
        try JSONSerialization.data(withJSONObject:comparisons,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("comparison.json"))
    }
}

@MainActor private final class NativeComposerM9Canvas: NativeFlippedView {
    var plate=CGRect.zero,radius:CGFloat=20
    override func draw(_ dirtyRect:NSRect) {
        NativePalette.canvas.setFill();bounds.fill()
        NativeDisplayOptions.plate(alpha:0.08).setFill();NSBezierPath(roundedRect:plate,xRadius:radius,yRadius:radius).fill()
    }
}
#endif
