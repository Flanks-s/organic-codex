#if M1_SELFTEST || NATIVE_SCROLL_BENCHMARK
import AppKit

/// Synthetic only. Uses unattached views and never starts the application event loop.
@MainActor enum NativeTranscriptScrollVerification {
    struct Timing: Codable {
        let name: String
        let samplesMS: [Double]
        var medianMS: Double { samplesMS.sorted()[samplesMS.count / 2] }
        var p95MS: Double { samplesMS.sorted()[Int(ceil(Double(samplesMS.count) * 0.95)) - 1] }
        var maximumMS: Double { samplesMS.max() ?? 0 }
        var totalMS: Double { samplesMS.reduce(0, +) }
    }
    static func fixture() -> Conversation {
        let c = Conversation(id: "scroll-synthetic-3000", title: "Synthetic scroll workload")
        let sentence = "Synthetic assistant prose with **emphasis**, `inline code`, and a deterministic explanation. "
        c.items = (0..<3000).map { i in
            let slot = i < 2500 ? i % 125 : 0, kind: RowKind, text: String
            if slot < 80 {
                kind = .tool(.command); text = "printf 'synthetic-\(i)'"
            } else if slot < 110 {
                kind = .assistant
                let count = 200 + (i * 137 % 1801)
                text = String(String(repeating: sentence, count: count / sentence.count + 1).prefix(count))
            } else if slot < 122 {
                kind = .user; text = "Synthetic request \(i): explain the next step."
            } else {
                kind = .assistant
                let count = 4096 + (i * 211 % (30 * 1024 - 4096 + 1))
                let line = "let syntheticValue = 42 // Synthetic fixture only\n"
                text = "```swift\n" + String(String(repeating: line, count: count / line.count + 1).prefix(count - 13)) + "\n```"
            }
            return .init(id: "scroll-\(i)", turnID: "turn-\(i / 125)", kind: kind, text: text,
                         status: "completed", timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        }
        return c
    }
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        let saved = NativeAppearance.current
        NativeAppearance.apply(.init()); defer { NativeAppearance.apply(saved) }
        let c = fixture(), view = NativeTranscript(conversation: c)
        view.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        view.followsEnd = false
        check(c.items.count == 3000 && c.items.filter { TranscriptPresentation.isActivity($0.rowKind) }.count == 2100,
              "Scroll fixture has 3000 synthetic items and 70 percent compact activity")
        check(c.items.filter { $0.rowKind == .user }.count == 240 &&
              c.items.filter { $0.text.hasPrefix("```swift") }.count == 60 &&
              c.items.filter { $0.text.hasPrefix("```swift") }.allSatisfy { (4096...30 * 1024).contains($0.text.utf8.count) },
              "Scroll fixture has 8 percent user and 2 percent 4-30 KiB code")
        var timings: [Timing] = []
        var detail: [[String: Any]] = []
        // Each pass gets the same offset and exactly 120 upward steps of 60 points.
        // The first pass includes cold row measurement. No outliers are discarded.
        for pass in 0..<4 {
            view.scrollToEnd()
            view.scrollOffset = CGPoint(x: 0, y: max(0, view.scrollOffset.y - 2200))
            view.layoutSubtreeIfNeeded()
            var samples: [Double] = []
            for tick in 0..<120 {
                var captured: CGImage?
                var updateEnd = 0.0, layoutEnd = 0.0, displayEnd = 0.0
                let start = CACurrentMediaTime()
                autoreleasepool {
                    view.scrollOffset = CGPoint(x: 0, y: max(0, view.scrollOffset.y - 60))
                    updateEnd = CACurrentMediaTime()
                    view.layoutSubtreeIfNeeded()
                    layoutEnd = CACurrentMediaTime()
                    view.displayIfNeeded()
                    displayEnd = CACurrentMediaTime()
                    if pass >= 2 {
                        let scale: CGFloat = pass == 2 ? 1 : 2
                        captured = VerificationRaster.capture(view, scale: scale)
                    }
                }
                let end = CACurrentMediaTime()
                samples.append((end - start) * 1000)
                let mounted = view.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.filter { !$0.isHidden }
                detail.append(["pass": pass, "tick": tick, "offset": view.scrollOffset.y,
                    "mounted": view.mountedRowCount, "pooled": view.pooledRowCount,
                    "mountedCode": mounted.filter { $0.item.text.hasPrefix("```swift") }.count,
                    "updateMS": (updateEnd - start) * 1000, "layoutMS": (layoutEnd - updateEnd) * 1000,
                    "displayMS": (displayEnd - layoutEnd) * 1000, "captureAndDrainMS": (end - displayEnd) * 1000])
                if let captured, tick == 0 || tick == 60 || tick == 119 {
                    try NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:])!
                        .write(to: output.appendingPathComponent("scroll-\(tick)-\(pass == 2 ? 1 : 2)x.png"))
                }
            }
            timings.append(Timing(name: ["cold-update-layout", "warm-update-layout", "warm-update-layout-capture-1x", "warm-update-layout-capture-2x"][pass], samplesMS: samples))
        }
        check(view.window == nil && NSApp.windows.allSatisfy { !$0.isVisible }, "Scroll benchmark opens no window")
        check(view.mountedRowCount < 125 && view.pooledRowCount <= 125, "Scroll benchmark retains bounded rows without reducing overscan")
        let summaries: [[String: Any]] = timings.map { t in
            ["name": t.name, "medianMS": t.medianMS, "p95MS": t.p95MS,
             "maximumMS": t.maximumMS, "totalMS": t.totalMS, "samplesMS": t.samplesMS,
             "ticksOver8MS": t.samplesMS.filter { $0 >= 8 }.count]
        }
        let report: [String: Any] = ["items": 3000, "activity": 2100, "assistant": 600, "user": 240, "code": 60,
            "ticks": 120, "stepPoints": 60, "width": 1080, "height": 720,
            "build": _isDebugAssertConfiguration() ? "-Onone" : "-O", "timings": summaries, "detail": detail]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("scroll-performance.json"))
        for t in timings { print(String(format: "SCROLL %@ median %.3f p95 %.3f max %.3f total %.3f ms", t.name, t.medianMS, t.p95MS, t.maximumMS, t.totalMS)) }
        view.dispose()
    }
    #if !SCROLL_BASELINE
    static func verifyInteractions(check: (Bool, String) -> Void) {
        let c = Conversation(id: "scroll-interactions", title: "Synthetic interaction retention")
        c.items = (0..<600).map { .init(id: "interaction-\($0)", turnID: "turn", kind: .tool(.command),
            text: "printf 'synthetic-\($0)'\nSynthetic details", status: "completed") }
        c.items[0] = .init(id: "interaction-0", turnID: "turn", kind: .user, text: "Synthetic editable request")
        let store = ConversationStore(conversations: [c]), view = NativeTranscript(conversation: c, store: store)
        view.verificationAXScreenOrigin = .zero
        view.frame = CGRect(x: 0, y: 0, width: 1080, height: 500); view.followsEnd = false; view.scrollOffset = .zero
        func row(_ id: String) -> NativeTranscriptRow? {
            view.scrollView.documentView!.subviews.compactMap { $0 as? NativeTranscriptRow }.first { !$0.isHidden && $0.item.id == id }
        }
        let tool = row("interaction-1")!
        let toggle = tool.subviews.compactMap { $0 as? NativeTranscriptActionButton }.first!
        check(toggle.accessibilityLabel()?.hasPrefix("Expand ") == true, "Scroll cached chevron keeps Expand AX label")
        toggle.performClick(nil)
        check(view.isExpanded(itemID: "interaction-1") && tool.body.string.contains("Synthetic details"), "Scroll cached chevron click expands original item")
        check(toggle.accessibilityLabel()?.hasPrefix("Collapse ") == true, "Scroll expanded chevron keeps Collapse AX label")
        toggle.performClick(nil)
        view.setSelectedRange(NSRange(location: 0, length: 5), itemID: "interaction-1")
        view.scrollToEnd()
        check(row("interaction-1") === tool && tool.preventsRecycling && tool.body.selectedRange().length == 5,
              "Scroll selection pins the same native text view outside overscan")
        view.setSelectedRange(NSRange(location: 0, length: 0), itemID: "interaction-1")
        view.scrollOffset = CGPoint(x: 0, y: view.scrollOffset.y - 60)
        check(row("interaction-1") == nil, "Scroll cleared selection allows pooling")
        view.scrollOffset = .zero
        let menuRow = row("interaction-1")!
        menuRow.menuWillOpen(menuRow.menu!); view.scrollToEnd()
        check(row("interaction-1") === menuRow && !view.canHandoff, "Scroll open context menu pins row and blocks handoff")
        menuRow.menuDidClose(menuRow.menu!); view.scrollOffset = CGPoint(x: 0, y: view.scrollOffset.y - 60)
        check(row("interaction-1") == nil && view.canHandoff, "Scroll context menu close releases recycling and handoff")
        view.scrollOffset = .zero
        let user = row("interaction-0")!
        var edits = 0, forks = 0
        view.onEditMessage = { _ in edits += 1 }; view.onForkMessage = { _ in forks += 1 }
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        user.mouseEntered(with: event)
        let buttons = user.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        check(Set(buttons.compactMap { $0.accessibilityLabel() }).isSuperset(of: ["Copy", "Edit", "Fork from Here"]),
              "Scroll first hover lazily creates labelled Copy Edit Fork controls")
        check(buttons.allSatisfy { !$0.frame.isEmpty }, "Scroll hover controls are positioned before drawing")
        _ = user.accessibilityCustomActions()?.first { $0.name == "Edit" }?.handler?()
        _ = user.accessibilityCustomActions()?.first { $0.name == "Fork from Here" }?.handler?()
        check(edits == 1 && forks == 1, "Scroll user AX routes current Edit and Fork callbacks")
        user.mouseExited(with: event)
        check(buttons.allSatisfy(\.isHidden), "Scroll mouse exit hides hover controls")
        // A normal model refresh still configures a resident row before the next pure scroll skips it.
        store.apply(.init(id: 1, time: 0, method: "item/commandExecution/outputDelta", params: [
            "threadId": .string(c.id), "itemId": "interaction-1", "delta": "\nSynthetic streamed suffix"]))
        view.setExpanded(true, itemID: "interaction-1")
        check(row("interaction-1")?.body.string.contains("Synthetic streamed suffix") == true,
              "Scroll optimization preserves a resident row's streamed refresh")
        let before = row("interaction-1")!
        view.scrollOffset = CGPoint(x: 0, y: 60)
        check(row("interaction-1") === before && before.body.string.contains("Synthetic streamed suffix"),
              "Scroll reuses the updated resident row without losing streamed text")
        view.dispose()
        check(view.scrollView.documentView!.subviews.isEmpty && view.pooledRowCount == 0,
              "Scroll dispose removes attached hidden pool cells")
    }
    static func verifyChevron(output: URL, check: (Bool, String) -> Void) throws {
        let saved = NativeAppearance.current
        defer { NativeAppearance.apply(saved); NativeDisplayOptions.shared.setVerificationState(nil) }
        var observations: [[String: Any]] = []
        for theme in 0..<3 {
            var look = NativeAppearance.Look()
            if theme == 1 { look.foreground = NSColor(srgbRed: 0.7, green: 0.35, blue: 0.8, alpha: 1) }
            NativeAppearance.apply(look)
            NativeDisplayOptions.shared.setVerificationState(.init(increaseContrast: theme == 2, reduceTransparency: false))
            for textScale: CGFloat in [0.85, 1, 1.4, 2] {
                look.textScale = textScale; NativeAppearance.apply(look)
                for scale: CGFloat in [1, 2] {
                    let size = ceil(16 * textScale)
                    let reference = NativeTranscriptActionButton(frame: CGRect(x: 0, y: 0, width: size, height: size))
                    let cached = NativeTranscriptActionButton(frame: reference.frame)
                    for button in [reference, cached] {
                        button.font = TranscriptLayout.font(11, scale: textScale)
                        button.title = ""
                        button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show Details")
                        button.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
                        button.contentTintColor = NativePalette.tertiaryLabel
                        button.setAccessibilityLabel("Expand Command")
                    }
                    cached.cachesChevron = true
                    for state in 0..<3 {
                        for button in [reference, cached] { button.isEnabled = state != 2; button.isHighlighted = state == 1 }
                        let a = VerificationRaster.capture(reference, scale: scale)
                        let b = VerificationRaster.capture(cached, scale: scale)
                        let diff = pixelDifference(a, b)
                        let name = "theme\(theme)-text\(textScale)-\(Int(scale))x-state\(state)"
                        check(diff.changed == 0 && diff.maximum == 0, "Chevron exact AppKit pixels " + name)
                        check(diff.ink > 0, "Chevron reference contains visible ink " + name)
                        check(cached.accessibilityLabel() == reference.accessibilityLabel(), "Chevron retains native AX label " + name)
                        observations.append(["case": name, "changedPixels": diff.changed, "maximumChannelError": diff.maximum, "inkPixels": diff.ink])
                        if textScale == 1 && theme == 0 && state == 0 {
                            try NSBitmapImageRep(cgImage: a).representation(using: .png, properties: [:])!
                                .write(to: output.appendingPathComponent("chevron-reference-\(Int(scale))x.png"))
                            try NSBitmapImageRep(cgImage: b).representation(using: .png, properties: [:])!
                                .write(to: output.appendingPathComponent("chevron-cached-\(Int(scale))x.png"))
                        }
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("chevron-pixels.json"))
    }
    private static func pixelDifference(_ a: CGImage, _ b: CGImage) -> (changed: Int, maximum: Int, ink: Int) {
        func bytes(_ image: CGImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            result.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return result
        }
        guard a.width == b.width, a.height == b.height else { return (-1, 255, 0) }
        let x = bytes(a), y = bytes(b)
        var changed = 0, maximum = 0, ink = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            var differs = false
            for channel in 0..<4 {
                let delta = abs(Int(x[i + channel]) - Int(y[i + channel]))
                maximum = max(maximum, delta); differs = differs || delta != 0
            }
            if differs { changed += 1 }
            if x[i + 3] > 0 { ink += 1 }
        }
        return (changed, maximum, ink)
    }
    #endif

}
#if NATIVE_SCROLL_BENCHMARK
@main @MainActor enum NativeTranscriptScrollMain {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0, failures = 0
        try NativeTranscriptScrollVerification.run(output: output) { pass, label in
            checks += 1; if !pass { failures += 1; print("FINDING: " + label) }
        }
        print("SCROLL: \(checks) checks, \(failures) findings")
        if failures > 0 { exit(1) }
    }
}
#endif
#endif
