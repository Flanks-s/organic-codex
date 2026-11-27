import AppKit

/// Repositories own subscriptions; a page lease may deliver only into its original generation.
@MainActor final class FunctionPanelSourceOwner {
    typealias Read = (Conversation, FunctionPanelPage) -> FunctionPanelReadSources
    typealias Observe = (Conversation, FunctionPanelPage, @escaping () -> Void) -> (() -> Void)
    let projection: FunctionPanelProjection
    private let read: Read
    private let observe: Observe
    private let connected: () -> Bool
    private let commands: (Conversation) -> FunctionPanelCommandPresentation
    private var cancel: (() -> Void)?
    private var generation = 0
    private var target: Conversation?
    private var page: FunctionPanelPage?
    private var bodies: [FunctionPanelBodyOption] = []
    var artifacts: FunctionPanelArtifactPreviewOwner? {
        didSet {
            oldValue?.stop()
            artifacts?.changed = { [weak self] in self?.publish() }
            refresh()
        }
    }
    var receive: (FunctionPanelProjectionSnapshot) -> Void = { _ in }
    private(set) var subscribed = false

    init(store: ConversationStore, read: @escaping Read, observe: @escaping Observe,
         connected: @escaping () -> Bool,
         commands: @escaping (Conversation) -> FunctionPanelCommandPresentation) {
        projection = FunctionPanelProjection(store: store)
        self.read = read
        self.observe = observe
        self.connected = connected
        self.commands = commands
    }
    static func bodies(_ resources: BodyResources) -> [FunctionPanelBodyOption] {
        guard let catalogue = resources.catalogue else { return [] }
        return catalogue.bodies.filter { BodyIdentityAdapter.choices.contains($0.id) }.map {
            .init(id: $0.id, name: $0.name)
        }
    }
    static func colours(_ resources: BodyResources) -> [FunctionPanelColour] {
        let bodies = resources.catalogue?.bodies ?? []
        var seen = Set<String>()
        let tints = BodyTintCatalogue.legacy + bodies.filter {
            BodyIdentityAdapter.choices.contains($0.id)
        }.map(BodyTintCatalogue.defaultTint)
        return tints.compactMap { tint in
            guard seen.insert(tint.id).inserted, let hex = UInt32(tint.hex.dropFirst(), radix: 16) else {
                return nil
            }
            let source = bodies.first { $0.colorHex == tint.hex && !$0.tone.isEmpty }
            return .init(id: tint.id, name: tint.name, bodyName: source?.name ?? "", hex: hex)
        }
    }
    static func defaultTint(for id: String) -> String? {
        guard let catalogue = BodyResources.shared.catalogue, let body = try? catalogue.body(id) else { return nil }
        return BodyTintCatalogue.defaultTint(body).id
    }
    func open(_ target: Conversation, page: FunctionPanelPage, bodies: [FunctionPanelBodyOption]) {
        if self.target === target, self.page == page { return }
        stop()
        self.target = target
        self.page = page
        self.bodies = bodies
        let ticket = generation
        subscribed = true
        let release = observe(target, page) { [weak self, weak target] in
            guard let self, let target, self.generation == ticket, self.target === target else { return }
            self.publish()
        }
        if generation == ticket { cancel = release } else { release() }
        refresh()
    }
    func refresh() {
        if let target, let page, let artifacts {
            artifacts.load(target, page: page, mapped: read(target, page).artifactThreads)
        }
        publish()
    }
    private func publish() {
        guard let target, let page else { return }
        var facts = read(target, page)
        facts.connected = connected()
        if let artifacts { facts.artifacts = artifacts.listing }
        let key = artifacts.map { "\($0.id):\($0.revision)" } ?? ""
        let value = projection.project(target, page: page, sources: facts, bodies: bodies, artifactKey: key)
        var input = value.input
        var presentation = commands(target)
        if let artifacts {
            let materials = artifacts.capabilities(input)
            input.materials = materials
            if !materials.openIDs.isEmpty { presentation.available.formUnion(["cover.open", "output.open"]) }
            if !materials.fileIDs.isEmpty { presentation.available.insert("file.open") }
            if !materials.copyIDs.isEmpty { presentation.available.formUnion(["cover.copy", "output.copy"]) }
            presentation.feedback = artifacts.feedback ?? presentation.feedback
        }
        input.commands = presentation
        receive(.init(input: input, phase: value.phase))
    }
    func stop() {
        generation += 1
        artifacts?.stop()
        let release = cancel
        cancel = nil
        subscribed = false
        target = nil
        page = nil
        release?()
    }
    isolated deinit {
        artifacts?.stop()
        cancel?()
    }
}
