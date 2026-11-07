#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Round eleven exercises production ownership boundaries, including AutoScene's actual settle timer.
@MainActor enum DockFollowupVerification {
    typealias Fixture=DockCapsuleVerification.Fixture
    static func startRelease(_ f: Fixture, owner: String, second: String) {
        DockReviewVerification.command(f,f.focused(owner,segments:2));DockReviewVerification.frame(f,1.2)
        let r=f.dock.items[second]!.identityFrame
        f.dock.hold(second,at:CGPoint(x:r.midX,y:r.midY),now:f.now,spring:(0.3,0.8))
        for k in 1...6 {
            f.now += 1/120
            f.dock.moveHeld(to:CGPoint(x:r.midX-CGFloat(k)*8,y:r.midY))
            f.dock.frame(at:f.now,elapsed:f.now-f.began)
        }
        f.dock.release();DockReviewVerification.command(f,f.focused(owner,segments:2));DockReviewVerification.frame(f,0)
    }
    static func run(to output: URL, check: (Bool,String)->Void) async throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        try peekRelease(to:output,check:check)
        try peekCoordinates(to:output,check:check)
        try releaseCoordinates(to:output,check:check)
        for escape in [false,true] {
            let all=Array(MockSeed.make().prefix(6)),store=ConversationStore(conversations:all,projects:MockSeed.projects,devices:MockSeed.devices)
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:2)
            let oldFully=scene.fullyFocused
            scene.fullyFocused=true;scene.ambient=false;scene.manualSettle=true
            var virtual=CACurrentMediaTime()-20
            scene.now={virtual};scene.dock.motionTime={virtual};scene.install()
            scene.enterFocused(all[0].id,reason:"r11-setup");virtual=scene.transitionEnd+0.1;scene.frame(virtual);scene.settle()
            scene.graft(all[1].id,at:1,reason:"r11-setup-split");virtual=scene.transitionEnd+0.1;scene.frame(virtual);scene.settle()
            scene.now={CACurrentMediaTime()};scene.dock.motionTime=nil;scene.manualSettle=false
            let second=all[1].id,r=scene.dock.items[second]!.identityFrame
            let start=CGPoint(x:r.midX,y:r.midY),drop=CGPoint(x:r.midX-70,y:r.midY)
            scene.drag=AutoScene.Drag(id:second,start:start,began:true,before:scene.members,beforeCurrent:scene.current)
            scene.dock.hold(second,at:start,now:CACurrentMediaTime(),spring:AutoScene.queueSpring)
            for k in 1...6 {
                scene.dock.moveHeld(to:CGPoint(x:start.x-70*CGFloat(k)/6,y:start.y))
                scene.frame(CACurrentMediaTime());try await Task.sleep(for:.milliseconds(8))
            }
            let count=scene.settles.count
            if escape {scene.cancelDrag()} else {_=scene.pointerUp(drop)}
            let began=CACurrentMediaTime(),planned=scene.switches.last?["durationSeconds"] as? Double ?? -1
            check(planned<0.000001,"R11 unchanged Split fixture has zero prepared duration escape=\(escape): \(planned)")
            check(scene.transitionEnd-began>0.1,"R11 scene deadline includes physical release escape=\(escape)")
            while CACurrentMediaTime()<began+0.07 {scene.frame(CACurrentMediaTime());try await Task.sleep(for:.milliseconds(5))}
            check(scene.settles.count==count,"R11 production auto settle does not truncate the release at 20ms escape=\(escape)")
            while scene.settles.count==count && CACurrentMediaTime()<began+3 {
                scene.frame(CACurrentMediaTime());try await Task.sleep(for:.milliseconds(8))
            }
            check(scene.settles.count==count+1,"R11 actual AutoScene timer eventually settles escape=\(escape)")
            let settled=scene.settles.last ?? 0
            check(settled+0.001>=scene.transitionEnd,"R11 actual settle happens after the entire physical tail escape=\(escape)")
            rows.append(["case":"auto-settle","escape":escape,"preparedDuration":planned,"sceneEnd":scene.transitionEnd,"settled":settled,"began":began])
            scene.fullyFocused=oldFully;scene.disposeTranscriptPresentation()
            check(scene.sceneView.window==nil,"R11 automatic settle stays windowless")
        }
        do {
            let f=Fixture(scale:2,exposure:false),owner=f.all[0].id,second=f.all[1].id
            startRelease(f,owner:owner,second:second)
            DockReviewVerification.frame(f,0.08)
            let me=f.dock.physicalGlassSnapshot.first{$0.id=="me"}!.frame,p=CGPoint(x:me.midX,y:me.midY)
            f.dock.holdMe(at:p)
            let pointer=CGPoint(x:p.x+90,y:p.y-25);f.dock.moveMe(to:pointer)
            f.now += 1/120;f.dock.frame(at:f.now,elapsed:f.now-f.began)
            let actual=f.dock.mePaintedFrame
            check(abs(actual.midX-pointer.x)<0.001 && abs(actual.midY-pointer.y)<0.001,"R11 regrabbed me follows the pointer while other release channels remain active")
            check(abs(actual.width-me.width*1.1)<0.001,"R11 me regrab keeps the normal pickup scale")
        }
        do {
            let f=Fixture(scale:2,exposure:false),owner=f.all[4].id
            let original=f.dock.items[owner]!
            check(original.role == .orb,"R11 capsule owner starts as an Auto orb")
            let autoOrb=original.glass.frame
            f.dock.still=false;_=f.dock.pointer(CGPoint(x:autoOrb.midX,y:autoOrb.midY),now:f.now)
            DockReviewVerification.frame(f,0.8)
            check(original.glass.frame.width>autoOrb.width+1,"R11 source Auto orb is magnified")
            DockReviewVerification.command(f,f.focused(owner));DockReviewVerification.frame(f,1.2)
            f.dock.still=true
            let second=f.focused(owner,segments:2).1[1]
            startRelease(f,owner:owner,second:second)
            DockReviewVerification.frame(f,0.08)
            f.dock.still=false;_=f.dock.pointer(CGPoint(x:autoOrb.midX,y:autoOrb.midY),now:f.now)
            DockReviewVerification.command(f,f.auto());DockReviewVerification.frame(f,0)
            let item=f.dock.items[owner]!,projection=f.dock.hoverProjectionForVerification[item.slot]
            let expected=item.target.adding(projection),target=f.dock.reviewReleaseTarget(f.glass) ?? .zero
            check(expected.width>item.target.width+1,"R11 returning owner has nonzero orb magnification")
            check(MotionStep.edge(target,expected)<0.001,"R11 physical capsule target includes the owner's entire orb projection")
            DockReviewVerification.frame(f,0.1)
            let before=f.dock.physicalGlassSnapshot.first{$0.id=="capsule"}!.logical
            let old=f.dock.hoverProjectionForVerification[item.slot]
            _=f.dock.pointer(CGPoint(x:autoOrb.midX-100,y:autoOrb.midY),now:f.now)
            f.dock.frame(at:f.now,elapsed:f.now-f.began)
            let after=f.dock.physicalGlassSnapshot.first{$0.id=="capsule"}!.logical,new=f.dock.hoverProjectionForVerification[item.slot]
            let actualDelta=CGRect(x:after.origin.x-before.origin.x,y:after.origin.y-before.origin.y,width:after.size.width-before.size.width,height:after.size.height-before.size.height)
            let delta=CGRect(x:new.origin.x-old.origin.x,y:new.origin.y-old.origin.y,width:new.size.width-old.size.width,height:new.size.height-old.size.height)
            check(abs(delta.size.width)>1,"R11 hover target update changes the orb width")
            check(vectorDistance(actualDelta,delta)<0.001,"R11 active capsule release follows updated orb projection in all four components")
        }
        do {
            let f=Fixture(scale:2,exposure:false),owner=f.all[0].id
            DockReviewVerification.command(f,f.focused(owner));DockReviewVerification.frame(f,0.1)
            let epoch=f.dock.capsuleEpochStart,before=f.dock.capsuleLogicalFrame
            f.dock.frame(at:f.now-0.004,elapsed:0.1)
            check(abs(f.dock.capsuleEpochStart-epoch)<0.000000001,"R11 display prediction repair never rewinds a stable injected clock")
            check(MotionStep.edge(before,f.dock.capsuleLogicalFrame)<0.001,"R11 mixed display/injected timestamps preserve the injected pose")
        }
        do {
            let f=Fixture(scale:2,exposure:false),id=f.all[4].id
            DockReviewVerification.frame(f,0)
            let r=f.dock.items[id]!.regular,cap=CGRect(x:r.minX-90,y:r.minY-70,width:260,height:64)
            f.dock.projectPeek(shown:id,open:true,capsule:cap,rows:[:],rowY:cap.maxY+30)
            DockReviewVerification.frame(f,2)
            f.dock.projectPeek(shown:nil,open:false,capsule:cap,rows:[:],rowY:cap.maxY+30)
            let delta=CGRect(x:cap.minX-r.minX,y:cap.minY-r.minY,width:cap.width-r.width,height:cap.height-r.height)
            let reference=RectSpring(from:delta,to:.zero,velocity:.zero,response:0.30,damping:0.90).sample(0.05).velocity
            f.now += 0.05
            let next=f.focused(f.all[0].id),springs=f.dock.springs(to:next.0,order:next.1,at:.infinity,spring:(0.4,0.82))
            let actual=springs[id]!.sample(0).velocity
            check(reference.size.width < -1 && reference.size.height < -1,"R11 Peek takeover fixture is shrinking in both dimensions")
            check(vectorDistance(actual,reference)<0.001,"R11 Peek takeover preserves all four signed velocity components")
            rows.append(["case":"peek-velocity","actual":[actual.origin.x,actual.origin.y,actual.size.width,actual.size.height],"expected":[reference.origin.x,reference.origin.y,reference.size.width,reference.size.height]])
        }
        check(NSApp.windows.allSatisfy{!$0.isVisible},"R11 checks show no visible window")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("followup.json"))
    }
    /// Replays release -> Auto -> Peek through the full production display callback.
    static func peekRelease(to output: URL, check: (Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for exposure in [false,true] { for delay in [0.025,0.10] {
            let f=Fixture(scale:2,exposure:exposure),owner=f.all[0].id,id=f.all[4].id
            startRelease(f,owner:owner,second:f.all[1].id)
            DockReviewVerification.frame(f,0.06)
            DockReviewVerification.command(f,f.auto())
            let dt=1.0/120
            DockReviewVerification.frame(f,delay)
            let item=f.dock.items[id]!,previous=item.glass.frame
            DockReviewVerification.frame(f,delay+dt)
            let source=item.glass.frame,regular=item.regular
            func difference(_ a:CGRect,_ b:CGRect,_ divisor:Double=1)->CGRect {
                CGRect(x:(a.origin.x-b.origin.x)/divisor,y:(a.origin.y-b.origin.y)/divisor,
                    width:(a.size.width-b.size.width)/divisor,height:(a.size.height-b.size.height)/divisor)
            }
            let velocity=difference(source,previous,dt)
            let from=difference(source,regular),relativeVelocity=velocity
            let capsule=CGRect(x:regular.minX-90,y:regular.minY-70,width:260,height:64),target=difference(capsule,regular)
            let tag="R12 exposure=\(exposure) delay=\(delay)"
            check(item.role == .orb,tag+" uses an overflow orb")
            check(f.dock.reviewReleaseTarget(item.glass) != nil,tag+" starts with a live physical release")
            let neighbor=f.dock.items[f.all[1].id]!.glass
            check(f.dock.reviewReleaseTarget(neighbor) != nil,tag+" has a separate neighbor release")
            f.dock.projectPeek(shown:id,open:true,capsule:capsule,rows:[:],rowY:capsule.maxY+30)
            check(f.dock.reviewReleaseTarget(item.glass) == nil,tag+" Peek owns its glass after takeover")
            check(f.dock.reviewReleaseTarget(neighbor) != nil,tag+" leaves the neighbor release intact")
            f.dock.frame(at:f.now,elapsed:f.now-f.began)
            check(MotionStep.edge(source,item.glass.frame)<0.001,tag+" first native frame is continuous")
            check(vectorDistance(source,item.motion.rect ?? .zero)<0.001,tag+" first logical frame adopts the last native frame")
            let extent=Double(max(abs(from.size.width),abs(from.size.height),abs(target.size.width),abs(target.size.height),1))
            let e=min(Spring.restEpsilon,0.002*extent)
            let springs=[Spring(from:from.origin.x,to:target.origin.x,velocity:relativeVelocity.origin.x,response:0.38,damping:0.78,epsilon:e),
                Spring(from:from.origin.y,to:target.origin.y,velocity:relativeVelocity.origin.y,response:0.38,damping:0.78,epsilon:e),
                Spring(from:from.size.width,to:target.size.width,velocity:relativeVelocity.size.width,response:0.38,damping:0.78,epsilon:e),
                Spring(from:from.size.height,to:target.size.height,velocity:relativeVelocity.size.height,response:0.38,damping:0.78,epsilon:e)]
            var last=source,maxNative:CGFloat=0,maxLogical:CGFloat=0
            for k in 1...24 {
                let t=Double(k)*dt
                DockReviewVerification.frame(f,delay+dt+t)
                let d=springs.map{$0.sample(t).value},r=regular
                let logical=CGRect(x:r.origin.x+d[0],y:r.origin.y+d[1],width:r.size.width+d[2],height:r.size.height+d[3])
                let expected=M10DockMotion.frame(name:"reference",now:logical,earlier:last,time:f.now,profile:M10DockMotion.dell,enabled:exposure)
                let logicalError=vectorDistance(item.motion.rect ?? .zero,logical),nativeError=MotionStep.edge(item.glass.frame,expected.painted)
                maxLogical=max(maxLogical,logicalError);maxNative=max(maxNative,nativeError)
                check(logicalError<0.001,tag+" signed source velocity drives logical frame \(k)")
                check(nativeError<0.001,tag+" full frame keeps Peek paint at frame \(k)")
                last=logical
            }
            for k in 25...360 {DockReviewVerification.frame(f,delay+dt+Double(k)*dt)}
            check(MotionStep.edge(item.glass.frame,capsule)<0.001,tag+" final native destination equals the requested capsule")
            check(vectorDistance(item.motion.rect ?? .zero,capsule)<0.001,tag+" final logical destination equals the requested capsule")
            rows.append(["exposure":exposure,"delay":delay,"maxLogicalError":maxLogical,"maxNativeError":maxNative,
                "finalDestinationError":MotionStep.edge(item.glass.frame,capsule),
                "sourceVelocity":[velocity.origin.x,velocity.origin.y,velocity.size.width,velocity.size.height]])
        } }
        try heldPreview(check:check)
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("peek-release.json"))
    }
    static func heldPreview(check: (Bool,String)->Void) throws {
        for exposure in [false,true] { for kind in ["item","identity","me"] {
            let f=Fixture(scale:2,exposure:exposure),owner=f.all[0].id,second=f.all[1].id,id=f.all[4].id
            startRelease(f,owner:owner,second:second)
            DockReviewVerification.frame(f,0.04)
            if kind != "identity" {
                DockReviewVerification.command(f,f.auto());DockReviewVerification.frame(f,0.03)
                let r=f.dock.items[id]!.regular
                f.dock.projectPeek(shown:id,open:true,capsule:CGRect(x:r.minX-80,y:r.minY-65,width:260,height:64),rows:[:],rowY:r.maxY+30)
                DockReviewVerification.frame(f,0.04)
            }
            let glass:NSGlassEffectView
            if kind == "me" {
                let container=f.host.subviews.compactMap{$0 as? NSGlassEffectContainerView}.first!
                glass=container.contentView!.subviews.compactMap{$0 as? NSGlassEffectView}.first{$0 !== f.glass && $0.frame == f.dock.mePaintedFrame}!
                f.dock.holdMe(at:CGPoint(x:glass.frame.midX,y:glass.frame.midY))
            } else {
                let heldID=kind == "identity" ? second:id,item=f.dock.items[heldID]!
                glass=kind == "identity" ? item.identity!.glassView:item.glass
                f.dock.hold(heldID,at:CGPoint(x:glass.frame.midX,y:glass.frame.midY),now:f.now,spring:(0.3,0.8))
            }
            let pointer=CGPoint(x:glass.frame.midX+70,y:glass.frame.midY-20)
            if kind == "me" {f.dock.moveMe(to:pointer)} else {f.dock.moveHeld(to:pointer)}
            f.now += 1/120;f.dock.frame(at:f.now,elapsed:f.now-f.began)
            let tag="R13 preview held \(kind) exposure=\(exposure)"
            check(f.dock.reviewReleaseTarget(glass)==nil,tag+" grab removes its old release")
            let neighbor=f.dock.items[owner]!.glass
            check(f.dock.reviewReleaseTarget(neighbor) != nil,tag+" has a live neighbor continuation")
            var next=(f.layout,f.order);next.1.swapAt(4,5)
            DockReviewVerification.command(f,next)
            check(f.dock.reviewReleaseTarget(glass)==nil,tag+" preview never reinstalls a held release")
            check(f.dock.reviewReleaseTarget(neighbor) != nil,tag+" preview preserves neighbor release")
            f.now += 1/120;f.dock.frame(at:f.now,elapsed:f.now-f.began)
            let raw=f.dock.reviewRawFrame(glass)
            check(raw != nil && MotionStep.edge(glass.frame,raw ?? .zero)<0.001,tag+" final native glass keeps pointer paint")
        } }
    }
    /// Preparation and dismissal must never turn a world Peek pose into an unrebased local spring.
    static func peekCoordinates(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for exposure in [false,true] { for focused in [false,true] {
            let f=Fixture(scale:2,exposure:exposure),owner=f.all[0].id,id=f.all[4].id
            f.dock.still=false
            let orb=f.dock.items[id]!.glass.frame
            _=f.dock.pointer(CGPoint(x:orb.midX,y:orb.midY),now:f.now)
            DockReviewVerification.frame(f,0.8)
            startRelease(f,owner:owner,second:f.all[1].id)
            DockReviewVerification.frame(f,0.04);DockReviewVerification.command(f,f.auto());DockReviewVerification.frame(f,0.04)
            let item=f.dock.items[id]!,regular=item.regular,until=f.dock.reviewReleaseEnd(item.glass) ?? f.now
            let home=item.target.adding(f.dock.hoverProjectionForVerification[item.slot])
            let capsule=CGRect(x:home.minX,y:regular.minY-160,width:home.width,height:64)
            let tag="R14 exposure=\(exposure) focused=\(focused)"
            check(until>f.now+0.05,tag+" fixture has a live protected release")
            check(f.dock.rise>1,tag+" fixture has nonzero rise")
            let projection=f.dock.hoverProjectionForVerification[item.slot]
            check(abs(projection.origin.x)+abs(projection.origin.y)+abs(projection.size.width)>1,tag+" fixture has nonzero orb projection")
            var requests=0
            f.dock.onNeedsFramesUntil={_ in requests += 1}
            f.dock.projectPeek(shown:id,open:true,capsule:capsule,rows:[:],rowY:capsule.maxY+30)
            check(f.dock.reviewPeekAnchor(id) != nil,tag+" anchor exists during the protected release")
            let end=until-f.began
            for k in 1...Int(ceil((end+0.02-0.04)*120)) {DockReviewVerification.frame(f,0.04+Double(k)/120)}
            check(f.dock.reviewPeekAnchor(id)==nil,tag+" first callbacks after release end leave no anchor")
            check(requests>0,tag+" relative conversion schedules its remaining tail")
            for k in 1...240 {DockReviewVerification.frame(f,end+0.03+Double(k)/120)}
            check(MotionStep.edge(item.glass.frame,capsule)<0.001,tag+" relative Peek still lands at the requested capsule")
            f.dock.settleContent(full:[owner])
            check(f.dock.reviewReleaseEnd(item.glass)==nil,tag+" settle clears the old physical channel")
            check(f.dock.reviewPeekAnchor(id)==nil,tag+" settle retains only orb-relative bud state")
            let source=item.motion.rect ?? item.glass.frame,oldDelta=f.dock.hoverProjectionForVerification[item.slot]
            var next=focused ? f.focused(owner):f.auto()
            if !focused {next.1.swapAt(4,5)}
            // Match AutoScene: prepare first, dismiss second, then snapshot and commit.
            let prepared=f.dock.springs(to:next.0,order:next.1,at:f.now-f.began,spring:(0.4,0.82))
            let local=prepared[id]!.sample(0).rect
            check(MotionStep.edge(local.adding(oldDelta),source)<0.001,tag+" prepared spring uses current role-local coordinates")
            f.dock.projectPeek(shown:nil,open:false,capsule:.zero,rows:[:],rowY:0)
            f.dock.transitionEpoch=f.dock.makeTransitionEpoch(at:f.now)
            f.dock.transition(to:next.0,order:next.1,full:Set(next.1.prefix(next.0.bars.count)),springs:prepared,duration:prepared.values.map(\.duration).max() ?? 0)
            f.layout=next.0;f.order=next.1;f.began=f.now;f.dock.frame(at:f.now,elapsed:0)
            let logicalError=vectorDistance(item.motion.rect ?? .zero,source),nativeError=MotionStep.edge(item.glass.frame,source)
            check(logicalError<0.001,tag+" commit applies the new projection exactly once")
            check(nativeError<0.001,tag+" next layout first native frame is continuous")
            check(f.dock.reviewPeekAnchor(id)==nil,tag+" layout takeover removes all anchored state")
            rows.append(["exposure":exposure,"focused":focused,"logicalError":logicalError,"nativeError":nativeError,"rise":f.dock.rise,"protectedUntil":until])
        } }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("peek-coordinates.json"))
    }
    /// A fake display link drives the real SceneClock Objective-C callback and pause decision.
    private final class DisplayTarget: NSObject {
        @objc var timestamp=0.0
        @objc var targetTimestamp=0.0
        @objc var isPaused=false
        @objc(setPaused:) func setPaused(_ value:Bool) {isPaused=value}
    }
    static func releaseCoordinates(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for reorder in [false,true] {
            let f=Fixture(scale:2,exposure:false),id=f.all[0].id
            f.dock.still=false;f.dock.editing=true
            DockReviewVerification.frame(f,1)
            let item=f.dock.items[id]!,r=item.glass.frame
            f.dock.hold(id,at:CGPoint(x:r.midX,y:r.minY),now:f.now,spring:(0.3,0.8))
            f.dock.moveHeld(to:CGPoint(x:r.midX+35,y:700))
            f.now += 0.2;f.dock.frame(at:f.now,elapsed:f.now-f.began)
            let world=item.motion.rect ?? item.glass.frame
            check(f.dock.rise>1,"R15 ordinary release has nonzero rise")
            check(f.dock.glassReleaseSettles==0,"R15 ordinary release has no physical continuation")
            f.dock.release()
            var next=f.auto();if reorder {next.1.swapAt(0,1)}
            let prepared=f.dock.springs(to:next.0,order:next.1,at:f.now-f.began,spring:(0.4,0.82))
            f.dock.transitionEpoch=f.dock.makeTransitionEpoch(at:f.now)
            f.dock.transition(to:next.0,order:next.1,full:[f.all[0].id],springs:prepared,duration:prepared.values.map(\.duration).max() ?? 0)
            f.began=f.now;f.layout=next.0;f.order=next.1;f.dock.frame(at:f.now,elapsed:0)
            let error=MotionStep.edge(item.motion.rect ?? .zero,world)
            check(error<0.001,"R15 ordinary release first logical frame preserves world pose reorder=\(reorder): \(error)")
            rows.append(["reorder":reorder,"rise":f.dock.rise,"beforeY":world.minY,"afterY":item.motion.rect?.minY ?? -1,"error":error])
        }
        do {
            let f=Fixture(scale:2,exposure:false),id=f.all[1].id
            f.dock.still=false;f.dock.editing=true
            DockReviewVerification.command(f,f.focused(f.all[0].id,segments:2));DockReviewVerification.frame(f,1)
            let item=f.dock.items[id]!,r=item.identityFrame
            f.dock.hold(id,at:CGPoint(x:r.midX,y:r.midY),now:f.now,spring:(0.3,0.8))
            f.dock.moveHeld(to:CGPoint(x:r.midX-30,y:r.midY-15));f.now += 0.15;f.dock.frame(at:f.now,elapsed:f.now-f.began)
            let world=item.identityFrame
            check(f.dock.rise>1,"R15 identity release has nonzero rise")
            f.dock.release();var next=f.auto();next.1.swapAt(1,4)
            DockReviewVerification.command(f,next);DockReviewVerification.frame(f,0)
            let source=item.spring.sample(0).rect.adding(f.dock.hoverProjectionForVerification[item.slot])
            let error=MotionStep.edge(source,world)
            check(error<0.001,"R15 released identity becomes an orb from its world pose: \(error)")
            rows.append(["case":"identity-to-orb","rise":f.dock.rise,"error":error])
        }
        do {
            let f=Fixture(scale:2,exposure:false),id=f.all[4].id
            f.dock.still=false;f.dock.editing=true;DockReviewVerification.frame(f,0.8)
            startRelease(f,owner:f.all[0].id,second:f.all[1].id)
            DockReviewVerification.frame(f,0.04);DockReviewVerification.command(f,f.auto());DockReviewVerification.frame(f,0.04)
            let item=f.dock.items[id]!,until=f.dock.reviewReleaseEnd(item.glass)!,home=item.regular
            let clock=SceneClock(),link=DisplayTarget(),lead=1.0/60
            var deadline=0.0,callbackTime=0.0
            f.dock.onNeedsFramesUntil={end in deadline=end;clock.run(until:end)}
            // Reproduce the old receiver's wall time, one display prediction behind the spring epoch.
            f.dock.onNeedsFrames={duration in clock.run(until:callbackTime-lead+duration)}
            f.dock.projectPeek(shown:id,open:true,capsule:home.offsetBy(dx:0,dy:-160),rows:[:],rowY:home.minY-80)
            callbackTime=until+0.001;f.now=callbackTime
            f.dock.frame(at:f.now,elapsed:f.now-f.began)
            check(deadline>callbackTime,"R15 relative conversion supplies an absolute deadline")
            let duration=RectSpring(from:.zero,to:CGRect(x:1,y:1,width:1,height:1),response:0.38,damping:0.78).duration
            let end=deadline>0 ? deadline:callbackTime+duration
            link.targetTimestamp=end-lead/2;link.timestamp=link.targetTimestamp-lead
            _=clock.perform(NSSelectorFromString("tick:"),with:link)
            check(!link.isPaused,"R15 real SceneClock stays running inside the final predicted-display interval")
            link.targetTimestamp=end+lead;link.timestamp=link.targetTimestamp-lead
            _=clock.perform(NSSelectorFromString("tick:"),with:link)
            check(link.isPaused,"R15 real SceneClock pauses after the absolute tail deadline")
            rows.append(["case":"scene-clock","deadline":deadline,"began":callbackTime])
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("release-coordinates.json"))
    }
    static func vectorDistance(_ a:CGRect,_ b:CGRect)->CGFloat {
        max(abs(a.origin.x-b.origin.x),abs(a.origin.y-b.origin.y),abs(a.size.width-b.size.width),abs(a.size.height-b.size.height))
    }
}
#endif
