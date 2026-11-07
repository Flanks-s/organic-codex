import AppKit

/// Host-owned runtime state. Updating it never replaces the editor or commits marked text.
struct NativeComposerState: Equatable {
    var running = false
    var sending = false
    var stopping = false
    var loading = false
    var outcomeUnknown = false
    var online = true
    var usesLiveCore = false
    var operationError: String?
    var voice: String?
    var dictating = false
}

enum NativeComposerAction: String, Equatable { case send = "Send", steer = "Steer", queue = "Queue" }
enum NativeComposerCompletion { case accepted, failed(String), outcomeUnknown(String) }
enum NativeComposerLayout { case fullBar, growing }

/// A Focused / Split capsule segment (product FocusedSegmentControls): attach, editor, model and send only. Its index
/// picks the ends: the first segment starts after me (the host's leading inset), the others after their divider; from
/// the second on, the end slot holds the conversation's identity orb.
struct NativeComposerSegment: Equatable { var index: Int; var isLast: Bool }

/// Value snapshot: later edits to access, model, effort, tier or attachments cannot change this request.
@MainActor struct NativeComposerSubmission {
    let id: UUID
    let identity: String?
    let action: NativeComposerAction
    let text: String
    let attachments: [Attachment]
    let settings: ModelSettings
    let access: Access
    let waitingForTurnID: String?
}

struct NativeComposerSendShortcut: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode == 76 ? 36 : keyCode
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift])
    }
    static let `return` = Self(keyCode: 36, modifiers: [])
    static let commandReturn = Self(keyCode: 36, modifiers: .command)
    func matches(_ event: NSEvent) -> Bool {
        let code = event.keyCode == 76 ? 36 : event.keyCode
        return code == keyCode && event.modifierFlags.intersection([.command, .control, .option, .shift]) == modifiers
    }
}
