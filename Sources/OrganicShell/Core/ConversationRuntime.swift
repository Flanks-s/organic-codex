import Foundation

/// Whole-orb forks use the backend's end-of-history boundary, never a message boundary.
struct OrbWholeForkRequest {
    let threadID: String
    let method = "thread/fork"
    var params: [String:JSONValue] { ["threadId":.string(threadID),"deferGoalContinuation":true] }
}

/// The operations used by Organic's existing native UI. Presentation and window geometry stay in the shell.
@MainActor protocol ConversationRuntime: AnyObject {
    var store: ConversationStore { get }
    var isShown: (ConversationID) -> Bool { get set }
    var onRedEvent: (Conversation) -> Void { get set }
    func start()
    func shutdown()
    func createUnsentConversation(title: String, projectID: String?, deviceID: String) -> Conversation
    @discardableResult func submit(_ submission: CoreSubmission, in c: Conversation, completion: @escaping @MainActor (CoreSubmissionReceipt) -> Void) -> Bool
    func interrupt(_ c: Conversation, id: UUID, completion: @escaping @MainActor (CoreSubmissionReceipt) -> Void)
    @discardableResult func send(_ c: Conversation, text: String, followUp: FollowUp) -> Bool
    func createConversation(title: String, projectID: String?, deviceID: String, firstMessage: String, attachments: [Attachment]) -> Conversation
    func stop(_ c: Conversation)
    func respond(_ approval: Approval, in c: Conversation, action: ApprovalAction)
    func respond(_ approval: Approval, in c: Conversation, response: JSONValue)
    func refresh(_ c: Conversation)
    func answer(_ request: UserInputRequest, in c: Conversation, answers: [String: [String]])
    func markSeen(_ c: Conversation)
    func rename(_ c: Conversation, title: String)
    func setArchived(_ c: Conversation, archived: Bool)
    func setPinned(_ c: Conversation, pinned: Bool)
    func attach(_ c: Conversation)
    func removeAttachment(_ a: Attachment, from c: Conversation)
    func fork(_ c: Conversation, at itemID: String) -> Conversation?
    func forkWhole(_ c: Conversation) async throws -> Conversation
    func compactNow(_ c: Conversation)
    func commit(_ c: Conversation, message: String)
    func revert(_ card: TranscriptItem, in c: Conversation)
    func toggleDictation(_ c: Conversation)
    func startVoice(_ c: Conversation)
    func endVoice(_ c: Conversation)
    func sendVoice(_ c: Conversation)
}

extension Conversation {
    /// Exclude the entire active turn, including its already completed tool and user rows.
    var completedForkItems: [TranscriptItem] {
        let active = activeTurnID ?? items.first(where: { $0.running })?.turnID ?? (running ? items.last?.turnID : nil)
        guard let active, let boundary = items.firstIndex(where: { $0.turnID == active }) else { return items }
        return Array(items.prefix(boundary))
    }
}

extension ConversationRuntime {
    func shutdown() {}
    /// The requesting window owns whole-Fork admission. Background arrival handling
    /// must not admit it into another window or choose a column before its Dock callback.
    func registerWholeFork(_ fork: Conversation) {
        let arrival = store.onAdd
        store.onAdd = nil
        store.add(fork)
        store.onAdd = arrival
    }
    func createUnsentConversation(title: String, projectID: String?, deviceID: String = "mac") -> Conversation {
        let c = Conversation(id: UUID().uuidString, identityIndex: store.nextIdentity(), title: title, projectID: projectID, deviceID: deviceID, updated: Date(), contextUsed: 0)
        c.cwd = store.project(projectID)?.path; c.next = store.newChatSettings; c.settings = c.next
        return c // No store insertion, thread creation or send before the UI admits/promotes this identity.
    }
    func createConversation(title: String, projectID: String?, deviceID: String, firstMessage: String) -> Conversation {
        createConversation(title: title, projectID: projectID, deviceID: deviceID, firstMessage: firstMessage, attachments: [])
    }
    @discardableResult func send(_ c: Conversation, text: String) -> Bool { send(c, text: text, followUp: .steer) }
    func createConversation(title: String, projectID: String?, firstMessage: String) -> Conversation {
        createConversation(title: title, projectID: projectID, deviceID: "mac", firstMessage: firstMessage)
    }
}

