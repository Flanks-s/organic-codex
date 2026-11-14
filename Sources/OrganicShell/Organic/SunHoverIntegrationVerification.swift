#if M1139_CHECK
import AppKit
import QuartzCore

@MainActor enum SunHoverIntegrationVerification {
    static func run(_ check: (Bool, String) -> Void) {
        channels(check)
        for scale in [1.0, 2.0] { scene(scale: scale, check) }
    }
    static func channels(_ check: (Bool, String) -> Void) {
        var t = 0.0
        let state = SunHoverState { t }, node = SunHoverNode()
        let store = ConversationStore(conversations: [])
        let g = SunHoverGeometry(llCenter: CGPoint(x: 48, y: 764), dockBaseline: 764, bounds: CGRect(x: 0, y: 0, width: 1280, height: 820), backingScale: 1)
        let titles = ["New Chat", "Add to Dock", "Search", "Show Sidebar", "Usage", "Settings"]
        node.permits = { _ in true }; state.pointer(in: [.ll]); t = 2; state.tick()
        for scale in [1.0, 2.0] {
            let geometry = SunHoverGeometry(llCenter: g.llCenter, dockBaseline: g.dockBaseline, bounds: g.bounds, backingScale: scale)
            node.sample(state: state, geometry: geometry, diameter: 42, usage: store.accountUsage, titles: titles)
            check(node.visibleSatellites.count == 6, "sun-node: six authored surfaces at \(scale)x")
            for key in SunHoverSatellite.allCases {
                let actual = node.glassSurfaces[key.rawValue].frame, expected = geometry.satelliteCenter(key)
                check(hypot(actual.midX - expected.x, actual.midY - expected.y) <= 0.72 / scale, "sun-node: measured native satellite center \(key) \(scale)x")
                check(abs(actual.width - 34) < 0.01, "sun-node: native satellite diameter stays 34 \(key) \(scale)x")
                let alpha = node.glassSurfaces[key.rawValue].alphaValue
                check(alpha == 1, "sun-node: settled native glass is opaque \(key)")
            }
        }
        for key in SunHoverSatellite.allCases {
            state.pointer(in: [.satellite(key)]); t += 1; state.tick(); t += 1; state.tick()
            node.sample(state: state, geometry: g, diameter: 42, usage: store.accountUsage, titles: titles)
            check(node.visibleLabels == [key], "sun-node: only one visible authored label \(key)")
            let actual = node.glassSurfaces[6 + key.rawValue].frame, expected = g.label(key, aligned: true)
            check(abs(actual.midX - expected.midX) < 0.01 && abs(actual.midY - expected.midY) < 0.01, "sun-node: native label center follows board \(key)")
            check(actual.width == expected.width && actual.height == 28, "sun-node: native capsule size follows board \(key)")
        }
        check(state.nextDeadline == nil && !state.needsFrames, "sun-idle: settled channels have no deadline or frame request")
        var shape = SunHoverPanelMotion(source: g.llCenter)
        shape.show(.usage, source: g.llCenter, geometry: g, at: 0)
        shape.show(.account, source: g.llCenter, geometry: g, accountHeight: SunHoverPanelView.accountHeight, at: 2)
        check(shape.needsFrames(at: 2.35), "sun-shape: panel-kind switch keeps its independent shape channels running")
        check(!shape.needsFrames(at: 4), "sun-idle: panel shape channels stop when settled")
        node.retire()
        check(node.visibleSatellites.isEmpty && node.visibleLabels.isEmpty, "sun-exit: native surfaces retire together")
        check(node.glassSurfaces.allSatisfy(\.isHidden), "sun-exit: every native glass is hidden after retirement")
        let reduced = SunHoverState(reduceMotion: true) { t }
        reduced.pointer(in: [.ll]); t += 0.06; reduced.tick()
        node.sample(state: reduced, geometry: g, diameter: 42, usage: store.accountUsage, titles: titles)
        for key in SunHoverSatellite.allCases {
            let actual = node.glassSurfaces[key.rawValue].frame, target = g.satellite(key, progress: 1, reduceMotion: true)
            check(actual == target && node.glassSurfaces[key.rawValue].alphaValue > 0 && node.glassSurfaces[key.rawValue].alphaValue < 1, "sun-node: reduced motion fades at endpoint \(key)")
        }
        t += 0.3; reduced.tick(); reduced.pointer(in: [.satellite(.usage)]); t += 0.06; reduced.tick()
        node.sample(state: reduced, geometry: g, diameter: 42, usage: store.accountUsage, titles: titles)
        let reducedLabel = node.glassSurfaces[6 + SunHoverSatellite.usage.rawValue]
        check(reducedLabel.frame == g.label(.usage, progress: 1, aligned: true), "sun-node: reduced label neck uses its endpoint geometry")
        check(reducedLabel.alphaValue > 0 && reducedLabel.alphaValue < 1, "sun-node: reduced label neck fades without deforming")
        node.dispose()
    }
    static func scene(scale: Double, _ check: (Bool, String) -> Void) {
        var t = 0.0
        let a = Conversation(id: "sun-a", title: "Current"), b = Conversation(id: "sun-b", title: "Needs attention")
        let outside = Conversation(id: "sun-outside", title: "Other window")
        a.backendThreadID = "sun-thread-a"; a.exactTokensUsed = 50; a.contextLimit = 100
        a.question = "Choose a direction"; b.error = .stopped; b.question = "One more question"; outside.error = .stopped
        let store = ConversationStore(conversations: [a, b, outside])
        let profile = DisplayProfile(name: "sun-check", frameInterval: 1/60, mmPerPoint: 0.27, persistenceFrames: 0)
        let scene = AutoScene(size: CGSize(width: 1280, height: 820), store: store, profile: profile, scale: scale)
        scene.now = { t }; scene.dock.motionTime = { t }; scene.manualSettle = true; scene.verificationPresented = true; scene.restOnSnapshot = true; scene.ambient = false
        scene.install(members: [a.id, b.id]); scene.clock.invalidate(); scene.settle()
        guard let hover = scene.sunHover, let measurement = scene.dock.meMeasurement else { check(false, "sun-writer: fixture must have a measured LL"); return }
        hover.now = { t }
        hover.accountObservation = store.observeAccountUsage { [weak hover] value in hover?.accountChanged(value) }
        check(store.accountUsageObservationCount == 1, "sun-usage: window owns one account observation")
        var commands: [SunHoverAction] = []; hover.command = { commands.append($0) }
        check(hover.attentionSnapshot.badgeCount == 2 && hover.attentionSnapshot.eventCount == 3, "sun-attention: badge counts window conversations, not events or other windows")
        check(hover.badge?.symbol == .count(2), "sun-attention: Dock consumes the same conversation projection")
        check(makeMeConfiguration(store: store, initials: "LL", drawingSize: 40, backingScale: scale, reduceMotion: false, ambient: false, isKeyWindow: true, badgeProjection: { nil }).badge == nil, "sun-collapse-badge: an empty projection does not fall back to global event counts")
        let corners = scene.dock.sunHoverMeCorner
        let cornerWrites = scene.dock.sunHoverCornerWrites
        scene.dock.holdMe(at: measurement.center); scene.dock.frame(at: t, elapsed: 2)
        print("TRACE corner scale=\(scale) before=\(corners) after=\(scene.dock.sunHoverMeCorner) held=\(String(describing: scene.dock.meMeasurement?.frame))")
        let held = scene.dock.meMeasurement!.frame
        check(scene.dock.sunHoverCornerWrites == cornerWrites && scene.dock.sunHoverMeCorner == min(held.width, held.height) / 2, "sun-corner: ordinary held LL keeps baseline writeGlass policy with no Sun corner writes")
        scene.dock.releaseMe(); t = 2; scene.dock.hoverFrame(at: t); scene.settle()
        hover.pointerChanged(measurement.center); t += 1; hover.advance(); t += 1; hover.advance()
        let open = scene.dock.meMeasurement!
        print("TRACE open scale=\(scale) baseline=\(measurement.frame) actual=\(open.frame)")
        check(abs(open.diameter - measurement.diameter - 6) < 0.01, "sun-writer: Dock adds the LL diameter channel \(scale)x")
        check(hypot(open.center.x - measurement.center.x, open.center.y - measurement.center.y) < 0.01, "sun-writer: Dock keeps the actual LL center \(scale)x")
        check(scene.dock.sunHoverRingsBelowMe(hover.node.ringLayers), "sun-ring-stack: actual ring layers stay below LL glyphs and badge at \(scale)x")
        let mounted = hover.node.glassSurfaces.filter { $0.superview != nil }, parent = hover.node.glassSurfaces[2].superview
        check(mounted.count == 4 && parent != nil && mounted.allSatisfy { $0.superview === parent } && parent?.subviews.contains(where: { $0.frame == open.frame && $0 is NSGlassEffectView }) == true, "sun-writer: LL and visible satellites share the native fusion container")
        check(hover.node.glassSurfaces[0].superview == nil && hover.node.glassSurfaces[1].superview == nil, "sun-input: unfinished glass has no native container membership")
        check(Set(hover.node.visibleSatellites) == [.search, .sidebar, .usage, .settings], "sun-input: unfinished transactions have no visible entry point")
        let samples = hover.node.samples
        for _ in 0..<50 { hover.pointerChanged(measurement.center) }
        check(hover.node.samples == samples, "sun-idle: stationary open tracking does not redraw")
        hover.activate(.newChat); hover.activate(.addToDock)
        check(commands.isEmpty && hover.state.mode == .open, "sun-input: unfinished actions cannot dispatch through a stale target")
        hover.activate(.search); hover.activate(.search)
        check(commands == [.search], "sun-input: a command dispatches exactly once before the hover retires")
        check(hover.state.mode == .idle && hover.node.visibleSatellites.isEmpty, "sun-exit: command retirement removes active surfaces")
        let afterRetirement = hover.node.samples; t += 0.016; hover.advance()
        check(hover.node.samples == afterRetirement && hover.node.visibleSatellites.isEmpty, "sun-exit: queued advance cannot resurrect a removed hover")
        hover.pointerChanged(measurement.center)
        check(hover.state.mode == .idle, "sun-input: terminal exit suppresses reopening under the same pointer")
        hover.pointerChanged(nil); hover.pointerChanged(measurement.center); t += 2; hover.advance()
        check(hover.state.mode == .open, "sun-input: leave and reenter releases the suppression")
        hover.llClick(); t += 0.12; hover.advance()
        check((hover.node.panel.glass.layer?.filters ?? []).isEmpty && hover.node.panel.rows.contains { !($0.layer?.filters ?? []).isEmpty && $0.frame.minY > $0.home.minY }, "sun-shape: entering ink rises and blurs while native glass stays sharp")
        t += 2; hover.advance(); t += 1; hover.advance()
        check(hover.state.mode == .panel(.account) && !hover.node.panel.isHidden, "sun-shape: LL click opens the account panel")
        check(hover.node.glassSurfaces.allSatisfy { $0.superview == nil }, "sun-shape: folded native surfaces leave no residual material")
        let account = hover.node.panel, expectedHeight = SunHoverPanelView.accountHeight
        check(abs(account.frame.height - expectedHeight) <= 0.5 / scale && account.rows.count == 5, "sun-shape: account includes profile, three rows and sign out")
        check(account.rows.map(\.title) == [store.accountUsage.identity.name!, "Settings\u{2026}", "Keyboard Shortcuts", "Collapse to Side", "Sign Out"], "sun-shape: real account data is not replaced by board text")
        check(account.glass.frame.size == account.bounds.size && CATransform3DIsIdentity(account.layer!.transform), "sun-shape: panel changes real shape without snapshot scaling")
        check(abs(account.document.frame.height - account.scroll.bounds.height) <= 0.5 / scale, "sun-account-layout: account document fits the actual viewport at both scales")
        check(account.content.superview === account.glass.contentView || account.content === account.glass.contentView, "sun-shape: native glass owns its live content")
        check(hover.escape() && hover.state.mode == .open, "sun-input: first Escape closes only the top panel")
        t += 2; hover.advance(); _ = hover.escape(); t += 2; hover.advance()
        check(hover.state.mode == .idle, "sun-input: second Escape folds satellites")
        hover.pointerChanged(nil); hover.pointerChanged(measurement.center); t += 2; hover.advance()
        hover.activate(.usage); t += 2; hover.advance(); t += 1; hover.advance()
        check(hover.state.mode == .panel(.usage), "sun-shape: Usage satellite uses the shared panel")
        check(hover.node.panel === account && account.rows.count == 3, "sun-shape: switching panels retains the real view and includes current context")
        check(account.rows.last?.value == "50%", "sun-usage: current column supplies the reported conversation context")
        check(account.rows.map(\.title) == ["5-hour limit", "Weekly limit", "Context, this conversation"], "sun-usage-board: reported window names and context match the board")
        check(account.rows.allSatisfy { SunHoverRenderCheck.trailingInk($0, scale: scale) }, "sun-value-align: painted values reach the trailing edge of the real row")
        check(account.rows.allSatisfy { $0.titleY == $0.valueRect.minY }, "sun-value-baseline: every Usage title shares its value's vertical origin")
        scene.scheme.draft = true; hover.refreshData()
        check(account.rows.last?.value == "\u{2014}" && account.rows.last?.used == nil, "sun-usage: visible unsent draft never borrows the previous full conversation context")
        scene.scheme.draft = false; hover.refreshData()
        store.clearCoreQuota()
        check(account.rows.prefix(2).allSatisfy { $0.value == "Not reported" && $0.used == nil }, "sun-usage: unknown quota never paints a zero percent bar")
        hover.retire(); hover.pointerChanged(nil)
        hover.llClick(); t += 2; hover.advance()
        hover.state.showPanel(.attention); hover.advance()
        check(hover.node.panel.exitingCount == 5, "sun-shape: switching kind retains exiting ink for its own fade")
        t += 2; hover.advance(); t += 1; hover.advance()
        let ids = account.rows.map(\.id)
        let source = hover.panelSource, ll = scene.dock.meMeasurement!
        check(abs(source.x - ll.center.x - 17) < 0.1 && abs(source.y - ll.center.y + 17) < 0.1, "sun-badge-source: attention grows from the authored upper right anchor")
        if let badge = scene.dock.sunHoverBadgeRect {
            print("TRACE badge scale=\(scale) actual=\(badge) ll=\(ll.frame) above=\(scene.dock.sunHoverBadgeIsAboveBody)")
            check(abs(badge.maxX - ll.frame.maxX - 3) < 0.1 && abs(badge.minY - ll.frame.minY + 3) < 0.1 && badge.height == 14 && scene.dock.sunHoverBadgeIsAboveBody, "sun-badge-board: actual badge uses right minus three top minus three above the LL body")
        } else { check(false, "sun-badge-board: actual Dock badge must be present") }
        check(ids == [b.id, a.id], "sun-attention: panel rows share badge severity ordering")
        account.rows.first?.invoke?()
        check(hover.attentionSnapshot.badgeCount == 2 && hover.attentionSnapshot.rows.first(where: { $0.conversationID == b.id })?.mostSevere.severity == .question, "sun-attention: reviewed error clears while unanswered question remains")
        check(scene.current == b.id, "sun-attention: activation swaps the freshly resolved conversation into full")
        let hiddenCount = (hover.node.accessibilityChildren() ?? []).count
        check(hiddenCount == 0, "sun-input: retired hover exposes no AX actions")
        scene.disposeTranscriptPresentation()
        check(store.accountUsageObservationCount == 0, "sun-usage: disposal cancels account subscription synchronously")
    }
}
#endif
