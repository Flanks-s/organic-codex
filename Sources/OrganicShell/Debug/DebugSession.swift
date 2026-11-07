import AppKit

/// Source-compatible name; the mock source owns these mutations as well as its only clock.
typealias DebugInjection = MockInjection

/// The panel is a client of the App's one MockReplay. Construction, opening and closing a
/// panel never seed or start playback. App explicitly calls startPlayback() once after wiring.
@MainActor final class DebugSession {
    let store: ConversationStore
    let replay: MockReplay?
    let tuning: DebugTuning
    var onArrive: ((Conversation) -> Void)?
    var onChange: (() -> Void)?
    private(set) var selectedID: String?
    private let initiallyPaused: Bool
    private var tuningObservation: UUID?
    var paused: Bool { replay?.isPlaybackActive != true }
    var backgroundEvents: Bool { replay?.backgroundEvents ?? true }
    var ticks: Int { replay?.totalTicks ?? 0 }
    var canInject: Bool { replay?.isBound(to:store) == true && replay?.canPlay == true && !store.usesLiveCore && !store.conversations.contains(where: { $0.isLiveConversation }) }
    var selected: Conversation? { selectedID.flatMap(store.conversation) }

    init(store: ConversationStore, replay: MockReplay?, initiallyPaused: Bool = false, tuning: DebugTuning = DebugTuning()) {
        self.store = store; self.replay = replay; self.initiallyPaused = initiallyPaused; self.tuning = tuning
        selectedID = store.conversations.first?.id
        tuningObservation = tuning.observe { [weak self] snapshot in self?.applyPlayback(snapshot) }
    }
    isolated deinit { if let tuningObservation { tuning.removeObserver(tuningObservation) } }
    private func applyPlayback(_ snapshot: DebugTuningSnapshot) {
        if canInject { _ = replay?.updatePlaybackSettings(snapshot.playback) }
        onChange?()
    }
    /// App startup only; does not belong to a window/panel's activate() lifetime.
    @discardableResult func startPlayback() -> Bool {
        guard canInject else { stopClock(); return false }
        applyPlayback(tuning.snapshot)
        replay?.start(live: !initiallyPaused); onChange?(); return true
    }
    @discardableResult func select(_ id: String) -> Bool {
        guard store.conversation(id) != nil else { return false }; selectedID = id; onChange?(); return true
    }
    @discardableResult func setPaused(_ value: Bool) -> Bool {
        guard canInject else { stopClock(); return false }
        let ok = replay?.setPaused(value) == true; onChange?(); return ok
    }
    @discardableResult func setBackgroundEvents(_ value: Bool) -> Bool {
        guard canInject else { return false }
        let ok = replay?.setBackgroundEvents(value) == true; onChange?(); return ok
    }
    @discardableResult func step() -> Bool {
        guard canInject else { return false }; let ok = replay?.step() == true; onChange?(); return ok
    }
    func stopClock() { if replay?.isBound(to:store) == true { replay?.stopPlayback() } }
    @discardableResult func inject(_ event: DebugInjection, into id: String? = nil) -> Bool {
        guard canInject else { return false }
        let ok = replay?.inject(event, into: id ?? selectedID) == true; onChange?(); return ok
    }
    @discardableResult func arrive() -> Conversation? {
        guard canInject, let c = replay?.arrive() else { return nil }
        selectedID = c.id; onArrive?(c); onChange?(); return c
    }
}
