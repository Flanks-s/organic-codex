import AppKit
import QuartzCore

extension TranscriptHandoffVerification {
    /// Preserve the old frozen base while revealing only the multiline goal's uncarried body at native admission.
    static func verifyGoalReveal(check:(Bool,String)->Void) {
        let prior=ColumnTranscriptHandoff.verificationThreshold
        defer {ColumnTranscriptHandoff.verificationThreshold=prior}
        ColumnTranscriptHandoff.verificationThreshold=8
        for scale:CGFloat in [1,2] {for action in ["point","focus","split","land","selected","lease","resize","mode"] {autoreleasepool {
            let store=ConversationStore(),sessions=NativeTranscriptSessions()
            let mock=MockReplay(store:store,includeSidebarHistory:true);mock.start(live:false)
            let c=store.conversations.first{$0.id=="C"}!
            let heading="<send_user_message_question_reply> 😀"
            let raw=heading+"\n"+(0..<7).map{"Read detail \($0), including `code` and **context**."}.joined(separator:"\n")
            c.items.insert(TranscriptItem(id:"reveal-prefix",kind:.assistant,text:String(repeating:"Offline scrollable history. ",count:500),running:false),at:0)
            c.items[c.items.firstIndex{$0.id=="C-1"}!].text=raw
            c.items.append(TranscriptItem(id:"reveal-future",turnID:"older-turn",kind:.assistant,text:String(repeating:"Later offline context. ",count:500)))
            let size=CGSize(width:1600,height:823)
            let scene=AutoScene(size:size,store:store,profile:.init(name:"goal-reveal",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:sessions)
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false;scene.setTranscriptPresentationActive(true)
            var clock=CACurrentMediaTime()+3600;scene.now={clock};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()
            let column=scene.columns[2],native=column.native
            column.layoutNative(fullWidth:scene.fullWidth(2,scene.layout))
            let goal=native.textSnapshot(itemID:"C-1",scale:scale)!
            native.scrollOffset.y += goal.rect.midY-250
            native.followsEnd=false;column.atEndBeforeMotion=false
            let first=NSRange(location:0,length:(heading as NSString).length)
            let selected=NSRange(location:8,length:first.length+22-8)
            if action=="selected" {native.setSelectedRange(selected,itemID:"C-1")}
            let original=native.flightVisibility()
            column.invalidateCaptures();scene.switchTo(2,reason:"multiline-goal-reveal")
            let start=clock,nodes=scene.flights["C"] ?? [],snapshot=column.snapshots[column.applied!]!
            check(nodes.contains{$0.line.look == .goal} && nodes.filter{$0.line.look == .segment}.count==2,"REVEAL actual goal and two narration flights \(scale)x \(action)")
            check(native.distanceFromEnd>600 && native.scrollOffset.y>600,"REVEAL reader is in long history \(scale)x \(action)")
            let legacy=snapshot.flightVisibility!
            // Build the expected token independently through Native's public raw-range API.
            native.restoreFlightVisibility(legacy);native.setTextHidden(false,itemID:"C-1")
            native.setTextHidden(true,itemID:"C-1",range:first)
            let wanted=native.flightVisibility();native.restoreFlightVisibility(original)
            check(snapshot.continuationFlightVisibility==wanted,"REVEAL successful slice ranges match raw UTF-16 first line \(scale)x \(action)")
            let zero=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:0,wheel2:0,wheel3:0)!)!
            M10ColumnWorkTrace.reset()
            clock=start+0.12;_=scene.transcriptWheel(zero,at:CGPoint(x:column.rect.sample(0.12).rect.midX,y:column.nativeArea.midY))
            // Match the real view stack: native and its flights stay below the Dock's foreground.
            let host=CALayer();host.anchorPoint = .zero;host.frame=scene.scene.bounds
            scene.scene.insertSublayer(host,below:scene.dock.layer)
            let renderer=OffscreenRenderer(size:size,host:scene.sceneView.layer!,scale:scale)
            let reference=CALayer();reference.backgroundColor=Look.canvas.cgColor
            @MainActor func renderScene()->[UInt8] {
                // Detached AppKit backing can contain stale partial rows. The verified native bitmap is its
                // sole CARenderer stand-in; never composite that proxy over a second AppKit backing owner.
                let hidden=native.layer!.isHidden
                CATransaction.begin();CATransaction.setDisableActions(true);native.layer!.isHidden=true;CATransaction.commit()
                let pixels=renderer.render(at:clock)
                CATransaction.begin();CATransaction.setDisableActions(true);native.layer!.isHidden=hidden;CATransaction.commit()
                return pixels
            }
            @MainActor func renderReference()->[UInt8] {
                let fresh=OffscreenRenderer(size:size,host:reference,scale:scale)
                return fresh.render(at:clock)
            }
            @MainActor func image(_ state:NativeTranscript.FlightVisibility)->CGImage {
                let old=native.flightVisibility(),hidden=native.isHidden,layerHidden=native.layer!.isHidden,mask=native.layer!.mask
                native.restoreFlightVisibility(state);native.isHidden=false;native.layer!.isHidden=false;native.layer!.mask=nil
                let result=native.snapshot(scale:scale)
                native.restoreFlightVisibility(old);native.isHidden=hidden;native.layer!.isHidden=layerHidden;native.layer!.mask=mask
                return result
            }
            @MainActor func referencePixels(_ bitmap:CGImage,_ t:Double)->[UInt8] {
                reference.sublayers=[]
                let layer=CALayer();layer.anchorPoint = .zero;layer.contents=bitmap;layer.contentsScale=scale;layer.contentsGravity = .resize
                layer.frame=native.frame;layer.transform=column.transcriptTailTransform(at:t)
                let fade=ColumnNode.fade();column.shapeFade(fade,column.nativeArea.size)
                fade.bounds.size.width += column.rect.w.sample(t).value-column.rect.w.to;layer.mask=fade
                reference.addSublayer(layer);let pixels=renderReference();reference.sublayers=[];return pixels
            }
            var exchanged=false,maxOffset:CGFloat=0
            for k in 15...60 {
                let t=Double(k)/120;clock=start+t
                guard column.transcriptWheelReady(at:t,flights:nodes) else {scene.frame(clock);continue}
                let before=renderScene()
                scene.frame(clock)
                check(column.hasContinuedTranscriptFlights,"REVEAL continuation really starts \(scale)x \(action)")
                guard column.transcriptHandoff.flightRoot != nil else {break}
                let oldPixels=referencePixels(image(legacy),t),expectedPixels=referencePixels(image(wanted),t)
                installNativePixels(column,at:t,in:host)
                let after=renderScene()
                var allowedBefore=before,revealedPixels=0,outsideGoal=0
                let currentVisibility=native.flightVisibility()
                native.restoreFlightVisibility(wanted)
                let goalRect=native.textSnapshot(itemID:"C-1",scale:scale)!.rect
                native.restoreFlightVisibility(currentVisibility)
                let projected=goalRect.applying(CATransform3DGetAffineTransform(column.transcriptTailTransform(at:t))).offsetBy(dx:native.frame.minX,dy:native.frame.minY).insetBy(dx:-1/scale,dy:-1/scale)
                // Exclude only changed pixels inside this goal, never other rows or the enclosing viewport.
                for i in stride(from:0,to:before.count,by:4) where oldPixels[i..<i+3] != expectedPixels[i..<i+3] {
                    let pixel=CGPoint(x:CGFloat((i/4)%renderer.w)/scale,y:CGFloat((i/4)/renderer.w)/scale)
                    if projected.contains(pixel) {
                        revealedPixels += 1
                        for c in 0..<4 {allowedBefore[i+c]=after[i+c]}
                    } else {outsideGoal += 1}
                }
                check(outsideGoal==0,"REVEAL reference changes no pixel outside the goal \(scale)x \(action): \(outsideGoal)")
                let restPop=renderer.tileDiff(allowedBefore,after).value,bodyPop=renderer.tileDiff(oldPixels,expectedPixels).value
                let footprints=nodes.flatMap {node in [t,t-column.motionProfile.frameInterval].map {sample in
                    node.continuationBounds(rect:column.rect.sample(sample).rect,form:column.form.sample(sample).value,lyricSize:column.lyricSize).insetBy(dx:-1/scale,dy:-1/scale)
                }}
                var flightBefore=after
                for i in stride(from:0,to:before.count,by:4) {
                    let pixel=CGPoint(x:CGFloat((i/4)%renderer.w)/scale,y:CGFloat((i/4)/renderer.w)/scale)
                    if footprints.contains(where:{$0.contains(pixel)}) {for c in 0..<4 {flightBefore[i+c]=allowedBefore[i+c]}}
                }
                let flightPop=renderer.tileDiff(flightBefore,after).value
                check(flightPop<=SelfTest.popThreshold,"REVEAL carried glyph exchange pop <= 2.0 \(scale)x \(action): \(flightPop)")
                check(restPop<=SelfTest.popThreshold,"REVEAL all other pixels keep unchanged 2.0 gate \(scale)x \(action): \(restPop)")
                check(revealedPixels>0,"REVEAL expected body contains actual ink \(scale)x \(action)")
                check(image(native.flightVisibility()).dataProvider!.data == image(wanted).dataProvider!.data,"REVEAL body visible and native first line hidden on the handoff frame \(scale)x \(action)")
                for sample in 0...120 {
                    let time=t+(column.form.duration-t)*Double(sample)/120
                    for node in nodes where node.line.look == .goal {
                        let p=node.screenPose(rect:column.rect.sample(time).rect,form:column.form.sample(time).value)
                        let end=node.screenPose(rect:column.rect.target,form:1),tail=column.transcriptTailTransform(at:time)
                        let extent=max(node.line.source.width,node.line.source.height)
                        let inner=max(0,column.lyricSize/13-1)*p.u
                        maxOffset=max(maxOffset,max(abs(p.origin.x-end.origin.x-tail.m41),abs(p.origin.y-end.origin.y-tail.m42))+abs(p.scale-end.scale)*extent+inner*extent)
                    }
                }
                print("REVEAL EXCHANGE",scale,action,"t",t,"flightPop",flightPop,"otherPop",restPop,"bodyPop",bodyPop,"bodyPixels",revealedPixels,"maxOffsetBound",maxOffset)
                print("REVEAL COSTS",scale,action,M10ColumnWorkTrace.events.filter{$0.name.hasPrefix("column.handoff")}.map{"\($0.name)=\(($0.end-$0.start)*1000)"}.joined(separator:" "))
                exchanged=true;break
            }
            check(exchanged,"REVEAL multiline fixture reaches a measured handoff \(scale)x \(action)")
            guard exchanged else {return}
            let offset=native.scrollOffset.y
            let wheel=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:1,wheel2:0,wheel3:0)!)!
            for _ in 0..<8 {clock+=1.0/120;scene.frame(clock);_=scene.transcriptWheel(wheel,at:CGPoint(x:column.rect.sample(clock-start).rect.midX,y:column.nativeArea.midY))}
            let actual=native.scrollOffset.y
            native.scrollOffset.y=offset;for _ in 0..<8 {native.scrollView.scrollWheel(with:wheel)}
            check(abs(native.scrollOffset.y-actual)<0.51 && offset-actual>79,"REVEAL eight of eight real wheel steps and reader position \(scale)x \(action)")
            check(image(native.flightVisibility()).dataProvider!.data == image(wanted).dataProvider!.data,"REVEAL body stays visible after scrolling \(scale)x \(action)")
            if action=="land" || action=="selected" {clock=start+column.form.duration+1.0/120}
            for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
            installNativePixels(column,at:clock-start,in:host);let before=renderScene()
            for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
            switch action {
            case "point":scene.switchTo(1,reason:"reveal-point")
            case "focus":scene.enterFocused(scene.current,reason:"reveal-focus")
            case "split":scene.transition(to:scene.members,current:scene.current,scheme:AutoScene.Scheme(mode:.focused,split:[scene.current,"B"],left:[],right:[]),spring:AutoScene.focusSpring,reason:"reveal-split")
            case "lease":
                let recipient=NSView(frame:native.frame)
                let lease=sessions.mount(c,in:recipient,frame:native.frame,store:store)
                check(lease?.isCurrent==true,"REVEAL lease really transfers to a second host \(scale)x")
            case "resize":scene.resize(to:CGSize(width:1500,height:850),live:false)
            case "mode":scene.suspendModePresentation()
            default:scene.frame(clock);installNativePixels(column,at:clock-start,in:host)
            }
            check(!column.hasContinuedTranscriptFlights && column.transcriptHandoff.previousFlightVisibility==nil && column.transcriptHandoff.scrollObservation==nil,"REVEAL cleanup releases all continuation state \(scale)x \(action)")
            check(native.flightVisibility()==original,"REVEAL cleanup restores every native glyph \(scale)x \(action)")
            if ["point","focus","split","land","selected"].contains(action) {
                let after=renderScene(),pop=renderer.tileDiff(before,after).value
                print("REVEAL CLEANUP",scale,action,"pop",pop)
                check(pop<=SelfTest.popThreshold,"REVEAL interruption/landing pop <= 2.0 \(scale)x \(action): \(pop)")
            }
            if action=="land" || action=="selected" {check(abs(native.scrollOffset.y-actual)<0.51,"REVEAL landing keeps reader \(scale)x \(action)")}
            if action=="selected" {check(native.selectedRange(itemID:"C-1")==selected,"REVEAL selection survives partial hiding and cleanup \(scale)x")}
        }}}
    }
}
