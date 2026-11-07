#if DEBUG_SELFTEST
import AppKit

@MainActor private final class S4TuningHost: DebugTuningHost {
    var snapshots: [DebugTuningSnapshot] = []
    var spring = LabSpring(response:0.42,damping:0.86)
    func applyDebugTuning(_ snapshot: DebugTuningSnapshot) {
        snapshots.append(snapshot)
        spring = LabSpring(response:snapshot[.autoResponse],damping:snapshot[.autoDamping])
    }
}

@MainActor enum DebugMockVerification {
    static func run(check: (Bool,String) -> Void) async {
        let tuning = DebugTuning(), one = S4TuningHost(), two = S4TuningHost()
        let first = DebugTuningBinding(tuning:tuning,host:one), second = DebugTuningBinding(tuning:tuning,host:two)
        check(one.snapshots == [.defaults] && two.snapshots == [.defaults],"S4 a new scene receives a complete initial tuning transaction")
        let original = one.spring.value(0.15)
        _ = tuning.set(DebugTuningParameter.autoResponse.key,0.8)
        check(one.snapshots.last?[.autoResponse] == 0.8 && two.snapshots.last == one.snapshots.last,"S4 two bound scenes receive the same motion parameters")
        check(abs(one.spring.value(0.15)-original)>0.05,"S4 the host contract changes an actual spring's sampled motion")
        _ = tuning.set(DebugTuningParameter.morphBurst.key,54);_ = tuning.set(DebugTuningParameter.queueDamping.key,0.6)
        _ = tuning.toggle("fullyFocused")
        check(one.snapshots.last?[.morphBurst] == 54 && one.snapshots.last?[.queueDamping] == 0.6 && one.snapshots.last?.toggles["fullyFocused"] == true,"S4 flight, queue and switch values share one scene snapshot")
        let late = S4TuningHost(), lateBinding = DebugTuningBinding(tuning:tuning,host:late)
        check(late.snapshots == [tuning.snapshot],"S4 windows created later inherit current values, not defaults")
        var resetIsAtomic = true, legacyParameters = 0, legacyToggles = 0
        tuning.onChange = { _,_ in legacyParameters += 1;resetIsAtomic = resetIsAtomic && tuning.snapshot == .defaults }
        tuning.onToggle = { _,_ in legacyToggles += 1;resetIsAtomic = resetIsAtomic && tuning.snapshot == .defaults }
        let beforeReset = one.snapshots.count, revision = tuning.revision
        tuning.reset()
        check(one.snapshots.count == beforeReset+1 && two.snapshots.last == .defaults && late.snapshots.last == .defaults,"S4 Reset publishes exactly one complete default transaction to all scenes")
        check(resetIsAtomic && legacyParameters == 3 && legacyToggles == 1 && tuning.revision == revision+1,"S4 legacy callbacks also see fully restored defaults")
        check(abs(one.spring.value(0.15)-original)<0.0000001,"S4 Reset restores the host spring's actual motion")
        let stable = one.snapshots.count
        tuning.reset();_ = tuning.set(DebugTuningParameter.autoResponse.key,0.42)
        check(one.snapshots.count == stable,"S4 unchanged Set and Reset do not invalidate prewarming or restart a clock")
        _ = tuning.set(DebugTuningParameter.mockCharsPerTick.key,31.9)
        check(tuning.snapshot.playback.charactersPerTick == 31 && tuning[.mockCharsPerTick] == 31,"S4 streamed character tuning is an integer at the application boundary")
        check(DebugTuningSnapshot(values:[DebugTuningParameter.mockCharsPerTick.key:.nan],toggles:[:]).playback.charactersPerTick == 16,"S4 manually constructed snapshots cannot trap when converting a nonfinite character count")
        check(!tuning.set("unknown",10) && !tuning.set("orb.size",.infinity),"S4 invalid keys and nonfinite parameters never reach hosts")
        let firstCount = one.snapshots.count
        first.invalidate();first.invalidate();_ = tuning.set(DebugTuningParameter.morphPop.key,0.3)
        check(one.snapshots.count == firstCount && two.snapshots.last?[.morphPop] == 0.3,"S4 closing a scene invalidates only its binding, idempotently")
        var selfToken: UUID?, selfCalls = 0
        selfToken = tuning.observe(deliverInitial:false) { _ in selfCalls += 1;if let selfToken { tuning.removeObserver(selfToken) } }
        _ = tuning.set(DebugTuningParameter.morphSwirl.key,50);_ = tuning.set(DebugTuningParameter.morphSwirl.key,51)
        check(selfCalls == 1,"S4 an observer may retire itself safely during publication")
        weak var released: S4TuningHost?;var retainedBinding: DebugTuningBinding?
        do { let host = S4TuningHost();released = host;retainedBinding = DebugTuningBinding(tuning:tuning,host:host) }
        check(released == nil,"S4 tuning never retains a retired scene")
        retainedBinding?.invalidate();retainedBinding = nil;second.invalidate();lateBinding.invalidate()

        let clock = S4ManualClock(), store = ConversationStore(), replay = MockReplay(store:store,clock:clock)
        replay.start(live:false)
        let tools = DebugTools(store:store,mock:replay)
        let scene = S4TuningHost(), binding = tools.bindTuning(to:scene)
        let panelController = tools.controller(.debug), panel = panelController.acquireContent() as! DebugPanelPage
        func tree(_ root: NSView) -> [NSView] { [root]+root.subviews.flatMap(tree) }
        let characterSlider = tree(panel.view).compactMap { $0 as? DebugSlider }.first { $0.accessibilityLabel() == DebugTuningParameter.mockCharsPerTick.label }!
        check(characterSlider.isEnabled,"S4 the real panel enables streamed characters for mock")
        characterSlider.set(37,notify:true)
        check(replay.playbackSettings.charactersPerTick == 37 && scene.snapshots.last?[.mockCharsPerTick] == 37,"S4 the real panel slider applies to the source and scene without replacing callbacks")
        check(await clock.requests.isEmpty,"S4 constructing tools, bindings and an offscreen panel starts no timer")
        tools.releaseAllContent()
        _ = tools.session.tuning.set(DebugTuningParameter.mockTick.key,0.5)
        _ = tools.session.tuning.set(DebugTuningParameter.mockEventInterval.key,3)
        check(replay.playbackSettings.tickInterval == 0.5 && replay.playbackSettings.backgroundEventInterval == 3,"S4 programmatic tuning applies with the panel closed")
        check(tools.startPlayback(),"S4 App has an explicit single-source startup entry")
        check(await MockPlaybackVerification.wait { await clock.requests.count == 1 },"S4 startup owns one playback sleep")
        let firstGeneration = replay.playbackGeneration
        _ = tools.startPlayback()
        check(replay.playbackGeneration == firstGeneration,"S4 repeated App startup is idempotent")
        let a = store.conversation("A")!, done = a.satellites.filter(\.done).count
        for _ in 0..<6 {
            let count = replay.totalTicks, latest = (await clock.requests).last!.id
            await clock.release(latest)
            _ = await MockPlaybackVerification.wait { let pending = await clock.pending; return replay.totalTicks == count+1 && pending.count == 1 }
        }
        check(a.satellites.filter(\.done).count == done+1 && tools.session.ticks == 6,"S4 background events run before opening a panel or pressing Resume")
        let requested = (await clock.requests).count
        _ = tools.session.setPaused(true)
        check(tools.session.step() && tools.session.ticks == 7,"S4 panel Step forwards exactly one tick to the source")
        for id in await clock.pending { await clock.release(id) }
        for _ in 0..<30 { await Task.yield() }
        let afterStepRequests = await clock.requests
        check(tools.session.ticks == 7 && afterStepRequests.count == requested,"S4 Pause and Step never allocate another playback loop")
        _ = tools.session.tuning.set(DebugTuningParameter.mockCharsPerTick.key,90)
        tools.session.tuning.reset()
        check(replay.playbackSettings == .init() && scene.snapshots.last == .defaults && tools.session.paused,"S4 Reset restores mock and scene settings without resuming a paused source")
        _ = tools.session.setPaused(false)
        _ = await MockPlaybackVerification.wait { (await clock.pending).count == 1 }
        let beforeRetiming = replay.playbackGeneration
        _ = tools.session.tuning.set(DebugTuningParameter.mockTick.key,0.1)
        _ = await MockPlaybackVerification.wait { (await clock.requests).last?.seconds == 0.1 }
        check(replay.playbackGeneration > beforeRetiming && tools.session.paused == false,"S4 changing tick while running retimes the existing source")
        tools.session.tuning.reset()
        _ = await MockPlaybackVerification.wait { (await clock.requests).last?.seconds == 0.25 }
        check(replay.playbackSettings == .init(),"S4 Reset also restores the next sleeping interval while running")
        let reactivated = panelController.acquireContent() as! DebugPanelPage
        let restoredSlider = tree(reactivated.view).compactMap { $0 as? DebugSlider }.first { $0.accessibilityLabel() == DebugTuningParameter.mockCharsPerTick.label }!
        check(restoredSlider.value == 16,"S4 reopening the panel reads applied defaults")
        let foreign = DebugSession(store:ConversationStore(),replay:replay)
        check(!foreign.canInject && !foreign.startPlayback() && !foreign.setPaused(true),"S4 a Debug session cannot control a replay from another store")
        foreign.stopClock()
        check(replay.isPlaybackActive,"S4 a foreign session cannot stop the source it does not own")
        store.usesLiveCore = true;reactivated.refresh()
        check(!restoredSlider.isEnabled,"S4 Live disables the real mock character slider")
        let emitted = replay.emitted, ticks = replay.totalTicks
        for event in DebugInjection.allCases { check(!tools.session.inject(event,into:"A"),"S4 Debug Live rejects: " + event.rawValue) }
        check(!tools.startPlayback() && !tools.session.step() && tools.session.arrive() == nil,"S4 Live rejects startup, stepping and new arrivals")
        _ = tools.session.tuning.set(DebugTuningParameter.mockCharsPerTick.key,99)
        _ = tools.session.tuning.set(DebugTuningParameter.autoResponse.key,0.8)
        check(replay.playbackSettings.charactersPerTick == 16 && scene.snapshots.last?[.autoResponse] == 0.8,"S4 Live can calibrate visuals without applying mock business parameters")
        for id in await clock.pending { await clock.release(id) }
        for _ in 0..<30 { await Task.yield() }
        check(replay.totalTicks == ticks && replay.emitted == emitted,"S4 Live transition fences all old sleeps")
        binding.invalidate();tools.shutdown();await clock.finishAll()
        check(NSApp.windows.allSatisfy { !$0.isVisible },"S4 verification opens no windows")
    }
}
#endif
