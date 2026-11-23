import AppKit
import QuartzCore

@MainActor enum AmbientSpinnerVerification {
    static func run(to path: String, application: NSApplication) -> Int32 {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName.contains("Built-in") }) else { return 2 }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures = 0
        func test(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        func tree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(tree) }
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                let until = min(end, Date().addingTimeInterval(0.01))
                if let event = application.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                    application.sendEvent(event)
                }
                RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.001)))
                CATransaction.flush()
            }
        }
        func image(_ spin: NSView) -> Data? {
            guard let bitmap = spin.bitmapImageRepForCachingDisplay(in: spin.bounds) else { return nil }
            spin.cacheDisplay(in: spin.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        func moving(_ spin: NSProgressIndicator) -> Bool {
            if let side = spin as? NormieSidebarSpinner { return side.verificationAnimating }
            let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: spin).children.compactMap {
                child in child.label.flatMap { key in (child.value as? Bool).map { (key, $0) } }
            })
            return fields["spinning"] ?? fields["animating"] ?? false
        }
        func quiet(_ spins: [NSProgressIndicator]) -> Bool { !spins.isEmpty && !spins.contains(where: moving) }
        func staticFrame(_ spin: NSProgressIndicator) -> Bool { spin.isDisplayedWhenStopped && !moving(spin) }
        let domain = "OrganicShell.AmbientSpinnerVerification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var o = Options()
        o.mock = true
        o.live = false
        let app = AppController(o, windowDefaults: defaults, presentsWindows: false)
        MockReplay(store: app.store).start(live: false)
        guard let c = app.store.conversation("A") else { return 2 }
        c.running = true
        c.items = [.init(id: "ambient-command", turnID: "ambient", kind: .tool(.command),
                         text: "printf fixture", status: "running")]
        c.plan = [.init(id: "progress", title: "Synthetic step")]
        c.satellites = [.init(id: "child", face: "•ᴗ•")]
        let origin = screen.visibleFrame.origin
        let frame = CGRect(x: origin.x, y: origin.y, width: 1280, height: 820)
        let w = OrganicWindow(app: app, frame: frame, screen: screen, members: ["A", "B", "C"], normie: true, o: o)
        app.windows = [w]
        defer { w.window.close() }
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        w.show(focus: true)
        application.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
        w.workbench.requestInspector(shown: true)
        pump(1)
        guard w.window.isKeyWindow else {
            print("FIXTURE main window never became key")
            return 2
        }
        func indicators(in view: NSView) -> [NormieSidebarSpinner] {
            tree(view).compactMap { $0 as? NormieSidebarSpinner }.filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        func side(required: Bool = true) -> NormieSidebarSpinner? {
            let cell = tree(w.workbench.sidebar.view).compactMap { $0 as? NormieSidebarCell }
                .first { $0.title.stringValue == c.title }
            let result = cell?.runningIndicator
            if let result, !result.isHiddenOrHasHiddenAncestor { return result }
            if required { print("no visible sidebar spinner for A") }
            return nil
        }
        func composer() -> NSProgressIndicator? { w.workbench.detail.composer?.contextRow.spinner }
        func inspector() -> [NormieSidebarSpinner] { indicators(in: w.workbench.inspector.view) }
        func mainSpins() -> [NSProgressIndicator] {
            let spins = inspector()
            guard spins.count == 2 else { return [] }
            return [side(), composer()].compactMap { $0 } + spins
        }
        func mark() -> NSView? {
            tree(w.workbench.detail.view).first { view in
                guard String(describing: type(of: view)) == "NativeTranscriptMark",
                      !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return false }
                let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: view).children.compactMap { child in
                    child.label.map { ($0, child.value) }
                })
                return (fields["status"] as? RowStatusKind) == .progress && (fields["symbolName"] as? String) == nil
            }
        }
        func clockRunning(_ view: NSView) -> Bool {
            Mirror(reflecting: view).children.first { $0.label == "clock" }?.value as? Timer != nil
        }
        let main = mainSpins()
        let labels = main.map { [$0.accessibilityLabel(), $0.superview?.accessibilityValue() as? String] }
        test(mainSpins().count == 4 && mainSpins().allSatisfy(moving),
             "06/07/18/19 visible initially")
        test(mark().map(clockRunning) == true, "08 clock running initially")
        for (id, spin) in [("06", side()), ("07", composer())] {
            guard let spin else { continue }
            try? image(spin)?.write(to: output.appendingPathComponent("\(id)-motion.png"))
        }
        pump(8.2)
        for (index, id) in ["06", "07", "18", "19"].enumerated() {
            let found = inspector()
            let spins = [side(), composer()] + found.map { Optional($0 as NSProgressIndicator) }
            guard found.count == 2, index < spins.count, let spin = spins[index] else {
                test(false, "\(id) fixed frame after eight seconds")
                continue
            }
            let still = image(spin)
            pump(0.11)
            let foundAgain = inspector()
            let current = [side(), composer()] + foundAgain.map { Optional($0 as NSProgressIndicator) }
            test(foundAgain.count == 2 && (current[index].map {
                staticFrame($0) && still != nil && still == image($0)
            } ?? false),
                 "\(id) fixed frame after eight seconds")
            if id == "06" || id == "07" { try? still?.write(to: output.appendingPathComponent("\(id)-fixed.png")) }
        }
        let markImage = mark().flatMap(image)
        pump(0.11)
        test(mark().map { !clockRunning($0) && markImage != nil && markImage == image($0) } == true,
             "08 clock stops and frame stays fixed after eight seconds")
        let currentLabels = mainSpins().map { [$0.accessibilityLabel(), $0.superview?.accessibilityValue() as? String] }
        test(currentLabels == labels, "AX")
        c.satellites.append(.init(id: "child-two", face: "•ᴗ•", done: true))
        app.store.changed(c)
        test(side().map(moving) == true && composer().map(moving) == true,
             "06/07 start in sub-agent count callback before the next frame")
        test(mark().map(clockRunning) == true, "08 starts in sub-agent count callback before the next frame")
        pump(8.2)
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: w.window.windowNumber, context: nil,
                                         characters: "x", charactersIgnoringModifiers: "x", isARepeat: false,
                                         keyCode: 7) else { return 2 }
        application.postEvent(key, atStart: true)
        if let event = application.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true) {
            application.sendEvent(event)
        }
        test(side().map(moving) == true && composer().map(moving) == true,
             "06/07 start in key input callback before the next frame")
        let preferences = UserDefaults.standard
        let reduceKey = "toggle.simulateReduceMotion"
        let savedReduce = preferences.object(forKey: reduceKey)
        func restoreReduce() {
            if let savedReduce { preferences.set(savedReduce, forKey: reduceKey) }
            else { preferences.removeObject(forKey: reduceKey) }
        }
        defer { restoreReduce() }
        preferences.set(true, forKey: reduceKey)
        let nc = NSWorkspace.shared.notificationCenter
        nc.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        pump(0.05)
        guard Motion.reduce else {
            print("FIXTURE reduce motion did not take")
            return 2
        }
        test(mainSpins().count == 4 && quiet(mainSpins()), "Reduce Motion stops spinners")
        restoreReduce()
        nc.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let histories = w.scene.subAgentWindows
        weak var closed: NSWindow?
        weak var releasedView: SheetSubAgentHistory?
        var historyFixtureFailed = false
        autoreleasepool {
            guard histories.present(subagentID: "child", of: c),
                  let view = histories.history(subagentID: "child"), let window = view.window else {
                test(false, "09 history opened")
                return
            }
            closed = window
            releasedView = view
            window.makeKeyAndOrderFront(nil)
            w.window.orderOut(nil)
            pump(1)
            guard window.isKeyWindow else {
                print("FIXTURE history window never became key")
                historyFixtureFailed = true
                return
            }
            test(mainSpins().count == 4 && quiet(mainSpins()), "Offscreen Normie indicators stopped")
            let spins = tree(view).compactMap { $0 as? NSProgressIndicator }.filter { !$0.isHiddenOrHasHiddenAncestor }
            test(spins.count == 2 && spins.allSatisfy(moving), "09 running in the key history window")
            pump(8.2)
            test(spins.count == 2 && spins.allSatisfy(staticFrame), "09 both controls show the fixed frame")
            window.close()
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            let idle = Mirror(reflecting: w).children.first { $0.label == "idle" }?.value as? DispatchWorkItem
            test(histories.openIDs.isEmpty && quiet(spins) && idle == nil, "09 closed history has no ambient deadline")
        }
        if historyFixtureFailed { return 2 }
        pump(0.4)
        test(closed == nil && releasedView == nil, "09 observers and registry release the closed window and view")
        c.running = false
        app.store.changed(c)
        pump(0.3)
        test((side(required: false).map { !moving($0) } ?? true) && composer()?.isHidden == true,
             "Session end hides 06/07")
        return failures == 0 ? 0 : 1
    }
}
