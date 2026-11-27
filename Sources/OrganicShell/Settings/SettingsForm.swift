import AppKit

@MainActor final class SettingsFormRow:SettingsView {
    private(set) var spec:SettingsRow
    let titleLabel=SettingsDrawing.label(),detailLabel=SettingsDrawing.label(size:11)
    var control:NSView?
    var themes:[SettingsThemeTile]=[]
    private(set) var actionControls:[NSView]=[]
    private var themeScroll:SettingsThemeViewport?,themeCanvas:SettingsView?
    private var themeScrollSelection:String?,themeWasExpanded=false
    init(_ spec:SettingsRow){
        self.spec=spec;super.init(frame:.zero);addSubview(titleLabel);addSubview(detailLabel)
        titleLabel.maximumNumberOfLines=1;detailLabel.maximumNumberOfLines=3;detailLabel.cell?.wraps=true
        control=makeControl(spec)
        if let control{addSubview(control)}
        if spec.kind == .themes {
            let colors=SettingsThemes.all
            var all=colors
            if spec.id == "look.code" {let t=SettingsThemes.theme(spec.visual.cardArt.isEmpty ? "canopy":spec.visual.cardArt);all.insert(SettingsThemes.t("match","Same as Window",true,t.bg,t.fg,t.accent,t.keyword,t.type,t.string,t.comment,t.function),at:0)}
            let scroll=SettingsThemeViewport(),canvas=SettingsView();scroll.canvas=canvas;scroll.addSubview(canvas)
            addSubview(scroll);themeScroll=scroll;themeCanvas=canvas
            for theme in all {let tile=SettingsThemeTile(theme);tile.run={ [weak self] in self?.spec.perform?(.string(theme.id)) };canvas.addSubview(tile);themes.append(tile)}
        }
        update(spec)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    var rowActionAvailable:Bool{spec.enabled && control == nil && spec.perform != nil && (spec.visual.chevron || spec.visual.cardArt == "live.plugin")}
    override var acceptsFirstResponder:Bool{rowActionAvailable}
    override func mouseDown(with event:NSEvent){if rowActionAvailable{spec.perform?(.null)}else{super.mouseDown(with:event)}}
    override func keyDown(with event:NSEvent){if rowActionAvailable,[36,49].contains(event.keyCode){spec.perform?(.null)}else{super.keyDown(with:event)}}
    override func accessibilityRole()->NSAccessibility.Role?{rowActionAvailable ? .button:.group}
    override func accessibilityLabel()->String?{spec.title}
    override func accessibilityPerformPress()->Bool{guard rowActionAvailable else{return false};spec.perform?(.null);return true}

    private func makeControl(_ r:SettingsRow)->NSView?{
        switch r.visual.style {
        case .profile,.statistics,.activity,.pluginTiles,.storage,.usageChart,.meter,.empty:return SettingsFigure(r)
        case .counter:let counter=SettingsCounter();counter.changed={ [weak self] v in self?.spec.perform?(.string(String(v))) };return counter
        case .slider:let slider=SettingsTextSlider();slider.changed={ [weak self] v in self?.spec.perform?(.string(String(v))) };return slider
        case .accent:let accent=SettingsAccentChoices();accent.choose={ [weak self] value in self?.spec.perform?(.string(value)) };return accent
        case .segmented:let c=SettingsSegments();c.choose={ [weak self] v in self?.spec.perform?(.string(v)) };return c
        default:break
        }
        switch r.kind {
        case .button,.toggle,.shortcut:
            let b=SettingsButton();b.style=r.kind == .toggle ? (r.visual.cardArt == "checkbox" ? .checkbox:.toggle):r.kind == .shortcut ? .shortcut:.plain
            if r.kind == .toggle{b.setButtonType(.switch);b.setAccessibilityRole(.checkBox)}
            b.run={ [weak self] in guard let self else{return};self.spec.perform?(self.spec.kind == .toggle ? .bool(!(self.spec.value.boolValue ?? false)):.null) };return b
        case .choice:
            let c:SettingsChoice=r.visual.style == .cards ? SettingsCardChoices():SettingsChoice()
            c.choose={ [weak self] v in self?.spec.perform?(.string(v)) };return c
        case .date:let d=SettingsDatePicker();d.changed={ [weak self] v in self?.spec.perform?(.number(v.timeIntervalSince1970)) };return d
        case .field:
            let f=SettingsField();f.edited={ [weak self] v in self?.spec.perform?(.string(v)) };return f
        case .editor:
            let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.borderType = .noBorder
            let editor=SettingsEditor(frame:.zero,textContainer:nil);editor.edited={ [weak self] v in self?.spec.perform?(.string(v)) };scroll.documentView=editor;return scroll
        case .progress,.chart,.code:
            if r.visual.style == .meter {return SettingsFigure(r)}
            return r.id == "appshots.preview" ? SettingsAppshotPreview():SettingsGraphic(r)
        case .daybreak:return SettingsDaybreakCard()
        default:return nil
        }
    }
    func update(_ next:SettingsRow){
        precondition(next.kind == spec.kind);spec=next
        let header=spec.kind == .heading || spec.visual.style == .header
        titleLabel.stringValue=spec.title;titleLabel.font = spec.visual.cardArt == "site" ? .monospacedSystemFont(ofSize:13,weight:.regular):.systemFont(ofSize:13,weight:header ? .semibold:.regular)
        detailLabel.stringValue=spec.detail;titleLabel.textColor = .labelColor;detailLabel.textColor = .secondaryLabelColor
        if let c=control as? SettingsChoice {c.choices=spec.choices;c.menuActions=spec.visual.menuActions;c.selected=spec.value.settingsText;c.title=spec.visual.rightText.isEmpty ? (spec.choices.first{$0.0 == c.selected}?.1 ?? (c.selected.isEmpty ? "Not reported":c.selected)):spec.visual.rightText;c.isEnabled=spec.enabled;if spec.id == "device"{c.symbolName=spec.visual.symbol}
            c.prominent=spec.visual.cardArt == "prominent"
            if let cards=c as? SettingsCardChoices {cards.art=spec.visual.cardArt;cards.title=spec.title;cards.syncCards()}}
        else if let b=control as? SettingsButton {
            b.isEnabled=spec.enabled;b.destructive=spec.destructive;b.toggled=spec.value.boolValue;b.prominent=spec.visual.cardArt == "prominent";b.symbolName=spec.visual.symbol
            b.compactDestructive=spec.visual.footer && spec.destructive
            b.formBodyButton=spec.kind == .button && spec.visual.group.hasPrefix("m9.") && !spec.visual.footer && !spec.visual.chevron && spec.visual.cardArt != "color"
            if spec.visual.footer{b.font = .systemFont(ofSize:11)}
            b.recordingShortcut=spec.kind == .shortcut && spec.visual.cardArt == "recording"
            if spec.kind == .shortcut{let base=NSFont.systemFont(ofSize:12,weight:.medium);b.font=NSFont(descriptor:base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,size:12)}
            b.title=spec.kind == .shortcut ? (b.recordingShortcut ? "Type Shortcut…":spec.value.settingsText.isEmpty ? "Unassigned":spec.value.settingsText):spec.visual.buttonTitle ?? (spec.kind == .button ? (spec.id.hasPrefix("go.") ? "Manage…":spec.title):"")
            b.swatch=spec.visual.cardArt == "color" ? SettingsDrawing.hex(b.title):nil;b.swatchFromTheme=b.swatch != nil && spec.value.settingsText.isEmpty;if b.swatch != nil{b.font = .monospacedSystemFont(ofSize:12,weight:.regular)}
            b.setAccessibilityLabel(spec.title.isEmpty ? b.title:spec.title);b.setAccessibilityHelp(spec.detail);b.needsDisplay=true
        }
        if let segments=control as? SettingsSegments{segments.configure(choices:spec.choices,value:spec.value.settingsText);segments.isEnabled=spec.enabled}
        if let counter=control as? SettingsCounter{counter.integerValue=Int(spec.value.settingsText) ?? spec.value.intValue ?? 5;counter.isEnabled=spec.enabled}
        if let slider=control as? SettingsTextSlider {slider.doubleValue=spec.value.doubleValue ?? Double(spec.value.settingsText) ?? 1;slider.isEnabled=spec.enabled}
        if let accent=control as? SettingsAccentChoices {accent.selected=spec.value.settingsText;accent.custom=spec.visual.menuActions.first?.detail ?? "";accent.openCustom={ [weak self] in self?.spec.visual.menuActions.first?.perform?(.null) };accent.needsLayout=true}
        if let f=control as? SettingsField {if f.currentEditor() == nil,f.stringValue != spec.value.settingsText {f.stringValue=spec.value.settingsText};f.isEnabled=spec.enabled;f.isEditable = !spec.visual.readOnly;f.font=spec.visual.readOnly || spec.visual.style == .rule ? .monospacedSystemFont(ofSize:12,weight:.regular):.systemFont(ofSize:13);f.setAccessibilityLabel(spec.title);f.placeholderString=spec.visual.placeholder.isEmpty ? spec.title:spec.visual.placeholder}
        if let scroll=control as? NSScrollView,let editor=scroll.documentView as? SettingsEditor{if !editor.hasMarkedText(),window?.firstResponder !== editor,editor.string != spec.value.settingsText{editor.string=spec.value.settingsText};editor.isEditable=spec.enabled;editor.setAccessibilityLabel(spec.title)}
        if let d=control as? SettingsDatePicker{d.dateValue=Date(timeIntervalSince1970:spec.value.doubleValue ?? Date().timeIntervalSince1970);d.isEnabled=spec.enabled;d.setAccessibilityLabel(spec.title)}
        if let graphic=control as? SettingsGraphic{graphic.spec=spec}
        if let figure=control as? SettingsFigure{figure.spec=spec;figure.needsDisplay=true}
        if let preview=control as? SettingsAppshotPreview{preview.reduceMotion=spec.value.boolValue ?? false}
        if let daybreak=control as? SettingsDaybreakCard{daybreak.email=spec.value.settingsText}
        for t in themes{t.selected=t.theme.id == spec.value.settingsText;t.needsDisplay=true}
        syncActions();needsLayout=true;needsDisplay=true
    }
    private func syncActions(){
        // Keep controls while their semantic action/type remains the same, preserving focused inputs.
        if actionControls.count != spec.visual.actions.count {actionControls.forEach{$0.removeFromSuperview()};actionControls=spec.visual.actions.enumerated().map{index,r in
            let v:NSView
            if r.visual.style == .segmented || r.id.hasSuffix("profileRange"){let c=SettingsSegments();c.choose={ [weak self] value in self?.spec.visual.actions[index].perform?(.string(value)) };v=c}
            else if r.kind == .choice{let c=SettingsChoice();c.choose={ [weak self] value in self?.spec.visual.actions[index].perform?(.string(value)) };v=c}
            else if r.kind == .field{let f=SettingsField();f.edited={ [weak self] value in self?.spec.visual.actions[index].perform?(.string(value)) };v=f}
            else{let b=SettingsButton();b.style=r.kind == .toggle ? (r.visual.cardArt == "checkbox" ? .checkbox:.toggle):.plain;b.run={ [weak self] in guard let self,self.spec.visual.actions.indices.contains(index)else{return};let r=self.spec.visual.actions[index];r.perform?(r.kind == .toggle ? .bool(!(r.value.boolValue ?? false)):.null) };v=b}
            addSubview(v);return v}}
        for (i,c) in actionControls.enumerated(){let r=spec.visual.actions[i]
            if let button=c as? SettingsButton{button.usesSmallIconLabel=spec.visual.style == .profile}
            if let c=c as? SettingsSegments{c.configure(choices:r.choices,value:r.value.settingsText)}
            else if let c=c as? SettingsChoice{c.choices=r.choices;c.selected=r.value.settingsText;c.title=r.choices.first{$0.0 == c.selected}?.1 ?? r.title;c.isEnabled=r.enabled;c.prominent=r.visual.cardArt == "prominent";c.symbolName=r.visual.symbol}
            else if let b=c as? SettingsButton{b.formBodyButton=r.kind == .button && !r.title.isEmpty && spec.visual.group.hasPrefix("m9.") && spec.visual.style != .header && spec.visual.style != .profile && !spec.visual.footer;b.title=r.visual.buttonTitle ?? r.title;b.font = .systemFont(ofSize:spec.visual.style == .header || spec.visual.style == .profile ? 11:13);b.chromeless=r.title.hasPrefix("Show All") || r.title == "Show Less";b.destructive=r.destructive;b.isEnabled=r.enabled;b.toggled=r.value.boolValue;b.symbolName=r.visual.symbol;b.filledIcon=r.visual.cardArt == "iconPlate";if r.visual.cardArt == "searchRecord"{b.chromeless=true};b.setAccessibilityLabel(r.title);b.needsDisplay=true}
            else if let f=c as? SettingsField{if f.currentEditor() == nil {f.stringValue=r.value.settingsText};f.placeholderString=r.title}
        }
    }
    func height(_ width:CGFloat)->CGFloat{
        if spec.visual.style == .themeStrip,spec.visual.showsAll{let columns=max(1,Int((width-14)/88)),rows=(themes.count+columns-1)/columns;return CGFloat(rows)*68+CGFloat(max(0,rows-1))*10+28}
        if let h=spec.visual.height{return h}
        if spec.visual.style == .footer{let r=(spec.detail as NSString).boundingRect(with:CGSize(width:width-20,height:1000),options:.usesLineFragmentOrigin,attributes:[.font:NSFont.systemFont(ofSize:11)]);return ceil(r.height)+2}
        if spec.visual.style == .header || spec.kind == .heading{return 26}
        // The grouped Form reserves a separate 1 pt between rows (below), not inside these intrinsic heights.
        // Keep fractional points until placing frames: rounding every row first accumulates at 2× and 1×.
        switch spec.kind{case .editor:return 238;case .themes:return 97;case .code:return 204;case .chart:return 158;case .progress:return 64;case .daybreak:return 150;default:break}
        if !spec.visual.group.hasPrefix("m9."){return spec.detail.isEmpty ? 41:52}
        if !spec.detail.isEmpty{return 52}
        switch spec.kind{case .choice:return 41.25;case .toggle:return 36.5;case .shortcut:return 39.5;case .button:return 40;default:return 36}
    }
    private func controlWidth(_ c:NSView)->CGFloat{
        if let cards=c as? SettingsCardChoices{return CGFloat(cards.choices.count)*80-10}
        if c is SettingsCounter{return 132}
        if c is SettingsTextSlider{return 194.5}
        if c is SettingsAccentChoices{return 233}
        if c is SettingsSegments{return spec.id == "demo.global.connectionsTab" ? 330:max(140,CGFloat(spec.choices.count)*80)}
        if let b=c as? SettingsButton {
            if b.style == .toggle{return 36}
            if b.title.isEmpty && !b.symbolName.isEmpty{return b.filledIcon ? 32:22}
            let text=(b.title as NSString).size(withAttributes:[.font:b.font ?? NSFont.systemFont(ofSize:13)]).width
            if b.style == .shortcut{return ceil(max(26,text+(b.recordingShortcut ? 16:14)))}
            let small=spec.visual.style == .header || spec.visual.style == .profile
            let insets:CGFloat
            if b.swatch != nil{insets=34}
            else if b.style == .popup{insets=b.symbolName.isEmpty ? (b.prominent ? 29:27):spec.visual.style == .profile ? 42.5:45} // 8 + 5 + 8 + 6; optional leading symbol
            else{insets=b.symbolName.isEmpty ? (small ? 20.5:24.5):(spec.visual.style == .profile ? 47:small ? 38:42)}
            return max(45,min(bounds.width*0.58,text+insets))
        }
        if c is SettingsField{if spec.id == "draft.account.name"{return 200};return spec.id.hasPrefix("sheet.") ? max(80,bounds.width-110):min(270,bounds.width*0.49)}
        return 180
    }
    override func layout(){
        super.layout();let w=bounds.width,h=bounds.height,style=spec.visual.style
        titleLabel.isHidden=false;detailLabel.isHidden=spec.detail.isEmpty
        let figure=[SettingsRowVisual.Style.profile,.statistics,.activity,.pluginTiles,.storage,.usageChart,.meter,.illustration,.empty].contains(style)
        if spec.kind == .daybreak {titleLabel.isHidden=true;detailLabel.isHidden=true;if let control{place(control,spec.visual.height == 170 ? bounds.insetBy(dx:10,dy:10):bounds)};return}
        if figure {
            titleLabel.isHidden=true;detailLabel.isHidden=true
            if let control{place(control,style == .empty ? bounds:bounds.insetBy(dx:10,dy:10))}
        } else if style == .header || spec.kind == .heading {let actions=spec.visual.actions,showThemes=actions.allSatisfy{$0.id == "m9.themes.all" || $0.id == "m9.code.all"}
            let titleY:CGFloat=actions.isEmpty && h == 26 ? 0:actions.isEmpty || showThemes ? -2:actions.count>1 ? (h>29 ? -1:-0.5):-1
            place(titleLabel,CGRect(x:8,y:titleY,width:w-18,height:18));detailLabel.isHidden=spec.detail.isEmpty
            if !spec.detail.isEmpty{let tw=(spec.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold)]).width;place(detailLabel,CGRect(x:16.25+tw,y:0,width:max(1,w-tw-28.5),height:16))}}
        else if style == .footer {titleLabel.isHidden=true;detailLabel.font = .systemFont(ofSize:11);detailLabel.textColor=spec.tint ?? .secondaryLabelColor;detailLabel.maximumNumberOfLines=0;place(detailLabel,CGRect(x:8,y:2,width:w-16,height:max(1,h-2)))}
        else {
            var leading:CGFloat=8
            if !spec.visual.symbol.isEmpty{leading += spec.visual.tile.isEmpty ? 32:spec.visual.tileSize+10}
            let cw=control.map(controlWidth) ?? 0,aux=actionControls.reduce(CGFloat(0)){$0+controlWidth($1)+(spec.kind == .shortcut ? 2:4)},right=max(0,cw+aux+(spec.visual.rightText.isEmpty ? 0:rightTextWidth)+(spec.visual.chevron ? 14:0))
            let labelWidth=max(1,w-leading-20-right)
            // LabeledContent aligns Accent color to the first baseline of its two-line trailing VStack.
            // Its label moves up 7.5pt, while the 16pt swatches move down 3pt; the row/group heights stay intact.
            // SwiftUI centres a plain Label around its tile. RowLabel's title/detail VStack instead aligns
            // its first baseline. Likewise a NavigationRow and the taller illustrated choices have their
            // own intrinsic text centre; these corrections move ink only, never the group's row heights.
            let plainTile=spec.detail.isEmpty && !spec.visual.tile.isEmpty && spec.visual.tileSize == 26
            let tileOffset:CGFloat=plainTile ? (spec.kind == .toggle ? 0.5:spec.kind == .choice ? 2.5:2):0
            let textOffset:CGFloat=tileOffset+(style == .cards ? 1:style == .slider ? 0.5:spec.visual.chevron && spec.kind == .button && spec.detail.isEmpty ? 2:style == .accent ? -8.25:spec.visual.group.hasPrefix("m9.") && ![SettingsRowVisual.Style.cards,.search,.toolbar].contains(style) ? (spec.kind == .toggle && spec.detail.isEmpty ? 1.5:spec.kind == .choice && spec.detail.isEmpty ? -0.75:spec.detail.isEmpty ? 0:1):0)
            place(titleLabel,CGRect(x:leading,y:(style == .cards ? 9:spec.detail.isEmpty ? (h-20)/2:9)+textOffset,width:labelWidth,height:18))
            place(detailLabel,CGRect(x:leading+(spec.visual.cardArt.hasPrefix("status.") ? 11:0),y:27+textOffset,width:labelWidth-(spec.visual.cardArt.hasPrefix("status.") ? 11:0),height:max(14,h-32)))
            if spec.visual.cardArt == "summary"{titleLabel.font = .systemFont(ofSize:11);titleLabel.textColor = .tertiaryLabelColor;detailLabel.font = .systemFont(ofSize:17,weight:.bold);detailLabel.textColor = .labelColor;detailLabel.maximumNumberOfLines=2;place(titleLabel,CGRect(x:8,y:13,width:w-18,height:15));place(detailLabel,CGRect(x:8,y:32,width:w-18,height:24))}
            if spec.visual.cardArt == "pair" {titleLabel.font = .systemFont(ofSize:34,weight:.semibold);titleLabel.alignment = .center;place(titleLabel,CGRect(x:0,y:8,width:w,height:48));detailLabel.isHidden=true}
            if spec.visual.cardArt == "checkbox" {place(titleLabel,CGRect(x:30,y:9,width:w-42,height:18));place(detailLabel,CGRect(x:30,y:27,width:w-42,height:16))}
            if let control {
                if spec.kind == .button,spec.visual.chevron{(control as? SettingsButton)?.chromeless=true;place(control,bounds)}
                else if spec.visual.cardArt == "checkbox"{place(control,CGRect(x:10,y:(h-14)/2,width:14,height:14))}
                else if spec.visual.cardArt == "instructions"{titleLabel.isHidden=true;detailLabel.isHidden=true;place(control,bounds.insetBy(dx:10,dy:10))}
                else if [SettingsRow.Kind.editor,.chart,.code,.progress].contains(spec.kind) && style != .cards{place(control,CGRect(x:10,y:spec.detail.isEmpty ? 36:52,width:w-20,height:max(1,h-(spec.detail.isEmpty ? 46:62))))}
                else if style == .rule {titleLabel.isHidden=true;detailLabel.isHidden=true;place(control,CGRect(x:42,y:9,width:min(230,w-180),height:24))}
                else if style == .search || style == .toolbar {titleLabel.isHidden=true;detailLabel.isHidden=true;place(control,CGRect(x:36,y:(h-24)/2,width:max(1,w-54-aux),height:24))}
                else {let ch:CGFloat=style == .cards ? 65:control is SettingsTextSlider ? 25:control is SettingsAccentChoices ? 40:control is SettingsSegments ? 24:control is SettingsButton && spec.kind == .toggle ? 18:spec.kind == .shortcut ? 22:spec.visual.footer ? 20:control is SettingsChoice || (control as? SettingsButton)?.swatch != nil ? 22:24
                    place(control,CGRect(x:spec.visual.centered ? (w-cw)/2:w-10-cw-aux-(spec.visual.chevron ? 14:0),y:(style == .cards ? 10:spec.detail.isEmpty ? (h-ch)/2:spec.kind == .toggle ? 9:8)+(style == .accent ? 3:0)-((control as? SettingsButton)?.formBodyButton == true && !plainTile ? 2:0),width:cw,height:ch))}
                if let scroll=control as? NSScrollView,let editor=scroll.documentView as? SettingsEditor{editor.minSize=NSSize(width:0,height:scroll.contentSize.height);editor.maxSize=NSSize(width:10_000,height:100_000);editor.frame.size=NSSize(width:scroll.contentSize.width,height:max(scroll.contentSize.height,editor.frame.height));editor.textContainer?.containerSize=NSSize(width:scroll.contentSize.width,height:100_000)}
            }
        }
        if let scroll=themeScroll,let canvas=themeCanvas {
            titleLabel.isHidden=true;detailLabel.isHidden=true;scroll.verificationScale=scale;place(scroll,CGRect(x:8,y:10,width:w-16,height:h-20))
            let columns=spec.visual.showsAll ? max(1,Int((w-14)/88)):max(1,themes.count),rows=spec.visual.showsAll ? (themes.count+columns-1)/columns:1
            canvas.verificationScale=scale
            canvas.frame=CGRect(x:0,y:0,width:spec.visual.showsAll ? w-16:CGFloat(themes.count)*84,height:spec.visual.showsAll ? CGFloat(rows)*68+CGFloat(max(0,rows-1))*10+8:80)
            let cellWidth=(w-20-CGFloat(max(0,columns-1))*6)/CGFloat(columns)
            for (i,t) in themes.enumerated(){canvas.place(t,CGRect(x:spec.visual.showsAll ? 2+CGFloat(i%columns)*(cellWidth+6)+(cellWidth-78)/2:CGFloat(i)*84+2,y:spec.visual.showsAll ? CGFloat(i/columns)*78+4:4,width:78,height:spec.visual.showsAll ? 68:72))}
            if spec.visual.showsAll {scroll.setOffset(0);themeWasExpanded=true}
            else if (themeScrollSelection != spec.value.settingsText || themeWasExpanded) && scroll.bounds.width>100 {
                let index=themes.firstIndex{$0.theme.id == spec.value.settingsText} ?? 0
                let requested=spec.value.settingsText == "match" ? 0:max(20,CGFloat(index)*84+41-scroll.bounds.width/2)
                scroll.setOffset(requested)
                themeScrollSelection=spec.value.settingsText;themeWasExpanded=false
            }else{scroll.setOffset(scroll.offset)}
        }
        if spec.visual.cardArt == "pluginToolbar",actionControls.count == 2 {
            place(actionControls[0],CGRect(x:10,y:10,width:342,height:24));place(actionControls[1],CGRect(x:388,y:12,width:max(1,w-398),height:20));return
        }
        // A plugin's trailing HStack has an 8pt gap and the chevron's intrinsic 8.5pt width.
        let chevronReserve:CGFloat=spec.visual.chevron ? (actionControls.contains{($0 as? SettingsButton)?.style == .toggle} ? 16.5:14):0
        var x=w-10-chevronReserve
        if style == .profile {x=(w+actionControls.reduce(CGFloat(0)){$0+controlWidth($1)+8}-8)/2}
        for c in actionControls.reversed(){let cw:CGFloat=style == .activity ? 237:style == .toolbar && c is SettingsSegments ? w*0.57:style == .toolbar && c is SettingsField ? max(90,w*0.40):controlWidth(c),ch:CGFloat=c is SettingsButton && (c as? SettingsButton)?.style == .toggle ? 18:(c as? SettingsButton)?.formBodyButton == true ? 24:22
            x-=cw;place(c,CGRect(x:x,y:(style == .header ? ((c as? SettingsButton)?.prominent == true ? -1.5:-2):style == .profile ? ((c as? SettingsButton)?.style == .popup ? 139.5:139):style == .activity ? 14:spec.detail.isEmpty ? (h-ch)/2:(c as? SettingsButton)?.style == .toggle ? 9.5:8)-((c as? SettingsButton)?.formBodyButton == true && !(spec.detail.isEmpty && !spec.visual.tile.isEmpty && spec.visual.tileSize == 26) ? 2:0),width:cw,height:ch));x-=style == .profile || style == .header ? 8:spec.kind == .shortcut ? 2:4}
    }
    private var rightTextWidth:CGFloat{min(bounds.width*0.6,max(143,(spec.visual.rightText as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13)]).width))}
    override func draw(_ dirtyRect:NSRect){
        guard spec.visual.style != .header,spec.kind != .heading else{return}
        if spec.visual.cardArt == "pluginToolbar" {SettingsArt.plate(CGRect(x:362,y:10,width:max(1,bounds.width-372),height:24),radius:7,color:.white.withAlphaComponent(0.08));SettingsArt.symbol("magnifyingglass",in:CGRect(x:370,y:16,width:12,height:12),size:11)}
        if spec.visual.cardArt == "locked"{SettingsArt.symbol("lock.fill",in:CGRect(x:bounds.width-64,y:9,width:12,height:14),size:11)}
        if !spec.visual.symbol.isEmpty && ![SettingsRowVisual.Style.profile,.statistics,.activity,.pluginTiles,.storage,.usageChart,.meter,.empty].contains(spec.visual.style) {
            let icon=CGRect(x:10,y:(bounds.height-(spec.visual.tile.isEmpty ? 18:spec.visual.tileSize))/2,width:spec.visual.tile.isEmpty ? 22:spec.visual.tileSize,height:spec.visual.tile.isEmpty ? 18:spec.visual.tileSize)
            if spec.visual.tile.isEmpty{SettingsArt.symbol(spec.visual.symbol,in:icon,size:14,color:spec.tint ?? .secondaryLabelColor)}
            else if spec.visual.cardArt == "site"{SettingsArt.plate(icon,radius:8,color:SettingsDrawing.hex(spec.visual.tile));let base=NSFont.systemFont(ofSize:spec.visual.tileSize*0.42,weight:.bold),font=NSFont(descriptor:base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,size:base.pointSize) ?? base;let line=font.ascender-font.descender+font.leading;SettingsDrawing.text(spec.visual.symbol,in:CGRect(x:icon.minX,y:icon.midY-line/2,width:icon.width,height:line),font:font,color:.white,alignment:.center)}
            else{SettingsArt.tile(spec.visual.symbol,spec.visual.tile,in:icon)}
        }
        if spec.visual.chevron {SettingsArt.symbol("chevron.right",in:CGRect(x:bounds.width-21,y:(bounds.height-12)/2,width:10,height:12),size:11,color:.tertiaryLabelColor,weight:.semibold)}
        if !spec.visual.rightText.isEmpty,control == nil || spec.visual.cardArt == "checkbox" || spec.visual.chevron {SettingsDrawing.text(spec.visual.rightText,in:CGRect(x:bounds.width-10-(spec.visual.chevron ? 18:0)-rightTextWidth-actionControls.reduce(CGFloat(0)){$0+controlWidth($1)+4},y:spec.detail.isEmpty ? (bounds.height-17)/2:8,width:rightTextWidth,height:18),font:.systemFont(ofSize:13),color:.secondaryLabelColor,alignment:.right)}
        if spec.visual.cardArt.hasPrefix("status.") {let color:NSColor=spec.visual.cardArt.hasSuffix("green") ? .systemGreen:spec.visual.cardArt.hasSuffix("orange") ? .systemOrange:.systemRed;SettingsArt.plate(CGRect(x:titleLabel.frame.minX+2,y:31,width:7,height:7),radius:3.5,color:color)}
        if spec.visual.style == .search || spec.visual.style == .toolbar,spec.visual.cardArt != "pluginToolbar" {SettingsArt.plate(CGRect(x:10,y:10,width:max(1,bounds.width-20-actionControls.reduce(CGFloat(0)){$0+controlWidth($1)+8}),height:24),radius:7,color:.white.withAlphaComponent(0.08));SettingsArt.symbol("magnifyingglass",in:CGRect(x:17,y:(bounds.height-12)/2,width:12,height:12),size:11)}
    }
}

@MainActor final class SettingsForm:SettingsView {
    private(set) var rows:[SettingsFormRow]=[]
    private(set) var groupFrames:[String:CGRect]=[:]
    func configure(_ specs:[SettingsRow]){
        let old=Dictionary(rows.map{($0.spec.id,$0)},uniquingKeysWith:{$1})
        let next=specs.map{spec->SettingsFormRow in if let row=old[spec.id],row.spec.kind == spec.kind,row.spec.visual.style == spec.visual.style{row.update(spec);return row};return SettingsFormRow(spec)}
        let ids=Set(next.map(ObjectIdentifier.init));for row in rows where !ids.contains(ObjectIdentifier(row)){row.removeFromSuperview()};for row in next where row.superview !== self{addSubview(row)};rows=next;needsLayout=true;needsDisplay=true
    }
    private func separates(_ i:Int)->Bool{i+1<rows.count && !rows[i].spec.visual.group.isEmpty && rows[i].spec.visual.group == rows[i+1].spec.visual.group}
    func fittedHeight(width:CGFloat)->CGFloat{let raw=rows.enumerated().reduce(CGFloat(40)){$0+$1.element.height(max(1,width-40))+$1.element.spec.visual.gap+(separates($1.offset) ? 1:0)};return ceil(raw*scale)/scale}
    override func layout(){super.layout();var y:CGFloat=20;groupFrames=[:]
        for (i,row) in rows.enumerated() {y+=row.spec.visual.gap;let h=row.height(max(1,bounds.width-40));place(row,CGRect(x:20,y:y,width:max(1,bounds.width-40),height:h));row.verificationScale=verificationScale;row.layoutSubtreeIfNeeded();y+=h+(separates(i) ? 1:0)
            if !row.spec.visual.group.isEmpty{let g=row.spec.visual.group;groupFrames[g]=groupFrames[g].map{$0.union(row.frame)} ?? row.frame}}
        needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect)
        let p=SettingsDrawing.palette(self),plate=NativeDisplayOptions.shared.state.reducesEffects ? p.canvas.blended(withFraction:0.04,of:.white) ?? p.canvas:p.label.withAlphaComponent(0.03)
        for r in groupFrames.values {SettingsArt.plate(r,radius:12,color:plate)}
        for (i,row) in rows.enumerated() where i+1<rows.count && !row.spec.visual.group.isEmpty && row.spec.visual.group == rows[i+1].spec.visual.group {
            p.label.withAlphaComponent(0.25).setFill();CGRect(x:row.frame.minX+10,y:row.frame.maxY,width:row.frame.width-20,height:1).fill()
        }
    }
}
