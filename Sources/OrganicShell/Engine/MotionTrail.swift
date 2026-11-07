import AppKit
import QuartzCore

/// M10 (DECISIONS #39, docs/reference/M10-PLAN-26102923.md): the exposure beyond the scene flights. Only two tools —
/// accumulation for translating glyphs and stretch for solids and glass — both gated
/// by the per-frame physical step, so nothing changes at rest or below the onset (spec §6).

/// The per-frame step of a box: the farthest any corner moved. A box that only grows has a step too (its edges sweep),
/// including true shape changes during translation. Appearance/exit/replacement use ContentGaussianTransition (#56).
enum MotionStep {
    static func edge(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(hypot(a.minX - b.minX, a.minY - b.minY), hypot(a.maxX - b.maxX, a.minY - b.minY),
            hypot(a.minX - b.minX, a.maxY - b.maxY), hypot(a.maxX - b.maxX, a.maxY - b.maxY))
    }
}

extension ExposureSample {
    /// A box's exposure: the sweep of its edges (translation and scale together) over one exposure.
    init(now: CGRect, earlier: CGRect, frameInterval: Double, mmPerPoint: Double, settings s: ExposureSettings) {
        // The same gate and copies as a point that moved as far as the farthest corner.
        let d = MotionStep.edge(now, earlier)
        self.init(now: CGPoint(x: d, y: 0), earlier: .zero, frameInterval: frameInterval, mmPerPoint: mmPerPoint, settings: s)
    }
}

/// Driver A's accumulation: for a layer moved or resized on the main thread every frame, a replicator whose copies lie
/// on the chord back to where it was one exposure earlier — translated and scaled, so glyphs on a translating/resizing box follow that motion
/// (Smear Lab's original per-frame method; driver B keeps `instanceDelay` on the real path, FlightNode).
///
/// Do not use this for appearance, disappearance or content replacement (DECISIONS #56).
/// Put tightly cropped glyph/icon textures inside `layer` (a CAReplicatorLayer); call `update` once a frame with the content's frame now
/// and one exposure earlier, both in the replicator's coordinates. At rest it is one copy at full opacity: pixel for
/// pixel the content alone.
@MainActor final class ChordTrail {
    let layer = CAReplicatorLayer()
    var settings = ExposureSettings()
    private(set) var sample = ExposureSample.still

    init() { reset() }

    func update(now: CGRect, earlier: CGRect, profile: DisplayProfile) {
        let s = ExposureSample(now: now, earlier: earlier, frameInterval: profile.frameInterval, mmPerPoint: profile.mmPerPoint, settings: settings)
        sample = s
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        guard s.count > 1, now.width > 0, now.height > 0 else { reset(); return }
        // Copy k sits k/(n−1) of the gated way back along the chord: a translation and, for a box whose size changes,
        // a scale about its centre (instanceTransform compounds per copy, so both are per-copy steps).
        let n = CGFloat(s.count - 1), g = s.gate
        let back = CGPoint(x: (earlier.midX - now.midX) * g / n, y: (earlier.midY - now.midY) * g / n)
        let sx = pow(max(0.01, earlier.width / now.width), g / n), sy = pow(max(0.01, earlier.height / now.height), g / n)
        var t = CATransform3DMakeTranslation(now.midX, now.midY, 0)
        t = CATransform3DTranslate(t, back.x, back.y, 0)
        t = CATransform3DScale(t, sx, sy, 1)
        t = CATransform3DTranslate(t, -now.midX, -now.midY, 0)
        layer.instanceCount = s.count
        layer.instanceTransform = t
        // A model value (not keyframed), so not premultiplied twice: plain white at the equal weight.
        layer.instanceColor = NSColor(white: 1, alpha: s.alpha).cgColor
    }

    /// One copy at full opacity: the content alone.
    func reset() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sample = .still; layer.instanceCount = 1; layer.instanceTransform = CATransform3DIdentity; layer.instanceColor = NSColor.white.cgColor
        CATransaction.commit()
    }
}

/// Stretch for solids and glass moved on the main thread (spec §5.2: glass only through a real frame change, never a
/// transform). The shape keeps its leading edge and reaches back along its motion by the gated sweep; its ends stay
/// round (the caller keeps the corner radius at half the short side). At rest, or below the onset, it is `now` exactly.
enum MotionStretch {
    static func rect(now: CGRect, earlier: CGRect, profile: DisplayProfile, settings s: ExposureSettings = ExposureSettings()) -> CGRect {
        let sample = ExposureSample(now: CGPoint(x: now.midX, y: now.midY), earlier: CGPoint(x: earlier.midX, y: earlier.midY),
                                    frameInterval: profile.frameInterval, mmPerPoint: profile.mmPerPoint, settings: s)
        guard sample.length > 0.01 else { return now }
        let g = sample.gate
        let dx = (earlier.midX - now.midX) * g, dy = (earlier.midY - now.midY) * g
        // Reach back toward where it was: grow on the trailing side only.
        return limited(CGRect(x: dx < 0 ? now.minX + dx : now.minX, y: dy < 0 ? now.minY + dy : now.minY,
                              width: now.width + abs(dx), height: now.height + abs(dy)), now: now)
    }

    /// How far paint may reach past the shape, as a share of its short side. Uncapped, a fast flight or one late frame
    /// turned a 40 pt orb into a 200 pt capsule (user 10-30). Only the paint is limited, never the pose.
    static let maxReach: CGFloat = 0.6

    static func limited(_ painted: CGRect, now: CGRect) -> CGRect {
        let reach = maxReach * min(now.width, now.height)
        let left = min(reach, max(0, now.minX - painted.minX)), right = min(reach, max(0, painted.maxX - now.maxX))
        let top = min(reach, max(0, now.minY - painted.minY)), bottom = min(reach, max(0, painted.maxY - now.maxY))
        return CGRect(x: now.minX - left, y: now.minY - top, width: now.width + left + right, height: now.height + top + bottom)
    }
}
