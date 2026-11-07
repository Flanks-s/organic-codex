#if NORMIE_SELFTEST
import AppKit

@MainActor enum NormieLookVerification {
    static func run(directory:URL,check:(Bool,String)->Void)throws{
        let original=NativeAppearance.current;defer{NativeAppearance.apply(original)}
        let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        let wb=NormieWorkbench(store:store,sessions:NativeComposerSessions(),current:"A")
        let canvas=NormieView(frame:CGRect(x:0,y:0,width:1280,height:820));canvas.fill=NativePalette.canvas
        for c in [wb.sidebar as NSViewController,wb.detail,wb.inspector]{canvas.addSubview(c.view)}
        wb.sidebar.view.frame=CGRect(x:0,y:0,width:260,height:820);wb.detail.view.frame=CGRect(x:260,y:0,width:700,height:820);wb.inspector.view.frame=CGRect(x:960,y:0,width:320,height:820)
        wb.refresh();wb.reviewChanges()
        var mounts:[NativeComposer?]=[],hosts:[NSView?]=[]
        wb.onComposerPresentationChange={mounts.append($0);hosts.append($1)}
        check(mounts.count==1 && mounts[0] === wb.detail.composer && hosts[0] === wb.detail.view,"f106 host receives the current composer and its actual Normie overlay coordinate host")
        wb.refresh();check(mounts.count==1,"f106 store refresh does not reinstall an identical mount")
        _ = wb.composerForHandoff();check(mounts.last! == nil,"f106 handoff withdraws the old binding before Organic takes ownership")
        wb.remountComposer();check(mounts.last! === wb.detail.composer,"f106 reverse handoff publishes the retained composer mount")
        for file in store.conversation("A")!.changes{if !wb.inspector.isFileExpanded(file.path){wb.inspector.toggleFile(file.path)}}
        NormieVerification.layout(canvas,scale:2)
        let code=descendants(wb.inspector.view).compactMap{$0 as? NormieDiffTextView}.first!
        code.setSelectedRange(NSRange(location:2,length:3));let editor=wb.detail.composer!.textView
        let sidebar=wb.sidebar.view,detail=wb.detail.view,inspector=wb.inspector.view,scroll=wb.inspector.scrollView
        var look=NativeAppearance.Look();look.background=NSColor(srgbRed:0.10,green:0.14,blue:0.18,alpha:1);look.foreground=NSColor(srgbRed:0.92,green:0.84,blue:0.72,alpha:1);look.accent = .systemOrange;look.wash = .systemPurple;look.clearGlass=true;look.textScale=1.3;look.code.fontID="monaco";look.code.pointSize=18;look.code.text = .systemCyan;look.code.added = .systemGreen;look.code.removed = .systemPink
        NativeAppearance.apply(look);NormieVerification.layout(canvas,scale:2)
        check(wb.sidebar.view === sidebar && wb.detail.view === detail && wb.inspector.view === inspector && wb.inspector.scrollView === scroll,"f132 retained Normie controllers, roots and inspector scroll remain identical")
        check(wb.detail.composer!.textView === editor,"f132 Normie composer retains its shared editor")
        check(descendants(inspector).contains{$0 === code} && code.selectedRange()==NSRange(location:2,length:3),"f133 real diff view and selection survive appearance changes")
        let font=code.textStorage!.attribute(.font,at:0,effectiveRange:nil) as! NSFont
        check(font.fontName.contains("Monaco") && abs(font.pointSize-16.5)<0.01,"f133 diff uses code font and code size")
        check((detail as! NormieView).fill==look.canvas && wb.detail.composerGlass.style == .clear,"f132 canvas and actual composer glass update together")
        check(wb.detail.composerGlass.tintColor==look.background?.withAlphaComponent(0.2),"f132 clear glass uses product tint strength")
        // Resolve the themed ancestor pass last for a deterministic offscreen fixture.
        NativeAppearance.recolor(canvas)
        for scale:CGFloat in [1,2]{let image=NativeViewBitmap.capture(canvas,scale:scale);try NormieVerification.write(image,to:directory.appendingPathComponent("normie-look@\(Int(scale))x.png"));check(image.width==1280*Int(scale),"f132 themed Normie offscreen bitmap scale")}
        var reset=original;reset.clearGlass=false;NativeAppearance.apply(reset);NormieVerification.layout(canvas,scale:2)
        check(wb.detail.composerGlass.style == .regular && code.selectedRange()==NSRange(location:2,length:3),"f133 reset retains diff selection and restores regular glass")
        NativeDisplayOptions.shared.setVerificationState(.init(increaseContrast:false,reduceTransparency:true));defer{NativeDisplayOptions.shared.setVerificationState(nil)}
        var opaque=look;opaque.background=NSColor(srgbRed:0.05,green:0.09,blue:0.20,alpha:1);NativeAppearance.apply(opaque)
        let plates=descendants(inspector).compactMap{$0 as? NormieView}.filter{$0.layer?.backgroundColor != nil}
        check(!plates.isEmpty && plates.allSatisfy{$0.layer?.backgroundColor == NativeDisplayOptions.plate(alpha:0.045).cgColor},"f132 reduced-transparency inspector plates are recomposited onto the new canvas")
        wb.dispose()
    }
    static func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
}
#endif
