#if ORGANIC_SELFTEST
import AppKit
import QuartzCore

/// Independent offscreen checks for M9's Organic endpoints and width-only transitions. No windows or transport.
/// Compile with App/SelfTest.swift and App/Offscreen.swift (not App/Main.swift); the existing scene gate stays intact.
@main @MainActor enum OrganicM9Verification {
    static var checks = 0, findings: [String] = []
    static func check(_ value: Bool, _ label: String) {
        checks += 1
        if !value { findings.append(label); print("FINDING: " + label) }
    }
    static func main() {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/sol-m9-organic")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scales = ProcessInfo.processInfo.environment["SELFTEST_SCALES"]?.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) } ?? [1, 2]
        let peekOnly = ProcessInfo.processInfo.environment["M132_PEEK_ONLY"] == "1"
        for scale in scales {
            if !peekOnly { endpoints(scale: scale, output: output); widthTransitions(scale: scale, output: output) }
            peekHeader(scale: scale, output: output)
        }
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "checks open no windows")
        let result = "Organic M9: \(checks) checks, \(findings.count) findings\n" + findings.joined(separator: "\n")
        print(result)
        try? result.write(to: output.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        exit(findings.isEmpty ? 0 : 1)
    }

    static func endpoints(scale: CGFloat, output: URL) {
        sourceCoverage(scale: scale)
        let seeded = MockSeed.make()
        let store = ConversationStore(conversations: seeded, projects: MockSeed.projects, devices: MockSeed.devices)
        let a = seeded[0], b = seeded[1]
        let node = ColumnNode(a, store: store, identity: .systemTeal,
            rect: CGRect(x: 0, y: 0, width: 600, height: 820), full: true, scale: scale, logicalBottom: 714)
        for width: CGFloat in [220, 300, 420] {
            let s = node.snapshot(fullWidth: 563, briefWidth: width)
            check(abs(s.briefFrame.minY + s.briefOrigin.y + s.briefLayout.height - 692) < 0.001,
                "M9 brief bottom is logicalBottom−22 at \(width) / \(scale)x")
            node.restLayout(fullWidth: 563, briefWidth: width)
            let bottom = node.brief.frame.minY + (node.brief.sublayers?.first?.frame.maxY ?? -1000)
            check(abs(bottom - 692) < 0.001, "M9 resize uses the same brief bottom / \(scale)x")
        }
        let flightSnapshot = node.snapshot(fullWidth: 563, briefWidth: 300)
        if let line = flightSnapshot.pieces.first(where: { $0.look == .segment }) {
            let look = MorphLook.segment(BriefLine(words: [], lyricSize: flightSnapshot.lyricSize, current: true))
            let plan = MorphFlightMath.makePlan(element: .init(id: "m9-segment", look: look, target: .fixture),
                from: line.source, to: line.destination, towardBrief: false, style: .tuned, span: 563, centre: nil, present: true)
            let flight = FlightNode(line: line, plan: plan, bounds: CGRect(x: 0, y: 0, width: 1280, height: 820), scale: scale)
            let spring = Spring(from: 0, to: 1, response: 0.42, damping: 0.86, epsilon: Spring.restEpsilon / 1280)
            let time = Timeline(began: 0, duration: spring.duration, rate: 120)
            let forms = time.map { spring.sample($0).value }, rects = time.map { _ in CGRect(x: 0, y: 0, width: 563, height: 820) }
            let tracks = flight.tracks(time, rects: rects, forms: forms, earlierRects: rects, earlierForms: forms,
                lyricSize: flightSnapshot.lyricSize, profile: .init(name: "M9", frameInterval: 1/60, mmPerPoint: 0.27, persistenceFrames: 0), exposure: .init())
            let carrier = flight.replicator.sublayers![0], material = carrier.sublayers![0]
            let source = material.sublayers![0], endpoint = material.sublayers![1]
            let transforms = tracks.first { $0.layer === source && $0.key == "shell.transform" }?.animation.values as? [NSValue] ?? []
            check(transforms.contains { $0.caTransform3DValue.m11 < 1 }, "M9 source retains analytic scale overshoot; no epsilon clamp / \(scale)x")
            check(endpoint.opacity == 1 && source.opacity == 0 && CATransform3DIsIdentity(endpoint.transform),
                  "M9 landing uses the exact source bitmap while its scaled material is transparent / \(scale)x")
            check(CFEqual(source.contents as CFTypeRef, endpoint.contents as CFTypeRef), "M9 endpoint reuses the same glyph image / \(scale)x")
            check(material.shouldRasterize && material.rasterizationScale == scale && endpoint.compositingFilter as? String == "plusL",
                  "M9 endpoint coverage adds inside an isolated backing-scale material / \(scale)x")
            if ProcessInfo.processInfo.environment["M9_SAMPLING_PROBE"] == "1" {
                samplingProbe(line, scale: scale, output: output)
            }
        } else { check(false, "M9 fixture contains a narration flight / \(scale)x") }
        let owner = NativeTranscriptSessions()
        let borrowed = ColumnNode(a, store: store, identity: .systemTeal,
            rect: CGRect(x: 0, y: 0, width: 600, height: 820), full: false, scale: scale, logicalBottom: 714,
            transcriptSessions: owner)
        let s = borrowed.snapshot(fullWidth: 563, briefWidth: 300)
        check(s.withGoal == nil && abs(s.briefFrame.minY + s.briefOrigin.y + s.briefLayout.height - 692) < 0.001,
              "M9 a borrowed transcript uses the same endpoint without capturing its owner / \(scale)x")

        let t = NativeTranscript(conversation: b, store: store)
        t.wantsLayer = true
        t.decisionCardsInline = false; t.decisionCardsAtBottom = true
        t.frame = CGRect(x: 0, y: 0, width: 356, height: 584); t.refresh(); t.layoutSubtreeIfNeeded()
        let cards = descendants(t).compactMap { $0 as? NativeTranscriptCard }.filter(\.isApprovalCard)
        check(cards.count == b.approvals.count && !cards.isEmpty, "M9 Organic mounts each approval once / \(scale)x")
        if let card = cards.last {
            let frame = t.convert(card.approvalPlateRect, from: card)
            check(abs(frame.maxY - (t.bounds.maxY - 34)) <= 1, "M9 approval plate is 12pt above logicalBottom / \(scale)x")
            check(abs(frame.minX - 12) <= 1 && abs(frame.width - (356 - 24)) <= 1,
                  "M9 approval plate is 12pt inside a Split column / \(scale)x")
            check(card.approvalSource?.conversation == b.title && card.approvalSource?.isOtherConversation == false,
                  "M9 approval source is inside its own card / \(scale)x")
            check(!card.isDescendant(of: t.scrollView.documentView!), "M9 approvals do not scroll with message rows / \(scale)x")
        }
        check(!t.pinnedDecisionFrame.isEmpty, "M9 decision overlay is present / \(scale)x")
        check(t.subviews.compactMap { $0 as? NSScrollView }.filter { $0 !== t.scrollView }.allSatisfy { $0.contentView is NativeCardClipView },
              "M9 long decision stacks scroll on the backing pixel grid / \(scale)x")
        let image = t.snapshot(scale: scale)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("approval-\(Int(scale))x.png"))
        t.decisionCardsAtBottom = false
        check(t.pinnedDecisionFrame.isEmpty, "M9 Normie handoff withdraws the Organic overlay / \(scale)x")
        let external = t.externalDecisionCards(width: 356)
        check(external.first === cards.first, "M9 handoff retains the original decision controls / \(scale)x")
        let q = NativeTranscript(conversation: seeded[2], store: store)
        q.decisionCardsInline = false; q.decisionCardsAtBottom = true
        q.frame = CGRect(x: 0, y: 0, width: 356, height: 584); q.refresh(); q.layoutSubtreeIfNeeded()
        if let card = descendants(q).compactMap({ $0 as? NativeTranscriptCard }).first,
           let field = descendants(card).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
            let revision = q.captureRevision, height = card.frame.height
            field.stringValue = "Retained answer"; card.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            check(q.captureRevision > revision && card.frame.height == height,
                  "M9 local answer edits invalidate captures without changing model or height / \(scale)x")
            q.refresh(); check(field.stringValue == "Retained answer", "M9 bottom overlay preserves an edited answer / \(scale)x")
        } else { check(false, "M9 fixture contains an editable question / \(scale)x") }

        let geometry = HeaderIslandGeometry.make(variant: .newChat, columnWidth: 192,
            state: .init(titleWidth: 78, band: 0, scale: scale))
        check(geometry.capsule.size == CGSize(width: 192, height: 42), "M9 New Chat nameplate is 192×42 / \(scale)x")
        check(geometry.titleFont == 17 && geometry.planet.size == CGSize(width: 88, height: 88), "M9 seed typography/planet / \(scale)x")
        let draft = DraftColumn(placeholder: Conversation(id: "m9-draft", title: "New Chat"), store: store, scale: scale)
        for height: CGFloat in [380, 714] {
            draft.lay(CGRect(x: 0, y: 52, width: 420, height: height - 52))
            let top: CGFloat = 156, row = height - 28
            let centre = row - 24 - top >= 150 ? (top + row - 24) / 2 - 24 : top - 56
            check(abs(draft.island.frame.minY - (centre - 63).rounded()) < 0.001,
                  "M9 New Chat hero includes the 52pt top bleed / \(height) / \(scale)x")
        }
        let old = NSAppearance.current
        NSAppearance.current = NSAppearance(named: .aqua)
        let tint = Look.peekTint.usingColorSpace(.sRGB)!
        NSAppearance.current = old
        check(max(tint.redComponent, tint.greenComponent, tint.blueComponent) < 0.35 && abs(tint.alphaComponent - 0.55) < 0.001,
              "M9 detached Peek resolves its dark tint even in an Aqua drawing context / \(scale)x")
        check(NormieAccount.prototype.initials == "LL", "M9 Dock uses the shared LL account identity / \(scale)x")
        let layout = AutoLayout(size: CGSize(width: 1280, height: 820), count: 6, fullIndex: 0, metrics: .init())
        if let orb = layout.orbs.first {
            let g = layout.peek(over: orb, size: CGSize(width: 1280, height: 820), satelliteRows: 0, satellite: 12, metrics: .init())
            let underlyingBottom = (layout.columns.first?.maxY ?? 0) - 22
            check(underlyingBottom <= g.blur.maxY - 22, "M9 brief's final glyphs remain inside Peek's blur core / \(scale)x")
        }
    }

    static func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }

    static func sourceCoverage(scale: CGFloat) {
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = context.makeImage()!
        var reference: [UInt8] = []
        for mixed in [false, true] {
            let root = CALayer(); root.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            root.backgroundColor = NSColor(white: 0.118, alpha: 1).cgColor
            let group = CALayer(); group.frame = CGRect(x: 10, y: 10, width: 20, height: 20); root.addSublayer(group)
            let a = CALayer(); a.frame = group.bounds; a.contents = image; group.addSublayer(a)
            if mixed {
                a.opacity = 0.5
                let b = CALayer(); b.frame = group.bounds; b.contents = image; b.opacity = 0.5
                b.compositingFilter = "plusL"; group.addSublayer(b)
                group.shouldRasterize = true; group.rasterizationScale = scale
            }
            let renderer = OffscreenRenderer(size: root.bounds.size, host: root, scale: scale)
            let frame = renderer.render(at: CACurrentMediaTime() + 3600)
            if mixed { check(renderer.tileDiff(reference, frame).value < 0.1, "M9 glyph coverage does not dim at the endpoint crossfade midpoint / \(scale)x") }
            else { reference = frame }
        }
    }

    /// Diagnostic control: one stationary bitmap, no NativeTranscript, no replicator, no handoff. The only animated
    /// channel approaches identity through the same tiny scale interval as the historical 0.579s frame.
    static func samplingProbe(_ line: ColumnNode.FlightPiece, scale: CGFloat, output: URL) {
        let root = CALayer(); root.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        root.isGeometryFlipped = true; root.backgroundColor = Look.canvas.cgColor
        let glyphs = CALayer(); glyphs.anchorPoint = .zero; glyphs.contentsScale = scale
        glyphs.contents = line.sourceImage; glyphs.frame = line.source; root.addSublayer(glyphs)
        let renderer = OffscreenRenderer(size: root.bounds.size, host: root, scale: scale)
        let start = CACurrentMediaTime() + 3600, duration = 0.8
        let timeline = Timeline(began: 0, duration: duration, rate: 120)
        let values = timeline.map { NSValue(caTransform3D: CATransform3DMakeScale(0.9986 + 0.0014 * $0 / duration, 0.9986 + 0.0014 * $0 / duration, 1)) }
        timeline.track(glyphs, "transform", values)?.start(at: start)
        var previous = renderer.render(at: start), maximum = 0.0, peakTime = 0.0
        for i in 1...192 {
            let time = Double(i) / 240, frame = renderer.render(at: start + time)
            let delta = renderer.tileDiff(previous, frame)
            if delta.value > maximum {
                maximum = delta.value; peakTime = time
                renderer.write(previous, output.appendingPathComponent("sampling-raw-a-\(Int(scale))x.png"))
                renderer.write(frame, output.appendingPathComponent("sampling-raw-b-\(Int(scale))x.png"))
            }
            previous = frame
        }
        let record: [String: Any] = ["bitmapOnly": true, "nativeViews": 0, "replicators": 0,
            "maximumTileStep": maximum, "peakTime": peakTime, "scaleAtPeak": 0.9986 + 0.0014 * peakTime / duration]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("sampling-probe-\(Int(scale))x.json"))
        print("M9 bitmap-only sampling probe \(scale)x: \(record)")
    }

    static func widthTransitions(scale: CGFloat, output: URL) {
        let fixtures = MockSeed.make()
        let store = ConversationStore(conversations: fixtures, projects: MockSeed.projects, devices: MockSeed.devices)
        let profile = DisplayProfile(name: "M9", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
        let scene = AutoScene(size: CGSize(width: 1280, height: 820), store: store, profile: profile, scale: scale)
        var clock = CACurrentMediaTime() + 3600
        scene.now = { clock }; scene.manualSettle = true; scene.restOnSnapshot = true; scene.ambient = false; scene.install()
        let renderer = OffscreenRenderer(size: CGSize(width: 1280, height: 820), host: scene.sceneView.layer!, scale: scale)
        func finish() { clock = scene.transitionEnd + 0.05; scene.settle(); clock += 0.2 }
        scene.settle(); clock += 0.2
        renderer.write(renderer.render(at: clock), output.appendingPathComponent("auto-closed-\(Int(scale))x.png"))
        scene.enterFocused("A", reason: "m9-setup"); finish()

        func run(_ name: String, _ actions: [(Double, () -> Void)]) {
            let start = clock, before = renderer.render(at: clock - 0.001)
            var pending = actions.sorted { $0.0 < $1.0 }, time = start, frames = 0, last = before
            var samples: [(Double, CGPoint, [UInt8], [UInt8])] = []
            repeat {
                while let first = pending.first, first.0 <= time - start + 1e-9 {
                    clock = start + first.0; first.1(); pending.removeFirst()
                }
                clock = time
                let frame = renderer.render(at: time)
                if frames == 0 { check(renderer.tileDiff(before, frame).value <= 2, "M9 \(name) no pop at start / \(scale)x") }
                else {
                    let diff = renderer.tileDiff(last, frame)
                    samples.append((diff.value, diff.at, last, frame))
                    if samples.count == 5 {
                        let around = [samples[0].0, samples[1].0, samples[3].0, samples[4].0].sorted()
                        let centre = samples[2], median = (around[1] + around[2]) / 2
                        if centre.0 > 8 && centre.0 > 3 * median + 2 {
                            check(false, "M9 \(name) spike \(centre.0) at \(centre.1), t=\(time - start - 2/240) / \(scale)x")
                            renderer.write(centre.2, output.appendingPathComponent("\(name)-spike-a-\(Int(scale))x.png"))
                            renderer.write(centre.3, output.appendingPathComponent("\(name)-spike-b-\(Int(scale))x.png"))
                        }
                        samples.removeFirst()
                    }
                }
                last = frame; frames += 1; time += 1 / 240
            } while (!pending.isEmpty || time <= scene.transitionEnd + 1 / 240) && frames < 2000
            finish()
            let after = renderer.render(at: clock)
            let handoff = renderer.tileDiff(last, after)
            check(handoff.value <= 2, "M9 \(name) handoff \(handoff.value) / \(scale)x")
            check(frames < 2000, "M9 \(name) observes the whole spring / \(scale)x")
            for column in scene.columns where column.isFull {
                check(abs((column.applied?.full ?? 0) - column.rect.target.width) <= 0.01,
                      "M9 \(name) full layout width equals its column, \(column.conversation.id) / \(scale)x")
                check(abs(column.native.frame.width - column.rect.target.width) <= 0.01,
                      "M9 \(name) native width equals its final column / \(scale)x")
            }
            renderer.write(after, output.appendingPathComponent("\(name)-end-\(Int(scale))x.png"))
        }
        run("focused-split", [(0, { scene.graft("B", at: 1, reason: "m9-graft") })])
        run("split-focused", [(0, { scene.ungraft("B", reason: "m9-ungraft") })])
        run("split-width-reverse", [(0, { scene.graft("B", at: 1, reason: "m9-graft") }),
                                    (0.12, { scene.ungraft("B", reason: "m9-reverse") })])
        scene.disposeTranscriptPresentation()
    }
}
#endif
