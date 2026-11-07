import Foundation

/// Adapter only: existing MockReplay and all old callers/scripts remain unchanged.
@MainActor final class MockConversationRuntime: ConversationRuntime {
    let store: ConversationStore
    let replay: MockReplay
    var isShown: (ConversationID) -> Bool = { _ in false }
    var onRedEvent: (Conversation) -> Void = { _ in }
    var animatePlayback = true
    private var receipts: [UUID: CoreSubmissionReceipt] = [:]
    private var snapshots: [UUID: CoreSubmission] = [:]
    private var owners: [UUID: String] = [:]
    private var stopIDs: Set<UUID> = []
    init(store: ConversationStore, replay: MockReplay? = nil, animatePlayback: Bool = true) { self.store = store; self.replay = replay ?? MockReplay(store: store); self.animatePlayback = animatePlayback }
    func start() { replay.start(live: animatePlayback) }
    func shutdown() { replay.stopPlayback() }
    @discardableResult func send(_ c: Conversation, text: String, followUp: FollowUp = .steer) -> Bool { replay.send(c, text: text, followUp: followUp) }
    @discardableResult func submit(_ s: CoreSubmission, in c: Conversation, completion: @escaping @MainActor (CoreSubmissionReceipt) -> Void) -> Bool {
        if stopIDs.contains(s.id) { completion(.init(id: s.id, result: .failed("This UUID belongs to an interrupt request."))); return false }
        if let old = snapshots[s.id], old != s || owners[s.id] != c.id { completion(.init(id: s.id, result: .failed("A UUID cannot be reused with another snapshot or chat."))); return false }
        snapshots[s.id] = s; owners[s.id] = c.id
        if let receipt = receipts[s.id] { completion(receipt); return receipt.result == .accepted }
        guard s.identity == nil || s.identity == c.id else { let r = CoreSubmissionReceipt(id: s.id, result: .failed("Submission identity does not match this chat.")); receipts[s.id] = r; completion(r); return false }
        guard !(s.action == .send && c.running), !(s.action == .steer && (!c.running || c.activeTurnID != s.waitingForTurnID)), !(s.action == .queue && c.running && c.activeTurnID != s.waitingForTurnID) else {
            let r = CoreSubmissionReceipt(id: s.id, result: .failed("The captured send action no longer matches the active turn.")); receipts[s.id] = r; completion(r); return false
        }
        let before = c.next, previousAccess = c.access, files = c.attachments
        c.next = s.settings; c.access = s.access; c.attachments = s.attachments
        let accepted = send(c, text: s.text, followUp: s.action == .queue ? .queue : .steer); c.next = before
        if !accepted { c.access = previousAccess; c.attachments = files }
        let receipt = CoreSubmissionReceipt(id: s.id, result: accepted ? .accepted : .failed("Mock declined the submission."))
        receipts[s.id] = receipt; completion(receipt); return accepted
    }
    func interrupt(_ c: Conversation, id: UUID, completion: @escaping @MainActor (CoreSubmissionReceipt) -> Void) {
        if snapshots[id] != nil { completion(.init(id: id, result: .failed("This UUID belongs to a message submission."))); return }
        stopIDs.insert(id)
        if let r = receipts[id] { completion(r); return }; let active = c.running; stop(c)
        let r = CoreSubmissionReceipt(id: id, result: active ? .accepted : .failed("There is no active turn.")); receipts[id] = r; completion(r)
    }
    func createConversation(title: String, projectID: String?, deviceID: String, firstMessage: String, attachments: [Attachment]) -> Conversation {
        let c = createUnsentConversation(title: title, projectID: projectID, deviceID: deviceID); c.attachments = attachments; c.draft = firstMessage; store.add(c); _ = send(c, text: firstMessage); return c
    }
    func stop(_ c: Conversation) { replay.stop(c) }
    func respond(_ approval: Approval, in c: Conversation, action: ApprovalAction) { replay.respond(approval, in: c, action: action) }
    func respond(_ approval: Approval, in c: Conversation, response: JSONValue) {
        let word = response["decision"]?.stringValue ?? response["action"]?.stringValue
        respond(approval, in: c, action: word == "accept" ? .accept : word == "decline" ? .decline : .cancel)
    }
    func answer(_ request: UserInputRequest, in c: Conversation, answers: [String: [String]]) { replay.answer(request, in: c, answers: answers) }
    func refresh(_ c: Conversation) { c.operationError = nil; store.changed(c) }
    func markSeen(_ c: Conversation) { c.completions = 0; c.unread = false; store.changed(c) }
    func rename(_ c: Conversation, title: String) { c.title = title; store.changed(c) }
    func setArchived(_ c: Conversation, archived: Bool) { c.archived = archived; c.archivedAt = archived ? Date() : nil; store.changed(c) }
    func setPinned(_ c: Conversation, pinned: Bool) { c.pinned = pinned; store.changed(c) }
    func attach(_ c: Conversation) { let sample = Attachment.samples[c.attachments.count % Attachment.samples.count]; c.attachments.append(.init(id: UUID().uuidString, name: sample.0, symbol: sample.1)); store.changed(c) }
    func removeAttachment(_ a: Attachment, from c: Conversation) { c.attachments.removeAll { $0.id == a.id }; store.changed(c) }
    func fork(_ c: Conversation, at itemID: String) -> Conversation? {
        guard let i = c.items.firstIndex(where: { $0.id == itemID }) else { return nil }; let fork = createUnsentConversation(title: "Fork of " + c.title, projectID: c.projectID, deviceID: c.deviceID)
        fork.items = Array(c.items.prefix(through: i)); fork.draft = c.items[i].text; store.add(fork); return fork
    }
    func compactNow(_ c: Conversation) { c.compactions += 1; c.contextUsed *= 0.5; store.changed(c) }
    func commit(_ c: Conversation, message: String) { c.lastCommit = .init(message: message, hash: "prototype", at: Date()); store.changed(c) }
    func revert(_ card: TranscriptItem, in c: Conversation) { replay.revert(card, in: c) }
    func toggleDictation(_ c: Conversation) { c.dictating.toggle(); store.changed(c) }
    func startVoice(_ c: Conversation) { c.voice = ""; store.changed(c) }
    func endVoice(_ c: Conversation) { c.voice = nil; store.changed(c) }
    func sendVoice(_ c: Conversation) { if let text = c.voice { _ = send(c, text: text) }; c.voice = nil }
}
