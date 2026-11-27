import AppKit
import QuartzCore

/// The refusal carrier is independent of both the Dock's fusion container and the trash proxy.
@MainActor final class OrbRefuseCarrier {
    private weak var scene: AutoScene?
    let view = AutoScene.PassThrough()
    private(set) var id: String?
    private(set) var orb: OrbComponent?
    private(set) var returning = false
    private(set) var pending: String?
    private(set) var pose = CGRect.zero
    private(set) var entrySourcePose = CGRect.zero
    private(set) var entryReplicaPose = CGRect.zero
    private(set) var handoffDelta: CGFloat = 0
    private(set) var handoffPose = CGRect.zero
    private(set) var handoffSource: CGRect?
    private(set) var handoffWasReturning = false
    var visible: Bool { id != nil && view.superview != nil && !view.isHidden }

    init(scene: AutoScene) {
        self.scene = scene
        view.wantsLayer = true
    }

    @discardableResult func enter(_ id: String) -> Bool {
        guard self.id == nil, let scene, let item = scene.dock.items[id],
              let native = scene.dock.trashCarrier(id) else { return false }
        let original = native.glass === item.identity?.glassView ? item.identity : item.decoration
        guard let original, let replica = original.prepareDragDecoration() else { return false }
        guard scene.orbTrash.yieldToRefuse(id) else {
            replica.dispose()
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = scene.overlayPlane.bounds
        scene.overlayPlane.addSubview(view)
        replica.setCanvasSize(view.bounds.size)
        for plane in [replica.backView, replica.glassView, replica.frontView] { view.addSubview(plane) }
        view.alphaValue = 0.45
        self.id = id
        pending = nil
        orb = replica
        returning = false
        paint(native.rect)
        entrySourcePose = scene.overlayPlane.convert(native.rect, from: scene.dockView)
        entryReplicaPose = pose
        scene.dock.setRefuseOwner(id, hidden: true)
        CATransaction.commit()
        return true
    }

    func request(_ id: String) {
        guard self.id != id else { return }
        pending = id
        _ = enter(id)
    }

    func leave() {
        pending = nil
        retire()
    }

    private func paint(_ rect: CGRect) {
        guard let scene, let orb else { return }
        let converted = scene.overlayPlane.convert(rect, from: scene.dockView)
        pose = converted
        orb.glassView.frame = converted
        orb.glassView.cornerRadius = min(converted.width, converted.height) / 2
        orb.glassView.contentView?.frame = orb.glassView.bounds
        orb.setFrame(converted)
    }

    func frame(_ time: Double) {
        if id == nil, let pending { _ = enter(pending) }
        guard let scene, let id, let native = scene.dock.trashCarrier(id) else {
            if self.id != nil { retire() }
            return
        }
        paint(native.rect)
        guard returning, time >= scene.transitionEnd, let item = scene.dock.items[id] else { return }
        let target = item.regular
        let delta = max(abs(native.rect.midX - target.midX), abs(native.rect.midY - target.midY),
                        abs(native.rect.width - target.width), abs(native.rect.height - target.height))
        if delta <= 0.5 { retire() }
        else { scene.runClock(until: time + 0.1) }
    }

    func beginReturn() {
        pending = nil
        guard id != nil else { return }
        returning = true
        if Motion.reduce, let layer = view.layer {
            let curve = OverlayCurve(0.3333, 0, 0.6667, 1, 0.1)
            OverlayMotion.animate(layer, "opacity", from: 0.45, to: 0, curve: curve, enabled: true)
        }
    }

    func settleAtSource() {
        guard returning else { return }
        guard let scene, let id, let native = scene.dock.trashCarrier(id) else {
            retire()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint(native.rect)
        retire()
        CATransaction.commit()
    }

    func retire() {
        guard let id, let scene else { return }
        let source = scene.dock.trashCarrier(id)?.rect
        handoffPose = pose
        handoffSource = source.map { scene.overlayPlane.convert($0, from: scene.dockView) }
        handoffWasReturning = returning
        if let source {
            let converted = scene.overlayPlane.convert(source, from: scene.dockView)
            handoffDelta = max(abs(pose.midX - converted.midX), abs(pose.midY - converted.midY),
                               abs(pose.width - converted.width), abs(pose.height - converted.height))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.dock.setRefuseOwner(id, hidden: false)
        scene.orbTrash.resumeFromRefuse()
        if returning, Motion.reduce, let item = scene.dock.items[id] {
            let curve = OverlayCurve(0.3333, 0, 0.6667, 1, 0.1)
            let views: [NSView] = [item.glass, item.content, item.decoration.backView, item.decoration.frontView]
            for layer in views.compactMap(\.layer) {
                OverlayMotion.animate(layer, "opacity", from: 0, to: 1, curve: curve, enabled: true)
            }
        }
        orb?.dispose()
        orb?.glassView.removeFromSuperview()
        orb = nil
        self.id = nil
        returning = false
        view.removeFromSuperview()
        CATransaction.commit()
    }
}
