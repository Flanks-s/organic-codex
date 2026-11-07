#if TRANSCRIPT_ORGANIC_SELFTEST
import AppKit
import QuartzCore

/// Integration runner, compiled in a private tree with App/Main's @main attribute removed (not its code).
/// Constructs hidden window hosts only: never calls applicationDidFinishLaunching, App.run, orderFront or Core.
@main @MainActor enum NativeTranscriptOrganicVerification {
    static func main() throws {
        _ = NSApplication.shared
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append(label); print("FINDING: " + label) } }
        func layout(_ window: OrganicWindow) {
            window.shell.view.layoutSubtreeIfNeeded(); window.workbench.detail.view.layoutSubtreeIfNeeded()
            // Production defers ordered-out windows (N3). Explicit offscreen captures prepare those same views.
            for transcript in window.transcriptSessions.transcripts.values where transcript.presentationActive && !transcript.isHidden {
                transcript.prepareForSnapshot()
            }
            window.scene.clock.invalidate()
        }
        var options = Options(); options.mock = true; options.live = false; options.mockPaused = true; options.ambient = false
        let app = AppController(options), c = Conversation(id: "organic-owner", title: "One reading session")
        c.items = (0..<40).map { i in
            .init(id: "owned-\(i)", turnID: "t", kind: i == 0 ? .user : i == 8 ? .reasoning : .assistant,
                  text: String(repeating: "Retained text at row \(i). ", count: 30))
        }
        app.store.add(c)
        let screen = NSScreen.main!, frame = CGRect(x: 40, y: 40, width: 1280, height: 820)
        let source = OrganicWindow(app: app, frame: frame, screen: screen, members: [c.id], normie: true, o: options)
        source.scene.manualSettle = true; source.workbench.refresh(); layout(source)
        let owner = source.transcriptSessions, transcript = owner.existingTranscript(for: c.id)!
        check(source.workbench.transcriptSessions === owner && source.scene.transcriptSessions === owner, "S2b window injects one owner into both hosts")
        check(source.scene.columns.first?.native === transcript && owner.count == 1, "S2b hidden column lookup does not allocate a second viewport")
        check(transcript.layer?.mask == nil, "S2b initial Normie has no Organic mask")
        let collapsedHeight = transcript.itemFrame(itemID: "owned-8")!.height
        transcript.setExpanded(true, itemID: "owned-8")
        transcript.prepareForSnapshot()
        transcript.scrollToItem(itemID: "owned-8")
        transcript.setSelectedRange(NSRange(location: 3, length: 10), itemID: "owned-8")
        let anchor = transcript.itemFrame(itemID: "owned-8")!.minY - transcript.scrollOffset.y
        let normieFrame = transcript.frame, normieOffset = transcript.scrollOffset
        // A hidden scene's resize, settle, prewarm and old node motion cannot touch Normie's frame or mask.
        source.scene.resize(to: CGSize(width: 1180, height: 800), live: false)
        source.scene.settle(); source.scene.prewarm()
        source.scene.columns.first?.place(CGRect(x: 73, y: 0, width: 600, height: 780), form: 0)
        source.scene.columns.first?.showRest(full: false)
        check(transcript.frame == normieFrame && transcript.scrollOffset == normieOffset, "S2b hidden/brief column cannot place or scroll Normie's viewport")
        check(transcript.layer?.mask == nil && !transcript.isHidden, "S2b hidden scene cannot hide or mask Normie")
        source.scene.resize(to: frame.size, live: false)
        source.shell.setMode(.organic, animated: false); source.scene.settle(); layout(source)
        check(owner.existingTranscript(for: c.id) === transcript && transcript.superview === source.scene.nativePlane, "S2b Hide Sidebar mounts the same viewport")
        check(transcript.layer?.mask != nil, "S2b Organic admission installs its own fade")
        check(abs(transcript.itemFrame(itemID: "owned-8")!.minY - transcript.scrollOffset.y - anchor) <= 1.01, "S2b Normie to Organic preserves reading anchor")
        check(transcript.selectedRange(itemID: "owned-8") == NSRange(location: 3, length: 10), "S2b Normie to Organic preserves selection")
        check(transcript.itemFrame(itemID: "owned-8")!.height > collapsedHeight, "S2b expansion survives Hide Sidebar")
        let organicFrame = transcript.frame
        source.workbench.refresh(); source.workbench.detail.view.needsLayout = true; layout(source)
        check(transcript.frame == organicFrame && transcript.superview === source.scene.nativePlane, "S2b hidden Normie layout/store cannot reclaim Organic's viewport")
        // An existing ranged hide belongs to its caller, even while ColumnNode prepares a flight capture.
        for scale: CGFloat in [1, 2] {
            transcript.setTextHidden(true, itemID: "owned-8", range: NSRange(location: 0, length: 7))
            let before = transcript.snapshot(scale: scale)
            source.scene.columns.first?.invalidateCaptures()
            _ = source.scene.columns.first?.snapshot(fullWidth: organicFrame.width, briefWidth: 250)
            let after = transcript.snapshot(scale: scale)
            check(before.dataProvider?.data == after.dataProvider?.data, "S2b flight capture preserves caller hidden ranges at \(scale)x")
            transcript.setTextHidden(false, itemID: "owned-8", range: NSRange(location: 0, length: 7))
        }
        source.scene.setTranscriptPresentationActive(false)
        let strip = CollapseStrip(store: app.store, sessions: source.scene.composers, members: [c], shown: c.id,
                                  scale: 2, transcriptSessions: owner)
        strip.onTranscriptConfiguration = { c, composer in source.scene.transcriptConfiguration(for: c, composer: composer) }
        let stripHost = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 820))
        stripHost.addSubview(strip); strip.frame = stripHost.bounds; strip.layoutSubtreeIfNeeded()
        check(owner.existingTranscript(for: c.id) === transcript && transcript.superview === strip, "S2b Collapse uses the original viewport")
        check(transcript.layer?.mask == nil, "S2b Collapse does not inherit Organic's fade")
        print("S2b collapse anchor \(anchor) -> \(transcript.itemFrame(itemID: "owned-8")!.minY - transcript.scrollOffset.y), width \(transcript.frame.width), follows \(transcript.followsEnd)")
        let stripFrame = transcript.frame
        source.scene.resize(to: CGSize(width: 700, height: 650), live: false); source.scene.settle()
        check(transcript.frame == stripFrame && transcript.superview === strip, "S2b hidden scene resize cannot change Collapse's viewport")
        check(transcript.selectedRange(itemID: "owned-8") == NSRange(location: 3, length: 10), "S2b Collapse retains selection")
        strip.dispose(); strip.removeFromSuperview()
        source.scene.resize(to: frame.size, live: false); source.scene.setTranscriptPresentationActive(true); source.scene.settle()
        check(transcript.superview === source.scene.nativePlane && transcript.layer?.mask != nil, "S2b Restore remounts the original and reinstalls the fade")
        print("S2b restored anchor \(transcript.itemFrame(itemID: "owned-8")!.minY - transcript.scrollOffset.y), width \(transcript.frame.width), follows \(transcript.followsEnd)")
        check(abs(transcript.itemFrame(itemID: "owned-8")!.minY - transcript.scrollOffset.y - anchor) <= 1.01, "S2b Collapse roundtrip preserves reading anchor")
        source.shell.setMode(.normie, animated: false); layout(source)
        check(transcript.layer?.mask == nil && transcript.isDescendant(of: source.workbench.detail.view), "S2b Show Sidebar restores Normie without Organic's mask")
        check(transcript.selectedRange(itemID: "owned-8") == NSRange(location: 3, length: 10), "S2b Show Sidebar retains selection")
        func standIns(_ view: NSView) -> [NativeTranscriptStandIn] {
            (view as? NativeTranscriptStandIn).map { [$0] } ?? view.subviews.flatMap(standIns)
        }
        source.shell.setMode(.organic, animated: true)
        let frozen = standIns(source.workbench.detail.view)
        check(!frozen.isEmpty && frozen.allSatisfy { $0.hitTest(.zero) == nil }, "S2b source fade keeps only noninteractive pixel stand-ins")
        check(owner.existingTranscript(for: c.id) === transcript, "S2b animated handoff still has one real viewport")
        transcript.followsEnd = false
        source.shell.setMode(.normie, animated: false); source.shell.flight.cancel(); layout(source)
        check(standIns(source.workbench.detail.view).isEmpty && transcript.layer?.mask == nil, "S2b reverse removes source stand-ins and Organic mask")
        check(!transcript.followsEnd, "S2b handoff does not overwrite a later explicit follow policy with mount-time state")
        transcript.followsEnd = true
        let movingOffset = transcript.scrollOffset
        source.prepareConversationTransfer(c.id, closing: true)
        let movingComposer = source.scene.composers.release(c.id)!
        let moving = owner.release(c.id)!
        let target = OrganicWindow(app: app, frame: frame, screen: screen, members: [c.id], normie: true, o: options,
                                   transferredTranscripts: [moving])
        target.scene.adoptComposer(movingComposer, for: c.id); target.workbench.remountComposer()
        target.scene.manualSettle = true; target.workbench.refresh(); layout(target)
        check(target.workbench.detail.composer === movingComposer && movingComposer.isDescendant(of: target.workbench.detail.view), "S2b Move retains and mounts the same composer too")
        var refreshes = 0
        movingComposer.onRefreshHistory = { refreshes += 1 }
        let targetEditorEpoch = movingComposer.presentationEpoch
        check(target.transcriptSessions.existingTranscript(for: c.id) === transcript, "S2b Move new-window constructor adopts before either host can allocate")
        check(transcript.scrollOffset == movingOffset && transcript.selectedRange(itemID: "owned-8") == NSRange(location: 3, length: 10), "S2b Move preserves offset and selection")
        check(transcript.itemFrame(itemID: "owned-8")!.height > collapsedHeight, "S2b Move retains expanded reasoning")
        let targetFrame = transcript.frame
        source.scene.resize(to: CGSize(width: 960, height: 700), live: false); source.scene.settle(); source.workbench.refresh(); layout(source)
        check(transcript.frame == targetFrame && transcript.isDescendant(of: target.workbench.detail.view), "S2b old window cannot resize or reclaim the moved viewport")
        source.shell.flight.shutdown(); source.shell.clearTranscriptStandIns()
        source.scene.disposeTranscriptPresentation(); source.disposeWorkbenchForClose(); owner.dispose()
        movingComposer.onRefreshHistory?()
        check(refreshes == 1 && movingComposer.presentationEpoch == targetEditorEpoch, "S2b closing source cannot withdraw target editor callbacks or AX lease")
        source.scene.resize(to: CGSize(width: 1100, height: 780), live: false); source.shell.setMode(.organic, animated: false)
        check(owner.count == 0 && target.transcriptSessions.existingTranscript(for: c.id) === transcript, "S2b late close/grow reflow cannot recreate source sessions or touch the target")
        check(!transcript.isDisposed, "S2b final source disposal leaves adopted target alive")
        target.shell.flight.shutdown(); target.scene.disposeTranscriptPresentation(); target.disposeWorkbenchForClose(); target.transcriptSessions.dispose()
        check(transcript.isDisposed, "S2b final target disposal retires the viewport")
        // Non-last-member Move: source must remount its NEXT editor before target admission, never detach the moved one.
        let one = Conversation(id: "move-one", title: "Moving"), two = Conversation(id: "move-two", title: "Staying")
        one.items = [.init(id: "one", turnID: "one", kind: .assistant, text: "Moving body")]
        two.items = [.init(id: "two", turnID: "two", kind: .assistant, text: "Staying body")]
        app.store.add(one); app.store.add(two)
        let remaining = OrganicWindow(app: app, frame: frame, screen: screen, members: [one.id, two.id], normie: true, o: options)
        remaining.scene.manualSettle = true; remaining.workbench.refresh(); layout(remaining)
        let original = remaining.transcriptSessions.existingTranscript(for: one.id)!
        remaining.prepareConversationTransfer(one.id, closing: false)
        let editor = remaining.scene.composers.release(one.id)!, session = remaining.transcriptSessions.release(one.id)!
        remaining.scene.remove(one.id, reason: "verification-move"); remaining.scene.settle()
        _ = remaining.workbench.select(remaining.scene.current); remaining.workbench.remountComposer(); layout(remaining)
        let received = OrganicWindow(app: app, frame: frame, screen: screen, members: [one.id], normie: true, o: options,
                                     transferredTranscripts: [session])
        received.scene.adoptComposer(editor, for: one.id); received.workbench.remountComposer(); received.workbench.refresh(); layout(received)
        check(remaining.workbench.selectedConversation === two && remaining.workbench.detail.composer !== editor,
              "S2b non-last Move selects the source's remaining chat without retaining its moved editor mount")
        check(received.transcriptSessions.existingTranscript(for: one.id) === original && editor.isDescendant(of: received.workbench.detail.view),
              "S2b non-last Move retains both target native graphs")
        let epoch = editor.presentationEpoch
        var recovery = 0; editor.onRefreshHistory = { recovery += 1 }
        remaining.shell.flight.shutdown(); remaining.scene.disposeTranscriptPresentation(); remaining.disposeWorkbenchForClose(); remaining.transcriptSessions.dispose()
        editor.onRefreshHistory?()
        check(editor.presentationEpoch == epoch && recovery == 1, "S2b later source close cannot retire a moved editor from a non-last transfer")
        received.shell.flight.shutdown(); received.scene.disposeTranscriptPresentation(); received.disposeWorkbenchForClose(); received.transcriptSessions.dispose()
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "S2b integration never opens a visible window")
        let report = "Organic transcript owner: \(checks) checks / \(failures.count) findings\n" + failures.joined(separator: "\n") + "\n"
        if let output = CommandLine.arguments.dropFirst().first { try report.write(toFile: output, atomically: true, encoding: .utf8) }
        print(report); if !failures.isEmpty { exit(1) }
    }
}
#endif
