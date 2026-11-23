import AppKit
import QuartzCore

/// One instance is installed per window, without a Scene entry or an implicit resource ledger.
@MainActor final class FunctionPanelWindowOwner {
    let host: FunctionPanelWindowHost
    let source: FunctionPanelSourceOwner
    let resources: BodyResources
    private(set) var body: FunctionPanelBodyOwner?
    private(set) var generation = 0
    private(set) var isOpen = false
    private(set) var snapshot: FunctionPanelProjectionSnapshot?
    private weak var window: NSWindow?
    private weak var target: Conversation?
    private var targetID: String?
    private weak var savedResponder: NSResponder?
    private let current: () -> Conversation?
    private let environment: () -> FunctionPanelWindowEnvironment
    private let columns: FunctionPanelColumnAccess
    private let actions: (FunctionPanelAction) -> Void
    private let intent: () -> Void
    private let clearFeedback: () -> Void
    private var restoreColumns: (() -> Void)?
    private var windowToken: NSObjectProtocol?
    private var presented: FunctionPanelWindowEnvironment?
    private var page: FunctionPanelPage = .overview
    private var phase: FunctionPanelPhaseInput?
    private var candidates: [String] = []
    private var entry = false
    private var synchronizing = false
    private var closing = false
    var stage: FunctionPanelView? { host.stage }

    init(window: NSWindow, store: ConversationStore, resources: BodyResources,
         current: @escaping () -> Conversation?, connected: @escaping () -> Bool,
         commands: @escaping (Conversation) -> FunctionPanelCommandPresentation,
         read: @escaping FunctionPanelSourceOwner.Read, observe: @escaping FunctionPanelSourceOwner.Observe,
         environment: @escaping () -> FunctionPanelWindowEnvironment,
         intent: @escaping () -> Void = {}, clearFeedback: @escaping () -> Void = {},
         columns: FunctionPanelColumnAccess, actions: @escaping (FunctionPanelAction) -> Void) {
        guard let root = window.contentView else { preconditionFailure("Panel requires a window content view") }
        precondition(!root.subviews.contains { $0 is FunctionPanelWindowHost }, "One panel owner per window")
        self.window = window
        self.resources = resources
        self.current = current
        self.environment = environment
        self.columns = columns
        self.actions = actions
        self.intent = intent
        self.clearFeedback = clearFeedback
        source = FunctionPanelSourceOwner(store: store, read: read, observe: observe,
                                          connected: connected, commands: commands)
        host = FunctionPanelWindowHost(frame: root.bounds)
        host.autoresizingMask = [.width, .height]
        host.isHidden = true
        host.appearance = NSAppearance(named: .darkAqua)
        root.addSubview(host)
        host.owner = self
        source.receive = { [weak self] in self?.accept($0) }
        windowToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.retire() } }
    }
    func present(page: FunctionPanelPage = .overview) {
        let env = environment()
        guard env.visible, let window, host.window === window, let target = current() else { return }
        if isOpen {
            synchronize()
            if isOpen {
                stage?.selectPage(page)
                return
            }
        }
        if closing { finishDismissal() }
        generation += 1
        self.target = target
        targetID = target.id
        presented = env
        self.page = page
        savedResponder = window.firstResponder
        restoreColumns = columns.suspend() // P3.pause
        isOpen = true
        body = FunctionPanelBodyOwner(resources: resources) // P3.resources
        let ticket = generation
        body?.receive = { [weak self] image in
            guard let self, self.isOpen, self.generation == ticket else { return } // P3.generation
            self.synchronize()
            guard self.isOpen else { return }
            self.stage?.updateBodySnapshot(image)
        }
        source.open(target, page: page, bodies: FunctionPanelSourceOwner.bodies(resources))
        guard let stage else {
            dismiss(animated: false)
            return
        }
        host.mount(stage, scopes: columns.views())
        stage.open(page: page)
        window.makeFirstResponder(stage)
    }
    private func accept(_ value: FunctionPanelProjectionSnapshot) {
        guard isOpen else { return }
        guard let target, current() === target, target.id == targetID else {
            dismiss(animated: false)
            return
        }
        snapshot = value
        synchronizing = true
        if let stage { stage.update(value.input) }
        else if let env = presented {
            let viewport = CGRect(origin: .zero, size: env.viewport.size)
            let column = env.column.offsetBy(dx: -env.viewport.minX, dy: -env.viewport.minY)
            let view = FunctionPanelView(input: value.input, viewport: viewport, column: column,
                                         reduced: env.reduced, automatic: true)
            view.frame = env.viewport
            view.onAction = { [weak self] action in
                if case .closed = action { self?.dismiss() } else { self?.submit(action) }
            }
            view.onPresentation = { [weak self] _ in self?.presentation() }
            view.onIntent = intent
            view.onDismissFeedback = clearFeedback
            host.install(view)
        }
        synchronizing = false
        synchronizeBody()
    }
    func refresh() {
        synchronize()
        if isOpen { source.refresh() }
    }
    private func submit(_ action: FunctionPanelAction) {
        synchronize()
        guard isOpen else { return }
        actions(action)
    }
    /// The composition root calls this for target, visibility, scale and Reduce Motion changes.
    func synchronize() {
        guard isOpen else { return }
        let env = environment()
        guard let target, current() === target, target.id == targetID, env.visible,
              let old = presented, old.scale == env.scale, old.reduced == env.reduced else {
            dismiss(animated: false)
            return
        }
        guard env != old else { return }
        presented = env
        synchronizing = true
        stage?.resize(viewport: CGRect(origin: .zero, size: env.viewport.size),
                      column: env.column.offsetBy(dx: -env.viewport.minX, dy: -env.viewport.minY))
        stage?.frame = env.viewport
        synchronizing = false
    }
    private func presentation() {
        guard !synchronizing, let stage else { return }
        if closing {
            if !stage.needsFrames { finishDismissal() }
            return
        }
        guard isOpen, let target else { return }
        if page != stage.state.page {
            page = stage.state.page
            source.open(target, page: page, bodies: FunctionPanelSourceOwner.bodies(resources))
        }
        synchronizeBody()
    }
    private func synchronizeBody() {
        guard !synchronizing, isOpen, let stage, stage.state.isOpen, let snapshot, let env = presented else {
            return
        }
        synchronizing = true
        defer { synchronizing = false }
        guard let fact = snapshot.phase.value else {
            if phase != nil { body?.close() }
            phase = nil
            return
        }
        let next = FunctionPanelPhaseInput(bodyID: snapshot.input.bodyID, event: fact.event, turnID: fact.turnID,
                                           scale: env.scale, bin: 12, quality: .panelHD,
                                           animate: fact.event.animate && !env.reduced)
        let slots = FunctionPanelGeometry.bodySlots(count: snapshot.input.bodies.count, offset: stage.state.bodyScroll)
        let visible = stage.state.option == 0 ? slots.map { snapshot.input.bodies[$0.index].id } : []
        let showEntry = stage.state.option != 0
        guard next != phase || candidates != visible || entry != showEntry else { return }
        phase = next
        candidates = visible
        entry = showEntry
        body?.present(next, candidates: visible, currentEntry: showEntry)
    }
    func dismiss(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        closing = true
        generation += 1
        source.stop()
        body?.close() // P3.close
        phase = nil
        candidates = []
        entry = false
        if animated, let stage {
            if stage.state.isOpen { stage.close() }
            if !stage.needsFrames { finishDismissal() }
        } else { finishDismissal() }
    }
    private func finishDismissal() {
        stage?.onPresentation = nil
        stage?.retire()
        host.unmount()
        body = nil
        restoreColumns?() // P3.restore
        restoreColumns = nil
        if let window, let view = savedResponder as? NSView, view.window === window,
           !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder, columns.admitsFocus(view) {
            window.makeFirstResponder(view)
        }
        savedResponder = nil
        snapshot = nil
        target = nil
        targetID = nil
        closing = false
    }
    func retire() {
        dismiss(animated: false)
        if closing { finishDismissal() }
    }
    isolated deinit {
        source.stop()
        body?.close()
        host.unmount()
        restoreColumns?()
        if let windowToken { NotificationCenter.default.removeObserver(windowToken) }
        host.removeFromSuperview()
    }
}
