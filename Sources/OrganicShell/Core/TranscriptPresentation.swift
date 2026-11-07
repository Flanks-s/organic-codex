import Foundation

// Ported from ui07 TranscriptPresentation.swift. Changes: rows carry a RowKind instead of
// wire role/type strings; user and assistant rows have no speaker label (Canopy 2026-10-21);
// tool statuses follow the Canopy prototype (waiting, declined, cancelled); an info notice
// exists for compaction.

enum RowStatusKind: Equatable { case none, progress, waiting, failed, stopped, declined, other }

struct RowPresentation: Equatable {
    let kind: RowKind
    let label: String
    let symbol: String?
    let statusText: String
    let statusKind: RowStatusKind
    let isPlaceholder: Bool
    var isProgress: Bool { statusKind == .progress }
    var metaText: String {
        if label.isEmpty { return statusText }
        return statusText.isEmpty ? label : label + " · " + statusText
    }
}

/// One run of a work row's line: plain words, code (commands and file names), a file's added or removed lines, a failure.
struct TranscriptActivityPart: Equatable, Sendable {
    enum Style: Equatable, Sendable { case say, code, added, removed, failed }
    let text: String
    let style: Style
}

/// Display-only decisions. No state, transport, persistence or attributed-text IO.
enum TranscriptPresentation {
    static func presentation(for item: TranscriptItem) -> RowPresentation {
        let label: String, symbol: String?
        switch item.rowKind {
        case .user, .assistant: label = ""; symbol = nil
        case .reasoning: label = "Reasoning"; symbol = "brain"
        case .tool(let tool):
            switch tool {
            case .command: label = "Command"; symbol = "terminal"
            case .fileChange: label = "File Change"; symbol = "doc.text"
            case .toolCall: label = "Tool Call"; symbol = "hammer"
            case .webSearch: label = "Web Search"; symbol = "globe"
            case .other: label = "Tool"; symbol = "wrench.and.screwdriver"
            }
        case .notice(let notice):
            switch notice {
            case .error: label = "Error"; symbol = "xmark.octagon.fill"
            case .warning: label = "Warning"; symbol = "exclamationmark.triangle.fill"
            case .info where isChangesCard(item):
                let files = item.text.split(separator: "\n").count
                label = "\(files) file\(files == 1 ? "" : "s") changed"; symbol = "doc.on.doc"
            case .info: label = "Context"; symbol = "arrow.down.right.and.arrow.up.left"
            }
        }
        if isChangesCard(item) {
            let reverted = item.status == changesReverted
            return RowPresentation(kind: item.rowKind, label: label, symbol: symbol, statusText: reverted ? "Reverted" : "",
                                   statusKind: reverted ? .stopped : .none, isPlaceholder: false)
        }
        let raw = item.status ?? "", status: String, statusKind: RowStatusKind
        switch raw.lowercased() {
        case "inprogress", "in_progress", "running", "started", "active":
            statusKind = .progress
            switch item.rowKind {
            case .assistant: status = "Writing…"
            case .reasoning: status = "Thinking…"
            case .tool: status = "Running…"
            default: status = "In Progress…"
            }
        case "waiting": status = "Waiting for approval"; statusKind = .waiting
        case "completed", "complete", "success", "succeeded", "idle", "unknown", "":
            status = ""; statusKind = .none
        case "failed", "error", "systemerror": status = "Failed"; statusKind = .failed
        case "interrupted", "aborted": status = "Stopped"; statusKind = .stopped
        case "cancelled", "canceled": status = "Cancelled"; statusKind = .stopped
        case "declined", "denied", "rejected": status = "Declined"; statusKind = .declined
        default: status = raw; statusKind = .other
        }
        let isPlaceholder = item.rowKind != .user && item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let displayedStatus: String
        if isPlaceholder && statusKind == .none {
            switch item.rowKind {
            case .reasoning: displayedStatus = "No summary"
            case .tool, .notice: displayedStatus = "No details"
            case .assistant: displayedStatus = "No text"
            case .user: displayedStatus = status
            }
        } else { displayedStatus = status }
        return RowPresentation(kind: item.rowKind, label: label, symbol: symbol, statusText: displayedStatus,
            statusKind: statusKind, isPlaceholder: isPlaceholder)
    }
    /// The card that ends a turn which edited files (ZCode, Codex): one "path  +N −M" line per file, with Undo and
    /// Review. An info notice marked by its status.
    static let changesStatus = "changes", changesReverted = "changes-reverted"
    static func isChangesCard(_ item: TranscriptItem) -> Bool {
        item.rowKind == .notice(.info) && (item.status == changesStatus || item.status == changesReverted)
    }

    /// Work rows (reasoning and tools). Codex shows each as one quiet line, "Thought for 6s", "Ran `swift build`",
    /// "Edited `SidebarView.swift` +9 −4", which opens into the full row; never a labelled Reasoning or Command block
    /// (2026-10-24 review r3).
    static func isActivity(_ kind: RowKind) -> Bool {
        switch kind {
        case .reasoning, .tool: true
        default: false
        }
    }

    /// A work row's one line as Codex words it ("Thought for 6s", "Ran `swift build`", "Edited `SidebarView.swift` +9 −4"),
    /// as words with their styles. The transcript draws it (TranscriptLayout.activityLine) and the brief column says the
    /// same thing for the row it is on now, so the two can be matched element for element (2026-10-25 discussion).
    static func activityParts(_ item: TranscriptItem, presentation: RowPresentation) -> [TranscriptActivityPart] {
        var parts: [TranscriptActivityPart] = []
        func say(_ text: String) { parts.append(TranscriptActivityPart(text: text, style: .say)) }
        func code(_ text: String) { parts.append(TranscriptActivityPart(text: text, style: .code)) }
        let first = String(item.text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
        let status = presentation.statusKind
        switch item.rowKind {
        case .reasoning:
            say(presentation.isProgress ? "Thinking" : "Thought for \(thoughtSeconds(item))s")
        case .tool(.fileChange):
            let verb = switch status {
            case .progress: "Editing "
            case .waiting: "Waiting for approval · Edit "
            case .failed: "Couldn’t edit "
            case .declined: "Declined edit · "
            case .stopped: "Stopped editing "
            default: "Edited "
            }
            say(verb)
            let files = item.text.split(separator: "\n").map { String($0) }
            for (i, entry) in files.enumerated() {
                let words = entry.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                code(((words.first ?? entry) as NSString).lastPathComponent)
                for word in words.dropFirst() where word.dropFirst() != "0" {
                    if word.hasPrefix("+") { parts.append(TranscriptActivityPart(text: " " + word, style: .added)) }
                    else if word.hasPrefix("−") || word.hasPrefix("-") { parts.append(TranscriptActivityPart(text: " " + word, style: .removed)) }
                }
                if i < files.count - 1 { say(", ") }
            }
        case .tool(.webSearch):
            say(presentation.isProgress ? "Searching the web for “" : "Searched the web for “"); say(first); say("”")
        case .tool(.command):
            switch status {
            case .progress: say("Running "); code(first)
            case .waiting: say("Waiting for approval · "); code(first)
            case .failed: say("Ran "); code(first); parts.append(TranscriptActivityPart(text: " · failed", style: .failed))
            case .declined: say("Declined "); code(first)
            case .stopped: say("Stopped "); code(first)
            default: say("Ran "); code(first)
            }
        default:
            say(presentation.isProgress ? "Calling " : "Called "); code(first)
        }
        return parts
    }

    /// The divider Codex draws between a turn's work and its answer ("Worked for 1m 4s"), on the answer's row once it
    /// is written. The mock has no clock for past turns, so the duration is a stable pick per turn.
    static func workedFor(index: Int, items: [TranscriptItem]) -> String? {
        guard items.indices.contains(index), index > 0, items[index].rowKind == .assistant,
              isActivity(items[index - 1].rowKind), items[index - 1].turnID == items[index].turnID,
              !presentation(for: items[index]).isProgress else { return nil }
        let seconds = [8, 14, 23, 41, 64, 107, 172][seed(items[index].id) % 7]
        return "Worked for " + (seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s")
    }

    /// How long a finished thought took, stable per row.
    static func thoughtSeconds(_ item: TranscriptItem) -> Int { [2, 3, 4, 6, 8, 11, 14][seed(item.id) % 7] }

    static func seed(_ text: String) -> Int {
        text.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }

    static func isTurnStart(index: Int, items: [TranscriptItem]) -> Bool {
        guard items.indices.contains(index) else { return false }
        return index == 0 || items[index].turnID != items[index - 1].turnID
    }
    static func showsMeta(index: Int, items: [TranscriptItem], presentation: RowPresentation) -> Bool {
        guard items.indices.contains(index) else { return false }
        if presentation.isPlaceholder { return true }
        switch presentation.kind {
        case .user, .assistant: return !presentation.statusText.isEmpty
        default: return true
        }
    }

    /// A message's code, as UTF-16 ranges, found in one pass. Input is bounded.
    struct CodeSyntax {
        /// Code content, excluding source delimiters.
        var content: [NSRange] = []
        /// Entire fenced blocks, including opening/closing delimiter lines and line endings.
        var blocks: [NSRange] = []
        var delimiters: [NSRange] = []
        /// Inline single-backtick content outside fenced blocks; delimiters are unchanged.
        var inline: [NSRange] = []
    }
    /// A message's first line with text in it: the brief's goal or input, and where the transcript draws it, which have
    /// to be the same characters for the line to fly between them.
    static func firstLine(of text: NSString) -> NSRange {
        var start = 0
        while start < text.length {
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let line = NSRange(location: start, length: contentsEnd - start)
            if text.substring(with: line).contains(where: { !$0.isWhitespace }) { return line }
            start = end
        }
        return NSRange(location: 0, length: 0)
    }

    static func codeSyntax(in text: String) -> CodeSyntax {
        guard text.utf8.count <= 256 * 1024 else { return CodeSyntax() }
        let string = text as NSString
        var result = CodeSyntax(), fenceStart: Int?, fenceLineStart: Int?, cursor = 0
        while cursor < string.length {
            let line = string.lineRange(for: NSRange(location: cursor, length: 0))
            let value = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("```") {
                result.delimiters.append(line)
                if let start = fenceStart {
                    if line.location > start { result.content.append(NSRange(location: start, length: line.location - start)) }
                    if let blockStart = fenceLineStart {
                        result.blocks.append(NSRange(location: blockStart, length: NSMaxRange(line) - blockStart))
                    }
                    fenceStart = nil; fenceLineStart = nil
                } else { fenceStart = NSMaxRange(line); fenceLineStart = line.location }
            } else if fenceStart == nil {
                var position = line.location
                let end = NSMaxRange(line)
                func singleTick(_ index: Int) -> Bool {
                    guard string.character(at: index) == 96,
                          (index == line.location || string.character(at: index - 1) != 96),
                          (index + 1 == end || string.character(at: index + 1) != 96) else { return false }
                    var escapes = 0, before = index - 1
                    while before >= line.location && string.character(at: before) == 92 { escapes += 1; before -= 1 }
                    return escapes % 2 == 0
                }
                while position < end {
                    guard singleTick(position) else { position += 1; continue }
                    var closing = position + 1
                    while closing < end && !singleTick(closing) { closing += 1 }
                    if closing < end {
                        if closing > position + 1 {
                            let range = NSRange(location: position + 1, length: closing - position - 1)
                            result.content.append(range); result.inline.append(range)
                        }
                        position = closing + 1
                    } else { break }
                }
            }
            cursor = NSMaxRange(line)
        }
        if let start = fenceStart, start < string.length { result.content.append(NSRange(location: start, length: string.length - start)) }
        if let blockStart = fenceLineStart { result.blocks.append(NSRange(location: blockStart, length: string.length - blockStart)) }
        return result
    }

    /// The composer context row's live status (Canopy prototype wording).
    static func activityPhrase(items: [TranscriptItem], running: Bool, sending: Bool, stopping: Bool, waiting: Bool) -> String? {
        if sending { return "Sending…" }
        if stopping { return "Stopping…" }
        guard running else { return nil }
        if waiting { return "Waiting for your approval" }
        guard let item = items.last(where: { presentation(for: $0).isProgress }) else { return "Working…" }
        switch item.rowKind {
        case .tool(.command):
            let line = String((item.text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "").prefix(60))
            return "Running Command" + (line.isEmpty ? "" : " · " + line)
        case .tool(.fileChange): return "Editing files…"
        case .tool: return "Running " + presentation(for: item).label
        case .reasoning: return "Thinking…"
        case .assistant: return "Writing…"
        default: return "Working…"
        }
    }
}
