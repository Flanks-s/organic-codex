import AppKit
import Darwin
import QuartzCore

/// A hidden-window fixture intercepts termination; it never enters the normal application launch path.
@MainActor final class WindowLifetimeTestApplication: NSApplication {
    var terminationRequests = 0
    var attentionRequests = 0
    override func requestUserAttention(_ requestType: NSApplication.RequestUserAttentionType) -> Int { attentionRequests += 1; return attentionRequests }
    override func terminate(_ sender: Any?) { terminationRequests += 1 }
}

@MainActor enum AppWindowLifetimeVerification {
    final class Weak<T: AnyObject> { weak var value: T?; init(_ value: T) { self.value = value } }
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func drain(_ seconds: Double = 0.08) {
        autoreleasepool {
            CATransaction.flush()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }
    }
    static func run(to path: String) -> Int32 {
        let application = WindowLifetimeTestApplication.shared as! WindowLifetimeTestApplication
        guard let screen = NSScreen.main else { print("No screen for hidden fixture"); return 2 }
        let output = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var options = Options(); options.mock = true; options.live = false; options.ambient = false
        let domain = ProcessInfo.processInfo.environment["WINDOW_ABRUPT_DOMAIN"] ?? ProcessInfo.processInfo.environment["WINDOW_DEFAULTS_DOMAIN"] ?? "OrganicShell.WindowLifetime." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AppController(options, windowDefaults: defaults, presentsWindows: false)
        let replay = MockReplay(store: app.store); replay.start(live: false)
        if ProcessInfo.processInfo.environment["WINDOW_ABRUPT_DOMAIN"] != nil {
            let w = OrganicWindow(app: app, frame: CGRect(x: 100, y: 100, width: 1000, height: 720), screen: screen,
                                  members: ["A", "B"], normie: true, o: options)
            app.windows = [w]
            w.window.close()
            _exit(0) // Deliberately bypass applicationWillTerminate and Swift defers after the durable close.
        }
        var windows: [Weak<OrganicWindow>] = [], scenes: [Weak<AutoScene>] = []
        var transcripts: [Weak<NativeTranscript>] = [], clocks: [Weak<SceneClock>] = []
        var nativeWindows: [Weak<NSWindow>] = []
        var roots: [Weak<RootView>] = [], areas: [Weak<NSTrackingArea>] = []
        var composers: [Weak<NativeComposer>] = [], headers: [Weak<HeaderIsland>] = []
        var memory: [[String: Any]] = [], failures: [String] = [], checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; if !value { failures.append(message) } }
        let functionalObserverBaseline = app.store.observationCount
        let resourceOnly = ProcessInfo.processInfo.environment["WINDOW_LIFETIME_ONLY"] == "1"
        if !resourceOnly {
            autoreleasepool { AppWindowRestorationVerification.run(app: app, options: options, defaults: defaults, screen: screen, check: check) }
        }
        drain(0.3)
        let functionalRetained = AppWindowRestorationVerification.probes.filter { $0.1.value != nil }.map(\.0)
        check(functionalRetained.isEmpty, "Restored/New Chat graphs release: \(functionalRetained)")
        check(app.store.observationCount == functionalObserverBaseline, "Restoration scenarios withdraw all window store observers")
        app.watchRedEvents()
        if let red = app.store.conversation("background-no-window") {
            red.redEvents += 1; app.store.changed(red)
            check(application.attentionRequests > 0 && app.windows.isEmpty, "6: Red notification requests attention without opening a window")
        }
        let observerBaseline = app.store.observationCount
        for cycle in 0..<20 {
            autoreleasepool {
                let w = OrganicWindow(app: app, frame: CGRect(x: 100, y: 100, width: 1000, height: 720),
                                      screen: screen, members: ["A", "B", "C"], normie: cycle % 2 == 0, o: options)
                app.windows.append(w)
                windows.append(Weak(w)); scenes.append(Weak(w.scene)); clocks.append(Weak(w.scene.clock))
                nativeWindows.append(Weak(w.window))
                transcripts += w.transcriptSessions.transcripts.values.map(Weak.init)
                composers += w.scene.members.compactMap { w.scene.composers.existingComposer(for: $0.id) }.map(Weak.init)
                headers += w.scene.nodes.values.compactMap(\.island).map(Weak.init)
                check(!w.window.isVisible, "Fixture never orders window front, cycle \(cycle)")
                w.root.updateTrackingAreas()
                roots.append(Weak(w.root)); areas += w.root.trackingAreas.map(Weak.init)
                w.watchAmbient(); w.watchAmbient(); w.shell.startModePreparation()
                w.window.close()
            }
            drain()
            let row: [String: Any] = ["cycle": cycle + 1, "residentBytes": residentBytes(),
                "windows": windows.filter { $0.value != nil }.count, "scenes": scenes.filter { $0.value != nil }.count,
                "transcripts": transcripts.filter { $0.value != nil }.count, "clocks": clocks.filter { $0.value != nil }.count,
                "nativeWindows": nativeWindows.filter { $0.value != nil }.count,
                "composers": composers.filter { $0.value != nil }.count, "headers": headers.filter { $0.value != nil }.count,
                "storeObservers": app.store.observationCount,
                "rootViews": roots.filter { $0.value != nil }.count, "trackingAreas": areas.filter { $0.value != nil }.count]
            memory.append(row)
            check(windows.allSatisfy { $0.value == nil }, "OrganicWindow releases by cycle \(cycle + 1)")
            check(scenes.allSatisfy { $0.value == nil }, "AutoScene releases by cycle \(cycle + 1)")
            check(transcripts.allSatisfy { $0.value == nil }, "NativeTranscript releases by cycle \(cycle + 1)")
            check(composers.allSatisfy { $0.value == nil } && headers.allSatisfy { $0.value == nil }, "Composers and header timers release by cycle \(cycle + 1)")
            check(app.store.observationCount == observerBaseline, "Window store observers release by cycle \(cycle + 1)")
            check(roots.allSatisfy { $0.value == nil } && areas.allSatisfy { $0.value == nil }, "Root views and tracking areas release by cycle \(cycle + 1)")
            check(app.windows.isEmpty, "No conversation owner remains after cycle \(cycle + 1)")
        }
        let abruptDomain = domain + ".abrupt"
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--selftest", output.appendingPathComponent("abrupt").path]
        var environment = ProcessInfo.processInfo.environment
        environment["SELFTEST_WINDOW_LIFETIME"] = "1"; environment["WINDOW_ABRUPT_DOMAIN"] = abruptDomain
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do {
            try child.run(); child.waitUntilExit()
            let abruptDefaults = UserDefaults(suiteName: abruptDomain)!
            abruptDefaults.synchronize()
            check(child.terminationStatus == 0 && SavedWindow.load(scope: "mock", defaults: abruptDefaults).count == 1,
                  "2: Last-close record survives immediate _exit without termination callback")
            abruptDefaults.removePersistentDomain(forName: abruptDomain)
        } catch { check(false, "Could not run isolated abrupt-exit fixture: \(error)") }
        drain(1)
        let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
        drain(3)
        let idleCPU = (cpuSeconds() - cpu) / (ProcessInfo.processInfo.systemUptime - start) * 100
        check(idleCPU < 2, "Zero-window idle CPU stays below 2 percent of one core")
        check(application.terminationRequests == 0, "Closing windows never asks application to terminate")
        let report: [String: Any] = ["resourceOnly": resourceOnly, "checks": checks, "findings": failures, "cycles": memory,
            "functionalRetained": functionalRetained, "functionalProbeCount": AppWindowRestorationVerification.probes.count,
            "idleCPUPercent": idleCPU, "terminationRequests": application.terminationRequests,
            "visibleWindows": NSApp.windows.filter(\.isVisible).count]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("window-lifetime.json"))
        }
        print("Window lifetime: \(checks) checks, \(failures.count) findings; idle CPU \(idleCPU)%")
        for failure in failures { print("FINDING: " + failure) }
        return failures.isEmpty ? 0 : 1
    }
}
