import AppKit
import ImageIO
import Metal
import QuartzCore

/// Renders a layer tree offscreen with CARenderer (Core Animation's own renderer, in process) at any time.
@MainActor final class OffscreenRenderer {
    let w: Int, h: Int
    private let texture: MTLTexture
    private let queue: MTLCommandQueue
    private let renderer: CARenderer
    private var warmed = false

    /// `scale` pixels per point: the scene draws at its own scale, and the renderer magnifies the tree to match.
    init(size: CGSize, host: CALayer, scale: CGFloat = 1) {
        w = Int(size.width * scale); h = Int(size.height * scale)
        let device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .managed
        texture = device.makeTexture(descriptor: d)!
        renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        // The renderer only sees what is committed after it is attached: attach an empty root, then the scene.
        let root = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Without a window nobody sizes the hosting layer; an empty one hides its subtree.
        host.anchorPoint = .zero
        host.bounds = CGRect(origin: .zero, size: size)
        host.position = .zero
        host.transform = CATransform3DMakeScale(scale, scale, 1)
        host.isGeometryFlipped = true
        root.addSublayer(host)
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Top-down BGRA pixels at media time `t`.
    func render(at t: Double) -> [UInt8] {
        CATransaction.flush()
        if !warmed { warmed = true; _ = render(at: t) }   // the first frame comes out empty
        renderer.beginFrame(atTime: t, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let b = queue.makeCommandBuffer()!, e = b.makeBlitCommandEncoder()!
        e.synchronize(resource: texture); e.endEncoding(); b.commit(); b.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // CARenderer's first texture row is the bottom of the scene.
        return (0..<h).reversed().flatMap { bytes[($0 * w * 4)..<(($0 + 1) * w * 4)] }
    }

    func image(_ bytes: [UInt8]) -> CGImage {
        CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func write(_ bytes: [UInt8], _ url: URL) { Offscreen.write(image(bytes), url) }

    /// |a − b| × 4 in red, for seeing what changed.
    func heat(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.count)
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
            out[i + 2] = UInt8(min(255, d * 4)); out[i + 3] = 255
        }
        return out
    }

    /// The largest mean |Δ| (0–255, RGB) over 16 × 16 tiles, and where it is.
    func tileDiff(_ a: [UInt8], _ b: [UInt8]) -> (value: Double, at: CGPoint) {
        let tile = 16
        var best = 0.0, at = CGPoint.zero
        for ty in stride(from: 0, to: h, by: tile) {
            for tx in stride(from: 0, to: w, by: tile) {
                var sum = 0, n = 0
                for y in ty..<min(h, ty + tile) {
                    var i = (y * w + tx) * 4
                    for _ in tx..<min(w, tx + tile) {
                        sum += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                        n += 3; i += 4
                    }
                }
                let m = Double(sum) / Double(max(1, n))
                if m > best { best = m; at = CGPoint(x: tx, y: ty) }
            }
        }
        return (best, at)
    }
}

/// `--selftest DIR`: scripted transitions rendered at 240 Hz on a virtual clock, checked for the glitches a
/// person would see: a pop when motion starts, a pop at the hand-off when it ends, a spike between two
/// frames mid-motion, and state left behind after a round trip.
@MainActor enum SelfTest {
    struct Finding { let scenario: String; let kind: String; let time: Double; let value: Double; let at: CGPoint; let files: [String] }

    static let rate = 240.0
    static let popThreshold = 2.0

    /// Every scenario at 1× and at 2× (regression b022: first-frame pixel alignment at both), each in its own folder.
    /// SELFTEST_SCALES=1 or 2 runs one of them, so scripts/selftest.sh can run both at once in two processes.
    static func run(to path: String, size: CGSize) -> Int32 {
        if ProcessInfo.processInfo.environment["SELFTEST_BODY_PACKAGE"] == "1" { return BodyPackageVerification.run(to:path) }
        if ProcessInfo.processInfo.environment["SELFTEST_BODY_WIRING"] == "1" { return BodyWiringVerification.run(to: path) }
#if !M10_DOCK_SELFTEST && !ORGANIC_SELFTEST && !ORB_SELFTEST && !ISLAND_SELFTEST && !M9_SPLIT_SELFTEST && !M11_MODE_SELFTEST
        if ProcessInfo.processInfo.environment["SELFTEST_MOCK_BODY_STARTUP"] == "1" { return MockBodyStartupVerification.run(to:path) }
        if ProcessInfo.processInfo.environment["SELFTEST_ORB_SWITCH"] == "1" { return OrbInputVerification.run(to:path) }
#endif
        if ProcessInfo.processInfo.environment["SELFTEST_HEADER_PULSE"] == "1" {
            return HeaderPulseVerification.run(to: path)
        }
        if ProcessInfo.processInfo.environment["SELFTEST_LONG_CONVERSATION"] == "1" {
            return LongConversationVerification.run(to: path, size: size)
        }
        if ProcessInfo.processInfo.environment["SELFTEST_M101_COLUMNS"] == "1" {
            return M10ColumnGaussianVerification.run(to:path,size:size)
        }
        if ProcessInfo.processInfo.environment["SELFTEST_COLUMN_WORK"] == "1" {
            return M10ColumnWorkVerification.run(to:path,size:size)
        }
        if ProcessInfo.processInfo.environment["SELFTEST_M10_COLUMNS"] == "1" {
            return M10ColumnVerification.run(to:path,size:size)
        }
        var failed: Int32 = 0
        let only = ProcessInfo.processInfo.environment["SELFTEST_SCALES"].map { $0.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) } }
        for scale in only ?? [1, 2] {
            failed |= run(to: path + "/\(Int(scale))x", size: size, scale: scale)
        }
        return failed
    }

    static func run(to path: String, size: CGSize, scale: CGFloat) -> Int32 {
        let forcedRetirementsAtStart=ModeFlight.forcedRetirementCount
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConversationStore()
        let mock = MockReplay(store: store)
        mock.start(live: false)
        let profile = DisplayProfile(name: "selftest", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
        let scene = AutoScene(size: size, store: store, profile: profile, scale: scale)
        // The virtual clock must stay ahead of real time: CARenderer leaves out a commit whose timestamp is later than
        // the frame it renders, so a slow run (2× on the 8 GB MBA) whose real time overtook a 10 s lead lost every
        // flight after the prewarm. A run takes minutes, not an hour.
        var clock = CACurrentMediaTime() + 3600
        scene.now = { clock }
        scene.manualSettle = true
        scene.restOnSnapshot = true
        scene.ambient = false
        scene.install()
        guard let host = scene.sceneView.layer else { return 2 }
        let r = OffscreenRenderer(size: size, host: host, scale: scale)
        var findings: [Finding] = [], rows: [[String: Any]] = []
        var invisibleAnimations = OrbInvisibleAnimationVerification.retainedSatelliteFindings(scale: scale)
            + OrbInvisibleAnimationVerification.retainedControlFindings(scale: scale)
        var invisibleIDs = Set(invisibleAnimations.map(\.identity)), animationAuditSamples = 0
        var visibilityChecks: [[String: Any]] = []
        OrbRetainedControlVerification.run(scale: scale) { passed, name in
            visibilityChecks.append(["check": name, "passed": passed])
            if !passed { findings.append(Finding(scenario: "retained-animation-visibility", kind: name, time: 0, value: 1, at: .zero, files: [])) }
        }
        func auditAnimations(_ scenario: String) {
            animationAuditSamples += 1
            let roots = [scene.sceneView, scene.nativePlane, scene.peekNode.view, scene.dockView, scene.overlayPlane]
                + (NSApp?.windows.compactMap { $0.contentView?.superview ?? $0.contentView } ?? [])
            for finding in OrbInvisibleAnimationVerification.findings(in: roots, scenario: scenario, at: clock)
                where invisibleIDs.insert(finding.identity).inserted {
                invisibleAnimations.append(finding)
            }
        }

        /// Runs `steps` (offset from the scenario start → action), renders through the end, settles, checks.
        /// `contentChanges`: content arrives during the scenario, so the hand-off may show it (not a glitch).
        func scenario(_ name: String, compareWithStart: Bool, contentChanges: Bool = false, _ steps: [(Double, () -> Void)]) {
            let start = clock
            if clock < CACurrentMediaTime() + 60 {
                findings.append(Finding(scenario: name, kind: "virtual clock not ahead of real time", time: 0, value: clock - CACurrentMediaTime(), at: .zero, files: []))
            }
            // SELFTEST_ONLY=a,b (looking into a finding; commits run every scenario): the other scenarios still act and
            // settle, unrendered, because each scenario starts from where the one before it ended.
            if let only = ProcessInfo.processInfo.environment["SELFTEST_ONLY"]?.split(separator: ",").map(String.init), !only.contains(name) {
                for (offset, action) in steps.sorted(by: { $0.0 < $1.0 }) { clock = start + offset; action() }
                clock = max(clock, scene.transitionEnd) + 0.05
                scene.settle()
                clock += 0.2
                return
            }
            let before = r.render(at: start - 0.001)
            auditAnimations(name + "-before")
            var frames: [[UInt8]] = [], times: [Double] = []
            var pending = steps.sorted { $0.0 < $1.0 }
            var t = start
            var ended = false
            while !ended {
                while let first = pending.first, first.0 <= t - start + 1e-9 {
                    clock = start + first.0
                    first.1()
                    auditAnimations(name + "-step-\(first.0)")
                    pending.removeFirst()
                }
                clock = t
                frames.append(r.render(at: t)); times.append(t)
                ended = pending.isEmpty && t > scene.transitionEnd + 1 / rate
                t += 1 / rate
                if frames.count > 2000 { break }
            }
            // SELFTEST_DUMP=<scenario>: every frame of that scenario, to look at a run frame by frame.
            if ProcessInfo.processInfo.environment["SELFTEST_DUMP"] == name {
                for (k, f) in frames.enumerated() { r.write(f, dir.appendingPathComponent(String(format: "%@-frame%03d.png", name, k))) }
            }
            clock = scene.transitionEnd + 0.05
            scene.settle()
            let after = r.render(at: clock)
            auditAnimations(name + "-settled")

            func save(_ bytes: [UInt8], _ tag: String) -> String {
                let file = "\(name)-\(tag).png"; r.write(bytes, dir.appendingPathComponent(file)); return file
            }
            // A pop when motion starts: the first frame must look like the rest before it.
            let s = r.tileDiff(before, frames[0])
            if s.value > popThreshold {
                findings.append(Finding(scenario: name, kind: "pop at start", time: 0, value: s.value, at: s.at,
                                        files: [save(before, "start-before"), save(frames[0], "start-first")]))
            }
            // A pop at the hand-off: the last animated frame must look like the settled rest.
            let e = r.tileDiff(frames[frames.count - 1], after)
            if e.value > popThreshold && !contentChanges {
                findings.append(Finding(scenario: name, kind: "pop at hand-off", time: times.last! - start, value: e.value, at: e.at,
                                        files: [save(frames[frames.count - 1], "end-last"), save(after, "end-settled")]))
            }
            // A spike: one frame-to-frame change far above its neighbours'.
            let steps = (1..<frames.count).map { r.tileDiff(frames[$0 - 1], frames[$0]).value }
            for k in 2..<max(2, steps.count - 2) {
                let around = [steps[k - 2], steps[k - 1], steps[k + 1], steps[k + 2]].sorted()
                let median = (around[1] + around[2]) / 2
                if steps[k] > 8, steps[k] > 3 * median + 2 {
                    let d = r.tileDiff(frames[k], frames[k + 1])
                    findings.append(Finding(scenario: name, kind: "spike", time: times[k + 1] - start, value: steps[k], at: d.at,
                                            files: [save(frames[k], "spike\(k)-a"), save(frames[k + 1], "spike\(k)-b"),
                                                    save(r.heat(frames[k], frames[k + 1]), "spike\(k)-heat")]))
                }
            }
            // State left behind: after a round trip the rest must match the rest before it.
            if compareWithStart {
                let rt = r.tileDiff(before, after)
                if rt.value > popThreshold {
                    findings.append(Finding(scenario: name, kind: "state left after round trip", time: 0, value: rt.value, at: rt.at,
                                            files: [save(before, "roundtrip-before"), save(after, "roundtrip-after")]))
                }
            }
            rows.append(["scenario": name, "frames": frames.count, "durationSeconds": (times.last ?? start) - start,
                         "startPop": s.value, "handOffPop": e.value, "maxStep": steps.max() ?? 0,
                         "steps": steps.map { ($0 * 10).rounded() / 10 },
                         "switches": scene.switches.suffix(steps.count > 0 ? 3 : 0).map { $0["to"] ?? -1 },
                         "columnsAfter": scene.columnState])
            clock += 0.2
        }

        let n = scene.columns.count
        for (a, b) in [(0, 1), (1, 2), (2, 0)] where max(a, b) < n {
            scenario("switch-\(a)to\(b)", compareWithStart: false, [(0, { scene.switchTo(b, reason: "test") })])
            _ = a
        }
        // Prepared ahead at rest, committed later: must look exactly like a switch compiled on click.
        scene.prewarm()
        clock += 0.5
        let warm = (scene.fullIndex + 1) % n
        scenario("prewarmed-switch", compareWithStart: false, [(0, { scene.switchTo(warm, reason: "test-prewarmed") })])
        if let last = scene.lastSwitch, last["prewarmed"] as? Bool != true {
            findings.append(Finding(scenario: "prewarmed-switch", kind: "prewarmed switch was not used", time: 0, value: 0, at: .zero, files: []))
        }
        let base = scene.fullIndex
        for x in [0.03, 0.08, 0.16, 0.3] {
            let other = (base + 1) % n
            scenario("reverse-at-\(Int(x * 1000))ms", compareWithStart: true,
                     [(0, { scene.switchTo(other, reason: "test") }), (x, { scene.switchTo(base, reason: "test-reverse") })])
        }
        if n >= 3 {
            let one = (base + 1) % n, two = (base + 2) % n
            scenario("chain", compareWithStart: false, [(0, { scene.switchTo(one, reason: "test") }), (0.15, { scene.switchTo(two, reason: "test-chain") })])
        }
        // An orb lands in the last brief slot and its conversation's column comes in; that slot's column goes to an orb
        // (f035). Landing the one that left puts everything back. Then the same, reversed while it moves.
        let firstOrb = { scene.order.count > scene.columns.count ? scene.order[scene.columns.count] : nil }
        if let orb = firstOrb() {
            let lastBrief = scene.columns.last { $0.conversation.id != scene.current }?.conversation.id ?? ""
            scenario("land-roundtrip", compareWithStart: true, [(0, { scene.land(orb, reason: "test-land") }), (1.0, { scene.land(lastBrief, reason: "test-land-back") })])
            scenario("land-reverse-at-120ms", compareWithStart: true, [(0, { scene.land(orb, reason: "test-land") }), (0.12, { scene.land(lastBrief, reason: "test-land-back") })])
        }
        // Focused and back: the full column centres at reading width, the others go to orbs either side; leaving
        // puts Auto back exactly (f038). Then a graft into Split and out again (f040, f042).
        scenario("focused-roundtrip", compareWithStart: true, [(0, { scene.enterFocused(scene.current, reason: "test") }), (1.0, { scene.leaveFocused(reason: "test") })])
        if let orb = firstOrb() {
            scenario("split-graft-roundtrip", compareWithStart: true, [
                (0, { scene.enterFocused(scene.current, reason: "test") }),
                (0.9, { scene.graft(orb, at: 1, reason: "test") }),
                (1.8, { scene.ungraft(orb, reason: "test") }),
                (2.7, { scene.leaveFocused(reason: "test") })])
        }
        // Streaming into the column that is growing and into the one that is shrinking, mid-motion.
        let grow = (scene.fullIndex + 1) % n, shrink = scene.fullIndex
        let ids = [scene.columns[grow].conversation, scene.columns[shrink].conversation].map { c in (c.id, c.items.last { $0.kind == .assistant }?.id ?? "") }
        scenario("stream-during", compareWithStart: false, contentChanges: true, [(0, { scene.switchTo(grow, reason: "test") })] + (1...6).map { k in
            (Double(k) * 0.05, {
                for (thread, item) in ids {
                    store.apply(CoreEvent(id: 9000 + k, time: nil, method: "item/agentMessage/delta",
                                          params: ["threadId": .string(thread), "itemId": .string(item), "delta": " 增量"]))
                }
            })
        })

        // Archiving a brief column (last: it changes the working set for good): it shrinks away, the first orb comes
        // in as a column, and the others take their new widths (f054).
        if let brief = scene.columns.last(where: { $0.conversation.id != scene.current })?.conversation {
            scenario("archive-brief", compareWithStart: false, [(0, { brief.archived = true; store.changed(brief) })])
        }

        let forcedRetirements=ModeFlight.forcedRetirementCount-forcedRetirementsAtStart
        if forcedRetirements>0 {findings.append(Finding(scenario:"mode-flight",kind:"forced retirement",time:0,value:Double(forcedRetirements),at:.zero,files:[]))}
        let visualFindings = findings.count
        for finding in invisibleAnimations {
            findings.append(Finding(scenario: finding.scenario, kind: "invisible infinite animation: " + finding.key + " on " + finding.path + " hidden by " + finding.hiddenBy.joined(separator: ", "),
                                    time: finding.time, value: 1, at: .zero, files: []))
        }
        let report: [String: Any] = [
            "scenarios": rows, "renderHz": rate, "popThreshold": popThreshold,
            "visualFindings": visualFindings, "animationAuditSamples": animationAuditSamples,
            "invisibleInfiniteAnimations": invisibleAnimations.map(\.json), "visibilityChecks": visibilityChecks,
            "findings": findings.map { ["scenario": $0.scenario, "kind": $0.kind, "timeSeconds": $0.time, "value": $0.value,
                                        "at": [$0.at.x, $0.at.y], "files": $0.files] }]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("report.json"))
        }
        print("selftest \(Int(scale))x: \(rows.count) scenarios, \(findings.count) findings -> \(dir.path)")
        for f in findings { print(String(format: "  %@ · %@ · t=%.3f s · %.1f at (%.0f, %.0f)", f.scenario, f.kind, f.time, f.value, f.at.x, f.at.y)) }
        return findings.isEmpty ? 0 : 1
    }
}
