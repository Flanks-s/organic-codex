import Foundation

/// Presentation facts only. Unknown values never acquire numeric defaults.
enum FunctionPanelValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case unloaded, loading, known(Value), unavailable, failed(String)

    var value: Value? { if case .known(let value) = self { return value }; return nil }
    var status: String {
        switch self {
        case .unloaded: "Not loaded"
        case .loading: "Loading…"
        case .known: "Known"
        case .unavailable: "Not provided"
        case .failed(let message): "Couldn’t load · " + message
        }
    }
    func text(_ format: (Value) -> String) -> String { value.map(format) ?? status }
}

enum FunctionPanelPage: String, CaseIterable, Sendable {
    case overview = "Overview", library = "Library", files = "Files"
    case background = "Background", outputs = "Outputs"
    static var navigation: [Self] { allCases }
    var symbol: String {
        switch self {
        case .overview: "circle.hexagongrid"
        case .library: "photo.on.rectangle"
        case .files: "doc.text"
        case .background: "terminal"
        case .outputs: "square.and.arrow.up"
        }
    }
    var expandedWidth: Double {
        switch self {
        case .overview: 108
        case .library, .outputs: 92
        case .files: 76
        case .background: 120
        }
    }
}

struct FunctionPanelBodyOption: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct FunctionPanelColour: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let bodyName: String
    let hex: UInt32
}

struct FunctionPanelSubagent: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let status: String
    let elapsed: FunctionPanelValue<String>
    let lines: [String]
    let canStop: Bool
}

struct FunctionPanelCover: Equatable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case image = "Images", pdf = "PDFs", artifact = "Artifacts" }
    let id: String
    let name: String
    let kind: Kind
    let metadata: FunctionPanelValue<String>
    let step: String
    let lyric: String
    let colour: UInt32
}

struct FunctionPanelFile: Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let additions: FunctionPanelValue<Int>
    let removals: FunctionPanelValue<Int>
    let provenance: String
    let lines: [String]
}

struct FunctionPanelTask: Equatable, Identifiable, Sendable {
    let id: String
    let command: String
    let status: String
    let progress: FunctionPanelValue<Double>
    let elapsed: FunctionPanelValue<String>
    let log: String
    let action: String?
}

struct FunctionPanelOutput: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let metadata: FunctionPanelValue<String>
    let content: String
    let colour: UInt32
}

struct FunctionPanelMaterials: Equatable, Sendable {
    var previews: [String: FunctionPanelValue<FunctionPanelArtifactPreview>]
    var openIDs: Set<String> = []
    var fileIDs: Set<String> = []
    var copyIDs: Set<String> = []
}

/// Every field is a value snapshot; no Conversation, runtime, store or resource singleton is retained.
struct FunctionPanelInput: Equatable, Sendable {
    var materials: FunctionPanelMaterials? = nil
    var live: FunctionPanelLivePresentation? = nil
    var commands: FunctionPanelCommandPresentation? = nil
    let id: String
    let title: String
    let goal: String
    let status: String
    let model: FunctionPanelValue<String>
    let context: FunctionPanelValue<Double>
    let worked: FunctionPanelValue<String>
    let compactHistory: FunctionPanelValue<String>
    let bodyID: String
    let bodies: [FunctionPanelBodyOption]
    let colours: [FunctionPanelColour]
    let subagents: FunctionPanelValue<[FunctionPanelSubagent]>
    let covers: FunctionPanelValue<[FunctionPanelCover]>
    let files: FunctionPanelValue<[FunctionPanelFile]>
    let tasks: FunctionPanelValue<[FunctionPanelTask]>
    let outputs: FunctionPanelValue<[FunctionPanelOutput]>
}

enum FunctionPanelAction: Equatable, Sendable {
    case rename(String), body(String), colour(String), notifications(String), pin(Bool)
    case archive, undoArchive, compact, fork, export, stop, model
    case openSubagent(String), stopSubagent(String)
    case openCover(String), copyCover(String), openFile(String)
    case task(String, String), openOutput(String), copyOutput(String), closed
}

/// Mutable interaction state is local to one view; identity is always a stable ID.
struct FunctionPanelState {
    var isOpen = false
    var page: FunctionPanelPage = .overview
    var hoveredPage: FunctionPanelPage?
    var option: Int?
    var hoveredOption: String?
    var bodyID: String
    var colourID: String
    var notification = "All"
    var dockPinned = false
    var archived = false
    var title: String
    var originalTitle: String
    var editingTitle = false
    var focusID: String?
    var bodyScroll = 0
    var colourScroll = 0
    var hoveredSubagent: String?
    var pinnedSubagent: String?
    var showsAllSubagents = false
    var subagentOffset = 0
    var historyOffsets: [String: Int] = [:]
    var coverID: String?
    var libraryOffset = 0
    var filter: FunctionPanelCover.Kind?
    var fileID: String?
    var taskID: String?
    var fanTasks = false
    var outputID: String?
    var pendingHover: (id: String?, deadline: Double)?

    init(_ input: FunctionPanelInput) {
        bodyID = input.bodyID
        colourID = input.colours.first?.id ?? ""
        title = input.title; originalTitle = input.title
        fileID = input.files.value?.last?.id
        outputID = input.outputs.value?.first?.id
    }
    var expandedSubagent: String? { hoveredSubagent ?? pinnedSubagent }
    mutating func reconcile(_ input: FunctionPanelInput) {
        let agents = input.subagents.value ?? []
        if let pinnedSubagent, !agents.contains(where: { $0.id == pinnedSubagent }) { self.pinnedSubagent = nil }
        if let hoveredSubagent, !agents.contains(where: { $0.id == hoveredSubagent }) { self.hoveredSubagent = nil }
        if let coverID, !(input.covers.value ?? []).contains(where: { $0.id == coverID }) { self.coverID = nil }
        if let fileID, !(input.files.value ?? []).contains(where: { $0.id == fileID }) {
            self.fileID = input.files.value?.last?.id }
        if let outputID, !(input.outputs.value ?? []).contains(where: { $0.id == outputID }) {
            self.outputID = input.outputs.value?.first?.id }
        bodyScroll = min(max(0, bodyScroll), max(0, input.bodies.count - 8))
        subagentOffset = min(max(0, subagentOffset), max(0, agents.count - 3))
        if agents.count <= 3 { showsAllSubagents = false }
        historyOffsets = historyOffsets.filter { key, _ in agents.contains { $0.id == key } }
    }
}
