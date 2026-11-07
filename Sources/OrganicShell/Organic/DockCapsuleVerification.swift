#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Structural checks only: detached AppKit views cannot validate WindowServer glass fusion.
@MainActor enum DockCapsuleVerification {
    @MainActor final class Fixture {
        let size = CGSize(width: 1280, height: 820)
        let all = Array(MockSeed.make().prefix(6))
        let host: DockNode.Passage
        let dock: DockNode
        let store: ConversationStore
        let metrics: AutoLayout.Metrics
        let glass: NSGlassEffectView
        var now = CACurrentMediaTime() + 3600
        var began = 0.0
        var order: [String]
        var layout: AutoLayout

        init(scale: CGFloat, exposure: Bool) {
            metrics = .tuned(for: size)
            layout = AutoLayout(size: size, count: all.count, fullIndex: 0, metrics: metrics)
            order = all.map(\.id)
            store = ConversationStore(conversations: all, projects: MockSeed.projects, devices: MockSeed.devices)
            host = DockNode.Passage(frame: CGRect(origin: .zero, size: size)); host.wantsLayer = true
            dock = DockNode(view: host, scale: scale)
            let container = host.subviews.compactMap { $0 as? NSGlassEffectContainerView }.first!
            glass = container.contentView!.subviews.first as! NSGlassEffectView
            dock.ambient = false; dock.still = true; dock.motionEnabled = exposure
            dock.motionProfile = M10DockMotion.dell
            dock.motionTime = { [unowned self] in self.now }
            dock.install(layout, metrics: metrics, order: all, full: [all[0].id], store: store)
            began = now
        }

        func focused(_ owner: String, segments: Int = 1) -> (AutoLayout, [String]) {
            let remaining = all.map(\.id).filter { $0 != owner }
            let ids = [owner] + remaining
            let f = FocusLayout(size: size, segments: segments, leftOrbs: 0,
                                rightOrbs: all.count - segments, satellites: segments > 1, metrics: metrics)
            var next = AutoLayout(); next.focused = true
            next.me = f.me; next.bars = f.segments; next.columns = f.columns; next.orbs = f.rightOrbs
            return (next, ids)
        }

        func auto() -> (AutoLayout, [String]) {
            (AutoLayout(size: size, count: all.count, fullIndex: 0, metrics: metrics), all.map(\.id))
        }

        @discardableResult func transition(_ next: (AutoLayout, [String])) -> [String: RectSpring] {
            let springs = dock.springs(to: next.0, order: next.1, at: now - began, spring: (0.40, 0.82))
            let duration = springs.values.map(\.duration).max() ?? 0
            dock.transition(to: next.0, order: next.1,
                            full: next.0.focused ? Set(next.1.prefix(next.0.bars.count)) : [all[0].id],
                            springs: springs, duration: duration)
            layout = next.0; order = next.1; began = now
            dock.hoverFrame(at: now); dock.sample(0)
            return springs
        }

        func sample(_ elapsed: Double) {
            now = began + elapsed; dock.hoverFrame(at: now); dock.sample(elapsed)
        }

        func walk(_ duration: Double) {
            let count = max(1, Int(ceil(duration * 240)))
            for step in 1...count { sample(duration * Double(step) / Double(count)) }
        }
    }

    static func run(to output: URL, check: (Bool, String) -> Void) throws {
        NativeAppearance.apply(.init())
        ModelCatalog.models = ModelCatalog.mockModels
        try DockGlassTopologyVerification.run(to: output, check: check)
        var rows: [[String: Any]] = []
        func near(_ a: CGRect, _ b: CGRect) -> Bool { MotionStep.edge(a, b) < 0.001 }
        func rect(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
        func state(_ f: Fixture, _ label: String) {
            check(f.glass.superview != nil, label + " keeps the existing glass node mounted")
            check(f.glass.isHidden != f.layout.focused, label + " resting participation matches mode")
            check(f.dock.focusedGlassOpacity == (f.layout.focused ? 1 : 0), label + " resting opacity")
            if f.layout.focused {
                let union = f.layout.bars.reduce(f.layout.bars.first ?? .zero) { $0.union($1) }
                check(near(f.dock.focusedGlassFrame, union), label + " one full capsule")
                check(f.dock.dividerLayers.count == max(0, f.layout.bars.count - 1), label + " divider count")
            }
        }

        for scale: CGFloat in [1, 2] {
            sceneLifecycle(scale: scale, check: check)
            for exposure in [false, true] {
                fallbacks(scale: scale, exposure: exposure, check: check)
                autoInteractions(scale: scale, exposure: exposure, check: check)
                let f = Fixture(scale: scale, exposure: exposure)
                let tag = "\(Int(scale))x exposure=\(exposure)"
                state(f, tag + " install Auto")
                check(f.layout.bars.count == 3, tag + " exercises both Auto gaps")
                for segments in [1, 2, 3] {
                    let next = f.focused(f.all[0].id, segments: segments)
                    f.dock.focusTarget = next.1[segments - 1]
                    f.dock.install(next.0, metrics: f.metrics, order: next.1.compactMap { f.store.conversation($0) },
                                   full: Set(next.1.prefix(segments)), store: f.store)
                    f.layout = next.0; f.order = next.1
                    state(f, tag + " install Focused/Split \(segments)")
                    for id in next.1.prefix(segments) {
                        let item = f.dock.items[id]!
                        let selected = segments > 1 && id == f.dock.focusTarget
                        check(abs(item.selection.opacity * Float(item.chromeHost.alphaValue) - (selected ? 1 : 0)) < 0.001,
                              tag + " selected segment emphasis \(segments)/\(id)")
                    }
                    check(f.dock.dividerLayers.allSatisfy { $0.opacity == 1 }, tag + " stationary divider opacity")
                    f.dock.relayout(next.0, metrics: f.metrics, order: next.1.compactMap { f.store.conversation($0) },
                                    full: Set(next.1.prefix(segments)))
                    state(f, tag + " relayout Focused/Split \(segments)")
                }
                let auto = f.auto()
                f.dock.install(auto.0, metrics: f.metrics, order: f.all, full: [f.all[0].id], store: f.store)
                f.layout = auto.0; f.order = auto.1; f.began = f.now
                state(f, tag + " reinstall Auto")
                f.dock.relayout(auto.0, metrics: f.metrics, order: f.all, full: [f.all[0].id])
                state(f, tag + " relayout Auto")

                for ownerIndex in [0, 1, 2, 4] {
                    for reverseAt in [0.0, 1.0/240, 1.0/60, 0.06, 0.12, 0.24, 0.45, 0.8] {
                        let owner = f.all[ownerIndex].id
                        let name = tag + " owner=\(ownerIndex) reverse=\(reverseAt)"
                        f.dock.install(auto.0, metrics: f.metrics, order: f.all, full: [f.all[0].id], store: f.store)
                        f.layout = auto.0; f.order = auto.1; f.began = f.now
                        let source = f.dock.items[owner]!.glass.frame
                        let entry = f.focused(owner)
                        let springs = f.transition(entry)
                        check(near(f.dock.focusedGlassFrame, source), name + " entry begins inside retained member, not Auto union")
                        check(!f.glass.isHidden, name + " entry participates even at alpha zero inside its owner")
                        let target = entry.0.bars[0]
                        let expected = RectSpring(dockFrom: springs[owner]!.sample(0).rect, to: target,
                                                  velocity: springs[owner]!.sample(0).velocity, response: 0.40, damping: 0.82)
                        let history = M10DockHistory(); history.reset(source)
                        _ = history.update(source, at: f.now, name: "expected", profile: M10DockMotion.dell, enabled: exposure)
                        let count = max(1, Int(ceil(reverseAt * 240)))
                        for step in 1...count {
                            let t = reverseAt * Double(step) / Double(count)
                            f.sample(t)
                            let elapsed = f.now - f.began
                            let e = history.update(expected.sample(elapsed).rect, at: f.now, name: "expected",
                                                   profile: M10DockMotion.dell, enabled: exposure)
                            check(!f.glass.isHidden && near(f.dock.capsuleLogicalFrame, e.rect), name + " entry frame \(step) analytic geometry")
                        }
                        let before = f.dock.focusedGlassFrame, alpha = f.dock.focusedGlassOpacity
                        let current = expected.sample(f.now - f.began)
                        let returned = f.transition(auto)
                        check(near(f.dock.focusedGlassFrame, before), name + " reversal preserves painted position")
                        check(f.dock.focusedGlassOpacity == alpha, name + " reversal preserves opacity")
                        let destination = returned[owner]!.target
                        let back = RectSpring(dockFrom: current.rect, to: destination, velocity: current.velocity,
                                              response: 0.40, damping: 0.82)
                        // A reversal retains the incoming display-frame history, including same-frame updates.
                        _ = history.update(current.rect, at: f.now, name: "expected", profile: M10DockMotion.dell, enabled: exposure)
                        var earlyRetirement = false
                        for step in 1...300 {
                            let t = Double(step)/240
                            f.sample(t)
                            let elapsed = f.now - f.began
                            let e = history.update(back.sample(elapsed).rect, at: f.now, name: "expected",
                                                   profile: M10DockMotion.dell, enabled: exposure)
                            check(near(f.dock.capsuleLogicalFrame, e.rect), name + " return frame \(step) retains analytic position/velocity")
                            if elapsed + 1e-8 < back.duration && f.glass.isHidden { earlyRetirement = true }
                            if ownerIndex == 0 && reverseAt == 0.12 {
                                rows.append(["case": name, "time": t, "hidden": f.glass.isHidden,
                                             "opacity": f.dock.focusedGlassOpacity, "capsule": rect(f.dock.focusedGlassFrame),
                                             "owner": rect(f.dock.items[owner]!.glass.frame)])
                            }
                        }
                        check(!earlyRetirement, name + " alpha zero never cuts the geometric return tail")
                        state(f, name + " returned Auto")

                        // Reverse the outgoing tail once more, before either endpoint is reached.
                        f.transition(entry); f.walk(0.8); f.transition(auto); f.walk(reverseAt)
                        let wasHidden = f.glass.isHidden
                        // An absent capsule has no visible source; the retained member owns that first frame.
                        let outgoing = wasHidden ? f.dock.items[owner]!.glass.frame : f.dock.focusedGlassFrame
                        f.transition(entry)
                        check(near(f.dock.focusedGlassFrame, outgoing), name + " outgoing reversal preserves painted position hidden=\(wasHidden) before=\(outgoing) after=\(f.dock.focusedGlassFrame)")
                        f.walk(1.25)
                        state(f, name + " returned Focused")
                    }
                }
                check(hostHasNoWindow(f.host), tag + " fixture remains detached")
            }
        }
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "capsule checks open no visible windows")
        try JSONSerialization.data(withJSONObject: ["frames": rows,
            "scope": "Detached view structure and geometry only; no WindowServer fusion claim."], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("capsule-frames.json"))
    }

    private static func hostHasNoWindow(_ host: NSView) -> Bool { host.window == nil }

    private static func sceneLifecycle(scale: CGFloat, check: (Bool, String) -> Void) {
        let all = Array(MockSeed.make().prefix(6))
        let store = ConversationStore(conversations: all, projects: MockSeed.projects, devices: MockSeed.devices)
        let scene = AutoScene(size: CGSize(width: 1280, height: 820), store: store, profile: M10DockMotion.dell, scale: scale)
        var clock = CACurrentMediaTime() + 3600
        scene.now = { clock }; scene.dock.motionTime = { clock }
        scene.manualSettle = true; scene.ambient = false
        scene.dock.motionProfile = M10DockMotion.dell
        scene.install()
        let container = scene.dockView.subviews.compactMap { $0 as? NSGlassEffectContainerView }.first!
        let glass = container.contentView!.subviews.first as! NSGlassEffectView
        for owner in all.prefix(3) {
            for reverseAt in [1.0/60, 0.12, 0.8] {
                let tag = "scene \(Int(scale))x \(owner.id) reverse=\(reverseAt) "
                let source = scene.dock.items[owner.id]!.glass.frame
                scene.enterFocused(owner.id, reason: "capsule-check"); scene.frame(clock)
                check(MotionStep.edge(scene.dock.focusedGlassFrame, source) < 0.001, tag + "commit starts in owner")
                let began = clock, count = max(1, Int(ceil(reverseAt * 240)))
                for step in 1...count {
                    clock = began + reverseAt * Double(step)/Double(count); scene.frame(clock)
                    check(!glass.isHidden, tag + "entry frame \(step) participates")
                }
                let before = scene.dock.focusedGlassFrame
                scene.leaveFocused(reason: "capsule-reverse-check"); scene.frame(clock)
                check(MotionStep.edge(scene.dock.focusedGlassFrame, before) < 0.001, tag + "scene reversal is continuous")
                let returning = clock, end = scene.transitionEnd
                for step in 1...max(1, Int(ceil((end - returning) * 240))) {
                    clock = min(end, returning + Double(step)/240); scene.frame(clock)
                }
                let ownerFrame = scene.dock.items[owner.id]!.glass.frame
                check(glass.isHidden || ownerFrame.insetBy(dx: -0.1, dy: -0.1).contains(scene.dock.focusedGlassFrame),
                      tag + "scene duration covers the carrier's geometric tail")
                scene.settle()
                check(glass.isHidden && scene.dock.focusedGlassOpacity == 0, tag + "scene settle withdraws capsule")
                clock += 0.1; scene.install()
                check(glass.isHidden && scene.dock.focusedGlassOpacity == 0, tag + "scene rebuild stays separated")
            }
        }
        scene.disposeTranscriptPresentation()
        check(scene.dockView.window == nil, "scene lifecycle remains windowless")
    }

    private static func fallbacks(scale: CGFloat, exposure: Bool, check: (Bool, String) -> Void) {
        let f = Fixture(scale: scale, exposure: exposure)
        let tag = "fallback \(Int(scale))x exposure=\(exposure) "
        let owner = f.all[0].id, auto = f.auto(), focused = f.focused(owner)
        func reset() {
            f.dock.install(auto.0, metrics: f.metrics, order: f.all, full: [owner], store: f.store)
            f.layout = auto.0; f.order = auto.1; f.began = f.now
        }
        func withdrawn(_ label: String) {
            check(f.glass.isHidden && f.dock.focusedGlassOpacity == 0, tag + label + " has no participating invisible capsule")
            check(f.dock.dividerLayers.allSatisfy { $0.opacity == 0 }, tag + label + " withdraws divider paint")
        }

        f.transition(focused); f.walk(0.06)
        f.dock.dropItems(keeping: Set(auto.1.dropFirst()))
        withdrawn("owner removed before layout catches up")
        for step in 1...60 { f.sample(0.06 + Double(step)/240); withdrawn("removed owner frame \(step)") }
        reset(); f.transition(focused); f.walk(0.06)
        let remaining = Array(auto.1.dropFirst())
        let withoutOwner = AutoLayout(size: f.size, count: remaining.count, fullIndex: 0, metrics: f.metrics)
        f.transition((withoutOwner, remaining))
        withdrawn("owner absent from next layout while old item is retained")
        f.walk(1.25); withdrawn("missing owner settled")

        reset(); f.transition(focused); f.walk(0.06)
        reset(); withdrawn("install interrupts entry")
        f.walk(0.4); withdrawn("install has no stale return tail")
        f.transition(focused); f.walk(0.8); f.transition(auto); f.walk(0.06)
        f.dock.relayout(auto.0, metrics: f.metrics, order: f.all, full: [owner])
        withdrawn("relayout interrupts exit")
        f.began = f.now; f.walk(0.4); withdrawn("relayout has no stale return tail")
        f.transition(focused); f.walk(0.8)
        check(!f.glass.isHidden && f.dock.focusedGlassOpacity == 1, tag + "valid reentry after rebuild")

        reset()
        let source = f.dock.items[owner]!.glass.frame
        f.dock.transition(to: focused.0, order: focused.1, full: [owner], springs: [:], duration: 0.8)
        f.dock.sample(0)
        check(!f.glass.isHidden && MotionStep.edge(f.dock.focusedGlassFrame, source) < 0.001,
              tag + "missing prepared spring starts inside the mounted owner")
        reset(); f.dock.dropItems(keeping: Set(auto.1.dropFirst()))
        f.transition(focused); withdrawn("entry owner not installed yet")
        reset(); f.transition(focused); f.walk(0.8); f.transition(auto); f.walk(0.06)
        let held = f.dock.items[owner]!.glass.frame
        f.dock.hold(owner, at: CGPoint(x: held.midX, y: held.midY), now: f.now, spring: (0.30, 0.80))
        withdrawn("returning owner transferred to pointer")
        f.dock.release(forTear: true)
        f.walk(0.2); withdrawn("pointer release never revives old carrier")

        f.dock.install(AutoLayout(), metrics: f.metrics, order: [], full: [], store: f.store)
        withdrawn("empty install")
        check(f.dock.focusedGlassFrame == .zero, tag + "empty install clears stale geometry")
        f.began = f.now; f.walk(0.4); withdrawn("empty frames")
        var emptyFocused = AutoLayout(); emptyFocused.focused = true
        f.dock.install(emptyFocused, metrics: f.metrics, order: [], full: [], store: f.store)
        withdrawn("empty focused install")
        reset(); f.transition(focused); f.walk(0.06)
        f.transition((AutoLayout(), [])); withdrawn("empty transition before retired items leave")
        f.dock.dropItems(keeping: []); f.walk(0.4); withdrawn("empty transition settled")

        // A focused scene with no side orbs naturally has no orb deltas. Do not call hoverFrame
        // between this commit and sample: a rebuilding caller can sample in precisely this order.
        reset(); f.dock.still = false
        _ = f.dock.pointer(CGPoint(x: auto.0.bars[0].midX, y: auto.0.bars[0].midY), now: f.now)
        f.walk(0.5)
        var single = focused.0; single.orbs = []
        f.dock.relayout(single, metrics: f.metrics, order: [f.all[0]], full: [owner])
        f.dock.dropItems(keeping: [owner]); f.dock.hoverFrame(at: f.now); f.dock.sample(0)
        check(f.dock.rise > 0, tag + "missing-delta fixture has nonzero bar rise")
        var orbOnly = AutoLayout(); orbOnly.me = auto.0.me
        orbOnly.orbs = [CGRect(x: 1100, y: 744, width: 40, height: 40)]
        let prior = f.dock.focusedGlassFrame
        let sourceLogical = f.dock.capsuleLogicalFrame
        let history = M10DockHistory(); history.reset(prior)
        _ = history.update(prior, at: f.now, name: "expected", profile: M10DockMotion.dell, enabled: exposure)
        let springs = f.dock.springs(to: orbOnly, order: [owner], at: 0, spring: (0.40, 0.82))
        f.dock.transition(to: orbOnly, order: [owner], full: [], springs: springs, duration: 0.8)
        f.layout = orbOnly; f.order = [owner]; f.began = f.now
        // Shared-epoch commits now prepare their hover projection. Explicitly inject its absence.
        let projection = f.dock.hoverProjectionForVerification.first ?? .zero
        // Commit sources are world poses rebased into the new role. This injected missing-delta
        // driver samples that local trajectory directly, without applying its prepared projection.
        let expectedSource = CGRect(x:sourceLogical.minX-projection.minX,y:sourceLogical.minY-projection.minY,
                                    width:sourceLogical.width-projection.width,height:sourceLogical.height-projection.height)
        let expected = RectSpring(dockFrom:expectedSource,to:orbOnly.orbs[0],response:0.40,damping:0.82)
        f.dock.clearHoverProjectionForVerification()
        for step in 0...300 {
            let t = Double(step)/240; f.now = f.began + t; f.dock.sample(t)
            let e = history.update(expected.sample(f.now - f.began).rect, at: f.now, name: "expected",
                                   profile: M10DockMotion.dell, enabled: exposure)
            check(f.glass.isHidden || MotionStep.edge(f.dock.capsuleLogicalFrame, e.rect) < 0.001,
                  tag + "orb without delta shares its owner's unshifted frame \(step)")
            if t > 0.01 && t < 0.2 { check(!f.glass.isHidden, tag + "orb-only return retains geometric carrier \(step)") }
        }
        withdrawn("orb-only return settled")
        reset(); withdrawn("install after orb-only return")
    }

    private static func autoInteractions(scale: CGFloat, exposure: Bool, check: (Bool, String) -> Void) {
        let f = Fixture(scale: scale, exposure: exposure), auto = f.auto()
        let tag = "Auto interactions \(Int(scale))x exposure=\(exposure) "
        let bars = Array(f.all.prefix(3)).map { f.dock.items[$0.id]!.glass }
        func separate(_ phase: String) {
            check(f.glass.isHidden && f.dock.focusedGlassOpacity == 0, tag + phase + " has no shared capsule")
            check(Set(bars.map(ObjectIdentifier.init)).count == 3 && bars.allSatisfy { $0.superview === f.glass.superview },
                  tag + phase + " retains three independent glass views")
        }
        f.dock.still = false
        _ = f.dock.pointer(CGPoint(x: auto.0.bars[1].midX, y: auto.0.bars[1].midY), now: f.now)
        for step in 1...120 { f.sample(Double(step)/240); separate("hover frame \(step)") }
        let held = f.all[1].id, source = f.dock.items[held]!.glass.frame
        f.dock.hold(held, at: CGPoint(x: source.midX, y: source.midY), now: f.now, spring: (0.30, 0.80))
        let start = f.now
        for step in 1...120 {
            f.now = start + Double(step)/240
            f.dock.moveHeld(to: CGPoint(x: source.midX + CGFloat(step), y: source.midY - CGFloat(step)/2))
            f.dock.hoverFrame(at: f.now); f.dock.sample(f.now - f.began); f.dock.heldFrame(at: f.now)
            separate("held bar/tear frame \(step)")
        }
        f.dock.release(forTear: true)
        let order = auto.1.filter { $0 != held } + [held]
        f.transition((auto.0, order))
        for step in 1...240 { f.sample(Double(step)/240); separate("bar to orb frame \(step)") }
        check(f.dock.items[held]!.role == .orb, tag + "held bar actually becomes an orb")
    }
}
#endif
