import CoreGraphics
import Foundation

/// A shared preparation cache. The caller owns visibility and cancels tickets when its source changes.
@MainActor final class RichCoverAssets {
    typealias Key = NativeFileCover.Key
    typealias Failure = NativeFileCover.Failure
    typealias Renderer = @MainActor (NativeFileCover.Recipe) async -> Result<NativeFileCover.Raster, Failure>

    struct Asset {
        let key: Key
        fileprivate let raster: NativeFileCover.Raster
        var image: CGImage { raster.image }
        var tint: NativeFileCover.RGB { raster.tint }
        var bytes: Int { raster.bytes }
    }

    struct Ticket {
        fileprivate let key: Key
        fileprivate let id: UUID
    }

    struct Pin {
        fileprivate let id: UUID
    }

    private struct Preparation {
        let generation: UUID
        let task: Task<Void, Never>
        var tickets: Set<UUID>
    }

    private struct Entry {
        let asset: Asset
        var lastUse: UInt64
    }

    private struct RetainedImage {
        var entries = 0
        var pins = 0
    }

    private let byteLimit: Int
    private let render: Renderer
    private var preparations: [Key: Preparation] = [:]
    private var publications: [UUID: (Result<Asset, Failure>) -> Void] = [:]
    private var entries: [Key: Entry] = [:]
    private var pins: [UUID: Asset] = [:]
    private var retained: [ObjectIdentifier: RetainedImage] = [:]
    private var use: UInt64 = 0
    private(set) var residentBytes = 0

    init(byteLimit: Int = 32 * 1024 * 1024, render: @escaping Renderer = { NativeFileCover.render($0) }) {
        self.byteLimit = max(0, byteLimit)
        self.render = render
    }

    isolated deinit {
        for preparation in preparations.values {
            preparation.task.cancel()
        }
    }

    /// The warm path. A hit also updates the eviction order.
    func cached(for key: Key) -> Asset? {
        guard let asset = entries[key]?.asset else { return nil }
        entries[key]?.lastUse = nextUse()
        return asset
    }

    /// Publication always happens after this call returns. The first recipe for a given key supplies the pixels.
    @discardableResult func request(_ recipe: NativeFileCover.Recipe,
                                   publish: @escaping (Result<Asset, Failure>) -> Void) -> Ticket {
        let key = recipe.key
        let ticket = Ticket(key: key, id: UUID())
        publications[ticket.id] = publish
        if preparations[key] != nil {
            preparations[key]?.tickets.insert(ticket.id)
            return ticket
        }
        let generation = UUID()
        let task = Task { [weak self, render] in
            guard !Task.isCancelled else { return }
            if let asset = self?.cached(for: key) {
                self?.finish(.success(asset), for: key, generation: generation)
                return
            }
            let raster = await render(recipe)
            self?.finish(raster.map { Asset(key: key, raster: $0) }, for: key, generation: generation)
        }
        preparations[key] = Preparation(generation: generation, task: task, tickets: [ticket.id])
        return ticket
    }

    /// Retire this consumer. Other consumers of the same key still get their result.
    func cancel(_ ticket: Ticket) {
        publications[ticket.id] = nil
        guard preparations[ticket.key]?.tickets.remove(ticket.id) != nil,
              preparations[ticket.key]?.tickets.isEmpty == true else { return }
        preparations.removeValue(forKey: ticket.key)?.task.cancel()
    }

    /// Hold the exact bitmap delivered to the caller, even if the LRU had already dropped it.
    /// Active pins may exceed the cache budget. They release only on explicit handoff or cancellation.
    func pin(_ asset: Asset) -> Pin {
        let pin = Pin(id: UUID())
        pins[pin.id] = asset
        retain(asset, pinned: true)
        insertIfAbsent(asset)
        trim()
        return pin
    }

    func release(_ pin: Pin) {
        guard let asset = pins.removeValue(forKey: pin.id) else { return }
        drop(asset, pinned: true)
        trim()
    }

    private func finish(_ result: Result<Asset, Failure>, for key: Key, generation: UUID) {
        guard let preparation = preparations[key], preparation.generation == generation else { return }
        preparations[key] = nil
        let published = result.map { asset in
            if let current = cached(for: key) { return current }
            if asset.bytes <= byteLimit {
                insertIfAbsent(asset)
                trim()
            }
            return asset
        }
        // Callbacks may cancel other tickets or start a new request for the same key.
        for id in preparation.tickets {
            publications.removeValue(forKey: id)?(published)
        }
    }

    private func nextUse() -> UInt64 {
        use += 1
        return use
    }

    private func insertIfAbsent(_ asset: Asset) {
        guard entries[asset.key] == nil else { return }
        entries[asset.key] = Entry(asset: asset, lastUse: nextUse())
        retain(asset, pinned: false)
    }

    private func retain(_ asset: Asset, pinned: Bool) {
        let id = ObjectIdentifier(asset.image)
        if retained[id] == nil {
            retained[id] = RetainedImage()
            residentBytes += asset.bytes
        }
        if pinned {
            retained[id]?.pins += 1
        } else {
            retained[id]?.entries += 1
        }
    }

    private func drop(_ asset: Asset, pinned: Bool) {
        let id = ObjectIdentifier(asset.image)
        guard var image = retained[id] else { return }
        if pinned {
            image.pins -= 1
        } else {
            image.entries -= 1
        }
        if image.pins == 0 && image.entries == 0 {
            retained[id] = nil
            residentBytes -= asset.bytes
        } else {
            retained[id] = image
        }
    }

    private func trim() {
        guard residentBytes > byteLimit else { return }
        let reclaimable = entries.values.filter { retained[ObjectIdentifier($0.asset.image)]?.pins == 0 }
        for entry in reclaimable.sorted(by: { $0.lastUse < $1.lastUse }) {
            entries[entry.asset.key] = nil
            drop(entry.asset, pinned: false)
            if residentBytes <= byteLimit { break }
        }
    }
}
