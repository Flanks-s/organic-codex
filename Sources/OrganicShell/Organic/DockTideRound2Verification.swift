#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

@MainActor enum DockTideRound2Verification {
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        let boardRows:[[String:Any]]
        if let path=ProcessInfo.processInfo.environment["TIDE_BOARD_TRACE"] {boardRows=(try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as? [[String:Any]]) ?? []}
        else {boardRows=[]}
        var traces:[[String:Any]]=[]
        for (x,lean,target) in [(922.0,26.0,948.75),(653.0,54.0,692.25)] {
            let c=TideContour(body:CGRect(x:x,y:746,width:36,height:36),tailAmount:1,lean:lean)
            let end=c.tail.map{$0.rect.maxX}.max() ?? x
            check(abs(end-target)<=1,"physical tip follows the rendered board; native screen confirmation required")
            check((c.tail.first?.radius ?? 0)>=5.5 && (c.tail.first?.radius ?? 10)<6.8,"R3 compensates the oversized native root reported in R2")
            check(c.parts.count<30,"goo-erased end is not a dense 23-disc rod")
        }
        for count in [6,9] {for scale:CGFloat in [1,2] {for hz in [60.0,120.0] {
            let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
            
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:M10DockMotion.dell,scale:scale)
            scene.restOnSnapshot=true;scene.ambient=false;scene.manualSettle=true;scene.install(members:store.conversations.map(\.id))
            scene.dock.setTideCapacityFixture(count==9 ? 461:nil)
            var now=VerificationClock.modelOrigin
            scene.now={now};scene.dock.motionTime={now}
            scene.dock.prepareTideMaterialNow()
            let target=scene.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.first!.id
            let begin=now,tag="\(count) \(scale)x \(hz)Hz"
            store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":.string(target),"turn":["id":"tide-round2"]]))
            store.apply(.init(id:2,time:10,method:"item/started",params:["threadId":.string(target),"turnId":"tide-round2","item":["id":"cmd","type":"commandExecution","command":"swift build -c release"]]))
            check(scene.dock.tideProbe["owner"] as? String == target,"Core event immediately enters Tide: "+tag)
            var minimum=Double.infinity,worst="",sampleRows:[[String:Any]]=[]
            var milestones=Array([0.0,0.05,0.07,0.09,0.13,0.19,0.30,0.60,1,2,5,8.5,8.57,8.66,8.73,9.3,10.5].enumerated())
            for frame in 0...Int(10.5*hz) {
                let offset=Double(frame)/hz;now=begin+offset
                if frame==Int(hz*2) {
                    store.apply(.init(id:3,time:12,method:"item/completed",params:["threadId":.string(target),"turnId":"tide-round2","item":["id":"cmd","type":"commandExecution","command":"swift build -c release"]]))
                }
                scene.dock.frame(at:now,elapsed:.infinity)
                let probe=scene.dock.tideProbe
                if let gap=probe["minimumGap"] as? Double,gap>0 {if gap<minimum {minimum=gap;worst="\(offset): \(probe["worstPair"] ?? "")"}}
                if let first=milestones.first,offset+1e-8>=first.element {
                    var row=probe;row["plannedOffset"]=first.element;row["actualOffset"]=offset;sampleRows.append(row);milestones.removeFirst()
                }
                if frame==Int(hz*0.05) {
                    let bubbles=probe["bubbles"] as? [[String:Any]] ?? []
                    let c=bubbles.first(where:{$0["id"] as? String == "C"})
                    if count==6 {
                        let raw=c?["raw"] as? [CGFloat] ?? []
                        check(raw.count==4 && abs(raw[2]-133.35653833526894)<0.01,"shared 240 Hz width matches board at +.05: "+tag)
                    } else {check(abs((c?["lean"] as? Double ?? 0)-26)<0.001,"C inclination waits until +.09: "+tag)}
                }
                if frame==Int(hz*2) {
                    check(abs((probe["eventRemaining"] as? Double ?? 0)-2.4)<0.001,"new event does not consume time preceding arrival: "+tag)
                }
                if frame==Int(hz*8.5) {
                    check((probe["occupancyRemaining"] as? Double ?? 1)<0.01,"occupancy reaches its independent boundary: "+tag)
                }
                if frame==Int(hz*0.25) {
                    let bubbles=probe["bubbles"] as? [[String:Any]] ?? []
                    check(bubbles.allSatisfy{($0["tail"] as? Double ?? 1)==0},"tail never starts before +.30: "+tag)
                }
                if frame==Int(hz) {
                    check(probe["level"] as? Int == (count==6 ? 1:2),"real capacity chooses room1/room2: "+tag)
                    let shapes=(probe["material"] as? [String:Any])?["shapes"] as? [[String:Any]] ?? []
                    check(shapes.count == (count==6 ? 1:2),"retained native tails reach requested capacity: "+tag)
                    check(shapes.allSatisfy{($0["shadowOpacity"] as? Float ?? 0)>0.24},"borrowed native body/tail has board shadow: "+tag)
                }
                if frame==Int(hz*5.2) {
                    check((probe["eventRemaining"] as? Double ?? -1)==0 && (probe["occupancyRemaining"] as? Double ?? 0)>3,"event expires before occupancy: "+tag)
                }
            }
            if let startReturn=sampleRows.first(where:{($0["plannedOffset"] as? Double)==8.5}) {
                check(startReturn["phase"] as? String == "holding","board retains the 8.5 boundary until its next 240 Hz tick: "+tag)
            }
            if let beforeReturn=sampleRows.first(where:{($0["plannedOffset"] as? Double)==5}) {
                check(beforeReturn["phase"] as? String == "holding","event expiry alone does not restore the brief: "+tag)
            }
            check(minimum.isFinite && minimum>=12-0.001,"every dynamic physical owner clears 12 pt: \(tag), \(minimum), \(worst)")
            check(scene.dock.tideProbe["phase"] as? String == "idle","natural return completes through production frame: "+tag)
            check((scene.dock.tideMaterialProbe["shapes"] as? [[String:Any]])?.isEmpty == true,"return disposes tail parts: "+tag)
            var boardRectError=0.0,boardTailError=0.0,boardLeanError=0.0,matched=0
            if !boardRows.isEmpty {
                for sample in sampleRows {
                    guard let at=sample["actualOffset"] as? Double,
                          let reference=boardRows.first(where:{$0["case"] as? String == (count==6 ? "room1":"room2") && abs(($0["t"] as? Double ?? -1)-at)<1e-7}),
                          let expected=reference["bubbles"] as? [[String:Any]] else{continue}
                    for b in sample["bubbles"] as? [[String:Any]] ?? [] {
                        guard let e=expected.first(where:{$0["id"] as? String == b["id"] as? String}),let raw=b["raw"] as? [CGFloat],let want=e["raw"] as? [Double] else{continue}
                        let rect=[want[0],764-want[2]/2,max(36,want[1]),want[2]]
                        boardRectError=max(boardRectError,zip(raw,rect).map{abs(Double($0.0)-$0.1)}.max() ?? 0)
                        boardTailError=max(boardTailError,abs((b["tail"] as? Double ?? 0)-(e["tail"] as? Double ?? 0)))
                        boardLeanError=max(boardLeanError,abs((b["lean"] as? Double ?? 0)-(e["lean"] as? Double ?? 0)));matched+=1
                    }
                }
                check(matched>0 && boardRectError<0.01,"same-time raw bubble geometry matches rendered board clock: "+tag)
                check(matched>0 && boardTailError<0.00001,"same-time tail spring matches board clock: "+tag)
                check(matched>0 && boardLeanError<0.00001,"same-time inclination matches board clock: "+tag)
            }
            traces.append(["boardRectError":boardRectError,"boardTailError":boardTailError,"boardLeanError":boardLeanError,"tag":tag,"minimumGap":minimum.isFinite ? minimum:0,"samples":sampleRows]);scene.disposeTranscriptPresentation()
        }}}
        let parkedStore=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        let parkedScene=AutoScene(size:CGSize(width:1280,height:820),store:parkedStore,profile:M10DockMotion.dell,scale:2)
        parkedScene.restOnSnapshot=true;parkedScene.manualSettle=true;parkedScene.scheme.parked=["D"];parkedScene.install(members:MockSeed.windowMembers)
        parkedStore.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"D","turn":["id":"parked"]]))
        check(parkedScene.dock.tideProbe["phase"] as? String == "idle","parked Auto orb never expands into Tide")
        parkedScene.disposeTranscriptPresentation()
        try protection(to:output,check:check)
        try JSONSerialization.data(withJSONObject:traces,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round2-traces.json"))
        check(NSApp.windows.allSatisfy{!$0.isVisible},"round2 verification opens no visible windows")
    }
    static func protection(to output:URL,check:(Bool,String)->Void) throws {
        for kind in ["space","attachment","focus","marked","chooser","submission","hover"] {
            let f=DockCapsuleVerification.Fixture(scale:2,exposure:false)
            let c=f.all[2],target=f.all[3],r=f.dock.restingTargets.first{$0.id==c.id}!.rect
            let editor=NativeComposer();f.dock.items[c.id]!.composer=editor
            if kind=="space" {c.draft="   "}
            if kind=="attachment" {editor.hasAttachments=true}
            if kind=="focus" {f.dock.focusTarget=c.id}
            if kind=="marked" {editor.textView.setMarkedText("候",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
            if kind=="chooser" {editor.onChooseAttachments={_ in};editor.chooseAttachments()}
            if kind=="submission" {c.sending=true}
            if kind=="hover" {_=f.dock.pointer(CGPoint(x:r.midX,y:r.midY),now:f.now)}
            f.store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":.string(target.id),"turn":["id":"protected"]]))
            f.dock.receiveTide(target)
            f.now+=1;f.dock.frame(at:f.now,elapsed:.infinity)
            check(f.dock.tideProbe["level"] as? Int == 0,"production protection refuses \(kind)")
            check(abs(f.dock.items[c.id]!.glass.frame.width-r.width)<0.01 && abs(f.dock.items[c.id]!.glass.frame.height-r.height)<0.01,"protected retained bar stays full width: \(kind)")
        }
        let hoverFixture=DockCapsuleVerification.Fixture(scale:2,exposure:false)
        let active=hoverFixture.all[3],borrowed=hoverFixture.all[2]
        hoverFixture.store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":.string(active.id),"turn":["id":"hover-owner"]]))
        hoverFixture.dock.receiveTide(active);hoverFixture.now+=1;hoverFixture.dock.frame(at:hoverFixture.now,elapsed:.infinity)
        if let r=hoverFixture.dock.items[active.id]?.glass.frame {
            _=hoverFixture.dock.pointer(CGPoint(x:r.midX,y:r.midY),now:hoverFixture.now)
            hoverFixture.now+=0.02;hoverFixture.dock.frame(at:hoverFixture.now,elapsed:.infinity)
        }
        check(hoverFixture.dock.tideProbe["level"] as? Int == 1,"notification hover does not reclaim the old brief rectangle")
        let borrowedRect=hoverFixture.dock.items[borrowed.id]!.glass.frame
        _=hoverFixture.dock.pointer(CGPoint(x:borrowedRect.midX,y:borrowedRect.midY),now:hoverFixture.now)
        hoverFixture.now+=0.02;hoverFixture.dock.frame(at:hoverFixture.now,elapsed:.infinity)
        check(hoverFixture.dock.tideProbe["level"] as? Int == 0,"hovering the visible borrowed body revokes the lease")
        _=hoverFixture.dock.pointer(nil,now:hoverFixture.now)
        hoverFixture.dock.frame(at:hoverFixture.now,elapsed:.infinity)
        hoverFixture.now+=0.899;hoverFixture.dock.frame(at:hoverFixture.now,elapsed:.infinity)
        check(hoverFixture.dock.tideProbe["level"] as? Int == 0,"real hover release observes the full grace interval")
        hoverFixture.now+=0.0011;hoverFixture.dock.frame(at:hoverFixture.now,elapsed:.infinity)
        check(hoverFixture.dock.tideProbe["level"] as? Int == 1,"real hover release can borrow again after .9 seconds")
        let idleHover=DockCapsuleVerification.Fixture(scale:2,exposure:false)
        let idleBar=idleHover.dock.items["C"]!.glass.frame,epoch=idleHover.now
        _=idleHover.dock.pointer(CGPoint(x:idleBar.midX,y:idleBar.midY),now:idleHover.now)
        idleHover.now=epoch+0.1;_=idleHover.dock.pointer(nil,now:idleHover.now)
        idleHover.now=epoch+0.2
        idleHover.store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"D","turn":["id":"idle-hover"]]))
        idleHover.dock.receiveTide(idleHover.all[3]);idleHover.dock.frame(at:idleHover.now,elapsed:.infinity)
        check(idleHover.dock.tideProbe["level"] as? Int == 0,"idle hover release cannot bypass grace before the first notification")
        idleHover.now=epoch+0.999;idleHover.dock.frame(at:idleHover.now,elapsed:.infinity)
        check(idleHover.dock.tideProbe["level"] as? Int == 0,"idle hover grace remains active until its deadline")
        idleHover.now=epoch+1.001;idleHover.dock.frame(at:idleHover.now,elapsed:.infinity)
        check(idleHover.dock.tideProbe["level"] as? Int == 1,"idle hover grace opens at its deadline")
        var m=TideMotion(briefs:[("C",CGRect(x:922,y:740,width:160,height:48)),("B",CGRect(x:605,y:740,width:305,height:48))],orbs:[("D",CGRect(x:1106,y:748,width:32,height:32)),("E",CGRect(x:1162,y:748,width:32,height:32)),("F",CGRect(x:1218,y:748,width:32,height:32))])
        m.receive(.init(id:1,kind:.command,text:"Running build"),owner:"D",at:0,protection:["C":[.draft]])
        m.protect([:],at:1);m.protect([:],at:1.899)
        check(m.level==0,"production lease retains .9 second release grace")
        m.protect([:],at:1.9);check(m.level==1,"protection release can borrow at grace deadline")
        m.step(1);m.receive(.init(id:2,kind:.step,text:"Finished build"),owner:"D",at:3,protection:[:]);m.step(2.5)
        check(m.event==nil && m.occupancyRemaining>0,"step lyric and occupancy use separate clocks")
    }
}
#endif
