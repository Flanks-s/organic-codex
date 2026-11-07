import AppKit

/// Windowless equivalent of the product NavigationSplitView chrome; the real traffic lights remain AppKit's.
/// The title is also published to NSWindow.title by the owner, so Window/AX names follow navigation.
@MainActor final class SettingsChrome:SettingsView {
    var sidebarWidth:CGFloat=220
    override func draw(_ dirtyRect:NSRect){
        let p=palette ?? .init(),s=sidebarWidth
        p.canvas.setFill();bounds.fill()
        let sidebar=p.sidebar
        sidebar.setFill();CGRect(x:0,y:0,width:s,height:bounds.height).fill()
        NSGradient(starting:sidebar,ending:p.canvas)?.draw(in:CGRect(x:s,y:0,width:max(1,bounds.width-s),height:52),angle:0)
        NSColor.white.withAlphaComponent(0.07).setFill();CGRect(x:s,y:52-1/scale,width:bounds.width-s,height:1/scale).fill()
        NSColor.black.withAlphaComponent(0.22).setFill();CGRect(x:s-1/scale,y:0,width:1/scale,height:bounds.height).fill()
        // Offline snapshots have no titlebar. Three neutral circles document their reserved native geometry.
        if window == nil {for x:CGFloat in [26,49,72]{NSColor(white:0.45,alpha:0.7).setFill();NSBezierPath(ovalIn:CGRect(x:x-7,y:19,width:14,height:14)).fill()}}
    }
}
@MainActor final class SettingsNavigationPlate:SettingsView {
    override func draw(_ dirtyRect:NSRect){
        SettingsArt.plate(bounds,radius:18,color:SettingsDrawing.palette(self).label.withAlphaComponent(0.09))
        NSColor.black.withAlphaComponent(0.22).setStroke();let p=NSBezierPath(roundedRect:bounds.insetBy(dx:0.25,dy:0.25),xRadius:18,yRadius:18);p.lineWidth=0.5;p.stroke()
    }
}
/// One toolbar item owns BOTH pieces. Separate NSToolbar items negotiate their leading margins independently:
/// the real title used to land 10.5 pt left of the windowless title. The same geometry now draws both paths.
@MainActor final class SettingsToolbarContent:SettingsView {
    static let navigationWidth:CGFloat=74,titleLeading:CGFloat=83.5,height:CGFloat=36
    var onLayout:(()->Void)?
    let navigation:SettingsNavigationPlate,title:SettingsLabel
    init(navigation:SettingsNavigationPlate,title:SettingsLabel){self.navigation=navigation;self.title=title;super.init(frame:CGRect(x:0,y:0,width:360,height:Self.height));addSubview(navigation);addSubview(title)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func layout(){super.layout();place(navigation,CGRect(x:0,y:0,width:Self.navigationWidth,height:Self.height));place(title,CGRect(x:Self.titleLeading,y:8.5,width:max(1,bounds.width-Self.titleLeading),height:22));if window != nil {
        // NSToolbar may give its custom item a fractional origin. Align in the actual backing space, not
        // merely in the child's local coordinates, which otherwise changes the title's rasterisation.
        title.frame=backingAlignedRect(title.frame,options:[.alignAllEdgesNearest])
        navigation.frame=backingAlignedRect(navigation.frame,options:[.alignAllEdgesNearest])
    };onLayout?()}
}
@MainActor final class SettingsSearchPlate:SettingsView {
    override func draw(_ dirtyRect:NSRect){SettingsArt.plate(bounds,radius:14,color:SettingsDrawing.palette(self).searchFill);SettingsArt.symbol("magnifyingglass",in:CGRect(x:9,y:7,width:12,height:12),size:11)}
}
@MainActor final class SettingsCatalogCell:SettingsView {
    let label=SettingsDrawing.label(size:13),subtitle=SettingsDrawing.label(size:11)
    var pane:SettingsPane?,accountName="Louis L.",accountPlan="Codex Account · Plus",initials="LL",groupOffset:CGFloat=9
    override init(frame:NSRect){super.init(frame:frame);addSubview(label);addSubview(subtitle);label.usesPalette=false;subtitle.usesPalette=false}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    func applyPalette(_ palette:SettingsPalette){self.palette=palette;label.textColor=palette.sidebarLabel;subtitle.textColor=palette.sidebarSecondary;needsDisplay=true}
    override func layout(){
        super.layout();let account=pane?.id == "account";subtitle.isHidden = !account
        if account {label.stringValue=accountName;label.font = .systemFont(ofSize:13,weight:.semibold);subtitle.stringValue=accountPlan;place(label,CGRect(x:53,y:8,width:bounds.width-63,height:17));place(subtitle,CGRect(x:53,y:25,width:bounds.width-63,height:15))}
        else {place(label,CGRect(x:pane == nil ? 12:44,y:pane == nil ? groupOffset:7.5,width:bounds.width-(pane == nil ? 24:54),height:17))}
    }
    override func draw(_ dirtyRect:NSRect){
        guard let p=pane else{return}
        if p.id == "account" {SettingsArt.avatar(initials,in:CGRect(x:16,y:9,width:30,height:30));return}
        // List supplies .large imageScale; the same SettingsTile inside Form keeps .medium.
        SettingsArt.tile(p.symbol,p.tint,in:CGRect(x:19,y:6,width:20,height:20),imageScale:.large)
    }
}
@MainActor final class SettingsCatalogRow:NSTableRowView {
    override func drawSelection(in dirtyRect:NSRect){guard isSelected else{return};SettingsArt.plate(bounds.insetBy(dx:10,dy:0),radius:9,color:SettingsDrawing.palette(self).selectionFill)}
    override func drawBackground(in dirtyRect:NSRect){}
}

/// NavigationSplitView's 220…260 pt sidebar divider. No timer/layout animation while dragging.
@MainActor final class SettingsSidebarDivider:SettingsView {
    var currentWidth:CGFloat=220,changed:((CGFloat)->Void)?
    private var startX:CGFloat=0,startWidth:CGFloat=220
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityRole(.splitter);setAccessibilityLabel("Settings sidebar width")}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.resizeLeftRight)}
    override func mouseDown(with event:NSEvent){startX=event.locationInWindow.x;startWidth=currentWidth}
    override func mouseDragged(with event:NSEvent){changed?(startWidth+event.locationInWindow.x-startX)}
    override func accessibilityValue()->Any?{currentWidth}
    override func accessibilityPerformIncrement()->Bool{let old=currentWidth;changed?(currentWidth+10);return currentWidth != old}
    override func accessibilityPerformDecrement()->Bool{let old=currentWidth;changed?(currentWidth-10);return currentWidth != old}
}
