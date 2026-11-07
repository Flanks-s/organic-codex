import AppKit

@MainActor final class NativeSettingsWorkbench:NSViewController,NSTableViewDataSource,NSTableViewDelegate {
    let session:SettingsSession
    let search=SettingsField(),table=NSTableView(),sidebarScroll=NSScrollView(),detailScroll=NSScrollView(),form=SettingsForm()
    let catalogDocument=SettingsView()
    let back=SettingsButton(),forward=SettingsButton(),titleLabel=SettingsDrawing.label(size:15,weight:.semibold)
    let navigationPlate=SettingsNavigationPlate(),searchPlate=SettingsSearchPlate(),sidebarDivider=SettingsSidebarDivider()
    private(set) lazy var toolbarContent=SettingsToolbarContent(navigation:navigationPlate,title:titleLabel)
    private(set) var sidebarWidth:CGFloat=220
    var onSidebarWidthChanged:(()->Void)?
    func setSidebarWidth(_ width:CGFloat){let scale=(view as? SettingsView)?.scale ?? 1;sidebarWidth=(min(260,max(220,width))*scale).rounded()/scale;sidebarDivider.currentWidth=sidebarWidth;(view as? SettingsChrome)?.sidebarWidth=sidebarWidth;view.needsLayout=true;view.needsDisplay=true;viewDidLayout();onSidebarWidthChanged?()}
    var onTitleChanged:((String)->Void)?
    private(set) var catalog:[SettingsPane]=[]
    private(set) var catalogRows:[(group:String,pane:SettingsPane?)]=[]
    private var loading:Task<Void,Never>?
    var automaticallyLoads=true
    private var renderedPane="",renderedRevision=0
    private var keyMonitor:Any?
    private var presentationActive=true
    private var displayObservation:UUID?
    private var updatingCatalog=false
    private var catalogNeedsReveal=true,catalogMounted=false
    private var catalogTop="",catalogQuery=""
    var onDialog:(()->Void)?
    init(session:SettingsSession){self.session=session;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func loadView(){
        let root=SettingsChrome(frame:CGRect(x:0,y:0,width:880,height:660));view=root
        root.setAccessibilityRole(.group);root.setAccessibilityLabel("Settings")
        search.drawsSearchPlaceholder=true;search.placeholderString="Search";search.setAccessibilityLabel("Search settings")
        search.edited={ [weak self] text in self?.session.query=text;self?.refreshCatalog() }
        back.title="";back.symbolName="chevron.left";back.chromeless=true;back.setAccessibilityLabel("Back");back.run={ [weak self] in self?.session.back() }
        forward.title="";forward.symbolName="chevron.right";forward.chromeless=true;forward.setAccessibilityLabel("Forward");forward.run={ [weak self] in self?.session.forward() }
        table.addTableColumn(NSTableColumn(identifier:.init("settings")));table.headerView=nil;table.rowHeight=32;table.intercellSpacing = .zero
        table.style = .plain;table.dataSource=self;table.delegate=self;table.backgroundColor = .clear
        table.floatsGroupRows=false;table.allowsEmptySelection=true;table.setAccessibilityLabel("Settings directory");table.setAccessibilityRole(.outline)
        catalogDocument.addSubview(table);sidebarScroll.documentView=catalogDocument;sidebarScroll.hasVerticalScroller=true;sidebarScroll.drawsBackground=false
        detailScroll.documentView=form;detailScroll.hasVerticalScroller=true;detailScroll.drawsBackground=false
        navigationPlate.addSubview(back);navigationPlate.addSubview(forward)
        for v in [searchPlate,search,sidebarScroll,toolbarContent,detailScroll,sidebarDivider]{root.addSubview(v)}
        sidebarDivider.changed={ [weak self] width in self?.setSidebarWidth(width) }
        displayObservation=NativeDisplayOptions.shared.observe{ [weak self] in self?.render() }
        session.onChange={ [weak self] in self?.render();self?.onDialog?() }
        render()
    }
    override func viewDidLayout(){
        super.viewDidLayout();guard let root=view as? SettingsView else{return}
        let w=root.bounds.width,h=root.bounds.height,side=sidebarWidth
        root.place(searchPlate,CGRect(x:10,y:62,width:side-20,height:27))
        root.place(search,CGRect(x:36,y:67,width:side-56,height:19))
        // List scrolls behind the bottom of Search, but keeps a 9 pt initial content inset. Putting the clip
        // itself at 98 clipped General's icon after a correct Browser reveal (the product clip starts at 89).
        root.place(sidebarScroll,CGRect(x:0,y:89,width:side,height:max(1,h-89)))
        if toolbarContent.superview === root {root.place(toolbarContent,CGRect(x:side+7,y:8,width:max(1,w-side-20),height:36))}
        toolbarContent.verificationScale=root.verificationScale;toolbarContent.palette=root.palette;toolbarContent.needsLayout=true;toolbarContent.layoutSubtreeIfNeeded()
        navigationPlate.place(back,CGRect(x:3,y:0,width:33,height:36))
        navigationPlate.place(forward,CGRect(x:39,y:0,width:33,height:36))
        root.place(detailScroll,CGRect(x:side,y:52,width:max(1,w-side),height:max(1,h-52)))
        root.place(sidebarDivider,CGRect(x:side-2,y:52,width:4,height:max(1,h-52)))
        table.tableColumns.first?.width=max(1,sidebarScroll.contentSize.width)
        layoutCatalog()
        layoutForm();revealCatalog()
    }
    private func layoutForm(){let width=detailScroll.contentSize.width;form.frame=CGRect(x:0,y:0,width:width,height:max(detailScroll.contentSize.height,form.fittedHeight(width:width)));form.needsLayout=true;form.layoutSubtreeIfNeeded()}
    func refreshCatalog(){
        guard !updatingCatalog else{return};updatingCatalog=true;defer{updatingCatalog=false}
        catalog=NativeSettingsCatalog.visible(query:session.query,mode:session.mode);catalogRows=[]
        var last=""
        for p in catalog {if p.group != last,!p.group.isEmpty{catalogRows.append((p.group,nil));last=p.group};catalogRows.append(("",p))}
        table.reloadData()
        layoutCatalog()
        if catalogTop != session.top || catalogQuery != session.query {catalogNeedsReveal=true;catalogTop=session.top;catalogQuery=session.query}
        if let i=catalogRows.firstIndex(where:{$0.pane?.id == session.top}){table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)}else{table.deselectAll(nil)}
        revealCatalog()
    }
    private func revealCatalog(){
        guard sidebarScroll.frame.height>100,sidebarScroll.contentSize.height>100 else{return}
        if !catalogMounted{sidebarScroll.contentView.scroll(to:.zero);catalogMounted=true}
        guard catalogNeedsReveal else{return};catalogNeedsReveal=false
        if let i=catalogRows.firstIndex(where:{$0.pane?.id == session.top}){
            // NSTableView.scrollRowToVisible adds a 16 pt breathing margin. SwiftUI List/ScrollViewReader does
            // not: at 880×660 that used to hide General when Browser was opened directly.
            let clip=sidebarScroll.contentView,rect=catalogDocument.convert(table.rect(ofRow:i),from:table)
            let offset=Self.catalogOffset(current:clip.bounds.minY,row:rect,viewport:clip.bounds.height,document:catalogDocument.bounds.height,scale:(view as? SettingsView)?.scale ?? 2)
            clip.scroll(to:CGPoint(x:0,y:offset));sidebarScroll.reflectScrolledClipView(clip)
        }
    }
    private func layoutCatalog(){
        let scale=(view as? SettingsView)?.scale ?? 2,width=max(1,sidebarScroll.contentSize.width)
        let height=catalogRows.isEmpty ? 0:table.rect(ofRow:catalogRows.count-1).maxY
        table.frame=SettingsDrawing.align(CGRect(x:0,y:9,width:width,height:height),scale)
        catalogDocument.frame=SettingsDrawing.align(CGRect(x:0,y:0,width:width,height:max(sidebarScroll.contentSize.height,height+9)),scale)
    }
    static func catalogOffset(current:CGFloat,row:CGRect,viewport:CGFloat,document:CGFloat,scale:CGFloat)->CGFloat{
        let limit=max(0,document-viewport)
        var target=current
        if row.minY<current{target=row.minY}else if row.maxY>current+viewport{target=row.maxY-viewport}
        return (min(limit,max(0,target))*max(1,scale)).rounded()/max(1,scale)
    }
    func render(){
        guard isViewLoaded else{return}
        view.appearance=NativeDisplayOptions.appearance
        let palette=SettingsPalette(session.preferences)
        (view as? SettingsView)?.palette=palette;(view as? SettingsView)?.fill=palette.canvas
        navigationPlate.palette=palette
        form.palette=palette;form.fill=palette.canvas;form.appearance=view.effectiveAppearance
        refreshCatalog();titleLabel.stringValue=session.paneTitle
        back.isEnabled=session.navigation.canBack;forward.isEnabled=session.navigation.canForward
        form.configure(SettingsPresentation.make(SettingsPanels.make(session),session:session))
        onTitleChanged?(titleLabel.stringValue)
        func paint(_ v:NSView){
            if let cell=v as? SettingsCatalogCell{cell.applyPalette(palette)}
            if let label=v as? SettingsLabel,label.usesPalette {label.textColor=label === titleLabel ? palette.label.withAlphaComponent(0.255):((label.font?.pointSize ?? 13) <= 11 ? palette.secondary:palette.label)}
            if let field=v as? SettingsField {field.textColor=palette.label}
            if let editor=v as? SettingsEditor {editor.textColor=palette.label}
            v.needsDisplay=true;v.subviews.forEach(paint)
        }
        paint(view);paint(navigationPlate);paint(titleLabel);layoutForm();rebuildFocusChain()
        if renderedRevision != session.contentRevision {renderedRevision=session.contentRevision;detailScroll.contentView.scroll(to:.zero)}
        if renderedPane != session.pane {
            renderedPane=session.pane;detailScroll.contentView.scroll(to:.zero);loading?.cancel()
            if automaticallyLoads {loading=Task{ [weak self] in await self?.session.loadNow() }}
        }
    }
    private(set) var focusChain:[NSView]=[]
    private func rebuildFocusChain(){
        var targets:[NSView]=[search,table]
        if back.isEnabled {targets.append(back)};if forward.isEnabled{targets.append(forward)}
        for row in form.rows {
            if let scroll=row.control as? NSScrollView,let editor=scroll.documentView as? SettingsEditor,editor.isEditable{targets.append(editor)}
            else if let control=row.control as? NSControl,control.isEnabled{targets.append(control)}
            if row.rowActionAvailable{targets.append(row)}
            for control in row.actionControls {if let c=control as? NSControl,c.isEnabled{targets.append(c)}else if let segments=control as? SettingsSegments{targets += segments.buttons}}
            if let segments=row.control as? SettingsSegments{targets += segments.buttons}
            if let accent=row.control as? SettingsAccentChoices{targets += accent.subviews.compactMap{$0 as? SettingsButton}}
            targets += row.themes
        }
        for (i,target) in targets.enumerated(){target.nextKeyView=targets[(i+1)%targets.count]}
        focusChain=targets
    }
    func reload(){loading?.cancel();loading=Task{ [weak self] in await self?.session.loadNow() }}
    func numberOfRows(in tableView:NSTableView)->Int{catalogRows.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard catalogRows.indices.contains(row)else{return nil}
        guard let p=catalogRows[row].pane else{let cell=SettingsCatalogCell();cell.applyPalette(SettingsPalette(session.preferences));cell.label.stringValue=catalogRows[row].group;cell.label.font = .systemFont(ofSize:11,weight:.semibold);cell.groupOffset=catalogRows[row].group == "Personal" ? 7.5:15.5;return cell}
        let cell=SettingsCatalogCell();cell.applyPalette(SettingsPalette(session.preferences));cell.pane=p;cell.label.stringValue=p.name;cell.setAccessibilityLabel(p.name);cell.setAccessibilityRole(.cell)
        if p.id == "account" {
            if session.mode == .demo {cell.accountName=session.snapshots["demo"]?["global"]?["name"]?.settingsText ?? "Louis L.";cell.accountPlan="Codex Account · "+(session.snapshots["demo"]?["global"]?["plan"]?.settingsText ?? "Plus")}
            else {let a=session.snapshots["account"]?["account"];cell.accountName=a?["name"]?.settingsText ?? a?["email"]?.settingsText ?? "Account";cell.accountPlan=a?["planType"]?.settingsText.capitalized ?? "Not reported"}
            cell.initials=cell.accountName.split(separator:" ").prefix(2).compactMap{$0.first}.map(String.init).joined()
        }
        if p.id == session.top{cell.label.font = .systemFont(ofSize:13,weight:.semibold)}
        return cell
    }
    func tableView(_ tableView:NSTableView,isGroupRow row:Int)->Bool{catalogRows.indices.contains(row) && catalogRows[row].pane == nil}
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView?{SettingsCatalogRow()}
    func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool{catalogRows.indices.contains(row) && catalogRows[row].pane != nil}
    func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat{
        guard catalogRows.indices.contains(row)else{return 32}
        if catalogRows[row].pane?.id == "account"{return 55}
        return catalogRows[row].pane == nil ? (catalogRows[row].group == "Personal" ? 24:32):32
    }
    func tableViewSelectionDidChange(_ notification:Notification){
        let row=table.selectedRow;guard !updatingCatalog,catalogRows.indices.contains(row),let p=catalogRows[row].pane,session.top != p.id else{return};session.go(p.id)
    }
    /// Called only after presentation. Tests exercise routeKey directly and never install a global monitor.
    func startKeyboard(){
        guard presentationActive,keyMonitor == nil,view.window != nil else{return}
        keyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){ [weak self] event in
            let handled=MainActor.assumeIsolated {guard let self,event.window === self.view.window else{return false};return self.routeKey(event)};return handled ? nil:event
        }
    }
    func routeKey(_ event:NSEvent)->Bool {
        guard presentationActive else{return false}
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if session.recording != nil || session.searchByKeystroke {
            if event.keyCode == 53 {session.recording=nil;session.searchByKeystroke=false;session.changed();return true}
            if event.keyCode == 51 && flags.intersection([.command,.control,.option,.shift]).isEmpty {session.record("");return true}
            guard !flags.intersection([.command,.control,.option]).isEmpty || session.recording == "send" else{return true}
            session.record(SettingsKeyCodec.combo(event));return true
        }
        if flags.contains(.command),event.charactersIgnoringModifiers == "[" {session.back();return true}
        if flags.contains(.command),event.charactersIgnoringModifiers == "]" {session.forward();return true}
        if flags.contains(.command),event.charactersIgnoringModifiers?.lowercased() == "f" {view.window?.makeFirstResponder(search);return true}
        return false
    }
    func stop(){if let displayObservation{NativeDisplayOptions.shared.removeObserver(displayObservation)};displayObservation=nil;presentationActive=false;onDialog=nil;loading?.cancel();loading=nil;if let keyMonitor{NSEvent.removeMonitor(keyMonitor)};keyMonitor=nil;session.stopPresentation()}
    isolated deinit {if let displayObservation{NativeDisplayOptions.shared.removeObserver(displayObservation)}}
    func snapshot(scale:CGFloat,fullPanel:Bool=false)->CGImage {
        loadViewIfNeeded()
        func setScale(_ v:NSView){(v as? SettingsView)?.verificationScale=scale;v.needsLayout=true;for c in v.subviews{setScale(c)}}
        setScale(view);view.needsLayout=true;view.layoutSubtreeIfNeeded();viewDidLayout();form.needsLayout=true;form.layoutSubtreeIfNeeded()
        var image:CGImage!;view.effectiveAppearance.performAsCurrentDrawingAppearance {image=NativeViewBitmap.capture(fullPanel ? form:view,scale:scale)};return image
    }
}
@MainActor enum SettingsKeyCodec {
    static func equivalent(_ combo:String)->(String,NSEvent.ModifierFlags) {
        var rest=combo,flags:NSEvent.ModifierFlags=[]
        for (mark,flag) in [("⌃",NSEvent.ModifierFlags.control),("⌥",.option),("⇧",.shift),("⌘",.command)] {
            if rest.contains(mark){flags.insert(flag);rest=rest.replacingOccurrences(of:mark,with:"")}
        }
        let special=["↩":"\r","⇥":"\t","⌫":"\u{8}","⌦":"\u{7f}","←":"\u{f702}","→":"\u{f703}","↓":"\u{f701}","↑":"\u{f700}","Space":" "]
        if rest.hasPrefix("F"),let number=Int(rest.dropFirst()),(1...35).contains(number),let scalar=UnicodeScalar(0xf704+number-1){return(String(scalar),flags)}
        return(special[rest] ?? rest.lowercased(),flags)
    }
    static func fixedCommand(_ combo:String,menu:NSMenu?)->String? {
        guard let menu else{return nil}
        let target=equivalent(combo)
        for item in menu.items {
            if let sub=item.submenu,let found=fixedCommand(combo,menu:sub){return found}
            guard !item.keyEquivalent.isEmpty,item.identifier?.rawValue.hasPrefix("shortcut.") != true else{continue}
            var flags=item.keyEquivalentModifierMask.intersection([.command,.control,.option,.shift])
            let key=item.keyEquivalent
            if key.count == 1,key != key.lowercased(){flags.insert(.shift)}
            if key.lowercased() == target.0,flags == target.1{return item.title}
        }
        return nil
    }
    static func combo(_ event:NSEvent)->String {
        let f=event.modifierFlags
        let prefix=(f.contains(.control) ? "⌃":"")+(f.contains(.option) ? "⌥":"")+(f.contains(.shift) ? "⇧":"")+(f.contains(.command) ? "⌘":"")
        let special:[UInt16:String]=[36:"↩",76:"↩",48:"⇥",51:"⌫",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",49:"Space"]
        if let scalar=event.charactersIgnoringModifiers?.unicodeScalars.first,(0xf704...0xf726).contains(scalar.value){return prefix+"F"+String(scalar.value-0xf704+1)}
        return prefix+(special[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased())
    }
}
