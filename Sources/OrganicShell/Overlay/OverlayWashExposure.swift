import AppKit

/// #56: a wash is a container in EVERY mode, including the temporary accum comparison.
/// Compatibility entry point: never creates a bitmap, filter, plusL subtree or replicator.
@MainActor enum OverlayWashExposure {
    static func prepare(group: CALayer, source: CALayer, image: CGImage, animations: [(String, CAAnimation)],
                        profile: DisplayProfile, origin: Double) -> [OverlayExposureFrame] {
        group.sublayers?.forEach { $0.removeFromSuperlayer() }; group.removeAllAnimations(); group.opacity = 0
        return []
    }
}
