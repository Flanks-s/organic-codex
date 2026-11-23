import AppKit
import QuartzCore

/// Real scene callbacks without a window, Core connection, or application entry point.
@MainActor enum M10ColumnWorkVerification {
    static func run(to path:String,size:CGSize)->Int32 {
        let out=URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        HeaderIsland.forceMotionTexturesForVerification=true
        defer {HeaderIsland.forceMotionTexturesForVerification=false}
        var checks=0,failures:[String]=[],reports:[[String:Any]]=[]
        @MainActor func check(_ value:Bool,_ message:String) {
            checks += 1
            if message.hasPrefix("split-cold") { print("SPLIT COLD", value ? "PASS" : "FAIL", message) }
            if !value {
                failures.append(message)
                print("FINDING", message)
            }
        }
        @MainActor func counts()->[String:Int] {Dictionary(M10ColumnWorkTrace.events.map{($0.name,1)},uniquingKeysWith:+)}
        @MainActor func drain() {
            let until=Date().addingTimeInterval(0.15)
            while Date()<until && (counts()["column.nativeUpdate"] ?? 0)==0 {
                _=RunLoop.main.run(mode:.default,before:min(until,Date().addingTimeInterval(0.005)))
            }
        }
        PeekHaloVerification.run(to: out.appendingPathComponent("peek-halo"), check: check)
        if ProcessInfo.processInfo.environment["SELFTEST_PEEK_HALO_ONLY"] == "1" {
            return failures.isEmpty ? 0:1
        }
        IslandEventPhaseVerification.run(to:out.appendingPathComponent("island-event-phase"),check:check)
        PeekTopClipVerification.run(to:out.appendingPathComponent("peek-top-clip"),check:check)
        IslandLongTitleVerification.run(to:out.appendingPathComponent("island-long-title"),check:check)
        let islandLayers=IslandLayerVerification.run(to:out.appendingPathComponent("island-layers"))
        checks+=islandLayers.checks;failures+=islandLayers.findings
        if ProcessInfo.processInfo.environment["SELFTEST_ISLAND_LAYER_ONLY"] == "1" {
            return failures.isEmpty ? 0:1
        }
        NativeTranscriptFollowVerification.run(check:check)
        TranscriptFreezeVerification.run(size:size,check:check)
        TranscriptHandoffVerification.run(check:check)
        let prewarm=M11PrewarmVerification.run(to:out.appendingPathComponent("prewarm"));checks+=prewarm.checks;failures+=prewarm.findings
        for shared in [false,true] {for scale:CGFloat in [1,2] {for enabled in [false,true] {autoreleasepool {
            let store=ConversationStore()
            let mock=MockReplay(store:store,includeSidebarHistory:true);mock.start(live:false)
            let scene=AutoScene(size:size,store:store,profile:.init(name:"Built-in fixture",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:scale,transcriptSessions:shared ? NativeTranscriptSessions():nil)
            if shared {scene.setTranscriptPresentationActive(true)}
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false;scene.columnExposureEnabled=enabled
            var time=CACurrentMediaTime()+3600;scene.now={time};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            var disposed = false
            defer { if !disposed { scene.disposeTranscriptPresentation() } }
            @MainActor func settle() {time=max(time,scene.transitionEnd+0.1);scene.clock.onFrame?(time);scene.settle();CATransaction.flush()}
            settle()
            scene.onCreate={text,_ in Conversation(id:"work-first-send",title:text)}
            scene.onSubmit={c,r,done in let accepted=mock.send(c,text:r.text);done(accepted ? .accepted:.failed("fixture rejected"));return accepted}
            store.onAdd={ [weak scene] c in scene?.admit(c,reason:"arrival") }
            scene.newChat();settle();let composer=scene.composers.draft().composer
            composer.setText("Draft a plan for the onboarding tour")
            scene.prewarm()
            let tag="\(Int(scale))x-\(enabled ? "on":"off")"+(shared ? "-shared":"")
            M10ColumnWorkTrace.reset();let cancelRoot=M10ColumnWorkTrace.scope("probe.cancel")
            scene.cancelNewChat();cancelRoot.end()
            let cancelMs=(M10ColumnWorkTrace.events.first!.end-M10ColumnWorkTrace.events.first!.start)*1000
            check(scene.lastSwitch?["prewarmed"] as? Bool == true,"cancel consumes its idle plan \(tag)")
            check((counts()["scene.prepare"] ?? 0)==0 && (counts()["column.viewport"] ?? 0)==0 && (counts()["draft.capture"] ?? 0)==0,"cancel input does not prepare/capture \(tag)")
            check(scene.isMoving,"cancel commits the spring before returning \(tag)")
            reports.append(["case":"cancel","tag":tag,"synchronousMs":cancelMs,"counts":counts(),"switch":scene.lastSwitch ?? [:]])
            try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("cancel-\(tag).json"))
            settle();scene.prewarm()
            M10ColumnWorkTrace.reset();let openRoot=M10ColumnWorkTrace.scope("probe.open")
            scene.newChat();openRoot.end()
            let openMs=(M10ColumnWorkTrace.events.first!.end-M10ColumnWorkTrace.events.first!.start)*1000
            check(scene.lastSwitch?["prewarmed"] as? Bool == true,"second open consumes its idle plan \(tag)")
            check((counts()["scene.prepare"] ?? 0)==0,"second open does not prepare in input \(tag)")
            reports.append(["case":"open","tag":tag,"synchronousMs":openMs,"counts":counts(),"switch":scene.lastSwitch ?? [:]])
            try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("open-\(tag).json"))
            settle();scene.prewarm()
            M10ColumnWorkTrace.reset();let root=M10ColumnWorkTrace.scope("probe.submit")
            let accepted=composer.submit();root.end()
            let synchronous=counts();let submitMs=(M10ColumnWorkTrace.events.first!.end-M10ColumnWorkTrace.events.first!.start)*1000
            check(composer.hasPendingSubmission,"first-send request remains pending across the bounded publication turn \(tag)")
            check(!composer.submit(),"first-send pending gate rejects duplicate input before publication \(tag)")
            check(scene.columns.contains{$0.conversation.id==scene.current && $0.isPromoting},"header promotion starts before submit returns \(tag)")
            check(scene.dock.items[scene.current]?.ownComposer === composer,"stationary first send keeps native editor mounted \(tag)")
            check(scene.dock.items[scene.current]?.full == true && composer.alphaValue == 1,"stationary first send keeps the editor visible \(tag)")
            drain();let coalesced=counts()
            check(accepted,"first send accepted \(tag)")
            check(scene.composers.existingComposer(for:scene.current) === composer,"first send keeps editor instance \(tag)")
            check(store.conversation(scene.current)?.items.count == 1,"three mock publications retain one user message \(tag)")
            check((synchronous["column.viewport"] ?? 0)==0,"no synchronous first-send viewport captures \(tag): \(synchronous)")
            check((coalesced["column.viewport"] ?? 0)==0,"no deferred unused first-send viewport captures \(tag): \(coalesced)")
            check((coalesced["column.nativeUpdate"] ?? 0)==1,"three moving publications coalesce into one native update \(tag)")
            check(scene.columns.first(where:{$0.conversation.id==scene.current})?.native.renderedRevision == store.conversation(scene.current)?.revision,"native shows latest revision before next motion \(tag)")
            try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("first-send-\(tag).json"))
            let publishMs=M10ColumnWorkTrace.events.filter{$0.name=="scene.firstSend.publish"}.map{($0.end-$0.start)*1000}.max() ?? 0
            reports.append(["case":"first-send","shared":shared,"scale":scale,"enabled":enabled,"submitMs":submitMs,
                "publishMs":publishMs,"longestSynchronousMs":max(submitMs,publishMs),"synchronous":synchronous,"afterRunLoop":coalesced])
            // At the column spring's end (~0.8s), the seed/name promotion is still moving until 1.2s.
            settle();M10ColumnWorkTrace.reset();scene.prewarm()
            check(scene.columns.contains{$0.isPromoting},"first-send fixture reaches spring settle before header promotion ends \(tag)")
            check((counts()["scene.prepare"] ?? 0)==0,"automatic/explicit prewarm cannot capture during header promotion \(tag)")
            try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("promotion-prewarm-\(tag).json"))
            // Invalidate any target plan even on the old path that incorrectly prewarmed during promotion.
            store.conversation(scene.current)?.revision += 1
            // A subsequent uncached switch must still synchronously supply every flight source before commit.
            M10ColumnWorkTrace.reset();scene.switchTo(scene.columns.firstIndex(where:{$0.conversation.id != scene.current}) ?? -1,reason:"work-cold-switch")
            let cold=counts();let preparation=scene.lastSwitch ?? [:]
            check((cold["scene.prepare"] ?? 0)==1,"uncached switch prepares before commit \(tag)")
            check((cold["column.viewport"] ?? 0)>0,"nonempty cold switch captures source before commit \(tag)")
            check((preparation["flights"] as? Int ?? 0)>0,"cold switch has real text flights, not only a transparent placeholder \(tag)")
            if shared {
                let pieces=Dictionary(uniqueKeysWithValues:scene.columns.filter{!$0.pieces.isEmpty}.map{($0.conversation.id,$0.pieces.count)})
                scene.setTranscriptPresentationActive(true)
                check(!pieces.isEmpty && pieces.allSatisfy{key,count in scene.columns.first{$0.conversation.id==key}?.pieces.count==count},"active shared transcript admission retains flight pieces \(tag)")
            }
            var frameCaptures=0
            for _ in 0...100 {time+=1/120;let n=counts()["column.viewport"] ?? 0;scene.clock.onFrame?(time);frameCaptures+=(counts()["column.viewport"] ?? 0)-n}
            check(frameCaptures==0,"Auto display-link frames never capture viewport \(tag)")
            try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("cold-auto-\(tag).json"))
            reports.append(["case":"cold-auto","shared":shared,"scale":scale,"enabled":enabled,"counts":cold,"prepare":preparation,"frameCaptures":frameCaptures])
            settle()
            scene.enterFocused(scene.current, reason: "split-cold-setup")
            settle()
            guard let left = scene.columns.first,
                  let incoming = scene.order.first(where: { $0 != scene.current }) else {
                check(false, "split-cold fixture has focused column and bank \(tag)")
                return
            }
            let conversation = left.conversation
            for n in 0..<30 {
                conversation.items.append(.init(id: "split-cold-\(n)", kind: .assistant,
                                                text: String(repeating: "Synthetic text ", count: 30), running: false))
            }
            conversation.revision += 1
            store.changed(conversation)
            left.renderDisplay(fullWidth: scene.fullWidth(0, scene.layout),
                               briefWidth: scene.briefWidth(0, scene.layout), force: true)
            left.native.scrollToEnd()
            let clip = left.native.scrollView.contentView
            clip.scroll(to: CGPoint(x: 0, y: max(0, clip.bounds.minY - 100)))
            left.native.scrollView.reflectScrolledClipView(clip)
            let offset = left.native.scrollOffset.y, oldWidth = left.native.frame.width
            let id = conversation.id
            @MainActor func waitForTarget(_ targetID: String? = nil) -> Bool {
                let waitingID = targetID ?? id
                let deadline = Date().addingTimeInterval(2)
                while scene.deferredTargets[waitingID] != nil && Date() < deadline {
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
                }
                return scene.deferredTargets[waitingID] == nil
            }
            M10ColumnWorkTrace.reset()
            let splitRoot = M10ColumnWorkTrace.scope("probe.split-cold")
            let opened = scene.openInSplit(incoming, reason: "split-cold")
            splitRoot.end()
            let events = M10ColumnWorkTrace.events
            let targetWidth = scene.fullWidth(0, scene.layout)
            let captures = events.filter { $0.name == "column.snapshot" && $0.fields["id"] as? String == id }
            let targetHits = captures.filter { abs(($0.fields["width"] as? CGFloat ?? -1) - targetWidth) < 0.5/scale }
            guard let right = scene.columns.first(where: { $0.conversation.id == incoming }),
                  let rightSlot = scene.columns.firstIndex(where: { $0 === right }) else {
                check(false, "split-cold incoming column exists \(tag)")
                return
            }
            let rightWidth = scene.fullWidth(rightSlot, scene.layout)
            let incomingCaptures = events.filter {
                $0.name == "column.snapshot" && $0.fields["id"] as? String == incoming
            }
            check(incomingCaptures.isEmpty, "split-cold incoming has no callback snapshot \(tag)")
            check(scene.deferredTargets[incoming] != nil, "split-cold incoming target deferred \(tag)")
            check(opened && scene.isMoving, "split-cold opens and moves \(tag)")
            check(targetHits.isEmpty, "split-cold no target-width snapshot in callback \(tag)")
            check(abs(left.native.frame.width - oldWidth) < 0.5/scale, "split-cold native width unchanged \(tag)")
            check(scene.deferredTargets[id] != nil, "split-cold target deferred \(tag)")
            let departure = captures.filter { abs(($0.fields["width"] as? CGFloat ?? -1) - oldWidth) < 0.5/scale }
            let incomingMs = incomingCaptures.reduce(0.0) { $0 + ($1.end-$1.start)*1000 }
            let makeMs = events.filter { $0.name == "scene.makeColumn" }
                .reduce(0.0) { $0 + ($1.end-$1.start)*1000 }
            let admitMs = events.filter { $0.name == "scene.admitUnmountedTranscripts" }
                .reduce(0.0) { $0 + ($1.end-$1.start)*1000 }
            conversation.items.append(.init(id: "split-cold-update", kind: .assistant,
                                            text: "New content", running: false))
            conversation.revision += 1
            store.changed(conversation)
            right.conversation.items.append(.init(id: "split-cold-right-update", kind: .assistant,
                                                  text: "New incoming content", running: false))
            right.conversation.revision += 1
            store.changed(right.conversation)
            _ = scene.prepare(members: scene.members, current: scene.current, scheme: scene.scheme, at: scene.now())
            check(scene.deferredTargets[id] != nil, "split-cold uncommitted prepare retains target \(tag)")
            if enabled { time = scene.transitionEnd + 0.1 }
            if enabled { scene.settle() }
            check(waitForTarget(), "split-cold target delivered within two seconds \(tag)")
            check(waitForTarget(incoming), "split-cold incoming target delivered within two seconds \(tag)")
            let delivery = M10ColumnWorkTrace.events.last {
                $0.name == "scene.deferred.deliver" && $0.fields["id"] as? String == id
            }
            let incomingDelivery = M10ColumnWorkTrace.events.last {
                $0.name == "scene.deferred.deliver" && $0.fields["id"] as? String == incoming
            }
            check(delivery != nil && incomingDelivery != nil && delivery!.start < incomingDelivery!.start,
                  "split-cold visible column delivers before incoming column \(tag)")
            settle()
            check(scene.deferredTargets.isEmpty, "split-cold all deferred targets retired \(tag)")
            check(!left.native.isHidden && abs(left.native.frame.width-targetWidth) <= 0.5/scale,
                  "split-cold native released at target width \(tag)")
            check(abs(left.native.scrollOffset.y-offset) <= 0.51, "split-cold preserves reading offset \(tag)")
            check(left.native.renderedRevision == conversation.revision, "split-cold renders newest revision \(tag)")
            check(!right.native.isHidden && abs(right.native.frame.width-rightWidth) <= 0.5/scale,
                  "split-cold incoming native released at target width \(tag)")
            check(right.native.renderedRevision == right.conversation.revision,
                  "split-cold incoming renders newest revision \(tag)")
            let splitMs = (events.first!.end-events.first!.start)*1000
            let departureMs = departure.reduce(0.0) { $0 + ($1.end-$1.start)*1000 }
            let deliveryMs = delivery.map { ($0.start-events.first!.start)*1000 } ?? -1
            let incomingDeliveryMs = incomingDelivery.map { ($0.start-events.first!.start)*1000 } ?? -1
            reports.append(["case":"split-cold", "tag":tag, "openMs":splitMs, "incomingMs":incomingMs,
                            "departureCount":departure.count, "departureMs":departureMs,
                            "deliveryMs":deliveryMs, "incomingDeliveryMs":incomingDeliveryMs,
                            "makeColumnMs":makeMs, "admitMs":admitMs, "settledBeforeDelivery":enabled])
            scene.ungraft(incoming, reason: "split-cold-follow")
            settle()
            left.native.scrollToEnd()
            check(scene.openInSplit(incoming, reason: "split-cold-follow"), "split-cold follow opens \(tag)")
            check(waitForTarget(), "split-cold follow delivers \(tag)")
            settle()
            check(left.native.shouldFollowEnd && left.native.isAtEnd, "split-cold preserves follow end \(tag)")
            scene.ungraft(incoming, reason: "split-cold-wheel")
            settle()
            left.native.scrollToEnd()
            clip.scroll(to: CGPoint(x: 0, y: max(0, clip.bounds.minY - 100)))
            left.native.scrollView.reflectScrolledClipView(clip)
            _ = scene.openInSplit(incoming, reason: "split-cold-wheel")
            let pendingWheel = scene.deferredTargets[id] != nil
            let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                                wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
            let wheelPoint = CGPoint(x: left.rect.sample(0).rect.midX, y: left.nativeArea.midY)
            var routed = true
            for _ in 0..<3 { routed = scene.transcriptWheel(wheel, at: wheelPoint) && routed }
            let queued = left.transcriptHandoff.events.count == 3
            let deliveredWheel = waitForTarget()
            let targetOffset = left.native.scrollOffset.y
            settle()
            let actualWheel = left.native.scrollOffset.y
            let queueCleared = left.transcriptHandoff.events.isEmpty
            left.native.scrollOffset.y = targetOffset
            for _ in 0..<3 { left.native.scrollView.scrollWheel(with: wheel) }
            let directWheel = left.native.scrollOffset.y
            let wheelDetail = "pending=\(pendingWheel) routed=\(routed) queued=\(queued) delivered=\(deliveredWheel)"
            let wheelOffsets = "clear=\(queueCleared) start=\(targetOffset) actual=\(actualWheel) direct=\(directWheel)"
            check(pendingWheel && routed && queued && deliveredWheel && queueCleared &&
                  directWheel < targetOffset - 0.51 && abs(actualWheel-directWheel) < 0.51,
                  "split-cold pending wheel replays three \(tag) \(wheelDetail) \(wheelOffsets)")
            scene.ungraft(incoming, reason: "split-cold-interrupt")
            settle()
            _ = scene.openInSplit(incoming, reason: "split-cold-interrupt")
            scene.ungraft(incoming, reason: "split-cold-interrupt")
            settle()
            check(waitForTarget() && !left.hasFullReflow, "split-cold interrupted target retired \(tag)")
            check(abs(left.native.frame.width-scene.fullWidth(0, scene.layout)) <= 0.5/scale,
                  "split-cold interrupted width correct \(tag)")
            M10ColumnWorkTrace.reset()
            _ = scene.openInSplit(incoming, reason: "split-cold-fallback")
            let bothPending = scene.deferredTargets[id] != nil && scene.deferredTargets[incoming] != nil
            // Make only the old-width native visible after admission, so its idle reflow rejects the source.
            left.native.isHidden = false
            let leftRetired = waitForTarget()
            let rightRetired = waitForTarget(incoming)
            let deliveredIDs = M10ColumnWorkTrace.events.filter { $0.name == "scene.deferred.deliver" }
                .compactMap { $0.fields["id"] as? String }
            settle()
            check(bothPending && leftRetired && rightRetired && !deliveredIDs.contains(id)
                  && deliveredIDs.contains(incoming) && scene.deferredTargets.isEmpty,
                  "split-cold one source fallback continues incoming delivery \(tag)")
            scene.ungraft(incoming, reason: "split-cold-fallback")
            settle()
            conversation.items.append(.init(id: "split-cold-large", kind: .assistant,
                                            text: String(repeating: "x", count: 70_000), running: false))
            conversation.revision += 1
            left.renderDisplay(fullWidth: scene.fullWidth(0, scene.layout),
                               briefWidth: scene.briefWidth(0, scene.layout), force: true)
            left.native.scrollToEnd()
            M10ColumnWorkTrace.reset()
            _ = scene.openInSplit(incoming, reason: "split-cold-large")
            check(scene.deferredTargets[id] == nil && (counts()["column.snapshot"] ?? 0) > 0,
                  "split-cold unsupported row remains synchronous \(tag)")
            settle()
            scene.ungraft(incoming, reason: "split-cold-dispose")
            settle()
            conversation.items.removeLast()
            conversation.revision += 1
            left.renderDisplay(fullWidth: scene.fullWidth(0, scene.layout),
                               briefWidth: scene.briefWidth(0, scene.layout), force: true)
            _ = scene.openInSplit(incoming, reason: "split-cold-dispose")
            check(scene.deferredTargets[id] != nil, "split-cold dispose starts pending task \(tag)")
            disposed = true
            scene.disposeTranscriptPresentation()
            check(scene.deferredTargets.isEmpty, "split-cold dispose cancels tasks \(tag)")
        }}}}
        for autoScale:CGFloat in [1,2] {for enabled in [false,true] {autoreleasepool {
            let store=ConversationStore()
            let replay=MockReplay(store:store);replay.start(live:false)
            let scene=AutoScene(size:size,store:store,profile:.init(name:"Built-in fixture",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0),scale:autoScale)
            scene.verificationPresented=true;scene.manualSettle=true;scene.ambient=false;scene.columnExposureEnabled=enabled
            var time=VerificationClock.renderOrigin;scene.now={time};scene.install(members:MockSeed.windowMembers);scene.clock.invalidate()
            defer {scene.disposeTranscriptPresentation()}
            M10ColumnWorkTrace.reset();scene.showCaptures(true)
            check((counts()["column.viewport"] ?? 0)>0,"explicit capture comparison prepares bitmaps \(enabled)")
            check(scene.columns.allSatisfy{ $0.restOnSnapshot },"explicit capture comparison switches actual displayed materials \(enabled)")
            scene.showCaptures(false);M10ColumnWorkTrace.active=false
            for target in [1,2] {
                scene.prewarm();M10ColumnWorkTrace.reset()
                let before=scene.columns.compactMap(\.island).reduce(0){$0+$1.motionGlyphMaterial.captureCount}
                scene.switchTo(target,reason:"work-warm-auto")
                let captures=scene.columns.compactMap(\.island).reduce(0){$0+$1.motionGlyphMaterial.captureCount}-before
                check((counts()["column.viewport"] ?? 0)==0,"warm Auto hit captures no viewport \(enabled) target \(target)")
                if enabled {check(captures==0,"warm Auto hit captures no glyph after CA flush target \(target): \(captures)")}
                reports.append(["case":"warm-auto","scale":autoScale,"enabled":enabled,"target":target,"glyphCapturesAfterFlush":captures,"counts":counts(),"switch":scene.lastSwitch ?? [:]])
                try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("warm-auto-\(Int(autoScale))x-\(enabled)-\(target).json"))
                let sourceCaptures=scene.columns.compactMap(\.island).reduce(0){$0+$1.motionGlyphMaterial.captureCount}
                for k in 1...100 {scene.clock.onFrame?(time+Double(k)/120)}
                let movingCaptures=scene.columns.compactMap(\.island).reduce(0){$0+$1.motionGlyphMaterial.captureCount}-sourceCaptures
                if enabled {check(movingCaptures==0,"warm Auto motion frames have no glyph captures \(autoScale)x target \(target): \(movingCaptures)")}
                time=scene.transitionEnd+0.1;scene.clock.onFrame?(time);scene.settle()
            }
        }}}
        for scale:CGFloat in [1,2] {
            let plane=IslandGlyphPlane();plane.forceTextureExposure=true;plane.warmingEnabled=true;plane.textureScale=scale
            let label=IslandLabel(labelWithString:"Build the onboarding tour")
            label.isBordered=false;label.isBezeled=false;label.drawsBackground=false;label.wantsLayer=true
            label.font = .systemFont(ofSize:12,weight:.semibold);label.textColor = .labelColor;label.lineBreakMode = .byTruncatingTail
            label.frame=CGRect(x:0,y:0,width:90,height:15)
            let old=label.bounds,font=label.font!,target=NSFont.systemFont(ofSize:13,weight:.semibold)
            let bounds=CGRect(x:0,y:0,width:(171.3*scale).rounded()/scale,height:ceil(target.ascender-target.descender))
            let warmed=plane.warmDrawing(of:label,font:target,bounds:bounds)!
            check(label.bounds==old && label.font==font,"target drawing warmup never mutates live label \(scale)x")
            label.font=target;label.frame=CGRect(origin:.zero,size:bounds.size);label.bounds=bounds
            let actual=NativeViewBitmap.capture(label,scale:scale)
            check(warmed.width==actual.width && warmed.height==actual.height,"target texture retains backing scale \(scale)x")
            check(warmed.dataProvider!.data! as Data == actual.dataProvider!.data! as Data,"target texture equals authored label draw byte-for-byte \(scale)x")
        }
        autoreleasepool {
            let c=Conversation(id:"work-empty",title:"Empty"),store=ConversationStore()
            let node=ColumnNode(c,store:store,identity:.systemGreen,rect:CGRect(x:0,y:0,width:557,height:820),full:true,scale:2,logicalBottom:720)
            M10ColumnWorkTrace.reset();let s=node.snapshot(fullWidth:557,briefWidth:220)
            check((counts()["column.viewport"] ?? 0)==0,"empty snapshot allocates no viewport bitmap")
            check(s.pieces.isEmpty,"empty snapshot has no flights")
            check(s.withGoal === s.transcript,"empty endpoints share one transparent image")
            try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("empty.json"))
            c.items=[.init(id:"reason",kind:.reasoning,text:"A completed thought.",running:false)];c.revision+=1
            M10ColumnWorkTrace.reset();let one=node.snapshot(fullWidth:557,briefWidth:220)
            check((counts()["column.viewport"] ?? 0)==1,"no hidden source requires exactly one capture")
            check(one.withGoal === one.transcript,"unmodified base shares original viewport")
            let n=counts()["column.viewport"];_ = node.snapshot(fullWidth:557,briefWidth:220)
            check(counts()["column.viewport"]==n,"resolved native geometry gives an immediate snapshot cache hit")
            try? M10ColumnWorkTrace.write(to:out.appendingPathComponent("shared.json"))
            let bridge=HeaderIslandInspectorBridge(conversation:c,store:store,actions:NormieActions())
            check(!bridge.inspector.isViewLoaded,"closed island inspector does not load view on construction")
            bridge.update(c);check(!bridge.inspector.isViewLoaded,"closed island inspector update stays lazy")
            check(bridge.content(for:.context)==nil,"context uses island context panel")
            check(!bridge.inspector.isViewLoaded,"unrelated panel does not load inspector")
            check(bridge.content(for:.changes) === bridge.inspector,"Changes loads the real inspector on request")
            check(bridge.inspector.isViewLoaded,"requested panel has loaded content")
        }
        for scale:CGFloat in [1,2] {
            let draft=DraftColumn(placeholder:Conversation(id:"audit-draft",title:"New Chat"),store:ConversationStore(),scale:scale)
            draft.lay(CGRect(x:360,y:52,width:717,height:650))
            draft.enter(windowWidth:1080,now:0);draft.frame(at:0.12)
            if let root=draft.layer {
                let audit=ReplicaContainerAudit.inspect(root,scenario:"newchat-draft",frame:14,time:CACurrentMediaTime(),includeDormant:true)
                check(audit.isEmpty,"draft replica material audit \(scale)x: \(audit.map(\.reason))")
            }
        }
        let newChat=M11NewChatVerification.run(to:out.appendingPathComponent("newchat-regression"))
        checks+=newChat.checks;failures+=newChat.findings
        check(NSApp.windows.allSatisfy{!$0.isVisible},"fixture orders no windows; no NSWindow constructed by test")
        let report:[String:Any] = ["checks":checks,"findings":failures,"reports":reports,"boundary":"headless debug CPU; not WindowServer/GPU presented-frame timing"]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
        print("COLUMN WORK",checks,"checks",failures.count,"findings");return failures.isEmpty ? 0:1
    }
}
