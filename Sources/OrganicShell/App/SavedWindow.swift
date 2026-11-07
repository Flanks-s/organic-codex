import AppKit

/// What a window was when the app quit (f003; product LocalPresentationState's window part): where it was, which mode,
/// its working set in order and the one it showed. Conversations' own state (drafts, attachments) lives with them.
struct SavedWindow: Codable {
    var frame: [Double]
    var normie: Bool
    var members: [String]
    var current: String
    /// Collapsed when the app quit: `frame`, `normie` and `current` are the window's own (to restore to), `selection`
    /// what the strip showed (COLLAPSE-SPEC §6: collapsed, collapseSelection, normalFrame).
    var collapsed: Bool? = nil
    var selection: String? = nil
    /// Organic's arrangement (product WindowState layout, split, splitFocus): Focused, with these in its split and
    /// `splitFocus`'s editor holding the keyboard.
    var layout: String? = nil
    var split: [String]? = nil
    var splitFocus: String? = nil
    /// New Chat not sent yet (WindowState composingNew, draft, project, device). Its files wait on the input sidecar (f107).
    var composingNew: Bool? = nil
    var draft: String? = nil
    var project: String? = nil
    var device: String? = nil

    /// One record per data source (product LocalPresentationState is endpoint-scoped): the mock's windows never open on a
    /// Live Core's conversations, nor one Core's on another's.
    static func key(_ scope: String) -> String { "organic.windows." + scope }

    @MainActor @discardableResult static func save(_ windows: [OrganicWindow], scope: String, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(windows.map(make)) else { return false }
        defaults.set(data, forKey: key(scope))
        return defaults.synchronize()
    }

    /// What `w` is now.
    @MainActor static func make(_ w: OrganicWindow) -> SavedWindow {
        let normal = w.collapsedState
        let f = normal?.frame ?? w.window.frame
        let normie = (normal?.mode ?? w.shell.mode) == .normie
        let current = normal?.current ?? (normie ? w.workbench.selectedConversation?.id ?? w.scene.current : w.scene.current)
        var saved = SavedWindow(frame: [f.minX, f.minY, f.width, f.height], normie: normie,
                                members: w.scene.members.map(\.id), current: current,
                                collapsed: normal == nil ? nil : true, selection: normal?.shown)
        if w.scene.isFocused && !w.scene.composingNew {
            saved.layout = "focused"; saved.split = w.scene.scheme.split; saved.splitFocus = w.scene.focusTarget
        }
        if normie ? w.workbench.composingNew : w.scene.composingNew {
            let context = normie ? w.workbench.newContext : w.scene.draftContext
            let text = w.scene.composers.draft().composer.text
            saved.composingNew = true; saved.draft = text.isEmpty ? nil : text
            saved.project = context.projectID; saved.device = context.deviceID
        }
        return saved
    }

    /// As a Live Core's presentation record (LocalPresentationState.WindowState): the window as its payload, an unsent New
    /// Chat's files beside it so their inputs go to the sidecar (ATTACH-PDF-S3; f179).
    @MainActor static func record(_ w: OrganicWindow, index: Int) -> LocalPresentationState.WindowState {
        let saved = make(w)
        let payload = (try? JSONEncoder().encode(saved)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        let files = saved.composingNew == true ? w.scene.composers.draft().composer.attachments.map(LocalPresentationState.FileState.init) : nil
        return .init(id: "window-\(index)", payload: payload, files: files?.isEmpty == true ? nil : files)
    }
    static func from(_ record: LocalPresentationState.WindowState) -> SavedWindow? {
        (try? JSONEncoder().encode(record.payload)).flatMap { try? JSONDecoder().decode(SavedWindow.self, from: $0) }
    }

    static func load(scope: String, defaults: UserDefaults = .standard) -> [SavedWindow] {
        guard let data = defaults.data(forKey: key(scope)) else { return [] }
        return (try? JSONDecoder().decode([SavedWindow].self, from: data)) ?? []
    }

    /// Its frame on the screen that holds most of it, moved inside that screen's visible frame (a display may be gone).
    @MainActor func visibleFrame() -> (CGRect, NSScreen) {
        var f = frame.count == 4 ? CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]) : CGRect(x: 0, y: 0, width: 1280, height: 820)
        let screen = NSScreen.screens.max { $0.frame.intersection(f).area < $1.frame.intersection(f).area } ?? NSScreen.main!
        let vis = screen.visibleFrame
        f.size.width = min(max(560, f.width), vis.width); f.size.height = min(max(520, f.height), vis.height)
        f.origin.x = min(max(f.minX, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.minY, vis.minY), vis.maxY - f.height)
        return (f, screen)
    }
}
