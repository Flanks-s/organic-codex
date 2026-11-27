import AppKit

/// Same B probe and C reducer events; D's action owner and natural card layout are included.
@MainActor final class FunctionPanelDCostHost: FunctionPanelActionHost {
    let data: FunctionPanelDRecordedData
    override var allowsPhaseAnimation: Bool { true }
    init(resources: BodyResources, scale: Int, reduced: Bool = true) {
        let data = FunctionPanelDRecordedData(); self.data = data
        super.init(conversation: data.data.conversation, store: data.data.store, resources: resources, scale: scale,
                   commands: data.owner, read: { _ in data.data.sources })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setPhase(_ input: FunctionPanelPhaseInput) {
        if data.data.conversation.phaseFacts.turnID != input.turnID { data.data.emit("turn/started",
                ["turn": ["id": .string(input.turnID)]]) }
        let count = 100, completed = Int((Double(input.event.value.fraction ?? 0) * 100).rounded())
        data.data.plan(completed, count, turn: input.turnID); refresh()
    }
}
