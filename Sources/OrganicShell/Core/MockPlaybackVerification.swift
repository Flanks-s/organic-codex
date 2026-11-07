#if CORE_SELFTEST || DEBUG_SELFTEST
import Foundation

/// Deliberately leaves cancelled sleeps pending. Releasing an old continuation proves the
/// generation fence, rather than relying on Task.sleep's cooperative cancellation.
actor S4ManualClock: CoreRuntimeClock {
    struct Request: Sendable { let id: Int; let seconds: TimeInterval }
    private var serial = 0
    private(set) var requests: [Request] = []
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    var pending: [Int] { waiting.keys.sorted() }
    func sleep(seconds: TimeInterval) async throws {
        serial += 1; let id = serial
        try await withCheckedThrowingContinuation { continuation in
            requests.append(.init(id:id, seconds:seconds)); waiting[id] = continuation
        }
    }
    func release(_ id: Int) { waiting.removeValue(forKey:id)?.resume() }
    func finishAll() {
        let old = waiting; waiting = [:]
        for value in old.values { value.resume(throwing:CancellationError()) }
    }
}

@MainActor enum MockPlaybackVerification {
    static func wait(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<4000 { if await predicate() { return true }; await Task.yield() }
        return false
    }
    static func run(check: (Bool,String) -> Void) async {
        let invalid = MockPlaybackSettings(tickInterval:.nan,charactersPerTick:Int.max,backgroundEventInterval: -.infinity).normalized
        check(invalid == .init(tickInterval:0.25,charactersPerTick:120,backgroundEventInterval:20),"S4 mock settings reject nonfinite values and bound character count")
        check(MockPlaybackSettings(tickInterval:0,charactersPerTick:0,backgroundEventInterval:0).normalized == .init(tickInterval:0.05,charactersPerTick:2,backgroundEventInterval:3),"S4 Core normalizes below-range values without a Debug dependency")
        let clock = S4ManualClock(), store = ConversationStore(), replay = MockReplay(store:store,clock:clock)
        replay.start(live:false)
        for seed in MockSeed.make() {
            let c = store.conversation(seed.id)!
            check(c.items.map(\.text) == seed.items.map(\.text) && c.running == seed.running && c.approvals.map(\.id) == seed.approvals.map(\.id) && c.approvals.map(\.command) == seed.approvals.map(\.command) && c.approvals.map(\.title) == seed.approvals.map(\.title),"S4 A–F seed unchanged: " + seed.id)
        }
        check(await clock.requests.isEmpty && !replay.isPlaybackActive,"S4 seeding does not start a clock")
        var deltas: [String] = [], times: [Double] = []
        replay.onEvent = { event in
            if event.params["threadId"] == "A",event.method == "item/reasoning/textDelta" { deltas.append(event.params["delta"]?.stringValue ?? ""); times.append(event.time ?? .nan) }
        }
        _ = replay.updatePlaybackSettings(.init(tickInterval:0.125,charactersPerTick:5))
        check(replay.step() && replay.totalTicks == 1 && deltas.last?.count == 5,"S4 paused Step writes the configured five characters in exactly one tick")
        replay.advance(ticks:1)
        check(deltas.count == 2 && deltas.allSatisfy{$0.count==5} && abs(times[1]-times[0]-0.125)<0.00001,"S4 manual ticks share configured cadence and virtual event timestamps")
        let tick = replay.totalTicks
        replay.advance(ticks:0);replay.advance(ticks: -1)
        check(replay.totalTicks == tick,"S4 nonpositive manual tick counts do not advance")
        replay.start(live:true)
        check(await wait { await clock.requests.count == 1 },"S4 starting playback schedules one sleep")
        let generation = replay.playbackGeneration
        replay.start(live:true);_ = replay.setPaused(false)
        check(replay.playbackGeneration == generation && !replay.step(),"S4 repeated Start/Resume is idempotent and running Step is rejected")
        replay.advance(ticks:50)
        check(replay.totalTicks == tick,"S4 a playing source rejects a second manual driver")
        _ = replay.setBackgroundEvents(false)
        _ = replay.updatePlaybackSettings(.init(tickInterval:0.125,charactersPerTick:27))
        check(replay.playbackGeneration == generation,"S4 background toggle and characters do not create a clock")
        _ = replay.updatePlaybackSettings(.init(tickInterval:0.5,charactersPerTick:27))
        check(await wait { await clock.requests.count == 2 },"S4 interval edit replaces the sleeping generation")
        let requests = await clock.requests
        check(requests.map(\.seconds) == [0.125,0.5],"S4 replacement sleep uses the new interval")
        await clock.release(requests[0].id)
        for _ in 0..<30 { await Task.yield() }
        check(replay.totalTicks == tick,"S4 a cancelled old sleep cannot tick after interval retiming")
        await clock.release(requests[1].id)
        check(await wait { replay.totalTicks == tick+1 },"S4 current sleep advances exactly once")
        check(deltas.last?.count == 27,"S4 next streamed fragment uses the changed character count")
        check(await wait { await clock.requests.count == 3 },"S4 the same loop rearms once")
        _ = replay.setPaused(true)
        let pausedTick = replay.totalTicks
        await clock.release((await clock.requests).last!.id)
        for _ in 0..<30 { await Task.yield() }
        check(replay.totalTicks == pausedTick && !replay.isPlaybackActive,"S4 Pause fences already scheduled work")
        check(replay.step() && replay.totalTicks == pausedTick+1,"S4 Step remains one tick after a running loop was paused")
        for _ in 0..<4 {
            let expected = (await clock.requests).count + 1
            _ = replay.setPaused(false)
            _ = await wait { await clock.requests.count == expected }
            _ = replay.setPaused(true)
        }
        let beforeStale = replay.totalTicks
        for id in await clock.pending { await clock.release(id) }
        for _ in 0..<30 { await Task.yield() }
        check(replay.totalTicks == beforeStale,"S4 rapid Pause/Resume never delivers extra ticks from four old generations")
        check(await clock.pending.isEmpty,"S4 fake clock releases every retired generation")
        replay.stopPlayback();await clock.finishAll()

        let backgroundStore = ConversationStore(), background = MockReplay(store:backgroundStore)
        background.start(live:false)
        _ = background.updatePlaybackSettings(.init(backgroundEventInterval:3))
        let a = backgroundStore.conversation("A")!, initialDone = a.satellites.filter(\.done).count
        background.advance(ticks:11)
        check(a.satellites.filter(\.done).count == initialDone,"S4 background event does not fire before its deadline")
        background.advance(ticks:1)
        check(a.satellites.filter(\.done).count == initialDone+1,"S4 background event advances from the source without any Debug panel")
        _ = background.setBackgroundEvents(false);background.advance(ticks:12)
        check(a.satellites.filter(\.done).count == initialDone+1,"S4 background Off leaves playback active but does not inject events")
        _ = background.setBackgroundEvents(true);background.advance(ticks:1)
        check(a.satellites.filter(\.done).count == initialDone+2,"S4 background Resume emits one event, never a catch-up burst")
        let f = backgroundStore.conversation("F")!, updated = f.updated
        check(background.inject(.addSatellite,into:f.id) && f.updated == updated,"S4 explicit satellite injection does not reorder the sidebar")
        check(background.inject(.approval,into:a.id),"S4 approval injection enters the source's blocked run")
        let waitingText = a.items.map(\.text), approval = a.approvals.first!
        background.advance(ticks:20)
        check(a.items.map(\.text) == waitingText && a.approvals.count == 1,"S4 injected approval blocks the same replay until a decision")
        background.respond(approval,in:a,action:.accept);background.advance(ticks:8)
        check(a.approvals.isEmpty && a.items.map(\.text) != waitingText,"S4 accepted injected approval resumes the blocked run")
        check(background.inject(.question,into:f.id) && f.userInput != nil,"S4 question is an ordinary structured mock request")
        let question = f.userInput!, questionItems = f.items
        background.advance(ticks:20)
        check(f.items == questionItems,"S4 question waits without another producer continuing the run")
        background.answer(question,in:f,answers:["direction":["Small change"]])
        check(f.userInput == nil && f.running,"S4 answering the original question resumes through the same source")
        let beforeDuplicate = f.items
        background.answer(question,in:f,answers:["direction":["Small change"]])
        check(f.items == beforeDuplicate,"S4 stale question responses do not send twice")

        let fixtureChat = backgroundStore.conversation("C")!
        let fixtureQuestion = UserInputRequest(id:"fixture-question:C",questions:[.init(id:"answer",header:"Question",prompt:fixtureChat.question!,options:[])])
        var staleFixture = fixtureQuestion;staleFixture.questions[0].prompt = "A different question"
        let fixtureItems = fixtureChat.items
        background.answer(staleFixture,in:fixtureChat,answers:["answer":["Yes"]])
        check(fixtureChat.items == fixtureItems && fixtureChat.question != nil,"S4 stale fixture question text is rejected")
        background.answer(fixtureQuestion,in:fixtureChat,answers:["answer":["New features only"]])
        check(fixtureChat.running && fixtureChat.question == nil,"S4 default C keeps its original native fixture-question answer contract")
        let fixtureAnswered = fixtureChat.items
        background.answer(fixtureQuestion,in:fixtureChat,answers:["answer":["New features only"]])
        check(fixtureChat.items == fixtureAnswered,"S4 the default C fixture answer is single use")

        let unicodeStore = ConversationStore(), unicode = MockReplay(store:unicodeStore)
        unicode.start(live:false);_ = unicode.updatePlaybackSettings(.init(charactersPerTick:7))
        let unicodeChat = unicodeStore.conversation("F")!, message = "看 👩🏽‍💻 café 🧪"
        var unicodeFragments: [String] = []
        unicode.onEvent = { event in
            if event.params["threadId"] == "F",event.method == "item/agentMessage/delta" { unicodeFragments.append(event.params["delta"]?.stringValue ?? "") }
        }
        check(unicode.send(unicodeChat,text:message),"S4 mock accepts a composed Unicode message")
        unicode.advance(ticks:80)
        let finalText = unicodeChat.items.last(where:{$0.kind == .assistant})?.text
        check(!unicodeFragments.isEmpty && unicodeFragments.allSatisfy{$0.count<=7} && unicodeFragments.joined() == finalText && finalText?.contains(message) == true,"S4 tuned chunks preserve composed Unicode and the complete reply")

        let liveClock = S4ManualClock(), liveStore = ConversationStore(), live = MockReplay(store:liveStore,clock:liveClock)
        live.start(live:true)
        _ = await wait { await liveClock.requests.count == 1 }
        liveStore.usesLiveCore = true
        let before = liveStore.conversations.map { ($0.id,$0.revision,$0.items) }, emitted = live.emitted
        for event in MockInjection.allCases { check(!live.inject(event,into:"A"),"S4 Core rejects Live injection: " + event.rawValue) }
        check(!live.step() && !live.setPaused(false) && !live.setBackgroundEvents(false) && !live.updatePlaybackSettings(.init()) && live.arrive() == nil,"S4 Core rejects all Live playback routes")
        live.advance(ticks:10);live.start(live:true)
        for id in await liveClock.pending { await liveClock.release(id) }
        for _ in 0..<30 { await Task.yield() }
        check(live.totalTicks == 0 && live.emitted == emitted && !live.isPlaybackActive,"S4 a source switched to Live cannot tick or reseed from an old continuation")
        check(zip(before,liveStore.conversations).allSatisfy { $0.0.0 == $0.1.id && $0.0.1 == $0.1.revision && $0.0.2 == $0.1.items },"S4 Live rejection does not mutate any conversation")
        await liveClock.finishAll()
        let liveOnly = ConversationStore();liveOnly.usesLiveCore = true
        let refused = MockReplay(store:liveOnly);refused.start(live:true)
        check(liveOnly.conversations.isEmpty && liveOnly.projects.isEmpty && liveOnly.devices.isEmpty,"S4 constructing a mock for Live never seeds projects, devices or chats")
        let mixedStore = ConversationStore();mixedStore.add(Conversation(id:"live",title:"Live"));mixedStore.conversation("live")!.isLiveConversation = true
        let mixed = MockReplay(store:mixedStore);mixed.start(live:false)
        check(mixedStore.conversations.map(\.id) == ["live"] && !mixed.inject(.complete,into:"live") && !mixed.step(),"S4 mixed stores reject mock seeding and mutations")

        let errorClock = S4ManualClock(), errorStore = ConversationStore(), errorReplay = MockReplay(store:errorStore,clock:errorClock)
        errorReplay.start(live:true);_ = await wait { await errorClock.requests.count == 1 }
        await errorClock.finishAll()
        check(await wait { !errorReplay.isPlaybackActive },"S4 throwing clock clears the active source instead of leaving a false-running UI")
        let releaseClock = S4ManualClock();weak var released: MockReplay?
        do {
            let temporary = MockReplay(store:ConversationStore(),clock:releaseClock);released = temporary;temporary.start(live:true)
            _ = await wait { await releaseClock.requests.count == 1 }
        }
        check(released == nil,"S4 the sleeping loop does not retain its replay owner")
        await releaseClock.finishAll()
    }
}
#endif
