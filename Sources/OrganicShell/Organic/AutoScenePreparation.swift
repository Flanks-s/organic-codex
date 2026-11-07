import AppKit
import QuartzCore

extension AutoScene {
    /// Opening and cancelling have known endpoints before input. Keep their exact ordinary plan at rest;
    /// interrupted or invalidated input still prepares synchronously from the current presentation.
    struct NewChatPreparationKey: Equatable {
        let size: CGSize, scheme: Scheme, revisions: [Int]
        let appearance: Int, display: Int
        let reduce: Bool, playful: Bool, presented: Bool, fullBleed: Bool
        let models: [ObjectIdentifier], treatment: [Double]
    }
    var newChatPreparationKey: NewChatPreparationKey {
        .init(size:size,scheme:scheme,revisions:revisions + members.map(\.revision) + members.map {id in nodes[id.id].map{prewarmNativeState($0)} ?? 0} + members.map {nodes[$0.id]?.ownsNative == true ? 1:0},appearance:NativeAppearance.revision,
              display:NativeDisplayOptions.shared.revision,reduce:Motion.reduce,playful:Look.playful,
              presented:transcriptsPresented,fullBleed:Self.fullBleed,models:members.map(ObjectIdentifier.init),
              treatment:[exposure.onsetMM,exposure.fullMM,Double(exposure.spacing),Double(exposure.maxCopies),
                         Tuning.shared.autoSpring.response,Tuning.shared.autoSpring.damping])
    }
    func discardNewChatPreparation() {
        if let p=newChatPreparation?.plan {unstage(p)}
        newChatPreparation=nil
    }
    private func prepareNewChatTransition() {
        guard newChatPreparation?.key != newChatPreparationKey else {return}
        discardNewChatPreparation()
        var next=scheme;next.draft.toggle()
        let rest=M11RestPresentation(columns)
        let p=prepare(members:members,current:current,scheme:next,at:now())
        rest.restore()
        for column in columns {
            let id=column.conversation.id
            if let rect=p.rects[id]?.target {column.island?.warmMotionTextures(variant:isFull(id,next) ? .full:.brief,columnWidth:rect.width)}
        }
        stage(p)
        newChatPreparation=(newChatPreparationKey,p)
    }
    /// What a prepared switch was made from: the working set, content revisions and the native views' scroll.
    // Hidden viewports may be laid out at several target widths during preparation. Their captureRevision
    // is an implementation detail, not new readable content. Model revisions still cover every shown column.
    private func prewarmNativeState(_ column:ColumnNode)->Int {column.form.to>0.5 ? column.nativeState:0}
    var revisions: [Int] {
        [order.hashValue,current.hashValue,Int(truncatingIfNeeded:profile.frameInterval.bitPattern),
         Int(truncatingIfNeeded:profile.mmPerPoint.bitPattern),columnExposureEnabled ? 1:0,exposure.enabled ? 1:0,
         Int(truncatingIfNeeded:exposure.shutter.bitPattern),columnZoomStyle == .gauss ? 1:0,
         size.width.hashValue,size.height.hashValue,NativeAppearance.revision,NativeDisplayOptions.shared.revision,
         Motion.reduce ? 1:0,Look.playful ? 1:0,scheme.mode == .auto ? 0:1,scheme.draft ? 1:0,
         scheme.split.hashValue,scheme.left.hashValue,scheme.right.hashValue,scheme.parked.hashValue,members.map(ObjectIdentifier.init).hashValue]
        + columns.map(\.conversation.revision) + columns.map{prewarmNativeState($0)}
    }

    func tracePrewarmLookup(id:String,plan:Prepared?,hit:Bool) {
        guard ModeSignposts.enabled || M10ColumnWorkTrace.active else{return}
        var reasons:[String]=[]
        if plan == nil {reasons.append(idlePrewarmTask == nil ? (prewarmMissReasons[id] ?? "absent"):"incomplete")}
        if isMoving {reasons.append("moving")}
        if plan?.fromRest == false {reasons.append("not-from-rest")}
        if dock.hasPeek {reasons.append("peek")}
        if let plan,plan.revisions != revisions {
            let names=Self.prewarmRevisionFields
            let current=revisions
            for i in 0..<max(plan.revisions.count,current.count) where i>=plan.revisions.count || i>=current.count || plan.revisions[i] != current[i] {
                reasons.append(i<names.count ? names[i]:(i<names.count+columns.count ? "model[\(i-names.count)]":"native[\(i-names.count-columns.count)]"))
            }
        }
        let reason=hit ? "hit":reasons.joined(separator:",")
        M10ColumnWorkTrace.count("scene.prewarm.lookup",["target":id,"hit":hit,"reason":reason,"job":idlePrewarmOutcome,"lastClear":lastPrewarmClear])
        if ModeSignposts.enabled {ModeSignposts.Trace().record("OrganicPrewarmLookup",detail:"target=\(id) \(reason) job=\(idlePrewarmOutcome) lastClear=\(lastPrewarmClear)")}
    }
    func requestPrewarm() {
        prewarmRequested=true
        if !prewarmScheduled,idlePrewarmTask == nil {idlePrewarmOutcome="queued"}
        if idleInputMonitor == nil,!verificationIdlePrewarm,sceneView.window != nil {
            idleInputMonitor=NSEvent.addLocalMonitorForEvents(matching:Self.prewarmInputMask) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self,event.window === self.sceneView.window {self.prewarmActivity()}
                }
                return event
            }
        }
        guard !modeHandoffActive,!prewarmScheduled,idlePrewarmTask == nil,
              presented,transcriptSessions == nil || transcriptsPresented else {return}
        prewarmScheduled=true
        let task=DispatchWorkItem { [weak self] in
            guard let self else{return}
            self.prewarmTask=nil;self.prewarmScheduled=false
            guard self.prewarmRequested else{return}
            guard self.idlePrewarmAllowed else {self.requestPrewarm();return}
            self.startIdlePrewarm()
        }
        prewarmTask=task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:task)
    }
    private var idlePrewarmAllowed:Bool {
        guard !modeHandoffActive,presented,transcriptSessions == nil || transcriptsPresented,
              !isMoving,draftColumn?.isMoving != true,!columns.isEmpty,scheme.mode == .auto,
              !dock.hasPeek,drag == nil,!clock.keepRunning,pressedButtons()==0,!columns.contains(where:{$0.isPromoting}),
              pendingRenders.isEmpty,pendingMovingRenders.isEmpty,!renderScheduled,!movingRenderScheduled,
              now()>=[idleMotionUntil,dock.meSettles,dock.peekSettles,dock.bloomSettles].max()! else {return false}
        let t=CACurrentMediaTime()
        guard t-lastPrewarmActivity>=0.25 else{return false}
        if !verificationIdlePrewarm,let event=NSApp.currentEvent,Self.prewarmInputMask.contains(NSEvent.EventTypeMask(rawValue:1 << event.type.rawValue)),t-event.timestamp<0.25 {return false}
        if !verificationIdlePrewarm,NSApp.nextEvent(matching:Self.prewarmInputMask,until:.distantPast,inMode:.default,dequeue:false) != nil {return false}
        return true
    }
    func cancelIdlePreparation() {
        if idlePrewarmTask != nil {idlePrewarmOutcome="cancelled"}
        idlePrewarmEpoch+=1;idlePrewarmTask?.cancel();idlePrewarmTask=nil
    }
    func prewarmActivity() {
        lastPrewarmActivity=CACurrentMediaTime()
        cancelIdlePreparation()
        requestPrewarm()
    }
    private func startIdlePrewarm() {
        if let screen=sceneView.window?.screen {profile=DisplayProfile.of(screen)}
        let epoch=idlePrewarmEpoch,key=newChatPreparationKey
        let idle=M11IdlePreparation(interval:verificationIdlePrewarm ? 0:min(profile.frameInterval,0.002)) { [weak self] in
            guard let self else{return false}
            return self.idlePrewarmEpoch==epoch && self.newChatPreparationKey==key && self.idlePrewarmAllowed
        }
        idle.recordSlices=verificationIdlePrewarm
        idlePrewarmOutcome="running"
        idlePrewarmTask=Task { @MainActor [weak self] in
            guard let self else{return}
            defer {
                idle.finish()
                if self.verificationIdlePrewarm {self.idlePrewarmSlices=idle.slices}
                if self.idlePrewarmEpoch==epoch {self.idlePrewarmTask=nil}
            }
            do {
                try await self.warmPeekImagesInIdle(idle)
                var ids=self.scheme.draft ? []:self.columns.filter{$0.conversation.id != self.current}.map{$0.conversation.id}
                if let preferred=self.preferredPrewarm,let i=ids.firstIndex(of:preferred) {ids.remove(at:i);ids.insert(preferred,at:0)}
                for id in ids {
                    if self.prewarmed[id]?.revisions==self.revisions {continue}
                    do {
                        let plan=try await self.prepareInIdle(members:self.members,current:id,at:self.now(),idle:idle)
                        try await self.warmIdleHeaders(plan,idle:idle)
                        try await idle.step("plan.stage") {
                            if let old=self.prewarmed[id] {self.unstage(old)}
                            self.stage(plan);self.prewarmed[id]=plan
                        }
                    } catch M11IdlePreparation.Stop.unsupportedSource(let reason) {self.prewarmMissReasons[id]=reason;M10ColumnWorkTrace.count("scene.prewarm.unsupported",["target":id,"reason":reason])}
                }
                // No overflow node allocation/native layout in an idle slice. Cold orbs keep the original fallback.
                if self.newChatPreparation?.key != self.newChatPreparationKey {
                    var next=self.scheme;next.draft.toggle()
                    do {
                        let plan=try await self.prepareInIdle(members:self.members,current:self.current,scheme:next,at:self.now(),idle:idle)
                        try await self.warmIdleHeaders(plan,idle:idle)
                        try await idle.step("newchat.stage") {
                            self.discardNewChatPreparation();self.stage(plan)
                            self.newChatPreparation=(self.newChatPreparationKey,plan)
                        }
                    } catch M11IdlePreparation.Stop.unsupportedSource(let reason) {self.prewarmMissReasons["newchat"]=reason;M10ColumnWorkTrace.count("scene.prewarm.unsupported",["target":"newchat","reason":reason])}
                }
                if self.scheme.draft {try await self.warmNewChatIslandInIdle(idle)}
                self.prewarmRequested=false;self.idlePrewarmOutcome="completed"
            } catch {
                if self.idlePrewarmEpoch==epoch {
                    self.idlePrewarmOutcome="interrupted"
                    self.idlePrewarmTask=nil
                    self.requestPrewarm()
                }
            }
        }
    }
    private func warmNewChatIslandInIdle(_ idle:M11IdlePreparation) async throws {
        guard !restOnSnapshot,let rect=layout.draftColumn else{return}
        let island:HeaderIsland
        if let ready=spareNewChatIsland {island=ready}
        else {
            island=try await idle.step("newchat.header.allocate") {
                let header=HeaderIsland();header.isHidden=true;return header
            }
            try await idle.step("newchat.header.mount") {nativePlane.addSubview(island);spareNewChatIsland=island}
        }
        let title=draftComposer?.text.split(separator:"\n",omittingEmptySubsequences:true).first.map{String($0.prefix(60))} ?? "New Chat"
        spareNewChatIdentity.title=title;spareNewChatIdentity.identityIndex=store.nextIdentity()
        island.motionProfile=profile;island.motionExposure=exposure;island.motionExposure.enabled=false
        var config=HeaderIslandConfiguration.conversation(spareNewChatIdentity,variant:.full,columnWidth:rect.width,
            band:HeaderIslandVariant.band(bleedTop:52),reduceMotion:Motion.reduce,ambient:ambient,
            isKeyWindow:sceneView.window?.isKeyWindow ?? true,scale:scale)
        config.active=false // a spare is a resource, not a live interactive/ambient header
        if island.configuration != config {
            try await idle.step("newchat.header.configure") {island.configure(config)}
        }
        if spareNewChatPromotionWarmConfig != config,let seed=draftColumn.map({$0.island.frame.minY+44}) {
            try await idle.step("newchat.header.promotion") {
                _=island.beginPromotion(seedCenterY:seed);island.endPromotion();spareNewChatPromotionWarmConfig=config
            }
        }
    }
    private func warmIdleHeaders(_ p:Prepared,idle:M11IdlePreparation) async throws {
        // ColumnNode configures sharp native headers. No cacheDisplay-backed glyph resource is needed.
    }
    /// Explicit synchronous warming is retained only for deterministic offscreen fixtures. Production hover
    /// and lifecycle requests use the same idle scheduler, including a stale-cache retry after streaming.
    func prewarm(_ index:Int?=nil) {
        if manualSettle && !verificationIdlePrewarm {prewarm(index,includeNewChat:true);return}
        if let i=index,columns.indices.contains(i) {preferredPrewarm=columns[i].conversation.id}
        requestPrewarm()
    }

    private func prewarm(_ index:Int?,includeNewChat:Bool) {
        let work=M10ColumnWorkTrace.scope("scene.prewarm",["moving":isMoving,"promotion":columns.contains{$0.isPromoting}]);defer{work.end()}
        if let screen=sceneView.window?.screen {profile=DisplayProfile.of(screen)}
        guard !modeHandoffActive, transcriptSessions == nil || transcriptsPresented else { return }
        // Not while a peek buds out: a switch prepared now would start its glass from the capsule.
        guard !isMoving, draftColumn?.isMoving != true, !columns.isEmpty, scheme.mode == .auto, !dock.hasPeek else { return }
        guard !columns.contains(where:{$0.isPromoting}) else {requestPrewarm();return}
        if scheme.draft {
            if includeNewChat {warmNewChatIsland();prepareNewChatTransition()}
            return
        }
        for i in index.map({ [$0] }) ?? Array(columns.indices) where i != fullIndex && i < columns.count {
            let id = columns[i].conversation.id
            if let p = prewarmed[id] {
                if p.revisions == revisions { continue }
                unstage(p)
            }
            let p = prepare(members: members, current: id, at: now())
            for column in columns {
                let key=column.conversation.id
                if let rect=p.rects[key]?.target {column.island?.warmMotionTextures(variant:key==p.current ? .full:.brief,columnWidth:rect.width)}
            }
            stage(p)
            prewarmed[id] = p
        }
        // Stage may have installed a new snapshot key. Warm after it, so a landing hits the visible brief's
        // exact key rather than baking it again after an earlier prewarm changed captureRevision.
        for column in columns { column.warmBriefExposureInk() }
        guard index == nil else { return }
        // Orbs: their columns and briefs made ahead, at the slot they would land in, so landing one only commits
        // (a cold landing spent 53 ms building the column and its native transcript before anything moved).
        let n = layout.columns.count
        guard let slot = (0..<n).last(where: { order[$0] != current }) else {if includeNewChat {prepareNewChatTransition()};return}
        for id in order.dropFirst(n) where conversation(id) != nil {
            _ = node(id, slot: slot, in: layout).snapshot(fullWidth: fullWidth(slot, layout), briefWidth: briefWidth(slot, layout))
        }
        if includeNewChat {prepareNewChatTransition()}
    }
}
