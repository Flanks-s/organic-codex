#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore
@MainActor enum DockGlassCadenceVerification {
    static func run(to output: URL, check: (Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for delay in [0.0,0.008,0.016,0.024,0.032] {
            for hz in [60.0,80.0,120.0] {
                for pattern in [0,1,2] {
                    let f=DockCapsuleVerification.Fixture(scale:2,exposure:true)
                    f.dock.motionProfile=DisplayProfile(name:"cadence",frameInterval:1/hz,mmPerPoint:0.27,persistenceFrames:0)
                    let owner=f.all[0].id, neighbour=f.all[1].id
                    f.transition(f.focused(owner));f.walk(1.2)
                    let auto=f.auto(), start=f.now
                    let springs=f.dock.springs(to:auto.0,order:auto.1,at:f.now-f.began,spring:(0.40,0.82))
                    f.now += delay
                    f.dock.transition(to:auto.0,order:auto.1,full:[owner],springs:springs,duration:springs.values.map(\.duration).max() ?? 0)
                    f.layout=auto.0;f.order=auto.1;f.began=start
                    var time=delay, previous=false, flips=0
                    for k in 0..<Int(hz*1.2) {
                        let gap=pattern == 0 ? 1/hz : (k%5 == 2 ? (pattern == 1 ? 3/hz:5/hz):1/hz)
                        time += gap;f.sample(time)
                        var a=f.dock.items[owner]!.glass.frame
                        if !f.glass.isHidden {a=a.union(f.glass.frame)}
                        let b=f.dock.items[neighbour]!.glass.frame
                        let connected=DockGlassTopology.gap(a,b)<=10
                        if previous != connected {flips += 1};previous=connected
                        rows.append(["delay":delay,"hz":hz,"pattern":pattern,"time":time,"gap":DockGlassTopology.gap(a,b),"connected":connected])
                    }
                    check(flips<=1,"cadence exit delay=\(delay) hz=\(hz) pattern=\(pattern) flips=\(flips)")
                }
            }
        }
        // A revised display prediction is not a new media-clock epoch.
        let live=DockCapsuleVerification.Fixture(scale:2,exposure:true)
        live.now=QuartzCore.CACurrentMediaTime()
        let focused=live.focused(live.all[0].id)
        live.dock.install(focused.0,metrics:live.metrics,order:focused.1.compactMap{live.store.conversation($0)},full:[live.all[0].id],store:live.store)
        live.dock.motionTime=nil
        let auto=live.auto(), springs=live.dock.springs(to:auto.0,order:auto.1,at:.infinity,spring:(0.40,0.82))
        live.dock.transition(to:auto.0,order:auto.1,full:[live.all[0].id],springs:springs,duration:springs.values.map(\.duration).max() ?? 0)
        let epoch=live.dock.capsuleEpochStart
        for offset in [0.08,0.076,0.084,0.084,0.12] {
            live.dock.frame(at:epoch+offset,elapsed:offset)
        }
        check(live.dock.capsuleEpochStart==epoch,"display prediction rollback does not shift the capsule epoch")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("cadence.json"))
    }
}
#endif
