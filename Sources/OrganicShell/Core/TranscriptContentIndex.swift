import Foundation

/// UTF-16 locators only: no attributed strings, views, resource data or inferred step quotes.
final class TranscriptContentIndex {
    private struct Value {
        var text: String, references: [TranscriptReference]
        var tailStart: Int, fence: Bool
    }
    private var values: [String: Value] = [:]
    private var sourceOrder: [String] = []
    private var sourceIDs = Set<String>()
    private(set) var parsedUnits = 0
    func removeAll() { values.removeAll(); sourceOrder = []; sourceIDs = [] }
    func references(for item: TranscriptItem) -> [TranscriptReference] {
        guard item.rowKind == .assistant || item.rowKind == .user else { values[item.id] = nil; return [] }
        if let old = values[item.id], old.text.utf8.elementsEqual(item.text.utf8) { return old.references }
        var start = 0, fence = false, kept: [TranscriptReference] = []
        if let old = values[item.id], item.text.utf8.starts(with: old.text.utf8) {
            // Seal only complete LF lines outside a fence. An unfinished destination stays in the tail.
            start = old.tailStart; fence = old.fence
            kept = old.references.filter { NSMaxRange($0.range) <= start }
        }
        let tail = (item.text as NSString).substring(from: start)
        parsedUnits += tail.utf16.count
        let prefix = fence ? "```\n" : "", shift = start - prefix.utf16.count
        let refs = kept + Self.parse(prefix + tail).map {
            TranscriptReference(range: NSRange(location: $0.range.location + shift, length: $0.range.length),
                labelRange: NSRange(location: $0.labelRange.location + shift, length: $0.labelRange.length), target: $0.target)
        }
        let raw = tail as NSString
        var cursor = 0, sealed = start, sealedFence = fence
        while cursor < raw.length {
            let line = raw.lineRange(for: NSRange(location: cursor, length: 0)), end = NSMaxRange(line)
            if raw.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") { fence.toggle() }
            if raw.character(at: end - 1) == 10 { sealed = start + end; sealedFence = fence }
            cursor = end
        }
        values[item.id] = Value(text: item.text, references: refs, tailStart: sealed, fence: sealedFence)
        return refs
    }
    func sources(in items: [TranscriptItem]) -> [SourceLocator] {
        let ids = Set(items.map(\.id)); values = values.filter { ids.contains($0.key) }
        sourceOrder = items.map(\.id)
        sourceIDs = ids
        for item in items { _ = references(for: item) }
        return indexedSources
    }
    func updateSource(_ item: TranscriptItem) {
        if sourceIDs.insert(item.id).inserted { sourceOrder.append(item.id) }
        _ = references(for: item)
    }
    var indexedSources: [SourceLocator] {
        sourceOrder.flatMap { id in (values[id]?.references ?? []).map { SourceLocator(itemID: id, range: $0.range, target: $0.target) } }
    }
    static func parse(_ text: String) -> [TranscriptReference] {
        let raw = text as NSString
        let excluded = codeExclusions(text).sorted { $0.location < $1.location }
        var result: [TranscriptReference] = [], i = 0, excludedIndex = 0
        func escaped(_ p: Int) -> Bool {
            var n = p, count = 0
            while n > 0, raw.character(at: n - 1) == 92 { count += 1; n -= 1 }
            return count % 2 == 1
        }
        while i < raw.length {
            while excludedIndex < excluded.count, NSMaxRange(excluded[excludedIndex]) <= i { excludedIndex += 1 }
            if excludedIndex < excluded.count, NSLocationInRange(i, excluded[excludedIndex]) { i = NSMaxRange(excluded[excludedIndex]); continue }
            let c = raw.character(at: i)
            if c == 91, !escaped(i) {
                let image = i > 0 && raw.character(at: i - 1) == 33
                var end = i + 1
                while end < raw.length, raw.character(at: end) != 10,
                      raw.character(at: end) != 93 || escaped(end) { end += 1 }
                if end + 1 < raw.length, raw.character(at: end) == 93, raw.character(at: end + 1) == 40 {
                    var close = end + 2, depth = 1
                    var quote: UInt16?, angle = false
                    while close < raw.length, raw.character(at: close) != 10 {
                        let unit = raw.character(at: close)
                        if !escaped(close) {
                            if let active = quote { if unit == active { quote = nil } }
                            else if angle { if unit == 62 { angle = false } }
                            else if unit == 60, raw.substring(with: NSRange(location: end + 2, length: close - end - 2)).trimmingCharacters(in: .whitespaces).isEmpty { angle = true }
                            else if [34,39].contains(unit), close > end + 2, [9,32].contains(raw.character(at: close - 1)) { quote = unit }
                            else if unit == 40 { depth += 1 }
                            else if unit == 41 { depth -= 1; if depth == 0 { break } }
                        }
                        close += 1
                    }
                    if depth == 0 {
                        let destination = raw.substring(with: NSRange(location: end + 2, length: close - end - 2))
                        if !image, let destination = Self.destination(destination), let target = ReferenceTarget(destination) {
                            result.append(.init(range: NSRange(location: i, length: close + 1 - i),
                                labelRange: NSRange(location: i + 1, length: end - i - 1), target: target))
                        }
                    }
                    i = min(raw.length, close + 1); continue
                }
            }
            let remaining = NSRange(location: i, length: raw.length - i)
            if c == 104, (raw.substring(with: NSRange(location: i, length: min(8, remaining.length))).hasPrefix("https://") ||
                         raw.substring(with: NSRange(location: i, length: min(7, remaining.length))).hasPrefix("http://")),
               i == 0 || !CharacterSet.alphanumerics.contains(UnicodeScalar(raw.character(at: i - 1)) ?? " ") {
                var end = i
                while end < raw.length, ![9,10,13,32,60,62,34,96].contains(raw.character(at: end)) { end += 1 }
                var opens = 0, closes = 0
                for position in i..<end { if raw.character(at: position) == 40 { opens += 1 }; if raw.character(at: position) == 41 { closes += 1 } }
                while end > i {
                    let last = raw.character(at: end - 1)
                    if [46,44,59,33,63,93].contains(last) { end -= 1 }
                    else if last == 41, closes > opens { end -= 1; closes -= 1 }
                    else { break }
                }
                let range = NSRange(location: i, length: end - i)
                if let target = ReferenceTarget(raw.substring(with: range)) { result.append(.init(range: range, labelRange: range, target: target)) }
                i = max(i + 1, end); continue
            }
            i += 1
        }
        return result
    }
    private static func codeExclusions(_ text: String) -> [NSRange] {
        if text.utf8.count <= 256 * 1024 {
            let code = TranscriptPresentation.codeSyntax(in: text)
            return code.blocks + code.inline + code.delimiters
        }
        // The legacy Markdown formatter has a size boundary. References still exclude code beyond it.
        let raw = text as NSString
        var ranges: [NSRange] = [], cursor = 0, fence: Int?
        while cursor < raw.length {
            let line = raw.lineRange(for: NSRange(location: cursor, length: 0)), end = NSMaxRange(line)
            if raw.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                if let start = fence { ranges.append(NSRange(location: start, length: end - start)); fence = nil }
                else { fence = cursor }
            } else if fence == nil {
                func tick(_ at: Int) -> Bool {
                    guard raw.character(at: at) == 96, (at == cursor || raw.character(at: at - 1) != 96),
                          at + 1 == end || raw.character(at: at + 1) != 96 else { return false }
                    var prior = at, slashes = 0
                    while prior > cursor, raw.character(at: prior - 1) == 92 { prior -= 1; slashes += 1 }
                    return slashes % 2 == 0
                }
                var at = cursor
                while at < end {
                    if tick(at) {
                        var close = at + 1
                        while close < end, !tick(close) { close += 1 }
                        if close < end { ranges.append(NSRange(location: at, length: close + 1 - at)); at = close + 1; continue }
                    }
                    at += 1
                }
            }
            cursor = end
        }
        if let start = fence { ranges.append(NSRange(location: start, length: raw.length - start)) }
        return ranges
    }
    private static func destination(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard raw.length > 0 else { return nil }
        var end = 0, start = 0
        if raw.character(at: 0) == 60 {
            start = 1; end = 1
            while end < raw.length, raw.character(at: end) != 62 { end += 1 }
            guard end < raw.length else { return nil }
        } else {
            while end < raw.length {
                if [9,32].contains(raw.character(at: end)), end == 0 || raw.character(at: end - 1) != 92 { break }
                end += 1
            }
        }
        let titleStart = start == 1 ? end + 1 : end
        let title = raw.substring(from: titleStart).trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
            guard let first = title.first, let last = title.last,
                  (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "(" && last == ")") else { return nil }
        }
        let target = raw.substring(with: NSRange(location: start, length: end - start)) as NSString
        let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ ".utf16)
        var units: [UInt16] = [], i = 0
        while i < target.length {
            if target.character(at: i) == 92, i + 1 < target.length, punctuation.contains(target.character(at: i + 1)) { i += 1 }
            units.append(target.character(at: i)); i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }
    static func quoteCounts(_ samples: [TranscriptQuoteSample]) -> [(String, Int, Int, [String: Int])] {
        var seen = Set<String>(), eligible: [TranscriptQuoteSample] = [], excluded = 0, duplicates = 0
        for sample in samples {
            guard seen.insert(sample.blockID).inserted else { duplicates += 1; continue }
            if sample.eligible && sample.type != .text { eligible.append(sample) } else { excluded += 1 }
        }
        // B1 has no proven step-quote association yet. Unknown provenance is missing, never guessed.
        var rows = TranscriptBlock.allCases.filter { $0 != .text }.map { kind in
            let values = eligible.filter { $0.type == kind }
            let reasons = Dictionary(grouping: values, by: { $0.reason.rawValue }).mapValues(\.count)
            return (kind.rawValue, values.count, values.count, reasons)
        }
        rows.append(("excluded", excluded + duplicates, 0, ["not_applicable": excluded, "duplicate": duplicates]))
        return rows
    }
}
