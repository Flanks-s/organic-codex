import Foundation

/// Deterministic stand-in for a summary model, preserving source spans for native flights.
enum MockBrief {
    static func paraphrase(_ source: String, of sourceID: String, playful: Bool) -> Paraphrase {
        let lead = leadClause(of: source)
        guard !lead.isEmpty else { return Paraphrase(text: playful ? "on it" : "Working on it.") }
        let swaps = playful ? playfulSwaps : plainSwaps
        var text = "", spans: [Paraphrase.Span] = []
        for (index, token) in lead.split(separator: " ").map(String.init).enumerated() {
            let (core, tail) = peel(token)
            if !text.isEmpty { text += " " }
            let start = text.count
            if let swap = swaps[core.lowercased()] {
                var word = swap
                if core.first?.isUppercase == true, !(playful && index == 0) { word = word.prefix(1).uppercased() + word.dropFirst() }
                text += word
                spans.append(.init(range: start..<text.count, kind: .synonym, sourceID: sourceID, source: core))
            } else {
                var word = core
                // The playful tone talks in lower case, except for names (`SidebarView.swift`, `UI`).
                if playful, index == 0, !isName(core) { word = word.lowercased() }
                text += word
                if !stopWords.contains(core.lowercased()), core.count > 1 {
                    spans.append(.init(range: start..<text.count, kind: .same, sourceID: sourceID, source: core))
                }
            }
            text += tail
        }
        return Paraphrase(text: text, spans: spans, lead: lead)
    }

    /// The source's first real sentence, without markup, cut to its main clause.
    static func leadClause(of source: String) -> String {
        var sentences: [String] = []
        for line in source.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            // Labels ("**What changed**"), headings, fences and code lines say nothing about the work.
            if line.hasPrefix("**") && line.hasSuffix("**") || line.hasPrefix("#") || line.hasPrefix("```") { continue }
            let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "- ", with: "", options: .anchored)
            sentences += plain.components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        // A one-word sentence ("Fixed.", "Done.") gives way to the one after it.
        guard var lead = sentences.first(where: { $0.split(separator: " ").count > 2 }) ?? sentences.first else { return "" }
        for cut in [", so ", ", and ", " — ", "; ", ": ", ", which "] {
            if let range = lead.range(of: cut) { lead = String(lead[..<range.lowerBound]) }
        }
        lead = lead.trimmingCharacters(in: CharacterSet(charactersIn: ".:; "))
        if lead.count > 72 {
            let words = lead.split(separator: " ")
            var cut = ""
            // Up to the first word that would not fit: a later, shorter one would make a phrase the answer never says.
            for word in words {
                guard cut.count + word.count < 70 else { break }
                cut += (cut.isEmpty ? "" : " ") + word
            }
            lead = cut
        }
        return lead
    }

    private static func peel(_ token: String) -> (core: String, tail: String) {
        var core = token, tail = ""
        while let last = core.last, ",.;:!?)”\"".contains(last) { tail = String(last) + tail; core.removeLast() }
        return (core, tail)
    }

    private static func isName(_ word: String) -> Bool {
        word.contains(".") || word.dropFirst().contains(where: \.isUppercase)
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "to", "in", "of", "and", "or", "for", "on", "at", "is", "it", "its", "it’s", "was", "so", "with",
        "as", "by", "be", "i", "just", "that", "this", "are", "were", "has", "had", "have", "from", "now", "only", "where",
        "not", "no", "but", "into", "than", "then", "there", "here", "every", "all",
    ]

    /// Words the brief model might put in place of the source's, plain.
    private static let plainSwaps: [String: String] = [
        "removed": "dropped", "clamped": "capped", "clamps": "caps", "added": "wrote", "checked": "reviewed",
        "moved": "shifted", "fixed": "repaired", "found": "spotted", "caching": "keeping", "cut": "trimmed",
        "build": "assemble", "builds": "assembles", "indexed": "catalogued", "skipped": "left out", "issues": "problems",
        "changed": "touched", "change": "edit", "outline": "plan", "retry": "second try", "failed": "broke",
        "worked": "paid off", "stare": "look", "fine": "okay", "clean": "tidy", "reading": "going through",
        "smallest": "narrowest", "failing": "broken", "appears": "shows up", "comes": "derives", "computed": "worked out",
        "known": "set", "wraps": "breaks", "needs": "calls for", "small": "minor", "look": "check", "running": "executing",
    ]
    /// The same, playful (spec §6.1's second tone).
    private static let playfulSwaps: [String: String] = [
        "removed": "ditched", "clamped": "reined in", "clamps": "reins in", "added": "slipped in", "checked": "eyeballed",
        "moved": "scooted", "fixed": "patched up", "found": "sniffed out", "caching": "hoarding", "cut": "chopped",
        "build": "cobble together", "builds": "cobbles together", "issues": "gremlins", "changed": "fiddled with",
        "nothing": "zilch", "fine": "totally fine", "retry": "do-over", "failed": "flopped", "worked": "did the trick",
        "stare": "squint", "clean": "spotless", "reading": "skimming", "smallest": "teeniest", "failing": "wonky",
        "appears": "pops up", "comes": "hails", "computed": "crunched", "wraps": "spills", "needs": "wants",
        "small": "tiny", "look": "poke around", "running": "whirring through",
    ]
}
