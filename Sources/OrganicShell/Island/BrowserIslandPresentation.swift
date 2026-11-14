import AppKit

@MainActor private final class BrowserIslandInkPlane: NSView {
    weak var owner: BrowserIslandPresentation?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { owner?.drawForeground() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Retained, externally sampled BrowserOrb component. It has no application, Core, Dock, or column entry point.
@MainActor final class BrowserIslandPresentation: NSView {
    let replay: any BrowserSessionDriver
    private(set) var liveContent: BrowserLiveContent?
    var liveAskPage: (() -> Void)?
    let motion = BrowserIslandMotion()
    let satellites = BrowserTabSatellites()
    var earthImageOverride: CGImage?
    var hostFull: Bool?
    var hostNow: (() -> Double)?
    var hostWake: (() -> Void)?
    var hostAction: ((BrowserMockAction) -> Bool)?
    var hostOption: (() -> Void)?
    var hostEvent: ((BrowserSessionState, BrowserSessionEvent) -> Void)?
    var hostPageFrame: CGRect?
    private var hostPendingBegan: [String: Double] = [:]
    let images: BrowserBodyImages
    let glass = BrowserIslandGlass()
    private let ink = BrowserIslandInkPlane(frame: CGRect(x: 0, y: 0, width: 1280, height: 820))
    private(set) var buttons: [String: BrowserActionButton] = [:]
    private(set) var pages: [BrowserPageID: BrowserPageMock] = [:]
    private var stateObservation: UUID?, inputObservation: UUID?
    private var tracking: NSTrackingArea?
    private(set) var disposed = false
    private var presented = true
    private var retainedTabs: [BrowserMockTab] = []
    private var renderingMode: BrowserIslandMotion.Mode = .address
    var backing = 2
    var reduceMotion: Bool {
        get { motion.reduceMotion }
        set { motion.reduceMotion = newValue; sample(at: motion.time) }
    }
    var activeButtonCount: Int { buttons.values.filter { $0.participates && !$0.isHidden }.count }
    var subscriptionCount: Int { (stateObservation == nil ? 0 : 1) + (inputObservation == nil ? 0 : 1) }
    override var isFlipped: Bool { true }
    override var isHidden: Bool { didSet { if isHidden { suspend() } else if !disposed { resume() } } }
    static func make(replay: MockBrowserReplay?, live: Bool, explicitlyEnabled: Bool, images: BrowserBodyImages) -> BrowserIslandPresentation? {
        guard !live, explicitlyEnabled, let replay, replay.enabled else { return nil }
        return BrowserIslandPresentation(replay: replay, images: images)
    }
    init(replay: any BrowserSessionDriver, images: BrowserBodyImages) {
        self.replay = replay; self.images = images
        super.init(frame: CGRect(x: 0, y: 0, width: 1280, height: 820)); wantsLayer = true
        appearance = NSAppearance(named: .darkAqua); setAccessibilityRole(.group); setAccessibilityLabel(replay.isLive ? BrowserLiveContent.label : "Built-in browser mock")
        layer?.addSublayer(satellites.back)
        for page in replay.isLive ? [] : BrowserPageID.allCases {
            let view = BrowserPageMock(page: page); pages[page] = view; addSubview(view)
            view.link = { [weak self] in self?.perform(.link) }
            view.pointer = { [weak self] point in
                guard let self else { return }
                self.localInput(.pointer(point.map { $0.x + 14 } ?? -1, point.map { $0.y + 150 } ?? -1))
            }
        }
        ink.owner = self; addSubview(ink)
        layer?.addSublayer(satellites.front)
        let symbols = ["back": "chevron.left", "forward": "chevron.right", "reload": "arrow.clockwise", "stop": "xmark",
                       "site": "info.circle", "annotation": "pencil", "external": "arrow.up.right.square", "extensions": "puzzlepiece", "options": "ellipsis"]
        for key in replay.isLive ? ["earth"] : ["site", "back", "forward", "reload", "annotation", "external", "extensions", "options", "earth", "mercury"] {
            let b = makeButton(key, label: BrowserIslandMotion.labels[key] ?? (key == "earth" ? "Browser" : "Sidebar density pass"))
            b.symbol = symbols[key]
        }
        if replay.isLive {
            let content=BrowserLiveContent(frame:.zero);liveContent=content;addSubview(content);addSubview(content.tabPanel)
            content.action={ [weak self] in self?.perform($0) };content.askPage={ [weak self] in self?.liveAskPage?() }
            content.tabsHover={ [weak self] inside in self?.localInput(.hover("tabs",inside)) }
        }
        resume(); motion.reset(replay.store.state, at: replay.time); satellites.configure(replay.store.state, at: replay.time, reset: true); sample(at: replay.time)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private func resume() {
        guard !disposed, !presented || stateObservation == nil else { return }; presented = true
        motion.reset(presentationState(replay.store.state), at: hostNow?() ?? replay.time)
        satellites.configure(replay.store.state, at: replay.time, reset: true)
        stateObservation = replay.store.observe { [weak self] state, event in
            guard let self, self.presented, !self.disposed else { return }
            let state = self.presentationState(state), event = self.presentationEvent(event)
            if case .opened = event.payload { self.motion.reset(state, at: event.metadata.time); self.satellites.configure(state, at: event.metadata.time, reset: true) }
            else { self.motion.sample(at: max(self.motion.time, event.metadata.time)); self.motion.receive(state, event: event); self.satellites.configure(state, at: event.metadata.time) }
            self.sample(at: max(self.motion.time, event.metadata.time))
            self.hostEvent?(state, event)
            self.hostWake?()
        }
        if !replay.isLive { inputObservation = replay.observeInputs { [weak self] input, time in guard let self, self.presented, !self.disposed, self.hostFull == nil else { return }; self.motion.input(input, at: time); self.sample(at: max(self.motion.time, time)) } }
        setAccessibilityHidden(false); setAccessibilityElement(true)
    }
    func suspend() {
        presented = false; if let stateObservation { replay.store.removeObserver(stateObservation) }; stateObservation = nil
        if let inputObservation { replay.removeInputObserver(inputObservation) }; inputObservation = nil
        motion.cancel(); satellites.setVisible(false)
        for b in buttons.values { b.participates = false; b.isHidden = true }
        for p in pages.values { p.setAccessibilityHidden(true) }
        liveContent?.isHidden=true;liveContent?.tabPanel.isHidden=true
        setAccessibilityHidden(true); setAccessibilityElement(false)
    }
    func dispose() {
        guard !disposed else { return }; suspend(); disposed = true
        for b in buttons.values { b.retire(); b.removeFromSuperview() }; buttons = [:]
        for p in pages.values { p.retire(); p.removeFromSuperview() }; pages = [:]
        satellites.dispose(); glass.dispose()
        liveContent?.retire();liveContent=nil
        if let tracking { removeTrackingArea(tracking) }; tracking = nil
    }
    func perform(_ action: BrowserMockAction) {
        guard !disposed, presented, !isHidden else { return }
        if hostAction?(action) == true { hostWake?(); return }
        replay.interact(.action(action)); hostWake?()
    }
    func localInput(_ input: BrowserMockInput) {
        if let hostNow { motion.input(input, at: hostNow()); sample(at: motion.time); hostWake?() }
        else { replay.interact(input) }
    }
    func setHostFull(_ full: Bool, at time: Double) {
        hostFull = full; motion.presentHost(full: full, at: time); sample(at: time)
    }
    func resetHost(at time: Double) {
        motion.reset(presentationState(replay.store.state), at: time)
        satellites.configure(replay.store.state, at: time, reset: true)
        sample(at: time)
    }
    private func presentationState(_ original: BrowserSessionState) -> BrowserSessionState {
        guard let hostFull else { return original }
        var state = original; state.full = hostFull
        for i in state.tabs.indices {
            guard let pending = state.tabs[i].pending else { continue }
            let key = "\(state.generation):\(state.tabs[i].id):\(pending.revision)"
            let began = hostPendingBegan[key] ?? (hostNow?() ?? motion.time)
            hostPendingBegan[key] = began
            state.tabs[i].pending = .init(page: pending.page, revision: pending.revision, began: began,
                duration: pending.duration, historyIndex: pending.historyIndex, appendsHistory: pending.appendsHistory)
        }
        return state
    }
    private func presentationEvent(_ event: BrowserSessionEvent) -> BrowserSessionEvent {
        guard let hostNow else { return event }
        let m = event.metadata
        return .init(metadata: .init(source: m.source, backend: m.backend, sessionGeneration: m.sessionGeneration,
            tabID: m.tabID, navigationRevision: m.navigationRevision, eventID: m.eventID, time: hostNow()), payload: event.payload)
    }
    @discardableResult private func makeButton(_ key: String, label: String) -> BrowserActionButton {
        if let b = buttons[key] { return b }
        let b = BrowserActionButton(frame: .zero); b.configure(label: label, enabled: true); addSubview(b); buttons[key] = b
        b.drawsHighlight = !["earth", "mercury"].contains(key) && !key.hasPrefix("moon:")
        b.invoke = { [weak self] in self?.activate(key) }
        if key == "earth" { b.optionInvoke = { [weak self] in self?.hostOption?() } }
        b.hover = { [weak self] inside in
            guard key != "mercury" else { return }
            let region = key.hasPrefix("tab:") || key.hasPrefix("close:") || key == "newTab" || key == "live-tabs" ? "tabs" : key
            self?.localInput(.hover(region, inside))
        }
        b.dismiss = { [weak self] in self?.perform(.background) }
        return b
    }
    private func activate(_ key: String) {
        if key == "live-tabs" {localInput(.hover("tabs",true));return}
        let basic: [String: BrowserMockAction] = ["back": .back, "forward": .forward, "reload": .reload, "site": .siteInformation,
            "annotation": .annotation, "external": .external, "extensions": .extensions, "options": .options,
            "manage": .manageCookies, "cookieBack": .cookieBack, "done": .done, "removeAll": .removeAllCookies, "popups": .popups, "autoplay": .autoplay, "newTab": .newTab]
        if let action = basic[key] { perform(action); return }
        if key.hasPrefix("remove:") { if let i = Int(key.dropFirst(7)) { perform(.removeCookie(i)) }; return }
        for permission in BrowserPermissionKey.allCases where key.hasPrefix(permission.rawValue + ":") {
            if let value = Int(key.split(separator: ":").last ?? ""), let choice = BrowserPermission(rawValue: value) { perform(.permission(permission, choice)) }; return
        }
        if key.hasPrefix("tab:") { perform(.selectTab(String(key.dropFirst(4)))); return }
        if key.hasPrefix("moon:") { perform(.selectTab(String(key.dropFirst(5)))); return }
        if key.hasPrefix("close:") { perform(.closeTab(String(key.dropFirst(6)))); return }
        // Ordinary planet clicks intentionally have no action. Only the offscreen driver supplies Option input in R2.
    }
    private func place(_ key: String, rect: CGRect, label: String, enabled: Bool = true, selected: Bool = false,
                       alpha: Double = 1, blur: Double = 0, scale: Double = 1, caption: String? = nil, symbol: String? = nil) {
        let b = makeButton(key, label: label); b.frame = rect; b.inkAlpha = alpha; b.inkBlur = blur; b.inkScale = scale
        b.caption = caption; if let symbol { b.symbol = symbol }; b.isHidden = alpha <= 0.001
        b.participates = presented && alpha > 0.6; b.configure(label: label, enabled: enabled, selected: selected)
        b.selectionStyle = key == "annotation" ? "sky" : "neutral"
        if ["camera:", "microphone:", "location:"].contains(where: { key.hasPrefix($0) }) { b.selectionStyle = "none" }
        b.plateOpacity = caption != nil && !key.hasPrefix("tab:") && key != "newTab" && !key.hasPrefix("camera:") && !key.hasPrefix("microphone:") && !key.hasPrefix("location:") ? 0.08 : 0
        b.textAlignment = key.hasPrefix("tab:") || key == "newTab" ? .left : .center
        if key.hasPrefix("tab:"), let tab = retainedTabs.first(where: { $0.id == String(key.dropFirst(4)) }) {
            b.leadingSymbol = tab.committed == .g ? "square.grid.2x2" : tab.committed == .n ? "plus" : "circle"
        }
        if key == "newTab" { b.leadingSymbol = "plus"; b.shortcut = "⌘T" }
    }
    func sample(at time: Double) {
        guard presented, !disposed, !isHidden else { return }
        motion.sample(at: time); satellites.sample(at: time, paused: motion.orbitPaused, reduced: reduceMotion)
        for b in buttons.values { b.participates = false; b.isHidden = true }
        let s = replay.store.state, m = motion
        guard s.enabled else { suspend(); return }
        if replay.isLive { sampleLive(s);return }
        retainedTabs = s.tabs + retainedTabs.filter { old in !s.tabs.contains { $0.id == old.id || $0.slot == old.slot } && m.tabHeights[old.slot].value > 0 }
        let retainedIDs = Set(retainedTabs.map(\.id))
        for key in Array(buttons.keys) {
            if let prefix = ["tab:", "close:", "moon:"].first(where: { key.hasPrefix($0) }), !retainedIDs.contains(String(key.dropFirst(prefix.count))) {
                buttons[key]?.retire(); buttons[key]?.removeFromSuperview(); buttons[key] = nil
            }
        }
        for (id, page) in pages {
            if let hostPageFrame { page.frame = hostPageFrame }
            let k = (m.pageOpacities[id] ?? 0) * m.pagePresence
            page.inkOpacity = k; page.isHidden = k <= 0.001; page.annotationEnabled = s.annotationEnabled; page.annotationOpacity = m.annotationOpacity
            page.setAccessibilityHidden(page.isHidden); page.annotationRect = id == .a ? m.annotationOutline.map { BrowserIslandMotion.annotationBlocks[$0] } : nil; page.needsDisplay = true
        }
        if m.full && m.flightBegan == nil {
            let rowLeft = 311.5 - m.addressWidth.value / 2
            place("site", rect: CGRect(x: rowLeft + 6, y: 108, width: 24, height: 24), label: "View Site Information", enabled: s.site != nil,
                  selected: m.mode == .site || m.mode == .cookies, alpha: m.rowOpacity, blur: 6 * (1 - m.rowOpacity), symbol: s.displayedPage == .n ? "magnifyingglass" : MockBrowserSeed.pages[s.displayedPage ?? .a]?.scheme == "https" ? "lock.fill" : "info.circle")
            for index in 0..<3 {
                let pose = m.lobePose(index), target = index == 0 ? CGSize(width: 72, height: 32) : index == 1 ? CGSize(width: 32, height: 32) : CGSize(width: 124, height: 32)
                let x = pose.frame.midX - target.width / 2, y = pose.frame.midY - 14
                if index == 0 {
                    place("back", rect: CGRect(x: x + 3.5, y: y, width: 32, height: 28), label: "Back", enabled: s.selectedTab?.canGoBack == true, alpha: pose.contentAlpha, blur: pose.contentBlur, scale: pose.contentScale)
                    place("forward", rect: CGRect(x: x + 36.5, y: y, width: 32, height: 28), label: "Forward", enabled: s.selectedTab?.canGoForward == true, alpha: pose.contentAlpha, blur: pose.contentBlur, scale: pose.contentScale)
                } else if index == 1 {
                    place("reload", rect: CGRect(x: x, y: y, width: 32, height: 28), label: s.selectedTab?.pending == nil ? "Reload" : "Stop", enabled: s.displayedPage != .n,
                          alpha: pose.contentAlpha, blur: pose.contentBlur, scale: pose.contentScale, symbol: "arrow.clockwise")
                    buttons["reload"]?.secondarySymbol = "xmark"; buttons["reload"]?.symbolBlend = m.stopAmount
                } else {
                    for (j, key) in ["annotation", "external", "extensions", "options"].enumerated() {
                        place(key, rect: CGRect(x: x + 6 + Double(j) * 28, y: y, width: 28, height: 28), label: BrowserIslandMotion.labels[key]!, selected: key == "annotation" && s.annotationEnabled,
                              alpha: pose.contentAlpha, blur: pose.contentBlur, scale: pose.contentScale)
                    }
                }
            }
            if let retiring = m.retiringMode {
                layoutCard(retiring)
                for (key, button) in buttons where !["site", "back", "forward", "reload", "annotation", "external", "extensions", "options"].contains(key) { button.participates = false }
            }
            layoutCard(m.mode)
        }
        place("earth", rect: m.earthFrame, label: "Browser", alpha: 1)
        place("mercury", rect: m.mercuryFrame, label: "Sidebar density pass", alpha: 1)
        if hostFull != nil { buttons["mercury"]?.participates = false; buttons["mercury"]?.isHidden = true }
        for tab in s.tabs {
            if let p = satellites.pose(tab.id, earth: m.earthFrame), p.opacity > 0.9, m.flightBegan == nil {
                place("moon:" + tab.id, rect: CGRect(x: p.center.x - 12, y: p.center.y - 12, width: 24, height: 24), label: MockBrowserSeed.pages[tab.committed]?.title ?? "Tab", alpha: p.opacity)
            }
        }
        // Native layers retain static pictures; detached checks draw the same moon poses explicitly.
        satellites.setVisible(window?.isVisible == true && window?.occlusionState.contains(.visible) == true)
        satellites.render(earth: m.earthFrame, images: images, scale: backing)
        satellites.back.isHidden = window == nil; satellites.front.isHidden = window == nil
        let keys = buttons.values.filter { $0.participates && $0.isEnabled }.sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        for (index, button) in keys.enumerated() { button.nextKeyView = keys[(index + 1) % keys.count] }
        needsDisplay = true; ink.needsDisplay = true
    }
    private func cardRow(_ key: String, rect: CGRect, label: String, row: Int, caption: String?, selected: Bool = false, enabled: Bool = true) {
        let a = motion.rowAlpha(row, for: renderingMode), rise = 6 * (1 - a)
        place(key, rect: rect.offsetBy(dx: 0, dy: rise), label: label, enabled: enabled, selected: selected, alpha: a, blur: 6 * (1 - a), caption: caption)
    }
    private func layoutCard(_ mode: BrowserIslandMotion.Mode) {
        renderingMode = mode
        if mode == .site { layoutSite() } else if mode == .cookies { layoutCookies() } else if mode == .tabs { layoutTabs() }
    }
    private func layoutSite() {
        let left = 311.5 - 160, site = replay.store.state.site
        cardRow("manage", rect: CGRect(x: left + 238, y: 104 + 101, width: 68, height: 22), label: "Manage cookies", row: 2, caption: "Manage")
        for (i, key) in BrowserPermissionKey.allCases.enumerated() {
            let selected = key == .camera ? site?.camera : key == .microphone ? site?.microphone : site?.location
            for value in BrowserPermission.allCases {
                let rect = CGRect(x: left + 174 + Double(value.rawValue) * 42, y: 237 + Double(i) * 32, width: 42, height: 22)
                cardRow(key.rawValue + ":\(value.rawValue)", rect: rect,
                        label: "\(key.rawValue) \(["Ask", "Allow", "Deny"][value.rawValue])", row: i + 3, caption: ["Ask", "Allow", "Deny"][value.rawValue], selected: selected == value)
            }
        }
        cardRow("popups", rect: CGRect(x: left + 166, y: 104 + 229, width: 140, height: 22), label: "Pop-ups", row: 6, caption: Self.popupNames[site?.popups ?? 0])
        cardRow("autoplay", rect: CGRect(x: left + 150, y: 104 + 261, width: 156, height: 22), label: "Auto-play", row: 7, caption: Self.autoplayNames[site?.autoplay ?? 1])
    }
    private func layoutCookies() {
        let left = 311.5 - 160
        cardRow("cookieBack", rect: CGRect(x: left + 8, y: 144, width: 150, height: 24), label: "Website Settings", row: 0, caption: "‹ Website Settings")
        var y = 174.0
        for i in 0..<3 {
            let a = min(motion.rowAlpha(i + 1, for: renderingMode), motion.cookieOpacity[i])
            place("remove:\(i)", rect: CGRect(x: left + 238, y: y + 11 + 6 * (1 - a), width: 68, height: 22), label: "Remove cookie group \(i + 1)", alpha: a, blur: 6 * (1 - a), caption: "Remove")
            y += motion.cookieHeights[i].value
        }
        y += motion.emptyHeight.value
        cardRow("removeAll", rect: CGRect(x: left + 14, y: y + 12, width: 92, height: 22), label: "Remove All", row: 4, caption: "Remove All", enabled: replay.store.state.site?.cookieCount != 0)
        cardRow("done", rect: CGRect(x: left + 250, y: y + 12, width: 56, height: 22), label: "Done", row: 4, caption: "Done")
    }
    private func layoutTabs() {
        let left = 161.5; var y = 144.0
        for (index, tab) in retainedTabs.enumerated() {
            let a = min(motion.rowAlpha(index, for: renderingMode), motion.tabOpacity[tab.slot])
            place("tab:" + tab.id, rect: CGRect(x: left + 6, y: y + 6 * (1 - a), width: 259, height: 32), label: MockBrowserSeed.pages[tab.committed]?.title ?? "Tab", enabled: replay.store.state.tabs.contains { $0.id == tab.id }, selected: tab.id == replay.store.state.selectedTabID,
                  alpha: a, blur: 6 * (1 - a), caption: MockBrowserSeed.pages[tab.committed]?.title)
            place("close:" + tab.id, rect: CGRect(x: left + 267, y: y + 5 + 6 * (1 - a), width: 22, height: 22), label: "Close Tab", enabled: replay.store.state.tabs.count > 1,
                  alpha: a, blur: 6 * (1 - a), symbol: "xmark")
            y += motion.tabHeights[tab.slot].value
        }
        cardRow("newTab", rect: CGRect(x: left + 6, y: y + 9, width: 288, height: 32), label: "New Tab", row: replay.store.state.tabs.count, caption: "New Tab", enabled: replay.store.state.tabs.count < 5)
    }
    fileprivate func drawForeground() {
        guard presented, !disposed, replay.enabled else { return }
        if replay.isLive {drawLiveForeground();return}
        let m = motion
        if hostFull != nil && !m.full {
            drawMoonFaces(front: false); drawPlanet("earth", frame: m.earthFrame); drawMoonFaces(front: true)
            return
        }
        let base = NSColor(srgbRed: 50 / 255, green: 52 / 255, blue: 50 / 255, alpha: 1)
        let tint = NSColor(srgbRed: (50 + 15 * m.annotationAmount) / 255, green: (52 + 44 * m.annotationAmount) / 255, blue: (50 + 65 * m.annotationAmount) / 255, alpha: 1)
        var discs: [BrowserIslandGlass.Disc] = [.init(rect: m.capsule, radius: min(m.radius.value, m.capsule.height / 2), color: tint)]
        var necks: [BrowserIslandGlass.Neck] = []
        if m.flightBegan == nil || m.time - (m.flightBegan ?? 0) < 0.12 || m.time - (m.flightBegan ?? 0) >= 0.52 {
            discs.append(.init(rect: CGRect(x: 284.5, y: 53, width: 54, height: 54), radius: 27, color: NSColor(srgbRed: 58 / 255, green: 59 / 255, blue: 58 / 255, alpha: 1)))
        }
        for i in 0..<3 where m.lobes[i].value >= 0.02 {
            let p = m.lobePose(i); discs.append(.init(rect: p.frame, radius: p.frame.height / 2, color: base)); necks.append(.init(start: p.neckStart, end: p.neckEnd, width: p.neckWidth))
        }
        if let key = m.labelKey, m.labelPresence.value > 0.02 {
            let p = m.labelPresence.value, anchor = m.labelAnchor(key), direction = key == "site" || key == "reload" || key == "back" || key == "forward" ? 1.0 : -1.0
            let sy = anchor.y - direction * 18, x = BrowserIslandMath.lerp(anchor.x, m.labelX.value, p), y = BrowserIslandMath.lerp(sy, anchor.y, p)
            let w = BrowserIslandMath.lerp(8, m.labelWidth.value, p), h = BrowserIslandMath.lerp(8, 24, min(1.03, p * 1.3))
            discs.append(.init(rect: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), radius: h / 2, color: base))
            necks.append(.init(start: CGPoint(x: anchor.x, y: anchor.y - direction * 24), end: CGPoint(x: x, y: y - direction * h / 2 + direction * 3), width: 10 * (1 - BrowserIslandMath.smooth((p - 0.25) / 0.4)) * min(1, p * 6)))
        }
        glass.draw(discs: discs, necks: necks, scale: backing)
        let navigation = m.lobePose(0)
        NSColor.white.withAlphaComponent(0.18 * navigation.contentAlpha).setFill(); CGRect(x: navigation.frame.midX - 0.5, y: navigation.frame.midY - 8, width: 1, height: 16).fill()
        drawMoonFaces(front: false)
        if hostFull == nil { drawPlanet("mercury", frame: m.mercuryFrame) }
        drawPlanet("earth", frame: m.earthFrame)
        drawMoonFaces(front: true)
        drawAddress()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: m.capsule, xRadius: m.radius.value, yRadius: m.radius.value).addClip()
        if let retiring = m.retiringMode { drawCard(retiring) }; drawCard(m.mode)
        NSGraphicsContext.restoreGraphicsState()
        if let text = m.label, m.labelPresence.value > 0.02, let labelRect = m.labelFrame {
            let a = BrowserIslandMath.smooth((m.labelPresence.value - 0.5) / 0.3) * m.labelTextOpacity
            BrowserPaint.inkGroup(in: labelRect, alpha: a, blur: 5 * (1 - a)) {
                BrowserPaint.text(text, labelRect.insetBy(dx: 0, dy: 4), size: 12, weight: .semibold, alignment: .center)
            }
        }
        if m.loadingOpacity > 0.01 && m.mode == .address { drawProgress() }
        if let issue = replay.store.state.issue { BrowserPaint.text(issue + " · Mock", CGRect(x: 34, y: 704, width: 530, height: 20), size: 11, color: BrowserPaint.secondary) }
    }
    private func sampleLive(_ state:BrowserSessionState) {
        let m=motion
        place("earth",rect:m.earthFrame,label:BrowserLiveContent.label)
        buttons["earth"]?.toolTip=BrowserLiveContent.label
        if m.full && m.mode == .address && m.flightBegan == nil {
            place("live-tabs",rect:m.capsule,label:BrowserLiveContent.label+" Tabs")
            buttons["live-tabs"]?.drawsHighlight=false
        }
        for key in Array(buttons.keys) where key.hasPrefix("moon:") && !state.tabIDs.contains(String(key.dropFirst(5))) {
            buttons[key]?.retire();buttons[key]?.removeFromSuperview();buttons[key]=nil
        }
        for tab in state.liveTabs {
            if let p=satellites.pose(tab.id,earth:m.earthFrame),p.opacity>0.9,m.flightBegan == nil {
                place("moon:"+tab.id,rect:CGRect(x:p.center.x-12,y:p.center.y-12,width:24,height:24),label:tab.title.isEmpty ? tab.url:tab.title,alpha:p.opacity)
            }
        }
        liveContent?.configure(state)
        liveContent?.placePage(hostPageFrame ?? BrowserIslandMetrics.page,visible:m.pageVisible,alpha:m.pagePresence)
        liveContent?.placeTabs(m.capsule,visible:m.full && m.mode == .tabs && m.flightBegan == nil)
        satellites.setVisible(window?.isVisible == true && window?.occlusionState.contains(.visible) == true)
        satellites.render(earth:m.earthFrame,images:images,scale:backing)
        satellites.back.isHidden=window == nil;satellites.front.isHidden=window == nil
        needsDisplay=true;ink.needsDisplay=true
    }
    private func drawLiveForeground() {
        let m=motion
        if m.full {
            glass.draw(discs:[.init(rect:m.capsule,radius:min(m.radius.value,m.capsule.height/2),color:NSColor(white:0.20,alpha:1))],necks:[],scale:backing)
            if m.mode == .address {drawAddress()}
        }
        drawMoonFaces(front:false);drawPlanet("earth",frame:m.earthFrame);drawMoonFaces(front:true)
    }
    private func drawPlanet(_ body: String, frame: CGRect) {
        BrowserPaint.plate(frame, radius: frame.width / 2, color: NSColor(white: 0.28, alpha: 0.7), stroke: NSColor.white.withAlphaComponent(0.30))
        if let image = (body == "earth" ? earthImageOverride : nil) ?? images.image(body, outer: frame.width, scale: backing, center: CGPoint(x: frame.midX, y: frame.midY)) {
            NSImage(cgImage: image, size: frame.size).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    private func drawMoonFaces(front: Bool) {
        guard window == nil else { return }
        for (id, _) in satellites.moons {
            guard let p = satellites.pose(id, earth: motion.earthFrame), p.front == front,
                  let image = images.image("moon", outer: 12, scale: backing, center: p.center) else { continue }
            let rect = CGRect(x: p.center.x - p.diameter / 2, y: p.center.y - p.diameter / 2, width: p.diameter, height: p.diameter)
            BrowserPaint.inkGroup(in: rect, alpha: p.opacity, blur: (1 - p.opacity) * 3) {
                NSGraphicsContext.saveGraphicsState(); let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.4); shadow.shadowBlurRadius = 6; shadow.shadowOffset = CGSize(width: 0, height: -2); shadow.set()
                NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState(); BrowserPaint.plate(rect, radius: rect.width / 2, color: .clear, stroke: NSColor.white.withAlphaComponent(0.34))
            }
        }
    }
    private func drawAddress() {
        let m = motion, left = 311.5 - (m.full ? m.addressWidth.value : 188) / 2
        var alpha = m.rowOpacity
        if let began = m.flightBegan { let t = m.time - began; alpha *= t < 0.09 ? max(0, 1 - t / 0.09) : t < 0.72 ? 0 : min(1, (t - 0.72) / 0.12) }
        BrowserPaint.inkGroup(in: CGRect(x: left, y: 104, width: m.full ? m.addressWidth.value : 188, height: 32), alpha: alpha, blur: 6 * (1 - alpha)) {
            if !m.full { BrowserPaint.text("•••  Sidebar density pass  ›", CGRect(x: left + 12, y: 112, width: 164, height: 18), weight: .semibold); return }
            if m.address.placeholder { BrowserPaint.text("Search or enter a URL", CGRect(x: left + 34, y: 112, width: m.addressWidth.value - 48, height: 18), color: BrowserPaint.tertiary) }
            else {
                let hostWidth = (m.address.host as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
                BrowserPaint.text(m.address.host, CGRect(x: left + 34, y: 112, width: hostWidth + 1, height: 18), weight: .semibold)
                BrowserPaint.text(m.address.rest, CGRect(x: left + 34 + hostWidth, y: 112, width: m.addressWidth.value - 48 - hostWidth, height: 18), color: BrowserPaint.secondary)
            }
        }
    }
    private func row(_ index: Int, rect: CGRect, _ draw: () -> Void) {
        let a = motion.rowAlpha(index, for: renderingMode)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: 6 * (1 - a))
        BrowserPaint.inkGroup(in: rect, alpha: a, blur: 6 * (1 - a), draw: draw); NSGraphicsContext.restoreGraphicsState()
    }
    private func drawCard(_ mode: BrowserIslandMotion.Mode) {
        renderingMode = mode
        if mode == .site { drawSite() } else if mode == .cookies { drawCookies() } else if mode == .tabs { drawTabsBackground() }
    }
    private func drawSite() {
        let left = 151.5, s = replay.store.state, page = MockBrowserSeed.pages[s.displayedPage ?? .a]!, site = s.site
        row(0, rect: CGRect(x: left, y: 144, width: 320, height: 26)) {
            BrowserPaint.symbol(page.scheme == "https" ? "lock" : "desktopcomputer", rect: CGRect(x: left + 16, y: 148, width: 16, height: 16), color: BrowserPaint.secondary)
            BrowserPaint.text(page.isLoopback ? "Local connection · not encrypted" : page.scheme == "https" ? "Connection is encrypted" : "Not encrypted", CGRect(x: left + 39, y: 148, width: 266, height: 20), size: 12, color: BrowserPaint.secondary)
        }
        row(1, rect: CGRect(x: left, y: 172, width: 320, height: 26)) {
            NSColor.white.withAlphaComponent(0.10).setFill(); CGRect(x: left + 12, y: 172, width: 296, height: 1).fill()
            BrowserPaint.text("Settings for " + page.host, CGRect(x: left + 16, y: 180, width: 288, height: 18), size: 11, weight: .semibold, color: BrowserPaint.tertiary)
        }
        let names = ["Cookies", "Camera", "Microphone", "Location", "Pop-ups", "Auto-play"], symbols = ["circle.dotted", "camera", "mic", "location", "macwindow.on.rectangle", "play.circle"]
        for i in 0..<6 {
            let y = 104.0 + 96 + Double(i) * 32
            row(i + 2, rect: CGRect(x: left, y: y, width: 320, height: 32)) {
                BrowserPaint.symbol(symbols[i], rect: CGRect(x: left + 16, y: y + 8, width: 16, height: 16), color: BrowserPaint.secondary)
                BrowserPaint.text(names[i], CGRect(x: left + 41, y: y + 8, width: 120, height: 20))
                if (1...3).contains(i) {
                    BrowserPaint.plate(CGRect(x: left + 172, y: y + 5, width: 130, height: 22), radius: 11, color: NSColor.white.withAlphaComponent(0.08))
                    BrowserPaint.plate(CGRect(x: left + 174 + self.motion.permissionPositions[i - 1] * 42, y: y + 7, width: 42, height: 18), radius: 9, color: NSColor.white.withAlphaComponent(0.20))
                }
                if i == 0 { BrowserPaint.text(site.map { $0.cookieCount == 0 ? "None" : String($0.cookieCount) } ?? "Not reported", CGRect(x: left + 192, y: y + 8, width: 36, height: 18), size: 12, color: BrowserPaint.secondary, alignment: .right) }
            }
        }
    }
    private func drawCookies() {
        let left = 151.5, site = replay.store.state.site
        row(0, rect: CGRect(x: left, y: 144, width: 320, height: 24)) { BrowserPaint.text(site.map { $0.cookieCount == 0 ? "None" : "\($0.cookieCount) cookie\($0.cookieCount == 1 ? "" : "s")" } ?? "Not reported", CGRect(x: left + 204, y: 148, width: 100, height: 20), size: 12, color: BrowserPaint.secondary, alignment: .right) }
        var y = 174.0
        for i in 0..<3 {
            let h = motion.cookieHeights[i].value, a = min(motion.rowAlpha(i + 1, for: renderingMode), motion.cookieOpacity[i])
            if let site, site.cookies.indices.contains(i) {
                let cookie = site.cookies[i], r = CGRect(x: left + 16, y: y, width: 212, height: max(0, h))
                BrowserPaint.inkGroup(in: r, alpha: a, blur: 6 * (1 - a)) {
                    BrowserPaint.text(cookie.domain, CGRect(x: r.minX, y: r.minY + 6, width: r.width, height: 18), weight: .semibold)
                    BrowserPaint.text("\(cookie.names.count) cookie\(cookie.names.count == 1 ? "" : "s") · " + cookie.names.joined(separator: ", "), CGRect(x: r.minX, y: r.minY + 24, width: r.width, height: 16), size: 11, color: BrowserPaint.secondary)
                }
            }; y += h
        }
        if motion.emptyHeight.value > 0.1 {
            row(2, rect: CGRect(x: left, y: y, width: 320, height: motion.emptyHeight.value)) { BrowserPaint.text("No cookies for this website", CGRect(x: left, y: y + 12, width: 320, height: 20), size: 12, color: BrowserPaint.tertiary, alignment: .center) }
        }
        y += motion.emptyHeight.value
        row(4, rect: CGRect(x: left, y: y + 4, width: 320, height: 1)) { NSColor.white.withAlphaComponent(0.1).setFill(); CGRect(x: left + 12, y: y + 4, width: 296, height: 1).fill() }
    }
    private func drawTabsBackground() {
        let y = 144 + motion.tabHeights.reduce(0) { $0 + $1.value }
        row(replay.store.state.tabs.count, rect: CGRect(x: 173.5, y: y + 4, width: 276, height: 1)) { NSColor.white.withAlphaComponent(0.1).setFill(); CGRect(x: 173.5, y: y + 4, width: 276, height: 1).fill() }
    }
    private func drawProgress() {
        let r = motion.capsule.insetBy(dx: 2, dy: 2), radius = r.height / 2
        let path = NSBezierPath(); path.move(to: CGPoint(x: r.minX, y: r.midY)); path.appendArc(withCenter: CGPoint(x: r.minX + radius, y: r.midY), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: CGPoint(x: r.maxX - radius, y: r.maxY)); path.appendArc(withCenter: CGPoint(x: r.maxX - radius, y: r.midY), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState(); cg.clip(to: CGRect(x: r.minX, y: r.minY, width: r.width * motion.loadingProgress, height: r.height))
        BrowserPaint.sky.withAlphaComponent(motion.loadingOpacity).setStroke(); path.lineWidth = 1.5; path.lineCapStyle = .round; path.stroke(); cg.restoreGState()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: motion.capsule, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self); tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { if presented && !disposed { localInput(.hover(motion.mode == .tabs ? "tabs" : "island", true)) } }
    override func mouseExited(with event: NSEvent) { if presented && !disposed { localInput(.hover(motion.mode == .tabs ? "tabs" : "island", false)) } }
    override func mouseDown(with event: NSEvent) { perform(.background) }
    override func rightMouseDown(with event: NSEvent) { if hostFull == nil { super.rightMouseDown(with: event) } }
    override func mouseDragged(with event: NSEvent) { if hostFull == nil { super.mouseDragged(with: event) } }
    override func pressureChange(with event: NSEvent) { if hostFull == nil { super.pressureChange(with: event) } }
    override func scrollWheel(with event: NSEvent) { if hostFull == nil { super.scrollWheel(with: event) } }
    override func cancelOperation(_ sender: Any?) { perform(.background) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard presented, !disposed, !isHidden else { return nil }
        let p = convert(point, from: superview)
        if let hit = satellites.hit(at: p), let button = buttons["moon:" + hit.id], button.participates {
            button.frame = CGRect(x: hit.center.x - 12, y: hit.center.y - 12, width: 24, height: 24); return button
        }
        func priority(_ key: String) -> Int { key == "earth" || key == "mercury" ? 3 : key.hasPrefix("moon:") ? 2 : 1 }
        for key in buttons.keys.sorted(by: { priority($0) == priority($1) ? $0 < $1 : priority($0) < priority($1) }) {
            if let target = buttons[key], target.participates, !target.isHidden, target.frame.contains(p) { return target }
        }
        if let page = replay.store.state.committedPage, let view = pages[page], !view.isHidden, view.frame.contains(p) { return view }
        if hostFull != nil { return motion.full && motion.capsule.contains(p) ? self : nil }
        return bounds.contains(p) ? self : nil
    }
    static let popupNames = ["Block and Notify", "Block", "Allow"]
    static let autoplayNames = ["Allow All Auto-Play", "Stop Media with Sound", "Never Auto-Play"]
}
