#if M1_SELFTEST || NATIVE_STREAM_BENCHMARK
import AppKit

@MainActor enum NativeTranscriptStreamVerification {
    struct Measurement: Codable {
        let characters: Int, lines: Int, count: Int
        let totalMS: Double, meanMS: Double, p50MS: Double, p99MS: Double, maximumMS: Double
        let first100MeanMS: Double, last100MeanMS: Double
        let textMatches: Bool, followsEnd: Bool, mounted: Int, axIndex: Int
    }
    /// Timing boundary: Core-shaped delta + store.apply + every synchronous observer (no timers or coalescing).
    /// Include the actual native text view's glyph layout as well as the observer's height layout. No event or
    /// final outlier is removed; this does not force an unrelated AppKit window/controller tree to relayout.
    static func measure(characters: Int, lines: Int) -> Measurement {
        let c = Conversation(id: "n3-stream", title: "Recorded long answer")
        c.running = true; c.activeTurnID = "stream"; c.isLiveConversation = true
        c.items = (0..<2000).map { i in
            let kind: RowKind = [.user, .assistant, .tool(.command), .reasoning, .tool(.fileChange)][i % 5]
            let text = i % 5 == 1 ? String(repeating: "**Recorded markdown** with `code` and text. ", count: 12) : "Recorded history \(i)"
            return .init(id: "n3-history-\(i)", turnID: "old-\(i / 5)", kind: kind, text: text)
        }
        c.items.append(.init(id: "answer", turnID: "stream", kind: .assistant, text: "", status: "running"))
        let store = ConversationStore(conversations: [c]), transcript = NativeTranscript(conversation: c, store: store)
        transcript.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        transcript.refresh(preservingOffset: false)
        let count = 600, lineLength = characters / lines
        let value = String(repeating: String(repeating: "x", count: lineLength - 1) + "\n", count: lines)
        let bytes = Array(value.utf8)
        let activeRow = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "answer" }!
        var samples: [Double] = []
        for i in 0..<count {
            let chunk = String(decoding: bytes[(i * bytes.count / count)..<((i + 1) * bytes.count / count)], as: UTF8.self)
            let start = CACurrentMediaTime()
            store.apply(.init(id: i + 1, time: Double(i), method: "item/agentMessage/delta", params: ["threadId": .string(c.id), "turnId": "stream", "itemId": "answer", "delta": .string(chunk)]))
            activeRow.body.layoutManager!.ensureLayout(for: activeRow.body.textContainer!)
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        let row = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "answer" }
        let sorted = samples.sorted(), total = samples.reduce(0, +)
        let report = Measurement(characters: value.count, lines: lines, count: count, totalMS: total,
            meanMS: total / Double(count), p50MS: sorted[count / 2], p99MS: sorted[Int(ceil(Double(count) * 0.99)) - 1], maximumMS: sorted.last!,
            first100MeanMS: samples.prefix(100).reduce(0, +) / 100, last100MeanMS: samples.suffix(100).reduce(0, +) / 100,
            textMatches: row?.body.string == value, followsEnd: transcript.isAtEnd, mounted: transcript.mountedRowCount,
            axIndex: (transcript.scrollView.documentView as! NativeTranscriptTable).semanticRows.first { $0.key == "item:answer" }?.index ?? -1)
        transcript.dispose()
        return report
    }
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        let reports = measurements()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: output.appendingPathComponent("n3-stream-cost.json"))
        for r in reports {
            check(r.textMatches && r.followsEnd && r.mounted < 100 && r.axIndex == 2000, "N3 \(r.characters) characters: native text complete, follows end, bounded rows, global AX index")
            if !_isDebugAssertConfiguration() {
                check(r.meanMS <= 1, "N3 \(r.characters) characters: -O mean delta <= 1 ms")
                check(r.p99MS <= 4, "N3 \(r.characters) characters: -O P99 delta <= 4 ms")
                check(r.totalMS <= 1000, "N3 \(r.characters) characters: -O all 600 deltas <= 1 s")
            }
            print(String(format: "N3 %d chars/%d lines: mean %.3f ms, P99 %.3f ms, max %.3f ms, total %.3f ms; first100 %.3f last100 %.3f", r.characters, r.lines, r.meanMS, r.p99MS, r.maximumMS, r.totalMS, r.first100MeanMS, r.last100MeanMS))
        }
        correctness(check: check)
#if M1_SELFTEST
        NativeTranscriptStoreChangeVerification.run(check: check)
#endif
    }
    static func measurements() -> [Measurement] {
        [measure(characters: 12000, lines: 400), measure(characters: 30000, lines: 1000), measure(characters: 30000, lines: 1)]
    }
    private static func correctness(check: (Bool, String) -> Void) {
        let c = Conversation(id: "n3-markdown", title: "Incremental markdown")
        c.running = true
        c.items = [.init(id: "answer", turnID: "stream", kind: .assistant, text: "", status: "running")]
        let store = ConversationStore(conversations: [c]), transcript = NativeTranscript(conversation: c, store: store)
        transcript.frame = CGRect(x: 0, y: 0, width: 1080, height: 360)
        let value = "# Heading\nA **bold** sentence with `code` and 中文🙂.\n- Bullet\n```swift\nlet x = 1\n\n```\nTail **word**\r\nFinal `code`.\n**跨\r行**\n**跨\u{2028}行**\n"
        let control = NativeTranscriptRow()
        var diagnosed = false
        for char in value {
            c.items[0].text += String(char); c.items[0].revision += 1; store.changed(c)
            let expected = TranscriptLayout.formatted(c.items[0], presentation: NativeTranscriptPresentation.presentation(for: c.items[0]), scale: 1)
            let row = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first!
            control.configure(c.items[0], sourceItem: c.items[0], index: 0, items: c.items, width: 1080, expanded: false)
            // Font fallback for CJK is a TextKit storage edit. Compare two native laid-out storages, not an
            // unlaid-out formatter value against a storage in which AppKit has already substituted PingFang.
            control.body.layoutManager!.ensureLayout(for: control.body.textContainer!)
            row.body.layoutManager!.ensureLayout(for: row.body.textContainer!)
            let expectedStorage = control.body.textStorage!
            if !diagnosed, !row.body.textStorage!.isEqual(to: expectedStorage) {
                diagnosed = true
                for i in 0..<min(expected.text.length, row.body.textStorage!.length) {
                    let a = row.body.textStorage!.attributes(at: i, effectiveRange: nil), b = expectedStorage.attributes(at: i, effectiveRange: nil)
                    if !(a as NSDictionary).isEqual(to: b) { print("N3 attribute diagnostic at \(i): actual \(a), expected \(b)"); break }
                }
            }
            check(row.body.textStorage!.isEqual(to: expectedStorage), "N3 append preserves full Markdown attributes at \(c.items[0].text.utf16.count) UTF16 units")
            check(row.sourceOffsets == expected.sourceOffsets, "N3 append preserves raw-source glyph mapping at \(c.items[0].text.utf16.count)")
            let geometry = TranscriptLayout.geometry(item: c.items[0], presentation: NativeTranscriptPresentation.presentation(for: c.items[0]), tableWidth: 1080, scale: 1,
                isTurnStart: TranscriptPresentation.isTurnStart(index: 0, items: c.items), expanded: false,
                showsMeta: TranscriptPresentation.showsMeta(index: 0, items: c.items, presentation: NativeTranscriptPresentation.presentation(for: c.items[0])), attributedText: expected.text)
            check(row.frame.height == geometry.rowHeight, "N3 incremental TextKit height equals full layout at \(c.items[0].text.utf16.count)")
        }
        transcript.setSelectedRange(NSRange(location: 2, length: 5), itemID: "answer")
        let row = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first!
        let selected = row.body.selectedRange()
        c.items[0].text += "Another paragraph.\n"; store.changed(c)
        check(row.body.selectedRange() == selected, "N3 append retains selection in the same native text view")
        let before = transcript.scrollOffset
        transcript.followsEnd = false; c.items[0].text += "Reading away.\n"; store.changed(c)
        check(transcript.scrollOffset == before, "N3 non-following append preserves viewport pixels")
        c.items[0].text = "A replacement **answer**."; store.changed(c)
        check(row.body.string == "A replacement answer.", "N3 non-append replacement falls back to the complete formatter")
        c.items[0].text = "é"; c.items[0].revision += 1; store.changed(c)
        c.items[0].text = "e\u{301}"; c.items[0].revision += 1; store.changed(c)
        check(row.sourceOffsets == [0, 1], "N3 canonical-equivalent replacement preserves the actual UTF16 source, not String equality")
        for scale: CGFloat in [1, 2] {
            let full = transcript.textSnapshot(itemID: "answer", scale: scale)!.image
            transcript.setTextHidden(true, itemID: "answer", range: NSRange(location: 0, length: 2))
            let hidden = transcript.textSnapshot(itemID: "answer", scale: scale)!.image
            transcript.setTextHidden(false, itemID: "answer", range: NSRange(location: 0, length: 2))
            let restored = transcript.textSnapshot(itemID: "answer", scale: scale)!.image
            check(full.dataProvider!.data != hidden.dataProvider!.data && full.dataProvider!.data == restored.dataProvider!.data,
                  "N3 stream/replacement flight range restores identical native pixels at \(Int(scale))x")
        }
        transcript.dispose()
#if M1_SELFTEST
        var skipped = TranscriptItem(id: "skipped", turnID: "turn", kind: .assistant, text: "First", status: "running")
        let stream = NativeTranscriptStreamLayout(item: skipped, width: 740, scale: 1, style: .init())
        let cell = NativeTranscriptRow()
        func mountSkipped() {
            let prepared = NativeTranscriptPreparedRow(item: skipped, source: skipped, index: 0, items: [skipped], width: 1080, expanded: false, style: .init(), stream: stream)
            cell.configure(skipped, sourceItem: skipped, index: 0, items: [skipped], width: 1080, expanded: false, prepared: prepared)
        }
        mountSkipped()
        for suffix in [" second", " third"] {
            skipped.text += suffix; skipped.revision += 1
            _ = stream.append(skipped, width: 740, scale: 1, style: .init())
        }
        mountSkipped()
        check(cell.body.string == skipped.text, "N3 a retained cell skipping stream generations receives a full current copy")
#endif
    }
}

#if NATIVE_STREAM_BENCHMARK
@MainActor enum NativeTranscriptStreamBenchmark {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reports = NativeTranscriptStreamVerification.measurements()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: output.appendingPathComponent("n3-stream-cost.json"))
        for r in reports { print(String(format: "%d: mean %.3f P99 %.3f max %.3f total %.3f first100 %.3f last100 %.3f correct %@",r.characters,r.meanMS,r.p99MS,r.maximumMS,r.totalMS,r.first100MeanMS,r.last100MeanMS,r.textMatches.description)) }
    }
}
#endif
#endif
