import Foundation

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
    func compactNow(_ c: Conversation)
    func commit(_ c: Conversation, message: String)
    func revert(_ card: TranscriptItem, in c: Conversation)
    func toggleDictation(_ c: Conversation)
    func startVoice(_ c: Conversation)
    func endVoice(_ c: Conversation)
    func sendVoice(_ c: Conversation)
}

extension ConversationRuntime {
    func shutdown() {}
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

