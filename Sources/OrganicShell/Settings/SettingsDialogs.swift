import AppKit

/// Independent AppKit port of the product's form sheets. This controller creates no window until presented.
@MainActor final class SettingsSheetContent:NSViewController {
    let session:SettingsSession,id:UUID
    let form=SettingsForm(),scroll=NSScrollView(),cancel=SettingsButton(),submit=SettingsButton(),heading=SettingsDrawing.label(size:17,weight:.bold),explanation=SettingsDrawing.label(size:12)
    var onClose:(()->Void)?
    private var availableSize=CGSize(width:440,height:452)
    /// Host content bounds, excluding titlebar; the conservative default fits a 760x480 window.
    func fit(in size:CGSize){availableSize=size;refresh()}
    init(session:SettingsSession,sheet:SettingsSheetState){self.session=session;id=sheet.id;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func loadView(){
        let root=SettingsView(frame:CGRect(x:0,y:0,width:440,height:440));root.fill = .windowBackgroundColor;view=root
        scroll.documentView=form;scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        for v in [heading,explanation,scroll,cancel,submit]{root.addSubview(v)}
        cancel.title="Cancel";cancel.setAccessibilityLabel("Cancel");cancel.keyEquivalent="\u{1b}";cancel.run={ [weak self] in guard let self else{return};self.session.cancelSheet(id:self.id);self.onClose?() }
        explanation.maximumNumberOfLines=2;explanation.cell?.wraps=true;explanation.textColor = .secondaryLabelColor
        submit.prominent=true
        submit.title="Continue";submit.setAccessibilityLabel("Continue");submit.keyEquivalent="\r";submit.run={ [weak self] in guard let self else{return};if self.session.sheet?.phase == .done{self.session.cancelSheet(id:self.id);self.onClose?();return};Task{await self.session.submitSheet(id:self.id);self.refresh()} }
        refresh()
    }
    private func field(_ key:String,_ title:String,_ fallback:String="",choices:[(String,String)]=[],editor:Bool=false)->SettingsRow {
        let value=session.sheet?.fields[key] ?? .string(fallback)
        return .init(id:"sheet."+key,title:title,kind:key == "at" ? .date:choices.isEmpty ? (editor ? .editor:.field):.choice,value:value,choices:choices,perform:{ [weak self] value in
            guard let self,self.session.sheet?.id == self.id else{return}
            self.session.sheet?.fields[key]=value
            if key == "hours" {self.session.sheet?.fields[key] = .number(Double(value.settingsText) ?? 0)}
            self.refresh()
        })
    }
    func refresh(){
        guard isViewLoaded,let sheet=session.sheet,sheet.id == id else{return}
        let titles:[SettingsSheetKind:String]=[.importContent:"Import from Claude Code",.customizeSync:"Content to Sync",.importMCP:"Import from Project MCP Files",.addMCP:"Add MCP Server",.pair:"Pair a Device",.ssh:"Add SSH Host",.schedule:"New scheduled task",.addSite:"Add site",.addRule:"Add custom rule"]
        heading.stringValue=titles[sheet.kind] ?? "Settings"
        let descriptions:[SettingsSheetKind:String]=[.customizeSync:"Choose what keeps coming over from Claude Code.",.importContent:"Choose what to bring over. Nothing in the other app changes.",.importMCP:"Choose what to bring over. Nothing in the other app changes.",.addMCP:session.mode == .demo ? "Codex starts it on This Mac and lists its tools.":"Add an HTTP server to the connected backend.",.pair:"On the other device, open Organic Codex, choose Connect to a Mac and enter this code.",.ssh:"Codex connects with the keys in your SSH agent."]
        explanation.stringValue=descriptions[sheet.kind] ?? ""
        var rows:[SettingsRow]=[]
        switch sheet.phase {
        case .editing,.failed:
            if case .failed(let error)=sheet.phase {rows.append(.init(id:"sheet.error",title:"Couldn’t save",detail:error))}
            switch sheet.kind {
            case .addMCP:rows += [field("name","Name"),field("transport","Transport",choices:session.mode == .live ? [("http","HTTP")]:[("stdio","Command (stdio)"),("http","URL (HTTP)")]),field("command",sheet.fields["transport"]?.settingsText == "http" ? "Server URL":"Command")]
            case .ssh:rows += [field("host","Host"),field("user","User"),field("port","Port","22")]
            case .schedule:
                rows += [field("name","Name"),field("prompt","Prompt",editor:true),field("at","First run"),field("hours","Repeat","0",choices:[("0","Once"),("1","Every hour"),("24","Every day"),("168","Every week")]),field("thread","Conversation","",choices:[("","Create a new chat")]+session.records("threads").compactMap{ t in guard let id=t["backendThreadID"]?.stringValue else{return nil};return(id,t["title"]?.settingsText ?? "Chat")})]
            case .addSite:rows += [field("host","Host")]
            case .addRule:rows += [field("pattern","Command pattern","npm run *"),field("rule","Action","ask",choices:SettingsPanelBuilder.policies)]
            case .importContent,.customizeSync,.importMCP:
                for (key,name) in [("settings","Settings and instructions"),("mcp","MCP servers"),("skills","Skills"),("projects","Projects"),("chats","Chats")] {
                    rows.append(.init(id:"sheet.pick."+key,title:name,kind:.toggle,value:sheet.fields[key] ?? false,perform:{ [weak self] v in guard let self,self.session.sheet?.id == self.id else{return};self.session.sheet?.fields[key]=v;self.refresh() }))
                }
            case .pair:
                rows.append(.init(id:"pair.code",title:"482 915",detail:"Enter this prototype pairing code on the other device."))
                rows.append(.init(id:"pair.wait",title:"Waiting for a device…",detail:"The demo will pair a sample iPad."))
            }
        case .working:rows.append(.init(id:"sheet.working",title:"Working…",detail:sheet.kind == .importContent ? "Importing selected prototype data…":"Waiting for acknowledgement…"))
        case .done:rows.append(.init(id:"sheet.done",title:"Complete",detail:sheet.message))
        case .cancelled:break
        }
        if [.importContent,.customizeSync,.importMCP].contains(sheet.kind),sheet.phase == .working || sheet.phase == .done {
            let status=rows
            rows=[("settings","Settings and instructions"),("mcp","MCP servers"),("skills","Skills"),("projects","Projects"),("chats","Chats")].map{key,title in SettingsRow(id:"sheet.pick."+key,title:title,kind:.toggle,value:sheet.fields[key] ?? false,enabled:false)}+status
        }
        let details=["settings":"CLAUDE.md becomes AGENTS.md","mcp":"3 servers","skills":"12 skills","projects":"4 folders","chats":"41 chats, read-only copies"]
        for i in rows.indices {
            rows[i].visual.group="sheet.form"
            if rows[i].id.hasPrefix("sheet.pick."){rows[i].detail=details[String(rows[i].id.dropFirst(11))] ?? "";rows[i].visual.cardArt="checkbox";rows[i].enabled=sheet.phase == .editing || {if case .failed=sheet.phase{return true};return false}()}
            if rows[i].kind == .field{rows[i].visual.placeholder=rows[i].id == "sheet.name" ? "my-server":rows[i].id == "sheet.host" ? "build-box.local":rows[i].id == "sheet.user" ? "dev":rows[i].id == "sheet.command" ? (sheet.fields["transport"] == "http" ? "https://…":"npx my-mcp-server"):"22"}
            if rows[i].id == "pair.code"{rows[i].visual.cardArt="pair";rows[i].visual.group="";rows[i].visual.height=70;rows[i].detail=""}
        }
        if sheet.kind == .pair{rows.removeAll{$0.id == "pair.wait"}}
        form.configure(rows);submit.isEnabled=sheet.canSubmit
        submit.title=sheet.kind == .customizeSync || sheet.kind == .pair ? "Done":sheet.kind == .addMCP ? "Add Server":sheet.kind == .ssh ? "Add Host":sheet.kind == .schedule ? "Create":"Import"
        cancel.title="Cancel";cancel.isHidden=sheet.phase == .done || (sheet.phase == .working && sheet.kind != .pair)
        if sheet.phase == .done{submit.title="Done";submit.isEnabled=true};submit.isHidden=false;submit.setAccessibilityLabel(submit.title);cancel.setAccessibilityLabel(cancel.title)
        if let root=view as? SettingsView {
            let width=min(440,max(240,availableSize.width))
            let height=min(max(160,availableSize.height),min(780,max(260,form.fittedHeight(width:width)+140)))
            preferredContentSize=NSSize(width:width,height:height);root.frame.size=preferredContentSize;root.needsLayout=true;viewDidLayout()
        }
    }
    override func viewDidLayout(){
        super.viewDidLayout();guard let root=view as? SettingsView else{return}
        let width=view.bounds.width
        root.place(heading,CGRect(x:18,y:18,width:max(1,width-40),height:26))
        heading.toolTip=session.mode == .demo ? "Demo only. No Live account, files or permissions will change.":nil
        root.place(explanation,CGRect(x:18,y:46,width:max(1,width-36),height:32))
        root.place(scroll,CGRect(x:0,y:84,width:width,height:max(1,view.bounds.height-140)))
        let bodyWidth=scroll.contentSize.width
        form.frame=CGRect(x:0,y:0,width:bodyWidth,height:max(scroll.contentSize.height,form.fittedHeight(width:bodyWidth)))
        form.needsLayout=true;form.layoutSubtreeIfNeeded()
        root.place(cancel,CGRect(x:max(8,width-204),y:view.bounds.height-42,width:80,height:26));root.place(submit,CGRect(x:max(96,width-116),y:view.bounds.height-42,width:96,height:26))
    }
    func snapshot(scale:CGFloat)->CGImage{loadViewIfNeeded();viewDidLayout();return NativeViewBitmap.capture(view,scale:scale)}
}
@MainActor enum SettingsAlerts {
    static func build(_ confirmation:SettingsConfirmation)->NSAlert {
        let alert=NSAlert();alert.messageText=confirmation.title;alert.informativeText=confirmation.message
        alert.alertStyle=confirmation.destructive ? .warning:.informational
        alert.addButton(withTitle:confirmation.confirm);alert.addButton(withTitle:"Cancel")
        alert.buttons.first?.hasDestructiveAction=confirmation.destructive
        return alert
    }
}

/// Lazy native driver: construction has no NSWindow/NSColorPanel side effects.
@MainActor protocol SettingsColorPanelDriver:AnyObject {
    func show(color:NSColor,changed:@escaping (NSColor)->Void)
    func disconnect()
}
@MainActor private final class SettingsSystemColorPanelDriver:NSObject,SettingsColorPanelDriver {
    private weak var panel:NSColorPanel?
    private var changed:((NSColor)->Void)?
    func show(color:NSColor,changed:@escaping (NSColor)->Void){
        self.changed=changed;let p=NSColorPanel.shared;panel=p
        p.color=color;p.setTarget(self);p.setAction(#selector(colorChanged(_:)));p.isContinuous=true;p.orderFront(nil)
    }
    @objc private func colorChanged(_ sender:NSColorPanel){changed?(sender.color)}
    func disconnect(){panel?.setTarget(nil);panel?.setAction(nil);panel=nil;changed=nil}
}
@MainActor final class SettingsColorPanelConnection {
    static let shared=SettingsColorPanelConnection(driver:SettingsSystemColorPanelDriver())
    private let driver:any SettingsColorPanelDriver
    private weak var owner:SettingsColorContent?
    private var generation=0
    init(driver:any SettingsColorPanelDriver){self.driver=driver}
    func show(for owner:SettingsColorContent){
        guard owner.presentationActive else{return}
        self.owner=owner;generation+=1;let epoch=generation
        driver.show(color:owner.color){[weak self,weak owner] color in
            guard let self,let owner,self.owner === owner,self.generation == epoch,owner.presentationActive else{return}
            owner.color=color;owner.save()
        }
    }
    func disconnect(_ owner:SettingsColorContent){
        guard self.owner === owner else{return}
        generation+=1;self.owner=nil;driver.disconnect()
    }
}

/// HSV editor plus the native system color panel. Action ownership is detached when the popover closes.
@MainActor final class SettingsColorContent:NSViewController,NSPopoverDelegate {
    let session:SettingsSession,key:String,original:String
    private let originalColor:String
    private let colorPanel:SettingsColorPanelConnection
    private(set) var presentationActive=true
    let canvas=SettingsColorCanvas(),hex=SettingsField(),revert=SettingsButton(),native=SettingsButton(),useTheme=SettingsButton()
    let heading=SettingsDrawing.label(size:13,weight:.semibold),paletteLabel=SettingsDrawing.label("Palette",size:11)
    private var presets:[SettingsPaletteDot]=[]
    var onClose:(()->Void)?
    var color:NSColor {didSet{refresh()}}
    init(session:SettingsSession,key:String,colorPanel:SettingsColorPanelConnection = .shared){
        self.colorPanel=colorPanel;self.session=session;self.key=key;original=session.preferences[key].settingsText
        let theme=SettingsThemes.theme(session.preferences["look.theme"].settingsText)
        originalColor=original.isEmpty ? (key.hasSuffix("background") ? theme.bg:key.hasSuffix("foreground") ? theme.fg:theme.accent):original
        color=SettingsDrawing.hex(originalColor)
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func loadView(){
        let root=SettingsView(frame:CGRect(x:0,y:0,width:252,height:332));root.fill = .windowBackgroundColor;view=root;preferredContentSize=root.bounds.size
        for v in [heading,canvas,hex,revert,paletteLabel,native]{root.addSubview(v)}
        heading.stringValue=key.hasSuffix("background") ? "Background":key.hasSuffix("foreground") ? "Foreground":"Accent Color"
        paletteLabel.textColor = .secondaryLabelColor
        let t=SettingsThemes.theme(session.preferences["look.theme"].settingsText)
        var colors:[String]=[];for color in [t.bg,t.fg,t.accent,t.keyword,t.type,t.string,t.function,t.comment] where !colors.contains(color){colors.append(color)}
        presets=colors.map{color in let b=SettingsPaletteDot();b.color=SettingsDrawing.hex(color);b.setAccessibilityLabel(color.uppercased());b.run={ [weak self] in guard let self,self.presentationActive else{return};self.color=SettingsDrawing.hex(color);self.save() };root.addSubview(b);return b}
        canvas.changed={ [weak self] c in self?.color=c;self?.save() }
        hex.setAccessibilityLabel("Hex color");hex.edited={ [weak self] v in guard let self,SettingsPreferences.isHex(v)else{return};self.color=SettingsDrawing.hex(v);self.save() }
        revert.title="Revert";revert.run={ [weak self] in guard let self else{return};self.session.preferences.set(self.key,.string(self.original));self.color=SettingsDrawing.hex(self.originalColor) }
        native.title="Show Colors…";native.run={ [weak self] in self?.showNativeColorPanel() }
        useTheme.title="Use Theme";useTheme.run={ [weak self] in guard let self else{return};self.session.preferences.set(self.key,"");self.onClose?() }
        refresh()
    }
    func save(){guard presentationActive else{return};session.preferences.set(key,.string(Self.hex(color)))}
    static func hex(_ color:NSColor)->String{let rgb=color.usingColorSpace(.sRGB) ?? color;return String(format:"#%02X%02X%02X",Int((rgb.redComponent*255).rounded()),Int((rgb.greenComponent*255).rounded()),Int((rgb.blueComponent*255).rounded()))}
    func refresh(){guard isViewLoaded else{return};canvas.color=color;if hex.currentEditor() == nil {hex.stringValue=Self.hex(color)}}
    override func viewDidLayout(){
        super.viewDidLayout();guard let root=view as? SettingsView else{return}
        root.place(heading,CGRect(x:12,y:12,width:228,height:18));root.place(canvas,CGRect(x:14,y:40,width:224,height:170))
        root.place(hex,CGRect(x:14,y:222,width:84,height:22));hex.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        root.place(revert,CGRect(x:182,y:222,width:56,height:22));root.place(paletteLabel,CGRect(x:12,y:252,width:224,height:14))
        for (i,b) in presets.enumerated(){root.place(b,CGRect(x:14+CGFloat(i)*24,y:274,width:18,height:18))}
        root.place(native,CGRect(x:14,y:302,width:104,height:22))
    }
    func showNativeColorPanel(){guard presentationActive else{return};colorPanel.show(for:self)}
    func disconnect(){presentationActive=false;colorPanel.disconnect(self);canvas.changed=nil;hex.edited=nil;native.run=nil;revert.run=nil;useTheme.run=nil}
    func popoverDidClose(_ notification:Notification){disconnect()}
}
@MainActor final class SettingsColorCanvas:SettingsView {
    var color=NSColor.systemBlue {didSet{needsDisplay=true}}
    var changed:((NSColor)->Void)?
    private var hue:CGFloat {color.usingColorSpace(.deviceRGB)?.hueComponent ?? 0.6}
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityRole(.slider);setAccessibilityLabel("Color saturation, brightness and hue");setAccessibilityHelp("Use arrow keys to adjust hue. Use the Hex color field for an exact value.")}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override var acceptsFirstResponder:Bool{true}
    override func draw(_ dirtyRect:NSRect){
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        context.saveGState();NSBezierPath(roundedRect:CGRect(x:0,y:0,width:bounds.width,height:140),xRadius:8,yRadius:8).addClip()
        NSColor(hue:hue,saturation:1,brightness:1,alpha:1).setFill();CGRect(x:0,y:0,width:bounds.width,height:140).fill()
        if let white=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[NSColor.white.cgColor,NSColor.white.withAlphaComponent(0).cgColor] as CFArray,locations:[0,1]){context.drawLinearGradient(white,start:.zero,end:CGPoint(x:bounds.width,y:0),options:[])}
        if let black=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[NSColor.black.withAlphaComponent(0).cgColor,NSColor.black.cgColor] as CFArray,locations:[0,1]){context.drawLinearGradient(black,start:.zero,end:CGPoint(x:0,y:140),options:[])}
        context.restoreGState()
        let colors=(0...6).map{NSColor(hue:CGFloat($0)/6,saturation:1,brightness:1,alpha:1)}
        NSGradient(colors:colors)?.draw(in:NSBezierPath(roundedRect:CGRect(x:0,y:154,width:bounds.width,height:14),xRadius:7,yRadius:7),angle:0)
        if let c=color.usingColorSpace(.deviceRGB){let p=NSPoint(x:c.saturationComponent*bounds.width,y:(1-c.brightnessComponent)*140);NSColor.white.setStroke();let circle=NSBezierPath(ovalIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14));circle.lineWidth=2;circle.stroke();let hueCircle=NSBezierPath(ovalIn:CGRect(x:c.hueComponent*(bounds.width-14),y:154,width:14,height:14));hueCircle.lineWidth=2;hueCircle.stroke()}
    }
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);update(event)}
    override func mouseDragged(with event:NSEvent){update(event)}
    private func emit(_ next:NSColor){color=next;changed?(next)}
    private func setHue(_ value:CGFloat){let c=color.usingColorSpace(.deviceRGB) ?? .systemBlue;emit(NSColor(hue:value,saturation:c.saturationComponent,brightness:c.brightnessComponent,alpha:c.alphaComponent))}
    private func update(_ event:NSEvent){let p=convert(event.locationInWindow,from:nil);if p.y>=150{setHue(max(0,min(1,p.x/max(1,bounds.width))))}else{emit(NSColor(hue:hue,saturation:max(0,min(1,p.x/max(1,bounds.width))),brightness:1-max(0,min(1,p.y/140)),alpha:color.alphaComponent))}}
    override func keyDown(with event:NSEvent){if [123,124].contains(event.keyCode){setHue((hue+(event.keyCode == 123 ? 0.99:0.01)).truncatingRemainder(dividingBy:1))}else{super.keyDown(with:event)}}
    override func accessibilityValue()->Any?{SettingsColorContent.hex(color)}
}
