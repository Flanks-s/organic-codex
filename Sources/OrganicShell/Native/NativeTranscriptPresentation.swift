import AppKit

/// Per-transcript injection point for the product's Appearance > Code Theme settings. No global mutable palette.
@MainActor struct NativeTranscriptCodeStyle: Equatable {
    var fontID = "sf"
    var pointSize: CGFloat = 12
    var text: NSColor?
    var fill: NSColor?
    var added: NSColor?
    var removed: NSColor?

    var resolvedFill:NSColor{guard let fill else{return NativePalette.codeFill};return NativeDisplayOptions.shared.state.reducesEffects ? NativeDisplayOptions.plate(fill,alpha:fill.alphaComponent):fill}
    func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let multiplier = pointSize.isFinite ? min(32, max(8, pointSize)) / 12 : 1
        let name: String? = switch fontID {
        case "menlo": "Menlo"
        case "monaco": "Monaco"
        case "courier": "Courier New"
        default: nil
        }
        return name.flatMap { NSFont(name: $0, size: size * multiplier) }
            ?? .monospacedSystemFont(ofSize: size * multiplier, weight: weight)
    }
}

/// Native display additions; wire models and the product's pure presentation API remain unchanged.
@MainActor enum NativeTranscriptPresentation {
    static func presentation(for item: TranscriptItem) -> RowPresentation {
        let p = TranscriptPresentation.presentation(for: item)
        if item.status?.lowercased() == "stopped" {
            return RowPresentation(kind: p.kind, label: p.label, symbol: p.symbol, statusText: "Stopped", statusKind: .stopped, isPlaceholder: p.isPlaceholder)
        }
        return p
    }
    static func activityParts(_ item: TranscriptItem, presentation: RowPresentation) -> [TranscriptActivityPart] {
        let p = presentation
        if item.rowKind == .reasoning {
            if p.isPlaceholder && !p.isProgress { return [.init(text: "No summary", style: .say)] }
            if p.statusKind != .none && !p.isProgress { return [.init(text: p.statusText, style: [.failed, .declined].contains(p.statusKind) ? .failed : .say)] }
            return TranscriptPresentation.activityParts(item, presentation: p)
        }
        let cancelled = ["cancelled", "canceled"].contains(item.status?.lowercased() ?? "")
        if item.rowKind == .tool(.command) {
            if cancelled { return [.init(text: "Cancelled ", style: .say), .init(text: firstLine(item.text), style: .code)] }
            if p.isPlaceholder { return [.init(text: p.isProgress ? "Running…" : p.statusText, style: .say)] }
            return TranscriptPresentation.activityParts(item, presentation: p)
        }
        if item.rowKind == .tool(.fileChange) {
            let verb: String = switch p.statusKind {
            case .progress: "Editing "
            case .waiting: "Waiting for approval · Edit "
            case .failed: "Couldn’t edit "
            case .declined: "Declined edit · "
            case .stopped: cancelled ? "Cancelled edit · " : "Stopped editing "
            default: "Edited "
            }
            var parts: [TranscriptActivityPart] = [.init(text: verb, style: .say)]
            let entries = item.text.split(separator: "\n").map(String.init)
            for (i, line) in entries.enumerated() {
                // Counts are suffix tokens; a file path itself can contain spaces, Unicode, '+' and '-'.
                let ns = line as NSString
                let suffix = try! NSRegularExpression(pattern: "(?:\\s+[+−-]\\d+)+\\s*$")
                let counts = suffix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))?.range
                let path = counts.map { ns.substring(to: $0.location) } ?? line
                parts.append(.init(text: (path as NSString).lastPathComponent, style: .code))
                if let counts {
                    for token in ns.substring(with: counts).split(whereSeparator: \.isWhitespace) {
                        guard let amount = Int(token.dropFirst()), amount != 0 else { continue }
                        parts.append(.init(text: " " + token, style: token.first == "+" ? .added : .removed))
                    }
                }
                if i < entries.count - 1 { parts.append(.init(text: ", ", style: .say)) }
            }
            if entries.isEmpty { parts.append(.init(text: "No details", style: .say)) }
            return parts
        }
        let searching = item.rowKind == .tool(.webSearch)
        var parts: [TranscriptActivityPart] = [.init(text: searching ? (p.isProgress ? "Searching the web for “" : "Searched the web for “") : (p.isProgress ? "Calling " : "Called "), style: .say)]
        parts.append(.init(text: item.text.isEmpty ? "No details" : firstLine(item.text), style: searching ? .say : .code))
        if searching { parts.append(.init(text: "”", style: .say)) }
        if !p.statusText.isEmpty && !p.isProgress && !p.isPlaceholder {
            parts.append(.init(text: " · " + p.statusText, style: [.failed, .declined].contains(p.statusKind) ? .failed : .say))
        }
        return parts
    }
    private static func firstLine(_ text: String) -> String { String(text.split(separator: "\n").first ?? "") }
}
