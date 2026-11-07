import AppKit

/// The brief form laid out from the conversation's summary, as the product's NativeBriefSurface.layout does
/// (reference §D "brief 的生成规则和排版"): the goal under its "Goal" note, the user's later messages, each stretch's
/// "Worked for" note and narration (or the "…" while it has nothing to say yet), and under the latest line the current
/// activity, or the state. Every part is its own image, so a flight can stand in for the part it lands on.
@MainActor struct BriefLayout {
    /// The transcript element a part's flight starts from (product MorphAnchor).
    enum Anchor: Hashable {
        /// A user message (the goal or a Steer), by item.
        case goal(String)
        /// The "Worked for" divider over an answer, by the answer's item.
        case worked(String)
        /// The row the agent is on, by item.
        case activity(String)
        /// A finished stretch's narration, from its answer's lead.
        case segment(String)
    }
    enum Kind: Equatable { case note, lyric, activity, state, dots }
    struct Part {
        let id: String
        let anchor: Anchor?
        let kind: Kind
        /// Brief-local, top-left origin, on whole points.
        var frame: CGRect
        /// On the latest line (shown at 1) or an older one (`Look.olderLine`).
        let current: Bool
        /// Which summary line it is on, counted from the top (flights stagger by line, counted from the bottom).
        var line = 0
        /// A narration's answer and its retelling with source spans: a segment flight's two ends.
        var answerID: String?
        var paraphrase: Paraphrase?
        let image: CGImage?
        /// The text as laid out, for a lyric's flight ends cut from its lines.
        let block: TextBlock?
        /// Dots the brief draws itself, and where, part-local: the "…" of a stretch with nothing to say yet, or an
        /// activity's compact dots in place of the transcript's spinner.
        let dots: (size: DotsLayer.Size, frame: CGRect)?
    }

    let parts: [Part]
    let height: CGFloat
    let lyricStyle: TextStyle
    let lineCount: Int

    /// `width` is the brief's text width (the column less 20 a side); `showsState` puts the state under the latest line
    /// when no column header island says it (product: `headerTop == nil`).
    /// `room`: how tall the brief can be seen. Only the lines that can reach it are laid out: the brief is bottom-aligned
    /// and clipped, so the rest of a long conversation never shows, and laying it out grew with every stretch (a 14-minute
    /// session took 200 ms per update, user 10-30). `drawsText`: false when the caller redraws every note and lyric itself.
    init(_ log: SummaryLog, width: CGFloat, columnWidth: CGFloat, scale: CGFloat, showsState: Bool, room: CGFloat? = nil, drawsText: Bool = true, lastLineIsCurrent: Bool = true) {
        let style = Look.lyric(columnWidth: columnWidth)
        lyricStyle = style
        let size = style.font.pointSize, lineGap = (size * 0.62).rounded()
        var lines = log.lines
        // The shortest line is one row of text and its gap; two more so a partly clipped top line still draws.
        if let room { lines = Array(lines.suffix(Int((room / (size + lineGap)).rounded(.up)) + 2)) }
        var parts: [Part] = [], y: CGFloat = 0

        func note(_ id: String, _ text: String, trailing: Bool, anchor: Anchor?, at top: CGFloat, current: Bool) -> Part {
            let block = TextBlock(text, style: Look.briefNote, width: width, maxLines: 1)
            // The frame is the image's own size: a layer resizes its contents to its frame, and the image is a little
            // wider than the text (self-test: a frame the text's width squeezed every glyph).
            let image = drawsText ? block.image(scale: scale) : nil
            let size = image?.size ?? block.size
            return Part(id: id, anchor: anchor, kind: .note,
                        frame: CGRect(origin: CGPoint(x: trailing ? (width - block.size.width).rounded() : 0, y: top), size: size),
                        current: current, image: image?.image, block: block, dots: nil)
        }
        func lyric(_ id: String, _ text: String, trailing: Bool, anchor: Anchor?, at top: CGFloat, current: Bool) -> Part {
            // Right-aligned blocks keep the full width and set each line's x (the goal's flights cut from them).
            let block = TextBlock(text, style: style, width: width, alignment: trailing ? .right : .left)
            let image = drawsText ? block.image(scale: scale) : nil
            return Part(id: id, anchor: anchor, kind: .lyric, frame: CGRect(origin: CGPoint(x: 0, y: top), size: image?.size ?? block.size),
                        current: current, image: image?.image, block: block, dots: nil)
        }

        for (index, line) in lines.enumerated() {
            let current = lastLineIsCurrent && index == lines.count - 1
            var row: [Part] = []
            let id: String
            switch line {
            case .goal(let goal):
                id = goal.itemID
                row.append(note(id + ".note", "Goal", trailing: true, anchor: nil, at: 0, current: current))
                row.append(lyric(id + ".main", goal.text, trailing: true, anchor: .goal(goal.itemID), at: row[0].frame.maxY + 3, current: current))
            case .input(let input):
                id = input.itemID
                row.append(lyric(id + ".main", input.text, trailing: true, anchor: .goal(input.itemID), at: 0, current: current))
            case .stretch(let stretch):
                id = stretch.id
                var top: CGFloat = 0
                if let worked = stretch.workedFor {
                    row.append(note(id + ".note", worked, trailing: false, anchor: stretch.answerID.map(Anchor.worked), at: 0, current: current))
                    top = row[0].frame.maxY + 3
                }
                if let narration = stretch.narration {
                    let anchor: Anchor? = stretch.answerID != nil && !narration.lead.isEmpty ? .segment(stretch.id) : nil
                    var part = lyric(id + ".main", narration.text, trailing: false, anchor: anchor, at: top, current: current)
                    part.answerID = stretch.answerID; part.paraphrase = narration
                    row.append(part)
                } else {
                    let box = DotsLayer.box(.large(size))
                    row.append(Part(id: id + ".main", anchor: nil, kind: .dots, frame: CGRect(origin: CGPoint(x: 0, y: top), size: box),
                                    current: current, image: nil, block: nil, dots: (.large(size), CGRect(origin: .zero, size: box))))
                }
            }
            if current {
                let at = (row.map(\.frame.maxY).max() ?? 0) + 7
                if log.state == .running, let activity = log.activity {
                    row.append(Self.activity(id + ".activity", activity, dots: !log.waiting, width: width, at: at, scale: scale))
                } else if showsState, let state = Self.stateNote(log.state, waiting: log.waiting) {
                    row.append(Self.state(id + ".state", state, width: width, at: at, scale: scale))
                }
            }
            let height = row.map(\.frame.maxY).max() ?? 0
            parts += row.map { var p = $0; p.frame.origin.y += y; p.line = index; return p }
            y += height + lineGap
        }
        self.parts = parts
        lineCount = lines.count
        height = lines.isEmpty ? 0 : y - lineGap
    }

    /// The agent's current row in the brief's words: 12 semibold, code 11.5 mono, single line cut with "…", after the
    /// compact dots while it has nothing else to say (NativeMorphRenderPacket.swift:365-399).
    /// Where an activity's text starts in its part: after the compact dots while it shows them.
    static func activityTextInset(_ part: Part) -> CGFloat { part.dots == nil ? 0 : 17 }

    private static func activity(_ id: String, _ activity: SummaryLog.Activity, dots: Bool, width: CGFloat, at top: CGFloat, scale: CGFloat) -> Part {
        let text = NSMutableAttributedString()
        for part in activity.parts {
            let font: NSFont, color: NSColor
            switch part.style {
            case .say: font = .systemFont(ofSize: 12, weight: .semibold); color = Look.secondary
            case .code: font = .monospacedSystemFont(ofSize: 11.5, weight: .regular); color = Look.ink.withAlphaComponent(Look.ink.alphaComponent * 0.78)
            case .added: font = .systemFont(ofSize: 12, weight: .medium); color = .systemGreen
            case .removed, .failed: font = .systemFont(ofSize: 12, weight: .medium); color = .systemRed
            }
            text.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: color]))
        }
        let occupied: CGFloat = dots ? 17 : 0, height = Look.activity.lineHeight
        let line = TextBlock.attributedLine(text, width: width - occupied, x: occupied, height: height, scale: scale)
        return Part(id: id, anchor: .activity(activity.itemID), kind: .activity, frame: CGRect(x: 0, y: top, width: line?.size.width ?? occupied, height: height),
                    current: true, image: line?.image, block: nil,
                    dots: dots ? (.compact, CGRect(x: 0, y: ((height - 12) / 2).rounded(), width: 12, height: 12)) : nil)
    }

    typealias StateNote = (text: String, symbol: String?, color: NSColor, dots: Bool)

    /// Under the latest line when no header says it (NativeBriefSurface.swift:233-244).
    static func stateNote(_ state: SummaryLog.State, waiting: Bool) -> StateNote? {
        switch state {
        case .running: waiting ? nil : ("Working", nil, Look.secondary, true)
        case .waiting: ("Waiting for your approval", "hand.raised.fill", .systemYellow, false)
        case .asking: ("Asking you a question", "questionmark.bubble.fill", .systemYellow, false)
        case .failedRunning: ("Error, still running", "exclamationmark.triangle.fill", .systemRed, false)
        case .failedStopped: ("Stopped by an error", "xmark.octagon.fill", .systemRed, false)
        case .done: ("Done", "checkmark.circle.fill", .systemGreen, false)
        case .idle: nil
        }
    }

    private static func state(_ id: String, _ note: StateNote, width: CGFloat, at top: CGFloat, scale: CGFloat) -> Part {
        let occupied: CGFloat = note.symbol == nil && !note.dots ? 0 : 18, height = Look.activity.lineHeight
        let text = NSAttributedString(string: note.text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: note.color])
        guard let line = TextBlock.attributedLine(text, width: width - occupied, x: occupied, height: height, scale: scale) else {
            return Part(id: id, anchor: nil, kind: .state, frame: CGRect(x: 0, y: top, width: 1, height: height), current: true, image: nil, block: nil, dots: nil)
        }
        var image = line.image
        if let symbol = note.symbol, let drawn = symbolImage(symbol, color: note.color, height: height, scale: scale, under: line.image) { image = drawn }
        return Part(id: id, anchor: nil, kind: .state, frame: CGRect(x: 0, y: top, width: line.size.width, height: height),
                    current: true, image: image, block: nil,
                    dots: note.dots ? (.compact, CGRect(x: 0, y: ((height - 12) / 2).rounded(), width: 12, height: 12)) : nil)
    }

    /// The state's symbol, 12 pt in its colour, drawn into the line's image at its leading edge.
    private static func symbolImage(_ name: String, color: NSColor, height: CGFloat, scale: CGFloat, under line: CGImage) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let s = max(1, scale), w = line.width, h = line.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(line, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: s, y: s)
        let size = symbol.size, box = CGRect(x: ((12 - size.width) / 2).rounded(), y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
        symbol.draw(in: box)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
