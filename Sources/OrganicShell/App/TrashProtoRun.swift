import AppKit
import QuartzCore

/// M11.37 round 1 (lane A, Claude, 11-10): Sol's native trash prototype (OrbTrashState, OrbTrashPresentation) on a stage
/// over the real window, so WinRec2 records real glass. Offscreen captures draw NSGlassEffectView as flat discs and cannot
/// show container fusion, and the neck question (10 of 163 sampled poses with a link under 1 pt) needs real frames.
/// `--demo-input trash-proto`, mock only (input-run.sh passes --mock). No Core, store or scene is touched: the stage only
/// covers the window's content. Variants (TRASH_VARIANTS, default "product,none"):
///   product - the pose exactly as OrbTrashState gives it (since r2: nubs only while armed and held, anchored on their
///             own bodies, hidden unless they join, thinning with the gap);
///   none    - no nubs: the container's spacing (10) alone, as the reference.
/// The 11-10 run of r1 compared "board" (r1's geometry), "clamped" (this driver's own 1 pt clamp) and "none"; its frames
/// are in runs/m1137-trash/trashp-a1 and decided r2. Any other variant name now behaves like "product".
/// Each variant runs at 1x, then at TRASH_SLOW (default .25; 0 skips it). A last-column pass closes the run.
/// Every frame goes to trash-proto.jsonl beside the receipt. The caption names variant, speed, virtual time and phase, so a
/// recording frame can be matched without a sync mark. The app stays up until --quit-after, so WinRec2 can finish its file.
@MainActor final class TrashProtoRun: NSObject {
    private final class Stage: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.065, green: 0.075, blue: 0.09, alpha: 1).setFill(); bounds.fill()
            for i in 0..<16 {
                NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.012 : 0.025).setFill()
                CGRect(x: 0, y: Double(i) * 55, width: bounds.width, height: 28).fill()
            }
            // Text-like bars behind the trash's path, so the glass has something to bend.
            NSColor.white.withAlphaComponent(0.16).setFill()
            for (i, w) in [300.0, 240, 330, 190, 280].enumerated() {
                NSBezierPath(roundedRect: CGRect(x: 960, y: 610 + Double(i) * 22, width: w, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            }
        }
    }
    private final class Plane: NSView { override var isFlipped: Bool { true } }

    nonisolated static let size = CGRect(x: 0, y: 0, width: 1280, height: 820)
    nonisolated static let geometry = OrbTrashGeometry(bounds: size, lastSlotX: 1234, dockBaseline: 764)
    nonisolated static let home = CGPoint(x: 1100, y: 696), near = CGPoint(x: 1182, y: 696), away = CGPoint(x: 1150, y: 696)
    /// Up and to the left of the can, 72.6 pt from its centre: still armed (armOut 74), with the bodies about 20 pt apart.
    nonisolated static let side = CGPoint(x: 1165, y: 660)
    nonisolated static let undoTarget = CGRect(x: 1000, y: 748, width: 32, height: 32)
    nonisolated static let clock0 = 4096.0

    private let window: NSWindow
    private let output: String?
    private let log: (String, [String: Any]) -> Void
    private let stage = Stage()
    private let sourceContainer = NSGlassEffectContainerView(), sourcePlane = Plane(), source = NSGlassEffectView()
    private var presentation: OrbTrashPresentation?
    private let caption = NSTextField(labelWithString: "")
    private var state = OrbTrashState()
    private var input = TrashProtoRun.startInput()
    private var vtime = TrashProtoRun.clock0, speed = 1.0, variant = "product"
    private var waiter: CheckedContinuation<CFTimeInterval, Never>?
    private var link: CADisplayLink?
    private var lastWall: CFTimeInterval?
    private var lines: [String] = []
    private var pendingCommit: UUID?
    private var token = UUID(), receipt = UUID()
    private var frames = 0, worstLink = Double.infinity

    init(window: NSWindow, output: String?, log: @escaping (String, [String: Any]) -> Void) {
        self.window = window; self.output = output; self.log = log
    }

    nonisolated static func startInput() -> OrbTrashState.Input {
        .init(semanticCenter: home, nativeCarrier: OrbTrashState.disc(home, 38), geometry: geometry)
    }

    func run() async {
        guard let content = window.contentView else { log("trash-proto", ["error": "no content view"]); return }
        let env = ProcessInfo.processInfo.environment
        let variants = (env["TRASH_VARIANTS"] ?? "product,none").split(separator: ",").map(String.init)
        let slow = Double(env["TRASH_SLOW"] ?? "") ?? 0.25
        stage.frame = content.bounds; stage.autoresizingMask = [.width, .height]
        content.addSubview(stage)
        sourcePlane.frame = Self.size; sourceContainer.frame = Self.size
        sourceContainer.spacing = 10; sourceContainer.contentView = sourcePlane
        source.style = .regular; source.cornerRadius = 19; source.frame = OrbTrashState.disc(Self.home, 38)
        sourcePlane.addSubview(source)
        for x in [1122.0, 1178, 1234] {
            let g = NSGlassEffectView(); g.style = .regular; g.cornerRadius = 16
            g.frame = CGRect(x: x - 16, y: 748, width: 32, height: 32); sourcePlane.addSubview(g)
        }
        stage.addSubview(sourceContainer)
        caption.font = .monospacedSystemFont(ofSize: 15, weight: .medium); caption.textColor = .white
        caption.frame = CGRect(x: 24, y: 18, width: 1200, height: 22)
        stage.addSubview(caption)
        link = stage.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        log("trash-proto", ["content": [content.bounds.width, content.bounds.height], "backing": window.backingScaleFactor,
                            "variants": variants, "slow": slow, "screen": window.screen?.localizedName ?? "?"])
        caption.stringValue = "M11.37 trash prototype · starting"
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        for v in variants { for s in (slow > 0 ? [1, slow] : [1]) { await pass(v, speed: s) } }
        await lastColumnPass()
        caption.stringValue = "M11.37 trash prototype · done"
        link?.invalidate(); link = nil
        log("trash-proto done", ["frames": frames, "worstLinkGap": worstLink.isFinite ? worstLink : -1])
        // input-check.py reads this step as "the run finished"; this spec has no paths of its own to report.
        log("done", ["ran": variants.count, "skipped": 0, "findings": 0])
    }

    @objc private func tick(_ l: CADisplayLink) { let w = waiter; waiter = nil; w?.resume(returning: l.targetTimestamp) }
    private func frame() async -> CFTimeInterval { await withCheckedContinuation { waiter = $0 } }

    private func reset(_ v: String, speed s: Double, removable: Bool) {
        variant = v; speed = s; lastWall = nil; pendingCommit = nil
        state = OrbTrashState(); token = UUID(); receipt = UUID()
        input = Self.startInput(); input.removable = removable
        presentation?.view.removeFromSuperview()
        let p = OrbTrashPresentation(bounds: Self.size)
        stage.addSubview(p.view, positioned: .below, relativeTo: caption)
        presentation = p
        source.isHidden = false; source.frame = OrbTrashState.disc(Self.home, 38)
        log("trash-proto pass", ["variant": v, "speed": s, "removable": removable, "t": vtime - Self.clock0])
    }

    private func pass(_ v: String, speed s: Double) async {
        reset(v, speed: s, removable: true)
        await drive(1.0, .begin(token))                        // the trash slides in
        await drive(1.2, from: Self.home, to: Self.near)       // into the arm radius: magnet, lean, neck
        await drive(1.0)                                       // armed, at rest
        await drive(0.7, from: Self.near, to: Self.side)       // still armed, pulled up and left: the neck thins and ends
        await drive(0.4)
        await drive(0.7, from: Self.side, to: Self.near)       // and comes back
        await drive(0.4)
        await drive(0.6, from: Self.near, to: Self.away)       // past 74 pt: the trash lets go
        await drive(0.8)
        await drive(0.6, from: Self.away, to: Self.near)       // armed again
        await drive(0.6)
        await drive(2.6, .release(token))                      // drop, sink, education bubble
        input.nativeCarrier = Self.undoTarget
        await drive(2.4, .undo(receipt, target: Self.undoTarget)) // emerge, fly back to the Dock, the trash retires
        flush()
    }

    private func lastColumnPass() async {
        reset("last-column", speed: 1, removable: false)
        await drive(1.0, .begin(token))
        await drive(1.2, from: Self.home, to: Self.near)
        await drive(2.8)
        await drive(1.5, .release(token))
        flush()
    }

    /// Runs display frames until `seconds` of virtual time pass. A path moves the pointer and the physical carrier together.
    private func drive(_ seconds: Double, from a: CGPoint? = nil, to b: CGPoint? = nil, _ first: OrbTrashState.Event = .tick) async {
        var elapsed = 0.0, event = first
        repeat {
            let now = await frame()
            let dt = lastWall.map { max(0, min(0.05, now - $0)) } ?? 0
            lastWall = now
            elapsed += dt * speed; vtime += dt * speed
            if let a, let b {
                let q = OrbTrashState.smooth(min(1, elapsed / max(seconds, 0.001)))
                let p = CGPoint(x: a.x + (b.x - a.x) * q, y: a.y + (b.y - a.y) * q)
                let old = input.nativeCarrier, next = OrbTrashState.disc(p, 38), step = dt * speed
                input.semanticCenter = p; input.nativeCarrier = next
                input.nativeVelocity = step > 0 ? CGRect(x: (next.minX - old.minX) / step, y: (next.minY - old.minY) / step, width: 0, height: 0) : .zero
            } else { input.nativeVelocity = .zero }
            step(event); event = .tick
        } while elapsed < seconds
    }

    private func step(_ e: OrbTrashState.Event) {
        var event = e
        if case .tick = e, let r = pendingCommit { event = .committed(r, session: token); pendingCommit = nil }
        input.event = event
        if state.owner == .source { source.frame = input.nativeCarrier }
        var o = state.step(input, at: vtime)
        for r in o.requests {
            switch r {
            case .remove: pendingCommit = receipt
            case .presentPrompt: input.prompt = .education
            default: break
            }
        }
        o.pose.nubs = shape(o.pose)
        presentation?.apply(o, source: source, title: "Fixture chat")
        record(o, event)
    }

    private func shape(_ p: OrbTrashState.Pose) -> [CGRect] { variant == "none" ? [] : p.nubs }

    private static func gap(_ a: CGRect, _ b: CGRect) -> Double { hypot(a.midX - b.midX, a.midY - b.midY) - a.width / 2 - b.width / 2 }
    private static func rect(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)].map { (v: Double) -> Double in (v * 1000).rounded() / 1000 }
    }

    private func record(_ o: OrbTrashState.Output, _ e: OrbTrashState.Event) {
        frames += 1
        let p = o.pose
        var row: [String: Any] = ["v": variant, "speed": speed, "t": vtime - Self.clock0, "wall": lastWall ?? 0,
                                  "phase": p.phase.rawValue, "owner": p.owner.rawValue, "can": Self.rect(p.can),
                                  "carrier": Self.rect(p.carrier), "nubs": p.nubs.map(Self.rect)]
        if case .tick = e {} else { row["event"] = "\(e)".split(separator: "(").first.map(String.init) ?? "" }
        var text = ""
        if p.owner == .trash, p.carrier.width > 0 {
            let body = Self.gap(p.can, p.carrier); row["bodyGap"] = body; text += String(format: " · body %.1f", body)
        }
        if p.nubs.count == 2 {
            let links = [Self.gap(p.can, p.nubs[0]), Self.gap(p.nubs[0], p.nubs[1]), Self.gap(p.nubs[1], p.carrier)]
            row["links"] = links; worstLink = min(worstLink, -(links.max() ?? 0))
            text += " · links " + links.map { String(format: "%.1f", $0) }.joined(separator: " / ")
        }
        if let b = p.bubble { row["bubble"] = Self.rect(b) }
        if let t = p.toast { row["toast"] = Self.rect(t) }
        if let tip = p.tail.last { row["tailGap"] = p.can.minY - tip.y }
        if let m = o.disabledMessage { row["message"] = m }
        if let data = try? JSONSerialization.data(withJSONObject: row), let line = String(data: data, encoding: .utf8) { lines.append(line) }
        caption.stringValue = String(format: "%@ · %.2fx · t %.3f · %@ · owner %@", variant, speed, vtime - Self.clock0,
                                     p.phase.rawValue, p.owner.rawValue) + text
    }

    private func flush() {
        guard let output, !lines.isEmpty else { lines.removeAll(); return }
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: output + "/trash-proto.jsonl"), text = lines.joined(separator: "\n") + "\n"
        lines.removeAll()
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
