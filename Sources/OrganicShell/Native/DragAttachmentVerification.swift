#if M1138_ATTACHMENT_SELFTEST
import AppKit
import QuartzCore

private final class AttachmentMockTransport: CoreTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var bodies: [JSONValue] = []
    var requests: Int { lock.withLock { count } }
    var messages: [JSONValue] { lock.withLock { bodies } }
    func request(_ method: String, path: String, body: JSONValue?, timeout: TimeInterval?) async throws -> JSONValue {
        lock.withLock { count += 1; bodies.append(body ?? .null) }
        return body?["method"]?.stringValue == "turn/start" ? ["turnId": "mock-wire-turn"] : [:]
    }
    func events(since: Int, threadID: String?) -> AsyncThrowingStream<CoreEvent, Error> { .init { $0.finish() } }
}

/// Product-component fixture: private pasteboards, synthetic conversations, isolated defaults and memory sidecars.
@MainActor enum DragAttachmentVerification {
    static weak var currentConversation: Conversation?
    static func run(output: URL, check: (Bool, String) -> Void) async throws {
        func exact(_ value: String?, _ expected: String) -> Bool {
            value.map { Array($0.utf8) == Array(expected.utf8) } ?? false
        }
        let suite = "attachment-verification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = AttachmentMockTransport()
        let previewClock = SceneClock()
        let a = Conversation(id: "A", title: "Source"), b = Conversation(id: "B", title: "Recipient")
        currentConversation = a
        defer { currentConversation = nil }
        let original = "First \u{4E2D}\u{6587} \u{1F319}\nSecond line e\u{0301}\r\n\tTail"
        a.items = [.init(id: "source", turnID: "turn", kind: .assistant, text: original)]
        a.draft = "draft A"; b.draft = "draft B"
        b.queued = [.init(id: "waiting", text: "queued text")]
        let store = ConversationStore(conversations: [a, b])
        let ca = NativeComposer(conversation: a, store: store), cb = NativeComposer(conversation: b, store: store)
        let currentComposer = ca
        let host = NativeFlippedView(frame: CGRect(x: 0, y: 0, width: 900, height: 180))
        host.addSubview(ca); host.addSubview(cb)
        cb.frame = CGRect(x: 0, y: 0, width: 640, height: 48); cb.targetWidth = 640
        cb.needsLayout = true; cb.layoutSubtreeIfNeeded()
        let sidecars = CoreMemoryAttachmentInputs()
        let saved = LocalPresentationState(store: store, scope: "fixture-attachments", storage: CoreDefaultsStorage(defaults), attachmentInputs: sidecars)
        var published = 0, sends = 0
        cb.onAttachmentsChange = { _ in published += 1 }
        cb.onSubmit = { submission in
            sends += 1
            Task { _ = try? await transport.rpc("turn/start", params: ["input": .array(submission.attachments.compactMap(\.input))]) }
        }
        cb.onSend = { _ in sends += 1 }
        let quote = DragAttachmentPayload.Quote(conversationID: a.id, itemID: "source", range: NSRange(location: 0, length: original.utf16.count), exactText: original)
        let file = DragAttachmentPayload.File(url: URL(fileURLWithPath: "/fixture/first.png"), id: "file-one")
        let payload = DragAttachmentPayload(values: [.file(file), .quote(quote)])
        let existing = Attachment(id: "existing", name: "existing.txt", symbol: "doc", input: ["type": "text", "text": "existing"])
        cb.attachments = [existing]; b.attachments = [existing]
        let session = DragAttachmentPayload.Session(target: cb.attachmentDropTarget)
        let beforeA = ca.attachments, draftA = ca.text, queue = b.queued
        let editor = cb.textView, undo = editor.undoManager!
        editor.replaceWholeDraftUndoably("draft B edited")
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let draft = cb.text, selection = editor.selectedRanges, undoName = undo.undoActionName, undoLevel = undo.groupingLevel
        check(cb.appendDragAttachments(payload, session: session), "entry.accept")
        check(published == 1, "entry.publish-once")
        check(cb.attachments == [existing] + payload.attachments, "entry.preserve-order-and-dedup")
        check(b.attachments == cb.attachments, "entry.bound-recipient-published")
        check(currentConversation === a && currentComposer === ca && ca.attachments == beforeA && ca.text == draftA && a.attachments.isEmpty && a.draft == "draft A", "entry.recipient-B-not-current-A")
        check(cb.text == draft && editor.selectedRanges == selection, "entry.editor-text-selection")
        check(editor.undoManager === undo && undo.canUndo && undo.undoActionName == undoName && undo.groupingLevel == undoLevel, "entry.undo-stack-preserved")
        undo.undo()
        check(cb.text == "draft B", "entry.undo-content-preserved")
        undo.redo()
        check(cb.text == draft, "entry.redo-content-preserved")
        check(!cb.appendDragAttachments(payload, session: session) && published == 1, "entry.repeated-callback-once")
        let changedCallback = DragAttachmentPayload(values: [.file(.init(url: URL(fileURLWithPath: "/fixture/second.txt"), id: "late-id"))])
        check(!cb.appendDragAttachments(changedCallback, session: session) && !cb.attachments.contains { $0.id == "late-id" }, "entry.session-idempotence")
        let another = DragAttachmentPayload.Session(target: cb.attachmentDropTarget)
        check(!cb.appendDragAttachments(payload, session: another) && published == 1, "entry.existing-id-dedup")
        let rebound = NativeComposer(conversation: b, store: store)
        check(rebound.attachments == cb.attachments, "entry.rebind-durable")
        try saved.save()
        let restoredStore = ConversationStore()
        let restoredState = LocalPresentationState(store: restoredStore, scope: "fixture-attachments", storage: CoreDefaultsStorage(defaults), attachmentInputs: sidecars)
        restoredState.restore()
        let restored = restoredStore.conversation("B")!.attachments
        check(restored.map(\.id) == cb.attachments.map(\.id), "entry.restore-ids-order")
        check(restored.last?.input == payload.attachments.last?.input && sidecars.writes > 0, "entry.restore-exact-quote-sidecar")
        check(exact(restored.last?.input?["text"]?.stringValue, original), "entry.restore-quote-utf8-identical")
        let restoredQuote = restored.last.flatMap { DragAttachmentPayload.restoreQuote(from: $0) }
        check(restoredQuote == quote, "entry.restore-source-id-item-range")
        check(restoredQuote?.conversationID == quote.conversationID, "quote.restore-conversation-id")
        check(restoredQuote?.itemID == quote.itemID, "quote.restore-item-id")
        check(restoredQuote?.range == quote.range, "quote.restore-utf16-range")
        check(exact(restoredQuote?.exactText, quote.exactText), "quote.restore-exact-text")
        // Exercise the unchanged production ready-input path, with an independent in-memory Core.
        let wireTransport = AttachmentMockTransport()
        let wireChat = Conversation(id: "wire", title: "Wire probe")
        wireChat.deviceID = "mock-wire"
        wireChat.backendThreadID = "mock-wire-thread"
        let wireStore = ConversationStore(conversations: [wireChat])
        let wireState = LocalPresentationState(store: wireStore, scope: "wire-probe",
            storage: CoreMemoryStorage(), attachmentInputs: CoreMemoryAttachmentInputs())
        let models = ModelCatalog.models
        let wireRuntime = LiveConversationRuntime(store: wireStore, client: wireTransport, presentation: wireState)
        ModelCatalog.models = models; wireRuntime.isConnected = true
        var wireReceipt: CoreSubmissionReceipt?
        let wireAdmitted = wireRuntime.submit(.init(identity: wireChat.id, text: "",
            attachments: Array(restored.suffix(1)), settings: b.next), in: wireChat) { wireReceipt = $0 }
        for _ in 0..<1000 {
            if wireReceipt != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        wireRuntime.shutdown()
        check(wireAdmitted && wireReceipt?.result == .accepted && wireTransport.requests == 1, "quote.wire-runtime-accepted")
        let wireQuote = wireTransport.messages.first?["params"]?["input"]?.arrayValue?.first
        check(wireQuote?.objectValue.map { Set($0.keys) } == Set(["type", "text"]), "quote.wire-exact-type-text-keys")
        check(wireQuote == ["type": "text", "text": .string(original)], "quote.wire-exact-input-value")
        a.items[0].text += " streamed suffix"; store.changed(a)
        check(exact(cb.attachments.last?.input?["text"]?.stringValue, original), "quote.snapshot-after-source-stream")
        check(exact(restored.last?.input?["text"]?.stringValue, original), "quote.restored-snapshot-after-stream")
        try saved.save()
        let afterStreamStore = ConversationStore()
        let afterStream = LocalPresentationState(store: afterStreamStore, scope: "fixture-attachments", storage: CoreDefaultsStorage(defaults), attachmentInputs: sidecars)
        afterStream.restore()
        check(exact(afterStreamStore.conversation("B")?.attachments.last?.input?["text"]?.stringValue, original), "quote.save-after-stream-remains-snapshot")
        check(cb.text == draft && b.queued == queue && cb.queued == queue, "entry.no-draft-or-queue-write")
        let stale = DragAttachmentPayload.Session(target: cb.attachmentDropTarget)
        cb.invalidateAttachmentDropTarget()
        check(!cb.appendDragAttachments(changedCallback, session: stale), "entry.stale-generation-rejected")
        let freshTarget = cb.attachmentDropTarget
        cb.invalidateAttachmentDropTarget(matching: stale.target)
        check(cb.attachmentDropTarget == freshTarget, "entry.stale-cancel-cannot-revoke-new-target")
        check(!ca.appendDragAttachments(changedCallback, session: .init(target: cb.attachmentDropTarget)), "entry.wrong-composer-rejected")
        let reboundTarget = DragAttachmentPayload.Session(target: cb.attachmentDropTarget)
        cb.bind(to: b, store: store)
        check(!cb.appendDragAttachments(changedCallback, session: reboundTarget), "entry.rebind-revokes-old-target")
        let drafts = NativeComposerSessions()
        let newChat = drafts.draft().composer
        var newChatPublications = 0
        newChat.onAttachmentsChange = { _ in newChatPublications += 1 }
        let chatCount = store.conversations.count
        check(newChat.appendDragAttachments(payload, session: .init(target: newChat.attachmentDropTarget)), "entry.unsent-new-chat-accepts")
        check(newChat.identity == nil && newChatPublications == 1 && store.conversations.count == chatCount, "entry.new-chat-no-conversation-created")
        check(drafts.draft().composer === newChat && drafts.draft().composer.attachments == payload.attachments, "entry.new-chat-remount-retains-files")
        saved.setWindows([.init(id: "draft-window", payload: ["draft": ""], files: newChat.attachments.map(LocalPresentationState.FileState.init))])
        try saved.save()
        let draftState = LocalPresentationState(store: ConversationStore(), scope: "fixture-attachments", storage: CoreDefaultsStorage(defaults), attachmentInputs: sidecars)
        check(draftState.restoreAttachments(draftState.windows[0].files ?? []).map(\.input) == newChat.attachments.map(\.input), "entry.new-chat-window-sidecar-restores-exact-input")

        for condition in ["loading", "ime", "choosing", "voice", "disabled"] {
            let c = NativeComposer()
            c.setText("guard draft"); c.attachments = [existing]
            let e = c.textView, manager = e.undoManager!
            e.replaceWholeDraftUndoably("guard edited")
            e.setSelectedRange(NSRange(location: 1, length: 2))
            var publications = 0
            c.onAttachmentsChange = { _ in publications += 1 }
            var picker: (@MainActor ([Attachment]) -> Void)?
            switch condition {
            case "loading": c.state.loading = true
            case "ime": e.setMarkedText("\u{5019}", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 2))
            case "choosing": c.onChooseAttachments = { picker = $0 }; c.chooseAttachments()
            case "voice": c.state.voice = "heard"
            default: c.isEnabled = false
            }
            let text = c.text, ranges = e.selectedRanges, marked = e.markedRange(), markedText = e.hasMarkedText(), canUndo = manager.canUndo
            let files = c.attachments, queued = c.queued, name = manager.undoActionName
            let attempt = DragAttachmentPayload.Session(target: c.attachmentDropTarget)
            check(!c.appendDragAttachments(payload, session: attempt), "eligibility.\(condition).reject")
            check(!c.showAttachmentPreview(payload, session: attempt, title: "Protected", clock: previewClock, at: 0), "eligibility.\(condition).preview-reject")
            check(c.attachments == files && publications == 0 && c.queued == queued && c.text == text, "eligibility.\(condition).unchanged")
            check(e.selectedRanges == ranges && e.markedRange() == marked && e.hasMarkedText() == markedText, "eligibility.\(condition).marked-selection-preserved")
            check(manager.canUndo == canUndo && manager.undoActionName == name && e.undoManager === manager, "eligibility.\(condition).undo-preserved")
            picker?([])
        }

        let moon = DragAttachmentPayload(values: [.mockMoon(.init(id: "mock-1", name: "Mock moon", text: "Mock satellite snapshot"))])
        for protection in ["ime", "choosing"] {
            let c = NativeComposer(); c.frame = CGRect(x: 0, y: 0, width: 640, height: 48); c.targetWidth = 640
            c.needsLayout = true; c.layoutSubtreeIfNeeded()
            var completion: (@MainActor ([Attachment]) -> Void)?
            c.onChooseAttachments = { completion = $0 }
            let active = DragAttachmentPayload.Session(target: c.attachmentDropTarget), start = CACurrentMediaTime()
            c.showAttachmentPreview(payload, session: active, title: "Protected", clock: previewClock, at: start)
            c.sampleAttachmentPreview(at: start + 0.05)
            if protection == "ime" {
                c.textView.setMarkedText("\u{5019}", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
            } else { c.chooseAttachments() }
            let marked = c.textView.markedRange(), selected = c.textView.selectedRanges, text = c.text
            check(c.attachmentPreview == nil && !c.attachmentPreviewNeedsFrames, "preview.\(protection)-entry-retires-existing-preview")
            check(!c.appendDragAttachments(payload, session: active) && c.attachments.isEmpty && c.text == text && c.textView.markedRange() == marked && c.textView.selectedRanges == selected, "preview.\(protection)-entry-still-protected")
            completion?([])
        }
        let moonDraft = cb.text, moonQueue = cb.queued
        check(cb.appendDragAttachments(moon, session: .init(target: cb.attachmentDropTarget)), "moon.attached")
        check(cb.text == moonDraft && cb.queued == moonQueue && sends == 0 && !cb.hasPendingSubmission, "moon.attachment-only-no-join-or-send")
        await Task.yield(); await Task.yield()
        check(transport.requests == 0, "entry.mock-transport-zero-requests")

        let preview = NativeComposer()
        let previewHost = NativeFlippedView(frame: CGRect(x: 0, y: 0, width: 900, height: 120))
        previewHost.wantsLayer = true; previewHost.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        preview.frame = CGRect(x: 20, y: 40, width: 640, height: 48); preview.targetWidth = 640
        previewHost.addSubview(preview); preview.needsLayout = true; preview.layoutSubtreeIfNeeded()
        let previewEditor = preview.textView, previewUndo = previewEditor.undoManager
        let editorFrame = previewEditor.frame, clipFrame = preview.scrollView.frame, editorWidth = previewEditor.textContainer?.containerSize.width
        let send = preview.canSend
        var geometry: [CGFloat] = [], requests: [Double?] = []
        preview.onAttachmentPreviewGeometryChange = { geometry.append($0) }
        preview.onAttachmentPreviewFrameRequest = { requests.append($0) }
        let ps = DragAttachmentPayload.Session(target: preview.attachmentDropTarget), t = CACurrentMediaTime()
        check(preview.showAttachmentPreview(payload, session: ps, title: "Recipient", clock: previewClock, at: t), "preview.open")
        check(preview.attachmentPreview?.hint.stringValue == "Attach to Recipient", "preview.attach-caption")
        preview.sampleAttachmentPreview(at: t + 0.05)
        check(preview.attachmentPreviewNeedsFrames && geometry.last! > 0, "preview.entry-100ms-progress")
        let beforeKindChange = geometry.last
        check(preview.showAttachmentPreview(.init(values: [.quote(quote)]), session: ps, title: "Recipient", clock: previewClock, at: t + 0.05), "preview.change-kind")
        check(preview.attachmentPreview?.hint.stringValue == "Quote in Recipient", "preview.quote-caption")
        check(geometry.last == beforeKindChange, "preview.change-kind-keeps-current-geometry")
        preview.sampleAttachmentPreview(at: t + 0.16)
        check(!preview.attachmentPreviewNeedsFrames && preview.attachmentPreview?.progress == 1, "preview.entry-settles")
        check(preview.attachmentPreview?.ghost.frame.height == 26 && preview.attachmentPreview?.ghost.layer?.cornerRadius == 13, "preview.ghost-geometry-26-r13")
        for scale: CGFloat in [1, 2] {
            let image = NativeViewBitmap.capture(previewHost, scale: scale)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("quote-preview-\(Int(scale))x.png"))
        }
        check(preview.attachments.isEmpty && preview.text.isEmpty && preview.canSend == send && !preview.sendButton.isEnabled, "preview.no-model-or-send-change")
        check(preview.textView === previewEditor && previewEditor.frame == editorFrame && preview.scrollView.frame == clipFrame && previewEditor.textContainer?.containerSize.width == editorWidth && previewEditor.undoManager === previewUndo, "preview.retained-editor-geometry-undo")
        let oldPreview = preview.attachmentPreview!
        preview.clearAttachmentPreview(sessionID: ps.id, at: t + 0.17)
        preview.sampleAttachmentPreview(at: t + 0.20)
        check(preview.attachmentPreviewNeedsFrames, "preview.exit-80ms-progress")
        preview.sampleAttachmentPreview(at: t + 0.26)
        let settledRequests = requests.count
        preview.sampleAttachmentPreview(at: t + 2)
        check(preview.attachmentPreview == nil && !preview.attachmentPreviewNeedsFrames && requests.count == settledRequests && requests.last! == nil, "preview.closed-no-frames-or-layer")
        func clean(_ view: NSView) -> Bool {
            (view.layer?.animationKeys() ?? []).isEmpty && (view.layer?.filters ?? []).isEmpty && view.subviews.allSatisfy(clean)
        }
        check(oldPreview.superview == nil && clean(oldPreview) && geometry.last == 0 && previewEditor.attachmentPreviewPlaceholderOpacity == 1 && preview.clipsToBounds, "preview.closed-no-animations-or-filters")
        let fast = DragAttachmentPayload.Session(target: preview.attachmentDropTarget)
        preview.showAttachmentPreview(payload, session: fast, title: "Fast", clock: previewClock, at: t + 3)
        check(preview.appendDragAttachments(payload, session: fast), "preview.fast-drop-before-100ms")
        check(preview.attachmentPreview == nil && !preview.attachmentPreviewNeedsFrames && preview.text.isEmpty, "preview.fast-drop-cleans-up")
        let argumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var reduced = argumentDomain; reduced["toggle.simulateReduceMotion"] = true
        UserDefaults.standard.setVolatileDomain(reduced, forName: UserDefaults.argumentDomain)
        let rm = DragAttachmentPayload.Session(target: preview.attachmentDropTarget)
        preview.showAttachmentPreview(moon, session: rm, title: "Reduced", clock: previewClock, at: t + 4)
        preview.sampleAttachmentPreview(at: t + 4.2)
        check(preview.attachmentPreview?.hint.stringValue == "Attach to Reduced" && preview.attachmentPreview?.displacement == 0 && preview.attachmentPreview?.ghost.isHidden == true && geometry.last == 0, "preview.reduce-motion-caption-without-geometry")
        check(previewEditor.attachmentPreviewPlaceholderOpacity == 1, "preview.reduce-motion-placeholder-static")
        check(preview.appendDragAttachments(moon, session: rm) && preview.attachments.contains { $0.id == "drag.mockMoon.mock-1" }, "preview.reduce-motion-result")
        UserDefaults.standard.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)
        let retired = DragAttachmentPayload.Session(target: preview.attachmentDropTarget)
        preview.showAttachmentPreview(payload, session: retired, title: "Retiring", clock: previewClock, at: t + 5)
        preview.presentationActive = false
        check(preview.attachmentPreview == nil && !preview.attachmentPreviewNeedsFrames && !preview.appendDragAttachments(changedCallback, session: retired), "preview.retirement-revokes-target-and-cleans")
        check(NativeComposerAttachmentPreview.entryDuration == 0.100 && NativeComposerAttachmentPreview.exitDuration == 0.080 && NativeComposerAttachmentPreview.blurRadius == 6, "preview.constants-100-80-blur6")
        await Task.yield()
        check(transport.requests == 0 && sends == 0 && b.queued == queue, "preview.mock-transport-zero-requests-queue-unchanged")

        for segmented in [false, true] {
            for width: CGFloat in [219, 220, 221, 640] {
                for count in [1, 3, 24] {
                    let c = NativeComposer(); c.segment = segmented ? .init(index: 1, isLast: true) : nil
                    c.targetWidth = width; c.frame = CGRect(x: 0, y: 0, width: width, height: 48)
                    c.attachments = (0..<count).map { .init(id: "chip-\($0)", name: String(repeating: "file", count: 20) + "\($0).txt", symbol: "doc") }
                    c.needsLayout = true; c.layoutSubtreeIfNeeded()
                    c.verificationAXScreenOrigin = .zero
                    let label = "chip.\(segmented).\(Int(width)).\(count)"
                    check(!c.attachmentScrollView.isHidden && c.attachmentChips.count == count, label + ".real-list-visible")
                    check(c.attachmentScrollView.frame.maxX <= c.sendButton.frame.minX && c.attachmentScrollView.frame.height == 26, label + ".before-send-26")
                    check(c.attachmentChips.allSatisfy { $0.frame.height == 26 && $0.layer?.cornerRadius == 13 && $0.frame.width <= 190 }, label + ".geometry-26-r13-max190")
                    check(c.attachmentChips.allSatisfy { $0.iconOnly == (width < 220) && $0.label.isHidden == (width < 220) }, label + ".threshold-220")
                    check(c.attachmentChips.allSatisfy { $0.accessibilityLabel()?.hasPrefix("Attachment: ") == true && ($0.accessibilityChildren()?.first as? NSButton) === $0.removeButton && $0.removeButton.accessibilityLabel()?.hasPrefix("Remove ") == true }, label + ".ax-chip-and-remove")
                    if count > 1 { check(c.attachmentContent.frame.width > c.attachmentScrollView.contentSize.width, label + ".scrollable-list") }
                    if count == 3 && width <= 221 {
                        for scale: CGFloat in [1, 2] {
                            let image = NativeViewBitmap.capture(c, scale: scale)
                            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(label + "-\(Int(scale))x.png"))
                        }
                    }
                    c.verificationAXScreenOrigin = .zero
                    func proxies(_ values: [Any], depth: Int = 0) -> [NativeInteractionProxy] {
                        guard depth < 30 else { return [] }
                        return values.compactMap { $0 as? NativeInteractionProxy }.flatMap { [$0] + proxies($0.accessibilityChildren() ?? [], depth: depth + 1) }
                    }
                    let ids = c.attachments.map(\.id)
                    for id in ids {
                        c.needsLayout = true; c.layoutSubtreeIfNeeded()
                        let chip = c.attachmentChips.first { $0.attachmentID == id }!
                        c.attachmentContent.scrollToVisible(chip.frame)
                        let exposed = proxies(c.accessibilityChildren() ?? [])
                        check(exposed.contains { $0.source === chip } && exposed.contains { $0.source === chip.removeButton }, label + ".canonical-ax.\(id)")
                        chip.removeButton.performClick(nil)
                        check(!c.attachments.contains { $0.id == id }, label + ".remove.\(id)")
                    }
                }
            }
        }
        let movingWidths: [(CGFloat, CGFloat)] = [(219, 221), (220, 219)]
        for (semantic, presented) in movingWidths {
            let c = NativeComposer(); c.targetWidth = semantic
            c.frame = CGRect(x: 0, y: 0, width: presented, height: 48); c.attachments = [existing]
            c.needsLayout = true; c.layoutSubtreeIfNeeded()
            check(c.attachmentChips[0].iconOnly == (semantic < 220), "chip.semantic-width-\(Int(semantic))-during-\(Int(presented))-frame")
        }
        let normie = NativeComposer(); normie.layoutMode = .growing
        var chooseCompletion: (@MainActor ([Attachment]) -> Void)?
        normie.onChooseAttachments = { chooseCompletion = $0 }; normie.chooseAttachments(); chooseCompletion?([existing])
        normie.prepareNormieLayout(width: 768, detailHeight: 760)
        check(normie.attachments == [existing] && !normie.attachmentScrollView.isHidden && normie.canSend, "normie.existing-picker-and-attachment-only-send")
        check(normie.attachmentScrollView.frame.minX == 14 && normie.attachmentScrollView.frame.minY == 42 && !normie.attachmentChips[0].iconOnly, "normie.existing-growing-chip-position")
        check(normie.removeAttachment(id: existing.id) && normie.attachments.isEmpty, "normie.existing-remove")

        let pasteboard = NSPasteboard(name: .init("attachment.fixture." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/fixture/a.png"), URL(fileURLWithPath: "/fixture/b.txt")]
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { url in let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item })
        let changeCount = pasteboard.changeCount
        let decodedFiles = DragAttachmentPayload.decode(pasteboard)!
        check(decodedFiles.attachments.map(\.url) == urls, "decode.multiple-files")
        check(decodedFiles.attachments.map(\.symbol) == ["photo", "doc"] && decodedFiles.attachments.first?.mimeType == "image/png", "decode.files-match-picker")
        check(pasteboard.changeCount == changeCount && DragAttachmentPayload.decode(pasteboard) == decodedFiles, "decode.pure-and-stable-keys")
        pasteboard.clearContents(); pasteboard.setString(original, forType: .string)
        check(DragAttachmentPayload.writeQuotes([quote], to: pasteboard), "decode.encode-quote")
        check(DragAttachmentPayload.decode(pasteboard)?.values == [.quote(quote)], "decode.quote-exact-text-source-item-range")
        if let value = DragAttachmentPayload.decode(pasteboard)?.values.first, case .quote(let reference) = value {
            check(exact(reference.exactText, quote.exactText), "decode.quote-exact-text")
            check(reference.conversationID == quote.conversationID, "decode.quote-conversation-id")
            check(reference.itemID == quote.itemID, "decode.quote-item-id")
            check(reference.range == quote.range, "decode.quote-utf16-range")
        } else { check(false, "decode.quote-fields-present") }
        check(pasteboard.string(forType: .string) == original, "decode.plain-text-preserved")
        pasteboard.clearContents(); pasteboard.setString("external plain text", forType: .string)
        check(DragAttachmentPayload.decode(pasteboard) == nil, "decode.neither-file-nor-quote")
        pasteboard.addTypes([DragAttachmentPayload.quoteType], owner: nil); pasteboard.setData(Data("invalid".utf8), forType: DragAttachmentPayload.quoteType)
        check(DragAttachmentPayload.decode(pasteboard) == nil, "decode.malformed-quote")
        let markdown = NativeTranscriptRow()
        let source = TranscriptItem(id: "markdown", turnID: "turn", kind: .assistant, text: "A **bold** \u{4E2D}\u{6587} \u{1F319} statement")
        markdown.configure(source, sourceItem: source, index: 0, items: [source], width: 640, expanded: false)
        let renderedWord = (markdown.body.string as NSString).range(of: "bold")
        markdown.body.setSelectedRange(renderedWord)
        let mapped = markdown.attachmentQuotes(conversationID: "markdown-source").first
        check(mapped?.range == (source.text as NSString).range(of: "bold") && mapped?.exactText == "bold", "selection.markdown-uses-source-offsets")
        try transcriptSelection(output: output, pasteboard: pasteboard, check: check)
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "attachment.no-visible-window")
    }

    private static func transcriptSelection(output: URL, pasteboard: NSPasteboard, check: (Bool, String) -> Void) throws {
        let conversation = Conversation(id: "selection", title: "Synthetic transcript")
        let text = "alpha \u{4E2D}\u{6587} \u{1F319}\nsecond \u{1F469}\u{200D}\u{1F4BB} line"
        conversation.items = [.init(id: "one", turnID: "turn", kind: .assistant, text: text),
                              .init(id: "two", turnID: "turn", kind: .assistant, text: "other item")]
        let transcript = NativeTranscript(conversation: conversation)
        transcript.frame = CGRect(x: 0, y: 0, width: 640, height: 500)
        transcript.refresh(); transcript.layoutSubtreeIfNeeded()
        func rows(_ view: NSView) -> [NativeTranscriptRow] { view.subviews.flatMap { ($0 as? NativeTranscriptRow).map { [$0] } ?? rows($0) } }
        let mounted = rows(transcript), first = mounted.first { $0.item.id == "one" }!, second = mounted.first { $0.item.id == "two" }!
        for (name, range) in [("single-line", NSRange(location: 0, length: 5)), ("cross-line", NSRange(location: 6, length: text.utf16.count - 6)), ("cjk-emoji", (text as NSString).range(of: "\u{4E2D}\u{6587} \u{1F319}"))] {
            first.body.setSelectedRange(range)
            let quote = first.attachmentQuotes(conversationID: conversation.id).first
            check(quote?.range == range && quote?.exactText == (text as NSString).substring(with: range), "selection.\(name).range-and-exact-text")
            check(quote?.conversationID == conversation.id && quote?.itemID == "one", "selection.\(name).source")
        }
        first.body.setSelectedRange(NSRange(location: 0, length: 5)); second.body.setSelectedRange(NSRange(location: 0, length: 5))
        let quotes = first.dragAttachmentQuotes()
        check(quotes.map(\.itemID) == ["one", "two"] && quotes.map(\.exactText) == ["alpha", "other"] && quotes.map(\.range) == [NSRange(location: 0, length: 5), NSRange(location: 0, length: 5)], "selection.cross-item.separate-ranges-in-source-order")
        pasteboard.clearContents()
        let nativeTypes = first.body.writablePasteboardTypes
        let plainTypes = nativeTypes.filter { $0.rawValue.lowercased().contains("plain") || $0.rawValue.lowercased().contains("string") }
        print("NATIVE_SELECTION_TYPES: " + nativeTypes.map(\.rawValue).joined(separator: ","))
        check(!plainTypes.isEmpty && nativeTypes.contains(DragAttachmentPayload.quoteType), "selection.native-types-plus-private-type")
        check(first.body.writeSelection(to: pasteboard, types: nativeTypes), "selection.native-writer")
        let plainPreserved = plainTypes.contains { type in
            if pasteboard.string(forType: type) == "alpha" { return true }
            guard let data = pasteboard.data(forType: type) else { return false }
            return String(data: data, encoding: .utf8) == "alpha" || String(data: data, encoding: .utf16) == "alpha"
        }
        check(plainPreserved, "selection.original-plain-text-still-present")
        check(DragAttachmentPayload.decode(pasteboard)?.values == quotes.map(DragAttachmentPayload.Value.quote), "selection.native-writer-quote-roundtrip")
    }
}
#endif
