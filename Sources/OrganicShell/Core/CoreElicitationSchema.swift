import Foundation

/// Core-only copy of M1 requestedSchema validation; no dependency on a transcript view.
/// Errors describe paths, never submitted values (which may be secret).
enum CoreElicitationSchema {
    private static let supported: Set<String> = ["$schema", "$id", "$comment", "title", "description", "default", "examples", "readOnly", "writeOnly", "deprecated", "type", "enum", "const", "properties", "required", "additionalProperties", "minLength", "maxLength", "pattern", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minItems", "maxItems", "uniqueItems", "items", "allOf", "anyOf", "oneOf", "not"]
    static func error(_ value: JSONValue, schema: JSONValue, path: String = "$", depth: Int = 0) -> String? {
        guard depth < 64 else { return "\(path): schema is too deeply nested." }
        if depth == 0, let failure = unsupported(schema, path: path, depth: 0) { return failure }
        if schema.boolValue == false { return "\(path): value is not permitted." }
        for branch in schema["allOf"]?.arrayValue ?? [] {
            if let failure = error(value, schema: branch, path: path, depth: depth + 1) { return failure }
        }
        if let branches = schema["anyOf"]?.arrayValue, !branches.contains(where: { error(value, schema: $0, path: path, depth: depth + 1) == nil }) { return "\(path): no requested alternative matches." }
        if let branches = schema["oneOf"]?.arrayValue, branches.filter({ error(value, schema: $0, path: path, depth: depth + 1) == nil }).count != 1 { return "\(path): exactly one requested alternative must match." }
        if let excluded = schema["not"], error(value, schema: excluded, path: path, depth: depth + 1) == nil { return "\(path): value is excluded by the request." }
        let types = schema["type"]?.stringValue.map { [$0] } ?? schema["type"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !types.isEmpty && !types.contains(where: { matches(value, type: $0) }) { return "\(path): expected \(types.joined(separator: " or "))." }
        if let choices = schema["enum"]?.arrayValue, !choices.contains(value) { return "\(path): choose an allowed value." }
        if let constant = schema["const"], constant != value { return "\(path): value does not match the request." }
        if let object = value.objectValue {
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let missing = required.first(where: { object[$0] == nil }) { return "Complete required field: \(path).\(missing)." }
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in object.keys.sorted() {
                if let child = properties[key], let failure = error(object[key]!, schema: child, path: path + "." + key, depth: depth + 1) { return failure }
                if properties[key] == nil {
                    if schema["additionalProperties"]?.boolValue == false { return "\(path).\(key): field is not requested." }
                    if let extra = schema["additionalProperties"], extra.objectValue != nil,
                       let failure = error(object[key]!, schema: extra, path: path + "." + key, depth: depth + 1) { return failure }
                }
            }
        }
        if let string = value.stringValue {
            if let min = schema["minLength"]?.intValue, string.unicodeScalars.count < min { return "\(path): text is too short." }
            if let max = schema["maxLength"]?.intValue, string.unicodeScalars.count > max { return "\(path): text is too long." }
            if let pattern = schema["pattern"]?.stringValue {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return "\(path): invalid requested pattern." }
                if regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) == nil { return "\(path): text does not match the requested pattern." }
            }
        }
        if let number = value.doubleValue {
            if !number.isFinite { return "\(path): enter a finite number." }
            if let min = schema["minimum"]?.doubleValue, number < min { return "\(path): number is below the minimum." }
            if let max = schema["maximum"]?.doubleValue, number > max { return "\(path): number exceeds the maximum." }
            if let min = schema["exclusiveMinimum"]?.doubleValue, number <= min { return "\(path): number must exceed the minimum." }
            if let max = schema["exclusiveMaximum"]?.doubleValue, number >= max { return "\(path): number must be below the maximum." }
            if let divisor = schema["multipleOf"]?.doubleValue {
                guard divisor > 0, divisor.isFinite else { return "\(path): invalid requested number interval." }
                let quotient = number / divisor
                if abs(quotient - quotient.rounded()) > 1e-9 { return "\(path): number does not match the requested interval." }
            }
        }
        if let values = value.arrayValue {
            if let min = schema["minItems"]?.intValue, values.count < min { return "\(path): too few entries." }
            if let max = schema["maxItems"]?.intValue, values.count > max { return "\(path): too many entries." }
            if schema["uniqueItems"]?.boolValue == true, values.enumerated().contains(where: { index, entry in values.prefix(index).contains(entry) }) { return "\(path): entries must be unique." }
            if let itemSchema = schema["items"] {
                for (index, item) in values.enumerated() {
                    if let failure = error(item, schema: itemSchema, path: "\(path)[\(index)]", depth: depth + 1) { return failure }
                }
            }
        }
        return nil
    }
    /// Inspect the whole schema first: an unsupported branch under `not` must not become a successful negation.
    private static func unsupported(_ schema: JSONValue, path: String, depth: Int) -> String? {
        guard depth < 64 else { return "\(path): schema is too deeply nested." }
        if schema.boolValue != nil { return nil }
        guard let object = schema.objectValue else { return "\(path): unsupported requested schema shape." }
        if let unknown = object.keys.sorted().first(where: { !supported.contains($0) }) { return "\(path): unsupported schema constraint \(unknown)." }
        if let properties = schema["properties"]?.objectValue {
            for key in properties.keys.sorted() {
                if let failure = unsupported(properties[key]!, path: path + "." + key, depth: depth + 1) { return failure }
            }
        }
        for key in ["not", "items", "additionalProperties"] {
            if let child = schema[key], let failure = unsupported(child, path: path, depth: depth + 1) { return failure }
        }
        for key in ["allOf", "anyOf", "oneOf"] {
            if let branches = schema[key]?.arrayValue {
                for branch in branches {
                    if let failure = unsupported(branch, path: path, depth: depth + 1) { return failure }
                }
            }
        }
        return nil
    }
    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): true
        case ("number", .number(let number)): number.isFinite
        case ("integer", .number(let number)): number.isFinite && number.rounded() == number
        default: false
        }
    }
}
