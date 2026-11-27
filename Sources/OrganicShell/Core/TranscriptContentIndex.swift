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
    private(set) var sourceProjectionCount = 0
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
    @discardableResult func updateSource(_ item: TranscriptItem) -> Bool {
        let previous = values[item.id]?.references ?? []
        if sourceIDs.insert(item.id).inserted { sourceOrder.append(item.id) }
        return previous != references(for: item)
    }
    var indexedSources: [SourceLocator] {
        sourceProjectionCount += 1
        return sourceOrder.flatMap { id in (values[id]?.references ?? []).map { SourceLocator(itemID: id, range: $0.range, target: $0.target) } }
    }
    static func parse(_ text: String, onImage: ((TranscriptReference) -> Void)? = nil) -> [TranscriptReference] {
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
                        if !image || onImage != nil,
                           let destination = Self.destination(destination), let target = ReferenceTarget(destination) {
                            let range = NSRange(location: i, length: close + 1 - i)
                            let label = NSRange(location: i + 1, length: end - i - 1)
                            let reference = TranscriptReference(range: range, labelRange: label, target: target)
                            if image {
                                onImage?(reference)
                            } else {
                                result.append(reference)
                            }
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
        var rows = TranscriptBlock.allCases.filter { $0 != .text }.map { kind in
            let values = eligible.filter { $0.type == kind }
            let missing = values.compactMap(\.reason)
            let reasons = Dictionary(grouping: missing, by: \.rawValue).mapValues(\.count)
            return (kind.rawValue, values.count, missing.count, reasons)
        }
        rows.append(("excluded", excluded + duplicates, 0, ["not_applicable": excluded, "duplicate": duplicates]))
        return rows
    }
}

extension TranscriptContentIndex {
    /// Project only fields attached to this block by the original payload.
    func stepQuotes(for item: TranscriptItem) -> [(String, TranscriptBlock, StepQuote)] {
        func quote(_ text: String?, _ field: String, _ kind: StepQuote.Kind, range: NSRange? = nil) -> StepQuote {
            let span = range ?? NSRange(location: 0, length: text?.utf16.count ?? 0)
            return Self.original(text, .init(kind: kind, itemID: item.id, requestID: nil,
                                             revision: item.revision, field: field, range: span))
        }
        switch item.quoteFields {
        case .fileChanges(let paths):
            return paths.enumerated().map { i, path in
                let result = quote(path, "changes[\(i)].path", .fileChange)
                return ("\(item.id):diff:\(i)", .diff, result)
            }
        case .image(let field, let text):
            return [("\(item.id):image", .image, quote(text, field, .image))]
        case nil:
            break
        }
        guard item.rowKind == .assistant else { return [] }
        let raw = item.text as NSString
        let kind: StepQuote.Kind = item.phase == .commentary ? .commentary : .message
        func block(_ ref: TranscriptReference, type: TranscriptBlock) -> (String, TranscriptBlock, StepQuote) {
            let label = raw.substring(with: ref.labelRange)
            return ("\(item.id):\(type.rawValue):\(ref.range.location)", type,
                    quote(label, "text", kind, range: ref.labelRange))
        }
        var images: [TranscriptReference] = []
        let refs = item.text.contains("![") ? Self.parse(item.text, onImage: { images.append($0) })
            : references(for: item)
        let files = refs.compactMap { ref -> (String, TranscriptBlock, StepQuote)? in
            guard case .file = ref.target else { return nil }
            return block(ref, type: .file)
        }
        return files + images.map { block($0, type: .image) }
    }

    static func stepQuote(for approval: Approval) -> StepQuote {
        guard !approval.isSidechat else { return .missing(.provenance) }
        let params = approval.request["params"]
        for field in ["reason", "message", "command"] {
            guard let text = params?[field]?.stringValue, hasPublicText(text) else { continue }
            return requestQuote(text, field: "params." + field, requestID: approval.id,
                                itemID: approval.toolItemID.isEmpty ? nil : approval.toolItemID,
                                revision: approval.revision)
        }
        return .missing(approval.request == .null ? .provenance : .publicText)
    }

    static func stepQuote(for input: UserInputRequest, question: UserInputRequest.Question) -> StepQuote {
        guard let index = input.questions.firstIndex(where: { $0.id == question.id }) else {
            return .missing(.association)
        }
        return requestQuote(input.questions[index].prompt, field: "params.questions[\(index)].question",
                            requestID: input.id, revision: input.revision)
    }

    private static func requestQuote(_ text: String, field: String, requestID: String, itemID: String? = nil,
                                     revision: Int) -> StepQuote {
        let range = NSRange(location: 0, length: text.utf16.count)
        return original(text, .init(kind: .approval, itemID: itemID, requestID: requestID, revision: revision,
                                    field: field, range: range))
    }

    private static func hasPublicText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func original(_ text: String?, _ source: StepQuote.Source) -> StepQuote {
        guard let text, hasPublicText(text) else { return .missing(.publicText) }
        return .original(text, source)
    }
}
