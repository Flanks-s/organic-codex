import Foundation

/// Read provenance is explicit. These values never acquire authority from UI defaults.
struct FunctionPanelLivePresentation: Equatable, Sendable {
    let contextText: String
    let contextLines: [String]
    let phaseText: String
    let filesTitle: String
    let capabilities: String
    let semanticText: [String]
    var conversationError: String? = nil
}

struct FunctionPanelLivePhase: Equatable, Sendable {
    let event: BodyPhaseEvent
    let turnID: String
}

struct FunctionPanelFileEvidence: Equatable, Sendable {
    let threadID: String
    let complete: Bool
    let reportedLines: [String]
}

/// Supplied by the owning read repository, not discovered through Runtime or Tools.shared.
struct FunctionPanelReadSources: Equatable, Sendable {
    let id: String
    var revision: Int
    var connected = true
    var artifacts: FunctionPanelValue<[CoreArtifact]> = .unloaded
    var model: FunctionPanelValue<String> = .unloaded
    var artifactThreads: [String: String] = [:]
    var outputArtifactIDs: Set<String> = []
    var fileEvidence: [String: FunctionPanelFileEvidence] = [:]
    /// An explicit history repository read failure, distinct from a conversation operation error.
    var historyError: String? = nil
}

struct FunctionPanelProjectionSnapshot {
    let input: FunctionPanelInput
    let phase: FunctionPanelValue<FunctionPanelLivePhase>
}
