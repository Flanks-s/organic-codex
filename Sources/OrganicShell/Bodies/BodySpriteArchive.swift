import Foundation

/// Both layouts store independently compressed PNG frames. No reader decodes a direction atlas.
struct BodySpriteIndex: Codable, Sendable {
    static let currentVersion = "org.organic.bodies.sprite-index.v1"
    enum Layout: String, Codable, Sendable { case files = "direction-files", packed = "direction-pack" }
    struct Group: Codable, Sendable {
        let descriptor: BodySpriteDescriptor
        let file: String?
        let offsets: [UInt64]
        let lengths: [Int]
    }
    let version: String
    let layout: Layout
    let groups: [String: Group]
}

/// A bounded read of exactly one compressed direction; decoded ownership stays in BodySpriteCache.
@MainActor final class BodySpriteArchive {
    let root: URL
    let index: BodySpriteIndex
    private(set) var framesRead = 0
    private(set) var encodedBytesRead = 0
    init(root: URL) throws {
        self.root = root
        let url = root.appendingPathComponent("index.json")
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4*1024*1024 else {
            throw BodyError.invalid("Sprite index exceeds its encoded budget")
        }
        index = try JSONDecoder().decode(BodySpriteIndex.self, from: Data(contentsOf: url))
        guard index.version == BodySpriteIndex.currentVersion else { throw BodyError.invalid("Unsupported sprite index") }
    }
    func descriptor(group: String, bin: Int) -> BodySpriteDescriptor? {
        guard let group = index.groups[group], (0..<32).contains(bin), group.lengths.count == 32,
              group.offsets.count == 32, BodySprite.valid(group.descriptor, budget: BodyProfile.current.atlasBudget) else { return nil }
        var descriptor = group.descriptor
        descriptor.lightBin = bin
        return descriptor
    }
    func read(group key: String, frameKey: String, bin: Int) throws -> Data {
        guard let group = index.groups[key], (0..<32).contains(bin), group.lengths.count == 32,
              group.offsets.count == 32 else { throw BodyError.invalid("Missing sprite direction") }
        let filename: String
        switch index.layout {
        case .files: filename = frameKey + ".png"
        case .packed:
            guard group.file == key + ".bodyframes" else { throw BodyError.invalid("Invalid sprite group file") }
            filename = group.file!
        }
        guard filename == (filename as NSString).lastPathComponent else { throw BodyError.invalid("Invalid sprite path") }
        let length = group.lengths[bin], offset = group.offsets[bin]
        guard length > 0, length <= 1024*1024 else { throw BodyError.invalid("Sprite frame exceeds its encoded budget") }
        let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(filename))
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard offset <= end, UInt64(length) <= end-offset else { throw BodyError.invalid("Truncated sprite frame") }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: length), data.count == length else { throw BodyError.invalid("Cannot read sprite direction") }
        framesRead += 1; encodedBytesRead += data.count
        return data
    }
}
