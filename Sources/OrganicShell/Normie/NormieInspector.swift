import AppKit

@MainActor struct NormieCodeStyle {
    var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var foreground = NativePalette.label
    var added = NSColor(srgbRed: 74/255, green: 230/255, blue: 114/255, alpha: 1)
    var removed = NSColor(srgbRed: 1, green: 69/255, blue: 58/255, alpha: 1)
    var fillAlpha: CGFloat = 0.10
    @MainActor static var nativeCurrent:Self{let code=NativeAppearance.current.code;return .init(font:code.font(11),foreground:code.text ?? NativePalette.label,added:code.added ?? NativePalette.added,removed:code.removed ?? NativePalette.removed,fillAlpha:code.added != nil || code.removed != nil ? 0.16:0.10)}
}

@MainActor final class NormieInspectorController: NSViewController {
    /// Standalone inspectors render synchronously by default. A collapsed workbench withdraws presentation only.
    var presentationActive = true { didSet {
        if isViewLoaded { NormieSidebarSpinner.setPresented(presentationActive, in: view) }
        if !presentationActive{motion.settle();referenceContent?.revoke()}
        if presentationActive && !oldValue { shownValue = c.map { value(for: $0) }; render() }
    } }
    private(set) var renderCount = 0
    private var shownValue: ShownValue?
    private struct SatelliteValue: Equatable { var id: String, face: String, title: String?; var done: Bool }
    private struct ShownValue: Equatable {
        var identity: ObjectIdentifier, title: String, goal: String, status: String, branch: String
        var context: String, percent: Int, compactions: Int, tokens: Int, reportedTokens: Int?
        var contextShown: Double, live: Bool, contextReported: Bool, gitBusy: Bool, running: Bool
        var gitError: String?, diffHash: String?, commit: Commit?
        var plan: [PlanStep], changes: [FileChange], paths: [String], satellites: [SatelliteValue]
        var usesLiveCore = false, canCommit = false, canCompact = false, canOpenSubAgent = false, hasBackend = false
        @MainActor init(_ c: Conversation) {
            identity = ObjectIdentifier(c); title = c.title; goal = c.items.first { $0.kind == .user }?.text ?? c.goal
            status = c.status; branch = c.branch; context = c.contextDescription; percent = c.contextPercent
            compactions = c.compactions; tokens = c.tokensUsed; reportedTokens = c.reportedTokensUsed
            contextShown = c.contextShown; live = c.isLiveConversation; contextReported = c.contextUsageReported; running = c.running
            gitBusy = c.gitBusy; gitError = c.gitError; diffHash = c.gitDiffHash; commit = c.lastCommit
            plan = c.plan; changes = c.changes; paths = c.gitPaths; hasBackend = c.backendThreadID != nil
            satellites = c.satellites.map { .init(id: $0.id, face: $0.face, title: $0.title, done: $0.done) }
        }
    }
    private func value(for conversation: Conversation) -> ShownValue {
        var value = ShownValue(conversation)
        value.usesLiveCore = store.usesLiveCore; value.canCommit = actions.commit != nil
        value.canCompact = actions.compact != nil; value.canOpenSubAgent = actions.subAgent != nil
        return value
    }
    enum Tab { case status, changes, sources, file }
    private let referenceIndex = TranscriptContentIndex()
    private var referenceSource: SourceLocator?
    private var referenceResult = TranscriptReferencePreview(state: .unavailable)
    private var referenceRevision = -1
    private var referenceIndexReady = false
    private var referenceObservation: UUID?
    private var referenceReturnTab: Tab = .status
    private var referenceReturnOffset = CGPoint.zero
    private var referenceSourcesOffset = CGPoint.zero
    private var referenceFileFromSources = false
    var onReference: ((Conversation, TranscriptReferenceRequest) -> Void)?
    var onReferenceDismiss: (() -> Void)?
    var onSourcesRequest: (() -> Void)?
    private var referenceContent: NormieReferenceContent?
    var referenceInputActive = true { didSet {
        guard referenceInputActive != oldValue else { return }
        if !referenceInputActive { referenceContent?.revoke() }
        else if tab == .sources || tab == .file { render() }
    } }
    let store: ConversationStore, actions: NormieActions
    private let inlineChanges: Bool
    let scrollView = NSScrollView()
    private let document = NormieView()
    private var c: Conversation?
    private var openFiles: Set<String> = []
    private var commitOpen = false
    private var review: NormieGitReview?
    private(set) var tab: Tab = .status
    private var applyingAppearance=false
    var codeStyle = NormieCodeStyle.nativeCurrent { didSet { if !applyingAppearance{render()} } }
    var notice: (String) -> Void = { _ in }
    private var renderWidth: CGFloat = 0
    private var commitField: NormieField?
    private var rendering = false
    let motion=NormieInspectorMotion()
    init(store: ConversationStore, actions: NormieActions, inlineChanges: Bool = false) {
        self.store = store; self.actions = actions; self.inlineChanges = inlineChanges
        super.init(nibName: nil, bundle: nil)
        referenceObservation = store.observeChanges { [weak self] c, change in
            guard let self, self.c === c else { return }
            guard self.referenceIndexReady, self.referenceInputActive,
                  let id = change.itemID, let index = c.transcriptItemIndex(id) else {
                self.referenceIndexReady = false; return
            }
            self.referenceIndex.updateSource(c.items[index]); self.referenceRevision = c.revision
            if self.tab == .sources { self.render() }
        }
    }
    isolated deinit { if let referenceObservation { store.removeObserver(referenceObservation) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func applyNativeAppearance(){
        applyingAppearance=true;codeStyle = .nativeCurrent;applyingAppearance=false
        for case let plate as NormieView in document.subviews where plate.identifier?.rawValue.hasPrefix("section/") == true {plate.layer?.backgroundColor=NativeDisplayOptions.plate(alpha:0.045).cgColor}
        let original=document.subviews.map{($0,$0.frame)}
        var changes:[(CGFloat,CGFloat)]=[]
        for (view,frame) in original{guard let text=view as? NormieDiffTextView,let storage=text.textStorage else{continue}
            let selected=text.selectedRanges,old=NSAttributedString(attributedString:storage)
            storage.beginEditing();old.enumerateAttributes(in:NSRange(location:0,length:old.length)){attrs,range,_ in
                let sign=attrs[.init("organic.diff.kind")] as? String ?? " "
                storage.addAttributes([.font:self.codeStyle.font,.foregroundColor:sign == " " ? self.codeStyle.foreground.withAlphaComponent(NativeDisplayOptions.shared.state.increaseContrast ? 1:0.62):self.codeStyle.foreground],range:range)
                if sign != " "{storage.addAttribute(.backgroundColor,value:NativeDisplayOptions.plate(sign == "+" ? self.codeStyle.added:self.codeStyle.removed,alpha:self.codeStyle.fillAlpha),range:range)}
            };storage.endEditing();text.selectedRanges=selected
            if let container=text.textContainer{text.layoutManager?.ensureLayout(for:container);let height=max(20,ceil(text.layoutManager?.usedRect(for:container).height ?? 20));changes.append((frame.maxY,height-frame.height));text.frame.size.height=height}
        }
        for (view,frame) in original{
            let before=changes.filter{$0.0<=frame.minY}.reduce(CGFloat(0)){$0+$1.1};view.frame.origin.y=frame.minY+before
            if view is NormieView{view.frame.size.height=frame.height+changes.filter{$0.0>frame.minY && $0.0<=frame.maxY}.reduce(CGFloat(0)){$0+$1.1}}
        }
        document.frame.size.height+=changes.reduce(CGFloat(0)){$0+$1.1};document.needsDisplay=true
    }
    override func loadView() {
        let root = NormieMotionHost(); root.fill = NormieDrawing.background; view = root
        motion.attach(root,scroll:scrollView)
        root.onHidden={[weak self] in self?.motion.settle()}
        root.onWindowChange={[weak self] in if self?.view.window == nil{self?.motion.settle()}}
        root.onDisplayOptionsChange={[weak self] in self?.render()}
        root.onAppearanceChange={[weak self] in self?.applyNativeAppearance()}
        scrollView.contentView = NormieClipView(); scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true; scrollView.documentView = document
        root.addSubview(scrollView); root.setAccessibilityRole(.group); root.setAccessibilityLabel("Status inspector")
    }
    override func viewDidLayout() {
        super.viewDidLayout(); scrollView.frame = (view as? NormieView)?.contentSafeRect ?? view.safeAreaRect
        scrollView.tile()
        let width = NormieDrawing.pixel(scrollView.contentSize.width, scale: (view as? NormieView)?.scale ?? 2)
        if width != renderWidth { renderWidth = width; render() }
    }
    func show(_ conversation: Conversation?) {
        let changed = c !== conversation
        if changed {
            referenceContent?.revoke()
            referenceIndex.removeAll(); referenceIndexReady = false; referenceSource = nil; referenceRevision = -1
            referenceSourcesOffset = .zero; referenceFileFromSources = false
            motion.settle()
            openFiles = []; commitOpen = false; tab = .status; review = nil
            scrollView.contentView.scroll(to: .zero)
        }
        c = conversation
        if !changed, (tab == .sources || tab == .file), referenceRevision != conversation?.revision {
            referenceRevision = conversation?.revision ?? -1; render()
        }
        guard presentationActive else { shownValue = nil; return }
        let value = conversation.map { self.value(for: $0) }
        if changed || shownValue != value {
            let planChanged = !changed && shownValue?.plan != value?.plan
            shownValue = value; render(animated:planChanged && !commitOpen ? .snappy25:nil)
        }
    }
    func showChanges() { if tab == .sources || tab == .file { onReferenceDismiss?() }; tab = .changes; render(animated:.snappy20) }
    func showStatus() { if tab == .sources || tab == .file { onReferenceDismiss?() }; tab = .status; render(animated:.snappy20) }
    private func enterReferences(_ destination: Tab) {
        if tab == .status || tab == .changes { referenceReturnTab = tab; referenceReturnOffset = scrollView.contentView.bounds.origin }
        if destination == .file, tab != .file {
            referenceFileFromSources = tab == .sources
            if tab == .sources { referenceSourcesOffset = referenceContent?.readingOffset ?? .zero }
        }
        tab = destination; referenceRevision = c?.revision ?? -1
    }
    func showSources() { onReferenceDismiss?(); enterReferences(.sources); render() }
    private func requestSources() { if let onSourcesRequest { onSourcesRequest() } else { showSources() } }
    func showReference(_ source: SourceLocator, result: TranscriptReferencePreview) {
        enterReferences(.file); referenceSource = source; referenceResult = result; render()
    }
    private func returnFromReferences() {
        if tab == .file, referenceFileFromSources { showSources(); return }
        onReferenceDismiss?()
        tab = referenceReturnTab; render(); scrollView.contentView.scroll(to: referenceReturnOffset)
    }
    func toggleFile(_ path: String) { if !openFiles.insert(path).inserted { openFiles.remove(path) }; render(animated:.snappy20) }
    func isFileExpanded(_ path: String) -> Bool { openFiles.contains(path) }
    private func render(animated:NormieDetailItemMotion.Kind?=nil) {
        guard presentationActive, isViewLoaded, !rendering else { return }; rendering = true; defer { rendering = false }
        renderCount += 1
        if tab == .sources, let referenceContent, referenceContent.isSourceList { referenceSourcesOffset = referenceContent.readingOffset }
        referenceContent?.revoke(); referenceContent = nil
        let before=motion.before(document,animated:animated)
        defer{motion.after(document,before:before,kind:animated)}
        var occurrence:[String:Int]=[:]
        func identify(_ v:NSView,_ key:String){let n=occurrence[key,default:0];occurrence[key]=n+1;v.identifier=NSUserInterfaceItemIdentifier(key+"/"+String(n))}
        let offset = scrollView.contentView.bounds.origin
        let referenceTab = tab == .sources || tab == .file
        let retainedField = commitOpen && !referenceTab ? commitField : nil
        document.subviews.filter { $0 !== retainedField }.forEach { $0.removeFromSuperview() }
        if !referenceTab { commitField = retainedField }
        let width = max(160, renderWidth), outer: CGFloat = 14
        var inset = outer, inner = width-2*outer
        var y: CGFloat = 18
        var sectionStart: CGFloat?
        var sectionKey=""
        func finishSection() {
            guard let start = sectionStart else { return }; y += 2
            let plate = NormieView(frame: CGRect(x: outer, y: start, width: max(1, width-2*outer), height: y-start))
            plate.wantsLayer = true; plate.layer?.cornerRadius = 10
            plate.layer?.backgroundColor = NativeDisplayOptions.plate(alpha:0.045).cgColor
            identify(plate,"section/"+sectionKey);document.addSubview(plate, positioned: .below, relativeTo: document.subviews.first)
            sectionStart = nil; inset = outer; inner = width-2*outer
        }
        @discardableResult func text(_ value: String, size: CGFloat = 12, color: NSColor = NativePalette.label, lines: Int = 1, mono: Bool = false, weight: NSFont.Weight = .regular) -> NormieLabel {
            let label = NormieDrawing.label(value, size: size, weight: weight); label.textColor = color
            label.maximumNumberOfLines = lines; label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
            label.cell?.wraps = lines > 1; label.cell?.usesSingleLineMode = lines == 1; label.cell?.isScrollable = false
            label.cell?.truncatesLastVisibleLine = true
            if mono { label.font = .monospacedSystemFont(ofSize: size, weight: .regular) }
            identify(label,"label/"+value);document.addSubview(label)
            // NSTextFieldCell accounts for its drawing insets and the configured line limit.
            let h = ceil(label.cell?.cellSize(forBounds:CGRect(x:0,y:0,width:inner,height:10000)).height ?? 0)
            document.place(label, CGRect(x: inset, y: y, width: inner, height: h+2)); y += h+10
            return label
        }
        func heading(_ title: String) {
            finishSection(); y += 16; inset = outer+4; inner = width-inset-outer
            text(title, size: 11, color: NativePalette.secondaryLabel, weight: .semibold); y -= 4
            sectionKey=title; sectionStart = y; y += 12; inset = outer+12; inner = width-2*inset
        }
        @discardableResult func button(_ title: String, enabled: Bool = true, key:String?=nil, symbol: String? = nil, action: @escaping () -> Void) -> NormieButton {
            let b = NormieDrawing.button(title, action: action); b.isEnabled = enabled
            b.alignment = .left
            if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
            identify(b,key ?? "button/"+title);document.addSubview(b); document.place(b, CGRect(x: inset, y: y, width: inner, height: 18)); y += 28
            return b
        }
        @discardableResult func symbol(_ name: String, at point: CGPoint, color: NSColor = NativePalette.secondaryLabel, size: CGFloat = 12) -> NormieInspectorSymbol {
            let image = NormieInspectorSymbol(name:name,size:size,tint:color)
            identify(image,"symbol/"+name); document.addSubview(image); document.place(image,CGRect(origin:point,size:CGSize(width:max(16,size),height:max(16,size))))
            return image
        }
        func spinner(at point: CGPoint) {
            let spin = NormieSidebarSpinner(); spin.style = .spinning; spin.controlSize = .mini
            spin.presented = presentationActive; spin.running = true
            identify(spin,"spinner"); document.addSubview(spin); document.place(spin,CGRect(origin:point,size:CGSize(width:16,height:16)))
        }
        if let c, tab == .sources || tab == .file {
            text(tab == .sources ? "Sources" : "File Target", size: 15, weight: .semibold)
            button("‹ Back") { [weak self] in self?.returnFromReferences() }
            if tab == .file { button("Sources") { [weak self] in self?.requestSources() } }
            let content: NormieReferenceContent
            if tab == .file, let source = referenceSource { content = NormieReferenceContent(source: source, result: referenceResult) }
            else {
                let sources = referenceIndexReady ? referenceIndex.indexedSources : referenceIndex.sources(in: c.items)
                referenceIndexReady = true; content = NormieReferenceContent(sources: sources)
            }
            content.onOpen = { [weak self, weak c] source in
                guard let self, let c, self.c === c, self.referenceInputActive, self.presentationActive else { return }; self.onReference?(c, .init(source: source))
            }
            referenceContent = content
            if !referenceInputActive { content.revoke() }
            document.addSubview(content)
            content.frame = CGRect(x: outer, y: y, width: width - 2 * outer, height: max(360, view.bounds.height - y - 20))
            if tab == .sources { content.restoreReadingOffset(referenceSourcesOffset) }
            document.frame = CGRect(x: 0, y: 0, width: width, height: content.frame.maxY + 20)
            return
        }
        text(inlineChanges || tab == .status ? "Status":"Changes", size: 15, weight: .semibold); y -= 6
        text(c?.title ?? "New Chat", size: 11, color: NativePalette.secondaryLabel); y -= 10
        guard let c else {
            y += 136
            let sparkles = symbol("sparkles",at:CGPoint(x:width/2-12,y:y),size:24)
            sparkles.frame = CGRect(x:(width-sparkles.imageSize.width)/2,y:y,width:sparkles.imageSize.width,height:sparkles.imageSize.height)
            y = sparkles.frame.maxY+6
            text("Nothing Yet", size: 13, weight: .semibold).alignment = .center; y -= 4
            text("Status appears once the chat starts.", size: 11, color: NativePalette.secondaryLabel, lines: 3).alignment = .center
            document.frame = CGRect(x: 0, y: 0, width: width, height: max(y+20, view.bounds.height))
            scrollView.contentView.scroll(to: .zero); return
        }
        if tab == .changes && !inlineChanges { button("‹ Status") { [weak self] in self?.showStatus() } }
        button("Sources", symbol: "link") { [weak self] in self?.requestSources() }
        heading("Git")
        let added = c.changes.reduce(0) { $0+$1.added }, removed = c.changes.reduce(0) { $0+$1.removed }
        let changes = NormieInspectorChangesButton()
        changes.configure(count:c.changes.count,added:added,removed:removed,expanded:tab == .changes)
        changes.isEnabled = !c.changes.isEmpty && !c.gitBusy && (!store.usesLiveCore || c.gitDiffHash != nil)
        changes.run = { [weak self] in
            guard let self else { return }; if self.tab == .changes { self.showStatus() } else { self.showChanges() }
        }
        identify(changes,"button/Changes");document.addSubview(changes);document.place(changes,CGRect(x:inset,y:y,width:inner,height:18));y += 28
        if tab == .changes {
            if !commitOpen { review = NormieGitReview(c) }
            if c.changes.isEmpty { text("No changes", color: NativePalette.secondaryLabel) }
            for file in c.changes {
                let path = file.path
                button("\(openFiles.contains(path) ? "⌄" : "›") \(path)   +\(file.added) −\(file.removed)",key:"file/"+path) { [weak self] in self?.toggleFile(path) }
                if openFiles.contains(path) {
                    let code = NormieDiffTextView()
                    let body = NSMutableAttributedString(string: "")
                    for line in file.lines {
                        let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
                        var attrs: [NSAttributedString.Key: Any] = [.init("organic.diff.kind"):sign,.font: codeStyle.font, .foregroundColor: line.kind == .context ? codeStyle.foreground.withAlphaComponent(NativeDisplayOptions.shared.state.increaseContrast ? 1:0.62) : codeStyle.foreground]
                        if line.kind != .context { attrs[.backgroundColor] = NativeDisplayOptions.plate(line.kind == .added ? codeStyle.added:codeStyle.removed,alpha:codeStyle.fillAlpha) }
                        body.append(NSAttributedString(string: sign+" "+line.text+"\n", attributes: attrs))
                    }
                    code.textStorage?.setAttributedString(body)
                    code.textContainer?.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
                    code.layoutManager?.ensureLayout(for: code.textContainer!)
                    let h = max(20, ceil(code.layoutManager?.usedRect(for: code.textContainer!).height ?? 20))
                    identify(code,"diff/"+path);document.addSubview(code); document.place(code, CGRect(x: inset, y: y, width: inner, height: h)); y += h+8
                }
            }
        }
        let divider = NormieView(frame:CGRect(x:inset,y:y-1,width:inner,height:1)); divider.fill = NativePalette.label.withAlphaComponent(0.12)
        identify(divider,"git.divider"); document.addSubview(divider); y += 10
        let branch = NormieInspectorBranchButton()
        branch.configure(c.branch.isEmpty ? "—":c.branch)
        branch.run = { [weak self] in self?.showBranchMenu() }
        identify(branch,"button/branch");document.addSubview(branch)
        document.place(branch,CGRect(x:inset,y:y,width:inner,height:18));y += 28
        if let commit = c.lastCommit { text(commit.message, lines: 2); text(commit.hash+" · "+NormieSidebarModel.shortAge(commit.at), size: 11, color: NativePalette.secondaryLabel, mono: true) }
        if let error = c.gitError { text(error, color: .systemRed, lines: 3) }
        if commitOpen {
            let input = commitField ?? NormieField(); input.placeholderString = "Commit message"
            if commitField == nil { input.stringValue = c.plan.last(where: \.done)?.title ?? c.title }
            input.target = self; input.action = #selector(commitFromField(_:))
            input.setAccessibilityLabel("Commit message"); if input.superview == nil { document.addSubview(input) }
            identify(input,"commit.field");document.place(input, CGRect(x: inset, y: y, width: inner, height: 24)); y += 28; commitField = input
            button("Commit \(c.changes.count) files", enabled: !c.gitBusy) { [weak self] in self?.commit() }
            button("Cancel") { [weak self] in self?.commitOpen = false; self?.render(animated:.snappy20) }
        } else {
            let commit = button("Commit…", enabled: !c.changes.isEmpty && !c.gitBusy && (!store.usesLiveCore || (actions.commit != nil && c.gitDiffHash != nil)), symbol:"checkmark.seal") { [weak self] in _ = self?.beginCommit() }
            commit.frame.size.width = 96
            let menu = NormieDrawing.button(""){ [weak self] in self?.showGitMenu() }; menu.image = NSImage(systemSymbolName:"ellipsis",accessibilityDescription:nil)
            menu.setAccessibilityLabel("Git actions"); identify(menu,"button/Git actions…"); document.addSubview(menu)
            document.place(menu,CGRect(x:inset+104,y:commit.frame.minY,width:22,height:18))
        }
        if inlineChanges || tab == .status {
            heading("Goal")
            let rowY = y, rowInset = inset, rowWidth = inner
            let state: String = switch SummaryLog(c,playful:false).state {
            case .running: "Working"; case .waiting: "Waiting"; case .asking: "Asking"; case .failedRunning: "Error"
            case .failedStopped: "Stopped"; case .done: c.lastTurnInterrupted ? "Stopped":"Complete"; case .idle: "Idle"
            }
            let stateWidth = ceil((state as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width)+5
            symbol("scope",at:CGPoint(x:inset,y:y)); inset += 24; inner -= 24+stateWidth+6
            text(c.items.first { $0.kind == .user }?.text ?? c.goal, lines: 3)
            let afterGoal = y; y = rowY; inset = width-outer-12-stateWidth; inner = stateWidth
            text(state,size:11,color:NativePalette.tertiaryLabel); y = afterGoal; inset = rowInset+24; inner = rowWidth-24
            let tokens=(c.isLiveConversation || c.backendThreadID != nil) && c.reportedTokensUsed == nil ? "Usage not reported":"\(c.tokensUsed.formatted(.number.notation(.compactName))) tokens"
            text([c.plan.isEmpty ? nil:"\(c.plan.filter(\.done).count)/\(c.plan.count) steps",tokens,c.satellites.isEmpty ? nil:"\(c.satellites.count) sub-agents"].compactMap{$0}.joined(separator:" · "), size: 11, color: NativePalette.secondaryLabel, lines: 2)
            if !c.plan.isEmpty {
                heading("Progress")
                let current = c.plan.firstIndex { !$0.done }
                for (index,step) in c.plan.enumerated() {
                    let x = inset, w = inner
                    if !step.done && index == current && c.running { spinner(at:CGPoint(x:x,y:y)) }
                    else { symbol(step.done ? "checkmark.circle.fill":"circle",at:CGPoint(x:x,y:y),color:step.done ? .systemGreen:NativePalette.tertiaryLabel) }
                    inset += 24; inner -= 24
                    let label = text(step.title,color:step.done ? NativePalette.secondaryLabel:NativePalette.label,lines:3)
                    if step.done { let value = NSMutableAttributedString(attributedString:label.attributedStringValue); value.addAttribute(.strikethroughStyle,value:NSUnderlineStyle.single.rawValue,range:NSRange(location:0,length:value.length)); label.attributedStringValue = value }
                    y -= 2; inset = x; inner = w
                }
            }
            heading("Context")
            let ring = NativeComposerContextRing(); ring.percent = (c.isLiveConversation || c.backendThreadID != nil) && !c.contextUsageReported ? nil:c.contextPercent
            identify(ring,"context.ring"); document.addSubview(ring); document.place(ring,CGRect(x:inset,y:y,width:22,height:22)); inset += 32; inner -= 32
            text(c.contextDescription).toolTip = c.contextDescription; y -= 8
            text(c.isLiveConversation ? "\(c.contextUsageReported ? String(c.contextPercent)+"%":"Usage not reported") · automatic compaction managed by the model" : c.compactions == 0 ? "\(c.contextPercent)% · compacts at 97%":"\(c.contextPercent)% · compacted \(c.compactions)×", size: 11, color: NativePalette.secondaryLabel)
            let compact = button("Compact Now", enabled: c.contextShown >= 0.1 && (!store.usesLiveCore || actions.compact != nil)) { [weak self] in
                guard let self else { return }; if let compact = self.actions.compact { compact(c) }
                else { c.contextUsed *= 0.35; c.compactions += 1; self.store.changed(c); self.notice("Compacted context (prototype)") }
            }
            compact.font = .systemFont(ofSize:11); compact.contentTintColor = NativePalette.accent
            if !c.satellites.isEmpty {
                heading("Sub-agents")
                for (index,satellite) in c.satellites.enumerated() {
                    let row = NormieInspectorSubAgentButton(); row.configure(satellite,index:index)
                    row.isEnabled = actions.subAgent != nil; row.run = { [weak self] in self?.actions.subAgent?(c,satellite) }
                    identify(row,"subagent/"+satellite.id); document.addSubview(row); document.place(row,CGRect(x:inset,y:y,width:inner,height:30)); y += 40
                }
            }
        }
        finishSection()
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(view.bounds.height, ceil(y+16)))
        scrollView.contentView.scroll(to: scrollView.contentView.constrainBoundsRect(CGRect(origin: offset, size: scrollView.contentSize)).origin)
    }
    private func showBranchMenu() {
        guard let c else { return }; let menu = NSMenu(); menu.autoenablesItems = false
        if store.usesLiveCore {
            menu.addItem(NormieMenuItem(c.branch, enabled: false)); menu.addItem(NormieMenuItem("Switch branches in the terminal", enabled: false))
        } else {
            var seen: Set<String> = []
            for branch in [c.branch, "main", "release/0.1.2"] where seen.insert(branch).inserted {
                let item = NormieMenuItem(branch) { [weak self] in c.branch = branch; self?.store.changed(c); self?.render() }; item.state = c.branch == branch ? .on : .off; menu.addItem(item)
            }
            menu.addItem(.separator()); menu.addItem(NormieMenuItem("New Branch…", enabled: false))
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 14, y: 80), in: view)
    }
    private func showGitMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        for title in ["Push", "Create Pull Request…", "Discard All Changes…"] { menu.addItem(NormieMenuItem(title, enabled: false)) }
        menu.popUp(positioning: nil, at: CGPoint(x: 14, y: 80), in: view)
    }
    @discardableResult func commit() -> Bool {
        guard let c, let review, let input = commitField else { return false }
        let message = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        guard !c.gitBusy, review.isCurrent(c) else { notice("Changes have changed. Review the current diff before committing."); return false }
        if let commit = actions.commit { commit(c, message, review) }
        else if !store.usesLiveCore {
            c.lastCommit = Commit(message: message, hash: "prototype", at: .now); c.changes = []; store.changed(c); notice("Committed changes (prototype)")
        } else { return false }
        commitOpen = false; render(animated:.snappy25); return true
    }
    @discardableResult func beginCommit() -> Bool {
        guard let c, !c.changes.isEmpty, !c.gitBusy, !store.usesLiveCore || (actions.commit != nil && c.gitDiffHash != nil) else { return false }
        review = NormieGitReview(c); commitOpen = true; render(animated:.snappy20); return true
    }
    @objc private func commitFromField(_ sender: Any?) { _ = commit() }
    /// Host can attach this to a reviewed-file Revert action; the same stale-review guard applies.
    @discardableResult func revertReviewedChanges() -> Bool {
        guard let c, let review, review.isCurrent(c), !c.gitBusy, let revert = actions.revert else { return false }
        revert(c, review); return true
    }
    #if NORMIE_SELFTEST
    var verificationCommitField: NormieField? { commitField }
    #endif
}

/// Keep the point-size and monochrome configuration together; a second configuration can reset the font size.
@MainActor final class NormieInspectorSymbol: NormieView {
    let name: String, pointSize: CGFloat
    let tint: NSColor
    private let source: NSImage?
    var imageSize: CGSize { source?.size ?? CGSize(width:pointSize,height:pointSize) }
    init(name: String, size: CGFloat, tint: NSColor) {
        self.name = name; pointSize = size; self.tint = tint
        let configuration = NSImage.SymbolConfiguration(pointSize:size,weight:name.hasPrefix("chevron") ? .semibold:.regular).applying(.preferringMonochrome())
        source = NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(configuration)
        super.init(frame:.zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let source else { return }
        let color = tint
        let colored = NSImage(size:source.size,flipped:false) { rect in
            source.draw(in:rect); color.setFill(); rect.fill(using:.sourceIn); return true
        }
        colored.draw(in:CGRect(x:bounds.midX-source.size.width/2,y:bounds.midY-source.size.height/2,width:source.size.width,height:source.size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
}

/// Keep a full-row hit target while reserving a separate trailing area for the branch chevron.
@MainActor final class NormieInspectorBranchButton: NormieButton {
    private var branch = ""
    let chevron = NormieInspectorSymbol(name:"chevron.down",size:8,tint:NativePalette.secondaryLabel)
    private let icon = NormieInspectorSymbol(name:"arrow.triangle.branch",size:12,tint:NativePalette.secondaryLabel)
    private let branchFont = NSFont.monospacedSystemFont(ofSize:12,weight:.regular)
    var titleRect: CGRect { CGRect(x:24,y:1,width:max(0,chevron.frame.minX-3-24),height:16) }
    override init(frame:NSRect) { super.init(frame:frame);addSubview(icon);addSubview(chevron) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(_ branch:String) {
        self.branch=branch;title="";setAccessibilityLabel("Branch: "+branch);needsLayout=true;needsDisplay=true
    }
    override func layout() {
        super.layout();icon.frame=CGRect(x:0,y:1,width:16,height:16)
        let natural=ceil((branch as NSString).size(withAttributes:[.font:branchFont]).width)
        chevron.frame=CGRect(x:min(bounds.maxX-chevron.imageSize.width,24+natural+3),y:bounds.midY-chevron.imageSize.height/2,width:chevron.imageSize.width,height:chevron.imageSize.height)
    }
    override func draw(_ dirtyRect:NSRect) {
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        (branch as NSString).draw(in:titleRect,withAttributes:[.font:branchFont,.foregroundColor:NativePalette.label,.paragraphStyle:paragraph])
    }
}

/// The product's Spacer pins the diff summary to the row's trailing edge.
@MainActor final class NormieInspectorChangesButton: NormieButton {
    private var count = 0, added = 0, removed = 0
    private var expanded = false
    private let icon = NormieInspectorSymbol(name:"doc.text",size:12,tint:NativePalette.secondaryLabel)
    private var chevron: NormieInspectorSymbol?
    var trailingRect: CGRect {
        let font = NSFont.monospacedDigitSystemFont(ofSize:12,weight:.regular)
        func width(_ value:String)->CGFloat {ceil((value as NSString).size(withAttributes:[.font:font]).width)}
        let width = count == 0 ? width("None"):width("+\(added)")+8+width("−\(removed)")+6+9
        return CGRect(x:max(24,bounds.width-width),y:1,width:width,height:16)
    }
    override init(frame: NSRect) { super.init(frame:frame); addSubview(icon) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(count: Int, added: Int, removed: Int, expanded: Bool) {
        self.count = count; self.added = added; self.removed = removed; self.expanded = expanded; title = "Changes"
        chevron?.removeFromSuperview(); chevron = nil
        if count > 0 {
            let view = NormieInspectorSymbol(name:expanded ? "chevron.down":"chevron.right",size:9,tint:NativePalette.secondaryLabel)
            chevron = view; addSubview(view)
        }
        setAccessibilityValue(count == 0 ? "None":"\(added) lines added, \(removed) removed"); needsDisplay = true; needsLayout = true
    }
    override func layout() {
        super.layout(); icon.frame = CGRect(x:0,y:1,width:16,height:16)
        chevron?.frame = CGRect(x:bounds.width-9,y:1,width:9,height:16)
    }
    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize:12,weight:.regular), alpha:CGFloat = isEnabled ? 1:0.5
        func draw(_ value:String,_ rect:CGRect,_ color:NSColor) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (value as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:color.withAlphaComponent(alpha),.paragraphStyle:paragraph])
        }
        let nameWidth = ceil(("Changes" as NSString).size(withAttributes:[.font:font]).width)
        draw("Changes",CGRect(x:24,y:1,width:nameWidth,height:16),NativePalette.label)
        if count > 0 {
            draw("\(count) file\(count == 1 ? "":"s")",CGRect(x:24+nameWidth+8,y:1,width:max(0,trailingRect.minX-6-(24+nameWidth+8)),height:16),NativePalette.tertiaryLabel)
            let plus = "+\(added)", plusWidth = ceil((plus as NSString).size(withAttributes:[.font:font]).width)
            draw(plus,CGRect(x:trailingRect.minX,y:1,width:plusWidth,height:16),.systemGreen)
            let minus = "−\(removed)", minusWidth = ceil((minus as NSString).size(withAttributes:[.font:font]).width)
            draw(minus,CGRect(x:trailingRect.minX+plusWidth+8,y:1,width:minusWidth,height:16),.systemRed)
        } else { draw("None",trailingRect,NativePalette.tertiaryLabel) }
    }
}

/// StatusInspector reuses the product's two-line SubAgentList row and its 26 pt face.
@MainActor private final class NormieInspectorSubAgentButton: NormieButton {
    private var face = "", task = "", done = false
    private let progress = NormieSidebarSpinner()
    private let mark = NormieSidebarSymbol(), chevron = NormieSidebarSymbol()
    override init(frame: NSRect) {
        super.init(frame: frame)
        progress.style = .spinning; progress.controlSize = .small
        mark.symbol = "checkmark.circle.fill"; mark.tint = .systemGreen
        chevron.symbol = "chevron.right"; chevron.pointSize = 10; chevron.tint = NativePalette.secondaryLabel
        for child in [progress,mark,chevron] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(_ satellite: Satellite, index: Int) {
        title = "Sub-agent \(index+1)"; face = satellite.face; done = satellite.done
        task = satellite.title ?? (satellite.threadID != nil ? "Sub-agent":SheetSubAgentCopy.task(index))
        setAccessibilityLabel(title+", "+task); setAccessibilityValue(done ? "Done":"Running")
        toolTip = "Open \(title)"; progress.isHidden = done; mark.isHidden = !done
        progress.running = !done; needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        progress.frame = CGRect(x:bounds.width-34,y:7,width:16,height:16); mark.frame = progress.frame
        chevron.frame = CGRect(x:bounds.width-12,y:7,width:12,height:16)
    }
    override func draw(_ dirtyRect: NSRect) {
        NativePalette.accent.withAlphaComponent(done ? 0.12:0.28).setFill()
        NSBezierPath(ovalIn:CGRect(x:0,y:2,width:26,height:26)).fill()
        let faceFont = NSFont.systemFont(ofSize:9,weight:.semibold)
        let faceAttributes: [NSAttributedString.Key:Any] = [.font:faceFont,.foregroundColor:NativePalette.label]
        let faceSize = (face as NSString).size(withAttributes:faceAttributes)
        (face as NSString).draw(at:CGPoint(x:13-faceSize.width/2,y:15-faceSize.height/2),withAttributes:faceAttributes)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in:CGRect(x:36,y:0,width:max(1,bounds.width-78),height:15),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NativePalette.label,.paragraphStyle:paragraph])
        (task as NSString).draw(in:CGRect(x:36,y:17,width:max(1,bounds.width-78),height:13),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NativePalette.secondaryLabel,.paragraphStyle:paragraph])
    }
}

@MainActor final class NormieDiffTextView: NSTextView {
    init() {
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer()
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true; drawsBackground = false
        textContainerInset = .zero; container.lineFragmentPadding = 0
        setAccessibilityLabel("File diff"); focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}
