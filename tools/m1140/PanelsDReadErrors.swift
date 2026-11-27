import AppKit
import QuartzCore

extension FunctionPanelDCheck {
    static let readOnlyRoutes: Set<String> = ["/health", "/capabilities", "/sessions", "thread/list", "model/list",
        "account/read", "account/rateLimits/read"]
    static func prepareSendFixture(_ f: FunctionPanelDRecordedData) async throws {
        // Runtime.init intentionally clears discovery and marks the device offline. Rehydrate
        // through its real read-only load path, never by assigning the global model catalogue.
        f.wire.before = { request in
            precondition(readOnlyRoutes.contains(request.key), "No inference/write request may leave this send fixture")
            if request.key == "/sessions" { return [] }
            if request.key == "thread/list" { return ["data": []] }
            return nil // CoreControllerFixture's existing recorded read replies.
        }
        try await f.runtime.load()
    }
    /// Every failure is produced through an existing public business path, in isolated memory.
    static func produceError(_ kind: String, _ f: FunctionPanelDRecordedData) async -> String {
        let c = f.data.conversation
        switch kind {
        case "stop-rejected":
            _ = f.fail(.stop); f.owner.submit(.stop); await settle(f)
            check(f.wire.count("turn/interrupt") == 1, "reads.operation-error.source.stop")
        case "send-failed":
            // A missing attachment fails inside dispatch, before ensureThread or any model RPC.
            // The recorded model/list advertises model1 with no adjustable effort. Restored
            // new-chat preferences may still name a removed model, which must not be used.
            c.next.modelID = "model1"; c.next.effort = .none; c.next.speed = .standard; c.next.daybreak = false
            c.attachments = [.init(id: "missing-input", name: "Unrestored attachment", symbol: "doc")]
            let submission = CoreSubmission(identity: c.id, action: c.running ? .steer : .send,
                text: "Isolated send failure",
                attachments: c.attachments, settings: c.next, access: c.access, waitingForTurnID: c.activeTurnID)
            let admitted = f.runtime.submit(submission, in: c) { print("Recorded send receipt: \($0.result)") }
            let deadline = CACurrentMediaTime() + 10
            while c.sending && CACurrentMediaTime() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
            check(admitted && !c.sending && f.wire.requests.allSatisfy { readOnlyRoutes.contains($0.key) },
                "reads.operation-error.source.send-zero-inference-or-write")
            check(c.operationError?.contains("An attachment could not be restored") == true,
                "reads.operation-error.source.send-original-error")
        case "core-error":
            f.data.emit("error", ["turnId": "one", "willRetry": false,
                    "error": ["message": "Recorded Core error event"]])
            check(c.items.last?.text == "Recorded Core error event" && f.wire.requests.isEmpty,
                "reads.operation-error.source.reducer")
        case "appearance-save":
            f.storage.memory.writeError = CoreError(code: 409, message: "Recorded appearance storage failure",
                data: nil, httpStatus: 409)
            let symbol = c.identitySymbol, tint = c.identityTint
            do { try f.presentation.setIdentity(c, symbol: f.body, tint: tint) }
            catch {
                // OrganicWindow.onIdentityChanged's public catch path, with no Window/App mounted.
                c.operationError = "Couldn't save this chat's look: \(error.localizedDescription)"
                f.data.store.changed(c)
            }
            check(c.identitySymbol == symbol && c.identityTint == tint && f.wire.requests.isEmpty,
                "reads.operation-error.source.appearance-rollback")
            f.storage.memory.writeError = nil
        default: preconditionFailure("Unknown recorded error")
        }
        check(c.historyLoaded && c.operationError != nil, "reads.operation-error.source.loaded." + kind)
        return c.operationError ?? "Missing expected original error"
    }

    static func readErrors(_ output: URL) async throws -> [String: Int] {
        let start = checks
        for scale in [1, 2] {
            for kind in ["stop-rejected", "send-failed", "core-error", "appearance-save"] {
                let f = FunctionPanelDRecordedData()
                if kind == "send-failed" { try await prepareSendFixture(f) }
                let host = f.host(BodyResources(), scale: scale)
                for scene in FunctionPanelScenario.allCases { host.select(scene); host.refresh() }
                let before = host.snapshot.input
                let base = "reads.operation-error.\(kind).\(scale)"
                check(before.context.value == 0.9 && before.subagents.value?.count == 3 && before.covers.value?.count ==
                    1 && before.files.value?.count == 1 && before.tasks.value?.count == 1 &&
                    before.outputs.value?.count == 1, base + ".nonempty-baseline")
                let error = await produceError(kind, f)
                host.refresh()
                for scene in FunctionPanelScenario.allCases {
                    host.select(scene); host.refresh(); await ready(host)
                    let input = host.snapshot.input, tag = base + "." + scene.fileKey
                    check(input.context == before.context && input.live?.contextText == before.live?.contextText &&
                        host.stage.renderedTexts.contains("90%"), tag + ".context-original")
                    check(input.subagents == before.subagents, tag + ".children-original")
                    check(input.covers == before.covers, tag + ".library-original")
                    check(input.files == before.files, tag + ".files-original")
                    check(input.tasks == before.tasks, tag + ".background-original")
                    check(input.outputs == before.outputs, tag + ".outputs-original")
                    check(input.goal == before.goal && input.model == before.model && input.compactHistory ==
                        before.compactHistory, tag + ".overview-original")
                    check(input.live?.conversationError == error && host.stage.renderedTexts.contains(error),
                        tag + ".original-error-drawn")
                    check(host.stage.renderedTexts.contains("State · Conversation error") && (host.stage
                            .accessibilityValue() as? String)?.contains(error) == true, tag + ".state-error-label-AX")
                    check(host.stage.textFrames.contains { $0.text == error && host.stage.bounds.contains(
                                $0.frame) && host.stage.surfaceFrame("feedback")?.contains($0.frame) == true },
                        tag + ".error-visible-band")
                    check(!host.stage.renderedTexts.contains { $0.contains("Couldn’t load")
                    } && !(host.stage.accessibilityValue() as? String ?? "").contains("Couldn’t load"),
                        tag + ".no-page-read-failure")
                }
                host.select(.overview); host.refresh(); await ready(host)
                if scale == 2 { try save(host, "error-" + kind, output) }
                host.close(); f.runtime.shutdown()
            }
        }
        let operationChecks = checks - start, readStart = checks
        for scale in [1, 2] {
            for source in ["explicit", "unread-error"] {
                let data = FunctionPanelCRecordedData(recordHistory: false), c = data.conversation
                let error = "Recorded history read failure"
                data.sources.artifacts = .failed(error); data.sources.model = .failed(error)
                if source == "explicit" { data.sources.historyError = error }
                else { c.operationError = error; data.store.changed(c) }
                let host = FunctionPanelLiveHost(conversation: c, store: data.store, resources: BodyResources(),
                    scale: scale, read: { _ in data.sources })
                for scene in FunctionPanelScenario.allCases {
                    host.select(scene); host.refresh()
                    let input = host.snapshot.input, tag = "reads.failure.\(source).\(scale)." + scene.fileKey
                    check(!c.historyLoaded && !c.loading && c.items.isEmpty && (
                            source != "explicit" || c.operationError == nil), tag + ".genuine-unread")
                    check(input.subagents == .failed(error) && input.goal.isEmpty,
                        tag + ".history-failed-not-empty-or-unloaded")
                    check(input.context == .unavailable && input.live?.contextText == "Not provided",
                        tag + ".no-token-data-or-zero")
                    if scene.page == .library { check(input.covers == .failed(error), tag + ".library-failed") }
                    if scene.page == .files { check(input.files == .failed(error), tag + ".files-failed") }
                    if scene.page == .background { check(input.tasks == .failed(error), tag + ".background-failed") }
                    if scene.page == .outputs { check(input.outputs == .failed(error), tag + ".outputs-failed") }
                    check(host.stage.renderedTexts.contains { $0.contains("Couldn’t load")
                    } && (host.stage.accessibilityValue() as? String)?.contains(error) == true,
                        tag + ".failure-visible-not-swallowed")
                }
                host.close()
            }
        }
        return ["reads.operation-error": operationChecks, "reads.failure": checks - readStart]
    }
}
