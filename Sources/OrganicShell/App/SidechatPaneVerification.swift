import AppKit
import QuartzCore

private actor P4SidechatFixture: CoreTransport {
    private var opened = 0
    private var closed: [String] = []

    nonisolated func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func closedIDs() -> [String] { closed }

    func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
        switch path {
        case "/sidechat/open":
            opened += 1
            return ["threadId": .string("child-\(opened)"), "parentThreadId": body?["parentThreadId"] ?? .null,
                    "lease": "fixture", "cursor": 0]
        case "/sidechat/events":
            try await Task.sleep(for: .seconds(30))
            return ["cursor": body?["since"] ?? 0, "events": []]
        case "/sidechat/close":
            if let id = body?["threadId"]?.stringValue { closed.append(id) }
            return [:]
        default:
            throw CoreWire.failure("Unexpected P4 fixture request")
        }
    }
}

@MainActor enum SidechatPaneVerification {
    static func run(to path: String) -> Int32 {
        var total = 0
        var findings = 0
        func check(_ passed: Bool, _ name: String) {
            total += 1
            if !passed {
                findings += 1
                print("FINDING: \(name)")
            }
        }

        let output = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for scale: CGFloat in [1, 2] {
                try exercise(scale: scale, output: output, check: check)
                var hostResults: [(Bool, String)]?
                Task { @MainActor in
                    do { hostResults = try await exerciseHost(scale: scale) }
                    catch { hostResults = [(false, "P4 host: \(error)")] }
                }
                let deadline = Date().addingTimeInterval(15)
                while hostResults == nil && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                for result in hostResults ?? [(false, "P4 host timed out")] { check(result.0, result.1) }
            }
        } catch {
            check(false, String(describing: error))
        }
        print("sidechat-pane: \(total) checks, \(findings) findings")
        return findings == 0 ? 0 : 1
    }

    private static func exerciseHost(scale: CGFloat) async throws -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        func check(_ value: Bool, _ name: String) { results.append((value, "P4 host \(scale)x: " + name)) }
        let wire = P4SidechatFixture()
        var options = Options()
        options.mock = true
        options.mockPaused = true
        options.live = false
        options.ambient = false
        let defaults = UserDefaults(suiteName: "p4-host-" + UUID().uuidString)!
        let app = AppController(options, windowDefaults: defaults, presentsWindows: false)
        let storage = CoreMemoryStorage()
        let presentation = LocalPresentationState(store: app.store, scope: "p4-host", storage: storage)
        let runtime = LiveConversationRuntime(store: app.store, client: wire, presentation: presentation)
        app.live = runtime
        app.runtime = runtime
        let parent = Conversation(id: "p4-parent", title: "Parent")
        parent.backendThreadID = "parent"
        parent.isLiveConversation = true
        app.store.add(parent)
        let screen = NSScreen.screens.first!
        let owner = OrganicWindow(app: app, frame: CGRect(x: 0, y: 0, width: 1500, height: 800),
                                  screen: screen, members: [parent.id], normie: false, o: options)
        app.windows = [owner]
        let scene = owner.scene
        scene.manualSettle = true
        scene.scale = scale
        scene.enterFocused(parent.id, reason: "p4-fixture")
        scene.settle()
        func menuEnabled() -> Bool {
            scene.orbMenu.present(parent, at: CGPoint(x: 50, y: 50), in: scene.overlayPlane, right: false)
            let result = scene.orbMenu.state.enabled(.sidechat)
            scene.orbMenu.dismiss(animated: false)
            return result
        }
        check(!menuEnabled(), "unavailable capability disables menu")
        runtime.sidechats.bind(instance: "fixture", available: true)
        check(menuEnabled(), "available live parent enables menu")
        let eligibility = scene.sidechatEligible
        scene.sidechatEligible = nil
        check(!menuEnabled(), "missing eligibility disables menu")
        scene.sidechatEligible = eligibility
        parent.backendThreadID = nil
        check(!menuEnabled(), "missing backend thread disables menu")
        parent.backendThreadID = "parent"
        parent.isLiveConversation = false
        check(!menuEnabled(), "non-live parent disables menu")
        parent.isLiveConversation = true
        parent.archived = true
        check(!menuEnabled(), "archived parent disables menu")
        parent.archived = false
        let before = scene.layout.columns
        scene.performOrbAction(.sidechat, conversation: parent, column: nil, anchor: .zero)
        for _ in 0..<20_000 where scene.sidechatPane == nil { await Task.yield() }
        guard let host = scene.sidechatPane, let chat = runtime.sidechats.chats.values.first else {
            owner.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            throw CoreWire.failure("P4 host did not open")
        }
        host.setReducedMotion(true)
        check(host.superview === scene.nativePlane && !host.folded, "opens in native plane")
        check(scene.sidechatReserve == 0 && scene.layout.columns == before, "wide open keeps columns")
        check(!host.pane.frame.intersects(scene.layout.columns[0]), "wide pane clears parent")
        results += await exerciseReservation(chat: chat, scale: scale)
        host.pane.onDraft?("P4_PRIVATE_DRAFT")
        host.pane.onFold?()
        check(host.folded && !host.moon.isHidden && runtime.sidechats.chats[chat.id] === chat,
              "fold preserves chat and moon")
        host.moon.invoke?()
        check(!host.folded, "moon reopens pane")
        let archive = Task { @MainActor in
            try await runtime.sidechats.withArchive(["parent"]) { true }
        }
        for _ in 0..<20_000 where !host.confirmation.isShowing { await Task.yield() }
        check(host.confirmation.isShowing && host.confirmation.request.message.contains("Parent"),
              "archive asks about the open sidechat")
        _ = host.confirmation.handleKey(.escape)
        do {
            _ = try await archive.value
            check(false, "archive cancellation prevents commit")
        } catch {
            check(!parent.archived && scene.sidechatPane === host, "archive cancellation preserves host")
        }
        let settingTargets = runtime.sidechats.archiveTargets(parentIDs: ["parent"])
        let settings = Task { @MainActor in
            await app.liveSettings.confirmSidechatClosure?(settingTargets) ?? false
        }
        for _ in 0..<20_000 where !host.confirmation.isShowing { await Task.yield() }
        check(host.confirmation.isShowing && host.confirmation.request.message.contains("Parent"),
              "settings uses the same confirmation surface")
        _ = host.confirmation.handleKey(.escape)
        check(await settings.value == false, "settings cancellation returns false")
        host.requestClose()
        check(host.confirmation.isShowing, "close confirms draft")
        _ = host.confirmation.handleKey(.escape)
        check(scene.sidechatPane === host && !host.closed, "close cancellation preserves host")
        host.requestClose()
        _ = host.confirmation.handleKey(.enter)
        for _ in 0..<20_000 {
            if await wire.closedIDs().contains(chat.id) { break }
            await Task.yield()
        }
        let closed = await wire.closedIDs()
        check(scene.sidechatPane == nil && host.superview == nil && closed.contains(chat.id),
              "close removes host and closes lease")
        runtime.sidechats.edit(chat, text: "late")
        check(scene.sidechatPane == nil, "late runtime event cannot remount a closed host")
        let orbParent = Conversation(id: "p4-orb", title: "Orb parent")
        orbParent.backendThreadID = "orb-thread"
        orbParent.isLiveConversation = true
        app.store.add(orbParent)
        scene.admit(orbParent, reason: "p4-fixture")
        scene.settle()
        check(!scene.columns.contains { $0.conversation === orbParent }, "second parent starts as an orb")
        scene.performOrbAction(.sidechat, conversation: orbParent, column: nil, anchor: .zero)
        for _ in 0..<20_000 where scene.sidechatPane == nil { await Task.yield() }
        guard let second = scene.sidechatPane, let secondID = scene.sidechatChatID else {
            owner.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            throw CoreWire.failure("P4 host did not reopen")
        }
        check(scene.isFocused && scene.columns.contains { $0.conversation === orbParent },
              "opening from orb brings parent into Focused")
        second.setReducedMotion(true)
        owner.shell.setMode(.normie, animated: false)
        check(second.folded, "switching to Normie folds the pane")
        owner.shell.setMode(.organic, animated: false)
        check(scene.sidechatPane === second && !second.moon.isHidden, "returning keeps the moon")
        owner.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        for _ in 0..<20_000 {
            if await wire.closedIDs().contains(secondID) { break }
            await Task.yield()
        }
        let windowClosed = await wire.closedIDs()
        check(second.superview == nil && windowClosed.contains(secondID), "closing window disposes and closes")
        return results
    }

    private static func exerciseReservation(chat: SidechatRuntime.Chat, scale: CGFloat) async -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        func check(_ value: Bool, _ name: String) { results.append((value, "P4 host \(scale)x: " + name)) }
        let profile = DisplayProfile(name: "P4 fixture", frameInterval: 1 / 120,
                                     mmPerPoint: 0.2, persistenceFrames: 0)

        // Async so the waits below suspend: spinning RunLoop.main inside this main-actor task never runs the
        // scene's own main-actor preparation task, so a Split's deferred target would still be pending (lane A).
        func fixture(width: CGFloat, split: Bool = false) async -> (AutoScene, Conversation) {
            let parent = Conversation(id: "reserve-parent", title: "Reservation")
            parent.items = (0..<8).map {
                TranscriptItem(id: "reserve-\($0)", kind: .assistant,
                               text: "Synthetic sidechat parent text", running: false)
            }
            let other = Conversation(id: "reserve-other", title: "Other")
            let store = ConversationStore(conversations: split ? [parent, other] : [parent])
            let scene = AutoScene(size: CGSize(width: width, height: 800), store: store, profile: profile, scale: scale)
            scene.manualSettle = true
            scene.verificationPresented = true
            scene.ambient = false
            var time = CACurrentMediaTime() + 3600
            scene.now = { time }
            scene.install()
            scene.enterFocused(parent.id, reason: "p4-reserve-fixture")
            time = max(time, scene.transitionEnd + 0.1)
            scene.frame(time)
            scene.settle()
            if split {
                _ = scene.openInSplit(other.id, reason: "p4-reserve-split")
                time = max(time, scene.transitionEnd + 0.1)
                scene.frame(time)
                scene.settle()
                let deadline = Date().addingTimeInterval(2)
                while !scene.deferredTargets.isEmpty && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                scene.settle()
            }
            scene.clock.invalidate()
            return (scene, parent)
        }

        let (scene, parent) = await fixture(width: 900)
        let before = scene.layout.columns
        let column = scene.columns[0]
        let oldWidth = column.native.frame.width
        M10ColumnWorkTrace.reset()
        defer { M10ColumnWorkTrace.active = false }
        let began = CACurrentMediaTime()
        scene.openSidechat(parent: parent, chat: chat) { host in
            host.onClose = { [weak scene] in scene?.removeSidechat() }
        }
        let synchronous = (CACurrentMediaTime() - began) * 1000
        let captures = M10ColumnWorkTrace.events.filter {
            $0.name == "column.snapshot" && $0.fields["id"] as? String == parent.id
        }
        guard let host = scene.sidechatPane else {
            scene.disposeTranscriptPresentation()
            check(false, "reservation host opens")
            return results
        }
        host.setReducedMotion(true)
        check(scene.sidechatReserve > 0, "narrow Focused reserves space")
        check(!scene.layout.columns.contains { $0.intersects(host.pane.frame) }, "narrow pane clears every column")
        let targetWidth = scene.fullWidth(0, scene.layout)
        let targetHits = captures.filter { abs(($0.fields["width"] as? CGFloat ?? -1) - targetWidth) < 0.5 / scale }
        let departure = captures.filter { abs(($0.fields["width"] as? CGFloat ?? -1) - oldWidth) < 0.5 / scale }
        check(targetHits.isEmpty && scene.deferredTargets[parent.id] != nil &&
              abs(column.native.frame.width - oldWidth) < 0.5 / scale, "visible parent reflow is deferred")
        scene.frame(scene.now() + profile.frameInterval)
        let firstFrame = (CACurrentMediaTime() - began) * 1000
        let deadline = Date().addingTimeInterval(2)
        while scene.deferredTargets[parent.id] != nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let delivered = M10ColumnWorkTrace.events.last {
            $0.name == "scene.deferred.deliver" && $0.fields["id"] as? String == parent.id
        }
        scene.settle()
        check(delivered != nil && scene.deferredTargets.isEmpty && !column.native.isHidden &&
              abs(column.native.frame.width - targetWidth) < 0.5 / scale,
              "deferred parent body becomes visible at target width")
        let delivery = delivered.map { ($0.start - began) * 1000 } ?? -1
        let departureMs = departure.reduce(0.0) { $0 + ($1.end - $1.start) * 1000 }
        print("P4 timing \(scale)x: sync_ms=\(synchronous) departure_count=\(departure.count) " +
              "departure_ms=\(departureMs) first_frame_ms=\(firstFrame) delivery_ms=\(delivery)")
        scene.placeSidechat()
        host.pane.frame.origin.x += 1
        let stationaryFrame = host.pane.frame
        for step in 1...3 { scene.frame(scene.now() + Double(step) * profile.frameInterval) }
        check(host.pane.frame == stationaryFrame, "stationary frames do not replace pane geometry")
        scene.sidechatPlacementCache = nil
        scene.placeSidechat()
        scene.foldSidechat()
        check(host.folded && !host.moon.isHidden && scene.sidechatReserve == 0 && scene.layout.columns == before,
              "fold restores columns and keeps moon")
        host.moon.invoke?()
        check(!host.folded && scene.sidechatReserve > 0, "moon reopens and reserves space")
        scene.resize(to: CGSize(width: 560, height: 800), live: false)
        check(scene.sidechatReserve == 0 && host.pane.frame.intersects(scene.layout.columns[0]),
              "resize falls back to overlay when space is insufficient")
        scene.resize(to: CGSize(width: 900, height: 800), live: false)
        check(scene.sidechatReserve > 0 && !host.pane.frame.intersects(scene.layout.columns[0]),
              "resize restores reservation when space returns")
        host.pane.apply(.init(), parentTitle: parent.title)
        host.requestClose()
        check(scene.sidechatPane == nil && host.superview == nil && scene.sidechatReserve == 0,
              "close restores columns and removes host")
        scene.disposeTranscriptPresentation()

        let (splitScene, splitParent) = await fixture(width: 1400, split: true)
        check(splitScene.layout.separateInputs && splitScene.columns.count == 2, "split fixture has two columns")
        let splitColumn = splitScene.columns.first { $0.conversation === splitParent }!
        let splitOldWidth = splitColumn.native.frame.width
        let splitOldRect = splitScene.layout.columns[0]
        let splitWasHidden = splitColumn.native.isHidden
        check(!splitWasHidden && splitScene.deferredTargets.isEmpty &&
              abs(splitOldWidth - splitOldRect.width) < 0.5 / scale, "split fixture has settled visible parent")
        M10ColumnWorkTrace.reset()
        splitScene.openSidechat(parent: splitParent, chat: chat) { _ in }
        let splitWidth = splitScene.fullWidth(0, splitScene.layout)
        let splitCaptures = M10ColumnWorkTrace.events.filter {
            $0.name == "column.snapshot" && $0.fields["id"] as? String == splitParent.id
        }
        let widths = splitCaptures.map { $0.fields["width"] as? CGFloat ?? -1 }
        let pending = splitScene.deferredTargets[splitParent.id] != nil
        print("P4 split \(scale)x: old_rect=\(splitOldRect) new_rect=\(splitScene.layout.columns[0]) " +
              "old_native=\(splitOldWidth) native=\(splitColumn.native.frame.width) " +
              "hidden_before=\(splitWasHidden) pending=\(pending) captures=\(widths)")
        check(!splitCaptures.contains { abs(($0.fields["width"] as? CGFloat ?? -1) - splitWidth) < 0.5 / scale } &&
              splitScene.deferredTargets[splitParent.id] != nil &&
              abs(splitColumn.native.frame.width - splitOldWidth) < 0.5 / scale, "split parent reflow is deferred")
        let splitDeadline = Date().addingTimeInterval(2)
        while !splitScene.deferredTargets.isEmpty && Date() < splitDeadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        splitScene.settle()
        check(splitScene.deferredTargets.isEmpty && !splitColumn.native.isHidden &&
              abs(splitColumn.native.frame.width - splitWidth) < 0.5 / scale, "split parent body reaches target")
        if let splitHost = splitScene.sidechatPane {
            check(splitScene.sidechatReserve > 0, "split reserves space")
            check(!splitScene.layout.columns.contains { $0.intersects(splitHost.pane.frame) },
                  "split pane clears both columns")
            if let other = splitScene.members.first(where: { $0 !== splitParent }) {
                splitScene.performOrbAction(.focused, conversation: other, column: nil, anchor: .zero)
                for _ in 0..<2_000 where splitScene.sidechatReserve > 0 { await Task.yield() }
                check(splitHost.folded && splitScene.sidechatReserve == 0, "parent leaving columns restores space")
            }
        } else {
            check(false, "split host opens")
        }
        splitScene.removeSidechat()
        splitScene.disposeTranscriptPresentation()

        let (tightSplit, tightParent) = await fixture(width: 900, split: true)
        tightSplit.openSidechat(parent: tightParent, chat: chat) { _ in }
        if let tightHost = tightSplit.sidechatPane {
            check(tightSplit.sidechatReserve == 0 && tightHost.pane.frame.intersects(tightSplit.layout.columns[0]),
                  "split without room overlays the parent")
        } else {
            check(false, "tight split host opens")
        }
        tightSplit.removeSidechat()
        tightSplit.disposeTranscriptPresentation()

        let (smallScene, smallParent) = await fixture(width: 560)
        smallScene.openSidechat(parent: smallParent, chat: chat) { _ in }
        if let smallHost = smallScene.sidechatPane {
            check(smallScene.sidechatReserve == 0 && smallHost.pane.frame.intersects(smallScene.layout.columns[0]),
                  "too-small window keeps overlay without reserve")
        } else {
            check(false, "small host opens")
        }
        smallScene.removeSidechat()
        smallScene.disposeTranscriptPresentation()
        return results
    }

    private static func exercise(scale: CGFloat, output: URL, check: (Bool, String) -> Void) throws {
        let draft = "PRIVATE_SIDECHAT_OFFSCREEN_20F"
        let item = TranscriptItem(id: "response", turnID: "turn", kind: .assistant, text: "The lantern holds its glow.")
        let parent = Conversation(id: "parent", title: "A lantern study")
        parent.items = [item]
        let body = NativeTranscript(conversation: parent)
        body.frame = CGRect(x: 64, y: 58, width: 480, height: 520)
        let root = NativeFlippedView(frame: CGRect(x: 0, y: 0, width: 970, height: 640))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        var time: TimeInterval = 100
        let host = SidechatPanePresentation(reducedMotion: false, now: { time })
        let pane = host.pane
        root.addSubview(body)
        root.addSubview(host)
        host.frame = root.bounds
        body.refresh(allowHidden: true)
        let selection = NSRange(location: 4, length: 7)
        body.setSelectedRange(selection, itemID: item.id)
        check(body.sidechatSelection(itemID: item.id)?.range == selection, "anchor uses raw selected parent text")
        let anchor = root.convert(body.sidechatSelection(itemID: item.id)?.rect ?? .zero, from: body)
        let wide = ExpandPaneLayout.resolve(in: root.bounds, parent: body.frame, selection: anchor, scale: scale)
        host.place(wide)
        func frame(_ name: String, after seconds: TimeInterval = 0) {
            time += seconds
            host.advance(at: time)
            root.layoutSubtreeIfNeeded()
            let file = output.appendingPathComponent("pane-\(name)@\(Int(scale))x.png")
            Offscreen.write(NativeViewBitmap.capture(root, scale: scale), file)
        }

        check(!wide.overlaysParent && wide.pane.minX > body.frame.maxX, "pane opens beside the parent")
        check(wide.anchor == CGPoint(x: body.frame.maxX, y: (anchor.midY * scale).rounded() / scale), "page edge")
        var closes = 0
        host.onClose = { closes += 1 }
        pane.apply(.init(items: [item], draft: draft, running: true, finalAnswerID: item.id), parentTitle: parent.title)
        frame("moon")
        check(host.moon.accessibilityPerformPress(), "moon can open through AX")
        frame("opening", after: 0.20)
        check(host.reveal > 0 && host.reveal < 1, "pane has an opening path")
        frame("open", after: 0.30)
        check(host.reveal == 1 && pane.editor.accessibilityLabel() == "Sidechat message",
              "open pane editor has AX label")
        var sends = 0
        pane.onSendToMain = { sends += 1 }
        pane.sendToMain()
        check(sends == 0 && !pane.canSendToMain, "sidechat rejects a partial reply")
        pane.editor.cancelOperation(nil)
        frame("fold", after: 0.40)
        check(host.folded && !host.closed && closes == 0 && pane.editor.string == draft,
              "Fold preserves sidechat draft")
        check(pane.isAccessibilityHidden(), "Fold hides the pane from accessibility")
        host.open()
        pane.apply(.init(items: [item], draft: draft, finalAnswerID: item.id), parentTitle: parent.title)
        pane.sendToMain()
        host.acceptQuoteReceipt()
        frame("return", after: 0.20)
        check(sends == 1 && host.dropProgress != nil && !host.folded && !pane.canSendToMain,
              "receipt falls and keeps the sidechat open")

        let attachment: JSONValue = ["attachmentType": "organicSidechatQuote", "identityKey": "returned",
                                     "payload": ["source": "Sidechat A", "summary": .string(item.text),
                                                 "anchorTurnId": "turn", "order": 0]]
        guard let quote = SidechatQuote(attachment) else { throw CoreWire.failure("Malformed sidechat pane quote") }
        parent.sidechatQuotes = [quote]
        body.refresh(allowHidden: true)
        let reply = body.itemFrame(itemID: item.id)
        let source = body.sidechatQuoteFrame(id: quote.id)
        check((source?.minY ?? -1) >= (reply?.maxY ?? .infinity) && parent.items == [item] && parent.draft.isEmpty,
              "hydrated source row follows the parent turn and leaves its composer alone")
        frame("returned", after: 0.40)

        let ghost = pane.transcript.conversation
        ghost.draft = draft
        let storage = CoreMemoryStorage()
        let store = ConversationStore(conversations: [parent, ghost])
        let presentation = LocalPresentationState(store: store, scope: "p3-fixture", storage: storage)
        presentation.setWindows([.init(id: ghost.id, payload: ["draft": .string(draft)])])
        try presentation.save()
        check(!storage.values.values.contains { String(decoding: $0, as: UTF8.self).contains(draft) },
              "sidechat pane stays out of shared persistence")
        ghost.draft = ""

        host.setReducedMotion(true)
        root.setFrameSize(CGSize(width: 380, height: 480))
        host.frame = root.bounds
        let narrow = ExpandPaneLayout.resolve(in: root.bounds, parent: root.bounds, selection: nil, scale: scale)
        host.place(narrow)
        host.fold()
        host.open()
        frame("narrow-reduced")
        check(narrow.overlaysParent && root.bounds.contains(narrow.pane), "narrow pane fits over the parent")
        check(host.reveal == 1 && !host.hasMotion, "reduced motion places the pane in one step")

        pane.apply(.init(draft: draft), parentTitle: parent.title)
        let replace = NSRange(location: 0, length: (draft as NSString).length)
        pane.editor.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0), replacementRange: replace)
        var submits = 0
        pane.onSend = { submits += 1 }
        pane.submitDraft()
        check(pane.editor.hasMarkedText() && submits == 0 && pane.content.draft == draft, "IME holds private draft")
        pane.editor.insertText("候補", replacementRange: pane.editor.markedRange())
        if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time,
                                        windowNumber: 0, context: nil, characters: "\r",
                                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            pane.editor.keyDown(with: enter)
        }
        check(!pane.editor.hasMarkedText() && submits == 1 && pane.content.draft == "候補", "committed editor submits")
        var accepted: Bool?
        host.confirmClosure(title: "Change settings?", names: ["Study", "Notes"]) { accepted = $0 }
        check(host.confirmation.request.message.hasSuffix("Study\nNotes"), "group confirmation names sidechats")
        _ = host.confirmation.handleKey(.escape)
        check(accepted == false && !host.closed, "Esc cancels grouped confirmation")
        host.requestClose()
        check(host.confirmation.isShowing && closes == 0, "Close confirms an unsent draft")
        frame("confirm")
        _ = host.confirmation.handleKey(.enter)
        check(host.closed && closes == 1 && pane.editor.string.isEmpty && pane.editor.undoManager?.canUndo != true,
              "Close clears the private editor and undo")
        frame("closed")
        host.dispose()
    }
}
