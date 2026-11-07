#if ISLAND_SELFTEST || TOOLS_SELFTEST || DEBUG_SELFTEST
import Foundation

/// Source-only verification shared by the three component gates. No product code uses this type.
enum PlainControlSourceAuditVerification {
    struct FileAudit {
        let url: URL
        let constructors: [String]
    }

    enum AuditError: Error {
        case missingSources(String)
        case unterminatedLiteralOrComment
    }

    /// The caller supplies the repository root through SOURCE_AUDIT_ROOT, or runs from that root.
    /// Never infer source ownership from a compiler's potentially flattened #filePath.
    static func sourceDirectory(component: String) throws -> URL {
        precondition(["Island", "Tools", "Debug"].contains(component))
        let root = ProcessInfo.processInfo.environment["SOURCE_AUDIT_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("Sources/OrganicShell/\(component)", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw AuditError.missingSources(directory.path) }
        return directory
    }

    static func audit(directory: URL) throws -> [FileAudit] {
        let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !$0.lastPathComponent.lowercased().contains("verification") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sources.isEmpty else { throw AuditError.missingSources(directory.path) }
        return try sources.map { url in
            FileAudit(url: url, constructors: try constructors(in: String(contentsOf: url, encoding: .utf8)))
        }
    }

    static func constructors(in source: String) throws -> [String] {
        let code = try codeOnly(source)
        let pattern = try NSRegularExpression(pattern: #"\bNS(?:Button|TextField|PopUpButton)\s*\("#)
        return pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)).map {
            String(code[Range($0.range, in: code)!])
        }
    }

    /// Preserve token separation and newlines while masking Swift strings and nested comments.
    /// Interpolation bodies are executable code, so scan them recursively rather than masking them.
    static func codeOnly(_ source: String) throws -> String {
        let bytes = Array(source.utf8)
        var result = bytes.map { $0 == 10 || $0 == 13 ? $0 : UInt8(32) }
        var index = 0
        func has(_ sequence: [UInt8], at offset: Int) -> Bool {
            offset + sequence.count <= bytes.count
                && bytes[offset..<(offset + sequence.count)].elementsEqual(sequence)
        }
        func scanString(hashes: Int, quotes: Int) throws {
            index += hashes + quotes
            let end = Array(repeating: UInt8(34), count: quotes) + Array(repeating: UInt8(35), count: hashes)
            let escape = [UInt8(92)] + Array(repeating: UInt8(35), count: hashes)
            while index < bytes.count {
                if has(end, at: index) { index += end.count; return }
                if has(escape, at: index) {
                    index += escape.count
                    if index < bytes.count && bytes[index] == 40 {
                        index += 1
                        try scanCode(interpolation: true)
                    } else {
                        index = min(index + 1, bytes.count)
                    }
                } else { index += 1 }
            }
            throw AuditError.unterminatedLiteralOrComment
        }
        func scanCode(interpolation: Bool) throws {
            var parentheses = 0
            while index < bytes.count {
                if has([47, 47], at: index) {
                    while index < bytes.count && bytes[index] != 10 && bytes[index] != 13 { index += 1 }
                    continue
                }
                if has([47, 42], at: index) {
                    var depth = 1
                    index += 2
                    while index < bytes.count && depth > 0 {
                        if has([47, 42], at: index) { depth += 1; index += 2 }
                        else if has([42, 47], at: index) { depth -= 1; index += 2 }
                        else { index += 1 }
                    }
                    guard depth == 0 else { throw AuditError.unterminatedLiteralOrComment }
                    continue
                }
                var hashes = 0
                while index + hashes < bytes.count && bytes[index + hashes] == 35 { hashes += 1 }
                if index + hashes < bytes.count && bytes[index + hashes] == 34 {
                    let quotes = has([34, 34, 34], at: index + hashes) ? 3 : 1
                    try scanString(hashes: hashes, quotes: quotes)
                    continue
                }
                if interpolation {
                    if bytes[index] == 40 { parentheses += 1 }
                    if bytes[index] == 41 {
                        if parentheses == 0 { index += 1; return }
                        parentheses -= 1
                    }
                }
                result[index] = bytes[index]
                index += 1
            }
            if interpolation { throw AuditError.unterminatedLiteralOrComment }
        }
        try scanCode(interpolation: false)
        return String(decoding: result, as: UTF8.self)
    }

    static func regressionChecks(directory: URL) throws -> [(Bool, String)] {
        let cases: [(String, String, Bool)] = [
            ("ordinary string", "let text = \"NSButton() NSTextField() NSPopUpButton()\"", false),
            ("raw string", "let text = ##\"NSButton()\"##", false),
            ("multiline string", "let text = \"\"\"\nNSButton()\n\"\"\"", false),
            ("raw multiline string", "let text = #\"\"\"\nNSButton()\n\"\"\"#", false),
            ("escaped quote", "let text = \"escaped \\\" quote NSButton()\"", false),
            ("nested comments", "// NSButton()\n/* NSTextField() /* nested */ NSPopUpButton() */", false),
            ("button code", "let button = NSButton()", true),
            ("field code with whitespace", "let field = NSTextField \n ()", true),
            ("popup code with comment", "let popup = NSPopUpButton/* comment */()", true),
            ("interpolation code", "let text = \"\\(NSButton())\"", true),
            ("raw interpolation code", "let text = #\"\\#(NSButton())\"#", true),
            ("identifier boundary", "let button = CustomNSButton()", false)
        ]
        var checks = try cases.map { name, source, forbidden in
            (try !constructors(in: source).isEmpty == forbidden, "§7.5 lexer: \(name)")
        }
        let owned = directory.appendingPathComponent("Owned", isDirectory: true)
        let sibling = directory.appendingPathComponent("Sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "let caption = \"NSButton()\" // NSTextField()".write(to: owned.appendingPathComponent("Caption.swift"), atomically: true, encoding: .utf8)
        try "let button = NSButton()".write(to: owned.appendingPathComponent("OtherVerification.swift"), atomically: true, encoding: .utf8)
        try "let button = NSButton()".write(to: sibling.appendingPathComponent("Outside.swift"), atomically: true, encoding: .utf8)
        let negative = owned.appendingPathComponent("Forbidden.swift")
        // The negative source is data for the audit, never compiled or added to product directories.
        try "let button = NSButton()".write(to: negative, atomically: true, encoding: .utf8)
        let failing = try audit(directory: owned)
        checks.append((failing.filter { !$0.constructors.isEmpty }.map { $0.url.lastPathComponent } == ["Forbidden.swift"],
                       "§7.5 negative fixture rejects real NSButton construction"))
        checks.append((failing.map { $0.url.lastPathComponent } == ["Caption.swift", "Forbidden.swift"],
                       "§7.5 scope excludes verification and sibling sources"))
        try FileManager.default.removeItem(at: negative)
        checks.append((try audit(directory: owned).allSatisfy { $0.constructors.isEmpty },
                       "§7.5 clean fixture ignores strings and comments"))
        // Keep the rejected source as reviewable evidence after the clean-fixture check.
        try "let button = NSButton()".write(to: negative, atomically: true, encoding: .utf8)
        return checks
    }

    static func run(component: String, evidenceDirectory: URL, check: (Bool, String) -> Void) throws {
        let directory = try sourceDirectory(component: component)
        let files = try audit(directory: directory)
        for file in files {
            check(file.constructors.isEmpty, "§7.5 static source audit \(component)/\(file.url.lastPathComponent)")
        }
        let regressions = try regressionChecks(directory: evidenceDirectory.appendingPathComponent("source-audit-fixtures"))
        for (passed, message) in regressions { check(passed, message) }
        let report: [String: Any] = [
            "component": component, "sourceDirectory": directory.path,
            "files": files.map { ["path": $0.url.path, "constructors": $0.constructors] as [String: Any] },
            "regressions": regressions.map { ["passed": $0.0, "check": $0.1] as [String: Any] }
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("source-audit.json"), options: .atomic)
    }
}
#endif
