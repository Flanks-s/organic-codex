import AppKit

@MainActor private final class LegacyDaybreak: NormieView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: 4.5)).addClip()
        let glow = NSShadow()
        glow.shadowColor = NSColor(srgbRed: 1, green: 0xb3/255, blue: 0x5c/255, alpha: 0.45)
        glow.shadowBlurRadius = 3
        glow.shadowOffset = CGSize(width: 0, height: 2)
        glow.set()
        NSColor(srgbRed: 1, green: 0xc7/255, blue: 0x7a/255, alpha: 1).setStroke()
        let path = NSBezierPath(ovalIn: CGRect(x: 0.8, y: 0.8, width: 14.4, height: 14.4))
        path.lineWidth = 1.6
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor enum NormieSettingsVerification {
    static func spinnerChecks() -> [(Bool, String)] {
        func observations(_ opacity: (Int, Int) -> CGFloat, phase: Int) -> (Bool, Bool) {
            func brightest(_ value: Int) -> Int {
                (0..<12).max { opacity($0, value) < opacity($1, value) }!
            }
            let head = brightest(phase)
            let next = brightest((phase + 1) % 12)
            let behind = opacity((head + 11) % 12, phase)
            let ahead = opacity((head + 1) % 12, phase)
            return ((next - head + 12) % 12 == 1, behind > ahead)
        }
        return (0..<12).flatMap { phase in
            let old = observations({ index, step in CGFloat((index + step) % 12 + 1) / 12 }, phase: phase)
            let current = observations(NativeTranscriptMark.spokeOpacity, phase: phase)
            print("CONTROL spinner phase \(phase) old direction=\(old.0) trail=\(old.1), " +
                  "new direction=\(current.0) trail=\(current.1)")
            return [(!old.0, "old spinner direction rejected phase \(phase)"),
                    (current.0, "spinner direction phase \(phase)"),
                    (current.1, "spinner trail phase \(phase)")]
        }
    }

    static func focusChecks() -> [(Bool, String)] {
        let domain = "OrganicShell.NormieSettingsVerification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = SettingsSession(source: SettingsDemoDataSource(),
                                      preferences: SettingsPreferences(defaults: defaults))
        let workbench = NativeSettingsWorkbench(session: session)
        workbench.automaticallyLoads = false
        _ = workbench.view
        return [(workbench.table.focusRingType == .none, "settings table focus ring"),
                (workbench.sidebarScroll.focusRingType == .none, "settings scroll focus ring")]
    }

    static func daybreakChecks(to path: String) -> [(Bool, String)] {
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks: [(Bool, String)] = []
        for scale in [1, 2] {
          for old in [true, false] {
            let version = old ? "old" : "new"
            let account = NormieAccountView(frame: CGRect(x: 0, y: 0, width: 220, height: 40))
            account.account = .prototype
            account.verificationScale = CGFloat(scale)
            account.layoutSubtreeIfNeeded()
            if old {
                account.daybreak.isHidden = true
                let legacy = LegacyDaybreak(frame: CGRect(x: 192, y: 16, width: 16, height: 8))
                account.addSubview(legacy, positioned: .below, relativeTo: account.button)
            }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 220 * scale,
                                                pixelsHigh: 40 * scale, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                checks.append((false, "daybreak \(version) bitmap \(scale)x"))
                continue
            }
            bitmap.size = account.bounds.size
            if let bytes = bitmap.bitmapData { memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh) }
            account.cacheDisplay(in: account.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])
            let file = output.appendingPathComponent("daybreak-\(version)-\(scale)x.png")
            let saved = (try? png?.write(to: file)) != nil
            checks.append((saved, "daybreak \(version) PNG \(scale)x"))
            func alpha(_ x: Int, _ y: Int, inverted: Bool) -> CGFloat {
                let row = inverted ? bitmap.pixelsHigh - 1 - y : y
                return bitmap.colorAt(x: x, y: row)?.alphaComponent ?? 0
            }
            func row(_ y: Int, inverted: Bool) -> CGFloat {
                (196 * scale..<204 * scale).reduce(0) { sum, x in
                    sum + (0..<scale).reduce(CGFloat(0)) { $0 + alpha(x, y * scale + $1, inverted: inverted) }
                }
            }
            let inverted = row(16, inverted: true) > row(16, inverted: false)
            func ink(_ x: Int, _ y: Int) -> Bool {
                ((x - 1) * scale..<(x + 2) * scale).contains { px in
                    ((y - 1) * scale..<(y + 2) * scale).contains { py in
                        alpha(px, py, inverted: inverted) > 0.4
                    }
                }
            }
            if !old {
                checks.append((ink(192, 23), "daybreak left endpoint \(scale)x"))
                checks.append((ink(200, 16), "daybreak apex \(scale)x"))
                checks.append((ink(208, 23), "daybreak right endpoint \(scale)x"))
            }
            let glow = (12...15).map { row($0, inverted: inverted) }
            let fades = glow[0] > 0 && zip(glow, glow.dropFirst()).allSatisfy { pair in pair.0 < pair.1 }
            print("CONTROL daybreak \(version) \(scale)x glow=\(glow) fades=\(fades)")
            checks.append((old ? !fades : fades, "daybreak \(version) glow \(scale)x"))
          }
        }
        return checks
    }

    static func hitChecks() -> [(Bool, String)] {
        let domain = "OrganicShell.NormieSettingsHit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = SettingsPreferences(defaults: defaults)
        let session = SettingsSession(source: SettingsDemoDataSource(), preferences: preferences)
        session.prepareInitialPane("appearance")
        session.setDraft("m9.themes.all", "yes")
        session.setDraft("m9.code.all", "yes")
        let workbench = NativeSettingsWorkbench(session: session)
        workbench.automaticallyLoads = false
        workbench.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workbench.view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        workbench.render()
        workbench.view.layoutSubtreeIfNeeded()
        var checks: [(Bool, String)] = []

        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                               clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        func points(_ bounds: NSRect) -> [NSPoint] {
            [NSPoint(x: bounds.midX, y: bounds.midY), NSPoint(x: bounds.minX + 4, y: bounds.minY + 4),
             NSPoint(x: bounds.maxX - 4, y: bounds.minY + 4), NSPoint(x: bounds.minX + 4, y: bounds.maxY - 4),
             NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 4)]
        }
        func hit(_ button: NSButton, _ point: NSPoint) -> Bool {
            guard let cell = button.cell, let mouse = event(.leftMouseDown, button.convert(point, to: nil)) else {
                return false
            }
            return cell.hitTest(for: mouse, in: button.bounds, of: button).contains(.contentArea)
        }
        func checkButton(_ button: NSButton, _ name: String) {
            checks.append((button.bounds.width >= 8 && button.bounds.height >= 8, "\(name) has layout"))
            for (index, point) in points(button.bounds).enumerated() {
                checks.append((hit(button, point), "\(name) hit point \(index)"))
            }
        }

        let control = NSButton(frame: NSRect(x: 0, y: 0, width: 78, height: 68))
        control.setButtonType(.radio)
        control.title = "Ayu"
        workbench.view.addSubview(control)
        let upperY = control.isFlipped ? control.bounds.minY + 12 : control.bounds.maxY - 12
        let upperPoint = NSPoint(x: control.bounds.midX, y: upperY)
        let controlPoints = Array(points(control.bounds).dropFirst()) + [upperPoint]
        let controlHits = controlPoints.map { hit(control, $0) }
        print("CONTROL native radio hit points corners and upper: \(controlHits)")
        checks.append((controlHits.allSatisfy { !$0 }, "native short radio corners and upper exclude contentArea"))
        control.removeFromSuperview()

        for key in ["look.theme", "look.code"] {
            guard let row = workbench.form.rows.first(where: { $0.spec.id == key }) else {
                checks.append((false, "\(key) theme row exists"))
                continue
            }
            checks.append((row.spec.visual.showsAll, "\(key) Show All expanded"))
            checks.append((row.themes.count == (key == "look.theme" ? 29 : 30), "\(key) all themes"))
            for tile in row.themes { checkButton(tile, "\(key) \(tile.theme.name)") }
            for id in ["ayu", "canopy", "chatgpt"] {
                guard let tile = row.themes.first(where: { $0.theme.id == id }) else {
                    checks.append((false, "\(key) \(id) exists"))
                    continue
                }
                preferences.set(key, .string(id == "ayu" ? "canopy" : "ayu"))
                workbench.form.scrollToVisible(workbench.form.convert(tile.bounds, from: tile))
                let location = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
                guard let down = event(.leftMouseDown, location), let up = event(.leftMouseUp, location) else {
                    checks.append((false, "\(key) \(id) mouse events"))
                    continue
                }
                window.postEvent(up, atStart: false)
                window.sendEvent(down)
                if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                                inMode: .default, dequeue: true) {
                    window.sendEvent(pending)
                }
                checks.append((preferences[key].settingsText == id, "\(key) \(id) center mouse click"))
            }
        }

        let panes = ["general", "notifications", "import", "profile", "appearance", "organic", "archived",
                     "storage", "configuration", "personalization", "shortcuts", "usage", "data", "plugins",
                     "computer", "appshots", "browser", "scheduler", "connections"]
        var cards = 0
        var switches = 0
        for pane in panes {
            session.go(pane)
            workbench.render()
            workbench.view.layoutSubtreeIfNeeded()
            for row in workbench.form.rows {
                if let choices = row.control as? SettingsCardChoices {
                    choices.layoutSubtreeIfNeeded()
                    for card in choices.cards {
                        cards += 1
                        checkButton(card, "\(pane) \(row.spec.id) \(card.caption)")
                    }
                }
                if row.spec.kind == .toggle, let button = row.control as? SettingsButton {
                    switches += 1
                    checkButton(button, "\(pane) \(row.spec.id) switch")
                }
            }
        }
        checks.append((cards > 0, "choice artwork controls found: \(cards)"))
        checks.append((switches > 0, "form switches found: \(switches)"))
        return checks
    }

    static func run(_ check: String, to path: String) -> Int32 {
        let checks: [(Bool, String)]
        switch check {
        case "spinner": checks = spinnerChecks()
        case "focus": checks = focusChecks()
        case "daybreak": checks = daybreakChecks(to: path)
        case "hit": checks = hitChecks()
        default: checks = [(false, "unknown check \(check)")]
        }
        for (passed, name) in checks { print("\(passed ? "PASS" : "FAIL") \(name)") }
        let failures = checks.filter { !$0.0 }.count
        print("\(checks.count) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
