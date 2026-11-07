#if M1_SELFTEST
import AppKit

@MainActor enum NativeTranscriptStoreChangeVerification {
    static func run(check: (Bool, String) -> Void) {
        let c = Conversation(id: "typed-native", title: "Precise native updates")
        c.running = true; c.activeTurnID = "t"
        c.items = [
            .init(id: "user", turnID: "t", kind: .user, text: "Question", timestamp: Date(timeIntervalSince1970: 100)),
            .init(id: "reason", turnID: "t", kind: .reasoning, text: "Recorded thought", status: "running"),
            .init(id: "command", turnID: "t", kind: .tool(.command), text: "printf fixture", status: "running"),
            .init(id: "answer", turnID: "t", kind: .assistant, text: "First **sentence**.\n", status: "running"),
            .init(id: "sibling", turnID: "t", kind: .assistant, text: "A following sibling.")
        ]
        let store = ConversationStore(conversations: [c]), view = NativeTranscript(conversation: c, store: store)
        view.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        view.refresh(preservingOffset: false)
        var serial = 0, checks = 0
        var hiddenRange = false, hiddenMark = false, selected = false, expanded = false
        func compare(_ label: String) {
            let full = NativeTranscript(conversation: c)
            full.frame = view.frame; full.refresh(preservingOffset: false)
            if expanded { full.setExpanded(true, itemID: "command") }
            if hiddenRange { full.setTextHidden(true, itemID: "answer", range: NSRange(location: 0, length: 5)) }
            if hiddenMark { full.setFlightSourceHidden(true, part: .activityMark, itemID: "reason") }
            if selected { full.setSelectedRange(NSRange(location: 0, length: 3), itemID: "answer") }
            full.followsEnd = false; full.scrollOffset = view.scrollOffset
            check(full.contentHeight == view.contentHeight, "typed/full total height: " + label)
            for item in c.items {
                check(full.itemFrame(itemID: item.id) == view.itemFrame(itemID: item.id), "typed/full row geometry: " + label + "/" + item.id)
                if let a = view.scrollView.documentView!.subviews.compactMap({ $0 as? NativeTranscriptRow }).first(where: { $0.item.id == item.id }),
                   let b = full.scrollView.documentView!.subviews.compactMap({ $0 as? NativeTranscriptRow }).first(where: { $0.item.id == item.id }) {
                    a.body.layoutManager!.ensureLayout(for: a.body.textContainer!); b.body.layoutManager!.ensureLayout(for: b.body.textContainer!)
                    check(a.body.string.utf8.elementsEqual(b.body.string.utf8) && a.body.textStorage!.isEqual(to: b.body.textStorage!), "typed/full text bytes and attributes: " + label + "/" + item.id)
                    check(a.sourceOffsets == b.sourceOffsets, "typed/full source glyph map: " + label + "/" + item.id)
                }
            }
            for scale: CGFloat in [1, 2] {
                let a = view.snapshot(scale: scale), b = full.snapshot(scale: scale)
                check(a.dataProvider!.data == b.dataProvider!.data, "typed/full viewport bytes: " + label + "/" + String(Int(scale)) + "x")
            }
            full.dispose(); checks += 1
        }
        func send(_ method: String, _ fields: JSONValue, precise: Bool = true) {
            let scans = view.historyScanCount, updates = view.itemRefreshCount
            let counts = Dictionary(uniqueKeysWithValues: c.items.map { ($0.id, view.rowConfigurationCount(itemID: $0.id)) })
            serial += 1; var p = fields.objectValue!; p["threadId"] = .string(c.id); p["turnId"] = "t"
            store.apply(.init(id: serial, time: 100, method: method, params: .object(p)))
            let id = p["itemId"]?.stringValue ?? p["item"]?["id"]?.stringValue
            if precise {
                check(view.historyScanCount == scans && view.itemRefreshCount == updates + 1, "typed item bypasses entire history: " + method)
                check(c.items.filter { $0.id != id }.allSatisfy { view.rowConfigurationCount(itemID: $0.id) == counts[$0.id] }, "typed item never configures unchanged siblings: " + method)
            } else { check(view.fullIndexRebuildCount > 0 && view.historyScanCount > scans, "structural event scans full history: " + method) }
            compare(method + "-" + String(serial))
        }
        for delta in ["A `code` fragment.\n", "```swift\n", "let n = 42\n", "```\n", "中文🙂 **tail**\n"] {
            send("item/agentMessage/delta", ["itemId": "answer", "delta": .string(delta)])
        }
        send("item/reasoning/summaryTextDelta", ["itemId": "reason", "delta": " More reasoning."])
        send("item/commandExecution/outputDelta", ["itemId": "command", "delta": "\nrecorded"])
        hiddenRange = true; hiddenMark = true; selected = true
        view.setTextHidden(true, itemID: "answer", range: NSRange(location: 0, length: 5))
        view.setFlightSourceHidden(true, part: .activityMark, itemID: "reason")
        view.setSelectedRange(NSRange(location: 0, length: 3), itemID: "answer")
        let selectedRow = view.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "answer" }!
        send("item/agentMessage/delta", ["itemId": "answer", "delta": "Selection stays.\n"])
        check(view.selectedRange(itemID: "answer") == NSRange(location: 0, length: 3) && selectedRow.superview != nil, "typed append retains the selected native row and range")
        check(view.glyphFrames(itemID: "answer", range: NSRange(location: 0, length: 5)).count > 0 && view.textSnapshot(itemID: "answer", scale: 2) != nil, "typed append preserves flight queries and hidden ranges")
        // New tail items grow the prefix index without rebuilding historical entries.
        send("item/started", ["item": ["id": "new-command", "type": "commandExecution", "command": "printf new"]])
        send("item/commandExecution/outputDelta", ["itemId": "new-command", "delta": "\nnew output"])
        send("item/completed", ["item": ["id": "new-command", "type": "commandExecution", "command": "printf new", "aggregatedOutput": "new output"]])
        send("item/started", ["item": ["id": "new-answer", "type": "agentMessage", "text": "Last **answer**."]])
        send("item/completed", ["item": ["id": "new-answer", "type": "agentMessage", "text": "Last **answer**."]])
        send("core/approvalRequested", ["approvalId": "pending-command", "request": ["method": "item/commandExecution/requestApproval", "params": ["itemId": "future-command", "command": "printf approval"]]], precise: false)
        send("core/approvalRequested", ["approvalId": "pending-question", "request": ["method": "item/tool/requestUserInput", "params": ["questions": [["id": "q", "question": "Recorded question", "options": [["label": "Yes", "description": "Recorded choice"]]]]]]], precise: false)
        send("item/started", ["item": ["id": "future-command", "type": "commandExecution", "command": "printf approval"]])
        send("item/started", ["item": ["id": "after-cards", "type": "agentMessage", "text": "After retained cards"]])
        send("core/approvalExpired", ["approvalId": "pending-command"], precise: false)
        send("core/approvalResponded", ["approvalId": "pending-question"], precise: false)
        send("turn/completed", ["turn": ["id": "t", "status": "completed"]], precise: false)
        check((view.scrollView.documentView as! NativeTranscriptTable).semanticRows.first { $0.key == "item:new-answer" }?.index == c.items.firstIndex { $0.id == "new-answer" }, "typed append retains global AX row numbers")
        expanded = true; view.setExpanded(true, itemID: "command")
        compare("expanded command")
        // Local edits/reorder/revert/reload are intentionally unhinted and cannot leave a stale entry or lookup.
        c.items[0].text = "Edited question"; store.changed(c); compare("edit")
        c.items.removeLast(2); store.changed(c); compare("rollback")
        c.items.swapAt(1, 2); store.changed(c); compare("reorder")
        c.items[1].status = "changes-reverted"; store.changed(c); compare("revert")
        // Unknown publication after a missed hidden revision must rebuild before a new precise event is trusted.
        view.isHidden = true; c.items[0].text = "Hidden edit"; store.changed(c)
        view.isHidden = false; view.prepareForSnapshot(); compare("hidden structural replay")
        check(checks >= 20, "typed/full differential covers streaming, lifecycles, structure and hidden restoration")
        view.dispose()
        // A changed row above the viewport updates its height immediately and keeps the visible reading anchor.
        let long = Conversation(id: "typed-away", title: "Reading away")
        long.items = (0..<100).map { .init(id: "away-\($0)", turnID: "t", kind: .assistant, text: "Stable row \($0)") }
        let s = ConversationStore(conversations: [long]), t = NativeTranscript(conversation: long, store: s)
        t.frame = CGRect(x: 0, y: 0, width: 1080, height: 360); t.refineColdHeights(budget: 10)
        t.followsEnd = false; t.scrollToItem(itemID: "away-50")
        let before = t.itemFrame(itemID: "away-50")!.minY - t.scrollOffset.y, scans = t.historyScanCount
        s.apply(.init(id: 1, time: 100, method: "item/agentMessage/delta", params: ["threadId": .string(long.id), "itemId": "away-0", "delta": .string(String(repeating: "new line\n", count: 10))]))
        check(t.itemFrame(itemID: "away-50")!.minY - t.scrollOffset.y == before && t.historyScanCount == scans, "offscreen dirty row adjusts prefix heights and preserves reading anchor without a history scan")
        t.dispose()
    }
}
#endif
