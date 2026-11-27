import Foundation

/// On-demand, read-only projection. Its owner calls open/refresh; animation never calls project.
@MainActor final class FunctionPanelProjection {
    let store: ConversationStore
    private var keys: [FunctionPanelPage: String] = [:]
    private var target: ObjectIdentifier?
    private var sourceID: String?
    private var covers: FunctionPanelValue<[FunctionPanelCover]> = .unloaded
    private var files: FunctionPanelValue<[FunctionPanelFile]> = .unloaded
    private var tasks: FunctionPanelValue<[FunctionPanelTask]> = .unloaded
    private var outputs: FunctionPanelValue<[FunctionPanelOutput]> = .unloaded
    private var last: FunctionPanelProjectionSnapshot?
    private var lastKey: String?
    private(set) var builds = 0
    private(set) var itemVisits = 0
    private(set) var artifactReads = 0
    init(store: ConversationStore) { self.store = store }

    func project(_ c: Conversation, page: FunctionPanelPage, sources: FunctionPanelReadSources,
                 bodies: [FunctionPanelBodyOption], artifactKey: String = "") -> FunctionPanelProjectionSnapshot {
        if target != ObjectIdentifier(c) || sourceID != sources.id {
            target = ObjectIdentifier(c); sourceID = sources.id; keys = [:]; last = nil; lastKey = nil
            covers = .unloaded; files = .unloaded; tasks = .unloaded; outputs = .unloaded
        }
        let childKey = c.satellites.map { satellite in
            satellite.threadID.flatMap { store.conversation($0) }.map {
                "\($0.id):\($0.revision)" } ?? satellite.id + ":missing"
        }.joined(separator: "|")
        let key = "\(c.revision):\(sources.id):\(sources.revision):\(artifactKey):\(childKey)"
        if keys[page] == key && lastKey == key, let last { return last }
        keys[page] = key; lastKey = key; builds += 1
        func availability<T: Equatable & Sendable>(_ known: @autoclosure () -> T) -> FunctionPanelValue<T> {
            if !sources.connected { return .failed("Disconnected") }
            if let error = sources.historyError { return .failed(error) }
            if !c.historyLoaded, !c.loading, let error = c.operationError { return .failed(error) }
            if !c.historyLoaded && c.loading { return .loading }
            if !c.historyLoaded { return .unloaded }
            return .known(known())
        }
        let loaded = sources.connected && sources.historyError == nil && c.historyLoaded
        var context: FunctionPanelValue<Double> = .unavailable
        var contextText = "Not provided"
        var contextLines: [String]?
        // Token provenance is independent of history, connectivity and the latest operation result.
        if let used = c.exactTokensUsed, used >= 0 {
            if let limit = c.contextLimit, limit > 0 {
                context = .known(Double(used) / Double(limit))
                contextText = "\(Int((Double(used) / Double(limit) * 100).rounded()))%"
            } else {
                contextText = "\(used) tokens · Limit not provided"
                contextLines = ["\(used) tokens", "Limit not provided"]
            }
        }
        let bridge = conversationPhaseEvent(c)
        let phase: FunctionPanelValue<FunctionPanelLivePhase>
        if !sources.connected { phase = .failed("Disconnected") }
        else if let turn = c.phaseFacts.turnID, !turn.isEmpty { phase = .known(.init(event: bridge, turnID: turn)) }
        else { phase = .unavailable }
        let phaseText = phase.value.map { $0.event.value.state == .unknown ? "Phase unknown" : $0.event.value.state
            .rawValue.capitalized } ?? "Phase · " + phase.status

        let agents: FunctionPanelValue<[FunctionPanelSubagent]> = availability(c.satellites.map { satellite in
            let child = satellite.threadID.flatMap { store.conversation($0) }
            let rows = child?.items ?? satellite.items
            itemVisits += rows.count
            return FunctionPanelSubagent(id: satellite.id, name: child?.title ?? satellite.title ?? satellite.id,
                status: child?.status ?? "Child not provided", elapsed: .unavailable,
                lines: rows.suffix(5).map(\.text), canStop: false)
        })
        func completeDiff(_ change: FileChange) -> Bool {
            guard let thread = c.backendThreadID, !thread.isEmpty, let proof = sources.fileEvidence[change.path] else {
                return false }
            return proof.threadID == thread && proof.complete && proof.reportedLines == change.lines.map(\.text) &&
                !change.lines.contains { $0.text.localizedCaseInsensitiveContains("[truncated]") }
        }
        if page == .files {
            files = availability(c.changes.map { change in
                let complete = completeDiff(change)
                return FunctionPanelFile(id: change.path, path: change.path,
                    additions: complete ? .known(change.added) : .unavailable,
                    removals: complete ? .known(change.removed) : .unavailable,
                    provenance: complete ?
                        "Files / Changes · Reported diff" : "Files / Changes · Origin or completeness not provided",
                    lines: change.lines.map(\.text))
            })
            // changes has no loaded-empty marker; its initial [] cannot prove an empty read.
            if files.value?.isEmpty == true { files = .unavailable }
        }
        if page == .background {
            tasks = availability(c.items.filter { itemVisits += 1; return $0.rowKind == .tool(.command) }.map { row in
                let parts = row.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                return FunctionPanelTask(id: row.id, command: String(parts.first ?? ""),
                    status: row.running ? "Running" : row.status ?? "Status not provided", progress: .unavailable,
                    elapsed: .unavailable, log: parts.count > 1 ? String(parts[1]) : "", action: nil)
            })
        }
        if page == .library || page == .outputs {
            artifactReads += 1
            func belongs(_ artifact: CoreArtifact) -> Bool {
                guard let thread = c.backendThreadID, !thread.isEmpty, !artifact.id.isEmpty else { return false }
                guard artifact.threadID == nil || artifact.threadID == thread else { return false }
                return artifact.threadID == thread || sources.artifactThreads[artifact.id] == thread
            }
            func metadata(_ artifact: CoreArtifact) -> FunctionPanelValue<String> {
                guard let bytes = artifact.raw["bytes"]?.intValue, bytes >= 0 else { return .unavailable }
                return .known("\(bytes) B · " + (artifact.raw["mimeType"]?.stringValue ?? "Type not provided"))
            }
            switch sources.artifacts {
            case .known(let values):
                let owned = values.filter(belongs)
                if page == .library {
                    covers = .known(owned.map { a in .init(id: a.id, name: a.name,
                        kind: a.mime.hasPrefix("image/") ? .image : a.mime == "application/pdf" ? .pdf : .artifact,
                        metadata: metadata(a), step: "Preview not provided", lyric: a.name, colour: 0x303630) })
                } else {
                    outputs = .known(owned.filter { sources.outputArtifactIDs.contains(
                                $0.id) || $0.generatedItemID?.isEmpty == false }.map { a in
                        .init(id: a.id, name: a.name, metadata: metadata(a), content: "Content not loaded",
                            colour: 0x303630)
                    } + c.changes.filter(completeDiff).map { change in
                        .init(id: "diff:" + change.path, name: change.path, metadata: .known("Reported diff"),
                              content: change.lines.map(\.text).joined(separator: "\n"), colour: 0x303630)
                    })
                }
            case .unloaded: if page == .library { covers = .unloaded } else { outputs = .unloaded }
            case .loading: if page == .library { covers = .loading } else { outputs = .loading }
            case .unavailable: if page == .library { covers = .unavailable } else { outputs = .unavailable }
            case .failed(let message): if page == .library { covers = .failed(message) } else {
                outputs = .failed(message) }
            }
            if !sources.connected { if page == .library { covers = .failed("Disconnected") } else {
                    outputs = .failed("Disconnected") } }
        }
        let goal = loaded ? c.items.last(where: { $0.rowKind == .user })?.text ?? "" : ""
        itemVisits += loaded ? c.items.count : 0
        let status = sources.connected ? c.status : "Disconnected"
        let model = sources.connected ? sources.model : .failed("Disconnected")
        let compact: FunctionPanelValue<String> = loaded && c.compactions > 0 ? .known(
            "\(c.compactions) reported compaction events") : .unavailable
        let identity = c.identitySymbol ?? (
            c.identityIndex >= ConversationBodyIdentity.allocationBase ? ConversationBodyIdentity.allocated(
                c.identityIndex).symbol : ConversationIdentity.assigned(c.identityIndex).symbol)
        var input = FunctionPanelInput(id: c.id, title: c.title, goal: goal, status: status, model: model,
            context: context, worked: .unavailable, compactHistory: compact, bodyID: identity,
            bodies: bodies, colours: [], subagents: agents, covers: covers, files: files, tasks: tasks,
                outputs: outputs)
        var semantics: [String] = [c.title, goal, status, model.text { $0 }, contextText, phaseText, covers.status,
            files.status, tasks.status, outputs.status]
        semantics += (agents.value ?? []).flatMap { [$0.name, $0.status] + $0.lines }
        semantics += (covers.value ?? []).flatMap { [$0.name, $0.metadata.text { $0 }] }
        semantics += (files.value ?? []).flatMap { [$0.path, $0.provenance] + $0.lines }
        semantics += (tasks.value ?? []).flatMap { [$0.command, $0.log, $0.status] }
        semantics += (outputs.value ?? []).flatMap { [$0.name, $0.content] }
        if let error = c.operationError { semantics += ["State · Conversation error", error] }
        input.live = .init(contextText: contextText, contextLines: contextLines ?? [contextText], phaseText: phaseText,
            filesTitle: "Files / Changes",
                           capabilities: "", semanticText: semantics, conversationError: c.operationError)
        let result = FunctionPanelProjectionSnapshot(input: input, phase: phase)
        last = result; return result
    }
}
