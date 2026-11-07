#if ORGANIC_SELFTEST
import AppKit
import QuartzCore

extension OrganicM9Verification {
    /// Native endpoint geometry, passive input, and actual retained Dock decoration visibility. No window or Core.
    static func peekHeader(scale: CGFloat, output: URL) {
        let firstCheck = checks, firstFinding = findings.count
        let size = CGSize(width: 1280, height: 820)
        let c = LongConversationVerification.fixture(96)
        c.running = false; c.items[c.items.count - 1].status = nil
        c.identitySymbol = "mars"; c.identityTint = "ocean"
        let peek = PeekNode(size: size, scale: scale)
        peek.ambient = false; peek.motionEnabled = false
        func visibleGlass(_ view: NSView) -> Int {
            guard !view.isHidden, (view.layer?.opacity ?? 1) > 0 else { return 0 }
            return (view is NSGlassEffectView ? 1 : 0) + view.subviews.reduce(0) { $0 + visibleGlass($1) }
        }
        check(peek.headerFrame == nil && !peek.headerVisible, "M13.2 closed Peek has no mounted header / \(scale)x")
        check(visibleGlass(peek.view) == 0, "M13.2 closed Peek mounts zero extra glass / \(scale)x")
        for width: CGFloat in [220, 300, 360] {
            let top: CGFloat = width == 360 ? 144 : 52
            let g = AutoLayout.Peek(blur: CGRect(x: 40, y: top, width: width, height: 560),
                                   capsule: CGRect(x: 56, y: top + 468, width: width - 32, height: 48),
                                   lyrics: CGRect(x: 40, y: top, width: width, height: 458), rowsTop: top + 520, column: nil)
            peek.open(c, geometry: g)
            let reference = HeaderIsland()
            var input = HeaderIslandConfiguration.conversation(c, variant: .brief, columnWidth: width,
                                                              band: HeaderIslandVariant.band(bleedTop: g.blur.minY),
                                                              ambient: false, scale: scale)
            input.active = false; input.signals.satellites = []
            reference.configure(input)
            reference.setPresentationActive(false)
            check(peek.header.geometry == reference.geometry, "M13.2 exact brief HeaderIslandGeometry / \(width) / \(scale)x")
            check(peek.header.configuration == input, "M13.2 shared header identity/title/mark configuration / \(width) / \(scale)x")
            check(visibleGlass(peek.view) == 2, "M13.2 exactly two visible header glass surfaces, no lobe / \(width) / \(scale)x")
            check(peek.headerFrame?.minY == 0 && peek.header.geometry.planet.minY == input.variant.metrics(band: input.band).planetTop,
                  "M13.2 header uses the corresponding brief column band / \(width) / \(scale)x")
            let lyricTop=max(g.lyrics.minY,reference.geometry.contentTop-18)
            let lyricRect=CGRect(x:g.lyrics.minX,y:lyricTop,width:g.lyrics.width,height:max(1,g.lyrics.maxY-lyricTop))
            check(peek.verificationLyricsLayer.frame == lyricRect, "M11.22 brief contentTop lyric viewport / \(width) / \(scale)x")
            let pose = peek.headerFrame
            peek.scroll(by: 10_000_000)
            check(peek.headerFrame == pose && peek.verificationLyricsLayer.frame == lyricRect,
                  "M13.2 scrolling retains fixed header and viewport / \(width) / \(scale)x")
            let avatar = peek.header.geometry.planet.offsetBy(dx: pose!.minX, dy: pose!.minY)
            check(peek.view.hitTest(CGPoint(x: avatar.midX, y: avatar.midY)) === peek.view,
                  "M13.2 passive header is protected by the Peek surface / \(width) / \(scale)x")
            check(!peek.header.planetButton.acceptsFirstResponder && !peek.header.titleButton.acceptsFirstResponder,
                  "M13.2 header adds no keyboard target / \(width) / \(scale)x")
            if width == 300 {
                let actual = peek.header.snapshot(scale: scale), expected = reference.snapshot(scale: scale)
                check(actual.dataProvider?.data == expected.dataProvider?.data, "M13.2 exact shared header proxy pixels / \(scale)x")
                Offscreen.write(actual, output.appendingPathComponent("peek-header-proxy-\(Int(scale))x.png"))
                Offscreen.write(expected, output.appendingPathComponent("peek-header-reference-\(Int(scale))x.png"))
            }
            reference.dispose()
            peek.fadeLyrics(); peek.retract(); peek.clear()
            check(peek.headerFrame == nil && !peek.headerVisible, "M13.2 close detaches all header glass / \(width) / \(scale)x")
        }
        peek.open(c, geometry: .init(blur: CGRect(x: 40, y: 144, width: 300, height: 560),
                                    capsule: CGRect(x: 56, y: 612, width: 268, height: 48),
                                    lyrics: CGRect(x: 40, y: 144, width: 300, height: 458), rowsTop: 664, column: nil))
        peek.dismiss()
        check(peek.headerFrame == nil && !peek.headerVisible, "M13.2 immediate dismissal leaves no header / \(scale)x")
        peek.clear(); peek.header.dispose()

        let store = ConversationStore(); MockReplay(store: store).start(live: false)
        let scene = AutoScene(size: size, store: store,
                              profile: .init(name: "M13.2 offscreen", frameInterval: 1/120, mmPerPoint: 0.2, persistenceFrames: 0), scale: scale)
        scene.manualSettle = true; scene.ambient = false
        let root = IslandPlane(frame: CGRect(origin: .zero, size: size))
        for v in [scene.sceneView, scene.nativePlane, scene.peekNode.view, scene.dockView, scene.overlayPlane] { root.addSubview(v) }
        var time = CACurrentMediaTime() + 3600
        scene.now = { time }; scene.dock.motionTime = { time }
        scene.install(); scene.clock.invalidate()
        time = max(time, scene.transitionEnd + 0.1); scene.clock.onFrame?(time); scene.settle(); scene.clock.invalidate()
        // Dispatch stages and the Dock veil use the same continuously advancing clock, including setup work.
        let wallOrigin = CACurrentMediaTime(), sceneOrigin = time
        scene.now = { sceneOrigin + CACurrentMediaTime() - wallOrigin }
        scene.dock.motionTime = scene.now
        let closed = VerificationRaster.capture(scene.peekNode.view, scale: scale)
        let orbs = Array(scene.order.dropFirst(scene.layout.columns.count))
        guard orbs.count >= 2, let item = scene.dock.items[orbs[0]] else {
            check(false, "M13.2 fixture contains two overflow orbs"); return
        }
        let glass = item.glass, decoration = item.decoration
        func opacity(_ layer: CALayer) -> Float {
            var result: Float = 1, current: CALayer? = layer
            while let l = current { result *= l.isHidden ? 0 : l.opacity; current = l.superlayer }
            return result
        }
        func bodyOpacity(_ orb: OrbComponent) -> Float {
            // Inspect the mounted body plane, including the veil layer, without adding an Orb test API.
            guard let body = orb.glassView.contentView?.subviews.first(where: { String(describing: type(of: $0)) == "OrbDecorationView" }),
                  let motion = body.layer?.sublayers?.first?.sublayers?.first else { return 1 }
            return opacity(motion)
        }
        func singleAvatar(_ label: String) {
            let top = scene.peekNode.headerVisible
            let bottom = bodyOpacity(item.decoration) > 0
            check(!(top && bottom), "M13.2 no duplicate Dock/top identity: \(label) / \(scale)x")
        }
        var duplicateAtSample = false
        func wait(_ seconds: Double) {
            let start = CACurrentMediaTime()
            repeat {
                time = scene.now()
                scene.clock.onFrame?(time); scene.clock.invalidate()
                if scene.peekNode.headerVisible, let id = scene.shownPeek, let current = scene.dock.items[id] {
                    duplicateAtSample = duplicateAtSample || bodyOpacity(current.decoration) > 0
                }
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.003))
            } while CACurrentMediaTime() - start < seconds
            time = scene.now()
            scene.clock.onFrame?(time); scene.clock.invalidate()
        }
        scene.setPeeking(orbs[0]); scene.clock.invalidate()
        check(scene.peekNode.headerFrame != nil && !scene.peekNode.headerVisible, "M13.2 initial header waits for Dock veil / \(scale)x")
        singleAvatar("open start")
        wait(0.09); singleAvatar("before content")
        wait(0.08); singleAvatar("after veil")
        check(scene.peekNode.headerVisible && item.veilAmount(at: time) == 1 && bodyOpacity(decoration) == 0,
              "M13.2 top replaces the fully veiled Dock identity / \(scale)x")
        check(item.glass === glass && item.decoration === decoration && item.role == .orb && item.veil.to == 1,
              "M13.2 same Dock glass/decoration retained as capsule / \(scale)x")
        check(scene.peekNode.header.configuration?.id == orbs[0], "M13.2 top is the peeked conversation / \(scale)x")
        wait(0.25)
        Offscreen.write(scene.peekNode.header.snapshot(scale: scale), output.appendingPathComponent("peek-open-header-\(Int(scale))x.png"))
        // Glass is a documented proxy only in this offline overview. Real WindowServer refraction is not captured.
        let headerImage = scene.peekNode.header.snapshot(scale: scale), headerFrame = scene.peekNode.headerFrame!
        scene.peekNode.header.isHidden = true
        let base = VerificationRaster.capture(root, scale: scale)
        scene.peekNode.header.isHidden = false
        let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.draw(headerImage, in: CGRect(x: headerFrame.minX * scale, y: (size.height - headerFrame.maxY) * scale,
                                           width: headerFrame.width * scale, height: headerFrame.height * scale))
        Offscreen.write(context.makeImage()!, output.appendingPathComponent("peek-open-overview-proxy-\(Int(scale))x.png"))
        let lyrics = scene.peekNode.verificationLyricsLayer.frame
        check(scene.peekScroll(70, at: CGPoint(x: lyrics.midX, y: lyrics.midY)), "M13.2 original surface still takes scroll / \(scale)x")
        check(scene.peekNode.verificationLyricsLayer.frame == lyrics, "M13.2 scene scroll preserves viewport / \(scale)x")
        scene.setPeeking(nil); singleAvatar("close request")
        wait(0.09); singleAvatar("Dock returning")
        wait(0.28)
        check(scene.peekNode.headerFrame == nil && !scene.peekNode.headerVisible && scene.shownPeek == nil,
              "M13.2 staged close leaves no header / \(scale)x")
        check(item.glass === glass && item.veilAmount(at: time) == 0, "M13.2 original Dock orb returns / \(scale)x")
        let after = VerificationRaster.capture(scene.peekNode.view, scale: scale)
        check(closed.dataProvider?.data == after.dataProvider?.data, "M13.2 closed Peek plane roundtrip is pixel exact / \(scale)x")
        Offscreen.write(after, output.appendingPathComponent("peek-closed-\(Int(scale))x.png"))

        scene.setPeeking(orbs[0]); wait(0.04); scene.setPeeking(nil); wait(0.025)
        scene.setPeeking(orbs[0]); wait(0.17); singleAvatar("close/open reversal")
        check(scene.peekNode.headerVisible, "M13.2 reversed open reveals the current header / \(scale)x")
        scene.setPeeking(orbs[1]); wait(0.17)
        check(scene.peekNode.headerVisible && scene.peekNode.header.configuration?.id == orbs[1],
              "M13.2 retarget replaces the header identity / \(scale)x")
        scene.dismissPeek()
        check(scene.peekNode.headerFrame == nil && !scene.peekNode.headerVisible, "M13.2 transition dismissal detaches header / \(scale)x")
        wait(0.18)
        check(scene.peekNode.headerFrame == nil && !scene.peekNode.headerVisible, "M13.2 cancelled reveal cannot leave a header / \(scale)x")
        check(!duplicateAtSample, "M13.2 every sampled open/close/reverse/retarget has one identity / \(scale)x")
        // M11.12: dispatch tracking callbacks directly; scene.pointer alone never exercises them.
        let hoverFirst = checks, hoverFindings = findings.count
        scene.setPeeking(orbs[0]); scene.clock.invalidate()
        let lower = HeaderIsland()
        var lowerInput = scene.peekNode.header.configuration!
        lowerInput.active = true; lowerInput.reduceMotion = true
        lower.configure(lowerInput)
        lower.frame = scene.peekNode.headerFrame!
        scene.nativePlane.addSubview(lower)
        var hoverTime = CACurrentMediaTime()
        lower.now = { hoverTime }
        var expansionCount = 0
        lower.actions.expansion = { expanded, _ in if expanded { expansionCount += 1 } }
        let capsule = lower.geometry.capsule.offsetBy(dx: lower.frame.minX, dy: lower.frame.minY)
        let p = CGPoint(x: capsule.midX, y: capsule.midY)
        func enter(at point: CGPoint) -> NSEvent {
            NSEvent.enterExitEvent(with: .mouseEntered, location: root.convert(point, to: nil), modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                  trackingNumber: 0, userData: nil)!
        }
        let entered = enter(at: p)
        scene.pointer(nil)
        lower.mouseEntered(with: entered); hoverTime += 0.4; lower.advance(to: hoverTime)
        let coveredExpanded = lower.state.expanded ? 1 : 0
        check(!lower.state.hovering && !lower.state.expanded, "M11.12 covered mouseEntered cannot expand lower island / \(scale)x")
        scene.pointer(p)
        lower.hover(true); hoverTime += 0.4; lower.advance(to: hoverTime)
        check(!lower.state.hovering && !lower.state.expanded, "M11.12 explicit hover shares the shield / \(scale)x")
        check(root.hitTest(p) === scene.peekNode.view, "M11.12 covered header hit belongs to Peek / \(scale)x")
        check(lower.hitTest(p) == nil, "M11.12 lower header rejects a direct covered hit / \(scale)x")
        check(scene.peekClick(at: p) && scene.peekScroll(1, at: p), "M11.12 passive top header consumes click and scroll / \(scale)x")
        let probe = IslandButton(frame: capsule)
        scene.nativePlane.addSubview(probe)
        var clicks = 0, drags = 0
        probe.invoke = { clicks += 1 }
        probe.beginPointerGesture = { _ in drags += 1; return nil }
        probe.mouseEntered(with: entered)
        check(probe.pointerHighlight == 0, "M11.12 covered planet/satellite control cannot highlight / \(scale)x")
        let press = NSEvent.mouseEvent(with: .leftMouseDown, location: root.convert(p, to: nil), modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        probe.mouseDown(with: press)
        let coveredClicks = clicks, coveredDrags = drags
        check(clicks == 0 && drags == 0, "M11.12 covered press starts neither lower click nor drag / \(scale)x")
        let composerHost = NativeComposer(frame: capsule)
        scene.dockView.addSubview(composerHost)
        let composerProbe = NativeComposerMenuButton(frame: CGRect(origin: .zero, size: capsule.size))
        composerProbe.addItem(withTitle: "Model")
        composerHost.addSubview(composerProbe)
        let composerIdle = VerificationRaster.capture(composerProbe, scale: scale)
        composerProbe.mouseEntered(with: entered)
        check(composerIdle.dataProvider?.data == VerificationRaster.capture(composerProbe, scale: scale).dataProvider?.data,
              "M11.12 covered composer menu has no hover ink / \(scale)x")
        check(root.hitTest(p) === scene.peekNode.view, "M11.12 Dock composer cannot steal covered hit / \(scale)x")
        check(composerHost.hitTest(p) == nil, "M11.12 native composer rejects a covered hit / \(scale)x")
        composerHost.removeFromSuperview()
        let row = NativeTranscriptRow()
        let rowItem = TranscriptItem(id: "shield-user", turnID: "shield-turn", kind: .user, text: "Hover actions")
        row.onEdit = {}; row.onFork = {}
        row.configure(rowItem, sourceItem: rowItem, index: 0, items: [rowItem], width: capsule.width, expanded: false)
        row.frame.origin = capsule.origin
        scene.nativePlane.addSubview(row)
        row.mouseEntered(with: entered)
        check(row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.isEmpty,
              "M11.12 covered transcript row does not expose hover actions / \(scale)x")
        row.removeFromSuperview()
        scene.setPeeking(nil); wait(0.36)
        check(lower.state.hovering && !lower.state.expanded && probe.pointerHighlight > 0,
              "M11.12 stationary pointer resumes hover after staged close / \(scale)x")
        hoverTime += 0.279; lower.advance(to: hoverTime)
        check(!lower.state.expanded, "M11.12 restored hover retains authored 280ms wait / \(scale)x")
        hoverTime += 0.002; lower.advance(to: hoverTime)
        // A duplicate native entry must not replay the expansion notification.
        lower.mouseEntered(with: entered); hoverTime += 0.05; lower.advance(to: hoverTime)
        check(lower.state.expanded && expansionCount == 1, "M11.12 restored hover expands exactly once / \(scale)x")
        // A pre-existing expansion closes on its original 300ms hover departure, with no forced geometry change.
        scene.setPeeking(orbs[0])
        check(!lower.state.hovering && lower.state.expanded, "M11.12 open clears existing hover without snapping expansion / \(scale)x")
        hoverTime += 0.301; lower.advance(to: hoverTime)
        check(!lower.state.expanded, "M11.12 covered pre-hovered island settles on its existing close timing / \(scale)x")
        scene.pointer(nil); scene.setPeeking(nil); wait(0.36)
        check(!lower.state.hovering && !lower.state.expanded && probe.pointerHighlight == 0,
              "M11.12 departed pointer stays clear after staged close / \(scale)x")
        // Opening during the pending hover must cancel it, even without a subsequent tracking exit.
        lower.hover(true); hoverTime += 0.1; lower.advance(to: hoverTime)
        scene.pointer(p); scene.setPeeking(orbs[0]); hoverTime += 0.3; lower.advance(to: hoverTime)
        check(!lower.state.hovering && !lower.state.expanded, "M11.12 open cancels a pending pre-existing hover / \(scale)x")
        scene.dismissPeek()
        check(lower.state.hovering, "M11.12 immediate dismissal restores stationary hover / \(scale)x")
        scene.setPeeking(orbs[0]); scene.pointer(nil); scene.dismissPeek()
        check(!lower.state.hovering, "M11.12 immediate dismissal respects a departed pointer / \(scale)x")
        lower.dispose(); lower.removeFromSuperview(); probe.removeFromSuperview()
        print("M11.12 observed \(Int(scale))x: coveredExpanded=\(coveredExpanded), coveredClicks=\(coveredClicks), coveredDragStarts=\(coveredDrags), expansionCallbacks=\(expansionCount)")
        print("M11.12 Peek pointer \(Int(scale))x: \(checks - hoverFirst) checks, \(findings.count - hoverFindings) findings")
        scene.clock.invalidate(); scene.disposeTranscriptPresentation(); scene.peekNode.header.dispose()
        print("M13.2 Peek \(Int(scale))x: \(checks - firstCheck) checks, \(findings.count - firstFinding) findings")
    }
}
#endif
