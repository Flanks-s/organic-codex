import AppKit

/// Metadata and draft attachment actions for the owned headless browser. No WebView or mock page.
@MainActor final class BrowserLiveContent: NSView {
    static let label = "Codex background browser"
    let title = NSTextField(labelWithString: "")
    let address = NSTextField(labelWithString: "")
    let issue = NSTextField(wrappingLabelWithString: "")
    let ask = BrowserActionButton(frame:.zero)
    let tabPanel = BrowserLivePanel()
    let scroll = NSScrollView()
    let rows = BrowserLiveRows()
    let newTab = BrowserActionButton(frame:.zero)
    private(set) var tabButtons: [String:BrowserActionButton] = [:]
    private(set) var closeButtons: [String:BrowserActionButton] = [:]
    private var previousTabs: [BrowserLiveTab] = []
    var action: ((BrowserMockAction)->Void)?
    var askPage: (() -> Void)?
    var tabsHover: ((Bool) -> Void)?
    override var isFlipped: Bool {true}
    override init(frame:CGRect) {
        super.init(frame:frame);setAccessibilityRole(.group);setAccessibilityLabel(Self.label)
        for view in [title,address,issue,ask] {addSubview(view)}
        title.font = .systemFont(ofSize:20,weight:.semibold);address.font = .systemFont(ofSize:13)
        address.lineBreakMode = .byTruncatingMiddle;address.textColor = .secondaryLabelColor
        issue.textColor = .secondaryLabelColor
        ask.caption="Ask about this page";ask.configure(label:"Ask about this page",enabled:true)
        ask.invoke={ [weak self] in self?.askPage?() }
        tabPanel.addSubview(scroll);tabPanel.addSubview(newTab);scroll.documentView=rows;scroll.hasVerticalScroller=true
        scroll.drawsBackground=false;newTab.caption="New Tab";newTab.configure(label:"New Tab",enabled:true)
        newTab.invoke={ [weak self] in self?.action?(.newTab) }
        tabPanel.hover={ [weak self] inside in self?.tabsHover?(inside) }
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is unsupported")}
    func configure(_ state:BrowserSessionState) {
        title.stringValue=state.selectedLiveTab?.title ?? ""
        address.stringValue=state.selectedLiveTab?.url ?? ""
        issue.stringValue=state.issue ?? ""
        if previousTabs != state.liveTabs {
            for button in Array(tabButtons.values)+Array(closeButtons.values) {button.retire();button.removeFromSuperview()}
            tabButtons=[:];closeButtons=[:]
            for (index,tab) in state.liveTabs.enumerated() {
                let button=BrowserActionButton(frame:CGRect(x:4,y:Double(index*32),width:252,height:30))
                button.caption=tab.title.isEmpty ? tab.url:tab.title;button.textAlignment = .left
                button.configure(label:button.caption ?? tab.url,enabled:true,selected:tab.id == state.selectedTabID)
                button.invoke={ [weak self] in self?.action?(.selectTab(tab.id)) }
                let close=BrowserActionButton(frame:CGRect(x:260,y:Double(index*32+4),width:24,height:24))
                close.symbol="xmark";close.configure(label:"Close Tab",enabled:true)
                close.invoke={ [weak self] in self?.action?(.closeTab(tab.id)) }
                rows.addSubview(button);rows.addSubview(close);tabButtons[tab.id]=button;closeButtons[tab.id]=close
            }
            rows.frame=CGRect(x:0,y:0,width:288,height:Double(max(1,state.liveTabs.count*32)));previousTabs=state.liveTabs
        }
        for tab in state.liveTabs {tabButtons[tab.id]?.configure(label:tab.title.isEmpty ? tab.url:tab.title,enabled:true,selected:tab.id == state.selectedTabID)}
    }
    func placePage(_ frame:CGRect,visible:Bool,alpha:Double) {
        self.frame=frame;isHidden = !visible;alphaValue=alpha;setAccessibilityHidden(!visible)
        title.frame=CGRect(x:24,y:32,width:max(1,frame.width-48),height:32)
        address.frame=CGRect(x:24,y:76,width:max(1,frame.width-48),height:24)
        ask.frame=CGRect(x:24,y:120,width:190,height:32);issue.frame=CGRect(x:24,y:170,width:max(1,frame.width-48),height:70)
        ask.participates=visible
    }
    func placeTabs(_ frame:CGRect,visible:Bool) {
        tabPanel.frame=frame;tabPanel.isHidden = !visible;tabPanel.setAccessibilityHidden(!visible)
        scroll.frame=CGRect(x:6,y:34,width:max(1,frame.width-12),height:max(1,frame.height-81))
        newTab.frame=CGRect(x:6,y:frame.height-40,width:max(1,frame.width-12),height:32)
        for button in Array(tabButtons.values)+Array(closeButtons.values)+[newTab] {button.participates=visible}
    }
    func retire() {
        for button in Array(tabButtons.values)+Array(closeButtons.values)+[ask,newTab] {button.retire()}
        tabPanel.removeFromSuperview();removeFromSuperview();setAccessibilityHidden(true)
    }
}
@MainActor final class BrowserLiveRows: NSView {override var isFlipped:Bool {true}}
@MainActor final class BrowserLivePanel: NSView {
    var hover: ((Bool)->Void)?
    private var area: NSTrackingArea?
    override var isFlipped: Bool {true}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area {removeTrackingArea(area)}
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
        self.area=area;addTrackingArea(area)
    }
    override func mouseEntered(with event:NSEvent) {hover?(true)}
    override func mouseExited(with event:NSEvent) {hover?(false)}
}
