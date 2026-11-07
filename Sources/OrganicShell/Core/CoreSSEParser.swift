import Foundation

/// Incremental UTF-8 SSE parser. A cursor advances only after a complete, valid event.
/// Retains partial lines across arbitrary network chunks, including split CRLF/UTF-8.
struct CoreSSEParser: Sendable {
    private(set) var lastEventID: Int
    private var line = Data()
    private var afterCR = false
    private var firstLine = true
    private var eventID: String?
    private var eventName: String?
    private var dataLines: [String] = []

    init(since: Int = 0) { lastEventID = since }

    mutating func append(_ data: Data) throws -> [CoreEvent] {
        var events: [CoreEvent] = []
        for byte in data {
            if afterCR {
                afterCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = try consumeLine() { events.append(event) }
                afterCR = byte == 13
            } else {
                line.append(byte)
            }
        }
        return events
    }

    /// SSE dispatch requires a blank line. A truncated frame at EOF is discarded so a
    /// reconnect using the last delivered cursor can receive it in full.
    mutating func finish() {
        line.removeAll(keepingCapacity: false)
        resetEvent()
        afterCR = false
    }

    private mutating func consumeLine() throws -> CoreEvent? {
        guard var text = String(data: line, encoding: .utf8) else {
            throw malformed("Core event stream contains invalid UTF-8.")
        }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty { return try dispatch() }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = parts[0]
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "id": if !value.contains("\0") { eventID = value }
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break // Core keepalives, retry hints and future SSE fields need no action.
        }
        return nil
    }

    private mutating func dispatch() throws -> CoreEvent? {
        defer { resetEvent() }
        guard !dataLines.isEmpty else { return nil }
        let event = try JSONDecoder().decode(CoreEvent.self, from: Data(dataLines.joined(separator: "\n").utf8))
        if let eventID, Int(eventID) != event.id {
            throw malformed("Core event id does not match its SSE envelope.")
        }
        if let eventName, !eventName.isEmpty, eventName != event.method {
            throw malformed("Core event method does not match its SSE envelope.")
        }
        guard event.id > lastEventID else { return nil }
        lastEventID = event.id
        return event
    }

    private mutating func resetEvent() {
        eventID = nil
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
    }

    private func malformed(_ message: String) -> CoreError {
        CoreError(code: nil, message: message, data: nil, httpStatus: nil)
    }
}
