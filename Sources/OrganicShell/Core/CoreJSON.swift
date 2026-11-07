import Foundation

// Copied unchanged from the current product (Sources/OrganicKit/Core/CoreJSON.swift, 2026-10-28) so mock
// events and a later Core SSE client share one wire type. Not shared: Shell v2 never edits that repository.

/// The Core wire format. Missing object keys remain nil; JSON null is an explicit value.
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var doubleValue: Double? { if case .number(let value) = self { value } else { nil } }
    var intValue: Int? { doubleValue.flatMap(Int.init(exactly:)) }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
                     ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(nilLiteral: ()) { self = .null }
}

struct CoreEvent: Codable, Sendable, Equatable {
    let id: Int
    let time: Double?
    let method: String
    let params: JSONValue
}

/// Preserves Core errors, including errors carried by a successful HTTP response.
/// Non-JSON HTTP failures retain their response body as a string in `data`.
struct CoreError: Error, Sendable, Equatable, LocalizedError {
    let code: Int?
    let message: String
    let data: JSONValue?
    let httpStatus: Int?

    var errorDescription: String? { message }
}
