import AppKit

/// Live native controls move between segment endpoints on the Dock's clock. The editor is never captured,
/// replaced or resigned; in particular a marked-text session survives a Focused/Split change.
@MainActor struct NativeComposerSegmentMotion {
    struct Pose {
        let view: NSView
        var rect: CGRect
        var opacity: CGFloat
        var hidden: Bool
    }
    var before: [Pose]
    var after: [Pose] = []
    var began: Double
    var sourceFrame: CGRect
    var targetFrame = CGRect.zero
    var sourceClip: CGRect
    var targetClip = CGRect.zero
    var sourceClipFrame: CGRect
    var targetClipFrame = CGRect.zero
    var sourceModel: NSImage
    var targetModel: NSImage?
    let duration = 0.20
}

extension NativeComposer {
    private var segmentViews: [NSView] {
        [attachButton, accessButton, sendButton, stopButton, voiceButton, dictationButton, modelButton,
         queueButton, contextButton, historyRefreshButton, attachmentScrollView, scrollView,
         textView, voiceTextLabel, voiceWaveform, sendingIndicator, stoppingIndicator]
    }

    func beginSegmentTransition(at now: Double) {
        guard !isComposing else { return }
        sampleSegmentTransition(at: now)
        (scrollView.contentView as? NativeComposerSegmentClipView)?.held = true
        segmentTransition = NativeComposerSegmentMotion(before: segmentViews.map {
            .init(view: $0, rect: $0.frame,
                  opacity: $0.isHidden ? 0 : $0.alphaValue, hidden: $0.isHidden)
        }, began: now, sourceFrame: frame, sourceClip:scrollView.contentView.bounds, sourceClipFrame:scrollView.contentView.frame,
            sourceModel: NSImage(cgImage:NativeViewBitmap.capture(modelButton,scale:controlScale),size:modelButton.bounds.size))
    }

    func commitSegmentTransition(at now: Double) {
        guard var transition = segmentTransition, !isComposing else { return }
        transition.targetFrame = frame
        transition.targetClipFrame = scrollView.bounds
        transition.targetClip = (scrollView.contentView as? NativeComposerSegmentClipView)?.normalized(scrollView.contentView.bounds) ?? scrollView.contentView.bounds
        modelButton.segmentBlend = nil
        transition.targetModel = NSImage(cgImage:NativeViewBitmap.capture(modelButton,scale:controlScale),size:modelButton.bounds.size)
        transition.after = segmentViews.map {
            .init(view: $0, rect: $0.frame, opacity: $0.isHidden ? 0 : 1, hidden: $0.isHidden)
        }
        // Hidden controls inherit the visible endpoint's position, so a returning button fades in in its own slot.
        for i in transition.before.indices {
            if transition.before[i].hidden { transition.before[i].rect = transition.after[i].rect }
        }
        segmentTransition = transition
        sampleSegmentTransition(at: now)
    }

    func sampleSegmentTransition(at now: Double) {
        guard let transition = segmentTransition, !transition.after.isEmpty else {
            if layoutMode == .fullBar, segment != nil, let clip = scrollView.contentView as? NativeComposerSegmentClipView {
                clip.held = true
                clip.frame = scrollView.bounds
                clip.bounds = clip.normalized(clip.bounds)
                clip.held = false
            }
            return
        }
        let k = CGFloat(smoothstep(0, 1, (now - transition.began) / transition.duration))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func blend(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: a.minX + (b.minX-a.minX)*k, y: a.minY + (b.minY-a.minY)*k,
                   width: a.width + (b.width-a.width)*k, height: a.height + (b.height-a.height)*k)
        }
        frame = blend(transition.sourceFrame, transition.targetFrame)
        for (a, b) in zip(transition.before, transition.after) {
            let rect = CGRect(x: a.rect.minX + (b.rect.minX - a.rect.minX) * k,
                              y: a.rect.minY + (b.rect.minY - a.rect.minY) * k,
                              width: a.rect.width + (b.rect.width - a.rect.width) * k,
                              height: a.rect.height + (b.rect.height - a.rect.height) * k)
            b.view.frame = rect
            b.view.alphaValue = a.opacity + (b.opacity - a.opacity) * k
            b.view.isHidden = k >= 1 ? b.hidden : a.hidden && b.hidden
        }
        scrollView.contentView.frame = blend(transition.sourceClipFrame,transition.targetClipFrame)
        scrollView.contentView.bounds = blend(transition.sourceClip,transition.targetClip)
        if let target = transition.targetModel {
            modelButton.segmentBlend = .init(from:transition.sourceModel,to:target,progress:k)
        }
        CATransaction.commit()
        if k >= 1 { finishSegmentTransition() }
    }

    func finishSegmentTransition() {
        guard let transition = segmentTransition else { return }
        if !transition.after.isEmpty { frame = transition.targetFrame }
        for pose in transition.after {
            pose.view.frame = pose.rect; pose.view.isHidden = pose.hidden; pose.view.alphaValue = 1
        }
        (scrollView.contentView as? NativeComposerSegmentClipView)?.held = false
        modelButton.segmentBlend = nil
        segmentTransition = nil
        needsLayout = true
    }
}

/// NSClipView's backing alignment can shift an empty editor by a fractional point after a parent moves.
/// Segment geometry stays continuous; valid scroll offsets are constrained without that extra quantization.
@MainActor final class NativeComposerSegmentClipView: NSClipView {
    var continuous = false
    var held = false
    func normalized(_ proposed: CGRect) -> CGRect {
        let document = documentView?.frame ?? .zero
        return CGRect(x:max(document.minX,min(proposed.minX,max(document.minX,document.maxX-proposed.width))),
                      y:max(document.minY,min(proposed.minY,max(document.minY,document.maxY-proposed.height))),
                      width:proposed.width,height:proposed.height)
    }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        if held { return proposedBounds }
        return continuous ? normalized(proposedBounds) : super.constrainBoundsRect(proposedBounds)
    }
}
