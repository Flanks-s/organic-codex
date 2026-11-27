import Foundation

/// A finite spring with continuous position/velocity when its target changes.
struct FunctionPanelSpring {
    var value: Double = 0
    var velocity: Double = 0
    var target: Double = 0
    mutating func advance(_ seconds: Double, response: Double, damping: Double) {
        let steps = max(1, Int(ceil(seconds * 240))), dt = seconds / Double(steps)
        let omega = 2 * Double.pi / response
        for _ in 0..<steps {
            velocity += (omega * omega * (target - value) - 2 * damping * omega * velocity) * dt
            value += velocity * dt
        }
    }
    mutating func finish() { value = target; velocity = 0 }
}

struct FunctionPanelMotion {
    private(set) var spring = FunctionPanelSpring()
    private(set) var began = 0.0
    private(set) var last = 0.0
    private(set) var deadline = 0.0
    private(set) var active = false
    private(set) var swapping = false
    private(set) var swapBegan = 0.0
    private(set) var frames = 0
    var needsFrames: Bool { active || swapping }
    var progress: Double { min(1, max(0, spring.value)) }
    func stageGate(_ delay: Double, now: Double) -> Double {
        if !active && spring.target == 1 { return 1 }
        guard spring.target == 1 else { return progress }
        return progress * min(1, max(0, (now - began - delay) / 0.25))
    }
    func contentProgress(at time: Double) -> Double {
        let entry = !active && spring.target == 1 ? 1 : spring.target == 1 ? min(1, max(0,
                (time - began - 0.71) / 0.13)) : progress
        let swap = swapping ? min(1, max(0, (time - swapBegan) / 0.2)) : 1
        return entry * swap
    }
    mutating func setOpen(_ open: Bool, at time: Double, reduced: Bool) {
        swapping = false
        spring.target = open ? 1 : 0
        began = time; last = time; deadline = time + (open ? 1.7 : 1.1)
        active = !reduced
        if reduced { spring.finish(); deadline = time }
    }
    mutating func swap(at time: Double, reduced: Bool) {
        swapping = !reduced; swapBegan = time
    }
    mutating func advance(to time: Double) {
        guard needsFrames else { return }
        frames += 1
        if active {
            spring.advance(max(0, min(0.05, time - last)), response: 0.5, damping: 0.84)
            if time >= deadline { spring.finish(); active = false }
        }
        if swapping && time - swapBegan >= 0.2 { swapping = false }
        last = time
    }
    mutating func retire() { active = false; swapping = false; spring.target = 0; spring.finish() }
}

/// Mock Pin/Archive actions use the same finite scheduling owner as the stage.
struct FunctionPanelActionMotion {
    private(set) var value = 0.0
    private(set) var active = false
    private var from = 0.0
    private var target = 0.0
    private var began = 0.0
    private var duration = 0.72
    mutating func set(_ target: Double, at time: Double, duration: Double = 0.72, reduced: Bool) {
        from = value; self.target = target; began = time; self.duration = duration
        active = !reduced
        if reduced { value = target }
    }
    mutating func advance(to time: Double) {
        guard active else { return }
        let t = min(1, max(0, (time - began) / duration)), eased = t * t * (3 - 2 * t)
        value = from + (target - from) * eased
        if t == 1 { active = false; value = target }
    }
    mutating func retire() { active = false; value = 0; from = 0; target = 0 }
}
