import AppKit
import Darwin

/// One persistent TextKit stack for an append-only assistant answer. Formatting restarts at the last source line,
/// carrying the fence state into that line; layout invalidates that paragraph instead of replacing the whole answer.
/// This uses TranscriptLayout.formatted, including its exact raw UTF-16 mapping, rather than a second Markdown dialect.
@MainActor final class NativeTranscriptStreamLayout {
    struct Edit {
        let baseGeneration: Int
        let range: NSRange
        let replacement: NSAttributedString
    }
    let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    private(set) var offsets: [Int] = []
    private(set) var generation = 0
    private(set) var edit: Edit?
    private(set) var formattedUnits = 0
    private(set) var size = NSSize.zero
    private var source: String
    private var sourceLength: Int
    private var rawTailStart = 0, displayTailStart = 0
    private var fenceBeforeTail = false
    private var plainTail = false
    private let width: CGFloat
    private let scale: CGFloat
    private let style: NativeTranscriptCodeStyle

    init(item: TranscriptItem, width: CGFloat, scale: CGFloat, style: NativeTranscriptCodeStyle) {
        source = item.text; sourceLength = item.text.utf16.count
        self.width = width; self.scale = scale; self.style = style
        container.lineFragmentPadding = 0
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = false; container.heightTracksTextView = false
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let value = TranscriptLayout.formatted(item, presentation: NativeTranscriptPresentation.presentation(for: item), scale: scale, codeStyle: style)
        storage.setAttributedString(value.text); offsets = value.sourceOffsets
        formattedUnits = (item.text as NSString).length
        checkpoint(item.text, sourceStart: 0, displayStart: 0, mapping: offsets, initialFence: false)
        measure()
    }

    /// Returns false for a replacement, width/style change or the formatter's large-input boundary. The caller then
    /// discards this cache and uses the ordinary complete formatter. Prefix proof is necessary with today's full-value
    /// Conversation notification; no event/delta is guessed or dropped.
    func append(_ item: TranscriptItem, width: CGFloat, scale: CGFloat, style: NativeTranscriptCodeStyle) -> Bool {
        guard self.width == width, self.scale == scale, self.style == style,
              item.text.utf8.count <= 256 * 1024, hasExactPrefix(item.text) else { return false }
        if item.text.utf8.count == source.utf8.count { return true }
        let addedStart = item.text.utf8.index(item.text.utf8.startIndex, offsetBy: source.utf8.count)
        let addition = String(decoding: item.text.utf8[addedStart...], as: UTF8.self)
        // An ordinary long paragraph must not be reformatted from its beginning for every letter. No delimiter or
        // newline can change the preceding plain text. Markdown-bearing unfinished lines use the contextual path.
        if plainTail, Self.isPlain(addition, allowingLineBreaks: true) {
            var fragment = item; fragment.text = addition
            let value = TranscriptLayout.formatted(fragment, presentation: NativeTranscriptPresentation.presentation(for: item), scale: scale, codeStyle: style)
            edit = Edit(baseGeneration: generation, range: NSRange(location: storage.length, length: 0), replacement: value.text)
            let displayStart = storage.length
            let mapping = Array(sourceLength..<(sourceLength + addition.utf16.count))
            storage.append(value.text)
            offsets.append(contentsOf: mapping)
            if addition.utf8.contains(10) {
                checkpoint(addition, sourceStart: sourceLength, displayStart: displayStart, mapping: mapping, initialFence: false)
            }
            sourceLength += addition.utf16.count; source = item.text; generation += 1
            formattedUnits += addition.utf16.count
            measure(); return true
        }
        let raw = item.text as NSString
        let tail = raw.substring(from: rawTailStart)
        let prefix = fenceBeforeTail ? "```\n" : ""
        var fragment = item; fragment.text = prefix + tail
        let value = TranscriptLayout.formatted(fragment, presentation: NativeTranscriptPresentation.presentation(for: item), scale: scale, codeStyle: style)
        let prefixCount = (prefix as NSString).length
        let mapping = value.sourceOffsets.map { $0 + rawTailStart - prefixCount }
        let range = NSRange(location: displayTailStart, length: storage.length - displayTailStart)
        edit = Edit(baseGeneration: generation, range: range, replacement: value.text)
        storage.replaceCharacters(in: range, with: value.text)
        offsets.replaceSubrange(displayTailStart..<offsets.count, with: mapping)
        formattedUnits += (fragment.text as NSString).length
        checkpoint(tail, sourceStart: rawTailStart, displayStart: displayTailStart, mapping: mapping, initialFence: fenceBeforeTail)
        source = item.text; sourceLength = raw.length; generation += 1
        measure()
        return true
    }

    /// Seal at LF only: the existing bold regex excludes LF, but permits bare CR/U+2028 inside a bold span. Parse
    /// all source line separators for fence state without accidentally sealing such a cross-line bold span.
    private func checkpoint(_ tail: String, sourceStart: Int, displayStart: Int, mapping: [Int], initialFence: Bool) {
        if !mapping.isEmpty, !mapping.contains(where: { $0 >= 0 }) {
            // A placeholder has no source glyphs. The first real delta must replace it, not append after it.
            rawTailStart = 0; displayTailStart = 0; fenceBeforeTail = false; plainTail = false; return
        }
        let raw = tail as NSString
        var cursor = 0, fence = initialFence, sealedFence = initialFence, nextStart = 0
        while cursor < raw.length {
            let line = raw.lineRange(for: NSRange(location: cursor, length: 0)), end = NSMaxRange(line)
            let last = raw.character(at: end - 1)
            guard let scalar = UnicodeScalar(last), CharacterSet.newlines.contains(scalar), !(last == 13 && end == raw.length) else { break }
            if raw.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") { fence.toggle() }
            if last == 10 { nextStart = end; sealedFence = fence }
            cursor = end
        }
        rawTailStart = sourceStart + nextStart; fenceBeforeTail = sealedFence
        displayTailStart = displayStart + (mapping.firstIndex(where: { $0 >= rawTailStart }) ?? mapping.count)
        plainTail = !sealedFence && Self.isPlain(raw.substring(from: nextStart))
    }
    private static func isPlain(_ value: String, allowingLineBreaks: Bool = false) -> Bool {
        !value.unicodeScalars.contains {
            switch $0.value {
            case 35, 42, 45, 96, 91, 93, 40, 41, 58, 47: return true
            case 10, 13, 0x2028, 0x2029: return !allowingLineBreaks
            default: return false
            }
        }
    }
    private func hasExactPrefix(_ value: String) -> Bool {
        guard value.utf8.count >= source.utf8.count else { return false }
        // String.hasPrefix is Unicode-canonical, which can accept a different raw UTF16 source. Exact bytes also
        // allow the common native UTF8 case to use memcmp rather than a Swift iterator over the growing prefix.
        let contiguous: Bool?? = value.utf8.withContiguousStorageIfAvailable { new in
            source.utf8.withContiguousStorageIfAvailable { old in
                old.isEmpty || memcmp(new.baseAddress!, old.baseAddress!, old.count) == 0
            }
        }
        if let outer = contiguous, let result = outer { return result }
        return value.utf8.starts(with: source.utf8)
    }
    private func measure() {
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let font = storage.length > 0 ? storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let fallback = font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
        size = NSSize(width: ceil(used.width), height: max(fallback, ceil(used.height)))
    }
}
