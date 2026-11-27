import AppKit
import QuartzCore

/// Standalone instrumentation check. Does not run Main, an app event loop, Core, or create an NSWindow.
@main @MainActor enum ProbeCheck {
    static func main() throws {
        _ = ModeProbeApplication.shared
        ModeSignposts.receiptsEnabled = true
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                    timestamp: CACurrentMediaTime(), windowNumber: 0, context: nil,
                                    characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool) {
            precondition(condition()); checks += 1
        }
        if ProcessInfo.processInfo.environment["M11_MODE_SIGNPOSTS"] == "0" {
            ModeSignposts.receiptsEnabled = false
            var evaluated = false
            func label() -> String { evaluated = true; return "unused" }
            check(!ModeSignposts.enabled)
            check(ModeSignposts.beginSwitch(from: label(), to: label(), window: 0, animated: true) == nil)
            check(!evaluated)
            check((ModeSignposts.receipt["events"] as! [[String: Any]]).isEmpty)
            ModeSignposts.receiptsEnabled = true
        }
        check(NSApp is ModeProbeApplication)
        ModeSignposts.dispatch(event) {
            ModeSignposts.withInput("fixture.menu.action", event: event) {
                let trace = ModeSignposts.beginSwitch(from: "organic", to: "normie", window: 0, animated: true)!
                ModeSignposts.withTrace(trace) {
                    check(ModeSignposts.current === trace)
                    ModeSignposts.measure("FixturePhase") {}
                    trace.firstAnimation("fixture only")
                    trace.firstAnimation("must not be repeated")
                    trace.record("SetMode", .end)
                }
            }
        }
        check(ModeSignposts.current == nil)
        let log = ModeSignposts.receipt["events"] as! [[String: Any]]
        check(log.filter { $0["phase"] as? String == "Input" }.count == 1)
        check(log.filter { $0["phase"] as? String == "FirstAnimation" }.count == 1)
        check(log.first?["eventTimestamp"] as? Double == event.timestamp)
        check(Set(log.compactMap { $0["id"] as? UInt64 }).count == 1)
        check(NSApp.windows.isEmpty)

        // Fixed artificial timestamps exercise the production receipt writer, not a real display or animation.
        let fixture = ModeSignposts.Trace()
        let t = 4096.0 // Synthetic receipt origin; keep uptime out of timestamp subtraction.
        fixture.record("Input", detail: "synthetic.offscreen.menu; NOT a live measurement", at: t, event: t - 0.002)
        fixture.record("SetMode", .begin, detail: "from=organic to=normie window=0 animated=true SYNTHETIC", at: t + 0.001)
        fixture.record("PrepareNormie", .begin, at: t + 0.002)
        fixture.record("PrepareNormie", .end, at: t + 0.180)
        fixture.record("FirstAnimation", at: t + 0.181)
        fixture.record("SetMode", .end, at: t + 0.190)
        fixture.record("FirstCommitProxy", .begin, at: t + 0.191)
        fixture.record("FirstCommitProxy", .end, at: t + 0.194)
        fixture.record("FirstDisplayLink", at: t + 0.200, timestamp: t + 0.200, target: t + 0.216666667)
        fixture.record("FirstDisplayLinkAfterCommitProxy", at: t + 0.200, timestamp: t + 0.200, target: t + 0.216666667)
        var receipt = ModeSignposts.receipt
        receipt["events"] = (receipt["events"] as! [[String: Any]]).filter { $0["id"] as? UInt64 == fixture.id }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/m11-probe-receipt.json")
        try JSONSerialization.data(withJSONObject: ["synthetic": true, "modeSwitchLog": receipt], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("M11 probe: \(checks) checks, 0 findings; no windows. Synthetic receipt: \(output.path)")
    }
}
