import AppKit
import QuartzCore

enum NativeFlightPart: Hashable { case workedDivider, activityText, activityMark }
struct NativeFlightSource {
    /// NativeTranscript viewport coordinates, top-left origin. Includes transparent padding on the pixel grid.
    let rect: CGRect
    let image: CGImage
}

/// Keep this view alive across presentation changes: its text views own selection and scroll state.
@MainActor final class NativeTranscript: NativeInteractionSurface {
    let conversation: Conversation
    private var modeEpochModel:Conversation?
    private var modeEpochFrozen=false
    private var modeCatchupGeneration=0
    private var modeCatchupFollowsEnd=false
    private var modeReplayInterval=0.125,modeReplayNext=0.0
    private var modeStreamItem:String?,modeStreamLength=0,modeStreamTime=0.0
    private var modeScrollGeneration=0
    private var modeSavedScroller:Bool?
    private var modeFollowResuming=false,modeCatchupRefreshing=false
    /// A resumed following viewport keeps its displayed tail through later inset/refinement and
    /// completion changes too. An explicit reading position still uses the normal reading anchor.
    func prepareModeFollowResumption() {modeFollowResuming=true}
    private func modeFollowOrigin()->(offset:CGFloat,shift:Double)? {
        guard modeFollowResuming,!modeEpochFrozen,!modeContentIsCatchingUp,!modeCatchupRefreshing else {return nil}
        let shift=(document.layer?.presentation()?.value(forKeyPath:"transform.translation.y") as? NSNumber)?.doubleValue
            ?? (document.layer?.value(forKeyPath:"transform.translation.y") as? NSNumber)?.doubleValue ?? 0
        return (scrollOffset.y,shift)
    }
    private func continueModeFollow(_ origin:(offset:CGFloat,shift:Double)?,following:Bool) {
        guard let origin,following else {return}
        let shift=Double(scrollOffset.y-origin.offset)+origin.shift
        guard abs(shift)>0.01 else {return}
        _=applyModeScrollCompensation(shift)
    }
    private func restoreModeScroller(animated:Bool=false) {
        guard let saved=modeSavedScroller else {return};modeSavedScroller=nil
        scrollView.hasVerticalScroller=saved
        guard let scroller=scrollView.verticalScroller else {return}
        scroller.alphaValue=1
        if animated {
            scroller.wantsLayer=true
            let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=0;fade.toValue=1;fade.duration=0.14
            scroller.layer?.add(fade,forKey:"mode.content.scroller")
        }
    }
    @discardableResult private func applyModeScrollCompensation(_ shift:Double)->Double {
        CATransaction.begin();CATransaction.setDisableActions(true);defer {CATransaction.commit()}
        if let value=document.layer?.value(forKeyPath:"transform.translation.y") as? NSNumber,abs(value.doubleValue)>0.000001 {document.layer?.setValue(0,forKeyPath:"transform.translation.y")}
        guard abs(shift)>0.01,!Motion.reduce,presentationActive,!isHiddenOrHasHiddenAncestor else {
            document.layer?.removeAnimation(forKey:"mode.content.scroll");return 0
        }
        let animation=CABasicAnimation(keyPath:"transform.translation.y")
        animation.fromValue=shift;animation.toValue=0;animation.duration=modeReplayInterval
        animation.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        animation.beginTime=document.layer?.convertTime(CACurrentMediaTime(),from:nil) ?? 0
        document.layer?.add(animation,forKey:"mode.content.scroll")
        return modeReplayInterval
    }
    /// Called only after a complete source picture covers the old native owner.
    func resetModeContentScrollCompensation() {_=applyModeScrollCompensation(0)}
    private func finishModeScroller(after delay:Double) {
        guard delay>0 else {restoreModeScroller();return}
        let generation=modeScrollGeneration
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
            guard let self,!self.isDisposed,!self.modeEpochFrozen,self.modeScrollGeneration == generation else {return}
            self.restoreModeScroller(animated:true)
        }
    }
    private func observeModeStream(_ change:ConversationChange) {
        guard Self.tracksModePictures,let id=change.itemID,let index=conversation.transcriptItemIndex(id) else {return}
        let text=conversation.items[index].text,length=text.utf8.count,now=CACurrentMediaTime()
        guard modeStreamItem != id || length != modeStreamLength else {return}
        defer {modeStreamItem=id;modeStreamLength=length;modeStreamTime=now}
        let elapsed=now-modeStreamTime,delta=length-modeStreamLength
        guard modeStreamItem == id,delta>0,elapsed>=0.02,elapsed<=2 else {return}
        // Replay half of a normal 16-character/250ms packet by default, then follow the observed source rate.
        // Count bytes in O(1); a bounded suffix estimates character width without rescanning a long answer.
        let suffix=text.suffix(16),bytesPerCharacter=Double(suffix.utf8.count)/Double(max(1,suffix.count))
        let interval=min(0.5,max(0.05,elapsed*8*max(1,bytesPerCharacter)/Double(delta)))
        modeReplayInterval=modeReplayInterval*0.75+interval*0.25
    }
    private var renderConversation:Conversation {modeEpochModel ?? conversation}
    private var modePresentationSequence=0
    #if M11_MODE_SELFTEST
    var verificationModeCatchupPackets:[[Double]]=[]
    var verificationManualModeCatchup=false
    var verificationPacedModeCatchup=false
    var verificationModeReplayNow:(()->Double)?
    var verificationModeReplayInterval:Double {modeReplayInterval}
    var verificationModeScrollAnimation:CAAnimation? {document.layer?.animation(forKey:"mode.content.scroll")}
    var verificationModeScrollOrigin:Double {Double(scrollOffset.y)}
    var verificationModeText:[String] {renderConversation.items.map(\.text)}
    func verificationModeCatchupStep() {var budget=8;_ = catchUpModeEpoch(modeCatchupGeneration,budget:&budget)}
    #endif
    var modeContentIsCatchingUp:Bool {!modeEpochFrozen && modeEpochModel != nil}
    private static let tracksModePictures=ProcessInfo.processInfo.environment["M11_MODE_ORRERY_FLIGHT"] != "0"
    private var modeRenderedModel:Conversation?
    var modeContentPresentationValue:Conversation {renderConversation}
    var modeContentRenderedValue:Conversation {modeEpochModel ?? modeRenderedModel ?? conversation}
    var onModeContentCatchupFinished:(()->Void)?
    func beginModeContentEpoch(snapshot:Conversation?=nil) {
        guard !modeEpochFrozen else {return}
        modeCatchupGeneration+=1
        // A second freeze captures the prefix actually on screen, never the unpresented store tail.
        if modeEpochModel == nil {modeEpochModel=snapshot ?? ModeContentEpoch.copy(modeContentRenderedValue);modeCatchupFollowsEnd=shouldFollowEnd && isAtEnd}
        modeEpochFrozen=true;modeContentInputBlocked=true
        modeScrollGeneration+=1
        document.wantsLayer=true
        // Freeze the displayed compensation rather than snapping a new warm/cold epoch to its model endpoint.
        if let shown=document.layer?.presentation()?.value(forKeyPath:"transform.translation.y") {
            document.layer?.setValue(shown,forKeyPath:"transform.translation.y")
        }
        document.layer?.removeAnimation(forKey:"mode.content.scroll")
        scrollView.verticalScroller?.alphaValue=0
        if modeSavedScroller == nil {modeSavedScroller=scrollView.hasVerticalScroller}
        // Overlay scrollers may rewrite their alpha during reflected programmatic scrolls.
        scrollView.hasVerticalScroller=false
        refinementTask?.cancel();refinementTask=nil
    }
    func endModeContentEpoch() {
        guard modeEpochFrozen else {return};modeEpochFrozen=false;modeContentInputBlocked=false;modeCatchupGeneration+=1
        prepareModeFollowResumption()
        let frozenShift=(document.layer?.value(forKeyPath:"transform.translation.y") as? NSNumber)?.doubleValue ?? 0
        let settling=applyModeScrollCompensation(frozenShift)
        guard modeEpochModel != nil else {finishModeScroller(after:settling);return}
        if !presentationActive || isHiddenOrHasHiddenAncestor {modeEpochModel=nil;restoreModeScroller();refreshDeferred=true;return}
        if modeEpochModel?.revision == conversation.revision,renderedRevision == conversation.revision {modeEpochModel=nil;finishModeScroller(after:settling);return}
        modeReplayNext=CACurrentMediaTime()+modeReplayInterval
        #if M11_MODE_SELFTEST
        if verificationManualModeCatchup {return}
        #endif
        let generation=modeCatchupGeneration
        NativeModeContentCatchupClock.shared.enqueue(self) { [weak self] budget in
            self?.catchUpModeEpoch(generation,budget:&budget) ?? false
        }
    }
    private func catchUpModeEpoch(_ generation:Int,budget:inout Int)->Bool {
        guard !isDisposed,generation == modeCatchupGeneration,!modeEpochFrozen,let previous=modeEpochModel else {return false}
        #if M11_MODE_SELFTEST
        let packetBudget=budget
        #endif
        #if M11_MODE_SELFTEST
        let now=verificationModeReplayNow?() ?? CACurrentMediaTime()
        let paced = !verificationManualModeCatchup || verificationPacedModeCatchup
        #else
        let now=CACurrentMediaTime(),paced=true
        #endif
        if paced,now<modeReplayNext {return true}
        modeReplayNext=now+modeReplayInterval
        let latest=ModeContentEpoch.copy(conversation)
        let old=Dictionary(uniqueKeysWithValues:previous.items.map {($0.id,$0)})
        var pending=false,items:[TranscriptItem]=[]
        for item in latest.items {
            var value=item
            let before=old[item.id]?.text ?? ""
            if item.text.hasPrefix(before),item.text.count>before.count {
                let count=min(budget,item.text.count-before.count)
                value.text=String(item.text.prefix(before.count+count));budget-=count
                if value.text != item.text {pending=true}
            }
            if old[item.id] != nil || !value.text.isEmpty || !pending {items.append(value)} else {pending=true}
        }
        if pending {
            for index in items.indices {
                let text=items[index].text
                if let value=old[items[index].id] {items[index]=value;items[index].text=text}
                else {items[index].status="running"}
            }
            // Keep status/cards/order at R0 until their preceding stream has been presented.
            let prefix=ModeContentEpoch.copy(previous);prefix.items=items
            modePresentationSequence+=1;prefix.revision = -modePresentationSequence-1000
            modeEpochModel=prefix
        } else {modeEpochModel=nil}
        #if M11_MODE_SELFTEST
        if packetBudget>budget {verificationModeCatchupPackets.append([CACurrentMediaTime(),Double(packetBudget-budget),Double(NativeModeContentCatchupClock.shared.verificationFrameSerial)])}
        #endif
        modeRows.removeAll(keepingCapacity:true)
        let following=followsEnd
        // Preserve the reader's original tail intent through each normal-sized stream packet.
        // Native scrolling away during catchup still wins over that saved intent.
        let follow=modeCatchupFollowsEnd && readerFollowsEnd && following
        if !follow {followsEnd=false}
        let oldOffset=scrollOffset.y
        let displayedShift=(document.layer?.presentation()?.value(forKeyPath:"transform.translation.y") as? NSNumber)?.doubleValue
            ?? (document.layer?.value(forKeyPath:"transform.translation.y") as? NSNumber)?.doubleValue ?? 0
        modeCatchupRefreshing=true
        defer {modeCatchupRefreshing=false}
        refresh(preservingOffset:follow ? false:nil,allowHidden:true)
        followsEnd=following
        let shift=Double(scrollOffset.y-oldOffset)+displayedShift
        let settling=applyModeScrollCompensation(follow ? shift:0)
        if !pending {finishModeScroller(after:max(settling,modeReplayInterval));onModeContentCatchupFinished?()}
        return pending
    }
    var decisionCardsInline=true{didSet{if decisionCardsInline != oldValue{invalidateAccessibilityLease();refresh(preservingOffset:true)}}}
    /// Organic's decisions are a bottom overlay, as in OrganicColumn.transcript. Normie owns its external rail.
    /// A presentation lease resets this flag on every handoff; the retained controls and request IDs are shared.
    var decisionCardsAtBottom = false {
        didSet { if decisionCardsAtBottom != oldValue { invalidateAccessibilityLease(); refresh() } }
    }
    private let pinnedScroll = NSScrollView(), pinnedDocument = NativeInteractionSurface()
    private var pinnedReserve: CGFloat = 0
    private(set) var captureRevision = 0
    var pinnedDecisionFrame: CGRect { decisionCardsAtBottom && !pinnedScroll.isHidden ? pinnedScroll.frame : .zero }
    private var retainedDecisionCards: [String: NativeTranscriptCard] = [:]
    private var externalCards:[String:NativeTranscriptCard]=[:]
    let scrollView = NSScrollView()
    private let document = NativeTranscriptTable(frame:.zero)
    private weak var store: ConversationStore?
    private var observation: UUID?
    private var rows: [String: NativeTranscriptRow] = [:]
    private var cards: [String: NativeTranscriptCard] = [:]
    private var order: [NSView] = []
    private var entries: [NativeTranscriptLayoutEntry] = []
    private var entryPositions: [String: Int] = [:]
    private var heights = NativeTranscriptHeightIndex()
    private var rowPool: [NativeTranscriptRow] = []
    private let sizingCard = NativeTranscriptCard()
    private var preparedKeys: Set<String> = []
    private struct ModeRowKey:Hashable {
        let item:String,revision:Int,appearance:Int,display:Int,width:CGFloat,expanded:Bool,reviewed:Bool
    }
    private var modeRows:[ModeRowKey:NativeTranscriptPreparedRow]=[:]
    private(set) var modeRowCacheHits=0
    var modePreparedWidths:[CGFloat] {Array(Set(modeRows.keys.map(\.width))).sorted()}
    private func modeRowKey(_ item:TranscriptItem,width:CGFloat)->ModeRowKey {
        .init(item:item.id,revision:renderConversation.revision,appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision,width:width,expanded:expanded.contains(item.id),reviewed:reviewedChanges.contains(item.id))
    }
    /// A value/layout cache only: no live frame, row, lease, callback, selection or scroll mutation.
    /// One item per call; long histories prepare only the bounded viewport/tail neighbourhood.
    @discardableResult func prepareModeRow(width:CGFloat,cursor:inout Int)->Bool {
        guard !isDisposed,width>1 else{return true}
        let (first,end)=modeRowWindow
        let index=first+cursor
        guard index<end else{return true}
        let item=renderConversation.items[index],key=modeRowKey(item,width:width)
        if modeRows[key] == nil, !reviewedChanges.contains(item.id) {
            if modeRows.count>=256 {modeRows=modeRows.filter{$0.key.revision == renderConversation.revision && $0.key.appearance == NativeAppearance.revision && $0.key.display == NativeDisplayOptions.shared.revision};if modeRows.count>=256 {modeRows.removeAll(keepingCapacity:true)}}
            modeRows[key]=NativeTranscriptPreparedRow(item:item,source:item,index:index,items:renderConversation.items,width:width,expanded:expanded.contains(item.id),style:codeStyle)
        }
        cursor+=1;return first+cursor>=end
    }
    private var modeRowWindow:(first:Int,end:Int) {
        let count=renderConversation.items.count
        let anchor=readingAnchor().flatMap{entryPositions[$0.key]}.flatMap{entries[$0].itemIndex} ?? max(0,count-24)
        // A hidden transcript's entries can be older than its items while it waits to refresh: the anchor may be past the end.
        let first=count<=64 ? 0:min(count,shouldFollowEnd && isAtEnd ? max(0,count-32):max(0,anchor-12))
        return (first,count<=64 ? count:min(count,first+48))
    }
    /// The longest text prepareModeRow would lay out, in bytes.
    var modeRowLargestText:Int {
        let (first,end)=modeRowWindow
        return renderConversation.items[first..<end].reduce(0){max($0,$1.text.utf8.count)}
    }
    private var configurationCounts: [String: Int] = [:]
    private var refinementCursor = 0
    private var refinementTask: Task<Void, Never>?
    private var layoutAppearanceRevision = -1, layoutDisplayRevision = -1
    private var layoutCodeStyle: NativeTranscriptCodeStyle?
    private var renderedChanges: [FileChange] = []
    private var lastViewportHeight: CGFloat = -1
    private var lastWidth: CGFloat = -1
    private var lastGrid: CGFloat = -1
    private var expanded: Set<String> = []
    private var reviewedChanges: Set<String> = []
    private var hiddenText: Set<String> = []
    private var hiddenTextRanges: [String: IndexSet] = [:]
    private var hiddenFlightParts: [String: Set<NativeFlightPart>] = [:]
    private let latestButton = NativeTranscriptLatestButton()
    private var renderedApprovals:[Approval]=[]
    private var renderedQuestion:UserInputRequest?
    private var renderedLegacyQuestion: String?
    private var layoutExpanded: Set<String> = [], layoutReviewed: Set<String> = []
    private var layoutInlinePolicy = true
    private(set) var incrementalRefreshCount = 0
    private(set) var fullIndexRebuildCount = 0
    private(set) var historyScanCount = 0
    private(set) var itemRefreshCount = 0
    private var renderedItemCount = 0
    // Entry values are the legacy comparison baseline. Retaining renderConversation.items itself forces an O(n)
    // Array copy on every reducer edit, even if the notification names exactly one item.
    private var renderedItems: [TranscriptItem] { entries.compactMap(\.item) }
    private var scrollObservation: NSObjectProtocol?
    private var pinnedObservation: NSObjectProtocol?
    private(set) var refreshDeferred=false
    private(set) var isDisposed=false
    private var configurationDepth = 0
    private var configurationNeedsRefresh = false
    private var configurationFollowEnd=false
    private var refreshing = false
    private(set) var newContentWhileAway = false
    private(set) var renderedRevision = -1
    var followsEnd = true
    /// Reader intent is independent of a host temporarily freezing follow during a text flight.
    private(set) var readerFollowsEnd = true
    var shouldFollowEnd:Bool {followsEnd && readerFollowsEnd}
    var codeStyle = NativeAppearance.current.code { didSet { if oldValue != codeStyle {modeRows=[:];refresh()} } }
    weak var messageDraftTarget:NativeComposer? {didSet{refresh(preservingOffset:true)}}
    var onUserMessageAction:((NativeUserMessageAction)->Void)? {didSet{refresh(preservingOffset:true)}}
    private(set) var elicitationExchanges:[String:NativeElicitationExchange]=[:]
    var onEditMessage: ((TranscriptItem) -> Void)? { didSet { refresh(preservingOffset: true) } }
    var onForkMessage: ((TranscriptItem) -> Void)? { didSet { refresh(preservingOffset: true) } }
    var onApprovalValue: ((Approval, JSONValue) -> Void)? { didSet { refresh(preservingOffset: true) } }
    private(set) var elicitationResponses: [String: JSONValue] = [:]
    var onApproval: ((Approval, ApprovalAction) -> Void)? { didSet { refresh(preservingOffset: true) } }
    var onAnswer: ((UserInputRequest, [String: [String]]) -> Void)? { didSet { refresh(preservingOffset: true) } }
    var onReviewChanges: ((TranscriptItem) -> Void)?
    var onRevertChanges: ((TranscriptItem) -> Void)? { didSet { refresh(preservingOffset: true) } }

    init(conversation: Conversation, store: ConversationStore? = nil) {
        self.conversation = conversation; self.store = store
        super.init(frame: .zero)
        appearance = NativeDisplayOptions.appearance
        scrollView.drawsBackground = false; scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none; scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init(); scrollView.documentView = document
        document.surface=self
        addSubview(scrollView)
        pinnedScroll.contentView = NativeCardClipView()
        pinnedScroll.drawsBackground = false; pinnedScroll.borderType = .noBorder
        pinnedScroll.hasVerticalScroller = true; pinnedScroll.autohidesScrollers = true
        pinnedScroll.scrollerStyle = .overlay; pinnedScroll.documentView = pinnedDocument
        pinnedScroll.isHidden = true; addSubview(pinnedScroll)
        latestButton.title = "Jump to Latest"; latestButton.font = .systemFont(ofSize: 12, weight: .medium)
        latestButton.target = self; latestButton.action = #selector(jumpToLatest); latestButton.isHidden = true
        latestButton.setAccessibilityLabel("Jump to Latest"); addSubview(latestButton)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didScroll() }
        }
        pinnedScroll.contentView.postsBoundsChangedNotifications = true
        pinnedObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: pinnedScroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureRevision &+= 1 }
        }
        setAccessibilityElement(false)
        scrollView.setAccessibilityLabel("Conversation: " + renderConversation.title)
        if let store {
            observation = store.observeChanges { [weak self] c, change in
                guard let self, c === self.conversation else { return }
                self.observeModeStream(change)
                self.refresh(change: change)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit {
        refinementTask?.cancel()
        if let observation { store?.removeObserver(observation) }
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        if let pinnedObservation { NotificationCenter.default.removeObserver(pinnedObservation) }
    }

    var scrollOffset: CGPoint {
        get { scrollView.contentView.bounds.origin }
        set {
            // On the pixel grid: at a fractional offset the screen shows the rows snapped to whole pixels while a
            // capture draws them at the fraction, so every horizontal edge moved at the swap (bubble edge 0.62 → 0.79).
            let maxY = max(0, document.frame.height - scrollView.contentSize.height)
            let y = (min(maxY, max(0, newValue.y)) * grid).rounded(.down) / grid
            let nested = refreshing
            refreshing = true
            let origin = CGPoint(x: 0, y: y)
            if scrollView.contentView.bounds.origin != origin {
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            if !nested, lastWidth > 0 {
                assembleViewport(follow: shouldFollowEnd && isAtEnd, preservePixels: true, reconfigure: false)
                if isAtEnd { newContentWhileAway = false }
                updateLatest(); scheduleHeightRefinement()
            }
            refreshing = nested
        }
    }
    var contentHeight: CGFloat { document.frame.height }
    private var grid: CGFloat { max(1, window?.backingScaleFactor ?? 1) }
    var isAtEnd: Bool { distanceFromEnd <= 24 }
    var distanceFromEnd: CGFloat { contentHeight - scrollOffset.y - scrollView.contentSize.height }
    func scrollToEnd() {
        readerFollowsEnd=true
        let nested = refreshing
        refreshing = true
        scrollOffset = CGPoint(x: 0, y: max(0, contentHeight - scrollView.contentSize.height))
        if !nested { assembleViewport(follow: true, reconfigure: false) }
        refreshing = nested
        newContentWhileAway = false; updateLatest()
    }
    @objc private func jumpToLatest() { scrollToEnd() }
    private func didScroll() {
        guard !refreshing, !isDisposed, lastWidth > 0 else { return }
        // Only native input reaches this callback unguarded. Latch intent before virtualization changes heights;
        // the legacy near-bottom slack must never re-arm follow after the reader deliberately scrolled away.
        if lastWidth == scrollView.contentSize.width,lastViewportHeight == scrollView.contentSize.height {
            readerFollowsEnd = distanceFromEnd <= 0.5
        }
        // Native wheel/scroller changes also need a backing-aligned offset, not just writes through our API.
        let offset = scrollOffset
        let y = (offset.y * grid).rounded(.down) / grid
        refreshing = true
        if offset.x != 0 || offset.y != y { scrollOffset = CGPoint(x: 0, y: y) }
        assembleViewport(follow: shouldFollowEnd && isAtEnd, preservePixels: !followsEnd, reconfigure: false)
        refreshing = false
        if isAtEnd { newContentWhileAway = false }
        updateLatest(); scheduleHeightRefinement()
    }
    private func updateLatest() {
        let distance=contentHeight-scrollOffset.y-scrollView.contentSize.height
        let hidden = isAtEnd || !(newContentWhileAway || distance>scrollView.contentSize.height)
        if latestButton.isHidden != hidden { latestButton.isHidden = hidden }
        let frame = CGRect(x: ((bounds.midX - 64) * grid).rounded() / grid,
            y: ((bounds.maxY - 40 - (pinnedReserve > 0 ? pinnedReserve + 10 : 0)) * grid).rounded() / grid, width: 128, height: 28)
        if latestButton.frame != frame { latestButton.frame = frame }
    }
    func rowConfigurationCount(itemID: String) -> Int { configurationCounts[itemID] ?? 0 }

    override func displayOptionsDidChange(){super.displayOptionsDidChange();refresh()}
    override func nativeAppearanceDidChange(){super.nativeAppearanceDidChange();if codeStyle != NativeAppearance.current.code{codeStyle=NativeAppearance.current.code}else{refresh()}}
    override func layout() {
        let origin=modeFollowOrigin(),following=shouldFollowEnd && isAtEnd
        defer {continueModeFollow(origin,following:following)}
        super.layout()
        guard configurationDepth == 0 else {configurationNeedsRefresh=true;return}
        if scrollView.frame != bounds { scrollView.frame = bounds }
        layoutPinnedDecisions()
        updateLatest()
        if lastWidth != scrollView.contentSize.width || lastGrid != grid || lastViewportHeight != scrollView.contentSize.height {
            refresh()
        }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); refresh()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let atEnd = isAtEnd
        let origin=modeFollowOrigin()
        defer {continueModeFollow(origin,following:shouldFollowEnd && atEnd)}
        super.setFrameSize(newSize)
        needsLayout = true
        if configurationDepth>0 {configurationFollowEnd = configurationFollowEnd || (shouldFollowEnd && atEnd);configurationNeedsRefresh=true;return}
        layoutSubtreeIfNeeded()
        if shouldFollowEnd && atEnd { scrollToEnd() }
    }

    /// nil follows only if already near the end; true freezes the current viewport during a flight.
    override func presentationVisibilityDidChange(){
        guard !isDisposed else { return }
        if !isPresentationVisible { refinementTask?.cancel(); refinementTask = nil; return }
        if refreshDeferred { refreshDeferred = false; refresh() }
        else { scheduleHeightRefinement() }
    }
    func dispose(){
        NativeModeContentCatchupClock.shared.cancel(self)
        guard !isDisposed else{return};modeRenderedModel=nil;modeRows.removeAll();isDisposed=true;refinementTask?.cancel();refinementTask=nil;presentationActive=false
        if let observation{store?.removeObserver(observation);self.observation=nil}
        if let scrollObservation{NotificationCenter.default.removeObserver(scrollObservation);self.scrollObservation=nil}
        if let pinnedObservation{NotificationCenter.default.removeObserver(pinnedObservation);self.pinnedObservation=nil}
        onEditMessage=nil;onForkMessage=nil;onUserMessageAction=nil;onApproval=nil;onApprovalValue=nil;onAnswer=nil;onReviewChanges=nil;onRevertChanges=nil;messageDraftTarget=nil
        for view in document.subviews{view.isHidden=true;view.removeFromSuperview()};for card in externalCards.values{card.isHidden=true;card.removeFromSuperview()};externalCards=[:];retainedDecisionCards=[:];cards=[:];rows=[:];rowPool=[];entries=[];entryPositions=[:];order=[];document.update([])
    }
    /// Mount configuration is one transaction, not a full history refresh for every callback assignment.
    static var onModeDrain:((Bool)->Void)?
    func configurePresentation(allowHidden:Bool=false,_ configure: () -> Void) {
        configurationDepth += 1
        configure()
        configurationDepth -= 1
        if configurationDepth == 0, configurationNeedsRefresh {
            configurationNeedsRefresh = false
            let follow=configurationFollowEnd;configurationFollowEnd=false
            Self.onModeDrain?(true)
            refresh(preservingOffset:follow ? false:nil,allowHidden:allowHidden)
            Self.onModeDrain?(false)
        }
    }
    func clearPresentationCallbacks() {
        configurePresentation {
            messageDraftTarget = nil; onUserMessageAction = nil; onEditMessage = nil; onForkMessage = nil
            onApproval = nil; onApprovalValue = nil; onAnswer = nil; onReviewChanges = nil; onRevertChanges = nil
        }
    }
    /// Selections survive transfer. An active pointer/menu or an IME field editor must finish first.
    var canHandoff: Bool {
        !rows.values.contains { $0.blocksHandoff } &&
        !Array(retainedDecisionCards.values).contains { $0.blocksHandoff } && !Array(cards.values).contains { $0.blocksHandoff } && !Array(externalCards.values).contains { $0.blocksHandoff }
    }

    /// nil follows only if already near the end; true freezes the current viewport during a flight.
    func refresh(preservingOffset: Bool? = nil, allowHidden: Bool = false, change: ConversationChange? = nil) {
        guard !isDisposed else { return }
        if (modeEpochFrozen || modeContentIsCatchingUp),change != nil {refreshDeferred=true;return}
        if configurationDepth > 0 { configurationNeedsRefresh = true; return }
        if !allowHidden, !isPresentationVisible { refreshDeferred = true; return }
        guard !refreshing else { return }
        refreshDeferred = false; refreshing = true
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0; NSAnimationContext.current.allowsImplicitAnimation = false
        defer { updateLatest(); NSAnimationContext.endGrouping(); refreshing = false; scheduleHeightRefinement() }
        let modeOrigin=modeFollowOrigin()
        let wasFollowing=modeOrigin == nil ? nil:Optional(shouldFollowEnd && isAtEnd)
        if scrollView.frame != bounds { scrollView.frame = bounds }
        layoutPinnedDecisions()
        let previous = scrollOffset, anchor = readingAnchor()
        let follow = preservingOffset == false || (preservingOffset == nil && (wasFollowing ?? (shouldFollowEnd && isAtEnd)))
        if !follow && renderedItemCount > 0 {
            if change?.itemID != nil { newContentWhileAway = true }
            else if renderedItems != renderConversation.items { newContentWhileAway = true }
        }
        let width = max(1, scrollView.contentSize.width)
        let invalid = lastWidth != width || lastGrid != grid || layoutAppearanceRevision != NativeAppearance.revision ||
            layoutDisplayRevision != NativeDisplayOptions.shared.revision || layoutCodeStyle != codeStyle
        lastViewportHeight = scrollView.contentSize.height
        lastWidth = width; lastGrid = grid; layoutAppearanceRevision = NativeAppearance.revision
        layoutDisplayRevision = NativeDisplayOptions.shared.revision; layoutCodeStyle = codeStyle
        let precise = !invalid && change?.itemID != nil && renderedRevision == renderConversation.revision - 1
        let updated: Bool
        if precise, let id = change?.itemID { updated = updateItemLayoutIndex(itemID: id) }
        else if !invalid && change == nil { historyScanCount += 1; updated = updateStreamingLayoutIndex() }
        else { updated = false }
        if updated {
            incrementalRefreshCount += 1
        } else {
            if renderedItems.filter({$0.rowKind == .user}) != renderConversation.items.filter({$0.rowKind == .user}) ||
                renderedApprovals.map(\.request) != renderConversation.approvals.map(\.request) ||
                renderedApprovals.map(\.id) != renderConversation.approvals.map(\.id) || renderedQuestion != renderConversation.userInput {
                invalidateAccessibilityLease()
            }
            if invalid || change != nil { historyScanCount += 1 }
            fullIndexRebuildCount += 1
            rebuildLayoutIndex(invalidating: invalid)
        }
        renderedApprovals = renderConversation.approvals; renderedQuestion = renderConversation.userInput
        renderedLegacyQuestion = renderConversation.question; layoutExpanded = expanded; layoutReviewed = reviewedChanges
        layoutInlinePolicy = decisionCardsInline
        renderedItemCount = renderConversation.items.count; renderedRevision = renderConversation.revision
        if Self.tracksModePictures {modeRenderedModel=ModeContentEpoch.copy(renderConversation)}
        // Short fixtures/history can be exact immediately; a long document never blocks on all its TextKit layouts.
        if !precise && entries.count <= 64 { for i in entries.indices { measureEntry(i, retainingText: false) } }
        resizeDocument()
        restoreViewport(previous: previous, anchor: preservingOffset == nil ? anchor : nil, follow: follow)
        assembleViewport(follow: follow, preservePixels: preservingOffset == true)
        continueModeFollow(modeOrigin,following:follow)
        needsDisplay = true
    }

    private struct ReadingAnchor { let key: String; let distance: CGFloat }
    private func readingAnchor() -> ReadingAnchor? {
        guard !entries.isEmpty else { return nil }
        let index = heights.row(at: scrollOffset.y - 18)
        return ReadingAnchor(key: entries[index].key, distance: 18 + heights.prefix(index) - scrollOffset.y)
    }
    private func restoreViewport(previous: CGPoint, anchor: ReadingAnchor?, follow: Bool) {
        if follow { scrollOffset = CGPoint(x: 0, y: max(0, contentHeight - scrollView.contentSize.height)) }
        else if let anchor, let i = entryPositions[anchor.key] { scrollOffset = CGPoint(x: 0, y: 18 + heights.prefix(i) - anchor.distance) }
        else { scrollOffset = previous }
    }
    private func resizeDocument() {
        let size = CGSize(width: lastWidth, height: max(scrollView.contentSize.height, ceil((18 + heights.total + 28 + pinnedReserve) * grid) / grid))
        if document.frame.size != size { document.setFrameSize(size) }
    }
    /// Typed notifications never inspect the historical prefix. A hint that cannot be proven against the current
    /// layout/metadata (missed revision, hidden refresh, changed decisions or topology) takes the structural fallback.
    private func updateItemLayoutIndex(itemID: String) -> Bool {
        guard renderedApprovals == renderConversation.approvals, renderedQuestion == renderConversation.userInput,
              renderedLegacyQuestion == renderConversation.question, renderedChanges == renderConversation.changes,
              layoutExpanded == expanded, layoutReviewed == reviewedChanges, layoutInlinePolicy == decisionCardsInline else { return false }
        if let position = entryPositions["item:" + itemID], let index = entries[position].itemIndex,
           renderedItemCount == renderConversation.items.count, renderConversation.items.indices.contains(index) {
            let entry = entries[position], item = renderConversation.items[index]
            guard item.id == itemID, entry.item?.turnID == item.turnID, entry.item?.rowKind == item.rowKind else { return false }
            entry.item = item; entry.exact = false; entry.prepared = nil
            // The next row depends on the preceding kind/turn, not its text/status. Keep its baseline current
            // without invalidating or reconfiguring it for every token.
            if index + 1 < renderConversation.items.count, let next = entryPositions["item:" + renderConversation.items[index + 1].id] {
                entries[next].previous = item
            }
            if item.rowKind == .user { invalidateAccessibilityLease() }
            refinementCursor = min(refinementCursor, position)
            measureEntry(position, retainingText: rows[itemID] != nil); itemRefreshCount += 1
            return true
        }
        // A lifecycle/delta can introduce one new tail item. Insert before orphan decisions/questions, while
        // keeping an existing last item's attached approvals in place. Only that bounded card tail moves.
        guard renderConversation.items.count == renderedItemCount + 1, let item = renderConversation.items.last, item.id == itemID else { return false }
        var insertion = entries.count
        while insertion > 0 {
            let last = entries[insertion - 1]
            if last.question != nil || last.approval.map({ entryPositions["item:" + $0.toolItemID] == nil }) == true { insertion -= 1 }
            else { break }
        }
        guard insertion == 0 || entries[insertion - 1].itemIndex == renderedItemCount - 1 ||
              entries[insertion - 1].approval != nil else { return false }
        let index = renderedItemCount, key = "item:" + itemID
        let entry = NativeTranscriptLayoutEntry(key: key)
        entry.itemIndex = index; entry.item = item; entry.previous = index > 0 ? renderConversation.items[index - 1] : nil
        entry.expanded = expanded.contains(itemID); entry.reviewed = reviewedChanges.contains(itemID)
        entry.height = estimatedHeight(item, index: index, expanded: entry.expanded)
        let tail = Array(entries[insertion...])
        let attached = tail.filter { $0.approval?.toolItemID == itemID }
        let remainder = tail.filter { $0.approval?.toolItemID != itemID }
        entries.replaceSubrange(insertion..<entries.count, with: [entry] + attached + remainder)
        heights.append(entry.height)
        for position in insertion..<entries.count {
            entryPositions[entries[position].key] = position; heights.set(entries[position].height, at: position)
        }
        if item.rowKind == .user { invalidateAccessibilityLease() }
        measureEntry(insertion, retainingText: false)
        itemRefreshCount += 1
        return true
    }
    /// Explicit legacy refresh callers have no hint. Prove the prefix unchanged before reusing bounded tail layout.
    private func updateStreamingLayoutIndex() -> Bool {
        let items = renderConversation.items, previous = renderedItems
        guard !entries.isEmpty, items.count == previous.count,
              renderedApprovals == renderConversation.approvals, renderedQuestion == renderConversation.userInput,
              renderedLegacyQuestion == renderConversation.question, renderedChanges == renderConversation.changes,
              layoutExpanded == expanded, layoutReviewed == reviewedChanges, layoutInlinePolicy == decisionCardsInline else { return false }
        var changed: [Int] = []
        for i in items.indices where items[i] != previous[i] {
            guard i >= items.count - 8, items[i].id == previous[i].id,
                  items[i].turnID == previous[i].turnID, items[i].rowKind == previous[i].rowKind,
                  items[i].rowKind != .user else { return false }
            changed.append(i)
        }
        var affected = Set(changed)
        for i in changed where i + 1 < items.count { affected.insert(i + 1) }
        for i in affected {
            guard let position = entryPositions["item:" + items[i].id] else { return false }
            let entry = entries[position]
            entry.item = items[i]; entry.previous = i > 0 ? items[i - 1] : nil
            entry.exact = false; entry.prepared = nil
            refinementCursor = min(refinementCursor, position)
        }
        return true
    }
    private func rebuildLayoutIndex(invalidating all: Bool) {
        var liveDecisions = Set(renderConversation.approvals.map { "approval:" + $0.id })
        if let request = renderConversation.userInput { liveDecisions.insert("question:" + request.id) }
        else if renderConversation.question != nil { liveDecisions.insert("question:fixture-question:" + renderConversation.id) }
        for key in Array(retainedDecisionCards.keys) where !liveDecisions.contains(key) {
            retainedDecisionCards[key]?.removeFromSuperview(); retainedDecisionCards[key] = nil
        }
        let old = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        var next: [NativeTranscriptLayoutEntry] = []
        let itemIDs = Set(renderConversation.items.map(\.id))
        let grouped = Dictionary(grouping: decisionCardsInline ? renderConversation.approvals : [], by: \.toolItemID)
        func addApproval(_ approval: Approval) {
            let key = "approval:" + approval.id, entry = old[key] ?? NativeTranscriptLayoutEntry(key: key)
            if all || entry.approval != approval { entry.exact = false; entry.prepared = nil }
            entry.exact = false
            entry.approval = approval; next.append(entry)
        }
        for (index, item) in renderConversation.items.enumerated() {
            let key = "item:" + item.id, entry = old[key] ?? NativeTranscriptLayoutEntry(key: key)
            let previous = index > 0 ? renderConversation.items[index - 1] : nil
            let opened = expanded.contains(item.id), reviewed = reviewedChanges.contains(item.id)
            if all || entry.item != item || entry.previous != previous || entry.expanded != opened || entry.reviewed != reviewed ||
                (reviewed && renderedChanges != renderConversation.changes) {
                entry.exact = false; entry.prepared = nil
                if all { entry.stream = nil }
                if entry.item == nil { entry.height = estimatedHeight(item, index: index, expanded: opened) }
            }
            entry.itemIndex = index; entry.item = item; entry.previous = previous; entry.expanded = opened; entry.reviewed = reviewed
            next.append(entry)
            for approval in grouped[item.id] ?? [] { addApproval(approval) }
        }
        for approval in renderConversation.approvals where decisionCardsInline && !itemIDs.contains(approval.toolItemID) { addApproval(approval) }
        if decisionCardsInline, let request = inlineQuestion {
            let key = "question:" + request.id, entry = old[key] ?? NativeTranscriptLayoutEntry(key: key)
            if all || entry.question != request { entry.exact = false; entry.prepared = nil }
            entry.exact = false
            entry.question = request; next.append(entry)
        }
        let sameOrder = entries.count == next.count && zip(entries, next).allSatisfy { $0 === $1 }
        entries = next
        if !sameOrder {
            entryPositions = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.key, $0.offset) })
            heights.reset(next.map(\.height))
        }
        renderedChanges = renderConversation.changes; refinementCursor = 0
    }
    private var inlineQuestion: UserInputRequest? {
        renderConversation.userInput ?? renderConversation.question.map { UserInputRequest(id: "fixture-question:" + renderConversation.id,
            questions: [.init(id: "answer", header: "Question", prompt: $0, options: [])]) }
    }
    private func estimatedHeight(_ item: TranscriptItem, index: Int, expanded: Bool) -> CGFloat {
        let start: CGFloat = TranscriptPresentation.isTurnStart(index: index, items: renderConversation.items) ? 22 : 6
        let scale = NativeAppearance.current.textScale
        if TranscriptPresentation.isActivity(item.rowKind) && !expanded { return ceil(start + 18 * scale) }
        let width = max(80, min(740, lastWidth - 56) - (item.rowKind == .user ? 170 : 0))
        let count = item.text.utf8.count
        let breaks = item.text.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        let lines = max(1, max(breaks + 1, Int(ceil(CGFloat(count) * 6.3 * scale / width))))
        return ceil(start + CGFloat(lines) * 18 * scale + (item.rowKind == .user ? 46 : 6))
    }
    private func shownItem(_ entry: NativeTranscriptLayoutEntry) -> TranscriptItem {
        var item = entry.item!
        if entry.reviewed {
            item.text += "\n\n" + renderConversation.changes.map { file in
                file.path + "\n" + file.lines.map { line in
                    (line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  ") + line.text
                }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        return item
    }
    @discardableResult private func measureEntry(_ index: Int, retainingText: Bool) -> NativeTranscriptPreparedRow? {
        let entry = entries[index]
        if let prepared = entry.prepared { return prepared }
        if entry.exact && !retainingText { return nil }
        var prepared: NativeTranscriptPreparedRow?
        let height: CGFloat
        if let item = entry.item, let itemIndex = entry.itemIndex {
            let scale = NativeAppearance.current.textScale
            let textWidth = max(1, min(740, lastWidth - 2 * TranscriptLayout.gutter))
            if item.rowKind == .assistant, !entry.reviewed, !item.text.isEmpty,
               (item.status == "running" || renderConversation.running && itemIndex == renderConversation.items.count - 1),
               item.text.utf8.count <= 256 * 1024 {
                if entry.stream?.append(item, width: textWidth, scale: scale, style: codeStyle) != true {
                    entry.stream = NativeTranscriptStreamLayout(item: item, width: textWidth, scale: scale, style: codeStyle)
                }
            } else { entry.stream = nil }
            let cached=modeRows[modeRowKey(item,width:lastWidth)]
            let value:NativeTranscriptPreparedRow
            if let cached,!entry.reviewed {value=cached;entry.stream=nil;modeRowCacheHits+=1}
            else {value=NativeTranscriptPreparedRow(item:shownItem(entry),source:item,index:itemIndex,items:renderConversation.items,width:lastWidth,expanded:entry.expanded,style:codeStyle,stream:entry.stream)}
            height = ceil(value.geometry.rowHeight * grid) / grid; prepared = value
            if retainingText { entry.prepared = value; preparedKeys.insert(entry.key) }
        } else {
            let card = cards[entry.key] ?? retainedDecisionCards[entry.key] ?? sizingCard
            configureCard(card, entry: entry)
            height = ceil(card.frame.height * grid) / grid + 12
        }
        entry.height = height; entry.exact = true; heights.set(height, at: index)
        return prepared
    }
    private func configureCard(_ card: NativeTranscriptCard, entry: NativeTranscriptLayoutEntry) {
        if let approval = entry.approval { _ = approvalCard(approval, old: card, width: lastWidth, attach: false) }
        else if let request = entry.question {
            card.configureQuestion(request, width: lastWidth, enabled: !renderConversation.isLiveConversation || onAnswer != nil) { [weak self] answers in self?.answer(request, answers: answers) }
        }
    }
    private func overscanRange() -> Range<Int> {
        guard !entries.isEmpty else { return 0..<0 }
        let h = max(1, scrollView.contentSize.height)
        let first = heights.row(at: max(0, scrollOffset.y - h) - 18)
        let last = heights.row(at: scrollOffset.y + 2 * h - 18)
        return first..<(last + 1)
    }
    private func assembleViewport(follow: Bool = false, preservePixels: Bool = false, reconfigure: Bool = true) {
        let previous = scrollOffset, anchor = readingAnchor()
        for id in rows.keys { if let i = entryPositions["item:" + id], rows[id]?.preventsRecycling == true { measureEntry(i, retainingText: true) } }
        for (key, card) in cards where card.preventsRecycling { if let i = entryPositions[key] { measureEntry(i, retainingText: true) } }
        // Refinement can expose additional cells near a boundary. Converge before mounting, without a blank frame.
        while true {
            let range = overscanRange()
            for i in range { measureEntry(i, retainingText: true) }
            resizeDocument(); restoreViewport(previous: previous, anchor: preservePixels ? nil : anchor, follow: follow)
            if overscanRange().allSatisfy({ entries[$0].exact }) { break }
        }
        let desired = Set(overscanRange().map { entries[$0].key })
        for (id, row) in Array(rows) where !desired.contains("item:" + id) && (!row.preventsRecycling || entryPositions["item:" + id] == nil) {
            retireAccessibilitySubtree(row); row.prepareForReuse(); rows[id] = nil
            // As many as an all-compact overscan mounts: real histories are mostly one-line activity rows, and a row costs
            // more to create than most of the work that reuses it.
            // Keep hidden pool cells in the same document: recycling need not tear down/recreate AppKit backing.
            if rowPool.count < 125 && !row.preventsRecycling { rowPool.append(row) }
            else { row.removeFromSuperview() }
        }
        for (key, card) in Array(cards) where !desired.contains(key) && (!card.preventsRecycling || entryPositions[key] == nil) {
            retireAccessibilitySubtree(card); card.isHidden = true; card.removeFromSuperview(); card.onHeightChange = nil; cards[key] = nil
        }
        let retainedItems = Array(rows.keys).map { "item:" + $0 }.filter { !desired.contains($0) }
        let retainedCards = cards.keys.filter { !desired.contains($0) }
        for key in retainedItems + retainedCards { if let i = entryPositions[key] { measureEntry(i, retainingText: true); mountEntry(i, reconfigure: reconfigure) } }
        resizeDocument()
        for i in overscanRange() { mountEntry(i, reconfigure: reconfigure) }
        // Pinned rows are retained at their logical document positions, never stacked into the visible range.
        var positioned: [(String, NSView, Int)] = []
        for (id, row) in rows { if let i = entryPositions["item:" + id] { position(row, at: i); positioned.append(("item:" + id, row, i)) } }
        for (key, card) in cards { if let i = entryPositions[key] { position(card, at: i); positioned.append((key, card, i)) } }
        positioned.sort { $0.2 < $1.2 }; order = positioned.map(\.1); document.updateVirtual(positioned)
        let retained = desired.union(rows.keys.map { "item:" + $0 })
        for key in preparedKeys.subtracting(retained) {
            if let i = entryPositions[key] {
                entries[i].prepared = nil
                // Only the bounded active tail may retain a measuring stack while outside overscan.
                if i < entries.count - 8 || entries[i].item?.status != "running" { entries[i].stream = nil }
            }
        }
        preparedKeys = retained
        updateLatest()
    }
    private func mountEntry(_ index: Int, preparedOverride: NativeTranscriptPreparedRow? = nil, reconfigure: Bool = true) {
        let entry = entries[index]
        if let item = entry.item, let itemIndex = entry.itemIndex {
            // Pure scrolling changes document positions, not row values or action routing. Model/appearance/
            // geometry refreshes still configure every mounted row, including rows pinned by an interaction.
            if !reconfigure, preparedOverride == nil, let row = rows[item.id], row.superview === document {
                position(row, at: index)
                return
            }
            let row = rows[item.id] ?? rowPool.popLast() ?? NativeTranscriptRow()
            if row.isHidden { row.isHidden = false }
            if row.superview == nil { document.addSubview(row) }
            row.onToggle = { [weak self] in self?.setExpanded(!(self?.expanded.contains(item.id) ?? false), itemID: item.id) }
            row.onReview = { [weak self] in
                guard let self else { return }
                if let onReviewChanges = self.onReviewChanges { onReviewChanges(item); return }
                if !self.reviewedChanges.insert(item.id).inserted { self.reviewedChanges.remove(item.id) }
                self.refresh(preservingOffset: true)
            }
            row.onRevert = { [weak self] in self?.revert(item) }
            row.onEdit = onEditMessage == nil && onUserMessageAction == nil && messageDraftTarget == nil ? nil : { [weak self] in self?.performUserMessageAction(.edit, itemID: item.id) }
            row.onFork = onForkMessage == nil && onUserMessageAction == nil ? nil : { [weak self] in self?.performUserMessageAction(.fork, itemID: item.id) }
            row.allowsRevert = !renderConversation.isLiveConversation || onRevertChanges != nil
            let before = row.configurationCount
            let prepared = preparedOverride ?? measureEntry(index, retainingText: true)
            row.configure(shownItem(entry), sourceItem: item, index: itemIndex, items: renderConversation.items, width: lastWidth,
                expanded: entry.expanded, codeStyle: codeStyle, prepared: prepared, fallbackTimestamp: entry.firstSeen)
            configurationCounts[item.id, default: 0] += row.configurationCount - before
            row.applyFlightHidden(hiddenFlightParts[item.id] ?? [], textHidden: hiddenText.contains(item.id))
            row.applyHiddenSourceRanges(hiddenTextRanges[item.id] ?? [])
            rows[item.id] = row; position(row, at: index)
        } else {
            let card = cards[entry.key] ?? retainedDecisionCards[entry.key] ?? NativeTranscriptCard()
            card.onVisualChange = { [weak self] in self?.captureRevision &+= 1 }
            configureCard(card, entry: entry)
            card.onHeightChange = { [weak self] in
                guard let self, let index = self.entryPositions[entry.key] else { return }
                self.entries[index].exact = false; self.refresh()
            }
            if card.isHidden { card.isHidden = false }
            if card.superview !== document { document.addSubview(card) }
            cards[entry.key] = card; retainedDecisionCards[entry.key] = card; externalCards[entry.key] = nil; position(card, at: index)
        }
    }
    private func position(_ view: NSView, at index: Int) {
        let origin = CGPoint(x: 0, y: (18 + heights.prefix(index)) * grid)
        let snapped = CGPoint(x: 0, y: origin.y.rounded() / grid)
        if view.frame.origin != snapped { view.frame.origin = snapped }
    }
    private func scheduleHeightRefinement() {
        if modeEpochFrozen || modeContentIsCatchingUp {return}
        guard refinementTask == nil, isPresentationVisible, !isDisposed, refinementCursor < entries.count else { return }
        refinementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            guard !Task.isCancelled, let self else { return }
            self.refinementTask = nil
            self.refineColdHeights(budget: 0.003)
            self.scheduleHeightRefinement()
        }
    }
    /// A bounded idle batch, also callable by offscreen tests without a window or a live backend.
    func refineColdHeights(budget: TimeInterval) {
        guard !refreshing, !isDisposed, isPresentationVisible else { return }
        refreshing = true
        defer { refreshing = false }
        let start = CACurrentMediaTime(), previous = scrollOffset, anchor = readingAnchor(), follow = shouldFollowEnd && isAtEnd
        let modeOrigin=modeFollowOrigin()
        while refinementCursor < entries.count {
            measureEntry(refinementCursor, retainingText: false); refinementCursor += 1
            if CACurrentMediaTime() - start >= budget { break }
        }
        resizeDocument(); restoreViewport(previous: previous, anchor: followsEnd ? anchor : nil, follow: follow)
        assembleViewport(follow: follow, preservePixels: !followsEnd)
        continueModeFollow(modeOrigin,following:follow)
    }
    /// Logical geometry does not require a mounted cell. Useful for hosts/tests scrolling directly to a message.
    /// Logical row indices already identify sources, including cold/offscreen rows. Validate against the model
    /// so a structural edit awaiting refresh still uses the authoritative fallback.
    func sourceItemIndex(_ itemID: String) -> Int? {
        if let position = entryPositions["item:" + itemID], let index = entries[position].itemIndex,
           renderConversation.items.indices.contains(index), renderConversation.items[index].id == itemID { return index }
        return renderConversation.transcriptItemIndex(itemID)
    }
    func sourceItem(_ itemID: String) -> TranscriptItem? {
        sourceItemIndex(itemID).map { renderConversation.items[$0] }
    }
    func itemFrame(itemID: String) -> CGRect? {
        guard let i = entryPositions["item:" + itemID] else { return nil }
        return CGRect(x: 0, y: 18 + heights.prefix(i), width: lastWidth, height: entries[i].height)
    }
    func scrollToItem(itemID: String) {
        guard let frame = itemFrame(itemID: itemID) else { return }
        let nested = refreshing; refreshing = true
        scrollOffset = CGPoint(x: 0, y: frame.minY)
        assembleViewport()
        refreshing = nested; scheduleHeightRefinement()
    }
    var mountedRowCount: Int { rows.count }
    var pooledRowCount: Int { rowPool.count }
    var exactHeightCount: Int { entries.filter(\.exact).count }
    /// Whether an item's row is mounted or within the overscan, without mounting it.
    func itemNearViewport(_ itemID: String) -> Bool {
        guard let i = entryPositions["item:" + itemID] else { return false }
        return rows[itemID] != nil || overscanRange().contains(i)
    }
    /// Offscreen flight/selection queries get one temporary cell; they never force the history to mount.
    private func withRow<Result>(_ itemID: String, _ body: (NativeTranscriptRow) -> Result) -> Result? {
        guard let i = entryPositions["item:" + itemID] else { return nil }
        let temporary = rows[itemID] == nil
        if temporary, let item = entries[i].item, let index = entries[i].itemIndex {
            // Do not refine global heights during a multi-part flight capture. Offscreen queries must not move
            // previously captured/visible glyphs, change the scrollbar or depend on the order of source queries.
            let prepared = NativeTranscriptPreparedRow(item: shownItem(entries[i]), source: item, index: index,
                items: renderConversation.items, width: lastWidth, expanded: entries[i].expanded, style: codeStyle)
            mountEntry(i, preparedOverride: prepared)
        }
        guard let row = rows[itemID] else { return nil }
        let result = body(row)
        if temporary, !row.preventsRecycling {
            retireAccessibilitySubtree(row); row.prepareForReuse(); rows[itemID] = nil
            entries[i].prepared = nil
            // As many as an all-compact overscan mounts: real histories are mostly one-line activity rows, and a row costs
            // more to create than most of the work that reuses it.
            // Keep hidden pool cells in the same document: recycling need not tear down/recreate AppKit backing.
            if rowPool.count < 125 && !row.preventsRecycling { rowPool.append(row) }
            else { row.removeFromSuperview() }
        }
        return result
    }
    @discardableResult func performUserMessageAction(_ kind:NativeUserMessageAction.Kind,itemID:String)->Bool {
        guard presentationActive,!isHiddenOrHasHiddenAncestor,let index=renderConversation.items.firstIndex(where:{$0.id == itemID}),renderConversation.items[index].rowKind == .user else{return false}
        let item=renderConversation.items[index]
        if kind == .edit {
            guard onEditMessage != nil || onUserMessageAction != nil || messageDraftTarget != nil else{return false}
            if let target=messageDraftTarget {guard target.stageUserMessageDraft(item) else{return false}}
        } else {guard onForkMessage != nil || onUserMessageAction != nil else{return false}}
        let request=NativeUserMessageAction(kind:kind,conversationID:renderConversation.id,message:item,historyBefore:Array(renderConversation.items.prefix(index)))
        if let onUserMessageAction{onUserMessageAction(request)}
        else if kind == .edit{onEditMessage?(item)}else{onForkMessage?(item)}
        return true
    }
    func setExpanded(_ value: Bool, itemID: String) {
        if value { expanded.insert(itemID) } else { expanded.remove(itemID) }
        refresh(preservingOffset: true)
    }
    func isExpanded(itemID: String) -> Bool { expanded.contains(itemID) }
    func selectedRange(itemID: String) -> NSRange? { withRow(itemID) { $0.body.selectedRange() } }
    func setSelectedRange(_ range: NSRange, itemID: String) {
        _ = withRow(itemID) { row in
            row.body.setSelectedRange(NSIntersectionRange(range, NSRange(location: 0, length: (row.body.string as NSString).length)))
        }
    }
    func displayedText(itemID: String) -> String? { withRow(itemID) { $0.body.string } }
    func setTextHidden(_ hidden: Bool, itemID: String) {
        if hidden { hiddenText.insert(itemID) } else { hiddenText.remove(itemID) }
        rows[itemID]?.applyFlightHidden(hiddenFlightParts[itemID] ?? [], textHidden: hidden)
    }
    /// Raw item.text UTF-16, exactly like glyphFrames. Hidden intervals form a union; restoring subtracts the interval.
    /// Drawing only, including any code/selection backing inside the source's pixel crop. Capture the source first.
    func setTextHidden(_ hidden: Bool, itemID: String, range: NSRange) {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              let item = sourceItem(itemID) else { return }
        let count = (item.text as NSString).length
        guard range.location < count else { return }
        let interval = range.location..<(range.location + min(range.length, count - range.location))
        if hidden { hiddenTextRanges[itemID, default: []].insert(integersIn: interval) }
        else { hiddenTextRanges[itemID]?.remove(integersIn: interval) }
        rows[itemID]?.applyHiddenSourceRanges(hiddenTextRanges[itemID] ?? [])
    }

    /// Capture before hiding, at the endpoint's backing scale. Chevron and row decoration stay in the base.
    func flightSource(_ part: NativeFlightPart, itemID: String, scale: CGFloat) -> NativeFlightSource? {
        prepareForSnapshot()
        return withRow(itemID) { row -> NativeFlightSource? in
            guard let view = row.flightView(part), !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            return NativeFlightSource(rect: convert(view.bounds, from: view), image: NativeViewBitmap.capture(view, scale: scale))
        } ?? nil
    }
    /// Drawing only: no relayout, scroll, selection or first-responder changes. Persists across refresh.
    func setFlightSourceHidden(_ hidden: Bool, part: NativeFlightPart, itemID: String) {
        if hidden { hiddenFlightParts[itemID, default: []].insert(part) }
        else { hiddenFlightParts[itemID]?.remove(part) }
        rows[itemID]?.applyFlightHidden(hiddenFlightParts[itemID] ?? [], textHidden: hiddenText.contains(itemID))
    }
    /// A synchronous capture may hide additional glyphs without clearing visibility owned by its caller.
    struct FlightVisibility:Equatable {
        fileprivate let text: Set<String>
        fileprivate let ranges: [String: IndexSet]
        fileprivate let parts: [String: Set<NativeFlightPart>]

        /// Only continuation changes whole-goal omission into the raw ranges actually carried by flights.
        /// Preserve any omission already owned by the caller before the capture borrowed its visibility.
        func replacingGoalText(with carried:[String:IndexSet],preserving original:Self)->Self {
            var whole=text,partial=ranges
            for (id,indices) in carried {
                if !original.text.contains(id) {whole.remove(id)}
                partial[id,default:[]].formUnion(indices)
            }
            return Self(text:whole,ranges:partial,parts:parts)
        }
    }
    func flightVisibility() -> FlightVisibility { .init(text: hiddenText, ranges: hiddenTextRanges, parts: hiddenFlightParts) }
    func restoreFlightVisibility(_ state: FlightVisibility) {
        hiddenText = state.text; hiddenTextRanges = state.ranges; hiddenFlightParts = state.parts
        for (id, row) in rows {
            row.applyFlightHidden(hiddenFlightParts[id] ?? [], textHidden: hiddenText.contains(id))
            row.applyHiddenSourceRanges(hiddenTextRanges[id] ?? [])
        }
    }

    /// Capture the actual viewport, including selection and native controls, at the hand-off scale.
    func snapshot(scale: CGFloat) -> CGImage {
        prepareForSnapshot()
        func cards(_ view:NSView)->[NativeTranscriptCard] {
            view.subviews.flatMap{($0 as? NativeTranscriptCard).map{[$0]} ?? cards($0)}
        }
        let rails=cards(pinnedDocument).filter(\.isApprovalCard)
        NativeTranscriptCard.drawsMotionPlate=true
        rails.forEach{$0.setGlassHiddenForCapture(true)}
        defer {NativeTranscriptCard.drawsMotionPlate=false;rails.forEach{$0.setGlassHiddenForCapture(false);$0.needsDisplay=true}}
        return NativeViewBitmap.capture(self, scale: scale)
    }
    func prepareForSnapshot(holdingOffset: Bool = true) {
        layoutSubtreeIfNeeded()
        if refreshDeferred || renderedRevision != renderConversation.revision || entries.isEmpty && !renderConversation.items.isEmpty { refresh(preservingOffset: holdingOffset,allowHidden:true) }
        for row in rows.values { row.body.layoutManager?.ensureLayout(for: row.body.textContainer!) }
        displayIfNeeded()
    }

    /// Raw item UTF-16 ranges in, raw ranges and viewport top-left rectangles out. Offscreen lines stay offscreen.
    func glyphFrames(itemID: String, range: NSRange) -> [(range: NSRange, rect: CGRect)] {
        prepareForSnapshot()
        return withRow(itemID) { row in
        guard let manager = row.body.layoutManager, let container = row.body.textContainer,
              range.location != NSNotFound, range.location >= 0, range.length > 0 else { return [] }
        let sourceLength = (row.item.text as NSString).length
        guard range.location < sourceLength else { return [] }
        let end = range.location + min(range.length, sourceLength - range.location)
        let offsets = row.sourceOffsets
        guard let start = offsets.firstIndex(where: { $0 >= range.location && $0 < end }),
              let last = offsets.lastIndex(where: { $0 >= range.location && $0 < end }) else { return [] }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: start, length: last - start + 1), actualCharacterRange: nil)
        var output: [(range: NSRange, rect: CGRect)] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
            let cut = NSIntersectionRange(lineGlyphs, glyphs)
            guard cut.length > 0 else { return }
            let chars = manager.characterRange(forGlyphRange: cut, actualGlyphRange: nil)
            guard chars.location < offsets.count else { return }
            let sourceStart = max(range.location, offsets[chars.location])
            let sourceEnd = min(end, offsets[min(offsets.count - 1, NSMaxRange(chars) - 1)] + 1)
            guard sourceEnd > sourceStart else { return }
            var rect = manager.boundingRect(forGlyphRange: cut, in: container)
            rect.origin.y = line.minY; rect.size.height = line.height
            rect.origin.x += row.body.textContainerOrigin.x; rect.origin.y += row.body.textContainerOrigin.y
            output.append((NSRange(location: sourceStart, length: sourceEnd - sourceStart), self.convert(rect, from: row.body)))
        }
        return output
        } ?? []
    }

    /// Activity wording is generated text; these ranges index displayedText rather than the raw item.
    func displayedGlyphFrames(itemID: String, range: NSRange) -> [(range: NSRange, rect: CGRect)] {
        prepareForSnapshot()
        return withRow(itemID) { row in
        guard let manager = row.body.layoutManager, let container = row.body.textContainer,
              range.location != NSNotFound, range.location >= 0, range.location < (row.body.string as NSString).length,
              range.length > 0 else { return [] }
        let length = min(range.length, (row.body.string as NSString).length - range.location)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.location, length: length), actualCharacterRange: nil)
        var output: [(range: NSRange, rect: CGRect)] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
            let cut = NSIntersectionRange(lineGlyphs, glyphs)
            guard cut.length > 0 else { return }
            var rect = manager.boundingRect(forGlyphRange: cut, in: container)
            rect.origin.y = line.minY; rect.size.height = line.height
            rect.origin.x += row.body.textContainerOrigin.x; rect.origin.y += row.body.textContainerOrigin.y
            output.append((manager.characterRange(forGlyphRange: cut, actualGlyphRange: nil), self.convert(rect, from: row.body)))
        }
        return output
        } ?? []
    }

    /// The exact native text, with transparent backing, for flights that must leave the bubble behind.
    func textSnapshot(itemID: String, scale: CGFloat) -> (image: CGImage, rect: CGRect)? {
        prepareForSnapshot()
        return withRow(itemID) { row -> (image: CGImage, rect: CGRect)? in
            guard !row.body.isHidden else { return nil }
            return (NativeViewBitmap.capture(row.body, scale: scale), convert(row.body.bounds, from: row.body))
        } ?? nil
    }

    private func approvalCard(_ approval: Approval, old: NativeTranscriptCard?, width: CGFloat,attach:Bool=true) -> NativeTranscriptCard {
        let card = old ?? NativeTranscriptCard()
        card.prepareForPresentation(scale:window?.backingScaleFactor)
        card.onVisualChange = { [weak self] in self?.captureRevision &+= 1 }
        if attach { card.setApprovalSource(nil) }
        if attach,card.superview == nil { document.addSubview(card) }
        card.chatApprovalAvailable=renderConversation.backendThreadID != nil
        let enabled = !(store?.isOffline(conversation) ?? false) && (!renderConversation.isLiveConversation || onApproval != nil || onApprovalValue != nil)
        let valueResponse: ((JSONValue) -> Void)? = !renderConversation.isLiveConversation || onApprovalValue != nil
            ? { [weak self] value in self?.respondValue(approval, value: value) } : nil
        card.configureApproval(approval, width: width, enabled: enabled, respondValue: valueResponse) { [weak self] action in self?.respond(approval, action: action) }
        return card
    }
    func retireExternalDecisionCards() {
        for card in externalCards.values { card.isHidden = true; card.removeFromSuperview() }
    }
    private func layoutPinnedDecisions() {
        guard decisionCardsAtBottom, bounds.width > 0 else {
            pinnedScroll.isHidden = true; pinnedReserve = 0
            for card in pinnedDocument.subviews { card.removeFromSuperview() }
            return
        }
        // ApprovalCard's own plate has 14 pt margins. Passing column+4 puts its edge exactly 12 pt inside the
        // column; its 560 pt product cap is a 588 pt control width. The 34 pt bottom includes our 22 pt bleed.
        let width = min(588, bounds.width + 4)
        let controls = externalDecisionCards(width:width,source:.init(project:store?.project(renderConversation.projectID)?.name ?? "No Project",conversation:renderConversation.title,isOtherConversation:false,canShowConversation:!renderConversation.archived))
        let cards = controls.filter { !$0.isApprovalCard } + controls.filter(\.isApprovalCard)
        var y: CGFloat = 0
        for card in cards {
            card.semanticParent = nil
            if card.isApprovalCard {
                card.setApprovalSource(.init(project: store?.project(renderConversation.projectID)?.name ?? "No Project",
                    conversation: renderConversation.title, isOtherConversation: false, canShowConversation: !renderConversation.archived))
            }
            if card.superview !== pinnedDocument { pinnedDocument.addSubview(card) }
            card.frame.origin = CGPoint(x: 0, y: (y * grid).rounded() / grid)
            card.onHeightChange = { [weak self] in self?.refresh() }
            y += card.frame.height + 8
        }
        let height = max(0, y - (cards.isEmpty ? 0 : 8))
        pinnedDocument.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let viewport = min(height, max(0, bounds.height - 34))
        pinnedReserve = cards.isEmpty ? 0 : viewport + 24
        pinnedScroll.frame = CGRect(x: ((bounds.width - width) / 2 * grid).rounded() / grid,
            y: ((bounds.maxY - 34 - viewport) * grid).rounded() / grid, width: width, height: viewport)
        pinnedScroll.isHidden = cards.isEmpty
    }
    /// One retained set of controls, rendered in Normie's bottom cluster; inline mode remains the Organic default.
    func externalDecisionCards(width:CGFloat,includeQuestion:Bool=true,source:NativeApprovalSource?=nil,showConversation:(()->Void)?=nil)->[NativeTranscriptCard]{
        var next:[String:NativeTranscriptCard]=[:],result:[NativeTranscriptCard]=[]
        for approval in renderConversation.approvals{let key="approval:"+approval.id
            let old=externalCards[key] ?? retainedDecisionCards[key] ?? NativeTranscriptCard()
            old.prepareForPresentation(scale:window?.backingScaleFactor)
            if let source {old.setApprovalSource(source,showConversation:showConversation,reconfigure:false)}
            let card=approvalCard(approval,old:old,width:width,attach:false);next[key]=card;retainedDecisionCards[key]=card;cards[key]=nil;result.append(card)}
        if renderConversation.question != nil || renderConversation.userInput != nil {
            let request=renderConversation.userInput ?? UserInputRequest(id:"fixture-question:"+renderConversation.id,questions:[.init(id:"answer",header:"Question",prompt:renderConversation.question ?? "",options:[])])
            let key="question:"+request.id,card=externalCards[key] ?? retainedDecisionCards[key] ?? NativeTranscriptCard()
            card.onVisualChange = { [weak self] in self?.captureRevision &+= 1 }
            card.configureQuestion(request,width:width,enabled:!(store?.isOffline(conversation) ?? false) && (!renderConversation.isLiveConversation || onAnswer != nil)){[weak self] values in self?.answer(request,answers:values)};next[key]=card;retainedDecisionCards[key]=card;cards[key]=nil;if includeQuestion{result.append(card)}
        }
        for (key,card) in externalCards where next[key] == nil{card.removeFromSuperview()};externalCards=next;for card in result { card.isHidden = false };return result
    }
    private func respondValue(_ approval: Approval, value: JSONValue) {
        guard !isDisposed, presentationActive, !modeEpochFrozen else{return}
        guard let current = conversation.approvals.first(where: { $0.id == approval.id }), !current.submitting,
              current.request == approval.request, current.method == approval.method else { return }
        guard CoreResponseValidation.approval(value,request:current) == nil else{return}
        elicitationResponses[approval.id]=value
        elicitationExchanges[approval.id] = .init(request:approval,response:value)
        if let onApprovalValue { onApprovalValue(approval, value); refresh(); return }
        guard !conversation.isLiveConversation else { return }
        elicitationResponses[approval.id] = value
        let word=value["decision"]?.stringValue
        respond(approval, action: word == "decline" ? .decline:word == "cancel" ? .cancel:.accept)
    }
    private func changed() {
        if let store { store.changed(conversation) } else { conversation.revision += 1 }
        refresh()
    }
    private func respond(_ approval: Approval, action: ApprovalAction) {
        guard !isDisposed, presentationActive, !modeEpochFrozen else{return}
        guard let current = conversation.approvals.first(where: { $0.id == approval.id }), !current.submitting,
              current.request == approval.request, current.method == approval.method else { return }
        if approval.method == "elicitation/create", action != .accept {
            let value:JSONValue=["action":.string(action == .decline ? "decline":"cancel")]
            guard CoreResponseValidation.approval(value,request:current) == nil else{return}
            elicitationResponses[approval.id]=value;elicitationExchanges[approval.id] = .init(request:approval,response:value)
            if let onApprovalValue{onApprovalValue(approval,value);refresh();return}
        }
        if let onApproval { onApproval(approval, action); refresh(); return }
        guard !conversation.isLiveConversation else { return }
        conversation.approvals.removeAll { $0.id == approval.id }
        if let i = conversation.items.firstIndex(where: { $0.id == approval.toolItemID }) {
            conversation.items[i].status = action == .accept ? nil : action == .decline ? "declined" : "cancelled"
            conversation.items[i].revision += 1
        }
        changed()
    }
    private func answer(_ request: UserInputRequest, answers: [String: [String]]) {
        guard !isDisposed, presentationActive, !modeEpochFrozen else{return}
        let current = conversation.userInput ?? conversation.question.map {
            UserInputRequest(id: "fixture-question:" + conversation.id, questions: [.init(id: "answer", header: "Question", prompt: $0, options: [])])
        }
        guard let current, current.id == request.id, current.questions == request.questions, !current.submitting else { return }
        guard CoreResponseValidation.answers(answers,request:current) == nil else{return}
        if let onAnswer { onAnswer(request, answers); refresh(); return }
        guard !conversation.isLiveConversation else { return }
        let text = request.questions.compactMap { answers[$0.id]?.joined(separator: ", ") }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        conversation.items.append(.init(id: request.id + "-answer", turnID: conversation.items.last?.turnID ?? "", kind: .user, text: text))
        conversation.question = nil; conversation.userInput = nil; changed()
    }
    private func revert(_ item: TranscriptItem) {
        if let onRevertChanges { onRevertChanges(item); refresh(); return }
        guard !conversation.isLiveConversation, let i = conversation.items.firstIndex(where: { $0.id == item.id }) else { return }
        let paths = Set(item.text.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
        conversation.changes.removeAll { paths.contains($0.path) }
        conversation.items[i].status = TranscriptPresentation.changesReverted; conversation.items[i].revision += 1; changed()
    }
}
