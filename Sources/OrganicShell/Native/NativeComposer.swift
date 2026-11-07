import AppKit
import UniformTypeIdentifiers

/// Retain one instance per conversation. Moving/resizing the host must not replace its NSTextView.
@MainActor final class NativeComposer: NativeInteractionSurface, NSTextViewDelegate {
    // Original integration API remains available.
    let scrollView = NSScrollView()
    let textView = NativeComposerTextView()
    let sendButton = NativePrimaryButton(title: "Send", target: nil, action: nil)
    private(set) lazy var sendPressMotion=NativeComposerPressMotion(sendButton)
    var onSend: ((String) -> Void)?
    var onChange: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    /// A motion adapter can prewarm after semantic content changes; never called once per display frame.
    var onMotionContentsChange:(()->Void)?
    var placeholder: String {
        get { placeholderOverride ?? (layoutMode == .growing ? "Message Codex — "+((sendShortcut ?? (sendsWithReturn ? .return:.commandReturn)) == .commandReturn ? "⌘↩":"↩")+" to send" : (state.running ? "Steer or queue…" : "Message…")) }
        set { placeholderOverride = newValue; updatePresentation() }
    }
    var sendsWithReturn = true {
        didSet { textView.sendsWithReturn = sendsWithReturn; updatePresentation() }
    }
    var isEnabled = true { didSet { updatePresentation() } }
    /// Compatibility flag for attachments owned by an older host. Prefer `attachments` for chips/snapshots.
    var hasAttachments = false { didSet { updatePresentation() } }
    var minimumHeight: CGFloat = 36 { didSet { requestMeasurement() } }
    var maximumHeight: CGFloat = 180 { didSet { requestMeasurement() } }
    private(set) var measuredHeight: CGFloat = 36
    private(set) var naturalEditorHeight:CGFloat = 36
    /// The display-linked host changes real frames continuously, then returns to the backing grid at rest.
    var motionLayoutContinuous=false

    let attachButton = NativeButton(title: "", target: nil, action: nil)
    let accessButton = NativeComposerMenuButton(frame: .zero)
    let modelButton = NativeComposerMenuButton(frame: .zero)
    let stopButton = NativeComposerStopButton(title: "", target: nil, action: nil)
    let dictationButton = NativeButton(title: "", target: nil, action: nil)
    let voiceButton = NativePrimaryButton(title: "", target: nil, action: nil)
    let queueButton = NativeComposerMenuButton(frame: .zero)
    let historyRefreshButton = NativeButton(title: "", target: nil, action: nil)
    let contextButton = NativeButton(title: "", target: nil, action: nil)
    let sendingIndicator = NSProgressIndicator()
    let stoppingIndicator = NSProgressIndicator()
    let voiceTextLabel = NativeLabel(labelWithString: "")
    let voiceWaveform = NativeComposerVoiceWaveform(frame:.zero)
    /// An overlay that captures the native mouseDown forwards its press state here (SendOptions' .22/.55 spring).
    func setSendPressed(_ pressed:Bool){sendPressMotion.setPressed(pressed)}
    let contextRing = NativeComposerContextRing()
    let contextRow = NativeComposerContextRow(frame: .zero)
    var workspace = NativeComposerWorkspace() { didSet { if workspace != oldValue { contextRow.configure(workspace) } } }
    var verificationScale: CGFloat?
    var controlScale: CGFloat { verificationScale ?? window?.backingScaleFactor ?? 2 }
    func controlRect(_ rect: CGRect) -> CGRect {
        if motionLayoutContinuous{return rect}
        let s = controlScale
        let x = (rect.minX*s).rounded()/s, y = (rect.minY*s).rounded()/s
        return CGRect(x: x, y: y, width: (rect.maxX*s).rounded()/s-x, height: (rect.maxY*s).rounded()/s-y)
    }
    var retainedLayoutWidth: CGFloat { initialLayoutWidth ?? bounds.width }
    var hasPendingSubmission: Bool { submissionPending }
    var hasPendingStop: Bool { stopPending }
    let attachmentScrollView = NSScrollView()
    let attachmentContent = NativeFlippedView()
    var attachmentChips: [NativeComposerAttachmentChip] = []

    var onSubmit: ((NativeComposerSubmission) -> Void)?
    var onStopRequest: ((UUID, @escaping @MainActor (NativeComposerCompletion) -> Void) -> Void)? { didSet { updateActionAvailability() } }
    var onRefreshHistory: (() -> Void)? { didSet { updatePresentation() } }
    var onStop: (() -> Void)? { didSet { updateActionAvailability() } }
    var onAttachmentsChange: (([Attachment]) -> Void)?
    var onAccessChange: ((Access) -> Void)?
    var onSettingsChange: ((ModelSettings) -> Void)?
    var onRestoreQueued: ((QueuedMessage) -> Void)?
    var onContext: (() -> Void)?
    var onVoice: (() -> Void)?
    var onEndVoice: (() -> Void)?
    var onSendVoice: ((String) -> Void)?
    var onDictation: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    private(set) var editorFocused = false
    /// A host picker/uploader can return fully prepared Attachment values instead of opening a local panel.
    var onChooseAttachments: (((@escaping @MainActor ([Attachment]) -> Void)) -> Void)?

    var state = NativeComposerState() { didSet { updatePresentation() } }
    var followUpDefault: FollowUp = .steer { didSet { updatePresentation() } }
    var access: Access = .auto { didSet { updatePresentation() } }
    var settings = ModelSettings() { didSet { updatePresentation() } }
    var baseSettings = ModelSettings() { didSet { updatePresentation() } }
    var attachments: [Attachment] = [] {
        didSet { if attachments != oldValue { draftRevision &+= 1 }; updatePresentation() }
    }
    var queued: [QueuedMessage] = [] { didSet { updatePresentation() } }
    var contextSummary = "Context usage has not been reported" { didSet { updatePresentation() } }
    var contextPercent: Int? { didSet { updatePresentation() } }
    var activeTurnID: String?
    var deviceName = "This Mac" { didSet { updatePresentation() } }
    /// FullBar is fixed at the host's height (product default 48 pt); growing is available for other surfaces.
    var layoutMode: NativeComposerLayout = .fullBar { didSet {guard layoutMode != oldValue else{return};finishSegmentTransition();invalidateAccessibilityLease();updatePresentation()} }
    var fixedHeight: CGFloat = 48 { didSet { requestMeasurement() } }
    /// Set by the dock for a Focused / Split segment; nil for a full bar.
    var segmentTransition: NativeComposerSegmentMotion?
    var segment: NativeComposerSegment? { didSet { if segment != oldValue { updatePresentation() } } }
    /// A non-nil width mounts the retained editor as a bar. Normie clears it when mounting its growing composer.
    /// Set the final semantic width before a spring begins; never derive density from animation frames.
    var targetWidth: CGFloat? {
        didSet {
            if targetWidth == oldValue, targetWidth == nil || layoutMode == .fullBar { return }
            if targetWidth != nil, layoutMode != .fullBar { layoutMode = .fullBar }
            else { updatePresentation() }
        }
    }
    var sendShortcut: NativeComposerSendShortcut? {
        didSet { textView.sendShortcut = sendShortcut; updatePresentation() }
    }
    private(set) var identity: String?
    private(set) var lastSubmission: NativeComposerSubmission?
    var onModeHandoffGuardChanged:(()->Void)?
    private(set) var isChoosingAttachments = false {didSet {if oldValue != isChoosingAttachments {onModeHandoffGuardChanged?()}}}
    private var placeholderOverride: String?
    private var measurementPending = false
    private var presentationPending = false
    private var presentationFlushPending = false
    private var initialLayoutWidth: CGFloat?
    private var draftRevision: UInt64 = 0
    private var submittedRevision: UInt64?
    private var submissionPending = false
    private var stopPending = false
    private var pendingStopID: UUID?
    private var batchUpdating = false
    private var presentationDepth=0
    private var presentationDirty=false
    private(set) var presentationUpdateCount=0
    /// Install one host's related policy/callback changes before rebuilding native menus and controls once.
    func configurePresentation(_ body:()->Void) {
        presentationDepth+=1;body();presentationDepth-=1
        if presentationDepth==0,presentationDirty {presentationDirty=false;updatePresentation()}
    }
    private var appearancePending=false
    private(set) var voiceDemo:NativeVoiceDemo?
    private var voiceSubmission:UUID?
    private weak var conversation: Conversation?
    private weak var store: ConversationStore?
    private var observation: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NativeDisplayOptions.appearance
        scrollView.contentView = NativeComposerSegmentClipView(frame:.zero)
        scrollView.drawsBackground = false; scrollView.borderType = .noBorder
        // No scroller, as in the product's bar editor (DockItems.swift:95, scrolls: false): the text still scrolls to
        // the caret inside the fixed bar, but an overlay scroller flashed on every switch that showed the composer.
        scrollView.hasVerticalScroller = false; scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none; scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        textView.delegate = self
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onStop = { [weak self] in self?.requestStop() }
        textView.onAttach = { [weak self] in self?.chooseAttachments() }
        textView.onLayoutChange = { [weak self] in self?.requestMeasurement() }
        textView.onCompositionChange = { [weak self] in self?.compositionChanged();self?.onModeHandoffGuardChanged?() }
        textView.onFocusChange = { [weak self] focused in self?.editorFocused = focused; self?.updateFocusRing(); self?.onFocusChange?(focused) }
        scrollView.documentView = textView
        attachmentScrollView.drawsBackground = false; attachmentScrollView.borderType = .noBorder
        attachmentScrollView.hasHorizontalScroller = true; attachmentScrollView.autohidesScrollers = true
        attachmentScrollView.scrollerStyle = .overlay
        attachmentScrollView.horizontalScrollElasticity = .none; attachmentScrollView.verticalScrollElasticity = .none
        attachmentScrollView.documentView = attachmentContent
        for view in [scrollView, attachmentScrollView, attachButton, accessButton, modelButton, dictationButton,
                     stopButton, sendButton, voiceButton, queueButton, contextButton, historyRefreshButton, sendingIndicator, stoppingIndicator, voiceTextLabel, voiceWaveform, contextRow] as [NSView] { addSubview(view) }
        configureButton(attachButton, symbol: "plus", label: "Attach files", action: #selector(attachPressed))
        configureButton(stopButton, symbol: "stop.fill", label: "Stop", action: #selector(stopPressed))
        configureButton(dictationButton, symbol: "mic", label: "Start Dictation", action: #selector(dictationPressed))
        configureButton(voiceButton, symbol: "waveform", label: "Start Voice Conversation", action: #selector(voicePressed))
        configureButton(historyRefreshButton, symbol: "arrow.clockwise", label: "Refresh history", action: #selector(refreshHistoryPressed))
        configureButton(contextButton, symbol: "circle.dotted", label: "Context", action: #selector(contextPressed))
        let sendCell=NativeComposerSendCell(textCell:sendButton.title);sendCell.motion=sendPressMotion;sendCell.isBordered=false;sendCell.setButtonType(.momentaryPushIn);sendButton.cell=sendCell
        configureButton(sendButton, symbol: "arrow.up", label: "Send", action: #selector(sendPressed))
        for popup in [accessButton, modelButton, queueButton] {
            popup.isBordered = false; popup.font = .systemFont(ofSize: 11); popup.autoenablesItems = false
        }
        for indicator in [sendingIndicator, stoppingIndicator] {
            indicator.style = .spinning; indicator.controlSize = .small; indicator.isDisplayedWhenStopped = false
            indicator.setAccessibilityElement(false)
        }
        contextButton.addSubview(contextRing); contextRing.setAccessibilityElement(false)
        voiceTextLabel.font = .systemFont(ofSize: 13); voiceTextLabel.lineBreakMode = .byTruncatingTail
        voiceTextLabel.setAccessibilityLabel("Voice transcript")
        setAccessibilityElement(false); updatePresentation();applyNativeAppearance()
    }
    convenience init() { self.init(frame: .zero) }
    convenience init(conversation: Conversation, store: ConversationStore? = nil) {
        self.init(); bind(to: conversation, store: store)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidHide(){super.viewDidHide();sendPressMotion.setPressed(false,animated:false)}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if window == nil{sendPressMotion.setPressed(false,animated:false)}}
    isolated deinit {
        if let observation { store?.removeObserver(observation) }
    }

    private var refreshDeferred=false
    private var refreshedCatalog: [ModelCatalog.Model] = []
    private var refreshedAppearance = -1
    private(set) var modelRefreshCount = 0
    private(set) var controlsLayoutCount = 0
    struct MenusValue:Equatable {
        var compact:Bool,growing:Bool,segmented:Bool
        var access:Access,settings:ModelSettings,base:ModelSettings,device:String
        var queued:[QueuedMessage],restorable:[Bool],catalog:[ModelCatalog.Model]
        var appearance:Int,display:Int
    }
    var menusValue:MenusValue?
    private(set) var menusBuildCount=0
    func noteMenusBuild(){menusBuildCount+=1}
    private var controlsLayoutValue: ControlsLayoutValue?
    private struct ControlsLayoutValue: Equatable {
        var size: CGSize, scale: CGFloat, density: CGFloat, growing: Bool, input: String
        var editorViewport: CGSize, attachmentViewport: CGSize, font: NSFont?
        var state: NativeComposerState, access: Access, settings: ModelSettings, base: ModelSettings
        var files: [Attachment], catalog: [ModelCatalog.Model], queued: Int, percent: Int?
        var pendingSend: Bool, pendingStop: Bool, enabled: Bool, legacyFiles: Bool, recovery: Bool, sendVoice: Bool
        var appearance: Int, display: Int, segment: NativeComposerSegment?
    }
    override func nativeAppearanceDidChange(){super.nativeAppearanceDidChange();applyNativeAppearance()}
    private func applyNativeAppearance(){
        guard !isComposing else{appearancePending=true;return};appearancePending=false
        let selected=textView.selectedRanges,font=NSFont.systemFont(ofSize:max(10,13*NativeAppearance.current.textScale))
        let color=NativeAppearance.current.foreground?.withAlphaComponent(0.9) ?? NSColor.textColor
        textView.font=font;textView.textColor=color;textView.insertionPointColor=color
        for button in [attachButton,sendButton,stopButton,voiceButton,dictationButton,contextButton]{button.contentTintColor=NativePalette.secondaryLabel};voiceTextLabel.textColor=NativePalette.label
        textView.typingAttributes=[.font:font,.foregroundColor:color]
        if let storage=textView.textStorage,storage.length>0{storage.addAttributes([.font:font,.foregroundColor:color],range:NSRange(location:0,length:storage.length))}
        textView.selectedRanges=selected;updatePresentation();requestMeasurement();needsLayout=true
    }
    override func presentationVisibilityDidChange(){voiceDemo?.synchronizeClock();guard isPresentationVisible,refreshDeferred else{return};refreshDeferred=false;refresh()}
    /// Opt-in demo owner. Host-provided voice callbacks take precedence and are never replaced.
    @discardableResult func enableVoiceDemo()->Bool{
        if voiceDemo != nil{return true};guard onVoice == nil,onEndVoice == nil,onSendVoice == nil,!state.usesLiveCore else{return false}
        let demo=NativeVoiceDemo(composer:self);voiceDemo=demo
        onVoice={[weak demo] in _ = demo?.start()};onEndVoice={[weak demo] in demo?.end()};onSendVoice={[weak self] heard in _ = self?.submitVoiceDemo(heard)};return true
    }
    func setDemoVoice(_ value:String?){guard !state.usesLiveCore,conversation?.isLiveConversation != true else{return};if state.voice != value{state.voice=value;state.dictating=false;conversation?.voice=value;conversation?.dictating=false;updatePresentation();if value == nil{voiceDemo?.synchronizeClock()};if let conversation{store?.changed(conversation)}}}
    @discardableResult private func submitVoiceDemo(_ heard:String)->Bool{
        guard !state.usesLiveCore,state.online,!isComposing,!state.loading,!state.sending,!state.stopping,!state.outcomeUnknown,!submissionPending,!heard.isEmpty,onSubmit != nil || onSend != nil else{return false}
        let request=NativeComposerSubmission(id:UUID(),identity:identity,action:effectiveAction,text:heard,attachments:[],settings:settings,access:access,waitingForTurnID:activeTurnID)
        lastSubmission=request;voiceSubmission=request.id
        if let onSubmit{submissionPending=true;submittedRevision=draftRevision;updatePresentation();onSubmit(request)}else{onSend?(heard);voiceSubmission=nil;setDemoVoice(nil)};return true
    }
    var text: String { textView.string }
    var isComposing: Bool { textView.hasMarkedText() || textView.isHandlingCompositionEvent }
    var effectiveAction: NativeComposerAction {
        state.running ? (followUpDefault == .steer ? .steer : .queue) : .send
    }
    var canSend: Bool {
        isEnabled && !isComposing && state.online && !state.loading && !state.sending && !state.stopping &&
        !state.outcomeUnknown && !submissionPending && !stopPending && state.voice == nil &&
        (hasAttachments || !attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var canStop: Bool {
        isEnabled && !isComposing && state.running && !state.stopping && !stopPending && (onStopRequest != nil || onStop != nil)
    }
    var canEditOptions: Bool { isEnabled && !isComposing && state.online && !state.loading && !isChoosingAttachments }
    var canChangeAttachments: Bool { isEnabled && !isComposing && !state.loading && !isChoosingAttachments && state.voice == nil }

    @discardableResult func setText(_ text: String, clearUndo: Bool = false) -> Bool {
        guard !isComposing else { return false }
        if textView.string != text {
            let old = textView.selectedRange()
            textView.string = text; conversation?.draft = text; draftRevision &+= 1
            let length = (text as NSString).length, location = min(old.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(old.length, length - location)))
            textView.needsDisplay = true
        }
        if clearUndo { textView.undoManager?.removeAllActions() }
        updatePresentation(); requestMeasurement(); return true
    }
    /// Local draft only, with the existing UndoManager and IME gate. Runtime Edit/Fork is a separate host callback.
    @discardableResult func stageUserMessageDraft(_ item:TranscriptItem)->Bool {
        guard item.rowKind == .user,!isComposing,!hasPendingSubmission,!state.loading else{return false}
        replaceDraftUndoably(item.text);conversation?.draft=text;updatePresentation();requestMeasurement();return true
    }
    func focus() { window?.makeFirstResponder(textView) }
    func useAutomaticPlaceholder() { placeholderOverride = nil; updatePresentation() }
    func textDidChange(_ notification: Notification) {
        draftRevision &+= 1
        conversation?.draft = text
        updatePresentation(); requestMeasurement(); onChange?(text)
    }

    /// Both the keyboard and the native button use this gate. M2's chooser calls it with an override.
    /// A Tools delivery passes its own UUID, so its receipt finishes the Tools operation too (TOOLS-M8 Send).
    @discardableResult func submit(followUp: FollowUp? = nil, id: UUID = UUID()) -> Bool {
        guard canSend else { return false }
        let action: NativeComposerAction = state.running ? ((followUp ?? followUpDefault) == .steer ? .steer : .queue) : .send
        let request = NativeComposerSubmission(id: id, identity: identity, action: action, text: text,
            attachments: attachments, settings: settings, access: access, waitingForTurnID: activeTurnID)
        lastSubmission = request
        if let onSubmit {
            submittedRevision = draftRevision; submissionPending = true; updatePresentation(); onSubmit(request)
        } else if let onSend { onSend(request.text) }
        else { return false }
        return true
    }
    /// Only a matching acknowledgement may finish a pending request. Failed/uncertain sends keep the draft.
    @discardableResult func completeSubmission(_ id: UUID, outcome: NativeComposerCompletion) -> Bool {
        guard lastSubmission?.id == id, submissionPending else { return false }
        // Never clear, replace, or replay a draft while the input method owns it.
        submissionPending = false; state.sending = false; conversation?.sending = false
        let wasVoice=voiceSubmission == id;voiceSubmission=nil
        switch outcome {
        case .accepted:
            state.operationError = nil; state.outcomeUnknown = false
            if wasVoice{setDemoVoice(nil)}
            if !wasVoice,submittedRevision == draftRevision, !isComposing {
                replaceDraftUndoably(""); attachments = []; publishAttachments()
            }
        case .failed(let message): state.operationError = message
        case .outcomeUnknown(let message): state.operationError = message; state.outcomeUnknown = true
        }
        conversation?.operationError = state.operationError; conversation?.sendOutcomeUnknown = state.outcomeUnknown
        conversation?.draft = text; conversation?.attachments = attachments
        submittedRevision = nil; updatePresentation(); return true
    }
    @discardableResult func requestStop() -> Bool {
        guard canStop else { return false }
        let id = UUID(); pendingStopID = id; stopPending = true; updatePresentation()
        if let onStopRequest {
            onStopRequest(id) { [weak self] outcome in _ = self?.completeStopRequest(id, outcome: outcome) }
        } else { onStop?() }
        return true
    }
    /// Only the matching request may clear pending. Accepted means interrupt acknowledged, not turn completed.
    @discardableResult func completeStopRequest(_ id: UUID, outcome: NativeComposerCompletion) -> Bool {
        guard pendingStopID == id else { return false }
        pendingStopID = nil; stopPending = false
        switch outcome {
        case .accepted: break
        case .failed(let message), .outcomeUnknown(let message):
            state.operationError = message; conversation?.operationError = message
            // An unknown interrupt is not an unknown send. Backend running/stopping remains authoritative.
        }
        updatePresentation(); return true
    }
    /// Legacy acknowledgement. Prefer the UUID overload for asynchronous stop handlers.
    func completeStopRequest() { pendingStopID = nil; stopPending = false; updatePresentation() }
    var showsHistoryRecovery: Bool {
        state.usesLiveCore && (state.outcomeUnknown || state.operationError?.isEmpty == false)
    }
    var canRefreshHistory: Bool {
        showsHistoryRecovery && isEnabled && !isComposing && !state.loading && onRefreshHistory != nil
    }
    @discardableResult func requestHistoryRefresh() -> Bool {
        guard canRefreshHistory else { return false }
        onRefreshHistory?(); return true
    }
    @objc private func refreshHistoryPressed() { _ = requestHistoryRefresh() }

    /// ComposerDock's focus ring (Normie only), just outside the dock: see NativeComposerFocusRing. The composer clips
    /// its subviews, so the host that mounts it puts the ring 1 pt around it; this only shows and hides it.
    let focusRing = NativeComposerFocusRing(frame: .zero)
    private func updateFocusRing() { focusRing.isHidden = !(layoutMode == .growing && editorFocused && !isHidden) }
    override func layout() {
        super.layout()
        guard presentationDepth==0 else{presentationDirty=true;return}
        updateFocusRing()
        // The segment clock owns these live frames until its finite transition reaches the endpoint.
        if segmentTransition?.after.isEmpty == false { return }
        guard !isComposing else { presentationPending = true; return }
        if initialLayoutWidth == nil, bounds.width > 0 { initialLayoutWidth = bounds.width }
        let value = ControlsLayoutValue(size: bounds.size, scale: controlScale, density: densityWidth, growing: layoutMode == .growing,
            input: text, editorViewport: scrollView.contentSize, attachmentViewport: attachmentScrollView.contentSize, font: textView.font,
            state: state, access: access, settings: settings, base: baseSettings, files: attachments,
            catalog: ModelCatalog.models, queued: queued.count, percent: contextPercent, pendingSend: submissionPending,
            pendingStop: stopPending, enabled: isEnabled, legacyFiles: hasAttachments, recovery: showsHistoryRecovery,
            sendVoice: onSendVoice != nil, appearance: NativeAppearance.revision, display: NativeDisplayOptions.shared.revision,
            segment: segment)
        guard controlsLayoutValue != value else { return }
        controlsLayoutValue = value; controlsLayoutCount += 1
        layoutControls()
    }
    func measureNow() {
        guard !isComposing else { presentationPending = true; return }
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let line = manager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        updateEditorInset()
        let desired = ceil(max(line, manager.usedRect(for: container).height + manager.extraLineFragmentRect.height)) + textView.textContainerInset.height * 2
        let viewport = scrollView.contentSize.height
        textView.setFrameSize(CGSize(width: max(1, scrollView.contentSize.width), height: max(viewport, desired)))
        // NSClipView can leave a negative document origin after its first resize from zero.
        // A composer document is top anchored; preserve scrolling in clip bounds, never in its frame.
        if textView.frame.origin != .zero { textView.setFrameOrigin(.zero) }
        let origin = scrollView.contentView.bounds.origin
        let constrained = CGPoint(x: 0, y: min(max(0, origin.y), max(0, textView.frame.height - viewport)))
        if origin != constrained {
            scrollView.contentView.scroll(to: constrained); scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let input = max(36, ceil(max(line, manager.usedRect(for: container).height)) + 12)
        naturalEditorHeight=input
        let growing = 84 + input + (attachments.isEmpty || state.voice != nil ? 0:36)
        let height = layoutMode == .fullBar ? max(1, fixedHeight) : min(max(120, maximumHeight), max(120, minimumHeight, growing))
        if measuredHeight != height { measuredHeight = height; onHeightChange?(height) }
    }
    /// Pure endpoint query: terminal preparation must not lay out a FUTURE editor viewport or clamp its scroll.
    /// TextKit updates naturalEditorHeight only when the actual native editor is measured.
    func normieLayoutHeight(detailHeight:CGFloat)->CGFloat {
        let attached:CGFloat=attachments.isEmpty || state.voice != nil ? 0:36
        return min(84+min(280,max(36,detailHeight*0.4))+(attachments.isEmpty ? 0:36),max(120,minimumHeight,84+naturalEditorHeight+attached))
    }
    /// Product Normie ComposerDock: 84 pt chrome + a 36...min(280, 40% detail) editor.
    /// Returns a settled height in two bounded TextKit passes, without replacing/clearing the editor.
    @discardableResult func prepareNormieLayout(width: CGFloat, detailHeight: CGFloat) -> CGFloat {
        targetWidth = nil
        if layoutMode != .growing { layoutMode = .growing }
        let cap = 84 + min(280, max(36, detailHeight * 0.4)) + (attachments.isEmpty ? 0:36)
        if maximumHeight != cap { maximumHeight = cap }
        let width = max(1, width)
        for _ in 0..<2 {
            let size = CGSize(width: width, height: max(120, measuredHeight))
            if frame.size != size { setFrameSize(size) }
            needsLayout = true; layoutSubtreeIfNeeded(); measureNow()
        }
        if frame.height != measuredHeight { setFrameSize(CGSize(width: width,height: measuredHeight)); needsLayout = true; layoutSubtreeIfNeeded() }
        return measuredHeight
    }
    /// ComposerEditor verticalInset:6 in Normie; DockBarMetrics centres one line in a full bar.
    func updateEditorInset() {
        guard layoutMode == .fullBar else {
            if textView.textContainerInset.height != 6 { textView.textContainerInset.height = 6 }
            return
        }
        let line = textView.layoutManager?.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13)) ?? 16
        // DockBarMetrics.editorInset: the inset is for one line and does not change while typing.
        // A long draft scrolls inside this fixed viewport, exactly like the product's retained editor.
        let inset = max(4, floor((scrollView.frame.height-line)/2))
        if textView.textContainerInset.height != inset { textView.textContainerInset.height = inset }
    }
    private func requestMeasurement() {
        guard !measurementPending else { return }
        measurementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementPending = false; self.measureNow()
        }
    }
    private func compositionChanged() {
        // Buttons cannot steal the first responder from an active input method.
        updateActionAvailability()
        guard !isComposing else { presentationPending = true; return }
        guard !presentationFlushPending else { return }
        presentationFlushPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationFlushPending = false
            guard !self.isComposing else { return }
            if self.appearancePending{self.applyNativeAppearance()}
            self.updatePresentation(); self.needsLayout = true; self.layoutSubtreeIfNeeded(); self.requestMeasurement()
        }
    }
    private func configureButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.target = self; button.action = action; button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isBordered = false; button.bezelStyle = .circular
        button.setAccessibilityLabel(label); button.toolTip = label
    }
    private func updateActionAvailability() {
        historyRefreshButton.isEnabled = canRefreshHistory
        sendButton.isEnabled = canSend
        stopButton.isEnabled = canStop
        attachButton.isEnabled = canChangeAttachments
        for control in [accessButton, modelButton] { control.isEnabled = canEditOptions && state.voice == nil }
        for chip in attachmentChips { chip.removeButton.isEnabled = canChangeAttachments }
        queueButton.isEnabled = isEnabled && !isComposing && !state.loading
        contextButton.isEnabled = !isComposing
        voiceButton.isEnabled = isEnabled && identity != nil && !isComposing && state.online && !state.usesLiveCore && !state.loading && !state.sending && !state.outcomeUnknown && !submissionPending
        dictationButton.isEnabled = canEditOptions && !state.usesLiveCore && state.voice == nil
    }
    private func updatePresentation() {
        guard !batchUpdating,presentationDepth==0 else {if presentationDepth>0 {presentationDirty=true};return}
        presentationUpdateCount+=1
        defer{onMotionContentsChange?()}
        if !state.running && !state.stopping { stopPending = false; pendingStopID = nil }
        updateActionAvailability()
        guard !isComposing else { presentationPending = true; return }
        presentationPending = false
        textView.isEditable = isEnabled
        textView.placeholder = placeholder; textView.needsDisplay = true
        let recovery = state.operationError ?? "The send outcome is unknown. Refresh history before sending again."
        historyRefreshButton.toolTip = onRefreshHistory == nil ? recovery+" Refresh history is not connected by this host." : recovery
        historyRefreshButton.setAccessibilityHelp(historyRefreshButton.toolTip)
        updateMenus()
        updateChips()
        updateAccessibility()
        sendButton.setAccessibilityLabel(effectiveAction.rawValue)
        sendButton.toolTip = state.outcomeUnknown ? "Send outcome unknown; check history before sending again." : state.operationError ?? (state.sending || submissionPending ? "Sending…" : effectiveAction.rawValue)
        stopButton.toolTip = state.stopping || stopPending ? "Stop requested; waiting for backend confirmation." : "Stop Response (⌘.)"
        dictationButton.image = NSImage(systemSymbolName: state.dictating ? "mic.fill" : "mic", accessibilityDescription: nil)
        dictationButton.contentTintColor = state.dictating ? .systemRed : nil
        dictationButton.setAccessibilityLabel(state.dictating ? "Stop Dictation" : "Start Dictation")
        dictationButton.toolTip = state.usesLiveCore ? "Use macOS Dictation with its keyboard shortcut." : dictationButton.accessibilityLabel()
        voiceButton.image = NSImage(systemSymbolName: state.voice == nil ? "waveform" : "xmark", accessibilityDescription: nil)
        voiceButton.drawsAccentCircle = state.voice == nil
        voiceButton.setAccessibilityLabel(state.voice == nil ? "Start Voice Conversation" : "End Voice Conversation")
        voiceButton.toolTip = state.usesLiveCore ? "Voice is paused; audio capture is not connected." : voiceButton.accessibilityLabel()
        sendingIndicator.isHidden = !(state.sending || submissionPending)
        if sendingIndicator.isHidden { sendingIndicator.stopAnimation(nil) } else { sendingIndicator.startAnimation(nil) }
        stoppingIndicator.isHidden = !(state.stopping || stopPending)
        if stoppingIndicator.isHidden { stoppingIndicator.stopAnimation(nil) } else { stoppingIndicator.startAnimation(nil) }
        updateActionAvailability(); needsLayout = true; requestMeasurement()
    }
    private func updateAccessibility() {
        let shortcut = sendShortcut ?? (sendsWithReturn ? .return : .commandReturn)
        textView.setAccessibilityIdentifier("composer." + (identity ?? "standalone") + ".draft")
        textView.setAccessibilityLabel("Message draft")
        textView.setAccessibilityHelp(placeholder + (shortcut == .return ? ". Return to send; Command Return for a new line." : shortcut == .commandReturn ? ". Command Return to send; Return for a new line." : ". Use the configured send shortcut."))
        textView.setAccessibilityPlaceholderValue(placeholder)
        let prefix = "composer." + (identity ?? "standalone") + "."
        sendButton.setAccessibilityIdentifier(prefix + "send")
        for (control, suffix) in [(attachButton, "attach"), (accessButton, "permissions"), (modelButton, "model"),
                                  (stopButton, "stop"), (queueButton, "queue"), (contextButton, "context"),
                                  (voiceButton, "voice"), (dictationButton, "dictation")] {
            control.setAccessibilityIdentifier(prefix + suffix)
        }
        sendButton.setAccessibilityHelp(state.outcomeUnknown ? "Send outcome unknown. Check history before retrying." : state.operationError ?? effectiveAction.rawValue)
        stopButton.setAccessibilityHelp(state.stopping || stopPending ? "Waiting for backend confirmation" : "Stop Response. Command period.")
        contextButton.setAccessibilityLabel(contextSummary)
        contextButton.toolTip = contextSummary
    }
    private func replaceDraftUndoably(_ value: String) {
        guard !isComposing else { return }
        textView.replaceWholeDraftUndoably(value)
    }
    private func publishAttachments() { conversation?.attachments = attachments; onAttachmentsChange?(attachments) }

    @objc private func sendPressed() {
        if state.voice != nil { sendVoice() } else { submit() }
    }
    @objc private func stopPressed() { requestStop() }
    @objc private func attachPressed() { chooseAttachments() }
    @objc private func contextPressed() { if !isComposing { onContext?() } }
    @objc private func dictationPressed() {
        guard dictationButton.isEnabled else { return }
        if let onDictation { onDictation() }
        else { state.dictating.toggle(); conversation?.dictating = state.dictating }
    }
    @objc private func voicePressed() {
        guard voiceButton.isEnabled else { return }
        if state.voice != nil {
            if let onEndVoice { onEndVoice() } else { state.voice = nil; conversation?.voice = nil }
        } else if let onVoice { onVoice() }
        else { state.voice = ""; conversation?.voice = "" }
    }
    @discardableResult func sendVoice() -> Bool {
        guard !isComposing, isEnabled, state.online, !state.usesLiveCore, !state.loading, !state.sending,
              !state.outcomeUnknown, !submissionPending, let heard = state.voice, !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let onSendVoice else { return false }
        onSendVoice(heard); return true
    }

    /// Does not present anything until explicitly invoked by the attach control/shortcut or host.
    func chooseAttachments() {
        guard canChangeAttachments else { return }
        isChoosingAttachments = true; updateActionAvailability()
        let completion: @MainActor ([Attachment]) -> Void = { [weak self] values in
            guard let self else { return }
            self.isChoosingAttachments = false
            self.attachments.append(contentsOf: values.filter { value in !self.attachments.contains { $0.id == value.id } })
            if !values.isEmpty { self.publishAttachments() }
            self.updatePresentation()
        }
        if let onChooseAttachments { onChooseAttachments(completion); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { result in
            completion(result == .OK ? panel.urls.map { url in
                let type = UTType(filenameExtension: url.pathExtension)
                return Attachment(id: UUID().uuidString, name: url.lastPathComponent,
                    symbol: type?.conforms(to: .image) == true ? "photo" : "doc", url: url, mimeType: type?.preferredMIMEType)
            } : [])
        }
    }
    @discardableResult func removeAttachment(id: String) -> Bool {
        guard canChangeAttachments, attachments.contains(where: { $0.id == id }) else { return false }
        attachments.removeAll { $0.id == id }; publishAttachments(); return true
    }

    /// A composer may only bind to its own identity. Use NativeComposerSessions to switch conversations.
    @discardableResult func bind(to c: Conversation, store: ConversationStore? = nil) -> Bool {
        guard identity == nil || identity == c.id else { return false }
        if let observation { self.store?.removeObserver(observation) }
        if identity != c.id{invalidateAccessibilityLease()}
        identity = c.id; conversation = c; self.store = store
        observation = store?.observe { [weak self] updated in
            guard let self, self.identity == updated.id else { return };if !self.isPresentationVisible{self.refreshDeferred=true}else{self.refresh()}
        }
        refresh(); return true
    }
    private var modeContentEpochFrozen=false
    func setModeContentEpochFrozen(_ frozen:Bool) {
        guard frozen != modeContentEpochFrozen else {return}
        modeContentEpochFrozen=frozen;modeContentInputBlocked=frozen
        if !frozen {refresh()}
    }
    func refresh() {
        if modeContentEpochFrozen {refreshDeferred=true;return}
        guard let c = conversation else { return }
        let nextState = NativeComposerState(running: c.running, sending: c.sending, stopping: c.stopping, loading: c.loading,
            outcomeUnknown: c.sendOutcomeUnknown, online: !(store?.isOffline(c) ?? false), usesLiveCore: store?.usesLiveCore ?? c.isLiveConversation,
            operationError: c.operationError, voice: c.voice, dictating: c.dictating)
        let nextDevice = store?.device(c.deviceID)?.name ?? "This Mac"
        let projectValue = store?.project(c.projectID)
        let project = projectValue?.name
        let location = [project, c.branch.isEmpty ? nil : c.branch, nextDevice].compactMap { $0 }.joined(separator: " · ")
        let nextPercent = c.contextUsageReported || (!c.isLiveConversation && c.backendThreadID == nil) ? c.contextPercent : nil
        let nextSummary = location + " · " + c.contextDescription + " · " + c.status
        let nextFollowUp = store?.followUpDefault ?? followUpDefault
        let phrase = TranscriptPresentation.activityPhrase(items: c.items, running: c.running, sending: c.sending, stopping: c.stopping, waiting: !c.approvals.isEmpty) ?? ""
        let n = c.satellites.filter { !$0.done }.count
        var nextWorkspace = NativeComposerWorkspace(project: project ?? "No Project", projectSymbol: projectValue?.colorHex == nil ? "folder":"folder.fill", projectTint: projectValue?.colorHex, branch: c.branch, device: nextDevice, deviceSymbol: store?.device(c.deviceID)?.symbol ?? "laptopcomputer", status: phrase.isEmpty ? "":phrase+(n == 0 ? "":" · \(n) sub-agent"+(n == 1 ? "":"s")), statusMark: c.approvals.isEmpty ? "":"hand.raised.fill")
        if phrase.isEmpty,c.error == .stopped,let reason=c.items.last(where:{$0.rowKind == .notice(.error)})?.text {nextWorkspace.status=reason;nextWorkspace.statusMark="exclamationmark.triangle.fill"}
        if !nextState.online { nextWorkspace.status = nextDevice+" is offline."; nextWorkspace.statusMark = "exclamationmark.triangle.fill" }
        // Text deltas do not change menus, attachment chips or input state. Preserve synchronous model updates,
        // but don't recreate those controls for every token (or twice through a detail.show and our own observer).
        if !isComposing, !submissionPending, text == c.draft, state == nextState, access == c.access,
           settings == c.next, baseSettings == c.settings, attachments == c.attachments, queued == c.queued,
           activeTurnID == c.activeTurnID, followUpDefault == nextFollowUp, deviceName == nextDevice,
           contextPercent == nextPercent, contextSummary == nextSummary, workspace == nextWorkspace, refreshedCatalog == ModelCatalog.models,
           refreshedAppearance == NativeAppearance.revision { return }
        modelRefreshCount += 1; refreshedCatalog = ModelCatalog.models; refreshedAppearance = NativeAppearance.revision
        batchUpdating = true
        // A marked draft is already being published to c. Never replay an older model copy after composition.
        if !isComposing && !submissionPending { _ = setText(c.draft) }
        else { c.draft = text }
        state = nextState
        access = c.access; settings = c.next; baseSettings = c.settings
        if !submissionPending { attachments = c.attachments }
        queued = c.queued
        activeTurnID = c.activeTurnID; followUpDefault = nextFollowUp
        deviceName = nextDevice; contextPercent = nextPercent; contextSummary = nextSummary; workspace = nextWorkspace
        batchUpdating = false; updatePresentation()
    }

    // UI/layout implementation lives in NativeComposerControls.swift.
    func setAccess(_ value: Access) {
        guard canEditOptions else { return }; access = value; conversation?.access = value; onAccessChange?(value)
    }
    func setSettings(_ value: ModelSettings) {
        guard canEditOptions else { return }; settings = value; conversation?.next = value; onSettingsChange?(value)
    }
    func canRestoreQueued(id: String) -> Bool {
        isEnabled && !isComposing && !state.loading && state.voice == nil && !state.sending && !state.outcomeUnknown && !submissionPending && text.isEmpty && attachments.isEmpty &&
        queued.contains { $0.id == id && ($0.deliveryError != nil || $0.waitingForTurnID == nil) }
    }
    @discardableResult func restoreQueued(id: String) -> Bool {
        guard canRestoreQueued(id: id), let message = queued.first(where: { $0.id == id }) else { return false }
        if let onRestoreQueued { onRestoreQueued(message); return true }
        replaceDraftUndoably(message.text); attachments = message.attachments; settings = message.settings; access = message.access
        queued.removeAll { $0.id == id }
        for i in queued.indices where queued[i].deliveryError == nil {
            queued[i].deliveryError = "An earlier queued message was restored. Restore this message when the composer is empty."
        }
        conversation?.queued = queued; conversation?.next = settings; conversation?.access = access
        publishAttachments(); onSettingsChange?(settings); onAccessChange?(access); return true
    }
}

@MainActor final class NativeComposerTextView: NSTextView {
    private let backingStorage: NSTextStorage
    private let sessionUndo = UndoManager()
    private var compositionEventDepth = 0
    var isHandlingCompositionEvent: Bool { compositionEventDepth > 0 }
    override var undoManager: UndoManager? { sessionUndo }
    var onSubmit: (() -> Void)?, onCancel: (() -> Void)?, onLayoutChange: (() -> Void)?
    var onCompositionChange: (() -> Void)?, onStop: (() -> Void)?, onAttach: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var placeholder = "Message…"
    var sendsWithReturn = true
    var sendShortcut: NativeComposerSendShortcut?

    init() {
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer()
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        backingStorage = storage
        super.init(frame: .zero, textContainer: container)
        isRichText = false; importsGraphics = false; allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        font = .systemFont(ofSize: 13); textColor = NativePalette.label
        insertionPointColor = NativePalette.label; drawsBackground = false; focusRingType = .none
        textContainerInset = CGSize(width: 0, height: 8)
        textContainer?.lineFragmentPadding = 0; textContainer?.widthTracksTextView = true
        minSize = .zero; maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true; isHorizontallyResizable = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setAccessibilityValue(_ value: Any?) {
        guard !hasMarkedText(), !isHandlingCompositionEvent, isEditable,NativeInteractionSurface.permits(self) else { return }
        guard let value = value as? String else { return }
        replaceWholeDraftUndoably(value)
    }
    func replaceWholeDraftUndoably(_ value: String) {
        guard !hasMarkedText(), !isHandlingCompositionEvent else { return }
        let undo = undoManager
        let ownsGroup = undo?.groupingLevel == 0
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        breakUndoCoalescing()
        insertText(value, replacementRange: NSRange(location: 0, length: (string as NSString).length))
        breakUndoCoalescing()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { onLayoutChange?() }
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); if result { onFocusChange?(true) }; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); if result { onFocusChange?(false) }; return result
    }
    override func keyDown(with event: NSEvent) {
        // The entire committing event belongs to the input method, including its reentrant commands.
        if hasMarkedText() {
            compositionEventDepth += 1
            defer { compositionEventDepth -= 1; onCompositionChange?() }
            super.keyDown(with: event); return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 47 && modifiers == .command { onStop?(); return }
        if event.keyCode == 0 && modifiers == [.command, .shift] { onAttach?(); return }
        let shortcut = sendShortcut ?? (sendsWithReturn ? .return : .commandReturn)
        if shortcut.matches(event) { onSubmit?(); return }
        if shortcut == .return && (event.keyCode == 36 || event.keyCode == 76) && modifiers == .command {
            insertText("\n", replacementRange: selectedRange()); return
        }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText(), !isHandlingCompositionEvent, let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        compositionEventDepth += 1
        defer { compositionEventDepth -= 1; onCompositionChange?() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        compositionEventDepth += 1
        defer { compositionEventDepth -= 1; onCompositionChange?() }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func unmarkText() {
        compositionEventDepth += 1
        defer { compositionEventDepth -= 1; onCompositionChange?() }
        super.unmarkText()
    }
}

/// ComposerDock's `.stroke(keyboardFocusIndicatorColor, lineWidth: 1.5)` on the dock's 20 pt shape. Only its outer half
/// shows on the product (the dock's glass covers the inner half), and at about half strength while the window isn't
/// key (measured on 1× captures: one pixel row outside the glass). It sits 1 pt outside the composer, which doesn't
/// clip it, so snapshots of the composer for flights never carry it.
@MainActor final class NativeComposerFocusRing: NSView {
    private var observers: [NSObjectProtocol] = []
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            })
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let edge = bounds.insetBy(dx: 1, dy: 1).insetBy(dx: -0.375, dy: -0.375)
        let ring = NSBezierPath(roundedRect: edge, xRadius: 20.375, yRadius: 20.375); ring.lineWidth = 0.75
        let color = NSColor.keyboardFocusIndicatorColor
        color.withAlphaComponent(color.alphaComponent * (window?.isKeyWindow == false ? 0.4 : 1)).setStroke(); ring.stroke()
    }
}
