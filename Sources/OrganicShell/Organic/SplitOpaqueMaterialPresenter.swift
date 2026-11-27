import AppKit

/// Installed once beneath the original content, before the glass enters a host.
@MainActor final class SplitOpaqueMaterialPresenter: NSView {
    private weak var glass: NSGlassEffectView?
    private let fill = CAShapeLayer()
    private var observation: UUID?
    init?(glass: NSGlassEffectView) {
        guard glass.superview == nil, glass.window == nil, let content = glass.contentView,
              !content.subviews.contains(where: { $0 is SplitOpaqueMaterialPresenter }) else {
            return nil
        }
        self.glass = glass
        super.init(frame: glass.bounds)
        wantsLayer = true
        layer?.addSublayer(fill)
        setAccessibilityElement(false)
        content.addSubview(self, positioned: .below, relativeTo: nil)
        observation = NativeDisplayOptions.shared.observe { [weak self] in self?.synchronize() }
        synchronize()
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }
    isolated deinit {
        if let observation {
            NativeDisplayOptions.shared.removeObserver(observation)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
    /// The host calls this in its pose transaction when its contour or clip changes.
    func synchronize() {
        guard let glass, let content = glass.contentView, superview === content else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = content.convert(glass.bounds, from: glass)
        fill.frame = bounds
        let radius = min(glass.cornerRadius, min(bounds.width, bounds.height) / 2)
        fill.path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        fill.fillColor = NativeDisplayOptions.plate(alpha: 0.12).cgColor
        isHidden = !NativeDisplayOptions.shared.state.reducesEffects
        CATransaction.commit()
    }
}
