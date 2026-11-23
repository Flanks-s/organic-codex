import AppKit
import QuartzCore

/// Immutable host input. All retained endpoints resolve the same conversation clock.
struct BodyPhaseEvent: Equatable {
    let sourceID: String
    let value: BodyPhaseValue
    let serial: UInt64
    var animate=true
}

@MainActor final class BodyPhasePlayback {
    private(set) var event: BodyPhaseEvent
    private(set) var began: Double
    private var transition: BodyPhaseTransition?
    private var emphasis: BodyPhaseEmphasis?
    private var emphasisBegan=0.0
    private var completionGlow=0.0,completionGlowVelocity=0.0
    private(set) var flashStart: Double = 0
    private(set) var duration: Double = 0
    private var observers:[UUID:()->Void]=[:]
    func observe(_ callback:@escaping()->Void)->UUID {let id=UUID();observers[id]=callback;return id}
    func removeObserver(_ id:UUID) {observers[id]=nil}
    init(_ event: BodyPhaseEvent, at time: Double) { self.event=event; began=time }
    func update(_ next: BodyPhaseEvent, at time: Double) {
        guard next.serial>=event.serial,event != next else { return }
        if next.serial == event.serial,!event.animate,next.animate {return}
        let previous=event
        defer {if event != previous {for callback in Array(observers.values) {callback()}}}
        if !next.animate {
            event=next;began=time;transition=nil;emphasis=nil;duration=0;flashStart=0;return
        }
        let pose=sample(at:time)
        let changed=event.value != next.value
        if !changed {
            event=next
            if next.value.state == .unknown {
                let p=BodyProfile.current.phase
                if finished(at:time) {began=time;transition=nil;duration=0}
                emphasis=BodyPhaseEmphasis(from:pose,amplitude:p.unknownEventGain,duration:Double(p.unknownEventDuration))
                emphasisBegan=time;duration=max(duration,time-began+Double(p.unknownEventDuration))
            }
            return
        }
        event=next; began=time; transition=nil; emphasis=nil; duration=0; flashStart=0
        if changed {
            let motion=BodyPhaseTransition(from:pose,to:next.value)
            transition=motion; duration=motion.duration
            if next.value.state == .completed {
                var lo=0.0,hi=motion.duration
                for _ in 0..<36 {
                    let mid=(lo+hi)/2
                    if motion.sample(at:mid).sample.lit >= 0.985 { hi=mid } else { lo=mid }
                }
                flashStart=hi
                completionGlow=Double(pose.sample.emphasis);completionGlowVelocity=pose.velocity[5]
                duration=flashStart+Double(BodyProfile.current.phase.doneRise+BodyProfile.current.phase.doneFall)
            }
        }
    }
    func sample(at time: Double, reduceMotion: Bool = false) -> BodyPhaseTransition.Pose {
        let t=max(0,time-began)
        guard !reduceMotion,t<duration else {return .init(sample:event.value.terminal(),velocity:.zero)}
        var pose=transition?.sample(at:t) ?? .init(sample:event.value.terminal(),velocity:.zero)
        if let emphasis {
            let glow=emphasis.sample(at:time-emphasisBegan)
            var velocity=pose.velocity;velocity[5]=glow.velocity[5]
            pose = .init(sample:.init(vector:pose.sample.vector,emphasis:glow.sample.emphasis),velocity:velocity)
        }
        guard event.value.state == .completed else {return pose}
        let p=BodyProfile.current.phase
        let u=min(1,max(0,t/duration)),u2=u*u,u3=u2*u
        let inherited=completionGlow*(2*u3-3*u2+1)+completionGlowVelocity*duration*(u3-2*u2+u)
        let gain=inherited+BodyPhaseTransition.pulse(at:t-flashStart,rise:Double(p.doneRise),fall:Double(p.doneFall))*Double(p.doneGain)
        var velocity=pose.velocity
        velocity[5]=completionGlow*(6*u2-6*u)/duration+completionGlowVelocity*(3*u2-4*u+1)
            +BodyPhaseTransition.pulseVelocity(at:t-flashStart,rise:Double(p.doneRise),fall:Double(p.doneFall))*Double(p.doneGain)
        return .init(sample:.init(vector:pose.sample.vector,emphasis:Float(gain)),velocity:velocity)
    }
    func finished(at time: Double) -> Bool { time >= began+duration }
}

/// Weak storage cannot retain conversations or a closed window.
@MainActor final class BodyPhasePlaybackRegistry {
    static let shared=BodyPhasePlaybackRegistry()
    private final class Entry { weak var value:BodyPhasePlayback?; init(_ value:BodyPhasePlayback){self.value=value} }
    private var entries:[String:Entry]=[:]
    func resolve(_ event:BodyPhaseEvent,at time:Double=CACurrentMediaTime())->BodyPhasePlayback {
        entries=entries.filter{$0.value.value != nil}
        let clock=entries[event.sourceID]?.value ?? BodyPhasePlayback(event,at:time)
        clock.update(event,at:time); entries[event.sourceID]=Entry(clock); return clock
    }
}
