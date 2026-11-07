import AppKit

/// Visual tokens for the first scene, from docs/reference/AUTO-DOCK-REFERENCE-26102804.md (Sol, sections A, D, E, F),
/// which cites the product source for each value.
@MainActor enum Look {
    // Dark mode only for now (user, 2026-10-28), like the product. Light mode is not being developed.
    /// The product uses NSColor.textBackgroundColor; Canopy's dark token is about #1e1e1e.
    static let canvas = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
    /// Washes (Canopy.swift:30-51), dark: moss from the top right (alpha 0.13, radius 0.75 × max side),
    /// teal from the bottom left (0.10, 0.80).
    static let moss = NSColor(srgbRed: 0x57 / 255, green: 0xC2 / 255, blue: 0x7A / 255, alpha: 1)
    static let teal = NSColor(srgbRed: 0x3B / 255, green: 0xAF / 255, blue: 0xC2 / 255, alpha: 1)
    static let mossAlpha = 0.13, tealAlpha = 0.10
    /// The canvas and its two washes for the current Settings ▸ Appearance (CanopyCanvas): a theme of its own takes its
    /// background, washed with its accent (0.15) and its wash colour (0.11); Canopy keeps moss and teal.
    static var themedCanvas: (canvas: NSColor, washes: [(NSColor, CGFloat)]) {
        let look = NativeAppearance.current
        guard let background = look.background else { return (canvas, [(moss, mossAlpha), (teal, tealAlpha)]) }
        return (background, [(look.accentColor, 0.15), (look.wash ?? teal, 0.11)])
    }
    /// Increase Contrast or Reduce Transparency: the canvas without its moss and teal washes (CanopyCanvas,
    /// Canopy.swift:46; f201).
    static var plainCanvas: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    /// Label colours, dark calibration: white 0.85 / 0.55 / 0.25; a theme's foreground at its label levels when it
    /// has one (the native render packet's palette; organic audit B21). Read at layout, so a new look re-renders them.
    static var ink: NSColor { NativeAppearance.current.foreground == nil ? NSColor(white: 1, alpha: 0.85) : NativeAppearance.current.label }
    static var secondary: NSColor { NativeAppearance.current.foreground == nil ? NSColor(white: 1, alpha: 0.55) : NativeAppearance.current.secondary }
    static var tertiary: NSColor { NativeAppearance.current.foreground == nil ? NSColor(white: 1, alpha: 0.25) : NativeAppearance.current.tertiary }
    /// Full-bleed column separators: label × 0.1, one backing pixel wide.
    static let separator = NSColor(white: 1, alpha: 0.1)
    static let bubble = NSColor(white: 1, alpha: 0.07)
    static let code = NSColor(white: 1, alpha: 0.05)
    static let capsule = NSColor(white: 1, alpha: 0.08)
    /// Resolve before assigning to NSGlassEffectView: a detached Dock's default drawing appearance is Aqua.
    /// Product OrganicDockProjection resolves windowBackgroundColor under its dark scene.
    static var peekTint: NSColor {
        var color = NSColor.windowBackgroundColor
        (NativeDisplayOptions.appearance ?? NSAppearance(named: .darkAqua)!).performAsCurrentDrawingAppearance {
            color = (NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .darkGray).withAlphaComponent(0.55)
        }
        return color
    }

    // Header (ColumnHeader.swift:21-33 under full bleed, t = 44): full | brief.
    static let planet: (full: CGFloat, brief: CGFloat) = (56, 44)
    static let avatarTop: (full: CGFloat, brief: CGFloat) = (52, 56)
    static let capsuleTop: (full: CGFloat, brief: CGFloat) = (104, 96)
    static let capsuleHeight: (full: CGFloat, brief: CGFloat) = (32, 28)
    static let contentTop: (full: CGFloat, brief: CGFloat) = (156, 144)

    // Line heights are whole points (Canopy's calibration is ~19.4 / 18.6), so layouts stay on the pixel grid
    // and a flight's first and last frames match the text at rest exactly.
    static var user: TextStyle { TextStyle(font: .systemFont(ofSize: 13), color: ink, lineHeight: 19) }
    static var body: TextStyle { TextStyle(font: .systemFont(ofSize: 13), color: ink, lineHeight: 21) }
    static var reasoning: TextStyle { TextStyle(font: .systemFont(ofSize: 12), color: secondary, lineHeight: 19) }
    static var mono: TextStyle { TextStyle(font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: secondary, lineHeight: 15) }
    static var activity: TextStyle { TextStyle(font: .systemFont(ofSize: 12, weight: .semibold), color: secondary, lineHeight: 17) }
    static var headerTitle: TextStyle { TextStyle(font: .systemFont(ofSize: 13, weight: .medium), color: ink, lineHeight: 18) }
    /// The brief's small notes, "Goal" and "Worked for …": 11 medium, tertiary (NativeMorphRenderPacket.swift:229-243).
    static var briefNote: TextStyle { TextStyle(font: .systemFont(ofSize: 11, weight: .medium), color: tertiary, lineHeight: 14) }
    /// How a brief retells a conversation (Settings ▸ Organic, `toggle.playfulSummaries`): Playful (the default) or Plain.
    static var playful: Bool { UserDefaults.standard.object(forKey: "toggle.playfulSummaries") as? Bool ?? true }
    /// A brief line older than the latest one, at rest (ColumnMorphMath.swift:107-109; hover lifts it to 0.62).
    static let olderLine: Float = 0.34

    /// The brief's goal: system bold, round(clamp(width × 0.068, 17, 24)), tracking −0.01 × size, right aligned.
    static func lyric(columnWidth w: CGFloat) -> TextStyle {
        let size = (w * 0.068).clamped(17, 24).rounded()
        return TextStyle(font: .systemFont(ofSize: size, weight: .bold), color: ink, lineHeight: ceil(size * 1.22), kern: -0.01 * size)
    }

    /// Identity colours (dark) for Mercury … Saturn, the six default members (fixture mockMembers.identityDark).
    static let identity: [NSColor] = [
        NSColor(srgbRed: 0.7412, green: 0.7176, blue: 0.6902, alpha: 1),
        NSColor(srgbRed: 0.9412, green: 0.7255, blue: 0.5412, alpha: 1),
        NSColor(srgbRed: 0.3647, green: 0.7059, blue: 0.9412, alpha: 1),
        NSColor(srgbRed: 0.9490, green: 0.4510, blue: 0.3020, alpha: 1),
        NSColor(srgbRed: 0.8863, green: 0.6588, blue: 0.4314, alpha: 1),
        NSColor(srgbRed: 0.9098, green: 0.7686, blue: 0.3529, alpha: 1),
    ]
}

/// Motion constants. Auto columns, forms and dock endpoints: 0.42 / 0.86 (Tuning.swift:102-105).
enum Motion {
    static let response = 0.42, damping = 0.86
    /// Reduce Motion: the system's, or Settings' preview of it (`toggle.simulateReduceMotion`, f199).
    @MainActor static var reduce: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "toggle.simulateReduceMotion")
    }
}
