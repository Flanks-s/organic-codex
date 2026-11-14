#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

@MainActor enum DockTideRound7Verification {
    static func widthBound(_ from:Double,_ to:Double,_ recipe:(Double,Double))->Double {
        var spring=PulseSpring(from);spring.aim(to,recipe);var bound=0.0
        for _ in 0..<360 {let before=spring.x;spring.step(1.0/120);bound=max(bound,abs(spring.x-before))}
        return bound+1
    }
    static func run(to output:URL,check:(Bool,String)->Void) throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        let bound=max(widthBound(68,300,(0.42,0.80)),widthBound(300,32,(0.50,0.86)))
        for scale:CGFloat in [1,2] {
            for ending in ["unpin","escape","mode-cancel"] {
                let f=DockTideRound6Verification.Fixture(scale:scale);f.store.conversation("C")!.draft=" "
                var until = -Double.infinity
                f.dock.onNeedsFrames={duration in until=max(until,f.now+duration);f.pendingFrame=true}
                f.dock.onNeedsFramesUntil={time in until=max(until,time);f.pendingFrame=true}
                let host=NSView(frame:CGRect(x:0,y:0,width:1280,height:820))
                let window=NSWindow(contentRect:host.bounds,styleMask:.borderless,backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(f.dock.view)
                f.start();f.approval("protected-pin");f.pump(0.8)
                check(f.p["level"] as? Int==0,"protected pin cannot borrow: \(scale)x \(ending)")
                var last=f.dock.items["D"]!.glass.frame,maxStep=0.0,minGap=Double.infinity
                func frames(_ duration:Double,_ phase:String) {
                    for _ in 0..<Int(duration*120) {
                        if f.now<until {f.pendingFrame=true}
                        f.pump(1.0/120);let actual=f.dock.items["D"]!.glass.frame
                        maxStep=max(maxStep,abs(actual.width-last.width));last=actual
                        minGap=min(minGap,f.p["minimumGap"] as? Double ?? 0)
                        rows.append(["scale":scale,"ending":ending,"phase":phase,"time":f.now,"rect":DockTideShape.rect(actual)])
                    }
                }
                let p=CGPoint(x:last.midX,y:last.midY)
                let hit=f.dock.view.hitTest(f.dock.view.convert(p,to:f.dock.view.superview)) as? DockTideHitView
                check(hit != nil,"the native protected orb exposes a real pin hit target: \(scale)x \(ending)")
                if let hit {
                    let location=f.dock.view.convert(p,to:nil)
                    let down=NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:f.now,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                    let up=NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:f.now,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
                    hit.mouseDown(with:down);hit.mouseUp(with:up)
                }
                frames(2,"opening")
                check(abs(last.width-300)<0.05,"protected pin reaches the complete action: \(scale)x \(ending)")
                if ending=="unpin" {f.dock.pinTide()}
                else if ending=="escape" {_=f.dock.dismissTide()}
                else {f.scene.beginModeHandoff();f.scene.endModeHandoff()}
                frames(3,"closing")
                check(maxStep<=bound,"displayed pin width follows the original free spring bound: \(scale)x \(ending), \(maxStep) <= \(bound)")
                check(minGap>=11.999,"protected pin retains the entire 12 pt contour: \(scale)x \(ending)")
                check(last.width<=68.05,"protected pin closes without retaining the wide card: \(scale)x \(ending)")
                let before=f.callbacks;f.pump(0.2)
                check(f.callbacks==before,"settled protected pin requests no frames: \(scale)x \(ending)")
                window.close();f.close()
            }
        }
        let previous=UserDefaults.standard.object(forKey:"toggle.simulateReduceMotion")
        UserDefaults.standard.set(true,forKey:"toggle.simulateReduceMotion")
        let reduced=DockTideRound6Verification.Fixture();reduced.store.conversation("C")!.draft=" "
        reduced.start();reduced.approval("reduced-pin");reduced.pump(0.1);reduced.dock.pinTide();reduced.pump(1.0/120)
        check(abs(reduced.dock.items["D"]!.glass.frame.width-300)<0.01,"Reduce Motion opens the valid protected action in one pose")
        check(reduced.p["motionBusy"] as? Bool==false,"Reduce Motion leaves no deferred pin clock")
        _=reduced.dock.dismissTide();reduced.pump(1.0/120)
        check(reduced.p["phase"] as? String=="idle","Reduce Motion closes the protected action without deferred handoff")
        reduced.close()
        if let previous {UserDefaults.standard.set(previous,forKey:"toggle.simulateReduceMotion")}else {UserDefaults.standard.removeObject(forKey:"toggle.simulateReduceMotion")}
        try add(to:output,check:check)
        try addMatrix(to:output,check:check)
        try side(to:output,check:check)
        try sideHover(to:output,check:check)
        liquid(check:check)
        try sidePair(to:output,check:check)
        try sideReflow(to:output,check:check)
        sideReview(check:check)
        try sideBoard(to:output,check:check)
        check(NSApp.windows.allSatisfy{!$0.isVisible},"round7 verification opens no window")
        try JSONSerialization.data(withJSONObject:["freeWidthBound":bound,"frames":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round7.json"))
    }
    static func add(to output:URL,check:(Bool,String)->Void)throws {
        let f=DockTideRound6Verification.Fixture();f.start();f.command();f.pump(1)
        let initial=f.dock.items["C"]!.glass.frame
        let token=(f.p["generation"] as? UInt64) ?? 0
        var additions:[Conversation]=[]
        for n in 0..<12 {
            let c=Conversation(id:"tide-add-\(n)",title:"Add fixture \(n)")
            additions.append(c)
            let (layout,order)=f.scene.arrange(f.scene.members+additions,current:f.scene.current)
            if !order.prefix(layout.bars.count).contains("C") {break}
        }
        for c in additions {f.store.add(c)}
        let denied=f.scene.admitWithTideSlots(additions,owner:"add-denied",capacityAllows:false)
        check(!denied && f.scene.members.count==6,"Add requires the caller's capacity verdict")
        let granted=f.scene.admitWithTideSlots(additions,owner:"add-fixture",capacityAllows:true)
        check(granted,"Add reserves the exact displaced canonical brief")
        check(f.dock.items["C"]?.role == .orb,"Add commits C to the canonical ordinary orb role")
        check(f.dock.items["C"]!.glass.frame==initial,"Add's commit retains the actual native source pose")
        check(f.dock.tideAddProbe["committed"] as? Bool==true,"Add lease commits before an old Tide callback can run")
        var frames:[[String:Any]]=[],minimumGap=Double.infinity
        let began=f.now
        for _ in 0..<360 {
            f.now+=1.0/120;f.dock.frame(at:f.now,elapsed:f.now-began)
            let groups=f.dock.tideAddPhysicalProbe
            for (id,arrays) in groups {
                for a in arrays where a.count==4 {
                    let r=CGRect(x:a[0],y:a[1],width:a[2],height:a[3])
                    for (other,item) in f.dock.items where other != id && !item.glass.isHidden {
                        minimumGap=min(minimumGap,TideContour.gap(r,item.glass.frame))
                    }
                }
            }
            frames.append(["time":f.now-began,"body":DockTideShape.rect(f.dock.items["C"]!.glass.frame),"add":f.dock.tideAddProbe])
        }
        check(minimumGap.isFinite && minimumGap>=11.999,"Add keeps the entire physical outgoing tail at least 12 pt from other owners: \(minimumGap)")
        let widths=frames.compactMap{($0["body"] as? [CGFloat])?[2]}
        check(widths.prefix(7).allSatisfy{abs($0-initial.width)<0.01},"Add holds the displayed 36 pt body while its tail begins retracting")
        check(zip(widths,widths.dropFirst()).allSatisfy{abs($0-$1)<1},"Add's 36 to 32 body has no one-frame takeover jump")
        check(abs(f.dock.items["C"]!.glass.frame.width-32)<0.01,"Add settles to a 32 pt ordinary orb")
        check((f.dock.tideAddProbe["tails"] as? [String:Any])?.isEmpty==true,"Add has no retained tail clock after settling")
        f.dock.retireTide()
        check(f.dock.items["C"]?.role == .orb && f.dock.tideAddProbe["committed"] as? Bool==true,"Tide retirement cannot evict Add's orb or lease")
        check(!f.scene.order.prefix(f.scene.layout.columns.count).contains("C"),"Add does not leave a hidden C column owning the orb")
        f.scene.setPeeking("C")
        check(f.scene.peeking=="C","Add's C uses the ordinary Peek entry")
        f.scene.setPeeking(nil)
        try JSONSerialization.data(withJSONObject:["initialGeneration":token,"additions":additions.map(\.id),"frames":frames],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-add.json"))
        f.close()
    }

    static func side(to output:URL,check:(Bool,String)->Void)throws {
        var reports:[[String:Any]]=[]
        for mode in ["focused","split","parked"] {
            let f=DockTideRound6Verification.Fixture()
            if mode=="parked" {
                var scheme=f.scene.scheme;scheme.parked=["D","E"]
                f.scene.transition(to:f.scene.members,current:f.scene.current,scheme:scheme,spring:Tuning.shared.autoSpring,reason:"tide-side-parked-fixture")
            } else {
                f.scene.enterFocused("A",reason:"tide-side-fixture")
                if mode=="split" {f.scene.graft("B",at:1,reason:"tide-side-split-fixture")}
            }
            f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
            // Finish the physical mode handoff before measuring the first frame of a new Side arrival.
            f.now=max(f.now,f.dock.glassReleaseSettles);f.force()
            let targets=f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}
            f.target=mode=="parked" ? "D":targets.last!.id;f.start();f.approval("side-"+mode,outside:true)
            var frames:[[String:Any]]=[],minimumGap=Double.infinity
            for _ in 0..<240 {
                f.pump(1.0/120)
                let probes=f.dock.tideSidePhysicalProbe
                for row in probes where row["active"] as? Bool==true {
                    let id=row["owner"] as! String
                    let arrays=([row["card"],row["orb"]].compactMap{$0 as? [CGFloat]})+(row["stem"] as? [[CGFloat]] ?? [])
                    let contours=arrays.filter{$0.count==4}.map{CGRect(x:$0[0],y:$0[1],width:$0[2],height:$0[3])}
                    for (other,item) in f.dock.items where other != id {
                        let obstacles=([item.glass]+[item.identity?.glassView].compactMap{$0}).filter{!$0.isHidden}.map(\.frame)
                        for a in contours {for b in obstacles {minimumGap=min(minimumGap,TideContour.gap(a,b))}}
                    }
                }
                frames.append(["time":f.now,"side":probes])
            }
            check(minimumGap.isFinite && minimumGap>=11.999,"side's entire native card/orb/stem contour retains 12 pt: \(mode), \(minimumGap)")
            let p=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target} ?? [:]
            let card=p["card"] as? [CGFloat] ?? [],orb=p["orb"] as? [CGFloat] ?? []
            check(p["active"] as? Bool==true,"real \(mode) entry routes its Core notice into TideSide B")
            check(card.count==4 && card[2]>=150 && [48.0,88.0].contains(Double(card[3])),"side approval reaches a 48 or 88 pt action card: \(mode)")
            check(orb.count==4 && abs(orb[2]-36)<0.01,"side orb swells to 36 pt: \(mode)")
            check((p["face"] as? [String:Any])?["opacity"] as? Double==1 && p["badgeAlpha"] as? Double==0,"Side keeps its planet visible and hides only its owned badge: \(mode)")
            let early=frames.first?["side"] as? [[String:Any]] ?? []
            let first=early.first{$0["owner"] as? String==f.target} ?? [:]
            check((first["face"] as? [String:Any])?["opacity"] as? Double==1 && (first["badgeAlpha"] as? Double ?? 0)>0 && (first["badgeAlpha"] as? Double ?? 1)<1,"Side's arriving badge fades over .07 s while its planet remains visible: \(mode)")
            check(card.count==4 && abs(card[1]+card[3]-(f.scene.layout.bars.map(\.minY).min()!-14))<0.05,"side card ends 14 pt above the real composer: \(mode)")
            let before=f.callbacks;f.pump(0.5)
            check(f.callbacks==before,"settled side requests zero display callbacks: \(mode)")
            check(!(p["stem"] as? [[CGFloat]] ?? []).isEmpty,"side stem is native glass: \(mode)")
            let ink=p["presentation"] as? [String:Any] ?? [:]
            check(ink["sideLead"] as? String=="1","Side's status count comes from its real pending approval: \(mode)")
            let lead=ink["leadRect"] as? [CGFloat] ?? [],title=ink["titleRect"] as? [CGFloat] ?? []
            check(card.count==4 && lead.count==4 && title.count==4 && abs(lead[0]-card[0]-14)<0.01 && lead[2]==14 && abs(title[0]-card[0]-35)<0.01,"Side retains the board's 14 pt mark and 7 pt content gap: \(mode)")
            check((ink["buttons"] as? [[String:Any]])?.count==2,"side preserves original approval buttons: \(mode)")
            let allow=f.button("Allow")
            check(allow != nil,"side exposes a real native Allow target: \(mode)")
            allow?.performClick(nil);f.pump(0.1)
            check(f.responses==["side-"+mode],"side button sends its original request ID exactly once: \(mode)")
            f.approval("side-lifecycle-"+mode);f.pump(0.3)
            let frozenButton=f.button("Allow"),submitted=f.submitted
            f.scene.beginModeHandoff();frozenButton?.performClick(nil)
            check(f.submitted==submitted,"a retained native Side button cannot submit through the real mode freeze: \(mode)")
            f.scene.endModeHandoff();f.pump(2)
            check(f.store.conversation(f.target)?.approvals.map(\.id)==["side-lifecycle-"+mode],"side mode cleanup retains its unanswered original request: \(mode)")
            check(!f.dock.tideSideProbe.contains{$0["active"] as? Bool==true},"real mode cancellation retires the side clock: \(mode)")
            reports.append(["mode":mode,"probe":p,"frames":frames]);f.close()
        }
        let anchors=[CGRect(x:30,y:748,width:32,height:32),CGRect(x:100,y:748,width:32,height:32)]
        let candidates=anchors.enumerated().map{TideSidePacking.Candidate(id:String($0.offset),anchor:$0.element,preferred:180,action:true,one:false,rank:$0.offset)}
        let pair=TideSidePacking.solve(candidates,region:30...354,bottom:726,right:false)
        check(pair.count==2,"one side admits two cards when its margin has 2*150+12 pt")
        check(pair.values.allSatisfy{$0.height==88},"sub-300 action width uses the complete 88 pt two-line card")
        let ordered=pair.values.sorted{$0.minX<$1.minX}
        check(ordered.count==2 && ordered[1].minX-ordered[0].maxX>=11.999,"two same-side cards keep 12 pt")
        check(TideSidePacking.solve(candidates,region:30...329,bottom:726,right:false).count==1,"a second card waits instead of violating the margin capacity")
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-side.json"))
    }

    static func sideHover(to output:URL,check:(Bool,String)->Void)throws {
        var evidence:[[String:Any]]=[]
        for mode in ["focused","split","parked"] {
            let f=DockTideRound6Verification.Fixture()
            if mode=="parked" {var scheme=f.scene.scheme;scheme.parked=["D"];f.scene.transition(to:f.scene.members,current:f.scene.current,scheme:scheme,spring:Tuning.shared.autoSpring,reason:"side-hover-fixture")}
            else {f.scene.enterFocused("A",reason:"side-hover-fixture");if mode=="split" {f.scene.graft("B",at:1,reason:"side-hover-fixture")}}
            f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
            // Hover an admitted Side on the outer right orb, where its entrance clears the neighbouring orbs.
            f.target=mode=="parked" ? "D":f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.last!.id
            f.start();f.approval("hover-"+mode);f.pump(1.5)
            guard let initial=f.dock.tideSidePhysicalProbe.first(where:{$0["owner"] as? String==f.target}),
                  let initialOrb=initial["orb"] as? [CGFloat],initialOrb.count==4 else {
                for label in ["native Side exists through hover","hover retains composer clearance","hover pauses the original hold","static hover requests no frames or writes"] {check(false,"\(label): \(mode)")}
                f.close();continue
            }
            let orb=initialOrb
            _=f.dock.pointer(CGPoint(x:orb[0]+orb[2]/2,y:orb[1]+orb[3]/2),now:f.now)
            let remaining=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target}!["eventRemaining"] as! Double
            var visible=true,gap=Double.infinity,rows:[[String:Any]]=[]
            for _ in 0..<144 {
                f.pump(1.0/120);f.force()
                let p=f.dock.tideSidePhysicalProbe.first{$0["owner"] as? String==f.target}!
                visible = visible && p["visible"] as? Bool==true
                if let card=p["card"] as? [CGFloat],card.count==4 {
                    for item in f.dock.items.values where item.role == .bar {gap=min(gap,Double(item.glass.frame.minY-card[1]-card[3]))}
                }
                rows.append(["time":f.now,"rise":f.dock.rise,"probe":p])
            }
            let end=f.dock.tideSidePhysicalProbe.first{$0["owner"] as? String==f.target}!
            check(visible,"Dock hover lift never withdraws its active native Side: \(mode)")
            check(gap>=11.999,"hovering Side follows the real composer with at least 12 pt: \(mode), \(gap)")
            check(abs((end["eventRemaining"] as! Double)-remaining)<0.0001,"hovering the real Side orb pauses its original hold: \(mode)")
            let count=f.callbacks,writes=end["writes"] as! Int;f.pump(0.2)
            let rest=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target}!
            check(f.callbacks==count && rest["writes"] as? Int==writes,"a lifted static Side requests no frames or glass writes: \(mode)")
            evidence.append(["mode":mode,"minimumComposerGap":gap,"frames":rows]);f.close()
        }
        try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-side-hover.json"))
    }
    static func liquid(check:(Bool,String)->Void) {
        let f=DockTideRound6Verification.Fixture();f.start();f.emit("core/pulseProgress",["completed":3,"total":7]);f.pump(2)
        let first=f.ink
        check(abs((first["liquidWidth"] as? Double ?? -1)-3.0/7)<0.0001,"Core test progress fills the horizontal notification surface")
        check(abs((first["liquidAlpha"] as? Double ?? -1)-0.24)<0.0001,"test liquid uses the board's .24 opacity")
        let callbacks=f.callbacks,updates=first["contentUpdates"] as? Int
        f.pump(0.5)
        check(f.callbacks==callbacks && f.ink["contentUpdates"] as? Int==updates,"static progress requests no frames or content writes")
        f.emit("core/pulseProgress",["completed":5,"total":7]);f.pump(0.1)
        let changing=f.ink["liquidWidth"] as? Double ?? -1
        check(changing>3.0/7 && changing<5.0/7,"a new progress event wakes one finite .6/.9 settle")
        f.pump(2)
        check(abs((f.ink["liquidWidth"] as? Double ?? -1)-5.0/7)<0.0001,"progress settles to its real reported fraction")
        let last=f.callbacks;f.pump(0.5)
        check(f.callbacks==last,"the second progress settle sleeps again")
        f.close()
        let unknown=DockTideRound6Verification.Fixture();unknown.start();unknown.command();unknown.pump(2)
        check((unknown.ink["liquidAlpha"] as? Double ?? -1)==0,"unknown progress shows no invented percentage fill")
        unknown.close()
    }

    static func sidePair(to output:URL,check:(Bool,String)->Void)throws {
        let f=DockTideRound6Verification.Fixture()
        f.scene.enterFocused("A",reason:"side-pair-fixture");f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
        let union=f.scene.layout.bars.reduce(f.scene.layout.bars[0]){$0.union($1)}
        let targets=f.dock.restingTargets.filter{!$0.bar && $0.rect.midX>union.midX}.sorted{$0.rect.minX<$1.rect.minX}
        check(targets.count>=3,"side-pair fixture has three real same-side orbs")
        guard targets.count>=3 else{f.close();return}
        f.target=targets[0].id;f.start();f.approval("pair-first");f.pump(0.12)
        f.target=targets.last!.id;f.start();f.approval("pair-second",outside:true)
        var minimum=Double.infinity,reports:[[String:Any]]=[]
        for _ in 0..<240 {
            f.pump(1.0/120)
            let visible=f.dock.tideSidePhysicalProbe.filter{$0["visible"] as? Bool==true}
            let contours=visible.map{p -> (String,[CGRect]) in
                let arrays=([p["card"],p["orb"]].compactMap{$0 as? [CGFloat]})+(p["stem"] as? [[CGFloat]] ?? [])
                return (p["owner"] as! String,arrays.filter{$0.count==4}.map{CGRect(x:$0[0],y:$0[1],width:$0[2],height:$0[3])})
            }
            for a in contours {for b in contours where a.0 != b.0 {for x in a.1 {for y in b.1 {minimum=min(minimum,TideContour.gap(x,y))}}}}
            reports.append(["time":f.now,"side":visible])
        }
        check(f.dock.tideSideProbe.filter{$0["visible"] as? Bool==true}.count==2,"two same-side cards reach real native surfaces")
        check(f.dock.tideSideProbe.filter{$0["visible"] as? Bool==true}.allSatisfy{($0["card"] as? [CGFloat])?[3]==88},"two real narrow cards each retain the complete 88 pt layout")
        check(f.dock.tideSideProbe.filter{$0["visible"] as? Bool==true}.allSatisfy{$0["contentRows"] as? Int==2 && $0["formAlpha"] as? Double==1},"both narrow cards finish the board's content form transition")
        let early=reports.flatMap{$0["side"] as? [[String:Any]] ?? []}.filter{p in
            guard let r=p["card"] as? [CGFloat],r.count==4,let ink=p["presentation"] as? [String:Any] else{return false}
            return r[2]<150 && (ink["actionAlpha"] as? Double ?? 0)>0.01
        }
        check(!early.isEmpty,"a narrow Side action exercises its content entrance before its width spring settles")
        check(early.allSatisfy{($0["presentation"] as? [String:Any])?["actionVisible"] as? Bool==true},"Side content fades inside the growing glass instead of popping on at 150 pt")
        check(minimum.isFinite && minimum>=11.999,"two native card/orb/stem contours retain 12 pt in every frame: \(minimum)")
        let before=f.callbacks,counts=f.dock.tideSideProbe.map{$0["writes"] as? Int ?? -1}
        f.pump(0.5)
        check(f.callbacks==before && counts==f.dock.tideSideProbe.map{$0["writes"] as? Int ?? -1},"two static cards request zero frames and write zero glass")
        f.target=targets[targets.count/2].id;f.start();f.approval("pair-waiting")
        f.pump(1)
        let waiting=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target} ?? [:]
        check(waiting["waiting"] as? Bool==true && waiting["visible"] as? Bool==false,"a third request waits on its ordinary orb, retaining its badge signal")
        let halo=waiting["presentation"] as? [String:Any] ?? [:]
        check(halo["haloOnly"] as? Bool==true && (halo["haloAlpha"] as? Double ?? 0)>0.99,"a waiting request retains its static orb halo without hiding the ordinary badge")
        check(abs((waiting["eventRemaining"] as? Double ?? 0)-7)<0.01,"waiting does not consume an unseen action's hold")
        let sleeping=f.callbacks;f.pump(0.5)
        check(f.callbacks==sleeping,"an unseen waiting request starts no display loop")
        var firstAdmission:[String:Any]?
        for _ in 0..<540 {
            f.pump(1.0/120)
            let p=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target} ?? [:]
            if firstAdmission == nil,p["visible"] as? Bool==true {firstAdmission=p}
        }
        let resumed=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target} ?? [:]
        check(resumed["visible"] as? Bool==true && (resumed["eventRemaining"] as? Double ?? 0)>5,"a waiting request receives a complete hold when room becomes available")
        let admittedInk=firstAdmission?["presentation"] as? [String:Any] ?? [:]
        check(admittedInk["actionAlpha"] as? Double==0,"an already-aged waiting request still delays its new card content by .20 s")
        check(admittedInk["haloAlpha"] as? Double==1,"orb-to-card admission never cuts an existing waiting halo")
        check((resumed["presentation"] as? [String:Any])?["actionAlpha"] as? Double==1,"the admitted request finishes its finite content entrance")
        try JSONSerialization.data(withJSONObject:["minimumGap":minimum.isFinite ? minimum as Any:NSNull(),"frames":reports,"waiting":waiting,"firstAdmission":firstAdmission ?? [:],"resumed":resumed],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-side-pair.json"))
        f.close()
    }

    static func sideReview(check:(Bool,String)->Void) {
        check(TideSidePacking.region(width:1280,focused:true,split:false,right:true)==932...1250,"Focused uses the board's reading margin, not the composer edge")
        check(TideSidePacking.region(width:1280,focused:true,split:true,right:true)==930...1250,"Split uses the board's outer 320 pt margin")
        check(TideSidePacking.region(width:1280,focused:false,split:false,right:false)==30...350,"parked uses the board's outer 320 pt margin")
        for mode in ["focused","split"] {for complex in [false,true] {
            let f=DockTideRound6Verification.Fixture();f.scene.enterFocused("A",reason:"side-review-fixture")
            if mode=="split" {f.scene.graft("B",at:1,reason:"side-review-split-fixture")}
            f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
            // Review needs the visible action card on the outer right orb, rather than a blocked waiting request.
            f.target=f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.last!.id;f.start()
            if complex {f.question(complex:true)}else {f.emit("turn/completed",["turn":["id":.string(f.turn),"status":"failed","error":["message":"Side stopped"]]])}
            f.pump(1)
            let button=f.button(complex ? "Answer question":"Review error")
            check(button != nil,"Side exposes the original full-interface Review button: \(mode) question \(complex)")
            button?.performClick(nil)
            check(!f.scene.isFocused && f.scene.current==f.target,"Side Review uses the real full conversation entry: \(mode) question \(complex)")
            check(f.responses.isEmpty && (!complex || f.store.conversation(f.target)?.userInput?.id=="question-r6"),"Review neither submits nor loses its pending question")
            f.close()
        }}
    }

    static func sideReflow(to output:URL,check:(Bool,String)->Void)throws {
        let f=DockTideRound6Verification.Fixture();f.scene.enterFocused("A",reason:"side-reflow-fixture")
        f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
        let targets=f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.midX<$1.rect.midX}
        let first=targets.first!.id;f.target=first;f.start();f.approval("reflow-first");f.pump(1.5)
        f.target=targets.last!.id;f.start();f.command()
        var oldRows=1,changed=false,hiddenAtChange=true,lastWidth=318.0,maxStep=0.0,subtitleKept=true
        var shifts:[[String:Any]]=[]
        for _ in 0..<240 {
            f.pump(1.0/240)
            let p=f.dock.tideSideProbe.first{$0["owner"] as? String==first} ?? [:],rows=p["contentRows"] as? Int ?? 0
            if rows==1,let ink=p["presentation"] as? [String:Any],(ink["actionAlpha"] as? Double ?? 0)>0.01 {subtitleKept = subtitleKept && ink["subtitleVisible"] as? Bool==true}
            if let native=f.dock.tideSidePhysicalProbe.first(where:{$0["owner"] as? String==first})?["card"] as? [CGFloat],native.count==4 {maxStep=max(maxStep,abs(native[2]-lastWidth));lastWidth=native[2]}
            if rows != oldRows {changed=true;hiddenAtChange = hiddenAtChange && p["formAlpha"] as? Double==0;shifts.append(["time":f.now,"rows":rows,"alpha":p["formAlpha"] ?? NSNull()])};oldRows=rows
        }
        let settled=f.dock.tideSideProbe.first{$0["owner"] as? String==first} ?? [:]
        check(changed && hiddenAtChange,"a visible Side changes row layout only after its old content has faded completely")
        check(subtitleKept,"the outgoing single-row action retains its subtitle until its content finishes fading")
        check(maxStep<=widthBound(318,156,(0.36,0.92)),"another owner never backdates an idle Side's new width target: \(maxStep)")
        check(settled["contentRows"] as? Int==2 && settled["formAlpha"] as? Double==1,"a mature wide action reaches its narrow two-line content and fades back in")
        for _ in 0..<72 where f.dock.tideSideProbe.contains(where:{$0["motionBusy"] as? Bool==true}) {f.pump(1.0/120)}
        check(!f.dock.tideSideProbe.contains(where:{$0["motionBusy"] as? Bool==true}),"both Side surfaces reach their finite spring endpoint within 1.6 s")
        let before=f.callbacks;f.pump(0.5)
        check(f.callbacks==before,"a completed Side form change starts no continuing frame loop")
        try JSONSerialization.data(withJSONObject:["maximumNativeWidthStep":maxStep,"bound":widthBound(318,156,(0.36,0.92)),"shifts":shifts,"settled":settled,"allSides":f.dock.tideSideProbe],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-side-reflow.json"))
        f.close()
    }

    static func sideBoard(to output:URL,check:(Bool,String)->Void)throws {
        guard let path=ProcessInfo.processInfo.environment["TIDE_SIDE_BOARD_TRACE"] else{return}
        let data=try Data(contentsOf:URL(fileURLWithPath:path)),root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let a=root["anchor"] as! [Double],t=root["target"] as! [String:Any],rows=root["rows"] as! [[String:Any]]
        let anchor=CGRect(x:a[0],y:a[1],width:a[2],height:a[3])
        let target=CGRect(x:t["l"] as! Double,y:726-(t["h"] as! Double),width:t["w"] as! Double,height:t["h"] as! Double)
        var motion=TideSideMotion(anchor:anchor,composerTop:740);motion.aim(target)
        var phase="arrival",cursor=0.0,maximum=0.0,reports:[[String:Any]]=[]
        for row in rows {
            let p=row["phase"] as! String,time=row["t"] as! Double
            if p != phase {phase=p;cursor=0;motion.aim(nil)}
            while cursor+1e-8<time {motion.step(1.0/240,reduced:false);cursor+=1.0/240}
            let expected=row["card"] as! [Double],actual=DockTideShape.rect(motion.card).map(Double.init)
            let error=zip(expected,actual).map{abs($0-$1)}.max() ?? 0
            let diameter=abs((row["orb"] as! Double)-motion.diameter.x)
            maximum=max(maximum,error,diameter)
            check(error<0.05 && diameter<0.05,"Side B geometry at the board's own \(phase) \(time)s: \(error), \(diameter)")
            reports.append(["phase":phase,"time":time,"expected":expected,"actual":actual,"error":error,"orbError":diameter])
        }
        try JSONSerialization.data(withJSONObject:["maximumError":maximum,"rows":reports],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-side-board.json"))
        // Auto Tide uses IslandTide02 tO (.42 → .24); Side's independent bfO starts at zero.
        if let liquid=(root["mainLiquidRows"] ?? root["liquidRows"]) as? [[String:Any]] {
            let f=DockTideRound6Verification.Fixture();f.start();f.emit("core/pulseProgress",["completed":3,"total":7])
            var at=0.0,rows:[[String:Any]]=[]
            for row in liquid {
                let t=row["t"] as! Double;f.pump(t-at,hz:240);at=t
                let w=f.ink["liquidWidth"] as? Double ?? -1,a=f.ink["liquidAlpha"] as? Double ?? -1
                let error=max(abs(w-(row["width"] as! Double)/100),abs(a-(row["alpha"] as! Double)))
                check(error<0.00001,"real progress follows the board's percentage-point spring, including rest at \(t)s: \(error)")
                rows.append(["t":t,"error":error,"fraction":w,"alpha":a])
            }
            f.close()
            try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-liquid-board.json"))
        }
    }

    static func addMatrix(to output:URL,check:(Bool,String)->Void)throws {
        var reports:[[String:Any]]=[]
        for scale:CGFloat in [1,2] {for room in [1,2] {for hovering in [false,true] {
            let f=DockTideRound6Verification.Fixture(scale:scale);f.scene.now={ [weak f] in f?.now ?? 0 }
            f.dock.setTideCapacityFixture(room==2 ? 461:nil);f.start();f.command();f.pump(1)
            if hovering {_=f.dock.pointer(CGPoint(x:45,y:764),now:f.now);f.pump(0.8)}
            let source=f.dock.items["C"]!.glass.frame
            let additions=(0..<2).map{Conversation(id:"matrix-add-\($0)",title:"Add matrix")}
            for c in additions {f.store.add(c)}
            check(f.scene.admitWithTideSlots(additions,owner:"matrix",capacityAllows:true),"Add matrix admits \(scale)x room\(room) hover \(hovering)")
            check(MotionStep.edge(source,f.dock.items["C"]!.glass.frame)<0.001,"Add matrix commits from the displayed source")
            var minimum=Double.infinity,frameRows:[[String:Any]]=[],worst:[String:Any]=[:]
            let began=f.now
            for i in 0..<360 {
                f.now+=1.0/120;f.dock.frame(at:f.now,elapsed:f.now-began)
                let groups=f.dock.tideAddPhysicalProbe
                for (id,parts) in groups {for a in parts where a.count==4 {
                    let rect=CGRect(x:a[0],y:a[1],width:a[2],height:a[3])
                    for (other,item) in f.dock.items where other != id && !item.glass.isHidden {
                        let gap=TideContour.gap(rect,item.glass.frame)
                        if gap<minimum {minimum=gap;worst=["t":f.now-began,"owner":id,"part":a,"other":other,"rect":DockTideShape.rect(item.glass.frame)]}
                    }
                }}
                if i==3 {
                    let before=f.dock.items["C"]!.glass.frame,tail=f.dock.tideAddPhysicalProbe
                    f.scene.beginModeHandoff();f.now+=0.2;f.force()
                    check(f.dock.items["C"]!.glass.frame==before && f.dock.tideAddPhysicalProbe==tail,"real mode preparation freezes both Add body and native tail")
                    check(f.dock.tideAnimationDiagnostics["tideRequestsDisplayFrames"] as? Bool==false,"frozen Add requests no Tide frames")
                    f.scene.endModeHandoff()
                }
                if i==100 {f.dock.serviceTideDeadline()}
                frameRows.append(["t":f.now-began,"body":DockTideShape.rect(f.dock.items["C"]!.glass.frame),"physical":groups])
            }
            check(minimum.isFinite && minimum>=11.999,"Add matrix full physical contour keeps 12 pt: \(scale)x room\(room) hover \(hovering), \(minimum)")
            check(f.dock.items["C"]?.role == .orb && f.dock.tideAddProbe["committed"] as? Bool==true,"old deadline and canceled mode cannot revoke committed Add")
            check(f.dock.tideAddPhysicalProbe.isEmpty,"Add matrix releases all finite visual channels")
            reports.append(["scale":scale,"room":room,"hover":hovering,"minimumGap":minimum.isFinite ? minimum as Any:NSNull(),"worst":worst,"frames":frameRows]);f.close()
        }}}
        try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-add-matrix.json"))
    }

}
#endif
