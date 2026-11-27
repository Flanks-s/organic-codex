import AppKit
/// Retains the actual surface and editor for an entire flight. No snapshots or clones.
@MainActor final class SplitSurfaceOwner {
    @MainActor final class DockFlight {
        struct Endpoint {
            let glass: NSGlassEffectView
            let frame: CGRect
            let orb: OrbComponent
            let body: NSView
            let composer: NativeComposer?
            let ink: SplitDockBinding?
        }
        let group: SplitMaterialGroup
        private(set) var endpoints: [String: Endpoint] = [:]
        private let leases: SplitPaintLease
        private var paint: [String: SplitPaintLease.Token] = [:]
        private(set) var displaying = false
        init(_ group: SplitMaterialGroup, leases: SplitPaintLease) {
            self.group = group
            self.leases = leases
        }
        func retain(_ endpoint: Endpoint, member: String) -> Bool {
            guard !displaying, endpoints[member] == nil, let holder = endpoint.orb.glassView.contentView,
                  endpoint.body.superview === holder,
                  !endpoints.values.contains(where: { $0.glass === endpoint.glass }),
                  endpoint.ink?.validates() != false, group.register(endpoint.glass) else { return false }
            endpoints[member] = endpoint
            return true
        }
        func arm() {
            for (member, endpoint) in endpoints {
                if case .part(let part)? = endpoint.ink?.paint {
                    paint[member] = leases.claim(member, by: part.instance, actor: .part)
                } else { paint[member] = leases.claim(member, by: endpoint.glass, actor: .native) }
            }
        }
        func owns(_ member: String) -> Bool {
            guard let endpoint = endpoints[member], let token = paint[member] else { return false }
            return leases.validates(token) && group.contains(endpoint.glass)
        }
        func beginDisplay(_ handoff: (NativeComposer) -> Void) {
            guard !displaying else { return }
            for (member, token) in paint where owns(member) {
                paint[member] = leases.handoff(token, to: self, actor: .surface)
                if let composer = endpoints[member]?.composer { handoff(composer) }
            }
            displaying = true
        }
        func release() {
            for token in paint.values { leases.release(token) }
            paint.removeAll()
        }
    }
    enum Phase: String { case idle, armed, moving, settled, cancelled, retired }
    struct Pose {
        let frame: CGRect
        let contentAlpha: CGFloat
    }
    let role: String
    let glass: NSGlassEffectView
    let composer: NativeComposer
    let orb: OrbComponent
    private(set) var group: SplitMaterialGroup
    private(set) var phase = Phase.idle
    private(set) var token: SplitPaintLease.Token?
    private var firstDisplay: Double?
    private var start: Pose?, target: Pose?
    private var duration: Double = 0
    private var retirementMask: SplitSpatialMaterialMask?
    private var orbAlpha: (CGFloat, CGFloat) = (1, 1)
    private let leases: SplitPaintLease
    private let editorTrailingInset: CGFloat
    init(role: String, glass: NSGlassEffectView, composer: NativeComposer,
         orb: OrbComponent, group: SplitMaterialGroup, leases: SplitPaintLease) {
        self.role = role
        self.glass = glass
        self.composer = composer
        self.orb = orb
        self.group = group
        self.leases = leases
        editorTrailingInset = max(0, glass.bounds.width-composer.frame.width)
        token = leases.claim(role, by: composer, actor: .native)
    }
    @discardableResult func begin(to: Pose, duration: Double,
                                 mask: SplitSpatialMaterialMask? = nil) -> Bool {
        guard [.idle, .settled, .cancelled].contains(phase), duration >= 0, duration.isFinite,
              let token, let claimed = leases.handoff(token, to: self, actor: .surface) else { return false }
        self.token = claimed
        retirementMask = mask
        start = Pose(frame: glass.layer?.presentation()?.frame ?? glass.frame, contentAlpha: composer.alphaValue)
        orbAlpha = (orb.frontView.alphaValue, orb.backView.alphaValue)
        target = to
        self.duration = duration
        firstDisplay = nil
        phase = .armed
        return true
    }
    /// Only the display callback starts this local flight, never the structural commit clock.
    @discardableResult func sampleAuthored(_ pose: Pose, displayTime: Double) -> Pose? {
        guard phase == .armed || phase == .moving else { return nil }
        let original = start
        defer { start = original }
        start = pose
        target = pose
        duration = 0
        return sample(displayTime: displayTime)
    }
    @discardableResult func sample(displayTime: Double, reduceMotion: Bool = false) -> Pose? {
        guard let token, leases.validates(token), let start, let target,
              phase == .armed || phase == .moving else { return nil }
        if firstDisplay == nil { firstDisplay = displayTime }
        let t = reduceMotion || duration == 0 ? 1 : min(1, max(0, (displayTime-firstDisplay!)/duration))
        let k = CGFloat(t*t*(3-2*t))
        let a = start.frame, b = target.frame
        let frame = CGRect(x: a.minX+(b.minX-a.minX)*k, y: a.minY+(b.minY-a.minY)*k,
                           width: a.width+(b.width-a.width)*k, height: a.height+(b.height-a.height)*k)
        let pose = Pose(frame: frame, contentAlpha: start.contentAlpha+(target.contentAlpha-start.contentAlpha)*k)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(pose)
        phase = .moving
        CATransaction.commit()
        return pose
    }
    private func place(_ pose: Pose) {
        glass.frame = pose.frame
        composer.frame = CGRect(x: 0, y: 0, width: max(0, pose.frame.width-editorTrailingInset),
                                height: pose.frame.height)
        composer.alphaValue = pose.contentAlpha
        orb.setFrame(group.content.convert(pose.frame, to: orb.frontView),
                     contentFrame: CGRect(x: pose.frame.width-42, y: 6, width: 36, height: 36))
    }
    @discardableResult func retireBeforeLoss(next: CGRect, neighbour: CGRect,
                                            mask: SplitSpatialMaterialMask) -> Bool {
        guard next.minX.isFinite, next.maxX.isFinite, neighbour.minX.isFinite,
              neighbour.minX-next.maxX < 12-1e-6 else { return false }
        return retire(mask: mask)
    }
    @discardableResult func retire(mask: SplitSpatialMaterialMask) -> Bool {
        guard phase == .moving, let token, leases.validates(token),
              group.members[ObjectIdentifier(glass)] === glass, glass.superview === group.content else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard mask.retire(role), group.retire(glass) else { return false }
        retirementMask = mask
        composer.alphaValue = 0
        orb.frontView.removeFromSuperview()
        orb.backView.removeFromSuperview()
        _ = leases.release(token)
        self.token = nil
        phase = .retired
        return true
    }
    @discardableResult func settle(into next: SplitMaterialGroup? = nil) -> Bool {
        guard phase == .moving, let token, leases.validates(token), let target,
              glass.frame == target.frame else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let next {
            guard SplitMaterialGroup.transferAtEndpoint(glass, from: group, to: next, settled: true) else {
                return false
            }
            group = next
        }
        _ = retirementMask?.retire(role)
        self.token = leases.handoff(token, to: composer, actor: .native)
        phase = .settled
        return self.token != nil
    }
    @discardableResult func cancel() -> Bool {
        guard let start, phase == .armed || phase == .moving || phase == .retired else { return false }
        let retired = phase == .retired
        guard retired ? !leases.owners.contains(where: { $0.role == role }) : token.map(leases.validates) == true else {
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if retired {
            guard group.bindAtBirth(glass) else { return false }
            group.outer.addSubview(orb.backView, positioned: .below, relativeTo: group.container)
            group.outer.addSubview(orb.frontView, positioned: .above, relativeTo: group.container)
            token = leases.claim(role, by: composer, actor: .native)
        } else if let token {
            self.token = leases.handoff(token, to: composer, actor: .native)
        }
        _ = retirementMask?.retire(role)
        orb.frontView.alphaValue = orbAlpha.0
        orb.backView.alphaValue = orbAlpha.1
        place(start)
        phase = .cancelled
        return token != nil
    }
}
