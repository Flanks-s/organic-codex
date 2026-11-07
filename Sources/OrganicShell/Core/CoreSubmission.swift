import Foundation

enum CoreSubmissionAction: String, Codable, Sendable { case send, steer, queue }
enum CoreSubmissionResult: Equatable, Sendable { case accepted, failed(String), outcomeUnknown(String) }
struct CoreSubmissionReceipt: Equatable, Sendable {
    enum Acceptance: String, Sendable { case backend, durableLocalQueue }
    let id: UUID
    let result: CoreSubmissionResult
    var acceptance: Acceptance? = nil
}
/// UI-independent immutable input. App maps NativeComposerSubmission once, preserving its UUID.
@MainActor struct CoreSubmission: Equatable, Sendable {
    let id: UUID
    let identity: String?
    let action: CoreSubmissionAction
    let text: String
    let attachments: [Attachment]
    let settings: ModelSettings
    let access: Access
    let waitingForTurnID: String?
    init(id: UUID = UUID(), identity: String? = nil, action: CoreSubmissionAction = .send, text: String,
         attachments: [Attachment] = [], settings: ModelSettings = ModelSettings(), access: Access = .auto, waitingForTurnID: String? = nil) {
        self.id = id; self.identity = identity; self.action = action; self.text = text; self.attachments = attachments
        self.settings = settings; self.access = access; self.waitingForTurnID = waitingForTurnID
    }
}
