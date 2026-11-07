#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

@MainActor enum DockGlassTopologyVerification {
    static func run(to output: URL, check: (Bool, String) -> Void) throws {
        try DockGlassCadenceVerification.run(to:output,check:check)
        try DockGlassBatchVerification.run(to:output,check:check)
        typealias Fixture = DockCapsuleVerification.Fixture
        var measurements: [[String: Any]] = []
        var exposureTrace: [[String: Any]] = []
        for exposure in [false, true] {
            for hz in [60.0, 120.0] {
                let f = Fixture(scale: 2, exposure: exposure)
                f.dock.motionProfile = .init(name: "fusion-\(hz)", frameInterval: 1/hz, mmPerPoint: 0.27, persistenceFrames: 0)
                let auto = f.auto(), owner = f.all[0].id
                var raw: [String: M10DockFrame] = [:]
                f.dock.onMotionFrame = { raw[$0.name] = $0 }
                func frames(_ capsuleOwner: String) -> [String: CGRect] {
                    var result = f.dock.items.filter { !$0.value.glass.isHidden }.mapValues { $0.glass.frame }
                    if !f.glass.isHidden { result["me"] = f.dock.mePaintedFrame }
                    if !f.glass.isHidden { result[capsuleOwner] = (result[capsuleOwner] ?? f.glass.frame).union(f.glass.frame) }
                    return result
                }
                func connections(_ values: [String: CGRect]) -> [String: Bool] {
                    let ids = values.keys.sorted(); var result: [String: Bool] = [:]
                    for i in 0..<(max(0,ids.count-1)) {
                        for j in (i+1)..<ids.count { result[ids[i]+"|"+ids[j]] = DockGlassTopology.gap(values[ids[i]]!,values[ids[j]]!) <= 10 }
                    }
                    return result
                }
                func logicalFrames() -> [String: CGRect] {
                    var values = f.dock.items.compactMapValues { $0.motion.rect }
                    values["me"] = f.dock.meLogicalFrame
                    if !f.glass.isHidden { values[owner] = (values[owner] ?? f.dock.capsuleLogicalFrame).union(f.dock.capsuleLogicalFrame) }
                    return values
                }
                func phase(_ name: String, duration: Double, commit: () -> Void, step: (Double) -> Void) {
                    var previous = connections(frames(owner)), flips: [String: Int] = [:]
                    var maxInset: CGFloat = 0
                    commit()
                    let count = max(1,Int(ceil(duration*hz)))
                    for k in 0...count {
                        step(duration*Double(k)/Double(count))
                        let current = connections(frames(owner))
                        let logical = logicalFrames(), painted = frames(owner)
                        for (id,r) in logical where id == "me" || id == owner || id == f.all[2].id {
                            let itemMotion = [raw["dock.orb."+id],raw["dock.bar."+id]].compactMap { $0 }.max { $0.time < $1.time }
                            let motion = raw["dock.capsule"].flatMap { id == owner && !f.glass.isHidden ? $0 : nil }
                                ?? raw["dock.me"].flatMap { id == "me" ? $0 : nil }
                                ?? itemMotion
                            if let motion, let applied = painted[id] {
                                func edges(_ value: CGRect) -> [CGFloat] { [value.minX,value.maxX,value.minY,value.maxY] }
                                exposureTrace.append(["phase":name,"exposure":exposure,"hz":hz,"time":duration*Double(k)/Double(count),"id":id,
                                    "logical":edges(r),"raw":edges(motion.painted),"applied":edges(applied),"earlier":edges(motion.earlier),
                                    "gate":motion.exposure.gate,"length":motion.exposure.length,"stepMM":motion.stepMM])
                            }
                        }
                        for (id,value) in current {
                            if let old=previous[id], old != value {
                                flips[id,default:0] += 1
                                let ids=id.split(separator:"|").map(String.init)
                                if let a=logical[ids[0]],let b=logical[ids[1]] {
                                    let gap=DockGlassTopology.gap(a,b)
                                    check(value ? gap <= 10:gap > 10,"fusion \(name) changes only after a logical crossing, gap=\(gap)")
                                }
                            }
                        }
                        for (id,r) in logical {
                            if let p=painted[id] { maxInset=max(maxInset,p.minX-r.minX,r.maxX-p.maxX,p.minY-r.minY,r.maxY-p.maxY) }
                        }
                        previous = current
                    }
                    let maximum = flips.values.max() ?? 0
                    check(maximum <= 1,"fusion \(name) exposure=\(exposure) \(hz)Hz changes each pair at most once: \(flips)")
                    measurements.append(["phase":name,"exposure":exposure,"hz":hz,"maxFlips":maximum,"flips":flips,"maxLogicalInset":maxInset])
                }
                phase("enter",duration:1,commit:{f.transition(f.focused(owner))},step:{f.sample($0)})
                phase("exit",duration:1.2,commit:{f.transition(auto)},step:{f.sample($0)})
                phase("enter-150ms",duration:0.15,commit:{f.transition(f.focused(owner))},step:{f.sample($0)})
                phase("reverse",duration:1.2,commit:{f.transition(auto)},step:{f.sample($0)})
                phase("enter-again",duration:1,commit:{f.transition(f.focused(owner))},step:{f.sample($0)})
                phase("exit-150ms",duration:0.15,commit:{f.transition(auto)},step:{f.sample($0)})
                phase("reverse-outgoing",duration:1,commit:{f.transition(f.focused(owner))},step:{f.sample($0)})
                phase("exit-again",duration:1.2,commit:{f.transition(auto)},step:{f.sample($0)})
                f.dock.still = false
                let orb = f.dock.items[f.all[4].id]!.glass.frame
                phase("hover",duration:0.8,commit:{_ = f.dock.pointer(CGPoint(x:orb.midX,y:orb.midY),now:f.now); f.began=f.now},step:{f.sample($0)})
                let id = f.all[1].id, source = f.dock.items[id]!.glass.frame
                f.dock.hold(id,at:CGPoint(x:source.midX,y:source.midY),now:f.now,spring:(0.30,0.80))
                var start = f.now
                phase("drag-in",duration:0.8,commit:{},step:{t in
                    f.now=start+t;f.dock.moveHeld(to:CGPoint(x:source.midX-180*CGFloat(t/0.8),y:source.midY))
                    f.dock.hoverFrame(at:f.now);f.dock.sample(f.now-f.began);f.dock.heldFrame(at:f.now)
                })
                start=f.now
                phase("drag-out",duration:0.8,commit:{},step:{t in
                    f.now=start+t;f.dock.moveHeld(to:CGPoint(x:source.midX-180+250*CGFloat(t/0.8),y:source.midY))
                    f.dock.hoverFrame(at:f.now);f.dock.sample(f.now-f.began);f.dock.heldFrame(at:f.now)
                })
                f.dock.release(forTear:true)
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fusion.json"))

        // A connected destination must not pulse when a reversal rebounds around the fusion threshold.
        try JSONSerialization.data(withJSONObject:exposureTrace,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("exposure-trace.json"))
        let pair = DockGlassTopology()
        let fixed = CGRect(x: 100, y: 0, width: 300, height: 48)
        func pairFrame(_ gap: CGFloat, at time: Double) -> Bool {
            let me = CGRect(x: 100-gap-40, y: 0, width: 40, height: 48)
            let shapes: [DockGlassTopology.Shape] = [
                .init(id: "me", logical: me, target: CGRect(x: 100,y: 0,width: 40,height: 48), painted: me),
                .init(id: "A", logical: fixed, target: fixed, painted: fixed)]
            let r = pair.resolve(shapes, spacing: 10, monotonic: true, at: time)
            return DockGlassTopology.gap(r["me"]!,r["A"]!) <= 10
        }
        var joined = pairFrame(12, at: 0), pairFlips = 0
        pair.begin(at: 0)
        for (i,gap) in [CGFloat(9.4),10.6,9.4,10.7,8,0].enumerated() {
            let next = pairFrame(gap,at:Double(i+1)/120)
            if next != joined { pairFlips += 1 }; joined = next
        }
        check(pairFlips == 1 && joined,"me/capsule rebound changes fusion exactly once, got \(pairFlips)")

        // The live path has no injected clock: every Dock channel must use the display target timestamp.
        let clockStore = ConversationStore(conversations:Array(MockSeed.make().prefix(6)),projects:MockSeed.projects,devices:MockSeed.devices)
        let clockScene = AutoScene(size:CGSize(width:1280,height:820),store:clockStore,profile:M10DockMotion.dell,scale:2)
        clockScene.manualSettle = true;clockScene.ambient = false;clockScene.install()
        let displayTarget = CACurrentMediaTime()+0.02
        var observedTimes: [Double] = []
        clockScene.dock.onMotionFrame = { observedTimes.append($0.time) }
        clockScene.frame(displayTarget)
        check(!observedTimes.isEmpty && observedTimes.allSatisfy { $0 == displayTarget },"live Dock channels share the display timestamp")

        // The unchanged physical gate can close for one short callback even at constant velocity.
        var gateTrace: [[String:Any]] = []
        for hz in [60.0,120.0] {
            let history = M10DockHistory(), profile = DisplayProfile(name:"gate-\(hz)",frameInterval:1/hz,mmPerPoint:0.27,persistenceFrames:0)
            var time = 0.0
            _ = history.update(CGRect(x:0,y:0,width:160,height:48),at:0,name:"gate",profile:profile,enabled:true)
            for dt in [1/hz,0.005,1/hz] {
                time += dt
                let frame = history.update(CGRect(x:time*600,y:0,width:160,height:48),at:time,name:"gate",profile:profile,enabled:true)
                gateTrace.append(["hz":hz,"dt":dt,"gate":frame.exposure.gate,"stepMM":frame.stepMM])
            }
        }
        try JSONSerialization.data(withJSONObject:gateTrace,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("gate-trace.json"))

        var reversals: [[String: Any]] = []
        for exposure in [false,true] {
            for delay in [0.033,0.058] {
                let r = Fixture(scale:2,exposure:exposure), owner = r.all[0].id
                let initial = r.dock.items[owner]!.glass.frame
                let entry = r.focused(owner), target = entry.0.bars[0]
                r.transition(entry);r.walk(0.15)
                let shown = r.dock.capsuleLogicalFrame, paint = r.dock.focusedGlassFrame
                let expected = RectSpring(dockFrom:initial,to:target,response:0.40,damping:0.82).sample(r.now-r.began)
                r.now += delay
                r.transition(r.auto())
                check(MotionStep.edge(r.dock.capsuleLogicalFrame,shown)<0.001,"delayed reversal \(delay) exposure=\(exposure) starts at displayed logical pose")
                check(MotionStep.edge(r.dock.focusedGlassFrame,paint)<0.001,"delayed reversal preserves painted commit frame before=\(paint) after=\(r.dock.focusedGlassFrame)")
                let back = RectSpring(dockFrom:expected.rect,to:initial,velocity:expected.velocity,response:0.40,damping:0.82)
                var prior = paint
                for step in 1...36 {
                    let elapsed = Double(step)/120;r.sample(elapsed)
                    let logical = r.dock.capsuleLogicalFrame, nowPaint = r.dock.focusedGlassFrame
                    check(MotionStep.edge(logical,back.sample(r.now-r.began).rect)<0.001,"delayed reversal continues displayed velocity \(step)")
                    if MotionStep.edge(logical,shown)>1 && step <= 3 {
                        check(MotionStep.edge(nowPaint,prior)>0.001,"advancing display frame is not frozen after reversal \(step)")
                    }
                    reversals.append(["exposure":exposure,"delay":delay,"step":step,"logical":[logical.minX,logical.maxX],"painted":[nowPaint.minX,nowPaint.maxX]])
                    prior = nowPaint
                }
            }
        }
        try JSONSerialization.data(withJSONObject:reversals,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("reversal.json"))

        let f = Fixture(scale:2,exposure:false), auto = f.auto(), owner = f.all[0].id
        let source = f.dock.items[owner]!.glass.frame, next = f.focused(owner)
        var springs = f.dock.springs(to:next.0,order:next.1,at:0,spring:(0.40,0.82))
        f.dock.transition(to:next.0,order:next.1,full:[owner],springs:springs,duration:0.8)
        // Deliberately no sample, hoverFrame, or fixture transition helper between these commits.
        springs = f.dock.springs(to:auto.0,order:auto.1,at:0,spring:(0.40,0.82))
        f.dock.transition(to:auto.0,order:auto.1,full:[owner],springs:springs,duration:0.8)
        f.began=f.now
        for step in 0...120 {
            f.sample(Double(step)/120)
            check(MotionStep.edge(f.dock.capsuleLogicalFrame,source)<0.001,"unsampled double commit returns to owner frame \(step)")
        }
        let h=Fixture(scale:2,exposure:false);h.dock.still=false
        let orbID=h.all[4].id, orb=h.dock.items[orbID]!.glass.frame
        _=h.dock.pointer(CGPoint(x:orb.midX,y:orb.midY),now:h.now);h.walk(0.8)
        let displayed=h.dock.items[orbID]!.glass.frame
        let logicalDisplayed=h.dock.items[orbID]!.motion.rect!
        h.transition(h.focused(orbID))
        check(MotionStep.edge(h.dock.capsuleLogicalFrame,logicalDisplayed)<0.001,"magnified orb entry inherits the last written logical pose")
        check(MotionStep.edge(h.dock.focusedGlassFrame,displayed)<0.001,"magnified orb carrier preserves the final native contour before=\(displayed) after=\(h.dock.focusedGlassFrame)")
        h.walk(1);h.transition(h.auto());h.walk(0.3)
        let before=h.dock.capsuleLogicalFrame,alpha=h.dock.focusedGlassOpacity
        h.now -= 5000;h.dock.sample(0.3)
        check(MotionStep.edge(h.dock.capsuleLogicalFrame,before)<0.001 && h.dock.focusedGlassOpacity==alpha,"capsule clock rewind preserves elapsed pose and opacity")

        // This trace is compared with the previous version, independent of glass rasterization.
        let words=Fixture(scale:2,exposure:true);var trace:[[String:Any]]=[];var leg=""
        words.dock.onMotionFrame={frame in
            guard frame.name=="dock.words."+words.all[1].id else{return}
            trace.append(["leg":leg,"time":frame.time-words.began,"rect":[frame.rect.minX,frame.rect.minY,frame.rect.width,frame.rect.height],
                          "earlier":[frame.earlier.minX,frame.earlier.minY,frame.earlier.width,frame.earlier.height],"copies":frame.exposure.count])
        }
        words.now=1000;words.began=1000;words.dock.install(words.layout,metrics:words.metrics,order:words.all,full:[words.all[0].id],store:words.store)
        leg="enter";words.transition(words.focused(words.all[0].id));words.walk(1)
        leg="exit";words.transition(words.auto());words.walk(1)
        try JSONSerialization.data(withJSONObject:trace,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("word-trace.json"))
    }
}
#endif
