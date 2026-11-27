import AppKit
import QuartzCore
import CoreImage

/// An uninstalled view module: its only inputs are a value snapshot, callbacks and a clock.
@MainActor final class FunctionPanelView: FunctionPanelPlane, NSTextFieldDelegate {
    private(set) var input: FunctionPanelInput
    private(set) var state: FunctionPanelState
    private(set) var motion = FunctionPanelMotion()
    private(set) var pinMotion = FunctionPanelActionMotion()
    private(set) var archiveMotion = FunctionPanelActionMotion()
    private(set) var geometry: FunctionPanelGeometry
    private(set) var buttons: [String: FunctionPanelButton] = [:]
    private(set) var interactiveRegions: [CGRect] = []
    private(set) var subagentText: [FunctionPanelTrackText] = []
    private(set) var renderedTexts: [String] = []
    private(set) var textFrames: [(text: String, frame: CGRect)] = []
    private(set) var liveContextRows: [FunctionPanelTrackText] = []
    private(set) var timerStarts = 0
    let nameField = NSTextField()
    let ink = FunctionPanelInk(frame: .zero)
    let nativeGlassContainer = NSGlassEffectContainerView()
    var onAction: (FunctionPanelAction) -> Void
    var onIntent: (() -> Void)?
    var onDismissFeedback: (() -> Void)?
    /// Optional presentation action for a mock host; it carries no business or runtime facts.
    var onPresentation: ((Double) -> Void)?
    private(set) var bodySnapshot = FunctionPanelBodySnapshot.empty
    func updateBodySnapshot(_ snapshot: FunctionPanelBodySnapshot) { bodySnapshot = snapshot; render() }
    let reduced: Bool
    private let automatic: Bool
    private let now: () -> Double
    private var timer: Timer?
    private var submittedTitle: String?
    private var time = 0.0
    private var glasses: [String: FunctionPanelGlass] = [:]
    private var usedButtons: Set<String> = []
    private var usedGlass: Set<String> = []
    private var buildingPage = false
    private var historyRegions: [String: CGRect] = [:]
    private func gate(_ delay: Double) -> CGFloat { CGFloat(motion.stageGate(delay, now: time)) }
    var needsFrames: Bool { motion.needsFrames || pinMotion.active || archiveMotion.active || state.pendingHover != nil
    }
    var hasTimer: Bool { timer != nil }

    init(input: FunctionPanelInput, viewport: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 820),
         column: CGRect = CGRect(x: 0, y: 0, width: 598, height: 736), reduced: Bool = false,
         automatic: Bool = true, now: @escaping () -> Double = { CACurrentMediaTime() },
         action: @escaping (FunctionPanelAction) -> Void = { _ in }) {
        self.input = input; state = FunctionPanelState(input); geometry = .init(viewport: viewport, column: column)
        self.reduced = reduced; self.automatic = automatic; self.now = now; onAction = action
        super.init(frame: viewport)
        appearance = NSAppearance(named: .darkAqua)
        nativeGlassContainer.frame = bounds; nativeGlassContainer.spacing = 8
        nativeGlassContainer.contentView = FunctionPanelPlane(frame: bounds)
        nativeGlassContainer.setAccessibilityElement(false); addSubview(nativeGlassContainer)
        ink.frame = bounds; ink.wantsLayer = true; addSubview(ink)
        nameField.isBordered = false; nameField.isBezeled = false; nameField.drawsBackground = false
        nameField.textColor = .white; nameField.font = .systemFont(ofSize: 12, weight: .semibold)
        nameField.delegate = self; nameField.setAccessibilityLabel("Chat name"); addSubview(nameField)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { timer?.invalidate() }
    func update(_ input: FunctionPanelInput) {
        if self.input.id != input.id {
            retire()
            state = FunctionPanelState(input)
            submittedTitle = nil
        }
        if input.live != nil {
            if !state.editingTitle { state.title = input.title; state.originalTitle = input.title }
            state.bodyID = input.commands?.bodyDraft ?? input.bodyID
            if let colour = input.commands?.colourID { state.colourID = colour }
        }
        self.input = input; state.reconcile(input); render()
    }
    func resize(viewport: CGRect, column: CGRect) {
        frame = viewport; geometry = .init(viewport: viewport, column: column); ink.frame = bounds
        nativeGlassContainer.frame = bounds; nativeGlassContainer.contentView?.frame = bounds; render()
    }
    func open(page: FunctionPanelPage = .overview, at time: Double? = nil) {
        let t = time ?? (automatic ? now() : self.time); self.time = t
        state.isOpen = true; state.archived = false; state.page = page; state.focusID = "orb"
        archiveMotion.retire()
        motion.setOpen(true, at: t, reduced: reduced); render(); schedule()
        window?.makeFirstResponder(buttons["orb"])
    }
    func close(at time: Double? = nil) {
        let t = time ?? (automatic ? now() : self.time); self.time = t
        state.isOpen = false; state.option = nil; state.pendingHover = nil; state.hoveredSubagent = nil
        if state.editingTitle { cancelTitle() }
        state.focusID = nil; motion.setOpen(false, at: t, reduced: reduced)
        onAction(.closed); render(); schedule()
    }
    func selectPage(_ page: FunctionPanelPage, at time: Double? = nil) {
        let t = time ?? (automatic ? now() : self.time); self.time = t
        state.page = page; state.option = nil; state.focusID = "tab.\(page.rawValue)"
        motion.swap(at: t, reduced: reduced); render(); schedule()
    }
    func advance(to time: Double) {
        self.time = time; motion.advance(to: time); pinMotion.advance(to: time); archiveMotion.advance(to: time)
        if let hover = state.pendingHover, time >= hover.deadline {
            state.hoveredSubagent = hover.id; state.pendingHover = nil
        }
        render()
        if !needsFrames { timer?.invalidate(); timer = nil }
    }
    func retire() {
        timer?.invalidate(); timer = nil; motion.retire(); pinMotion.retire(); archiveMotion.retire()
        state.isOpen = false; state.pendingHover = nil; state.option = nil
        state.editingTitle = false; state.focusID = nil; render()
    }
    private func schedule() {
        guard automatic, needsFrames, timer == nil else { return }
        timerStarts += 1
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.advance(to: self.now()) }
        }
    }
    func beginTitle() {
        guard state.isOpen else { return }
        if input.commands?.available.contains("rename") == true { onIntent?() }
        state.editingTitle = true; state.originalTitle = state.title; state.focusID = "title"
        nameField.stringValue = submittedTitle ?? state.title
        render()
        window?.makeFirstResponder(nameField)
    }
    func setTitleDraft(_ title: String) { guard state.editingTitle else { return }; nameField.stringValue = title }
    func commitTitle() {
        guard state.editingTitle else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        state.title = trimmed.isEmpty ? state.originalTitle : trimmed
        state.editingTitle = false; state.focusID = "title.button"
        if state.title != state.originalTitle {
            if input.live != nil { submittedTitle = state.title }
            onAction(.rename(state.title))
        }
        render(); window?.makeFirstResponder(buttons["title.button"])
    }
    func cancelTitle() {
        submittedTitle = nil
        state.title = state.originalTitle; state.editingTitle = false; state.focusID = "title.button"
        nameField.stringValue = state.title; render(); window?.makeFirstResponder(buttons["title.button"])
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as AnyObject? === nameField { commitTitle() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === nameField, !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { commitTitle(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelTitle(); return true }
        return false
    }
    func escape() {
        if state.editingTitle { cancelTitle() }
        else if let option = state.option {
            state.option = nil; state.focusID = "option.\(option)"; render()
            window?.makeFirstResponder(buttons["option.\(option)"])
        }
        else if state.pinnedSubagent != nil { state.pinnedSubagent = nil; state.hoveredSubagent = nil; render() }
        else if state.page != .overview { selectPage(.overview) }
        else { close() }
    }
    func focus(_ id: String?) {
        state.focusID = id; render()
        if let id, let button = buttons[id], button.live { window?.makeFirstResponder(button) }
    }
    func hoverSubagent(_ id: String?, at time: Double) {
        state.pendingHover = (id, time + (id == nil ? 0.13 : 0.05)); schedule()
    }
    func pinSubagent(_ id: String) {
        state.pinnedSubagent = state.pinnedSubagent == id ? nil : id
        state.hoveredSubagent = nil; state.pendingHover = nil; render()
    }
    func scrollBodies(_ delta: Int) {
        state.bodyScroll = min(max(0, state.bodyScroll + delta), max(0, input.bodies.count - 8)); render()
    }
    func scrollColours(_ delta: Int) {
        state.colourScroll = min(max(0, state.colourScroll + delta), max(0, appearanceColours.count - 9)); render()
    }
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let delta = event.scrollingDeltaY > 0 ? -1 : 1
        if let id = historyRegions.first(where: { $0.value.contains(point) })?.key { scrollHistory(id, delta: -delta) }
        else if state.showsAllSubagents && geometry.placed(CGRect(x: 280, y: 0, width: 280,
                height: 264)).contains(point) { scrollSubagents(delta) }
        else if state.option == 0 { scrollBodies(delta) }
        else if state.option == 1 && input.commands != nil { scrollColours(delta) }
        else if state.page == .library { scrollLibrary(event.scrollingDeltaY > 0 ? -1 : 1) }
        else { super.scrollWheel(with: event) }
    }
    func scrollSubagents(_ delta: Int) {
        guard state.showsAllSubagents else { return }
        state.subagentOffset = min(max(0, state.subagentOffset + delta), max(0,
                (input.subagents.value?.count ?? 0) - 3))
        render()
    }
    func scrollHistory(_ id: String, delta: Int) {
        guard let agent = input.subagents.value?.first(where: { $0.id == id }) else { return }
        state.historyOffsets[id] = min(max(0, (state.historyOffsets[id] ?? 0) + delta), max(0, agent.lines.count - 5))
        render()
    }
    func scrollLibrary(_ delta: Int) {
        let rows = Int(ceil(Double(filteredCovers().count) / 3))
        state.libraryOffset = min(max(0, state.libraryOffset + delta), max(0, rows - 3)); render()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape() }
        else if event.keyCode == 48 {
            let ids = visibleButtonIDs
            if !ids.isEmpty {
                let backwards = event.modifierFlags.contains(.shift)
                let index = state.focusID.flatMap { ids.firstIndex(of: $0) } ?? (backwards ? 0 : -1)
                focus(ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count])
            }
        } else { super.keyDown(with: event) }
    }
    var visibleButtonIDs: [String] { buttons.filter { $0.value.live && !$0.value.isHidden }.keys.sorted() }
    override var acceptsFirstResponder: Bool { state.isOpen }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard state.isOpen, interactiveRegions.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
    func buttonFrame(_ id: String) -> CGRect? { buttons[id].flatMap { $0.live && !$0.isHidden ? $0.frame : nil } }
    func surfaceFrame(_ id: String) -> CGRect? { glasses[id].flatMap { $0.isHidden ? nil : $0.frame } }
    func toggleOption(_ index: Int) { state.option = state.option == index ? nil : index; render() }
    func selectBody(_ id: String) {
        guard input.bodies.contains(where: { $0.id == id }) else { return }
        state.bodyID = id; onAction(.body(id)); render()
    }
    func filteredCovers() -> [FunctionPanelCover] {
        (input.covers.value ?? []).filter { state.filter == nil || $0.kind == state.filter }
    }
    func interact(_ change: (inout FunctionPanelState) -> Void) { change(&state); render() }
    @discardableResult func button(_ id: String, _ label: String, _ rect: CGRect, symbol: String? = nil,
                                   circular: Bool = false, selected: Bool = false, filled: Bool = true,
                                   action: @escaping () -> Void) -> FunctionPanelButton {
        usedButtons.insert(id)
        let button = buttons[id] ?? FunctionPanelButton(frame: .zero)
        if button.superview == nil { addSubview(button); buttons[id] = button }
        let placed = geometry.placed(rect)
        let clipped = buildingPage ? placed.intersection(geometry.placed(FunctionPanelGeometry.panel)) : placed
        button.frame = clipped.isNull ? .zero : clipped; button.label = label; button.symbol = symbol
        button.circular = circular; button.selected = selected; button.filled = filled
        button.inkInset = 0
        button.focused = state.focusID == id; button.customPaint = nil; button.hover = nil; button.key = nil
        button.onFocus = { [weak self] focused in
            guard let self, focused, self.state.focusID != id else { return }
            self.state.focusID = id; self.render()
        }
        button.invoke = action
        button.isHidden = clipped.isEmpty
        button.live = state.isOpen && motion.progress > 0.55 && !clipped.isEmpty
        button.onBeginIntent = input.commands?.available.contains(id) == true ? {
            [weak self] in self?.onIntent?() } : nil
        button.alphaValue = buildingPage ? gate(0.71) : motion.progress
        button.live = button.live && button.alphaValue > 0.55; button.needsDisplay = true
        button.setAccessibilityValue(selected ? "Selected" : "")
        button.setAccessibilityRole(.button)
        if input.live != nil {
            let writes = ["compact", "fork", "export", "stop", "cover.open", "cover.copy", "file.open", "output.open",
                "output.copy"]
            if (writes.contains(id) || id.hasPrefix("sub.open.") || id.hasPrefix("sub.stop.") || id.hasPrefix(
                    "task.action.")) && input.commands?.available.contains(id) != true {
                button.isHidden = true; button.live = false; button.invoke = nil; button.setAccessibilityHidden(true)
                return button
            }
            if (id.hasPrefix("body.") || id.hasPrefix("colour.")) && input.commands?.available.contains(id) != true {
                button.live = false; button.invoke = nil; button.setAccessibilityRole(.image)
            }
        }
        button.setAccessibilityHidden(button.isHidden)
        if button.live { interactiveRegions.append(button.frame) }
        return button
    }
    func glass(_ id: String, _ rect: CGRect, radius: CGFloat = 24, alpha: CGFloat = 1) {
        usedGlass.insert(id)
        let surface = glasses[id] ?? FunctionPanelGlass(frame: .zero)
        if surface.superview == nil {
            addSubview(surface, positioned: .below, relativeTo: nativeGlassContainer); glasses[id] = surface
            surface.material.removeFromSuperview(); nativeGlassContainer.contentView?.addSubview(surface.material)
            surface.material.setAccessibilityElement(false)
        }
        surface.frame = geometry.placed(rect); surface.radius = radius
        surface.alphaValue = alpha * motion.progress; surface.isHidden = false; surface.layoutSubtreeIfNeeded()
        surface.material.frame = surface.frame
        surface.material.alphaValue = surface.alphaValue
        surface.material.isHidden = false
        if surface.alphaValue > 0.01 { interactiveRegions.append(surface.frame) }
    }
    func label(_ text: String, _ rect: CGRect, size: CGFloat = 12, alpha: CGFloat = 0.9,
               weight: NSFont.Weight = .regular, align: NSTextAlignment = .left, mono: Bool = false) {
        let frame = geometry.placed(rect)
        renderedTexts.append(text)
        textFrames.append((text, frame))
        ink.commands.append { FunctionPanelPaint.text(text, frame, size: size, alpha: alpha, weight: weight,
                align: align, mono: mono) }
    }
    func fill(_ rect: CGRect, colour: NSColor, radius: CGFloat = 10) {
        let frame = geometry.placed(rect)
        ink.commands.append { FunctionPanelPaint.plate(frame, radius: radius, fill: colour) }
    }
    func pageRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: 66 + x, y: 264 + y, width: width, height: height)
    }
    private func render() {
        usedButtons = []
        usedGlass = []
        interactiveRegions = []
        ink.commands = []
        historyRegions = [:]
        subagentText = []
        renderedTexts = []
        textFrames = []
        liveContextRows = []
        setAccessibilityLabel("Function panels · " + state.title)
        setAccessibilityValue(state.isOpen ? state.page.rawValue + " · " + input.status + " · Context " +
            input.context.text { "\(Int(($0 * 100).rounded()))%" } : "Closed")
        if let live = input.live { setAccessibilityValue(([state.page.rawValue] + live.semanticText).joined(
                    separator: " · ")) }
        if let feedback = input.commands?.feedback {
            setAccessibilityValue((accessibilityValue() as? String ?? "") + " · " + feedback)
        }
        if motion.progress > 0 || state.isOpen {
            renderStage()
            if let message = input.live?.conversationError ?? input.commands?.feedback {
                // Remain inside the existing #213 shield (panel.maxY), including hit/AX coverage.
                glass("feedback", CGRect(x: 66, y: 672, width: 491, height: 56), radius: 14)
                if input.live?.conversationError != nil {
                    label("State · Conversation error", CGRect(x: 82, y: 675, width: 427, height: 14), size: 10,
                        alpha: 0.5)
                }
                label(message, CGRect(x: 82, y: 691, width: 427, height: 18), size: 11)
                if let feedback = input.commands?.feedback {
                    if feedback != message { label(feedback, CGRect(x: 82, y: 710, width: 427, height: 14), size: 10) }
                    button("feedback.dismiss", "Dismiss message", CGRect(x: 521, y: 690, width: 24, height: 22),
                        symbol: "xmark", filled: false) { [weak self] in self?.onDismissFeedback?() }
                }
            }
            if !state.archived && archiveMotion.value == 0 { renderAppearance(); renderSubagents() }
            let stageCommands = ink.commands
            ink.commands = []; buildingPage = true
            if !state.archived && archiveMotion.value == 0 {
                renderPage()
                if state.page == .overview && input.live != nil && input.commands?.available.contains("model") == true {
                    button("model", "Change next model", pageRect(284, 86, 26, 20), symbol: "ellipsis", filled: false) {
                        [weak self] in self?.onAction(.model)
                    }
                }
            }
            buildingPage = false
            let pageCommands = ink.commands
            let clip = geometry.placed(FunctionPanelGeometry.panel)
            ink.commands = stageCommands + [{
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: clip).addClip()
                for command in pageCommands { command() }
                NSGraphicsContext.restoreGraphicsState()
            }]
            renderMockPin()
        }
        for (id, button) in buttons where !usedButtons.contains(id) {
            button.isHidden = true; button.live = false; button.invoke = nil; button.hover = nil
        }
        for (id, glass) in glasses where !usedGlass.contains(id) {
            glass.isHidden = true
            glass.material.isHidden = true
        }
        nameField.isHidden = !state.editingTitle || !state.isOpen
        nameField.setAccessibilityHidden(nameField.isHidden)
        if state.editingTitle {
            let width = measuredTitleWidth()
            nameField.frame = geometry.placed(FunctionPanelGeometry.title(width: width,
                    progress: motion.progress).insetBy(dx: 24, dy: 7))
            interactiveRegions.append(nameField.frame)
        }
        let content = motion.contentProgress(at: time)
        ink.alphaValue = motion.progress * (0.5 + 0.5 * content)
        if !reduced, content > 0, content < 1 {
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue((1 - content) * 8, forKey: kCIInputRadiusKey)
            ink.layer?.filters = filter.map { [$0] }
        } else { ink.layer?.filters = nil }
        ink.needsDisplay = true; needsDisplay = true
        onPresentation?(motion.progress)
    }
    private func measuredTitleWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let baseline = ("Sidebar density pass" as NSString).size(withAttributes: [.font: font]).width
        let width = (state.title as NSString).size(withAttributes: [.font: font]).width
        return FunctionPanelGeometry.titleWidth(state.title, measured: width - baseline)
    }
    private func renderStage() {
        let p = motion.progress
        var orb = FunctionPanelGeometry.orb(p)
        let q = CGFloat(archiveMotion.value)
        if q > 0 {
            let a = 1 - q, cx = a * a * a * orb.midX + 3 * a * a * q * 270 + 3 * a * q * q * 90 + q * q * q * 48
            let cy = a * a * a * orb.midY + 3 * a * a * q * 340 + 3 * a * q * q * 730 + q * q * q * 764
            let diameter = orb.width + (18 - orb.width) * q
            orb = CGRect(x: cx - diameter / 2, y: cy - diameter / 2, width: diameter, height: diameter)
        }
        let archiveFade = 1 - min(1, max(0, (q - 0.84) / 0.16))
        glass("orb", orb, radius: orb.width / 2, alpha: archiveFade)
        let normalTitle = FunctionPanelGeometry.title(width: measuredTitleWidth(), progress: Double(gate(0.03)))
        let titleFrame = CGRect(x: normalTitle.minX + (236 - normalTitle.minX) * q,
                                y: normalTitle.minY + (104 - normalTitle.minY) * q,
                                width: normalTitle.width + (150 - normalTitle.width) * q, height: 32)
        glass("title", titleFrame, radius: 16)
        let orbButton = button("orb", state.page == .overview ? "Close" : "Back to Overview", orb,
            circular: true) { [weak self] in
            guard let self else { return }
            if self.state.option != nil { self.state.option = nil; self.render() }
            else if self.state.page != .overview { self.selectPage(.overview) }
            else { self.close() }
        }
        orbButton.alphaValue *= archiveFade; orbButton.live = orbButton.live && !state.archived
        let context = input.live?.contextText ?? input.context.text { "\(Int(($0 * 100).rounded()))%" }
        renderedTexts.append(context)
        let livePhase = input.live?.phaseText
        if let livePhase { renderedTexts.append(livePhase) }
        let selectedColour = state.option == 1 ? appearanceColours.first { $0.id == state.colourID } : nil
        let colourTip = selectedColour.map { colour in
            colour.name + (colour.bodyName.isEmpty ? "" : " · " + colour.bodyName)
        }
        let tip = state.hoveredOption ?? colourTip
        let picture = bodySnapshot.planet
        if let lines = input.live?.contextLines, lines.count == 2, orb.width > 80 {
            let local = CGRect(origin: .zero, size: orb.size), factor = orb.width / 150
            for (index, text) in lines.enumerated() {
                let band = CGRect(x: 7 * factor, y: (index == 0 ? 67.5 : 96) * factor,
                                  width: orb.width - 14 * factor, height: (index == 0 ? 22 : 18) * factor)
                let size: CGFloat = (index == 0 ? 16 : 11) * factor
                let measured = FunctionPanelTrackText(text, agentID: "context", role: "context.\(index)", row: band,
                    band: band, item: local, size: size, alpha: 0.9, weight: .semibold)
                let centered = CGRect(x: (orb.width - measured.fragment.width) / 2 - 1, y: band.minY,
                                      width: measured.fragment.width + 2, height: band.height)
                liveContextRows.append(.init(text, agentID: "context", role: "context.\(index)", row: centered,
                    band: band, item: local, size: size, alpha: index == 0 ? 1 : 0.75, weight: .semibold))
            }
        }
        let contextRows = liveContextRows
        orbButton.customPaint = { bounds in
            FunctionPanelPaint.plate(bounds.insetBy(dx: 5, dy: 5), radius: bounds.width / 2,
                                     fill: NSColor(srgbRed: 0.34, green: 0.35, blue: 0.34, alpha: 1))
            if let picture {
                NSImage(cgImage: picture.image, size: CGSize(width: 150, height: 150)).draw(in: bounds)
                if picture.quality == .preview {
                    FunctionPanelPaint.text(
                        "Preview", CGRect(x: 30, y: 16, width: 90, height: 14),
                        size: 10, weight: .semibold, align: .center
                    )
                }
            }
            guard bounds.width > 80 else { return }
            if let livePhase {
                FunctionPanelPaint.text(
                    livePhase, CGRect(x: 12, y: 13, width: bounds.width - 24, height: 17),
                    size: 9, alpha: 0.65, align: .center
                )
            }
            // #259: Context stays on the phase sphere at every delivered quality.
            if tip == nil && !contextRows.isEmpty {
                for row in contextRows {
                    row.draw()
                }
            } else {
                let rect = CGRect(
                    x: 7, y: bounds.height * 0.51, width: bounds.width - 14, height: 36
                )
                FunctionPanelPaint.text(
                    tip ?? context, rect, size: tip == nil ? (context.hasSuffix("%") ? 30 : 15) : 11,
                    weight: .semibold, align: .center
                )
            }
            let caption = CGRect(
                x: 6, y: bounds.height * 0.79, width: bounds.width - 12, height: 15
            )
            FunctionPanelPaint.text(
                tip == nil ? "Context" : "", caption, size: 10, alpha: 0.6, align: .center
            )
        }
        if input.live != nil && input.commands?.available.contains("rename") != true && !state.editingTitle {
            label(state.title, titleFrame.insetBy(dx: 14, dy: 8), size: 12, weight: .semibold)
        }
        else if !state.editingTitle {
            button("title.button", state.archived ? "Archived · Undo" : state.title,
                   CGRect(x: titleFrame.minX, y: titleFrame.minY, width: titleFrame.width - (
                           self.state.archived ? 0 : 32), height: 32), filled: false) { [weak self] in
                guard let self else { return }
                if self.state.archived {
                    self.state.archived = false
                    self.state.isOpen = false
                    self.motion.setOpen(false, at: self.time, reduced: self.reduced)
                    self.archiveMotion.set(0, at: self.time, reduced: self.reduced)
                    self.onAction(.undoArchive); self.render(); self.schedule()
                }
                else { self.beginTitle() }
            }
        }
        if state.archived || archiveMotion.value > 0 { return }
        button("close", "Close", CGRect(x: 242, y: 190, width: 20, height: 24), symbol: "chevron.right",
            filled: false) { [weak self] in self?.close() }
        for (index, item) in FunctionPanelGeometry.chips(page: state.page, hover: state.hoveredPage).enumerated() {
            let (page, rect) = item
            glass("chip.\(page.rawValue)", rect, radius: 13)
            let b = button("tab.\(page.rawValue)", page.rawValue, rect, symbol: page.symbol,
                filled: false) { [weak self] in self?.selectPage(page) }
            b.alphaValue = gate(0.08 + Double(index) * 0.03); b.live = b.live && b.alphaValue > 0.55
            b.hover = { [weak self] inside in self?.state.hoveredPage = inside ? page : nil; self?.render() }
        }
        if state.page != .background {
            var frame = FunctionPanelGeometry.panel
            frame.size.height = state.page == .overview && input.live != nil ?
                liveOverviewLayout.height : FunctionPanelGeometry.paneHeight(state.page, covers: filteredCovers().count,
                selectedCover: state.coverID != nil)
            let gate = CGFloat(motion.stageGate(0.58, now: time))
            let source = CGRect(x: 287, y: 110, width: 48, height: 20)
            let grown = CGRect(x: source.minX + (frame.minX - source.minX) * gate,
                               y: source.minY + (frame.minY - source.minY) * gate,
                               width: source.width + (frame.width - source.width) * gate,
                               height: source.height + (frame.height - source.height) * gate)
            glass("panel", grown, radius: 10 + 14 * gate)
        }
        drawArc(left: true); drawArc(left: false)
    }
    private func drawArc(left: Bool) {
        let origin = geometry.origin
        let alpha = motion.stageGate(left ? 0.2 : 0.14, now: time)
        let tint = appearanceColours.first { $0.id == state.colourID }.map {
            FunctionPanelPaint.colour($0.hex) } ?? .white
        ink.commands.append {
            (left ? NSColor.white : tint).withAlphaComponent((left ? 0.3 : 0.62) * alpha).setStroke()
            let path = NSBezierPath()
            for y in stride(from: CGFloat(8), through: left ? 227 : 252, by: 2) {
                let p = CGPoint(x: (left ? FunctionPanelGeometry.leftX(y) : FunctionPanelGeometry.rightX(y)) + origin.x,
                    y: y + origin.y)
                if y == 8 { path.move(to: p) } else { path.line(to: p) }
            }
            path.lineWidth = 1.25; path.stroke()
        }
    }
    private var appearanceColours: [FunctionPanelColour] { input.commands?.colours ?? input.colours }
    private func renderAppearance() {
        let names = ["Planet", "Colour", "Notifications", state.dockPinned ? "Pinned to Dock" : "Pin to Dock",
            "Archive"]
        let symbols = ["circle", "circle.fill", "bell", "pin", "archivebox"]
        for index in 0..<5 {
            if input.live != nil && index != 0 && !(index == 1 && input.commands?.available.contains(where: {
                        $0.hasPrefix("colour.") }) == true) { continue }
            let open = state.option
            let y = FunctionPanelGeometry.leftStations[index]
            if open == index && index < 3 { continue }
            let dot = open != nil && index != open
            let dotY: CGFloat = open.map { FunctionPanelTrackLayout.parkedY(option: $0, index: index) } ?? y
            let centerY = dot ? dotY : y
            let d: CGFloat = dot ? 5 : index == 1 ? 18 : 26
            let rect = CGRect(x: FunctionPanelGeometry.leftX(centerY) - d / 2, y: centerY - d / 2, width: d, height: d)
            let b = button("option.\(index)", names[index], rect, symbol: symbols[index],
                circular: true) { [weak self] in
                guard let self else { return }
                if index < 3 { self.toggleOption(index) }
                else if index == 3 {
                    self.state.dockPinned.toggle()
                    self.pinMotion.set(self.state.dockPinned ? 1 : 0, at: self.time, reduced: self.reduced)
                    self.onAction(.pin(self.state.dockPinned)); self.render(); self.schedule()
                } else {
                    self.state.archived = true
                    self.archiveMotion.set(1, at: self.time, duration: 0.9, reduced: self.reduced)
                    self.onAction(.archive); self.render(); self.schedule()
                }
            }
            b.hover = { [weak self] inside in self?.state.hoveredOption = inside ? names[index] : nil; self?.render() }
            b.alphaValue = gate(0.4 + Double(index) * 0.05); b.live = b.live && b.alphaValue > 0.55
            if index == 0, !dot {
                b.customPaint = { bounds in FunctionPanelPaint.plate(bounds.insetBy(dx: 2, dy: 2),
                        radius: bounds.width / 2, fill: NSColor(white: 0.55, alpha: 1)) }
            }
            if index == 1, !dot, let colour = appearanceColours.first(where: { $0.id == state.colourID }) {
                b.customPaint = { bounds in FunctionPanelPaint.plate(bounds, radius: bounds.width / 2,
                        fill: FunctionPanelPaint.colour(colour.hex)) }
            }
            if index == 0, !dot, let picture = bodySnapshot.entries[FunctionPanelBodySnapshot.key(state.bodyID,
                    outer: 26)] {
                b.customPaint = { bounds in NSImage(cgImage: picture.image, size: bounds.size).draw(in: bounds) }
            }
            if dot && FunctionPanelTrackLayout.drawCollapsedDots {
                b.symbol = nil
                b.customPaint = { bounds in FunctionPanelPaint.plate(bounds, radius: 2.5,
                        fill: NSColor.white.withAlphaComponent(0.55)) }
            }
        }
        if state.option == 0 {
            for slot in FunctionPanelGeometry.bodySlots(count: input.bodies.count, offset: state.bodyScroll) {
                let body = input.bodies[slot.index]
                let b = button("body.\(body.id)", body.name, slot.frame, circular: true,
                    selected: state.bodyID == body.id) { [weak self] in self?.selectBody(body.id) }
                b.live = b.live && !slot.clipped
                b.inkInset = 0.5
                b.customPaint = { bounds in FunctionPanelPaint.plate(bounds.insetBy(dx: 1.5, dy: 1.5),
                        radius: bounds.width / 2, fill: NSColor(white: 0.55, alpha: 1)) }
                if let picture = bodySnapshot.entries[FunctionPanelBodySnapshot.key(body.id, outer: 22)] {
                    b.customPaint = { bounds in NSImage(cgImage: picture.image, size: bounds.size).draw(in: bounds) }
                }
                b.hover = { [weak self] inside in self?.state.hoveredOption = inside ? body.name : nil; self?.render() }
                b.key = { [weak self] code in
                    if code == 125 { self?.scrollBodies(1); return true }
                    if code == 126 { self?.scrollBodies(-1); return true }
                    return false
                }
            }
        } else if state.option == 1 {
            let colours = input.commands == nil ? appearanceColours : Array(appearanceColours.dropFirst(
                    state.colourScroll).prefix(9))
            for (index, colour) in colours.enumerated() {
                let y: CGFloat = 34 + CGFloat(index) * 20
                let b = button("colour.\(colour.id)",
                    colour.name + (colour.bodyName.isEmpty ? "" : ", " + colour.bodyName),
                               CGRect(x: FunctionPanelGeometry.leftX(y) - 7.5, y: y - 7.5, width: 15, height: 15),
                                   circular: true, selected: state.colourID == colour.id) { [weak self] in
                    self?.state.colourID = colour.id; self?.onAction(.colour(colour.id)); self?.render()
                }
                b.customPaint = { bounds in FunctionPanelPaint.plate(bounds, radius: 7.5,
                        fill: FunctionPanelPaint.colour(colour.hex)) }
                b.hover = {
                    [weak self] inside in self?.state.hoveredOption = inside ? colour.name + (
                        colour.bodyName.isEmpty ? "" : " · " + colour.bodyName) : nil
                    self?.render()
                }
                if input.commands != nil {
                    b.key = { [weak self] code in
                        guard code == 125 || code == 126 else { return false }
                        self?.scrollColours(code == 125 ? 1 : -1); return true
                    }
                }
            }
        } else if state.option == 2 {
            for (index, name) in ["All", "Important", "Off"].enumerated() {
                let y: CGFloat = 82 + CGFloat(index) * 32
                let b = button("notify.\(name)", name, CGRect(x: FunctionPanelGeometry.leftX(y) - 12, y: y - 12,
                        width: 24, height: 24), symbol: index == 2 ? "bell.slash" : "bell", circular: true,
                    selected: state.notification == name) { [weak self] in
                    self?.state.notification = name; self?.onAction(.notifications(name)); self?.render()
                }
                b.hover = { [weak self] inside in self?.state.hoveredOption = inside ? name : nil; self?.render() }
                b.key = { [weak self] code in
                    guard let self else { return false }
                    if code == 53 { self.escape(); return true }
                    guard [123, 124, 125, 126].contains(code) else { return false }
                    let names = ["All", "Important", "Off"],
                        current = names.firstIndex(of: self.state.notification) ?? 0
                    let next = min(2, max(0, current + ([123, 126].contains(code) ? -1 : 1)))
                    self.state.notification = names[next]
                    self.onAction(.notifications(names[next]))
                    self.render()
                    return true
                }
            }
        }
    }
    private func renderMockPin() {
        let p = CGFloat(pinMotion.value)
        guard p > 0 else { return }
        let a = 1 - p, sx = geometry.origin.x + FunctionPanelGeometry.leftX(148)
        let x = a * a * a * sx + 3 * a * a * p * 600 + 3 * a * p * p * 1090 + p * p * p * 1066
        let y = a * a * a * 148 + 3 * a * a * p * 16 + 3 * a * p * p * 430 + p * p * p * 764
        let d = 26 + 6 * p
        let rect = CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
        ink.commands.append { FunctionPanelPaint.plate(rect, radius: d / 2, fill: NSColor(white: 0.55, alpha: 1)) }
    }
    private func renderSubagents() {
        historyRegions.removeAll(keepingCapacity: true)
        guard let all = input.subagents.value else {
            label(input.subagents.status, CGRect(x: 320, y: 44, width: 240, height: 44), alpha: 0.55); return
        }
        if all.isEmpty { label("No sub-agents", CGRect(x: 320, y: 44, width: 240, height: 20), alpha: 0.55); return }
        let offset = state.showsAllSubagents ? min(state.subagentOffset, max(0, all.count - 3)) : 0
        let shown = Array(all.dropFirst(offset).prefix(3))
        let expanded = shown.firstIndex { $0.id == state.expandedSubagent }
        let rects = FunctionPanelGeometry.subagentBlocks(count: shown.count, expanded: expanded)
        for (index, agent) in shown.enumerated() {
            let rect = rects[index], isExpanded = expanded == index
            let textGate = gate(0.46 + Double(index) * 0.07)
            if isExpanded { glass("sub.\(agent.id)", rect, radius: 20) }
            let b = button("sub.\(agent.id)", agent.name + " · " + agent.status, rect,
                filled: false) { [weak self] in self?.pinSubagent(agent.id) }
            b.customPaint = { _ in }
            b.key = { [weak self] code in
                guard isExpanded, [125, 126].contains(code) else { return false }
                self?.scrollHistory(agent.id, delta: code == 126 ? 1 : -1); return true
            }
            b.hover = {
                [weak self] inside in guard let self else { return }
                self.hoverSubagent(inside ? agent.id : nil, at: self.now())
            }
            let mid = rect.midY, satellite = CGRect(x: rect.minX + 6, y: mid - 10, width: 20, height: 20)
            let sat = button("sat.\(agent.id)", agent.name, satellite,
                symbol: agent.status == "Finished" ? "circle" : "circle.fill", circular: true,
                selected: state.pinnedSubagent == agent.id) { [weak self] in self?.pinSubagent(agent.id) }
            sat.alphaValue = gate(0.24 + Double(index) * 0.07); sat.live = sat.live && sat.alphaValue > 0.55
            let pad: CGFloat = isExpanded ? 8 : 0
            func text(_ value: String, role: String, row: CGRect, band: CGRect, size: CGFloat,
                      alpha: CGFloat, weight: NSFont.Weight = .regular) {
                let layout = FunctionPanelTrackText(value, agentID: agent.id, role: role, row: geometry.placed(row),
                                                   band: geometry.placed(band), item: geometry.placed(rect),
                                                   size: size, alpha: alpha * textGate, weight: weight)
                subagentText.append(layout); ink.commands.append { layout.draw() }
            }
            let header = CGRect(x: rect.minX + 36, y: rect.minY + 3 + pad, width: 246, height: 16)
            text(agent.name, role: "name", row: CGRect(x: header.minX, y: header.minY, width: 135, height: 16),
                band: header, size: 11, alpha: 0.9, weight: .semibold)
            text(agent.status, role: "status", row: CGRect(x: rect.minX + 173, y: header.minY, width: 53, height: 16),
                band: header, size: 10, alpha: 0.55)
            text(agent.elapsed.text { $0 }, role: "elapsed", row: CGRect(x: rect.minX + 230, y: header.minY, width: 52,
                    height: 16), band: header, size: 10, alpha: 0.5)
            if expanded == nil || isExpanded {
                let historyOffset = min(state.historyOffsets[agent.id] ?? 0, max(0, agent.lines.count - 5))
                let latest = isExpanded ? agent.lines.dropLast(historyOffset).suffix(5) : agent.lines.suffix(2)
                let history = CGRect(x: rect.minX + 36, y: rect.minY + 20 + pad, width: 236,
                                     height: isExpanded ? rect.height - 20 - pad - 31 : 52)
                if isExpanded { historyRegions[agent.id] = geometry.placed(history) }
                // Board: 15/19 type, 6 pt gap, 52 pt collapsed history. Keep
                // two (expanded: five) complete entries, tail-truncated per row.
                var y = history.maxY - CGFloat(latest.count) * 19 - CGFloat(max(0, latest.count - 1)) * 6
                for (lineIndex, line) in latest.enumerated() {
                    text(line, role: "history.\(lineIndex)", row: CGRect(x: history.minX, y: y, width: 236, height: 19),
                         band: history, size: 15, alpha: lineIndex == latest.count - 1 ? 0.95 : 0.45, weight: .bold)
                    y += 25
                }
            }
            if isExpanded {
                button("sub.open.\(agent.id)", "Open", CGRect(x: rect.maxX - 64, y: rect.maxY - 27, width: 52,
                        height: 22)) { [weak self] in self?.onAction(.openSubagent(agent.id)) }
                if agent.canStop || input.commands?.available.contains("sub.stop.\(agent.id)") == true {
                    button("sub.stop.\(agent.id)", "Stop", CGRect(x: rect.maxX - 124, y: rect.maxY - 27, width: 52,
                            height: 22)) { [weak self] in self?.onAction(.stopSubagent(agent.id)) }
                }
            }
        }
        if all.count > 3 {
            button("sub.more", state.showsAllSubagents ? "Back · \(all.count) total" : "More… \(all.count - 3)",
                CGRect(x: 580, y: 232, width: 18, height: 22), symbol: "ellipsis", filled: false) { [weak self] in
                guard let self else { return }; self.state.showsAllSubagents.toggle()
                self.state.subagentOffset = 0; self.render()
            }
            buttons["sub.more"]?.key = { [weak self] code in
                guard [125, 126].contains(code) else { return false }
                self?.scrollSubagents(code == 125 ? 1 : -1); return true
            }
        }
    }
}
