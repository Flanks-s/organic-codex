import AppKit

@MainActor final class NativeTranscriptRow: NativeFlippedView, NSMenuDelegate {
    weak var semanticParent:NativeTranscriptAXRow?
    override func accessibilityParent()->Any?{if let semanticParent,superview === semanticParent.table{return semanticParent};return super.accessibilityParent()}
    let body = NativeTranscriptTextView()
    private lazy var meta = NativeLabel(labelWithString: "")
    private lazy var divider = NativeLabel(labelWithString: "")
    private let toggle = NativeTranscriptActionButton()
    private let activityMark = NativeTranscriptMark()
    private lazy var kindSymbol = NativeTranscriptMark()
    private lazy var metaStatus = NativeTranscriptMark()
    private lazy var time = NativeLabel(labelWithString: "")
    private var hasChrome = false
    // Most rows of a real history are one-line activity rows that never show these, and a button costs more to create
    // than a recycled row costs to configure: they are made the first time a row needs them.
    private var review, revert, copyButton, editButton, forkButton: NativeTranscriptActionButton?
    private var actionButtons: [NativeTranscriptActionButton] { [toggle] + [review, revert, copyButton, editButton, forkButton].compactMap { $0 } }
    private var tracking: NSTrackingArea?
    private var hovering = false
    private(set) var firstSeen = Date()
    private var codeStyle = NativeTranscriptCodeStyle()
    private struct Configuration: Equatable {
        let shown: TranscriptItem, source: TranscriptItem
        let width: CGFloat, grid: CGFloat
        let expanded: Bool, turnStart: Bool, showsMeta: Bool, allowsRevert: Bool
        let worked: String?
        let style: NativeTranscriptCodeStyle
        let displayRevision:Int
        let appearanceRevision:Int
    }
    private var configuration: Configuration?
    private var presentation: (source: TranscriptItem, value: RowPresentation)?
    private(set) var configurationCount = 0
    private var geometry: TranscriptGeometry?
    private var attributed = NSAttributedString(string: "")
    private var fixedSourceOffsets: [Int] = []
    private var stream: NativeTranscriptStreamLayout?
    private var streamGeneration = -1
    var sourceOffsets: [Int] { stream?.offsets ?? fixedSourceOffsets }
    private(set) var item = TranscriptItem(id: "", turnID: "", kind: .assistant, text: "")
    var onToggle: (() -> Void)?, onReview: (() -> Void)?, onRevert: (() -> Void)?
    var onEdit: (() -> Void)? { didSet { if (oldValue == nil) != (onEdit == nil) { layoutActions() } } }
    var onFork: (() -> Void)? { didSet { if (oldValue == nil) != (onFork == nil) { layoutActions() } } }
    var allowsRevert = true

    private var trackingInteraction = false
    var blocksHandoff: Bool {
        trackingInteraction || body.isTrackingSelection || actionButtons.contains { $0.isTrackingPress }
    }
    var preventsRecycling: Bool {
        trackingInteraction || body.isTrackingSelection || body.selectedRanges.contains { $0.rangeValue.length > 0 } ||
            actionButtons.contains { $0.isTrackingPress } ||
            (window?.firstResponder as? NSView).map { $0.isDescendant(of: self) } == true
    }
    func menuWillOpen(_ menu: NSMenu) { trackingInteraction = true }
    func menuDidClose(_ menu: NSMenu) { trackingInteraction = false }
    override func prepareForReuse() {
        menu?.cancelTrackingWithoutAnimation(); trackingInteraction = false
        super.prepareForReuse()
        semanticParent = nil; configuration = nil; hovering = false; firstSeen = Date()
        // Hidden pool cells remain attached. Source lookups must never mistake them for a live item.
        item = TranscriptItem(id: "", turnID: "", kind: .assistant, text: "")
        presentation = nil
        stream = nil; streamGeneration = -1; fixedSourceOffsets = []
        body.setSelectedRange(NSRange(location: 0, length: 0))
        applyFlightHidden([], textHidden: false); applyHiddenSourceRanges([])
        onToggle = nil; onReview = nil; onRevert = nil; onEdit = nil; onFork = nil
        activityMark.status = .none; if hasChrome { metaStatus.status = .none }
        isHidden = true
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        body.textContainer?.replaceLayoutManager(NativeTranscriptFlightLayoutManager())
        for view in [body, toggle, activityMark] { addSubview(view) }
        toggle.font = .systemFont(ofSize: 11); toggle.target = self; toggle.action = #selector(toggled)
        let menu=NSMenu();let copy=NSMenuItem(title:"Copy Message",action:#selector(copied),keyEquivalent:"");copy.target=self;menu.addItem(copy)
        menu.delegate=self;self.menu=menu;body.menu=menu
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Compact activity has no metadata, divider or hover timestamp. Create that chrome only on demand.
    private func ensureChrome() {
        guard !hasChrome else { return }
        hasChrome = true
        for view in [meta, divider, kindSymbol, metaStatus, time] { addSubview(view) }
        meta.textColor = NativePalette.secondaryLabel
        divider.textColor = NativePalette.tertiaryLabel
        time.textColor = NativePalette.tertiaryLabel; time.isHidden = true
    }
    private func changesButton(_ slot: ReferenceWritableKeyPath<NativeTranscriptRow, NativeTranscriptActionButton?>, _ title: String, _ action: Selector) -> NativeTranscriptActionButton {
        if let made = self[keyPath: slot] { return made }
        let button = NativeTranscriptActionButton()
        button.font = TranscriptLayout.font(11, scale: NativeAppearance.current.textScale); button.target = self; button.action = action; button.title = title
        // What NativeAppearance.recolor gives a button that was already there.
        if NativeAppearance.current.foreground != nil { button.contentTintColor = NativeAppearance.current.label }
        self[keyPath: slot] = button; addSubview(button)
        return button
    }
    private func hoverButton(_ slot: ReferenceWritableKeyPath<NativeTranscriptRow, NativeTranscriptActionButton?>, _ symbol: String, _ label: String, _ action: Selector) -> NativeTranscriptActionButton {
        if let made = self[keyPath: slot] { return made }
        let button = NativeTranscriptActionButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.contentTintColor = NativePalette.secondaryLabel
        button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
        button.isHidden = true
        self[keyPath: slot] = button; addSubview(button)
        return button
    }
    func configure(_ item: TranscriptItem, sourceItem: TranscriptItem, index: Int, items: [TranscriptItem], width: CGFloat, expanded: Bool, codeStyle: NativeTranscriptCodeStyle = .init(), prepared: NativeTranscriptPreparedRow? = nil, fallbackTimestamp: Date? = nil) {
        let grid = max(1, window?.backingScaleFactor ?? 1)
        // Every mounted row comes through here on every scroll tick: most of them have not changed.
        let p = presentation?.source == sourceItem ? presentation!.value : NativeTranscriptPresentation.presentation(for: sourceItem)
        presentation = (sourceItem, p)
        let turnStart = TranscriptPresentation.isTurnStart(index: index, items: items)
        let showsMeta = TranscriptPresentation.showsMeta(index: index, items: items, presentation: p)
        let worked = TranscriptPresentation.workedFor(index: index, items: items)
        let next = Configuration(shown: item, source: sourceItem, width: width, grid: grid, expanded: expanded, turnStart: turnStart, showsMeta: showsMeta, allowsRevert: allowsRevert, worked: worked, style: codeStyle,displayRevision:NativeDisplayOptions.shared.revision,appearanceRevision:NativeAppearance.revision)
        guard next != configuration else { return }
        let sameChrome = configuration.map { old in
            old.width == next.width && old.grid == next.grid && old.expanded == next.expanded &&
            old.turnStart == next.turnStart && old.showsMeta == next.showsMeta && old.allowsRevert == next.allowsRevert &&
            old.worked == next.worked && old.style == next.style && old.displayRevision == next.displayRevision &&
            old.appearanceRevision == next.appearanceRevision && old.source.timestamp == sourceItem.timestamp &&
            NativeTranscriptPresentation.presentation(for: old.source) == p
        } ?? false
        configuration = next; configurationCount += 1
        self.codeStyle = codeStyle
        self.item = sourceItem
        let compact = TranscriptPresentation.isActivity(item.rowKind) && !expanded
        if !compact { ensureChrome() }
        let scale=NativeAppearance.current.textScale
        if !sameChrome {
            if hasChrome {
                meta.font=TranscriptLayout.font(11,scale:scale,weight:.semibold)
                divider.font=TranscriptLayout.font(11.5,scale:scale)
                time.font=TranscriptLayout.font(11,scale:scale)
            }
            for button in [toggle,review,revert].compactMap({$0}){button.font=TranscriptLayout.font(11,scale:scale)}
        }
        let prepared = prepared ?? NativeTranscriptPreparedRow(item: item, source: sourceItem, index: index,
            items: items, width: width, expanded: expanded, style: codeStyle)
        let text = prepared.text
        let streamed = prepared.stream
        let localEdit = streamed === stream && streamGeneration + 1 == prepared.streamGeneration ? streamed?.edit : nil
        if let streamed, streamed === stream, streamGeneration == prepared.streamGeneration {
            // This generation is already in the native storage (e.g. a viewport assembly without a new delta).
        } else if let edit = localEdit, edit.baseGeneration == streamGeneration,
                  NSMaxRange(edit.range) == body.textStorage?.length {
            let selections = body.selectedRanges
            body.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            let restored = selections.map { value in
                let r = value.rangeValue, start = min(r.location, text.length)
                return NSValue(range: NSRange(location: start, length: min(r.length, text.length - start)))
            }
            if body.selectedRanges != restored { body.selectedRanges = restored }
            attributed = text
        } else if streamed != nil || stream != nil || !attributed.isEqual(to: text) {
            // A skipped generation needs a complete copy even when `attributed` aliases the stream's mutable
            // storage and therefore already compares equal. A snapshot/retained cell must never keep stale glyphs.
            let selections = body.selectedRanges
            body.textStorage?.setAttributedString(text); attributed = text
            let restored = selections.map { value in
                let selection = value.rangeValue, location = min(selection.location, text.length)
                return NSValue(range: NSRange(location: location, length: min(selection.length, text.length - location)))
            }
            if body.selectedRanges != restored { body.selectedRanges = restored }
        }
        stream = streamed; streamGeneration = prepared.streamGeneration
        fixedSourceOffsets = streamed == nil ? prepared.offsets : []
        let g = prepared.geometry
        geometry = g
        // Every child sits on the pixel grid: on screen a fractional layer is resampled, in a capture it is drawn
        // in place, and the two differ visibly at the native ↔ capture swap.
        func snapped(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX * grid).rounded() / grid, y: (r.minY * grid).rounded() / grid, width: ceil(r.width * grid) / grid, height: ceil(r.height * grid) / grid)
        }
        let bodyFrame = snapped(g.bodyRect)
        if body.frame != bodyFrame { body.frame = bodyFrame }
        let containerSize = CGSize(width: max(1, body.frame.width), height: .greatestFiniteMagnitude)
        if body.textContainer?.containerSize != containerSize { body.textContainer?.containerSize = containerSize }
        if !sameChrome {
            body.textContainer?.maximumNumberOfLines = g.maximumLines
            body.textContainer?.lineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
            body.setAccessibilityLabel(p.label.isEmpty ? (item.rowKind == .user ? "User message" : "Assistant message") : p.label)
            if hasChrome {
                meta.isHidden = g.metaRect == nil; meta.stringValue = p.metaText
                if let rect = g.metaRect { meta.frame = snapped(rect) }
                kindSymbol.isHidden = g.metaRect == nil || p.symbol == nil
                kindSymbol.symbolName = p.symbol
                kindSymbol.tint = item.rowKind == .notice(.error) ? .systemRed : item.rowKind == .notice(.warning) ? .systemOrange : NativePalette.secondaryLabel
                metaStatus.isHidden = g.metaRect == nil || p.statusKind == .none
                metaStatus.status = p.statusKind
                if let rect = g.metaRect {
                    if p.symbol != nil {
                        kindSymbol.frame = snapped(CGRect(x: rect.minX, y: rect.midY - 6, width: 12, height: 12))
                        meta.frame = snapped(CGRect(x: rect.minX + 16, y: rect.minY, width: max(1, rect.width - 36), height: rect.height))
                    }
                    let textWidth = ceil((p.metaText as NSString).size(withAttributes: [.font: meta.font!]).width)
                    metaStatus.frame = snapped(CGRect(x: min(rect.maxX - 12, meta.frame.minX + textWidth + 5), y: rect.midY - 6, width: 12, height: 12))
                }
                divider.isHidden = g.dividerRect == nil; divider.stringValue = g.dividerText ?? ""
                if let rect = g.dividerRect {
                    let size = divider.fittingSize
                    divider.frame = snapped(CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: min(rect.width, size.width), height: size.height))
                }
            }
            activityMark.isHidden = g.indicatorRect == nil
            activityMark.status = p.statusKind
            if let rect = g.indicatorRect { activityMark.frame = snapped(rect) }
            toggle.isHidden = g.moreButtonRect == nil
            toggle.cachesChevron = compact
            toggle.title = compact ? "" : "Show less"
            toggle.image = compact ? NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show Details") : nil
            toggle.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            toggle.contentTintColor = NativePalette.tertiaryLabel
            toggle.setAccessibilityLabel(expanded ? "Collapse " + p.label : "Expand " + p.label)
            if let rect = g.moreButtonRect { toggle.frame = snapped(rect) }
            let changes = TranscriptPresentation.isChangesCard(item)
            if changes {
                _=changesButton(\.review,"Review",#selector(reviewed));_=changesButton(\.revert,"Undo",#selector(reverted))
            }
            review?.isHidden = !changes; revert?.isHidden = !changes || item.status == TranscriptPresentation.changesReverted
            review?.isEnabled = onReview != nil
            revert?.isEnabled = allowsRevert && item.status != TranscriptPresentation.changesReverted
            if changes,let rect=g.metaRect {
                var x=rect.maxX
                for button in [review,revert].compactMap({$0}) where !button.isHidden {
                    button.sizeToFit();let size=button.frame.size
                    x-=size.width;button.frame=snapped(CGRect(x:x,y:rect.midY-size.height/2,width:size.width,height:size.height));x-=6
                }
                meta.frame.size.width=max(1,x-meta.frame.minX-6)
                metaStatus.frame.origin.x=min(metaStatus.frame.minX,x-12)
            }
        }
        // Expanded activity's Show less and a user's hover actions move with body height, even when their labels
        // and fonts stay identical. Avoid reassigning all NSControl cells: that enqueues expensive Auto Layout work.
        if let rect = g.moreButtonRect, toggle.frame != snapped(rect) { toggle.frame = snapped(rect) }
        let size = CGSize(width: floor(width * grid) / grid, height: ceil(g.rowHeight * grid) / grid)
        if frame.size != size { frame.size = size }
        if let fallbackTimestamp { firstSeen = fallbackTimestamp }
        if hasChrome && !sameChrome { time.stringValue = (item.timestamp ?? firstSeen).formatted(date: .omitted, time: .shortened) }
        layoutActions()
        setAccessibilityLabel(item.rowKind == .user ? "User message" : compact ? text.string : p.metaText.isEmpty ? "Assistant message" : p.metaText)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let g = geometry else { return }
        if let bubble = g.bubbleRect {
            // Straight edges on whole pixels: a part-covered edge row came out 7/255 apart on screen and in a capture.
            let grid = max(1, window?.backingScaleFactor ?? 1)
            func edge(_ v: CGFloat) -> CGFloat { (v * grid).rounded() / grid }
            let rect = CGRect(x: edge(bubble.minX), y: edge(bubble.minY), width: edge(bubble.maxX) - edge(bubble.minX), height: edge(bubble.maxY) - edge(bubble.minY))
            let color: NSColor = switch item.rowKind {
            case .user: NativePalette.bubble
            case .notice(.error): NativeDisplayOptions.plate(.systemRed,alpha:0.10)
            case .notice(.warning): NativeDisplayOptions.plate(.systemOrange,alpha:0.10)
            default: NativePalette.codeFill
            }
            let radius: CGFloat = item.rowKind == .user ? 16 : 10
            color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        if let rect = g.ruleRect { NativePalette.tertiaryLabel.setFill(); rect.fill() }
        if let rect = g.dividerRect {
            let grid = max(1, window?.backingScaleFactor ?? 1)
            let x = divider.frame.maxX + 10, y = (rect.midY * grid).rounded() / grid
            NativePalette.tertiaryLabel.withAlphaComponent(0.3).setFill()
            CGRect(x: x, y: y, width: max(0, rect.maxX - x), height: 1 / grid).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    func reconcilePointerHover(_ point: CGPoint?) {
        let inside = point.map { visibleRect.contains($0) && NativePointerShield.permits(self, localPoint: $0) } ?? false
        guard hovering != inside else { return }; hovering = inside; layoutActions()
    }
    override func mouseEntered(with event: NSEvent) { hovering = NativePointerShield.permits(self, localPoint: convert(event.locationInWindow, from: nil)); layoutActions() }
    override func mouseExited(with event: NSEvent) { hovering = false; layoutActions() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hovering = false; layoutActions() } }
    private func layoutActions() {
        guard hasChrome else { return }
        let show = geometry?.actionsRect != nil && hovering
        if time.isHidden != !show { time.isHidden = !show }
        let editHidden = !show || onEdit == nil, forkHidden = !show || onFork == nil
        if show {
            copyButton = hoverButton(\.copyButton, "doc.on.doc", "Copy", #selector(copied))
            if !editHidden { editButton = hoverButton(\.editButton, "pencil", "Edit", #selector(edited)) }
            if !forkHidden { forkButton = hoverButton(\.forkButton, "arrow.triangle.branch", "Fork from Here", #selector(forked)) }
        }
        if let copyButton, copyButton.isHidden != !show { copyButton.isHidden = !show }
        if let editButton, editButton.isHidden != editHidden { editButton.isHidden = editHidden }
        if let forkButton, forkButton.isHidden != forkHidden { forkButton.isHidden = forkHidden }
        // Nothing here is seen until the pointer is over the row, and sizing the time was most of a user row's configure.
        guard show, let rect = geometry?.actionsRect else { return }
        let grid = max(1, window?.backingScaleFactor ?? 1)
        var x = rect.maxX
        for button in [forkButton, editButton, copyButton].compactMap({ $0 }) where !button.isHidden {
            x -= 20
            button.frame = CGRect(x: (x * grid).rounded() / grid, y: (rect.minY * grid).rounded() / grid, width: 20, height: 18); x -= 2
        }
        let size = time.fittingSize
        time.frame = CGRect(x: ((x - 4 - size.width) * grid).rounded() / grid, y: ((rect.midY - size.height / 2) * grid).rounded() / grid, width: ceil(size.width * grid) / grid, height: ceil(size.height * grid) / grid)
    }
    override func accessibilityCustomActions()->[NSAccessibilityCustomAction]? {
        guard item.rowKind == .user else{return super.accessibilityCustomActions()}
        let expected=item
        func action(_ name:String,_ run:@escaping(NativeTranscriptRow)->Void)->NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name:name,handler:{[weak self] in
                guard let self,self.item == expected,NativeInteractionSurface.permits(self)else{return false}
                run(self);return true
            })
        }
        var actions=[action("Copy"){$0.copied()}]
        if onEdit != nil{actions.append(action("Edit"){$0.edited()})}
        if onFork != nil{actions.append(action("Fork from Here"){$0.forked()})}
        return actions
    }
    func flightView(_ part: NativeFlightPart) -> NSView? {
        switch part {
        case .workedDivider: geometry?.dividerRect == nil ? nil : divider
        case .activityText: geometry?.isCompact == true ? body : nil
        case .activityMark: geometry?.isCompact == true && geometry?.indicatorRect != nil ? activityMark : nil
        }
    }
    func applyFlightHidden(_ parts: Set<NativeFlightPart>, textHidden: Bool) {
        let dividerHidden = geometry?.dividerRect == nil || parts.contains(.workedDivider)
        let bodyHidden = textHidden || (geometry?.isCompact == true && parts.contains(.activityText))
        let markHidden = geometry?.indicatorRect == nil || parts.contains(.activityMark)
        if hasChrome, divider.isHidden != dividerHidden { divider.isHidden = dividerHidden }
        if body.isHidden != bodyHidden { body.isHidden = bodyHidden }
        if activityMark.isHidden != markHidden { activityMark.isHidden = markHidden }
    }
    func applyHiddenSourceRanges(_ indices: IndexSet) {
        guard let manager = body.layoutManager as? NativeTranscriptFlightLayoutManager, let container = body.textContainer else { return }
        if indices.isEmpty { if manager.setOmittedRanges([], in: container) { body.needsDisplay = true }; return }
        var ranges: [NSRange] = [], start: Int?
        for i in 0...sourceOffsets.count {
            let hidden = i < sourceOffsets.count && sourceOffsets[i] >= 0 && indices.contains(sourceOffsets[i])
            if hidden && start == nil { start = i }
            if !hidden, let first = start { ranges.append(NSRange(location: first, length: i - first)); start = nil }
        }
        if manager.setOmittedRanges(ranges, in: container) { body.needsDisplay = true }
    }
    @objc private func toggled() { onToggle?() }
    @objc private func reviewed() { onReview?() }
    @objc private func reverted() { onRevert?() }
    @objc private func copied() {
        _ = copyMessage()
    }
    @discardableResult func copyMessage(to pasteboard:NSPasteboard = .general)->Bool {
        guard superview != nil,NativeInteractionSurface.permits(self)else{return false}
        pasteboard.clearContents();return pasteboard.setString(item.text,forType:.string)
    }
    @objc private func edited() { if !isHiddenOrHasHiddenAncestor { onEdit?() } }
    @objc private func forked() { if !isHiddenOrHasHiddenAncestor { onFork?() } }
}

/// The viewport and a flight both draw this same mark; never a second renderer in the flight composer.
@MainActor private final class NativeTranscriptMark: NativeFlippedView {
    private var phase = 0
    private var clock: Timer?
    var status: RowStatusKind = .none { didSet { if status != oldValue { needsDisplay = true }; updateClock() } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var tint = NativePalette.secondaryLabel
    override var isHidden: Bool { didSet { updateClock() } }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { clock?.invalidate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateClock() }
    private func updateClock() {
        let running = status == .progress && symbolName == nil && window != nil && !isHiddenOrHasHiddenAncestor
        if !running { clock?.invalidate(); clock = nil; return }
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 1 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.window != nil, !self.isHiddenOrHasHiddenAncestor else { self.clock?.invalidate(); self.clock = nil; return }
                self.phase = (self.phase + 1) % 12; self.needsDisplay = true
            }
        }
        clock = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func draw(_ dirtyRect: NSRect) {
        if status == .progress && symbolName == nil {
            // Drawn by this view in both viewport and source captures, not NSProgressIndicator's private surface.
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6
                let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round
                path.move(to: CGPoint(x: bounds.midX + cos(a) * 3, y: bounds.midY + sin(a) * 3))
                path.line(to: CGPoint(x: bounds.midX + cos(a) * 5, y: bounds.midY + sin(a) * 5))
                NativePalette.secondaryLabel.withAlphaComponent(CGFloat((i + phase) % 12 + 1) / 12).setStroke(); path.stroke()
            }
            return
        }
        let statusSymbol: String = switch status {
        case .waiting: "hand.raised.fill"
        case .failed: "xmark.circle.fill"
        case .declined: "hand.raised.slash.fill"
        case .stopped: "stop.circle"
        default: "questionmark.circle"
        }
        let symbol = symbolName ?? statusSymbol
        let color = symbolName != nil ? tint : status == .failed ? .systemRed : [.waiting, .declined].contains(status) ? .systemOrange : NativePalette.secondaryLabel
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [color])))?
            .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension NativeTranscriptRow: NativePointerHoverClient {}
