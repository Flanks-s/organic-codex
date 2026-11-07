import CoreGraphics
import Foundation

/// Preserve a carried item's pointer offset when entering unflipped screen coordinates.
enum DragCarryGeometry {
    static func screenCenter(pointer:CGPoint,offset:CGPoint)->CGPoint {
        CGPoint(x:pointer.x+offset.x,y:pointer.y-offset.y)
    }
}

extension DragCarryGeometry {
    /// The header's damped follow offset becomes its original pickup offset after tear takes ownership.
    /// Keep the first sample exact, and freeze the same pose before a drop, merge, or return animation.
    struct TearOffset {
        let began:Double
        let x:Spring,y:Spring
        private var sampledAt:Double
        private var frozen:CGPoint?
        var duration:Double {max(x.duration,y.duration)}
        var isStopped:Bool {frozen != nil}

        init(from:CGPoint,to:CGPoint,at time:Double,spring:(response:Double,damping:Double)) {
            began=time;sampledAt=time
            x=Spring(from:from.x,to:to.x,response:spring.response,damping:spring.damping,epsilon:Spring.restEpsilon)
            y=Spring(from:from.y,to:to.y,response:spring.response,damping:spring.damping,epsilon:Spring.restEpsilon)
        }
        mutating func advance(at time:Double)->CGPoint {
            if let frozen {return frozen}
            sampledAt=max(sampledAt,time)
#if M10_DOCK_SELFTEST
            // Negative control reproduces round two's permanently retained handoff offset.
            if ProcessInfo.processInfo.environment["M1111_TEAR_OFFSET_NEGATIVE"] == "1" {return CGPoint(x:x.from,y:y.from)}
#endif
            return CGPoint(x:x.sample(sampledAt-began).value,y:y.sample(sampledAt-began).value)
        }
        mutating func stop(at time:Double) {
            guard frozen == nil else {return}
            frozen=advance(at:time)
        }
    }
}
