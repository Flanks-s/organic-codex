import AppKit

/// Normie ApprovalCard's source is inside its glass, between the title and command.
struct NativeApprovalSource: Equatable {
    var project: String
    var conversation: String
    var isOtherConversation: Bool
    var canShowConversation = true
}

/// The inner command viewport follows the same backing-pixel scroll rule as the transcript.
@MainActor final class NativeCardClipView:NSClipView {
    override func constrainBoundsRect(_ proposedBounds:NSRect)->NSRect{var rect=super.constrainBoundsRect(proposedBounds);let scale=max(1,window?.backingScaleFactor ?? 1);rect.origin.x=(rect.origin.x*scale).rounded(.down)/scale;rect.origin.y=(rect.origin.y*scale).rounded(.down)/scale;return rect}
    override func scroll(to newOrigin:NSPoint){super.scroll(to:constrainBoundsRect(CGRect(origin:newOrigin,size:bounds.size)).origin)}
}

/// Borderless controls on plates drawn by the card. Radios use a drawn mark rather than a system bezel.
@MainActor private final class NativeCardButton: NativeButton {
    var invoke: (() -> Void)?
    var drawsRailTitle = false
    static func railSecondary(in window: NSWindow?) -> NSColor {
        if let foreground = NativeAppearance.current.foreground { return foreground.withAlphaComponent(0.58) }
        // The product's inactive glass resolves secondary content to 96/255 coverage.
        // Plain AppKit secondaryLabelColor stays at 55%, and was visibly too bright.
        return window?.isKeyWindow == true ? .secondaryLabelColor : .white.withAlphaComponent(0.375)
    }
    /// ApprovalCard's accept button (.borderedProminent, tinted with the accent): the accent plate while the window is
    /// key, the same grey plate as the others when it isn't (as SwiftUI draws it).
    var prominent = false { didSet { needsDisplay = true } }
    private var keyObservers: [NSObjectProtocol] = []
    isolated deinit { keyObservers.forEach(NotificationCenter.default.removeObserver) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver); keyObservers = []
        guard let window, prominent || drawsRailTitle else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            })
        }
    }
    private(set) var radio = false
    private(set) var isTrackingPress = false
    override func mouseDown(with event: NSEvent) {
        isTrackingPress = true; defer { isTrackingPress = false }; super.mouseDown(with: event)
    }
    init(_ title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; invoke = action; target = self; self.action = #selector(pressed)
        font = .systemFont(ofSize: 12)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setButtonType(_ type: NSButton.ButtonType) {
        // Keep the native button's action and radio state, with no AppKit radio bezel in a capture.
        radio = type == .radio
        super.setButtonType(radio ? .pushOnPushOff : type)
    }
    override func draw(_ dirtyRect: NSRect) {
        if drawsRailTitle {
            let font=font ?? .systemFont(ofSize:13,weight:.medium)
            let source=identifier?.rawValue == "approval.showConversation"
            if !source {
                // .bordered at the regular size: a 24 pt plate, 7 pt corners, white at 27% over the card (measured on
                // the product's 2× capture); .borderedProminent takes the accent while the window is key.
                let plate=bounds.insetBy(dx:0,dy:max(0,(bounds.height-24)/2))
                let fill=prominent && window?.isKeyWindow == true ? NativeAppearance.current.accentColor:NSColor.white.withAlphaComponent(0.27)
                fill.withAlphaComponent(fill.alphaComponent*(isEnabled ? 1:0.45)).setFill()
                NSBezierPath(roundedRect:plate,xRadius:7,yRadius:7).fill()
            }
            let color=source ? Self.railSecondary(in: window):(NativeAppearance.current.foreground ?? .textColor)
            let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:color.withAlphaComponent(color.alphaComponent*(isEnabled ? 1:0.45))]
            let size=(title as NSString).size(withAttributes:attributes)
            // A link has its intrinsic Text bounds, with no bordered-button centering inset.
            // Centering the rounded-up field shifted its 2× glyphs by half a pixel.
            let origin = CGPoint(x:(bounds.width-size.width)/2, y:source ? 0:(bounds.height-size.height)/2)
            (title as NSString).draw(in:CGRect(origin:origin,size:size),withAttributes:attributes)
            return
        }
        guard radio else { super.draw(dirtyRect); return }
        let circle = CGRect(x: 1, y: bounds.midY - 5, width: 10, height: 10)
        NativePalette.secondaryLabel.withAlphaComponent(isEnabled ? 1 : 0.4).setStroke()
        let path = NSBezierPath(ovalIn: circle); path.lineWidth = 1; path.stroke()
        if state == .on { NativePalette.label.setFill(); NSBezierPath(ovalIn: circle.insetBy(dx: 2.5, dy: 2.5)).fill() }
        (title as NSString).draw(in: CGRect(x: 18, y: bounds.midY - 8, width: max(1, bounds.width - 18), height: 18),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NativePalette.label.withAlphaComponent(isEnabled ? 1 : 0.4)])
    }
    override func sizeToFit() { super.sizeToFit(); frame.size.width += 16 }
    @objc private func pressed() { if isEnabled && superview != nil && !isHiddenOrHasHiddenAncestor { invoke?() } }
}

/// Live AppKit controls own edits, selection and actions. The same subtree supplies the flight viewport.
@MainActor final class NativeTranscriptCard: NativeFlippedView, NSTextFieldDelegate {
    var onHeightChange:(()->Void)?
    /// Local edits/options affect captures even when the model revision and card height stay unchanged.
    var onVisualChange: (() -> Void)?
    private var lastWindowGrid:CGFloat?
    private(set) var approvalConfigurationCount=0
    /// A detached handoff keeps the destination grid; falling back to 1 rebuilt every rail once before its 2x mount.
    func prepareForPresentation(scale:CGFloat?) {if let scale {lastWindowGrid=max(1,scale)}}
    private var commandScrollObservation: NSObjectProtocol?
    private var keyObservations: [NSObjectProtocol] = []
    /// Explicit grid for a windowless fixture; live cards use their window backing scale.
    var verificationScale: CGFloat? { didSet { synchronizeApprovalGrid() } }
    isolated deinit { if let commandScrollObservation { NotificationCenter.default.removeObserver(commandScrollObservation) }; keyObservations.forEach(NotificationCenter.default.removeObserver) }
    private(set) var approvalSource: NativeApprovalSource?
    private var sourceAction: (() -> Void)?
    private var configuredSource: NativeApprovalSource?
    private let approvalGlass = NSGlassEffectView()
    var modePhotoMaterial:NSGlassEffectView? {approvalSource == nil ? nil:approvalGlass}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {lastWindowGrid=window.backingScaleFactor}
        approvalGlass.isHidden = window == nil
        keyObservations.forEach(NotificationCenter.default.removeObserver); keyObservations = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateRailSecondary() }
                })
            }
        }
        if window != nil { synchronizeApprovalGrid() }
        updateRailSecondary()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {lastWindowGrid=window.backingScaleFactor}
        if window != nil { synchronizeApprovalGrid() }
    }
    /// External cards are configured before Normie mounts them. Adopt the real backing grid
    /// on that first mount, so a 2× window does not keep the detached card's 1× widths.
    private func synchronizeApprovalGrid() {
        guard approvalSource != nil, approvalGrid != grid, let approval, let approvalAction else { return }
        let oldHeight = frame.height
        let command = subviews.compactMap { $0 as? NSScrollView }.first
        let selection = (command?.documentView as? NSTextView)?.selectedRange()
        let offset = command?.contentView.bounds.origin
        configureApproval(approval, width: approvalWidth, enabled: approvalEnabled, respondValue: approvalValue, action: approvalAction)
        if let command = subviews.compactMap({ $0 as? NSScrollView }).first {
            if let selection, let text = command.documentView as? NSTextView, NSMaxRange(selection)<=text.string.utf16.count { text.setSelectedRange(selection) }
            if let offset { command.contentView.scroll(to: offset); command.reflectScrolledClipView(command.contentView) }
        }
        if frame.height != oldHeight { onHeightChange?() }
        onVisualChange?()
    }
    override func nativeAppearanceDidChange() { super.nativeAppearanceDidChange(); updateRailSecondary() }
    private func updateRailSecondary() {
        let color = NativeCardButton.railSecondary(in: window)
        for child in subviews {
            if child.identifier?.rawValue == "approval.source", let label = child as? NSTextField { label.textColor = color }
            if child.identifier?.rawValue == "approval.note", let text = child as? NSTextView, let storage = text.textStorage {
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
            }
            child.needsDisplay = true
        }
        onVisualChange?()
    }
    var isApprovalCard: Bool { approval != nil }
    var approvalPlateRect: CGRect { paintRect }
    func setApprovalSource(_ source: NativeApprovalSource?, showConversation: (() -> Void)? = nil, reconfigure:Bool=true) {
        sourceAction = showConversation
        guard approvalSource != source else { return }
        approvalSource = source
        if reconfigure, let approval, let approvalAction {
            configureApproval(approval, width: approvalWidth, enabled: approvalEnabled, respondValue: approvalValue, action: approvalAction)
        }
    }
    private var awaitingDecisionReview = false
    var preventsRecycling: Bool {
        if awaitingDecisionReview { return true }
        if fields.values.contains(where: { !$0.stringValue.isEmpty }) || jsonField.map({ $0.stringValue != "{}" }) == true ||
            optionButtons.values.joined().contains(where: { $0.state == .on }) { return true }
        if let first = window?.firstResponder as? NSView, first.isDescendant(of: self) { return true }
        if fields.values.contains(where: { $0.currentEditor() != nil }) || jsonField?.currentEditor() != nil { return true }
        func active(_ view: NSView) -> Bool {
            if let button = view as? NativeCardButton, button.isTrackingPress { return true }
            if let text = view as? NSTextView, text.selectedRange().length > 0 { return true }
            if let text = view as? NativeTranscriptTextView, text.isTrackingSelection { return true }
            return view.subviews.contains(where: active)
        }
        return active(self)
    }
    var blocksHandoff: Bool {
        if awaitingDecisionReview { return true }
        if fields.values.contains(where: { ($0.currentEditor() as? NSTextView)?.hasMarkedText() == true }) ||
            (jsonField?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return true }
        func tracking(_ view: NSView) -> Bool {
            if let button = view as? NativeCardButton, button.isTrackingPress { return true }
            if let text = view as? NativeTranscriptTextView, text.isTrackingSelection || text.hasMarkedText() { return true }
            return view.subviews.contains(where: tracking)
        }
        return tracking(self)
    }
    weak var semanticParent:NativeTranscriptAXRow?
    override func accessibilityParent()->Any?{if let semanticParent,superview === semanticParent.table{return semanticParent};return super.accessibilityParent()}
    var chatApprovalAvailable=false
    var reviewUnknownDecision:((JSONValue,@escaping(Bool)->Void)->Void)?
    private var configuredChatApproval=false
    private var displayRevision = -1
    private var appearanceRevision = -1
    private var paintRect = CGRect.zero
    private var fields: [String: NSTextField] = [:]
    private var optionButtons: [String: [NativeCardButton]] = [:]
    private var submitButton: NativeCardButton?
    private var answer: (([String: [String]]) -> Void)?
    private var request: UserInputRequest?
    private var questionWidth: CGFloat = -1
    private var questionEnabled = true
    private var questionGrid: CGFloat = -1
    private var approval: Approval?
    private var approvalWidth: CGFloat = -1
    private var approvalEnabled = true
    private var approvalGrid: CGFloat = -1
    private var approvalAction: ((ApprovalAction) -> Void)?
    private var approvalValue: ((JSONValue) -> Void)?
    private var jsonField: NSTextField?
    private var validationLabel: NativeLabel?
    private var approvalAccept: NativeCardButton?
    private var grid: CGFloat { max(1, verificationScale ?? window?.backingScaleFactor ?? lastWindowGrid ?? 1) }

    func configureApproval(_ value: Approval, width: CGFloat, enabled: Bool = true, action: @escaping (ApprovalAction) -> Void) {
        configureApproval(value, width: width, enabled: enabled, respondValue: nil, action: action)
    }
    func configureApproval(_ value: Approval, width: CGFloat, enabled: Bool = true,
                           respondValue: ((JSONValue) -> Void)?, action: @escaping (ApprovalAction) -> Void) {
        let valueCallbackChanged = (approvalValue == nil) != (respondValue == nil)
        approvalAction = action; approvalValue = respondValue
        if approval == value && approvalWidth == width && approvalEnabled == enabled && approvalGrid == grid && configuredChatApproval == chatApprovalAvailable && configuredSource == approvalSource && displayRevision == NativeDisplayOptions.shared.revision && appearanceRevision == NativeAppearance.revision {
            if valueCallbackChanged { validateApproval() }
            return
        }
        approvalConfigurationCount+=1
        let same = approval?.id == value.id && approval?.request == value.request && approval?.method == value.method
        let retained = same ? jsonField : nil
        approval = value; approvalWidth = width; approvalEnabled = enabled; approvalGrid = grid;configuredChatApproval=chatApprovalAvailable;configuredSource=approvalSource;displayRevision=NativeDisplayOptions.shared.revision;appearanceRevision=NativeAppearance.revision
        clear(keeping: retained.map { [ObjectIdentifier($0)] } ?? [])
        jsonField = nil; validationLabel = nil; approvalAccept = nil
        let x = columnX(width), w = columnWidth(width)
        let rail = approvalSource != nil, inset: CGFloat = rail ? 14:12
        var y: CGFloat = inset
        if let source = approvalSource {
            let hand = NSImageView(frame: snapped(CGRect(x:x+14,y:y,width:16,height:16)))
            hand.image = NSImage(systemSymbolName:"hand.raised.fill",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:14,weight:.regular))
            hand.contentTintColor = .systemOrange; hand.setAccessibilityElement(false); addSubview(hand)
            y = addText(value.title,x:x+36,y:y,width:w-50,weight:.semibold)
            let label = NativeLabel(labelWithString:source.project+" · "+source.conversation)
            label.identifier = NSUserInterfaceItemIdentifier("approval.source")
            label.font = .systemFont(ofSize:10); label.textColor=NativeCardButton.railSecondary(in: window); label.lineBreakMode = .byTruncatingTail
            let sourceY=y+8, available=max(1,w-28)
            let natural=ceil((label.stringValue as NSString).size(withAttributes:[.font:label.font!]).width*grid)/grid+4
            let link = NativeCardButton("Show Conversation") { [weak self] in self?.sourceAction?() }
            link.font = .systemFont(ofSize:10); link.drawsRailTitle=true; link.contentTintColor=NativePalette.secondaryLabel; link.isEnabled=source.canShowConversation
            link.identifier=NSUserInterfaceItemIdentifier("approval.showConversation")
            let linkWidth=source.isOtherConversation ? ceil((link.title as NSString).size(withAttributes:[.font:link.font!]).width*grid)/grid:0
            let labelWidth=min(natural,max(1,available-(linkWidth == 0 ? 0:linkWidth+8)))
            label.frame=snapped(CGRect(x:x+12,y:sourceY,width:labelWidth,height:12)); addSubview(label)
            if source.isOtherConversation { link.frame=snapped(CGRect(x:label.frame.maxX+6,y:sourceY,width:linkWidth,height:12));addSubview(link) }
            y=sourceY+12
        } else { y = addText(value.title,x:x+inset,y:y,width:w-2*inset,weight:.semibold) }
        y = addCommand(value.command, x:x+inset,y:y+8,width:w-2*inset)
        if !value.note.isEmpty { y = addText(value.note,x:x+inset,y:y+8,width:w-2*inset,quiet:true,size:rail ? 10:nil) }
        if value.method == "elicitation/create" {
            let schema = value.request["params"]?["requestedSchema"] ?? .object([:])
            do {
                y = addText("Requested information (JSON)", x: x + 12, y: y + 8, width: w - 24, weight: .semibold)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let schemaText = (try? encoder.encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                y = addText(schemaText, x: x + 12, y: y + 6, width: w - 24, quiet: true, size: 10) + 8
                let field = retained ?? NativeLabel()
                if retained == nil { field.stringValue = "{}" }
                prepareField(field, label: "Requested information JSON", enabled: enabled && !value.submitting)
                field.font = NativeAppearance.current.code.font(11)
                field.usesSingleLineMode = false; field.cell?.wraps = true
                field.frame = snapped(CGRect(x: x + 12, y: y, width: max(1, w - 24), height: 72).insetBy(dx: 8, dy: 5))
                jsonField = field; if field.superview == nil { addSubview(field) }; y += 80
            }
            let label = NativeLabel(labelWithString: "")
            label.font = .systemFont(ofSize: 11); label.textColor = .systemRed
            label.frame = snapped(CGRect(x: x + 12, y: y, width: max(1, w - 24), height: 28))
            label.maximumNumberOfLines = 2; label.cell?.wraps = true
            validationLabel = label; addSubview(label); y += 30
        }
        let decisions=value.request["params"]?["availableDecisions"]?.arrayValue
        for decision in decisions ?? []{if let scope=NativeApprovalDecisions.scope(decision){y=addText(scope,x:x+12,y:y+6,width:w-24,quiet:true,size:10)}}
        if let app=value.cuaApplicationForChatApproval,chatApprovalAvailable{y=addText("Allow for this chat lets Computer Use access "+app+" across tools in this conversation, including after reopening it. Revoke access in Settings → Computer use.",x:x+12,y:y+6,width:w-24,quiet:true,size:10)}
        y += rail ? 8:12
        let buttonStart = subviews.count
        var bx=x+inset
        func button(_ label:String,enabled available:Bool=true,_ run:@escaping()->Void)->NativeCardButton {
            let button=NativeCardButton(label,action:run);button.isEnabled=enabled && !value.submitting && available
            if rail { button.font = .systemFont(ofSize:13); button.drawsRailTitle=true }
            button.sizeToFit()
            let natural = rail ? ceil((label as NSString).size(withAttributes:[.font:button.font!]).width*grid)/grid+24:button.frame.width
            let width=min(max(rail ? 40:64,natural),max(1,w-2*inset))
            if bx+width>x+w-inset,bx>x+inset{y+=32;bx=x+inset}
            button.frame=snapped(CGRect(x:bx,y:y,width:width,height:rail ? 26:28));bx=button.frame.maxX+8;addSubview(button);return button
        }
        if let decisions,respondValue != nil {
            for decision in decisions{let b=button(NativeApprovalDecisions.title(decision)){[weak self] in _ = self?.chooseDecision(decision)};b.toolTip=NativeApprovalDecisions.scope(decision) ?? NativeApprovalDecisions.exact(decision)}
        }else if value.cuaChatApprovalResponse != nil,chatApprovalAvailable,respondValue != nil {
            _ = button("Cancel"){[weak self] in self?.decide(.cancel)};_ = button("Decline"){[weak self] in self?.decide(.decline)}
            _ = button("Allow once"){[weak self] in self?.emitApprovalValue(["action":"accept","content":[:]],expected:value)}
            _ = button("Allow for this chat"){[weak self] in guard let response=value.cuaChatApprovalResponse else{return};self?.emitApprovalValue(response,expected:value)}
        }else{
            for (label,decision) in [("Cancel",ApprovalAction.cancel),("Decline",.decline),(value.acceptLabel,.accept)]{
                let b=button(label){[weak self] in self?.decide(decision)};if decision == .accept{approvalAccept=b;b.prominent=true}
            }
        }
        if rail {
            // Right-align each wrapped row without changing order or the native actions.
            let buttons=subviews.dropFirst(buttonStart).compactMap { $0 as? NativeCardButton }
            for rowY in Set(buttons.map { $0.frame.minY }) {
                let row=buttons.filter { $0.frame.minY == rowY }
                let delta=x+w-inset-(row.last?.frame.maxX ?? x+w-inset)
                for button in row { button.frame.origin.x += delta }
            }
        }
        finish(width:width,y:y+(rail ? 39:40))
        setAccessibilityLabel("Approval: " + value.title)
        validateApproval()
    }

    private func emitApprovalValue(_ response:JSONValue,expected:Approval){guard let approval,approval.id == expected.id,approval.request == expected.request,approval.method == expected.method,approvalEnabled,!approval.submitting,!isHiddenOrHasHiddenAncestor,CoreResponseValidation.approval(response,request:approval) == nil else{return};approvalValue?(response)}
    @discardableResult func chooseDecision(_ decision:JSONValue)->Bool {
        guard let approval,approvalEnabled,!approval.submitting,!isHiddenOrHasHiddenAncestor,approvalValue != nil,(approval.request["params"]?["availableDecisions"]?.arrayValue ?? []).contains(decision)else{return false}
        let response:JSONValue=["decision":decision]
        guard CoreResponseValidation.approval(response,request:approval) == nil else{return false}
        if NativeApprovalDecisions.known(decision){emitApprovalValue(response,expected:approval);return true}
        let mount=superview
        var ancestor=superview,root:NativeInteractionSurface?
        while let view=ancestor{if let surface=view as? NativeInteractionSurface{root=surface;break};ancestor=view.superview}
        let epoch=root?.presentationEpoch
        var resolved=false
        awaitingDecisionReview = true
        let confirm:(Bool)->Void={[weak self,weak mount,weak root] allowed in
            guard !resolved else{return};resolved=true
            self?.awaitingDecisionReview = false
            guard allowed,let self,self.superview === mount,root?.presentationEpoch == epoch else{return}
            self.emitApprovalValue(response,expected:approval)
        }
        if let reviewUnknownDecision{reviewUnknownDecision(decision,confirm);return true}
        guard let window else{awaitingDecisionReview = false;return false}
        let alert=NSAlert();alert.messageText="Use this response?";alert.informativeText="Core offered an additional response. Review its exact value before sending:\n\n"+NativeApprovalDecisions.exact(decision);alert.addButton(withTitle:"Send response");alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window){result in MainActor.assumeIsolated{confirm(result == .alertFirstButtonReturn)}};return true
    }
    private func decide(_ decision: ApprovalAction) {
        guard let approval,approvalEnabled,!approval.submitting,!isHiddenOrHasHiddenAncestor else{return}
        guard decision == .accept, approval.method == "elicitation/create" else { approvalAction?(decision); return }
        guard let value = validatedContent() else { validateApproval(); return }
        // An elicitation's content never passes through the content-free ApprovalAction.accept callback.
        approvalValue?(["action": "accept", "content": value])
    }
    private func validatedContent() -> JSONValue? {
        guard let approval else { return nil }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data((jsonField?.stringValue ?? "{}").utf8))
            guard value.objectValue != nil else { validationLabel?.stringValue = "Enter a JSON object."; return nil }
            if let error=CoreResponseValidation.approval(["action":"accept","content":value],request:approval) {
                validationLabel?.stringValue = error; return nil
            }
            validationLabel?.stringValue = ""; return value
        } catch { validationLabel?.stringValue = "Enter valid JSON."; return nil }
    }
    private func validateApproval() {
        guard let approval, approval.method == "elicitation/create" else { return }
        let valid = validatedContent() != nil
        approvalAccept?.isEnabled = approvalEnabled && !approval.submitting && approvalValue != nil && valid
    }

    func configureQuestion(_ value: UserInputRequest, width: CGFloat, enabled: Bool = true, action: @escaping ([String: [String]]) -> Void) {
        answer = action
        if request == value && questionWidth == width && questionEnabled == enabled && questionGrid == grid && displayRevision == NativeDisplayOptions.shared.revision && appearanceRevision == NativeAppearance.revision { return }
        let same = request?.id == value.id && request?.questions == value.questions
        let retained = same ? fields : [:]
        request = value; questionWidth = width; questionEnabled = enabled; questionGrid = grid;displayRevision=NativeDisplayOptions.shared.revision;appearanceRevision=NativeAppearance.revision
        clear(keeping: Set(retained.values.map(ObjectIdentifier.init))); fields = [:]; optionButtons = [:]
        let x = columnX(width), w = columnWidth(width)
        var y: CGFloat = 12
        for question in value.questions {
            if !question.header.isEmpty { y = addText(question.header, x: x + 12, y: y, width: w - 24, weight: .semibold) + 4 }
            y = addText(question.prompt, x: x + 12, y: y, width: w - 24) + 8
            for option in question.options {
                let button = NativeCardButton(option.label) { [weak self] in
                    guard let self, self.questionEnabled, self.request?.submitting == false else { return }
                    self.fields[question.id]?.stringValue = option.label
                    self.questionEdited()
                }
                button.setButtonType(.radio); button.identifier = NSUserInterfaceItemIdentifier(question.id)
                button.isEnabled = enabled && !value.submitting
                button.frame = snapped(CGRect(x: x + 12, y: y, width: max(1, w - 24), height: 26))
                button.setAccessibilityHelp(option.description)
                button.setAccessibilityRole(.radioButton)
                optionButtons[question.id, default: []].append(button)
                addSubview(button); y += 28
                if !option.description.isEmpty { y = addText(option.description, x: x + 30, y: y, width: w - 42, quiet: true) + 4 }
            }
            let field: NSTextField = retained[question.id] ?? (question.isSecret ? NativeSecureField() : NativeLabel())
            field.placeholderString = question.options.isEmpty ? "Your answer" : "Or write an answer"
            prepareField(field, label: question.prompt, enabled: enabled && !value.submitting)
            field.usesSingleLineMode=question.isSecret;field.maximumNumberOfLines=question.isSecret ? 1:0
            field.cell?.wraps = !question.isSecret;field.cell?.isScrollable=question.isSecret
            field.lineBreakMode=question.isSecret ? .byClipping:.byWordWrapping
            field.identifier = NSUserInterfaceItemIdentifier(question.id)
            let fieldWidth=max(1,w-24-2*Self.fieldInset.width),height=answerHeight(field,width:fieldWidth,secret:question.isSecret)
            field.frame = snapped(CGRect(x: x + 12+Self.fieldInset.width, y: y+Self.fieldInset.height, width:fieldWidth, height:height))
            fields[question.id] = field
            if field.superview == nil { addSubview(field) }
            y += height+2*Self.fieldInset.height+12
        }
        let button = NativeCardButton("Submit answer") { [weak self] in self?.submit() }
        button.frame = snapped(CGRect(x: x + 12, y: y, width: min(130, max(1, w - 24)), height: 28))
        submitButton = button; addSubview(button)
        finish(width: width, y: y + 40)
        setAccessibilityLabel("Question")
        updateQuestionValidity()
    }
    private func updateQuestionValidity() {
        guard let request else { return }
        for question in request.questions {
            let answer = fields[question.id]?.stringValue ?? ""
            for button in optionButtons[question.id] ?? [] { button.state = button.title == answer ? .on : .off; button.needsDisplay = true }
        }
        submitButton?.isEnabled = questionEnabled && !request.submitting && !request.questions.isEmpty
            && Set(request.questions.map(\.id)).count == request.questions.count && request.questions.allSatisfy { !$0.id.isEmpty }
            && request.questions.allSatisfy { fields[$0.id]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
    private func submit() {
        updateQuestionValidity()
        guard let request, questionEnabled, !request.submitting, submitButton?.isEnabled == true else { return }
        answer?(Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, [fields[$0.id]?.stringValue ?? ""]) }))
    }
    func controlTextDidChange(_ obj: Notification) {
        if let control = obj.object as? NSTextField, control === jsonField { validateApproval(); onVisualChange?() }
        else { questionEdited() }
    }
    private func answerHeight(_ field:NSTextField,width:CGFloat,secret:Bool)->CGFloat {
        guard !secret else{return 18}
        let font=field.font ?? .systemFont(ofSize:13),paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
        let value=field.stringValue.isEmpty ? " ":field.stringValue+(field.stringValue.hasSuffix("\n") ? "\u{200b}":"")
        let height=(value as NSString).boundingRect(with:CGSize(width:width,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font,.paragraphStyle:paragraph]).height
        return ceil(min(max(18,height),4*ceil(font.ascender-font.descender+font.leading))*grid)/grid
    }
    private func questionEdited(){
        updateQuestionValidity()
        onVisualChange?()
        guard let request,let answer,request.questions.contains(where:{q in guard let field=fields[q.id]else{return false};return abs(field.frame.height-answerHeight(field,width:field.frame.width,secret:q.isSecret))>0.1})else{return}
        let width=questionWidth;questionWidth = -1
        configureQuestion(request,width:width,enabled:questionEnabled,action:answer)
        onHeightChange?()
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),let field=control as? NSTextField,
              fields.values.contains(where:{$0 === field}),!(field is NSSecureTextField) else{return false}
        textView.insertNewlineIgnoringFieldEditor(nil);return true
    }
    private func prepareField(_ field: NSTextField, label: String, enabled: Bool) {
        field.isEnabled = enabled; field.font = .systemFont(ofSize: 13)
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.isEditable = true; field.isSelectable = true; field.delegate = self
        field.focusRingType = .none; field.setAccessibilityLabel(label)
    }
    private static let fieldInset = CGSize(width: 8, height: 5)
    private func columnWidth(_ width: CGFloat) -> CGFloat { approvalSource == nil ? max(1,min(740,width-56)) : max(1,min(768,width-28)) }
    private func columnX(_ width: CGFloat) -> CGFloat { (width - columnWidth(width)) / 2 }
    private func snapped(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX * grid).rounded() / grid, y: (r.minY * grid).rounded() / grid, width: ceil(r.width * grid) / grid, height: ceil(r.height * grid) / grid)
    }
    private func clear(keeping retained: Set<ObjectIdentifier> = []) {
        if let commandScrollObservation { NotificationCenter.default.removeObserver(commandScrollObservation); self.commandScrollObservation = nil }
        for view in subviews where !retained.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
    }
    private func finish(width: CGFloat, y: CGFloat) {
        frame.size = CGSize(width: floor(width * grid) / grid, height: ceil(y * grid) / grid)
        paintRect = snapped(CGRect(x: columnX(width), y: 0, width: columnWidth(width), height: y))
        if approvalSource != nil {
            approvalGlass.isHidden = window == nil
            approvalGlass.frame = paintRect; approvalGlass.cornerRadius = 18
            approvalGlass.style = NativeAppearance.current.clearGlass ? .clear:.regular
            approvalGlass.tintColor = NativeAppearance.current.background?.withAlphaComponent(NativeAppearance.current.clearGlass ? 0.2:0.55)
            addSubview(approvalGlass,positioned:.below,relativeTo:subviews.first)
        }
        needsDisplay = true; setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    @discardableResult private func addText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                                            weight: NSFont.Weight = .regular, mono: Bool = false, quiet: Bool = false, size: CGFloat? = nil) -> CGFloat {
        let view = NativeTranscriptTextView()
        let rail = approvalSource != nil
        let font: NSFont = mono ? (rail ? .monospacedSystemFont(ofSize:12,weight:weight) : NativeAppearance.current.code.font((size ?? 12)*NativeAppearance.current.textScale,weight:weight)) : .systemFont(ofSize:(size ?? 13)*NativeAppearance.current.textScale,weight:weight)
        let paragraph = NSMutableParagraphStyle(); if !rail { paragraph.lineHeightMultiple = 1.2 }
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: quiet ? NativePalette.secondaryLabel : (rail ? NativeAppearance.current.foreground ?? NSColor.textColor : NativePalette.label), .paragraphStyle: paragraph]))
        let rect = snapped(CGRect(x: x, y: y, width: max(1, width), height: 18))
        let container = view.textContainer!
        container.containerSize = CGSize(width: rect.width, height: .greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: container)
        if rail, mono || weight == .semibold { view.textContainerInset.height = 1 }
        let minimum: CGFloat = rail ? (size == 10 ? 12 : (weight == .semibold ? 17:16)):18
        let height = max(minimum, ceil((view.layoutManager?.usedRect(for: container).height ?? minimum) * grid) / grid)
        view.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        let nextY = view.frame.maxY
        if rail && weight == .semibold {
            view.frame = snapped(view.frame.offsetBy(dx: 1, dy: -0.5))
        }
        if rail && quiet {
            view.identifier = NSUserInterfaceItemIdentifier("approval.note")
            view.textStorage?.addAttribute(.foregroundColor, value: NativeCardButton.railSecondary(in: window), range: NSRange(location: 0, length: view.string.utf16.count))
        }
        addSubview(view); return nextY
    }
    private func addCommand(_ text:String,x:CGFloat,y:CGFloat,width:CGFloat)->CGFloat {
        _ = addText(text,x:x,y:y,width:width,mono:true)
        guard let view=subviews.last as? NativeTranscriptTextView else{return y}
        let contentHeight=view.frame.height;view.removeFromSuperview();view.frame.origin = .zero
        let scroll=NSScrollView();scroll.contentView=NativeCardClipView();scroll.drawsBackground=false;scroll.borderType = .noBorder
        scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none;scroll.verticalScrollElasticity = .none
        scroll.frame=snapped(CGRect(x:x,y:y,width:width,height:min(136,contentHeight)));scroll.documentView=view
        scroll.contentView.postsBoundsChangedNotifications = true
        commandScrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisualChange?() }
            }
        scroll.setAccessibilityLabel("Approval command");addSubview(scroll);return scroll.frame.maxY
    }
    /// A column's moving capture stands in for the whole transcript, glass included. Its glass can't be captured (it
    /// comes out near black), so the card draws a plate of about the glass's brightness (66 70 70 over 38 43 44 in a recording): the swap back to the real
    /// glass at rest was a visible jump from dark to light (user 10-30).
    static var drawsMotionPlate=false
    static var drawsPhotoInk=false
    /// Normie's own card keeps its real glass under the source picture; a plate there would double it (it brightened by
    /// 23 levels at takeoff). A column's goes with the transcript at admission, and the picture has to carry it. A Normie
    /// card whose conversation will be a full column moves there at admission, glass and all, so the source plate gets a
    /// plate of its own for it just then (`ModeHandoffPlate.addCardPlates`). In the picture it read 66 as 89 until then.
    var leavesNormieForColumn=false
    private var inColumn:Bool {var v=superview;while let p=v {if p is NativeTranscript {return true};v=p.superview};return false}
    /// isHidden isn't enough: cacheDisplay still renders a hidden glass view's layers. Only out of the tree is it gone.
    func setGlassHiddenForCapture(_ hidden:Bool) {
        if hidden {approvalGlass.removeFromSuperview()}
        else if approvalSource != nil,approvalGlass.superview == nil {addSubview(approvalGlass,positioned:.below,relativeTo:subviews.first)}
    }
    override func draw(_ dirtyRect: NSRect) {
        let rail = approvalSource != nil, radius: CGFloat = rail ? 18:12
        // NSGlassEffectView supplies the real window material. Like Normie's composer, the offscreen
        // check draws a neutral plate: cacheDisplay cannot reproduce WindowServer refraction.
        let motionPlate=Self.drawsMotionPlate && inColumn
        if !Self.drawsPhotoInk && (!rail || window == nil || motionPlate) {
            (rail ? NativeDisplayOptions.plate(alpha:motionPlate ? 0.1:0.08):NativePalette.codeFill).setFill()
            NSBezierPath(roundedRect:paintRect,xRadius:radius,yRadius:radius).fill()
            (rail ? NSColor.black.withAlphaComponent(0.45):NativePalette.tertiaryLabel).setStroke()
            let border=NSBezierPath(roundedRect:paintRect.insetBy(dx:0.5/grid,dy:0.5/grid),xRadius:radius,yRadius:radius)
            border.lineWidth=1/grid; border.stroke()
        }
        for view in subviews where !view.isHidden {
            let plate: CGRect? = switch view {
            case let button as NativeCardButton where !button.radio && button.identifier?.rawValue != "approval.showConversation": rail ? nil:button.frame
            case let field as NSTextField where field.isEditable: field.frame.insetBy(dx: -Self.fieldInset.width, dy: -Self.fieldInset.height)
            default: nil
            }
            guard let plate else { continue }
            let enabled = (view as? NSControl)?.isEnabled ?? true
            NativeDisplayOptions.plate(alpha:enabled ? (rail ? 0.25:0.10):0.05).setFill()
            NSBezierPath(roundedRect: plate, xRadius: rail ? 6:7, yRadius: rail ? 6:7).fill()
        }
    }
}
