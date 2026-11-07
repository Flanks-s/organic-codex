#if ORB_SELFTEST
import AppKit
import QuartzCore

/// Offscreen component package with ORB_SELFTEST, including the Core, Dock and Island adapters.
/// Synthetic, offscreen components only; never starts the normal application lifecycle or orders a window.
@main enum OrbVerification {
    @MainActor static func main() throws {
        OrbDisplayEnvironment.shared.setOverride(.init()); defer { OrbDisplayEnvironment.shared.setOverride(nil) }
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/orb-verification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks = 0, failures: [String] = [], notes: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { failures.append(label) }
        }
        OrbAmbientVerification.run { check($0, $1) }
        OrbAmbientVerification.corrections(to: directory) { check($0, $1) }
        OrbAmbientVerification.shortRound(to: directory) { check($0, $1) }
        OrbSatelliteVisibilityVerification.run(to: directory) { check($0, $1) }
        // M10.4 pickup uses independently authored decoration, not a copied AppKit/backdrop tree.
        for scale:CGFloat in [1,2] {
            let source=OrbComponent(id:"carry-source-\(scale)")
            let config=OrbConfiguration(content:.identity(.assigned(4)),drawingSize:56,
                badge:.init(tone:.yellow,symbol:.count(12)),ambient:false,backingScale:scale)
            source.configure(config);source.setCanvasSize(CGSize(width:120,height:120))
            let rect=CGRect(x:32,y:32,width:56,height:56);source.setFrame(rect)
            let parent=source.glassView.superview,metrics=source.metrics
            guard let carrier=source.prepareDragDecoration() else {check(false,"drag preparation");continue}
            carrier.setCanvasSize(CGSize(width:120,height:120));carrier.setFrame(rect)
            check(carrier.glassView !== source.glassView && carrier.backView !== source.backView,"carry owns fresh material and planes")
            check(source.glassView.superview === parent && source.metrics==metrics,"preparation does not mutate source")
            func pixels(_ orb:OrbComponent)->Data {
                let c=CGContext(data:nil,width:Int(120*scale),height:Int(120*scale),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.scaleBy(x:scale,y:scale);orb.renderOffscreenDecorations(in:c,planet:rect)
                return c.makeImage()!.dataProvider!.data! as Data
            }
            check(pixels(source)==pixels(carrier),"source and prepared carry draw identical static bytes @\(scale)x")
            let count=carrier.verificationHostGlyph.captures+carrier.verificationHostBadge.captures
            let profile=DisplayProfile(name:"M10.4 Dell",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
            let next=rect.offsetBy(dx:24,dy:0);carrier.setFrame(next)
            carrier.exposeGlyphs(now:next,earlier:rect,profile:profile)
            check(carrier.verificationHostGlyph.sample.count>1 && carrier.verificationHostBadge.sample.count>1,"carried identity and badge digits both accumulate")
            check(count==carrier.verificationHostGlyph.captures+carrier.verificationHostBadge.captures,"carry movement reuses prepared tight textures")
            carrier.exposeGlyphs(now:next,earlier:next,profile:profile)
            check(carrier.verificationHostGlyph.sample.count==1 && carrier.verificationHostBadge.sample.count==1,"carried orb rests native in same frame")
            source.dispose();carrier.glassView.removeFromSuperview();carrier.dispose()
        }

        // Exhaustive priority combinations, including red beating both kinds of yellow and green.
        for error in [nil, OrbBadge.ErrorState.running, .stopped] {
            for approvals in [0, 1, 12, 123] {
                for question in [false, true] {
                    for completions in [0, 1, 4] {
                        let badge = OrbBadge.resolve(error: error, approvals: approvals, question: question, completions: completions)
                        if let error {
                            check(badge == OrbBadge(tone: .red, symbol: error == .running ? .error : .stopped), "red priority")
                        } else if approvals > 0 {
                            check(badge == OrbBadge(tone: .yellow, symbol: .count(approvals)), "approval priority")
                        } else if question {
                            check(badge == OrbBadge(tone: .yellow, symbol: .question), "question priority")
                        } else if completions > 0 {
                            check(badge == OrbBadge(tone: .green, symbol: .count(completions)), "completion priority")
                        } else { check(badge == nil, "idle has no badge") }
                    }
                }
            }
        }
        check(OrbBadge.Symbol.count(123).text == "99+", "badge count caps at 99+")
        check(OrbBadge.Symbol.stopped.text == "x_x", "stopped face")
        check(OrbQuota(primaryUsed: nil, secondaryUsed: nil).tightestUsed == nil, "unknown quota remains unknown")
        check(OrbQuota(primaryUsed: nil, secondaryUsed: 0.6).tightestUsed == 0.6, "single reported quota")
        check(OrbQuota(primaryUsed: 0.34, secondaryUsed: 0.58).tightestUsed == 0.58, "tightest means most used")
        check(OrbQuota(primaryUsed: .nan, secondaryUsed: nil).tightestUsed == nil, "invalid report is unknown")
        check(OrbQuota(primaryUsed: 0, secondaryUsed: nil).tightestUsed == 0, "reported zero differs from unknown")
        check(OrbQuota(primaryUsed: nil, secondaryUsed: nil).summary == "Usage not reported", "unknown is never 100% left")
        check(OrbQuota(primaryUsed:.nan,secondaryUsed:0).summary == "100% left in reported limit","invalid primary is not a second reported quota")
        check(OrbQuota(primaryUsed:nil,secondaryUsed:nil,primaryWindowMinutes:nil,secondaryWindowMinutes:45).primaryTitle == "Primary limit","unknown quota window remains unknown")
        check(OrbQuota(primaryUsed:0,secondaryUsed:0,primaryWindowMinutes:120,secondaryWindowMinutes:45).secondaryTitle == "45-minute limit","reported nonstandard windows retain their duration")
        check(OrbCelestialBody.allCases.count == 13, "13 identities")
        let colors: [UInt32] = [0xBDB7B0, 0xF0B98A, 0x5DB4F0, 0xF2734D, 0xE2A86E, 0xE8C45A,
                                 0x6ED7DD, 0x8A97FF, 0xE89DAA, 0xA7B4C2, 0xC3A6F2, 0x7FD9A8, 0xDB8C6B]
        for i in 0..<13 {
            let identity = OrbIdentity.assigned(i)
            check(identity.symbol.rawValue == i && identity.tint.hex == colors[i], "identity assignment \(i)")
            check(!OrbCelestialGlyph(symbol: identity.symbol).path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).isEmpty,
                  "identity path \(i)")
            check(OrbIdentity.assigned(i+13).tint != identity.tint, "later palette round \(i)")
            for dark in [true,false] {
                NSAppearance(named:dark ? .darkAqua:.aqua)!.performAsCurrentDrawingAppearance {
                    let color=identity.tint.color.usingColorSpace(.sRGB)!,expected=dark ? identity.tint.hex:identity.tint.lightHex
                    check(abs(color.redComponent-CGFloat(expected >> 16 & 255)/255)<1e-6 && abs(color.greenComponent-CGFloat(expected >> 8 & 255)/255)<1e-6 && abs(color.blueComponent-CGFloat(expected & 255)/255)<1e-6,"identity \(i) \(dark ? "dark":"light") palette")
                }
            }
        }
        check(Set((0..<52).map { let v=OrbIdentity.assigned($0); return "\(v.symbol.rawValue):\(v.tint.rawValue)" }).count == 52,"first52 rendered identities do not repeat")
        for size:CGFloat in [44,48,56] {
            let shape=OrbOrbitShape.header(size),canonical=shape.scaled(by:56/size)
            let quarter=OrbSatellites.point(angle:.pi/2,size:56,shape:canonical),tilt = -18*Double.pi/180
            check(shape.diameter == 12 && shape.radius == size/2+10,"header satellite diameter/radius \(size)")
            check(abs((quarter.x-28)*size/56+16*sin(tilt))<1e-6 && abs((quarter.y-28)*size/56-16*cos(tilt))<1e-6,"header orbit vertical radius stays16 at \(size)")
        }

        let fixtures = makeFixtures()
        for scale in [CGFloat(1), 2] {
            for (label, fixture) in fixtures {
                var c = fixture; c.backingScale = scale
                try render(label: label, configuration: c, scale: scale, directory: directory)
            }
            try renderIdentities(scale: scale, directory: directory)
            try renderIdentities(scale:scale,directory:directory,appearance:.light)
        }

        let c = OrbComponent(id: "geometry")
        var configuration = fixtures[0].1
        c.configure(configuration)
        c.setCanvasSize(CGSize(width: 600, height: 400))
        // Drain already-requested NSView layout before the timed sampling, and again afterwards.
        c.backView.layoutSubtreeIfNeeded(); c.frontView.layoutSubtreeIfNeeded(); c.glassView.layoutSubtreeIfNeeded()
        let backFrame = c.backView.frame, frontFrame = c.frontView.frame
        c.setFrame(CGRect(x: 20, y: 20, width: 32, height: 32))
        let before = c.metrics
        let start = CACurrentMediaTime()
        for i in 0..<100 {
            let d = 32 + CGFloat(i % 17)
            c.setFrame(CGRect(x: CGFloat(i), y: 20, width: d, height: d))
        }
        let elapsed = (CACurrentMediaTime()-start)*1_000
        c.backView.layoutSubtreeIfNeeded(); c.frontView.layoutSubtreeIfNeeded(); c.glassView.layoutSubtreeIfNeeded()
        let after = c.metrics
        check(after.geometryCalls-before.geometryCalls == 100, "100 frame calls counted")
        check(after.layoutCalls == before.layoutCalls, "setFrame does not call layout")
        check(after.glyphPaths == before.glyphPaths && after.liquidPaths == before.liquidPaths &&
              after.badgePaths == before.badgePaths && after.glowPaths == before.glowPaths &&
              after.orbitBuilds == before.orbitBuilds && after.textLayouts == before.textLayouts,
              "setFrame does not build paths, orbits, or text")
        check(c.backView.frame == backFrame && c.frontView.frame == frontFrame, "view frames stay fixed")
        c.configure(configuration)
        check(c.metrics.configurations == after.configurations, "equal configuration is a no-op")
        check(c.backView.hitTest(.zero) == nil && c.frontView.hitTest(.zero) == nil, "decoration passes input")
        check(c.backView.isAccessibilityHidden() && c.frontView.isAccessibilityHidden(), "no duplicate AX")
        let wobble = c.verificationMotionLayers[3].animation(forKey: "wobble")
        check(wobble == nil, "M11.47 running liquid has no idle loop")
        check(c.verificationLiquidLevel == configuration.context, "running identity liquid keeps the reported context waterline")
        notes.append(String(format: "setFrame ×100: %.3f ms total; %.3f µs/call (CPU mutation time, no render-server flush)", elapsed, elapsed*10))
        notes.append("setFrame deltas: layout=0, glyphPaths=0, liquidPaths=0, badgePaths=0, glowPaths=0, orbitBuilds=0, textLayouts=0")

        // Pause all independent clocks at the same synthetic media timestamp; no waiting or window is needed.
        let now = CACurrentMediaTime()+0.25
        let phaseAtPause = c.verificationPhases(at: now)
        let liquidAtPause = c.verificationMotionLayers[3].convertTime(now, from: nil)
        c.verificationPause(true, at: now)
        let held = c.verificationPhases(at: now+12)
        for (a, b) in zip(phaseAtPause, held) {
            check(abs(a.0-b.0) < 1e-6 && abs(b.0-b.1) < 1e-6, "front/back hold the same phase")
        }
        check(abs(c.verificationMotionLayers[3].convertTime(now+12, from: nil)-liquidAtPause) < 1e-6, "liquid holds phase")
        c.verificationPause(false, at: now+12)
        let resumed = c.verificationPhases(at: now+12)
        for (a, b) in zip(phaseAtPause, resumed) { check(abs(a.0-b.0) < 1e-6, "resume has no phase jump") }
        let advanced = c.verificationPhases(at: now+12.5)
        for (a, b) in zip(resumed, advanced) { check(b.0 > a.0 && abs(b.0-b.1) < 1e-6, "resumed clocks advance together") }
        check(abs(c.verificationMotionLayers[3].convertTime(now+12, from: nil)-liquidAtPause) < 1e-6, "liquid resume continuous")

        // Real semantic updates while paused must retain phase and only change the subsequent rate.
        let p = OrbComponent(id: "pace")
        p.configure(configuration)
        configuration.ambient = false; p.configure(configuration)
        let phases = p.verificationPhases(at: CACurrentMediaTime())
        configuration.satellites[0].pace = 1
        p.configure(configuration)
        let rebased = p.verificationPhases(at: CACurrentMediaTime()+5)
        for (a, b) in zip(phases, rebased) { check(abs(a.0-b.0) < 1e-6 && abs(b.0-b.1) < 1e-6, "pace update during pause preserves phase") }
        configuration.ambient = true; p.configure(configuration)
        let resumedNow = CACurrentMediaTime()
        let resumedPhases = p.verificationPhases(at: resumedNow)
        let futurePhases = p.verificationPhases(at: resumedNow+1)
        check(abs((futurePhases[0].0-resumedPhases[0].0)-2.6) < 1e-5, "per-satellite pace maps to 2.6 rad/s")
        let loopBegin = p.verificationMotionLayers[3].animation(forKey: "wobble")?.beginTime
        configuration.context = 0.7; configuration.compactions += 1; p.configure(configuration)
        check(p.verificationMotionLayers[3].animation(forKey: "wobble")?.beginTime == loopBegin, "context change does not restart wobble")
        check(p.verificationSpinnerLayer.animation(forKey: "spin")?.duration == 0.9, "compaction spins liquid once over 0.9 s")

        let rowOrb = OrbComponent(id: "rows")
        var rowConfig = fixtures[0].1
        rowConfig.ambient = false
        rowOrb.configure(rowConfig)
        let orbitPhase = rowOrb.verificationPhases(at: CACurrentMediaTime())
        rowConfig.satellites[2].done = true; rowConfig.satellites[2].finishedOrder = 1
        rowConfig.satellites[3].finishedOrder = 0
        rowConfig.satelliteMode = .rows; rowOrb.configure(rowConfig)
        let rowGeometry = rowOrb.verificationSatellites
        check(rowGeometry.values.allSatisfy { $0.frontOpacity == 1 && $0.backOpacity == 0 && $0.front == $0.back }, "rows show exactly one front copy")
        check(rowGeometry["d"]!.front.x < rowGeometry["c"]!.front.x && rowGeometry["d"]!.front.y > rowGeometry["a"]!.front.y, "finished rows retain finishedOrder")
        rowConfig.satelliteMode = .follow(["a": CGPoint(x: -25, y: 30)])
        rowOrb.configure(rowConfig)
        check(rowOrb.verificationSatellites["a"]?.front == CGPoint(x: -9, y: 46), "follow targets are centre-relative y-down")
        rowConfig.satelliteMode = .orbit; rowOrb.configure(rowConfig)
        let returnPhase = rowOrb.verificationPhases(at: CACurrentMediaTime())
        for (a, b) in zip(orbitPhase, returnPhase) { check(abs(a.0-b.0) < 1e-6 && abs(b.0-b.1) < 1e-6, "orbit/rows/follow retain shared phase while paused") }
        rowConfig.satellitesRetired = true; rowConfig.reduceMotion = true
        rowOrb.configure(rowConfig)

        let b = OrbComponent(id: "badge")
        var badgeConfig = OrbConfiguration(content: .identity(.assigned(4)), drawingSize: 32, context: 0.8)
        b.configure(badgeConfig)
        let alpha = b.verificationLiquidColors.map { $0.alpha }
        check(alpha == [0.5, 0.78], "context 0.8 uses deep alpha")
        badgeConfig.context = 0.79; b.configure(badgeConfig)
        check(b.verificationLiquidColors.map { $0.alpha } == [0.24, 0.42], "ordinary liquid alpha")
        badgeConfig.badge = OrbBadge(tone: .red, symbol: .error); badgeConfig.redUnseen = true; badgeConfig.redEvents = 1
        b.configure(badgeConfig)
        let hopKey = "organic.orb.alert.badge"
        let hop = b.glassView.layer?.animation(forKey: hopKey) as? CAKeyframeAnimation
        check(hop?.duration == 6.5 && hop?.values?.count == 11, "two finite red hops")
        b.setFrame(CGRect(x: 20, y: 20, width: 48, height: 48))
        let backHop = b.verificationMotionLayers[0].animation(forKey: "alert") as? CAKeyframeAnimation
        check(backHop?.keyPath == "position.y" && backHop?.isAdditive == true &&
              b.verificationMotionLayers[0].transform.m22 == 1.5,
              "red hop is a scene-space additive translation outside hover scale")
        check((backHop?.values as? [Double]) == (hop?.values as? [Double]), "glass and decoration use the same 5 pt hop values")
        let spring = b.verificationBadgeLayer.animation(forKey: "presence.scale") as? CASpringAnimation
        check(abs((spring?.stiffness ?? 0)-pow(2 * .pi/0.3, 2)) < 1e-6, "badge spring response 0.30")
        check(abs((spring?.damping ?? 0)-2*0.7*sqrt(spring?.stiffness ?? 0)) < 1e-6, "badge damping 0.70")
        badgeConfig.ambient = false; b.configure(badgeConfig)
        check(b.glassView.layer?.speed == 1 && b.glassView.layer?.animation(forKey: hopKey)?.speed == 0, "pause only glass hop, not Dock geometry")
        let glassHeld = b.glassView.layer?.animation(forKey: hopKey)?.timeOffset ?? -1
        badgeConfig.ambient = true; b.configure(badgeConfig)
        let restoredHop = b.glassView.layer?.animation(forKey: hopKey)
        check(restoredHop?.speed == 1 && glassHeld >= 0, "glass hop resumes")
        badgeConfig.redUnseen = false; b.configure(badgeConfig)
        let breath = b.verificationMotionLayers[4].animation(forKey: "breathe")
        check(breath == nil, "M11.47 acknowledged red status has no glow pulse")
        let breathBegin = breath?.beginTime
        badgeConfig.ambient = false; b.configure(badgeConfig)
        badgeConfig.ambient = true; b.configure(badgeConfig)
        check(b.verificationMotionLayers[4].animation(forKey: "breathe")?.beginTime == breathBegin, "environment does not restart finite glow")
        let glowNow = CACurrentMediaTime()+0.25
        let glowTime = b.verificationMotionLayers[4].convertTime(glowNow, from: nil)
        b.verificationPause(true, at: glowNow)
        check(abs(b.verificationMotionLayers[4].convertTime(glowNow+8, from: nil)-glowTime) < 1e-6, "glow holds its own phase")
        b.verificationPause(false, at: glowNow+8)
        check(abs(b.verificationMotionLayers[4].convertTime(glowNow+8, from: nil)-glowTime) < 1e-6, "glow resumes continuously")
        badgeConfig.badge = OrbBadge(tone: .green, symbol: .count(1)); badgeConfig.completions = 1
        b.configure(badgeConfig)
        check(abs((b.verificationGlyphLayer.animation(forKey: "completion")?.duration ?? 0)-0.66) < 1e-6, "completion glyph 0.16 + 0.50 s")
        badgeConfig.badge = nil; b.configure(badgeConfig)
        check(b.verificationBadgeLayer.opacity == 0 && b.verificationBadgeLayer.animation(forKey: "presence.scale") != nil, "badge exit retains drawable until spring ends")
        badgeConfig.reduceMotion = true; b.configure(badgeConfig)
        check(b.verificationGlyphLayer.animationKeys()?.isEmpty != false && b.verificationBadgeLayer.animationKeys()?.isEmpty != false, "reduce motion removes finite movement")
        check(b.verificationMotionLayers.prefix(3).allSatisfy { $0.speed == 0 }, "reduce motion freezes ambient clocks")

        for scale:CGFloat in [1,2] {
            let paused=OrbComponent(id:"presence-pause-\(scale)")
            var input=OrbConfiguration(content:.identity(.assigned(0)),drawingSize:40,backingScale:scale)
            paused.configure(input); input.badge = .init(tone:.yellow,symbol:.question); paused.configure(input)
            check(paused.verificationBadgeLayer.animation(forKey:"presence.scale") != nil,"visible badge entrance animates")
            paused.setPresentationActive(false)
            func settled(_ visible:Bool,_ reason:String) {
                let layer=paused.verificationBadgeLayer
                check(!(layer.animationKeys() ?? []).contains { $0.hasPrefix("presence.") },reason+": no finite presence animation")
                check(layer.opacity == (visible ? 1:0) && abs(layer.transform.m11-(visible ? 1:0.4))<1e-6,reason+": final semantic model")
            }
            settled(true,"pause during entrance")
            input.badge=nil; paused.configure(input); settled(false,"exit while retained as bar")
            input.badge = .init(tone:.green,symbol:.count(2)); paused.configure(input); settled(true,"entrance while retained as bar")
            paused.setPresentationActive(true); settled(true,"restore orb after paused updates")
            input.badge=nil; paused.configure(input)
            input.ambient=false; paused.configure(input); settled(false,"window hidden during exit")
            input.badge = .init(tone:.red,symbol:.error); paused.configure(input); settled(true,"hidden window semantic change")
            input.ambient=true; paused.configure(input); settled(true,"visible window resumes without delayed badge")
            paused.dispose()
        }

        for (label, fixture) in fixtures {
            let component = OrbComponent(id: "all-geometry-\(label)")
            component.configure(fixture)
            component.backView.layoutSubtreeIfNeeded(); component.frontView.layoutSubtreeIfNeeded(); component.glassView.layoutSubtreeIfNeeded()
            let first = component.metrics
            for i in 0..<100 { component.setFrame(CGRect(x: i, y: 7, width: 32+i%17, height: 32+i%17)) }
            component.backView.layoutSubtreeIfNeeded(); component.frontView.layoutSubtreeIfNeeded(); component.glassView.layoutSubtreeIfNeeded()
            var last = component.metrics; last.geometryCalls = first.geometryCalls
            check(last == first, "\(label): 100 frames and drained layout do no drawing or layout work")
        }

        let finite=OrbComponent(id:"finite-feedback")
        var feedback=fixtures[0].1;feedback.ambient=true;feedback.activitySerial=1;finite.configure(feedback)
        feedback.activitySerial=2;finite.configure(feedback)
        check(finite.verificationMotionLayers[3].animation(forKey:"eventSettle") != nil,"live activity submits finite feedback")
        feedback.identityLiquid=false;feedback.activitySerial=3;finite.configure(feedback)
        check(finite.verificationLiquidLevel == 0 && finite.verificationMotionLayers[3].animation(forKey:"eventSettle") == nil,"disabled liquid cannot leak a finite wave at the bottom edge")
        feedback.identityLiquid=true;feedback.activitySerial=4;finite.configure(feedback)
        finite.setPresentationActive(false);feedback.activitySerial=5;finite.configure(feedback)
        check(finite.verificationMotionLayers[3].animation(forKey:"eventSettle") == nil,"a hidden new event clears stale paused feedback")
        finite.dispose()

        // Workspace notifications update retained components without a semantic reconfigure.
        let accessible=OrbComponent(id:"display-options")
        var ac=fixtures[0].1; ac.ambient=false; ac.badge = .init(tone:.yellow,symbol:.question)
        accessible.configure(ac)
        let retained=accessible.verificationLayers.map(ObjectIdentifier.init),builds=accessible.metrics.orbitBuilds
        var notifications=0
        let observation=OrbDisplayEnvironment.shared.observe { notifications+=1 }
        for options in [OrbDisplayEnvironment.Options(increaseContrast:true),.init(reduceTransparency:true),.init(increaseContrast:true,reduceTransparency:true)] {
            OrbDisplayEnvironment.shared.setOverride(options)
            check(accessible.verificationLiquidColors.allSatisfy { $0.alpha == 1 },"display options make liquid opaque")
            check(accessible.verificationLiquidColors.first == accessible.verificationLiquidColors.last,"display options remove decorative liquid gradient")
            check(accessible.verificationLayers.map(ObjectIdentifier.init) == retained && accessible.metrics.orbitBuilds == builds,"display options preserve layer identity and orbit clocks")
            check(accessible.verificationBadgeLayer.opacity == 1,"display options preserve semantic badge")
            check(OrbDisplayEnvironment.surface(.white,opacity:0.12).alphaComponent == 1,"display options make decorative surfaces opaque")
            for scale:CGFloat in [1,2] {
                var image=ac; image.backingScale=scale
                try render(label:options.increaseContrast ? (options.reduceTransparency ? "a11y-both":"a11y-contrast"):"a11y-transparency",configuration:image,scale:scale,directory:directory)
            }
        }
        check(notifications == 3,"Workspace display-option notification reaches live observers")
        OrbDisplayEnvironment.shared.setOverride(.init())
        check(accessible.verificationLiquidColors.map { $0.alpha } == [0.24,0.42],"turning display options off restores the context liquid colors")
        OrbDisplayEnvironment.shared.removeObserver(observation); accessible.dispose()

        let screen=OrbComponent(id:"screen-change"); var sc=fixtures[0].1; sc.ambient=false; screen.configure(sc)
        let screenLayers=screen.verificationLayers.map(ObjectIdentifier.init),screenPhases=screen.verificationPhases(at:CACurrentMediaTime()),screenBuilds=screen.metrics.orbitBuilds
        sc.backingScale=2; sc.satelliteAccent = .systemPurple; screen.configure(sc)
        check(screen.verificationLayers.map(ObjectIdentifier.init) == screenLayers && screen.metrics.orbitBuilds == screenBuilds,"backing/accent changes redraw faces without rebuilding or replacing orbit layers")
        check(zip(screenPhases,screen.verificationPhases(at:CACurrentMediaTime()+10)).allSatisfy { abs($0.0-$1.0)<1e-6 && abs($0.1-$1.1)<1e-6 },"backing/accent changes retain paused front/back phase")
        screen.dispose()

        var hover=OrbMeHoverState(); hover.hover(true,now:10); hover.advance(to:10.499,mouseButtonsDown:false)
        check(!hover.visible,"me quota waits 500ms")
        hover.advance(to:10.5,mouseButtonsDown:false); check(hover.visible,"me quota appears at 500ms")
        hover.setDragging(true); check(!hover.visible && hover.deadline == nil,"me drag cancels quota and pending hover")
        hover.hover(true,now:11); check(hover.deadline == nil,"dragging cannot restart hover")
        hover.setDragging(false); hover.hover(true,now:12); hover.advance(to:12.5,mouseButtonsDown:true)
        check(!hover.visible && hover.deadline == nil,"pressed mouse suppresses delayed quota")
        let quota=OrbQuota(primaryUsed:0,secondaryUsed:0.8,primaryResetsAt:Date(timeIntervalSince1970:1800000000),secondaryResetsAt:nil)
        let me=OrbMeController(model:.init(name:"Recorded account",plan:"Recorded plan",quota:quota)),host=NSView(frame:CGRect(x:0,y:0,width:500,height:500))
        me.now={ 20 }; me.hover(true,anchor:CGRect(x:24,y:30,width:36,height:36),in:host,at:20)
        me.advance(to:20.5)
        check(me.isQuotaPresented && me.card.hitTest(.zero) == nil,"quota card is mounted in host overlay and passes pointer input")
        check(me.card.frame.minX == 24 && me.card.frame.minY == 76,"quota card anchors ten points above me")
        check(me.card.accessibilityLabel()?.contains("Reset time not reported") == true && me.card.accessibilityLabel()?.contains("0% used") == true,"quota AX preserves reported zero and missing reset")
        for scale:CGFloat in [1,2] {
            me.card.drawingScale=scale; me.card.layoutSubtreeIfNeeded(); me.card.displayIfNeeded()
            let bitmap=VerificationRaster.bitmap(width: Int(264*scale), height: Int(220*scale))
            bitmap.size=me.card.bounds.size; memset(bitmap.bitmapData!,0,bitmap.bytesPerRow*bitmap.pixelsHigh); me.card.verificationDrawing.cacheDisplay(in:me.card.verificationDrawing.bounds,to:bitmap)
            // Explicit opaque offscreen background proxy. The text itself is the card's own cacheDisplay output.
            let context=CGContext(data:nil,width:bitmap.pixelsWide,height:bitmap.pixelsHigh,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(white:0.16,alpha:1).cgColor); context.fill(CGRect(x:0,y:0,width:context.width,height:context.height))
            context.draw(bitmap.cgImage!,in:CGRect(x:0,y:0,width:context.width,height:context.height))
            try NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("me-quota@\(Int(scale))x.png"))
            check(bitmap.pixelsWide == Int(264*scale),"quota cacheDisplay backing scale")
            let bytes=UnsafeBufferPointer(start:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
            check(bytes.filter { $0>0 }.count>1000,"quota native drawing captures actual glyph pixels")
        }
        let quotaAX=me.card.accessibilityLabel()
        OrbDisplayEnvironment.shared.setOverride(.init(increaseContrast:true))
        check(me.card.layer?.shadowOpacity == 0 && me.card.accessibilityLabel() == quotaAX && me.isQuotaPresented,"Workspace display options remove quota shadow without changing values or dismissing card")
        OrbDisplayEnvironment.shared.setOverride(.init())
        check(me.card.layer?.shadowOpacity == 0.25,"quota restores authored shadow when effects are allowed")
        me.setDragging(true); check(!me.isQuotaPresented && host.subviews.isEmpty,"drag immediately removes quota overlay")
        var actions:[OrbMeController.Action]=[]; me.onAction={ actions.append($0) }
        let menu=me.makeAccountMenu(),usage=menu.items.first { $0.title == "Usage & Billing" }!
        check(usage.subtitle == quota.summary,"account usage menu reports actual quota summary")
        check(menu.items.first { $0.title == "Help" }?.isEnabled == false,"account Help retains product disabled boundary")
        for item in menu.items where item.isEnabled && item.action != nil {
            _=(item.target as? NSObject)?.perform(item.action!)
        }
        check(actions == [.newChat,.showSidebar,.collapse,.profile,.usage,.settings,.fullyFocused,.shortcuts,.signOut],"account menu only forwards native host actions in product order")
        me.dismiss()

        // M10-G host ink is immutable and separate from both ambient clocks and badge plate geometry.
        let dell=DisplayProfile(name:"Dell",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
        for scale:CGFloat in [1,2] {
            for content:OrbContent in [.seed,.identity(.assigned(4)),.me(initials:"LO",quota:.init(primaryUsed:0.3,secondaryUsed:0.4))] {
                let host=OrbComponent(id:"host-exposure")
                var c=OrbConfiguration(content:content,drawingSize:56,badge:.init(tone:.yellow,symbol:.count(12)),ambient:false,backingScale:scale)
                host.configure(c)
                let a=CGRect(x:40,y:40,width:40,height:40),b=a.offsetBy(dx:24,dy:0)
                host.setFrame(a)
                func stillBytes()->Data {
                    let side=Int(180*scale),context=CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.scaleBy(x:scale,y:scale);host.renderOffscreenDecorations(in:context,planet:a)
                    return Data(bytes:context.data!,count:side*side*4)
                }
                let native=stillBytes();host.exposeGlyphs(now:a,earlier:a,profile:dell)
                check(native==stillBytes(),"host still texture ON/native pixels exact at \(scale)x")
                let captures=host.verificationHostGlyph.captures+host.verificationHostBadge.captures
                host.setFrame(b);host.exposeGlyphs(now:b,earlier:a,profile:dell)
                check(host.verificationHostGlyph.sample.count>1,"host glyphs accumulate while ambient is held")
                check(host.verificationHostBadge.sample.count>1,"host badge numbers accumulate independently")
                for ink in [host.verificationHostGlyph,host.verificationHostBadge] {
                    check(ink.bitmap.contents != nil,"host glyph image prewarmed")
                    check(ink.bitmap.sublayers?.isEmpty != false && ink.bitmap.shadowOpacity==0 && ink.bitmap.mask==nil && ink.bitmap.filters?.isEmpty != false && ink.bitmap.backgroundFilters?.isEmpty != false,"replicated leaf is only a flat bitmap")
                    let image=ink.bitmap.contents as! CGImage
                    check(image.bytesPerRow==image.width*4 && CFDataGetLength(image.dataProvider!.data!)==image.bytesPerRow*image.height,"independent tight glyph storage")
                }
                check(host.verificationHostGlyph.captures+host.verificationHostBadge.captures==captures,"host sampling does not bake textures")
                host.exposeGlyphs(now:b,earlier:a,profile:dell,enabled:false)
                check(host.verificationHostGlyph.sample.count==1 && host.verificationHostBadge.sample.count==1,"host disabled returns native in same frame")
                host.exposeGlyphs(now:b,earlier:a,profile:dell);host.resetHostExposure()
                check(host.verificationHostGlyph.sample.count==1 && host.verificationHostBadge.sample.count==1,"host reset removes glyph and number tails")
                c.badge=nil;host.configure(c);host.dispose()
            }
        }

        let prior = p.metrics
        p.dispose(); p.setFrame(.zero); p.configure(configuration)
        check(p.metrics == prior, "dispose prevents later work")
        notes.append("Pause/resume: front/back satellite phase and liquid local time continuous within 1e-6; pace changes while paused preserve phase.")
        notes.append("Images use actual decoration model layers at phase 1.1. The neutral circle is an OFFSCREEN GLASS PROXY; NSGlassEffectView material/fusion is not tested.")
        let result = "Orb selftest: \(checks) checks, \(failures.count) failures\n" + (notes + failures.map { "FAIL: \($0)" }).joined(separator: "\n") + "\n"
        try result.write(to: directory.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        print(result)
        if !failures.isEmpty { exit(1) }
    }

    static func makeFixtures() -> [(String, OrbConfiguration)] {
        let levels = [0.46, 0.22, 0.31, 0.63, 0.88, 0.12]
        var result = (0..<6).map { index in
            (String(UnicodeScalar(65+index)!), OrbConfiguration(content: .identity(.assigned(index)), drawingSize: 32, context: levels[index]))
        }
        result[0].1.running = true
        result[0].1.satellites = [OrbSatellite(id: "a", face: "^-^", pace: 0.55), OrbSatellite(id: "b", face: "^o^", pace: 0.55),
                                  OrbSatellite(id: "c", face: "•ᴗ•", pace: 0.55), OrbSatellite(id: "d", face: "-_-", pace: 0.55, done: true)]
        result[1].1.running = true; result[1].1.badge = OrbBadge(tone: .yellow, symbol: .count(1))
        result[2].1.badge = OrbBadge(tone: .yellow, symbol: .question)
        result[3].1.running = true; result[3].1.badge = OrbBadge(tone: .red, symbol: .error)
        result[4].1.badge = OrbBadge(tone: .red, symbol: .stopped)
        for i in [3, 4] { result[i].1.redEvents = 1; result[i].1.redUnseen = true }
        result.append(("green", OrbConfiguration(content: .identity(.assigned(6)), drawingSize: 32, context: 0.3,
                                                  badge: OrbBadge(tone: .green, symbol: .count(3)))))
        result.append(("me", OrbConfiguration(content: .me(initials: "LO", quota: OrbQuota(primaryUsed: 0.34, secondaryUsed: 0.58)), drawingSize: 36)))
        result.append(("me-unknown", OrbConfiguration(content: .me(initials: "LO", quota: OrbQuota(primaryUsed: nil, secondaryUsed: nil)), drawingSize: 36)))
        var rows = result[0].1; rows.satelliteMode = .rows
        result.append(("A-rows", rows))
        return result
    }

    @MainActor static func render(label: String, configuration: OrbConfiguration, scale: CGFloat, directory: URL) throws {
        let size = CGSize(width: 180, height: configuration.satelliteMode == .orbit ? 116 : 164)
        let root = CALayer(); root.bounds = CGRect(origin: .zero, size: size); root.isGeometryFlipped = true
        root.backgroundColor = NSColor(srgbRed: 0.09, green: 0.105, blue: 0.10, alpha: 1).cgColor
        // Native endpoint beside hover endpoint. The same drawingSize is retained in both cases.
        for (index, diameter) in [configuration.drawingSize, CGFloat(48)].enumerated() {
            let component = OrbComponent(id: "\(label)-\(index)")
            component.configure(configuration)
            let rect = CGRect(x: CGFloat(index)*84+42-diameter/2, y: 54-diameter/2, width: diameter, height: diameter)
            component.setFrame(rect)
            component.verificationSample(phase: 1.1)
            let planes = component.verificationLayers
            root.addSublayer(planes[0]); root.addSublayer(glassProxy(rect))
            // Body is normally glass-local; translate its fixed-size view origin to the scene for this render only.
            let bodyHost = CALayer(); bodyHost.position = rect.origin; bodyHost.anchorPoint = .zero
            bodyHost.addSublayer(planes[1]); root.addSublayer(bodyHost); root.addSublayer(planes[2])
        }
        addLabel(label+" · \(Int(scale))× · native / hover", root: root, rect: CGRect(x: 4, y: size.height-25, width: 172, height: 20), scale: scale)
        try png(root, size: size, scale: scale, url: directory.appendingPathComponent("\(label)@\(Int(scale))x.png"))
    }

    @MainActor static func renderIdentities(scale: CGFloat, directory: URL, appearance: OrbConfiguration.Appearance = .dark) throws {
        let size = CGSize(width: 560, height: 168), root = CALayer()
        root.bounds = CGRect(origin: .zero, size: size); root.isGeometryFlipped = true
        root.backgroundColor = (appearance == .dark ? NSColor(srgbRed: 0.09, green: 0.105, blue: 0.10, alpha: 1):NSColor(white:0.94,alpha:1)).cgColor
        for i in 0..<13 {
            let x = CGFloat(i%7)*80, y = CGFloat(i/7)*84
            let component = OrbComponent(id: "planet-\(i)")
            component.configure(OrbConfiguration(content: .identity(.assigned(i)), drawingSize: 40, context: 0.46, backingScale: scale, appearance:appearance))
            let rect = CGRect(x: x+20, y: y+8, width: 40, height: 40)
            component.setFrame(rect)
            let planes = component.verificationLayers
            root.addSublayer(planes[0]); root.addSublayer(glassProxy(rect))
            let host = CALayer(); host.position = rect.origin; host.anchorPoint = .zero
            host.addSublayer(planes[1]); root.addSublayer(host); root.addSublayer(planes[2])
            addLabel(OrbIdentity.assigned(i).symbol.name, root: root, rect: CGRect(x: x, y: y+54, width: 80, height: 20), scale: scale)
            if appearance == .light { (root.sublayers?.last as? CATextLayer)?.foregroundColor=NSColor.black.withAlphaComponent(0.8).cgColor }
        }
        try png(root, size: size, scale: scale, url: directory.appendingPathComponent("identities\(appearance == .light ? "-light":"")@\(Int(scale))x.png"))
    }

    @MainActor static func glassProxy(_ rect: CGRect) -> CALayer {
        let layer = CAShapeLayer(); layer.frame = rect
        layer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
        layer.fillColor = OrbDisplayEnvironment.surface(NSColor(white:0.22,alpha:1),opacity:0.6).cgColor
        layer.strokeColor = OrbDisplayEnvironment.surface(NSColor(white:0.7,alpha:1),opacity:0.22).cgColor; layer.lineWidth = 0.7
        return layer
    }

    static func addLabel(_ text: String, root: CALayer, rect: CGRect, scale: CGFloat) {
        let label = CATextLayer(); label.frame = rect; label.string = text
        let font = NSFont.systemFont(ofSize: 10)
        label.font = font; label.fontSize = 10; label.contentsScale = scale
        label.foregroundColor = NSColor.white.withAlphaComponent(0.8).cgColor; label.alignmentMode = .center
        root.addSublayer(label)
    }

    @MainActor static func png(_ layer: CALayer, size: CGSize, scale: CGFloat, url: URL) throws {
        let width = Int(size.width*scale), height = Int(size.height*scale)
        let bitmap = VerificationRaster.bitmap(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
#endif
