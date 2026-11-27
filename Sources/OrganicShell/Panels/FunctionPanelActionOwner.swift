import Foundation

/// Uses the window's runtime and local identity persistence for qualified operations.
@MainActor final class FunctionPanelActionOwner {
    private struct Target {
        let value: Conversation
        let id: String
        let thread: String?
        @MainActor init(_ value: Conversation) { self.value = value; id = value.id; thread = value.backendThreadID }
    }
    let store: ConversationStore
    let runtime: any ConversationRuntime
    let presentation: LocalPresentationState?
    let windows: SheetSubAgentWindows
    private let parent: Target
    private let children: [String: Target]
    private let current: () -> Conversation?
    private let connected: () -> Bool
    private let capabilities: () -> Set<String>
    private let modelPicker: () -> OverlayComposerBinding?
    private let colours: [FunctionPanelColour]
    private var admitted: [FunctionPanelAction] = []
    private(set) var pending = false
    private(set) var submissions = 0
    private(set) var result: String?
    private(set) var bodyDraft: String?
    private(set) var colourDraft: String?
    private(set) var titleDraft: String?
    private(set) var editedModel: ModelSettings?
    var onChange: (() -> Void)?

    init(conversation: Conversation, store: ConversationStore, runtime: any ConversationRuntime,
         presentation: LocalPresentationState?, windows: SheetSubAgentWindows,
         current: @escaping () -> Conversation?, connected: @escaping () -> Bool,
         capabilities: @escaping () -> Set<String>, colours: [FunctionPanelColour] = [],
         modelPicker: @escaping () -> OverlayComposerBinding? = { nil }) {
        precondition(runtime.store === store && (presentation == nil || presentation?.store === store))
        self.store = store; self.runtime = runtime; self.presentation = presentation; self.windows = windows
        parent = Target(conversation)
        self.current = current
        self.connected = connected
        self.capabilities = capabilities
        self.colours = colours
        self.modelPicker = modelPicker
        children = Dictionary(uniqueKeysWithValues: conversation.satellites.compactMap { satellite in
            satellite.threadID.flatMap { store.conversation($0) }.map { (satellite.id, Target($0)) }
        })
    }
    static func key(_ action: FunctionPanelAction) -> String? {
        switch action {
        case .body(let id): "body." + id
        case .colour(let id): "colour." + id
        case .fork: "fork"
        case .stop: "stop"
        case .rename: "rename"
        case .compact: "compact"
        case .archive: "archive"
        case .undoArchive: "undoArchive"
        case .model: "model"
        case .openSubagent(let id): "sub.open." + id
        case .stopSubagent(let id): "sub.stop." + id
        default: nil // No result-bearing write port: deliberately absent, including Export.
        }
    }
    var value: FunctionPanelCommandPresentation {
        let c = parent.value
        let identity = ConversationIdentity.resolved(index: c.identityIndex, symbol: c.identitySymbol,
                                                     tint: c.identityTint)
        return .init(available: capabilities(), feedback: result, bodyDraft: bodyDraft, colours: colours,
                     colourID: colourDraft ?? identity.tint)
    }
    /// A fresh first click/key gesture starts a new intent. A double click or a repeated receipt uses this intent.
    func beginIntent() { if !pending { admitted = [] } }
    func dismissFeedback() { result = nil; onChange?() }
    private func qualifiedTarget(_ action: FunctionPanelAction) -> Target? {
        guard let key = Self.key(action) else { return nil }
        let childID: String?
        switch action { case .openSubagent(let id), .stopSubagent(let id): childID = id; default: childID = nil }
        let target = childID.flatMap { children[$0] } ?? parent
        let parentMatches = current() === parent.value && store.conversation(
            parent.id) === parent.value && parent.value.backendThreadID == parent.thread
        let childMatches = childID.map { id in
            children[id] != nil && parent.value.satellites.contains { $0.id == id && $0.threadID == target.thread }
                && store.conversation(target.id) === target.value && target.value.backendThreadID == target.thread
        } ?? true
        guard parentMatches && childMatches else {
            reject("The conversation changed. Reopen the panel to submit.")
            return nil
        } // D.target
        guard connected() else { reject("Disconnected. Reconnect before submitting."); return nil } // D.connection
        guard capabilities().contains(key) else {
            reject("This action is no longer available. Your input is kept.")
            return nil
        } // D.capability
        return target
    }
    /// Cache success and failure for this intent. A fresh gesture may retry without losing input.
    func submit(_ action: FunctionPanelAction) {
        if case .body(let id) = action { bodyDraft = id }
        if case .colour(let id) = action { colourDraft = id }
        if case .rename(let title) = action { titleDraft = title }
        guard let target = qualifiedTarget(action) else { return }
        guard !pending && !admitted.contains(action) else { return } // D.dedup
        submissions += 1; admitted.append(action); pending = true; result = "Submitting…"; onChange?()
        switch action {
        case .rename(let title):
            write(.rename(title), action: action, target: target.value, success: "Title saved")
        case .compact:
            write(.compact, action: action, target: target.value, success: "Compact request accepted")
        case .archive, .undoArchive:
            let archived = action == .archive
            write(.archive(archived), action: action, target: target.value, success: archived ? "Archived" : "Restored")
        case .model:
            openModel(action, target: target.value)
        case .colour(let id):
            do {
                try setIdentity(target.value, symbol: target.value.identitySymbol, tint: id)
                finish(action, target: target.value, error: nil, success: "Appearance saved")
            } catch { finish(action, target: target.value, error: error.localizedDescription, success: "") }
        case .body(let id):
            do {
                let tint = target.value.identityTint ?? FunctionPanelSourceOwner.defaultTint(for: id)
                try setIdentity(target.value, symbol: id, tint: tint)
                finish(action, target: target.value, error: nil, success: "Appearance saved")
            } catch { finish(action, target: target.value, error: error.localizedDescription, success: "") }
        case .fork:
            Task { [self] in
                // The actor task may start after the click's context changed; revalidate at the write boundary.
                guard qualifiedTarget(action) != nil else { pending = false; onChange?(); return }
                do {
                    _ = try await runtime.forkWhole(target.value)
                    finish(action, target: target.value, error: nil, success: "Fork created")
                }
                catch { finish(action, target: target.value, error: error.localizedDescription, success: "") }
            }
        case .stop, .stopSubagent:
            runtime.interrupt(target.value, id: UUID()) { [weak self] receipt in
                guard let self else { return }
                switch receipt.result {
                case .accepted: self.finish(action, target: target.value, error: nil, success: "Stop accepted")
                case .failed(let reason), .outcomeUnknown(let reason): self.finish(action, target: target.value,
                    error: reason, success: "")
                }
            }
        case .openSubagent(let id):
            let opened = windows.present(subagentID: id, of: parent.value)
            finish(action, target: target.value, error: opened ? nil : "The child conversation could not be opened.",
                success: "Child opened")
        default: break
        }
    }
    private func setIdentity(_ c: Conversation, symbol: String?, tint: String?) throws {
        if let presentation {
            try presentation.setIdentity(c, symbol: symbol, tint: tint)
        } else {
            guard !store.usesLiveCore, store.canSelectBodyIdentity else {
                throw CoreWire.failure("The body identity is unavailable.")
            }
            c.identitySymbol = symbol
            c.identityTint = tint
            store.changed(c)
        }
    }
    private func write(_ change: ConversationEdit, action: FunctionPanelAction, target: Conversation, success: String) {
        runtime.edit(change, in: target, qualify: { [weak self] in
            guard let self else { return "The panel closed before the request was sent." }
            return self.qualifiedTarget(action) == nil ? self.result : nil
        }) { [weak self] receipt in
            guard let self else { return }
            self.finish(action, target: target, error: Self.error(receipt), success: success)
        }
    }
    private func openModel(_ action: FunctionPanelAction, target: Conversation) {
        pending = false
        result = nil
        let picker = modelPicker()
        let presented = picker?.presentModelPicker(for: target, qualify: { [weak self, weak picker] in
            guard let self, self.qualifiedTarget(action) != nil else { return false }
            guard let picker, self.modelPicker() === picker else {
                self.reject("This Model picker is no longer available.")
                return false
            }
            return true
        }, completion: { [weak self] receipt in
            guard let self else { return }
            if receipt == .accepted { self.editedModel = target.next }
            self.result = Self.error(receipt) ?? "Next model updated"
            self.onChange?()
        }) == true
        if !presented { reject("This Model picker is no longer available.") }
        else { onChange?() }
    }
    private static func error(_ receipt: CoreSubmissionResult) -> String? {
        switch receipt {
        case .accepted: nil
        case .failed(let error): error
        case .outcomeUnknown(let error): "Outcome unknown · " + error
        }
    }
    private func reject(_ reason: String) { result = reason; onChange?() }
    private func finish(_ action: FunctionPanelAction, target: Conversation, error: String?, success: String) {
        pending = false
        if let error {
            // The write port owns rollback and ambiguous outcomes; the panel never invents either.
            result = error // D.rollback
        } else { result = success }
        if error == nil {
            if case .body = action { bodyDraft = nil }
            if case .colour = action { colourDraft = nil }
        }
        onChange?()
    }
}
