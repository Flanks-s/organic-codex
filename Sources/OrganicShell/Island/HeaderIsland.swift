import AppKit
import QuartzCore
import CoreImage

struct HeaderIslandConfiguration: Equatable {
    var id:String
    var title:String
    var identity:OrbIdentity = .assigned(0)
    var variant:HeaderIslandVariant = .full
    var columnWidth:CGFloat = 400
    var band:CGFloat = 0
    var signals=HeaderIslandSignals()
    var activitySerial:UInt64=0
    var satellitesRetired=false
    var contextDescription="Context usage has not been reported"
    var contextLimit:String?
    var canCompact=false
    var reduceMotion=false, ambient=true, isKeyWindow=true
    var active=true
    var scale:CGFloat=2
    var notices:ConversationNoticeSnapshot?
    var noticeColumnWidth:CGFloat?
}

@MainActor struct HeaderIslandActions {
    var customize:(()->Void)?
    var rename:((String)->Void)?
    var route:((HeaderIslandRoute)->Void)?
    var compact:(()->Void)?
    var noticeAction:((ConversationNoticeAction)->Void)?
    /// The window owner closes its other islands here. No window/scene registry lives in this component.
    var expansion:((Bool,Bool)->Void)?
    var geometry:((HeaderIslandGeometry)->Void)?
    /// Sheet owner receives this island's frame in its superview coordinates. nil selects the default row.
    var subAgents:((_ anchor:CGRect,_ select:String?)->Void)?
    /// nil is a click/AX action; a screen point is a satellite dropped away from its row.
    var openSatellite:((_ id:String,_ screenPoint:CGPoint?)->Void)?
}

/// Retained native endpoint. The column owns placement and uses snapshots while driver B changes variants.
@MainActor final class HeaderIsland:IslandPlane, NSTextFieldDelegate, NSPopoverDelegate {
    private(set) var configuration:HeaderIslandConfiguration?
    private(set) var state=HeaderIslandState() {didSet {if state != oldValue {NotificationCenter.default.post(name:Notification.Name("Organic.ModePreparationInputsChanged"),object:self)}}}
    private(set) var geometry=HeaderIslandGeometry.make(variant:.full,columnWidth:400,state:.init())
    let titleButton=IslandButton(), planetButton=IslandButton(), eventButton=IslandButton()
    let renameField=IslandRenameField()
    let orb=OrbComponent(id:UUID().uuidString)
    private(set) var orbIsCarried=false
    /// Geometry is the live orb pose, including full/brief and local expansion motion.
    var draggableOrbRect:CGRect { orb.glassView.frame }
    var orbDragPreparationDelay:Double {max(0,(localMotion.map{$0.began+$0.spring.duration} ?? now())-now())}
    var canDragOrb:Bool {
        guard canAct,!state.editing,!orbIsCarried,let variant=configuration?.variant else {return false}
        switch variant {
        case .full,.brief,.split:return true
        case .collapse,.newChat:return false
        }
    }
    /// Hide paint, never layout or the original glass's parent. The carried decoration has its own fixed canvas.
    func setOrbCarried(_ carried:Bool) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer {CATransaction.commit()}
        orbIsCarried=carried
        // Withdraw the owned drawing before AppKit hides its native backing planes. This also
        // suppresses orbit/exposure replicas if a backing presentation survives the view handoff.
        orb.setOpacity(carried ? 0:1)
        for view in [orb.glassView,orb.backView,orb.frontView] { view.isHidden=carried }
        planetButton.isHidden=carried
        if !carried {planetButton.restorePointerHover()}
    }
    private let glassContainer=NSGlassEffectContainerView()
    private let capsule=NSGlassEffectView(), lobe=NSGlassEffectView()
    private let controlsMask=CAShapeLayer()
    private let controls=IslandPlane(), nameLabel=IslandLabel(labelWithString:""), chevron=IslandLabel(labelWithString:"›")
    /// Offscreen checks exercise the real texture path without constructing an NSWindow.
    static var forceMotionTexturesForVerification=false
    var motionGlyphMaterial:IslandGlyphPlane {glyphPlane}
    private let glyphPlane=IslandGlyphPlane(frame:.zero)
    private let glyphPose=IslandPlane()
    private var nameBaseRect=CGRect.zero
    /// For the path check: an activity line showing with no glass under it, past the island's own spring (the line shows at once as that starts).
    var eventOutsideCapsule:Bool { !eventButton.isHidden && localMotion == nil && !capsule.frame.insetBy(dx:-1,dy:-1).contains(eventButton.frame) }
    private let motionClock=IslandMotionClock()
    /// While the column moves the capsule comes from `motionGeometry`, not from the island's state. An activity line that arrives then
    /// waits for the landing: it showed with no glass under it for the whole motion (board 261031j). One already up stays, with its capsule.
    private var hostMotion=false,hostMotionKeepsActivity=false,hostMotionTruncatesTitle=false
    private var shownShape:HeaderIslandShape { hostMotion && !hostMotionKeepsActivity && state.shape == .activity ? .compact:state.shape }
    var motionProfile:DisplayProfile?
    var motionExposure:ExposureSettings = {var s=ExposureSettings();s.enabled=ProcessInfo.processInfo.environment["M10_COLUMNS"] != "0";return s}()
    private(set) var motionRecords:[IslandMotionRecord]=[]
    private var lastMotion:(geometry:HeaderIslandGeometry,origin:CGPoint,name:CGRect,fontScale:CGFloat)?
    private var localMotion:(from:HeaderIslandGeometry,to:HeaderIslandGeometry,began:Double,spring:Spring)?
    private var lobeMotion:(base:CGRect,began:Double)?
    private var controlsFade:IslandControlsFade?
    private var controlsOpacity:CGFloat=0
    private var eventPhase=IslandEventPhase(),wantedEvent=false
    private var eventBaseRect=CGRect.zero
    private let eventMask=CAShapeLayer()
    private let eventBlur=OverlayFilter.make("gaussianBlur",values:["name":"islandEventBlur","inputRadius":0,"enabled":false])
    private let mark=IslandMarkView()
    private var actionButtons:[IslandButton]=[], satelliteButtons:[String:IslandButton]=[:]
    private var satelliteOpeners:[String:SatelliteOpener]=[:]
    private var carriedSatellites=Set<String>()
    private var overflowButton=IslandButton(), divider=IslandPlane()
    private var firstHiddenSatellite:String?
    private var widths:[CGFloat:CGFloat]=[:]
    private var timer:Timer?, outsideMonitor:Any?, popover:NSPopover?
    private var hoverTracking:NSTrackingArea?
    private var lobeTask:DispatchWorkItem?
    private var promotionInProgress=false, promotionTitleRevealed=false
    private var promotionName:String?
    private let gaussianClock=SceneClock()
    private var nameGaussian:ContentGaussianTransition?
    private var outgoingGaussians:[ContentGaussianTransition]=[]
    var contentZoomStyle=M10IslandZoom.selected
    private var semanticGaussian:Bool {contentZoomStyle == .gauss && motionExposure.enabled && configuration?.reduceMotion == false}
    private var motionPose:HeaderIslandGeometry?
    private var retiringNames:[IslandLabel]=[]
    private weak var exposureOutgoingName:IslandLabel?
    private var nameAnimationBegan:Double?
    private var renderedLobe=0, disposed=false, presentationActive=true
    private var interactionGeneration=0
    private var pulse:HeaderPulsePresentation?
    private var pulsePresentationRetired=false
    private var modeContentFrozen=false
    private var pulseSuppressed:[(NSView,Bool)]=[]
    private var pulseShowing:Bool { pulse?.isEnabled == true && pulse?.isHidden == false }
    var pulseClockRunning:Bool { pulse?.clockRunning == true }
    var pulseProbe:[String:Any]? {
        guard pulseShowing, var probe=pulse?.probe else { return nil }
        probe["orbRect"]=[orb.glassView.frame.minX,orb.glassView.frame.minY,orb.glassView.frame.width,orb.glassView.frame.height]
        return probe
    }
    var actions=HeaderIslandActions()
    /// Supply fresh/dedicated controllers. In particular, use HeaderIslandInspectorBridge for Normie inspectors.
    var panelContent:((HeaderIslandPanel)->NSViewController?)?
    var now:()->Double = { CACurrentMediaTime() }
    var noticeWallTime:()->Double = { Date().timeIntervalSince1970 }
    override var isHidden:Bool {
        didSet {
            guard oldValue != isHidden else { return }
            interactionGeneration+=1
            if isHidden { pulse?.suspend(); restorePulseContent(); satelliteOpeners.values.forEach{$0.cancel()}; renameField.invalidateFocusRequests(); stopMotionExposure() }
            else if let c=configuration,c.notices != nil {restorePulseContent();configurePulse(c)}
            // The host can configure a retained hidden island before showing it again.
            if configuration != nil { installMenus(); schedule(); syncOutsideMonitor() }
        }
    }

    override init(frame:NSRect) {
        super.init(frame:frame)
        postsFrameChangedNotifications=true;postsBoundsChangedNotifications=true
        orb.glassView.postsFrameChangedNotifications=true
        glyphPlane.forceTextureExposure=Self.forceMotionTexturesForVerification
        glassContainer.spacing=8; glassContainer.contentView=IslandPlane()
        for glass in [capsule,lobe,orb.glassView] {
            glass.style = .regular; glass.tintColor=NSColor.windowBackgroundColor.withAlphaComponent(0.42)
        }
        // Only the capsule and its lobe share a container (ColumnHeader.islandView). The planet is a separate piece of
        // glass above them: in the container it melted into the capsule at this 8 pt spacing.
        for glass in [capsule,lobe] { glassContainer.contentView?.addSubview(glass) }
        capsule.contentView=IslandPlane(); lobe.cornerRadius=10; lobe.isHidden=true
        addSubview(orb.backView); addSubview(glassContainer); addSubview(orb.glassView); addSubview(orb.frontView); addSubview(controls)
        for v in [titleButton,planetButton,eventButton,mark,divider,overflowButton] as [NSView] { controls.addSubview(v) }
        controls.addSubview(glyphPlane); glyphPlane.addSubview(glyphPose)
        glyphPose.addSubview(nameLabel); glyphPose.addSubview(chevron)
        motionClock.tick={ [weak self] in self?.sampleMotion(at:$0) }
        for label in [nameLabel,chevron] {
            label.isBordered=false; label.isBezeled=false; label.drawsBackground=false
            label.maximumNumberOfLines=1; label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false); label.wantsLayer=true
        }
        nameLabel.textColor = .labelColor; chevron.textColor = .secondaryLabelColor
        titleButton.drawsText=false; planetButton.drawsText=false; planetButton.circular=true
        // The product's title and event controls are clear (NativeHeaderTitleControl): a plate of radius 8 stuck out past
        // the capsule's rounder corners, and stayed there while the button held the keyboard.
        titleButton.drawsPointerHighlight=false; eventButton.drawsPointerHighlight=false
        titleButton.invoke={ [weak self] in self?.togglePin() }
        titleButton.doubleClick={ [weak self] in self?.beginRename() }
        titleButton.focus={ [weak self] in self?.setKeyboardFocus($0) }
        eventButton.focus={ [weak self] in self?.setKeyboardFocus($0) }
        planetButton.invoke={ [weak self] in guard let self,self.canAct else { return }; self.actions.customize?() }
        planetButton.beginPointerGesture={ [weak self] event in
            guard let self,self.canDragOrb else { return nil }
            return self.orbDragProvider()?.beginOrbDrag(from:self,event:event)
        }
        eventButton.invoke={ [weak self] in guard let self,let event=self.state.activity else { return }; self.route(event.route) }
        renameField.delegate=self
        for panel in HeaderIslandPanel.allCases {
            let button=IslandButton(); button.invoke={ [weak self] in self?.openPanel(panel) }
            controls.addSubview(button); actionButtons.append(button)
        }
        overflowButton.text="…"; overflowButton.invoke={ [weak self] in guard let self else { return }; self.openSubAgents(select:self.firstHiddenSatellite) }
        divider.layer?.backgroundColor=NSColor.white.withAlphaComponent(0.22).cgColor
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Conversation header")
        for v in [glassContainer,capsule,lobe,orb.backView,orb.frontView] { v.setAccessibilityElement(false) }
        renameField.participates=false; eventButton.isHidden=true; mark.isHidden=true; divider.isHidden=true; overflowButton.isHidden=true
        actionButtons.forEach { $0.isHidden=true }
        updateDisplayStyle()
    }
    convenience init() { self.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { timer?.invalidate(); lobeTask?.cancel(); motionClock.stop(); if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) } }
    override func displayOptionsDidChange() { updateDisplayStyle(); super.displayOptionsDidChange() }
    private func updateDisplayStyle() {
        let opaque=OrbDisplayEnvironment.shared.options.opaqueSurfaces
        for glass in [capsule,lobe,orb.glassView] { glass.tintColor=opaque ? nil:NSColor.windowBackgroundColor.withAlphaComponent(0.42) }
        divider.layer?.backgroundColor=OrbDisplayEnvironment.surface(.white,opacity:0.22).cgColor
        capsule.layer?.shadowOpacity=opaque ? 0:(state.expanded ? 0.18:0.08)
    }

    func configure(_ input:HeaderIslandConfiguration, at time:Double?=nil) {
        guard !disposed else { return }
        let t=time ?? now(), old=configuration
        let oldName=nameLabel.stringValue,oldNameFrame=nameLabel.frame,oldNameFont=nameLabel.font,oldNameBounds=nameLabel.bounds.size
        if old?.id != input.id {
            restorePulseContent(); pulse?.dispose(); pulse?.removeFromSuperview(); pulse=nil
            interactionGeneration+=1
            promotionInProgress=false; promotionTitleRevealed=false; promotionName=nil
            state=HeaderIslandState(); endInput(); popover?.close()
            eventPhase.reset(visible:false);wantedEvent=false
        }
        state.updateSatelliteRetirement(was:old?.id == input.id ? old?.satellitesRetired:nil,retired:input.satellitesRetired,now:t)
        if let old, old.variant != input.variant { pulse?.suspend() }
        configuration=input
        if old?.title != input.title || widths.isEmpty {
            widths=Dictionary(uniqueKeysWithValues:[CGFloat(12),12.5,13,16,17].map { font in
                (font,ceil((input.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:font,weight:.semibold)]).width))
            })
        }
        if !input.active {
            stopMotionExposure()
            if old?.active == true { interactionGeneration+=1 }
            state.escape(); state.hover(false,now:t); state.focus(false,now:t); state.outside(); endInput(); popover?.close(); lobe.isHidden=true; lobeTask?.cancel()
        } else if let old,old.id == input.id,input.variant != .newChat,old.variant != .newChat {
            if input.notices == nil { state.update(old.signals,input.signals,now:t) }
        }
        if input.reduceMotion {
            stopMotionExposure()
            for key in ["island.name.fall","island.name.blur"] { nameLabel.layer?.removeAnimation(forKey:key) }
            nameLabel.layer?.filters=nil; lobe.isHidden=true; lobe.layer?.removeAllAnimations()
        }
        orb.setPresentationActive(input.active && presentationActive)
        render(animated:old != nil && input.variant == old?.variant)
        if let old,old.id == input.id,old.title != input.title,!promotionInProgress,!state.editing {
            animateName(from:oldName,frame:oldNameFrame,font:oldNameFont,bounds:oldNameBounds)
        }
        schedule(); syncOutsideMonitor()
    }
    /// Explicit input methods are also useful when the host owns outside-event arbitration.
    func receive(_ event:HeaderIslandEvent,at time:Double?=nil) { guard canAct else { return }; state.show(event,now:time ?? now()); render(animated:true); schedule() }
    func advance(to time:Double) {
        let was=state.expanded, pinned=state.pinned
        state.tick(now:time); render(animated:true); schedule()
        if was != state.expanded || pinned != state.pinned { publishExpansion() }
    }
    func hover(_ inside:Bool,at time:Double?=nil) {
        guard canAct else { return }
        let admitted = inside && NativePointerShield.permits(self)
        if pulseShowing { pulse?.hover(admitted,at:time ?? now()); return }
        guard admitted != state.hovering else { return }
        state.hover(admitted,now:time ?? now()); nameLabel.alphaValue=admitted ? 1:geometry.titleOpacity; schedule()
    }
    func reconcilePointerHover(_ point:CGPoint?) { hover(point.map { visibleCapsule.contains($0) } ?? false) }
    func setKeyboardFocus(_ inside:Bool,at time:Double?=nil) { guard canAct else { return }; if pulseShowing {pulse?.focus(inside);return}; state.focus(inside,now:time ?? now()); schedule() }
    func togglePin() {
        guard canAct,configuration?.variant != .newChat else { return }
        if pulseShowing { pulse?.togglePin(); return }
        state.togglePin(); render(animated:true); schedule(); publishExpansion()
    }
    func setExpanded(_ open:Bool,pinned:Bool=false) {
        if !open { pulse?.dismiss() }
        guard canAct else { return }; state.setExpanded(open,pinned:pinned); render(animated:true); schedule(); publishExpansion()
    }
    func outsideClick() {
        guard canAct else { return }
        pulse?.dismiss()
        if state.editing { commitRename() } else { state.outside(); render(animated:true); schedule(); publishExpansion() }
    }
    func escape() { guard canAct else { return }; pulse?.dismiss(); state.escape(); endInput(); popover?.close(); render(animated:true); schedule(); publishExpansion() }
    func beginRename() {
        guard canAct,configuration?.variant != .newChat,!state.editing else { return }
        interactionGeneration+=1
        pulse?.dismiss()
        state.beginRename(configuration!.title); renameField.beginSession(text:state.renameText)
        render(animated:true); schedule(); publishExpansion(); _ = renameField.focusSession()
    }
    func commitRename() {
        guard state.editing else { return }
        state.editRename(renameField.stringValue)
        let next=state.commitRename(); endInput()
        if let next,var c=configuration {
            c.title=next; configure(c); actions.rename?(next)
        } else { render(animated:true) }
        schedule()
    }
    func cancelRename() { guard state.editing else { return }; state.cancelRename(); endInput(); render(animated:true); schedule() }
    private func endInput() {
        interactionGeneration+=1
        let ownedEditor=renameField.currentEditor() != nil
        renameField.endSession()
        if ownedEditor { window?.makeFirstResponder(canAct ? titleButton:nil) }
        renameField.removeFromSuperview()
    }
    func controlTextDidChange(_ obj:Notification) { if state.editing { state.editRename(renameField.stringValue) } }
    func controlTextDidEndEditing(_ obj:Notification) { if state.editing,renameField.participates,(obj.object as? NSControl) === renameField { commitRename() } }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector) -> Bool {
        guard state.editing,renameField.participates,control === renameField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { guard !textView.hasMarkedText() else { return false }; commitRename(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelRename(); return true }; return false
    }
    override func cancelOperation(_ sender:Any?) { escape() }
    private var canAct:Bool { !disposed && !isHiddenOrHasHiddenAncestor && !promotionInProgress && presentationActive && configuration?.active == true }
    private func publishExpansion() { actions.expansion?(state.expanded,state.pinned); syncOutsideMonitor() }

    private func render(animated:Bool) {
        restorePulseContent()
        guard let c=configuration else { return }
        if !c.active || !presentationActive {satelliteOpeners.values.forEach{$0.cancel()}}
        let departure=motionPose ?? geometry
        motionPose=nil
        let old=geometry, m=c.variant.metrics(band:c.band), shape=shownShape
        let font:CGFloat = shape == .activity ? 12:shape == .expanded ? 13:m.font
        let width = c.variant == .newChat || promotionName != nil ? Self.seedTitleWidths[font] ?? 0 : widths[font] ?? 0
        geometry = .make(variant:c.variant,columnWidth:c.columnWidth,state:.init(shape:shape,titleWidth:width,hasMark:c.signals.mark != nil,hasSatellites:!c.signals.satellites.isEmpty && (!c.satellitesRetired || state.satellitesHoldingUntil != nil),band:c.band,scale:c.scale))
        let g=geometry
        if hostMotion,(widths[g.titleFont] ?? 0)>g.title.width+0.5 {hostMotionTruncatesTitle=true}
        if old.actions.isEmpty != g.actions.isEmpty {
            let target:CGFloat=g.actions.isEmpty ? 0:1
            if animated {
                controlsFade=IslandControlsFade(from:controlsFade?.value(at:now()) ?? controlsOpacity,to:target,began:now())
                motionClock.start(in:self)
            } else {controlsFade=nil;controlsOpacity=target}
        }
        setAccessibilityHidden(!(c.active && presentationActive && !promotionInProgress))
        frame.size=CGSize(width:(c.columnWidth*c.scale).rounded()/c.scale,height:g.height)
        glassContainer.frame=bounds; glassContainer.contentView?.frame=bounds; controls.frame=bounds
        glyphPlane.frame=controls.bounds
        glyphPose.layer?.transform=CATransform3DIdentity;glyphPose.frame=glyphPlane.bounds
        capsule.frame=g.capsule; capsule.cornerRadius=g.radius; capsule.contentView?.frame=capsule.bounds
        orb.glassView.frame=g.planet; orb.glassView.cornerRadius=g.planet.width/2
        orb.glassView.contentView?.frame=orb.glassView.bounds
        orb.setCanvasSize(bounds.size)
        titleButton.frame=g.titleRow; titleButton.isHidden=state.editing
        titleButton.participates=c.active && presentationActive && !state.editing; titleButton.text=c.variant == .newChat ? "New Chat":promotionName ?? c.title
        titleButton.setAccessibilityValue(c.signals.words)
        titleButton.setAccessibilityHelp(state.expanded ? "Closes the details":"Shows sub-agents, changes and context")
        planetButton.frame=g.planet; planetButton.participates=c.active && presentationActive
        planetButton.text="Customize \(c.title)"; planetButton.setAccessibilityHelp("Customizes the chat")
        let labelHeight=ceil(NSFont.systemFont(ofSize:g.titleFont,weight:.semibold).ascender-NSFont.systemFont(ofSize:g.titleFont,weight:.semibold).descender)
        nameLabel.font = .systemFont(ofSize:g.titleFont,weight:.semibold)
        nameLabel.stringValue=c.variant == .newChat ? "New Chat":promotionName ?? c.title
        place(nameLabel,CGRect(x:g.title.minX,y:g.title.midY-labelHeight/2,width:g.title.width,height:labelHeight))
        nameLabel.setBoundsSize(nameLabel.frame.size)
        nameBaseRect=nameLabel.frame
        nameLabel.alphaValue=state.expanded || state.hovering ? 1:g.titleOpacity; nameLabel.isHidden=state.editing
        mark.mark=c.signals.mark; mark.configureDots(paused:!c.ambient || !c.active || !presentationActive,reduced:c.reduceMotion,scale:c.scale); mark.isHidden=shape != .compact || c.variant == .newChat || c.signals.mark == nil
        place(mark,CGRect(x:g.title.minX-20,y:g.titleRow.midY-7,width:14,height:14))
        chevron.stringValue=state.expanded ? "⌄":"›"; chevron.font = .systemFont(ofSize:12,weight:.semibold)
        place(chevron,CGRect(x:g.title.maxX+8,y:g.titleRow.midY-8,width:8,height:16)); chevron.isHidden=state.editing || c.variant == .newChat
        let showEvent=g.event != nil && state.activity != nil
        if let r=g.event,let event=state.activity {
            eventBaseRect=r;eventButton.text=event.text; eventButton.symbol=event.symbol
            eventButton.tint=event.urgent ? (event.kind == .error ? .systemRed:.systemYellow):event.kind == .done ? .systemGreen:.secondaryLabelColor
        }
        if !c.active || !presentationActive {eventPhase.reset(visible:showEvent)}
        else if showEvent != wantedEvent {eventPhase.retarget(visible:showEvent,at:now(),reduced:c.reduceMotion)}
        wantedEvent=showEvent
        eventPhase.sample(now());applyEventPose()
        if eventPhase.busy {motionClock.start(in:self)}
        for (i,b) in actionButtons.enumerated() {
            b.isHidden=g.actions.isEmpty && controlsFade == nil
            b.participates=c.active && presentationActive && !g.actions.isEmpty
            if !g.actions.isEmpty { b.frame=g.actions[i] }
        }
        let running=c.signals.satellites.filter { !$0.done }.count
        actionButtons[0].text=running>0 ? "\(running) sub-agent\(running == 1 ? "":"s")":c.signals.satellites.isEmpty ? "0 sub-agents":"\(c.signals.satellites.count) done"
        actionButtons[0].symbol="circle.hexagongrid"; actionButtons[0].isEnabled = !c.signals.satellites.isEmpty
        actionButtons[1].text=c.signals.files == 0 ? "No changes":"\(c.signals.files) file\(c.signals.files == 1 ? "":"s") +\(c.signals.added) −\(c.signals.removed)"
        actionButtons[1].symbol="doc.text"; actionButtons[1].isEnabled=c.signals.files>0
        actionButtons[2].text=c.signals.context.map { "Context \(Int(($0*100).rounded()))%" } ?? "Context unknown"; actionButtons[2].symbol="circle.dashed"
        actionButtons[3].text=c.signals.words; actionButtons[3].symbol="sparkle"
        if let r=g.rename {
            if renameField.superview == nil { controls.addSubview(renameField) }
            renameField.frame=r; renameField.font = .systemFont(ofSize:g.titleFont,weight:.semibold); renameField.participates=c.active && presentationActive
        } else { renameField.participates=false; renameField.removeFromSuperview() }
        var oc=OrbConfiguration(content:c.variant == .newChat ? .seed:.identity(c.identity),drawingSize:56)
        oc.context=c.variant == .newChat ? 0:c.signals.context ?? 0
        oc.running=c.variant != .newChat && c.signals.running
        oc.activitySerial=c.variant == .newChat ? 0:c.activitySerial
        oc.satellites=c.variant == .newChat || c.variant == .collapse ? []:c.signals.satellites
        oc.satellitesRetired=c.satellitesRetired && state.satellitesHoldingUntil == nil; oc.reduceMotion=c.reduceMotion; oc.ambient=c.ambient && c.active && presentationActive; oc.isKeyWindow=c.isKeyWindow; oc.backingScale=c.scale
        oc.orbitShape = .header(g.planet.width).scaled(by:56/g.planet.width)
        oc.satelliteFollowStagger=0
        // Header status lives in the nameplate. Keep body-only completion feedback and compaction; no red alerts or duplicate badge.
        oc.completions=c.variant == .newChat ? 0:c.signals.completions
        oc.compactions=c.variant == .newChat ? 0:c.signals.compactions
        let rows=layoutSatellites(c,g)
        if let row=g.satelliteRow {
            let scale=g.planet.width/56
            oc.satelliteMode = .follow(rows.mapValues { CGPoint(x:($0.x-g.planet.midX)/scale,y:($0.y-g.planet.midY)/scale) })
            oc.satelliteDiameter=16/scale; oc.satelliteVisibleIDs=Set(rows.keys).subtracting(carriedSatellites)
            _ = row
        }
        orb.configure(oc); orb.setFrame(g.planet)
        sampleControlsFade(at:now())
        installMenus(); updateTrackingAreas()
        glyphPlane.textureScale=window?.backingScaleFactor ?? c.scale
        glyphPlane.warmingEnabled=motionExposure.enabled && !c.reduceMotion &&
            !(semanticGaussian && (promotionInProgress || localMotion != nil || lobeMotion != nil || (animated && old != g)))
        glyphPlane.warmTextures()
        if animated && old != g && (c.notices == nil || state.expanded || state.editing) { animateGeometry(from:departure,to:g) }
        else if localMotion != nil { sampleMotion(at:now()) }
        if state.lobeRevision != renderedLobe,shape == state.shape { renderedLobe=state.lobeRevision; popLobe() }
        if old != g { actions.geometry?(g) }
        if canDragOrb {orbDragProvider()?.prepareOrbDrag(from:self)}
        configurePulse(c)
    }

    private func restorePulseContent() {
        for (view,hidden) in pulseSuppressed {view.isHidden=hidden}
        pulseSuppressed=[]
    }

    private func configurePulse(_ c:HeaderIslandConfiguration) {
        guard let notices=c.notices else {pulse?.suspend();return}
        if pulse == nil {
            let view=HeaderPulsePresentation();pulse=view
            view.setModeContentFrozen(modeContentFrozen)
            addSubview(view,positioned:.below,relativeTo:orb.glassView)
            view.onToggle={ [weak self] in self?.togglePin() }
            view.onRename={ [weak self] in self?.beginRename() }
            view.onAction={ [weak self] action in
                guard let self,self.canAct else{return}
                if action == .review {self.pulse?.dismiss();self.route(.transcript)} else {self.actions.noticeAction?(action)}
            }
            view.onPanel={ [weak self] in self?.openPanel($0) }
            view.onExpansion={ [weak self] open,pin in self?.actions.expansion?(open,pin);self?.syncOutsideMonitor() }
            view.onPose={ [weak self] scale in
                guard let self,self.pulseShowing else{return}
                let r=self.geometry.planet
                let frame=CGRect(x:r.midX-r.width*scale/2,y:r.midY-r.height*scale/2,width:r.width*scale,height:r.height*scale)
                // OrbComponent.setFrame places decorations only. The host owns the visible glass geometry.
                self.orb.glassView.frame=frame; self.orb.glassView.cornerRadius=frame.width/2
                self.orb.glassView.contentView?.frame=self.orb.glassView.bounds
                self.orb.setFrame(frame)
                self.planetButton.frame=frame
                if self.hoverTracking?.rect != self.visibleCapsule {self.updateTrackingAreas()}
            }
        }
        let font=c.variant.metrics(band:c.band).font
        let compact=HeaderIslandGeometry.make(variant:c.variant,columnWidth:c.columnWidth,
            state:.init(titleWidth:widths[font] ?? 0,hasMark:c.signals.mark != nil,band:c.band,scale:c.scale))
        let suspended = isHiddenOrHasHiddenAncestor || !c.active || pulsePresentationRetired || hostMotion || state.editing || state.expanded || promotionInProgress
        pulse?.frame=CGRect(x:0,y:0,width:c.columnWidth,height:max(geometry.height,compact.capsule.minY+140))
        pulse?.setAmbientActive(presentationActive)
        pulse?.wallTime=noticeWallTime
        pulse?.configure(notices,input:c,compact:compact.capsule,at:now(),suspended:suspended,interactive:canAct)
        pulse?.setTitleMenu(titleButton.menu)
        guard pulseShowing else{return}
        frame.size.height=max(frame.height,compact.capsule.minY+140)
        for view in [capsule,lobe] + controls.subviews.filter({$0 !== planetButton}) {
            pulseSuppressed.append((view,view.isHidden));view.isHidden=true
        }
        updateTrackingAreas()
    }
    // MARK: Motion (Claude, f069: the column's full ↔ brief / Split / Focused transitions)

    /// The island's compact geometry for another variant and column width, from what it already measured. Pure: no
    /// configure, no text measurement, so the scene can call it every frame.
    func motionGeometry(variant v: HeaderIslandVariant, columnWidth w: CGFloat) -> HeaderIslandGeometry {
        guard let c = configuration else { return geometry }
        let font = v.metrics(band: c.band).font
        let width = v == .newChat || promotionName != nil ? Self.seedTitleWidths[font] ?? 0 : widths[font] ?? 0
        return .make(variant: v, columnWidth: w, state: .init(shape: hostMotion && hostMotionKeepsActivity ? .activity:.compact, titleWidth: width, hasMark: c.signals.mark != nil,
                                                              hasSatellites: false, band: c.band, scale: c.scale))
    }

    /// Prewarm the compact endpoint's text before driver B commits. No live configure/geometry or glass copies.
    func warmMotionTextures(variant:HeaderIslandVariant,columnWidth:CGFloat) {
        guard motionExposure.enabled,configuration?.reduceMotion == false else {return}
        if semanticGaussian && (promotionInProgress || localMotion != nil || lobeMotion != nil) {return}
        if semanticGaussian {glyphPlane.warmingEnabled=true;glyphPlane.warmTextures()}
        let g=motionGeometry(variant:variant,columnWidth:columnWidth)
        let font=NSFont.systemFont(ofSize:g.titleFont,weight:.semibold)
        let height=ceil(font.ascender-font.descender)
        _=glyphPlane.warmDrawing(of:nameLabel,font:font,bounds:CGRect(x:0,y:0,width:g.title.width,height:height))
    }

    /// A transition starts: an open island closes (its expansion, rename and popover end).
    func beginMotion() {
        pulse?.suspend(); restorePulseContent()
        if state.expanded || state.editing || state.pinned { escape() }
        stopMotionExposure()
        if !hostMotion {
            hostMotionTruncatesTitle=(widths[geometry.titleFont] ?? 0)>geometry.title.width+0.5
            hostMotion=true;hostMotionKeepsActivity=state.activity != nil
        }
    }

    /// Driver A while the column moves: the glass, the planet and the name placed on `g` (mixed from two variants), the
    /// name drawn at the configured font scaled by `fontScale`. The island's own frame is the host's.
    func placeMotion(_ g: HeaderIslandGeometry, fontScale: CGFloat, earlier:HeaderIslandGeometry?=nil,
                     earlierOrigin:CGPoint?=nil, earlierFontScale:CGFloat?=nil) {
        motionPose=g
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glassContainer.frame = bounds; glassContainer.contentView?.frame = bounds; controls.frame = bounds
        glyphPlane.frame=controls.bounds
        if glyphPose.frame.size != glyphPlane.bounds.size {glyphPose.setFrameSize(glyphPlane.bounds.size)}
        // applyMotionExposure writes the final real glass frames once; do not lay out the unstretched SDF first.
        orb.setCanvasSize(bounds.size); orb.setFrame(g.planet)
        retiringNames.removeAll { $0.superview == nil }
        for old in retiringNames {
            let base=old.bounds.size
            place(old,CGRect(x:nameBaseRect.midX-base.width/2,y:nameBaseRect.midY-base.height/2,width:base.width,height:base.height))
            old.setBoundsSize(base)
        }
        nameLabel.alphaValue = g.titleOpacity
        mark.frame.origin = CGPoint(x: g.title.minX - 20, y: g.titleRow.midY - 7)
        titleButton.frame = g.titleRow; planetButton.frame = g.planet
        if let event=g.event {eventBaseRect=event}
        applyMotionExposure(g,fontScale:fontScale,earlier:earlier,earlierOrigin:earlierOrigin,earlierFontScale:earlierFontScale)
        applyEventPose()
        CATransaction.commit()
    }

    /// At rest again: the configured layout, exactly.
    func endMotion() {
        stopMotionExposure()
        nameLabel.setBoundsSize(nameLabel.frame.size)
        // What arrived or ended during the motion takes its shape now, on the activity's own spring.
        let changed=hostMotion && hostMotionKeepsActivity == (state.activity == nil)
        hostMotion=false;hostMotionKeepsActivity=false;hostMotionTruncatesTitle=false
        render(animated: changed)
    }

    private static let seedTitleWidths: [CGFloat:CGFloat] = Dictionary(uniqueKeysWithValues: [CGFloat(12),12.5,13,16,17].map { size in
        (size, ceil(("New Chat" as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.semibold)]).width))
    })
    /// Call after configuring the retained conversation as .full. No timers or geometry animation are installed.
    func beginPromotion(seedCenterY:CGFloat) -> HeaderIslandPromotion? {
        guard let c=configuration,c.variant == .full,!disposed else { return nil }
        beginMotion(); promotionInProgress=true; promotionTitleRevealed=false; promotionName="New Chat"
        render(animated:false)
        if semanticGaussian {
            animateName(from:nameLabel.stringValue,frame:nameLabel.frame,font:nameLabel.font,bounds:nameLabel.bounds.size,feedback:false)
            orb.setGlyphGaussianVisible(true,at:now(),initiallyVisible:false,spotlight:true)
        }
        let name=motionGeometry(variant:.full,columnWidth:c.columnWidth)
        let full=HeaderIslandGeometry.make(variant:.full,columnWidth:c.columnWidth,state:.init(titleWidth:widths[13] ?? 0,hasMark:c.signals.mark != nil,band:c.band,scale:c.scale))
        var seed=HeaderIslandGeometry.make(variant:.newChat,columnWidth:c.columnWidth,state:.init(titleWidth:Self.seedTitleWidths[17] ?? 0,band:c.band,scale:c.scale))
        let dy=seedCenterY-seed.planet.midY
        seed.planet.origin.y += dy; seed.capsule.origin.y += dy; seed.title.origin.y += dy; seed.titleRow.origin.y += dy
        seed.height += dy; seed.contentTop += dy
        return HeaderIslandPromotion(seed:seed,launchName:name,full:full,seedCenterY:seedCenterY,columnWidth:c.columnWidth,scale:c.scale,reduceMotion:c.reduceMotion)
    }
    /// Host invokes at elapsed >= plan.titleDelay, before placeMotion(sample.geometry,...). Idempotent.
    func revealPromotionTitle() {
        guard promotionInProgress,!promotionTitleRevealed else { return }
        let old=nameLabel.stringValue,frame=nameLabel.frame,font=nameLabel.font,base=nameLabel.bounds.size
        promotionTitleRevealed=true; promotionName=nil; render(animated:false)
        animateName(from:old,frame:frame,font:font,bounds:base,feedback:false)
    }
    func endPromotion() {
        promotionInProgress=false; promotionName=nil; promotionTitleRevealed=false
        endMotion()
    }
    #if ISLAND_SELFTEST
    var verificationName:String { nameLabel.stringValue }
    #endif

    private func place(_ v:NSView,_ r:CGRect) {
        let s=configuration?.scale ?? 2
        let x=(r.minX*s).rounded()/s,y=(r.minY*s).rounded()/s
        v.frame=CGRect(x:x,y:y,width:(r.maxX*s).rounded()/s-x,height:(r.maxY*s).rounded()/s-y)
    }
    private func layoutSatellites(_ c:HeaderIslandConfiguration,_ g:HeaderIslandGeometry) -> [String:CGPoint] {
        firstHiddenSatellite=nil
        for b in satelliteButtons.values { b.isHidden=true; b.participates=false }
        overflowButton.isHidden=true; divider.isHidden=true
        guard let row=g.satelliteRow else { satelliteOpeners.values.forEach{$0.cancel()}; return [:] }
        let running=c.signals.satellites.filter { !$0.done }
        let done=c.signals.satellites.enumerated().filter { $0.element.done }.sorted { ($0.element.finishedOrder ?? $0.offset)<($1.element.finishedOrder ?? $1.offset) }.map(\.element)
        let plan=HeaderIslandSatellitePlan.make(running:running.count,done:done.count,width:row.width)
        let places=plan.places(width:row.width)
        var targets:[String:CGPoint]=[:]
        func position(_ sat:OrbSatellite,_ x:CGFloat) {
            let point=CGPoint(x:x,y:row.midY); targets[sat.id]=point
            let b=satelliteButtons[sat.id] ?? IslandButton()
            if b.superview == nil { controls.addSubview(b); satelliteButtons[sat.id]=b }
            b.drawsText=false; b.text="Sub-agent \(sat.face)\(sat.done ? ", finished":" , running")"
            b.linkCursor=true;b.circularHit=true;b.drawsPointerHighlight=false
            b.frame=CGRect(x:x-12,y:row.minY,width:24,height:24); b.isHidden=false; b.participates=c.active && presentationActive
            b.invoke={ [weak self] in self?.route(.satellite(sat.id)) }
            let opener=satelliteOpeners[sat.id] ?? SatelliteOpener(satellite:sat,diameter:16)
            satelliteOpeners[sat.id]=opener;opener.satellite=sat
            opener.hiddenAtRest=false
            opener.carryingChanged={ [weak self] carried in
                guard let self else{return}
                if carried {self.carriedSatellites.insert(sat.id)} else {self.carriedSatellites.remove(sat.id)}
                self.render(animated:false)
            }
            opener.admitted={ [weak self] in self?.canAct == true && self?.geometry.satelliteRow != nil }
            opener.open={ [weak self] point in
                guard let self else{return}
                if let open=self.actions.openSatellite {open(sat.id,point)} else if point == nil {self.route(.satellite(sat.id))}
            }
            b.beginPointerGesture={ [weak b,weak opener] event in guard let b else{return nil};return opener?.begin(from:b,event:event) }
        }
        for (i,sat) in running.prefix(plan.running).enumerated() { position(sat,row.minX+places.running[i]) }
        for (i,sat) in done.suffix(plan.done).enumerated() { position(sat,row.minX+places.done[i]) }
        firstHiddenSatellite=HeaderIslandSatellitePlan.firstHidden(shown:Set(targets.keys),running:running,done:done)
        if plan.hidden>0 { overflowButton.isHidden=false; overflowButton.participates=c.active && presentationActive; overflowButton.frame=CGRect(x:row.minX+places.more-12,y:row.minY,width:24,height:24); overflowButton.setAccessibilityLabel("\(plan.hidden) more sub-agents") }
        if plan.divider { divider.isHidden=false; place(divider,CGRect(x:row.minX+places.divider-0.5,y:row.midY-5,width:1,height:10)) }
        for id in satelliteButtons.keys.filter({ id in !c.signals.satellites.contains { $0.id == id } }) {
            satelliteOpeners.removeValue(forKey:id)?.cancel();satelliteButtons.removeValue(forKey:id)?.removeFromSuperview()
        }
        for (id,opener) in satelliteOpeners where targets[id] == nil {opener.cancel()}
        return targets
    }
    private func installMenus() {
        let generation=interactionGeneration
        func admitted(_ header:HeaderIsland)->Bool { header.canAct && header.interactionGeneration == generation }
        for button in [titleButton,planetButton] {
            button.setAccessibilityCustomActions([NSAccessibilityCustomAction(name:"Rename",handler:{ [weak self] in
                guard let self,admitted(self),!self.state.editing,self.configuration?.variant != .newChat else { return false }
                self.beginRename(); return self.state.editing
            })])
        }
        func menu() -> NSMenu {
            let menu=NSMenu(); menu.autoenablesItems=false
            let rename=IslandMenuItem("Rename…") { [weak self] in guard let self,admitted(self) else { return }; self.beginRename() }; rename.isEnabled=canAct && configuration?.variant != .newChat
            menu.addItem(rename); menu.addItem(IslandMenuItem("Customize…") { [weak self] in guard let self,admitted(self) else { return }; self.actions.customize?() })
            let agents=IslandMenuItem("Show Sub-agents") { [weak self] in guard let self,admitted(self) else { return }; self.openPanel(.subAgents) }
            agents.isEnabled = !(configuration?.signals.satellites.isEmpty ?? true); menu.addItem(agents); return menu
        }
        titleButton.menu=menu(); planetButton.menu=menu()
    }
    private func route(_ route:HeaderIslandRoute) {
        guard canAct else { return }
        if case .panel(let panel)=route { openPanel(panel) }
        else { actions.route?(route); state.outside(); render(animated:true); schedule(); publishExpansion() }
    }
    func openPanel(_ panel:HeaderIslandPanel) {
        guard canAct else { return }
        if panel == .subAgents,actions.subAgents != nil { openSubAgents(select:nil); return }
        state.setExpanded(true,pinned:true); render(animated:true); schedule(); publishExpansion()
        actions.route?(.panel(panel))
        guard window != nil else { return }
        popover?.close()
        let p=NSPopover(); p.behavior = .semitransient; p.delegate=self
        p.contentViewController=makePanelContent(panel); p.contentSize=CGSize(width:360,height:420)
        popover=p
        let index=HeaderIslandPanel.allCases.firstIndex(of:panel)!
        p.show(relativeTo:actionButtons[index].bounds,of:actionButtons[index],preferredEdge:.maxY)
    }
    private func openSubAgents(select:String?) {
        guard canAct else { return }
        guard let open=actions.subAgents else { openPanel(.subAgents); return }
        // Capture before collapsing: the host owns conversion, direction, one-sheet lifetime and focus.
        let anchor=frame
        popover?.close(); popover=nil
        state.outside(); render(animated:true); schedule(); publishExpansion()
        open(anchor,select)
    }
    #if ISLAND_SELFTEST
    var verificationOverflowButton:IslandButton { overflowButton }
    var verificationFirstHidden:String? { firstHiddenSatellite }
    var verificationHasPopover:Bool { popover != nil }
    var verificationGlassTints:[NSColor?] { [orb.glassView.tintColor,capsule.tintColor,lobe.tintColor] }
    var verificationShadow:Float { capsule.layer?.shadowOpacity ?? 0 }
    #endif
    func makePanelContent(_ panel:HeaderIslandPanel) -> NSViewController {
        if let controller=panelContent?(panel) { return controller }
        var input=configuration!; input.canCompact = input.canCompact && actions.compact != nil
        return HeaderIslandPanelController(panel:panel,configuration:input,route:{ [weak self] in self?.route($0) },compact:{ [weak self] in guard let self,self.canAct,self.configuration?.canCompact == true else { return }; self.actions.compact?() })
    }
    func popoverDidClose(_ notification:Notification) { if let closed=notification.object as? NSPopover,closed === popover { popover=nil } }

    private func schedule() {
        timer?.invalidate(); timer=nil
        // Not canAct: that goes false when the window has been idle for 8 s (the ambient hold), and an event line then
        // stayed on screen until the next input (user 10-30; 14.7 s with a 2.2 s hold in a real-path run).
        guard !disposed,configuration?.active == true,let deadline=state.nextDeadline else { return }
        let timer=Timer(timeInterval:max(0.001,deadline-now()),repeats:false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.advance(to:self.now())
            }
        }
        self.timer=timer; RunLoop.main.add(timer,forMode:.common)
    }
    private func syncOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor=nil }
        guard canAct,window != nil else { return }
        outsideMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.keyDown]) { [weak self] event in
            let consumed=MainActor.assumeIsolated { self?.consumeLocalEvent(event) ?? false }
            return consumed ? nil:event
        }
    }
    private func consumeLocalEvent(_ event:NSEvent) -> Bool {
        guard event.window === window else { return false }
        if event.type == .keyDown,event.keyCode == 53,let opener=satelliteOpeners.values.first(where:{$0.isPressed}) {opener.cancel();return true}
        // A sibling island's activity/expansion monitor may run before the drag monitor. Whichever sees
        // Esc first cancels the SAME scene gesture; it must not merely dismiss an unrelated nameplate.
        if event.type == .keyDown,event.keyCode == 53,orbDragProvider()?.cancelOrbDrag() == true { return true }
        guard canAct else { return false }
        if event.type == .keyDown,event.keyCode == 53,state.expanded || state.editing || state.activity != nil || pulseShowing && pulse?.state.mode != .compact { escape(); return true }
        if event.type == .leftMouseDown,popover == nil,(state.expanded || state.editing || pulseShowing && pulse?.state.pinned == true),!visibleCapsule.union(visiblePlanet).insetBy(dx:-4,dy:-4).contains(convert(event.locationInWindow,from:nil)) {
            let editing=state.editing; outsideClick(); return !editing
        }
        return false
    }
    #if ISLAND_SELFTEST || M10_DOCK_SELFTEST
    func verificationLocalEvent(_ event:NSEvent)->Bool {consumeLocalEvent(event)}
    #endif
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area=NSTrackingArea(rect:visibleCapsule,options:[.mouseEnteredAndExited,.activeInKeyWindow],owner:self)
        addTrackingArea(area); hoverTracking=area; super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hover(NativePointerShield.permits(self,localPoint:convert(event.locationInWindow,from:nil))) }
    override func mouseExited(with event:NSEvent) { hover(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); syncOutsideMonitor()
        if window == nil { satelliteOpeners.values.forEach{$0.cancel()}; stopMotionExposure() }
        else if localMotion != nil || lobeMotion != nil { motionClock.start(in:self) }
    }
    private var visibleCapsule:CGRect { pulseShowing ? pulse!.capsuleFrame:capsule.frame }
    private var visiblePlanet:CGRect { orb.glassView.frame }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard canAct,!isHiddenOrHasHiddenAncestor,NativePointerShield.permits(self,localPoint:convert(point,from:superview)) else { return nil }
        let p=convert(point,from:superview)
        // Planet owns the overlap, and its visible circle rather than its square bounds is the target.
        let r=visiblePlanet, dx=(p.x-r.midX)/(r.width/2),dy=(p.y-r.midY)/(r.height/2)
        if !orbIsCarried,dx*dx+dy*dy<=1 { return planetButton }
        if pulseShowing {return pulse?.hitTest(p)}
        let radius=capsule.cornerRadius // the real SDF radius; the backing CALayer's cornerRadius is not the glass
        guard NSBezierPath(roundedRect:visibleCapsule,xRadius:radius,yRadius:radius).contains(p) else { return nil }
        // Rename width springs can leave the visible plate wider than the model title button.
        // Its complete visible compact plate remains the same title action during that tail.
        if state.shape == .compact { return titleButton.participates ? titleButton:nil }
        return super.hitTest(point)
    }
    func dispose() {
        restorePulseContent();pulse?.dispose()
        satelliteOpeners.values.forEach{$0.cancel()};satelliteOpeners=[:]
        state.escape(); disposed=true; interactionGeneration+=1; setAccessibilityHidden(true)
        for b in [titleButton,planetButton,eventButton,overflowButton]+actionButtons+Array(satelliteButtons.values) { b.participates=false }
        timer?.invalidate(); timer=nil; lobeTask?.cancel(); popover?.close(); endInput(); orb.dispose()
        stopMotionExposure()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor=nil }
    }
}

extension HeaderIsland {
    private var exposureProfile:DisplayProfile {
        window?.screen.map(DisplayProfile.of) ?? motionProfile ?? DisplayProfile(name:"offscreen island",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
    }
    private func stopMotionExposure() {
        localMotion=nil; lobeMotion=nil; motionClock.stop(); glyphPlane.reset(); controls.layer?.mask=nil
        nameGaussian?.setVisible(true,animated:false);nameGaussian=nil
        for effect in outgoingGaussians {
            effect.setVisible(false,animated:false)
            retiringNames.first{$0.layer === effect.layer}?.removeFromSuperview()
        }
        outgoingGaussians=[];retiringNames.removeAll{$0.superview == nil}
        orb.resetGlyphGaussian()
        controlsFade=nil;controlsOpacity=geometry.actions.isEmpty ? 0:1
        for b in actionButtons {b.alphaValue=controlsOpacity;b.isHidden=geometry.actions.isEmpty}
        glyphPose.layer?.transform=CATransform3DIdentity;glyphPose.setFrameOrigin(.zero)
        orb.exposeGlyphs(now:geometry.planet,earlier:geometry.planet,profile:exposureProfile,enabled:false)
        lastMotion=nil; motionRecords=[]; lobe.isHidden=true
        for key in ["island.bounds.size","island.position","island.radius"] { capsule.layer?.removeAnimation(forKey:key) }
    }
    private func applyMotionExposure(_ g:HeaderIslandGeometry,fontScale:CGFloat,earlier:HeaderIslandGeometry?,earlierOrigin:CGPoint?,earlierFontScale:CGFloat?) {
        let origin=frame.origin
        var previous=earlier ?? lastMotion?.geometry ?? g
        var oldOrigin=earlierOrigin ?? lastMotion?.origin ?? origin
        if earlier == nil,lastMotion != nil {
            let k=CGFloat(motionExposure.shutter)
            previous = .mix(g,previous,k)
            oldOrigin=CGPoint(x:origin.x+(oldOrigin.x-origin.x)*k,y:origin.y+(oldOrigin.y-origin.y)*k)
        }
        let profile=exposureProfile
        var settings=motionExposure
        settings.enabled = settings.enabled && configuration?.reduceMotion != true && presentationActive && !isHiddenOrHasHiddenAncestor
        func world(_ r:CGRect,_ o:CGPoint)->CGRect { r.offsetBy(dx:o.x,dy:o.y) }
        func local(_ r:CGRect)->CGRect { r.offsetBy(dx:-origin.x,dy:-origin.y) }
        func glass(_ now:CGRect,_ old:CGRect,_ view:NSGlassEffectView,_ radius:CGFloat,_ id:String) {
            let sample=ExposureSample(now:now,earlier:old,frameInterval:profile.frameInterval,mmPerPoint:profile.mmPerPoint,settings:settings)
            var treated=IslandGlassExposure.frame(now:now,earlier:old,profile:profile,settings:settings)
            if sample.gate>0 {
                let s=configuration?.scale ?? 1
                let x=floor((treated.minX-origin.x)*s)/s+origin.x, y=floor((treated.minY-origin.y)*s)/s+origin.y
                treated=CGRect(x:x,y:y,width:ceil((treated.maxX-origin.x)*s)/s+origin.x-x,height:ceil((treated.maxY-origin.y)*s)/s+origin.y-y)
            }
            let frame=local(treated),round=radius+(min(treated.width,treated.height)/2-radius)*sample.gate
            if view.frame != frame {view.frame=frame}
            if view.cornerRadius != round {view.cornerRadius=round}
            if view.contentView?.frame != view.bounds {view.contentView?.frame=view.bounds}
            motionRecords.append(.init(material:id,now:now,earlier:old,treated:treated,sample:sample,shutter:settings.shutter))
        }
        motionRecords=[]
        glass(world(g.capsule,origin),world(previous.capsule,oldOrigin),capsule,g.radius,"island.glass")
        glass(world(g.planet,origin),world(previous.planet,oldOrigin),orb.glassView,g.planet.width/2,"island.planetGlass")
        // M10-F owns the identity/seed ink. Its public host-motion entry excludes both the liquid and the glass.
        let semanticZoom = semanticGaussian && (promotionInProgress || localMotion != nil || lobeMotion != nil)
        orb.exposeGlyphs(now:world(g.planet,origin),earlier:world(previous.planet,oldOrigin),profile:profile,enabled:settings.enabled && !semanticZoom)
        let k=max(0.01,fontScale)
        var baseRect=nameBaseRect
        // Promotion retains its authored seed-to-title choreography.
        let constrained=hostMotion && hostMotionTruncatesTitle && !promotionInProgress && configuration?.variant != .newChat
        if constrained {
            // A truncated title uses the moving capsule's available width, not the destination's truncation.
            // Keep its native drawing inside the pose view so AppKit can draw the whole label and arrow.
            baseRect.origin.x=0;baseRect.size.width=g.title.width/k
            nameLabel.frame=baseRect;nameLabel.setBoundsSize(baseRect.size);nameBaseRect=baseRect
        }
        let dx=constrained ? 0:baseRect.midX-geometry.title.midX,dy=baseRect.midY-geometry.title.midY
        let current=CGRect(x:g.title.midX+(dx-baseRect.width/2)*k,y:g.title.midY+(dy-baseRect.height/2)*k,width:baseRect.width*k,height:baseRect.height*k)
        // Canonical, pixel-aligned native glyphs stay laid out once. Their glyph-only parent follows the analytic
        // subpixel pose: rounding the moving native frame held then jumped whole pixels near the spring's tail.
        // Only while the column moves: the island's own motion (expansion, the planets' island) is as it was.
        // AppKit doesn't see the pose. Laid out for a wider end, a label can stand past the window's edge as far as AppKit knows, and
        // then it isn't drawn: the right column's arrow was gone for the first 24–42 ms of a switch (board 261031j). So the pose's view
        // stands where the glyphs show, whole points, and the transform keeps the rest.
        let shift=hostMotion ? (current.minX-baseRect.minX).rounded():0
        if glyphPose.frame.minX != shift {glyphPose.setFrameOrigin(CGPoint(x:shift,y:glyphPose.frame.minY))}
        var pose=CATransform3DMakeTranslation(current.minX-shift,current.minY,0)
        pose=CATransform3DScale(pose,k,k,1);pose=CATransform3DTranslate(pose,-baseRect.minX,-baseRect.minY,0)
        glyphPose.layer?.transform = abs(k-1)<1e-12 && abs(current.minX-baseRect.minX)<1e-9 && abs(current.minY-baseRect.minY)<1e-9 ? CATransform3DIdentity:pose
        // The arrow follows the name's moving width, as the product's arrowRect does; the name itself takes its end's truncation at once, as there.
        if hostMotion {chevron.setFrameOrigin(CGPoint(x:baseRect.minX+(g.title.maxX+8-current.minX)/k,y:baseRect.minY+(g.titleRow.midY-8-current.minY)/k))}
        let base=nameBaseRect.size,oldK=earlierFontScale ?? lastMotion?.fontScale ?? fontScale
        let oldName:CGRect
        if earlier == nil,let lastMotion {
            let r=lastMotion.name,s=CGFloat(settings.shutter)
            oldName=CGRect(x:current.minX+(r.minX-current.minX)*s,y:current.minY+(r.minY-current.minY)*s,
                width:current.width+(r.width-current.width)*s,height:current.height+(r.height-current.height)*s)
        }
        else { oldName=CGRect(x:previous.title.midX+(dx-base.width/2)*oldK,y:previous.title.midY+(dy-base.height/2)*oldK,width:base.width*oldK,height:base.height*oldK) }
        let old=world(oldName,oldOrigin), now=world(current,origin)
        glyphPlane.textureScale=window?.backingScaleFactor ?? configuration?.scale ?? 2
        var glyphSettings=settings
        if semanticZoom {glyphSettings.enabled=false}
        glyphPlane.update(now:current,earlier:local(old),profile:profile,settings:glyphSettings,epoch:nameAnimationBegan)
        nameGaussian?.settle(at:self.now())
        outgoingGaussians.removeAll { effect in
            guard effect.settle(at:self.now()) else{return false}
            retiringNames.first{$0.layer === effect.layer}?.removeFromSuperview();return true
        }
        retiringNames.removeAll{$0.superview == nil}
        orb.settleGlyphGaussian(at:self.now())
        motionRecords.append(.init(material:"island.name",now:now,earlier:old,treated:now,sample:glyphPlane.sample,shutter:settings.shutter))
        lastMotion=(g,origin,current,fontScale)
    }
    /// Offscreen and scene-owned driving use the same entry as the display link. No fixed 1/60 Timer.
    func sampleMotion(at time:Double) {
        pulse?.sample(at:time)
        guard !disposed else { return }
        let dt=exposureProfile.frameInterval*motionExposure.shutter
        if let m=localMotion {
            let elapsed=time-m.began, u=CGFloat(m.spring.sample(elapsed).value), old=CGFloat(m.spring.sample(elapsed-dt).value)
            placeMotion(.mix(m.from,m.to,u),fontScale:1,earlier:.mix(m.from,m.to,old),earlierOrigin:frame.origin,earlierFontScale:1)
            if elapsed>=m.spring.duration { localMotion=nil; glyphPlane.reset(); lastMotion=nil; motionPose=nil }
        }
        if let m=lobeMotion {
            func rect(_ t:Double)->CGRect {
                let t=max(0,min(0.16,t)),p=CGFloat(t<0.07 ? t/0.07:1-(t-0.07)/0.09),s=0.6+0.4*p
                return CGRect(x:m.base.midX+12*p-m.base.width*s/2,y:m.base.midY-m.base.height*s/2,width:m.base.width*s,height:m.base.height*s)
            }
            let r=rect(time-m.began),old=rect(time-m.began-dt)
            var settings=motionExposure; settings.enabled = settings.enabled && configuration?.reduceMotion != true
            let sample=ExposureSample(now:r,earlier:old,frameInterval:dt,mmPerPoint:exposureProfile.mmPerPoint,settings:settings)
            let treated=IslandGlassExposure.frame(now:r,earlier:old,profile:exposureProfile,settings:settings)
            lobe.frame=treated; lobe.cornerRadius=min(treated.width,treated.height)/2
            motionRecords.removeAll { $0.material == "island.lobe" }
            motionRecords.append(.init(material:"island.lobe",now:r,earlier:old,treated:treated,sample:sample,shutter:settings.shutter))
            if time-m.began>=0.18 { lobe.isHidden=true; lobeMotion=nil }
        }
        sampleControlsFade(at:time)
        eventPhase.sample(time);applyEventPose()
        clipControlsToCapsule()
        if localMotion == nil && lobeMotion == nil && controlsFade == nil && !eventPhase.busy { motionClock.stop() }
    }
    /// Keep the outgoing drawing until its own fade ends. The live SDF clips text during both glass springs.
    private func applyEventPose() {
        CATransaction.begin();CATransaction.setDisableActions(true);defer {CATransaction.commit()}
        let p=eventPhase.pose
        eventButton.frame=eventBaseRect.offsetBy(dx:0,dy:p.offsetY)
        eventButton.alphaValue=p.opacity
        eventButton.isHidden = !wantedEvent && !eventPhase.busy
        eventButton.participates=wantedEvent && p.opacity>0 && configuration?.active == true && presentationActive
        if let layer=eventButton.layer,let eventBlur {
            // CA gaussianBlur uses layer points, as ContentGaussianTransition does: product radius 2pt.
            // Install once per phase and notify CA through the named key path, not a mutable CIFilter.
            if p.blur>0 {
                if layer.filters?.isEmpty != false {layer.filters=[eventBlur]}
                layer.setValue(true,forKeyPath:"filters.islandEventBlur.enabled")
                layer.setValue(p.blur,forKeyPath:"filters.islandEventBlur.inputRadius")
            } else if layer.filters?.isEmpty == false {
                layer.setValue(0,forKeyPath:"filters.islandEventBlur.inputRadius")
                layer.setValue(false,forKeyPath:"filters.islandEventBlur.enabled")
                layer.filters=nil
            }
        }
        if wantedEvent || eventPhase.busy {
            let r=capsule.frame.offsetBy(dx:-eventButton.frame.minX,dy:-eventButton.frame.minY)
            eventMask.frame=eventButton.bounds
            eventMask.isGeometryFlipped=eventButton.layer?.isGeometryFlipped ?? false
            eventMask.path=CGPath(roundedRect:r,cornerWidth:capsule.cornerRadius,cornerHeight:capsule.cornerRadius,transform:nil)
            if eventButton.layer?.mask !== eventMask {eventButton.layer?.mask=eventMask}
        } else {eventButton.layer?.mask=nil}
    }
    /// The detail rows' fade is authored apart from the capsule's spring, and a close outruns it: they hung below the
    /// glass for a tenth of a second (board 10-31). Only while there are rows and something moves; activity lines have none.
    private func clipControlsToCapsule() {
        guard localMotion != nil || controlsFade != nil,actionButtons.contains(where:{!$0.isHidden}) else {
            if controls.layer?.mask != nil { controls.layer?.mask=nil }
            return
        }
        let r=capsule.frame.insetBy(dx:-1,dy:-1),radius=min(capsule.cornerRadius+1,min(r.width,r.height)/2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        controlsMask.frame=controls.bounds; controlsMask.isGeometryFlipped=controls.layer?.isGeometryFlipped ?? false
        controlsMask.path=CGPath(roundedRect:r,cornerWidth:radius,cornerHeight:radius,transform:nil)
        if controls.layer?.mask == nil { controls.layer?.mask=controlsMask }
        CATransaction.commit()
    }
    private func sampleControlsFade(at time:Double) {
        if let fade=controlsFade {
            controlsOpacity=fade.value(at:time)
            if fade.complete(at:time) {controlsFade=nil}
        }
        for b in actionButtons {
            b.alphaValue=controlsOpacity
            b.isHidden=geometry.actions.isEmpty && controlsFade == nil
        }
    }
    var motionIsRunning:Bool { localMotion != nil || lobeMotion != nil || controlsFade != nil || eventPhase.busy || pulseShowing && pulse?.motion?.busy == true }
    #if M10_DOCK_SELFTEST
    var verificationRetiringNameCount:Int {retiringNames.filter{$0.superview != nil}.count}
    #endif
    var contentGaussianPoses:[ContentGaussianTransition.Pose] {
        ([nameGaussian].compactMap{$0}+outgoingGaussians).map{$0.pose(at:now())}
    }
    var motionGlyphLayer:CAReplicatorLayer { glyphPlane.trail.layer }
    var motionGlyphRect:CGRect { nameBaseRect.applying(CATransform3DGetAffineTransform(glyphPose.layer?.transform ?? CATransform3DIdentity)).offsetBy(dx:glyphPose.frame.minX,dy:0) }
    var glassHasExposureTransform:Bool {
        [capsule,lobe,orb.glassView].contains { view in
            if let layer=view.layer,!CATransform3DIsIdentity(layer.transform) {return true}
            var parent=view.superview
            while let p=parent {if p is IslandGlyphPlane{return true};parent=p.superview}
            return false
        }
    }
}

private extension HeaderIsland {
    func animateGeometry(from old:HeaderIslandGeometry,to next:HeaderIslandGeometry) {
        guard let c=configuration else { return }
        if let screen=window?.screen {motionProfile=DisplayProfile.of(screen)}
        let layer=capsule.layer
        let response:Double,damping:Double
        switch state.timing {
        case .activityIn:(response,damping)=(0.30,0.76)
        case .activityOut:(response,damping)=(0.26,0.88)
        case .expand:(response,damping)=(0.34,0.80)
        case .close:(response,damping)=(0.28,0.90)
        case .rename:(response,damping)=(0.24,0.82)
        case .renameCommit:(response,damping)=(0.24,0.72)
        case .immediate:return
        }
        if c.reduceMotion {
            switch state.timing {
            case .activityIn,.activityOut:controls.layer?.removeAnimation(forKey:"island.fade")
            default:
                let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=0.7;fade.toValue=1;fade.duration=0.12
                controls.layer?.add(fade,forKey:"island.fade")
            }
            layer?.removeAllAnimations();return
        }
        // P2/§5.2: layer bounds animation does not relayout NSGlassEffectView's SDF. Size and round ends must be real.
        for key in ["island.bounds.size","island.position","island.radius"] { layer?.removeAnimation(forKey:key) }
        let extent=max(1,Double(MotionStep.edge(old.capsule,next.capsule)))
        let spring=Spring(from:0,to:1,response:response,damping:damping,epsilon:Spring.restEpsilon/extent)
        localMotion=(old,next,now(),spring)
        if semanticGaussian {animateName(from:nameLabel.stringValue,frame:nameLabel.frame,font:nameLabel.font,bounds:nameLabel.bounds.size,feedback:false)}
        sampleMotion(at:now()); motionClock.start(in:self)
        layer?.shadowOpacity=OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 0:(state.expanded ? 0.18:0.08); layer?.shadowRadius=state.expanded ? 18:4; layer?.shadowOffset=CGSize(width:0,height:3)
        // The controls' existing authored reveal/removal is sampled independently, including interrupted alpha.
    }
    static func spring(_ key:String,response:Double,damping:Double) -> CASpringAnimation {
        let a=CASpringAnimation(keyPath:key),omega=2*Double.pi/response
        a.mass=1; a.stiffness=omega*omega; a.damping=2*damping*omega; a.duration=a.settlingDuration
        return a
    }
    func popLobe() {
        guard let c=configuration,!c.reduceMotion,c.active,state.activity != nil else { return }
        if let screen=window?.screen {motionProfile=DisplayProfile.of(screen)}
        lobeTask?.cancel(); lobe.isHidden=false
        lobe.frame=CGRect(x:geometry.capsule.maxX-24,y:geometry.capsule.minY+6,width:20,height:20)
        lobe.layer?.removeAllAnimations()
        if semanticGaussian {animateName(from:nameLabel.stringValue,frame:nameLabel.frame,font:nameLabel.font,bounds:nameLabel.bounds.size,feedback:false)}
        lobeMotion=(lobe.frame,now()); sampleMotion(at:now()); motionClock.start(in:self)
    }
    func animateName(from old:String,frame oldFrame:CGRect,font oldFont:NSFont?,bounds oldBounds:CGSize?=nil,feedback:Bool=true) {
        guard let c=configuration else { return }
        let outgoing=IslandLabel(labelWithString:old)
        outgoing.font=oldFont; outgoing.textColor=nameLabel.textColor; outgoing.frame=oldFrame
        outgoing.setBoundsSize(oldBounds ?? oldFrame.size); retiringNames.append(outgoing)
        outgoing.isBordered=false; outgoing.isBezeled=false; outgoing.drawsBackground=false; outgoing.setAccessibilityElement(false)
        outgoing.wantsLayer=true; glyphPose.addSubview(outgoing)
        exposureOutgoingName=outgoing; nameAnimationBegan=now()
        if semanticGaussian,let oldLayer=outgoing.layer,let newLayer=nameLabel.layer {
            glyphPlane.reset()
            // Native own-draw labels only. No glass/backing clone and no texture preparation on a motion frame.
            for key in ["island.name.in","island.name.fall","island.name.blur"] {newLayer.removeAnimation(forKey:key)}
            newLayer.filters=nil
            let began=now(),prior=nameGaussian,priorPlan=prior?.plan
            // The current incoming always started from its hidden pose. Recreate that exact public Plan on
            // the outgoing drawing, then reverse it. Existing old drawings reverse at the SAME timestamp.
            // Their alpha/velocity sum stays complementary even when expansion is interrupted at 37ms.
            var duration=ContentGaussianTransition.Configuration.system.duration
            for effect in outgoingGaussians {
                let alpha=effect.pose(at:began).opacity,velocity=effect.plan?.velocity(at:began).opacity ?? 0
                if alpha>0,velocity<0 {duration=min(duration,2*alpha / -velocity)}
            }
            duration=max(1/240,duration)
            for effect in outgoingGaussians {effect.configuration.duration=duration;effect.setVisible(false,at:began)}
            let old=ContentGaussianTransition(content:oldLayer,clock:gaussianClock,initiallyVisible:priorPlan == nil,
                configuration:prior?.configuration ?? .system)
            if let priorPlan {old.setVisible(true,at:priorPlan.began)}
            old.configuration.duration=duration
            prior?.setVisible(true,animated:false)
            let new=ContentGaussianTransition(content:newLayer,clock:gaussianClock,initiallyVisible:false,
                configuration:promotionInProgress ? .spotlight:.system)
            new.configuration.duration=duration
            nameGaussian=new;outgoingGaussians.append(old)
            ContentGaussianTransition.replace(old:old,new:new,at:began)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.11) { [weak self] in
                guard let self else{return}
                let finish=began+0.11
                new.settle(at:finish)
                self.outgoingGaussians.removeAll { effect in
                    guard (effect.endTime ?? 0)<=finish else{return false}
                    effect.settle(at:finish)
                    self.retiringNames.first{$0.layer === effect.layer}?.removeFromSuperview()
                    return true
                }
            }
            if feedback {orb.animateHeaderRename()}
            return
        }
        let out=CABasicAnimation(keyPath:"opacity"); out.fromValue=1; out.toValue=0; out.duration=0.05; out.timingFunction=CAMediaTimingFunction(name:.easeOut)
        outgoing.alphaValue=0; outgoing.layer?.add(out,forKey:"island.name.out")
        if !c.reduceMotion {
            let lift=CABasicAnimation(keyPath:"transform.translation.y"); lift.fromValue=0; lift.toValue = -3; lift.duration=0.05
            outgoing.layer?.add(lift,forKey:"island.name.lift")
            let fall=CABasicAnimation(keyPath:"transform.translation.y"); fall.fromValue=4; fall.toValue=0; fall.duration=0.1; fall.timingFunction=CAMediaTimingFunction(name:.easeOut); fall.beginTime=CACurrentMediaTime()+0.05; fall.fillMode = .backwards
            nameLabel.layer?.add(fall,forKey:"island.name.fall")
            let blur=CIFilter(name:"CIGaussianBlur")!; blur.name="islandRenameBlur"; blur.setValue(0,forKey:kCIInputRadiusKey)
            nameLabel.layer?.filters=[blur]
            let clear=CABasicAnimation(keyPath:"filters.islandRenameBlur.inputRadius"); clear.fromValue=2; clear.toValue=0; clear.duration=0.1; clear.beginTime=fall.beginTime; clear.fillMode = .backwards
            nameLabel.layer?.add(clear,forKey:"island.name.blur"); if feedback { orb.animateHeaderRename() }
        }
        let incoming=CABasicAnimation(keyPath:"opacity"); incoming.fromValue=0; incoming.toValue=1; incoming.duration=c.reduceMotion ? 0.12:0.1
        incoming.timingFunction=CAMediaTimingFunction(name:.easeOut)
        incoming.beginTime=CACurrentMediaTime()+(c.reduceMotion ? 0:0.05); incoming.fillMode = .backwards
        nameLabel.layer?.add(incoming,forKey:"island.name.in")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak outgoing] in outgoing?.removeFromSuperview() }
    }
}

extension HeaderIsland {
    /// Capture the actual endpoint with its window's cache representation. Call before hiding it.
    /// Freeze decorations across the flight with setPresentationActive(false), then resume at rest.
    func snapshot(scale:CGFloat?=nil) -> CGImage {
        let s=scale ?? configuration?.scale ?? 2
        layoutSubtreeIfNeeded(); displayIfNeeded()
        if window != nil { return NativeViewBitmap.capture(self,scale:s) }
        // No render-server backdrop exists offscreen. A clearly documented glass proxy is used only here.
        // cacheDisplay also bypasses the existing CA name fade/lift. Sample that authored animation on the injected
        // clock for the proxy; otherwise the product's 0.05/0.10 fade appears as an artificial one-frame text swap.
        let oldAlpha=nameLabel.alphaValue,oldFrame=nameLabel.frame
        let outgoingAlpha=exposureOutgoingName?.alphaValue, outgoingFrame=exposureOutgoingName?.frame
        if promotionInProgress,let began=nameAnimationBegan {
            let elapsed=now()-began
            if elapsed>=0,elapsed<0.18 {
                func ease(_ t:Double)->CGFloat {
                    let x=min(1,max(0,t));var lo=0.0,hi=1.0
                    for _ in 0..<24 {let u=(lo+hi)/2,bx=3*0.58*(1-u)*u*u+u*u*u;if bx<x{lo=u}else{hi=u}}
                    let u=(lo+hi)/2;return CGFloat(3*(1-u)*u*u+u*u*u)
                }
                let reduced=configuration?.reduceMotion == true
                let incoming=ease((elapsed-(reduced ? 0:0.05))/(reduced ? 0.12:0.10))
                nameLabel.alphaValue=oldAlpha*incoming
                if !reduced {nameLabel.frame.origin.y += 4*(1-incoming)}
                exposureOutgoingName?.alphaValue=1-ease(elapsed/0.05)
                if !reduced,let outgoingFrame {exposureOutgoingName?.frame.origin.y=outgoingFrame.minY-3*CGFloat(min(1,elapsed/0.05))}
            } else if elapsed>=0.18 {nameAnimationBegan=nil}
        }
        defer {
            nameLabel.alphaValue=oldAlpha;nameLabel.frame=oldFrame
            if let outgoingAlpha {exposureOutgoingName?.alphaValue=outgoingAlpha}
            if let outgoingFrame {exposureOutgoingName?.frame=outgoingFrame}
        }
        glassContainer.isHidden=true; orb.glassView.isHidden=true; orb.backView.isHidden=true; orb.frontView.isHidden=true
        if pulseShowing {pulse?.setOffscreenGlassHidden(true)}
        // The view's whole-point stand and its transform as one pose, around a capture of the labels where they are laid out.
        let poseStand=glyphPose.frame.minX,poseRest=glyphPose.layer?.transform ?? CATransform3DIdentity
        let nativePose=CATransform3DConcat(poseRest,CATransform3DMakeTranslation(poseStand,0,0))
        let accumulate=glyphPlane.sample.count>1 || !CATransform3DIsIdentity(nativePose)
        let savedCount=glyphPlane.trail.layer.instanceCount,savedColor=glyphPlane.trail.layer.instanceColor
        if accumulate {glyphPose.setFrameOrigin(.zero);glyphPose.layer?.transform=CATransform3DIdentity;glyphPlane.trail.layer.instanceCount=1;glyphPlane.trail.layer.instanceColor=NSColor.white.cgColor}
        let glyphs=accumulate ? NativeViewBitmap.capture(glyphPlane,scale:s):nil
        if accumulate {glyphPose.setFrameOrigin(CGPoint(x:poseStand,y:0));glyphPose.layer?.transform=poseRest;glyphPlane.trail.layer.instanceCount=savedCount;glyphPlane.trail.layer.instanceColor=savedColor}
        if accumulate { glyphPlane.isHidden=true }
        let native=NativeViewBitmap.capture(self,scale:s)
        if pulseShowing {pulse?.setOffscreenGlassHidden(false)}
        if accumulate { glyphPlane.isHidden=false }
        glassContainer.isHidden=false; orb.glassView.isHidden=orbIsCarried; orb.backView.isHidden=orbIsCarried; orb.frontView.isHidden=orbIsCarried
        let context=CGContext(data:nil,width:Int(ceil(bounds.width*s)),height:Int(ceil(bounds.height*s)),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.saveGState(); context.translateBy(x:0,y:CGFloat(context.height)); context.scaleBy(x:s,y:-s)
        let pose=motionPose ?? geometry
        let radius=pulseShowing ? pulse!.capsuleRadius:capsule.cornerRadius
        let capsulePath=CGPath(roundedRect:visibleCapsule,cornerWidth:radius,cornerHeight:radius,transform:nil)
        context.setFillColor(OrbDisplayEnvironment.surface(NSColor(white:0.18,alpha:1),opacity:0.92).cgColor); context.addPath(capsulePath); context.fillPath()
        if !lobe.isHidden { context.fillEllipse(in:lobe.frame) }
        if !orbIsCarried { orb.renderOffscreenDecorations(in:context,planet:pulseShowing ? orb.glassView.frame:pose.planet) }
        context.restoreGState()
        context.draw(native,in:CGRect(x:0,y:0,width:context.width,height:context.height))
        if let glyphs {
            // cacheDisplay bypasses CAReplicatorLayer. Replay the exact instance transform for this OFFSCREEN proxy;
            // the real window uses the original native control layers directly, including their authored filters.
            let trail=glyphPlane.trail, sample=glyphPlane.sample, tr=trail.layer.instanceTransform
            let pose=CATransform3DGetAffineTransform(nativePose)
            let step=CGAffineTransform(a:tr.m11,b:tr.m12,c:tr.m21,d:tr.m22,tx:tr.m41,ty:tr.m42)
            var transforms=[CGAffineTransform.identity]
            for _ in 1..<sample.count { transforms.append(transforms.last!.concatenating(step)) }
            for t in transforms.reversed() {
                context.saveGState(); context.translateBy(x:0,y:CGFloat(context.height)); context.scaleBy(x:s,y:-s)
                context.concatenate(pose.concatenating(t)); context.translateBy(x:0,y:glyphPlane.bounds.height); context.scaleBy(x:1,y:-1)
                let pixels=CGAffineTransform(scaleX:1/s,y:1/s).concatenating(context.ctm)
                context.restoreGState()
                if let image=IslandGlyphBitmapPose.image(glyphs,transform:pixels,width:context.width,height:context.height) {
                    context.saveGState();context.setAlpha(sample.alpha)
                    context.draw(image,in:CGRect(x:0,y:0,width:context.width,height:context.height));context.restoreGState()
                }
            }
        }
        return context.makeImage()!
    }
    /// Endpoint preparation for driver B; does not mutate this live header, editor, timers or selection.
    func snapshot(variant:HeaderIslandVariant,scale:CGFloat) -> CGImage {
        guard var c=configuration else { return snapshot(scale:scale) }
        if c.variant == variant,c.scale == scale { return snapshot(scale:scale) }
        c.variant=variant; c.scale=scale; c.ambient=false
        let endpoint=HeaderIsland(); endpoint.now=now; endpoint.configure(c)
        endpoint.state=state; endpoint.renameField.stringValue=renameField.stringValue; endpoint.render(animated:false)
        let image=endpoint.snapshot(scale:scale); endpoint.dispose(); return image
    }
    func setModeContentFrozen(_ frozen:Bool) {
        modeContentFrozen=frozen;pulse?.setModeContentFrozen(frozen)
        // Variant/layout preparation can have suspended Pulse behind the opaque source picture.
        if !frozen,!pulsePresentationRetired,configuration != nil {render(animated:false)}
    }
    /// Actual scene retirement is independent of the window's eight-second ambient budget.
    func setPulsePresentationRetired(_ retired:Bool) {
        pulsePresentationRetired=retired
        if retired { pulse?.suspend(); restorePulseContent() }
        render(animated:false)
    }
    func setPresentationActive(_ active:Bool) {
        if !active {satelliteOpeners.values.forEach{$0.cancel()}}
        if !active && presentationActive { interactionGeneration+=1 }
        presentationActive=active; orb.setPresentationActive(active && configuration?.active == true)
        if !active { timer?.invalidate(); timer=nil; popover?.close(); stopMotionExposure() }
        pulse?.setAmbientActive(active)
        render(animated:false); schedule(); syncOutsideMonitor()
    }
}

extension HeaderIsland: NativePointerHoverClient {}
