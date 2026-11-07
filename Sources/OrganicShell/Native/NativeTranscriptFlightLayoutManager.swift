import AppKit

/// TextKit still draws every visible pixel. Only the source crop's area is omitted from the graphics context.
/// Both primitives must use the same clip: the source snapshot also contains inline-code and selection backgrounds.
// Like NSLayoutManager's drawing primitives, this object is confined to its owning text system's thread.
final class NativeTranscriptFlightLayoutManager: NSLayoutManager {
    private var omitted: [CGRect] = []
    @discardableResult func setOmittedRanges(_ ranges: [NSRange], in container: NSTextContainer) -> Bool {
        if ranges.isEmpty && omitted.isEmpty { return false }
        ensureLayout(for: container)
        var rects: [CGRect] = []
        for range in ranges {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
                let cut = NSIntersectionRange(lineGlyphs, glyphs)
                guard cut.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: cut, in: container)
                rect.origin.y = line.minY; rect.size.height = line.height
                rects.append(rect)
            }
        }
        guard rects != omitted else { return false }
        omitted = rects; return true
    }
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        clipped(at: origin) { super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
    }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        clipped(at: origin) { super.drawBackground(forGlyphRange: glyphsToShow, at: origin) }
    }
    private func clipped(at origin: CGPoint, draw: () -> Void) {
        guard !omitted.isEmpty, let context = NSGraphicsContext.current?.cgContext else { draw(); return }
        context.saveGState()
        for rect in omitted {
            // Snap in this context's device coordinates, including the current backing phase and scale.
            let source = rect.offsetBy(dx: origin.x, dy: origin.y)
            let aligned = context.convertToUserSpace(context.convertToDeviceSpace(source).integral)
            let path = CGMutablePath(); path.addRect(context.boundingBoxOfClipPath); path.addRect(aligned)
            context.addPath(path); context.clip(using: .evenOdd)
        }
        draw(); context.restoreGState()
    }
}
