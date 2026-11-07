#if M1_SELFTEST
import AppKit
import ObjectiveC

/// Compile Core/*.swift and Native/*.swift with -D M1_SELFTEST; no window or NSApplication.run is used.
@main @MainActor enum M1Verification {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/sol-native-m1")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures: [String] = [], diagnostics: [String] = [], checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !value() { failures.append(message) }
        }
        NativeTranscriptFollowVerification.run(check:{check($0,$1)})
        try NativeTranscriptScrollVerification.run(output: output, check: { check($0, $1) })
        if CommandLine.arguments.contains("--scroll-only") {
            let report = "Scroll verification: \(checks) checks, \(failures.count) findings\n" + failures.joined(separator: "\n")
            try report.write(to: output.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
            print(report)
            if !failures.isEmpty { exit(1) }
            return
        }
        #if !SCROLL_BASELINE
        NativeTranscriptScrollVerification.verifyInteractions(check: { check($0, $1) })
        try NativeTranscriptScrollVerification.verifyChevron(output: output, check: { check($0, $1) })
        #endif
        try NativeTranscriptVirtualVerification.run(output: output, check: { check($0, $1) })
        try NativeTranscriptStreamVerification.run(output: output, check: { check($0, $1) })
        try NativeComposerBarFocusVerification.run(output: output, check: { check($0, $1) })
        try NativeComposerM9Verification.run(output: output, check: { check($0, $1) })
        let store = ConversationStore()
        let mock = MockReplay(store: store)
        var events: [CoreEvent] = []; mock.onEvent = { events.append($0) }; mock.start(live: false)
        check(store.conversations.map(\.id) == MockSeed.make().map(\.id), "Complete mock seed identity and ordering")
        for seed in MockSeed.make() {
            let c = store.conversation(seed.id)!
            check(c.items.map(\.text) == seed.items.map(\.text), "Seed text: " + c.id)
            check(c.items.map(\.rowKind) == seed.items.map(\.rowKind), "Seed row kinds: " + c.id)
            check(c.items.map(\.status) == seed.items.map(\.status), "Seed row statuses: " + c.id)
            check(c.running == seed.running && c.error == seed.error && c.question == seed.question, "Seed run state: " + c.id)
            check(c.contextPercent == seed.contextPercent && c.plan.map(\.title) == seed.plan.map(\.title), "Seed usage and plan: " + c.id)
        }
        check(store.conversation("B")?.approvals.first?.title == "Run this command?", "Approval copy retained")
        check(store.conversation("A")?.satellites.count == 4, "Subagents retained")
        let priority = Conversation(id: "priority", title: "")
        priority.items = [.init(id: "p", turnID: "p", kind: .assistant, text: "done")]
        priority.running = true; priority.question = "question"; priority.error = .running
        priority.approvals = [.init(id: "a", title: "", command: "", note: "", acceptLabel: "", toolItemID: "")]
        check(priority.state == .waiting, "Approval precedes errors")
        priority.approvals = []; priority.error = .stopped
        check(priority.state == .failedStopped, "Stopped error priority")
        priority.error = .running; check(priority.state == .failedRunning, "Running error priority")
        priority.error = nil; check(priority.state == .asking, "Question precedes running")
        priority.question = nil; check(priority.state == .running, "Running priority")
        priority.running = false; check(priority.state == .done, "Done priority")
        priority.items = []; check(priority.state == .idle, "Idle priority")

        let replicaStore = ConversationStore()
        let sameMock = MockReplay(store: replicaStore)
        var sameEvents: [CoreEvent] = []; sameMock.onEvent = { sameEvents.append($0) }; sameMock.start(live: false)
        mock.advance(ticks: 40); sameMock.advance(ticks: 40)
        // M9 seeds now use each run's wall-clock origin so sidebar ages match the product. The
        // two runs have different Date() inputs: compare their full events in the same time coordinates.
        // Do not round/discard timestamps; every virtual offset and seeded updatedAt must still match.
        func relativeEvents(_ values: [CoreEvent]) -> [CoreEvent] {
            let origin=values.first?.time ?? 0
            return values.map { event in
                var fields=event.params.objectValue ?? [:]
                if event.method == "thread/started",var thread=fields["thread"]?.objectValue,let time=thread["updatedAt"]?.doubleValue {
                    thread["updatedAt"] = .number(time-origin);fields["thread"] = .object(thread)
                }
                return CoreEvent(id:event.id,time:event.time.map{$0-origin},method:event.method,params:.object(fields))
            }
        }
        check(relativeEvents(events) == relativeEvents(sameEvents), "Deterministic relative-clock replay, including every timestamp offset")
        let deltas = events.filter { $0.method == "item/reasoning/textDelta" || $0.method == "item/agentMessage/delta" }
        check(deltas.allSatisfy { ($0.params["delta"]?.stringValue?.count ?? 0) <= 16 }, "At most 16 characters per tick")
        let replayOrigin=events.first?.time ?? 0
        check(deltas.allSatisfy { let quarters=(($0.time ?? 0)-replayOrigin)*4;return quarters.rounded() == quarters }, "Quarter-second virtual clock relative to the seed origin")
        var parser = CoreSSEParser()
        let event = CoreEvent(id: 1, time: 0, method: "test", params: ["text": "中文 🪐"])
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        var parsed: [CoreEvent] = []
        for byte in Data("id: 1\r\nevent: test\r\ndata: \(json)\r\n\r\n".utf8) { parsed += try parser.append(Data([byte])) }
        check(parsed == [event], "SSE split CRLF and Unicode")
        let failed = Conversation(id: "error", title: "")
        EventReducer.apply(.init(id: 1, time: 1, method: "item/completed", params: ["item": ["id": "failed-command", "type": "commandExecution", "command": "false", "status": "failed"]]), to: failed)
        check(failed.items.first?.status == "failed", "Completed failed tools retain failure")
        let approvalThread = store.conversation("B")!
        mock.respond(approvalThread.approvals[0], in: approvalThread, action: .accept)
        mock.advance(ticks: 100)
        check(approvalThread.approvals.isEmpty && !approvalThread.running, "Approval fixture unblocks and finishes")

        let c = store.conversation("F")!
        let transcript = NativeTranscript(conversation: c, store: store)
        transcript.frame = CGRect(x: 0, y: 0, width: 640, height: 420)
        transcript.refresh(preservingOffset: true); transcript.scrollOffset = .zero
        let raw = c.items[0], full = NSRange(location: 0, length: (raw.text as NSString).length)
        let frames = transcript.glyphFrames(itemID: raw.id, range: full)
        check(frames.count > 1, "User text wraps into real TextKit line fragments")
        check(frames.allSatisfy { $0.rect.minX >= 28 && $0.rect.maxX <= 612 && $0.rect.height > 0 }, "Glyph rectangles use the reading column")
        check(frames.reduce(0) { $0 + $1.range.length } == full.length, "Wrapped raw ranges cover the user message")
        transcript.scrollOffset = CGPoint(x: 0, y: 50)
        let moved = transcript.glyphFrames(itemID: raw.id, range: full)
        check(zip(frames, moved).allSatisfy { abs($0.rect.minY - $1.rect.minY - 50) < 0.01 }, "Glyph rectangles follow viewport scrolling")
        transcript.setSelectedRange(NSRange(location: 0, length: 3), itemID: raw.id)
        let offset = transcript.scrollOffset
        c.items.append(.init(id: "stream", kind: .assistant, text: String(repeating: "stream ", count: 100), running: true))
        store.changed(c)
        check(transcript.scrollOffset == offset, "Streaming while away from end preserves offset")
        check(transcript.selectedRange(itemID: raw.id) == NSRange(location: 0, length: 3), "Streaming retains selection")
        transcript.scrollToEnd(); check(transcript.isAtEnd, "Scroll to end")
        transcript.setExpanded(true, itemID: "F-3")
        check(transcript.displayedText(itemID: "F-3") == c.items.first { $0.id == "F-3" }?.text, "Expanded activity has its full content")
        transcript.scrollOffset = .zero
        for scale: CGFloat in [1, 2] {
            let snapshot = transcript.snapshot(scale: scale)
            let reference = VerificationRaster.bitmap(width: Int(640 * scale), height: Int(420 * scale))
            reference.size = transcript.bounds.size
            memset(reference.bitmapData!, 0, reference.bytesPerRow * reference.pixelsHigh)
            transcript.cacheDisplay(in: transcript.bounds, to: reference)
            check(snapshot.width == Int(640 * scale) && snapshot.height == Int(420 * scale), "Snapshot backing dimensions at \(scale)x")
            check(snapshot.dataProvider?.data == reference.cgImage?.dataProvider?.data, "Snapshot equals a direct native cache at \(scale)x")
            let bytes = snapshot.dataProvider!.data! as Data
            check(bytes.contains { $0 != 0 }, "Snapshot contains rendered native content at \(scale)x")
            let bitmap = NSBitmapImageRep(cgImage: snapshot)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("transcript-\(Int(scale))x.png"))
            let canvas = CGContext(data: nil, width: snapshot.width, height: snapshot.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(CGColor(red: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
            canvas.draw(snapshot, in: CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
            try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("transcript-canvas-\(Int(scale))x.png"))
        }
        let markdown = c.items.first { $0.id == "F-8" }!
        let code = (markdown.text as NSString).range(of: "let readingWidth")
        check(!transcript.glyphFrames(itemID: markdown.id, range: code).isEmpty, "Markdown raw indices map through removed fences")
        check(transcript.displayedText(itemID: markdown.id)?.contains("```swift") == false, "Fenced delimiters are hidden")
        let activityText = transcript.displayedText(itemID: "F-2") ?? ""
        check(!transcript.displayedGlyphFrames(itemID: "F-2", range: NSRange(location: 0, length: (activityText as NSString).length)).isEmpty,
              "Generated activity has displayed glyph geometry")
        let beforeHiding = transcript.snapshot(scale: 1)
        let nativeText = transcript.textSnapshot(itemID: raw.id, scale: 2)
        check(nativeText != nil && nativeText!.image.width == Int(ceil(nativeText!.rect.width * 2)), "Flight text snapshot uses the actual text view")
        transcript.setTextHidden(true, itemID: raw.id)
        check(transcript.snapshot(scale: 1).dataProvider?.data != beforeHiding.dataProvider?.data, "Flight can remove source text while retaining its bubble")
        transcript.setTextHidden(false, itemID: raw.id)
        check(transcript.snapshot(scale: 1).dataProvider?.data == beforeHiding.dataProvider?.data, "Restoring flight text restores identical pixels")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func click(_ title: String, in view: NSView) -> Bool {
            guard let button = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == title && !$0.isHidden }) else { return false }
            button.performClick(nil); return true
        }
        func editField(_ field: NSTextField?, _ value: String) {
            guard let field else { return }
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        check(click("Review", in: transcript), "Changes Review is a native action")
        check(transcript.displayedText(itemID: "F-t1-changes")?.contains("struct ColumnMath") == true, "Fixture Review expands the actual diff")
        check(click("Undo", in: transcript), "Changes Undo is a native action")
        check(c.items.first { $0.id == "F-t1-changes" }?.status == TranscriptPresentation.changesReverted, "Fixture Undo marks the changes reverted")

        let cardStore = ConversationStore()
        let localReplay = MockReplay(store: cardStore); localReplay.start(live: false)
        let b = cardStore.conversation("B")!, approvalView = NativeTranscript(conversation: b, store: cardStore)
        approvalView.frame = CGRect(x: 0, y: 0, width: 620, height: 400); approvalView.refresh()
        approvalView.onApproval = { approval, action in localReplay.respond(approval, in: b, action: action) }
        check(click("Run", in: approvalView) && b.approvals.isEmpty, "Approval button resolves the fixture through its callback")
        let question = cardStore.conversation("C")!
        question.userInput = .init(id: "input", questions: [.init(id: "format", header: "Notes", prompt: "Which format?", options: [.init(label: "Features only", description: "Use the shorter outline")]), .init(id: "detail", header: "Detail", prompt: "Any detail?", options: [])])
        let questionView = NativeTranscript(conversation: question, store: cardStore)
        questionView.frame = CGRect(x: 0, y: 0, width: 620, height: 500); questionView.refresh()
        check(click("Features only", in: questionView), "Question choice is a native action")
        let inputs = descendants(questionView).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        editField(inputs.last, "Include the context row")
        check(click("Submit answer", in: questionView) && question.userInput == nil && question.question == nil, "Question fixture submits choice and text")
        check(question.items.last?.text == "Features only\nInclude the context row", "Question fixture retains submitted content")

        let all = Conversation(id: "all-rows", title: "All row kinds")
        let kinds: [RowKind] = [.user, .assistant, .reasoning, .tool(.command), .tool(.fileChange), .tool(.toolCall), .tool(.webSearch), .tool(.other), .notice(.error), .notice(.warning), .notice(.info)]
        all.items = kinds.enumerated().map { .init(id: "row-\($0.offset)", turnID: "turn", kind: $0.element, text: "Unicode 中文 👩🏽‍💻 row \($0.offset)\n**Bold** and `code`", status: $0.offset == 3 ? "failed" : nil) }
        let allView = NativeTranscript(conversation: all)
        for width: CGFloat in [320, 980] {
            allView.frame = CGRect(x: 0, y: 0, width: width, height: 600); allView.refresh(preservingOffset: true)
            check(all.items.allSatisfy { allView.displayedText(itemID: $0.id) != nil }, "Every RowKind has a native text view at width \(width)")
            for item in all.items { allView.setExpanded(true, itemID: item.id) }
            let textViews = descendants(allView).compactMap { $0 as? NativeTranscriptTextView }
            check(!textViews.isEmpty && textViews.allSatisfy { !$0.isEditable && $0.isSelectable }, "Transcript content is read-only and selectable")
            _ = allView.snapshot(scale: 2)
        }

        // A flight is an actual child cache placed over the viewport with that child omitted.
        let flightConversation = Conversation(id: "flight-sources", title: "Flight sources")
        flightConversation.items = [
            .init(id: "flight-work", turnID: "flight-turn", kind: .tool(.command), text: "swift build", status: "running"),
            .init(id: "flight-answer", turnID: "flight-turn", kind: .assistant, text: "**中文 👩🏽‍💻 lead** with `inline` code.\n```swift\nlet café = 1\n```\nLast sentence.")
        ]
        let flightView = NativeTranscript(conversation: flightConversation)
        flightView.frame = CGRect(x: 0, y: 0, width: 640, height: 500); flightView.refresh(preservingOffset: true)
        flightView.setSelectedRange(NSRange(location: 0, length: 3), itemID: "flight-answer")
        func pixels(_ image: CGImage) -> [UInt8] {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let segmentConversation = MockSeed.make().first { $0.id == "A" }!
        let segmentItem = segmentConversation.items.first { $0.id == "A-4" }!
        let segmentRaw = segmentItem.text as NSString
        let segmentRange = NSRange(location: 0, length: NSMaxRange(segmentRaw.range(of: "removed it.")))
        let segmentView = NativeTranscript(conversation: segmentConversation)
        segmentView.frame = CGRect(x: 0, y: 0, width: 380, height: 600); segmentView.refresh(preservingOffset: true)
        segmentView.scrollOffset = .zero
        segmentView.setSelectedRange(NSRange(location: 1, length: 5), itemID: segmentItem.id)
        for scale: CGFloat in [1, 2] {
            let original = segmentView.snapshot(scale: scale), source = segmentView.textSnapshot(itemID: segmentItem.id, scale: scale)!
            let glyphs = segmentView.glyphFrames(itemID: segmentItem.id, range: segmentRange)
            let offset = segmentView.scrollOffset, height = segmentView.contentHeight, selection = segmentView.selectedRange(itemID: segmentItem.id)
            segmentView.setTextHidden(true, itemID: segmentItem.id, range: segmentRange)
            let base = segmentView.snapshot(scale: scale)
            let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: base.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            for glyph in glyphs {
                let x = floor((glyph.rect.minX - source.rect.minX) * scale), y = floor((glyph.rect.minY - source.rect.minY) * scale)
                let maxX = ceil((glyph.rect.maxX - source.rect.minX) * scale), maxY = ceil((glyph.rect.maxY - source.rect.minY) * scale)
                let crop = CGRect(x: x, y: y, width: maxX - x, height: maxY - y).intersection(CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height))
                guard let cut = source.image.cropping(to: crop) else { check(false, "Segment glyph crop exists"); continue }
                let rect = CGRect(x: source.rect.minX + crop.minX / scale, y: source.rect.minY + crop.minY / scale, width: crop.width / scale, height: crop.height / scale)
                context.draw(cut, in: CGRect(x: rect.minX * scale, y: CGFloat(base.height) - rect.maxY * scale, width: crop.width, height: crop.height))
            }
            let expected = pixels(original), actual = pixels(context.makeImage()!)
            let delta = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
            diagnostics.append("Segment range, \(Int(scale))x: max channel error \(delta)/255")
            check(delta <= 1, "Segment cropped-glyph reconstruction at \(scale)x, error \(delta)/255")
            check(pixels(base) != expected && !glyphs.isEmpty, "Segment hides a nonempty markdown source range")
            let remainder = segmentView.glyphFrames(itemID: segmentItem.id, range: NSRange(location: NSMaxRange(segmentRange), length: segmentRaw.length - NSMaxRange(segmentRange)))
            check(!remainder.isEmpty && segmentView.textSnapshot(itemID: segmentItem.id, scale: scale) != nil, "Segment leaves the rest of the native body visible")
            segmentView.refresh(preservingOffset: true)
            check(pixels(segmentView.snapshot(scale: scale)) == pixels(base), "Partial suppression survives refresh without layout change")
            segmentView.setTextHidden(false, itemID: segmentItem.id, range: segmentRange)
            check(pixels(segmentView.snapshot(scale: scale)) == expected, "Restoring segment range restores identical bytes at \(scale)x")
            check(segmentView.scrollOffset == offset && segmentView.contentHeight == height && segmentView.selectedRange(itemID: segmentItem.id) == selection, "Segment preserves offset, height and native selection")
        }
        for scale: CGFloat in [1, 2] {
            for (part, id) in [(NativeFlightPart.workedDivider, "flight-answer"), (.activityText, "flight-work"), (.activityMark, "flight-work")] {
                let original = flightView.snapshot(scale: scale)
                guard let source = flightView.flightSource(part, itemID: id, scale: scale) else { check(false, "Flight source exists: \(part)"); continue }
                let oldOffset = flightView.scrollOffset, oldHeight = flightView.contentHeight
                flightView.setSelectedRange(NSRange(location: 0, length: 3), itemID: "flight-answer")
                let selection = flightView.selectedRange(itemID: "flight-answer")
                flightView.setFlightSourceHidden(true, part: part, itemID: id)
                let base = flightView.snapshot(scale: scale)
                let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: base.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
                context.draw(source.image, in: CGRect(x: source.rect.minX * scale, y: CGFloat(base.height) - source.rect.maxY * scale,
                    width: source.rect.width * scale, height: source.rect.height * scale))
                let expected = pixels(original), actual = pixels(context.makeImage()!)
                let delta = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
                diagnostics.append("Flight \(part), \(Int(scale))x: max channel error \(delta)/255")
                check(delta <= 1, "Flight reconstruction \(part) at \(scale)x (max channel error \(delta)/255, allowed 1/255)")
                check(pixels(base) != expected, "Hiding \(part) removes pixels at \(scale)x")
                check(source.image.width == Int(source.rect.width * scale) && source.image.height == Int(source.rect.height * scale)
                    && [source.rect.minX, source.rect.minY, source.rect.width, source.rect.height].allSatisfy { ($0 * scale).rounded() == $0 * scale }, "Flight source on pixel grid at \(scale)x")
                flightView.refresh(preservingOffset: true)
                check(flightView.flightSource(part, itemID: id, scale: scale) == nil, "Flight suppression survives refresh")
                flightView.setFlightSourceHidden(false, part: part, itemID: id)
                check(pixels(flightView.snapshot(scale: scale)) == expected, "Restoring \(part) returns identical bytes at \(scale)x")
                check(flightView.scrollOffset == oldOffset && flightView.contentHeight == oldHeight && flightView.selectedRange(itemID: "flight-answer") == selection, "Flight hide/restore preserves geometry, scroll and selection")
            }
        }
        let flightAnswer = flightConversation.items[1]
        let formattedLead = TranscriptLayout.formatted(flightAnswer, presentation: TranscriptPresentation.presentation(for: flightAnswer), scale: 1)
        check(formattedLead.sourceOffsets.count == formattedLead.text.length, "Source map covers displayed UTF-16 including emoji")
        for token in ["中文 👩🏽‍💻 lead", "inline", "let café = 1", "Last sentence."] {
            let rawRange = (flightAnswer.text as NSString).range(of: token)
            let displayRange = (formattedLead.text.string as NSString).range(of: token)
            let mapped = flightView.glyphFrames(itemID: flightAnswer.id, range: rawRange)
            let displayed = flightView.displayedGlyphFrames(itemID: flightAnswer.id, range: displayRange)
            check(mapped.map(\.rect) == displayed.map(\.rect) && !mapped.isEmpty, "Segment raw/displayed glyphs match: " + token)
            check(mapped.first?.range == rawRange, "Segment preserves source range: " + token)
        }
        for token in ["**", "`", "```swift\n"] {
            check(flightView.glyphFrames(itemID: flightAnswer.id, range: (flightAnswer.text as NSString).range(of: token)).isEmpty, "Removed markdown has no source glyph: " + token)
        }
        flightView.setExpanded(true, itemID: "flight-work")
        check(flightView.flightSource(.activityText, itemID: "flight-work", scale: 1) == nil && flightView.flightSource(.activityMark, itemID: "flight-work", scale: 1) == nil, "Expanded activity has no collapsed flight source")
        flightView.setExpanded(false, itemID: "flight-work")
        flightView.setTextHidden(true, itemID: "flight-work")
        flightView.setFlightSourceHidden(true, part: .activityText, itemID: "flight-work")
        flightView.setFlightSourceHidden(false, part: .activityText, itemID: "flight-work")
        check(flightView.flightSource(.activityText, itemID: "flight-work", scale: 1) == nil, "Restoring a flight part does not cancel setTextHidden")
        flightView.setTextHidden(false, itemID: "flight-work")
        // Inspect the instantiated view tree; compare draw IMPs so an unapproved text-control subclass cannot slip in.
        func uncapturedTextControls(_ view: NSView) -> [NSView] {
            descendants(view).filter { child in
                let base: AnyClass?
                if child is NSSecureTextField { base = NSSecureTextField.self }
                else if child is NSTextField { base = NSTextField.self }
                else if child is NSButton { base = NSButton.self }
                else if child is NSTextView { base = NSTextView.self }
                else if child is NativeComposerMenuButton { base = NSControl.self }
                else if child is NSControl && !(child is NSScroller) { return true }
                else { return false }
                let selector = #selector(NSView.draw(_:))
                guard let cls = object_getClass(child), let base,
                      let own = class_getInstanceMethod(cls, selector), let inherited = class_getInstanceMethod(base, selector) else { return true }
                return method_getImplementation(own) == method_getImplementation(inherited)
            }
        }
        for view in [transcript, approvalView, questionView, allView, flightView] {
            check(uncapturedTextControls(view).isEmpty, "Transcript tree contains only controls with a custom draw path")
        }

        // User hover strip: reserve height, expose only native actions, return the exact original item to callbacks.
        var editedItems: [TranscriptItem] = [], forkedItems: [TranscriptItem] = []
        transcript.onEditMessage = { editedItems.append($0) }; transcript.onForkMessage = { forkedItems.append($0) }
        let userRow = descendants(transcript).compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == raw.id }!
        let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let beforeHover = (transcript.contentHeight, transcript.scrollOffset, userRow.frame)
        userRow.mouseEntered(with: hover)
        let hoverButtons = userRow.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        check(Set(hoverButtons.compactMap { $0.accessibilityLabel() }).isSuperset(of: ["Copy", "Edit", "Fork from Here"]), "Hover exposes Copy, Edit and Fork with native labels")
        check(userRow.subviews.compactMap { $0 as? NativeLabel }.contains { !$0.isHidden && !$0.stringValue.isEmpty }, "Hover shows the reserved timestamp")
        hoverButtons.first { $0.accessibilityLabel() == "Edit" }?.performClick(nil)
        check(editedItems == [raw], "Native Edit returns the source item without editing the conversation")
        hoverButtons.first { $0.accessibilityLabel() == "Fork from Here" }?.performClick(nil)
        check(forkedItems == [raw], "Native Fork returns source item ID and history remains untouched")
        let clipboard = NSPasteboard.general
        let oldClipboard = clipboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        hoverButtons.first { $0.accessibilityLabel() == "Copy" }?.performClick(nil)
        check(clipboard.string(forType: .string) == raw.text, "Hover Copy retains the original message")
        clipboard.clearContents()
        let restoredClipboard = oldClipboard.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }
        clipboard.writeObjects(restoredClipboard)
        userRow.mouseExited(with: hover)
        check(beforeHover.0 == transcript.contentHeight && beforeHover.1 == transcript.scrollOffset && beforeHover.2 == userRow.frame, "Hover does not change row height, scroll or geometry")

        // Code appearance updates the real text view, geometry and the exact source image together.
        var style = NativeTranscriptCodeStyle(); style.fontID = "menlo"; style.pointSize = 15
        style.text = .systemPink; style.fill = NSColor.systemBlue.withAlphaComponent(0.15); style.added = .systemTeal; style.removed = .systemOrange
        flightView.codeStyle = style
        let styled = descendants(flightView).compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == flightAnswer.id }!.body
        let inlineRange = (styled.string as NSString).range(of: "inline")
        let inlineFont = styled.textStorage?.attribute(.font, at: inlineRange.location, effectiveRange: nil) as? NSFont
        check(inlineFont?.fontName.contains("Menlo") == true && inlineFont?.pointSize == 15, "Code settings reach actual inline TextKit font")
        check((styled.textStorage?.attribute(.foregroundColor, at: inlineRange.location, effectiveRange: nil) as? NSColor) == style.text
            && (styled.textStorage?.attribute(.backgroundColor, at: inlineRange.location, effectiveRange: nil) as? NSColor) == style.fill, "Code theme reaches actual foreground and background")
        let fenceRange = (styled.string as NSString).range(of: "let café")
        check((styled.textStorage?.attribute(.font, at: fenceRange.location, effectiveRange: nil) as? NSFont)?.pointSize == 15, "Code settings reach fenced text")
        let styleSnapshot = flightView.textSnapshot(itemID: flightAnswer.id, scale: 2)!
        check(styleSnapshot.image.width == Int(styleSnapshot.rect.width * 2), "Styled flight still caches actual TextKit pixels")

        let file = TranscriptItem(id: "spaced-path", turnID: "tool", kind: .tool(.fileChange), text: "Sources/中文 file.swift +9 −0\nOther.swift +0 −4")
        let fileParts = NativeTranscriptPresentation.activityParts(file, presentation: NativeTranscriptPresentation.presentation(for: file))
        check(fileParts.map(\.text).joined() == "Edited 中文 file.swift +9, Other.swift −4", "File changes retain spaces and Unicode and omit zero counts")
        for kind in [RowKind.tool(.command), .tool(.fileChange), .tool(.toolCall), .tool(.webSearch), .tool(.other)] {
            for status in ["running", "waiting", "declined", "cancelled", "failed", "stopped"] {
                let item = TranscriptItem(id: "status", turnID: "tool", kind: kind, text: "payload 中文", status: status)
                let presentation = NativeTranscriptPresentation.presentation(for: item)
                let parts = NativeTranscriptPresentation.activityParts(item, presentation: presentation)
                check(presentation.statusKind != .none && !parts.isEmpty && parts.map(\.text).joined().contains("payload 中文"), "Tool keeps status and real payload: \(kind), \(status)")
            }
        }
        let emptyReasoning = TranscriptItem(id: "empty-reason", turnID: "tool", kind: .reasoning, text: "")
        check(NativeTranscriptPresentation.activityParts(emptyReasoning, presentation: NativeTranscriptPresentation.presentation(for: emptyReasoning)).map(\.text).joined() == "No summary", "Empty completed reasoning shows the real empty state")

        // Streaming updates only changed rows, immediately remeasures height and independently tracks user reading.
        let streamConversation = Conversation(id: "incremental", title: "Incremental")
        streamConversation.items = (0..<24).map { .init(id: "stable-\($0)", turnID: "t\($0)", kind: .assistant, text: "Paragraph \($0)\nSecond line 中文") }
        let streamView = NativeTranscript(conversation: streamConversation)
        streamView.frame = CGRect(x: 0, y: 0, width: 420, height: 240); streamView.refresh(preservingOffset: false)
        let counts = streamConversation.items.map { streamView.rowConfigurationCount(itemID: $0.id) }
        let previousHeight = streamView.contentHeight
        streamConversation.items[23].text += String(repeating: "\nstreaming line", count: 12); streamConversation.items[23].revision += 1
        streamConversation.revision += 1; streamView.refresh()
        check(streamView.contentHeight > previousHeight && streamView.isAtEnd, "Streaming height updates synchronously and follows the bottom")
        check((0..<23).allSatisfy { streamView.rowConfigurationCount(itemID: "stable-\($0)") == counts[$0] }
            && streamView.rowConfigurationCount(itemID: "stable-23") == counts[23] + 1, "Streaming configures only the changed row")
        streamView.scrollOffset = .zero
        let readingRect = streamView.glyphFrames(itemID: "stable-10", range: NSRange(location: 0, length: 9))[0].rect
        streamView.scrollOffset = CGPoint(x: 0, y: readingRect.minY + 4)
        let anchored = streamView.glyphFrames(itemID: "stable-10", range: NSRange(location: 0, length: 9))[0].rect
        streamView.setSelectedRange(NSRange(location: 1, length: 5), itemID: "stable-10")
        streamConversation.items[2].text += String(repeating: "\nEarlier line grows", count: 20); streamConversation.items[2].revision += 1
        streamConversation.revision += 1; streamView.refresh()
        check(streamView.glyphFrames(itemID: "stable-10", range: NSRange(location: 0, length: 9))[0].rect == anchored, "Growth above the viewport preserves the reader's row and distance")
        check(streamView.selectedRange(itemID: "stable-10") == NSRange(location: 1, length: 5), "Growth above the viewport preserves native selection")
        check(streamView.newContentWhileAway && !streamView.isAtEnd && click("Jump to Latest", in: streamView) && streamView.isAtEnd && !streamView.newContentWhileAway, "Jump to Latest is available only for unread content while away")
        streamView.followsEnd = false
        let frozen = streamView.scrollOffset
        streamConversation.items[23].text += String(repeating: "\nFrozen flight base", count: 12); streamConversation.revision += 1; streamView.refresh()
        check(streamView.scrollOffset == frozen && !streamView.isAtEnd, "followsEnd=false freezes the end viewport during a flight")
        streamView.followsEnd = true; streamView.scrollToEnd()
        streamConversation.items[23].status = nil; streamConversation.revision += 1; streamView.refresh()
        check(streamView.isAtEnd, "Streaming completion retains the bottom follow position")

        // Structured answers: one shared value per ID, descriptions visible, secrets remain secure fields.
        let formConversation = Conversation(id: "form", title: "Form")
        let formRequest = UserInputRequest(id: "request-id", questions: [
            .init(id: "choice-id", header: "Format", prompt: "Pick one", options: [.init(label: "Outline", description: "Keep the full outline")]),
            .init(id: "secret-id", header: "Credential", prompt: "Secret answer", options: [], isSecret: true)
        ])
        formConversation.userInput = formRequest
        let formView = NativeTranscript(conversation: formConversation)
        formView.frame = CGRect(x: 0, y: 0, width: 500, height: 500); formView.refresh()
        var receivedAnswers: [(String, [String: [String]])] = []
        formView.onAnswer = { request, answers in receivedAnswers.append((request.id, answers)) }
        let submitForm = descendants(formView).compactMap { $0 as? NSButton }.first { $0.title == "Submit answer" }!
        check(!submitForm.isEnabled && descendants(formView).compactMap { $0 as? NSTextView }.contains { $0.string == "Keep the full outline" }, "Question descriptions are visible; incomplete form cannot submit")
        let secret = descendants(formView).compactMap { $0 as? NativeSecureField }.first!
        check(click("Outline", in: formView) && !submitForm.isEnabled, "Selecting one option does not submit an incomplete form")
        editField(secret, "   "); check(!submitForm.isEnabled, "Whitespace secret is invalid")
        editField(secret, "sensitive answer"); check(submitForm.isEnabled, "All valid answers enable Submit")
        submitForm.performClick(nil)
        check(receivedAnswers.first?.0 == "request-id" && receivedAnswers.first?.1 == ["choice-id": ["Outline"], "secret-id": ["sensitive answer"]], "Structured submit preserves request ID, question IDs and option labels")
        let freeAnswer = descendants(formView).compactMap { $0 as? NativeLabel }.first { $0.isEditable && $0.identifier?.rawValue == "choice-id" }!
        editField(freeAnswer, "Own answer")
        formView.refresh(preservingOffset: true)
        check(freeAnswer.stringValue == "Own answer" && secret.stringValue == "sensitive answer", "Refresh preserves per-question values and secret control identity")
        formConversation.userInput?.submitting = true; formView.refresh(preservingOffset: true)
        let waitingSubmit = descendants(formView).compactMap { $0 as? NSButton }.first { $0.title == "Submit answer" }!
        let answerCount = receivedAnswers.count; waitingSubmit.performClick(nil)
        check(!waitingSubmit.isEnabled && receivedAnswers.count == answerCount && !secret.isEnabled, "Submitting form disables edits and duplicate native submissions")

        // Elicitation: retain the original request and send an explicit JSON response only after validation.
        let schema: JSONValue = ["type": "object", "properties": ["name": ["type": "string", "minLength": 1], "count": ["type": "integer", "minimum": 1], "mode": ["type": "string", "enum": ["fast", "full"]]], "required": ["name", "count"], "additionalProperties": false]
        let elicitation = Approval(id: "elicitation-id", title: "Requested information", command: "Fill the requested fields", note: "", acceptLabel: "Allow", toolItemID: "", method: "elicitation/create", request: ["params": ["requestedSchema": schema]])
        let elicitationConversation = Conversation(id: "elicitation", title: "Elicitation")
        elicitationConversation.isLiveConversation = true; elicitationConversation.approvals = [elicitation]
        let elicitationView = NativeTranscript(conversation: elicitationConversation)
        elicitationView.frame = CGRect(x: 0, y: 0, width: 500, height: 600); elicitationView.refresh()
        var values: [JSONValue] = [], ordinaryApprovals = 0
        elicitationView.onApproval = { _, _ in ordinaryApprovals += 1 }
        elicitationView.onApprovalValue = { approval, response in check(approval == elicitation, "Elicitation preserves the original Core request"); values.append(response) }
        let jsonInput = descendants(elicitationView).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        let allow = descendants(elicitationView).compactMap { $0 as? NSButton }.first { $0.title == "Allow" }!
        check(!allow.isEnabled && descendants(elicitationView).compactMap { $0 as? NSTextView }.contains { $0.string.contains("required") && $0.string.contains("count") }, "Elicitation renders required schema and rejects the empty object")
        for invalid in ["not JSON", "[]", "{}", "{\"name\":\"\",\"count\":1}", "{\"name\":\"ok\",\"count\":1.5}", "{\"name\":\"ok\",\"count\":0}", "{\"name\":\"ok\",\"count\":1,\"mode\":\"bad\"}"] {
            editField(jsonInput, invalid); allow.performClick(nil)
            check(!allow.isEnabled && values.isEmpty && ordinaryApprovals == 0, "Invalid elicitation content cannot accept: " + invalid)
        }
        editField(jsonInput, "{\"name\":\"ok\",\"count\":2,\"mode\":\"full\"}")
        check(allow.isEnabled, "Valid elicitation enables Allow")
        allow.performClick(nil)
        check(values == [["action": "accept", "content": ["name": "ok", "count": 2, "mode": "full"]]] && ordinaryApprovals == 0, "Valid elicitation sends exact JSON content through the value callback")
        elicitationView.refresh(preservingOffset: true)
        check(jsonInput.stringValue.contains("full"), "Elicitation draft survives an unrelated refresh")
        elicitationConversation.approvals[0].submitting = true; elicitationView.refresh(preservingOffset: true)
        check(!jsonInput.isEnabled, "Submitting elicitation keeps its draft and disables edits")
        check(NativeTranscriptSchema.error(["outer": [:]], schema: ["type": "object", "properties": ["outer": ["type": "object", "required": ["inner"]]]]) != nil, "Elicitation validates nested required fields")
        check(NativeTranscriptSchema.error(["items": [1, "wrong"]], schema: ["properties": ["items": ["type": "array", "items": ["type": "integer"]]]]) != nil, "Elicitation validates array element types")
        check(NativeTranscriptSchema.error(["name": "ok"], schema: ["properties": ["name": ["$ref": "#/definition"]]]) != nil, "Unsupported schema constraints cannot silently accept a value")
        check(NativeTranscriptSchema.error([:], schema: ["not": ["$ref": "#/definition"]]) != nil, "An unsupported negated schema cannot be treated as a validation success")
        let nestedMarkdown = TranscriptItem(id: "nested-code", turnID: "code", kind: .assistant, text: "**A `bold code` and B**; `**literal**`.")
        let nestedFormat = TranscriptLayout.formatted(nestedMarkdown, presentation: TranscriptPresentation.presentation(for: nestedMarkdown), scale: 1, codeStyle: style)
        check(nestedFormat.text.string == "A bold code and B; **literal**." && nestedFormat.sourceOffsets.count == nestedFormat.text.length, "Bold containing code and literal emphasis inside code retain correct markup mapping")
        let nestedCodeRange = (nestedFormat.text.string as NSString).range(of: "bold code")
        check((nestedFormat.text.attribute(.font, at: nestedCodeRange.location, effectiveRange: nil) as? NSFont)?.fontName.contains("Menlo") == true, "Bold formatting preserves the configured inline code font")

        for view in [streamView, formView, elicitationView] {
            check(uncapturedTextControls(view).isEmpty, "New transcript controls all override draw")
            check(descendants(view).filter { $0 is NSButton || $0 is NSTextField }.allSatisfy { child in
                if let field = child as? NSTextField { return !field.isBezeled && !field.isBordered }
                return (child as? NSButton)?.isBordered == false
            }, "Transcript controls have no system bezels")
            check(descendants(view).allSatisfy { child in [child.frame.minX, child.frame.minY, child.frame.width, child.frame.height].allSatisfy { $0.rounded() == $0 } }, "Unattached transcript geometry is backing-aligned")
        }
        let axTexts = descendants(allView).compactMap { $0 as? NativeTranscriptTextView }
        for text in axTexts {
            _ = text.scrollToVisible(text.bounds)
            let original = text.string
            check(text.accessibilityValue() == original && text.accessibilityRole() == .textArea, "AX reads the actual native text value")
            check(!text.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")) && !text.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilitySelectedText:")) && !text.accessibilityIsAttributeSettable(.value), "Read-only AX does not advertise content writes")
            text.setAccessibilityValue("forbidden"); text.setAccessibilitySelectedText("forbidden")
            text.accessibilitySetValue("forbidden", forAttribute: .value)
            check(text.string == original, "Modern and legacy AX content writes are rejected")
            text.setAccessibilitySelectedTextRange(NSRange(location: 0, length: min(2, (original as NSString).length)))
            check(text.selectedRange().location == 0 && text.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilitySelectedTextRange:")), "Read-only AX permits native selection writes")
            text.accessibilitySetValue(NSValue(range: NSRange(location: 1, length: 1)), forAttribute: .selectedTextRange)
            check(text.selectedRange() == NSRange(location: 1, length: 1), "Legacy AX selection writes use the native selection without recursion")
            text.setAccessibilitySelectedTextRanges([NSValue(range: NSRange(location: 2, length: 1))])
            check(text.selectedRange() == NSRange(location: 2, length: 1), "Modern AX ranges use the native selection without recursion")
            check(!text.accessibilityPerformConfirm() && !text.accessibilityPerformIncrement(), "Native text exposes no invented confirm or increment actions")
        }
        let nativePress = class_getInstanceMethod(NSButton.self, NSSelectorFromString("accessibilityPerformPress"))!
        for view in [transcript, formView, elicitationView, streamView] {
            check(descendants(view).compactMap { $0 as? NSButton }.allSatisfy { button in
                guard let cls = object_getClass(button), let own = class_getInstanceMethod(cls, NSSelectorFromString("accessibilityPerformPress")) else { return false }
                return method_getImplementation(own) != method_getImplementation(nativePress)
            }, "Transcript buttons guard AppKit AX Press with current presentation visibility")
        }
        check(descendants(allView).compactMap { $0 as? NativeTranscriptRow }.allSatisfy { $0.accessibilityRole() == .group && $0.accessibilityLabel()?.isEmpty == false }, "AX row groups have readable native labels")
        for (name, view) in [("all-rows", allView), ("question", formView), ("elicitation", elicitationView), ("styled-flight", flightView)] {
            for scale: CGFloat in [1, 2] {
                let captured = view.snapshot(scale: scale)
                let rep = VerificationRaster.bitmap(width: captured.width, height: captured.height)
                rep.size = view.bounds.size; memset(rep.bitmapData!, 0, rep.bytesPerRow * rep.pixelsHigh)
                view.cacheDisplay(in: view.bounds, to: rep)
                check(pixels(captured) == pixels(rep.cgImage!), "\(name) viewport equals its own cache at \(Int(scale))x")
                try NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(Int(scale))x.png"))
                let canvas = CGContext(data: nil, width: captured.width, height: captured.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                canvas.setFillColor(CGColor(gray: 0.12, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: captured.width, height: captured.height))
                canvas.draw(captured, in: CGRect(x: 0, y: 0, width: captured.width, height: captured.height))
                try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-canvas-\(Int(scale))x.png"))
            }
        }

        let composer = NativeComposer()
        composer.frame = CGRect(x: 0, y: 0, width: 500, height: 80); composer.layoutSubtreeIfNeeded()
        var sends = 0, cancels = 0
        composer.onSend = { _ in sends += 1 }; composer.onCancel = { cancels += 1 }
        let editor = composer.textView, undo = editor.undoManager!
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)!
        }
        _ = composer.setText("ready", clearUndo: true)
        editor.keyDown(with: key(36, "\r", modifiers: .capsLock))
        check(sends == 1, "Caps Lock Return sends once")
        editor.keyDown(with: key(36, "\r", modifiers: .command))
        check(sends == 1 && composer.text.contains("\n"), "Command Return inserts a newline")
        for (code, chars): (UInt16, String) in [(36, "\r"), (53, "\u{1b}"), (49, " ")] {
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let before = composer.text
            composer.frame.size.width = 360; composer.layoutSubtreeIfNeeded(); composer.measureNow()
            check(editor.hasMarkedText() && composer.text == before && editor.undoManager === undo, "Resize retains marked text and Undo")
            check(!composer.setText("external replacement"), "External updates cannot replace composition")
            editor.keyDown(with: key(code, chars))
            check(sends == 1 && cancels == 0, "Marked Return/Escape/Space stays with the input method: \(code)")
            editor.unmarkText()
        }
        _ = composer.setText("", clearUndo: true)
        undo.groupsByEvent = false; undo.beginUndoGrouping()
        editor.insertText("Undo specimen", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping(); undo.undo()
        check(composer.text.isEmpty, "Native edit Undo")
        undo.redo(); check(composer.text == "Undo specimen", "Native edit Redo")
        // Full-bar composer: exercise actual controls and the common keyboard/action gates offscreen.
        let fullBar = NativeComposer()
        fullBar.targetWidth = 563
        fullBar.frame = CGRect(x: 0, y: 0, width: 563, height: 48)
        fullBar.layoutSubtreeIfNeeded(); fullBar.measureNow()
        check(fullBar.placeholder == "Message…" && fullBar.measuredHeight == 48, "Full bar uses product placeholder and fixed height")
        var submissions: [NativeComposerSubmission] = []
        fullBar.onSubmit = { submissions.append($0) }
        check(!fullBar.submit() && !fullBar.canSend, "Empty draft cannot submit")
        _ = fullBar.setText(" \n ")
        check(!fullBar.submit(), "Whitespace-only draft cannot submit")
        let imageAttachment = Attachment(id: "photo", name: "设计稿.png", symbol: "photo", url: URL(fileURLWithPath: "/tmp/设计稿.png"), mimeType: "image/png")
        var attachmentChanges = 0
        fullBar.onAttachmentsChange = { _ in attachmentChanges += 1 }
        fullBar.onChooseAttachments = { completion in completion([imageAttachment]) }
        fullBar.chooseAttachments(); fullBar.layoutSubtreeIfNeeded()
        check(fullBar.attachments == [imageAttachment] && attachmentChanges == 1, "Attachment picker completion adds real chips and publishes")
        check(fullBar.attachmentChips.count == 1 && fullBar.attachmentChips[0].removeButton.accessibilityLabel() == "Remove 设计稿.png", "Attachment chip has named native removal control")
        check(!fullBar.sendButton.isHidden && fullBar.canSend, "Attachment-only message exposes Send instead of Voice")
        check(fullBar.submit(followUp: .queue) && submissions.last?.action == .send, "Idle follow-up override still sends immediately")
        let attachmentRequest = submissions.last!
        check(attachmentRequest.attachments == [imageAttachment] && !fullBar.submit(), "Pending send captures attachments and blocks repeat")
        check(!fullBar.sendingIndicator.isHidden, "Pending typed submission shows sending spinner")
        check(fullBar.completeSubmission(attachmentRequest.id, outcome: .failed("Upload failed")), "Failed send acknowledges matching request")
        check(fullBar.text == " \n " && fullBar.attachments == [imageAttachment] && fullBar.canSend, "Failed send retains recoverable draft and attachment")
        check(!fullBar.completeSubmission(attachmentRequest.id, outcome: .accepted), "Duplicate acknowledgement cannot clear a draft")
        fullBar.attachmentChips[0].removeButton.performClick(nil)
        check(fullBar.attachments.isEmpty && attachmentChanges == 2, "Native chip removal updates attachments")

        _ = fullBar.setText("follow up", clearUndo: true)
        fullBar.state.running = true; fullBar.activeTurnID = "active-turn"
        check(fullBar.placeholder == "Steer or queue…" && fullBar.effectiveAction == .steer, "Running placeholder and default Steer")
        fullBar.followUpDefault = .queue
        fullBar.textView.keyDown(with: key(36, "\r"))
        let queueRequest = submissions.last!
        check(queueRequest.action == .queue && queueRequest.waitingForTurnID == "active-turn", "Keyboard follows Queue default and captures predecessor")
        let savedModel = queueRequest.settings, savedAccess = queueRequest.access
        fullBar.setAccess(.full)
        var editedSettings = fullBar.settings; editedSettings.modelID = "g6astra"; editedSettings.effort = .ultra
        fullBar.setSettings(editedSettings)
        check(queueRequest.settings == savedModel && queueRequest.access == savedAccess, "Pending submission has independent settings and permission snapshot")
        _ = fullBar.completeSubmission(queueRequest.id, outcome: .accepted)
        check(fullBar.text.isEmpty, "Accepted unedited draft clears through native editing")
        _ = fullBar.setText("steer")
        check(fullBar.submit(followUp: .steer) && submissions.last?.action == .steer, "M2 can submit per-message Steer override")
        let steerRequest = submissions.last!
        fullBar.textView.insertText(" later", replacementRange: NSRange(location: 5, length: 0))
        _ = fullBar.completeSubmission(steerRequest.id, outcome: .accepted)
        check(fullBar.text == "steer later", "A late acceptance preserves newer typing")
        check(fullBar.submit(), "Newer draft can submit after acknowledgement")
        let uncertain = submissions.last!
        _ = fullBar.completeSubmission(uncertain.id, outcome: .outcomeUnknown("Timeout"))
        check(!fullBar.canSend && !fullBar.submit() && fullBar.text == "steer later", "Ambiguous send blocks blind resend without losing content")
        fullBar.state.outcomeUnknown = false
        for status in 0..<4 {
            fullBar.state.online = status != 0; fullBar.state.loading = status == 1
            fullBar.state.sending = status == 2; fullBar.state.stopping = status == 3
            let count = submissions.count
            fullBar.sendButton.performClick(nil); fullBar.textView.keyDown(with: key(36, "\r"))
            check(!fullBar.canSend && submissions.count == count, "Button and keyboard share blocked state \(status)")
        }
        fullBar.state = NativeComposerState(running: true)
        var stops = 0; fullBar.onStop = { stops += 1 }
        fullBar.textView.keyDown(with: key(47, ".", modifiers: .command))
        check(stops == 1 && !fullBar.requestStop() && !fullBar.canSend, "Stop shortcut latches stopping and blocks duplicate Stop and Send")
        check(!fullBar.stoppingIndicator.isHidden, "Stop request shows stopping spinner")
        fullBar.completeStopRequest(); fullBar.state.online = false
        check(fullBar.requestStop() && stops == 2, "Offline Stop remains a host callback instead of claiming completion")
        fullBar.completeStopRequest(); fullBar.state = NativeComposerState()
        fullBar.sendShortcut = .init(keyCode: 36, modifiers: [.command, .shift])
        _ = fullBar.setText("custom shortcut")
        fullBar.textView.keyDown(with: key(36, "\r", modifiers: [.command, .shift, .capsLock]))
        check(submissions.last?.text == "custom shortcut", "Configured shortcut ignores Caps Lock")
        _ = fullBar.completeSubmission(submissions.last!.id, outcome: .failed("Retry"))
        fullBar.sendShortcut = nil

        // Every geometry/state mutation while marked must retain the same input context and Undo root.
        fullBar.layoutSubtreeIfNeeded(); fullBar.measureNow()
        let fullEditor = fullBar.textView, fullUndo = fullBar.textView.undoManager!
        fullEditor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedString = fullBar.text, markedSelection = fullEditor.selectedRange(), editorFrame = fullEditor.frame
        let clipFrame = fullBar.scrollView.frame, containerWidth = fullEditor.textContainer!.containerSize.width
        let markedRange = fullEditor.markedRange(), oldInset = fullEditor.textContainerInset
        let oldHeight = fullBar.measuredHeight
        var heightCallbacks = 0; fullBar.onHeightChange = { _ in heightCallbacks += 1 }
        fullBar.frame.size = CGSize(width: 320, height: 64); fullBar.targetWidth = 760
        fullBar.fixedHeight = 64; fullBar.state = NativeComposerState(running: true, sending: true, online: false)
        fullBar.isEnabled = false; fullBar.placeholder = "Deferred placeholder"; fullBar.attachments = [imageAttachment]
        fullBar.layoutMode = .growing; fullBar.maximumHeight = 120
        fullBar.layoutSubtreeIfNeeded(); fullBar.measureNow()
        fullEditor.setAccessibilityValue("AX must not interrupt marked text")
        check(fullBar.isComposing && fullBar.text == markedString && fullEditor.markedRange() == markedRange, "All state and AX mutations preserve marked text")
        check(fullEditor.selectedRange() == markedSelection && fullEditor.undoManager === fullUndo && fullEditor.isEditable, "Marked state retains selection, Undo and editability")
        check(fullEditor.frame == editorFrame && fullBar.scrollView.frame == clipFrame && fullEditor.textContainer!.containerSize.width == containerWidth && fullEditor.textContainerInset == oldInset, "Marked resize freezes internal geometry and TextKit width")
        check(fullBar.measuredHeight == oldHeight && heightCallbacks == 0 && !fullBar.submit() && !fullBar.requestStop(), "Marked text blocks height publication, Send and Stop")
        check(!fullBar.setText("replacement") && !fullBar.removeAttachment(id: "photo"), "Marked text blocks external replacement and chip action")
        fullEditor.unmarkText()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        fullBar.layoutSubtreeIfNeeded(); fullBar.measureNow()
        check(!fullEditor.isEditable && fullEditor.placeholder == "Deferred placeholder" && fullBar.scrollView.frame != clipFrame, "Deferred state and geometry apply after composition ends")
        fullBar.isEnabled = true; fullBar.state = NativeComposerState(); fullBar.layoutMode = .fullBar; fullBar.fixedHeight = 48
        fullBar.useAutomaticPlaceholder(); fullBar.attachments = []
        _ = fullBar.setText(String(repeating: "line 中文 👩🏽‍💻\n", count: 40), clearUndo: true)
        fullBar.frame.size = CGSize(width: 563, height: 48); fullBar.targetWidth = 563
        fullBar.layoutSubtreeIfNeeded(); fullBar.measureNow()
        check(fullBar.measuredHeight == 48 && fullEditor.frame.height > fullBar.scrollView.contentSize.height, "Long multiline text scrolls inside fixed full bar")
        fullBar.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 100))
        _ = fullBar.setText("short"); fullBar.measureNow()
        check(fullBar.scrollView.contentView.bounds.origin == .zero, "Shrinking draft resets clip origin")
        fullBar.layoutMode = .growing; fullBar.minimumHeight = 36; fullBar.maximumHeight = 120
        _ = fullBar.setText(String(repeating: "line\n", count: 40)); fullBar.measureNow()
        check(fullBar.measuredHeight == 120, "Optional growing mode clamps maximum height")
        fullBar.layoutMode = .fullBar
        fullBar.state = NativeComposerState(sending: true)
        _ = fullBar.setText(""); fullBar.layoutSubtreeIfNeeded()
        check(!fullBar.sendButton.isHidden && !fullBar.sendingIndicator.isHidden && fullBar.voiceButton.isHidden, "Empty sending draft retains spinner instead of switching to Voice")
        fullBar.state = NativeComposerState()
        fullBar.placeholder = "Explicit placeholder"
        _ = fullBar.setText("")
        check(fullEditor.accessibilityPlaceholderValue() == "Explicit placeholder" && fullEditor.accessibilityLabel() == "Message draft", "Native AX publishes placeholder and editable draft label")
        _ = fullBar.setText("", clearUndo: true)
        fullUndo.groupsByEvent = false; fullUndo.beginUndoGrouping()
        fullEditor.setAccessibilityValue("AX draft 中文")
        fullUndo.endUndoGrouping()
        check(fullBar.text == "AX draft 中文" && fullEditor.accessibilityValue() == "AX draft 中文", "Native AX value reads and writes actual draft")
        fullUndo.undo(); check(fullBar.text.isEmpty, "AX draft edit participates in native Undo")
        fullUndo.redo(); check(fullBar.text == "AX draft 中文", "AX draft edit participates in native Redo")
        fullBar.state.running = true; fullBar.followUpDefault = .queue
        check(fullBar.sendButton.accessibilityLabel() == "Queue", "AX Send label reflects Queue action")
        fullBar.state.running = false
        fullBar.contextPercent = nil; fullBar.contextSummary = "Remote · Context usage has not been reported"
        check(fullBar.contextButton.accessibilityLabel()?.contains("not been reported") == true, "Unknown context is explicit in native AX")

        _ = fullBar.setText("")
        var recoveredSettings = ModelSettings(); recoveredSettings.modelID = "g6luna"
        fullBar.queued = [.init(id: "failed-queue", text: "Recovered 中文", attachments: [imageAttachment], settings: recoveredSettings, access: .readOnly, deliveryError: "Previous turn stopped"), .init(id: "later-queue", text: "Later", waitingForTurnID: "old-turn")]
        _ = fullBar.setText("new draft")
        check(!fullBar.restoreQueued(id: "failed-queue") && fullBar.text == "new draft", "Queue recovery cannot overwrite a later draft")
        _ = fullBar.setText("")
        check(fullBar.restoreQueued(id: "failed-queue") && fullBar.text == "Recovered 中文" && fullBar.attachments == [imageAttachment], "Failed queue restores text and attachments")
        check(fullBar.settings == recoveredSettings && fullBar.access == .readOnly && fullBar.queued.first?.deliveryError != nil, "Queue recovery restores configuration and blocks later automatic release")

        let sessions = NativeComposerSessions()
        let firstConversation = Conversation(id: "composer-one", title: "One"), secondConversation = Conversation(id: "composer-two", title: "Two")
        firstConversation.draft = "First"; secondConversation.draft = "Second"
        let firstComposer = sessions.composer(for: firstConversation), secondComposer = sessions.composer(for: secondConversation)
        check(firstComposer !== secondComposer && firstComposer.textView.undoManager !== secondComposer.textView.undoManager, "Conversations have independent editor and Undo roots")
        let firstUndo = firstComposer.textView.undoManager!; firstUndo.groupsByEvent = false; firstUndo.beginUndoGrouping()
        firstComposer.textView.insertText(" edit", replacementRange: NSRange(location: 5, length: 0)); firstUndo.endUndoGrouping()
        firstUndo.undo()
        check(firstComposer.text == "First" && secondComposer.text == "Second" && firstConversation.draft == "First", "Undo only changes its conversation draft")
        firstUndo.redo(); check(firstComposer.text == "First edit", "Per-conversation Redo survives lookup")
        check(sessions.composer(for: firstConversation) === firstComposer && !firstComposer.bind(to: secondConversation), "Session lookup retains editor and rejects cross-conversation rebinding")
        let boundStore = ConversationStore()
        let boundConversation = Conversation(id: "pending-refresh", title: "Pending")
        boundConversation.draft = "Initial"; boundStore.add(boundConversation)
        let boundComposer = NativeComposer(conversation: boundConversation, store: boundStore)
        var boundRequest: NativeComposerSubmission?
        boundComposer.onSubmit = { boundRequest = $0 }
        check(boundComposer.submit(), "Bound composer starts typed submission")
        boundComposer.textView.insertText(" newer", replacementRange: NSRange(location: 7, length: 0))
        boundComposer.attachments = [imageAttachment]
        boundConversation.draft = ""; boundConversation.attachments = []
        boundStore.changed(boundConversation)
        check(boundComposer.text == "Initial newer" && boundComposer.attachments == [imageAttachment], "Pending store refresh cannot erase newer draft or attachments")
        _ = boundComposer.completeSubmission(boundRequest!.id, outcome: .failed("Offline"))
        check(boundConversation.draft == "Initial newer" && boundConversation.attachments == [imageAttachment], "Failed send restores the retained draft into its bound model")
        boundComposer.textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let boundMarked = boundComposer.text
        boundConversation.draft = "stale snapshot"; boundStore.changed(boundConversation)
        check(boundComposer.text == boundMarked && boundConversation.draft == boundMarked && boundComposer.isComposing, "Bound store refresh preserves current marked draft and repairs stale model text")
        boundComposer.textView.unmarkText()
        let fresh = sessions.draft(); _ = fresh.composer.setText("Promote")
        let promoted = Conversation(id: "promoted", title: "Promoted")
        check(sessions.promoteDraft(fresh.token, to: promoted) === fresh.composer && promoted.draft == "Promote", "First-send promotion retains exact editor and draft")
        let nextDraft = sessions.draft()
        check(nextDraft.composer !== fresh.composer && nextDraft.composer.text.isEmpty && nextDraft.composer.textView.undoManager !== fresh.composer.textView.undoManager, "New draft generation starts with independent text and Undo")
        check(!sessions.isCurrentDraft(fresh.token) && sessions.promoteDraft(fresh.token, to: secondConversation) == nil && !sessions.discardDraft(fresh.token), "Stale draft tokens cannot mutate the next generation")
        check(sessions.discardDraft(nextDraft.token), "Current empty draft can be explicitly discarded")

        fullBar.targetWidth = 760; fullBar.frame.size.width = 760; fullBar.layoutSubtreeIfNeeded()
        let wideModelTitle = fullBar.modelButton.itemTitle(at: 0)
        fullBar.frame.size.width = 418; fullBar.layoutSubtreeIfNeeded()
        check(!fullBar.dictationButton.isHidden && fullBar.modelButton.itemTitle(at: 0) == wideModelTitle, "Animation width crossing density threshold does not switch controls")

        // §7.5 composer regression: the entire reused tree, including attachment chips.
        let composerDrawIssues = uncapturedTextControls(fullBar).filter { !($0 is NSImageView) }
        check(composerDrawIssues.isEmpty, "Composer text controls all override draw: \(composerDrawIssues.map { String(describing: type(of: $0)) })")
        check(descendants(fullBar).allSatisfy { v in
            if let b = v as? NSButton { return !b.isBordered }
            if let f = v as? NSTextField { return !f.isBordered && !f.isBezeled }
            return true
        }, "Composer has no system bezels")
        for button in [fullBar.accessButton, fullBar.modelButton, fullBar.queueButton] {
            check(type(of: button) != NSPopUpButton.self && button.accessibilityRole() == .popUpButton, "Menu button retains AX popup role without NSPopUpButton")
            check(button.menu?.autoenablesItems == false && button.menu?.item(at: 0)?.isHidden == true, "Menu retains explicit availability and hides presentation item")
        }
        let accessItem = fullBar.accessButton.menu!.items.first { ($0.representedObject as? String) == Access.full.rawValue }!
        _ = accessItem.target?.perform(accessItem.action, with: accessItem)
        check(fullBar.access == .full && fullBar.accessButton.menu!.items.contains { $0.state == .on && ($0.representedObject as? String) == Access.full.rawValue }, "Real permissions menu action updates selection and checkmark")
        for scale: CGFloat in [1, 2] {
            fullBar.verificationScale = scale
            fullBar.frame.size = CGSize(width: 563.25, height: 49.25); fullBar.targetWidth = 563.25
            fullBar.needsLayout = true; fullBar.layoutSubtreeIfNeeded()
            let controls: [NSView] = [fullBar.sendButton, fullBar.attachButton, fullBar.stopButton, fullBar.dictationButton, fullBar.voiceButton, fullBar.contextButton, fullBar.accessButton, fullBar.modelButton, fullBar.queueButton, fullBar.voiceTextLabel]
            check(controls.filter { !$0.isHidden }.allSatisfy { v in [v.frame.minX, v.frame.minY, v.frame.width, v.frame.height].allSatisfy { abs($0*scale-($0*scale).rounded()) < 0.0001 } }, "Composer controls align to backing grid at \(scale)x")
            let image = VerificationRaster.capture(fullBar, scale: scale)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("composer-75-\(Int(scale))x.png"))
        }
        fullBar.verificationScale = nil

        // Render actual AppKit controls at representative target widths; no NSWindow is allocated.
        fullBar.state = NativeComposerState(running: true); fullBar.attachments = [imageAttachment]; fullBar.queued = []
        fullBar.onStop = {}; _ = fullBar.setText("继续说点什么，或者 @ 一个文件")
        for width: CGFloat in [320, 418, 563, 760] {
            fullBar.frame.size = CGSize(width: width, height: 48); fullBar.targetWidth = width
            fullBar.layoutSubtreeIfNeeded(); fullBar.measureNow()
            check(fullBar.scrollView.frame.width > 0 && fullBar.scrollView.frame.maxX <= width, "Editor remains usable at target width \(width)")
            check(fullBar.dictationButton.isHidden == (width < 440), "Tight-width dictation rule at \(width)")
            let rep = VerificationRaster.bitmap(width: Int(width * 2), height: 96)
            rep.size = fullBar.bounds.size
            memset(rep.bitmapData!, 0, rep.bytesPerRow * rep.pixelsHigh)
            fullBar.cacheDisplay(in: fullBar.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("composer-\(Int(width))-2x.png"))
            check(fullBar.attachmentChips[0].removeButton.frame.maxX <= fullBar.attachmentScrollView.contentSize.width, "First chip removal stays visible at \(width)")
            check(fullBar.attachmentChips[0].label.frame.width > 0 && fullBar.attachmentChips[0].removeButton.frame.width > 0, "Attachment chip lays out its native text and action at \(width)")
            check(fullBar.textView.frame.origin == .zero, "Editor document stays top anchored after resize at \(width)")
            check(fullBar.scrollView.contentView.bounds.origin.y <= max(0, fullBar.textView.frame.height - fullBar.scrollView.contentSize.height), "Resized viewport clamps old scroll offset at \(width)")
            let canvas = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(CGColor(gray: 0.12, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            canvas.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("composer-\(Int(width))-canvas-2x.png"))
        }
        // f082: rich Edit/Fork requests freeze original text and exact prefix, while editing the retained draft.
        let actionConversation=Conversation(id:"message-actions",title:"Message actions")
        let previous=TranscriptItem(id:"before",turnID:"t0",kind:.assistant,text:"Existing history")
        let current=TranscriptItem(id:"current",turnID:"t1",kind:.user,text:"**Raw** 中文\\nSecond line",timestamp:Date(timeIntervalSince1970:1234))
        let later=TranscriptItem(id:"after",turnID:"t1",kind:.assistant,text:"Later history")
        actionConversation.items=[previous,current,later]
        let actionComposer=NativeComposer(conversation:actionConversation)
        actionComposer.frame=CGRect(x:0,y:0,width:640,height:48)
        let actionTranscript=NativeTranscript(conversation:actionConversation)
        actionTranscript.frame=CGRect(x:0,y:0,width:640,height:600)
        actionTranscript.messageDraftTarget=actionComposer
        var messageActions:[NativeUserMessageAction]=[]
        actionTranscript.onUserMessageAction={messageActions.append($0)}
        check(actionTranscript.performUserMessageAction(.edit,itemID:current.id),"Edit admits an original user message")
        check(actionComposer.text == current.text && actionConversation.draft == current.text,"Edit stages raw source text in the retained composer")
        check(actionConversation.items == [previous,current,later],"Edit does not rewrite source history")
        check(actionTranscript.performUserMessageAction(.fork,itemID:current.id),"Fork emits an unsent host request")
        check(messageActions.last?.historyBefore == [previous] && messageActions.last?.message == current && messageActions.last?.draftText == current.text,"Fork carries exact prefix and pending message")
        check(!actionTranscript.performUserMessageAction(.fork,itemID:later.id),"Assistant rows cannot be forked as a user message")
        actionComposer.textView.setMarkedText("拼",selectedRange:NSRange(location:1,length:0),replacementRange:actionComposer.textView.selectedRange())
        let composingDraft=actionComposer.text
        check(!actionTranscript.performUserMessageAction(.edit,itemID:current.id) && actionComposer.text == composingDraft,"Edit cannot overwrite an IME-owned draft")
        actionComposer.textView.unmarkText()
        actionTranscript.isHidden=true
        check(!actionTranscript.performUserMessageAction(.edit,itemID:current.id),"Hidden transcript cannot issue message callbacks")
        actionTranscript.isHidden=false
        check(elicitationView.elicitationExchanges[elicitation.id]?.request.request == elicitation.request && elicitationView.elicitationExchanges[elicitation.id]?.response == values.first,"Elicitation ledger preserves raw Core request and exact response")
        let emptyForm=Conversation(id:"empty-schema",title:"Empty schema")
        emptyForm.isLiveConversation=true
        let emptyApproval=Approval(id:"empty-form",title:"Empty form",command:"Explicit consent",note:"",acceptLabel:"Accept",toolItemID:"",method:"elicitation/create",request:["id":17,"params":["requestedSchema":["type":"object","properties":[:],"required":[]]]])
        emptyForm.approvals=[emptyApproval]
        let emptyView=NativeTranscript(conversation:emptyForm);emptyView.frame=CGRect(x:0,y:0,width:500,height:500)
        var emptyResponses:[JSONValue]=[];emptyView.onApprovalValue={_,response in emptyResponses.append(response)}
        check(descendants(emptyView).compactMap{$0 as? NSTextField}.contains{$0.isEditable && $0.stringValue == "{}"},"Empty schema still shows a JSON object editor")
        check(emptyResponses.isEmpty,"A valid empty object never accepts automatically")
        check(click("Decline",in:emptyView) && emptyResponses == [["action":"decline"]],"Decline preserves the content-free Core response")
        check(emptyView.elicitationExchanges[emptyApproval.id]?.request.request["id"] == 17,"Numeric original Core request ID is preserved")
        let secretSchema:JSONValue=["type":"object","properties":["token":["type":"string","writeOnly":true,"minLength":1]],"required":["token"]]
        check(CoreResponseValidation.approval(["action":"accept","content":[:]],request:Approval(id:"secret",title:"Secret",command:"",note:"",acceptLabel:"Allow",toolItemID:"",method:"elicitation/create",request:["params":["requestedSchema":secretSchema]])) != nil,"Core validator rejects missing required secret fields")

        // f198: windowless screen-space fixture. No NSWindow is made or shown.
        let axParent=NativeFlippedView(frame:CGRect(x:0,y:0,width:360,height:260))
        let surface=NativeInteractionSurface(frame:CGRect(x:0,y:0,width:240,height:160))
        surface.verificationAXScreenOrigin=CGPoint(x:100,y:200);axParent.addSubview(surface)
        surface.presentationClip=CGRect(x:20,y:10,width:100,height:70)
        let legacy=NativeVerificationLegacyAX("row",frame:CGRect(x:110,y:205,width:180,height:60))
        let legacyProxy=surface.proxy(legacy,parent:surface)!
        check(legacyProxy.accessibilityFrame() == CGRect(x:120,y:210,width:100,height:55),"AX frame is clipped to the effective viewport")
        let equivalent=NativeVerificationLegacyAX("row",frame:legacy.rect)
        check(surface.proxy(equivalent,parent:surface) === legacyProxy,"AX cache follows NSObject equality rather than pointer address")
        check(legacyProxy.accessibilityParent() as? NativeInteractionSurface === surface,"AX canonical parent remains the presentation surface")
        check(legacyProxy.accessibilityPerformPress() && legacy.presses == 1,"Visible legacy AX Press forwards exactly once")
        surface.isHidden=true
        check(legacyProxy.accessibilityFrame().isEmpty && !legacyProxy.accessibilityPerformPress(),"Hidden surface withdraws frame and old AX action")
        surface.isHidden=false
        check(!legacyProxy.accessibilityPerformPress(),"Showing again cannot revive an old AX object")
        let shownProxy=surface.proxy(legacy,parent:surface)!
        check(shownProxy !== legacyProxy && shownProxy.accessibilityPerformPress(),"A new presentation supplies a fresh live proxy")
        surface.presentationActive=false
        check(surface.accessibilityChildren()?.isEmpty == true && surface.hitTest(CGPoint(x:30,y:20)) == nil && !shownProxy.accessibilityPerformPress(),"Withdrawal removes AX, hit testing and stale actions")
        surface.presentationActive=true
        let modeProxy=surface.proxy(legacy,parent:surface)!
        surface.presentationContext="brief"
        check(!modeProxy.accessibilityPerformPress(),"Window/form context changes revoke old AX")
        let clippedProxy=surface.proxy(legacy,parent:surface)!
        surface.presentationClip=CGRect(x:220,y:140,width:10,height:10)
        check(clippedProxy.accessibilityFrame().isEmpty && !clippedProxy.accessibilityPerformPress(),"Completely clipped content cannot act")
        surface.presentationClip=nil
        let ancestorProxy=surface.proxy(legacy,parent:surface)!
        axParent.isHidden=true;axParent.isHidden=false
        check(!ancestorProxy.accessibilityPerformPress(),"Ancestor hide/unhide cannot resurrect old descendants")
        let alphaProxy=surface.proxy(legacy,parent:surface)!
        axParent.alphaValue=0;axParent.alphaValue=1
        check(!alphaProxy.accessibilityPerformPress(),"Ancestor opacity withdrawal revokes its lease")
        let parentProxy=surface.proxy(legacy,parent:surface)!
        surface.removeFromSuperview();axParent.addSubview(surface)
        check(!parentProxy.accessibilityPerformPress(),"Remount retires old AX objects")
        let windowProxy=surface.proxy(legacy,parent:surface)!
        surface.verificationWindowVisible=false
        check(windowProxy.accessibilityFrame().isEmpty && !windowProxy.accessibilityPerformPress() && surface.hitTest(CGPoint(x:30,y:20)) == nil,"hidden window admission withdraws AX and hits")
        surface.verificationWindowVisible=true
        check(!windowProxy.accessibilityPerformPress(),"restoring a window cannot revive its prior AX objects")
        let custom=NativeVerificationActionAX()
        let customProxy=surface.proxy(custom,parent:surface)!
        let exportedAction=customProxy.accessibilityCustomActions()!.first!
        check(exportedAction.handler?() == true && custom.invocations == 1,"Current custom AX action forwards its BOOL")
        surface.invalidateAccessibilityLease()
        check(exportedAction.handler?() == false && custom.invocations == 1,"Retained custom AX handler rejects a revoked lease")
        let declineProxy=surface.proxy(custom,parent:surface)!
        check(!declineProxy.accessibilityPerformPress(),"Modern source false is preserved instead of inventing Press")
        let composerParent=NativeFlippedView(frame:CGRect(x:0,y:0,width:740,height:120))
        let leased=NativeComposer();leased.frame=CGRect(x:0,y:0,width:640,height:48);leased.verificationAXScreenOrigin = .zero
        composerParent.addSubview(leased);leased.layoutSubtreeIfNeeded();leased.measureNow()
        let editorProxy=leased.proxy(leased.textView,parent:leased)!
        editorProxy.setAccessibilityValue("AX current draft")
        check(leased.text == "AX current draft","Current AX proxy edits the actual native draft")
        leased.layoutMode = .growing
        editorProxy.setAccessibilityValue("stale form")
        check(leased.text == "AX current draft","Full-bar to growing switch rejects stale editor writes")
        let growingProxy=leased.proxy(leased.textView,parent:leased)!
        leased.removeFromSuperview();composerParent.addSubview(leased)
        growingProxy.setAccessibilityValue("stale mount")
        check(leased.text == "AX current draft","Normie/Organic remount rejects stale editor writes")
        let hiddenEditor=leased.proxy(leased.textView,parent:leased)!
        leased.isHidden=true;leased.isHidden=false;hiddenEditor.setAccessibilityValue("stale hidden")
        check(leased.text == "AX current draft","Hidden/shown composer does not revive old editor AX")
        let pendingDraft=sessions.draft(),draftView=pendingDraft.composer
        draftView.frame=CGRect(x:0,y:0,width:640,height:48);draftView.verificationAXScreenOrigin = .zero;draftView.layoutSubtreeIfNeeded();draftView.measureNow()
        let oldDraftAX=draftView.proxy(draftView.textView,parent:draftView)!
        let promotion=Conversation(id:"ax-promotion",title:"Promotion")
        _ = sessions.promoteDraft(pendingDraft.token,to:promotion)
        oldDraftAX.setAccessibilityValue("stale pre-promotion")
        check(promotion.draft != "stale pre-promotion","Draft promotion revokes the previous AX identity")
        check(transcript.window == nil && composer.window == nil && NSApp.windows.allSatisfy { !$0.isVisible }, "Verification uses unattached views and opens no windows")
        try NativeM8Verification.run(output:output,check:{check($0,$1)})
        try NativeAXLookVerification.run(output:output,check:{check($0,$1)})
        try NativeTranscriptOwnerVerification.run(output:output,check:{check($0,$1)})
        NativeRecoveryVerification.run(check:{check($0,$1)})
        NativeVoiceVerification.run(check:{check($0,$1)})
        try NativeComponentFixVerification.run(output:output,check:{check($0,$1)})
        let report = (["M1 verification: \(checks) checks, \(failures.count) findings -> \(output.path)"] + failures.map { "  " + $0 } + diagnostics).joined(separator: "\n") + "\n"
        try report.write(to: output.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        print(report, terminator: "")
        if !failures.isEmpty { exit(1) }
    }
}
private final class NativeVerificationLegacyAX:NSObject {
    let key:String
    var rect:CGRect,presses=0
    init(_ key:String,frame:CGRect){self.key=key;rect=frame;super.init()}
    override var hash:Int{key.hashValue}
    override func isEqual(_ object:Any?)->Bool{(object as? NativeVerificationLegacyAX)?.key == key}
    override func accessibilityAttributeValue(_ attribute:NSAccessibility.Attribute)->Any? {
        switch attribute{case .role:return "AXRow";case .position:return NSValue(point:rect.origin);case .size:return NSValue(size:rect.size);case .children:return [];default:return nil}
    }
    override func accessibilityActionNames()->[NSAccessibility.Action]{[.press]}
    override func accessibilityPerformAction(_ action:NSAccessibility.Action){if action == .press{presses+=1}}
}
@MainActor private final class NativeVerificationActionAX:NSAccessibilityElement, @unchecked Sendable {
    var invocations=0
    override func accessibilityFrame()->NSRect{CGRect(x:120,y:220,width:50,height:30)}
    override func accessibilityRole()->NSAccessibility.Role?{.button}
    override func accessibilityCustomActions()->[NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name:"Exact action",handler:{[weak self] in self?.invoke() ?? false})]
    }
    private nonisolated func invoke()->Bool {
        let box=NativeVerificationTransfer(value:self)
        return MainActor.assumeIsolated{box.value.invocations+=1;return true}
    }
    override func accessibilityPerformPress()->Bool{false}
}
private struct NativeVerificationTransfer<Value>:@unchecked Sendable{let value:Value}
#endif
