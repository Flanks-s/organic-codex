import AppKit

/// Explicit real-window fixture. It owns a test store and never starts a Core connection.
@MainActor enum RichBriefVerification {
    static func run(to path: String) -> Int32 {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("check.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try! FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }) else {
            try? log.write(contentsOf: Data("FAIL: built-in display unavailable\n".utf8))
            return 81
        }
        let suite = "OrganicShell.RichBriefVerification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = Options()
        options.mock = true
        options.live = false
        options.quitAfter = 30
        let controller = AppController(options, windowDefaults: defaults, presentsWindows: false)
        func make(_ id: String, _ title: String, _ items: [TranscriptItem]) -> Conversation {
            let conversation = Conversation(id: id, title: title)
            conversation.items = items
            return conversation
        }
        let first = make("fixture-a", "Workspace", [
            .init(id: "a-user", turnID: "a", kind: .user, text: "Check the workspace layout."),
            .init(id: "a-answer", turnID: "a", kind: .assistant, text: "The workspace is ready to review."),
        ])
        let specimen = make("fixture-b", "File references", [
            .init(id: "b-user", turnID: "b", kind: .user, text: "Review the two files."),
            .init(id: "b-thought", turnID: "b", kind: .reasoning, text: "I will inspect both source files."),
            .init(id: "b-first", turnID: "b", kind: .assistant,
                  text: "Inspect [ColumnMath.swift](native/Specimen/ColumnMath.swift:18)."),
            .init(id: "b-second", turnID: "b", kind: .assistant,
                  text: "Review [SidebarView.swift](native/SidebarView.swift:42)."),
        ])
        let third = make("fixture-c", "Review notes", [
            .init(id: "c-user", turnID: "c", kind: .user, text: "Summarize the review."),
            .init(id: "c-answer", turnID: "c", kind: .assistant, text: "The review notes are ready."),
        ])
        for (index, conversation) in [first, specimen, third].enumerated() {
            conversation.identityIndex = index
            controller.store.add(conversation)
        }
        RichBriefProjection.enabledOverride = true
        defer { RichBriefProjection.enabledOverride = nil }
        let area = screen.visibleFrame
        let size = CGSize(width: min(1280, area.width - 40), height: min(820, area.height - 40))
        let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                           width: size.width, height: size.height)
        let host = OrganicWindow(app: controller, frame: frame, screen: screen,
                                 members: [first.id, specimen.id, third.id], normie: false, o: options)
        controller.windows = [host]
        host.show(focus: false)
        NSApp.activate(ignoringOtherApps: true)
        let start = Date()
        func write(_ message: String) {
            let elapsed = Date().timeIntervalSince(start)
            let line = String(format: "%.3f %@\n", elapsed, message)
            try? log.write(contentsOf: Data(line.utf8))
            print(line, terminator: "")
        }
        func wait(until seconds: TimeInterval) {
            while Date().timeIntervalSince(start) < seconds {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }
        defer { host.window.close() }
        write("window opened")
        guard host.scene.columns.count == 3,
              let column = host.scene.columns.first(where: { $0.conversation === specimen }), !column.isFull else {
            write("FAIL: expected three columns with the fixture in brief")
            return 1
        }
        func currentCoverReady() -> Bool {
            guard column.coverVersion > 0, let widths = column.displayWidths else { return false }
            let summary = column.boundedSummary(columnWidth: widths.brief)
            let layout = column.modeBrief(summary, width: max(60, widths.brief - 40), columnWidth: widths.brief)
            return layout.parts.contains { $0.kind == .cover && $0.current && $0.image != nil }
        }
        while Date().timeIntervalSince(start) < 5 && !currentCoverReady() {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard currentCoverReady() else {
            write("FAIL: current cover did not publish within 5 seconds")
            return 1
        }
        write("current cover ready; version=\(column.coverVersion)")
        wait(until: 12)
        var resized = host.window.frame
        resized.size.width -= 200
        host.window.setFrame(resized, display: true)
        write("window width reduced by 200 pt")
        wait(until: 18)
        host.shell.setMode(.normie)
        write("setMode normie")
        wait(until: 22)
        host.shell.setMode(.organic)
        write("setMode organic")
        wait(until: 30)
        write("PASS: timeline complete")
        return 0
    }
}
