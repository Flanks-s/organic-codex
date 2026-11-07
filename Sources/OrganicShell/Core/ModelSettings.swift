import Foundation

/// Models, reasoning levels and speeds, as in the Canopy prototype (Prototype.dc.html, 2026-10-22).
/// Names come from the user's Codex model list; levels per model are placeholders until a host reports them.
enum ModelCatalog {
    struct Model: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let version: String
        let efforts: [Effort]
        var serviceTiers: [String] = []
        var cyberPrograms: [String]? = nil
        var reportedByCore = false
        var wireModel: String? = nil
        var defaultEffortValue: Effort? = nil
        /// Exact model/list value for distinguishing absent capability fields from reported empty lists.
        var rawCapabilities: JSONValue? = nil
        var full: String { version.isEmpty ? name : "GPT-\(version) \(name)" }
        var major: Substring { version.split(separator: ".").first ?? "" }
        var availableSpeeds: [Speed] {
            guard reportedByCore else { return Speed.allCases }
            var result: [Speed] = [.standard]
            if serviceTiers.contains("priority") || serviceTiers.contains("fast") { result.append(.fast) }
            if serviceTiers.contains("ultrafast") { result.append(.ultrafast) }
            return result
        }
    }

    /// Fixed order, oldest to newest; the picker's lyrics follow it top to bottom.
    @MainActor static var models: [Model] = mockModels
    /// model/list as Core reports it (LiveConversationRuntime.load).
    static func coreModels(_ values: [JSONValue]) -> [Model] {
        values.compactMap { value in
            guard let id = value["id"]?.stringValue ?? value["model"]?.stringValue else { return nil }
            let efforts = (value["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
                Effort(rawValue: $0["reasoningEffort"]?.stringValue ?? $0.stringValue ?? "")
            }
            return .init(id: id, name: value["displayName"]?.stringValue ?? id, version: "", efforts: efforts,
                         serviceTiers: (value["serviceTiers"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue ?? $0.stringValue },
                         cyberPrograms: value["availableAccessPrograms"]?["cyber"]?.arrayValue?.compactMap(\.stringValue),
                         reportedByCore: true, wireModel: value["model"]?.stringValue, defaultEffortValue: Effort(rawValue: value["defaultReasoningEffort"]?.stringValue ?? ""), rawCapabilities: value)
        }
    }
    static let mockModels: [Model] = [
        Model(id: "g56luna", name: "Luna", version: "5.6", efforts: [.low, .medium, .high]),
        Model(id: "g56terra", name: "Terra", version: "5.6", efforts: [.low, .medium, .high, .xhigh]),
        Model(id: "g56sol", name: "Sol", version: "5.6", efforts: [.low, .medium, .high, .xhigh]),
        Model(id: "g6luna", name: "Luna", version: "6", efforts: [.low, .medium, .high]),
        Model(id: "g6sol", name: "Sol", version: "6", efforts: [.low, .medium, .high, .xhigh]),
        Model(id: "g61sol", name: "Sol", version: "6.1", efforts: [.low, .medium, .high, .xhigh, .ultra]),
        Model(id: "g6astra", name: "Astra", version: "6", efforts: [.medium, .high, .xhigh, .ultra]),
    ]
    /// Daybreak runs on a limited set of models.
    static let daybreakModels: Set<String> = ["g56terra", "g6sol", "g6luna"]

    @MainActor static func model(_ id: String) -> Model {
        models.first { $0.id == id } ?? Model(id: id, name: id.isEmpty ? "Choose a model" : id, version: "", efforts: [], reportedByCore: true)
    }

    /// The level a model starts at when nothing is remembered: High if it has it, otherwise its top level.
    static func defaultEffort(_ m: Model, wanted: Effort? = nil) -> Effort {
        if let wanted, m.efforts.contains(wanted) { return wanted }
        return m.defaultEffortValue ?? (m.efforts.contains(.high) ? .high : m.efforts.last ?? (m.reportedByCore ? .none : .high))
    }
}

enum Effort: String, CaseIterable, Sendable {
    case none, minimal, low, medium, high, xhigh, max, ultra
    var label: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .max: "Max"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .ultra: "Ultra"
        }
    }
}

enum Speed: Int, CaseIterable, Sendable {
    case standard = 1, fast, ultrafast
    var label: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Fast"
        case .ultrafast: "Ultrafast"
        }
    }
}

/// Model, reasoning, speed and Daybreak for a message. A conversation keeps the settings its last message used
/// and the settings for the next one; they differ when the user changed something (the pending dot).
@MainActor struct ModelSettings: Equatable, Sendable {
    var modelID = "g61sol"
    var effort: Effort = .high
    var speed: Speed = .standard
    var daybreak = false
    /// The level each model was last used with, so switching back restores it.
    var memory: [String: Effort] = [:]

    var model: ModelCatalog.Model { ModelCatalog.model(modelID) }
    var label: String {
        if model.reportedByCore && model.efforts.isEmpty {
            return model.full + (model.rawCapabilities?["supportedReasoningEfforts"]?.arrayValue != nil ? " · No adjustable reasoning" : " · Reasoning not reported")
        }
        return "\(model.full) · \(effort.label)"
    }

    /// Called only by the pending-settings editor; queued/running snapshots remain unchanged.
    mutating func normalizeSpeed(for availableModel: ModelCatalog.Model? = nil) -> String? {
        guard !(availableModel ?? model).availableSpeeds.contains(speed) else { return nil }
        let previous = speed.label
        speed = .standard
        return "\(previous) is not available for this model. Using Standard."
    }

    func remembered(_ m: ModelCatalog.Model) -> Effort { ModelCatalog.defaultEffort(m, wanted: memory[m.id]) }
    func available(_ m: ModelCatalog.Model) -> Bool { !daybreak || (m.reportedByCore ? (m.cyberPrograms ?? []).contains("daybreakBlue") : ModelCatalog.daybreakModels.contains(m.id)) }

    mutating func pick(_ id: String) {
        let m = ModelCatalog.model(id)
        guard available(m), id != modelID else { return }
        memory[modelID] = effort
        modelID = id
        effort = remembered(m)
    }
    mutating func step(_ delta: Int) {
        let usable = ModelCatalog.models.filter(available)
        guard let i = usable.firstIndex(where: { $0.id == modelID }) else { return }
        let j = min(max(0, i + delta), usable.count - 1)
        pick(usable[j].id)
    }
    /// Daybreak on moves an unsupported model to GPT-6 Sol and says so.
    mutating func toggleDaybreak() -> String? {
        daybreak.toggle()
        guard daybreak, !available(model) else { return nil }
        let from = model.full
        memory[modelID] = effort
        guard let compatible = ModelCatalog.models.first(where: available) else {
            daybreak = false
            return "Daybreak is not available for this account’s models"
        }
        modelID = compatible.id
        effort = remembered(model)
        return "Daybreak · switched from \(from)"
    }
}

/// A file attached to the next message (mock: sample names, as in the prototype).
struct Attachment: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var symbol: String
    var url: URL? = nil
    var input: JSONValue? = nil
    var mimeType: String? = nil
    var persistedInputPath: String? = nil
    static let samples = [("sidebar-spacing.png", "photo"), ("design-notes.md", "doc.text"), ("crash-2026-10-21.log", "doc")]
}

/// While a reply runs, a new message either joins it (steer) or waits for it to finish (queue).
enum FollowUp: String, Sendable { case steer, queue }

@MainActor struct QueuedMessage: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var attachments: [Attachment] = []
    var settings: ModelSettings = ModelSettings()
    var access: Access = .auto
    var waitingForTurnID: String? = nil
    var deliveryError: String? = nil
}
