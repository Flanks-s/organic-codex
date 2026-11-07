import Foundation
import CryptoKit

/// Presentation-owned attachment payloads. References are scoped to the Core endpoint, not to a backend data dir.
/// Callers commit the small presentation record before removing any previously referenced payload.
@MainActor protocol CoreAttachmentInputStorage: AnyObject {
    func persist(_ input: JSONValue, scope: String) throws -> String
    func restore(_ reference: String, scope: String) throws -> JSONValue
    func remove(_ reference: String, scope: String) throws
}

enum CoreAttachmentInputEncoding {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode(_ input: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(input)
    }
}

/// The default for CoreMemoryStorage: existing in-process fixtures never touch the user's presentation directory.
@MainActor final class CoreMemoryAttachmentInputs: CoreAttachmentInputStorage {
    private(set) var values: [String: Data] = [:]
    private(set) var writes = 0
    var writeError: Error?
    func persist(_ input: JSONValue, scope: String) throws -> String {
        if let writeError { throw writeError }
        let data = try CoreAttachmentInputEncoding.encode(input)
        let reference = "memory://" + CoreAttachmentInputEncoding.digest(Data(scope.utf8)) + "/" + CoreAttachmentInputEncoding.digest(data) + ".json"
        if values[reference] == nil { values[reference] = data; writes += 1 }
        return reference
    }
    func restore(_ reference: String, scope: String) throws -> JSONValue {
        guard reference.hasPrefix("memory://" + CoreAttachmentInputEncoding.digest(Data(scope.utf8)) + "/"), let data = values[reference] else {
            throw CoreWire.failure("The saved attachment input is missing or belongs to another endpoint.")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func remove(_ reference: String, scope: String) throws {
        guard reference.hasPrefix("memory://" + CoreAttachmentInputEncoding.digest(Data(scope.utf8)) + "/") else {
            throw CoreWire.failure("The attachment input does not belong to this endpoint.")
        }
        values[reference] = nil
    }
}

/// Production defaults to the shell's own Presentation directory. Tests inject an exclusively temporary root.
/// Content-addressed names allow a draft, queued message and outbound UUID to share a payload without ID collisions.
@MainActor final class CoreFileAttachmentInputs: CoreAttachmentInputStorage {
    let root: URL
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Organic Shell v2/Presentation", directoryHint: .isDirectory)
    }
    init(root: URL = CoreFileAttachmentInputs.defaultRoot) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }
    func directory(scope: String) -> URL {
        root.appendingPathComponent(CoreAttachmentInputEncoding.digest(Data(scope.utf8)), isDirectory: true).appendingPathComponent("Attachments", isDirectory: true)
    }
    private func checkDirectory(_ url: URL) throws {
        // Paths, not URLs: for a directory not made yet, resolving drops the trailing slash, and the URLs differ though
        // nothing is a link (every first send under ~/Library/Application Support failed this way, 10-29 Live check).
        guard url.isFileURL, url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw CoreWire.failure("The attachment directory cannot be a symbolic link.")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw CoreWire.failure("The attachment directory is not a private directory.") }
        }
    }
    private func prepare(scope: String) throws -> URL {
        let directory = directory(scope: scope)
        for url in [root, directory.deletingLastPathComponent(), directory] {
            try checkDirectory(url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return directory
    }
    private func ownedURL(_ reference: String, scope: String) throws -> URL {
        let url = URL(fileURLWithPath: reference).standardizedFileURL
        let directory = directory(scope: scope)
        let name = url.deletingPathExtension().lastPathComponent
        guard reference.hasPrefix("/"), url.deletingLastPathComponent() == directory, url.pathExtension == "json",
              name.count == 64, name.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CoreWire.failure("The attachment input does not belong to this endpoint.")
        }
        for dir in [root, directory.deletingLastPathComponent(), directory] { try checkDirectory(dir) }
        guard url.resolvingSymlinksInPath().path == url.path else { throw CoreWire.failure("The attachment input cannot be a symbolic link.") }
        return url
    }
    func persist(_ input: JSONValue, scope: String) throws -> String {
        let data = try CoreAttachmentInputEncoding.encode(input), directory = try prepare(scope: scope)
        let url = directory.appendingPathComponent(CoreAttachmentInputEncoding.digest(data) + ".json")
        _ = try ownedURL(url.path, scope: scope)
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if existing != data {
            try data.write(to: url, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }
    func restore(_ reference: String, scope: String) throws -> JSONValue {
        let url = try ownedURL(reference, scope: scope)
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw CoreWire.failure("The saved attachment input is not a regular file.") }
        let data = try Data(contentsOf: url)
        guard CoreAttachmentInputEncoding.digest(data) == url.deletingPathExtension().lastPathComponent else {
            throw CoreWire.failure("The saved attachment input is damaged.")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func remove(_ reference: String, scope: String) throws {
        let url = try ownedURL(reference, scope: scope)
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw CoreWire.failure("Only owned attachment input files can be removed.") }
            try FileManager.default.removeItem(at: url)
        }
    }
}
