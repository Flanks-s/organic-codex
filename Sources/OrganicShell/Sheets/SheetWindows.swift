import AppKit

struct SheetWindowConfiguration {
    var title: String
    var size: CGSize
    var minimumSize: CGSize
    var resizable = true
}
/// A seam for offscreen verification: the production factory creates a window only when present is called.
@MainActor protocol SheetWindowHandle: AnyObject {
    var host: NSView { get }
    var title: String { get set }
    func present(at point: CGPoint?)
    func presentSheet(for parent: NSWindow)
    func dismiss()
}
typealias SheetWindowFactory = @MainActor (SheetWindowConfiguration, @escaping @MainActor () -> Void) -> any SheetWindowHandle

@MainActor final class SheetAppKitWindow: SheetWindowHandle {
    private let window: NSWindow
    let host: NSView
    private var closeObserver: NSObjectProtocol?
    private var parentCloseObserver: NSObjectProtocol?
    var title: String { get { window.title } set { window.title = newValue } }
    init(configuration: SheetWindowConfiguration, onClose: @escaping @MainActor () -> Void) {
        var mask: NSWindow.StyleMask = [.titled, .fullSizeContentView]
        if configuration.resizable { mask.formUnion([.closable, .miniaturizable, .resizable]) }
        window = NSWindow(contentRect: CGRect(origin: .zero, size: configuration.size), styleMask: mask, backing: .buffered, defer: false)
        host = OverlayView(frame: CGRect(origin: .zero, size: configuration.size))
        window.contentView = host; window.title = configuration.title; window.contentMinSize = configuration.minimumSize
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.titlebarAppearsTransparent = true
        if !configuration.resizable { window.titleVisibility = .hidden }
        window.appearance = NSAppearance(named: .darkAqua)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated { onClose() } }
    }
    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
    }
    func present(at point: CGPoint?) {
        if !window.isVisible {
            if let point { window.setFrameTopLeftPoint(CGPoint(x: point.x - window.frame.width / 2, y: point.y + 14)) }
            else if let key = NSApp.keyWindow { window.setFrameTopLeftPoint(CGPoint(x: key.frame.midX - window.frame.width / 2, y: key.frame.maxY - 80)) }
            else { window.center() }
        }
        window.makeKeyAndOrderFront(nil)
    }
    func presentSheet(for parent: NSWindow) {
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        parent.beginSheet(window)
    }
    func dismiss() {
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver); self.parentCloseObserver = nil }
        if let parent = window.sheetParent { parent.endSheet(window) }; window.close()
    }
}

/// A view-only projection, with no store observer, approval/request model, or mutation callbacks.
@MainActor final class SheetSubAgentHistory: OverlayView {
    let transcript: NativeTranscript
    let projection: Conversation
    private let heading = SheetStyle.label("", size: 14, weight: .semibold)
    private let task = SheetStyle.label("", size: 12, secondary: true), status = SheetStyle.label("", size: 12, secondary: true)
    private let parentLabel = SheetStyle.label("", size: 11, secondary: true), readOnlyLabel = SheetStyle.label("Read only", size: 11, secondary: true)
    private let portrait = SheetSatellitePortrait(frame: .zero), parentGlyph = SheetIdentityGlyphView(frame: .zero)
    private let statusSpinner=SheetHistorySpinner(size:.small),workingSpinner=SheetHistorySpinner(size:.mini)
    private let workingClip=SheetHistorySpinnerClip(frame:.zero)
    private var scrollObservation:NSObjectProtocol?
    private(set) var parentID: String
    private(set) var subagentID: String
    init(parent: Conversation, subagentID: String, identity: OrbIdentity? = nil) {
        self.parentID = parent.id; self.subagentID = subagentID
        projection = Conversation(id: "readonly-subagent:" + subagentID, title: "Sub-agent")
        projection.isLiveConversation = true
        transcript = NativeTranscript(conversation: projection)
        super.init(frame: .zero); appearance = NSAppearance(named: .darkAqua)
        for view in [heading, task, status, portrait, transcript, parentGlyph, parentLabel, readOnlyLabel,statusSpinner,workingClip] { addSubview(view) }
        workingClip.addSubview(workingSpinner)
        transcript.scrollView.contentView.postsBoundsChangedNotifications=true
        scrollObservation=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:transcript.scrollView.contentView,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.placeWorkingSpinner() } }
        // A file change can be read/expanded; it can never invoke a runtime operation.
        transcript.onReviewChanges = { _ in }
        let lock = NSTextAttachment(); lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))
        lock.bounds = CGRect(x: 0, y: -2, width: 11, height: 11)
        let footer = NSMutableAttributedString(attachment: lock)
        footer.append(NSAttributedString(string: " Read only", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])); readOnlyLabel.attributedStringValue = footer
        readOnlyLabel.setAccessibilityLabel("Read only")
        update(parent: parent, identity: identity)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) };statusSpinner.stopAnimation(nil);workingSpinner.stopAnimation(nil) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();syncSpinners() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true; layoutSubtreeIfNeeded() }
    func update(parent: Conversation, identity: OrbIdentity? = nil) {
        guard parent.id == parentID else { return }
        let index = parent.satellites.firstIndex { $0.id == subagentID } ?? 0
        let satellite = parent.satellites.first { $0.id == subagentID }
        let live = parent.backendThreadID != nil || parent.isLiveConversation || satellite?.threadID != nil
        let done = satellite?.done ?? true
        portrait.face = satellite?.face ?? "-_-"; portrait.done = done; parentGlyph.identity = identity ?? .assigned(parent.identityIndex)
        heading.stringValue = "Sub-agent \(index + 1)"
        task.stringValue = satellite?.title ?? (live ? "Sub-agent" : SheetSubAgentCopy.task(index))
        status.stringValue = done ? "✓ Done" : "Running"; status.textColor = done ? .systemGreen : .secondaryLabelColor
        parentLabel.stringValue = "From “\(parent.title)”"; projection.title = heading.stringValue
        projection.backendThreadID = satellite?.threadID; projection.running = !done
        if live {
            projection.items = satellite?.items ?? []
            if projection.items.isEmpty { projection.items = [.init(id: "history-waiting", turnID: "", kind: .notice(.info), text: "Waiting for the sub-agent’s history…")] }
        } else { projection.items = SheetSubAgentCopy.items(index, done: done) }
        if !done { projection.items.append(.init(id: "subagent-working", turnID: "", kind: .notice(.info), text: "Working…")) }
        projection.revision += 1
        transcript.refresh(); needsLayout = true
        syncSpinners()
        setAccessibilityLabel("\(heading.stringValue), from \(parent.title), read only")
    }
    override func layout() {
        super.layout(); let s = max(1, window?.backingScaleFactor ?? 1), w = bounds.width
        portrait.frame = SheetStyle.snap(CGRect(x: 20, y: 40, width: 38, height: 38), scale: s)
        heading.frame = SheetStyle.snap(CGRect(x: 70, y: 40, width: max(1, w - 182), height: 20), scale: s)
        status.frame = SheetStyle.snap(CGRect(x: max(20, w - 104), y: 42, width: 84, height: 18), scale: s); status.alignment = .right
        let statusWidth=ceil((status.stringValue as NSString).size(withAttributes:[.font:status.font!]).width)
        statusSpinner.frame=SheetStyle.snap(CGRect(x:status.frame.maxX-statusWidth-22,y:42,width:16,height:16),scale:s)
        task.frame = SheetStyle.snap(CGRect(x: 70, y: 63, width: max(1, w - 90), height: 34), scale: s); task.maximumNumberOfLines = 2
        transcript.frame = SheetStyle.snap(CGRect(x: 0, y: 105, width: w, height: max(1, bounds.height - 141)), scale: s)
        transcript.layoutSubtreeIfNeeded()
        workingClip.frame=transcript.frame
        parentGlyph.frame = SheetStyle.snap(CGRect(x: 20, y: bounds.height - 26, width: 15, height: 15), scale: s)
        parentLabel.frame = SheetStyle.snap(CGRect(x: 43, y: bounds.height - 26, width: max(1, w - 175), height: 16), scale: s)
        readOnlyLabel.frame = SheetStyle.snap(CGRect(x: max(20, w - 128), y: bounds.height - 26, width: 108, height: 16), scale: s); readOnlyLabel.alignment = .right
        placeWorkingSpinner()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(0.6).setFill(); bounds.fill()
        NSColor.separatorColor.setFill(); CGRect(x: 0, y: 104, width: bounds.width, height: 1).fill(); CGRect(x: 0, y: bounds.height - 36, width: bounds.width, height: 1).fill()
    }
    private func syncSpinners() {
        statusSpinner.isHidden = !projection.running
        statusSpinner.setRunning(projection.running && window != nil && !isHiddenOrHasHiddenAncestor)
        placeWorkingSpinner()
    }
    private func placeWorkingSpinner() {
        let r=transcript.glyphFrames(itemID:"subagent-working",range:NSRange(location:0,length:7)).first?.rect
        guard projection.running,let r,!transcript.isHidden else { workingSpinner.isHidden=true;workingSpinner.setRunning(false);return }
        let rect=workingClip.convert(r,from:transcript),s=max(1,window?.backingScaleFactor ?? 1)
        workingSpinner.frame=SheetStyle.snap(CGRect(x:rect.minX-16,y:rect.midY-5,width:10,height:10),scale:s)
        workingSpinner.isHidden = !workingClip.bounds.intersects(workingSpinner.frame)
        workingSpinner.setRunning(window != nil && !workingSpinner.isHidden && !isHiddenOrHasHiddenAncestor)
    }
}

@MainActor private final class SheetHistorySpinnerClip:OverlayView {
    override init(frame:NSRect) { super.init(frame:frame);wantsLayer=true;layer?.masksToBounds=true }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point:NSPoint)->NSView? { nil }
}

/// Product Design/Spinner.swift: AppKit's render-server animation, not a Swift timer or a textual ellipsis.
@MainActor private final class SheetHistorySpinner:NSProgressIndicator {
    private var animating=false
    init(size:NSControl.ControlSize) { super.init(frame:.zero);style = .spinning;isIndeterminate=true;isDisplayedWhenStopped=false;usesThreadedAnimation=true;controlSize=size;setAccessibilityElement(false) }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setRunning(_ value:Bool) { guard animating != value else { return };animating=value;if value { startAnimation(nil) } else { stopAnimation(nil) } }
    override func draw(_ dirtyRect:NSRect) { super.draw(dirtyRect) }
    override func hitTest(_ point:NSPoint)->NSView? { nil }
}

@MainActor final class SheetSubAgentWindows {
    private struct Entry { let parentID: String; let generation: UUID; let handle: any SheetWindowHandle; let history: SheetSubAgentHistory }
    private var entries: [String: Entry] = [:]
    private let factory: SheetWindowFactory
    var onOpen: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    var resolveIdentity: (Conversation) -> OrbIdentity = { .assigned($0.identityIndex) }
    var openIDs: Set<String> { Set(entries.keys) }
    init(factory: @escaping SheetWindowFactory = { SheetAppKitWindow(configuration: $0, onClose: $1) }) { self.factory = factory }
    isolated deinit { for entry in entries.values { entry.handle.dismiss() } }
    func history(subagentID: String) -> SheetSubAgentHistory? { entries[subagentID]?.history }
    @discardableResult func present(subagentID: String, of parent: Conversation, at screenPoint: CGPoint? = nil) -> Bool {
        guard parent.satellites.contains(where: { $0.id == subagentID }) else { return false }
        if let entry = entries[subagentID] {
            guard entry.parentID == parent.id else { return false } // Never attach an existing ID to a different parent.
            entry.history.update(parent: parent, identity: resolveIdentity(parent)); entry.handle.title = windowTitle(subagentID, parent)
            entry.handle.present(at: screenPoint); onOpen?(subagentID); return true
        }
        let generation = UUID(), history = SheetSubAgentHistory(parent: parent, subagentID: subagentID, identity: resolveIdentity(parent))
        let configuration = SheetWindowConfiguration(title: windowTitle(subagentID, parent), size: CGSize(width: 420, height: 440), minimumSize: CGSize(width: 340, height: 280))
        let handle = factory(configuration) { [weak self] in
            guard let self, self.entries[subagentID]?.generation == generation else { return }
            self.entries.removeValue(forKey: subagentID); self.onDismiss?(subagentID)
        }
        history.frame = handle.host.bounds; history.autoresizingMask = [.width, .height]; handle.host.addSubview(history); history.layoutSubtreeIfNeeded()
        entries[subagentID] = Entry(parentID: parent.id, generation: generation, handle: handle, history: history)
        handle.present(at: screenPoint); onOpen?(subagentID); return true
    }
    func refresh(parent: Conversation) { for entry in entries.values where entry.parentID == parent.id { entry.history.update(parent: parent, identity: resolveIdentity(parent)); entry.handle.title = windowTitle(entry.history.subagentID, parent) } }
    func dismiss(subagentID: String) { guard let entry = entries.removeValue(forKey: subagentID) else { return }; entry.handle.dismiss(); onDismiss?(subagentID) }
    func dismiss() { for id in Array(entries.keys) { dismiss(subagentID: id) } }
    private func windowTitle(_ id: String, _ parent: Conversation) -> String { "Sub-agent \((parent.satellites.firstIndex { $0.id == id } ?? 0) + 1) · \(parent.title)" }
}

enum SheetSubAgentCopy {
    static let tasks = ["Searching for rowInsets across native/", "Running LayoutTests at 560 and 1920 pt", "Reading the sidebar list styles", "Comparing against the Canopy prototype", "Checking the narrow window", "Writing the summary"]
    static func task(_ index: Int) -> String { tasks[max(0, index) % tasks.count] }
    static func items(_ index: Int, done: Bool) -> [TranscriptItem] {
        let scripts: [[(Conversation.Kind, String)]] = [
            [(.reasoning, "Thought for 3s"), (.command, "rg -n \"rowInsets\" native/"), (.assistant, "Two hits, both in `SidebarView.swift`. The list rows set their own insets."), (.command, "rg -n \"listRowInsets\" native/ --count")],
            [(.reasoning, "Thought for 2s"), (.command, "swift test --filter LayoutTests"), (.assistant, "7 passed at 1920 pt. Running again at 560 pt."), (.command, "swift test --filter LayoutTests/narrow")],
            [(.reasoning, "Thought for 5s"), (.command, "sed -n 1,80p native/SidebarView.swift"), (.assistant, "`.listStyle(.sidebar)` with custom row insets; the system metrics would do.")],
            [(.reasoning, "Thought for 4s"), (.command, "open design/canopy/prototype/Main.dc.html"), (.assistant, "The prototype rows are 28 pt with 8 pt leading. Ours match once the insets go.")],
            [(.reasoning, "Thought for 2s"), (.command, "scripts/run.sh -- --size 560x700"), (.assistant, "The title no longer wraps at 560 pt. Nothing else moved.")],
            [(.reasoning, "Thought for 6s"), (.assistant, "Collecting what the others found for the parent chat.")]
        ]
        var items = scripts[max(0, index) % scripts.count].enumerated().map { TranscriptItem(id: "mock-subagent-\($0.offset)", kind: $0.element.0, text: $0.element.1, running: false) }
        if done { items.append(.init(id: "mock-subagent-report", turnID: "", kind: .notice(.info), text: "Done. Reported back to the parent chat.")) }
        return items
    }
}
