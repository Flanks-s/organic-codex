import AppKit
import QuartzCore

/// Tests the native exchange and RootView's post-Peek/queue route, with no window or backend.
@MainActor enum TranscriptHandoffVerification {
    static func run(check:(Bool,String)->Void) {
        let previous=ColumnTranscriptHandoff.verificationThreshold
        let previousFlight=ColumnTranscriptHandoff.verificationFlightThreshold
        defer {ColumnTranscriptHandoff.verificationThreshold=previous;ColumnTranscriptHandoff.verificationFlightThreshold=previousFlight}
        ColumnTranscriptHandoff.verificationThreshold=1
        ColumnTranscriptHandoff.verificationFlightThreshold=1.5
        verifyIndependentThresholds(check:check)
        verifyEarlyWheel(check:check)
        verifyEarlyFlight(check:check)
        verifyFlightLifecycle(check:check)
        verifyEdgeFlights(check:check)
        verifyGoalReveal(check:check)
        for shared in [false,true] {for scale:CGFloat in [1,2] {autoreleasepool {
            let conversations=["A","B","C"].map { id in
                let c=Conversation(id:id,title:"Offline \(id)")
                c.items=(0..<120).map { i in TranscriptItem(id:"\(id)-\(i)",kind:i % 4 == 0 ? .user:.assistant,text:"Paragraph \(i). " + String(repeating:"Keep the reading anchor through a column width change. ",count:5),running:false) }
                return c
            }
            let store=ConversationStore(conversations:conversations,projects:MockSeed.projects,devices:MockSeed.devices)
            let size=CGSize(width:1600,height:900)
            let scene=AutoScene(size:size,store:store,profile:.init(name:"freeze-offscreen",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:shared ? NativeTranscriptSessions():nil)
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false
            if shared {scene.setTranscriptPresentationActive(true)}
            var clock=VerificationClock.renderOrigin;scene.now={clock};scene.install(members:conversations.map(\.id));scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            let tag="\(Int(scale))x-\(shared ? "shared":"owned")"
            var exchangeOffsets:[String:CGFloat]=[:]
            @MainActor func finish() {
                clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()
                for column in scene.columns where column.isFull {
                    if let offset=exchangeOffsets[column.conversation.id] {
                        check(abs(column.native.scrollOffset.y-offset)<0.51,"FREEZE handoff-to-settle keeps the reader position \(tag)")
                    }
                }
                exchangeOffsets=[:]
            }
            @MainActor func advance(_ name:String) {
                let start=clock,end=scene.transitionEnd
                var exchanged=false
                for k in 0...Int(ceil(max(0,end-start)*120)) {
                    clock=start+Double(k)/120;scene.frame(clock)
                    let full=scene.columns.filter(\.isFull)
                    if !full.isEmpty,full.allSatisfy({$0.transcriptHandoff.handedOff}) {
                        exchanged=true
                        check(clock<end-1/120,"FREEZE early native exchange \(name) \(tag)")
                        check(full.allSatisfy{!$0.native.isHidden && $0.inkMaterial.isHidden && (scene.flights[$0.conversation.id] == nil || $0.hasContinuedTranscriptFlights)},"FREEZE one transcript owner after exchange \(name) \(tag)")
                        check(full.allSatisfy{!$0.hasFullReflow && $0.native.layer?.animation(forKey:"column.settle.slide")==nil},"FREEZE no wrap mixture or scroll slide at exchange \(name) \(tag)")
                        exchangeOffsets=Dictionary(uniqueKeysWithValues:full.map{($0.conversation.id,$0.native.scrollOffset.y)})
                        for column in full {
                            // Compare the exact native layout against the frozen arrival material, with identical masks.
                            // Buffered input intentionally changes the viewport; its movement is checked separately.
                            if let key=column.applied,abs(key.offset-column.native.scrollOffset.y)<0.51,
                               let expected=column.snapshots[key]?.withGoal {
                                let mask=column.native.layer?.mask;column.native.layer?.mask=nil
                                let actual=column.native.snapshot(scale:scale);column.native.layer?.mask=mask
                                check(expected.dataProvider?.data == actual.dataProvider?.data,"FREEZE native handoff material is byte exact \(name) \(tag)")
                            }
                            if let tail=column.native.layer?.animation(forKey:"column.motion.tail") as? CAKeyframeAnimation,let values=tail.values as? [NSValue],let end=values.last?.caTransform3DValue {
                                check(tail.isAdditive && CATransform3DIsIdentity(end),"FREEZE analytic additive tail lands exactly \(name) \(tag)")
                            } else {check(false,"FREEZE native tail exists \(name) \(tag)")}
                        }
                        print("FREEZE HANDOFF",name,tag,"seconds",clock-start,"settle",end-start)
                        if name=="auto-wheel" {
                            for (index,event) in M10ColumnWorkTrace.events.enumerated() where event.name=="column.handoffTranscript" && event.fields["queued"] as? Int==32 {
                                let children=M10ColumnWorkTrace.events.filter{$0.parent==index}
                                print("EARLY QUEUED32 COST",tag,"totalMs",(event.end-event.start)*1000,"parts",children.map{"\($0.name)=\(($0.end-$0.start)*1000)"}.joined(separator:" "))
                            }
                        }
                        break
                    }
                }
                check(exchanged,"FREEZE full columns exchange before settle \(name) \(tag)")
            }
            @MainActor func wheel(_ delta:Int32)->NSEvent {
                NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:delta,wheel2:0,wheel3:0)!)!
            }
            finish()
            scene.switchTo(1,reason:"freeze-wheel")
            let reader=scene.columns.first{$0.isFull}!
            let atEnd=reader.native.scrollOffset.y
            let p=CGPoint(x:reader.rect.sample(0).rect.midX,y:reader.nativeArea.midY)
            ColumnTranscriptHandoff.replayDepth=1
            check(!scene.transcriptWheel(wheel(1),at:p),"FREEZE replay cannot re-enter the Root wheel route \(tag)")
            ColumnTranscriptHandoff.replayDepth=0
            check(!scene.transcriptWheel(wheel(1),at:CGPoint(x:-10,y:20)),"FREEZE pointer outside full column keeps existing route \(tag)")
            for _ in 0..<32 {check(scene.transcriptWheel(wheel(1),at:p),"FREEZE pre-exchange wheel accepted \(tag)")}
            check(reader.transcriptHandoff.events.count==32 && reader.native.scrollOffset.y==atEnd,"FREEZE queued wheel retains order before exchange \(tag)")
            if let sessions=scene.transcriptSessions {
                let alias=ColumnNode(reader.conversation,store:store,identity:.systemBlue,rect:reader.rect.target,full:true,scale:scale,logicalBottom:reader.logicalBottom,transcriptSessions:sessions)
                check(alias.native === reader.native && alias.transcriptHandoff !== reader.transcriptHandoff,"FREEZE shared native hosts own separate column motion state \(tag)")
                alias.beginTranscriptMotion()
                check(reader.transcriptHandoff.active && reader.transcriptHandoff.events.count==32,"FREEZE borrowed host cannot reset the current owner's pending input \(tag)")
            }
            advance("auto-wheel")
            check(reader.transcriptHandoff.events.isEmpty && reader.native.scrollOffset.y<atEnd-32,"FREEZE all queued wheel steps reach the native scroll view \(tag)")
            let delivered=reader.native.scrollOffset.y
            reader.native.scrollOffset.y=atEnd
            for _ in 0..<32 {reader.native.scrollView.scrollWheel(with:wheel(1))}
            check(abs(reader.native.scrollOffset.y-delivered)<0.51,"EARLY queued 32 of 32 steps equal direct native replay \(tag)")
            check(!reader.native.readerFollowsEnd,"FREEZE replayed input latches reading intent \(tag)")
            let read=reader.native.scrollOffset.y
            finish()
            check(abs(reader.native.scrollOffset.y-read)<0.51,"FREEZE settle does not undo replayed wheel \(tag)")
            // An interrupted transition must retain the departing target's queue until it is safe to replay hidden.
            scene.switchTo(2,reason:"freeze-interrupt")
            let interrupted=scene.columns.first{$0.isFull}!,before=interrupted.native.scrollOffset.y
            let ip=CGPoint(x:interrupted.rect.sample(0).rect.midX,y:interrupted.nativeArea.midY)
            check(scene.transcriptWheel(wheel(1),at:ip),"FREEZE interrupt fixture queues a wheel \(tag)")
            clock+=0.1;scene.frame(clock);scene.switchTo(1,reason:"freeze-reverse")
            finish()
            check(interrupted.transcriptHandoff.events.isEmpty && interrupted.native.scrollOffset.y<before,"FREEZE interrupted queue is replayed once without changing targets \(tag)")
            // Both Focused directions and every full Split segment use the same exchange.
            for threshold:CGFloat in [2,1,0.5] {
                ColumnTranscriptHandoff.verificationThreshold=threshold
                scene.enterFocused(scene.current,reason:"freeze-focus");advance("focus-in-\(threshold)");finish()
                scene.leaveFocused(reason:"freeze-unfocus");advance("focus-out-\(threshold)");finish()
            }
            ColumnTranscriptHandoff.verificationThreshold=1
            scene.enterFocused(scene.current,reason:"freeze-split-focus");finish()
            let joined=conversations.first{$0.id != scene.current}!.id
            scene.graft(joined,at:1,reason:"freeze-graft")
            check(scene.columns.filter(\.isFull).count==2,"FREEZE Split fixture has two full columns \(tag)")
            advance("split-graft");finish()
            scene.ungraft(joined,reason:"freeze-ungraft");advance("split-ungraft");finish()
            ColumnTranscriptHandoff.verificationThreshold=0
            scene.leaveFocused(reason:"freeze-settle-gap")
            clock=scene.transitionEnd+0.005;scene.frame(clock)
            let gap=scene.columns.first{$0.isFull}!,gapOffset=scene.columns.first{$0.isFull}!.native.scrollOffset.y
            let gp=CGPoint(x:gap.rect.target.midX,y:gap.nativeArea.midY)
            check(scene.transcriptWheel(wheel(1),at:gp),"FREEZE wheel in duration-to-settle gap is retained \(tag)")
            finish()
            check(gap.transcriptHandoff.events.isEmpty && gap.native.scrollOffset.y<gapOffset,"FREEZE disabled early exchange still delivers the final queued wheel \(tag)")
            ColumnTranscriptHandoff.verificationThreshold=1
            for full in scene.columns where full.isFull {full.native.scrollToEnd()}
            scene.resize(to:CGSize(width:1500,height:860),live:true)
            check(scene.columns.filter(\.isFull).allSatisfy{$0.native.distanceFromEnd<0.51 && $0.native.layer?.animation(forKey:"column.motion.tail")==nil},"FREEZE resize remains immediate and keeps end readers at end \(tag)")
        }}}
    }

    /// Exercise the actual mock flights, then observe their removal through AutoScene.frame at the two default gates.
    private static func verifyIndependentThresholds(check:(Bool,String)->Void) {
        // Use a stricter configured flight gate to force a distinct wait even when the default is already satisfied.
        let flightLimit:CGFloat=0.5
        if ProcessInfo.processInfo.environment["M11_TRANSCRIPT_HANDOFF_PT"] == nil {check(ColumnTranscriptHandoff.configuredThreshold==8,"FREEZE transcript default is 8 pt")}
        if ProcessInfo.processInfo.environment["M11_TRANSCRIPT_HANDOFF_FLIGHT_PT"] == nil {check(ColumnTranscriptHandoff.configuredFlightThreshold==1.5,"FREEZE flight default is 1.5 pt")}
        for shared in [false,true] {for scale:CGFloat in [1,2] {autoreleasepool {
            let store=ConversationStore()
            // No backend or live input is attached.
            let replay=MockReplay(store:store,includeSidebarHistory:true);replay.start(live:false)
            let scene=AutoScene(size:CGSize(width:1600,height:900),store:store,profile:.init(name:"freeze-gates",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:shared ? NativeTranscriptSessions():nil)
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false
            if shared {scene.setTranscriptPresentationActive(true)}
            var clock=VerificationClock.renderOrigin;scene.now={clock};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()
            scene.switchTo(2,reason:"freeze-independent-gates")
            let start=clock,end=scene.transitionEnd,column=scene.columns.first{$0.isFull}!
            let nodes=scene.flights[column.conversation.id] ?? []
            let tag="\(Int(scale))x-\(shared ? "shared":"owned")"
            check(!nodes.isEmpty && nodes.contains{$0.line.look == .goal},"FREEZE separate gates fixture has real goal flights \(tag)")
            @MainActor func residual(_ t:Double)->CGFloat {
                nodes.map { flight in
                    let pose=flight.screenPose(rect:column.rect.sample(t).rect,form:column.form.sample(t).value)
                    let end=flight.screenPose(rect:column.rect.target,form:1)
                    let extent=max(flight.line.source.width,flight.line.source.height,flight.line.destination.width,flight.line.destination.height)
                    return max(abs(pose.origin.x-end.origin.x),abs(pose.origin.y-end.origin.y))+abs(pose.scale-end.scale)*extent
                }.max() ?? 0
            }
            var bareTime:Double?,flightTime:Double?,formerTime:Double?,bareResidual:CGFloat=0,formerResidual:CGFloat=0
            for k in 0...Int(ceil((end-start)*120)) {
                let t=Double(k)/120
                if bareTime == nil,column.transcriptReady(at:t,threshold:8,flightThreshold:flightLimit,flights:[]) {
                    bareTime=t;bareResidual=residual(t)
                    check(column.transcriptReady(at:t,threshold:8,flightThreshold:1.5,flights:nodes)==(bareResidual<=1.5),"FREEZE default flight gate accepts exactly its endpoint tolerance \(tag)")
                    check(column.transcriptReady(at:t,threshold:8,flightThreshold:0,flights:[]),"FREEZE no-flight column ignores the flight gate \(tag)")
                    check(!column.transcriptReady(at:t,threshold:8,flightThreshold:flightLimit,flights:nodes),"FREEZE flight column waits after the transcript gate opens \(tag)")
                    func remaining(_ spring:Spring)->Double {let s=spring.sample(t);return abs(s.value-spring.to)+abs(s.velocity)*spring.response/(2 * .pi)}
                    let reach=Double(max(column.rect.target.width,column.rect.target.height))
                    print("FREEZE GATE",tag,"t",t,"rect",max(remaining(column.rect.x)+remaining(column.rect.w),remaining(column.rect.y)+remaining(column.rect.h)),"form",remaining(column.form)*reach,"presence",remaining(column.presence)*reach,"flight",bareResidual,"count",nodes.count)
                }
                if formerTime == nil,column.transcriptReady(at:t,threshold:8,flightThreshold:8,flights:nodes) {formerTime=t;formerResidual=residual(t)}
                if column.transcriptReady(at:t,threshold:8,flightThreshold:flightLimit,flights:nodes) {flightTime=t;break}
            }
            check(bareTime != nil && flightTime != nil && flightTime!>bareTime! && bareResidual>flightLimit,"FREEZE flight and transcript gates have distinct opening times \(tag)")
            check(formerTime != nil && flightTime != nil && formerTime!<flightTime! && formerResidual>flightLimit,"FREEZE former shared 8 pt gate would remove unsettled flights \(tag)")
            print("FREEZE FORMER GATE",tag,"t",formerTime ?? -1,"residual",formerResidual,"flightGateTime",flightTime ?? -1)
            ColumnTranscriptHandoff.verificationThreshold=8
            ColumnTranscriptHandoff.verificationFlightThreshold=flightLimit
            var removed=false
            for k in 0...Int(ceil((end-start)*120)) {
                clock=start+Double(k)/120;scene.frame(clock)
                if column.transcriptHandoff.handedOff {
                    removed=true
                    check(residual(clock-start)<=flightLimit,"FREEZE removed flight residual stays within its own gate \(tag)")
                    check(abs(clock-start-(flightTime ?? -1))<0.00001,"FREEZE scene uses the flight gate for the actual exchange \(tag)")
                    check(scene.flights[column.conversation.id] == nil && !column.native.isHidden,"FREEZE settled flights give way to one native owner \(tag)")
                    print("FREEZE FLIGHT EXCHANGE",tag,"t",clock-start,"residual",residual(clock-start),"limit",flightLimit)
                    break
                }
            }
            check(removed,"FREEZE flight column exchanges before settle at independent configured gates \(tag)")
            clock=end+0.1;scene.frame(clock);scene.settle();scene.clock.invalidate()
            // Focused full-to-full reflow has no flights and must use the larger transcript gate in the real driver.
            scene.enterFocused(scene.current,reason:"freeze-bare-gate")
            let focusStart=clock,focusEnd=scene.transitionEnd,full=scene.columns.first{$0.isFull}!
            check(scene.flights[full.conversation.id]?.isEmpty ?? true,"FREEZE no-flight Focused fixture \(tag)")
            var bareExchanged=false
            for k in 0...Int(ceil((focusEnd-focusStart)*120)) {
                clock=focusStart+Double(k)/120
                let ready=full.transcriptReady(at:clock-focusStart,threshold:8,flightThreshold:0,flights:[])
                scene.frame(clock)
                if ready || full.transcriptHandoff.handedOff {
                    bareExchanged=ready && full.transcriptHandoff.handedOff
                    print("FREEZE BARE EXCHANGE",tag,"t",clock-focusStart,"form",full.form.sample(clock-focusStart).value)
                    break
                }
            }
            check(bareExchanged,"FREEZE no-flight scene exchanges at the transcript gate without waiting for flights \(tag)")
            ColumnTranscriptHandoff.verificationThreshold=1
            ColumnTranscriptHandoff.verificationFlightThreshold=1.5
        }}}
    }


    /// AppKit backing layers require their view host. Use its verified viewport bitmap in CARenderer's scene space.
    /// This compares the original animated material to native pixels at exactly the same analytic pose/time.
    static func installNativePixels(_ column:ColumnNode,at t:Double,in host:CALayer) {
        // Detached AppKit backing layers have no CARenderer time owner. Native animation installation is checked
        // by the unrendered queue fixture above; this fixture compares pixels using the shared analytic pose.
        let layer=CALayer();layer.name="early.native.pixels";layer.anchorPoint = .zero
        let mask=column.native.layer?.mask;column.native.layer?.mask=nil
        let image=column.native.snapshot(scale:column.scale);column.native.layer?.mask=mask
        layer.contents=image;layer.contentsScale=column.scale;layer.contentsGravity = .resize
        layer.frame=column.native.frame;layer.transform=column.transcriptTailTransform(at:t)
        let fade=ColumnNode.fade();column.shapeFade(fade,column.nativeArea.size)
        fade.bounds.size.width += column.rect.w.sample(t).value-column.rect.w.to
        layer.mask=fade;host.addSublayer(layer)
        if let flights=column.transcriptHandoff.flightRoot {host.addSublayer(flights)}
    }
    private static func savePop(_ renderer:OffscreenRenderer,before:[UInt8],after:[UInt8],label:String) {
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("organic-m118-pop")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        renderer.write(before,folder.appendingPathComponent(label+"-before.png"))
        renderer.write(after,folder.appendingPathComponent(label+"-after.png"))
    }
    /// Physical mouse fixtures: line units, no precise delta and no gesture phase.
    private static func verifyEarlyWheel(check:(Bool,String)->Void) {
        let prior=ColumnTranscriptHandoff.verificationThreshold
        let priorFlight=ColumnTranscriptHandoff.verificationFlightThreshold
        defer {ColumnTranscriptHandoff.verificationThreshold=prior;ColumnTranscriptHandoff.verificationFlightThreshold=priorFlight}
        ColumnTranscriptHandoff.verificationThreshold=8
        ColumnTranscriptHandoff.verificationFlightThreshold=1.5
        for shared in [false,true] {for scale:CGFloat in [1,2] {autoreleasepool {
            let conversations=["A","B","C"].map { id in
                let c=Conversation(id:"early-\(id)",title:"Offline \(id)")
                c.items=(0..<120).map { i in TranscriptItem(id:"\(id)-\(i)",kind:i % 4 == 0 ? .user:.assistant,text:"Paragraph \(i). " + String(repeating:"Keep a stable reader through the moving viewport. ",count:5),running:false) }
                c.items[119].text += String(repeating:"Tail paragraph. ",count:600)
                return c
            }
            let store=ConversationStore(conversations:conversations,projects:MockSeed.projects,devices:MockSeed.devices)
            let scene=AutoScene(size:CGSize(width:1600,height:900),store:store,profile:.init(name:"early-wheel",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:shared ? NativeTranscriptSessions():nil)
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false
            if shared {scene.setTranscriptPresentationActive(true)}
            var clock=VerificationClock.renderOrigin;scene.now={clock};scene.install(members:conversations.map(\.id));scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            let tag="\(Int(scale))x-\(shared ? "shared":"owned")"
            @MainActor func finish() {clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()}
            @MainActor func wheel(_ delta:Int32)->NSEvent {NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:delta,wheel2:0,wheel3:0)!)!}
            check(!wheel(1).hasPreciseScrollingDeltas && wheel(1).phase.isEmpty && wheel(1).momentumPhase.isEmpty,"EARLY fixture is a discrete mouse wheel \(tag)")
            finish()
            for action in ["point","focus-in","focus-out","graft","ungraft"] {
                for column in scene.columns where column.isFull {column.native.scrollToEnd();column.invalidateCaptures()}
                if action=="graft" {scene.enterFocused(scene.current,reason:"early-setup");finish()}
                switch action {
                case "point":scene.switchTo(1,reason:"early-point")
                case "focus-in":scene.enterFocused(scene.current,reason:"early-focus")
                case "focus-out":scene.leaveFocused(reason:"early-unfocus")
                case "graft":scene.graft(conversations.first{$0.id != scene.current}!.id,at:1,reason:"early-graft")
                default:scene.ungraft(conversations.first{$0.id != scene.current}!.id,reason:"early-ungraft")
                }
                let start=clock,end=scene.transitionEnd
                let full=Array(scene.columns.filter(\.isFull).prefix(1))
                var gates:[String:Double]=[:]
                for k in 0...Int(ceil((end-start)*120)) {
                    let t=Double(k)/120
                    if gates["edge8"]==nil,full.allSatisfy({MotionStep.edge($0.rect.sample(t).rect,$0.rect.target)<=8}) {gates["edge8"]=t}
                    if gates["reflow"]==nil,full.allSatisfy({$0.fullReflow.map{$0.progress(at:t)>=1-0.00001} ?? true}) {gates["reflow"]=t}
                    for (name,pt,velocity,relative):(String,CGFloat,Double,Bool) in [("base",8,1,false),("pos8",8,0,false),("pos16",16,0,false),("pos24",24,0,false),("relative24",24,0,true)] {
                        if gates[name]==nil,full.allSatisfy({$0.transcriptReady(at:t,threshold:pt,flightThreshold:1.5,flights:scene.flights[$0.conversation.id] ?? [],velocityWeight:velocity,relativeFlight:relative)}) {gates[name]=t}
                    }
                }
                for k in 0...Int(ceil((end-start)*120)) {
                    let t=Double(k)/120
                    if gates["geometry24"]==nil,full.allSatisfy({$0.transcriptReady(at:t,threshold:24,flightThreshold:1.5,flights:scene.flights[$0.conversation.id] ?? [],velocityWeight:0,relativeFlight:true,includeForm:false)}) {gates["geometry24"]=t}
                }
                check(full.allSatisfy{scene.flights[$0.conversation.id]?.isEmpty ?? true},"EARLY long tail keeps goal and narration flights outside the viewport \(action) \(tag)")
                print("EARLY GEOMETRY",action,tag,full.map{ "\($0.rect.sample(0).rect) -> \($0.rect.target)" }.joined(separator:" "))
                print("EARLY MATRIX",action,tag,gates.sorted{$0.key<$1.key}.map{"\($0.key)=\($0.value)"}.joined(separator:" "))
                // Zero input isolates the exchange's pixels; the next batch checks actual wheel displacement.
                clock=start+0.05
                for column in full {
                    let r=column.rect.sample(clock-start).rect
                    check(scene.transcriptWheel(wheel(0),at:CGPoint(x:r.midX,y:column.nativeArea.midY)),"EARLY moving wheel routes to its full column \(action) \(tag)")
                }
                check(full.allSatisfy{!$0.transcriptHandoff.handedOff},"EARLY large width/form residual still queues input \(action) \(tag)")
                // Host the real native plane alongside the animated scene, without a window.
                let host=scene.sceneView.layer!
                let renderer=OffscreenRenderer(size:CGSize(width:1600,height:900),host:host,scale:scale)
                var exchanged=false,pop=0.0,exchange=0.0
                M10ColumnWorkTrace.reset()
                for k in 7...Int(ceil((end-start)*120)) {
                    clock=start+Double(k)/120
                    let will=full.filter{!$0.transcriptHandoff.handedOff && ($0.transcriptWheelReady(at:clock-start,flights:scene.flights[$0.conversation.id] ?? []) || $0.transcriptReady(at:clock-start,threshold:8,flightThreshold:1.5,flights:scene.flights[$0.conversation.id] ?? []))}
                    let before=will.isEmpty ? nil:renderer.render(at:clock)
                    scene.frame(clock)
                    if let before {
                        for column in will where column.transcriptHandoff.handedOff {installNativePixels(column,at:clock-start,in:host)}
                        let after=renderer.render(at:clock),difference=renderer.tileDiff(before,after).value
                        if difference>SelfTest.popThreshold {savePop(renderer,before:before,after:after,label:action+"-"+tag)}
                        pop=max(pop,difference)
                    }
                    if full.allSatisfy({$0.transcriptHandoff.handedOff}) {exchanged=true;exchange=clock-start;break}
                }
                check(exchanged && exchange<end-start,"EARLY input exchanges before settle \(action) \(tag)")
                check(exchange<=max(gates["edge8"] ?? -1,gates["reflow"] ?? -1)+2.0/120+0.00001,"EARLY native responds by edge8/reflow floor plus two frames \(action) \(tag)")
                check(pop<=SelfTest.popThreshold,"EARLY native exchange pop stays within unchanged 2.0 tile gate \(action) \(tag): \(pop)")
                check(full.allSatisfy{!$0.hasFullReflow && $0.transcriptHandoff.events.isEmpty},"EARLY exchange has one wrap layout and drains the queue \(action) \(tag)")
                for column in full {
                    let offset=column.native.scrollOffset.y
                    let r=column.rect.sample(clock-start).rect,p=CGPoint(x:r.midX,y:column.nativeArea.midY)
                    for _ in 0..<32 {_=scene.transcriptWheel(wheel(1),at:p)}
                    let actual=column.native.scrollOffset.y
                    column.native.scrollOffset.y=offset
                    for _ in 0..<32 {column.native.scrollView.scrollWheel(with:wheel(1))}
                    check(abs(column.native.scrollOffset.y-actual)<0.51 && actual<offset-32,"EARLY 32 of 32 wheel steps match direct native delivery \(action) \(tag)")

                }
                let events=M10ColumnWorkTrace.events.filter{$0.name.hasPrefix("column.handoff")}
                print("EARLY EXCHANGE",action,tag,"frame",Int(round(exchange*120)),"seconds",exchange,"pop",pop,"costs",events.map{"\($0.name)=\(($0.end-$0.start)*1000)"}.joined(separator:" "))
                let offsets=Dictionary(uniqueKeysWithValues:full.map{($0.conversation.id,$0.native.scrollOffset.y)})
                // Interrupt after native ownership, not only while the old snapshot queue is pending.
                if action=="point" {scene.switchTo(2,reason:"early-after-handoff");finish();scene.switchTo(1,reason:"early-return")}
                finish()
                check(full.allSatisfy{abs($0.native.scrollOffset.y-(offsets[$0.conversation.id] ?? -100))<0.51},"EARLY settle/interruption preserves the scrolled reader \(action) \(tag)")
                for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
            }
        }}}
    }

    static func verifyFlightLifecycle(check:(Bool,String)->Void) {
        guard ColumnTranscriptHandoff.keepWheelFlights else {return}
        let prior=ColumnTranscriptHandoff.verificationThreshold
        defer {ColumnTranscriptHandoff.verificationThreshold=prior}
        ColumnTranscriptHandoff.verificationThreshold=8
        for scale:CGFloat in [1,2] {for action in ["point","focus","split","resize","mode","land"] {autoreleasepool {
            let store=ConversationStore()
            let mock=MockReplay(store:store,includeSidebarHistory:true);mock.start(live:false)
            // Completed work after the answer reserves real native rows below the flying narration.
            // Its open, non-running stretch has no brief glyphs; all moving ink stays in the opaque viewport band.
            for c in store.conversations where c.id=="C" {
                c.items.insert(TranscriptItem(id:"offline-prefix",kind:.assistant,text:String(repeating:"Offline scrollable history. ",count:500),running:false),at:0)
                for i in 0..<6 {c.items.append(TranscriptItem(id:"offline-footer-\(i)",turnID:"C-t1",kind:.tool(.command),text:"printf offline-\(i)",status:"completed"))}
            }
            let scene=AutoScene(size:CGSize(width:1600,height:900),store:store,profile:.init(name:"carry-lifecycle",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:NativeTranscriptSessions())
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false;scene.setTranscriptPresentationActive(true)
            var clock=VerificationClock.renderOrigin;scene.now={clock};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()
            let target=scene.columns[2]
            target.layoutNative(fullWidth:scene.fullWidth(2,scene.layout));target.native.scrollToEnd();target.invalidateCaptures()
            scene.switchTo(2,reason:"carry-lifecycle")
            let start=clock,column=scene.columns.first{$0.isFull}!
            let zero=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:0,wheel2:0,wheel3:0)!)!
            clock=start+0.05
            _=scene.transcriptWheel(zero,at:CGPoint(x:column.rect.sample(0.05).rect.midX,y:column.nativeArea.midY))
            for k in 7...50 {
                clock=start+Double(k)/120;scene.frame(clock)
                if column.transcriptHandoff.handedOff {break}
            }
            check(column.hasContinuedTranscriptFlights,"CARRY scrollable flight admitted \(action)")
            print("CARRY FIXTURE",action,"flights",scene.flights[column.conversation.id]?.count ?? 0,"continued",column.hasContinuedTranscriptFlights,"time",clock-start)
            let visibility=column.transcriptHandoff.previousFlightVisibility
            check(clock-start<column.form.duration && !column.native.isHidden,"CARRY native owns input before the original flight clock ends \(action) \(scale)x")
            let offset=column.native.scrollOffset.y
            let wheel=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:1,wheel2:0,wheel3:0)!)!
            for _ in 0..<8 {
                clock += 1.0/120;scene.frame(clock)
                _=scene.transcriptWheel(wheel,at:CGPoint(x:column.rect.sample(clock-start).rect.midX,y:column.nativeArea.midY))
            }
            let actual=column.native.scrollOffset.y
            column.native.scrollOffset.y=offset
            for _ in 0..<8 {column.native.scrollView.scrollWheel(with:wheel)}
            check(abs(actual-column.native.scrollOffset.y)<0.51,"CARRY eight of eight steps equal direct native delivery \(action)")
            check(actual<offset-8,"CARRY eight real line steps move scrollable native \(action)")
            check(abs((column.transcriptHandoff.flightScroll?.position.y ?? 999)-(offset-actual))<0.01,"CARRY scroll transport matches all eight steps \(action)")
            clock += 0.05;scene.frame(clock)
            check(column.hasContinuedTranscriptFlights,"CARRY wheel burst stays inside the original flight clock \(action) \(scale)x")
            if action=="land" {clock=start+column.form.duration+1.0/120}
            let host=scene.sceneView.layer!,renderer=OffscreenRenderer(size:CGSize(width:1600,height:900),host:scene.sceneView.layer!,scale:scale)
            installNativePixels(column,at:clock-start,in:host)
            let before=renderer.render(at:clock)
            for l in host.sublayers ?? [] where l.name=="early.native.pixels" {l.removeFromSuperlayer()}
            switch action {
            case "point":scene.switchTo(1,reason:"carry-reverse")
            case "focus":scene.enterFocused(scene.current,reason:"carry-focus")
            case "split":scene.transition(to:scene.members,current:scene.current,scheme:AutoScene.Scheme(mode:.focused,split:[scene.current,"B"],left:[],right:[]),spring:AutoScene.focusSpring,reason:"carry-split")
            case "land":scene.frame(clock);installNativePixels(column,at:clock-start,in:host)
            case "resize":scene.resize(to:CGSize(width:1500,height:850),live:false)
            default:scene.suspendModePresentation()
            }
            check(!column.hasContinuedTranscriptFlights && column.transcriptHandoff.scrollObservation==nil && column.transcriptHandoff.previousFlightVisibility==nil,"CARRY interruption removes continuation and hidden visibility \(action)")
            check(column.native.flightVisibility()==visibility,"CARRY cleanup restores the native glyph lease \(action) \(scale)x")
            if action=="point" || action=="focus" || action=="split" || action=="land" {
                let after=renderer.render(at:clock),pop=renderer.tileDiff(before,after).value
                if pop>SelfTest.popThreshold {savePop(renderer,before:before,after:after,label:"lifecycle-"+action)}
                check(pop<=SelfTest.popThreshold,"CARRY interruption pop stays within unchanged 2.0 gate \(action): \(pop)")
                print("CARRY INTERRUPT",action,scale,"pop",pop,"at",renderer.tileDiff(before,after).at,"offset",actual,"delta",offset-actual)
                clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()
                check(column.transcriptHandoff.events.isEmpty,"CARRY interruption leaves no pending wheel \(action)")
            }
        }}}
    }

    private static func verifyEarlyFlight(check:(Bool,String)->Void) {
        let prior=ColumnTranscriptHandoff.verificationThreshold
        let priorFlight=ColumnTranscriptHandoff.verificationFlightThreshold
        defer {ColumnTranscriptHandoff.verificationThreshold=prior;ColumnTranscriptHandoff.verificationFlightThreshold=priorFlight}
        ColumnTranscriptHandoff.verificationThreshold=8;ColumnTranscriptHandoff.verificationFlightThreshold=1.5
        for shared in [false,true] {for scale:CGFloat in [1,2] {autoreleasepool {
            let store=ConversationStore()
            // Only MockSeed content is used; no backend is attached.
            let replay=MockReplay(store:store,includeSidebarHistory:true);replay.start(live:false)
            let scene=AutoScene(size:CGSize(width:1600,height:900),store:store,profile:.init(name:"early-flight",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:shared ? NativeTranscriptSessions():nil)
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false
            if shared {scene.setTranscriptPresentationActive(true)}
            var clock=VerificationClock.renderOrigin;scene.now={clock};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            clock=max(clock,scene.transitionEnd+0.1);scene.frame(clock);scene.settle();scene.clock.invalidate()
            scene.switchTo(2,reason:"early-flight")
            let start=clock,end=scene.transitionEnd,column=scene.columns.first{$0.isFull}!,nodes=scene.flights[scene.current] ?? []
            let tag="\(Int(scale))x-\(shared ? "shared":"owned")"
            check(!nodes.isEmpty && nodes.contains{$0.line.look == .goal},"EARLY mock has visible goal flights \(tag)")
            var times:[String:Double]=[:]
            for k in 0...Int(ceil((end-start)*120)) {
                let t=Double(k)/120
                if times["edge8"]==nil,MotionStep.edge(column.rect.sample(t).rect,column.rect.target)<=8 {times["edge8"]=t}
                for (name,pt,velocity,relative):(String,CGFloat,Double,Bool) in [("base",8,1,false),("pos8",8,0,false),("pos16",16,0,false),("pos24",24,0,false),("relative24",24,0,true)] {
                    if times[name]==nil,column.transcriptReady(at:t,threshold:pt,flightThreshold:1.5,flights:nodes,velocityWeight:velocity,relativeFlight:relative) {times[name]=t}
                }
            }
            print("EARLY FLIGHT MATRIX",tag,"flights",nodes.count,times.sorted{$0.key<$1.key}.map{"\($0.key)=\($0.value)"}.joined(separator:" "))
            clock=start+0.05
            let event=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:0,wheel2:0,wheel3:0)!)!
            _=scene.transcriptWheel(event,at:CGPoint(x:column.rect.sample(0.05).rect.midX,y:column.nativeArea.midY))
            let host=scene.sceneView.layer!
            let renderer=OffscreenRenderer(size:CGSize(width:1600,height:900),host:host,scale:scale)
            M10ColumnWorkTrace.reset()
            var pop=0.0,exchange:Double?
            for k in 7...Int(ceil((end-start)*120)) {
                clock=start+Double(k)/120
                let ready=column.transcriptWheelReady(at:clock-start,flights:nodes) || column.transcriptReady(at:clock-start,threshold:8,flightThreshold:1.5,flights:nodes)
                let before=ready ? renderer.render(at:clock):nil
                scene.frame(clock)
                if column.transcriptHandoff.handedOff {
                    if let before {
                        installNativePixels(column,at:clock-start,in:host)
                        let after=renderer.render(at:clock);pop=renderer.tileDiff(before,after).value
                        if pop>SelfTest.popThreshold {savePop(renderer,before:before,after:after,label:"flight-"+tag)}
                    }
                    exchange=clock-start;break
                }
            }
            check(exchange != nil,"EARLY visible goal flight exchanges before settle \(tag)")
            check((exchange ?? 9)<=(times["edge8"] ?? -1)+2.0/120+0.00001,"EARLY flight responds by edge8 plus two frames \(tag)")
            check(pop<=SelfTest.popThreshold,"EARLY flight exchange pop stays within unchanged 2.0 tile gate \(tag): \(pop)")
            check((scene.flights[scene.current]==nil || column.hasContinuedTranscriptFlights) && !column.native.isHidden,"EARLY native owns visible goal exactly once \(tag)")
            column.native.scrollToEnd()
            let offset=column.native.scrollOffset.y
            let wheel=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:1,wheel2:0,wheel3:0)!)!
            for _ in 0..<8 {_=scene.transcriptWheel(wheel,at:CGPoint(x:column.rect.sample(clock-start).rect.midX,y:column.nativeArea.midY))}
            let actual=column.native.scrollOffset.y;column.native.scrollOffset.y=offset
            for _ in 0..<8 {column.native.scrollView.scrollWheel(with:wheel)}
            check(abs(actual-column.native.scrollOffset.y)<0.51,"EARLY visible goal delivers eight of eight wheel steps \(tag)")
            let shifted=column.native.scrollOffset.y
            if column.hasContinuedTranscriptFlights {
                check(column.transcriptHandoff.flightScroll?.position.y == column.transcriptHandoff.flightScrollStart-shifted,"CARRY flight follows every native wheel bounds change \(tag)")
                let landing=start+column.form.duration+1.0/120
                clock=landing
                for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
                installNativePixels(column,at:clock-start,in:host)
                let before=renderer.render(at:clock)
                scene.frame(clock)
                for layer in host.sublayers ?? [] where layer.name=="early.native.pixels" {layer.removeFromSuperlayer()}
                installNativePixels(column,at:clock-start,in:host)
                let after=renderer.render(at:clock),landingPop=renderer.tileDiff(before,after).value
                check(landingPop<=SelfTest.popThreshold,"CARRY landing pop stays within unchanged 2.0 gate \(tag): \(landingPop)")
                check(!column.hasContinuedTranscriptFlights && column.transcriptHandoff.flightRoot==nil && column.transcriptHandoff.scrollObservation==nil,"CARRY landing removes flight owner and observer \(tag)")
                check(abs(column.native.scrollOffset.y-shifted)<0.51,"CARRY landing keeps the reader \(tag)")
                print("CARRY LANDING",tag,"t",clock-start,"pop",landingPop)
            }
            print("EARLY FLIGHT EXCHANGE",tag,"seconds",exchange ?? -1,"pop",pop)
            print("EARLY FLIGHT COSTS",tag,M10ColumnWorkTrace.events.filter{$0.name.hasPrefix("column.handoff")}.map{"\($0.name)=\(($0.end-$0.start)*1000)"}.joined(separator:" "))
            clock=end+0.1;scene.frame(clock);scene.settle();scene.clock.invalidate()
        }}}
    }

}
