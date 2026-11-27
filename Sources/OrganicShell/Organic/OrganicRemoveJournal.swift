import Foundation

/// The only persisted Remove preference. Production supplies .standard; checks supply a private suite.
struct OrganicRemovePreferences {
    static let key = "organic.remove.suppressEducation.v1"
    let defaults: UserDefaults
    var suppressEducation: Bool { defaults.bool(forKey: Self.key) }
    func suppress() { defaults.set(true, forKey: Self.key) }
}

/// Ephemeral, window-local journal. Persist the resulting layout, never this clock across process launches.
struct OrganicRemoveJournal {
    enum Prompt: String { case education, toast }
    static let editTitle = "Undo Remove from Organic"
    static let fullMessage = "The Dock is full"
    static let lastColumnMessage = "The last column stays"
    private(set) var receipt: OrganicRemovalReceipt?
    private(set) var prompt: Prompt?
    private(set) var remaining = 0.0
    private(set) var started = false
    private var lastTime: Double?
    private var hovered = false
    private var keyboardFocused = false
    private var consumedSessions: Set<UUID> = []
    private var boundWindowID: UUID?
    private var boundScope: String?
    private var retired = false
    var canUndo: Bool { receipt != nil && remaining > 0 }
    var editMenuTitle: String? { canUndo ? Self.editTitle : nil }
    var isPaused: Bool { prompt != nil && (hovered || keyboardFocused) }

    /// The common value-level entry for both removal sources. Rejections cannot replace the current receipt.
    @discardableResult mutating func record(_ outcome: Result<OrganicRemovePolicy.Removal, OrganicRemovePolicy.Rejection>,
                                           suppressed: Bool, at time: Double) -> Bool {
        guard case .success(let removal) = outcome else { return false }
        return install(removal.receipt,suppressed:suppressed,at:time)
    }

    /// Scene adapters install only after a successful layout commit. The old receipt survives any rejected request.
    @discardableResult mutating func install(_ receipt: OrganicRemovalReceipt, suppressed: Bool, at time: Double) -> Bool {
        guard !retired, time.isFinite, !consumedSessions.contains(receipt.sessionID),
              boundWindowID == nil || boundWindowID == receipt.windowID,
              boundScope == nil || boundScope == receipt.endpointScope else { return false }
        boundWindowID = receipt.windowID; boundScope = receipt.endpointScope
        consumedSessions.insert(receipt.sessionID)
        self.receipt = receipt
        remaining = suppressed ? 5 : 6
        prompt = nil; started = false; lastTime = time; hovered = false; keyboardFocused = false
        return true
    }
    mutating func present(_ kind: Prompt, receiptID: UUID, at time: Double) {
        advance(to: time)
        guard receipt?.id == receiptID, !started, canUndo else { return }
        if kind == .toast { remaining = min(remaining,5) }
        started = true; prompt = kind; lastTime = time
    }
    mutating func advance(to time: Double) {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { return }
        if started, !isPaused, let lastTime { remaining = max(0, remaining - (time - lastTime)) }
        lastTime = time
        if remaining <= 0 { receipt = nil; prompt = nil; hovered = false; keyboardFocused = false }
    }
    mutating func pause(hover: Bool, focus: Bool, at time: Double) {
        advance(to: time); hovered = hover; keyboardFocused = focus
    }
    mutating func suppressCurrentEducation(at time: Double) {
        advance(to: time)
        guard canUndo else { return }
        // The preference adapter writes the installation flag; this value type only changes presentation.
        if prompt == .education { prompt = .toast }
    }
    /// Escape, outside click, a new drag, mode change and resignation close UI without rolling back membership.
    mutating func dismiss(at time: Double) {
        advance(to: time)
        started = true; prompt = nil; hovered = false; keyboardFocused = false; lastTime = time
    }
    mutating func undo(receiptID: UUID, in layout: OrganicMemberLayout, availability: OrganicRemovePolicy.Availability,
                       capacity: OrganicUndoCapacity, at time: Double) -> OrganicRemovePolicy.Undo {
        advance(to: time)
        guard canUndo, let receipt, receipt.id == receiptID else { return .unavailable }
        let result = OrganicRemovePolicy.undo(receipt, in: layout, availability: availability, capacity: capacity)
        switch result {
        case .restored, .alreadyPresent, .unavailable: clear()
        case .full: break // Add wins. Keep the record and the original expiry so the user can retry.
        }
        return result
    }
    mutating func retireWindow() { clear(); consumedSessions = []; retired = true }
    private mutating func clear() {
        receipt = nil; prompt = nil; remaining = 0; lastTime = nil; started = false
        hovered = false; keyboardFocused = false
    }
}
