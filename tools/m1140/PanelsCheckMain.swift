import AppKit
import QuartzCore
import ImageIO

@main @MainActor enum FunctionPanelsCheck {
    static var checks = 0
    static var failures: [String] = []
    static var frames: [[String: Any]] = []
    static var costs: [[String: Any]] = []
    static func check(_ passed: Bool, _ name: String) {
        checks += 1
        if !passed { failures.append(name); print("FAIL: " + name) }
    }
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
    static func settle(_ view: FunctionPanelView, from: Double = 0) {
        for index in 0...108 { view.advance(to: from + Double(index) / 60) }
    }
    static func press(_ view: FunctionPanelView, _ id: String) {
        check(view.buttons[id]?.accessibilityPerformPress() == true, "input.press.\(id)")
    }
    static func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                             keyCode: code)!
    }
    static func geometry() {
        check(FunctionPanelPage.navigation.count == 5 && Set(FunctionPanelPage.navigation).count == 5,
            "geometry.navigation-five")
        check(FunctionPanelFixtures.bodies.count == 24, "geometry.catalog-24")
        check(!FunctionPanelFixtures.bodies.contains { ["earth", "sun", "moon"].contains($0.id) },
            "geometry.reserved-excluded")
        check(FunctionPanelGeometry.panel == CGRect(x: 66, y: 264, width: 491, height: 464), "geometry.panel")
        check(FunctionPanelGeometry.orb(0) == CGRect(x: 283.5, y: 52, width: 56, height: 56), "geometry.orb-rest")
        check(FunctionPanelGeometry.orb(1) == CGRect(x: 95, y: 40, width: 150, height: 150), "geometry.orb-open")
        check(FunctionPanelGeometry.title(width: 188, progress: 1) == CGRect(x: 76, y: 186, width: 188, height: 32),
            "geometry.title")
        check(FunctionPanelGeometry.titleWidth("", measured: -1000) == 112 && FunctionPanelGeometry.titleWidth("",
                measured: 1000) == 320, "geometry.title-limits")
        check(near(FunctionPanelGeometry.leftX(130), 55) && near(FunctionPanelGeometry.rightX(130), 310),
            "geometry.arcs")
        check(FunctionPanelGeometry.leftStations == [46, 80, 114, 148, 182], "geometry.left-stations")
        let chips = FunctionPanelGeometry.chips(page: .overview, hover: nil)
        check(chips.count == 4 && chips.map { $0.1.minX } == [106, 140, 174, 208], "geometry.chip-row")
        check(chips.allSatisfy { $0.1.minY == 228 && $0.1.size == CGSize(width: 26, height: 26) }, "geometry.chip-size")
        for page in FunctionPanelPage.allCases {
            check(FunctionPanelGeometry.chips(page: page, hover: .files).count == 4, "geometry.chips.\(page.rawValue)")
        }
        let slots = FunctionPanelGeometry.bodySlots(count: 24, offset: 8)
        check(slots.filter { !$0.clipped }.count == 8, "geometry.body-eight-visible")
        check(slots.filter(\.clipped).allSatisfy { $0.frame.width == 9 }, "geometry.body-edge-clipping")
        check(slots.filter { !$0.clipped }.allSatisfy { $0.frame.width == 22 }, "geometry.body-diameter")
        check(near(slots[2].frame.midY - slots[1].frame.midY, 21), "geometry.body-pitch")
        check(FunctionPanelGeometry.librarySlot(index: 4, selected: false, tile: false,
                tileIndex: 0) == CGRect(x: 173.3, y: 157, width: 144.3, height: 83.25), "geometry.library-wall")
        check(FunctionPanelGeometry.librarySlot(index: 0, selected: true, tile: false,
                tileIndex: 0).size == CGSize(width: 260, height: 150), "geometry.library-cover")
        check(FunctionPanelGeometry.librarySlot(index: 0, selected: false, tile: true, tileIndex: 3) == CGRect(x: 252,
                y: 236, width: 35.1, height: 20.25), "geometry.library-tile")
        check(FunctionPanelGeometry.paneHeight(.library) == 389 && FunctionPanelGeometry.paneHeight(
                .files) == 456 && FunctionPanelGeometry.paneHeight(.outputs) == 350, "geometry.page-heights")
        let file = FunctionPanelGeometry.fileCard(index: 5, selected: 6, count: 7)
        check(file.0 == CGRect(x: 32, y: 158, width: 423, height: 266) && near(file.1, -1.2), "geometry.file-fan")
        check(FunctionPanelGeometry.outputCard(index: 0, selected: 0) == CGRect(x: 137.5, y: 16, width: 216,
                height: 272), "geometry.output-selected")
        let neighbour = FunctionPanelGeometry.outputCard(index: 1, selected: 0)
        check(near(neighbour.width, 194.4) && near(neighbour.height, 244.8) && near(neighbour.maxY, 288),
            "geometry.output-neighbour-scale")
        check(FunctionPanelGeometry.outputRadius(selected: true) == 12 && near(FunctionPanelGeometry.outputRadius(
                    selected: false), 10.8), "geometry.output-scaled-radius")
        check(FunctionPanelGeometry.finishedTaskBack(index: 1, y: 500) == CGRect(x: 88, y: 506, width: 447,
                height: 36) && FunctionPanelGeometry.finishedTaskBack(index: 2, y: 500) == CGRect(x: 88, y: 512,
                width: 447, height: 36), "geometry.finished-stack-six")
        let blocks = FunctionPanelGeometry.subagentBlocks(count: 3, expanded: nil)
        check(blocks.map(\.minY) == [16, 94, 172] && blocks.allSatisfy { $0.size == CGSize(width: 284, height: 72) },
            "geometry.subagents-brief")
        let expanded = FunctionPanelGeometry.subagentBlocks(count: 3, expanded: 0)
        check(expanded.map(\.height) == [192, 22, 22] && expanded.map(\.minY) == [8, 205, 232],
            "geometry.subagents-expanded")
    }
    static func values() {
        for state in FunctionPanelFixtureState.allCases {
            let input = FunctionPanelFixtures.input(state: state)
            let context = input.context.text { "\(Int(($0 * 100).rounded()))%" }
            if state == .known { check(context == "61%", "values.known-context") }
            else {
                check(context != "0" && context != "0%", "values.no-zero.\(state.rawValue)")
                check(context == input.context.status, "values.context-status.\(state.rawValue)")
                check(input.worked.value == nil && input.model.value == nil,
                    "values.no-fabricated-details.\(state.rawValue)")
                check(!input.status.contains("sub-agents"), "values.no-hidden-child-count.\(state.rawValue)")
            }
            for page in FunctionPanelPage.allCases {
                let view = FunctionPanelView(input: input, reduced: true, automatic: false)
                view.open(page: page, at: 0)
                check(view.input.context == input.context, "values.immutable.\(state.rawValue).\(page.rawValue)")
                check(!view.needsFrames && !view.hasTimer, "values.no-loading-loop.\(state.rawValue).\(page.rawValue)")
                view.retire()
            }
        }
        let zero: FunctionPanelValue<Int> = .known(0)
        check(zero.text(String.init) == "0", "values.authoritative-zero-retained")
        let failed: FunctionPanelValue<Double> = .failed("Disconnected")
        check(failed.text { String($0) }.contains("Disconnected"), "values.failure-detail")
        let empty = FunctionPanelFixtures.input(empty: true)
        check(empty.covers.value?.isEmpty == true && empty.files.value?.isEmpty == true && empty.tasks.value?.isEmpty ==
            true && empty.outputs.value?.isEmpty == true, "values.empty-is-known-not-missing")
        let view = FunctionPanelView(input: empty, reduced: true, automatic: false)
        for page in FunctionPanelPage.allCases {
            view.open(page: page, at: 0)
            let detailControls = view.visibleButtonIDs.filter {
                $0.hasPrefix("cover.") || $0.hasPrefix("file.") || $0.hasPrefix("task.") || $0.hasPrefix("output.") }
            check(detailControls.isEmpty && !view.hasTimer, "values.empty-page-no-phantom-actions.\(page.rawValue)")
        }
        view.retire()
    }
    static func interactions(scale: CGFloat) {
        let host = FunctionPanelMockHost(), view = host.stage
        host.select(.overview); settle(view)
        check(view.state.isOpen && !view.needsFrames, "motion.open-settles.\(scale)")
        check(view.buttons["orb"]?.accessibilityRole() == .button, "ax.button-role.\(scale)")
        check(view.buttons["orb"]?.accessibilityLabel() == "Close", "ax.button-label.\(scale)")
        check(view.accessibilityValue() as? String == "Overview · Running · 2 sub-agents · Context 61%",
            "ax.group-value.\(scale)")
        if let button = view.buttons["tab.Files"] {
            let point = view.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
            check(view.hitTest(point) === button, "hit.actual-tab.\(scale)")
        } else { check(false, "hit.actual-tab.\(scale)") }
        check(view.hitTest(CGPoint(x: 1000, y: 500)) == nil, "hit.outside-passes-through.\(scale)")
        view.focus("compact")
        check(view.state.focusID == "compact" && view.buttons["compact"]?.focused == true, "focus.intent.\(scale)")
        let ids = view.visibleButtonIDs, next = ids[(ids.firstIndex(of: "compact")! + 1) % ids.count]
        view.keyDown(with: key(48))
        check(view.state.focusID == next && view.buttons[next]?.focused == true, "focus.tab-native-event.\(scale)")
        view.keyDown(with: key(48, modifiers: .shift))
        check(view.state.focusID == "compact" && view.buttons["compact"]?.focused == true,
            "focus.shift-tab-native-event.\(scale)")
        view.beginTitle(); view.setTitleDraft("  Density revised  ")
        let editor = NSTextView(frame: .zero)
        check(view.control(view.nameField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
            "title.enter-consumed.\(scale)")
        check(view.state.title == "Density revised" && host.actions.contains(.rename("Density revised")),
            "title.enter-commits.\(scale)")
        view.beginTitle(); view.setTitleDraft("Discard this")
        check(view.control(view.nameField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
            "title.escape-consumed.\(scale)")
        check(view.state.title == "Density revised" && !host.actions.contains(.rename("Discard this")),
            "title.escape-no-write.\(scale)")
        view.beginTitle(); view.setTitleDraft("Blur saved")
        view.controlTextDidEndEditing(Notification(name: Notification.Name("NSControlTextDidEndEditingNotification"),
                object: view.nameField))
        check(view.state.title == "Blur saved" && !view.state.editingTitle && view.nameField.isHidden,
            "title.blur-commits.\(scale)")
        view.beginTitle(); view.setTitleDraft("  "); view.commitTitle()
        check(view.state.title == "Blur saved", "title.empty-keeps-original.\(scale)")
        press(view, "tab.Library"); settle(view, from: 2)
        check(view.state.page == .library, "input.library.\(scale)")
        press(view, "cover.cover-0"); check(view.state.coverID == "cover-0", "input.library-select.\(scale)")
        press(view, "cover.copy"); check(host.actions.contains(.copyCover("cover-0")), "input.copy-stable-id.\(scale)")
        press(view, "cover.wall"); press(view, "filter.PDFs")
        check(view.filteredCovers().allSatisfy { $0.kind == .pdf } && view.state.coverID == nil,
            "input.library-filter.\(scale)")
        view.selectPage(.files, at: 4); settle(view, from: 4)
        press(view, "file.file-3"); press(view, "file.open")
        check(host.actions.contains(.openFile("file-3")), "input.file-open.\(scale)")
        view.selectPage(.background, at: 6); settle(view, from: 6)
        press(view, "task.main.tests"); check(view.state.taskID == "tests", "input.task-expand.\(scale)")
        press(view, "task.action.tests")
        check(host.actions.contains(.task("tests", "Stop")), "input.task-action.\(scale)")
        press(view, "task.fan"); check(view.state.fanTasks, "input.task-fan.\(scale)")
        view.selectPage(.outputs, at: 8); settle(view, from: 8)
        press(view, "output.Next"); press(view, "output.copy")
        check(view.state.outputID == "output-1" && host.actions.contains(.copyOutput("output-1")),
            "input.output-next.\(scale)")
        view.toggleOption(0)
        check(view.visibleButtonIDs.filter { $0.hasPrefix("body.") }.count == 8, "input.body-visible-eight.\(scale)")
        view.scrollBodies(100)
        check(view.visibleButtonIDs.contains("body.sedna"), "input.body-last-reachable.\(scale)")
        press(view, "body.sedna"); check(view.state.bodyID == "sedna", "input.body-select.\(scale)")
        view.toggleOption(1); press(view, "colour.coral")
        check(view.state.colourID == "coral", "input.colour-select.\(scale)")
        view.toggleOption(2); press(view, "notify.Important")
        check(view.state.notification == "Important", "input.notify-select.\(scale)")
        view.buttons["notify.Important"]?.keyDown(with: key(125))
        check(view.state.notification == "Off", "input.notify-arrow.\(scale)")
        view.keyDown(with: key(53)); check(view.state.option == nil, "input.escape-option.\(scale)")
        check(view.state.focusID == "option.2" && view.buttons["option.2"]?.focused == true,
            "focus.escape-returns-to-bead.\(scale)")
        view.close(at: 10)
        check(view.hitTest(CGPoint(x: 170, y: 115)) == nil && view.visibleButtonIDs.isEmpty,
            "hit.close-withdraws.\(scale)")
        settle(view, from: 10)
        let before = view.motion.frames
        view.advance(to: 40)
        check(!view.needsFrames && view.motion.frames == before && !view.hasTimer, "motion.no-resident-tick.\(scale)")
        view.open(at: 50); view.advance(to: 50.12)
        let position = view.motion.progress
        view.close(at: 50.12)
        check(view.motion.progress == position, "motion.reverse-continuous.\(scale)")
        view.retire()
        check(!view.hasTimer && !view.state.editingTitle && view.interactiveRegions.isEmpty,
            "lifecycle.retire.\(scale)")
    }
    static func subagents() {
        for count in [0, 1, 3, 7] {
            let view = FunctionPanelView(input: FunctionPanelFixtures.input(subagentCount: count), reduced: true,
                automatic: false)
            view.open(at: 0)
            check(view.visibleButtonIDs.filter { $0.hasPrefix("sub.agent-") }.count == min(3, count),
                "subagents.visible.\(count)")
            check(view.visibleButtonIDs.contains("sub.more") == (count > 3), "subagents.more.\(count)")
            if count > 3 {
                press(view, "sub.more"); view.scrollSubagents(100)
                check(view.visibleButtonIDs.contains("sub.agent-6") && view.state.subagentOffset == 4,
                    "subagents.more-last-reachable")
                press(view, "sub.more")
                check(!view.state.showsAllSubagents && view.visibleButtonIDs.contains("sub.agent-0"),
                    "subagents.more-back")
            }
            if count > 0 {
                view.hoverSubagent("agent-0", at: 0); view.advance(to: 0.049)
                check(view.state.hoveredSubagent == nil, "subagents.hover-before-delay.\(count)")
                view.advance(to: 0.051)
                check(view.state.hoveredSubagent == "agent-0", "subagents.hover-after-delay.\(count)")
                view.pinSubagent("agent-0"); view.hoverSubagent(nil, at: 1); view.advance(to: 1.14)
                check(view.state.pinnedSubagent == "agent-0" && view.state.hoveredSubagent == nil,
                    "subagents.pinned-after-exit.\(count)")
            }
            view.retire()
        }
        let view = FunctionPanelView(input: FunctionPanelFixtures.input(), reduced: true, automatic: false)
        view.open(at: 0); view.pinSubagent("agent-2")
        view.update(FunctionPanelFixtures.input(reversedAgents: true))
        check(view.state.pinnedSubagent == "agent-2", "identity.selection-survives-reorder")
        view.update(FunctionPanelFixtures.input(subagentCount: 1))
        check(view.state.pinnedSubagent == nil, "identity.removed-selection-clears")
        view.update(FunctionPanelFixtures.input(many: true)); view.selectPage(.library, at: 1); view.scrollLibrary(100)
        check(view.visibleButtonIDs.contains("cover.cover-29"), "input.many-library-last-reachable")
        view.pinSubagent("agent-0"); view.scrollHistory("agent-0", delta: 100)
        check(view.state.historyOffsets["agent-0"] == 7, "subagents.history-first-reachable")
        view.scrollHistory("agent-0", delta: -100)
        check(view.state.historyOffsets["agent-0"] == 0, "subagents.history-latest-reachable")
        view.retire()
    }
    static func timerLifecycle() {
        var time = 0.0
        let view = FunctionPanelView(input: FunctionPanelFixtures.input(), automatic: true, now: { time })
        view.open(at: 0)
        check(view.hasTimer && view.timerStarts == 1, "motion.finite-timer-starts")
        time = 2
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        check(!view.hasTimer && !view.needsFrames, "motion.finite-timer-retires")
        let frameCount = view.motion.frames
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        check(view.motion.frames == frameCount, "motion.idle-has-no-work")
        view.retire()
    }
    static func mockActions() {
        let host = FunctionPanelMockHost(), view = host.stage
        host.select(.overview); settle(view)
        press(view, "option.3"); settle(view, from: 2)
        check(view.state.dockPinned && view.pinMotion.value == 1 && !view.needsFrames, "mock.pin-finite")
        check(host.actions.contains(.pin(true)), "mock.pin-action")
        press(view, "option.4"); settle(view, from: 4)
        check(view.state.archived && view.archiveMotion.value == 1 && !view.needsFrames, "mock.archive-finite")
        check(!view.visibleButtonIDs.contains("option.4") && host.actions.contains(.archive),
            "mock.archive-withdraws-controls")
        press(view, "title.button"); settle(view, from: 6)
        check(!view.state.archived && view.archiveMotion.value == 0 && host.actions.contains(.undoArchive),
            "mock.archive-undo")
        view.retire()
    }
    static func capture(_ host: FunctionPanelMockHost, _ name: String, scale: CGFloat, directory: URL) throws {
        host.layoutSubtreeIfNeeded(); host.stage.layoutSubtreeIfNeeded()
        let began = CACurrentMediaTime()
        let image = NativeViewBitmap.capture(host, scale: scale)
        let captureMS = (CACurrentMediaTime() - began) * 1000
        check(host.hasSoftBackground, "frames.background-blur-ready.\(name).\(scale)")
        if name == "overview" {
            let region = CGRect(x: 82 * scale, y: 317 * scale, width: 459 * scale, height: 19 * scale)
            let crop = image.cropping(to: region)!
            let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            var bright = 0
            for y in 0..<crop.height { for x in 0..<crop.width {
                let offset = y * context.bytesPerRow + x * 4
                if bytes[offset] > 170 && bytes[offset + 1] > 170 && bytes[offset + 2] > 170 { bright += 1 }
            } }
            check(bright > Int(30 * scale * scale), "frames.goal-second-line.\(scale)")
        }
        let filename = name + "-\(Int(scale))x.png"
        let url = directory.appendingPathComponent(filename)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "M1140.capture", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "M1140.capture", code: 2) }
        check(image.width == Int(host.bounds.width * scale) && image.height == Int(host.bounds.height * scale),
            "frames.dimensions.\(filename)")
        frames.append(["path": "frames/" + filename, "width": image.width, "height": image.height,
                       "scenario": host.scenario.rawValue, "state": host.dataState.rawValue, "agents": host.agentCount,
                       "sampleTime": host.sampleTime, "inputID": host.stage.input.id, "captureMS": captureMS,
                           "nativeMaterialCertified": false])
    }
    static func contactSheets(_ out: URL) throws {
        for scale in [1, 2] {
            let context = CGContext(data: nil, width: 1280, height: 442, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (index, scene) in FunctionPanelScenario.allCases.enumerated() {
                let url = out.appendingPathComponent("frames/\(scene.fileKey)-\(scale)x.png")
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                context.draw(image, in: CGRect(x: (index % 4) * 320, y: 442 - (index / 4 + 1) * 221, width: 320,
                        height: 221))
            }
            let url = out.appendingPathComponent("contact-\(scale)x.png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "M1140.contact", code: scale) }
        }
    }
    static func exportFrames(_ out: URL) throws {
        let directory = out.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scale: CGFloat in [1, 2] {
            for scenario in FunctionPanelScenario.allCases {
                let host = FunctionPanelMockHost(); let began = CACurrentMediaTime()
                host.select(scenario)
                let openMS = (CACurrentMediaTime() - began) * 1000
                host.sample(at: 1.8)
                costs.append(["scenario": scenario.fileKey, "scale": scale, "mockOpenMS": openMS,
                              "settledSampleMS": (CACurrentMediaTime() - began) * 1000])
                try capture(host, scenario.fileKey, scale: scale, directory: directory)
                host.stage.retire()
            }
            let motion = FunctionPanelMockHost(); motion.select(.overview)
            for sample in [0.25, 0.58, 0.8] {
                motion.sample(at: sample)
                try capture(motion, "opening-\(Int(sample * 1000))", scale: scale, directory: directory)
            }
            motion.sample(at: 1.8); motion.stage.close(at: 2); motion.sample(at: 2.18)
            check(motion.stage.motion.progress > 0 && motion.stage.motion.progress < 1,
                "frames.closing-is-intermediate.\(scale)")
            try capture(motion, "closing-180", scale: scale, directory: directory)
            motion.stage.open(page: .overview, at: 3); motion.sample(at: 4.8)
            motion.stage.selectPage(.library, at: 5); motion.sample(at: 5.07)
            try capture(motion, "page-swap-70", scale: scale, directory: directory)
            motion.stage.retire()
            for state in FunctionPanelFixtureState.allCases {
                let host = FunctionPanelMockHost(reduced: true)
                host.select(.library)
                host.setDataState(state)
                host.sample(at: 2)
                try capture(host, "data-\(state.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    scale: scale, directory: directory)
                host.stage.retire()
            }
            for count in [0, 1, 7] {
                let host = FunctionPanelMockHost(reduced: true)
                host.select(.subagents)
                host.setAgentCount(count)
                host.sample(at: 2)
                try capture(host, "subagents-\(count)", scale: scale, directory: directory); host.stage.retire()
            }
            for page in [FunctionPanelScenario.library, .files, .background, .outputs] {
                let host = FunctionPanelMockHost(reduced: true)
                host.setCollectionMode(.empty)
                host.select(page)
                host.sample(at: 2)
                try capture(host, "empty-\(page.fileKey)", scale: scale, directory: directory); host.stage.retire()
            }
            let many = FunctionPanelMockHost(reduced: true)
            many.setCollectionMode(.many)
            many.select(.library)
            many.stage.scrollLibrary(100)
            many.sample(at: 2)
            try capture(many, "many-library-last", scale: scale, directory: directory)
            many.select(.hover, at: 3); many.stage.scrollHistory("agent-0", delta: 100); many.sample(at: 5)
            try capture(many, "many-history-first", scale: scale, directory: directory); many.stage.retire()
            let narrow = FunctionPanelMockHost(size: CGSize(width: 960, height: 884), column: CGRect(x: 0, y: 0,
                    width: 360, height: 736), reduced: true)
            narrow.select(.overview); narrow.sample(at: 2)
            check(narrow.stage.geometry.origin.x == 0, "geometry.narrow-clamp.\(scale)")
            try capture(narrow, "narrow-column", scale: scale, directory: directory); narrow.stage.retire()
            let split = FunctionPanelMockHost(column: CGRect(x: 640, y: 0, width: 640, height: 736), reduced: true)
            split.select(.overview); split.sample(at: 2)
            check(split.stage.input == FunctionPanelFixtures.input(), "frames.split-same-data.\(scale)")
            try capture(split, "split-right", scale: scale, directory: directory); split.stage.retire()
        }
    }
    static func main() throws {
        _ = NSApplication.shared
        let initialWindows = NSApplication.shared.windows.count
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        geometry(); values(); subagents(); timerLifecycle(); mockActions()
        for scale: CGFloat in [1, 2] { interactions(scale: scale) }
        if !CommandLine.arguments.contains("--no-frames") { try exportFrames(output); try contactSheets(output) }
        check(NSApplication.shared.windows.count == initialWindows, "lifecycle.no-window-created")
        let report: [String: Any] = ["checks": checks, "failures": failures, "frames": frames, "costs": costs,
                                     "contactSheets": frames.isEmpty ? [] : ["contact-1x.png", "contact-2x.png"],
"focusCoverage": "Windowless focus intent and native text delegate; actual window firstResponder/IME belong to Claude.",
            "materialCoverage": "Actual native glass views installed; windowless PNG underlays certify structure only."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,
                .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("\(checks) checks, \(failures.count) failures, \(frames.count) frames")
        exit(failures.isEmpty ? 0 : 1)
    }
}
