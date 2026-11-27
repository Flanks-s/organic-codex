import AppKit

// Ported from ui07 TranscriptLayout.swift. Changes: TranscriptItem input, no attachments;
// the user bubble uses 12 pt optical padding on all four sides (Canopy 2026-10-21), measured
// from cap height to baseline instead of the line box.

struct TranscriptGeometry {
    let rowHeight: CGFloat
    let metaRect: NSRect?
    let bubbleRect: NSRect?
    let bodyRect: NSRect
    let moreButtonRect: NSRect?
    let ruleRect: NSRect?
    let maximumLines: Int
    /// A work row shown as its one line (Codex): the state mark before it, a chevron after it.
    var isCompact = false
    var indicatorRect: NSRect?
    /// "Worked for …" above an answer, with a hairline running on after it.
    var dividerRect: NSRect?
    var dividerText: String?
    /// Under a user message: its time and Copy, Edit and Fork, shown while the pointer is over the row (ZCode, Codex).
    var actionsRect: NSRect?
}

/// One geometry and attributed-text implementation shared by measurement and cells.
@MainActor enum TranscriptLayout {
    static let gutter: CGFloat = 28
    static let userLineHeightMultiple: CGFloat = 1.2
    static func font(_ size: CGFloat, scale: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSFont {
        font(size, scale: scale, weight: weight, mono: mono, codeStyle: .init())
    }
    static func font(_ size: CGFloat, scale: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false, codeStyle: NativeTranscriptCodeStyle) -> NSFont {
        let points = max(10, size * scale)
        return mono ? codeStyle.font(points, weight: weight) : NSFont.systemFont(ofSize: points, weight: weight)
    }
    static func attributed(_ item: TranscriptItem, presentation: RowPresentation, scale: CGFloat) -> NSAttributedString {
        attributed(item, presentation: presentation, scale: scale, codeStyle: .init())
    }
    static func attributed(_ item: TranscriptItem, presentation: RowPresentation, scale: CGFloat, codeStyle: NativeTranscriptCodeStyle) -> NSAttributedString {
        formatted(item, presentation: presentation, scale: scale, codeStyle: codeStyle).text
    }
    static func formatted(_ item: TranscriptItem, presentation: RowPresentation, scale: CGFloat) -> (text: NSAttributedString, sourceOffsets: [Int]) {
        formatted(item, presentation: presentation, scale: scale, codeStyle: .init())
    }
    static func formatted(_ item: TranscriptItem, presentation: RowPresentation, scale: CGFloat, codeStyle: NativeTranscriptCodeStyle) -> (text: NSAttributedString, sourceOffsets: [Int]) {
        let palette = NativePalette.self
        let bodyFont: NSFont, color: NSColor
        let style = NSMutableParagraphStyle()
        switch presentation.kind {
        case .user:
            bodyFont = font(13, scale: scale); color = palette.label; style.lineHeightMultiple = userLineHeightMultiple
        case .assistant:
            bodyFont = font(13, scale: scale); color = palette.label
            style.lineHeightMultiple = 1.3; style.paragraphSpacing = 0
        case .reasoning:
            bodyFont = font(12, scale: scale); color = palette.secondaryLabel; style.lineHeightMultiple = 1.25
        case .tool:
            bodyFont = font(12, scale: scale, mono: true, codeStyle: codeStyle); color = (codeStyle.text ?? palette.codeText)
        case .notice:
            bodyFont = font(12, scale: scale); color = palette.label
        }
        let value = presentation.isPlaceholder ? presentation.statusText : item.text
        var sourceOffsets = presentation.isPlaceholder ? Array(repeating: -1, count: (value as NSString).length) : Array(0..<(value as NSString).length)
        let output = NSMutableAttributedString(string: value, attributes: [.font: bodyFont, .foregroundColor: color, .paragraphStyle: style])
        if TranscriptPresentation.isChangesCard(item) {
            // "path  +N −M" per line: the path in mono, the counts green and red, as in the Changes inspector.
            let whole = NSRange(location: 0, length: output.length)
            output.addAttribute(.font, value: font(12, scale: scale, mono: true, codeStyle: codeStyle), range: whole)
            style.lineHeightMultiple = 1.35
            output.addAttribute(.paragraphStyle, value: style, range: whole)
            for (pattern, tint) in [("\\+\\d+", (codeStyle.added ?? palette.added)), ("−\\d+", (codeStyle.removed ?? palette.removed))] {
                for match in (try? NSRegularExpression(pattern: pattern))?.matches(in: value, range: whole) ?? [] {
                    output.addAttribute(.foregroundColor, value: tint, range: match.range)
                }
            }
            for (pattern, tint) in [("^\\+ .*$", (codeStyle.added ?? palette.added)), ("^− .*$", (codeStyle.removed ?? palette.removed))] {
                for match in (try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines))?.matches(in: value, range: whole) ?? [] {
                    output.addAttribute(.foregroundColor, value: tint, range: match.range)
                }
            }
            if item.status == TranscriptPresentation.changesReverted {
                output.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                      .foregroundColor: palette.secondaryLabel], range: whole)
            }
            return (output, sourceOffsets)
        }
        let references = presentation.kind == .assistant || presentation.kind == .user ? TranscriptContentIndex.parse(value) : []
        for reference in references where reference.labelRange.length > 0 {
            // Deliberately not NSAttributedString.Key.link: Organic shares these pixels without link behavior.
            output.addAttributes([.transcriptReference: reference.target.raw,
                .foregroundColor: palette.accent,
                .font: font(bodyFont.pointSize / scale, scale: scale, weight: .medium)], range: reference.labelRange)
        }
        if value.utf8.count <= 256 * 1024 {
            if let headings = try? NSRegularExpression(pattern: "^#{1,6} .*$", options: [.anchorsMatchLines]) {
                for match in headings.matches(in: value, range: NSRange(location: 0, length: output.length)) {
                    output.addAttribute(.font, value: font(bodyFont.pointSize / scale, scale: scale, weight: .semibold), range: match.range)
                }
            }
            // One pass over the text finds every kind of code; the formatting and the markup removal below share it.
            let code = TranscriptPresentation.codeSyntax(in: value)
            let fencedStyle = style.mutableCopy() as! NSMutableParagraphStyle
            fencedStyle.lineHeightMultiple = 1; fencedStyle.paragraphSpacing = 0
            for range in code.blocks {
                output.addAttributes([.font: font(12, scale: scale, mono: true, codeStyle: codeStyle), .paragraphStyle: fencedStyle,
                                      .foregroundColor: (codeStyle.text ?? palette.codeText)], range: range)
            }
            for range in code.delimiters {
                output.addAttributes([.font: font(11, scale: scale, mono: true, codeStyle: codeStyle), .foregroundColor: palette.tertiaryLabel], range: range)
            }
            for range in code.inline {
                output.addAttributes([.font: font(12, scale: scale, mono: true, codeStyle: codeStyle), .foregroundColor: (codeStyle.text ?? palette.codeText)], range: range)
            }
            for range in code.content {
                output.addAttribute(.backgroundColor, value: codeStyle.resolvedFill, range: range)
            }
            // Codex answers show no markup: bullets for "- ", bold labels without their asterisks, inline code and
            // code blocks without their backticks and fences. Every range above was found in the original text, so the
            // markup is removed last, from the end backwards.
            if presentation.kind == .assistant {
                func inFence(_ r: NSRange) -> Bool { code.blocks.contains { NSIntersectionRange($0, r).length > 0 } }
                if let bullets = try? NSRegularExpression(pattern: "^(\\s*)- ", options: [.anchorsMatchLines]) {
                    for match in bullets.matches(in: value, range: NSRange(location: 0, length: output.length)) where !inFence(match.range) {
                        output.replaceCharacters(in: NSRange(location: NSMaxRange(match.range(at: 1)), length: 1), with: "•")
                    }
                }
                var markup: [NSRange] = code.delimiters + references.flatMap(\.markup)
                for inline in code.inline {
                    markup.append(NSRange(location: inline.location - 1, length: 1))
                    markup.append(NSRange(location: NSMaxRange(inline), length: 1))
                }
                if let bold = try? NSRegularExpression(pattern: "\\*\\*([^*\\n]+)\\*\\*") {
                    for match in bold.matches(in: value, range: NSRange(location: 0, length: output.length)) where !inFence(match.range) && !code.inline.contains(where: { NSLocationInRange(match.range.location, $0) }) {
                        output.enumerateAttribute(.font, in: match.range(at: 1)) { _, run, _ in
                            if !code.content.contains(where: { NSIntersectionRange($0, run).length > 0 }) {
                                output.addAttribute(.font, value: font(bodyFont.pointSize / scale, scale: scale, weight: .semibold), range: run)
                            }
                        }
                        markup.append(NSRange(location: match.range.location, length: 2))
                        markup.append(NSRange(location: NSMaxRange(match.range(at: 1)), length: 2))
                    }
                }
                var removed = IndexSet()
                for range in markup { removed.insert(integersIn: range.location..<NSMaxRange(range)) }
                for indices in removed.rangeView.reversed() {
                    let range = NSRange(location: indices.lowerBound, length: indices.count)
                    output.deleteCharacters(in: range)
                    sourceOffsets.removeSubrange(range.location..<NSMaxRange(range))
                }
            } else if presentation.kind == .user {
                for range in references.flatMap(\.markup).sorted(by: { $0.location > $1.location }) {
                    output.deleteCharacters(in: range); sourceOffsets.removeSubrange(range.location..<NSMaxRange(range))
                }
            }
        } else {
            for range in references.flatMap(\.markup).sorted(by: { $0.location > $1.location }) {
                output.deleteCharacters(in: range); sourceOffsets.removeSubrange(range.location..<NSMaxRange(range))
            }
        }
        return (output, sourceOffsets)
    }
    /// A work row's one line, as Codex words it: what was done, with commands and file names in code type and a
    /// file's added and removed lines in green and red.
    static func activityLine(_ item: TranscriptItem, presentation: RowPresentation, scale: CGFloat) -> NSAttributedString {
        activityLine(item, presentation: presentation, scale: scale, codeStyle: .init())
    }
    static func activityLine(_ item: TranscriptItem, presentation: RowPresentation, scale: CGFloat, codeStyle: NativeTranscriptCodeStyle) -> NSAttributedString {
        let palette = NativePalette.self
        let quiet: [NSAttributedString.Key: Any] = [.font: font(12.5, scale: scale), .foregroundColor: palette.secondaryLabel]
        let code: [NSAttributedString.Key: Any] = [.font: font(12, scale: scale, mono: true, codeStyle: codeStyle),
                                                   .foregroundColor: (codeStyle.text ?? palette.codeText).withAlphaComponent(0.85)]
        let line = NSMutableAttributedString()
        for part in NativeTranscriptPresentation.activityParts(item, presentation: presentation) {
            let attributes: [NSAttributedString.Key: Any] = switch part.style {
            case .say: quiet
            case .code: code
            case .added: [.font: font(12, scale: scale, weight: .medium), .foregroundColor: (codeStyle.added ?? palette.added)]
            case .removed, .failed: [.font: font(12, scale: scale, weight: .medium), .foregroundColor: (codeStyle.removed ?? palette.removed)]
            }
            line.append(NSAttributedString(string: part.text, attributes: attributes))
        }
        return line
    }

    // One sizing stack, never an NSTextView. Reusing it also avoids thousands of font/layout allocations
    // while the virtual document refines cold heights in short main-actor batches.
    private static let sizingStorage = NSTextStorage()
    private static let sizingLayout = NSLayoutManager()
    private static let sizingContainer: NSTextContainer = {
        let container = NSTextContainer()
        container.lineFragmentPadding = 0
        sizingStorage.addLayoutManager(sizingLayout); sizingLayout.addTextContainer(container)
        return container
    }()
    private static func measured(_ text: NSAttributedString, width: CGFloat, maximumLines: Int = 0) -> NSSize {
        let container = sizingContainer, layout = sizingLayout
        sizingStorage.setAttributedString(text)
        container.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        container.maximumNumberOfLines = maximumLines
        container.lineBreakMode = maximumLines == 0 ? .byWordWrapping : .byTruncatingTail
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let baseFont = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let fallback = baseFont.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
        return NSSize(width: ceil(used.width), height: max(fallback, ceil(used.height)))
    }
    /// Line-box padding that yields `optical` points from the bubble edge to cap top and to the last baseline.
    private static func userPadding(scale: CGFloat, optical: CGFloat = 12) -> (top: CGFloat, bottom: CGFloat) {
        let f = font(13, scale: scale)
        let lineHeight = f.ascender - f.descender + f.leading
        let extraAbove = lineHeight * (userLineHeightMultiple - 1)
        let aboveCap = extraAbove + f.ascender - f.capHeight
        return (max(2, optical - aboveCap), max(2, optical + f.descender))
    }
    static func geometry(item: TranscriptItem, presentation: RowPresentation, tableWidth: CGFloat, scale: CGFloat,
                         isTurnStart: Bool, expanded: Bool, showsMeta: Bool, attributedText: NSAttributedString,
                         workedFor: String? = nil, measuredBody: NSSize? = nil) -> TranscriptGeometry {
        let columnWidth = max(1, min(740, tableWidth - 2 * gutter)), columnX = (tableWidth - columnWidth) / 2
        let metaHeight = ceil(16 * scale)
        if TranscriptPresentation.isActivity(item.rowKind) && !expanded {
            // One line: the state mark, the words, a chevron that opens the full row.
            let top: CGFloat = isTurnStart ? 22 : 3, bottom: CGFloat = 3
            let marked = presentation.statusKind != .none
            let mark: CGFloat = marked ? ceil(16 * scale) : 0
            let chevron = ceil(16 * scale)
            let textX = columnX + mark
            let line = measured(attributedText, width: max(1, columnWidth - mark - chevron - 4), maximumLines: 1)
            let body = NSRect(x: textX, y: top, width: line.width, height: line.height)
            let indicator = marked ? NSRect(x: columnX, y: body.midY - ceil(12 * scale) / 2, width: ceil(12 * scale), height: ceil(12 * scale)) : nil
            let more = NSRect(x: body.maxX + 2, y: body.midY - chevron / 2, width: chevron, height: chevron)
            return TranscriptGeometry(rowHeight: ceil(body.maxY + bottom), metaRect: nil, bubbleRect: nil, bodyRect: body,
                moreButtonRect: more, ruleRect: nil, maximumLines: 1,
                isCompact: true, indicatorRect: indicator)
        }
        let divider = workedFor.map { _ in ceil(18 * scale) } ?? 0
        let top: CGFloat = (isTurnStart ? 22 : 6) + (divider > 0 ? divider + 12 : 0), bottom: CGFloat = 6
        if presentation.isPlaceholder && !TranscriptPresentation.isActivity(item.rowKind) {
            let meta = NSRect(x: columnX, y: top, width: columnWidth, height: metaHeight)
            return TranscriptGeometry(rowHeight: ceil(top + metaHeight + bottom), metaRect: meta, bubbleRect: nil,
                bodyRect: NSRect(x: columnX, y: meta.maxY, width: columnWidth, height: 0),
                moreButtonRect: nil, ruleRect: nil, maximumLines: 0)
        }
        let bodyY = top + (showsMeta ? metaHeight + 4 : 0)
        var textX = columnX, textWidth = columnWidth, padX: CGFloat = 0, padTop: CGFloat = 0, padBottom: CGFloat = 0
        var cardX = columnX, cardWidth = columnWidth
        let lineLimit: Int
        switch presentation.kind {
        case .user:
            padX = 12
            (padTop, padBottom) = userPadding(scale: scale)
            let maximum = max(1, min(columnWidth * 0.8, 620) - padX * 2)
            let natural = measured(attributedText, width: maximum)
            cardWidth = min(columnWidth, max(36, min(maximum, natural.width) + padX * 2))
            cardX = columnX + columnWidth - cardWidth; textX = cardX + padX
            textWidth = max(1, cardWidth - padX * 2); lineLimit = 0
        case .reasoning:
            textX += 12; textWidth = max(1, textWidth - 12); lineLimit = 3
        case .tool:
            padX = 12; padTop = 10; padBottom = 10; textX += padX; textWidth = max(1, textWidth - padX * 2); lineLimit = 8
        case .notice:
            padX = 12; padTop = 10; padBottom = 10; textX += padX; textWidth = max(1, textWidth - padX * 2); lineLimit = 0
        case .assistant: lineLimit = 0
        }
        let full = measuredBody ?? measured(attributedText, width: textWidth)
        let limited = lineLimit > 0 ? measured(attributedText, width: textWidth, maximumLines: lineLimit) : full
        // An opened work row can always fold back to its one line.
        let collapsible = (lineLimit > 0 && full.height > limited.height + 0.5) || TranscriptPresentation.isActivity(item.rowKind)
        let visible = collapsible && !expanded ? limited : full
        let body = NSRect(x: textX, y: bodyY + padTop, width: textWidth, height: visible.height)
        let buttonHeight = ceil(18 * scale)
        let more = collapsible ? NSRect(x: textX, y: body.maxY + 4, width: min(textWidth, max(84, 84 * scale)), height: buttonHeight) : nil
        let contentBottom = more?.maxY ?? body.maxY
        let card: NSRect?
        switch presentation.kind {
        case .user, .tool, .notice: card = NSRect(x: cardX, y: bodyY, width: cardWidth, height: contentBottom - bodyY + padBottom)
        default: card = nil
        }
        let actions = presentation.kind == .user && card != nil
            ? NSRect(x: cardX, y: card!.maxY + 3, width: cardWidth, height: ceil(18 * scale)) : nil
        let rowBottom = actions?.maxY ?? card?.maxY ?? contentBottom
        let meta = showsMeta ? NSRect(x: cardX, y: top, width: cardWidth, height: metaHeight) : nil
        let rule = presentation.kind == .reasoning ? NSRect(x: columnX, y: bodyY, width: 2, height: contentBottom - bodyY) : nil
        let dividerRect = divider > 0 ? NSRect(x: columnX, y: top - divider - 6, width: columnWidth, height: divider) : nil
        return TranscriptGeometry(rowHeight: ceil(rowBottom + bottom), metaRect: meta, bubbleRect: card,
            bodyRect: body, moreButtonRect: more, ruleRect: rule,
            maximumLines: collapsible && !expanded ? lineLimit : 0, dividerRect: dividerRect, dividerText: workedFor,
            actionsRect: actions)
    }
}
