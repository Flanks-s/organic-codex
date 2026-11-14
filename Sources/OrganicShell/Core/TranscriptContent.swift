import Foundation

enum ReferenceTarget: Equatable, Hashable {
    case web(String), file(String)
    var raw: String { switch self { case .web(let s), .file(let s): s } }
    init?(_ raw: String) {
        let lower = raw.lowercased()
        if (lower.hasPrefix("https://") || lower.hasPrefix("http://")),
           let url = URL(string: raw), url.host != nil { self = .web(raw) }
        else if raw.hasPrefix("/") || raw.hasPrefix("./") || raw.hasPrefix("../") || raw.hasPrefix("~/") ||
                    lower.hasPrefix("file://") || raw.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil ||
                    (raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil &&
                     raw.range(of: #"^[^\s<>]+\.[A-Za-z0-9]+(?:(?:#L|:)\d+(?:[-:]\d+)?)?$"#, options: .regularExpression) != nil) {
            self = .file(raw)
        } else { return nil }
    }
    var fileLocation: (path: String, line: Int?) {
        var path = raw, line: Int?
        if let match = path.range(of: #"(?:#L|:)(\d+)(?:[-:]\d+)?$"#, options: .regularExpression) {
            line = Int(path[match].drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber }))
            path = String(path[..<match.lowerBound])
        }
        if path.lowercased().hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        return (path.removingPercentEncoding ?? path, line)
    }
}

struct SourceLocator: Equatable {
    let itemID: String
    let range: NSRange
    let target: ReferenceTarget
}

struct TranscriptReference: Equatable {
    let range: NSRange
    let labelRange: NSRange
    let target: ReferenceTarget
    var markup: [NSRange] {
        guard range != labelRange else { return [] }
        return [NSRange(location: range.location, length: labelRange.location - range.location),
                NSRange(location: NSMaxRange(labelRange), length: NSMaxRange(range) - NSMaxRange(labelRange))]
    }
}

enum TranscriptBlock: String, CaseIterable, Codable {
    case text, file, table, code, json, diff, approval, annotation, image, diagram
    case staticChart = "static_chart", htmlChart = "html_chart", mermaid
    case textAnnotation = "text_annotation", pdfAnnotation = "pdf_annotation", finding
}
enum StepQuoteMissingReason: String, CaseIterable, Codable {
    case provenance = "missing_provenance", association = "missing_association"
    case publicText = "no_public_text", resource = "unavailable_resource"
}
/// Metadata projection supplied by the caller's chosen range; identity is used only for deduplication.
struct TranscriptQuoteSample: Codable {
    let blockID: String
    let type: TranscriptBlock
    let eligible: Bool
    let reason: StepQuoteMissingReason
}
enum StepQuote: Equatable {
    case missing(String)
    // B1 does not infer provenance or synthesize a summary from transcript text.
}
struct TranscriptReferenceRequest: Equatable {
    let source: SourceLocator
}
struct TranscriptReferencePreview: Equatable {
    enum State: Equatable { case loading, ready, unavailable }
    var state: State
    var text = ""
    var message = ""
}
