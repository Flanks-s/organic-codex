import AppKit

struct NormieNewChatContext: Equatable { var projectID: String?; var deviceID = "mac" }
struct NormieGitReview: Equatable {
    var conversationID: String
    var hash: String?
    var paths: [String]
    var changes: [FileChange]
    @MainActor init(_ c: Conversation) {
        conversationID = c.id; hash = c.gitDiffHash
        paths = c.gitPaths.isEmpty ? c.changes.map(\.path) : c.gitPaths; changes = c.changes
    }
    @MainActor func isCurrent(_ c: Conversation) -> Bool { self == Self(c) }
}

/// Host supplies real backend operations; never acknowledge a Live action merely because a button was pressed.
@MainActor final class NormieActions {
    var submit: ((Conversation, NativeComposerSubmission, @escaping @MainActor (NativeComposerCompletion) -> Void) -> Void)?
    /// Return an UNSENT model. Workbench promotes the retained draft, then calls submit exactly once.
    var create: ((NormieNewChatContext, NativeComposerSubmission) -> Conversation?)?
    /// Preferred stop path. Forward this UUID to runtime.interrupt; complete exactly once with its actual receipt.
    var interrupt: ((Conversation, UUID, @escaping @MainActor (NativeComposerCompletion) -> Void) -> Void)?
    var stop: ((Conversation) -> Void)?
    /// A refresh is a read-only request, not a send receipt. Core updates the model/loading/error via the store.
    var refreshHistory: ((Conversation) -> Void)?
    /// Normal (non-archived) backend list cursor. Core owns cursor/deduplication; sidebar owns only presentation.
    var hasMoreHistory: (() -> Bool)?
    var loadMoreHistory: ((@escaping @MainActor (Result<Void, Error>) -> Void) -> Void)?
    var pin: ((Conversation, Bool) -> Void)?
    var archive: ((Conversation, Bool) -> Void)?
    var rename: ((Conversation, String) -> Void)?
    var markSeen: ((Conversation) -> Void)?
    var approval: ((Conversation, Approval, ApprovalAction) -> Void)?
    var approvalValue: ((Conversation, Approval, JSONValue) -> Void)?
    var answer: ((Conversation, UserInputRequest, [String: [String]]) -> Void)?
    var edit: ((Conversation, TranscriptItem) -> Void)?
    var fork: ((Conversation, TranscriptItem) -> Void)?
    var revertTranscript: ((Conversation, TranscriptItem) -> Void)?
    var commit: ((Conversation, String, NormieGitReview) -> Void)?
    var revert: ((Conversation, NormieGitReview) -> Void)?
    var compact: ((Conversation) -> Void)?
    var subAgent: ((Conversation, Satellite) -> Void)?
    var referencePreview: (@MainActor (ReferenceTarget, Conversation) async -> TranscriptReferencePreview)?
    var referenceWeb: ((URL) -> Void)?
    var chooseWorkspace: ((NormieNewChatContext, @escaping @MainActor (Project?) -> Void) -> Void)?
    var configureComposer: ((NativeComposer, Conversation?) -> Void)?
    var command: ((NormieCommand, Int) -> Void)?
    var externalCommands: Set<NormieCommand> = []
}
