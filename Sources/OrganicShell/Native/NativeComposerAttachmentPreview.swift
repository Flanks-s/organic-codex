import AppKit
import QuartzCore

/// Content-only preview. The host samples its geometry; it owns no timer, display link or input resources.
@MainActor final class NativeComposerAttachmentPreview: NativeFlippedView {
    static let entryDuration = 0.100
    static let exitDuration = 0.080
    static let blurRadius = 6.0
    private(set) var payload: DragAttachmentPayload
    let session: DragAttachmentPayload.Session
    private(set) var title: String
    let hint = NativeLabel(labelWithString: "")
    let ghost = NativeFlippedView()
    let ink = NativeFlippedView()
    let label = NativeLabel(labelWithString: "")
    let icon = NSImageView()
    private var effects: [ContentGaussianTransition] = []
    private(set) var isLeaving = false
    private(set) var needsFrames = false
    private(set) var progress: CGFloat = 0
    private(set) var displacement: CGFloat = 0
    private(set) var chipWidth: CGFloat = 80
    var endTime: Double? { effects.compactMap(\.endTime).max() }
    init(payload: DragAttachmentPayload, session: DragAttachmentPayload.Session, title: String, clock: SceneClock) {
        self.payload = payload; self.session = session; self.title = title
        super.init(frame: .zero)
        wantsLayer = true; setAccessibilityElement(false)
        hint.stringValue = (payload.isQuote ? "Quote in " : "Attach to ") + title
        hint.font = .systemFont(ofSize: 11, weight: .medium); hint.textColor = NativePalette.secondaryLabel
        hint.setAccessibilityLabel(hint.stringValue)
        label.stringValue = payload.previewName; label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        chipWidth = min(190, max(80, label.intrinsicContentSize.width + 34))
        icon.image = NSImage(systemSymbolName: payload.isQuote ? "text.quote" : payload.attachments.first?.symbol ?? "doc", accessibilityDescription: nil)
        icon.setAccessibilityElement(false); label.setAccessibilityElement(false)
        ghost.wantsLayer = true; ghost.layer?.cornerRadius = 13
        ghost.layer?.borderWidth = 1; ghost.layer?.borderColor = NativePalette.secondaryLabel.withAlphaComponent(0.35).cgColor
        ghost.setAccessibilityElement(false); ink.setAccessibilityElement(false)
        addSubview(hint); addSubview(ghost); ghost.addSubview(ink); ink.addSubview(icon); ink.addSubview(label)
        for view in [hint, ink] {
            view.wantsLayer = true
            var config = ContentGaussianTransition.Configuration()
            config.duration = Self.entryDuration; config.radius = Self.blurRadius
            effects.append(ContentGaussianTransition(content: view.layer!, clock: clock, initiallyVisible: false, configuration: config))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func begin(at time: Double) {
        isLeaving = false; needsFrames = true
        for effect in effects { effect.configuration.duration = Self.entryDuration; effect.setVisible(true, at: time) }
    }
    /// Same-session changes keep the current geometric envelope and continue from its pose/velocity.
    func replace(payload: DragAttachmentPayload, title: String, at time: Double) {
        self.payload = payload; self.title = title
        hint.stringValue = (payload.isQuote ? "Quote in " : "Attach to ") + title
        hint.setAccessibilityLabel(hint.stringValue)
        label.stringValue = payload.previewName
        icon.image = NSImage(systemSymbolName: payload.isQuote ? "text.quote" : payload.attachments.first?.symbol ?? "doc", accessibilityDescription: nil)
        begin(at: time)
    }
    func leave(at time: Double) {
        guard !isLeaving else { return }
        isLeaving = true; needsFrames = true
        for effect in effects { effect.configuration.duration = Self.exitDuration; effect.setVisible(false, at: time) }
    }
    @discardableResult func sample(at time: Double, sendFrame: CGRect, reduceMotion: Bool) -> Bool {
        for effect in effects { effect.settle(at: time) }
        needsFrames = effects.contains { $0.plan != nil }
        progress = CGFloat(effects.first?.pose(at: time).opacity ?? 0)
        displacement = reduceMotion ? 0 : (chipWidth + 8) * progress
        ghost.isHidden = reduceMotion
        frame = CGRect(x: sendFrame.minX, y: sendFrame.minY - 20, width: max(chipWidth, hint.intrinsicContentSize.width), height: 46)
        hint.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 16)
        ghost.frame = CGRect(x: 0, y: 20, width: chipWidth, height: 26)
        ghost.layer?.borderColor = NativePalette.secondaryLabel.withAlphaComponent(0.35 * progress).cgColor
        ink.frame = ghost.bounds
        icon.frame = CGRect(x: 8, y: 6, width: 14, height: 14)
        label.frame = CGRect(x: 27, y: 4, width: max(1, chipWidth - 35), height: 18)
        return needsFrames
    }
    func cancel() {
        for effect in effects { effect.setVisible(false, animated: false) }
        needsFrames = false; progress = 0; displacement = 0
    }
}
