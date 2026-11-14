import AppKit
import ObjectiveC

/// Explicit verification entry only. Uses local demo data and never changes system preferences.
@MainActor enum ApplicationAppearanceVerification {
    fileprivate static var presentationScreen: NSScreen?
    static func run(to path: String) -> Int32 {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks = 0, failures: [String] = [], samples: [[String: Any]] = []
        func check(_ passed: Bool, _ message: String) {
            checks += 1
            if !passed { failures.append(message); print("FAIL: " + message) }
        }
        let names: [NSAppearance.Name] = [.accessibilityHighContrastDarkAqua, .darkAqua, .accessibilityHighContrastAqua, .aqua]
        func sample(_ surface: String, _ phase: String, _ explicit: NSAppearance?, _ effective: NSAppearance, _ expected: NSAppearance.Name) {
            let resolved = effective.bestMatch(from: names)
            samples.append(["surface": surface, "phase": phase, "appearance": explicit?.name.rawValue ?? "nil",
                            "effectiveAppearance": effective.name.rawValue, "resolved": resolved?.rawValue ?? "nil",
                            "nativeAppearance": NativeDisplayOptions.appearance?.name.rawValue ?? "nil",
                            "increaseContrast": NativeDisplayOptions.shared.state.increaseContrast,
                            "displayOptionsRevision": NativeDisplayOptions.shared.revision])
            check(resolved == expected, "\(phase): \(surface) resolves to \(expected.rawValue), got \(resolved?.rawValue ?? "nil")")
        }
        func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08)) }
        let display = NativeDisplayOptions.shared
        let original = display.state
        check(NSApp.appearance?.name == NativeDisplayOptions.appearance?.name, "Startup selects Native's current contrast appearance")
        defer { display.setVerificationState(nil); display.refresh() }
        func setContrast(_ enabled: Bool) {
            display.setVerificationState(.init(increaseContrast: enabled, reduceTransparency: original.reduceTransparency))
            print("Contrast injection requested=\(enabled) notified=\(display.state.increaseContrast) revision=\(display.revision)")
            // Publish the injected state in this synchronous entry, before AppKit's event loop starts.
            display.refresh()
        }
        setContrast(false)

        let suite = "OrganicShell.ApplicationAppearanceVerification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        guard let screen = NSScreen.screens.first(where: { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }) else {
            print("Application appearance: built-in display missing; no windows opened")
            return 81
        }
        presentationScreen = screen
        let order = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)))!
        let positionedOrder = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.m1149_makeKeyAndOrderFront(_:)))!
        method_exchangeImplementations(order, positionedOrder)
        defer { method_exchangeImplementations(order, positionedOrder); presentationScreen = nil }
        let settings = NativeSettingsWindowController.install(dataSource: SettingsDemoDataSource(), preferences: SettingsPreferences(defaults: defaults))
        let tools = ToolsWindowController(artifacts: CoreArtifactsController(storage: CoreMemoryStorage()), terminal: CoreTerminalController(), demo: ToolsDemoArtifacts())
        let debug = DebugTools(store: ConversationStore(), mock: nil, initiallyPaused: true)
        defer { NativeSettingsWindowController.uninstall(); tools.dismiss(); tools.window?.close(); debug.shutdown() }
        func position(_ window: NSWindow?) {
            if let window {
                let area = screen.visibleFrame
                window.setFrameOrigin(CGPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
            }
        }
        settings.show(pane: "general"); position(settings.window)
        tools.present(); position(tools.window)
        let debugWindow = debug.controller(.debug)
        debugWindow.toggle(); position(debugWindow.window)
        for window in [settings.window!, tools.window!, debugWindow.window!] {
            check(window.screen === screen, "\(window.title) opens on the built-in display")
        }
        let alert = NSAlert()
        alert.messageText = "Application appearance verification"
        alert.informativeText = "This window uses the application's default appearance."
        alert.addButton(withTitle: "OK")
        alert.layout()
        position(alert.window)
        let menu = NSMenu(title: "Appearance verification")
        menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        let open = NSOpenPanel(), save = NSSavePanel(), popover = NSPopover()
        let content = NSViewController()
        content.view = NSView(frame: CGRect(x: 0, y: 0, width: 180, height: 80))
        popover.contentViewController = content
        popover.behavior = .applicationDefined
        if let anchor = settings.window?.contentView {
            popover.show(relativeTo: CGRect(x: 20, y: 20, width: 1, height: 1), of: anchor, preferredEdge: .maxX)
        }
        defer { popover.close(); alert.window.orderOut(nil) }
        settle()
        func inspect(_ phase: String, _ expected: NSAppearance.Name) {
            check(display.state.increaseContrast == (expected == .accessibilityHighContrastDarkAqua), "\(phase): contrast state injection is active")
            sample("NSApp", phase, NSApp.appearance, NSApp.effectiveAppearance, expected)
            check(NSApp.appearance?.name == expected, "\(phase): NSApp explicitly selects \(expected.rawValue)")
            let windows: [(String, NSWindow?)] = [("Settings", settings.window), ("Tools", tools.window), ("Debug", debugWindow.window), ("NSAlert", alert.window), ("NSOpenPanel", open), ("NSSavePanel", save)]
            for (name, window) in windows {
                if let window { sample(name, phase, window.appearance, window.effectiveAppearance, expected) }
                else { check(false, "\(phase): \(name) window exists") }
            }
            sample("NSMenu", phase, menu.appearance, menu.effectiveAppearance, expected)
            sample("NSPopover", phase, popover.appearance, popover.effectiveAppearance, expected)
        }
        inspect("standard", .darkAqua)
        if ProcessInfo.processInfo.environment["VERIFY_APPLICATION_APPEARANCE_HOLD"] == "1" {
            alert.window.makeKeyAndOrderFront(nil)
            let windows = ["settings": settings.window!.windowNumber, "tools": tools.window!.windowNumber,
                           "debug": debugWindow.window!.windowNumber, "alert": alert.window.windowNumber]
            try! JSONSerialization.data(withJSONObject: windows, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("windows.json"))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 15))
        }
        setContrast(true)
        settle()
        inspect("increase-contrast", .accessibilityHighContrastDarkAqua)
        setContrast(false)
        settle()
        inspect("contrast-restored", .darkAqua)
        let report: [String: Any] = ["checks": checks, "failures": failures, "samples": samples,
                                    "arguments": CommandLine.arguments, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "screen": ["name": screen.localizedName, "maximumFramesPerSecond": screen.maximumFramesPerSecond,
                                               "backingScaleFactor": screen.backingScaleFactor]]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("verification.json"))
        let receipt = ["display": "\(screen.localizedName) · \(screen.maximumFramesPerSecond) Hz · \(screen.backingScaleFactor)×"]
        try! JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("receipt.json"))
        let text = "Application appearance: \(checks) checks / \(failures.count) failures\n" + failures.joined(separator: "\n") + "\n"
        try! text.write(to: directory.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        print(text)
        return failures.isEmpty ? 0 : 1
    }
}

fileprivate extension NSWindow {
    /// Installed only while the verification runs, before any window is ordered onscreen.
    @objc dynamic func m1149_makeKeyAndOrderFront(_ sender: Any?) {
        let area = ApplicationAppearanceVerification.presentationScreen!.visibleFrame
        setFrameOrigin(CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
        m1149_makeKeyAndOrderFront(sender)
    }
}
