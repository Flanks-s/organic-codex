import AppKit

extension NativeComposer {
    var densityWidth: CGFloat { layoutMode == .growing ? bounds.width : (targetWidth ?? retainedLayoutWidth) + (segment?.index == 0 ? bounds.height : 0) }

    func updateMenus() {
        let compact = layoutMode == .fullBar && densityWidth < (segment == nil ? 620 : 560)
        let value=MenusValue(compact:compact,growing:layoutMode == .growing,segmented:segment != nil,access:access,settings:settings,base:baseSettings,device:deviceName,queued:queued,restorable:queued.map{canRestoreQueued(id:$0.id)},catalog:ModelCatalog.models,appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision)
        guard menusValue != value else{return};menusValue=value;noteMenusBuild()
        accessButton.font = .systemFont(ofSize: 13); modelButton.font = .systemFont(ofSize: 13); modelButton.horizontalPadding = 6
        modelButton.segmentLabelSizing = layoutMode == .fullBar && segment != nil
        modelButton.chevronSpacing = modelButton.segmentLabelSizing ? 5 : 7
        accessButton.symbolTintColor = access == .full ? .systemOrange:NativePalette.secondaryLabel
        accessButton.removeAllItems(); accessButton.addItem(withTitle: compact ? "" : access.rawValue)
        accessButton.item(at: 0)?.image = NSImage(systemSymbolName: access == .full ? "exclamationmark.shield.fill" : "checkmark.shield", accessibilityDescription: nil)
        accessButton.contentTintColor = access == .full ? .systemOrange : NativePalette.label
        accessButton.setAccessibilityLabel("Permissions: " + access.rawValue)
        accessButton.toolTip = "Permissions on " + deviceName + ": " + access.rawValue
        let heading = NSMenuItem(title: "Permissions on " + deviceName, action: nil, keyEquivalent: "")
        accessButton.menu?.addItem(heading)
        for value in Access.allCases {
            let item = NSMenuItem(title: value.rawValue, action: #selector(accessPicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value.rawValue; item.state = value == access ? .on : .off
            accessButton.menu?.addItem(item)
        }

        let pending = settings.modelID != baseSettings.modelID || settings.effort != baseSettings.effort || settings.speed != baseSettings.speed || settings.daybreak != baseSettings.daybreak
        modelButton.removeAllItems()
        let label = compact ? settings.model.name+" · "+settings.effort.label : settings.label
        modelButton.addItem(withTitle: (pending ? "• " : "") + label)
        modelButton.setAccessibilityLabel("Next message model: " + settings.label + ", " + settings.speed.label + (pending ? ", override" : ""))
        modelButton.toolTip = settings.label + " · " + settings.speed.label + (pending ? " · Next message override" : "")
        for model in ModelCatalog.models {
            let item = NSMenuItem(title: model.full, action: #selector(modelPicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = model.id; item.isEnabled = settings.available(model)
            item.state = model.id == settings.modelID ? .on : .off; modelButton.menu?.addItem(item)
        }
        modelButton.menu?.addItem(.separator())
        let effort = NSMenuItem(title: "Reasoning effort", action: nil, keyEquivalent: ""), efforts = NSMenu()
        for level in settings.model.efforts {
            let item = NSMenuItem(title: level.label, action: #selector(effortPicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = level.rawValue; item.state = settings.effort == level ? .on : .off
            efforts.addItem(item)
        }
        effort.submenu = efforts; modelButton.menu?.addItem(effort)
        let tier = NSMenuItem(title: "Service tier", action: nil, keyEquivalent: ""), tiers = NSMenu()
        for speed in Speed.allCases {
            let item = NSMenuItem(title: speed.label, action: #selector(speedPicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = speed.rawValue; item.isEnabled = settings.model.availableSpeeds.contains(speed)
            item.state = settings.speed == speed ? .on : .off; tiers.addItem(item)
        }
        tier.submenu = tiers; modelButton.menu?.addItem(tier)
        let daybreak = NSMenuItem(title: "Daybreak", action: #selector(daybreakPicked), keyEquivalent: "")
        daybreak.target = self; daybreak.state = settings.daybreak ? .on : .off
        daybreak.isEnabled = !settings.model.reportedByCore || ModelCatalog.models.contains { ($0.cyberPrograms ?? []).contains("daybreakBlue") }
        modelButton.menu?.addItem(daybreak)
        if pending {
            let item = NSMenuItem(title: "Reset to current conversation settings", action: #selector(resetSettings), keyEquivalent: "")
            item.target = self; modelButton.menu?.addItem(item)
        }

        queueButton.removeAllItems(); queueButton.addItem(withTitle: "\(queued.count)")
        queueButton.item(at: 0)?.image = NSImage(systemSymbolName: "text.line.last.and.arrowtriangle.forward", accessibilityDescription: nil)
        queueButton.setAccessibilityLabel("Queued messages: \(queued.count)")
        queueButton.toolTip = "Queued messages; failed messages can be restored into an empty draft."
        for message in queued {
            let first = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Attachments"
            let title = (message.deliveryError == nil ? "Waiting: " : "Restore: ") + String(first.prefix(60))
            let item = NSMenuItem(title: title, action: #selector(queuePicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = message.id
            item.toolTip = message.deliveryError
            item.isEnabled = canRestoreQueued(id: message.id)
            queueButton.menu?.addItem(item)
        }
    }

    func updateChips() {
        let existing = Dictionary(attachmentChips.map { ($0.attachmentID, $0) }, uniquingKeysWith: { first, _ in first })
        for chip in attachmentChips where !attachments.contains(where: { $0.id == chip.attachmentID }) { chip.removeFromSuperview() }
        attachmentChips = attachments.map { attachment in
            let chip = existing[attachment.id] ?? NativeComposerAttachmentChip(attachment: attachment)
            chip.update(attachment)
            chip.onRemove = { [weak self] in self?.removeAttachment(id: attachment.id) }
            if chip.superview == nil { attachmentContent.addSubview(chip) }
            return chip
        }
    }

    /// A button's progress indicator, 5 pt inside it. A hidden button not laid out yet can be smaller than that, and
    /// insetting it gave CGRect.null to AppKit (an AppKit geometry warning; Sol's group-one stress check, 10-29).
    static func indicatorRect(in r: CGRect) -> CGRect {
        r.width > 10 && r.height > 10 ? r.insetBy(dx: 5, dy: 5) : CGRect(x: r.midX, y: r.midY, width: 0, height: 0)
    }
    func layoutControls() {
        if layoutMode == .growing{layoutGrowingControls();return}
        (scrollView.contentView as? NativeComposerSegmentClipView)?.continuous = segment != nil
        contextRow.isHidden = true; contextRow.spinner.animating = false; stopButton.normie = false
        sendButton.disabledFill = nil; voiceButton.disabledFill = nil
        scrollView.hasVerticalScroller = false
        let h = max(1, bounds.height), control = min(30, max(26, (h * 0.5).rounded()))
        let inset = max(4, ((h - control) / 2).rounded()), y = max(0, (h - control) / 2), gap: CGFloat = 4
        let compact = densityWidth < (segment == nil ? 620 : 560), tight = densityWidth < 440
        var left = inset, right = max(inset, bounds.width - inset)
        if let segment {
            // FocusedSegmentControls' HStack (spacing 4): 8 pt after a divider (the first segment's me slot is the
            // host's leading inset); at the end the identity orb's slot (the bar's height), else 10 pt, or the capsule's
            // end inset for the last segment.
            let endInset = ((h - control) / 2).rounded()
            left = (segment.index == 0 ? 0 : 8) + gap
            right = bounds.width - (segment.index > 0 ? h : segment.isLast ? endInset : 10) - gap
        }
        func leading(_ view: NSView, _ width: CGFloat) {
            view.frame = controlRect(CGRect(x: left, y: y, width: max(1, width), height: control)); left += width + gap
        }
        func trailing(_ view: NSView, _ width: CGFloat) {
            right -= width; view.frame = controlRect(CGRect(x: max(left, right), y: y, width: max(1, width), height: control)); right -= gap
        }
        let isVoice = state.voice != nil && segment == nil
        sendPressMotion.usesPressSpring=identity != nil && !isVoice
        leading(attachButton, control)
        accessButton.isHidden = segment != nil
        if segment == nil { leading(accessButton, compact ? control : accessButton.preferredWidth) }
        sendButton.isHidden = false
        voiceButton.isHidden = segment != nil || !isVoice && (state.running || state.sending || hasPendingSubmission || state.outcomeUnknown || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments || !attachments.isEmpty)
        // Voice occupies the empty-draft trailing slot; attachment-only drafts always expose Send.
        if !voiceButton.isHidden && !isVoice {
            sendButton.isHidden = true; trailing(voiceButton, control)
        } else {
            trailing(sendButton, control)
            if isVoice { trailing(voiceButton, control) }
        }
        attachmentScrollView.isHidden = attachments.isEmpty || isVoice
        if !attachmentScrollView.isHidden {
            let iconOnly = densityWidth < 220
            for chip in attachmentChips { chip.iconOnly = iconOnly }
            let width = min(190, max(iconOnly ? 44 : 52, (right - left) * 0.36))
            trailing(attachmentScrollView, width)
            attachmentScrollView.frame.origin.y = (h - 26) / 2
            attachmentScrollView.frame.size.height = 26
            var x: CGFloat = 0
            for chip in attachmentChips {
                let width = min(chip.preferredWidth, max(44, attachmentScrollView.contentSize.width))
                chip.frame = controlRect(CGRect(x: x, y: 0, width: width, height: 26)); chip.needsLayout = true; chip.layoutSubtreeIfNeeded(); x += width + 6
            }
            attachmentContent.frame = controlRect(CGRect(x: 0, y: 0, width: max(attachmentScrollView.contentSize.width, x), height: 26))
        }
        stopButton.isHidden = !state.running || segment != nil
        if !stopButton.isHidden { trailing(stopButton, control) }
        dictationButton.isHidden = tight || isVoice || segment != nil
        if !dictationButton.isHidden { trailing(dictationButton, control) }
        if segment != nil {
            // The product's HStack has two flexible children: the model is offered half the room after
            // fixed slots/controls/gaps, then its truncated intrinsic width leaves the remainder to the editor.
            trailing(modelButton,modelButton.width(fittingLabelProposal:max(0,(right-left-gap)/2)))
        } else {
            let proposal = attachments.isEmpty ? max(74, bounds.width * 0.38) : max(1, (right-left-gap) * 0.45)
            trailing(modelButton, min(modelButton.preferredWidth, proposal))
        }
        queueButton.isHidden = queued.isEmpty || segment != nil
        if !queueButton.isHidden { trailing(queueButton, 38) }
        contextButton.isHidden = true; historyRefreshButton.isHidden = !showsHistoryRecovery || segment != nil
        if !historyRefreshButton.isHidden {
            historyRefreshButton.title = compact ? "" : "Refresh history"
            historyRefreshButton.font = .systemFont(ofSize: 11)
            historyRefreshButton.imagePosition = compact ? .imageOnly : .imageLeading
            trailing(historyRefreshButton, compact ? control : 120)
        }
        scrollView.isHidden = isVoice
        voiceTextLabel.isHidden = !isVoice
        voiceTextLabel.stringValue = state.voice?.isEmpty == false ? state.voice! : "Listening…"
        voiceWaveform.isHidden = !isVoice;voiceWaveform.active=isVoice
        voiceWaveform.frame=controlRect(CGRect(x:left,y:y,width:36,height:control))
        voiceTextLabel.frame = controlRect(CGRect(x: left+46, y: y, width: max(1, right-left-46), height: control))
        let editorHeight = max(1, h - 8)
        scrollView.frame = controlRect(CGRect(x: left, y: 4, width: max(1, right - left), height: editorHeight))
        updateEditorInset()
        let width = max(1, scrollView.contentSize.width)
        if textView.frame.width != width {
            textView.setFrameSize(CGSize(width: width, height: max(scrollView.contentSize.height, textView.frame.height)))
            textView.textContainer?.containerSize.width = width
        }
        if textView.frame.origin != .zero { textView.setFrameOrigin(.zero) }
        sendingIndicator.frame = controlRect(Self.indicatorRect(in: sendButton.frame))
        stoppingIndicator.frame = controlRect(Self.indicatorRect(in: stopButton.frame))
        sendButton.image = state.sending || hasPendingSubmission ? nil : NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        stopButton.image = state.stopping || hasPendingStop ? nil : NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        if isVoice {
            sendButton.isEnabled = isEnabled && state.online && !state.usesLiveCore && !state.loading && !state.sending && !state.outcomeUnknown && !hasPendingSubmission && !(state.voice ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && onSendVoice != nil
        }
        contextRing.percent = contextPercent; contextRing.frame = controlRect(NativeComposerContextRing.frame(in: contextButton.bounds))
        contextButton.image = nil
    }

    /// Normie uses an editor above its own control row. Organic fullBar keeps the original horizontal path.
    private func layoutGrowingControls() {
        (scrollView.contentView as? NativeComposerSegmentClipView)?.continuous = false
        let h = max(120, bounds.height), control: CGFloat = 28, y = h-40, gap: CGFloat = 8
        contextRow.isHidden = false; contextRow.configure(workspace); contextRow.scale = controlScale
        sendButton.disabledFill = NativePrimaryButton.dockDisabledFill; voiceButton.disabledFill = NativePrimaryButton.dockDisabledFill
        // ComposerDock context leading -6 relative to the 14 pt content inset.
        contextRow.frame = controlRect(CGRect(x: 8,y: 10,width: max(1,bounds.width-22),height: 22))
        contextRow.needsLayout = true; contextRow.layoutSubtreeIfNeeded()
        contextRow.spinner.animating = !contextRow.spinner.isHidden
        stopButton.normie = true
        var left: CGFloat = 7.5, right = max(14,bounds.width-14)
        func leading(_ view: NSView,_ width: CGFloat) { view.frame=controlRect(CGRect(x:left,y:y,width:width,height:control)); left += width+gap }
        func trailing(_ view: NSView,_ width: CGFloat) { right-=width; view.frame=controlRect(CGRect(x:max(left,right),y:y,width:width,height:control)); right-=gap }
        let isVoice = state.voice != nil
        sendPressMotion.usesPressSpring=identity != nil && !isVoice
        accessButton.isHidden=false; leading(attachButton,control); leading(accessButton,accessButton.preferredWidth)
        // Normie offers Voice for an empty draft even while running; FullBar offers Send while running.
        voiceButton.isHidden = !isVoice && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments || !attachments.isEmpty || state.sending || hasPendingSubmission || state.outcomeUnknown)
        sendButton.isHidden = !voiceButton.isHidden && !isVoice
        if sendButton.isHidden { trailing(voiceButton,control) }
        else { trailing(sendButton,control); if isVoice { trailing(voiceButton,control) } }
        stopButton.isHidden = !state.running; if !stopButton.isHidden { trailing(stopButton,control) }
        dictationButton.isHidden = isVoice || identity == nil
        if !dictationButton.isHidden { trailing(dictationButton,control) }
        trailing(modelButton,min(modelButton.preferredWidth,max(74,bounds.width*0.38)))
        queueButton.isHidden = queued.isEmpty; if !queueButton.isHidden { trailing(queueButton,38) }
        contextButton.isHidden = showsHistoryRecovery || identity == nil
        historyRefreshButton.isHidden = !showsHistoryRecovery
        if showsHistoryRecovery {
            historyRefreshButton.title = "Refresh history"; historyRefreshButton.font = .systemFont(ofSize:11); historyRefreshButton.imagePosition = .imageLeading
            trailing(historyRefreshButton,120)
        } else if !contextButton.isHidden { trailing(contextButton,28) }
        attachmentScrollView.isHidden = attachments.isEmpty || isVoice
        let attached: CGFloat = attachmentScrollView.isHidden ? 0:36
        if !attachmentScrollView.isHidden {
            attachmentScrollView.frame = controlRect(CGRect(x:14,y:42,width:max(1,bounds.width-28),height:26))
            var x: CGFloat = 0
            for chip in attachmentChips {
                chip.iconOnly = false
                let width=min(chip.preferredWidth,max(52,attachmentScrollView.contentSize.width))
                chip.frame=controlRect(CGRect(x:x,y:0,width:width,height:26)); chip.needsLayout=true; chip.layoutSubtreeIfNeeded(); x+=width+6
            }
            attachmentContent.frame=controlRect(CGRect(x:0,y:0,width:max(attachmentScrollView.contentSize.width,x),height:26))
        }
        scrollView.isHidden = isVoice; voiceTextLabel.isHidden = !isVoice
        let editor = controlRect(CGRect(x:14,y:36+attached,width:max(1,bounds.width-28),height:max(36,h-84-attached)))
        scrollView.frame=editor;voiceWaveform.isHidden = !isVoice;voiceWaveform.active=isVoice
        voiceWaveform.frame=controlRect(CGRect(x:editor.minX,y:editor.minY,width:36,height:editor.height))
        voiceTextLabel.frame=controlRect(CGRect(x:editor.minX+46,y:editor.minY,width:max(1,editor.width-46),height:editor.height))
        voiceTextLabel.stringValue=state.voice?.isEmpty == false ? state.voice!:"Listening…"
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        updateEditorInset()
        let width = max(1,scrollView.contentSize.width)
        if textView.frame.width != width { textView.setFrameSize(CGSize(width:width,height:max(scrollView.contentSize.height,textView.frame.height))); textView.textContainer?.containerSize.width=width }
        if textView.frame.origin != .zero { textView.setFrameOrigin(.zero) }
        sendingIndicator.frame=controlRect(Self.indicatorRect(in:sendButton.frame)); stoppingIndicator.frame=controlRect(Self.indicatorRect(in:stopButton.frame))
        sendButton.image=state.sending || hasPendingSubmission ? nil:NSImage(systemSymbolName:"arrow.up",accessibilityDescription:nil)
        stopButton.image=state.stopping || hasPendingStop ? nil:NSImage(systemSymbolName:"stop.fill",accessibilityDescription:nil)
        if isVoice { sendButton.isEnabled=isEnabled && state.online && !state.usesLiveCore && !state.loading && !state.sending && !state.outcomeUnknown && !hasPendingSubmission && !(state.voice ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && onSendVoice != nil }
        contextRing.percent=contextPercent; contextRing.frame=controlRect(NativeComposerContextRing.frame(in:contextButton.bounds)); contextButton.image=nil
    }

    @objc private func accessPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = Access(rawValue: raw) else { return }; setAccess(value)
    }
    @objc private func modelPicked(_ item: NSMenuItem) {
        guard canEditOptions, let id = item.representedObject as? String else { return }
        var next = settings; next.pick(id); let notice = next.normalizeSpeed(); setSettings(next)
        if let notice { modelButton.toolTip = notice; modelButton.setAccessibilityHelp(notice) }
    }
    @objc private func effortPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = Effort(rawValue: raw), settings.model.efforts.contains(value) else { return }
        var next = settings; next.effort = value; next.memory[next.modelID] = value; setSettings(next)
    }
    @objc private func speedPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? Int, let value = Speed(rawValue: raw), settings.model.availableSpeeds.contains(value) else { return }
        var next = settings; next.speed = value; setSettings(next)
    }
    @objc private func daybreakPicked() {
        var next = settings; let notice = next.toggleDaybreak(); setSettings(next)
        if let notice { modelButton.toolTip = notice; modelButton.setAccessibilityHelp(notice) }
    }
    @objc private func resetSettings() { setSettings(baseSettings) }
    @objc private func queuePicked(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { restoreQueued(id: id) }
    }
}

@MainActor final class NativeComposerAttachmentChip: NativeFlippedView {
    let attachmentID: String
    let icon = NSImageView()
    let label = NativeLabel(labelWithString: "")
    let removeButton = NativeButton(title: "", target: nil, action: nil)
    var onRemove: (() -> Void)?
    var iconOnly = false { didSet { label.isHidden = iconOnly; needsLayout = true } }
    var preferredWidth: CGFloat { iconOnly ? 44 : min(190, max(80, label.intrinsicContentSize.width + 52)) }
    init(attachment: Attachment) {
        attachmentID = attachment.id; super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 13; layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        removeButton.isBordered = false; removeButton.target = self; removeButton.action = #selector(remove)
        for view in [icon, label, removeButton] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group); update(attachment)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ attachment: Attachment) {
        label.stringValue = attachment.name; icon.image = NSImage(systemSymbolName: attachment.symbol, accessibilityDescription: nil)
        icon.setAccessibilityElement(false); label.setAccessibilityLabel("Attachment: " + attachment.name)
        label.setAccessibilityElement(false)
        setAccessibilityLabel("Attachment: " + attachment.name)
        setAccessibilityIdentifier("composer.attachment." + attachmentID)
        removeButton.setAccessibilityIdentifier("composer.attachment." + attachmentID + ".remove")
        removeButton.setAccessibilityLabel("Remove " + attachment.name); toolTip = attachment.name; needsLayout = true
    }
    override func accessibilityChildren() -> [Any]? { [removeButton] }
    override func layout() {
        super.layout(); icon.frame = CGRect(x: 8, y: 6, width: 14, height: 14)
        label.frame = CGRect(x: 27, y: 4, width: max(1, floor(bounds.width - 51)), height: 18)
        removeButton.frame = CGRect(x: floor(bounds.width - 22), y: 3, width: 20, height: 20)
    }
    @objc private func remove() { onRemove?() }
}

@MainActor final class NativeComposerContextRing: NSView {
    var percent: Int? { didSet { needsDisplay = true } }
    /// Product ComposerDock: a 15 pt ring centred in its 28 pt control. Square whatever the control's height, on
    /// whole points (it was the control less 3 pt, taller than wide, so the track was an oval and the arc a circle).
    static let side: CGFloat = 15
    static func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: (bounds.midX - side / 2).rounded(), y: (bounds.midY - side / 2).rounded(), width: side, height: side)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        // One circle for the track and the arc (product ContextRing: primary at 0.15, the accent or orange from 80 %).
        let side = min(bounds.width, bounds.height), center = CGPoint(x: bounds.midX, y: bounds.midY), radius = side / 2 - 1
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        NativePalette.label.withAlphaComponent(0.15).setStroke()
        let track = NSBezierPath(ovalIn: circle); track.lineWidth = 2; track.stroke()
        if let percent {
            (percent >= 80 ? NSColor.systemOrange : NativePalette.accent).setStroke()
            let path = NSBezierPath(); path.lineWidth = 2; path.lineCapStyle = .round
            path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - CGFloat(min(100, max(0, percent))) * 3.6, clockwise: true)
            path.stroke()
        } else {
            NativePalette.secondaryLabel.setFill(); NSBezierPath(ovalIn: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)).fill()
        }
    }
}
