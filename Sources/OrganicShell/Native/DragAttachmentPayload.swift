import AppKit
import UniformTypeIdentifiers

/// Immutable input to the attachment lane. No scene, conversation lookup, file I/O or sending lives here.
struct DragAttachmentPayload: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        let composer: UUID
        let conversationID: String?
        let generation: UInt64
    }
    struct Session: Equatable, Sendable {
        let id: UUID
        let target: Target
        init(id: UUID = UUID(), target: Target) { self.id = id; self.target = target }
    }
    /// Source coordinates are UTF-16, like NSTextView and the transcript's source-offset table.
    struct Quote: Codable, Equatable, Sendable {
        let conversationID: String
        let itemID: String
        let range: NSRange
        let exactText: String
        var isValid: Bool {
            !conversationID.isEmpty && !itemID.isEmpty && range.location != NSNotFound &&
            range.location >= 0 && range.length > 0 && range.location <= Int.max - range.length && !exactText.isEmpty
        }
        var source: JSONValue {
            ["conversationID": .string(conversationID), "itemID": .string(itemID),
             "location": .number(Double(range.location)), "length": .number(Double(range.length))]
        }
    }
    struct File: Equatable, Sendable {
        let id: String
        let url: URL
        init(url: URL, id: String? = nil) {
            self.url = url.standardizedFileURL
            self.id = id ?? "drag.file." + CoreAttachmentInputEncoding.digest(Data(self.url.absoluteString.utf8))
        }
        var attachment: Attachment? {
            guard url.isFileURL, !id.isEmpty else { return nil }
            let type = UTType(filenameExtension: url.pathExtension)
            return Attachment(id: id, name: url.lastPathComponent,
                symbol: type?.conforms(to: .image) == true ? "photo" : "doc", url: url, mimeType: type?.preferredMIMEType)
        }
    }
    struct MockMoon: Equatable, Sendable {
        let id: String
        let name: String
        let text: String
    }
    enum Value: Equatable, Sendable {
        case file(File), quote(Quote), mockMoon(MockMoon)
        var deduplicationKey: String? { attachment?.id }
        var attachment: Attachment? {
            switch self {
            case .file(let file): return file.attachment
            case .quote(let quote):
                guard quote.isValid else { return nil }
                let input: JSONValue = ["type": "text", "text": .string(quote.exactText)]
                guard let id = DragAttachmentPayload.quoteID(quote) else { return nil }
                return Attachment(id: id, name: "Quote", symbol: "text.quote", input: input)
            case .mockMoon(let moon):
                guard !moon.id.isEmpty, !moon.text.isEmpty else { return nil }
                return Attachment(id: "drag.mockMoon." + moon.id, name: moon.name, symbol: "moon",
                    input: ["type": "text", "text": .string(moon.text)])
            }
        }
    }
    let values: [Value]
    let attachments: [Attachment]
    init(values: [Value]) {
        self.values = values
        attachments = values.compactMap(\.attachment)
    }
    var isQuote: Bool { !values.isEmpty && values.allSatisfy { if case .quote = $0 { return true }; return false } }
    var previewName: String {
        let files = attachments
        return files.count == 1 ? files[0].name : "\(files.count) attachments"
    }

    // Attachment.id survives FileState/sidecar persistence and is never appended to Core's input array.
    private static let quoteIDPrefix = "drag.quote.v1."
    private struct QuoteOrigin: Codable {
        let version: Int
        let conversationID: String
        let itemID: String
        let range: NSRange
        let snapshotSHA256: String
    }
    private static func quoteID(_ quote: Quote) -> String? {
        let origin = QuoteOrigin(version: 1, conversationID: quote.conversationID, itemID: quote.itemID,
            range: quote.range, snapshotSHA256: CoreAttachmentInputEncoding.digest(Data(quote.exactText.utf8)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(origin) else { return nil }
        return quoteIDPrefix + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    /// Decode local provenance from the opaque id and the exact snapshot from the ordinary text input.
    static func restoreQuote(from attachment: Attachment) -> Quote? {
        guard attachment.id.hasPrefix(quoteIDPrefix), attachment.id.utf8.count <= 64 * 1024,
              attachment.input?["type"]?.stringValue == "text", let text = attachment.input?["text"]?.stringValue else { return nil }
        let encoded = String(attachment.id.dropFirst(quoteIDPrefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = encoded + String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let origin = try? JSONDecoder().decode(QuoteOrigin.self, from: data),
              origin.version == 1, origin.snapshotSHA256 == CoreAttachmentInputEncoding.digest(Data(text.utf8)) else { return nil }
        let quote = Quote(conversationID: origin.conversationID, itemID: origin.itemID, range: origin.range, exactText: text)
        return quote.isValid ? quote : nil
    }

    static let quoteType = NSPasteboard.PasteboardType("local.organic-shell.attachment-quote.v1")
    private struct References: Codable { let version: Int; let quotes: [Quote] }

    /// Adds only our representation; the native writer continues to own plain text/RTF and all other types.
    @MainActor @discardableResult static func writeQuotes(_ quotes: [Quote], to pasteboard: NSPasteboard) -> Bool {
        guard !quotes.isEmpty, quotes.allSatisfy(\.isValid),
              let data = try? JSONEncoder().encode(References(version: 1, quotes: quotes)) else { return false }
        pasteboard.addTypes([quoteType], owner: nil)
        return pasteboard.setData(data, forType: quoteType)
    }

    /// Pure decoding: no pasteboard mutation, URL access, conversation lookup or attachment publication.
    @MainActor static func decode(_ pasteboard: NSPasteboard) -> Self? {
        var values: [Value] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL {
                values.append(.file(File(url: url)))
            }
            if let data = item.data(forType: quoteType), data.count <= 8 * 1024 * 1024,
               let reference = try? JSONDecoder().decode(References.self, from: data), reference.version == 1,
               !reference.quotes.isEmpty, reference.quotes.allSatisfy(\.isValid) {
                values.append(contentsOf: reference.quotes.map(Value.quote))
            }
        }
        var seen: Set<String> = []
        values = values.filter { value in value.deduplicationKey.map { seen.insert($0).inserted } ?? false }
        return values.isEmpty ? nil : Self(values: values)
    }
}
