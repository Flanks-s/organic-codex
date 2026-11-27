import AppKit
import QuartzCore

extension AutoScene {
    private var splitRequestsBlocked: Bool {
        transcriptSessions?.isDisposed == true || modeHandoffActive || scheme.draft
            || sceneView.window?.attachedSheet != nil || orbTrash.hasForegroundSurface
            || overlayPlane.subviews.contains { ($0 as? SheetSurface)?.isShowing == true }
    }
    var canSplitWithNext: Bool { nextSplitPlan() != nil }
    func splitPlan(incoming: String) -> SplitPresentationLayout.Plan? {
        splitPlan(receiving: focusTarget, incoming: incoming)
    }
    func splitPlan(receiving: String, incoming: String) -> SplitPresentationLayout.Plan? {
        guard !splitRequestsBlocked, let source = orbTrash.project() else { return nil }
        guard let plan = SplitPresentationLayout.makeSplit(receiving: receiving, incoming: incoming,
            layout: source, size: size, metrics: metrics) else { return nil }
        let target = Scheme(mode: .focused, split: plan.split, right: plan.right)
        guard arrange(members, current: receiving, scheme: target).0.separateInputs else { return nil }
        return plan
    }
    func nextSplitPlan() -> SplitPresentationLayout.Plan? {
        guard let source = orbTrash.project() else { return nil }
        let screen = scheme.mode == .focused ? Array(scheme.left.reversed()) + scheme.split + scheme.right
            : scheme.parked + order.filter { !scheme.parked.contains($0) }
        guard let incoming = SplitPresentationLayout.next(receiving: focusTarget, screen: screen,
                                                          layout: source) else { return nil }
        return splitPlan(incoming: incoming)
    }
    @discardableResult func openInSplit(_ incoming: String, reason: String) -> Bool {
        guard let plan = splitPlan(incoming: incoming) else { return false }
        return commitSplit(plan, reason: reason)
    }
    func validatesSplit(_ plan: SplitPresentationLayout.Plan) -> Bool {
        plan.isValid && !splitRequestsBlocked && plan.size == size && plan.metrics == metrics
            && orbTrash.project() == plan.source
            && (plan.split.count == 1 || FocusLayout.explicitPair(size: size,
                bankCount: members.count - 2, metrics: metrics) != nil)
    }
    /// Preparation never publishes a temporary single pane. Recheck the complete source at the commit boundary.
    @discardableResult func commitSplit(_ plan: SplitPresentationLayout.Plan, reason: String,
                                        restoring: Bool = false) -> Bool {
        guard validatesSplit(plan),
              let claim = structureOwner.claim(window: plan.source.windowID,
                                               revision: plan.source.revision) else { return false }
        defer { structureOwner.cancel(claim) }
        dock.captureSplitSources(scheme.split + plan.split, window: plan.source.windowID)
        defer { dock.discardSplitSources() }
        let editing = members.contains { composers.existingComposer(for: $0.id)?.editorFocused == true }
        let next = Scheme(mode: .focused, split: plan.split, right: plan.right)
        var prepared = prepare(members: members, current: plan.current, scheme: next,
                               at: now(), spring: Self.focusSpring,
                               deferVisibleReflow: !restoring && plan.split.count == 2)
        prepared.splitCertificate = plan
        guard validatesSplit(plan), prepared.next.columns.count == plan.split.count,
              plan.split.count != 2 || prepared.next.separateInputs else { return false }
        let before = structureOwner.commits
        commit(prepared, reason: reason, prewarmed: false,
               start: CACurrentMediaTime(), structureClaim: claim)
        guard structureOwner.commits == before + 1 else { return false }
        if restoring {
            settle()
            dock.relayout(layout, metrics: metrics, order: order.compactMap(conversation), full: fullIDs)
        }
        if editing { composers.existingComposer(for: plan.current)?.focus() }
        return true
    }
    func splitArrangement(_ models: [Conversation], scheme: Scheme) -> (AutoLayout, [String])? {
        guard scheme.mode == .focused, scheme.split.count == 2,
              let geometry = FocusLayout.explicitPair(size: size, bankCount: models.count - 2,
                                                       metrics: metrics) else { return nil }
        let ids = models.map(\.id)
        let balanced = scheme.balanced(members: ids)
        let pair = balanced.split
        guard Set(pair).count == 2, pair.allSatisfy(ids.contains) else { return nil }
        return (geometry, pair + balanced.left + balanced.right)
    }
    func restoreSplit(_ saved: SavedWindow) {
        guard let source = orbTrash.project(), let plan = SplitPresentationLayout.restored(
            split: saved.split ?? [], current: saved.current, focus: saved.splitFocus,
            left: saved.leftBank ?? saved.left, right: saved.rightBank ?? saved.right,
            layout: source, size: size, metrics: metrics) else { return }
        _ = commitSplit(plan, reason: "restore-split", restoring: true)
    }
    func fitSeparateSplit() {
        let fitted = fittingSplitTarget(members: members, current: current, scheme: scheme)
        guard fitted.scheme != scheme else { return }
        transition(to: members, current: fitted.current, scheme: fitted.scheme,
                   spring: Self.focusSpring, reason: "fit-split")
    }
    func fittingSplitTarget(members: [Conversation], current: String, scheme: Scheme)
        -> (current: String, scheme: Scheme) {
        guard scheme.mode == .focused, scheme.split.count > 1 else { return (current, scheme) }
        let ids = members.map(\.id)
        let pair = scheme.split.filter(ids.contains)
        if pair.count == 2, FocusLayout.explicitPair(size: size, bankCount: ids.count - 2,
                                                    metrics: metrics) != nil { return (current, scheme) }
        let keep = pair.contains(focusTarget) ? focusTarget : (pair.contains(current) ? current : pair.first ?? current)
        var next = scheme
        next.split = [keep]
        next.left = []
        next.parked = []
        var seen: Set<String> = [keep]
        next.right = (pair + Array(scheme.left.reversed()) + scheme.parked + scheme.right + ids)
            .filter { ids.contains($0) && seen.insert($0).inserted }
        return (keep, next)
    }
    func reconcileSplitCompare(next: Scheme) {
        if let pair = compare {
            let a = next.split.firstIndex(of: pair.left)
            let b = next.split.firstIndex(of: pair.right)
            if next.mode != .focused || a == nil || b == nil || abs(a! - b!) != 1 {
                compare = nil
                compareAsk = nil
                compareSheet.dismiss()
                dock.setMeDivider(nil)
            }
        }
        if compareAsk != nil && next.split != scheme.split {
            compareAsk = nil
            compareSheet.dismiss()
            dock.setMeDivider(nil)
        }
    }
}
