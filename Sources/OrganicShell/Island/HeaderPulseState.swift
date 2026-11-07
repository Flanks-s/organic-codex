import Foundation

/// IslandPulse's event clock and interruptible geometry, independent of AppKit and wall-clock timers.
struct HeaderPulseState {
    enum Mode: String, CaseIterable { case compact, bloom, action, expanded }
    static let dwell = 0.28, grace = 0.14, liveEvery = 0.75, timeExtra = 18.0
    private(set) var event: ConversationNotice?
    private(set) var pending: [ConversationNotice] = []
    private(set) var remaining = 0.0
    private(set) var hovering = false, inside = false, pinned = false, focused = false
    private(set) var enabled = false
    private(set) var revision = 0
    private(set) var acceptedRevision = 0
    private var hoverAge = 0.0, liveAge = 0.0
    private var cursor: Int?
    private var candidateText: String?
    var mode: Mode {
        if event?.buttons.isEmpty == false || (pinned && !pending.isEmpty) { return .action }
        if pinned || hovering || focused { return .expanded }
        return event == nil ? .compact : .bloom
    }
    var actionEvent: ConversationNotice? { event?.buttons.isEmpty == false ? event : pinned ? pending.first : nil }

    /// Initial mounting consumes the cursor, not the old journal. Unanswered requests can still be reopened.
    mutating func ingest(_ snapshot: ConversationNoticeSnapshot) {
        pending = snapshot.pending
        if let request = event?.requestID, !pending.contains(where: { $0.requestID == request }) {
            event = nil; remaining = 0
        }
        if cursor == nil { cursor = snapshot.journal.last?.id ?? 0; enabled = !pending.isEmpty; return }
        for notice in snapshot.journal where notice.id > cursor! {
            // A request and its response may share one UI publication. Never resurrect a retired action.
            if let request = notice.requestID, !pending.contains(where: { $0.requestID == request }) { continue }
            receive(notice)
        }
        cursor = max(cursor ?? 0, snapshot.journal.last?.id ?? 0)
        if let notice = snapshot.journal.first(where: { $0.id == event?.id }), notice.text != event?.text {
            candidateText = notice.text
        }
    }
    @discardableResult mutating func receive(_ notice: ConversationNotice) -> Bool {
        revision += 1
        guard event?.urgent != true || notice.urgent else { return false }
        acceptedRevision += 1
        event = notice; remaining = notice.hold; liveAge = 0; candidateText = nil
        enabled = true
        return true
    }
    mutating func hover(_ value: Bool) { guard value != inside else { return }; inside = value; hoverAge = 0 }
    mutating func focus(_ value: Bool) { focused = value }
    mutating func togglePin() { pinned.toggle() }
    mutating func dismiss() { event = nil; remaining = 0; pinned = false; hovering = false; inside = false; focused = false }
    mutating func tick(_ dt: Double) {
        hoverAge += dt
        if inside && !hovering && hoverAge + 1e-9 >= Self.dwell { hovering = true }
        if !inside && hovering && hoverAge + 1e-9 >= Self.grace { hovering = false }
        if event != nil {
            liveAge += dt
            if liveAge + 1e-9 >= Self.liveEvery, let text = candidateText {
                event?.text = text; candidateText = nil; liveAge = 0
            }
            // Hover freezes the event immediately, including its dwell. A short exit retains the expanded pose.
            if !inside && !pinned && !focused {
                remaining -= dt
                if remaining <= 0 { event = nil; remaining = 0 }
            }
        }
    }
}

/// Board integrator, including its 240 Hz semi-implicit Euler step and rest thresholds.
struct PulseSpring {
    var x: Double, v = 0.0, target: Double
    var omega = 16.0, damping = 0.8
    init(_ value: Double) { x = value; target = value }
    mutating func aim(_ value: Double, _ recipe: (Double, Double)) {
        guard value != target else { return }
        target = value; omega = 2 * .pi / recipe.0; damping = recipe.1
    }
    mutating func step(_ dt: Double) {
        guard dt > 0 else { return }
        let count = max(1, Int(ceil(dt * 240))), h = dt / Double(count)
        for _ in 0..<count {
            v += (-omega * omega * (x - target) - 2 * damping * omega * v) * h
            x += v * h
        }
        if abs(x - target) < 0.004 && abs(v) < 0.02 { x = target; v = 0 }
    }
    var busy: Bool { x != target || v != 0 }
}

struct PulseContentPhase {
    var k = 0.0, target = 0.0, delay = 0.0
    mutating func show(_ value: Double, delay: Double = 0) { target = value; self.delay = value > 0 ? delay : 0 }
    mutating func step(_ dt: Double) {
        if delay > 0 { delay -= dt }
        else if k != target { k = target > k ? min(target, k + dt / 0.11) : max(target, k - dt / 0.07) }
    }
    var opacity: Double { let t = min(1, max(0, k)); return t * t * (3 - 2 * t) }
    var blur: Double { (1 - opacity) * 8 }
    var scale: Double { 0.97 + 0.03 * opacity }
    var busy: Bool { k != target || delay > 0 }
}

struct PulseTextSwap {
    private(set) var text = ""
    private var next: String?
    private(set) var k = 1.0
    mutating func put(_ value: String, immediate: Bool = false) {
        if immediate || text.isEmpty { text = value; next = nil; k = 1; return }
        guard (next ?? text) != value else { return }; next = value
    }
    mutating func step(_ dt: Double) {
        if let next {
            k -= dt / 0.06
            if k <= 0 { k = 0; text = next; self.next = nil }
        } else if k < 1 { k = min(1, k + dt / 0.09) }
    }
    var opacity: Double { let t = min(1, max(0, k)); return t * t * (3 - 2 * t) }
}

struct HeaderPulseMotion {
    private(set) var width: PulseSpring, height: PulseSpring, radius: PulseSpring, kick = PulseSpring(1)
    private(set) var mode = HeaderPulseState.Mode.compact
    private(set) var layers: [HeaderPulseState.Mode: PulseContentPhase] = [:]
    private(set) var layerWidths: [HeaderPulseState.Mode: Double] = [:]
    var columnWidth: Double, compactWidth: Double, compactHeight: Double
    init(columnWidth: Double, compactWidth: Double, compactHeight: Double, clock: Bool = false) {
        self.columnWidth = columnWidth; self.compactWidth = compactWidth; self.compactHeight = compactHeight
        let initialWidth = compactWidth + (clock ? HeaderPulseState.timeExtra : 0)
        width = PulseSpring(initialWidth); height = PulseSpring(compactHeight); radius = PulseSpring(compactHeight / 2)
        kick.omega = 2 * .pi / 0.34; kick.damping = 0.55
        for mode in HeaderPulseState.Mode.allCases {
            layers[mode] = .init(k: mode == .compact ? 1 : 0, target: mode == .compact ? 1 : 0)
            layerWidths[mode] = initialWidth
        }
    }
    mutating func receiveKick(rebloom: Bool) { kick.v += 1.1; if rebloom { width.v += 70 } }
    mutating func retarget(_ next: HeaderPulseState.Mode, clock: Bool) {
        let w: Double, h: Double, r: Double
        switch next {
        case .compact: (w, h, r) = (min(columnWidth - 24, compactWidth + (clock ? HeaderPulseState.timeExtra : 0)), compactHeight, compactHeight / 2)
        case .bloom: (w, h, r) = (max(compactWidth, min(288, columnWidth - 24)), 58, 29)
        case .action: (w, h, r) = (max(compactWidth, min(292, columnWidth - 24)), 86, 26)
        case .expanded: (w, h, r) = (max(compactWidth, min(336, columnWidth - 24)), 116, 24)
        }
        let opening = h > height.target
        width.aim(w, opening ? (0.28, 0.74) : (0.42, 0.70))
        height.aim(h, opening ? (0.36, 0.78) : (0.34, 0.88))
        radius.aim(r, opening ? (0.36, 0.78) : (0.34, 0.88))
        if next != mode {
            for key in HeaderPulseState.Mode.allCases { layers[key]?.show(key == next ? 1 : 0, delay: next == .compact ? 0.14 : 0.06) }
            mode = next
        }
        layerWidths[next] = w
    }
    mutating func step(_ dt: Double, reduced: Bool = false) {
        if reduced {
            width.x = width.target; width.v = 0; height.x = height.target; height.v = 0
            radius.x = radius.target; radius.v = 0; kick.x = 1; kick.v = 0
            for key in HeaderPulseState.Mode.allCases { let target=layers[key]?.target ?? 0; layers[key]?.k = target; layers[key]?.delay = 0 }
            return
        }
        width.step(dt); height.step(dt); radius.step(dt); kick.step(dt)
        for key in HeaderPulseState.Mode.allCases { layers[key]?.step(dt) }
    }
    var busy: Bool { width.busy || height.busy || radius.busy || kick.busy || layers.values.contains(where: \.busy) }
}
