import AppKit
import QuartzCore

extension TranscriptHandoffVerification {
    /// Long, synthetic history with a mid-viewport goal and narration at the bottom edge.
    static func verifyEdgeFlights(check:(Bool,String)->Void) {
        let prior=ColumnTranscriptHandoff.verificationThreshold
        defer {ColumnTranscriptHandoff.verificationThreshold=prior}
        ColumnTranscriptHandoff.verificationThreshold=8
        for scale:CGFloat in [1,2] {for action in ["point","focus","split","resize","mode","land","header","side"] {autoreleasepool {
            let store=ConversationStore()
            let mock=MockReplay(store:store,includeSidebarHistory:true);mock.start(live:false)
            let c=store.conversations.first{$0.id=="C"}!
            c.items.insert(TranscriptItem(id:"edge-prefix",kind:.assistant,text:String(repeating:"Offline scrollable history. ",count:500),running:false),at:0)
            if let i=c.items.firstIndex(where:{$0.id=="C-1"}) {
                c.items[i].text="Outline the release notes for 0.1.2. " + String(repeating:"Keep each offline change clear and concrete. ",count:14)
            }
            if action=="side",let i=c.items.firstIndex(where:{$0.id=="C-2"}) {
                c.items[i].text=String(repeating:"W",count:68) + " go now.\n\n" + (0..<4).map{"Offline supporting detail \($0)."}.joined(separator:"\n")
            }
            c.items.append(TranscriptItem(id:"edge-future",turnID:"older-turn",kind:.assistant,text:String(repeating:"Later offline context. ",count:500)))
            let targetSlot=action=="side" ? 1:2
            let members=action=="side" ? ["A","C","B"]:MockSeed.windowMembers
            let size=CGSize(width:1600,height:823)
            let scene=AutoScene(size:size,store:store,profile:.init(name:"edge-flights",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:NativeTranscriptSessions())
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false;scene.setTranscriptPresentationActive(true)
            var clock=CACurrentMediaTime()+3600;scene.now={clock};scene.install(members:members);scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()
            let column=scene.columns[targetSlot]
            column.layoutNative(fullWidth:scene.fullWidth(targetSlot,scene.layout))
            if let goal=column.native.textSnapshot(itemID:"C-1",scale:scale) {
                column.native.scrollOffset.y += goal.rect.midY-250
            }
            column.native.followsEnd=false;column.atEndBeforeMotion=false;column.invalidateCaptures()
            let goal=column.native.textSnapshot(itemID:"C-1",scale:scale)!
            print("EDGE SHAPE",scale,action,"goal",goal.rect,"viewport",column.native.bounds,"offset",column.native.scrollOffset,"end",column.native.distanceFromEnd)
            check(abs(goal.rect.height-154)<3,"EDGE realistic 154pt goal \(scale)x")
            check(column.native.bounds.contains(goal.rect) && column.native.distanceFromEnd>600 && column.native.scrollOffset.y>600,"EDGE goal visible with reader in middle \(scale)x")
            scene.switchTo(targetSlot,reason:"edge-flights")
            let start=clock,nodes=scene.flights[scene.current] ?? []
            check(nodes.contains{$0.line.look == .goal} && nodes.filter{$0.line.look == .segment}.count>=2,"EDGE actual goal and two narration flights \(scale)x")
            var edge:Double?,exchange:Double?,pop=0.0
            let wheel=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:0,wheel2:0,wheel3:0)!)!
            M10ColumnWorkTrace.reset()
            clock=start+0.12;_=scene.transcriptWheel(wheel,at:CGPoint(x:column.rect.sample(0.12).rect.midX,y:column.nativeArea.midY))
            let host=scene.sceneView.layer!,renderer=OffscreenRenderer(size:size,host:host,scale:scale)
            for k in 15...60 {
                let t=Double(k)/120;clock=start+t
                if edge==nil,MotionStep.edge(column.rect.sample(t).rect,column.rect.target)<=8 {edge=t}
                let ready=column.transcriptWheelReady(at:t,flights:nodes) || column.transcriptReady(at:t,threshold:8,flightThreshold:1.5,flights:nodes)
                let before=ready ? renderer.render(at:clock):nil
                scene.frame(clock)
                if column.transcriptHandoff.handedOff {
                    exchange=t
                    if let before {
                        installNativePixels(column,at:t,in:host)
                        pop=renderer.tileDiff(before,renderer.render(at:clock)).value
                    }
                    break
                }
            }
            if edge==nil {for k in 0...60 {let t=Double(k)/120;if MotionStep.edge(column.rect.sample(t).rect,column.rect.target)<=8 {edge=t;break}}}
            print("EDGE EXCHANGE",scale,action,"edge8",edge ?? -1,"handoff",exchange ?? -1,"continued",column.hasContinuedTranscriptFlights,"pop",pop)
            let viewport=column.transcriptViewportFrame(at:0.25)
            let outside=nodes.filter{$0.line.look == .segment}.filter {node in
                let box=node.continuationBounds(rect:column.rect.sample(0.25).rect,form:column.form.sample(0.25).value,lyricSize:column.lyricSize)
                return box.maxY>viewport.maxY-28 || box.maxX>viewport.maxX
            }
            if action=="side" {
                check(nodes.contains{$0.line.look == .segment && $0.continuationBounds(rect:column.rect.sample(0.25).rect,form:column.form.sample(0.25).value,lyricSize:column.lyricSize).maxX>viewport.maxX},"EDGE wide narration crosses the right viewport boundary \(scale)x")
            }
            check(!outside.isEmpty,"EDGE narration reaches outside the opaque bottom/side band \(scale)x")
            print("EDGE COSTS",scale,action,M10ColumnWorkTrace.events.filter{$0.name.hasPrefix("column.handoff")}.map{"\($0.name)=\(($0.end-$0.start)*1000)"}.joined(separator:" "))
            check(column.hasContinuedTranscriptFlights,"EDGE continuation really starts \(scale)x")
            check((exchange ?? 9)<=(edge ?? -1)+2.0/120+0.00001,"EDGE handoff by edge8 plus two frames \(scale)x")
            check(pop<=SelfTest.popThreshold,"EDGE exchange pop <= unchanged 2.0: \(pop) \(scale)x")
            if column.hasContinuedTranscriptFlights {
                let offset=column.native.scrollOffset.y,visibility=column.transcriptHandoff.previousFlightVisibility
                let step:Int32=action=="header" ? -8:1
                let input=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:step,wheel2:0,wheel3:0)!)!
                clock += 1.0/120;scene.frame(clock)
                for _ in 0..<8 {
                    if action=="land" || action=="header" || action=="side" {clock += 1.0/120;scene.frame(clock)}
                    _=scene.transcriptWheel(input,at:CGPoint(x:column.rect.sample(clock-start).rect.midX,y:column.nativeArea.midY))
                }
                let actual=column.native.scrollOffset.y
                column.native.scrollOffset.y=offset
                for _ in 0..<8 {column.native.scrollView.scrollWheel(with:input)}
                check(abs(actual-column.native.scrollOffset.y)<0.51 && abs(actual-offset)>70,"EDGE eight actual steps equal direct native delivery \(action) \(scale)x")
                check(abs((column.transcriptHandoff.flightScroll?.position.y ?? 999)-(offset-actual))<0.01,"EDGE every wheel transports retained glyphs \(action) \(scale)x")
                check(column.hasContinuedTranscriptFlights,"EDGE interruption/landing fixture owns both planes \(action) \(scale)x")
                if action=="header",let root=column.transcriptHandoff.flightRoot {
                    for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
                    installNativePixels(column,at:clock-start,in:host)
                    let visible=renderer.render(at:clock)
                    CATransaction.begin();CATransaction.setDisableActions(true);root.isHidden=true;CATransaction.commit()
                    let hidden=renderer.render(at:clock)
                    CATransaction.begin();CATransaction.setDisableActions(true);root.isHidden=false;CATransaction.commit()
                    let top=column.transcriptViewportFrame(at:clock-start).minY
                    let bytes=max(0,min(visible.count,Int((top*scale).rounded(.down))*renderer.w*4))
                    check(visible.prefix(bytes)==hidden.prefix(bytes),"EDGE scrolled flight contributes zero pixels above viewport/header \(scale)x")
                    check(nodes.contains{$0.line.look == .goal && $0.screenPose(rect:column.rect.sample(clock-start).rect,form:column.form.sample(clock-start).value).origin.y<top},"EDGE header protection is exercised by an offscreen transported goal \(scale)x")
                }
                if action=="land" || action=="header" || action=="side" {clock=start+column.form.duration+1.0/120}
                for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
                installNativePixels(column,at:clock-start,in:host)
                let before=renderer.render(at:clock)
                for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
                switch action {
                case "point":scene.switchTo(1,reason:"edge-reverse")
                case "focus":scene.enterFocused(scene.current,reason:"edge-focus")
                case "split":scene.transition(to:scene.members,current:scene.current,scheme:AutoScene.Scheme(mode:.focused,split:[scene.current,"B"],left:[],right:[]),spring:AutoScene.focusSpring,reason:"edge-split")
                case "resize":scene.resize(to:CGSize(width:1500,height:850),live:false)
                case "mode":scene.suspendModePresentation()
                default:scene.frame(clock);installNativePixels(column,at:clock-start,in:host)
                }
                check(!column.hasContinuedTranscriptFlights && column.transcriptHandoff.scrollObservation==nil && column.transcriptHandoff.previousFlightVisibility==nil,"EDGE interruption releases owner, observer and glyph lease \(action) \(scale)x")
                check(column.native.flightVisibility()==visibility,"EDGE cleanup restores prior native visibility \(action) \(scale)x")
                if action != "resize" && action != "mode" {
                    let after=renderer.render(at:clock),interruptionPop=renderer.tileDiff(before,after).value
                    print("EDGE LIFECYCLE",scale,action,"pop",interruptionPop,"at",renderer.tileDiff(before,after).at,"time",clock-start)
                    check(interruptionPop<=SelfTest.popThreshold,"EDGE interruption/landing pop <= unchanged 2.0 \(action) \(scale)x: \(interruptionPop)")
                }
                if action=="land" || action=="header" || action=="side" {check(abs(column.native.scrollOffset.y-actual)<0.51,"EDGE landing keeps reader \(action) \(scale)x")}
            }
        }}}
    }
}
