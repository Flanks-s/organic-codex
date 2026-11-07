#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// A stateful audit: every walk combines ownership changes instead of resetting after each gesture.
@MainActor enum DockHandoffVerification {
    typealias Fixture=DockCapsuleVerification.Fixture
    static let h=1.0/120
    static func vector(_ r:CGRect)->[Double] { [Double(r.origin.x),Double(r.origin.y),Double(r.size.width),Double(r.size.height)] }
    static func error(_ a:[Double],_ b:[Double])->Double { zip(a,b).map{abs($0-$1)}.max() ?? 0 }
    static func derivative(_ a:CGRect,_ b:CGRect,_ c:CGRect,forward:Bool)->[Double] {
        let x=vector(a),y=vector(b),z=vector(c)
        return (0..<4).map { forward ? (-3*x[$0]+4*y[$0]-z[$0])/(2*h):(x[$0]-4*y[$0]+3*z[$0])/(2*h) }
    }
    struct Count {
        var events=0,items=0,position=0,velocity=0,deadline=0,born=0,lost=0,fusion=0,filtered=0,recorded=0
        var fields:[String:Int] { ["events":events,"items":items,"positionFailures":position,"velocityFailures":velocity,"deadlineFailures":deadline,"born":born,"lost":lost,"fusionChanges":fusion,"alphaFiltered":filtered,"recordedParts":recorded] }
    }
    @MainActor final class Walk {
        let f:Fixture
        let name:String
        var deadline=0.0
        var rows:[[String:Any]]=[]
        var counts:[String:Count]=[:]
        var releaseFailures=0,identityFailures=0,riseChanges=0
        var originCorrect=false
        var size=CGSize(width:1280,height:820)
        var metrics=AutoLayout.Metrics.tuned(for:CGSize(width:1280,height:820))
        var previous:[String:CGRect]=[:]
        var previousTime=0.0
        var cadence=1.0/60
        var fullyFocused=false
        var activeAction:String?
        var nativePairState:[String:Bool]=[:]
        var nativePairFlips:[String:Int]=[:]
        var nativeIntervals:[[String:Any]]=[]
        func closeInterval() {
            guard let action=activeAction else {return}
            nativeIntervals.append(["action":action,"pairFlips":nativePairFlips,"maximumFlips":nativePairFlips.values.max() ?? 0])
            activeAction=nil
        }
        init(name:String,exposure:Bool) {
            self.name=name;f=Fixture(scale:2,exposure:exposure)
            // A small injected epoch keeps independent finite derivatives numerically well conditioned.
            f.now=100;f.began=100;f.dock.still=false
            f.dock.onNeedsFrames={ [unowned self] d in self.deadline=max(self.deadline,self.f.now+d) }
            f.dock.onNeedsFramesUntil={ [unowned self] end in self.deadline=max(self.deadline,end) }
            f.dock.frame(at:f.now,elapsed:0)
        }
        func tick(_ dt:Double=0) {
            if dt>0 {previous=frames();previousTime=f.now}
            f.now += dt;f.dock.frame(at:f.now,elapsed:f.now-f.began)
            if activeAction != nil {
                let current=fusion(frames())
                for (key,value) in current {
                    if let old=nativePairState[key],old != value {nativePairFlips[key,default:0] += 1}
                    nativePairState[key]=value
                }
            }
        }
        func advance(_ dt:Double) {
            let steps=max(1,Int(ceil(dt/cadence))),step=dt/Double(steps)
            for _ in 0..<steps {tick(step)}
        }
        /// Native contours are the audit authority. Raw and physical logical poses are diagnostic only.
        func frames()->[String:CGRect] {Dictionary(uniqueKeysWithValues:f.dock.auditedGlassSnapshot.filter{!$0.hidden}.map{($0.id,$0.frame)})}
        func physicalFrames()->[String:(logical:CGRect,native:CGRect)] {
            Dictionary(uniqueKeysWithValues:f.dock.auditedGlassSnapshot.map{($0.id,($0.logical,$0.frame))})
        }
        func fusion(_ values:[String:CGRect])->[String:Bool] {
            var result:[String:Bool]=[:];let ids=values.keys.sorted()
            for (i,a) in ids.enumerated() {for b in ids.dropFirst(i+1) {
                let x=values[a]!,y=values[b]!
                guard min(x.maxY,y.maxY)-max(x.minY,y.minY)>min(x.height,y.height)*0.25 else {continue}
                result[a+"|"+b]=DockGlassTopology.gap(x,y)<=10
            }}
            return result
        }
        func commit(_ next:(AutoLayout,[String])) {
            let prepared=f.dock.springs(to:next.0,order:next.1,at:f.now-f.began,spring:(0.4,0.82))
            let duration=prepared.values.map(\.duration).max() ?? 0
            f.dock.projectPeek(shown:nil,open:false,capsule:.zero,rows:[:],rowY:0)
            f.dock.transitionEpoch=f.dock.makeTransitionEpoch(at:f.now)
            f.dock.transition(to:next.0,order:next.1,full:Set(next.1.prefix(next.0.bars.count)),springs:prepared,duration:duration)
            f.layout=next.0;f.order=next.1;f.began=f.now;f.dock.still=fullyFocused && next.0.focused
            // Match AutoScene.commit's final runClock boundary, including its physical release tail.
            deadline=max(deadline,f.now+duration,f.dock.glassReleaseSettles,f.dock.meSettles,f.dock.peekSettles,f.dock.carrySettles)
        }
        func event(_ action:String,zero:String?=nil,pickup:String?=nil,_ body:()->Void) {
            closeInterval();activeAction=action;nativePairState=fusion(frames());nativePairFlips=[:]
            let beforeParts=Dictionary(uniqueKeysWithValues:f.dock.auditedGlassSnapshot.map{($0.id,$0)})
            let rawBefore=beforeParts.mapValues(\.raw)
            let before=frames(),beforePhysical=physicalFrames(),prior=previous,priorTime=previousTime,eventTime=f.now
            let beforeState:[String:Any]=["physicalReleaseChannels":f.dock.reviewPhysicalReleaseCount,
                "holding":f.dock.isHolding,"peek":f.dock.hasPeek,"focused":f.layout.focused,
                "layoutVelocity":f.dock.items.values.map{Self.vector($0.spring.sample(f.now-f.began).velocity).map{abs($0)}.max() ?? 0}.max() ?? 0]
            body();tick();let first=frames(),afterPhysical=physicalFrames()
            let afterParts=Dictionary(uniqueKeysWithValues:f.dock.auditedGlassSnapshot.map{($0.id,$0)})
            let rawAfter=afterParts.mapValues(\.raw)
            let releaseVelocity=zero.flatMap{ $0 == "me" ? f.dock.makeTransitionEpoch(at:f.now).me.velocity:f.dock.items[$0]?.spring.sample(0).velocity }
            let actualEnd=f.dock.reviewAllSpringEnd
            let endError=max(0,max(actualEnd,f.dock.glassReleaseSettles,f.dock.meSettles,f.dock.peekSettles,f.dock.carrySettles)-deadline)
            tick(cadence);let second=frames();tick(cadence);let third=frames()
            var count=counts[action] ?? Count();count.events += 1
            count.born += first.keys.filter{before[$0]==nil}.count;count.lost += before.keys.filter{first[$0]==nil}.count
            var parts:[[String:Any]]=[]
            for id in Set(beforeParts.keys).union(afterParts.keys).sorted() {
                let source=beforeParts[id],destination=afterParts[id]
                let old=source?.frame,current=destination?.frame
                let eligible=old != nil && current != nil && source?.hidden == false && destination?.hidden == false &&
                    (source?.effectiveAlpha ?? 0)>=0.02 && (destination?.effectiveAlpha ?? 0)>=0.02
                let e=old.flatMap{a in current.map{Self.error(Self.vector(a),Self.vector($0))}} ?? 0
                var oldV=[Double](repeating:0,count:4),newV=oldV
                let hasVelocity=old != nil && current != nil && prior[id] != nil && second[id] != nil && third[id] != nil
                if let old,let current,let p=prior[id],let r=second[id],let s=third[id] {
                    let dt=max(cadence,eventTime-priorTime)
                    oldV=zip(Self.vector(old),Self.vector(p)).map{($0-$1)/dt}
                    let x=Self.vector(current),y=Self.vector(r),z=Self.vector(s)
                    newV=(0..<4).map{(-3*x[$0]+4*y[$0]-z[$0])/(2*cadence)}
                }
                let carrier=zero.map{$0 == "me" ? "me":"item."+$0}
                let pickupCarrier=pickup.map{$0 == "me" ? "me":"item."+$0}
                let ve=id==carrier ? releaseVelocity.map{Self.error(Self.vector($0),[0,0,0,0])} ?? .infinity:(id==pickupCarrier ? Self.error(newV,[0,0,0,0]):Self.error(oldV,newV))
                count.recorded += 1
                if eligible {
                    count.items += 1;if e>=0.001 {count.position += 1}
                    if hasVelocity && ve>=0.01 {count.velocity += 1}
                    if id==carrier,ve>=0.001 {releaseFailures += 1}
                } else {count.filtered += 1}
                parts.append(["id":id,"before":old.map{Self.vector($0)} ?? [],"after":current.map{Self.vector($0)} ?? [],
                    "beforeWorldVelocity":oldV,"afterWorldVelocity":newV,
                    "beforeRaw":rawBefore[id].map{Self.vector($0)} ?? [],"afterRaw":rawAfter[id].map{Self.vector($0)} ?? [],
                    "beforeNative":beforePhysical[id].map{Self.vector($0.native)} ?? [],"afterNative":afterPhysical[id].map{Self.vector($0.native)} ?? [],
                    "beforeEffectiveLogical":beforePhysical[id].map{Self.vector($0.logical)} ?? [],"afterEffectiveLogical":afterPhysical[id].map{Self.vector($0.logical)} ?? [],
                    "beforeEffectiveAlpha":source?.effectiveAlpha ?? 0,"afterEffectiveAlpha":destination?.effectiveAlpha ?? 0,
                    "beforeHidden":source?.hidden ?? true,"afterHidden":destination?.hidden ?? true,
                    "beforeModelAlpha":source?.alpha ?? 0,"afterModelAlpha":destination?.alpha ?? 0,
                    "beforePresentationSampled":source?.sampledPresentation ?? false,"afterPresentationSampled":destination?.sampledPresentation ?? false,
                    "beforeAlphaChain":source?.alphaChain ?? [],"afterAlphaChain":destination?.alphaChain ?? [],
                    "positionChecked":eligible,"velocityChecked":eligible && hasVelocity,"positionError":e,"velocityError":ve,
                    "velocityPolicy":id==carrier ? "zero local release spring; world hover continues":(id==pickupCarrier ? "zero pickup shape velocity; stationary pointer":"preserve world tangent"),
                    "releaseLocalVelocity":id==carrier ? releaseVelocity.map{Self.vector($0)} ?? []:[]])
            }
            let bf=fusion(before),af=fusion(first)
            count.fusion += bf.keys.filter{af[$0] != nil && af[$0] != bf[$0]}.count
            if endError>0.000000001 && !f.dock.isHolding {count.deadline += 1}
            counts[action]=count
            rows.append(["walk":name,"action":action,"beforeState":beforeState,"time":eventTime,"cadence":cadence,"nativeFusionBefore":bf,"nativeFusionAfter":af,"deadline":deadline,"actualEnd":actualEnd,"deadlineShortBy":endError,"heldKeepsClockRunning":f.dock.isHolding,"parts":parts])
        }
        static var h:Double {DockHandoffVerification.h}
        static func vector(_ r:CGRect)->[Double] {DockHandoffVerification.vector(r)}
        static func error(_ a:[Double],_ b:[Double])->Double {DockHandoffVerification.error(a,b)}
        static func derivative(_ a:CGRect,_ b:CGRect,_ c:CGRect,forward:Bool)->[Double] {DockHandoffVerification.derivative(a,b,c,forward:forward)}
        func peek(_ open:Bool) {
            let id=f.all[4].id,item=f.dock.items[id]!,r=item.regular
            let cap=CGRect(x:r.minX,y:r.minY-160,width:max(120,r.width),height:64)
            f.dock.projectPeek(shown:open ? id:nil,open:open,capsule:cap,rows:[:],rowY:cap.maxY+30)
            deadline=max(deadline,f.dock.peekSettles)
        }
        func setup(_ state:String) {
            let orb=f.dock.items[f.all[4].id]!.glass.frame
            _=f.dock.pointer(CGPoint(x:orb.midX,y:orb.midY),now:f.now);f.dock.editing=true;advance(0.8)
            if state=="rest" {return}
            if state=="layout" {var next=f.auto();next.1.swapAt(0,1);commit(next);advance(0.075);return}
            DockFollowupVerification.startRelease(f,owner:f.all[0].id,second:f.all[1].id)
            DockReviewVerification.frame(f,0.04);commit(f.auto());advance(0.04)
            deadline=max(deadline,f.dock.glassReleaseSettles,f.dock.peekSettles)
            if state=="physical" {return}
            peek(true);advance(state=="peek-protected" ? 0.025:1.3)
        }
        func run(state:String,drop:String,remove:Bool) async throws {
            setup(state)
            let speed=f.dock.items.values.map{Self.vector($0.spring.sample(f.now-f.began).velocity).map{abs($0)}.max() ?? 0}.max() ?? 0
            let physical=f.dock.glassReleaseSettles>f.now,anchor=f.dock.reviewPeekAnchor(f.all[4].id) != nil
            switch state {
            case "rest":originCorrect=speed<0.001 && !physical && !f.dock.hasPeek
            case "layout":originCorrect=speed>1
            case "physical":originCorrect=physical
            case "peek-protected":originCorrect=anchor && f.dock.hasPeek
            default:originCorrect = !anchor && f.dock.hasPeek
            }
            rows.append(["walk":name,"action":"origin","state":state,"matches":originCorrect,"springSpeed":speed,"physicalRelease":physical,"anchor":anchor,"hasPeek":f.dock.hasPeek,"rise":f.dock.rise])
            let id=f.all[0].id,overflow=f.all[4].id
            event("hover-out") {_=f.dock.pointer(nil,now:f.now)}
            advance(0.013)
            event("hover-in") {
                let r=f.dock.items[overflow]!.regular
                _=f.dock.pointer(CGPoint(x:r.midX,y:r.midY),now:f.now)
            }
            event("grab",pickup:id) {
                let r=f.dock.items[id]!.glass.frame,row=f.layout.me.midY-f.dock.rise
                let p=CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4)
                f.dock.hold(id,at:p,now:f.now,spring:(0.3,0.8))
            }
            advance(0.35)
            for preview in 0..<4 {
                event("held-reorder") {var next=(f.layout,f.order);next.1.swapAt(1,2);commit(next)}
                advance(0.05)
                rows.append(["walk":name,"action":"long-hold-preview","preview":preview,"heldForAtLeast":0.35])
            }
            event("held-reorder") {var next=(f.layout,f.order);next.1.swapAt(1,2);commit(next)}
            advance(0.017)
            event(drop,zero:id) {
                f.dock.release();var next=f.auto();if drop=="drop-reorder" {next.1.swapAt(0,1)};commit(next)
            }
            advance(0.035)
            event("split-enter") {
                var next=f.focused(id,segments:2);next.1=[id,overflow]+f.all.map(\.id).filter{$0 != id && $0 != overflow};commit(next)
            }
            advance(0.08)
            event("identity-grab",pickup:overflow) {
                let r=f.dock.items[overflow]!.identity?.glassView.frame ?? f.dock.items[overflow]!.identityFrame,row=f.layout.me.midY-f.dock.rise
                f.dock.hold(overflow,at:CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4),now:f.now,spring:(0.3,0.8))
            }
            advance(0.011)
            // Execute the production delayed pointer-leave callback before probing the moving lift.
            f.dock.editing=false;_=f.dock.pointer(nil,now:f.now)
            try await Task.sleep(for:.milliseconds(100))
            // Deliberately let lift change between release and commit without presenting a frame.
            event("identity-to-orb",zero:overflow) {
                f.dock.editing=false;_=f.dock.pointer(nil,now:f.now)
                let world=f.dock.items[overflow]!.identityFrame,releaseRise=f.dock.rise
                f.dock.release();commit(f.auto())
                let item=f.dock.items[overflow]!,source=item.spring.sample(0).rect.adding(f.dock.hoverProjectionForVerification[item.slot])
                let e=Self.error(Self.vector(world),Self.vector(source));if e>=0.001 {identityFailures += 1}
                if abs(releaseRise-f.dock.rise)>0.001 {riseChanges += 1}
                rows.append(["walk":name,"action":"identity-source","releaseRise":releaseRise,"commitRise":f.dock.rise,"error":e,"expectedWorld":Self.vector(world),"actualWorld":Self.vector(source)])
            }
            advance(0.025)
            event("peek-open") {peek(true)};advance(0.04)
            event("peek-close") {peek(false)};advance(0.04)
            event("peek-reopen") {peek(true)};advance(1.3)
            event("clock-rewind") {f.now -= 0.25;f.began -= 0.25;deadline=max(deadline,f.dock.peekSettles)}
            event("me-grab",pickup:"me") {
                let r=f.dock.mePaintedFrame;f.dock.holdMe(at:CGPoint(x:r.midX,y:r.midY))
            }
            advance(0.013)
            event("me-release",zero:"me") {f.dock.releaseMe();deadline=max(deadline,f.dock.meSettles)}
            event("resize") {
                size=CGSize(width:1340,height:860);metrics=AutoLayout.Metrics.tuned(for:size)
                f.host.frame=CGRect(origin:.zero,size:size);f.host.bounds=CGRect(origin:.zero,size:size)
                let next=AutoLayout(size:size,count:f.all.count,fullIndex:0,metrics:metrics)
                f.dock.relayout(next,metrics:metrics,order:f.all,full:[id]);f.layout=next;f.order=f.all.map(\.id);f.began=f.now
            }
            event("tear-grab",pickup:id) {
                let r=f.dock.items[id]!.glass.frame,row=f.layout.me.midY-f.dock.rise
                f.dock.hold(id,at:CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4),now:f.now,spring:(0.3,0.8))
            }
            advance(0.02)
            event("tear-gap",zero:id) {
                f.dock.release(forTear:true);f.dock.setHidden(id,true)
                let others=f.all.filter{$0.id != id},next=AutoLayout(size:size,count:others.count,fullIndex:0,metrics:metrics)
                commit((next,others.map(\.id)))
            }
            advance(0.04)
            if remove {f.dock.dropItems(keeping:Set(f.all.dropFirst().map(\.id)))}
            event(remove ? "tear-return-rebuilt":"tear-return-retained") {
                f.dock.setHidden(id,false);f.dock.endHeaderTear(kept:true)
                let next=AutoLayout(size:size,count:f.all.count,fullIndex:0,metrics:metrics)
                f.dock.ensureItems(for:f.all,layout:next,order:f.all.map(\.id));commit((next,f.all.map(\.id)))
            }
        }
    }
    /// Controlled Objective-C display-link properties, driving SceneClock's actual pause decision.
    private final class Target:NSObject {
        @objc var timestamp=0.0,targetTimestamp=0.0,isPaused=false
        @objc(setPaused:) func setPaused(_ value:Bool) {isPaused=value}
    }
    static func clockRisk(to output:URL,check:(Bool,String)->Void,strict:Bool)->[String:Any] {
        let w=Walk(name:"clock-deadline",exposure:false),f=w.f
        w.setup("physical");w.peek(true);w.advance(0.05)
        f.dock.settleContent(full:[f.all[0].id]);w.tick(0.01);w.tick(0.01)
        let clock=SceneClock(),target=Target(),sent=w.deadline
        clock.run(until:sent)
        f.now -= 0.25;f.began -= 0.25;w.tick()
        let actual=f.dock.peekSettles
        target.targetTimestamp=actual+0.001;target.timestamp=target.targetTimestamp-1/60
        _=clock.perform(NSSelectorFromString("tick:"),with:target)
        if strict {check(target.isPaused,"R17 injected-clock deadline retracts after rollback (known SceneClock max limitation)")}
        return ["sentDeadline":sent,"migratedPeekEnd":actual,"extraTime":sent-actual,"pausedAfterActualEnd":target.isPaused,"scope":"Known injected-clock risk; SceneClock.max cannot retract a previously registered deadline."]
    }
    /// These two walks also cross AutoScene's real cancel and endTear preparation boundaries.
    static func sceneChains(check:(Bool,String)->Void)->[[String:Any]] {
        var rows:[[String:Any]]=[]
        for remove in [false,true] {
            let all=Array(MockSeed.make().prefix(6)),store=ConversationStore(conversations:all,projects:MockSeed.projects,devices:MockSeed.devices)
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
            scene.ambient=false;scene.manualSettle=true
            var now=1000.0
            scene.now={now};scene.dock.motionTime={now};scene.dock.motionEnabled=false;scene.install()
            scene.dock.editing=true;now += 1;scene.frame(now)
            var reordered=scene.members;reordered.swapAt(0,1)
            scene.commit(scene.prepare(members:reordered,current:scene.current,at:now,spring:(0.4,0.82)),reason:"r16-layout",prewarmed:false,start:CACurrentMediaTime())
            now += 0.06;scene.frame(now)
            let id=all[0].id,item=scene.dock.items[id]!,r=item.motion.rect ?? item.glass.frame
            let row=scene.layout.me.midY-scene.dock.rise,p=CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4)
            scene.drag=AutoScene.Drag(id:id,start:p,began:true,before:scene.members,beforeCurrent:scene.current)
            scene.dock.hold(id,at:p,now:now,spring:(0.3,0.8));now += 0.017;scene.frame(now)
            if remove {scene.cancelDrag()} else {_=scene.pointerUp(p)}
            scene.frame(now)
            let velocity=vector(item.spring.sample(0).velocity),end=scene.transitionEnd,actual=now+(scene.dock.items.values.map{$0.spring.duration}.max() ?? 0)
            check(error(velocity,[0,0,0,0])<0.001,"R16 real AutoScene release preserves zero velocity escape=\(remove): \(velocity)")
            check(end+0.000000001>=actual,"R16 real AutoScene deadline covers committed springs escape=\(remove): \(actual-end)")
            now += 0.04;scene.frame(now)
            let before=scene.members,current=scene.current,world=item.motion.rect ?? item.glass.frame
            scene.dock.hold(id,at:CGPoint(x:world.midX,y:world.midY),now:now,spring:(0.3,0.8));scene.frame(now)
            scene.tearing=(id,before,current);scene.dock.release(forTear:true);scene.dock.setHidden(id,true)
            let others=before.filter{$0.id != id}
            scene.commit(scene.prepare(members:others,current:others[0].id,at:now,spring:(0.4,0.82)),reason:"r16-tear-gap",prewarmed:false,start:CACurrentMediaTime())
            now += 0.04;scene.frame(now)
            if remove {scene.dock.dropItems(keeping:Set(others.map(\.id)))}
            scene.endTear(kept:true);scene.frame(now)
            check(scene.dock.items[id] != nil && scene.members.contains{$0.id==id},"R16 real endTear restores retained or rebuilt member remove=\(remove)")
            check(scene.sceneView.window==nil,"R16 real scene chain stays windowless")
            rows.append(["escape":remove,"dropBeforeTearReturn":remove,"releaseVelocity":velocity,"sceneDeadline":end,"actualSpringEnd":actual])
            scene.clock.invalidate();scene.disposeTranscriptPresentation()
        }
        return rows
    }
    /// Esc crosses the real AutoScene cancel/prepare/commit path at all five starting states.
    static func escapeChains(strict:Bool,check:(Bool,String)->Void)->[[String:Any]] {
        var rows:[[String:Any]]=[]
        for state in ["rest","layout","physical","peek-protected","peek-expired"] {for hz in [60.0,120.0] {
            let all=Array(MockSeed.make().prefix(6)),store=ConversationStore(conversations:all,projects:MockSeed.projects,devices:MockSeed.devices)
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
            scene.ambient=false;scene.manualSettle=true
            var now=2000.0
            scene.now={now};scene.dock.motionTime={now};scene.dock.motionEnabled=false;scene.install()
            scene.dock.editing=true
            func advance(_ duration:Double) {
                let n=max(1,Int(ceil(duration*hz))),dt=duration/Double(n)
                for _ in 0..<n {now += dt;scene.frame(now)}
            }
            advance(0.8)
            if state=="layout" {
                var next=scene.members;next.swapAt(0,1)
                scene.commit(scene.prepare(members:next,current:scene.current,at:now,spring:(0.4,0.82)),reason:"r17-esc-layout",prewarmed:false,start:CACurrentMediaTime());advance(0.075)
            } else if state != "rest" {
                scene.enterFocused(all[0].id,reason:"r17-esc-source");scene.graft(all[1].id,at:1,reason:"r17-esc-source");advance(1.2)
                let item=scene.dock.items[all[1].id]!,r=item.identityFrame
                scene.dock.hold(all[1].id,at:CGPoint(x:r.midX,y:r.midY),now:now,spring:(0.3,0.8))
                for n in 1...6 {scene.dock.moveHeld(to:CGPoint(x:r.midX-CGFloat(n)*8,y:r.midY));advance(1/hz)}
                scene.dock.release()
                scene.commit(scene.prepare(members:scene.members,current:scene.current,at:now,spring:(0.4,0.82)),reason:"r17-esc-release",prewarmed:false,start:CACurrentMediaTime())
                scene.leaveFocused(reason:"r17-esc-auto");advance(0.04)
                if state.hasPrefix("peek") {
                    let id=all[4].id,r=scene.dock.items[id]!.regular,cap=CGRect(x:r.minX,y:r.minY-160,width:160,height:64)
                    scene.dock.projectPeek(shown:id,open:true,capsule:cap,rows:[:],rowY:cap.maxY+30)
                    advance(state=="peek-protected" ? 0.025:1.3)
                }
            }
            let id=all[0].id,item=scene.dock.items[id]!,r=item.glass.frame,row=scene.layout.me.midY-scene.dock.rise
            let p=CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4)
            scene.drag=AutoScene.Drag(id:id,start:p,began:true,before:scene.members,beforeCurrent:scene.current)
            scene.dock.hold(id,at:p,now:now,spring:(0.3,0.8));advance(1/hz)
            let before=Dictionary(uniqueKeysWithValues:scene.dock.auditedGlassSnapshot.map{($0.id,$0)})
            scene.cancelDrag();scene.frame(now)
            let after=Dictionary(uniqueKeysWithValues:scene.dock.auditedGlassSnapshot.map{($0.id,$0)})
            let differences=before.compactMap {key,r in after[key].map{part in
                ["id":key,"nativeError":MotionStep.edge(r.frame,part.frame),"beforeEffectiveAlpha":r.effectiveAlpha,
                 "afterEffectiveAlpha":part.effectiveAlpha,"beforeHidden":r.hidden,"afterHidden":part.hidden,
                 "positionChecked":!r.hidden && !part.hidden && r.effectiveAlpha>=0.02 && part.effectiveAlpha>=0.02] as [String:Any]
            }}
            if strict {
                let maximum=differences.filter{$0["positionChecked"] as? Bool == true}.compactMap{$0["nativeError"] as? CGFloat}.max() ?? 0
                check(maximum<0.001,"R17 real Escape all visible native contours state=\(state) hz=\(hz): \(maximum)")
            }
            check(scene.drag==nil && !scene.dock.isHolding,"R17 real Escape cancels state=\(state) hz=\(hz)")
            check(scene.transitionEnd+1e-9>=scene.dock.reviewAllSpringEnd,"R17 real Escape deadline includes capsule and identity state=\(state) hz=\(hz)")
            rows.append(["state":state,"hz":hz,"parts":differences,"sceneEnd":scene.transitionEnd,"allSpringEnd":scene.dock.reviewAllSpringEnd])
            scene.clock.invalidate();scene.disposeTranscriptPresentation()
        }}
        return rows
    }
    static func anchorBoundaryChains()->[[String:Any]] {
        var rows:[[String:Any]]=[]
        for hz in [60.0,120.0] {for side in [-1.0,1.0] {
            let w=Walk(name:"anchor-boundary",exposure:false);w.cadence=1/hz;w.setup("physical");w.peek(true)
            let end=w.f.dock.glassReleaseSettles,target=end+side/hz
            w.advance(max(0,target-w.f.now))
            w.event("anchor-boundary-close") {w.peek(false)}
            rows.append(["hz":hz,"side":side,"releaseEnd":end,"inputTime":target,"events":w.rows])
        }}
        return rows
    }
    static func draftChains(check:(Bool,String)->Void)->[[String:Any]] {
        var result:[[String:Any]]=[]
        for hz in [60.0,120.0] {
            let w=Walk(name:"draft-carrier",exposure:false);w.cadence=1/hz;w.setup("rest")
            let composer=NativeComposer(frame:.zero),r=CGRect(x:450,y:650,width:200,height:48)
            w.f.dock.showDraftBar(composer,at:r);w.tick()
            check(w.frames()["draft"] != nil,"R17 native audit constructs a physical draft hz=\(hz)")
            w.event("draft-layout") {var next=w.f.auto();next.1.swapAt(0,1);w.commit(next)}
            w.event("draft-hover") {_=w.f.dock.pointer(nil,now:w.f.now)}
            result += w.rows;w.f.dock.hideDraftBar()
        }
        return result
    }
    static func contourRegressions(check:(Bool,String)->Void)->[[String:Any]] {
        var rows:[[String:Any]]=[]
        for hz in [60.0,120.0] {for heldSlot in [0,1] {for exposure in [false,true] {
            let w=Walk(name:"contour-regression",exposure:exposure),f=w.f
            w.cadence=1/hz;w.setup("layout")
            let id=f.all[heldSlot].id,item=f.dock.items[id]!,r=item.glass.frame,row=f.layout.me.midY-f.dock.rise
            let before=w.frames()
            f.dock.hold(id,at:CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4),now:f.now,spring:(0.3,0.8));w.tick()
            let grabbed=w.frames()
            let grabParts=before.compactMap{key,r in grabbed[key].map{["id":key,"error":MotionStep.edge(r,$0)] as [String:Any]}}
            // HEAD's immediate hover collapse for side orbs is a separate, unchanged pickup rule.
            let bars=Set(f.all.prefix(3).map{"item."+$0.id}).union(["me","capsule"])
            let grabError=before.filter{bars.contains($0.key)}.compactMap{key,r in grabbed[key].map{MotionStep.edge(r,$0)}}.max() ?? 0
            check(grabError<0.001,"R17 grab inherits native bar contours (HEAD orb hover rule recorded separately) hz=\(hz) slot=\(heldSlot): \(grabError)")
            w.advance(0.35)
            var maxBob:CGFloat=0
            for _ in 0..<5 {
                let old=Dictionary(uniqueKeysWithValues:f.dock.items.map{($0.key,$0.value.glass.frame)})
                var next=(f.layout,f.order);next.1.swapAt(1,2);w.commit(next);w.tick()
                for (key,r) in old where key != id {
                    if let current=f.dock.items[key]?.glass.frame {maxBob=max(maxBob,abs(r.origin.y-current.origin.y))}
                }
                w.advance(1/hz)
            }
            check(maxBob<0.001,"R17 long-held repeated preview changes bob basis once hz=\(hz) slot=\(heldSlot): \(maxBob)")
            let held=w.frames();f.dock.release();w.commit(f.auto());w.tick();let released=w.frames()
            let releaseError=held.compactMap{key,r in released[key].map{MotionStep.edge(r,$0)}}.max() ?? 0
            check(releaseError<0.001,"R17 release inherits every native contour hz=\(hz) slot=\(heldSlot): \(releaseError)")
            rows.append(["hz":hz,"slot":heldSlot,"exposure":exposure,"grabError":grabError,"allGrabParts":grabParts,"bobError":maxBob,"releaseError":releaseError])
        }}}
        return rows
    }
    static func visibilityChecks(check:(Bool,String)->Void) {
        let root=NSView(),parent=NSView(),child=NSView()
        for view in [root,parent,child] {view.wantsLayer=true}
        root.addSubview(parent);parent.addSubview(child)
        root.alphaValue=0.5;parent.alphaValue=0.4;child.alphaValue=0.25
        var state=DockNode.glassVisibility(child)
        check(abs(state.alpha-0.05)<0.000001,"R18 alpha multiplies the complete superview chain once")
        check(!state.hidden && state.chain.count==3,"R18 visible chain records every ancestor")
        parent.isHidden=true;state=DockNode.glassVisibility(child)
        check(state.hidden,"R18 hidden ancestor excludes the part without deleting its record")
        parent.isHidden=false;root.layer?.isHidden=true;state=DockNode.glassVisibility(child)
        check(state.hidden,"R18 hidden ancestor layer excludes the part")
        root.layer?.isHidden=false;root.alphaValue=1;parent.alphaValue=0.019;child.alphaValue=1
        check(DockNode.glassVisibility(child).alpha<0.02,"R18 alpha below 0.02 is excluded")
        parent.alphaValue=0.02
        check(DockNode.glassVisibility(child).alpha>=0.02-0.0000001,"R18 threshold keeps alpha 0.02")
        parent.alphaValue=1;child.alphaValue=0.4;child.layer?.opacity=0.7
        check(abs(DockNode.glassVisibility(child).alpha-0.7)<0.000001,"R18 view alpha is not multiplied again into its backing layer")
    }

    /// Independent ordinary operations: no earlier drop/Peek/clock rewind is allowed to seed the case.
    static func singleOperations(check:(Bool,String)->Void)->[[String:Any]] {
        var rows:[[String:Any]]=[]
        for action in ["split-enter","peek-open","identity-grab","tear-return-retained"] {
            for state in ["rest","layout"] {for exposure in [false,true] {for hz in [60.0,120.0] {
                let w=Walk(name:"single/\(state)/\(action)/exposure=\(exposure)/hz=\(Int(hz))",exposure:exposure),f=w.f
                w.cadence=1/hz;w.setup(state)
                let id=f.all[0].id,overflow=f.all[4].id
                func split() {
                    var next=f.focused(id,segments:2);next.1=[id,overflow]+f.all.map(\.id).filter{$0 != id && $0 != overflow};w.commit(next)
                }
                if action=="identity-grab" {split();w.advance(state=="rest" ? 1.2:0.08)}
                if action=="tear-return-retained" {
                    let r=f.dock.items[id]!.glass.frame,row=f.layout.me.midY-f.dock.rise
                    f.dock.hold(id,at:CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4),now:f.now,spring:(0.3,0.8));w.tick();w.advance(0.02)
                    f.dock.release(forTear:true);f.dock.setHidden(id,true)
                    let others=f.all.filter{$0.id != id},layout=AutoLayout(size:f.size,count:others.count,fullIndex:0,metrics:f.metrics)
                    w.commit((layout,others.map(\.id)));w.advance(0.04)
                }
                let releaseBefore=f.dock.glassReleaseSettles>f.now,peekBefore=f.dock.hasPeek
                w.event(action) {
                    switch action {
                    case "split-enter":split()
                    case "peek-open":w.peek(true)
                    case "identity-grab":
                        let r=f.dock.items[overflow]!.identity!.glassView.frame,row=f.layout.me.midY-f.dock.rise
                        f.dock.hold(overflow,at:CGPoint(x:r.midX,y:row+(r.midY-row+4)/0.4),now:f.now,spring:(0.3,0.8))
                    default:
                        f.dock.setHidden(id,false);f.dock.endHeaderTear(kept:true)
                        f.dock.ensureItems(for:f.all,layout:f.auto().0,order:f.auto().1);w.commit(f.auto())
                    }
                }
                var row=w.rows.last!
                row["initialState"]=state;row["releaseBefore"]=releaseBefore;row["peekBefore"]=peekBefore
                let parts=row["parts"] as! [[String:Any]]
                let stable=parts.filter {p in
                    let a=p["beforeRaw"] as! [Double],b=p["afterRaw"] as! [Double]
                    return p["positionChecked"] as! Bool && a.count==4 && b.count==4 && error(a,b)<0.001
                }
                let maximum=stable.compactMap{$0["positionError"] as? Double}.max() ?? 0
                row["visibleRawStableNativeMaximum"]=maximum
                check(maximum<0.001,"R18 single visible raw-stable native \(action) state=\(state) exposure=\(exposure) hz=\(hz): \(maximum)")
                rows.append(row)
            }}}
        }
        for ownerIndex in 0..<3 {for progress in [0.0,1.0/60,0.075,0.15,0.24,0.35] {for segments in [2,3] {for exposure in [false,true] {
            let w=Walk(name:"single/split-owner=\(ownerIndex)/progress=\(progress)/segments=\(segments)/exposure=\(exposure)",exposure:exposure),f=w.f
            w.cadence=1/120;w.setup("rest")
            if progress>0 {var next=f.auto();next.1.swapAt(0,1);w.commit(next);w.advance(progress)}
            w.event("split-enter") {w.commit(f.focused(f.all[ownerIndex].id,segments:segments))}
            var row=w.rows.last!;let parts=row["parts"] as! [[String:Any]]
            let stable=parts.filter {p in
                let x=p["beforeRaw"] as! [Double],y=p["afterRaw"] as! [Double]
                return p["positionChecked"] as! Bool && x.count==4 && y.count==4 && error(x,y)<0.001
            }
            let maximum=stable.compactMap{$0["positionError"] as? Double}.max() ?? 0
            row["visibleRawStableNativeMaximum"]=maximum
            check(maximum<0.001,"R18 independent Split entry owner=\(ownerIndex) progress=\(progress) segments=\(segments) exposure=\(exposure): \(maximum)")
            rows.append(row)
        }}}}
        return rows
    }
    static func run(to output:URL,regressionOnly:Bool,check:(Bool,String)->Void) async throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        visibilityChecks(check:check)
        var intervals:[[String:Any]]=[]
        var totals:[String:Count]=[:],traces:[[String:Any]]=[],walks=0,releaseFailures=0,identityFailures=0,riseChanges=0,originFailures=0
        for state in ["rest","layout","physical","peek-protected","peek-expired"] {
            for exposure in [false,true] {for drop in ["drop","drop-reorder"] {for remove in [false,true] {for hz in [60.0,120.0] {for focused in [false,true] {
                let w=Walk(name:"\(state)/exposure=\(exposure)/\(drop)/remove=\(remove)",exposure:exposure)
                w.cadence=1/hz;w.fullyFocused=focused
                try await w.run(state:state,drop:drop,remove:remove);walks += 1;releaseFailures += w.releaseFailures;identityFailures += w.identityFailures;riseChanges += w.riseChanges;if !w.originCorrect {originFailures += 1}
                w.closeInterval();intervals += w.nativeIntervals
                traces += w.rows
                for (key,c) in w.counts {
                    var old=totals[key] ?? Count();old.events += c.events;old.items += c.items;old.position += c.position;old.velocity += c.velocity;old.deadline += c.deadline;old.born += c.born;old.lost += c.lost;old.filtered += c.filtered;old.recorded += c.recorded;old.fusion += c.fusion;totals[key]=old
                }
            }}}}}
        }
        check(walks==160,"R17 native matrix executes 160 walks at 60/120 Hz, Fully Focused on/off")
        check(originFailures==0,"R16 all five requested starting states are actually constructed: \(originFailures)")
        check(riseChanges==0,"R17 action does not advance time internally")
        check(releaseFailures==0,"R16 prepared zero release velocity is retained: \(releaseFailures) failures")
        check(identityFailures==0,"R16 identity world source survives a changing lift: \(identityFailures) failures")
        if !regressionOnly {
            for (action,c) in totals.sorted(by:{$0.key<$1.key}) {
                check(c.position==0,"R16 strict first-frame position \(action): \(c.position)/\(c.items)")
                check(c.velocity==0,"R16 signed world tangent \(action): \(c.velocity)/\(c.items)")
                check(c.deadline==0,"R16 deadline covers actual channels \(action): \(c.deadline)/\(c.events)")
            }
        }
        let repeating=intervals.filter{($0["maximumFlips"] as? Int ?? 0)>1}
        if !regressionOnly {check(repeating.isEmpty,"R17 every native pair changes fusion at most once per handoff: \(repeating.count)/\(intervals.count) intervals")}
        let result:[String:Any]=["nativeIntervals":intervals,"repeatingFusionIntervals":repeating.count,"walks":walks,"events":totals.values.reduce(0){$0+$1.events},"counts":totals.mapValues(\.fields),"releaseVelocityFailures":releaseFailures,"identitySourceFailures":identityFailures,"movingLiftCases":riseChanges,"originFailures":originFailures,
            "effectiveAlphaThreshold":0.02,"positionTolerance":0.001,"velocityTolerance":0.01,"cadences":[1.0/60,1.0/120],"velocityComponents":"origin.x, origin.y, size.width, size.height; incoming native interval rate and three-point outgoing fit",
            "clockRisk":clockRisk(to:output,check:check,strict:!regressionOnly),"sceneChains":sceneChains(check:check),"escapeChains":escapeChains(strict:!regressionOnly,check:check),"anchorBoundaryChains":anchorBoundaryChains(),"regressions":contourRegressions(check:check),"draftChains":draftChains(check:check),"singleOperations":singleOperations(check:check),"traces":traces,"scope":"All visible native physical glass, including capsule, draft, identity and me; hidden and effective-alpha <0.02 nodes recorded but excluded from position assertions. Finite native velocities use real display cadence; acceleration and shutter-history differences are retained as measurement findings."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("handoffs.json"))
        check(NSApp.windows.allSatisfy{!$0.isVisible},"R16 audit shows no window")
    }
}
#endif
