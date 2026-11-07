import QuartzCore

/// Driver B (spec §4): a committed transition sampled on a uniform grid and handed to the render server
/// as keyframes in one transaction. The main thread takes no part until the transition ends.
struct Timeline: Sendable {
    let began: Double
    let duration: Double
    /// Sample times relative to `began`: a uniform grid strictly inside the duration, then the end.
    let times: [Double]
    let linearKeys: [NSNumber]

    /// The display's rate, at least 120 Hz. Geometry uses cubic (Catmull-Rom) keys, so the render server's
    /// in-between samples stay well under a pixel; the rest is linear.
    static func rate(frameInterval: Double) -> Double { max(120, 1 / max(1e-4, frameInterval)) }

    init(began: Double, duration: Double, rate: Double) {
        let d = max(duration, 1 / rate)
        let m = max(1, Int(ceil(d * rate)))
        let grid = (0..<m).map { Double($0) / rate } + [d]
        self.began = began
        self.duration = d
        times = grid
        linearKeys = grid.map { NSNumber(value: $0 / d) }
    }

    /// Keyframes for `keyPath` (one value per entry of `times`), not yet started. Discrete keyframes take one
    /// fewer value: CA wants one more key time than values, so the final sample is dropped. `smooth` uses
    /// cubic keys (geometry); otherwise linear.
    @MainActor func track(_ layer: CALayer, _ keyPath: String, _ values: [Any], discrete: Bool = false, smooth: Bool = false) -> Track? {
        // A value that never changes needs no animation: the model already holds it (callers set the end pose).
        if let first = values.first as? NSObject, values.allSatisfy({ ($0 as? NSObject)?.isEqual(first) == true }) { return nil }
        if let first = values.first, CFGetTypeID(first as CFTypeRef) == CGColor.typeID,
           values.allSatisfy({ CFEqual($0 as CFTypeRef, first as CFTypeRef) }) { return nil }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = discrete ? Array(values.dropLast()) : values
        animation.keyTimes = linearKeys
        animation.calculationMode = discrete ? .discrete : smooth ? .cubic : .linear
        animation.duration = duration
        // Backwards fill holds the first pose for delayed replicator copies that sample before the start.
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return Track(layer: layer, key: "shell.\(keyPath)", animation: animation)
    }

    func map<T>(_ f: (Double) -> T) -> [T] { times.map(f) }
}

/// One prepared animation: started when its transition commits (driver B).
struct Track {
    let layer: CALayer
    let key: String
    let animation: CAKeyframeAnimation

    /// Starts at media time `began`. The layer must already be in its tree.
    @MainActor func start(at began: Double) {
        animation.beginTime = layer.convertTime(began, from: nil)
        layer.add(animation, forKey: key)
    }
}

extension CALayer {
    /// Ends driver-B animations on this layer; callers set the model values first.
    @MainActor func removeShellAnimations() {
        for key in animationKeys() ?? [] where key.hasPrefix("shell.") { removeAnimation(forKey: key) }
    }
}
