import AppKit

/// Value input only. No dependency on Core, Organic, Native, or the product's module.
enum OrbContent: Equatable {
    case identity(OrbIdentity)
    /// Product New Chat: fixed jade liquid, no identity, no ambient wobble.
    case seed
    case me(initials: String, quota: OrbQuota)
}

struct OrbQuota: Equatable {
    /// Fractions USED, not remaining. nil means not reported; zero is a reported empty limit.
    var primaryUsed: Double?
    var secondaryUsed: Double?
    var primaryResetsAt:Date?,secondaryResetsAt:Date?
    var primaryWindowMinutes:Int?=300,secondaryWindowMinutes:Int?=10_080
    var primaryTitle:String { Self.title(minutes:primaryWindowMinutes,fallback:"Primary limit") }
    var secondaryTitle:String { Self.title(minutes:secondaryWindowMinutes,fallback:"Secondary limit") }
    private static func title(minutes:Int?,fallback:String)->String {
        guard let minutes,minutes>0 else { return fallback }
        if minutes == 10_080 { return "Weekly limit" }; if minutes%60 == 0 { return "\(minutes/60)-hour limit" }; return "\(minutes)-minute limit"
    }
    var tightestUsed: Double? {
        [primaryUsed, secondaryUsed].compactMap { $0 }.filter(\.isFinite)
            .map { min(1, max(0, $0)) }.max()
    }
    var summary: String {
        guard let used = tightestUsed else { return "Usage not reported" }
        let remaining = Int(((1 - used) * 100).rounded())
        let both=primaryUsed?.isFinite == true && secondaryUsed?.isFinite == true
        return both ? "\(remaining)% left" : "\(remaining)% left in reported limit"
    }
}

struct OrbBadge: Equatable {
    enum Tone: Int, Comparable {
        case green, yellow, red
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    enum Symbol: Equatable {
        case count(Int), question, error, stopped
        var text: String {
            switch self {
            case .count(let n): n > 99 ? "99+" : "\(max(0, n))"
            case .question: "?"
            case .error: "!"
            case .stopped: "x_x"
            }
        }
    }
    enum ErrorState { case running, stopped }
    var tone: Tone
    var symbol: Symbol

    /// The resolver is also used by the Core adapter described in ORB-PORT-26102807.md.
    static func resolve(error: ErrorState?, approvals: Int, question: Bool, completions: Int) -> Self? {
        if let error { return Self(tone: .red, symbol: error == .running ? .error : .stopped) }
        if approvals > 0 { return Self(tone: .yellow, symbol: .count(approvals)) }
        if question { return Self(tone: .yellow, symbol: .question) }
        if completions > 0 { return Self(tone: .green, symbol: .count(completions)) }
        return nil
    }
}

struct OrbSatellite: Equatable {
    var id: String
    var face: String
    var pace: Double = 0
    var done = false
    var finishedOrder: Int?
}

enum OrbSatelliteMode: Equatable {
    case orbit
    /// Running then finished rows, below the orb; finishedOrder is stable across updates.
    case rows
    /// Points relative to the orb centre, y down. Used while a scene supplies moving row endpoints.
    case follow([String: CGPoint])
}
struct OrbOrbitShape:Equatable {
    var diameter:CGFloat,radius:CGFloat,flatten:Double,tiltDegrees:Double
    static func header(_ size:CGFloat)->Self {
        let radius=size/2+10
        return .init(diameter:12,radius:radius,flatten:16/Double(radius),tiltDegrees:-18)
    }
    func scaled(by factor:CGFloat)->Self { .init(diameter:diameter*factor,radius:radius*factor,flatten:flatten,tiltDegrees:tiltDegrees) }
}

struct OrbConfiguration: Equatable {
    enum Appearance:Equatable { case dark,light }
    var content: OrbContent
    /// Endpoint coordinates. Hover MUST keep this constant and call setFrame instead.
    var drawingSize: CGFloat
    var context: Double = 0
    var identityLiquid = true
    var running = false
    /// A live event advances this value once. Appearance, geometry and history never replay it.
    var activitySerial: UInt64 = 0
    var badge: OrbBadge?
    var satellites: [OrbSatellite] = []
    var satellitesRetired = false
    var satelliteMode: OrbSatelliteMode = .orbit
    /// Header row uses a 16pt face and keeps overflow clocks retained but hidden. nil preserves Dock sizing.
    var satelliteDiameter: CGFloat?
    var satelliteVisibleIDs: Set<String>?
    var orbitShape:OrbOrbitShape?
    var satelliteAccent:NSColor?
    var satelliteFollowStagger:Double=0.02
    var compactions = 0
    var completions = 0
    var redEvents = 0
    var redUnseen = false
    var reduceMotion = false
    /// False while the window is invisible or idle. Holds ambient clocks; semantic badge presence settles immediately.
    var ambient = true
    var isKeyWindow = true
    /// Configure on backing changes, never on each geometry sample. Text has 2× magnification headroom.
    var backingScale: CGFloat = 2
    var appearance:Appearance = .dark

    var liquidLevel: Double? {
        switch content {
        case .seed: 0.12
        case .identity: identityLiquid ? (context.isFinite ? min(1, max(0, context)) : nil) : 0
        case .me(_, let quota): quota.tightestUsed
        }
    }
}

/// Counters measure the actual drawing functions and NSView.layout callbacks, not estimates.
struct OrbDrawingMetrics: Equatable {
    var configurations = 0
    var geometryCalls = 0
    var layoutCalls = 0
    var glyphPaths = 0
    var liquidPaths = 0
    var badgePaths = 0
    var glowPaths = 0
    var orbitBuilds = 0
    var textLayouts = 0
}

final class OrbMetrics {
    var value = OrbDrawingMetrics()
}
