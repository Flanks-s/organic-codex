import AppKit
import QuartzCore

/// Uninstalled read-only host. The eventual window owner must inject its existing resources.
@MainActor class FunctionPanelLiveHost: FunctionPanelPlane {
    let resources: BodyResources
    let projection: FunctionPanelProjection
    let conversation: Conversation
    let owner: FunctionPanelBodyOwner
    let stage: FunctionPanelView
    let scale: Int
    let read: (FunctionPanelPage) -> FunctionPanelReadSources
    private(set) var phaseInput: FunctionPanelPhaseInput?
    private(set) var snapshot: FunctionPanelProjectionSnapshot
    private var page: FunctionPanelPage = .overview
    private var synchronizing = false
    private(set) var actions: [FunctionPanelAction] = []
    private(set) var firstStageFrame: Double?
    let openedAt = CACurrentMediaTime()
    var allowsPhaseAnimation: Bool { !stage.reduced }

    init(conversation: Conversation, store: ConversationStore, resources: BodyResources, scale: Int,
         reduced: Bool = true, read: @escaping (FunctionPanelPage) -> FunctionPanelReadSources) {
        self.conversation = conversation; self.resources = resources; self.scale = scale; self.read = read
        let projection = FunctionPanelProjection(store: store)
        self.projection = projection; owner = FunctionPanelBodyOwner(resources: resources)
        let bodies = Self.bodies(resources)
        let snapshot = projection.project(conversation, page: .overview, sources: read(.overview), bodies: bodies)
        self.snapshot = snapshot
        stage = FunctionPanelView(input: snapshot.input, reduced: reduced, automatic: false)
        super.init(frame: CGRect(x: 0, y: 0, width: 1280, height: 852))
        appearance = NSAppearance(named: .darkAqua)
        stage.frame.origin.y = 32; addSubview(stage)
        owner.receive = { [weak self] in self?.stage.updateBodySnapshot($0) }
        stage.onPresentation = { [weak self] _ in self?.presentation() }
        stage.onAction = { [weak self] action in self?.actions.append(action) }
        stage.open(at: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func decorate(_ input: FunctionPanelInput) -> FunctionPanelInput { input }
    static func bodies(_ resources: BodyResources) -> [FunctionPanelBodyOption] {
        FunctionPanelSourceOwner.bodies(resources)
    }
    func refresh() {
        snapshot = projection.project(conversation, page: stage.state.page, sources: read(stage.state.page),
            bodies: Self.bodies(resources))
        synchronizing = true; stage.update(decorate(snapshot.input)); synchronizing = false
        synchronizeBody()
    }
    func select(_ scenario: FunctionPanelScenario) {
        stage.selectPage(scenario.page, at: 0)
        stage.interact {
            $0.option = scenario == .customize ? 0 : nil
            $0.pinnedSubagent = scenario == .hover ? snapshot.input.subagents.value?.first?.id : nil
        }
    }
    private func presentation() {
        guard !synchronizing else { return }; synchronizing = true
        defer { synchronizing = false }
        guard stage.state.isOpen else { owner.close(); return }
        if page != stage.state.page {
            page = stage.state.page
            snapshot = projection.project(conversation, page: page, sources: read(page), bodies: Self.bodies(resources))
            stage.update(decorate(snapshot.input))
        }
        synchronizeBody()
    }
    func synchronizeBody() {
        let previous = synchronizing; synchronizing = true
        defer { synchronizing = previous }
        guard stage.state.isOpen else { return }
        guard let phase = snapshot.phase.value, !snapshot.input.bodyID.isEmpty else {
            phaseInput = nil; owner.close()
            stage.updateBodySnapshot(.init(entries: [:], planet: nil, loading: snapshot.phase.status,
                                           phaseLoading: .unloaded))
            return
        }
        let input = FunctionPanelPhaseInput(bodyID: snapshot.input.bodyID, event: phase.event, turnID: phase.turnID,
                                            scale: scale, bin: 12, quality: .panelHD,
                                                animate: phase.event.animate && allowsPhaseAnimation)
        phaseInput = input
        let candidates = stage.state.option == 0 ? FunctionPanelGeometry.bodySlots(count: snapshot.input.bodies.count,
            offset: stage.state.bodyScroll).map { snapshot.input.bodies[$0.index].id } : []
        owner.present(input, candidates: candidates, currentEntry: stage.state.option != 0)
    }
    func close() { stage.onPresentation = nil; stage.retire(); owner.close() }
    override func draw(_ dirtyRect: NSRect) {
        if firstStageFrame == nil { firstStageFrame = CACurrentMediaTime() - openedAt }
        NSColor(srgbRed: 0.105, green: 0.11, blue: 0.105, alpha: 1).setFill(); bounds.fill()
        for (index, colour) in [UInt32(0xe15a55), 0xe4b34b, 0x62bc5b].enumerated() {
            FunctionPanelPaint.colour(colour).setFill()
            NSBezierPath(ovalIn: CGRect(x: 12 + index * 20, y: 9, width: 12, height: 12)).fill()
        }
    }
}
