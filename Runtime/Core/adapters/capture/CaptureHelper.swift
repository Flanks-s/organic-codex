import AppKit
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Carbon

var resultFile: String?
func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    if let resultFile { try? data.write(to: URL(fileURLWithPath:resultFile), options:.atomic) }
    print(String(data: data, encoding: .utf8)!)
}

func focusedWindow(_ pid: pid_t) -> [String: Any] {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let code = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
    guard code == .success, let value else { return ["axError": code.rawValue] }
    let window = unsafeBitCast(value, to: AXUIElement.self)
    var out: [String: Any] = [:]
    for name in [kAXTitleAttribute, kAXRoleAttribute, kAXSubroleAttribute] {
        var item: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, name as CFString, &item) == .success, let item {
            out[name] = String(describing: item)
        }
    }
    var count = 0
    var lines: [String] = []
    func visit(_ node: AXUIElement, _ depth: Int) {
        guard depth < 14 && count < 500 else { return }
        count += 1
        var parts: [String] = []
        for name in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var item: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, name as CFString, &item) == .success, let item {
                if let string = item as? String, !string.isEmpty { parts.append(string) }
                else if let number = item as? NSNumber { parts.append(number.stringValue) }
            }
        }
        if !parts.isEmpty { lines.append(String(repeating: "  ", count:depth) + parts.joined(separator:" | ")) }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
            for child in list { visit(child, depth + 1) }
        }
    }
    visit(window, 0)
    out["text"] = lines.joined(separator:"\n")
    out["nodeCount"] = count
    return out
}

func runHotkey(probe: Bool) {
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: 0x4F434150, id: 1)
    let status = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
    emit(["event":"hotkeyRegistered", "status":status, "shortcut":"Control+Option+Command+S", "success":status == noErr])
    fflush(stdout)
    guard status == noErr else { exit(1) }
    if probe { if let ref { UnregisterEventHotKey(ref) }; return }
    var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        emit(["event":"captureRequested", "timeUTC":ISO8601DateFormatter().string(from:Date())])
        fflush(stdout)
        return noErr
    }, 1, &type, nil, nil)
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApplication.shared.run()
}

func inspect(selected: String? = nil) -> [String: Any] {
    let front = NSWorkspace.shared.frontmostApplication
    let app = selected.flatMap { wanted in NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == wanted || $0.bundleURL?.path == wanted || $0.localizedName == wanted } } ?? front
    var out: [String: Any] = [
        "timeUTC": ISO8601DateFormatter().string(from: Date()),
        "screenCaptureAccess": CGPreflightScreenCaptureAccess(),
        "accessibilityTrusted": AXIsProcessTrusted(),
        "displays": NSScreen.screens.map { s in ["name": s.localizedName, "frame": NSStringFromRect(s.frame), "scale": s.backingScaleFactor] }
    ]
    func appInfo(_ app: NSRunningApplication) -> [String: Any] { ["pid":app.processIdentifier,"bundleId":app.bundleIdentifier ?? "","name":app.localizedName ?? "","path":app.bundleURL?.path ?? ""] }
    if let front { out["frontmostApplication"] = appInfo(front) }
    if let app {
        out["captureApplication"] = appInfo(app)
        out["focusedWindow"] = focusedWindow(app.processIdentifier)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        out["applicationWindows"] = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }.map {
            ["id": $0[kCGWindowNumber as String] ?? 0, "title": $0[kCGWindowName as String] ?? "", "bounds": $0[kCGWindowBounds as String] ?? [:]]
        }
    }
    return out
}

@main struct CaptureHelper {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if let index = args.firstIndex(of:"--result-json"), index + 1 < args.count {
            resultFile = args[index+1]
            args.removeSubrange(index...index+1)
        }
        if args.first == "hotkey" || args.first == "hotkey-probe" { runHotkey(probe:args.first == "hotkey-probe"); return }
        var out = inspect(selected:args.first == "inspect" && args.count > 1 ? args[1] : nil)
        guard args.first == "capture" else { emit(out); return }
        guard args.count >= 3 else { emit(["error":"Usage: CaptureHelper capture screen|window OUTPUT.png [windowId]"]); exit(2) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.captureResolution = .best
            let filter: SCContentFilter
            if args[1] == "window" {
                let wanted = args.count > 3 ? UInt32(args[3]) : nil
                let front = (out["frontmostApplication"] as? [String: Any])?["pid"] as? Int32
                guard let window = content.windows.first(where: { wanted != nil ? $0.windowID == wanted : $0.owningApplication?.processID == front && $0.windowLayer == 0 }) else {
                    throw NSError(domain:"OrganicCapture", code:2, userInfo:[NSLocalizedDescriptionKey:"No requested window is currently capturable"])
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
                out["captureSource"] = ["kind":"window", "id":window.windowID, "title":window.title ?? "", "bundleId":window.owningApplication?.bundleIdentifier ?? ""]
            } else {
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    throw NSError(domain:"OrganicCapture", code:3, userInfo:[NSLocalizedDescriptionKey:"No display is available"])
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
                out["captureSource"] = ["kind":"screen", "displayId": display.displayID]
            }
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            let image = try await SCScreenshotManager.captureImage(contentFilter:filter, configuration:config)
            let url = URL(fileURLWithPath:args[2])
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw NSError(domain:"OrganicCapture",code:4,userInfo:[NSLocalizedDescriptionKey:"Cannot create output image"])
            }
            CGImageDestinationAddImage(dest,image,nil)
            guard CGImageDestinationFinalize(dest) else { throw NSError(domain:"OrganicCapture",code:5,userInfo:[NSLocalizedDescriptionKey:"Image write failed"]) }
            out["image"] = ["path":url.path,"width":image.width,"height":image.height,"mimeType":"image/png"]
            out["success"] = true
            emit(out)
        } catch {
            let e = error as NSError
            out["success"] = false
            out["error"] = ["domain": e.domain,"code":e.code,"message":e.localizedDescription]
            emit(out)
            exit(1)
        }
    }
}
