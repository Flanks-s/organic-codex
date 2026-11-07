import AppKit
import QuartzCore

/// Static working dots. M11.47 removes idle light and breathing loops; notification transitions own motion.
final class DotsLayer: CALayer {
    enum Size: Equatable {
        /// In a lyric line of this size.
        case large(CGFloat)
        /// In a 12 × 12 pt indicator's place.
        case compact
    }
    /// Legacy metric retained for existing layout callers; no repeating animation uses this period.
    static let period: CFTimeInterval = 2.4

    static func box(_ size: Size) -> CGSize {
        switch size {
        // One lyric line's height (the lyric's line box is about 1.2 × its size), the dots' width.
        case .large(let l): CGSize(width: (1.34 * l).rounded(.up), height: (1.2 * l).rounded())
        case .compact: CGSize(width: 12, height: 12)
        }
    }

    private let group = CALayer()
    private let dots = [CALayer(), CALayer(), CALayer()]
    private(set) var size = Size.compact

    override init() {
        super.init()
        addSublayer(group)
        for dot in dots { group.addSublayer(dot) }
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var metrics: (diameter: CGFloat, gap: CGFloat, dim: Float, lit: Float, breath: CGFloat) {
        switch size {
        case .large(let l): (0.30 * l, 0.22 * l, 0.34, 1, 1.06)
        case .compact: (2.5, 2, 0.34 * 0.78, 0.78, 1.04)
        }
    }

    /// Retained API for callers sharing presentation lifetime with other ink.
    func setRunning(_ on: Bool) {
        let now = CACurrentMediaTime()
        if !on, speed != 0 { let t = convertTime(now, from: nil); speed = 0; timeOffset = t }
        else if on, speed == 0 { let t = timeOffset; speed = 1; timeOffset = 0; beginTime = 0; beginTime = convertTime(now, from: nil) - t }
    }

    /// Lays out static working ink in the existing box; `still` remains source-compatible.
    func configure(_ size: Size, color: NSColor, scale: CGFloat, still: Bool = false) {
        self.size = size
        let m = metrics, total = 3 * m.diameter + 2 * m.gap
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentsScale = scale
        group.bounds = CGRect(x: 0, y: 0, width: total, height: m.diameter)
        // Large: from the lyric's leading edge, centred in its line. Compact: centred in its square.
        let x: CGFloat = if case .large = size { total / 2 } else { bounds.width / 2 }
        group.position = CGPoint(x: x, y: bounds.height / 2)
        for (i, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(i) * (m.diameter + m.gap), y: 0, width: m.diameter, height: m.diameter)
            dot.cornerRadius = m.diameter / 2
            dot.backgroundColor = color.cgColor
            dot.contentsScale = scale
        }
        CATransaction.commit()
        restart(still: still)
    }

    func stop() {
        group.removeAllAnimations()
        for dot in dots { dot.removeAllAnimations() }
    }

    private func restart(still: Bool) {
        stop()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for dot in dots { dot.opacity = 0.62 * metrics.lit }
        group.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}
