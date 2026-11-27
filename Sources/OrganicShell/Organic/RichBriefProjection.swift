import AppKit

@MainActor enum RichBriefProjection {
    private static let environmentEnabled = ProcessInfo.processInfo.environment["ORGANIC_RICH_BRIEF"] == "1"
    static var enabledOverride: Bool?
    static var enabled: Bool { enabledOverride ?? environmentEnabled }
    static let theme = NativeFileCover.Theme(revision: NativeAppearance.revision,
        plate: .init(red: 44, green: 58, blue: 70), ink: .init(red: 238, green: 242, blue: 245))

    static func make(conversation: Conversation, log: SummaryLog, index: TranscriptContentIndex,
                     width: CGFloat, scale: CGFloat, assets: RichCoverAssets)
        -> (projection: BriefLayout.RichProjection, wanted: [NativeFileCover.Recipe], used: [RichCoverAssets.Asset]) {
        var projection: BriefLayout.RichProjection = [:]
        var wanted: [NativeFileCover.Recipe] = []
        var used: [RichCoverAssets.Asset] = []
        guard let oldest = log.stretches.first else { return (projection, wanted, used) }
        func opener(_ stretch: SummaryLog.Stretch) -> String {
            stretch.id.hasPrefix("after:") ? String(stretch.id.dropFirst(6)) : stretch.id
        }
        let ids = Set(log.stretches.flatMap { [opener($0), $0.answerID].compactMap { $0 } })
        var positions: [String: Int] = [:]
        let items = conversation.items
        for position in items.indices.reversed() {
            let id = items[position].id
            if ids.contains(id) { positions[id] = position }
            if id == opener(oldest) { break }
        }
        let currentSize = CGSize(width: width, height: (width * 150 / 260).rounded())
        let oldSize = CGSize(width: currentSize.width * 0.135, height: currentSize.height * 0.135)
        for stretch in log.stretches {
            guard let start = positions[opener(stretch)] else { continue }
            let end = stretch.answerID.flatMap { positions[$0] } ?? (items.count - 1)
            let first = start == end ? start : start + 1
            guard first <= end else { continue }
            var blocks: [BriefLayout.RichBlock] = []
            for item in items[first...end] where item.rowKind == .assistant {
                let quotes = Dictionary(uniqueKeysWithValues: index.stepQuotes(for: item).map { ($0.0, $0.2) })
                for ref in index.references(for: item) {
                    guard case .file = ref.target else { continue }
                    let id = "\(item.id):file:\(ref.range.location)"
                    let name = (ref.target.fileLocation.path as NSString).lastPathComponent
                    guard let current = try? NativeFileCover.Recipe(
                        resourceID: id, sourceRevision: "\(item.revision)", target: ref.target, fileName: name,
                        size: currentSize, scale: scale, theme: theme),
                          let old = try? NativeFileCover.Recipe(
                            resourceID: id, sourceRevision: "\(item.revision)", target: ref.target, fileName: name,
                            size: oldSize, scale: scale, theme: theme) else { continue }
                    func variant(_ recipe: NativeFileCover.Recipe, size: CGSize) -> BriefLayout.Cover.Variant {
                        let asset = assets.cached(for: recipe.key)
                        if let asset { used.append(asset) } else { wanted.append(recipe) }
                        return .init(size: size, image: asset?.image)
                    }
                    let cover = BriefLayout.Cover(id: "\(id):\(item.revision)",
                        current: variant(current, size: currentSize), old: variant(old, size: oldSize))
                    let source = BriefLayout.BlockSource(blockID: id, itemID: item.id,
                                                         revision: item.revision, range: ref.range)
                    blocks.append(.init(source: source, cover: cover,
                                        stepQuote: quotes[id] ?? .missing(.association), lyric: nil))
                }
            }
            if !blocks.isEmpty {
                let last = blocks.removeLast()
                blocks.append(.init(source: last.source, cover: last.cover,
                                    stepQuote: last.stepQuote, lyric: stretch.narration))
                projection[stretch.id] = blocks
            }
        }
        return (projection, wanted, used)
    }
}
