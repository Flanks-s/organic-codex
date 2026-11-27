import AppKit

@MainActor enum DebugAppReset {
    static private(set) var restarting = false

    static func clearMock(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: SavedWindow.key("mock"))
        defaults.synchronize()
    }

    static func arguments(_ original: [String]) -> [String] {
        var result: [String] = []
        var skip = false
        for argument in original {
            if skip {
                skip = false
            } else if argument == "--demo-input" {
                skip = true
            } else if argument != "--debug-reset" {
                result.append(argument)
            }
        }
        result.append("--debug-reset")
        return result
    }

    static func perform(
        allowed: Bool,
        defaults: UserDefaults = .standard,
        original: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        open: (URL, NSWorkspace.OpenConfiguration, @escaping @MainActor @Sendable (Bool) -> Void) -> Void = {
            url, config, done in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                let success = app != nil && error == nil
                Task { @MainActor in done(success) }
            }
        },
        terminate: @escaping @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }
    ) {
        guard allowed, !restarting else { return }
        clearMock(defaults: defaults)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments(original)
        configuration.environment = environment
        open(Bundle.main.bundleURL, configuration) { success in
            guard success else { return }
            restarting = true
            terminate()
        }
    }
}
