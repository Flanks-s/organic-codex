import AppKit
import QuartzCore

/// Real scene callbacks without a window, Core connection, or application entry point.
@MainActor enum M10ColumnWorkVerification {
    static func run(to path:String,size:CGSize)->Int32 {
        let out=URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        HeaderIsland.forceMotionTexturesForVerification=true
        defer {HeaderIsland.forceMotionTexturesForVerification=false}
        var checks=0,failures:[String]=[],reports:[[String:Any]]=[]
        @MainActor func check(_ value:Bool,_ message:String) {checks+=1;if !value {failures.append(message);print("FINDING",message)}}
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
            defer {scene.disposeTranscriptPresentation()}
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
