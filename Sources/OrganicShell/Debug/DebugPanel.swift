import AppKit
import UniformTypeIdentifiers

@MainActor final class DebugPanelPage:DebugFormPage {
    let session:DebugSession
    private var observation:UUID?
    private var pausedButton:DebugButton!,stepButton:DebugButton!,backgroundButton:DebugButton!,targetButton:DebugButton!
    private var injectionButtons:[DebugButton]=[],parameterSliders:[String:DebugSlider]=[:],toggleButtons:[String:DebugButton]=[:]
    private var stateLabel=DebugPaint.label("",size:11),notice=DebugPaint.label("",size:11)
    init(session:DebugSession){self.session=session;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func loadView(){
        super.loadView();view.setAccessibilityLabel("Debug panel")
        form.heading("Mock Engine")
        pausedButton=form.toggle("Paused",value:session.paused){[weak self] in guard let self else{return};_ = session.setPaused(!session.paused)}
        stepButton=form.button("Step"){[weak self] in _ = self?.session.step()}
        backgroundButton=form.toggle("Background sub-agent events",value:session.backgroundEvents){[weak self] in guard let self else{return};_ = session.setBackgroundEvents(!session.backgroundEvents)}
        form.heading("Inject Event")
        targetButton=form.menu("Conversation",choices:[],selection:0){[weak self] index in guard let self,session.store.conversations.indices.contains(index)else{return};_ = session.select(session.store.conversations[index].id)}
        let grid=DebugGrid()
        for event in DebugInjection.allCases{let button=DebugButton(event.rawValue){[weak self] in _ = self?.session.inject(event)};injectionButtons.append(button);grid.append(button)}
        form.add(grid,height:185)
        injectionButtons.append(form.button("New Conversation Arrives"){[weak self] in _ = self?.session.arrive()})
        form.heading("State");stateLabel.maximumNumberOfLines=0;stateLabel.lineBreakMode = .byWordWrapping;form.add(stateLabel,height:130)
        notice.maximumNumberOfLines=0;notice.lineBreakMode = .byWordWrapping;notice.textColor = .secondaryLabelColor;form.add(notice,height:58)
        let groups=["Mock engine","Dock","Spring · Focused / Split","Peek","Auto layout","Spring · Auto columns","Brief ↔ full","Spring · queue","Spring · Normie ↔ Organic","Orb","Orb · satellites","Orb · red alert","Spring · orb hover","Spring · approval card","Tear · drag","Spring · tear","Window grow · route A"]
        for group in groups {
            form.heading(group)
            for parameter in DebugTuningParameter.all.filter({$0.group == group}){
                let slider=form.slider(parameter.label,value:session.tuning[parameter],range:parameter.range){[weak self] value in guard let self else{return};_ = session.tuning.set(parameter.key,value)}
                parameterSliders[parameter.key]=slider
            }
        }
        form.heading("Switches")
        for (key,title) in [("simulateReduceMotion","Simulate Reduce Motion"),("playfulSummaries","Playful summaries"),("organicFullBleed","Full-bleed Organic"),("identityLiquid","Orb liquid in identity colour"),("fullyFocused","Fully Focused"),("forceClickPeek","Force Click Peek")] {
            toggleButtons[key]=form.toggle(title,value:session.tuning.toggles[key] ?? false){[weak self] in guard let self else{return};_ = session.tuning.toggle(key);toggleButtons[key]?.checked=session.tuning.toggles[key] ?? false}
        }
        form.button("Copy JSON"){[weak self] in guard let self else{return};NSPasteboard.general.clearContents();NSPasteboard.general.setString(String(decoding:session.tuning.exportJSON(),as:UTF8.self),forType:.string);notice.stringValue="Tuning JSON copied. No conversation or request content is exported."}
        form.button("Export JSON…"){[weak self] in self?.export()}
        form.button("Reset All"){[weak self] in guard let self else{return};session.tuning.reset();for p in DebugTuningParameter.all{parameterSliders[p.key]?.set(session.tuning[p])};for (key,b) in toggleButtons{b.checked=session.tuning.toggles[key] ?? false}}
        form.note("Mock tuning applies to the shared playback source. Scene hosts subscribe to the tuning snapshot; Reset All restores parameters, never conversation history.",height:44)
        refresh()
    }
    override func activate(){super.activate();_ = view;session.onChange={[weak self] in self?.refresh()};observation=session.store.observe{[weak self] _ in self?.refresh()};refresh()}
    override func deactivate(){super.deactivate();if let observation{session.store.removeObserver(observation)};observation=nil;session.onChange=nil}
    func refresh(){
        guard isViewLoaded else{return};let demo=session.canInject
        pausedButton.checked=session.paused;pausedButton.isEnabled=demo;stepButton.isEnabled=demo && session.paused;backgroundButton.checked=session.backgroundEvents;backgroundButton.isEnabled=demo
        targetButton.choices=session.store.conversations.map{$0.id+" · "+$0.title};targetButton.selection=session.store.conversations.firstIndex(where:{$0.id == session.selectedID}) ?? 0;targetButton.valueText=session.selected?.title
        for b in injectionButtons{b.isEnabled=demo && session.selected?.isLiveConversation != true}
        for p in DebugTuningParameter.all { parameterSliders[p.key]?.set(session.tuning[p]); parameterSliders[p.key]?.isEnabled = !p.key.hasPrefix("mock.") || demo }
        for (key,button) in toggleButtons { button.checked = session.tuning.toggles[key] ?? false }
        stateLabel.stringValue=session.store.conversations.prefix(8).map{c in "\(c.id) · \(c.running ? "running":"idle") · approvals \(c.approvals.count) · \(c.question == nil ? "":"? ")\(c.error == nil ? "":"! ")ctx \(c.contextPercent)% · sub \(c.satellites.filter{!$0.done}.count)/\(c.satellites.count)"}.joined(separator:"\n")
        notice.stringValue=demo ? "Demo injection only. Step advances the actual MockReplay by one tick. Playback and background events share the same clock, including before this panel opens.":"Live Core: mock playback and business injection are disabled. Local visual calibration remains available."
    }
    private func export(){guard let window=view.window else{return};let panel=NSSavePanel();panel.nameFieldStringValue="organic-tuning.json";panel.allowedContentTypes=[.json];panel.beginSheetModal(for:window){[weak self] result in MainActor.assumeIsolated{guard result == .OK,let url=panel.url,let self else{return};do{try self.session.tuning.exportJSON().write(to:url,options:.atomic)}catch{self.notice.stringValue=error.localizedDescription}}}}
}
