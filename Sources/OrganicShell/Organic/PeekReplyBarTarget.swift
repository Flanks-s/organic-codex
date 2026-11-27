import CoreGraphics

/// Reply admission for one column bar. The caller supplies geometry in one coordinate space.
enum PeekReplyBarTarget: Equatable {
    enum Role: Equatable {
        case full, brief, focused, splitLeft, splitRight
    }

    struct Segment {
        let frame: CGRect
        let controls: NativeComposerSegment
    }

    struct Placement: Equatable {
        let editorFrame: CGRect
        let leading: CGFloat
        let segment: NativeComposerSegment?
    }

    enum Rejection: Equatable {
        case browserCovered, normieTakeover, invalidGeometry, segmentMismatch, insufficientWidth
    }

    case inPlace(Placement)
    case borrow(Placement)
    case rejected(Rejection)

    /// Use the existing minimum for a Dock input, measured before reserving its leading slot.
    static let minimumBarWidth = SplitPresentationLayout.minimumInput

    /// leading is the reservation that remains inside the visible segment after clipping.
    static func resolve(
        clippedBar: CGRect, role: Role, leading: CGFloat, segment: Segment?,
        browserCovered: Bool, normieTakeover: Bool
    ) -> Self {
        if browserCovered { return .rejected(.browserCovered) }
        if normieTakeover { return .rejected(.normieTakeover) }
        guard valid(clippedBar), segment.map({ valid($0.frame) }) ?? true, leading.isFinite, leading >= 0 else {
            return .rejected(.invalidGeometry)
        }
        guard segment?.controls == expectedSegment(for: role) else {
            return .rejected(.segmentMismatch)
        }
        let visibleBar = segment.map { clippedBar.intersection($0.frame) } ?? clippedBar
        guard !visibleBar.isEmpty, visibleBar.width >= minimumBarWidth, visibleBar.width > leading else {
            return .rejected(.insufficientWidth)
        }
        let frame = CGRect(x: visibleBar.minX + leading, y: visibleBar.minY,
                           width: visibleBar.width - leading, height: visibleBar.height)
        let placement = Placement(editorFrame: frame, leading: leading, segment: segment?.controls)
        if role == .brief { return .borrow(placement) }
        return .inPlace(placement)
    }

    private static func expectedSegment(for role: Role) -> NativeComposerSegment? {
        switch role {
        case .full, .brief: nil
        case .focused: NativeComposerSegment(index: 0, isLast: true)
        case .splitLeft: NativeComposerSegment(index: 0, isLast: false)
        case .splitRight: NativeComposerSegment(index: 1, isLast: true)
        }
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width > 0 && frame.size.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }
}
