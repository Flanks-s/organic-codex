#if OVERLAY_SELFTEST
import AppKit
import ObjectiveC

@main @MainActor enum OverlayVerification {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/sol-overlay-m2-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--cost-only") { try OverlayM101Verification.costOnly(output:output); return }
        var checks = 0, findings: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ text: String) { checks += 1; if !value() { findings.append(text) } }
        if ProcessInfo.processInfo.environment["M1116_WHEEL_ONLY"] == "1" {
            try OverlayWheelVerification.run(output: output, check: { check($0, $1) })
            let report = (["Overlay wheel verification: \(checks) checks, \(findings.count) findings"] + findings).joined(separator: "\n") + "\n"
            try report.write(to: output.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
            print(report, terminator: ""); if !findings.isEmpty { exit(1) }; return
        }
        do {
            // M9: a one-colour track (the slider's accent fill) draws; a one-stop gradient drew nothing.
            let bitmap = VerificationRaster.bitmap(width: 8, height: 4)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            OverlayStyle.linear([NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)], in: CGRect(x: 0, y: 0, width: 8, height: 4))
            NSGraphicsContext.restoreGraphicsState()
            let pixel = bitmap.colorAt(x: 4, y: 2)
            check((pixel?.blueComponent ?? 0) > 0.9 && (pixel?.alphaComponent ?? 0) > 0.9, "a one-colour track fill draws (the slider's accent)")
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }
        func pixels(_ image: CGImage) -> [UInt8] {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let host = OverlayView(frame: CGRect(x: 0, y: 0, width: 760, height: 820)), clock = OverlayManualClock()
        let anchor = CGRect(x: 430, y: 756, width: 158, height: 28)
        var settings = ModelSettings(); settings.effort = .ultra; settings.speed = .ultrafast
        let picker = OverlayModelPicker(clock: clock)
        var changed: [ModelSettings] = [], modelChanges: [String] = [], efforts: [Effort] = [], tiers: [Speed] = []
        picker.onSettingsChange = { changed.append($0) }; picker.onModelSelected = { modelChanges.append($0.id) }
        picker.onEffortSelected = { efforts.append($0) }; picker.onTierSelected = { tiers.append($0) }
        picker.configure(settings: settings, models: ModelCatalog.mockModels); picker.present(anchor: anchor, in: host)
        check(picker.isShowing && !picker.isDismissing && picker.superview === host, "Picker mounts as a modal host child")
        let plates = descendants(picker).compactMap { $0 as? OverlayPlateButton }
        check(plates.count == 2 && plates.allSatisfy { !($0 as NSView is NSButton) && !$0.isOpaque && $0.cell == nil }, "Caption capsules have no NSButtonCell, material or opaque first-frame backing")
        let dawn = plates.first { $0.title == "Daybreak" }!
        check(dawn.layer?.backgroundColor?.alpha == 0 && dawn.image != nil && dawn.contentTintColor != nil, "Daybreak has explicit transparent backing and complete foreground before entrance")
        let plateAction = OverlayPlateButton(frame: CGRect(x: 0, y: 0, width: 112, height: 30)); var platePresses = 0
        plateAction.invoke = { platePresses += 1 }
        check(plateAction.isEnabled && plateAction.accessibilityPerformPress() && platePresses == 1, "Cell-free capsule preserves native AX press")
        plateAction.isEnabled = false
        check(!plateAction.accessibilityPerformPress() && platePresses == 1, "Disabled capsule cannot activate through AX")
        check(!picker.acceptsFirstResponder && !picker.becomeFirstResponder(), "Picker never takes composer focus")
        check(OverlayKey.from(code: 36, modifiers: .command) == nil && OverlayKey.from(code: 123, modifiers: .control) == nil && OverlayKey.from(code: 124, modifiers: .option) == nil, "Modified shortcuts stay on the native composer/window path")
        check(OverlayKey.from(code: 126, modifiers: [.shift, .capsLock]) == .up, "Shift and Caps Lock do not suppress picker navigation")
        check(picker.capsuleRect.width == 348 && picker.capsuleRect.height == 48 && picker.reasoning.levels == ModelCatalog.mockModels[5].efforts, "Picker uses the product capsule and current model efforts")
        check(picker.placements.last(where: { $0.current })?.id == "g61sol", "Current lyric occupies the focus line")
        check(descendants(picker).compactMap { $0 as? OverlayLyricRow }.allSatisfy { $0.name.font?.pointSize == 28 && ($0.renderScale == 1 || abs($0.renderScale - 19 / CGFloat(28)) < 1e-9) }, "All lyrics reuse 28 pt native rendering at the product's two scales")
        // M9: HStack(spacing: 6) glyph to glyph (the labels pad 2 pt each side); DaybreakButton sized to its content with the
        // dawn icon; the speed lens is plain regular glass.
        check(descendants(picker).compactMap { $0 as? OverlayLyricRow }.filter { !$0.version.stringValue.isEmpty }.allSatisfy { abs($0.name.frame.minX - ($0.version.frame.width + 2)) < 0.01 && abs($0.word.frame.minX - ($0.name.frame.maxX + 2)) < 0.01 }, "M9 lyric parts are 6 pt apart glyph to glyph")
        let daybreakPlates = descendants(picker).compactMap { $0 as? OverlayPlateButton }.filter { $0.title == "Daybreak" }
        check(daybreakPlates.count == 1 && daybreakPlates[0].leadingInset == 10 && abs(daybreakPlates[0].frame.width - daybreakPlates[0].naturalWidth) < 1 && daybreakPlates[0].imageTintColor != nil, "M9 Daybreak is sized to its content with the dawn icon")
        check(descendants(picker.speedSelector).compactMap { $0 as? OverlayLens }.allSatisfy(\.plain), "M9 speed lens is the product's plain glass")
        check(picker.handleKey(.left) && picker.settings.effort == .xhigh && efforts.last == .xhigh, "Left selects the preceding supported effort")
        check(picker.handleKey(.right) && picker.settings.effort == .ultra, "Right returns to Ultra")
        check(picker.handleKey(.up) && picker.settings.modelID == "g6sol" && modelChanges.last == "g6sol", "Up selects a model and emits its stable ID")
        check(picker.settings.memory["g61sol"] == .ultra && picker.handleKey(.down) && picker.settings.effort == .ultra, "Switching back restores remembered effort")
        check(!picker.selectEffort(.minimal), "Unsupported reasoning efforts cannot commit")
        check(picker.wheel(deltaY: -1, precise: false) && picker.scrolling && picker.settings.modelID == "g6astra", "Wheel enters the faster teleprompter and steps one model")
        clock.advance(by: 1.099); check(picker.scrolling, "Wheel mode stays active before the 1.1 second idle boundary")
        clock.advance(by: 0.001); check(!picker.scrolling, "Wheel mode settles at the injected idle deadline")
        _ = picker.selectModel("g61sol"); _ = picker.selectEffort(.ultra)
        let word = descendants(picker).compactMap { $0 as? OverlayRollingWord }.first { $0.text == "Ultra" }!
        _ = picker.selectEffort(.high)
        check(word.direction == -1 && word.letters.first?.layer?.animation(forKey: "overlay.word.transform.translation.y") != nil, "Lowering effort reverses the actual letter animation")
        _ = picker.selectEffort(.ultra)
        check(word.direction == 1 && word.letters.allSatisfy { $0.gradient == OverlayStyle.ultra && $0.wordSpan?.width == word.frame.width }, "Ultra letters share one whole-word gradient span")
        let letterAnimation = word.letters.first?.layer?.animation(forKey: "overlay.word.transform.translation.y") as? CAKeyframeAnimation
        check(letterAnimation?.duration == 0.46 && letterAnimation?.keyTimes == [0, 0.55, 1], "Incoming letters use the product .253/.207 two-leg motion")

        let sparse: [ModelCatalog.Model] = [
            .init(id: "core-std", name: "Standard Model", version: "6", efforts: [.low, .high], reportedByCore: true),
            .init(id: "core-fast", name: "Fast Model", version: "6", efforts: [.medium, .high, .ultra], serviceTiers: ["priority"], cyberPrograms: ["daybreakBlue"], reportedByCore: true),
            .init(id: "core-ultra", name: "Ultra Model", version: "6", efforts: [.high, .ultra], serviceTiers: ["priority", "ultrafast"], reportedByCore: true)
        ]
        let capabilities = OverlayModelPicker(clock: clock)
        var coreSettings = settings; coreSettings.modelID = "core-std"
        capabilities.configure(settings: coreSettings, models: sparse); capabilities.present(anchor: anchor, in: host)
        check(capabilities.settings.speed == .standard && capabilities.note?.contains("Using Standard") == true, "Invalid pending tier normalizes to Standard with a reason")
        check(capabilities.speedSelector.buttons.map(\.isEnabled) == [true, false, false], "Core service tiers gate all three speed buttons")
        check(capabilities.speedSelector.buttons[1].accessibilityHelp()?.contains("not available") == true && !capabilities.selectTier(.fast), "Unsupported tier is disabled and explains why")
        _ = capabilities.selectModel("core-fast")
        check(capabilities.speedSelector.buttons.map(\.isEnabled) == [true, true, false] && capabilities.selectTier(.fast), "Core priority enables Fast only")
        _ = capabilities.selectModel("core-ultra")
        check(capabilities.selectTier(.ultrafast) && capabilities.speedSelector.buttons.allSatisfy(\.isEnabled), "Core ultrafast enables the third tier")
        capabilities.toggleDaybreak()
        check(capabilities.settings.daybreak && capabilities.settings.modelID == "core-fast" && capabilities.settings.speed == .standard, "Daybreak chooses a compatible model and normalizes its unsupported tier")
        check(!capabilities.selectModel("core-std"), "Daybreak cannot select an unsupported Core model")
        let slider = capabilities.reasoning
        slider.pointerDown(x: slider.stops.first!); check(slider.value == .medium, "Slider snaps directly to the first supported tick")
        clock.advance(by: 0.01); slider.pointerDragged(x: slider.bounds.maxX)
        check(slider.value == .ultra && slider.lensStretch <= 0.32 && slider.isDragging, "Held lens stretches with velocity and snaps to Ultra")
        slider.pointerUp(); check(!slider.isDragging && slider.lensStretch == 0, "Released reasoning lens lands on its tick")
        check(slider.accessibilityPerformDecrement() && slider.value == .high, "AX reasoning adjustment follows the supported tick list")
        let beforeTier = capabilities.settings.speed
        capabilities.speedSelector.pointerDown(x: capabilities.speedSelector.stops[2])
        capabilities.speedSelector.pointerUp()
        check(capabilities.settings.speed == beforeTier, "Dragging over an unsupported speed cannot select it")
        var obsolete = settings; obsolete.modelID = "removed-core-model"
        capabilities.configure(settings: obsolete, models: sparse)
        check(!capabilities.selectModel("removed-core-model") && capabilities.note?.contains("no longer reported") == true, "A removed Core model remains informational and cannot be reselected")

        let send = OverlaySendOptions(clock: clock), sendAnchor = CGRect(x: 700, y: 756, width: 28, height: 28)
        var selected: [FollowUp] = [], shortPresses = 0
        send.onSelect = { selected.append($0) }; send.onShortPress = { shortPresses += 1 }
        check(send.beginPress(anchor: sendAnchor, in: host, pointer: CGPoint(x: 714, y: 770)), "Send accepts a valid pointer press")
        clock.advance(by: 0.349); check(!send.isShowing && send.pressState == .holding, "349 ms does not open Send options")
        send.endPress(at: CGPoint(x: 714, y: 770)); clock.advance(by: 0.1)
        check(shortPresses == 1 && selected.isEmpty && !send.isShowing, "Short release sends once and cancels the hold deadline")
        _ = send.beginPress(anchor: sendAnchor, in: host, pointer: CGPoint(x: 714, y: 770)); clock.advance(by: 0.35)
        check(send.isShowing && send.pressState == .opened && shortPresses == 1, "350 ms opens options without sending")
        let queueRect = send.rowRect(.queue)!, queuePoint = CGPoint(x: queueRect.midX, y: queueRect.midY)
        send.continuePress(at: queuePoint); send.endPress(at: queuePoint); send.endPress(at: queuePoint)
        check(selected == [.queue] && shortPresses == 1 && send.isDismissing, "Holding, sliding and releasing commits Queue exactly once")
        clock.advance(by: 0.23); check(!send.isShowing && send.superview == nil, "Dismiss removes Send after its render-server tail")
        _ = send.beginPress(anchor: sendAnchor, in: host, pointer: CGPoint(x: 714, y: 770)); clock.advance(by: 0.35)
        _ = send.handleKey(.escape); send.endPress(at: CGPoint(x: 714, y: 770)); clock.advance(by: 0.23)
        check(selected == [.queue] && shortPresses == 1 && !send.isShowing, "Esc during a hold closes without a late release send")
        _ = send.beginPress(anchor: sendAnchor, in: host, pointer: CGPoint(x: 714, y: 770)); clock.advance(by: 0.35)
        check(send.outsideClick(at: CGPoint(x: 8, y: 8)), "Outside click is consumed")
        send.endPress(at: CGPoint(x: 8, y: 8)); clock.advance(by: 0.23)
        check(selected == [.queue] && shortPresses == 1, "Outside close never sends on mouse-up")
        send.present(anchor: sendAnchor, in: host); _ = send.handleKey(.up); _ = send.handleKey(.enter)
        check(selected == [.queue, .queue], "Send keyboard toggle and Return commit the selected option")
        clock.advance(by: 0.23)
        send.canSend = { false }
        check(!send.beginPress(anchor: sendAnchor, in: host, pointer: .zero), "Disabled/offline Send cannot start a hold")
        send.canSend = { true }; _ = send.beginPress(anchor: sendAnchor, in: host, pointer: CGPoint(x: 714, y: 770))
        send.canSend = { false }; clock.advance(by: 0.35); send.endPress(at: CGPoint(x: 714, y: 770))
        check(!send.isShowing && shortPresses == 1, "Capability loss during a hold cancels without sending")

        // The shield is a real topmost hit, including while closing; no synthetic event is redispatched.
        capabilities.dismiss(); picker.dismiss(); clock.advance(by: 0.23)
        picker.present(anchor: anchor, in: host)
        let hit = host.hitTest(CGPoint(x: 8, y: 8))
        check(hit === picker && picker.outsideClick(at: CGPoint(x: 8, y: 8)), "Modal outside hit lands on the overlay, not underlying content")
        picker.needsLayout = true; picker.layoutSubtreeIfNeeded()
        check(([picker] + descendants(picker)).compactMap(\.layer).flatMap(layers).allSatisfy { $0.animation(forKey: "aurora") == nil && $0.animation(forKey: "twinkle") == nil }, "A closing layout cannot restart paused Ultra ambient animations")
        check(host.hitTest(CGPoint(x: 8, y: 8)) === picker, "Closing shield continues to block the underlying scene")
        picker.present(anchor: anchor, in: host); clock.advance(by: 0.23)
        check(picker.isShowing && picker.superview === host && !picker.isDismissing, "Reopen invalidates stale removal work")
        _ = picker.handleKey(.enter); clock.advance(by: 0.23)
        check(!picker.isShowing && picker.superview == nil, "Picker Return dismisses without a new selection")

        let curves: [(OverlayCurve, OverlayCurve, String)] = [
            (OverlayMotion.glide, .init(0.22, 1.2, 0.36, 1, 0.55), "glide"), (OverlayMotion.grow, .init(0.3, 1.2, 0.5, 1, 0.4), "grow"),
            (OverlayMotion.rise, .init(0.2, 1, 0.35, 1, 0.42), "rise"), (OverlayMotion.morphIn, .init(0.2, 1.28, 0.36, 1, 0.46), "morph in"),
            (OverlayMotion.morphOut, .init(0.5, 0, 0.8, 0.4, 0.22), "morph out"), (OverlayMotion.blurIn, .init(0.2, 1, 0.3, 1, 0.38), "blur in"),
            (OverlayMotion.blurOut, .init(0.42, 0, 1, 1, 0.23), "blur out"), (OverlayMotion.closeFade, .init(0.42, 0, 1, 1, 0.16), "close fade"),
            (OverlayMotion.closeSink, .init(0.42, 0, 1, 1, 0.2), "close sink"), (OverlayMotion.closeExtras, .init(0, 0, 0.58, 1, 0.05), "close extras")]
        for (actual, expected, name) in curves { check(actual == expected, "Product curve: " + name) }
        check(OverlayMotion.stagger == 0.028 && OverlayMotion.hold == 0.35, "Product rise staggering and Send deadline")
        check(abs(OverlayMotion.sendSpring().stiffness - pow(2 * .pi / 0.36, 2)) < 1e-9 && abs(OverlayMotion.pressSpring().damping - 2 * 0.55 * 2 * .pi / 0.22) < 1e-9, "Send spring response/damping match both product contracts")

        picker.configure(settings: settings, models: ModelCatalog.mockModels); picker.present(anchor: anchor, in: host)
        // The capsule grows by its frame, frame by frame, never by a scale transform (user, 2026-10-29: "失真变形").
        let glass = picker.subviews.compactMap { $0 as? NSGlassEffectView }.first!
        let near = { (a: CGRect, b: CGRect) in abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1 }
        check(near(glass.frame, picker.anchorRect) && picker.morphProgress == 0, "Capsule morph starts at the actual button rect")
        check(["transform.scale.x", "transform.scale.y", "transform.translation.x", "transform.translation.y"].allSatisfy { glass.layer?.animation(forKey: "overlay." + $0) == nil }
              && glass.layer.map { CATransform3DIsIdentity($0.transform) } != false, "Capsule glass is never scaled or shifted by a transform")
        var mid: [CGRect] = []
        for _ in 0..<13 { clock.advance(by: 1.0 / 60); mid.append(glass.frame) }
        check(mid.contains { $0.width > picker.anchorRect.width + 20 && $0.width < picker.capsuleRect.width - 20 }, "Capsule glass passes through intermediate sizes")
        check(picker.reasoning.frame.size == CGSize(width: 332, height: 34), "The slider keeps its own size while the glass grows")
        func sampled(_ c: OverlayCurve, _ x: Double) -> Double {
            // The cubic Bézier by dense parameter sampling: the point whose x is nearest gives the reference y.
            func b(_ t: Double, _ p1: Float, _ p2: Float) -> Double { let u = 1 - t; return 3 * u * u * t * Double(p1) + 3 * u * t * t * Double(p2) + t * t * t }
            let t = (0...4000).map { Double($0) / 4000 }.min { abs(b($0, c.x1, c.x2) - x) < abs(b($1, c.x1, c.x2) - x) }!
            return b(t, c.y1, c.y2)
        }
        check([0.1, 0.3, 0.5, 0.8].allSatisfy { abs(OverlayMotion.morphIn.value(at: $0) - sampled(OverlayMotion.morphIn, $0)) < 2e-3 && abs(OverlayMotion.morphOut.value(at: $0) - sampled(OverlayMotion.morphOut, $0)) < 2e-3 }
              && OverlayMotion.morphIn.value(at: 0) == 0 && abs(OverlayMotion.morphIn.value(at: 1) - 1) < 1e-9, "Frame-driven morph follows the product morph curves")
        clock.advance(by: 0.3)
        check(glass.frame == picker.capsuleRect && picker.morphProgress == 1 && picker.reasoning.alphaValue == 1, "Capsule settles exactly at its place, slider fully shown")
        let rising = descendants(picker).compactMap { $0 as? OverlayLyricRow }.compactMap { $0.motionLayer.animation(forKey: "overlay.transform.translation.y") }
        check(OverlayZoom.selected == .gauss && OverlayExposure.enabled ? rising.isEmpty : (rising.count == 7 && rising.allSatisfy { $0.duration == 0.42 }), "M10.1 Gaussian entrance has no legacy rise; accum preserves the original rise")
        let pickerLayers = ([picker] + descendants(picker)).compactMap(\.layer).flatMap(layers)
        check(pickerLayers.allSatisfy { $0.animation(forKey: "aurora") == nil }, "M11.47 Ultra gradient has no idle aurora animation")
        check(pickerLayers.allSatisfy { $0.animation(forKey: "twinkle") == nil }, "M11.47 Ultra art has no idle twinkle animation")

        for (name, surface) in [("model-picker", picker as OverlaySurface), ("send-options", send as OverlaySurface)] {
            if surface === send { send.canSend = { true }; send.present(anchor: sendAnchor, in: host) }
            for scale: CGFloat in [1, 2] {
                let image = surface.snapshot(scale: scale)
                check(image.width == Int(host.bounds.width * scale) && image.height == Int(host.bounds.height * scale), "\(name) snapshot dimensions at \(Int(scale))x")
                let rep = VerificationRaster.bitmap(width: image.width, height: image.height)
                rep.size = surface.bounds.size; memset(rep.bitmapData!, 0, rep.bytesPerRow * rep.pixelsHigh); surface.cacheDisplay(in: surface.bounds, to: rep)
                check(pixels(image) == pixels(rep.cgImage!), "\(name) static snapshot equals its own native cache at \(Int(scale))x")
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(Int(scale))x.png"))
                let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                canvas.setFillColor(CGColor(gray: 0.12, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height)); canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-canvas-\(Int(scale))x.png"))
            }
            let controls = descendants(surface).filter { $0 is NSTextField || $0 is NSButton }
            check(controls.allSatisfy { view in
                let base: AnyClass = view is NSButton ? NSButton.self : NSTextField.self
                guard let cls = object_getClass(view), let a = class_getInstanceMethod(cls, #selector(NSView.draw(_:))), let b = class_getInstanceMethod(base, #selector(NSView.draw(_:))) else { return false }
                return method_getImplementation(a) != method_getImplementation(b)
            }, "\(name) text controls override draw")
            check(controls.allSatisfy { ($0 as? NSButton)?.isBordered != true && ($0 as? NSTextField)?.isBezeled != true }, "\(name) has no system bezels")
            check(!controls.isEmpty && controls.allSatisfy { !$0.acceptsFirstResponder }, "\(name) controls do not take focus")
            check(controls.allSatisfy { view in [view.frame.minX, view.frame.minY, view.frame.width, view.frame.height].allSatisfy { $0.rounded() == $0 } }, "\(name) text-control frames are on the backing grid")
        }
        let unflipped = NSView(frame: host.frame), flippedSend = OverlaySendOptions(clock: clock)
        var flippedChoices: [FollowUp] = []; flippedSend.onSelect = { flippedChoices.append($0) }
        let lowerAnchor = CGRect(x: 700, y: 36, width: 28, height: 28)
        _ = flippedSend.beginPress(anchor: lowerAnchor, in: unflipped, pointer: CGPoint(x: 714, y: 50)); clock.advance(by: 0.35)
        check(flippedSend.anchorRect.minY == 756, "An unflipped host anchor converts exactly once to overlay top-left coordinates")
        let r = flippedSend.rowRect(.queue)!, hostPoint = unflipped.convert(CGPoint(x: r.midX, y: r.midY), from: flippedSend)
        flippedSend.continuePress(at: hostPoint); flippedSend.endPress(at: hostPoint)
        check(flippedChoices == [.queue], "Held release uses host coordinates correctly across a flipped overlay")
        picker.reduceMotion = true; picker.present(anchor: anchor, in: host)
        check(([picker] + descendants(picker)).compactMap(\.layer).flatMap(layers).allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "Reduce Motion omits movement and ambient animations")
        let composer = NativeComposer(); composer.frame = CGRect(x: 0, y: 756, width: 760, height: 48); composer.targetWidth = 760; host.addSubview(composer); composer.layoutSubtreeIfNeeded()
        let binding = OverlayComposerBinding(composer: composer, host: host, clock: clock)
        _ = composer.setText("offscreen draft"); var submissions = 0; composer.onSend = { _ in submissions += 1 }
        composer.layoutSubtreeIfNeeded(); composer.measureNow()
        let sendRect = host.convert(composer.sendButton.bounds, from: composer.sendButton), sendPoint = CGPoint(x: sendRect.midX, y: sendRect.midY)
        check(binding.pointerDown(at: sendPoint), "Opt-in composer adapter handles Send mouse-down")
        clock.advance(by: 0.2); _ = binding.pointerUp(at: sendPoint)
        check(submissions == 1, "Composer adapter preserves normal short-click Send")
        check(binding.presentModelPicker() && binding.modelPicker.isShowing, "Composer model button anchor can present the lyric picker")
        binding.modelPicker.dismiss(); clock.advance(by: 0.23)
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: clock.now,
                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)!
        }
        func modelKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> Bool {
            binding.keyDown(with: key(code, modifiers: modifiers, repeatKey: repeatKey), firstResponder: composer.modelButton)
        }
        for code: UInt16 in [36, 76, 49, 125] {
            check(modelKey(code) && binding.modelPicker.isShowing, "C12 Model key \(code) opens the lyric picker")
            check(binding.modelPicker.settings.modelID == composer.settings.modelID, "C12 opening key \(code) does not also navigate the picker")
            check(!binding.modelPicker.acceptsFirstResponder && !binding.modelPicker.becomeFirstResponder(), "C12 opening key \(code) does not transfer focus")
            check(modelKey(53) && binding.modelPicker.isDismissing, "C12 Esc closes a keyboard-opened picker")
            check(modelKey(49) && binding.modelPicker.isDismissing, "C12 Space during fade-out cannot open the native menu")
            clock.advance(by: 0.23)
        }
        check(!binding.keyDown(with: key(36), firstResponder: composer.textView), "C12 editor Return stays on the editor submission path")
        check(!binding.keyDown(with: key(49), firstResponder: composer.accessButton), "C12 Access button keeps its own menu")
        let otherComposer = NativeComposer()
        otherComposer.frame=CGRect(x:0,y:0,width:760,height:48);otherComposer.targetWidth=760
        check(!binding.keyDown(with: key(125), firstResponder: otherComposer.modelButton), "C12 another composer's Model button is not captured")
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            check(!modelKey(36, modifiers: modifier) && !binding.modelPicker.isShowing, "C12 modifier \(modifier.rawValue) is not mistaken for Model activation")
        }
        check(modelKey(49, modifiers: .capsLock) && binding.modelPicker.isShowing, "C12 Caps Lock does not disable keyboard opening")
        let usableModels = ModelCatalog.models.filter(binding.modelPicker.available)
        let oldIndex = usableModels.firstIndex { $0.id == binding.modelPicker.settings.modelID }!
        check(modelKey(125), "C12 Down is consumed by an open picker")
        check(binding.modelPicker.settings.modelID == usableModels[min(oldIndex + 1, usableModels.count - 1)].id,
              "C12 Down navigates exactly once and writes selection back to composer")
        check(binding.modelPicker.settings.modelID == composer.settings.modelID && submissions == 1, "C12 keyboard model selection updates settings without sending")
        check(modelKey(49) && !binding.modelPicker.isDismissing, "C12 Space in the open picker cannot fall through to NSMenu")
        check(modelKey(36) && binding.modelPicker.isDismissing, "C12 Return accepts and closes the open picker")
        clock.advance(by: 0.23)
        check(modelKey(36, repeatKey: true) && !binding.modelPicker.isShowing, "C12 held Return after close is consumed without reopening or native fallback")
        composer.modelButton.isEnabled = false
        check(!modelKey(36) && !binding.presentModelPicker(), "C12 disabled Model button cannot open an overlay")
        composer.modelButton.isEnabled = true; composer.presentationActive = false
        check(!modelKey(36), "C12 retired presentation cannot open an overlay")
        composer.presentationActive = true; composer.presentationClip = .zero
        check(!modelKey(36), "C12 clipped-out Model button cannot open an overlay")
        composer.presentationClip = nil; composer.verificationWindowVisible = false
        check(!modelKey(36), "C12 invisible window cannot open an overlay")
        composer.verificationWindowVisible = nil
        check(binding.pointerDown(at: sendPoint), "Adapter can begin a second Send hold after closing a picker")
        check(!modelKey(36), "C12 Model activation cannot interrupt a captured Send press")
        composer.isHidden = true; clock.advance(by: 0.35); _ = binding.pointerUp(at: sendPoint)
        check(submissions == 1 && !binding.sendOptions.isShowing && !binding.presentModelPicker(), "Hiding a composer cancels a pending hold and blocks hidden controls")
        check(!modelKey(36), "C12 hidden Model button cannot open an overlay")
        binding.disconnect()
        composer.isHidden = false
        check(!binding.isConnected && !modelKey(36) && !binding.presentModelPicker(), "C12 disconnected binding cannot be reused by stale keyboard callbacks")
        check(host.window == nil && NSApp.windows.allSatisfy { !$0.isVisible }, "Overlay verification creates no window or app run loop")
        // Retire the earlier keyboard fixtures before a later bitmap capture drains AppKit layout.
        composer.isHidden=true;composer.presentationActive=false;composer.removeFromSuperview();otherComposer.isHidden=true
        try OverlayGroup1Verification.run(output:output,check:{ check($0,$1) })
        try OverlayWheelVerification.run(output:output,check:{ check($0,$1) })
        if ProcessInfo.processInfo.environment["M10_FRAMES"] == "1" { try OverlayM10Verification.run(output: output, check: { check($0, $1) }) }
        let report = (["Overlay verification: \(checks) checks, \(findings.count) findings"] + findings).joined(separator: "\n") + "\n"
        try report.write(to: output.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
        print(report, terminator: ""); if !findings.isEmpty { exit(1) }
    }
}
#endif
