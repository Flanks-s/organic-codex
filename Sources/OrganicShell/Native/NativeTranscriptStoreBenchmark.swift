#if NATIVE_STREAM_BENCHMARK
import AppKit

/// Same fixture/timing boundary before and after: reducer + publish + all synchronous transcript work.
@main @MainActor enum NativeTranscriptStoreBenchmark {
    struct Result: Codable {
        let history: Int, events: Int, medianMS: Double, p95MS: Double, maximumMS: Double, totalMS: Double
        let historyPasses: Int, indexRebuilds: Int, incrementalRefreshes: Int, mountedRows: Int
        let textMatches: Bool
    }
    static func measure(_ count: Int) -> Result {
        let c = Conversation(id: "store-benchmark", title: "Recorded stream")
        c.items = (0..<count).map { i in
            let kind: RowKind = [.user, .assistant, .reasoning, .tool(.command), .tool(.fileChange)][i % 5]
            return .init(id: "history-\(i)", turnID: "turn-\(i / 5)", kind: kind,
                text: i % 5 == 1 ? "## Recorded answer\n**Markdown** and `code`.\n```swift\nlet n = 42\n```\n" : "Recorded tool or message \(i)")
        }
        c.items.append(.init(id: "stream", turnID: "stream-turn", kind: .assistant, text: "", status: "running"))
        c.running = true; c.activeTurnID = "stream-turn"
        let store = ConversationStore(conversations: [c]), view = NativeTranscript(conversation: c, store: store)
        view.frame = CGRect(x: 0, y: 0, width: 1080, height: 720); view.refresh(preservingOffset: false)
        let before = (view.historyScanCount, view.fullIndexRebuildCount, view.incrementalRefreshCount)
        let chunks = (0..<600).map { i in i % 30 == 0 ? "```swift\nlet value = \(i)\n```\n" : "**Line \(i)** with `code`.\n" }
        var samples: [Double] = []
        for (i, chunk) in chunks.enumerated() {
            let e = CoreEvent(id: i + 1, time: Double(i), method: "item/agentMessage/delta", params: ["threadId": .string(c.id), "turnId": "stream-turn", "itemId": "stream", "delta": .string(chunk)])
            let began = CACurrentMediaTime(); store.apply(e)
            let row = view.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "stream" }!
            row.body.layoutManager!.ensureLayout(for: row.body.textContainer!)
            samples.append((CACurrentMediaTime() - began) * 1000)
        }
        let sorted = samples.sorted()
        let row = view.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "stream" }
        let expected = TranscriptLayout.formatted(c.items.last!, presentation: NativeTranscriptPresentation.presentation(for: c.items.last!), scale: 1).text.string
        let r = Result(history: count, events: samples.count, medianMS: sorted[samples.count / 2],
            p95MS: sorted[Int(ceil(Double(samples.count) * 0.95)) - 1], maximumMS: sorted.last!, totalMS: samples.reduce(0, +),
            historyPasses: view.historyScanCount - before.0, indexRebuilds: view.fullIndexRebuildCount - before.1,
            incrementalRefreshes: view.incrementalRefreshCount - before.2, mountedRows: view.mountedRowCount,
            textMatches: c.items.last!.text.utf8.elementsEqual(chunks.joined().utf8) && row?.body.string.utf8.elementsEqual(expected.utf8) == true)
        view.dispose(); return r
    }
    static func main() throws {
        _ = NSApplication.shared
        let result = [measure(2000), measure(20000)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(decoding: data, as: UTF8.self))
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("store-change-stream-cost.json"))
        var findings: [String] = [], checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { findings.append(label); print("FINDING: " + label) } }
        for r in result {
            check(r.textMatches && r.historyPasses == 0 && r.indexRebuilds == 0 && r.incrementalRefreshes == r.events && r.mountedRows < 100,
                  "typed stream: complete bytes and zero full history scans for " + String(r.history))
        }
        try NativeTranscriptStreamVerification.run(output: output, check: check)
        try NativeTranscriptVirtualVerification.run(output: output, check: check)
        print("STORE_STREAM_BENCHMARK: \(checks) checks, \(findings.count) findings")
        if !findings.isEmpty { exit(1) }
    }
}
#endif
