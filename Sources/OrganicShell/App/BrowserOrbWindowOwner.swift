import AppKit
import QuartzCore

@MainActor private final class BrowserHostPlane: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point); return hit === self ? nil : hit
    }
}

/// One window's location and presentation lease. The App's replay remains the sole data source.
@MainActor final class BrowserOrbWindowOwner: BrowserHostPort, BrowserDockPort {
    private weak var window: OrganicWindow?
    let replay: any BrowserSessionDriver
    private let animateAdmission: Bool
    private var captureTask: Task<Void,Never>?
    private var captureID: UUID?
    private let began: Double
    private(set) var browser: BrowserIslandPresentation?
    private(set) var earth: BrowserHostEarth?
    private var images: BrowserBodyImages?
    private var plane: BrowserHostPlane?
    private var returning: OrbComponent?
    private var returnButton: BrowserActionButton?
    private(set) var composer: BrowserMockComposer?
    private var mockDraft = ""
    private(set) var mockSubmissions: [String] = []
    private var attachment: BrowserColumnAttachment?
    private weak var borrowedColumn: ColumnNode?
    private weak var savedResponder: NSResponder?
    private var preparation: Task<Void, Never>?, renderTask: Task<Void, Never>?
    private var retirements: [Task<Void, Never>] = []
    private var retirementCount = 0
    private var epoch = 0
    private var seenHome: Set<String> = []
    private let initialHome: Set<String>
    private var retainedEarthMotion: BrowserEarthMotion?
    private var modeSuspended = false
    private var scenarioObservation: UUID?
    private var pendingScenario: BrowserMockScene?
    private var queuedToggle = false
    private var admission: Spring?,admissionBegan=0.0
    private var exitPicture: BrowserDockExitPicture?,exitSpring: Spring?,exitBegan=0.0
    private var exitRect=CGRect.zero
    private var exitCompletion: (() -> Void)?
    var isExiting: Bool {exitSpring != nil}
    private(set) var full = false
    private(set) var disposed = false
    private(set) var sampledFrames = 0
    var visibilityOverride: Bool?
    var reduceOverride: Bool?
    var ready: Bool { browser != nil && preparation == nil }
    var pendingTaskCount: Int { (preparation == nil ? 0 : 1) + (renderTask == nil ? 0 : 1) + (captureTask == nil ? 0 : 1) + retirementCount }
    var now: Double { max(0, (window?.scene.now() ?? began)-began) }
    private var reduced: Bool { reduceOverride ?? Motion.reduce }
    init(window: OrganicWindow, replay: any BrowserSessionDriver, animateAdmission: Bool = true) {
        self.window = window; self.replay = replay;self.animateAdmission=animateAdmission; began = window.scene.now()
        initialHome=Set(replay.store.state.homeEvents.map {"\($0.sessionGeneration):\($0.eventID)"})
    }
    func mount() {
        guard let window, !disposed else { return }
        window.scene.browserPort = self; window.scene.dock.browserDockPort = self
        window.shell.onBrowserModeWillChange = { [weak self] _ in self?.modeSuspended = true; self?.hide() }
        if projection() != nil {
            if animateAdmission {
                window.scene.transition(to:window.scene.members,current:window.scene.current,scheme:window.scene.scheme,
                    spring:Tuning.shared.autoSpring,reason:"browser-admit")
            } else {window.scene.resize(to:window.scene.size,live:false)}
        }
        update()
    }
    func project(members: [Conversation], current: String, scheme: AutoScene.Scheme, size: CGSize,
                 metrics: AutoLayout.Metrics, scale: CGFloat, protected: (AutoLayout, [String])?,
                 hasConstraint: Bool, hasLease: Bool) -> (AutoLayout, [String])? {
        guard !disposed, !modeSuspended, window?.shell.mode == .organic else { return protected }
        let result = BrowserHostLayout.make(ids: members.map(\.id), current: current, scheme: scheme, size: size,
            metrics: metrics, scale: scale, hasConstraint: hasConstraint, hasLease: hasLease)
        return result.map { ($0.layout, $0.order) } ?? protected
    }
    private func projection() -> BrowserHostLayout? {
        guard !disposed, !modeSuspended, let window, window.shell.mode == .organic, window.browserCanPresent,
              replay.enabled else { return nil }
        let scene = window.scene, facts = scene.dock.trashLeaseFacts()
        return BrowserHostLayout.make(ids: scene.members.map(\.id), current: scene.current, scheme: scene.scheme,
            size: scene.size, metrics: scene.metrics, scale: scene.scale,
            hasConstraint: scene.orbTrash.constraint.map { _ in true } ?? false,
            hasLease: facts.tide != nil || facts.addToken != nil)
    }
    func installed(in scene: AutoScene) { update() }
    func resized(in scene: AutoScene) { update() }
    func committed(in scene: AutoScene, layout: AutoLayout) {
        // Called after orbTrash.committed. Read its final certificate without touching membership or trash revision.
        guard projection() != nil, borrowedColumn?.conversation.id == nil || borrowedColumn?.conversation.id == scene.current else { hide(); return }
        wake()
    }
    func modeChanged(_ mode: WindowShell.Mode) { modeSuspended = mode != .organic; update() }
    func visibilityChanged() { update(); wake() }
    private func update() {
        guard let window, projection() != nil else { hide(); return }
        let visible = visibilityOverride ?? (window.window.isVisible && !window.window.isMiniaturized && window.window.occlusionState.contains(.visible))
        guard visible else { hide(); return }
        if browser == nil && preparation == nil { prepare() }
        if let browser { browser.backing = Int(window.scene.scale); browser.reduceMotion = reduced; layout(browser) }
    }
    private func prepare() {
        guard let window else { return }
        epoch += 1; let token = epoch
        let images = BrowserBodyImages(); self.images = images
        let earth = BrowserHostEarth(resources: images.resources,retainedMotion:retainedEarthMotion); self.earth = earth
        preparation = Task { @MainActor [weak self] in
            do {
                try await images.prepare(); try await earth.prepare(scale: Int(window.scene.scale))
                try Task.checkCancellation()
                guard let self, !self.disposed, self.epoch == token else { return }
                guard self.projection() != nil else { self.hide();return }
                for event in self.replay.store.state.homeEvents where self.seenHome.insert("\(event.sessionGeneration):\(event.eventID)").inserted {
                    if self.replay.isLive && !self.initialHome.contains("\(event.sessionGeneration):\(event.eventID)") {
                        earth.receive(event,at:self.now,reduced:self.reduced,utcOffset:TimeZone.current.secondsFromGMT())
                    } else {
                        earth.adoptHomeSnapshot(event,at:self.now,reduced:self.reduced,utcOffset:TimeZone.current.secondsFromGMT())
                    }
                }
                let browser = BrowserIslandPresentation(replay: self.replay, images: images)
                browser.liveAskPage={ [weak self] in self?.askLivePage() }
                browser.hostFull = false; browser.hostNow = { [weak self] in self?.now ?? 0 }
                browser.hostWake = { [weak self] in self?.wake() }
                browser.hostOption = { [weak self] in self?.toggleFull() }
                browser.hostAction = { [weak self] action in
                    guard let self else { return true }
                    if action == .optionOpen { self.toggleFull(); return true }
                    switch action {
                    case .siteInformation, .manageCookies, .cookieBack, .done, .background, .external, .extensions, .options:
                        self.browser?.motion.input(.action(action), at: self.now); self.browser?.sample(at: self.now); return true
                    default: return false
                    }
                }
                browser.hostEvent = { [weak self] state, _ in self?.receiveHomes(state) }
                browser.resetHost(at: self.now)
                let plane = BrowserHostPlane(frame: window.root.bounds); plane.autoresizingMask = [.width, .height]
                plane.addSubview(browser); window.root.addSubview(plane)
                self.plane = plane; self.browser = browser
                self.preparation = nil; self.layout(browser)
                if !self.reduced && self.animateAdmission {
                    let spring=Tuning.shared.autoSpring
                    self.admission=Spring(from:0,to:1,response:spring.response,damping:spring.damping,
                        epsilon:Spring.restEpsilon/56);self.admissionBegan=self.now
                }
                self.frame(at: window.scene.now()); self.wake()
                if let scenario=self.pendingScenario {self.pendingScenario=nil;self.playScenario(scenario)}
            } catch {
                await earth.dispose();images.dispose()
                guard let self, self.epoch == token else { return }
                self.preparation = nil; self.hide()
            }
        }
    }
    private func layout(_ browser: BrowserIslandPresentation) {
        guard let window, let projected = projection(), let index = projected.order.firstIndex(of: window.scene.current),
              projected.layout.columns.indices.contains(index) else { return }
        let column = projected.layout.columns[index]
        let header=window.scene.nodes[window.scene.current]?.island
        let headerY=header.map {$0.frame.minY+$0.geometry.planet.midY} ?? BrowserIslandMetrics.center.y
        let delta = CGPoint(x: column.midX-BrowserIslandMetrics.center.x, y: headerY-BrowserIslandMetrics.center.y)
        browser.setFrameOrigin(delta)
        let dockFrame=window.scene.dock.browserSlotFrame(projected.dock)
        browser.motion.hostDockCenter = CGPoint(x: dockFrame.midX-delta.x, y: dockFrame.midY-delta.y)
        browser.motion.hostDockDiameter=dockFrame.width
        browser.hostPageFrame = CGRect(x: column.minX-delta.x+14, y: 150, width: max(1,column.width-28),
                                       height: max(1,projected.layout.bars[index].minY-delta.y-162))
        browser.motion.available = CGRect(x: column.minX-delta.x+4, y: -delta.y, width: max(1,column.width-8), height: projected.layout.bars[index].minY-4)
        images?.hostLL = CGPoint(x: projected.layout.me.midX-delta.x, y: projected.layout.me.midY-delta.y)
    }
    func toggleFull() {
        guard !disposed,!isExiting, let window, projection() != nil, let browser,
              !window.scene.isDragging,!window.scene.isTearing,!window.shell.modeContentInputBlocked,
              window.scene.composers.modeContentCanHandoff,
              let column = window.scene.nodes[window.scene.current] else { return }
        if window.scene.isMoving {queuedToggle.toggle();wake();return}
        if let editor=window.window.firstResponder as? NSTextView,editor.hasMarkedText() {return}
        if !full && attachment == nil {
            if let editor = window.window.firstResponder as? NSTextView, editor.hasMarkedText() { return }
            savedResponder = window.window.firstResponder
            let attachment = BrowserColumnAttachment(column: column)
            column.browserAttachment = attachment; self.attachment = attachment; borrowedColumn = column
            window.window.makeFirstResponder(window.root)
            attachment.cover(); window.scene.dock.setHidden(column.conversation.id, true)
            window.scene.dock.items[column.conversation.id]?.glass.isHidden=true
            let orb = OrbComponent(id: "browser.return."+column.conversation.id)
            orb.configure(makeOrbConfiguration(column.conversation,drawingSize:56,backingScale:window.scene.scale,
                reduceMotion:reduced,ambient:false,isKeyWindow:window.window.isKeyWindow))
            if let plane { for v in [orb.backView,orb.glassView,orb.frontView] { plane.addSubview(v,positioned:.below,relativeTo:browser) } }
            returning = orb
            let button = BrowserActionButton(frame:.zero);button.configure(label:column.conversation.title,enabled:true)
            button.drawsHighlight=false;button.optionInvoke={ [weak self] in self?.toggleFull() }
            plane?.addSubview(button);returnButton=button
            if !replay.isLive {
                let composer=BrowserMockComposer();composer.field.stringValue=mockDraft
                composer.submit={ [weak self] text in self?.mockSubmissions.append(text) }
                composer.isHidden=true;plane?.addSubview(composer);self.composer=composer
            }
        }
        full.toggle(); browser.setHostFull(full, at: now);admission=nil;browser.motion.hostAdmissionFrame=nil
        if reduced && !full { restoreColumn() }
        wake(); frame(at: window.scene.now())
    }
    func frame(at time: Double) {
        guard !disposed, let window else { return }
        if let exitSpring {
            let elapsed=time-began-exitBegan,q=max(0,exitSpring.sample(elapsed).value)
            exitPicture?.frame=CGRect(x:exitRect.midX-exitRect.width*q/2,y:exitRect.midY-exitRect.height*q/2,
                width:exitRect.width*q,height:exitRect.height*q)
            if elapsed>=exitSpring.duration {
                let completion=exitCompletion;exitCompletion=nil;self.exitSpring=nil
                exitPicture?.removeFromSuperview();exitPicture=nil;retire();completion?()
            } else if !window.scene.manualSettle {window.scene.runClock(until:time+1.0/30)}
            return
        }
        guard let browser else {update();return}
        guard projection() != nil else { hide(); return }
        if queuedToggle,!window.scene.isMoving {queuedToggle=false;toggleFull()}
        sampledFrames += 1; let local = max(0,time-began)
        layout(browser); browser.reduceMotion = reduced
        if let admission {
            let q=max(0,admission.sample(local-admissionBegan).value),target=browser.motion.hostDockCenter ?? BrowserIslandMetrics.dock
            browser.motion.hostAdmissionFrame=CGRect(x:target.x-browser.motion.hostDockDiameter*q/2,
                y:target.y-browser.motion.hostDockDiameter*q/2,width:browser.motion.hostDockDiameter*q,height:browser.motion.hostDockDiameter*q)
            if local-admissionBegan>=admission.duration {self.admission=nil;browser.motion.hostAdmissionFrame=nil}
            browser.satellites.back.opacity=Float(min(1,q));browser.satellites.front.opacity=Float(min(1,q))
        }
        browser.sample(at: local)
        if let returning {
            returning.setFrame(browser.motion.mercuryFrame.offsetBy(dx:browser.frame.minX,dy:browser.frame.minY))
            returnButton?.frame = returning.glassView.frame
        }
        if let composer,let projected=projection(),let index=projected.order.firstIndex(of:window.scene.current),projected.layout.bars.indices.contains(index) {
            composer.frame=projected.layout.bars[index];composer.layoutSubtreeIfNeeded()
            composer.isHidden = !browser.motion.pageVisible;composer.alphaValue=browser.motion.pagePresence
            let interactive=full && browser.motion.flightBegan == nil
            composer.setInteractive(interactive)
        }
        if !full, browser.motion.flightBegan == nil { restoreColumn() }
        let frame = browser.motion.earthFrame.offsetBy(dx:browser.frame.minX,dy:browser.frame.minY)
        let light = BodyProfile.current.quantizedDirection(Float(atan2(frame.midY-window.scene.layout.me.midY,
            window.scene.layout.me.midX-frame.midX)*180 / .pi)).degrees
        let outer=Float(max(32,frame.width))
        let scale = Int(window.scene.scale)
        if let earth, renderTask == nil, earth.needsSample || earth.needsRender(outer:outer,scale:scale,light:light) {
            let token = epoch
            renderTask = Task { @MainActor [weak self] in
                try? await earth.sample(at:local,outer:outer,scale:scale,light:light,reduced:self?.reduced ?? true)
                guard let self, self.epoch == token, !self.disposed else { return }
                self.browser?.earthImageOverride=earth.image;self.browser?.needsDisplay=true;self.renderTask=nil
                if earth.needsSample {self.wake()}
            }
        }
        if queuedToggle || admission != nil || browser.motion.needsSamples || browser.satellites.busy || earth?.needsSample == true { wake() }
    }
    private func receiveHomes(_ state: BrowserSessionState) {
        for event in state.homeEvents where seenHome.insert("\(event.sessionGeneration):\(event.eventID)").inserted {
            earth?.receive(event,at:now,reduced:reduced,utcOffset:TimeZone.current.secondsFromGMT())
        }
        wake()
    }
    func prepareForSceneInput() {
        guard full || attachment != nil else {return}
        full=false;browser?.hostFull=false;browser?.resetHost(at:now);restoreColumn();wake()
    }
    private func wake() {
        guard !disposed, browser != nil, let window, !window.scene.manualSettle else { return }
        window.scene.runClock(until:window.scene.now()+1.0/30)
    }
    func playScenario(_ scene:BrowserMockScene) {
        guard !replay.isLive else {return}
        guard let browser else {pendingScenario=scene;update();return}
        if let scenarioObservation {replay.removeInputObserver(scenarioObservation)}
        let startsFull=scene != .dock && scene != .open
        if full != startsFull {toggleFull()}
        browser.localInput(.reset)
        scenarioObservation=replay.observeInputs { [weak self] input,_ in
            guard let self,self.browser != nil,!self.disposed else {return}
            if input == .action(.optionOpen) {self.toggleFull()}
            else {self.browser?.localInput(input)}
            self.wake()
        }
        wake()
    }
    func hidesGlass(_ glass: NSGlassEffectView) -> Bool { attachment?.covers == true && borrowedColumn.map { window?.scene.dock.items[$0.conversation.id]?.glass === glass } == true }
    func coversMember(_ id: String) -> Bool { attachment?.covers == true && borrowedColumn?.conversation.id == id }
    private func restoreColumn() {
        attachment?.restore();borrowedColumn?.browserAttachment=nil
        if let id=borrowedColumn?.conversation.id {window?.scene.dock.setHidden(id,false)}
        if let column=borrowedColumn,let window {column.placeIsland(column.rect.target,shown:true);if let savedResponder {window.window.makeFirstResponder(savedResponder)}}
        attachment=nil;borrowedColumn=nil;savedResponder=nil
        if let composer {mockDraft=composer.field.stringValue;composer.retire()};composer=nil
        returning?.dispose();returning=nil;returnButton?.retire();returnButton?.removeFromSuperview();returnButton=nil
    }
    private func hide() {
        epoch += 1;full=false
        admission=nil;queuedToggle=false
        if let scenarioObservation {replay.removeInputObserver(scenarioObservation)};scenarioObservation=nil;pendingScenario=nil
        let oldPreparation=preparation,oldRender=renderTask,oldCapture=captureTask
        captureTask?.cancel();captureTask=nil;captureID=nil
        preparation?.cancel();preparation=nil;renderTask?.cancel();renderTask=nil
        restoreColumn();browser?.dispose();browser?.removeFromSuperview();browser=nil
        plane?.removeFromSuperview();plane=nil
        if let earth {retainedEarthMotion=earth.frozenMotion(at:now)}
        let oldEarth=earth, oldImages=images;earth=nil;images=nil
        if oldEarth != nil || oldImages != nil {
            retirementCount += 1
            retirements.append(Task { @MainActor [weak self] in
                await oldEarth?.dispose();await oldPreparation?.value;await oldRender?.value;await oldCapture?.value
                oldImages?.dispose();self?.retirementCount -= 1
            })
        }
    }
    private func askLivePage() {
        guard let window,let source=replay as? LiveBrowserSource,captureTask == nil,!disposed else {return}
        let id=UUID();captureID=id
        captureTask=Task { @MainActor [weak self,weak window] in
            guard let window else {return}
            await BrowserLiveDelivery.attachPage(from:window,source:source)
            if self?.captureID == id {self?.captureTask=nil;self?.captureID=nil}
        }
    }
    func beginDisable(_ completion:@escaping()->Void) {
        guard !disposed,!isExiting else {return}
        func retainRemoval(_ scene: AutoScene) {
            let generation = scene.generation, end = scene.ends, settled = scene.settles.count
            let closingWindow = self.window
            retirementCount += 1
            retirements.append(Task { @MainActor [weak self, weak scene, weak closingWindow] in
                defer { self?.retirementCount -= 1 }
                guard let scene, let closingWindow, !closingWindow.isClosed,
                      scene.generation == generation else { return }
                if scene.manualSettle {
                    if let owner = self, let spring = owner.exitSpring {
                        owner.frame(at: owner.began + owner.exitBegan + spring.duration + 0.001)
                    }
                    guard scene.generation == generation else { return }
                    // The original endpoint routine samples the Dock at infinity and restores its native content.
                    scene.settle(); scene.clock.invalidate()
                } else {
                    while !closingWindow.isClosed, scene.generation == generation,
                          scene.now() < end || scene.settles.count <= settled {
                        do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                    }
                }
            })
        }
        guard !reduced,let window,let browser,let image=earth?.image else {
            let scene=window?.scene
            retire()
            if let scene {
                scene.transition(to:scene.members,current:scene.current,scheme:scene.scheme,
                    spring:Tuning.shared.autoSpring,reason:"browser-remove")
                if reduced {scene.settle();scene.clock.invalidate()}
                else { retainRemoval(scene) }
            }
            completion();return
        }
        let frame=browser.motion.earthFrame.offsetBy(dx:browser.frame.minX,dy:browser.frame.minY)
        hide();window.scene.browserPort=nil;window.shell.onBrowserModeWillChange=nil
        let picture=BrowserDockExitPicture(image:image,frame:frame);window.root.addSubview(picture)
        exitPicture=picture;exitRect=frame;exitBegan=now;exitCompletion=completion
        let spring=Tuning.shared.autoSpring;exitSpring=Spring(from:1,to:0,response:spring.response,damping:spring.damping,
            epsilon:Spring.restEpsilon/max(1,frame.width))
        window.scene.transition(to:window.scene.members,current:window.scene.current,scheme:window.scene.scheme,
            spring:spring,reason:"browser-remove")
        retainRemoval(window.scene)
        if !window.scene.manualSettle {window.scene.runClock(until:window.scene.now()+1.0/30)}
    }
    func drain() async {
        while true {
            let tasks = retirements; retirements = []
            for task in tasks { await task.value }
            if retirements.isEmpty, exitSpring == nil { return }
            if exitSpring != nil {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
    }
    func retire() {
        guard !disposed else { return };disposed=true;hide()
        exitPicture?.removeFromSuperview();exitPicture=nil;exitSpring=nil;exitCompletion=nil
        window?.scene.browserPort=nil;window?.scene.dock.browserDockPort=nil;window?.shell.onBrowserModeWillChange=nil
    }
}
