import AppKit
import QuartzCore

/// D 0.3's planet and LL flights, on one window-wide plane. A pure shared sampler drives both
/// main-thread glass geometry and render-server translation. Reversals retain the authored timeline.
/// The legacy rail/composer implementation remains available for regression comparisons and pending Dock work.
@MainActor final class ModeFlight {
    final class Plane: NSView {
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {} // A foreground plane owns sublayers, never a cached ancestor canvas.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A planet's trip: from `from` to `to` (glyph-sized or orb-sized frames), leaving at `start`, taken in at the end
    /// (`absorbed`: a bar, or a sidebar row) or handed to the real orb there.
    struct Token {
        let id: String
        let conversation: Conversation
        let from: CGRect, to: CGRect
        let start: Double
        let absorbed: Bool
    }

    /// One flying thing's plane. CA keyframes move real glass only from above its container: on the glass view's own layer,
    /// or on a plane inside the container, the glass stays where it is and only its content goes (standalone test, 10-31).
    @MainActor private final class Carrier {
        let plane = Plane(), container = NSGlassEffectContainerView(), content = Plane(), ink = Plane()
        var shaped = false
        var decorationVisible:Bool?
        var orbGeometry:(frame:CGRect,content:CGRect)?
        var glyphStage: ModeFlightGlyphStage?
        init() {
            plane.wantsLayer = true;plane.clipsToBounds=false;container.clipsToBounds=false;content.clipsToBounds=false;ink.clipsToBounds=false
            container.wantsLayer=true
            container.spacing = 0
            container.contentView = content
            plane.addSubview(container)
            plane.addSubview(ink)
        }
        func fit(_ size: CGSize) {
            let bounds = CGRect(origin: .zero, size: size)
            if plane.frame.size != size { plane.setFrameSize(size) }; container.frame = bounds; content.frame = bounds
        }
    }

    let view = Plane()
    /// Presentation of the independent sidebar, sampled on the same absolute server clock.
    var rowSidebarOffset:((Double)->CGFloat)?
    func refreshRowPresentation() {
        guard usesOrrery,running else {return}
        serverCache=nil
        if usesServerMotion {installServerMotion()}
    }
    private var sampledPoses:[String:[ModeOrreryFlight.Pose]]?
    private var sampledRowOffsets:[CGFloat]?
    private func rowOffset(at time:Double)->CGFloat {
        if let offsets=sampledRowOffsets {let i=Int((time/serverDuration*Double(serverSamples-1)).rounded());if offsets.indices.contains(i) {return offsets[i]}}
        return rowSidebarOffset?(began+time) ?? 0
    }
    private func visibleRow(_ rect:CGRect,at time:Double)->CGRect {rect.offsetBy(dx:rowOffset(at:time),dy:0)}
    private var link: CADisplayLink?
    private var began = 0.0
    private var modeProbe: ModeSignposts.Trace?
    private var probedFirstTick = false
    private(set) var running = false

    static let orreryEnabled = ProcessInfo.processInfo.environment["M11_MODE_ORRERY_FLIGHT"] != "0"
    private var orreryClock = ModeOrreryFlight.Clock()
    private var orreryPlans: [String: ModeOrreryFlight.Plan] = [:]
    private var orreryForward = true
    private var orreryAvatar: (from: CGRect, to: CGRect)?
    private var orreryAvatarGlass = Spring.rest(0)
    /// Reserved for the later Dock-owned composer/neck implementation. Nil keeps its legacy path.
    weak var dockBridge: (any ModeFlightDockBridge)?
    /// Read-only endpoint lookup. prepareDragDecoration copies component-owned drawing, never a live view.
    var endpointOrb: ((String) -> OrbComponent?)?
    /// A native endpoint must be mounted and exposed before its last flying owner is retired.
    var destinationOwnerVisible: ((String) -> Bool)?
    /// Native geometry is sampled independently of the authored rail and its cached resting destination.
    var destinationOwnerFrame: ((String) -> CGRect?)?
    /// Shared Dock translation is independent of the authored avatar rail and its final endpoint blend.
    var destinationOwnerLift: ((String) -> CGFloat?)?
    private var lastOwnerLiftTrace:CGFloat?
    private var ownerLiftTrace:ModeSignposts.Trace?
    var destinationOwnerFailure: ((String) -> String)?
    /// A finite, already-commanded visibility clock (for example the independently moving native sidebar).
    var destinationVisibilityEndsAt: (() -> Double?)?
    private var knownVisibilityEnd=0.0
    private var liveOwnerFrames: [String:CGRect] = [:]
    private(set) var forcedRetirements = 0
    private(set) static var forcedRetirementCount = 0
    func currentDestinationRect(_ id:String)->CGRect? {
        guard usesOrrery,toOrganic else {return nil}
        if let rect=destinationOwnerFrame?(id),rect.width>0,rect.height>0 {
            liveOwnerFrames[id]=rect;return rect
        }
        return liveOwnerFrames[id]
    }
    private func trackedOwnerRect(_ id:String,_ rect:CGRect,at t:Double)->CGRect {
        guard usesOrrery,toOrganic else {return rect}
        var adjusted=rect,synchronousLift:CGFloat=0
        if id == "me",t>0,let lift=destinationOwnerLift?(id) {
            synchronousLift=lift*CGFloat(ModeOrreryFlight.smooth(min(1,t/0.08)))
            adjusted.origin.y+=synchronousLift
            if ModeSignposts.enabled,lastOwnerLiftTrace.map({abs($0-synchronousLift)>0.01}) ?? true {
                lastOwnerLiftTrace=synchronousLift
                if ownerLiftTrace == nil {ownerLiftTrace=modeProbe ?? ModeSignposts.Trace()}
                ownerLiftTrace?.record("ModeFlightOwnerLift",detail:"id=me shift=\(synchronousLift)",at:began+t)
            }
        }
        let base: CGRect, remaining:Double
        if id == "me" {
            guard let target=avatarEndpoints(toOrganic:true)?.to else {return rect}
            base=target;remaining=max(0,avatarHandoff-t)
        } else {
            guard let token=tokens.first(where:{$0.token.id == id})?.token,
                  !token.absorbed,let plan=orreryPlans[id] else {return rect}
            base=token.to
            remaining=orreryClock.rate>0 ? max(0,plan.handoff-orreryTime(t)):max(0,orreryTime(t))
        }
        // A zero-weight correction does not need native layer reads on the initial flight submission.
        guard remaining<0.14,let native=currentDestinationRect(id) else {return adjusted}
        // Blend only the endpoint delta over the authored last 140 ms. The board rail is unchanged.
        // Once landed, following the native surface exactly lets a lift keep its own spring and velocity.
        let w=CGFloat(1-ModeOrreryFlight.smooth(min(1,remaining/0.14)))
        return CGRect(x:adjusted.minX+(native.minX-base.minX)*w,y:adjusted.minY+(native.minY-base.minY-synchronousLift)*w,
                      width:max(0.5,rect.width+(native.width-base.width)*w),height:max(0.5,rect.height+(native.height-base.height)*w))
    }
    private func ownerGeometryMatches(_ id:String,at t:Double)->Bool {
        guard usesOrrery,toOrganic,let native=currentDestinationRect(id) else {return true}
        // An absorbed token transfers into a full bar, rather than matching that bar's outer rectangle.
        if tokens.first(where:{$0.token.id == id})?.token.absorbed == true {return true}
        let authored:CGRect?
        if id == "me" {authored=orreryAvatarFrame(t)}
        else {authored=orreryPlans[id].map {corrected($0.pose(at:orreryTime(t)).rect,by:corrections[id],at:t)}}
        guard let authored else {return true}
        return MotionStep.edge(trackedOwnerRect(id,authored,at:t),native)<0.5
    }
    var conversationIsLive: ((Conversation) -> Bool)?
    private struct Delta {
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        init(x: CGFloat,y: CGFloat,width: CGFloat,height: CGFloat) { self.x=x;self.y=y;self.width=width;self.height=height }
    }
    private struct Correction {
        let delta: Delta; let duration: Double
        var referenceSize: CGSize? = nil
        var velocity: CGPoint = .zero
    }
    private var retiredOwners: Set<String> = []
    private var nativeAppearanceOwners:Set<String> = []
    /// A filtered destination has no visible owner to wait for.
    var destinationExists: ((String) -> Bool)?
    private var corrections: [String:Correction] = [:]
    private var rowCorrections: [String:Correction] = [:]
    private var avatarCorrection: Correction?
    private var ownerExposedAt: [String:Double] = [:]
    private var waitingForOwner = false
    private var ownerProbe: Timer?
    private var ownerProbeCount = 0
    private var ownerProbeGeneration = 0
    private var lastAdvancedTime = 0.0
    private var parkedMediaTime = 0.0, parkedFlightTime = 0.0
    private var checkingOwners = false
    private var ownerCommitCheckScheduled=false
    private func stopOwnerProbe() {
        ownerProbe?.invalidate();ownerProbe=nil;ownerProbeGeneration &+= 1;ownerCommitCheckScheduled=false
    }
    private func parkOwnerProbe() {
        guard running,ownerProbe == nil else {return}
        parkedMediaTime=CACurrentMediaTime();parkedFlightTime=lastAdvancedTime;ownerProbeCount=0
        let timer=Timer(timeInterval:0.1,target:self,selector:#selector(probeDestinationOwners(_:)),userInfo:nil,repeats:true)
        ownerProbe=timer;RunLoop.main.add(timer,forMode:.common)
    }
    @objc private func probeDestinationOwners(_ timer:Timer) {
        guard running,ownerProbe === timer else {timer.invalidate();return}
        ownerProbeCount+=1;checkDestinationOwners()
        if !running {stopOwnerProbe()}
        else if !waitingForOwner {ownerProbe?.invalidate();ownerProbe=nil}
        else if ownerProbeCount>=20 {stopOwnerProbe()}
    }
    private func checkDestinationOwners() {
        guard running,usesOrrery,!checkingOwners else {return}
        checkingOwners=true
        defer {checkingOwners=false}
        let parkedSample=parkedMediaTime>0 ? parkedFlightTime+max(0,CACurrentMediaTime()-parkedMediaTime):lastAdvancedTime
        let sample=max(lastAdvancedTime,elapsed,parkedSample)
        waitingForOwner=false;link?.isPaused=false
        advance(at:sample)
        if running,!waitingForOwner {
            // Manual/offscreen hosts have no display link; native ownership still needs one exposure fence.
            let lease=ownerProbeGeneration,interval=profile.frameInterval
            DispatchQueue.main.asyncAfter(deadline:.now()+interval) { [weak self] in
                guard let self,self.running,self.ownerProbeGeneration == lease else {return}
                self.advance(at:max(self.elapsed,sample+interval))
            }
        }
    }
    /// Resources and the t=0 command are ready before native sources are hidden; there is one owner.
    var sourceOwnerNeedsCommit: Bool { false }
    private func canRetireOwner(_ id: String, at time: Double) -> Bool {
        // A completed transfer stays completed when the native owner later animates its own ink.
        // Reversal/reclamation explicitly clears retirement; an unrelated Pulse fade cannot reopen it.
        if retiredOwners.contains(id) {return true}
        guard ownerVisible(id),ownerGeometryMatches(id,at:time) else { return false }
        guard destinationOwnerVisible != nil else { return true }
        return ownerExposedAt[id].map { time-$0 >= profile.frameInterval-1e-9 } ?? false
    }
    private func corrected(_ rect: CGRect, by correction: Correction?, at elapsed: Double) -> CGRect {
        guard let correction else { return rect }
        let k = 1-ModeOrreryFlight.smooth(elapsed/max(0.001,correction.duration))
        let span=min(0.08,correction.duration),u=min(1,max(0,elapsed/span))
        let v=CGFloat(max(0,elapsed)*(1-u)*(1-u))
        // A positive size ratio stays positive even when the authored path later shrinks to ring size.
        let reference=correction.referenceSize ?? rect.size
        let width=rect.width*(1+correction.delta.width/max(0.001,reference.width)*k)
        let height=rect.height*(1+correction.delta.height/max(0.001,reference.height)*k)
        return CGRect(x:rect.minX+correction.delta.x*k+correction.velocity.x*v,y:rect.minY+correction.delta.y*k+correction.velocity.y*v,
                      width:max(0.5,width),height:max(0.5,height))
    }
    private var serverOwnerVisibility: [String:Bool]?
    private var frameOwnerVisibility:[String:Bool]?
    private func ownerVisible(_ id: String) -> Bool { serverOwnerVisibility?[id] ?? frameOwnerVisibility?[id] ?? destinationOwnerVisible?(id) ?? true }
    private func correcting(_ id: String, at elapsed: Double) -> Bool {
        for correction in [corrections[id],rowCorrections[id]] {
            guard let c=correction,elapsed<c.duration else { continue }
            let position=abs(c.delta.x)+abs(c.delta.y)
            let size=abs(c.delta.width)+abs(c.delta.height)
            if position+size>0.01 { return true }
        }
        return false
    }
    private var usesOrrery: Bool { Self.orreryEnabled && !reducesMotion }
    private func orreryTime(_ elapsed: Double) -> Double { orreryClock.time(at: elapsed) }
    private func orreryAvatarFrame(_ elapsed: Double) -> CGRect? {
        guard usesOrrery, let trip = orreryAvatar else { return nil }
        return corrected(ModeOrreryFlight.avatar(at: orreryTime(elapsed), forward: orreryForward, from: trip.from, to: trip.to),by:avatarCorrection,at:elapsed)
    }
    private func orreryPose(_ id: String, at elapsed: Double) -> ModeOrreryFlight.Pose? {
        guard usesOrrery, let plan = orreryPlans[id] else { return nil }
        if let poses=sampledPoses?[id] {let i=Int((elapsed/serverDuration*Double(serverSamples-1)).rounded());if poses.indices.contains(i) {return poses[i]}}
        var pose = plan.pose(at: orreryTime(elapsed))
        pose.rect = corrected(pose.rect,by:corrections[id],at:elapsed)
        if orreryClock.rate < 0 && orreryTime(elapsed) > 0 { pose.visible = true }
        if !canRetireOwner(id,at:elapsed) { pose.visible = true }
        return pose
    }

    private struct ServerPath {let x:[NSNumber],y:[NSNumber];var depth:[NSNumber]? = nil}
    private var serverCache:(key:String,paths:[String:ServerPath])?
    private var serverActive=false
    private static let serverMotionEnabled=ProcessInfo.processInfo.environment["M11_MODE_SERVER_MOTION"] != "0"
    var prioritizesInitialSubmit=false
    private var serverHorizon:Double?
    private var serverExtensionGeneration=0
    private var serverDuration: Double { serverHorizon ?? (usesOrrery ? max(2,orreryClock.remaining) : 2) }
    private func beginInitialServerWindow() {
        guard usesOrrery,prioritizesInitialSubmit,manualTime == nil else {return}
        serverHorizon=0.125;serverExtensionGeneration &+= 1
        let generation=serverExtensionGeneration
        DispatchQueue.main.asyncAfter(deadline:.now()+profile.frameInterval*2) { [weak self] in
            guard let self,self.running,self.serverExtensionGeneration == generation else {return}
            self.serverHorizon=nil;self.serverCache=nil
            self.installServerMotion()
        }
    }
    private var serverSamples: Int { Int(ceil(serverDuration*240))+1 }
    #if M10_MODE_SELFTEST || M11_MODE_SELFTEST
    var verificationServerMotion=false
    var verificationBeforeServerCommit:(()->Void)?
    var verificationBeforeInitialCommit:(()->Void)?
    var verificationMaterialViews:[String:NSView] {Dictionary(uniqueKeysWithValues:tokens.map {($0.token.id,$0.carrier.container)})}
    var verificationAllMaterialViews:[NSView] {view.subviews.flatMap { $0.subviews.compactMap {$0 as? NSGlassEffectContainerView} }}
    var verificationMaterialLayers:[String:CALayer] {
        Dictionary(uniqueKeysWithValues:tokens.compactMap { node in node.carrier.container.layer.map {(node.token.id,$0)} })
    }
    var verificationHeldConversationIDs:Set<String> {Set(tokens.filter {!retiredOwners.contains($0.token.id)}.map {$0.token.conversation.id})}
    var verificationServerLayer:CALayer? {tokens.first?.carrier.plane.layer}
    var verificationServerLayers: [String:CALayer] {
        var result:[String:CALayer]=[:]
        result["me"]=avatarCarrier.plane.layer
        for node in tokens { result[node.token.id]=node.carrier.plane.layer }
        return result
    }
    var verificationRowLayers: [String:CALayer] {
        Dictionary(uniqueKeysWithValues:tokens.compactMap { node in
            node.carrier.glyphStage?.line.layer.map { (node.token.id,$0) }
        })
    }
    #endif
    private var usesServerMotion:Bool {
        if manualTime == nil {return Self.serverMotionEnabled}
        #if M10_MODE_SELFTEST || M11_MODE_SELFTEST
        return verificationServerMotion
        #else
        return false
        #endif
    }
    private func serverKey(_ forward:Bool,_ spring:RectSpring,_ plan:[Token],_ composer:(from:CGRect,to:CGRect,leave:Double)?)->String {
        "\(forward)|\(spring)|\(view.bounds.size)|\(orreryClock)|"+plan.map{"\($0.id):\($0.from):\($0.to):\($0.start):\($0.absorbed)"}.joined(separator:";")+"|\(String(describing:composer))"
    }
    private func serverPaths(_ forward:Bool,_ spring:RectSpring,_ plan:[Token],_ composer:(from:CGRect,to:CGRect,leave:Double)?)->[String:ServerPath] {
        func path(_ point:(Double)->CGPoint)->ServerPath {
            var x:[NSNumber]=[],y:[NSNumber]=[];x.reserveCapacity(serverSamples);y.reserveCapacity(serverSamples)
            for i in 0..<serverSamples {let p=point(Double(i)*serverDuration/Double(serverSamples-1));x.append(NSNumber(value:Double(p.x)));y.append(NSNumber(value:Double(p.y)))}
            return .init(x:x,y:y)
        }
        var result:[String:ServerPath]=["me":path{t in let r=self.orreryAvatarFrame(t) ?? spring.sample(t).rect;return CGPoint(x:r.midX,y:r.midY)}]
        for token in plan {
            result[token.id]=path { t in let r=self.tokenFrame(token,at:t,strip:self.view.bounds.height-20,forward:forward) ?? token.to;return CGPoint(x:r.midX,y:r.midY)}
            if usesOrrery { result[token.id]?.depth=(0..<serverSamples).map { NSNumber(value:orreryPose(token.id,at:Double($0)*serverDuration/Double(serverSamples-1))?.depth ?? 7) } }
        }
        if let composer {result["composer"]=path { t in let e=CGFloat(Self.ease(min(1,max(0,(t-composer.leave)/0.30))));return CGPoint(x:composer.from.midX+(composer.to.midX-composer.from.midX)*e,y:composer.from.midY+(composer.to.midY-composer.from.midY)*e)}}
        return result
    }
    func prewarmServerMotion(toOrganic:Bool,avatar:(from:CGRect,to:CGRect),tokens:[Token],composer:(from:CGRect,to:CGRect,slot:Int)?) {
        if !running,Self.orreryEnabled {
            let r=avatar.from,drawing=CGRect(x:avatarCarrier.plane.bounds.midX-r.width/2,y:avatarCarrier.plane.bounds.midY-r.height/2,width:r.width,height:r.height)
            self.avatar.frame=drawing;self.avatar.cornerRadius=min(r.width,r.height)/2
            avatarContent.frame=CGRect(origin:.zero,size:r.size);avatarFace.frame=avatarContent.bounds
            avatarFace.glassness=toOrganic ? 0:1;avatarTrail.frame=avatarContent.bounds
            return
        }
        guard !running,usesServerMotion,!Self.orreryEnabled else{return}
        let spring=RectSpring(from:avatar.from,to:avatar.to,response:0.45,damping:0.82)
        let trip=composer.map{(from:$0.from,to:$0.to,leave:0.12+0.04*Double(min($0.slot,4)))}
        let key=serverKey(toOrganic,spring,tokens,trip)
        if serverCache?.key != key {serverCache=(key,serverPaths(toOrganic,spring,tokens,trip))}
    }
    private func installServerMotion() {
        #if M11_MODE_SELFTEST
        verificationBeforeServerCommit?()
        #endif
        serverOwnerVisibility=Dictionary(uniqueKeysWithValues:(tokens.map {$0.token.id}+["me"]).map {($0,ownerVisible($0))})
        defer {serverOwnerVisibility=nil;sampledPoses=nil;sampledRowOffsets=nil}
        if usesOrrery {
            // Geometry and all appearance channels consume the same authored 240 Hz samples once.
            sampledRowOffsets=(0..<serverSamples).map {rowSidebarOffset?(began+Double($0)*serverDuration/Double(serverSamples-1)) ?? 0}
            var poses:[String:[ModeOrreryFlight.Pose]]=[:]
            for node in tokens {poses[node.token.id]=(0..<serverSamples).compactMap {orreryPose(node.token.id,at:Double($0)*serverDuration/Double(serverSamples-1))}}
            sampledPoses=poses
        }
        let plan=tokens.map(\.token),key=serverKey(toOrganic,avatarRect,plan,composerTrip)
        let paths=serverCache?.key == key ? serverCache!.paths:serverPaths(toOrganic,avatarRect,plan,composerTrip)
        modeProbe?.record(serverCache?.key == key ? "ModeServerPlanHit":"ModeServerPlanMiss")
        serverActive=true
        func install(_ node:NSView,_ id:String,_ centre:CGPoint) {installServerPath(node,paths[id],centre)}
        let r=orreryAvatarFrame(0) ?? avatarRect.sample(0).rect;install(avatarCarrier.plane,"me",CGPoint(x:r.midX,y:r.midY))
        for token in tokens {let r=tokenFrame(token.token,at:0,strip:view.bounds.height-20) ?? token.token.from;install(token.carrier.plane,token.token.id,CGPoint(x:r.midX,y:r.midY))}
        if usesOrrery { installOrreryAppearance() }
        // The composer stays where it is until it has been seen there (lateComposerTick). Left in the server from the start, a long
        // turn had it already at its far end when the first frame reached the screen, 330 pt from where it came from (board 10-31).
        if let trip=composerTrip {
            let centre=usesOrrery && !composerGlass.isHidden ? CGPoint(x:composerGlass.frame.midX,y:composerGlass.frame.midY):CGPoint(x:trip.from.midX,y:trip.from.midY)
            installServerPath(composerCarrier.plane,manualTime == nil ? ServerPath(x:[centre.x,centre.x].map{NSNumber(value:Double($0))},y:[centre.y,centre.y].map{NSNumber(value:Double($0))}):paths["composer"],centre)
        }
    }
    private func serverAnimationLayers() -> [CALayer] {
        let views=[avatarCarrier.plane,composerCarrier.plane]+tokens.flatMap { node in
            [node.carrier.plane,node.carrier.container,node.glass,node.carrier.ink,node.orb.backView,node.orb.frontView]+(node.carrier.glyphStage.map {[$0.line]} ?? [])
        }
        return views.compactMap(\.layer)
    }
    private func installServerPath(_ node:NSView,_ path:ServerPath?,_ centre:CGPoint) {
        guard let path,let layer=node.layer else{return}
        serverCounter(node,centre:centre)
        let absolute = usesOrrery && node !== composerCarrier.plane
        let x=CAKeyframeAnimation(keyPath:absolute ? "position.x":"transform.translation.x")
        let y=CAKeyframeAnimation(keyPath:absolute ? "position.y":"transform.translation.y")
        let dx=(layer.anchorPoint.x-0.5)*node.bounds.width,dy=(layer.anchorPoint.y-0.5)*node.bounds.height
        x.values=absolute ? path.x.map {NSNumber(value:$0.doubleValue+dx)}:path.x
        y.values=absolute ? path.y.map {NSNumber(value:$0.doubleValue+dy)}:path.y
        x.isAdditive = !absolute;y.isAdditive = !absolute;x.duration=serverDuration;y.duration=serverDuration
        var channels: [CAAnimation] = [x,y]
        if let values=path.depth {
            let depth=CAKeyframeAnimation(keyPath:"zPosition");depth.values=values;depth.duration=serverDuration;depth.calculationMode = .discrete
            channels.append(depth)
        }
        let group=CAAnimationGroup();group.animations=channels;group.duration=serverDuration;group.beginTime=layer.convertTime(began,from:nil)
        ModeSignposts.frameRange(group)
        group.fillMode = .both;group.isRemovedOnCompletion=false;layer.add(group,forKey:"mode.server.translation")
    }
    /// Content and glass opacity share the position clock even while the main thread is busy.
    /// Glass shape still follows native frames only; Gaussian channels belong only to row ink.
    private func installOrreryAppearance() {
        let previous=serverOwnerVisibility
        if previous == nil {serverOwnerVisibility=Dictionary(uniqueKeysWithValues:(tokens.map {$0.token.id}+["me"]).map {($0,ownerVisible($0))})}
        defer {serverOwnerVisibility=previous}
        for node in tokens where !nativeAppearanceOwners.contains(node.token.id) {
            let poses=(0..<serverSamples).compactMap { orreryPose(node.token.id,at:Double($0)*serverDuration/Double(serverSamples-1)) }
            func clock(row: Bool) -> CAAnimationGroup? {
                guard poses.count == serverSamples else { return nil }
                func key(_ path: String, _ values: [NSNumber], discrete: Bool = false) -> CAKeyframeAnimation {
                    let animation=CAKeyframeAnimation(keyPath:path);animation.values=values;animation.duration=serverDuration
                    animation.calculationMode=discrete ? .discrete:.linear;return animation
                }
                var channels: [CAAnimation] = [key("opacity",poses.map { NSNumber(value:row ? $0.row:$0.glass) })]
                if row {
                    channels.append(key("filters.m1131RowGaussian.inputRadius",poses.map { NSNumber(value:6*(1-$0.row)) }))
                    channels.append(key("filters.m1131RowGaussian.enabled",poses.map { NSNumber(value:$0.row>0 && $0.row<1) },discrete:true))
                    channels.append(key("zPosition",poses.map { NSNumber(value:Double($0.depth)+0.01) },discrete:true))
                    channels.append(key("transform.scale",poses.map { NSNumber(value:1+0.15*(1-$0.row)) }))
                    if let plan=orreryPlans[node.token.id] {
                        let rows=(0..<serverSamples).map { visibleRow(corrected(plan.row,by:rowCorrections[node.token.id],at:Double($0)*serverDuration/Double(serverSamples-1)),at:Double($0)*serverDuration/Double(serverSamples-1)) }
                        channels.append(key("position.x",rows.map {NSNumber(value:$0.midX-3)}))
                        channels.append(key("position.y",rows.map {NSNumber(value:$0.midY-1)}))
                        node.carrier.glyphStage?.installCoverageClock(rows:rows,strengths:poses.map(\.row),duration:serverDuration,began:began,offsets:(0..<serverSamples).map {rowOffset(at:Double($0)*serverDuration/Double(serverSamples-1))})
                    }
                }
                let group=CAAnimationGroup();group.animations=channels;group.duration=serverDuration
                group.beginTime=began;group.fillMode = .both;group.isRemovedOnCompletion=false
                return group
            }
            if let group=clock(row:false) {for view in [node.carrier.container,node.carrier.ink,node.orb.backView,node.orb.frontView] {if let layer=view.layer {group.beginTime=layer.convertTime(began,from:nil);layer.add(group,forKey:"mode.orrery.appearance")}}}
            if let layer=node.carrier.glyphStage?.line.layer,let group=clock(row:true) {group.beginTime=layer.convertTime(began,from:nil);layer.add(group,forKey:"mode.orrery.appearance")}
        }
    }
    private func serverCounter(_ node:NSView,centre:CGPoint,authored:CGPoint?=nil) {
        if usesOrrery && node !== composerCarrier.plane {
            // Geometry is local to the planet. Only this absolute carrier moves in window points.
            node.setFrameOrigin(CGPoint(x:centre.x-node.bounds.midX,y:centre.y-node.bounds.midY))
            if serverActive,let authored {node.layer?.transform=CATransform3DMakeTranslation(centre.x-authored.x,centre.y-authored.y,0)}
            else {node.layer?.transform=CATransform3DIdentity}
        } else if serverActive { node.layer?.transform=CATransform3DMakeTranslation(-centre.x,-centre.y,0) }
    }
    private func clearServerMotion() {
        guard serverActive else{return};serverActive=false
        for node in [avatarCarrier.plane,composerCarrier.plane]+tokens.map(\.carrier.plane) {
            node.layer?.removeAnimation(forKey:"mode.server.translation");node.layer?.transform=CATransform3DIdentity
        }
        for node in tokens {
            for view in [node.carrier.container,node.glass,node.carrier.ink,node.orb.backView,node.orb.frontView] { view.layer?.removeAnimation(forKey:"mode.orrery.appearance") }
            node.carrier.glyphStage?.line.layer?.removeAnimation(forKey:"mode.orrery.appearance")
        }
    }

    // me
    private let avatar = NSGlassEffectView()
    private let avatarCarrier = Carrier()
    private let avatarFace = AvatarFace()
    private let avatarContent = Plane()
    private let avatarTrail = M10ModeGlyphTrail(frame: .zero)
    private var avatarRect = RectSpring.rest(.zero), avatarGlass = Spring.rest(0)
    private var avatarShown = false
    /// The authored minimum (modeResponse × 1.4). The actual hand-off also waits for the existing
    /// analytic spring's visible tail; otherwise 2× text jumps to the endpoint at 0.63 s.
    static let handoff = 0.45 * 1.4
    private(set) var avatarHandoff = ModeFlight.handoff

    // planets
    private typealias TokenNode = (token: Token, glass: NSGlassEffectView, orb: OrbComponent, trail: M10ModeGlyphTrail, logical: CGRect?, carrier: Carrier)
    private var tokens: [TokenNode] = []
    private struct WarmKey: Equatable {let identity:ObjectIdentifier,configuration:OrbConfiguration,appearance:Int}
    private var warmTokens: [String: (WarmKey, TokenNode)] = [:]
    private(set) var preparedTokenCount = 0
    private(set) var consumedPreparedTokens = 0
    private func flightConfiguration(_ conversation:Conversation)->OrbConfiguration {
        var c=makeOrbConfiguration(conversation,drawingSize:32,backingScale:view.window?.backingScaleFactor ?? 2,reduceMotion:true,ambient:false,isKeyWindow:true)
        c.badge=nil;c.satellites=[];c.redUnseen=false
        return c
    }
    private func warmKey(_ t:Token)->WarmKey {
        .init(identity:ObjectIdentifier(t.conversation),configuration:flightConfiguration(t.conversation),appearance:NativeAppearance.revision)
    }
    /// Allocations and orb configuration happen while the flight plane is hidden. The first exposed glyph bake
    /// still uses its actual sampled size: baking it at a nominal future frame changes cold-path pixels.
    func prewarm(tokens next: [Token]) {
        guard !running else { return }
        view.isHidden=false;view.alphaValue=0
        let keep = Set(next.map(\.id))
        for id in Array(warmTokens.keys) where !keep.contains(id) {
            if let (_, node) = warmTokens.removeValue(forKey: id) { disposeToken(node) }
        }
        for token in next {
            let key = warmKey(token)
            if warmTokens[token.id]?.0 == key {continue}
            if let (_, old) = warmTokens.removeValue(forKey: token.id) { disposeToken(old) }
            let node = makeToken(token)
            node.glass.frame=token.from;node.orb.setFrame(token.from)
            node.glass.alphaValue=0;node.orb.setOpacity(0)
            if Self.orreryEnabled {node.carrier.container.alphaValue=0}
            warmTokens[token.id] = (key, node)
            preparedTokenCount += 1
        }
    }
    private func disposeToken(_ t: TokenNode) { t.carrier.glyphStage?.reset(); t.trail.reset(); t.glass.removeFromSuperview(); t.orb.dispose(); t.carrier.plane.removeFromSuperview() }
    private var toOrganic = true
    private var travel: Double { toOrganic ? 0.32 : 0.28 }

    // composer
    var composerMaterialIsVisible:Bool {dockBridge?.materialIsVisible ?? (composerTrip != nil && !composerGlass.isHidden)}
    func prepareComposerMaterial(from source:NSGlassEffectView?) {
        guard let source else{return}
        if composerGlass.style != source.style {composerGlass.style=source.style}
        if composerGlass.tintColor != source.tintColor {composerGlass.tintColor=source.tintColor}
    }
    private let composerGlass = NSGlassEffectView()
    private let composerCarrier = Carrier()
    private var composerTrip: (from: CGRect, to: CGRect, leave: Double)?
    private var composerLeaveStage = 0, composerSlot = 0
    private var composerShowsAt: Double?, landedLeg: Bool?, composerPlannedLeave: Double?
    /// Two ticks, because a commit after admission can take longer than any fixed wait. On the first it shows where the real
    /// composer is; it leaves on the next, once that commit is on screen. Left on the first, the frame that commit made was
    /// already well along (the curve starts fast), and it appeared across the window from the composer it came from (board 10-31).
    private func lateComposerTick(at t: Double) {
        guard let planned = composerTrip else { composerLeaveStage = 0; return }
        let centre = CGPoint(x: planned.from.midX, y: planned.from.midY)
        if composerLeaveStage == 2 {
            composerLeaveStage = 1; composerShowsAt = t
            composerTrip = (planned.from, planned.to, .greatestFiniteMagnitude)
            if serverActive {installServerPath(composerCarrier.plane,serverPaths(toOrganic,avatarRect,[],(planned.from,planned.to,.greatestFiniteMagnitude))["composer"],centre)}
            return
        }
        composerLeaveStage = 0
        let trip = (from: planned.from, to: planned.to, leave: max(t, composerPlannedLeave ?? 0.12 + 0.04 * Double(min(composerSlot, 4))))
        composerTrip = trip
        ends = max(ends, trip.leave + 0.30 + 0.16 + 0.05)
        // The other keyframes are in the server already; this one joins them on the same clock.
        if serverActive {installServerPath(composerCarrier.plane,serverPaths(toOrganic,avatarRect,[],trip)["composer"],centre)}
    }

    /// Called each frame with the elapsed time, and once at the end with `.infinity`.
    var onFrame: ((Double) -> Void)?
    /// How far the far end has moved since the trips were planned (Show Sidebar: the sidebar sliding in); the
    /// planets and me land where it is now, the offset growing with each one's progress.
    var targetShift:(()->CGPoint)? {didSet{
        if targetShift != nil,serverActive,!usesOrrery {
            // Bake the current analytic pose before retiring B; removing B at the last main-thread pose would jump backwards.
            CATransaction.begin();CATransaction.setDisableActions(true)
            clearServerMotion();frame(max(0,(manualTime?() ?? CACurrentMediaTime())-began))
            CATransaction.commit()
        }
    }}
    private var ends = 0.0
    private var reducesMotion = false
    var exposureEnabled = M10ModeExposure.enabled
    /// Tests use the production sampler without installing a display link or opening a window.
    var manualTime: (() -> Double)?
    var onExposureSample: ((M10ModeFrameSample) -> Void)?
    var onExposureCost: ((String, Double) -> Void)?
    /// Permanent window integration (unlike the per-leg onFrame hand-off). Sidebar sampling shares
    /// this display link rather than adding a second animation clock to the same mode transition.
    var onPresentationFrame: ((Double, DisplayProfile) -> Void)?
    var onShutdown: (() -> Void)?
    private var profile = DisplayProfile(name: "offscreen", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
    private let display = M10ModeDisplayProfile()
    private var previousShift: (time: Double, point: CGPoint)?

    init() {
        if Self.orreryEnabled {ModeFlightGlyphStage.prewarmInkAtlas()}
        view.wantsLayer = true
        for (g, carrier) in [(avatar, avatarCarrier), (composerGlass, composerCarrier)] {
            g.style = .regular
            g.tintColor = Look.canvas.withAlphaComponent(0.55)
            g.isHidden = true
            carrier.content.addSubview(g)
            view.addSubview(carrier.plane)
        }
        avatar.contentView = avatarContent
        avatarContent.addSubview(avatarFace)
        avatarContent.addSubview(avatarTrail)
        avatarTrail.bitmapProvider = { [weak avatarFace] scale in
            M10ModeExposure.glyphBitmap(size:avatarFace?.bounds.size ?? CGSize(width:1,height:1),scale:scale) {
                avatarFace?.drawGlyph(in:$0)
            }
        }
        avatarTrail.isHidden = true
        view.isHidden = true
        view.setAccessibilityElement(false)
    }

    func resize(to size: CGSize) {
        if Self.orreryEnabled,view.frame.size == size {return}
        view.frame = CGRect(origin: .zero, size: size)
        for carrier in [avatarCarrier, composerCarrier] + tokens.map(\.carrier) + warmTokens.values.map(\.1.carrier) { carrier.fit(size) }
        if Self.orreryEnabled { for node in tokens+warmTokens.values.map(\.1) { node.orb.setCanvasSize(size) } }
    }

    /// Starts a leg. `avatar` is me's trip (sidebar → dock when `toOrganic`); a reversal starts from where me is now.
    func start(toOrganic: Bool, avatar trip: (from: CGRect, to: CGRect), initials: String, tokens next: [Token],
               composer: (from: CGRect, to: CGRect, slot: Int)?, reduceMotion: Bool) {
        let now = manualTime?() ?? CACurrentMediaTime()
        let oldElapsed = now - began
        let atomicStart=Self.orreryEnabled && !reduceMotion && !prioritizesInitialSubmit
        let previousActions=CATransaction.disableActions()
        if Self.orreryEnabled,prioritizesInitialSubmit {CATransaction.setDisableActions(true)}
        if atomicStart { CATransaction.begin();CATransaction.setDisableActions(true) }
        var initialCommit=false
        defer {
            if Self.orreryEnabled,prioritizesInitialSubmit {CATransaction.setDisableActions(previousActions)}
            if atomicStart {
                if initialCommit {prepareInitialCommit()}
                CATransaction.commit()
                if initialCommit && !prioritizesInitialSubmit {CATransaction.flush()}
            }
        }
        if usesOrrery && running && !reduceMotion {
            profile=display.sample(for:view)
            modeProbe=ModeSignposts.current ?? modeProbe
            redirect(toOrganic:toOrganic,avatar:trip,tokens:next,at:oldElapsed)
            return
        }
        initialCommit=true
        let reversesOrrery = false
        corrections = [:]; rowCorrections = [:];avatarCorrection = nil;ownerExposedAt = [:];retiredOwners=[];nativeAppearanceOwners=[]
        clearServerMotion()
        modeProbe = ModeSignposts.current; probedFirstTick = false
        modeProbe?.record("ModeFlightPrepare", .begin)
        defer { modeProbe?.record("ModeFlightPrepare", .end) }
        reducesMotion = reduceMotion
        stopOwnerProbe();waitingForOwner=false;lastAdvancedTime=0;parkedMediaTime=0;parkedFlightTime=0
        if !usesOrrery {
            // Permanent carriers must not retain the previous Orrery world-to-local origin.
            for carrier in [avatarCarrier,composerCarrier] {
                carrier.plane.setFrameOrigin(.zero);carrier.plane.layer?.transform=CATransform3DIdentity
            }
        }
        profile = display.sample(for: view)
        previousShift = nil
        // A shift belongs to the leg that set it (after this start); one turned back must not carry the last one's.
        targetShift = nil
        // The glass as Settings ▸ Appearance has it now (ModeTransition.refreshPalette; app audit AP14).
        for g in [avatar, composerGlass] { dress(g, tint: 0.55) }
        // me: from where it is if it is still flying (its pose and velocity carry on), else from the far end at rest.
        let carried = running && avatarShown
        let pose = avatarRect.sample(now - began), glass = avatarGlass.sample(now - began)
        let from = carried ? pose.rect : trip.from
        avatarRect = RectSpring(from: from, to: trip.to, velocity: carried ? pose.velocity : .zero, response: 0.45, damping: 0.82)
        avatarGlass = Spring(from: carried ? glass.value : (toOrganic ? 0 : 1), to: toOrganic ? 1 : 0,
                             velocity: carried ? glass.velocity : 0, response: 0.45, damping: 0.82, epsilon: Spring.restEpsilon / 100)
        avatarHandoff = max(Self.handoff, avatarRect.duration, avatarGlass.duration)
        if avatarFace.initials != initials {avatarFace.initials = initials}
        avatarShown = true
        avatar.isHidden = false

        // A planet still in the air turns back from where it is, on the rail it came along, without waiting for its
        // turn (the product reverses the visible planets; here they leave again from their current frame).
        var airborne: [String: CGRect] = [:]
        if running { for t in tokens where !t.glass.isHidden { if let r=tokenFrame(t.token,at:now-began,strip:view.bounds.height-20),r.width>1 {airborne[t.token.id]=r} } }
        clearTokens()
        self.toOrganic = toOrganic
        if Self.orreryEnabled && !reduceMotion && !reversesOrrery {
            let sorted = next.sorted { (toOrganic ? $0.to.midX : $0.from.midX) < (toOrganic ? $1.to.midX : $1.from.midX) }
            orreryForward = toOrganic; orreryAvatar = trip
            orreryAvatarGlass = Spring(from:toOrganic ? 0:1,to:toOrganic ? 1:0,response:0.45,damping:0.82,epsilon:Spring.restEpsilon/100)
            orreryPlans = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { rank, token in
                (token.id, ModeOrreryFlight.Plan(forward: toOrganic, row: toOrganic ? token.from : token.to,
                    real: toOrganic ? token.to : token.from, rank: rank, lastRank: max(0,sorted.count-1), avatarFrom:trip.from, avatarTo:trip.to))
            })
            let duration = orreryPlans.values.map(\.duration).max() ?? 0.686
            orreryClock = .init(origin:0,rate:1,duration:duration)
        }
        if !reduceMotion {
            for var t in next {
                modeProbe?.record("ModeFlightTokenPrepare", .begin, detail: t.id)
                defer { modeProbe?.record("ModeFlightTokenPrepare", .end, detail: t.id) }
                if !usesOrrery, let here = airborne[t.id] { t = Token(id: t.id, conversation: t.conversation, from: here, to: t.to, start: 0, absorbed: t.absorbed) }
                let warmed = warmTokens.removeValue(forKey: t.id)
                if let (key, cached) = warmed, key == warmKey(t) {
                    cached.glass.alphaValue=1
                    if Self.orreryEnabled {cached.carrier.container.alphaValue=1}
                    cached.orb.backView.isHidden = false; cached.orb.frontView.isHidden = false
                    tokens.append((t, cached.glass, cached.orb, cached.trail, nil, cached.carrier)); consumedPreparedTokens += 1
                    ModeSignposts.current?.record("ModeFlightResourceHit", detail: t.id)
                } else {
                    if let (_, old) = warmed { disposeToken(old) }
                    tokens.append(makeToken(t))
                    ModeSignposts.current?.record("ModeFlightResourceMiss", detail: t.id)
                }
            }
        }
        if usesOrrery {
            // A changed selection may consume only a subset of the warmed identities.
            for (_, node) in warmTokens.values {disposeToken(node)}
            warmTokens.removeAll()
            for node in tokens where node.carrier.glyphStage == nil {
                node.carrier.glyphStage = ModeFlightGlyphStage(conversation:node.token.conversation,in:view)
            }
            for node in tokens.sorted(by: { (orreryPlans[$0.token.id]?.rank ?? 0) < (orreryPlans[$1.token.id]?.rank ?? 0) }) { view.addSubview(node.carrier.plane) }
            avatarHandoff = orreryClock.remaining
            avatarCarrier.plane.layer?.zPosition = 6
        }
        composerLeaveStage = 0; landedLeg = nil; composerPlannedLeave = nil; composerShowsAt = nil
        composerTrip = reduceMotion || dockBridge != nil ? nil : composer.map { ($0.from, $0.to, 0.12 + 0.04 * Double(min($0.slot, 4))) }
        // Seen where the real composer is before it goes, on the same two ticks as the late path. Without a display link's ticks
        // (offscreen checks) just a little before it leaves.
        if let trip = composerTrip {
            if manualTime == nil { composerPlannedLeave = trip.leave; composerLeaveStage = -1 }
            else { composerShowsAt = trip.leave - 0.034 }
        }
        composerGlass.isHidden = composerTrip == nil

        began = usesOrrery ? (manualTime?() ?? CACurrentMediaTime()):now
        let lastToken = next.map { $0.start + travel }.max() ?? 0
        ends = max(avatarHandoff, lastToken + 0.16, (composerTrip?.leave ?? 0) + 0.30 + 0.16) + 0.05
        if usesOrrery { ends = max(orreryClock.remaining, (composerTrip?.leave ?? 0) + (composerTrip == nil ? 0 : 0.51)) }
        liveOwnerFrames.removeAll();knownVisibilityEnd=0;lastOwnerLiftTrace=nil;ownerLiftTrace=nil
        running = true
        dockBridge?.beginModeFlight(.init(toOrganic:toOrganic,mediaTime:now,composer:composer,reversing:reversesOrrery))
        view.isHidden = false
        view.alphaValue=1;view.layer?.zPosition=ModePlaneOrder.flight
        if link == nil, manualTime == nil {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            ModeSignposts.frameRange(l)
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
        beginInitialServerWindow()
        ModeSignposts.measure("ModeFlightInitialFrame") {frame(0,refreshSemantic:!prioritizesInitialSubmit)}
        if usesOrrery,prioritizesInitialSubmit,manualTime == nil {began=CACurrentMediaTime()}
        if usesServerMotion,!reduceMotion {
            ModeSignposts.measure("ModeServerCommit") {installServerMotion()}

        }
    }

    /// Called immediately before submitting the initial CA transaction, before any cold native work.
    private func prepareInitialCommit() {
        guard usesOrrery,usesServerMotion,manualTime == nil,!prioritizesInitialSubmit else {return}
        #if M11_MODE_SELFTEST
        verificationBeforeInitialCommit?()
        #endif
        began=CACurrentMediaTime()+(prioritizesInitialSubmit ? 0:profile.frameInterval)
        for layer in serverAnimationLayers() {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("mode.server.") || key == "mode.orrery.appearance" {
                if let command=layer.animation(forKey:key)?.copy() as? CAAnimation {
                    command.beginTime=layer.convertTime(began,from:nil);layer.add(command,forKey:key)
                }
            }
        }
    }

    /// Reuse native carriers. Rebase the clock, never restart an endpoint-to-endpoint leg.
    private func redirect(toOrganic nextDirection: Bool, avatar trip: (from:CGRect,to:CGRect), tokens next: [Token], at elapsed: Double) {
        stopOwnerProbe();waitingForOwner=false;lastAdvancedTime=0;parkedMediaTime=0;parkedFlightTime=0;link?.isPaused=false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var oldRects = Dictionary(uniqueKeysWithValues:tokens.compactMap { node in
            orreryPose(node.token.id,at:elapsed).map { pose in
                // Translation keeps running on CA during a stall; native glass size stays at its last commit.
                let tracked=trackedOwnerRect(node.token.id,pose.rect,at:elapsed)
                let size = serverActive && !node.glass.isHidden ? node.glass.frame.size:tracked.size
                return (node.token.id,CGRect(x:tracked.midX-size.width/2,y:tracked.midY-size.height/2,width:size.width,height:size.height))
            }
        })
        var oldRows = Dictionary(uniqueKeysWithValues:orreryPlans.map { id,plan in
            (id,corrected(plan.row,by:rowCorrections[id],at:elapsed))
        })
        let h=0.0001
        var oldVelocities=Dictionary(uniqueKeysWithValues:tokens.compactMap { node -> (String,CGPoint)? in
            guard let a=orreryPose(node.token.id,at:elapsed)?.rect,let b=orreryPose(node.token.id,at:elapsed+h)?.rect else {return nil}
            return (node.token.id,CGPoint(x:(b.midX-a.midX)/h,y:(b.midY-a.midY)/h))
        })
        let sampledAvatar=orreryAvatarFrame(elapsed).map {trackedOwnerRect("me",$0,at:elapsed)}
        let oldAvatar=sampledAvatar.map {r in
            let size=serverActive && avatarShown ? avatar.frame.size:r.size
            return CGRect(x:r.midX-size.width/2,y:r.midY-size.height/2,width:size.width,height:size.height)
        }
        let nextAvatar = orreryAvatarFrame(elapsed+h)
        let oldAvatarVelocity=sampledAvatar.flatMap {a in nextAvatar.map {CGPoint(x:($0.midX-a.midX)/h,y:($0.midY-a.midY)/h)}} ?? .zero
        let time = orreryTime(elapsed)
        let changedDirection = toOrganic != nextDirection
        let keepAvatarHidden = !changedDirection && !avatarShown
        if changedDirection { retiredOwners=[];nativeAppearanceOwners=[] }
        clearServerMotion()
        liveOwnerFrames.removeAll();knownVisibilityEnd=0;lastOwnerLiftTrace=nil;ownerLiftTrace=nil
        orreryClock.origin = time
        if toOrganic != nextDirection {
            orreryClock.rate = -orreryClock.rate
            composerTrip=nil;composerGlass.isHidden=true;composerLeaveStage=0
            composerShowsAt=nil;composerPlannedLeave=nil
        } else {
            // Rebase the deferred legacy composer along with the clock, without replaying its trip.
            if let trip=composerTrip {composerTrip=(trip.from,trip.to,trip.leave-elapsed)}
            composerShowsAt=composerShowsAt.map {$0-elapsed}
            composerPlannedLeave=composerPlannedLeave.map {$0-elapsed}
        }
        toOrganic = nextDirection
        corrections = [:]; rowCorrections = [:];avatarCorrection = nil;ownerExposedAt = [:]
        orreryAvatar = orreryForward == nextDirection ? trip:(trip.to,trip.from)
        let duration = max(0.001,orreryClock.remaining)
        // A conversation can change between a column header and a Dock slot during admission.
        // Its stable model identity keeps the same carrier even when its endpoint key changes.
        let keep = Set(next.map(\.id))
        for token in next where orreryPlans[token.id] == nil {
            if let i=tokens.firstIndex(where:{$0.token.conversation === token.conversation && !keep.contains($0.token.id)}) {
                let oldID=tokens[i].token.id
                if retiredOwners.remove(oldID) != nil {retiredOwners.insert(token.id)}
                orreryPlans[token.id]=orreryPlans.removeValue(forKey:oldID)
                oldRects[token.id]=oldRects.removeValue(forKey:oldID)
                oldRows[token.id]=oldRows.removeValue(forKey:oldID)
                oldVelocities[token.id]=oldVelocities.removeValue(forKey:oldID)
                tokens[i].token=token
            }
        }
        for node in tokens where !keep.contains(node.token.id) { disposeToken(node);orreryPlans.removeValue(forKey:node.token.id) }
        tokens.removeAll { !keep.contains($0.token.id) }
        for token in next {
            guard let old = orreryPlans[token.id] else { continue }
            let row = nextDirection ? token.from:token.to, real = nextDirection ? token.to:token.from
            let trip = orreryAvatar!
            let plan = ModeOrreryFlight.Plan(forward:orreryForward,row:row,real:real,rank:old.rank,lastRank:old.lastRank,avatarFrom:trip.from,avatarTo:trip.to)
            orreryPlans[token.id] = plan
            if !retiredOwners.contains(token.id),let oldRow=oldRows[token.id] {
                rowCorrections[token.id]=Correction(delta:Delta(x:oldRow.minX-row.minX,y:oldRow.minY-row.minY,width:oldRow.width-row.width,height:oldRow.height-row.height),duration:duration,referenceSize:row.size)
            }
            if !retiredOwners.contains(token.id),let rect = oldRects[token.id] {
                let base = plan.pose(at:time).rect
                corrections[token.id] = Correction(delta:Delta(x:rect.minX-base.minX,y:rect.minY-base.minY,width:rect.width-base.width,height:rect.height-base.height),duration:duration,referenceSize:base.size)
            }
            if let i = tokens.firstIndex(where:{$0.token.id == token.id}) { tokens[i].token = token }
        }
        if !keepAvatarHidden,let oldAvatar,let rect = orreryAvatarFrame(0) {
            avatarCorrection = Correction(delta:Delta(x:oldAvatar.minX-rect.minX,y:oldAvatar.minY-rect.minY,width:oldAvatar.width-rect.width,height:oldAvatar.height-rect.height),duration:duration,referenceSize:rect.size)
        }
        do {
            // Preserve C1 continuity on endpoint refresh as well as direction changes.
            // An 80 ms Hermite residual carries the displayed velocity into the reversed board clock.
            // Position is exact at the command; the residual and its derivative vanish at the far end.
            for node in tokens {
                let id=node.token.id
                guard let a=orreryPose(id,at:0)?.rect,let b=orreryPose(id,at:h)?.rect,let old=oldVelocities[id] else {continue}
                corrections[id]?.velocity=CGPoint(x:old.x-(b.midX-a.midX)/h,y:old.y-(b.midY-a.midY)/h)
            }
            if let a=orreryAvatarFrame(0),let b=orreryAvatarFrame(h) {
                avatarCorrection?.velocity=CGPoint(x:oldAvatarVelocity.x-(b.midX-a.midX)/h,y:oldAvatarVelocity.y-(b.midY-a.midY)/h)
            }
        }
        began = manualTime?() ?? CACurrentMediaTime();ends = max(duration,composerTrip.map {max(0,$0.leave+0.51)} ?? 0);avatarHandoff = keepAvatarHidden ? 0:duration
        avatarShown = !keepAvatarHidden;avatar.isHidden = keepAvatarHidden
        beginInitialServerWindow()
        frame(0,refreshSemantic:false)
        if usesServerMotion { installServerMotion() }
    }

    var activeTokens: [Token] { tokens.map(\.token) }
    var rowCoverage:(()->ModeFlightRowCoverage?)?
    func rowCoverageMatches(_ id:String)->Bool {tokens.first {$0.token.conversation.id == id}?.carrier.glyphStage?.coverage != nil}
    var heldConversationIDs:Set<String> {Set(tokens.filter {!retiredOwners.contains($0.token.id)}.map {$0.token.conversation.id})}
    var presentationInterval:Double {profile.frameInterval}
    /// Reclaim a just-published native contribution in the same transaction as a scroll ownership fence.
    func reclaimPendingRowOwners() {
        guard running,usesOrrery,!nativeAppearanceOwners.isEmpty else {return}
        frame(elapsed,refreshSemantic:false)
    }
    var headingToOrganic: Bool { toOrganic }
    /// Repaired native paint needs a fresh display commit before its flight owner can retire.
    func destinationPaintReasserted(_ id:String) {
        guard running,usesOrrery,!retiredOwners.contains(id) else {return}
        ownerExposedAt.removeValue(forKey:id)
    }

    func organicSourceAtRest(_ id: String, at elapsed: Double) -> Bool {
        guard usesOrrery,!toOrganic else { return false }
        return sourceOwnerNeedsCommit
    }
    func avatarEndpoints(toOrganic: Bool) -> (from:CGRect,to:CGRect)? {
        guard let trip=orreryAvatar else { return nil }
        return orreryForward == toOrganic ? trip:(trip.to,trip.from)
    }

    /// Resize and store mutations refresh geometry without replacing the authored phase or native nodes.
    func updateEndpoints(rows: [String:CGRect], real: [String:CGRect], avatar: (from:CGRect,to:CGRect), absorbedIDs: Set<String>? = nil) {
        guard running,usesOrrery else { return }
        let previousCount=tokens.count
        pruneConversations()
        let removed=previousCount != tokens.count
        let next = tokens.map { node -> Token in
            let token=node.token,row=rows[token.conversation.id] ?? (toOrganic ? token.from:token.to)
            let header="header."+token.conversation.id
            let key=real[token.id] != nil ? token.id:(real[header] != nil ? header:(real[token.conversation.id] != nil ? token.conversation.id:token.id))
            let orb=real[key] ?? (toOrganic ? token.to:token.from)
            let absorbed=toOrganic ? (absorbedIDs.map {$0.contains(key)} ?? token.absorbed):true
            return Token(id:key,conversation:token.conversation,from:toOrganic ? row:orb,to:toOrganic ? orb:row,start:token.start,absorbed:absorbed)
        }
        let trip=avatarEndpoints(toOrganic:toOrganic)
        let changed = (trip.map { MotionStep.edge($0.from,avatar.from)>0.01 || MotionStep.edge($0.to,avatar.to)>0.01 } ?? false)
            || Set(next.map(\.id)) != Set(tokens.map {$0.token.id})
            || next.contains { token in tokens.first(where:{$0.token.id == token.id}).map { MotionStep.edge($0.token.from,token.from)>0.01 || MotionStep.edge($0.token.to,token.to)>0.01 || $0.token.absorbed != token.absorbed } ?? false }
        if changed { redirect(toOrganic:toOrganic,avatar:avatar,tokens:next,at:elapsed) }
        else if removed || waitingForOwner {checkDestinationOwners()}
    }
    private func pruneConversations() {
        let removed = tokens.filter { $0.token.conversation.archived || conversationIsLive?($0.token.conversation) == false || (!toOrganic && destinationExists?($0.token.conversation.id) == false) }
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map { $0.token.id })
        for node in removed { disposeToken(node);orreryPlans.removeValue(forKey:node.token.id);corrections.removeValue(forKey:node.token.id);rowCorrections.removeValue(forKey:node.token.id) }
        tokens.removeAll { ids.contains($0.token.id) }
    }

    private func makeToken(_ token: Token) -> TokenNode {
        let g = NSGlassEffectView()
        dress(g, tint: nil)
        let carrier = Carrier()
        carrier.fit(view.bounds.size)
        carrier.content.addSubview(g)
        view.addSubview(carrier.plane)
        let endpoint = Self.orreryEnabled ? endpointOrb?(token.id) : nil
        let copy = endpoint?.prepareDragDecoration(glassView:g)
        let orb = copy ?? OrbComponent(id: "flight." + token.id, glassView: g)
        if let endpoint { g.style=endpoint.glassView.style; g.tintColor=endpoint.glassView.tintColor }
        orb.setCanvasSize(view.bounds.size)
        carrier.plane.addSubview(orb.backView, positioned: .below, relativeTo: carrier.container)
        carrier.plane.addSubview(orb.frontView, positioned: .above, relativeTo: carrier.container)
        let c=flightConfiguration(token.conversation)
        if copy == nil { orb.configure(c) }
        // Only decoration enters the replicator, never the glass. Its real content frame below is
        // counter-positioned inside the stretched glass, so neither its glyphs nor liquid are stretched.
        let trail = M10ModeGlyphTrail(frame: .zero)
        trail.freezesContent = true
        let decoration = g.contentView
        g.contentView = trail
        if let decoration {
            decoration.frame = CGRect(x:0,y:0,width:32,height:32)
            trail.addSubview(decoration)
        }
        if Self.orreryEnabled {
            // As in M11.27, content is a sibling of sharp glass, with independent opacity.
            g.contentView = Plane()
            carrier.ink.addSubview(trail)
            carrier.glyphStage = ModeFlightGlyphStage(conversation:token.conversation,in:view)
            carrier.glyphStage?.line.isHidden = true
        }
        return (token, g, orb, trail, nil, carrier)
    }

    /// A valid prepared leg is already in flight when native ownership changes. Keep its clock, caches and poses.
    /// Changed destination geometry is rebased continuously onto this same authored phase.
    func continuePrepared(toOrganic: Bool, avatar destination: CGRect, tokens next: [Token],
                          composer: (from: CGRect, to: CGRect, slot: Int)?, reduceMotion: Bool) -> Bool {
        guard running, self.toOrganic == toOrganic, reducesMotion == reduceMotion else { return false }
        let elapsed = (manualTime?() ?? CACurrentMediaTime()) - began
        var redirected = false
        if usesOrrery {
            let currentDestination = avatarEndpoints(toOrganic:toOrganic)?.to ?? destination
            let changed = MotionStep.edge(currentDestination,destination)>0.5
                || Set(tokens.map { $0.token.id }) != Set(next.map(\.id))
                || tokens.contains { old in next.first(where:{$0.id == old.token.id}).map { MotionStep.edge($0.from,old.token.from)>0.5 || MotionStep.edge($0.to,old.token.to)>0.5 } ?? true }
            if changed {
            let trip = self.toOrganic ? (orreryForward ? orreryAvatar!.from:orreryAvatar!.to,destination)
                                     : (orreryForward ? orreryAvatar!.to:orreryAvatar!.from,destination)
            redirect(toOrganic:toOrganic,avatar:trip,tokens:next,at:elapsed)
            redirected = true
            }
        } else {
            guard MotionStep.edge(avatarRect.target,destination)<0.5,
                  Set(tokens.map { $0.token.id }) == Set((reduceMotion ? []:next).map(\.id)),
                  tokens.allSatisfy({ old in next.contains { $0.id == old.token.id && $0.absorbed == old.token.absorbed && MotionStep.edge($0.to,old.token.to)<0.5 } }) else { return false }
        }
        if !reduceMotion, dockBridge == nil, composerTrip == nil, let composer {
            // Its clock starts on the first tick after this admission's turn: a long turn had it first seen already far along
            // its way, with the real composer still behind it (board 10-31).
            composerTrip = (composer.from, composer.to, .greatestFiniteMagnitude); composerSlot = composer.slot
            composerLeaveStage = 2
            if manualTime != nil {lateComposerTick(at: elapsed); lateComposerTick(at: elapsed)}
        }
        ModeSignposts.current?.record("ModeFlightContinued", detail: "same prepared destinations; original clock retained")
        if !redirected { frame(elapsed) }
        return true
    }

    /// Clear or regular per the look; a theme of its own tints with its canvas (0.20 clear, 0.55 tinted), else `tint`
    /// over Canopy's canvas (nil: none).
    private func dress(_ g: NSGlassEffectView, tint: CGFloat?) {
        let look=NativeAppearance.current,style:NSGlassEffectView.Style=look.clearGlass ? .clear:.regular
        if g.style != style {g.style=style}
        let color=look.background.map {$0.withAlphaComponent(look.clearGlass ? 0.20:0.55)} ?? tint.map {Look.canvas.withAlphaComponent($0)}
        if g.tintColor != color {g.tintColor=color}
    }

    /// The window closed: the display link (which holds this flight) goes (app audit AP24).
    func shutdown() {
        cancel()
        link?.invalidate(); link = nil
        onFrame = nil
        onExposureSample = nil; onExposureCost = nil
        onPresentationFrame = nil
        for (_, node) in warmTokens.values { disposeToken(node) }; warmTokens = [:]
        avatarTrail.reset()
        onShutdown?(); onShutdown = nil
    }

    /// Ends at once for an explicit nonanimated switch or window shutdown.
    func cancel() {
        guard running else { return }
        finish()
    }

    /// Whether `id`'s real orb may show yet (it is hidden until its planet arrives).
    func arrived(_ id: String, at elapsed: Double) -> Bool {
        if usesOrrery, let plan = orreryPlans[id] {
            if retiredOwners.contains(id) { return true }
            if correcting(id,at:elapsed) { return false }
            if orreryClock.rate < 0 { return orreryTime(elapsed) <= 0 }
            return orreryTime(elapsed) >= plan.handoff
        }
        guard let t = tokens.first(where: { $0.token.id == id && !$0.token.absorbed }) else { return true }
        return elapsed >= t.token.start + travel
    }

    /// Whether the full bar may show yet (its glass arrives at leave + 0.30).
    func barArrived(at elapsed: Double) -> Bool { dockBridge?.materialHasLanded ?? composerTrip.map { elapsed >= $0.leave + 0.30 } ?? true }

    var ownerTime:Double {max(elapsed,lastAdvancedTime)}
    var elapsed: Double { running ? max(0,(manualTime?() ?? CACurrentMediaTime()) - began) : .infinity }
    var duration: Double { ends }
    /// For demos: what is still on screen.
    var debugState: [String: Any] {
        ["running": running, "avatarHidden": avatar.isHidden, "avatar": NSStringFromRect(usesOrrery ? avatar.convert(avatar.bounds,to:view):avatar.frame), "tokens": tokens.count, "viewHidden": view.isHidden]
    }

    @objc private func tick(_ l: CADisplayLink) {
        modeProbe?.record("ModeFlightTick",.begin)
        defer{modeProbe?.record("ModeFlightTick",.end)}
        modeProbe?.display(l)
        if !probedFirstTick, let modeProbe {
            probedFirstTick = true
            modeProbe.record("FlightFirstDisplayLink", timestamp: l.timestamp, target: l.targetTimestamp)
            ModeSignposts.withTrace(modeProbe) { ModeSignposts.measure("ModeFlightFirstTick") { advance(l) } }
        } else {ModeSignposts.withTrace(modeProbe) {advance(l)}}
    }

    private func advance(_ l: CADisplayLink) {
        profile = display.sample(for: view, interval: l.targetTimestamp - l.timestamp)
        let t = max(0,l.targetTimestamp - began)
        if composerLeaveStage == -1, let planned = composerPlannedLeave, t >= planned - 0.034 { composerLeaveStage = 2 }
        if composerLeaveStage > 0 {lateComposerTick(at: t)}
        advance(at:t)
    }

    /// Shared by CADisplayLink and the windowless production-path verifier.
    func advance(at t: Double) {
        if usesOrrery,!running {return}
        lastAdvancedTime=t
        if let end=destinationVisibilityEndsAt?(),end.isFinite {knownVisibilityEnd=max(knownVisibilityEnd,end)}
        let nominalEnd=max(ends,knownVisibilityEnd-began)
        if !usesOrrery,t >= ends { finish(landed:true);return }
        frame(t)
        if t >= ends && (!usesOrrery || (tokens.allSatisfy { canRetireOwner($0.token.id,at:t) } && canRetireOwner("me",at:t))) {
            finish(landed:true)
        } else if usesOrrery,destinationOwnerFrame != nil,t >= nominalEnd+0.3 {
            let ids=(tokens.map {$0.token.id}+["me"]).filter {!canRetireOwner($0,at:t)}
            let reasons=ids.map {id in
                "\(id){dest=\(destinationOwnerVisible?(id) ?? true),geometry=\(ownerGeometryMatches(id,at:t)),exposed=\(ownerExposedAt[id].map(String.init(describing:)) ?? "nil"),current=\(currentDestinationRect(id).map(NSStringFromRect) ?? "nil"),reason=\(destinationOwnerFailure?(id) ?? "adapter.visibility")}"
            }.joined(separator:";")
            forcedRetirements+=1
            Self.forcedRetirementCount+=1
            (modeProbe ?? (ModeSignposts.enabled ? ModeSignposts.Trace():nil))?.record("ModeFlightForcedRetire",detail:"lateMS=\((t-nominalEnd)*1000) railLateMS=\((t-ends)*1000) owners=\(reasons)")
            finish(landed:true)
        } else if usesOrrery,t >= ends+1,!ownerExposedAt.values.contains(where:{t-$0 < profile.frameInterval}) {
            // Stop polling without withdrawing the last visible owner. Native admission wakes the fence.
            if !waitingForOwner {modeProbe?.record("ModeFlightWaitingOwners",detail:(tokens.map {$0.token.id}+["me"]).filter {!canRetireOwner($0,at:t)}.joined(separator:","))}
            waitingForOwner=true;link?.isPaused=true;parkOwnerProbe()
        }
    }

    func destinationDidMount() {
        guard waitingForOwner,running,usesOrrery else {return}
        guard !ownerCommitCheckScheduled else {return}
        ownerCommitCheckScheduled=true
        let lease=ownerProbeGeneration
        func afterCommit(_ remaining:Int) {
            DispatchQueue.main.asyncAfter(deadline:.now()+self.profile.frameInterval) { [weak self] in
                guard let self,self.running,self.ownerProbeGeneration == lease else {return}
                self.checkDestinationOwners()
                if self.running,self.waitingForOwner,remaining>0 {afterCommit(remaining-1)}
                else {self.ownerCommitCheckScheduled=false}
            }
        }
        afterCommit(1)
    }
    #if M11_MODE_SELFTEST
    var verificationWaitingForOwner: Bool {waitingForOwner}
    var verificationOwnerFenceState:[String:Double] {ownerExposedAt.merging(["_last":lastAdvancedTime,"_interval":profile.frameInterval,"_ends":ends],uniquingKeysWith:{$1})}
    var verificationOwnerProbeActive:Bool {ownerProbe != nil}
    func verificationPoseVelocity(_ id:String,at time:Double)->CGPoint {
        let a=id == "me" ? orreryAvatarFrame(time):orreryPose(id,at:time)?.rect
        let b=id == "me" ? orreryAvatarFrame(time+0.0001):orreryPose(id,at:time+0.0001)?.rect
        guard let a,let b else {return .zero}
        return CGPoint(x:(b.midX-a.midX)/0.0001,y:(b.midY-a.midY)/0.0001)
    }
    var verificationInitialLead: Double {began-CACurrentMediaTime()}
    #endif

    /// An admission can come after its flight has landed: 1.08 s against 0.74 s on a 14-minute conversation. Starting the
    /// flight then put every orb back where it began and flew them all again (board 10-31).
    func landedAlready(toOrganic: Bool) -> Bool {
        guard landedLeg == toOrganic else { return false }
        landedLeg = nil
        onFrame?(.infinity)
        return true
    }
    private func finish(landed: Bool = false) {
        let retirementTrace=usesOrrery && ModeSignposts.enabled ? (modeProbe ?? ModeSignposts.Trace()):nil
        retirementTrace?.record("ModeFlightRetirementWork",.begin)
        defer {retirementTrace?.record("ModeFlightRetirementWork",.end)}
        let atomicFinish=usesOrrery
        if atomicFinish { CATransaction.begin();CATransaction.setDisableActions(true) }
        defer { if atomicFinish { CATransaction.commit() } }
        if landed,usesOrrery { onFrame?(.infinity) }
        dockBridge?.endModeFlight(landed:landed)
        landedLeg = landed ? toOrganic : nil
        clearServerMotion()
        modeProbe?.record("ModeFlightEnd")
        running = false
        stopOwnerProbe();waitingForOwner=false;serverExtensionGeneration &+= 1;serverHorizon=nil
        targetShift = nil
        link?.isPaused = true
        if usesOrrery,prioritizesInitialSubmit {
            // Retain the already allocated native carriers for the next key, including a cold picture path.
            for node in tokens {
                if let (_,old)=warmTokens.removeValue(forKey:node.token.id) {disposeToken(old)}
                node.carrier.container.alphaValue=0;node.carrier.ink.alphaValue=0;node.orb.setOpacity(0)
                node.carrier.glyphStage?.line.isHidden=true
                warmTokens[node.token.id]=(warmKey(node.token),node)
            }
            tokens=[]
        } else {clearTokens()}
        avatar.isHidden = true; avatarShown = false
        composerGlass.isHidden = true; composerTrip = nil
        avatarTrail.reset(); avatarTrail.isHidden = true; avatarFace.glyphHidden = false
        view.isHidden = true
        onPresentationFrame?(.infinity, profile)
        if !usesOrrery || !landed { onFrame?(.infinity) }
    }

    private func clearTokens() {
        for t in tokens { disposeToken(t) }
        tokens = []
    }

    func sample(at elapsed: Double, profile: DisplayProfile) {
        self.profile = profile
        frame(elapsed)
    }

    private func frame(_ t: Double,refreshSemantic: Bool = true) {
        let frameStarted=onExposureCost == nil ? 0:CACurrentMediaTime()
        defer {if usesOrrery {onExposureCost?("frame.total",CACurrentMediaTime()-frameStarted)}}
        var appearanceNeedsRefresh=false
        let sharesDisplayCommit=usesOrrery
        let previousActions=CATransaction.disableActions()
        if !sharesDisplayCommit {CATransaction.begin()}
        CATransaction.setDisableActions(true)
        // Publish native visibility first. Keep one commit of overlap while native glass resumes drawing.
        let publishStarted=onExposureCost == nil ? 0:CACurrentMediaTime()
        if usesOrrery {
            let coverage=rowCoverage?()
            for node in tokens {
                let revision=node.carrier.glyphStage?.coverageRevision
                node.carrier.glyphStage?.coverage=coverage
                if revision != node.carrier.glyphStage?.coverageRevision {appearanceNeedsRefresh=true}
            }
            onFrame?(t)
        }
        if usesOrrery {onExposureCost?("owners.publish",CACurrentMediaTime()-publishStarted)}
        let previousVisibility=frameOwnerVisibility
        if usesOrrery {frameOwnerVisibility=Dictionary(uniqueKeysWithValues:(tokens.map {$0.token.id}+["me"]).map {($0,destinationOwnerVisible?($0) ?? true)})}
        defer {frameOwnerVisibility=previousVisibility}
        if usesOrrery,destinationOwnerVisible != nil {
            for id in tokens.map({$0.token.id})+["me"] {
                if ownerVisible(id) { if ownerExposedAt[id] == nil { ownerExposedAt[id] = t } }
                else { ownerExposedAt.removeValue(forKey:id) }
            }
        }
        if usesOrrery { pruneConversations() }
        let process = exposureEnabled && !reducesMotion
        // D 0.3 keeps LL on the flight plane through T. Legacy mode retains the original spring-tail handoff.
        if avatarShown, t >= avatarHandoff, !usesOrrery || canRetireOwner("me",at:t) { avatarShown = false; avatar.isHidden = true;if usesOrrery {retiredOwners.insert("me")} }
        let shift = usesOrrery ? CGPoint.zero : (targetShift?() ?? .zero)
        let oldShift: CGPoint
        if let last = previousShift, t > last.time, t - last.time <= 1.5 * profile.frameInterval { oldShift = last.point }
        else { oldShift = shift }
        previousShift = (t, shift)
        if avatarShown {
            ModeSignposts.current?.record("ModeAvatarFrame",.begin)
            defer{ModeSignposts.current?.record("ModeAvatarFrame",.end)}
            let costStart = onExposureCost == nil ? 0 : CACurrentMediaTime()
            let k = CGFloat(min(1, t / avatarHandoff))
            let authoredAvatar=orreryAvatarFrame(t) ?? avatarRect.sample(t).rect
            let r = trackedOwnerRect("me",authoredAvatar,at:t).offsetBy(dx: shift.x * k, dy: shift.y * k), g = usesOrrery ? CGFloat(min(1,max(0,orreryAvatarGlass.sample(orreryTime(t)).value))) : CGFloat(min(1, max(0, avatarGlass.sample(t).value)))
            let d = max(1, r.width)
            let c = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            let oldT = max(0, t - profile.frameInterval)
            let old = (orreryAvatarFrame(oldT) ?? avatarRect.sample(oldT).rect)
                .offsetBy(dx: oldShift.x * CGFloat(min(1, oldT / avatarHandoff)), dy: oldShift.y * CGFloat(min(1, oldT / avatarHandoff)))
            let before = CGRect(x: old.midX - old.width / 2, y: old.midY - old.width / 2, width: old.width, height: old.width)
            let painted = usesOrrery ? c : M10ModeExposure.stretch(c, before, profile: profile, enabled: process)
            let avatarDrawing=usesOrrery ? CGRect(x:avatarCarrier.plane.bounds.midX-painted.width/2,y:avatarCarrier.plane.bounds.midY-painted.height/2,width:painted.width,height:painted.height):painted
            if !usesOrrery || avatar.frame != avatarDrawing {avatar.frame=avatarDrawing}
            serverCounter(avatarCarrier.plane,centre:CGPoint(x:c.midX,y:c.midY),authored:CGPoint(x:authoredAvatar.midX,y:authoredAvatar.midY));avatar.cornerRadius = min(painted.width, painted.height) / 2
            let avatarBounds=CGRect(origin:.zero,size:painted.size)
            if !usesOrrery || avatarContent.frame != avatarBounds {avatarContent.frame=avatarBounds}
            let local = c.offsetBy(dx: -painted.minX, dy: -painted.minY)
            if !usesOrrery || avatarFace.frame != local {avatarFace.frame=local}
            avatarFace.glassness = g
            if !usesOrrery || avatarTrail.frame != avatarContent.bounds {avatarTrail.frame=avatarContent.bounds}
            avatarTrail.update(now: local, earlier: before.offsetBy(dx: -painted.minX, dy: -painted.minY), profile: profile, enabled: process && !usesOrrery)
            avatarFace.glyphHidden = avatarTrail.exposure.count > 1
            avatarTrail.isHidden = !avatarFace.glyphHidden
            onExposureSample?(.init(id: "me", time: t, now: c, earlier: before, painted: painted, exposure: avatarTrail.exposure,
                                    instanceTransform: avatarTrail.trail.layer.instanceTransform))
            onExposureCost?("me", CACurrentMediaTime() - costStart)
        }
        let strip = view.bounds.height - 20
        for i in tokens.indices {
            ModeSignposts.current?.record("ModeOrbFrame",.begin,detail:tokens[i].token.id)
            defer{ModeSignposts.current?.record("ModeOrbFrame",.end,detail:tokens[i].token.id)}
            let costStart = onExposureCost == nil ? 0 : CACurrentMediaTime()
            if refreshSemantic,usesOrrery, let endpoint = endpointOrb?(tokens[i].token.id), !tokens[i].orb.hasSameDragConfiguration(as:endpoint) {
                let node=tokens[i]
                if let copy=endpoint.prepareDragDecoration(glassView:node.glass) {
                    // Native material/carrier identities survive an admission's semantic drawing change.
                    // Replacing them here reintroduced the same empty material frame as a reversal.
                    let decoration=node.glass.contentView
                    node.orb.dispose();node.trail.reset()
                    node.trail.subviews.forEach { $0.removeFromSuperview() }
                    node.glass.contentView=Plane()
                    if let decoration {decoration.frame=CGRect(x:0,y:0,width:32,height:32);node.trail.addSubview(decoration)}
                    copy.setCanvasSize(view.bounds.size)
                    node.carrier.plane.addSubview(copy.backView,positioned:.below,relativeTo:node.carrier.container)
                    node.carrier.plane.addSubview(copy.frontView,positioned:.above,relativeTo:node.carrier.container)
                    node.glass.style=endpoint.glassView.style;node.glass.tintColor=endpoint.glassView.tintColor
                    tokens[i].orb=copy;node.carrier.decorationVisible=nil;node.carrier.orbGeometry=nil
                    if serverActive { appearanceNeedsRefresh=true }
                }
            }
            let (token, glass, orb, trail, _, carrier) = tokens[i]
            if refreshSemantic {carrier.glyphStage?.refresh(conversation:token.conversation,scale:view.window?.backingScaleFactor ?? 2)}
            guard let authoredFrame = tokenFrame(token, at: t, strip: strip, shift: shift) else {
                if carrier.container.alphaValue != 0 {carrier.container.alphaValue=0}
                carrier.container.layer?.removeAnimation(forKey:"mode.orrery.appearance");glass.isHidden = true
                if !usesOrrery || carrier.decorationVisible != false {orb.setOpacity(0);carrier.decorationVisible=false}
                carrier.glyphStage?.line.isHidden=true;if usesOrrery {retiredOwners.insert(token.id)};continue
            }
            let r=trackedOwnerRect(token.id,authoredFrame,at:t)
            let before = tokenFrame(token, at: max(0, t - profile.frameInterval), strip: strip, shift: oldShift) ?? r
            let painted = usesOrrery ? r : M10ModeExposure.stretch(r, before, profile: profile, enabled: process)
            glass.isHidden = false
            // New glass in its own container keeps default corners until its frame changes: a rounded square for the
            // 230 ms before a column-top orb leaves (board 10-31). So the first frame is a hair off.
            let drawing = usesOrrery ? CGRect(x:carrier.plane.bounds.midX-painted.width/2,y:carrier.plane.bounds.midY-painted.height/2,width:painted.width,height:painted.height):painted
            let glassDrawing=(carrier.shaped || usesOrrery) ? drawing:drawing.insetBy(dx:-0.05,dy:-0.05)
            if !usesOrrery || glass.frame != glassDrawing {glass.frame=glassDrawing}
            let radius=min(painted.width,painted.height)/2
            if !usesOrrery || glass.cornerRadius != radius {glass.cornerRadius=radius}
            carrier.shaped = true
            let trailBounds=CGRect(origin:.zero,size:painted.size)
            if !usesOrrery || trail.frame != trailBounds {trail.frame=trailBounds}
            if usesOrrery,carrier.ink.frame != drawing {carrier.ink.frame=drawing}
            let local = r.offsetBy(dx: -painted.minX, dy: -painted.minY)
            if !usesOrrery || carrier.orbGeometry?.frame != drawing || carrier.orbGeometry?.content != local {
                orb.setFrame(drawing,contentFrame:local);carrier.orbGeometry=(drawing,local)
            }
            serverCounter(carrier.plane,centre:CGPoint(x:r.midX,y:r.midY),authored:CGPoint(x:authoredFrame.midX,y:authoredFrame.midY))
            let authored = orreryPose(token.id, at:t)
            let leafAlpha=usesOrrery ? 1:(authored.map {CGFloat($0.glass)} ?? 1)
            if !usesOrrery || glass.alphaValue != leafAlpha {glass.alphaValue=leafAlpha}
            if !usesOrrery || carrier.decorationVisible != true {orb.setOpacity(1);carrier.decorationVisible=true}
            if let authored, let plan = orreryPlans[token.id] {
                let atDestination=orreryClock.rate<0 ? orreryTime(t)<=0:authored.landed
                let nativeOwns=atDestination && destinationOwnerVisible != nil && ownerVisible(token.id) && ownerGeometryMatches(token.id,at:t)
                if nativeOwns {
                    // Native visibility and its complementary flying contribution are published atomically.
                    // Keep the carrier alive through the exposure fence, without adding a second material.
                    nativeAppearanceOwners.insert(token.id)
                    for part in [carrier.container,carrier.ink,orb.backView,orb.frontView]+(carrier.glyphStage.map {[$0.line]} ?? []) {
                        part.layer?.removeAnimation(forKey:"mode.orrery.appearance")
                    }
                } else if nativeAppearanceOwners.remove(token.id) != nil {appearanceNeedsRefresh=true}
                let alpha=nativeOwns ? 0:CGFloat(authored.glass)
                for part in [carrier.container,carrier.ink,orb.backView,orb.frontView] where part.alphaValue != alpha {part.alphaValue=alpha}
                carrier.plane.layer?.zPosition = authored.depth
                carrier.glyphStage?.coverageHorizontalOffset=rowSidebarOffset?(began+t) ?? 0
                carrier.glyphStage?.sample(authored,row:visibleRow(corrected(plan.row,by:rowCorrections[token.id],at:t),at:t))
                if nativeOwns {carrier.glyphStage?.line.layer?.opacity=0}
            }
            trail.update(now: local, earlier: before.offsetBy(dx: -painted.minX, dy: -painted.minY), profile: profile, enabled: process && !usesOrrery)
            tokens[i].logical = r
            onExposureSample?(.init(id: "planet." + token.id, time: t, now: r, earlier: before, painted: painted,
                                    exposure: trail.exposure, instanceTransform: trail.trail.layer.instanceTransform))
            onExposureCost?("planet." + token.id, CACurrentMediaTime() - costStart)
        }
        if let trip = composerTrip {
            ModeSignposts.current?.record("ModeComposerFrame",.begin)
            defer{ModeSignposts.current?.record("ModeComposerFrame",.end)}
            let costStart = onExposureCost == nil ? 0 : CACurrentMediaTime()
            let k = min(1, max(0, (t - trip.leave) / 0.30)), e = CGFloat(Self.ease(k))
            // Gone when the real bar shows (leave + 0.30), where it lies exactly: the product keeps it 0.16 s longer, but
            // there SwiftUI's glass merges with the bar's; two NSGlassEffectViews stack, and the bar's contents showed
            // blurred under it and then jumped clear (a recording, 10-29; DECISIONS #37).
            if t >= trip.leave + 0.30 { composerGlass.isHidden = true } else {
                let r = CGRect(x: trip.from.minX + (trip.to.minX - trip.from.minX) * e, y: trip.from.minY + (trip.to.minY - trip.from.minY) * e,
                               width: trip.from.width + (trip.to.width - trip.from.width) * e, height: trip.from.height + (trip.to.height - trip.from.height) * e)
                let oldK = min(1, max(0, (t - profile.frameInterval - trip.leave) / 0.30)), oldE = CGFloat(Self.ease(oldK))
                let before = CGRect(x: trip.from.minX + (trip.to.minX - trip.from.minX) * oldE,
                                    y: trip.from.minY + (trip.to.minY - trip.from.minY) * oldE,
                                    width: trip.from.width + (trip.to.width - trip.from.width) * oldE,
                                    height: trip.from.height + (trip.to.height - trip.from.height) * oldE)
                let painted = M10ModeExposure.stretch(r, before, profile: profile, enabled: process)
                composerGlass.isHidden = t < (composerShowsAt ?? (composerLeaveStage == -1 ? .infinity : trip.leave))
                composerGlass.frame = painted
                serverCounter(composerCarrier.plane,centre:CGPoint(x:r.midX,y:r.midY))
                // Preserve M9's authored corner at an unprocessed pose; a stretched capsule has semicircular ends.
                let originalRadius = 20 + (r.height / 2 - 20) * e
                composerGlass.cornerRadius = painted == r ? originalRadius : min(painted.width, painted.height) / 2
                onExposureSample?(.init(id: "composer", time: t, now: r, earlier: before, painted: painted,
                                        exposure: M10ModeExposure.sample(r, before, profile: profile, enabled: process),
                                        instanceTransform: CATransform3DIdentity))
                onExposureCost?("composer", CACurrentMediaTime() - costStart)
            }
        }
        if appearanceNeedsRefresh {
            let started=onExposureCost == nil ? 0:CACurrentMediaTime()
            installOrreryAppearance();onExposureCost?("appearance.rebuild",CACurrentMediaTime()-started)
        }
        // A display-link frame belongs to AppKit's one outer display commit. Popping an explicit
        // per-flight transaction can synchronously run the entire NSWindow/SwiftUI layout tree here.
        if sharesDisplayCommit {CATransaction.setDisableActions(previousActions)} else {CATransaction.commit()}
        dockBridge?.sampleModeFlight(elapsed:t)
        onPresentationFrame?(began + t, profile)
        if !usesOrrery { onFrame?(t) }
    }

    /// Where a planet is `t` seconds into the leg, or nil once it is gone.
    private func tokenFrame(_ token:Token,at t:Double,strip:CGFloat,shift:CGPoint = .zero,forward:Bool?=nil)->CGRect? {
        if usesOrrery,retiredOwners.contains(token.id) { return nil }
        if let pose = orreryPose(token.id,at:t) {
            // The real endpoint takes over in this same transaction. Never stack two glass circles.
            let returning = orreryClock.rate < 0
            let hidden = returning ? orreryTime(t) <= 0 : pose.landed
            if hidden && !correcting(token.id,at:t) && canRetireOwner(token.id,at:t) { return nil }
            return pose.rect.offsetBy(dx:CGFloat(pose.row)*(rowSidebarOffset?(began+t) ?? 0)+shift.x * CGFloat(min(1,t/max(0.001,avatarHandoff))),dy:shift.y * CGFloat(min(1,t/max(0.001,avatarHandoff))))
        }
        let direction=forward ?? toOrganic,tripDuration=direction ? 0.32:0.28
        let k=(t-token.start)/tripDuration
        let e = k <= 0 ? 0 : Self.ease(min(1, k))
        let a = CGPoint(x: token.from.midX, y: token.from.midY), b = CGPoint(x: token.to.midX + shift.x, y: token.to.midY + shift.y)
        // Dock tokens travel the window's bottom rail (AssembleFlight). A column's header orb starts and ends far above
        // it: by way of that rail it crossed the whole window, and its one big step stretched into a tall capsule (user
        // 10-30). It keeps to the band it lives in, until the user's own keyframes for these flights replace this.
        let band = token.id.hasPrefix("header.") ? min(a.y, b.y) : strip
        let p = Self.rail(a, b, strip: band, at: CGFloat(e))
        var size: CGFloat
        if direction {
            // Grows from its glyph to 22 over the first 0.08 s, keeps 22 to 2/3 of the way, then takes the target's size.
            if k <= 0 { size = token.from.width + (22 - token.from.width) * CGFloat(min(1, t / 0.08)) }
            else if e < 2.0 / 3 { size = 22 }
            else { size = 22 + (token.to.width - 22) * CGFloat((e - 2.0 / 3) * 3) }
        } else {
            // Keeps its orb's size, shrinks to 22 over the first third, then to the row's 16.
            if e < 1.0 / 3 { size = token.from.width + (22 - token.from.width) * CGFloat(e * 3) }
            else { size = 22 + (token.to.width - 22) * CGFloat((e - 1.0 / 3) * 1.5) }
        }
        if k >= 1 {
            let after = t - token.start - tripDuration
            if token.absorbed {
                // Taken in over 0.10 s.
                guard after < 0.10 else { return nil }
                // Arrival already has zero size velocity. The old fast-out curve restarted at a nonzero
                // velocity here (16 → 8 pt in the first 60 Hz frame), a spike even with exposure disabled.
                // Same 0.10 s and endpoints, but C1-continuous at both boundaries; a driver repair, not blur.
                size = token.to.width * CGFloat(1 - smoothstep(0, 1, after / 0.10))
            } else {
                // Held over the real orb for 0.16 s, then gone.
                guard after < 0.16 else { return nil }
                size = token.to.width
            }
        }
        size = max(0.5, size)
        return CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
    }

    /// cubic-bezier(0.22, 0.80, 0.25, 1), the flights' easing.
    static func ease(_ x: Double) -> Double {
        let x1 = 0.22, y1 = 0.80, x2 = 0.25, y2 = 1.0
        func bx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s }
        func by(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 { let m = (lo + hi) / 2; if bx(m) < x { lo = m } else { hi = m } }
        return by((lo + hi) / 2)
    }

    /// a → (a.x, strip) → (b.x, strip) → b, its corners rounded (radius min(24, leg in, leg out / 2)), at a fraction of its
    /// length; a corner counts as r × 1.11 of it.
    static func rail(_ a: CGPoint, _ b: CGPoint, strip: CGFloat, at f: CGFloat) -> CGPoint {
        let p1 = CGPoint(x: a.x, y: strip), p2 = CGPoint(x: b.x, y: strip)
        let leg1 = abs(strip - a.y), leg2 = abs(b.x - a.x), leg3 = abs(strip - b.y)
        let r1 = max(0, min(24, leg1, leg2 / 2)), r2 = max(0, min(24, leg2 / 2, leg3))
        // Pieces: straight down, corner, straight across, corner, straight up.
        let s1 = leg1 - r1, c1 = r1 * 1.11, s2 = max(0, leg2 - r1 - r2), c2 = r2 * 1.11, s3 = leg3 - r2
        let total = s1 + c1 + s2 + c2 + s3
        guard total > 0.001 else { return b }
        var d = f * total
        let dirY1: CGFloat = strip >= a.y ? 1 : -1, dirX: CGFloat = b.x >= a.x ? 1 : -1, dirY3: CGFloat = b.y >= strip ? 1 : -1
        func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ u: CGFloat) -> CGPoint {
            CGPoint(x: (1 - u) * (1 - u) * p0.x + 2 * (1 - u) * u * c.x + u * u * p1.x,
                    y: (1 - u) * (1 - u) * p0.y + 2 * (1 - u) * u * c.y + u * u * p1.y)
        }
        if d <= s1 { return CGPoint(x: a.x, y: a.y + dirY1 * d) }
        d -= s1
        if d <= c1 { return quad(CGPoint(x: a.x, y: strip - dirY1 * r1), p1, CGPoint(x: a.x + dirX * r1, y: strip), c1 > 0 ? d / c1 : 1) }
        d -= c1
        if d <= s2 { return CGPoint(x: a.x + dirX * (r1 + d), y: strip) }
        d -= s2
        if d <= c2 { return quad(CGPoint(x: b.x - dirX * r2, y: strip), p2, CGPoint(x: b.x, y: strip + dirY3 * r2), c2 > 0 ? d / c2 : 1) }
        d -= c2
        return CGPoint(x: b.x, y: strip + dirY3 * (r2 + min(d, s3)))
    }

    /// me between its two looks (AvatarFlight): the account gradient fading to 0.3 as it turns to glass, the initials
    /// shrinking a little and turning from white to the label colour.
    final class AvatarFace: NSView {
        var glyphHidden = false { didSet { if oldValue != glyphHidden { needsDisplay = true } } }
        var initials = NormieAccount.prototype.initials { didSet { needsDisplay = true } }
        var glassness: CGFloat = 0 { didSet { if abs(glassness - oldValue) > 0.001 { needsDisplay = true } } }
        private var cachedGradient:(CGFloat,NSGradient?)?
        private func gradient(at g:CGFloat)->NSGradient? {
            if let cachedGradient,cachedGradient.0 == g {return cachedGradient.1}
            let value=NSGradient(colors:[NSColor(srgbRed:0x78/255,green:0xd8/255,blue:0xa6/255,alpha:1-0.7*g),NSColor(srgbRed:0x2b/255,green:0x8a/255,blue:0x7a/255,alpha:1-0.7*g)])
            cachedGradient=(g,value);return value
        }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let g = glassness, r = bounds
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: r).addClip()
            gradient(at:g)?.draw(in:r,angle:-45)
            NSGraphicsContext.restoreGraphicsState()
            if !glyphHidden { drawGlyph(in: r) }
        }
        func drawGlyph(in r: CGRect) {
            let g = glassness
            let font = NSFont.systemFont(ofSize: max(1, r.width * (0.40 - 0.08 * g)), weight: .semibold)
            let color = g <= 0.5 ? NSColor.white : Look.ink
            let text = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: color])
            let s = text.size()
            text.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }

    final class AvatarGlyph: NSView {
        weak var face: AvatarFace?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { face?.drawGlyph(in: bounds) }
    }

    #if M10_MODE_SELFTEST || M11_MODE_SELFTEST
    /// The cost probe replays elapsed time. Re-arm the one-shot handoff so every loop includes me,
    /// rather than accidentally timing the cheap post-handoff path after the first loop.
    func verificationOrreryState(at elapsed: Double) -> [[String:Any]] {
        tokens.map { node in
            let pose = orreryPose(node.token.id,at:elapsed)
            let rowHasInk: Bool
            if let contents=node.carrier.glyphStage?.bitmap.contents {
                let image=contents as! CGImage
                let bytes=image.dataProvider!.data! as Data
                rowHasInk = bytes.enumerated().contains { $0.offset%4 == 3 && $0.element>0 }
            } else {rowHasInk=false}
            return ["id":node.token.id,"frame":[node.logical?.minX ?? node.glass.frame.minX,node.logical?.minY ?? node.glass.frame.minY,node.glass.frame.width,node.glass.frame.height],
                    "hidden":node.glass.isHidden,"glassOpacity":usesOrrery ? node.carrier.container.alphaValue:node.glass.alphaValue,
                    "rowFrame":NSStringFromRect(node.carrier.glyphStage?.line.frame ?? .zero),
                    "rowStationary":node.carrier.glyphStage?.line.superview === view,
                    "rowBitmapReady":rowHasInk,"rowHidden":node.carrier.glyphStage?.line.isHidden ?? true,
                    "rowIdentityMatches":node.carrier.glyphStage?.line.identity == NormieDrawing.identity(node.token.conversation),
                    "nativeOwnerVisible":ownerVisible(node.token.id),
                    "glassFiltered":node.glass.layer?.filters?.isEmpty == false,
                    "rowOpacity":node.carrier.glyphStage?.line.layer?.opacity ?? 0,
                    "effectiveGlyphOpacity":node.carrier.ink.alphaValue*node.trail.alphaValue*(node.trail.subviews.first?.alphaValue ?? 1),
                    "rowDepth":node.carrier.glyphStage?.line.layer?.zPosition ?? 0,
                    "rowFilterCount":node.carrier.glyphStage?.line.layer?.filters?.count ?? 0,
                    "copies":node.trail.trail.layer.instanceCount,
                    "rowRadius":node.carrier.glyphStage?.line.layer?.value(forKeyPath:"filters.m1131RowGaussian.inputRadius") as? Double ?? 0,
                    "depth":node.carrier.plane.layer?.zPosition ?? 0,"landed":arrived(node.token.id,at:elapsed),
                    "authoredVisible":pose?.visible ?? false,
                    "endpointConfigurationMatches":endpointOrb?(node.token.id).map { node.orb.hasSameDragConfiguration(as:$0) } ?? true]
        }
    }
    func verificationSetComposerTrip(from: CGRect,to: CGRect,leave: Double) {composerTrip=(from,to,leave)}
    func verificationRearmAvatar() { avatarShown = true; avatar.isHidden = false }
    var verificationContentIsSeparated: Bool {
        tokens.allSatisfy { $0.trail.superview === $0.carrier.ink && $0.glass.contentView !== $0.trail }
    }
    var verificationTrails: [(String,M10ModeGlyphTrail)] { [("me",avatarTrail)] + tokens.map { ("planet."+$0.token.id,$0.trail) } }
    var verificationGlass: [(String, NSGlassEffectView)] {
        [("me",avatar),("composer",composerGlass)] + tokens.map { ("planet."+$0.token.id,$0.glass) }
    }
    /// At an untreated pose, temporarily restore the exact pre-M10 view mounts. This compares the new
    /// one-copy host against M9's direct contentView path, not merely the same new code with a flag off.
    func verificationOriginalMounts() -> () -> Void {
        avatar.contentView = avatarFace
        var originals: [(NSGlassEffectView, M10ModeGlyphTrail, NSView, CGRect)] = []
        for t in tokens {
            if let body = t.trail.subviews.first {
                originals.append((t.glass,t.trail,body,body.frame));t.glass.contentView = body
            }
        }
        return {
            self.avatar.contentView = self.avatarContent
            self.avatarContent.addSubview(self.avatarFace,positioned:.below,relativeTo:self.avatarTrail)
            for (glass,trail,body,frame) in originals { glass.contentView=trail;trail.addSubview(body);body.frame=frame }
        }
    }

    func verificationFocus(_ id:String)->()->Void {
        var states:[(NSView,Bool)]=[]
        func set(_ view:NSView,_ show:Bool) {states.append((view,view.isHidden));view.isHidden = !show}
        set(avatar,id == "me");set(composerGlass,id == "composer")
        for token in tokens {let show=id == "planet."+token.token.id;set(token.glass,show);set(token.orb.backView,show);set(token.orb.frontView,show)}
        return {for (view,hidden) in states {view.isHidden=hidden}}
    }

    /// Windowless renderer: borrow the ACTUAL non-glass layer subtrees, replacing only WindowServer glass
    /// with an explicitly labelled proxy. The caller restores every borrowed layer after rendering.
    func verificationPaint(into root: CALayer, scale: CGFloat, elapsed: Double, includeAvatar: Bool = true, onlyID:String?=nil) -> () -> Void {
        var borrowed: [(CALayer, CALayer, UInt32)] = []
        func allowed(_ glass:NSGlassEffectView)->Bool {
            guard let onlyID else{return true}
            if glass === avatar{return onlyID == "me"}
            if glass === composerGlass{return onlyID == "composer"}
            return tokens.contains{$0.glass === glass && onlyID == "planet."+$0.token.id}
        }
        func plate(_ r: CGRect, radius: CGFloat, opacity: Float = 1, depth: CGFloat = 0) {
            let proxy = CAShapeLayer()
            proxy.opacity = opacity; proxy.zPosition = depth
            proxy.path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            proxy.fillColor = NSColor(white: 0.24, alpha: 0.60).cgColor
            proxy.strokeColor = NSColor(white: 0.7, alpha: 0.30).cgColor; proxy.lineWidth = 0.5
            root.addSublayer(proxy)
        }
        // This isolated checker has no Organic/Normie destination scene. Give the component its real
        // endpoint stand-ins: otherwise hiding the flight would artificially delete the bar/me/orb.
        if (onlyID == nil || onlyID == "composer"),let trip = composerTrip, composerGlass.isHidden, elapsed >= trip.leave + 0.30 {
            plate(trip.to, radius: trip.to.height / 2)
        }
        if includeAvatar,(onlyID == nil || onlyID == "me"),avatar.isHidden, elapsed >= avatarHandoff {
            let r = avatarRect.target
            let end = CGRect(x: r.midX-r.width/2, y: r.midY-r.width/2, width:r.width,height:r.width)
            plate(end,radius:r.width/2)
            let face = AvatarFace(frame:CGRect(origin:.zero,size:end.size));face.initials=avatarFace.initials;face.glassness=toOrganic ? 1:0
            let l=CALayer();l.contents=NativeViewBitmap.capture(face,scale:scale);l.frame=end;root.addSublayer(l)
        }
        if !toOrganic {
            // Normie's destination rows are already there under its incoming planets (WindowShell.toNormie).
            for t in tokens where onlyID == nil || onlyID == "planet."+t.token.id {
                let glyph: NSView
                if usesOrrery {
                    let row=NormieSidebarIdentity(frame:CGRect(origin:.zero,size:t.token.to.size));row.identity=NormieDrawing.identity(t.token.conversation);glyph=row
                } else {
                    let row=NormiePlanetView(frame:CGRect(origin:.zero,size:t.token.to.size));row.identity=NormieDrawing.identity(t.token.conversation);glyph=row
                }
                let l=CALayer();l.contents=NativeViewBitmap.capture(glyph,scale:scale);l.frame=usesOrrery ? t.token.to.offsetBy(dx:-3,dy:-1):t.token.to
                l.opacity=Float(min(1,max(0,elapsed/0.22)));root.addSublayer(l)
            }
        }
        for glass in (includeAvatar ? [avatar, composerGlass] : [composerGlass]) + tokens.map(\.glass) where !glass.isHidden && allowed(glass) {
            let depth: CGFloat = usesOrrery ? (glass === avatar ? 6 : tokens.first { $0.glass === glass }?.carrier.plane.layer?.zPosition ?? 0) : 0
            let world: CGRect
            if usesOrrery,glass === avatar {world=orreryAvatarFrame(elapsed) ?? glass.convert(glass.bounds,to:view)}
            else if usesOrrery,glass !== composerGlass {world=tokens.first {$0.glass === glass}?.logical ?? glass.convert(glass.bounds,to:view)}
            else {world=glass.frame}
            let materialAlpha=usesOrrery ? (tokens.first {$0.glass === glass}?.carrier.container.alphaValue ?? glass.alphaValue):glass.alphaValue
            plate(world, radius: glass.cornerRadius, opacity:Float(materialAlpha),depth:depth)
            if glass === avatar {
                // Native backing-layer contentsAreFlipped is WindowServer-specific. Draw the same native
                // glyph cache at the actual replica matrices, as plain readback layers, instead of borrowing
                // AppKit's private backing layer into an unrelated CARenderer hierarchy.
                let face=CALayer();face.contents=NativeViewBitmap.capture(avatarFace,scale:scale)
                face.frame=avatarFace.frame.offsetBy(dx:world.minX,dy:world.minY);face.zPosition=depth;root.addSublayer(face)
                if avatarFace.glyphHidden {
                    let cache=avatarTrail.flattenedImage!
                    let transform=CATransform3DGetAffineTransform(avatarTrail.trail.layer.instanceTransform)
                    var box=avatarFace.frame
                    for _ in 0..<avatarTrail.exposure.count {
                        let l=CALayer();l.contents=cache;l.opacity=Float(avatarTrail.exposure.alpha)
                        l.frame=box.offsetBy(dx:world.minX,dy:world.minY);root.addSublayer(l)
                        box=box.applying(transform)
                    }
                }
                continue
            }
            let contentLayer = usesOrrery ? (tokens.first { $0.glass === glass }?.trail.layer ?? glass.contentView?.layer) : glass.contentView?.layer
            guard let layer = contentLayer, let parent = layer.superlayer,
                  let index = parent.sublayers?.firstIndex(of: layer) else { continue }
            borrowed.append((layer, parent, UInt32(index)))
            let host = CALayer(); host.anchorPoint = .zero; host.position = world.origin
            host.bounds = CGRect(origin: .zero, size: glass.frame.size)
            host.zPosition=depth
            if usesOrrery {host.opacity=Float(tokens.first { $0.glass === glass }?.carrier.ink.alphaValue ?? 1)}
            root.addSublayer(host); host.addSublayer(layer)
        }
        for t in tokens where t.glass.isHidden && !t.token.absorbed && arrived(t.token.id,at:elapsed) {
            plate(t.token.to,radius:t.token.to.height/2)
            let l = usesOrrery ? t.trail.layer! : t.orb.glassView.contentView!.layer!
            if let parent=l.superlayer,let index=parent.sublayers?.firstIndex(of:l) {
                borrowed.append((l,parent,UInt32(index)))
                t.orb.setOpacity(1)
                let host=CALayer();host.anchorPoint = .zero;host.position=t.token.to.origin
                root.addSublayer(host);host.addSublayer(l)
            }
        }
        if usesOrrery {
            for token in tokens where onlyID == nil || onlyID == "planet."+token.token.id {
                guard let line = token.carrier.glyphStage?.line, !line.isHidden, let layer=line.layer else { continue }
                // AppKit backing contents are WindowServer-specific. Draw the same native identity once,
                // then copy the actual single-layer Gaussian/opacity/scale into this labelled readback host.
                let glyph=NormieSidebarIdentity(frame:CGRect(origin:.zero,size:line.bounds.size));glyph.identity=line.identity
                let ink=CALayer();ink.contents=NativeViewBitmap.capture(glyph,scale:scale)
                ink.bounds=layer.bounds;ink.anchorPoint=layer.anchorPoint;ink.position=layer.position
                ink.transform=layer.transform;ink.opacity=layer.opacity;ink.filters=layer.filters
                ink.zPosition=token.carrier.plane.layer?.zPosition ?? 7;root.addSublayer(ink)
            }
        }
        let hidden = tokens.filter { $0.glass.isHidden }.map(\.orb)
        return {
            for (layer, parent, index) in borrowed { parent.insertSublayer(layer, at: index) }
            for orb in hidden { orb.setOpacity(0) }
        }
    }
    #endif
}

/// Native AppKit order AND compositor z-order. Re-admitting a cached source cannot cover the flight.
enum ModePlaneOrder {
    static let target:CGFloat=0, sidebar:CGFloat=10, source:CGFloat=20, flight:CGFloat=30
}

#if M11_MODE_SELFTEST
extension ModeFlight {
    /// The never-ordered window supplies no CADisplayLink callbacks. Use the identical compositor-tick
    /// prelude, including the legacy composer's commit stages, before the shared production advance.
    func verificationDisplayAdvance(at time:Double) {
        if let hz=Double(ProcessInfo.processInfo.environment["M1131_SIM_HZ"] ?? ""),hz>0 {profile.frameInterval=1/hz}
        if composerLeaveStage == -1,let planned=composerPlannedLeave,time>=planned-0.034 {composerLeaveStage=2}
        if composerLeaveStage>0 {lateComposerTick(at:time)}
        advance(at:time)
    }
}
#endif


#if M11_MODE_SELFTEST
extension ModeFlight {
    func verificationDropPreparedResources() {
        precondition(!running)
        for (_,node) in warmTokens.values {disposeToken(node)}
        warmTokens.removeAll();serverCache=nil
    }
}
#endif
