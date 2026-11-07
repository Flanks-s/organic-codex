import AppKit

@MainActor final class SheetCompareConfirmation: SheetSurface {
    private let title = SheetStyle.label("Start a compare test?", size: 13, weight: .semibold)
    private let message = SheetStyle.label("Messages you type here go to both conversations at once.", size: 12, secondary: true)
    let suppressionButton = SheetButton(frame: .zero), cancelButton = SheetButton(frame: .zero), confirmButton = SheetButton(frame: .zero)
    private(set) var neverAsk = false
    private var upward = true
    var onNeverAskChange: ((Bool) -> Void)?
    var onConfirm: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    override init(clock: any OverlayClock = OverlaySystemClock()) {
        super.init(clock: clock); card.radius = 14
        for view in [title, message, suppressionButton, cancelButton, confirmButton] { card.content.addSubview(view) }
        message.maximumNumberOfLines = 0; message.cell?.wraps = true; message.lineBreakMode = .byWordWrapping
        suppressionButton.title = "Don't ask again"; suppressionButton.drawsPlate = false
        suppressionButton.drawContent = { [weak self] rect in
            guard let self else { return }
            (self.neverAsk ? NSColor.controlAccentColor : .white.withAlphaComponent(0.1)).setFill(); NSBezierPath(roundedRect: CGRect(x: 0, y: 5, width: 14, height: 14), xRadius: 3, yRadius: 3).fill()
            if self.neverAsk { SheetStyle.text("✓", in: CGRect(x: 1, y: 3, width: 14, height: 17), size: 12, color: .white, weight: .bold) }
            SheetStyle.text("Don't ask again", in: CGRect(x: 21, y: 4, width: max(1, rect.width - 21), height: 18), size: 12)
        }
        suppressionButton.invoke = { [weak self] in guard let self else { return }; self.setNeverAsk(!self.neverAsk) }
        cancelButton.title = "Cancel"; cancelButton.invoke = { [weak self] in self?.dismiss(reason: .cancelled) }
        confirmButton.title = "Compare"; confirmButton.accent = true; confirmButton.invoke = { [weak self] in self?.confirm() }
        setAccessibilityLabel("Compare confirmation")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(anchor: CGRect, in host: NSView, neverAsk: Bool, upward: Bool = true) {
        self.neverAsk = neverAsk; self.upward = upward; suppressionButton.selected = neverAsk
        super.present(anchor: anchor, in: host)
    }
    override func layout() {
        super.layout(); card.frame = anchored(size: CGSize(width: 280, height: 168), upward: upward); card.layoutSubtreeIfNeeded()
        let w = card.bounds.width
        title.frame = snapped(CGRect(x: 14, y: 14, width: w - 28, height: 19))
        message.frame = snapped(CGRect(x: 14, y: 42, width: w - 28, height: 38))
        suppressionButton.frame = snapped(CGRect(x: 14, y: 89, width: w - 28, height: 24))
        cancelButton.frame = snapped(CGRect(x: w - 168, y: 126, width: 68, height: 28)); confirmButton.frame = snapped(CGRect(x: w - 92, y: 126, width: 78, height: 28))
    }
    func setNeverAsk(_ value: Bool) { guard isShowing, !isDismissing else { return }; neverAsk = value; suppressionButton.selected = value; suppressionButton.needsDisplay = true; onNeverAskChange?(value) }
    func confirm() { guard isShowing, !isDismissing else { return }; let value = neverAsk; dismiss(reason: .confirmed); onConfirm?(value) }
    override func willDismiss(reason: SheetDismissReason) { if reason != .confirmed { onCancel?() } }
    override func handleKey(_ key: OverlayKey) -> Bool { guard isShowing, !isDismissing else { return false }; if key == .enter { confirm(); return true }; return super.handleKey(key) }
}
