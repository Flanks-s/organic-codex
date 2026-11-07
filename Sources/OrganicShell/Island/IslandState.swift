import Foundation

struct HeaderIslandSignals: Equatable {
    enum Error: Equatable { case stopped, running }
    enum Mark: Equatable { case stoppedError, runningError, approvals(Int), question, completion, working }
    var error: Error?
    var approvals = 0, completions = 0
    var question = false, running = false, stopping = false
    var stops = 0, files = 0, added = 0, removed = 0, compactions = 0
    var context: Double?
    var satellites: [OrbSatellite] = []
    var mark: Mark? {
        if let error { return error == .stopped ? .stoppedError:.runningError }
        if approvals>0 { return .approvals(min(9,approvals)) }
        if question { return .question }; if completions>0 { return .completion }
        return running ? .working:nil
    }
    var words: String {
        switch mark {
        case .stoppedError: "Stopped by an error"
        case .runningError: "Error, still working"
        case .approvals: "\(approvals) approval\(approvals == 1 ? "":"s") need you"
        case .question: "Asking you a question"
        case .completion: "Done"
        case .working: "Working"
        case nil: "Idle"
        }
    }
}
enum HeaderIslandPanel: String, CaseIterable { case subAgents, changes, context, status }
enum HeaderIslandRoute: Equatable { case panel(HeaderIslandPanel), satellite(String), transcript }
struct HeaderIslandEvent: Equatable {
    enum Kind: Int, CaseIterable { case working, changes, spawn, finish, context, compacted, done, question, approval, error }
    var kind: Kind
    var text: String
    var satellite: String?
    var at: TimeInterval
    var hold: Double {
        switch kind { case .error:5; case .question,.approval:4; case .done:3; case .compacted,.context,.changes:2.4; case .finish:2.2; case .spawn:2; case .working:1.5 }
    }
    var urgent: Bool { kind == .error || kind == .question || kind == .approval }
    var route: HeaderIslandRoute {
        switch kind {
        case .changes: .panel(.changes)
        case .context,.compacted: .panel(.context)
        case .spawn: .panel(.subAgents)
        case .finish: satellite.map(HeaderIslandRoute.satellite) ?? .panel(.subAgents)
        default: .transcript
        }
    }
    var symbol: String {
        switch kind {
        case .error:"exclamationmark.triangle.fill"; case .approval:"hand.raised.fill"; case .question:"questionmark.bubble.fill"
        case .done:"checkmark.circle.fill"; case .compacted:"arrow.down.right.and.arrow.up.left"; case .context:"circle.dashed"
        case .finish:"checkmark.circle"; case .spawn:"circle.hexagongrid"; case .changes:"doc.text"; case .working:"sparkle"
        }
    }
    static func between(_ a: HeaderIslandSignals, _ b: HeaderIslandSignals, contextArmed: Bool, now: Double) -> Self? {
        func e(_ kind: Kind,_ text: String,_ satellite: String? = nil) -> Self { .init(kind:kind,text:text,satellite:satellite,at:now) }
        if let error=b.error, a.error != error { return e(.error,error == .stopped ? "Stopped by an error":"Error · still working") }
        if b.approvals>a.approvals { return e(.approval,b.approvals == 1 ? "1 approval needs you":"\(b.approvals) approvals need you") }
        if b.question && !a.question { return e(.question,"A question for you") }
        if a.running && !b.running && b.error == nil && !a.stopping && b.stops == a.stops { return e(.done,b.files>0 ? "Done · \(b.files) file\(b.files == 1 ? "":"s") changed":"Done") }
        let percent=b.context.map { "\(Int(($0*100).rounded()))% used" } ?? "usage unreported"
        if b.compactions>a.compactions { return e(.compacted,"Context compacted · "+percent) }
        if contextArmed, let x=a.context, let y=b.context, x<0.8 && y>=0.8 { return e(.context,"Context "+percent) }
        if b.satellites.filter(\.done).count>a.satellites.filter(\.done).count, b.satellites.count == a.satellites.count,
           let latest=b.satellites.enumerated().filter({ $0.element.done }).max(by:{ ($0.element.finishedOrder ?? $0.offset)<($1.element.finishedOrder ?? $1.offset) }) {
            return e(.finish,"Sub-agent \(latest.offset+1) finished · \(b.satellites.filter { !$0.done }.count) running",latest.element.id)
        }
        if b.satellites.count>a.satellites.count { let n=b.satellites.filter { !$0.done }.count; return e(.spawn,"\(n) sub-agent\(n == 1 ? "":"s") running") }
        if b.files>a.files || b.added>a.added || b.removed>a.removed { return e(.changes,"+\(b.added) −\(b.removed) · \(b.files) file\(b.files == 1 ? "":"s")") }
        if b.running && !a.running { return e(.working,"Working") }; return nil
    }
}

/// Deterministic product IslandModel port. One latest waiting event, not an unbounded FIFO.
/// No timers in this value: HeaderIsland schedules only nextDeadline, or tests inject tick(now:).
struct HeaderIslandState: Equatable {
    private(set) var activity: HeaderIslandEvent?, waiting: HeaderIslandEvent?
    private(set) var expanded=false, pinned=false, editing=false, hovering=false, focused=false
    private(set) var renameText="", renameOriginal=""
    private(set) var lobeRevision=0
    private(set) var satellitesHoldingUntil:Double?
    private(set) var timing = Timing.immediate
    var contextArmed=true
    private var dismissAt: Double?, hoverAt: Double?, closeAt: Double?
    private var held=false
    enum Timing: Equatable { case immediate, activityIn, activityOut, expand, close, rename, renameCommit }
    var shape: HeaderIslandShape { editing ? .editing:expanded ? .expanded:activity == nil ? .compact:.activity }
    var nextDeadline: Double? { [dismissAt,hoverAt,closeAt,satellitesHoldingUntil].compactMap { $0 }.min() }
    mutating func show(_ event: HeaderIslandEvent, now: Double) {
        guard !editing, !expanded else { return }
        if activity?.urgent == true && !event.urgent { waiting=event; return }
        if event.urgent { waiting=nil }
        if let old=activity, old.kind == event.kind, event.at-old.at<0.25 {
            var replacement=event; replacement.at=old.at; activity=replacement
        } else { activity=event; lobeRevision+=1; timing = .activityIn }
        held=false; dismissAt=now+event.hold
    }
    mutating func update(_ a: HeaderIslandSignals,_ b: HeaderIslandSignals,now: Double) {
        if (b.context.map { $0<0.75 } ?? false) || b.compactions>a.compactions { contextArmed=true }
        if let event=HeaderIslandEvent.between(a,b,contextArmed:contextArmed,now:now) {
            if event.kind == .context { contextArmed=false }; show(event,now:now)
        }
    }
    mutating func hover(_ inside: Bool, now: Double) {
        hovering=inside; hoverAt=nil; closeAt=nil
        if !inside && !focused && held { held=false; dismissAt=now+0.8 }
        if inside && !expanded && !editing { hoverAt=now+0.280 }
        if !inside && expanded && !pinned && !focused { closeAt=now+0.300 }
    }
    mutating func focus(_ inside: Bool, now: Double) {
        focused=inside
        if inside { closeAt=nil }
        if !inside && !hovering {
            if held { held=false; dismissAt=now+0.8 }
            if expanded && !pinned { closeAt=now+0.300 }
        }
    }
    mutating func setExpanded(_ open: Bool, pinned pin: Bool) {
        hoverAt=nil; closeAt=nil; dismissAt=nil; held=false
        expanded=open; pinned=open && pin; timing=open ? .expand:.close
        if open { activity=nil; waiting=nil }
    }
    mutating func togglePin() { setExpanded(!(expanded && pinned),pinned:true) }
    mutating func outside() { if !editing { setExpanded(false,pinned:false); activity=nil; waiting=nil } }
    mutating func escape() { if editing { cancelRename() } else { outside() } }
    mutating func updateSatelliteRetirement(was:Bool?,retired:Bool,now:Double) {
        if !retired { satellitesHoldingUntil=nil }
        else if was == false { satellitesHoldingUntil=now+2 }
    }
    mutating func tick(now: Double) {
        if let end=satellitesHoldingUntil,end<=now { satellitesHoldingUntil=nil }
        if let t=hoverAt,t<=now { hoverAt=nil; if hovering && !editing { setExpanded(true,pinned:false) } }
        if let t=closeAt,t<=now { closeAt=nil; if !hovering && !focused && !pinned { setExpanded(false,pinned:false) } }
        if let t=dismissAt,t<=now {
            dismissAt=nil
            if hovering || focused { held=true; return }
            activity=nil; timing = .activityOut
            if let event=waiting { waiting=nil; if now-event.at<6 { show(event,now:now) } }
        }
    }
    mutating func beginRename(_ name: String) {
        guard !editing else { return }; setExpanded(false,pinned:false); activity=nil; waiting=nil
        editing=true; renameText=name; renameOriginal=name; timing = .rename
    }
    mutating func editRename(_ text: String) { if editing { renameText=text } }
    @discardableResult mutating func commitRename() -> String? {
        guard editing else { return nil }; editing=false
        let name=renameText.trimmingCharacters(in:.whitespacesAndNewlines)
        timing = .renameCommit
        return name.isEmpty || name == renameOriginal ? nil:name
    }
    mutating func cancelRename() { editing=false; renameText=renameOriginal; timing = .close }
}
