import AppKit
import CoreGraphics

/// Glyph material: the accumulate exposure (spec §5.1), validated in Smear Lab 26102802 and moved into the
/// render server by Render Probes 26102803 (P1). Gated by the per-frame step in millimetres (spec §6).
struct ExposureSettings: Sendable {
    var enabled = true
    /// Share of one frame interval the exposure covers (1 = 360° shutter, 0.5 = 180°).
    var shutter = 1.0
    /// Per-frame physical step where the effect begins, and where it is fully applied. Smear Lab's
    /// 4 → 10 pt on the Dell (0.27 mm/pt).
    var onsetMM = 1.08, fullMM = 2.7
    /// Spacing between copies, and their cap.
    var spacing: CGFloat = 1.5
    var maxCopies = 40
}

/// The exposure of one glyph node at one instant: how many equal-weight copies, how far apart in time.
struct ExposureSample: Sendable {
    var count = 1
    var alpha: CGFloat = 1
    /// Time between copies; they replay the node's own animation, so they lie on its real path.
    var delayStep = 0.0
    var stepPt: CGFloat = 0
    var length: CGFloat = 0
    /// How far the gate is open (0…1): the share of the sweep the copies cover.
    var gate: CGFloat = 0

    static let still = ExposureSample()

    /// `earlier` is the node's screen position one exposure (shutter × frame interval) before `now`.
    init(now a: CGPoint, earlier b: CGPoint, frameInterval: Double, mmPerPoint: Double, settings s: ExposureSettings) {
        guard s.enabled else { return }
        let exposure = s.shutter * frameInterval
        let swept = hypot(a.x - b.x, a.y - b.y)
        stepPt = swept * CGFloat(frameInterval / max(1e-6, exposure))
        let stepMM = Double(stepPt) * mmPerPoint
        let gate = CGFloat(smoothstep(s.onsetMM, s.fullMM, stepMM))
        self.gate = gate
        length = swept * gate
        // No cut-off: the smear shrinks to nothing with the gate. Smear Lab dropped it below 0.75 pt, which
        // showed as a step in sharpness and brightness on the frame it ended (self-test, 2026-10-28).
        guard length > 0.01 else { return }
        count = min(s.maxCopies, 1 + Int(ceil(length / s.spacing)))
        // Equal weights. A feature covered by every copy composites to 1 − 0.1 × gate: 0.9 when fully gated in,
        // and back to 1 as the gate closes, so the end of a smear never steps in brightness.
        alpha = CGFloat(1 - pow(0.1 * Double(gate), 1 / Double(count)))
        delayStep = Double(gate) * exposure / Double(count - 1)
    }

    private init() {}

    /// Keyframe value for `instanceColor`. An animated instanceColor is premultiplied twice (rgb × α²,
    /// measured 2026-10-28 on macOS 26.6.2 and 27.2), so rgb is pre-divided by α in extended sRGB.
    /// Quantized to 1/1024 and cached: a transition asks for thousands.
    @MainActor var instanceColor: CGColor {
        let q = max(1, Int((alpha * 1024).rounded()))
        if let c = Self.colors[q] { return c }
        let a = CGFloat(q) / 1024
        let c = CGColor(colorSpace: Self.extended, components: [1 / a, 1 / a, 1 / a, a])!
        Self.colors[q] = c
        return c
    }

    private static let extended = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    @MainActor private static var colors: [Int: CGColor] = [:]
}

func smoothstep(_ lower: Double, _ upper: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - lower) / max(0.0001, upper - lower)))
    return t * t * (3 - 2 * t)
}
