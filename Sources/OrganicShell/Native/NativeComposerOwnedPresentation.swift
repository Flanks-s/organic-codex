import AppKit
extension NativeComposer {
    func takeSplitPresentation() {
        splitOwnsPresentation = true
        segmentTransition?.sourceModel = nil
        segmentTransition?.targetModel = nil
        modelButton.segmentBlend = nil
    }

    func applySplitEndpoint(_ endpoint: CGRect, segment: NativeComposerSegment?, at time: Double) {
        takeSplitPresentation()
        beginSegmentTransition(at: time)
        self.segment = segment
        targetWidth = endpoint.width
        if !isComposing {
            frame = endpoint
            layoutSubtreeIfNeeded()
        }
        commitSegmentTransition(at: time)
    }
    func fitSplitActionRail(in viewport: CGRect, root: NSView) {
        let visible = splitActionRail.filter { !$0.isHidden && $0.alphaValue > 0 }
        let rail = visible.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let delta = DockGlassTopology.actionOffset(in: convert(viewport, from: root), rail: rail)
        guard !rail.isNull, delta != .zero else { return }
        for control in visible {
            let original = control.frame
            let projected = original.offsetBy(dx: delta.x, dy: delta.y)
            splitActionPoses.append((control, original, projected))
            control.frame = projected
        }
    }

    func releaseSplitPresentation(settled: Bool) {
        guard splitOwnsPresentation else { return }
        splitOwnsPresentation = false
        restoreSplitActionRail()
        if settled { finishSegmentTransition() }
    }
}
