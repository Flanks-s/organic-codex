import AppKit
import QuartzCore

#if !M10_DOCK_SELFTEST && !ORGANIC_SELFTEST && !ORB_SELFTEST
#if !ISLAND_SELFTEST && !M9_SPLIT_SELFTEST && !M11_MODE_SELFTEST
/// Ordered-out fixtures bypass normal app startup, real Core connections and model requests.
@MainActor enum M08SealVerification {
    private static let started = ProcessInfo.processInfo.systemUptime

    private static func progress(_ stage: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = String(format: "M08 %@ +%.3fs %@\n", stamp, elapsed, stage)
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func windowFunctional(to path: String) -> Int32 {
        guard let screen = NSScreen.main else { return 2 }
        let suite = "m08-window-functional-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        var findings = [String]()
        AppLiveWindowRestorationVerification.run(defaults: defaults, screen: screen) { value, label in
            checks += 1
            if !value { findings.append(label) }
        }
        let output = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["checks": checks, "findings": findings],
                                    options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("verification.json"))
        print("M08 window functional: \(checks) checks, \(findings.count) findings")
        return findings.isEmpty ? 0 : 1
    }

    private static var conversationOutside = [[String: Any]]()
    private static var tearCases = [[String: Any]]()

    struct Observation {
        let name: String
        let feature: String
        let exposed: Bool
    }

    static func run(to path: String) -> Int32 {
        progress("start")
        progress("AppKit finishLaunching")
        NSApp.finishLaunching()
        progress("AppKit ready")
        guard !NSScreen.screens.isEmpty else {
            print("M08 seal requires an AppKit display session for its ordered-out fixtures")
            return 2
        }
        let saved = OrganicFeatureAvailability.current
        let performer = OrganicHaptics.performer
        let models = ModelCatalog.models
        defer {
            OrganicFeatureAvailability.current = saved
            OrganicHaptics.performer = performer
            ModelCatalog.models = models
        }
        ModelCatalog.models = ModelCatalog.mockModels
        let output = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0
        var findings = [String]()
        var rows = [[String: Any]]()
        var pixels = [[String: Any]]()
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { findings.append(message) }
        }
        let mode = ProcessInfo.processInfo.environment["SELFTEST_M08_SEAL_MODE"] ?? "default"
        let leak = ProcessInfo.processInfo.environment["SELFTEST_M08_SEAL_LEAK"]
        let names = ["window-tear", "conversation-orb-tear", "collapse", "dictation", "haptics"]
        let defaults = OrganicFeatureAvailability()
        check(saved == .startup(ProcessInfo.processInfo.environment), "Actual launch state matches its environment")
        check(defaults == OrganicFeatureAvailability.startup([:]), "Absent launch overrides keep all features off")
        check(defaults == OrganicFeatureAvailability.startup(["ORGANIC_ENABLE_FEATURES": "unknown,false"]),
              "Unknown tokens cannot enable a feature")
        var tear = defaults
        tear.windowTear = true
        tear.conversationOrbTear = true
        check(tear == .startup(["ORGANIC_ENABLE_FEATURES": "tear"]), "Tear launch token enables both drag routes")
        let runs = leak == nil ? (mode == "default" ? ["default"] : names) : ["default"]
        for name in runs {
            progress("configuration " + name)
            OrganicFeatureAvailability.current = .startup(["ORGANIC_ENABLE_FEATURES": leak ?? name])
            var expected = defaults
            switch name {
            case "window-tear": expected.windowTear = true
            case "conversation-orb-tear": expected.conversationOrbTear = true
            case "collapse": expected.collapse = true
            case "dictation": expected.dictation = true
            case "haptics": expected.haptics = true
            default: break
            }
            check(OrganicFeatureAvailability.current == expected, "Independent launch opt-in: " + name)
            conversationOutside = []
            tearCases = []
            let observations = observe(output: output, tag: name, check: check)
            let leaks = observations.filter(\.exposed).map(\.name)
            for observation in observations {
                let enabled = observation.feature == name
                check(observation.exposed == enabled, "\(name): \(observation.name) expected exposed=\(enabled)")
            }
            if name != "default" {
                let required = observations.filter { $0.feature == name }.map(\.name)
                check(!required.isEmpty, "Negative control has observations: " + name)
                for item in required {
                    check(leaks.contains(item), "Default-off audit detects deliberately enabled: " + item)
                }
            }
            rows.append(["configuration": name, "defaultAuditFindings": leaks,
                         "conversationOutside": conversationOutside,
                         "tearCases": tearCases,
                         "observations": observations.map {
                             ["name": $0.name, "feature": $0.feature, "exposed": $0.exposed] as [String: Any]
                         }])
        }
        progress("pixels")
        verifyPixels(output: output, rows: &pixels, check: check)
        progress("pixels complete")
        check(!NSApp.windows.contains(where: \.isVisible), "Every fixture stays offscreen")
        let report: [String: Any] = ["checks": checks, "findings": findings, "mode": mode,
                                     "forcedLeak": leak ?? "",
                                     "runs": rows, "pixelDeviations": pixels]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("verification.json"))
        for finding in findings { print("FINDING: " + finding) }
        print("M08 seal: \(checks) checks, \(findings.count) findings")
        return findings.isEmpty ? 0 : 1
    }

    private static func observe(output: URL, tag: String, check: (Bool, String) -> Void) -> [Observation] {
        var result = [Observation]()
        var emissions = 0
        OrganicHaptics.performer = { _ in emissions += 1 }
        func record(_ name: String, _ feature: String, _ exposed: Bool) {
            result.append(.init(name: name, feature: feature, exposed: exposed))
        }
        progress(tag + " menus")
        let builder = NormieMenuBuilder(context: { NormieMenuContext() }, perform: { _, _ in })
        let menu = builder.makeMainMenu()
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        for command in ["collapse", "restore"] {
            record("menu." + command, "collapse", items(menu).contains {
                ($0.representedObject as? String) == command && !$0.isHidden
            })
            record("shortcut." + command, "collapse", items(menu).contains {
                $0.identifier?.rawValue == "shortcut." + command && !$0.keyEquivalent.isEmpty
            })
            record("catalog." + command, "collapse", NativeSettingsCatalog.shortcuts.contains { $0.id == command })
        }
        record("command.collapse-enabled", "collapse", NormieMenuContext().enabled(.collapse))
        var collapsedContext = NormieMenuContext()
        collapsedContext.collapsed = true
        record("command.restore-enabled", "collapse", collapsedContext.enabled(.restore))
        check(items(menu).contains { ($0.representedObject as? String) == "mergeWindows" },
              "Merge Windows remains present: " + tag)
        let account = NormieAccount(initials: "TT", name: "Test", plan: "Test", daybreak: false)
        let accountMenu = builder.makeAccountMenu(account: account, quotaSummary: "", organic: true)
        record("menu.account", "collapse", items(accountMenu).contains { $0.title == "Collapse to Side" })
        check(!zip(builder.windowsMenu.items, builder.windowsMenu.items.dropFirst()).contains {
            $0.0.isSeparatorItem && $0.1.isSeparatorItem
        }, "Window menu has no adjacent separators: " + tag)
        progress(tag + " fullscreen menu fixture")
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = menu
        progress(tag + " fullscreen fixture init")
        let fullScreen = OrbInputVerification.Fixture()
        progress(tag + " fullscreen fixture ready")
        fullScreen.owner.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification))
        record("menu.fullscreen", "collapse", items(menu).contains { $0.title == "Exit Full Screen and Collapse" })
        progress(tag + " fullscreen fixture dispose")
        fullScreen.dispose()
        progress(tag + " fullscreen fixture disposed")
        NSApp.mainMenu = previousMenu
        progress(tag + " settings")
        let suite = "m08-seal-settings-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "settings.collapseOnHoverSpace")
        let session = SettingsSession(source: SettingsDemoDataSource(),
                                      preferences: SettingsPreferences(defaults: preferences))
        var panel = SettingsPanelBuilder(session: session)
        panel.general()
        record("settings.source", "collapse", panel.rows.contains { $0.id == "collapseOnHoverSpace" })
        let presentation = SettingsPresentation.make(panel.rows, session: session)
        record("settings.presentation", "collapse", presentation.contains {
            $0.id == "collapseOnHoverSpace" || $0.title == "Collapse"
        })
        check(preferences.bool(forKey: "settings.collapseOnHoverSpace"), "Stored Collapse preference survives: " + tag)
        var shortcuts = SettingsPanelBuilder(session: session)
        shortcuts.shortcuts()
        for command in ["collapse", "restore"] {
            record("settings.shortcut." + command, "collapse", shortcuts.rows.contains {
                $0.id == "shortcut." + command
            })
        }
        for pattern in [NSHapticFeedbackManager.FeedbackPattern.generic, .alignment, .levelChange] {
            let before = emissions
            OrganicHaptics.perform(pattern)
            let emitted = emissions - before
            record("haptics.\(pattern.rawValue)", "haptics", emitted == 1)
            check(emitted <= 1, "Haptic seam emits at most once")
        }
        progress(tag + " composer")
        for layout in [NativeComposerLayout.fullBar, .growing] {
            let composer = makeComposer(layout: layout)
            record("dictation.\(layout)", "dictation", !composer.dictationButton.isHidden)
            let dictation = OrganicFeatureAvailability.current.dictation
            OrganicFeatureAvailability.current.dictation = false
            let absent = makeComposer(layout: layout)
            OrganicFeatureAvailability.current.dictation = dictation
            record("dictation.\(layout).slot", "dictation",
                   composer.modelButton.frame.maxX < absent.modelButton.frame.maxX)
        }
        if tag == "default" || tag == "collapse" {
            progress(tag + " collapse")
            collapseObservations(record: record, check: check)
        }
        if tag == "default" || tag == "window-tear" || tag == "conversation-orb-tear" {
            progress(tag + " tear")
            tearObservations(feature: tag, record: record, check: check)
        }
        record("haptics.all-inputs", "haptics", emissions > 0)
        return result
    }

    private static func collapseObservations(record: (String, String, Bool) -> Void,
                                             check: (Bool, String) -> Void) {
        for entry in ["command", "held-space", "hover-space", "smart-zoom", "saved"] {
            progress("collapse " + entry + " init")
            let f = OrbInputVerification.Fixture()
            progress("collapse " + entry + " ready")
            defer {
                f.owner.strip?.dispose()
                f.dispose()
            }
            let scene = f.scene
            let id = scene.current
            let target = scene.dockTargets.first { $0.id == id }!
            let point = CGPoint(x: target.rect.midX, y: target.bar ? target.rect.minY : target.rect.midY)
            let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: f.time,
                windowNumber: f.owner.window.windowNumber, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
            switch entry {
            case "command": f.owner.command(.collapse, tag: 0)
            case "held-space":
                check(scene.pointerDown(point, member: id), "Held-Space fixture picks up a member")
                _ = f.owner.key(space)
                if !OrganicFeatureAvailability.current.collapse {
                    check(scene.isHolding, "Disabled Space does not consume the held drag")
                }
                scene.cancelDrag()
            case "hover-space":
                let key = "settings.collapseOnHoverSpace"
                let previous = UserDefaults.standard.object(forKey: key)
                UserDefaults.standard.set(true, forKey: key)
                _ = f.owner.key(space, collapseHoverPoint: point)
                if let previous { UserDefaults.standard.set(previous, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            case "smart-zoom":
                f.owner.root.smartMagnify(with: f.event(.leftMouseDown, at: point))
            default:
                var saved = SavedWindow.make(f.owner)
                saved.collapsed = true
                saved.selection = id
                f.app.restoreCollapsedWindows([.init(saved: saved)])
                AppWindowLifetimeVerification.drain()
                if !OrganicFeatureAvailability.current.collapse {
                    check(SavedWindow.make(f.owner).collapsed != true, "Saved collapsed owner becomes a normal window")
                }
            }
            progress("collapse " + entry + " complete")
            record("collapse." + entry, "collapse", f.owner.isCollapsed)
            record("menu.orb-account." + entry, "collapse", f.scene.meController.makeAccountMenu().items.contains {
                $0.title == "Collapse to Side"
            })
            let access = SunHoverAccess(account: scene.store.accountUsage, available: [], disabledInLayout: [],
                                        accountActions: [.profile, .settings, .shortcuts, .collapse, .signOut])
            record("menu.sun-hover." + entry, "collapse", access.accountItems.contains { $0.action == .collapse })
        }
    }

    private static func tearObservations(feature: String, record: (String, String, Bool) -> Void,
                                         check: (Bool, String) -> Void) {
        for mode in ["auto", "focused", "split"] {
            let entries = ["dock", "grip", "member", "header", "header-brief", "orb-dock", "orb-bar",
                           "orb-full", "orb-brief", "orb-peek", "orb-tide"]
            for entry in entries {
                // Baseline DockNode.draggable(at:) requires !base.focused; header/orb-bar cover these layouts.
                if entry == "grip" && mode != "auto" { continue }
                let isConversation = entry.hasPrefix("orb-")
                if feature == "window-tear" && isConversation { continue }
                if feature == "conversation-orb-tear" && !isConversation { continue }
                for edge in ["top", "side"] {
                    let stage = "tear.\(mode).\(entry).\(edge)"
                    progress(stage + " init")
                    let f = M08SealFixtureInput.make(mode: mode)
                    progress(stage + " ready")
                    defer { f.dispose() }
                    let scene = f.scene
                    let conversationOrb = entry.hasPrefix("orb-")
                    guard let target = M08SealFixtureInput.target(scene: scene, entry: entry) else { continue }
                    let header = target.header
                    let id = target.id
                    let point = target.point
                    let input = M08SealFixtureInput.receipt(fixture: f, target: target, edge: edge)
                    check(scene.members.map(\.id) == M08SealFixtureInput.members,
                          stage + " starts with the shared members")
                    let members = scene.members.map(\.id)
                    let selected = scene.current
                    let home = scene.dockFrame(of: id)
                    var callbacks = 0
                    var tearBegins = 0
                    var tearDrops = 0
                    scene.onTear = { [weak scene] event in
                        callbacks += 1
                        if case .begin = event { tearBegins += 1 }
                        if case .drop = event {
                            tearDrops += 1
                            scene?.endTear(kept: true)
                        }
                    }
                    progress(stage + " press")
                    if conversationOrb {
                        check(scene.orbInput.begin(f.event(.leftMouseDown, at: point), id: id,
                                                   header: header, tidePlanet: entry == "orb-tide",
                                                   ordinary: { _ in }), stage + " orb drag begins")
                    } else if let header {
                        check(M104HeaderOrbDragging.install(in: scene).begin(from: header, at: point),
                              stage + " legacy header drag begins")
                    } else {
                        check(scene.pointerDown(point, member: entry == "member" ? id : nil),
                              stage + " legacy Dock/grip/member drag begins")
                    }
                    check(scene.pressedNode == id, stage + " picks the requested member")
                    let path = M08SealFixtureInput.trajectory(scene: scene, point: point, edge: edge)
                    let outside = path.outside
                    let inside = path.inside
                    progress(stage + " move")
                    if conversationOrb {
                        scene.orbInput.dragged(f.event(.leftMouseDragged, at: inside))
                        check(scene.isDragging || scene.isTearing, stage + " crosses the pickup threshold")
                        scene.orbInput.dragged(f.event(.leftMouseDragged, at: outside))
                        scene.orbInput.released(f.event(.leftMouseUp, at: outside, after: 0.4))
                    } else {
                        scene.pointerDragged(inside)
                        check(scene.isDragging || scene.isTearing, stage + " crosses the pickup threshold")
                        scene.pointerDragged(outside)
                        _ = scene.pointerUp(outside)
                    }
                    progress(stage + " settle")
                    f.settle()
                    progress(stage + " complete")
                    let allowed = OrganicFeatureAvailability.current.allowsTear(conversationOrb: conversationOrb)
                    let label = "tear.\(mode).\(entry).\(edge)"
                    if conversationOrb && !allowed {
                        conversationOutside.append([
                            "entry": label, "input": input, "members": scene.members.map(\.id),
                            "current": scene.current,
                            "removals": scene.orbTrash.successfulRemovals, "callbacks": callbacks,
                            "holding": scene.isHolding, "tearing": scene.isTearing,
                            "trashCarrying": scene.orbTrash.isCarrying,
                            "reason": scene.switches.last?["reason"] as? String ?? ""
                        ])
                    }
                    record(label, conversationOrb ? "conversation-orb-tear" : "window-tear", callbacks > 0)
                    if allowed {
                        check(tearBegins == 1 && tearDrops == 1, label + " tears and drops exactly once")
                    }
                    tearCases.append(["entry": label, "input": input, "begins": tearBegins, "drops": tearDrops,
                                      "callbacks": callbacks, "members": scene.members.map(\.id),
                                      "home": home.map { [$0.midX, $0.midY] } ?? [],
                                      "returned": scene.dockFrame(of: id).map { [$0.midX, $0.midY] } ?? []])
                    check(!scene.isTearing && !scene.isHolding && !scene.dock.isHolding,
                          label + " releases input and paint ownership")
                    if !conversationOrb || allowed {
                        check(scene.members.map(\.id) == members && scene.current == selected,
                              label + " restores source order and selection")
                    } else {
                        check(scene.switches.contains { $0["reason"] as? String == "trash-return" },
                              label + " uses the baseline orbTrash.release / trash-return branch")
                        check(!scene.switches.contains { $0["reason"] as? String == "tear-disabled-return" },
                              label + " bypasses the new non-conversation return branch")
                        check(scene.orbTrash.successfulRemovals == 0,
                              label + " preserves the baseline outside-drop removal count")
                    }
                    if !allowed {
                        check(callbacks == 0, label + " never calls onTear")
                        check(header?.orbIsCarried != true, label + " restores header paint ownership")
                        check(home != nil && scene.dockFrame(of: id) != nil, label + " retains a Dock position")
                        if !conversationOrb, let home, let returned = scene.dockFrame(of: id) {
                            check(abs(home.midX - returned.midX) < 1 && abs(home.midY - returned.midY) < 1,
                                  label + " returns to its original position")
                        }
                    }
                    check(f.app.windows.count == 1, label + " cannot create a second window in the fixture")
                }
            }
        }
    }

    private static func makeComposer(layout: NativeComposerLayout) -> NativeComposer {
        let conversation = Conversation(id: "m08-composer", title: "Test")
        conversation.draft = "Check the composer controls"
        let composer = NativeComposer(conversation: conversation)
        composer.layoutMode = layout
        composer.frame = CGRect(x: 0, y: 0, width: 760, height: layout == .fullBar ? 48 : 110)
        composer.layoutControls()
        composer.layoutSubtreeIfNeeded()
        return composer
    }

    private static func verifyPixels(output: URL, rows: inout [[String: Any]], check: (Bool, String) -> Void) {
        for layout in [NativeComposerLayout.fullBar, .growing] {
            for scale: CGFloat in [1, 2] {
                OrganicFeatureAvailability.current = .init()
                let off = makeComposer(layout: layout)
                let a = NativeViewBitmap.capture(off, scale: scale)
                OrganicFeatureAvailability.current.dictation = true
                let on = makeComposer(layout: layout)
                let b = NativeViewBitmap.capture(on, scale: scale)
                let name = "\(layout)-\(Int(scale))x"
                Offscreen.write(a, output.appendingPathComponent(name + "-off.png"))
                Offscreen.write(b, output.appendingPathComponent(name + "-on.png"))
                func bytes(_ image: CGImage) -> [UInt8] {
                    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: VerificationRaster.colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                                      count: image.width * image.height * 4))
                }
                let first = bytes(a)
                let second = bytes(b)
                var changed = 0
                var error = 0
                var minX = a.width
                var minY = a.height
                var maxX = -1
                var maxY = -1
                for index in stride(from: 0, to: first.count, by: 4) {
                    var differs = false
                    for channel in 0..<3 {
                        let delta = abs(Int(first[index + channel]) - Int(second[index + channel]))
                        error += delta
                        differs = differs || delta != 0
                    }
                    if differs {
                        changed += 1
                        let pixel = index / 4
                        let x = pixel % a.width
                        let y = pixel / a.width
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
                let reclaimed = off.modelButton.frame.maxX - on.modelButton.frame.maxX
                check(off.dictationButton.isHidden && !on.dictationButton.isHidden, name + " hides the microphone")
                check(reclaimed > 0, name + " reclaims the microphone slot")
                check(changed > 0, name + " pixel negative control detects enabled dictation")
                let microphone = on.dictationButton.frame
                let modelOn = on.modelButton.frame
                let modelOff = off.modelButton.frame
                rows.append(["layout": name, "changedPixels": changed, "totalPixels": a.width * a.height,
                             "microphoneFrame": [microphone.minX, microphone.minY,
                                                 microphone.width, microphone.height],
                             "modelOnFrame": [modelOn.minX, modelOn.minY, modelOn.width, modelOn.height],
                             "modelOffFrame": [modelOff.minX, modelOff.minY, modelOff.width, modelOff.height],
                             "rgbMeanAbsoluteError": Double(error) / Double(a.width * a.height * 3),
                             "reclaimedPoints": reclaimed,
                             "changedBounds": [minX, minY, maxX - minX + 1, maxY - minY + 1]])
            }
        }
    }
}
#endif
#endif
