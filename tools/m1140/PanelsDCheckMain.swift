import AppKit
import ImageIO
import QuartzCore

@main @MainActor enum FunctionPanelDCheck {
    static var checks = 0, failures: [String] = [], frames: [String] = []
    static var framesEnabled = true
    static func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value {
            failures.append(name)
            print("FAIL: " + name)
        }
    }
    struct Saved: Equatable {
        let title: String, draft: String, next: ModelSettings, symbol: String?, tint: String?
        let stopping: Bool, archived: Bool, count: Int, childStopping: Bool
        @MainActor init(_ f: FunctionPanelDRecordedData) {
            let c = f.data.conversation
            title = c.title; draft = c.draft; next = c.next; symbol = c.identitySymbol; tint = c.identityTint
            stopping = c.stopping
            archived = c.archived
            count = f.data.store.conversations.count
            childStopping = f.child.stopping
        }
    }
    static func settle(_ f: FunctionPanelDRecordedData) async {
        let until = CACurrentMediaTime() + 10
        while f.owner.pending && CACurrentMediaTime() < until { try? await Task.sleep(for: .milliseconds(2)) }
    }
    static func ready(_ host: FunctionPanelActionHost) async {
        let until = CACurrentMediaTime() + 10
        while host.owner.hasPendingWork && CACurrentMediaTime() < until { try? await Task.sleep(for: .milliseconds(2)) }
    }
    static func save(_ host: FunctionPanelActionHost, _ name: String, _ output: URL) throws {
        guard framesEnabled else { return }
        awaitlessSave(host, name, output)
    }
    static func awaitlessSave(_ host: FunctionPanelActionHost, _ name: String, _ output: URL) {
        let image = NativeViewBitmap.capture(host, scale: CGFloat(host.scale)), file = name + "-\(host.scale)x.png"
        let directory = output.appendingPathComponent("frames")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(file) as CFURL,
            "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        check(CGImageDestinationFinalize(destination), "actions.frames." + file); frames.append(file)
    }
    static func inputKept(_ f: FunctionPanelDRecordedData, _ host: FunctionPanelActionHost, _ before: Saved,
        _ tag: String) {
        check(f.data.conversation.next == before.next && f.data.conversation.draft == before.draft, tag + ".next-draft")
        check(host.stage.nameField.stringValue == "New title · 新标题" && host.stage.state.editingTitle,
            tag + ".new-title")
        check(!host.stage.nameField.isHidden && !host.stage.renderedTexts.contains(host.stage.state.title),
            tag + ".editor-without-old-title-overprint")
        check(host.stage.state.coverID == "text" && host.stage.state.libraryOffset == 1, tag + ".selection-scroll")
    }
    static func edit(_ host: FunctionPanelActionHost) {
        host.select(.library)
        host.stage.beginTitle(); host.stage.setTitleDraft("New title · 新标题")
        host.stage.interact { $0.coverID = "text"; $0.libraryOffset = 1 }
    }
    static func visible(_ host: FunctionPanelActionHost, _ text: String, _ tag: String) {
        check(host.stage.renderedTexts.contains(text), tag + ".drawn")
        check(host.stage.textFrames.contains { $0.text == text && host.stage.bounds.contains($0.frame) },
            tag + ".visible-frame")
        check((host.stage.accessibilityValue() as? String)?.contains(text) == true, tag + ".AX")
        let panel = host.stage.geometry.placed(FunctionPanelGeometry.panel)
        check(host.stage.surfaceFrame("feedback").map { panel.contains($0) } == true,
            tag + ".inside-existing-overlay-shield")
    }
    static func results(_ output: URL) async throws {
        for index in 0..<6 {
            for failing in [false, true] {
                let f = FunctionPanelDRecordedData(), action = f.operations[index], host = f.host(BodyResources(),
                    scale: 2)
                edit(host); let before = Saved(f), calls = f.wire.requests.count, writes = f.storage.writes
                let message = failing ? f.fail(action) : ""
                f.owner.submit(action); await settle(f)
                let tag = "actions." + (failing ? "rollback" : "success") + ".\(index)"
                check(!f.owner.pending, tag + ".finished")
                inputKept(f, host, before, tag)
                if failing {
                    check(Saved(f) == before, tag + ".store-restored")
                    visible(host, message, tag)
                    check(f.owner.result == message && !message.isEmpty, tag + ".original-error")
                    if case .body(let id) = action { check(host.stage.state.bodyID == id &&
                            f.data.conversation.identitySymbol == before.symbol, tag + ".selection-vs-saved-body") }
                    if case .colour(let id) = action { check(host.stage.state.colourID == id &&
                            f.data.conversation.identityTint == before.tint, tag + ".selection-vs-saved-colour") }
                    if case .openSubagent = action { check(f.wire.requests.count == calls, tag + ".zero-rpc") }
                    else if index == 0 || index == 5 { check(f.storage.writes == writes + 1 && f.wire.requests.count ==
                            calls, tag + ".one-local-attempt") }
                    else { check(f.wire.count(index == 1 ? "thread/fork" : "turn/interrupt") == 1, tag + ".one-write") }
                    await ready(host); try save(host, "failure-\(index)", output)
                } else {
                    check(f.owner.result != nil && f.owner.result != "Submitting…", tag + ".receipt")
                    switch action {
                    case .colour(let id):
                        check(f.data.conversation.identityTint == id && f.storage.writes == writes + 1,
                            tag + ".persisted-once")
                        check(f.wire.requests.count == calls, tag + ".zero-rpc")
                    case .body(let id):
                        check(f.data.conversation.identitySymbol == id && f.storage.writes == writes + 1,
                            tag + ".persisted-once")
                        check(f.wire.requests.count == calls, tag + ".zero-rpc")
                    case .fork:
                        check(f.data.store.conversations.count == before.count + 1, tag + ".store-child")
                        let requests = f.wire.requests.filter { $0.key == "thread/fork" }
                        check(requests.count == 1 && requests[0].params["threadId"] == "t1" && requests[0].params[
                                "beforeTurnId"] == nil, tag + ".whole-boundary")
                        let fork = f.data.store.backendConversation("fork-1")
                        check(fork?.next == before.next && fork?.items.map(\.id) == ["u1", "a1"],
                            tag + ".real-runtime-hydration")
                    case .stop, .stopSubagent:
                        let child = index == 4, target = child ? f.child : f.data.conversation
                        let requests = f.wire.requests.filter { $0.key == "turn/interrupt" }
                        check(requests.count == 1 && requests[0].params["threadId"] == .string(child ? "child-0" : "t1"
                            ) && requests[0].params["turnId"] == .string(child ? "child-active" : "one"),
                            tag + ".correct-business-target")
                        check(target.stopping && (child ? !f.data.conversation.stopping : !f.child.stopping),
                            tag + ".store-stopping")
                    case .openSubagent:
                        check(f.windows.openIDs == [f.satelliteID] && f.wire.requests.count == calls,
                            tag + ".existing-window-owner")
                        check(f.windows.history(subagentID: f.satelliteID)?.superview != nil,
                            tag + ".real-history-view")
                    default: break
                    }
                }
                host.close(); f.windows.dismiss(); f.runtime.shutdown()
            }
        }
    }
    static func preflight(_ output: URL) async throws {
        for scale in [1, 2] {
            for reason in ["target", "connection", "capability"] {
                for index in 0..<6 {
                    let f = FunctionPanelDRecordedData(), action = f.operations[index], host = f.host(BodyResources(),
                        scale: scale)
                    edit(host)
                    if reason == "target" { f.current = Conversation(id: f.data.conversation.id,
                            title: "Replacement object") }
                    if reason == "connection" { f.connected = false }
                    if reason == "capability" { f.capabilities.remove(FunctionPanelActionOwner.key(action)!) }
                    let before = Saved(f), writes = f.storage.writes, calls = f.wire.requests.count,
                        tag = "actions.guard." + reason + ".\(index).\(scale)"
                    f.owner.submit(action); await settle(f)
                    check(Saved(f) == before && f.storage.writes == writes, tag + ".unchanged-store")
                    check(f.wire.requests.count == calls && f.windows.openIDs.isEmpty, tag + ".zero-request")
                    let expected = reason == "target" ? "The conversation changed. Reopen the panel to submit." :
                        reason == "connection" ? "Disconnected. Reconnect before submitting." :
                        "This action is no longer available. Your input is kept."
                    visible(host, expected, tag)
                    inputKept(f, host, before, tag)
                    if case .body(let id) = action { check(host.stage.state.bodyID == id, tag + ".body-draft-kept") }
                    if case .colour(let id) = action { check(host.stage.state.colourID == id,
                            tag + ".colour-draft-kept") }
                    if index == 2 { await ready(host); try save(host, "refused-" + reason, output) }
                    let requests = f.wire.requests.count
                    check(host.stage.buttons["feedback.dismiss"]?.accessibilityPerformPress() == true,
                        tag + ".dismissible")
                    check(host.stage.surfaceFrame("feedback") == nil && f.wire.requests.count == requests && Saved(
                            f) == before, tag + ".dismiss-local-only")
                    inputKept(f, host, before, tag + ".after-dismiss")
                    host.close(); f.runtime.shutdown()
                }
            }
        }
        // Closed target, changed backend ID, and child replacement each use the same admission guard.
        for reason in ["closed", "thread", "child"] {
            let f = FunctionPanelDRecordedData(), host = f.host(BodyResources(), scale: 2)
            let action: FunctionPanelAction = reason == "child" ? .stopSubagent(f.satelliteID) : .stop
            if reason == "closed" { f.current = nil }
            if reason == "thread" { f.data.conversation.backendThreadID = "replacement-thread" }
            if reason == "child" { f.child.backendThreadID = "replacement-child" }
            let before = Saved(f); f.owner.submit(action); await settle(f)
            check(Saved(f) == before && f.wire.requests.isEmpty, "actions.guard.target." + reason)
            visible(host, "The conversation changed. Reopen the panel to submit.", "actions.guard.target." + reason)
            host.close(); f.runtime.shutdown()
        }
    }
    static func dedup() async {
        for index in 0..<6 {
            let f = FunctionPanelDRecordedData(), action = f.operations[index], writes = f.storage.writes
            f.owner.submit(action); f.owner.submit(action); await settle(f); f.owner.submit(action); await settle(f)
            let tag = "actions.dedup.\(index)"
            check(f.owner.submissions == 1, tag + ".one-business-admission")
            switch action {
            case .body, .colour: check(f.storage.writes == writes + 1 && f.owner.result == "Appearance saved",
                tag + ".one-save")
            case .fork: check(f.wire.count("thread/fork") == 1 && f.data.store.conversations.count == 5,
                tag + ".one-fork")
            case .stop, .stopSubagent: check(f.wire.count("turn/interrupt") == 1, tag + ".one-interrupt")
            case .openSubagent: check(f.windows.openIDs.count == 1 && f.opens == 1, tag + ".one-child-window")
            default: break
            }
            f.windows.dismiss(); f.runtime.shutdown()
        }
    }
    static func controls() async {
        for index in 0..<6 {
            let f = FunctionPanelDRecordedData(), host = f.host(BodyResources(), scale: 2), action = f.operations[index]
            if index == 0 {
                host.select(.customize)
                let bodyIndex = host.stage.input.bodies.firstIndex { $0.id == f.body }!
                host.stage.interact { $0.bodyScroll = max(0, bodyIndex - 3) }
            } else if index == 5 {
                host.stage.interact { $0.option = 1 }
            } else if index >= 3 {
                host.select(.hover); host.stage.interact { $0.pinnedSubagent = f.satelliteID }
            }
            let key = FunctionPanelActionOwner.key(action)!, button = host.stage.buttons[key]
            check(button?.live == true && button?.isHidden == false, "actions.ui.visible.\(index)")
            check(button?.accessibilityPerformPress() == true, "actions.ui.AX-press.\(index)")
            f.owner.submit(action) // Duplicate delivery of that intent, not a second AX command.
            await settle(f)
            check(f.owner.submissions == 1, "actions.dedup.ui.\(index)")
            check(f.owner.result != nil && f.owner.result != "Submitting…", "actions.ui.real-receipt.\(index)")
            host.close(); f.windows.dismiss(); f.runtime.shutdown()
        }
        let f = FunctionPanelDRecordedData(), host = f.host(BodyResources(), scale: 2)
        let button = host.stage.buttons["fork"]!
        func mouse(_ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: CACurrentMediaTime(),
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
        }
        button.mouseDown(with: mouse(1)); await settle(f)
        button.mouseDown(with: mouse(2)); await settle(f)
        check(f.wire.count("thread/fork") == 1, "actions.dedup.real-double-click")
        button.mouseDown(with: mouse(1)); await settle(f)
        check(f.wire.count("thread/fork") == 2, "actions.dedup.fresh-gesture-allowed")
        host.close(); f.runtime.shutdown()
    }
    static func failureDedup() async {
        for index in 0..<6 {
            let f = FunctionPanelDRecordedData(), action = f.operations[index]
            _ = f.fail(action)
            f.owner.submit(action); await settle(f)
            let calls = f.wire.requests.count, writes = f.storage.writes
            f.owner.submit(action); await settle(f)
            check(f.owner.submissions == 1, "actions.dedup.failed-intent.\(index)")
            check(f.wire.requests.count == calls && f.storage.writes == writes,
                "actions.dedup.failed-intent-no-repeat-write.\(index)")
            f.owner.beginIntent(); f.owner.submit(action); await settle(f)
            check(f.owner.submissions == 2, "actions.dedup.failed-intent-explicit-retry.\(index)")
            f.windows.dismiss(); f.runtime.shutdown()
        }
    }
    static func queuedFork() async {
        for reason in ["target", "connection", "capability"] {
            let f = FunctionPanelDRecordedData(), host = f.host(BodyResources(), scale: 2)
            edit(host); let before = Saved(f)
            f.owner.submit(.fork)
            if reason == "target" { f.current = nil }
            if reason == "connection" { f.connected = false }
            if reason == "capability" { f.capabilities.remove("fork") }
            await settle(f)
            let tag = "actions.guard." + reason + ".queued-fork"
            check(Saved(f) == before && f.wire.requests.isEmpty && !f.owner.pending, tag + ".no-write")
            let expected =
                reason == "target" ? "The conversation changed. Reopen the panel to submit." : reason == "connection" ?
                "Disconnected. Reconnect before submitting." : "This action is no longer available. Your input is kept."
            visible(host, expected, tag); inputKept(f, host, before, tag)
            host.close(); f.runtime.shutdown()
        }
    }
    static func scenes(_ output: URL) async throws {
        for scale in [1, 2] {
            let f = FunctionPanelDRecordedData(), host = f.host(BodyResources(), scale: scale)
            for scene in FunctionPanelScenario.allCases {
                host.select(scene); await ready(host)
                let tag = "actions.presentation.\(scene.fileKey).\(scale)"
                check(!host.stage.renderedTexts.contains { $0.contains("Notifications not provided") || $0.contains(
                            "Dock pin not provided") || $0.contains("Export not provided") }, tag + ".no-fine-print")
                for id in ["compact", "export", "option.2", "option.3", "option.4", "title.button", "cover.open",
                    "cover.copy", "file.open", "output.open", "output.copy"] {
                    check(host.stage.buttons[id]?.isHidden != false, tag + ".missing-capability-hidden." + id)
                }
                check(host.commandOwner.result == nil, tag + ".no-fake-success")
                for forbidden in FunctionPanelCCheckWords.values {
                    check(!host.stage.renderedTexts.contains { $0.contains(forbidden) }, tag + ".no-mock." + forbidden)
                }
                if scene == .overview {
                    let labels = host.stage.textFrames.filter { $0.frame.minY >= 264 && $0.frame.minY < 700 }
                    check(labels.filter { $0.text == "Not provided" }.count == 1 && labels.contains {
                            $0.text == "Model" }, tag + ".only-labeled-missing")
                    check(!labels.contains { $0.frame.minY == 264 + 149 }, tag + ".no-history-row")
                    let fork = host.stage.buttonFrame("fork")!, stop = host.stage.buttonFrame("stop")!,
                        panel = host.stage.surfaceFrame("panel")!
                    check(fork.minY == 264 + 149 && stop.minY == fork.minY && stop.minX - fork.maxX == 11,
                        tag + ".normal-action-spacing")
                    check(panel.maxY - stop.maxY == 16 && panel.height == 193, tag + ".collapsed-card-bottom")
                }
                try save(host, "live-d-" + scene.fileKey, output)
            }
            host.select(.overview); f.capabilities = []; host.refresh()
            check(host.stage.surfaceFrame("panel")?.height == 155,
                "actions.presentation.no-actions-natural-bottom.\(scale)")
            check(host.stage.buttons["fork"]?.isHidden != false && host.stage.buttons["stop"]?.isHidden != false,
                "actions.presentation.no-actions-no-buttons.\(scale)")
            let before = Saved(f); f.owner.submit(.stop); await settle(f)
            check(Saved(f) == before && f.wire.requests.isEmpty, "actions.guard.capability.no-actions.\(scale)")
            check(f.owner.result?.contains("accepted") != true, "actions.guard.capability.no-success.\(scale)")
            host.close(); f.runtime.shutdown()
        }
        let f = FunctionPanelDRecordedData(), host = f.host(BodyResources(), scale: 2)
        host.stage.interact { $0.option = 1 }
        check(host.stage.visibleButtonIDs.filter { $0.hasPrefix("colour.") }.count == 9,
            "actions.presentation.colour-nine-positions")
        host.stage.scrollColours(100)
        check(host.stage.buttons["colour.clay"]?.live == true && host.stage.state.colourScroll == 4,
            "actions.presentation.colour-overflow-reachable")
        let dots = host.stage.buttons.filter { $0.key.hasPrefix("colour.") && $0.value.live }.map { $0.value.frame }
        check(dots.count == 9 && dots.allSatisfy { $0.maxY < 228 }, "actions.presentation.colour-track-bounded")
        host.close(); f.runtime.shutdown()
    }
    static func editResults() async {
        let edits: [(FunctionPanelAction, String, String)] = [
            (.rename("New title · 新标题"), "thread/name/set", "Title saved"),
            (.compact, "thread/compact/start", "Compact request accepted"),
            (.archive, "thread/archive", "Archived"),
            (.undoArchive, "thread/unarchive", "Restored"),
        ]
        for (action, method, success) in edits {
            for mode in ["success", "failure", "target", "connection", "capability"] {
                let f = FunctionPanelDRecordedData(), c = f.data.conversation
                f.data.store.setOnline(c.deviceID, true)
                let key = FunctionPanelActionOwner.key(action)!
                f.capabilities.insert(key)
                c.archived = action == .undoArchive
                c.archivedAt = c.archived ? Date(timeIntervalSince1970: 100) : nil
                let host = f.host(BodyResources(), scale: 2), before = Saved(f), oldDate = c.archivedAt
                let context = c.contextUsed, compactions = c.compactions
                let rejection = CoreError(code: 409, message: "Recorded edit refusal", data: nil, httpStatus: 409)
                if mode == "failure" { f.wire.failures[method] = rejection }
                if case .rename(let title) = action {
                    host.stage.beginTitle()
                    host.stage.setTitleDraft(title)
                    host.stage.commitTitle()
                    host.stage.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification,
                                                              object: host.stage.nameField))
                } else { f.owner.submit(action) }
                f.owner.submit(action)
                if mode == "target" { f.current = nil }
                if mode == "connection" { f.connected = false }
                if mode == "capability" { f.capabilities.remove(key) }
                await settle(f)
                let tag = "edits.\(mode).\(key)", sent = mode == "success" || mode == "failure"
                check(f.wire.requests.count == (sent ? 1 : 0), tag + ".request-count")
                check(!f.owner.pending && f.owner.submissions == 1, tag + ".single-completion")
                check(c.draft == before.draft && c.next == before.next, tag + ".inputs")
                check(c.compactions == compactions && c.contextUsed == context, tag + ".no-fake-compaction")
                let request = f.wire.requests.first
                if sent { check(request?.key == method && request?.params["threadId"] == "t1", tag + ".target") }
                if mode == "success" {
                    check(f.owner.result == success, action == .compact ? "edits.compact" : "edits.receipt." + key)
                    check(c.archived == (action == .archive), tag + ".archive-changed")
                    check(c.title == (key == "rename" ? "New title · 新标题" : before.title), tag + ".title")
                } else {
                    check(Saved(f) == before && c.archivedAt == oldDate, tag + ".store-restored")
                    let reason = switch mode {
                    case "failure": rejection.message
                    case "target": "The conversation changed. Reopen the panel to submit."
                    case "connection": "Disconnected. Reconnect before submitting."
                    default: "This action is no longer available. Your input is kept."
                    }
                    let category = mode == "failure" ? "edits.receipt." + key : tag
                    check(f.owner.result == reason, category + ".feedback")
                    visible(host, reason, category)
                    if case .rename(let title) = action {
                        host.stage.beginTitle()
                        check(host.stage.nameField.stringValue == title, tag + ".resumed-draft")
                    }
                }
                host.close()
            }
        }
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        framesEnabled = !CommandLine.arguments.contains("--no-frames")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await results(output)
        try await preflight(output)
        await dedup()
        await controls()
        await failureDedup()
        await queuedFork()
        try await scenes(output)
        let readErrorChecks = try await readErrors(output)
        if CommandLine.arguments.contains("--edit-results") { await editResults() }
        let report: [String: Any] = ["checks": checks, "failures": failures, "frames": frames,
            "readErrorChecks": readErrorChecks,
            "dataSource": """
            C recorded Store.apply/EventReducer + existing CoreControllerFixture in-process\
             allowlisted transport; no runtime.start/load, network or real conversation
            """]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,
                .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("D: \(checks) checks, \(failures.count) failures, \(frames.count) frames")
        exit(failures.isEmpty ? 0 : 1)
    }
}

enum FunctionPanelCCheckWords { static let values = ["GPT-5 Codex · High", "6m 12s", "61%", "84%", "26%", "272,000",
        "Sidebar density pass", "8 of 8"] }
