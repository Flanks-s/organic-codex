import AppKit
import QuartzCore
import ImageIO
import CoreText

@main @MainActor enum FunctionPanelBCheck {
    static var checks = 0, failures: [String] = [], frames: [String] = []
    static var textLineCases: [[String: Any]] = []
    static var textLineChecks = 0
    static func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value {
            failures.append(name)
            print("FAIL: " + name)
        }
    }
    static func until(_ predicate: () -> Bool, seconds: Double = 15) async -> Bool {
        let end = CACurrentMediaTime() + seconds
        while !predicate() && CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }
    static func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
    static func reference(_ input: FunctionPanelPhaseInput, resources: BodyResources) async throws -> BodyRaster {
        let maps = try await resources.queue!.prepare(input.bodyID, maximumWidth: 512)
        return await Task.detached(priority: .utility) {
            var request = BodyRenderRequest(outer: 150, scale: input.scale, lightDegrees: Float(input.bin) * 360 / 32,
                phase: input.event.value.terminal())
            request.phaseLighting = .prepare(body: maps.body, map: maps.map, ring: maps.ring, clouds: maps.clouds,
                request: request)
            return BodyRasterizer.render(body: maps.body, map: maps.map, ring: maps.ring, clouds: maps.clouds,
                request: request)
        }.value
    }
    static func phase(_ state: BodyPhaseState, scale: Int, serial: UInt64 = 1, turn: String = "turn-7",
        body: String = "mercury") -> FunctionPanelPhaseInput {
        .init(bodyID: body, event: .init(sourceID: "check/\(body)/\(state.rawValue)/\(scale)", value: .init(state,
                    fraction: state == .unknown ? nil : 0.37), serial: serial, animate: false),
              turnID: turn, scale: scale, bin: 12, quality: .panelHD)
    }
    static func rendering() async throws {
        let corpus = BodyPhaseState.allCases.map { ("mercury", $0) } +
            (FunctionPanelFixtures.bodies.map(\.id) + ["sun", "earth", "moon"]).filter { $0 != "mercury" }.map { ($0,
                    BodyPhaseState.running) }
        for scale in [1, 2] { for (body, state) in corpus {
            let resources = BodyResources(), owner = FunctionPanelBodyOwner(resources: BodyResources())
            // Keep the independent target's resource owner separate from the delivered stream.
            let input = phase(state, scale: scale, body: body)
            owner.present(input, candidates: [])
            let ready = await until { owner.currentPicture?.quality == .panelHD }
            check(ready, "hd.ready.\(body).\(state).\(scale)")
            if let picture = owner.currentPicture {
                check(picture.image.width == 150 * scale && picture.nativeOuter == 150,
                    "hd.native-raster.\(body).\(state).\(scale)")
                check(BodyProfile.current.bodyDiameter(outer: 150, framing: .orb) * Float(scale) == Float(140 * scale),
                    "hd.body-diameter.\(scale)")
                check(picture.event == input.event && picture.turnID == input.turnID,
                    "phase.provenance.\(body).\(state).\(scale)")
                let target = try await reference(input, resources: resources)
                check(bytes(picture.image) == Data(target.pixels), "hd.independent-target.\(body).\(state).\(scale)")
            } else { check(false, "hd.native-raster.\(body).\(state).\(scale)") }
            let work = owner.phaseWork, publications = owner.publicationCount
            try? await Task.sleep(for: .milliseconds(80))
            check(work == owner.phaseWork && publications == owner.publicationCount && !owner.hasPendingWork,
                "resources.no-resident-tick.\(body).\(state).\(scale)")
            owner.close()
            _ = await until({ owner.resources.hdReservedBytes == 0 && owner.pendingImages == 0 }, seconds: 0.8)
            check(owner.resources.hdReservedBytes == 0, "resources.release-HD.\(body).\(state).\(scale)")
            check(owner.pendingImages == 0, "resources.close-images.\(body).\(state).\(scale)")
        } }
    }
    static func budgetAndCancellation() async {
        let resources = BodyResources(), owner = FunctionPanelBodyOwner(resources: resources)
        let held = resources.reserveHD(bytes: 16 * 1024 * 1024)!
        owner.present(phase(.running, scale: 2), candidates: [])
        _ = await until { owner.currentPicture != nil && owner.pendingImages == 0 }
        check(owner.currentPicture?.quality == .preview && owner.currentPicture?.image.width == 112,
            "resources.honest-preview")
        check(resources.hdReservedBytes == 16 * 1024 * 1024 && owner.loading == .budgetRefused,
            "resources.no-ledger-bypass")
        resources.releaseHD(held); owner.retryVisibleHD()
        check(await until { owner.currentPicture?.quality == .panelHD && !owner.hasPendingWork },
            "resources.visible-upgrade")
        owner.close(); _ = await until { resources.hdReservedBytes == 0 && owner.pendingImages == 0 }
        check(resources.hdReservedBytes == 0 && owner.pendingImages == 0, "resources.release-after-upgrade")
        resources.sprites.removeAll()
        check(resources.sprites.residentBytes == 0, "resources.release-preview-working-lease")
        let active = FunctionPanelBodyOwner(resources: BodyResources())
        let activeEvent = BodyPhaseEvent(sourceID: "cancel-visible-HD", value: .init(.running, fraction: 0.8),
            serial: 1)
        active.present(.init(bodyID: "saturn", event: activeEvent, turnID: "active", scale: 2, bin: 12,
                quality: .panelHD, animate: true), candidates: [])
        try? await Task.sleep(for: .milliseconds(20))
        active.close()
        check(await until { active.resources.hdReservedBytes == 0 && active.pendingImages == 0 &&
                BodyPhaseStream.activeJobs == 0 }, "resources.cancel-active-HD")
        check(!active.hasPendingWork, "resources.cancel-no-timer")
        let delayed = FunctionPanelBodyOwner(resources: BodyResources())
        delayed.imageDelay = .milliseconds(350)
        delayed.present(phase(.running, scale: 1), candidates: Array(FunctionPanelFixtures.bodies.prefix(8)).map(\.id))
        delayed.close(); try? await Task.sleep(for: .milliseconds(60))
        check(delayed.pendingImages == 0, "resources.cancel-image-tasks")
        check(delayed.requestCounts.isEmpty, "resources.no-hidden-image-work")
        _ = await until({ delayed.pendingImages == 0 && delayed.resources.hdReservedBytes == 0 }, seconds: 1)
        let provenance = FunctionPanelBodyOwner(resources: BodyResources())
        let original = phase(.running, scale: 1, serial: 10, turn: "old-turn")
        provenance.present(original, candidates: [])
        let newest = FunctionPanelPhaseInput(bodyID: original.bodyID,
            event: .init(sourceID: original.event.sourceID, value: .init(.failed, fraction: 0.37), serial: 11,
                animate: false),
            turnID: "new-turn", scale: 1, bin: 12, quality: .panelHD)
        provenance.present(newest, candidates: [])
        _ = await until { provenance.currentPicture?.quality == .panelHD && !provenance.hasPendingWork }
        check(provenance.currentPicture?.event == newest.event && provenance.currentPicture?.turnID == "new-turn",
            "phase.late-generation")
        provenance.close()
        _ = await until { provenance.resources.hdReservedBytes == 0 && provenance.pendingImages == 0 }
        check(BodyPhaseStream.activeJobs == 0, "resources.retired-jobs")
        let downgrade = FunctionPanelBodyOwner(resources: BodyResources()), initial = phase(.running, scale: 2)
        downgrade.present(initial, candidates: [])
        _ = await until { downgrade.currentPicture?.quality == .panelHD && !downgrade.hasPendingWork }
        downgrade.present(.init(bodyID: initial.bodyID, event: initial.event, turnID: initial.turnID,
                                scale: initial.scale, bin: initial.bin, quality: .preview), candidates: [])
        check(await until { downgrade.currentPicture?.quality == .preview && downgrade.resources.hdReservedBytes == 0 &&
                !downgrade.hasPendingWork }, "resources.quality-downgrade-retires-HD")
        downgrade.close(); _ = await until { downgrade.pendingImages == 0 }
    }
    static func atoms(_ host: FunctionPanelTextureMockHost) -> [(String, CGRect)] {
        host.stage.buttons.compactMap { id, button in
            let include = id == "sub.more" || ["option.", "body.", "colour.", "notify.",
                "sub.agent-"].contains { id.hasPrefix($0) }
            guard include, !button.isHidden, button.alphaValue > 0.01 else { return nil }
            var rect = button.bounds.insetBy(dx: button.inkInset, dy: button.inkInset)
            if button.symbol != nil && button.customPaint == nil && rect.width < 14 {
                rect = CGRect(x: button.bounds.midX - 7, y: button.bounds.midY - 7, width: 14, height: 14)
            }
            return (id, host.convert(rect, from: button))
        }
    }
    static func safetyAndCandidates() async {
        let host = FunctionPanelTextureMockHost(resources: BodyResources(), scale: 2, quality: .preview)
        check(host.phaseInput.event.value.fraction == Float(0.37), "phase.not-context")
        check(host.stage.input.context.value == 0.61, "phase.context-preserved")
        for option in [nil, 0, 1, 2] as [Int?] {
            for count in [0, 1, 3, 7] {
                host.stage.update(FunctionPanelFixtures.input(subagentCount: count))
                host.stage.interact { $0.option = option }
                for pin in [nil, "agent-0", "agent-1", "agent-2"] as [String?] {
                    host.stage.interact { $0.pinnedSubagent = pin }
                    let items = atoms(host)
                    check(items.allSatisfy { $0.1.minY >= host.chrome },
                        "tracks.safe-header.\(option ?? -1).\(count).\(pin ?? "none")")
                    var overlaps = false
                    for i in items.indices { for j in items.indices where i < j {
                        if !items[i].1.intersection(items[j].1).isEmpty { overlaps = true }
                    } }
                    check(!overlaps, "tracks.no-overlap.\(option ?? -1).\(count).\(pin ?? "none")")
                }
            }
            let displayed = NativeViewBitmap.capture(host, scale: 1)
            host.stage.isHidden = true
            let reserved = NativeViewBitmap.capture(host, scale: 1)
            host.stage.isHidden = false
            let headerBytes = displayed.bytesPerRow * Int(host.chrome)
            check(bytes(displayed).prefix(headerBytes) == bytes(reserved).prefix(headerBytes),
                "tracks.header-pixels.\(option ?? -1)")
        }
        let lyrics = FunctionPanelFixtures.input(subagentCount: 7).subagents.value!.map {
            $0.lines.suffix(2).joined(separator: "\n") }
        check(Set(lyrics).count == 7, "fixtures.distinct-subagent-lyrics")
        host.select(.customize)
        _ = await until { host.owner.pendingImages == 0 }
        let visible = Set(FunctionPanelGeometry.bodySlots(count: 24, offset: 0).map {
                host.stage.input.bodies[$0.index].id })
        check(FunctionPanelFixtures.bodies.filter { !visible.contains($0.id) }.allSatisfy { host.owner.requestCounts[
                    FunctionPanelBodySnapshot.key($0.id, outer: 22)] == nil }, "sprites.invisible-zero")
        for _ in 0..<2 { host.stage.scrollBodies(8); _ = await until { host.owner.pendingImages == 0 } }
        check(FunctionPanelFixtures.bodies.allSatisfy { host.owner.requestCounts[FunctionPanelBodySnapshot.key($0.id,
                    outer: 22)] != nil }, "sprites.all-24-reachable")
        check(FunctionPanelBodyOwner.maximumPrefetch == 0, "sprites.bounded-prefetch")
        let entries = host.stage.bodySnapshot.entries.values
        check(entries.allSatisfy { $0.image.width == $0.nativeOuter * $0.scale }, "sprites.native-dimensions")
        host.close(); _ = await until { host.owner.pendingImages == 0 && host.owner.resources.hdReservedBytes == 0 }
        check(BodyProfile.current.bodyDiameter(outer: 26, framing: .orb) == 22 && BodyProfile.current.bodyDiameter(
                outer: 22, framing: .orb) == 19, "sprites.profile-26-22-and-22-19")
        for scale in [1, 2] {
            let gallery = FunctionPanelTextureMockHost(resources: BodyResources(), scale: scale, quality: .preview)
            _ = await until { gallery.owner.pendingImages == 0 }
            check(gallery.stage.bodySnapshot.entries["mercury:26"]?.image.width == 26 * scale,
                "sprites.current-entry.\(scale)")
            gallery.select(.customize)
            for page in 0..<3 {
                _ = await until { gallery.owner.pendingImages == 0 }
                let wanted = Set(FunctionPanelGeometry.bodySlots(count: 24, offset: gallery.stage.state.bodyScroll
                    ).map { FunctionPanelBodySnapshot.key(gallery.stage.input.bodies[$0.index].id, outer: 22) })
                let images = gallery.stage.bodySnapshot.entries
                check(Set(images.keys) == wanted && images.values.allSatisfy { $0.image.width == 22 * scale &&
                        $0.nativeOuter == 22 }, "sprites.delivered-visible-page.\(scale).\(page)")
                if page < 2 { gallery.stage.scrollBodies(8) }
            }
            gallery.close(); _ = await until { gallery.owner.pendingImages == 0 }
        }
    }
    static func longTextInput() -> FunctionPanelInput {
        let base = FunctionPanelFixtures.input(many: true)
        func long(_ text: String) -> String { Array(repeating: "排版检查：" + text + " 中文排版完整字形、标题与历史不能互相覆盖。",
                count: 3).joined(separator: " ") }
        let agents = base.subagents.value!.map {
            FunctionPanelSubagent(id: $0.id, name: long($0.name), status: long($0.status),
                                 elapsed: .known(long($0.elapsed.text { $0 })), lines: $0.lines.map(long),
                                     canStop: $0.canStop)
        }
        return .init(id: base.id, title: base.title, goal: base.goal, status: base.status, model: base.model,
                     context: base.context, worked: base.worked, compactHistory: base.compactHistory,
                     bodyID: base.bodyID, bodies: base.bodies, colours: base.colours, subagents: .known(agents),
                     covers: base.covers, files: base.files, tasks: base.tasks, outputs: base.outputs)
    }
    static func textLayout() {
        let start = checks
        func coordinates(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width,
                rect.height].map(Double.init) }
        // Tolerance covers floating point roundoff, never a backing pixel.
        func contains(_ outer: CGRect, _ inner: CGRect) -> Bool { outer.insetBy(dx: -0.000001,
                dy: -0.000001).contains(inner) }
        let cases = FunctionPanelScenario.allCases.map { ($0.fileKey, $0.page, $0 == .customize ? 0 : nil) } +
            [("customize-colours", .overview, 1), ("customize-notifications", .overview, 2)]
        for scale in [1, 2] { for stress in [false, true] {
            let input = stress ? longTextInput() : FunctionPanelFixtures.input()
            let view = FunctionPanelView(input: input, reduced: true, automatic: false)
            for (scene, page, option) in cases {
                view.open(page: page, at: 0)
                for pin in [nil, "agent-0", "agent-1", "agent-2"] as [String?] {
                    view.interact { $0.option = option; $0.pinnedSubagent = pin }
                    let tag =
                        "subagents.text-lines.\(scene).\(scale)x.\(stress ? "long-CJK" : "fixture").\(pin ?? "brief")"
                    let lines = view.subagentText
                    check(Set(lines.map(\.agentID)).count == 3, tag + ".all-agents")
                    var boxes: [[String: Any]] = []
                    for (index, layout) in lines.enumerated() {
                        // Measure the retained line drawn by CTLineDraw, including its ellipsis
                        // and fallback-font CJK glyphs. Do not infer height from the point size.
                        let raw = CTLineGetImageBounds(layout.line, nil)
                        let glyph = CGRect(x: layout.baseline.x + raw.minX, y: layout.baseline.y - raw.maxY,
                                           width: raw.width, height: raw.height)
                        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                        let width = CGFloat(CTLineGetTypographicBounds(layout.line, &ascent, &descent, &leading))
                        let fragment = CGRect(x: layout.baseline.x, y: layout.baseline.y - ascent, width: width,
                            height: ascent + descent + leading)
                        let label = tag + ".\(layout.agentID).\(layout.role)"
                        check(glyph == layout.glyphs && fragment == layout.fragment, label + ".drawing-identity")
                        check(contains(layout.row, glyph) && contains(layout.row, fragment), label + ".complete-row")
                        check(contains(layout.band, glyph) && contains(layout.band, fragment), label + ".visible-band")
                        check(contains(layout.item, glyph) && contains(layout.item, fragment), label + ".own-item")
                        let transform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
                        check(contains(layout.band.applying(transform), glyph.applying(transform)) &&
                              contains(layout.band.applying(transform), fragment.applying(transform)),
                                  label + ".backing-bounds")
                        check(CTLineGetGlyphCount(layout.line) > 0 && glyph.width > 0 && glyph.height > 0,
                            label + ".shaped-glyphs")
                        if stress { check(layout.truncated, label + ".long-ellipsis") }
                        for other in lines.dropFirst(index + 1) {
                            check(!glyph.intersects(other.glyphs) && !fragment.intersects(other.fragment),
                                  label + ".separate.\(other.agentID).\(other.role)")
                        }
                        boxes.append(["agent": layout.agentID, "role": layout.role, "row": coordinates(layout.row),
                                      "band": coordinates(layout.band), "item": coordinates(layout.item),
                                          "glyph": coordinates(glyph),
                                      "fragment": coordinates(fragment), "truncated": layout.truncated,
                                          "sourceLength": layout.source.utf16.count])
                    }
                    for agent in input.subagents.value! {
                        let history = lines.filter { $0.agentID == agent.id && $0.role.hasPrefix("history.") }
                        let expected = pin == nil ? min(2, agent.lines.count) : pin == agent.id ? min(5,
                            agent.lines.count) : 0
                        check(history.count == expected, tag + ".\(agent.id).fixed-lines")
                        check(history.map(\.source) == Array(agent.lines.suffix(expected)),
                            tag + ".\(agent.id).unchanged-latest")
                    }
                    textLineCases.append(["case": tag, "scale": scale, "lines": boxes])
                    if pin == nil {
                        let image = NativeViewBitmap.capture(view, scale: CGFloat(scale))
                        check(image.width == 1280 * scale && image.height == 820 * scale, tag + ".native-raster")
                    }
                }
            }
            view.retire()
            check(view.subagentText.isEmpty, "subagents.text-lines.retire-clears.\(scale).\(stress)")
        } }
        textLineChecks = checks - start
    }
    static func save(_ host: FunctionPanelTextureMockHost, name: String, directory: URL) throws {
        let image = NativeViewBitmap.capture(host, scale: CGFloat(host.scale))
        let path = name + "-\(host.scale)x.png", url = directory.appendingPathComponent(path)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BodyError.invalid("PNG export") }
        frames.append(path)
    }
    static func contextPlacement() async {
        for scale in [1, 2] {
            for quality in [FunctionPanelPictureQuality.preview, .panelHD] {
                let host = FunctionPanelTextureMockHost(resources: BodyResources(), scale: scale, quality: quality)
                _ = await until { !host.owner.hasPendingWork }
                check(host.owner.currentPicture?.quality == quality,
                      "hd.native-raster.context-ready.\(scale)x.\(quality.rawValue)")
                let base = host.stage.input
                for scene in FunctionPanelScenario.allCases {
                    host.stage.update(base)
                    host.select(scene)
                    let tag = "context.placement.\(scene.fileKey).\(scale)x.\(quality.rawValue)"
                    let duplicate = host.stage.textFrames.contains { $0.text.hasPrefix("Context  ") }
                    check(!duplicate, tag + ".no-overview-copy")
                    var images: [Data] = []
                    for text in ["17%", "83%", "900 tokens", "Not provided"] {
                        var input = base
                        let lines = text == "900 tokens" ? [text, "Limit not provided"] : [text]
                        input.live = .init(
                            contextText: lines.joined(separator: " · "), contextLines: lines,
                            phaseText: "Phase unknown", filesTitle: "Files / Changes",
                            capabilities: "", semanticText: lines
                        )
                        host.stage.update(input)
                        let orb = host.stage.buttons["orb"]!
                        images.append(bytes(NativeViewBitmap.capture(orb, scale: CGFloat(scale))))
                        let ax = host.stage.accessibilityValue() as? String
                        check(ax?.contains(text) == true, tag + ".ax." + text)
                    }
                    check(Set(images).count == 4, tag + ".sphere-paints-every-value")
                }
                host.close()
                _ = await until { !host.owner.hasPendingWork }
            }
        }
    }
    static func export(_ output: URL) async throws {
        let directory = output.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let host = FunctionPanelTextureMockHost(resources: BodyResources(), scale: scale)
            _ = await until { host.owner.currentPicture?.quality == .panelHD && !host.owner.hasPendingWork }
            for scene in FunctionPanelScenario.allCases {
                host.select(scene); _ = await until { host.owner.pendingImages == 0 }
                try save(host, name: scene.fileKey, directory: directory)
            }
            host.select(.customize)
            for page in [2, 3] {
                host.stage.scrollBodies(8); _ = await until { host.owner.pendingImages == 0 }
                try save(host, name: "customize-bodies-page-\(page)", directory: directory)
            }
            for option in [1, 2] {
                host.stage.interact { $0.option = option }; _ = await until { host.owner.pendingImages == 0 }
                try save(host, name: option == 1 ? "customize-colours" : "customize-notifications",
                    directory: directory)
            }
            host.select(.overview)
            try save(host, name: "context-in-planet", directory: directory)
            host.close(); _ = await until { host.owner.resources.hdReservedBytes == 0 }
            let upgrade = FunctionPanelTextureMockHost(resources: BodyResources(), scale: scale, quality: .preview)
            _ = await until { upgrade.owner.currentPicture != nil && !upgrade.owner.hasPendingWork }
            try save(upgrade, name: "quality-preview", directory: directory)
            upgrade.setPhase(FunctionPanelTextureMockHost.phase(scale: scale))
            _ = await until { upgrade.owner.currentPicture?.quality == .panelHD && !upgrade.owner.hasPendingWork }
            try save(upgrade, name: "quality-HD", directory: directory)
            upgrade.close(); _ = await until { upgrade.owner.resources.hdReservedBytes == 0 }
        }
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await safetyAndCandidates(); try await rendering(); await budgetAndCancellation()
        textLayout()
        await contextPlacement()
        if !CommandLine.arguments.contains("--no-frames") { try await export(output) }
        check(NSApp.windows.isEmpty, "lifecycle.no-window-created")
        let report: [String: Any] = ["checks": checks, "failures": failures, "frames": frames,
            "HDLimit": 16 * 1024 * 1024,
                                    "nativeMaterialCertified": false, "phaseFraction": 0.37, "contextFraction": 0.61,
                                    "textLineChecks": textLineChecks, "textLineCaseCount": textLineCases.count]
        try JSONSerialization.data(withJSONObject: textLineCases, options: [.prettyPrinted,
                .sortedKeys]).write(to: output.appendingPathComponent("text-line-bounds.json"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,
                .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("\(checks) B checks, \(failures.count) failures, \(frames.count) frames")
        exit(failures.isEmpty ? 0 : 1)
    }
}
