import AppKit
import ImageIO
import QuartzCore

@main @MainActor enum FunctionPanelCCheck {
    static var checks = 0, failures: [String] = [], frames: [String] = [], timings: [[String: Double]] = []
    static let forbidden = ["GPT-5 Codex · High", "6m 12s", "61%", "84%", "26%", "272,000", "Sidebar density pass",
        "8 of 8"]
    static func check(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition {
            failures.append(name)
            print("FAIL: " + name)
        }
    }
    static func until(_ condition: () -> Bool) async {
        let deadline = CACurrentMediaTime() + 16
        while !condition() && CACurrentMediaTime() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
    static func noMock(_ snapshot: FunctionPanelProjectionSnapshot, view: FunctionPanelView? = nil, tag: String) {
        let input = snapshot.input
        let texts = [input.title, input.goal, input.model.text { $0 }, input.worked.text { $0 }] +
            (input.live?.semanticText ?? []) + (view?.renderedTexts ?? []) +
            [view?.accessibilityValue() as? String ?? ""] + (view?.buttons.values.filter {
                    !$0.isHidden }.map(\.label) ?? [])
        check(input.live != nil && input.id == "t1", "live.no-mock.identity." + tag)
        for value in forbidden { check(!texts.contains(where: { $0.contains(value) }),
                "live.no-mock." + tag + "." + value) }
    }
    static func values() async {
        let data = FunctionPanelCRecordedData(), projection = FunctionPanelProjection(store: data.store)
        let c = data.conversation
        let initialRevision = c.revision, initialItems = c.items
        let start = CACurrentMediaTime()
        var snapshot = projection.project(c, page: .overview, sources: data.sources, bodies: [])
        timings.append(["firstMS": (CACurrentMediaTime() - start) * 1000])
        let actual = conversationPhaseEvent(c)
        check(snapshot.phase.value?.event == actual && snapshot.phase.value?.turnID == c.phaseFacts.turnID,
            "live.phase.same-source-event")
        check(snapshot.phase.value?.event.value.fraction == Float(2.0 / 7), "live.phase.plan-not-context")
        check(snapshot.input.context.value == 0.9, "live.values.reported-ratio")
        check(snapshot.input.worked.value == nil, "live.worked-no-seed.known-history")
        noMock(snapshot, tag: "known")
        let builds = projection.builds, visits = projection.itemVisits
        for _ in 0..<100 { _ = projection.project(c, page: .overview, sources: data.sources, bodies: []) }
        check(projection.builds == builds && projection.itemVisits == visits, "live.incremental.same-revision-no-work")
        check(c.revision == initialRevision && c.items == initialItems, "live.read-only.model-unchanged")
        check(projection.artifactReads == 0, "live.incremental.no-unopened-artifact-read")
        let switched = FunctionPanelProjection(store: data.store)
        _ = switched.project(c, page: .library, sources: data.sources, bodies: [])
        var disconnected = FunctionPanelReadSources(id: "recorded-other-source", revision: 1)
        disconnected.connected = false
        check(switched.project(c, page: .overview, sources: disconnected, bodies: []).input.covers.value == nil,
            "live.incremental.source-id-invalidates-foreign-page-cache")
        check(switched.project(c, page: .library, sources: data.sources, bodies: []).input.status == c.status,
            "live.incremental.source-id-restored-without-foreign-snapshot")
        snapshot = projection.project(c, page: .library, sources: data.sources, bodies: [])
        check(snapshot.input.covers.value?.map(\.id) == ["text"], "live.artifact.thread-filter")
        check(!snapshot.input.covers.value!.contains(where: { $0.id == "image" }), "live.artifact.no-cross-thread")
        var unknownBytes = data.sources
        unknownBytes.revision += 1
        unknownBytes.artifacts = .known([.init(raw: ["id": "missing-bytes", "threadId": "t1",
                    "mimeType": "text/plain"])])
        let bytes = projection.project(c, page: .library, sources: unknownBytes, bodies: [])
        check(bytes.input.covers.value?.first?.metadata.value == nil, "live.values.artifact-no-default-zero-bytes")
        check(bytes.input.covers.value?.first?.metadata.text { $0 } != "0 B", "live.values.artifact-no-zero-label")
        var mapped = unknownBytes; mapped.revision += 1; mapped.artifactThreads = ["unassigned": "t1"]
        mapped.artifacts = .known([.init(raw: ["id": "unassigned"]), .init(raw: ["id": "unowned"])])
        check(projection.project(c, page: .library, sources: mapped,
                bodies: []).input.covers.value?.map(\.id) == ["unassigned"], "live.artifact.explicit-source-map")
        for page in FunctionPanelPage.allCases {
            snapshot = projection.project(c, page: page, sources: data.sources, bodies: [])
            noMock(snapshot, tag: page.rawValue)
            check(snapshot.input.worked.value == nil, "live.worked-no-seed." + page.rawValue)
        }
        snapshot = projection.project(c, page: .background, sources: data.sources, bodies: [])
        check(snapshot.input.tasks.value?.first?.command == "printf fixture", "live.records.command-payload")
        check(snapshot.input.tasks.value?.allSatisfy { $0.progress.value == nil && $0.elapsed.value == nil &&
                $0.action == nil } == true, "live.records.no-invented-job-progress")
        var truncated = data.sources; truncated.revision += 1; truncated.fileEvidence = [:]
        snapshot = projection.project(c, page: .files, sources: truncated, bodies: [])
        check(snapshot.input.files.value?.first?.additions.value == nil && snapshot.input.files.value?.first?.removals
            .value == nil, "live.records.truncated-no-full-stats")
        check(snapshot.input.files.value?.first?.provenance.hasPrefix("Files / Changes") == true,
            "live.records.unknown-file-origin")
        check(snapshot.input.files.value?.allSatisfy { !$0.provenance.contains("Changed in this conversation")
        } == true, "live.records.no-false-file-ownership")
        var staleProof = data.sources; staleProof.revision += 2
        staleProof.fileEvidence = ["fixture.swift": .init(threadID: "t1", complete: true,
                reportedLines: ["+old-version"])]
        check(projection.project(c, page: .files, sources: staleProof,
                bodies: []).input.files.value?.first?.additions.value == nil, "live.records.stale-diff-proof-rejected")
        snapshot = projection.project(c, page: .outputs, sources: data.sources, bodies: [])
        check(snapshot.input.outputs.value?.first?.content == "+new", "live.records.proven-diff-output")
        var generated = data.sources; generated.revision += 1
        generated.artifacts = .known([.init(raw: ["id": "owned-output", "threadId": "t1", "generatedItemId": "a1"]),
                .init(raw: ["id": "foreign-output", "threadId": "t2", "generatedItemId": "a2"])])
        let outputIDs = projection.project(c, page: .outputs, sources: generated,
            bodies: []).input.outputs.value?.map(\.id) ?? []
        check(outputIDs.contains("owned-output") && !outputIDs.contains("foreign-output"),
            "live.artifact.outputs-proven-owner")
        let used = FunctionPanelCRecordedData()
        used.conversation.contextLimit = nil; used.store.changed(used.conversation)
        snapshot = FunctionPanelProjection(store: used.store).project(used.conversation, page: .overview,
            sources: used.sources, bodies: [])
        check(snapshot.input.context.value == nil, "live.values.no-zero.only-used")
        check(snapshot.input.live?.contextText == "900 tokens · Limit not provided", "live.values.used-preserved")
        for status in ["unloaded", "loading", "unavailable", "failed", "disconnected"] {
            let fixture = FunctionPanelCRecordedData(recordHistory: status != "failed"); fixture.sources.revision += 1
            switch status {
            case "unloaded": fixture.conversation.historyLoaded = false
            fixture.sources.artifacts = .unloaded
            fixture.sources.model = .unloaded
            case "loading": fixture.conversation.loading = true
            fixture.sources.artifacts = .loading
            fixture.sources.model = .loading
            case "unavailable": fixture.sources.artifacts = .unavailable; fixture.sources.model = .unavailable
            case "failed":
                fixture.conversation.historyLoaded = false
                fixture.conversation.exactTokensUsed = nil; fixture.conversation.contextLimit = nil
                fixture.sources.historyError = "Recorded read failed"
                fixture.sources.artifacts = .failed("Recorded read failed")
                fixture.sources.model = .failed("Recorded read failed")
            default: fixture.sources.connected = false
            }
            fixture.store.changed(fixture.conversation)
            let adapter = FunctionPanelProjection(store: fixture.store)
            for page in FunctionPanelPage.allCases {
                let value = adapter.project(fixture.conversation, page: page, sources: fixture.sources, bodies: [])
                noMock(value, tag: status + page.rawValue)
                if status != "unavailable" { check(value.input.worked.value == nil,
                        "live.worked-no-seed." + status + page.rawValue) }
                check(value.input.context.value != 0, "live.values.no-zero." + status + page.rawValue)
                if status == "failed" {
                    check(fixture.conversation.operationError == nil && value.input.live?.conversationError == nil,
                        "reads.failure.C.explicit-only." + page.rawValue)
                    check(value.input.subagents == .failed("Recorded read failed") && value.input.goal.isEmpty,
                        "reads.failure.C.history." + page.rawValue)
                    check(value.input.context == .unavailable && value.input.live?.contextText == "Not provided",
                        "live.values.read-failure-no-token-data-or-zero." + page.rawValue)
                    if page == .files { check(value.input.files == .failed("Recorded read failed"),
                            "reads.failure.C.files") }
                    if page == .background { check(value.input.tasks == .failed("Recorded read failed"),
                            "reads.failure.C.background") }
                }
            }
            let collection = adapter.project(fixture.conversation, page: .library, sources: fixture.sources,
                bodies: []).input.covers
            check(collection.value == nil, "live.values.no-unknown-empty." + status)
            let expected = status == "unloaded" ? "Not loaded" : status == "loading" ? "Loading…" : status ==
                "unavailable" ? "Not provided" : "Couldn’t load"
            check(collection.status.hasPrefix(expected), "live.values.explicit-state." + status)
        }
        let operation = FunctionPanelCRecordedData(),
            operationProjection = FunctionPanelProjection(store: operation.store)
        operation.conversation.operationError = "Recorded operation failed"
        operation.store.changed(operation.conversation)
        for page in FunctionPanelPage.allCases {
            let value = operationProjection.project(operation.conversation, page: page, sources: operation.sources,
                bodies: [])
            check(value.input.context.value == 0.9 && value.input.subagents.value?.count == 3,
                "reads.operation-error.C.loaded." + page.rawValue)
            check(value.input.live?.conversationError == "Recorded operation failed" &&
                value.input.live?.semanticText.contains("Recorded operation failed") == true,
                "reads.operation-error.C.visible-value." + page.rawValue)
            check(!value.input.goal.isEmpty, "reads.operation-error.C.goal." + page.rawValue)
            let status = page == .library ? value.input.covers.status : page == .files ?
                value.input.files.status : page == .background ? value.input.tasks.status : page == .outputs ?
                value.input.outputs.status : value.input.subagents.status
            check(status == "Known", "reads.operation-error.C.no-read-failure." + page.rawValue)
        }
        let empty = FunctionPanelCRecordedData(); empty.sources.revision += 1; empty.sources.artifacts = .known([])
        check(FunctionPanelProjection(store: empty.store).project(empty.conversation, page: .library,
                sources: empty.sources, bodies: []).input.covers.value == [], "live.values.known-empty")
        let bare = Conversation(id: "t1", title: "Unloaded recorded thread"),
            bareStore = ConversationStore(conversations: [])
        bare.isLiveConversation = true; bare.backendThreadID = "t1"; bareStore.add(bare)
        let missing = FunctionPanelProjection(store: bareStore).project(bare, page: .overview, sources: data.sources,
            bodies: [])
        check(missing.phase.value == nil && missing.input.goal.isEmpty, "live.phase.missing-turn-no-fabrication")
        bareStore.apply(.init(id: 1, time: 1, method: "thread/restored", params: ["threadId": "t1",
                    "thread": ["id": "t1", "turns": []]]))
        let emptyRead = FunctionPanelProjection(store: bareStore)
        check(emptyRead.project(bare, page: .files, sources: data.sources, bodies: []).input.files.value == nil,
            "live.values.default-files-not-known-empty")
        check(emptyRead.project(bare, page: .background, sources: data.sources, bodies: []).input.tasks.value == [],
            "live.values.loaded-empty-command-records")
        let unplanned = FunctionPanelCRecordedData(); unplanned.emit("turn/started", ["turn": ["id": "no-plan"]])
        let noPlan = FunctionPanelProjection(store: unplanned.store).project(unplanned.conversation, page: .overview,
            sources: unplanned.sources, bodies: [])
        check(noPlan.phase.value?.event.value.state == .unknown && noPlan.phase.value?.event.value.fraction == nil,
            "live.phase.no-plan-unknown")
        unplanned.emit("item/started", ["turnId": "no-plan", "item": ["id": "absent-child",
                    "type": "collabAgentToolCall", "receiverThreadIds": ["missing-child"]]])
        let absent = FunctionPanelProjection(store: unplanned.store).project(unplanned.conversation, page: .overview,
            sources: unplanned.sources, bodies: [])
        check(absent.input.subagents.value?.first?.status == "Child not provided",
            "live.records.missing-child-not-success")
        for terminal in ["completed", "failed", "interrupted", "waiting"] {
            let d = FunctionPanelCRecordedData()
            if terminal == "waiting" {
                d.emit("core/approvalRequested", ["approvalId": "approval", "request": [
                            "method": "item/commandExecution/requestApproval", "params": ["command": "preview"]]])
            } else { d.emit("turn/completed", ["turn": ["id": "one", "status": .string(terminal)]]) }
            let phase = FunctionPanelProjection(store: d.store).project(d.conversation, page: .overview,
                sources: d.sources, bodies: []).phase.value
            check(phase?.event == conversationPhaseEvent(d.conversation
                ) && phase?.turnID == d.conversation.phaseFacts.turnID, "live.phase.exact-event." + terminal)
            check(phase?.event.value.state.rawValue == (terminal == "interrupted" ? "cancelled" : terminal),
                "live.phase.real-state." + terminal)
        }
        data.emit("thread/compacted", [:]); let begin = CACurrentMediaTime()
        _ = projection.project(c, page: .overview, sources: data.sources, bodies: [])
        timings.append(["incrementalMS": (CACurrentMediaTime() - begin) * 1000])
        let parentRevision = c.revision, beforeChild = projection.builds
        data.emit("item/completed", ["turnId": "child-turn", "item": ["id": "child-next", "type": "agentMessage",
                    "text": "Recorded child update"]], thread: "child-0")
        let updatedChild = projection.project(c, page: .overview, sources: data.sources, bodies: [])
        check(c.revision == parentRevision && projection.builds == beforeChild + 1 && updatedChild.input.subagents
            .value?.contains { $0.lines.contains("Recorded child update") } == true, "live.incremental.child-revision")
        var changedSource = data.sources; changedSource.revision += 1
        let beforeSource = projection.builds
        _ = projection.project(c, page: .overview, sources: changedSource, bodies: [])
        check(projection.builds == beforeSource + 1, "live.incremental.source-revision")
    }
    static func save(_ host: FunctionPanelLiveHost, _ name: String, output: URL) throws {
        let image = NativeViewBitmap.capture(host, scale: CGFloat(host.scale)), file = name + "-\(host.scale)x.png"
        let directory = output.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(file) as CFURL,
            "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        check(CGImageDestinationFinalize(destination), "live.frames.png." + file)
        frames.append(file)
    }
    static func hosts(_ output: URL, framesEnabled: Bool) async throws {
        for scale in [1, 2] {
            let data = FunctionPanelCRecordedData(), resources = BodyResources()
            let host = FunctionPanelLiveHost(conversation: data.conversation, store: data.store, resources: resources,
                scale: scale, read: { _ in data.sources })
            check(host.resources === resources && host.owner.resources === resources,
                "live.host.injected-existing-ledger.\(scale)")
            await until { !host.owner.hasPendingWork && host.owner.currentPicture != nil }
            check(host.owner.currentPicture?.event == host.snapshot.phase.value?.event &&
                host.owner.currentPicture?.turnID == data.conversation.phaseFacts.turnID,
                "live.phase.host-same-provenance.\(scale)")
            for scene in FunctionPanelScenario.allCases {
                host.select(scene); await until { !host.owner.hasPendingWork }
                noMock(host.snapshot, view: host.stage, tag: scene.fileKey + "\(scale)")
                check(!host.stage.buttons.contains { id, button in !button.isHidden && ["export",
                            "compact", "stop", "fork", "output.copy", "file.open"].contains(id) },
                    "live.host.no-write-entry.\(scene).\(scale)")
                if framesEnabled { try save(host, "live-" + scene.fileKey, output: output) }
            }
            host.select(.library)
            host.stage.interact { $0.coverID = "text"; $0.libraryOffset = 1 }
            let page = host.stage.state.page, selected = host.stage.state.coverID,
                scroll = host.stage.state.libraryOffset
            data.emit("thread/name/updated", ["name": "Recorded renamed thread"]); host.refresh()
            check(host.stage.state.title == data.conversation.title && host.stage.state.bodyID ==
                host.snapshot.input.bodyID, "live.incremental.read-only-title-and-identity-refresh.\(scale)")
            data.emit("turn/completed", ["turn": ["id": "one", "status": "completed"]]); host.refresh()
            check(host.stage.state.page == page && host.stage.state.coverID == selected &&
                host.stage.state.libraryOffset == scroll, "live.incremental.background-preserves-navigation.\(scale)")
            check(host.phaseInput?.animate == false, "live.host.reduce-motion-terminal.\(scale)")
            await until { !host.owner.hasPendingWork }
            let before = host.owner.publicationCount, builds = host.projection.builds
            try? await Task.sleep(for: .milliseconds(100))
            check(host.owner.publicationCount == before && host.projection.builds == builds,
                "live.incremental.stationary-zero-frames.\(scale)")
            host.close(); await until { resources.hdReservedBytes == 0 && host.owner.pendingImages == 0 }
            for missing in ["context-used-only", "phase-unknown", "library-empty-unowned", "files-truncated",
                "background-no-progress"] {
                let d = FunctionPanelCRecordedData()
                if missing == "context-used-only" { d.conversation.contextLimit = nil; d.store.changed(d.conversation) }
                if missing == "phase-unknown" { d.emit("turn/started", ["turn": ["id": "unplanned"]]) }
                if missing == "library-empty-unowned" {
                    d.sources.revision += 1
                    d.sources.artifacts = .known([.init(raw: ["id": "unowned-record",
                            "name": "Unassigned recorded artifact"])])
                }
                if missing == "files-truncated" {
                    d.sources.revision += 1
                    d.sources.fileEvidence = [:]
                    d.emit("item/completed", ["turnId": "one", "item": ["id": "truncated-diff", "type": "fileChange",
                            "changes": [["path": "fixture.swift", "diff": "+partial\n[truncated]"]]]])
                }
                let view = FunctionPanelLiveHost(conversation: d.conversation, store: d.store, resources: resources,
                    scale: scale, read: { _ in d.sources })
                view.select(missing == "library-empty-unowned" ? .library : missing == "files-truncated" ?
                    .files : missing == "background-no-progress" ? .background : .overview)
                await until { !view.owner.hasPendingWork }
                noMock(view.snapshot, view: view.stage, tag: missing + "\(scale)")
                if missing == "context-used-only" {
                    let rows = view.stage.liveContextRows
                    check(rows.map(\.source) == ["900 tokens", "Limit not provided"],
                        "live.values.context-visible.lines.\(scale)")
                    for row in rows { check(!row.truncated && row.band.contains(row.fragment) && row.band.contains(
                                row.glyphs), "live.values.context-visible.complete-glyphs.\(scale)." + row.role) }
                    check(rows.count == 2 && !rows[0].glyphs.intersects(rows[1].glyphs),
                        "live.values.context-visible.separate-lines.\(scale)")
                }
                if framesEnabled { try save(view, missing, output: output) }
                view.close(); await until { view.owner.pendingImages == 0 }
            }
            check(host.actions.isEmpty, "live.host.no-business-actions.\(scale)")
        }
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await values(); try await hosts(output, framesEnabled: !CommandLine.arguments.contains("--no-frames"))
        let report: [String: Any] = ["checks": checks, "failures": failures, "frames": frames,
            "projectionTimingSamples": timings,
            "dataSource": """
            CoreVerification recorded protocol rows + PhaseHostCheck plan events\
             + CoreControllerFixture artifact metadata; Store.apply/EventReducer; no network
            """]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,
                .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("C: \(checks) checks, \(failures.count) failures, \(frames.count) frames")
        exit(failures.isEmpty ? 0 : 1)
    }
}
