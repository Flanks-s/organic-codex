import AppKit
import QuartzCore

/// Standalone switch: driver-A column translation is deliberately unaffected.
enum M10IslandZoom: String {
    case accum, gauss
    static var selected: Self { Self(rawValue: ProcessInfo.processInfo.environment["M10_ISLAND_ZOOM"] ?? "accum") ?? .accum }
}
