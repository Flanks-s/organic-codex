import AppKit
import QuartzCore

/// Windowless, synthetic mock-shaped history. Enter only through --selftest's early return.
@MainActor enum LongConversationVerification {
    static func fixture(_ count: Int, singleTurn: Bool = true) -> Conversation {
        let c = Conversation(id: "A", title: "Long offline conversation")
        c.running = true; c.activeTurnID = "long"
        c.items = (0..<count).map { i in
            let kind: RowKind, text: String
            switch i % 4 {
            case 0: kind = .user; text = "Check the column layout and retain its native text \(i)."
            case 1: kind = .reasoning; text = "I checked the layout and found the smallest change for the native column."
            case 2: kind = .tool(.command); text = "swift build\nBuild complete."
            default: kind = .assistant; text = "I fixed the layout and kept the native text aligned. The checks passed."
            }
            return .init(id: "long-\(i)", turnID: singleTurn ? "long" : "turn-\(i / 4)", kind: kind, text: text)
        }
        c.items[c.items.count - 1].status = "running"
        return c
    }
    static func run(to path: String, size: CGSize) -> Int32 {
        let out = URL(fileURLWithPath: path); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var results: [[String: Any]] = [], failures: [String] = [], checks = 0
        @MainActor func check(_ condition: Bool, _ message: String) { checks += 1; if !condition { failures.append(message); print("FINDING", message) } }
        @MainActor func time(_ body: () -> Void) -> Double { let t = CACurrentMediaTime(); body(); return (CACurrentMediaTime() - t) * 1000 }
        @MainActor func sample(_ name: String, _ n: Int, _ values: [Double]) {
            let sorted = values.sorted()
            let report: [String: Any] = ["case": name, "items": n, "samples": values.count, "meanMS": values.reduce(0,+)/Double(values.count), "p50MS": sorted[sorted.count/2], "maxMS": sorted.last!]
            results.append(report); print(report)
        }
        semanticChecks(check: check)
        peekPixels(to: out, check: check)
        for n in [2000, 20000] { autoreleasepool {
            let c = fixture(n), other = Conversation(id: "B", title: "Other")
            other.items = [.init(id: "other-user", turnID: "other", kind: .user, text: "Other question"), .init(id: "other-answer", turnID: "other", kind: .assistant, text: "A short answer.")]
            let extra = (0..<6).map { Conversation(id: "orb-\($0)", title: "Orb \($0)") }
            let store = ConversationStore(conversations: [c, other] + extra, projects: MockSeed.projects, devices: MockSeed.devices)
            let sessions = NativeTranscriptSessions()
            let scene = AutoScene(size: size, store: store, profile: .init(name: "long-selftest", frameInterval: 1/120, mmPerPoint: 0.2, persistenceFrames: 0), scale: 2, transcriptSessions: sessions)
            scene.verificationPresented = true; scene.manualSettle = true; scene.ambient = false
            var clock = VerificationClock.renderOrigin; scene.now = { clock }
            let bench = NormieWorkbench(store: store, sessions: NativeComposerSessions(), current: c.id, transcriptSessions: sessions)
            bench.setTranscriptPresentationActive(false)
            let host = NormieView(frame: CGRect(origin: .zero, size: size))
            host.addSubview(bench.sidebar.view); host.addSubview(bench.detail.view)
            bench.sidebar.view.frame = CGRect(x: 0, y: 0, width: 240, height: size.height)
            bench.detail.view.frame = CGRect(x: 240, y: 0, width: size.width - 240, height: size.height)
            bench.refresh(); scene.setTranscriptPresentationActive(true)
            sample("install", n, [time { scene.install(members: ["A", "B"] + extra.map(\.id)); scene.clock.invalidate() }])
            @MainActor func settle() { clock = max(clock, scene.transitionEnd + 0.1); scene.clock.onFrame?(clock); scene.settle(); scene.clock.invalidate() }
            settle()
            var serial = 0, applyValues: [Double] = []
            @MainActor func feed(_ reasoning: Bool = false) {
                serial += 1
                let id = "long-\(n - (reasoning ? 3 : 1))"
                let began = CACurrentMediaTime()
                store.apply(.init(id: serial, time: Double(serial), method: reasoning ? "item/reasoning/summaryTextDelta" : "item/agentMessage/delta", params: ["threadId": "A", "turnId": "long", "itemId": .string(id), "delta": " delta"]))
                applyValues.append((CACurrentMediaTime() - began) * 1000)
                host.layoutSubtreeIfNeeded(); scene.nativePlane.layoutSubtreeIfNeeded()
            }
            var values: [Double] = []
            for _ in 0..<64 { values.append(time { feed() }) }
            sample("delta-full-store-scene-sidebar-layout", n, values)
            sample("delta-full-publication", n, applyValues); applyValues = []
            check(scene.columns.first?.native.renderedRevision == c.revision, "full delta consumed final revision \(n)")
            let fullScans = scene.columns.first!.native.historyScanCount
            check(fullScans < 30, "typed full deltas do not rebuild history \(n)")
            M10ColumnWorkTrace.reset()
            sample("switch-sync", n, [time { scene.switchTo(1, reason: "long-selftest") }])
            results.append(["case": "switch-breakdown", "items": n, "milliseconds": scene.prepareBreakdown])
            try? M10ColumnWorkTrace.write(to: out.appendingPathComponent("switch-\(n).json"))
            settle()
            values = []
            for i in 0..<64 { values.append(time { feed(i % 2 == 0) }) }
            sample("delta-brief-store-summary-dock-sidebar-layout", n, values)
            sample("delta-brief-publication", n, applyValues); applyValues = []
            sample("summary-visible", n, [time { _ = SummaryLog(c, playful: Look.playful, lineLimit: 30) }])
            sample("summary-explicit-full-materialization", n, [time { _ = SummaryLog(c, playful: Look.playful) }])
            check(c.summarySource.rebuilds == 1, "precise deltas reuse one summary structure \(n)")
            do {
                let g = scene.layout.peek(over: CGRect(x: 1000, y: size.height - 70, width: 50, height: 50), size: size, satelliteRows: 1, satellite: 19, metrics: .tuned(for: size))
                M10ColumnWorkTrace.reset()
                sample("peek-open", n, [time { scene.peekNode.open(c, geometry: g) }])
                try? M10ColumnWorkTrace.write(to: out.appendingPathComponent("peek-\(n).json"))
                sample("peek-scroll-top", n, [time { scene.peekNode.scroll(by: 10_000_000) }])
                sample("peek-scroll-bottom", n, [time { scene.peekNode.scroll(by: -10_000_000) }])
                check(scene.peekNode.mountedLyricCount > 0 && scene.peekNode.mountedLyricCount < 40, "Peek keeps bounded rows and full scroll document \(n)")
                scene.peekNode.dismiss(); scene.peekNode.clear()
            }
            var target: AutoScene.ModeTargetPlan?
            sample("mode-target-begin", n, [time { target = scene.beginModeTarget(selected: c.id) }])
            var steps: [Double] = []
            if let target { while !target.ready { steps.append(time { _ = scene.prepareModeTargetStep(target) }) } }
            sample("mode-target-step", n, steps)
            sample("mock-terminal-select-history", n, [time { let terminal = NormieMockTerminal(); terminal.refresh(c); _ = terminal.history }])
            var builder: ModeSurfaceBuilder!
            sample("mode-surface-builder-init", n, [time {
                builder = ModeSurfaceBuilder(scene.sceneView, scale: 2, includeWindowFrame: false,
                    detached: [(scene.nativePlane, scene.nativePlane.frame, scene.sceneView.bounds), (scene.dockView, scene.dockView.frame, scene.sceneView.bounds)])
            }])
            var tiles: [Double] = []
            while !builder.ready { tiles.append(time { builder.step() }) }
            sample("mode-source-tile", n, tiles)
            results.append(["case": "mode-source-total", "items": n, "milliseconds": tiles.reduce(0,+)])
            check(builder.finish()?.tiles.count == tiles.count && !tiles.isEmpty, "mode source completes all offline tiles \(n)")
            scene.verificationPresented = false; scene.setTranscriptPresentationActive(false); bench.setTranscriptPresentationActive(true)
            _ = bench.select(other.id); bench.detail.view.layoutSubtreeIfNeeded()
            sample("normie-select-long", n, [time { _ = bench.select(c.id); bench.detail.view.layoutSubtreeIfNeeded() }])
            values = []; for _ in 0..<64 { values.append(time { feed() }) }; sample("delta-normie", n, values)
            sample("delta-normie-publication", n, applyValues); applyValues = []
            check(c.items.count == n && c.items.last!.text.hasSuffix(" delta"), "fixture history and deltas retained \(n)")
            sample("layout-without-delta", n, (0..<8).map { _ in time { host.layoutSubtreeIfNeeded(); scene.nativePlane.layoutSubtreeIfNeeded() } })
            sample("mode-normie-prepare-transcript-snapshots", n, [time { bench.detail.prepareTranscriptSnapshots() }])
            let normieBuilder = ModeSurfaceBuilder(bench.detail.view, scale: 2, includeWindowFrame: false)
            var normieTiles: [Double] = []
            while !normieBuilder.ready { normieTiles.append(time { normieBuilder.step() }) }
            sample("mode-normie-source-tile", n, normieTiles)
            results.append(["case": "mode-normie-source-total", "items": n, "milliseconds": normieTiles.reduce(0,+)])
            scene.disposeTranscriptPresentation(); sessions.dispose()
        } }
        let report: [String: Any] = ["checks": checks, "failures": failures, "optimized": !_isDebugAssertConfiguration(), "results": results]
        if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? json.write(to: out.appendingPathComponent("long-conversation.json")) }
        print("Long conversation: \(checks) checks, \(failures.count) failures")
        return failures.isEmpty ? 0 : 1
    }
    static func peekPixels(to out: URL, check: (Bool, String) -> Void) {
        for scale: CGFloat in [1, 2] { autoreleasepool {
            let c = fixture(96); c.running = false; c.items[c.items.count - 1].status = nil
            let size = CGSize(width: 1200, height: 800)
            let g = AutoLayout().peek(over: CGRect(x: 700, y: 730, width: 48, height: 48), size: size, satelliteRows: 1, satellite: 18, metrics: .tuned(for: size))
            let peek = PeekNode(size: size, scale: scale); peek.ambient = false; peek.motionEnabled = false
            peek.open(c, geometry: g)
            // The scalar oracle follows the real brief boundary; text still uses the uncached original layout.
            let contentTop=(HeaderIslandVariant.brief.metrics(band:HeaderIslandVariant.band(bleedTop:g.blur.minY)).contentTop*scale).rounded()/scale
            let clipTop=max(g.lyrics.minY,contentTop-18)
            let lyricSize=CGSize(width:g.lyrics.width,height:max(1,g.lyrics.maxY-clipTop))
            let reference = BriefLayout(SummaryLog(uncached: c, playful: Look.playful), width: max(60, g.lyrics.width - 40), columnWidth: g.lyrics.width, scale: scale, showsState: true)
            @MainActor func render(_ layer: CALayer) -> CGImage {
                let context = CGContext(data: nil, width: Int(g.lyrics.width * scale), height: Int(lyricSize.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: scale, y: scale); layer.render(in: context); return context.makeImage()!
            }
            for location in ["end", "top", "middle", "end-again"] {
                let origin: CGFloat
                if location == "top" { peek.scroll(by: 10_000_000); origin = 16 }
                else if location == "middle" {
                    let line = reference.lineCount / 2
                    peek.verificationScrollToLine(line)
                    origin = -(reference.parts.first { $0.line == line }?.frame.minY ?? 0)
                } else {
                    if location == "end-again" { peek.scroll(by: -10_000_000) }
                    let minimum = max(0, lyricSize.height - 70), document = 16 + max(reference.height, minimum) + 22
                    origin = 16 + max(0, minimum - reference.height) + min(0, lyricSize.height - document)
                }
                let expected = CALayer(); expected.isGeometryFlipped = peek.verificationLyricsLayer.contentsAreFlipped(); expected.anchorPoint = .zero; expected.bounds = CGRect(origin: .zero, size: lyricSize); expected.masksToBounds = true
                let fade = CAGradientLayer(); fade.anchorPoint = .zero; fade.frame = expected.bounds
                fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]; fade.locations = [0, NSNumber(value: Double(16 / max(16, lyricSize.height)))]; expected.mask = fade
                let liveContent=peek.verificationLyricsLayer.sublayers!.first!
                let liveOrigin=liveContent.frame.minY
                let liveRows=Dictionary(uniqueKeysWithValues:(liveContent.sublayers ?? []).compactMap { row -> (Int,CALayer)? in
                    guard let name=row.name,let reverse=Int(name) else{return nil}
                    return (reference.lineCount-1-reverse,row)
                })
                // Fenwick prefixes and the full layout sum in different orders. Verify world positions independently,
                // then share the equivalent local origins so CALayer's float raster phase is identical at integer edges.
                var positionError:CGFloat=0
                let content = CALayer(); content.anchorPoint = .zero; content.frame = CGRect(x: 20, y: liveOrigin, width: max(60, g.lyrics.width - 40), height: max(1, reference.height)); expected.addSublayer(content)
                for line in 0..<reference.lineCount {
                    let parts = reference.parts.filter { $0.line == line }
                    guard let first = parts.first else { continue }
                    let box = parts.dropFirst().reduce(first.frame) { $0.union($1.frame) }
                    var rowY=box.minY+(origin-liveOrigin)
                    if let live=liveRows[line] {
                        positionError=max(positionError,abs((liveOrigin+live.frame.minY)-(origin+box.minY)))
                        rowY=live.frame.minY
                    }
                    let row = CALayer(); row.anchorPoint = .zero; row.frame = CGRect(x: 0, y: rowY, width: content.bounds.width, height: box.height)
                    content.addSublayer(row)
                    for part in parts {
                        let layer = CALayer(); layer.anchorPoint = .zero; layer.frame = part.frame.offsetBy(dx: 0, dy: -box.minY); layer.opacity = part.current ? 1 : Look.olderLine
                        let text = CALayer(); text.anchorPoint = .zero; text.frame = CGRect(origin: .zero, size: part.frame.size); text.contents = part.image; text.contentsScale = scale; text.contentsGravity = .resize
                        layer.addSublayer(text); row.addSublayer(layer)
                    }
                }
                let actual = render(peek.verificationLyricsLayer), baseline = render(expected)
                let a = Array(actual.dataProvider!.data! as Data), b = Array(baseline.dataProvider!.data! as Data)
                let error = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 255
                print("PEEK PIXELS",location,scale,"maxChannel",error,"positionError",positionError)
                check(positionError<0.000001 && a.count == b.count && a.contains { $0 != 0 } && error <= 1, "Peek exact brief-clipped resting pixels \(location) \(Int(scale))x error=\(error) positionError=\(positionError)")
                let actualRep = NSBitmapImageRep(cgImage: actual), expectedRep = NSBitmapImageRep(cgImage: baseline)
                try? actualRep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("peek-\(location)-\(Int(scale))x.png"))
                try? expectedRep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("peek-reference-\(location)-\(Int(scale))x.png"))
            }
            peek.clear()
        } }
    }

    static func semanticChecks(check: (Bool, String) -> Void) {
        let c = fixture(24), store = ConversationStore(conversations: [])
        store.add(c)
        @MainActor func compare(_ label: String) {
            for playful in [false, true] {
                let reference = SummaryLog(uncached: c, playful: playful), indexed = SummaryLog(c, playful: playful)
                check(indexed == reference, "summary reference equivalence \(label) playful=\(playful)")
                for limit in [1, 3, 9] {
                    check(SummaryLog(c, playful: playful, lineLimit: limit).lines == Array(reference.lines.suffix(limit)), "bounded summary suffix \(label) / \(limit) / \(playful)")
                }
            }
        }
        compare("initial")
        for i in 0..<20 {
            let index = c.items.count - (i % 2 == 0 ? 1 : 3)
            c.items[index].text += " changed"; c.items[index].revision += 1
            store.changed(c, change: .itemChanged(itemID: c.items[index].id)); compare("delta-\(i)")
        }
        check(c.summarySource.rebuilds == 1, "typed tail updates do not rebuild summary")
        c.items[c.items.count - 1].status = nil
        store.changed(c, change: .itemChanged(itemID: c.items.last!.id)); compare("answer-completed")
        for (id, kind, turn) in [("steer", RowKind.user, "long"), ("think", .reasoning, "long"), ("next", .assistant, "long"), ("new-turn", .user, "next-turn"), ("new-thought", .reasoning, "next-turn")] {
            c.items.append(.init(id: id, turnID: turn, kind: kind, text: "A new source line that retains its spans.", status: kind == .user ? nil : "running"))
            store.changed(c, change: .itemAppended(itemID: id)); compare("append-" + id)
        }
        check(c.summarySource.rebuilds == 1, "new turns and Steer append without full history rebuild")
        c.running = false; c.error = .stopped; store.changed(c); compare("stopped")
        c.error = .running; store.changed(c); compare("failed-running")
        c.error = nil; c.question = "Choose a path"; store.changed(c); compare("question")
        c.question = nil; c.items.removeLast(3); store.changed(c); compare("rollback")
        c.items.swapAt(1, 4); store.changed(c); compare("reorder")
        c.items[0].text = "Edited goal\nSecond line"; store.changed(c); compare("goal-edit")
        c.items.append(.init(id: "idle-goal", turnID: "idle-new", kind: .user, text: "Only a goal in the latest turn"))
        store.changed(c); compare("idle-goal")
        check(c.state == .idle, "state distinguishes last-turn goal from older completed work")
        let rebuilds = c.summarySource.rebuilds
        for _ in 0..<20 { _ = c.state }
        check(c.summarySource.rebuilds == rebuilds, "idle orb state reuses transcript metadata")
        c.items = []; store.changed(c); compare("empty")
        c.items = [.init(id: "only-reason", turnID: "orphan", kind: .reasoning, text: "Reason without a user.", status: "running")]
        c.running = true; store.changed(c); compare("no-user")
        c.items.append(.init(id: "other-reason", turnID: "other", kind: .reasoning, text: "A different orphan turn."))
        store.changed(c, change: .itemAppended(itemID: "other-reason")); compare("no-user-new-turn")
    }

}
