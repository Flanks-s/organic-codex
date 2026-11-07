import AppKit
import CoreGraphics

/// What the motion system needs to know about the screen a window is on (spec §6).
struct DisplayProfile: Sendable {
    var name: String
    /// Nominal frame interval; the scene clock replaces it with the display link's measured one.
    var frameInterval: Double
    var mmPerPoint: Double
    /// Panel persistence in frames, from slow-motion footage. Recorded, not yet applied to the shutter.
    var persistenceFrames: Double

    @MainActor static func of(_ screen: NSScreen) -> DisplayProfile {
        let hz = Double(max(1, screen.maximumFramesPerSecond))
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let mm = CGDisplayScreenSize(id).width
        let perPoint = mm > 0 ? Double(mm) / Double(screen.frame.width) : 0.27
        return DisplayProfile(name: screen.localizedName, frameInterval: 1 / hz, mmPerPoint: perPoint,
                              persistenceFrames: Self.persistence(screen.localizedName))
    }

    /// 2026-10-28 slow-motion: the MBA's LCD holds 2–3 frames, the Dell U2414H about none. Others unknown.
    static func persistence(_ name: String) -> Double {
        let n = name.lowercased()
        if n.contains("u2414h") { return 0 }
        if n.contains("color lcd") && ProcessInfo.processInfo.hostName.lowercased().contains("air") { return 2.5 }
        return 0
    }

    var summary: String {
        String(format: "%@ · %.0f Hz · %.3f mm/pt · persistence %.1f f", name, 1 / frameInterval, mmPerPoint, persistenceFrames)
    }
}
