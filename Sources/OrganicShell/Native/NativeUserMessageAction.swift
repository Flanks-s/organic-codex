import Foundation

/// Value request for a host/runtime. Fork preserves this prefix and stages message as an UNSENT draft.
/// It never edits the source conversation, creates a backend thread or sends on the host's behalf.
struct NativeUserMessageAction:Equatable,Sendable {
    enum Kind:Equatable,Sendable {case edit,fork}
    var kind:Kind,conversationID:String,message:TranscriptItem,historyBefore:[TranscriptItem]
    var draftText:String{message.text}
}
struct NativeElicitationExchange:Equatable,Sendable {
    var request:Approval
    var response:JSONValue
}
