import AppKit

/// A window-owned route lease. Suspension keeps explicit intent, but retires every asynchronous receipt.
@MainActor final class TranscriptReferenceRouting {
    var admitted: () -> Bool = { false }
    var selected: () -> Conversation? = { nil }
    var preview: (@MainActor (ReferenceTarget, Conversation) async -> TranscriptReferencePreview)?
    var web: ((URL) -> Void)?
    var show: ((Conversation, SourceLocator, TranscriptReferencePreview) -> Void)?
    private var generation = 0
    private var task: Task<Void, Never>?
    private weak var owner: Conversation?
    private var pending: TranscriptReferenceRequest?
    private var current: TranscriptReferenceRequest?
    isolated deinit { task?.cancel() }
    private func valid(_ c: Conversation, _ request: TranscriptReferenceRequest) -> Bool {
        guard selected() === c, !c.archived, let item = c.items.first(where: { $0.id == request.source.itemID }) else { return false }
        return TranscriptContentIndex.parse(item.text).contains { $0.range == request.source.range && $0.target == request.source.target }
    }
    func open(_ c: Conversation, _ request: TranscriptReferenceRequest) {
        guard valid(c, request) else { return }
        suspend(); owner = c; pending = request; current = nil; resume()
    }
    func suspend() {
        generation += 1; task?.cancel(); task = nil
        if pending == nil { pending = current }; current = nil
    }
    func revoke() {
        suspend(); owner = nil; pending = nil; current = nil
    }
    func reconcile() {
        if let owner, selected() !== owner { revoke(); return }
        if admitted() { resume() } else { suspend() }
    }
    func resume() {
        guard admitted(), let c = owner, let request = pending else { return }
        guard valid(c, request) else { revoke(); return }
        pending = nil; current = request
        let token = generation
        let loader = preview
        task = Task { [weak self, weak c] in
            guard let c else { return }
            // Admission can be published inside a native mount. Present only after that stack has returned.
            guard self?.begin(c, request, token: token) == true else { return }
            let result = await loader?(request.source.target, c) ?? .init(state: .unavailable, message: "No registered preview is available for this target.")
            self?.finish(c, request, token: token, result: result)
        }
    }
    private func begin(_ c: Conversation, _ request: TranscriptReferenceRequest, token: Int) -> Bool {
        guard generation == token, admitted(), valid(c, request), !Task.isCancelled else { return false }
        if case .web(let raw) = request.source.target, let url = URL(string: raw) {
            current = nil; task = nil; web?(url); return false
        }
        show?(c, request.source, .init(state: .loading, message: "Loading read-only preview…"))
        return generation == token && admitted()
    }
    private func finish(_ c: Conversation, _ request: TranscriptReferenceRequest, token: Int, result: TranscriptReferencePreview) {
        guard generation == token, admitted(), valid(c, request), !Task.isCancelled else { return }
        current = nil; task = nil; show?(c, request.source, result)
    }
}
