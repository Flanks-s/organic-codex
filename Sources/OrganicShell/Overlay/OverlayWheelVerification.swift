#if OVERLAY_SELFTEST
import AppKit

/// M11.16: drive the production wheel with notched (non-precise, phase-free) input, then inspect
/// the submitted CA tracks and rasterize their actual native glyphs through the existing CARenderer mirror.
@MainActor enum OverlayWheelVerification {
    private struct Pose {
        var y: CGFloat, font: CGFloat, depth: CGFloat, opacity: CGFloat, blur: CGFloat
    }
    private struct InkBounds { var rect: CGRect; var peak: Double }
    private static func inkBounds(_ pixels: [UInt8], width: Int, height: Int) -> InkBounds? {
        var x0 = width, y0 = height, x1 = 0, y1 = 0, peak = 30
        for y in 0..<height { for x in 0..<width {
            let k = (y * width + x) * 4, light = max(Int(pixels[k]), Int(pixels[k + 1]), Int(pixels[k + 2]))
            peak = max(peak, light)
            if light > 38 { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1) }
        } }
        guard x1 > x0, y1 > y0 else { return nil }
        return .init(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), peak: Double(peak))
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private static func rows(_ picker: OverlayModelPicker) -> [String: OverlayLyricRow] {
        Dictionary(uniqueKeysWithValues: views(picker).compactMap { view in
            guard let row = view as? OverlayLyricRow,
                  let model = picker.models.first(where: { $0.name == row.name.stringValue && ($0.version.isEmpty ? "" : "GPT-" + $0.version) == row.version.stringValue }) else { return nil }
            return (model.id, row)
        })
    }
    private static func scalar(_ layer: CALayer, _ key: String, time: Double) -> CGFloat {
        OverlayExposure.path(of: layer, origin: time).scalars[key]?.value(at: 0)
            ?? (layer.value(forKeyPath: key) as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    }
    private static func pose(_ row: OverlayLyricRow, time: Double) -> Pose {
        let l = row.motionLayer
        let font = row.ink.subviews.first { $0.layer?.name == "overlay.lyric-font" }?.layer
        let depth = scalar(l, "transform.scale", time: time)
        // Report the lyric's base Y, removing the reference's leading-midpoint depth displacement.
        let top = l.position.y - l.anchorPoint.y * l.bounds.height * depth
        return Pose(y: row.frame.minY + top + scalar(l, "transform.translation.y", time: time) - 20 * (1 - depth),
                    font: 28 * row.renderScale * (font.map { scalar($0, "transform.scale", time: time) } ?? 1),
                    depth: depth, opacity: scalar(l, "opacity", time: time),
                    blur: l.filters?.isEmpty == false ? scalar(l, "filters.overlayBlur.inputRadius", time: time) : 0)
    }
    private static func target(_ models: [ModelCatalog.Model], selected: String, scrolling: Bool) -> [String: Pose] {
        let current = models.firstIndex { $0.id == selected }!, others = models.filter { $0.id != selected }
        var y: CGFloat = 0, normal: [String: CGFloat] = [:]
        for (i, model) in others.enumerated() {
            if i > 0 && others[i - 1].major != model.major { y += 13 }
            normal[model.id] = y; y += 32
        }
        let focus = y + 10
        return Dictionary(uniqueKeysWithValues: models.enumerated().map { i, model in
            if i == current { return (model.id, Pose(y: focus, font: 28, depth: 1, opacity: 1, blur: 0)) }
            if !scrolling { return (model.id, Pose(y: normal[model.id]!, font: 19, depth: 1, opacity: 0.34, blur: 0)) }
            if i > current { return (model.id, Pose(y: focus + 48 + CGFloat(i - current - 1) * 32, font: 19, depth: 1, opacity: 0, blur: 3)) }
            let distance = current - i, gaps = (i + 1...current).filter { models[$0 - 1].major != models[$0].major }.count
            let at = focus - 10 - CGFloat(distance) * 32 - CGFloat(gaps) * 13
            return (model.id, Pose(y: at, font: 19, depth: 1 - 0.015 * CGFloat(distance),
                                   opacity: at < -19.2 ? 0 : 0.34 * max(0, 1 - 0.17 * CGFloat(distance - 1)), blur: min(4, 0.8 * CGFloat(distance - 1))))
        })
    }
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        let directory = output.appendingPathComponent("wheel")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = OverlayExposure.enabled, mode = OverlayZoom.verificationOverride
        defer { OverlayExposure.enabled = saved; OverlayZoom.verificationOverride = mode }
        var trace = "variant,event,model,time,y,font,depth,opacity,blur,expectedY,expectedFont,expectedDepth,expectedOpacity,expectedBlur\n"
        var rasterTrace = "time,inkY,inkWidth,inferredFont,inferredOpacity,expectedY,expectedWidth,expectedFont,expectedOpacity\n"
        var metrics: [[String: Any]] = []
        let glideFast = OverlayCurve(0.2, 1.15, 0.35, 1, 0.38), growFast = OverlayCurve(0.3, 1.2, 0.5, 1, 0.30)
        let glide = OverlayCurve(0.22, 1.2, 0.36, 1, 0.55), grow = OverlayCurve(0.3, 1.2, 0.5, 1, 0.4)
        func interpolate(_ a: CGFloat, _ b: CGFloat, _ curve: OverlayCurve, _ time: Double) -> CGFloat {
            a + (b - a) * curve.value(at: min(1, time / curve.duration))
        }
        for variant in ["off", "accum", "gauss", "reduced"] {
            OverlayExposure.enabled = variant != "off"; OverlayZoom.verificationOverride = variant == "gauss" ? .gauss : .accum
            let clock = OverlayManualClock(), mount = CALayer(), size = CGSize(width: 760, height: 820)
            let renderer = OverlayM101Renderer(size: size, root: mount, scale: 1)
            let host = OverlayView(frame: CGRect(origin: .zero, size: size)), picker = OverlayModelPicker(clock: clock)
            host.wantsLayer = true; picker.reduceMotion = variant == "reduced"
            picker.sceneTime = { renderer.origin + clock.now }; picker.exposureProfile = OverlayExposure.dell
            var settings = ModelSettings(); settings.modelID = "g6luna"; settings.memory["g6sol"] = .low; settings.memory["g61sol"] = .medium
            var commits: [String] = []; picker.onSettingsChange = { commits.append($0.modelID) }
            picker.configure(settings: settings, models: ModelCatalog.mockModels)
            picker.present(anchor: CGRect(x: 430, y: 756, width: 158, height: 28), in: host)
            clock.advance(by: 1); host.layoutSubtreeIfNeeded(); picker.reasoning.stopAmbient()
            let map = rows(picker)
            func retainTracks(_ layer: CALayer) {
                // CARenderer advances CA's process-wide offscreen clock into the future. Keep the submitted
                // source tracks available for later retargets; their times, values and fill modes are unchanged.
                for key in layer.animationKeys() ?? [] { if let stored = layer.animation(forKey: key) { let a = stored.copy() as! CAAnimation; a.isRemovedOnCompletion = false; layer.add(a, forKey: key) } }
                layer.sublayers?.forEach(retainTracks)
            }
            func poses() -> [String: Pose] { map.mapValues { pose($0, time: renderer.origin + clock.now) } }
            func compare(_ actual: Pose, _ expected: Pose, _ context: String) {
                check(abs(actual.y - expected.y) < 0.002, "M11.16 position " + context)
                check(abs(actual.font - expected.font) < 0.002, "M11.16 font " + context)
                check(abs(actual.depth - expected.depth) < 0.002, "M11.16 depth " + context)
                check(abs(actual.opacity - expected.opacity) < 0.002, "M11.16 opacity " + context)
                check(abs(actual.blur - expected.blur) < 0.002, "M11.16 focus " + context)
            }
            var event = 0, maxPositionJump: CGFloat = 0, maxFontJump: CGFloat = 0, frameChanges = 0, idleDeadline = clock.now
            func transition(delta: CGFloat?, samples: [Double], fast: Bool = true) throws {
                event += 1
                let before = poses(), began = clock.now, previousCommits = commits.count
                if let delta { _ = picker.wheel(deltaY: delta, precise: false); idleDeadline = clock.now + 1.1 }
                else { clock.advance(by: max(0, idleDeadline - clock.now)); check(!picker.scrolling, "M11.16 idle returns to list " + variant) }
                let start = clock.now, target = target(picker.models, selected: picker.settings.modelID, scrolling: picker.scrolling)
                views(picker).compactMap(\.layer).forEach(retainTracks)
                if delta != nil { check(commits.count == previousCommits + 1, "M11.16 accepted notch commits immediately once " + variant) }
                for (id, row) in map {
                    let at = pose(row, time: renderer.origin + start), old = before[id]!
                    maxPositionJump = max(maxPositionJump, abs(at.y - old.y)); maxFontJump = max(maxFontJump, abs(at.font - old.font))
                    compare(at, picker.reduceMotion ? target[id]! : old, "continuity \(variant) \(event) \(id)")
                    if delta != nil && row.toolTip == picker.selectedModel?.full {
                        check(row.word.letters.allSatisfy { $0.layer?.animation(forKey: "overlay.word.transform.translation.y") == nil }, "M11.16 model handoff does not roll effort letters")
                    }
                }
                var previous: [UInt8]?, localChanges = 0
                let rasterize = variant == "accum" || variant == "gauss"
                let isolated = variant == "off" && event == 1
                var reference: InkBounds?, isolatedWidths = Set<Int>()
                func renderRow(resting: Bool) -> [UInt8] {
                    let row = map[picker.settings.modelID]!
                    let mirror = OverlayM101Mirror(scale: 1, startTime: renderer.origin, view: row)
                    let copy = mirror.copy(row.layer!)
                    if resting {
                        func rest(_ layer: CALayer) { layer.removeAllAnimations(); layer.sublayers?.forEach(rest) }
                        rest(copy)
                    }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    mount.sublayers?.forEach { $0.removeFromSuperlayer() }; mount.addSublayer(copy); CATransaction.commit()
                    return renderer.render(at: clock.now)
                }
                if isolated {
                    let pixels = renderRow(resting: true)
                    reference = inkBounds(pixels, width: renderer.width, height: renderer.height)
                    check(reference != nil, "M11.16 isolated native glyph reference renders")
                }
                for (index, t) in samples.enumerated() {
                    clock.advance(by: max(0, start + t - clock.now)); host.layoutSubtreeIfNeeded()
                    for (id, row) in map {
                        let a = before[id]!, b = target[id]!, actual = pose(row, time: renderer.origin + clock.now)
                        let expected = picker.reduceMotion ? b : Pose(y: interpolate(a.y, b.y, fast ? glideFast : glide, t),
                            font: interpolate(a.font, b.font, fast ? growFast : grow, t), depth: interpolate(a.depth, b.depth, fast ? glideFast : glide, t),
                            opacity: interpolate(a.opacity, b.opacity, OverlayMotion.ease(fast ? 0.28 : 0.35), t), blur: interpolate(a.blur, b.blur, OverlayMotion.ease(fast ? 0.28 : 0.35), t))
                        compare(actual, expected, "trajectory \(variant) \(event) \(id) \(index)")
                        trace += "\(variant),\(event),\(id),\(t),\(actual.y),\(actual.font),\(actual.depth),\(actual.opacity),\(actual.blur),\(expected.y),\(expected.font),\(expected.depth),\(expected.opacity),\(expected.blur)\n"
                    }
                    if isolated, let reference {
                        let pixels = renderRow(resting: false)
                        let ink = inkBounds(pixels, width: renderer.width, height: renderer.height)
                        check(ink != nil, "M11.16 isolated native glyph remains visible frame \(index)")
                        if let ink {
                            let id = picker.settings.modelID, a = before[id]!, b = target[id]!
                            let y = interpolate(a.y, b.y, glideFast, t), font = interpolate(a.font, b.font, growFast, t)
                            let opacity = interpolate(a.opacity, b.opacity, OverlayMotion.ease(0.28), t)
                            let expectedY = y + (reference.rect.minY - b.y) * font / 28
                            let expectedWidth = reference.rect.width * font / 28
                            let inferredFont = 28 * ink.rect.width / reference.rect.width
                            let inferredOpacity = (ink.peak - 30) / (reference.peak - 30)
                            check(abs(ink.rect.minY - expectedY) <= 3, "M11.16 rendered target position frame \(index)")
                            check(abs(ink.rect.width - expectedWidth) <= 3, "M11.16 rendered target glyph size frame \(index)")
                            check(abs(inferredOpacity - opacity) < 0.05, "M11.16 rendered target opacity frame \(index)")
                            isolatedWidths.insert(Int(ink.rect.width))
                            rasterTrace += "\(t),\(ink.rect.minY),\(ink.rect.width),\(inferredFont),\(inferredOpacity),\(expectedY),\(expectedWidth),\(font),\(opacity)\n"
                        }
                        try renderer.write(pixels, to: directory.appendingPathComponent("isolated-row-frame\(String(format: "%03d", index)).png"))
                    }
                    if rasterize {
                        // Rebuild the mirror for each semantic update: its glyph paint cache must not retain old effort/tint.
                        let mirror = OverlayM101Mirror(scale: 1, startTime: renderer.origin, view: picker)
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        mount.sublayers?.forEach { $0.removeFromSuperlayer() }; mount.addSublayer(mirror.copy(picker.layer!)); CATransaction.commit()
                        let pixels = renderer.render(at: clock.now)
                        if let previous, renderer.tileDiff(previous, pixels) > 0.05 { localChanges += 1 }
                        previous = pixels
                        try renderer.write(pixels, to: directory.appendingPathComponent("\(variant)-event\(event)-frame\(String(format: "%03d", index)).png"))
                    }
                }
                if isolated { check(isolatedWidths.count > 5, "M11.16 isolated glyphs render multiple intermediate font sizes") }
                if rasterize && samples.count > 10 { check(localChanges > 5, "M11.16 panel raster changes \(variant) event \(event)"); frameChanges += localChanges }
                check(clock.now >= began, "M11.16 clock remains monotonic")
            }
            let frames = (0...24).map { Double($0) / 60 }
            try transition(delta: -1, samples: frames) // first notch: normal list -> drum + next model
            check(picker.settings.modelID == "g6sol" && picker.settings.effort == .low && picker.reasoning.value == .low, "M11.16 wheel restores effort and synchronizes slider")
            try transition(delta: -1, samples: [0, 0.03, 0.08, 0.12])
            try transition(delta: 1, samples: frames) // reverse before the previous CA tail completes
            clock.advance(by: 0.01)
            try transition(delta: nil, samples: (0...36).map { Double($0) / 60 }, fast: false)
            check(commits == ["g6sol", "g61sol", "g6sol"], "M11.16 idle adds no deferred selection " + variant)
            // Exercise every adjacent pair, including the 13pt generation gap, in both directions.
            for _ in 0..<4 { try transition(delta: 1, samples: frames) }
            for _ in 0..<6 { try transition(delta: -1, samples: frames) }
            metrics.append(["variant": variant, "maxPositionJump": maxPositionJump, "maxFontJump": maxFontJump, "renderedPanelChangingFrames": frameChanges])
            picker.dismiss(); clock.advance(by: 0.3)
        }
        // Event logic is tested separately from animation sampling, with exact boundary and rejected-notch timing.
        let clock = OverlayManualClock(), host = OverlayView(frame: CGRect(x: 0, y: 0, width: 760, height: 820)), picker = OverlayModelPicker(clock: clock)
        picker.reduceMotion = true
        var settings = ModelSettings(); settings.modelID = "g56luna"
        var selected: [String] = []; picker.onModelSelected = { selected.append($0.id) }
        picker.configure(settings: settings, models: ModelCatalog.mockModels); picker.present(anchor: .zero, in: host)
        _ = picker.wheel(deltaY: -1, precise: false)
        clock.advance(by: 0.02); _ = picker.wheel(deltaY: -1, precise: false)
        clock.advance(by: 0.02); _ = picker.wheel(deltaY: -1, precise: false)
        check(selected == ["g56terra"], "M11.16 20ms and 40ms rapid notches are rejected")
        clock.advance(by: 0.005); _ = picker.wheel(deltaY: -1, precise: false)
        check(selected == ["g56terra"], "M11.16 v1 strict 45ms boundary is rejected")
        clock.advance(by: 0.001); _ = picker.wheel(deltaY: -1, precise: false)
        check(selected == ["g56terra", "g56sol"], "M11.16 46ms notch is accepted")
        clock.advance(by: 0.046); _ = picker.wheel(deltaY: 1, precise: false)
        check(picker.settings.modelID == "g56terra", "M11.16 reverse notch is exactly one model")
        for _ in 0..<10 { clock.advance(by: 0.046); _ = picker.wheel(deltaY: 1, precise: false) }
        check(picker.settings.modelID == "g56luna" && selected.count == 4, "M11.16 beginning clamps without duplicate commits")
        for _ in 0..<10 { clock.advance(by: 0.046); _ = picker.wheel(deltaY: -1, precise: false) }
        check(picker.settings.modelID == "g6astra" && selected.count == 10, "M11.16 end clamps without wrapping")
        _ = picker.wheel(deltaY: 0, precise: false)
        clock.advance(by: 1.099); check(picker.scrolling, "M11.16 idle still scrolling at 1099ms")
        clock.advance(by: 0.001); check(!picker.scrolling && selected.count == 10, "M11.16 idle returns at 1100ms without committing")
        func allLayers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(allLayers) }
        check(views(picker).compactMap(\.layer).flatMap(allLayers).allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "M11.16 Reduce Motion omits wheel, word and ambient animations")
        settings.modelID = "g56terra"; settings.daybreak = true; picker.configure(settings: settings, models: ModelCatalog.mockModels)
        clock.advance(by: 0.046); _ = picker.wheel(deltaY: -1, precise: false)
        check(picker.settings.modelID == "g6luna" && picker.settings.daybreak, "M11.16 Daybreak wheel skips incompatible models")
        let sparse: [ModelCatalog.Model] = [
            .init(id: "fast", name: "Fast", version: "6", efforts: [.low, .high], serviceTiers: ["priority"], cyberPrograms: ["daybreakBlue"], reportedByCore: true),
            .init(id: "standard", name: "Standard", version: "6", efforts: [.medium, .high], cyberPrograms: ["daybreakBlue"], reportedByCore: true)
        ]
        settings.modelID = "fast"; settings.effort = .low; settings.speed = .fast; settings.memory["standard"] = .medium
        picker.configure(settings: settings, models: sparse)
        clock.advance(by: 0.046); _ = picker.wheel(deltaY: -1, precise: false)
        check(picker.settings.modelID == "standard" && picker.settings.speed == .standard && picker.speedSelector.value == .standard
              && picker.reasoning.value == .medium && picker.reasoning.levels == [.medium, .high] && picker.note?.contains("Using Standard") == true,
              "M11.16 wheel synchronizes effort, allowed speed, normalization caption and Daybreak")
        picker.dismiss(); clock.advance(by: 0.3)
        check(!picker.wheel(deltaY: -1, precise: false), "M11.16 dismissed picker rejects stale wheel input")
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "M11.16 wheel verification remains windowless")
        try trace.write(to: directory.appendingPathComponent("tracks.csv"), atomically: true, encoding: .utf8)
        try rasterTrace.write(to: directory.appendingPathComponent("isolated-row-raster.csv"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("metrics.json"))
    }
}
#endif
