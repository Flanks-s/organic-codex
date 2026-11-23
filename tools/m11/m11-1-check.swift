#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

#if !CHECK_PACKAGE_WHOLE_TREE
/// tools/bodies/run-regressions.py and run-host-regressions.py still compile this file with a hand-kept source list
/// that leaves App/RootView.swift out. tools/m11/m11-1-check.sh links the whole product tree (check_package.py) and
/// defines CHECK_PACKAGE_WHOLE_TREE, so it gets the real type. Remove this once those two follow the tree (debt #65).
@MainActor final class RootView: NSView { override var isFlipped: Bool { true } }
#endif

@main @MainActor enum M111Check {
    static var checks = 0, failures: [String] = [], costs: [[String: Any]] = []
    static func check(_ value: @autoclosure () -> Bool, _ name: String) { checks += 1; if !value() { failures.append(name); print("FAIL: " + name) } }
    static func image(_ view: NSView, scale: CGFloat) -> CGImage { NativeViewBitmap.capture(view, scale: scale) }
    static func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
    static func measure(_ name: StaticString, scale: CGFloat, _ action: () -> Void) {
        let begin = CACurrentMediaTime(); ModeSignposts.operation(name,detail:"offscreen component \(scale)x",action); costs.append(["phase": String(describing:name), "scale": scale, "ms": (CACurrentMediaTime() - begin) * 1000])
    }
    static func sourceContinuity(scale: CGFloat) {
        let size = CGSize(width: 96, height: 64)
        let context = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor.orange.cgColor); context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        let picture = context.makeImage()!
        let host = ModeFlight.Plane(frame: CGRect(origin: .zero, size: size)); host.wantsLayer = true
        let live = CALayer(); live.frame = host.bounds; live.contents = picture; host.layer!.addSublayer(live)
        let flight = ModeFlight.Plane(frame: host.bounds); flight.wantsLayer = true; host.addSubview(flight)
        let renderer = OffscreenRenderer(size: size, host: host.layer!, scale: scale)
        let t = VerificationClock.renderOrigin, before = renderer.render(at: t)
        let plate = ModeHandoffPlate(frame: .zero)
        plate.stage(picture, in: host, below: flight)
        // A detached AppKit view does not mount newly added backing layers into CARenderer's borrowed root.
        // Borrow the actual production plate layer explicitly, as the M10 windowless renderer does.
        func mount(_ v:NSView) {for child in v.subviews {if let layer=child.layer {v.layer?.addSublayer(layer)};mount(child)}}
        host.layer!.addSublayer(plate.layer!);mount(plate)
        check(before == renderer.render(at: t), "staged source has zero pixel cost at rest")
        plate.hold(picture, in: host, below: flight, holes: [])
        host.layer!.addSublayer(plate.layer!);mount(plate)
        live.contents = nil; live.backgroundColor = NSColor.black.cgColor
        let held = renderer.render(at: t)
        if before != held {
            let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first!)
            Offscreen.write(renderer.image(before), out.appendingPathComponent("plate-before-\(scale).png"))
            Offscreen.write(renderer.image(held), out.appendingPathComponent("plate-held-\(scale).png"))
            print("plate geometry \(plate.frame) layer=\(String(describing: plate.layer?.frame)) flipped=\(String(describing: plate.layer?.isGeometryFlipped))")
        }
        check(before == held, "source survives an entire underlying scene removal with zero changed bytes")
        check(plate.hitTest(CGPoint(x: 5, y: 5)) === plate, "source controls cannot fire behind a frozen image")
        var oldCompletion = false
        plate.revealDestination(duration: 0.005) { oldCompletion = true }
        plate.hold(picture, in: host, below: flight, holes: [])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        check(!oldCompletion && plate.picture?.tiles.first?.image === picture, "old fade completion cannot retire a reversed handoff")
        plate.clear(); check(plate.picture == nil && plate.superview == nil, "handoff retires source pixels")
    }
    static func main() throws {
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .darkAqua)

        ModeSignposts.receiptsEnabled = true
        ModeRegressionChecks.stagedReversal {value,name in check(value,name)}
        ModeRegressionChecks.modeReturnTranscripts {value,name in check(value,name)}
        ModeRegressionChecks.dockIdle {value,name in check(value,name)}
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/m11-1-check")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scale: CGFloat in [1, 2] {
            ModeRegressionChecks.avatarPaint(scale:scale) {value,name in check(value,name)}
            let store = ConversationStore(), size = CGSize(width: 1280, height: 820)
            let replay = MockReplay(store: store); replay.start(live: false)
            let sessions = NativeTranscriptSessions(store: store)
            let scene = AutoScene(size: size, store: store, profile: .init(name: "offscreen", frameInterval: 1/60, mmPerPoint: 0.27, persistenceFrames: 0), scale: scale, transcriptSessions: sessions)
            scene.ambient = false; scene.manualSettle = true
            let root = RootView(frame: CGRect(origin: .zero, size: size)); root.wantsLayer = true
            for plane in [scene.sceneView, scene.nativePlane, scene.peekNode.view, scene.dockView, scene.overlayPlane] { plane.frame = root.bounds; root.addSubview(plane) }
            let workbench = NormieWorkbench(store: store, sessions: scene.composers, current: store.conversations.first?.id, transcriptSessions: sessions)
            _ = workbench.select("F")
            _ = workbench.composerForHandoff()
            scene.install(); scene.settle()
            let shell = WindowShell(organic: root, scene: scene, workbench: workbench, mode: .organic)
            _ = shell.view; shell.split.view.isHidden = true
            ModeRegressionChecks.streamAndSourceRegressions(shell,scale:scale) {value,name in check(value,name)}
            let native = scene.columns.first!.native, nativeParent = native.superview
            let composer = scene.composers.composer(for: store.conversations[0], store: store), composerParent = scene.composers.composer(for: store.conversations[0], store: store).superview
            let draft = composer.text, selection = composer.textView.selectedRange(), revision = store.conversations[0].revision
            let before = image(root, scale: scale)
            measure("ModePrewarm", scale: scale) { shell.prepareModeSwitch(reason: "offscreen") }
            let after = image(root, scale: scale)
            check(bytes(before) == bytes(after), "\(scale)x prewarming preserves source pixels")
            check(native.superview === nativeParent, "prewarm never steals transcript lease")
            check(composer.superview === composerParent && composer.text == draft && composer.textView.selectedRange() == selection, "prewarm never remounts/mutates editor")
            check(store.conversations[0].revision == revision, "prewarm does not publish a model change")
            check(shell.verificationPreparationIsValid, "prepared key immediately valid")
            check(shell.verificationPreparedRows > 0, "hidden sidebar cells/flight anchors are materialized before input")
            check(shell.verificationPreparedRowsInBounds, "prepared visible row anchors lie inside the actual viewport")
            check(shell.verificationPreparedAvatar?.size == CGSize(width: 26, height: 26), "hidden sidebar avatar has a real 26pt endpoint before capture")
            let oldDocumentHeight = native.scrollView.documentView!.frame.height
            native.scrollView.documentView!.frame.size.height = native.scrollView.contentView.bounds.height + 100
            native.scrollOffset = CGPoint(x: 0, y: 1)
            check(native.scrollOffset.y == 1, "scroll fixture actually moved")
            check(!shell.verificationPreparationIsValid, "scroll invalidates source capture")
            native.scrollOffset = .zero
            native.scrollView.documentView!.frame.size.height = oldDocumentHeight
            shell.prepareModeSwitch(reason: "offscreen.scroll")
            _ = composer.setText(draft + " draft edit")
            check(!shell.verificationPreparationIsValid, "unpublished draft text invalidates source capture")
            _ = composer.setText(draft)
            shell.prepareModeSwitch(reason: "offscreen.draft")
            store.changed(store.conversations[0])
            check(!shell.verificationPreparationIsValid, "model revision invalidates source capture")

            var targetStages=0
            shell.verificationTargetObservation={stage,ids in
                targetStages+=1
                check(ids.allSatisfy{$0 == scene.current},"real target hierarchy \(stage) exposes only current conversation, got \(ids)")
            }
            measure("PostInputSequence.O2N",scale:scale) {shell.verificationColdAdmission()}
            shell.verificationFinishNormieReplay()
            check(targetStages>=2,"real target hierarchy checks hidden admission and validated reveal")
            shell.verificationTargetObservation=nil
            let normieGeometry=shell.verificationGeometryUnderDeltas(legacy:false)
            check(normieGeometry.ready && normieGeometry.tokens>=3,"Normie geometry also completes under deltas without waiting for revision-bound Organic picture preparation")
            let normieBefore = image(shell.split.view, scale: scale), normieParent = native.superview, editorParent = composer.superview
            measure("ModePrewarm.normieSource", scale: scale) { shell.prepareModeSwitch(reason: "offscreen.normie") }
            check(native.superview === normieParent && composer.superview === editorParent, "Organic prewarm never steals Normie leases/editor")
            check(bytes(normieBefore) == bytes(image(shell.split.view, scale: scale)), "Normie pixels unchanged by Organic prewarm")
            let count = workbench.detail.terminalFullLayoutCount
            measure("NormieLayout.repeat", scale: scale) { for _ in 0..<10 { workbench.detail.viewDidLayout() } }
            check(workbench.detail.terminalFullLayoutCount == count + 10, "baseline repeats endpoint layout")
            workbench.detail.freezeModeLayout(true)
            let frozen = workbench.detail.terminalFullLayoutCount
            measure("NormieLayout.frozen", scale: scale) { for _ in 0..<10 { workbench.detail.viewDidLayout() } }
            check(workbench.detail.terminalFullLayoutCount == frozen, "mode flight does not repeat endpoint layout")
            workbench.detail.freezeModeLayout(false)
            ModeRegressionChecks.idleMotion(workbench.detail,scale:scale) {value,name in check(value,name)}

            let source = workbench.sidebar.view, host = ModeFlight.Plane(frame: root.bounds)
            let sourceParent=source.superview,sourceFrame=source.frame
            source.frame = CGRect(x: 0, y: 0, width: 280, height: size.height); host.addSubview(source)
            source.layoutSubtreeIfNeeded()
            let exposure = M10SidebarExposure()
            measure("M10SidebarBegin.cold", scale: scale) { _ = exposure.begin(source: source, in: host, driven: false, scale: scale) }
            exposure.finish()
            let picture = image(source, scale: scale)
            measure("M10SidebarBegin.prepared", scale: scale) { _ = exposure.begin(source: source, in: host, driven: false, scale: scale, prepared: picture) }
            check((exposure.image.contents as AnyObject?) === picture, "hot sidebar uses prepared CGImage identity")
            exposure.finish()
            sourceParent?.addSubview(source);source.frame=sourceFrame

            let c = store.conversations[0], row = CGRect(x: 26, y: 150, width: 16, height: 16)
            for forward in [true, false] {
                let header = CGRect(x: 390, y: 24, width: forward ? 56 : 44, height: forward ? 56 : 44)
                let token = ModeFlight.Token(id: "header." + c.id, conversation: c, from: forward ? row : header, to: forward ? header : row, start: 0.08, absorbed: !forward)
                let flight = ModeFlight(); flight.manualTime = { 1000 }; flight.resize(to: size)
                let cold = ModeFlight(); cold.manualTime = { 1000 }; cold.resize(to: size)
                measure("ModeFlightStart.cold", scale: scale) { cold.start(toOrganic: forward, avatar: (row, header), initials: "LL", tokens: [token], composer: nil, reduceMotion: false) }
                cold.shutdown()
                measure("ModeFlightPrewarm", scale: scale) { flight.prewarm(tokens: [token]) }
                measure("ModeFlightStart.prepared", scale: scale) { flight.start(toOrganic: forward, avatar: (row, header), initials: "LL", tokens: [token], composer: nil, reduceMotion: false) }
                check(flight.consumedPreparedTokens == 1, "header flight consumes one prewarmed resource")
                var records: [M10ModeFrameSample] = []; flight.onExposureSample = { records.append($0) }
                let profile = DisplayProfile(name: "60Hz", frameInterval: 1/60, mmPerPoint: 0.27, persistenceFrames: 0)
                flight.sample(at: 0, profile: profile)
                check(records.first(where: { $0.id == "planet." + token.id })?.now == token.from, "header starts at actual header/row, never composer")
                records = []; flight.sample(at: 0.07, profile: profile)
                let beforeAdmission = records.map(\.now)
                flight.manualTime = { 1000.07 }; records = []
                check(flight.continuePrepared(toOrganic: forward, avatar: header, tokens: [token], composer: nil, reduceMotion: false), "same prepared destination continues its original clock")
                check(zip(beforeAdmission, records.map(\.now)).allSatisfy { MotionStep.edge($0, $1) < 1e-8 } && records.count == beforeAdmission.count, "native admission never resets the first flight pose")
                records = []; flight.sample(at: token.start + (forward ? 0.32 : 0.28), profile: profile)
                check(records.first(where: { $0.id == "planet." + token.id }).map { MotionStep.edge($0.now, token.to) < 1e-5 } ?? false, "header lands at matching row/header")
                check(flight.verificationGlass.allSatisfy { $0.1.contentView?.layer.map { M10ModeRenderBudget.inspect($0, scale: scale).violations.isEmpty } ?? true }, "header replicators contain glyphs only")
                flight.shutdown()
            }
            let changed=store.conversations[2]
            _=workbench.select(changed.id);workbench.detail.view.layoutSubtreeIfNeeded()
            shell.verificationAdmittedMode(.normie);shell.split.view.isHidden=false;root.isHidden=true
            let selectedNative=sessions.existingTranscript(for:changed.id)!, selectedHost=sessions.existingTranscript(for:changed.id)!.superview
            let beforeTarget=image(shell.split.view,scale:scale)
            measure("ModePrewarm.changedSelection",scale:scale) {shell.prepareModeSwitch(reason:"offscreen.changed.selection")}
            check(shell.verificationOrganicTokenIDs.contains("header."+changed.id),"changed Normie selection has an opening header token before native admission")
            check(selectedNative.superview === selectedHost,"mode target preparation never moves the visible selected viewport")
            check(bytes(beforeTarget)==bytes(image(shell.split.view,scale:scale)),"mode target preparation preserves Normie source pixels")
            let headerEnds=shell.verificationOrganicHeaderEnds
            var admitted=false,heldAtCommit=0
            measure("ModeNativeAdmission.N2O",scale:scale) {admitted=shell.verificationAdmitOrganic(heldAtCommit:&heldAtCommit)}
            check(scene.columns.allSatisfy {column in
                guard let island=column.island,let end=headerEnds["header."+column.conversation.id] else{return false}
                return MotionStep.edge(end,island.orb.glassView.convert(island.orb.glassView.bounds,to:shell.view))<0.5
            },"opening header endpoints equal the actual admitted destinations")
            check(admitted && scene.current==changed.id,"versioned Organic mode target commits the selected conversation")
            check(heldAtCommit==1,"at the commit only the full target claims a native viewport")
            check(scene.columns.allSatisfy{$0.ownsNative},"when the flight ends the brief columns take theirs (user 11-01: they went full empty)")
            check(scene.composers.existingComposer(for:changed.id)?.isDescendant(of:scene.dockView) == true,"the selected real editor returns to its Organic bar")
            check(selectedNative.superview === scene.nativePlane,"selected transcript retains identity at the Organic destination")
            shell.prepareModeSwitch(reason:"offscreen.real.shell.layers")
            ModeRegressionChecks.runShell(shell,scale:scale,output:output) {value,name in check(value,name)}
            shell.disposeModePreparation(); workbench.dispose(); scene.disposeTranscriptPresentation()
        }
        for scale: CGFloat in [1, 2] { sourceContinuity(scale: scale) }
        ModeRegressionChecks.run(output) { value,name in check(value,name) }
        let gate = ModeAdmissionGate(); var admitted = 0
        gate.arm { admitted += 1 }; check(gate.waitingForFrame && admitted == 0, "admission waits for a production frame")
        gate.presentedFrame(interval: 0.001); gate.cancel()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        check(admitted == 0, "cancelled generation cannot admit a stale target")
        gate.arm { admitted += 1 }; gate.presentedFrame(interval: 0.001)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        check(admitted == 1 && !gate.waitingForFrame, "one first frame admits exactly once")
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "no visible windows")
        print("AppKit auxiliary windows: " + NSApp.windows.map { "\(type(of: $0)):visible=\($0.isVisible)" }.joined(separator: ", "))
        let report: [String: Any] = ["checks": checks, "findings": failures, "costs": costs, "modeSwitchLog": ModeSignposts.receipt, "scope": "offscreen preparation and production component calls; no input-to-display measurement"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("verification.json"))
        print("M11-1: \(checks) checks, \(failures.count) findings; \(output.path)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
