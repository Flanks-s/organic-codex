import AppKit

/// Compatibility name: Open in and CoreService share one implementation of the ownership proof.
typealias NormieLocalIdentity = CoreLocalIdentity

enum NormieOpenDecision: Equatable { case prototype(String), denied(String), open(URL, bundle: String) }

@MainActor final class NormieOpenIn {
    static let applications = [("Finder", "com.apple.finder"), ("Terminal", "com.apple.Terminal"),
                               ("Xcode", "com.apple.dt.Xcode"), ("Visual Studio Code", "com.microsoft.VSCode")]
    let store: ConversationStore
    var selected: () -> Conversation?
    var notice: (String) -> Void
    var identity: NormieLocalIdentity?
    init(store: ConversationStore, selected: @escaping () -> Conversation?, notice: @escaping (String) -> Void) {
        self.store = store; self.selected = selected; self.notice = notice
    }
    func decision(application: String, directoryExists: (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }) -> NormieOpenDecision {
        guard let c = selected(), !c.archived else { return .denied("Select a conversation first.") }
        let place = store.project(c.projectID)?.name ?? c.title
        guard store.usesLiveCore else { return .prototype("Would open “\(place)” in \(application) (prototype)") }
        guard identity?.verified == true, store.device(c.deviceID)?.isLocal == true else {
            return .denied("This project belongs to the connected Core. Open its directory on that machine.")
        }
        guard let path = c.cwd ?? store.project(c.projectID)?.path, path.hasPrefix("/"), !path.contains("\n"), directoryExists(path) else {
            return .denied("The working directory is not available on this Mac.")
        }
        guard let bundle = Self.applications.first(where: { $0.0 == application })?.1 else { return .denied("Unsupported application.") }
        return .open(URL(fileURLWithPath: path, isDirectory: true), bundle: bundle)
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (name, bundle) in Self.applications {
            let item = NormieMenuItem(name, enabled: selected() != nil) { [weak self] in self?.open(application: name) }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = NSSize(width: 16, height: 16); item.image = icon
            }
            menu.addItem(item)
        }
        return menu
    }
    func open(application: String) {
        switch decision(application: application) {
        case .prototype(let message), .denied(let message): notice(message)
        case .open(let directory, let bundle):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { notice("\(application) is not installed on this Mac."); return }
            NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                if let message = error?.localizedDescription { Task { @MainActor [weak self] in self?.notice(message) } }
            }
        }
    }
}
