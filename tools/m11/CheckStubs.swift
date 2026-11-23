// Compile-only stand-ins for tools/m11/m11-1-check.sh (infra lane, Claude, 2026-11-08).
//
// Why it is safe: the check package links App/SelfTest.swift, and SelfTest's Orb retained-control checks
// (Orb/OrbRetainedControlVerification.swift, Orb/OrbInvisibleAnimationVerification.swift) build a production
// SettingsButton. M111Check (tools/m11/m11-1-check.swift) only calls ModeRegressionChecks and never calls SelfTest or
// those Orb checks, so nothing here runs. The Settings group itself is not linked: it drags in the App layer and its
// @main. The real SettingsButton lives in Sources/OrganicShell/Settings/SettingsControls.swift and is what the app's
// own selftest exercises.
//
// Guard: if anything in the check ever builds this stand-in, the check stops at once (precondition failure), so a
// stand-in can never pass for the production control.
import AppKit

@MainActor class SettingsButton: NSButton {
    enum Style { case plain, toggle, popup, shortcut, tile, checkbox }
    var style = Style.plain
    var recordingShortcut = false

    override init(frame frameRect: NSRect) {
        preconditionFailure("tools/m11/CheckStubs.swift: the compile-only SettingsButton stand-in was used; "
            + "this check must not run SelfTest's Orb checks (link the real Settings group instead)")
    }

    required init?(coder: NSCoder) {
        preconditionFailure("tools/m11/CheckStubs.swift: the compile-only SettingsButton stand-in was used")
    }
}
