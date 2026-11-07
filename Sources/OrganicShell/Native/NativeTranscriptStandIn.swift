import AppKit

/// Source pixels kept only for Hide Sidebar's fade after the actual viewport has moved to Organic.
/// No input, selection or AX identity is duplicated. The owner continues to hold the only live transcript.
@MainActor final class NativeTranscriptStandIn: NSView {
    override var isFlipped: Bool { true }
    private let image: NSImage
    init(_ source: NSView, scale: CGFloat) {
        let pixels = (source as? NativeTranscript)?.snapshot(scale: scale) ?? NativeViewBitmap.capture(source, scale: scale)
        image = NSImage(cgImage: pixels, size: source.bounds.size)
        super.init(frame: source.frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
