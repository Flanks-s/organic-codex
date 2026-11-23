import AppKit
import QuartzCore

/// Window-local adapter. The scene owns membership/Scheme; this object owns only transient trash UI and certificates.
@MainActor final class AutoSceneTrash {
    private weak var scene: AutoScene?
    let windowID=UUID()
    var state=OrbTrashState()
    private(set) var journal=OrganicRemoveJournal()
    let presentation: OrbTrashPresentation
    var preferences=OrganicRemovePreferences(defaults:.standard)
    private(set) var constraint: OrganicTrashLayout?
    private var slots: [String:OrganicMemberLayout.Column]=[:]
    private var vacancies: [OrganicMemberLayout.Vacancy]=[]
    private var revision: UInt64=0, selectionRevision: UInt64=0
    private var selected=""
    private var token: UUID?, member: String?, pointer=CGPoint.zero, grab=CGPoint.zero
    private var source: NSGlassEffectView?
    private var proxyOrb: OrbComponent?
    private var monitor: Any?
    private weak var inputWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var keyboardAction=0
    private var free=false
    private var applying=false, closed=false
    private var message: String?, messageUntil=0.0
    private(set) var output: OrbTrashState.Output?
    private(set) var successfulRemovals=0
    private(set) var successfulUndos=0
    private(set) var ownershipChecks=0,ownershipFailures=0
    private(set) var lastRemoval: OrganicRemovePolicy.Removal?
    var isCarrying: Bool { token != nil }
    var applyingDelta: Bool { applying }
    var hasForegroundSurface: Bool {
        isCarrying || journal.prompt != nil || (scene?.orbInput.isPressed == true && scene?.drag?.conversationOrb == true)
    }

    init(scene: AutoScene) {
        self.scene=scene;presentation=OrbTrashPresentation(bounds:scene.overlayPlane.bounds)
        presentation.drawsPrototypeGlyph=false
        presentation.onUndo = { [weak self] in self?.undo() }
        presentation.onNever = { [weak self] in self?.never() }
        presentation.onDismiss = { [weak self] in self?.dismiss() }
        scene.overlayPlane.addSubview(presentation.view)
    }
    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func project() -> OrganicMemberLayout? {
        guard let scene,!scene.scheme.draft,!scene.columns.isEmpty else { return nil }
        let shown=Array(scene.order.prefix(scene.layout.columns.count))
        guard shown.contains(scene.current),shown.count==scene.layout.columns.count else { return nil }
        if selected != scene.current { selectionRevision &+= 1;selected=scene.current }
        let total=scene.layout.columns.reduce(0) { $0+$1.width }
        let columns=shown.enumerated().map { i,id -> OrganicMemberLayout.Column in
            var slot=slots[id] ?? .init(id:UUID().uuidString,lineage:0,member:id,weight:1)
            slot.weight=constraint?.columns.first(where:{$0.member==id})?.weight ?? Double(scene.layout.columns[i].width/max(1,total));slots[id]=slot;return slot
        }
        let bank=Array(scene.order.dropFirst(columns.count))
        let parked=scene.scheme.parked.filter(bank.contains)
        let left=scene.scheme.mode == .focused ? scene.scheme.left.filter(bank.contains):[]
        let right=bank.filter { !parked.contains($0) && !left.contains($0) }
        let members=scene.members.map { c in
            OrganicMemberLayout.Member(id:c.id,title:c.title,archived:c.archived,
                identity:.init(identityIndex:c.identityIndex,symbol:c.identitySymbol,tint:c.identityTint))
        }
        let value=OrganicMemberLayout(windowID:windowID,endpointScope:String(describing:ObjectIdentifier(scene.store)),
            mode:scene.scheme.mode == .focused ? .focused:.auto,members:members,columns:columns,
            left:left,right:right,parked:parked,vacancies:vacancies,current:scene.current,
            selectionRevision:selectionRevision,revision:revision)
        return value.isValid ? value:nil
    }
    func eligibility(_ id: String) -> OrganicRemovePolicy.Rejection? {
        guard !closed,let scene,id != AutoScene.draftID,scene.store.conversation(id) != nil,
              let layout=project() else { return .missingMember }
        return OrganicRemovePolicy.eligibility(id,in:layout)
    }
    func committed(reason: String,next:AutoLayout) {
        guard !applying,let scene else { return }
        scene.dock.trashDidCommitMembers(Set(scene.members.map(\.id)))
        revision &+= 1
        if selected != scene.current { selectionRevision &+= 1;selected=scene.current }
        if let constraint {
            let actual=Array(scene.order.prefix(next.columns.count))
            if actual != constraint.columns.map(\.member) || (scene.scheme.mode == .focused) != (constraint.mode == .focused) {
                vacancies=[]
                if (scene.scheme.mode == .focused) != (constraint.mode == .focused) { self.constraint=nil }
                else {
                    let total=next.columns.reduce(0){$0+$1.width}
                    let columns=actual.enumerated().map { i,id -> OrganicMemberLayout.Column in
                        var slot=slots[id] ?? .init(id:UUID().uuidString,lineage:0,member:id,weight:1)
                        slot.weight=next.columns[i].width/max(1,total);slots[id]=slot;return slot
                    }
                    self.constraint = .init(mode:constraint.mode,columns:columns)
                }
            }
        }
    }
    private func apply(_ value: OrganicMemberLayout, reason: String, affected: Set<String>) -> Bool {
        guard let scene,value.isValid else { return false }
        let models=value.members.compactMap { scene.store.conversation($0.id) }
        guard models.count==value.members.count else { return false }
        var next=scene.scheme
        next.parked=value.parked;next.left=value.left;next.right=value.right
        if next.mode == .focused { next.split=value.columns.map(\.member) }
        constraint = .init(mode:value.mode,columns:value.columns)
        vacancies=value.vacancies
        for slot in value.columns { slots[slot.member]=slot }
        if let pair=scene.compare,!value.members.contains(where:{$0.id==pair.left}) || !value.members.contains(where:{$0.id==pair.right}) {
            scene.compare=nil;scene.compareAsk=nil;scene.dock.setMeDivider(nil)
        }
        applying=true;defer { applying=false }
        scene.dock.prepareTrashMembershipChange(affected,keeping:Set(value.members.map(\.id)))
        scene.transition(to:models,current:value.current,scheme:next,spring:AutoScene.queueSpring,reason:reason)
        revision=value.revision;selectionRevision=value.selectionRevision;selected=value.current
        return true
    }

    func begin(_ id: String, pointer: CGPoint, grab: CGPoint) {
        guard !closed,let scene,scene.store.conversation(id) != nil,id != AutoScene.draftID,project() != nil else { return }
        dismiss();clearSurface()
        self.member=id;self.pointer=pointer;self.grab=grab;token=UUID()
        source=scene.dock.trashCarrier(id)?.glass
        guard source != nil else { token=nil;member=nil;return }
        mountOrb(id);attach(scene.dockView.window)
        step(.begin(token!),at:scene.now())
    }
    func move(_ point: CGPoint) { pointer=point;if scene?.drag?.freeCarry == true { free=true } }
    /// Re-evaluate semantic hit and eligibility on this up, before selecting the sole drop branch.
    @discardableResult func release(_ point: CGPoint) -> Bool {
        guard let token,let scene else { return false }
        pointer=point
        step(.release(token),at:scene.now())
        self.token=nil
        if output?.requests.contains(.remove(token)) == true,let member {
            if let receipt=remove(member,source:.trash,session:token) {
                scene.dock.detachTrashCarrier()
                step(.committed(receipt.id,session:token),at:scene.now())
            } else { cancel() }
        } else { cancel() }
        return true
    }
    @discardableResult func remove(_ id: String, source: OrganicRemovalReceipt.Source, session: UUID = UUID()) -> OrganicRemovalReceipt? {
        guard let scene,let layout=project(),eligibility(id)==nil else {
            show(OrganicRemoveJournal.lastColumnMessage);return nil
        }
        let outcome=OrganicRemovePolicy.remove(id,from:layout,source:source,sessionID:session)
        guard case .success(let removal)=outcome,
              apply(removal.layout,reason:"trash-remove",affected:[id]) else { return nil }
        guard journal.install(removal.receipt,suppressed:preferences.suppressEducation,at:scene.now()) else { return nil }
        successfulRemovals+=1;lastRemoval=removal
        if source != .trash {
            clearSurface();member=id;self.source=NSGlassEffectView();mountOrb(id);attach(scene.dockView.window)
            step(.menuRemoved(removal.receipt.id),at:scene.now())
        }
        return removal.receipt
    }
    func undo() {
        guard let scene else { return }
        journal.advance(to:scene.now())
        guard let receipt=journal.receipt,let layout=project() else { return }
        let c=scene.store.conversation(receipt.member.id)
        let availability:OrganicRemovePolicy.Availability=c == nil ? .missing:c!.archived ? .archived:.available
        let capacity=undoCapacity(in:layout)
        // Compute first; a failed physical commit must not consume the journal.
        let result=OrganicRemovePolicy.undo(receipt,in:layout,availability:availability,capacity:capacity)
        switch result {
        case .full: journal.advance(to:scene.now());show(OrganicRemoveJournal.fullMessage)
        case .restored(let restoration):
            guard apply(restoration.layout,reason:"trash-undo",affected:Set(restoration.requisitionedBriefs+[receipt.member.id])) else { return }
            _=journal.undo(receiptID:receipt.id,in:layout,availability:availability,capacity:capacity,at:scene.now())
            successfulUndos+=1;member=receipt.member.id;mountOrb(receipt.member.id)
            restoreKeyboardFocus()
            source=scene.dock.trashCarrier(receipt.member.id)?.glass ?? source
            let target=scene.orbEndpoint(receipt.member.id) ?? scene.dock.frame(of:receipt.member.id) ?? .zero
            scene.dock.setTrashOwner(receipt.member.id,hidden:true,frame:nil)
            step(.undo(receipt.id,target:target),at:scene.now())
        case .alreadyPresent,.unavailable:
            _=journal.undo(receiptID:receipt.id,in:layout,availability:availability,capacity:capacity,at:scene.now());dismiss()
        }
    }
    func undoCapacity(in layout: OrganicMemberLayout) -> OrganicUndoCapacity {
        guard let scene else { return .init(dockLimit:0,maxColumns:1) }
        func limit(_ slots:[OrganicMemberLayout.Column],parked:Int) -> Int {
            guard let last=slots.last else { return 0 }
            let share=last.weight/max(0.0001,slots.reduce(0){$0+$1.weight})
            let content=max(0,scene.sizeForOrb.width-2*scene.metrics.inset-CGFloat(parked)*AutoLayout.parkedSlot-CGFloat(max(0,slots.count-1))*scene.metrics.gap)
            let room=max(0,content*share-scene.metrics.lastBarMin-scene.metrics.orbGap)
            return parked+max(0,Int((room+scene.metrics.orbGap)/(scene.metrics.orb+scene.metrics.orbGap)))
        }
        let facts=scene.dock.trashLeaseFacts()
        let maxColumns=scene.isFocused ? FocusLayout.capacity(width:scene.sizeForOrb.width,members:scene.members.count+1,metrics:scene.metrics):AutoLayout.capacity(width:scene.sizeForOrb.width-CGFloat(layout.parked.count)*AutoLayout.parkedSlot,metrics:scene.metrics)
        let parked=layout.parked.count+((journal.receipt?.position.column==nil && journal.receipt?.position.bank == .parked) ? 1:0)
        let offers=scene.dock.undoBriefPrefixes().map { prefix in
            OrganicUndoCapacity.BriefOffer(members:prefix,dockLimitAfterRequisition:limit(layout.columns.filter{!prefix.contains($0.member)},parked:parked))
        }
        // Ask the same policy for the normalized slot proposal, without granting or reserving any capacity.
        var returned=layout.columns
        if let receipt=journal.receipt,
           case .restored(let proposal)=OrganicRemovePolicy.undo(receipt,in:layout,availability:.available,
                capacity:.init(dockLimit:1_000_000,maxColumns:maxColumns,dockLimitAfterColumnReturn:1_000_000)) {
            returned=proposal.layout.columns
        }
        return .init(dockLimit:limit(layout.columns,parked:parked),briefOffers:offers,maxColumns:maxColumns,
            dockLimitAfterColumnReturn:limit(returned,parked:layout.parked.count),addProtectedMembers:facts.add,tideToken:facts.tide)
    }
    func validateCarrier() {
        guard let scene,isCarrying,let member else { return }
        if !scene.members.contains(where:{$0.id==member}) || scene.store.conversation(member)?.archived != false { scene.orbInput.cancel() }
    }
    func frame(_ time: Double) {
        guard !closed else { return }
        if let scene {
            let focus=(scene.dockView.window?.firstResponder as? NSView).map { $0.isDescendant(of:presentation.view) } ?? false
            journal.pause(hover:promptContains(pointer),focus:focus,at:time)
        }
        journal.advance(to:time)
        guard state.phase != .hidden else { return }
        if journal.prompt == nil,state.phase == .educating { step(.dismiss,at:time) }
        else { step(.tick,at:time) }
    }
    private func step(_ event: OrbTrashState.Event, at time: Double) {
        guard let scene else { return }
        presentation.resize(scene.overlayPlane.bounds)
        let native=member.flatMap { scene.dock.trashCarrier($0) }
        if source == nil { source=native?.glass }
        let raw=CGPoint(x:pointer.x-grab.x,y:pointer.y-grab.y)
        let last=scene.layout.orbs.max(by:{$0.maxX<$1.maxX})?.midX ?? scene.sizeForOrb.width-46
        let geometry=OrbTrashGeometry(bounds:scene.dockView.bounds,lastSlotX:last,dockBaseline:scene.layout.me.midY)
        var input=OrbTrashState.Input(event:event,semanticCenter:raw,nativeCarrier:native?.rect ?? output?.pose.carrier ?? .zero,
            nativeVelocity:native?.velocity ?? .zero,inWindow:scene.dockView.bounds.contains(pointer),
            allowsArming:free,
            removable:token == nil || (member.map { eligibility($0)==nil } ?? false),sourceClearance:member.map { scene.dock.trashClearance($0) } ?? .infinity,
            prompt:journal.prompt,geometry:geometry)
        if state.phase == .emerging,let member { input.nativeCarrier=scene.orbEndpoint(member) ?? input.nativeCarrier }
        var next=state.step(input,at:time)
        for request in next.requests {
            if case .presentPrompt(let receiptID)=request {
                journal.present(preferences.suppressEducation ? .toast:.education,receiptID:receiptID,at:time)
                input.event = .tick;input.prompt=journal.prompt;next=state.step(input,at:time)
                break
            }
        }
        if time < messageUntil { next.disabledMessage=message }
        output=next
        if let source {
            scene.dock.withTrashGlassBatch {
                self.presentation.apply(next,source:source,title:self.member.flatMap { scene.store.conversation($0)?.title } ?? "Conversation",sourcePose:native?.rect,
                    writeSource:{ [weak self] frame,hidden in
                        guard let self,let member=self.member else { return }
                        scene.dock.setTrashOwner(member,hidden:hidden,frame:frame)
                        if !scene.dock.isHolding { scene.nodes[member]?.island?.setOrbCarried(hidden) }
                    })
                self.paintOrb(next.pose)
            }
        }
        if next.pose.hidden { clearSurface() }
        else if next.needsFrames || journal.canUndo { scene.runClock(until:max(time+0.1,time+journal.remaining)) }
    }
    /// Inspect applied native properties only after the Dock has committed its pending source write.
    func didApplyFrame() {
        guard let scene,let pose=output?.pose,!pose.hidden else { return }
        let nativeVisible:Bool
        if !scene.dock.isHolding,let member,scene.columns.contains(where:{$0.conversation.id==member}),let island=scene.nodes[member]?.island {
            nativeVisible = !island.orbIsCarried
        } else { nativeVisible=source.map { $0.superview != nil && !$0.isHidden && $0.layer?.isHidden != true } ?? false }
        let count=(nativeVisible ? 1:0)+(presentation.proxy.isHidden ? 0:1)
        let expected=pose.owner == .none ? 0:1
        ownershipChecks+=1;if count != expected { ownershipFailures+=1 }
    }
    private func mountOrb(_ id: String) {
        guard let scene,let c=scene.store.conversation(id) else { return }
        if proxyOrb == nil {
            let orb=OrbComponent(id:"trash.carrier",glassView:presentation.proxy)
            presentation.view.addSubview(orb.backView,positioned:.below,relativeTo:presentation.container)
            presentation.view.addSubview(orb.frontView,positioned:.above,relativeTo:presentation.container)
            proxyOrb=orb
        }
        proxyOrb?.configure(makeOrbConfiguration(c,drawingSize:48,backingScale:scene.scale,reduceMotion:Motion.reduce,ambient:false,isKeyWindow:true))
        proxyOrb?.setCanvasSize(scene.overlayPlane.bounds.size)
    }
    private func paintOrb(_ pose: OrbTrashState.Pose) {
        guard let orb=proxyOrb else { return }
        let shown=pose.owner == .trash && !pose.hidden && pose.carrier.width>0.5
        orb.setFrame(pose.carrier);orb.setOpacity(shown ? Float(pose.glyphAlpha):0)
        orb.setPresentationActive(false)
        orb.backView.isHidden = !shown;orb.frontView.isHidden = !shown
    }
    private func promptContains(_ p:CGPoint) -> Bool {
        guard journal.prompt != nil,let pose=output?.pose else { return false }
        return pose.bubble?.contains(p) == true || pose.toast?.contains(p) == true
    }
    private func attach(_ window:NSWindow?) {
        guard inputWindow !== window || monitor == nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) };inputWindow=window
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.mouseMoved]) { [weak self] event in
            guard let self,event.window === self.inputWindow,let scene=self.scene else { return event }
            let p=scene.dockView.convert(event.locationInWindow,from:nil)
            if event.type == .mouseMoved { self.pointer=p;return event }
            if event.type == .keyDown,self.journal.prompt != nil,event.keyCode==48 {
                if self.inputWindow?.firstResponder !== self.presentation.view {
                    self.previousResponder=self.inputWindow?.firstResponder;self.keyboardAction=0
                } else { self.keyboardAction=(self.keyboardAction+1) % (self.journal.prompt == .education ? 3:2) }
                self.inputWindow?.makeFirstResponder(self.presentation.view)
                self.journal.pause(hover:self.promptContains(self.pointer),focus:true,at:scene.now())
                return nil
            }
            if event.type == .keyDown,self.inputWindow?.firstResponder === self.presentation.view,
               event.keyCode==36 || event.keyCode==49 {
                if self.keyboardAction==0 { self.undo() }
                else if self.keyboardAction==1,self.journal.prompt == .education { self.never() }
                else { self.dismiss() };return nil
            }
            if event.type == .keyDown,event.keyCode==53,self.hasForegroundSurface {
                if self.isCarrying { scene.orbInput.cancel() } else { self.dismiss() };return nil
            }
            if event.type == .leftMouseDown,self.journal.prompt != nil,!self.promptContains(p) { self.dismiss();return nil }
            return event
        }
    }
    func never() { guard let scene else { return };preferences.suppress();journal.suppressCurrentEducation(at:scene.now());step(.tick,at:scene.now()) }
    func dismiss() { guard let scene else { return };journal.dismiss(at:scene.now());restoreKeyboardFocus();if state.phase == .educating { step(.dismiss,at:scene.now()) } }
    private func restoreKeyboardFocus() {
        if let responder=inputWindow?.firstResponder as? NSView,responder === presentation.view || responder.isDescendant(of:presentation.view) { inputWindow?.makeFirstResponder(previousResponder) }
        previousResponder=nil;keyboardAction=0
    }
    func cancel() {
        guard let scene else { return }
        if let member,let pose=output?.pose { scene.dock.setTrashOwner(member,hidden:false,frame:pose.carrier) }
        token=nil;clearSurface()
    }
    func suspend() { dismiss();cancel() }
    func close() { suspend();journal.retireWindow();closed=true;if let monitor { NSEvent.removeMonitor(monitor);self.monitor=nil } }
    private func clearSurface() {
        restoreKeyboardFocus()
        if let source { presentation.retire(source:source) }
        if let member {
            scene?.dock.setTrashOwner(member,hidden:false,frame:nil)
            if scene?.dock.isHolding != true { scene?.nodes[member]?.island?.setOrbCarried(false) }
        }
        proxyOrb?.dispose();proxyOrb?.backView.removeFromSuperview();proxyOrb?.frontView.removeFromSuperview();proxyOrb=nil
        state=OrbTrashState();output=nil;source=nil;member=nil;token=nil;free=false
    }
    private func show(_ text:String) {
        guard let scene else { return };message=text;messageUntil=scene.now()+2.4
        if state.phase != .hidden { step(.tick,at:scene.now()) }
    }
}


extension AutoScene {
    func markConversationOrbPress(_ point:CGPoint,pickup:CGRect?) {
        guard var d=drag,d.id != DockNode.meID,let r=pickup else { return }
        d.conversationOrb=true;d.grab=CGPoint(x:point.x-r.midX,y:point.y-r.midY)
        d.sourceRow=r.midY;d.pickupPose=r;drag=d
    }
}
