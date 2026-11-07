import AppKit

struct OverlayLyricPlacement: Equatable {
    let id: String
    let y: CGFloat
    let current: Bool
    var opacity: Double = 1
    var blur: CGFloat = 0
    var scale: CGFloat = 1
}

@MainActor final class OverlayModelPicker: OverlaySurface {
    private let backdrop = OverlayBackdrop()
    private let lyrics = OverlayView(), extras = OverlayView()
    private let captionRow = OverlayView()
    private let capsule = NSGlassEffectView()
    private let capsuleContent = OverlayView()
    let reasoning: OverlayReasoningSlider
    let speedSelector: OverlaySpeedSelector
    private let caption = OverlayGradientLabel(labelWithString: "")
    private let daybreak = OverlayPlateButton(frame: .zero), reset = OverlayPlateButton(frame: .zero)
    private var viewportSize: CGSize?
    private var updating = false
    private var rows: [String: OverlayLyricRow] = [:]
    private(set) var settings = ModelSettings()
    private(set) var models: [ModelCatalog.Model] = []
    private var base: ModelSettings?
    private var reportedIDs: Set<String> = []
    private(set) var note: String?
    private(set) var scrolling = false
    private var wheel: CGFloat = 0
    private var lastNotch: Double = -.infinity
    private var wheelIdle: OverlayCancellation?
    private(set) var capsuleRect = CGRect.zero
    /// The capsule between the model button (0) and its place (1; morphIn overshoots past 1). Its frame follows this
    /// every frame on the main thread: a glass size cannot animate on the render server, and a scale transform squashed
    /// the glass and the slider inside it (user, 2026-10-29: "失真变形").
    private(set) var morphProgress: Double = 1
    private var morphRun: (from: Double, to: Double, start: TimeInterval, curve: OverlayCurve)?
    private var morphLink: CADisplayLink?
    private var morphTick: OverlayCancellation?
    private var morphEarlierProgress: Double?
    private(set) var placements: [OverlayLyricPlacement] = []
    var onSettingsChange: ((ModelSettings) -> Void)?
    var onModelSelected: ((ModelCatalog.Model) -> Void)?
    var onEffortSelected: ((Effort) -> Void)?
    var onTierSelected: ((Speed) -> Void)?
    var selectedModel: ModelCatalog.Model? { models.first { $0.id == settings.modelID } }
    override var interactiveRects: [CGRect] {
        rows.values.filter { !$0.isHidden && $0.motionLayer.opacity != 0 }.map { convert($0.bounds, from: $0) }
            + [capsuleRect, convert(daybreak.bounds, from: daybreak), convert(speedSelector.bounds, from: speedSelector)]
            + (reset.isHidden ? [] : [convert(reset.bounds, from: reset)])
    }
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        reasoning = OverlayReasoningSlider(clock: clock); speedSelector = OverlaySpeedSelector(clock: clock)
        super.init(clock: clock)
        for view in [backdrop, lyrics, extras, capsule] { view.wantsLayer = true; addSubview(view) }
        capsule.cornerRadius = 24; capsule.contentView = capsuleContent; capsuleContent.addSubview(reasoning)
        captionRow.wantsLayer = true; extras.addSubview(captionRow); extras.addSubview(speedSelector)
        for view in [caption, daybreak, reset] { captionRow.addSubview(view) }
        caption.wantsLayer = true
        caption.font = .systemFont(ofSize: 11, weight: .semibold); caption.textColor = .secondaryLabelColor; caption.maximumNumberOfLines = 2
        caption.cell?.wraps = true; caption.lineBreakMode = .byWordWrapping
        daybreak.title = "Daybreak"
        daybreak.image = NSImage(systemSymbolName: "sunrise.fill", accessibilityDescription: nil)
        daybreak.invoke = { [weak self] in guard let self, self.isShowing, !self.isDismissing else { return }; self.toggleDaybreak() }
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to This Chat’s Settings")
        reset.setAccessibilityLabel("Reset to This Chat’s Settings")
        reset.invoke = { [weak self] in guard let self, self.isShowing, !self.isDismissing, let base = self.base else { return }; self.publish(base) }
        reasoning.onSelect = { [weak self] in _ = self?.selectEffort($0) }
        speedSelector.onSelect = { [weak self] in _ = self?.selectTier($0) }
        setAccessibilityLabel("Model, reasoning and speed")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(settings: ModelSettings, base: ModelSettings? = nil, models: [ModelCatalog.Model] = ModelCatalog.models) {
        self.settings = settings; self.base = base
        var seen: Set<String> = []; self.models = models.filter { seen.insert($0.id).inserted }
        reportedIDs = seen
        note = nil
        if !self.models.contains(where: { $0.id == settings.modelID }) {
            self.models.append(.init(id: settings.modelID, name: settings.modelID, version: "", efforts: [], serviceTiers: [], reportedByCore: true))
            note = "This model is no longer reported by Core."
        }
        if let model = selectedModel, !model.availableSpeeds.contains(self.settings.speed) {
            let message = "\(self.settings.speed.label) is not available for this model. Using Standard."
            note = [note, message].compactMap { $0 }.joined(separator: " "); self.settings.speed = .standard
        }
        if let model = selectedModel, !model.efforts.isEmpty, !model.efforts.contains(self.settings.effort) { self.settings.effort = remembered(model) }
        syncRows(); if isShowing { update(animated: false) }
        if self.settings != settings { onSettingsChange?(self.settings) }
    }
    func available(_ model: ModelCatalog.Model) -> Bool {
        reportedIDs.contains(model.id) && (!settings.daybreak || (model.reportedByCore ? (model.cyberPrograms ?? []).contains("daybreakBlue") : ModelCatalog.daybreakModels.contains(model.id)))
    }
    private func remembered(_ model: ModelCatalog.Model) -> Effort {
        if let effort = settings.memory[model.id], model.efforts.contains(effort) { return effort }
        if let effort = model.defaultEffortValue, model.efforts.contains(effort) { return effort }
        return model.efforts.contains(.high) ? .high : model.efforts.last ?? .none
    }
    @discardableResult func selectModel(_ id: String) -> Bool {
        guard let model = models.first(where: { $0.id == id }), available(model) else { return false }
        guard id != settings.modelID else { return true }
        var next = settings; next.memory[next.modelID] = next.effort; next.modelID = id; next.effort = remembered(model)
        publish(next); return true
    }
    @discardableResult func selectEffort(_ effort: Effort) -> Bool {
        guard selectedModel?.efforts.contains(effort) == true else { return false }
        var next = settings; next.effort = effort; next.memory[next.modelID] = effort; publish(next); return true
    }
    @discardableResult func selectTier(_ tier: Speed) -> Bool {
        guard selectedModel?.availableSpeeds.contains(tier) == true else { return false }
        var next = settings; next.speed = tier; publish(next); return true
    }
    func toggleDaybreak() {
        var next = settings; next.daybreak.toggle(); note = nil
        if next.daybreak, let current = selectedModel, !(current.reportedByCore ? (current.cyberPrograms ?? []).contains("daybreakBlue") : ModelCatalog.daybreakModels.contains(current.id)) {
            guard let model = models.first(where: { $0.reportedByCore ? ($0.cyberPrograms ?? []).contains("daybreakBlue") : ModelCatalog.daybreakModels.contains($0.id) }) else {
                note = "Daybreak is not available for this account’s models"; update(animated: false); return
            }
            note = "Daybreak · switched from " + current.full; next.memory[next.modelID] = next.effort; next.modelID = model.id; next.effort = remembered(model)
        }
        publish(next, retainingNote: true)
    }
    private func publish(_ proposed: ModelSettings, retainingNote: Bool = false) {
        var next = proposed
        if !retainingNote { note = nil }
        if let model = models.first(where: { $0.id == next.modelID }), !model.availableSpeeds.contains(next.speed) {
            let message = "\(next.speed.label) is not available for this model. Using Standard."
            note = [note, message].compactMap { $0 }.joined(separator: " "); next.speed = .standard
        }
        let previous = settings; settings = next
        update(animated: previous != next)
        guard previous != next else { return }
        onSettingsChange?(next)
        if previous.modelID != next.modelID, let model = selectedModel { onModelSelected?(model) }
        if previous.effort != next.effort { onEffortSelected?(next.effort) }
        if previous.speed != next.speed { onTierSelected?(next.speed) }
    }
    override func handleKey(_ key: OverlayKey) -> Bool {
        guard isShowing, !isDismissing else { return false }
        switch key {
        case .up, .down:
            let usable = models.filter(available)
            if let i = usable.firstIndex(where: { $0.id == settings.modelID }), !usable.isEmpty {
                let next = usable[min(max(0, i + (key == .up ? -1 : 1)), usable.count - 1)]
                _ = selectModel(next.id)
            }
        case .left, .right: _ = reasoning.step(key == .left ? -1 : 1)
        case .escape: dismiss(reason: .escape)
        case .enter: dismiss(reason: .enter)
        }
        return true
    }
    @discardableResult func wheel(deltaY: CGFloat, precise: Bool) -> Bool {
        guard isShowing, !isDismissing else { return false }
        let delta = -deltaY * (precise ? 1 : 40); guard delta != 0 else { return true }
        let entering = !scrolling, previousID = settings.modelID
        if entering { scrolling = true; wheel = 0 }
        var step = 0
        if abs(delta) >= 40 { step = delta > 0 ? 1 : -1; wheel = 0 }
        else { if (wheel > 0) != (delta > 0) { wheel = 0 }; wheel += delta; if abs(wheel) >= 60 { step = wheel > 0 ? 1 : -1; wheel = 0 } }
        if step != 0, clock.now - lastNotch > 0.045 { lastNotch = clock.now; _ = handleKey(step > 0 ? .down : .up) }
        // Entering and selecting on the same notch form one transaction, as in v1's SwiftUI update.
        if entering && settings.modelID == previousID { update(animated: true) }
        wheelIdle?.cancel(); wheelIdle = clock.schedule(after: 1.1) { [weak self] in self?.scrolling = false; self?.update(animated: true) }
        return true
    }
    override func scrollWheel(with event: NSEvent) { _ = wheel(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, bounds.contains(convert(point, from: superview)) else { return nil }
        if isDismissing { return self }
        let p = convert(point, from: superview)
        for row in rows.values where convert(row.bounds, from: row).contains(p) && (row.motionLayer.opacity) > 0 { return row }
        if [capsuleRect, convert(speedSelector.bounds, from: speedSelector), convert(daybreak.bounds, from: daybreak)].contains(where: { $0.contains(p) }) || (!reset.isHidden && convert(reset.bounds, from: reset).contains(p)) { return super.hitTest(point) }
        return self
    }
    private func syncRows() {
        let ids = Set(models.map(\.id))
        for id in Array(rows.keys) where !ids.contains(id) { rows.removeValue(forKey: id)?.removeFromSuperview() }
        for model in models where rows[model.id] == nil {
            let row = OverlayLyricRow(clock: clock); rows[model.id] = row; lyrics.addSubview(row)
            row.invoke = { [weak self] in
                guard let self, self.settings.modelID != model.id else { return }
                self.scrolling = false; self.wheelIdle?.cancel(); _ = self.selectModel(model.id)
            }
            row.onHover = { [weak self, weak row] hovered in
                guard let self, let row, model.id != self.settings.modelID, self.available(model) else { return }
                OverlayMotion.animate(row.motionLayer, "opacity", from: 0.34, to: hovered ? 0.62 : 0.34, curve: OverlayMotion.ease(0.25), enabled: !self.reduceMotion)
            }
        }
    }
    override func present(anchor: CGRect, in host: NSView) { viewportSize = nil; super.present(anchor: anchor, in: host) }
    override func layout() { super.layout(); if viewportSize != bounds.size { update(animated: false) } }
    private func update(animated: Bool) {
        guard isShowing, !updating else { return }; updating = true; defer { updating = false }; viewportSize = bounds.size
        let layout = Self.lyricLayout(models: models, selected: settings.modelID, scrolling: scrolling)
        placements = layout.lines
        let width: CGFloat = 348, height = layout.height + 44 + 48 + 77
        let left = min(max(anchorRect.midX - width / 2, 12), max(12, bounds.width - 12 - width)), top = bounds.height - 22 - height
        let oldTop = lyrics.frame.minY
        lyrics.frame = snapped(CGRect(x: left, y: top, width: width, height: layout.height))
        for placement in layout.lines {
            guard let row = rows[placement.id], let model = models.first(where: { $0.id == placement.id }) else { continue }
            let oldY = oldTop + row.frame.minY + OverlayMotion.scalar(row.motionLayer, "transform.translation.y")
            let oldScale = row.renderScale * OverlayMotion.scalar(row.fontLayer, "transform.scale")
            let oldDepth = OverlayMotion.scalar(row.motionLayer, "transform.scale")
            let oldOpacity = OverlayMotion.scalar(row.motionLayer, "opacity")
            let oldBlur = row.motionLayer.filters?.isEmpty == false ? OverlayMotion.scalar(row.motionLayer, "filters.overlayBlur.inputRadius") : 0
            let effort = placement.current ? settings.effort : remembered(model)
            let wordChange = placement.current && row.isCurrent && !row.word.text.isEmpty && row.word.text != effort.label
            row.configure(model, effort: effort, current: placement.current, available: available(model), reduceMotion: reduceMotion, animateWord: wordChange && animated, unavailableReason: reportedIDs.contains(model.id) ? "Not with Daybreak" : "Unavailable from Core")
            row.frame = snapped(CGRect(x: 0, y: placement.y, width: width, height: placement.current ? 40 : 28))
            row.prepareMotion(); row.prepareFont()
            let scale = placement.scale
            let opacity = placement.opacity * (placement.current ? 1 : available(model) ? 0.34 : 0.14)
            // AppKit owns this backing layer's top-left anchor. The 40pt lyric's leading-midpoint
            // scale is equivalent to top-left scaling plus 20 * (1 - depth), on the same glide curve.
            let centre = 20 * (1 - scale)
            OverlayMotion.animate(row.motionLayer, "transform.translation.y", from: animated ? oldY - lyrics.frame.minY - row.frame.minY : centre, to: centre, curve: scrolling ? OverlayMotion.glideFast : OverlayMotion.glide, enabled: animated && !reduceMotion, retarget: false)
            OverlayMotion.animate(row.motionLayer, "transform.scale", from: oldDepth, to: scale, curve: scrolling ? OverlayMotion.glideFast : OverlayMotion.glide, enabled: animated && !reduceMotion, retarget: false)
            OverlayMotion.animate(row.fontLayer, "transform.scale", from: oldScale / row.renderScale, to: 1, curve: scrolling ? OverlayMotion.growFast : OverlayMotion.grow, enabled: animated && !reduceMotion, retarget: false)
            OverlayMotion.animate(row.motionLayer, "opacity", from: oldOpacity, to: opacity, curve: OverlayMotion.ease(scrolling ? 0.28 : 0.35), enabled: animated && !reduceMotion, retarget: false)
            if !animated && placement.blur == 0 { row.motionLayer.filters = nil }
            else { OverlayFilter.installBlur(on: row.motionLayer) }
            if row.motionLayer.filters?.isEmpty == false { OverlayMotion.animate(row.motionLayer, "filters.overlayBlur.inputRadius", from: oldBlur, to: placement.blur, curve: OverlayMotion.ease(scrolling ? 0.28 : 0.35), enabled: animated && !reduceMotion, retarget: false) }
            row.accumulate(enabled: animated && !reduceMotion)
        }
        capsuleRect = snapped(CGRect(x: left, y: top + layout.height + 44, width: width, height: 48))
        reasoning.reduceMotion = reduceMotion; placeCapsule()
        if let model = selectedModel { reasoning.configure(levels: model.efforts, value: settings.effort, daybreak: settings.daybreak); speedSelector.reduceMotion = reduceMotion; speedSelector.configure(value: settings.speed, allowed: model.availableSpeeds) }
        extras.frame = bounds
        captionRow.frame = snapped(CGRect(x: left, y: top + layout.height + 2, width: width, height: 30))
        // DaybreakButton: sized to its content (10 / 12 pt insets), the trailing end of the caption row.
        daybreak.leadingInset = 10
        daybreak.frame = snapped(CGRect(x: width - daybreak.naturalWidth, y: 0, width: daybreak.naturalWidth, height: 30))
        daybreak.contentTintColor = .labelColor; daybreak.setAccessibilityValue(settings.daybreak ? "On" : "Off")
        // Off: the dawn icon (LyricStyle.dawn) and a primary title; on: both dark on the dawn fill.
        daybreak.imageTintColor = NSColor(srgbRed: 1, green: 0xbe / 255, blue: 0x6e / 255, alpha: 1)
        daybreak.fillColors = settings.daybreak ? OverlayStyle.dawn : []
        if settings.daybreak { daybreak.contentTintColor = NSColor(srgbRed: 0x2a / 255, green: 0x14 / 255, blue: 0x06 / 255, alpha: 1); daybreak.imageTintColor = nil }
        reset.isHidden = base == nil || base == settings; reset.frame = snapped(CGRect(x: daybreak.frame.minX - 40, y: daybreak.frame.minY, width: 30, height: 30))
        caption.stringValue = note ?? (settings.effort == .ultra ? "Uses your limits faster" : "")
        caption.gradient = note == nil && settings.effort == .ultra ? OverlayStyle.ultra : []
        caption.textColor = caption.gradient.isEmpty ? .secondaryLabelColor : .white
        caption.frame = snapped(CGRect(x: 0, y: 0, width: width - 160, height: 30))
        speedSelector.frame = snapped(CGRect(x: left + 8, y: capsuleRect.maxY + 10, width: 332, height: 71)); speedSelector.layoutSubtreeIfNeeded()
        backdrop.frame = snapped(CGRect(x: left - 210, y: top - 190, width: width + 420, height: height + 330)); backdrop.layoutSubtreeIfNeeded()
    }
    override func animateIn() {
        reasoning.resumeAmbient()
        // Populate all capsule pixels before installing the caption's render-server blur/rise animations.
        // cacheDisplay tests are synchronous; a newly mounted, layer-backed window is not.
        captionRow.displayIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lyrics.layer?.opacity = 1; lyrics.layer?.setValue(0, forKeyPath: "transform.translation.y"); extras.layer?.opacity = 1
        CATransaction.commit()
        if usesGaussian {
            rows.values.forEach { $0.resetExposure() }
            contentAppearance(placements.compactMap { rows[$0.id] } + [caption, speedSelector.label] + speedSelector.buttons, visible: true)
            containerAppearance([daybreak, reset, speedSelector.glassAppearanceView], visible: true)
            speedSelector.enter(curve: OverlayMotion.capIn, delay: 0, animated: !reduceMotion, contentGaussian: true)
            morph(showing: true)
            backdrop.prepareGaussian(); containerAppearance([backdrop], visible: true)
            return
        }
        for (i, placement) in placements.enumerated() { if let row = rows[placement.id] { OverlayMotion.entrance(row, order: placements.count - 1 - i, enabled: !reduceMotion) } }
        OverlayMotion.entrance(caption, blur: 3, enabled: !reduceMotion)
        for button in [daybreak, reset] { OverlayMotion.animate(button.layer!, "opacity", from: 0, to: 1, curve: OverlayMotion.rise, enabled: !reduceMotion, retarget: false) }
        speedSelector.enter(curve: OverlayMotion.capIn, delay: 0.05, animated: !reduceMotion)
        OverlayMotion.entrance(speedSelector.label, blur: 3, rise: 18, curve: OverlayMotion.ease(0.5), delay: 0.13, enabled: !reduceMotion)
        morph(showing: true)
        backdrop.transition(from: 0.55, to: 1, curve: OverlayMotion.blurIn, enabled: !reduceMotion)
        OverlayMotion.animate(backdrop.layer!, "opacity", from: 0, to: 1, curve: OverlayMotion.blurIn, enabled: !reduceMotion, retarget: false)
    }
    override func animateOut() {
        morph(showing: false)
        if usesGaussian {
            rows.values.forEach { $0.resetExposure() }
            contentAppearance(placements.compactMap { rows[$0.id] } + [caption, speedSelector.label] + speedSelector.buttons, visible: false)
            containerAppearance([daybreak, reset, speedSelector.glassAppearanceView, backdrop], visible: false)
            return
        }
        OverlayMotion.animate(lyrics.layer!, "opacity", from: 1, to: 0, curve: OverlayMotion.closeFade, enabled: !reduceMotion)
        OverlayMotion.animate(lyrics.layer!, "transform.translation.y", from: 0, to: 10, curve: OverlayMotion.closeSink, enabled: !reduceMotion)
        OverlayMotion.animate(extras.layer!, "opacity", from: 1, to: 0, curve: OverlayMotion.closeExtras, enabled: !reduceMotion)
        backdrop.transition(from: 1, to: 0.7, curve: OverlayMotion.blurOut, enabled: !reduceMotion)
        OverlayMotion.animate(backdrop.layer!, "opacity", from: 1, to: 0, curve: OverlayMotion.blurOut, enabled: !reduceMotion)
    }
    private func morph(showing: Bool) {
        guard let layer = capsule.layer else { return }
        let curve = showing ? OverlayMotion.morphIn : OverlayMotion.morphOut
        OverlayMotion.animate(layer, "opacity", from: showing ? 0.5 : 1, to: showing ? 1 : 0, curve: curve, enabled: !reduceMotion, retarget: !showing)
        stopMorph()
        let from = showing ? 0 : morphProgress, to: Double = showing ? 1 : 0
        guard !reduceMotion else { morphProgress = to; placeCapsule(); return }
        morphRun = (from, to, clock.now, curve); morphProgress = from; morphEarlierProgress = from; placeCapsule()
        if clock is OverlaySystemClock {
            let link = capsule.displayLink(target: self, selector: #selector(morphFrame)); link.add(to: .main, forMode: .common); morphLink = link
        } else { scheduleMorphTick() }
    }
    private func scheduleMorphTick() { morphTick = clock.schedule(after: 1.0 / 60) { [weak self] in self?.morphFrame() } }
    @objc private func morphFrame() {
        guard let run = morphRun else { stopMorph(); return }
        let t = min(1, (clock.now - run.start) / run.curve.duration)
        let profile = OverlayExposure.profile(for: self)
        let previous = max(0, (clock.now - run.start - profile.frameInterval) / run.curve.duration)
        morphEarlierProgress = run.from + (run.to - run.from) * run.curve.value(at: previous)
        morphProgress = run.from + (run.to - run.from) * run.curve.value(at: t); placeCapsule()
        if t >= 1 { morphProgress = run.to; morphEarlierProgress = nil; placeCapsule(); stopMorph() } else if morphLink == nil { scheduleMorphTick() }
    }
    private func stopMorph() { morphLink?.invalidate(); morphLink = nil; morphTick?.cancel(); morphTick = nil; morphRun = nil; morphEarlierProgress = nil }
    /// The glass between the button and its place at `morphProgress`; the slider keeps its own size, centred and clipped
    /// by the growing glass, and comes up as the glass opens.
    private func placeCapsule() {
        let p = CGFloat(morphProgress), a = anchorRect, b = capsuleRect
        func geometry(_ p: CGFloat) -> CGRect {
            snapped(CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
                           width: max(1, a.width + (b.width - a.width) * p), height: max(1, a.height + (b.height - a.height) * p)))
        }
        let nominal = morphRun == nil && morphProgress == 1 ? b : geometry(p)
        let earlier = morphEarlierProgress.map { geometry(CGFloat($0)) } ?? nominal
        let rect = OverlayGlassExposure.pixelAligned(OverlayGlassExposure.rect(now: nominal, earlier: earlier, profile: OverlayExposure.profile(for: self), enabled: OverlayExposure.enabled && !reduceMotion), scale: grid)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        capsule.frame = rect; capsule.cornerRadius = min(rect.width, rect.height) / 2
        capsuleContent.frame = CGRect(origin: .zero, size: rect.size)
        capsuleContent.layer?.masksToBounds = nominal != b
        capsuleContent.layer?.cornerRadius = capsule.cornerRadius
        // Glass keeps its outward-aligned physical frame. Content follows the CONTINUOUS nominal centre:
        // rounding an odd width/height must not kick all glyphs/track pixels sideways by 1pt at a slow tail.
        // NSView layout stays on the backing grid; only this content layer receives subpixel translation.
        let centre = CGPoint(x:a.midX+(b.midX-a.midX)*p,y:a.midY+(b.midY-a.midY)*p)
        let desired = CGRect(x:centre.x-rect.minX-166,y:centre.y-rect.minY-17,width:332,height:34)
        let placed = snapped(desired)
        reasoning.frame = placed
        reasoning.layer?.transform = CATransform3DMakeTranslation(desired.minX-placed.minX,desired.minY-placed.minY,0)
        reasoning.alphaValue = min(1, max(0, (p - 0.3) / 0.5))
        CATransaction.commit()
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { stopMorph(); morphProgress = 1 }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func willDismiss(reason: OverlayDismissReason) { wheelIdle?.cancel(); reasoning.pointerUp(); reasoning.stopAmbient(); speedSelector.pointerUp(); speedSelector.stopMotion() }
    static func lyricLayout(models: [ModelCatalog.Model], selected: String, scrolling: Bool) -> (lines: [OverlayLyricPlacement], height: CGFloat) {
        let current = models.firstIndex { $0.id == selected } ?? 0
        let others = models.enumerated().filter { $0.offset != current }.map(\.element)
        var ys: [String: CGFloat] = [:], y: CGFloat = 0
        for (k, model) in others.enumerated() { if k > 0 && others[k - 1].major != model.major { y += 13 }; ys[model.id] = y; y += 32 }
        let focus = y + 10
        let lines = models.enumerated().map { i, model -> OverlayLyricPlacement in
            if i == current { return .init(id: model.id, y: focus, current: true) }
            if !scrolling { return .init(id: model.id, y: ys[model.id] ?? 0, current: false) }
            if i < current {
                let distance = current - i, gaps = (i + 1...current).filter { models[$0 - 1].major != models[$0].major }.count
                let at = focus - 10 - CGFloat(distance) * 32 - CGFloat(gaps) * 13
                return .init(id: model.id, y: at, current: false, opacity: at < -19.2 ? 0 : max(0, 1 - 0.17 * Double(distance - 1)), blur: min(4, 0.8 * CGFloat(distance - 1)), scale: 1 - 0.015 * CGFloat(distance))
            }
            return .init(id: model.id, y: focus + 48 + CGFloat(i - current - 1) * 32, current: false, opacity: 0, blur: 3)
        }
        return (lines, focus + 40)
    }
}
