import AppKit

// Orb decoration configurations from Shell v2's Core models (Sol, docs/reference/ORB-PORT-26102807.md). The Orb
// component knows nothing of Core and Core nothing of the component; this bridge is the only place they meet.

@MainActor
func makeOrbConfiguration(
    _ c: Conversation,
    drawingSize: CGFloat,
    backingScale: CGFloat,
    reduceMotion: Bool,
    ambient: Bool,
    isKeyWindow: Bool,
    satelliteMode: OrbSatelliteMode = .orbit
) -> OrbConfiguration {
    let error: OrbBadge.ErrorState?
    switch c.phaseFacts.isRetrying ? ErrorState.running:c.error {
    case .running: error = .running
    case .stopped: error = .stopped
    case nil: error = nil
    }
    return OrbConfiguration(
        content: .identity(orbIdentity(of: c)),
        drawingSize: drawingSize,
        bodyUnknown: (c.isLiveConversation || c.backendThreadID != nil) && !c.contextUsageReported,
        bodyPhase: conversationPhaseEvent(c),
        // Settings ▸ Organic ▸ Identity liquid (`toggle.identityLiquid`, on by default): the context as liquid.
        context: UserDefaults.standard.object(forKey: "toggle.identityLiquid") as? Bool ?? true ? c.contextShown : 0,
        identityLiquid: UserDefaults.standard.object(forKey:"toggle.identityLiquid") as? Bool ?? true,
        running: c.running,
        activitySerial: c.orbActivity.serial,
        badge: .resolve(error: error, approvals: c.approvals.count,
                        question: c.question != nil, completions: c.completions),
        satellites: c.satellites.map {
            OrbSatellite(id: $0.id, face: $0.face, pace: c.pace,
                         done: $0.done, finishedOrder: $0.finishedOrder, bodyPhase:satellitePhaseEvent($0,parent:c))
        },
        satellitesRetired: c.satellitesRetired,
        satelliteMode: satelliteMode,
        compactions: c.compactions,
        completions: c.completions,
        redEvents: c.redEvents,
        redUnseen: c.redUnseen,
        reduceMotion: reduceMotion,
        ambient: ambient,
        isKeyWindow: isKeyWindow,
        backingScale: backingScale
    )
}

/// me's badge (product MeOrb.badge, DockItems.swift:836): every chat's approvals, question and error added up, red if
/// any chat has an error, else yellow (M9: the product's me showed a red 4, v2's none).
@MainActor
func meBadge(_ store: ConversationStore) -> OrbBadge? {
    var count = 0, tone: OrbBadge.Tone?
    for c in store.conversations {
        let events = c.approvals.count + (c.question == nil && c.userInput == nil ? 0 : 1) + (c.error == nil ? 0 : 1)
        guard events > 0 else { continue }
        count += events
        let t: OrbBadge.Tone = c.error != nil ? .red : .yellow
        tone = max(tone ?? t, t)
    }
    return tone.map { OrbBadge(tone: $0, symbol: .count(count)) }
}

@MainActor
func makeMeConfiguration(
    store: ConversationStore,
    initials: String,
    drawingSize: CGFloat,
    backingScale: CGFloat,
    reduceMotion: Bool,
    ambient: Bool,
    isKeyWindow: Bool,
    badgeProjection: (() -> OrbBadge?)? = nil
) -> OrbConfiguration {
    func shown(_ used: Double) -> Double { Double(Conversation.percent(used)) / 100 }
    let quota = OrbQuota(
        primaryUsed: store.quotaFiveHourReported ? shown(store.quotaFiveHour) : nil,
        secondaryUsed: store.quotaWeekReported ? shown(store.quotaWeek) : nil
    )
    let badge: OrbBadge?
    if let badgeProjection { badge = badgeProjection() } else { badge = meBadge(store) }
    return OrbConfiguration(
        content: .me(initials: initials, quota: quota),
        drawingSize: drawingSize,
        badge: badge,
        reduceMotion: reduceMotion,
        ambient: ambient,
        isKeyWindow: isKeyWindow,
        backingScale: backingScale
    )
}

/// A conversation's planet: Customize's symbol and tint when set (Core identitySymbol / identityTint), else the one
/// assigned by its index (f122).
@MainActor func orbIdentity(of c: Conversation) -> OrbIdentity {
    BodyIdentityAdapter.identity(index: c.identityIndex, symbol: c.identitySymbol, tint: c.identityTint)
}

/// New M11.39 projection; meBadge above deliberately keeps its existing all-store/event-count behavior.
struct SunHoverAttention {
    enum Severity: Int, Comparable {
        case stoppedError, runningError, approval, question
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    struct Event: Equatable {
        let key: String
        let sourceID: String
        let severity: Severity
        let text: String
        let since: Double
        let waitStartReported: Bool
    }
    struct Row: Equatable {
        let conversationID: String
        let title: String
        let events: [Event]
        var mostSevere: Event { events[0] }
        var additionalCount: Int { max(0, events.count - 1) }
        var suffix: String { additionalCount == 0 ? "" : "+\(additionalCount)" }
    }
    let rows: [Row]
    var eventCount: Int { rows.reduce(0) { $0 + $1.events.count } }
    var conversationCount: Int { rows.count }
    var visibleRows: [Row] { Array(rows.prefix(6)) }
    var badgeCount: Int { conversationCount }
}

/// Lifetime is one Organic window. Re-evaluate IDs on every read and again on activation.
@MainActor final class SunHoverAttentionProjection {
    private var firstSeen: [String: Double] = [:]
    /// `time` is Unix seconds, matching CoreEvent.time; use a monotonic clock only for the motion state/deal.
    func snapshot(store: ConversationStore, memberIDs: Set<String>, at time: Double) -> SunHoverAttention {
        var rows: [SunHoverAttention.Row] = [], liveKeys: Set<String> = []
        let members = memberIDs.sorted().compactMap { id -> Conversation? in
            guard let c = store.conversation(id), c.id == id, !c.archived else { return nil }; return c
        }
        func descendants(_ root: Conversation) -> [Conversation] {
            var pending = root.satellites.compactMap(\.threadID), visited: Set<String> = [root.id], result: [Conversation] = []
            while let tid = pending.popLast() {
                guard let child = store.backendConversation(tid) ?? store.conversation(tid), !child.archived,
                      visited.insert(child.id).inserted else { continue }
                result.append(child); pending += child.satellites.compactMap(\.threadID)
            }
            return result
        }
        let childrenByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, descendants($0)) })
        let representedChildren = Set(childrenByID.values.flatMap { $0.map(\.id) })
        for parent in members where !representedChildren.contains(parent.id) {
            let id = parent.id, children = childrenByID[id] ?? []
            var events: [SunHoverAttention.Event] = [], requests: Set<String> = []
            func append(_ source: Conversation, key: String, clockKey: String, severity: SunHoverAttention.Severity, text: String) {
                let stable = id + ":" + source.id + ":" + key
                liveKeys.insert(stable)
                let reported = store.attentionTime(threadID: source.backendThreadID ?? source.id, eventKey: clockKey)
                if firstSeen[stable] == nil { firstSeen[stable] = reported ?? time }
                if !store.attentionErrorWasReviewed(sourceID: source.id, key: stable) {
                    events.append(.init(key: stable, sourceID: source.id, severity: severity, text: text,
                                        since: reported ?? firstSeen[stable]!, waitStartReported: reported != nil))
                }
            }
            for source in [parent] + children {
                // A child that is itself a window member keeps its failure when folded into its parent's row.
                if source === parent || memberIDs.contains(source.id), let error = source.error {
                    let turn = source.notices.snapshot(in: source).turnID ?? source.activeTurnID ?? ""
                    let key = "error:\(turn):\(source.redEvents):\(String(describing: error))"
                    append(source, key: key, clockKey: "error", severity: error == .stopped ? .stoppedError : .runningError,
                           text: source.operationError ?? (error == .stopped ? "Stopped by an error" : "Error · still working"))
                }
                for approval in source.approvals where requests.insert(approval.id).inserted {
                    append(source, key: "request:" + approval.id, clockKey: "request:" + approval.id, severity: .approval,
                           text: approval.title + (approval.command.isEmpty ? "" : " " + approval.command))
                }
                if let input = source.userInput, requests.insert(input.id).inserted {
                    append(source, key: "request:" + input.id, clockKey: "request:" + input.id, severity: .question,
                           text: input.questions.map(\.prompt).joined(separator: " · "))
                } else if source.userInput == nil, let question = source.question {
                    append(source, key: "question:" + question, clockKey: "question", severity: .question, text: question)
                }
            }
            events.sort { $0.severity == $1.severity ? ($0.since == $1.since ? $0.key < $1.key : $0.since < $1.since) : $0.severity < $1.severity }
            if !events.isEmpty { rows.append(.init(conversationID: id, title: parent.title, events: events)) }
        }
        firstSeen = firstSeen.filter { liveKeys.contains($0.key) }
        rows.sort {
            let a = $0.mostSevere, b = $1.mostSevere
            if a.severity != b.severity { return a.severity < b.severity }
            return a.since == b.since ? $0.conversationID < $1.conversationID : a.since < b.since
        }
        return .init(rows: rows)
    }
    func activate(_ id: String, store: ConversationStore, memberIDs: Set<String>, at time: Double) -> String? {
        guard let row = snapshot(store: store, memberIDs: memberIDs, at: time).rows.first(where: { $0.conversationID == id }) else { return nil }
        for error in row.events where error.severity == .stoppedError || error.severity == .runningError {
            store.markAttentionErrorReviewed(sourceID: error.sourceID, key: error.key)
        }
        return id
    }
}
