#if M1_SELFTEST || NATIVE_STREAM_BENCHMARK
import AppKit

@MainActor enum NativeTranscriptVirtualVerification {
    @inline(never) private static func optimizedBuild() -> Bool { !_isDebugAssertConfiguration() }
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        let saved = NativeAppearance.current; NativeAppearance.apply(.init()); defer { NativeAppearance.apply(saved) }
        check(Thread.isMainThread, "Virtual timings execute on the main thread")
        let c = Conversation(id: "virtual-2007", title: "Synthetic long history")
        let paragraph = "A **markdown** answer with `inline code`, a wrapped explanation and 中文 glyphs. "
        c.items = (0..<2007).map { i in
            let kind: RowKind
            let text: String
            switch i % 5 {
            case 0: kind = .user; text = "Question \(i): keep this history readable."
            case 1: kind = .assistant; text = "Answer \(i).\n" + String(repeating: paragraph, count: 22) + "\n```swift\nlet value = 42\n```\n- A final bullet."
            case 2: kind = .tool(.command); text = "printf 'recorded-\(i)'\n" + String(repeating: "recorded output\n", count: 12)
            case 3: kind = .reasoning; text = String(repeating: "Recorded reasoning \(i). ", count: 40)
            default: kind = .notice(.info); text = "Sources/View\(i).swift  +12 −3"
            }
            return TranscriptItem(id: "virtual-\(i)", turnID: "turn-\(i / 5)", kind: kind, text: text,
                status: i % 5 == 4 ? TranscriptPresentation.changesStatus : nil)
        }
        let transcript = NativeTranscript(conversation: c)
        let start = CACurrentMediaTime()
        // setFrameSize performs the first layout/refresh. Include that work, rather than timing a warmed no-op.
        transcript.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        transcript.refresh(preservingOffset: false)
        let initialMS = (CACurrentMediaTime() - start) * 1000
        let coldExact = transcript.exactHeightCount, coldMounted = transcript.mountedRowCount
        let counts = Dictionary(uniqueKeysWithValues: c.items.map { ($0.id, transcript.rowConfigurationCount(itemID: $0.id)) })
        let last = c.items.count - 1
        c.items[last].text += " Another streamed delta."; c.items[last].revision += 1; c.revision += 1
        let deltaStart = CACurrentMediaTime(); transcript.refresh()
        let deltaMS = (CACurrentMediaTime() - deltaStart) * 1000
        check(coldExact < 100 && coldMounted < 100, "Virtual cold load measures/mounts a bounded viewport, not 2007 cells")
        check(transcript.rowConfigurationCount(itemID: c.items[last].id) == counts[c.items[last].id]! + 1, "Virtual streaming reconfigures the changed last row")
        check(c.items.dropLast().allSatisfy { transcript.rowConfigurationCount(itemID: $0.id) == counts[$0.id] }, "Virtual streaming leaves every unchanged row configuration alone")
        check(transcript.isAtEnd, "Virtual streaming at end keeps bottom follow")
        if optimizedBuild() {
            check(initialMS <= 150, "Virtual release first refresh <= 150 ms")
            check(deltaMS <= 16, "Virtual release delta refresh <= 16 ms")
        }
        var readings: [String] = []
        func alphaCount(_ image: CGImage) -> Int {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            return stride(from: 3, to: image.width * image.height * 4, by: 4).reduce(0) { $0 + (bytes[$1] > 0 ? 1 : 0) }
        }
        transcript.verificationAXScreenOrigin = CGPoint(x: 100, y: 100)
        for (name, offset) in [("top", CGFloat(0)), ("middle", transcript.contentHeight / 2), ("end", transcript.contentHeight)] {
            transcript.scrollOffset = CGPoint(x: 0, y: offset)
            if name == "end" { transcript.scrollToEnd() }
            else { check(transcript.scrollOffset.y == floor(offset), "Virtual explicit \(name) offset writes retain their backing-aligned pixel value") }
            let table = transcript.scrollView.documentView as! NativeTranscriptTable
            let visible = table.subviews.compactMap { $0 as? NativeTranscriptRow }.filter { $0.frame.intersects(transcript.scrollView.contentView.bounds) }
            check(transcript.mountedRowCount < 100 && transcript.pooledRowCount <= 20, "Virtual \(name) has bounded cells and pool")
            check(!visible.isEmpty && visible.allSatisfy { !$0.body.string.isEmpty }, "Virtual \(name) viewport has native text rows")
            check(!table.visibleRows.isEmpty && table.visibleRows.allSatisfy { $0.index == Int($0.key.dropFirst(5).split(separator: "-").last!) }, "Virtual \(name) AX rows keep global indexes")
            check(visible.allSatisfy { $0.frame.minY.rounded() == $0.frame.minY }, "Virtual \(name) cell origins stay on the pixel grid")
            for scale: CGFloat in [1, 2] {
                let image = transcript.snapshot(scale: scale)
                check(alphaCount(image) > 1000 && visible.contains { alphaCount(VerificationRaster.capture($0.body, scale: scale)) > 100 }, "Virtual \(name) \(Int(scale))x viewport and body render nonempty")
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("virtual-\(name)@\(Int(scale))x.png"))
            }
            readings.append("\(name): mounted=\(transcript.mountedRowCount), pool=\(transcript.pooledRowCount), offset=\(transcript.scrollOffset.y), height=\(transcript.contentHeight)")
        }
        transcript.scrollToItem(itemID: "virtual-1000")
        transcript.setSelectedRange(NSRange(location: 2, length: 8), itemID: "virtual-1000")
        let pinned = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "virtual-1000" }!
        let anchorY = pinned.frame.minY - transcript.scrollOffset.y
        c.items[1].text += String(repeating: paragraph, count: 5); c.items[1].revision += 1; c.revision += 1
        transcript.refresh()
        check(abs(pinned.frame.minY - transcript.scrollOffset.y - anchorY) < 1.01, "Virtual upstream edit preserves logical reading anchor")
        transcript.frame.size.width = 830
        check(abs(pinned.frame.minY - transcript.scrollOffset.y - anchorY) < 1.01, "Virtual width reflow preserves logical reading anchor")
        let beforeBatch = transcript.exactHeightCount
        transcript.refineColdHeights(budget: 0.0000001)
        check(transcript.exactHeightCount <= beforeBatch + 1, "Virtual tiny idle budget never traverses the full cold history")
        transcript.isHidden = true
        let hiddenExact = transcript.exactHeightCount; transcript.refineColdHeights(budget: 30)
        check(transcript.exactHeightCount == hiddenExact, "Virtual hidden presentations suspend cold measurement")
        transcript.isHidden = false
        let idleStart = CACurrentMediaTime(); transcript.refineColdHeights(budget: 30)
        let refinementMS = (CACurrentMediaTime() - idleStart) * 1000
        check(transcript.exactHeightCount == c.items.count, "Virtual idle measurement eventually makes every height exact without mounting history")
        check(abs(pinned.frame.minY - transcript.scrollOffset.y - anchorY) < 1.01, "Virtual cold-height refinement preserves logical reading anchor")
        transcript.scrollToEnd()
        check(pinned.superview != nil && pinned.item.id == "virtual-1000" && pinned.body.selectedRange() == NSRange(location: 2, length: 8), "Virtual offscreen selected row retains the same text view and selection")
        transcript.setSelectedRange(NSRange(location: 0, length: 0), itemID: "virtual-1000")
        transcript.scrollOffset = .zero
        check(!transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.contains { $0.item.id == "virtual-1000" }, "Virtual cleared offscreen selection releases the pinned cell")
        let topRow = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "virtual-0" }!
        let oldProxy = transcript.proxy(topRow.body, parent: transcript)!
        transcript.scrollToEnd()
        check(oldProxy.accessibilityFrame().isEmpty && oldProxy.accessibilityValue() == nil, "Virtual reuse retires exported AX leaves before reassigning cells")
        let beforeQuery = transcript.mountedRowCount, offsetBefore = transcript.scrollOffset, heightBefore = transcript.contentHeight
        let offscreenID = "virtual-501", raw = c.items[501].text as NSString
        let rawRange = raw.range(of: "markdown")
        let frames = transcript.glyphFrames(itemID: offscreenID, range: rawRange)
        let source = transcript.textSnapshot(itemID: offscreenID, scale: 2)
        check(!frames.isEmpty && source != nil, "Virtual offscreen markdown flight APIs still return raw-source glyphs and native capture")
        check(transcript.mountedRowCount == beforeQuery && transcript.scrollOffset == offsetBefore && transcript.contentHeight == heightBefore, "Virtual offscreen flight queries leave no retained cells and never scroll")
        transcript.setTextHidden(true, itemID: offscreenID, range: rawRange)
        transcript.scrollToItem(itemID: offscreenID)
        let hidden = transcript.textSnapshot(itemID: offscreenID, scale: 1)!.image
        transcript.setTextHidden(false, itemID: offscreenID, range: rawRange)
        let restored = transcript.textSnapshot(itemID: offscreenID, scale: 1)!.image
        check(hidden.dataProvider!.data != restored.dataProvider!.data, "Virtual range hiding survives recycling and applies when the row returns")
        let frozen = transcript.scrollOffset
        transcript.followsEnd = false; c.items[1].text += paragraph; c.revision += 1
        transcript.refresh(preservingOffset: true)
        check(transcript.scrollOffset == frozen, "Virtual explicit flight refresh freezes pixel offset")
        transcript.followsEnd = true; transcript.scrollToItem(itemID: "virtual-1000")
        let beforePage = transcript.itemFrame(itemID: "virtual-1000")!.minY - transcript.scrollOffset.y
        c.items.insert(contentsOf: (0..<5).map { .init(id: "earlier-\($0)", turnID: "earlier", kind: .assistant, text: "Earlier recorded history page.") }, at: 0); c.revision += 1
        transcript.refresh()
        check(abs(transcript.itemFrame(itemID: "virtual-1000")!.minY - transcript.scrollOffset.y - beforePage) < 1.01, "Virtual prepending a history page preserves the same reading item and offset")
        transcript.dispose()
        check(transcript.mountedRowCount == 0 && transcript.pooledRowCount == 0, "Virtual dispose releases mounted cells, pool and refinement")

        let compact = Conversation(id: "virtual-compact", title: "Compact activity stress")
        compact.items = (0..<2200).map { .init(id: "compact-\($0)", turnID: "same", kind: .tool(.command), text: "printf 'recorded'", status: "completed") }
        let activity = NativeTranscript(conversation: compact); activity.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        for y in [CGFloat(0), activity.contentHeight / 2, activity.contentHeight] {
            activity.scrollOffset = CGPoint(x: 0, y: y)
            check(activity.mountedRowCount <= 125 && activity.pooledRowCount <= 125, "Virtual all-compact history bounds the maximum live control population")
        }
        activity.dispose()
        let sparse = Conversation(id: "virtual-cold-overestimate", title: "Empty fenced blocks")
        sparse.items = (0..<200).map { .init(id: "sparse-\($0)", turnID: "same", kind: .assistant, text: String(repeating: "```swift\n```\n", count: 40)) }
        let sparseView = NativeTranscript(conversation: sparse); sparseView.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        sparseView.scrollToEnd()
        let clip = sparseView.scrollView.contentView.bounds
        let coverage = sparseView.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.reduce(CGFloat(0)) { sum, row in
            let intersection = row.frame.intersection(clip); return sum + (intersection.isNull ? 0 : intersection.height)
        }
        check(coverage >= clip.height - 29, "Virtual severe cold-height overestimates converge until the whole viewport is mounted")
        check(sparseView.mountedRowCount < 100, "Virtual overestimate convergence stays bounded by viewport height")
        sparseView.dispose()
        try verifyCardsAndActions(check: check)
        let report = String(format: "Native virtual benchmark (%@): initial %.3f ms; last delta %.3f ms; full idle refinement %.3f ms\n", optimizedBuild() ? "-O" : "-Onone", initialMS, deltaMS, refinementMS) +
            "2007 mixed rows, width1080, viewport720; first cold exact=\(coldExact), mounted=\(coldMounted)\n" + readings.joined(separator: "\n") + "\n"
        try report.write(to: output.appendingPathComponent("virtual-performance.txt"), atomically: true, encoding: .utf8)
        print(report, terminator: "")
    }
    private static func verifyCardsAndActions(check: (Bool, String) -> Void) throws {
        let c = Conversation(id: "virtual-interactions", title: "Virtual interactions")
        c.items = (0..<240).map { .init(id: "interactive-\($0)", turnID: "t", kind: .assistant, text: "Selectable recorded message \($0).") }
        c.items[0] = .init(id: "interactive-0", turnID: "t", kind: .user, text: "Original user input")
        c.items[2] = .init(id: "interactive-2", turnID: "t", kind: .tool(.command), text: "printf 'recorded'\nFull recorded output", status: "completed")
        c.items[3] = .init(id: "interactive-3", turnID: "t", kind: .notice(.info), text: "Sources/Recorded.swift  +2 −1", status: TranscriptPresentation.changesStatus)
        c.approvals = [.init(id: "inline", title: "Recorded approval", command: "printf 'recorded'", note: "", acceptLabel: "Allow", toolItemID: "interactive-1")]
        c.userInput = .init(id: "inline-question", questions: [.init(id: "explanation", header: "Explain", prompt: "Recorded question", options: [])])
        let transcript = NativeTranscript(conversation: c)
        var edits = 0, forks = 0, reviews = 0
        transcript.onEditMessage = { _ in edits += 1 }; transcript.onForkMessage = { _ in forks += 1 }
        transcript.onReviewChanges = { _ in reviews += 1 }
        transcript.frame = CGRect(x: 0, y: 0, width: 1080, height: 500); transcript.scrollOffset = .zero
        func row(_ id: String) -> NativeTranscriptRow? { transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == id } }
        let menuRow = row("interactive-0")!, initialUserTime = row("interactive-0")!.firstSeen
        let retiringApproval = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptCard }.first!
        let retiringButton = retiringApproval.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Allow" }!
        menuRow.menuWillOpen(menuRow.menu!)
        transcript.scrollToEnd()
        check(!retiringButton.accessibilityPerformPress() && c.approvals.count == 1, "Virtual an offscreen retired approval rejects a retained raw AX press")
        check(row("interactive-0") === menuRow, "Virtual an open native row menu pins the same cell")
        menuRow.menuDidClose(menuRow.menu!); transcript.scrollOffset = .zero; transcript.scrollToEnd()
        check(row("interactive-0") == nil, "Virtual closing a menu allows its offscreen cell to recycle")
        let question = transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptCard }.first { $0.accessibilityLabel()?.contains("Question") == true } ?? transcript.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptCard }.last!
        let field = question.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "explanation" }!
        field.stringValue = "Unsubmitted multiline\nanswer"; question.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
        transcript.scrollOffset = .zero
        check(question.superview != nil && field.stringValue == "Unsubmitted multiline\nanswer", "Virtual unsubmitted question input pins its native card outside the viewport")
        let tool = row("interactive-2")!
        transcript.setExpanded(true, itemID: tool.item.id)
        check(tool.body.string.contains("Full recorded output") && transcript.isExpanded(itemID: tool.item.id), "Virtual expand measures and displays the full tool row")
        transcript.scrollToEnd(); transcript.scrollOffset = .zero
        check(row("interactive-2")!.body.string.contains("Full recorded output"), "Virtual expanded state survives recycling")
        check(row("interactive-0")!.firstSeen == initialUserTime, "Virtual recycling retains a message’s missing-timestamp fallback per item")
        let user = row("interactive-0")!, parent = transcript.scrollView.documentView!
        check(transcript.performUserMessageAction(.edit, itemID: user.item.id) && transcript.performUserMessageAction(.fork, itemID: user.item.id) && edits == 1 && forks == 1, "Virtual recycled user row retains Edit and Fork routing")
        let changes = row("interactive-3")!
        changes.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Review" }!.performClick(nil)
        check(reviews == 1, "Virtual Changes Review routes after recycling")
        transcript.scrollToEnd(); transcript.scrollOffset = .zero
        row("interactive-3")!.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Undo" }!.performClick(nil)
        check(c.items[3].status == TranscriptPresentation.changesReverted, "Virtual Changes Revert updates the original item after recycling")
        let inline = parent.subviews.compactMap { $0 as? NativeTranscriptCard }.first { $0 !== question }!
        inline.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Allow" }!.performClick(nil)
        check(c.approvals.isEmpty, "Virtual inline approval retains the exact original callback after recycling")
        let draft = field.stringValue
        transcript.decisionCardsInline = false
        let external = transcript.externalDecisionCards(width: 1080)
        check(!external.isEmpty && external.allSatisfy { $0.superview !== parent }, "Virtual external decision cards remain independently owned by Normie")
        check(draft == "Unsubmitted multiline\nanswer", "Virtual inline drafts remain intact up to explicit presentation mode change")
        transcript.dispose()
    }

}
#endif
