import Foundation
import CoreGraphics

/// New trash-only tuning from OrbTrash.dc.html:201,215,217-227. Existing product springs stay untouched.
enum OrbTrashParameters {
    struct Tuning: Equatable { var response: Double; var damping: Double; init(_ r: Double, _ d: Double) { response = r; damping = d } }
    static let enter = Tuning(0.5, 0.82), exit = Tuning(0.34, 1), arm = Tuning(0.24, 0.86)
    static let follow = Tuning(0.07, 1), back = Tuning(0.34, 0.78), size = Tuning(0.16, 0.9)
    static let lidOpen = Tuning(0.2, 0.9), lidShut = Tuning(0.3, 0.5)
    static let sink = Tuning(0.2, 0.92), sinkSize = Tuning(0.22, 1), sinkGlyph = Tuning(0.09, 1)
    static let emergeGlyph = Tuning(0.14, 1) // OrbTrash.dc.html:210,454, distinct from SINK_G.
    static let swallow = Tuning(0.3, 0.6), morphTop = Tuning(0.44, 0.84), morphBottom = Tuning(0.5, 0.9)
    static let morphWidth = Tuning(0.5, 0.84), morphOut = Tuning(0.3, 1)
    static let trashDiameter = 44.0, carriedDiameter = 38.0, armedDiameter = 30.0
    static let armRadius = 60.0, armOut = 74.0, armBand = 30.0, reorderBand = 44.0
    static let magnet = 0.22, lean = 6.0, nubRadius = 8.0, nubReach = 0.33
    // Native glass: only held, armed carriers have nubs. The board's goo reach is not used here.
    static let neckFullGap = 6.0, neckThinGap = 10.0, neckThinEnd = 14.0, neckZeroGap = 16.0
    static let neckThinRadius = 3.0, neckMinDiameter = 4.0, neckMaxNubGap = 4.0
    static let neckBoundaryDiameter = 6.0
    static let lidDegrees = 24.0, lidMinimum = -6.0, haloRest = 0.2, haloArmed = 0.5, haloScale = 1.16, redTint = 0.16
    static let sinkDone = 3.0, swallowVelocity = 7.0, swallowDiameter = 6.0, swallowIcon = 0.05
    static let emergeDiameter = 6.0, flightTime = 0.58, sinkZ = 25.0, emergeZ = 30.0
    static let bubbleWidth = 288.0, bubbleHeight = 114.0, bubbleRadius = 18.0, bubbleSeed = 20.0
    static let tailWidth = 30.0, tailHeight = 26.0, tailInset = 8.0
    static let bottomDelay = 0.03, widthDelay = 0.05, contentIn = 0.2, contentOut = 0.08, contentStagger = 0.16
    static let contentBlur = 6.0, contentRise = 4.0, retireHold = 0.25, morphHold = 0.05
    static let disabledMessageTime = 2.4, toastTime = 5.0, educationTime = 6.0
    // Geometry policy: separation, connection overlap and classification hysteresis have different jobs.
    static let separatedGap = 12.0, connectedOverlap = 1.0
}

struct OrbTrashMotion {
    private var spring: Spring
    private var start = 0.0
    init(_ value: Double) { spring = .rest(value) }
    init(_ value: Double, velocity: Double, at time: Double) {
        spring = .init(from:value,to:value,velocity:velocity,response:0.07,damping:1,epsilon:0.0001)
        start = time
    }
    var target: Double { spring.to }
    func sample(_ time: Double) -> (value: Double, velocity: Double) { spring.sample(max(0, time - start)) }
    mutating func aim(_ target: Double, at time: Double, tuning: OrbTrashParameters.Tuning, delay: Double = 0) {
        guard target != spring.to else { return }
        let old = sample(time)
        spring = .init(from: old.value, to: target, velocity: old.velocity,
                       response: tuning.response, damping: tuning.damping, epsilon: 0.0001)
        start = time + delay
    }
    mutating func impulse(_ velocity: Double, at time: Double, tuning: OrbTrashParameters.Tuning) {
        let old = sample(time)
        spring = .init(from: old.value, to: 0, velocity: old.velocity + velocity,
                       response: tuning.response, damping: tuning.damping, epsilon: 0.0001)
        start = time
    }
    func moving(_ time: Double) -> Bool { time - start < spring.duration }
}

struct OrbTrashGeometry: Equatable {
    var bounds: CGRect
    var lastSlotX: Double
    var dockBaseline: Double
    var target: CGPoint { .init(x: min(bounds.maxX - 32, max(bounds.minX + 32, lastSlotX)), y: min(bounds.maxY - 32, max(bounds.minY + 32, dockBaseline - 68))) }
    var offX: Double { bounds.maxX + 40 }
    var armBandY: Double { dockBaseline - OrbTrashParameters.armBand }
    func bubble(above can: CGRect) -> CGRect? {
        let width = min(OrbTrashParameters.bubbleWidth, bounds.width - 20)
        let bottom = can.minY - OrbTrashParameters.separatedGap - OrbTrashParameters.tailHeight + OrbTrashParameters.tailInset
        let rect = CGRect(x: min(bounds.maxX - 10 - width, max(bounds.minX + 10, target.x + 34 - width)),
                          y: bottom - OrbTrashParameters.bubbleHeight, width: width, height: OrbTrashParameters.bubbleHeight)
        return rect.minY >= bounds.minY + 10 && width >= 220 ? rect : nil
    }
}

struct OrbTrashState {
    enum Phase: String { case hidden, appearing, carrying, armed, disabled, sinking, educating, emerging, retiring }
    enum Owner: String { case source, trash, none }
    enum Event {
        case tick, begin(UUID), move, release(UUID), committed(UUID, session: UUID), menuRemoved(UUID), rejected, cancel, dismiss, undo(UUID, target: CGRect), retire
    }
    struct Input {
        var event: Event = .tick
        var semanticCenter: CGPoint
        var nativeCarrier: CGRect
        // Origin and size rates from the last physical source write, not semantic-pointer velocity.
        var nativeVelocity: CGRect = .zero
        // Window containment uses the physical pointer; arm distance uses semanticCenter separately.
        var inWindow = true
        var allowsArming = true
        var removable = true
        // Minimum clearance of complete unrelated physical contours, including any Tide tail.
        var sourceClearance = Double.infinity
        var prompt: OrganicRemoveJournal.Prompt? = nil
        var geometry: OrbTrashGeometry
    }
    struct Pose: Equatable {
        var phase: Phase
        var can: CGRect
        var carrier: CGRect
        var carrierVelocity: CGRect
        var owner: Owner
        var nubs: [CGRect]
        var bubble: CGRect?
        var tail: [CGPoint]
        var toast: CGRect?
        var lidDegrees: Double
        var haloAlpha: Double
        var haloScale: Double
        var redTint: Double
        var iconAlpha: Double
        var iconScale: Double
        var glyphAlpha: Double
        var glyphBlur: Double
        var contentAlpha: Double
        var carrierZ: Double
        var hidden: Bool
    }
    enum Request: Equatable {
        case handoff(Owner, UUID, CGRect, CGRect)
        case remove(UUID)
        case returnToOrigin(UUID)
        case presentPrompt(UUID)
    }
    struct Output { var pose: Pose; var requests: [Request]; var disabledMessage: String?; var needsFrames: Bool }
    private(set) var phase: Phase = .hidden
    private(set) var owner: Owner = .source
    private var session: UUID?
    private var carrierToken: UUID?
    private var receipt: UUID?
    private var lastTime = -Double.infinity
    private var entry = OrbTrashMotion(0), arm = OrbTrashMotion(0), lid = OrbTrashMotion(0), gulp = OrbTrashMotion(0)
    private var ox = OrbTrashMotion(0), oy = OrbTrashMotion(0), diameter = OrbTrashMotion(38), height = OrbTrashMotion(38), glyph = OrbTrashMotion(1)
    private var top = OrbTrashMotion(0), bottom = OrbTrashMotion(0), width = OrbTrashMotion(0)
    private var disabledNoticeUntil = -Double.infinity
    private var disabledNotified = false
    private var releaseRequested = false
    private var retireAt: Double?
    private var contentStart: Double?
    private var emergeArmed=false
    private var flightStart = 0.0
    private var flightOrigin = CGPoint.zero
    private var flightTarget = CGRect.zero
    private var lastCan: CGRect?
    private var neckWasVisible = false
    private var promptVisible = false

    mutating func step(_ input: Input, at suppliedTime: Double) -> Output {
        let time = suppliedTime.isFinite ? max(lastTime.isFinite ? lastTime : suppliedTime, suppliedTime) : (lastTime.isFinite ? lastTime : 0)
        lastTime = time
        let k = OrbTrashParameters.self, g = input.geometry
        var requests: [Request] = []
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        switch input.event {
        case .begin(let token):
            neckWasVisible = false
            session = token; carrierToken = token; receipt = nil; phase = .appearing; owner = .source
            disabledNotified = false; disabledNoticeUntil = -.infinity; releaseRequested = false; retireAt = nil
            entry.aim(1, at: time, tuning: k.enter)
            ox = .init(input.nativeCarrier.midX); oy = .init(input.nativeCarrier.midY)
            diameter = .init(input.nativeCarrier.width); height = .init(input.nativeCarrier.height); glyph = .init(1)
            promptVisible = false; contentStart = nil
        case .committed(let id, let token):
            if token == session && releaseRequested && phase == .armed { receipt = id; phase = .sinking }
        case .menuRemoved(let id):
            receipt=id;phase = .educating;owner = .none;promptVisible=true
            entry.aim(1,at:time,tuning:k.enter);requests.append(.presentPrompt(id))
        case .undo(let requested, let target):
            if let receipt, receipt == requested {
                phase = .emerging; owner = .trash; promptVisible = false;emergeArmed=true
                carrierToken = receipt
                retireAt = nil; entry.aim(1,at:time,tuning:k.enter)
                flightStart = time; flightTarget = target
                flightOrigin = lastCan.map { .init(x:$0.midX,y:$0.midY) } ?? g.target
                ox = .init(flightOrigin.x); oy = .init(flightOrigin.y); diameter = .init(k.emergeDiameter); height = .init(k.emergeDiameter); glyph = .init(0)
                requests.append(.handoff(.trash, receipt, .init(x: flightOrigin.x - 3, y: flightOrigin.y - 3, width: 6, height: 6), .zero))
            }
        case .cancel, .rejected:
            if phase != .sinking && phase != .educating && phase != .emerging {
                if let session { requests.append(.returnToOrigin(session)) }
                phase = .retiring; retireAt = time + k.retireHold; releaseRequested = true
            }
        case .dismiss:
            if phase == .educating { phase = .retiring; retireAt = time + k.retireHold }
            promptVisible = false
        case .retire:
            phase = .hidden; owner = .none; session = nil; carrierToken = nil; receipt = nil
            promptVisible = false; entry = .init(0); arm = .init(0); lid = .init(0)
        default: break
        }
        if [.appearing, .carrying, .armed, .disabled].contains(phase) {
            let near = distance(input.semanticCenter, g.target)
            let arrived = abs(entry.sample(time).value - 1) * (g.offX - g.target.x) <= 1
            let canArm = input.inWindow && input.allowsArming && arrived && input.removable
            let armed = canArm && (phase == .armed ? near <= k.armOut : near < k.armRadius && input.semanticCenter.y < g.armBandY)
            phase = !input.removable ? .disabled : armed ? .armed : arrived ? .carrying : .appearing
            if !input.removable && arrived && input.inWindow && near < k.armRadius && input.semanticCenter.y < g.armBandY && !disabledNotified {
                disabledNotified = true; disabledNoticeUntil = time + k.disabledMessageTime
            }
            if canArm && near < k.armRadius && input.sourceClearance >= k.separatedGap && owner == .source, let session {
                owner = .trash
                ox = .init(input.nativeCarrier.midX,velocity:input.nativeVelocity.minX+input.nativeVelocity.width/2,at:time)
                oy = .init(input.nativeCarrier.midY,velocity:input.nativeVelocity.minY+input.nativeVelocity.height/2,at:time)
                diameter = .init(input.nativeCarrier.width,velocity:input.nativeVelocity.width,at:time)
                height = .init(input.nativeCarrier.height,velocity:input.nativeVelocity.height,at:time)
                requests.append(.handoff(.trash, session, input.nativeCarrier, input.nativeVelocity))
            }
            if case .release(let token) = input.event, !releaseRequested, let session, token == session {
                releaseRequested = true
                if armed && owner == .trash { requests.append(.remove(session)) }
                else { requests.append(.returnToOrigin(session)); phase = .retiring; retireAt = time + k.retireHold }
            }
        }
        // Board T.emerge ends its armed treatment past ARM_OUT * 1.5 or the authored flight duration.
        if phase == .emerging, hypot(ox.sample(time).value-g.target.x,oy.sample(time).value-g.target.y)>k.armOut*1.5 || time-flightStart>=k.flightTime { emergeArmed=false }
        let isArmed = phase == .armed || phase == .sinking || phase == .emerging && emergeArmed
        arm.aim(isArmed ? 1 : 0, at: time, tuning: k.arm)
        lid.aim(isArmed ? 1 : 0, at: time, tuning: isArmed ? k.lidOpen : k.lidShut)
        let a = input.removable ? min(1, max(0, arm.sample(time).value)) : 0
        let trashX = g.offX + (g.target.x - g.offX) * entry.sample(time).value
        let visualOrb = owner == .trash ? CGPoint(x: ox.sample(time).value, y: oy.sample(time).value) : CGPoint(x: input.nativeCarrier.midX, y: input.nativeCarrier.midY)
        let len = max(0.01, distance(visualOrb, .init(x: trashX, y: g.target.y)))
        let ux = (visualOrb.x - trashX) / len, uy = (visualOrb.y - g.target.y) / len
        let center = CGPoint(x: trashX + ux * k.lean * a, y: g.target.y + uy * k.lean * a)
        if phase == .sinking {
            ox.aim(center.x, at: time, tuning: k.sink); oy.aim(center.y, at: time, tuning: k.sink)
            diameter.aim(0, at: time, tuning: k.sinkSize); glyph.aim(0, at: time, tuning: k.sinkGlyph)
            height.aim(0, at: time, tuning: k.sinkSize)
            if max(diameter.sample(time).value,height.sample(time).value) < k.sinkDone {
                owner = .none; phase = .educating; promptVisible = true
                gulp.impulse(k.swallowVelocity, at: time, tuning: k.swallow)
                if let receipt { requests.append(.presentPrompt(receipt)) }
            }
        } else if phase == .emerging {
            // Cubic board flight with moving endpoint; retargeting follows through the same analytic channels.
            if case .undo = input.event {} else if input.nativeCarrier.width > 0 { flightTarget = input.nativeCarrier }
            let q = min(1, max(0, (time - flightStart) / k.flightTime)), s = Self.bezierEase(q)
            let dx = flightTarget.midX - flightOrigin.x, dy = flightTarget.midY - flightOrigin.y
            let chord = hypot(dx, dy), nx = chord > 0 ? dy / chord : 0, ny = chord > 0 ? -abs(dx) / chord : -1
            let bow = max(24, chord)
            let p1 = CGPoint(x: flightOrigin.x + dx * 0.10 + nx * bow * 0.26, y: flightOrigin.y + dy * 0.10 + ny * bow * 0.26)
            let p2 = CGPoint(x: flightOrigin.x + dx * 0.58 + nx * bow * 0.14, y: flightOrigin.y + dy * 0.58 + ny * bow * 0.14)
            let px = pow(1-s,3)*flightOrigin.x + 3*pow(1-s,2)*s*p1.x + 3*(1-s)*s*s*p2.x + pow(s,3)*flightTarget.midX
            let py = pow(1-s,3)*flightOrigin.y + 3*pow(1-s,2)*s*p1.y + 3*(1-s)*s*s*p2.y + pow(s,3)*flightTarget.midY
            ox.aim(px, at: time, tuning: k.follow); oy.aim(py, at: time, tuning: k.follow)
            diameter.aim(flightTarget.width, at: time, tuning: k.size); glyph.aim(1, at: time, tuning: k.emergeGlyph)
            height.aim(flightTarget.height, at: time, tuning: k.size)
            if q >= 1 && abs(ox.sample(time).value - flightTarget.midX) < 1 && abs(oy.sample(time).value - flightTarget.midY) < 1 {
                phase = .retiring; retireAt = time + k.retireHold
            }
        } else if owner == .trash {
            ox.aim(input.semanticCenter.x + (center.x - input.semanticCenter.x) * k.magnet * a, at: time, tuning: k.follow)
            oy.aim(input.semanticCenter.y + (center.y - input.semanticCenter.y) * k.magnet * a, at: time, tuning: k.follow)
            diameter.aim(k.carriedDiameter + (k.armedDiameter - k.carriedDiameter) * a, at: time, tuning: k.size)
            height.aim(k.carriedDiameter + (k.armedDiameter - k.carriedDiameter) * a, at: time, tuning: k.size)
        }
        let canD = k.trashDiameter + k.swallowDiameter * gulp.sample(time).value
        let can = Self.disc(center, canD)
        let dw=max(0,diameter.sample(time).value), dh=max(0,height.sample(time).value)
        var carrier = owner == .trash ? CGRect(x:ox.sample(time).value-dw/2,y:oy.sample(time).value-dh/2,width:dw,height:dh) : input.nativeCarrier
        var neck: [CGRect] = []
        let centerDistance = distance(.init(x: carrier.midX, y: carrier.midY), center)
        // Preserve the original carrier handoff eligibility; it is independent of drawing a neck.
        let neckAllowed = phase == .armed || phase == .sinking || phase == .emerging && centerDistance <= k.armOut * 1.5
        if owner == .trash {
            let heldAmount = phase == .armed && releaseRequested ? 0 : a
            neck = Self.nubRects(can:can,carrier:carrier,amount:heldAmount,phase:phase,previouslyVisible:neckWasVisible)
        }
        neckWasVisible = !neck.isEmpty
        if owner == .trash && phase != .emerging && !neckAllowed && a < 0.01 && centerDistance - canD/2 - carrier.width/2 >= k.separatedGap,
           input.sourceClearance >= k.separatedGap, let token = carrierToken {
            owner = .source; requests.append(.handoff(.source, token, carrier,
                .init(x:ox.sample(time).velocity-diameter.sample(time).velocity/2,
                      y:oy.sample(time).velocity-height.sample(time).velocity/2,
                      width:diameter.sample(time).velocity,height:height.sample(time).velocity)))
        }
        if phase == .educating && input.prompt == nil && !requests.contains(where: { if case .presentPrompt = $0 { true } else { false } }) {
            phase = .retiring; promptVisible = false; retireAt = time + k.retireHold
        }
        let education = promptVisible && input.prompt != .toast && g.bubble(above: can) != nil
        top.aim(education ? 1 : 0, at: time, tuning: education ? k.morphTop : k.morphOut)
        bottom.aim(education ? 1 : 0, at: time, tuning: education ? k.morphBottom : k.morphOut, delay: education ? k.bottomDelay : 0)
        width.aim(education ? 1 : 0, at: time, tuning: education ? k.morphWidth : k.morphOut, delay: education ? k.widthDelay : 0)
        var bubble: CGRect?, tail: [CGPoint] = []
        if let target = g.bubble(above: can), max(top.sample(time).value, bottom.sample(time).value, width.sample(time).value) > 0.003 {
            let w = min(1.02, max(0, width.sample(time).value)), h = top.sample(time).value, b = bottom.sample(time).value
            let right = center.x + 10 + (target.maxX-center.x-10)*w
            let bw = 20 + (target.width-20)*w, by = center.y-10 + (target.minY-center.y+10)*h
            let bb = center.y+10 + (target.maxY-center.y-10)*b
            bubble = .init(x: right-bw, y: by, width: bw, height: max(20, bb-by))
            let tk = Self.smooth((b-0.6)/0.4)
            if tk > 0.01, let bubble {
                let tip = min(can.minY-k.separatedGap, bubble.maxY-k.tailInset+k.tailHeight*tk)
                tail = [.init(x:center.x-k.tailWidth*tk/2,y:bubble.maxY-k.tailInset),
                        .init(x:center.x+k.tailWidth*tk/2,y:bubble.maxY-k.tailInset), .init(x:center.x,y:tip)]
            }
            if education && w > 0.55 && contentStart == nil { contentStart = time }
        }
        let toast = promptVisible && !education ? CGRect(x: max(g.bounds.minX+10, can.maxX-230), y: max(g.bounds.minY+10, can.minY-44), width: min(230,g.bounds.width-20), height: 32) : nil
        if phase == .retiring, bubble != nil { retireAt = time + k.retireHold }
        if phase == .retiring, let retireAt, time >= retireAt, bubble == nil {
            entry.aim(0, at: time, tuning: k.exit)
            if abs(trashX-g.offX) < 0.5 { phase = .hidden }
        }
        if phase == .hidden { carrier = .zero; neck = []; bubble = nil; tail = [] }
        let channels = [entry, arm, lid, gulp, ox, oy, diameter, height, glyph, top, bottom, width]
        let pose = Pose(phase: phase, can: can, carrier: carrier,
            carrierVelocity: owner == .trash ? .init(x: ox.sample(time).velocity-diameter.sample(time).velocity/2,
                y: oy.sample(time).velocity-height.sample(time).velocity/2, width: diameter.sample(time).velocity, height: height.sample(time).velocity) : input.nativeVelocity,
            owner: owner, nubs: neck, bubble: bubble, tail: tail, toast: toast,
            lidDegrees: input.removable ? max(k.lidMinimum,k.lidDegrees*lid.sample(time).value) : 0,
            haloAlpha: input.removable ? k.haloRest+(k.haloArmed-k.haloRest)*a : 0,
            haloScale: 1+(k.haloScale-1)*a, redTint: input.removable ? k.redTint*a : 0,
            iconAlpha: input.removable ? 0.88 : 0.3, iconScale: 1+k.swallowIcon*gulp.sample(time).value,
            glyphAlpha: min(1,max(0,glyph.sample(time).value)), glyphBlur: 10*(1-min(1,max(0,glyph.sample(time).value))),
            contentAlpha: education ? Self.smooth((time-(contentStart ?? time))/k.contentIn) : toast != nil ? 1 : 0,
            carrierZ: phase == .emerging ? k.emergeZ : k.sinkZ, hidden: phase == .hidden)
        lastCan = can
        return .init(pose: pose, requests: requests,
                     disabledMessage: time < disabledNoticeUntil ? OrganicRemoveJournal.lastColumnMessage : nil,
                     needsFrames: phase != .hidden && (channels.contains { $0.moving(time) } || phase == .sinking || phase == .emerging || retireAt.map { time < $0 } == true))
    }
    static func disc(_ p: CGPoint, _ diameter: Double) -> CGRect { .init(x:p.x-diameter/2,y:p.y-diameter/2,width:diameter,height:diameter) }
    /// Two native lobes, or none. This changes no carrier, lid, lean, halo or timing channel.
    static func nubRects(can: CGRect, carrier: CGRect, amount: Double, phase: Phase, previouslyVisible: Bool) -> [CGRect] {
        guard phase == .armed, carrier.width > 0.5 else { return [] }
        let k = OrbTrashParameters.self
        let dx=carrier.midX-can.midX, dy=carrier.midY-can.midY, distance=hypot(dx,dy)
        guard distance > 0.01 else { return [] }
        let gap=max(0,distance-can.width/2-carrier.width/2)
        let envelope: Double
        if gap <= k.neckFullGap { envelope=k.nubRadius }
        else if gap < k.neckThinGap {
            envelope=k.nubRadius+(k.neckThinRadius-k.nubRadius)*smooth((gap-k.neckFullGap)/(k.neckThinGap-k.neckFullGap))
        } else if gap <= k.neckThinEnd { envelope=k.neckThinRadius }
        else { envelope=k.neckThinRadius*(1-smooth((gap-k.neckThinEnd)/(k.neckZeroGap-k.neckThinEnd))) }
        var radius=min(k.nubRadius*smooth(amount),envelope)
        if !previouslyVisible { radius=min(radius,k.neckBoundaryDiameter/2) }
        guard radius*2 >= k.neckMinDiameter else { return [] }
        // Aim into the middle of the gap, but never detach either lobe from its own body.
        func anchoredOffset(_ aim: Double, bodyRadius: Double) -> Double {
            min(aim,bodyRadius+radius-k.connectedOverlap)
        }
        // Once the bodies overlap, keep both lobes inside their common lens instead of crossing past it.
        let canAim=min(can.width/2+gap/2,distance*can.width/(can.width+carrier.width))
        let orbAim=min(carrier.width/2+gap/2,distance*carrier.width/(can.width+carrier.width))
        let canOffset=anchoredOffset(canAim,bodyRadius:can.width/2)
        let orbOffset=anchoredOffset(orbAim,bodyRadius:carrier.width/2)
        let ux=dx/distance, uy=dy/distance
        let pair=[disc(.init(x:can.midX+ux*canOffset,y:can.midY+uy*canOffset),radius*2),
                  disc(.init(x:carrier.midX-ux*orbOffset,y:carrier.midY-uy*orbOffset),radius*2)]
        let nubGap=hypot(pair[0].midX-pair[1].midX,pair[0].midY-pair[1].midY)-2*radius
        guard nubGap <= k.neckMaxNubGap else { return [] }
        return pair
    }
    static func smooth(_ x: Double) -> Double { let q = min(1,max(0,x)); return q*q*(3-2*q) }
    private static func bezierEase(_ x: Double) -> Double {
        var lo=0.0, hi=1.0
        for _ in 0..<24 {
            let t=(lo+hi)/2, bx=3*(1-t)*(1-t)*t*0.32+3*(1-t)*t*t*0.2+t*t*t
            if bx < x { lo=t } else { hi=t }
        }
        let t=(lo+hi)/2
        return 3*(1-t)*t*t+t*t*t
    }
}
