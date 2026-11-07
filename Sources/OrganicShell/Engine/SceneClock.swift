import AppKit
import QuartzCore

/// One clock per window (spec §3.1). The display link runs only while driver-A work asks for frames;
/// every callback hands out the frame's target timestamp, which is where poses are sampled.
@MainActor final class SceneClock: NSObject {
    private var link: CADisplayLink?
    private var until = 0.0
    var onFrame: ((Double) -> Void)?
    private(set) var log = FrameLog()

    func attach(to view: NSView) {
        link?.invalidate()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l
    }

    /// Frames keep coming whatever `until` says (a node held under the pointer bobs its neighbours).
    var keepRunning = false { didSet { if keepRunning { link?.isPaused = false } } }

    /// Keeps frames coming until `time` (media time).
    func run(until time: Double) {
        until = max(until, time)
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        let start = CACurrentMediaTime()
        onFrame?(l.targetTimestamp)
        log.add(target: l.targetTimestamp, interval: l.targetTimestamp - l.timestamp, busy: CACurrentMediaTime() - start)
        if l.targetTimestamp > until && !keepRunning { l.isPaused = true; log.pause() }
    }

    func invalidate() { link?.invalidate(); link = nil }
}

/// Display-link callbacks only: they are not proof of presented frames (recordings and the camera are).
struct FrameLog {
    var ticks = 0, longGaps = 0
    var maxGapMs = 0.0, maxBusyMs = 0.0, busyTotalMs = 0.0
    private var last = 0.0

    mutating func add(target: Double, interval: Double, busy: Double) {
        if last > 0 {
            let gap = target - last
            maxGapMs = max(maxGapMs, gap * 1000)
            if interval > 0, gap > interval * 1.5 { longGaps += 1 }
        }
        last = target; ticks += 1
        maxBusyMs = max(maxBusyMs, busy * 1000); busyTotalMs += busy * 1000
    }

    /// The next callback after a pause is not a gap.
    mutating func pause() { last = 0 }

    var fields: [String: Any] {
        ["ticks": ticks, "gapsOver1_5Frames": longGaps, "maxGapMs": maxGapMs, "maxBusyMs": maxBusyMs,
         "meanBusyMs": ticks > 0 ? busyTotalMs / Double(ticks) : 0]
    }
}
