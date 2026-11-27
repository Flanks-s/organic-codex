#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Production value models and detached native views; no WindowServer material verdict is fabricated.
@MainActor enum DockTideVerification {
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        if ProcessInfo.processInfo.environment["TIDE_NATIVE_ONLY"] != "1" {
            leases(check:check)
            try contours(to:output,check:check)
        }
        try native(to:output,check:check)
    }

    static func leases(check:(Bool,String)->Void) {
        typealias L=DockSlotLeases
        let candidates:[L.Candidate]=[.init(id:"C",role:.brief),.init(id:"B",role:.brief),.init(id:"A",role:.full)]
        var model=L()
        let first=model.request(owner:"window",purpose:.tide,count:1,candidates:candidates,at:0)
        check(first.status == .granted && first.lease?.briefs == ["C"],"Tide lease takes the contiguous rightmost brief")
        let token=first.lease!.token
        check(model.request(owner:"window",purpose:.tide,count:1,candidates:candidates,at:0.1).lease?.token == token,"identical request retains its generation")
        check(model.request(owner:"add",purpose:.add,count:2,candidates:candidates,at:0.15).status == .full && model.owns(token),"Add requires an explicit successful capacity verdict")
        let denied=model.request(owner:"add",purpose:.add,count:2,candidates:candidates,capacityAllows:false,at:0.2)
        check(denied.status == .full && denied.reasons.contains(.capacity) && model.owns(token),"failed Add capacity never steals Tide")
        let add=model.request(owner:"add",purpose:.add,count:2,candidates:candidates,capacityAllows:true,at:0.3)
        check(add.status == .granted && add.revoked == token && model.tide == nil,"successful Add preallocation invalidates Tide immediately")
        let addToken=add.lease!.token
        check(!model.release(token) && model.owns(addToken),"old Tide callback cannot restore Add's space")
        check(model.commitAdd(addToken),"matching Add generation commits")
        check(!model.release(addToken) && model.add?.committed == true,"Esc-style release cannot undo committed Add capacity")
        check(model.updateAddCapacity(requiredBriefs:1) && model.add?.briefs == ["C"],"falling capacity restores only the no-longer-needed brief")
        check(!model.owns(addToken),"capacity update retires the previous Add generation")
        check(model.updateAddCapacity(requiredBriefs:0) && model.add == nil,"orb-count reduction releases the remaining capacity")
        for reason in L.Reason.allCases where ![.fullColumn,.grace,.occupied,.capacity,.insufficientSpace,.staleGeneration].contains(reason) {
            var held=candidates;held[0].protection=[reason]
            let result=model.request(owner:"window",purpose:.tide,count:2,candidates:held,at:1)
            check(result.status == .full && result.lease == nil && result.reasons.contains(reason),"protected C blocks borrowing B: \(reason.rawValue)")
            check(result.allowsRefusalKnock == (reason != .markedText),"refusal knock respects marked-text ownership: \(reason.rawValue)")
        }
        var partial=candidates;partial[1].protection=[.draft]
        let reduced=model.request(owner:"window",purpose:.tide,count:2,candidates:partial,at:2)
        check(reduced.status == .reduced && reduced.lease?.briefs == ["C"],"blocked B reduces two requested briefs to one")
        model.updateProtection([.focus],for:"C",at:3)
        check(model.tide == nil && !model.release(reduced.lease!.token),"user reclaim invalidates existing and delayed Tide ownership")
        model.updateProtection([],for:"C",at:4)
        check(model.request(owner:"window",purpose:.tide,count:1,candidates:candidates,at:4.899).reasons.contains(.grace),"protection release retains the full 0.9 second grace")
        check(model.request(owner:"window",purpose:.tide,count:1,candidates:candidates,at:4.9).status == .granted,"brief becomes eligible at the grace deadline")
        let current=model.tide!.token
        var blocked=candidates;blocked[0].protection=[.draft]
        _=model.request(owner:"window",purpose:.tide,count:1,candidates:blocked,at:5)
        check(!model.owns(current),"request-time protection also invalidates an old lease")
        check(model.request(owner:"window",purpose:.tide,count:1,candidates:[.init(id:"A",role:.full)],at:6).reasons.contains(.fullColumn),"full columns are never borrowed")
        model.retire();check(model.tide == nil,"retirement revokes temporary Tide")
        let capacity=model.request(owner:"add",purpose:.add,count:1,candidates:candidates,capacityAllows:true,at:10).lease!
        _=model.commitAdd(capacity.token)
        let extra=model.request(owner:"window",purpose:.tide,count:1,candidates:[candidates[1],candidates[2]],at:11).lease!
        check(extra.briefs == ["B"],"committed Add capacity does not block a separate free brief")
        let enlarged=model.request(owner:"add",purpose:.add,count:2,candidates:candidates,capacityAllows:true,at:12)
        check(enlarged.lease?.briefs == ["C","B"] && enlarged.revoked == extra.token,"next Add preallocation extends capacity and preempts the new Tide")
        check(model.release(enlarged.lease!.token) && model.add?.briefs == ["C"] && model.add?.committed == true,"cancelled capacity extension preserves the prior committed Add")
        check(!model.commitAdd(enlarged.lease!.token),"late Add acknowledgement cannot commit a retired reservation")
        _=model.updateAddCapacity(requiredBriefs:0)
        let older=model.request(owner:"window",purpose:.tide,count:1,candidates:candidates,at:13).lease!.token
        model.retire()
        let newer=model.request(owner:"window",purpose:.tide,count:2,candidates:candidates,at:14).lease!.token
        check(!model.release(older) && model.owns(newer),"stale callback cannot release a later Tide generation of the same owner")
        var empty=L()
        let noBorrow=empty.request(owner:"add",purpose:.add,count:0,candidates:candidates,capacityAllows:true,at:0).lease!.token
        check(empty.commitAdd(noBorrow) && empty.add == nil,"Add that needs no brief leaves no phantom capacity lease")
        check(empty.request(owner:"add",purpose:.add,count:2,candidates:[candidates[0],candidates[0]],capacityAllows:true,at:1).status == .full,"duplicate candidate IDs cannot allocate the same physical slot twice")
    }

    static func contours(to output:URL,check:(Bool,String)->Void) throws {
        var worstGap=CGFloat.infinity,worstOverlap=CGFloat.infinity,maxParts=0,samples=0
        for lean in [10.0,26,54,70] {for velocity in [-500.0,0,500] {for i in 0...56 {
            let k=Double(i)/50
            let c=TideContour(body:CGRect(x:653,y:746,width:36,height:36),tailAmount:k,lean:lean,horizontalVelocity:velocity)
            let obstacles=c.parts.map(\.rect)
            let proposed=CGRect(x:701,y:740,width:461,height:48)
            let admitted=TideContour.admit(proposed,obstacles:obstacles)
            check(admitted != nil,"tail envelope admits a notification by reducing only its own width")
            if let admitted {
                let gap=c.envelopeGap(to:admitted);worstGap=min(worstGap,gap)
                check(gap>=12-1e-7,"complete tail envelope retains 12 pt: k=\(k), lean=\(lean), velocity=\(velocity)")
                check(admitted.height == proposed.height && admitted.maxX == proposed.maxX,"admission preserves notification height and fixed right edge")
            }
            let all=c.parts
            for j in 1..<all.count {
                let a=all[j-1],b=all[j]
                let overlap=a.radius+b.radius-hypot(a.rect.midX-b.rect.midX,a.rect.midY-b.rect.midY)
                worstOverlap=min(worstOverlap,overlap)
            }
            maxParts=max(maxParts,all.count);samples+=1
        }}}
        check(worstOverlap>=1,"native circular pieces overlap by at least 1 pt, including the tip")
        check(maxParts<=65,"native prototype has a bounded physical part count")
        let crowded=CGRect(x:1100,y:740,width:60,height:48)
        check(TideContour.admit(crowded,obstacles:[crowded]) == nil,"no fitting width returns no expanded shape instead of flattening")
        try JSONSerialization.data(withJSONObject:["samples":samples,"minimumEnvelopeGap":worstGap,
            "minimumInternalOverlap":worstOverlap,"maximumPhysicalParts":maxParts,"nativeFusionVerified":false],options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent("tide-contours.json"))
    }

    static func native(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for scale:CGFloat in [1,2] {for exposure in [false,true] {for hz in [60.0,120.0] {
            let f=DockCapsuleVerification.Fixture(scale:scale,exposure:exposure)
            f.dock.motionProfile = .init(name:"tide-peek",frameInterval:1/hz,mmPerPoint:0.27,persistenceFrames:0)
            f.dock.frame(at:f.now,elapsed:0)
            let c=f.all[2].id,d=f.all[3].id,e=f.all[4].id
            let original=Dictionary(uniqueKeysWithValues:f.dock.restingTargets.map{($0.id,$0.rect)})
            let cBase=original[c]!
            f.store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":.string(d),"turn":["id":"tide-native-turn"]]))
            let pose=TideMaterialPose(owner:c,body:CGRect(x:cBase.minX,y:cBase.midY-18,width:36,height:36))
            let installed=f.dock.stageTideMaterialProbe([pose])
            let tag="\(Int(scale))x exposure=\(exposure) \(Int(hz))Hz"
            check(installed,"native material fixture mounts after a real-shaped Core event: "+tag)
            check(f.dock.physicalGlassSnapshot.filter{$0.group==c}.count==pose.contour.parts.count,"all physical body/tail parts are audited: "+tag)
            check(MotionStep.edge(f.dock.items[c]!.glass.frame,pose.body)<0.001,"borrowed body reaches its 36 pt native target: "+tag)
            guard installed else {
                rows.append(["scale":scale,"exposure":exposure,"hz":hz,"installed":false,
                    "actualBody":DockFrameLog.rect(f.dock.items[c]!.glass.frame),
                    "physical":f.dock.physicalGlassSnapshot.map { ["id":$0.id,"group":$0.group,"frame":DockFrameLog.rect($0.frame)] as [String:Any] }])
                continue
            }
            f.dock.sample(.infinity)
            check(MotionStep.edge(f.dock.items[c]!.glass.frame,pose.body)<0.001,"direct production sample cannot overwrite the retained Tide material pose: "+tag)
            f.dock.frame(at:f.now,elapsed:f.now-f.began)
            let stationary=Dictionary(uniqueKeysWithValues:f.dock.physicalGlassSnapshot.filter{$0.group != c && $0.group != d && $0.group != e}.map{($0.id,$0.frame)})
            let began=f.now,capD=CGRect(x:original[d]!.minX-150,y:original[d]!.minY-120,width:280,height:48)
            let capE=capD.offsetBy(dx:original[e]!.minX-original[d]!.minX,dy:0)
            f.dock.projectPeek(shown:d,open:true,capsule:capD,rows:[:],rowY:capD.maxY+30)
            var switched=false,closed=false,minHeight=CGFloat.infinity,neighbourShift:CGFloat=0,minGap=CGFloat.infinity
            var previous:[String:Bool]=[:],flips:[String:Int]=[:],maxFlips=0
            for frame in 0...Int(hz*3) {
                let t=Double(frame)/hz;f.now=began+t
                if !switched,t>=0.12 {switched=true;f.now=began+0.12;f.dock.projectPeek(shown:e,open:true,capsule:capE,rows:[:],rowY:capE.maxY+30);f.now=began+t}
                if !closed,t>=1.5 {
                    check(MotionStep.edge(f.dock.items[e]!.glass.frame,capE)<0.01,"incoming Peek reaches its specified x/y/w/h: "+tag)
                    closed=true;f.dock.projectPeek(shown:nil,open:false,capsule:.zero,rows:[:],rowY:0)
                }
                f.dock.frame(at:f.now,elapsed:f.now-f.began)
                for id in [d,e] {minHeight=min(minHeight,f.dock.items[id]!.glass.frame.height)}
                let parts=f.dock.physicalGlassSnapshot
                for part in parts {
                    if let old=stationary[part.id] {neighbourShift=max(neighbourShift,MotionStep.edge(old,part.frame))}
                    guard part.group==c else {continue}
                    for other in parts where other.group != c {minGap=min(minGap,TideContour.gap(part.frame,other.frame))}
                }
                for a in parts where a.group==c {for b in parts where b.group != c {
                    let key=a.id+"|"+b.id,joined=TideContour.gap(a.frame,b.frame)<=10
                    if let old=previous[key],old != joined {flips[key,default:0]+=1}
                    previous[key]=joined;maxFlips=max(maxFlips,flips[key] ?? 0)
                }}
            }
            for id in [d,e] {check(MotionStep.edge(f.dock.items[id]!.glass.frame,original[id]!)<0.01,"closing Peek returns to its original orb endpoint \(id): "+tag)}
            check(minHeight>=32-0.01,"adjacent Peek never flattens either body: "+tag)
            check(neighbourShift<0.001,"Tide/Peek leaves unrelated native neighbours fixed: "+tag)
            check(minGap>=12-0.001,"every physical Tide part clears every other owner: "+tag)
            check(maxFlips==0,"Tide-to-neighbour fusion intent never flips: "+tag)
            rows.append(["scale":scale,"exposure":exposure,"hz":hz,"minimumHeight":minHeight,
                "neighbourShift":neighbourShift,"minimumPhysicalGap":minGap,"maximumFusionFlips":maxFlips,"probe":f.dock.tideMaterialProbe])
            f.dock.clearTideMaterialProbe()
            check(f.dock.physicalGlassSnapshot.filter{$0.id.hasPrefix("tide.tail.")}.isEmpty,"material disposal removes physical tail participation: "+tag)
        }}}
        check(NSApp.windows.allSatisfy{!$0.isVisible},"Tide verification shows no windows")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-native.json"))
    }
}
#endif
