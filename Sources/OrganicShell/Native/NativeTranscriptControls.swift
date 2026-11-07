import AppKit

@MainActor final class NativeTranscriptLatestButton: NativeButton {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.18, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        super.draw(dirtyRect)
    }
}
