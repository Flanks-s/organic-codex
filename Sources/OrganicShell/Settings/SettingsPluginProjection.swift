// Independent port of the product catalog projection.
import Foundation

/// Searches the complete catalog as data and gives Form only one bounded page of rows.
enum SettingsPluginProjection {
    static let pageSize = 100

    enum MarketplaceSource: Hashable {
        case path(String), name(String), index(Int)
    }
    struct MarketplaceID: Hashable {
        let source: MarketplaceSource
        let occurrence: Int
    }
    struct PluginSource: Hashable {
        let canonicalID: String?
        let name: String?
        let path: String?
        let url: String?
        let package: String?
        let registry: String?
        let index: Int?
    }
    struct EntryID: Hashable {
        let marketplace: MarketplaceID
        let source: PluginSource
        let occurrence: Int
    }
    struct Entry: Identifiable {
        let id: EntryID
        let plugin: JSONValue
    }
    struct Section: Identifiable {
        let id: MarketplaceID
        let title: String
        let marketplace: JSONValue
        var entries: [Entry]
    }
    struct Page {
        let sections: [Section]
        let catalogCount: Int
        let matchCount: Int
        let index: Int
        let pageCount: Int

        var firstResult: Int { matchCount == 0 ? 0 : index * SettingsPluginProjection.pageSize + 1 }
        var lastResult: Int { min((index + 1) * SettingsPluginProjection.pageSize, matchCount) }
        var hasPrevious: Bool { index > 0 }
        var hasNext: Bool { index + 1 < pageCount }
    }

    static func sections(catalog: JSONValue, query: String) -> (sections:[Section],count:Int) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [Section] = []
        var catalogCount = 0
        var marketplaceOccurrences: [MarketplaceSource: Int] = [:]
        for (marketIndex, market) in (catalog["marketplaces"]?.arrayValue ?? []).enumerated() {
            let marketSource: MarketplaceSource
            // Backend paths are already normalized by its protocol. Do not resolve them
            // against the client's filesystem; the connected Core may be on another host.
            if let path = market["path"]?.stringValue { marketSource = .path(path) }
            else if let name = market["name"]?.stringValue { marketSource = .name(name) }
            else { marketSource = .index(marketIndex) }
            let marketOccurrence = marketplaceOccurrences[marketSource, default: 0]
            marketplaceOccurrences[marketSource] = marketOccurrence + 1
            let marketID = MarketplaceID(source: marketSource, occurrence: marketOccurrence)
            var entries: [Entry] = []
            var pluginOccurrences: [PluginSource: Int] = [:]
            for (pluginIndex, plugin) in (market["plugins"]?.arrayValue ?? []).enumerated() {
                catalogCount += 1
                let canonicalID = plugin["id"]?.stringValue
                let name = plugin["name"]?.stringValue
                let source = PluginSource(canonicalID: canonicalID, name: canonicalID == nil ? name : nil,
                                          path: plugin["source"]?["path"]?.stringValue,
                                          url: plugin["source"]?["url"]?.stringValue,
                                          package: plugin["source"]?["package"]?.stringValue,
                                          registry: plugin["source"]?["registry"]?.stringValue,
                                          index: canonicalID == nil && name == nil ? pluginIndex : nil)
                let occurrence = pluginOccurrences[source, default: 0]
                pluginOccurrences[source] = occurrence + 1
                let fields = [name, plugin["interface"]?["displayName"]?.stringValue,
                              plugin["interface"]?["shortDescription"]?.stringValue,
                              plugin["interface"]?["longDescription"]?.stringValue]
                guard query.isEmpty || fields.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) else { continue }
                entries.append(Entry(id: EntryID(marketplace: marketID, source: source, occurrence: occurrence), plugin: plugin))
            }
            if !entries.isEmpty {
                matches.append(Section(id: marketID,
                                       title: market["interface"]?["displayName"]?.stringValue ?? market["name"]?.stringValue ?? "Plugins",
                                       marketplace: market, entries: entries))
            }
        }
        return (matches,catalogCount)
    }
    static func page(catalog: JSONValue, query: String, requestedPage: Int) -> Page {
        let all=sections(catalog:catalog,query:query),matches=all.sections,catalogCount=all.count
        let matchCount = matches.reduce(0) { $0 + $1.entries.count }
        let pageCount = max(1, (matchCount + pageSize - 1) / pageSize)
        let index = min(max(0, requestedPage), pageCount - 1)
        let lower = index * pageSize, upper = min(lower + pageSize, matchCount)
        var preceding = 0
        var sections: [Section] = []
        for var section in matches {
            let count = section.entries.count
            let start = max(0, lower - preceding), end = min(count, upper - preceding)
            if start < end {
                section.entries = Array(section.entries[start..<end])
                sections.append(section)
            }
            preceding += count
        }
        return Page(sections: sections, catalogCount: catalogCount, matchCount: matchCount,
                    index: index, pageCount: pageCount)
    }
}
