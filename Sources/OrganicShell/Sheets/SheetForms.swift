import AppKit

enum SheetFieldValidation: Sendable { case none, absolutePath, jsonObject }
struct SheetFormField: Sendable {
    var id: String
    var label: String
    var value = ""
    var placeholder = ""
    var required = false
    var secret = false
    var validation: SheetFieldValidation = .none
}
struct SheetFormRequest: Sendable {
    var title: String
    var message: String
    var confirmTitle = "OK"
    var cancelTitle = "Cancel"
    var destructive = false
    var fields: [SheetFormField] = []
}

/// A native AppKit form/confirmation body. The scene can mount it, or SheetNativeDialog can attach it as a window sheet.
@MainActor final class SheetForm: SheetSurface, NSTextFieldDelegate {
    private(set) var request = SheetFormRequest(title: "", message: "")
    private let heading = SheetStyle.label("", size: 14, weight: .semibold), message = SheetStyle.label("", size: 12, secondary: true)
    private let errorLabel = SheetStyle.label("", size: 11, secondary: true)
    let confirmButton = SheetButton(frame: .zero), cancelButton = SheetButton(frame: .zero)
    let scrollView = SheetScrollView(frame: .zero)
    private let document = OverlayView()
    private var fields: [String: NSTextField] = [:]
    private var labels: [NativeLabel] = [], plates: [SheetFieldPlate] = []
    private var centered = true
    private(set) var validationError: String?
    var isValid: Bool { validationError == nil }
    var onConfirm: (([String: String]) -> Void)?
    var onCancel: (() -> Void)?
    override var initialResponder: NSView? { request.fields.first.flatMap { fields[$0.id] } ?? confirmButton }
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        super.init(clock: clock); dismissesOnOutside = false; card.radius = 18
        for view in [heading, message, scrollView, errorLabel, cancelButton, confirmButton] { card.content.addSubview(view) }
        message.maximumNumberOfLines = 0; message.cell?.wraps = true; message.lineBreakMode = .byWordWrapping
        errorLabel.textColor = .systemRed; errorLabel.maximumNumberOfLines = 2; errorLabel.lineBreakMode = .byWordWrapping
        scrollView.borderType = .noBorder; scrollView.drawsBackground = false; scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true; scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false; scrollView.documentView = document
        confirmButton.invoke = { [weak self] in self?.confirm() }; cancelButton.invoke = { [weak self] in self?.dismiss(reason: .cancelled) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(_ request: SheetFormRequest, anchor: CGRect? = nil, in host: NSView) {
        self.request = request; centered = anchor == nil
        fields.removeAll(); labels.removeAll(); plates.removeAll(); document.subviews.forEach { $0.removeFromSuperview() }
        heading.stringValue = request.title; message.stringValue = request.message
        confirmButton.title = request.confirmTitle; confirmButton.accent = !request.destructive; confirmButton.destructive = request.destructive; cancelButton.title = request.cancelTitle
        for field in request.fields {
            let label = SheetStyle.label(field.label + (field.required ? " *" : ""), size: 11, weight: .medium, secondary: true), plate = SheetFieldPlate(frame: .zero)
            let input: NSTextField = field.secret ? SheetSecretField(frame: .zero) : SheetField(frame: .zero)
            input.stringValue = field.value; input.placeholderString = field.placeholder; input.delegate = self; input.setAccessibilityLabel(field.label); input.identifier = NSUserInterfaceItemIdentifier(field.id)
            document.addSubview(plate); document.addSubview(label); document.addSubview(input); labels.append(label); plates.append(plate)
            if fields[field.id] == nil { fields[field.id] = input }
        }
        let controls: [NSView] = request.fields.compactMap { fields[$0.id] } + [cancelButton, confirmButton]
        for i in controls.indices { controls[i].nextKeyView = controls[(i + 1) % controls.count] }
        validate(); setAccessibilityLabel(request.title)
        super.present(anchor: anchor ?? CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 0, height: 0), in: host)
    }
    override func layout() {
        super.layout(); let w = min(460, max(1, bounds.width - 24)), fieldHeight = CGFloat(request.fields.count) * 65
        let textRect = (request.message as NSString).boundingRect(with: CGSize(width: max(1, w - 40), height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let messageHeight = min(128, max(18, ceil(textRect.height)))
        let bodyTop: CGFloat = 56 + messageHeight, bottom: CGFloat = 90
        let h = min(max(1, bounds.height - 24), bodyTop + fieldHeight + bottom)
        card.frame = centered ? snapped(CGRect(x: max(12, bounds.midX - w / 2), y: max(12, bounds.midY - h / 2), width: w, height: h)) : anchored(size: CGSize(width: w, height: h), upward: true)
        card.layoutSubtreeIfNeeded()
        heading.frame = snapped(CGRect(x: 20, y: 20, width: w - 40, height: 22)); message.frame = snapped(CGRect(x: 20, y: 48, width: w - 40, height: messageHeight))
        scrollView.frame = snapped(CGRect(x: 20, y: bodyTop, width: w - 40, height: max(1, h - bodyTop - bottom)))
        document.frame = snapped(CGRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, fieldHeight)))
        for (i, field) in request.fields.enumerated() {
            let y = CGFloat(i) * 65
            labels[i].frame = snapped(CGRect(x: 0, y: y, width: document.bounds.width, height: 17))
            plates[i].frame = snapped(CGRect(x: 0, y: y + 22, width: document.bounds.width, height: 32))
            fields[field.id]?.frame = snapped(CGRect(x: 8, y: y + 28, width: max(1, document.bounds.width - 16), height: 21))
        }
        errorLabel.frame = snapped(CGRect(x: 20, y: h - 81, width: w - 40, height: 30))
        cancelButton.frame = snapped(CGRect(x: w - 214, y: h - 46, width: 82, height: 28)); confirmButton.frame = snapped(CGRect(x: w - 124, y: h - 46, width: 104, height: 28))
    }
    var values: [String: String] {
        Dictionary(request.fields.compactMap { field -> (String, String)? in
            guard let input = fields[field.id] else { return nil }
            let raw = input.stringValue
            return (field.id, field.validation == .absolutePath ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw)
        }, uniquingKeysWith: { first, _ in first })
    }
    @discardableResult func setValue(_ value: String, fieldID: String) -> Bool { guard let field = fields[fieldID] else { return false }; field.stringValue = value; validate(); return true }
    func controlTextDidChange(_ obj: Notification) { validate() }
    private func validate() {
        let ids = request.fields.map(\.id)
        if ids.contains("") || Set(ids).count != ids.count { validationError = "Every form field must have a unique, nonempty ID." }
        else {
            validationError = nil
            for field in request.fields {
                let raw = fields[field.id]?.stringValue ?? "", trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if field.required && trimmed.isEmpty { validationError = "Complete \(field.label)."; break }
                if trimmed.isEmpty && !field.required { continue }
                if field.validation == .absolutePath && (!trimmed.hasPrefix("/") || raw.contains("\n") || raw.contains("\r") || raw.contains("\0")) { validationError = "Enter an absolute path on the Core host."; break }
                if field.validation == .jsonObject {
                    if let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data), value is [String: Any] {} else { validationError = "Enter a valid JSON object for \(field.label)."; break }
                }
            }
        }
        errorLabel.stringValue = validationError ?? ""; confirmButton.isEnabled = validationError == nil
    }
    func confirm() { guard isShowing, !isDismissing else { return }; validate(); guard isValid else { return }; let result = values; dismiss(reason: .confirmed); onConfirm?(result) }
    override func willDismiss(reason: SheetDismissReason) { if reason != .confirmed { onCancel?() } }
    override func handleKey(_ key: OverlayKey) -> Bool { guard isShowing, !isDismissing else { return false }; if key == .enter { confirm(); return true }; return super.handleKey(key) }
}

/// Native beginSheet lifecycle with a custom drawn AppKit form, never a system-bezel NSAlert accessory tree.
@MainActor final class SheetNativeDialog {
    let form: SheetForm
    private let factory: SheetWindowFactory
    private var handle: (any SheetWindowHandle)?
    private var generation: UUID?
    private var requestEpoch = 0
    var isShowing: Bool { handle != nil }
    var onConfirm: (([String: String]) -> Void)?
    var onCancel: (() -> Void)?
    init(clock: any OverlayClock = OverlaySystemClock(), factory: @escaping SheetWindowFactory = { SheetAppKitWindow(configuration: $0, onClose: $1) }) {
        self.factory = factory; form = SheetForm(clock: clock)
        form.onConfirm = { [weak self] in self?.finish(values: $0) }; form.onCancel = { [weak self] in self?.finish(values: nil) }
    }
    isolated deinit { handle?.dismiss() }
    func present(_ request: SheetFormRequest, sheetFor parent: NSWindow) { present(request) { $0.presentSheet(for: parent) } }
    /// Injection seam; production callers normally use sheetFor:. No window is created by the form itself.
    func present(_ request: SheetFormRequest, attach: (any SheetWindowHandle) -> Void) {
        requestEpoch += 1; let requestID = requestEpoch; finish(values: nil)
        guard requestEpoch == requestID else { return }
        let messageHeight = min(128, max(18, ceil((request.message as NSString).boundingRect(with: CGSize(width: 420, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 12)]).height)))
        let height = min(620, 170 + messageHeight + CGFloat(request.fields.count) * 65)
        let id = UUID(); generation = id
        let h = factory(.init(title: request.title, size: CGSize(width: 484, height: height), minimumSize: CGSize(width: 484, height: height), resizable: false)) { [weak self] in
            guard let self, self.generation == id else { return }; self.finish(values: nil, windowAlreadyClosed: true)
        }
        handle = h; form.present(request, in: h.host); attach(h)
        // beginSheet creates the real window association after the offscreen body has been prepared.
        if let responder = form.initialResponder { h.host.window?.makeFirstResponder(responder) }
    }
    func dismiss() { requestEpoch += 1; finish(values: nil) }
    private func finish(values: [String: String]?, windowAlreadyClosed: Bool = false) {
        guard let handle else { return }; self.handle = nil; generation = nil
        form.dismiss(reason: values == nil ? .cancelled : .confirmed, animated: false)
        if !windowAlreadyClosed { handle.dismiss() }
        if let values { onConfirm?(values) } else { onCancel?() }
    }
}
