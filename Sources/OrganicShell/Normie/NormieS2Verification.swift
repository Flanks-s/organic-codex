#if NORMIE_SELFTEST
import AppKit

@MainActor enum NormieS2Verification {
    static func run(directory: URL, check: (Bool, String) -> Void) throws {
        let store = ConversationStore(), c = Conversation(id: "normie-s2", title: "Live fixture")
        c.updated = Date(timeIntervalSince1970: 100); c.isLiveConversation = true; c.running = true
        c.items = (0..<24).map { .init(id: "n-\($0)", turnID: "turn", kind: .assistant, text: String(repeating: "Retained native body \($0). ", count: 22)) }
        store.add(c); store.usesLiveCore = true
        let actions = NormieActions(), sessions = NativeComposerSessions(), owner = NativeTranscriptSessions(store: store)
        var hasMore = true, pageCalls = 0
        var page: (@MainActor (Result<Void, Error>) -> Void)?
        actions.hasMoreHistory = { hasMore }
        actions.loadMoreHistory = { done in pageCalls += 1; page = done }
        var stopTargets: [String] = []
        var stops: [(UUID, @MainActor (NativeComposerCompletion) -> Void)] = [], refreshed: [String] = []
        actions.interrupt = { target, id, done in
            stopTargets.append(target.id)
            stops.append((id, done))
        }
        actions.refreshHistory = { refreshed.append($0.id) }
        let workbench = NormieWorkbench(store: store, sessions: sessions, current: c.id, actions: actions, transcriptSessions: owner)
        _ = workbench.view; workbench.view.frame = CGRect(x: 0, y: 0, width: 1080, height: 760)
        workbench.view.layoutSubtreeIfNeeded()
        let model = workbench.sidebarModel, key = NormieSidebarModel.historyPageKey
        check(workbench.transcriptSessions === owner && workbench.detail.transcripts[c.id] === owner.existingTranscript(for: c.id), "S2 Workbench accepts the window's shared transcript owner")
        check(model.rows.contains(.more(key)), "S2 global backend page is reachable with fewer than five loaded chats")
        model.showMore(key); model.showMore(key)
        check(pageCalls == 1 && model.historyLoading && model.historyTitle().contains("Loading"), "S2 Show More consumes one Core page and rejects duplicate clicks")
        for i in 0..<32 {
            let old = Conversation(id: "older-\(i)", title: "Older \(i)")
            old.updated = Date(timeIntervalSince1970: Double(90-i)); store.add(old)
        }
        page?(.success(()))
        check(!model.historyLoading && model.current == c.id && model.rows.contains(.more("recents")), "S2 page arrival preserves selection and keeps local 5/+20 grouping")
        model.showMore("recents")
        check(model.limit("recents") == 25 && pageCalls == 1, "S2 local Show More still reveals twenty already-loaded rows")
        model.showMore("recents")
        let sidebar = workbench.sidebar; _ = sidebar.view
        sidebar.view.frame = CGRect(x: 0, y: 0, width: 280, height: 250); sidebar.view.layoutSubtreeIfNeeded()
        sidebar.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 140)); sidebar.scrollView.reflectScrolledClipView(sidebar.scrollView.contentView)
        let reading = sidebar.scrollView.contentView.bounds.origin
        model.showMore(key); page?(.failure(CoreWire.failure("Fixture page failed")))
        check(model.historyError?.contains("Fixture page failed") == true && model.historyTitle().contains("Retry"), "S2 page error remains visible and retryable")
        check(model.current == c.id && sidebar.scrollView.contentView.bounds.origin == reading, "S2 page error cannot scroll back to current chat")
        model.focus(.more(key)); sidebar.scrollView.contentView.scroll(to: reading)
        model.showMore(key); hasMore = false; page?(.success(()))
        check(!model.rows.contains(.more(key)) && !model.historyLoading && model.historyError == nil, "S2 exhausted Core cursor removes only the global page row")
        check(model.current == c.id && sidebar.scrollView.contentView.bounds.origin == reading, "S2 removal of focused final-page row preserves the sidebar reading position")
        hasMore = true; model.refresh(); model.showMore(key)
        let late = page; model.cancelHistoryPaging(); late?(.failure(CoreWire.failure("late")))
        check(!model.historyLoading && model.historyError == nil, "S2 retired pagination callback cannot restore old error/loading")
        let composer = sessions.composer(for: c, store: store)
        check(composer.requestStop() && composer.hasPendingStop && stops.count == 1 && stopTargets == [c.id], "S2 Normie uses asynchronous UUID interrupt instead of fire-and-forget stop")
        stops[0].1(.failed("Normie stop failed"))
        check(!composer.hasPendingStop && composer.canStop && composer.state.operationError == "Normie stop failed", "S2 Normie stop failure clears pending while running remains true")
        c.operationError = "Send outcome unknown"; c.sendOutcomeUnknown = true; store.changed(c)
        check(composer.requestHistoryRefresh() && refreshed == [c.id], "S2 visible recovery delegates Refresh history to its canonical chat")
        check(c.sendOutcomeUnknown && !composer.canSend, "S2 Normie refresh does not invent send acknowledgement")
        let transcript = owner.existingTranscript(for: c.id)!
        transcript.followsEnd = false; transcript.scrollToItem(itemID: "n-8")
        transcript.setSelectedRange(NSRange(location: 2, length: 6), itemID: "n-8")
        _ = workbench.composerForHandoff()
        let organic = NSView(frame: CGRect(x: 0, y: 0, width: 830, height: 430))
        let organicLease = owner.mount(c, in: organic, frame: organic.bounds)!
        let organicFrame = transcript.frame
        workbench.refresh(); workbench.detail.view.needsLayout = true; workbench.detail.view.layoutSubtreeIfNeeded()
        check(transcript.superview === organic && transcript.frame == organicFrame && organicLease.isCurrent, "S2 hidden Normie store/layout cannot reclaim or resize Organic's transcript")
        check(composer.onStopRequest == nil && composer.onRefreshHistory == nil, "S2 handoff withdraws window-owned recovery callbacks without changing request truth")
        workbench.remountComposer(); workbench.detail.view.layoutSubtreeIfNeeded()
        check(transcript.superview === workbench.detail.view && !organicLease.isCurrent && workbench.detail.transcripts[c.id] === transcript, "S2 explicit Normie return reacquires the same viewport")
        check(transcript.selectedRange(itemID: "n-8") == NSRange(location: 2, length: 6), "S2 Normie/Organic roundtrip retains selection")
        for scale: CGFloat in [1, 2] {
            let image = workbench.snapshot(scale: scale)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("s2-recovery@\(Int(scale))x.png"))
            check(image.width > 0 && composer.historyRefreshButton.accessibilityLabel() == "Refresh history", "S2 recovery snapshot and AX label at \(Int(scale))x")
        }
        _ = workbench.composerForHandoff()
        let transfer = owner.release(c.id)!, newOwner = NativeTranscriptSessions(store: store)
        check(newOwner.adopt(transfer), "S2 window transfer accepts the session released by the old owner")
        let incoming = newOwner.mount(c, in: organic, frame: organic.bounds)!
        workbench.dispose(); owner.dispose()
        check(!transcript.isDisposed && incoming.isCurrent, "S2 disposing old Workbench/window cannot kill transferred transcript")
        newOwner.dispose()
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "S2 checks open no windows")
    }
}
#endif
