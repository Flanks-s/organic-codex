#if OVERLAY_SELFTEST
import AppKit

@MainActor private final class Group1HitContent:OverlayView {
    var clicks=0
    override func mouseDown(with event:NSEvent){clicks+=1}
}
@MainActor private final class Group1Editor:NSTextView {
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect)}
}
@MainActor enum OverlayGroup1Verification {
    static func run(output:URL,check:(Bool,String)->Void) throws {
        let visible=NSApp.windows.filter(\.isVisible).count
        func views(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(views)}
        func layers(_ l:CALayer)->[CALayer]{[l]+(l.sublayers ?? []).flatMap(layers)}
        func event(_ type:NSEvent.EventType,_ p:CGPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:p,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        let all=Effort.allCases,models:[ModelCatalog.Model]=[
            .init(id:"all",name:"All",version:"",efforts:all),
            .init(id:"sparse",name:"Sparse",version:"",efforts:[.low,.high]),
            .init(id:"none",name:"No effort",version:"",efforts:[])]
        for reduced in [false,true] {
            let clock=OverlayManualClock(),root=OverlayView(frame:CGRect(x:0,y:0,width:1120,height:820))
            // Nonzero parent origin exercises window-base -> overlay -> slider conversions.
            let host=OverlayView(frame:CGRect(x:35,y:17,width:1050,height:780))
            root.addSubview(host)
            let body=Group1HitContent(frame:CGRect(x:0,y:0,width:500,height:650))
            let otherFull=Group1HitContent(frame:CGRect(x:520,y:0,width:500,height:650))
            let editor=Group1Editor(frame:CGRect(x:30,y:680,width:700,height:60))
            editor.isRichText=false;editor.isEditable=true;editor.string="Keep this draft and selection"
            editor.setSelectedRange(NSRange(location:5,length:4))
            for v in [body,otherFull,editor]{host.addSubview(v)}
            var settings=ModelSettings();settings.modelID="all";settings.effort=all[0]
            let picker=OverlayModelPicker(clock:clock);picker.reduceMotion=reduced
            picker.configure(settings:settings,models:models)
            let anchor=CGRect(x:180,y:700,width:120,height:26)
            picker.present(anchor:anchor,in:host);clock.advance(by:0.7)
            let slider=picker.reasoning;var selected:[Effort]=[]
            picker.onEffortSelected={selected.append($0)}
            for i in all.indices {
                let x=slider.stops[i]
                slider.pointerDown(x:x);clock.advance(by:0.011)
                slider.pointerDragged(x:x+0.1)
                check(slider.value == all[i] && picker.settings.effort == all[i],"G1 f117 every supported effort \(all[i]) reduced=\(reduced)")
                slider.pointerUp()
                if i+1<all.count {
                    let span=slider.stops[i+1]-x
                    slider.pointerDown(x:x+span*0.49)
                    check(slider.value == all[i],"G1 f117 nearest lower tick at 49 percent reduced=\(reduced)")
                    slider.pointerDragged(x:x+span*0.51)
                    check(slider.value == all[i+1],"G1 f117 nearest upper tick at 51 percent reduced=\(reduced)")
                    slider.pointerUp()
                }
            }
            slider.pointerDown(x:slider.stops.first!);clock.advance(by:0.01)
            slider.pointerDragged(x:slider.stops.last!)
            check(slider.isDragging && slider.lensStretch>0 && slider.lensStretch<=0.32,"G1 f117 held lens stretches within product bound reduced=\(reduced)")
            clock.advance(by:0.079);check(slider.isDragging,"G1 f117 long press keeps lens held before idle")
            clock.advance(by:1.5)
            check(slider.isDragging && slider.lensStretch == 0,"G1 f117 injected long hold settles velocity without releasing lens")
            slider.pointerUp();check(!slider.isDragging && slider.lensStretch == 0,"G1 f117 release lands on a supported tick")
            let word=OverlayRollingWord(clock:clock);word.reduceMotion=reduced
            _ = word.set("Low",ultra:false,animated:true)
            _ = word.set("Ultra",ultra:true,animated:true)
            check(word.direction == 1 && word.letters.allSatisfy{
                $0.gradient == OverlayStyle.ultra && $0.wordSpan?.width == word.frame.width &&
                abs(($0.wordSpan?.minX ?? 1)+$0.frame.minX)<0.001
            },"G1 f117 Ultra letters share one continuous whole-word gradient reduced=\(reduced)")
            for scale:CGFloat in [1,2] {
                let image=NativeViewBitmap.capture(word,scale:scale)
                let alpha=NSBitmapImageRep(cgImage:image)
                var columns=Set<Int>()
                for x in 0..<alpha.pixelsWide {for y in 0..<alpha.pixelsHigh where (alpha.colorAt(x:x,y:y)?.alphaComponent ?? 0)>0.5 {columns.insert(x)}}
                check(columns.count>Int(word.bounds.width*scale/5),"G1 f117 whole-word gradient draws actual glyphs at \(Int(scale))x")
                try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("group1-ultra-word-\(reduced)-\(Int(scale))x.png"))
            }
            if reduced {check(word.letters.allSatisfy{($0.layer?.animationKeys() ?? []).isEmpty},"G1 f117 reduced word omits letter motion")}
            _ = word.set("Low",ultra:false,animated:true)
            check(word.direction == -1 && word.letters.allSatisfy{$0.gradient.isEmpty},"G1 f117 lowering reverses direction and removes Ultra gradient")
            root.addSubview(word);word.frame.origin=CGPoint(x:30,y:60)
            for scale:CGFloat in [1,2] {
                let image=NativeViewBitmap.capture(slider,scale:scale)
                try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("group1-slider-\(reduced)-\(Int(scale))x.png"))
                check(image.width == Int(slider.bounds.width*scale),"G1 f117 native image \(Int(scale))x reduced=\(reduced)")
            }
            slider.pointerDown(x:slider.stops.last!)
            _ = picker.selectModel("sparse")
            check(!slider.isDragging && slider.lensStretch == 0 && slider.levels == [.low,.high],"G1 f117 changing model ends the old effort drag")
            slider.pointerDown(x:slider.stops.last!)
            _ = picker.selectModel("none");let before=picker.settings
            slider.pointerDragged(x:-900);clock.advance(by:2)
            check(!slider.isDragging && slider.levels.isEmpty && !picker.selectEffort(.ultra) && picker.settings == before,"G1 f117 no-effort model rejects old held pointer and delayed callbacks")
            picker.configure(settings:settings,models:models);picker.present(anchor:anchor,in:host);clock.advance(by:0.7)
            let originalAnchor=picker.anchorRect,originalCapsule=picker.capsuleRect,selection=editor.selectedRange(),draft=editor.string
            let down=slider.convert(CGPoint(x:slider.stops.first!,y:slider.bounds.midY),to:nil)
            slider.mouseDown(with:event(.leftMouseDown,down))
            let overEditor=editor.convert(CGPoint(x:editor.bounds.midX,y:editor.bounds.midY),to:nil)
            slider.mouseDragged(with:event(.leftMouseDragged,overEditor))
            slider.mouseUp(with:event(.leftMouseUp,overEditor))
            check(!slider.isDragging && body.clicks == 0 && otherFull.clicks == 0 && editor.selectedRange() == selection && editor.string == draft,"G1 f119 slider drag over native input never reaches underlying text/column")
            slider.cursorUpdate(with:event(.mouseMoved,overEditor))
            check(NSCursor.current === NSCursor.arrow && picker.anchorRect == originalAnchor && picker.capsuleRect == originalCapsule,"G1 f119 arrow cursor and overlay anchors remain stable after crossing input")
            for (label,target) in [("body",body),("other-full",otherFull)] {
                if !picker.isShowing || picker.isDismissing{picker.present(anchor:anchor,in:host);clock.advance(by:0.7)}
                let p=target.convert(CGPoint(x:10,y:20),to:host),rootPoint=host.convert(p,to:root),hit=root.hitTest(rootPoint)
                check(hit === picker,"G1 f119 \(label) outside hit is intercepted by topmost shield")
                if let hit {hit.mouseDown(with:event(.leftMouseDown,host.convert(p,to:nil)))}
                check(picker.isDismissing && body.clicks == 0 && otherFull.clicks == 0 && editor.selectedRange() == selection,"G1 f119 outside \(label) closes only picker and preserves selection")
                check(root.hitTest(rootPoint) === picker,"G1 f119 closing tail still blocks \(label)")
                clock.advance(by:0.24)
                check(!picker.isShowing && root.hitTest(rootPoint) !== picker,"G1 f119 shield retires after tail \(label)")
            }
            check(body.clicks == 0 && otherFull.clicks == 0 && editor.string == draft,"G1 f119 no redispatched click or draft mutation")
            if reduced {
                let animations=views(slider).compactMap(\.layer).flatMap(layers).flatMap{$0.animationKeys() ?? []}
                check(animations.isEmpty,"G1 f117 reduced slider has no motion or ambient animations after repeated drags")
            }
        }
        check(NSApp.windows.filter(\.isVisible).count == visible,"G1 overlays never display a window")
    }
}
#endif
