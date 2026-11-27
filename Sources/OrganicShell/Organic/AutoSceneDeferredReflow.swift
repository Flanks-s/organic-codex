import AppKit
import QuartzCore
extension AutoScene {
    struct DeferredTarget {
        let full: CGFloat
        let brief: CGFloat
        let top: CGFloat
        let reflow: ColumnFullReflow
    }
    func cancelDeferredTargets() {
        deferredEpoch += 1
        deferredTargets.values.forEach { $0.cancel() }
        deferredTargets = [:]
        deferredPlans = [:]
    }
    func startDeferredTargets(_ plan: Prepared) {
        let epoch = deferredEpoch
        let ordered = plan.order.compactMap { id -> (String, DeferredTarget, ColumnNode)? in
            guard let target = plan.deferred[id], let column = nodes[id] else { return nil }
            return (id, target, column)
        }.sorted { lhs, rhs in
            // The reflow layer has one new plane plus one plane per departure material.
            let left = (lhs.1.reflow.layer.sublayers?.count ?? 0) > 1
            let right = (rhs.1.reflow.layer.sublayers?.count ?? 0) > 1
            if left != right { return left }
            return (plan.order.firstIndex(of: lhs.0) ?? 0) < (plan.order.firstIndex(of: rhs.0) ?? 0)
        }
        for (id, target, _) in ordered { deferredPlans[id] = target }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var current: ColumnNode?
            var currentID: String?
            let valid = { [weak self] in
                guard let self, let column = current, let id = currentID else { return false }
                return self.deferredEpoch == epoch && self.deferredTargets[id] != nil
                    && self.columns.contains { $0 === column }
                    && self.presented && !self.modeHandoffActive
                    && (self.transcriptSessions == nil || self.transcriptsPresented)
            }
            let idle = M11IdlePreparation(interval: min(profile.frameInterval, 0.002),
                                          budget: profile.frameInterval * 0.25, valid: valid)
            defer { idle.finish() }
            for (id, target, column) in ordered {
                guard deferredEpoch == epoch else { return }
                guard deferredTargets[id] != nil else { continue }
                current = column
                currentID = id
                do {
                    let snapshot = try await column.idleSnapshot(fullWidth: target.full, briefWidth: target.brief,
                                                                 contentTop: target.top, idle: idle)
                    guard valid() else {
                        fallbackDeferredTarget(id, column: column, target: target, epoch: epoch)
                        continue
                    }
                    deliverDeferredTarget(id, column: column, target: target, snapshot: snapshot)
                    deferredTargets[id] = Task { @MainActor [weak self, weak column] in
                        do { try await Task.sleep(for: .seconds(target.reflow.deliveryDuration)) }
                        catch { return }
                        guard let self, let column, deferredEpoch == epoch else { return }
                        if isMoving {
                            deferredTargets[id] = nil
                            deferredPlans[id] = nil
                        } else { releaseDeferredTarget(id, column: column) }
                    }
                } catch {
                    fallbackDeferredTarget(id, column: column, target: target, epoch: epoch)
                }
            }
        }
        for (id, _, _) in ordered { deferredTargets[id] = task }
    }
    func deliverDeferredTarget(_ id: String, column: ColumnNode, target: DeferredTarget,
                               snapshot: ColumnNode.Snapshot) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        column.apply(snapshot)
        let time = max(0, now() - began)
        let tracks = target.reflow.deliver(snapshot, at: time, scale: scale,
                                           rate: Timeline.rate(frameInterval: profile.frameInterval))
        M10ColumnWorkTrace.count("scene.deferred.deliver", ["id": id, "milliseconds": time * 1000,
                                                         "fadeMs": target.reflow.deliveryDuration * 1000])
        for track in tracks { M10ColumnExposure.start(track, at: now(), frameInterval: profile.frameInterval) }
        CATransaction.commit()
    }
    func releaseDeferredTarget(_ id: String, column: ColumnNode) {
        deferredTargets[id] = nil
        deferredPlans[id] = nil
        guard let i = columns.firstIndex(where: { $0 === column }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dirty.remove(id) != nil || column.needsReanchor {
            column.renderDisplay(fullWidth: fullWidth(i, layout), briefWidth: briefWidth(i, layout), force: true)
        }
        column.removeAnimations()
        column.showRest(full: isFull(id))
        column.endTranscriptMotion()
        CATransaction.commit()
    }
    func fallbackDeferredTarget(_ id: String, column: ColumnNode, target: DeferredTarget, epoch: Int) {
        guard deferredEpoch == epoch, deferredTargets[id] != nil else { return }
        let snapshot = column.snapshot(fullWidth: target.full, briefWidth: target.brief, contentTop: target.top)
        column.apply(snapshot)
        releaseDeferredTarget(id, column: column)
    }
    func fallbackDeferredTargets() {
        for (id, target) in deferredPlans {
            if let column = nodes[id] {
                fallbackDeferredTarget(id, column: column, target: target, epoch: deferredEpoch)
            }
        }
    }
}
