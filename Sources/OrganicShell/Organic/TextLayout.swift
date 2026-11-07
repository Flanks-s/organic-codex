import AppKit
import CoreText

/// Text style for snapshot text. Line height is absolute so layouts are deterministic.
struct TextStyle {
    var font: NSFont
    var color: NSColor
    var lineHeight: CGFloat
    var kern: CGFloat = 0

    var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: color, .kern: kern] }
}

/// A paragraph laid out once (off the motion path), with each line's string range and rectangle in the
/// block's top-left coordinates, and a snapshot image of it (spec §7: motion moves snapshots only).
struct TextBlock {
    struct Line { let range: NSRange; let rect: CGRect; let ctLine: CTLine }
    let text: String
    let style: TextStyle
    let lines: [Line]
    let size: CGSize

    /// Right-aligned blocks keep `width` as their width and set each line's x.
    init(_ text: String, style: TextStyle, width: CGFloat, maxLines: Int = 0, alignment: NSTextAlignment = .left) {
        self.text = text; self.style = style
        let attributed = NSAttributedString(string: text, attributes: style.attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [Line] = [], start = 0, widest: CGFloat = 0
        let length = attributed.length
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(10, width)))
            if count <= 0 { count = length - start }
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            let last = maxLines > 0 && lines.count == maxLines - 1 && start + count < length
            if last {
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: style.attributes))
                line = CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? line
                count = length - start
            }
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            widest = max(widest, w)
            // Whole points, so a line drawn on its own and inside its block land on the same pixels.
            let x = alignment == .right ? max(0, width - w).rounded() : 0
            lines.append(Line(range: NSRange(location: start, length: count),
                              rect: CGRect(x: x, y: CGFloat(lines.count) * style.lineHeight, width: w, height: style.lineHeight), ctLine: line))
            start += count
            if last { break }
        }
        self.lines = lines
        size = CGSize(width: alignment == .right ? ceil(width) : ceil(widest), height: CGFloat(lines.count) * style.lineHeight)
    }

    /// Top-left of the glyph at a UTF-16 index, in block coordinates.
    func point(at index: Int) -> CGPoint {
        guard let line = lines.last(where: { $0.range.location <= index }) ?? lines.first else { return .zero }
        let x = CTLineGetOffsetForStringIndex(line.ctLine, index, nil)
        return CGPoint(x: line.rect.minX + x, y: line.rect.minY)
    }

    /// A snapshot of the whole block, or of the lines in `range` only.
    func image(scale: CGFloat, lines subset: Range<Int>? = nil) -> (image: CGImage, size: CGSize)? {
        let picked = subset.map { Array(lines[$0]) } ?? lines
        guard !picked.isEmpty else { return nil }
        // One line: its own width, drawn at 0. Several: the block's width, each line at its x.
        let top = picked[0].rect.minY, single = picked.count == 1 && subset != nil
        let width = single ? picked[0].rect.width : (subset == nil ? size.width : picked.map(\.rect.maxX).max() ?? 1)
        let size = CGSize(width: max(1, ceil(width) + 2), height: CGFloat(picked.count) * style.lineHeight)
        return Self.draw(size: size, scale: scale) { context in
            for line in picked { Self.draw(line.ctLine, at: line.rect.minY - top, x: single ? 0 : line.rect.minX, style: style, height: size.height, in: context) }
        }.map { ($0, size) }
    }

    /// Draws the block's lines with its top-left at `origin` in a y-up context of height `canvasHeight`.
    func draw(in context: CGContext, at origin: CGPoint, canvasHeight: CGFloat) {
        for line in lines {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line.ctLine, &ascent, &descent, nil)
            let baseline = origin.y + line.rect.minY + (style.lineHeight + ascent - descent) / 2
            context.textPosition = CGPoint(x: origin.x + line.rect.minX, y: canvasHeight - baseline)
            CTLineDraw(line.ctLine, context)
        }
    }

    /// Line `k` as drawn, cut to its glyphs from string index `from` to `to`, at pixel boundaries so pieces of
    /// one line tile it exactly. Returns the piece and its x and width in the line's own coordinates.
    func piece(line k: Int, from: Int, to: Int, scale: CGFloat) -> (image: CGImage, x: CGFloat, width: CGFloat)? {
        guard k < lines.count, let whole = image(scale: scale, lines: k..<(k + 1)) else { return nil }
        let s = max(1, scale), line = lines[k].ctLine
        let x0 = (CTLineGetOffsetForStringIndex(line, from, nil) * s).rounded()
        var x1 = (CTLineGetOffsetForStringIndex(line, to, nil) * s).rounded()
        if to >= lines[k].range.location + lines[k].range.length { x1 = CGFloat(whole.image.width) }
        guard x1 - x0 >= 1, let cut = whole.image.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: CGFloat(whole.image.height))) else { return nil }
        return (cut, x0 / s, (x1 - x0) / s)
    }

    /// Draws one string on a single line in this style: a flight's look at the other end.
    static func singleLine(_ text: String, style: TextStyle, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: style.attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let size = CGSize(width: ceil(width) + 2, height: style.lineHeight)
        return draw(size: size, scale: scale) { draw(line, at: 0, x: 0, style: style, height: size.height, in: $0) }.map { ($0, size) }
    }

    /// One line of mixed-style text, cut to `width` with "…", drawn from `x` in a box `height` tall and centred in it:
    /// a brief's activity or state line. The image is as wide as what it draws; `textWidth` is the text's own width.
    static func attributedLine(_ text: NSAttributedString, width: CGFloat, x: CGFloat, height: CGFloat,
                               scale: CGFloat) -> (image: CGImage, size: CGSize, textWidth: CGFloat)? {
        guard text.length > 0 else { return nil }
        let whole = CTLineCreateWithAttributedString(text)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
        let line = CTLineCreateTruncatedLine(whole, Double(max(1, width)), .end, ellipsis) ?? whole
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let size = CGSize(width: ceil(x + w) + 2, height: height)
        let baseline = ((height + ascent - descent) / 2).rounded()
        return draw(size: size, scale: scale) { context in
            context.textPosition = CGPoint(x: x, y: height - baseline)
            CTLineDraw(line, context)
        }.map { ($0, size, ceil(w)) }
    }

    private static func draw(_ line: CTLine, at top: CGFloat, x: CGFloat, style: TextStyle, height: CGFloat, in context: CGContext) {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let baseline = top + (style.lineHeight + ascent - descent) / 2
        context.textPosition = CGPoint(x: x, y: height - baseline)
        CTLineDraw(line, context)
    }

    private static func draw(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let s = max(1, scale)
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * s)), height: Int(ceil(size.height * s)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: s, y: s)
        context.textMatrix = .identity
        body(context)
        return context.makeImage()
    }
}
