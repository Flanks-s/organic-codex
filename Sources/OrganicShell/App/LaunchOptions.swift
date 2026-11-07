import AppKit

struct Options {
    var display = ""
    var float = false
    /// `--inactive`: like `--float` without the floating level (captures on a test screen nobody else uses).
    var inactive = false
    var settingsPane: String?
    /// The product's initial content size (OrganicWindowController.swift:34-36).
    var width: CGFloat = 1280, height: CGFloat = 820
    var demo = false, demoInterval = 2.4
    var quitAfter: Double?
    var output: String?
    var live = true
    /// --mock: the mock conversations even on a normal launch (demos, tests and timed runs always use them).
    var mock = false
    /// --live-core: the live Core in a timed or scripted run too (to test it; windows are still neither saved nor restored).
    var liveCore = false
    /// --mock-paused: the mock, held still (no playback; the Debug panel starts paused), for frames that must not change.
    var mockPaused = false
    /// Product lab entries (--orb-lab, --transition-lab, --spring-lab, --spotlight-lab): mock only, the lab opened at launch.
    var labs: [String] = []
    var block = false
    var demoHover = false
    var demoSwap = false
    var demoCompose = false
    var demoLand = false
    var demoDrag = false
    var demoDragHeader = false
    var demoResize = false
    var demoOverlays = false
    var demoMe = false
    var demoPeek = false
    var normie = false
    var demoMode = false
    var demoModeMenu = false, demoModeKey = false
    var demoBloom = false
    var demoRefuse = false
    var demoSplit = false
    var demoCompare = false
    var demoArchive = false
    var demoWindows = false
    var demoNewChat = false
    var demoCollapse = false
    var demoCustomize = false
    var demoTear = false
    var demoInput: String?
    var demoSettings = false
    var demoTools = false
    var demoLabs = false
    var demoScrollProbe = false
    var demoDeliver = false
    var demoLiveTerminal = false
    var demoAccess = false
    var demoCollapseNew = false
    var demoModeReverse = false
    var demoTerminal = false
    var demoFullScreenCollapse = false
    var demoAudit = false
    var demoLook = false
    var demoAudit2 = false
    var demoMember = false
    var demoOrganicActions = false
    var demoLiveHooks = false
    var demoFocus = false
    var demoLiveWrite = false
    var demoPersist = false
    var demoTuning = false
    var demoAcceptance = false
    /// Debug: no ambient motion (dots, liquids, satellites), to compare the window's frame rate with and without it.
    var ambient = true
    /// Debug: planes to hide (dock, native, scene), to find what keeps the window compositing at rest.
    var hide: [String] = []
    var offscreen: String?
    var selftest: String?
    var offscreenHz = 60.0, offscreenTarget = 1

    static func parse() -> Options {
        var o = Options(), i = 1
        let a = CommandLine.arguments
        func next() -> String { i += 1; return i < a.count ? a[i] : "" }
        while i < a.count {
            switch a[i] {
            case "--display": o.display = next()
            case "--float": o.float = true
            case "--inactive": o.inactive = true
            case "--settings": o.settingsPane = next()
            case "--size":
                let p = next().split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { o.width = p[0]; o.height = p[1] }
            case "--demo": o.demo = true
            case "--demo-interval": o.demoInterval = Double(next()) ?? 2.4
            case "--quit-after": o.quitAfter = Double(next())
            case "--output": o.output = next()
            case "--no-stream": o.live = false
            case "--mock": o.mock = true
            case "--mock-paused": o.mock = true; o.mockPaused = true; o.live = false
            case "--orb-lab", "--transition-lab", "--spring-lab", "--spotlight-lab": o.mock = true; o.labs.append(a[i])
            case "--settings-tour": o.mock = true; o.demoSettings = true
            case "--live-core": o.liveCore = true
            case "--block": o.block = true
            case "--demo-hover": o.demoHover = true
            case "--demo-swap": o.demoSwap = true
            case "--demo-compose": o.demoCompose = true
            case "--demo-land": o.demoLand = true
            case "--demo-drag": o.demoDrag = true
            case "--demo-drag-header": o.demoDragHeader = true
            case "--demo-resize": o.demoResize = true
            case "--demo-overlays": o.demoOverlays = true
            case "--demo-me": o.demoMe = true
            case "--demo-peek": o.demoPeek = true
            case "--normie": o.normie = true
            case "--demo-mode": o.demoMode = true
            case "--demo-mode-menu": o.demoModeMenu = true
            case "--demo-mode-key": o.demoModeKey = true
            case "--demo-bloom": o.demoBloom = true
            case "--demo-refuse": o.demoRefuse = true
            case "--demo-split": o.demoSplit = true
            case "--demo-compare": o.demoCompare = true
            case "--demo-archive": o.demoArchive = true
            case "--demo-windows": o.demoWindows = true
            case "--demo-newchat": o.demoNewChat = true
            case "--demo-collapse": o.demoCollapse = true
            case "--demo-customize": o.demoCustomize = true
            case "--demo-tear": o.demoTear = true
            case "--demo-input": o.demoInput = next()
            case "--demo-settings": o.demoSettings = true
            case "--demo-tools": o.demoTools = true
            case "--demo-labs": o.demoLabs = true
            case "--demo-scroll-probe": o.demoScrollProbe = true
            case "--demo-deliver": o.demoDeliver = true
            case "--demo-live-terminal": o.demoLiveTerminal = true
            case "--demo-access": o.demoAccess = true
            case "--demo-collapse-new": o.demoCollapseNew = true
            case "--demo-mode-reverse": o.demoModeReverse = true
            case "--demo-terminal": o.demoTerminal = true
            case "--demo-fullscreen-collapse": o.demoFullScreenCollapse = true
            case "--demo-audit": o.demoAudit = true
            case "--demo-look": o.demoLook = true
            case "--demo-audit2": o.demoAudit2 = true
            case "--demo-member": o.demoMember = true
            case "--demo-organic-actions": o.demoOrganicActions = true
            case "--demo-live-hooks": o.demoLiveHooks = true
            case "--demo-focus-continuity": o.demoFocus = true
            case "--demo-live-write": o.demoLiveWrite = true
            case "--demo-persist": o.demoPersist = true
            case "--demo-tuning": o.demoTuning = true
            case "--demo-acceptance": o.demoAcceptance = true
            case "--no-ambient": o.ambient = false
            case "--hide": o.hide = next().split(separator: ",").map(String.init)
            case "--offscreen": o.offscreen = next()
            case "--selftest": o.selftest = next()
            case "--offscreen-hz": o.offscreenHz = Double(next()) ?? 60
            case "--offscreen-target": o.offscreenTarget = Int(next()) ?? 1
            default: break
            }
            i += 1
        }
        return o
    }

    /// A scripted run (a demo, a timed quit, a test): it neither restores nor saves the windows.
    var automated: Bool {
        // ORGANIC_PERSIST=1: a scripted run that saves and restores anyway (to test the restore itself).
        if ProcessInfo.processInfo.environment["ORGANIC_PERSIST"] == "1" { return false }
        return quitAfter != nil || demo || selftest != nil || CommandLine.arguments.contains { $0.hasPrefix("--demo") }
    }
    /// The Live Core on a normal launch, or with --live-core; never when a mock, paused mock or lab was asked for
    /// (product OrganicApplication.isDemoMode: those runs must not reach a backend).
    var usesLiveCore: Bool { !mock && (liveCore || !automated) }
}
