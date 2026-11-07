import AppKit

/// Lazy window shell. Offscreen acquisition creates only a controller + view, never an NSWindow.
@MainActor final class DebugToolWindow:NSWindowController,NSWindowDelegate {
    let toolTitle:String,size:CGSize,autosave:String
    private let factory:()->DebugPageController
    private(set) var page:DebugPageController?
    init(title:String,size:CGSize,autosave:String,factory:@escaping()->DebugPageController){toolTitle=title;self.size=size;self.autosave=autosave;self.factory=factory;super.init(window:nil)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    @discardableResult func acquireContent()->DebugPageController {
        if let page{return page};let page=factory();self.page=page;_ = page.view;page.view.frame=CGRect(origin:.zero,size:size);page.activate();page.view.needsLayout=true;page.view.layoutSubtreeIfNeeded();return page
    }
    func releaseContent(){page?.deactivate();page?.view.removeFromSuperview();window?.contentViewController=nil;page=nil}
    func toggle(){if window?.isVisible == true{window?.orderOut(nil);releaseContent();return};let page=acquireContent()
        if window == nil {
            let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title=toolTitle;window.autorecalculatesKeyViewLoop=true;window.isReleasedWhenClosed=false;window.isRestorable=false;window.contentMinSize=CGSize(width:min(size.width,toolTitle == "Debug" ? 380:700),height:min(size.height,480));window.setFrameAutosaveName(autosave);window.delegate=self;self.window=window
            if !window.setFrameUsingName(autosave){window.center()}
        }
        window?.contentViewController=page;window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification:Notification){releaseContent()}
    override func close(){releaseContent();super.close()}
}

/// Retain once in App. Scene hosts are weak and must be retained by the window/scene owner.
@MainActor final class DebugTools:NSObject {
    enum Tool:Int,CaseIterable {case debug,orb,transition,spring,spotlight
        var title:String{["Debug","Orb Lab","Transition Lab","Spring Lab","Spotlight Lab"][rawValue]}
        var key:String{["d","o","t","p",""][rawValue]}
    }
    let session:DebugSession
    weak var transitionHost:(any TransitionLabHost)?
    weak var springHost:(any SpringLabHost)?
    private var windows:[Tool:DebugToolWindow]=[:]
    init(store:ConversationStore,mock:MockReplay?,initiallyPaused:Bool=false,transitionHost:(any TransitionLabHost)?=nil,springHost:(any SpringLabHost)?=nil){session=DebugSession(store:store,replay:mock,initiallyPaused:initiallyPaused);self.transitionHost=transitionHost;self.springHost=springHost;super.init()}
    func controller(_ requested:Tool)->DebugToolWindow {
        // Spring / Spotlight share one lab window and one transport lifetime.
        let tool:Tool=requested == .spotlight ? .spring:requested
        if let existing=windows[tool]{return existing}
        let session=session
        let size:CGSize=switch tool{case .debug:CGSize(width:440,height:760);case .orb:CGSize(width:1100,height:740);case .transition:CGSize(width:1240,height:780);default:CGSize(width:1320,height:900)}
        let controller=DebugToolWindow(title:tool.title,size:size,autosave:"organic."+(tool == .debug ? "debug":tool.title.replacingOccurrences(of:" ",with:""))){[weak self] in
            switch tool{case .debug:return DebugPanelPage(session:session);case .orb:return OrbLabPage(store:session.store);case .transition:return TransitionLabPage(store:session.store,host:self?.transitionHost);default:return SpringLabPage(store:session.store,host:self?.springHost)}
        };windows[tool]=controller;return controller
    }
    func toggleDebug(){controller(.debug).toggle()}
    func toggleOrbLab(){controller(.orb).toggle()}
    func toggleTransitionLab(){controller(.transition).toggle()}
    func toggleSpringLab(){let c=controller(.spring);c.toggle();(c.page as? SpringLabPage)?.setSpotlight(false)}
    func showSpotlightLab(){let c=controller(.spotlight);if c.window?.isVisible != true{c.toggle()};(c.page as? SpringLabPage)?.setSpotlight(true)}
    func menuItems()->[NSMenuItem]{Tool.allCases.map{tool in let item=NSMenuItem(title:tool.title+"…",action:#selector(openTool(_:)),keyEquivalent:tool.key);item.keyEquivalentModifierMask=tool.key.isEmpty ? []:[.shift,.option,.command];item.target=self;item.tag=tool.rawValue;return item}}
    @objc private func openTool(_ item:NSMenuItem){guard let tool=Tool(rawValue:item.tag)else{return};switch tool{case .debug:toggleDebug();case .orb:toggleOrbLab();case .transition:toggleTransitionLab();case .spring:toggleSpringLab();case .spotlight:showSpotlightLab()}}
    func releaseAllContent(){windows.values.forEach{$0.releaseContent()}}
    /// One app-level source; showing or closing a tool window never calls this.
    @discardableResult func startPlayback() -> Bool { session.startPlayback() }
    func bindTuning(to host: any DebugTuningHost) -> DebugTuningBinding { DebugTuningBinding(tuning:session.tuning,host:host) }
    func shutdown(){releaseAllContent();session.stopClock();windows.values.forEach{$0.close()};windows=[:]}
}
