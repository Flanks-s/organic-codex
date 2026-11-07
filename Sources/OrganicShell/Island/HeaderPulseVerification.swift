import AppKit
import QuartzCore

/// Windowless event-to-native-endpoint checks. Board traces are captured from the board's live JS object.
@MainActor enum HeaderPulseVerification {
    static func run(to path: String) -> Int32 {
        let out = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var checks = 0, failures: [String] = [], evidence: [[String: Any]] = []
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label); print("FINDING", label) }
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00001 }
        var state = HeaderPulseState()
        state.ingest(.init())
        let command = ConversationNotice(kind: .command, text: "Running fixture command")
        let approval = ConversationNotice(kind: .approval, text: "Allow fixture edit?", requestID: "a", buttons: [.init(title: "Review", action: .review)])
        check(state.receive(command) && state.mode == .bloom, "event opens bloom")
        state.tick(0.5); check(state.event != nil && near(state.remaining, 2.5), "event dwells for its board hold")
        state.receive(approval); check(state.mode == .action && state.event?.kind == .approval, "urgent request interrupts ordinary news")
        check(!state.receive(command) && state.event?.kind == .approval, "ordinary news cannot displace an urgent request")
        state.receive(.init(kind: .stoppedError, text: "Stopped"))
        check(state.event?.kind == .stoppedError, "urgent failure can replace the waiting request")
        state.dismiss(); state.receive(command); state.tick(2.9); state.hover(true); state.tick(0.279)
        check(!state.hovering && state.event != nil && state.remaining > 0.09, "hover dwell holds event immediately without early expansion")
        state.tick(0.002); check(state.hovering && state.mode == .expanded, "hover expands after 280 ms")
        state.tick(10); check(state.event != nil, "hover holds beyond the event deadline")
        state.hover(false); state.tick(0.139); check(state.hovering, "hover exit retains pose during 140 ms grace")
        state.tick(0.002); check(!state.hovering, "hover exit closes after grace")
        state.tick(3); check(state.mode == .compact && state.event == nil, "event retracts after remaining hold")
        state.receive(approval); state.togglePin(); state.tick(20)
        check(state.mode == .action && state.event != nil, "pin retains an unanswered action")
        state.dismiss(); check(state.mode == .compact, "Escape/outside dismissal closes Pulse")
        var restored=HeaderPulseState();restored.ingest(.init(pending:[approval]));restored.togglePin()
        check(restored.mode == .action && restored.actionEvent?.requestID == "a", "restored pending request reopens without replaying old news")
        var live=HeaderPulseState();live.ingest(.init())
        var liveNotice=ConversationNotice(id:1,kind:.command,text:"First output")
        live.ingest(.init(journal:[liveNotice]));liveNotice.text="Latest output";live.ingest(.init(journal:[liveNotice]));live.tick(0.74)
        check(live.event?.text == "First output", "live updates wait for the board's 750 ms cadence")
        live.tick(0.01);check(live.event?.text == "Latest output", "live updates show real latest output at the cadence")

        let table: [(ConversationNotice, NoticeHalo, String)] = [
            (command, .none, "ordinary progress"), (.init(kind: .step, text: "Edited fixture"), .none, "ordinary step"),
            (.init(kind: .done, text: "Done"), .card, "result"), (approval, .card, "unknown approval scope"),
            (.init(kind: .approval, text: "rm -rf /", request: ["params": ["command": "rm -rf /"]]), .card, "command text is not a risk classifier"),
            (.init(kind: .approval, text: "Read", request: ["params": ["permissions": ["fileSystem": ["write": ["/workspace/sub/file"]]]]], workspace: "/workspace"), .card, "explicit workspace write"),
            (.init(kind: .approval, text: "Escalation", request: ["params": ["sandbox_permissions": "require_escalated"]]), .column, "explicit elevation"),
            (.init(kind: .approval, text: "Network", request: ["params": ["permissions": ["network": ["enabled": true]]]]), .column, "explicit network permission"),
            (.init(kind: .approval, text: "Write", request: ["params": ["permissions": ["fileSystem": ["write": ["/workspace-other/file"]]]]], workspace: "/workspace"), .column, "explicit write outside workspace"),
            (.init(kind: .question, text: "Question"), .card, "structured question"),
            (.init(kind: .retryingError, text: "Retrying"), .none, "work continues after error"),
            (.init(kind: .stoppedError, text: "Stopped"), .column, "work-stopping failure"),
            (.init(kind: .context, text: "Unknown"), .none, "unknown context"),
            (.init(kind: .context, text: "89.9", context: 0.899), .none, "context below 90 percent"),
            (.init(kind: .context, text: "90", context: 0.9), .column, "context at 90 percent")
        ]
        for (notice, halo, label) in table {
            check(notice.halo == halo, "halo: " + label)
            evidence.append(["case": label, "halo": notice.halo.rawValue])
        }
        var swap = PulseTextSwap(); swap.put("Old"); swap.put("New"); swap.step(0.03)
        check(swap.text == "Old" && swap.opacity < 1, "live text blurs out before replacement")
        swap.step(0.031); check(swap.text == "New" && swap.opacity == 0, "live text swaps after 60 ms")
        swap.step(0.09); check(swap.opacity == 1, "live text returns over 90 ms")
        var reduced = HeaderPulseMotion(columnWidth: 507, compactWidth: 188, compactHeight: 32)
        reduced.retarget(.action, clock: false); reduced.receiveKick(rebloom: false); reduced.step(0, reduced: true)
        check(reduced.width.x == 292 && reduced.height.x == 86 && reduced.kick.x == 1 && !reduced.busy, "reduced motion settles geometry with no kick or blur")

        // One store and one event type are used for both real-shaped events and missing producer fixtures.
        for variant: HeaderIslandVariant in [.full, .brief] {
            for scale: CGFloat in [1, 2] {
                let c = Conversation(id: "pulse", title: "Pulse fixture")
                c.cwd = "/workspace"; c.isLiveConversation = true
                let store = ConversationStore(conversations: [c])
                let header = HeaderIsland()
                var time = VerificationRaster.epoch, serial = 0
                let began=time,epoch=VerificationRaster.date.timeIntervalSince1970
                header.now = { time }
                header.noticeWallTime = { epoch+time-began }
                func configure() {
                    var input = HeaderIslandConfiguration.conversation(c, variant: variant, columnWidth: variant == .full ? 507 : 317, band: 44, ambient: false, scale: scale)
                    input.notices = c.notices.snapshot(in: c)
                    header.configure(input)
                }
                func emit(_ method: String, _ value: JSONValue = [:]) {
                    serial += 1; var p = value.objectValue ?? [:]; p["threadId"] = "pulse"
                    store.apply(.init(id: serial, time: epoch+time-began, method: method, params: .object(p)))
                    configure()
                }
                func advance(_ seconds: Double) {
                    for _ in 0..<Int((seconds * 240).rounded()) { time += 1 / 240; header.sampleMotion(at: time) }
                }
                func capture(_ name: String) {
                    if let probe = header.pulseProbe { var row = probe; row["name"] = name; row["scale"] = scale; row["variant"] = variant == .full ? "full" : "brief"; evidence.append(row) }
                    let image=header.snapshot(scale:scale)
                    let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.setFillColor(NSColor(white:0.12,alpha:1).cgColor);context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
                    context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
                    Offscreen.write(context.makeImage()!, out.appendingPathComponent("\(variant == .full ? "full" : "brief")-\(Int(scale))x-\(name).png"))
                }
                configure()
                check(header.pulseProbe == nil, "mounting does not replay historical news")
                emit("turn/started", ["turn": ["id": "t"]]); advance(0.1); capture("command-open")
                advance(0.5); capture("command-hold")
                check(header.pulseProbe?["mode"] as? String == "bloom", "store lifecycle opens native Pulse")
                check(header.pulseProbe?["glassFilters"] as? Int == 0, "native glass never receives a blur filter")
                let request: JSONValue = ["method": "item/commandExecution/requestApproval", "params": ["command": "fixture command", "availableDecisions": ["accept", "decline"]]]
                emit("core/approvalRequested", ["approvalId": "approval", "request": request]); advance(0.6); capture("approval-hold")
                check(header.pulseProbe?["mode"] as? String == "action" && header.pulseProbe?["halo"] as? String == "card", "real-shaped approval enters native action/card halo")
                emit("item/started", ["turnId": "t", "item": ["id": "tool", "type": "commandExecution", "command": "ordinary"]])
                check(header.pulseProbe?["event"] as? String == "approval", "native endpoint retains urgent event against a command")
                var replies: [ConversationNoticeAction] = []
                header.actions.noticeAction = { replies.append($0) }
                let actionControls = descendants(header).compactMap { $0 as? IslandButton }.filter { $0.participates && $0.text == "Allow" }
                check(actionControls.count == 1, "native approval has one actionable offered Allow button")
                if let button = actionControls.first { button.invoke?(); button.invoke?() }
                check(replies == [.approval("approval", ["decision": "accept"])], "native response preserves request ID/JSON and rejects duplicate press")
                emit("core/approvalResponded", ["approvalId": "approval"]); advance(0.6); capture("approval-replied")
                check(header.pulseProbe?["event"] as? String == "reply" && c.approvals.isEmpty, "backend reply retires action and shows actual response")
                advance(2); capture("approval-retract")
                emit("core/approvalRequested", ["approvalId": "question", "request": ["method": "item/tool/requestUserInput", "params": ["questions": [["id": "scope", "question": "Include the fixture?", "options": [["label": "Leave out"], ["label": "Include"]]]]]]])
                advance(0.6); capture("question-hold")
                check(header.pulseProbe?["event"] as? String == "question" && header.pulseProbe?["halo"] as? String == "card", "structured question remains separate from permission approval")
                let answer=descendants(header).compactMap{$0 as? IslandButton}.first{$0.participates && $0.text == "Include"}
                answer?.invoke?()
                check(replies.last == .answer("question",["scope":["Include"]]), "question reply preserves original question ID and answer array")
                emit("core/approvalExpired", ["approvalId": "question"]); advance(2)
                emit("error", ["turnId": "t", "message": "Retry fixture", "willRetry": true]); advance(0.6); capture("retry-hold")
                check(header.pulseProbe?["halo"] as? String == "none", "retryable error has no whole-column halo")
                emit("turn/completed", ["turn": ["id": "t", "status": "failed", "error": ["message": "Fixture stopped"]]]); advance(0.6); capture("stopped-hold")
                check(header.pulseProbe?["halo"] as? String == "column", "failed terminal event has column halo")
                advance(5)
                emit("turn/started", ["turn": ["id": "t2"]])
                emit("thread/tokenUsage/updated", ["tokenUsage": ["last": ["totalTokens": 899], "modelContextWindow": 1000]])
                check(header.pulseProbe?["halo"] as? String == "none", "real context does not round 89.9 percent into a full halo")
                emit("thread/tokenUsage/updated", ["tokenUsage": ["last": ["totalTokens": 900], "modelContextWindow": 1000]]); advance(0.6); capture("context-hold")
                check(header.pulseProbe?["halo"] as? String == "column", "reported tokens/limit cross the actual 90-percent boundary")
                advance(3)
                emit("core/pulseProgress", ["completed": 3, "total": 7]); advance(0.6); capture("tests-hold")
                check(header.pulseProbe?["event"] as? String == "tests", "synthetic missing producer enters the same store/reducer/native path")
                header.hover(true, at: time); advance(0.3); capture("hover-open")
                check(header.pulseProbe?["mode"] as? String == "expanded", "native header hover uses Pulse dwell")
                advance(0.5);capture("hover-hold")
                header.hover(false, at: time); advance(0.1)
                check(header.pulseProbe?["mode"] as? String == "expanded", "native hover preserves exit grace")
                advance(0.1); capture("hover-exit")
                emit("turn/completed", ["turn": ["id": "t2", "status": "completed"]]); advance(0.6); capture("done-hold")
                check(c.completions == 0 && header.pulseProbe?["event"] as? String == "done", "visible completion uses terminal event, not unread count")
                advance(3); capture("done-retract")
                check(header.pulseProbe?["mode"] as? String == "compact", "native endpoint returns to compact")
                for (name,field,halo) in [("inside",JSONValue.object(["permissions":["fileSystem":["write":["/workspace/file"]]]]),"card"),
                                          ("outside",JSONValue.object(["sandbox_permissions":"require_escalated"]),"column")] {
                    var params=field.objectValue!;params["command"]="fixture command";params["availableDecisions"]=["accept","decline"]
                    emit("core/approvalRequested",["approvalId":.string(name),"request":["method":"item/commandExecution/requestApproval","params":.object(params)]])
                    advance(0.1);capture("approval-\(name)-open");advance(0.5);capture("approval-\(name)-hold")
                    check(header.pulseProbe?["halo"] as? String == halo,"native approval scope \(name) uses shared grade")
                    advance(7.2);capture("approval-\(name)-retract")
                    emit("core/approvalResponded",["approvalId":.string(name)]);advance(2.5)
                }
                c.satellites.append(.init(id:"child",face:"x"));store.changed(c);configure();advance(0.1);capture("spawn-open");advance(0.5);capture("spawn-hold")
                check(header.pulseProbe?["event"] as? String == "spawn","parent metadata publication delivers actual child start")
                advance(2.5);capture("spawn-retract")
                c.satellites[0].done=true;store.changed(c);configure();advance(0.1);capture("finish-open");advance(0.5);capture("finish-hold")
                check(header.pulseProbe?["event"] as? String == "finish","parent metadata publication delivers actual child completion")
                advance(2.7);capture("finish-retract")
                header.beginMotion(); check(header.pulseProbe == nil, "column handoff suspends Pulse without changing its existing flight")
                header.endMotion()
                header.isHidden=true;check(header.pulseProbe == nil,"hidden header suspends Pulse")
                header.isHidden=false;check(header.pulseProbe != nil,"unhiding resumes the retained Pulse endpoint")
                header.dispose()
            }
        }
        HeaderPulseRevisionVerification.run(check: check, evidence: &evidence)
        HeaderPulseThirdVerification.run(check:check,evidence:&evidence)
        HeaderPulseFourthVerification.run(check:check,evidence:&evidence)
        boardChecks(check: check, evidence: &evidence)
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "verification opens no visible windows")
        let report: [String: Any] = ["checks": checks, "failures": failures, "evidence": evidence]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("pulse.json")) }
        print("HEADER PULSE \(checks) checks \(failures.count) findings")
        return failures.isEmpty ? 0 : 1
    }

    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private static func boardChecks(check: (Bool, String) -> Void, evidence: inout [[String: Any]]) {
        guard let path = ProcessInfo.processInfo.environment["PULSE_BOARD_TRACE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let traces = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            check(false, "board trace is supplied from headless IslandPulse at the same frame times"); return
        }
        let kinds: [String: ConversationNotice.Kind] = ["cmd": .command, "step": .step, "agentUp": .spawn, "agentDown": .finish, "tests": .tests,
                                                       "appr": .approval, "q": .question, "err": .retryingError, "done": .done, "ctx": .context]
        let modes = ["cmp": "compact", "blm": "bloom", "act": "action", "exp": "expanded"]
        for trace in traces {
            guard let key = trace["key"] as? String, let kind = kinds[key], let initial = trace["initial"] as? [String: Any],
                  let column = initial["column"] as? Double, let compact = initial["compact"] as? Double, let height = initial["height"] as? Double,
                  let clock = initial["clock"] as? Bool, let frames = trace["frames"] as? [[String: Any]] else { check(false, "board trace schema"); continue }
            var state = HeaderPulseState(), motion = HeaderPulseMotion(columnWidth: column, compactWidth: compact, compactHeight: height, clock: clock)
            var notice = ConversationNotice(kind: kind, text: key)
            if kind == .approval || kind == .question { notice.buttons = [.init(title: "Review", action: .review)] }
            state.receive(notice); motion.receiveKick(rebloom: false)
            var error = 0.0, opacityError = 0.0, modeErrors = 0, count = 0
            for frame in frames {
                guard let t = frame["t"] as? Double, t <= notice.hold + 0.8 else { break }
                state.tick(1 / 240)
                let hasClock = key == "tests" || key == "ctx" ? false : key == "done" ? true : clock
                motion.retarget(state.mode, clock: hasClock); motion.step(1 / 240)
                let values = ["w": motion.width.x, "h": motion.height.x, "r": motion.radius.x, "kick": motion.kick.x]
                for (field, actual) in values { error = max(error, abs(actual - (frame[field] as? Double ?? .infinity))) }
                if let mode = frame["mode"] as? String, modes[mode] != state.mode.rawValue { modeErrors += 1 }
                opacityError = max(opacityError, abs((motion.layers[state.mode]?.k ?? 0) - (frame["alpha"] as? Double ?? .infinity)))
                count += 1
            }
            check(error < 0.00001, "board frame geometry/kick " + key + " max error \(error)")
            check(opacityError < 0.00001 && modeErrors == 0, "board frame timing/content " + key + " mode errors \(modeErrors) alpha error \(opacityError)")
            evidence.append(["board": key, "frames": count, "maxGeometryError": error, "maxAlphaError": opacityError, "modeErrors": modeErrors])
        }
    }
}

#if HEADER_PULSE_SELFTEST
@main @MainActor enum HeaderPulseVerificationMain {
    static func main() { exit(HeaderPulseVerification.run(to: CommandLine.arguments.dropFirst().first ?? "/tmp/organic-pulse-check")) }
}
#endif
