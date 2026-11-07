#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Ninth-round wiring checks use physical views and independent source snapshots.
@MainActor enum DockReviewVerification {
    typealias Fixture = DockCapsuleVerification.Fixture
    static func command(_ f: Fixture, _ next: (AutoLayout,[String])) {
        let springs=f.dock.springs(to:next.0,order:next.1,at:f.now-f.began,spring:(0.4,0.82))
        f.dock.transitionEpoch=f.dock.makeTransitionEpoch(at:f.now)
        f.dock.transition(to:next.0,order:next.1,full:Set(next.1.prefix(next.0.bars.count)),springs:springs,duration:springs.values.map(\.duration).max() ?? 0)
        f.layout=next.0;f.order=next.1;f.began=f.now
    }
    static func frame(_ f: Fixture, _ t: Double) {
        f.now=f.began+t;f.dock.frame(at:f.now,elapsed:t)
    }
    static func run(to output: URL, check: (Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for direct in [false,true] {
            let f=Fixture(scale:2,exposure:false), owner=f.all[0].id, second=f.all[1].id
            if !direct {command(f,f.focused(owner));frame(f,1.2)}
            check(f.dock.items[second]!.identity == nil,"R9 first identity fixture has no previous carrier")
            let incoming=f.dock.items[second]!
            let next=f.focused(owner,segments:2)
            let target=next.0.bars[1],diameter=next.0.me.width
            let source=incoming.role == .orb ? incoming.motion.rect! : CGRect(x:target.maxX-target.height/2-diameter/2,y:target.midY-diameter/2,width:diameter,height:diameter)
            command(f,next)
            for k in 0...16 {
                frame(f,Double(k)/240)
                let item=f.dock.items[second]!, identity=item.identity!
                check(item.identityFrame.minY>680 && identity.glassView.frame.minY>680,
                      "R9 new Split identity stays on Dock row direct=\(direct) frame=\(k): \(item.identityFrame)")
                if k==0 {check(MotionStep.edge(item.identityFrame,source)<0.001,"R9 first Split identity inherits the retained orb source")}
                rows.append(["case":"first-identity","direct":direct,"frame":k,"logical":DockFrameLog.rect(item.identityFrame),"native":DockFrameLog.rect(identity.glassView.frame),"alpha":identity.glassView.alphaValue])
                if k==8 {
                    let image=NativeViewBitmap.capture(f.host,scale:2)
                    try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("first-identity-\(direct).png"))
                }
            }
            check(f.dock.physicalGlassSnapshot.contains{$0.id=="identity."+second},"R9 physical path actually contains a Split identity")
            check(f.host.window == nil,"R9 detached fixture makes no native backing-scale claim")
        }
        for fullFrame in [false,true] {
            let f=Fixture(scale:2,exposure:true),owner=f.all[0].id
            command(f,f.focused(owner,segments:2));frame(f,1.2)
            command(f,f.auto());frame(f,0.07)
            let before=Dictionary(uniqueKeysWithValues:f.dock.physicalGlassSnapshot.map{($0.id,$0)})
            let fades=f.dock.reviewFades
            f.now -= 5000
            if fullFrame {f.dock.frame(at:f.now,elapsed:0.07)}
            else {f.dock.hoverFrame(at:f.now);f.dock.sample(0.07)}
            for part in f.dock.physicalGlassSnapshot {
                guard let old=before[part.id] else {continue}
                check(MotionStep.edge(old.logical,part.logical)<0.001,"R9 rewind preserves all logical channels \(part.id), fullFrame=\(fullFrame)")
                check(MotionStep.edge(old.frame,part.frame)<0.001,"R9 rewind preserves all painted channels \(part.id), fullFrame=\(fullFrame)")
            }
            for (id,value) in f.dock.reviewFades {
                check(abs(value-(fades[id] ?? value))<0.0001,"R9 rewind preserves fade \(id), fullFrame=\(fullFrame)")
            }
        }
        do {
            let f=Fixture(scale:2,exposure:false),owner=f.all[0].id,second=f.all[1].id
            f.dock.still=false
            let orb=f.dock.items[f.all[4].id]!.glass.frame
            _=f.dock.pointer(CGPoint(x:orb.midX,y:orb.midY),now:f.now)
            f.began=f.now;frame(f,0.8)
            command(f,f.focused(owner,segments:2));frame(f,1.2)
            f.dock.still=true;frame(f,1.3)
            let before=f.dock.items[second]!.identityFrame
            check(f.dock.rise==0,"R9 identity rebase fixture starts Fully Focused")
            f.dock.still=false
            command(f,f.auto());frame(f,0)
            check(f.dock.rise>10,"R9 identity rebase fixture restores hover rise")
            check(MotionStep.edge(before,f.dock.items[second]!.identityFrame)<0.001,"R9 existing identity keeps its world source when rise changes")
        }
        do {
            let f=Fixture(scale:2,exposure:false)
            frame(f,0)
            let me=f.dock.physicalGlassSnapshot.first{$0.id=="me"}!.frame
            let glass=f.host.subviews.compactMap{$0 as? NSGlassEffectContainerView}.first!.contentView!.subviews.compactMap{$0 as? NSGlassEffectView}.first{$0.frame==me}!
            f.dock.holdMe(at:CGPoint(x:me.midX,y:me.midY))
            for k in 0...12 {
                f.dock.moveMe(to:CGPoint(x:me.midX+CGFloat(k)/2,y:me.midY))
                frame(f,Double(k)/240)
                let raw=f.dock.reviewRawFrame(glass)!
                check(MotionStep.edge(raw,glass.frame)<0.001,"R9 held me retains raw painted bounds \(k)")
            }
        }
        do {
            let f=Fixture(scale:2,exposure:false),owner=f.all[0].id,second=f.all[1].id
            command(f,f.focused(owner,segments:2));frame(f,1.2)
            let item=f.dock.items[second]!,identity=item.identity!,other=f.dock.items[f.all[2].id]!.glass.frame
            f.dock.hold(second,at:CGPoint(x:item.identityFrame.midX,y:item.identityFrame.midY),now:f.now,spring:(0.3,0.8))
            let zero=f.now
            for k in 0...24 {
                f.now=zero+0.5+Double(k)/240
                f.dock.moveHeld(to:CGPoint(x:other.minX-24-8-CGFloat(k)/3,y:other.midY))
                f.dock.frame(at:f.now,elapsed:f.now-f.began)
                let raw=f.dock.reviewRawFrame(identity.glassView)!
                check(MotionStep.edge(raw,identity.glassView.frame)<0.001,"R9 held Split identity retains raw painted bounds \(k)")
            }
        }
        // These event entry points must not publish raw glass before the final projection.
        do {
            let f=Fixture(scale:2,exposure:true),owner=f.all[0].id
            command(f,f.focused(owner));frame(f,1.2);command(f,f.auto());frame(f,0.15)
            let bar=f.dock.items[owner]!.glass
            f.dock.resetReviewWrites()
            f.dock.hoverGrip(CGPoint(x:bar.frame.midX,y:bar.frame.minY))
            check(f.dock.items.values.allSatisfy{f.dock.reviewWriteCount($0.glass)==1},"R9 hoverGrip applies one final glass write")
            f.dock.resetReviewWrites();f.dock.settleContent(full:[owner])
            check(f.dock.items.values.allSatisfy{f.dock.reviewWriteCount($0.glass)==1},"R9 settleContent applies one final glass write")
        }
        // A release inherits the last native glass poses, including the painted shutter.
        for exposure in [false,true] {
            let f=Fixture(scale:2,exposure:exposure),owner=f.all[0].id,second=f.all[1].id
            command(f,f.focused(owner,segments:2));frame(f,1.2)
            let item=f.dock.items[second]!, start=item.identityFrame
            f.dock.hold(second,at:CGPoint(x:start.midX,y:start.midY),now:f.now,spring:(0.3,0.8))
            f.dock.heldFrame(at:f.now)
            var previous=item.identity!.glassView.frame
            for k in 1...6 {
                previous=item.identity!.glassView.frame
                f.now += 1/120
                f.dock.moveHeld(to:CGPoint(x:start.midX+CGFloat(k)*10,y:start.midY-30))
                f.dock.frame(at:f.now,elapsed:f.now-f.began)
            }
            let before=Dictionary(uniqueKeysWithValues:f.dock.physicalGlassSnapshot.map{($0.id,$0)})
            let actual=item.identity!.glassView.frame
            let velocity=CGRect(x:(actual.origin.x-previous.origin.x)*120,y:(actual.origin.y-previous.origin.y)*120,
                width:(actual.size.width-previous.size.width)*120,height:(actual.size.height-previous.size.height)*120)
            f.dock.release()
            command(f,f.focused(owner));frame(f,0)
            for part in f.dock.physicalGlassSnapshot {
                if let old=before[part.id] {
                    check(MotionStep.edge(old.frame,part.frame)<0.001,"R10 release native boundary is continuous \(part.id), exposure=\(exposure)")
                }
            }
            let v=f.dock.reviewReleaseVelocity(item.identity!.glassView) ?? item.identitySpring.sample(0).velocity
            check(max(abs(v.origin.x-velocity.origin.x),abs(v.origin.y-velocity.origin.y),abs(v.size.width-velocity.size.width),abs(v.size.height-velocity.size.height))<0.001,
                "R10 release retains measured signed native velocity, exposure=\(exposure)")
            check(MotionStep.edge(f.dock.physicalGlassSnapshot.first{$0.id=="identity."+second}!.logical,actual)<0.001,"R10 identity spring starts at the last painted shape, exposure=\(exposure)")
            for k in 1...30 {
                frame(f,Double(k)/120)
                check(f.dock.topologyFinalResidual<0.00001,"R10 release whole-frame residual \(k), exposure=\(exposure)")
                if k==1 {check(MotionStep.edge(item.identity!.glassView.frame,actual)>0.001,"R10 release advances on its next frame without a paint hold")}
            }
        }
        for name in ["empty","filtered"] {
            let path=output.appendingPathComponent("replay-\(name).jsonl")
            try (name=="empty" ? "":"{\"transitionSerial\":99,\"targetTimestamp\":1}\n").write(to:path,atomically:true,encoding:.utf8)
            var rejected=false
            _=try DockGlassBatchVerification.replay(path:path.path,scale:1){value,_ in if !value {rejected=true}}
            check(rejected,"R9 rejects \(name) replay with zero valid callbacks")
        }
        try JSONSerialization.data(withJSONObject:["identityFrames":rows,"nativeGlassBackingVerified":false,"scope":"Detached point geometry; real 1x/2x glass backing requires window verification."],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("review-frames.json"))
        check(NSApp.windows.allSatisfy{!$0.isVisible},"R9 checks display no window")
    }
}
#endif
