import Foundation

enum ApprovalAction: Sendable { case accept, decline, cancel }

struct UserInputRequest: Identifiable, Equatable, Sendable {
    struct Question: Identifiable, Equatable, Sendable {
        struct Option: Equatable, Sendable { var label: String; var description: String }
        var id: String
        var header: String
        var prompt: String
        var options: [Option]
        var isSecret = false
    }
    var id: String
    var questions: [Question]
    var submitting = false
}

