import Foundation

/// Interleaved thread/read and event-page facts must keep each clock attached to its own turn.
@MainActor enum HeaderPulseFourthVerification {
    static func run(check: (Bool, String) -> Void, evidence: inout [[String: Any]]) {
        let old: JSONValue = ["turns": [["id": "A", "status": "completed", "startedAt": 10, "completedAt": 20, "items": []]]]
        func event(_ id: Int, _ method: String, _ turn: String, _ time: Double?, _ status: String? = nil) -> CoreEvent {
            var value: [String: JSONValue] = ["id": .string(turn)]
            if let status { value["status"] = .string(status) }
            return .init(id: id, time: time, method: method, params: ["threadId": "interleaved", "turn": .object(value)])
        }
        for seeded in [false, true] {
            for status in ["running", "completed", "failed", "interrupted"] {
                let c = Conversation(id: "interleaved", title: "Interleaved history")
                EventReducer.hydrate(old, into: c)
                let replay = HistoryReplay(conversation: c, cursor: 1, seeded: seeded)
                replay.apply(event(2, "turn/started", "B", 30), through: 3)
                if status != "running" { replay.apply(event(3, "turn/completed", "B", 40, status), through: 3) }
                // Production reads the snapshot first, fetches through health, then hydrates and merges.
                EventReducer.hydrate(old, into: c)
                let count = c.notices.journal.count
                replay.merge(into: c, snapshot: old)
                let notice = c.notices.snapshot(in: c)
                let name = "R4 \(seeded ? "seeded" : "cold") B \(status) after A-only snapshot"
                check(notice.turnID == "B" && (status == "running" ? c.activeTurnID == "B" : c.activeTurnID == nil), name + " keeps merged identity")
                check(notice.startedAt == 30 && notice.endedAt == (status == "running" ? nil : 40), name + " keeps B clock")
                check(notice.terminalStatus == (status == "running" ? nil : status), name + " keeps B status")
                replay.merge(into: c, snapshot: old)
                check(c.notices.journal.count == count && c.notices.snapshot(in: c) == notice, name + " is silent and idempotent")
                if status != "running" {
                    c.notices.consume(event(4, "turn/completed", "B", 40, status), in: c)
                    check(c.notices.journal.count == count, name + " retains completion deduplication")
                }
                evidence.append(["fourth": name, "turn": notice.turnID ?? "none", "start": notice.startedAt ?? -1, "end": notice.endedAt ?? -1, "status": notice.terminalStatus ?? "none"])
            }
        }
        do {
            let c = Conversation(id: "interleaved", title: "Unknown clock")
            let replay = HistoryReplay(conversation: c, cursor: 1, seeded: false)
            replay.apply(event(2, "turn/started", "B", nil), through: 3)
            EventReducer.hydrate(old, into: c); replay.merge(into: c, snapshot: old)
            let notice = c.notices.snapshot(in: c)
            check(notice.turnID == "B" && notice.startedAt == nil && notice.endedAt == nil, "R4 missing B timestamps stay unknown instead of borrowing A or wall time")
        }
        do {
            let c = Conversation(id: "interleaved", title: "Seeded completion")
            let store = ConversationStore(conversations: [c])
            store.apply(event(1, "turn/started", "B", 30))
            let replay = HistoryReplay(conversation: c, cursor: 1, seeded: true)
            replay.apply(event(2, "turn/completed", "B", 40, "completed"), through: 2)
            EventReducer.hydrate(old, into: c); replay.merge(into: c, snapshot: old)
            let notice = c.notices.snapshot(in: c)
            check(notice.turnID == "B" && notice.startedAt == 30 && notice.endedAt == 40, "R4 completion-only replay retains the same B baseline start")
        }
        for status in ["inProgress", "completed"] {
            let c = Conversation(id: "interleaved", title: "Newer snapshot")
            let replay = HistoryReplay(conversation: c, cursor: 0, seeded: false)
            replay.apply(event(1, "turn/started", "B", 30), through: 2)
            replay.apply(event(2, "turn/completed", "B", 40, "completed"), through: 2)
            var newer: [String: JSONValue] = ["id": "C", "status": .string(status), "startedAt": 50, "items": []]
            if status == "completed" { newer["completedAt"] = 60 }
            let snapshot: JSONValue = ["turns": [["id": "B", "status": "completed", "startedAt": 30, "completedAt": 40, "items": []], .object(newer)]]
            EventReducer.hydrate(snapshot, into: c); replay.merge(into: c, snapshot: snapshot)
            let notice = c.notices.snapshot(in: c)
            check(notice.turnID == "C" && notice.startedAt == 50 && notice.endedAt == (status == "inProgress" ? nil : 60), "R4 newer snapshot C \(status) wins over replayed B")
        }
        do {
            let c = Conversation(id: "interleaved", title: "Identity boundary")
            c.activeTurnID = "B"; c.running = true
            c.notices.restore(in: c, started: 10, ended: 20, confirmedTurn: "A", status: "completed")
            let notice = c.notices.snapshot(in: c)
            check(notice.turnID == "B" && notice.startedAt == nil && notice.endedAt == nil, "R4 restore rejects active-clock metadata carrying another turn ID")
        }
    }
}

#if PULSE_FOURTH_SELFTEST
@main @MainActor enum PulseFourthVerificationMain {
    static func main() {
        let path = CommandLine.arguments.dropFirst().first ?? "/tmp/organic-m1133e/fourth"
        var checks = 0, failures: [String] = [], evidence: [[String: Any]] = []
        HeaderPulseFourthVerification.run(check: { passed, name in
            checks += 1
            if !passed { failures.append(name); print("FINDING", name) }
        }, evidence: &evidence)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["checks": checks, "failures": failures, "evidence": evidence], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path).appendingPathComponent("fourth.json"))
        }
        print("PULSE FOURTH \(checks) checks \(failures.count) findings")
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
