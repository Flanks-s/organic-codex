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
    switch c.error {
    case .running: error = .running
    case .stopped: error = .stopped
    case nil: error = nil
    }
    return OrbConfiguration(
        content: .identity(orbIdentity(of: c)),
        drawingSize: drawingSize,
        // Settings ▸ Organic ▸ Identity liquid (`toggle.identityLiquid`, on by default): the context as liquid.
        context: UserDefaults.standard.object(forKey: "toggle.identityLiquid") as? Bool ?? true ? c.contextShown : 0,
        identityLiquid: UserDefaults.standard.object(forKey:"toggle.identityLiquid") as? Bool ?? true,
        running: c.running,
        activitySerial: c.orbActivity.serial,
        badge: .resolve(error: error, approvals: c.approvals.count,
                        question: c.question != nil, completions: c.completions),
        satellites: c.satellites.map {
            OrbSatellite(id: $0.id, face: $0.face, pace: c.pace,
                         done: $0.done, finishedOrder: $0.finishedOrder)
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
    isKeyWindow: Bool
) -> OrbConfiguration {
    func shown(_ used: Double) -> Double { Double(Conversation.percent(used)) / 100 }
    let quota = OrbQuota(
        primaryUsed: store.quotaFiveHourReported ? shown(store.quotaFiveHour) : nil,
        secondaryUsed: store.quotaWeekReported ? shown(store.quotaWeek) : nil
    )
    return OrbConfiguration(
        content: .me(initials: initials, quota: quota),
        drawingSize: drawingSize,
        badge: meBadge(store),
        reduceMotion: reduceMotion,
        ambient: ambient,
        isKeyWindow: isKeyWindow,
        backingScale: backingScale
    )
}

/// A conversation's planet: Customize's symbol and tint when set (Core identitySymbol / identityTint), else the one
/// assigned by its index (f122).
@MainActor func orbIdentity(of c: Conversation) -> OrbIdentity {
    var identity = OrbIdentity.assigned(c.identityIndex)
    if let symbol = OrbCelestialBody.allCases.first(where: { String(describing: $0) == c.identitySymbol }) { identity.symbol = symbol }
    if let tint = OrbTint.allCases.first(where: { String(describing: $0) == c.identityTint }) { identity.tint = tint }
    return identity
}
