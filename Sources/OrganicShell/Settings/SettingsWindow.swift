import AppKit

/// A lifecycle value used by the native owner and by tests without constructing any NSWindow.
struct SettingsWindowLifecycle:Equatable {
    private(set) var installed=false,presented=false,contentAlive=false,presentationCount=0
    mutating func install(){installed=true}
    mutating func present(){guard installed else{return};presented=true;contentAlive=true;presentationCount+=1}
    mutating func close(){presented=false;contentAlive=false}
    mutating func dispose(){close();installed=false}
}

/// Install is lazy. The same window restores its autosaved frame; close releases its entire view/controller graph.
/// No application/window state is consulted by panel models. App wires Settings… (⌘,) and the account menu here.
@MainActor final class NativeSettingsWindowController:NSObject,NSWindowDelegate,NSToolbarDelegate {
    static private(set) var shared:NativeSettingsWindowController?
    static let frameAutosaveName="organic.settings"
    static let initialSize=NSSize(width:880,height:660),minimumSize=NSSize(width:760,height:480)
    let session:SettingsSession
    private(set) var lifecycle=SettingsWindowLifecycle()
    private(set) var window:NSWindow?
    private(set) var workbench:NativeSettingsWorkbench?
    private var sheetWindow:NSWindow?,sheetContent:SettingsSheetContent?,sheetID:UUID?,alertID:UUID?
    private var colorPopover:NSPopover?,colorContent:SettingsColorContent?
    private var presentationTask:Task<Void,Never>?
    private var toolbarItems:[NSToolbarItem.Identifier:NSToolbarItem]=[:]
    private var toolbarAlignmentPending=false
    private var toolbarGap:CGFloat=120
    private static let toolbarSpace=NSToolbarItem.Identifier("organic.settings.sidebarSpace")
    private static let toolbarNavigation=NSToolbarItem.Identifier("organic.settings.navigation")
    var onApplicationAction:((String)->Void)?
    private init(source:any SettingsDataSource,preferences:SettingsPreferences){session=SettingsSession(source:source,preferences:preferences);super.init();lifecycle.install()}
    @discardableResult static func install(dataSource:any SettingsDataSource,preferences:SettingsPreferences=SettingsPreferences())->NativeSettingsWindowController {
        if let shared{shared.session.setSource(dataSource);shared.workbench?.reload();return shared}
        let owner=NativeSettingsWindowController(source:dataSource,preferences:preferences);shared=owner;return owner
    }
    static func uninstall(){shared?.dispose();shared=nil}
    @objc func showSettings(_ sender:Any?=nil){show()}
    func show(pane:String?=nil){show(pane:pane,resetHistory:false)}
    func show(pane:String?,resetHistory:Bool){
        if let pane{if resetHistory{session.prepareInitialPane(pane)}else{session.openPane(pane)}}
        if window == nil {
            let w=NSWindow(contentRect:CGRect(origin:.zero,size:Self.initialSize),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            w.title=session.paneTitle;w.titleVisibility = .hidden;w.identifier = .init("organic.settings");w.titlebarAppearsTransparent=true;w.toolbarStyle = .unified
            w.contentMinSize=Self.minimumSize;w.isRestorable=false;w.isReleasedWhenClosed=false;w.standardWindowButton(.zoomButton)?.isEnabled=false
            w.setFrameAutosaveName(Self.frameAutosaveName)
            if !w.setFrameUsingName(Self.frameAutosaveName){w.center()}
            w.delegate=self;window=w
        }
        let content=acquireContent()
        window?.contentViewController=content;installToolbar(content);content.startKeyboard()
        lifecycle.present();window?.makeKeyAndOrderFront(nil)
        alignToolbar();DispatchQueue.main.async{[weak self] in self?.alignToolbar()}
        presentDialogs()
    }
    /// The same hosted graph boundary used by show(), without creating or displaying a window.
    @discardableResult func acquireContent()->NativeSettingsWorkbench {
        if let workbench{return workbench}
        let content=NativeSettingsWorkbench(session:session);workbench=content
        session.onOpenURL={url in NSWorkspace.shared.open(url)}
        session.onApplicationAction={ [weak self] action in self?.applicationAction(action) }
        content.onDialog={ [weak self] in self?.presentDialogs() }
        content.onTitleChanged={ [weak self] title in self?.window?.title=title }
        content.onSidebarWidthChanged={ [weak self] in self?.alignToolbar() }
        content.loadViewIfNeeded()
        return content
    }
    private func installToolbar(_ content:NativeSettingsWorkbench){
        guard let window,window.toolbar == nil else{return}
        let toolbar=NSToolbar(identifier:"organic.settings.toolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false
        content.toolbarContent.onLayout={ [weak self] in self?.scheduleToolbarAlignment() }
        window.toolbar=toolbar;window.titleVisibility = .hidden;window.title=session.paneTitle
    }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{[Self.toolbarSpace,Self.toolbarNavigation,.flexibleSpace]}
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(toolbar)}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem?{
        guard let content=workbench else{return nil};let item=NSToolbarItem(itemIdentifier:id);item.isBordered=false
        if id == Self.toolbarSpace{item.view=NSView(frame:CGRect(x:0,y:0,width:toolbarGap,height:1));item.minSize=CGSize(width:toolbarGap,height:1);item.maxSize=CGSize(width:toolbarGap,height:1)}
        else if id == Self.toolbarNavigation{content.toolbarContent.removeFromSuperview();item.view=content.toolbarContent;item.minSize=CGSize(width:360,height:36);item.maxSize=CGSize(width:360,height:36);item.label="Navigation and pane title"}
        else{return nil};toolbarItems[id]=item;return item
    }
    /// Native toolbar leading margins vary by macOS. Align the real capsule to the same 220+8 anchor as the
    /// windowless drawing after AppKit lays out the items. A late toolbar negotiation also invokes it; no frame timer.
    private func scheduleToolbarAlignment(){
        guard !toolbarAlignmentPending else{return};toolbarAlignmentPending=true
        DispatchQueue.main.async{[weak self] in guard let self else{return};self.toolbarAlignmentPending=false;self.alignToolbar()}
    }
    private func alignToolbar(){
        guard let plate=workbench?.navigationPlate,plate.window != nil,let spacer=toolbarItems[Self.toolbarSpace]else{return}
        let delta=(workbench?.sidebarWidth ?? 220)+7-plate.convert(.zero,to:nil).x
        guard abs(delta)>0.5,toolbarGap+delta>=0,toolbarGap+delta<=300 else{return}
        toolbarGap+=delta;spacer.minSize=CGSize(width:toolbarGap,height:1);spacer.maxSize=CGSize(width:toolbarGap,height:1);spacer.view?.frame.size.width=toolbarGap
    }
    func windowDidResize(_ notification:Notification){alignToolbar()}
    /// Existing Core event stream may call this after login/OAuth/config/capture updates. Does nothing while closed.
    func refresh(){if lifecycle.presented{workbench?.reload()}}
    private func applicationAction(_ action:String){
        if action.hasPrefix("color:"){
            colorContent?.disconnect();colorPopover?.performClose(nil)
            let content=SettingsColorContent(session:session,key:String(action.dropFirst(6))),popover=NSPopover()
            colorContent=content;colorPopover=popover;popover.contentViewController=content;popover.behavior = .transient;popover.delegate=content
            content.onClose={ [weak popover] in popover?.performClose(nil) }
            if let workbench {
                let rowID=content.key.hasSuffix("background") ? "color.background":content.key.hasSuffix("foreground") ? "color.foreground":"look.accent"
                if let row=workbench.form.rows.first(where:{$0.spec.id == rowID}),let anchor=row.control {
                    let local=content.key.hasSuffix("custom") ? CGRect(x:0,y:0,width:20,height:20):anchor.bounds
                    let rect=workbench.view.convert(local,from:anchor)
                    popover.show(relativeTo:rect,of:workbench.view,preferredEdge:.minY)
                }
            }
        } else if action == "chooseProjectFolder",let window {
            let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false
            panel.beginSheetModal(for:window){ [weak self] response in
                let accepted=response == .OK
                MainActor.assumeIsolated{guard accepted,let path=panel.url?.path else{return};self?.session.preferences.set("general.folder",.string(path))}
            }
        } else if action == "chooseSkillFolder",let window {
            let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false;panel.prompt="Install Skill"
            let scope=session.scope
            panel.beginSheetModal(for:window){ [weak self] response in
                let accepted=response == .OK
                MainActor.assumeIsolated{guard accepted,let url=panel.url,let self,self.session.scope == scope else{return};self.session.installSkillFolder(url)}
            }
        } else {onApplicationAction?(action)}
    }
    private func presentDialogs(){
        guard let window,lifecycle.presented else{return}
        if let state=session.sheet {
            if sheetID == state.id {sheetContent?.refresh();return}
            guard window.attachedSheet == nil else{return}
            sheetID=state.id
            let content=SettingsSheetContent(session:session,sheet:state);sheetContent=content
            content.loadViewIfNeeded();content.fit(in:window.contentLayoutRect.size);let child=NSWindow(contentViewController:content);sheetWindow=child
            content.onClose={ [weak self] in self?.endFormSheet() }
            window.beginSheet(child)
            if state.kind == .pair {
                presentationTask?.cancel()
                presentationTask=Task{ [weak self] in
                    try? await Task.sleep(for:.milliseconds(2600));guard !Task.isCancelled,let self else{return}
                    await self.session.completeDemoPair(id:state.id);self.sheetContent?.refresh()
                }
            }
        } else if sheetWindow != nil {endFormSheet()}
        if let confirmation=session.confirmation,alertID != confirmation.id,window.attachedSheet == nil {
            alertID=confirmation.id
            let alert=SettingsAlerts.build(confirmation)
            alert.beginSheetModal(for:window){ [weak self] response in
                let accepted=response == .alertFirstButtonReturn
                MainActor.assumeIsolated {guard let self else{return};self.alertID=nil;Task{await self.session.resolveConfirmation(id:confirmation.id,confirmed:accepted)}}
            }
        }
    }
    private func endFormSheet(){
        presentationTask?.cancel();presentationTask=nil
        if let sheetWindow{window?.endSheet(sheetWindow)}
        sheetWindow=nil;sheetContent=nil;sheetID=nil
    }
    func windowWillClose(_ notification:Notification){releaseContent()}
    /// Retire the hosted graph; shared by real close and windowless lifecycle verification.
    func releaseContent(){
        endFormSheet();colorContent?.disconnect();colorPopover?.performClose(nil);colorContent=nil;colorPopover=nil
        workbench?.stop();window?.toolbar?.delegate=nil;window?.toolbar=nil;toolbarItems=[:];workbench=nil;window?.contentViewController=nil;lifecycle.close()
    }
    func dispose(){
        if let window{windowWillClose(Notification(name:NSWindow.willCloseNotification,object:window));window.delegate=nil;window.close()}
        window=nil;lifecycle.dispose()
    }
}
