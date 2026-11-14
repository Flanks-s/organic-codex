#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Real retained glass, a predicted display timestamp, and the host's existing event/lifecycle entries.
@MainActor enum DockTideRound9Verification {
    static func run(to output:URL,check:(Bool,String)->Void)throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        let defaults=UserDefaults.standard,key="toggle.simulateReduceMotion"
        let savedArguments=defaults.volatileDomain(forName:UserDefaults.argumentDomain)
        var arguments=savedArguments;arguments[key]=false
        defaults.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
        defer {defaults.setVolatileDomain(savedArguments,forName:UserDefaults.argumentDomain)}
        var rows:[[String:Any]]=[]
        for mode in ["focused","split","parked"] {
            let f=DockTideRound6Verification.Fixture()
            let root=RootView(frame:CGRect(x:0,y:0,width:1280,height:820));root.wantsLayer=true
            for view in [f.scene.sceneView,f.scene.nativePlane,f.scene.peekNode.view,f.scene.dockView,f.scene.overlayPlane] {view.frame=root.bounds;root.addSubview(view)}
            f.scene.enterFocused("A",reason:"tide-r9")
            if mode=="parked" {
                f.scene.settle();f.scene.leaveFocused(reason:"tide-r9")
                f.scene.settle();var scheme=f.scene.scheme;scheme.parked=["B","C"]
                f.scene.transition(to:f.scene.members,current:"A",scheme:scheme,spring:Tuning.shared.autoSpring,reason:"tide-r9")
            } else if mode=="split" {f.scene.graft("B",at:1,reason:"tide-r9")}
            f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
            if mode=="split" {f.scene.showCaptures(false)}
            let targets=mode=="parked" ? ["B","C"]:Array(f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.suffix(2).map(\.id))
            func controls(_ view:NSView)->[CGRect] {
                guard !view.isHiddenOrHasHiddenAncestor else{return []}
                if let button=view as? NSButton,button.title=="Run" || button.title=="Allow" {
                    let visible=button.visibleRect.intersection(button.bounds)
                    return visible.isEmpty ? []:[button.convert(visible,to:f.dock.view)]
                }
                return view.subviews.flatMap(controls)
            }
            let nativeButtons=mode=="split" ? f.scene.columns.flatMap{controls($0.native)}:[]
            if mode=="split" {
                check(!nativeButtons.isEmpty,"Split fixture contains the real full-column decision Run control")
                check(nativeButtons.allSatisfy{$0.width>20 && $0.width<=200 && $0.height>=14 && $0.height<=48 && root.bounds.contains($0)},"native decision oracle uses a shared host and actual visible button bounds")
            }
            var until = -Double.infinity,link=false,displayCallbacks=0,minimumGap=Double.infinity,popped=false
            var wasVisible:Set<String>=[]
            f.dock.onNeedsFrames={d in until=max(until,f.now+d);link=true}
            f.dock.onNeedsFramesUntil={t in until=max(until,t);link=true}
            func tick(_ seconds:Double) {
                for _ in 0..<max(1,Int((seconds*120).rounded())) {
                    f.now+=1.0/120
                    if let due=f.dock.tideLightProbe["nextWakeAt"] as? Double,due<=f.now {f.dock.serviceTideDeadline()}
                    if link {
                        // SceneClock pauses after onFrame when targetTimestamp exceeds the requested deadline.
                        let target=f.now+1.0/120;displayCallbacks+=1
                        f.dock.frame(at:target,elapsed:.infinity)
                        let sides=f.dock.tideSidePhysicalProbe.filter{$0["visible"] as? Bool==true}
                        let owners=Set(sides.compactMap{$0["owner"] as? String})
                        for p in f.dock.tideSideProbe where wasVisible.contains(p["owner"] as? String ?? "") {
                            if p["active"] as? Bool==true,p["returning"] as? Bool==false,p["visible"] as? Bool==false {popped=true}
                        }
                        wasVisible=owners
                        func parts(_ p:[String:Any])->[CGRect] {
                            ([p["card"],p["orb"]].compactMap{$0 as? [CGFloat]}+(p["stem"] as? [[CGFloat]] ?? [])).filter{$0.count==4}.map{CGRect(x:$0[0],y:$0[1],width:$0[2],height:$0[3])}
                        }
                        for p in sides {
                            let id=p["owner"] as! String
                            let other=f.dock.items.filter{!owners.contains($0.key)}.values.flatMap {item in
                                ([item.glass]+[item.identity?.glassView].compactMap{$0}).filter{!$0.isHidden}.map(\.frame)
                            }+sides.filter{$0["owner"] as? String != id}.flatMap(parts)+f.scene.layout.bars+nativeButtons
                            for a in parts(p) {for b in other {minimumGap=min(minimumGap,TideContour.gap(a,b))}}
                        }
                        if target>until {link=false}
                    }
                }
            }
            f.target=targets[0];f.start();f.command();tick(0.7)
            let command=f.dock.tideSideProbe.first{$0["owner"] as? String==f.target} ?? [:]
            let commandRect=command["card"] as? [CGFloat] ?? []
            let commandCallbacks=displayCallbacks
            check(command["visible"] as? Bool==true && commandRect.count==4 && commandRect[2]>=149,"Side command opens without hover under the real display deadline rule: "+mode)
            check(displayCallbacks>25,"Side keeps predicted display tickets until the bud and card settle: "+mode)
            f.approval("side-r9-first");tick(1)
            f.target=targets[1];f.start();f.command();tick(1)
            f.approval("side-r9-second",outside:true);tick(2)
            let sides=f.dock.tideSideProbe.filter{targets.contains($0["owner"] as? String ?? "")}
            check(sides.filter{$0["visible"] as? Bool==true && (($0["card"] as? [CGFloat])?[2] ?? 0)>=149}.count==2,"two adjacent owned orbs receive two legal Side cards: "+mode)
            check(sides.allSatisfy{($0["formAlpha"] as? Double ?? 0)>0.999},"Side form content reaches full alpha after repacking: "+mode)
            if mode != "parked" {check(sides.filter{($0["card"] as? [CGFloat])?[3]==88}.count==2,"both narrow Side approvals become 88 pt cards: "+mode)}
            for side in sides {
                let id=side["owner"] as! String
                func rawCommandLabels(_ view:NSView)->Bool {
                    if let label=view as? NativeLabel,label.stringValue.contains("printf"),!label.isHiddenOrHasHiddenAncestor {return true}
                    return view.subviews.contains(where:rawCommandLabels)
                }
                check(!rawCommandLabels(f.dock.view),"Side approval uses a summary rather than the raw command: "+mode+" "+id)
                let item=f.dock.items[id]!
                check(side["visible"] as? Bool==true || (!item.glass.isHidden && item.glass.alphaValue>0.01) || item.identity.map{!$0.glassView.isHidden && $0.glassView.alphaValue>0.01}==true,"waiting Side keeps its ordinary orb glass visible: "+mode+" "+id)
            }
            check(minimumGap.isFinite && minimumGap>=11.999,"every moving Side body and stem retains 12 pt from every other owner: "+mode)
            check(!popped,"an admitted Side never parks and reappears during a form change: "+mode)
            rows.append(["case":mode,"minimumGap":minimumGap,"nativeButtons":nativeButtons.map(DockTideShape.rect),"side":sides,"commandCallbacks":commandCallbacks,"command":command,"displayCallbacks":displayCallbacks,"items":f.dock.items.mapValues{["rect":DockTideShape.rect($0.glass.frame),"hidden":$0.glass.isHidden,"alpha":$0.glass.alphaValue]}])
            _=f.dock.dismissTide();tick(2)
            check(f.dock.tideSideProbe.allSatisfy{$0["active"] as? Bool==false},"one dismissal finishes both Side retreats: "+mode)
            let before=displayCallbacks;tick(0.5)
            check(displayCallbacks==before,"settled Side retreat leaves no display link tickets: "+mode)
            f.target=targets[0];f.emit("core/approvalExpired",["approvalId":"side-r9-first"])
            f.target=targets[1];f.emit("core/approvalExpired",["approvalId":"side-r9-second"]);tick(0.1)
            check(!f.dock.tideSideProbe.contains(where:{$0["active"] as? Bool==true}),"expiration after Side dismissal never reopens a card during cleanup: "+mode)
            f.dock.retireTide()
            check(targets.allSatisfy{id in
                guard let item=f.dock.items[id] else{return false}
                return !item.glass.isHidden && item.glass.alphaValue>0.01 || item.identity.map{!$0.glassView.isHidden && $0.glassView.alphaValue>0.01}==true
            },"Side retirement restores ordinary orb glass before another mode can leave it waiting: "+mode)
            withExtendedLifetime(root) {};f.close()
        }
        for kind in ["approval","live"] {try retreat(kind,to:&rows,check:check)}
        let progress=DockTideRound6Verification.Fixture();progress.start();progress.emit("core/pulseProgress",["completed":3,"total":7]);progress.pump(0.1)
        let early=progress.ink["liquidWidth"] as? Double ?? -1
        check(early>3.0/7 && early<1,"Dock liquid recedes from full width to the real progress fraction")
        progress.pump(0.6)
        func hasPercentage(_ view:NSView)->Bool {
            if let label=view as? NativeLabel,label.stringValue=="43%",!label.isHiddenOrHasHiddenAncestor {return true}
            return view.subviews.contains(where:hasPercentage)
        }
        check(hasPercentage(progress.dock.view),"the real native progress label shows the rounded reported fraction at the right edge")
        func glyph(_ view:NSView)->NSView? {
            if view.bounds.size==CGSize(width:14,height:14),view.layer?.sublayers?.contains(where:{($0 as? CAShapeLayer)?.path != nil})==true,!view.isHiddenOrHasHiddenAncestor {return view}
            return view.subviews.compactMap(glyph).first
        }
        check(glyph(progress.dock.view)?.isFlipped==true,"the small native status glyph uses the celestial path's authored downward-y coordinates")
        let progressCallbacks=progress.callbacks;progress.pump(2);let settled=progress.callbacks;progress.pump(0.5)
        check(settled>=progressCallbacks && progress.callbacks==settled,"the percentage and liquid finish their finite settle and sleep")
        rows.append(["case":"progress","widthAt0.1":early,"presentation":progress.ink]);progress.close()
        let reclaim=DockTideRound6Verification.Fixture();reclaim.start();reclaim.command();reclaim.pump(1)
        let borrowed=reclaim.dock.items["C"]!.glass.frame
        _=reclaim.dock.pointer(CGPoint(x:borrowed.midX,y:borrowed.midY),now:reclaim.now)
        var selected=0,exterior=0.0
        for tick in 1...20 {
            reclaim.pump(1.0/120)
            guard Double(tick)/120>=0.07 else{continue}
            let shapes=reclaim.dock.tideMaterialProbe["shapes"] as? [[String:Any]] ?? []
            guard let shape=shapes.first(where:{$0["owner"] as? String=="C"}),let b=shape["body"] as? [CGFloat],b.count==4 else{continue}
            let tail=shape["tail"] as? [[String:Any]] ?? [];guard !tail.isEmpty else{continue};selected+=1
            let radius=min(b[2],b[3])/2,center=CGPoint(x:b[0]+radius,y:b[1]+b[3]/2)
            for part in tail {if let r=part["rect"] as? [CGFloat],r.count==4 {exterior=max(exterior,hypot(r[0]+r[2]/2-center.x,r[1]+r[3]/2-center.y)+r[2]/2-radius)}}
        }
        check(selected>0 && exterior<0.0001,"reclaimed tail root enters its own native body before its final glass pieces retire")
        rows.append(["case":"reclaim-root","samples":selected,"maximumExterior":exterior]);reclaim.close()
        let pin=DockTideRound6Verification.Fixture();pin.store.conversation("C")!.draft=" "
        pin.start();pin.approval("pin-r9");pin.pump(0.8);pin.dock.pinTide();pin.pump(2)
        let column=pin.scene.columns.first{$0.conversation.id=="C"}!
        let ink=column.briefContent.convert(column.briefContent.bounds,to:pin.scene.sceneView.layer)
        let card=pin.dock.items["D"]!.glass.frame
        check(ink.maxY<=card.minY-11.999 || ink.maxX<=card.minX || ink.minX>=card.maxX,"protected pin reserves reading space above the actual card")
        _=pin.dock.dismissTide();pin.pump(2)
        check(abs(column.briefContent.transform.m42)<0.001,"pin retirement restores the retained reading ink")
        pin.close()
        let expired=DockTideRound6Verification.Fixture();expired.start();expired.approval("expired-r9");expired.pump(14)
        let before=expired.dock.items["C"]!.glass.frame
        expired.emit("core/approvalExpired",["approvalId":"expired-r9"]);expired.pump(0.05)
        check(expired.p["phase"] as? String=="idle" && expired.dock.items["C"]!.glass.frame==before,"expired pending cleanup cannot borrow and bounce an already returned brief")
        expired.close()
        for ending in ["resign","close","epoch","reduce"] {
            let f=DockTideRound6Verification.Fixture()
            let window=NSWindow(contentRect:f.dock.view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;let host=NSView(frame:f.dock.view.bounds);window.contentView=host;host.addSubview(f.dock.view)
            if ending=="reduce" {
                arguments[key]=true;defaults.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
                f.scene.reduceMotionChanged()
            }
            f.start();f.approval("exit-r9");f.pump(1)
            let before=f.dock.items.mapValues{$0.glass.frame}
            if ending=="resign" {
                window.resignKey()
                check(f.p["phase"] as? String=="returning" && f.dock.items["C"]!.glass.frame==before["C"],"resign starts a finite retreat from displayed native glass")
                f.pump(2)
            } else if ending=="close" {
                window.close()
                check(f.dock.items["C"]!.glass.frame==before["C"] && f.dock.items["D"]!.glass.frame==before["D"],"willClose preserves the window's final native compositor frame")
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
            } else if ending=="epoch" {
                f.scene.modeContentEpochFrozen=true;f.scene.beginModeHandoff();f.scene.suspendModePresentation();f.scene.setTranscriptPresentationActive(false)
                f.now+=0.2;f.force()
                check(f.p["phase"] as? String=="frozen" && f.dock.items["C"]!.glass.frame==before["C"] && f.dock.items["D"]!.glass.frame==before["D"],"suspend cannot repaint Tide inside the frozen mode-content epoch")
                f.scene.modeContentEpochFrozen=false;f.scene.endModeHandoff()
            } else {
                f.emit("turn/completed",["turn":["id":.string(f.turn),"status":"interrupted"]])
                _=f.dock.dismissTide()
                // A real pointer leave can consume the reduced endpoint before the next display callback.
                f.now+=1.0/120;_=f.dock.pointer(nil,now:f.now);f.force()
                check(abs(f.dock.items["C"]!.glass.frame.width-f.dock.items["C"]!.target.width)<0.01,"Reduce Motion returns all native brief geometry in the same endpoint transaction")
                check((f.dock.tideMaterialProbe["shapes"] as? [[String:Any]])?.isEmpty==true,"Reduce Motion retires every retained tail and borrowed face in the endpoint transaction")
                arguments[key]=false;defaults.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
            }
            check(f.p["phase"] as? String=="idle","exit finishes without a hidden Tide clock: "+ending)
            check(f.store.conversation("D")!.approvals.count==1,"exit does not answer pending requests: "+ending)
            rows.append(["case":ending,"before":before.mapValues(DockTideShape.rect),"after":f.dock.items.mapValues{DockTideShape.rect($0.glass.frame)},"probe":f.dock.tideLightProbe])
            window.contentView=nil;if ending != "close" {window.close()};f.close()
        }
        check(NSApp.windows.allSatisfy{!$0.isVisible},"round9 never orders a window")
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round9.json"))
    }
    private static func retreat(_ kind:String,to rows:inout [[String:Any]],check:(Bool,String)->Void)throws {
        let f=DockTideRound6Verification.Fixture();var link=false,until = -Double.infinity
        f.dock.onNeedsFrames={d in until=max(until,f.now+d);link=true}
        f.dock.onNeedsFramesUntil={t in until=max(until,t);link=true}
        f.start()
        if kind=="approval" {f.approval("retreat-r9")}else {f.emit("core/pulseProgress",["completed":7,"total":7])}
        let began=f.now;var previous=f.dock.items["D"]!.glass.frame,maxEdge=0.0,maxFirst=0.0
        var frames:[[String:Any]]=[]
        for tick in 1...1800 {
            f.now=began+Double(tick)/120
            if let due=f.dock.tideLightProbe["nextWakeAt"] as? Double,f.now>=due+0.060 {f.dock.serviceTideDeadline()}
            if link {
                let target=f.now+1.0/120
                f.dock.frame(at:target,elapsed:.infinity)
                let rect=f.dock.items["D"]!.glass.frame
                let edge=max(abs(rect.minX-previous.minX),abs(rect.maxX-previous.maxX),abs(rect.minY-previous.minY),abs(rect.maxY-previous.maxY))
                let phase=f.dock.tideLightProbe["phase"] as? String ?? ""
                if f.now-began>6.8 {maxEdge=max(maxEdge,edge)}
                if phase=="returning",maxFirst==0 {maxFirst=edge}
                frames.append(["t":f.now-began,"rect":DockTideShape.rect(rect),"edge":edge,"phase":phase]);previous=rect
                if target>until {link=false}
            }
        }
        let bound=DockTideRound7Verification.widthBound(458,32,(0.50,0.86))+DockTideRound7Verification.widthBound(268,0,(0.56,0.68))
        check(maxEdge<=bound,"every native retreat edge stays within the two original free-spring channels: \(kind) \(maxEdge) <= \(bound)")
        check(maxFirst<bound,"occupancy retreat begins at a single displayed step: "+kind)
        check(f.p["phase"] as? String=="idle","the sampled retreat reaches its ordinary native endpoint: "+kind)
        rows.append(["case":"native-retreat-"+kind,"maximumEdge":maxEdge,"firstReturnEdge":maxFirst,"bound":bound,"frames":frames]);f.close()
    }

}
#endif
