import AppKit

@MainActor enum SettingsDrawing {
    static func hex(_ value:String,alpha:CGFloat=1) -> NSColor {
        let clean=value.trimmingCharacters(in:CharacterSet(charactersIn:"#"))
        let n=UInt32(clean,radix:16) ?? 0x3478f6
        return NSColor(srgbRed:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:alpha)
    }
    static func palette(_ view:NSView)->SettingsPalette {
        var ancestor:NSView?=view
        while let current=ancestor {if let p=(current as? SettingsView)?.palette{return p};ancestor=current.superview}
        return .init()
    }
    static func align(_ r:CGRect,_ scale:CGFloat) -> CGRect {
        let s=max(1,scale),x=(r.minX*s).rounded()/s,y=(r.minY*s).rounded()/s
        return CGRect(x:x,y:y,width:(r.maxX*s).rounded()/s-x,height:(r.maxY*s).rounded()/s-y)
    }
    static func label(_ text:String="",size:CGFloat=13,weight:NSFont.Weight = .regular) -> SettingsLabel {
        let v=SettingsLabel(labelWithString:text);v.font = .systemFont(ofSize:size,weight:weight);v.lineBreakMode = .byTruncatingTail;v.setAccessibilityRole(.staticText);return v
    }
    static func text(_ string:String,in rect:CGRect,font:NSFont,color:NSColor,alignment:NSTextAlignment = .left) {
        let p=NSMutableParagraphStyle();p.alignment=alignment;p.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:p])
    }
}
@MainActor class SettingsView:NSView {
    var verificationScale:CGFloat?
    var palette:SettingsPalette?
    var fill:NSColor? {didSet{needsDisplay=true}}
    var scale:CGFloat {
        if let verificationScale{return verificationScale}
        // NSTableView can mount cells during cacheDisplay, after snapshot's scale traversal. Such cells
        // inherit the current render grid instead of silently reverting to 2× during a 1× capture.
        var parent=superview
        while let ancestor=parent{if let scale=(ancestor as? SettingsView)?.verificationScale{return scale};parent=ancestor.superview}
        return window?.backingScaleFactor ?? 2
    }
    override var isFlipped:Bool {true}
    override init(frame:NSRect) {super.init(frame:frame);autoresizesSubviews=false}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func draw(_ dirtyRect:NSRect){if let fill {fill.setFill();bounds.fill()}}
    func place(_ view:NSView,_ rect:CGRect){view.frame=SettingsDrawing.align(rect,scale)}
}
@MainActor final class SettingsLabel:NSTextField {
    var usesPalette=true
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect)}
}
@MainActor final class SettingsField:NSTextField,NSTextFieldDelegate {
    var edited:((String)->Void)?
    var drawsSearchPlaceholder=false
    override init(frame:NSRect) {
        super.init(frame:frame);isBordered=false;isBezeled=false;drawsBackground=false;focusRingType = .none
        font = .systemFont(ofSize:13);delegate=self;setAccessibilityRole(.textField)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func draw(_ dirtyRect:NSRect){
        // NSTextField's placeholder is brighter than the searchable-sidebar field. Keep the native editor,
        // selection and AX, and draw just its empty, unfocused hint through the same offscreen drawing path.
        if drawsSearchPlaceholder,stringValue.isEmpty,currentEditor() == nil,let placeholderString {
            SettingsDrawing.text(placeholderString,in:CGRect(x:2,y:0,width:max(1,bounds.width-4),height:bounds.height),font:font ?? .systemFont(ofSize:13),color:SettingsDrawing.palette(self).label.withAlphaComponent(127.0/255))
        }else{super.draw(dirtyRect)}
    }
    func controlTextDidChange(_ obj:Notification){edited?(stringValue)}
}
@MainActor final class SettingsEditor:NSTextView,NSTextViewDelegate {
    var edited:((String)->Void)?
    private let retainedStorage:NSTextStorage?
    override init(frame:NSRect,textContainer:NSTextContainer?) {
        let container:NSTextContainer
        if let textContainer {container=textContainer;retainedStorage=textContainer.layoutManager?.textStorage}
        else {
            let storage=NSTextStorage(),manager=NSLayoutManager(),created=NSTextContainer()
            storage.addLayoutManager(manager);manager.addTextContainer(created)
            retainedStorage=storage;container=created
        }
        super.init(frame:frame,textContainer:container)
        isRichText=false;isAutomaticQuoteSubstitutionEnabled=false;isAutomaticDashSubstitutionEnabled=false
        drawsBackground=false;isVerticallyResizable=true;isHorizontallyResizable=false
        font = .monospacedSystemFont(ofSize:12,weight:.regular);textContainerInset=NSSize(width:8,height:8)
        self.textContainer?.widthTracksTextView=true;delegate=self;setAccessibilityRole(.textArea)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect)}
    func textDidChange(_ notification:Notification){edited?(string)}
}
@MainActor class SettingsButton:NSButton {
    enum Style {case plain,toggle,popup,shortcut,tile,checkbox}
    var style=Style.plain,run:(()->Void)?,toggled:Bool?,destructive=false
    var symbolName="",chromeless=false,prominent=false
    var swatch:NSColor?
    var swatchFromTheme=false
    var filledIcon=false,compactDestructive=false
    var formBodyButton=false,usesSmallIconLabel=false
    static func ink(_ base:NSColor,opacity:CGFloat)->NSColor{base.withAlphaComponent(base.alphaComponent*opacity)}
    var recordingShortcut=false{didSet{if recordingShortcut != oldValue{syncRecording()};needsDisplay=true}}
    private var heldRecordingAnimation: CAAnimation?
    private lazy var animationVisibility = OrbAnimationVisibilityObservation(view:self) { [weak self] in self?.syncRecording() }
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if recordingShortcut { animationVisibility.rebind() };syncRecording()}
    override func viewDidMoveToSuperview(){super.viewDidMoveToSuperview();if recordingShortcut { animationVisibility.rebind() };syncRecording()}
    private func syncRecording(){
        let enabled = recordingShortcut && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if enabled { if !animationVisibility.isObserving { animationVisibility.rebind() } } else { animationVisibility.stop(); heldRecordingAnimation = nil }
        guard enabled, window != nil else { layer?.removeAnimation(forKey:"shortcut.recording"); return }
        if layer == nil { wantsLayer = true; animationVisibility.rebind() }
        guard let layer else { return }
        guard OrbAnimationVisibility.state(layer:layer, view:self).isVisible else {
            layer.removeAnimation(forKey:"shortcut.recording"); return
        }
        guard layer.animation(forKey:"shortcut.recording") == nil else { return }
        if let heldRecordingAnimation { layer.add(heldRecordingAnimation,forKey:"shortcut.recording"); return }
        let animation=CABasicAnimation(keyPath:"opacity");animation.fromValue=1;animation.toValue=0.55;animation.duration=0.7;animation.autoreverses=true;animation.repeatCount = .infinity;animation.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        animation.beginTime = layer.convertTime(CACurrentMediaTime(),from:nil)
        heldRecordingAnimation = animation
        layer.add(animation,forKey:"shortcut.recording")
    }
    var switchTrackRect:CGRect{CGRect(x:0,y:(bounds.height-15)/2,width:36,height:15)}
    var switchKnobRect:CGRect{let r=switchTrackRect;return CGRect(x:toggled == true ? 13.5:1.5,y:r.minY+1.5,width:21,height:13)}
    var hover=false
    private var hoverArea:NSTrackingArea?
    override init(frame:NSRect) {
        super.init(frame:frame);isBordered=false;focusRingType = .none;target=self;action=#selector(fire)
        font = .systemFont(ofSize:13);setAccessibilityRole(.button)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let hoverArea{removeTrackingArea(hoverArea)}
        let area=NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseEnteredAndExited,.inVisibleRect],owner:self)
        addTrackingArea(area);hoverArea=area
    }
    override func mouseEntered(with event:NSEvent){hover=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent){hover=false;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        if chromeless {if !symbolName.isEmpty{SettingsArt.symbol(symbolName,in:CGRect(x:bounds.midX-7,y:bounds.midY-7,width:14,height:14),size:13,color:.labelColor.withAlphaComponent(isEnabled ? 0.8:0.25))}else if !title.isEmpty{SettingsDrawing.text(title,in:CGRect(x:0,y:2,width:bounds.width,height:max(1,bounds.height-8)),font:.systemFont(ofSize:11),color:.labelColor,alignment:.right)};return}
        if recordingShortcut{NSColor.controlAccentColor.setStroke();let p=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6);p.lineWidth=1.5;p.stroke();SettingsDrawing.text(title,in:bounds.insetBy(dx:8,dy:3),font:.systemFont(ofSize:12),color:.labelColor,alignment:.center);return}
        let highlighted=cell?.isHighlighted == true
        let opacity:CGFloat=isEnabled ? 1:style == .popup ? 0.45:0.4
        if style == .checkbox {
            let r=CGRect(x:(bounds.width-14)/2,y:(bounds.height-14)/2,width:14,height:14)
            SettingsArt.plate(r,radius:4,color:toggled == true ? SettingsDrawing.palette(self).accent:.white.withAlphaComponent(0.12))
            if toggled == true{SettingsArt.symbol("checkmark",in:r.insetBy(dx:2,dy:2),size:11,color:.white)};return
        }
        if style == .toggle {
            let p=SettingsDrawing.palette(self),r=switchTrackRect
            let neutral=p.canvas.blended(withFraction:0.16,of:.white) ?? NSColor(white:0.26,alpha:1)
            SettingsArt.plate(r,radius:7.5,color:(toggled == true && window?.isKeyWindow == true ? p.accent:neutral).withAlphaComponent(opacity))
            SettingsArt.plate(switchKnobRect,radius:6.5,color:.white);return
        }
        let r=style == .popup || style == .shortcut || formBodyButton || swatch != nil ? bounds:bounds.insetBy(dx:0.5,dy:usesSmallIconLabel ? 1:0.5),radius:CGFloat=style == .popup || swatch != nil ? 7:6
        let alpha:CGFloat=style == .popup || style == .shortcut || swatch != nil ? 0.10:highlighted ? 0.32:hover ? 0.32:0.27
        let primary=SettingsDrawing.palette(self).label
        let fill=style == .popup || style == .shortcut || swatch != nil ? Self.ink(primary,opacity:alpha*opacity):primary.withAlphaComponent(alpha*opacity)
        if (!title.isEmpty && !(style == .shortcut && title == "Unassigned")) || filledIcon {SettingsArt.plate(r,radius:radius,color:prominent ? SettingsDrawing.palette(self).accent.withAlphaComponent(opacity):compactDestructive ? NSColor.systemRed.withAlphaComponent(0.22*opacity):fill)}
        if window?.firstResponder === self {NSColor.keyboardFocusIndicatorColor.setStroke();let p=NSBezierPath(roundedRect:r.insetBy(dx:1,dy:1),xRadius:radius,yRadius:radius);p.lineWidth=2;p.stroke()}
        let baseColor:NSColor=style == .shortcut && title == "Unassigned" ? .tertiaryLabelColor:prominent ? .white:destructive ? .systemRed:swatchFromTheme ? SettingsDrawing.palette(self).secondary:SettingsDrawing.palette(self).label
        // withAlphaComponent(1) discarded the system label's intrinsic opacity, making every button word
        // white (255) instead of the product's 224/231. Disabled opacity multiplies the semantic ink.
        let color=Self.ink(baseColor,opacity:opacity)
        if !symbolName.isEmpty{SettingsArt.symbol(symbolName,in:CGRect(x:title.isEmpty ? (bounds.width-14)/2:usesSmallIconLabel && style == .plain ? 12:8,y:(bounds.height-14)/2,width:14,height:14),size:style == .popup || (font?.pointSize ?? 13)<=11 ? 11:12,color:style == .popup ? SettingsDrawing.palette(self).secondary:color)}
        if let swatch{SettingsArt.plate(CGRect(x:7,y:(bounds.height-14)/2,width:14,height:14),radius:7,color:swatch)}
        let left:CGFloat=swatch != nil ? 27:style == .shortcut ? 7:symbolName.isEmpty ? 8:usesSmallIconLabel ? (style == .popup ? 23.5:36):26
        SettingsDrawing.text(title,in:CGRect(x:left,y:(bounds.height-16)/2-(style == .shortcut || swatch != nil ? 1:style == .popup && !prominent ? 0.5:0)+(usesSmallIconLabel && style == .plain ? 1:0),width:max(0,bounds.width-left-(style == .popup ? 19:style == .shortcut || swatch != nil ? 7:8)),height:18),font:font ?? .systemFont(ofSize:13),color:color,alignment:style == .popup || usesSmallIconLabel ? .left:.center)
        if style == .popup {SettingsArt.symbol(prominent ? "chevron.down":"chevron.up.chevron.down",in:CGRect(x:bounds.width-(prominent ? 16:14),y:(bounds.height-10)/2,width:prominent ? 10:8,height:10),size:8,color:prominent ? .white.withAlphaComponent(0.85):.secondaryLabelColor,weight:.bold)}
    }
    override func accessibilityValue() -> Any? {if style == .shortcut{return title};return style == .toggle ? (toggled.map{$0 ? 1:0} ?? 2):super.accessibilityValue()}
    @objc private func fire(){guard isEnabled else{return};run?();needsDisplay=true}
}
@MainActor class SettingsChoice:SettingsButton {
    var choices:[(String,String)]=[],selected=""
    var choose:((String)->Void)?
    var menuActions:[SettingsRow]=[]
    override init(frame:NSRect){super.init(frame:frame);style = .popup;run={ [weak self] in self?.showMenu() };setAccessibilityRole(.popUpButton)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    func buildMenu() -> NSMenu {
        let menu=NSMenu()
        if !menuActions.isEmpty {
            for (index,row) in menuActions.enumerated(){
                if row.kind == .choice {menu.addItem(.sectionHeader(title:row.title))
                    for (value,title) in row.choices{let item=NSMenuItem(title:title,action:#selector(pickEmbedded(_:)),keyEquivalent:"");item.target=self;item.isEnabled=row.enabled;item.state=row.value.settingsText == value ? .on:.off;item.representedObject=["index":index,"value":value] as [String:Any];menu.addItem(item)}
                }else {let item=NSMenuItem(title:row.title,action:#selector(pickEmbedded(_:)),keyEquivalent:"");item.target=self;item.isEnabled=row.enabled;item.state=row.value.boolValue == true ? .on:.off;item.representedObject=["index":index] as [String:Any];menu.addItem(item)}
            };return menu
        }
        for (value,name) in choices {
            let item=NSMenuItem(title:name,action:#selector(pick(_:)),keyEquivalent:"");item.target=self;item.representedObject=value;item.state=value == selected ? .on:.off;menu.addItem(item)
        }
        return menu
    }
    private func showMenu(){let menu=buildMenu();menu.popUp(positioning:menu.items.first{$0.state == .on},at:NSPoint(x:0,y:bounds.height),in:self)}
    @objc private func pickEmbedded(_ item:NSMenuItem){
        guard isEnabled,let payload=item.representedObject as? [String:Any],let i=payload["index"] as? Int,menuActions.indices.contains(i),menuActions[i].enabled else{return}
        let r=menuActions[i];r.perform?((payload["value"] as? String).map(JSONValue.string) ?? .bool(!(r.value.boolValue ?? false)))
    }
    @objc private func pick(_ item:NSMenuItem){guard let value=item.representedObject as? String else{return};choose?(value)}
}
@MainActor final class SettingsGraphic:SettingsView {
    var spec:SettingsRow {didSet{needsDisplay=true}}
    init(_ spec:SettingsRow){self.spec=spec;super.init(frame:.zero);setAccessibilityRole(.image);setAccessibilityLabel(spec.title+". "+spec.detail)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func draw(_ dirtyRect:NSRect){
        super.draw(dirtyRect)
        if spec.kind == .progress {
            let r=CGRect(x:0,y:2,width:bounds.width,height:6)
            NSColor.labelColor.withAlphaComponent(0.08).setFill();NSBezierPath(roundedRect:r,xRadius:3,yRadius:3).fill()
            SettingsDrawing.palette(self).accent.setFill();NSBezierPath(roundedRect:CGRect(x:0,y:2,width:r.width*max(0,min(1,spec.value.doubleValue ?? 0)),height:6),xRadius:3,yRadius:3).fill()
        } else if spec.kind == .code {
            let theme=SettingsThemes.theme(spec.value["theme"]?.settingsText ?? "canopy"),fontID=spec.value["font"]?.settingsText ?? "sf"
            SettingsDrawing.hex(theme.bg).blended(withFraction:0.18,of:.black)?.setFill();NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill()
            let font=NSFont(name:["sf":"SFMono-Regular","menlo":"Menlo","monaco":"Monaco","courier":"Courier New"][fontID] ?? "Menlo",size:spec.value["size"]?.doubleValue ?? 12) ?? .monospacedSystemFont(ofSize:12,weight:.regular)
            let sample="// A little context goes a long way.\nstruct Message: Sendable {\n    let title: String\n    func greet() -> String {\n        return \"Hello, world\"\n    }\n}"
            let text=NSMutableAttributedString(string:sample,attributes:[.font:font,.foregroundColor:SettingsDrawing.hex(theme.fg)])
            for (pattern,color) in [("//[^\\n]*",theme.comment),("\\b(struct|let|func|return)\\b",theme.keyword),("\\b(Message|Sendable|String)\\b",theme.type),("\"[^\"]*\"",theme.string),("\\bgreet\\b",theme.function)] {
                let regex=try? NSRegularExpression(pattern:pattern)
                for match in regex?.matches(in:sample,range:NSRange(location:0,length:(sample as NSString).length)) ?? [] {text.addAttribute(.foregroundColor,value:SettingsDrawing.hex(color),range:match.range)}
            }
            text.draw(in:bounds.insetBy(dx:14,dy:12))
        } else {
            let numbers=spec.value.arrayValue?.compactMap(\.doubleValue) ?? [],maxN=max(1,numbers.max() ?? 1)
            if numbers.count>100 {
                let gap:CGFloat=2,w=max(2,(bounds.width-51*gap)/52)
                for (i,n) in numbers.enumerated() where n>=0{SettingsDrawing.hex("#57c27a",alpha:0.08+0.85*n/maxN).setFill();NSBezierPath(roundedRect:CGRect(x:CGFloat(i/7)*(w+gap),y:CGFloat(i%7)*12,width:w,height:10),xRadius:2,yRadius:2).fill()}
            } else {
                let gap:CGFloat=6,w=max(1,(bounds.width-CGFloat(max(0,numbers.count-1))*gap)/CGFloat(max(1,numbers.count)))
                for (i,n) in numbers.enumerated(){NSColor.controlAccentColor.withAlphaComponent(0.7).setFill();let h=(bounds.height-12)*n/maxN;NSBezierPath(roundedRect:CGRect(x:CGFloat(i)*(w+gap),y:bounds.height-h,width:w,height:h),xRadius:3,yRadius:3).fill()}
            }
        }
    }
}
@MainActor final class SettingsThemeTile:SettingsButton {
    override var isFlipped:Bool{true}
    let theme:SettingsTheme
    var selected=false
    init(_ theme:SettingsTheme){self.theme=theme;super.init(frame:.zero);style = .tile;setButtonType(.radio);title=theme.name;setAccessibilityLabel(theme.name);setAccessibilityRole(.radioButton)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func draw(_ dirtyRect:NSRect){
        let plate=CGRect(x:2,y:0,width:74,height:50),fg=SettingsDrawing.hex(theme.fg)
        SettingsArt.plate(plate,radius:7,color:SettingsDrawing.hex(theme.bg))
        SettingsArt.plate(CGRect(x:6,y:4,width:18,height:42),radius:2,color:fg.withAlphaComponent(0.08))
        for (i,t) in [(18.0,theme.keyword),(30,theme.type),(24,theme.string),(14,theme.comment)].enumerated(){SettingsArt.plate(CGRect(x:29,y:8+CGFloat(i)*7,width:t.0,height:3),radius:1.5,color:SettingsDrawing.hex(t.1))}
        SettingsArt.plate(CGRect(x:28,y:37,width:40,height:9),radius:4.5,color:fg.withAlphaComponent(0.1));SettingsArt.plate(CGRect(x:59,y:38,width:7,height:7),radius:3.5,color:SettingsDrawing.hex(theme.accent))
        (selected ? SettingsDrawing.palette(self).accent:fg.withAlphaComponent(0.12)).setStroke();let line:CGFloat=selected ? 2.5:1,path=NSBezierPath(roundedRect:plate.insetBy(dx:line/2,dy:line/2),xRadius:7,yRadius:7);path.lineWidth=line;path.stroke()
        SettingsDrawing.text(theme.name,in:CGRect(x:0,y:55,width:bounds.width,height:16),font:.systemFont(ofSize:11,weight:selected ? .semibold:.regular),color:selected ? .labelColor:.secondaryLabelColor,alignment:.center)
    }
    override func becomeFirstResponder()->Bool{let accepted=super.becomeFirstResponder();if accepted,let viewport=superview?.superview as? SettingsThemeViewport{viewport.reveal(frame)};return accepted}
    override func accessibilityValue() -> Any? {selected ? 1:0}
}

@MainActor final class SettingsDatePicker:NSDatePicker {
    var changed:((Date)->Void)?
    override init(frame:NSRect){
        super.init(frame:frame);datePickerStyle = .textFieldAndStepper;datePickerElements=[.yearMonthDay,.hourMinute]
        isBordered=false;isBezeled=false;drawsBackground=false;font = .systemFont(ofSize:12);target=self;action=#selector(picked)
        setAccessibilityLabel("First run")
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect)}
    @objc private func picked(){changed?(dateValue)}
}
