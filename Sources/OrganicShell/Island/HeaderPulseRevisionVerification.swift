import AppKit
import QuartzCore

/// Regression inputs deliberately exercise publications that contain more than one semantic event.
@MainActor enum HeaderPulseRevisionVerification {
    static func run(check: (Bool, String) -> Void, evidence: inout [[String: Any]]) {
        let boardData=ProcessInfo.processInfo.environment["PULSE_REVISION_BOARD"].flatMap { try? Data(contentsOf:URL(fileURLWithPath:$0)) }
        let board=boardData.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        let boardGeometry=board?["geometry"] as? [[String:Any]] ?? []
        check(boardGeometry.count == 4,"R8 headless board supplies full/brief command/action widths")
        func boardWidth(_ variant:HeaderIslandVariant,_ event:String) -> Double {
            boardGeometry.first { $0["variant"] as? String == (variant == .full ? "full":"brief") && $0["event"] as? String == event }?["w"] as? Double ?? -1000
        }
        let approval: JSONValue = ["method":"item/commandExecution/requestApproval","params":["command":"Synthetic","availableDecisions":["accept","decline"]]]
        let question: JSONValue = ["method":"item/tool/requestUserInput","params":["questions":[["id":"q","question":"Synthetic question?","options":[["label":"No"],["label":"Yes"]]]]]]
        for request in [approval,question] { for ending in ["core/approvalResponded","core/approvalExpired"] {
            let c=Conversation(id:"batch",title:"Batch"), store=ConversationStore()
            store.add(c)
            var state=HeaderPulseState(); state.ingest(c.notices.snapshot(in:c))
            store.apply(.init(id:1,time:nil,method:"core/approvalRequested",params:["threadId":"batch","approvalId":"a","request":request]))
            store.apply(.init(id:2,time:nil,method:ending,params:["threadId":"batch","approvalId":"a"]))
            state.ingest(c.notices.snapshot(in:c))
            check(state.event?.kind == .reply && state.actionEvent == nil,"R1 batched request retired: \(request["method"]?.stringValue ?? "") \(ending)")
        }}
        do {
            let c=Conversation(id:"restore",title:"Restore"), store=ConversationStore()
            store.add(c)
            store.apply(.init(id:1,time:10,method:"turn/started",params:["threadId":"restore","turn":["id":"A"]]))
            let replay=HistoryReplay(conversation:c,cursor:1,seeded:true)
            let snapshot: JSONValue=["turns":[["id":"B","status":"inProgress","startedAt":20,"items":[]]]]
            EventReducer.hydrate(snapshot,into:c); replay.merge(into:c,snapshot:snapshot)
            let count=c.notices.journal.count
            store.apply(.init(id:2,time:21,method:"item/started",params:["threadId":"restore","turnId":"B","item":["id":"cmd","type":"commandExecution","command":"Synthetic B"]]))
            let restored=c.notices.snapshot(in:c)
            check(c.notices.journal.count == count+1 && c.notices.journal.last?.text.contains("Synthetic B") == true,"R2 restored active turn accepts subsequent real-shaped notices")
            check(restored.turnID == "B" && restored.startedAt == 20,"R2 restored lifecycle clock belongs to B")
        }
        do {
            let c=Conversation(id:"history",title:"History"), store=ConversationStore()
            store.add(c); store.apply(.init(id:1,time:nil,method:"turn/started",params:["threadId":"history","turn":["id":"A"]]))
            let count=c.notices.journal.count
            func history(_ done: Bool) -> JSONValue {
                ["turns":[["id":"A","status":"inProgress","items":[["id":"tool","type":"collabAgentToolCall","receiverThreadIds":["child"],"agentsStates":["child":["status":.string(done ? "completed":"running")]]]]]]]
            }
            EventReducer.hydrate(history(false),into:c); store.changed(c)
            check(c.notices.journal.count == count,"R3 history child insertion is a baseline, not spawn")
            c.loading=true; EventReducer.hydrate(history(true),into:c); store.changed(c); c.loading=false; store.changed(c)
            check(c.notices.journal.count == count,"R3 history child completion is a baseline, not finish")
            // Loading is not an event source: live child publications can arrive during a parent read.
            c.loading=true;c.satellites.append(.init(id:"live-child",face:"x"));store.changed(c)
            check(c.notices.journal.last?.kind == .spawn,"R3 live child start during history loading is not suppressed")
            c.satellites[c.satellites.count-1].done=true;store.changed(c);c.loading=false
            check(c.notices.journal.last?.kind == .finish,"R3 live child completion during history loading is not suppressed")
        }
        do {
            let c=Conversation(id:"unknown",title:"Unknown"); c.isLiveConversation=true; c.exactTokensUsed=123
            let input=HeaderIslandConfiguration.conversation(c,variant:.full,columnWidth:507)
            check(input.signals.context == nil,"R7 tokens without a reported limit do not invent zero percent")
        }
        do {
            let header=HeaderIsland(),host=IslandPlane(frame:CGRect(x:0,y:0,width:507,height:400))
            let window=NSWindow(contentRect:host.bounds,styleMask:.borderless,backing:.buffered,defer:true)
            window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(header)
            var input=HeaderIslandConfiguration(id:"clock",title:"Clock",columnWidth:507,ambient:false)
            input.notices = .init(running:true);header.configure(input)
            input.notices?.journal=[.init(id:1,kind:.command,text:"Synthetic clock")];header.configure(input)
            check(header.pulseClockRunning,"R4 attached unshown host starts the actual Pulse display link")
            header.isHidden=true
            check(!header.pulseClockRunning,"R4 hidden presentation stops the actual Pulse display link")
            check(!window.isVisible,"R4 display-link host is never ordered onscreen")
            header.dispose();window.close()
        }
        do {
            let store=ConversationStore()
            let c=Conversation(id:"immediate",title:"Immediate")
            store.add(c)
            let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:.init(name:"Pulse publication",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),scale:1)
            scene.verificationPresented=true;scene.install();scene.clock.invalidate();scene.settle();scene.manualSettle=false
            let before=CACurrentMediaTime()
            store.apply(.init(id:1,time:nil,method:"turn/started",params:["threadId":"immediate","turn":["id":"t"]]))
            let probe=scene.columns.first { $0.conversation === c }?.island?.pulseProbe
            check(probe?["event"] as? String == "command","R12 native notice is configured synchronously before transcript batch")
            evidence.append(["revision":"publication","applyToProbeMs":(CACurrentMediaTime()-before)*1000,"immediate":probe?["event"] as? String ?? "none"])
            scene.disposeTranscriptPresentation()
        }
        for variant: HeaderIslandVariant in [.full,.brief] { for scale: CGFloat in [1,2] {
            let c=Conversation(id:"native",title:"Native fixture"), store=ConversationStore()
            store.add(c); c.isLiveConversation=true
            let logicalWidth: CGFloat = variant == .full ? 495:305
            let column=ColumnNode(c,store:store,identity:.white,rect:CGRect(x:0,y:0,width:logicalWidth,height:800),full:variant == .full,scale:scale,logicalBottom:760)
            let header=HeaderIsland(); column.attachIsland(header)
            // A board trace is a deterministic clock fixture; machine uptime must not move its expiry tick.
            var time=4096.0, serial=0
            header.now={time}
            func configure(_ v:HeaderIslandVariant?=nil) { column.configureIsland(v ?? variant,width:logicalWidth) }
            func emit(_ method:String,_ p:JSONValue=[:]) {
                serial+=1;var p=p.objectValue ?? [:];p["threadId"]="native"
                store.apply(.init(id:serial,time:time,method:method,params:.object(p)));configure()
            }
            func advance(_ dt:Double) {
                let n=max(1,Int(ceil(dt*240)))
                for _ in 0..<n {time+=dt/Double(n);header.sampleMotion(at:time)}
            }
            func number(_ key:String)->Double { (header.pulseProbe?[key] as? CGFloat).map(Double.init) ?? header.pulseProbe?[key] as? Double ?? -1 }
            func width()->Double { Double((header.pulseProbe?["rect"] as? [CGFloat])?[2] ?? -1) }
            configure();emit("turn/started",["turn":["id":"t"]]);advance(0.6)
            evidence.append(["revision":"width","variant":String(describing:variant),"scale":scale,"event":"cmd","native":width(),"board":boardWidth(variant,"cmd")])
            check(abs(width()-boardWidth(variant,"cmd"))<0.2,"R8 \(variant) \(scale)x bloom width follows board 288")
            header.togglePin();advance(0.3);header.isHidden=true;header.isHidden=false
            check(header.pulseProbe?["mode"] as? String == "compact","R4 hidden pinned Pulse does not revive")
            emit("item/started",["turnId":"t","item":["id":"c","type":"commandExecution","command":"Synthetic"]]);header.hover(true,at:time);advance(0.3)
            configure(variant == .full ? .brief:.full);configure()
            check(header.pulseProbe?["mode"] as? String == "compact","R4 variant switch retires hover and event")
            emit("item/started",["turnId":"t","item":["id":"c2","type":"commandExecution","command":"Synthetic"]]);header.togglePin();advance(0.3)
            header.isHidden=true
            check(header.pulseProbe == nil,"R4 hidden presentation suspends Pulse")
            header.isHidden=false
            check(header.pulseProbe?["mode"] as? String == "compact","R4 hidden pin cannot revive")
            emit("item/started",["turnId":"t","item":["id":"clock","type":"commandExecution","command":"Synthetic"]])
            let origin=time
            time=origin+0.016;header.sampleMotion(at:time)
            time=origin+0.010;configure()
            time=origin+0.032;header.sampleMotion(at:time)
            check(abs(number("remaining")-2.968)<0.00001,"R6 mixed target/current timestamps never rewind integration baseline")
            header.escape();advance(0.9)
            let orbWidth=header.orb.glassView.frame.width
            emit("core/approvalRequested",["approvalId":"native-a","request":approval])
            let start=time
            var rows:[[String:Any]]=[]
            for _ in 1...48 {
                advance(1/240)
                var p=header.pulseProbe ?? [:];p["t"]=time-start;rows.append(p)
            }
            let kickFrame=rows[14]
            let orb=(kickFrame["orbRect"] as? [CGFloat])?[2] ?? orbWidth
            check(orb > orbWidth*1.02,"R10 visible native orb glass receives board kick")
            check(rows.prefix(48).contains { ($0["haloAlpha"] as? Double ?? -1)>0 && ($0["haloAlpha"] as? Double ?? 2)<1 },"R11 opening halo has intermediate alpha")
            check(rows.prefix(14).contains { ($0["leadAlpha"] as? Double ?? -1)>0 && ($0["leadAlpha"] as? Double ?? 2)<1 },"R11 status mark swaps through intermediate alpha")
            check(rows.prefix(14).contains { ($0["trailAlpha"] as? Double ?? -1)>0 && ($0["trailAlpha"] as? Double ?? 2)<1 },"R11 compact trail swaps through intermediate alpha")
            for frame in 49...1752 {
                advance(1/240)
                var p=header.pulseProbe ?? [:];p["t"]=time-start;rows.append(p)
                if frame == 144 {
                    evidence.append(["revision":"width","variant":String(describing:variant),"scale":scale,"event":"appr","native":width(),"board":boardWidth(variant,"appr")])
                    check(abs(width()-boardWidth(variant,"appr"))<0.2,"R8 \(variant) \(scale)x action width follows board 292") }
                if frame == 1685 {
                    check((p["actionAlpha"] as? Double ?? 0)>0 && (p["actionText"] as? String)?.isEmpty == false && (p["drawnButtons"] as? [String])?.count == 2 && (p["buttons"] as? [String])?.isEmpty == true,"R9 outgoing action retains text/buttons while disabling input")
                    check(number("haloAlpha")>0 && number("haloAlpha")<1,"R11 closing halo fades with outgoing content")
                }
                if frame == 1716 { check(header.pulseProbe?["actionText"] as? String == "","R9 outgoing action clears after fade") }
            }
            if let path=ProcessInfo.processInfo.environment["PULSE_REVISION_BOARD"],
               let data=try? Data(contentsOf:URL(fileURLWithPath:path)),
               let reference=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               let frames=reference["frames"] as? [[String:Any]],frames.count == rows.count {
                for (native,board) in [("actionAlpha","actionAlpha"),("haloAlpha","actionAlpha"),("leadAlpha","leadAlpha"),("trailAlpha","trailAlpha")] {
                    let error=zip(rows,frames).map { abs(($0.0[native] as? Double ?? -2)-($0.1[board] as? Double ?? 2)) }.max() ?? 10
                    check(error<0.001,"R11 same-time board/native \(native) max error \(error)")
                    evidence.append(["revision":"alpha","variant":String(describing:variant),"scale":scale,"field":native,"maxError":error,"frames":rows.count])
                }
            } else { check(false,"R11 headless board transition trace supplied") }
            emit("core/approvalResponded",["approvalId":"native-a"]);advance(2.7)
            emit("error",["message":"Synthetic stop","willRetry":false]);advance(0.6)
            check(abs(number("haloWidth")-(variant == .full ? 507:317))<0.01,"R8 \(variant) \(scale)x halo spans divider-to-divider column")
            evidence.append(["revision":"native","variant":String(describing:variant),"scale":scale,"frames":rows])
            header.dispose()
        }}
    }
}

#if PULSE_REVISION_SELFTEST
/// Every transport operation is handled in memory, including an explicitly held response POST.
private actor PulseReplyTransport: CoreTransport {
    var pending: JSONValue
    private(set) var posts=0
    private var waiters: [CheckedContinuation<JSONValue,Error>]=[]
    init(_ request: JSONValue) { pending=["threadId":"backend","approvalId":"request","request":request] }
    func request(_ method:String,path:String,body:JSONValue?,timeout:TimeInterval?) async throws -> JSONValue {
        if path.hasPrefix("/approvals/") {
            posts+=1
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        if path == "/health" { return ["name":"Organic Codex Core","backendConnected":true,"lastEventId":0,"pendingApprovals":[pending]] }
        if body?["method"]?.stringValue == "thread/read" { return ["thread":["id":"backend","turns":[]]] }
        return [:]
    }
    nonisolated func events(since:Int,threadID:String?) -> AsyncThrowingStream<CoreEvent,Error> { AsyncThrowingStream { $0.finish() } }
    func release() { let held=waiters;waiters=[];for waiter in held { waiter.resume(returning:[:]) } }
}

@main @MainActor enum PulseRevisionVerificationMain {
    static func main() async {
        let path=CommandLine.arguments.dropFirst().first ?? "/tmp/organic-m1133c/revision"
        var code=HeaderPulseVerification.run(to:path)
        var rows:[[String:Any]]=[]
        let requests: [JSONValue] = [
            ["method":"item/commandExecution/requestApproval","params":["command":"Synthetic","availableDecisions":["accept","decline"]]],
            ["method":"item/tool/requestUserInput","params":["questions":[["id":"q","question":"Synthetic?","options":[["label":"No"],["label":"Yes"]]]]]]
        ]
        for request in requests {
            let c=Conversation(id:"response",title:"Response"),store=ConversationStore()
            c.backendThreadID="backend";c.isLiveConversation=true;store.add(c)
            let transport=PulseReplyTransport(request)
            let presentation=LocalPresentationState(store:store,scope:"pulse-revision",storage:CoreMemoryStorage())
            let runtime=LiveConversationRuntime(store:store,client:transport,presentation:presentation)
            EventReducer.approval(["approvalId":"request","request":request],in:c)
            func submit() {
                if let q=c.userInput { runtime.answer(q,in:c,answers:["q":["Yes"]]) }
                else if let a=c.approvals.first { runtime.respond(a,in:c,response:["decision":"accept"]) }
            }
            submit()
            for _ in 0..<100 where await transport.posts == 0 { await Task.yield() }
            do { try await runtime.read(c,includeSatellites:false) }
            catch { code=1;print("FINDING R5 synthetic history read failed",error) }
            let retained=c.userInput?.submitting ?? c.approvals.first?.submitting ?? false
            submit()
            for _ in 0..<100 { await Task.yield() }
            let posts=await transport.posts,passed=retained && posts == 1
            if !passed { code=1; print("FINDING R5 in-flight response duplicated after reconciliation",posts) }
            rows.append(["method":request["method"]?.stringValue ?? "","submittingRetained":retained,"posts":posts,"passed":passed])
            await transport.release()
            for _ in 0..<100 { await Task.yield() }
        }
        if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:path).appendingPathComponent("responses.json")) }
        print("PULSE REVISION response checks 2, exit \(code)")
        exit(code)
    }
}
#endif
