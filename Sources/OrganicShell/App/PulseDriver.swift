import AppKit
import QuartzCore

/// InputRun owns posted input and recording. This driver only produces synthetic Core events and receipts.
@MainActor struct PulseDriver {
    let app: AppController
    let window: OrganicWindow
    let log: (String, [String: Any]) -> Void
    let sleep: (Double) async -> Void
    let hover: (CGPoint?) -> Void
    let click: (CGPoint) async -> Void
    let escape: () -> Void

    func run(_ spec: Set<String>) async {
        guard PulseDriverSequence.accepts(spec) else { return }
        // Check the runtime before inspecting any conversation or installing response observers.
        guard !app.o.usesLiveCore, !app.store.usesLiveCore,
              let runtime = app.runtime as? MockConversationRuntime,
              let replay = app.mock, runtime.store === app.store, runtime.replay === replay, replay.canPlay else {
            log("pulse-driver-refused", ["reason": "A mock-only runtime and store are required."]); return
        }
        guard window.shell.mode == .organic, window.scene.scheme.mode == .auto else {
            log("pulse-driver-refused", ["reason": "Use an Organic Auto window with full and brief columns."]); return
        }
        _ = replay.setPaused(true)
        let acceptedMouseMoves = window.window.acceptsMouseMovedEvents
        window.window.acceptsMouseMovedEvents = true
        defer { window.window.acceptsMouseMovedEvents = acceptedMouseMoves }
        let sequence = PulseDriverSequence(store: app.store, scene: window.scene, log: log, sleep: sleep,
                                          hover: hover, click: click, escape: escape)
        let restore = sequence.observeReplies(actions: window.actions, replay: replay)
        defer { restore(); _ = replay.setPaused(true) }
        await sequence.run(spec)
    }
}

/// Shared with the windowless harness: event shapes, ordering, clocks and probe sampling are identical.
@MainActor final class PulseDriverSequence {
    static let events = ["cmd", "step", "agent-up", "agent-down", "tests", "approval-unknown", "approval-inside",
                         "approval-outside", "question", "retry", "stopped", "done", "context-88", "context-90", "compacted"]
    static let interactions = ["hover", "priority", "reply", "live"]
    static let workspace = "/tmp/organic-pulse-driver/workspace"
    static func accepts(_ spec: Set<String>) -> Bool {
        spec.contains("p-pulse-all") || events.contains { event in ["full", "brief"].contains { spec.contains("p-pulse-\(event).\($0)") } }
            || interactions.contains { spec.contains("p-pulse-\($0)") }
    }
    static func hold(_ event: String) -> Double {
        switch event {
        case "approval-unknown", "approval-inside", "approval-outside", "question": 7
        case "retry", "stopped": 5
        case "cmd", "done", "live": 3
        case "agent-up": 2
        case "agent-down": 2.2
        case "reply": 1.8
        default: 2.4
        }
    }
    static func offsets(_ hold: Double) -> [Double] {
        Array(Set([0, 1 / 60, 0.06, 0.10, 0.17, 0.28, 0.6, hold - 0.05, hold, hold + 0.14, hold + 0.5, hold + 0.8])).sorted()
    }
    struct Target {
        let column: ColumnNode
        let variant: String
        var conversation: Conversation { column.conversation }
    }
    struct Arrival { let target: Target; let path: String; let event: String; let at: Double; let requestID: String? }
    struct Step { let at: Double; let order: Int; let work: @MainActor () async -> Void }
    let store: ConversationStore
    let scene: AutoScene
    let log: (String, [String: Any]) -> Void
    let sleep: (Double) async -> Void
    let hover: (CGPoint?) -> Void
    let click: (CGPoint) async -> Void
    let escape: () -> Void
    let now: () -> Double
    let wallTime: () -> Double
    private var serial = 0, stepSerial = 0, turnSerial = 0
    private var turns: [String: String] = [:], items: [String: String] = [:], children: [String: String] = [:]
    private var started = 0.0, deadline = Double.infinity
    private var sampleChecks=0
    private var submissions: [[String: Any]] = []
    private var responseAt: [String: Double] = [:]
    private var completed: [String] = []
    private(set) var findings = 0

    init(store: ConversationStore, scene: AutoScene, log: @escaping (String, [String: Any]) -> Void,
         sleep: @escaping (Double) async -> Void, hover: @escaping (CGPoint?) -> Void,
         click: @escaping (CGPoint) async -> Void, escape: @escaping () -> Void,
         now: @escaping () -> Double = { CACurrentMediaTime() }, wallTime: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store; self.scene = scene; self.log = log; self.sleep = sleep
        self.hover = hover; self.click = click; self.escape = escape; self.now = now; self.wallTime = wallTime
    }
    func observeReplies(actions: NormieActions, replay: MockReplay) -> () -> Void {
        let approval = actions.approvalValue, answer = actions.answer, observer = replay.onEvent
        actions.approvalValue = { [weak self] c, request, response in
            if let self, request.id.hasPrefix("pulse-driver-") {
                let fields: [String: Any] = ["target": c.id, "requestID": request.id, "response": Self.object(response), "mock": true]
                self.submissions.append(fields); self.log("pulse-driver-submit-approval", fields)
            }
            approval?(c, request, response)
        }
        actions.answer = { [weak self] c, request, answers in
            if let self, request.id.hasPrefix("pulse-driver-") {
                let fields: [String: Any] = ["target": c.id, "requestID": request.id, "answerIDs": answers.keys.sorted(), "answers": answers, "mock": true]
                self.submissions.append(fields); self.log("pulse-driver-submit-answer", fields)
            }
            answer?(c, request, answers)
        }
        replay.onEvent = { [weak self] event in
            if let self, let id = event.params["approvalId"]?.stringValue, id.hasPrefix("pulse-driver-") {
                self.responseAt[id] = self.now()
                self.log("pulse-driver-mock-response", ["requestID": id, "wireMethod": event.method, "eventID": event.id,
                                                        "target": event.params["threadId"]?.stringValue ?? "", "params": Self.object(event.params), "mock": true])
            }
            observer?(event)
        }
        return { actions.approvalValue = approval; actions.answer = answer; replay.onEvent = observer }
    }
    static func object(_ value: JSONValue) -> Any {
        guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }
    private func target(_ variant: String) -> Target? {
        guard let column = scene.columns.first(where: {
            !$0.conversation.isLiveConversation && !$0.conversation.archived &&
                (variant == "full" ? $0.islandVariant == .full : $0.islandVariant == .brief)
        }), column.island != nil else { return nil }
        return Target(column: column, variant: variant)
    }
    private func fields(_ target: Target, path: String) -> [String: Any] {
        ["path": path, "variant": target.variant, "target": target.conversation.id, "mock": true]
    }
    private func wire(_ method: String, _ params: JSONValue, target: Target, path: String, phase: String) {
        serial += 1
        var p = params.objectValue ?? [:]; p["threadId"] = .string(target.conversation.id)
        let event = CoreEvent(id: 11_330_000 + serial, time: wallTime(), method: method, params: .object(p))
        let before = now(); store.apply(event)
        var row = fields(target, path: path)
        row["phase"] = phase; row["wireMethod"] = method; row["eventID"] = event.id
        row["params"] = Self.object(event.params); row["applyMs"] = (now() - before) * 1000
        log("pulse-driver-wire", row)
    }
    private func snapshot(_ arrival: Arrival, offset: Double, phase: String = "sample") {
        var row = fields(arrival.target, path: arrival.path)
        row["eventName"] = arrival.event; row["phase"] = phase; row["requestedOffset"] = offset
        let actual=now(), planned=arrival.at+offset, elapsed=actual-arrival.at
        row["plannedAt"]=planned;row["actualAt"]=actual;row["elapsed"]=elapsed;row["drift"]=actual-planned
        let probe=arrival.target.column.island?.pulseProbe ?? [:]
        row["pulseProbe"] = probe
        if arrival.path == "p-pulse-\(arrival.event).\(arrival.target.variant)" {
            sampleChecks+=1
            let hold=Self.hold(arrival.event)
            let matches=Self.matchesActualTime(probe,event:arrival.event,elapsed:elapsed,hold:hold,compactHeight:arrival.target.variant == "brief" ? 27:32)
            row["expectedStateAtActual"]=elapsed<hold ? "event":"compact"
            row["stateMatchesActualTime"]=matches
            if !matches { check(false,"Sample matches actual time: \(arrival.path)",target:arrival.target,details:["plannedAt":planned,"actualAt":actual,"elapsed":elapsed,"hold":hold,"probe":probe]) }
        }
        row["probeAvailable"] = arrival.target.column.island?.pulseProbe != nil
        if let id = arrival.requestID { row["requestID"] = id }
        if let header = arrival.target.column.island { row["contentTexts"] = textLabels(header) }
        log("pulse-driver-probe", row)
    }
    private func check(_ value: Bool, _ message: String, target: Target? = nil, details:[String:Any] = [:]) {
        if !value { findings += 1 }
        var row: [String: Any] = ["passed": value, "check": message, "elapsed": now() - started]
        if let target { row["target"] = target.conversation.id; row["variant"] = target.variant }
        row.merge(details,uniquingKeysWith:{_,new in new})
        log("pulse-driver-check", row)
    }
    /// A late sample is judged against its actual clock. Missing probes and frozen actions always fail.
    static func matchesActualTime(_ probe:[String:Any],event:String,elapsed:Double,hold:Double,compactHeight:Double) -> Bool {
        let kinds=["cmd":"command","step":"step","agent-up":"spawn","agent-down":"finish","tests":"tests","approval-unknown":"approval","approval-inside":"approval","approval-outside":"approval","question":"question","retry":"retryingError","stopped":"stoppedError","done":"done","context-88":"context","context-90":"context","compacted":"compacted"]
        guard let mode=probe["mode"] as? String, let shown=probe["event"] as? String, let kind=kinds[event] else { return false }
        let current=shown == kind && mode == (["approval","question"].contains(kind) ? "action":"bloom")
        let compact=shown == "none" && mode == "compact" && (probe["remaining"] as? Double ?? 1)<0.001
        if elapsed<hold-1/60 { return current }
        if elapsed<=hold+1/60 { return current || compact }
        guard compact else { return false }
        if elapsed>=hold+0.8 {
            guard let rect=probe["rect"] as? [CGFloat],rect.count==4 else { return false }
            return abs(Double(rect[3])-compactHeight)<1
        }
        return true
    }
    private func step(_ at: Double, _ work: @escaping @MainActor () async -> Void) -> Step {
        stepSerial += 1; return Step(at: at, order: stepSerial, work: work)
    }
    private func perform(_ steps: [Step], origin: Double) async {
        for step in steps.sorted(by: { $0.at == $1.at ? $0.order < $1.order : $0.at < $1.at }) {
            guard !Task.isCancelled, now() < deadline else {
                check(false, "Driver budget/cancellation interrupted the sequence"); return
            }
            if origin + step.at > deadline { check(false, "Scheduled sample exceeds the driver budget"); return }
            let planned=origin+step.at
            while now()<planned-0.000001 && !Task.isCancelled { await sleep(max(0,planned-now())) }
            guard !Task.isCancelled else {check(false,"Driver cancelled before scheduled work");return}
            await step.work()
        }
    }
    private func samples(_ arrival: Arrival, hold: Double, origin: Double) -> [Step] {
        Self.offsets(hold).map { offset in step(arrival.at - origin + offset) { self.snapshot(arrival, offset: offset) } }
    }

    /// Flush only preparation metadata before Escape. Event arrivals retain the normal store-to-view delay.
    private func prepare(_ targets: [Target], event: String) async {
        hover(nil)
        for target in targets {
            let c = target.conversation, path = "p-pulse-\(event).\(target.variant)"
            for id in c.approvals.map(\.id) + [c.userInput?.id].compactMap({ $0 }) {
                wire("core/approvalExpired", ["approvalId": .string(id)], target: target, path: path, phase: "setup")
            }
            turnSerial += 1
            let turn = "pulse-driver-turn-\(turnSerial)-\(c.id)", item = "pulse-driver-item-\(turnSerial)-\(c.id)"
            turns[c.id] = turn; items[c.id] = item; children[c.id] = "pulse-driver-child-\(turnSerial)-\(c.id)"
            wire("thread/started", ["thread": ["id": .string(c.id), "cwd": .string(Self.workspace)]], target: target, path: path, phase: "setup")
            wire("turn/started", ["turn": ["id": .string(turn)]], target: target, path: path, phase: "setup")
            wire("core/fixtureState", ["satellites": [], "changes": [], "redEvents": 0], target: target, path: path, phase: "setup")
            wire("thread/tokenUsage/updated", tokens(100), target: target, path: path, phase: "setup")
            if event == "agent-down" { agent(target, done: false, path: path, phase: "setup") }
            if event == "compacted" { wire("thread/tokenUsage/updated", tokens(880), target: target, path: path, phase: "setup") }
            target.column.configureIsland(target.column.islandVariant, width: target.column.target.width)
        }
        // One posted Escape can be consumed by one island's outside monitor.
        for _ in 0...scene.columns.count { escape(); await sleep(0.015) }
        await sleep(0.85)
        for target in targets { check(target.column.island?.pulseProbe?["mode"] as? String == "compact", "Preparation settles to compact", target: target) }
    }
    private func tokens(_ used: Int) -> JSONValue { ["tokenUsage": ["last": ["totalTokens": .number(Double(used))], "modelContextWindow": 1000]] }
    private func agent(_ target: Target, done: Bool, path: String, phase: String) {
        let id = target.conversation.id, child = children[id]!
        wire(done ? "item/completed" : "item/started", ["turnId": .string(turns[id]!), "item": ["id": .string(items[id]!), "type": "collabAgentToolCall", "receiverThreadIds": [.string(child)], "agentsStates": .object([child: ["status": .string(done ? "completed" : "running")]]), "prompt": "Synthetic Pulse child"]], target: target, path: path, phase: phase)
    }
    @discardableResult private func emit(_ event: String, target: Target, path: String) -> Arrival {
        let id = target.conversation.id, turn = turns[id]!, item = items[id]!, at = now()
        var requestID: String?
        switch event {
        case "cmd", "live":
            wire("item/started", ["turnId": .string(turn), "item": ["id": .string(item), "type": "commandExecution", "command": "printf 'Pulse synthetic output'", "status": "inProgress"]], target: target, path: path, phase: "event")
        case "step":
            wire("item/completed", ["turnId": .string(turn), "item": ["id": .string(item), "type": "fileChange", "changes": [["path": "PulseFixture.swift", "diff": "-old fixture\n+new fixture"]]]], target: target, path: path, phase: "event")
        case "agent-up", "agent-down": agent(target, done: event == "agent-down", path: path, phase: "event")
        case "tests": wire("core/pulseProgress", ["completed": 3, "total": 7], target: target, path: path, phase: "event")
        case "approval-unknown", "approval-inside", "approval-outside":
            let request = "pulse-driver-approval-\(serial + 1)-\(id)"; requestID = request
            var params: [String: JSONValue] = ["itemId": .string(item), "command": "printf 'Pulse approval fixture'", "availableDecisions": ["accept", "decline"]]
            if event == "approval-inside" { params["permissions"] = ["fileSystem": ["write": [.string(Self.workspace + "/fixture.txt")]]] }
            if event == "approval-outside" { params["sandbox_permissions"] = "require_escalated" }
            wire("core/approvalRequested", ["approvalId": .string(request), "title": "Allow the synthetic fixture?", "request": ["method": "item/commandExecution/requestApproval", "params": .object(params)]], target: target, path: path, phase: "event")
        case "question":
            let request = "pulse-driver-question-\(serial + 1)-\(id)"; requestID = request
            wire("core/approvalRequested", ["approvalId": .string(request), "request": ["method": "item/tool/requestUserInput", "params": ["questions": [["id": "pulse-scope", "header": "Scope", "question": "Include the synthetic fixture?", "options": [["label": "Leave out", "description": "Omit the fixture."], ["label": "Include", "description": "Include the fixture."]]]]]]], target: target, path: path, phase: "event")
        case "retry": wire("error", ["turnId": .string(turn), "message": "Synthetic retryable error", "willRetry": true], target: target, path: path, phase: "event")
        case "stopped": wire("turn/completed", ["turn": ["id": .string(turn), "status": "failed", "error": ["message": "Synthetic work-stopping failure"]]], target: target, path: path, phase: "event")
        case "done": wire("turn/completed", ["turn": ["id": .string(turn), "status": "completed"]], target: target, path: path, phase: "event")
        case "context-88", "context-90": wire("thread/tokenUsage/updated", tokens(event == "context-88" ? 880 : 900), target: target, path: path, phase: "event")
        case "compacted": wire("thread/compacted", [:], target: target, path: path, phase: "event")
        default: check(false, "Unknown event \(event)", target: target)
        }
        var row = fields(target, path: path); row["eventName"] = event; row["arrivalAt"] = at
        if let requestID { row["requestID"] = requestID }
        log("pulse-driver-arrival", row)
        return Arrival(target: target, path: path, event: event, at: at, requestID: requestID)
    }
    func run(_ spec: Set<String>) async {
        started = now(); deadline = started + 175
        let all = spec.contains("p-pulse-all")
        log("pulse-driver-begin", ["spec": spec.sorted(), "all": all, "budgetSeconds": 175, "pairedVariants": all, "mock": true])
        for event in Self.events {
            let variants = ["full", "brief"].filter { all || spec.contains("p-pulse-\(event).\($0)") }
            guard !variants.isEmpty else { continue }
            let targets = variants.compactMap { variant -> Target? in
                let result = target(variant); check(result != nil, "Target \(variant) exists"); return result
            }
            guard !targets.isEmpty, now() < deadline else { continue }
            await prepare(targets, event: event)
            let origin = now(), arrivals = targets.map { emit(event, target: $0, path: "p-pulse-\(event).\($0.variant)") }
            await perform(arrivals.flatMap { samples($0, hold: Self.hold(event), origin: origin) }, origin: origin)
            if now() >= deadline { break }
            // Preserve the last sampled frame for at least one display interval before setup mutates the model.
            await sleep(0.06)
            for arrival in arrivals {
                let actual=now(),hold=Self.hold(event),probe=arrival.target.column.island?.pulseProbe ?? [:]
                let passed=actual-arrival.at>=hold+0.8 && Self.matchesActualTime(probe,event:event,elapsed:actual-arrival.at,hold:hold,compactHeight:arrival.target.variant == "brief" ? 27:32)
                check(passed,"Event retracts: \(arrival.path)",target:arrival.target,details:["plannedAt":arrival.at+hold+0.8,"actualAt":actual,"arrivalAt":arrival.at,"elapsed":actual-arrival.at,"hold":hold,"probe":probe])
                completed.append(arrival.path)
            }
        }
        for name in Self.interactions where all || spec.contains("p-pulse-\(name)") {
            guard let target = target("full"), now() < deadline else { check(false, "Interaction target/budget unavailable"); continue }
            switch name {
            case "hover": await runHover(target)
            case "priority": await runPriority(target)
            case "reply": await runReply(target)
            default: await runLive(target)
            }
            if now() < deadline { completed.append("p-pulse-\(name)") }
        }
        hover(nil)
        for _ in 0...scene.columns.count { escape(); await sleep(0.015) }
        await sleep(0.85)
        log("pulse-driver-end", ["duration": now() - started, "completed": completed, "findings": findings,
                                  "sampleChecks":sampleChecks,"underThreeMinutes": now() - started < 180, "mockPlaybackRemainsPaused": true])
    }
    private func capsulePoint(_ target: Target) -> CGPoint {
        let header = target.column.island!
        if let r = header.pulseProbe?["rect"] as? [CGFloat], r.count == 4 {
            return header.convert(CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2), to: scene.dock.view)
        }
        return header.convert(CGPoint(x: header.geometry.capsule.midX, y: header.geometry.capsule.midY), to: scene.dock.view)
    }
    private func runHover(_ target: Target) async {
        let path = "p-pulse-hover"
        await prepare([target], event: "cmd")
        let arrival = emit("cmd", target: target, path: path), origin = now()
        var steps = samples(arrival, hold: 3, origin: origin)
        steps.append(step(0.5) { self.hover(self.capsulePoint(target)); self.log("pulse-driver-hover-enter", self.fields(target, path: path)) })
        for t in [0.27, 0.29, 0.34, 0.45, 0.8, 3.5] { steps.append(step(0.5 + t) { self.snapshot(arrival, offset: 0.5 + t, phase: "hover-enter+\(t)") }) }
        steps.append(step(4.2) { self.hover(nil); self.log("pulse-driver-hover-leave", self.fields(target, path: path)) })
        for t in [0.10, 0.139, 0.15, 0.3, 0.6] { steps.append(step(4.2 + t) { self.snapshot(arrival, offset: 4.2 + t, phase: "hover-leave+\(t)") }) }
        steps.append(step(5.0) { self.hover(self.capsulePoint(target)) })
        steps.append(step(5.35) { self.hover(nil) }); steps.append(step(5.43) { self.hover(self.capsulePoint(target)) })
        steps.append(step(5.55) { self.snapshot(arrival, offset: 5.55, phase: "quick-reentry") })
        steps.append(step(5.8) { self.escape() }); steps.append(step(6.1) { self.hover(nil); self.snapshot(arrival, offset: 6.1, phase: "escape") })
        steps.append(step(6.3) { await self.click(self.capsulePoint(target)); self.log("pulse-driver-pin-click", self.fields(target, path: path)) })
        steps.append(step(6.9) { self.snapshot(arrival, offset: 6.9, phase: "pinned"); await self.click(CGPoint(x: target.column.target.midX, y: self.scene.size.height * 0.55)) })
        steps.append(step(7.7) { self.snapshot(arrival, offset: 7.7, phase: "outside-click") })
        await perform(steps, origin: origin)
    }
    private func runPriority(_ target: Target) async {
        let path = "p-pulse-priority"
        await prepare([target], event: "cmd")
        let origin = now()
        var arrivals: [String: Arrival] = ["first": emit("cmd", target: target, path: path)]
        var steps: [Step] = []
        for (key, event, at) in [("first", "cmd", 0.0), ("approval", "approval-unknown", 0.25), ("ordinary", "cmd", 0.5), ("failure", "stopped", 0.75)] {
            if at > 0 { steps.append(step(at) { arrivals[key] = self.emit(event, target: target, path: path) }) }
            for offset in Self.offsets(Self.hold(event)) {
                steps.append(step(at + offset) { if let arrival = arrivals[key] { self.snapshot(arrival, offset: offset, phase: "priority-" + key) } })
            }
        }
        steps.append(step(0.7) {
            if let arrival = arrivals["approval"] { self.snapshot(arrival, offset: self.now() - arrival.at, phase: "ordinary-blocked") }
            self.check(target.column.island?.pulseProbe?["event"] as? String == "approval", "Ordinary command cannot replace approval", target: target)
        })
        await perform(steps, origin: origin)
    }
    private func runLive(_ target: Target) async {
        let path = "p-pulse-live"
        await prepare([target], event: "live")
        let origin = now(), arrival = emit("live", target: target, path: path)
        var steps = samples(arrival, hold: 3, origin: origin)
        for (index, t) in [0.15, 0.3, 0.8, 1.05, 1.55, 2.0].enumerated() {
            steps.append(step(t) { self.wire("item/commandExecution/outputDelta", ["turnId": .string(self.turns[target.conversation.id]!), "itemId": .string(self.items[target.conversation.id]!), "delta": .string("\nSynthetic output \(index + 1)")], target: target, path: path, phase: "live-output") })
        }
        for t in [0.75, 0.81, 1.5, 2.25] { steps.append(step(t) { self.snapshot(arrival, offset: t, phase: "live-cadence") }) }
        await perform(steps, origin: origin)
    }
    private func textLabels(_ root: NSView) -> [String] {
        root.subviews.compactMap { view in
            guard let label = view as? IslandLabel, !label.isHiddenOrHasHiddenAncestor, label.alphaValue > 0 else { return nil }
            return label.stringValue
        } + root.subviews.flatMap { textLabels($0) }
    }
    private func buttons(_ root: NSView) -> [IslandButton] {
        root.subviews.flatMap { view in (view as? IslandButton).map { [$0] } ?? [] } + root.subviews.flatMap { buttons($0) }
    }
    private func runReply(_ target: Target) async {
        for (event, label) in [("approval-unknown", "Deny"), ("approval-unknown", "Allow"), ("question", "Leave out"), ("question", "Include")] {
            guard now() < deadline else { check(false, "Reply budget exhausted"); break }
            await prepare([target], event: event)
            let arrival = emit(event, target: target, path: "p-pulse-reply")
            await perform(samples(arrival, hold: Self.hold(event), origin: arrival.at).filter { $0.at <= 0.6 }, origin: arrival.at)
            guard let header = target.column.island, let button = buttons(header).first(where: { $0.text == label && $0.participates && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }) else {
                check(false, "Offered reply button missing: \(label)", target: target); continue
            }
            let rect = button.convert(button.bounds, to: scene.dock.view), point = CGPoint(x: rect.midX, y: rect.midY)
            var row = fields(target, path: "p-pulse-reply"); row["button"] = label; row["point"] = [point.x, point.y]
            row["buttonRect"] = [rect.minX, rect.minY, rect.width, rect.height]; row["requestID"] = arrival.requestID ?? ""
            row["answerIDs"] = event == "question" ? ["pulse-scope"] : []
            log("pulse-driver-click-offered", row)
            let count = submissions.count
            await click(point)
            check(submissions.count == count + 1, "Posted click submits one original request: \(label)", target: target)
            let id = arrival.requestID ?? "", response = Arrival(target: target, path: arrival.path, event: "reply", at: responseAt[id] ?? now(), requestID: id)
            check(responseAt[id] != nil, "Mock emitted approvalResponded", target: target)
            let lateRequestSamples = samples(arrival, hold: Self.hold(event), origin: arrival.at).filter { $0.at > 0.6 }
            await perform(lateRequestSamples + samples(response, hold: 1.8, origin: arrival.at), origin: arrival.at)
        }
    }
}

#if PULSE_DRIVER_SELFTEST
/// Uses native headers without constructing an OrganicWindow or entering the application run loop.
@main @MainActor enum PulseDriverVerification {
    static func main() async {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/organic-m1133b/driver-check")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = ConversationStore()
        // Construct the actual store-bound replay used by the response adapter.
        let boundReplay = MockReplay(store: store); boundReplay.start(live: false); _ = boundReplay.setPaused(true)
        let runtime = MockConversationRuntime(store: store, replay: boundReplay)
        let actions = NormieActions()
        actions.approvalValue = { runtime.respond($1, in: $0, response: $2) }
        actions.answer = { runtime.answer($1, in: $0, answers: $2) }
        let scene = AutoScene(size: CGSize(width: 1280, height: 820), store: store,
                              profile: .init(name: "Pulse driver offscreen", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0), scale: 1)
        scene.islandActions = actions; scene.verificationPresented = true; scene.manualSettle = true; scene.ambient = false
        let host = RootView(frame: CGRect(x: 0, y: 0, width: 1280, height: 820))
        for plane in [scene.sceneView, scene.nativePlane, scene.dockView, scene.overlayPlane, scene.peekNode.view] {
            plane.frame = host.bounds; host.addSubview(plane)
        }
        var time = VerificationClock.modelOrigin
        let began = time, epoch = Date().timeIntervalSince1970
        let delayed=ProcessInfo.processInfo.environment["PULSE_DRIVER_LATE"] == "1"
        var lastInputTime=time
        scene.now = { time }; scene.install(); scene.clock.invalidate(); scene.settle()
        for column in scene.columns { column.island?.now = { time }; column.island?.noticeWallTime = { epoch + time - began } }
        var records: [[String: Any]] = []
        let driver = PulseDriverSequence(store: store, scene: scene,
            log: { name, fields in var row = fields; row["name"] = name; row["time"] = time - began; records.append(row) },
            sleep: { requested in
                let seconds=requested+(delayed && requested>6 && requested<6.5 ? 0.42:0)
                let count = max(1, Int(ceil(seconds * 240))), dt = seconds / Double(max(1, Int(ceil(seconds * 240))))
                for _ in 0..<count {
                    time += dt
                    if delayed && time-lastInputTime>=8 { scene.setAmbientRunning(false) }
                    for column in scene.columns { column.island?.sampleMotion(at: time) }
                }
            }, hover: { point in
                lastInputTime=time;scene.setAmbientRunning(true)
                for column in scene.columns {
                    guard let header = column.island else { continue }
                    let local = point.map { header.convert($0, from: scene.dock.view) }
                    header.reconcilePointerHover(local)
                }
            }, click: { point in
                lastInputTime=time;scene.setAmbientRunning(true)
                for column in scene.columns {
                    guard let header = column.island else { continue }
                    let parentPoint = header.superview?.convert(point, from: scene.dock.view) ?? point
                    if let button = header.hitTest(parentPoint) as? IslandButton { button.performClick(nil); return }
                }
                for column in scene.columns { column.island?.outsideClick() }
            }, escape: { lastInputTime=time;scene.setAmbientRunning(true);for column in scene.columns { column.island?.escape() } },
            now: { time }, wallTime: { epoch + time - began })
        let restore = driver.observeReplies(actions: actions, replay: boundReplay)
        await driver.run(["p-pulse-all"])
        restore()
        var failures: [String] = [], checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append(label); print("FINDING", label) } }
        let expected: [String: (String, String)] = ["cmd": ("command", "none"), "step": ("step", "none"), "agent-up": ("spawn", "none"), "agent-down": ("finish", "none"), "tests": ("tests", "none"),
            "approval-unknown": ("approval", "card"), "approval-inside": ("approval", "card"), "approval-outside": ("approval", "column"), "question": ("question", "card"),
            "retry": ("retryingError", "none"), "stopped": ("stoppedError", "column"), "done": ("done", "card"), "context-88": ("context", "none"), "context-90": ("context", "column"), "compacted": ("compacted", "none")]
        for event in PulseDriverSequence.events { for variant in ["full", "brief"] {
            let path = "p-pulse-\(event).\(variant)"
            let samples = records.filter { $0["name"] as? String == "pulse-driver-probe" && $0["path"] as? String == path }
            check(samples.count == 12, "All requested offsets logged: " + path)
            let hold = samples.first { abs(($0["requestedOffset"] as? Double ?? -1) - 0.6) < 1e-6 }
            let probe = hold?["pulseProbe"] as? [String: Any]
            check(probe?["event"] as? String == expected[event]!.0 && probe?["halo"] as? String == expected[event]!.1, "Event/halo reaches native probe: " + path)
        }}
        let checksFromDriver = records.filter { $0["name"] as? String == "pulse-driver-check" }
        for row in checksFromDriver { check(row["passed"] as? Bool == true, row["check"] as? String ?? "Driver check") }
        let hover = records.filter { $0["path"] as? String == "p-pulse-hover" && $0["name"] as? String == "pulse-driver-probe" }
        for (phase, mode) in [("hover-enter+3.5", "expanded"), ("quick-reentry", "expanded"), ("escape", "compact"), ("outside-click", "compact")] {
            check(hover.contains { $0["phase"] as? String == phase && ($0["pulseProbe"] as? [String: Any])?["mode"] as? String == mode }, "Hover exit path: " + phase)
        }
        check(records.filter { $0["name"] as? String == "pulse-driver-submit-approval" }.count == 2, "Deny and Allow submit through mock runtime")
        check(records.filter { $0["name"] as? String == "pulse-driver-submit-answer" && $0["answerIDs"] as? [String] == ["pulse-scope"] }.count == 2, "Both question options preserve original answer ID")
        check(records.filter { $0["name"] as? String == "pulse-driver-mock-response" }.count == 4, "All posted-response substitutes receive real mock acknowledgement")
        let end = records.last { $0["name"] as? String == "pulse-driver-end" }
        check((end?["completed"] as? [String])?.count == 34, "All 34 paths complete")
        check(end?["underThreeMinutes"] as? Bool == true, "All paths fit three minutes on the virtual clock")
        let closed:[String:Any]=["mode":"compact","event":"none","remaining":0.0,"rect":[CGFloat(0),0,200,32]]
        let frozen:[String:Any]=["mode":"action","event":"approval","remaining":1.0,"rect":[CGFloat(0),0,292,86]]
        check(PulseDriverSequence.matchesActualTime(closed,event:"approval-unknown",elapsed:7.37,hold:7,compactHeight:32),"Late hold-.05 sample accepts already-retracted state at its actual clock")
        check(!PulseDriverSequence.matchesActualTime(frozen,event:"approval-unknown",elapsed:7.37,hold:7,compactHeight:32),"Late sample rejects an action incorrectly frozen beyond hold")
        check(!PulseDriverSequence.matchesActualTime([:],event:"approval-unknown",elapsed:7.9,hold:7,compactHeight:32),"Missing hidden probe cannot pass retraction")
        check(!PulseDriverSequence.matchesActualTime(closed,event:"approval-unknown",elapsed:6.5,hold:7,compactHeight:32),"Premature retraction cannot pass a pre-hold sample")
        var wrongHeight=closed;wrongHeight["rect"]=[CGFloat(0),0,292,86]
        check(!PulseDriverSequence.matchesActualTime(wrongHeight,event:"approval-unknown",elapsed:7.9,hold:7,compactHeight:32),"A compact label with unclosed geometry cannot pass settled retraction")
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "Driver verification displays no windows")
        let result: [String: Any] = ["checks": checks, "failures": failures, "virtualDuration": time - began, "records": records,
                                   "inputLimitation": "Hover uses header reconciliation; click uses native hitTest/performClick; Escape calls the public header action. Posted AppKit input requires Claude's real-window run."]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("driver.json")) }
        print("PULSE DRIVER \(checks) checks \(failures.count) findings, virtual seconds \(time - began)")
        scene.disposeTranscriptPresentation()
        withExtendedLifetime(host) {}
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
