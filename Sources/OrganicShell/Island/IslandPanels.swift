import AppKit

/// Optional adapter: uses the EXACT Normie Changes/Status controller rather than a second diff renderer.
/// Retain this bridge alongside the header. It never reads a window or a scene.
@MainActor final class HeaderIslandInspectorBridge {
    let inspector:NormieInspectorController
    private var conversation:Conversation
    var isPresented:Bool { inspector.isViewLoaded && inspector.view.window != nil }
    init(conversation:Conversation,store:ConversationStore,actions:NormieActions) {
        self.conversation=conversation
        inspector=NormieInspectorController(store:store,actions:actions)
    }
    func content(for panel:HeaderIslandPanel) -> NSViewController? {
        guard panel == .status || panel == .changes else { return nil }
        if !inspector.isViewLoaded { inspector.view.frame=CGRect(x:0,y:0,width:360,height:420) }
        inspector.show(conversation)
        if panel == .status { inspector.showStatus() } else { inspector.showChanges() }; return inspector
    }
    func update(_ conversation:Conversation) {
        self.conversation=conversation
        if inspector.isViewLoaded { inspector.show(conversation) }
    }
}

@MainActor final class HeaderIslandPanelController:NSViewController {
    let panel:HeaderIslandPanel, configuration:HeaderIslandConfiguration
    var route:(HeaderIslandRoute)->Void, compact:()->Void
    init(panel:HeaderIslandPanel,configuration:HeaderIslandConfiguration,route:@escaping (HeaderIslandRoute)->Void,compact:@escaping ()->Void) {
        self.panel=panel; self.configuration=configuration; self.route=route; self.compact=compact
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let root=IslandPlane(frame:CGRect(x:0,y:0,width:360,height:420)); view=root
        let scroll=NSScrollView(frame:root.bounds); scroll.drawsBackground=false; scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true
        scroll.autoresizingMask=[.width,.height]
        let doc=IslandPlane(frame:CGRect(x:0,y:0,width:340,height:420)); scroll.documentView=doc; root.addSubview(scroll)
        root.setAccessibilityElement(true); root.setAccessibilityRole(.group); root.setAccessibilityLabel(panel.rawValue+" panel")
        var y:CGFloat=16
        func label(_ text:String,size:CGFloat=12) {
            let l=IslandLabel(labelWithString:text); l.font = .systemFont(ofSize:size); l.textColor = .labelColor
            l.isBordered=false; l.isBezeled=false; l.drawsBackground=false; l.maximumNumberOfLines=4; l.lineBreakMode = .byWordWrapping
            l.frame=CGRect(x:16,y:y,width:308,height:size == 15 ? 24:48); y+=l.frame.height+8; doc.addSubview(l)
        }
        func button(_ text:String,symbol:String,enabled:Bool=true,_ callback:@escaping ()->Void) {
            let b=IslandButton(); b.text=text; b.symbol=symbol; b.isEnabled=enabled; b.invoke=callback
            b.frame=CGRect(x:12,y:y,width:316,height:32); y+=36; doc.addSubview(b)
        }
        switch panel {
        case .subAgents:
            label("Sub-agents",size:15)
            if configuration.signals.satellites.isEmpty { label("No sub-agents yet") }
            for s in configuration.signals.satellites {
                button("\(s.face) · \(s.done ? "Finished":"Working")",symbol:s.done ? "checkmark.circle":"circle.hexagongrid") { [weak self] in self?.route(.satellite(s.id)) }
            }
        case .context:
            label("Context",size:15)
            label(configuration.signals.context.map { "\(Int(($0*100).rounded()))% used" } ?? "Usage not reported")
            label(configuration.contextDescription)
            if let limit=configuration.contextLimit { label("Context limit: "+limit) }
            button("Compact Now",symbol:"arrow.down.right.and.arrow.up.left",enabled:configuration.canCompact) { [weak self] in self?.compact() }
        case .changes:
            label("Changes",size:15); label("\(configuration.signals.files) files · +\(configuration.signals.added) −\(configuration.signals.removed)")
            label(configuration.signals.files == 0 ? "No changes":"Diff details are unavailable.")
        case .status:
            label("Status",size:15); label(configuration.signals.words)
            label("Nothing Yet")
        }
        doc.frame.size.height=max(420,y+16)
    }
}

extension HeaderIslandConfiguration {
    /// Optional Core -> value adapter. Call on semantic changes, not during driver B sampling.
    @MainActor static func conversation(_ c:Conversation,variant:HeaderIslandVariant,columnWidth:CGFloat,band:CGFloat=0,
                                        reduceMotion:Bool=false,ambient:Bool=true,isKeyWindow:Bool=true,scale:CGFloat=2,
                                        identitySymbol:String?=nil,identityTint:String?=nil) -> Self {
        var input=Self(id:c.id,title:c.title)
        input.identity = .assigned(c.identityIndex)
        if let symbol=OrbCelestialBody.allCases.first(where:{ String(describing:$0) == (identitySymbol ?? c.identitySymbol) }) { input.identity.symbol=symbol }
        if let tint=OrbTint.allCases.first(where:{ String(describing:$0) == (identityTint ?? c.identityTint) }) { input.identity.tint=tint }
        input.variant=variant; input.columnWidth=columnWidth; input.band=band
        input.activitySerial=c.orbActivity.serial
        input.signals.error=c.error.map { $0 == .stopped ? .stopped:.running }
        input.signals.approvals=c.approvals.count; input.signals.question=c.question != nil || c.userInput != nil
        input.signals.completions=c.completions; input.signals.running=c.running; input.signals.stopping=c.stopping; input.signals.stops=c.stops
        input.signals.files=c.changes.count; input.signals.added=c.changes.reduce(0) { $0+$1.added }; input.signals.removed=c.changes.reduce(0) { $0+$1.removed }
        input.signals.context = (c.isLiveConversation || c.backendThreadID != nil) && !c.contextUsageReported ? nil:c.contextShown; input.signals.compactions=c.compactions
        input.signals.satellites=c.satellites.map { .init(id:$0.id,face:$0.face,pace:c.pace,done:$0.done,finishedOrder:$0.finishedOrder) }
        input.satellitesRetired=c.satellitesRetired; input.contextDescription=c.contextDescription; input.contextLimit=c.contextLimit.map(String.init)
        input.canCompact = !c.running && !c.sending && !c.loading
        input.reduceMotion=reduceMotion; input.ambient=ambient; input.isKeyWindow=isKeyWindow; input.scale=scale
        return input
    }
}
