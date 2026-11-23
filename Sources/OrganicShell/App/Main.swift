import AppKit

// Organic Shell v2 · first scene: Organic Auto brief↔full with the dock (spec §12, step 1).




@main enum Main {
    @MainActor static func main() {
        let o = Options.parse()
        let appearanceVerification = ProcessInfo.processInfo.environment["VERIFY_APPLICATION_APPEARANCE"]
        // Test runs only (--selftest, appearance verification, or --demo-input with --output): a crash ends in _exit(70) with its trace in
        // the run's output folder instead of the system crash dialog, which takes the front from every later run (11-06 on
        // the MBA). Hand runs keep the normal system crash report. CrashGuard.swift, Claude.
        if let dir = appearanceVerification ?? o.selftest ?? (o.demoInput != nil ? o.output : nil) { CrashGuard.install(directory: dir) }
        // --launch-plan: what this command line would start, printed before anything is created (no Core, no window).
        if CommandLine.arguments.contains("--launch-plan") {
            print("launch-plan liveCore=\(o.usesLiveCore) mock=\(o.mock) paused=\(o.mockPaused) playback=\(o.live) labs=\(o.labs) automated=\(o.automated)")
            exit(0)
        }
        // The first shared access must create the subclass required by the lifetime fixture.
        let app: NSApplication
        if o.selftest != nil, ProcessInfo.processInfo.environment["SELFTEST_WINDOW_LIFETIME"] == "1" {
            app = WindowLifetimeTestApplication.shared
        } else {
            app = ModeProbeApplication.shared
        }
        // Keep all AppKit surfaces on Native's dark appearance, including live contrast changes.
        app.appearance = NativeDisplayOptions.appearance
        NativeDisplayOptions.shared.observe {
            app.appearance = NativeDisplayOptions.appearance
        }
        if let dir = o.selftest, ProcessInfo.processInfo.environment["SELFTEST_WINDOW_LIFETIME"] == "1" {
            exit(AppWindowLifetimeVerification.run(to: dir))
        }
        if let dir = o.selftest, ProcessInfo.processInfo.environment["SELFTEST_NO_WINDOW"] == "1" {
            exit(AppNoWindowVerification.run(to: dir))
        }
        if let dir = o.selftest {
            exit(SelfTest.run(to: dir, size: CGSize(width: o.width, height: o.height)))
        }
        if let dir = o.offscreen {
            Offscreen.run(to: dir, hz: o.offscreenHz, size: CGSize(width: o.width, height: o.height), target: o.offscreenTarget)
            return
        }
        ModeSignposts.receiptsEnabled = o.output != nil
        app.setActivationPolicy(.regular)
        if let dir = appearanceVerification { exit(ApplicationAppearanceVerification.run(to: dir)) }
        let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu(title: "Organic Shell")
        sub.addItem(NSMenuItem(title: "Quit Organic Shell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = sub; menu.addItem(item); app.mainMenu = menu
        let controller = AppController(o)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
