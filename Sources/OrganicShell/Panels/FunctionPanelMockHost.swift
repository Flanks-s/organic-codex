import AppKit
import QuartzCore
import CoreImage

/// Optional canvas host for checks/review only. Nothing in App or AutoScene constructs it.
@MainActor final class FunctionPanelMockHost: FunctionPanelPlane {
    let stage: FunctionPanelView
    private(set) var scenario: FunctionPanelScenario = .overview
    private(set) var dataState: FunctionPanelFixtureState = .known
    private(set) var agentCount = 3
    private(set) var collectionMode: FunctionPanelCollectionMode = .normal
    private(set) var actions: [FunctionPanelAction] = []
    private(set) var sampleTime = 0.0
    private var scenarioButtons: [FunctionPanelButton] = []
    private var backgroundSharp: CGImage?
    private var backgroundSoft: CGImage?
    private var backgroundScale: CGFloat = 0
    var hasSoftBackground: Bool { backgroundSoft != nil }
    let column: CGRect

    init(size: CGSize = CGSize(width: 1280, height: 884), column: CGRect = CGRect(x: 0, y: 0, width: 598, height: 736),
         reduced: Bool = false, automatic: Bool = false) {
        self.column = column
        stage = FunctionPanelView(input: FunctionPanelFixtures.input(), viewport: CGRect(x: 0, y: 0, width: size.width,
                height: min(820, size.height)),
                                  column: column, reduced: reduced, automatic: automatic)
        super.init(frame: CGRect(origin: .zero, size: size))
        appearance = NSAppearance(named: .darkAqua)
        addSubview(stage)
        stage.onAction = { [weak self] in self?.actions.append($0) }
        stage.onPresentation = { [weak self] _ in self?.needsDisplay = true }
        installControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func select(_ scenario: FunctionPanelScenario, at time: Double = 0) {
        self.scenario = scenario; sampleTime = time
        stage.update(fixtureInput())
        stage.open(page: scenario.page, at: time)
        stage.interact {
            $0.option = scenario == .customize ? 0 : nil
            $0.pinnedSubagent = scenario == .hover ? "agent-0" : nil
        }
        needsDisplay = true
    }
    func setDataState(_ value: FunctionPanelFixtureState) {
        dataState = value; stage.update(fixtureInput())
    }
    func setAgentCount(_ count: Int) {
        agentCount = count; stage.update(fixtureInput())
    }
    func setCollectionMode(_ mode: FunctionPanelCollectionMode) { collectionMode = mode; stage.update(fixtureInput()) }
    private func fixtureInput() -> FunctionPanelInput {
        FunctionPanelFixtures.input(state: dataState, subagentCount: agentCount, empty: collectionMode == .empty,
            many: collectionMode == .many)
    }
    func sample(at time: Double) {
        let start = max(sampleTime, stage.motion.last)
        guard time >= start else { return }
        var cursor = start + 1 / 60
        while cursor < time { stage.advance(to: cursor); cursor += 1 / 60 }
        sampleTime = time; stage.advance(to: time); needsDisplay = true
    }
    private func installControls() {
        guard bounds.height >= 884 else { return }
        func control(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, action: @escaping () -> Void) {
            let b = FunctionPanelButton(frame: CGRect(x: x, y: y, width: width, height: 23))
            b.label = title; b.invoke = action; addSubview(b); scenarioButtons.append(b)
        }
        for (index, scenario) in FunctionPanelScenario.allCases.enumerated() {
            control(scenario.rawValue, x: 16 + CGFloat(index) * 106, y: 830,
                width: 98) { [weak self] in self?.select(scenario, at: CACurrentMediaTime()) }
        }
        control("Replay", x: 16, y: 859, width: 78) {
            [weak self] in guard let self else { return }
            self.stage.retire()
            self.select(self.scenario, at: CACurrentMediaTime())
        }
        for (index, count) in [0, 1, 3, 7].enumerated() {
            control("Agents \(count)", x: 110 + CGFloat(index) * 78, y: 859,
                width: 72) { [weak self] in self?.setAgentCount(count) }
        }
        for (index, value) in FunctionPanelFixtureState.allCases.enumerated() {
            control(value.rawValue, x: 442 + CGFloat(index) * 108, y: 859,
                width: 102) { [weak self] in self?.setDataState(value) }
        }
        for (index, mode) in FunctionPanelCollectionMode.allCases.enumerated() {
            control(mode.rawValue, x: 994 + CGFloat(index) * 91, y: 859,
                width: 85) { [weak self] in self?.setCollectionMode(mode) }
        }
    }
    private func prepareBackground(scale: CGFloat) {
        guard backgroundSharp == nil || backgroundScale != scale else { return }
        let board = FunctionPanelInk(frame: CGRect(x: 0, y: 0, width: column.width, height: 736))
        let width = column.width, goal = stage.input.goal
        board.commands.append {
            FunctionPanelPaint.text(goal, CGRect(x: 178, y: 160, width: min(387, width - 190), height: 76), size: 16,
                weight: .medium)
        }
        for (index, line) in ["Thought for 14s ›", "Edited SidebarView.swift +1 −1 ›",
            "Found one custom inset and removed it.", "Checking the narrow window next.",
            "Row height is 28 pt now, down from 32.", "Re-recording the snapshots at 1x and 2x."].enumerated() {
            board.commands.append {
                FunctionPanelPaint.text(line, CGRect(x: 58, y: 270 + CGFloat(index) * 61, width: min(507, width - 72),
                        height: 40), size: index % 2 == 0 ? 13 : 16)
            }
        }
        let sharp = NativeViewBitmap.capture(board, scale: scale), image = CIImage(cgImage: sharp)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(18 * scale, forKey: kCIInputRadiusKey)
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        backgroundSharp = sharp; backgroundScale = scale
        backgroundSoft = filter?.outputImage.flatMap { context.createCGImage($0.cropped(to: image.extent),
                from: image.extent) }
    }
    private func drawBackground() {
        let scale = min(2, max(1, abs(NSGraphicsContext.current?.cgContext.ctm.a ?? 1)))
        prepareBackground(scale: scale)
        let p = CGFloat(stage.motion.progress), s = 1 - 0.015 * p
        let rect = CGRect(x: column.minX + 311 * (1 - s), y: 410 * (1 - s), width: column.width * s, height: 736 * s)
        if let backgroundSharp, p < 1 {
            NSImage(cgImage: backgroundSharp, size: CGSize(width: column.width, height: 736)).draw(in: rect,
                from: .zero, operation: .sourceOver, fraction: 1 - p, respectFlipped: true, hints: nil)
        }
        if let image = backgroundSoft ?? backgroundSharp, p > 0 {
            NSImage(cgImage: image, size: CGSize(width: column.width, height: 736)).draw(in: rect, from: .zero,
                operation: .sourceOver, fraction: 0.4 * p, respectFlipped: true, hints: nil)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.105, green: 0.11, blue: 0.105, alpha: 1).setFill(); bounds.fill()
        drawBackground()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let split = column.minX > 0
        let narrow = !split && column.width != 598
        let remaining = (bounds.width - column.maxX) / 2
        let separators: [CGFloat] = split ? [bounds.width / 2] : narrow ? [column.maxX, column.maxX + remaining] : [598,
            915]
        for x in separators where x < bounds.width {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x, y: 84))
            path.line(to: CGPoint(x: x, y: 736))
            path.stroke()
        }
        for (index, colour) in [UInt32(0xe15a55), 0xe4b34b, 0x62bc5b].enumerated() {
            FunctionPanelPaint.colour(colour).setFill()
            NSBezierPath(ovalIn: CGRect(x: 16 + CGFloat(index) * 19, y: 18, width: 11, height: 11)).fill()
        }
        if !stage.state.isOpen && stage.motion.progress == 0 {
            let orb = stage.geometry.placed(FunctionPanelGeometry.orb(0))
            let title = stage.geometry.placed(FunctionPanelGeometry.title(width: 188, progress: 0))
            FunctionPanelPaint.plate(orb, radius: 28, fill: NSColor(white: 0.35, alpha: 1))
            FunctionPanelPaint.plate(title, radius: 16, fill: NSColor(white: 0.23, alpha: 1))
            FunctionPanelPaint.text(stage.state.title, title.insetBy(dx: 18, dy: 9), size: 12)
        }
        let neighbours: [(CGFloat, String)] = split ? [(226, "Approval copy review")] : narrow
            ? [(column.maxX + remaining / 2 - 92.5, "Approval copy review"), (column.maxX + remaining * 1.5 - 92.5,
                    "Release notes outline")]
            : [(665, "Approval copy review"), (991, "Release notes outline")]
        for (x, title) in neighbours where x + 185 < bounds.width {
            let borrowed = narrow && CGRect(x: x, y: 56, width: 185,
                height: 68).intersects(stage.geometry.placed(CGRect(x: 0, y: 0, width: 598, height: 264)))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(borrowed ? 1 - stage.motion.progress : 1)
            FunctionPanelPaint.plate(CGRect(x: x + 70, y: 56, width: 44, height: 44), radius: 22,
                fill: NSColor(white: 0.35, alpha: 1))
            FunctionPanelPaint.plate(CGRect(x: x, y: 97, width: 185, height: 27), radius: 13.5,
                fill: NSColor(white: 0.23, alpha: 1))
            FunctionPanelPaint.text(title, CGRect(x: x + 12, y: 104, width: 166, height: 17), size: 11)
            NSGraphicsContext.restoreGraphicsState()
        }
        FunctionPanelPaint.plate(CGRect(x: 30, y: 746, width: 36, height: 36), radius: 18, fill: NSColor(white: 0.4,
                alpha: 1))
        FunctionPanelPaint.text("LL", CGRect(x: 30, y: 757, width: 36, height: 18), size: 11, align: .center)
        for x: CGFloat in [1106, 1162, 1218] where x + 32 <= bounds.width {
            FunctionPanelPaint.plate(CGRect(x: x, y: 748, width: 32, height: 32), radius: 16, fill: NSColor(white: 0.35,
                    alpha: 1))
        }
        let replies: [(CGRect, String)] = narrow
            ? [(CGRect(x: 78, y: 740, width: column.width - 83, height: 48), "Steer or queue…"),
               (CGRect(x: column.maxX + 7, y: 740, width: remaining - 12, height: 48), "Reply…"),
               (CGRect(x: column.maxX + remaining + 7, y: 740, width: remaining - 12, height: 48), "Reply…")]
            : [(CGRect(x: 78, y: 740, width: 515, height: 48), "Steer or queue…"), (CGRect(x: 605, y: 740, width: 305,
                        height: 48), "Reply…"), (CGRect(x: 922, y: 740, width: 160, height: 48), "Reply…")]
        for (baseRect, label) in replies where baseRect.maxX < bounds.width {
            var rect = baseRect
            if rect.minX == 922 { rect.size.width -= 56 * CGFloat(stage.pinMotion.value) }
            FunctionPanelPaint.plate(rect, radius: 24, fill: NSColor(white: 0.23, alpha: 1))
            FunctionPanelPaint.text(label, rect.insetBy(dx: 20, dy: 15), size: 13, alpha: 0.4)
        }
        if bounds.height >= 884 {
            NSColor(white: 0.08, alpha: 1).setFill()
            CGRect(x: 0, y: 820, width: bounds.width, height: 64).fill()
        }
    }
}
