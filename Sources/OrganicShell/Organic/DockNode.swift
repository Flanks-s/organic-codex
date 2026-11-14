import AppKit
import QuartzCore

/// The Auto dock (reference §E): me at the left, then one glass node per conversation of the working set — a bar under
/// its column, or an orb when it overflows — all NSGlassEffectViews in one container (spacing 10). A conversation keeps
/// its node when it moves between bar and orb (§E 融合关系), so the glass itself changes shape. Glass shape only follows
/// main-thread frame changes (P2), so nodes are driven per frame (driver A) on springs that start with the columns'.
@MainActor final class DockNode {
    enum Role { case bar, orb }

    @MainActor final class Item {
        let conversation: Conversation
        let glass = NSGlassEffectView()
        /// What the node shows, clipped to its shape while the glass springs.
        // Orb drawing uses a fixed 48 pt body view. Keep its origin at the glass's TOP edge when
        // the displayed planet is smaller; an unflipped host instead lifts it by (48 - diameter).
        let content = DockNode.Passage()
        /// The bar's face: a brief bar's words (the draft's first line, or "Reply…", f056) or the full bar's composer.
        let barFace = NSView()
        let chromeHost = NSView()
        let selection = CAShapeLayer()
        var segmentMix = DockFade(0), emphasis = DockFade(0), controlsOpacity = DockFade(1)
        var identity: OrbComponent?
        var identitySpring = RectSpring.rest(.zero), identityBegan = 0.0
        var identityOpacity = DockFade(0)
        var identityFrame = CGRect.zero
        var identityMotion = M10DockHistory()
        var chromeExit: (rect:CGRect,began:Double)?
        let label = NativeLabel(labelWithString: "")
        /// The conversation's composer, from the first time its bar is full; hidden while it is not.
        var composer: NativeComposer?
        /// The orb's face: the product's decoration (Sol's port, `Orb/`): planet, liquid, badge, satellites. Its body
        /// lives in the glass; its back and front planes sit under and over the dock's glass container.
        let decoration: OrbComponent
        /// The decoration's fade between orb (1) and bar (0): sampled per frame, it moves no glass.
        var face = (from: Float(1), to: Float(1), start: 0.0, duration: 0.0)
        var spring = RectSpring.rest(.zero)
        /// A bar's grip on its top edge, straddling it (DockItems.swift:18-25): 34 × 5, 44 × 6 under the pointer.
        let grip = CAShapeLayer()
        /// Where it rests after the last commit.
        var target = CGRect.zero
        /// As of the last commit: what the node is, the composer is showing, and its slot among bars or orbs.
        var role = Role.orb, full = false, slot = 0
        /// A peek capsule's face: the conversation's name, a chevron and its badge (BriefBar `titled`).
        let peekFace = PeekBarFace()
        /// Where its own spring and hover put it on the last frame, before a peek's bud.
        var regular = CGRect.zero
        let motion = M10DockHistory(), orbMotion = M10DockHistory(), wordMotion = M10DockHistory()
        let wordTrail = M10DockGlyph(), peekTrail = M10DockGlyph()
        let wordGaussian = M10DockGaussian(), peekGaussian = M10DockGaussian()
        var semanticZoomUntil = 0.0
        let peekWordMotion = M10DockHistory()
        /// The planet's veil while it is budded out into a peek (sampled like `face`).
        var veil = (from: Float(0), to: Float(0), start: 0.0, duration: 0.0)
        init(_ c: Conversation) {
            conversation = c
            glass.style = .regular
            for v in [content, barFace, chromeHost] { v.wantsLayer = true; v.autoresizesSubviews = false }
            content.layer?.masksToBounds = true
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.font = .systemFont(ofSize: 13)
            barFace.addSubview(label)
            barFace.clipsToBounds = false
            chromeHost.layer?.masksToBounds = true
            chromeHost.layer?.addSublayer(selection)
            chromeHost.addSubview(barFace)
            peekFace.alphaValue = 0
            content.addSubview(peekFace)
            glass.contentView = content
            decoration = OrbComponent(id: c.id, glassView: glass)
        }
        /// The bar's content follows the glass's frame and keeps its place; the decoration only transforms. Budded out
        /// into a peek, the orb's content stays where the orb is (`orb`, glass-local; OrganicDockProjection orbContentFrame).
        func shape(_ r: CGRect, orb: CGRect? = nil) {
            content.frame = CGRect(origin: .zero, size: r.size)
            content.layer?.cornerRadius = min(r.width, r.height) / 2
            let d = min(r.width, r.height)
            decoration.setFrame(r, contentFrame: orb ?? CGRect(x: 0, y: 0, width: d, height: d))
        }
        /// The composer while it is in this bar: Normie takes it into its detail and gives it back (shared sessions).
        var ownComposer: NativeComposer? { composer?.superview === barFace ? composer : nil }
        func veilAmount(at now: Double) -> Float {
            guard veil.duration > 0 else { return veil.to }
            let k = Float(smoothstep(0, 1, (now - veil.start) / veil.duration))
            return veil.from + (veil.to - veil.from) * k
        }
        func faceOpacity(at now: Double) -> Float {
            guard face.duration > 0 else { return face.to }
            let k = Float(smoothstep(0, 1, (now - face.start) / face.duration))
            return face.from + (face.to - face.from) * k
        }
    }

    /// Only a composer takes the pointer; everything else in the dock passes it on to the scene, which treats
    /// brief bars and orbs as its own click targets.
    final class Passage: NSView, IslandOrbDragProvider {
        var routeOrbInput: ((HeaderIsland, NSEvent) -> Bool)?
        var routeTideOrbInput: ((String, NSEvent) -> Bool)?
        var routeTidePlanetInput: ((String, NSEvent, DockTideHitView) -> Bool)?
        var orbInputContains: ((CGPoint) -> Bool)?
        var cancelOrbInput: (() -> Bool)?
        func routeOrbInput(from island: HeaderIsland, event: NSEvent) -> Bool { routeOrbInput?(island,event) ?? false }
        weak var dockOwner:DockNode?
        func beginOrbDrag(from island:HeaderIsland,event:NSEvent) -> (any IslandOrbDragGesture)? {
            dockOwner?.headerDragControllerForPress()?.beginOrbDrag(from:island,event:event)
        }
        @discardableResult func cancelOrbDrag()->Bool {
            if cancelOrbInput?() == true { return true }
            if let drag=dockOwner?.headerOrbDragging,drag.phase == .pressed || drag.phase == .carrying || drag.phase == .tearing {
                drag.cancel();return true
            }
            // Any held node, not only a header's: an island showing an event must not take the Esc meant for the drag.
            return dockOwner?.cancelHeldPress?() == true
        }
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();dockOwner?.attachTideWindow(window)}
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        /// VoiceOver's dock nodes, beside the native composers (AutoScene.dockAccessibilityChildren, f197).
        var accessibilityNodes: (() -> [Any])?
        override func accessibilityChildren() -> [Any]? { (super.accessibilityChildren() ?? []) + (accessibilityNodes?() ?? []) }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            if dockOwner?.tidePlanetHit(at:convert(point,from:superview),hit:hit) != nil { return self }
            var view: NSView? = hit
            while let v = view { if v is NativeComposer || v is DockTideHitView { return hit }; view = v.superview }
            return nil
        }
        private func tidePlanetHit(_ event:NSEvent)->DockTideHitView? {
            let local=convert(event.locationInWindow,from:nil)
            guard let hit=super.hitTest(convert(local,to:superview)) else {return nil}
            return dockOwner?.tidePlanetHit(at:local,hit:hit)
        }
        override func mouseDown(with event:NSEvent) {
            guard let target=tidePlanetHit(event),let id=target.orbID else {super.mouseDown(with:event);return}
            target.cancelPress()
            if routeTidePlanetInput?(id,event,target) != true {target.mouseDown(with:event)}
        }
        override func rightMouseDown(with event:NSEvent) {
            guard let target=tidePlanetHit(event),let id=target.orbID else {super.rightMouseDown(with:event);return}
            if routeTideOrbInput?(id,event) != true {target.rightMouseDown(with:event)}
        }
    }

    /// Only the notice's planet disc joins the shared gesture. Text, borrowed briefs and buttons retain Tide input.
    private func tidePlanetHit(at point:CGPoint,hit:NSView)->DockTideHitView? {
        var ancestor:NSView?=hit
        while let node=ancestor,node !== view {
            if node is NSButton {return nil}
            if let target=node as? DockTideHitView,let id=target.orbID,
               id==tidePresentedOwner,items[id]?.role == .orb,frame(of:id)?.contains(point)==true {return target}
            ancestor=node.superview
        }
        return nil
    }

    let view: NSView
    /// Install once after the AutoScene is constructed. Kept here, with a weak scene in the coordinator.
    private(set) var headerOrbDragging:M104HeaderOrbDragging?
    func installHeaderOrbDragging(_ coordinator:M104HeaderOrbDragging) { headerOrbDragging=coordinator }
    func headerDragControllerForPress()->M104HeaderOrbDragging? {headerOrbDragging}
    // InputRun still reads this receipt; there are no separate header return carriers.
    var headerReturnCount:Int {returns.count}
    var carrySettles:Double {max(returns.values.map{$0.began+$0.delta.duration}.max() ?? 0,dockLandings.values.map(\.until).max() ?? 0)}
    let layer = CALayer()
    /// Runtime A/B switches are read once; diagnostics remain opt-in.
    static let sharedEpochEnabled = ProcessInfo.processInfo.environment["DOCK_EPOCH"] != "0"
    static let batchWriteEnabled = ProcessInfo.processInfo.environment["DOCK_BATCH_WRITE"] != "0"
    struct TransitionEpoch {
        let began: Double
        let physicalReleaseID: String?
        let capsule: (rect: CGRect, velocity: CGRect)
        let me: (rect: CGRect, velocity: CGRect)
        let identities: [String: (rect: CGRect, velocity: CGRect)]
        let items: [String: (rect: CGRect, velocity: CGRect)]
        let worldItems: [String: CGRect]
    }
    var transitionEpoch: TransitionEpoch?
    private var transitionIdentitySources: [String: (rect: CGRect, velocity: CGRect)]?
    private var sceneBegan: Double?
    private var commitClock: Double?
    private var lastInjectedClock: Double?
    private struct GlassObservation {
        var rect: CGRect, time: Double
        var previous: CGRect?, previousTime: Double?
        var regular: CGRect? = nil, previousRegular: CGRect? = nil
        var regularVelocity: CGRect? {
            guard let regular, let previousRegular, let previousTime, time > previousTime else { return nil }
            let dt=time-previousTime
            return CGRect(x:(regular.origin.x-previousRegular.origin.x)/dt,y:(regular.origin.y-previousRegular.origin.y)/dt,
                width:(regular.size.width-previousRegular.size.width)/dt,height:(regular.size.height-previousRegular.size.height)/dt)
        }
        var velocity: CGRect {
            guard let previous, let previousTime, time > previousTime else { return .zero }
            let dt=time-previousTime
            return CGRect(x:(rect.origin.x-previous.origin.x)/dt,y:(rect.origin.y-previous.origin.y)/dt,
                width:(rect.size.width-previous.size.width)/dt,height:(rect.size.height-previous.size.height)/dt)
        }
    }
    private var glassObservations: [ObjectIdentifier:GlassObservation] = [:]
    private var releasedGlassID: String?
    private var observingPickup = false
    private func observeGlass(_ glass: NSGlassEffectView, at now: Double) {
        guard held != nil || releasedGlassID != nil || !glassReleases.isEmpty || observingPickup else { return }
        let key=ObjectIdentifier(glass), rect=glass.frame
        guard !glass.isHidden,glass.layer?.isHidden != true,rect.width>0,rect.height>0 else {glassObservations[key]=nil;return}
        let old=glassObservations[key]
        let regular=items.values.first { $0.glass === glass }?.regular
        if let old, now <= old.time {
            glassObservations[key]=GlassObservation(rect:rect,time:old.time,previous:old.previous,previousTime:old.previousTime,regular:regular,previousRegular:old.previousRegular)
        } else { glassObservations[key]=GlassObservation(rect:rect,time:now,previous:old?.rect,previousTime:old?.time,regular:regular,previousRegular:old?.regular) }
    }
    private func observeAllGlass(at now: Double) {
        for case let glass as NSGlassEffectView in content.subviews { observeGlass(glass,at:now) }
    }
    func makeTransitionEpoch(at time: Double) -> TransitionEpoch {
        var poses=items.mapValues { $0.spring.sample(sampledElapsed ?? 0) }
        var worlds=items.mapValues { $0.motion.rect ?? $0.glass.frame }
        for (id,source) in tideLayoutSources {
            guard let item=items[id] else{continue}
            poses[id]=(localFrame(source.rect,role:item.role,slot:item.slot,at:time),source.velocity)
            worlds[id]=source.rect
        }
        return TransitionEpoch(began:time,physicalReleaseID:Self.sharedEpochEnabled ? (releasedGlassID ?? (glassReleases.isEmpty ? nil:"continuation")):nil,
            capsule:capsuleSpring.sample((capsuleSampleTime ?? time)-capsuleBegan),
            me:(meMotion.rect ?? me?.frame ?? .zero,meSpring.sample((meSampleTime ?? time)-meBegan).velocity),
            identities:items.compactMapValues { item in
                guard item.identity != nil else { return nil }
                if let side=tideSides[item.conversation.id],side.pose.shown {return (side.orbGlass.frame,.zero)}
                let t=item.identityMotion.observationTime ?? capsuleSampleTime ?? time
                let pose=item.identitySpring.sample(t-item.identityBegan)
                return (item.identityMotion.rect ?? item.identityFrame,pose.velocity)
            },items:poses,worldItems:worlds)
    }
    @MainActor private final class GlassRelease {
        let spring: RectSpring
        var began: Double
        weak var view: NSGlassEffectView?
        let history=M10DockHistory()
        init(view:NSGlassEffectView,source: GlassObservation, target: CGRect, began: Double, tuning: RectSpring) {
            self.view=view;self.began=began
            spring=RectSpring(dockFrom:source.rect,to:target,velocity:source.velocity,
                response:tuning.x.response,damping:tuning.x.damping)
            history.reset(source.rect)
        }
    }
    private var glassReleases: [ObjectIdentifier:GlassRelease] = [:]
    private func projectedCapsule(_ rect: CGRect, at now: Double) -> CGRect {
        if !base.focused, let owner=capsuleOwnerID.flatMap({items[$0]}),owner.role == .orb {
            return orbDeltas.indices.contains(owner.slot) ? rect.adding(orbDeltas[owner.slot]):rect
        }
        return rect.offsetBy(dx:refusal(at:now),dy:-rise)
    }
    /// The scene must not settle while a physical release channel still has motion to finish.
    var glassReleaseSettles: Double {max(glassReleases.values.map{$0.began+$0.spring.duration}.max() ?? 0,
        contourHandoffs.values.map(\.end).max() ?? 0)}
    private func currentGlassTarget(_ glass: NSGlassEffectView) -> CGRect? {
        if glass === focusedGlass {return projectedCapsule(capsuleSpring.target,at:motionNow())}
        if glass === me {return meSpring.target.adding(meDelta)}
        if let draftBar,glass === draftBar.glass {return draftBar.rect.offsetBy(dx:0,dy:-rise)}
        for item in items.values {
            if glass === item.identity?.glassView {return item.identitySpring.target.offsetBy(dx:refusal(at:motionNow()),dy:-rise)}
            if glass === item.glass {
                if item.role == .bar {return item.target.offsetBy(dx:refusal(at:motionNow()),dy:-rise)}
                return orbDeltas.indices.contains(item.slot) ? item.target.adding(orbDeltas[item.slot]):item.target
            }
        }
        return nil
    }
    private func releaseLogical(_ glass: NSGlassEffectView?, fallback: CGRect?) -> CGRect? {
        guard let glass, let channel=glassReleases[ObjectIdentifier(glass)] else { return fallback }
        let target=currentGlassTarget(glass) ?? channel.spring.target,home=channel.spring.target
        let delta=CGRect(x:target.origin.x-home.origin.x,y:target.origin.y-home.origin.y,
            width:target.size.width-home.size.width,height:target.size.height-home.size.height)
        let pose=channel.spring.sample(motionNow()-channel.began).rect
        // A shrinking hover delta has signed dimensions; CGRect edge accessors standardize them.
        return CGRect(x:pose.origin.x+delta.origin.x,y:pose.origin.y+delta.origin.y,
            width:pose.size.width+delta.size.width,height:pose.size.height+delta.size.height)
    }
    private func applyGlassReleases() {
        let now=motionNow()
        for (key,channel) in glassReleases {
            guard let view=channel.view else { continue }
            var write=glassWrites[key] ?? GlassWrite(view:view,frame:view.frame,alpha:view.alphaValue,hidden:view.isHidden)
            guard !write.hidden else { continue }
            let r=releaseLogical(view,fallback:nil) ?? channel.spring.sample(now-channel.began).rect
            let f=channel.history.update(r,at:now,name:"dock.release",profile:exposureProfile,enabled:usesExposure)
            let old=write.frame
            write.frame=f.painted
            if collectingGlass {glassWrites[key]=write}
            else {writeGlass(view,frame:f.painted,reason:"release")}
            if let ink=write.view.contentView?.frame {
                write.view.contentView?.frame=ink.offsetBy(dx:old.minX-f.painted.minX,dy:old.minY-f.painted.minY)
            }
        }
    }
    private func beginGlassRelease(at now: Double) {
        glassReleases.removeAll(keepingCapacity:true)
        func add(_ glass: NSGlassEffectView?, target: CGRect, tuning: RectSpring) {
            guard let glass,!glassHidden(glass),let pose=glassObservations[ObjectIdentifier(glass)] else { return }
            glassReleases[ObjectIdentifier(glass)]=GlassRelease(view:glass,source:pose,target:target,began:now,tuning:tuning)
        }
        add(focusedGlass,target:projectedCapsule(capsuleSpring.target,at:now),tuning:capsuleSpring)
        if meHeld == nil {add(me,target:meSpring.target.adding(meDelta),tuning:meSpring)}
        if let draftBar {add(draftBar.glass,target:draftBar.rect.offsetBy(dx:0,dy:-rise),tuning:capsuleSpring)}
        for (id,item) in items where !carries(id) {
            var target=item.target
            if item.role == .bar {target=target.offsetBy(dx:refusal(at:now),dy:-rise)}
            else if orbDeltas.indices.contains(item.slot) {target=target.adding(orbDeltas[item.slot])}
            add(item.glass,target:target,tuning:item.spring)
            add(item.identity?.glassView,target:item.identitySpring.target.offsetBy(dx:refusal(at:now),dy:-rise),tuning:item.identitySpring)
        }
    }
    /// A scoped bridge for a contour whose ownership changes before its raw geometry does.
    /// The solver and its destination margins are unchanged; the existing motion tuning retires the old edge offset.
    private final class ContourHandoff {
        weak var view:NSGlassEffectView?
        weak var arrival:NSGlassEffectView?
        var source:CGRect
        var raw:CGRect?
        var tuning:RectSpring
        var delta:RectSpring?
        var began:Double
        init(view:NSGlassEffectView,source:CGRect,raw:CGRect?,tuning:RectSpring,arrival:NSGlassEffectView?,at now:Double) {
            self.view=view;self.source=source;self.raw=raw;self.tuning=tuning;self.arrival=arrival;began=now
        }
        var end:Double {began+max(tuning.duration,delta?.duration ?? 0)}
    }
    private var contourHandoffs:[ObjectIdentifier:ContourHandoff]=[:]
    private var tearingGlassID:String?
    private func rawContour(_ glass:NSGlassEffectView)->CGRect? {
        if glass === focusedGlass {return capsuleMotion.rect}
        if glass === me {return meMotion.rect}
        if glass === draftBar?.glass {return draftMotion.rect}
        for item in items.values {
            if glass === item.glass {return item.motion.rect}
            if glass === item.identity?.glassView {return item.identityMotion.rect}
        }
        return nil
    }
    private func captureContours(excluding:NSGlassEffectView?=nil)->[(NSGlassEffectView,CGRect,CGRect?)] {
        content.subviews.compactMap {view in
            guard let glass=view as? NSGlassEffectView,glass !== excluding,!glass.isHidden,glass.layer?.isHidden != true,
                  glass.frame.width>0,glass.frame.height>0 else {return nil}
            return (glass,glass.frame,rawContour(glass))
        }
    }
    private func queueContours(_ sources:[(NSGlassEffectView,CGRect,CGRect?)],tuning:RectSpring,
                               stableRaw:Bool,arrival:NSGlassEffectView?=nil) {
        let now=motionNow()
        for (glass,frame,raw) in sources {
            contourHandoffs[ObjectIdentifier(glass)]=ContourHandoff(view:glass,source:frame,raw:stableRaw ? raw:nil,
                tuning:tuning,arrival:arrival,at:now)
        }
        onNeedsFramesUntil?(now+tuning.duration)
    }
    private func applyContourHandoffs() {
        guard !contourHandoffs.isEmpty else {return}
        let now=motionNow()
        var seams:[ObjectIdentifier:(NSGlassEffectView,CGFloat,CGFloat)]=[:]
        for (key,handoff) in contourHandoffs {
            guard let glass=handoff.view,glass.superview === content,!glassHidden(glass),glass.layer?.isHidden != true else {
                contourHandoffs[key]=nil;continue
            }
            let projected=glassFrame(glass)
            if handoff.delta == nil {
                if let raw=handoff.raw,let current=rawContour(glass),MotionStep.edge(raw,current)>=0.001 {
                    contourHandoffs[key]=nil;continue
                }
                let difference=handoff.source.subtractingSignedComponents(projected)
                guard max(abs(difference.origin.x),abs(difference.origin.y),abs(difference.size.width),abs(difference.size.height))>=0.001 else {
                    contourHandoffs[key]=nil;continue
                }
                handoff.delta=RectSpring(peekDeltaFrom:difference,to:.zero,velocity:.zero,
                    response:handoff.tuning.x.response,damping:handoff.tuning.x.damping)
                // A delayed display callback consumes elapsed time; it never restarts this handoff.
                onNeedsFramesUntil?(handoff.end)
            }
            guard let spring=handoff.delta else {continue}
            let d=spring.sample(now-handoff.began).rect
            let rect=projected.addingSignedComponents(d)
            guard rect.width>0,rect.height>0 else {contourHandoffs[key]=nil;continue}
            if let arrival=handoff.arrival,arrival.superview === content,
               min(glassFrame(arrival).maxY,projected.maxY)-max(glassFrame(arrival).minY,projected.minY)>min(glassFrame(arrival).height,projected.height)*0.25 {
                let incoming=glassFrame(arrival),id=ObjectIdentifier(arrival),old=seams[id]
                var left=old?.1 ?? 0,right=old?.2 ?? 0
                // Both faces of a returned seam move together, preserving its resolved gap.
                if projected.midX<incoming.midX {left += d.origin.x+d.size.width}
                else {right += d.origin.x}
                seams[id]=(arrival,left,right)
            }
            let ink=glass.contentView?.frame
            writeGlass(glass,frame:rect,reason:"contourHandoff")
            if let ink {glass.contentView?.frame=ink.offsetBy(dx:projected.minX-rect.minX,dy:projected.minY-rect.minY)}
            if now-handoff.began>=spring.duration {contourHandoffs[key]=nil}
        }
        for (_,entry) in seams {
            let (glass,left,right)=entry,old=glassFrame(glass)
            let rect=CGRect(x:old.minX+left,y:old.minY,width:old.width+right-left,height:old.height)
            guard rect.width>0 else {continue}
            let ink=glass.contentView?.frame
            writeGlass(glass,frame:rect,reason:"returnSeam")
            if let ink {glass.contentView?.frame=ink.offsetBy(dx:old.minX-rect.minX,dy:0)}
        }
    }

    private struct GlassWrite {
        let view: NSGlassEffectView
        var frame: CGRect
        var alpha: CGFloat
        var hidden: Bool
    }
    private var collectingGlass = false, resolvingGlass = false
    var onTrashFrame: ((Double)->Void)?
    var onTrashApplied: (()->Void)?
    weak var browserDockPort: (any BrowserDockPort)?
    private var trashHiddenGlass=Set<ObjectIdentifier>()
    private var trashHiddenMember: String?
    private var trashReflowPending=false
    private var trashLiveMembers=Set<String>()
    private var freeCarry: (x:OrbTrashMotion,y:OrbTrashMotion,grab:CGPoint)?
    private var glassWrites: [ObjectIdentifier: GlassWrite] = [:]
    private var batchID = 0
    private var rawExposed: [String: M10DockFrame] = [:]
    private var epochSourceBatchID = 0
    private var capturesWriteLog = false
    private var writeTrace: [[String: Any]] = []
    private func glassFrame(_ glass: NSGlassEffectView) -> CGRect { glassWrites[ObjectIdentifier(glass)]?.frame ?? glass.frame }
    private func glassHidden(_ glass: NSGlassEffectView) -> Bool { glassWrites[ObjectIdentifier(glass)]?.hidden ?? glass.isHidden }
    private func writeGlass(_ glass: NSGlassEffectView, frame: CGRect? = nil, alpha: CGFloat? = nil, hidden: Bool? = nil, reason: String = "raw") {
        var hidden=ModeDepartureSurfaces.retains(glass) || trashHiddenGlass.contains(ObjectIdentifier(glass)) ? true:hidden
        if let browserDockPort, browserDockPort.hidesGlass(glass) { hidden = true }
#if M10_DOCK_SELFTEST
        if reason == "raw", let frame {reviewRawGlass[ObjectIdentifier(glass)]=frame}
        if !collectingGlass,frame != nil {reviewWrites[ObjectIdentifier(glass),default:0] += 1}
#endif
        if collectingGlass {
            let key = ObjectIdentifier(glass)
            var write = glassWrites[key] ?? GlassWrite(view: glass, frame: glass.frame, alpha: glass.alphaValue, hidden: glass.isHidden)
            if let frame { write.frame = frame }; if let alpha { write.alpha = alpha }; if let hidden { write.hidden = hidden }
            glassWrites[key] = write
        } else {
            let deduplicate=tideTimeline?.active == true || !tideMaterialShapes.isEmpty || tideSideLive || !tideAddTails.isEmpty
            let changed=(frame.map{glass.frame != $0 || glass.cornerRadius != (tideGlassCorners[ObjectIdentifier(glass)] ?? min($0.width,$0.height)/2)} ?? false)
                || (alpha.map{glass.alphaValue != $0} ?? false) || (hidden.map{glass.isHidden != $0} ?? false)
            guard !deduplicate || changed else {
                if frame != nil {observeGlass(glass,at:motionNow())}
                return
            }
            if let frame { glass.frame = frame; glass.cornerRadius = tideGlassCorners[ObjectIdentifier(glass)] ?? min(frame.width,frame.height)/2 }
            if let alpha { glass.alphaValue = alpha }; if let hidden { glass.isHidden = hidden }
            countTideWrite()
            if capturesWriteLog { traceWrite(glass, reason: reason) }
            if frame != nil { observeGlass(glass,at:motionNow()) }
        }
    }
    private func traceWrite(_ glass: NSGlassEffectView, reason: String) {
        writeTrace.append(["order":writeTrace.count,"batchID":batchID,"view":String(describing:ObjectIdentifier(glass)),
            "reason":reason,"frame":DockFrameLog.rect(glass.frame),"hidden":glass.isHidden,"alpha":glass.alphaValue])
    }
    private func beginGlassBatch() -> Bool {
        guard Self.batchWriteEnabled, !collectingGlass else { return false }
        collectingGlass = true; glassWrites.removeAll(keepingCapacity:true)
        return true
    }
    private func endGlassBatch(_ owns: Bool) {
        guard owns else { return }
        applyGlassReleases()
        resolvingGlass = true; reconcileGlassTopology(); resolvingGlass = false
        applyContourHandoffs()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Stable view order makes each native glass receive exactly one final geometry write.
        for view in content.subviews {
            guard let glass = view as? NSGlassEffectView, let write = glassWrites[ObjectIdentifier(glass)] else { continue }
#if M10_DOCK_SELFTEST
            reviewWrites[ObjectIdentifier(glass),default:0] += 1
#endif
            let deduplicate=tideTimeline?.active == true || !tideMaterialShapes.isEmpty || tideSideLive || !tideAddTails.isEmpty
            let changed=glass.frame != write.frame || glass.cornerRadius != (tideGlassCorners[ObjectIdentifier(glass)] ?? min(write.frame.width,write.frame.height)/2) || glass.alphaValue != write.alpha || glass.isHidden != write.hidden
            if !deduplicate || changed {
                glass.frame = write.frame; glass.cornerRadius = tideGlassCorners[ObjectIdentifier(glass)] ?? min(write.frame.width,write.frame.height)/2
                glass.alphaValue = write.alpha; glass.isHidden = ModeDepartureSurfaces.retains(glass) || write.hidden
                countTideWrite()
            }
            if capturesWriteLog { traceWrite(glass,reason:"finalBatch") }
        }
        for side in tideSides.values where side.pose.shown {side.finishMaterialFrame()}
        CATransaction.commit()
        if held != nil || releasedGlassID != nil || !glassReleases.isEmpty { observeAllGlass(at:motionNow()) }
        collectingGlass = false; glassWrites.removeAll(keepingCapacity:true)
    }
    private let container = NSGlassEffectContainerView()
    private let content = Passage()
    private let chromePlane = Passage()
    private let focusedGlass = NSGlassEffectView()
    private var focusedMix = DockFade(0)
    private var segmentIDs: [String] = []
    private var capsuleSpring = RectSpring.rest(.zero), capsuleBegan = 0.0
    /// The product retains its first focused member as the capsule, then returns it to Auto.
    private var capsuleOwnerID: String?
    private var capsuleSharesOwnerPose = false
    private let capsuleMotion = M10DockHistory()
    private let glassTopology = DockGlassTopology()
    private let frameLog = DockFrameLog.shared.map { DockFrameLog.Context($0) }
    private var glassTransitionUntil = 0.0
    private var capsuleSampleTime: Double?
    private var meSampleTime: Double?
    private var sampledElapsed: Double?
    private var displayTime: Double?
    private var latestDisplayTime = 0.0
    private var glassRetargetTime: Double?
    private var glassRetargetPaint: [ObjectIdentifier: CGRect] = [:]
    private var topologyPeekExclusions: Set<String> = []
    // M11.34: notification ownership on the scene's existing display callback.
    private var tideTimeline:TideMotion?
    private var tideLeaseMemory=DockSlotLeases()
    private let tideWatchedEditors=NSHashTable<NativeComposer>.weakObjects()
    private var tideCursors:[String:Int]=[:]
    let questionDiagnostics=TideQuestionDiagnostics()
    private var tideMediaLast:Double?
    private var tidePointer:CGPoint?
    private var tideNodePoses:[String:CGRect]=[:]
    private var tideWords:DockTidePresentation?
    private var tideInkFilters:[String:NSObject]=[:]
    private var tideMinimumGap=Double.infinity
    private var tideWorstPair=""
    private var tideDegraded=false
    private var tideDynamic=false
    private var tidePool:[String:DockTideShape]=[:]
    private var tideFaces:[String:DockTideFace]=[:]
    private var tideBorrowHits:[String:DockTideHitView]=[:]
    var tideWarmAllowed:(()->Bool)?
    var onTideMotion:(()->Void)?
    private var tideWarmJob:DispatchWorkItem?,tideWakeJob:DispatchWorkItem?
    private var tideWakeAt:Double?,tideWarmGeneration=0
    private var tideMovingCallbacks=0,tideStillCallbacks=0,tideMovingWrites=0,tideStillWrites=0
    private var tideFrameMoving:Bool?
    private var tideLastAppliedRise:CGFloat?
    private var tideWarmMaxSliceMS=0.0,tideWarmContentMS=0.0
    private var tideLastWakeDriftMS=0.0
    private var tideArrivalAllocations=0,tideArrivalContentAllocations=0
    private var tideDelivering=false
    private var tidePresentedOwner:String?
    private var tideSides:[String:DockTideSide]=[:]
    private var tideGlassCorners:[ObjectIdentifier:CGFloat]=[:]
    private var tideSideLive=false
    private var tideSideFitCache:[String:(input:[CGRect],result:[String:CGRect]?)]=[:]
    private var tideSideHiddenSources:Set<String>=[]
    private var tideSideQueued:[String:[ConversationNotice]]=[:]
    private var tideFrozenAt:Double?
    private var tideFrozenSources:[String:CGRect]=[:]
    private var tideFrozen=false
    private let tideModeExit=TideModeExit()
    private var tideAddLayout:(began:Double,duration:Double)?
    private var tideAddReservation:DockSlotLeases.Lease?
    private var tideAddTails:[String:TideAddHandoff]=[:]
    /// The caller has already applied Add's capacity policy. Rejection never changes membership.
    func reserveTideSlotsForAdd(owner:String,count:Int,capacityAllows:Bool)->DockSlotLeases.Decision {
        advanceTideClock(to:tideNow());refreshTideProtection()
        var leases=tideTimeline?.leases ?? tideLeaseMemory
        let protection=tideProtection()
        let candidates=items.values.filter{$0.role == .bar}.sorted{$0.target.minX>$1.target.minX}.map {
            DockSlotLeases.Candidate(id:$0.conversation.id,role:$0.full ? .full:.brief,protection:protection[$0.conversation.id] ?? [])
        }
        let decision=leases.request(owner:owner,purpose:.add,count:count,candidates:candidates,capacityAllows:capacityAllows,at:tideNow())
        tideTimeline?.leases=leases;tideLeaseMemory=leases
        if let lease=decision.lease,decision.status == .granted {
            tideAddReservation=lease
            if decision.revoked != nil {freezeTideForMode()}
        }
        return decision
    }
    func cancelTideAdd(_ token:DockSlotLeases.Token) {
        guard tideAddReservation?.token==token else{return}
        _=tideLeaseMemory.release(token);tideTimeline?.leases=tideLeaseMemory;tideAddReservation=nil
        finishTideModeHandoff()
    }
    var tideAddProbe:[String:Any] {
        ["committed":tideLeaseMemory.add?.committed ?? false,"briefs":tideLeaseMemory.add?.briefs ?? [],
         "generation":tideLeaseMemory.generation,"reservation":tideAddReservation != nil,
         "tails":tideAddTails.mapValues{["tail":$0.tail(at:motionNow()),"bodyDelay":0.07,"began":$0.began]}]
    }
    /// Explicit native sampling for the Add driver and the physical gate, outside measurement probes.
    var tideAddPhysicalProbe:[String:[[CGFloat]]] {
        Dictionary(uniqueKeysWithValues:tideAddTails.keys.compactMap {id -> (String,[[CGFloat]])? in
            guard let item=items[id] else{return nil}
            return (id,[DockTideShape.rect(item.glass.frame)]+(tidePool[id]?.views ?? []).filter{!$0.isHidden}.map{DockTideShape.rect($0.frame)})
        })
    }
    private func applyTideAddTails() {
        guard !tideFrozen else{return}
        let now=motionNow()
        for (id,handoff) in tideAddTails {
            guard let item=items[id] else{tideAddTails[id]=nil;tidePool[id]?.park();continue}
            let amount=handoff.tail(at:now)
            if amount>0 {
                let pose=TideMaterialPose(owner:id,body:glassFrame(item.glass),tailAmount:amount,lean:handoff.lean,retracting:true)
                tidePool[id]?.apply(pose.contour){[weak self] glass,rect,hidden in
                    self?.writeGlass(glass,frame:rect,alpha:1,hidden:hidden,reason:"tideAddTail")
                    if !hidden {glass.cornerRadius=min(rect.width,rect.height)/2}
                }
                tidePool[id]?.style(identity:Look.identity[item.conversation.identityIndex % Look.identity.count],amount:amount)
            } else {tidePool[id]?.park()}
            let face=item.role == .orb ? max(0,1-Double(item.faceOpacity(at:now))):max(0,1-(now-handoff.began)/0.07)
            tideFaces[id]?.render(rect:glassFrame(item.glass),opacity:face)
            if now>=handoff.began+handoff.duration {tideAddTails[id]=nil;tideFaces[id]?.park()}
        }
        if let layout=tideAddLayout,now>=layout.began+layout.duration {tideAddLayout=nil}
        if !tideAddTails.isEmpty || tideAddLayout != nil {onNeedsFramesUntil?(now)}
    }
    private var tideReclaim:(id:String,due:Double)?
    private var tideAnimationTrial:DockTideAnimationTrial?
    private var tideLifecycle:DockTideLifecycle?
    var onTideAction:((String,ConversationNoticeAction)->Void)?
    var onTideReclaim:((String)->Void)?
    var onTidePointer:((CGPoint?)->Void)?
    var tideContentObstacles:(()->[CGRect])?
    var onTideReadingRoom:(([CGRect])->Void)?
    var tideCanDismiss:(()->Bool)?
    func attachTideWindow(_ window:NSWindow?) {
        if tideLifecycle == nil {
            let lifecycle=DockTideLifecycle()
            lifecycle.retire={ [weak self] in self?.retireTide() }
            lifecycle.deactivate={ [weak self] in self?.endTideInteraction() }
            lifecycle.close={ [weak self] in self?.closeTidePresentation() }
            lifecycle.input={ [weak self] event in self?.handleTideInput(event) ?? false }
            tideLifecycle=lifecycle
        }
        tideLifecycle?.attach(window)
    }
    private func handleTideInput(_ event:NSEvent)->Bool {
        if event.type == .mouseMoved {
            // Keep future lease protection current without waking an inactive or retired scene.
            guard !tideFrozen,!view.isHiddenOrHasHiddenAncestor else{return false}
            if tideTimeline?.active == true || tideSides.values.contains(where:{$0.active}) {
                tidePointerEvent(event)
            } else {tidePointer=view.convert(event.locationInWindow,from:nil)}
            return false
        }
        // A planet down must reach pickup before Tide's outside-click dismissal can consume it.
        if event.type == .leftMouseDown,
           (view as? Passage)?.orbInputContains?(view.convert(event.locationInWindow,from:nil)) == true {return false}
        guard event.window?.attachedSheet == nil else{return false}
        if event.type == .keyDown,let editor=event.window?.firstResponder as? NSTextView,editor.hasMarkedText() {return false}
        let side=tideSides.values.filter{$0.active && !$0.motion.returning}.max{($0.pose.shown ? 2:0)+($0.motion.event?.urgent == true ? 1:0)<($1.pose.shown ? 2:0)+($1.motion.event?.urgent == true ? 1:0)}
        if let side,!tideFrozen,!hasPeek,tideCanDismiss?() != false {
            let point=view.convert(event.locationInWindow,from:nil)
            if event.type == .keyDown,event.keyCode==53 {return dismissTide()}
            if event.type == .leftMouseDown,!tideSides.values.contains(where:{$0.pose.shown && ($0.glass.frame.contains(point) || $0.pose.orb.contains(point))}) {return dismissTide()}
        }
        guard !tideFrozen,tideTimeline?.active == true,!hasPeek,held == nil,tideCanDismiss?() != false,event.window?.attachedSheet == nil else{return false}
        if event.type == .keyDown {
            if let editor=event.window?.firstResponder as? NSTextView,editor.hasMarkedText() {return false}
            return event.keyCode==53 && dismissTide()
        }
        let point=view.convert(event.locationInWindow,from:nil)
        if let id=tideTimeline?.owner,tideNodePoses[id]?.contains(point) == true {return false}
        // A requisitioned editor belongs to the user; its press is allowed to focus it.
        if tideMaterialPoses.values.contains(where:{$0.body.rect.contains(point)}) {return false}
        return dismissTide()
    }
    private func sideEligible(_ item:Item)->Bool {item.role == .orb && (base.focused || item.slot<base.leading)}
    var tideSideProbe:[[String:Any]] {tideSides.keys.sorted().compactMap{tideSides[$0]?.probe(at:tideFrozenAt ?? tideNow())}}
    var tideSidePhysicalProbe:[[String:Any]] {tideSides.keys.sorted().compactMap{tideSides[$0]?.physicalProbe}}
    private func packTideSides() {
        // Every existing surface reaches arrival time on its old target before another owner changes packing.
        let at=tideNow()
        for side in tideSides.values {
            let source=items[side.id]?.regular
            side.followDock(centerX:source.flatMap{$0.width>0 ? $0.midX:nil} ?? side.restingAnchor.midX,rise:Double(rise))
        }
        for side in tideSides.values where side.active {side.advance(to:at)}
        tideSideLive=tideSides.values.contains{$0.active}
        let union=base.bars.reduce(base.bars.first ?? .zero){$0.union($1)}
        let visible=tideSides.values.filter{$0.candidate != nil}
        for right in [false,true] {
            let entries=visible.filter{($0.pose.anchor.midX>union.midX)==right}
            // Side B uses the reading margin, not the wider composer capsule's edge.
            let region=TideSidePacking.region(width:view.bounds.width,focused:base.focused,split:base.bars.count>1,right:right)
            var chosen:[DockTideSide]=[],targets:[String:CGRect]=[:]
            let ranked=entries.sorted{a,b in
                let x=a.candidate!.rank,y=b.candidate!.rank
                return x==y ? a.arrivalAt<b.arrivalAt:x>y
            }
            for entry in ranked {
                let trial=chosen+[entry]
                guard let region else{continue}
                let proposed=TideSidePacking.solve(trial.compactMap(\.candidate),region:region,bottom:union.minY-14-rise,right:right)
                guard proposed.count==trial.count else{continue}
                let ids=Set(trial.map(\.id))
                let fixed=items.values.filter{!ids.contains($0.conversation.id)}.flatMap{item in
                    [item.glass,item.identity?.glassView].compactMap{$0}.filter{!$0.isHidden}.map(\.frame)
                }+base.bars+(tideContentObstacles?() ?? [])
                // Try a bounded set of independent vertical lanes. Neither neighbours nor tails shrink.
                let orderedIDs=trial.map(\.id),key=orderedIDs.joined(separator:"\u{1f}")
                let sorted=fixed.sorted {a,b in a.minX != b.minX ? a.minX<b.minX:a.minY != b.minY ? a.minY<b.minY:a.width != b.width ? a.width<b.width:a.height<b.height}
                let signature=trial.flatMap {side in [proposed[side.id]!,side.pose.anchor,CGRect(x:side.pose.composerTop,y:0,width:side.ready ? 1:0,height:Double(TideTailBudget.pieces))]}+sorted
                let fitted:[String:CGRect]?
                if let cached=tideSideFitCache[key],cached.input==signature {fitted=cached.result}
                else {
                    fitted=TideSidePacking.fit(proposed,order:orderedIDs,obstacles:fixed,staggered:!base.focused && base.leading>0,contour:{id,rect in tideSides[id]?.projectedPhysical(rect) ?? []})
                    tideSideFitCache[key]=(signature,fitted)
                }
                if let fitted {chosen=trial;targets=fitted}
            }
            for entry in tideSides.values where (entry.pose.anchor.midX>union.midX)==right {
                let raised=targets[entry.id].map{$0.maxY<union.minY-14-rise-1} ?? false
                entry.target(targets[entry.id],staged:raised || (!base.focused && base.leading>0 && targets.count==2))
            }
        }
    }
    /// Native decision controls can change while the notice sleeps; re-admit only this finite notification.
    func tideReadingRoomChanged() {
        guard !tideFrozen,tideSides.values.contains(where:{$0.active}) else{return}
        packTideSides()
        if tideSides.values.contains(where:{$0.busy}) {onTideMotion?();onNeedsFrames?(0);scheduleTideWake()}
    }
    private func advanceTideSides(at time:Double) {
        for side in tideSides.values where side.active {side.advance(to:time)}
        packTideSides()
    }
    private func renderTideSides() {
        guard !tideFrozen else{return}
        let at=tideNow();advanceTideSides(at:at)
        let ordered=tideSides.values.filter{$0.pose.shown}.sorted{$0.arrivalAt<$1.arrivalAt}
        var placed:[String:[CGRect]]=[:]
        for side in ordered {
            let id=side.id
            guard let item=items[id] else{continue}
            let others=tideSides.values.filter{$0.id != id && $0.pose.shown}
            let otherIDs=Set(others.map(\.id))
            let obstacles=items.values.filter{$0.conversation.id != id && !otherIDs.contains($0.conversation.id)}.flatMap{item in
                [item.glass,item.identity?.glassView].compactMap{$0}.filter{!$0.isHidden}.map(\.frame)
            }+base.bars+others.flatMap{placed[$0.id] ?? $0.physical}+(tideContentObstacles?() ?? [])
            let orb=side.render(title:item.conversation.title,color:Look.identity[item.conversation.identityIndex % Look.identity.count],obstacles:obstacles){[weak self] glass,rect,hidden in
                if glass === side.glass {self?.tideGlassCorners[ObjectIdentifier(glass)]=min(side.pose.radius.x,min(rect.width,rect.height)/2)}
                self?.writeGlass(glass,frame:rect,alpha:1,hidden:hidden,reason:"tideSide")
            }
            _=orb;placed[id]=side.physical
            guard side.pose.shown else{continue}
            tideSideHiddenSources.insert(id)
            do {
                writeGlass(item.glass,alpha:0,hidden:true,reason:"tideSideSource")
                item.decoration.setOpacity(0);item.decoration.setPresentationActive(false)
                if let identity=item.identity {writeGlass(identity.glassView,alpha:0,hidden:true,reason:"tideSideSource");identity.setOpacity(0);identity.setPresentationActive(false)}
            }
            if side.busy {onTideMotion?();onNeedsFramesUntil?(displayTime ?? latestDisplayTime)}
        }
        for (id,side) in tideSides where !side.pose.shown {
            let source=side.orbGlass.frame
            let wasShown=side.park(keepHalo:side.active)
            guard wasShown || tideSideHiddenSources.contains(id) else{continue}
            tideSideHiddenSources.remove(id)
            if let item=items[id] {
                let identity=item.identityOpacity.value(at:at)
                writeGlass(item.glass,frame:item.regular,alpha:CGFloat(1-identity),hidden:false,reason:"tideSideRestore");item.decoration.setOpacity(1-identity);item.decoration.setPresentationActive(ambientRunning && identity<1)
                if let orb=item.identity {writeGlass(orb.glassView,alpha:CGFloat(identity),hidden:false,reason:"tideSideRestore");orb.setOpacity(identity);orb.setPresentationActive(ambientRunning && identity>0)}
                let material=identity>=0.999 ? item.identity?.glassView:item.glass
                if let material,!Motion.reduce {
                    let tuning=RectSpring(dockFrom:source,to:glassFrame(material),response:0.50,damping:0.86)
                    queueContours([(material,source,nil)],tuning:tuning,stableRaw:false)
                }
            }
        }
        for (id,side) in tideSides where side.active && !side.pose.shown {
            guard let item=items[id] else{continue}
            side.renderWaitingHalo(title:item.conversation.title,color:Look.identity[item.conversation.identityIndex % Look.identity.count])
            if side.busy {onTideMotion?();onNeedsFramesUntil?(displayTime ?? latestDisplayTime)}
        }
    }
    private func requestTideReclaim(_ id:String) {
        guard !tideFrozen,tideTimeline?.active == true,tideMaterialShapes[id] != nil else{return}
        let delay=tideTimeline?.bubbles[id]?.busy == true ? 0.26:0
        tideReclaim=(id,tideNow()+delay)
        refreshTideProtection();onTideMotion?();onNeedsFrames?(0);scheduleTideWake()
        if delay==0 {serviceTideDeadline()}
    }
    private func tidePointerEvent(_ event:NSEvent) {
        guard !tideFrozen else{return}
        let point=view.convert(event.locationInWindow,from:nil)
        if let onTidePointer {onTidePointer(point)}
        else {let duration=pointer(point,now:tideNow());onNeedsFrames?(duration)}
    }
    /// Physical source poses belong to the next layout writer, including the retained brief being reclaimed.
    private var tideLayoutSources:[String:(rect:CGRect,velocity:CGRect)] {
        var result:[String:(CGRect,CGRect)]=[:]
        for id in tideAddTails.keys {if let item=items[id] {result[id]=(item.glass.frame,.zero)}}
        for (id,side) in tideSides where side.pose.shown {result[id]=(side.orbGlass.frame,.zero)}
        guard let motion=tideTimeline,motion.active else{return result}
        for (id,rect) in tideNodePoses {
            guard let node=motion.nodes[id] else{continue}
            let velocity=CGRect(x:node.right.v-node.width.v,y:-node.height.v/2-node.lift.v,width:node.width.v,height:node.height.v)
            result[id]=(rect,tideFrozen ? .zero:velocity)
        }
        for (id,contour) in tideMaterialPoses {
            guard let b=motion.bubbles[id] else{continue}
            result[id]=(contour.body.rect,tideFrozen ? .zero:CGRect(x:b.left.v,y:-b.height.v/2,width:b.width.v,height:b.height.v))
        }
        return result
    }
    /// Freeze the actual source pose before mode capture; retirement follows the host's suspend entry.
    func freezeTideForMode(fading:Bool=false) {
        guard !tideFrozen else{return}
        guard tideTimeline?.active == true || tideSides.values.contains(where:{$0.active}) || !tideAddTails.isEmpty else{return}
        tideFrozenSources=Dictionary(uniqueKeysWithValues:tideLayoutSources.keys.compactMap {id in
            guard let item=items[id] else{return nil}
            return (id,tideSides[id]?.pose.shown == true ? tideSides[id]!.orbGlass.frame:item.glass.frame)
        });tideFrozenAt=tideNow()
        tideFrozen=true;tideReclaim=nil;tideWords?.freezeInput()
        for side in tideSides.values {side.words.freezeInput();side.orbHit.interactive=false;side.orbHit.cancelPress()}
        for hit in tideBorrowHits.values {hit.interactive=false;hit.cancelPress()}
        tideWakeJob?.cancel();tideWakeJob=nil;tideWakeAt=nil
        tideWarmJob?.cancel();tideWarmJob=nil;tideWarmGeneration+=1
        if fading {
            tideModeExit.clear()
            for id in tideFrozenSources.keys {
                guard let item=items[id] else{continue}
                tideModeExit.include([item.glass,item.chromeHost,item.decoration.backView,item.decoration.frontView])
                if let identity=item.identity {tideModeExit.include([identity.glassView,identity.backView,identity.frontView])}
                if let face=tideFaces[id] {tideModeExit.include([face.orb.backView,face.orb.frontView])}
                tidePool[id]?.fadeModeExit(tideModeExit)
            }
            tideWords?.fadeModeExit(tideModeExit)
            for side in tideSides.values where side.active {side.fadeModeExit(tideModeExit)}
        }
    }
    /// Lifecycle starts at the accepted mode key, before cold body-photo work or native admission.
    func beginTideDeparture(using pictures:ModeDepartureSurfaces,in host:NSView,at time:Double) {
        freezeTideForMode(fading:true)
        tideModeExit.start(using:pictures,in:host,at:time)
    }
    var tideDepartureScreenState:[String:Any] {tideModeExit.probe}
    var tideDeparturePhoto:NSView? {tideModeExit.photo}
    /// Resigning key closes finite notification channels; it does not reset any displayed glass.
    func endTideInteraction() {
        guard !tideFrozen else{return}
        advanceTideClock(to:tideNow())
        for side in tideSides.values where side.active {side.dismiss(at:tideNow());side.words.freezeInput()}
        tideTimeline?.dismiss();tideWords?.freezeInput()
        scheduleTideWake();onTideMotion?();onNeedsFrames?(0)
    }
    /// The closing window owns its last compositor frame. Park only after its removal is submitted.
    private func closeTidePresentation() {
        freezeTideForMode()
        tideTimeline=nil
        DispatchQueue.main.async { [weak self] in self?.retireTide() }
    }
    func finishTideModeHandoff() {
        guard tideFrozen else{return}
        if tideModeExit.isExiting {retireTide();return}
        if let at=tideFrozenAt {
            let delta=max(0,tideNow()-at)
            for id in tideAddTails.keys {tideAddTails[id]?.began+=delta}
            if tideAddLayout != nil {tideAddLayout!.began+=delta}
        }
        tideFrozen=false;tideFrozenAt=nil;tideFrozenSources=[:]
        for side in tideSides.values where side.active {side.dismiss(at:tideNow())}
        tideMediaLast=tideNow();tideTimeline?.resumeClock(at:tideNow());tideTimeline?.dismiss()
        onTideMotion?();onNeedsFrames?(0);scheduleTideWake()
    }
    @discardableResult func dismissTide()->Bool {
        if !tideFrozen,tideSides.values.contains(where:{$0.active && !$0.motion.returning}) {
            for side in tideSides.values where side.active {side.dismiss(at:tideNow())}
            scheduleTideWake();onTideMotion?();onNeedsFrames?(0);return true
        }
        guard !tideFrozen,tideTimeline?.active == true,tideTimeline?.returning != true else{return false}
        advanceTideClock(to:tideNow());tideTimeline?.dismiss();scheduleTideWake();onTideMotion?();onNeedsFrames?(0)
        return true
    }
    func pinTide() {
        guard !tideFrozen else{return}
        advanceTideClock(to:tideNow());tideTimeline?.togglePin(at:tideNow(),protection:tideProtection())
        scheduleTideWake();onTideMotion?();onNeedsFrames?(0)
    }
    func refreshTideReduction() {tideTimeline?.reduced=Motion.reduce;if !tideFrozen,(tideTimeline?.active == true || tideSides.values.contains(where:{$0.active})) {onNeedsFrames?(0)}}
    private func prepareTideWords() {
        guard !(TideCompositePolicy.control && store?.usesLiveCore == false),tideWords == nil else{return}
        if tideDelivering || tideFrameMoving != nil {tideArrivalContentAllocations+=1}
        let began=CACurrentMediaTime()
        let words=DockTidePresentation(parent:view,below:container)
        words.onPin={ [weak self] in self?.pinTide() }
        words.onPointer={ [weak self] event in self?.tidePointerEvent(event) }
        words.onAction={ [weak self] action in
            guard let self,!self.tideFrozen,let owner=self.tideTimeline?.owner,self.tideTimeline?.action?.submitting == false else{return}
            self.onTideAction?(owner,action)
        }
        tideWords=words;tideWarmContentMS=max(tideWarmContentMS,(CACurrentMediaTime()-began)*1000)
    }
    /// Explicit mock diagnostic; the real Tide lifecycle never calls this ordinary-orb experiment.
    @discardableResult func beginTideAnimationTrial(owner:String)->Bool {
        guard store?.usesLiveCore == false,let item=items[owner],!item.conversation.isLiveConversation,item.role == .orb,tideTimeline?.active != true else{return false}
        endTideAnimationTrial()
        tideAnimationTrial=DockTideAnimationTrial(owner:owner,orb:item.decoration,parent:view,container:container)
        return true
    }
    func endTideAnimationTrial() {tideAnimationTrial?.finish(ambient:ambientRunning);tideAnimationTrial=nil}
    var tideClockOwners:[(String,Any)] {
        var result:[(String,Any)]=tideFaces.map{("tide.face."+$0.key,$0.value)}
        if let meDecoration {result.append(("dock.me",meDecoration))}
        for (id,item) in items {
            result += [("dock."+id+".orb",item.decoration),("dock."+id+".words",item.wordGaussian),("dock."+id+".peek",item.peekGaussian)]
            if let identity=item.identity {result.append(("dock."+id+".identity",identity))}
        }
        for (id,side) in tideSides {result += [("tide.side."+id+".orb",side.face.orb),("tide.side."+id+".content",side.words)]}
        return result
    }
    var tideAnimationDiagnostics:[String:Any] {
        ["mode":TideAnimationMode.selected.rawValue,"ambientLoops":"product-policy","filterPolicy":TideCompositePolicy.legacy ? "legacy":"detached","control":TideCompositePolicy.control && store?.usesLiveCore == false,"trial":tideAnimationTrial?.probe as Any? ?? NSNull(),
         "timers":["warmupPending":tideWarmJob != nil,"deadlinePending":tideWakeJob != nil,"deadlineAt":tideWakeAt as Any? ?? NSNull(),"repeatingTimers":0,"reclaimPending":tideReclaim != nil],
         "tideRequestsDisplayFrames":(tideTimeline?.busy == true || tideSides.values.contains{$0.busy} || !tideAddTails.isEmpty) && !tideFrozen]
    }
    private func tideAllowsAmbient(_ id:String)->Bool {
        if tideSides[id]?.pose.shown == true {return false}
        if tideFrozen,tidePresentedOwner==id {return false}
        return tidePresentedOwner != id || (tideTimeline?.ownerInk.opacity ?? 1)>0
    }
    private func countTideWrite() {
        guard tideTimeline?.active == true else{return}
        if tideFrameMoving ?? (tideTimeline?.busy == true) {tideMovingWrites+=1}else{tideStillWrites+=1}
    }
    /// Called in small idle slices; never drains material construction from store.apply or a display callback.
    func prepareTideMaterialNow() {
        prepareTideWords()
        for item in tideWarmCandidates() {warmTideItem(item,complete:true)}
    }
    private func tideWarmCandidates()->[Item] {
        if TideCompositePolicy.control,store?.usesLiveCore == false {return []}
        let bars=items.values.filter{$0.role == .bar && !$0.full}.sorted{$0.target.minX>$1.target.minX}.prefix(2)
        return Array(bars)+items.values.filter{$0.role == .orb}.sorted{$0.slot<$1.slot}
    }
    private func warmTideItem(_ item:Item,complete:Bool) {
        let began=CACurrentMediaTime();defer{tideWarmMaxSliceMS=max(tideWarmMaxSliceMS,(CACurrentMediaTime()-began)*1000)}
        let id=item.conversation.id
        if item.role == .bar {
            if tideBorrowHits[id] == nil {
                let hit=DockTideHitView();hit.orbID=id;hit.isHidden=true;hit.onPress={ [weak self] in self?.requestTideReclaim(id) }
                hit.onPointer={ [weak self] event in self?.tidePointerEvent(event) }
                view.addSubview(hit);tideBorrowHits[id]=hit
            }
            if tidePool[id]?.matches(item.glass) != true {
                tidePool[id]?.dispose()
                tidePool[id]=DockTideShape(owner:id,parent:content,material:item.glass,shadowParent:view,allocate:false)
                tidePool[id]?.onTintWrite={ [weak self] in self?.countTideWrite() }
                tidePool[id]?.onAllocation={ [weak self] in
                    guard let self else{return}
                    if self.tideDelivering || self.tideFrameMoving != nil {self.tideArrivalAllocations+=1}
                    self.countTideWrite()
                }
            }
            if complete {while tidePool[id]?.ready == false {tidePool[id]?.prepareOne()}}
            else if tidePool[id]?.ready == false {tidePool[id]?.prepareOne();return}
        }
        if sideEligible(item) {
            if tideSides[id] == nil || tideSides[id]?.restingAnchor != item.target {
                tideSides.removeValue(forKey:id)?.dispose()
                let top=base.bars.map(\.minY).min() ?? item.target.minY
                let side=DockTideSide(id:id,anchor:item.target,composerTop:top,parent:content,inkParent:view,container:container,style:item.glass.style,configuration:makeOrbConfiguration(item.conversation,drawingSize:48,backingScale:view.window?.backingScaleFactor ?? 2,reduceMotion:Motion.reduce,ambient:false,isKeyWindow:true))
                side.orbHit.orbID=id
                side.onWake={ [weak self] in self?.onTideMotion?();self?.onNeedsFrames?(0);self?.scheduleTideWake() }
                side.words.onPin={ [weak self,weak side] in guard let self,!self.tideFrozen else{return};side?.pin(at:self.tideNow()) }
                side.words.onAction={ [weak self,weak side] action in
                    guard let self,!self.tideFrozen,side?.motion.action?.submitting == false else{return}
                    self.onTideAction?(id,action)
                }
                side.words.onPointer={ [weak self] event in self?.tidePointerEvent(event) }
                tideSides[id]=side
            }
            if complete {while tideSides[id]?.ready == false {tideSides[id]?.prepareOne()}}
            else if tideSides[id]?.ready == false {tideSides[id]?.prepareOne();return}
            if let queued=tideSideQueued.removeValue(forKey:id) {
                sunHoverTideBacklog.forgetSide(queued, owner: id)
#if M1139_CHECK
                traceSunHoverTide(queued, owner: id)
#endif
                tideSides[id]?.receive(item.conversation.notices.snapshot(in:item.conversation),incoming:queued,at:tideNow());packTideSides();onNeedsFrames?(0);scheduleTideWake()
            }
        }
        if tideFaces[id] == nil {
            let c=makeOrbConfiguration(item.conversation,drawingSize:48,backingScale:view.window?.backingScaleFactor ?? 2,reduceMotion:false,ambient:false,isKeyWindow:true)
            let face=DockTideFace(id:id,glass:item.glass,configuration:c)
            mount(face.orb);tideFaces[id]=face
        }
    }
    private func scheduleTideWarmup(after delay:Double=0.6) {
        guard tideWarmJob == nil else{return}
        let generation=tideWarmGeneration
        let job=DispatchWorkItem { [weak self] in
            guard let self,self.tideWarmGeneration==generation else{return}
            self.tideWarmJob=nil
            guard self.tideWarmAllowed?() != false else{return}
            if self.tideTimeline?.active != true,let event=NSApp.currentEvent,CACurrentMediaTime()-event.timestamp<0.25 {
                self.scheduleTideWarmup(after:0.25);return
            }
            self.prepareTideWords()
            if let item=self.tideWarmCandidates().first(where:{i in self.tideFaces[i.conversation.id] == nil || (self.sideEligible(i) && self.tideSides[i.conversation.id]?.ready != true) || (i.role == .bar && self.tidePool[i.conversation.id]?.ready != true)}) {
                self.warmTideItem(item,complete:false);self.scheduleTideWarmup(after:0.003)
            }
        }
        tideWarmJob=job;DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:job)
    }
    private func advanceTideClock(to time:Double) {
        guard tideTimeline?.active == true,!tideFrozen else{return}
        tideTimeline?.reduced=Motion.reduce
        tideTimeline?.step(max(0,time-(tideMediaLast ?? time)),settleFromRest:true);tideMediaLast=time
        if tideTimeline?.active == false,!Motion.reduce {
            for (id,source) in tideNodePoses {
                guard let item=items[id],item.role == .orb,MotionStep.edge(source,item.regular)>0.001 else{continue}
                let tuning=RectSpring(dockFrom:source,to:item.regular,response:0.50,damping:0.86)
                queueContours([(item.glass,source,nil)],tuning:tuning,stableRaw:false)
            }
        }
    }
    private func scheduleTideWake() {
        guard !tideFrozen else {tideWakeJob?.cancel();tideWakeJob=nil;tideWakeAt=nil;return}
        let now=tideNow()
        advanceTideSides(at:now)
        if tideSides.values.contains(where:{$0.busy}) {onTideMotion?();onNeedsFrames?(0)}
        var delays=[tideTimeline?.nextWake]
        delays += tideSides.values.filter{ $0.motion.active }.map{ $0.nextWake }
        if let reclaim=tideReclaim {delays.append(max(0,reclaim.due-now))}
        if tideTimeline?.active == true,let release=tideTimeline?.leases.nextProtectionRelease(after:now) {delays.append(release-now)}
        guard let delay=delays.compactMap({$0}).min() else {tideWakeJob?.cancel();tideWakeJob=nil;tideWakeAt=nil;return}
        let due=now+max(0.001,delay)
        if let old=tideWakeAt,abs(old-due)<0.005 {return}
        tideWakeJob?.cancel();tideWakeAt=due
        let job=DispatchWorkItem { [weak self] in self?.serviceTideDeadline() }
        tideWakeJob=job;DispatchQueue.main.asyncAfter(deadline:.now()+max(0.001,delay),execute:job)
    }
    /// The timer also has a deterministic entry for detached verification with an injected clock.
    func serviceTideDeadline() {
        let due=tideWakeAt,at=tideNow()
        tideWakeJob?.cancel();tideWakeJob=nil;tideWakeAt=nil
        guard !tideFrozen else{return}
        if let due {
            tideLastWakeDriftMS=(at-due)*1000
        }
        advanceTideSides(at:tideNow())
        let previousHover=tideTimeline?.hovering
        advanceTideClock(to:tideNow());refreshTideProtection()
        if let reclaim=tideReclaim,reclaim.due<=tideNow()+1e-8 {
            tideReclaim=nil;onTideReclaim?(reclaim.id)
        }
        if tideTimeline?.busy == true || tideSides.values.contains(where:{$0.busy}) || previousHover != tideTimeline?.hovering {onTideMotion?();onNeedsFrames?(0)}
        scheduleTideWake()
    }
    private func tideNow()->Double {motionTime?() ?? CACurrentMediaTime()}
    private func configureTide() {
        if trashReflowPending { reflowTrashTide();trashReflowPending=false;return }
        retireTide();tideMinimumGap = .infinity;tideWorstPair=""
        for id in Array(tideSides.keys) where items[id].map({!sideEligible($0)}) ?? true {tideSides.removeValue(forKey:id)?.dispose()}
        for id in Array(tidePool.keys) where items[id] == nil {tidePool.removeValue(forKey:id)?.dispose()}
        for id in Array(tideFaces.keys) where items[id] == nil || tideFaces[id]?.orb.glassView !== items[id]?.glass {tideFaces.removeValue(forKey:id)?.dispose()}
        for id in Array(tideBorrowHits.keys) where items[id] == nil {tideBorrowHits.removeValue(forKey:id)?.removeFromSuperview()}
        let bars=items.values.filter{$0.role == .bar}.sorted{$0.target.minX>$1.target.minX}
        let briefs=bars.prefix(while:{!$0.full}).map{($0.conversation.id,$0.target)}
        let orbs=items.values.filter{$0.role == .orb && $0.slot >= base.leading}.sorted{$0.target.minX<$1.target.minX}.map{($0.conversation.id,$0.target)}
        if let add=tideLeaseMemory.add,add.committed {
            let needed=add.briefs.prefix{items[$0]?.role == .orb}.count
            _=tideLeaseMemory.updateAddCapacity(requiredBriefs:needed)
        }
        tideTimeline=TideMotion(briefs:briefs,orbs:orbs)
        tideTimeline?.leases=tideLeaseMemory
        refreshTideProtection()
        scheduleTideWarmup()
        tideCursors=Dictionary(uniqueKeysWithValues:items.values.map{($0.conversation.id,$0.conversation.notices.journal.last?.id ?? 0)})
    }
    func retireTide() {
        tideModeExit.clear()
        let retiredNodes=Array(tideNodePoses.keys)
        tideFrozen=false;tideFrozenAt=nil;tideFrozenSources=[:];tideReclaim=nil
        for id in tideAddTails.keys {tidePool[id]?.park();tideFaces[id]?.park()}
        tideAddTails.removeAll();tideAddLayout=nil
        for (id,side) in tideSides {side.retire();tideFaces[id]?.park();items[id]?.decoration.setOpacity(1)}
        for id in tideSideHiddenSources {
            guard let item=items[id] else{continue}
            let alpha=item.identityOpacity.value(at:motionNow())
            writeGlass(item.glass,frame:item.regular,alpha:CGFloat(1-alpha),hidden:false,reason:"tideSideRetire")
            item.decoration.setOpacity(1-alpha)
            if let identity=item.identity {writeGlass(identity.glassView,alpha:CGFloat(alpha),hidden:false,reason:"tideSideRetire");identity.setOpacity(alpha)}
        }
        onTideReadingRoom?([])
        tideSideQueued.removeAll();sunHoverTideBacklog.discardSide();tideSideHiddenSources.removeAll();tideSideFitCache.removeAll();tideSideLive=false
        endTideAnimationTrial()
        tideWakeJob?.cancel();tideWakeJob=nil;tideWakeAt=nil
        tideWarmJob?.cancel();tideWarmJob=nil;tideWarmGeneration+=1
        tideLeaseMemory=tideTimeline?.leases ?? tideLeaseMemory;tideLeaseMemory.retire()
        if let id=tidePresentedOwner {tideFaces[id]?.park();items[id]?.decoration.setOpacity(items[id]?.role == .orb ? 1:0);items[id]?.decoration.setPresentationActive(ambientRunning && items[id]?.role == .orb)}
        tidePresentedOwner=nil
        for hit in tideBorrowHits.values {hit.isHidden=true;hit.cancelPress()}
        tideTimeline=nil;tideMediaLast=nil;tideDynamic=false;tideNodePoses=[:]
        tideWords?.park();clearTideMaterialProbe()
        for id in retiredNodes {if let item=items[id] {place(item,item.motion.rect ?? item.target)}}
    }
    /// Mock capacity input, not a presentation override. The next Core event still applies for the lease.
    func setTideCapacityFixture(_ width:Double?) {
        guard store?.usesLiveCore == false else{return}
        tideTimeline?.capacityDemand=width
    }
    func tideOwns(_ id:String)->Bool {
        if tideSides[id]?.pose.shown == true {return true}
        guard tideTimeline?.owner==id else{return false}
        if tideTimeline?.action?.requestID != nil {return true}
        return (tideTimeline?.nodes[id]?.width.value.target ?? 32)>32 || (tideNodePoses[id]?.width ?? 32)>32
    }
    func tideHasNotice(_ id:String)->Bool {tideTimeline?.owner==id || tideSides[id]?.pose.shown == true}
    private func tideProtection()->[String:Set<DockSlotLeases.Reason>] {
        var result:[String:Set<DockSlotLeases.Reason>]=[:]
        for id in items.keys where items[id]?.role == .bar {
            guard let item=items[id] else{continue};let c=item.conversation,editor=item.composer
            var reasons:Set<DockSlotLeases.Reason>=[]
            if item.full {reasons.insert(.fullColumn)}
            if !c.draft.isEmpty || editor?.text.isEmpty == false {reasons.insert(.draft)}
            if !c.attachments.isEmpty || editor?.attachments.isEmpty == false || editor?.hasAttachments == true {reasons.insert(.attachment)}
            if editor?.editorFocused == true || focusTarget == id {reasons.insert(.focus)}
            if editor?.isComposing == true {reasons.insert(.markedText)}
            if editor?.isChoosingAttachments == true {reasons.insert(.choosingAttachment)}
            if c.sending || editor?.hasPendingSubmission == true || editor?.state.sending == true || editor?.state.outcomeUnknown == true {reasons.insert(.submitting)}
            if carries(id) || tideReclaim?.id==id {reasons.insert(.reclaimed)}
            if let p=tidePointer,(tideMaterialPoses[id]?.body.rect ?? glassFrame(item.glass)).contains(p) {reasons.insert(.hover)}
            result[id]=reasons
        }
        return result
    }
    private func refreshTideProtection() {
        guard !tideFrozen else{return}
        let wasBusy=tideTimeline?.busy == true
        let facts=tideProtection()
        tideTimeline?.protect(facts,at:tideNow())
        if let leases=tideTimeline?.leases {tideLeaseMemory=leases}
        if !wasBusy,tideTimeline?.busy == true {onTideMotion?();onNeedsFrames?(0)}
        if tideTimeline?.active == true {scheduleTideWake()}
    }
    private func watchTideEditor(_ editor:NativeComposer) {
        guard !tideWatchedEditors.contains(editor) else{return}
        tideWatchedEditors.add(editor)
        let contents=editor.onMotionContentsChange,focus=editor.onFocusChange
        editor.onMotionContentsChange={ [weak self] in contents?();self?.refreshTideProtection() }
        editor.onFocusChange={ [weak self] value in focus?(value);self?.refreshTideProtection() }
    }
    /// Called by AutoScene's existing observer before transcript coalescing. UI IDs stay unchanged.
    func receiveTide(_ c:Conversation,enabled:Bool=true) {
        tideDelivering=true;defer{tideDelivering=false}
        let snapshot=c.notices.snapshot(in:c)
        questionDiagnostics.observe(snapshot,owner:c.id)
        let previous=tideCursors[c.id] ?? snapshot.journal.last?.id ?? 0
        tideCursors[c.id]=max(previous,snapshot.journal.last?.id ?? 0)
        refreshTideProtection()
        if (sunHoverTideBacklog.isDeferring || !sunHoverTideBacklog.isEmpty), items[c.id] != nil, !(TideCompositePolicy.control && store?.usesLiveCore == false) {
            sunHoverTideBacklog.append(snapshot.journal.filter { $0.id > previous }, owner: c.id)
            if enabled { resumeSunHoverTide(source: "arrival") }
            return
        }
        deliverTide(c, snapshot: snapshot, after: previous, enabled: enabled)
    }
    /// Ordinary arrivals and hover replay share all admission, expiry, text and wake rules.
    private func deliverTide(_ c: Conversation, snapshot: ConversationNoticeSnapshot, incoming values: [ConversationNotice]? = nil, after previous: Int = 0, enabled: Bool) {
        tideDelivering=true;defer{tideDelivering=false}
        func pendingNotices() -> [ConversationNotice] {
            (values ?? snapshot.journal).filter { notice in (values != nil || notice.id > previous) && (notice.requestID == nil || snapshot.pending.contains(where: { $0.requestID == notice.requestID })) }
        }
        if enabled,!tideFrozen,let item=items[c.id],sideEligible(item),!(TideCompositePolicy.control && store?.usesLiveCore == false) {
            let incoming = pendingNotices()
            if let side=tideSides[c.id],side.ready {
                side.configure(makeOrbConfiguration(c,drawingSize:48,backingScale:view.window?.backingScaleFactor ?? 2,reduceMotion:Motion.reduce,ambient:false,isKeyWindow:true))
#if M1139_CHECK
                traceSunHoverTide(incoming, owner: c.id)
#endif
                side.receive(snapshot,incoming:incoming,at:tideNow());packTideSides()
                if side.busy {onTideMotion?();onNeedsFrames?(0)}
                scheduleTideWake()
            } else if !incoming.isEmpty {sunHoverTideBacklog.recordSide(incoming, owner: c.id);tideSideQueued[c.id,default:[]]+=incoming;scheduleTideWarmup(after:0)}
            return
        }
        guard !(TideCompositePolicy.control && store?.usesLiveCore == false),enabled,!tideFrozen,tideAddTails.isEmpty,!base.focused,items[c.id]?.role == .orb,(items[c.id]?.slot ?? -1)>=base.leading,buds[c.id]?.open != true else{return}
        if tideTimeline == nil {configureTide()}
        let at=tideNow()
        advanceTideClock(to:at)
        let previousEvent=tideTimeline?.event,previousBusy=tideTimeline?.busy
        tideTimeline?.syncPending(snapshot,owner:c.id)
        if tideTimeline?.active == true,(previousEvent != tideTimeline?.event || previousBusy != tideTimeline?.busy) {
            onTideMotion?();onNeedsFrames?(0)
        }
        let incoming = pendingNotices()
        // Advance old clocks up to arrival before installing a new event's deadline.
        if !incoming.isEmpty {advanceTideClock(to:at)}
        for notice in incoming {
            // Expiring an already dismissed request is silent cleanup, not a fresh space requisition.
            if notice.kind == .reply,notice.text == "Request expired",
               tideTimeline?.owner != c.id || tideTimeline?.returning == true {continue}
            if tideTimeline?.active != true {
                tideMediaLast=at;tideMovingCallbacks=0;tideStillCallbacks=0;tideMovingWrites=0;tideStillWrites=0;tideArrivalAllocations=0;tideArrivalContentAllocations=0
            }
            let protection=tideProtection()
#if M1139_CHECK
            traceSunHoverTide([notice], owner: c.id)
#endif
            tideTimeline?.receive(notice,owner:c.id,at:at,protection:protection)
            if tideTimeline?.busy == true {onTideMotion?()}
            onNeedsFrames?(0);scheduleTideWarmup(after:0);scheduleTideWake()
        }
        if tideTimeline?.owner == c.id,let notice=snapshot.journal.first(where:{$0.id == tideTimeline?.event?.id}) {tideTimeline?.updateText(notice.text);scheduleTideWake()}
    }
    private var tidePresentationProbe:[String:Any] {
        var probe=tideWords?.probe ?? [:]
        probe["interactive"]=tideTimeline?.active == true && !tideFrozen
        if tideFrozen,let rows=probe["buttons"] as? [[String:Any]] {
            probe["buttons"]=rows.map{row in var value=row;value["enabled"]=false;return value}
        }
        return probe
    }
    /// Small retained sample. Before the first physical batch only, gap falls back to the visible row frames.
    /// No layer inventory, mask/filter walk or full diagnostic snapshot runs here.
    var tideLightProbe:[String:Any] {
        guard let m=tideTimeline else{return ["phase":"idle","physicalSampled":false,"side":tideSideProbe,"add":tideAddProbe]}
        let age=m.paused || tideFrozen ? 0:max(0,tideNow()-(tideMediaLast ?? tideNow()))
        return ["side":tideSideProbe,"add":tideAddProbe,"modeExit":tideModeExit.probe,"frozenSources":tideFrozenSources.mapValues(DockTideShape.rect),"phase":m.active ? (tideFrozen ? "frozen":m.returning ? "returning":"holding"):"idle","owner":m.owner ?? "",
            "event":m.event?.kind.rawValue ?? "","eventRemaining":max(0,m.eventRemaining-age),"occupancyRemaining":max(0,m.occupancyRemaining-age),
            "wakeDriftMS":tideLastWakeDriftMS,"questionWarningCount":questionDiagnostics.warnings.count,"poseAt":tideMediaLast ?? 0,"frameTarget":displayTime ?? latestDisplayTime,"level":m.level,"generation":m.leases.generation,"progress":m.progress as Any? ?? NSNull(),"motionBusy":m.busy && !tideFrozen,"nextWakeAt":tideWakeAt as Any? ?? NSNull(),
            "rect":m.owner.flatMap{tideNodePoses[$0]}.map{DockTideShape.rect($0)} ?? [],"physicalSampled":false,
            "minimumGap":tideReportedGap as Any? ?? NSNull(),"tailBudget":TideTailBudget.pieces,
            "displayCallbacks":["moving":tideMovingCallbacks,"still":tideStillCallbacks],"glassWrites":["moving":tideMovingWrites,"still":tideStillWrites],
            "arrivalGlassAllocations":tideArrivalAllocations,"arrivalContentAllocations":tideArrivalContentAllocations,"warmMaxSliceMS":tideWarmMaxSliceMS,"warmContentMS":tideWarmContentMS,"preparedTailViews":tidePool.mapValues{$0.views.count},
            "pending":m.pending.map{["owner":$0.owner,"requestID":$0.notice.requestID ?? ""]},"presentation":tidePresentationProbe,"material":tideMaterialLightProbe]
    }
    var tideMaterialLightProbe:[String:Any] {
        ["physicalSampled":false,"tailBudget":TideTailBudget.pieces,"shapes":tideMaterialShapes.keys.sorted().map {id -> [String:Any] in
            ["owner":id,"allocatedTailViews":tideMaterialShapes[id]?.views.count ?? 0,"body":tideMaterialPoses[id].map{DockTideShape.rect($0.body.rect)} ?? []]
        }]
    }
    private var tideReportedGap:Double? {
        if tideMinimumGap.isFinite {return tideMinimumGap}
        let bodies=items.values.filter {!$0.glass.isHidden && $0.glass.layer?.isHidden != true && $0.glass.alphaValue>0.001}.map(\.glass.frame)
        return bodies.enumerated().flatMap {i,a in bodies.dropFirst(i+1).map {Double(TideContour.gap(a,$0))}}.min()
    }
    var tideProbe:[String:Any] {
        guard let m=tideTimeline else{return ["phase":"idle"]}
        let age=m.paused || tideFrozen ? 0:max(0,tideNow()-(tideMediaLast ?? tideNow()))
        return ["side":tideSideProbe,"add":tideAddProbe,"modeExit":tideModeExit.probe,"frozenSources":tideFrozenSources.mapValues(DockTideShape.rect),"phase":m.active ? (tideFrozen ? "frozen":m.returning ? "returning":"holding"):"idle","owner":m.owner ?? "",
            "event":m.event?.kind.rawValue ?? "","eventRemaining":max(0,m.eventRemaining-age),"occupancyRemaining":max(0,m.occupancyRemaining-age),
            "questionWarnings":questionDiagnostics.warnings,"capacityDemand":m.capacityDemand as Any? ?? NSNull(),"elapsed":m.elapsed,"level":m.level,"generation":m.leases.generation,"lyric":m.lyric,
            "contentAlpha":m.ink.opacity,"degraded":tideDegraded,"minimumGap":tideReportedGap as Any? ?? NSNull(),"worstPair":tideWorstPair,
            "tailBudget":TideTailBudget.pieces,"motionBusy":m.busy && !tideFrozen,"nextWakeAt":tideWakeAt as Any? ?? NSNull(),
            "displayCallbacks":["moving":tideMovingCallbacks,"still":tideStillCallbacks],"glassWrites":["moving":tideMovingWrites,"still":tideStillWrites],"arrivalGlassAllocations":tideArrivalAllocations,"arrivalContentAllocations":tideArrivalContentAllocations,"warmMaxSliceMS":tideWarmMaxSliceMS,"warmContentMS":tideWarmContentMS,"preparedTailViews":tidePool.mapValues{$0.views.count},
            "faces":tideFaces.mapValues{$0.probe},"ownerOriginalOpacity":m.ownerInk.opacity,
            "sampleAt":tideMediaLast ?? 0,"frameTarget":displayTime ?? latestDisplayTime,
            "bubbles":m.briefOrder.compactMap { id -> [String:Any]? in guard let b=m.bubbles[id] else{return nil};return ["id":id,"raw":DockTideShape.rect(b.rect),"tail":b.tail.x,"lean":b.lean.x,"content":b.content.opacity,"face":b.face.opacity] },
            "nodes":tideNodePoses.mapValues{DockTideShape.rect($0)},"pending":m.pending.map{["owner":$0.owner,"requestID":$0.notice.requestID ?? ""]},"presentation":tidePresentationProbe,"material":tideMaterialProbe]
    }
    private func applyDynamicTide() {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        if tideFrozen {
            if tideModeExit.isExiting {return}
            for (id,rect) in tideFrozenSources {
                guard let item=items[id],tideSides[id]?.pose.shown != true else{continue}
                if tideAddTails[id] != nil {item.motion.reset(rect)}
                writeGlass(item.glass,frame:rect,alpha:1,hidden:false,reason:"tideModeFreeze");item.shape(rect)
                if tideTimeline?.owner==id {item.decoration.setOpacity(Float(tideTimeline?.ownerInk.opacity ?? 0));item.decoration.setPresentationActive(false)}
            }
            return
        }
        refreshTideProtection()
        guard tideTimeline?.active == true || tideDynamic else{return}
        let at=tideNow()
        let protection=tideProtection()
        tideTimeline?.protect(protection,at:at);advanceTideClock(to:at);scheduleTideWake()
        guard let m=tideTimeline,m.active else {
            if let id=tidePresentedOwner {tideFaces[id]?.park();items[id]?.decoration.setOpacity(items[id]?.role == .orb ? 1:0);items[id]?.decoration.setPresentationActive(ambientRunning && items[id]?.role == .orb)}
            tidePresentedOwner=nil
            let retired=Set(tideNodePoses.keys).union(tideMaterialShapes.keys)
            tideDynamic=false;tideNodePoses=[:];clearTideMaterialProbe();tideWords?.park()
            for id in retired {if let item=items[id] {place(item,item.regular)}}
            onTideReadingRoom?([])
            return
        }
        if tideFrameMoving != nil {tideFrameMoving = tideFrameMoving == true || m.busy || (tideLastAppliedRise != nil && tideLastAppliedRise != rise)}
        tideLastAppliedRise=rise
        tideDynamic=true;tideDegraded=false
        let wanted=Set(m.briefOrder.prefix(m.level))
        for id in wanted where tideMaterialShapes[id] == nil {
            guard let item=items[id] else{continue}
            tideMaterialSavedPaint[id]=(item.chromeHost.isHidden,item.grip.isHidden)
            if tidePool[id] == nil {
                tidePool[id]=DockTideShape(owner:id,parent:content,material:item.glass,shadowParent:view,allocate:false)
                tidePool[id]?.onTintWrite={ [weak self] in self?.countTideWrite() }
                tidePool[id]?.onAllocation={ [weak self] in
                    guard let self else{return}
                    if self.tideDelivering || self.tideFrameMoving != nil {self.tideArrivalAllocations+=1}
                    self.countTideWrite()
                }
            }
            tideMaterialShapes[id]=tidePool[id]
            scheduleTideWarmup(after:0)
        }
        let previousPoses=tideMaterialPoses
        tideMaterialPoses=[:]
        for id in m.briefOrder.reversed() where tideMaterialShapes[id] != nil {
            guard let b=m.bubbles[id] else{continue};var r=b.rect.offsetBy(dx:0,dy:-rise)
            for other in items.values where other.role == .bar && other.conversation.id != id && other.target.minX<b.original.minX {
                let o=tideMaterialPoses[other.conversation.id]?.body.rect ?? glassFrame(other.glass)
                r.origin.x=max(r.minX,o.maxX+12)
            }
            let input=TideMaterialPose(owner:id,body:r,tailAmount:b.tail.x,lean:b.lean.x,horizontalVelocity:b.left.v,retracting:b.tail.value.target==0 && b.tail.v<0)
            if tideContourInputs[id] == input,let old=previousPoses[id] {tideMaterialPoses[id]=old}
            else {tideContourInputs[id]=input;tideMaterialPoses[id]=input.contour}
        }
        let displayedNodes=tideNodePoses
        tideNodePoses=[:]
        // The refusal spring can rebound past the resting width. Admit against that same-frame
        // glass, not the ordinary placement that will be overwritten later in this batch.
        for id in m.briefOrder where !Set(m.briefOrder.prefix(m.level)).contains(id) && tideMaterialShapes[id] == nil {
            guard let bubble=m.bubbles[id],abs(bubble.width.x-bubble.original.width)>0.001,let item=items[id] else{continue}
            let r=bubble.rect.offsetBy(dx:0,dy:-rise)
            tideNodePoses[id]=r;writeGlass(item.glass,frame:r,alpha:1,hidden:false,reason:"tideRefusal")
        }
        let excluded=Set(m.orbOrder).union(tideMaterialPoses.keys)
        let obstacles=materialObstacles(excluding:excluded)+tideMaterialPoses.values.flatMap{$0.parts.map(\.rect)}
        // Round both sides of a reserved slot outwards. Subtracting an epsilon only from its
        // right edge made the last 32 pt neighbour miss the left-hand 12 pt test by one ulp.
        let rowClearance=12.0+0.000_000_1
        var nextEdge=Double.infinity
        for (index,id) in m.orbOrder.enumerated().reversed() {
            guard let node=m.nodes[id] else{continue}
            var raw=node.rect.offsetBy(dx:0,dy:-rise)
            let raised=id==m.owner && node.lift.x>1
            var rowCapacity=node.widthDemand
            if raised {
                let right=min(raw.maxX,nextEdge-12-1e-9)
                raw.origin.x=right-raw.width
            } else {
                // Bounded row admission, not a second spring or a joint topology solver.
                // Only a returning notification may be wider than the ordinary 32 pt minimum.
                let left=obstacles.filter{raw.minY<$0.maxY+rowClearance && raw.maxY>$0.minY-rowClearance}.map{$0.maxX+rowClearance}.max() ?? 0
                let reserve=Double(index)*(32+rowClearance)
                // Reconstructing maxX must stay on the legal side of an exact 12 pt boundary.
                let rightLimit=nextEdge-rowClearance
                let right=min(rightLimit,max(min(raw.maxX,rightLimit),left+reserve+32))
                rowCapacity=max(32,right-left-reserve)
                let width=max(32,min(raw.width,rowCapacity))
                if width<raw.width-0.001 {tideDegraded=true}
                raw=CGRect(x:right-width,y:raw.minY,width:width,height:max(32,raw.height))
            }
            let other=obstacles+Array(tideNodePoses.values)
            var r=TideContour.admit(raw,obstacles:other)
            if id==m.owner,let previous=displayedNodes[id],previous.width>68,
               (r?.width ?? 0)<raw.width-0.001 {
                let ceiling=other.filter{raw.minX<$0.maxX+12 && raw.maxX>$0.minX-12}.map{$0.minY-12}.min()
                if let ceiling,previous.maxY<=ceiling+0.001 {
                    // Reverse the handoff: keep the admitted card above its neighbour until it fits the row.
                    var floating=raw;floating.origin.y=min(raw.minY,ceiling-raw.height)
                    if let admitted=TideContour.admit(floating,obstacles:other),abs(admitted.width-raw.width)<0.001 {r=admitted}
                }
            }
            if r == nil {
                let orb=CGRect(x:raw.maxX-32,y:raw.midY-16,width:32,height:32)
                r=TideContour.admit(orb,obstacles:other)
            }
            guard let fitted=r else {
                // An owner never gets permission to cover a protected editor. Keep its last legal orb.
                tideDegraded=true
                continue
            }
            if fitted.width<raw.width-0.001 {tideDegraded=true}
            tideNodePoses[id]=fitted
            if id==m.owner,(node.lift.x>1 || node.lift.value.target>0) {
                tideTimeline?.acceptRaisedPose(fitted.offsetBy(dx:0,dy:rise),for:id)
            } else {
                let demand=min(node.widthDemand,rowCapacity)
                let maximum=CGRect(x:raw.maxX-demand,y:raw.minY,width:demand,height:raw.height)
                let capacity=TideContour.admit(maximum,obstacles:other)?.width ?? 32
                tideTimeline?.acceptRowPose(fitted.offsetBy(dx:0,dy:rise),capacity:capacity,for:id)
            }
            if !raised {nextEdge=fitted.minX}
        }
        for id in m.orbOrder {
            if let item=items[id],let r=tideNodePoses[id] {
                writeGlass(item.glass,frame:r,alpha:1,hidden:false,reason:id==m.owner ? "tideNotification":"tideRow");item.shape(r)
            }
        }
        onTideReadingRoom?(m.owner.flatMap {id in tideNodePoses[id].flatMap {r in r.minY < (items[id]?.regular.minY ?? r.minY)-1 ? [r]:nil}} ?? [])
        if let id=m.owner,let r=tideNodePoses[id],let item=items[id] {
            prepareTideWords()
            // Requisitioned brief tails belong to other conversations, never to this notice's halo.
            tideWords?.render(m,rect:r,tailBounds:nil,title:item.conversation.title,color:Look.identity[item.conversation.identityIndex % Look.identity.count],glyph:orbIdentity(of:item.conversation).symbol)
            if let old=tidePresentedOwner,old != id {
                tideFaces[old]?.park();items[old]?.decoration.setOpacity(1)
                items[old]?.decoration.setPresentationActive(ambientRunning)
            }
            tidePresentedOwner=id
            item.decoration.setOpacity(Float(m.ownerInk.opacity))
            item.decoration.setPresentationActive(m.ownerInk.opacity>0 && ambientRunning)
            tideFaces[id]?.hide()
        }
    }

    // M11.34 material validation is opt-in and mock-only, pending WindowServer approval of the tail.
    private var tideMaterialShapes: [String: DockTideShape] = [:]
    private var tideMaterialPoses: [String: TideContour] = [:]
    private var tideContourInputs:[String:TideMaterialPose]=[:]
    private var tideMaterialSavedPaint: [String: (chrome: Bool, grip: Bool)] = [:]
    private var tideMaterialSuppressed: Set<String> = []

    /// A static native material sample only. It deliberately does not implement Tide event playback.
    @discardableResult func stageTideMaterialProbe(_ poses: [TideMaterialPose]) -> Bool {
        guard store?.usesLiveCore == false, !base.focused, !poses.isEmpty,
              Set(poses.map(\.owner)).count == poses.count,
              poses.allSatisfy({ items[$0.owner]?.role == .bar && items[$0.owner]?.full == false
                  && items[$0.owner]?.conversation.isLiveConversation == false
                  && items[$0.owner]?.conversation.draft.isEmpty == true
                  && items[$0.owner]?.conversation.attachments.isEmpty == true
                  && items[$0.owner]?.composer?.isComposing != true
                  && items[$0.owner]?.composer?.editorFocused != true }) else { return false }
        let proposed = Dictionary(uniqueKeysWithValues: poses.map { ($0.owner,$0.contour) })
        for (id, contour) in proposed {
            let others = materialObstacles(excluding: Set(proposed.keys)) + proposed.filter { $0.key != id }.flatMap { $0.value.parts.map(\.rect) }
            guard others.allSatisfy({ contour.envelopeGap(to:$0) >= 12-1e-8 }) else { return false }
        }
        retireTide()
        tideMaterialPoses = proposed
        for id in proposed.keys.sorted() {
            guard let item = items[id] else { continue }
            tideMaterialSavedPaint[id] = (item.chromeHost.isHidden,item.grip.isHidden)
            warmTideItem(item,complete:true)
            tideMaterialShapes[id] = tidePool[id]
        }
        let batch=beginGlassBatch();applyTideMaterialProbe();endGlassBatch(batch)
        refreshOrbs()
        return true
    }

    func clearTideMaterialProbe() {
        guard !tideMaterialShapes.isEmpty else { return }
        let old=tideMaterialShapes
        tideMaterialShapes=[:];tideMaterialPoses=[:];tideContourInputs=[:];tideMaterialSuppressed=[]
        for (id, shape) in old {
            for glass in shape.views {writeGlass(glass,frame:.zero,hidden:true,reason:"tidePark")}
            shape.park();tideFaces[id]?.park();tideBorrowHits[id]?.isHidden=true
            if let item=items[id] {
                let saved=tideMaterialSavedPaint[id]
                item.chromeHost.isHidden=saved?.chrome ?? false;item.grip.isHidden=saved?.grip ?? false;item.grip.opacity=1
                item.chromeHost.layer?.opacity=1;item.chromeHost.layer?.transform=CATransform3DIdentity;item.chromeHost.layer?.filters=nil
                for layer in [item.decoration.frontView.layer,item.decoration.backView.layer] {layer?.filters=nil;layer?.transform=CATransform3DIdentity}
                item.decoration.setOpacity(item.role == .orb ? 1:0)
                place(item,item.motion.rect ?? item.target)
            }
        }
        tideMaterialSavedPaint=[:];tideInkFilters=[:];refreshOrbs()
    }

    var tideMaterialProbe: [String:Any] {
        ["validationOnly":true,"nativeFusionVerified":false,"containerSpacing":container.spacing,"tailBudget":TideTailBudget.pieces,"faces":tideFaces.mapValues{$0.probe},
         "suppressed":tideMaterialSuppressed.sorted(),"shapes":tideMaterialShapes.keys.sorted().map { tideMaterialShapes[$0]!.probe }]
    }

    private func materialObstacles(excluding ids:Set<String>) -> [CGRect] {
        var frames=items.filter { !ids.contains($0.key) && !glassHidden($0.value.glass) }.map { glassFrame($0.value.glass) }
        if let me,!glassHidden(me) {frames.append(glassFrame(me))}
        if let draftBar,!glassHidden(draftBar.glass) {frames.append(glassFrame(draftBar.glass))}
        return frames.filter { $0.width>0 && $0.height>0 }
    }

    private func applyTideMaterialProbe() {
        guard !tideFrozen else{return}
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        guard !tideMaterialShapes.isEmpty else { return }
        if base.focused || tideMaterialShapes.keys.contains(where: {
            items[$0]?.role != .bar || items[$0]?.full == true || carries($0)
                || items[$0]?.conversation.draft.isEmpty != true || items[$0]?.composer?.isComposing == true
        }) && !tideDynamic { clearTideMaterialProbe(); return }
        tideMaterialSuppressed=[]
        let ids=Set(tideMaterialShapes.keys)
        for id in ids.sorted() {
            guard let item=items[id],let shape=tideMaterialShapes[id],let proposed=tideMaterialPoses[id] else { continue }
            let others=materialObstacles(excluding:ids) + tideMaterialPoses.filter { $0.key != id }.flatMap { $0.value.parts.map(\.rect) }
            let contour:TideContour
            if others.allSatisfy({proposed.envelopeGap(to:$0)>=12-1e-8}) {contour=proposed}
            else {contour = .init(body:proposed.body.rect,tailAmount:0,lean:26);tideMaterialSuppressed.insert(id)}
            writeGlass(item.glass,frame:contour.body.rect,alpha:1,hidden:false,reason:"tideMaterial")
            let b=tideDynamic ? tideTimeline?.bubbles[id]:nil
            let face=b?.face.opacity ?? 1,ink=b?.content.opacity ?? 0
            if let hit=tideBorrowHits[id] {
                if hit.frame != contour.body.rect {hit.frame=contour.body.rect}
                hit.interactive = !tideFrozen
                hit.isHidden = !tideDynamic || (ink>=1 && !hit.hasPress)
            }
            item.shape(contour.body.rect);item.decoration.setOpacity(0)
            tideFaces[id]?.render(rect:contour.body.rect,opacity:face)
            item.chromeHost.isHidden=ink<=0;item.grip.isHidden=ink<=0
            item.grip.opacity=Float(ink)
            var filter=tideInkFilters[id]
            DockTidePresentation.ink(item.chromeHost.layer!,opacity:ink,blur:(1-ink)*8,scale:0.97+0.03*ink,filter:&filter)
            tideInkFilters[id]=filter

            shape.apply(contour) { [unowned self] glass,rect,hidden in self.writeGlass(glass,frame:rect,alpha:1,hidden:hidden,reason:"tideMaterial") }
            let original=tideTimeline?.bubbles[id]?.original.width ?? 160
            let amount=max(0,min(1,1-(contour.body.rect.width-36)/max(1,original-36)))
            shape.style(identity:Look.identity[item.conversation.identityIndex % Look.identity.count],amount:amount)

        }
    }
#if M10_DOCK_SELFTEST
    struct PhysicalGlass {
        let id: String, group: String
        let frame: CGRect, logical: CGRect, raw: CGRect
        let alpha: CGFloat, effectiveAlpha: CGFloat
        let hidden: Bool, sampledPresentation: Bool
        let alphaChain: [[String:Any]]
    }
#endif
    /// View alpha and its backing-layer opacity are the same factor, not two multipliers.
    static func glassVisibility(_ glass:NSView)->(alpha:CGFloat,hidden:Bool,presentation:Bool,chain:[[String:Any]]) {
        var alpha:CGFloat=1,hidden=false,presentation=false,chain:[[String:Any]]=[]
        var view:NSView?=glass
        while let current=view {
            let layer=current.layer,presented=layer?.presentation()
            let opacity=CGFloat(presented?.opacity ?? layer?.opacity ?? Float(current.alphaValue))
            let layerHidden=presented?.isHidden ?? layer?.isHidden ?? false
            alpha *= max(0,min(1,opacity));hidden = hidden || current.isHidden || layerHidden
            presentation = presentation || presented != nil
            chain.append(["view":String(describing:type(of:current)),"viewAlpha":current.alphaValue,
                "modelOpacity":layer.map{Double($0.opacity)} as Any? ?? NSNull(),
                "presentationOpacity":presented.map{Double($0.opacity)} as Any? ?? NSNull(),
                "hidden":current.isHidden,"layerHidden":layerHidden,"factor":opacity])
            view=current.superview
        }
        return (alpha,hidden,presentation,chain)
    }
#if M10_DOCK_SELFTEST
    var physicalGlassSnapshot:[PhysicalGlass] {auditedGlassSnapshot.filter{!$0.hidden}}
    var auditedGlassSnapshot: [PhysicalGlass] {
        var result: [PhysicalGlass] = []
        func add(_ id: String, _ group: String, _ glass: NSGlassEffectView?, _ logical: CGRect?) {
            guard let glass,glass.superview === content,let logical,logical.width>0,logical.height>0 else {return}
            let visibility=Self.glassVisibility(glass)
            result.append(PhysicalGlass(id:id,group:group,frame:glass.frame,logical:releaseLogical(glass,fallback:logical) ?? logical,
                raw:logical,alpha:glass.alphaValue,effectiveAlpha:visibility.alpha,hidden:visibility.hidden,
                sampledPresentation:visibility.presentation,alphaChain:visibility.chain))
        }
        add("me","me",me,meMotion.rect)
        for (id,item) in items {
            add("item."+id,id,item.glass,tideNodePoses[id] ?? tideMaterialShapes[id]?.contour?.body.rect ?? item.motion.rect)
            add("identity."+id,"identity."+id,item.identity?.glassView,item.identityMotion.rect)
        }
        for (id, shape) in tideMaterialShapes {
            for (i, part) in (shape.contour?.tail ?? []).enumerated() {
                add("tide.tail.\(id).\(i)",id,shape.views[i],part.rect)
            }
        }
        if let owner=capsuleOwnerID { add("capsule",owner,focusedGlass,capsuleMotion.rect) }
        add("draft","draft",draftBar?.glass,draftMotion.rect)
        return result.sorted { $0.id < $1.id }
    }
    var reviewPhysicalReleaseCount:Int {glassReleases.values.filter{motionNow()<$0.began+$0.spring.duration}.count}
    var topologyFinalResidual: CGFloat { glassTopology.finalResidual }
    func topologyConnected(_ a: String, _ b: String) -> Bool? { glassTopology.connected(a,b) }
    func clearHoverProjectionForVerification() { orbDeltas = [] }
    var hoverProjectionForVerification: [CGRect] { orbDeltas }
    var reviewFades: [String: Float] {
        let now=motionNow()
        var values=["capsule":focusedMix.value(at:now)]
        for (id,item) in items {values[id+".identity"]=item.identityOpacity.value(at:now);values[id+".segment"]=item.segmentMix.value(at:now);values[id+".emphasis"]=item.emphasis.value(at:now);values[id+".controls"]=item.controlsOpacity.value(at:now)}
        return values
    }
    private var reviewRawGlass: [ObjectIdentifier:CGRect] = [:]
    private var reviewWrites: [ObjectIdentifier:Int] = [:]
    func reviewRawFrame(_ glass: NSGlassEffectView) -> CGRect? {reviewRawGlass[ObjectIdentifier(glass)]}
    func reviewReleaseEnd(_ glass:NSGlassEffectView)->Double? {glassReleases[ObjectIdentifier(glass)].map{$0.began+$0.spring.duration}}
    func reviewPeekAnchor(_ id:String)->CGRect? {buds[id]?.anchor}
    func reviewReleaseTarget(_ glass:NSGlassEffectView) -> CGRect? {glassReleases[ObjectIdentifier(glass)]?.spring.target}
    func reviewReleaseVelocity(_ glass:NSGlassEffectView) -> CGRect? {glassReleases[ObjectIdentifier(glass)]?.spring.sample(0).velocity}
    func reviewWriteCount(_ glass: NSGlassEffectView) -> Int {reviewWrites[ObjectIdentifier(glass)] ?? 0}
    func resetReviewWrites() {reviewWrites=[:]}
    var reviewAllSpringEnd:Double {
        func end(_ glass:NSGlassEffectView?,_ logicalEnd:Double)->Double {
            guard let glass,!glass.isHidden,glass.layer?.isHidden != true else {return 0}
            if let channel=glassReleases[ObjectIdentifier(glass)] {return channel.began+channel.spring.duration}
            return logicalEnd
        }
        var result=end(focusedGlass,capsuleBegan+capsuleSpring.duration)
        for item in items.values {
            result=max(result,end(item.glass,(sceneBegan ?? motionNow())+item.spring.duration),
                end(item.identity?.glassView,item.identityBegan+item.identitySpring.duration))
        }
        return result
    }
    var capsuleLogicalFrame: CGRect { capsuleMotion.rect ?? .zero }
    var capsuleEpochStart: Double { capsuleBegan }
    var meLogicalFrame: CGRect { meMotion.rect ?? .zero }
    var mePaintedFrame: CGRect { me?.frame ?? .zero }
#endif
    var focusedGlassFrame: CGRect { focusedGlass.frame }
    var focusedGlassOpacity: CGFloat { focusedGlass.alphaValue }
    private final class Divider {
        let layer = CAShapeLayer()
        var opacity = DockFade(0)
    }
    private var segmentDividers: [String:Divider] = [:]
    var dividerLayers: [CAShapeLayer] { segmentDividers.values.map(\.layer) }
    /// The window installs the initial value too: AutoScene only notifies subsequent changes.
    var focusTargetProvider: (() -> String?)?
    var focusTarget: String? {
        didSet { if focusTarget != oldValue { refreshTideProtection();retargetSegmentAppearance(); onNeedsFrames?(0.25) } }
    }
    /// Over the glass: the bars' grips (a grip straddles its bar's edge, so it cannot live in the clipped glass).
    private let gripPlane = DockNode.Passage()
    private var me: NSGlassEffectView?
    private var meDecoration: OrbComponent?
    private var sunHoverDiameter: CGFloat = 0, sunHoverBaseFrame: CGRect?
    private var sunHoverLabel: String?, sunHoverLabelMix = 0.0
    private var sunHoverPickupDiameter: CGFloat?
    private var sunHoverHeldShape: (shape: RectSpring, began: Double)?
    var sunHoverBadge: (() -> OrbBadge?)?
    var sunHoverBlocksPointer: ((CGPoint) -> Bool)?
    var onMeMeasurementChanged: (() -> Void)?
    private(set) var sunHoverCornerWrites = 0
    private var sunHoverTideBacklog = SunHoverTideBacklog()
    var sunHoverTideCanResume: (() -> Bool)?
    var sunHoverDeferredCount: Int { sunHoverTideBacklog.entries.count }
    var sunHoverTideEventID: Int? { tideTimeline?.event?.id }
    func sunHoverTideCursor(_ id: String) -> Int? { tideCursors[id] }
    func beginSunHoverTideDeferral() {
        guard !sunHoverTideBacklog.isDeferring else { return }
        sunHoverTideBacklog.begin(sideQueued: tideSideQueued); tideSideQueued = [:]
        _ = dismissTide()
        _ = dismissTide()
    }
    func endSunHoverTideDeferral(resume: Bool = true) {
        sunHoverTideBacklog.end()
        if resume { resumeSunHoverTide(source: "finish") }
    }
    func resumeSunHoverTide(source: StaticString = #function) {
#if M1139_CHECK
        sunHoverTideResumeSources.append(String(describing: source))
#endif
        guard !sunHoverTideBacklog.isDeferring, !sunHoverTideBacklog.isEmpty, sunHoverTideCanResume?() != false, !tideFrozen else { return }
        for entry in sunHoverTideBacklog.drain() {
            guard let item = items[entry.owner], !item.conversation.archived else { continue }
            let snapshot = item.conversation.notices.snapshot(in: item.conversation)
            let notice = snapshot.journal.first { $0.id == entry.notice.id } ?? entry.notice
            deliverTide(item.conversation, snapshot: snapshot, incoming: [notice], enabled: true)
        }
    }
#if M1139_CHECK
    private(set) var sunHoverTideReceipts: [String] = [], sunHoverTideResumeSources: [String] = []
    var sunHoverTideIsDeferring: Bool { sunHoverTideBacklog.isDeferring }
    var sunHoverSideQueuedIDs: [String: [Int]] { tideSideQueued.mapValues { $0.map(\.id) } }
    func sunHoverTideResetReceipts() { sunHoverTideReceipts = []; sunHoverTideResumeSources = [] }
    func sunHoverTideForgetCursor(_ id: String) { tideCursors[id] = nil }
    private func traceSunHoverTide(_ notices: [ConversationNotice], owner: String) { sunHoverTideReceipts += notices.map { "\(owner):\($0.id)" } }
#endif
    func takeSunHoverDiameterForDrag() {
        sunHoverPickupDiameter = sunHoverBaseFrame?.width ?? base.me.width
        sunHoverDiameter = 0
    }
    /// The Sun surfaces share LL's native fusion container. This is semantic mounting, never a frame writer.
    func mountSunHoverGlass(_ surfaces: [NSGlassEffectView]) {
        for surface in surfaces { content.addSubview(surface, positioned: .above, relativeTo: me) }
    }
    /// Keep the usage ring behind LL's front glyphs and badge, in the same world coordinates.
    func mountSunHoverRing(_ layers: [CALayer]) {
        guard let parent = meDecoration?.frontView.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        for ring in layers.reversed() where ring.superlayer !== parent { parent.insertSublayer(ring, at: 0) }
    }
#if M1139_CHECK
    func sunHoverRingsBelowMe(_ layers: [CALayer]) -> Bool {
        guard let parent = meDecoration?.frontView.layer, let all = parent.sublayers, all.count > layers.count else { return false }
        return layers.allSatisfy { $0.superlayer === parent } && Array(all.prefix(layers.count)).elementsEqual(layers, by: { $0 === $1 })
    }
#endif
    struct MeMeasurement { let frame: CGRect; var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }; var diameter: CGFloat { frame.width } }
    var meMeasurement: MeMeasurement? { me.flatMap { $0.isHidden ? nil : MeMeasurement(frame: glassFrame($0)) } }
    var sunHoverBadgeRect: CGRect? { meDecoration?.meBadgeRect }
    var sunHoverBadgeIsAboveBody: Bool { meDecoration?.meBadgeIsAboveBody == true }
    var sunHoverMeUsage: Double? { meDecoration?.meSemanticUsage }
    var sunHoverMeCorner: CGFloat { me?.cornerRadius ?? 0 }
    func setSunHover(diameterDelta: CGFloat, label: String?, mix: Double, at time: Double) {
        let changedLabel = sunHoverLabel != label
        let changedDiameter = sunHoverDiameter != diameterDelta
        sunHoverDiameter = diameterDelta; sunHoverLabel = label; sunHoverLabelMix = mix
        if changedLabel { refreshOrbs() }
        meDecoration?.setMeLabelMix(mix)
        if changedDiameter, me != nil, meHeld == nil { placeMe(sunHoverBaseFrame ?? meSpring.target.adding(meDelta), at: time) }
    }
    /// me's own spring (it moves for Focused), and what hover adds to it.
    private var meSpring = RectSpring.rest(.zero), meBegan = 0.0, meDelta = CGRect.zero
    /// When me's spring comes to rest (media time), so the clock runs until then.
    var meSettles: Double { meBegan + meSpring.duration }
    /// The capsule (Focused / Split): its segments together.
    var capsule: CGRect? { base.focused ? base.bars.reduce(base.bars.first ?? .zero) { $0.union($1) } : nil }
    private var store: ConversationStore?
    /// M10-E: inject only for deterministic offscreen checks; live placement uses this window's screen.
    var motionProfile: DisplayProfile? {
        didSet { if motionProfile?.name != oldValue?.name || motionProfile?.mmPerPoint != oldValue?.mmPerPoint { resetMotion() } }
    }
    var motionEnabled = true
    var motionTime: (() -> Double)?
    var onMotionFrame: ((M10DockFrame) -> Void)?
    /// Default Dock adapter; callers may wrap this observer without requiring scene-level wiring.
    var onComposerMotion: ((NativeComposer, M10DockFrame, DisplayProfile) -> Void)?
    private(set) var composerMotion: M10DockComposer!
    private let meMotion = M10DockHistory(), draftMotion = M10DockHistory()
    private var cachedScreen: ObjectIdentifier?, cachedMotionProfile: DisplayProfile?
    private var exposureProfile: DisplayProfile {
        if let motionProfile { return motionProfile }
        if let screen = view.window?.screen ?? NSScreen.main {
            let id = ObjectIdentifier(screen)
            if cachedScreen != id { cachedScreen = id; cachedMotionProfile = .of(screen) }
        }
        return cachedMotionProfile ?? M10DockMotion.dell
    }
    private func motionNow() -> Double {
        let now=commitClock ?? motionTime?() ?? displayTime ?? max(CACurrentMediaTime(),latestDisplayTime)
        synchronizeInjectedClock(at:now)
        return now
    }
    /// Virtual clock changes migrate the entire Dock epoch. Display prediction revisions do not.
    private func synchronizeInjectedClock(at _: Double) {
        guard let now=motionTime?(),commitClock == nil,now.isFinite else { return }
        let previous=lastInjectedClock
        lastInjectedClock=now
        guard let previous, now < previous else { return }
        let delta=now-previous
        for channel in glassReleases.values {channel.began += delta;channel.history.shiftClock(by:delta)}
        for channel in contourHandoffs.values {channel.began += delta}
        for key in glassObservations.keys {
            glassObservations[key]?.time += delta
            if glassObservations[key]?.previousTime != nil {glassObservations[key]?.previousTime! += delta}
        }
        if sceneBegan != nil {sceneBegan! += delta}
        capsuleBegan += delta; meBegan += delta; hoverBegan += delta; liftBegan += delta
        focusedMix.began += delta; glassTransitionUntil += delta; latestDisplayTime += delta
        if capsuleSampleTime != nil {capsuleSampleTime! += delta}
        if meSampleTime != nil {meSampleTime! += delta}
        if glassRetargetTime != nil {glassRetargetTime! += delta}
        if refusalStart != nil {refusalStart! += delta}
        if barBloom != nil {barBloom!.began += delta}
        if held != nil {held!.began += delta}
        for id in buds.keys {buds[id]?.began += delta;if buds[id]?.anchorUntil != nil {buds[id]!.anchorUntil! += delta}}
        for id in blooms.keys {blooms[id]?.release += delta}
        for id in returns.keys {returns[id]?.began += delta}
        for id in dockLandings.keys {dockLandings[id]?.until += delta}
        for divider in segmentDividers.values {divider.opacity.began += delta}
        for history in [meMotion,draftMotion,capsuleMotion] {history.shiftClock(by:delta)}
        glassTopology.shiftClock(by:delta)
        for item in items.values {
            item.identityBegan += delta; item.identityOpacity.began += delta
            item.segmentMix.began += delta; item.emphasis.began += delta; item.controlsOpacity.began += delta
            item.face.start += delta; item.veil.start += delta; item.semanticZoomUntil += delta
            if item.chromeExit != nil {item.chromeExit!.began += delta}
            for history in [item.motion,item.orbMotion,item.identityMotion,item.wordMotion,item.peekWordMotion] {history.shiftClock(by:delta)}
            for view in [item.glass,item.barFace,item.label,item.ownComposer].compactMap({$0}) {
                guard let layer=view.layer, let fade=layer.animation(forKey:Self.fadeKey)?.copy() as? CAAnimation else {continue}
                fade.beginTime += delta;layer.add(fade,forKey:Self.fadeKey)
            }
        }
    }
    private var usesExposure: Bool { motionEnabled && M10DockMotion.enabled && !Motion.reduce }
    var contentZoomStyle=M10DockZoom.selected
    private var usesGaussian:Bool {usesExposure && contentZoomStyle == .gauss}
    func resetMotion() {
        composerMotion?.reset(); composerMotion?.prune()
        meDecoration?.resetHostExposure()
        for item in items.values {item.decoration.resetHostExposure();item.identity?.resetHostExposure()}
        meMotion.reset(); draftMotion.reset(); capsuleMotion.reset()
        for item in items.values { item.wordGaussian.reset(); item.peekGaussian.reset(); item.label.layer?.opacity=Float(item.label.alphaValue); item.peekFace.layer?.opacity=Float(item.peekFace.alphaValue); item.decoration.resetGlyphGaussian(); item.motion.reset(); item.orbMotion.reset(); item.wordMotion.reset(); item.wordTrail.reset(); item.peekWordMotion.reset(); item.peekTrail.reset(); item.identityMotion.reset(); item.peekFace.glyphExposureActive = false; item.peekFace.motionBadgeRect = nil }
    }
    private func placeMe(_ r: CGRect, at now: Double) {
        guard let me else { return }
        sunHoverBaseFrame = r
        let r = r.insetBy(dx: -sunHoverDiameter / 2, dy: -sunHoverDiameter / 2)
        meSampleTime = now
        let f = meMotion.update(r, at: now, name: "dock.me", profile: exposureProfile, enabled: usesExposure)
        writeGlass(me, frame:f.painted)
        if sunHoverDiameter != 0 { me.cornerRadius = f.painted.height / 2; sunHoverCornerWrites += 1 }
        meDecoration?.setFrame(f.painted)
        if let d = meDecoration { M10DockMotion.onOrbFrame?(d, f, exposureProfile) }
        if frameLog != nil { rawExposed[f.name] = f }
        onMotionFrame?(f)
        onMeMeasurementChanged?()
    }

    /// Window environment for the decorations: ambient motion (off in tests), Reduce Motion, key window.
    var ambient = true
    /// Fully Focused (f044): in Focused or Split the dock is still — no orbiting, bobbing or hops, no rise or magnification.
    var still = false { didSet { if still != oldValue { refreshOrbs() } } }
    private(set) var items: [String: Item] = [:]
    /// The resting layout and metrics; hover magnifies and raises from these (reference §E).
    private var base = AutoLayout(), metrics = AutoLayout.Metrics()
    private var pointerX: CGFloat?
    /// Hover, 0 (away) → 1 (over the dock): drives the 12 pt rise and the orbs' magnification together.
    private var hover = Spring.rest(0), hoverBegan = 0.0
    private(set) var sunHoverDockHeld = false
    private var paintedHoverPose: (amount: Double, lift: Double, pointerX: CGFloat?)?
    private(set) var hovering = false
    /// The rise alone: up while the pointer is over the dock or one of its editors has the keyboard, so typing with the
    /// pointer elsewhere keeps it up while magnification goes (NativeDockScene's separate lift; organic audit B11).
    private var lift = Spring.rest(0), liftBegan = 0.0
    var editing = false {
        didSet { guard editing != oldValue else { return }; refreshTideProtection();if sunHoverDockHeld { return };retargetLift(hovered: hover.to > 0.5, now: motionNow()); onNeedsFrames?(0.6) }
    }
    private func retargetLift(hovered: Bool, now: Double) {
        let target: Double = hovered || editing ? 1 : 0
        guard target != lift.to else { return }
        let c = lift.sample(now - liftBegan)
        lift = Spring(from: c.value, to: target, velocity: c.velocity, response: target > 0.5 ? 0.26 : 0.30, damping: target > 0.5 ? 0.86 : 0.90,
                      epsilon: Spring.restEpsilon / 48)
        liftBegan = now
    }
    private var pendingLeave: DispatchWorkItem?
    /// Freeze the existing channels at their last painted pose before LL's input reaches pointer().
    func beginSunHoverDockHold(at now: Double) {
        guard !sunHoverDockHeld else { return }
        let amount = paintedHoverPose?.amount ?? 0
        let up = paintedHoverPose?.lift ?? 0
        if let pose = paintedHoverPose { pointerX = pose.pointerX }
        sunHoverDockHeld = true
        pendingLeave?.cancel(); pendingLeave = nil
        hover = .rest(amount); hoverBegan = now
        lift = .rest(up); liftBegan = now
    }
    /// Re-admit the latest pointer, including an exit that occurred while the pose was held.
    func endSunHoverDockHold(at now: Double, pointer point: CGPoint?) -> Double {
        guard sunHoverDockHeld else { return 0 }
        sunHoverDockHeld = false
        let duration = pointer(point, now: now)
        if pendingLeave == nil { retargetHover(to: hovering ? 1 : 0, now: now) }
        return max(duration, hover.duration, lift.duration)
    }
#if M1139_CHECK
    var sunHoverLogicalMeFrame: CGRect { meMotion.rect ?? .zero }
    var sunHoverDockPose: (amount: Double, lift: Double, pointerX: CGFloat?) {
        let t = motionNow()
        return (hover.sample(t - hoverBegan).value, lift.sample(t - liftBegan).value, pointerX)
    }
#endif
    /// What hover adds to each resting orb slot's frame, and how far the dock has risen.
    private var orbDeltas: [CGRect] = []
    private(set) var rise: CGFloat = 0
    /// The hidden Dock may stop drawing while its editing spring keeps its absolute epoch.
    /// Flight owners must sample that epoch, not the last painted (possibly stale) rise.
    var modePresentationRise:CGFloat {
        still ? 0:metrics.hoverRise*CGFloat(min(1,max(0,lift.sample(motionNow()-liftBegan).value)))
    }
    private static let preservesModeLift=ProcessInfo.processInfo.environment["M11_MODE_ORRERY_FLIGHT"] != "0"
    private var liftTrace:ModeSignposts.Trace?
    private var lastLiftTrace:(rise:CGFloat,editing:Bool,ll:CGFloat,bar:CGFloat)?
    private func recordLift(at time:Double,writer:String) {
        guard ModeSignposts.enabled else {liftTrace=nil;lastLiftTrace=nil;return}
        let ll=me.map {base.me.midY-$0.frame.midY} ?? 0
        let bar=items.values.first(where:{$0.role == .bar}).map {$0.target.minY-$0.glass.frame.minY} ?? 0
        if let last=lastLiftTrace,last.editing == editing,abs(last.rise-rise)<0.01,abs(last.ll-ll)<0.01,abs(last.bar-bar)<0.01 {return}
        if liftTrace == nil {liftTrace=ModeSignposts.Trace()}
        liftTrace?.record("ModeDockLift",detail:"rise=\(rise) editing=\(editing) llRise=\(ll) barRise=\(bar) writer=\(writer)",at:time)
        lastLiftTrace=(rise,editing,ll,bar)
    }
    /// The composer for a conversation, made on first use (the scene owns the sessions and callbacks).
    var composerFor: ((Conversation) -> NativeComposer)?

    init(view: NSView, scale: CGFloat) {
        self.view = view
        (view as? Passage)?.dockOwner=self
        layer.anchorPoint = .zero
        container.spacing = 10
        container.contentView = content
        view.addSubview(container)
        focusedGlass.alphaValue = 0
        focusedGlass.isHidden = true
        content.addSubview(focusedGlass)
        chromePlane.wantsLayer = true
        view.addSubview(chromePlane, positioned: .above, relativeTo: container)
        gripPlane.wantsLayer = true
        view.addSubview(gripPlane, positioned: .above, relativeTo: container)
        composerMotion = M10DockComposer(in: view)
        onComposerMotion = { [weak self] source, frame, profile in
            guard let self else { return }
            self.composerMotion.update(source, frame: frame, profile: profile, enabled: self.usesExposure)
        }
    }

    /// Every working-set conversation's node at rest for `layout`, with `order` its display order (bars first).
    func install(_ layout: AutoLayout, metrics m: AutoLayout.Metrics, order: [Conversation], full: Set<String>, store: ConversationStore) {
        retireTide()
        tidePool.values.forEach{$0.dispose()};tidePool=[:]
        tideSides.values.forEach{$0.dispose()};tideSides=[:];tideGlassCorners=[:];tideSideLive=false
        tideFaces.values.forEach{$0.dispose()};tideFaces=[:]
        buds.removeAll(keepingCapacity:true);peekShown=nil
        glassTopology.reset(); glassTransitionUntil = 0
        contourHandoffs.removeAll(keepingCapacity:true);tearingGlassID=nil
        glassRetargetTime = nil; glassRetargetPaint = [:]
        sampledElapsed = 0; meSampleTime = nil; sceneBegan = nil; transitionEpoch = nil; lastInjectedClock = nil
        releasedGlassID=nil;glassObservations.removeAll(keepingCapacity:true);glassReleases.removeAll(keepingCapacity:true)
        topologyPeekExclusions = []
        withdrawFocusedGlass()
        resetMotion()
        base = layout; metrics = m; self.store = store
        container.frame = view.bounds
        content.frame = container.bounds
        gripPlane.frame = view.bounds; chromePlane.frame = view.bounds
        me?.removeFromSuperview(); meDecoration?.dispose()
        dressGlass(focusedGlass)
        focusedMix = DockFade(layout.focused ? 1 : 0)
        capsuleSpring = .rest(layout.bars.reduce(layout.bars.first ?? .zero){$0.union($1)})
        capsuleBegan = motionNow()
        let me = NSGlassEffectView(frame: layout.me)
        me.cornerRadius = layout.me.height / 2
        content.addSubview(me); self.me = me
        dressGlass(me)
        meSpring = .rest(layout.me)
        sunHoverBaseFrame = layout.me
        let meDecoration = OrbComponent(id: "organic.me", glassView: me)
        mount(meDecoration); self.meDecoration = meDecoration
        for item in items.values { item.glass.removeFromSuperview(); item.chromeHost.removeFromSuperview(); item.decoration.dispose(); item.identity?.glassView.removeFromSuperview(); item.identity?.dispose() }
        items = [:]
        for c in order {
            let item = Item(c)
            content.addSubview(item.glass)
            chromePlane.addSubview(item.chromeHost)
            mount(item.decoration)
            gripPlane.layer?.addSublayer(item.grip)
            items[c.id] = item
            dressGlass(item.glass)
        }
        segmentIDs = Array(order.prefix(layout.bars.count).map(\.id))
        let targets = self.targets(layout, order: order.map(\.id))
        for (id, item) in items {
            guard let t = targets[id] else { continue }
            item.spring = .rest(t.rect); item.role = t.role; item.slot = t.slot
            place(item, t.rect)
        }
        settleContent(full: full)
        refreshOrbs()
        configureTide()
    }

    /// The window changed size: the same nodes, at rest in the new layout.
    func relayout(_ layout: AutoLayout, metrics m: AutoLayout.Metrics, order: [Conversation], full: Set<String>) {
        retireTide()
        endAnchoredPeeks(at:motionNow(),force:true)
        if Self.preservesModeLift {CATransaction.begin();CATransaction.setDisableActions(true)}
        let ownsBatch=Self.preservesModeLift ? beginGlassBatch():false
        defer {
            endGlassBatch(ownsBatch)
            recordLift(at:motionNow(),writer:"relayout")
            if Self.preservesModeLift {CATransaction.commit()}
        }
        glassTopology.reset(); glassTransitionUntil = 0
        contourHandoffs.removeAll(keepingCapacity:true);tearingGlassID=nil
        glassRetargetTime = nil; glassRetargetPaint = [:]
        sampledElapsed = 0; meSampleTime = nil; sceneBegan = nil; transitionEpoch = nil; lastInjectedClock = nil
        releasedGlassID=nil;glassObservations.removeAll(keepingCapacity:true);glassReleases.removeAll(keepingCapacity:true)
        topologyPeekExclusions = []
        withdrawFocusedGlass()
        resetMotion()
        base = layout; metrics = m
        capsuleSpring = .rest(layout.bars.reduce(layout.bars.first ?? .zero){$0.union($1)})
        capsuleBegan = motionNow()
        for v in [container, content, gripPlane, chromePlane] as [NSView] { v.frame = view.bounds }
        content.frame = container.bounds
        me?.cornerRadius = layout.me.height / 2
        if !Self.preservesModeLift,let me {me.frame=layout.me;meDecoration?.setFrame(layout.me)}
        meSpring = .rest(layout.me)
        meDecoration?.setCanvasSize(view.bounds.size)
        segmentIDs = Array(order.prefix(layout.bars.count).map(\.id))
        let targets = self.targets(layout, order: order.map(\.id))
        for (id, item) in items {
            item.decoration.setCanvasSize(view.bounds.size); item.identity?.setCanvasSize(view.bounds.size)
            guard let t = targets[id] else { continue }
            item.spring = .rest(t.rect); item.role = t.role; item.slot = t.slot; item.target = t.rect
            if !Self.preservesModeLift {place(item,t.rect)}
        }
        // Relayout changes resting slots, not the ongoing editing/hover lift.
        // Publish every world pose in this batch; never expose an unraised pose between display callbacks.
        if Self.preservesModeLift {hoverFrame(at:motionNow());sample(.infinity)} else {orbDeltas=[]}
        settleContent(full: full)
        refreshOrbs()
        configureTide()
    }

    /// A decoration's back plane goes under the dock's one glass container and its front plane over it (ORB-PORT).
    private func mount(_ d: OrbComponent) {
        d.setCanvasSize(view.bounds.size)
        view.addSubview(d.backView, positioned: .below, relativeTo: container)
        view.addSubview(d.frontView, positioned: .above, relativeTo: container)
    }

    /// Ambient motion held or let go (f202): each orb's liquid, satellites and hops keep their phase while held.
    private(set) var ambientRunning = true
    func setAmbientRunning(_ on: Bool) {
        if ambientRunning != on { resetMotion() }
        ambientRunning = on
        for item in items.values { item.decoration.setPresentationActive(on && item.role == .orb && tideAllowsAmbient(item.conversation.id)); item.identity?.setPresentationActive(on && item.identityOpacity.to > 0 && tideAllowsAmbient(item.conversation.id)) }
        meDecoration?.setPresentationActive(on)
    }

    /// Every decoration's configuration, from its conversation (deduplicated by value inside the component).
    func refreshOrbs() {
        let reduce = Motion.reduce
        let key = view.window?.isKeyWindow ?? true, scale = view.window?.backingScaleFactor ?? 2
        let size = max(metrics.orb, metrics.orbMagnified, 1)
        for item in items.values {
            var c = makeOrbConfiguration(item.conversation, drawingSize: size, backingScale: scale,
                                         reduceMotion: reduce, ambient: ambient && !still, isKeyWindow: key)
            c.bodyOuter=metrics.orb
            // Open in a peek: no badge (the capsule shows it), satellites in the row under the capsule.
            if let bud = buds[item.conversation.id], bud.open {
                c.badge = nil
                if let follow = bud.follow { c.satelliteMode = .follow(follow) }
            }
            item.decoration.configure(c)
            tideFaces[item.conversation.id]?.configure(c)
            if let identity = item.identity {
                var identityConfig = c
                identityConfig.drawingSize = size
                identity.configure(identityConfig)
            }
        }
        if let store, let meDecoration {
            var configuration = makeMeConfiguration(store: store, initials: NormieAccount.prototype.initials, drawingSize: max(metrics.me, 1), backingScale: scale,
                                                       reduceMotion: reduce, ambient: ambient && !still, isKeyWindow: key, badgeProjection: sunHoverBadge)
            configuration.meBadgeAtCorner = sunHoverBadge != nil
            configuration.meLabel = sunHoverLabel
            meDecoration.configure(configuration)
            meDecoration.setMeLabelMix(sunHoverLabelMix)
        }
    }

    /// Nodes for members that have none yet (an arrival): each starts as a point at the centre of where it will rest and
    /// grows there on its spring. Nodes whose conversation left keep theirs until the transition settles.
    func ensureItems(for members: [Conversation], layout: AutoLayout, order: [String]) {
        let targets = self.targets(layout, order: order)
        for c in members where items[c.id] == nil {
            guard let t = targets[c.id] else { continue }
            let item = Item(c)
            content.addSubview(item.glass)
            chromePlane.addSubview(item.chromeHost)
            mount(item.decoration)
            gripPlane.layer?.addSublayer(item.grip)
            item.role = t.role; item.slot = t.slot
            item.spring = .rest(CGRect(x: t.rect.midX, y: t.rect.midY, width: 0, height: 0))
            place(item, item.spring.target)
            item.barFace.alphaValue = t.role == .bar ? 1 : 0
            item.decoration.setOpacity(t.role == .orb ? 1 : 0)
            // Face defaults to an orb's. A bar born mid-transition (back from a tear, whose gap dropped its item; a merge)
            // showed its orb over the bar's left end until settle, then cut away (board 10-31).
            if t.role == .bar { item.face = (0, 0, 0, 0) }
            items[c.id] = item
            dressGlass(item.glass)
        }
        refreshOrbs()
    }

    /// Nodes whose conversation is no longer in the working set: gone once the transition settles.
    func dropItems(keeping ids: Set<String>) {
        for (id, item) in items where !ids.contains(id) {
            buds[id]=nil;if peekShown == id {peekShown=nil}
            item.glass.removeFromSuperview(); item.chromeHost.removeFromSuperview(); item.decoration.dispose(); item.identity?.glassView.removeFromSuperview(); item.identity?.dispose(); item.grip.removeFromSuperlayer()
            items[id] = nil
        }
        if let owner = capsuleOwnerID, items[owner] == nil { withdrawFocusedGlass() }
    }

    /// Where every node rests in `layout`: the first `bars.count` of `order` as bars, the rest as orbs.
    private func targets(_ layout: AutoLayout, order: [String]) -> [String: (role: Role, rect: CGRect, slot: Int)] {
        var out: [String: (Role, CGRect, Int)] = [:]
        for (i, id) in order.enumerated() {
            if i < layout.bars.count { out[id] = (.bar, layout.bars[i], i) }
            else if i - layout.bars.count < layout.orbs.count { out[id] = (.orb, layout.orbs[i - layout.bars.count], i - layout.bars.count) }
        }
        return out
    }

    /// A brief bar's words follow its conversation's draft; called whenever a conversation changes.
    func refreshWords() {
        for item in items.values {
            let draft = item.conversation.draft.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            item.label.stringValue = draft ?? "Reply…"
            // Product: an unsent draft at 0.72 of the primary colour, "Reply…" at 0.38 (DockItems.swift:378-386).
            item.label.textColor = NSColor(white: 1, alpha: draft == nil ? 0.38 : 0.72)
            prepareWords(item)
        }
    }

    /// Springs from where every node is `t` seconds into the current transition to its place in `layout`.
    func springs(to layout: AutoLayout, order: [String], at t: Double,
                 spring: (response: Double, damping: Double) = Tuning.shared.autoSpring) -> [String: RectSpring] {
        endAnchoredPeeks(at:motionNow())
        let targets = self.targets(layout, order: order)
        let sourceTime = layout.focused != base.focused ? (sampledElapsed ?? t) : t
        var out: [String: RectSpring] = [:]
        for (id, item) in items {
            // A held node starts from where the pointer has it, still; a dropped one springs from there to its slot.
            var now = carries(id) ? (rect: item.motion.rect ?? item.glass.frame, velocity: CGRect.zero) : item.spring.sample(sourceTime)
            if let source=tideLayoutSources[id] {now=(localFrame(source.rect,role:item.role,slot:item.slot,at:motionNow()),source.velocity)}
            if let releasedIdentity, releasedIdentity.id == id, targets[id]?.role == .orb {
                now = (localFrame(releasedIdentity.planet,role:item.role,slot:item.slot,at:motionNow()),.zero)
            }
            // Released just before this commit, so it is no longer "held": its spring is from before the press, and it
            // jumped there and slid back (Dock reorder, board 10-31).
            if let releasedNode, releasedNode.id == id { now = (localFrame(releasedNode.rect,role:item.role,slot:item.slot,at:motionNow()), .zero) }
            if returns[id] != nil,let target=targets[id],target.role == .bar {now=(target.rect,.zero)}
            // Budded out into a peek: from the capsule, where it is (the transition takes the bud over).
            if let bud = buds[id], !carries(id) {
                let d = bud.delta.sample(motionNow() - bud.began)
                if bud.physicalTakeover {
                    let world=(bud.anchor ?? item.regular).addingSignedComponents(d.rect)
                    let velocity=bud.anchor == nil ? regularVelocity(item).addingSignedComponents(d.velocity):d.velocity
                    now=(localFrame(item.motion.rect ?? world,role:item.role,slot:item.slot,at:motionNow()),velocity)
                } else {now=(now.rect.adding(d.rect),now.velocity.addingSignedComponents(d.velocity))}
            }
            // Gone from the working set: to a point where it is, and removed when the transition settles.
            let gone = CGRect(x: now.rect.midX, y: now.rect.midY, width: 0, height: 0)
            out[id] = RectSpring(dockFrom: now.rect, to: targets[id]?.rect ?? gone, velocity: now.velocity,
                                 response: spring.response, damping: spring.damping)
        }
        return out
    }

    /// At a commit: the new springs and resting layout, and every node's content for where it is going. A bar turning
    /// full or brief swaps the composer and its words; a node turning bar or orb swaps its faces. All with render-server
    /// fades; new content is laid out once for the target (f056: controls never re-lay out while the glass springs), and
    /// an outgoing editor stays in the window until it is out of sight, so a composition is never cut.
    func transition(to layout: AutoLayout, order: [String], full fullIDs: Set<String>, springs: [String: RectSpring], duration: Double) {
        synchronizeInjectedClock(at:motionNow())
        let tideSources=tideLayoutSources
        let addReservation=tideAddReservation
        let addPoses=tideContourInputs
        tideAddTails.removeAll();tideAddLayout=nil
        let tideBatch=tideSources.isEmpty ? false:beginGlassBatch()
        defer {
            if !tideSources.isEmpty {
                for (id,source) in tideSources {
                    if let item=items[id] {item.motion.reset(source.rect);writeGlass(item.glass,frame:source.rect,alpha:1,hidden:false,reason:"tideLayoutHandoff");item.shape(source.rect)}
                }
                endGlassBatch(tideBatch)
            }
        }
        if frameLog != nil { epochSourceBatchID = batchID }
        let meChanges = layout.me != base.me
        let epoch = Self.sharedEpochEnabled ? (transitionEpoch ?? makeTransitionEpoch(at:motionNow())) : nil
        transitionEpoch = nil
        if !tideSources.isEmpty,!trashReflowPending {retireTide()}
        commitClock = epoch?.began
        transitionIdentitySources = epoch?.identities
        defer { commitClock = nil; transitionIdentitySources = nil }
        let capsuleNow = epoch?.began ?? motionNow()
        for handoff in contourHandoffs.values {
            if let glass=handoff.view {handoff.source=glass.frame;handoff.raw=nil;handoff.delta=nil;handoff.began=capsuleNow}
        }
        let physicalRelease=epoch?.physicalReleaseID != nil
        defer { releasedGlassID=nil }
        var committedSprings = springs
        if let epoch {
            for (id, spring) in springs where !carries(id) && buds[id] == nil && releasedNode?.id != id && releasedIdentity?.id != id && returns[id] == nil {
                if let source=epoch.items[id] {
                    committedSprings[id]=RectSpring(dockFrom:source.rect,to:spring.target,velocity:source.velocity,
                        response:spring.x.response,damping:spring.x.damping)
                }
            }
        }
        if let lease=addReservation {
            let next=targets(layout,order:order)
            if lease.briefs.allSatisfy({next[$0]?.role == .orb}),tideLeaseMemory.commitAdd(lease.token) {
                tideTimeline?.leases=tideLeaseMemory
                let addBegan=motionTime?() ?? CACurrentMediaTime()
                let addDuration=(committedSprings.values.map(\.duration).max() ?? 0)+0.07
                if !lease.briefs.isEmpty || !addPoses.isEmpty {tideAddLayout=(addBegan,addDuration)}
                for id in Set(lease.briefs).union(addPoses.keys) {
                    guard let target=next[id],let source=tideSources[id] ?? items[id].map({($0.glass.frame,CGRect.zero)}) else{continue}
                    let spring=committedSprings[id] ?? RectSpring(dockFrom:source.0,to:target.rect,velocity:.zero,response:Tuning.shared.autoSpring.response,damping:Tuning.shared.autoSpring.damping)
                    committedSprings[id]=spring
                    tideAddTails[id]=TideAddHandoff(began:addBegan,duration:addDuration,
                        initialTail:addPoses[id]?.tailAmount ?? 0,lean:addPoses[id]?.lean ?? 26,reduced:Motion.reduce)
                }
            } else {_=tideLeaseMemory.release(lease.token)}
            tideAddReservation=nil
        }
        sceneBegan = epoch?.began
        // Preparation does not create a new motion observation or consume the incoming exposure.
        if epoch != nil {
            capsuleMotion.adoptEpoch(at:capsuleNow); meMotion.adoptEpoch(at:capsuleNow)
            for item in items.values { item.motion.adoptEpoch(at:capsuleNow); item.identityMotion.adoptEpoch(at:capsuleNow) }
        }
        frameLog?.transition(at: capsuleNow, from: base.focused, to: layout.focused, previousUntil: glassTransitionUntil)
        glassRetargetTime = capsuleNow
        glassRetargetPaint = DockGlassTopology.safeMarginEnabled ? [:] : Dictionary(uniqueKeysWithValues: content.subviews.compactMap { view in
            guard let glass = view as? NSGlassEffectView, !glass.isHidden else { return nil }
            return (ObjectIdentifier(glass), glass.frame)
        })
        let capsuleWasActive = capsuleOwnerID != nil
        let splitHandoff=layout.focused && layout.bars.count>1 &&
            (!base.focused || segmentIDs != Array(order.prefix(layout.bars.count)))
        var splitContours=splitHandoff ? captureContours():[]
        if splitHandoff,!capsuleWasActive,let owner=order.first.flatMap({items[$0]}) {
            // An alpha-zero incoming capsule still contributes shape: graft it inside its presented owner.
            splitContours.append((focusedGlass,owner.glass.frame,nil))
        }
        glassTopology.begin(at: motionNow())
        // Preparation can block the main thread. Continue the last displayed sample, not unseen wall-clock motion.
        var oldCapsule = epoch?.capsule ?? capsuleSpring.sample((capsuleSampleTime ?? capsuleNow) - capsuleBegan)
        let nextTargets = targets(layout, order: order)
        for (id,target) in nextTargets {
            if !physicalRelease, let item=items[id],item.role == .bar,target.role == .orb,item.identity != nil,
               item.identityOpacity.value(at:capsuleNow) >= 0.999 {
                glassTopology.adoptIdentity("identity."+id,as:id)
            }
        }
        if layout.focused {
            let owner = order.prefix(layout.bars.count).first
            if !capsuleWasActive, let owner {
                // Start inside the retained member, never across Auto's open gaps. Hidden history
                // belongs to the old Auto union and must not stretch this first visible frame.
                if let source = committedSprings[owner] {
                    oldCapsule = source.sample(0)
                    if let item = items[owner], item.role == .orb, orbDeltas.indices.contains(item.slot) {
                        // Convert the displayed orb pose into the capsule's bar-local rise coordinates.
                        oldCapsule.rect = oldCapsule.rect.adding(orbDeltas[item.slot]).offsetBy(dx: 0, dy: rise)
                    }
                }
                else if let item = items[owner] {
                    oldCapsule = ((item.motion.rect ?? item.glass.frame).offsetBy(dx: -refusal(at: capsuleNow), dy: rise), .zero)
                } else { oldCapsule = (.zero, .zero) }
                capsuleMotion.reset(oldCapsule.rect.offsetBy(dx: refusal(at: capsuleNow), dy: -rise))
            }
            capsuleOwnerID = owner
            capsuleSharesOwnerPose = layout.bars.count == 1 && (!base.focused || base.bars.count == 1)
        }
        let union = layout.bars.reduce(layout.bars.first ?? .zero) { $0.union($1) }
        let nextCapsule: CGRect
        if !layout.focused, capsuleWasActive {
            if let target = capsuleOwnerID.flatMap({ nextTargets[$0]?.rect }) { nextCapsule = target }
            else {
                // The product removes a missing member; it never sends an orphan capsule to the origin.
                withdrawFocusedGlass()
                nextCapsule = union
            }
        } else { nextCapsule = union }
        // me springs to its place too: into the capsule's left end for Focused and back (Tuning focus 0.40 / 0.82).
        if !layout.focused { meDivider = nil }
        if let me, layout.me != base.me {
            let now = motionNow()
            let logical = epoch?.me.rect ?? meMotion.rect ?? me.frame
            let velocity = epoch?.me.velocity ?? meSpring.sample((meSampleTime ?? now) - meBegan).velocity
            let from = logical
            base = layout
            meSpring = RectSpring(dockFrom: from.offsetBy(dx: -meDelta.minX, dy: -meDelta.minY), to: meHome, velocity: velocity, response: 0.40, damping: 0.82)
            meBegan = now
        }
        base = layout
        if let epoch {
            // Rebase the last written world poses into the new role's hover coordinates.
            // New slot deltas must never be added to an old slot's local source rectangle.
            hoverFrame(at:capsuleNow,placeMe:false)
            func local(_ world: CGRect, role: Role, slot: Int) -> CGRect {
                localFrame(world,role:role,slot:slot,at:capsuleNow)
            }
            for (id,target) in nextTargets {
                guard let source=epoch.items[id],let sampledWorld=epoch.worldItems[id],let spring=committedSprings[id],
                      !carries(id),(buds[id] == nil || buds[id]?.physicalTakeover == true),
                      (releasedIdentity?.id != id || target.role == .orb),returns[id] == nil else {continue}
                // Explicit releases keep their saved world pose and prepared starting velocity.
                let world: CGRect
                if let releasedNode,releasedNode.id == id {world=releasedNode.rect}
                else if let releasedIdentity,releasedIdentity.id == id {
                    world=releasedIdentity.planet
                } else {world=sampledWorld}
                let bob = buds[id] == nil ? heldBob(role:target.role,slot:target.slot,at:capsuleNow):(position:CGFloat(0),velocity:CGFloat(0))
                var velocity=(releasedNode?.id == id || releasedIdentity?.id == id || buds[id]?.physicalTakeover == true) ? spring.sample(0).velocity:source.velocity
                if let item=items[id],buds[id] == nil {
                    velocity.origin.y += heldBob(role:item.role,slot:item.slot,at:capsuleNow).velocity-bob.velocity
                }
                committedSprings[id]=RectSpring(dockFrom:local(world,role:target.role,slot:target.slot).offsetBy(dx:0,dy:-bob.position),to:spring.target,
                    velocity:velocity,response:spring.x.response,damping:spring.x.damping)
            }
            if capsuleWasActive,let world=capsuleMotion.rect,let owner=capsuleOwnerID,let target=nextTargets[owner] {
                oldCapsule.rect=local(world,role:target.role,slot:target.slot)
            } else if let owner=capsuleOwnerID,let source=committedSprings[owner] {
                oldCapsule=source.sample(0)
            }
            if me != nil && meChanges {
                meSpring=RectSpring(dockFrom:epoch.me.rect.offsetBy(dx:-meDelta.minX-refusal(at:capsuleNow),dy:-meDelta.minY),
                    to:meHome,velocity:epoch.me.velocity,response:0.40,damping:0.82)
                meBegan=capsuleNow
            }
        }
        for id in tideAddTails.keys {
            guard let spring=committedSprings[id] else{continue}
            let recipe=nextTargets[id]?.role == .orb ? (0.42,0.84):(spring.x.response,spring.x.damping)
            tideAddTails[id]?.size=RectSpring(dockFrom:spring.sample(0).rect,to:spring.target,response:recipe.0,damping:recipe.1)
        }
        for id in dockLandings.keys {dockLandings[id]?.until=motionNow()+duration}
        let capsuleTuning = committedSprings.values.first
        capsuleSpring = RectSpring(dockFrom: oldCapsule.rect, to: nextCapsule, velocity: oldCapsule.velocity,
                                   response: capsuleTuning?.x.response ?? 0.4, damping: capsuleTuning?.x.damping ?? 0.82)
        capsuleBegan = capsuleNow
        sampledElapsed = 0
        capsuleSampleTime = capsuleNow
        glassTransitionUntil = capsuleNow + max(duration, capsuleSpring.duration, focusedMix.duration)
        focusedMix.retarget(layout.focused ? 1 : 0, at: capsuleNow)
        refreshWords()
        segmentIDs = Array(order.prefix(layout.bars.count))
        if let target = focusTargetProvider?() { focusTarget = target }
        let targets = self.targets(layout, order: order)
        // A later gesture can demote a returning column. Its existing item then lands in the Dock.
        for (id,back) in returns where targets[id]?.role != .bar {
            returns[id]=nil;dockLandings[id]=DockLanding(header:back.header,until:motionNow()+duration)
        }
        for (id, item) in items {
            if let s = committedSprings[id], !carries(id) {
                // One owner supplies the single Focused carrier and its returning Auto member.
                item.spring = capsuleSharesOwnerPose && capsuleOwnerID == id ? capsuleSpring : s; if buds[id] != nil { endBud(id) }; if releasedNode?.id == id { releasedNode = nil } }
            guard let t = targets[id] else {
                item.identityOpacity.retarget(0, at: motionNow())
                item.emphasis.retarget(0, at: motionNow())
                fade(item.barFace,to:0,delay:0,duration:0.12)
                continue
            }
            item.target = t.rect
            if let releasedIdentity, releasedIdentity.id == id, t.role == .orb, item.role == .bar {
                item.chromeExit = (releasedIdentity.bar,motionNow())
            }
            retargetIdentity(item, target: t, spring: committedSprings[id])
            // Held, it looks like its orb whatever the preview makes it; the drop's transition gives it its look.
            if carries(id) { item.slot = t.slot;if returns[id] != nil {returns[id]?.full=fullIDs.contains(id)};continue }
            let full = fullIDs.contains(id) && t.role == .bar
            arrange(item, for: t.rect, full: full, leading: leading(t), segment: segment(t), animated: true)
            if t.role != item.role {
                if usesGaussian, let label = item.label.layer {
                    item.semanticZoomUntil = motionNow() + max(0.3, duration)
                    item.wordTrail.reset()
                    if !full && !item.full {item.wordGaussian.show(t.role == .bar, content: label, at: motionNow(), initiallyVisible: item.role == .bar, fadesContent:false)}
                    else {item.wordGaussian.reset()}
                    if M10DockMotion.orbExposureEnabled {item.decoration.setGlyphGaussianVisible(t.role == .orb, at: motionNow(), initiallyVisible: item.role == .orb, fadesContent:false)}
                    if let composer=item.ownComposer {composerMotion.setGaussianVisible(composer,t.role == .bar,at:motionNow(),initiallyVisible:item.role == .bar)}
                }
                item.role = t.role
                let now = motionNow(), from = item.faceOpacity(at: now)
                item.decoration.setPresentationActive(true)
                if t.role == .bar {
                    item.face = (from, 0, now, 0.12)
                    fade(item.barFace, to: 1, delay: usesGaussian ? 0:0.10, duration: usesGaussian ? 0.1:0.16)
                } else {
                    item.face = (from, 1, now + (usesGaussian ? 0:0.12), usesGaussian ? 0.1:0.18)
                    fade(item.barFace, to: 0, delay: 0, duration: 0.10)
                }
            }
            item.slot = t.slot
            guard full != item.full else { continue }
            item.full = full
            if full {
                fade(item.label, to: 0, delay: 0, duration: 0.10)
                // In as the words leave: an empty capsule for a quarter second read as lag (recording, 2026-10-28).
                if let composer = item.ownComposer { composer.isHidden = false; fade(composer, to: 1, delay: 0.06, duration: 0.20) }
            } else {
                if let composer = item.ownComposer { fade(composer, to: 0, delay: 0, duration: 0.12) }
                fade(item.label, to: 1, delay: 0.10, duration: 0.16)
            }
        }
        releasedIdentity = nil
        retargetSegmentAppearance()
        retargetDividers(animated:true)
        if physicalRelease { beginGlassRelease(at:capsuleNow) }
        if splitHandoff,let tuning=committedSprings.values.max(by:{$0.duration<$1.duration}) {
            queueContours(splitContours,tuning:tuning,stableRaw:false)
        }
    }

    /// At rest: the final content, without animation. A composer that is not full leaves the screen and the AX tree,
    /// unless it is mid-composition (hiding it would end the input method's session); then it waits for the next rest.
    func settleContent(full fullIDs: Set<String>) {
        endAnchoredPeeks(at:motionNow(),force:true)
        glassReleases.removeAll(keepingCapacity:true)
        let ownsBatch=beginGlassBatch();defer {endGlassBatch(ownsBatch)}
        let visibleFrames = items.mapValues { $0.motion.rect ?? $0.glass.frame }
        resetMotion()
        refreshWords()
        focusedMix = DockFade(base.focused ? 1 : 0)
        capsuleSpring = .rest(base.bars.reduce(base.bars.first ?? .zero){$0.union($1)})
        capsuleBegan = motionNow()
        capsuleOwnerID = base.focused ? segmentIDs.first : nil
        capsuleSharesOwnerPose = base.focused && base.bars.count == 1
        for (id, item) in items {
            if returns[id] != nil {continue}
            let r = item.spring.sample(.infinity).rect
            item.target = r
            let full = fullIDs.contains(id) && item.role == .bar
            arrange(item, for: r, full: full, leading: leading((item.role, r, item.slot)), segment: segment((item.role, r, item.slot)))
            item.full = full
            let segmented = base.focused && item.role == .bar
            item.segmentMix = DockFade(segmented ? 1 : 0)
            item.emphasis = DockFade(segmented && base.bars.count > 1 && id == selectedSegment ? 1 : 0)
            item.controlsOpacity = DockFade(segmented && base.bars.count > 1 && id != selectedSegment ? 0.62 : 1)
            retargetIdentity(item, target: (item.role, r, item.slot), spring: nil)
            item.identityOpacity = DockFade(base.focused && item.identity != nil && (item.role == .orb || item.slot > 0) ? 1 : 0)
            item.chromeExit = nil
            item.ownComposer?.finishSegmentTransition()
            for view in [item.label, item.composer, item.barFace].compactMap({ $0 }) { view.layer?.removeAnimation(forKey: Self.fadeKey) }
            item.barFace.alphaValue = item.role == .bar ? 1 : 0
            let orb = item.role == .orb
            item.face = (orb ? 1 : 0, orb ? 1 : 0, 0, 0)
            item.decoration.setOpacity((orb ? 1 : 0) * (1-item.identityOpacity.value(at:motionNow())))
            // A bar's decoration stops its clocks (liquid, satellites) until it is an orb again.
            item.decoration.setPresentationActive(orb && item.identityOpacity.to < 1)
            item.label.alphaValue = full ? 0 : 1
            if let composer = item.ownComposer {
                composer.alphaValue = full ? 1 : 0
                composer.isHidden = !full && !composer.isComposing
            }
        }
        for (id,item) in items where returns[id] == nil { place(item, visibleFrames[id] ?? item.spring.target) }
        retargetDividers(animated:false)
        updateFocusedGlass()
        reconcileGlassTopology()
        configureTide()
    }

    // MARK: New Chat's draft bar (f047, f048)

    /// The draft's input under its column: its own glass in the dock's container, no entrance (a new node starts where
    /// it rests), the draft's composer full in it. It rises with the bars.
    private var draftBar: (glass: NSGlassEffectView, face: NSView, composer: NativeComposer, rect: CGRect)?
    var draftBarFrame: CGRect? { draftBar?.glass.frame }

    func showDraftBar(_ composer: NativeComposer, at r: CGRect) {
        let glass = draftBar?.glass ?? NSGlassEffectView()
        let face = draftBar?.face ?? NSView()
        if draftBar == nil {
            dressGlass(glass)
            face.wantsLayer = true; face.layer?.masksToBounds = true
            glass.contentView = face
            content.addSubview(glass)
        }
        if composer.superview !== face { composer.removeFromSuperview(); face.addSubview(composer) }
        draftBar = (glass, face, composer, r)
        composer.isHidden = false; composer.alphaValue = 1
        composer.targetWidth = r.width
        composer.frame = CGRect(origin: .zero, size: r.size); composer.layoutSubtreeIfNeeded()
        composerMotion.prepare(composer, atCommit: true)
        placeDraft(r.offsetBy(dx: 0, dy: -rise))
    }

    func hideDraftBar() {
        composerMotion.reset()
        draftBar?.glass.removeFromSuperview()
        draftBar = nil
    }

    private func placeDraft(_ r: CGRect) {
        guard let d = draftBar else { return }
        let f = draftMotion.update(r, at: motionNow(), name: "dock.draft", profile: exposureProfile, enabled: usesExposure)
        writeGlass(d.glass, frame:f.painted)
        d.face.frame = CGRect(x: r.minX-f.painted.minX, y: r.minY-f.painted.minY, width: r.width, height: r.height)
        d.face.layer?.cornerRadius = r.height / 2
        onMotionFrame?(f)
        d.composer.frame = CGRect(origin: .zero, size: r.size)
        onComposerMotion?(d.composer, f, exposureProfile)
    }

    /// The first send (f048): the new conversation's node takes the draft bar's place and frame, as a bar, so nothing
    /// moves; the composer (the same editor, promoted) goes into it with the next arrangement.
    func adoptDraftBar(as id: String) {
        guard let d = draftBar, let item = items[id] else { return }
        let r = d.glass.frame.offsetBy(dx: 0, dy: rise)
        item.spring = .rest(r); item.target = r; item.role = .bar
        item.barFace.alphaValue = 1; item.face = (0, 0, 0, 0); item.decoration.setOpacity(0)
        place(item, d.glass.frame)
        hideDraftBar()
    }

    // MARK: Refusal (f049)

    private var refusalStart: Double?
    /// Focused and Split don't take a new chat: the capsule and me shake their head, 240 ms (NativeDockScene: x 0, −6,
    /// 5, −3, 2, 0 at 0, 40, 85, 130, 180, 240 ms).
    func refuse() { if base.focused { refusalStart = motionNow() } }
    private func refusal(at now: Double) -> CGFloat {
        guard let start = refusalStart else { return 0 }
        let times = [0.0, 0.04, 0.085, 0.13, 0.18, 0.24], values: [CGFloat] = [0, -6, 5, -3, 2, 0]
        let t = now - start
        guard t < 0.24 else { refusalStart = nil; return 0 }
        guard let i = (0..<5).first(where: { t >= times[$0] && t < times[$0 + 1] }) else { return 0 }
        let p = CGFloat((t - times[i]) / (times[i + 1] - times[i]))
        return values[i] + (values[i + 1] - values[i]) * p
    }

    // MARK: Appearing (f066; NativeDockScene.bloom)

    private var blooms: [String: (delta: RectSpring, release: Double)] = [:]
    private var barBloom: (spring: Spring, began: Double)?
    /// When the last bud is at rest (media time).
    var bloomSettles: Double {
        max(blooms.values.map { $0.release + $0.delta.duration }.max() ?? 0, barBloom.map { $0.began + $0.spring.duration } ?? 0)
    }

    /// The dock appears (Organic opened directly, or entered without every planet flying in): the bars settle from 1.06 ×
    /// (0.22 / 1.0); each orb not in `excluding` buds at 0.9 × from the nearest bar's end, released left to right 40 ms
    /// apart from 0.10 s (0.38 / 0.78), its planet unveiled over 0.08 s from 0.09 s after its release.
    func bloom(excluding ids: Set<String>) {
        let now = motionNow()
        barBloom = (Spring(from: 1.06, to: 1, response: 0.22, damping: 1, epsilon: Spring.restEpsilon / 200), now)
        if usesGaussian {
            for item in items.values where item.role == .bar {
                item.semanticZoomUntil = now + 0.7
                item.wordTrail.reset()
                if !item.full, let label = item.label.layer { item.wordGaussian.show(true, content: label, at: now, initiallyVisible: false, duration:0.16) }
            }
        }
        let bars = items.values.filter { $0.role == .bar }.map(\.target)
        let orbs = items.values.filter { $0.role == .orb && !ids.contains($0.conversation.id) }.sorted { $0.target.midX < $1.target.midX }
        for (rank, item) in orbs.enumerated() {
            let t = item.target
            let bar = bars.min { abs($0.midX - t.midX) < abs($1.midX - t.midX) }
            let inset = min(t.width, bar?.height ?? t.height) / 2 + 2
            let c = bar.map { CGPoint(x: t.midX >= $0.midX ? $0.maxX - inset : $0.minX + inset, y: $0.midY) } ?? CGPoint(x: t.midX, y: t.midY)
            let w = t.width * 0.9, h = t.height * 0.9
            let start = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            let release = now + 0.1 + 0.04 * Double(min(rank, 4))
            if usesGaussian {
                item.semanticZoomUntil = release + 0.7
                if M10DockMotion.orbExposureEnabled {item.decoration.setGlyphGaussianVisible(true, at: release, initiallyVisible: false)}
            }
            blooms[item.conversation.id] = (RectSpring(from: CGRect(x: start.minX - t.minX, y: start.minY - t.minY, width: w - t.width, height: h - t.height),
                                                       to: .zero, response: 0.38, damping: 0.78), release)
            item.veil = (1, 0, release + 0.09, 0.08)
            item.decoration.setVeil(1)
        }
    }

    // MARK: Hide / Show Sidebar (f028–f030)

    /// Where every node rests after the last commit, for the planets flying in: bars and orbs, by conversation.
    var restingTargets: [(id: String, rect: CGRect, bar: Bool, slot: Int)] {
        items.values.map { ($0.conversation.id, $0.target, $0.role == .bar, $0.slot) }
    }
    var meRest: CGRect { base.me }
    var meFrame: CGRect? { me?.frame }

    /// Hidden while their flights are on the way: me, an orb (until its planet arrives), the full bar (until the
    /// composer's glass does). Nothing else changes.
    func setMeHidden(_ hidden: Bool) {
        me?.isHidden = hidden
        meDecoration?.backView.isHidden = hidden; meDecoration?.frontView.isHidden = hidden
    }
    func setHidden(_ id: String, _ hidden: Bool) {
        guard let item = items[id] else { return }
        if hidden,!tideFrozen,tideMaterialShapes[id] != nil {clearTideMaterialProbe()}
        if hidden { composerMotion.reset() }
        setHiddenPaint(item,hidden)
    }
    private func setHiddenPaint(_ item:Item,_ hidden:Bool) {
        if ModeDepartureSurfaces.retains(item.glass) {return}
        var hidden=hidden || trashHiddenMember == item.conversation.id
        if let browserDockPort, browserDockPort.coversMember(item.conversation.id) { hidden = true }
        // Layers hidden, not views: a bar holds its conversation's editor, and hiding the view would take the keyboard
        // from it (Hide Sidebar's composer flight; f030, f101). Glass ignores alphaValue, and the bar's face (the
        // editor) does not draw under the glass's layer, so both go (product: the arriving bar at opacity 0).
        // The glass's content is not drawn under the glass's own layer: an orb's body (the decoration's bodyView, in
        // `content`) kept showing while its planet flew in, two of it (f029, 10-29 recording).
        item.glass.layer?.isHidden = hidden
        item.content.layer?.isHidden = hidden
        item.barFace.layer?.isHidden = hidden; item.chromeHost.isHidden = hidden; item.identity?.glassView.isHidden = hidden; item.identity?.backView.isHidden = hidden; item.identity?.frontView.isHidden = hidden
        // Nor does that hide the glass itself: an empty glass circle waited in the slot. An orb holds no editor, so its
        // glass view can go (a bar keeps its view for the keyboard's sake; its flight's glass covers it).
        if item.role != .bar || !hidden { item.glass.isHidden = hidden }
        item.decoration.backView.isHidden = hidden; item.decoration.frontView.isHidden = hidden
        item.grip.isHidden = hidden || item.role != .bar
        if tideFrozen,tideFrozenSources[item.conversation.id] != nil {
            // Native mode admission may repaint its ordinary planet; the frozen notification owns this ink.
            item.decoration.setOpacity(Float(tideTimeline?.owner==item.conversation.id ? tideTimeline?.ownerInk.opacity ?? 0:0))
            item.chromeHost.layer?.opacity=0;item.grip.opacity=0
        }
    }

    /// Back from Normie: every composer it took returns to its bar, laid out and shown as the bar is.
    func remountComposers() {
        if let target = focusTargetProvider?() { focusTarget = target }
        for item in items.values {
            guard let composer = item.composer, composer.superview !== item.barFace else { continue }
            composer.removeFromSuperview()
            item.barFace.addSubview(composer)
            arrange(item, for: item.target, full: item.full, leading: leading((item.role, item.target, item.slot)), segment: segment((item.role, item.target, item.slot)))
            composer.alphaValue = item.full ? 1 : 0
            composer.isHidden = !item.full
        }
    }

    /// Lays a node's bar content out for `target`, its resting frame: the words, and the composer when full.
    /// Room kept at a bar's leading end: Focused's first segment holds me there (DockItems FullBar `leading`).
    private func leading(_ t: (role: Role, rect: CGRect, slot: Int)) -> CGFloat {
        base.focused && t.role == .bar && t.slot == 0 ? t.rect.height : 0
    }

    /// A Focused / Split bar's place in the capsule, for its composer's ends (FocusedSegmentControls).
    private func segment(_ t: (role: Role, rect: CGRect, slot: Int)) -> NativeComposerSegment? {
        base.focused && t.role == .bar ? NativeComposerSegment(index: t.slot, isLast: t.slot == base.bars.count - 1) : nil
    }

    private func arrange(_ item: Item, for target: CGRect, full: Bool, leading: CGFloat = 0, segment: NativeComposerSegment? = nil, animated: Bool = false) {
        item.barFace.frame = CGRect(origin: .zero, size: target.size)
        let inset = max(16, target.height * 0.4)
        item.label.sizeToFit()
        item.label.frame = CGRect(x: inset, y: ((target.height - item.label.frame.height) / 2).rounded(),
                                  width: max(0, target.width - inset - 16), height: item.label.frame.height)
        prepareWords(item)
        guard full || item.composer != nil else { return }
        if item.composer == nil, let composer = composerFor?(item.conversation) {
            composer.alphaValue = 0; composer.isHidden = true
            item.barFace.addSubview(composer); item.composer = composer
            watchTideEditor(composer)
        }
        guard full, let composer = item.ownComposer else { return }
        let nextFrame = CGRect(x: leading, y: 0, width: target.width - leading, height: target.height)
        let changes = (segment != nil || composer.segment != nil) && (composer.segment != segment || composer.frame != nextFrame)
        if animated && changes { composer.beginSegmentTransition(at: motionNow()) }
        composer.segment = segment
        composer.targetWidth = target.width - leading
        composer.frame = nextFrame
        composer.layoutSubtreeIfNeeded()
        if animated && changes { composer.commitSegmentTransition(at: motionNow()) }
        composerMotion.prepare(composer, atCommit: true)
    }

    private func prepareWords(_ item: Item) {
        let label = item.label
        if item.wordTrail.prepare(label, key: "\(label.stringValue)|\(label.bounds)|\(label.textColor?.description ?? "")",
                                  scale: view.window?.backingScaleFactor ?? 2) {
            // New text/layout has no earlier matching glyph bitmap; do not stretch a truncated new word into old text.
            item.wordMotion.reset()
        }
    }

    private var selectedSegment: String? {
        if let focusTarget, segmentIDs.contains(focusTarget) { return focusTarget }
        return segmentIDs.first
    }

    private func retargetSegmentAppearance() {
        let now = motionNow()
        for (id, item) in items {
            guard segmentIDs.contains(id) || item.role == .orb else { continue }
            let segmented = base.focused && segmentIDs.contains(id)
            item.segmentMix.retarget(segmented ? 1 : 0, at: now)
            item.emphasis.retarget(segmented && base.bars.count > 1 && id == selectedSegment ? 1 : 0, at: now)
            item.controlsOpacity.retarget(segmented && base.bars.count > 1 && id != selectedSegment ? 0.62 : 1, at: now)
        }
    }

    private func retargetIdentity(_ item: Item, target: (role: Role, rect: CGRect, slot: Int), spring: RectSpring?) {
        let now = motionNow()
        let segmentIdentity = base.focused && target.role == .bar && target.slot > 0
        guard segmentIdentity || item.identity != nil else { return }
        let visible = base.focused && (target.role == .orb || segmentIdentity)
        let diameter = max(1, target.role == .bar ? base.me.width : target.rect.width)
        let end = segmentIdentity ? CGRect(x: target.rect.maxX - target.rect.height / 2 - diameter / 2,
                                  y: target.rect.midY - diameter / 2, width: diameter, height: diameter) :
            (target.role == .orb ? target.rect : CGRect(x: target.rect.maxX - target.rect.height / 2 - diameter / 2,
                                                       y: target.rect.midY - diameter / 2, width: diameter, height: diameter))
        if item.identity == nil {
            let identity = OrbComponent(id: "identity." + item.conversation.id)
            content.addSubview(identity.glassView); mount(identity); dressGlass(identity.glassView)
            item.identity = identity
            let start = item.role == .orb ? item.glass.frame : end
            item.identitySpring = .rest(start.offsetBy(dx:-refusal(at:now),dy:rise)); item.identityFrame = start
            identity.setOpacity(0)
        }
        let current: (rect: CGRect, velocity: CGRect)
        if let source = transitionIdentitySources?[item.conversation.id] {
            current = (source.rect.offsetBy(dx:-refusal(at:now),dy:rise),source.velocity)
        } else { current = item.identitySpring.sample(now-item.identityBegan) }
        item.identitySpring = spring.map { RectSpring(dockFrom: current.rect, to: end, velocity: current.velocity,
                                                      response: $0.x.response, damping: $0.x.damping) } ?? .rest(end)
        item.identityBegan = now
        item.identityOpacity.retarget(visible ? 1 : 0, at: now)
        if let identity = item.identity {
            identity.configure(makeOrbConfiguration(item.conversation, drawingSize: max(metrics.orb,metrics.orbMagnified,1),
                backingScale: view.window?.backingScaleFactor ?? 2, reduceMotion: Motion.reduce,
                ambient: ambient && !still, isKeyWindow: view.window?.isKeyWindow ?? true))
            // A newly grafted segment inherits this same member's prepared pickup ink.
            if item.decoration.pointerInkPrepared {identity.preparePointerInk()}
            identity.setPresentationActive(true)
        }
    }

    private func placeIdentity(_ item: Item, at now: Double, heldRect:CGRect? = nil) {
        if ModeDepartureSurfaces.retains(item.glass) {return}
        if held?.identity == true, held?.id == item.conversation.id, heldRect == nil { return }
        guard let identity = item.identity else { return }
        let alpha:Float = carriesHeader(item.conversation.id) ? 0:item.identityOpacity.value(at: now)
        let r = heldRect ?? item.identitySpring.sample(now - item.identityBegan).rect.offsetBy(dx: refusal(at: now), dy: -rise)
        if heldRect != nil { item.identitySpring = .rest(r.offsetBy(dx:-refusal(at:now),dy:rise)); item.identityBegan = now }
        let f = item.identityMotion.update(r, at: now, name: "dock.identity." + item.conversation.id,
                                          profile: exposureProfile, enabled: usesExposure)
        if frameLog != nil { rawExposed[f.name] = f }
        item.identityFrame = r
        writeGlass(identity.glassView,frame:f.painted,alpha:CGFloat(alpha))
        identity.setFrame(f.painted)
        identity.setOpacity(alpha)
        identity.setPresentationActive(ambientRunning && alpha > 0)
        // Same physical treatment as the other planets. The M10 interface itself is unchanged.
        M10DockMotion.onOrbFrame?(identity, f, exposureProfile)
    }

    private func reconcileGlassTopology() {
        if collectingGlass && !resolvingGlass { return }
        // Direct sample/release callers also commit glass; the display callback is not the only writer.
        applyDynamicTide()
        applyTideMaterialProbe()
        if !collectingGlass { applyGlassReleases() }
        struct Part { let id: String; let view: NSGlassEffectView; let logical: CGRect; let target: CGRect; let locked: Bool }
        var parts: [Part] = []
        func add(_ id: String, _ glass: NSGlassEffectView?, _ logical: CGRect?, _ target: CGRect, locked: Bool = false) {
            guard let glass, let logical, !glassHidden(glass), glass.layer?.isHidden != true,
                  glass.superview === content, logical.width > 0, logical.height > 0 else { return }
            parts.append(Part(id:id,view:glass,logical:releaseLogical(glass,fallback:logical) ?? logical,target:target,locked:locked))
        }
        // A carried destination follows the pointer; its home only becomes the target after release.
        add("me", me, meMotion.rect, meHeld != nil ? (meMotion.rect ?? meSpring.target.adding(meDelta)) : meSpring.target.adding(meDelta), locked:meHeld != nil || sunHoverDockHeld)
        for (id, item) in items {
            if tideSides[id]?.pose.shown == true {continue}
            if tideAddTails[id] != nil {
                let body=glassFrame(item.glass)
                var destination=item.target
                if item.role == .bar {destination=destination.offsetBy(dx:0,dy:-rise)}
                else if orbDeltas.indices.contains(item.slot) {destination=destination.adding(orbDeltas[item.slot])}
                // The contour is physical now; its topology destination is the canonical Add layout.
                add(id,item.glass,body,destination,locked:true)
                if let shape=tidePool[id],let contour=shape.contour {for (v,p) in zip(shape.views,contour.tail) {add(id,v,p.rect,destination,locked:true)}}
                continue
            }
            if let r=tideNodePoses[id] {add(id,item.glass,r,r,locked:true);continue}
            if let shape = tideMaterialShapes[id], let contour = shape.contour {
                add(id,item.glass,contour.body.rect,contour.body.rect,locked:true)
                for (glass,part) in zip(shape.views,contour.tail) {add(id,glass,part.rect,part.rect,locked:true)}
                continue
            }
            var target = item.target
            if carries(id) { target = item.motion.rect ?? target }
            else if item.role == .bar { target = target.offsetBy(dx: 0, dy: -rise) }
            else if orbDeltas.indices.contains(item.slot) { target = target.adding(orbDeltas[item.slot]) }
            // A Peek bud owns a separate content-frame projection; keep its existing glass/content contract.
            if buds[id] != nil { topologyPeekExclusions.insert(id) }
            else if let logical = item.motion.rect, MotionStep.edge(logical,item.glass.frame)<0.001 { topologyPeekExclusions.remove(id) }
            // The segment keeps its resting motion, but its facing glass edge yields to its carried identity.
            let heldGlass = carries(id) && !(held?.id == id && held?.identity == true)
            if !topologyPeekExclusions.contains(id) { add(id, item.glass, item.motion.rect, target, locked:heldGlass) }
            add("identity." + id, item.identity?.glassView, item.identityMotion.rect, item.identitySpring.target.offsetBy(dx: 0, dy: -rise),
                locked:(held?.id == id && held?.identity == true) || releasedGlassID == id)
        }
        if let id = capsuleOwnerID, let logical = capsuleMotion.rect {
            let sample = capsuleSpring.sample(motionNow() - capsuleBegan).rect
            let delta = CGRect(x: logical.minX-sample.minX, y: logical.minY-sample.minY,
                               width: logical.width-sample.width, height: logical.height-sample.height)
            add(id, focusedGlass, logical, capsuleSpring.target.adding(delta))
        }
        if let draftBar { add("draft", draftBar.glass, draftMotion.rect, draftBar.rect.offsetBy(dx: 0, dy: -rise)) }
        var groups: [String: DockGlassTopology.Shape] = [:]
        for part in parts {
            let old = groups[part.id]
            groups[part.id] = .init(id: part.id, logical: old?.logical.union(part.logical) ?? part.logical,
                                   target: old?.target.union(part.target) ?? part.target,
                                   painted: old?.painted.union(glassFrame(part.view)) ?? glassFrame(part.view), locked:part.locked || old?.locked == true)
        }
        // Only pairs touching the physical carrier follow pointer geometry; neighbours follow layout targets.
        var carriedIDs:Set<String>=[]
        if let held {carriedIDs.insert(held.identity ? "identity."+held.id:held.id)}
        if meHeld != nil {carriedIDs.insert("me")}
        let result = glassTopology.resolve(Array(groups.values), spacing: container.spacing,
            monotonic: held == nil && meHeld == nil && motionNow() < glassTransitionUntil, at: motionNow(),carriedIDs:carriedIDs)
        for part in parts {
            guard let bounds = result[part.id], let original = groups[part.id]?.painted else { continue }
            let old = glassFrame(part.view)
            var clipped = old.intersection(bounds)
            if !DockGlassTopology.safeMarginEnabled, glassRetargetTime == motionNow(), let previous = glassRetargetPaint[ObjectIdentifier(part.view)] {
                // The previous frame already includes topology clearance. Do not expand it a second time.
                clipped = previous
            } else {
                if old.minX == original.minX && bounds.minX < original.minX { clipped.origin.x = bounds.minX; clipped.size.width += original.minX-bounds.minX }
                if old.maxX == original.maxX && bounds.maxX > original.maxX { clipped.size.width += bounds.maxX-original.maxX }
                if old.minY == original.minY && bounds.minY < original.minY { clipped.origin.y = bounds.minY; clipped.size.height += original.minY-bounds.minY }
                if old.maxY == original.maxY && bounds.maxY > original.maxY { clipped.size.height += bounds.maxY-original.maxY }
            }
            if DockGlassTopology.safeMarginEnabled && !part.locked {
                // The capsule and its retained owner share one authority; no union-to-parts gap can reappear.
                clipped = CGRect(x:bounds.minX,y:old.minY,width:bounds.width,height:old.height)
            }
            if DockGlassTopology.safeMarginEnabled && part.locked { clipped = old }
            guard !clipped.isNull else { continue }
            guard clipped != old else { continue }
            let ink = part.view.contentView?.frame
            writeGlass(part.view,frame:clipped,reason:"projection")
            // Glass clipping must not move or scale the existing content/exposure in world coordinates.
            if let ink { part.view.contentView?.frame = ink.offsetBy(dx: old.minX-clipped.minX, dy: old.minY-clipped.minY) }
        }
        if tideDynamic {
            // A focused identity is another surface of the same conversation, not a different owner.
            // Zero-alpha retired identities are not physical neighbours in the Auto row.
            let physical=parts.filter {(glassWrites[ObjectIdentifier($0.view)]?.alpha ?? $0.view.alphaValue)>0.001}.map {
                ($0.id.hasPrefix("identity.") ? String($0.id.dropFirst(9)):$0.id,glassFrame($0.view))
            }
            tideMinimumGap = .infinity
            for a in physical {for b in physical where a.0 != b.0 {let gap=TideContour.gap(a.1,b.1);if gap<tideMinimumGap {tideMinimumGap=gap;tideWorstPair=a.0+"|"+b.0}}}
        }
        if !collectingGlass {applyContourHandoffs()}
    }

    private func withdrawFocusedGlass() {
        glassReleases[ObjectIdentifier(focusedGlass)]=nil
        writeGlass(focusedGlass,frame:.zero,alpha:0,hidden:true)
        focusedMix = DockFade(0)
        capsuleOwnerID = nil; capsuleSharesOwnerPose = false
        capsuleSpring = .rest(.zero); capsuleBegan = motionNow()
        capsuleMotion.reset()
        capsuleSampleTime = nil
        for divider in segmentDividers.values { divider.layer.opacity = 0 }
    }

    private func updateFocusedGlass() {
        let now = motionNow()
        capsuleSampleTime = now
        let alpha = focusedMix.value(at: now)
        let owner = capsuleOwnerID.flatMap { items[$0] }
        if base.focused {
            guard let owner, owner.glass.superview === content, !base.bars.isEmpty else {
                withdrawFocusedGlass(); return
            }
        } else if capsuleOwnerID != nil && (owner == nil || owner?.glass.superview !== content) {
            withdrawFocusedGlass(); return
        } else if base.bars.isEmpty && owner == nil {
            withdrawFocusedGlass(); return
        }
        let logical=projectedCapsule(capsuleSpring.sample(now-capsuleBegan).rect,at:now)
        let f = capsuleMotion.update(logical,at:now,name:"dock.capsule",profile:exposureProfile,enabled:usesExposure)
        let rect = f.painted
        if frameLog != nil { rawExposed[f.name] = f }
        onMotionFrame?(f)
        writeGlass(focusedGlass,frame:rect,alpha:CGFloat(alpha))
        // Alpha-zero glass still fuses in NSGlassEffectContainerView. Keep the outgoing shape
        // through its complete spring (and exposure tail), then withdraw it inside its Auto node.
        let returning = capsuleOwnerID != nil && (now - capsuleBegan < capsuleSpring.duration || alpha > 0 || f.exposure.length > 0)
        writeGlass(focusedGlass,hidden:!base.focused && !returning)
        if glassHidden(focusedGlass) { capsuleOwnerID = nil }
        for (id, divider) in segmentDividers {
            guard let item = items[id] else { continue }
            let frame = glassFrame(item.glass)
            let path = CGMutablePath()
            path.move(to:CGPoint(x:frame.maxX,y:frame.minY+10))
            path.addLine(to:CGPoint(x:frame.maxX,y:frame.maxY-10))
            divider.layer.path = path; divider.layer.lineWidth = 1
            divider.layer.fillColor = nil
            divider.layer.strokeColor = (NativeAppearance.current.foreground?.withAlphaComponent(0.1) ?? NSColor.separatorColor).cgColor
            divider.layer.opacity = divider.opacity.value(at:now) * alpha
        }
    }

    private func retargetDividers(animated:Bool) {
        let ids = Set(base.focused ? segmentIDs.dropLast() : [])
        for id in ids where segmentDividers[id] == nil {
            let divider = Divider();segmentDividers[id] = divider
            chromePlane.layer?.insertSublayer(divider.layer,at:0)
        }
        for (id,divider) in segmentDividers {
            let target:Float = ids.contains(id) ? 1:0
            if animated {divider.opacity.retarget(target,at:motionNow())}
            else {divider.opacity = DockFade(target)}
        }
        if !animated {
            for id in Array(segmentDividers.keys) where !ids.contains(id) {
                segmentDividers.removeValue(forKey:id)?.layer.removeFromSuperlayer()
            }
        }
    }

    private static let fadeKey = "shell.fade"
    /// Opacity to `target` on the render server, from wherever it is on screen now (a reversal starts there).
    private func fade(_ view: NSView, to target: CGFloat, delay: Double, duration: Double) {
        guard let layer = view.layer else { view.alphaValue = target; return }
        let from = CGFloat(layer.presentation()?.opacity ?? layer.opacity)
        layer.removeAnimation(forKey: Self.fadeKey)
        view.alphaValue = target
        guard abs(from - target) > 0.001 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = target
        a.beginTime = layer.convertTime(motionNow(), from: nil) + delay
        a.duration = duration
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: Self.fadeKey)
    }

    /// The pointer moved (nil: it left the window). Returns how long frames are needed from `now`.
    func pointer(_ p: CGPoint?, now: Double) -> Double {
        advanceTideClock(to:tideNow())
        tidePointer=p
        for side in tideSides.values where side.active {side.hover(side.pose.shown && (p.map{side.glass.frame.contains($0) || side.pose.orb.contains($0)} ?? false),at:tideNow())}
        let tideInside=tideTimeline?.owner.flatMap{tideNodePoses[$0]}.map{r in p.map(r.contains) ?? false} ?? false
        tideTimeline?.hover(tideInside)
        scheduleTideWake()
        refreshTideProtection()
        synchronizeInjectedClock(at:now)
        // While a peek shows, the dock holds its magnification and rise (NativeDockScene: `if !peeking`).
        if sunHoverDockHeld { return 0 }
        guard peekShown == nil else { return 0.05 }
        let restTop = base.bars.first?.minY ?? base.me.minY
        // Enter 24 pt above the dock's resting top; leave 12 pt further up (hysteresis).
        // The notification owns its 36 pt orb; its hover must not magnify the ordinary row underneath it.
        let sideOwnsPointer=tideSides.values.contains {side in side.pose.shown && (p.map{side.glass.frame.contains($0) || side.pose.orb.contains($0)} ?? false)}
        let autoOwnsPointer=tideTimeline?.active == true && (tideInside || (p.map {point in tideMaterialPoses.values.contains{$0.body.rect.contains(point)}} ?? false))
        let inside = !sideOwnsPointer && !autoOwnsPointer && (p.map { $0.y > restTop - (hovering ? 36 : 24) } ?? false)
        pointerX = inside ? p?.x : pointerX
        if inside != hovering {
            hovering = inside
            pendingLeave?.cancel(); pendingLeave = nil
            if inside { retargetHover(to: 1, now: now) } else {
                // Leaving waits 0.08 s before the dock comes down.
                let w = DispatchWorkItem { [weak self] in self?.retargetHover(to: 0, now: self?.motionNow() ?? CACurrentMediaTime()); self?.onNeedsFrames?(0.6) }
                pendingLeave = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
            }
        }
        return max(0.05, hover.duration - (now - hoverBegan), lift.duration - (now - liftBegan))
    }

    var onNeedsFrames: ((Double) -> Void)?
    /// Absolute media-time deadline for springs begun at a predicted display target.
    var onNeedsFramesUntil: ((Double) -> Void)?
    /// Esc while a node is held, wherever the key lands first (AutoScene.cancelDrag). True when there was one.
    var cancelHeldPress: (() -> Bool)?

    private func retargetHover(to v: Double, now: Double) {
        let c = hover.sample(now - hoverBegan)
        // Enter 0.26 / 0.86, leave 0.30 / 0.90 (NativeDockScene.swift:1115-1130).
        hover = Spring(from: c.value, to: v, velocity: c.velocity, response: v > 0.5 ? 0.26 : 0.30, damping: v > 0.5 ? 0.86 : 0.90,
                       epsilon: Spring.restEpsilon / 48)
        hoverBegan = now
        retargetLift(hovered: v > 0.5, now: now)
    }

    /// Driver A for hover, at media time `now`: me placed, and what hover adds to each orb slot and to the bars.
    func hoverFrame(at now: Double, placeMe shouldPlaceMe: Bool = true) {
        synchronizeInjectedClock(at:now)
        let q = still ? 0 : CGFloat(min(1, max(0, hover.sample(now - hoverBegan).value)))
        let up = still ? 0 : CGFloat(min(1, max(0, lift.sample(now - liftBegan).value)))
        // Holding a node, the dock stays up but nothing magnifies (NativeDockScene beginDrag: amount = 0).
        let amount = held == nil ? q : 0
        let laidOrbs: [CGRect], laidMe: CGRect
        if base.focused {
            // Focused / Split: each side re-packs outward from the capsule, which never moves (FocusLayout.magnified).
            var f = FocusLayout()
            f.segments = base.bars; f.capsule = base.bars.reduce(base.bars.first ?? .zero) { $0.union($1) }; f.me = base.me
            f.leftOrbs = base.orbs.filter { $0.midX < f.capsule.minX }; f.rightOrbs = base.orbs.filter { $0.midX >= f.capsule.minX }
            let l = f.magnified(pointerX: pointerX, amount: amount, metrics: metrics).raised(up, metrics: metrics)
            laidOrbs = l.leftOrbs + l.rightOrbs; laidMe = l.me
        } else {
            let l = base.magnified(pointerX: pointerX, amount: amount, metrics: metrics).raised(up, metrics: metrics)
            laidOrbs = l.orbs; laidMe = l.me
        }
        meDelta = CGRect(x: laidMe.minX - base.me.minX, y: laidMe.minY - base.me.minY, width: laidMe.width - base.me.width, height: laidMe.height - base.me.height)
        let r = meSpring.sample(now - meBegan).rect
        let meRect = CGRect(x: r.minX + meDelta.minX + refusal(at: now), y: r.minY + meDelta.minY, width: r.width + meDelta.width, height: r.height + meDelta.height)
        if shouldPlaceMe && meHeld == nil { placeMe(meRect, at: now) }
        orbDeltas = zip(laidOrbs, base.orbs).map { CGRect(x: $0.minX - $1.minX, y: $0.minY - $1.minY, width: $0.width - $1.width, height: $0.height - $1.height) }
        rise = metrics.hoverRise * up
        paintedHoverPose = (Double(amount), Double(up), pointerX)
    }

    /// me's and the orbs' current frames, for receipts.
    var nodeFrames: [CGRect] { ([me?.frame].compactMap { $0 }) + items.values.filter { $0.role == .orb }.sorted { $0.slot < $1.slot }.map(\.glass.frame) }
    /// The independent slot consumes the already painted hover/LL hold, without writing another Dock channel.
    func browserSlotFrame(_ slot: CGRect) -> CGRect {
        guard let pose=paintedHoverPose else {return slot}
        var projection=AutoLayout();projection.orbs=[slot]
        return projection.magnified(pointerX:pose.pointerX,amount:CGFloat(pose.amount),metrics:metrics)
            .raised(CGFloat(pose.lift),metrics:metrics).orbs[0]
    }

    /// The conversation whose orb is under `p` (at least 44 × 44 pt to hit, §E), if any.
    func orb(at p: CGPoint) -> Conversation? {
        items.values.first { item in
            guard item.role == .orb else { return false }
            let f = item.glass.frame
            if buds[item.conversation.id]?.open == true { return f.contains(p) }
            return f.insetBy(dx: min(0, (f.width - 44) / 2), dy: min(0, (f.height - 44) / 2)).contains(p)
        }?.conversation
    }

    /// Use one display timestamp for hover, spring sampling, exposure and topology.
    func frame(at now: Double, elapsed: Double) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer { CATransaction.commit() }
        synchronizeInjectedClock(at:motionTime?() ?? now)
        let hadTide=tideTimeline?.active == true
        if hadTide {tideFrameMoving=tideTimeline?.busy == true && !tideFrozen}
        defer {
            if hadTide {if tideFrameMoving == true {tideMovingCallbacks+=1}else{tideStillCallbacks+=1}}
            if tideTimeline?.busy == true,!tideFrozen {onTideMotion?();onNeedsFramesUntil?(now)}
            tideFrameMoving=nil
        }
        batchID += 1
        if frameLog != nil { capturesWriteLog = true; glassTopology.beginFrameLog(); writeTrace.removeAll(keepingCapacity:true); rawExposed.removeAll(keepingCapacity:true) }
        let ownsBatch = beginGlassBatch()
        latestDisplayTime = max(latestDisplayTime, now)
        displayTime = now
        defer { displayTime = nil; capturesWriteLog = false }
        hoverFrame(at: now)
        sample(elapsed)
        heldFrame(at: now)
        headerLandingFrame(at:now)
        applyTideMaterialProbe()
        applyTideAddTails()
        renderTideSides()
        onTrashFrame?(now)
        browserDockPort?.frame(at: now)
        endGlassBatch(ownsBatch)
        onTrashApplied?()
        recordLift(at:now,writer:"frame")
        if let frameLog {
            recordFrameLog(frameLog, target: now, elapsed: elapsed)
            glassTopology.endFrameLog()
        }
    }

    /// Reads applied views only, after every geometry writer in this display callback has finished.
    private func recordFrameLog(_ log: DockFrameLog.Context, target: Double, elapsed: Double) {
        let snapshotBegan = CACurrentMediaTime()
        var known: [ObjectIdentifier: (String, String?, CGRect?)] = [:]
        func identify(_ glass: NSGlassEffectView?, _ id: String, _ group: String?, _ logical: CGRect?) {
            if let glass { known[ObjectIdentifier(glass)] = (id, group, logical) }
        }
        identify(focusedGlass, "focusedGlass", capsuleOwnerID, capsuleMotion.rect)
        identify(me, "me", "me", meMotion.rect)
        for (id, item) in items {
            identify(item.glass, "item." + id, id, item.motion.rect)
            identify(item.identity?.glassView, "identity." + id, "identity." + id, item.identityMotion.rect)
        }
        identify(draftBar?.glass, "draft", "draft", draftMotion.rect)
        var nodes: [[String: Any]] = []
        func visit(_ parent: NSView, path: String, ancestorHidden: Bool) {
            for (index, child) in parent.subviews.enumerated() {
                let childPath = path + "." + String(index)
                if let glass = child as? NSGlassEffectView {
                    let identity = known[ObjectIdentifier(glass)]
                    let group = identity?.1
                    let excluded = (identity?.0.hasPrefix("item.") ?? false) && (group.map { topologyPeekExclusions.contains($0) } ?? false)
                    let logical = identity?.2
                    let visibility=Self.glassVisibility(glass)
                    nodes.append(["id": identity?.0 ?? ("unidentified" + childPath), "path": childPath,
                        "groupID": group as Any? ?? NSNull(), "frame": DockFrameLog.rect(glass.frame),
                        "contentFrame": DockFrameLog.rect(glass.convert(glass.bounds, to: content)),
                        "windowFrame": DockFrameLog.rect(glass.convert(glass.bounds, to: nil)),
                        "logical": identity?.2.map { DockFrameLog.rect($0) as Any } ?? NSNull(),
                        "isHidden": glass.isHidden, "ancestorHidden": ancestorHidden,
                        "layerHidden": glass.layer?.isHidden ?? false, "alphaValue": glass.alphaValue,
                        "effectiveAlpha":visibility.alpha,"effectiveHidden":visibility.hidden,
                        "alphaPresentationSampled":visibility.presentation,"alphaChain":visibility.chain,
                        "topologyPeekExcluded": excluded,
                        "topologyEligible": !glass.isHidden && glass.layer?.isHidden != true && glass.superview === content && (logical?.width ?? 0) > 0 && (logical?.height ?? 0) > 0 && !excluded])
                }
                visit(child, path: childPath, ancestorHidden: ancestorHidden || child.isHidden)
            }
        }
        visit(content, path: "content", ancestorHidden: content.isHidden || container.isHidden)
        log.sink.write(["type":"dockFrame","dockID":log.id,"targetTimestamp":target,"motionNow":motionNow(),
            "elapsed":elapsed.isFinite ? elapsed as Any : NSNull(),"snapshotBeganMediaTime":snapshotBegan,"hasWindow":content.window != nil,
            "containerFrame":DockFrameLog.rect(container.frame),"containerSpacing":container.spacing,
            "focused":base.focused,"capsuleOwnerID":capsuleOwnerID as Any? ?? NSNull(),
            "sceneBegan":sceneBegan as Any? ?? NSNull(),"capsuleBegan":capsuleBegan,"meBegan":meBegan,
            "identityBegans":items.mapValues { $0.identityBegan },"batchID":batchID,"epochSourceBatchID":epochSourceBatchID,"writes":writeTrace,
            "epochEnabled":Self.sharedEpochEnabled,"batchWriteEnabled":Self.batchWriteEnabled,"safeMarginEnabled":DockGlassTopology.safeMarginEnabled,"transitionUntil":glassTransitionUntil,
            "inTransition":motionNow()<glassTransitionUntil,"transitionBegan":log.transitionBegan,
            "transitionSerial":log.transitionCount,"firstFrameAfterTransition":log.lastLoggedTransition != log.transitionCount,
            "fromFocused":log.fromFocused,"toFocused":log.toFocused,"reversed":log.reversed,
            "heldID":held?.id as Any? ?? NSNull(),"meHeld":meHeld != nil,
            "sameFrameViewRetention":glassRetargetTime == motionNow(),
            "rawExposed":rawExposed.mapValues { DockFrameLog.rect($0.painted) },
            "rawMotion":rawExposed.mapValues { ["time":$0.time,"logical":DockFrameLog.rect($0.rect),"earlier":DockFrameLog.rect($0.earlier),
                "gate":$0.exposure.gate,"length":$0.exposure.length,"stepMM":$0.stepMM,"mmPerPoint":$0.mmPerPoint] as [String:Any] },"glass":nodes,"topologyPasses":glassTopology.frameLogPasses])
        log.lastLoggedTransition = log.transitionCount
    }

    /// The same world-space bob basis is used when sampling and rebasing a held preview.
    private func heldBob(role:Role,slot:Int,at now:Double)->(position:CGFloat,velocity:CGFloat) {
        guard let h=held else {return (0,0)}
        let i=(role == .bar ? 0:10)+slot,dt=max(0,now-h.began)
        let period=0.62+0.09*Double(i%4),reach=1.4+0.3*Double(i%3),omega=2*Double.pi/period
        let ramp=min(1,dt/0.2),rampVelocity=dt<0.2 ? 5.0:0
        return (CGFloat(reach*sin(omega*dt)*ramp),CGFloat(reach*(omega*cos(omega*dt)*ramp+sin(omega*dt)*rampVelocity)))
    }

    /// Driver A: one frame of every node, `t` seconds into the transition, with hover on top.
    func sample(_ elapsed: Double) {
        synchronizeInjectedClock(at:motionNow())
        let ownsBatch = beginGlassBatch()
        defer { endGlassBatch(ownsBatch) }
        let sceneTime = Self.sharedEpochEnabled && elapsed.isFinite ? sceneBegan.map { motionNow()-$0 } ?? elapsed : elapsed
        let t=tideAddLayout.map{Motion.reduce ? Double.infinity:max(0,motionNow()-$0.began)} ?? sceneTime
        sampledElapsed = t
        let now = motionNow()
        if let d = draftBar { placeDraft(d.rect.offsetBy(dx: 0, dy: -rise)) }
        for item in items.values where !carries(item.conversation.id) || held?.identity == true {
            if item.face.duration > 0 { item.decoration.setOpacity(item.faceOpacity(at: now)) }
            // While one is held the others bob a little, each on its own period (NativeDockScene.swift:1230-1241).
            let bob = heldBob(role:item.role,slot:item.slot,at:now).position
            var r = item.spring.sample(t).rect
            if let handoff=tideAddTails[item.conversation.id],let size=handoff.size {
                let delayed=Motion.reduce ? Double.infinity:max(0,now-handoff.began-0.07)
                let shape=size.sample(delayed).rect,centerY=r.midY
                r.size=shape.size;r.origin.y=centerY-shape.height/2
            }
            if item.role == .orb, item.slot < orbDeltas.count {
                let d = orbDeltas[item.slot]
                r = CGRect(x: r.minX + d.minX, y: r.minY + d.minY, width: r.width + d.width, height: r.height + d.height)
            } else if item.role == .bar {
                r = r.offsetBy(dx: 0, dy: -rise)
            }
            // Appearing (bloom): an orb buds from the nearest bar's end, a bar settles from 1.06 ×.
            if let b = blooms[item.conversation.id] {
                r = r.adding(now < b.release ? b.delta.sample(0).rect : b.delta.sample(now - b.release).rect)
                if now - b.release >= b.delta.duration { blooms[item.conversation.id] = nil }
            }
            if item.role == .bar, let bb = barBloom {
                let k = CGFloat(bb.spring.sample(now - bb.began).value)
                r = CGRect(x: r.midX - r.width * k / 2, y: r.midY - r.height * k / 2, width: r.width * k, height: r.height * k)
            }
            if item.role == .bar { r = r.offsetBy(dx: refusal(at: now), dy: 0) }
            item.regular = r
            if tideSides[item.conversation.id]?.pose.shown == true {continue}
            updateBudBasis(item,regular:r,at:now)
            if item.veil.duration > 0 { item.decoration.setVeil(item.veilAmount(at: now)) }
            if let bud = buds[item.conversation.id] {
                let delta=bud.delta.sample(now-bud.began).rect
                let budded=bud.physicalTakeover ? (bud.anchor ?? r).addingSignedComponents(delta):r.adding(delta)
                place(item, budded, orb: CGRect(x: r.minX - budded.minX, y: r.minY - budded.minY, width: r.width, height: r.height))
                if !bud.open, now - bud.began >= bud.delta.duration { endBud(item.conversation.id) }
                continue
            }
            place(item, r.offsetBy(dx: 0, dy: bob))
        }
        updateFocusedGlass()
        if held == nil && meHeld == nil { reconcileGlassTopology() }
    }

    private func place(_ item: Item, _ r: CGRect, orb: CGRect? = nil) {
        if ModeDepartureSurfaces.retains(item.glass) {return}
        let now = motionNow(), profile = exposureProfile
        item.wordGaussian.settle(at: now); item.peekGaussian.settle(at: now)
        item.decoration.settleGlyphGaussian(at: now)
        let semanticGaussian = usesGaussian && !carries(item.conversation.id) && now < item.semanticZoomUntil
        let f = item.motion.update(r, at: now, name: "dock." + (item.role == .bar ? "bar." : "orb.") + item.conversation.id,
                                   profile: profile, enabled: usesExposure)
        // Add keeps Tide's real contour until its finite handoff completes. Host exposure remains content-only.
        let painted = tideAddTails[item.conversation.id] != nil ? r:f.painted
        if frameLog != nil { rawExposed[f.name] = f }
        let diameter = min(r.width, r.height)
        let body = (orb ?? CGRect(x: 0, y: 0, width: diameter, height: diameter)).offsetBy(dx: r.minX, dy: r.minY)
        let bodyFrame = item.orbMotion.update(body, at: now, name: "dock.planet." + item.conversation.id, profile: profile, enabled: usesExposure)
        writeGlass(item.glass,frame:painted)
        item.shape(painted, orb: bodyFrame.painted.offsetBy(dx: -painted.minX, dy: -painted.minY))
        // Native controls retain their original world frame and target layout; glass alone reaches backwards.
        let shift = CGPoint(x: r.minX-painted.minX, y: r.minY-painted.minY)
        if let exit = item.chromeExit, now-exit.began >= 0.12 { item.chromeExit = nil }
        let chrome = item.chromeExit?.rect ?? painted
        let chromeShift = item.chromeExit == nil ? shift : CGPoint.zero
        item.chromeHost.frame = chrome
        item.chromeHost.layer?.cornerRadius = min(chrome.width, chrome.height) / 2
        item.barFace.setFrameOrigin(chromeShift); item.peekFace.setFrameOrigin(shift)
        item.ownComposer?.sampleSegmentTransition(at: now)
        item.chromeHost.alphaValue = CGFloat(item.controlsOpacity.value(at: now))
        // A header pickup carries this item's glass, even while its resting segment shares the capsule.
        let headerPaint=carriesHeader(item.conversation.id)
        let mix:Float = headerPaint ? 0:item.segmentMix.value(at: now)
        let identityAlpha:Float = headerPaint ? 0:item.identityOpacity.value(at:now)
        writeGlass(item.glass,alpha:CGFloat((1-mix)*(1-identityAlpha)))
        item.decoration.setOpacity(item.faceOpacity(at:now)*(1-identityAlpha))
        if identityAlpha >= 1 { item.decoration.setPresentationActive(false) }
        item.selection.fillColor = NativePalette.accent.withAlphaComponent(0.08).cgColor
        item.selection.path = CGPath(roundedRect: CGRect(origin: chromeShift, size: item.chromeExit == nil ? r.size : chrome.size), cornerWidth: chrome.height / 2, cornerHeight: chrome.height / 2, transform: nil)
        // Selection is outside the controls' opacity group.
        item.selection.opacity = item.emphasis.value(at: now) / max(0.01, Float(item.chromeHost.alphaValue))
        placeIdentity(item, at: now)
        let words = item.label.convert(item.label.bounds, to: view)
        let wf = item.wordMotion.update(words, at: now, name: "dock.words." + item.conversation.id, profile: profile, enabled: usesExposure)
        item.wordTrail.update(item.label, in: item.chromeHost, world: words, earlier: wf.earlier, profile: profile,
                              enabled: usesExposure && !semanticGaussian, opacity: item.barFace.layer?.presentation()?.opacity ?? Float(item.barFace.alphaValue))
        let pendingShift = collectingGlass ? CGPoint(x:painted.minX-item.glass.frame.minX,y:painted.minY-item.glass.frame.minY) : .zero
        let peekWorld = item.peekFace.convert(item.peekFace.bounds, to: view).offsetBy(dx:pendingShift.x,dy:pendingShift.y)
        let pf = item.peekWordMotion.update(peekWorld, at: now, name: "dock.peek.words."+item.conversation.id, profile: profile, enabled: usesExposure)
        item.peekTrail.update(item.peekFace, in: item.content, world: peekWorld, earlier: pf.earlier, profile: profile,
                              enabled: usesExposure && !semanticGaussian, hideSource: false)
        item.peekFace.glyphExposureActive = item.peekTrail.isActive
        if let badge = item.peekFace.badgeRect {
            let world = item.peekFace.convert(badge, to: view).offsetBy(dx:pendingShift.x,dy:pendingShift.y)
            let previous = world.offsetBy(dx: pf.earlier.minX-peekWorld.minX, dy: pf.earlier.minY-peekWorld.minY)
            let bf = M10DockMotion.frame(name: "dock.peek.badge", now: world, earlier: previous, time: now, profile: profile, enabled: usesExposure)
            item.peekFace.motionBadgeRect = bf.exposure.gate > 0 ? bf.painted.offsetBy(dx: -peekWorld.minX, dy: -peekWorld.minY):nil
            onMotionFrame?(bf)
        }
        onMotionFrame?(pf)
        if semanticGaussian { item.decoration.exposeGlyphs(now: bodyFrame.rect, earlier: bodyFrame.rect, profile: profile, enabled: false) }
        else { M10DockMotion.onOrbFrame?(item.decoration, bodyFrame, profile) }
        if let composer = item.ownComposer {
            onComposerMotion?(composer, f, profile)
        }
        onMotionFrame?(f); onMotionFrame?(wf)
        // The grip shows on a bar at rest in its role (not while held, nor while it changes shape into an orb). Focused /
        // Split segments have none (FocusedSegmentControls, unlike FullBar, carries no dockGrip).
        let shows = item.role == .bar && !carries(item.conversation.id) && r.height > 30
        let g = item.conversation.id == gripHover ? CGSize(width: 44, height: 6) : CGSize(width: 34, height: 5)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        item.grip.isHidden = !shows
        item.grip.opacity = 1 - mix
        item.grip.frame = CGRect(x: r.midX - g.width / 2, y: r.minY - g.height / 2, width: g.width, height: g.height)
        item.grip.path = CGPath(roundedRect: CGRect(origin: .zero, size: g), cornerWidth: g.height / 2, cornerHeight: g.height / 2, transform: nil)
        item.grip.fillColor = NSColor(white: 1, alpha: item.conversation.id == gripHover ? 0.55 : 0.28).cgColor
        CATransaction.commit()
    }

    // MARK: Peek (f045–f046; OrganicDockProjection, role .peek)

    private func localFrame(_ world:CGRect,role:Role,slot:Int,at now:Double)->CGRect {
        if role == .bar {return world.offsetBy(dx:-refusal(at:now),dy:rise)}
        guard orbDeltas.indices.contains(slot) else {return world}
        let d=orbDeltas[slot]
        return CGRect(x:world.minX-d.minX,y:world.minY-d.minY,width:world.width-d.width,height:world.height-d.height)
    }
    private func regularVelocity(_ item:Item)->CGRect {
        let pose=glassObservations[ObjectIdentifier(item.glass)]
        if pose?.time == item.motion.observationTime,let velocity=pose?.regularVelocity {return velocity}
        return item.spring.sample(sampledElapsed ?? 0).velocity
    }
    /// A world anchor is valid only for the physical release it replaced.
    private func updateBudBasis(_ item:Item,regular:CGRect,at now:Double,force:Bool=false) {
        let id=item.conversation.id
        guard var bud=buds[id],bud.physicalTakeover else {return}
        var pose=bud.delta.sample(now-bud.began)
        var changed=false
        if let anchor=bud.anchor,force || now >= (bud.anchorUntil ?? 0) {
            pose.rect=anchor.addingSignedComponents(pose.rect).subtractingSignedComponents(regular)
            pose.velocity=pose.velocity.subtractingSignedComponents(regularVelocity(item))
            bud.anchor=nil;bud.anchorUntil=nil;changed=true
        }
        if bud.anchor == nil {
            let target=bud.open ? (bud.capsuleGoal?.subtractingSignedComponents(regular) ?? bud.delta.target):.zero
            if changed || target != bud.delta.target {
                bud.delta=RectSpring(peekDeltaFrom:pose.rect,to:target,velocity:pose.velocity,
                    response:bud.delta.x.response,damping:bud.delta.x.damping)
                bud.began=now;buds[id]=bud
                onNeedsFramesUntil?(bud.began+bud.delta.duration)
            }
        }
    }
    private func endAnchoredPeeks(at now:Double,force:Bool=false) {
        for (id,bud) in buds where bud.anchor != nil {
            if let item=items[id] {updateBudBasis(item,regular:item.regular,at:now,force:force)}
        }
    }

    /// A peek's bud: what it adds to its orb's frame, springing out to the capsule and back (open 0.38 / 0.78, closing
    /// 0.30 / 0.90), and the satellites' row under the capsule (centre-relative, drawing units).
    private struct Bud {
        var delta: RectSpring, began: Double, open: Bool
        var follow: [String: CGPoint]?
        var physicalTakeover = false
        var anchor: CGRect? = nil
        var anchorUntil: Double? = nil
        var capsuleGoal: CGRect? = nil
    }
    private var buds: [String: Bud] = [:]
    /// The conversation a peek shows (product shownPeek), while it does.
    private(set) var peekShown: String?
    var hasPeek: Bool { !buds.isEmpty || peekShown != nil }
    /// When the last bud comes to rest (media time).
    var peekSettles: Double { buds.values.map { $0.began + $0.delta.duration }.max() ?? 0 }

    /// Projects a peek: `shown`'s orb buds out into `capsule` while `open` (else back into its slot); any other bud goes
    /// back. `rows` are the satellites' x in the row under the capsule, `rowY` its centre (OrganicDockBridge.peekRow).
    func projectPeek(shown: String?, open: Bool, capsule: CGRect, rows: [String: CGFloat], rowY: CGFloat) {
        let now = motionNow()
        endAnchoredPeeks(at:now)
        let spring = open ? (response: 0.38, damping: 0.78) : (response: 0.30, damping: 0.90)
        let opening=open && shown != nil && (shown != peekShown || shown.flatMap{buds[$0]?.open} != true)
        let contours=opening ? captureContours():[]
        peekShown = shown
        var ids = Set(buds.keys)
        if let shown { ids.insert(shown) }
        var reconfigure = false
        for id in ids {
            guard let item = items[id], item.role == .orb, !carries(id) else { if buds[id] != nil { endBud(id) }; continue }
            let want = id == shown && open
            let r = item.regular == .zero ? item.glass.frame : item.regular
            var current = buds[id].map { $0.delta.sample(now - $0.began) } ?? (rect: .zero, velocity: .zero)
            let key=ObjectIdentifier(item.glass)
            let release=glassReleases.removeValue(forKey:key)
            let takeover=release != nil
            let signed=takeover || buds[id]?.physicalTakeover == true
            let until=release.map{$0.began+$0.spring.duration} ?? buds[id]?.anchorUntil
            let anchor=want && (until ?? 0)>now ? (buds[id]?.anchor ?? r):nil
            let reference=anchor ?? r
            let target=want ? capsule.subtractingSignedComponents(reference):.zero
            let pose=glassObservations[key]
            let regularVelocity=self.regularVelocity(item)
            if let oldAnchor=buds[id]?.anchor {
                current.rect=oldAnchor.addingSignedComponents(current.rect).subtractingSignedComponents(reference)
                if anchor == nil {current.velocity=current.velocity.subtractingSignedComponents(regularVelocity)}
            } else if anchor != nil {current.velocity=current.velocity.addingSignedComponents(regularVelocity)}
            if takeover {
                // Open Peek has a fixed world destination; closing rejoins the moving orb.
                current=(item.glass.frame.subtractingSignedComponents(reference),
                    (pose?.velocity ?? .zero).subtractingSignedComponents(anchor == nil ? regularVelocity:.zero))
                item.motion.reset(item.glass.frame)
            }
            if takeover || buds[id] == nil || buds[id]!.delta.target != target || buds[id]!.anchor != anchor {
                let delta=signed ? RectSpring(peekDeltaFrom:current.rect,to:target,velocity:current.velocity,
                    response:spring.response,damping:spring.damping):RectSpring(from:current.rect,to:target,velocity:current.velocity,
                    response:spring.response,damping:spring.damping)
                buds[id] = Bud(delta:delta,began:now,open:buds[id]?.open ?? false,follow:buds[id]?.follow,physicalTakeover:signed,anchor:anchor,anchorUntil:anchor == nil ? nil:until,capsuleGoal:signed && want ? capsule:nil)
                if usesGaussian {item.semanticZoomUntil=now+buds[id]!.delta.duration}
            }
            // What the orb shows changes only when it opens or closes (a retarget keeps it).
            guard buds[id]!.open != want else { continue }
            buds[id]!.open = want
            reconfigure = true
            veil(item, to: want ? 1 : 0, now: now)
            if want {
                // The orb's planet stays where it is under its veil; its satellites go to the row, relative to its centre.
                let k = max(metrics.orb, metrics.orbMagnified, 1) / max(1, r.width)
                buds[id]!.follow = Dictionary(uniqueKeysWithValues: item.conversation.satellites.map { s in
                    let x = rows[s.id] ?? r.midX
                    return (s.id, CGPoint(x: (x - r.midX) * k, y: (rows[s.id] == nil ? 0 : rowY - r.midY) * k))
                })
                item.glass.tintColor = Look.peekTint
                item.peekFace.configure(item.conversation, badge: makeOrbConfiguration(item.conversation, drawingSize: 1, backingScale: 1,
                                        reduceMotion: false, ambient: false, isKeyWindow: true).badge, size: capsule.size)
                item.peekTrail.prepare(item.peekFace, key: "\(item.conversation.title)|\(item.peekFace.bounds)|\(String(describing: item.conversation.state))", scale: view.window?.backingScaleFactor ?? 2) {
                    item.peekFace.glyphBitmap(scale: self.view.window?.backingScaleFactor ?? 2)
                }
                item.peekWordMotion.reset()
            } else {
                buds[id]!.follow = nil
                fadeFace(item, visible: false, duration: 0.07)
            }
        }
        if reconfigure { refreshOrbs() }
        if opening,let shown,let bud=buds[shown] {queueContours(contours,tuning:bud.delta,stableRaw:false)}
    }

    /// The shown peek's titled face in (0.12 s, 100 ms after it opens) or out (0.07 s); 3 pt out of focus while hidden.
    func peekContent(visible: Bool, duration: Double) {
        guard let id = peekShown, let item = items[id] else { return }
        fadeFace(item, visible: visible, duration: duration)
    }

    private func fadeFace(_ item: Item, visible: Bool, duration: Double) {
        guard let layer = item.peekFace.layer else { return }
        if usesGaussian {
            item.peekTrail.reset()
            layer.removeAnimation(forKey: "overlay.opacity")
            item.peekFace.alphaValue = 1
            item.peekGaussian.show(visible, content: layer, at: motionNow(), initiallyVisible: !visible)
            item.peekFace.alphaValue=visible ? 1:0
            return
        }
        let curve = OverlayCurve(0, 0, 0.58, 1, duration)
        item.peekFace.alphaValue = visible ? 1 : 0
        OverlayMotion.animate(layer, "opacity", from: layer.opacity, to: Float(visible ? 1 : 0), curve: curve)
        PeekNode.installBlur(on: layer)
        if layer.filters?.isEmpty == false {
            OverlayMotion.animate(layer, "filters.peekBlur.inputRadius", from: visible ? 3 : 0, to: visible ? 0 : 3, curve: curve)
            PeekNode.installBlur(on: item.peekTrail.trail.layer)
            OverlayMotion.animate(item.peekTrail.trail.layer, "filters.peekBlur.inputRadius", from: visible ? 3 : 0, to: visible ? 0 : 3, curve: curve)
        }
    }

    private func veil(_ item: Item, to v: Float, now: Double) {
        item.veil = (item.veilAmount(at: now), v, now, 0.12)
    }

    /// A bud is over: back in its slot, or taken over by a transition or a drag.
    private func endBud(_ id: String) {
        buds[id] = nil
        guard let item = items[id] else { return }
        let now = motionNow()
        if item.veilAmount(at: now) > 0 || item.veil.to > 0 { veil(item, to: 0, now: now) }
        if (item.peekFace.layer?.opacity ?? 0) > 0 { fadeFace(item, visible: false, duration: 0.07) }
        item.glass.tintColor = glassTint
        refreshOrbs()
    }

    /// The peek glass's frame while it is open, for its float shadow.
    var peekCapsuleFrame: CGRect? { peekShown.flatMap { id in buds[id]?.open == true ? items[id]?.glass.frame : nil } }

    /// The node whose hover region is under `p` (NativeDockScene hit frames): an orb, 44 × 44 at least, or an open peek's
    /// whole capsule, as an orb; a bar by its grip.
    func hoverNode(at p: CGPoint) -> (id: String, orb: Bool)? {
        if sunHoverBlocksPointer?(p) == true { return nil }
        for item in items.values where !carries(item.conversation.id) {
            if item.identityOpacity.to > 0, item.identityFrame.insetBy(dx:-4,dy:-4).contains(p) { return (item.conversation.id, true) }
            let f = item.glass.frame
            switch item.role {
            case .orb:
                let hit = buds[item.conversation.id]?.open == true ? f : f.insetBy(dx: min(0, (f.width - 44) / 2), dy: min(0, (f.height - 44) / 2))
                if hit.contains(p) { return (item.conversation.id, true) }
            case .bar:
                if base.focused { continue }
                if CGRect(x: f.midX - 32, y: f.minY - 8, width: 64, height: 16).contains(p) { return (item.conversation.id, false) }
            }
        }
        return nil
    }

    /// An orb's frame on screen now (peekOrigin).
    /// An orb budded into a Peek's capsule counts as the orb: a mode switch made a flying orb of the whole capsule, 300 pt
    /// across (board 10-31).
    func frame(of id: String) -> CGRect? {
        guard let item = items[id] else { return nil }
        if tidePresentedOwner==id,let rect=tideNodePoses[id] {
            let d=min(rect.width,rect.height)
            return CGRect(x:rect.minX,y:rect.midY-d/2,width:d,height:d)
        }
        return buds[id] != nil && item.regular != .zero ? item.regular : item.glass.frame
    }

    // MARK: Glass (Settings ▸ Appearance ▸ Glass; NativeAppearance.Change)

    /// Clear or regular, and a custom theme's canvas tint (0.20 clear, 0.55 tinted; nil for Canopy: NativeDockScene).
    private(set) var glassClear = NativeAppearance.current.clearGlass
    private(set) var glassTint: NSColor? = NativeAppearance.current.background.map { $0.withAlphaComponent(NativeAppearance.current.clearGlass ? 0.20 : 0.55) }
    func setGlass(clear: Bool, tint: NSColor?) {
        glassClear = clear; glassTint = tint
        for (id, item) in items { dressGlass(item.glass, keepTint: buds[id] != nil) }
        if let me { dressGlass(me) }; dressGlass(focusedGlass)
        for item in items.values { if let identity = item.identity { dressGlass(identity.glassView) } }
        if let bar = draftBar?.glass { dressGlass(bar) }
    }
    private func dressGlass(_ g: NSGlassEffectView, keepTint: Bool = false) {
        g.style = glassClear ? .clear : .regular
        if !keepTint { g.tintColor = glassTint }
    }

    // MARK: Holding a node (queue drag, reference §E 拖拽)

    /// The node under the pointer while it is dragged: its centre is the pointer's (y follows 0.4 of it, around the
    /// dock's row), only its shape springs, to an orb (NativeDockScene positionDragged).
    private var held: (id: String, center: CGPoint, shape: RectSpring, began: Double, identity:Bool, row:CGFloat?)?
    private weak var carriedHeader:HeaderIsland?
    private struct DockLanding {weak var header:HeaderIsland?;var until:Double}
    private var dockLandings:[String:DockLanding]=[:]
    private var carriedID:String?
    private struct Return {
        weak var header:HeaderIsland?
        let delta:RectSpring
        var began:Double
        let goalSize:CGSize
        var full:Bool
    }
    private var returns:[String:Return]=[:]
    private func carries(_ id:String)->Bool {held?.id == id || returns[id] != nil}
    private func carriesHeader(_ id:String)->Bool {carriedID == id || returns[id] != nil}
    func hasHeaderReturn(_ id:String)->Bool {returns[id] != nil}
    var headerCarryOrigin:CGPoint? { carriedHeader.map { h in let r=view.convert(h.draggableOrbRect,from:h);return CGPoint(x:r.midX,y:r.midY) } }
    private func headerRect()->CGRect? {carriedHeader.map{view.convert($0.draggableOrbRect,from:$0)}}
    private var releasedIdentity: (id:String,planet:CGRect,bar:CGRect)?
    /// The bar whose grip is under the pointer.
    private(set) var gripHover: String?

    static let meID = "organic.me"

    /// What a press at `p` can pick up: me, an orb (at least 44 × 44 to hit), or a bar by its grip (64 × 16 on its top).
    func draggable(at p: CGPoint) -> String? {
        if let me, me.frame.insetBy(dx: min(0, (me.frame.width - 48) / 2), dy: min(0, (me.frame.height - 48) / 2)).contains(p) { return Self.meID }
        for item in items.values {
            if item.identityOpacity.to > 0, item.identityFrame.insetBy(dx:-4,dy:-4).contains(p) { return item.conversation.id }
            let f = item.glass.frame
            if item.role == .orb, f.insetBy(dx: min(0, (f.width - 44) / 2), dy: min(0, (f.height - 44) / 2)).contains(p) { return item.conversation.id }
            if item.role == .bar, !base.focused, CGRect(x: f.midX - 32, y: f.minY - 8, width: 64, height: 16).contains(p) { return item.conversation.id }
        }
        return nil
    }

    func hoverGrip(_ p: CGPoint?) {
        let id = p.flatMap { p in items.values.first { $0.role == .bar && !base.focused && CGRect(x: $0.glass.frame.midX - 32, y: $0.glass.frame.minY - 8, width: 64, height: 16).contains(p) }?.conversation.id }
        guard id != gripHover else { return }
        let ownsBatch=beginGlassBatch();defer {endGlassBatch(ownsBatch)}
        gripHover = id
        for item in items.values { place(item, item.motion.rect ?? item.glass.frame) }
        reconcileGlassTopology()
    }

    func hold(_ id: String, at p: CGPoint, now: Double, spring: (response: Double, damping: Double), header:HeaderIsland? = nil, originRow:CGFloat? = nil,pickupOverride:CGRect? = nil,conversationOrb:Bool=false) {
        releasedGlassID=nil;freeCarry=nil
        let pickupContours=captureContours()
        // Ownership changes inherit the contour already submitted to AppKit, including neighbours.
        observingPickup=true;observeAllGlass(at:now);observingPickup=false
        glassTopology.begin(at: motionNow()); glassTransitionUntil = 0
        guard let item = items[id] else { return }
        if !base.focused && capsuleOwnerID == id { withdrawFocusedGlass() }
        let regrabbing=returns.removeValue(forKey:id)
        dockLandings.removeValue(forKey:id)?.header?.setOrbCarried(false)
        carriedHeader=header;carriedID=header == nil ? nil:id
        let pickup=regrabbing == nil ? header.map{view.convert($0.draggableOrbRect,from:$0)}:(item.motion.rect ?? item.glass.frame)
        header?.setOrbCarried(true)
        if header != nil {
            item.motion.reset();item.orbMotion.reset();item.wordMotion.reset();item.peekWordMotion.reset()
            item.wordTrail.reset();item.peekTrail.reset()
            // The outgoing bar controls finish their existing fade on the Dock row, not at the header.
            item.chromeExit=(item.chromeHost.frame,now)
        }
        // A grab is translation from this frame onward; semantic zoom must never suppress drag exposure.
        item.semanticZoomUntil=0;item.wordGaussian.reset();item.label.layer?.opacity=Float(item.label.alphaValue)
        item.decoration.resetGlyphGaussian()
        item.decoration.preparePointerInk();item.identity?.preparePointerInk()
        if let composer=item.ownComposer {composerMotion.cancelGaussian(composer)}
        if buds[id] != nil { endBud(id) }
        let identity = header == nil && base.focused && item.role == .bar && item.slot > 0 && item.identityOpacity.to > 0
        let carriedGlass=identity ? item.identity?.glassView:item.glass
        let nativePickup=pickupOverride ?? carriedGlass?.frame
        if header == nil,let nativePickup {
            // The new zero-velocity pickup shape already contains the last shutter contour.
            // Reusing the old raw history would expose the topology correction a second time.
            if identity {item.identityMotion.reset(nativePickup)} else {item.motion.reset(nativePickup)}
        }
        if let carriedGlass {
            glassReleases[ObjectIdentifier(carriedGlass)]=nil;contourHandoffs[ObjectIdentifier(carriedGlass)]=nil
            for handoff in contourHandoffs.values where handoff.arrival === carriedGlass {handoff.arrival=nil}
        }
        let d = max(metrics.orb, metrics.orbMagnified), r = pickup ?? nativePickup ?? (identity ? item.identityFrame : item.motion.rect ?? item.glass.frame)
        let shape = RectSpring(from: CGRect(origin: .zero, size: r.size), to: CGRect(x: 0, y: 0, width: d, height: d), velocity: .zero,
                               response: spring.response, damping: spring.damping)
        let heldRow = header == nil && pickupOverride == nil ? nil:originRow ?? p.y
        held = (id, conversationOrb ? CGPoint(x:r.midX,y:r.midY):follow(p,row:heldRow), shape, now, identity, heldRow)
        // Rebase the local contour bridge when pickup changes locking, including an unfinished Peek bridge.
        // Pointer motion after this ownership handoff remains free to join and separate again.
        queueContours(pickupContours.filter{$0.0 !== carriedGlass},tuning:shape,stableRaw:true)
        if identity {
            queueContours([(item.glass,item.glass.frame,item.motion.rect)],tuning:item.spring,stableRaw:true)
            observeAllGlass(at:now)
            item.identity?.setPresentationActive(true); return
        }
        // Picked up, it is its orb: planet and badge in, the bar's words and composer out (the editor stays in the window).
        item.decoration.setPresentationActive(true)
        item.face = header == nil ? (item.faceOpacity(at: motionNow()), 1, motionNow(), 0.12):(1,1,now,0)
        fade(item.barFace, to: 0, delay: 0, duration: 0.10)
        if let composer = item.ownComposer, item.full { fade(composer, to: 0, delay: 0, duration: 0.10) }
        item.role = .orb; item.full = false
        if header != nil || pickupOverride != nil {heldFrame(at:now)}
    }

    func moveHeld(to p: CGPoint) {
        if freeCarry != nil {
            let t=motionNow(),q=CGPoint(x:p.x-freeCarry!.grab.x,y:p.y-freeCarry!.grab.y)
            freeCarry!.x.aim(q.x,at:t,tuning:OrbTrashParameters.follow);freeCarry!.y.aim(q.y,at:t,tuning:OrbTrashParameters.follow)
        } else if held != nil { held!.center = follow(p,row:held!.row) }
    }

    /// Lets go: the next transition springs the node from where the pointer left it to its slot.
    func release(toHeader:Bool = false, forTear:Bool = false) {
        if freeCarry != nil { heldFrame(at:motionNow());freeCarry=nil }
        if !toHeader,!forTear,let held {
            // The physical release inherits native geometry; changing locks must not project it twice.
            queueContours(captureContours(),tuning:held.shape,stableRaw:false)
        }
        if forTear {tearingGlassID=held?.id}
        if toHeader, let h=held,let item=items[h.id],let target=headerRect() {
            let r=item.motion.rect ?? item.glass.frame
            returns[h.id]=Return(header:carriedHeader,delta:RectSpring(from:r.offsetBy(dx:-target.minX,dy:-target.minY),to:CGRect(origin:.zero,size:target.size),response:h.shape.x.response,damping:h.shape.x.damping),began:motionNow(),goalSize:target.size,full:false)
            carriedHeader=nil;carriedID=nil
            held=nil
            return
        }
        if let held, held.identity, let item = items[held.id] {
            releasedGlassID=held.id
            releasedIdentity = (held.id,item.identityFrame,item.motion.rect ?? item.glass.frame)
        } else if let held, let item = items[held.id] {
            releasedGlassID=held.id
            releasedNode = (held.id, item.motion.rect ?? item.glass.frame)
            if carriedID == held.id,item.identity != nil {
                // If this header lands as a side orb, the existing Dock identity starts at the carried pose.
                item.identitySpring = .rest((item.motion.rect ?? item.glass.frame).offsetBy(dx:0,dy:rise))
                item.identityBegan=motionNow();item.identityMotion.reset()
            }
        }
        held = nil
        if !forTear {
            if let id=carriedID {dockLandings[id]=DockLanding(header:carriedHeader,until:motionNow()+0.6)}
            carriedHeader=nil;carriedID=nil
        }
    }
    func endHeaderTear(kept:Bool) {
        if kept,let id=tearingGlassID,let item=items[id] {
            queueContours(captureContours(excluding:item.glass),tuning:item.spring,stableRaw:true,arrival:item.glass)
        }
        tearingGlassID=nil
        // The panel has reached this header; hand the same paint back without a trip through the Dock.
        if kept,let id=carriedID,let r=headerRect(),let item=items[id] {
            place(item,r);releasedNode=nil
            returns[id]=Return(header:carriedHeader,delta:RectSpring(from:CGRect(origin:.zero,size:r.size),to:CGRect(origin:.zero,size:r.size),response:AutoScene.queueSpring.response,damping:AutoScene.queueSpring.damping),began:motionNow(),goalSize:r.size,full:false)
            carriedHeader=nil;carriedID=nil
        } else {carriedHeader?.setOrbCarried(false);carriedHeader=nil;carriedID=nil}
    }
    private func finishHeaderReturn(_ id:String) {
        guard let back=returns.removeValue(forKey:id),let item=items[id] else {return}
        back.header?.setOrbCarried(false)
        item.role = .bar;item.full=back.full;item.spring = .rest(item.target)
        arrange(item,for:item.target,full:back.full,leading:leading((.bar,item.target,item.slot)),segment:segment((.bar,item.target,item.slot)))
        item.face=(0,0,0,0);item.decoration.setOpacity(0)
        item.motion.reset();item.orbMotion.reset();item.wordMotion.reset();item.wordTrail.reset()
        place(item,item.target.offsetBy(dx:0,dy:-rise))
        // The structural bar reappears in its Dock slot; the carried paint has landed in the header.
        item.glass.alphaValue=0;fade(item.glass,to:1,delay:0,duration:0.16)
        item.barFace.alphaValue=0;fade(item.barFace,to:1,delay:0,duration:0.16)
        if let composer=item.ownComposer {composer.alphaValue=back.full ? 1:0}
    }

    private var releasedNode: (id: String, rect: CGRect)?
    var isHolding: Bool { held != nil }

    /// Trash shares the current native write batch and its outer transaction.
    func withTrashGlassBatch(_ body:()->Void) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        let owns=beginGlassBatch();body();endGlassBatch(owns);if owns { onTrashApplied?() };CATransaction.commit()
    }
    func trashCarrier(_ id:String)->(glass:NSGlassEffectView,rect:CGRect,velocity:CGRect)? {
        guard let item=items[id] else { return nil }
        let glass=held?.id == id && held?.identity == true ? item.identity?.glassView:item.glass
        guard let glass else { return nil }
        let rect=glassFrame(glass),observation=glassObservations[ObjectIdentifier(glass)]
        var velocity=observation?.velocity ?? .zero
        if collectingGlass,let observation,motionNow()>observation.time {
            let dt=motionNow()-observation.time,r=observation.rect
            velocity=CGRect(x:(rect.minX-r.minX)/dt,y:(rect.minY-r.minY)/dt,width:(rect.width-r.width)/dt,height:(rect.height-r.height)/dt)
        }
        return (glass,rect,velocity)
    }
    func beginFreeCarry(pointer:CGPoint,grab:CGPoint) {
        guard let h=held,let p=trashCarrier(h.id) else { return }
        let t=motionNow()
        freeCarry=(OrbTrashMotion(p.rect.midX,velocity:p.velocity.minX+p.velocity.width/2,at:t),
                   OrbTrashMotion(p.rect.midY,velocity:p.velocity.minY+p.velocity.height/2,at:t),grab)
        moveHeld(to:pointer)
    }
    func setTrashOwner(_ id:String,hidden:Bool,frame:CGRect?) {
        if !hidden { trashHiddenGlass.removeAll();trashHiddenMember=nil }
        guard let item=items[id] else { return }
        if held?.id != id,item.role == .bar {
            // A restored column's structural bar is not its flying planet. Only planet ink changes owner.
            trashHiddenGlass.remove(ObjectIdentifier(item.glass));trashHiddenMember=nil
            writeGlass(item.glass,hidden:false,reason:"trashStructuralReturn")
            item.glass.layer?.isHidden=false;item.content.layer?.isHidden=false;item.barFace.layer?.isHidden=false;item.chromeHost.isHidden=false
            item.decoration.setOpacity(0);item.decoration.backView.isHidden=hidden;item.decoration.frontView.isHidden=hidden
            if let identity=item.identity {
                if hidden { trashHiddenGlass.insert(ObjectIdentifier(identity.glassView)) }
                else { trashHiddenGlass.remove(ObjectIdentifier(identity.glassView)) }
                writeGlass(identity.glassView,hidden:hidden,reason:"trashIdentityReturn")
                identity.backView.isHidden=hidden;identity.frontView.isHidden=hidden
            }
            return
        }
        let carrier=trashCarrier(id)?.glass ?? item.glass
        if hidden { trashHiddenMember=id;trashHiddenGlass.insert(ObjectIdentifier(carrier)) }
        else { trashHiddenMember=nil;trashHiddenGlass.remove(ObjectIdentifier(carrier)) }
        if let frame,glassFrame(carrier) != frame {
            if carrier === item.glass { item.motion.reset(frame) }
            writeGlass(carrier,frame:frame,hidden:hidden,reason:"trashOwner")
        } else { writeGlass(carrier,hidden:hidden,reason:"trashOwner") }
        if held?.id == id || item.role == .orb { setHiddenPaint(item,hidden) }
        if held?.id != id,returns[id] == nil { carriedHeader?.setOrbCarried(hidden) }
        if hidden,let component=item.identity,carrier === component.glassView {
            component.backView.isHidden=true;component.frontView.isHidden=true
        }
    }
    func detachTrashCarrier() {
        freeCarry=nil;held=nil;carriedHeader=nil;carriedID=nil;releasedNode=nil;releasedIdentity=nil
    }
    func trashClearance(_ id:String)->Double {
        guard let carrier=trashCarrier(id) else { return .infinity }
        let source=carrier.rect
        // Include the complete material graph: capsules, LL, borrowed bodies and every Tide tail piece.
        return content.subviews.compactMap { view -> Double? in
            guard let glass=view as? NSGlassEffectView,glass !== carrier.glass,!glassHidden(glass),glass.layer?.isHidden != true else { return nil }
            let r=glassFrame(glass);guard r.width>0,r.height>0 else { return nil }
            let x=max(0,max(source.minX-r.maxX,r.minX-source.maxX))
            let y=max(0,max(source.minY-r.maxY,r.minY-source.maxY))
            return hypot(x,y)
        }.min() ?? .infinity
    }
    func trashLeaseFacts()->(add:Set<String>,tide:DockSlotLeases.Token?,addToken:DockSlotLeases.Token?) {
        let leases=tideTimeline?.leases ?? tideLeaseMemory
        return (Set(leases.add?.briefs ?? []),leases.tide?.token,leases.add?.token)
    }
    func undoBriefPrefixes()->[[String]] {
        refreshTideProtection()
        let leases=tideTimeline?.leases ?? tideLeaseMemory,protection=tideProtection()
        let candidates=items.values.filter { $0.role == .bar }.sorted { $0.target.minX>$1.target.minX }.map {
            DockSlotLeases.Candidate(id:$0.conversation.id,role:$0.full ? .full:.brief,protection:protection[$0.conversation.id] ?? [])
        }
        return leases.undoPrefixes(candidates:candidates,at:tideNow())
    }
    func prepareTrashMembershipChange(_ affected:Set<String>,keeping:Set<String>) {
        trashReflowPending=true;trashLiveMembers=keeping
        // Rejoining does not replay the conversation's old notice journal or restart an old Tide hold.
        for id in keeping where tideCursors[id]==nil { tideCursors[id]=store?.conversation(id)?.notices.journal.last?.id ?? 0 }
        var leases=tideTimeline?.leases ?? tideLeaseMemory
        if let tide=leases.tide,affected.contains(tide.token.owner) || !affected.isDisjoint(with:tide.briefs) { _=leases.release(tide.token) }
        tideTimeline?.leases=leases;tideLeaseMemory=leases
        for id in affected where !keeping.contains(id) {
            tideSides.removeValue(forKey:id)?.dispose();tideSideQueued[id]=nil;tideCursors[id]=nil
            tidePool.removeValue(forKey:id)?.dispose();tideFaces.removeValue(forKey:id)?.dispose()
            tideBorrowHits.removeValue(forKey:id)?.removeFromSuperview();tideNodePoses[id]=nil
        }
    }
    func trashDidCommitMembers(_ ids:Set<String>) { if trashReflowPending { trashLiveMembers=ids } }
    private func reflowTrashTide() {
        let bars=items.values.filter { trashLiveMembers.contains($0.conversation.id) && $0.role == .bar }.sorted { $0.target.minX>$1.target.minX }
        let briefs=bars.prefix(while:{!$0.full}).map { ($0.conversation.id,$0.target) }
        let orbs=items.values.filter { trashLiveMembers.contains($0.conversation.id) && $0.role == .orb && $0.slot>=base.leading }.sorted { $0.target.minX<$1.target.minX }.map { ($0.conversation.id,$0.target) }
        if tideTimeline == nil { tideTimeline=TideMotion(briefs:briefs,orbs:orbs);tideTimeline?.leases=tideLeaseMemory }
        else {
            let previous=tideTimeline?.owner
            tideTimeline?.reflow(briefs:briefs,orbs:orbs)
            if let previous,tideTimeline?.owner==nil {
                tideFaces[previous]?.park();tideWords?.park();tidePresentedOwner=nil
                for hit in tideBorrowHits.values { hit.isHidden=true;hit.cancelPress() }
                onTideReadingRoom?([])
            }
        }
        tideLeaseMemory=tideTimeline?.leases ?? tideLeaseMemory
        if let add=tideLeaseMemory.add,add.committed {
            let needed=add.briefs.prefix { trashLiveMembers.contains($0) && items[$0]?.role == .orb }.count
            _=tideLeaseMemory.updateAddCapacity(requiredBriefs:needed);tideTimeline?.leases=tideLeaseMemory
        }
        refreshTideProtection();scheduleTideWake()
    }

    // MARK: Dragging me (f038: into Focused; f042: out of it)

    /// me under the pointer: its centre follows the pointer from where it was picked up, at 1.1 × its size.
    private var meHeld: (start: CGPoint, origin: CGRect, pointer: CGPoint)?
    func holdMe(at p: CGPoint) {
        guard let me else { return }
        let channel=glassReleases.removeValue(forKey:ObjectIdentifier(me))
        let contour=contourHandoffs.removeValue(forKey:ObjectIdentifier(me))
        meHeld=(p,channel == nil && contour == nil ? (meMotion.rect ?? me.frame):me.frame,p)
        if let diameter = sunHoverPickupDiameter, let origin = meHeld?.origin {
            let target = CGSize(width: diameter * 1.1, height: diameter * 1.1)
            sunHoverHeldShape = (RectSpring(from: CGRect(origin: .zero, size: origin.size), to: CGRect(origin: .zero, size: target), velocity: .zero,
                                           response: AutoScene.queueSpring.response, damping: AutoScene.queueSpring.damping), motionNow())
        } else { sunHoverHeldShape = nil }
        sunHoverPickupDiameter = nil
    }
    func moveMe(to p: CGPoint) { meHeld?.pointer = p }
    /// Lets me go: it springs from where it is to `home` (its place in the layout the drop leads to).
    func releaseMe() {
        guard let me, meHeld != nil else { return }
        meHeld = nil; sunHoverHeldShape = nil; sunHoverPickupDiameter = nil
        meSpring = RectSpring(from: (meMotion.rect ?? me.frame).offsetBy(dx: -meDelta.minX, dy: -meDelta.minY), to: meHome, velocity: .zero, response: 0.28, damping: 0.84)
        meBegan = motionNow()
    }

    // MARK: Compare (f043)

    /// Where Split's dividers are: halfway between neighbouring segments (FocusLayout.dividers).
    var dividers: [CGFloat] { base.focused ? zip(base.bars, base.bars.dropFirst()).map { ($0.maxX + $1.minX) / 2 } : [] }
    /// me sits on a divider while Compare is asked or on (OrganicDockProjection meFrame), else at its place.
    private var meDivider: CGFloat?
    private var meHome: CGRect { var r = base.me; if let x = meDivider { r.origin.x = x - r.width / 2 }; return r }
    func setMeDivider(_ x: CGFloat?) {
        guard x != meDivider, let me, meHeld == nil else { meDivider = x; return }
        meDivider = x
        let now = motionNow()
        meSpring = RectSpring(from: (meMotion.rect ?? me.frame).offsetBy(dx: -meDelta.minX, dy: -meDelta.minY), to: meHome, velocity: .zero, response: 0.40, damping: 0.82)
        meBegan = now
    }
    var isHoldingMe: Bool { meHeld != nil }
    /// The bar or orb me would land on at `p`: bars widened 6 pt a side, orbs 10, both 10 up and down (OrganicDockBridge).
    func meTarget(at p: CGPoint) -> String? {
        items.values.first { item in
            let f = item.glass.frame
            return (item.role == .bar ? f.insetBy(dx: -6, dy: -10) : f.insetBy(dx: -10, dy: -10)).contains(p)
        }?.conversation.id
    }

    private func follow(_ p: CGPoint, row origin:CGFloat? = nil) -> CGPoint {
        let row = origin ?? (base.me.midY - rise)
        return CGPoint(x: p.x, y: row - 4 + (p.y - row) * 0.4)
    }

    /// Sample after header placement, so a return follows the same frame's moving destination.
    func headerLandingFrame(at now:Double) {
        let ownsBatch=beginGlassBatch();defer {endGlassBatch(ownsBatch)}
        for (id,landing) in dockLandings where now>=landing.until {
            landing.header?.setOrbCarried(false);dockLandings[id]=nil
        }
        for (id,back) in returns {
            guard let item=items[id],let header=back.header else {returns[id]=nil;continue}
            let target=view.convert(header.draggableOrbRect,from:header)
            let pose=back.delta.sample(now-back.began).rect
            place(item,CGRect(x:target.minX+pose.minX,y:target.minY+pose.minY,
                              width:pose.width+target.width-back.goalSize.width,height:pose.height+target.height-back.goalSize.height))
            if now-back.began>=back.delta.duration,!header.isHidden,header.alphaValue>=0.999 {finishHeaderReturn(id)}
        }
    }

    /// Driver A for the held node, at media time `now`, after the others are placed.
    func heldFrame(at now: Double) {
        synchronizeInjectedClock(at:now)
        let ownsBatch = beginGlassBatch(); defer { endGlassBatch(ownsBatch) }
        defer { reconcileGlassTopology() }
        if let m = meHeld, me != nil {
            let c = CGPoint(x: m.origin.midX + m.pointer.x - m.start.x, y: m.origin.midY + m.pointer.y - m.start.y)
            let size = sunHoverHeldShape.map { $0.shape.sample(max(0, now - $0.began)).rect.size } ?? CGSize(width: m.origin.width * 1.1, height: m.origin.width * 1.1)
            let r = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            placeMe(r, at: now)
        }
        guard let h = held, let item = items[h.id] else { return }
        let size = h.shape.sample(now - h.began).rect.size
        let center=freeCarry.map { CGPoint(x:$0.x.sample(now).value,y:$0.y.sample(now).value) } ?? h.center
        let r = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        if h.identity { placeIdentity(item,at:now,heldRect:r); return }
        place(item,r)
        if item.face.duration > 0 { item.decoration.setOpacity(item.faceOpacity(at: motionNow())) }
    }
}

extension CGRect {
    func subtractingSignedComponents(_ d: CGRect) -> CGRect {
        CGRect(x:origin.x-d.origin.x,y:origin.y-d.origin.y,width:size.width-d.size.width,height:size.height-d.size.height)
    }
    /// Four signed rates or deltas; CGRect edge accessors normalize negative dimensions.
    func addingSignedComponents(_ d: CGRect) -> CGRect {
        CGRect(x:origin.x+d.origin.x,y:origin.y+d.origin.y,
               width:size.width+d.size.width,height:size.height+d.size.height)
    }
    /// Componentwise sum (origin and size), for deltas laid over a frame.
    func adding(_ d: CGRect) -> CGRect { CGRect(x: minX + d.minX, y: minY + d.minY, width: width + d.width, height: height + d.height) }
}

/// A peek capsule's face (product BriefBar `titled`): the conversation's name and a chevron, then its badge in the control's
/// box at the end. Drawn by the view itself; laid out once for the capsule and clipped while the glass springs.
@MainActor final class PeekBarFace: NSView {
    private var title = "", badge: OrbBadge?
    private var capturingGlyphs = false
    var glyphExposureActive = false { didSet { if oldValue != glyphExposureActive { needsDisplay = true } } }
    var motionBadgeRect: CGRect? { didSet { if oldValue != motionBadgeRect { needsDisplay = true } } }
    private var cachedBadgeRect: CGRect?
    var badgeRect: CGRect? {
        if let cachedBadgeRect { return cachedBadgeRect }
        guard let badge else { return nil }
        let h=bounds.height,control=(h*0.5).clamped(26,30).rounded(),end=((h-control)/2).rounded()
        let box=CGRect(x:bounds.width-end-control,y:((h-control)/2).rounded(),width:control,height:control)
        let base=NSFont.systemFont(ofSize:10,weight:.bold)
        let font=base.fontDescriptor.withDesign(.rounded).flatMap{NSFont(descriptor:$0,size:10)} ?? base
        let size=(badge.symbol.text as NSString).size(withAttributes:[.font:font])
        let width=max(18,(size.width+10).rounded())
        let r=CGRect(x:(box.midX-width/2).rounded(),y:(box.midY-9).rounded(),width:width,height:18)
        cachedBadgeRect=r;return r
    }
    func glyphBitmap(scale: CGFloat) -> CGImage {
        capturingGlyphs = true
        defer { capturingGlyphs = false; needsDisplay = true }
        return M10DockPicture.draw(self,scale:scale,plates:false)!
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ c: Conversation, badge: OrbBadge?, size: CGSize) {
        title = c.title; self.badge = badge; cachedBadgeRect = nil
        frame = CGRect(origin: .zero, size: size)
        needsDisplay = true
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(c.title)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { drawFace() }
    }

    private func drawFace() {
        if glyphExposureActive, !capturingGlyphs {
            if let badge, let r = motionBadgeRect ?? badgeRect {
                (badge.tone == .red ? NSColor.systemRed:badge.tone == .yellow ? NSColor.systemYellow:NSColor.systemGreen).setFill()
                NSBezierPath(roundedRect:r,xRadius:min(r.width,r.height)/2,yRadius:min(r.width,r.height)/2).fill()
            }
            return
        }
        // DockBarMetrics: control = clamp(h × 0.5, 26, 30), end inset centres it on the end arc; leading max(16, h × 0.4).
        let h = bounds.height, control = (h * 0.5).clamped(26, 30).rounded(), end = ((h - control) / 2).rounded()
        let leading = max(16, h * 0.4)
        let box = CGRect(x: bounds.width - end - control, y: ((h - control) / 2).rounded(), width: control, height: control)
        if let badge {
            // 10 pt bold rounded, 5 pt a side, at least 18 × 18; white on red, black 0.85 on yellow or green.
            let base = NSFont.systemFont(ofSize: 10, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 10) } ?? base
            let red = badge.tone == .red
            let text = NSAttributedString(string: badge.symbol.text, attributes: [.font: font, .foregroundColor: red ? NSColor.white : NSColor(white: 0, alpha: 0.85)])
            let size = text.size(), pill = CGSize(width: max(18, (size.width + 10).rounded()), height: 18)
            let r = CGRect(x: (box.midX - pill.width / 2).rounded(), y: (box.midY - 9).rounded(), width: pill.width, height: 18)
            if !capturingGlyphs {
                (red ? NSColor.systemRed : badge.tone == .yellow ? NSColor.systemYellow : NSColor.systemGreen).setFill()
                let plate = motionBadgeRect ?? r
                NSBezierPath(roundedRect: plate, xRadius: min(plate.width,plate.height)/2, yRadius: min(plate.width,plate.height)/2).fill()
            }
            if !glyphExposureActive || capturingGlyphs {
                text.draw(at: CGPoint(x: (r.midX - size.width / 2).rounded(), y: (r.midY - size.height / 2).rounded()))
            }
        }
        guard !glyphExposureActive || capturingGlyphs else { return }
        // HStack(spacing 8): title, chevron, Spacer(min 4), status.
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        let chevronSize = chevron?.size ?? CGSize(width: 6, height: 10)
        let room = max(0, box.minX - 8 - 4 - 8 - chevronSize.width - 8 - leading)
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Look.ink, .paragraphStyle: style]
        let natural = (title as NSString).size(withAttributes: attributes)
        let width = min(room, ceil(natural.width))
        let line = ceil(natural.height)
        (title as NSString).draw(with: CGRect(x: leading, y: ((h - line) / 2).rounded(), width: width, height: line),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        if let chevron {
            let x = (leading + width + 8).rounded(), y = ((h - chevronSize.height) / 2).rounded()
            let tinted = NSImage(size: chevronSize, flipped: false) { rect in
                chevron.draw(in: rect); Look.secondary.set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: CGRect(x: x, y: y, width: chevronSize.width, height: chevronSize.height))
        }
    }
}

/// Finite, interruptible opacity on the dock's existing frame clock (including offscreen virtual time).
struct DockFade {
    var from: Float, to: Float, began = 0.0
    let duration = 0.20
    init(_ value: Float) { from = value; to = value }
    func value(at time: Double) -> Float {
        let k = Float(smoothstep(0, 1, (time - began) / duration))
        return from + (to - from) * k
    }
    mutating func retarget(_ target: Float, at time: Double) {
        guard target != to else { return }; from = value(at: time); to = target; began = time
    }
}

private extension RectSpring {
    /// A relative Peek delta can have negative dimensions; all four components remain signed.
    init(peekDeltaFrom from: CGRect, to: CGRect, velocity: CGRect, response: Double, damping: Double) {
        let extent=Double(max(abs(from.size.width),abs(from.size.height),abs(to.size.width),abs(to.size.height),1))
        let e=min(Spring.restEpsilon,0.002*extent)
        x=Spring(from:from.origin.x,to:to.origin.x,velocity:velocity.origin.x,response:response,damping:damping,epsilon:e)
        y=Spring(from:from.origin.y,to:to.origin.y,velocity:velocity.origin.y,response:response,damping:damping,epsilon:e)
        w=Spring(from:from.size.width,to:to.size.width,velocity:velocity.size.width,response:response,damping:damping,epsilon:e)
        h=Spring(from:from.size.height,to:to.size.height,velocity:velocity.size.height,response:response,damping:damping,epsilon:e)
    }
}
