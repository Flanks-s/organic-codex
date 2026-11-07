import AppKit
import QuartzCore

@MainActor final class NormieSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onModeEndpointVisibilityChanged:(()->Void)?
    let model: NormieSidebarModel
    let searchField = NormieField()
    let table = NormieSidebarTable()
    let scrollView = NSScrollView()
    let accountView = NormieAccountView()
    private let searchPlate = NormieView(), searchIcon = NormieSidebarSymbol()
    private let emptyIcon = NormieSidebarSymbol(), emptyDetail = NormieDrawing.label(size: 11)
    private let scrollMask = CAGradientLayer()
    private var scrollObservation: NSObjectProtocol?
    private let empty = NormieDrawing.label("No Results", size: 13, weight: .semibold)
    private var suppressSelection = false
    private var focusedRename: String?
    private var revealedCurrent:String?,revealedFocus:String?
    private var hiddenPlanets: Set<String> = []
    private var modePreparationSafeRect: CGRect?
    func prepareModeLayout(size: CGSize, safeRect: CGRect) {
        loadViewIfNeeded(); modePreparationSafeRect = safeRect; view.setFrameSize(size)
        layoutContent(); scrollView.tile(); layoutContent()
        accountView.layout() // A hidden split has no AppKit layout pass to size its 26pt avatar.
    }
    func endModePreparation() { modePreparationSafeRect = nil }
    private struct PreparedRow {
        let value:RowValue, appearance:Int, display:Int, renaming:String?, renameText:String
        let cell:NormieSidebarCell
    }
    private var preparedRows:[String:PreparedRow]=[:]
    /// Retain detached target rows. NSTableView.view(makeIfNecessary:) need not retain its result while hidden.
    @discardableResult func prepareModeRow(_ row:Int)->NormieSidebarCell? {
        guard model.rows.indices.contains(row),table.rect(ofRow:row).intersects(scrollView.contentView.bounds) else{return nil}
        if let live=table.view(atColumn:0,row:row,makeIfNecessary:false) as? NormieSidebarCell{return live}
        let item=model.rows[row], key=item.key, value=value(for:item)
        let cached=preparedRows[key]
        let cell:NormieSidebarCell
        if let cached,cached.value == value,cached.appearance == NativeAppearance.revision,cached.display == NativeDisplayOptions.shared.revision,
           cached.renaming == model.renaming,cached.renameText == model.renameText {cell=cached.cell}
        else {
            cell=makeCell(item)
            preparedRows[key] = .init(value:value,appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision,renaming:model.renaming,renameText:model.renameText,cell:cell)
        }
        cell.frame=CGRect(origin:.zero,size:table.rect(ofRow:row).size);cell.layoutSubtreeIfNeeded()
        return cell
    }
    func preparedModeFrame(_ row:Int)->CGRect? {
        guard model.rows.indices.contains(row) else{return nil}
        let item=model.rows[row]
        if let live=table.view(atColumn:0,row:row,makeIfNecessary:false) as? NormieSidebarCell{return live.convert(live.flightSourceRect,to:view)}
        guard let cell=preparedRows[item.key]?.cell else{return nil}
        let frame=table.rect(ofRow:row)
        return table.convert(cell.flightSourceRect.offsetBy(dx:frame.minX,dy:frame.minY),to:view)
    }
    var preparedModeDrawingRows:[(view:NSView,rect:CGRect,clip:CGRect)] {
        let clip=scrollView.contentView.convert(scrollView.contentView.bounds,to:view)
        return model.rows.enumerated().compactMap { i,item in
            guard table.view(atColumn:0,row:i,makeIfNecessary:false) == nil,let cell=preparedRows[item.key]?.cell,
                  table.rect(ofRow:i).intersects(scrollView.contentView.bounds) else{return nil}
            return (cell,table.convert(table.rect(ofRow:i),to:view),clip)
        }
    }
    private var displayedRows: [NormieSidebarRow] = []
    var modeContentKey:String {String(describing:model.rows.map(value(for:)))+"|\(model.current ?? "")|\(model.focusedRowKey ?? "")|\(table.selectedRow)|\(model.query)|\(model.renaming ?? "")|\(model.renameText)"}
    private var displayedValues: [RowValue] = []
    private(set) var fullReloadCount = 0
    private(set) var rowReloadCount = 0
    /// Only values actually drawn by a sidebar cell. Transcript text/revision/pace are intentionally absent.
    private struct RowValue: Equatable {
        var row: NormieSidebarRow
        var title = "", status = "", device = "", deviceID = "", identitySymbol: String?, identityTint: String?, projectColor: String?
        var identity = 0
        var updated = Date.distantPast
        var active = false, open = false, pinned = false, online = true, local = true
    }
    private func value(for row: NormieSidebarRow) -> RowValue {
        var value = RowValue(row: row)
        switch row {
        case .group(let key): value.open = model.isGroupOpen(key)
        case .project(let id):
            if let p = model.store.project(id) {
                value.title = p.name; value.projectColor = p.colorHex; value.open = model.isOpen(p); value.pinned = p.pinned
                value.deviceID = p.deviceID
                value.device = model.store.device(p.deviceID)?.name ?? p.deviceID
                value.online = model.store.device(p.deviceID)?.online ?? false
                value.local = model.store.device(p.deviceID)?.isLocal ?? false
            }
        case .conversation(let id, _):
            if let c = model.store.conversation(id) {
                value.title = c.title; value.status = NormieSidebarModel.status(c)
                value.active = NormieSidebarModel.hasStatus(c); value.pinned = c.pinned
                value.updated = c.updated
                value.identity = c.identityIndex; value.identitySymbol = c.identitySymbol; value.identityTint = c.identityTint
                value.deviceID = c.deviceID
                value.device = model.store.device(c.deviceID)?.name ?? c.deviceID
                value.online = model.store.device(c.deviceID)?.online ?? false
                value.local = model.store.device(c.deviceID)?.isLocal ?? false
            }
        case .more(let key):
            if key == NormieSidebarModel.historyPageKey { value.title = model.historyTitle(); value.active = model.historyLoading; value.status = model.historyError ?? "" }
        }
        return value
    }
    var onCustomize: ((Conversation) -> Void)?
    var onNewChatInProject: ((String) -> Void)?
    var onAccount: (() -> Void)?
    var account: NormieAccount { get { accountView.account } set { accountView.account = newValue } }
    var undoArchive: (() -> Void)? { didSet { table.undoAction = undoArchive } }
    /// Only visible rows are flight sources. Never fabricate an offscreen row's anchor.
    var rowFrames: [String: CGRect] {
        guard view.window != nil else { return [:] }
        var result: [String: CGRect] = [:]
        for (i, row) in model.rows.enumerated() {
            guard let id = row.conversationID, table.rect(ofRow: i).intersects(table.visibleRect),
                  let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? NormieSidebarCell else { continue }
            result[id] = cell.convert(cell.flightSourceRect, to: nil)
        }
        return result
    }
    var avatarFrame: CGRect? { view.window == nil ? nil : accountView.avatar.convert(accountView.avatar.bounds, to: nil) }
    func setFlightSourcesHidden(_ ids: Set<String>, avatar: Bool) {
        if ModeFlight.orreryEnabled {
            let changed=hiddenPlanets.symmetricDifference(ids)
            hiddenPlanets=ids
            if accountView.avatar.isHidden != avatar {accountView.avatar.isHidden=avatar}
            guard !changed.isEmpty else {return}
            for (row,item) in model.rows.enumerated() where item.conversationID.map(changed.contains) == true {
                let id=item.conversationID!
                if let cell=table.view(atColumn:0,row:row,makeIfNecessary:false) as? NormieSidebarCell {cell.setFlightSourceHidden(ids.contains(id))}
                if let cell=preparedRows[item.key]?.cell {cell.setFlightSourceHidden(ids.contains(id))}
            }
            return
        }
        hiddenPlanets = ids; accountView.avatar.isHidden = avatar
        for (row, item) in model.rows.enumerated() {
            if let id = item.conversationID, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NormieSidebarCell { cell.setFlightSourceHidden(ids.contains(id)) }
            if let id = item.conversationID, let cell = preparedRows[item.key]?.cell { cell.setFlightSourceHidden(ids.contains(id)) }
        }
    }
    /// Exclude airborne identities from the immutable sliding-sidebar foreground too.
    func flightSourceViews(for ids: Set<String>) -> [NSView] {
        model.rows.enumerated().flatMap { row, item -> [NSView] in
            guard let id = item.conversationID, ids.contains(id) else { return [] }
            let live = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NormieSidebarCell
            return [live, preparedRows[item.key]?.cell].compactMap { $0?.planet }
        }
    }
    var hiddenFlightSourceViews: [NSView] { flightSourceViews(for: hiddenPlanets) }
    /// A handoff needs all of the identity outside the clip and scroll-fade boundaries.
    func fullyCoversFlightIdentity(_ identity:NSView) -> Bool {
        let rect=identity.convert(identity.bounds,to:scrollView.contentView)
        var coverage=scrollView.contentView.bounds
        if coverage.minY>0.5 {coverage.origin.y+=min(9,coverage.height*0.25);coverage.size.height-=min(9,coverage.height*0.25)}
        if table.frame.height-scrollView.contentView.bounds.maxY>0.5 {coverage.size.height-=min(18,scrollView.contentView.bounds.height*0.25)}
        return !rect.isEmpty && coverage.contains(rect)
    }


    init(model: NormieSidebarModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let root = NormieSidebarSurface(); view = root
        root.onDisplayOptionsChange={[weak self] in self?.updateSearchPalette()}
        root.onAppearanceChange=root.onDisplayOptionsChange
        searchPlate.wantsLayer = true; searchPlate.layer?.cornerRadius = 14
        searchPlate.layer?.backgroundColor = NativeDisplayOptions.plate(alpha:0.07).cgColor
        searchIcon.symbol = "magnifyingglass"; searchIcon.pointSize = 13; searchIcon.tint = (NativeAppearance.current.foreground ?? .white).withAlphaComponent(0.42)
        searchPlate.addSubview(searchIcon)
        searchField.placeholderString = "Search"; searchField.delegate = self
        updateSearchPalette()
        searchField.setAccessibilityLabel("Search chats by title or project"); searchPlate.addSubview(searchField)
        scrollView.contentView = NormieClipView(); scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("sidebar")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = NormieSidebarMetrics.rowHeight; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Conversations"); table.setAccessibilityRole(.table)
        table.keyAction = { [weak self] key in self?.model.keyboard(key) }
        table.menuForRow = { [weak self] row in self?.menu(for: row) }
        table.target = self; table.doubleAction = #selector(activateRow)
        scrollView.documentView = table
        for v in [searchPlate, scrollView, accountView, empty, emptyIcon, emptyDetail] { root.addSubview(v) }
        emptyIcon.symbol = "magnifyingglass"; emptyIcon.pointSize = 24; emptyIcon.tint = NormieSidebarMetrics.secondary
        emptyDetail.maximumNumberOfLines = 2; emptyDetail.lineBreakMode = .byWordWrapping; emptyDetail.alignment = .center
        emptyDetail.textColor = NormieSidebarMetrics.secondary
        scrollView.wantsLayer = true; scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScrollMask();self?.onModeEndpointVisibilityChanged?() }
        }
        accountView.onOpen = { [weak self] in self?.onAccount?() }
        empty.textColor = NormieSidebarMetrics.primary; empty.alignment = .center
        model.onChange = { [weak self] in self?.reload() }
        reload()
    }
    private func updateSearchPalette() {
        searchPlate.layer?.backgroundColor = NativeDisplayOptions.plate(alpha: 0.07).cgColor
        searchIcon.tint = (NativeAppearance.current.foreground ?? .white).withAlphaComponent(0.42)
        searchField.textColor = NormieSidebarMetrics.primary
        searchField.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NormieSidebarMetrics.primary.withAlphaComponent(0.6)])
    }
    isolated deinit { if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) } }
    override func viewDidLayout() {
        super.viewDidLayout()
        layoutContent()
        onModeEndpointVisibilityChanged?()
    }
    private func layoutContent() {
        guard let root = view as? NormieView else { return }
        let safe = modePreparationSafeRect ?? root.contentSafeRect, w = safe.width, h = safe.height
        root.place(searchPlate, CGRect(x: safe.minX+10, y: safe.minY+10, width: max(0, w-20), height: 28))
        root.place(searchIcon, CGRect(x: 8, y: 7, width: 13, height: 14))
        root.place(searchField, CGRect(x: 27, y: 6, width: max(0, searchPlate.bounds.width-35), height: 20))
        root.place(scrollView, CGRect(x: safe.minX, y: safe.minY+44, width: w, height: max(0, h-98)))
        root.place(accountView, CGRect(x: safe.minX+10, y: safe.minY+max(48, h-50), width: max(0, w-20), height: 40))
        let middle = scrollView.frame.midY
        root.place(emptyIcon, CGRect(x: safe.midX-12, y: middle-40, width: 24, height: 24))
        root.place(empty, CGRect(x: safe.minX+16, y: middle-10, width: max(0, w-32), height: 18))
        root.place(emptyDetail, CGRect(x: safe.minX+20, y: middle+14, width: max(0, w-40), height: 32))
        if let surface = root as? NormieSidebarSurface { surface.searchBottom = scrollView.frame.minY; surface.accountTop = accountView.frame.minY-4; surface.needsDisplay = true }
        table.tableColumns.first?.width = max(0, scrollView.contentSize.width)
        table.frame.size.width = scrollView.contentSize.width
        updateScrollMask()
    }
    private func updateScrollMask() {
        let height = scrollView.bounds.height
        guard height > 0 else { return }
        let top = scrollView.contentView.bounds.minY > 0.5
        let bottom = table.frame.height-scrollView.contentView.bounds.maxY > 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if top || bottom {
            scrollMask.frame = scrollView.bounds; scrollMask.startPoint = CGPoint(x: 0.5, y: 1); scrollMask.endPoint = CGPoint(x: 0.5, y: 0)
            scrollMask.colors = [NSColor.white.withAlphaComponent(top ? 0:1).cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.withAlphaComponent(bottom ? 0:1).cgColor]
            scrollMask.locations = [0, NSNumber(value: Double(min(0.25,9/height))), NSNumber(value: Double(max(0.75,1-18/height))), 1]
            scrollView.layer?.mask = scrollMask
        } else { scrollView.layer?.mask = nil }
        CATransaction.commit()
    }
    func reload() {
        guard isViewLoaded else { return }
        defer {onModeEndpointVisibilityChanged?()}
        if let id = model.renaming, id == focusedRename { return } // Keep the active field editor through streaming.
        let values = model.rows.map(value(for:))
        preparedRows = preparedRows.filter { key,entry in model.rows.contains { $0.key == key && value(for:$0) == entry.value } }
        let structureChanged = displayedRows != model.rows
        let changedRows = IndexSet(values.indices.filter { !displayedValues.indices.contains($0) || displayedValues[$0] != values[$0] })
        let selectionChanged = model.current != revealedCurrent || model.focusedRowKey != revealedFocus || model.renaming != focusedRename
        guard structureChanged || !changedRows.isEmpty || selectionChanged else { return }
        let previousOffset=scrollView.contentView.bounds.origin
        let retiredPageFocus = revealedFocus == NormieSidebarRow.more(NormieSidebarModel.historyPageKey).key && model.focusedRowKey == nil
        let reveal=model.current != revealedCurrent || (!retiredPageFocus && model.focusedRowKey != revealedFocus) || model.renaming != focusedRename
        suppressSelection = true
        if structureChanged || model.renaming != focusedRename {
            fullReloadCount += 1; table.reloadData(); table.layoutSubtreeIfNeeded()
        } else if !changedRows.isEmpty {
            rowReloadCount += changedRows.count
            table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
            table.layoutSubtreeIfNeeded()
        }
        displayedRows = model.rows; displayedValues = values
        let focused = model.focusedRowKey.flatMap { key in model.rows.firstIndex { $0.key == key } }
        if let index = focused ?? model.rows.firstIndex(where: { $0.conversationID == model.current && model.current != nil }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if reveal {table.scrollRowToVisible(index)}
        } else { table.deselectAll(nil) }
        if !reveal {
            let clip=scrollView.contentView
            var origin=clip.constrainBoundsRect(CGRect(origin:previousOffset,size:clip.bounds.size)).origin
            origin.y=min(max(0,origin.y),max(0,table.frame.height-clip.bounds.height))
            clip.scroll(to:origin);scrollView.reflectScrolledClipView(clip)
        }
        revealedCurrent=model.current;revealedFocus=model.focusedRowKey
        empty.isHidden = model.query.isEmpty || model.hasHistoryPage || model.rows.contains { $0.conversationID != nil || { if case .project = $0 { true } else { false } }($0) }
        emptyIcon.isHidden = empty.isHidden; emptyDetail.isHidden = empty.isHidden
        emptyDetail.stringValue = "No loaded projects or chats match “\(model.query)”."
        updateScrollMask()
        suppressSelection = false
        focusedRename = model.renaming
        if let id = model.renaming, let row = model.rows.firstIndex(where: { $0.conversationID == id }),
           let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NormieSidebarCell,
           let window = view.window {
            window.makeFirstResponder(cell.rename); cell.rename.selectText(nil)
        }
    }
    func focusSearch() { loadViewIfNeeded(); view.window?.makeFirstResponder(searchField); searchField.selectText(nil) }
    func search(_ query: String) { searchField.stringValue = query; model.search(query) }
    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .group = model.rows[row] { row == 0 ? NormieSidebarMetrics.firstSectionHeight : NormieSidebarMetrics.sectionHeight } else { NormieSidebarMetrics.rowHeight } }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NormieSidebarRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, model.rows.indices.contains(table.selectedRow) else { return }
        let row = model.rows[table.selectedRow]
        if row.key != model.focusedRowKey { model.focus(row) }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item=model.rows[row]
        if let cached=preparedRows.removeValue(forKey:item.key),cached.value == value(for:item),cached.appearance == NativeAppearance.revision,
           cached.display == NativeDisplayOptions.shared.revision,cached.renaming == model.renaming,cached.renameText == model.renameText {return cached.cell}
        return makeCell(item)
    }
    private func makeCell(_ item:NormieSidebarRow)->NormieSidebarCell {
        let cell=NormieSidebarCell();cell.configure(item, model:model)
        cell.activate = { [weak self] in self?.model.activate(item) }
        if let id = item.conversationID {
            cell.setFlightSourceHidden(hiddenPlanets.contains(id))
            cell.pin.run = { [weak self] in self?.model.pin(id) }; cell.archive.run = { [weak self] in self?.model.archive(id) }
            if model.renaming == id {
                cell.beginRename(text: model.renameText, delegate: self)
            }
        }
        return cell
    }
    @objc private func activateRow() {
        let i = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if model.rows.indices.contains(i) { model.activate(model.rows[i]) }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === searchField { model.search(searchField.stringValue) }
        else if let field = notification.object as? NormieField { model.renameText = field.stringValue }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField !== searchField, model.renaming != nil { model.finishRename() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if control === searchField { searchField.stringValue = ""; model.search("") } else { model.cancelRename() }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), control !== searchField {
            model.finishRename(); view.window?.makeFirstResponder(table); return true
        }
        return false
    }
    func menu(for row: Int) -> NSMenu? {
        guard model.rows.indices.contains(row) else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        switch model.rows[row] {
        case .conversation(let id, _):
            guard let c = model.store.conversation(id) else { return nil }
            menu.addItem(NormieMenuItem(c.pinned ? "Unpin" : "Pin") { [weak self] in self?.model.pin(id) })
            menu.addItem(NormieMenuItem("Rename…") { [weak self] in self?.model.beginRename(id) })
            appendIdentityMenu(to: menu, conversation: c)
            menu.addItem(.separator())
            menu.addItem(NormieMenuItem("Archive") { [weak self] in self?.model.archive(id) })
        case .project(let id):
            guard let p = model.store.project(id) else { return nil }
            menu.addItem(NormieMenuItem(p.pinned ? "Unpin" : "Pin") { [weak self] in self?.model.pinProject(id) })
            menu.addItem(NormieMenuItem("New Chat in Project", enabled: model.store.device(p.deviceID)?.online ?? true) { [weak self] in self?.onNewChatInProject?(id) })
        default: return nil
        }
        return menu
    }
}

@MainActor final class NormieSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NormieSidebarMetrics.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor final class NormieSidebarTable: NSTableView {
    var keyAction: ((NormieSidebarKey) -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?
    var undoAction: (() -> Void)?
    @objc func undo(_ sender: Any?) { undoAction?() }
    override func keyDown(with event: NSEvent) {
        let key: NormieSidebarKey?
        switch event.keyCode {
        case 125: key = .down; case 126: key = .up; case 115: key = .home; case 119: key = .end
        case 123: key = .left; case 124: key = .right; case 36, 76: key = .activate; case 53: key = .escape
        case 51 where event.modifierFlags.contains(.command): key = .archive
        default: key = nil
        }
        if let key { keyAction?(key) } else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuForRow?(row(at: convert(event.locationInWindow, from: nil))) }
}
