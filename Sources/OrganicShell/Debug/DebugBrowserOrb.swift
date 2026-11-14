import AppKit

/// R2 exposes state playback only. Window/Dock presentation is deliberately deferred to R3.
@MainActor enum DebugBrowserOrb {
    static weak var liveSource: LiveBrowserSource?
    static func add(to form: DebugForm, session: DebugSession) {
        if let liveSource {
            form.heading("Codex background browser")
            weak var toggle: DebugButton?
            toggle=form.toggle("Force browser orb off",value:liveSource.forcedOff) { [weak liveSource] in
                guard let liveSource else {return}
                liveSource.setForcedOff(!liveSource.forcedOff);toggle?.checked=liveSource.forcedOff
            }
            return
        }
        form.heading("Browser Orb · explicit mock")
        weak var toggle: DebugButton?
        toggle = form.toggle("Enable browser mock in Auto", value: session.replay?.browserReplay?.enabled == true) { [weak session] in
            guard let session, session.canInject, let replay = session.replay else { return }
            _ = replay.setBrowserMockEnabled(replay.browserReplay?.enabled != true)
            session.onBrowserMockChanged?()
            toggle?.checked = replay.browserReplay?.enabled == true
        }
        toggle?.isEnabled = session.canInject
        let grid = DebugGrid()
        for scene in BrowserMockScene.allCases {
            let button = DebugButton(scene.rawValue.capitalized) { [weak session] in
                guard let session, session.canInject, let driver = session.replay?.browserReplay else { return }
                driver.play(scene)
                session.onBrowserScenario?(scene)
            }
            button.isEnabled = session.canInject; grid.append(button)
        }
        form.add(grid, height: 185)
        for issue in ["State unavailable", "Navigation failed", "Permissions not reported"] {
            let button = form.button(issue) { [weak session] in
                guard let session, session.canInject, let driver = session.replay?.browserReplay, driver.enabled else { return }
                driver.setIssue(issue)
            }
            button.isEnabled = session.canInject
        }
        form.note("Browser mock appears only in Auto. Other layouts and live sessions never expose it.", height: 44)
    }
}
