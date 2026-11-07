import AppKit
import QuartzCore

extension AppController {
    /// Where windows are saved: the mock's in the app's defaults; a Live Core's in its presentation state (already scoped
    /// to its endpoint), with an unsent New Chat's files in the sidecar.
    var windowScope: String { o.usesLiveCore ? "live:" + CoreService.shared.baseURL.absoluteString : "mock" }
    /// Persist before teardown; an empty owner list must not erase the last closed window.
    func saveWindows(_ owners: [OrganicWindow]? = nil) {
        let owners = owners ?? windows
        guard !owners.isEmpty else { return }
        guard let live else {
            if !SavedWindow.save(owners, scope: windowScope, defaults: windowDefaults) { liveError = "Couldn't save the windows to disk." }
            return
        }
        let records = owners.enumerated().map { SavedWindow.record($0.element, index: $0.offset) }
        do { try live.saveWindowPresentation(records) } catch { liveError = "Couldn't save the windows: \(error.localizedDescription)" }
    }

    struct WindowRestoration {
        var saved: SavedWindow
        var files: [Attachment] = []
    }
    func windowRecords() -> [WindowRestoration] {
        if let live {
            return live.presentation.windows.compactMap { record in
                SavedWindow.from(record).map { WindowRestoration(saved: $0, files: live.presentation.restoreAttachments(record.files ?? [])) }
            }
        }
        return SavedWindow.load(scope: windowScope, defaults: windowDefaults).map { WindowRestoration(saved: $0) }
    }

    /// Startup and Dock reopen share record filtering, window construction and arrangement restoration.
    @discardableResult func restoreWindows(_ records: [WindowRestoration], into initial: OrganicWindow? = nil,
                                          present: Bool = true) -> OrganicWindow? {
        guard windows.isEmpty || initial != nil else { return front }
        let records = records.map { record in
            var record = record
            // Older Live restores could persist the empty startup placeholder beside a real working set.
            // Text (including whitespace) and attachments are genuine unsent content; context alone is not.
            if record.saved.composingNew == true, !record.saved.members.isEmpty,
               (record.saved.draft ?? "").isEmpty, record.files.isEmpty {
                record.saved.composingNew = false
            }
            return record
        }.filter { record in
            record.saved.composingNew == true || record.saved.members.contains { store.conversation($0)?.archived == false }
        }
        let valid = records.isEmpty ? [WindowRestoration(saved: defaultWindowRecord())] : records
        for (index, record) in valid.enumerated() {
            let saved = record.saved
            let ids = saved.members.filter { store.conversation($0)?.archived == false }
            let (frame, screen) = saved.visibleFrame()
            let w: OrganicWindow
            if index == 0, let initial {
                w = initial
                w.window.setFrame(frame, display: false)
                for id in ids where !w.scene.members.contains(where: { $0.id == id }) {
                    if let c = store.conversation(id) { w.scene.admit(c, reason: "restore") }
                }
                w.scene.settle()
            } else {
                w = OrganicWindow(app: self, frame: frame, screen: screen, members: ids, normie: saved.normie, o: o)
                windows.append(w); attachLive(w)
            }
            if let current = ids.contains(saved.current) ? saved.current : ids.first {
                // Select before switching modes: the initial Live owner is still a Normie New Chat.
                // show() alone can return early for the current member and leave its draft flag intact.
                _ = w.workbench.select(current)
                if w.scene.composingNew { w.scene.closeDraftForSwitch() }
                w.scene.show(current); w.scene.settle()
            }
            w.shell.setMode(saved.normie ? .normie : .organic, animated: false)
            restoreArrangement(saved, in: w, files: record.files)
        }
        if present { presentRestoredWindows(valid) }
        return windows.first
    }

    var launchScreen: NSScreen {
        let screens = NSScreen.screens
        return (o.display.isEmpty ? nil : screens.first { $0.localizedName.lowercased().contains(o.display.lowercased()) })
            ?? screens.first { $0 != screens.first } ?? NSScreen.main!
    }
    private func defaultWindowRecord() -> SavedWindow {
        let screen = launchScreen
        let visible = screen.visibleFrame
        let size = CGSize(width: min(o.width, visible.width - 40), height: min(o.height, visible.height - 40))
        let latest = store.conversations.filter { !$0.archived }.max { $0.updated < $1.updated }
        // Automated mock recipes keep their established working set; normal empty launches show the latest chat.
        let members = automated && live == nil ? MockSeed.windowMembers : latest.map { [$0.id] } ?? []
        return SavedWindow(frame: [visible.midX - size.width / 2, visible.midY - size.height / 2, size.width, size.height],
                           normie: automated && live == nil ? o.normie : true, members: members,
                           current: members.first ?? "", composingNew: members.isEmpty)
    }

    func presentRestoredWindows(_ records: [WindowRestoration]) {
        guard presentsWindows else { return }
        for w in windows.dropFirst().reversed() { w.show(focus: w.shell.mode == .normie) }
        windows.first.map { $0.show(focus: $0.shell.mode == .normie) }
        for (w, record) in zip(windows, records) where record.saved.collapsed == true {
            let saved = record.saved
            DispatchQueue.main.async { [weak w] in
                guard let w, !w.isClosed else { return }
                w.collapseToSide(saved.members.contains(saved.selection ?? "") ? saved.selection : saved.current)
            }
        }
    }

    /// What a saved window was besides its members: Focused and its split (each grafted in, then settled at once, before
    /// anything shows), the split member whose editor had the keyboard, and New Chat with its unsent words, project and
    /// device (f003; product LocalPresentationState WindowState).
    func restoreArrangement(_ s: SavedWindow, in w: OrganicWindow, files: [Attachment] = []) {
        let held = Set(w.scene.members.map(\.id))
        if s.layout == "focused", let split = s.split?.filter(held.contains), let lead = split.first {
            w.scene.enterFocused(lead, reason: "restore"); w.scene.settle()
            for (i, id) in split.enumerated().dropFirst() { w.scene.graft(id, at: i, reason: "restore"); w.scene.settle() }
            // Graft selects its new pane. Restore the saved current at rest without changing split order or orb banks.
            if split.contains(s.current), w.scene.current != s.current {
                w.scene.current = s.current
                w.scene.resize(to: w.scene.sceneView.bounds.size, live: false)
            }
            if let focus = s.splitFocus, held.contains(focus), let c = store.conversation(focus) {
                DispatchQueue.main.async { [weak w] in guard let w, !w.isClosed else { return }; w.scene.composer(for: c).focus() }
            }
        }
        guard s.composingNew == true else { return }
        let context = NormieNewChatContext(projectID: s.project, deviceID: s.device ?? "mac")
        if s.normie { w.workbench.useNewChatContext(context); _ = w.workbench.newChat(projectID: s.project) }
        else { w.scene.draftContext = context; w.scene.newChat(); w.scene.settle() }
        if let text = s.draft { w.scene.composers.draft().composer.setText(text) }
        if !files.isEmpty { w.scene.composers.draft().composer.attachments = files }
    }

    /// A late Core load must never reopen a window the user closed while it was connecting.
    func restoreLive() {
        guard startupRestorePending, let first = windows.first else { return }
        startupRestorePending = false
        _ = restoreWindows(automated ? [] : windowRecords(), into: first)
    }

    // MARK: Windows (f002, f188)

    /// Move Conversation to New Window (f188): it leaves `source`'s working set, its editor (draft, selection, undo) goes
    /// with it, and a window the source's size grows beside it (centred 24 pt right and down), from a 72 pt square at the
    /// conversation's bar or orb. New windows open in Normie (WindowModel's default).
    func moveToNewWindow(_ id: String?, from source: OrganicWindow) {
        // The only member may move too, unless New Chat has unsent words there; its window then closes (WindowCoordinator
        // movableConversation, commitTransfer).
        guard let id, source.allowsTransfer, source.scene.members.contains(where: { $0.id == id }), store.conversation(id) != nil,
              source.scene.members.count > 1 || !source.hasUnboundDraft else { NSSound.beep(); return }
        let only = source.scene.members.count == 1
        let f = source.window.frame
        let startPoint = source.scene.dockFrame(of: id).map { source.window.convertPoint(toScreen: source.root.convert(CGPoint(x: $0.midX, y: $0.midY), to: nil)) }
            ?? CGPoint(x: f.midX, y: f.midY)
        source.prepareConversationTransfer(id, closing: only)
        let composer = source.scene.composers.release(id)
        let transcript = source.transcriptSessions.release(id)
        if !only { source.scene.remove(id, reason: "moved") }
        if !only, source.shell.mode == .normie {
            _ = source.workbench.select(source.scene.current); source.workbench.remountComposer()
        }
        openWindow(for: id, composer: composer, transcript: transcript, size: f.size, centre: CGPoint(x: f.midX + 24, y: f.midY - 24), from: startPoint, screen: source.window.screen)
        if only { DispatchQueue.main.async { source.window.close() } }
    }

    /// A window for one conversation, grown from a 72 pt square at `start` to `size` centred at `centre` (kept on its
    /// screen) over 0.38 s on (0.3, 0.6, 0.2, 1), its content fading in over the first 0.18 s (TearWindowGrowth).
    @discardableResult func openWindow(for id: String, composer: NativeComposer?, transcript: NativeTranscriptSessions.Session? = nil,
                                      size: CGSize, centre: CGPoint, from start: CGPoint, screen: NSScreen?) -> OrganicWindow {
        let screen = screen ?? NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main!
        let vis = screen.visibleFrame
        // Its size too, on a smaller screen (TearGeometry.finalFrame; audit A18).
        let fit = CGSize(width: min(size.width, vis.width), height: min(size.height, vis.height))
        var frame = CGRect(x: centre.x - fit.width / 2, y: centre.y - fit.height / 2, width: fit.width, height: fit.height)
        frame.origin.x = min(max(frame.minX, vis.minX), vis.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, vis.minY), vis.maxY - frame.height)
        let w = OrganicWindow(app: self, frame: frame, screen: screen, members: [id], normie: true, o: o,
                              transferredTranscripts: transcript.map { [$0] } ?? [])
        if let composer { w.scene.adoptComposer(composer, for: id); w.workbench.remountComposer() }
        windows.append(w)
        attachLive(w)
        w.watchAmbient()
        let reduce = Motion.reduce
        let begin = CGRect(x: start.x - 36, y: start.y - 36, width: 72, height: 72)
        w.growing = true
        w.window.contentMinSize = CGSize(width: 1, height: 1)
        w.window.setFrame(begin, display: false)
        w.window.contentView?.alphaValue = 0.01
        w.window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.18
            w.window.contentView?.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0 : 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.2, 1)
            w.window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard !w.transcriptSessions.isDisposed else { return }
                w.growing = false
                w.window.contentMinSize = CGSize(width: 560, height: 520)
                if let content = w.window.contentView { w.scene.resize(to: content.bounds.size, live: false) }
                w.window.makeKeyAndOrderFront(nil)
                w.workbench.detail.composer?.focus()
            }
        })
        return w
    }

    // MARK: Tear (f182–f186)

    func tear(_ e: AutoScene.TearEvent, from source: OrganicWindow) {
        switch e {
        case .begin(let id, let p, let row, let press):
            guard tearing == nil, let c = store.conversation(id), !source.isCollapsed, !source.window.styleMask.contains(.fullScreen) else {
                source.scene.endTear(kept: true); return
            }
            let t = TearSession(id: id, conversation: c, source: source, row: row, press: press)
            tearing = t
            t.begin(at: p, sourceHasOthers: source.scene.members.contains { $0.id != id })
            // The clock stops while a tear is out, so its lost-release check runs on a timer of its own.
            tearWatch?.invalidate()
            tearWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak source] _ in
                MainActor.assumeIsolated { source?.scene.endPressIfButtonReleased() }
            }
            // For recordings: the panel is a window of its own.
            if let out = o.output { try? "\(t.windowNumber)".write(toFile: out + "/panel-window.txt", atomically: true, encoding: .utf8) }
        case .move(let p):
            tearing?.move(p)
        case .drop(let p):
            guard let t = tearing else { return }
            tearing = nil; tearWatch?.invalidate(); tearWatch = nil
            switch t.outcome(at: p) {
            case .back:
                t.flyBack { source.scene.endTear(kept: true) }
            case .merge(let target, let index):
                // The conversation and its editor move; the target shows it full where it was dropped.
                guard source.transcriptSessions.transfer(t.id, to: target.transcriptSessions) else {
                    t.flyBack { source.scene.endTear(kept: true) }; return
                }
                target.scene.discardTranscriptColumn(t.id)
                source.prepareConversationTransfer(t.id, closing: t.single)
                let composer = source.scene.composers.release(t.id)
                source.scene.endTear(kept: false)
                if let composer { target.scene.adoptComposer(composer, for: t.id) }
                target.scene.receive(t.conversation, at: index)
                // Normie shows it too: the target's own selection, not only its hidden scene (TearSession: current = id).
                if target.shell.mode == .normie { target.workbench.memberOrder = target.scene.order; _ = target.workbench.select(t.id); target.workbench.remountComposer() }
                t.retire()
                target.window.makeKeyAndOrderFront(nil)
                if t.single { source.window.close() }
            case .newWindow(let at):
                guard source.transcriptSessions.canHandoff else { t.flyBack { source.scene.endTear(kept: true) }; return }
                source.prepareConversationTransfer(t.id, closing: t.single)
                let transcript = source.transcriptSessions.release(t.id)
                let composer = source.scene.composers.release(t.id)
                source.scene.endTear(kept: false)
                let size = source.window.frame.size
                openWindow(for: t.id, composer: composer, transcript: transcript, size: size == .zero ? CGSize(width: 1000, height: 760) : size, centre: at, from: at, screen: nil)
                t.retire(after: 0.2)
                if t.single { source.window.close() }
            }
        case .cancel:
            guard let t = tearing else { return }
            tearing = nil; tearWatch?.invalidate(); tearWatch = nil
            t.flyBack { source.scene.endTear(kept: true) }
        }
    }

    /// Merge All Conversation Windows: every other window's members join `target` at its end, and those windows close.
    /// Merge All (f188; WindowCoordinator.mergeSources): only when every window may take part, none keeps New Chat's
    /// unsent words, and no conversation is in two of them; else a beep.
    func mergeWindows(into target: OrganicWindow) {
        let others = windows.filter { $0 !== target }
        var seen = Set(target.scene.members.map(\.id))
        guard !others.isEmpty, target.allowsTransfer,
              others.allSatisfy({ $0.allowsTransfer && !$0.scene.members.isEmpty && !$0.hasUnboundDraft }),
              others.allSatisfy({ $0.scene.members.allSatisfy { seen.insert($0.id).inserted } }) else { NSSound.beep(); return }
        for w in others {
            if let id = w.scene.members.first?.id { w.prepareConversationTransfer(id, closing: true) }
            for c in w.scene.members {
                // allowsTransfer preflights interaction on both owners; no structural mutation before adoption.
                guard w.transcriptSessions.transfer(c.id, to: target.transcriptSessions) else { NSSound.beep(); return }
                target.scene.discardTranscriptColumn(c.id)
                if let composer = w.scene.composers.release(c.id) { target.scene.adoptComposer(composer, for: c.id) }
                target.scene.admit(c, reason: "merged")
            }
            w.window.close()
        }
        if target.shell.mode == .normie { target.workbench.remountComposer() }
    }

    /// Manual closes save the surviving set, or the last window itself, before presentation owners are torn down.
    func closing(_ w: OrganicWindow) {
        guard windows.contains(where: { $0 === w }) else { return }
        startupRestorePending = false
        if windows.count == 1 {
            demoTimer?.invalidate(); demoTimer = nil
            hoverTimer?.invalidate(); hoverTimer = nil
            swapTimer?.invalidate(); swapTimer = nil
        }
        if !isTerminating && !automated { saveWindows(windows.count == 1 ? [w] : windows.filter { $0 !== w }) }
        if tearing?.source === w { tearing?.retire(); tearing = nil; tearWatch?.invalidate(); tearWatch = nil }
    }
    func closed(_ w: OrganicWindow) { windows.removeAll { $0 === w } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard windows.isEmpty else { return true }
        startupRestorePending = false
        return restoreWindows(windowRecords()) == nil
    }

    /// Cmd+N starts a fresh draft; Dock reopen restores the retained working set instead.
    @discardableResult func newChatWindow(present: Bool = true) -> OrganicWindow? {
        startupRestorePending = false
        var saved = defaultWindowRecord()
        saved.normie = true; saved.members = []; saved.current = ""; saved.composingNew = true
        let w = restoreWindows([WindowRestoration(saved: saved)], present: present)
        if !automated { saveWindows() }
        return w
    }

    /// A fresh Normie owner for Tools' reveal command.
    @discardableResult func openConversationWindow(members: [String]?) -> OrganicWindow? {
        guard let screen = NSScreen.main else { return nil }
        let vis = screen.visibleFrame, size = CGSize(width: min(1280, vis.width - 40), height: min(820, vis.height - 40))
        let w = OrganicWindow(app: self, frame: CGRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2, width: size.width, height: size.height),
                              screen: screen, members: members, normie: true, o: o)
        windows.append(w)
        attachLive(w)
        if presentsWindows { w.show(focus: true) }
        return w
    }
}
