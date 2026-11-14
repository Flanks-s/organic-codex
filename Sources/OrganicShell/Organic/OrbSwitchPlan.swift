import Foundation

/// A complete layout transaction. A Dock source trades its exact slot with the destination.
struct OrbSwitchPlan {
    var members: [String]
    var current: String
    var scheme: AutoScene.Scheme

    @MainActor static func make(source: String, target: String, members: [String], current: String,
                                scheme: AutoScene.Scheme, columns: [String], explicitColumn: Bool) -> Self? {
        guard source != target, let a = members.firstIndex(of: source), let b = members.firstIndex(of: target) else { return nil }
        var result = Self(members: members, current: current, scheme: scheme)
        if columns.contains(source), !explicitColumn {
            result.current = source
            return result
        }
        result.members.swapAt(a, b)
        func exchange(_ ids: [String]) -> [String] { ids.map { $0 == source ? target : ($0 == target ? source : $0) } }
        result.scheme.split = exchange(scheme.split)
        result.scheme.left = exchange(scheme.left)
        result.scheme.right = exchange(scheme.right)
        result.scheme.parked = exchange(scheme.parked)
        if current == target { result.current = source }
        else if current == source { result.current = target }
        return result
    }
}
