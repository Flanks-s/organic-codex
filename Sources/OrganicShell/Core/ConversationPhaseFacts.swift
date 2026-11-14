import Foundation

/// Turn-scoped facts. Transport IDs order replacements; transcript shape never proves completion.
struct ConversationPhaseFacts: Sendable {
    enum State: String, Sendable { case running, unknown, waiting, completed, failed, cancelled }
    private(set) var turnID: String?
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var terminal: State?
    private(set) var serial: UInt64 = 0
    private(set) var isRetrying = false
    private(set) var isReplay = false
    private var awaiting = false
    private var stoppedError = false
    private var activityID = Int.min
    private var startID = Int.min
    private var planID = Int.min
    private var terminalID = Int.min
    private var seen: [Int] = []
    private var retired: Set<String> = []
    private var pendingPlans:[String:(id:Int,steps:[JSONValue])]=[:]
    private struct Selection:Equatable {
        let turnID:String?
        let completed,total:Int
        let terminal:State?
        let awaiting,stopped,retrying:Bool
    }
    private var selection:Selection {.init(turnID:turnID,completed:completed,total:total,terminal:terminal,awaiting:awaiting,stopped:stoppedError,retrying:isRetrying)}
    var fraction: Double? { total > 0 ? Double(completed)/Double(total) : nil }

    @MainActor func state(in c: Conversation) -> State {
        if let terminal { return terminal }
        if stoppedError || turnID == nil && c.error == .stopped { return .failed }
        if awaiting || turnID == nil && c.needsYou { return .waiting }
        return fraction == nil ? .unknown : .running
    }
    @MainActor mutating func consume(_ event: CoreEvent, in c: Conversation) {
        guard !seen.contains(event.id) else { return }
        seen.append(event.id); if seen.count > 256 { seen.removeFirst(seen.count-256) }
        let previousSerial=serial
        defer {if serial != previousSerial {isReplay=false}}
        let p=event.params, incoming=p["turnId"]?.stringValue ?? p["turn"]?["id"]?.stringValue
        switch event.method {
        case "thread/started", "thread/restored":
            if let thread=p["thread"] {restore(thread,in:c,eventID:event.id)}
            return
        case "turn/started":
            guard let id=incoming, !id.isEmpty, !retired.contains(id), event.id > startID else { return }
            if turnID != id {
                if let turnID { retired.insert(turnID) }
                turnID=id; completed=0; total=0; planID=Int.min; terminalID=Int.min
            } else if terminal != nil { return }
            startID=event.id; terminal=nil; awaiting=false;stoppedError=false;isRetrying=false
            if let pending=pendingPlans.removeValue(forKey:id) {replacePlan(pending.steps);planID=pending.id}
            serial &+= 1
        case "turn/plan/updated":
            guard let id=incoming, !id.isEmpty, !retired.contains(id) else { return }
            if turnID != nil,turnID != id {
                if event.id > (pendingPlans[id]?.id ?? Int.min) {pendingPlans[id]=(event.id,p["plan"]?.arrayValue ?? [])}
                if pendingPlans.count>8,let oldest=pendingPlans.min(by:{$0.value.id<$1.value.id})?.key {pendingPlans[oldest]=nil}
                return
            }
            guard terminal == nil,event.id > planID else { return }
            if turnID == nil { turnID=id }
            replacePlan(p["plan"]?.arrayValue ?? []); planID=event.id; serial &+= 1
        case "turn/completed":
            guard let id=incoming, id == turnID, event.id > terminalID else { return }
            // An absent status neither invents completion nor revokes a confirmed terminal state.
            terminalID=event.id
            guard let confirmed=Self.confirmed(p["turn"]?["status"]?.stringValue) else {return}
            terminal=confirmed;isRetrying=false;serial &+= 1
        case "core/fixtureState":
            let previous=selection
            awaiting=c.needsYou;stoppedError=c.error == .stopped;isRetrying=c.error == .running
            if previous != selection {serial &+= 1}
        default:
            guard incoming == nil || incoming == turnID, event.id > activityID else { return }
            if event.method == "error" { stoppedError=p["willRetry"]?.boolValue != true;isRetrying = !stoppedError }
            if event.method.hasPrefix("core/approval") { awaiting=c.needsYou }
            if ["item/completed", "item/started"].contains(event.method) { if stoppedError {isRetrying=true};stoppedError=false }
            if ["item/completed", "item/started", "error", "core/approvalRequested", "core/approvalResponded", "core/approvalExpired"].contains(event.method) { activityID=event.id;serial &+= 1 }
        }
        // Bound retired turn bookkeeping without allowing known old turns to restart.
        if retired.count > 512 { retired=Set(retired.sorted().suffix(512)) }
    }
    @MainActor mutating func restore(_ thread:JSONValue,in c:Conversation,eventID:Int?=nil) {
        if let eventID,eventID<max(startID,max(planID,terminalID)) {return}
        let previous=selection
        defer {if previous != selection {serial &+= 1};isReplay=true}
        let turns=thread["turns"]?.arrayValue ?? []
        let selected=turns.first{$0["id"]?.stringValue == c.activeTurnID} ?? turns.last
        guard let selected,let id=selected["id"]?.stringValue else {
            if turnID == nil {completed=0;total=0;terminal=nil}
            isReplay=true;return
        }
        if eventID != nil,retired.contains(id) {return}
        if turnID != id {
            if let turnID {retired.insert(turnID)}
            turnID=id;completed=0;total=0;planID=Int.min
        }
        if let plan=selected["plan"]?.arrayValue {replacePlan(plan)}
        terminal=Self.confirmed(selected["status"]?.stringValue)
        awaiting=c.needsYou;stoppedError=c.error == .stopped;isRetrying=c.error == .running
        if let eventID {startID=max(startID,eventID)}
        isReplay=true
    }
    @MainActor mutating func mergeHistory(_ replay:Self,turnID selected:String?,status:String?,in c:Conversation) {
        guard let selected else {isReplay=true;return}
        let previous=selection
        defer {if previous != selection {serial &+= 1};isReplay=true}
        if turnID != selected {completed=0;total=0;planID=Int.min}
        turnID=selected
        if replay.turnID == selected {
            if replay.planID != Int.min {completed=replay.completed;total=replay.total;planID=replay.planID}
            startID=max(startID,replay.startID);terminalID=max(terminalID,replay.terminalID)
            isRetrying=replay.isRetrying;stoppedError=replay.stoppedError
        }
        terminal=Self.confirmed(status)
        awaiting=c.needsYou;isReplay=true
    }
    mutating func resetTransportEpoch() {
        let next=serial &+ 1
        self=Self();serial=next;isReplay=true
    }
    private mutating func replacePlan(_ plan: [JSONValue]) {
        let valid=plan.allSatisfy{$0["step"]?.stringValue != nil && ["pending","inProgress","in_progress","completed"].contains($0["status"]?.stringValue ?? "")}
        guard valid else {completed=0;total=0;return}
        total=plan.count;completed=plan.filter{$0["status"]?.stringValue == "completed"}.count
    }
    private static func confirmed(_ status: String?) -> State? {
        switch status { case "completed": .completed; case "failed": .failed; case "interrupted", "cancelled": .cancelled; default: nil }
    }
}

@MainActor extension ConversationStore {
    func resetPhaseTransportEpoch() {for c in conversations {c.phaseFacts.resetTransportEpoch()}}
}
