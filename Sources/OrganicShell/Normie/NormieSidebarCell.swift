import AppKit

@MainActor final class NormieSidebarCell: NormieView {
    let planet = NormieSidebarIdentity(), title = NormieDrawing.label(size: 13)
    let trailing = NormieDrawing.label(size: 11), device = NormieDrawing.label(size: 11)
    let folder = NormieSidebarSymbol(), deviceMark = NormieSidebarSymbol(), statusMark = NormieSidebarSymbol()
    let pin = NormieButton(), archive = NormieButton(), disclosure = NormieButton(), rename = NormieField()
    let runningIndicator = NormieSidebarSpinner()
    var activate: (() -> Void)?
    private var tracking: NSTrackingArea?
    private(set) var isChat = false, nested = false, hovering = false, showsRunning = false
    private var hasStatus = false, isGroup = false, isMore = false, topLevel = false, flightHidden = false
    private var projectColor: String?
    private var projectExpanded = false
    private var fitText = "", fitWidth: CGFloat = -1, fittedWidth: CGFloat = 0
    /// Keep M11.2's flight anchors unchanged. Both visible identity slots sit three
    /// points left of their flight rect, including the nested chat slot at x = 36.
    var flightSourceRect: CGRect {
        CGRect(x: nested ? NormieSidebarMetrics.nestedTitleX + 4 : NormieSidebarMetrics.iconX + 2,
               y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [planet, folder, title, trailing, device, deviceMark, statusMark, disclosure, pin, archive, rename, runningIndicator] { addSubview(v) }
        runningIndicator.style = .spinning; runningIndicator.controlSize = .mini
        runningIndicator.isDisplayedWhenStopped = false; runningIndicator.setAccessibilityLabel("Running")
        trailing.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); trailing.alignment = .right
        device.alignment = .right
        for (button, symbol) in [(pin, "pin"), (archive, "archivebox")] {
            button.image = Self.image(symbol, size: 11); button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }
        pin.setAccessibilityLabel("Pin or unpin conversation"); archive.setAccessibilityLabel("Archive conversation")
        pin.toolTip = "Pin / Unpin"; archive.toolTip = "Archive"
        disclosure.imagePosition = .imageOnly; disclosure.imageScaling = .scaleNone
        disclosure.run = { [weak self] in self?.activate?() }
        rename.isHidden = true; rename.setAccessibilityLabel("Chat name")
        onAppearanceChange = { [weak self] in self?.updatePalette() }
        updatePalette(); setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private static func image(_ symbol: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }
    private func updatePalette() {
        title.textColor = isMore ? NormieSidebarMetrics.secondary : NormieSidebarMetrics.primary
        trailing.textColor = NormieSidebarMetrics.tertiary; device.textColor = NormieSidebarMetrics.secondary
        disclosure.contentTintColor = (NativeAppearance.current.foreground ?? .white).withAlphaComponent(0.58)
        pin.contentTintColor = NormieSidebarMetrics.secondary; archive.contentTintColor = NormieSidebarMetrics.secondary
        if let hex = projectColor, let rgb = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) {
            folder.tint = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                  green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        } else { folder.tint = NativePalette.accent }
    }
    func setFlightSourceHidden(_ hidden: Bool) {
        flightHidden = hidden; planet.isHidden = !isChat || hidden
    }
    func configure(_ row: NormieSidebarRow, model: NormieSidebarModel) {
        showsRunning = false; runningIndicator.running = false; toolTip = nil
        isChat = row.conversationID != nil; nested = false; topLevel = false; isGroup = false; isMore = false
        projectColor = nil; projectExpanded = false; hasStatus = false; rename.isHidden = true
        folder.isHidden = true; device.isHidden = true; deviceMark.isHidden = true
        statusMark.isHidden = true; disclosure.isHidden = true; trailing.isHidden = true
        disclosure.isEnabled = true; title.font = .systemFont(ofSize: 13)
        switch row {
        case .group(let key):
            isGroup = true; title.stringValue = key; title.font = .systemFont(ofSize: 11, weight: .semibold)
            // Section disclosure is supplied by the native sidebar style in the product. Its resting
            // header has no leading chevron; Return/Left/Right and clicking the header still work.
        case .project(let id):
            if let p = model.store.project(id) {
                title.stringValue = p.name; projectColor = p.colorHex
                folder.isHidden = false; folder.symbol = p.colorHex == nil ? "folder" : "folder.fill"
                disclosure.isHidden = false
                projectExpanded = model.isOpen(p)
                disclosure.image = NSImage(systemSymbolName: projectExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
                showDevice(p.deviceID, store: model.store)
            }
        case .conversation(let id, let project):
            guard let c = model.store.conversation(id) else { return }
            nested = project != nil; topLevel = !nested; title.stringValue = c.title
            planet.identity = NormieDrawing.identity(c); hasStatus = NormieSidebarModel.hasStatus(c)
            let status = NormieSidebarModel.status(c)
            if c.error != nil { statusMark.symbol = "exclamationmark.triangle.fill"; statusMark.tint = .systemRed }
            else if !c.approvals.isEmpty { statusMark.symbol = "hand.raised.fill"; statusMark.tint = .systemOrange }
            else if c.question != nil || c.userInput != nil { statusMark.symbol = "questionmark.bubble.fill"; statusMark.tint = .systemOrange }
            else if c.running { showsRunning = true }
            else if c.unread { statusMark.symbol = "circle.fill"; statusMark.tint = NativePalette.accent }
            trailing.stringValue = hasStatus ? "" : status
            trailing.setAccessibilityLabel(status); statusMark.setAccessibilityLabel(status)
            pin.image = Self.image(c.pinned ? "pin.slash" : "pin", size: 11)
            pin.setAccessibilityLabel(c.pinned ? "Unpin" : "Pin"); pin.toolTip = c.pinned ? "Unpin" : "Pin"
            if topLevel { showDevice(c.deviceID, store: model.store) }
            title.setAccessibilityLabel(c.title + ", " + status)
            toolTip = c.title + "\nUpdated " + c.updated.formatted(.relative(presentation: .named))
        case .more(let key):
            isMore = true
            nested = !["recents", "pinned", NormieSidebarModel.historyPageKey].contains(key)
            let history = key == NormieSidebarModel.historyPageKey
            title.stringValue = history ? model.historyTitle() : "Show More"; title.font = .systemFont(ofSize: 11)
            if history {
                disclosure.isHidden = false; disclosure.image = Self.image(model.historyError != nil ? "arrow.clockwise" : "plus", size: 11)
                disclosure.isEnabled = !model.historyLoading; toolTip = model.historyError
            }
        }
        planet.isHidden = !isChat || flightHidden
        runningIndicator.isHidden = !showsRunning
        runningIndicator.running = showsRunning
        disclosure.setAccessibilityLabel(title.stringValue); updatePalette(); updateHover(); needsLayout = true
    }
    private func showDevice(_ id: String, store: ConversationStore) {
        guard let d = store.device(id), !d.isLocal else { return }
        device.isHidden = false; deviceMark.isHidden = false; device.stringValue = d.name
        deviceMark.symbol = d.online ? "circle.fill" : "exclamationmark.circle"
        deviceMark.tint = d.online ? .systemGreen : .systemOrange
        deviceMark.pointSize = d.online ? 7 : 11
        device.setAccessibilityLabel("\(d.name), \(d.online ? "connected" : "offline")")
    }
    func beginRename(text: String, delegate: NSTextFieldDelegate) {
        title.isHidden = true; rename.isHidden = false; rename.stringValue = text; rename.delegate = delegate
        updateHover()
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let start = isGroup ? 12 : nested ? NormieSidebarMetrics.nestedTitleX + (isChat ? 21 : 0) : isMore ? 46 : NormieSidebarMetrics.titleX
        // SwiftUI lays out the folder at its 14.5 pt optical width, and Text has no NSTextField inset.
        let titleStart = isGroup || nested || isMore ? start : start - (isChat ? 3 : 1.5)
        let actionsWidth: CGFloat = isChat && hovering && rename.isHidden ? 42 : 0
        let markWidth: CGFloat = isChat ? (hasStatus ? 14 : (hovering ? 0 : 24)) : 0
        let right = width - NormieSidebarMetrics.trailingInset
        let markEnd = right - (actionsWidth > 0 ? actionsWidth + 4 : 0)
        let trailingWidth = isChat ? markWidth + (actionsWidth > 0 ? actionsWidth + (hasStatus ? 4 : 0) : 0) : 0
        // Device Text has an independent width proposal (104 pt maximum in SidebarView).
        // Reserve its 4 pt gap + 7 pt mark, and the title/device HStack spacing; do not
        // give the native field's two-sided padding extra room at the title's expense.
        let deviceWidth: CGFloat = device.isHidden ? 0 : min(115, max(48, (width - start - trailingWidth - 25) / 2))
        let deviceRight = right + 0.5 - trailingWidth - (trailingWidth > 0 ? 6 : 0)
        let deviceLeft = deviceRight - deviceWidth
        let end = device.isHidden ? right - trailingWidth - (trailingWidth > 0 ? 6 : 0) : deviceLeft - 11
        let textEnd = isChat ? end + 4 : end - (device.isHidden ? 8 : 0)
        var textRect = CGRect(x: titleStart, y: isGroup ? height - 17 : (height - 20) / 2 + 1,
                              width: max(0, (isGroup || isMore ? right : textEnd) - titleStart), height: isGroup ? 14 : 20)
        let renameRect = textRect
        if isChat, rename.isHidden { textRect.size.width = displayWidth(textRect.width) }
        place(title, textRect); place(rename, renameRect)
        place(planet, CGRect(x: nested ? NormieSidebarMetrics.nestedTitleX + 1 : NormieSidebarMetrics.iconX - 1,
                             y: (height - 16) / 2 - 1, width: 16, height: 16))
        place(folder, CGRect(x: NormieSidebarMetrics.iconX, y: (height - 16) / 2, width: 16, height: 16))
        // chevron.right's optical centre is a point below chevron.down in AppKit's
        // native image-only button. Align the collapsed disclosure with SidebarView.
        let disclosureY = (height-14)/2 - (!folder.isHidden && !projectExpanded ? 1:0)
        place(disclosure, CGRect(x:11.5,y:disclosureY,width:14,height:14))
        place(trailing, CGRect(x: right - 34, y: (height - 18) / 2 + 1, width: 36, height: 18))
        let symbolSize: CGFloat = statusMark.symbol == "circle.fill" ? 7 : 14
        place(statusMark, CGRect(x: markEnd - symbolSize - 1, y: (height - symbolSize) / 2, width: symbolSize, height: symbolSize))
        place(runningIndicator, CGRect(x: markEnd - 14, y: (height - 14) / 2, width: 14, height: 14))
        let dotSize: CGFloat = deviceMark.symbol == "circle.fill" ? 7 : 11
        place(deviceMark, CGRect(x: deviceRight - dotSize - 1, y: (height - dotSize) / 2 - 1, width: dotSize, height: dotSize))
        place(device, CGRect(x: deviceLeft, y: (height - 16) / 2, width: max(0, deviceWidth - dotSize - 4), height: 16))
        place(pin, CGRect(x: right - 42, y: (height - 20) / 2, width: 20, height: 20))
        place(archive, CGRect(x: right - 20, y: (height - 20) / 2, width: 20, height: 20))
    }
    /// SwiftUI's one-line title does not leave one orphaned letter from the next truncated word.
    /// Account for that at the native field's right edge, preserving its full value/AX/tooltip.
    /// Work is cached per text/width; streaming deltas never cause title measurement.
    private func displayWidth(_ width: CGFloat) -> CGFloat {
        let text = title.stringValue
        if fitText == text, fitWidth == width { return fittedWidth }
        fitText = text; fitWidth = width; fittedWidth = width
        guard text.count > 30, text.contains(" "), width > 20, let font = title.font else { return width }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width-4 else { return width }
        let chars = Array(text), ellipsis = ("…" as NSString).size(withAttributes: attributes).width
        var end = 0
        while end < chars.count {
            let prefix = String(chars.prefix(end+1))
            if (prefix as NSString).size(withAttributes: attributes).width + ellipsis > width-4 { break }
            end += 1
        }
        if end > 1, end < chars.count, chars[end-2].isWhitespace, chars[end-1].unicodeScalars.allSatisfy({$0.isASCII}), chars[end-1].isLetter, chars[end].isLetter {
            fittedWidth = max(0, width - (String(chars[end-1]) as NSString).size(withAttributes: attributes).width - 1)
        }
        return fittedWidth
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateHover() }
    private func updateHover() {
        pin.isHidden = !isChat || !hovering || !rename.isHidden; archive.isHidden = pin.isHidden
        trailing.isHidden = !isChat || hasStatus || hovering
        statusMark.isHidden = !isChat || !hasStatus || showsRunning
        title.isHidden = !rename.isHidden; needsLayout = true
    }
    override func mouseDown(with event: NSEvent) { if !isChat { activate?() } else { super.mouseDown(with: event) } }
}
