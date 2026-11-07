import AppKit
import QuartzCore

/// One native transcript and the SAME session composer used by Organic. No hosting views or duplicate editor.
@MainActor final class NormieDetailController: NSViewController {
    let store: ConversationStore, sessions: NativeComposerSessions, actions: NormieActions
    let transcriptSessions: NativeTranscriptSessions
    private let ownsTranscriptSessions: Bool
    var transcripts: [String: NativeTranscript] { transcriptSessions.transcripts }
    private var transcriptLeases: [String: NativeTranscriptSessions.Lease] = [:]
    private(set) var transcriptsPresented = true
    var canHandoffTranscripts: Bool { transcriptLeases.values.allSatisfy { $0.transcript?.canHandoff != false } }
    private(set) var composer: NativeComposer?
    private(set) var conversation: Conversation?
    private(set) var fullShowCount = 0
    private var hasShownConversation = false
    private struct DecisionValue: Equatable {
        var identity: ObjectIdentifier, title: String, project: String
        var offline:Bool, archived:Bool
        var approvals: [Approval], question: UserInputRequest?, legacyQuestion: String?
    }
    private var decisionValues: [DecisionValue] = []
    private(set) var draftToken: NativeComposerSessions.DraftToken?
    private(set) var context = NormieNewChatContext()
    let offlineBanner = NormieOfflineBanner(frame:.zero)
    let newChatView: NormieNewChatView
    let composerGlass = NormieComposerGlass(frame:CGRect(x:0,y:0,width:300,height:120))
    let composerContext = NormieDrawing.label(size: 11)
    let composerStatus=NormieDrawing.label(size:11)
    /// Source for the host's glass flight. NativeComposer remains a direct child for existing scene handoffs.
    var composerDockFrame: CGRect? { view.window == nil || composerGlass.isHidden ? nil:composerGlass.convert(composerGlass.bounds,to:nil) }
    var composerDockRect: CGRect { composerGlass.frame }
    func composerDockSnapshot(scale:CGFloat) -> CGImage? {
        guard !composerGlass.isHidden,let root=view as? NormieView else { return nil }
        root.layoutSubtreeIfNeeded()
        let image=NativeViewBitmap.capture(root,scale:scale)
        let sx=CGFloat(image.width)/root.bounds.width,sy=CGFloat(image.height)/root.bounds.height
        let r=composerGlass.frame
        return image.cropping(to:CGRect(x:r.minX*sx,y:r.minY*sy,width:r.width*sx,height:r.height*sy))
    }
    private let newChatScroll = NSScrollView()
    private let backgroundTranscriptHost=NormieView()
    private let approvalScroll = NSScrollView(), approvalDocument = NativeInteractionSurface(frame:.zero)
    private var backgroundCards: [String: NativeTranscriptCard] = [:]
    private var approvalSignature:[Approval]=[]
    private let toast = NormieView(), toastText = NormieDrawing.label(size: 11), undoButton = NormieButton()
    private var externalComposer = false
    private var previousHeightCallback: ((CGFloat) -> Void)?
    private var previousMotionCallback:(()->Void)?
    let terminalPane=NormieTerminalPane(frame:.zero)
    private(set) var isTerminalShown=false
    var onTerminalShownChange:((Bool)->Void)?
    private var terminalProgress=0.0,terminalMotion=NormieTerminalMotion(),terminalStart=0.0
    let motionClock=NormieMotionClock()
    var motionProcessingEnabled = ProcessInfo.processInfo.environment["M10_COMPOSER_SHARP"] != "1"
    private(set) var motionPreparationMS=0.0
    private(set) var composerGlassSample=ExposureSample.still
    private(set) var composerGlassNative=CGRect.zero,composerGlassEarlier=CGRect.zero
    private(set) var terminalFrameCount=0,terminalFullLayoutCount=0
    private var terminalAnimating=false
    private let terminalClip=NormieView()
    private struct MovingFrame { let view:NSView,from:CGRect,to:CGRect }
    private var terminalFrames:[MovingFrame]=[]
    private var terminalProxies:[(NSView,NormieMotionProxy)]=[]
    private struct ComposerMotionValue:Equatable{
        var text:String,scroll:CGPoint,state:NativeComposerState,files:[Attachment],settings:ModelSettings,workspace:NativeComposerWorkspace,access:Access,selection:NSRange,marked:NSRange,canSend:Bool,canStop:Bool,appearance:Int,display:Int
        func samePlates(as other:Self)->Bool{var value=self;value.text=other.text;value.selection=other.selection;value.marked=other.marked;return value==other}
    }
    private var composerMotionValue:ComposerMotionValue?
    private var terminalPixelsDirty=false,terminalRelayoutNeeded=false
    private(set) var motionRecaptureMS:[Double]=[]
    private struct WarmKey:Equatable{var id:ObjectIdentifier,size:CGSize,scale:CGFloat,composer:ComposerMotionValue?,terminal:String,appearance:Int,display:Int}
    private var editorLastOrigin=CGPoint.zero
    private var terminalPictureKeys:[ObjectIdentifier:WarmKey]=[:]
    private var warmPictures:[ObjectIdentifier:(WarmKey,NormieMotionPicture)]=[:]
    private var warmTask:DispatchWorkItem?
    private var idleCapture:NormieIdleMotionCapture?
    private var idleCaptureKey:WarmKey?
    private var modePresentationActive=true
    private var lastMotionModelChange = -Double.infinity
    private var motionInputMonitor:Any?
    private var lastMotionInput = -Double.infinity
    private(set) var idleMotionSliceMS:[Double]=[]
    private(set) var idleMotionDiscarded=0
    private func cancelIdleMotionCapture() {warmTask?.cancel();warmTask=nil;idleCapture=nil;idleCaptureKey=nil}
    func setModePresentationActive(_ active:Bool) {
        modePresentationActive=active
        if active {scheduleMotionPrewarm()} else {cancelIdleMotionCapture()}
    }
    /// A stream packet invalidates pixels without starting invisible drawing or a polling loop.
    func invalidateIdleMotionPictures() {
        lastMotionModelChange=CACurrentMediaTime()
        cancelIdleMotionCapture();warmPictures.removeAll(keepingCapacity:true)
        if !store.conversations.contains(where:{$0.running || $0.sending || $0.loading}) {scheduleMotionPrewarm()}
    }
    private var allowsModernIdleMotion:Bool {
        !NormieIdleMotionCapture.orreryEnabled || (modePresentationActive && !store.conversations.contains {$0.running || $0.sending || $0.loading})
    }

    private(set) var motionWarmupMS=0.0
    private var terminalSafeRect=CGRect.zero
    private var itemMotions:[NormieDetailItemMotion]=[]
    private var approvalRest:[ObjectIdentifier:(NSView,CGRect,NormieMotionPicture)]=[:]
    private var presentedApprovalIDs:[String]=[]
    private var toastMotion:NormieDetailItemMotion?
    private var toastRevision=0
    var activeMotionProxies:[NormieMotionProxy] { terminalProxies.map(\.1)+itemMotions.map(\.proxy)+(toastMotion.map{[$0.proxy]} ?? []) }
    private var layingOut = false
    private var modeLayoutFrozen = false
    private var modeHandoffInProgress=false
    private var approvalRestAfterMode=false
    /// Layout still completes, but unrelated detail motion capture cannot run inside an outer mode flight.
    func beginModeHandoff() {modeHandoffInProgress=true;cancelIdleMotionCapture();settleMotions()}
    func hideNonSelectedModeTranscripts() {
        for transcript in transcriptSessions.transcripts.values where transcript.isDescendant(of:view) && transcript.conversation !== conversation {transcript.isHidden=true}
        backgroundTranscriptHost.isHidden=true
    }
    var modeComposerMaterial:NSGlassEffectView? {isViewLoaded && !composerGlass.isHidden ? composerGlass:nil}
    /// Which of the rail's cards go to a column at the next switch to Organic (`NativeTranscriptCard.leavesNormieForColumn`).
    /// The marked cards that show now, which are about to go.
    var cardsLeavingForColumns:[NativeTranscriptCard] {backgroundCards.values.filter{$0.leavesNormieForColumn && !$0.isHiddenOrHasHiddenAncestor}}
    func markApprovalCards(movingToColumns ids:Set<String>) {
        for (key,card) in backgroundCards {card.leavesNormieForColumn=key.lastIndex(of:":").map{ids.contains(String(key[..<$0]))} ?? false}
    }
    func setModeComposerMaterialInFlight(_ active:Bool) {
        let alpha:CGFloat=active ? 0:1
        if composerGlass.alphaValue != alpha {composerGlass.alphaValue=alpha}
    }
    func prepareModeContentCatchup() {
        endModeHandoff()
        if isViewLoaded {view.layoutSubtreeIfNeeded()}
        approvalRestAfterMode=false
    }
    func endModeHandoff() {
        approvalRestAfterMode=true;lastMotionInput=CACurrentMediaTime();modeHandoffInProgress=false
        if isViewLoaded, !NormieIdleMotionCapture.orreryEnabled || modePresentationActive {view.needsLayout=true;scheduleMotionPrewarm()}
    }

    private var modePreparationSafeRect: CGRect?
    private struct ComposerEndpointKey:Equatable {
        let identity:ObjectIdentifier,width:CGFloat,height:CGFloat,minimum:CGFloat,natural:CGFloat
        let value:ComposerMotionValue?
    }
    private var composerEndpointKey:ComposerEndpointKey?
    private var composerEndpointHeight:CGFloat=120
    private struct ApprovalLayoutKey:Equatable {
        let width:CGFloat,scale:CGFloat,selected:String?,values:[DecisionValue],appearance:Int,display:Int
    }
    private var approvalLayoutKey:ApprovalLayoutKey?
    private var approvalLayoutOrder:[NSView]=[]
    /// The endpoint is laid out once; AppKit may move/clip it while its sidebar slides.
    func freezeModeLayout(_ frozen: Bool) {
        modeLayoutFrozen = frozen
        if !frozen,isViewLoaded,!NormieIdleMotionCapture.orreryEnabled || modePresentationActive {view.needsLayout=true}
    }
    /// Loads and lays out chrome only. The source keeps every real transcript/editor lease and callback.
    func prewarmModeChrome(size: CGSize, safeRect: CGRect) {
        guard externalComposer, !transcriptsPresented else { return }
        ModeSignposts.measure("PrewarmNormieDetail") {
            loadViewIfNeeded(); modePreparationSafeRect = safeRect; view.setFrameSize(size)
            layoutContent()
        }
    }
    func endModePreparation() { modePreparationSafeRect = nil }
    isolated deinit{motionClock.stop();warmTask?.cancel();if let motionInputMonitor{NSEvent.removeMonitor(motionInputMonitor)}}
    func setTerminalController(_ controller:CoreTerminalController?){terminalPane.setController(controller)}
    func setTerminalShown(_ shown:Bool,animated:Bool=true,rebase:Bool=false){
        guard shown != isTerminalShown || rebase else{return}
        let now=motionClock.now,elapsed=now-terminalStart
        if terminalAnimating { advanceTerminal(at:now,profile:motionClock.profile) }
        let velocity=terminalAnimating && terminalProgress>0 && terminalProgress<1 ? terminalMotion.speed(at:elapsed):0
        terminalAnimating=false
        terminalProxies.forEach{$0.1.retire()};terminalProxies=[];terminalPictureKeys=[:]
        let changed=shown != isTerminalShown
        isTerminalShown=shown;terminalPane.presentationActive=shown && conversation != nil
        if !shown,let responder=view.window?.firstResponder as? NSView,responder.isDescendant(of:terminalPane),!externalComposer{composer?.focus()}
        if changed{onTerminalShownChange?(shown)}
        guard animated,(view.window?.isVisible == true || motionClock.manualTime != nil),!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else{terminalAnimating=false;terminalPane.watchMotionOutput(false);terminalProgress=shown ? 1:0;view.needsLayout=true;view.layoutSubtreeIfNeeded();return}
        let preparing=CACurrentMediaTime(),start=min(1,max(0,terminalProgress))
        view.layoutSubtreeIfNeeded()
        let tracked=view.subviews.filter{$0 !== terminalClip && $0 !== composer?.focusRing}+(composer.map{[$0.focusRing]} ?? [])
        let target=terminalTargetFrames(shown:shown)
        terminalFrames=tracked.map{MovingFrame(view:$0,from:$0.frame,to:target[ObjectIdentifier($0)] ?? $0.frame)}
        composer?.motionLayoutContinuous=true
        let clipFrame=terminalClip.frame,clipHidden=terminalClip.isHidden,paneHidden=terminalPane.isHidden,paneAlpha=terminalPane.alphaValue
        terminalClip.isHidden=false;terminalClip.frame.size.height=NormieTerminalMotion.height(available:(view as! NormieView).contentSafeRect.height)
        terminalPane.isHidden=false;terminalPane.alphaValue=1;terminalPane.layoutSubtreeIfNeeded()
        for source in terminalPictureSources where !source.isHidden {
            let key=pictureKey(source)
            let picture=warmPictures[ObjectIdentifier(source)].flatMap{$0.0 == key ? $0.1:nil} ?? captureMotionPicture(source,scale:key.scale)
            if let picture {
                let proxy=NormieMotionProxy(source:source,picture:picture,in:view)
                if source === composer?.scrollView{proxy.fixedInkSize=true;proxy.clippingView=source}
                if source is NativeTranscriptCard{proxy.clippingView=approvalScroll}
                terminalProxies.append((source,proxy));terminalPictureKeys[ObjectIdentifier(source)]=key
            }
        }
        terminalClip.frame=clipFrame;terminalClip.isHidden=clipHidden;terminalPane.isHidden=paneHidden;terminalPane.alphaValue=paneAlpha
        terminalProgress=start;terminalMotion = .init(start:start,target:shown ? 1:0,velocity:velocity)
        editorLastOrigin=composer?.scrollView.contentView.bounds.origin ?? .zero
        composerMotionValue=currentComposerMotionValue();terminalPane.watchMotionOutput(true);terminalPixelsDirty=false
        // Preparation is measured separately, never counted as a presented frame or hidden by jumping ahead.
        terminalStart=motionClock.now;terminalSafeRect=(view as! NormieView).contentSafeRect;terminalAnimating=true
        motionPreparationMS=(CACurrentMediaTime()-preparing)*1000
        applyTerminalFrames(at:terminalStart,profile:motionClock.profile)
        motionClock.start()
    }
    /// Each native child keeps its own unscaled glyph plane. The editor is never replaced or hidden as an NSView.
    private var terminalPictureSources:[NSView]{
        [terminalPane as NSView]+(composer?.subviews.filter{!$0.isHidden && !($0 is NSProgressIndicator) && !($0 is NativeComposerVoiceWaveform)} ?? [])+Array(backgroundCards.values).filter{card in !itemMotions.contains{$0.proxy.nativeSource === card}}+(!toast.isHidden && toastMotion == nil ? [toast]:[])
    }
    private func terminalTargetFrames(shown:Bool)->[ObjectIdentifier:CGRect]{
        guard let root=view as? NormieView else{return [:]};let safe=root.contentSafeRect,w=safe.width
        let h=safe.height-(shown ? NormieTerminalMotion.height(available:safe.height):0)
        let owns=composer != nil && !externalComposer && composer?.superview === view
        let ch=owns ? composer!.normieLayoutHeight(detailHeight:h):max(120,composer?.measuredHeight ?? 120)
        let top:CGFloat=offlineBanner.isHidden ? 0:78,base:CGFloat=externalComposer ? 14:ch+26
        let ah=approvalScroll.isHidden ? 0:min(approvalDocument.frame.height,min(max(0,h-top-base-64),min(300,max(80,h*0.5))))
        let bottom=base+ah
        func grid(_ r:CGRect)->CGRect{NormieDrawing.rect(r,scale:root.scale)}
        var frames:[ObjectIdentifier:CGRect]=[:]
        func put(_ v:NSView,_ r:CGRect){frames[ObjectIdentifier(v)]=grid(r)}
        if let c=conversation,let transcript=transcripts[c.id],transcript.superview === view{put(transcript,CGRect(x:safe.minX,y:safe.minY+top-10,width:w,height:max(1,h-top-bottom+10)))}
        put(newChatScroll,CGRect(x:safe.minX,y:safe.minY,width:w,height:max(1,h-bottom)))
        put(approvalScroll,CGRect(x:safe.minX,y:safe.minY+max(top,h-bottom),width:w,height:ah))
        if let composer,owns{let cw=max(1,min(768,w-28)),r=grid(CGRect(x:safe.minX+(w-cw)/2,y:safe.minY+h-ch-14,width:cw,height:ch));put(composer,r);put(composerGlass,r);put(composer.focusRing,r.insetBy(dx:-1,dy:-1))}
        put(toast,CGRect(x:safe.minX+max(14,(w-min(520,w-28))/2),y:safe.minY+max(top+4,h-bottom-44),width:max(1,min(520,w-28)),height:36))
        return frames
    }
    private func advanceTerminal(at time:Double,profile:DisplayProfile){
        guard terminalAnimating else{return};terminalProgress=terminalMotion.value(at:time-terminalStart)
        applyTerminalFrames(at:time,profile:profile);terminalFrameCount+=1
        if time-terminalStart>=terminalMotion.duration {
            terminalAnimating=false;terminalProgress=isTerminalShown ? 1:0
            terminalProxies.forEach{$0.1.retire()};terminalProxies=[];terminalFrames=[]
            terminalPane.watchMotionOutput(false);composer?.motionLayoutContinuous=false
            view.needsLayout=true // One final native admission, not a full root layout every display callback.
        }
    }
    private func applyTerminalFrames(at time:Double,profile:DisplayProfile){
        guard let root=view as? NormieView else{return}
        // Keep the product's nonnegative, capped 220pt allocation. Sampling the spring beyond that allocation made
        // a new one-pixel overshoot/return on a 60Hz 1x display; the original viewDidLayout already clamps it.
        let p=min(1,max(0,terminalMotion.value(at:time-terminalStart))),q=min(1,max(0,terminalMotion.value(at:time-terminalStart-profile.frameInterval)))
        let delta=terminalMotion.target-terminalMotion.start
        func fraction(_ value:Double)->CGFloat{abs(delta)>1e-9 ? CGFloat((value-terminalMotion.start)/delta):1}
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        // Continuous real frames while moving, just like the product's frame animation. Rounding every sample to
        // a backing pixel holds one pose for several frames then jumps 1px at the tail. Endpoints are already on
        // the backing grid; the final native layout uses root.place again. No curve/tail is shortened.
        for pair in terminalFrames { pair.view.frame=NormieDetailItemMotion.mix(pair.from,pair.to,fraction(p)) }
        composer?.layoutSubtreeIfNeeded()
        let safe=root.contentSafeRect,full=NormieTerminalMotion.height(available:safe.height),height=full*CGFloat(min(1,max(0,p)))
        terminalClip.frame=CGRect(x:safe.minX,y:safe.maxY-height,width:safe.width,height:height);terminalClip.isHidden=height<0.01
        terminalClip.place(terminalPane,CGRect(x:0,y:0,width:safe.width,height:full));terminalPane.isHidden=false;terminalPane.alphaValue=CGFloat(min(1,max(0,p)))
        var earlier:[ObjectIdentifier:CGRect]=[:]
        var ideal:[ObjectIdentifier:CGRect]=[:]
        for pair in terminalFrames { earlier[ObjectIdentifier(pair.view)]=NormieDetailItemMotion.mix(pair.from,pair.to,fraction(q)) }
        for pair in terminalFrames { ideal[ObjectIdentifier(pair.view)]=NormieDetailItemMotion.mix(pair.from,pair.to,fraction(p)) }
        for (source,proxy) in terminalProxies {
            let actual=source.convert(source.bounds,to:root)
            var old=actual
            if source === terminalPane{old=actual.offsetBy(dx:0,dy:full*CGFloat(p-q))}
            else if let composer,source.isDescendant(of:composer){
                let n=composer.frame,o=earlier[ObjectIdentifier(composer)] ?? n
                // Context and editor are top anchored; the controls are bottom anchored. No font is scaled.
                let bottom=source.frame.minY>=composer.bounds.height-41
                old=actual.offsetBy(dx:o.minX-n.minX,dy:(bottom ? o.maxY-n.maxY:o.minY-n.minY))
            }else if source is NativeTranscriptCard{
                let n=approvalScroll.frame,o=earlier[ObjectIdentifier(approvalScroll)] ?? n
                old=actual.offsetBy(dx:o.minX-n.minX,dy:o.minY-n.minY)
            }else{old=earlier[ObjectIdentifier(source)] ?? actual}
            proxy.settings.enabled=motionProcessingEnabled
            // A changing editor viewport clips a constant-size native glyph plane, not a stretched screenshot.
            var now=proxy.fixedInkSize ? CGRect(origin:actual.origin,size:proxy.picture.size):actual
            if proxy.fixedInkSize,let origin=proxy.picture.editorOrigin,let composer{
                let scroll=composer.scrollView.contentView.bounds.origin
                now.origin.x-=scroll.x-origin.x;now.origin.y-=scroll.y-origin.y
                old.origin.x-=editorLastOrigin.x-origin.x;old.origin.y-=editorLastOrigin.y-origin.y
                old.size=proxy.picture.size
            }
            proxy.update(now:now,earlier:old,profile:profile,opacity:source === terminalPane ? CGFloat(min(1,max(0,p))):1)
        }
        editorLastOrigin=composer?.scrollView.contentView.bounds.origin ?? .zero
        if let composer { // Real glass geometry only: never inside the replicator, never a transform scale.
            let now=composer.frame,old=earlier[ObjectIdentifier(composer)] ?? now
            composerGlassNative=now;composerGlassEarlier=old
            composerGlassSample=ExposureSample(now:now,earlier:old,frameInterval:profile.frameInterval,mmPerPoint:profile.mmPerPoint,settings:ExposureSettings(enabled:motionProcessingEnabled))
            composerGlass.frame=NormieSolidMotion.rect(now:now,earlier:old,profile:profile,settings:ExposureSettings(enabled:motionProcessingEnabled))
            composerGlass.contentView?.frame=composerGlass.bounds;root.offscreenGlassRect=composerGlass.frame
        }
    }
    private func advanceMotions(at time:Double,profile:DisplayProfile)->Bool {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion{settleMotions();return false}
        if terminalAnimating,Set(terminalPictureSources.map(ObjectIdentifier.init)) != Set(terminalProxies.map{ObjectIdentifier($0.0)}){terminalRelayoutNeeded=true}
        if terminalAnimating,terminalRelayoutNeeded{terminalRelayoutNeeded=false;setTerminalShown(isTerminalShown,rebase:true)}
        if terminalAnimating{
            let value=currentComposerMotionValue()
            for (source,proxy) in terminalProxies{
                var key=pictureKey(source,composerValue:value);let id=ObjectIdentifier(source)
                if proxy.fixedInkSize,let origin=proxy.picture.editorOrigin,let scroll=composer?.scrollView.contentView.bounds.origin,
                   scroll.y>=origin.y,scroll.y+source.bounds.height<=origin.y+proxy.picture.size.height{
                    key.composer?.scroll=terminalPictureKeys[id]?.composer?.scroll ?? scroll
                }
                guard motionProcessingEnabled,key != terminalPictureKeys[id] || (source === terminalPane && terminalPixelsDirty) else{continue}
                terminalPictureKeys[id]=key
                let start=CACurrentMediaTime()
                let reuse=source === terminalPane || (value != nil && composerMotionValue?.samePlates(as:value!) == true)
                if let picture=captureMotionPicture(source,scale:(view as? NormieView)?.scale ?? 2,reusing:reuse ? proxy.picture:nil){proxy.replaceContent(picture)}
                motionRecaptureMS.append((CACurrentMediaTime()-start)*1000)
            }
            composerMotionValue=value;terminalPixelsDirty=false
        }
        advanceTerminal(at:time,profile:profile)
        itemMotions.removeAll{if $0.advance(time,profile:profile,enabled:motionProcessingEnabled){return false};$0.proxy.retire();return true}
        if let toastMotion,!toastMotion.advance(time,profile:profile,enabled:motionProcessingEnabled){toastMotion.proxy.retire();self.toastMotion=nil}
        return terminalAnimating || !itemMotions.isEmpty || toastMotion != nil
    }
    private func settleMotions(){
        cancelIdleMotionCapture();warmPictures=[:]
        motionClock.stop();terminalAnimating=false;terminalProgress=isTerminalShown ? 1:0;composer?.motionLayoutContinuous=false
        terminalProxies.forEach{$0.1.retire()};terminalProxies=[];terminalFrames=[]
        itemMotions.forEach{$0.proxy.retire()};itemMotions=[];toastMotion?.proxy.retire();toastMotion=nil
        terminalPane.watchMotionOutput(false)
        if isViewLoaded,!NormieIdleMotionCapture.orreryEnabled || modePresentationActive {view.needsLayout=true}
    }
    func disposeTerminal(){settleMotions();terminalPane.dispose()}
    private func currentComposerMotionValue()->ComposerMotionValue?{guard let c=composer else{return nil};return .init(text:c.text,scroll:c.scrollView.contentView.bounds.origin,state:c.state,files:c.attachments,settings:c.settings,workspace:c.workspace,access:c.access,selection:c.textView.selectedRange(),marked:c.textView.markedRange(),canSend:c.canSend,canStop:c.canStop,appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision)}
    private func captureMotionPicture(_ source:NSView,scale:CGFloat,reusing:NormieMotionPicture?=nil)->NormieMotionPicture?{
        if let composer,source === composer.scrollView{return NormieMotionPicture.editor(composer,scale:scale)}
        return NormieMotionPicture.capture(source,scale:scale,reusing:reusing)
    }
    private func pictureKey(_ source:NSView,composerValue:ComposerMotionValue?=nil)->WarmKey{
        var value:ComposerMotionValue?,size=source.bounds.size
        if let composer,source.isDescendant(of:composer){
            value=composerValue ?? currentComposerMotionValue()
            if source === composer.scrollView{size.height=max(280,size.height)}else{value?.text="";value?.scroll = .zero;value?.selection=NSRange(location:0,length:0);value?.marked=NSRange(location:0,length:0)}
        }
        return .init(id:ObjectIdentifier(source),size:size,scale:(view as? NormieView)?.scale ?? 2,composer:value,terminal:source === terminalPane ? terminalPane.motionContentKey:"",appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision)
    }
    /// Idle prewarming is separate from the callback budget. It never runs while hidden, during a transition or an IME.
    func prepareMotionPictures(){
        guard !modeHandoffInProgress,isViewLoaded,!terminalAnimating,composer?.isComposing != true else{return}
        let start=CACurrentMediaTime(),clipHidden=terminalClip.isHidden,paneHidden=terminalPane.isHidden,clipFrame=terminalClip.frame,paneAlpha=terminalPane.alphaValue
        CATransaction.begin();CATransaction.setDisableActions(true)
        terminalClip.isHidden=false;terminalClip.frame.size.height=terminalPane.bounds.height;terminalPane.isHidden=false;terminalPane.alphaValue=1;terminalPane.layoutSubtreeIfNeeded()
        for source in terminalPictureSources where !source.isHidden{
            let key=pictureKey(source),id=ObjectIdentifier(source)
            if warmPictures[id]?.0 != key,let picture=captureMotionPicture(source,scale:key.scale){warmPictures[id]=(key,picture)}
        }
        terminalClip.frame=clipFrame;terminalClip.isHidden=clipHidden;terminalPane.isHidden=paneHidden;terminalPane.alphaValue=paneAlpha;CATransaction.commit()
        motionWarmupMS=(CACurrentMediaTime()-start)*1000
    }
    private var canRunIdleMotionSlice:Bool {
        allowsModernIdleMotion && !modeHandoffInProgress && isViewLoaded && view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor &&
        transcriptsPresented && !terminalAnimating && !motionClock.running && composer?.isComposing != true &&
        NSEvent.pressedMouseButtons == 0 && CACurrentMediaTime()-lastMotionInput >= 0.35 &&
        (!NormieIdleMotionCapture.orreryEnabled || CACurrentMediaTime()-lastMotionModelChange>=0.5)
    }
    private func scheduleMotionPrewarm(){
        guard allowsModernIdleMotion else {return}
        guard !modeHandoffInProgress,isViewLoaded,view.window != nil,!view.isHiddenOrHasHiddenAncestor,transcriptsPresented else{return}
        guard warmTask == nil else{return}
        let task=DispatchWorkItem{[weak self] in self?.runIdleMotionSlice()};warmTask=task
        let delay=NormieIdleMotionCapture.orreryEnabled ? max(0.016,lastMotionInput+0.35-CACurrentMediaTime(),lastMotionModelChange+0.5-CACurrentMediaTime()):0.016
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:task)
    }
    private func runIdleMotionSlice(){
        warmTask=nil
        guard canRunIdleMotionSlice else {
            if !NormieIdleMotionCapture.orreryEnabled {scheduleMotionPrewarm()}
            else if allowsModernIdleMotion,CACurrentMediaTime()<max(lastMotionInput+0.35,lastMotionModelChange+0.5) {scheduleMotionPrewarm()}
            return
        }
        let start=CACurrentMediaTime()
        defer{
            idleMotionSliceMS.append((CACurrentMediaTime()-start)*1000)
            if idleMotionSliceMS.count>512 {idleMotionSliceMS.removeFirst(idleMotionSliceMS.count-512)}
        }
        ModeSignposts.operation("NormieMotionIdleTurn",detail:"includes allocation, drawing and bookkeeping") {runIdleMotionWork()}
    }
    private func runIdleMotionWork(){
        let sources=terminalPictureSources.filter{NormieIdleMotionCapture.supports($0)}
        if let capture=idleCapture,let key=idleCaptureKey {
            guard sources.contains(where:{$0 === (idleCaptureOwner ?? capture.source)}),pictureKey(idleCaptureOwner ?? capture.source) == key else{
                idleMotionDiscarded+=1;idleCapture=nil;idleCaptureKey=nil;scheduleMotionPrewarm();return
            }
            if let picture=capture.result {
                let owner=idleCaptureOwner ?? capture.source
                warmPictures[ObjectIdentifier(owner)]=(key,picture)
                if let card=owner as? NativeTranscriptCard,card.superview === approvalDocument {
                    approvalRest[ObjectIdentifier(card)]=(card,card.convert(card.bounds,to:view),picture)
                }
                idleCapture=nil;idleCaptureKey=nil
            }
        }
        if idleCapture == nil {
            guard let source=sources.first(where:{warmPictures[ObjectIdentifier($0)]?.0 != pictureKey($0)}) else{return}
            idleCaptureKey=pictureKey(source)
            let editor=source === composer?.scrollView ? composer:nil
            idleCapture=ModeSignposts.measure("NormieMotionPrewarmAllocate") {NormieIdleMotionCapture(editor?.textView ?? source,scale:idleCaptureKey!.scale,composer:editor)}
            // The key belongs to the scroll view, while its bounded text document is the actual capture source.
            if editor != nil {idleCaptureOwner=source}
            else {idleCaptureOwner=nil}
            guard idleCapture != nil else{return}
        }
        guard let capture=idleCapture else{return}
        let clipHidden=terminalClip.isHidden,paneHidden=terminalPane.isHidden,clipFrame=terminalClip.frame,paneAlpha=terminalPane.alphaValue
        CATransaction.begin();CATransaction.setDisableActions(true)
        if capture.source === terminalPane {
            terminalClip.isHidden=false;terminalClip.frame.size.height=terminalPane.bounds.height
            terminalPane.isHidden=false;terminalPane.alphaValue=1
        }
        capture.step()
        terminalClip.frame=clipFrame;terminalClip.isHidden=clipHidden;terminalPane.isHidden=paneHidden;terminalPane.alphaValue=paneAlpha
        CATransaction.commit()
        scheduleMotionPrewarm()
    }
    #if M11_MODE_SELFTEST
    var verificationIdleMotionSources:[NSView] {terminalPictureSources}
    func verificationMotionCapture(_ source:NSView,scale:CGFloat)->NormieMotionPicture? {
        verificationExposeMotionSource(source) {captureMotionPicture(source,scale:scale)}
    }
    func verificationExposeMotionSource<T>(_ source:NSView,_ body:()->T)->T {
        let h=terminalClip.isHidden,p=terminalPane.isHidden,f=terminalClip.frame,a=terminalPane.alphaValue
        CATransaction.begin();CATransaction.setDisableActions(true)
        if source === terminalPane {terminalClip.isHidden=false;terminalClip.frame.size.height=terminalPane.bounds.height;terminalPane.isHidden=false;terminalPane.alphaValue=1;terminalPane.layoutSubtreeIfNeeded()}
        defer{terminalClip.frame=f;terminalClip.isHidden=h;terminalPane.isHidden=p;terminalPane.alphaValue=a;CATransaction.commit()}
        return body()
    }
    #endif
    private weak var idleCaptureOwner:NSView?
    func disposeTranscripts() {
        for lease in transcriptLeases.values { transcriptSessions.unmount(lease) }
        transcriptLeases = [:]; backgroundCards = [:]
        if ownsTranscriptSessions { transcriptSessions.dispose() }
    }
    /// false freezes source pixels for a flight; the next admitted host claims the same views through the owner.
    /// Background show/layout/store callbacks cannot reclaim them. true is the explicit return-to-Normie admission.
    func setTranscriptPresentationActive(_ active: Bool) {
        if !active{settleMotions()}
        transcriptsPresented = active
        for lease in transcriptLeases.values { _ = lease.setActive(active) }
        approvalDocument.presentationActive = active
        if active { transcriptLeases = transcriptLeases.filter { $0.value.isCurrent } }
        if active, isViewLoaded {
            if let c = conversation { show(c) } else { showDraft(context) }
            view.needsLayout = true
        }
    }
    func prepareTranscriptSnapshots() {
        for lease in transcriptLeases.values where lease.transcript?.isHidden == false { lease.transcript?.prepareForSnapshot() }
    }
    var onConfigureComposer: ((NativeComposer, Conversation?, NativeComposerSessions.DraftToken?) -> Void)?
    var onComposerPresentationChange:((NativeComposer?,NSView?)->Void)?
    private weak var publishedComposer:NativeComposer?
    func republishComposerPresentation(){if isViewLoaded,!externalComposer,let composer,composer.superview === view{publishedComposer=composer;onComposerPresentationChange?(composer,view)}}
    var onContextChange: ((NormieNewChatContext) -> Void)?
    var onReview: (() -> Void)?
    var onUndo: (() -> Void)?
    var onSelectConversation: ((String) -> Void)?

    init(store: ConversationStore, sessions: NativeComposerSessions, actions: NormieActions, transcriptSessions: NativeTranscriptSessions? = nil) {
        self.store = store; self.sessions = sessions; self.actions = actions
        self.transcriptSessions = transcriptSessions ?? NativeTranscriptSessions(store: store)
        ownsTranscriptSessions = transcriptSessions == nil
        newChatView = NormieNewChatView(store: store, actions: actions)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        motionInputMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown,.leftMouseDragged,.rightMouseDragged,.scrollWheel,.magnify,.rotate,.swipe]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self {self.lastMotionInput=CACurrentMediaTime();self.cancelIdleMotionCapture();self.scheduleMotionPrewarm()}
            }
            return event
        }
        let root = NormieMotionHost(); root.fill = NormieDrawing.background;root.canopy=true;view = root
        motionClock.onSuspend={[weak self] in self?.settleMotions()}
        motionClock.attach(root)
        motionClock.frame = { [weak self] time,profile in self?.advanceMotions(at:time,profile:profile) ?? false }
        root.onWindowChange = { [weak self,weak root] in guard let self,let root else{return};if root.window == nil{self.settleMotions()}else{self.motionClock.attach(root);self.scheduleMotionPrewarm()} }
        root.onHidden = { [weak self] in self?.settleMotions() }
        root.onDisplayOptionsChange={[weak self] in self?.updateDisplayOptions()}
        root.onAppearanceChange={[weak self] in self?.updateDisplayOptions();self?.updateGlassAppearance()}
        offlineBanner.isHidden = true
        newChatScroll.contentView = NormieClipView(); newChatScroll.drawsBackground = false
        newChatScroll.hasVerticalScroller = true; newChatScroll.autohidesScrollers = true; newChatScroll.documentView = newChatView
        approvalScroll.contentView = NormieClipView(); approvalScroll.drawsBackground = false
        approvalScroll.hasVerticalScroller = true; approvalScroll.autohidesScrollers = true; approvalScroll.documentView = approvalDocument
        updateGlassAppearance(); composerGlass.cornerRadius = 20
        composerGlass.contentView = NormieView(); composerGlass.setAccessibilityElement(false)
        composerGlass.isHidden = true; composerContext.textColor = NativePalette.secondaryLabel
        composerContext.setAccessibilityLabel("Conversation context")
        root.addSubview(composerGlass); root.addSubview(composerContext);root.addSubview(composerStatus);composerStatus.textColor = NativePalette.secondaryLabel;composerStatus.alignment = .right
        root.addSubview(newChatScroll); root.addSubview(approvalScroll); root.addSubview(offlineBanner); root.addSubview(toast)
        terminalClip.wantsLayer=true;terminalClip.layer?.masksToBounds=true;root.addSubview(terminalClip);terminalClip.addSubview(terminalPane);terminalPane.isHidden=true
        terminalPane.onClose={[weak self] in self?.setTerminalShown(false)}
        terminalPane.onMotionContentChange={[weak self] in
            guard let self else {return};self.terminalPixelsDirty=true
            NotificationCenter.default.post(name:Notification.Name("Organic.ModePreparationInputsChanged"),object:self.view)
        }
        toast.wantsLayer = true; toast.layer?.cornerRadius = 10; toast.layer?.backgroundColor = NativeDisplayOptions.plate(alpha:0.09).cgColor
        toast.addSubview(toastText); toast.addSubview(undoButton); toast.isHidden = true
        undoButton.title = "Undo"; undoButton.run = { [weak self] in self?.onUndo?() }; undoButton.setAccessibilityLabel("Undo archive")
        root.setAccessibilityRole(.group); root.setAccessibilityLabel("Conversation detail")
        newChatView.onChange = { [weak self] value in
            self?.context = value; self?.updateDraftAvailability(); self?.onContextChange?(value)
        }
    }
    private func updateDisplayOptions(){toast.layer?.backgroundColor=NativeDisplayOptions.plate(alpha:0.09).cgColor;view.needsDisplay=true;terminalPixelsDirty=true;scheduleMotionPrewarm()}
    private func updateGlassAppearance(){let look=NativeAppearance.current;composerGlass.style=look.clearGlass ? .clear:.regular;composerGlass.tintColor=look.background?.withAlphaComponent(look.clearGlass ? 0.2:0.55);view.needsLayout=true}
    func show(_ c: Conversation?) {
        _ = view
        let changed = !hasShownConversation || conversation !== c || draftToken != nil
        if changed,terminalAnimating{settleMotions()}
        hasShownConversation = true
        conversation = c; draftToken = nil
        if changed {
            fullShowCount += 1
            terminalPane.configure(c,store:store); terminalPane.presentationActive=isTerminalShown && c != nil
            if newChatView.isDraft { newChatView.isDraft=false }
            newChatView.isHidden = c != nil; newChatScroll.isHidden = c != nil
            if c != nil { newChatView.invalidateWorkspaceRequests() }
            if transcriptsPresented { for (id, lease) in transcriptLeases { _ = lease.setVisible(id == c?.id) } }
        }
        guard let c else { hideComposer(); offlineBanner.isHidden = true; return }
        let transcript = transcriptsPresented ? retainedTranscript(for:c) : nil
        let next = sessions.composer(for: c, store: store)
        if let transcript, transcript.messageDraftTarget !== next {transcript.messageDraftTarget=next}
        if changed || composer !== next { mount(next, conversation: c, token: nil) }
        let offline = store.isOffline(c)
        let offlineChanged = offlineBanner.isHidden != !offline
        if offlineChanged { offlineBanner.isHidden = !offline }
        let message = "\(store.device(c.deviceID)?.name ?? "This device") is offline.\nThis is the last loaded copy. You can keep writing; sending is off until it reconnects."
        if offlineBanner.stringValue != message { offlineBanner.stringValue = message }
        next.refresh()
        let decisions = store.conversations.map {transcriptSessions.modePresentationValue($0)}.filter { !$0.archived && (!$0.approvals.isEmpty || ($0.id == c.id && ($0.question != nil || $0.userInput != nil))) }.map {
            DecisionValue(identity: ObjectIdentifier($0), title: $0.title, project: store.project($0.projectID)?.name ?? "No Project",
                          offline:store.isOffline($0),archived:$0.archived,approvals: $0.approvals, question: $0.id == c.id ? $0.userInput : nil, legacyQuestion: $0.id == c.id ? $0.question : nil)
        }
        let cardsChanged = decisions != decisionValues; decisionValues = decisions
        if terminalAnimating && cardsChanged{terminalRelayoutNeeded=true}
        let labelsChanged = updateComposerLabels()
        if changed || offlineChanged || cardsChanged || labelsChanged { view.needsLayout = true }
    }
    @discardableResult private func updateComposerLabels() -> Bool {
        let project=store.project(conversation?.projectID ?? context.projectID)?.name ?? "No Project"
        let device=store.device(conversation?.deviceID ?? context.deviceID)?.name ?? "This device"
        let branch=conversation?.branch ?? ""
        let contextText=project+(branch.isEmpty ? "":"  ·  "+branch)+"  ·  "+device
        let statusText: String
        if let conversation {
            let c=transcriptSessions.modePresentationValue(conversation)
            let phrase=store.isOffline(c) ? device+" is offline.":TranscriptPresentation.activityPhrase(items:c.items,running:c.running,sending:c.sending,stopping:c.stopping,waiting:!c.approvals.isEmpty) ?? (c.error == .stopped ? c.items.last(where:{$0.rowKind == .notice(.error)})?.text:nil) ?? ""
            let running=c.satellites.filter{!$0.done}.count
            statusText=phrase+(running>0 ? " · \(running) sub-agent"+(running == 1 ? "":"s"):"")
        } else { statusText="" }
        let changed = composerContext.stringValue != contextText || composerStatus.stringValue != statusText
        if composerContext.stringValue != contextText { composerContext.stringValue = contextText }
        if composerStatus.stringValue != statusText {
            composerStatus.stringValue=statusText;composerStatus.toolTip=statusText;composerStatus.setAccessibilityLabel(statusText)
        }
        return changed
    }
    private func retainedTranscript(for c: Conversation) -> NativeTranscript? {
        guard transcriptsPresented else { return nil }
        if let lease = transcriptLeases[c.id] {
            if let transcript = lease.transcript, transcript.conversation === c, c.id != conversation?.id || transcript.superview === view { return transcript }
            // Another host won. Store/layout callbacks cannot claim it back; only explicit return admission may.
            if lease.isCurrent == false, let existing = transcriptSessions.existingTranscript(for: c.id), existing.conversation === c { return nil }
            transcriptLeases[c.id] = nil
        }
        var configuration = NativeTranscriptSessions.Configuration()
        configuration.decisionCardsInline = false
        configuration.messageDraftTarget = sessions.composer(for: c, store: store)
        configuration.onApproval = actions.approval.map { handler in { handler(c, $0, $1) } }
        configuration.onApprovalValue = actions.approvalValue.map { handler in { handler(c, $0, $1) } }
        configuration.onAnswer = actions.answer.map { handler in { handler(c, $0, $1) } }
        configuration.onEditMessage = actions.edit.map { handler in { handler(c, $0) } }
        configuration.onForkMessage = actions.fork.map { handler in { handler(c, $0) } }
        configuration.onRevertChanges = actions.revertTranscript.map { handler in { handler(c, $0) } }
        configuration.onReviewChanges = { [weak self] _ in self?.onReview?() }
        let selected=c.id == conversation?.id
        if backgroundTranscriptHost.superview !== view {backgroundTranscriptHost.isHidden=true;view.addSubview(backgroundTranscriptHost)}
        // An approval in another conversation needs its actions/cards, not a full-width visible history reflow.
        let host=selected ? view:backgroundTranscriptHost
        guard let lease = transcriptSessions.mount(c,in:host,configuration:configuration,store:store,visible:selected) else { return nil }
        transcriptLeases[c.id] = lease
        // Background cards retain their controls with a hidden transcript; the selected viewport alone is visible.
        _ = lease.setVisible(c.id == conversation?.id)
        return lease.transcript
    }
    func showDraft(_ context: NormieNewChatContext) {
        _ = view; conversation = nil;terminalPane.configure(nil,store:store);terminalPane.presentationActive=false
        if transcriptsPresented { transcriptLeases.values.forEach { _ = $0.setVisible(false) } }; offlineBanner.isHidden = true
        self.context = context;newChatView.isDraft=true;newChatView.context = context; newChatView.isHidden = false; newChatScroll.isHidden = false
        let draft = sessions.draft(); draftToken = draft.token
        newChatView.useDraftToken(draft.token)
        mount(draft.composer, conversation: nil, token: draft.token); updateDraftAvailability(); view.needsLayout = true
    }
    private func updateDraftAvailability() {
        guard conversation == nil, let composer else { return }
        composer.state.online = store.device(context.deviceID)?.online ?? false
        composer.state.usesLiveCore = store.usesLiveCore
        composer.deviceName = store.device(context.deviceID)?.name ?? context.deviceID
        composer.contextSummary = (store.project(context.projectID)?.name ?? "No Project")+" · "+composer.deviceName
        let project=store.project(context.projectID),device=store.device(context.deviceID)
        composer.workspace = .init(project:project?.name ?? "No Project",projectSymbol:project == nil ? "bubble.left":project?.colorHex == nil ? "folder":"folder.fill",projectTint:project?.colorHex,device:device?.name ?? context.deviceID,deviceSymbol:device?.symbol ?? "laptopcomputer",status:device?.online == false ? composer.deviceName+" is offline.":"",statusMark:device?.online == false ? "exclamationmark.triangle.fill":"")
    }
    private func mount(_ next: NativeComposer, conversation: Conversation?, token: NativeComposerSessions.DraftToken?) {
        // Organic owns all mounts/layout/callbacks until an explicit remount. A background store refresh or a
        // different current ID must never pull its editor back into an invisible Normie detail (b079/b089).
        if externalComposer { composer = next; return }
        let alreadyMounted = composer === next && !externalComposer && next.superview === view
        if composer !== next { hideComposer(); composer = next }
        externalComposer = false
        if next.superview !== view { view.addSubview(next) }
        next.isHidden = false; next.alphaValue = 1; next.layoutMode = .growing; next.targetWidth = nil
        if !alreadyMounted {
            previousHeightCallback = next.onHeightChange
            previousMotionCallback=next.onMotionContentsChange
            next.onMotionContentsChange = {[weak self] in self?.scheduleMotionPrewarm()}
            next.onHeightChange = { [weak self] _ in
                guard let self, !self.externalComposer, !self.layingOut else { return }
                if self.terminalAnimating{self.terminalRelayoutNeeded=true}
                self.view.needsLayout = true
            }
        }
        onConfigureComposer?(next, conversation, token)
        if publishedComposer !== next{publishedComposer=next;onComposerPresentationChange?(next,view)}
    }
    private func hideComposer() {
        guard let composer, !externalComposer else { return }
        composer.onHeightChange = previousHeightCallback; composer.focusRing.removeFromSuperview()
        composer.onMotionContentsChange=previousMotionCallback
        // Avoid removing a marked editor. Its owner can defer the selection/mode handoff until composition ends.
        if !composer.isComposing { composer.removeFromSuperview();if publishedComposer === composer{publishedComposer=nil;onComposerPresentationChange?(nil,nil)} }
        else { composer.isHidden = false }
    }
    /// Does not detach, hide, snapshot, or replace the editor. The scene reparents it at its own admitted handoff.
    func composerForHandoff() -> NativeComposer? {
        if publishedComposer != nil{publishedComposer=nil;onComposerPresentationChange?(nil,nil)}
        if !externalComposer { composer?.onHeightChange = previousHeightCallback }
        if !externalComposer { composer?.onMotionContentsChange=previousMotionCallback }
        composer?.invalidateAccessibilityLease();setTranscriptPresentationActive(false)
        externalComposer = true; return composer
    }
    func remountComposer() {
        externalComposer = false
        setTranscriptPresentationActive(true)
        if let c = conversation { mount(sessions.composer(for: c, store: store), conversation: c, token: nil) }
        else { showDraft(context) }
        view.needsLayout = true
    }
    func showNotice(_ text: String, undo: Bool) {
        _ = view;toastMotion?.proxy.retire();toastMotion=nil;toastRevision+=1
        toastText.stringValue = text; undoButton.isHidden = !undo; toast.isHidden = false;toast.alphaValue=1;view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        if canAnimateDetail,let picture=NormieMotionPicture.capture(toast,scale:(view as? NormieView)?.scale ?? 2){
            let end=toast.frame,start=end.insetBy(dx:end.width*0.01,dy:end.height*0.01).offsetBy(dx:0,dy:8)
            toastMotion = .init(proxy:NormieMotionProxy(source:toast,picture:picture,in:view),from:start,to:end,start:motionClock.now,kind:.toastIn,carriedBy:toast,host:view)
            _ = toastMotion?.advance(motionClock.now,profile:motionClock.profile,enabled:motionProcessingEnabled);motionClock.start()
        }
        NSAccessibility.post(element: toastText, notification: .valueChanged)
    }
    private var canAnimateDetail:Bool{(view.window?.isVisible == true || motionClock.manualTime != nil) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    func dismissNotice() {
        guard !toast.isHidden else{return};toastRevision+=1
        toastMotion?.proxy.retire();toastMotion=nil
        if canAnimateDetail,let picture=NormieMotionPicture.capture(toast,scale:(view as? NormieView)?.scale ?? 2){
            let r=toast.frame;toastMotion = .init(proxy:NormieMotionProxy(source:nil,picture:picture,in:view),from:r,to:r,start:motionClock.now,kind:.toastOut,appearing:false,carriedBy:toast,host:view)
            _ = toastMotion?.advance(motionClock.now,profile:motionClock.profile,enabled:motionProcessingEnabled);motionClock.start()
        }
        toast.isHidden = true
    }
    /// Archive bookkeeping must not dismiss a newer, unrelated error or informational toast.
    func dismissArchiveNotice() { if !undoButton.isHidden { dismissNotice() } }
    private func layoutBackgroundApprovals(width: CGFloat, availableHeight: CGFloat,maximumHeight:CGFloat) -> CGFloat {
        guard transcriptsPresented, width > 80 else { return 0 }
        let key=ApprovalLayoutKey(width:width,scale:(view as? NormieView)?.scale ?? 2,selected:conversation?.id,values:decisionValues,appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision)
        if approvalLayoutKey == key, !approvalLayoutOrder.isEmpty, approvalLayoutOrder.allSatisfy({$0.superview === approvalDocument && !$0.isHidden}) {
            var y:CGFloat=0
            for node in approvalLayoutOrder {node.frame.origin.y=NormieDrawing.pixel(y,scale:(view as? NormieView)?.scale ?? 2);y+=node.frame.height+(node is NativeTranscriptCard ? 12:0)}
            y=max(0,y-12);approvalDocument.frame.size=CGSize(width:width,height:y);approvalScroll.isHidden=false
            return min(y,min(maximumHeight,min(300,max(80,availableHeight*0.5))))
        }
        approvalDocument.subviews.filter { !($0 is NativeTranscriptCard) }.forEach { $0.removeFromSuperview() }
        var keep: Set<String> = [], y: CGFloat = 0
        let sources=store.conversations.sorted{a,b in if a.id == conversation?.id{return true};if b.id == conversation?.id{return false};return a.id<b.id}
        let signature=sources.flatMap {transcriptSessions.modePresentationValue($0).approvals}
        if signature != approvalSignature{approvalSignature=signature;approvalDocument.invalidateAccessibilityLease()}
        for source in sources {
            let presentation=transcriptSessions.modePresentationValue(source)
            guard !presentation.approvals.isEmpty || (source.id == conversation?.id && (presentation.question != nil || presentation.userInput != nil)) else {continue}
            guard let transcript=retainedTranscript(for:source) else { continue }
            let cards=ModeSignposts.measure("NormieApprovalConfigure",detail:source.id) {
                transcript.externalDecisionCards(width:width,includeQuestion:source.id == conversation?.id,
                    source:.init(project:store.project(presentation.projectID)?.name ?? "No Project",conversation:presentation.title,isOtherConversation:source.id != conversation?.id,canShowConversation:!presentation.archived),
                    showConversation:{[weak self] in self?.onSelectConversation?(source.id)})
            }
            for (index,card) in cards.enumerated(){
                let key=source.id+":"+String(index);keep.insert(key)
                let configurations=card.approvalConfigurationCount
                let other=source.id != conversation?.id
                if card.isApprovalCard {
                    card.setApprovalSource(.init(project:store.project(presentation.projectID)?.name ?? "No Project",conversation:presentation.title,isOtherConversation:other,canShowConversation:!presentation.archived),showConversation:{ [weak self] in self?.onSelectConversation?(source.id) })
                } else {
                    let text=(store.project(presentation.projectID)?.name ?? "No Project")+" · "+presentation.title+(other ? " · Show Conversation":"")
                    let header=NormieDrawing.button(text){[weak self] in if other{self?.onSelectConversation?(source.id)}}
                    header.isEnabled=other && !presentation.archived;header.alignment = .left;approvalDocument.addSubview(header)
                    header.frame=NormieDrawing.rect(CGRect(x:28,y:y,width:max(1,width-56),height:24),scale:(view as? NormieView)?.scale ?? 2);y+=24
                }
                backgroundCards[key]=card
                card.onHeightChange = { [weak self] in self?.view.needsLayout=true }
                ModeSignposts.measure("NormieApprovalMount",detail:"id=\(source.id) scale=\(card.window?.backingScaleFactor ?? 0) rebuilds.before=\(card.approvalConfigurationCount-configurations)") {
                    if card.superview !== approvalDocument{card.removeFromSuperview();approvalDocument.addSubview(card)}
                }
                ModeSignposts.current?.record("NormieApprovalMountResult",detail:"id=\(source.id) scale=\(card.window?.backingScaleFactor ?? 0) rebuilds=\(card.approvalConfigurationCount-configurations)")
                card.frame.origin.y=NormieDrawing.pixel(y,scale:(view as? NormieView)?.scale ?? 2);y+=card.frame.height+12
            }
        }
        for key in Array(backgroundCards.keys) where !keep.contains(key) { if let card=backgroundCards[key],!backgroundCards.contains(where:{keep.contains($0.key) && $0.value === card}){card.removeFromSuperview()};backgroundCards[key] = nil }
        if !keep.isEmpty { y -= 12 }
        approvalDocument.frame = CGRect(x: 0, y: 0, width: width, height: y)
        approvalScroll.isHidden = keep.isEmpty
        approvalLayoutKey=key;approvalLayoutOrder=approvalDocument.subviews.sorted{$0.frame.minY<$1.frame.minY}
        return keep.isEmpty ? 0 : min(y,min(maximumHeight,min(300,max(80,availableHeight*0.5))))
    }
    private func modeComposerHeight(_ composer:NativeComposer,width:CGFloat,height:CGFloat)->CGFloat {
        func key()->ComposerEndpointKey {.init(identity:ObjectIdentifier(composer),width:width,height:height,minimum:composer.minimumHeight,natural:composer.naturalEditorHeight,value:currentComposerMotionValue())}
        if composerEndpointKey == key(),composer.layoutMode == .growing,composer.targetWidth == nil,composer.frame.width == width {return composerEndpointHeight}
        let measured=composer.prepareNormieLayout(width:width,detailHeight:height)
        composerEndpointHeight=measured;composerEndpointKey=key();return measured
    }
    override func viewDidLayout() {
        super.viewDidLayout(); layoutContent()
    }
    private func layoutContent() {
        guard !layingOut, !modeLayoutFrozen, let root = view as? NormieView else { return }
        if terminalAnimating{if root.contentSafeRect != terminalSafeRect{settleMotions()}else{return}} // DECISIONS #26: resize settles before reflow.
        terminalFullLayoutCount+=1
        layingOut = true; defer { layingOut = false }
        let safe = modePreparationSafeRect ?? root.contentSafeRect, w = safe.width
        let terminalHeight=conversation == nil ? 0:NormieTerminalMotion.height(available:safe.height)*min(1,max(0,terminalProgress))
        let h=max(0,safe.height-terminalHeight)
        root.place(terminalClip,CGRect(x:safe.minX,y:safe.minY+h,width:w,height:terminalHeight));terminalClip.isHidden=terminalHeight<0.01
        terminalClip.place(terminalPane,CGRect(x:0,y:0,width:w,height:NormieTerminalMotion.height(available:safe.height)))
        terminalPane.isHidden=terminalHeight<0.5;terminalPane.alphaValue=CGFloat(min(1,max(0,terminalProgress)))
        let composerWidth = max(1, min(768, w-28))
        let ownsComposer = composer != nil && !externalComposer && composer?.superview === view
        let composerHeight = ModeSignposts.measure("NormieComposerEndpointLayout") {ownsComposer ? modeComposerHeight(composer!,width:composerWidth,height:h) : max(120,composer?.measuredHeight ?? 120)}
        let top: CGFloat = offlineBanner.isHidden ? 0 : 78
        let dockHeight = composerHeight
        let baseBottom = externalComposer ? 14 : dockHeight+26
        let approvalsHeight=layoutBackgroundApprovals(width:w,availableHeight:h,maximumHeight:max(0,h-top-baseBottom-64))
        let bottom = baseBottom+approvalsHeight
        if transcriptsPresented, let c = conversation, let lease = transcriptLeases[c.id] {
            // NativeTranscript keeps 18 pt above its first row (Organic's columns); Normie's TranscriptView starts 8 pt
            // below the toolbar (contentInsets.top 8 over the automatic toolbar inset), so it reaches 10 pt under it.
            let lead: CGFloat = 10
            _ = lease.place(CGRect(x: safe.minX, y: safe.minY+top-lead, width: w, height: max(1, h-top-bottom+lead)))
        }
        root.place(offlineBanner, CGRect(x: safe.minX+max(14, (w-740)/2), y: safe.minY+10, width: max(1, min(740, w-28)), height: 62))
        root.place(newChatScroll, CGRect(x: safe.minX, y: safe.minY, width: w, height: max(1, h-bottom)))
        root.place(approvalScroll, CGRect(x: safe.minX, y: safe.minY+max(top, h-bottom), width: w, height: approvalsHeight))
        root.place(newChatView, CGRect(x: 0, y: 0, width: newChatScroll.contentSize.width, height: max(1, h-bottom)))
        composerGlass.isHidden = !ownsComposer; composerContext.isHidden = true;composerStatus.isHidden = true
        if !ownsComposer { root.offscreenGlassRect = nil }
        if let composer, ownsComposer {
            root.place(composerGlass, CGRect(x:safe.minX+(w-composerWidth)/2,y:safe.minY+h-dockHeight-14,width:composerWidth,height:dockHeight))
            composerGlass.contentView?.frame = composerGlass.bounds
            root.offscreenGlassRect = composerGlass.frame
            updateComposerLabels()
            composer.targetWidth = nil // Non-nil is the bar admission API and switches layoutMode to .fullBar.
            root.place(composer,composerGlass.frame)
            if composer.focusRing.superview !== root { root.addSubview(composer.focusRing, positioned: .above, relativeTo: composer) }
            root.place(composer.focusRing, composerGlass.frame.insetBy(dx: -1, dy: -1))
#if NORMIE_SELFTEST
            // Reproduce the actual admission, not a test that repairs the mode after the host set targetWidth.
            assert(composer.layoutMode == .growing && composer.targetWidth == nil,"M9 Normie must never admit its editor as a bar")
            assert(composer.frame == composerGlass.frame,"M9 all three rows share the one composer glass")
            if !composer.isComposing { assert(composer.scrollView.frame.maxY+4<=composer.accessButton.frame.minY,"M9 full-width body stays above the controls") }
#endif
        }
        root.place(toast, CGRect(x: safe.minX+max(14, (w-min(520, w-28))/2), y: safe.minY+max(top+4, h-bottom-44), width: max(1, min(520, w-28)), height: 36))
        toast.place(toastText, CGRect(x: 12, y: 9, width: max(1, toast.bounds.width-82), height: 18))
        toast.place(undoButton, CGRect(x: toast.bounds.width-62, y: 5, width: 52, height: 26))
        if !modeHandoffInProgress {updateApprovalMotionRest();scheduleMotionPrewarm()}
    }

    private func updateApprovalMotionRest(){
        let afterMode=approvalRestAfterMode;approvalRestAfterMode=false
        let ids=store.conversations.filter{!$0.archived}.flatMap(\.approvals).map(\.id)
        guard ids != presentedApprovalIDs else{return};presentedApprovalIDs=ids
        let previous=approvalRest;approvalRest=[:]
        for card in backgroundCards.values where card.superview != nil {
            let key=ObjectIdentifier(card),r=card.convert(card.bounds,to:view)
            let picture:NormieMotionPicture?
            if afterMode {picture=warmPictures[key].flatMap{$0.0 == pictureKey(card) ? $0.1:nil}}
            else {picture=NormieMotionPicture.capture(card,scale:(view as? NormieView)?.scale ?? 2)}
            if let picture {approvalRest[key]=(card,r,picture)}
        }
        // The mode fade already introduced these cards. Populate future removal pictures through idle tiles;
        // never append synchronous card captures or a second entrance to the flight-end callback.
        if afterMode {scheduleMotionPrewarm();return}
        guard canAnimateDetail,!terminalAnimating else{return}
        itemMotions.forEach{$0.proxy.retire()};itemMotions=[]
        let now=motionClock.now
        for (id,(card,r,picture)) in approvalRest {
            let old=previous[id]?.1,from=old ?? r.offsetBy(dx:0,dy:8)
            itemMotions.append(.init(proxy:NormieMotionProxy(source:card,picture:picture,in:view),from:from,to:r,start:now,kind:.approval,fade:old == nil,carriedBy:approvalDocument,host:view))
        }
        for (id,(_,r,picture)) in previous where approvalRest[id] == nil {
            itemMotions.append(.init(proxy:NormieMotionProxy(source:nil,picture:picture,in:view),from:r,to:r.offsetBy(dx:0,dy:8),start:now,kind:.approval,appearing:false,carriedBy:approvalDocument,host:view))
        }
        for motion in itemMotions{_ = motion.advance(now,profile:motionClock.profile,enabled:motionProcessingEnabled)}
        if !itemMotions.isEmpty{motionClock.start()}
    }
}

/// New Chat's page (NormieDetailView.emptyState): the leaf, the project and one line, centred above the composer. The
/// project and device are chosen from the composer's context row (NewChatContext), whose menus this view builds.
@MainActor final class NormieNewChatView: NormieView {
    let store: ConversationStore, actions: NormieActions
    let hero=NormieNewChatSymbol(frame:.zero)
    let selectionHint=NormieDrawing.label("Select a conversation to compose a message.",size:13)
    var isDraft=true{didSet{refresh()}}
    let heading = NormieDrawing.label("No Project", size: 22, weight: .semibold)
    let subtitle = NormieDrawing.label("Nothing is created until you send.", size: 13)
    /// How far below this view's bounds the product's centring space reaches. It centres the page above the composer
    /// cluster; with a background approval card its stack sits 6 px higher than this view's own centre (1× captures,
    /// leaf, title and line alike), so the space ends 2 pt, not Canopy.dockInset's 14, below the bounds.
    var bottomInset: CGFloat = 2 { didSet { if bottomInset != oldValue { needsLayout = true } } }
    private var workspaceEpoch: UInt64 = 0
    private var draftToken: NativeComposerSessions.DraftToken?
    var onChange: ((NormieNewChatContext) -> Void)?
    var context = NormieNewChatContext() { didSet { if oldValue != context { workspaceEpoch &+= 1 }; refresh() } }
    func useDraftToken(_ token: NativeComposerSessions.DraftToken) { if draftToken != token { draftToken = token; workspaceEpoch &+= 1 } }
    func invalidateWorkspaceRequests() { workspaceEpoch &+= 1 }
    init(store: ConversationStore, actions: NormieActions) {
        self.store = store; self.actions = actions; super.init(frame: .zero)
        for v in [hero,selectionHint,heading, subtitle] { addSubview(v) }
        heading.alignment = .center; subtitle.alignment = .center;subtitle.maximumNumberOfLines=2;subtitle.lineBreakMode = .byWordWrapping;subtitle.textColor = NativePalette.secondaryLabel
        setAccessibilityRole(.group); setAccessibilityLabel("New chat context"); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refresh() {
        hero.isHidden = !isDraft;heading.isHidden = !isDraft;subtitle.isHidden = !isDraft;selectionHint.isHidden=isDraft;selectionHint.alignment = .center;selectionHint.textColor = NativePalette.secondaryLabel
        heading.stringValue = store.project(context.projectID)?.name ?? "No Project"
        let device=store.device(context.deviceID)?.name ?? "This Mac"
        subtitle.stringValue = (context.projectID == nil ? "New chat without a project on ":"New chat on ")+device+". Nothing is created until you send."
        needsLayout = true
    }
    @discardableResult func pickDevice(_ id: String) -> Bool {
        guard store.device(id)?.online == true else { return false }
        context = NormieNewChatContext(projectID: store.projects.first { $0.deviceID == id }?.id, deviceID: id)
        onChange?(context); return true
    }
    @discardableResult func pickProject(_ id: String?) -> Bool {
        if let id { guard let p = store.project(id), p.deviceID == context.deviceID else { return false } }
        context.projectID = id; onChange?(context); return true
    }
    func makeProjectMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Projects on \(store.device(context.deviceID)?.name ?? context.deviceID)"))
        for p in store.projects where p.deviceID == context.deviceID {
            let item = NormieMenuItem(p.name) { [weak self] in _ = self?.pickProject(p.id) }
            item.image = NSImage(systemSymbolName: p.colorHex == nil ? "folder" : "folder.fill", accessibilityDescription: nil)
            item.state = p.id == context.projectID ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator()); let none = NormieMenuItem("No Project") { [weak self] in _ = self?.pickProject(nil) }
        none.state = context.projectID == nil ? .on : .off; menu.addItem(none)
        menu.addItem(NormieMenuItem("Choose Workspace…", enabled: actions.chooseWorkspace != nil && (store.device(context.deviceID)?.online ?? false)) { [weak self] in
            guard let self else { return }; let requested = self.context, epoch = self.workspaceEpoch
            self.actions.chooseWorkspace?(requested) { [weak self] project in
                guard let self, self.workspaceEpoch == epoch, self.context == requested, let project, project.deviceID == requested.deviceID,
                      project.path?.hasPrefix("/") == true, project.path?.contains("\n") == false else { return }
                let canonical = self.store.addProject(project); _ = self.pickProject(canonical.id)
            }
        })
        return menu
    }
    /// DeviceCards (ComposerDock.swift): a card per device, the chosen one on an accent plate; picking one closes `done`.
    func makeDeviceCards(done: @escaping @MainActor () -> Void) -> NormieDeviceCards {
        NewChatDevicePicker.makeCards(store: store, selected: context.deviceID,
                                      pick: { [weak self] in _ = self?.pickDevice($0.deviceID) }, done: done)
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        place(selectionHint,CGRect(x:14,y:bounds.midY-12,width:max(1,bounds.width-28),height:24))
        // A 10 pt VStack: 44 pt leaf, 22 pt semibold project, the secondary line (wraps when narrow).
        let leaf = hero.symbolSize, headingHeight = ceil(heading.intrinsicContentSize.height)
        let line = subtitle.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, w-40), height: 200)).height ?? 16
        let total = leaf.height+10+headingHeight+10+line
        let top = max(0, ((bounds.height+bottomInset)-total)/2)
        place(hero,CGRect(x:(w-leaf.width)/2,y:top,width:leaf.width,height:leaf.height))
        place(heading, CGRect(x: 20, y: top+leaf.height+10, width: max(1, w-40), height: headingHeight))
        place(subtitle, CGRect(x: 20, y: top+leaf.height+20+headingHeight, width: max(1, w-40), height: ceil(line)))
    }
}

/// `leaf.fill` at 44 pt in Canopy moss (dark), drawn at the symbol's own size like SwiftUI's Image.
@MainActor final class NormieNewChatSymbol:NormieView {
    // .symbolRenderingMode(.hierarchical): the vein is the moss's secondary tier.
    private static let image = NSImage(systemSymbolName:"leaf.fill",accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:44,weight:.regular).applying(NSImage.SymbolConfiguration(hierarchicalColor:NSColor(srgbRed:0x57/255,green:0xc2/255,blue:0x7a/255,alpha:1))))
    var symbolSize: CGSize { Self.image?.size ?? CGSize(width:48,height:48) }
    override func draw(_ dirtyRect:NSRect){ Self.image?.draw(in:bounds) }
}


extension NormieDetailController {
    func setModeContentInputBlocked(_ blocked:Bool) {
        terminalPane.modeContentInputBlocked=blocked
        func visit(_ view:NSView) {
            (view as? NativeInteractionSurface)?.modeContentInputBlocked=blocked
            for child in view.subviews {visit(child)}
        }
        if isViewLoaded {visit(view)}
    }
}

#if M11_MODE_SELFTEST
extension NormieDetailController {
    var verificationCloseThreeCards:Int {backgroundCards.values.filter {!$0.isHidden && $0.superview === approvalDocument && !approvalScroll.isHidden && approvalScroll.frame.height>0}.count}
}
#endif
