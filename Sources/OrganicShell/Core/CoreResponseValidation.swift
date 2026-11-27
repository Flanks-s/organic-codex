import Foundation

/// Validates the JSON-schema subset accepted by Core's elicitation forms, independently of the UI.
/// Unknown constraints fail closed rather than submitting an apparently validated value.
enum CoreResponseValidation {
    static func schema(_ value: JSONValue, against schema: JSONValue, path: String = "content") -> String? {
        CoreElicitationSchema.error(value, schema: schema, path: path)
    }
    static func approval(_ response: JSONValue, request: Approval) -> String? {
        if request.method == "elicitation/create" {
            guard let action = response["action"]?.stringValue, ["accept", "decline", "cancel"].contains(action) else { return "Choose accept, decline or cancel." }
            if action == "accept" {
                guard let content = response["content"] else { return "The form is missing its content." }
                return schema(content, against: request.request["params"]?["requestedSchema"] ?? ["type": "object"])
            }
        } else if request.method == "item/permissions/requestApproval" {
            guard response["permissions"]?.objectValue != nil, ["turn", "session"].contains(response["scope"]?.stringValue ?? "") else { return "Permissions and their scope are required." }
        } else if request.method.contains("requestApproval") {
            guard let decision = response["decision"] else { return "An approval decision is required." }
            let choices = request.request["params"]?["availableDecisions"]?.arrayValue ?? ["accept", "decline", "cancel"]
            guard choices.contains(decision) else { return "The selected decision was not offered by Core." }
        } else { return "Unsupported approval response; nothing was sent." }
        return nil
    }
    static func answers(_ values: [String: [String]], request: UserInputRequest) -> String? {
        guard !request.questions.isEmpty, Set(values.keys).isSubset(of: Set(request.questions.map(\.id))) else {
            return "Use the original question IDs."
        }
        for answer in values.values {
            guard !answer.isEmpty, answer.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { return "Every supplied answer must be nonempty." }
        }
        return nil
    }
}
