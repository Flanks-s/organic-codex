#if NORMIE_SELFTEST || NORMIE_STREAM_BENCHMARK
import AppKit
import QuartzCore

/// Core-shaped synchronous bursts, including pending AppKit layout. No timers, networking, shell or window.
@MainActor enum NormieStreamCostVerification {
    struct Measurement: Codable {
        var count: Int, meanMS: Double, p50MS: Double, p99MS: Double, maximumMS: Double
        init(_ values: [Double]) {
            let sorted = values.sorted()
            count = sorted.count; meanMS = values.reduce(0, +) / Double(max(1, count))
            p50MS = sorted[sorted.count / 2]
            p99MS = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.99)) - 1)]
            maximumMS = sorted.last!
        }
    }
    struct Report: Codable {
        var historyCount: Int, conversations: Int
        var apply: Measurement, applyAndLayout: Measurement, forcedLayoutWithoutEvent: Measurement
        var finalAnswer: String, drawnAnswer: String, reasoningCharacters: Int
        var optimized: Bool
        var sidebarFullReloads: Int, sidebarRowReloads: Int, inspectorRenders: Int, detailFullShows: Int
        var composerRefreshes: Int, composerLayouts: Int, fullTranscriptIndices: Int, incrementalTranscriptUpdates: Int
        var viewportWidth: CGFloat
        var pendingLayoutViews: Int
    }
    static func measure() -> Report {
        let c = Conversation(id: "n2-stream", title: "Dedicated offline stream fixture")
        c.isLiveConversation = true; c.backendThreadID = c.id; c.running = true; c.activeTurnID = "stream"
        let paragraph = "**Recorded markdown** with `inline code`, a [link](https://example.invalid), and a readable paragraph. "
        c.items = (0..<2000).map { i in
            let kind: RowKind, text: String
            switch i % 5 {
            case 0: kind = .user; text = "Recorded question \(i)"
            case 1: kind = .assistant; text = String(repeating: paragraph, count: 12) + "\n```swift\nlet value = 42\n```"
            case 2: kind = .tool(.command); text = "printf recorded\n" + String(repeating: "recorded output\n", count: 8)
            case 3: kind = .reasoning; text = String(repeating: "Recorded reasoning. ", count: 24)
            default: kind = .tool(.fileChange); text = "Sources/File\(i).swift +12 −3"
            }
            return .init(id: "history-\(i)", turnID: "history-\(i / 5)", kind: kind, text: text)
        }
        c.items += [.init(id: "stream-reason", turnID: "stream", kind: .reasoning, text: "Thinking", status: "running"),
                    .init(id: "stream-answer", turnID: "stream", kind: .assistant, text: "", status: "running")]
        let others = (0..<11).map { Conversation(id: "other-\($0)", title: "Other conversation \($0)") }
        let store = ConversationStore(conversations: [c] + others, devices: MockSeed.devices)
        store.usesLiveCore = true
        let workbench = NormieWorkbench(store: store, sessions: NativeComposerSessions(), current: c.id)
        // The app mounts these controllers separately; loading the optional standalone split here would resize
        // the detail back to 1140pt and benchmark that split's constraint negotiation instead of a 1080pt column.
        let host = NormieView(frame: CGRect(x: 0, y: 0, width: 1320, height: 820))
        host.addSubview(workbench.sidebar.view); host.addSubview(workbench.detail.view)
        host.addSubview(workbench.inspector.view); workbench.inspector.view.isHidden = true
        workbench.refresh()
        workbench.sidebarModel.showMore("recents")
        workbench.sidebar.view.frame = CGRect(x: 0, y: 0, width: 240, height: 820)
        workbench.detail.view.frame = CGRect(x: 240, y: 0, width: 1080, height: 820)
        workbench.sidebar.view.layoutSubtreeIfNeeded(); workbench.detail.view.layoutSubtreeIfNeeded()
        workbench.detail.transcripts[c.id]?.scrollToEnd()
        let sidebarFull = workbench.sidebar.fullReloadCount, sidebarRows = workbench.sidebar.rowReloadCount
        let inspectorRenders = workbench.inspector.renderCount, detailShows = workbench.detail.fullShowCount
        let composerUpdates = workbench.detail.composer?.modelRefreshCount ?? 0
        let composerLayouts = workbench.detail.composer?.controlsLayoutCount ?? 0
        let indexBuilds = workbench.detail.transcripts[c.id]?.fullIndexRebuildCount ?? 0
        let increments = workbench.detail.transcripts[c.id]?.incrementalRefreshCount ?? 0
        var samples: [Double] = [], withLayout: [Double] = [], serial = 0
        func feed(_ method: String, _ item: String, _ delta: String) {
            serial += 1
            let event = CoreEvent(id: serial, time: 1_793_145_600 + Double(serial) / 300,
                method: method, params: ["threadId": .string(c.id), "turnId": "stream", "itemId": .string(item), "delta": .string(delta)])
            let start = CACurrentMediaTime(); store.apply(event)
            let applied = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded()
            workbench.detail.view.layoutSubtreeIfNeeded()
            workbench.detail.transcripts[c.id]?.layoutSubtreeIfNeeded()
            let finished = CACurrentMediaTime()
            samples.append((applied - start) * 1000); withLayout.append((finished - start) * 1000)
        }
        for i in 1...600 {
            feed("item/agentMessage/delta", "stream-answer", i % 2 == 1 ? String((i + 1) / 2) : ", ")
            if i % 12 == 0 { feed("item/reasoning/summaryTextDelta", "stream-reason", " reasoning") }
        }
        // layoutSubtreeIfNeeded traverses this windowless AppKit tree even without a delta. Keep that control
        // separate from the synchronous store.apply budget; it is not a second batch of backend events or FPS.
        var noEvent: [Double] = []
        for _ in 0..<20 {
            let start = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded(); workbench.detail.view.layoutSubtreeIfNeeded()
            workbench.detail.transcripts[c.id]?.layoutSubtreeIfNeeded()
            noEvent.append((CACurrentMediaTime() - start) * 1000)
        }
        let drawnAnswer = workbench.detail.transcripts[c.id]?.scrollView.documentView?.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "stream-answer" }?.body.string ?? ""
        func pending(_ view: NSView) -> Int { (view.needsLayout ? 1 : 0) + view.subviews.reduce(0) { $0 + pending($1) } }
        let report = Report(historyCount: c.items.count, conversations: store.conversations.count,
            apply: .init(samples), applyAndLayout: .init(withLayout), forcedLayoutWithoutEvent: .init(noEvent), finalAnswer: c.items.last!.text,
            drawnAnswer: drawnAnswer, reasoningCharacters: c.items[c.items.count - 2].text.count, optimized: !_isDebugAssertConfiguration(),
            sidebarFullReloads: workbench.sidebar.fullReloadCount - sidebarFull,
            sidebarRowReloads: workbench.sidebar.rowReloadCount - sidebarRows,
            inspectorRenders: workbench.inspector.renderCount - inspectorRenders,
            detailFullShows: workbench.detail.fullShowCount - detailShows,
            composerRefreshes: (workbench.detail.composer?.modelRefreshCount ?? 0) - composerUpdates,
            composerLayouts: (workbench.detail.composer?.controlsLayoutCount ?? 0) - composerLayouts,
            fullTranscriptIndices: (workbench.detail.transcripts[c.id]?.fullIndexRebuildCount ?? 0) - indexBuilds,
            incrementalTranscriptUpdates: (workbench.detail.transcripts[c.id]?.incrementalRefreshCount ?? 0) - increments,
            viewportWidth: workbench.detail.transcripts[c.id]?.bounds.width ?? 0, pendingLayoutViews: pending(host))
        workbench.detail.transcriptSessions.dispose()
        return report
    }
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        let r = measure()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(r).write(to: output.appendingPathComponent("n2-stream-cost.json"))
        check(r.apply.count == 650 && r.historyCount == 2002 && r.conversations == 12 && r.viewportWidth == 1080,
              "N2 real store.apply burst: 2002 rows, 12 chats, 1080pt transcript, 650 Core-shaped events")
        check(r.finalAnswer == (1...300).map { String($0) + ", " }.joined() && r.reasoningCharacters == 508,
              "N2 no dropped/coalesced events: all 600 answer and 50 reasoning deltas are synchronous")
        check(r.drawnAnswer == r.finalAnswer, "N2 the retained native text view contains the entire latest answer")
        check(r.sidebarFullReloads == 0 && r.sidebarRowReloads == 0, "N2 text deltas never reload a sidebar cell or table")
        check(r.inspectorRenders == 0 && r.detailFullShows == 0 && r.composerRefreshes == 0,
              "N2 collapsed inspector, retained detail and unchanged composer do no token-driven reconstruction")
        check(r.fullTranscriptIndices == 0 && r.incrementalTranscriptUpdates == 650,
              "N2 tail deltas update the existing index instead of rebuilding 2002 entries")
        if r.optimized {
            check(r.apply.meanMS <= 2, "N2 -O mean synchronous store.apply and every observer <= 2 ms")
            check(r.apply.p99MS <= 8, "N2 -O P99 synchronous store.apply and every observer <= 8 ms")
        }
        synchronousChanges(check: check)
        print(String(format: "N2 store.apply (-O=%@): mean %.3f ms, P99 %.3f ms, max %.3f ms; forced layout without events %.3f ms", r.optimized.description,
                     r.apply.meanMS, r.apply.p99MS, r.apply.maximumMS, r.forcedLayoutWithoutEvent.meanMS))
    }
    private static func synchronousChanges(check: (Bool, String) -> Void) {
        let c = Conversation(id: "n2-semantics", title: "Before")
        c.isLiveConversation = true; c.running = true
        c.items = [.init(id: "n2-user", turnID: "turn", kind: .user, text: "Question"),
                   .init(id: "n2-answer", turnID: "turn", kind: .assistant, text: "Answer", status: "running")]
        let store = ConversationStore(conversations: [c], devices: MockSeed.devices); store.usesLiveCore = true
        let wb = NormieWorkbench(store: store, sessions: NativeComposerSessions(), current: c.id)
        _ = wb.view; wb.view.frame = CGRect(x: 0, y: 0, width: 1340, height: 820); wb.view.layoutSubtreeIfNeeded()
        let full = wb.sidebar.fullReloadCount, rows = wb.sidebar.rowReloadCount, renders = wb.inspector.renderCount
        c.title = "After"; store.changed(c)
        check(wb.sidebar.fullReloadCount == full && wb.sidebar.rowReloadCount == rows + 1,
              "N2 title update synchronously reloads only its row")
        c.identityIndex += 1; store.changed(c)
        check(wb.sidebar.rowReloadCount == rows + 2, "N2 identity update is synchronous")
        c.error = .running; store.changed(c)
        check(wb.sidebar.rowReloadCount == rows + 3, "N2 error update is synchronous")
        c.error = nil; c.approvals = [.init(id: "n2-approval", title: "Approve", command: "printf fixture", note: "", acceptLabel: "Allow", toolItemID: "n2-answer")]; store.changed(c)
        check(wb.sidebar.rowReloadCount == rows + 4 && wb.detail.view.needsLayout, "N2 approval immediately updates sidebar and invalidates decision layout")
        c.approvals = []; c.question = "Answer this"; store.changed(c)
        check(wb.sidebar.rowReloadCount == rows + 5, "N2 question update is synchronous")
        c.question = nil; c.running = false; c.unread = true; store.changed(c)
        check(wb.sidebar.rowReloadCount == rows + 6 && wb.detail.composer?.state.running == false,
              "N2 unread/turn completion synchronously update sidebar and composer")
        let beforeDevice = wb.sidebar.rowReloadCount
        store.updateDevices(store.devices + [.init(id: "n2-offline", name: "Offline fixture", kind: .server, online: false)])
        c.deviceID = "n2-offline"; store.changed(c)
        check(wb.sidebar.rowReloadCount == beforeDevice + 1 && !wb.detail.offlineBanner.isHidden && wb.detail.composer?.state.online == false,
              "N2 device changes synchronously update the row, offline banner and send availability")
        c.deviceID = "mac"; store.changed(c)
        check(wb.detail.offlineBanner.isHidden && wb.detail.composer?.state.online == true,
              "N2 reconnecting the selected device immediately restores the existing composer")
        check(wb.inspector.renderCount == renders, "N2 hidden inspector never draws stale intermediate states")
        wb.requestInspector(shown: true)
        check(wb.inspector.renderCount > renders, "N2 opening inspector synchronously renders the latest model")
        let openRenders = wb.inspector.renderCount
        c.items[1].text += " delta"; c.items[1].revision += 1; store.changed(c)
        check(wb.inspector.renderCount == openRenders, "N2 visible inspector ignores body-only changes")
        c.branch = "other-branch"; store.changed(c)
        check(wb.inspector.renderCount > openRenders && wb.detail.composerContext.stringValue.contains("other-branch"),
              "N2 visible inspector and detail chrome synchronously update when displayed fields change")
        let transcript = wb.detail.transcripts[c.id]!
        let rebuilds = transcript.fullIndexRebuildCount
        c.items[0].text = "Edited user question"; c.items[0].revision += 1; store.changed(c)
        check(transcript.fullIndexRebuildCount == rebuilds + 1, "N2 user edit takes the full AX/layout invalidation path")
        wb.detail.transcriptSessions.dispose()
    }
}

#if NORMIE_STREAM_BENCHMARK
@main @MainActor enum NormieStreamBenchmark {
    static func main() throws {
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .darkAqua)
        let report = NormieStreamCostVerification.measure()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let path = CommandLine.arguments.dropFirst().first { try data.write(to: URL(fileURLWithPath: path)) }
        print(String(decoding: data, as: UTF8.self))
        precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "Benchmark must not open a window")
    }
}
#endif
#endif
