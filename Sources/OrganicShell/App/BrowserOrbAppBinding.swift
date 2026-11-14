import AppKit

extension OrganicWindow {
    /// The command is explicit; merely creating a window or a debug panel never creates browser state.
    func reconcileBrowserOrb(animateLiveAdmission: Bool = false) {
        if let app=browserApp, app.o.usesLiveCore || app.store.usesLiveCore {
            guard let source=app.liveBrowser, source.enabled else {
                disableBrowserOrb(); return
            }
            if browserOwner?.isExiting == true {browserOwner?.retire();browserOwner=nil}
            guard browserOwner == nil else {browserOwner?.visibilityChanged();return}
            guard shell.mode == .organic,scene.scheme.mode == .auto,!scene.scheme.draft,browserCanPresent else {return}
            let owner=BrowserOrbWindowOwner(window:self,replay:source,animateAdmission:animateLiveAdmission)
            browserOwner=owner;owner.mount();return
        }
        guard let app=browserApp, !app.o.usesLiveCore, !app.store.usesLiveCore, let mock=app.mock, mock.canPlay,
              let replay=mock.browserReplay,replay.enabled else {
            if let owner=browserOwner {
                owner.beginDisable { [weak self,weak owner] in
                    if self?.browserOwner === owner {self?.browserOwner=nil}
                }
            }
            return
        }
        if browserOwner?.isExiting == true {browserOwner?.retire();browserOwner=nil}
        guard browserOwner == nil else { browserOwner?.visibilityChanged();return }
        guard shell.mode == .organic,scene.scheme.mode == .auto,!scene.scheme.draft,browserCanPresent else {return}
        let owner=BrowserOrbWindowOwner(window:self,replay:replay);browserOwner=owner;owner.mount()
    }
    private func disableBrowserOrb() {
        guard let owner=browserOwner else {return}
        owner.beginDisable { [weak self,weak owner] in
            if self?.browserOwner === owner {self?.browserOwner=nil}
        }
    }
}

extension AppController {
    func installLiveBrowser(client: any CoreTransport) {
        liveBrowser?.dispose()
        let source=LiveBrowserSource(client:client);liveBrowser=source
        DebugBrowserOrb.liveSource=source
        source.onWillDisconnect={ [weak self] in
            for window in self?.windows ?? [] {window.browserOwner?.prepareForSceneInput()}
        }
        source.onChange={ [weak self,weak source] _,hydrate in
            source?.reduceMotion=Motion.reduce
            for window in self?.windows ?? [] {window.reconcileBrowserOrb(animateLiveAdmission:!hydrate)}
        }
    }
    func synchronizeBrowserOrbWindows() {
        for window in windows {window.reconcileBrowserOrb()}
    }
}
