import Foundation

/// Values only. Authority is supplied by the external action owner at submission time.
struct FunctionPanelCommandPresentation: Equatable, Sendable {
    var available: Set<String> = []
    var feedback: String? = nil
    var bodyDraft: String? = nil
    var colours: [FunctionPanelColour] = []
    var colourID: String? = nil
}

struct FunctionPanelOverviewLayout {
    let history: CGRect?
    let actions: CGRect?
    let height: CGFloat
    init(historyKnown: Bool, hasActions: Bool) {
        history = historyKnown ? CGRect(x: 16, y: 149, width: 350, height: 34) : nil
        let next: CGFloat = historyKnown ? 193 : 149
        actions = hasActions ? CGRect(x: 16, y: next, width: 459, height: 28) : nil
        height = (actions?.maxY ?? history?.maxY ?? 139) + 16
    }
}
