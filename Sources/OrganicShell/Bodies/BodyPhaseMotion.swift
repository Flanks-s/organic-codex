import Foundation
import simd

/// Explicit finite event envelope. Sampling is pure and never requests another frame.
struct BodyPhaseTransition: Sendable {
    struct Pose: Sendable { let sample: BodyPhaseSample; let velocity: SIMD8<Double> }
    let start: SIMD8<Double>, velocity: SIMD8<Double>, target: BodyPhaseSample
    let state: BodyPhaseState
    let duration: Double, response: Double, flashRise: Double, flashFall: Double, flashGain: Float, floor: Double
    init(from: Pose, to value: BodyPhaseValue, profile: BodyProfile = .current) {
        start=from.sample.vector
        var initialVelocity=from.velocity
        for i in 0..<8 where !initialVelocity[i].isFinite {initialVelocity[i]=0}
        velocity=initialVelocity; target=value.terminal(profile:profile); state=value.state
        let p=profile.phase
        response=Double(p.fractionResponse); flashRise=Double(p.doneRise); flashFall=Double(p.doneFall); flashGain=p.doneGain; floor=Double(p.floor)
        switch value.state {
        case .running, .completed: duration=Double(p.fractionResponse)*3
        case .unknown: duration=Double(p.hazeFade)
        case .waiting: duration=Double(p.waitFade)
        case .failed: duration=Double(p.failSweep)
        case .cancelled: duration=Double(p.cancelFade)
        }
    }
    var endTime: Double { duration + (state == .completed ? flashRise+flashFall : 0) }
    func sample(at time: Double, reduceMotion: Bool = false) -> Pose {
        let t=time.isFinite ? max(0,time) : (time == .infinity ? endTime : 0)
        if reduceMotion || t >= endTime { return Pose(sample:target,velocity:.zero) }
        if t >= duration {
            let pulse=Self.pulse(at:t-duration,rise:flashRise,fall:flashFall)
            var speed=SIMD8<Double>.zero
            speed[5]=Double(flashGain)*Self.pulseVelocity(at:t-duration,rise:flashRise,fall:flashFall)
            return Pose(sample:.init(vector:target.vector,emphasis:flashGain*Float(pulse)),velocity:speed)
        }
        let u=t/duration, u2=u*u, u3=u2*u, goal=target.vector
        // Other state entries use the board's finite smoothstep, extended by the incoming velocity.
        var x=start*(2*u3-3*u2+1)+velocity*(duration*(u3-2*u2+u))+goal*(-2*u3+3*u2)
        var v=start*((6*u2-6*u)/duration)+velocity*(3*u2-4*u+1)+goal*((-6*u2+6*u)/duration)
        if state == .running || state == .completed {
            // Preserve the authored critical response for two responses, then taper its tiny residual
            // to exactly zero over one response. Both position and velocity have a finite C1 tail.
            let w=2*Double.pi/response,delta=start[0]-goal[0],b=velocity[0]+delta*w,e=exp(-w*t)
            let tail=min(1,max(0,(t-2*response)/response)),g=1-tail*tail*(3-2*tail)
            let dg=tail>0 && tail<1 ? -6*tail*(1-tail)/response : 0
            x[0]=goal[0]+(delta+b*t)*e*g
            v[0]=(b-(delta+b*t)*w)*e*g+(delta+b*t)*e*dg
            // A closer target can require braking: arbitrary incoming velocity otherwise makes
            // even a critically damped response cross its target. Stop within that distance, C1.
            if delta*velocity[0]<0,abs(velocity[0])>w*abs(delta) {
                let stop=2*abs(delta/velocity[0])
                if t<stop {
                    x[0]=start[0]+velocity[0]*t*(1-t/(2*stop));v[0]=velocity[0]*(1-t/stop)
                } else {x[0]=goal[0];v[0]=0}
            }
        }
        for i in 0..<6 {
            let lower=i==0 ? floor:0
            if x[i]<lower {x[i]=lower;v[i]=0}
            if x[i]>1 {x[i]=1;v[i]=0}
        }
        return Pose(sample:.init(vector:x,minimum:Float(floor)),velocity:v)
    }
    static func pulse(at t: Double, rise: Double, fall: Double) -> Double {
        func smooth(_ x: Double)->Double {let u=min(1,max(0,x));return u*u*(3-2*u)}
        guard t>0,t<rise+fall else{return 0}
        return t<rise ? smooth(t/rise) : 1-smooth((t-rise)/fall)
    }
    static func pulseVelocity(at t: Double, rise: Double, fall: Double) -> Double {
        guard t>0,t<rise+fall else{return 0}
        let u=t<rise ? t/rise:(t-rise)/fall
        return 6*u*(1-u)*(t<rise ? 1/rise:-1/fall)
    }
    static func unknownEvent(at t: Double, amplitude: Float, duration: Double, profile: BodyProfile = .current) -> BodyPhaseSample {
        BodyPhaseEmphasis(amplitude:amplitude,duration:duration,profile:profile).sample(at:t).sample
    }
}

/// One unknown-progress event. A replacement envelope accepts the previous value and derivative.
struct BodyPhaseEmphasis: Sendable {
    let base: BodyPhaseSample
    let amplitude, initial, velocity, duration: Double
    init(from: BodyPhaseTransition.Pose? = nil, amplitude: Float, duration: Double, profile: BodyProfile = .current) {
        base=BodyPhaseValue(.unknown).terminal(profile:profile)
        self.amplitude=amplitude.isFinite ? Double(min(1,max(0,amplitude))) : 0
        initial=Double(from?.sample.emphasis ?? 0)
        let speed=from?.velocity[5] ?? 0
        velocity=speed.isFinite ? speed:0
        self.duration=duration.isFinite ? max(0,duration):0
    }
    func sample(at time: Double, reduceMotion: Bool = false) -> BodyPhaseTransition.Pose {
        let t=time.isFinite ? max(0,time) : (time == .infinity ? duration:0)
        guard !reduceMotion,duration>0,t<duration else{return .init(sample:base,velocity:.zero)}
        let rise=duration*0.3,first=t<rise,T=first ? rise:duration-rise,u=(first ? t:t-rise)/T,u2=u*u,u3=u2*u
        let a=first ? initial:amplitude,b=first ? amplitude:0,v=first ? velocity:0
        let value=a*(2*u3-3*u2+1)+v*T*(u3-2*u2+u)+b*(-2*u3+3*u2)
        var speed=SIMD8<Double>.zero
        speed[5]=(a*(6*u2-6*u)+b*(-6*u2+6*u))/T+v*(3*u2-4*u+1)
        if value<0 || value>1 {speed[5]=0}
        return .init(sample:.init(vector:base.vector,emphasis:Float(value)),velocity:speed)
    }
}
