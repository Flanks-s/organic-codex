import Foundation

/// Synthetic Core events, with a virtual clock shared by live playback and offscreen checks.
@MainActor final class MockReplay {
    struct Script { let id: String; let title: String; let goal: String; let command: String; let output: String; let reply: String }
    static var scripts: [Script] {
        MockSeed.make().map { c in
            Script(id: c.id, title: c.title, goal: c.goal,
                   command: c.items.first { $0.kind == .command }?.text ?? "",
                   output: "", reply: c.items.last { $0.kind == .assistant }?.text ?? "")
        }
    }
    static let tickInterval = 0.25
    static let charactersPerTick = 16
    private enum Step { case think(String), command(String, String), write(String), finish }
    private struct Run {
        var turnID: String
        var steps: [Step]
        var index = 0
        var current: String?
        var written = 0
        var wait = 0
        var endless = false
        var blocked: String?
    }
    private let store: ConversationStore
    private let seeds: [Conversation]
    private let epoch: TimeInterval
    private var nextEvent = 1, serial = 0
    private var ticks = 0, injectionSerial = 0
    private var elapsed: TimeInterval = 0, backgroundElapsed: TimeInterval = 0
    private var started = false
    private var loop: Task<Void, Never>?
    private let clock: any CoreRuntimeClock
    private var advancing = false
    private(set) var playbackSettings = MockPlaybackSettings()
    private(set) var isPlaybackActive = false
    private(set) var playbackGeneration: UInt64 = 0
    private(set) var backgroundEvents = true
    var totalTicks: Int { ticks }
    #if DEBUG_SELFTEST
    var verificationArrivalIDs = false
    #endif
    func isBound(to candidate: ConversationStore) -> Bool { candidate === store }
    var canPlay: Bool { !store.usesLiveCore && !store.conversations.contains(where: { $0.isLiveConversation }) }
    private var runs: [String: Run] = [:]
    private(set) var emitted = 0
    var onEvent: ((CoreEvent) -> Void)?

    init(store: ConversationStore, includeSidebarHistory: Bool = false, clock: any CoreRuntimeClock = CoreSystemClock()) {
        self.store = store; self.clock = clock
        let now = Date(); epoch = now.timeIntervalSince1970; seeds = includeSidebarHistory ? MockSeed.library(now: now) : MockSeed.make(now: now)
        guard canPlay else { return }
        if store.projects.isEmpty { store.updateProjects(MockSeed.projects) }
        if store.devices.isEmpty { store.updateDevices(MockSeed.devices) }
        for seed in seeds {
            let conversation = Conversation(id: seed.id, title: seed.title)
            conversation.archivedAt = seed.archivedAt
            store.add(conversation)
        }
    }
    deinit { loop?.cancel() }

    func start(live: Bool) {
        guard canPlay else { stopPlayback(); return }
        if !started {
            started = true
            for c in seeds { seed(c) }
            runs["A"] = Run(turnID: "A-t1", steps: Self.cycle, endless: true)
            runs["B"] = Run(turnID: "B-t1", steps: [.command("Scripts/lint-copy.sh native/Approval*.strings", "Checked 214 strings in 9 files.\nNo issues found."),
                .write("No issues found in the approval strings.\n\nNothing was changed; the run only read the project."), .finish], current: "B-3", blocked: "B-ap1")
            runs["D"] = Run(turnID: "D-t1", steps: [.think("The last step failed. Retrying with a smaller batch and the cached inputs."),
                .command("render --batch scenes/*.json --no-texture-reload", "Rendered 240 frames in 3m 12s (was 6m 40s)."),
                .write("Caching the textures across frames cut the batch time roughly in half."), .finish], endless: true)
        }
        guard live, !isPlaybackActive else { return }
        isPlaybackActive = true
        playbackGeneration &+= 1
        let generation = playbackGeneration, clock = clock
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval(for: generation) else { return }
                do { try await clock.sleep(seconds: interval) }
                catch { self?.finished(generation); return }
                guard !Task.isCancelled, let replay = self, replay.playbackGeneration == generation, replay.isPlaybackActive else { return }
                guard replay.canPlay else { replay.stopPlayback(); return }
                replay.advanceOneTick(elapsed: interval)
            }
        }
    }
    func stopPlayback() {
        playbackGeneration &+= 1
        isPlaybackActive = false; loop?.cancel(); loop = nil
    }
    private func interval(for generation: UInt64) -> TimeInterval? {
        guard generation == playbackGeneration, isPlaybackActive else { return nil }
        guard canPlay else { stopPlayback(); return nil }
        return playbackSettings.tickInterval
    }
    private func finished(_ generation: UInt64) {
        guard generation == playbackGeneration else { return }
        stopPlayback()
    }
    @discardableResult func setPaused(_ paused: Bool) -> Bool {
        guard canPlay else { stopPlayback(); return false }
        if paused { stopPlayback() } else { start(live: true) }
        return true
    }
    @discardableResult func step() -> Bool {
        guard canPlay, !isPlaybackActive, !advancing else { return false }
        start(live: false); advanceOneTick(elapsed: playbackSettings.tickInterval); return true
    }
    @discardableResult func updatePlaybackSettings(_ settings: MockPlaybackSettings) -> Bool {
        guard canPlay else { stopPlayback(); return false }
        let next = settings.normalized, reschedule = isPlaybackActive && next.tickInterval != playbackSettings.tickInterval
        playbackSettings = next
        if reschedule { stopPlayback(); start(live: true) }
        return true
    }
    @discardableResult func setBackgroundEvents(_ enabled: Bool) -> Bool {
        guard canPlay else { stopPlayback(); return false }
        backgroundEvents = enabled; return true
    }

    /// Existing deterministic callers remain supported. A playing source rejects a second manual driver.
    func advance(ticks count: Int = 1) {
        guard started, canPlay, !isPlaybackActive, !advancing, count > 0 else { return }
        for _ in 0..<count {
            guard canPlay, !isPlaybackActive else { break }
            advanceOneTick(elapsed: playbackSettings.tickInterval)
        }
    }
    private func advanceOneTick(elapsed interval: TimeInterval) {
        guard started, canPlay, !advancing else { return }
        advancing = true; defer { advancing = false }
        ticks += 1
        elapsed += interval
        for c in store.conversations {
            guard canPlay else { stopPlayback(); return }
            guard c.running, !store.isOffline(c) else { continue }
            guard var run = runs[c.id], run.blocked == nil, run.index < run.steps.count else { continue }
            if run.wait > 0 { run.wait -= 1; runs[c.id] = run; continue }
            let step = run.steps[run.index]
            switch step {
            case .think(let text), .write(let text):
                let type = if case .think = step { "reasoning" } else { "agentMessage" }
                if run.current == nil {
                    run.current = newID(c.id)
                    emit("item/started", thread: c.id, ["turnId": .string(run.turnID), "item": ["id": .string(run.current!), "type": .string(type), "text": ""]])
                }
                let chars = Array(text), end = min(chars.count, run.written + playbackSettings.charactersPerTick)
                emit(type == "reasoning" ? "item/reasoning/textDelta" : "item/agentMessage/delta", thread: c.id,
                     ["turnId": .string(run.turnID), "itemId": .string(run.current!), "delta": .string(String(chars[run.written..<end]))])
                run.written = end
                if end == chars.count {
                    emit("item/completed", thread: c.id, ["turnId": .string(run.turnID), "item": ["id": .string(run.current!), "type": .string(type), "text": .string(text)]])
                    run.current = nil; run.written = 0; run.index += 1
                }
            case .command(let command, let output):
                if run.current == nil {
                    run.current = newID(c.id); run.wait = 3
                    emit("item/started", thread: c.id, ["turnId": .string(run.turnID), "item": ["id": .string(run.current!), "type": "commandExecution", "command": .string(command)]])
                } else {
                    emit("item/completed", thread: c.id, ["turnId": .string(run.turnID), "item": ["id": .string(run.current!), "type": "commandExecution", "command": .string(command), "aggregatedOutput": .string(output)]])
                    run.current = nil; run.index += 1
                }
            case .finish:
                if run.endless { run.index = 0; run.wait = 4 }
                else {
                    emit("turn/completed", thread: c.id, ["turn": ["id": .string(run.turnID), "status": "completed"]])
                    run.index = run.steps.count
                }
            }
            if c.running { runs[c.id] = run } else { runs[c.id] = nil }
        }
        backgroundElapsed += interval
        if backgroundEvents, backgroundElapsed >= playbackSettings.backgroundEventInterval {
            backgroundElapsed = 0
            if let c = store.conversations.first(where: { $0.running && !store.isOffline($0) }) {
                _ = inject(c.satellites.contains(where: { !$0.done }) ? .satelliteDone : .addSatellite, into: c.id)
            }
        }
    }

    @discardableResult func send(_ c: Conversation, text: String, followUp: FollowUp = .steer) -> Bool {
        guard canPlay, !c.isLiveConversation, store.conversation(c.id) === c, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !c.sending, !store.isOffline(c) else { return false }
        if c.running && followUp == .queue {
            c.queued.append(.init(id: newID(c.id), text: text, attachments: c.attachments, settings: c.next, access: c.access, waitingForTurnID: c.activeTurnID))
            c.draft = ""; c.attachments = []; store.changed(c); return true
        }
        let turn = c.running ? c.activeTurnID ?? newID(c.id) : newID(c.id)
        if !c.running { emit("turn/started", thread: c.id, ["turn": ["id": .string(turn)]]) }
        emit("item/completed", thread: c.id, ["turnId": .string(turn), "item": ["id": .string(newID(c.id)), "type": "userMessage", "text": .string(text)]])
        c.question = nil; c.userInput = nil; c.error = nil; c.draft = ""; c.attachments = []; c.settings = c.next
        runs[c.id] = Run(turnID: turn, steps: [.think("Reading the question and the earlier turns."), .write("Here’s how I’d go about “\(text.prefix(70))”:\n\n1. Read what the code does today.\n2. Make the smallest change that solves it.\n3. Check the result."), .finish])
        store.changed(c); return true
    }
    func stop(_ c: Conversation) {
        guard canPlay, !c.isLiveConversation, store.conversation(c.id) === c, c.running else { return }
        runs[c.id] = nil
        emit("turn/completed", thread: c.id, ["turn": ["id": .string(c.activeTurnID ?? ""), "status": "interrupted"]])
    }
    func respond(_ approval: Approval, in c: Conversation, action: ApprovalAction) {
        guard canPlay, !c.isLiveConversation, store.conversation(c.id) === c, c.approvals.contains(where: { $0.id == approval.id }) else { return }
        let status: JSONValue = action == .accept ? "running" : action == .decline ? "declined" : "cancelled"
        emit("core/approvalResponded", thread: c.id, ["approvalId": .string(approval.id), "itemId": .string(approval.toolItemID), "status": status])
        if var run = runs[c.id], run.blocked == approval.id {
            run.blocked = nil; run.wait = 3
            if action != .accept { run.current = nil; run.steps = [.write("Okay, I didn’t run it."), .finish]; run.index = 0 }
            runs[c.id] = run
        }
        if action == .cancel { stop(c) }
    }
    func answer(_ request: UserInputRequest, in c: Conversation, answers: [String: [String]]) {
        guard canPlay, !c.isLiveConversation, store.conversation(c.id) === c else { return }
        let fixture = c.userInput == nil && c.question != nil && request.id == "fixture-question:" + c.id
            && request.questions.count == 1 && request.questions[0].prompt == c.question
        guard c.userInput?.id == request.id || fixture else { return }
        emit("core/approvalResponded", thread: c.id, ["approvalId": .string(request.id)])
        _ = send(c, text: answers.keys.sorted().compactMap { answers[$0]?.joined(separator: ", ") }.joined(separator: "\n"))
    }
    func revert(_ card: TranscriptItem, in c: Conversation) {
        guard canPlay, !c.isLiveConversation, store.conversation(c.id) === c, TranscriptPresentation.isChangesCard(card), let i = c.items.firstIndex(where: { $0.id == card.id }) else { return }
        let paths = Set(card.text.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
        c.changes.removeAll { paths.contains($0.path) }
        c.items[i].status = TranscriptPresentation.changesReverted; c.items[i].revision += 1; store.changed(c)
    }

    @discardableResult func inject(_ event:MockInjection,into id:String?=nil)->Bool {
        guard canPlay, let id, let c=store.conversation(id), !c.isLiveConversation else{return false}
        injectionSerial+=1
        let itemID="debug-\(injectionSerial)-\(UUID().uuidString)",turn=c.activeTurnID ?? "debug-turn-\(injectionSerial)"
        func emit(_ method:String,_ fields:[String:JSONValue]){var p=fields;p["turnId"] = .string(turn);self.emit(method,thread:c.id,p)}
        func settle(){stop(c);for approval in c.approvals{respond(approval,in:c,action:.cancel)};c.approvals=[];c.question=nil;c.userInput=nil;c.sending=false;c.stopping=false}
        switch event {
        case .approval:
            guard c.approvals.isEmpty else{return false}
            emit("turn/started",["turn":["id":.string(turn)]])
            emit("item/started",["item":["id":.string(itemID),"type":"commandExecution","command":"swift test --filter LayoutTests","status":"waiting"]])
            emit("core/approvalRequested",["approvalId":.string(itemID+"-approval"),"title":"Run this command?","acceptLabel":"Run","request":["id":.string(itemID),"method":"item/commandExecution/requestApproval","params":["command":"swift test --filter LayoutTests","reason":"Demo injection · read-only checks","itemId":.string(itemID)]]])
            runs[c.id] = Run(turnID:turn, steps:[.command("swift test --filter LayoutTests", "Demo checks passed."), .write("The demo command completed."), .finish], current:itemID, blocked:itemID+"-approval")
        case .question:
            settle()
            emit("core/approvalRequested",["approvalId":.string(itemID),"request":["id":.string(itemID),"method":"item/tool/requestUserInput","params":["questions":[["id":"direction","header":"Direction","question":"Which direction should I take?","options":[["label":"Small change","description":"Keep the existing design."],["label":"Broader pass","description":"Update the surrounding code too."]]]]]]])
        case .errorRunning:
            if !c.running{emit("turn/started",["turn":["id":.string(turn)]])}
            emit("error",["willRetry":true,"error":["message":"Demo: temporary tool failure; retrying."]])
        case .errorStopped:
            settle();emit("error",["willRetry":false,"error":["message":"Demo: the run stopped after a tool failure."]])
        case .complete:
            settle();emit("item/completed",["item":["id":.string(itemID),"type":"agentMessage","text":"Demo work completed. The checks passed."]]);c.error=nil;c.completions+=1;c.unread=true
            for i in c.satellites.indices{c.satellites[i].done=true;c.satellites[i].face="-_-";c.satellites[i].finishedOrder=injectionSerial+i};c.satellitesRetired=true
        case .compaction:
            let before=c.contextPercent;emit("thread/compacted",[:]);c.contextUsed=max(0.06,c.contextUsed*0.3)
            emit("item/completed",["item":["id":.string(itemID),"type":"notice","noticeKind":"info","text":.string("Context compacted · \(before)% → \(c.contextPercent)% of the context window")]])
        case .addSatellite:
            if c.satellitesRetired{c.satellites=[]};c.satellitesRetired=false;c.satellites.append(Satellite(id:itemID,face:"•ᴗ•",threadID:itemID,title:"Demo sub-agent"))
        case .satelliteDone:
            guard let i=c.satellites.firstIndex(where:{!$0.done})else{return false};c.satellites[i].done=true;c.satellites[i].face="-_-";c.satellites[i].finishedOrder=injectionSerial
        case .contextUp:c.contextUsed=min(1,c.contextUsed+0.15)
        }
        if ![.compaction,.addSatellite,.satelliteDone].contains(event){c.updated=Date()}
        store.changed(c);return true
    }
    @discardableResult func arrive() -> Conversation? {
        guard canPlay else { return nil }
        injectionSerial += 1
        #if DEBUG_SELFTEST
        let identity = verificationArrivalIDs ? "fixture-\(injectionSerial)" : UUID().uuidString
        #else
        let identity = UUID().uuidString
        #endif
        let c = Conversation(id:"debug-arrival-\(identity)",title:"New conversation")
        c.identityIndex = store.nextIdentity(); store.add(c); return c
    }

    private static let cycle: [Step] = [
        .think("The sidebar row height comes from the system list. Custom insets only fight it; removing them should be enough."),
        .command("swift test --filter LayoutTests", "Executed 7 tests, with 0 failures."),
        .write("Removed the custom row insets in `SidebarView.swift`. Rows take the system height again, and the list scrolls under the profile capsule as designed.\n\n- `swift build` passes\n- `swift test --filter LayoutTests`: 7 passed"), .finish,
    ]
    private func newID(_ prefix: String) -> String { serial += 1; return "\(prefix)-mock-\(serial)" }
    private func emit(_ method: String, thread: String, _ fields: [String: JSONValue], at time: TimeInterval? = nil) {
        var p = fields; p["threadId"] = .string(thread)
        let e = CoreEvent(id: nextEvent, time: time ?? epoch + elapsed, method: method, params: .object(p))
        nextEvent += 1; emitted += 1; store.apply(e); onEvent?(e)
    }
    private func seed(_ c: Conversation) {
        emit("thread/started", thread: c.id, ["thread": ["id": .string(c.id), "name": .string(c.title), "branch": .string(c.branch),
            "archived": .bool(c.archived), "updatedAt": .number(c.updated.timeIntervalSince1970), "pinned": .bool(c.pinned), "projectId": c.projectID.map(JSONValue.string) ?? .null, "deviceId": .string(c.deviceID), "turns": []]])
        for item in c.items {
            var value: [String: JSONValue] = ["id": .string(item.id), "text": .string(item.text)]
            switch item.rowKind {
            case .user: value["type"] = "userMessage"
            case .assistant: value["type"] = "agentMessage"
            case .reasoning: value["type"] = "reasoning"
            case .tool(.command): value["type"] = "commandExecution"; value["command"] = .string(item.text)
            case .tool(.fileChange): value["type"] = "fileChange"
            case .tool(.webSearch): value["type"] = "webSearch"
            case .tool: value["type"] = "mcpToolCall"; value["tool"] = .string(item.text)
            case .notice(let notice): value["type"] = "notice"; value["noticeKind"] = notice == .error ? "error" : notice == .warning ? "warning" : "info"
            }
            if let status = item.status { value["status"] = .string(status) }
            emit("item/completed", thread: c.id, ["turnId": .string(item.turnID), "item": .object(value)])
        }
        if c.running { emit("turn/started", thread: c.id, ["turn": ["id": .string(c.activeTurnID ?? "")]], at: c.updated.timeIntervalSince1970) }
        emit("thread/tokenUsage/updated", thread: c.id, ["tokenUsage": ["last": ["totalTokens": .number(Double(Int((c.contextUsed * 272_000).rounded())))], "modelContextWindow": 272_000]])
        emit("turn/plan/updated", thread: c.id, ["turnId": .string(c.items.last?.turnID ?? ""), "plan": .array(c.plan.map { ["step": .string($0.title), "status": $0.done ? "completed" : "pending"] })])
        for approval in c.approvals {
            emit("core/approvalRequested", thread: c.id, ["approvalId": .string(approval.id), "title": .string(approval.title), "acceptLabel": .string(approval.acceptLabel), "request": ["method": "item/commandExecution/requestApproval", "params": ["command": .string(approval.command), "reason": .string(approval.note), "itemId": .string(approval.toolItemID)]]])
        }
        emit("core/fixtureState", thread: c.id, ["identityIndex": .number(Double(c.identityIndex)), "redEvents": .number(Double(c.redEvents)), "question": c.question.map(JSONValue.string) ?? .null,
            "error": c.error == .running ? "running" : c.error == .stopped ? "stopped" : .null,
            "changes": .array(c.changes.map { file in ["path": .string(file.path), "added": .number(Double(file.added)), "removed": .number(Double(file.removed)),
                "lines": .array(file.lines.map { line in ["kind": line.kind == .added ? "added" : line.kind == .removed ? "removed" : "context", "text": .string(line.text)] })] }),
            "satellites": .array(c.satellites.map { ["id": .string($0.id), "face": .string($0.face), "done": .bool($0.done)] })])
    }
}
