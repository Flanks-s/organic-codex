import AppKit
import QuartzCore

/// All coordinates are y down. Fixed drawing coordinates; its parent scales with the Dock.
final class OrbLiquid {
    let layer = CALayer()
    private let spinner = CALayer()
    let fill = CAGradientLayer()
    private let surface = CAShapeLayer()
    private var size: CGFloat = 0
    private var amplitude: CGFloat = -1
    private var spins = 0
    private var activitySerial: UInt64 = 0
    private var initialized = false
    private var lastSettleStart: Double?
    private var restPosition = CGPoint.zero
    private var restPath: CGPath?
    static let settleDuration = 0.9
    private let metrics: OrbMetrics

    init(metrics: OrbMetrics) {
        self.metrics = metrics
        layer.masksToBounds = true
        layer.addSublayer(spinner); spinner.addSublayer(fill); fill.mask = surface
        fill.startPoint = CGPoint(x: 0.5, y: 0); fill.endPoint = CGPoint(x: 0.5, y: 1)
        surface.anchorPoint = .zero
    }
    func settleColors() { fill.removeAnimation(forKey:"colors") }

    func configure(size d: CGFloat, level: Double?, colors: [CGColor], wobble: CGFloat, compactions: Int, animate: Bool, activitySerial: UInt64 = 0, eventVisible: Bool = true) {
        let resized = d != size
        if resized {
            size = d
            let box = CGRect(x: 0, y: 0, width: d, height: d)
            layer.frame = box; layer.cornerRadius = d / 2
            spinner.frame = box; fill.frame = box
            surface.bounds = CGRect(x: 0, y: -d, width: d, height: 2*d)
        }
        layer.isHidden = level == nil
        let target = CGPoint(x: 0, y: d * (1 - CGFloat(level ?? 0)) - d)
        restPosition = target
        let from = surface.presentation()?.position ?? surface.position
        surface.position = target
        if initialized, animate, from != target {
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = NSValue(point: from); a.toValue = NSValue(point: target); a.duration = 0.9
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = surface.convertTime(CACurrentMediaTime(), from: nil)
            surface.add(a, forKey: "level")
        }
        let priorColors = fill.presentation()?.colors ?? fill.colors
        if (fill.colors as? [CGColor]) != colors {
            fill.colors = colors
            if initialized, animate {
                let a = CABasicAnimation(keyPath: "colors")
                a.fromValue = priorColors; a.toValue = colors; a.duration = 0.4
                a.beginTime = fill.convertTime(CACurrentMediaTime(), from: nil)
                fill.add(a, forKey: "colors")
            }
        }
        // The model is always the exact resting surface. CA owns only the finite excursion.
        if resized || amplitude != 0 {
            amplitude = 0
            surface.removeAnimation(forKey: "wobble")
            surface.path = wave(phase: 0)
            restPath = surface.path
        }
        if resized {finishFeedback()}
        settle(activitySerial:activitySerial, amplitude:wobble, animate:initialized && animate && eventVisible)
        if wobble<=0 {finishFeedback()}
        if initialized, spins != compactions, animate {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi; a.duration = 0.9
            a.beginTime = spinner.convertTime(CACurrentMediaTime(), from: nil)
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            spinner.add(a, forKey: "spin")
        }
        if !animate {
            finishFeedback()
        }
        spins = compactions; initialized = true
    }

    /// Consume every serial, but merge events during the excursion without restarting or queuing a tail.
    func settle(activitySerial:UInt64, amplitude wobble:CGFloat, animate:Bool) {
        guard activitySerial != self.activitySerial else {return}
        self.activitySerial=activitySerial
        guard animate,wobble>0 else {finishFeedback();return}
        guard activitySerial>0 else {return}
        // Monotonic wall time is independent of the parent clock held by the ambient lifecycle.
        let now=CACurrentMediaTime()
        guard lastSettleStart.map({now-$0 >= Self.settleDuration}) ?? true else {return}
        if let current=surface.animation(forKey:"eventSettle"),surface.convertTime(now,from:nil)-current.beginTime<current.duration {return}
        surface.removeAnimation(forKey:"eventSettle")
        let a=CAKeyframeAnimation(keyPath:"path")
        a.values=(0...24).map { index in
            let t=Double(index)/24
            // Flat first/last segments preserve zero entry/exit velocity in CA's linear interpolation.
            let u=min(1,max(0,(t-1.0/24)/(1-2.0/24)))
            amplitude=wobble*CGFloat(16*u*u*(1-u)*(1-u))
            return wave(phase:4 * .pi * t)
        }
        amplitude=0
        a.duration=Self.settleDuration;a.repeatCount=0
        let started=CACurrentMediaTime();lastSettleStart=started
        a.beginTime=surface.convertTime(started,from:nil)
        a.preferredFrameRateRange=OrbTuning.ambient
        surface.add(a,forKey:"eventSettle")
    }

    func synchronizeActivity(from source:OrbLiquid) {
        activitySerial=source.activitySerial;lastSettleStart=source.lastSettleStart
    }

    /// Finish before a parent clock is held. Never freeze a presentation wave or level interpolation.
    func finishFeedback() {
        surface.removeAnimation(forKey:"eventSettle");surface.removeAnimation(forKey:"level");surface.removeAnimation(forKey:"wobble")
        spinner.removeAnimation(forKey:"spin");fill.removeAnimation(forKey:"colors")
        amplitude=0;surface.position=restPosition
        if let restPath {surface.path=restPath}
    }

    private func wave(phase: Double) -> CGPath {
        metrics.value.liquidPaths += 1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: size))
        for i in 0...24 {
            let k = Double(i) / 24 * 2 * .pi
            let y = amplitude * CGFloat(0.7 * sin(k + phase) + 0.3 * sin(2*k - phase))
            path.addLine(to: CGPoint(x: size * CGFloat(i) / 24, y: y))
        }
        path.addLine(to: CGPoint(x: size, y: size)); path.closeSubpath()
        return path
    }

    #if ORB_SELFTEST || ISLAND_SELFTEST
    var surfaceLayer: CALayer { surface }
    var spinnerLayer: CALayer { spinner }
    #endif
}
