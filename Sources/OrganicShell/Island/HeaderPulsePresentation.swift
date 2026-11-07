import AppKit
import QuartzCore

/// Pulse's glass and four content planes. Filters belong exclusively to the content planes.
@MainActor final class HeaderPulsePresentation: IslandPlane {
    private(set) var state = HeaderPulseState()
    private(set) var motion: HeaderPulseMotion?
    private(set) var capsuleFrame = CGRect.zero
    private let glass = NSGlassEffectView()
    private let halo = CAGradientLayer()
    private let clip = IslandPlane(), clipMask = CAShapeLayer()
    private var planes: [HeaderPulseState.Mode: IslandPlane] = [:]
    private var labels: [String: IslandLabel] = [:]
    private var buttons: [IslandButton] = []
    private var detailButtons: [IslandButton] = []
    private var leads: [HeaderPulseState.Mode: PulseLeadView] = [:]
    private let progressRing = PulseRingView()
    private var reportedExpanded = false, reportedPinned = false
    private let surfaceButton = IslandButton()
    private var snapshot = ConversationNoticeSnapshot()
    private var input: HeaderIslandConfiguration?
    private var base = CGRect.zero
    private var lastTime: Double?
    private var swap = PulseTextSwap()
    private let clock = IslandMotionClock()
    private var modeContentFrozen=false
    private var suspended = true
    private var interactive = false
    private var ambientActive = true
    private var blurFilters: [ObjectIdentifier:NSObject] = [:]
    private var warmObserver: CFRunLoopObserver?
    private var warmIndex=0, warmSlices=0
    private var warmTotalMS=0.0, warmMaxMS=0.0
    private var sampleMS=0.0, maxSampleMS=0.0, maxClockGapMS=0.0
    private var lastClockWall: Double?
    private var filterBuilds=0
    private var submittedRequest: String?
    private var submittedAge = 0.0
    private var displayedAction: ConversationNotice?
    private var displayedHalo: ConversationNotice?
    private var haloPhase = PulseContentPhase()
    private var leadSwaps: [HeaderPulseState.Mode: PulseTextSwap] = [:]
    private var trailSwap = PulseTextSwap()
    var onToggle: (() -> Void)?
    var onRename: (() -> Void)?
    var onAction: ((ConversationNoticeAction) -> Void)?
    var onPanel: ((HeaderIslandPanel) -> Void)?
    var onPose: ((Double) -> Void)?
    var onExpansion: ((Bool, Bool) -> Void)?
    var wallTime: () -> Double = { Date().timeIntervalSince1970 }
    var isEnabled: Bool { state.enabled }
    var clockRunning: Bool { clock.isRunning }
    var capsuleRadius: CGFloat { glass.cornerRadius }
    func setOffscreenGlassHidden(_ hidden: Bool) { glass.isHidden = hidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        halo.type = .radial; halo.startPoint = CGPoint(x: 0.5, y: 0.25); halo.endPoint = CGPoint(x: 1, y: 1)
        halo.locations = [0, 1]; layer?.addSublayer(halo)
        glass.style = .regular; glass.contentView = IslandPlane()
        addSubview(glass); addSubview(clip)
        clip.layer?.mask = clipMask
        surfaceButton.drawsText = false; surfaceButton.drawsPointerHighlight = false
        surfaceButton.invoke = { [weak self] in self?.onToggle?() }
        surfaceButton.doubleClick = { [weak self] in self?.onRename?() }
        surfaceButton.focus = { [weak self] in self?.focus($0) }
        addSubview(surfaceButton)
        for mode in HeaderPulseState.Mode.allCases {
            let plane = IslandPlane(); clip.addSubview(plane); planes[mode] = plane
            switch mode {
            case .compact: makeLabel("compactTitle", in: plane, size: 13); makeLabel("compactTrail", in: plane, size: 11, secondary: true)
            case .bloom:
                makeLabel("bloomTitle", in: plane, size: 11, secondary: true)
                makeLabel("bloomText", in: plane, size: 13)
                makeLabel("bloomTrail", in: plane, size: 11, secondary: true)
            case .action:
                makeLabel("actionTitle", in: plane, size: 11, secondary: true)
                makeLabel("actionText", in: plane, size: 13)
                for _ in 0..<2 {
                    let button = IslandButton(); button.pointSize = 12
                    button.layer?.cornerRadius = 13; plane.addSubview(button); buttons.append(button)
                }
            case .expanded:
                makeLabel("expandedTitle", in: plane, size: 13)
                for (i, title) in ["Sub-agents", "Changes", "Context", "Status"].enumerated() {
                    makeLabel("key\(i)", in: plane, size: 10, secondary: true); labels["key\(i)"]?.stringValue = title
                    makeLabel("value\(i)", in: plane, size: 12)
                    let button = IslandButton(); button.drawsText = false
                    button.text = "Show " + title; button.invoke = { [weak self] in self?.onPanel?(HeaderIslandPanel.allCases[i]) }
                    plane.addSubview(button); detailButtons.append(button)
                }
            }
            if mode != .expanded { let lead=PulseLeadView();plane.addSubview(lead);leads[mode]=lead }
        }
        planes[.compact]?.addSubview(progressRing)
        clock.tick = { [weak self] time in
            guard let self else { return }
            let wall=CACurrentMediaTime()
            if let previous=self.lastClockWall { self.maxClockGapMS=max(self.maxClockGapMS,(wall-previous)*1000) }
            self.lastClockWall=wall; self.sample(at:time)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil {clock.stop();stopIdleWarmup()} else {schedule();requestIdleWarmup()} }
    func setTitleMenu(_ menu:NSMenu?) {surfaceButton.menu=menu}

    private func makeLabel(_ key: String, in view: NSView, size: CGFloat, secondary: Bool = false) {
        let label = IslandLabel(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: secondary ? .medium : .semibold)
        label.textColor = .white.withAlphaComponent(secondary ? 0.55 : 0.92)
        label.isBordered = false; label.isBezeled = false; label.drawsBackground = false
        label.maximumNumberOfLines = 1; label.lineBreakMode = .byTruncatingTail; label.wantsLayer = true
        label.setAccessibilityElement(false)
        view.addSubview(label); labels[key] = label
    }

    func configure(_ snapshot: ConversationNoticeSnapshot, input: HeaderIslandConfiguration, compact: CGRect,
                   at time: Double, suspended: Bool, interactive: Bool) {
        guard !modeContentFrozen else {return}
        sample(at: time)
        self.snapshot = snapshot; self.input = input; self.base = compact; self.interactive = interactive
        let revision = state.revision
        let acceptedRevision = state.acceptedRevision
        state.ingest(snapshot)
        if motion == nil {
            motion = .init(columnWidth: input.noticeColumnWidth ?? input.columnWidth, compactWidth: compact.width,
                           compactHeight: input.variant == .brief ? 27 : compact.height, clock: hasClock)
        }
        motion?.columnWidth = input.noticeColumnWidth ?? input.columnWidth; motion?.compactWidth = compact.width
        motion?.compactHeight = input.variant == .brief ? 27 : compact.height
        let rebloom = motion?.mode == .bloom
        for i in 0..<(state.revision-revision) {motion?.receiveKick(rebloom:rebloom && i < state.acceptedRevision-acceptedRevision)}
        if let submittedRequest, !snapshot.pending.contains(where: { $0.requestID == submittedRequest }) { self.submittedRequest = nil }
        self.suspended = suspended; isHidden = suspended || !state.enabled
        if suspended { state.dismiss() }
        lastTime = max(lastTime ?? time, time)
        refresh(dt: 0)
        schedule(); requestIdleWarmup()
    }

    /// An active body picture retains this exact native header pose, including its independent expiry clock.
    func setModeContentFrozen(_ frozen:Bool) {
        guard frozen != modeContentFrozen else {return}
        modeContentFrozen=frozen;lastTime=nil
        if frozen {clock.stop();stopIdleWarmup()} else {schedule()}
    }
    func setAmbientActive(_ active: Bool) { ambientActive=active; schedule() }
    func hover(_ inside: Bool, at time: Double) { guard !suspended else { return }; sample(at: time); state.hover(inside); schedule() }
    func focus(_ value: Bool) { guard !suspended && interactive else { return }; state.focus(value); refresh(dt: 0); schedule() }
    func togglePin() { guard !suspended && interactive else { return }; state.togglePin(); refresh(dt: 0); schedule() }
    func dismiss() { state.dismiss(); refresh(dt: 0); schedule() }
    func suspend() {
        stopIdleWarmup()
        state.dismiss(); suspended = true; interactive = false; isHidden = true; clock.stop(); lastTime = nil
        displayedAction=nil; displayedHalo=nil; haloPhase=PulseContentPhase()
        if let m=motion { motion = .init(columnWidth:m.columnWidth,compactWidth:m.compactWidth,compactHeight:m.compactHeight,clock:hasClock) }
        onPose?(1)
        if reportedExpanded || reportedPinned { reportedExpanded=false; reportedPinned=false; onExpansion?(false,false) }
    }
    func dispose() { stopIdleWarmup(); clock.stop(); state.dismiss(); onPose = nil; onAction = nil; onPanel = nil; onToggle = nil;onRename=nil }

    func sample(at time: Double) {
        guard !modeContentFrozen else {return}
        let began=CACurrentMediaTime()
        defer { sampleMS=(CACurrentMediaTime()-began)*1000; maxSampleMS=max(maxSampleMS,sampleMS) }
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = max(lastTime ?? time, time)
        guard !suspended, state.enabled else { return }
        // Preserve a deterministic path after a delayed frame; hover and expiry use actual elapsed time.
        var remaining = min(dt, 1)
        if dt > remaining { state.tick(dt - remaining) }
        if submittedRequest != nil { submittedAge += dt; if submittedAge > 0.5 { submittedRequest = nil } }
        while remaining > 1e-9 {
            let step = min(1.0 / 60, remaining)
            state.tick(step); refresh(dt: step); remaining -= step
        }
        if dt == 0 { refresh(dt: 0) }
        schedule()
    }

    private var hasClock: Bool {
        snapshot.startedAt != nil && snapshot.progress == nil && (input?.signals.context ?? 0) < 0.8
            && snapshot.pending.isEmpty && (snapshot.running || snapshot.terminalStatus == "completed")
    }
    private var elapsed: String {
        guard let start = snapshot.startedAt else { return "" }
        let seconds = Int(max(0, (snapshot.endedAt ?? wallTime()) - start))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
    private func schedule() {
        if !modeContentFrozen && !suspended && state.enabled && (motion?.busy == true || haloPhase.busy || state.event != nil || state.inside || state.hovering || state.pinned || (snapshot.running && ambientActive)) {
            if !clock.isRunning { lastClockWall=nil }
            clock.start(in: self)
        } else { clock.stop(); lastClockWall=nil }
    }

    private func refresh(dt: Double) {
        guard let input, motion != nil else { return }
        let previousMode = motion!.mode
        motion!.retarget(state.mode, clock: hasClock)
        motion!.step(dt, reduced: input.reduceMotion)
        let m = motion!
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        let y = base.minY + (input.variant == .brief ? 1 : 0)
        capsuleFrame = CGRect(x: base.midX - m.width.x / 2, y: y, width: max(1, m.width.x), height: max(1, m.height.x))
        glass.frame = capsuleFrame; glass.cornerRadius = min(m.radius.x, m.height.x / 2)
        glass.contentView?.frame = glass.bounds
        glass.tintColor = OrbDisplayEnvironment.shared.options.opaqueSurfaces ? nil : NSColor.windowBackgroundColor.withAlphaComponent(0.42)
        clip.frame = capsuleFrame; clipMask.frame = clip.bounds
        clipMask.path = CGPath(roundedRect: clip.bounds, cornerWidth: glass.cornerRadius, cornerHeight: glass.cornerRadius, transform: nil)
        surfaceButton.frame = capsuleFrame; surfaceButton.participates = interactive
        surfaceButton.text = input.title + ", " + (state.event?.text ?? input.signals.words)
        let notice = state.actionEvent ?? state.event
        let wantsHalo = notice?.halo != nil && notice?.halo != NoticeHalo.none
        if wantsHalo, let notice { displayedHalo=notice }
        if haloPhase.target != (wantsHalo ? 1 : 0) { haloPhase.show(wantsHalo ? 1 : 0,delay:0.06) }
        haloPhase.step(dt)
        if input.reduceMotion { haloPhase.k=haloPhase.target; haloPhase.delay=0 }
        if haloPhase.opacity == 0 && !wantsHalo { displayedHalo=nil }
        let scope = displayedHalo?.halo ?? .none
        let haloWidth = scope == .column ? (input.noticeColumnWidth ?? input.columnWidth) : capsuleFrame.width
        halo.frame = CGRect(x: base.midX - haloWidth / 2, y: y - 8, width: haloWidth, height: max(90, capsuleFrame.height + 32))
        let color: NSColor = displayedHalo?.kind == .stoppedError ? NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
            : displayedHalo?.kind == .context ? NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)
            : displayedHalo?.kind == .done ? NSColor(srgbRed: 0.29, green: 0.90, blue: 0.45, alpha: 1) : .systemYellow
        halo.colors = [color.withAlphaComponent(0.17).cgColor, color.withAlphaComponent(0).cgColor]
        halo.opacity = Float(scope == .none || OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 0 : haloPhase.opacity)
        halo.isHidden = halo.opacity == 0
        for mode in HeaderPulseState.Mode.allCases {
            guard let plane = planes[mode], let phase = m.layers[mode] else { continue }
            let w = m.layerWidths[mode] ?? base.width
            plane.layer?.transform = CATransform3DIdentity
            plane.frame = CGRect(x: (capsuleFrame.width - w) / 2, y: 0, width: w, height: mode == .compact ? m.compactHeight : mode == .bloom ? 58 : mode == .action ? 86 : 116)
            plane.alphaValue = phase.opacity; plane.isHidden = phase.opacity == 0
            plane.layer?.setAffineTransform(CGAffineTransform(translationX: w * (1 - phase.scale) / 2, y: plane.frame.height * (1 - phase.scale) / 2).scaledBy(x: phase.scale, y: phase.scale))
            setContentBlur(plane,radius:phase.blur,enabled:phase.opacity > 0 && phase.opacity < 1 && !input.reduceMotion)
        }
        labels["compactTitle"]?.font = .systemFont(ofSize: input.variant == .brief ? 12 : 13, weight: .semibold)
        put("compactTitle", input.title, 32, (m.compactHeight - 16) / 2, (m.layerWidths[.compact] ?? 0) - 80, 16)
        let ringFraction = snapshot.progress ?? ((input.signals.context ?? 0) >= 0.8 ? input.signals.context : nil)
        let nextTrail = ringFraction != nil ? "ring" : hasClock ? "time" : "chevron"
        trailSwap.put(nextTrail); trailSwap.step(dt)
        let shownTrail = trailSwap.text
        put("compactTrail", shownTrail == "time" ? elapsed : "›", (m.layerWidths[.compact] ?? 0) - 46, (m.compactHeight - 14) / 2, 34, 14)
        labels["compactTrail"]?.alignment = .right
        progressRing.isHidden = shownTrail != "ring"
        progressRing.alphaValue = trailSwap.opacity
        labels["compactTrail"]?.alphaValue = trailSwap.opacity
        progressRing.fraction = ringFraction ?? 0
        progressRing.tint = snapshot.progress != nil ? input.identity.tint.color : NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)
        progressRing.frame = CGRect(x: (m.layerWidths[.compact] ?? 0) - 26, y: (m.compactHeight - 14) / 2, width: 14, height: 14)
        labels["compactTrail"]?.isHidden = shownTrail == "ring"
        if let trail=labels["compactTrail"] { applySwap(trailSwap,to:trail,reduced:input.reduceMotion) }
        applySwap(trailSwap,to:progressRing,reduced:input.reduceMotion)
        let bw = m.layerWidths[.bloom] ?? 288
        put("bloomTitle", input.title, 42, 13, bw - 104, 14)
        let text = state.event?.text ?? swap.text
        swap.put(text, immediate: previousMode != .bloom && state.mode == .bloom || state.event?.progress != nil)
        swap.step(dt)
        put("bloomText", swap.text, 42, 27, bw - 104, 18)
        labels["bloomText"]?.alphaValue = swap.opacity
        if let text=labels["bloomText"] { setContentBlur(text,radius:(1-swap.opacity)*6,enabled:!input.reduceMotion && swap.opacity > 0 && swap.opacity < 1) }
        labels["bloomText"]?.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.98 + 0.02 * swap.opacity, y: 0.98 + 0.02 * swap.opacity))
        labels["bloomText"]?.textColor = notice?.kind == .retryingError || notice?.kind == .stoppedError ? NSColor(srgbRed: 1, green: 0.48, blue: 0.44, alpha: 1) : .white.withAlphaComponent(0.92)
        let trail = notice?.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? notice?.context.map { "\(Int(($0 * 100).rounded()))%" } ?? elapsed
        put("bloomTrail", trail, bw - 56, 22, 38, 14); labels["bloomTrail"]?.alignment = .right
        let aw = m.layerWidths[.action] ?? 292
        put("actionTitle", input.title, 38, 10, aw - 56, 14)
        if let action=state.actionEvent { displayedAction=action }
        else if (m.layers[.action]?.opacity ?? 0) == 0 { displayedAction=nil }
        put("actionText", displayedAction?.text ?? "", 18, 24, aw - 36, 18)
        var right = aw - 18
        for i in buttons.indices.reversed() {
            let button = buttons[i], choice = displayedAction?.buttons.indices.contains(i) == true ? displayedAction!.buttons[i] : nil
            let measured = Double(((choice?.title ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
            let width = min((aw - 42) / 2, max(54, measured + 24))
            right -= width; button.frame = CGRect(x: right, y: 47, width: width, height: 26); right -= 6
            button.text = choice?.title ?? ""; button.tint = .white
            button.layer?.backgroundColor = (i == 1 ? NSColor(srgbRed: 0.20, green: 0.47, blue: 0.96, alpha: 1) : NSColor.white.withAlphaComponent(0.13)).cgColor
            button.isHidden = choice == nil
            button.participates = interactive && state.actionEvent?.requestID == displayedAction?.requestID && state.mode == .action && (m.layers[.action]?.opacity ?? 0) > 0.5 && choice != nil
            button.isEnabled = submittedRequest == nil && snapshot.pending.first(where: { $0.requestID == state.actionEvent?.requestID })?.submitting != true
            button.focus = { [weak self] in self?.focus($0) }
            button.invoke = { [weak self] in
                guard let self, let choice, self.interactive, self.state.mode == .action, self.state.actionEvent?.buttons.contains(choice) == true, self.submittedRequest == nil else { return }
                self.submittedRequest = self.state.actionEvent?.requestID
                self.submittedAge = 0
                self.onAction?(choice.action); self.refresh(dt: 0)
            }
        }
        let ew = m.layerWidths[.expanded] ?? 336, cell = (ew - 48) / 2
        put("expandedTitle", input.title, 18, 12, ew - 36, 16)
        let values = [input.signals.satellites.isEmpty ? "None" : "\(input.signals.satellites.filter { !$0.done }.count) running",
                      input.signals.files == 0 ? "None" : "+\(input.signals.added) −\(input.signals.removed)",
                      input.signals.context.map { "\(Int(($0 * 100).rounded()))% used" } ?? "Unreported", input.signals.words]
        for i in 0..<4 {
            let x = 18 + Double(i % 2) * (cell + 12), y = 36 + Double(i / 2) * 35
            put("key\(i)", labels["key\(i)"]!.stringValue, x, y, cell, 13)
            put("value\(i)", values[i], x, y + 13, cell, 16)
            detailButtons[i].frame = CGRect(x: x, y: y, width: cell, height: 29)
            detailButtons[i].participates = interactive && state.mode == .expanded && (m.layers[.expanded]?.opacity ?? 0) > 0.5
        }
        let mark: PulseLeadView.Mark = input.signals.error != nil ? .error
            : !snapshot.pending.filter({$0.kind == .approval}).isEmpty ? .approval(snapshot.pending.filter{$0.kind == .approval}.count)
            : snapshot.pending.contains(where:{$0.kind == .question}) ? .question
            : notice?.kind == .done || snapshot.terminalStatus == "completed" ? .done : input.signals.running ? .working : .idle
        for mode in [HeaderPulseState.Mode.compact, .bloom, .action] {
            leads[mode]?.frame = CGRect(x: mode == .compact ? 12 : 18, y: mode == .compact ? (m.compactHeight - 14) / 2 : mode == .bloom ? 22 : 10, width: 14, height: 14)
            var status = leadSwaps[mode] ?? PulseTextSwap()
            status.put(mark.key); status.step(dt); leadSwaps[mode]=status
            leads[mode]?.mark = PulseLeadView.Mark(key:status.text)
            if let lead=leads[mode] { applySwap(status,to:lead,reduced:input.reduceMotion) }
        }
        onPose?(m.kick.x)
        let expanded=state.mode == .expanded || state.pinned
        if !suspended && (expanded != reportedExpanded || state.pinned != reportedPinned) {
            reportedExpanded=expanded;reportedPinned=state.pinned;onExpansion?(expanded,state.pinned)
        }
    }

    /// Retain one disabled filter per content layer instead of allocating filters on animation frames.
    private func setContentBlur(_ view:NSView,radius:Double,enabled:Bool,prepare:Bool=false) {
        let id=ObjectIdentifier(view)
        if blurFilters[id] == nil, enabled || prepare,
           let filter=OverlayFilter.make("gaussianBlur",values:["name":"pulseContentBlur","inputRadius":0,"enabled":false]) {
            blurFilters[id]=filter; view.layer?.filters=[filter]; filterBuilds+=1
        }
        blurFilters[id]?.setValue(enabled ? radius:0,forKey:"inputRadius")
        blurFilters[id]?.setValue(enabled,forKey:"enabled")
    }
    private var warmViews:[NSView] {
        var result:[NSView]=HeaderPulseState.Mode.allCases.compactMap { planes[$0] }
        result += [labels["bloomText"],labels["compactTrail"]].compactMap { $0 }
        result += [HeaderPulseState.Mode.compact,.bloom,.action].compactMap { leads[$0] }
        result.append(progressRing);return result
    }
    private func stopIdleWarmup() {
        if let warmObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(),warmObserver,.commonModes) }
        warmObserver=nil
    }
    private func requestIdleWarmup() {
        guard warmObserver == nil, warmIndex<warmViews.count, window != nil else { return }
        warmObserver=CFRunLoopObserverCreateWithHandler(nil,CFRunLoopActivity.beforeWaiting.rawValue,true,CFIndex.max) { [weak self] _,_ in
            MainActor.assumeIsolated { self?.warmOneContentLayer() }
        }
        if let warmObserver { CFRunLoopAddObserver(CFRunLoopGetMain(),warmObserver,.commonModes) }
    }
    /// One content-only cache slice after the run loop finishes its current work. Never warm glass or mutate notices.
    func warmOneContentLayer() {
        guard !suspended, state.event == nil, motion?.busy != true, superview?.isHiddenOrHasHiddenAncestor != true else { stopIdleWarmup(); return }
        let views=warmViews
        guard warmIndex<views.count else { stopIdleWarmup(); return }
        let began=CACurrentMediaTime(), view=views[warmIndex]
        setContentBlur(view,radius:0,enabled:false,prepare:true)
        if !view.bounds.isEmpty, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:bitmap) }
        let cost=(CACurrentMediaTime()-began)*1000
        warmTotalMS+=cost;warmMaxMS=max(warmMaxMS,cost);warmSlices+=1;warmIndex+=1
        if warmIndex>=views.count { stopIdleWarmup() } else { CFRunLoopWakeUp(CFRunLoopGetMain()) }
    }

    private func applySwap(_ swap: PulseTextSwap, to view: NSView, reduced: Bool) {
        let opacity=reduced ? 1:swap.opacity
        view.alphaValue=opacity
        setContentBlur(view,radius:(1-opacity)*6,enabled:!reduced && opacity > 0 && opacity < 1)
        view.layer?.setAffineTransform(CGAffineTransform(scaleX:0.98+0.02*opacity,y:0.98+0.02*opacity))
    }

    private func put(_ key: String, _ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        guard let label = labels[key] else { return }
        if label.stringValue != text { label.stringValue = text }
        label.frame = CGRect(x: x, y: y, width: max(0, width), height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard interactive, !isHidden, NSBezierPath(roundedRect: capsuleFrame, xRadius: glass.cornerRadius, yRadius: glass.cornerRadius).contains(p) else { return nil }
        for button in buttons + detailButtons where button.participates && !button.isHiddenOrHasHiddenAncestor {
            if button.convert(button.bounds, to: self).contains(p) { return button }
        }
        return surfaceButton
    }

    var probe: [String: Any] {
        ["mode": state.mode.rawValue, "event": state.event?.kind.rawValue ?? "none", "halo": (state.actionEvent ?? state.event)?.halo.rawValue ?? "none",
         "rect": [capsuleFrame.minX, capsuleFrame.minY, capsuleFrame.width, capsuleFrame.height], "remaining": state.remaining,
         "glassFilters": glass.layer?.filters?.count ?? 0,
         "haloAlpha": Double(halo.opacity), "haloWidth": halo.frame.width,
         "actionAlpha": motion?.layers[.action]?.opacity ?? 0, "actionText": labels["actionText"]?.stringValue ?? "",
         "drawnButtons": buttons.filter { !$0.isHidden }.map(\.text),
         "leadKey": leadSwaps[.compact]?.text ?? "", "leadAlpha": leadSwaps[.compact]?.opacity ?? 1,
         "trailKey": trailSwap.text, "trailAlpha": trailSwap.opacity, "sampleTime": lastTime ?? 0,
         "suspended": suspended, "filterBuilds":filterBuilds,"warmSlices":warmSlices,"warmTotalMS":warmTotalMS,"warmMaxMS":warmMaxMS,
         "sampleMS":sampleMS,"maxSampleMS":maxSampleMS,"maxClockGapMS":maxClockGapMS,"buttons": buttons.filter(\.participates).map(\.text)]
    }
}

@MainActor private final class PulseRingView: IslandPlane {
    var fraction = 0.0 { didSet { if oldValue != fraction { needsDisplay=true } } }
    var tint = NSColor.white
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let ring=NSBezierPath(ovalIn:bounds.insetBy(dx:1.5,dy:1.5));ring.lineWidth=2
        NSColor.white.withAlphaComponent(0.16).setStroke();ring.stroke()
        let arc=NSBezierPath();arc.lineWidth=2;arc.lineCapStyle = .round
        arc.appendArc(withCenter:CGPoint(x:7,y:7),radius:5.5,startAngle:-90,endAngle:-90+360*min(1,max(0,fraction)),clockwise:false)
        tint.setStroke();arc.stroke()
    }
}

@MainActor private final class PulseLeadView: IslandPlane {
    enum Mark: Equatable {
        case idle, working, done, approval(Int), question, error
        var key: String {
            switch self { case .idle: "idle"; case .working: "working"; case .done: "done"; case .approval(let n): "approval:\(n)"; case .question: "question"; case .error: "error" }
        }
        init(key: String) {
            switch key { case "working": self = .working; case "done": self = .done; case "question": self = .question; case "error": self = .error
            default: self = key.hasPrefix("approval:") ? .approval(Int(key.dropFirst(9)) ?? 1) : .idle }
        }
    }
    // The containing Pulse supplies one finite kick/swap per notice. Working ink has no clock.
    var mark = Mark.idle { didSet { if mark != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        switch mark {
        case .idle: return
        case .working:
            for i in 0..<3 {
                NSColor.white.withAlphaComponent(0.75).setFill()
                NSBezierPath(ovalIn:CGRect(x:0.5+Double(i)*5,y:5.5,width:3,height:3)).fill()
            }
        case .done:
            let path=NSBezierPath();path.move(to:CGPoint(x:3,y:7.4));path.line(to:CGPoint(x:5.9,y:10.2));path.line(to:CGPoint(x:11,y:4.2))
            path.lineWidth=1.8;path.lineCapStyle = .round;path.lineJoinStyle = .round
            NSColor(srgbRed:0.29,green:0.90,blue:0.45,alpha:1).setStroke();path.stroke()
        case .approval(let n): badge(String(min(9,n)), error:false)
        case .question: badge("?",error:false)
        case .error: badge("!",error:true)
        }
    }
    private func badge(_ text:String,error:Bool) {
        (error ? NSColor(srgbRed:1,green:0.27,blue:0.23,alpha:1):NSColor(srgbRed:1,green:0.84,blue:0.04,alpha:1)).setFill()
        NSBezierPath(ovalIn:bounds).fill()
        let p=NSMutableParagraphStyle();p.alignment = .center
        (text as NSString).draw(in:CGRect(x:0,y:1,width:14,height:12),withAttributes:[.font:NSFont.systemFont(ofSize:9,weight:.heavy),.foregroundColor:error ? NSColor.white:NSColor.black,.paragraphStyle:p])
    }
}
