import AppKit
import QuartzCore
import ImageIO

@main @MainActor enum FunctionPanelOverlayCheck {
    static var checks = 0, failures: [String] = [], frames: [String] = []
    static func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value {
            failures.append(name)
            print("FAIL: " + name)
        }
    }
    static func event(_ type: NSEvent.EventType, point: CGPoint, host: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: host.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                               pressure: 0)!
    }
    static func key() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false,
                             keyCode: 48)!
    }
    static func wheel() -> NSEvent {
        NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 8, wheel2: 0,
                wheel3: 0)!)!
    }
    /// A hidden window's own caching rep follows its backing scale, not the requested export scale.
    /// Render directly into the target rep, then copy its pixels; never enlarge a captured bitmap.
    static func capture(_ host: NSView, scale: Int) -> CGImage {
        let width = Int(host.bounds.width) * scale, height = Int(host.bounds.height) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = host.bounds.size
        if let bytes = rep.bitmapData { memset(bytes, 0, rep.bytesPerRow * rep.pixelsHigh) }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = rep.cgImage!, space = image.colorSpace!
        let copy = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        copy.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return copy.makeImage()!
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = output.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scale in [1, 2] { for split in [false, true] {
            let tag = "\(split ? "split" : "narrow-column").\(scale)"
            let host = FunctionPanelOverlayMockHost(split: split, scale: scale)
            let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            let original = host.neighbours.first { host.covered.contains($0.originalFrame) }!
            check(window.makeFirstResponder(original), "overlay.initial-focus." + tag)
            let originals = host.neighbours.map(\.originalFrame)
            host.present()
            let until = CACurrentMediaTime() + 10
            while (host.owner.currentPicture?.quality != .panelHD || host.owner.hasPendingWork) && CACurrentMediaTime(
                ) < until { try? await Task.sleep(for: .milliseconds(10)) }
            check(host.owner.currentPicture?.quality == .panelHD, "overlay.real-HD." + tag)
            check(host.covered.width == 598 && host.covered.minX >= 0 && host.covered.maxX <= host.bounds.maxX,
                "overlay.geometry-598." + tag)
            check(!window.isVisible && !window.isKeyWindow, "overlay.never-order-window." + tag)
            check(host.stage.input == FunctionPanelFixtures.input(), "overlay.same-data." + tag)
            let neighbourCount = host.neighbours.reduce(0) { $0 + $1.received.count }
            // Grid includes empty ink, gaps and both boundaries; AppKit hit testing must shield every point.
            for x in stride(from: host.covered.minX + 1, to: host.covered.maxX, by: 31) {
                for y in stride(from: CGFloat(33), to: host.covered.maxY, by: 37) {
                    let hit = host.hit(at: CGPoint(x: x, y: y))
                    check(hit === host.shield || hit?.isDescendant(of: host.shield) == true,
                        "overlay.no-passthrough.grid." + tag)
                }
            }
            // A blank point exercises click, hover, wheel and a captured drag without triggering panel actions.
            let inside = CGPoint(x: host.covered.maxX - 4, y: host.covered.maxY - 4)
            for type: NSEvent.EventType in [.leftMouseDown, .mouseMoved, .leftMouseDragged, .leftMouseUp] {
                let target = host.dispatch(event(type, point: inside, host: host))
                check(target === host.shield, "overlay.no-passthrough.native-\(type.rawValue)." + tag)
            }
            check(host.dispatch(wheel(), at: inside) === host.shield, "overlay.no-passthrough.native-wheel." + tag)
            check(host.shield.received.count == 5 && host.neighbours.reduce(0) {
                    $0 + $1.received.count } == neighbourCount,
                  "overlay.no-passthrough.receivers." + tag)
            let screenCover = window.convertToScreen(host.convert(host.covered, to: nil))
            check(host.accessibilityHitTest(window.convertPoint(toScreen: host.convert(inside,
                        to: nil))) as? NSView === host.stage,
                  "overlay.ax-native-hit." + tag)
            let children = host.accessibilityChildren()!.compactMap { $0 as? FunctionPanelNeighbourProbe }
            check(children.count == host.neighbours.filter { !$0.isHidden }.count, "overlay.ax-children." + tag)
            for cell in host.neighbours {
                check(cell.isHidden || !cell.frame.intersects(host.covered), "overlay.ax-clipped-frame." + tag)
                check(cell.isHidden ? cell.accessibilityFrame().isEmpty : !cell.accessibilityFrame().intersects(
                        screenCover), "overlay.ax-screen-frame." + tag)
                check(cell.isHidden ? !cell.isAccessibilityElement() && !cell.acceptsFirstResponder : cell
                    .isAccessibilityElement(), "overlay.ax-covered-hidden." + tag)
                check(!cell.isHidden || !host.neighbourTabStops.contains(where: { $0 === cell }),
                    "overlay.tab-covered-excluded." + tag)
            }
            let below = host.neighbours.last!
            let belowPoint = CGPoint(x: below.frame.midX, y: below.frame.midY)
            check(host.dispatch(event(.leftMouseDown, point: belowPoint, host: host)) === below,
                "overlay.outside-below-stage." + tag)
            _ = host.dispatch(event(.leftMouseUp, point: belowPoint, host: host))
            host.stage.focus("orb")
            for _ in 0..<(host.stage.visibleButtonIDs.count + 2) {
                window.firstResponder?.keyDown(with: key())
                check(window.firstResponder is FunctionPanelButton, "overlay.tab-native-contained." + tag)
            }
            if let exposed = host.neighbours.first(where: { !$0.isHidden }) {
                let outside = CGPoint(x: exposed.frame.midX, y: exposed.frame.midY)
                for type: NSEvent.EventType in [.leftMouseDown, .mouseMoved, .leftMouseDragged, .leftMouseUp] {
                    check(host.dispatch(event(type, point: outside, host: host)) === exposed,
                        "overlay.outside-native-\(type.rawValue)." + tag)
                }
                check(host.dispatch(wheel(), at: outside) === exposed && exposed.received.count == 5,
                    "overlay.outside-native-wheel." + tag)
                _ = host.dispatch(event(.leftMouseDown, point: outside, host: host))
                let beforeDrag = exposed.received.count
                check(host.dispatch(event(.leftMouseDragged, point: inside,
                            host: host)) === host.shield && exposed.received.count == beforeDrag,
                      "overlay.no-passthrough.drag-cross-in." + tag)
                check(host.dispatch(event(.leftMouseUp, point: inside, host: host)) === host.shield,
                    "overlay.no-passthrough.drag-end." + tag)
            } else { check(false, "overlay.outside-present." + tag) }
            if !CommandLine.arguments.contains("--no-frames") {
                let image = capture(host, scale: scale)
                check(image.width == 960 * scale && image.height == 852 * scale, "overlay.PNG-native-size." + tag)
                let name = "\(split ? "split-right" : "narrow-column")-\(scale)x.png"
                let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,
                    "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                check(CGImageDestinationFinalize(destination), "overlay.PNG." + tag)
                frames.append(name)
            }
            host.dismiss()
            check(window.firstResponder === original, "overlay.restore-focus." + tag)
            check(host.neighbours.map(\.frame) == originals && host.neighbourTabStops.count == host.neighbours.count,
                "overlay.restore-geometry-tab." + tag)
            check(host.accessibilityChildren()!.count == host.neighbours.count && host.neighbours.allSatisfy {
                    $0.isAccessibilityElement() }, "overlay.restore-AX." + tag)
            for cell in host.neighbours {
                check(host.hit(at: CGPoint(x: cell.frame.midX, y: cell.frame.midY)) === cell,
                    "overlay.restore-hit." + tag)
            }
            let fence = CACurrentMediaTime() + 2
            while host.owner.resources.hdReservedBytes != 0 && CACurrentMediaTime() < fence {
                try? await Task.sleep(for: .milliseconds(10)) }
            check(host.owner.resources.hdReservedBytes == 0, "overlay.release-HD." + tag)
            check(!window.isVisible, "overlay.no-desktop-window." + tag)
            window.contentView = nil; window.close()
        } }
        let report: [String: Any] = ["checks": checks, "failures": failures, "frames": frames,
            "visibleWindows": NSApp.windows.filter(\.isVisible).count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,
                .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        print("\(checks) overlay checks, \(failures.count) failures, \(frames.count) frames")
        exit(failures.isEmpty ? 0 : 1)
    }
}
