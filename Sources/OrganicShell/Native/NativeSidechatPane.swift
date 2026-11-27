import AppKit
import QuartzCore

/// The window owns the view. The private runtime owns conversation state.
@MainActor final class NativeSidechatPane: NativeFlippedView, NSTextViewDelegate {
    struct Content {
        var items: [TranscriptItem] = []
        var question: UserInputRequest?
        var draft = ""
        var running = false
        var finalAnswerID: String?
        var activeTurnID: String?
        var stopped = false
    }

    private let model = Conversation(id: SidechatRuntime.presentationPrefix + UUID().uuidString, title: "Sidechat")
    private let card = SheetCard(frame: .zero)
    private let contentMask = CAShapeLayer()
    private let island = SheetCard(frame: .zero)
    private let bubble = SheetCard(frame: .zero)
    private let heading = SheetStyle.label("New sidechat", size: 12, weight: .medium)
    private let origin = SheetStyle.label("", size: 11, secondary: true)
    private let dot = SheetStyle.label("●", size: 9)
    private let status = SheetStyle.label("", size: 11, secondary: true)
    private let inputScroll = SheetScrollView(frame: .zero)
    private let closeButton = SheetButton(frame: .zero)
    private let sendButton = SheetButton(frame: .zero)
    private let returnButton = SheetButton(frame: .zero)
    private let sentBadge = SheetStyle.label("Sent", size: 11, secondary: true)
    private var syncingDraft = false
    private(set) var content = Content()
    var moonColor = NSColor.systemTeal
    let editor = NativeComposerTextView()
    private(set) lazy var transcript = NativeTranscript(conversation: model)

    var onDraft: ((String) -> Void)?
    var onContentChanged: (() -> Void)?
    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    var onFold: (() -> Void)?
    var onClose: (() -> Void)?
    var onSendToMain: (() -> Void)?
    var onAnswer: ((UserInputRequest, [String: [String]]) -> Void)?
    private var pendingAnswerID: String?
    private var sentAnswerID: String?
    var canSendToMain: Bool {
        !content.running && content.finalAnswerID != nil &&
            content.finalAnswerID != sentAnswerID && pendingAnswerID == nil
    }
    var needsCloseConfirmation: Bool {
        content.running || !content.items.isEmpty ||
            !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.radius = 24
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addSubview(card)
        for view in [island as NSView, origin, transcript, bubble, returnButton, sentBadge] {
            card.content.addSubview(view)
        }
        for view in [dot as NSView, heading, status, closeButton] { island.content.addSubview(view) }
        bubble.content.addSubview(inputScroll)
        bubble.content.addSubview(sendButton)
        origin.alignment = .center
        configure(closeButton, title: "Close sidechat") { [weak self] in self?.onClose?() }
        configure(sendButton, title: "Send") { [weak self] in self?.submitDraft() }
        configure(returnButton, title: "Send to main") { [weak self] in self?.sendToMain() }
        closeButton.drawsPlate = false
        closeButton.drawContent = { Self.drawIcon("×", in: $0, color: .secondaryLabelColor) }
        sendButton.drawsPlate = false
        sendButton.drawContent = { [weak self] rect in
            guard let self else { return }
            moonColor.withAlphaComponent(sendButton.isEnabled ? 0.85 : 0.25).setFill()
            NSBezierPath(ovalIn: rect).fill()
            Self.drawIcon(content.running ? "▪" : "↑", in: rect, color: .white)
        }
        returnButton.accent = true
        editor.placeholder = "Ask this sidechat…"
        editor.setAccessibilityLabel("Sidechat message")
        editor.unregisterDraggedTypes()
        editor.delegate = self
        editor.onSubmit = { [weak self] in self?.submitDraft() }
        editor.onCancel = { [weak self] in self?.onFold?() }
        editor.onStop = { [weak self] in self?.onStop?() }
        editor.onCompositionChange = { [weak self] in self?.draftChanged() }
        inputScroll.drawsBackground = false
        inputScroll.documentView = editor
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        editor.nextKeyView = sendButton
        sendButton.nextKeyView = returnButton
        returnButton.nextKeyView = closeButton
        closeButton.nextKeyView = editor
        model.isLiveConversation = true
        transcript.onAnswer = { [weak self] request, answers in self?.onAnswer?(request, answers) }
        updateActions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func drawIcon(_ glyph: String, in rect: CGRect, color: NSColor) {
        let line = CGRect(x: rect.minX, y: rect.midY - 10, width: rect.width, height: 20)
        SheetStyle.text(glyph, in: line, size: 16, color: color, weight: .semibold, align: .center)
    }

    private func configure(_ button: SheetButton, title: String, invoke: @escaping () -> Void) {
        button.title = title
        button.setAccessibilityLabel(title)
        button.invoke = invoke
    }

    func apply(_ value: Content, parentTitle: String) {
        content = value
        origin.stringValue = parentTitle.isEmpty ? "Sidechat" : "Sidechat of " + parentTitle
        setAccessibilityLabel(origin.stringValue)
        let question = value.items.first { $0.rowKind == .user }?.text ?? "New sidechat"
        heading.stringValue = question.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        editor.insertionPointColor = moonColor
        editor.placeholder = value.items.isEmpty ? "Ask this sidechat…" : "Ask a follow-up…"
        model.items = value.items
        model.userInput = value.question
        model.running = value.running
        model.revision += 1
        if !editor.hasMarkedText(), !editor.isHandlingCompositionEvent, editor.string != value.draft {
            syncingDraft = true
            editor.string = value.draft
            editor.undoManager?.removeAllActions()
            syncingDraft = false
        }
        transcript.refresh(allowHidden: true)
        updateActions()
        onContentChanged?()
    }

    func apply(_ chat: SidechatRuntime.Chat, parentTitle: String) {
        apply(.init(items: chat.items, question: chat.userInput, draft: chat.draft, running: chat.running,
                    finalAnswerID: chat.lastAnswer, activeTurnID: chat.activeTurnID, stopped: chat.stopped),
              parentTitle: parentTitle)
    }

    func textDidChange(_ notification: Notification) { draftChanged() }

    private func draftChanged() {
        guard !syncingDraft, !editor.hasMarkedText(), !editor.isHandlingCompositionEvent else { return }
        if editor.string != content.draft {
            content.draft = editor.string
            onDraft?(editor.string)
        }
        updateActions()
    }

    private func updateActions() {
        let streaming = content.items.contains { $0.turnID == content.activeTurnID && $0.rowKind == .assistant &&
            !$0.text.isEmpty
        }
        let idleStatus = content.stopped ? "Stopped" : content.items.isEmpty ? "" : "Done"
        status.stringValue = content.running ? (streaming ? "Running" : "Thinking") : idleStatus
        dot.textColor = moonColor.withAlphaComponent(content.running ? 1 : 0.45)
        sendButton.title = content.running ? "Stop" : "Send"
        sendButton.setAccessibilityLabel(sendButton.title)
        sendButton.isEnabled = content.running || !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        returnButton.isEnabled = canSendToMain
        let sent = content.finalAnswerID != nil && sentAnswerID == content.finalAnswerID
        returnButton.isHidden = !canSendToMain
        sentBadge.isHidden = !sent
    }

    func submitDraft() {
        guard !editor.hasMarkedText(), !editor.isHandlingCompositionEvent else { return }
        if content.running {
            onStop?()
        } else if sendButton.isEnabled {
            draftChanged()
            onSend?()
        }
    }

    func sendToMain() {
        guard canSendToMain, let answer = content.finalAnswerID, let onSendToMain else { return }
        pendingAnswerID = answer
        updateActions()
        onSendToMain()
    }

    func markSent() -> Bool {
        guard let pendingAnswerID else { return false }
        sentAnswerID = pendingAnswerID
        rejectSendToMain()
        return true
    }

    func rejectSendToMain() {
        pendingAnswerID = nil
        updateActions()
    }

    func reveal(_ fraction: CGFloat, fromLeft: Bool, opaqueBacking: Bool) {
        let width = bounds.width * fraction
        let x = fromLeft ? 0 : bounds.width - width
        let aperture = CGRect(x: x, y: 0, width: width, height: bounds.height)
        card.usesOpaqueBacking = opaqueBacking
        card.placeMotionGlass(aperture)
        card.needsDisplay = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fraction > 0, fraction < 1 {
            let radius = min(card.radius, width / 2, bounds.height / 2)
            contentMask.frame = bounds
            contentMask.path = CGPath(roundedRect: aperture, cornerWidth: radius, cornerHeight: radius, transform: nil)
            card.content.layer?.mask = contentMask
        } else {
            card.content.layer?.mask = nil
        }
        card.content.alphaValue = max(0, (fraction - 0.45) / 0.55)
        CATransaction.commit()
    }

    func clear() {
        syncingDraft = true
        editor.unmarkText()
        _ = window?.makeFirstResponder(nil)
        syncingDraft = false
        sentAnswerID = nil
        pendingAnswerID = nil
        apply(.init(), parentTitle: "")
        editor.undoManager?.removeAllActions()
    }

    func dispose() {
        clear()
        editor.delegate = nil
        transcript.dispose()
        removeFromSuperview()
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let width = bounds.width
        let height = bounds.height
        let inner = max(1, width - 32)
        island.frame = CGRect(x: 16, y: 31, width: inner, height: 27)
        dot.frame = CGRect(x: 10, y: 7, width: 10, height: 14)
        heading.frame = CGRect(x: 23, y: 5, width: max(1, inner - 116), height: 18)
        status.frame = CGRect(x: max(0, inner - 87), y: 6, width: 57, height: 16)
        closeButton.frame = CGRect(x: max(0, inner - 27), y: 3, width: 22, height: 22)
        origin.frame = CGRect(x: 16, y: 68, width: inner, height: 16)
        transcript.frame = CGRect(x: 3, y: 84, width: max(1, width - 6), height: max(1, height - 174))
        bubble.frame = CGRect(x: 16, y: max(84, height - 49), width: inner, height: 38)
        inputScroll.frame = CGRect(x: 12, y: 3, width: max(1, inner - 52), height: 32)
        let inputSize = inputScroll.contentSize
        editor.minSize = inputSize
        editor.setFrameSize(CGSize(width: inputSize.width, height: max(editor.frame.height, inputSize.height)))
        sendButton.frame = CGRect(x: max(0, inner - 32), y: 6, width: 26, height: 26)
        returnButton.frame = CGRect(x: 16, y: max(84, height - 80), width: 116, height: 22)
        sentBadge.frame = CGRect(x: 20, y: returnButton.frame.midY - 7, width: 48, height: 14)
    }
}
