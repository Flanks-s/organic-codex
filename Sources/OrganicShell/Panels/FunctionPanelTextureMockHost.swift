import AppKit
import QuartzCore

/// This standalone, uninstalled host reserves native chrome above the board's coordinate space.
@MainActor final class FunctionPanelTextureMockHost: FunctionPanelPlane {
    let stage: FunctionPanelView
    let owner: FunctionPanelBodyOwner
    let scale: Int
    let chrome = FunctionPanelTrackLayout.headerHeight
    private(set) var phaseInput: FunctionPanelPhaseInput
    private var synchronizing = false
    let openedAt = CACurrentMediaTime()
    private(set) var firstStageFrame: Double?
    init(resources: BodyResources, scale: Int, quality: FunctionPanelPictureQuality = .panelHD, reduced: Bool = true) {
        self.scale = scale
        phaseInput = Self.phase(scale: scale, quality: quality)
        owner = FunctionPanelBodyOwner(resources: resources)
        stage = FunctionPanelView(input: FunctionPanelFixtures.input(), reduced: reduced, automatic: false)
        super.init(frame: CGRect(x: 0, y: 0, width: 1280, height: 852))
        appearance = NSAppearance(named: .darkAqua)
        stage.wantsLayer = true; stage.layer?.masksToBounds = true
        stage.frame.origin.y = chrome; addSubview(stage)
        owner.receive = { [weak self] in self?.stage.updateBodySnapshot($0) }
        stage.onPresentation = { [weak self] _ in self?.synchronize() }
        stage.onAction = { [weak self] action in
            guard let self else { return }
            if case .body(let id) = action {
                let old = self.phaseInput
                self.phaseInput = .init(bodyID: id, event: old.event, turnID: old.turnID, scale: old.scale,
                    bin: old.bin, quality: old.quality, animate: old.animate)
                self.synchronize()
            }
        }
        select(.overview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    static func phase(scale: Int, quality: FunctionPanelPictureQuality = .panelHD, serial: UInt64 = 1,
                      state: BodyPhaseState = .running, turn: String = "turn-7",
                          body: String = "mercury") -> FunctionPanelPhaseInput {
        .init(bodyID: body, event: .init(sourceID: "m1140/mock/thread", value: .init(state, fraction: 0.37),
                serial: serial, animate: false),
              turnID: turn, scale: scale, bin: 12, quality: quality)
    }
    func select(_ scenario: FunctionPanelScenario) {
        stage.open(page: scenario.page, at: 0)
        stage.interact {
            $0.option = scenario == .customize ? 0 : nil
            $0.pinnedSubagent = scenario == .hover ? "agent-0" : nil
        }
        synchronize(); needsDisplay = true
    }
    func setPhase(_ input: FunctionPanelPhaseInput) { phaseInput = input; synchronize() }
    private func synchronize() {
        guard !synchronizing else { return }; synchronizing = true
        defer { synchronizing = false }
        guard stage.state.isOpen else { owner.close(); return }
        let candidates = stage.state.option == 0 ? FunctionPanelGeometry.bodySlots(count: stage.input.bodies.count,
            offset: stage.state.bodyScroll).map { stage.input.bodies[$0.index].id } : []
        owner.present(phaseInput, candidates: candidates, currentEntry: stage.state.option != 0)
    }
    func close() { stage.onPresentation = nil; stage.retire(); owner.close() }
    override func draw(_ dirtyRect: NSRect) {
        if firstStageFrame == nil { firstStageFrame = CACurrentMediaTime() - openedAt }
        NSColor(srgbRed: 0.105, green: 0.11, blue: 0.105, alpha: 1).setFill(); bounds.fill()
        for (index, colour) in [UInt32(0xe15a55), 0xe4b34b, 0x62bc5b].enumerated() {
            FunctionPanelPaint.colour(colour).setFill()
            NSBezierPath(ovalIn: CGRect(x: 16 + CGFloat(index) * 19, y: 18, width: 11, height: 11)).fill()
        }
        for x: CGFloat in [598, 915] {
            NSColor.white.withAlphaComponent(0.1).setFill(); CGRect(x: x, y: 84 + chrome, width: 1, height: 652).fill()
        }
        for (x, title) in [(CGFloat(665), "Approval copy review"), (991, "Release notes outline")] {
            FunctionPanelPaint.plate(CGRect(x: x + 70, y: 56 + chrome, width: 44, height: 44), radius: 22,
                fill: NSColor(white: 0.35, alpha: 1))
            FunctionPanelPaint.plate(CGRect(x: x, y: 97 + chrome, width: 185, height: 27), radius: 13.5,
                fill: NSColor(white: 0.23, alpha: 1))
            FunctionPanelPaint.text(title, CGRect(x: x + 12, y: 104 + chrome, width: 166, height: 17), size: 11)
        }
        for (x, width) in [(CGFloat(78), CGFloat(515)), (605, 305), (922, 160)] {
            FunctionPanelPaint.plate(CGRect(x: x, y: 740 + chrome, width: width, height: 48), radius: 24,
                fill: NSColor(white: 0.23, alpha: 1))
            FunctionPanelPaint.text("Steer or queue…", CGRect(x: x + 20, y: 755 + chrome, width: width - 40,
                    height: 18), size: 13, alpha: 0.4)
        }
    }
}
