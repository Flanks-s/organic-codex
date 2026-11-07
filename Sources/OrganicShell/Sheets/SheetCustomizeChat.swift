import AppKit

struct SheetChatCustomization: Equatable {
    var name: String
    var symbol: OrbCelestialBody
    var tint: OrbTint
    var identity: OrbIdentity { OrbIdentity(symbol: symbol, tint: tint) }
}

@MainActor final class SheetCustomizeChat: SheetSurface, NSTextFieldDelegate {
    let nameField = SheetField(frame: .zero)
    let preview = SheetIdentityPreview(frame: .zero)
    let defaultsButton = SheetButton(frame: .zero), cancelButton = SheetButton(frame: .zero), doneButton = SheetButton(frame: .zero)
    private let fieldPlate = SheetFieldPlate(frame: .zero)
    private let heading = SheetStyle.label("Customize Chat", size: 13, weight: .semibold)
    private let symbolLabel = SheetStyle.label("Symbol", size: 11, weight: .semibold, secondary: true)
    private let tintLabel = SheetStyle.label("Color", size: 11, weight: .semibold, secondary: true)
    private(set) var symbolButtons: [SheetButton] = [], tintButtons: [SheetButton] = []
    private(set) var draft = SheetChatCustomization(name: "", symbol: .mercury, tint: .silver)
    private(set) var tintPicked = false
    private var originalName = ""
    var onDone: ((SheetChatCustomization) -> Void)?
    var onCancel: (() -> Void)?
    override var initialResponder: NSView? { nameField }
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        super.init(clock: clock); dismissesOnOutside = false
        for view in [preview, heading, fieldPlate, nameField, symbolLabel, tintLabel, defaultsButton, cancelButton, doneButton] { card.content.addSubview(view) }
        nameField.placeholderString = "Chat name"; nameField.setAccessibilityLabel("Chat name"); nameField.delegate = self
        for symbol in OrbCelestialBody.allCases {
            let b = SheetButton(frame: .zero); b.title = symbol.name; b.setAccessibilityLabel(symbol.name)
            b.drawContent = { [weak self] rect in
                guard let self else { return }; SheetStyle.glyph(.init(symbol: symbol, tint: self.tintPicked ? self.draft.tint : OrbTint.allCases[symbol.rawValue]), in: rect.insetBy(dx: 9, dy: 9))
            }
            b.invoke = { [weak self] in self?.selectSymbol(symbol) }; symbolButtons.append(b); card.content.addSubview(b)
        }
        for tint in OrbTint.allCases {
            let b = SheetButton(frame: .zero); b.title = String(describing: tint).capitalized; b.drawsPlate = false
            b.drawContent = { [weak self] rect in
                tint.color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                if self?.draft.tint == tint { NSColor.white.withAlphaComponent(0.7).setStroke(); let p = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75)); p.lineWidth = 1.5; p.stroke() }
            }
            b.invoke = { [weak self] in self?.selectTint(tint) }; tintButtons.append(b); card.content.addSubview(b)
        }
        defaultsButton.title = "Use Defaults"; defaultsButton.invoke = { [weak self] in self?.useDefaults() }
        cancelButton.title = "Cancel"; cancelButton.invoke = { [weak self] in self?.dismiss(reason: .cancelled) }
        doneButton.title = "Done"; doneButton.accent = true; doneButton.invoke = { [weak self] in self?.commit() }
        let controls: [NSView] = [nameField] + symbolButtons + tintButtons + [defaultsButton, cancelButton, doneButton]
        for i in controls.indices { controls[i].nextKeyView = controls[(i + 1) % controls.count] }
        setAccessibilityLabel("Customize Chat")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(name: String, identity: OrbIdentity, level: Double, in host: NSView) {
        originalName = name; draft = .init(name: name, symbol: identity.symbol, tint: identity.tint); tintPicked = false
        nameField.stringValue = name; preview.level = level; sync()
        super.present(anchor: CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 0, height: 0), in: host)
    }
    override func layout() {
        super.layout(); let width = min(400, max(1, bounds.width - 24)), height: CGFloat = 350
        card.frame = snapped(CGRect(x: max(12, bounds.midX - width / 2), y: max(12, bounds.midY - height / 2), width: width, height: height)); card.layoutSubtreeIfNeeded()
        preview.frame = snapped(CGRect(x: 20, y: 20, width: 64, height: 64))
        heading.frame = snapped(CGRect(x: 100, y: 21, width: max(1, width - 120), height: 20))
        fieldPlate.frame = snapped(CGRect(x: 100, y: 48, width: max(1, width - 120), height: 32))
        nameField.frame = snapped(CGRect(x: 108, y: 54, width: max(1, width - 136), height: 21))
        symbolLabel.frame = snapped(CGRect(x: 20, y: 102, width: width - 40, height: 16))
        for (i, b) in symbolButtons.enumerated() { b.frame = snapped(CGRect(x: 20 + CGFloat(i % 7) * 48, y: 126 + CGFloat(i / 7) * 48, width: 42, height: 42)) }
        tintLabel.frame = snapped(CGRect(x: 20, y: 228, width: width - 40, height: 16))
        let tintStep = min(30, max(22, (width - 62) / 12))
        for (i, b) in tintButtons.enumerated() { b.frame = snapped(CGRect(x: 20 + CGFloat(i) * tintStep, y: 252, width: 22, height: 22)) }
        defaultsButton.frame = snapped(CGRect(x: 20, y: 302, width: 108, height: 28))
        cancelButton.frame = snapped(CGRect(x: width - 168, y: 302, width: 70, height: 28)); doneButton.frame = snapped(CGRect(x: width - 90, y: 302, width: 70, height: 28))
    }
    func setName(_ value: String) { nameField.stringValue = value; draft.name = value }
    func controlTextDidChange(_ obj: Notification) { draft.name = nameField.stringValue }
    func selectSymbol(_ symbol: OrbCelestialBody) { guard !isDismissing else { return }; draft.symbol = symbol; if !tintPicked { draft.tint = OrbTint.allCases[symbol.rawValue] }; sync() }
    func selectTint(_ tint: OrbTint) { guard !isDismissing else { return }; draft.tint = tint; tintPicked = true; sync() }
    func useDefaults() { draft.tint = OrbTint.allCases[draft.symbol.rawValue]; tintPicked = false; sync() }
    func commit() {
        guard isShowing, !isDismissing else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.name = name.isEmpty ? originalName : name
        let result = draft; dismiss(reason: .confirmed); onDone?(result)
    }
    override func handleKey(_ key: OverlayKey) -> Bool {
        guard isShowing, !isDismissing else { return false }
        if key == .enter { commit(); return true }; return super.handleKey(key)
    }
    override func willDismiss(reason: SheetDismissReason) { if reason != .confirmed { onCancel?() } }
    private func sync() {
        preview.identity = draft.identity
        for (i, b) in symbolButtons.enumerated() { b.selected = OrbCelestialBody.allCases[i] == draft.symbol; b.needsDisplay = true }
        for (i, b) in tintButtons.enumerated() { b.selected = OrbTint.allCases[i] == draft.tint; b.needsDisplay = true }
        defaultsButton.isEnabled = draft.tint != OrbTint.allCases[draft.symbol.rawValue]
    }
}
