import AppKit

/// Prepared on demand by the virtual document; cells consume this exact text/geometry instead of measuring twice.
/// Only mounted/overscan cells retain attributed text. Cold history retains a height and the value-model signature.
@MainActor struct NativeTranscriptPreparedRow {
    let text: NSAttributedString
    let offsets: [Int]
    let geometry: TranscriptGeometry
    let stream: NativeTranscriptStreamLayout?
    let streamGeneration: Int
    init(item: TranscriptItem, source: TranscriptItem, index: Int, items: [TranscriptItem], width: CGFloat,
         expanded: Bool, style: NativeTranscriptCodeStyle, stream: NativeTranscriptStreamLayout? = nil) {
        let p = NativeTranscriptPresentation.presentation(for: source), scale = NativeAppearance.current.textScale
        self.stream = stream; streamGeneration = stream?.generation ?? 0
        if let stream {
            text = stream.storage; offsets = [] // The stream owns one mutable mapping; cells don't copy its prefix.
        } else if TranscriptPresentation.isActivity(item.rowKind) && !expanded {
            text = TranscriptLayout.activityLine(item, presentation: p, scale: scale, codeStyle: style)
            let raw = item.text as NSString
            var cursor = 0, mapping: [Int] = []
            for part in NativeTranscriptPresentation.activityParts(item, presentation: p) {
                let count = (part.text as NSString).length
                let found = raw.range(of: part.text, range: NSRange(location: cursor, length: raw.length - cursor))
                if part.style != .say && found.location != NSNotFound {
                    mapping += Array(found.location..<NSMaxRange(found)); cursor = NSMaxRange(found)
                } else { mapping += Array(repeating: -1, count: count) }
            }
            offsets = mapping
        } else {
            let formatted = TranscriptLayout.formatted(item, presentation: p, scale: scale, codeStyle: style)
            text = formatted.text; offsets = formatted.sourceOffsets
        }
        geometry = TranscriptLayout.geometry(item: item, presentation: p, tableWidth: width, scale: scale,
            isTurnStart: TranscriptPresentation.isTurnStart(index: index, items: items), expanded: expanded,
            showsMeta: TranscriptPresentation.showsMeta(index: index, items: items, presentation: p),
            attributedText: text, workedFor: TranscriptPresentation.workedFor(index: index, items: items),
            measuredBody: stream?.size)
    }
}

/// Prefix heights: cold refinement and a streaming delta update offsets without moving every subsequent NSView.
struct NativeTranscriptHeightIndex {
    private var tree: [CGFloat] = [0]
    private(set) var heights: [CGFloat] = []
    mutating func reset(_ values: [CGFloat]) {
        heights = values; tree = [0] + values
        for i in 1..<tree.count { let next = i + (i & -i); if next < tree.count { tree[next] += tree[i] } }
    }
    mutating func append(_ height: CGFloat) {
        let count = heights.count + 1, start = count - (count & -count)
        let sum = prefix(heights.count) - prefix(start) + height
        heights.append(height); tree.append(sum)
    }
    mutating func set(_ height: CGFloat, at index: Int) {
        let delta = height - heights[index]; heights[index] = height
        var i = index + 1
        while i < tree.count { tree[i] += delta; i += i & -i }
    }
    func prefix(_ end: Int) -> CGFloat {
        var i = min(end, heights.count), result: CGFloat = 0
        while i > 0 { result += tree[i]; i -= i & -i }
        return result
    }
    var total: CGFloat { prefix(heights.count) }
    func row(at offset: CGFloat) -> Int {
        guard !heights.isEmpty else { return 0 }
        var index = 0, sum: CGFloat = 0, bit = 1
        while bit <= heights.count / 2 { bit *= 2 }
        while bit > 0 {
            let next = index + bit
            if next <= heights.count, sum + tree[next] <= max(0, offset) { index = next; sum += tree[next] }
            bit /= 2
        }
        return min(index, heights.count - 1)
    }
}

@MainActor final class NativeTranscriptLayoutEntry {
    let key: String
    let firstSeen = Date()
    var itemIndex: Int?
    var item: TranscriptItem?
    var previous: TranscriptItem?
    var approval: Approval?
    var question: UserInputRequest?
    var expanded = false
    var reviewed = false
    var height: CGFloat = 40
    var exact = false
    var prepared: NativeTranscriptPreparedRow?
    var stream: NativeTranscriptStreamLayout?
    init(key: String) { self.key = key }
}

/// Native button tracking can run a nested event loop while wheel/stream events refresh the document.
@MainActor final class NativeTranscriptActionButton: NativeButton {
    private(set) var isTrackingPress = false
    var cachesChevron = false
    private struct ChevronKey: Hashable {
        let width: CGFloat, height: CGFloat, scale: CGFloat
        let appearance: String
        let theme: Int, display: Int
        let key: Bool
    }
    private static var chevrons: [ChevronKey: CGImage] = [:]
    private static var pendingChevrons = Set<ChevronKey>()
    private var capturingChevron = false
    /// The one thing on nearly every row of a real history. AppKit resolves the symbol through CoreUI on each draw, about a
    /// millisecond; drawn once, the picture is the same. It is cut from this button in its window, after the pass that drew it:
    /// a picture from a detached button came out visibly dimmer on screen (96 against 76).
    override func draw(_ dirtyRect: NSRect) {
        guard cachesChevron, !capturingChevron, title.isEmpty, image != nil, isEnabled, !isHighlighted, state == .off,
              let window, let context = NSGraphicsContext.current else { super.draw(dirtyRect); return }
        let transform = context.cgContext.ctm
        let scale = max(1, hypot(transform.a, transform.c))
        // Native rows are snapped to backing pixels. Preserve AppKit's rendering for unusual capture transforms.
        guard abs(transform.b) < 0.0001, abs(transform.c) < 0.0001,
              abs(abs(transform.d) - scale) < 0.0001,
              abs(transform.tx - transform.tx.rounded()) < 0.0001,
              abs(transform.ty - transform.ty.rounded()) < 0.0001 else { super.draw(dirtyRect); return }
        let key = ChevronKey(width: bounds.width, height: bounds.height, scale: scale,
                             appearance: effectiveAppearance.name.rawValue,
                             theme: NativeAppearance.revision, display: NativeDisplayOptions.shared.revision, key: window.isKeyWindow)
        guard let picture = Self.chevrons[key] else {
            super.draw(dirtyRect)
            if scale == window.backingScaleFactor, Self.pendingChevrons.insert(key).inserted {
                DispatchQueue.main.async { [weak self] in
                    Self.pendingChevrons.remove(key)
                    self?.cutChevron(key)
                }
            }
            return
        }
        let cg = context.cgContext
        cg.saveGState(); cg.interpolationQuality = .none
        cg.translateBy(x: bounds.minX, y: bounds.maxY); cg.scaleBy(x: 1, y: -1)
        cg.draw(picture, in: CGRect(origin: .zero, size: bounds.size)); cg.restoreGState()
    }
    private func cutChevron(_ key: ChevronKey) {
        guard let window, !isHiddenOrHasHiddenAncestor, cachesChevron, window.isKeyWindow == key.key,
              bounds.width == key.width, bounds.height == key.height, window.backingScaleFactor == key.scale else { return }
        capturingChevron = true; defer { capturingChevron = false }
        let picture = NativeViewBitmap.capture(self, scale: key.scale)
        if Self.chevrons.count >= 32 { Self.chevrons.removeAll(keepingCapacity: true) }
        Self.chevrons[key] = picture
    }
    override func mouseDown(with event: NSEvent) {
        isTrackingPress = true
        defer { isTrackingPress = false }
        super.mouseDown(with: event)
    }
}
