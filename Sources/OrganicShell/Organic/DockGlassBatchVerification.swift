#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Independent checks of native view outputs, not the resolver's cached connection predicate.
@MainActor enum DockGlassBatchVerification {
    static func run(to output: URL, check: (Bool,String)->Void) throws {
        try DockReviewVerification.run(to:output,check:check)
        var rows:[[String:Any]]=[]
        var caseIndex=0
        let scale=CGFloat(Double(ProcessInfo.processInfo.environment["DOCK_CHECK_SCALE"] ?? "2") ?? 2)
        for mm in [0.27,0.128,0.19921568328259037] {
            for hz in [60.0,120.0] {
                for pattern in 0...2 {
                    for skew in [0.0,0.008,0.024,0.048] {
                        let f=DockCapsuleVerification.Fixture(scale:scale,exposure:true)
                        f.dock.motionProfile = .init(name:"batch",frameInterval:1/hz,mmPerPoint:mm,persistenceFrames:0)
                        let zero=f.now, owner=f.all[0].id
                        var time=0.0, step=0, phase=0, epoch=zero
                        var previous:[String:Bool]=[:], flips:[String:Int]=[:], maximum=0
                        var residual:CGFloat=0, physicalResidual:CGFloat=0, minAB=CGFloat.infinity, sources=0
                        f.dock.frame(at:zero,elapsed:0)
                        let events=[2.0,4.0,6.0,6.15,8.0,10.0]
                        while time < 11.5 {
                            time += pattern == 0 ? 1/hz : (step%5 == 2 ? Double(pattern == 1 ? 3:5)/hz:1/hz)
                            step += 1
                            while phase < events.count && time >= events[phase] {
                                let event=zero+events[phase]
                                f.now=event
                                let next=(phase==0 || phase==2 || phase==4) ? f.focused(owner):f.auto()
                                let springs=f.dock.springs(to:next.0,order:next.1,at:event-epoch,spring:(0.4,0.82))
                                f.dock.transitionEpoch=f.dock.makeTransitionEpoch(at:event)
                                f.now=event+skew
                                f.dock.transition(to:next.0,order:next.1,full:[owner],springs:springs,duration:springs.values.map(\.duration).max() ?? 0)
                                f.layout=next.0;f.order=next.1;f.began=event;epoch=event
                                phase += 1;flips=[:]
                            }
                            if phase>0 && zero+time<epoch+skew {continue}
                            f.now=zero+time
                            f.dock.frame(at:f.now,elapsed:f.now-epoch)
                            let parts=f.dock.physicalGlassSnapshot
                            residual=max(residual,f.dock.topologyFinalResidual)
                            var current:[String:Bool]=[:]
                            for i in parts.indices { for j in parts.indices where j>i {
                                let a=parts[i],b=parts[j]
                                let gap=DockGlassTopology.gap(a.frame,b.frame)
                                if a.group != b.group, let joined=f.dock.topologyConnected(a.group,b.group) {
                                    let vertical=min(a.logical.maxY,b.logical.maxY)-max(a.logical.minY,b.logical.minY)
                                    if vertical > min(a.logical.height,b.logical.height)*0.25 {
                                        let signed=max(a.frame.minX-b.frame.maxX,b.frame.minX-a.frame.maxX)
                                        physicalResidual=max(physicalResidual,joined ? max(0,signed+1):max(0,12-gap))
                                    }
                                }
                                for threshold:CGFloat in [0,2.5,4,8,10] {
                                    let key=a.id+"|"+b.id+"@"+String(Double(threshold))
                                    let joined=gap<=threshold
                                    current[key]=joined
                                    if let old=previous[key],old != joined {flips[key,default:0] += 1}
                                    maximum=max(maximum,flips[key] ?? 0)
                                }
                                if a.group==owner && b.group==f.all[1].id || b.group==owner && a.group==f.all[1].id {
                                    minAB=min(minAB,gap)
                                }
                                sources += 1
                            } }
                            previous=current
                        }
                        check(maximum<=1,"physical batch case=\(caseIndex) max repeated contour crossings=\(maximum)")
                        if DockGlassTopology.safeMarginEnabled {
                            check(minAB>=12-0.0001,"physical batch case=\(caseIndex) A/B final gap=\(minAB)")
                            check(physicalResidual<0.0001,"physical batch case=\(caseIndex) physical residual=\(physicalResidual)")
                            check(residual<0.0001,"physical batch case=\(caseIndex) whole-frame residual=\(residual)")
                        }
                        rows.append(["case":caseIndex,"mm":mm,"hz":hz,"pattern":pattern,"skew":skew,
                            "scale":scale,"nativeBackingVerified":false,"maxFlips":maximum,"minAB":minAB,"maxResidual":residual,"physicalResidual":physicalResidual,"physicalPairs":sources])
                        caseIndex += 1
                    }
                }
            }
        }
        // These callbacks preserve measured display cadence, including short/repeated predictions.
        // Read-only input is opt-in so the ordinary gate never depends on external recordings.
        if let path=ProcessInfo.processInfo.environment["DOCK_REPLAY_LOG"] {
            rows.append(try replay(path:path,scale:scale,check:check))
        }

        check(NSApp.windows.allSatisfy{!$0.isVisible},"physical glass checks open no visible windows")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("physical-glass.json"))
    }
    /// No WindowServer backing is created by these detached fixtures.
    static func replay(path: String, scale: CGFloat, check: (Bool,String)->Void) throws -> [String:Any] {
            let lines=try String(contentsOfFile:path,encoding:.utf8).split(separator:"\n")
            let records=try lines.map {try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
            let f=DockCapsuleVerification.Fixture(scale:scale,exposure:true)
            f.dock.motionProfile = .init(name:"recorded",frameInterval:1/120,mmPerPoint:0.19921568328259037,persistenceFrames:0)
            var observedTransitions=Set<Int>()
            var serial=0,epoch=f.now,previous:[String:Bool]=[:],flips:[String:Int]=[:],maxFlips=0,frames=0
            for row in records {
                guard let target=row["targetTimestamp"] as? Double,let nextSerial=row["transitionSerial"] as? Int,nextSerial<=6 else {continue}
                guard target.isFinite,nextSerial>=0 else {continue}
                let elapsed=row["elapsed"] as? Double ?? 0
                if nextSerial > 0 {observedTransitions.insert(nextSerial)}
                if nextSerial != serial {
                    let began=target-elapsed
                    f.now=began
                    let next=(row["toFocused"] as? Bool ?? false) ? f.focused(f.all[0].id):f.auto()
                    let springs=f.dock.springs(to:next.0,order:next.1,at:began-epoch,spring:(0.4,0.82))
                    f.dock.transitionEpoch=f.dock.makeTransitionEpoch(at:began)
                    f.dock.transition(to:next.0,order:next.1,full:[f.all[0].id],springs:springs,duration:springs.values.map(\.duration).max() ?? 0)
                    f.layout=next.0;f.order=next.1;serial=nextSerial;epoch=began;flips=[:]
                }
                f.now=target;f.dock.frame(at:target,elapsed:elapsed)
                let parts=f.dock.physicalGlassSnapshot
                var current:[String:Bool]=[:]
                for i in parts.indices {for j in parts.indices where j>i {
                    let key=parts[i].id+"|"+parts[j].id
                    let joined=DockGlassTopology.gap(parts[i].frame,parts[j].frame)<=2.5
                    current[key]=joined
                    if let old=previous[key],old != joined {flips[key,default:0] += 1}
                    maxFlips=max(maxFlips,flips[key] ?? 0)
                }}
                previous=current;frames += 1
            }
            check(frames>0,"recorded replay requires valid callbacks; got \(frames)")
            check(observedTransitions == Set(1...6),"recorded replay requires all six transitions; got \(observedTransitions.sorted())")
            check(maxFlips<=1,"recorded full-frame replay \(frames) callbacks max contour crossings=\(maxFlips)")
            return ["recordedCallbacks":frames,"maxFlips":maxFlips,"transitions":observedTransitions.sorted()]
    }

}
#endif
