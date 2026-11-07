import AppKit
import CoreText

@MainActor enum DebugPaint {
    static let background=NSColor(srgbRed:0.075,green:0.085,blue:0.095,alpha:1)
    static func text(_ value:String,_ rect:CGRect,size:CGFloat=12,color:NSColor = .labelColor,mono:Bool=false){
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        // NSString's drawing bridge can request a nil fallback font when a cell-less control
        // straddles an offscreen clip in SDK 27. Use the explicit CT font/color attributes on both paths.
        let font=CTFontCreateUIFontForLanguage(mono ? .userFixedPitch:.system,size,nil) ?? CTFontCreateWithName("Helvetica" as CFString,size,nil)
        let resolved=(color.usingColorSpace(.deviceRGB) ?? .white).cgColor
        let string=NSAttributedString(string:value,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):resolved])
        let line=CTLineCreateWithAttributedString(string)
        context.saveGState();context.clip(to:rect)
        let flipped=NSGraphicsContext.current?.isFlipped ?? true
        context.textMatrix=flipped ? CGAffineTransform(scaleX:1,y:-1):.identity
        context.textPosition=CGPoint(x:rect.minX,y:flipped ? rect.minY+ceil(CTFontGetAscent(font)):rect.maxY-ceil(CTFontGetAscent(font)))
        CTLineDraw(line,context);context.restoreGState()
    }
    static func label(_ text:String,size:CGFloat=12)->NativeLabel{let f=NativeLabel(labelWithString:text);f.font = .systemFont(ofSize:size);f.textColor = .labelColor;f.isBordered=false;f.isBezeled=false;f.drawsBackground=false;return f}
    static func pixel(_ value:CGFloat,_ scale:CGFloat)->CGFloat{(value*scale).rounded()/scale}
}

/// No cell, bezel, or system control text path. Menus are real NSMenu instances.
@MainActor final class DebugButton:NSControl {
    var title:String{didSet{needsDisplay=true}}
    var valueText:String?{didSet{needsDisplay=true}}
    var onPress:(()->Void)?
    var choices:[String]?;var selection=0
    var onSelect:((Int)->Void)?
    var isToggle=false
    var checked=false{didSet{needsDisplay=true}}
    private var hovering=false,pressed=false
    private var tracking:NSTrackingArea?
    init(_ title:String,action:(()->Void)?=nil){self.title=title;onPress=action;super.init(frame:.zero);cell=nil;setAccessibilityRole(.button);setAccessibilityLabel(title)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{isEnabled && !isHiddenOrHasHiddenAncestor}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)};let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self);tracking=area;addTrackingArea(area)}
    override func mouseEntered(with event:NSEvent){hovering=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent){hovering=false;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect){
        let scale=window?.backingScaleFactor ?? 2
        let rect=bounds.insetBy(dx:0.5/scale,dy:0.5/scale)
        NativeDisplayOptions.plate(alpha:pressed ? 0.16:hovering ? 0.10:0.055).setFill();NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6).fill()
        var text=isToggle ? (checked ? "☑  ":"☐  ")+title:title
        if let valueText{text += "   "+valueText};if choices != nil{text += "  ⌄"}
        DebugPaint.text(text,CGRect(x:9,y:(bounds.height-16)/2,width:max(1,bounds.width-18),height:18),color:isEnabled ? .labelColor:.tertiaryLabelColor)
        if window?.firstResponder === self{NSColor.keyboardFocusIndicatorColor.setStroke();let p=NSBezierPath(roundedRect:rect.insetBy(dx:1,dy:1),xRadius:5,yRadius:5);p.lineWidth=1;p.stroke()}
    }
    override func mouseDown(with event:NSEvent){guard isEnabled else{return};window?.makeFirstResponder(self);pressed=true;needsDisplay=true}
    override func mouseUp(with event:NSEvent){let fire=pressed && bounds.contains(convert(event.locationInWindow,from:nil));pressed=false;needsDisplay=true;if fire{_ = activate()}}
    @discardableResult func activate()->Bool {
        guard isEnabled,!isHiddenOrHasHiddenAncestor,NativeInteractionSurface.permits(self)else{return false}
        if let choices {
            guard window != nil else{return false};let m=NSMenu();m.autoenablesItems=false
            for (i,title) in choices.enumerated(){let item=NSMenuItem(title:title,action:#selector(chosen(_:)),keyEquivalent:"");item.target=self;item.tag=i;item.state=i == selection ? .on:.off;m.addItem(item)}
            m.popUp(positioning:m.item(at:selection),at:NSPoint(x:0,y:bounds.height),in:self);return true
        }
        guard let onPress else{return false};onPress();return true
    }
    @objc private func chosen(_ item:NSMenuItem){guard isEnabled,NativeInteractionSurface.permits(self)else{return};selection=item.tag;if let choices,choices.indices.contains(item.tag){valueText=choices[item.tag]};onSelect?(item.tag)}
    override func keyDown(with event:NSEvent){if [36,49,125].contains(event.keyCode){_ = activate()}else{super.keyDown(with:event)}}
    override func accessibilityPerformPress()->Bool{activate()}
    override func accessibilityValue()->Any?{isToggle ? (checked ? 1:0):valueText}
    override func isAccessibilityEnabled()->Bool{isEnabled}
}
@MainActor final class DebugSlider:NSControl {
    let name:String,range:ClosedRange<Double>
    private(set) var value:Double
    var onChange:((Double)->Void)?
    init(_ name:String,value:Double,range:ClosedRange<Double>){self.name=name;self.value=value;self.range=range;super.init(frame:.zero);cell=nil;setAccessibilityRole(.slider);setAccessibilityLabel(name)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{isEnabled}
    func set(_ next:Double,notify:Bool=false){guard next.isFinite else{return};value=min(range.upperBound,max(range.lowerBound,next));needsDisplay=true;if notify{onChange?(value)}}
    override func draw(_ dirtyRect:NSRect){
        DebugPaint.text(name,CGRect(x:0,y:0,width:bounds.width-72,height:17))
        DebugPaint.text(String(format:"%.3g",value),CGRect(x:bounds.width-70,y:0,width:70,height:17),color:.secondaryLabelColor,mono:true)
        let y:CGFloat=30;NativeDisplayOptions.plate(alpha:0.13).setFill();NSBezierPath(roundedRect:CGRect(x:3,y:y-2,width:max(1,bounds.width-6),height:4),xRadius:2,yRadius:2).fill()
        let x=3+CGFloat((value-range.lowerBound)/(range.upperBound-range.lowerBound))*max(1,bounds.width-6)
        NSColor.controlAccentColor.setFill();NSBezierPath(ovalIn:CGRect(x:x-5,y:y-5,width:10,height:10)).fill()
        if window?.firstResponder === self{NSColor.keyboardFocusIndicatorColor.setStroke();NSBezierPath(ovalIn:CGRect(x:x-7,y:y-7,width:14,height:14)).stroke()}
    }
    private func update(_ event:NSEvent){guard isEnabled else{return};let p=convert(event.locationInWindow,from:nil);set(range.lowerBound+Double((p.x-3)/max(1,bounds.width-6))*(range.upperBound-range.lowerBound),notify:true)}
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);update(event)}
    override func mouseDragged(with event:NSEvent){update(event)}
    override func keyDown(with event:NSEvent){guard isEnabled,NativeInteractionSurface.permits(self)else{return};switch event.keyCode{case 123,125:set(value-(range.upperBound-range.lowerBound)/100,notify:true);case 124,126:set(value+(range.upperBound-range.lowerBound)/100,notify:true);default:super.keyDown(with:event)}}
    override func accessibilityValue()->Any?{value}
    override func accessibilityMinValue()->Any?{range.lowerBound}
    override func accessibilityMaxValue()->Any?{range.upperBound}
    override func setAccessibilityValue(_ value:Any?){guard isEnabled,NativeInteractionSurface.permits(self),let v=value as? Double else{return};set(v,notify:true)}
    override func accessibilityPerformIncrement()->Bool{guard isEnabled,NativeInteractionSurface.permits(self)else{return false};set(value+(range.upperBound-range.lowerBound)/100,notify:true);return true}
    override func accessibilityPerformDecrement()->Bool{guard isEnabled,NativeInteractionSurface.permits(self)else{return false};set(value-(range.upperBound-range.lowerBound)/100,notify:true);return true}
}
@MainActor class DebugCanvas:NativeFlippedView {
    override init(frame:NSRect){super.init(frame:frame);appearance=NativeDisplayOptions.appearance;setAccessibilityRole(.group)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func draw(_ dirtyRect:NSRect){DebugPaint.background.setFill();bounds.fill()}
}
@MainActor final class DebugForm:DebugCanvas {
    private(set) var rows:[(NSView,CGFloat)]=[]
    @discardableResult func heading(_ text:String)->NativeLabel{let label=DebugPaint.label(text,size:13);label.font = .systemFont(ofSize:13,weight:.semibold);add(label,height:30);return label}
    func note(_ text:String,height:CGFloat=42){let label=DebugPaint.label(text,size:11);label.textColor = .secondaryLabelColor;label.lineBreakMode = .byWordWrapping;label.maximumNumberOfLines=0;add(label,height:height)}
    func add(_ view:NSView,height:CGFloat=30){rows.append((view,height));addSubview(view);needsLayout=true}
    @discardableResult func button(_ title:String,_ action:@escaping()->Void)->DebugButton{let b=DebugButton(title,action:action);add(b);return b}
    @discardableResult func toggle(_ title:String,value:Bool,_ action:@escaping()->Void)->DebugButton{let b=button(title,action);b.isToggle=true;b.checked=value;b.setAccessibilityRole(.checkBox);return b}
    @discardableResult func menu(_ title:String,choices:[String],selection:Int=0,_ change:@escaping(Int)->Void)->DebugButton{let b=DebugButton(title);b.choices=choices;b.selection=selection;b.valueText=choices.indices.contains(selection) ? choices[selection]:nil;b.onSelect=change;b.setAccessibilityRole(.popUpButton);add(b);return b}
    @discardableResult func slider(_ title:String,value:Double,range:ClosedRange<Double>,_ change:@escaping(Double)->Void)->DebugSlider{let s=DebugSlider(title,value:value,range:range);s.onChange=change;add(s,height:44);return s}
    func setHeight(_ view:NSView,_ height:CGFloat){guard let i=rows.firstIndex(where:{$0.0 === view})else{return};rows[i].1=height;needsLayout=true}
    var keyboardControls:[NSControl]{
        func collect(_ v:NSView)->[NSControl]{if let control=v as? NSControl,control is DebugButton || control is DebugSlider{return control.isEnabled && !control.isHiddenOrHasHiddenAncestor ? [control]:[]};return v.subviews.flatMap(collect)}
        return rows.flatMap{collect($0.0)}
    }
    override func layout(){super.layout();var y:CGFloat=14;let s=window?.backingScaleFactor ?? 2;for (v,h) in rows{v.frame=CGRect(x:14,y:DebugPaint.pixel(y,s),width:max(1,bounds.width-28),height:h);y+=h+7};let height=y+14;if frame.height != height{frame.size.height=height};let keys=keyboardControls;for (i,key) in keys.enumerated(){key.nextKeyView=keys[(i+1)%keys.count]}}
}
@MainActor protocol DebugPage:AnyObject {var root:NSView{get};func activate();func deactivate()}
@MainActor class DebugPageController:NSViewController,DebugPage {
    var root:NSView{view}
    var active=false
    override func loadView(){view=DebugCanvas()}
    func activate(){active=true;view.isHidden=false}
    func deactivate(){active=false;view.isHidden=true}
    func snapshot(scale:CGFloat)->CGImage{view.layoutSubtreeIfNeeded();return NativeViewBitmap.capture(view,scale:scale)}
}
@MainActor class DebugFormPage:DebugPageController {
    let form=DebugForm(),scroll=NSScrollView()
    override func loadView(){super.loadView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.documentView=form;view.addSubview(scroll)}
    override func viewDidLayout(){super.viewDidLayout();scroll.frame=view.safeAreaRect;form.frame.size.width=scroll.contentSize.width;form.needsLayout=true;form.layoutSubtreeIfNeeded()}
}

@MainActor final class DebugGrid:NativeFlippedView {
    var buttons:[DebugButton]=[]
    func append(_ button:DebugButton){buttons.append(button);addSubview(button);needsLayout=true}
    override func layout(){super.layout();let scale=window?.backingScaleFactor ?? 2;let w=DebugPaint.pixel((bounds.width-7)/2,scale);for (i,b) in buttons.enumerated(){b.frame=CGRect(x:CGFloat(i%2)*(w+7),y:CGFloat(i/2)*37,width:w,height:30)}}
}
