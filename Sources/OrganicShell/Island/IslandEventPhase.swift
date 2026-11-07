import Foundation

/// NativeHeaderIslandTextPhase eventIn/eventOut, continued from the sampled presentation on reversal.
struct IslandEventPhase {
    struct Pose { var opacity:CGFloat=0,offsetY:CGFloat=0,blur:CGFloat=0 }
    private(set) var pose=Pose()
    private var from=Pose(),target=Pose(),start=0.0,delay=0.0,duration=0.0
    private(set) var busy=false
    mutating func reset(visible:Bool) {pose=Pose(opacity:visible ? 1:0);from=pose;target=pose;busy=false}
    mutating func retarget(visible:Bool,at now:Double,reduced:Bool) {
        sample(now)
        if visible && pose.opacity == 0 {pose=Pose(opacity:0,offsetY:reduced ? 0:4,blur:reduced ? 0:2)}
        if reduced {pose.offsetY=0;pose.blur=0}
        from=pose;target=Pose(opacity:visible ? 1:0);start=now
        delay=visible && !reduced ? 0.08:0
        duration=reduced ? 0.12:(visible ? 0.09:0.06)
        busy=from.opacity != target.opacity || from.offsetY != target.offsetY || from.blur != target.blur
    }
    mutating func sample(_ now:Double) {
        guard busy else{return}
        let t=min(1,max(0,(now-start-delay)/duration))
        var lo=0.0,hi=1.0
        for _ in 0..<24 {let u=(lo+hi)/2,x=3*0.58*(1-u)*u*u+u*u*u;if x<t{lo=u}else{hi=u}}
        let u=(lo+hi)/2,k:CGFloat=t<=0 ? 0:t>=1 ? 1:CGFloat(3*(1-u)*u*u+u*u*u)
        pose=Pose(opacity:from.opacity+(target.opacity-from.opacity)*k,
                  offsetY:from.offsetY+(target.offsetY-from.offsetY)*k,blur:from.blur+(target.blur-from.blur)*k)
        if now>=start+delay+duration {pose=target;busy=false}
    }
}
