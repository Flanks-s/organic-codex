import AppKit

/// The window's two modes (product DetailRoot + OrganicSplitViewController, f004, f027): Normie, Sol's workbench with
/// its sidebar, detail and inspector in a system split view under a toolbar; and Organic, the Auto scene over the whole
/// window with only the traffic lights. Both share one store and one set of composer sessions, so a conversation's
/// editor, draft and selection carry across. Hiding the sidebar is the switch to Organic, showing it the way back.
@MainActor final class WindowShell: NSViewController, NSToolbarDelegate, NSUserInterfaceValidations, NSToolbarItemValidation {
    var onTurnCost:((String,Double)->Void)?
    /// AppKit searches the window's content controller when the window itself is first responder.
    @objc func toggleInspector(_ sender:Any?) { split.toggleInspector(sender) }
    func validateUserInterfaceItem(_ item:any NSValidatedUserInterfaceItem)->Bool {
        guard item.action == #selector(toggleInspector(_:)) else { return true }
        return split.validateUserInterfaceItem(item)
    }
    func validateToolbarItem(_ item:NSToolbarItem)->Bool { validateUserInterfaceItem(item) }

    enum Mode: String { case normie, organic }

    final class Split: NSSplitViewController {
        weak var shell: WindowShell?
        // The sidebar command is the mode switch: a Normie window without its sidebar is Organic.
        override func toggleSidebar(_ sender: Any?) { shell?.toggleSidebar(sender) }
        override func toggleInspector(_ sender: Any?) {
            guard shell?.mode == .normie,shell?.modeContentInputBlocked != true else { return }
            super.toggleInspector(sender)
        }
        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(toggleInspector(_:)) {
                if shell?.modeContentInputBlocked == true {return shell?.contentInspectorEnabled ?? true}
                if shell?.toolbarNormieOwner != true {return false}
            }
            return super.validateUserInterfaceItem(item)
        }
    }

    final class NativeSplitSurface:NSSplitView {
        var acceptsBodyInput:(()->Bool)?
        override func hitTest(_ point:NSPoint)->NSView? {acceptsBodyInput?() == false ? nil:super.hitTest(point)}
        override func drawDivider(in rect:NSRect) {if acceptsBodyInput?() != false {super.drawDivider(in:rect)}}
    }
    /// The split remains a stable sidebar ancestor; only its content items belong to Normie body ownership.
    private var normieBodyRoot:NSView {
        ModeFlight.orreryEnabled ? workbench.detail.view:split.view
    }
    private var normieBodyRoots:[NSView] {
        ModeFlight.orreryEnabled ? [workbench.detail.view,workbench.inspector.view]:[split.view]
    }
    final class Container: NSView {
        override var acceptsFirstResponder:Bool {true}
        var blocksContentInput:(()->Bool)?
        var inactiveBody:(()->NSView?)?
        override func hitTest(_ point:NSPoint)->NSView? {
            if blocksContentInput?() == true {return self}
            let hit=super.hitTest(point)
            // NSSplitViewController's empty wrapper stays above Organic after its body rejects input.
            if let body=inactiveBody?(),hit === body {
                let local=convert(point,from:superview)
                for child in subviews.reversed() where child !== body {if let candidate=child.hitTest(local) {return candidate}}
            }
            return hit
        }
        override var isFlipped: Bool { true }
    }

    let split = Split()
    private var inspectorCollapseObservation: NSKeyValueObservation?
    let workbench: NormieWorkbench
    let organic: RootView
    let scene: AutoScene
    private(set) var mode: Mode
    var onModeChange: ((Mode) -> Void)?
    var onBrowserModeWillChange: ((Mode) -> Void)?
    /// Hide / Show Sidebar's flights, over everything.
    let flight = ModeFlight()
    private let sidebarExposure = M10SidebarExposure()
    private var modeProbe: ModeSignposts.Trace?
    private var normieNativeStaged=false
    private var normieEndpointStaged=false
    private var admissionSidebarBuilder:ModeSurfaceBuilder?
    private var admissionSidebarKey=""
    private var admissionSidebarImage:CGImage?
    private var admittedMode: Mode
    private let admission = ModeAdmissionGate()
    private let sourcePlate = ModeHandoffPlate(frame: .zero)
    private var contentSession:ModeContentSession?
    private let contentPicture=ModeContentPictureView(frame:.zero)
    private let contentDockExposure=ModeContentDockExposure()
    private let contentComposerInk=ModeComposerInkRetainer()
    private let contentSidebarCutout=ModeContentSidebarCutout()
    private var contentWarm:ModeWarmPicture?
    private var contentWarmKey:ModeFlightPictureKey?
    private var contentCaptureGeneration:UInt64=0
    private var contentCapturing=false,contentOpening=false,contentFinishing=false
    private var contentEpochHeld=false
    private var contentEpochRevision:String?
    private var contentTrace:ModeSignposts.Trace?
    private var contentCaptureTask:DispatchWorkItem?
    private var contentPreparedSourceKey:ModePreparationKey?
    private var contentSessionGeneration:UInt64=0
    private var contentEndpointChecks=0
    private var contentLastKey:ModeFlightPictureKey?
    private var contentApprovalSignature=""
    private var contentPendingReplay:Set<String>=[]
    private var contentReplayScheduled=false
    private var contentCaptureCosts:[[String:Any]]=[]
    private var contentWorkCosts:[[String:Any]]=[]
    private var contentFadeLatencies:[[String:Any]]=[]
    private var contentInvalidations:[String:Int]=[:]
    private let departureSurfaces=ModeDepartureSurfaces()
    var modeDepartureScreenStates:[[String:Any]] {departureSurfaces.screenStates}
    private var contentKeyTime=0.0
    private var contentInputEntered:Double?
    private var contentFirstSubmitMS:[Double]=[]
    private var contentFocusConversation:String?
    private var contentSessionCaptureCount=0
    private var contentMountCount=0
    private var contentMidPhaseMounts=0
    private var contentInitialMountGeneration:UInt64=0
    private var contentFrameTime=0.0
    private weak var contentFocusResponder:NSResponder?
    private weak var contentFocusField:NSTextField?
    private weak var contentFocusOwner:NSResponder?
    private weak var contentChrome:NSView?
    private var contentChromeInstalled=false
    private var contentFocusRestoreGeneration:UInt64=0
    private var contentDetachedOwner:Mode?
    private var contentOrganicReady:AutoScene.ModeTargetPlan?
    private var contentPreparedNormieLayout:[CGFloat]?
    private var contentEndpointMountPending=false
    private var contentDeferredSelection:String?
    private var contentSelectionTarget:String?
    private var contentSelectionPlan:AutoScene.ModeTargetPlan?
    private var contentSelectionPreparing=false
    private var contentEpochCompletionPending=false
    private var contentInspectorEnabled=true
    private var contentInspectorWasOpen=false
    private var contentWantsSearch=false
    private weak var contentSearchPredecessor:NSResponder?
    var modeContentInputBlocked:Bool {contentOpening || contentSession != nil}
    var allowsModeContentTransfer:Bool {!modeContentInputBlocked && !contentEpochHeld}
    private var toolbarNormieOwner:Bool {
        if !ModeFlight.orreryEnabled {return mode == .normie}
        if contentOpening {return contentPicture.superview != nil || admittedMode == .normie}
        if contentSession != nil {return true} // The same retained toolbar fades as one surface.
        return admittedMode == .normie
    }
    /// A member command is a new user intent, independent of the picture's fixed selection/epoch.
    @discardableResult func deferModeSelection(_ id:String)->Bool {
        guard ModeFlight.orreryEnabled,modeContentInputBlocked,scene.store.conversation(id)?.archived == false else {return false}
        contentDeferredSelection=id;contentWantsSearch=false
        contentTrace?.record("ModeContentSelection",detail:"requested=\(id) mode=\(mode.rawValue)")
        return true
    }
    /// Prepare a late member intent while the old epoch is still retained. No capture/layout is added to the key.
    private func prepareDeferredOrganicSelection(_ id:String) {
        guard mode == .organic,admittedMode == .organic,contentEpochHeld,!contentOpening,id != scene.current,scene.store.conversation(id)?.archived == false else {return}
        if contentSelectionTarget == id,contentSelectionPreparing || contentSelectionPlan.map({scene.modeTargetIsValid($0)}) == true {return}
        contentSelectionTarget=id;contentSelectionPlan=nil;contentSelectionPreparing=true
        let generation=contentSessionGeneration
        var plan:AutoScene.ModeTargetPlan?
        var row=0,rowsReady=false,nativeReady=false,editorReady=false,editorLayoutReady=false
        func step() {
            guard self.contentSessionGeneration == generation,self.contentSelectionTarget == id else {return}
            guard self.mode == .organic,self.contentEpochHeld,self.contentDeferredSelection == id,self.scene.store.conversation(id)?.archived == false else {self.contentSelectionPreparing=false;return}
            let began=CACurrentMediaTime()
            if plan == nil {plan=self.scene.beginModeTarget(selected:id)}
            guard let target=plan,self.scene.modeTargetIsValid(target) else {self.contentSelectionPreparing=false;return}
            let ready:Bool
            if !target.ready {_=self.scene.prepareModeTargetStep(target);ready=false}
            else if !rowsReady {
                if let pair=target.columns.first(where:{$0.0.conversation.id == id}) {rowsReady=pair.0.native.prepareModeRow(width:pair.1.area.width,cursor:&row)} else {rowsReady=true}
                ready=false
            } else if !nativeReady {
                // No shared view changes parents during a partial body fade.
                if self.contentSession?.atDestination(self.contentNow) == true {
                    nativeReady=self.workbench.transcriptSessions.withModeContentMountPermission {self.scene.prepareHiddenModeSelection(target,id:id)}
                }
                ready=false
            } else if !editorReady {
                if let conversation=self.scene.conversation(id) {_=self.scene.composer(for:conversation)}
                editorReady=true;ready=false
            } else if !editorLayoutReady {
                if let composer=self.scene.composers.existingComposer(for:id),
                   let index=target.order.firstIndex(of:id),target.layout.bars.indices.contains(index) {
                    self.scene.dock.prepareModeSelectionComposer(composer,id:id,bar:target.layout.bars[index],slot:index,count:target.layout.bars.count,focused:target.layout.focused)
                }
                editorLayoutReady=true;ready=true
            } else {ready=true}
            self.recordContentWork("native.selection.prepare",began:began)
            if ready {
                self.contentSelectionPlan=target;self.contentSelectionPreparing=false
                self.contentTrace?.record("ModeContentSelectionReady",detail:"id=\(id) frozen=\(self.contentEpochHeld) valid=\(self.scene.modeTargetIsValid(target))")
                if !self.flight.running {self.advanceContentSession(at:self.contentNow,flightFinished:true)}
            }
            else {ModeContentWorkBoundary.schedule(in:self.view,interval:self.flight.presentationInterval) {step()}}
        }
        ModeContentWorkBoundary.schedule(in:view,interval:flight.presentationInterval) {step()}
    }
    /// The menu and offscreen NSMenuItem target/action share this exact member routing.
    func selectModeMember(at index:Int) {
        let order=scene.order
        guard order.indices.contains(index) else {return}
        let id=order[index]
        if deferModeSelection(id) {return}
        if mode == .normie {_=workbench.select(id)}
        else if let column=scene.columns.firstIndex(where:{$0.conversation.id == id}) {scene.switchTo(column,reason:"menu")}
        else {scene.land(id,reason:"menu")}
    }
    private func clearContentFocus() {
        contentFocusConversation=nil;contentFocusResponder=nil;contentFocusOwner=nil;contentFocusField=nil
    }
    private func restoreSelectedContentFocus(_ id:String?,target:Mode) {
        #if M11_MODE_SELFTEST
        ModeFadeCloseTwoVerification.beforeSelectedFocus?()
        #endif
        guard let id,scene.store.conversation(id)?.archived == false,let window=view.window else {return}
        contentFocusRestoreGeneration &+= 1;let generation=contentFocusRestoreGeneration
        let began=CACurrentMediaTime()
        contentTrace?.record("ModeContentFocusPending",detail:"id=\(id) mode=\(target.rawValue)")
        func attempt(_ remaining:Int) {
            guard self.contentFocusRestoreGeneration == generation,self.mode == target,!self.modeContentInputBlocked,
                  self.scene.store.conversation(id)?.archived == false else {return}
            let responder=window.firstResponder
            let search=self.workbench.sidebar.searchField
            if target == .normie,!search.isHiddenOrHasHiddenAncestor,
               responder === search || (responder != nil && responder === search.currentEditor()) {
                self.contentTrace?.record("ModeContentFocusYielded",detail:"id=\(id) reason=visible-search");return
            }
            let composer=target == .normie ? self.workbench.detail.composer:self.scene.composers.existingComposer(for:id)
            // A later explicit editor intent wins. A detached field editor/window is not a new intent.
            if let editor=responder as? NativeComposerTextView,editor !== composer?.textView,
               let event=NSApp.currentEvent,event.timestamp>began,
               [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type) {
                self.contentTrace?.record("ModeContentFocusYielded",detail:"id=\(id) reason=later-pointer");return
            }
            let shown=target == .normie ? self.workbench.selectedConversation?.id:self.scene.current
            if shown == id,let composer,composer.window === window,!composer.isHiddenOrHasHiddenAncestor,
               !self.scene.isMoving || target == .normie {
                if window.makeFirstResponder(composer.textView),window.firstResponder === composer.textView {
                    self.contentTrace?.record("ModeContentFocusRestored",detail:"id=\(id) mode=\(target.rawValue)")
                    return
                }
            }
            if remaining == 120 || remaining == 60 {
                self.contentTrace?.record("ModeContentFocusWaiting",detail:"id=\(id) shown=\(shown ?? "nil") responder=\(responder.map {String(describing:type(of:$0))} ?? "nil") composerWindow=\(composer?.window === window) hidden=\(composer?.isHiddenOrHasHiddenAncestor ?? true) moving=\(self.scene.isMoving)")
            }
            guard remaining>0 else {self.contentTrace?.record("ModeContentFocusExpired",detail:"id=\(id)");return}
            ModeContentWorkBoundary.schedule(in:self.view,interval:self.flight.presentationInterval) {attempt(remaining-1)}
        }
        attempt(120)
    }
    /// Native reparenting may temporarily leave AppKit's unowned field editor as first responder.
    /// Preserve a real later editor/Search intent; otherwise recover the editor saved at the key.
    private var contentAdmissionResponder:NSResponder? {
        let current=view.window?.firstResponder
        if current is NativeComposerTextView {return current}
        if let editor=current as? NSTextView,editor.delegate is NSTextField {return current}
        if current is NSTextField {return current}
        return contentFocusResponder ?? current
    }
    private func rememberContentFocus() {
        guard let window=view.window else {return}
        contentWantsSearch=false
        contentFocusResponder=window.firstResponder;contentFocusOwner=window.firstResponder
        var ancestor=window.firstResponder as? NSView;contentFocusConversation=nil
        while let current=ancestor {if let composer=current as? NativeComposer {contentFocusConversation=composer.identity;break};ancestor=current.superview}
        contentFocusField=(window.firstResponder as? NSTextView)?.delegate as? NSTextField
    }
    private func restoreAdmissionResponder(_ responder:NSResponder?) {
        if contentWantsSearch,mode == .normie {
            // A Search command issued while the body is shielded is an explicit pending intent.
            // Native staging may temporarily focus/reparent an editor; that cannot consume it.
            workbench.sidebar.focusSearch();return
        }
        guard let window=view.window,let responder else {return}
        // Synchronous native admission owns only its own focus changes. Preserve a later Search/editor intent too.
        if let editor=responder as? NSTextView,let field=editor.delegate as? NSTextField,field.window === window,!field.isHiddenOrHasHiddenAncestor {window.makeFirstResponder(mode == .organic && field.isDescendant(of:workbench.sidebar.view) ? organic:field)}
        else if let target=responder as? NSView,target.window === window,!target.isHiddenOrHasHiddenAncestor {window.makeFirstResponder(responder)}
        else if responder === window || responder === organic {window.makeFirstResponder(mode == .organic ? organic:window)}
    }
    private func restoreContentFocus(ifUnchanged expected:NSResponder?) {
        guard let window=view.window,window.firstResponder === expected || window.firstResponder === window || window.firstResponder === view else {return}
        if let field=contentFocusField,field.window === window,!field.isHiddenOrHasHiddenAncestor {window.makeFirstResponder(field)}
        else if let responder=contentFocusResponder,let target=responder as? NSView,target.window === window,!target.isHiddenOrHasHiddenAncestor {window.makeFirstResponder(responder)}
    }
    private var contentNow:Double {flight.manualTime.map {max($0(),contentFrameTime)} ?? CACurrentMediaTime()}
    private var preparedSwitch: PreparedModeSwitch?
    private var lastFlightGeometry:PreparedModeSwitch?
    private var flightSourcePictures: [String:ModeSurfacePicture] = [:]
    private var flightSourceKeys: [String:ModeFlightPictureKey] = [:]
    private let turnSidebar=ModeTurnSidebar()
    private var sidebarBitmapRefreshPending=false
    #if M11_MODE_SELFTEST
    private var beforeTurnSidebarCommit:(()->Void)?
    private var sidebarBakeCount=0,endpointRefreshCount=0
    private var sidebarBakeMaximumMS=0.0
    #endif
    private struct ModeFlightPictureKey: Equatable {
        let size:CGSize,scale:CGFloat,appearance:Int,contrast:Int,selected:String,search:String
        let account:NormieAccount
        let models:[ModePreparationKey.Model]
        let deviceStatus:[String]
        let order:[String],rows:[String],current:String,sidebarScroll:CGPoint
        let viewports:[ModePreparationKey.Viewport]
        let flags:[String]
        let headerStates:[HeaderIslandState?],headerRects:[CGRect]
        let scheme:AutoScene.Scheme?
        var terminal=""
        init(_ key:ModePreparationKey,account:NormieAccount,search:String) {
            size=key.size;scale=key.scale;appearance=key.appearance;contrast=key.contrast
            deviceStatus=key.deviceStatus
            selected=key.selected;models=key.models;self.account=account;self.search=search
            order=key.order;rows=key.rows;current=key.current;sidebarScroll=key.sidebarScroll
            viewports=key.viewports;flags=key.flags;headerStates=key.headerStates;headerRects=key.headerRects;scheme=key.scheme
        }
    }
    private func flightPictureKey() -> ModeFlightPictureKey {
        var key=ModeFlightPictureKey(modePreparationKey(),account:workbench.account,search:workbench.sidebar.searchField.stringValue)
        key.terminal=workbench.detail.terminalPane.motionContentKey
        return key
    }
    private func bankFlightPicture(_ picture:ModeSurfacePicture,mode:String) {
        picture.modeName=mode
        if ModeFlight.orreryEnabled,mode == Mode.normie.rawValue {
            picture.sidebarRect=workbench.sidebar.view.convert(workbench.sidebar.view.bounds,to:view)
        }
        flightSourcePictures[mode]=picture;flightSourceKeys[mode]=flightPictureKey()
    }
    /// A synchronous Native transfer changes viewport geometry/revisions without changing the saved mode's content.
    /// Rekey only photos that were valid immediately before that transfer; stale content is never rehabilitated.
    private func rekeyFlightPictures(after previous:ModeFlightPictureKey) {
        guard ModeFlight.orreryEnabled else {return}
        let current=flightPictureKey()
        for (mode,key) in flightSourceKeys where key == previous {flightSourceKeys[mode]=current}
    }
    private var composerFlightBar: String?
    private var composerFlightAwaitingRegistration=false
    private var preparationTask: DispatchWorkItem?
    private var lastModeStoreChange = -Double.infinity
    #if M11_MODE_SELFTEST
    var verificationAfterPictureJoin:(()->Void)?
    var verificationColdAdmissionReadiness:[Bool]=[]
    var verificationSlicedPreparation=false
    var verificationLegacyPreparationRules=false
    var verificationBeforeTurnAdmission: (() -> Void)?
    var verificationAfterTurnAdmission: (() -> Void)?
    #endif
    private var preparationGeneration: UInt64 = 0
    private var preparationObserver: CFRunLoopObserver?
    private var cachedPreparationInput:ModePreparationKey?
    private var preparationKeyBuilds=0
    private var preparationInputsDirty=true
    private var preparationInputObservations:[NSObjectProtocol]=[]
    private var preparationTitleObservation:NSKeyValueObservation?
    private var preparationAppearanceObservation:UUID?
    private var preparationDisplayObservation:UUID?
    private var preparationObserverChecks=0
    private func invalidateModePreparationInputs() {preparationInputsDirty=true}
    private var preparationStoreObservation: UUID?
    private var preparationMenuObservation: NSObjectProtocol?
    private var preparationMouseMonitor: Any?
    private var preparingMode = false, performingAdmission = false
    private var preparationBatch:ModePreparationBatch?
    private var preparingOrganicTarget:AutoScene.ModeTargetPlan?
    private var admissionOrganicTarget:AutoScene.ModeTargetPlan?
    private var pendingMode: Mode?
    private var transitionGeneration: UInt64 = 0
    private var headerHidden: [String: [(view: NSView, hidden: Bool)]] = [:]
    private var openingFrameTime = 0.0
    private var flightEndpointRefreshScheduled = false
    private var flightRowsAwaitingRefresh = false
    private var lastFlightHostSize:CGSize?,lastFlightSidebarFrame:CGRect?
    private struct FlightEndpointGeometry:Equatable {
        var mode:String,admitted:String,host:CGSize,side:CGRect,clip:CGRect,table:CGRect
        var rows:[String],ids:[String],rects:[CGRect],avatar:CGRect,me:CGRect
    }
    private var lastFlightEndpointGeometry:FlightEndpointGeometry?
    private func flightEndpointGeometry()->FlightEndpointGeometry {
        let sidebar=workbench.sidebar,headers=headerEndpoints(),dock=scene.dockTargets
        return .init(mode:mode.rawValue,admitted:admittedMode.rawValue,host:view.bounds.size,side:sidebar.view.frame,
                     clip:sidebar.scrollView.contentView.bounds,table:sidebar.table.frame,rows:sidebar.model.rows.map(\.key),
                     ids:headers.map(\.tokenID)+dock.map {"\($0.id):\($0.bar)"}+flight.activeTokens.map(\.id),
                     rects:headers.map(\.rect)+dock.map(\.rect),avatar:sidebarAvatar(),me:scene.meRest)
    }
    #if M11_MODE_SELFTEST
    private(set) var verificationOwnerRequests=0
    #endif
    private var frozenSourceTranscripts:[NativeTranscript]=[]
    private var admissionRowKey=""
    #if M11_MODE_SELFTEST
    var verificationTargetObservation:((String,[String])->Void)?
    #endif
    var admissionHoles:[CGRect]=[]
    fileprivate var admissionWasCold = false
    private var admissionRowCursor=0
    private var lastNormieTopInset: CGFloat = 52
    private var lastNormieSidebarWidth: CGFloat?
    private static let preparesModes = ProcessInfo.processInfo.environment["M11_MODE_PREWARM"] != "0"
    private static let fliesHeaders = ProcessInfo.processInfo.environment["M10_HEADER_FLIGHTS"] != "0"
    /// The sidebar avatar's frame and the window height when it last flew out: the way back keeps its distance from
    /// the bottom (OrganicWindowController makePlan).
    private var savedAvatar: (rect: CGRect, height: CGFloat)?
    var initials = NormieAccount.prototype.initials
    private var transcriptStandIns: [NativeTranscriptStandIn] = []
    func clearTranscriptStandIns() {
        transcriptStandIns.forEach { $0.removeFromSuperview() }; transcriptStandIns = []
    }
    /// A source window can remain visible until the target's first commit. Its live view moves, its pixels stay.
    func freezeTranscriptSourceForTransfer() {
        if mode == .normie { freezeNormieTranscripts(); return }
        clearTranscriptStandIns()
        for transcript in workbench.transcriptSessions.transcripts.values
            where !transcript.isHiddenOrHasHiddenAncestor && transcript.isDescendant(of: organic) {
            guard let host = transcript.superview else { continue }
            let source = NativeTranscriptStandIn(transcript, scale: view.window?.backingScaleFactor ?? 1)
            host.addSubview(source, positioned: .above, relativeTo: transcript)
            source.needsDisplay = true; source.displayIfNeeded()
            transcriptStandIns.append(source)
        }
    }
    private func freezeNormieTranscripts() {
        let probe = ModeSignposts.current
        probe?.record("FreezeNormieTranscripts", .begin)
        defer { probe?.record("FreezeNormieTranscripts", .end) }
        clearTranscriptStandIns()
        let scale = view.window?.backingScaleFactor ?? 1
        for transcript in workbench.transcriptSessions.transcripts.values
            where !transcript.isHiddenOrHasHiddenAncestor && transcript.isDescendant(of: split.view) {
            guard let host = transcript.superview else { continue }
            let source = ModeSignposts.measure("TranscriptSnapshot", detail: transcript.conversation.id) { NativeTranscriptStandIn(transcript, scale: scale) }
            host.addSubview(source, positioned: .above, relativeTo: transcript)
            transcriptStandIns.append(source)
        }
        // The same decision cards move from Normie's external rail into Organic's inline rows. Keep the rail's
        // clipped source pixels too, above the detail: its real scroll view may collapse when those cards leave.
        func cards(_ v: NSView) -> [NativeTranscriptCard] { (v as? NativeTranscriptCard).map { [$0] } ?? v.subviews.flatMap(cards) }
        var captured = Set<ObjectIdentifier>()
        for card in cards(split.view) where !card.isHiddenOrHasHiddenAncestor {
            guard let scroll = card.enclosingScrollView, let parent = scroll.superview,
                  captured.insert(ObjectIdentifier(scroll)).inserted else { continue }
            let source = ModeSignposts.measure("ApprovalRailSnapshot") { NativeTranscriptStandIn(scroll, scale: scale) }
            source.frame = workbench.detail.view.convert(scroll.frame, from: parent)
            workbench.detail.view.addSubview(source)
            transcriptStandIns.append(source)
        }
        // Finish the source's own draw before removing the live viewport in this same transaction.
        ModeSignposts.measure("StandInDisplay") {
            for source in transcriptStandIns { source.needsDisplay = true; source.displayIfNeeded() }
        }
    }

    init(organic: RootView, scene: AutoScene, workbench: NormieWorkbench, mode: Mode) {
        self.organic = organic; self.scene = scene; self.workbench = workbench; self.mode = mode; self.admittedMode = mode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        scene.dock.composerMotion.canPrepareAtRest={ [weak self] in guard let self else{return false};return self.pendingMode == nil && !self.flight.running && !self.scene.isMoving && !self.contentEpochCompletionPending}
        NativeTranscript.onModeDrain={begin in ModeSignposts.current?.record("NormieNativeViewportDrain",begin ? .begin:.end)}
        M10ColumnModeProbe.enabled={ModeSignposts.current != nil}
        M10ColumnModeProbe.record={phase,begin,detail in ModeSignposts.current?.record(phase,begin ? .begin:.end,detail:detail)}
        let root = Container(frame: organic.frame)
        view = root
        root.blocksContentInput={ [weak self] in self?.modeContentInputBlocked == true }
        root.inactiveBody={ [weak self] in guard let self,ModeFlight.orreryEnabled,self.admittedMode == .organic else{return nil};return self.split.view }
        workbench.onModeSearchFocus={ [weak self] in
            guard let self,self.modeContentInputBlocked,self.mode == .normie else {return false}
            self.contentWantsSearch=true;self.contentSearchPredecessor=self.view.window?.firstResponder
            self.workbench.sidebar.focusSearch();return true
        }
        workbench.transcriptSessions.onModeContentCatchupFinished={ [weak self] id in
            guard let self else {return}
            self.contentPendingReplay.formUnion(self.scene.modeContentEpochPending);self.scene.modeContentEpochPending=[]
            self.contentPendingReplay.insert(id);self.scheduleContentReplay()
            if !self.contentEpochHeld {self.workbench.refresh()}
        }
        scene.composers.onModeHandoffGuardChanged={ [weak self] in
            guard let self,self.contentSession != nil else {return}
            self.contentEndpointChecks=0
            DispatchQueue.main.asyncAfter(deadline:.now()+self.flight.presentationInterval) { [weak self] in guard let self else {return};self.advanceContentSession(at:self.contentNow,flightFinished:!self.flight.running) }
        }
        split.shell = self
        if ModeFlight.orreryEnabled {
            let surface=NativeSplitSurface();surface.isVertical=true;surface.dividerStyle = .thin;surface.acceptsBodyInput={ [weak self] in self?.admittedMode == .normie }
            split.splitView=surface
        }
        let side = NSSplitViewItem(sidebarWithViewController: workbench.sidebar)
        // The product's split (OrganicWindowController: 240…400, 280/1280 preferred; M9 sidebar round).
        side.minimumThickness = NormieSidebarMetrics.minimumWidth; side.maximumThickness = NormieSidebarMetrics.maximumWidth
        side.preferredThicknessFraction = NormieSidebarMetrics.preferredThicknessFraction
        let body = NSSplitViewItem(viewController: workbench.detail)
        body.minimumThickness = 300
        let inspector = NSSplitViewItem(inspectorWithViewController: workbench.inspector)
        inspector.minimumThickness = 280; inspector.maximumThickness = 420
        inspector.preferredThicknessFraction = 320.0 / 1280.0; inspector.isCollapsed = true
        for item in [side, body, inspector] { split.addSplitViewItem(item) }
        // The system toolbar toggles the split item directly, bypassing our menu command.
        inspectorCollapseObservation = inspector.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
            let shown = !item.isCollapsed
            MainActor.assumeIsolated { self?.workbench.inspectorVisible = shown }
        }
        addChild(split)
        // Organic underneath, Normie over it (it fades out over the scene as the window turns Organic), the flights on top.
        organic.frame = root.bounds
        organic.autoresizingMask = [.width, .height]
        root.addSubview(organic)
        split.view.frame = root.bounds
        root.addSubview(split.view)
        if ModeFlight.orreryEnabled {
            organic.wantsLayer=true
            for item in normieBodyRoots {item.wantsLayer=true}
            split.view.layoutSubtreeIfNeeded()
            if let host=split.splitView.arrangedSubviews.first {turnSidebar.bindNative(host:host,content:workbench.sidebar.view,in:root)}
        }
        flight.resize(to: root.bounds.size)
        root.addSubview(flight.view)
        flight.endpointOrb = { [weak scene] id in
            guard let scene else { return nil }
            if id.hasPrefix("header.") {
                let conversation = String(id.dropFirst("header.".count))
                return scene.columns.first { $0.conversation.id == conversation }?.island?.orb
            }
            return scene.dock.items[id]?.decoration
        }
        flight.conversationIsLive = { [weak scene] conversation in
            scene?.store.conversation(conversation.id) === conversation && !conversation.archived
        }
        flight.rowCoverage = { [weak self] in
            guard let self else {return nil}
            let sidebar=self.workbench.sidebar,scroll=sidebar.scrollView
            guard scroll.bounds.width>0,scroll.bounds.height>0 else {return nil}
            let rect=scroll.convert(scroll.bounds,to:self.view),h=max(1,scroll.bounds.height)
            let a=scroll.convert(CGPoint(x:scroll.bounds.midX,y:scroll.bounds.maxY),to:self.view)
            let b=scroll.convert(CGPoint(x:scroll.bounds.midX,y:scroll.bounds.minY),to:self.view)
            let top=scroll.contentView.bounds.minY>0.5,bottom=sidebar.table.frame.height-scroll.contentView.bounds.maxY>0.5
            return ModeFlightRowCoverage(rect:rect,start:CGPoint(x:0.5,y:(a.y-rect.minY)/h),end:CGPoint(x:0.5,y:(b.y-rect.minY)/h),
                alpha:[top ? 0:1,1,1,bottom ? 0:1],stops:[0,min(0.25,9/h),max(0.75,1-18/h),1])
        }
        flight.rowSidebarOffset={ [weak self] time in self?.turnSidebar.rowOffset(at:time) ?? 0 }
        flight.destinationOwnerVisible = { [weak self] id in self?.flightOwnerVisible(id) ?? false }
        if ModeFlight.orreryEnabled {
            flight.destinationOwnerFrame = { [weak self] id in self?.currentFlightOwnerFrame(id) }
            flight.destinationOwnerLift = { [weak self] id in
                guard let self,id == "me",let target=self.flight.avatarEndpoints(toOrganic:true)?.to else {return nil}
                return self.scene.meRest.minY-target.minY-self.scene.dock.modePresentationRise
            }
            flight.destinationOwnerFailure = { [weak self] id in self?.flightOwnerFailure(id) ?? "window.closed" }
            flight.destinationVisibilityEndsAt = { [weak self] in self?.turnSidebar.visibilityEndsAt }
        }
        if ModeFlight.orreryEnabled {turnSidebar.now={ [weak self] in self?.flight.manualTime?() ?? CACurrentMediaTime() }}
        turnSidebar.canRetire={ [weak self] in self?.pendingMode == nil }
        workbench.sidebar.onModeEndpointVisibilityChanged={ [weak self] in self?.invalidateModePreparationInputs();self?.flight.destinationDidMount();self?.scheduleFlightEndpointRefresh() }
        scene.onModeEndpointVisibilityChanged={ [weak self] in self?.invalidateModePreparationInputs();self?.flight.destinationDidMount();self?.scheduleFlightEndpointRefresh() }
        flight.destinationExists = { [weak self] id in self?.workbench.sidebar.model.rows.contains { $0.conversationID == id } ?? false }
        flight.onShutdown = { [weak self] in self?.sidebarExposure.finish();self?.turnSidebar.finish(); self?.sourcePlate.clear() }
        flight.onPresentationFrame = { [weak self] time, profile in
            guard let self else { return }
            if ModeFlight.orreryEnabled,(self.contentSession != nil || self.contentOpening) {
                if time.isFinite {self.contentFrameTime=max(self.contentFrameTime,time)}
                self.advanceContentSession(at:self.contentNow,flightFinished:!time.isFinite)
                return
            }
            if time.isFinite {
                self.sidebarExposure.advance(at: time, profile: profile)
                self.sourcePlate.advance(at:time)
                self.sourcePlate.presentationInterval=profile.frameInterval
                if !ModeHandoffPlate.carriesGlass {self.workbench.detail.setModeComposerMaterialInFlight(self.mode == .organic && self.flight.composerMaterialIsVisible)}
                if self.pendingMode != nil, time > self.openingFrameTime { self.admission.presentedFrame(interval: profile.frameInterval) }
            } else {
                self.scene.endModeHandoff();self.scene.dock.composerMotion.endModeHandoff();self.workbench.detail.endModeHandoff();self.workbench.detail.setModeComposerMaterialInFlight(false);self.resumeSourceTranscripts()
                self.sidebarExposure.finish()
                if self.pendingMode == nil {self.turnSidebar.finishWhenSettled {}}
                if self.mode == .normie {self.releaseFlightHidden()}
                self.workbench.detail.freezeModeLayout(false)
                self.scheduleModePrewarm(reason: "flight.end")
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        invalidateModePreparationInputs()
        flight.resize(to: view.bounds.size)
        turnSidebar.resizeHost(view.bounds.size)
        if contentOpening {applyContentSidebarCutout()}
        if let session=contentSession {
            if contentPicture.frame != view.bounds {contentPicture.frame=view.bounds}
            if contentPicture.imageLayer.frame != contentPicture.bounds {contentPicture.imageLayer.frame=contentPicture.bounds}
            if let host=turnSidebar.verificationSafeNativeHost {contentSidebarCutout.apply(to:organic,width:host.bounds.width,time:contentNow,revision:turnSidebar.nativeClockRevision,offset:turnSidebar.rowOffset)}
            contentDockExposure.apply(to:scene.dockView,session:session,time:contentNow)
            if let window=view.window {for chrome in modeChromeSurfaces(in:window) where chrome.layer?.animation(forKey:"mode.content.phase") == nil {if let layer=chrome.layer {session.animate(layer,at:contentNow,photoOnTop:false)}}}
        }
        layoutNormie()
        if ModeFlight.orreryEnabled {invalidateContentPicture(reason:"resize",onlyIfChanged:true)}
        let side=workbench.sidebar.view
        if turnSidebar.needsResize(host:view.bounds.size,source:side.bounds.size) {
            // Geometry follows AppKit immediately. One coalesced bitmap refresh follows at the display boundary.
            turnSidebar.reframe(source:side.bounds.size)
            sidebarBitmapRefreshPending=true
        }
        let geometryChanged=lastFlightHostSize != view.bounds.size || lastFlightSidebarFrame != side.frame
        lastFlightHostSize=view.bounds.size;lastFlightSidebarFrame=side.frame
        if geometryChanged {refreshFlightEndpoints();scheduleFlightEndpointRefresh()}
    }

    /// Normie fills the window; its sidebar, detail and inspector lay out in their safe areas (under the toolbar).
    private func layoutNormie() {
        if split.view.frame != view.bounds { split.view.frame = view.bounds }
    }

    /// The toolbar Normie shows (sidebar, New Chat, Open in, inspector); Organic hides it.
    func installToolbar(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "organic.normie")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        apply(mode, in: window)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        ModeSignposts.withInput(sender == nil ? "sidebar.command" : "toolbar.sidebar.action") {
            setMode(mode == .normie ? .organic : .normie)
        }
    }

    /// Hide Sidebar (→ Organic) and Show Sidebar (→ Normie). `animated`: the authored flights (toolbar, menu, ⌃⌘S); a
    /// plain switch otherwise (launch, restore).
    /// Hide Sidebar's animated collapse is still running.
    private var sidebarCollapsing = false

    /// For demos: the sidebar as AppKit has it.
    var sidebarState: [String: Any] {
        guard let item = split.splitViewItems.first else { return [:] }
        let v = item.viewController.view
        return ["collapsed": item.isCollapsed, "frame": NSStringFromRect(v.frame), "hidden": v.isHidden, "alpha": v.alphaValue,
                "splitAlpha": normieBodyRoot.alphaValue, "splitHidden": normieBodyRoot.isHidden, "inWindow": v.window != nil]
    }

    func setMode(_ next: Mode, animated: Bool = true) {
        let entered = ModeSignposts.enabled || ModeFlight.orreryEnabled ? CACurrentMediaTime() : nil
        guard !workbench.transcriptSessions.isDisposed, next != mode, let window = view.window else { return }
        // A conversation out in a tear's panel belongs to no mode yet; its drop or Esc comes first.
        guard !scene.isTearing else { return }
        if ModeFlight.orreryEnabled {
            guard scene.composers.modeContentCanHandoff else {return}
            if let editor=window.firstResponder as? NSTextView,editor.hasMarkedText() {return}
        }
        onBrowserModeWillChange?(next)
        // A held Dock node goes home first, as a held header does (beginPreparedSwitch): its release would land in another mode.
        let turnsOrrery = animated && ModeFlight.orreryEnabled && flight.running && !Motion.reduce && !normieNativeStaged
            && flight.headingToOrganic != (next == .organic)
        if !turnsOrrery,!(animated && ModeFlight.orreryEnabled && !Motion.reduce) {scene.cancelDrag()}
        if ModeFlight.orreryEnabled {contentInputEntered=entered}
        let probe = ModeSignposts.beginSwitch(from: "\(mode)", to: "\(next)", window: window.windowNumber, animated: animated, enteredAt: entered)
        modeProbe?.stopObservation(reason: "superseded by next setMode"); modeProbe = probe
        probe?.observe()
        ModeSignposts.withTrace(probe) {
            defer {
                probe?.record("SetMode", .end, detail: "result=\(mode)")
                probe?.didReturn()
            }
            let reduce = Motion.reduce
            if ModeFlight.orreryEnabled,reduce {
                let focus=contentAdmissionResponder,selection=contentDeferredSelection
                cancelContentSession();cancelModePreparation();admission.cancel();transitionGeneration &+= 1
                pendingMode=nil;flight.cancel();turnSidebar.finish();sourcePlate.clear();releaseFlightHidden()
                workbench.sidebar.setFlightSourcesHidden([],avatar:false)
                scene.endModeHandoff();scene.dock.composerMotion.endModeHandoff();workbench.detail.endModeHandoff()
                workbench.detail.setModeComposerMaterialInFlight(false);workbench.detail.freezeModeLayout(false)
                if let selection {_=workbench.select(selection);scene.show(selection)}
                let previous=admittedMode
                performingAdmission=true
                let committed=next == .organic ? toOrganic(window,animated:false,reduce:true):toNormie(window,animated:false,reduce:true)
                performingAdmission=false
                guard committed else {rejectNativeCommit(preserving:previous,window:window);return}
                admittedMode=next;finalizeNativeOwner(next,window:window);turnSidebar.settleNative(incoming:next == .normie)
                restoreAdmissionResponder(focus);restoreSelectedContentFocus(selection,target:next);clearContentFocus()
                contentInputEntered=nil;onModeChange?(next);return
            }
            if animated, Self.preparesModes, workbench.detail.composer?.isComposing != true {
                beginPreparedSwitch(next, window: window, reduce: reduce, probe: probe)
                return
            }
            if contentOpening || contentSession != nil {cancelContentSession()}
            cancelModePreparation();admission.cancel(); pendingMode = nil; flight.cancel();turnSidebar.finish();sourcePlate.clear();scene.endModeHandoff();scene.dock.composerMotion.endModeHandoff();transitionGeneration &+= 1
            let previousOwner=admittedMode
            let committed=next == .organic ? toOrganic(window,animated:animated,reduce:reduce):toNormie(window,animated:animated,reduce:reduce)
            if ModeFlight.orreryEnabled {
                guard committed else {rejectNativeCommit(preserving:previousOwner,window:window);return}
                CATransaction.begin();CATransaction.setDisableActions(true)
                finalizeNativeOwner(next,window:window,preserveTargetFade:animated);admittedMode=next
                CATransaction.commit()
            } else {admittedMode=mode}
            if mode == next { onModeChange?(next) }
            else {
                probe?.record("ModeSwitchRejected", detail: "handoff guard; mode did not change")
                probe?.stopObservation(reason: "handoff rejected")
            }
        }
    }

    @discardableResult private func toOrganic(_ window: NSWindow?, animated: Bool, reduce: Bool) -> Bool {
        let probe = ModeSignposts.current
        probe?.record("ToOrganic", .begin)
        defer { probe?.record("ToOrganic", .end) }
        // Not while choosing files, or while the terminal (hidden in Organic) is composing. The editor goes mid-composition
        // as the product's does: it keeps the keyboard, the marked text and the selection (f030, f101).
        guard workbench.detail.composer?.isChoosingAttachments != true, !workbench.detail.terminalPane.isComposing,
              workbench.detail.canHandoffTranscripts else { return false }
        sidebarExposure.finish()
        if ModeFlight.orreryEnabled,performingAdmission,contentOpening,
           let plan=admissionOrganicTarget,contentOrganicReady === plan {
            mode = .organic;organic.isHidden=false
            workbench.isNormie=false;workbench.sidebarVisible=false
            setModeToolbar(false,in:window);split.splitViewItems.last?.isCollapsed=true
            return true
        }
        probe?.record("OrganicPlan", .begin)
        let h = view.bounds.height
        // The plan, while the sidebar's geometry is still there (willToggle): the avatar, the planets that can be seen
        // (not under the title bar or the account capsule), the composer.
        let avatarFrom = workbench.avatarFrame.map { view.convert($0, from: nil) } ?? CGRect(x: 25, y: h - 51, width: 26, height: 26)
        savedAvatar = (avatarFrom, h)
        let sidebarWidth = split.splitViewItems.first?.viewController.view.frame.width ?? 0
        let seen = CGRect(x: 0, y: 52, width: max(sidebarWidth, 200), height: h - 52 - 64)
        var rowGeometry = ModeFlight.orreryEnabled ? sidebarRows(warming:true):[:]
        rowGeometry.merge(workbench.rowFrames.mapValues { view.convert($0,from:nil) },uniquingKeysWith: {_,live in live})
        let rows = rowGeometry.filter { seen.contains(CGPoint(x:$0.value.midX,y:$0.value.midY)) }
        let composer = workbench.detail.composer
        // The composer's glass leaves from Normie's composer dock (its glass capsule), else from the editor itself.
        let composerFrom = workbench.detail.composerDockFrame.map { view.convert($0, from: nil) }
            ?? composer.flatMap { c in c.window == nil ? nil : view.convert(c.bounds, from: c) }
        flight.prepareComposerMaterial(from:workbench.detail.modeComposerMaterial)
        let editing = composer.map { c in (window?.firstResponder as? NSView)?.isDescendant(of: c) == true } ?? false
        probe?.record("OrganicPlan", .end)
        if animated && sourcePlate.picture == nil { freezeNormieTranscripts() } else { clearTranscriptStandIns() }
        if !(contentOpening && contentDetachedOwner == .normie) {_ = ModeSignposts.measure("ComposerHandoff") {workbench.composerForHandoff()}}
        let committed=performingAdmission && admissionOrganicTarget.map {
            $0.key.selected == workbench.selectedConversation?.id && (contentOrganicReady === $0 || scene.commitModeTarget($0))
        } == true
        if !committed {
            ModeSignposts.measure("OrganicColumnsCaptureBake", detail: "columns=\(scene.columns.map { $0.conversation.id }.joined(separator: ",")); inclusive setTranscriptPresentationActive(true)") {
                scene.setTranscriptPresentationActive(true)
            }
            // New Chat is the window's one state (WindowModel.composingNew): Normie's draft is Organic's, and back (audit A04).
            ModeSignposts.measure("OrganicSceneShow", detail: "inclusive show/newChat/resize; snapshot + prewarm + keyframe work inside these calls") {
                if workbench.composingNew {
                    scene.draftContext = workbench.newContext
                    if !scene.composingNew && !scene.isFocused { scene.newChat() }
                }
                else {
                    if scene.composingNew { scene.cancelNewChat() }
                    if let id = workbench.selectedConversation?.id { scene.show(id) }
                }
            }
        }
        mode = .organic
        if !committed {ModeSignposts.measure("OrganicRemountComposers") { scene.remountComposers() }}

        let normie = normieBodyRoot
        organic.isHidden = false
        // After Organic shows: an editor under a hidden view cannot take the keyboard.
        if editing { composer?.focus() } else { window?.makeFirstResponder(organic) }
        workbench.isNormie = false; workbench.sidebarVisible = false
        setModeToolbar(false,in:window)
        split.splitViewItems.last?.isCollapsed = true
        guard animated else { normie.isHidden = true; split.splitViewItems.first?.isCollapsed = !ModeFlight.orreryEnabled;if !contentOpening && contentSession == nil {turnSidebar.settleNative(incoming:false)};finishApply(window);return true }
        // The dock fades in, the columns are there at once, Normie fades out over them (0.22 s) while its sidebar slides.
        probe?.firstAnimation("scene.fadeDockIn; first animation-producing call")
        ModeSignposts.measure("DockFadeAnimation") { scene.fadeDockIn() }
        if !performingAdmission {
            let flying = reduce ? [] : openingTokens(.organic, rows: rows, headers: headerEndpoints())
            workbench.sidebar.setFlightSourcesHidden(Set(flying.map { $0.conversation.id }), avatar: true)
        }
        // After a cold admission the main thread is still catching up, and the sidebar's exposure held a smeared frame for 40 ms,
        // every row doubled (board 10-31). The real sidebar slides in the render server, so it goes without.
        let sidebarLease = reduce || admissionWasCold || turnSidebar.usesNativeHost ? nil : sidebarExposure.begin(source: workbench.sidebar.view, in: view, below: flight.view, driven: false, scale:scene.scale,prepared:performingAdmission ? preparedSidebarPicture:nil,foreground:{[self] in sidebarForeground()})
        if turnSidebar.usesNativeHost {if reduce {turnSidebar.settleNative(incoming:false)} else {turnSidebar.moveNative(incoming:false)}}
        else if performingAdmission, !reduce {
            animatePreparedSidebar(incoming:false)
        } else {
            sidebarCollapsing = true
            NSAnimationContext.runAnimationGroup({ _ in split.splitViewItems.first?.animator().isCollapsed = true }, completionHandler: { [weak self] in
                // Turned back to Normie while this collapse ran: AppKit ends it with the sidebar gone though it says expanded;
                // collapsing and expanding again brings it back (a recording, 10-29).
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let sidebarLease { self.sidebarExposure.finish(sidebarLease) }
                    self.sidebarCollapsing = false
                    guard self.mode == .normie, let item = self.split.splitViewItems.first else { return }
                    item.isCollapsed = true; item.isCollapsed = false
                }
            })
        }
        let fadeGeneration = transitionGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            normie.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.mode == .organic, self.transitionGeneration == fadeGeneration else { return }
                normie.isHidden = true; normie.alphaValue = 1
                self.split.splitViewItems.first?.isCollapsed = !ModeFlight.orreryEnabled
                // The split's fade ends before its collapse. Retire its content proxy BEFORE restoring
                // alpha, otherwise that independently mounted proxy could flash back for the last 30 ms.
                self.sidebarExposure.finish()
                self.clearTranscriptStandIns()
            }
        })
        // The planets, left to right by slot: into bars (taken in at their left end) or orbs (handed to the real one).
        // The planets and the composer assemble only into Auto; Focused, Split and a draft get me alone
        // (OWC:205-209; audit A16).
        probe?.record("OrganicFlightPlan", .begin)
        let assembles = !scene.isFocused && !scene.composingNew
        let targets = assembles ? scene.dockTargets.sorted { $0.rect.minX < $1.rect.minX } : []
        let headerTargets = Self.fliesHeaders && !scene.composingNew ? headerEndpoints() : []
        let headerIDs = Set(headerTargets.map(\.id))
        var tokens: [ModeFlight.Token] = []
        for t in targets where !headerIDs.contains(t.id) {
            guard let from = rows[t.id], let c = scene.store.conversation(t.id) else { continue }
            let to = t.bar ? CGRect(x: t.rect.minX + 4, y: t.rect.midY - 16, width: 32, height: 32) : t.rect
            tokens.append(.init(id: t.id, conversation: c, from: from, to: to, start: 0.08 + 0.04 * Double(min(tokens.count, 4)), absorbed: t.bar))
        }
        for target in headerTargets {
            guard let from = rows[target.id] else { continue }
            tokens.append(.init(id: target.tokenID, conversation: target.conversation, from: from, to: target.rect,
                                start: 0.08 + 0.04 * Double(min(tokens.count, 4)), absorbed: false))
        }
        tokens = rankedTokens(tokens, forward: true)
        let full = targets.first { $0.id == scene.current && $0.bar }
        let trip = full.flatMap { f in composerFrom.map { (from: $0, to: f.rect, slot: f.slot) } }
        // What the flights arrive at stays hidden until they do: me, the orbs, the full bar.
        releaseFlightHidden()
        scene.setMeHidden(true); meFlightHidden = true
        let waiting = reduce ? [] : tokens.filter { !$0.absorbed }.map(\.id)
        for id in waiting {
            if id.hasPrefix("header.") { hideHeader(id) }
            else { scene.setDockHidden(id, true); flightHidden.insert(id) }
        }
        if let f = full, trip != nil, !reduce { scene.setDockHidden(f.id, true); flightHidden.insert(f.id);composerFlightBar=f.id;composerFlightAwaitingRegistration=true }
        let flyingRows = reduce ? Set<String>() : Set(tokens.map { $0.conversation.id })
        workbench.sidebar.setFlightSourcesHidden(flyingRows, avatar: true)
        // Orbs whose rows could not be seen bud from the bars instead (dockAppear → bloom).
        scene.bloomDock(excluding: Set(waiting))
        var pending = Set(waiting), barPending = trip != nil && !reduce, mePending = true
        flight.onFrame = { [weak self] t in
            guard let self else { return }
            if mePending, t >= self.flight.avatarHandoff { mePending = false; self.scene.setMeHidden(false); self.meFlightHidden = false; self.workbench.sidebar.setFlightSourcesHidden(t.isFinite ? flyingRows : [], avatar: false) }
            if !t.isFinite { self.workbench.sidebar.setFlightSourcesHidden([], avatar: false) }
            for id in pending where t == .infinity || self.flight.arrived(id, at: t) { pending.remove(id); if id.hasPrefix("header.") { self.revealHeader(id) } else { self.scene.setDockHidden(id, false); self.flightHidden.remove(id) } }
            if barPending, t == .infinity || ((!ModeFlight.orreryEnabled || !self.composerFlightAwaitingRegistration) && self.flight.barArrived(at: t)), let f = full { barPending = false; self.scene.setDockHidden(f.id, false); self.flightHidden.remove(f.id) }
        }
        probe?.record("OrganicFlightPlan", .end)
        let avatarTo = scene.meFrame ?? scene.meRest
        if !performingAdmission || !(flight.landedAlready(toOrganic: true) || flight.continuePrepared(toOrganic: true, avatar: avatarTo, tokens: tokens, composer: trip, reduceMotion: reduce)) {
            flight.start(toOrganic: true, avatar: (avatarFrom, avatarTo), initials: initials, tokens: tokens, composer: trip, reduceMotion: reduce)
        }
        composerFlightAwaitingRegistration=false
        if ModeFlight.orreryEnabled { flight.onFrame = { [weak self] time in self?.publishFlightOwners(at:time) } }
        finishApply(window)
        return true
    }

    @discardableResult private func toNormie(_ window:NSWindow?, animated: Bool, reduce: Bool) -> Bool {
        let probe = ModeSignposts.current
        probe?.record("ToNormie", .begin)
        defer { probe?.record("ToNormie", .end) }
        guard scene.transcriptSessions?.canHandoff != false else { return false }
        sidebarExposure.finish()
        clearTranscriptStandIns()
        // Hide Sidebar turned back: what its leg hid comes back now (B09). Not at this leg's own admission: they had flown,
        // and the real ones came back under the source picture's holes (board 10-31). The source's retirement lets them go.
        if !performingAdmission {releaseFlightHidden()}
        probe?.record("NormieSourcePlan", .begin)
        let h = view.bounds.height
        // From the dock as it is now, right to left: a bar from its left end, an orb from its frame.
        let headerSources = Self.fliesHeaders && !scene.composingNew ? headerEndpoints() : []
        let headerIDs = Set(headerSources.map(\.id))
        let sources = (scene.isFocused || scene.composingNew ? [] : scene.dockTargets).filter { !headerIDs.contains($0.id) }.compactMap { t -> (id: String, rect: CGRect)? in
            guard let r = scene.dockFrame(of: t.id) else { return nil }
            return (t.id, t.bar ? CGRect(x: r.minX + 4, y: r.midY - 16, width: 32, height: 32) : r)
        }.sorted { $0.rect.midX > $1.rect.midX }
        let meFrom = scene.meFrame ?? scene.meRest
        probe?.record("NormieSourcePlan", .end)
        if !normieNativeStaged && !(contentOpening && contentDetachedOwner == .organic) {ModeSignposts.measure("OrganicColumnsUnmount") {
            if performingAdmission {scene.suspendModePresentation()} else {scene.setTranscriptPresentationActive(false)}
        }}
        mode = .normie
        // Normie at its end state before anything shows, so the planets know where their rows are.
        probe?.record("PrepareNormie", .begin, detail: workbench.detail.isViewLoaded ? "detail.loaded" : "detail.cold")
        workbench.sidebar.endModePreparation(); workbench.detail.endModePreparation()
        let normie = ModeSignposts.measure("NormieSplitViewLoad", detail: workbench.detail.isViewLoaded ? "detail.loaded" : "detail.cold; may include first detail.loadView") { normieBodyRoot }
        if animated {normie.alphaValue=0}
        normie.isHidden=false
        #if M11_MODE_SELFTEST
        verificationObserveTarget("unhidden")
        #endif
        split.splitViewItems.first?.isCollapsed = false
        if normieNativeStaged {
            if !normieEndpointStaged {finishNormieEndpoint {setModeToolbar(true,in:window)}}
            normieNativeStaged=false;normieEndpointStaged=false
        } else {
            let prepared=ModeFlight.orreryEnabled && performingAdmission && contentPreparedNormieLayout == contentNormieLayoutKey
            admitNormieContent(layout:!prepared) {setModeToolbar(true,in:window)}
            if prepared {workbench.detail.freezeModeLayout(false);setModeToolbar(true,in:window)}
        }
        if let root = workbench.sidebar.view as? NormieView { lastNormieTopInset = root.contentSafeRect.minY }
        lastNormieSidebarWidth = workbench.sidebar.view.bounds.width
        probe?.record("PrepareNormie", .end)
        // The scene goes at once; Normie fades in over 0.22 s (DetailRoot).
        if !performingAdmission {organic.isHidden = true}
        finishApply(window)
        ModeSignposts.measure("NormieFirstResponder") {workbench.detail.composer?.focus()}
        workbench.refreshComposerPresentationBinding()
        guard animated else {if !contentOpening && contentSession == nil {turnSidebar.settleNative(incoming:true)};return true}
        // Explicit: shown and faded in one commit, an animator() fade has no start on screen and Normie popped in.
        guard workbench.detail.conversation?.id == scene.current || scene.composingNew else {probe?.record("ModeTargetRejected",detail:"selected transcript mismatch");return false}
        workbench.detail.hideNonSelectedModeTranscripts()
        func fadeNormie() {
            CATransaction.begin();CATransaction.setDisableActions(true)
        normie.alphaValue = 1
        #if M11_MODE_SELFTEST
        verificationObserveTarget("validated.reveal")
        #endif
        if let layer = normie.layer {
            let a = CABasicAnimation(keyPath: "opacity")
            ModeSignposts.frameRange(a)
            a.fromValue = 0; a.toValue = 1; a.duration = 0.22
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.fillMode = .backwards
            probe?.firstAnimation("normie.layer.add(mode.normie)")
            ModeSignposts.measure("NormieFadeAnimation") { layer.add(a, forKey: "mode.normie") }
        }
            CATransaction.commit()
        }
        if !performingAdmission {fadeNormie()}
        probe?.record("NormieFlightPlan", .begin)
        var rows = ModeFlight.orreryEnabled ? sidebarRows(warming:true):[:]
        rows.merge(workbench.rowFrames.mapValues { view.convert($0,from:nil) },uniquingKeysWith: {_,live in live})
        var tokens: [ModeFlight.Token] = []
        for s in sources {
            guard let to = rows[s.id], let c = scene.store.conversation(s.id) else { continue }
            tokens.append(.init(id: s.id, conversation: c, from: s.rect, to: to, start: 0.08 + 0.04 * Double(min(tokens.count, 4)), absorbed: true))
        }
        for source in headerSources {
            guard let to = rows[source.id] else { continue }
            tokens.append(.init(id: source.tokenID, conversation: source.conversation, from: source.rect, to: to,
                                start: 0.08 + 0.04 * Double(min(tokens.count, 4)), absorbed: true))
            if !reduce { hideHeader(source.tokenID) }
        }
        tokens = rankedTokens(tokens, forward: false)
        let saved = savedAvatar.map { CGRect(x: $0.rect.minX, y: h - ($0.height - $0.rect.minY), width: $0.rect.width, height: $0.rect.height) }
        let avatarTo = workbench.avatarFrame.map { view.convert($0, from: nil) } ?? saved ?? CGRect(x: 25, y: h - 51, width: 26, height: 26)
        var returningRows = reduce ? Set<String>() : Set(tokens.map { $0.conversation.id })
        workbench.sidebar.setFlightSourcesHidden(returningRows, avatar: true)
        flight.onFrame = { [weak self] t in
            guard let self else { return }
            for token in tokens where ModeFlight.orreryEnabled ? self.flight.arrived(token.id,at:t) : t >= token.start+0.28 { returningRows.remove(token.conversation.id) }
            self.workbench.sidebar.setFlightSourcesHidden(returningRows, avatar: t < self.flight.avatarHandoff)
        }
        probe?.record("NormieFlightPlan", .end)
        if !performingAdmission || !(flight.landedAlready(toOrganic: false) || flight.continuePrepared(toOrganic: false, avatar: avatarTo, tokens: tokens, composer: nil, reduceMotion: reduce)) {
            flight.start(toOrganic: false, avatar: (meFrom, avatarTo), initials: initials, tokens: tokens, composer: nil, reduceMotion: reduce)
        }
        if ModeFlight.orreryEnabled { flight.onFrame = { [weak self] time in self?.publishFlightOwners(at:time) } }
        if performingAdmission {
            if !reduce {
                if !admissionWasCold,!turnSidebar.usesNativeHost {_=sidebarExposure.begin(source:workbench.sidebar.view,in:view,below:flight.view,driven:false,scale:scene.scale,prepared:preparedSidebarPicture,foreground:{[self] in sidebarForeground()})}
                // The flights are already under way here, most of them nearly home. Following the sidebar now would throw them
                // 240 pt off the window in one frame, to where the sidebar is as it starts to slide in (user 10-30: "broken").
                // They land where their rows will rest, and the sidebar comes in under them.
                animatePreparedSidebar(incoming:true)
            }
            // Both complete pictures begin their compositor fades only after all target preparation is finished.
            fadeNormie()
            return true
        }
        // The sidebar slides in as AppKit slides it (the product's animator().isCollapsed = false); the rows were read at
        // its end, and the planets and me follow it there (DECISIONS #10). Not while Hide Sidebar's collapse still runs:
        // that one's end puts the sidebar back.
        if turnSidebar.usesNativeHost {if reduce {turnSidebar.settleNative(incoming:true)} else {turnSidebar.moveNative(incoming:true)};return true}
        guard !reduce, !sidebarCollapsing, let item = split.splitViewItems.first else { return true }
        let sidebar = item.viewController.view
        let end = view.convert(sidebar.bounds.origin, from: sidebar)
        let sidePicture = performingAdmission ? preparedSwitch.flatMap { preparation in
            (workbench.sidebar.view as? NormieView)?.contentSafeRect == preparation.sidebarSafeRect ? preparation.sidebar : nil
        } : nil
        let sidebarLease = sidebarExposure.begin(source: sidebar, in: view, below: flight.view, driven: false, prepared: sidePicture)
        item.isCollapsed = true
        view.layoutSubtreeIfNeeded()
        sidebarExposure.rebase()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.allowsImplicitAnimation = true
            item.animator().isCollapsed = false
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let sidebarLease { self?.sidebarExposure.finish(sidebarLease) }
            }
        })
        flight.targetShift = { [weak self, weak sidebar] in
            guard let self, let sidebar, !sidebar.isHidden else { return .zero }
            return CGPoint(x: self.view.convert(sidebar.bounds.origin, from: sidebar).x - end.x, y: 0)
        }
        return true
    }

    /// Collapse (f050): the strip over everything but the flights; the scene and Normie hidden under it, no toolbar.
    func setCollapsed(_ strip: NSView?) {
        settlePendingMode()
        sidebarExposure.finish()
        let on = strip != nil
        scene.setTranscriptPresentationActive(!on && mode == .organic)
        if let strip { view.addSubview(strip, positioned: .below, relativeTo: flight.view) }
        organic.isHidden = on || mode == .normie
        normieBodyRoot.isHidden = on || mode == .organic
        setModeToolbar(!on && mode == .normie,in:view.window)
        if turnSidebar.usesNativeHost {turnSidebar.settleNative(incoming:!on && mode == .normie)}
        if ModeFlight.orreryEnabled {
            for (index,root) in normieBodyRoots.enumerated() {root.isHidden = on || mode == .organic || (index>0 && split.splitViewItems[index+1].isCollapsed)}
        }
        workbench.isCollapsed = on
    }

    /// Launch in a mode, without flights.
    func apply(_ m: Mode, in window: NSWindow) {
        admittedMode = m
        sidebarExposure.finish()
        let normie = m == .normie
        // Opened in Organic, the editors are the dock's from the start: Normie must not take one back on a selection.
        if !normie { _ = workbench.composerForHandoff() }
        scene.setTranscriptPresentationActive(!normie)
        workbench.isNormie = normie
        workbench.sidebarVisible = normie
        if normie { prepareNormie() }
        split.splitViewItems.first?.isCollapsed = !normie && !ModeFlight.orreryEnabled
        normieBodyRoot.isHidden = !normie
        organic.isHidden = normie
        setModeToolbar(normie,in:window)
        if turnSidebar.usesNativeHost {turnSidebar.settleNative(incoming:normie)}
        finishApply(window)
    }

    /// Opened (or plainly switched) in Normie: the workbench shows the scene's conversation with its editor, as toNormie
    /// prepares it. Launching in Normie showed New Chat's page, no composer, under the selected row (M9 capture, 10-29):
    /// at launch the scene has no members yet when the mode applies, so the window calls this again once it shows. A
    /// window with no members keeps New Chat (Live's first window).
    func prepareNormie() {
        guard mode == .normie, !scene.members.isEmpty else { return }
        let probe = ModeSignposts.current
        probe?.record("PrepareNormie", .begin)
        defer { probe?.record("PrepareNormie", .end) }
        workbench.memberOrder = scene.order
        if scene.composingNew { _ = workbench.newChat(projectID: scene.draftContext.projectID) } else { _ = workbench.select(scene.current) }
        workbench.remountComposer()
        workbench.refresh()
        workbench.refreshComposerPresentationBinding()
    }

    private func finishApply(_ window:NSWindow?) {
        layoutNormie()
        refreshTitle()
        scene.clock.run(until: CACurrentMediaTime() + 0.1)
    }

    private func modeChromeSurfaces(in window:NSWindow)->[NSView] {
        guard let frame=window.contentView?.superview else {return []}
        func find(_ view:NSView,_ type:String)->[NSView] {
            if String(describing:Swift.type(of:view)) == type {return [view]}
            return view.subviews.flatMap {find($0,type)}
        }
        let toolbar=contentChrome.flatMap {$0.window === window ? [$0]:nil} ?? find(frame,"NSToolbarView")
        contentChrome=toolbar.first
        // These AppKit-owned fill views are outside the detail controller's root, inside its stable split wrapper.
        let fills=split.splitView.arrangedSubviews.dropFirst().flatMap {find($0,"NSTitlebarBackgroundView")}
        return toolbar+fills
    }
    private func setModeToolbar(_ shown:Bool,in window:NSWindow?) {
        guard let window else {return}
        guard ModeFlight.orreryEnabled,!Motion.reduce else {
            if contentChromeInstalled {for surface in modeChromeSurfaces(in:window) {surface.layer?.removeAnimation(forKey:"mode.content.phase");surface.layer?.opacity=1;surface.setAccessibilityHidden(false)}}
            contentChromeInstalled=false;window.toolbar?.isVisible=shown;return
        }
        if window.toolbar?.isVisible != true {window.toolbar?.isVisible=true}
        contentChromeInstalled=true
        for surface in modeChromeSurfaces(in:window) {
            surface.wantsLayer=true
            if contentSession == nil && !contentOpening {
                surface.layer?.removeAnimation(forKey:"mode.content.phase");surface.layer?.opacity=shown ? 1:0
                surface.setAccessibilityHidden(!shown)
            }
        }
    }
    /// Normie shows the conversation's title, Organic none; the window keeps one for the Window menu either way, New
    /// Chat while drafting (OWC observeTitle, applyChrome; app audit AP16).
    func refreshTitle() {
        guard pendingMode == nil else { return }
        guard let window = view.window else { return }
        window.titleVisibility = contentChromeInstalled || mode == .normie ? .visible : .hidden
        let drafting = mode == .normie ? workbench.composingNew : scene.composingNew
        let shown = mode == .normie ? workbench.selectedConversation : scene.conversation(scene.focusTarget)
        window.title = drafting ? "New Chat" : shown?.title ?? "Organic Codex"
    }

    /// The window's own inspector (⌥⌘I; app audit AP02): the split's inspector item, told to the workbench.
    func toggleInspector() {
        guard mode == .normie, let item = split.splitViewItems.last else { return }
        item.animator().isCollapsed = !item.isCollapsed
        workbench.inspectorVisible = !item.isCollapsed
    }
    var inspectorShown: Bool { split.splitViewItems.last.map { !$0.isCollapsed } ?? false }

    /// What a mode flight hid until its planet arrives (me, orbs, the full bar). A leg turned back gives them all
    /// back before the next leg hides its own (organic audit B09).
    private var flightHidden = Set<String>(), meFlightHidden = false
    private func releaseFlightHidden() {
        composerFlightBar=nil;composerFlightAwaitingRegistration=false
        for id in Array(headerHidden.keys) { revealHeader(id) }
        for id in flightHidden { scene.setDockHidden(id, false) }
        flightHidden = []
        if meFlightHidden { scene.setMeHidden(false); meFlightHidden = false }
    }

    // MARK: NSToolbarDelegate

    private static let newChat = NSToolbarItem.Identifier("organic.newChat")
    private static let openIn = NSToolbarItem.Identifier("organic.openIn")
    private static let terminal = NSToolbarItem.Identifier("organic.terminal")
    private static let inspectorToggle = NSToolbarItem.Identifier("organic.inspector")

    /// The product's (OrganicWindowController): the sidebar's New Chat and toggle; over the detail, Open in and Terminal;
    /// the system inspector toggle over the Status inspector.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newChat, .toggleSidebar, .sidebarTrackingSeparator,
         .flexibleSpace, Self.openIn, Self.terminal, .inspectorTrackingSeparator, .flexibleSpace,
         ModeFlight.orreryEnabled ? Self.inspectorToggle:.toggleInspector]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.inspectorToggle where ModeFlight.orreryEnabled:
            // Reserved toggleInspector items are created by AppKit without consulting this delegate.
            // Keep our own fixed icon while the system split temporarily has no mounted detail.
            let item=NSToolbarItem(itemIdentifier:id)
            let image=NSImage(systemSymbolName:"sidebar.right",accessibilityDescription:"Toggle Inspector") ?? NSImage(size:NSSize(width:16,height:16))
            item.image=image
            item.label="Show Inspector";item.toolTip="Show or Hide Inspector"
            item.target=self;item.action=#selector(toggleInspector(_:))
            let button=NSButton(image:image,target:self,action:#selector(toggleInspector(_:)))
            button.title="";button.bezelStyle = .texturedRounded;button.imagePosition = .imageOnly
            button.frame=CGRect(x:0,y:0,width:32,height:28);button.toolTip=item.toolTip
            button.identifier=NSUserInterfaceItemIdentifier("mode.inspector.toggle")
            button.setAccessibilityLabel("Toggle Inspector");item.view=button
            item.target=self;item.action=#selector(toggleInspector(_:))
            return item
        case Self.newChat:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Chat")
            item.label = "New Chat"; item.toolTip = "New Chat (⌘N)"
            item.target = self; item.action = #selector(newChat(_:))
            return item
        case Self.terminal:
            // Normie's bottom terminal (f026; Sol's NormieTerminal).
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: workbench.terminalToolbarSymbol, accessibilityDescription: "Terminal")
            item.label = "Terminal"; item.toolTip = workbench.terminalToolbarToolTip
            item.target = self; item.action = #selector(toggleTerminal(_:))
            return item
        case Self.openIn:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            // Finder's own icon, as the product's (OrganicWindowController.openInToolbarItem; M9).
            item.image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder").map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "folder", accessibilityDescription: "Open in")
            item.label = "Open in"; item.toolTip = "Open in Finder"
            item.menu = workbench.openIn.makeMenu()
            item.showsIndicator = true
            // A primary action makes it the product's split button (the icon opens in Finder; a divider, then the menu).
            item.target = self; item.action = #selector(openInFinder(_:))
            return item
        default:
            return nil
        }
    }

    @objc private func newChat(_ sender: Any?) { workbench.perform(.newChat) }
    @objc private func toggleTerminal(_ sender: Any?) { workbench.perform(.terminal) }
    @objc private func openInFinder(_ sender: Any?) { workbench.openIn.open(application: "Finder") }
}

extension WindowShell {
    #if M11_MODE_SELFTEST
    var verificationPreparationKeyBuilds:Int {preparationKeyBuilds}
    var verificationPreparationObserverChecks:Int {preparationObserverChecks}
    func verificationWakePreparationObserver() {
        guard preparationInputsDirty else {return};preparationInputsDirty=false;preparationObserverChecks+=1
        _=modePreparationKey();_=flightPictureKey()
    }
    func verificationPreparationSnapshot()->ModePreparationKey {modePreparationKey()}
    var verificationPreparationIsValid: Bool {
        return ModeFlight.orreryEnabled ? (contentWarm != nil && contentWarmKey == flightPictureKey()):preparedSwitch?.key == modePreparationKey()
    }
    var verificationPreparedRows: Int { preparedSwitch?.rows.count ?? 0 }
    var verificationPreparedAvatar: CGRect? { preparedSwitch?.avatar }
    var verificationPreparedRowsInBounds: Bool { preparedSwitch?.rows.values.allSatisfy { view.bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false }
    func verificationAdmittedMode(_ next: Mode) { mode = next; admittedMode = next }
    #endif
    func startModePreparation() {
        guard Self.preparesModes, preparationObserver == nil else { return }
        preparationStoreObservation = scene.store.observe { [weak self] _ in self?.modeStoreChanged() }
        preparationMenuObservation = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleModePrewarm(reason: "menu.open") }
        }
        preparationMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.view.window,
                   event.locationInWindow.y >= (self.view.window?.contentLayoutRect.maxY ?? .infinity)
                    || self.scene.isMe(at: self.organic.convert(event.locationInWindow, from: nil)) {
                    self.scheduleModePrewarm(reason: "toolbar.or.me.hover")
                }
            }
            return event
        }
        // Native edits, scroll/layout, display options and island state carry invalidation to the
        // idle observer. A pointer wakeup alone cannot rebuild either preparation key.
        if ModeFlight.orreryEnabled {
            let names:[Notification.Name]=[Notification.Name("Organic.ModePreparationInputsChanged"),ConversationStore.devicesDidChange,NSControl.textDidChangeNotification,NSTableView.selectionDidChangeNotification,
                NSText.didChangeNotification,NSTextView.didChangeSelectionNotification,
                NSView.boundsDidChangeNotification,NSView.frameDidChangeNotification,
                NSWindow.didResizeNotification,NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification,NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,UserDefaults.didChangeNotification]
            for name in names {
                preparationInputObservations.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
                    // NotificationCenter delivers this callback on .main; only the object crosses the synchronous actor assertion.
                    nonisolated(unsafe) let object=note.object
                    MainActor.assumeIsolated {
                        guard let self else {return}
                        if let source=object as? NSView,source.window !== self.view.window {return}
                        if let window=object as? NSWindow,window !== self.view.window {return}
                        self.invalidateModePreparationInputs()
                    }
                })
            }
            preparationTitleObservation=view.window?.observe(\.title,options:[.new]) { [weak self] _,_ in
                MainActor.assumeIsolated {self?.invalidateModePreparationInputs()}
            }
            preparationAppearanceObservation=NativeAppearance.observe { [weak self] in self?.invalidateModePreparationInputs() }
            preparationDisplayObservation=NativeDisplayOptions.shared.observe { [weak self] in self?.invalidateModePreparationInputs() }
            let natives:[NSView]=[workbench.sidebar.scrollView.contentView,workbench.sidebar.view]+Array(workbench.transcriptSessions.transcripts.values).map({$0 as NSView})+scene.dock.items.values.map({$0.glass as NSView})
            for native in natives {
                native.postsFrameChangedNotifications=true;native.postsBoundsChangedNotifications=true
            }
        }
        preparationObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max - 1) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.preparationTask == nil, !self.preparingMode, self.pendingMode == nil,
                      !self.flight.running, self.view.window?.isVisible == true else { return }
                if ModeFlight.orreryEnabled {
                    guard !self.contentEpochCompletionPending,!self.contentOpening,self.contentSession == nil else {return}
                    guard self.preparationInputsDirty else {return}
                    self.preparationInputsDirty=false;self.preparationObserverChecks+=1
                }
                if ModeFlight.orreryEnabled,self.contentWarm != nil,self.contentWarmKey != self.flightPictureKey() {self.invalidateContentPicture(reason:self.contentInvalidationReason())}
                if self.preparedSwitch?.key != self.modePreparationKey() { self.scheduleModePrewarm(reason: "idle.changed") }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), preparationObserver, .commonModes)
        scheduleModePrewarm(reason: "window.ready")
    }

    func disposeModePreparation() {
        ModeContentWorkBoundary.cancel(in:view)
        turnSidebar.finish()
        cancelContentSession();contentPendingReplay=[]
        cancelModePreparation(); admission.cancel(); pendingMode = nil
        sourcePlate.clear(); preparedSwitch = nil; releaseFlightHidden();frozenSourceTranscripts=[]
        if let observer = preparationObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        preparationObserver = nil
        for observation in preparationInputObservations {NotificationCenter.default.removeObserver(observation)}
        preparationInputObservations=[];preparationTitleObservation=nil
        if let observation=preparationDisplayObservation {NativeDisplayOptions.shared.removeObserver(observation)}
        if let observation=preparationAppearanceObservation {NativeAppearance.removeObserver(observation)}
        preparationDisplayObservation=nil;preparationAppearanceObservation=nil
        if let observer = preparationStoreObservation { scene.store.removeObserver(observer) }; preparationStoreObservation = nil
        if let observer = preparationMenuObservation { NotificationCenter.default.removeObserver(observer) }; preparationMenuObservation = nil
        if let monitor = preparationMouseMonitor { NSEvent.removeMonitor(monitor) }; preparationMouseMonitor = nil
    }

    private func modeStoreChanged() {
        invalidateModePreparationInputs()
        lastModeStoreChange=CACurrentMediaTime()
        if ModeFlight.orreryEnabled {invalidateContentPicture(reason:contentInvalidationReason())}
        refreshFlightEndpoints()
        scheduleFlightEndpointRefresh()
        #if M11_MODE_SELFTEST
        if verificationLegacyPreparationRules {cancelModePreparation();return}
        #endif
        // Body deltas never cancel geometry/row endpoints. Only the picture phase is revision-bound.
        if preparationBatch?.kind == .source {cancelModePreparation()}
        scheduleModePrewarm(reason:"store.change")
    }
    private var modeSourceQuiet:Bool {CACurrentMediaTime()-lastModeStoreChange>=0.6}
    private var geometryPrepared:Bool {preparedSwitch?.geometryKey == modeGeometryKey()}
    private func markCardsLeavingNormie() {
        guard mode == .normie else {return}
        var full=Set(workbench.selectedConversation.map{[$0.id]} ?? [])
        if scene.isFocused {full.formUnion(scene.columns.map(\.conversation.id))}
        workbench.detail.markApprovalCards(movingToColumns:full)
    }
    func scheduleModePrewarm(reason: String) {
        guard Self.preparesModes,!workbench.transcriptSessions.isDisposed,pendingMode == nil,!flight.running else{return}
        if ModeFlight.orreryEnabled,contentEpochCompletionPending || contentOpening || contentSession != nil {return}
        if ModeFlight.orreryEnabled {scheduleContentPicture(reason:reason)}
        markCardsLeavingNormie()
        if preparedSwitch?.hasSource == true,preparedSwitch?.key == modePreparationKey() {return}
        if ModeFlight.orreryEnabled,geometryPrepared,contentPreparedSourceKey == modePreparationKey() {return}
        if let batch=preparationBatch,batch.kind == .geometry,batch.key == modeGeometryKey() {return}
        if preparingMode {return}
        let geometry=geometryPrepared
        if preparationTask != nil,reason != "store.change" {return}
        preparationTask?.cancel();preparationGeneration &+= 1
        let generation=preparationGeneration
        let delay=geometry ? max(0,lastModeStoreChange+0.6-CACurrentMediaTime()):0
        let task=DispatchWorkItem { [weak self] in
            guard let self,self.preparationGeneration == generation else{return};self.preparationTask=nil
            guard self.pendingMode == nil,!self.flight.running,self.view.window?.isVisible == true else{return}
            self.prepareModeSwitch(reason:reason)
        }
        preparationTask=task
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:task)
    }

    /// Compare ordinary presentation values. No reflective description or formatted header tree is
    /// built on an unchanged beforeWaiting wakeup; all consumers share the same cached value.
    private func modePreparationKey() -> ModePreparationKey {
        let input=readModePreparationInput()
        if let cachedPreparationInput,cachedPreparationInput == input {return cachedPreparationInput}
        preparationKeyBuilds+=1;cachedPreparationInput=input
        return input
    }
    private func readModePreparationInput() -> ModePreparationKey {
        let models = scene.store.conversations.map {
            ModePreparationKey.Model(identity: ObjectIdentifier($0), revision: $0.revision, draft: $0.draft, attachments: $0.attachments)
        }
        var viewports = workbench.transcriptSessions.transcripts.values.sorted { $0.conversation.id < $1.conversation.id }.map {
            ModePreparationKey.Viewport(identity: ObjectIdentifier($0), frame: $0.frame, scroll: $0.scrollOffset, revision: $0.captureRevision,
                                        editor: "", selection: NSRange(location: 0, length: 0), marked: NSRange(location: NSNotFound, length: 0))
        }
        for c in scene.members {
            if let editor = scene.composers.existingComposer(for: c.id) {
                viewports.append(.init(identity: ObjectIdentifier(editor), frame: editor.frame,
                                       scroll: editor.scrollView.contentView.bounds.origin, revision: 0, editor: editor.text,
                                       selection: editor.textView.selectedRange(), marked: editor.textView.markedRange()))
            }
        }
        if let editor = workbench.detail.composer, !viewports.contains(where: { $0.identity == ObjectIdentifier(editor) }) {
            viewports.append(.init(identity: ObjectIdentifier(editor), frame: editor.frame, scroll: editor.scrollView.contentView.bounds.origin,
                                   revision: 0, editor: editor.text, selection: editor.textView.selectedRange(), marked: editor.textView.markedRange()))
        }
        return .init(mode:admittedMode.rawValue, size: view.bounds.size, scale: view.window?.backingScaleFactor ?? scene.scale,
                     appearance: NativeAppearance.revision, reduced: Motion.reduce,
                     selected: workbench.selectedConversation?.id ?? "", current: scene.current, order: scene.order,
                     rows: workbench.sidebarModel.rows.map(\.key), sidebarScroll: workbench.sidebar.scrollView.contentView.bounds.origin,
                     display: (view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0,
                     contrast: NativeDisplayOptions.shared.revision,
                     flags: ["\(scene.composingNew)", "\(scene.isFocused)", "\(workbench.composingNew)", "\(workbench.isTerminalShown)",
                             "\(inspectorShown)", workbench.sidebar.searchField.stringValue, "\(view.window?.firstResponder?.hash ?? 0)",
                             modeSidebarFrameKey, workbench.account.initials,workbench.account.name,workbench.account.plan,"\(workbench.account.daybreak)","\(workbench.account.fullyFocused)", view.window?.title ?? "",
                             "\(workbench.isCollapsed)", workbench.sidebarModel.renaming ?? "", workbench.sidebarModel.renameText,
                             scene.columns.map { $0.conversation.id }.joined(separator: ";"),
                             scene.dockTargets.map { "\($0.id):\(NSStringFromRect(scene.dockFrame(of: $0.id) ?? .zero))" }.joined(separator: ";")],
                     models: models, viewports: viewports,headerStates:scene.columns.map {$0.island?.state},headerRects:scene.columns.map {$0.island?.orb.glassView.frame ?? .zero},deviceStatus:ModeFlight.orreryEnabled ? scene.store.devices.map {"\($0.id):\($0.online):\($0.name):\($0.isLocal)"}.sorted():[],scheme:scene.scheme)
    }

    /// In Organic the Normie sidebar is hidden: preparing its layout resizes it and AppKit puts it back a turn later,
    /// so its frame there says nothing about the screen, and keying on it cancelled every preparation.
    private var modeSidebarFrameKey:String {
        #if M11_MODE_SELFTEST
        if verificationLegacyPreparationRules {return NSStringFromRect(workbench.sidebar.view.frame)}
        #endif
        return admittedMode == .organic ? "":NSStringFromRect(workbench.sidebar.view.frame)
    }
    private var modeGeometryBatchKey:ModePreparationKey {
        #if M11_MODE_SELFTEST
        if verificationLegacyPreparationRules {return modePreparationKey()}
        #endif
        return modeGeometryKey()
    }

    private func modeGeometryKey()->ModePreparationKey {
        var key=modePreparationKey();key.models=[];key.viewports=[];key.headerStates=[];key.headerRects=[]
        key.flags=["\(inspectorShown)",modeSidebarFrameKey,workbench.account.initials,workbench.account.name,workbench.account.plan,"\(workbench.account.daybreak)","\(workbench.account.fullyFocused)",workbench.sidebarModel.renaming ?? "",workbench.sidebarModel.renameText,
                   admittedMode == .organic ? scene.columns.map {"\($0.conversation.id):\(NSStringFromRect($0.island?.orb.glassView.frame ?? .zero))"}.joined(separator:";"):"",
                   admittedMode == .organic ? scene.dockTargets.map {"\($0.id):\(NSStringFromRect(scene.dockFrame(of:$0.id) ?? .zero))"}.joined(separator:";"):"",
                   "\(scene.composingNew)","\(workbench.composingNew)","\(workbench.isTerminalShown)"]
        return key
    }
    /// A detached host is supported by the offscreen verifier. Production admission still requires a real window.
    func prepareModeSwitch(reason: String) {
        guard Self.preparesModes, !preparingMode, pendingMode == nil, !flight.running, !scene.isMoving, !workbench.isCollapsed, workbench.canHandoff else { return }
        if ModeFlight.orreryEnabled,contentEpochCompletionPending || contentOpening || contentSession != nil {return}
        if admittedMode == .organic, scene.columns.contains(where: { $0.island?.motionIsRunning == true }) { return }
        if preparedSwitch?.hasSource == true,preparedSwitch?.key == modePreparationKey() {return}
        if ModeFlight.orreryEnabled,geometryPrepared,contentPreparedSourceKey == modePreparationKey() {return}
        if geometryPrepared {if modeSourceQuiet {prepareModeSource(reason:reason)};return}
        preparingMode = true
        let batch=ModePreparationBatch(key:modeGeometryBatchKey,reason:reason,kind:.geometry)
        preparationBatch=batch
        var organicTarget:AutoScene.ModeTargetPlan?
        var sidebarBuilder:ModeSurfaceBuilder?
        var sidebarPicture:ModeSurfacePicture?
        var rows:[String:CGRect]=[:], avatar=CGRect.zero, headers:[ModeHeaderEndpoint]=[]
        var forward:[ModeFlight.Token]=[], reverse:[ModeFlight.Token]=[]
        var warmed=0
        var sidebarRow=0
        var sidebarImage:CGImage?
        var sidebarImageKey=""
        batch.steps.append { [self] in scene.dock.composerMotion.prewarmModeStep() }
        batch.steps.append { [self] in
            if admittedMode == .organic {
                // Do not expand/layout a hidden NSSplitView: AppKit can update window chrome and shared viewports.
                let size=view.bounds.size
                let width=min(NormieSidebarMetrics.maximumWidth,max(NormieSidebarMetrics.minimumWidth,lastNormieSidebarWidth ?? size.width*NormieSidebarMetrics.preferredThicknessFraction))
                let top=view.window == nil ? 0:lastNormieTopInset
                workbench.sidebar.prepareModeLayout(size:CGSize(width:width,height:size.height),safeRect:CGRect(x:0,y:top,width:width,height:max(0,size.height-top)))
                workbench.detail.prewarmModeChrome(size:CGSize(width:max(1,size.width-width),height:size.height),safeRect:CGRect(x:0,y:top,width:max(1,size.width-width),height:max(0,size.height-top)))
            } else if let selected=workbench.selectedConversation?.id {
                organicTarget=scene.beginModeTarget(selected:selected);preparingOrganicTarget=organicTarget
            }
            return true
        }
        batch.steps.append { [self] in
            let sidebar=workbench.sidebar
            guard sidebarRow<sidebar.model.rows.count else{return true}
            let row=sidebarRow;sidebarRow+=1
            if sidebar.table.rect(ofRow:row).intersects(sidebar.scrollView.contentView.bounds) {
                _=ModeSignposts.measure("PrewarmSidebarRow",detail:"row=\(row)") {
                    sidebar.prepareModeRow(row)
                }
            }
            return sidebarRow==sidebar.model.rows.count
        }
        batch.steps.append { [self] in
            if admittedMode == .organic,let item=split.splitViewItems.first {
                // Cells already exist. Resolve AppKit's actual restored sidebar width while the entire target is hidden.
                let collapsed=item.isCollapsed
                ModeSignposts.measure("PrewarmNormieGeometry") {
                    CATransaction.begin();CATransaction.setDisableActions(true)
                    item.isCollapsed=false;split.view.layoutSubtreeIfNeeded()
                    let width=max(NormieSidebarMetrics.minimumWidth,workbench.sidebar.view.bounds.width)
                    item.isCollapsed=collapsed;split.view.layoutSubtreeIfNeeded()
                    let size=view.bounds.size,top=view.window == nil ? 0:lastNormieTopInset
                    workbench.sidebar.prepareModeLayout(size:CGSize(width:width,height:size.height),safeRect:CGRect(x:0,y:top,width:width,height:max(0,size.height-top)))
                    workbench.detail.prewarmModeChrome(size:CGSize(width:max(1,size.width-width),height:size.height),safeRect:CGRect(x:0,y:top,width:max(1,size.width-width),height:max(0,size.height-top)))
                    CATransaction.commit()
                }
            }
            let scale=view.window?.backingScaleFactor ?? scene.scale
            rows=sidebarRows(warming:true);avatar=sidebarAvatar()
            headers=organicTarget?.headers ?? headerEndpoints()
            sidebarImageKey=workbench.sidebar.modeContentKey
            let flying = openingTokens(admittedMode == .organic ? .normie : .organic, rows: rows, headers: headers, target: organicTarget)
            let exclusions = [workbench.sidebar.accountView.avatar] + workbench.sidebar.flightSourceViews(for: Set(flying.map { $0.conversation.id }))
            if !ModeFlight.orreryEnabled {sidebarBuilder=ModeSurfaceBuilder(workbench.sidebar.view,scale:scale,includeWindowFrame:false,excluding:exclusions,detached:workbench.sidebar.preparedModeDrawingRows)}
            return true
        }
        batch.steps.append {
            if ModeFlight.orreryEnabled {sidebarPicture=ModeSurfacePicture(tiles:[],glasses:[],size:CGSize(width:1,height:1),scale:1);return true}
            sidebarBuilder?.step();sidebarPicture=sidebarBuilder?.finish();return sidebarPicture != nil
        }
        batch.steps.append { [self] in
            (forward,reverse)=ModeSignposts.measure("PrewarmModePlans") {
                (openingTokens(.organic,rows:rows,headers:headers,target:organicTarget),openingTokens(.normie,rows:rows,headers:headers))
            }
            let towardOrganic=admittedMode == .normie
            var trip:(from:CGRect,to:CGRect,slot:Int)?
            if towardOrganic,let target=organicTarget,let source=workbench.detail.composerDockFrame.map({view.convert($0,from:nil)}),let i=target.order.prefix(target.layout.bars.count).firstIndex(of:target.current) {trip=(source,target.layout.bars[i],i)}
            ModeSignposts.measure("PrewarmServerMotion") {flight.prewarmServerMotion(toOrganic:towardOrganic,avatar:towardOrganic ? (avatar,organicTarget?.me ?? scene.meRest):(scene.meRest,avatar),tokens:towardOrganic ? forward:reverse,composer:trip)}
            return true
        }
        batch.steps.append { [self] in
            let tokens=admittedMode == .organic ? reverse:forward
            guard warmed<tokens.count else{return true}
            warmed+=1
            ModeSignposts.measure("PrewarmModeFlight"){flight.prewarm(tokens:Array(tokens.prefix(warmed)))}
            return warmed==tokens.count
        }
        func publish(_ picture:ModeSurfacePicture?,complete:Bool) {
            guard let sidebar=sidebarPicture else{return}
            if sidebarImage == nil {sidebarImage=sidebar.flattened()}
            let picture=picture ?? ModeSurfacePicture(tiles:[],glasses:[],size:view.bounds.size,scale:scene.scale)
            let top=admittedMode == .organic && view.window != nil ? lastNormieTopInset:(workbench.sidebar.view as? NormieView)?.contentSafeRect.minY ?? 0
            if complete {bankFlightPicture(picture,mode:admittedMode.rawValue)}
            preparedSwitch = .init(key:modePreparationKey(),geometryKey:modeGeometryKey(),hasSource:complete,source:picture,sidebarContentKey:sidebarImageKey,sidebar:sidebarImage!,rows:rows,avatar:avatar,
                headers:headers,toOrganic:forward,toNormie:reverse,composer:workbench.detail.composerDockFrame.map{view.convert($0,from:nil)},
                sidebarSafeRect:CGRect(x:0,y:top,width:workbench.sidebar.view.bounds.width,height:max(0,workbench.sidebar.view.bounds.height-top)),organicTarget:organicTarget)
            lastFlightGeometry=preparedSwitch
            if complete {sourcePlate.stage(picture,in:view,below:flight.view)}
        }
        batch.steps.append {publish(nil,complete:false);return true}
        batch.finish = {ModeSignposts.current?.record("ModeGeometryReady",detail:"tokens=\(forward.count)/\(reverse.count)")}
        runModePreparation(batch)
    }

    private func prepareModeSource(reason:String) {
        guard let prepared=preparedSwitch,geometryPrepared,modeSourceQuiet else{return}
        preparingMode=true
        let batch=ModePreparationBatch(key:modePreparationKey(),reason:"source."+reason,kind:.source)
        preparationBatch=batch
        var row=0,column=0,widthIndex=0
        var builder:ModeSurfaceBuilder?,target=prepared.organicTarget
        batch.steps.append { [self] in
            guard admittedMode == .normie,let selected=workbench.selectedConversation?.id else{return true}
            if target == nil || !scene.modeTargetIsValid(target!) {target=scene.beginModeTarget(selected:selected);preparingOrganicTarget=target}
            guard let target else{return true}
            return scene.prepareModeTargetStep(target)
        }
        batch.steps.append { [self] in
            if admittedMode == .organic,let c=scene.conversation(scene.current) {
                let widths=Array(Set([workbench.detail.view.bounds.width,view.bounds.width-NormieSidebarMetrics.minimumWidth,view.bounds.width-NormieSidebarMetrics.maximumWidth])).sorted()
                guard widthIndex<widths.count else{return true}
                if !ModeSignposts.measure("PrewarmNativeRow",{workbench.transcriptSessions.transcript(for:c,store:scene.store).prepareModeRow(width:widths[widthIndex],cursor:&row)}) {return false}
                widthIndex+=1;row=0;return widthIndex==widths.count
            }
            guard let target=target,column<target.columns.count else{return true}
            let pair=target.columns[column]
            if scene.isFocused || pair.0.conversation.id == target.current {
                if !ModeSignposts.measure("PrewarmNativeRow",{pair.0.native.prepareModeRow(width:pair.1.area.width,cursor:&row)}) {return false}
            }
            column+=1;row=0;return column==target.columns.count
        }
        batch.steps.append { [self] in
            if ModeFlight.orreryEnabled {scheduleContentPicture(reason:reason);return true}
            builder=ModeSignposts.measure("PrewarmSourceIndex") {ModeSurfaceBuilder(view,scale:view.window?.backingScaleFactor ?? scene.scale,includeWindowFrame:false,excluding:[flight.view,sourcePlate],normalizeRootOpacity:true)};return true
        }
        batch.steps.append {if ModeFlight.orreryEnabled {return true};builder?.step();return builder?.ready == true}
        batch.finish = { [self] in
            if ModeFlight.orreryEnabled {contentPreparedSourceKey=modePreparationKey();return}
            guard let picture=builder?.finish() else{return}
            bankFlightPicture(picture,mode:admittedMode.rawValue)
            preparedSwitch = .init(key:modePreparationKey(),geometryKey:prepared.geometryKey,hasSource:true,source:picture,
                sidebarContentKey:prepared.sidebarContentKey,sidebar:prepared.sidebar,rows:prepared.rows,avatar:prepared.avatar,
                headers:prepared.headers,toOrganic:prepared.toOrganic,toNormie:prepared.toNormie,composer:prepared.composer,
                sidebarSafeRect:prepared.sidebarSafeRect,organicTarget:target)
            sourcePlate.stage(picture,in:view,below:flight.view)
        }
        runModePreparation(batch)
    }
    private func runModePreparation(_ batch:ModePreparationBatch) {
        #if M11_MODE_SELFTEST
        if verificationSlicedPreparation {return}
        #endif
        if view.window == nil {while preparationBatch === batch {runPreparationSlice(schedule:false)}}
        else {runPreparationSlice(schedule:true)}
    }

    private func runPreparationSlice(schedule:Bool) {
        guard let batch=preparationBatch else{return}
        guard batch.key == (batch.kind == .geometry ? modeGeometryBatchKey:modePreparationKey()), pendingMode == nil, !flight.running else {cancelModePreparation();return}
        let finished=batch.step()
        batch.key=batch.kind == .geometry ? modeGeometryBatchKey:modePreparationKey() // only hidden geometry may change in this slice
        if finished {
            ModeSignposts.withTrace(batch.trace) {batch.finish?()};batch.end(cancelled:false);preparationBatch=nil;preparingMode=false
            if batch.kind == .geometry {
                #if M11_MODE_SELFTEST
                if verificationSlicedPreparation {return}
                #endif
                if view.window == nil,modeSourceQuiet {prepareModeSource(reason:"geometry.ready")}
                else {scheduleModePrewarm(reason:"geometry.ready")}
            }
        } else if schedule {
            let generation=preparationGeneration
            let task=DispatchWorkItem { [weak self] in
                guard let self,self.preparationGeneration == generation else{return}
                self.preparationTask=nil;self.runPreparationSlice(schedule:true)
            }
            preparationTask=task
            DispatchQueue.main.asyncAfter(deadline:.now()+(ModeFlight.orreryEnabled ? flight.presentationInterval:0.002),execute:task)
        }
    }
    private func cancelModePreparation() {
        preparationBatch?.end(cancelled:true);preparationBatch=nil;preparingMode=false
        preparationGeneration &+= 1;preparationTask?.cancel();preparationTask=nil
    }

    private func sidebarRows(warming: Bool = false,reusingPrepared:Bool=false) -> [String: CGRect] {
        let sidebar = workbench.sidebar
        // visibleRect is empty under the hidden split. Its already-sized clip bounds describe the target viewport.
        var visible = warming || reusingPrepared ? sidebar.scrollView.contentView.bounds : sidebar.table.visibleRect
        if warming,visible.height <= 0 {visible.size.height=view.bounds.height}
        var result: [String: CGRect] = [:]
        for (index, row) in sidebar.model.rows.enumerated() {
            guard let id=row.conversationID,sidebar.table.rect(ofRow:index).intersects(visible) else{continue}
            if warming {
                if sidebar.preparedModeFrame(index) == nil {_=sidebar.prepareModeRow(index)}
            }
            if warming || reusingPrepared,let rect=sidebar.preparedModeFrame(index) {
                result[id]=admittedMode == .organic ? rect:sidebar.view.convert(rect,to:view)
            } else if let cell=sidebar.table.view(atColumn:0,row:index,makeIfNecessary:false) as? NormieSidebarCell {
                result[id]=cell.convert(cell.flightSourceRect,to:admittedMode == .organic ? sidebar.view:view)
            } else if reusingPrepared {
                // A cold hidden NSTableView need not allocate/layout a cell just to read its 16 pt endpoint.
                let nested:Bool
                if case .conversation(_,let project)=row {nested=project != nil} else {nested=false}
                let frame=sidebar.table.rect(ofRow:index)
                let rect=CGRect(x:frame.minX+(nested ? NormieSidebarMetrics.nestedTitleX+4:NormieSidebarMetrics.iconX+2),
                                y:frame.midY-8,width:16,height:16)
                let local=sidebar.table.convert(rect,to:sidebar.view)
                result[id]=admittedMode == .organic ? local:sidebar.view.convert(local,to:view)
            }
        }
        return result
    }
    private func sidebarAvatar() -> CGRect {
        let avatar = workbench.sidebar.accountView.avatar
        return avatar.convert(avatar.bounds, to: admittedMode == .organic ? workbench.sidebar.view : view)
    }
    private func headerEndpoints() -> [ModeHeaderEndpoint] {
        guard Self.fliesHeaders else { return [] }
        return scene.columns.compactMap { column in
            guard let island = column.island, !island.isHidden else { return nil }
            let glass = island.orb.glassView
            let rect = glass.convert(glass.bounds, to: view)
            guard rect.width > 0 else { return nil }
            return .init(id: column.conversation.id, conversation: column.conversation, rect: rect)
        }
    }
    /// Only the owning native mode may expose endpoints. Photos retain their existing, independent fade.
    private func hasForegroundContentOwner(_ target:Mode) -> Bool {
        let root=target == .organic ? organic:normieBodyRoot
        guard exposed(root) else {return false}
        let others=target == .organic ? normieBodyRoots:[organic]
        return others.allSatisfy { other in
            other.bounds.width<=0 || other.isHidden || other.alphaValue<=0.001 || other.layer?.isHidden == true ||
                (other.layer?.presentation()?.opacity ?? other.layer?.opacity ?? 1)<=0.001
        }
    }
    /// Logical admission cannot substitute for the selected shared views' actual parent chain.
    private func nativeContentBelongs(to target:Mode) -> Bool {
        let root=target == .organic ? organic:normieBodyRoot
        let identity=target == .organic ? scene.current:workbench.selectedConversation?.id
        guard let identity else {return true}
        if let transcript=workbench.transcriptSessions.existingTranscript(for:identity),!transcript.isDescendant(of:root) {return false}
        if let composer=scene.composers.existingComposer(for:identity),!composer.isDescendant(of:root) {return false}
        return true
    }
    private func nativeHandoffAllowed() -> Bool {
        return (!ModeFlight.orreryEnabled || scene.composers.modeContentCanHandoff) && !workbench.transcriptSessions.isDisposed && workbench.canHandoff && scene.transcriptSessions?.canHandoff != false
    }
    /// Data migration may be skipped; visibility, chrome and native policy are always repaired atomically.
    private func finalizeNativeOwner(_ target:Mode,window:NSWindow?,preserveTargetFade:Bool=false) {
        let wanted=target == .organic ? organic:normieBodyRoot
        let unwanted=target == .organic ? normieBodyRoots:[organic]
        for root in unwanted {
            // Organic is the opaque base throughout a content session. Even a synchronous hide/show
            // notifies its header descendants and collapses a live status capsule before the fade.
            if ModeFlight.orreryEnabled,(contentOpening || contentSession != nil),root === organic {continue}
            root.layer?.removeAllAnimations();root.isHidden=true;root.alphaValue=1;root.layer?.opacity=1
        }
        if !preserveTargetFade {wanted.layer?.removeAllAnimations()}
        else {wanted.layer?.removeAnimation(forKey:"mode.turn.native-out")}
        wanted.isHidden=false;wanted.alphaValue=1;wanted.layer?.opacity=1
        if target == .normie,ModeFlight.orreryEnabled {
            for (root,item) in zip(normieBodyRoots,split.splitViewItems.dropFirst()) {
                root.isHidden=item.isCollapsed;root.alphaValue=1;root.layer?.opacity=1
            }
        }
        split.splitView.needsDisplay=true
        workbench.isNormie=target == .normie;workbench.sidebarVisible=target == .normie
        setModeToolbar(target == .normie,in:window ?? view.window)
        if target == .normie || turnSidebar.usesNativeHost {split.splitViewItems.first?.isCollapsed=false}
        if ModeFlight.orreryEnabled,!contentOpening,contentSession == nil,target == .normie {
            for column in scene.columns {column.island?.setPulsePresentationRetired(true)}
        }
        if turnSidebar.usesNativeHost,!turnSidebar.isActive,!contentOpening,contentSession == nil {turnSidebar.settleNative(incoming:target == .normie)}
    }
    private func rejectNativeCommit(preserving owner:Mode,window:NSWindow?) {
        transitionGeneration &+= 1;admission.cancel();cancelModePreparation();pendingMode=nil;mode=owner
        flight.cancel();turnSidebar.finish();releaseFlightHidden();workbench.sidebar.setFlightSourcesHidden([],avatar:false)
        finalizeNativeOwner(owner,window:window)
        // A staged transfer can own shared views behind a complete source cover. Do not discard that cover on rejection.
        if !normieNativeStaged {sourcePlate.clear()}
        scene.endModeHandoff();scene.dock.composerMotion.endModeHandoff();workbench.detail.endModeHandoff()
        workbench.detail.setModeComposerMaterialInFlight(false);workbench.detail.freezeModeLayout(false)
        if !normieNativeStaged {resumeSourceTranscripts();clearTranscriptStandIns()}
        onModeChange?(owner)
    }
    private func exposed(_ target: NSView,covering footprint:NSView?=nil) -> Bool {
        if target === organic || target.isDescendant(of:organic),
           !contentSidebarCutout.fullyExposes((footprint ?? target).convert((footprint ?? target).bounds,to:organic),at:contentNow) {return false}
        var node: NSView? = target
        while let view = node {
            if view.isHidden || view.alphaValue < 0.999 || view.layer?.isHidden == true || (view.layer?.presentation()?.opacity ?? view.layer?.opacity ?? 1) < 0.999 { return false }
            node = view.superview
        }
        return target.superview != nil && target.bounds.width > 0
    }
    private func rowFullyCoversFlight(_ conversation:String) -> Bool {
        for (index,row) in workbench.sidebar.model.rows.enumerated() where row.conversationID == conversation {
            guard let cell=workbench.sidebar.table.view(atColumn:0,row:index,makeIfNecessary:false) as? NormieSidebarCell else {return false}
            return workbench.sidebar.fullyCoversFlightIdentity(cell.planet) || flight.rowCoverageMatches(conversation)
        }
        return false
    }
    /// The flight cache describes our last write, not a later native layout/display commit.
    private func organicAvatarGlass()->NSGlassEffectView? {
        guard let rect=scene.meFrame else {return nil}
        func find(in host:NSView)->NSGlassEffectView? {
            for view in host.subviews {
                if let glass=view as? NSGlassEffectView,MotionStep.edge(glass.convert(glass.bounds,to:self.view),rect)<0.5 {return glass}
                if let found=find(in:view) {return found}
            }
            return nil
        }
        return find(in:scene.dockView)
    }
    /// Selection can exchange a column and a Dock orb while their original flight IDs stay fixed.
    private func organicFlightSurface(_ id:String)->(glass:NSView,ink:NSView,alternate:NSView?)? {
        if id == "me" {return organicAvatarGlass().map {($0,$0,nil)}}
        let conversation=id.hasPrefix("header.") ? String(id.dropFirst(7)):id
        let absorbed=flight.activeTokens.first {$0.id == id}?.absorbed == true
        if !absorbed,let island=scene.columns.first(where:{$0.conversation.id == conversation})?.island {
            return (island.orb.glassView,island.orb.frontView,nil)
        }
        guard let item=scene.dock.items[conversation] else {return nil}
        return (item.glass,item.role == .bar ? item.barFace:item.decoration.frontView,item.role == .bar ? nil:item.identity?.frontView)
    }
    private func flightOwnerFailure(_ id:String)->String {
        var surface=organicFlightSurface(id)
        if mode == .normie {
            if id == "me" {let avatar=workbench.sidebar.accountView.avatar;surface=(avatar,avatar,nil)}
            else {
                let conversation=id.hasPrefix("header.") ? String(id.dropFirst(7)):id
                let index=workbench.sidebar.model.rows.firstIndex {$0.conversationID == conversation}
                let planet=index.flatMap {workbench.sidebar.table.view(atColumn:0,row:$0,makeIfNecessary:false) as? NormieSidebarCell}?.planet
                surface=planet.map {($0,$0,nil)}
            }
        }
        func chain(_ target:NSView?)->String {
            guard let target else {return "missing"};var node:NSView?=target,parts:[String]=[]
            while let v=node {parts.append("\(type(of:v))[h=\(v.isHidden),lh=\(v.layer?.isHidden ?? false),a=\(v.alphaValue),p=\(v.layer?.presentation()?.opacity ?? v.layer?.opacity ?? 1)]");node=v.superview}
            return parts.joined(separator:">")
        }
        let phase=contentSession.map {"u=\($0.progress(at:contentNow)),end=\($0.atDestination(contentNow)),exposes=\(contentRepresentationExposesEndpoint($0))"} ?? "none"
        let footprint=surface.map {exposed($0.glass)} ?? false
        return "mode=\(mode.rawValue)/\(admittedMode.rawValue),opening=\(contentOpening),meHidden=\(meFlightHidden),footprint=\(footprint),side=\(turnSidebar.rowOffset(at:contentNow)),phase=\(phase),native=\(chain(surface?.glass)),ink=\(chain(surface?.ink))"
    }
    private func currentFlightOwnerFrame(_ id:String)->CGRect? {
        guard mode == .organic else {return nil}
        return organicFlightSurface(id).map {M10SidebarExposure.presentedRect($0.glass,in:view)}
    }
    private func flightOwnerVisible(_ id: String) -> Bool {
        let started=flight.onExposureCost == nil ? 0:CACurrentMediaTime()
        defer {flight.onExposureCost?("owners.read",CACurrentMediaTime()-started)}
        if let session=contentSession {
            guard !contentOpening,session.requestedMode == mode.rawValue,session.atDestination(contentNow),contentRepresentationExposesEndpoint(session) else {return false}
        } else {
            guard pendingMode == nil,admittedMode == mode,sourcePlate.picture == nil,hasForegroundContentOwner(mode) else {return false}
        }
        if mode == .organic {
            if id == "me",meFlightHidden {return false}
            guard let surface=organicFlightSurface(id),exposed(surface.glass),
                  exposed(surface.ink,covering:surface.glass) || surface.alternate.map({exposed($0,covering:surface.glass)}) == true else {return false}
            let actual=M10SidebarExposure.presentedRect(surface.glass,in:view)
            if let current=flight.currentDestinationRect(id) {return MotionStep.edge(actual,current)<0.5}
            if id == "me" {return flight.avatarEndpoints(toOrganic:true).map {MotionStep.edge(actual,$0.to)<0.5} ?? true}
            return flight.activeTokens.first {$0.id == id}.map {$0.absorbed || MotionStep.edge(actual,$0.to)<0.5} ?? false
        }

        if id == "me" {
            let native=workbench.sidebar.accountView.avatar
            return exposed(native) && (flight.avatarEndpoints(toOrganic:false).map {MotionStep.edge(M10SidebarExposure.presentedRect(native,in:view),$0.to)<0.5} ?? false)
        }
        let conversation = id.hasPrefix("header.") ? String(id.dropFirst(7)):id
        for (index,row) in workbench.sidebar.model.rows.enumerated() where row.conversationID == conversation {
            if let cell=workbench.sidebar.table.view(atColumn:0,row:index,makeIfNecessary:false) as? NormieSidebarCell {
                let planet=cell.planet.convert(cell.planet.bounds,to:workbench.sidebar.table)
                let matchingCoverage=flight.rowCoverageMatches(conversation) && (flight.activeTokens.first {$0.conversation.id == conversation}.map {flight.arrived($0.id,at:flight.ownerTime)} ?? false)
                guard (workbench.sidebar.scrollView.contentView.bounds.contains(planet) && workbench.sidebar.fullyCoversFlightIdentity(cell.planet)) || matchingCoverage else {return false}
                return exposed(cell.planet) && (flight.activeTokens.first(where:{$0.conversation.id == conversation}).map {MotionStep.edge(M10SidebarExposure.presentedRect(cell.planet,in:view),$0.to.offsetBy(dx:-3,dy:-1))<0.5} ?? false)
            }
        }
        return false
    }
    private func publishFlightOwners(at time: Double) {
        guard ModeFlight.orreryEnabled else { return }
        defer {contentComposerInk.refresh()}
        #if M11_MODE_SELFTEST
        verificationOwnerRequests+=1
        #endif
        let tokens=flight.activeTokens
        if mode == .normie {
            let hideMe = !flight.sourceOwnerNeedsCommit
            if meFlightHidden != hideMe {scene.setMeHidden(hideMe);meFlightHidden=hideMe}
            for token in tokens {
                let show=flight.organicSourceAtRest(token.id,at:time)
                if token.id.hasPrefix("header.") { if show { revealHeader(token.id) } else { hideHeader(token.id) } }
                else if show {
                    if flightHidden.remove(token.id) != nil { scene.setDockHidden(token.id,false) }
                } else if !flightHidden.contains(token.id) {
                    scene.setDockHidden(token.id,true);flightHidden.insert(token.id)
                }
            }
        }
        if mode == .organic {
            let barReady = !composerFlightAwaitingRegistration && flight.barArrived(at:time)
            if let id=composerFlightBar,!barReady,!flightHidden.contains(id) {scene.setDockHidden(id,true);flightHidden.insert(id)}
            let active=Set(tokens.map(\.id))
            for id in Array(headerHidden.keys) where !active.contains(id) { revealHeader(id) }
            for id in flightHidden where !active.contains(id) && (id != composerFlightBar || barReady) {scene.setDockHidden(id,false);flightHidden.remove(id)}
            if barReady {composerFlightBar=nil}
            let hideMe = time < flight.avatarHandoff
            let nativeMeHidden = !hideMe && organicAvatarGlass()?.isHidden == true
            if meFlightHidden != hideMe || nativeMeHidden {
                if nativeMeHidden,!meFlightHidden {flight.destinationPaintReasserted("me");contentTrace?.record("ModeNativeOwnerReassert",detail:"id=me reason=native-paint-after-publish")}
                scene.setMeHidden(hideMe);meFlightHidden=hideMe
            }
            for token in tokens where flight.arrived(token.id,at:time) {
                if !token.absorbed {
                    let currentHeader="header."+token.conversation.id
                    if scene.columns.contains(where:{$0.conversation.id == token.conversation.id}) {revealHeader(currentHeader)}
                    else if scene.dock.items[token.conversation.id]?.role == .orb {
                        scene.setDockHidden(token.conversation.id,false);flightHidden.remove(token.conversation.id)
                    }
                }
                if token.id.hasPrefix("header.") { revealHeader(token.id) }
                else if token.id != composerFlightBar || barReady {
                    let cachedHidden=flightHidden.remove(token.id) != nil
                    let native=scene.dock.items[token.id]?.glass
                    let nativeHidden=native?.isHidden == true || native?.layer?.isHidden == true
                    if cachedHidden || nativeHidden {
                        if nativeHidden,!cachedHidden {flight.destinationPaintReasserted(token.id);contentTrace?.record("ModeNativeOwnerReassert",detail:"id=\(token.id) reason=native-paint-after-publish")}
                        scene.setDockHidden(token.id,false)
                    }
                }
            }
            workbench.sidebar.setFlightSourcesHidden(time.isFinite ? Set(tokens.map { $0.conversation.id }):[],avatar:time.isFinite)
        } else {
            let held=flight.heldConversationIDs
            let waiting=Set(tokens.filter {
                !flight.arrived($0.id,at:time) || (held.contains($0.conversation.id) && (flightRowsAwaitingRefresh || !rowFullyCoversFlight($0.conversation.id)))
            }.map { $0.conversation.id })
            workbench.sidebar.setFlightSourcesHidden(waiting,avatar:time < flight.avatarHandoff)
            if !time.isFinite { releaseFlightHidden() }
        }
    }
    private func reconcileNativeRowFence() {
        if mode == .normie,flightRowsAwaitingRefresh {
            let rows=sidebarRows(warming:false)
            if flight.activeTokens.allSatisfy({ token in rows[token.conversation.id].map {MotionStep.edge($0,token.to)<0.5} ?? false}) {flightRowsAwaitingRefresh=false}
        }
        publishFlightOwners(at:flight.ownerTime)
    }
    private func scheduleFlightEndpointRefresh() {
        guard ModeFlight.orreryEnabled,flight.running else {return}
        let geometry=flightEndpointGeometry()
        guard geometry != lastFlightEndpointGeometry else {return}
        lastFlightEndpointGeometry=geometry
        if mode == .normie {
            // Reclaim still-flying identities synchronously; expensive path reconstruction stays coalesced.
            flightRowsAwaitingRefresh=true
            workbench.sidebar.setFlightSourcesHidden(flight.heldConversationIDs,avatar:workbench.sidebar.accountView.avatar.isHidden)
            flight.reclaimPendingRowOwners()
        }
        let side=workbench.sidebar.view
        if turnSidebar.needsResize(host:view.bounds.size,source:side.bounds.size) {
            turnSidebar.reframe(source:side.bounds.size);sidebarBitmapRefreshPending=true
        }
        guard !flightEndpointRefreshScheduled else {return}
        flightEndpointRefreshScheduled=true
        // Legacy store observers have no ordering guarantee. Read rows again after the sidebar has reordered.
        DispatchQueue.main.asyncAfter(deadline:.now()+flight.presentationInterval) { [weak self] in
            guard let self else { return }
            self.flightEndpointRefreshScheduled=false
            if self.sidebarBitmapRefreshPending {
                self.sidebarBitmapRefreshPending=false
                if self.turnSidebar.isActive {
                    let side=self.workbench.sidebar.view
                    self.turnSidebar.resize(self.sidebarForeground(),host:self.view.bounds.size,source:side.bounds.size,scale:self.view.window?.backingScaleFactor ?? self.scene.scale)
                }
            }
            self.refreshFlightEndpoints()
        }
    }
    private func refreshFlightEndpoints() {
        guard ModeFlight.orreryEnabled,flight.running else { return }
        #if M11_MODE_SELFTEST
        endpointRefreshCount+=1
        #endif
        let refreshStarted=flight.onExposureCost == nil ? 0:CACurrentMediaTime()
        defer {flight.onExposureCost?("endpoints.refresh",CACurrentMediaTime()-refreshStarted)}
        let headers=headerEndpoints()
        var real=Dictionary(uniqueKeysWithValues:headers.map { ($0.tokenID,$0.rect) })
        let headerIDs=Set(headers.map(\.id))
        let targets=Dictionary(uniqueKeysWithValues:scene.dockTargets.map {($0.id,$0)})
        let absorbed=Set(scene.dockTargets.filter(\.bar).map(\.id))
        for token in flight.activeTokens where !headerIDs.contains(token.conversation.id) {
            let id=token.conversation.id
            if let rect=targets[id]?.rect ?? scene.dockFrame(of:id) {
                real[id]=absorbed.contains(id) ? CGRect(x:rect.minX+4,y:rect.midY-16,width:32,height:32):rect
            }
        }
        let rowAvatar=sidebarAvatar(),me=scene.meRest
        flight.updateEndpoints(rows:sidebarRows(warming:admittedMode == .organic),real:real,
                               avatar:flight.headingToOrganic ? (rowAvatar,me):(me,rowAvatar),absorbedIDs:absorbed)
        flightRowsAwaitingRefresh=false
        publishFlightOwners(at:flight.elapsed)
    }
    /// A turn changes the visible native destination in the same transaction as the flight clock.
    /// Cancel old admission/fade completions before they can finish the abandoned presentation.
    private func reverseOrreryPresentation(_ next: Mode,window: NSWindow?) {
        let commandStarted=CACurrentMediaTime()
        defer {onTurnCost?("command",(CACurrentMediaTime()-commandStarted)*1000)}
        let probe=ModeSignposts.current
        probe?.record("ModeTurnRetainedFlight",detail:"elapsed=\(flight.elapsed) duration=\(flight.duration) held=\(flight.heldConversationIDs.count) admitted=\(admittedMode.rawValue) requested=\(next.rawValue)")
        let sourceMode=admittedMode
        let contentKey=flightPictureKey()
        let side=workbench.sidebar.view
        let scale=window?.backingScaleFactor ?? scene.scale
        if let probe {
            for (name,key) in flightSourceKeys where key != contentKey {
                probe.record("ModeTurnPhotoInvalid",detail:"mode=\(name) models=\(key.models != contentKey.models) viewports=\(key.viewports != contentKey.viewports) selection=\(key.selected != contentKey.selected) rows=\(key.rows != contentKey.rows) device=\(key.deviceStatus != contentKey.deviceStatus)")
            }
        }
        flightSourcePictures=flightSourcePictures.filter {$0.value.size == view.bounds.size && $0.value.scale == scale && flightSourceKeys[$0.key] == contentKey}
        flightSourceKeys=flightSourceKeys.filter {flightSourcePictures[$0.key] != nil}
        if ModeFlight.orreryEnabled {ModePhotoSnapshot.freezeNativeFades(normieBodyRoot)}
        let old=flight.activeTokens
        let tokens=old.map { ModeFlight.Token(id:$0.id,conversation:$0.conversation,from:$0.to,to:$0.from,start:$0.start,absorbed:next == .normie) }
        let avatarTrip=flight.avatarEndpoints(toOrganic:next == .organic)
            ?? (next == .organic ? (sidebarAvatar(),scene.meFrame ?? scene.meRest):(scene.meFrame ?? scene.meRest,sidebarAvatar()))
        admission.cancel();cancelModePreparation();transitionGeneration &+= 1
        let generation=transitionGeneration
        pendingMode=next;mode=next;composerFlightBar=nil
        // A plan is tied to selection, not merely to its still-live source columns.
        if admissionOrganicTarget?.key.selected != workbench.selectedConversation?.id {admissionOrganicTarget=nil}
        flight.onFrame=nil
        CATransaction.begin();CATransaction.setDisableActions(true)
        flight.start(toOrganic:next == .organic,avatar:avatarTrip,initials:initials,tokens:tokens,composer:nil,reduceMotion:false)
        if turnSidebar.usesNativeHost {
            #if M11_MODE_SELFTEST
            beforeTurnSidebarCommit?()
            #endif
            turnSidebar.moveNative(incoming:next == .normie)
        }
        let targetPicture=flightSourcePictures[next.rawValue]
        let selectionMatches = next == .organic
            ? (scene.composingNew == workbench.composingNew && (workbench.composingNew || scene.current == workbench.selectedConversation?.id))
            : workbench.detail.conversation?.id == workbench.selectedConversation?.id
        let alreadyAdmitted=sourceMode == next && selectionMatches && nativeContentBelongs(to:next)
        // Freeze admission until the target curtain is opaque. A cold, invalid cache is never shown.
        sourcePlate.shieldSource(in:view,below:flight.view)
        // The turned carrier owns the source immediately, including planets already handed to native orbs.
        workbench.sidebar.setFlightSourcesHidden(Set(tokens.map {$0.conversation.id}),avatar:true)
        scene.setMeHidden(true);meFlightHidden=true
        for token in tokens {
            if token.id.hasPrefix("header.") {hideHeader(token.id)}
            else if !flightHidden.contains(token.id) {scene.setDockHidden(token.id,true);flightHidden.insert(token.id)}
        }
        CATransaction.commit()
        // Flush before dispatching any Native work. An outer transaction previously held this turn
        // for 75–102 ms while the old server animation continued in the abandoned direction.
        CATransaction.flush()
        probe?.record("ModeTurnServerCommitted")
        let admit: @MainActor () -> Void = { [weak self,weak window] in
            guard let self,self.transitionGeneration == generation,self.mode == next else {return}
            ModeSignposts.withTrace(probe) {
            probe?.record("ModeTurnNativeAdmission",.begin)
            defer {probe?.record("ModeTurnNativeAdmission",.end)}
            #if M11_MODE_SELFTEST
            self.verificationBeforeTurnAdmission?()
            #endif
            let nativeStarted=CACurrentMediaTime()
            defer {self.onTurnCost?("nativeAdmission",(CACurrentMediaTime()-nativeStarted)*1000)}
            guard self.nativeHandoffAllowed() else {self.rejectNativeCommit(preserving:sourceMode,window:window);return}
            CATransaction.begin();CATransaction.setDisableActions(true)
            defer {CATransaction.commit()}
            let pictureKeyBeforeAdmission=self.flightPictureKey()
            self.scene.cancelDrag()
            // Cold sources are captured in bounded main-loop slices before admission, never in a while-step loop.
            self.sidebarExposure.finish();self.turnSidebar.suppressNative()
            self.normieBodyRoot.layer?.removeAllAnimations();self.workbench.sidebar.view.layer?.removeAllAnimations()
            self.normieBodyRoot.alphaValue=1
            for root in [self.normieBodyRoot,self.organic] {root.layer?.removeAnimation(forKey:"mode.turn.native-out");root.layer?.opacity=1}
            self.releaseFlightHidden()
            if next == .organic,let selected=self.workbench.selectedConversation?.id {
                if self.admissionOrganicTarget?.key.selected != selected {self.admissionOrganicTarget=self.scene.beginModeTarget(selected:selected)}
            }
            if !alreadyAdmitted {
                self.performingAdmission=true
                let committed=next == .organic ? self.toOrganic(window,animated:false,reduce:false):self.toNormie(window,animated:false,reduce:false)
                self.performingAdmission=false
                guard committed else {self.rejectNativeCommit(preserving:sourceMode,window:window);return}
            }
            self.finalizeNativeOwner(next,window:window);self.admittedMode=next
            self.rekeyFlightPictures(after:pictureKeyBeforeAdmission)
            #if M11_MODE_SELFTEST
            self.verificationAfterTurnAdmission?()
            #endif
            self.normieNativeStaged=false;self.normieEndpointStaged=false
            if next == .organic {
                self.scene.setMeHidden(true);self.meFlightHidden=true
                for token in tokens {
                    if token.id.hasPrefix("header.") {self.hideHeader(token.id)}
                    else {self.scene.setDockHidden(token.id,true);self.flightHidden.insert(token.id)}
                }
            } else {self.organic.isHidden=true}
            self.workbench.sidebar.setFlightSourcesHidden(Set(tokens.map {$0.conversation.id}),avatar:true)
            self.flight.onFrame = { [weak self] time in self?.publishFlightOwners(at:time) }
            self.refreshFlightEndpoints();self.flight.advance(at:self.flight.elapsed)
            self.turnSidebar.suppressNative()
            let complete: @MainActor () -> Void = { [weak self] in
                guard let self,self.transitionGeneration == generation else {return}
                self.sourcePlate.clear()
                self.pendingMode=nil;self.publishFlightOwners(at:self.flight.elapsed)
                self.flight.destinationDidMount()
                self.turnSidebar.finishWhenSettled { [weak self] in
                    guard let self,self.transitionGeneration == generation else {return}
                    self.reconcileNativeRowFence();self.flight.destinationDidMount()
                }
                self.scheduleModePrewarm(reason:"handoff.turn.end")
            }
            if alreadyAdmitted || targetPicture != nil {
                // The only crossfade has completed; native pixels replace an opaque matching curtain.
                complete()
            } else {self.sourcePlate.revealDestination(duration:0.14,completion:complete)}
            self.preparedSwitch=nil
            }
        }
        var curtainReady=false,sidebarReady=false,admissionRequested=false
        let admitWhenReady:@MainActor ()->Void = { [weak self] in
            guard let self,self.transitionGeneration == generation,curtainReady,sidebarReady,!admissionRequested else {return}
            admissionRequested=true;admit()
        }
        let curtainComplete:@MainActor ()->Void = {curtainReady=true;admitWhenReady()}
        DispatchQueue.main.async { [weak self] in
            guard let self,self.transitionGeneration == generation,self.mode == next else {return}
        let contentStarted=CACurrentMediaTime()
        defer {self.onTurnCost?("curtainPrepare",(CACurrentMediaTime()-contentStarted)*1000)}
        let holes=tokens.flatMap {[$0.from.insetBy(dx:-3,dy:-3),$0.to.insetBy(dx:-3,dy:-3)]}
            + [avatarTrip.from.insetBy(dx:-3,dy:-3),avatarTrip.to.insetBy(dx:-3,dy:-3)]
        let sideRect=self.turnSidebar.presentedRect ?? M10SidebarExposure.presentedRect(side,in:self.view)
        let cachedWidth=CGFloat(self.preparedSidebarPicture?.width ?? 0)/scale
        let knownWidth=max(sideRect.width,max(side.bounds.width,max(self.lastNormieSidebarWidth ?? 0,cachedWidth)))
        let width=knownWidth>0 ? knownWidth:self.view.bounds.width*NormieSidebarMetrics.preferredThicknessFraction
        let sidebarHole=CGRect(x:0,y:sideRect.minY,width:width,height:max(sideRect.height,self.view.bounds.height-sideRect.minY))
        // The independent moving sidebar is its only owner; no retained photo may leave a stationary copy below it.
        self.sourcePlate.openRect=sidebarHole
        self.sourcePlate.updateHoles(holes)
        if alreadyAdmitted {
            // A rapid second turn returns to the still-mounted native mode. Reverse the current
            // curtain instead of replacing a partly visible image with a different cached picture.
            self.sourcePlate.updateHoles(holes)
            self.sourcePlate.revealDestination(duration:0.14,completion:curtainComplete)
            self.sourcePlate.bindNativeCrossfade(sourceMode == .organic ? self.organic:self.normieBodyRoot,revealing:true)
        } else if let targetPicture {
            self.sourcePlate.openRect=sidebarHole
            self.sourcePlate.restoreSource(targetPicture,in:self.view,below:self.flight.view,holes:holes,completion:curtainComplete)
            let outgoing=sourceMode == .organic ? self.organic:self.normieBodyRoot
            self.sourcePlate.bindNativeCrossfade(outgoing,revealing:false)
        } else {
            finishSidebar()
            let native=sourceMode == .organic ? self.organic:self.split.view
            let outgoing=ModeSurfaceBuilder(native,scale:scale,includeWindowFrame:false,presentation:true,excluding:[side],normalizeRootOpacity:true)
            outgoing.completeInSlices(valid:{ [weak self] in self?.transitionGeneration == generation && self?.mode == next },onSlice:{ [weak self] cost in self?.onTurnCost?("coldSource.slice",cost) }) { [weak self] picture in
                guard let self,let picture else {return}
                let pinStarted=CACurrentMediaTime()
                defer {self.onTurnCost?("coldSource.pin",(CACurrentMediaTime()-pinStarted)*1000)}
                self.bankFlightPicture(picture,mode:sourceMode.rawValue)
                self.sourcePlate.openRect=sidebarHole
                self.sourcePlate.pinNativeBackdrop(picture,in:self.view,below:self.flight.view,holes:holes)
                CATransaction.flush()
                curtainComplete()
            }
            return
        }
        finishSidebar()
        }
        @MainActor func finishSidebar() {
        if self.turnSidebar.usesNativeHost {sidebarReady=true;admitWhenReady();return}
        CATransaction.flush()
        DispatchQueue.main.async { [weak self] in
            guard let self,self.transitionGeneration == generation,self.mode == next else {return}
        // The server flight is already committed. Prepare exactly one sidebar texture with no avatar/planets.
        if let prepared=self.preparedSidebarPicture {commitSidebar(prepared)}
        else {
            let builderStarted=CACurrentMediaTime()
            let builder=self.makeSidebarForegroundBuilder()
            self.onTurnCost?("sidebar.builder",(CACurrentMediaTime()-builderStarted)*1000)
            builder.completeInSlices(valid:{ [weak self] in self?.transitionGeneration == generation && self?.mode == next },onSlice:{ [weak self] cost in self?.onTurnCost?("sidebar.captureSlice",cost) }) {picture in
                guard let picture else {return}
                let packed=CACurrentMediaTime(),bitmap=picture.flattened()
                self.onTurnCost?("sidebar.pack",(CACurrentMediaTime()-packed)*1000)
                commitSidebar(bitmap)
            }
        }
        }
        }
        @MainActor func commitSidebar(_ sideImage:CGImage) {
        guard self.transitionGeneration == generation,self.mode == next else {return}
        let sidebarStarted=CACurrentMediaTime()
        #if M11_MODE_SELFTEST
        self.beforeTurnSidebarCommit?()
        #endif
        // Baking and queueing may take time while CA keeps moving the previous texture.
        var sideRect=self.turnSidebar.presentedRect ?? M10SidebarExposure.presentedRect(side,in:self.view)
        let sideAlpha=self.turnSidebar.presentedAlpha ?? (self.normieBodyRoot.isHidden ? Float(0):(self.normieBodyRoot.layer?.presentation()?.opacity ?? Float(self.normieBodyRoot.alphaValue)))
        if self.turnSidebar.presentedRect == nil,sideAlpha<0.001,next == .normie {
            let width=sideRect.width>0 ? sideRect.width:CGFloat(sideImage.width)/scale
            sideRect=CGRect(x:-width,y:sideRect.minY,width:width,height:sideRect.height>0 ? sideRect.height:CGFloat(sideImage.height)/scale)
        }
        self.sidebarExposure.finish()
        self.turnSidebar.begin(sideImage,source:side,in:self.view,below:self.flight.view,rect:sideRect,alpha:sideAlpha,incoming:next == .normie,scale:scale)
        self.flight.refreshRowPresentation()
        CATransaction.flush()
        self.onTurnCost?("sidebar",(CACurrentMediaTime()-sidebarStarted)*1000)
        sidebarReady=true;admitWhenReady()
        }
    }

    private func hideHeader(_ id: String) {
        guard headerHidden[id] == nil, let column = scene.columns.first(where: { "header." + $0.conversation.id == id }), let island = column.island else { return }
        let views = [island.orb.glassView, island.orb.backView, island.orb.frontView]
        headerHidden[id] = views.map { ($0, $0.isHidden) }; views.forEach { $0.isHidden = true }
    }
    private func revealHeader(_ id: String) {
        guard let held = headerHidden.removeValue(forKey: id) else { return }
        for (view, hidden) in held { view.isHidden = hidden }
    }
    private func rankedTokens(_ tokens: [ModeFlight.Token], forward: Bool) -> [ModeFlight.Token] {
        tokens.sorted { forward ? $0.to.minX < $1.to.minX : $0.from.minX > $1.from.minX }.enumerated().map { rank, token in
            .init(id: token.id, conversation: token.conversation, from: token.from, to: token.to,
                  start: 0.08 + 0.04 * Double(min(rank, 4)), absorbed: token.absorbed)
        }
    }
    private func openingTokens(_ next: Mode, rows: [String: CGRect], headers: [ModeHeaderEndpoint], target:AutoScene.ModeTargetPlan?=nil) -> [ModeFlight.Token] {
        guard !scene.composingNew else { return [] }
        let headerIDs = Set(headers.map(\.id))
        var endpoints: [(String, Conversation, CGRect, Bool)] = headers.map { ($0.tokenID, $0.conversation, $0.rect, false) }
        if let target {
            endpoints += target.dockEndpoints.map {($0.id,$0.conversation,$0.rect,$0.absorbed)}
        }
        for target in (target != nil || scene.isFocused ? [] : scene.dockTargets) where !headerIDs.contains(target.id) {
            guard let c = scene.store.conversation(target.id), let rect = scene.dockFrame(of: target.id) else { continue }
            let r = target.bar ? CGRect(x: rect.minX + 4, y: rect.midY - 16, width: 32, height: 32) : rect
            endpoints.append((target.id, c, r, target.bar))
        }
        endpoints.sort { next == .organic ? $0.2.minX < $1.2.minX : $0.2.minX > $1.2.minX }
        // A changed Normie selection needs Organic's pending target layout. Do not fly to stale header geometry.
        if next == .organic, target == nil, workbench.selectedConversation?.id != scene.current { return [] }
        return endpoints.compactMap { id, c, rect, absorbed in
            guard let row = rows[c.id] else { return nil }
            return .init(id: id, conversation: c, from: next == .organic ? row : rect, to: next == .organic ? rect : row,
                         start: 0.08 + 0.04 * Double(min(endpoints.firstIndex(where: { $0.0 == id }) ?? 0, 4)),
                         absorbed: next == .organic ? absorbed : true)
        }
    }

    private func beginPreparedSwitch(_ next: Mode, window: NSWindow?, reduce: Bool, probe: ModeSignposts.Trace?) {
        if ModeFlight.orreryEnabled,!reduce {beginContentSwitch(next,window:window,probe:probe);return}
        guard workbench.canHandoff, scene.transcriptSessions?.canHandoff != false else {
            probe?.record("ModeSwitchRejected", detail: "native gesture/IME must finish"); return
        }
        if ModeFlight.orreryEnabled,flight.running,!reduce,flight.headingToOrganic != (next == .organic),!normieNativeStaged {
            reverseOrreryPresentation(next,window:window)
            onModeChange?(next)
            return
        }
        // A sliced Native mount may already have borrowed the source views, while the transparent target has
        // not been committed. Reversal must restore ownership through normal admission, keeping the held source.
        let reversingStagedNormie=normieNativeStaged && next == .organic
        // Before sampling any source or target header geometry.
        scene.dock.headerOrbDragging?.cancelImmediately()
        scene.beginModeHandoff();scene.dock.composerMotion.beginModeHandoff();workbench.detail.beginModeHandoff();admissionRowCursor=0
        let candidate=preparedSwitch?.organicTarget ?? preparingOrganicTarget
        cancelModePreparation()
        admissionOrganicTarget = next == .organic ? candidate.flatMap {$0.key.selected == workbench.selectedConversation?.id && scene.modeTargetIsValid($0) ? $0:nil} ?? workbench.selectedConversation.flatMap {scene.beginModeTarget(selected:$0.id)}:nil
        admission.cancel(); normieNativeStaged=false;normieEndpointStaged=false;admissionSidebarBuilder=nil;admissionSidebarImage=nil; transitionGeneration &+= 1
        let generation = transitionGeneration
        releaseFlightHidden()
        if next == admittedMode && !reversingStagedNormie && (!ModeFlight.orreryEnabled || nativeContentBelongs(to:next)) {
            pendingMode = nil; mode = next
            if ModeFlight.orreryEnabled {
                CATransaction.begin();CATransaction.setDisableActions(true)
                finalizeNativeOwner(next,window:window,preserveTargetFade:true)
                if !reduce {turnSidebar.moveNative(incoming:next == .normie)}
                CATransaction.commit()
            }
            let rows = preparedSwitch?.rows ?? sidebarRows(), headers = headerEndpoints()
            let tokens = reduce ? [] : openingTokens(next, rows: rows, headers: headers)
            let avatar = preparedSwitch?.avatar ?? sidebarAvatar(), me = scene.meFrame ?? scene.meRest
            workbench.sidebar.setFlightSourcesHidden(Set(tokens.map { $0.conversation.id }), avatar: true)
            if next == .organic {
                scene.setMeHidden(true); meFlightHidden = true
                for token in tokens {
                    if token.id.hasPrefix("header.") { hideHeader(token.id) }
                    else { scene.setDockHidden(token.id, true); flightHidden.insert(token.id) }
                }
            }
            var returningRows = Set(tokens.map { $0.conversation.id })
            flight.onFrame = { [weak self] time in
                guard let self else { return }
                if time >= self.flight.avatarHandoff {
                    self.scene.setMeHidden(false); self.meFlightHidden = false
                }
                for token in tokens where self.flight.arrived(token.id, at: time) {
                    if token.id.hasPrefix("header.") { self.revealHeader(token.id) }
                    else { self.scene.setDockHidden(token.id, false); self.flightHidden.remove(token.id) }
                }
                if next == .normie {
                    for token in tokens where ModeFlight.orreryEnabled ? self.flight.arrived(token.id,at:time) : time >= token.start+0.28 { returningRows.remove(token.conversation.id) }
                }
                self.workbench.sidebar.setFlightSourcesHidden(time.isFinite ? returningRows : [], avatar: time < self.flight.avatarHandoff)
                if !time.isFinite { self.sourcePlate.clear(); self.releaseFlightHidden() }
            }
            probe?.firstAnimation("opening reversed before native admission; source ownership unchanged")
            flight.start(toOrganic: next == .organic, avatar: next == .organic ? (avatar, me) : (me, avatar),
                         initials: initials, tokens: tokens, composer: nil, reduceMotion: reduce)
            onModeChange?(next); return
        }
        markCardsLeavingNormie()
        let prepared=preparedSwitch.flatMap{$0.geometryKey == modeGeometryKey() ? $0:nil}
        let sourceReady=prepared.map{$0.hasSource && $0.key == modePreparationKey()} ?? false
        let reusesHeldSource=reversingStagedNormie && sourcePlate.picture != nil
        if reusesHeldSource {probe?.record("ModeStagedReversal",detail:"restore borrowed Native ownership; retain exact held Organic source")}
        preparedSwitch=prepared
        probe?.record(sourceReady ? "ModePreparationHit":"ModePreparationMiss")
        probe?.record(prepared == nil ? "ModeLayoutPreparationMiss":"ModeLayoutPreparationHit")
        if ModeFlight.orreryEnabled,prepared == nil,admittedMode == .organic {
            let size=view.bounds.size
            let width=min(NormieSidebarMetrics.maximumWidth,max(NormieSidebarMetrics.minimumWidth,lastNormieSidebarWidth ?? size.width*NormieSidebarMetrics.preferredThicknessFraction))
            let top=view.window == nil ? 0:lastNormieTopInset
            workbench.sidebar.prepareModeLayout(size:CGSize(width:width,height:size.height),safeRect:CGRect(x:0,y:top,width:width,height:max(0,size.height-top)))
        }
        let endpointTarget = admissionOrganicTarget ?? (ModeFlight.orreryEnabled ? scene.beginModeTarget(selected:scene.current):nil)
        let rows = prepared?.rows ?? sidebarRows(warming:ModeFlight.orreryEnabled), headers = endpointTarget?.headers ?? prepared?.headers ?? headerEndpoints()
        let sideAvatar = prepared?.avatar ?? sidebarAvatar()
        let organicAvatar = next == .organic ? admissionOrganicTarget?.me ?? scene.meFrame ?? scene.meRest:scene.meFrame ?? scene.meRest
        let tokens = reduce ? [] : prepared.map { next == .organic ? $0.toOrganic : $0.toNormie } ?? openingTokens(next, rows: rows, headers: headers,target:endpointTarget)
        probe?.record("ModeOpeningPlan",detail:"tokens=\(tokens.count) headers=\(tokens.filter{$0.id.hasPrefix("header.")}.count) source=\(sourceReady)")
        // Leaving Organic the live scene lies under the picture with the flown orbs hidden, so a hole can reach their badges and
        // satellites, which otherwise stayed behind for the whole fade (board 10-31). A bar's own hole has only empty glass under it.
        let bars = next == .normie ? Set(scene.dockTargets.filter(\.bar).map(\.id)) : []
        var holes = tokens.map { t -> CGRect in
            // A column-top orb's satellites go wider than a Dock orb's badge: a sliver stayed behind for 0.4 s at 14 (board 10-31).
            let reach: CGFloat = next == .normie && !bars.contains(t.id) ? (t.id.hasPrefix("header.") ? 22 : 14) : 3
            return t.from.insetBy(dx: -reach, dy: -reach)
        }
        // me's ring and its count go too.
        holes.append((next == .organic ? sideAvatar : organicAvatar).insetBy(dx: next == .normie ? -10 : -3, dy: next == .normie ? -10 : -3))
        admissionHoles = holes
        sourcePlate.openRect = next == .organic && !workbench.sidebar.view.isHidden ? view.convert(workbench.sidebar.view.bounds, from: workbench.sidebar.view) : nil
        if sourceReady,let prepared {bankFlightPicture(prepared.source,mode:admittedMode.rawValue);ModeSignposts.measure("ModeSourceHold") {sourcePlate.hold(prepared.source,in:view,below:flight.view,holes:holes)}}
        else { sourcePlate.shieldSource(in: view, below: flight.view) }
        workbench.sidebar.setFlightSourcesHidden(Set(tokens.map { $0.conversation.id }), avatar: true)
        if next == .normie {
            scene.setMeHidden(true); meFlightHidden = true
            for token in tokens {
                if token.id.hasPrefix("header.") { hideHeader(token.id) }
                else { scene.setDockHidden(token.id, true); flightHidden.insert(token.id) }
            }
        }
        freezeSourceTranscripts(sourceRoot:reversingStagedNormie ? split.view:nil)
        mode = next; pendingMode = next
        if next == .organic {flight.prepareComposerMaterial(from:workbench.detail.modeComposerMaterial)}
        openingFrameTime = CACurrentMediaTime()
        probe?.firstAnimation("prepared opening flight; native admission waits for first production frame")
        flight.onFrame = ModeFlight.orreryEnabled ? { [weak self] time in self?.publishFlightOwners(at:time) }:nil
        flight.start(toOrganic: next == .organic, avatar: next == .organic ? (sideAvatar, organicAvatar) : (organicAvatar, sideAvatar),
                     // Without a source picture yet the composer's trip waits for it: glass over the live source is near
                     // black until the picture is there (board 10-31). continuePrepared starts it at admission.
                     initials: initials, tokens: tokens, composer: next == .organic && (sourceReady || reusesHeldSource) ? preparedComposerTrip():nil, reduceMotion: reduce)
        if turnSidebar.usesNativeHost,!reduce {turnSidebar.moveNative(incoming:next == .normie)}
        if ModeFlight.orreryEnabled,!reduce {CATransaction.flush()}
        let coldSource = !(sourceReady || reusesHeldSource) ? ModeSurfaceBuilder(view,scale:window?.backingScaleFactor ?? scene.scale,includeWindowFrame:false,excluding:[flight.view,sourcePlate],normalizeRootOpacity:true):nil
        admission.arm { [weak self, weak window] in
            guard let self, self.transitionGeneration == generation, self.pendingMode == next else { return }
            guard !self.workbench.transcriptSessions.isDisposed, self.workbench.detail.canHandoffTranscripts,
                  self.scene.transcriptSessions?.canHandoff != false else {
                self.pendingMode = nil; self.mode = self.admittedMode; self.flight.cancel(); self.releaseFlightHidden()
                self.sourcePlate.clear(); self.workbench.sidebar.setFlightSourcesHidden([], avatar: false)
                probe?.record("ModeSwitchRejected", detail: "handoff became unavailable after opening frame")
                self.onModeChange?(self.mode); return
            }
            self.prepareAdmissionResources(generation:generation,source:coldSource,probe:probe) { [weak self,weak window] in
                guard let self,self.transitionGeneration == generation,self.pendingMode == next else{return}
            ModeSignposts.withTrace(probe) {
                ModeSignposts.measure("ModeNativeAdmission") {
                    if ModeFlight.orreryEnabled,!self.nativeHandoffAllowed() {self.rejectNativeCommit(preserving:self.admittedMode,window:window);return}
                    let previousOwner=self.admittedMode
                    if !ModeFlight.orreryEnabled {self.pendingMode=nil}
                    self.performingAdmission = true
                    defer { self.performingAdmission = false }
                    self.admissionWasCold = coldSource != nil
                    defer { self.admissionWasCold = false }
                    if let image=coldSource?.finish() {self.bankFlightPicture(image,mode:self.admittedMode.rawValue);self.sourcePlate.hold(image,in:self.view,below:self.flight.view,holes:holes)}
                    let pictureKeyBeforeAdmission=self.flightPictureKey()
                    var committed:Bool
                    if next == .organic {
                        let leaving=self.workbench.detail.cardsLeavingForColumns.map{(card:$0,rect:self.sourcePlate.convert($0.approvalPlateRect,from:$0))}
                        committed=self.toOrganic(window, animated: true, reduce: reduce)
                        if committed {self.sourcePlate.addCardPlates(leaving.filter{!$0.card.isDescendant(of:self.workbench.detail.view)}.map(\.rect))}
                    }
                    else {committed=self.toNormie(window, animated: true, reduce: reduce)}
                    guard committed || !ModeFlight.orreryEnabled else {self.rejectNativeCommit(preserving:previousOwner,window:window);return}
                    if ModeFlight.orreryEnabled {self.finalizeNativeOwner(next,window:window,preserveTargetFade:true)}
                    self.pendingMode=nil;self.admittedMode = next
                    self.rekeyFlightPictures(after:pictureKeyBeforeAdmission)
                    self.workbench.detail.freezeModeLayout(true)
                    probe?.record("ModeDestinationReady")
                    self.sourcePlate.revealDestination { [weak self] in
                        guard let self, self.transitionGeneration == generation else { return }
                        if next == .normie {self.organic.isHidden=true;self.releaseFlightHidden()}
                        self.publishFlightOwners(at:self.flight.elapsed)
                        self.flight.destinationDidMount()
                        self.preparedSwitch = nil
                        self.scheduleModePrewarm(reason: "handoff.end")
                    }
                }
            }
            }
        }

        onModeChange?(next)
    }

    private func freezeSourceTranscripts(sourceRoot:NSView?=nil) {
        workbench.detail.freezeModeLayout(true)
        let source=sourceRoot ?? (admittedMode == .organic ? organic:split.view)
        for native in workbench.transcriptSessions.transcripts.values where native.presentationActive && native.isDescendant(of:source) && !native.isHiddenOrHasHiddenAncestor {
            if native.layer?.mask?.bounds.isEmpty == true {continue}
            if !frozenSourceTranscripts.contains(where:{$0 === native}) {frozenSourceTranscripts.append(native)}
            native.presentationActive=false
        }
        ModeSignposts.current?.record("ModeSourceViewportsFrozen",detail:"count=\(frozenSourceTranscripts.count)")
    }
    private func resumeSourceTranscripts() {
        let source=admittedMode == .organic ? organic:split.view
        let frozen=frozenSourceTranscripts;frozenSourceTranscripts=[]
        for native in frozen where !native.isDisposed && !native.presentationActive && native.isDescendant(of:source) && !native.isHiddenOrHasHiddenAncestor {
            native.presentationActive=true
        }
    }
    private func prepareAdmissionResources(generation:UInt64,source:ModeSurfaceBuilder?,probe:ModeSignposts.Trace?,completion:@escaping @MainActor ()->Void) {
        guard transitionGeneration == generation else{return}
        if ModeFlight.orreryEnabled,!nativeHandoffAllowed() {rejectNativeCommit(preserving:admittedMode,window:view.window);return}
        let turn=probe ?? ModeSignposts.current
        turn?.record("ModeAdmissionTurn",.begin)
        defer{turn?.record("ModeAdmissionTurn",.end)}
        if let target=admissionOrganicTarget,!scene.modeTargetIsValid(target),let selected=workbench.selectedConversation?.id {
            admissionOrganicTarget=scene.beginModeTarget(selected:selected)
        }
        let ready=ModeSignposts.withTrace(probe) {ModeSignposts.measure("ModeColdPreparationSlice") {
            let deadline=CACurrentMediaTime()+0.005
            var worked=false
            repeat {
                if let target=admissionOrganicTarget,!target.ready {_=scene.prepareModeTargetStep(target)}
                else if pendingMode == .normie,let c=scene.conversation(scene.current),admissionRowCursor>=0 {
                    let width=max(1,view.bounds.width-workbench.sidebar.view.bounds.width)
                    // A new delta does not restart this bounded warm pass. Admission refreshes the latest model once.
                    if workbench.transcriptSessions.transcript(for:c,store:scene.store).prepareModeRow(width:width,cursor:&admissionRowCursor) {admissionRowCursor = -1}
                }
                else if let source,!source.ready {
                    if worked,CACurrentMediaTime()+max(0.001,source.lastStepSeconds)>deadline {return false}
                    source.step()
                }
                else {return !worked} // never append native admission to a tile/layout slice that already spent its budget
                worked=true
            } while CACurrentMediaTime()<deadline
            return false
        }}
        if ready,pendingMode == .normie,!normieNativeStaged {
            ModeSignposts.withTrace(probe) {
                // Holes as for a prepared source: the picture still has the orbs, and they had already left (board 10-31).
                if let picture=source?.finish() {sourcePlate.hold(picture,in:view,below:flight.view,holes:admissionHoles)}
                stageNormieNativeAdmission()
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.002) { [weak self] in
                guard let self,self.transitionGeneration == generation,self.pendingMode == .normie else{return}
                self.prepareAdmissionResources(generation:generation,source:source,probe:probe,completion:completion)
            }
        }
        else if ready,pendingMode == .normie,!normieEndpointStaged {
            ModeSignposts.withTrace(probe) {ModeSignposts.measure("ModeNormieEndpointStage") {
                finishNormieEndpoint {setModeToolbar(true,in:view.window)}
                workbench.detail.freezeModeLayout(true)
                normieEndpointStaged=true
            }}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.002) {[weak self] in self?.prepareAdmissionResources(generation:generation,source:source,probe:probe,completion:completion)}
        }
        else if ready,pendingMode == .normie,preparedSidebarPicture == nil {
            ModeSignposts.withTrace(probe) {ModeSignposts.measure("ModeAdmissionSidebarSlice") {
                let key=workbench.sidebar.modeContentKey
                if admissionSidebarBuilder == nil || admissionSidebarKey != key {
                    admissionSidebarKey=key
                    admissionSidebarBuilder=ModeSurfaceBuilder(workbench.sidebar.view,scale:view.window?.backingScaleFactor ?? scene.scale,includeWindowFrame:false,excluding:[workbench.sidebar.accountView.avatar] + workbench.sidebar.hiddenFlightSourceViews,detached:workbench.sidebar.preparedModeDrawingRows)
                }
                let deadline=CACurrentMediaTime()+0.004
                repeat {admissionSidebarBuilder?.step()} while admissionSidebarBuilder?.ready == false && CACurrentMediaTime()+max(0.001,admissionSidebarBuilder?.lastStepSeconds ?? 0)<deadline
                if let picture=admissionSidebarBuilder?.finish() {admissionSidebarImage=picture.flattened()}
            }}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.002) {[weak self] in self?.prepareAdmissionResources(generation:generation,source:source,probe:probe,completion:completion)}
        }
        else if ready {completion()}
        else {DispatchQueue.main.asyncAfter(deadline:.now()+0.002) { [weak self] in self?.prepareAdmissionResources(generation:generation,source:source,probe:probe,completion:completion) }}
    }
    func admitNormieContent(layout:Bool=true,showChrome:()->Void = {}) {
        workbench.detail.beginModeHandoff();workbench.detail.freezeModeLayout(true)
        func admitNormie() {
            func configureHost() {
            ModeSignposts.measure("NormieNativePolicy") {workbench.isNormie = true;workbench.sidebarVisible = true}
            workbench.memberOrder = scene.order
            ModeSignposts.measure("NormieNativeSelection") {if scene.composingNew {_ = workbench.newChat(projectID:scene.draftContext.projectID)} else {_ = workbench.select((contentOpening || contentSession != nil) ? (contentFocusConversation ?? scene.current):scene.current)}}
            ModeSignposts.measure("NormieNativeComposer") {workbench.remountComposer()}
            ModeSignposts.measure("NormieNativeRefresh") {workbench.refresh()}
            }
            if let c=scene.conversation(scene.current),!scene.composingNew {
                scene.composers.composer(for:c,store:scene.store).configurePresentation(configureHost)
            } else {configureHost()}
            if layout { finishNormieEndpoint(showChrome:showChrome) }
        }
        if let c=scene.conversation(scene.current), !scene.composingNew {
            ModeSignposts.measure("NormieNativeViewportBatch") {workbench.transcriptSessions.transcript(for:c,store:scene.store).configurePresentation(allowHidden:true,admitNormie)}
        } else {admitNormie()}
    }

    private func finishNormieEndpoint(showChrome:()->Void) {
        ModeSignposts.measure("NormieWindowChrome",showChrome)
        layoutNormie()
        workbench.detail.freezeModeLayout(false)
        ModeSignposts.measure("NormieLayout") {split.view.layoutSubtreeIfNeeded()}
        if ModeFlight.orreryEnabled {contentPreparedNormieLayout=contentNormieLayoutKey}
    }
    /// Native policy/mount/refresh is an independent turn while the target is transparent. The opening CA flight
    /// is already running. The source plate protects ownership changes; no target pixels are exposed here.
    private func stageNormieNativeAdmission() {
        ModeSignposts.measure("ModeNormieNativeStage") {
            scene.suspendModePresentation()
            workbench.sidebar.endModePreparation();workbench.detail.endModePreparation()
            let target=normieBodyRoot;target.alphaValue=0;target.isHidden=false
            split.splitViewItems.first?.isCollapsed=false
            admitNormieContent(layout:false)
            normieNativeStaged=true
        }
    }

    private func preparedComposerTrip()->(from:CGRect,to:CGRect,slot:Int)? {
        guard let source=workbench.detail.composerDockFrame.map({view.convert($0,from:nil)}),let plan=admissionOrganicTarget else{return nil}
        guard let i=plan.order.prefix(plan.layout.columns.count).firstIndex(of:plan.current),i<plan.layout.bars.count else{return nil}
        return (source,plan.layout.bars[i],i)
    }
    private var preparedSidebarPicture:CGImage? {
        let scale=view.window?.backingScaleFactor ?? scene.scale,size=workbench.sidebar.view.bounds.size
        func matches(_ image:CGImage)->Bool {image.width == Int(ceil(size.width*scale)) && image.height == Int(ceil(size.height*scale))}
        if let admissionSidebarImage,admissionSidebarKey == workbench.sidebar.modeContentKey,matches(admissionSidebarImage) {return admissionSidebarImage}
        guard let prepared=preparedSwitch,prepared.sidebarContentKey == workbench.sidebar.modeContentKey,matches(prepared.sidebar) else{return nil}
        return prepared.sidebar
    }
    private func sidebarForeground()->CGImage {
        // Me flies by itself; with the avatar in the sliding picture there were two of it (board 10-31).
        #if M11_MODE_SELFTEST
        let began=CACurrentMediaTime();sidebarBakeCount+=1
        defer {sidebarBakeMaximumMS=max(sidebarBakeMaximumMS,(CACurrentMediaTime()-began)*1000)}
        #endif
        let builder=makeSidebarForegroundBuilder()
        while !builder.ready {builder.step()}
        return builder.finish()!.flattened()
    }
    private func makeSidebarForegroundBuilder()->ModeSurfaceBuilder {
        let held=workbench.sidebar.flightSourceViews(for:flight.heldConversationIDs)
        return ModeSurfaceBuilder(workbench.sidebar.view,scale:view.window?.backingScaleFactor ?? scene.scale,includeWindowFrame:false,excluding:[workbench.sidebar.accountView.avatar] + workbench.sidebar.hiddenFlightSourceViews + held,detached:workbench.sidebar.preparedModeDrawingRows)
    }
    private func animatePreparedSidebar(incoming:Bool) {
        if turnSidebar.usesNativeHost {turnSidebar.moveNative(incoming:incoming);return}
        let side=workbench.sidebar.view, width=side.bounds.width
        let animation=CABasicAnimation(keyPath:"transform.translation.x");ModeSignposts.frameRange(animation)
        animation.fromValue=incoming ? -width:0;animation.toValue=incoming ? 0:-width
        animation.duration=0.25;animation.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        side.layer?.add(animation,forKey:"mode.sidebar.translation")
    }

    func settlePendingMode() {
        if ModeFlight.orreryEnabled,(contentSession != nil || contentOpening) {
            guard nativeHandoffAllowed() else {return}
            let target=mode,selected=contentDeferredSelection,focus=contentAdmissionResponder
            cancelContentSession();flight.cancel()
            performingAdmission=true
            _=target == .organic ? toOrganic(view.window,animated:false,reduce:true):toNormie(view.window,animated:false,reduce:true)
            performingAdmission=false;admittedMode=target;pendingMode=nil
            finalizeNativeOwner(target,window:view.window)
            scene.endModeHandoff();scene.dock.composerMotion.endModeHandoff();workbench.detail.endModeHandoff()
            if let selected {_=workbench.select(selected);if target == .organic {scene.show(selected);scene.remountComposers()}}
            restoreAdmissionResponder(focus);restoreSelectedContentFocus(selected,target:target)
            contentDeferredSelection=nil;clearContentFocus()
            return
        }
        guard let target=pendingMode,let window=view.window else{return}
        if ModeFlight.orreryEnabled,!nativeHandoffAllowed() {rejectNativeCommit(preserving:admittedMode,window:window);return}
        // Transfers/collapse need completed ownership now. Cancel the sliced flight continuation first;
        // an obsolete asynchronous completion must never admit into a different owner afterwards.
        cancelModePreparation();admission.cancel();transitionGeneration &+= 1
        pendingMode=nil;flight.cancel();turnSidebar.finish();sourcePlate.clear();releaseFlightHidden();scene.endModeHandoff();scene.dock.composerMotion.endModeHandoff()
        workbench.sidebar.setFlightSourcesHidden([],avatar:false);workbench.detail.freezeModeLayout(false)
        performingAdmission=true
        if let plan=admissionOrganicTarget,scene.modeTargetIsValid(plan) {while !plan.ready,scene.modeTargetIsValid(plan) {_=scene.prepareModeTargetStep(plan)}}
        let previousOwner=admittedMode
        let committed=target == .organic ? toOrganic(window,animated:false,reduce:true):toNormie(window,animated:false,reduce:true)
        performingAdmission=false
        if ModeFlight.orreryEnabled {
            guard committed else {rejectNativeCommit(preserving:previousOwner,window:window);return}
            CATransaction.begin();CATransaction.setDisableActions(true);finalizeNativeOwner(target,window:window);admittedMode=target;CATransaction.commit()
        } else {admittedMode=mode}
        // No flight left to end: the columns the commit left unmounted take their transcripts now, not at endModeHandoff.
        scene.admitUnmountedTranscripts(scene.columns)
    }
}

#if M11_MODE_SELFTEST
extension WindowShell {
    func verificationGeometryUnderDeltas(legacy:Bool,deltas:Bool=true)->(ready:Bool,turns:Int,tokens:Int) {
        cancelModePreparation();preparedSwitch=nil
        verificationSlicedPreparation=true;verificationLegacyPreparationRules=legacy
        defer {verificationSlicedPreparation=false;verificationLegacyPreparationRules=false;lastModeStoreChange = -Double.infinity;cancelModePreparation()}
        for turn in 0..<180 {
            if preparationBatch == nil {prepareModeSwitch(reason:"verification.streaming.geometry")}
            if admittedMode == .organic {workbench.sidebar.view.frame=CGRect(x:0,y:0,width:240,height:0)}
            // The real store observer cancellation/full-key behavior is exercised, without a visible window.
            if deltas {
                if let c=scene.conversation(scene.current) {scene.store.changed(c)}
                modeStoreChanged()
            }
            runPreparationSlice(schedule:false)
            if geometryPrepared {return (true,turn+1,(admittedMode == .organic ? preparedSwitch?.toNormie.count:preparedSwitch?.toOrganic.count) ?? 0)}
        }
        return (false,180,preparedSwitch?.toNormie.count ?? 0)
    }
    func verificationSourceUnderFrameRestores()->Bool {
        if ModeFlight.orreryEnabled {
            verificationSlicedPreparation=true;lastModeStoreChange = -Double.infinity
            prepareModeSwitch(reason:"verification.body.source.geometry")
            for _ in 0..<240 {
                if preparationBatch == nil {break}
                workbench.sidebar.view.frame=CGRect(x:0,y:0,width:240,height:0)
                runPreparationSlice(schedule:false)
            }
            verificationSlicedPreparation=false;cancelModePreparation()
            verificationWaitForWarmContent()
            return geometryPrepared && (contentWarm != nil && contentWarmKey == flightPictureKey())
        }
        verificationSlicedPreparation=true;lastModeStoreChange = -Double.infinity
        defer{verificationSlicedPreparation=false;cancelModePreparation()}
        prepareModeSwitch(reason:"verification.source.frame.restore")
        for _ in 0..<240 {
            workbench.sidebar.view.frame=CGRect(x:0,y:0,width:240,height:0)
            if preparationBatch == nil {return preparedSwitch?.hasSource == true && preparedSwitch?.key == modePreparationKey()}
            runPreparationSlice(schedule:false)
        }
        return false
    }
    func verificationStreamingOpening()->(tokens:Int,hits:Int,stableSource:Bool) {
        guard let c=scene.conversation(scene.current) else{return (0,0,false)}
        scene.store.changed(c) // invalidate the picture while leaving every drawn orb value unchanged
        let clock=CACurrentMediaTime();flight.manualTime={clock}
        beginPreparedSwitch(.normie,window:nil,reduce:false,probe:ModeSignposts.current)
        let native=workbench.transcriptSessions.existingTranscript(for:c.id)
        let revision=native?.renderedRevision
        if !c.items.isEmpty {c.items[c.items.count-1].text += " streaming fixture"}
        scene.store.changed(c)
        let stable=native?.renderedRevision == revision && native?.presentationActive == false
        var count=0
        flight.onExposureSample={if $0.id.hasPrefix("planet.") {count+=1}}
        flight.sample(at:1/120,profile:.init(name:"120Hz",frameInterval:1/120,mmPerPoint:0.27,persistenceFrames:0))
        let result=(count,flight.consumedPreparedTokens,stable)
        flight.onExposureSample=nil;admission.cancel();pendingMode=nil;transitionGeneration &+= 1;mode=admittedMode
        flight.cancel();turnSidebar.finish();sourcePlate.clear();releaseFlightHidden();scene.endModeHandoff();workbench.detail.endModeHandoff();resumeSourceTranscripts()
        workbench.sidebar.setFlightSourcesHidden([],avatar:false)
        return result
    }
    var verificationCurrentSurface:ModeSurfaceBuilder {ModeSurfaceBuilder(view,scale:scene.scale,includeWindowFrame:false,excluding:[flight.view,sourcePlate],normalizeRootOpacity:true)}
    var verificationNativePlane:NSView {scene.nativePlane}
    func verificationBeginLayerReplay()->Bool {
        guard let prepared=preparedSwitch,let header=prepared.toNormie.first(where:{$0.id.hasPrefix("header.")}),
              let dock=prepared.toNormie.first(where:{!$0.id.hasPrefix("header.")}) else{return false}
        let tokens=[header,dock].enumerated().map { i,t in ModeFlight.Token(id:t.id,conversation:t.conversation,from:t.from,to:t.to,start:0.08+0.04*Double(i),absorbed:true) }
        let holes=tokens.map{$0.from.insetBy(dx:-3,dy:-3)}+[scene.meRest.insetBy(dx:-3,dy:-3)]
        sourcePlate.hold(prepared.source,in:view,below:flight.view,holes:holes)
        for token in tokens {if token.id.hasPrefix("header."){hideHeader(token.id)}else{scene.setDockHidden(token.id,true);flightHidden.insert(token.id)}}
        scene.setMeHidden(true);meFlightHidden=true
        normieBodyRoot.isHidden=false
        flight.manualTime={1000}
        flight.start(toOrganic:false,avatar:(scene.meRest,prepared.avatar),initials:initials,tokens:tokens,composer:nil,reduceMotion:false)
        view.addSubview(split.view,positioned:.above,relativeTo:nil)
        view.addSubview(sourcePlate,positioned:.above,relativeTo:nil)
        sourcePlate.hold(prepared.source,in:view,below:flight.view,holes:holes)
        return true
    }
    func verificationEndLayerReplay() {
        flight.cancel();turnSidebar.finish();sourcePlate.clear();releaseFlightHidden();normieBodyRoot.isHidden=true
        workbench.sidebar.setFlightSourcesHidden([],avatar:false)
    }

    private func verificationObserveTarget(_ stage:String) {
        func visible(_ v:NSView)->[String] {
            guard !v.isHidden,v.alphaValue>0,v.layer?.opacity != 0 else{return []}
            if let transcript=v as? NativeTranscript {return [transcript.renderedRevision == transcript.conversation.revision ? transcript.conversation.id:transcript.conversation.id+"@stale"]}
            return v.subviews.flatMap(visible)
        }
        verificationTargetObservation?(stage,visible(split.view))
    }
    func verificationStagedReversal()->Bool {
        if ModeFlight.orreryEnabled {
            verificationWaitForWarmContent()
            var now=CACurrentMediaTime();flight.manualTime={now}
            beginContentSwitch(.normie,window:view.window,probe:ModeSignposts.current)
            verificationFlightAdmit()
            guard let session=contentSession else {return false}
            let photo=session.photoID,live=session.liveMode
            now+=0.08;flight.advance(at:0.08)
            beginContentSwitch(.organic,window:view.window,probe:ModeSignposts.current)
            let fixed=contentSession?.photoID == photo && contentSession?.liveMode == live
            let end=flight.duration;now+=end+0.02
            advanceContentSession(at:now,flightFinished:false)
            // Native endpoint migration crosses its work/commit boundary before the retirement deadline.
            RunLoop.main.run(until:Date(timeIntervalSinceNow:flight.presentationInterval*3.2))
            flight.advance(at:end+0.02);flight.advance(at:end+0.07)
            advanceContentSession(at:now,flightFinished:!flight.running)
            let restored=workbench.detail.composer?.isDescendant(of:organic) == true
            let result=fixed && restored && admittedMode == .organic
            flight.cancel();cancelContentSession();return result
        }
        guard let picture=preparedSwitch?.source else{return false}
        flight.manualTime={1000}
        sourcePlate.hold(picture,in:view,below:flight.view,holes:[])
        scene.beginModeHandoff();workbench.detail.beginModeHandoff();freezeSourceTranscripts()
        pendingMode = .normie;mode = .normie
        stageNormieNativeAdmission()
        let borrowed=workbench.detail.composer?.isDescendant(of:split.view) == true
        beginPreparedSwitch(.organic,window:nil,reduce:false,probe:ModeSignposts.current)
        let held=sourcePlate.picture?.tiles.first?.image === picture.tiles.first?.image
        admission.performNow()
        let deadline=Date(timeIntervalSinceNow:5)
        while pendingMode != nil && Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.003))}
        let restored=workbench.detail.composer?.isDescendant(of:organic) == true
        flight.cancel();turnSidebar.finish();sourcePlate.clear()
        return borrowed && held && restored && admittedMode == .organic
    }
    func verificationColdAdmission() {
        pendingMode = .normie
        freezeSourceTranscripts()
        var done=false
        let trace=ModeSignposts.current
        let source=ModeSurfaceBuilder(view,scale:scene.scale,includeWindowFrame:false,excluding:[flight.view,sourcePlate],normalizeRootOpacity:true)
        prepareAdmissionResources(generation:transitionGeneration,source:source,probe:trace) { [self] in
            ModeSignposts.withTrace(trace) {verificationWholeAdmissionNormie()}
            done=true
        }
        let deadline=Date(timeIntervalSinceNow:15)
        while !done && Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.003))}
        pendingMode=nil
    }
    func verificationWholeAdmissionNormie() {
        performingAdmission=true;defer{performingAdmission=false}
        flight.manualTime={1000}
        if let prepared=preparedSwitch {sourcePlate.hold(prepared.source,in:view,below:flight.view,holes:[])}
        toNormie(nil,animated:true,reduce:false)
        admittedMode = .normie
        if let native=scene.transcriptSessions?.existingTranscript(for:scene.current) {print("Native target width=\(native.scrollView.contentSize.width) warm=\(native.modePreparedWidths) hits=\(native.modeRowCacheHits)")}
    }
    func verificationFinishNormieReplay() {
        if verificationTargetObservation != nil {
            for frame in 0...45 {
                flight.sample(at:Double(frame)/60,profile:.init(name:"handoff",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0))
                verificationObserveTarget("frame.\(frame)")
            }
        }
        flight.cancel();turnSidebar.finish();sourcePlate.clear()
    }
    var verificationOrganicHeaderEnds:[String:CGRect] {Dictionary(uniqueKeysWithValues:(preparedSwitch?.toOrganic ?? []).filter{$0.id.hasPrefix("header.")}.map{($0.id,$0.to)})}
    var verificationOrganicTokenIDs:[String] {preparedSwitch?.toOrganic.map(\.id) ?? []}
    func verificationAdmitNormie() {
        scene.suspendModePresentation();normieBodyRoot.isHidden=false;split.splitViewItems.first?.isCollapsed=false
        admitNormieContent();workbench.detail.view.layoutSubtreeIfNeeded()
        organic.isHidden=true;mode = .normie;admittedMode = .normie
    }
    func verificationAdmitOrganic(heldAtCommit:inout Int)->Bool {
        guard let prepared=preparedSwitch,let plan=prepared.organicTarget else{return false}
        admissionOrganicTarget=plan;performingAdmission=true;defer{performingAdmission=false}
        sourcePlate.hold(prepared.source,in:view,below:flight.view,holes:[])
        flight.manualTime={1000}
        toOrganic(nil,animated:true,reduce:false)
        heldAtCommit=scene.columns.filter{$0.ownsNative}.count
        admittedMode=mode
        flight.cancel();turnSidebar.finish();sourcePlate.clear()
        return mode == .organic
    }
}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
    func verificationFlightSettle(asOrganic: Bool) {
        if ModeFlight.orreryEnabled {cancelContentSession()}
        performingAdmission=true
        if asOrganic { toOrganic(nil,animated:false,reduce:false) }
        else { toNormie(nil,animated:false,reduce:false) }
        performingAdmission=false;admittedMode=asOrganic ? .organic:.normie;mode=admittedMode
        if ModeFlight.orreryEnabled {finalizeNativeOwner(admittedMode,window:view.window)}
    }
    func verificationFlightToggle(toOrganic: Bool) {
        beginPreparedSwitch(toOrganic ? .organic:.normie,window:view.window,reduce:false,probe:nil)
    }
    func verificationFlightAdmit() {
        admission.performNow()
        let deadline=Date(timeIntervalSinceNow:2)
        while pendingMode != nil,Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.002))}
    }
    func verificationDropFlightPreparation() {
        cancelModePreparation();preparedSwitch=nil;preparingOrganicTarget=nil
    }
    var verificationSourceTurning: Bool {sourcePlate.verificationTurnCommitted || (sourcePlate.picture != nil && turnSidebar.verificationSingleOwner)}
    var verificationReverseSourcesHidden:Bool {
        flight.activeTokens.allSatisfy { token in
            if token.id.hasPrefix("header.") {
                guard let orb=scene.columns.first(where:{$0.conversation.id == token.conversation.id})?.island?.orb else {return true}
                return orb.glassView.isHidden && orb.frontView.isHidden && orb.backView.isHidden
            }
            guard let item=scene.dock.items[token.conversation.id] else {return true}
            return item.glass.isHidden || item.glass.layer?.isHidden == true
        }
    }
    var verificationRowDiagnostics:[String:Any] {
        let rows=workbench.sidebar.model.rows.enumerated().compactMap {index,row -> [String:Any]? in
            guard let cell=workbench.sidebar.table.view(atColumn:0,row:index,makeIfNecessary:false) as? NormieSidebarCell else {return nil}
            var chain:[[String:Any]]=[],node:NSView?=cell.planet
            while let current=node {chain.append(["type":String(describing:type(of:current)),"hidden":current.isHidden,"alpha":current.alphaValue,"opacity":current.layer?.opacity ?? -1,"frame":NSStringFromRect(current.frame),"bounds":NSStringFromRect(current.bounds),"flipped":current.isFlipped,"presentationOpacity":current.layer?.presentation()?.opacity ?? -1,"layerHidden":current.layer?.isHidden ?? false]);node=current.superview}
            return ["id":row.conversationID ?? "","frame":NSStringFromRect(M10SidebarExposure.presentedRect(cell.planet,in:view)),"chain":chain,"exposed":exposed(cell.planet),"fullyCovers":workbench.sidebar.fullyCoversFlightIdentity(cell.planet)]
        }
        return ["rows":rows,"mode":mode.rawValue,"admitted":admittedMode.rawValue,"pending":pendingMode != nil,"picture":sourcePlate.picture != nil,"content":verificationContentSessionState,"meFrame":scene.meFrame.map(NSStringFromRect) ?? "nil","meRest":NSStringFromRect(scene.meRest),"meOwner":flightOwnerVisible("me"),"avatarTarget":flight.avatarEndpoints(toOrganic:mode == .organic).map {NSStringFromRect($0.to)} ?? "nil"]
    }
    func verificationRefreshFlightEndpoints() {refreshFlightEndpoints()}
    func verificationHoldHeader(_ id:String) {hideHeader(id)}
    func verificationScheduleFlightEndpoints() {scheduleFlightEndpointRefresh()}
    func verificationPublishFlightOwners(at time:Double) {publishFlightOwners(at:time)}
    var verificationRowsAwaitingRefresh:Bool {flightRowsAwaitingRefresh}
    var verificationTurnGeneration:UInt64 {transitionGeneration}
    func verificationFlightNativeOwner(_ id:String)->Bool {flightOwnerVisible(id)}
    func verificationSidebarForeground()->CGImage {sidebarForeground()}
    var verificationSidebarBakeCount:Int {sidebarBakeCount}
    var verificationEndpointRefreshCount:Int {endpointRefreshCount}
    var verificationSidebarBakeMaximumMS:Double {sidebarBakeMaximumMS}
    var verificationTurnSidebarImage:CALayer {turnSidebar.verificationImage}
    var verificationFlightDeviceKey:[String] {flightPictureKey().deviceStatus}
    var verificationPreparationDeviceKey:[String] {modePreparationKey().deviceStatus}
    var verificationBeforeTurnSidebarCommit:(()->Void)? {
        get {beforeTurnSidebarCommit}
        set {beforeTurnSidebarCommit=newValue}
    }
    var verificationTurnSidebarSingleOwner:Bool {turnSidebar.verificationSingleOwner}
    var verificationTurnContentLayer:CALayer? {sourcePlate.verificationImageLayer}
    var verificationTurnSidebarCutout:Bool {sourcePlate.verificationHasPhotoSidebarCutout}
    var verificationTurnSourceOpacity:Float {sourcePlate.verificationTurnOpacity}
    var verificationHasSidebarProxy:Bool {turnSidebar.view.superview != nil}
    var verificationNativeSidebarHost:NSView? {turnSidebar.verificationNativeHost}
    func verificationCoverBody(_ shown:Bool) {normieBodyRoot.isHidden = !shown;normieBodyRoot.alphaValue=1;normieBodyRoot.layer?.opacity=1}
    var verificationNativeOwnerState:[String:Any] {
        ["requested":mode.rawValue,"admitted":admittedMode.rawValue,"normieHidden":normieBodyRoot.isHidden,
         "organicHidden":organic.isHidden,"normieAlpha":normieBodyRoot.alphaValue,"organicAlpha":organic.alphaValue,
         "foregroundOrganic":hasForegroundContentOwner(.organic),"foregroundNormie":hasForegroundContentOwner(.normie),
         "toolbarVisible":verificationToolbarExposed]
    }
    func verificationRepairRest(_ target:Mode) {finalizeNativeOwner(target,window:view.window)}
    func verificationEndpointOwner(_ id:String)->Bool {flightOwnerVisible(id)}
    var verificationPhotoCrossfadeCommitted:Bool {sourcePlate.verificationTurnCommitted}
    var verificationReusablePictureModes:[String] {let key=flightPictureKey();return flightSourceKeys.filter {$0.value == key}.keys.sorted()}
    var verificationTurnCachedSelection:String? {flightSourceKeys[mode.rawValue]?.selected}
    var verificationTurnAvatarHole:Bool {
        guard let trip=flight.avatarEndpoints(toOrganic:mode == .organic),let path=sourcePlate.verificationHoles else {return false}
        return !path.contains(CGPoint(x:trip.to.midX,y:trip.to.midY),using:.evenOdd) && !path.contains(CGPoint(x:trip.from.midX,y:trip.from.midY),using:.evenOdd)
    }
    func verificationComposerPublisher() -> Bool {
        let id=scene.current
        guard let item=scene.dock.items[id] else {return false}
        composerFlightBar=id;composerFlightAwaitingRegistration=false
        scene.setDockHidden(id,true);flightHidden.insert(id)
        flight.verificationSetComposerTrip(from:CGRect(x:300,y:740,width:400,height:40),to:item.glass.frame,leave:0.12)
        publishFlightOwners(at:0)
        return item.glass.layer?.isHidden == true && !flight.barArrived(at:0)
    }
    var verificationComposerOwner: (id: String?,hidden: Bool,arrived: Bool) {
        (composerFlightBar,composerFlightBar.flatMap {scene.dock.items[$0]?.glass.isHidden} ?? false,flight.barArrived(at:flight.elapsed))
    }
    var verificationFlightPresentation: [String:Bool] {
        ["organic":mode == .organic,"admittedOrganic":admittedMode == .organic,"pending":pendingMode != nil]
    }
    var verificationFlightNativeOwners: Bool {
        // Inspect native views directly after finish, when the token array has already been disposed.
        if mode == .organic {
            return exposed(organic) && scene.columns.allSatisfy { $0.island.map {exposed($0.orb.glassView)} ?? false }
        }
        return exposed(workbench.sidebar.accountView.avatar) && workbench.sidebar.hiddenFlightSourceViews.isEmpty
    }
}
#endif


extension WindowShell {
    private var contentResolution:CGFloat {
        let value=Double(ProcessInfo.processInfo.environment["M11_MODE_PHOTO_SCALE"] ?? "2") ?? 2
        return CGFloat(min(2,max(0.5,value)))
    }
    private func contentRepresentationExposesEndpoint(_ session:ModeContentSession)->Bool {
        guard admittedMode == mode,!organic.isHidden,organic.layer?.opacity == 1 else {return false}
        if mode == .organic {
            guard normieBodyRoots.allSatisfy({$0.isHidden}) else {return false}
            if session.photoMode == "organic" {return true}
            let alpha=flight.manualTime != nil ? (contentPicture.layer?.opacity ?? 0):(contentPicture.layer?.presentation()?.opacity ?? contentPicture.layer?.opacity ?? 0)
            return alpha<=0.001
        }
        let alpha=flight.manualTime != nil ? (normieBodyRoot.layer?.opacity ?? 0):(normieBodyRoot.layer?.presentation()?.opacity ?? normieBodyRoot.layer?.opacity ?? 0)
        return !normieBodyRoot.isHidden && alpha>=0.999
    }
    private func contentRevision()->String {scene.store.conversations.map {"\($0.id):\($0.revision)"}.joined(separator:",")}
    private func contentInvalidationReason()->String {
        let approvals=scene.store.conversations.map {c in c.id+":"+c.approvals.map {"\($0.id)/\($0.request)/\($0.submitting)"}.joined(separator:",")}.joined(separator:";")
        let changed=contentApprovalSignature != approvals;defer {contentApprovalSignature=approvals}
        guard let old=contentLastKey else {return "store"}
        let next=flightPictureKey()
        if old.size != next.size || old.scale != next.scale {return "resize"}
        if old.appearance != next.appearance || old.contrast != next.contrast {return "appearance"}
        if old.models.map(\.draft) != next.models.map(\.draft) {return "typing"}
        if old.viewports.map(\.scroll) != next.viewports.map(\.scroll) || old.sidebarScroll != next.sidebarScroll {return "scroll"}
        return changed ? "approval":"streaming"
    }
    private func invalidateContentPicture(reason:String,onlyIfChanged:Bool=false) {
        let key=flightPictureKey()
        if onlyIfChanged,contentLastKey == key {return}
        contentLastKey=key;contentWarm=nil;contentWarmKey=nil
        contentInvalidations[reason,default:0]+=1
        (contentTrace ?? ModeSignposts.current)?.record("ModePhotoInvalidated",detail:"reason=\(reason) activeRetained=\(contentSession?.photoID ?? "none")")
        // An active picture is immutable, including during resize. Never replace it with a mixed snapshot.
        if !contentOpening && contentSession == nil && !contentEpochCompletionPending {contentCaptureGeneration &+= 1;contentCaptureTask?.cancel();contentCaptureTask=nil;contentCapturing=false;releaseContentEpoch();scheduleContentPicture(reason:reason)}
    }
    /// A warm capture is expendable; a mode opening or an admitted flight still owns its input shield.
    func prepareForContentInput() {
        guard contentEpochHeld,contentCapturing,!contentOpening,contentSession == nil else {return}
        invalidateContentPicture(reason:"input")
    }
    private func holdContentEpoch() {
        guard !contentEpochHeld else {return};contentEpochHeld=true;contentEpochRevision=contentRevision()
        let began=CACurrentMediaTime();defer {recordContentWork("epoch.freeze",began:began)}
        workbench.transcriptSessions.beginModeContentEpoch(scene.store.conversations)
        contentEpochRevision=scene.store.conversations.map {"\($0.id):\(workbench.transcriptSessions.modePresentationValue($0).revision)"}.joined(separator:",")
        for column in scene.columns {column.island?.setModeContentFrozen(true)}
        scene.composers.setModeContentEpochFrozen(true)
        scene.modeContentEpochFrozen=true;workbench.setModeContentEpochFrozen(true)
        workbench.detail.freezeModeLayout(true)
    }
    private func releaseContentEpoch() {
        if !contentOpening,contentSession == nil {departureSurfaces.finish()}
        guard contentEpochHeld else {return};contentEpochHeld=false;contentEpochRevision=nil
        workbench.transcriptSessions.modeContentMountLocked=false
        workbench.transcriptSessions.endModeContentEpoch()
        for column in scene.columns {column.island?.setModeContentFrozen(false)}
        scene.composers.setModeContentEpochFrozen(false)
        scene.modeContentEpochFrozen=false;workbench.setModeContentEpochFrozen(false)
        let pending=scene.modeContentEpochPending;scene.modeContentEpochPending=[]
        contentPendingReplay.formUnion(pending);scheduleContentReplay()
        workbench.detail.freezeModeLayout(false)
    }
    private func scheduleContentReplay() {
        guard !contentReplayScheduled,!contentEpochHeld,!contentPendingReplay.isEmpty else {return}
        contentReplayScheduled=true
        DispatchQueue.main.asyncAfter(deadline:.now()+flight.presentationInterval) { [weak self] in
            guard let self else {return};self.contentReplayScheduled=false
            guard !self.contentEpochHeld,!self.workbench.transcriptSessions.isDisposed else {return}
            if let id=self.contentPendingReplay.sorted().first(where:{self.workbench.transcriptSessions.existingTranscript(for:$0)?.modeContentIsCatchingUp != true}) {
                self.contentPendingReplay.remove(id)
                if let c=self.scene.store.conversation(id) {self.scene.changed(c)}
            }
            if self.contentPendingReplay.contains(where:{self.workbench.transcriptSessions.existingTranscript(for:$0)?.modeContentIsCatchingUp != true}) {self.scheduleContentReplay()}
        }
    }
    private var contentStoreIsQuiet:Bool {
        !scene.store.conversations.contains {$0.running || $0.sending || $0.loading} &&
            !workbench.transcriptSessions.transcripts.values.contains {$0.modeContentIsCatchingUp} && CACurrentMediaTime()-lastModeStoreChange>0.5
    }
    private func scheduleContentPicture(reason:String) {
        guard contentStoreIsQuiet else {return}
        guard ModeFlight.orreryEnabled,contentSession == nil,!contentOpening,!contentCapturing,!flight.running else {return}
        if contentWarm != nil,contentWarmKey == flightPictureKey() {return}
        // Geometry prewarming may ask repeatedly. Only an actual invalidation resets this deadline.
        if contentCaptureTask != nil {return}
        let generation=contentCaptureGeneration
        let task=DispatchWorkItem { [weak self] in
            guard let self,self.contentCaptureGeneration == generation else {return};self.contentCaptureTask=nil
            guard self.contentSession == nil,!self.contentOpening,!self.flight.running,self.contentStoreIsQuiet else {return}
            // A tracking control or marked-text editor may consume its remaining input inside AppKit.
            guard self.nativeHandoffAllowed() else {self.scheduleContentPicture(reason:"input.busy");return}
            self.captureContentPicture(cold:false) { [weak self] photo,key in
                guard let self else {return};self.contentWarm=photo;self.contentWarmKey=photo == nil ? nil:key
            }
        }
        contentCaptureTask=task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6,execute:task)
    }
    private func contentExclusions()->[NSView] {
        var excluded:[NSView]=[flight.view,sourcePlate,contentPicture,workbench.sidebar.view,scene.dockView]
        excluded += departureSurfaces.exclusions
        if let host=turnSidebar.verificationSafeNativeHost {excluded.append(host)}
        if let material=workbench.detail.modeComposerMaterial {excluded.append(material)}
        for column in scene.columns {if let island=column.island {excluded.append(island)}}
        let excludedRoots=Set(excluded.map(ObjectIdentifier.init))
        func scrollers(_ node:NSView) {
            guard !node.isHidden,!excludedRoots.contains(ObjectIdentifier(node)) else {return}
            if node is NSScroller {excluded.append(node);return}
            node.subviews.forEach(scrollers)
        }
        scrollers(view)
        return excluded
    }
    private func contentMaterialJobs(scale:CGFloat)->[ModeContentMaterialJob] {
        guard admittedMode == .normie else {return []}
        var jobs:[ModeContentMaterialJob]=[]
        if let material=workbench.detail.modeComposerMaterial,let ink=workbench.detail.composer {
            jobs.append(ModeContentMaterialJob(source:ink,ink:ink,glass:material,in:view,scale:scale,kind:"composer"))
        }
        func walk(_ node:NSView) {
            guard !node.isHidden,node.alphaValue>0 else {return}
            if let card=node as? NativeTranscriptCard,let glass=card.modePhotoMaterial,!glass.isHidden {
                jobs.append(ModeContentMaterialJob(source:card,ink:card,glass:glass,in:view,scale:scale,kind:"approval"));return
            }
            node.subviews.forEach(walk)
        }
        walk(normieBodyRoot)
        return jobs
    }
    private func captureContentPicture(cold:Bool,completion:@escaping (ModeWarmPicture?,ModeFlightPictureKey)->Void) {
        if contentSession != nil {contentSessionCaptureCount+=1;completion(nil,flightPictureKey());return}
        contentCaptureGeneration &+= 1;let generation=contentCaptureGeneration
        contentCapturing=true;holdContentEpoch()
        let key=flightPictureKey(),revision=contentEpochRevision ?? contentRevision(),source=admittedMode.rawValue,scale=contentResolution,size=view.bounds.size
        let selected=admittedMode == .organic ? scene.current:workbench.selectedConversation?.id ?? ""
        contentLastKey=key
        let trace=contentTrace ?? ModeSignposts.current ?? (ModeSignposts.enabled ? ModeSignposts.Trace():nil)
        let began=CACurrentMediaTime()
        // Cold capture records the source already on screen. Forcing the whole window to lay out
        // here presents a newer store version and repeats native work before its shield is installed.
        if !cold {view.window?.contentView?.superview?.layoutSubtreeIfNeeded()}
        let captureAppearance=view.effectiveAppearance.name,displayRevision=NativeDisplayOptions.shared.revision,nativeRevision=NativeAppearance.revision
        let scrolls=workbench.transcriptSessions.transcripts.filter {!$0.value.isHiddenOrHasHiddenAncestor && $0.value.presentationActive}.mapValues { $0.scrollOffset }
        let terminalKey=workbench.detail.terminalPane.motionContentKey
        func inputsMatch()->Bool {
            self.contentSession == nil && self.view.bounds.size == size && self.view.effectiveAppearance.name == captureAppearance &&
                NativeDisplayOptions.shared.revision == displayRevision && NativeAppearance.revision == nativeRevision &&
                self.workbench.transcriptSessions.transcripts.filter({!$0.value.isHiddenOrHasHiddenAncestor && $0.value.presentationActive}).mapValues({$0.scrollOffset}) == scrolls &&
                self.workbench.detail.terminalPane.motionContentKey == terminalKey &&
                (cold || (self.contentRevision() == revision && self.flightPictureKey() == key))
        }
        trace?.record("ModePhotoCapture",.begin,detail:"path=\(cold ? "cold":"warm") resolution=\(scale) size=\(size) revision=\(revision)")
        // WindowServer material is not a bitmap. Freeze its ink independently and retain a matching
        // process-owned material surface above the opaque source bitmap for the picture's lifetime.
        let materialJobs=contentMaterialJobs(scale:scale)
        let builder=ModeSurfaceBuilder(view,scale:scale,includeWindowFrame:false,excluding:contentExclusions()+materialJobs.map(\.source),normalizeRootOpacity:true,opaqueBody:true)
        var materialIndex=0,nativeRowCursor=0,nativePrepared = !cold
        func prepareNativeStep() {
            guard cold,!nativePrepared else {return}
            let start=CACurrentMediaTime()
            if self.mode == .organic,let plan=self.admissionOrganicTarget {
                nativePrepared=self.scene.prepareModeTargetStep(plan)
                if !self.scene.modeTargetIsValid(plan) {nativePrepared=true}
            } else if self.mode == .normie,let c=self.scene.conversation(self.contentFocusConversation ?? self.scene.current) {
                let width=max(1,self.view.bounds.width-self.workbench.sidebar.view.bounds.width)
                nativePrepared=self.workbench.transcriptSessions.transcript(for:c,store:self.scene.store).prepareModeRow(width:width,cursor:&nativeRowCursor)
            } else {nativePrepared=true}
            self.recordContentWork("native.prepare.slice",began:start)
        }
        var maximumSlice=(CACurrentMediaTime()-began)*1000
        var slices:[Double]=[],sliceTimes:[Double]=[],sliceIntervals:[Double]=[],sliceBudgets:[Double]=[],maximumPaintSeconds=0.0015
        func step() {
            guard self.contentCaptureGeneration == generation else {return}
            if !inputsMatch() {
                self.contentCapturing=false
                if !self.contentOpening {self.releaseContentEpoch()}
                trace?.record("ModePhotoCapture",.end,detail:"cancelled size=\(self.view.bounds.size != size) appearance=\(self.view.effectiveAppearance.name != captureAppearance) terminal=\(self.workbench.detail.terminalPane.motionContentKey != terminalKey) sourceMode=\(source) requested=\(self.mode.rawValue)")
                completion(nil,key);return
            }
            let start=CACurrentMediaTime();sliceTimes.append(start);sliceIntervals.append(self.flight.presentationInterval)
            // At most one native preparation item per display batch. Never append a cold mount to it.
            prepareNativeStep()
            let paintBudget=ModeContentWorkBoundary.captureBudget(at:start);sliceBudgets.append(paintBudget*1000)
            var painted=false
            // An indivisible AppKit draw can exceed its estimate. Always permit one item in a fresh
            // frame, or a previous >4 ms tile would poison the estimate and starve this capture forever.
            while paintBudget>=0.0015 && CACurrentMediaTime()-start<paintBudget && (!painted || CACurrentMediaTime()-start+max(builder.lastStepSeconds,maximumPaintSeconds)<paintBudget) {
                let paintBegan=CACurrentMediaTime()
                if !builder.ready {builder.step()}
                else if materialIndex<materialJobs.count {materialJobs[materialIndex].step();if materialJobs[materialIndex].ready {materialIndex+=1}}
                else {break}
                maximumPaintSeconds=max(maximumPaintSeconds*0.8,CACurrentMediaTime()-paintBegan)
                painted=true
            }
            let cost=(CACurrentMediaTime()-start)*1000;maximumSlice=max(maximumSlice,cost);slices.append(cost)
            if !builder.ready || materialIndex<materialJobs.count || !nativePrepared {
                // A timer deadline separates batches by a display interval, not another main-queue drain item.
                ModeContentWorkBoundary.schedule(in:self.view,interval:self.flight.presentationInterval) {step()};return
            }
            guard let picture=builder.finish() else {completion(nil,key);return}
            let raster=ModeContentRaster(tiles:picture.tiles.map {.init(rect:$0.rect,image:$0.image)},size:size,scale:scale)
            let inkRasters=materialJobs.map {$0.raster()}
            let job=Task.detached(priority:.userInitiated) {(raster.render(),inkRasters.map {$0?.render()})}
            Task { @MainActor in
                let (body,inks)=await job.value
                #if M11_MODE_SELFTEST
                self.verificationAfterPictureJoin?()
                #endif
                guard self.contentCaptureGeneration == generation else {return}
                guard let image=body,self.view.bounds.size == size,self.view.effectiveAppearance.name == captureAppearance,
                      NativeDisplayOptions.shared.revision == displayRevision,NativeAppearance.revision == nativeRevision,
                      cold || inputsMatch() else {
                    self.contentCapturing=false;if !self.contentOpening {self.releaseContentEpoch()};completion(nil,key);return
                }
                let photo=ModeWarmPicture(mode:source,revision:revision,image:image,size:size,scale:scale,captureMS:(CACurrentMediaTime()-began)*1000,maximumSliceMS:maximumSlice,selection:selected,materials:zip(materialJobs,inks).compactMap {$0.0.finish(ink:$0.1)})
                self.contentCapturing=false
                self.contentCaptureCosts.append(["mode":source,"scale":scale,"wallMS":photo.captureMS,"maximumSliceMS":maximumSlice,"bytes":photo.bytes,"cold":cold,"slicesMS":slices,"sliceTimes":sliceTimes,"sliceIntervals":sliceIntervals,"sliceBudgetsMS":sliceBudgets])
                trace?.record("ModePhotoCapture",.end,detail:"resolution=\(scale) bytes=\(photo.bytes) wallMS=\(photo.captureMS) maximumSliceMS=\(maximumSlice) slices=\(slices.count)")
                if !cold {
                    self.releaseContentEpoch()
                    // Releasing may synchronously replay native changes and invalidate this generation.
                    guard self.contentCaptureGeneration == generation,self.flightPictureKey() == key else {completion(nil,key);return}
                }
                completion(photo,key)
            }
        }
        ModeContentWorkBoundary.schedule(in:self.view,interval:flight.presentationInterval) {step()}
    }
    private func recordContentWork(_ phase:String,began:Double) {
        let ms=(CACurrentMediaTime()-began)*1000
        if contentWorkCosts.count<256 {contentWorkCosts.append(["phase":phase,"ms":ms])}
        onTurnCost?(phase,ms)
        contentTrace?.record("ModeContentWork",detail:"phase=\(phase) ms=\(ms)")
    }
    private func contentFlight(_ next:Mode,prepared:PreparedModeSwitch?=nil) {
        let began=CACurrentMediaTime();defer {recordContentWork("flight.submit",began:began);ModeContentWorkBoundary.flightSubmitted(interval:flight.presentationInterval)}
        flight.onFrame={ [weak self] time in self?.publishFlightOwners(at:time) }
        flight.prioritizesInitialSubmit=true
        if flight.running {
            let tokens=flight.activeTokens.map {ModeFlight.Token(id:$0.id,conversation:$0.conversation,from:$0.to,to:$0.from,start:$0.start,absorbed:next == .normie)}
            let avatar=flight.avatarEndpoints(toOrganic:next == .organic) ?? (sidebarAvatar(),scene.meRest)
            flight.start(toOrganic:next == .organic,avatar:avatar,initials:initials,tokens:tokens,composer:nil,reduceMotion:false)
        } else {
            let target=next == .organic ? (admissionOrganicTarget ?? workbench.selectedConversation.flatMap {scene.beginModeTarget(selected:$0.id)}):nil
            if next == .organic {admissionOrganicTarget=target}
            let rows=prepared?.rows ?? sidebarRows(reusingPrepared:true),headers=target?.headers ?? prepared?.headers ?? headerEndpoints()
            let validPrepared=prepared.flatMap {next != .organic || $0.organicTarget?.key.selected == workbench.selectedConversation?.id ? $0:nil}
            let tokens=validPrepared.map {next == .organic ? $0.toOrganic:$0.toNormie} ?? openingTokens(next,rows:rows,headers:headers,target:target)
            let side=prepared?.avatar ?? sidebarAvatar(),me=target?.me ?? scene.meRest
            flight.start(toOrganic:next == .organic,avatar:next == .organic ? (side,me):(me,side),initials:initials,tokens:tokens,composer:nil,reduceMotion:false)
        }
        // frame(0) publishes source ownership in the very same flight transaction.
        // Avoid a second blanket hide/layout/commit after the server command has been installed.
        #if M11_MODE_SELFTEST
        beforeTurnSidebarCommit?()
        #endif
        if contentFirstSubmitMS.count>=512 {contentFirstSubmitMS.removeFirst()}
        contentFirstSubmitMS.append((CACurrentMediaTime()-contentKeyTime)*1000)
        contentTrace?.record("ModeFlightFirstSubmit",detail:"keyLatencyMS=\((CACurrentMediaTime()-contentKeyTime)*1000)")
    }
    private var contentNormieLayoutKey:[CGFloat] {
        [view.bounds.width,view.bounds.height,workbench.sidebar.view.bounds.width,
         split.splitViewItems.last?.isCollapsed == true ? 1:0,workbench.inspector.view.bounds.width]
    }
    private func prepareContentNormieLayout() {
        guard contentPreparedNormieLayout != contentNormieLayoutKey else {return}
        workbench.sidebar.endModePreparation();workbench.detail.endModePreparation()
        normieBodyRoot.isHidden=false;normieBodyRoot.layer?.opacity=0
        if split.splitViewItems.first?.isCollapsed == true {split.splitViewItems.first?.isCollapsed=false}
        finishNormieEndpoint {setModeToolbar(true,in:view.window)}
        contentPreparedNormieLayout=contentNormieLayoutKey
    }
    private func holdContentPictureCover(photoMode:String) {
        organic.isHidden=false;organic.layer?.opacity=1
        normieBodyRoots.forEach {$0.layer?.opacity=0}
        if photoMode == "normie" {
            scene.dockView.layer?.opacity=0
            for column in scene.columns {column.island?.layer?.opacity=0}
        }
    }
    private func afterContentCommit(generation:UInt64,phase:String,_ body:@escaping @MainActor ()->Void) {
        contentTrace?.record("ModeContentWorkQueued",detail:"phase=\(phase) generation=\(generation)")
        ModeContentWorkBoundary.schedule(in:self.view,interval:flight.presentationInterval) { [weak self] in
            guard let self,self.contentSessionGeneration == generation,self.contentOpening else {return}
            self.contentTrace?.record("ModeContentWorkBoundary",detail:"phase=\(phase) generation=\(generation)")
            ModeSignposts.withTrace(self.contentTrace,body)
        }
    }
    private func beginContentSwitch(_ next:Mode,window:NSWindow?,probe:ModeSignposts.Trace?) {
        guard nativeHandoffAllowed(),!scene.isTearing else {probe?.record("ModeSwitchRejected",detail:"native handoff guard");return}
        contentFocusRestoreGeneration &+= 1
        let entered=flight.manualTime?() ?? CACurrentMediaTime();contentKeyTime=contentInputEntered ?? CACurrentMediaTime();contentInputEntered=nil;contentTrace=probe ?? ModeSignposts.current ?? contentTrace
        contentTrace?.record("ModeContentKey",detail:"requested=\(next.rawValue)",at:flight.manualTime == nil ? contentKeyTime:entered)
        if let session=contentSession {
            CATransaction.begin();CATransaction.setDisableActions(true)
            mode=next;contentEndpointChecks=0
            let turnTime=contentNow
            let bodyLayer=session.photoMode == "normie" ? contentPicture.layer:normieBodyRoot.layer
            // A restored native source may have hidden its picture at an opaque endpoint. That layer's
            // opacity no longer represents u; only the fixed live representation can supply a sample.
            let canSample=admittedMode.rawValue == session.liveMode && flight.manualTime == nil && view.window?.isVisible == true && bodyLayer?.animation(forKey:"mode.content.phase") != nil
            let displayed=canSample ? bodyLayer?.presentation().map {Double($0.opacity)}:nil
            session.turn(to:next.rawValue,at:turnTime,presentedAlpha:displayed)
            if admittedMode.rawValue != session.liveMode {session.hold(at:turnTime)}
            animateContentSession(at:turnTime);CATransaction.commit()
            // This transaction changes only existing opacity clocks. Submit it before rebuilding flight channels.
            CATransaction.flush()
            contentTrace?.record("ModeContentTurnSubmit",detail:"u=\(session.progress(at:turnTime)) requested=\(next.rawValue)")
            CATransaction.begin();CATransaction.setDisableActions(true)
            contentFlight(next);CATransaction.commit()
            turnSidebar.moveNative(incoming:next == .normie)
            applyContentSidebarCutout()
            if session.isHeld {prepareContentLiveOwner(session)}
            scheduleContentEndpoint(generation:contentSessionGeneration)
            onModeChange?(next);return
        }
        if contentOpening {
            mode=next;pendingMode=next;contentFlight(next);turnSidebar.moveNative(incoming:next == .normie);applyContentSidebarCutout()
            if next == admittedMode,contentDetachedOwner == nil {
                let generation=contentSessionGeneration
                afterContentCommit(generation:generation,phase:"capture.cancel-return") {
                    guard self.mode == self.admittedMode,self.contentDetachedOwner == nil else {return}
                    self.contentCaptureGeneration &+= 1;self.contentCapturing=false
                    self.finishAbandonedContentOpening(owner:self.admittedMode)
                }
            }
            onModeChange?(next);return
        }
        let old=admittedMode,prepared=preparedSwitch ?? lastFlightGeometry.flatMap {$0.geometryKey.size == view.bounds.size && $0.key.mode == admittedMode.rawValue ? $0:nil}
        contentCaptureGeneration &+= 1;contentCaptureTask?.cancel();contentCaptureTask=nil;contentCapturing=false
        contentSessionGeneration &+= 1;let generation=contentSessionGeneration
        contentSelectionPlan=nil;contentSelectionTarget=nil;contentSelectionPreparing=false
        contentEpochCompletionPending=false
        contentOpening=true;contentFrameTime=0;contentDeferredSelection=nil;mode=next;pendingMode=next
        if old == .organic {scene.dock.beginTideDeparture(using:departureSurfaces,in:scene.nativePlane,at:contentKeyTime)}
        admissionOrganicTarget=next == .organic ? prepared?.organicTarget.flatMap {$0.key.selected == workbench.selectedConversation?.id ? $0:nil}:nil
        // Submit flight before any capture or native mount work. Its server clock remains independent.
        contentFlight(next,prepared:prepared)
        ModeContentWorkBoundary.flightSubmitted(interval:flight.presentationInterval)
        rememberContentFocus();contentInspectorWasOpen=workbench.inspectorVisible
        contentInspectorEnabled = !workbench.isCollapsed
        func admit(_ photo:ModeWarmPicture?,warm:Bool) {
            guard self.contentSessionGeneration == generation,self.contentOpening else {return}
            guard let photo else {self.failContentOpening(owner:old);return}
            if self.mode == old {self.finishAbandonedContentOpening(owner:old);return}
            self.afterContentCommit(generation:generation,phase:"picture.install") {
                guard self.nativeHandoffAllowed() else {self.failContentOpening(owner:old);return}
                let began=CACurrentMediaTime()
                CATransaction.begin();CATransaction.setDisableActions(true)
                self.contentPicture.install(photo)
                self.contentPicture.isHidden=false
                let firstHeader=self.scene.nativePlane.subviews.first {$0 is HeaderIsland}
                self.scene.nativePlane.addSubview(self.contentPicture,positioned:.below,relativeTo:firstHeader)
                self.contentPicture.layer?.zPosition=0;self.contentPicture.layer?.opacity=1
                self.organic.layer?.zPosition=0;self.split.view.layer?.zPosition=2
                self.holdContentPictureCover(photoMode:photo.mode)
                if let host=self.turnSidebar.verificationSafeNativeHost {
                    self.contentSidebarCutout.apply(to:self.organic,width:host.bounds.width,time:self.contentNow,revision:self.turnSidebar.nativeClockRevision,offset:self.turnSidebar.rowOffset)
                }
                CATransaction.commit()
                self.recordContentWork("picture.install",began:began)
                self.afterContentCommit(generation:generation,phase:"native.detach") {
                    guard self.nativeHandoffAllowed() else {self.failContentOpening(owner:old);return}
                    if self.mode == old {self.finishAbandonedContentOpening(owner:old);return}
                    let began=CACurrentMediaTime()
                    for native in self.workbench.transcriptSessions.transcripts.values {native.resetModeContentScrollCompensation()}
                    if old == .organic {self.contentComposerInk.retain(from:self.scene.dock,scale:self.contentResolution)}
                    if old == .normie {_=ModeSignposts.measure("ComposerHandoff") {self.workbench.composerForHandoff()}}
                    else {self.scene.suspendModePresentation()}
                    self.contentDetachedOwner=old
                    self.contentComposerInk.refresh()
                    self.recordContentWork("native.detach",began:began)
                    @MainActor func commitNative() {
                    self.afterContentCommit(generation:generation,phase:"native.admission") {
                        guard self.nativeHandoffAllowed() else {self.failContentOpening(owner:old);return}
                        let requested=self.mode
                        if requested == old {self.finishAbandonedContentOpening(owner:old);return}
                        #if M11_MODE_SELFTEST
                        if !warm {self.verificationColdAdmissionReadiness.append(requested == .organic ? (self.admissionOrganicTarget?.ready == true):!self.workbench.transcriptSessions.transcripts.values.flatMap(\.modePreparedWidths).isEmpty)}
                        #endif
                        let began=CACurrentMediaTime(),focus=self.contentAdmissionResponder
                        CATransaction.begin();CATransaction.setDisableActions(true)
                        self.performingAdmission=true
                        let committed=self.workbench.transcriptSessions.withModeContentMountPermission {
                            requested == .organic ? self.toOrganic(window,animated:false,reduce:false):self.toNormie(window,animated:false,reduce:false)
                        }
                        self.performingAdmission=false
                        guard committed else {CATransaction.commit();self.failContentOpening(owner:old);return}
                        self.admittedMode=requested;self.finalizeNativeOwner(requested,window:window)
                        self.organic.isHidden=false;self.organic.alphaValue=1;self.organic.layer?.opacity=1
                        // Keep the same complete source cover through the target's first native layout commit.
                        self.holdContentPictureCover(photoMode:photo.mode)
                        self.restoreAdmissionResponder(focus)
                        CATransaction.commit()
                        self.recordContentWork("native.admission",began:began)
                        self.afterContentCommit(generation:generation,phase:"native.ready-layout") {
                            let began=CACurrentMediaTime()
                            if requested == .normie {
                                _=self.workbench.transcriptSessions.withModeContentMountPermission {
                                    self.workbench.detail.freezeModeLayout(false)
                                    self.workbench.detail.view.needsLayout=true
                                    self.workbench.detail.view.layoutSubtreeIfNeeded()
                                    return true
                                }
                                self.workbench.detail.hideNonSelectedModeTranscripts()
                            }
                            self.holdContentPictureCover(photoMode:photo.mode)
                            self.recordContentWork("native.ready-layout",began:began)
                            self.afterContentCommit(generation:generation,phase:"content.fade") {
                            let session=ModeContentSession(photo:photo,target:requested.rawValue,time:self.flight.manualTime?() ?? CACurrentMediaTime(),trace:self.contentTrace)
                            if self.mode != requested {session.turn(to:self.mode.rawValue,at:session.anchorTime)}
                            self.contentSession=session;self.contentEndpointChecks=0;self.contentSessionCaptureCount=0;self.contentMountCount=1;self.contentMidPhaseMounts=0
                            self.contentInitialMountGeneration=self.workbench.transcriptSessions.modeMountGeneration
                            session.leaseGeneration=UInt64(self.contentMountCount)
                            self.contentOpening=false;self.pendingMode=nil;self.contentDetachedOwner=nil;self.contentOrganicReady=nil
                            self.refreshTitle();window?.toolbar?.validateVisibleItems()
                            self.contentWarm=nil;self.contentWarmKey=nil
                            self.animateContentSession(at:session.anchorTime)
                            self.contentFadeLatencies.append(["path":warm ? "warm":"cold","ms":(CACurrentMediaTime()-self.contentKeyTime)*1000])
                            self.contentTrace?.record("ModeContentFadeStart",detail:"path=\(warm ? "warm":"cold") keyLatencyMS=\((CACurrentMediaTime()-self.contentKeyTime)*1000) sessionID=\(session.id) photoID=\(photo.id)")
                            self.reconcileNativeRowFence();self.flight.destinationDidMount()
                            self.scheduleContentEndpoint(generation:generation)
                            }
                        }
                    }
                    }
                    if self.mode == .organic,let plan=self.admissionOrganicTarget,plan.ready,self.scene.modeTargetIsValid(plan) {
                        self.afterContentCommit(generation:generation,phase:"native.columns") {
                            guard self.nativeHandoffAllowed() else {self.failContentOpening(owner:old);return}
                            if self.mode == old {self.finishAbandonedContentOpening(owner:old);return}
                            let began=CACurrentMediaTime(),focus=self.contentAdmissionResponder
                            CATransaction.begin();CATransaction.setDisableActions(true)
                            let committed=self.workbench.transcriptSessions.withModeContentMountPermission {self.scene.commitModeTarget(plan,includeDock:false)}
                            self.holdContentPictureCover(photoMode:photo.mode)
                            self.restoreAdmissionResponder(focus)
                            CATransaction.commit()
                            self.recordContentWork("native.columns",began:began)
                            guard committed else {commitNative();return}
                            self.afterContentCommit(generation:generation,phase:"native.dock") {
                                let began=CACurrentMediaTime(),focus=self.contentAdmissionResponder
                                CATransaction.begin();CATransaction.setDisableActions(true)
                                self.scene.finishModeContentDockCommit();self.contentOrganicReady=plan
                                self.holdContentPictureCover(photoMode:photo.mode)
                                self.restoreAdmissionResponder(focus)
                                CATransaction.commit()
                                self.recordContentWork("native.dock",began:began)
                                commitNative()
                            }
                        }
                    } else if self.mode == .normie {
                        let selected=self.contentFocusConversation ?? self.scene.current
                        let phases:[(String,@MainActor ()->Void)]=[
                            ("native.normie-editor",{
                                var began=CACurrentMediaTime()
                                self.workbench.memberOrder=self.scene.order
                                self.workbench.prepareModeContentSelection(selected,draft:self.scene.composingNew,context:self.scene.draftContext)
                                self.recordContentWork("native.normie-selection",began:began)
                                began=CACurrentMediaTime();self.workbench.prepareModeContentEditor()
                                self.recordContentWork("native.normie-editor",began:began)
                                began=CACurrentMediaTime();self.workbench.prepareModeContentChrome()
                                self.recordContentWork("native.normie-chrome",began:began)
                            }),
                            ("native.normie-layout",{
                                self.prepareContentNormieLayout()
                                self.workbench.detail.freezeModeLayout(false)
                                self.workbench.detail.view.needsLayout=true
                                self.workbench.detail.view.layoutSubtreeIfNeeded()
                                self.normieNativeStaged=true;self.normieEndpointStaged=true
                            })]
                        @MainActor func stage(_ index:Int) {
                            guard index<phases.count else {commitNative();return}
                            let (phase,body)=phases[index]
                            self.afterContentCommit(generation:generation,phase:phase) {
                                guard self.nativeHandoffAllowed() else {self.failContentOpening(owner:old);return}
                                if self.mode == old {self.finishAbandonedContentOpening(owner:old);return}
                                let began=CACurrentMediaTime(),focus=self.contentAdmissionResponder
                                CATransaction.begin();CATransaction.setDisableActions(true)
                                _=self.workbench.transcriptSessions.withModeContentMountPermission {body();return true}
                                self.contentComposerInk.refresh()
                                self.holdContentPictureCover(photoMode:photo.mode)
                                self.restoreAdmissionResponder(focus);CATransaction.commit()
                                self.recordContentWork(phase == "native.normie-editor" ? "native.normie-prepare":phase,began:began)
                                stage(index+1)
                            }
                        }
                        stage(0)
                    } else {commitNative()}
                }
            }
        }
        // Return to the run loop for the flight's first commit before any source index, layout,
        // epoch, chrome, focus or native admission work. Never enqueue capture in the same drain.
        ModeContentWorkBoundary.schedule(in:self.view,interval:flight.presentationInterval) { [weak self] in
            guard let self,self.contentSessionGeneration == generation,self.contentOpening else {return}
            self.cancelModePreparation();self.admission.cancel();self.sourcePlate.clear();self.transitionGeneration &+= 1
            self.turnSidebar.moveNative(incoming:self.mode == .normie)
            self.applyContentSidebarCutout()
            let warmKeyBeforeInput=self.flightPictureKey()
            self.holdContentEpoch();self.workbench.transcriptSessions.modeContentMountLocked=true
            self.scene.beginModeHandoff();self.scene.dock.composerMotion.beginModeHandoff();self.workbench.detail.beginModeHandoff()
            if let warm=self.contentWarm,self.contentWarmKey == warmKeyBeforeInput,warm.mode == old.rawValue,warm.scale == self.contentResolution {admit(warm,warm:true)}
            else {self.captureContentPicture(cold:true) {photo,_ in admit(photo,warm:false)}}
            self.onModeChange?(self.mode)
        }
    }
    private func applyContentSidebarCutout() {
        guard let host=turnSidebar.verificationSafeNativeHost else {return}
        contentSidebarCutout.apply(to:organic,width:host.bounds.width,time:contentNow,revision:turnSidebar.nativeClockRevision,offset:turnSidebar.rowOffset)
    }
    private func prepareContentLiveOwner(_ session:ModeContentSession) {
        guard !contentEndpointMountPending else {return}
        contentEndpointMountPending=true
        let generation=contentSessionGeneration
        ModeContentWorkBoundary.schedule(in:self.view,interval:flight.presentationInterval) { [weak self,weak session] in
            guard let self,let session,self.contentSession === session,self.contentSessionGeneration == generation else {return}
            self.contentEndpointMountPending=false
            guard session.isHeld else {return}
            let live=Mode(rawValue:session.liveMode)!
            guard self.mountContentOwner(live,session:session,coveredU:session.anchorU) else {
                self.prepareContentLiveOwner(session);return
            }
            self.mode=Mode(rawValue:session.requestedMode)!
            session.resume(at:self.contentNow)
            self.animateContentSession(at:self.contentNow)
            self.flight.destinationDidMount()
        }
    }
    private func animateContentSession(at time:Double) {
        guard let session=contentSession else {return}
        organic.isHidden=false;organic.alphaValue=1;organic.layer?.opacity=1
        organic.layer?.backgroundColor=NativePalette.canvas.withAlphaComponent(1).cgColor
        if let host=turnSidebar.verificationSafeNativeHost {
            contentSidebarCutout.apply(to:organic,width:host.bounds.width,time:contentNow,revision:turnSidebar.nativeClockRevision,offset:turnSidebar.rowOffset)
        }
        contentDockExposure.apply(to:scene.dockView,session:session,time:time)
        if let window=view.window {
            for chrome in modeChromeSurfaces(in:window) {
                chrome.wantsLayer=true;chrome.setAccessibilityHidden(true)
                if let layer=chrome.layer {session.animate(layer,at:time,photoOnTop:false)}
            }
        }
        if session.photoMode == "normie" {
            normieBodyRoots.forEach {$0.isHidden=true}
            if let layer=contentPicture.layer {session.animate(layer,at:time,photoOnTop:true)}
            // The resident header channel is above the body picture. Apply the same source-over attenuation once.
            for column in scene.columns {if let island=column.island {island.wantsLayer=true;if let layer=island.layer {session.animate(layer,at:time,photoOnTop:false,invert:true)}}}
        } else {
            contentPicture.layer?.opacity=1
            for column in scene.columns {column.island?.layer?.removeAnimation(forKey:"mode.content.phase");column.island?.layer?.opacity=1}
            for (root,item) in zip(normieBodyRoots,split.splitViewItems.dropFirst()) {
                root.isHidden=item.isCollapsed
                if !item.isCollapsed,let layer=root.layer {session.animate(layer,at:time,photoOnTop:false)}
            }
        }
    }
    private func scheduleContentEndpoint(generation:UInt64) {
        guard contentEndpointChecks<20 else {return}
        contentEndpointChecks+=1
        DispatchQueue.main.asyncAfter(deadline:.now()+0.225) { [weak self] in
            guard let self,self.contentSessionGeneration == generation else {return}
            self.advanceContentSession(at:self.contentNow,flightFinished:!self.flight.running)
            if self.contentSession != nil {self.scheduleContentEndpoint(generation:generation)}
        }
    }
    private func advanceContentSession(at time:Double,flightFinished:Bool) {
        guard let session=contentSession else {return}
        if let selected=contentDeferredSelection {prepareDeferredOrganicSelection(selected)}
        let rendered=workbench.transcriptSessions.transcripts.values.filter {!$0.isHiddenOrHasHiddenAncestor}.map {"\($0.conversation.id):\($0.renderedRevision)"}.sorted().joined(separator:",")
        session.leaseGeneration=workbench.transcriptSessions.modeMountGeneration
        session.record(at:time,renderedRevision:rendered)
        guard session.atDestination(time),!contentFinishing else {return}
        contentFinishing=true;defer {contentFinishing=false}
        let target=Mode(rawValue:session.requestedMode)!
        if contentDeferredSelection == nil,let selected=workbench.selectedConversation?.id,selected != session.selection {contentDeferredSelection=selected}
        let selectedAfterPicture=contentDeferredSelection ?? workbench.selectedConversation?.id
        // At full cover, admit the native endpoint before asking its flight fence to retire.
        if admittedMode != target {
            guard !contentEndpointMountPending else {return}
            contentEndpointMountPending=true
            let generation=contentSessionGeneration
            ModeContentWorkBoundary.schedule(in:self.view,interval:flight.presentationInterval) { [weak self,weak session] in
                guard let self,let session,self.contentSession === session,self.contentSessionGeneration == generation else {return}
                self.contentEndpointMountPending=false
                guard session.requestedMode == target.rawValue,session.atDestination(self.contentNow) else {return}
                let began=CACurrentMediaTime()
                let success=self.mountContentOwner(target,session:session,coveredU:session.progress(at:self.contentNow))
                self.recordContentWork("native.endpoint",began:began)
                if success {self.flight.destinationDidMount();self.advanceContentSession(at:self.contentNow,flightFinished:!self.flight.running)}
            }
            return
        }
        guard flightFinished else {return}
        contentEpochCompletionPending=true
        CATransaction.begin();CATransaction.setDisableActions(true)
        guard commitPreparedContentSelection(selectedAfterPicture,target:target) else {
            CATransaction.commit();contentEpochCompletionPending=false
            if let selectedAfterPicture {prepareDeferredOrganicSelection(selectedAfterPicture)}
            return
        }
        session.record(at:time,renderedRevision:rendered,boundary:true)
        contentSession=nil;contentPicture.isHidden=true;contentDockExposure.clear();contentSidebarCutout.clear();pendingMode=nil;mode=target
        for column in scene.columns {column.island?.layer?.removeAnimation(forKey:"mode.content.phase");column.island?.layer?.opacity=1}
        ModeSignposts.operation("ModeContentNativePublication",detail:"mode=\(target.rawValue)") {
            finalizeNativeOwner(target,window:view.window);admittedMode=target
            if target == .normie {contentComposerInk.clear()} else {contentComposerInk.refresh()}
            organic.layer?.opacity=1
        }
        CATransaction.commit()
        let generation=contentSessionGeneration
        // D is already presented. Release model catchup on a separate display ticket, never in its publication frame.
        ModeContentWorkBoundary.schedule(in:view,interval:flight.presentationInterval) { [weak self] in
            guard let self,self.contentSessionGeneration == generation,self.contentSession == nil,!self.contentOpening else {return}
            CATransaction.begin();CATransaction.setDisableActions(true)
            ModeSignposts.operation("ModeContentPictureRetirementWork",detail:"hidden picture; native owner already published") {self.contentPicture.clear()}
            ModeSignposts.operation("ModeContentCatchupLayout",detail:"mode=\(target.rawValue)") {
                if target == .normie {self.workbench.detail.prepareModeContentCatchup()}
                else {self.workbench.detail.endModeHandoff()}
            }
            let epochBegan=CACurrentMediaTime()
            ModeSignposts.operation("ModeContentEpochReleaseWork",detail:"mode=\(target.rawValue)") {
                self.releaseContentEpoch();self.scene.endModeHandoff();self.scene.dock.composerMotion.endModeHandoff()
            }
            self.recordContentWork("native.epoch.release",began:epochBegan)
            CATransaction.commit()
            self.contentTrace?.record("ModeContentEpochReleased",detail:"prepared owner published before normal streaming/card catchup")
            ModeContentWorkBoundary.schedule(in:self.view,interval:self.flight.presentationInterval) { [weak self] in
                guard let self,self.contentSessionGeneration == generation,self.contentSession == nil,!self.contentOpening else {return}
                ModeSignposts.operation("ModeContentFocusRestoreWork",detail:"mode=\(target.rawValue)") {
                    self.restoreSelectedContentFocus(self.contentDeferredSelection,target:target)
                }
                self.contentDeferredSelection=nil;self.clearContentFocus()
                self.contentEpochCompletionPending=false
                self.scheduleModePrewarm(reason:"content.epoch.released")
            }
        }
        releaseFlightHidden();workbench.sidebar.setFlightSourcesHidden([],avatar:false)
        turnSidebar.finishWhenSettled {};preparedSwitch=nil;scheduleModePrewarm(reason:"content.session.end")
    }
    /// Preserve the frozen key until the prepared target is mounted. A store callback cannot invalidate
    /// it between flight retirement and native publication, and a cold synchronous show is never a fallback here.
    private func commitPreparedContentSelection(_ selected:String?,target:Mode)->Bool {
        guard let selected,scene.store.conversation(selected)?.archived == false else {return true}
        guard selected != workbench.selectedConversation?.id || (target == .organic && selected != scene.current) else {return true}
        if target == .organic,selected != scene.current {
            guard let plan=contentSelectionPlan,plan.key.selected == selected,plan.ready,scene.modeTargetIsValid(plan) else {
                contentTrace?.record("ModeContentSelectionNotReady",detail:"id=\(selected) frozen=\(contentEpochHeld)")
                return false
            }
        }
        let began=CACurrentMediaTime()
        let committed=ModeSignposts.operation("ModeContentSelectionCommitWork",detail:"id=\(selected) target=\(target.rawValue)") {
            workbench.transcriptSessions.withModeContentMountPermission {
                if target == .organic,selected != scene.current,let plan=contentSelectionPlan {
                    guard scene.commitModeTarget(plan,includeDock:false) else {return false}
                    ModeSignposts.operation("ModeContentSelectedDockCommit",detail:selected) {
                        if scene.members.contains(where:{scene.dock.items[$0.id] == nil}) {
                            scene.dock.ensureItems(for:scene.members,layout:scene.layout,order:scene.order)
                        }
                        scene.dock.relayout(scene.layout,metrics:scene.metrics,order:scene.order.compactMap(scene.conversation),full:scene.fullIDs)
                        // relayout already settled these roles. Do not settle and remount the same six items twice.
                        scene.remountComposers();scene.updateStatus()
                    }
                    scene.columns.first(where:{$0.conversation.id == selected})?.native.prepareModeFollowResumption()
                    contentTrace?.record("ModeContentSelectionCommit",detail:"id=\(selected) prepared=true rise=\(scene.dock.rise)")
                }
                if selected != workbench.selectedConversation?.id {_=workbench.select(selected)}
                return true
            }
        }
        recordContentWork("native.selection.commit",began:began)
        if committed {contentSelectionPlan=nil;contentSelectionTarget=nil;contentSelectionPreparing=false}
        return committed
    }
    @discardableResult private func mountContentOwner(_ target:Mode,session:ModeContentSession,coveredU:Double?=nil)->Bool {
        let began=CACurrentMediaTime();defer {recordContentWork("native.mount",began:began)}
        guard nativeHandoffAllowed() else {contentTrace?.record("ModeContentEndpointBlocked",detail:"complete frozen owner retained; endpoint retry armed");return false}
        let focusBefore=contentAdmissionResponder
        let u=coveredU ?? session.progress(at:contentNow)
        guard u<=0 || u>=1 else {return false}
        CATransaction.begin();CATransaction.setDisableActions(true)
        performingAdmission=true
        let success=workbench.transcriptSessions.withModeContentMountPermission {
            if contentDeferredSelection == nil,let selected=workbench.selectedConversation?.id,selected != session.selection {contentDeferredSelection=selected}
            if !session.selection.isEmpty {_=workbench.select(session.selection)}
            return target == .organic ? toOrganic(view.window,animated:false,reduce:false):toNormie(view.window,animated:false,reduce:false)
        }
        performingAdmission=false
        if success {
            contentMountCount+=1;admittedMode=target
            if target == .normie,contentInspectorWasOpen {split.splitViewItems.last?.isCollapsed=false}
            finalizeNativeOwner(target,window:view.window)
            organic.isHidden=false;organic.layer?.opacity=1
            restoreAdmissionResponder(focusBefore)
        }
        CATransaction.commit()
        if success {contentComposerInk.refresh();reconcileNativeRowFence()}
        return success
    }
    private func restoreDetachedContentSource(_ owner:Mode)->Bool {
        guard contentDetachedOwner != nil else {return true}
        performingAdmission=true;defer {performingAdmission=false}
        return workbench.transcriptSessions.withModeContentMountPermission {
            if owner == .normie {
                scene.suspendModePresentation()
                workbench.isNormie=true;workbench.sidebarVisible=true
                workbench.remountComposer();workbench.refresh()
                return true
            }
            return toOrganic(view.window,animated:false,reduce:false)
        }
    }
    private func finishAbandonedContentOpening(owner:Mode) {
        let began=CACurrentMediaTime();defer {recordContentWork("native.restore",began:began)}
        guard restoreDetachedContentSource(owner) else {failContentOpening(owner:owner);return}
        contentDetachedOwner=nil;contentOrganicReady=nil;normieNativeStaged=false;normieEndpointStaged=false
        contentOpening=false;pendingMode=nil;contentPicture.clear();contentSidebarCutout.clear();contentDockExposure.clear()
        scene.dockView.layer?.opacity=1
        for column in scene.columns {column.island?.layer?.opacity=1}
        // Both a completed transition and an abandoned cold capture enter the same paced catchup.
        workbench.detail.freezeModeLayout(false)
        if owner == .normie {workbench.detail.prepareModeContentCatchup()}
        releaseContentEpoch();scene.endModeHandoff();scene.dock.composerMotion.endModeHandoff();workbench.detail.endModeHandoff()
        finalizeNativeOwner(owner,window:view.window);admittedMode=owner
        if let selected=contentDeferredSelection {
            if selected != workbench.selectedConversation?.id {_=workbench.select(selected)}
            if owner == .organic,selected != scene.current {scene.show(selected);scene.remountComposers()}
            restoreSelectedContentFocus(selected,target:owner)
        }
        contentDeferredSelection=nil;clearContentFocus()
        flight.destinationDidMount()
    }
    private func failContentOpening(owner:Mode) {
        // A later IME/lease guard may refuse admission after the source detach phase. Its
        // complete picture remains in place until the original native owner is repaired.
        guard restoreDetachedContentSource(owner) else {
            contentTrace?.record("ModeContentRecoveryBlocked",detail:"source=\(owner.rawValue); complete picture retained")
            return
        }
        contentDetachedOwner=nil;contentOrganicReady=nil;contentEndpointMountPending=false
        normieNativeStaged=false;normieEndpointStaged=false
        contentOpening=false;pendingMode=nil;mode=owner;contentPicture.clear();contentDockExposure.clear();contentSidebarCutout.clear();releaseContentEpoch();clearContentFocus()
        flight.cancel();releaseFlightHidden();workbench.sidebar.setFlightSourcesHidden([],avatar:false)
        scene.endModeHandoff();scene.dock.composerMotion.endModeHandoff();workbench.detail.endModeHandoff()
        turnSidebar.moveNative(incoming:owner == .normie)
        finalizeNativeOwner(owner,window:view.window);admittedMode=owner
        onModeChange?(owner)
        contentTrace?.record("ModeContentAdmissionRejected",detail:"complete old owner retained")
    }
    private func cancelContentSession() {
        contentComposerInk.clear()
        contentSelectionPlan=nil;contentSelectionTarget=nil;contentSelectionPreparing=false
        contentEpochCompletionPending=false
        contentFocusRestoreGeneration &+= 1;contentDetachedOwner=nil;contentOrganicReady=nil;contentEndpointMountPending=false
        if ModeFlight.orreryEnabled,contentOpening {
            normieNativeStaged=false;normieEndpointStaged=false
            scene.dockView.layer?.opacity=1
            for column in scene.columns {column.island?.layer?.opacity=1}
        }
        contentSessionGeneration &+= 1;contentCaptureGeneration &+= 1;contentCaptureTask?.cancel();contentCaptureTask=nil
        contentSession=nil;contentOpening=false;contentCapturing=false;contentPicture.clear();contentDockExposure.clear();contentSidebarCutout.clear();releaseContentEpoch();clearContentFocus()
    }
}

#if M11_MODE_SELFTEST
extension WindowShell {
    func verificationPrepareContentPicture() {
        contentCaptureTask?.cancel();contentCaptureTask=nil;contentWarm=nil;contentWarmKey=nil
        captureContentPicture(cold:false) { [weak self] picture,key in self?.contentWarm=picture;self?.contentWarmKey=picture == nil ? nil:key}
    }
    var verificationContentCapturing:Bool {contentCapturing}
    var verificationContentSessionState:[String:Any] {
        guard let session=contentSession else {return ["active":false,"opening":contentOpening,"oldPicture":sourcePlate.picture != nil,"warm":contentWarm != nil]}
        let time=contentNow,u=session.progress(at:time)
        return ["active":true,"opening":contentOpening,"sessionID":session.id,"photoID":session.photoID,"photoMode":session.photoMode,"liveMode":session.liveMode,"requestedMode":session.requestedMode,"u":u,"a":ModeContentSession.alpha(u),"mounts":contentMountCount+Int(workbench.transcriptSessions.modeMountGeneration-contentInitialMountGeneration),"captures":contentSessionCaptureCount,"midPhaseMounts":contentMidPhaseMounts,"historyLayers":sourcePlate.verificationCompositionStats.groups,"organicOpacity":organic.layer?.opacity ?? -1,"photoLayers":contentPicture.imageLayer.sublayers?.count ?? 0,"revision":session.revision,"oldPicture":sourcePlate.picture != nil,"bytes":session.image.bytesPerRow*session.image.height]
    }
    var verificationContentCaptureCosts:[[String:Any]] {contentCaptureCosts}
    var verificationContentWorkCosts:[[String:Any]] {contentWorkCosts}
    var verificationContentFadeLatencies:[[String:Any]] {contentFadeLatencies}
    var verificationContentInvalidations:[String:Int] {contentInvalidations}
    func verificationInvalidateContent(_ reason:String) {invalidateContentPicture(reason:reason)}
    func verificationContentCommitRejected() {failContentOpening(owner:admittedMode)}
    func verificationFinishContentSession() {
        let previous=flight.manualTime,endpoint=contentNow+2
        flight.manualTime={endpoint}
        advanceContentSession(at:endpoint,flightFinished:true)
        // Keep the synthetic endpoint fixed while the production preparation tickets finish.
        // Restoring the clock after 3.5 frames used to abandon late selection below full cover.
        let deadline=Date(timeIntervalSinceNow:2)
        while contentSession != nil,Date()<deadline {
            RunLoop.main.run(until:Date(timeIntervalSinceNow:flight.presentationInterval))
            advanceContentSession(at:endpoint,flightFinished:true)
        }
        RunLoop.main.run(until:Date(timeIntervalSinceNow:flight.presentationInterval*3.5))
        flight.manualTime=previous
    }
    var verificationContentImage:CGImage? {contentSession?.image ?? contentWarm?.image}
}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
    var verificationContentPhase:CAKeyframeAnimation? {
        guard let session=contentSession else {return nil}
        return (session.photoMode == "normie" ? contentPicture.layer:normieBodyRoot.layer)?.animation(forKey:"mode.content.phase") as? CAKeyframeAnimation
    }
    var verificationContentLeaseGeneration:UInt64 {workbench.transcriptSessions.modeMountGeneration}
    func verificationWaitForWarmContent() {
        let until=Date(timeIntervalSinceNow:4)
        for _ in 0..<3 {
            if contentWarm != nil,contentWarmKey == flightPictureKey() {return}
            verificationPrepareContentPicture()
            while contentCapturing,Date()<until {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.001))}
        }
    }
}
#endif
#if M11_MODE_SELFTEST
extension WindowShell {
    var verificationRound14State:[String:Any] {
        ["sidebarWidth":verificationNativeSidebarHost?.bounds.width ?? 0,"sidebarContentWidth":workbench.sidebar.view.bounds.width,
         "epoch":contentEpochHeld,"blocked":modeContentInputBlocked,"captures":contentCaptureCosts.count,"quiet":contentStoreIsQuiet,
         "firstSubmitMS":contentFirstSubmitMS,"fence":flight.verificationOwnerFenceState,"bodyHidden":normieBodyRoot.isHidden]
    }
}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
    var verificationChromeTree:[[String:Any]] {
        guard let root=view.window?.contentView?.superview else {return []}
        func walk(_ v:NSView,_ depth:Int)->[[String:Any]] {[["class":String(describing:type(of:v)),"frame":NSStringFromRect(v.frame),"depth":depth,"layer":v.layer != nil]]+v.subviews.flatMap {walk($0,depth+1)}}
        return walk(root,0)
    }
}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
    var verificationToolbarExposed:Bool {
        guard let window=view.window,window.toolbar?.isVisible == true else {return false}
        if let surface=modeChromeSurfaces(in:window).first {return (surface.layer?.opacity ?? 1)>0.999}
        return mode == .normie
    }
    var verificationChromePhase:CAKeyframeAnimation? {contentChrome?.layer?.animation(forKey:"mode.content.phase") as? CAKeyframeAnimation}
}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
    var verificationComparisonState:[String:Any] {
        let photoAlpha:Double
        if let session=contentSession {photoAlpha=session.photoMode == "normie" ? ModeContentSession.alpha(session.progress(at:contentNow)):1}
        else {photoAlpha=0}
        let nAlpha=contentSession.map {$0.photoMode == "organic" ? ModeContentSession.alpha($0.progress(at:contentNow)):0} ?? (normieBodyRoot.isHidden ? 0:1)
        var glasses:[[String:Any]]=[]
        func walk(_ view:NSView) {
            if let glass=view as? NSGlassEffectView {glasses.append(["id":glass.identifier?.rawValue ?? "", "frame":NSStringFromRect(glass.convert(glass.bounds,to:self.view)),"style":glass.style.rawValue,"radius":glass.cornerRadius,"appearance":glass.effectiveAppearance.name.rawValue,"hasInk":glass.contentView?.layer?.sublayers?.contains {$0.contents != nil} ?? false])}
            view.subviews.forEach(walk)
        }
        walk(contentPicture)
        let inkPixels=contentPicture.subviews.flatMap { host -> [Int] in
            func images(_ view:NSView)->[CGImage] {(view.layer?.sublayers ?? []).compactMap {layer -> CGImage? in guard let contents=layer.contents,CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {return nil};return (contents as! CGImage)}+view.subviews.flatMap(images)}
            return images(host).map {image in
                var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
                bytes.withUnsafeMutableBytes {data in
                    let c=CGContext(data:data.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
                }
                return stride(from:3,to:bytes.count,by:4).reduce(0){$0+(bytes[$1]>2 ? 1:0)}
            }
        }
        return ["mode":mode.rawValue,"admitted":admittedMode.rawValue,"pending":pendingMode?.rawValue ?? "none","opening":contentOpening,
                "photo":contentPicture.imageLayer.contents != nil,"photoAlpha":photoAlpha,"inkPixels":inkPixels,"normieAlpha":nAlpha,"normieHidden":normieBodyRoots.allSatisfy {$0.isHidden},"organicHidden":organic.isHidden,
                "nativeOwner":nativeContentBelongs(to:admittedMode) && hasForegroundContentOwner(admittedMode),"toolbar":verificationToolbarExposed,"phase":verificationContentPhase != nil,
                "captures":contentCaptureCosts.count,"epoch":contentEpochHeld,"materials":glasses,"width":verificationNativeSidebarHost?.bounds.width ?? 0]
    }
    func verificationScheduleWarmCandidate() {scheduleContentPicture(reason:"comparison.quiet")}
    func verificationForgetContentCandidate() {
        contentCaptureGeneration &+= 1;contentCaptureTask?.cancel();contentCaptureTask=nil;contentCapturing=false
        contentWarm=nil;contentWarmKey=nil
        if contentSession == nil,!contentOpening {releaseContentEpoch()}
    }

    var verificationComparisonPhoto:ModeContentPictureView {contentPicture}
    var verificationComparisonMaterialImages:[CGImage] {
        func images(_ view:NSView)->[CGImage] {
            (view.layer?.sublayers ?? []).compactMap {layer -> CGImage? in guard let value=layer.contents,CFGetTypeID(value as CFTypeRef) == CGImage.typeID else {return nil};return (value as! CGImage)}+view.subviews.flatMap(images)
        }
        return contentPicture.subviews.flatMap(images)
    }

}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
    var verificationFadeClosureState:[String:Any] {
        let firstMaterial=workbench.detail.modeComposerMaterial
        let field=view.window?.firstResponder as? NSTextView
        let editorID=scene.store.conversations.compactMap {scene.composers.existingComposer(for:$0.id)}.first {field === $0.textView}?.identity ?? workbench.detail.composer.flatMap {field === $0.textView ? $0.identity:nil}
        return ["mode":mode.rawValue,"admitted":admittedMode.rawValue,"opening":contentOpening,"session":contentSession != nil,
                "epoch":contentEpochHeld,"pending":pendingMode?.rawValue ?? "none","gate":admission.waitingForFrame,
                "focusConversation":contentFocusConversation ?? "none","deferred":contentDeferredSelection ?? "none",
                "selected":workbench.selectedConversation?.id ?? "none","current":scene.current,"editor":editorID ?? "none",
                "materialAlpha":firstMaterial?.alphaValue ?? -1,"composerFlight":flight.composerMaterialIsVisible,
                "flight":flight.running,"normieAlpha":normieBodyRoot.layer?.opacity ?? -1]
    }
    func verificationFadeMember(_ id:String) {
        if let index=scene.order.firstIndex(of:id) {selectModeMember(at:index)}
    }
    var verificationFadeDockBars:[CALayer] {contentDockExposure.verificationBars}
}
#endif


#if M11_MODE_SELFTEST
extension WindowShell {
    func verificationWarmGeometryForClosure() {
        verificationSlicedPreparation=true;defer {verificationSlicedPreparation=false}
        prepareModeSwitch(reason:"closure.geometry")
        for _ in 0..<240 {if preparationBatch == nil {break};runPreparationSlice(schedule:false)}
        contentWarm=nil;contentWarmKey=nil
    }
    var verificationClosureTripEligible:Bool {preparedComposerTrip() != nil}
    var verificationClosureSidebarCutout:CALayer? {organic.layer?.mask}
}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
 var verificationCloseTwoOwners:[String:Bool] {Dictionary(uniqueKeysWithValues:(flight.activeTokens.map(\.id)+["me"]).map {($0,flightOwnerVisible($0))})}
}
#endif

#if M11_MODE_SELFTEST
extension WindowShell {
    func verificationCloseThreeRestoreFocus(_ id:String,target:Mode) {restoreSelectedContentFocus(id,target:target)}
}
#endif
