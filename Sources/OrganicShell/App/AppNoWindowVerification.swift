import AppKit

/// Exercises the installed app menu and Settings callbacks without launching or creating any window.
@MainActor enum AppNoWindowVerification {
    static func run(to path: String) -> Int32 {
        _ = NSApplication.shared
        let app = AppController(Options())
        let domain = "OrganicShell.M1120." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let originalMenu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = originalMenu
            defaults.removePersistentDomain(forName: domain)
            NativeSettingsWindowController.uninstall()
        }
        let preferences = SettingsPreferences(defaults: defaults)
        app.installSettings(preferences: preferences)
        app.installMainMenu()
        func items(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
        }
        let all = items(NSApp.mainMenu)
        func item(_ command: NormieCommand) -> NSMenuItem? {
            all.first { $0.representedObject as? String == command.rawValue }
        }
        if let probe = ProcessInfo.processInfo.environment["NO_WINDOW_PROBE"] {
            print("no-window probe: \(probe), conversationWindows=\(app.windows.count), nativeWindows=\(NSApp.windows.count)")
            fflush(stdout)
            if probe == "shortcuts" {
                // This invokes SettingsSession.onLocalChange -> settingChanged -> applyShortcuts.
                preferences.set("keys.newChat", .string("⌃⌥n"))
                app.applyShortcuts()
            } else if let newChat = item(.newChat) {
                _ = app.menus.validateMenuItem(newChat)
            } else { return 1 }
            print("no-window probe survived")
            return 0
        }
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures.append(label) }
        }
        check(app.windows.isEmpty && NSApp.windows.isEmpty, "Fixture creates no windows")
        check(app.front == nil, "No conversation command target")
        check(app.settings?.window == nil, "Settings session installs without a window")
        check(app.core == nil && app.live == nil, "Fixture never connects to Core")
        let global: Set<NormieCommand> = [.settings, .shortcuts, .artifacts, .browser, .appshots, .newChat]
        for entry in all {
            guard let raw = entry.representedObject as? String, let command = NormieCommand(rawValue: raw) else { continue }
            check(app.menus.validateMenuItem(entry) == global.contains(command), "No-window validation: " + raw)
            check(entry.target === app.menus, "Application retains menu target: " + raw)
        }
        preferences.set("keys.newChat", .string("⌃⌥n"))
        check(item(.newChat)?.keyEquivalent == "n" && item(.newChat)?.keyEquivalentModifierMask == [.control, .option],
              "Settings callback updates New Chat shortcut without a window")
        preferences.set("keys.settings", .string("⌃,"))
        check(item(.settings)?.keyEquivalent == "," && item(.settings)?.keyEquivalentModifierMask == [.control],
              "Settings callback updates application shortcut")
        preferences.set("keys.undo", .string("⌃z"))
        let undo = all.first { $0.action == Selector(("undo:")) }
        check(undo?.keyEquivalent == "z" && undo?.keyEquivalentModifierMask == [.control], "Undo shortcut updates without a conversation")
        let numbers = all.filter { $0.identifier?.rawValue.hasPrefix("number.") == true }
        check(numbers.count == 9, "All number shortcuts are present")
        preferences.set("numberShortcuts", .string("off"))
        check(numbers.allSatisfy { $0.keyEquivalent.isEmpty }, "Number shortcuts switch off without a conversation")
        preferences.set("numberShortcuts", .string("on"))
        check(numbers.allSatisfy { $0.keyEquivalent == String($0.tag + 1) }, "Number shortcuts switch on without a conversation")
        preferences.set("keys.newChat", .string(""))
        check(item(.newChat)?.keyEquivalent.isEmpty == true, "New Chat can clear its shortcut without a window")
        // These events exercise AppKit's menu entry only; they are not evidence of physical keyboard delivery.
        let installedMenu = NSApp.mainMenu
        let productionPerform = app.menus.perform
        var routed: [NormieCommand] = []
        app.menus.perform = { command, _ in routed.append(command) }
        preferences.set("keys.newChat", .string("⌘n"))
        func key(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                             characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        }
        check(NSApp.keyWindow == nil, "Menu routing has no key window")
        check(NSApp.mainMenu === installedMenu, "Settings updates preserve the installed main menu")
        check(installedMenu?.performKeyEquivalent(with: key(.command)) == true && routed == [.newChat],
              "Native menu routes synthetic Cmd+N through fire with no window")
        if let entry = item(.newChat), let action = entry.action {
            check(NSApp.sendAction(action, to: entry.target, from: entry) && routed == [.newChat, .newChat],
                  "NSApplication target/action routes New Chat without a responder window")
        } else { check(false, "New Chat retains its target/action") }
        preferences.set("keys.newChat", .string("⌃⌥n"))
        check(installedMenu?.performKeyEquivalent(with: key([.control, .option])) == true && routed.count == 3,
              "Native menu routes the configured replacement shortcut")
        preferences.set("keys.newChat", .string(""))
        check(installedMenu?.performKeyEquivalent(with: key(.command)) == false && routed.count == 3,
              "An explicitly cleared shortcut cannot route Cmd+N")
        check(NSApp.mainMenu === installedMenu && item(.newChat)?.target === app.menus,
              "Installed main menu and retained builder survive shortcut updates")
        app.menus.perform = productionPerform
        // Disabled selectors must never manufacture a conversation window, including direct dispatch.
        for command in NormieCommand.allCases where !global.contains(command) { app.menus.perform(command, 0) }
        app.restoreLive()
        check(app.animatedLayers().isEmpty, "Diagnostics tolerate zero conversation windows")
        check(app.windows.isEmpty && NSApp.windows.isEmpty, "Disabled commands and late restore create no windows")
        check(app.core == nil && app.live == nil, "No Core connection after callbacks")
        let report = "App no-window: \(checks) checks, \(failures.count) findings\n" + failures.joined(separator: "\n")
        let output = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try report.write(to: output.appendingPathComponent("no-window.txt"), atomically: true, encoding: .utf8)
        } catch { print(error); return 1 }
        print(report)
        return failures.isEmpty ? 0 : 1
    }
}
