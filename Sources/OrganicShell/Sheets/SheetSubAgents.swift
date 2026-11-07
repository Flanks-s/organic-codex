import AppKit

@MainActor final class SheetSubAgents: SheetSurface {
    private let titleLabel = SheetStyle.label("Sub-agents", size: 13, weight: .semibold)
    private let parentLabel = SheetStyle.label("", size: 11, secondary: true), counts = SheetStyle.label("", size: 11, secondary: true)
    private let identity = SheetIdentityGlyphView(frame: .zero)
    let scrollView = SheetScrollView(frame: .zero)
    private let document = SheetOrbitDocument()
    private var rowViews: [String: SheetSubAgentRow] = [:]
    private(set) var conversation: Conversation?
    private(set) var orderedIDs: [String] = []
    private(set) var selectedID: String?
    private(set) var upward = true
    var onSelect: ((String) -> Void)?
    var onOpenWindow: ((String, Conversation) -> Void)?
    var resolveIdentity: (Conversation) -> OrbIdentity = { .assigned($0.identityIndex) }
    let budMotion=SheetBudDriver()
    private var scrollObservation:NSObjectProtocol?
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        super.init(clock: clock)
        card.tintColor = .windowBackgroundColor.withAlphaComponent(0.55)
        for view in [titleLabel, parentLabel, counts, identity, scrollView] { card.content.addSubview(view) }
        scrollView.drawsBackground = false; scrollView.borderType = .noBorder; scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true; scrollView.scrollerStyle = .overlay; scrollView.documentView = document
        scrollView.automaticallyAdjustsContentInsets = false; scrollView.verticalScrollElasticity = .none
        identity.setAccessibilityElement(false)
        scrollView.contentView.postsBoundsChangedNotifications=true
        scrollObservation=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scrollView.contentView,queue:.main) { [weak self] _ in MainActor.assumeIsolated {self?.refreshMotionContent()} }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { if let scrollObservation {NotificationCenter.default.removeObserver(scrollObservation)};budMotion.stop(reset:false) }
    func present(conversation: Conversation, anchor: CGRect, upward: Bool, in host: NSView, select: String? = nil) {
        self.conversation = conversation; self.upward = upward
        selectedID = select; rebuild(); super.present(anchor: anchor, in: host); revealSelected()
    }
    /// Call after parent store updates; keep selection/reading position, including a running→done reorder.
    func refresh() { let offset = scrollView.contentView.bounds.origin; rebuild(); needsLayout = true; layoutSubtreeIfNeeded(); scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(offset.y, max(0, document.bounds.height - scrollView.contentSize.height))));refreshMotionContent() }
    private func rebuild() {
        guard let c = conversation else { return }
        var seen: Set<String> = []; let satellites = c.satellites.filter { seen.insert($0.id).inserted }
        let running = satellites.filter { !$0.done }
        let done = satellites.finishedInOrder.reversed()
        let ordered = running + Array(done); orderedIDs = ordered.map(\.id)
        if selectedID == nil || !orderedIDs.contains(selectedID!) { selectedID = orderedIDs.first }
        titleLabel.stringValue = "Sub-agents"; parentLabel.stringValue = c.title; identity.identity = resolveIdentity(c)
        counts.stringValue = [running.isEmpty ? nil : "\(running.count) running", done.isEmpty ? nil : "\(done.count) done"].compactMap { $0 }.joined(separator: " · ")
        setAccessibilityLabel("Sub-agents of " + c.title)
        for id in rowViews.keys where !orderedIDs.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        for satellite in ordered {
            let index = c.satellites.firstIndex { $0.id == satellite.id } ?? 0
            let row = rowViews[satellite.id] ?? SheetSubAgentRow(frame: .zero)
            row.configure(satellite, index: index, selected: selectedID == satellite.id, mock: c.backendThreadID == nil && !c.isLiveConversation, still: reduceMotion, suspended: !isShowing || isDismissing)
            row.invoke = { [weak self] in self?.open(satellite.id) };row.onVisualChange = { [weak self] in self?.refreshMotionContent() }
            if row.superview == nil { document.addSubview(row) }; rowViews[satellite.id] = row
        }
        document.runningCount = running.count; document.doneCount = done.count
    }
    override func layout() {
        super.layout(); guard conversation != nil else { return }
        let split: CGFloat = document.runningCount > 0 && document.doneCount > 0 ? 21 : 0
        let rowsHeight = CGFloat(orderedIDs.count) * 52 + split
        card.frame = anchored(size: CGSize(width: 352, height: min(448, 68 + rowsHeight)), upward: upward); card.layoutSubtreeIfNeeded()
        budMotion.updateTarget(card.frame,upward:upward)
        let w = card.bounds.width
        identity.frame = snapped(CGRect(x: 14, y: 16, width: 24, height: 24))
        titleLabel.frame = snapped(CGRect(x: 52, y: 11, width: max(1, w - 180), height: 18))
        parentLabel.frame = snapped(CGRect(x: 52, y: 30, width: max(1, w - 68), height: 16))
        counts.frame = snapped(CGRect(x: max(52, w - 132), y: 13, width: min(116, w - 68), height: 16)); counts.alignment = .right
        scrollView.frame = snapped(CGRect(x: 0, y: 52, width: w, height: max(1, card.bounds.height - 52)))
        let width = scrollView.contentSize.width
        document.frame = snapped(CGRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, rowsHeight + 16)))
        var y: CGFloat = 8
        for (i, id) in orderedIDs.enumerated() {
            if i == document.runningCount && split > 0 { y += split }
            rowViews[id]?.frame = snapped(CGRect(x: 0, y: y, width: width, height: 52)); y += 52
        }
        document.needsDisplay = true
    }
    @discardableResult func select(_ id: String) -> Bool {
        guard orderedIDs.contains(id), isShowing, !isDismissing else { return false }
        selectedID = id; for (key, row) in rowViews { row.selected = key == id }; onSelect?(id); revealSelected();refreshMotionContent(); return true
    }
    @discardableResult func open(_ id: String) -> Bool {
        guard let conversation, select(id), isShowing, !isDismissing, self.conversation === conversation, selectedID == id else { return false }
        dismiss(reason: .selection); onOpenWindow?(id, conversation); return true
    }
    override func handleKey(_ key: OverlayKey) -> Bool {
        guard isShowing, !isDismissing else { return false }
        switch key {
        case .up, .down:
            guard !orderedIDs.isEmpty else { return true }
            let i = selectedID.flatMap { orderedIDs.firstIndex(of: $0) } ?? 0
            _ = select(orderedIDs[min(orderedIDs.count - 1, max(0, i + (key == .up ? -1 : 1)))]); return true
        case .enter: if let selectedID { _ = open(selectedID) }; return true
        case .escape: dismiss(reason: .escape); return true
        default: return false
        }
    }
    private func revealSelected() {
        guard let selectedID, let row = rowViews[selectedID] else { return }
        row.scrollToVisible(row.bounds)
        let p = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: (p.y * grid).rounded() / grid))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    private var motionRows:[(CGRect,CALayer)] {orderedIDs.compactMap {id in guard let row=rowViews[id],let layer=row.layer else {return nil};let r=card.content.convert(row.bounds,from:row).intersection(scrollView.frame);return r.isEmpty ? nil:(r,layer)}}
    private func refreshMotionContent() {budMotion.contentTransition?.refresh(rows:budMotion.zoom == .gauss ? []:motionRows)}
    override var appearanceStartsHidden:Bool {!reduceMotion && window != nil}
    override func animateIn() {
        let gaussian=budMotion.exposureEnabled && budMotion.zoom == .gauss
        // Restore source model endpoints BEFORE capture. All CA starts are chosen AFTER the capture.
        CATransaction.begin();CATransaction.setDisableActions(true)
        for id in orderedIDs {if let row=rowViews[id] {row.layer?.removeAnimation(forKey:"overlay.opacity");row.layer?.removeAnimation(forKey:"overlay.transform.translation.y");row.layer?.opacity=1;row.layer?.transform=CATransform3DIdentity}}
        CATransaction.commit()
        budMotion.start(card:card,upward:upward,reduceMotion:reduceMotion,rows:gaussian ? []:motionRows)
        let t=budMotion.beginTime
        if let layer=card.layer {
            CATransaction.begin();CATransaction.setDisableActions(true);layer.opacity=1
            if !reduceMotion {let a=SheetStyle.spring(response:0.38,damping:0.78);a.keyPath="opacity";a.fromValue=0;a.toValue=1;a.beginTime=layer.convertTime(t,from:nil);layer.add(a,forKey:"sheets.bud.opacity")}
            CATransaction.commit()
        }
        for (i,id) in orderedIDs.enumerated() {
            guard let row=rowViews[id],let layer=row.layer else {continue};row.dots.suspended=false
            if !gaussian {
                let curve=OverlayCurve(0,0,0.58,1,0.12),delay=0.07+min(Double(i),4)*0.02
                SheetMotionAnimation.animate(layer,"transform.translation.y",from:4,to:0,curve:curve,at:t,delay:delay,enabled:!reduceMotion)
                SheetMotionAnimation.animate(layer,"opacity",from:0,to:1,curve:curve,at:t,delay:delay,enabled:!reduceMotion)
            }
        }
        budMotion.contentTransition?.copyRowAnimations()
    }

    override func willDismiss(reason: SheetDismissReason) { budMotion.stop(reset:false);for row in rowViews.values { row.dots.suspended = true } }
    override func animateOut() {
        if budMotion.exposureEnabled,budMotion.zoom == .gauss {
            budMotion.hideContent()
            if let layer=card.layer {
                let t=budMotion.contentTransition?.effect?.plan?.began ?? budMotion.sceneClock.mediaTime()
                let opacity=budMotion.openingOpacity(at:t)
                layer.removeAnimation(forKey:"sheets.bud.opacity")
                SheetMotionAnimation.animate(layer,"opacity",from:opacity,to:0,curve:OverlayMotion.ease(0.16),at:t,enabled:!reduceMotion)
            }
        } else {
            super.animateOut()
        }
    }
    override func didFinish() { budMotion.stop(reset:true) }
}

@MainActor private final class SheetOrbitDocument: OverlayView {
    var runningCount = 0, doneCount = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setStroke()
        var y: CGFloat = 8
        for (group, count) in [runningCount, doneCount].enumerated() {
            if count > 0 { let p = NSBezierPath(); p.move(to: CGPoint(x: 28, y: y + 6)); p.line(to: CGPoint(x: 28, y: y + CGFloat(count) * 52 - 6)); p.setLineDash([3, 5], count: 2, phase: 0); p.lineWidth = 1; p.stroke(); y += CGFloat(count) * 52 }
            if group == 0 && runningCount > 0 && doneCount > 0 {
                NSBezierPath.strokeLine(from: CGPoint(x: 16, y: y + 0.5), to: CGPoint(x: bounds.width - 16, y: y + 0.5))
                SheetStyle.text("Done", in: CGRect(x: 52, y: y + 4, width: 80, height: 16), size: 11, color: .tertiaryLabelColor, weight: .semibold); y += 21
            }
        }
    }
}
@MainActor private final class SheetSubAgentRow: SheetButton {
    let dots = SheetActivityDots(frame: .zero)
    private var satellite = Satellite(id: "", face: "•ᴗ•")
    private var index = 0
    private var task = ""
    override init(frame: NSRect) { super.init(frame: frame); addSubview(dots) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ satellite: Satellite, index: Int, selected: Bool, mock: Bool, still: Bool, suspended: Bool) {
        self.satellite = satellite; self.index = index; self.selected = selected
        dots.isHidden = satellite.done; dots.still = still; dots.suspended = suspended
        task = satellite.title ?? (mock ? SheetSubAgentCopy.task(index) : "Sub-agent")
        setAccessibilityLabel("Sub-agent \(index + 1), \(task), \(satellite.done ? "done" : "running")")
        setAccessibilityHelp("Opens its read-only window"); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered { (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.055)).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 10, yRadius: 10).fill() }
        (satellite.done ? NSColor.systemGray : .controlAccentColor).withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn: CGRect(x: 14, y: 12, width: 28, height: 28)).fill()
        SheetStyle.text(satellite.face, in: CGRect(x: 14, y: 19, width: 28, height: 16), size: 10, color: .white, weight: .semibold, align: .center)
        let statusWidth: CGFloat = 80, w = max(1, bounds.width - 56 - statusWidth - 8)
        SheetStyle.text("Sub-agent \(index + 1)", in: CGRect(x: 56, y: 9, width: w, height: 18), size: 13, weight: .medium)
        SheetStyle.text(task, in: CGRect(x: 56, y: 29, width: w, height: 17), size: 11.5, color: .secondaryLabelColor)
        SheetStyle.text(satellite.done ? "✓ Done" : "Running", in: CGRect(x: bounds.width - statusWidth, y: 18, width: statusWidth - 16, height: 18), size: 11, color: .secondaryLabelColor, align: .right)
    }
    override func layout() { super.layout(); dots.frame = SheetStyle.snap(CGRect(x: bounds.width - 78, y: 20, width: 12, height: 12), scale: window?.backingScaleFactor ?? 1) }
}

/// Put this in the bar's ellipsis seat. The callback's rect is in the supplied modal host's coordinates.
@MainActor final class SheetSubAgentsEllipsis: SheetButton {
    weak var modalHost: NSView?
    var onOpen: ((CGRect) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); title = "…"; drawsPlate = false; setAccessibilityLabel("Sub-agents")
        invoke = { [weak self] in guard let self, let host = self.modalHost else { return }; self.onOpen?(host.convert(self.bounds, from: self)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
