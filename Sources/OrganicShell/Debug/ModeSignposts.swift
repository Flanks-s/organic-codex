import AppKit
import QuartzCore
import os.signpost

/// Observation only: no flush, transaction, animation, layout, or dispatch hop is added to a switch.
/// Receipt collection is opt-in via --output; Instruments can independently enable this OSLog.
@MainActor enum ModeSignposts {
    /// The same opt-out controls production display links and explicit mode animations.
    static let requestsHighFrameRate = ProcessInfo.processInfo.environment["M11_MODE_FRAME_RANGE"] != "0"
    static func frameRange(_ link:CADisplayLink) {
        if requestsHighFrameRate {link.preferredFrameRateRange=CAFrameRateRange(minimum:80,maximum:120,preferred:120)}
    }
    static func frameRange(_ animation:CAAnimation) {
        if requestsHighFrameRate {animation.preferredFrameRateRange=CAFrameRateRange(minimum:80,maximum:120,preferred:120)}
    }
    static let log = OSLog(subsystem: "local.organic-shell", category: "ModeSwitch")
    static var receiptsEnabled = false
    private static let loggingAllowed = ProcessInfo.processInfo.environment["M11_MODE_SIGNPOSTS"] != "0"
    static var enabled: Bool { receiptsEnabled || (loggingAllowed && log.signpostsEnabled) }
    private static var sequence: UInt64 = 0
    private static var rows: [Row] = []
    private static var dropped = 0
    private static var frameCounts:[String:Int]=[:]
    static var current: Trace?
    private static var input: Trace?
    private static var arrival: (event: NSEvent, time: Double)?

    enum Edge: String { case begin, end, event }
    struct Row {
        let id: UInt64, phase: String, edge: String, time: Double, emitted: Double, detail: String
        let eventTime: Double?, timestamp: Double?, target: Double?
        var json: [String: Any] {
            var result: [String: Any] = ["id": id, "phase": phase, "edge": edge, "time": time, "emitTime": emitted, "detail": detail]
            if let eventTime { result["eventTimestamp"] = eventTime }
            if let timestamp { result["timestamp"] = timestamp }
            if let target { result["targetTimestamp"] = target }
            return result
        }
    }

    @MainActor final class Trace: NSObject {
        let id: UInt64
        let signpostID: OSSignpostID
        private var observers: [CFRunLoopObserver] = []
        private var observingDisplay = false
        private var returned = false, commitBegan = false, committed = false, displayed = false
        private var animated = false
        private var deadline = 0.0

        override init() {
            ModeSignposts.sequence += 1
            id = ModeSignposts.sequence
            signpostID = OSSignpostID(log: ModeSignposts.log)
            super.init()
        }

        func record(_ phase: StaticString, _ edge: Edge = .event, detail: String = "", at: Double? = nil,
                    event: Double? = nil, timestamp: Double? = nil, target: Double? = nil) {
            let emitted = CACurrentMediaTime()
            let time = at ?? emitted
            // emit aligns xctrace to the receipt; media may be backdated to event arrival or function entry.
            let type: OSSignpostType = edge == .begin ? .begin : edge == .end ? .end : .event
            if ModeSignposts.loggingAllowed && ModeSignposts.log.signpostsEnabled {
                os_signpost(type, log: ModeSignposts.log, name: phase, signpostID: signpostID,
                            "m11 id=%llu phase=%{public}s edge=%{public}s media=%.9f emit=%.9f event=%.9f timestamp=%.9f target=%.9f detail=%{public}s",
                            id, String(describing: phase), edge.rawValue, time, emitted, event ?? -1,
                            timestamp ?? -1, target ?? -1, detail)
            }
            if ModeSignposts.receiptsEnabled {
                let name=String(describing:phase)
                if ["ModeOrbFrame","ModeAvatarFrame","ModeComposerFrame","ModeFlightTick","ModeContentCommit"].contains(name) {ModeSignposts.frameCounts[name,default:0]+=1;return}
                // Bound memory during a long manual session. No JSON serialization on the input/animation path.
                if ModeSignposts.rows.count < 32768 {
                    ModeSignposts.rows.append(Row(id: id, phase: String(describing: phase), edge: edge.rawValue,
                                                 time: time, emitted: emitted, detail: detail, eventTime: event, timestamp: timestamp, target: target))
                } else { ModeSignposts.dropped += 1 }
            }
        }

        func firstAnimation(_ detail: String) {
            guard !animated else { return }; animated = true
            record("FirstAnimation", detail: detail)
        }

        /// Bracket the FIRST outer run-loop commit opportunity after setMode returns, in common modes.
        /// CA has no public commit-start/end callback. These are proxies, not a measured CA commit duration.
        /// A CATransaction completion waits for animations to finish and would measure the wrong thing.
        func observe() {
            observingDisplay = true
            deadline = CACurrentMediaTime() + 5
            for order in [CFIndex.min, CFIndex.max] {
                let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, order) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self, self.returned, !self.committed else { return }
                        if order == CFIndex.min {
                            self.commitBegan = true
                            self.record("FirstCommitProxy", .begin, detail: "runloop.beforeWaiting.lowOrder")
                        } else if self.commitBegan {
                            self.committed = true
                            self.record("FirstCommitProxy", .end, detail: "runloop.beforeWaiting.highOrder")
                            self.removeObservers()
                        }
                    }
                }!
                observers.append(observer)
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
        }

        func didReturn() { returned = true }

        /// Read the production ModeFlight link; do not add another display clock or change its rate.
        func display(_ sender: CADisplayLink) {
            guard observingDisplay else { return }
            if !displayed {
                displayed = true
                record("FirstDisplayLink", detail: "production ModeFlight callback; target is a prediction, not proof of motion",
                       timestamp: sender.timestamp, target: sender.targetTimestamp)
            }
            if committed {
                record("FirstDisplayLinkAfterCommitProxy", detail: "presentation estimate only",
                       timestamp: sender.timestamp, target: sender.targetTimestamp)
                stopObservation()
            } else if CACurrentMediaTime() >= deadline {
                record("ObservationTimeout", detail: "no commit opportunity observed within 5 seconds")
                stopObservation()
            }
        }

        private func removeObservers() {
            for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observers.removeAll()
        }

        func stopObservation(reason: String? = nil) {
            if let reason, observingDisplay || !observers.isEmpty { record("ObservationStopped", detail: reason) }
            observingDisplay = false; removeObservers()
        }
    }

    static var receipt: [String: Any] {
        ["frameEventCounts":frameCounts,"version": 1, "clock": "CACurrentMediaTime seconds", "dropped": dropped, "events": rows.map(\.json),
         "commitScope": "first beforeWaiting observer bracket after setMode returns; proxy only",
         "displayScope": "first production ModeFlight display-link callback and first after commit proxy; targetTimestamp is predicted, not observed motion"]
    }

    static func withTrace<T>(_ trace: Trace?, _ body: () throws -> T) rethrows -> T {
        let old = current; current = trace; defer { current = old }
        return try body()
    }

    static func measure<T>(_ phase: StaticString, detail: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        guard let trace = current else { return try body() }
        let text = detail()
        trace.record(phase, .begin, detail: text)
        defer { trace.record(phase, .end, detail: text) }
        return try body()
    }

    /// Idle preparation is observable even though it has no input event and is outside a SetMode trace.
    static func operation<T>(_ phase: StaticString, detail: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let trace = Trace()
        return try withTrace(trace) { try measure(phase, detail: detail, body) }
    }

    static func withInput<T>(_ source: String, event: NSEvent? = nil, useCurrentEvent: Bool = true, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        if let input {
            input.record("InputAction", detail: source)
            return try body()
        }
        let trace = Trace(), e = event ?? (useCurrentEvent ? NSApp.currentEvent : nil)
        let arrived = arrival.flatMap { a in e === a.event ? a.time : nil }
        trace.record("Input", detail: source, at: arrived, event: e?.timestamp)
        input = trace; defer { input = nil }
        return try body()
    }

    static func beginSwitch(from: @autoclosure () -> String, to: @autoclosure () -> String, window: @autoclosure () -> Int, animated: Bool, enteredAt: Double? = nil) -> Trace? {
        guard enabled else { return nil }
        let trace = input ?? Trace()
        if input == nil { trace.record("Input", detail: "programmatic; no NSEvent", at: enteredAt) }
        trace.record("SetMode", .begin, detail: "from=\(from()) to=\(to()) window=\(window()) animated=\(animated)", at: enteredAt)
        return trace
    }

    /// Called by the NSApplication subclass before super.sendEvent; the event itself is never consumed or changed.
    static func dispatch<T>(_ event: NSEvent, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let old = arrival; arrival = (event, CACurrentMediaTime()); defer { arrival = old }
        if event.type == .keyDown, event.keyCode == 1,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command] {
            return withInput("keyboard.sendEvent.ctrl-cmd-s", event: event, body)
        }
        return body()
    }
}

/// Uses AppKit's original event and shortcut dispatch. No global monitor or CGEvent injection.
@MainActor final class ModeProbeApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        ModeSignposts.dispatch(event) { super.sendEvent(event) }
    }
}
