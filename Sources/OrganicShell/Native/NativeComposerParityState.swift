/// Opt-in capture recipes. Timing is supplied by OrganicWindow; these values never start an app or a window.
enum NativeComposerParityState: String, CaseIterable {
    case splitLeft = "split-left", splitRight = "split-right", split3
    case split3Left = "split3-left", split3Middle = "split3-middle"
    case removeMiddle = "split-remove-middle", removeFirst = "split-remove-first"
    case identityLanded = "split-identity-landed", roundtrip = "split-roundtrip"

    enum Step: Equatable {
        case focused, graftNext, select(Int), remove(Int), dragIdentity(Int), normie, organic
    }
    var steps: [Step] {
        let two: [Step] = [.focused, .graftNext]
        let three = two + [.graftNext]
        switch self {
        case .splitLeft: return two + [.select(0)]
        case .splitRight: return two + [.select(1)]
        case .split3: return three
        case .split3Left: return three + [.select(0)]
        case .split3Middle: return three + [.select(1)]
        case .removeMiddle: return three + [.remove(1)]
        case .removeFirst: return three + [.remove(0)]
        case .identityLanded: return two + [.dragIdentity(1)]
        case .roundtrip: return two + [.normie, .organic]
        }
    }
}
