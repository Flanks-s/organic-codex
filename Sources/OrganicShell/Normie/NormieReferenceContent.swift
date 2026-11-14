import AppKit

/// Read-only content in the existing inspector. Source rows are virtualized by NSTableView.
@MainActor final class NormieReferenceContent: NormieView, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = NSScrollView(), table = NSTableView()
    private let targetScroll = NSScrollView()
    private let target = NormieDiffTextView(), preview = NormieDiffTextView()
    private let status = NormieDrawing.label("", size: 12)
    private let copy = NormieDrawing.button("Copy Target", action: {})
    private var sources: [SourceLocator] = []
    private var locator: SourceLocator?
    var onOpen: ((SourceLocator) -> Void)?
    var readingOffset: CGPoint { scroll.contentView.bounds.origin }
    var isSourceList: Bool { locator == nil }
    func restoreReadingOffset(_ offset: CGPoint) {
        layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: offset); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func revoke() { onOpen = nil; copy.run = nil }
    init(sources: [SourceLocator]) {
        self.sources = sources
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("source")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(openSource)
        table.setAccessibilityLabel("Sources")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        addSubview(scroll)
        status.stringValue = sources.isEmpty ? "No references in this conversation." : "\(sources.count) reference\(sources.count == 1 ? "" : "s")"
        status.textColor = NativePalette.secondaryLabel; addSubview(status)
    }
    init(source: SourceLocator, result: TranscriptReferencePreview) {
        locator = source
        super.init(frame: .zero)
        target.string = source.target.raw; target.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        target.textColor = NativePalette.label; target.setAccessibilityLabel("Complete file target")
        status.stringValue = result.state == .unavailable ? "Unavailable — " + result.message : result.message
        status.maximumNumberOfLines = 3; status.textColor = NativePalette.secondaryLabel
        status.lineBreakMode = .byWordWrapping; status.cell?.wraps = true; status.cell?.usesSingleLineMode = false; status.cell?.isScrollable = false
        copy.run = { [weak self] in
            guard let raw = self?.locator?.target.raw else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(raw, forType: .string)
        }
        preview.string = result.text; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textColor = NativePalette.label; preview.setAccessibilityLabel("Read-only file preview")
        scroll.documentView = preview; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        targetScroll.documentView = target; targetScroll.drawsBackground = false; targetScroll.hasVerticalScroller = true
        for child in [targetScroll, status, copy, scroll] { addSubview(child) }
        if let line = source.target.fileLocation.line, result.state == .ready {
            let text = result.text as NSString
            var start = 0, number = 1
            while start < text.length, number < line { start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))); number += 1 }
            if start < text.length { preview.setSelectedRange(text.lineRange(for: NSRange(location: start, length: 0))) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        if locator == nil {
            status.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 22)
            scroll.frame = CGRect(x: 0, y: 28, width: bounds.width, height: max(1, bounds.height - 28))
            table.tableColumns.first?.width = max(1, scroll.contentSize.width)
        } else {
            targetScroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 88)
            target.textContainer?.containerSize = NSSize(width: max(1, targetScroll.contentSize.width), height: .greatestFiniteMagnitude)
            if let container = target.textContainer, let manager = target.layoutManager {
                manager.ensureLayout(for: container)
                target.frame.size = NSSize(width: targetScroll.contentSize.width, height: max(88, manager.usedRect(for: container).height))
            }
            status.frame = CGRect(x: 0, y: 96, width: bounds.width, height: 54)
            copy.frame = CGRect(x: 0, y: 154, width: 120, height: 26)
            scroll.frame = CGRect(x: 0, y: 190, width: bounds.width, height: max(1, bounds.height - 190))
            preview.textContainer?.containerSize = NSSize(width: max(1, scroll.contentSize.width), height: .greatestFiniteMagnitude)
            if let container = preview.textContainer, let manager = preview.layoutManager {
                manager.ensureLayout(for: container)
                preview.frame.size = NSSize(width: max(1, scroll.contentSize.width), height: max(scroll.contentSize.height, manager.usedRect(for: container).height))
                preview.scrollRangeToVisible(preview.selectedRange())
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let source = sources[row]
        let button = NormieDrawing.button(source.target.raw) { [weak self] in self?.onOpen?(source) }
        button.alignment = .left; button.lineBreakMode = .byTruncatingMiddle; button.toolTip = source.target.raw
        button.setAccessibilityLabel(source.target.raw); return button
    }
    @objc private func openSource() {
        let row = table.selectedRow
        if sources.indices.contains(row) { onOpen?(sources[row]) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { openSource() } else { super.keyDown(with: event) }
    }
}
