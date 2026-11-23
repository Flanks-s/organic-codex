import AppKit

struct SheetChatCustomization: Equatable {
    var name: String
    var symbol: OrbCelestialBody
    var tint: OrbTint
    var bodyID: String? = nil
    var tintID: String? = nil
    var resolvedBodyID: String { bodyID ?? String(describing:symbol) }
    var identity: OrbIdentity { OrbIdentity(symbol:symbol,tint:tint,bodyID:bodyID,tintID:tintID) }
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
    /// Persistence migration gates identity edits, while the conversation title remains editable.
    var bodySelectionEnabled = true { didSet { if oldValue != bodySelectionEnabled { sync() } } }
    override var initialResponder: NSView? { nameField }
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        super.init(clock: clock); dismissesOnOutside = false
        for view in [preview, heading, fieldPlate, nameField, symbolLabel, tintLabel, defaultsButton, cancelButton, doneButton] { card.content.addSubview(view) }
        nameField.placeholderString = "Chat name"; nameField.setAccessibilityLabel("Chat name"); nameField.delegate = self
        for bodyID in BodyIdentityAdapter.choices {
            let b = SheetButton(frame: .zero); b.title = bodyID.capitalized; b.setAccessibilityLabel(bodyID.capitalized)
            b.drawContent = { rect in
                BodyFaceDrawing.draw(bodyID,in:rect.insetBy(dx:5,dy:5))
            }
            b.invoke = { [weak self] in self?.selectBody(bodyID) }; symbolButtons.append(b); card.content.addSubview(b)
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
        originalName = name; draft = .init(name:name,symbol:identity.symbol,tint:identity.tint,bodyID:identity.bodyID,tintID:identity.tintID); tintPicked = false
        nameField.stringValue = name; preview.level = level; sync()
        super.present(anchor: CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 0, height: 0), in: host)
    }
    override func layout() {
        super.layout(); let width = min(400, max(1, bounds.width - 24)), height: CGFloat = 446
        card.frame = snapped(CGRect(x: max(12, bounds.midX - width / 2), y: max(12, bounds.midY - height / 2), width: width, height: height)); card.layoutSubtreeIfNeeded()
        preview.frame = snapped(CGRect(x: 20, y: 20, width: 64, height: 64))
        heading.frame = snapped(CGRect(x: 100, y: 21, width: max(1, width - 120), height: 20))
        fieldPlate.frame = snapped(CGRect(x: 100, y: 48, width: max(1, width - 120), height: 32))
        nameField.frame = snapped(CGRect(x: 108, y: 54, width: max(1, width - 136), height: 21))
        symbolLabel.frame = snapped(CGRect(x: 20, y: 102, width: width - 40, height: 16))
        for (i, b) in symbolButtons.enumerated() { b.frame = snapped(CGRect(x: 20 + CGFloat(i % 7) * 48, y: 126 + CGFloat(i / 7) * 48, width: 42, height: 42)) }
        tintLabel.frame = snapped(CGRect(x: 20, y: 324, width: width - 40, height: 16))
        let tintStep = min(30, max(22, (width - 62) / 12))
        for (i, b) in tintButtons.enumerated() { b.frame = snapped(CGRect(x: 20 + CGFloat(i) * tintStep, y: 348, width: 22, height: 22)) }
        defaultsButton.frame = snapped(CGRect(x: 20, y: 398, width: 108, height: 28))
        cancelButton.frame = snapped(CGRect(x: width - 168, y: 398, width: 70, height: 28)); doneButton.frame = snapped(CGRect(x: width - 90, y: 398, width: 70, height: 28))
    }
    func setName(_ value: String) { nameField.stringValue = value; draft.name = value }
    func controlTextDidChange(_ obj: Notification) { draft.name = nameField.stringValue }
    func selectSymbol(_ symbol: OrbCelestialBody) { selectBody(String(describing:symbol)) }
    func selectBody(_ bodyID: String) {
        guard bodySelectionEnabled,!isDismissing,BodyIdentityAdapter.choices.contains(bodyID) else { return }
        draft.bodyID=bodyID
        if let symbol=OrbCelestialBody.allCases.first(where:{String(describing:$0)==bodyID}) { draft.symbol=symbol }
        if !tintPicked { applyDefaultTint() }; sync()
    }
    private func applyDefaultTint() {
        guard let catalogue=BodyResources.shared.catalogue,let body=try? catalogue.body(draft.resolvedBodyID) else { return }
        let tint=BodyTintCatalogue.defaultTint(body); draft.tintID=tint.id
        if let raw=tint.legacyRawValue,let old=OrbTint(rawValue:raw) { draft.tint=old }
    }
    func selectTint(_ tint: OrbTint) { guard bodySelectionEnabled,!isDismissing else { return }; draft.tint=tint; draft.tintID=nil; tintPicked=true; sync() }
    func useDefaults() { guard bodySelectionEnabled else { return }; applyDefaultTint(); tintPicked=false; sync() }
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
        for (i, b) in symbolButtons.enumerated() { b.isEnabled=bodySelectionEnabled; b.selected = BodyIdentityAdapter.choices[i] == draft.resolvedBodyID; b.needsDisplay = true }
        for (i, b) in tintButtons.enumerated() { b.isEnabled=bodySelectionEnabled; b.selected = (draft.tintID ?? String(describing:draft.tint)) == String(describing:OrbTint.allCases[i]); b.needsDisplay = true }
        let defaultID=BodyResources.shared.catalogue.flatMap { try? $0.body(draft.resolvedBodyID) }.map { BodyTintCatalogue.defaultTint($0).id }
        defaultsButton.isEnabled = bodySelectionEnabled && (draft.tintID ?? String(describing:draft.tint)) != defaultID
    }
}
