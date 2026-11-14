import Foundation

/// Applies Core's concrete notifications to the native observable objects. No view or window is recreated.
@MainActor enum EventReducer {
    static func upsert(_ item: JSONValue, turnID: String, in c: Conversation, completed: Bool = false, time: Double? = nil) {
        guard let id = item["id"]?.stringValue else { return }
        let type = item["type"]?.stringValue ?? "unknown"
        let kind: RowKind
        switch type {
        case "userMessage": kind = .user
        case "agentMessage": kind = .assistant
        case "reasoning": kind = .reasoning
        case "commandExecution": kind = .tool(.command)
        case "fileChange": kind = .tool(.fileChange)
        case "webSearch": kind = .tool(.webSearch)
        case "contextCompaction": kind = .notice(.info)
        case "notice":
            kind = .notice(item["noticeKind"]?.stringValue == "error" ? .error : item["noticeKind"]?.stringValue == "warning" ? .warning : .info)
        default: kind = .tool(.toolCall)
        }
        let content = item["content"]?.arrayValue ?? []
        var text = item["text"]?.stringValue ?? content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        if type == "reasoning" {
            text = item["text"]?.stringValue ?? (item["summary"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["text"]?.stringValue }.joined(separator: "\n")
            if text.isEmpty { text = content.compactMap { $0.stringValue ?? $0["text"]?.stringValue }.joined(separator: "\n") }
        }
        if type == "contextCompaction" { text = "Context compacted" }
        if type == "dynamicToolCall" || type == "mcpToolCall" {
            let tool = [item["namespace"]?.stringValue ?? item["server"]?.stringValue, item["tool"]?.stringValue].compactMap { $0 }.joined(separator: ".")
            let values = item["contentItems"]?.arrayValue ?? item["result"]?["content"]?.arrayValue ?? []
            let output = values.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            text = tool + (output.isEmpty ? "" : "\n" + output)
        }
        if type == "commandExecution" {
            text = item["command"]?.stringValue ?? ""
            if let output = item["aggregatedOutput"]?.stringValue, !output.isEmpty { text += "\n" + output }
        }
        if type == "fileChange", item["changes"]?.arrayValue != nil {
            let changes = item["changes"]?.arrayValue ?? []
            text = changes.map { value in
                let path = value["path"]?.stringValue ?? "File"
                let diff = value["diff"]?.stringValue ?? ""
                let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                let file = FileChange(path: path, added: added, removed: removed, lines: lines.map {
                    FileChange.Line(kind: $0.hasPrefix("+") && !$0.hasPrefix("+++") ? .added : $0.hasPrefix("-") && !$0.hasPrefix("---") ? .removed : .context, text: $0)
                })
                if let i = c.changes.firstIndex(where: { $0.path == path }) { c.changes[i] = file } else { c.changes.append(file) }
                return "\(path)  +\(added) −\(removed)"
            }.joined(separator: "\n")
        }
        if text.isEmpty && kind == .tool(.toolCall) { text = item["tool"]?.stringValue ?? type }
        let rawStatus = item["status"]?.stringValue
        let status: String? = ["failed", "declined", "cancelled", "interrupted", "waiting", "changes", "changes-reverted"].contains(rawStatus ?? "") ? rawStatus : completed || rawStatus == "completed" ? nil : rawStatus == "inProgress" ? "running" : rawStatus ?? (kind == .user ? nil : "running")
        let row = TranscriptItem(id: id, turnID: turnID, kind: kind, text: text, status: status, timestamp: time.map(Date.init(timeIntervalSince1970:)))
        if let i = c.transcriptItemIndex(id) {
            var updated = row
            // An item/started replay must never erase text restored from thread/read.
            if !completed && updated.text.isEmpty && !c.items[i].text.isEmpty { updated.text = c.items[i].text }
            updated.revision = c.items[i].revision
            updated.timestamp = c.items[i].timestamp ?? updated.timestamp
            if updated != c.items[i] { updated.revision += 1; c.items[i] = updated }
        } else { c.items.append(row) }
        if type == "contextCompaction" { c.compactions = c.items.filter { $0.rowKind == .notice(.info) && $0.text == "Context compacted" }.count }
        if type == "collabAgentToolCall" {
            for thread in item["receiverThreadIds"]?.arrayValue ?? [] {
                guard let threadID = thread.stringValue else { continue }
                let state = item["agentsStates"]?[threadID]
                let done = ["completed", "errored", "shutdown", "notFound"].contains(state?["status"]?.stringValue ?? "")
                if let i = c.satellites.firstIndex(where: { $0.threadID == threadID }) {
                    if done && !c.satellites[i].done { c.satellites[i].finishedOrder = c.satellites.compactMap(\.finishedOrder).max().map { $0 + 1 } ?? 0 }
                    c.satellites[i].done = done
                } else {
                    c.satellites.append(Satellite(id: threadID, face: done ? "-_-" : "•ᴗ•", done: done, threadID: threadID, title: item["prompt"]?.stringValue))
                }
            }
        }
    }

    static func hydrate(_ thread: JSONValue, into c: Conversation, phaseEvent: CoreEvent? = nil) {
        c.running = false; c.activeTurnID = nil
        if let name = thread["name"]?.stringValue, !name.isEmpty { c.title = name }
        c.cwd = thread["cwd"]?.stringValue ?? c.cwd
        c.archived = thread["archived"]?.boolValue ?? c.archived
        for turn in thread["turns"]?.arrayValue ?? [] {
            guard let id = turn["id"]?.stringValue else { continue }
            let running = turn["status"]?.stringValue == "inProgress"
            c.satellites = []; c.satellitesRetired = !running
            for item in turn["items"]?.arrayValue ?? [] {
                upsert(item, turnID: id, in: c, completed: !running || item["status"]?.stringValue == "completed", time: turn["startedAt"]?.doubleValue)
            }
            if running { c.activeTurnID = id; c.running = true }
        }
        // A live notification can arrive before the first read, so insertion order is
        // not chronology. The official snapshot establishes turn and item order.
        let turns = thread["turns"]?.arrayValue ?? []
        let turnOrder = turns.compactMap { $0["id"]?.stringValue }
        let grouped = Dictionary(grouping: c.items, by: \.turnID)
        var ordered: [TranscriptItem] = []
        for turn in turns {
            guard let id = turn["id"]?.stringValue else { continue }
            let rows = grouped[id] ?? []
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let itemIDs = (turn["items"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            let known = Set(itemIDs)
            ordered += itemIDs.compactMap { byID[$0] }
            ordered += rows.filter { !known.contains($0.id) }
        }
        let knownTurns = Set(turnOrder)
        ordered += c.items.filter { !knownTurns.contains($0.turnID) }
        c.items = ordered
        c.historyLoaded = true
        let recovered = turns.first { $0["id"]?.stringValue == c.activeTurnID } ?? turns.last { ["completed","failed","interrupted"].contains($0["status"]?.stringValue ?? "") }
        c.notices.restore(in: c, started: recovered?["startedAt"]?.doubleValue, ended: recovered?["completedAt"]?.doubleValue,
                          confirmedTurn: recovered?["id"]?.stringValue, status: recovered?["status"]?.stringValue)
        c.phaseFacts.restore(thread,in:c,eventID:phaseEvent?.id)
    }

    static func approval(_ p: JSONValue, in c: Conversation) {
        guard let id = p["approvalId"]?.stringValue, let request = p["request"] else { return }
        let submitting = c.approvals.first(where: { $0.id == id })?.submitting == true || (c.userInput?.id == id && c.userInput?.submitting == true)
        let method = request["method"]?.stringValue ?? "Approval"
        let params = request["params"] ?? .object([:])
        if method == "item/tool/requestUserInput" {
            let questions = (params["questions"]?.arrayValue ?? []).compactMap { value -> UserInputRequest.Question? in
                guard let id = value["id"]?.stringValue else { return nil }
                return .init(id: id, header: value["header"]?.stringValue ?? "", prompt: value["question"]?.stringValue ?? "",
                             options: (value["options"]?.arrayValue ?? []).map { .init(label: $0["label"]?.stringValue ?? "", description: $0["description"]?.stringValue ?? "") },
                             isSecret: value["isSecret"]?.boolValue ?? false)
            }
            c.userInput = .init(id: id, questions: questions)
            c.userInput?.submitting = submitting
            c.question = questions.map(\.prompt).joined(separator: "\n")
            return
        }
        let title = method == "elicitation/create" ? "Allow this tool request?" : method.contains("fileChange") ? "Apply these changes?" : "Allow this request?"
        var command = params["command"]?.stringValue ?? params["message"]?.stringValue ?? params["reason"]?.stringValue ?? method
        if method == "item/permissions/requestApproval", let permissions = params["permissions"], let data = try? JSONEncoder().encode(permissions) {
            command += "\n" + String(decoding: data, as: UTF8.self)
        }
        var a = Approval(id: id, title: p["title"]?.stringValue ?? title, command: command, note: params["reason"]?.stringValue ?? "", acceptLabel: p["acceptLabel"]?.stringValue ?? "Allow", toolItemID: params["itemId"]?.stringValue ?? "", method: method, request: request, source: p["source"]?.stringValue ?? "")
        a.submitting = submitting
        if let i = c.approvals.firstIndex(where: { $0.id == id }) { c.approvals[i] = a } else { c.approvals.append(a) }
    }

    /// One classifier for mock store.apply and the live runtime, after its replay/watermark gates.
    /// Applying history directly keeps the old Void API and is published structurally by its owner.
    static func applyReportingChange(_ event: CoreEvent, to c: Conversation) -> ConversationChange {
        defer { c.notices.consume(event, in: c); c.orbActivity.consume(event, in: c) }
        let p = event.params
        let deltas: Set<String> = ["item/agentMessage/delta", "item/reasoning/summaryTextDelta",
            "item/reasoning/textDelta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta"]
        if deltas.contains(event.method), let id = p["itemId"]?.stringValue, !id.isEmpty, p["delta"]?.stringValue != nil {
            let existed = c.transcriptItemIndex(id) != nil
            apply(event, to: c)
            return existed ? .itemAppended(itemID: id) : .itemChanged(itemID: id)
        }
        if ["item/started", "item/completed"].contains(event.method), let id = p["item"]?["id"]?.stringValue, !id.isEmpty {
            let previous = c.transcriptItemIndex(id).map { c.items[$0] }
            apply(event, to: c)
            guard let index = c.transcriptItemIndex(id) else { return .structural }
            let current = c.items[index]
            if let previous, previous.rowKind != current.rowKind || previous.turnID != current.turnID { return .structural }
            // Review rows can depend on the shared file diff, so this is a multi-row mutation.
            if p["item"]?["type"]?.stringValue == "fileChange", p["item"]?["changes"]?.arrayValue != nil { return .structural }
            return .itemChanged(itemID: id)
        }
        apply(event, to: c)
        return .structural
    }

    static func apply(_ event: CoreEvent, to c: Conversation) {
        defer {c.phaseFacts.consume(event,in:c)}
        let p = event.params
        let turnID = p["turnId"]?.stringValue ?? p["turn"]?["id"]?.stringValue ?? c.activeTurnID ?? ""
        switch event.method {
        case "thread/started", "thread/restored":
            if let thread = p["thread"] {
                hydrate(thread, into: c, phaseEvent:event)
                c.branch = thread["branch"]?.stringValue ?? c.branch
                c.projectID = thread["projectId"]?.stringValue ?? c.projectID
                c.deviceID = thread["deviceId"]?.stringValue ?? c.deviceID
                c.pinned = thread["pinned"]?.boolValue ?? c.pinned
                c.updated = thread["updatedAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) ?? c.updated
            }
        case "turn/started":
            if c.activeTurnID != turnID { c.satellites = []; c.satellitesRetired = false }
            c.activeTurnID = turnID; c.running = true; c.stopping = false; c.error = nil; c.updated = event.time.map(Date.init(timeIntervalSince1970:)) ?? c.updated
            c.lastTurnInterrupted = false
        case "turn/completed":
            if c.activeTurnID == nil || c.activeTurnID == turnID {
                let interrupted = p["turn"]?["status"]?.stringValue == "interrupted" || c.stopping
                c.lastTurnInterrupted = interrupted
                c.running = false; c.activeTurnID = nil; c.stopping = false; c.pace = 0; c.satellitesRetired = true
                if interrupted { c.stops += 1 }
                if p["turn"]?["status"]?.stringValue == "failed" { c.error = .stopped }
                else if p["turn"]?["status"]?.stringValue == "completed" { c.error = nil }
                for i in c.items.indices where c.items[i].turnID == turnID && c.items[i].status == "running" {
                    c.items[i].status = interrupted ? "interrupted" : nil; c.items[i].revision += 1
                }
            }
        case "item/started", "item/completed":
            if let item = p["item"] { upsert(item, turnID: turnID, in: c, completed: event.method == "item/completed", time: event.time) }
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            guard let id = p["itemId"]?.stringValue, let delta = p["delta"]?.stringValue else { return }
            if let i = c.transcriptItemIndex(id) { c.items[i].text += delta; c.items[i].revision += 1 }
            else {
                let kind: RowKind = event.method.contains("reasoning") ? .reasoning : event.method.contains("commandExecution") ? .tool(.command) : event.method.contains("fileChange") ? .tool(.fileChange) : .assistant
                c.items.append(TranscriptItem(id: id, turnID: turnID, kind: kind, text: delta, status: "running"))
            }
            c.pace = event.method.contains("agentMessage") ? 1 : 0.4
        case "thread/tokenUsage/updated":
            let usage = p["tokenUsage"] ?? p
            if let tokens = usage["last"]?["totalTokens"]?.intValue { c.exactTokensUsed = tokens }
            if let limit = usage["modelContextWindow"]?.intValue, limit > 0 { c.contextLimit = limit }
            if let used = c.exactTokensUsed, let limit = c.contextLimit { c.contextUsed = Double(used) / Double(limit) }
        case "thread/compacted": c.compactions += 1
        case "turn/plan/updated":
            c.plan = (p["plan"]?.arrayValue ?? []).enumerated().map { i, step in .init(id: "\(turnID)-plan-\(i)", title: step["step"]?.stringValue ?? "", done: step["status"]?.stringValue == "completed") }
        case "core/approvalRequested": approval(p, in: c)
        case "core/approvalExpired", "core/approvalResponded":
            guard let id = p["approvalId"]?.stringValue else { return }
            c.approvals.removeAll { $0.id == id }
            if c.userInput?.id == id { c.userInput = nil; c.question = nil }
            if let itemID = p["itemId"]?.stringValue, let i = c.transcriptItemIndex(itemID) {
                c.items[i].status = p["status"]?.stringValue
                c.items[i].revision += 1
            }
        case "core/fixtureState":
            // Synthetic metadata has no backend equivalent; all text still uses regular item events.
            c.identityIndex = p["identityIndex"]?.intValue ?? c.identityIndex
            c.redEvents = p["redEvents"]?.intValue ?? c.redEvents
            c.question = p["question"]?.stringValue
            c.error = p["error"]?.stringValue == "running" ? .running : p["error"]?.stringValue == "stopped" ? .stopped : nil
            c.changes = (p["changes"]?.arrayValue ?? []).compactMap { value in
                guard let path = value["path"]?.stringValue else { return nil }
                return FileChange(path: path, added: value["added"]?.intValue ?? 0, removed: value["removed"]?.intValue ?? 0,
                    lines: (value["lines"]?.arrayValue ?? []).map { line in
                        .init(kind: line["kind"]?.stringValue == "added" ? .added : line["kind"]?.stringValue == "removed" ? .removed : .context,
                              text: line["text"]?.stringValue ?? "")
                    })
            }
            c.satellites = (p["satellites"]?.arrayValue ?? []).compactMap { value in
                guard let id = value["id"]?.stringValue else { return nil }
                return Satellite(id: id, face: value["face"]?.stringValue ?? "•ᴗ•", done: value["done"]?.boolValue ?? false,
                                 finishedOrder: value["finishedOrder"]?.intValue, threadID: id, title: value["title"]?.stringValue)
            }
        case "thread/name/updated": if let name = p["threadName"]?.stringValue ?? p["name"]?.stringValue { c.title = name }
        case "error":
            c.error = p["willRetry"]?.boolValue == true ? .running : .stopped
            c.operationError = p["error"]?["message"]?.stringValue ?? p["message"]?.stringValue ?? "Core reported an error."
            c.redEvents += 1
            c.items.append(TranscriptItem(id: "error-\(event.id)", turnID: turnID, kind: .notice(.error), text: c.operationError!))
        default: break
        }
    }
}
