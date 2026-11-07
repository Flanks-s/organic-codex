import AppKit

struct SheetContextOption: Equatable, Sendable {
    var id: String
    var title: String
    var detail = ""
    var enabled = true
    var disabledReason: String?
}

/// Context/device menu contents are supplied by the scene. Other Folder… / host-path actions remain callbacks.
@MainActor final class SheetContextPicker: SheetSurface {
    private let heading = SheetStyle.label("", size: 12, weight: .semibold)
    private let scrollView = SheetScrollView(frame: .zero), document = OverlayView()
    private var buttons: [SheetButton] = []
    private(set) var options: [SheetContextOption] = []
    private(set) var highlightedID: String?
    private(set) var selectedID: String?
    private var upward = true
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        super.init(clock: clock); card.radius = 14; card.content.addSubview(heading); card.content.addSubview(scrollView)
        scrollView.drawsBackground = false; scrollView.borderType = .noBorder; scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true; scrollView.scrollerStyle = .overlay; scrollView.documentView = document
        scrollView.automaticallyAdjustsContentInsets = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(title: String, options: [SheetContextOption], selectedID: String?, anchor: CGRect, upward: Bool = true, in host: NSView) {
        var seen: Set<String> = []; self.options = options.filter { seen.insert($0.id).inserted }
        self.selectedID = selectedID; self.upward = upward; heading.stringValue = title; setAccessibilityLabel(title)
        highlightedID = self.options.first { $0.id == selectedID && $0.enabled }?.id ?? self.options.first(where: \.enabled)?.id
        buttons.forEach { $0.removeFromSuperview() }; buttons = []
        for option in self.options {
            let b = SheetButton(frame: .zero); b.isEnabled = option.enabled; b.selected = option.id == highlightedID
            b.title = option.title; b.setAccessibilityHelp(option.disabledReason ?? option.detail); b.toolTip = option.disabledReason ?? option.detail
            b.drawContent = { [weak self] rect in
                let chosen = self?.selectedID == option.id
                if chosen { SheetStyle.text("✓", in: CGRect(x: 8, y: 10, width: 18, height: 18), size: 12) }
                SheetStyle.text(option.title, in: CGRect(x: 30, y: option.detail.isEmpty ? 10 : 5, width: max(1, rect.width - 40), height: 18), size: 12, color: option.enabled ? .labelColor : .tertiaryLabelColor)
                if !option.detail.isEmpty { SheetStyle.text(option.detail, in: CGRect(x: 30, y: 23, width: max(1, rect.width - 40), height: 16), size: 10, color: .secondaryLabelColor) }
            }
            b.invoke = { [weak self] in self?.select(option.id) }; document.addSubview(b); buttons.append(b)
        }
        super.present(anchor: anchor, in: host)
    }
    override func layout() {
        super.layout(); card.frame = anchored(size: CGSize(width: 300, height: min(380, 38 + CGFloat(options.count) * 44)), upward: upward); card.layoutSubtreeIfNeeded()
        heading.frame = snapped(CGRect(x: 14, y: 12, width: card.bounds.width - 28, height: 18))
        scrollView.frame = snapped(CGRect(x: 6, y: 36, width: card.bounds.width - 12, height: max(1, card.bounds.height - 42)))
        document.frame = snapped(CGRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, CGFloat(buttons.count) * 44)))
        for (i, b) in buttons.enumerated() { b.frame = snapped(CGRect(x: 0, y: CGFloat(i) * 44, width: document.bounds.width, height: 40)) }
    }
    @discardableResult func select(_ id: String) -> Bool {
        guard isShowing, !isDismissing, options.contains(where: { $0.id == id && $0.enabled }) else { return false }
        selectedID = id; dismiss(reason: .selection); onSelect?(id); return true
    }
    override func handleKey(_ key: OverlayKey) -> Bool {
        guard isShowing, !isDismissing else { return false }
        switch key {
        case .up, .down:
            let enabled = options.filter(\.enabled); guard !enabled.isEmpty else { return true }
            let i = highlightedID.flatMap { id in enabled.firstIndex { $0.id == id } } ?? 0
            highlightedID = enabled[min(enabled.count - 1, max(0, i + (key == .up ? -1 : 1)))].id
            for (i, b) in buttons.enumerated() { b.selected = options[i].id == highlightedID; if b.selected { b.scrollToVisible(b.bounds) } }; return true
        case .enter: if let highlightedID { _ = select(highlightedID) }; return true
        default: return super.handleKey(key)
        }
    }
    override func willDismiss(reason: SheetDismissReason) { if reason != .selection { onCancel?() } }
}
