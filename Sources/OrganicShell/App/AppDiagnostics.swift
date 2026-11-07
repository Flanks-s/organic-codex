import AppKit
import QuartzCore

extension AppController {
    /// Every transcript view in the windows: whose, shown or not, its size, content height and offset (the live-history check).
    func transcriptViews() -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ v: NSView) {
            if let t = v as? NativeTranscript {
                out.append(["id": t.conversation.id, "items": t.conversation.items.count, "hidden": t.isHiddenOrHasHiddenAncestor,
                            "frame": NSStringFromRect(t.convert(t.bounds, to: nil)), "content": t.contentHeight, "offset": t.scrollOffset.y])
            }
            v.subviews.forEach(walk)
        }
        windows.forEach { if let v = $0.window.contentView?.superview { walk(v) } }
        return out
    }
    /// Every layer in the window still carrying an animation, with its keys (a forgotten one makes the window
    /// server composite every frame while nothing visibly changes).
    func animatedLayers() -> [String] {
        guard let window = windows.first?.window else { return [] }
        var out: [String] = []
        func walk(_ l: CALayer, _ path: String) {
            let here = path + "/" + (l.name ?? String(describing: type(of: l)))
            if let keys = l.animationKeys(), !keys.isEmpty {
                let detail = keys.map { k -> String in
                    let a = l.animation(forKey: k)
                    return "\(k)(repeat \(a?.repeatCount ?? 0), dur \(a?.duration ?? 0), hidden \(l.isHidden), op \(l.opacity))"
                }
                out.append(here + " " + detail.joined(separator: ", "))
            }
            for s in l.sublayers ?? [] { walk(s, here) }
        }
        if let l = window.contentView?.superview?.layer ?? window.contentView?.layer { walk(l, "") }
        return out
    }

    func save() {
        guard !saved, let path = o.output else { return }
        saved = true
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The last window may have closed already (AP19): the scene's part only while one is left.
        let s = windows.first?.scene
        let receipt: [String: Any] = [
            "app": "Organic Shell v2 first scene", "display": s?.profile.summary ?? "", "windowSize": [s?.size.width ?? 0, s?.size.height ?? 0],
            "modeSwitchLog": ModeSignposts.receipt,
            "columns": s?.columns.count ?? 0, "switches": s?.switches ?? [], "displayLink": s?.clock.log.fields ?? [:],
            "windows": windows.map { ["members": $0.scene.members.map(\.id), "current": $0.scene.current, "normie": $0.shell.mode == .normie, "frame": NSStringFromRect($0.window.frame),
                                      "collapsed": $0.isCollapsed, "shown": $0.strip?.shown ?? "", "focused": $0.scene.isFocused, "split": $0.scene.scheme.split,
                                      "focusTarget": $0.scene.focusTarget, "newChat": $0.shell.mode == .normie ? $0.workbench.composingNew : $0.scene.composingNew,
                                      "draft": $0.scene.composers.draft().composer.text, "draftFiles": $0.scene.composers.draft().composer.attachments.map(\.name), "draftProject": ($0.shell.mode == .normie ? $0.workbench.newContext : $0.scene.draftContext).projectID ?? ""] },
            "mockEvents": mock?.emitted ?? [], "liveCore": ["connected": live?.isConnected ?? false, "status": live?.connectionStatus ?? "", "error": liveError ?? "",
                                                          "conversations": store.conversations.count,
                                                          "shown": windows.compactMap { w in store.conversation(w.scene.current) }.map { c in
                                                              ["id": c.id, "items": c.items.count, "historyLoaded": c.historyLoaded, "loading": c.loading, "error": c.operationError ?? ""] }, "transcripts": transcriptViews()], "hoverLog": hoverLog, "swapLog": swapLog, "composeLog": composeLog, "resizeLog": resizeLog, "settles": s?.settles ?? [], "animationsAtQuit": windows.isEmpty ? [] : animatedLayers(), "exposure": ["enabled": s?.exposure.enabled ?? false, "shutter": s?.exposure.shutter ?? 0],
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "pid": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url.appendingPathComponent("receipt.json"))
        }
    }
}
