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
        m52Dock(check: check)
        if ProcessInfo.processInfo.environment["SELFTEST_M52_DOCK_ONLY"] == "1" {
            print("M52 DOCK", checks, "checks", failures.count, "findings")
            return failures.isEmpty ? 0 : 1
        }
        verifySplitRefusal(check: check)
        verifyRefuseThenTrash(check: check)
        verifyLLRefusal(check: check)
        if ProcessInfo.processInfo.environment["SELFTEST_M53_ONLY"] == "1" {
            print("M53", checks, "checks", failures.count, "findings")
            return failures.isEmpty ? 0 : 1
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
            let readingBefore = left.native.verificationReadingAnchor
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
            let readingAfter = left.native.verificationReadingAnchor
            print("M52 READING", tag, "before", offset, readingBefore?.key ?? "nil",
                  readingBefore?.distance ?? .nan, "after", left.native.scrollOffset.y,
                  readingAfter?.key ?? "nil", readingAfter?.distance ?? .nan, "widths", oldWidth, targetWidth)
            if shared {
                check(readingBefore != nil && readingAfter?.key == readingBefore?.key
                      && abs((readingAfter?.distance ?? .infinity) - (readingBefore?.distance ?? 0)) <= 0.51,
                      "split-cold preserves reading anchor \(tag)")
            } else {
                check(abs(left.native.scrollOffset.y-offset) <= 0.51, "split-cold preserves reading offset \(tag)")
            }
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

    static func m52Dock(check: (Bool, String) -> Void) {
        let size = CGSize(width: 1280, height: 820)
        let mutation = ProcessInfo.processInfo.environment["SELFTEST_M52_MUTATION"] ?? ""
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        for scale: CGFloat in [1, 2] {
            do {
                let store = ConversationStore()
                let ids = ["A", "B", "C", "D", "E", "F"]
                for id in ids {
                    store.add(Conversation(id: id, title: id))
                }
                let profile = DisplayProfile(name: "M52 undo", frameInterval: 1 / 120,
                                             mmPerPoint: 0.2, persistenceFrames: 0)
                let scene = AutoScene(size: size, store: store, profile: profile, scale: scale)
                scene.verificationPresented = true
                scene.manualSettle = true
                scene.ambient = false
                var time = CACurrentMediaTime() + 3600
                scene.now = { time }
                scene.install(members: ids)
                scene.clock.invalidate()
                store.onChange = { [weak scene] conversation in scene?.changed(conversation) }
                func settle() {
                    time = max(time, scene.transitionEnd + 0.1)
                    scene.clock.onFrame?(time)
                    scene.settle()
                    CATransaction.flush()
                }
                scene.enterFocused("C", reason: "m52-undo")
                settle()
                let focused = scene.scheme.left == ["B", "A"] && scene.scheme.right == ["D", "E", "F"]
                let archived = store.conversation("B")!
                scene.archiveOrb(archived, at: CGPoint(x: 300, y: 300))
                settle()
                let removed = scene.scheme.left == ["D", "A"] && scene.scheme.right == ["E", "F"]
                let arrival = Conversation(id: "X", title: "X")
                store.add(arrival)
                scene.addOrbToDock(arrival, at: 10, origin: nil, reason: "m52-undo-arrival")
                settle()
                let arrived = scene.scheme.left == ["D", "A"] && scene.scheme.right == ["E", "F", "X"]
                scene.undoOrbArchive("B")
                settle()
                let restored = scene.scheme.left == ["D", "B", "A"] && scene.scheme.right == ["E", "F", "X"]
                check(focused && removed && arrived && restored, "m52 dock archive undo order \(Int(scale))x")
                scene.disposeTranscriptPresentation()
            }
            for index in [0, 1, 4] {
                let store = ConversationStore()
                let ids = (0..<9).map { "m52-\($0)" }
                for id in ids { store.add(Conversation(id: id, title: id)) }
                let profile = DisplayProfile(name: "M52 fixture", frameInterval: 1 / 120,
                                             mmPerPoint: 0.2, persistenceFrames: 0)
                let scene = AutoScene(size: size, store: store, profile: profile, scale: scale)
                scene.verificationPresented = true
                scene.manualSettle = true
                scene.ambient = false
                var time = CACurrentMediaTime() + 3600
                scene.now = { time }
                scene.install(members: ids)
                scene.clock.invalidate()
                func settle() {
                    time = max(time, scene.transitionEnd + 0.1)
                    scene.clock.onFrame?(time)
                    scene.settle()
                    CATransaction.flush()
                }
                let screen = scene.scheme.parked + scene.order.filter { !scene.scheme.parked.contains($0) }
                let target = screen[index]
                let beforeBar = scene.layout.bars.first
                let beforeColumn = scene.layout.columns.first
                scene.enterFocused(target, reason: "m52-dock")
                settle()
                var sch = scene.scheme
                if mutation == "focus-sides" {
                    sch.left = Array(screen[..<index].reversed())
                    sch.right = Array(screen[(index + 1)...])
                }
                let tag = "\(Int(scale))x position \(index + 1)"
                let m = scene.metrics
                let bars = scene.layout.bars
                let orbs = scene.layout.orbs
                check(sch.left.count == 4 && sch.right.count == 4, "m52 dock focus balance \(tag)")
                check(Array(sch.left.reversed()) + sch.right == screen.filter { $0 != target },
                      "m52 dock focus order \(tag)")
                if var bar = bars.first, let outerLeft = orbs.first(where: { $0.minX < bar.minX }),
                   let outerRight = orbs.last, let column = scene.layout.columns.first {
                    if mutation == "centered-bar" {
                        bar.origin.x = column.minX
                        bar.size.width = column.width
                    }
                    let left = Array(orbs.prefix(sch.left.count))
                    let right = Array(orbs.dropFirst(sch.left.count))
                    check(near(left.last?.minX ?? outerLeft.minX, m.inset)
                          && near(outerRight.maxX, size.width - m.inset), "m52 dock focus margins \(tag)")
                    let ordered = Array(left.reversed()) + [bar] + right
                    check(orbs.allSatisfy { near($0.width, m.orb) && near($0.height, m.orb) },
                          "m52 dock focus orb sizes \(tag)")
                    check(zip(ordered, ordered.dropFirst()).allSatisfy { near($1.minX - $0.maxX, m.orbGap) },
                          "m52 dock focus gaps \(tag)")
                    let reserve = CGFloat(max(sch.left.count, sch.right.count)) * (m.orb + m.orbGap) + m.orbGap
                    let width = max(220, min(768, max(320, size.width - 2 * m.inset - 2 * reserve)))
                    check(near(column.width, width) && near(column.midX, size.width / 2),
                          "m52 dock column width \(tag)")
                    if index == 0 {
                        print("M52 FRAMES", tag, "before", String(describing: beforeBar),
                              String(describing: beforeColumn), "focused", bar, column)
                    }
                } else { check(false, "m52 dock focus geometry exists \(tag)") }
                if index == 0 {
                    let incoming = sch.right[0]
                    check(scene.openInSplit(incoming, reason: "m52-dock"), "m52 dock split opens \(tag)")
                    settle()
                    let pair = scene.layout
                    let split = scene.scheme
                    check(split.right.count >= split.left.count && split.right.count - split.left.count <= 1,
                          "m52 dock split balance \(tag)")
                    if pair.bars.count == 2, pair.columns.count == 2, !pair.orbs.isEmpty {
                        let left = Array(pair.orbs.prefix(split.left.count))
                        let right = Array(pair.orbs.dropFirst(split.left.count))
                        let gap = max(CGFloat(12), m.gap)
                        check(near(left.last?.minX ?? pair.me.minX, m.inset)
                              && near(right.last?.maxX ?? pair.bars[1].maxX, size.width - m.inset),
                              "m52 dock split margins \(tag)")
                        check(near(pair.bars[0].minX, pair.me.maxX + gap)
                              && near((right.first?.minX ?? 0) - pair.bars[1].maxX, max(12, m.orbGap)),
                              "m52 dock split gaps \(tag)")
                        check(near((pair.bars[0].maxX + pair.bars[1].minX) / 2, size.width / 2)
                              && pair.columns.enumerated().allSatisfy { near($1.minX, CGFloat($0) * size.width / 2)
                                  && near($1.width, size.width / 2) }, "m52 dock split columns \(tag)")
                        print("M52 FRAMES", tag, "split", pair.bars)
                    } else { check(false, "m52 dock split geometry exists \(tag)") }
                } else if index == 1 {
                    let initial = Array(sch.left.reversed()) + sch.right
                    let removed = sch.right.last!
                    scene.transition(to: scene.members.filter { $0.id != removed }, current: target,
                                     scheme: scene.scheme, spring: AutoScene.focusSpring, reason: "m52-remove")
                    settle()
                    var after = scene.scheme
                    if mutation == "remove-unbalanced" {
                        after = sch
                        after.right.removeAll { $0 == removed }
                    }
                    check(after.left.count == 3 && after.right.count == 4 && after.right.first == sch.left.first,
                          "m52 dock right removal rebalances \(tag)")
                    check(Array(after.left.reversed()) + after.right == initial.filter { $0 != removed },
                          "m52 dock right removal order \(tag)")
                    let removedLeft = after.left.last!
                    scene.transition(to: scene.members.filter { $0.id != removedLeft }, current: target,
                                     scheme: scene.scheme, spring: AutoScene.focusSpring, reason: "m52-remove")
                    settle()
                    check(scene.scheme.left.count == 3 && scene.scheme.right.count == 3,
                          "m52 dock left removal rebalances \(tag)")
                    check(Array(scene.scheme.left.reversed()) + scene.scheme.right
                          == initial.filter { $0 != removed && $0 != removedLeft },
                          "m52 dock left removal order \(tag)")
                    let firstArrival = Conversation(id: "m52-short-a", title: "New A")
                    store.add(firstArrival)
                    scene.addOrbToDock(firstArrival, at: 10, origin: nil, reason: "m52-arrival")
                    settle()
                    let shortSide = scene.scheme
                    let secondArrival = Conversation(id: "m52-short-b", title: "New B")
                    store.add(secondArrival)
                    scene.addOrbToDock(secondArrival, at: 10, origin: nil, reason: "m52-arrival")
                    settle()
                    check(shortSide.left.count == 3 && shortSide.right.count == 4
                          && scene.scheme.left == shortSide.left + [secondArrival.id]
                          && scene.scheme.right == shortSide.right, "m52 dock 3/4 arrival left outside \(tag)")
                } else {
                    let a = Conversation(id: "m52-new-a", title: "New A")
                    store.add(a)
                    scene.addOrbToDock(a, at: 10, origin: nil, reason: "m52-arrival")
                    settle()
                    check(scene.scheme.left == sch.left && scene.scheme.right == sch.right + [a.id],
                          "m52 dock tie arrival right outside \(tag)")
                    let b = Conversation(id: "m52-new-b", title: "New B")
                    store.add(b)
                    scene.addOrbToDock(b, at: 10, origin: nil, reason: "m52-arrival")
                    settle()
                    check(scene.scheme.left == sch.left + [b.id] && scene.scheme.right == sch.right + [a.id],
                          "m52 dock short-side arrival left outside \(tag)")
                }
                scene.disposeTranscriptPresentation()
            }
            let narrow = CGSize(width: 900, height: 700)
            let store = ConversationStore()
            let ids = (0..<9).map { "m52-narrow-\($0)" }
            for id in ids { store.add(Conversation(id: id, title: id)) }
            let profile = DisplayProfile(name: "M52 narrow fixture", frameInterval: 1 / 120,
                                         mmPerPoint: 0.2, persistenceFrames: 0)
            let scene = AutoScene(size: narrow, store: store, profile: profile, scale: scale)
            scene.verificationPresented = true
            scene.manualSettle = true
            scene.ambient = false
            var time = CACurrentMediaTime() + 3600
            scene.now = { time }
            scene.install(members: ids)
            scene.clock.invalidate()
            scene.enterFocused(ids[0], reason: "m52-narrow")
            time = scene.transitionEnd + 0.1
            scene.clock.onFrame?(time)
            scene.settle()
            let metrics = scene.metrics
            var layout = FocusLayout()
            layout.capsule = scene.layout.bars[0]
            layout.me = scene.layout.me
            layout.leftOrbs = Array(scene.layout.orbs.prefix(scene.scheme.left.count))
            layout.rightOrbs = Array(scene.layout.orbs.dropFirst(scene.scheme.left.count))
            let tag = "\(Int(scale))x narrow"
            check(near(layout.leftOrbs.last!.minX, metrics.inset)
                  && near(layout.rightOrbs.last!.maxX, narrow.width - metrics.inset), "m52 dock margins \(tag)")
            check(layout.capsule.width >= 319 && (layout.leftOrbs + layout.rightOrbs).allSatisfy {
                $0.minX >= 0 && $0.maxX <= narrow.width
            }, "m52 dock narrow fit \(tag)")
            for pointer in [layout.leftOrbs[1].midX, layout.rightOrbs[1].midX] {
                let grown = layout.magnified(pointerX: pointer, amount: 1, metrics: metrics)
                for (before, after) in [(layout.leftOrbs, grown.leftOrbs), (layout.rightOrbs, grown.rightOrbs)] {
                    let low = before.map(\.minX).min()!
                    let high = before.map(\.maxX).max()!
                    check(after.allSatisfy { $0.minX >= low - 1 && $0.maxX <= high + 1 },
                          "m52 dock magnify bounds \(tag)")
                }
                check(grown.capsule == layout.capsule && grown.me == layout.me, "m52 dock magnify fixed \(tag)")
            }
            scene.disposeTranscriptPresentation()

            let trioStore = ConversationStore()
            let trioIDs = (0..<3).map { "m52-trio-\($0)" }
            for id in trioIDs { trioStore.add(Conversation(id: id, title: id)) }
            let trio = AutoScene(size: size, store: trioStore, profile: profile, scale: scale)
            trio.verificationPresented = true
            trio.manualSettle = true
            trio.ambient = false
            var trioTime = CACurrentMediaTime() + 3600
            trio.now = { trioTime }
            trio.install(members: trioIDs)
            trio.clock.invalidate()
            trio.enterFocused(trioIDs[0], reason: "m52-single-orb")
            trioTime = trio.transitionEnd + 0.1
            trio.settle()
            let opened = trio.openInSplit(trioIDs[1], reason: "m52-single-orb")
            trioTime = trio.transitionEnd + 0.1
            trio.settle()
            if opened, trio.layout.bars.count == 2, let orb = trio.layout.orbs.first {
                var single = FocusLayout()
                single.capsule = trio.layout.bars[0].union(trio.layout.bars[1])
                single.me = trio.layout.me
                single.rightOrbs = [orb]
                let grown = single.magnified(pointerX: orb.midX, amount: 1, metrics: trio.metrics).rightOrbs[0]
                check(grown.width > trio.metrics.orb && grown.minX >= 0 && grown.maxX <= size.width
                      && !grown.intersects(trio.layout.bars[1]) && !grown.intersects(trio.layout.me)
                      && near(grown.midX, orb.midX) && near(grown.maxY, orb.maxY),
                      "m52 dock single Split orb magnifies \(Int(scale))x")
            } else {
                check(false, "m52 dock single Split orb fixture \(Int(scale))x")
            }
            trio.disposeTranscriptPresentation()
        }
    }

    static func verifySplitRefusal(check: (Bool, String) -> Void) {
        for scale: CGFloat in [1, 2] {
            let store = ConversationStore()
            let mock = MockReplay(store: store)
            mock.start(live: false)
            let profile = DisplayProfile(name: "split-refusal", frameInterval: 1 / 60,
                                         mmPerPoint: 0.27, persistenceFrames: 0)
            let scene = AutoScene(size: CGSize(width: 1280, height: 820), store: store,
                                  profile: profile, scale: scale)
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 1280, height: 820))
            for view in [scene.sceneView, scene.nativePlane, scene.peekNode.view, scene.dockView, scene.overlayPlane] {
                host.addSubview(view)
            }
            let toastClock = OverlayManualClock()
            scene.orbToast = OrbActionToast(clock: toastClock)
            scene.manualSettle = true
            scene.verificationPresented = true
            scene.ambient = false
            var time = CACurrentMediaTime() + 100
            scene.now = { time }
            scene.dock.motionTime = { time }
            scene.install(members: ["A", "B", "C", "D", "E", "F"])
            func settle() {
                time += 2
                scene.clock.onFrame?(time)
                scene.settle()
                scene.clock.invalidate()
            }
            settle()
            scene.enterFocused(scene.current, reason: "M53 fixture")
            settle()
            guard let incoming = scene.order.first(where: { !scene.scheme.split.contains($0) }),
                  let origin = scene.dock.frame(of: incoming), let single = scene.dock.capsule else {
                check(false, "M53 single Focused fixture exists @\(scale)x")
                scene.disposeTranscriptPresentation()
                continue
            }
            let start = CGPoint(x: origin.midX, y: origin.midY)
            let target = CGPoint(x: single.midX, y: single.midY)
            let pressed = scene.pointerDown(start)
            scene.pointerDragged(target)
            _ = scene.pointerUp(target)
            settle()
            check(pressed && scene.scheme.split.count == 2 && scene.scheme.split.contains(incoming),
                  "M53 single Focused drag still creates Split @\(scale)x")
            guard scene.scheme.split.count == 2,
                  let third = scene.order.first(where: { !scene.scheme.split.contains($0) }),
                  let source = scene.dock.frame(of: third), let capsule = scene.dock.capsule,
                  let right = scene.layout.bars.last else {
                check(false, "M53 two-member Split fixture exists @\(scale)x")
                scene.disposeTranscriptPresentation()
                continue
            }
            let scheme = scene.scheme
            let members = scene.members.map(\.id)
            let bars = scene.layout.bars
            let sourcePoint = CGPoint(x: source.midX, y: source.midY)
            let drop = CGPoint(x: right.midX, y: capsule.midY)
            let started = scene.pointerDown(sourcePoint)
            scene.markConversationOrbPress(sourcePoint, pickup: source)
            scene.pointerDragged(CGPoint(x: sourcePoint.x + 10, y: sourcePoint.y))
            time += 0.1
            scene.dock.frame(at: time, elapsed: .infinity)
            let pairs = scene.scheme.split
            let groups = scene.order.filter { $0 != third } + ["me"]
            func topology() -> [String: Bool] {
                var result: [String: Bool] = [:]
                for i in groups.indices {
                    for j in groups.indices where j > i {
                        if let connected = scene.dock.topologyConnected(groups[i], groups[j]) {
                            result[groups[i] + "|" + groups[j]] = connected
                        }
                    }
                }
                return result
            }
            let beforeTopology = topology()
            scene.pointerDragged(drop)
            let entered = scene.orbRefuse.entryReplicaPose
            let beforeEntry = scene.orbRefuse.entrySourcePose
            let entryGap = max(abs(entered.midX - beforeEntry.midX), abs(entered.midY - beforeEntry.midY),
                               abs(entered.width - beforeEntry.width), abs(entered.height - beforeEntry.height))
            time += 0.1
            scene.dock.frame(at: time, elapsed: .infinity)
            let nativeHidden = scene.dock.trashCarrier(third)?.glass.isHidden == true
            let separate = scene.orbRefuse.orb?.glassView.superview === scene.orbRefuse.view
            let dark = scene.orbRefuse.visible && abs(scene.orbRefuse.view.alphaValue - 0.45) < 0.001
            let toast = scene.orbToast.superview != nil
                && scene.orbToast.label.stringValue == "Split holds two conversations"
            let expiry = scene.orbToast.expiresAt
            let fixed = scene.dock.capsule == capsule && scene.layout.bars == bars
                && topology() == beforeTopology
                && scene.dock.topologyConnected(third, pairs[1]) != true
            check(nativeHidden && separate && fixed,
                  "M53 refusal keeps source hidden and topology unchanged @\(scale)x")
            let beforeExit = scene.orbRefuse.pose
            scene.pointerDragged(sourcePoint)
            let afterExit = scene.dock.trashCarrier(third)?.rect ?? .zero
            let exitGap = max(abs(beforeExit.midX - afterExit.midX), abs(beforeExit.midY - afterExit.midY),
                              abs(beforeExit.width - afterExit.width), abs(beforeExit.height - afterExit.height))
            time += 0.1
            scene.dock.frame(at: time, elapsed: .infinity)
            let restored = scene.dock.trashCarrier(third)?.glass.isHidden == false && !scene.orbRefuse.visible
            toastClock.advance(by: 0.1)
            scene.pointerDragged(drop)
            check(started && dark && restored && toast && scene.orbToast.expiresAt == expiry,
                  "M53 third orb stays dark, preserves geometry and shows one toast @\(scale)x")
            check(entryGap <= 0.5 && exitGap <= 0.5, "M53 entry and exit handoffs do not jump @\(scale)x")
            _ = scene.pointerUp(drop)
            settle()
            let returned = scene.dock.frame(of: third).map {
                abs($0.midX - source.midX) <= 1 && abs($0.midY - source.midY) <= 1
            } ?? false
            check(scene.scheme == scheme && scene.members.map(\.id) == members
                  && scene.layout.bars == bars && returned && scene.orbToast.superview != nil,
                  "M53 refusal returns orb without changing Split @\(scale)x")
            let refusal = scene.orbRefuse
            let handoff = "delta=\(refusal.handoffDelta), pose=\(refusal.handoffPose)"
            let sourceFrame = "source=\(String(describing: refusal.handoffSource))"
            let status = "visible=\(refusal.visible), returning=\(refusal.returning)"
                + ", retiredReturn=\(refusal.handoffWasReturning)"
            let currentSource = scene.dock.trashCarrier(third).map {
                scene.overlayPlane.convert($0.rect, from: scene.dockView)
            }
            let current = "currentPose=\(refusal.pose), currentSource=\(String(describing: currentSource))"
            check(refusal.handoffWasReturning && refusal.handoffDelta <= 0.5 && !refusal.visible,
                  "M53 return handoff @\(scale)x, \(handoff), \(sourceFrame), \(status), \(current)")
            check(scene.orbTrash.ownershipFailures == 0, "M53 three-way ownership stays valid @\(scale)x")
            let repressed = scene.pointerDown(sourcePoint)
            scene.markConversationOrbPress(sourcePoint, pickup: source)
            scene.pointerDragged(CGPoint(x: sourcePoint.x + 10, y: sourcePoint.y))
            scene.pointerDragged(drop)
            _ = scene.pointerUp(drop)
            let midReturn = refusal.visible && refusal.returning && time < scene.transitionEnd
            scene.settle()
            let visibleSource = scene.dock.trashCarrier(third).map {
                !$0.glass.isHidden && $0.glass.layer?.isHidden != true
            } ?? false
            check(repressed && midReturn && !refusal.visible && !refusal.returning && visibleSource
                  && refusal.handoffWasReturning && refusal.handoffDelta <= 0.5,
                  "M53 settle during return hands off without a ghost @\(scale)x")
            scene.orbToast.dismiss()
            scene.disposeTranscriptPresentation()
        }
    }

    static func verifyLLRefusal(check: (Bool, String) -> Void) {
        for scale: CGFloat in [1, 2] { verifyLLRefusal(scale: scale, check: check) }
    }

    private static func verifyLLRefusal(scale: CGFloat, check: (Bool, String) -> Void) {
        let store = ConversationStore()
        let mock = MockReplay(store: store)
        mock.start(live: false)
        let profile = DisplayProfile(name: "LL-refusal", frameInterval: 1 / 60,
                                     mmPerPoint: 0.27, persistenceFrames: 0)
        let size = CGSize(width: 1280, height: 820)
        let scene = AutoScene(size: size, store: store, profile: profile, scale: scale)
        let host = NSView(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for view in [scene.sceneView, scene.nativePlane, scene.peekNode.view, scene.dockView, scene.overlayPlane] {
            host.addSubview(view)
        }
        defer {
            scene.disposeTranscriptPresentation()
            window.contentView = nil
            window.close()
        }
        scene.manualSettle = true
        scene.verificationPresented = true
        scene.ambient = false
        var time = CACurrentMediaTime() + 100
        scene.now = { time }
        scene.dock.motionTime = { time }
        scene.install(members: ["A", "B", "C", "D", "E", "F"])
        func settle() {
            time += 2
            scene.clock.onFrame?(time)
            scene.settle()
            scene.clock.invalidate()
        }
        settle()
        scene.enterFocused(scene.current, reason: "LL refusal fixture")
        settle()
        guard let incoming = scene.order.first(where: { !scene.scheme.split.contains($0) }) else {
            check(false, "LL refusal fixture has an incoming member @\(scale)x")
            return
        }
        scene.graft(incoming, at: 1, reason: "LL refusal fixture")
        settle()
        guard scene.scheme.split.count == 2, let me = scene.dock.meFrame,
              let right = scene.layout.bars.last, let conversation = scene.conversation(scene.scheme.split[1]) else {
            check(false, "LL refusal fixture has two segments and LL @\(scale)x")
            return
        }
        let composer = scene.composer(for: conversation)
        let scheme = scene.scheme
        let start = CGPoint(x: me.midX, y: me.midY)
        let drop = CGPoint(x: right.midX, y: right.midY)
        let inRange = scene.dock.capsule?.insetBy(dx: -24, dy: -24).contains(drop) == true
        let pressed = scene.pointerDown(start)
        scene.pointerDragged(drop)
        let excluded = scene.drag.map { !scene.refusesDrop($0, at: drop) } ?? false
        let clear = !scene.orbRefuse.visible && scene.orbRefuse.pending == nil && scene.orbToast.superview == nil
        _ = scene.pointerUp(drop)
        let focused = window.firstResponder === composer.textView
        check(pressed && inRange && excluded && clear && !scene.orbRefuse.visible && scene.orbToast.superview == nil
              && !scene.dock.isHoldingMe && scene.scheme == scheme && focused,
              "LL over Split keeps normal right-segment focus and never enters refusal @\(scale)x")
    }

    static func verifyRefuseThenTrash(check: (Bool, String) -> Void) {
        let previous = OrganicFeatureAvailability.current
        OrganicFeatureAvailability.current.conversationOrbTear = false
        defer { OrganicFeatureAvailability.current = previous }
        for scale: CGFloat in [1, 2] {
            var outcomes: [[String]] = []
            for viaRefuse in [false, true] {
                let store = ConversationStore()
                let mock = MockReplay(store: store)
                mock.start(live: false)
                let profile = DisplayProfile(name: "refuse-trash", frameInterval: 1 / 60,
                                             mmPerPoint: 0.27, persistenceFrames: 0)
                let scene = AutoScene(size: CGSize(width: 1280, height: 820), store: store,
                                      profile: profile, scale: scale)
                let host = NSView(frame: CGRect(x: 0, y: 0, width: 1280, height: 820))
                for view in [scene.sceneView, scene.nativePlane, scene.peekNode.view,
                             scene.dockView, scene.overlayPlane] { host.addSubview(view) }
                let suite = "refuse-trash-" + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                scene.orbTrash.preferences = .init(defaults: defaults)
                scene.manualSettle = true
                scene.verificationPresented = true
                scene.ambient = false
                var time = CACurrentMediaTime() + 100
                scene.now = { time }
                scene.dock.motionTime = { time }
                scene.install(members: ["A", "B", "C", "D", "E", "F"])
                func advance(_ seconds: Double) {
                    for _ in 0..<max(1, Int(seconds * 60)) {
                        time += 1.0 / 60
                        scene.frame(time)
                    }
                    scene.clock.invalidate()
                }
                advance(2)
                scene.settle()
                scene.enterFocused(scene.current, reason: "refuse-trash fixture")
                advance(2)
                scene.settle()
                guard let second = scene.order.first(where: { !scene.scheme.split.contains($0) }) else {
                    check(false, "M53 trash fixture has a second member @\(scale)x")
                    scene.disposeTranscriptPresentation()
                    continue
                }
                scene.graft(second, at: 1, reason: "refuse-trash fixture")
                advance(2)
                scene.settle()
                guard let third = scene.order.first(where: { !scene.scheme.split.contains($0) }),
                      let source = scene.dock.frame(of: third), let capsule = scene.dock.capsule,
                      let right = scene.layout.bars.last else {
                    check(false, "M53 trash fixture has a third orb @\(scale)x")
                    scene.disposeTranscriptPresentation()
                    continue
                }
                let start = CGPoint(x: source.midX, y: source.midY)
                let pressed = scene.pointerDown(start)
                scene.markConversationOrbPress(start, pickup: source)
                if viaRefuse {
                    scene.pointerDragged(CGPoint(x: right.midX, y: capsule.midY))
                    advance(0.3)
                    check(scene.orbRefuse.visible && scene.orbTrash.yieldedToRefuse,
                          "M53 trash path enters refusal @\(scale)x")
                }
                let last = scene.layout.orbs.max(by: { $0.maxX < $1.maxX })?.midX ?? 1234
                let canX = min(scene.dockView.bounds.maxX - 32, max(32, last))
                let canY = min(scene.dockView.bounds.maxY - 32, max(32, scene.layout.me.midY - 68))
                let target = CGPoint(x: canX - 52, y: canY)
                scene.pointerDragged(target)
                advance(1.5)
                let armed = scene.orbTrash.output?.pose.phase == .armed
                let cleared = !scene.orbRefuse.visible && !scene.orbTrash.yieldedToRefuse
                _ = scene.pointerUp(target)
                advance(1.2)
                let removed = scene.orbTrash.successfulRemovals == 1
                check(pressed && armed && cleared && removed && scene.orbTrash.ownershipChecks > 0
                      && scene.orbTrash.ownershipFailures == 0,
                      "M53 trash ownership and removal via=\(viaRefuse) @\(scale)x")
                outcomes.append(scene.members.map(\.id))
                scene.disposeTranscriptPresentation()
                defaults.removePersistentDomain(forName: suite)
            }
            check(outcomes.count == 2 && outcomes[0] == outcomes[1],
                  "M53 refusal then trash matches direct removal @\(scale)x")
        }
    }
}
