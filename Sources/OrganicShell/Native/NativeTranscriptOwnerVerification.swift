#if M1_SELFTEST
import AppKit

@MainActor enum NativeTranscriptOwnerVerification {
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        func tree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(tree) }
        let store = ConversationStore(), c = Conversation(id: "owner-s2", title: "Retained reading session")
        c.items = (0..<32).map { index in
            .init(id: "owned-\(index)", turnID: "turn", kind: index == 0 ? .user : index == 8 ? .reasoning : .assistant,
                  text: index == 0 ? "Question with a **markdown** source." : String(repeating: "Native retained line \(index). ", count: 32))
        }
        store.add(c)
        let owner = NativeTranscriptSessions(store: store)
        let first = NSView(frame: CGRect(x: 0, y: 0, width: 830, height: 400))
        let second = NSView(frame: first.frame), third = NSView(frame: first.frame)
        let transcript = owner.transcript(for: c)
        check(transcript === owner.transcript(for: c) && owner.count == 1, "S2 lookup retains one native transcript per canonical model")
        check(transcript.superview == nil && !transcript.presentationActive, "S2 lookup alone never mounts or starts a hidden viewport")
        var edits = 0
        var config = NativeTranscriptSessions.Configuration()
        config.onEditMessage = { _ in edits += 1 }
        let source = owner.mount(c, in: first, frame: first.bounds, configuration: config)!
        transcript.followsEnd = false
        let collapsed = transcript.itemFrame(itemID: "owned-8")!.height
        transcript.setExpanded(true, itemID: "owned-8")
        transcript.scrollToItem(itemID: "owned-8")
        transcript.setSelectedRange(NSRange(location: 3, length: 10), itemID: "owned-8")
        let selected = tree(transcript).compactMap { $0 as? NativeTranscriptRow }.first { $0.item.id == "owned-8" }!.body
        let offset = transcript.scrollOffset
        let anchor = transcript.itemFrame(itemID: "owned-8")!.minY - offset.y
        let oldEdit = transcript.onEditMessage!
        transcript.setTextHidden(true, itemID: "owned-8", range: NSRange(location: 0, length: 8))
        let before = [CGFloat(1), 2].map { transcript.snapshot(scale: $0) }
        _ = source.setActive(false)
        let frozen = transcript.renderedRevision
        c.items[31].text += " deferred"; store.changed(c)
        check(transcript.renderedRevision == frozen && transcript.refreshDeferred, "S2 frozen source defers store work without deleting its pixels")
        let target = owner.mount(c, in: second, frame: second.bounds, configuration: config)!
        check(target.transcript === transcript && transcript.superview === second && first.subviews.isEmpty, "S2 mode handoff reparents the same viewport without a duplicate tree")
        check(transcript.selectedRange(itemID: "owned-8") == NSRange(location: 3, length: 10), "S2 transfer preserves source-coordinate selection")
        check(tree(transcript).contains { $0 === selected }, "S2 selected TextKit view survives a mount change")
        check(transcript.itemFrame(itemID: "owned-8")!.height > collapsed, "S2 expanded reasoning survives mount change")
        check(transcript.scrollOffset == offset && !transcript.followsEnd, "S2 same-width mount retains exact offset and follow policy")
        // Last-row delta is offscreen; the selected viewport and hidden flight range must remain identical.
        for (index, scale) in [CGFloat(1), 2].enumerated() {
            let after = transcript.snapshot(scale: scale)
            check(before[index].dataProvider?.data == after.dataProvider?.data, "S2 transferred selected/flight-hidden viewport is byte-identical at \(Int(scale))x")
            try NSBitmapImageRep(cgImage: after).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("owner-transfer@\(Int(scale))x.png"))
        }
        let targetFrame = transcript.frame
        check(!source.place(CGRect(x: 100, y: 100, width: 300, height: 80)) && transcript.frame == targetFrame, "S2 stale source layout cannot resize the target")
        check(!source.setActive(false) && transcript.presentationActive, "S2 stale source cannot retire the target")
        check(!owner.unmount(source), "S2 stale source unmount cannot steal the target")
        oldEdit(c.items[0]); check(edits == 0, "S2 retained old callback cannot dispatch after transfer")
        transcript.onEditMessage?(c.items[0]); check(edits == 1, "S2 current mount callback dispatches once")
        _ = target.place(CGRect(x: 0, y: 0, width: 640, height: 400))
        check(abs(transcript.itemFrame(itemID: "owned-8")!.minY - transcript.scrollOffset.y - anchor) < 1.01, "S2 target width reflow preserves the logical reading anchor")
        check(transcript.selectedRange(itemID: "owned-8") == NSRange(location: 3, length: 10), "S2 reflow keeps native selection")
        transcript.setTextHidden(false, itemID: "owned-8", range: NSRange(location: 0, length: 8))
        let moving = owner.release(c.id)!
        check(owner.count == 0 && !target.isCurrent && !transcript.isDisposed, "S2 release revokes source without disposal")
        let destination = NativeTranscriptSessions(store: store)
        check(destination.adopt(moving), "S2 destination adopts a transferred session")
        let arrival = destination.mount(c, in: third, frame: third.bounds, configuration: config)!
        check(arrival.transcript === transcript && destination.existingTranscript(for: c.id) === transcript, "S2 Move/Tear keeps the same native identity")
        owner.dispose(); check(!transcript.isDisposed && arrival.isCurrent, "S2 source-window disposal cannot dispose the adopted viewport")
        check(!destination.adopt(moving), "S2 an owned session cannot be adopted twice")
        try store.remove(ids: [c.id])
        check(transcript.isDisposed && destination.count == 0 && !arrival.isCurrent && third.subviews.isEmpty, "S2 permanent library removal disposes and unmounts the owned session")

        // Host presentation cleanup and a target's superseded cold cache (S2b).
        let visual = Conversation(id: "owner-visual", title: "Scoped visual state")
        visual.items = [.init(id: "visual-row", turnID: "v", kind: .assistant, text: "Shared viewport")]
        store.add(visual)
        let visualOwner = NativeTranscriptSessions(store: store), targetOwner = NativeTranscriptSessions(store: store)
        let visualLease = visualOwner.mount(visual, in: first, frame: first.bounds)!
        let visualView = visualLease.transcript!, baselineMask = CALayer()
        visualView.layer?.mask = baselineMask
        var cleanups = 0
        check(visualLease.onUnmount { [weak visualView] in cleanups += 1; visualView?.layer?.mask = nil; visualView?.followsEnd = true }, "S2b current lease can pair its host presentation cleanup")
        visualView.followsEnd = false
        let cold = targetOwner.mount(visual, in: second, frame: second.bounds)!.transcript!
        check(cold !== visualView, "S2b target fixture contains a genuinely different cold cache")
        check(visualOwner.transfer(visual.id, to: targetOwner), "S2b cross-window transfer replaces a cold target cache")
        check(cold.isDisposed && !visualView.isDisposed && targetOwner.existingTranscript(for: visual.id) === visualView, "S2b only superseded cache is disposed, moving graph is retained")
        check(cleanups == 1 && visualView.layer?.mask == nil && visualView.followsEnd, "S2b release cleans Organic mask and temporary follow policy once")
        check(!visualLease.onUnmount { cleanups += 100 }, "S2b stale lease cannot install cleanup on a later mount")
        let visualTarget = targetOwner.mount(visual, in: third, frame: third.bounds)!
        check(visualTarget.transcript === visualView && visualView.layer?.mask == nil, "S2b Normie admission has no Organic mask")
        let alienStore = ConversationStore(), alien = NativeTranscriptSessions(store: alienStore)
        check(!targetOwner.transfer(visual.id, to: alien) && visualTarget.isCurrent, "S2b cross-library refusal preserves the original mount")
        visualOwner.dispose()
        check(!visualView.isDisposed && visualTarget.isCurrent, "S2b closing source owner leaves moved target alive")
        targetOwner.dispose(); alien.dispose()
        check(visualView.isDisposed && cleanups == 1, "S2b final owner disposes without rerunning source cleanup")
        check(!targetOwner.canHandoff && targetOwner.mount(visual, in: first) == nil, "S2b disposed owner refuses late admission without recreating a graph")

        // One decision control graph across external (Normie) and inline (Organic) mounts.
        let question = Conversation(id: "owner-question", title: "Pending question")
        question.items = [.init(id: "question-message", turnID: "q", kind: .assistant, text: "Choose a destination.")]
        question.userInput = .init(id: "request", questions: [.init(id: "answer", header: "Destination", prompt: "Where?", options: [])])
        let questions = NativeTranscriptSessions(), qhost = NSView(frame: first.frame)
        var external = NativeTranscriptSessions.Configuration(); external.decisionCardsInline = false
        let qlease = questions.mount(question, in: qhost, frame: qhost.bounds, configuration: external)!
        let qt = qlease.transcript!, card = qt.externalDecisionCards(width: 830).first!
        let field = tree(card).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        field.stringValue = "Retain this answer"
        let rail = NSView(frame: first.frame); rail.addSubview(card)
        let inline = questions.mount(question, in: second, frame: second.bounds)!
        inline.transcript!.scrollToEnd()
        check(tree(inline.transcript!).contains { $0 === card }, "S2 inline/external policy reuses the question card")
        check(tree(inline.transcript!).contains { $0 === field } && field.stringValue == "Retain this answer", "S2 question draft and field identity survive policy change")
        let back = questions.mount(question, in: qhost, frame: qhost.bounds, configuration: external)!
        let restored = back.transcript!.externalDecisionCards(width: 830).first!
        check(restored === card && field.stringValue == "Retain this answer", "S2 question state survives return to external rail")
        questions.dispose()

        weak var freed: NativeTranscript?
        var stale: NativeTranscriptSessions.Lease?
        autoreleasepool {
            let lifetime = NativeTranscriptSessions(), c = Conversation(id: "weak", title: "Weak")
            let host = NSView(frame: first.frame)
            stale = lifetime.mount(c, in: host, frame: host.bounds)
            freed = stale?.transcript
            lifetime.removeConversation(c.id)
        }
        check(freed == nil && stale?.isCurrent == false, "S2 stale weak lease does not retain the removed graph")
        destination.dispose()
    }
}
#endif
