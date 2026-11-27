import Foundation

enum FunctionPanelScenario: String, CaseIterable {
    case overview = "Overview", customize = "自定义", subagents = "子智能体", hover = "悬停展开"
    case library = "Library", files = "Files", background = "Background", outputs = "Outputs"
    var page: FunctionPanelPage {
        switch self {
        case .overview, .customize, .subagents, .hover: .overview
        case .library: .library
        case .files: .files
        case .background: .background
        case .outputs: .outputs
        }
    }
    var fileKey: String {
        switch self {
        case .customize: "customize"
        case .subagents: "subagents"
        case .hover: "hover"
        default: page.rawValue.lowercased()
        }
    }
}

enum FunctionPanelFixtureState: String, CaseIterable {
    case unloaded = "Not loaded", loading = "Loading", known = "Known", unavailable = "Not provided", failed = "Failed"
    func project<T: Equatable & Sendable>(_ value: T) -> FunctionPanelValue<T> {
        switch self {
        case .unloaded: .unloaded
        case .loading: .loading
        case .known: .known(value)
        case .unavailable: .unavailable
        case .failed: .failed("Fixture failure")
        }
    }
}

enum FunctionPanelCollectionMode: String, CaseIterable { case normal = "Normal", empty = "Empty", many = "Many" }

/// Fixed authored sample values. There is no random seed, simulated clock or product resource dependency.
enum FunctionPanelFixtures {
    private static func lines(index: Int, many: Bool) -> [String] {
        let names = ["Metric auditor", "Snapshot runner", "Title checker", "Toolbar auditor", "Layout runner",
            "Copy reviewer", "Contrast checker"]
        let files = ["SidebarStyle.swift", "SidebarSnapshotTests.swift", "ProfileCapsule.swift", "Toolbar.swift",
            "Layout.swift", "Strings.swift", "Contrast.swift"]
        let previous = ["Both row insets now share Metrics", "Wide 2x passed; narrow 1x is next",
            "The profile title clears by 12", "Toolbar padding matches the list", "The split layout keeps its gutter",
            "The approval copy uses one verb", "The label contrast is above target"]
        let latest = ["28 pt is the final system row", "Eight snapshots are ready to compare",
            "No title clips in the narrow column", "The icon and title align at the top",
            "No overlap in the right column", "No duplicate label remains", "The quiet text stays readable"]
        let i = index % names.count
        return (many ? (1...8).map { "\(names[i]) check \($0): read the metrics"
        } : []) + ["Compare \(names[i].lowercased()) results", "Reading \(files[i])", previous[i], latest[i]]
    }
    static let bodies: [FunctionPanelBodyOption] = [
        "Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune", "Pluto",
        "Ceres", "Pallas", "Juno", "Vesta", "Astraea", "Hygiea", "Chiron", "Pholus",
        "Nessus", "Orcus", "Haumea", "Quaoar", "Makemake", "Gonggong", "Eris", "Sedna"
    ].map { .init(id: $0.lowercased(), name: $0) }

    static func input(state: FunctionPanelFixtureState = .known, subagentCount: Int = 3,
                      empty: Bool = false, many: Bool = false, reversedAgents: Bool = false) -> FunctionPanelInput {
        let colours: [FunctionPanelColour] = [
            .init(id: "silver", name: "Silver", bodyName: "Mercury", hex: 0xbdb7b0),
            .init(id: "peach", name: "Peach", bodyName: "Venus", hex: 0xf0b98a),
            .init(id: "sky", name: "Sky Blue", bodyName: "Earth", hex: 0x5db4f0),
            .init(id: "coral", name: "Coral", bodyName: "Mars", hex: 0xf2734d),
            .init(id: "caramel", name: "Caramel", bodyName: "Jupiter", hex: 0xe2a86e),
            .init(id: "gold", name: "Gold", bodyName: "Saturn", hex: 0xe8c45a),
            .init(id: "turquoise", name: "Turquoise", bodyName: "Uranus", hex: 0x7ed6c8),
            .init(id: "cornflower", name: "Cornflower", bodyName: "Neptune", hex: 0x7f9bf5),
            .init(id: "lavender", name: "Lavender", bodyName: "Pluto", hex: 0xc39bf0)
        ]
        let agentNames = ["Metric auditor", "Snapshot runner", "Title checker", "Toolbar auditor", "Layout runner",
            "Copy reviewer", "Contrast checker"]
        var agents = (0..<max(0, subagentCount)).map { index in
            FunctionPanelSubagent(id: "agent-\(index)", name: agentNames[index % agentNames.count],
                                  status: index == 2 ? "Finished" : "Running", elapsed: .known(["3m 05s", "1m 42s",
                                          "52s"][index % 3]),
                                  lines: lines(index: index, many: many), canStop: index != 2)
        }
        if reversedAgents { agents.reverse() }
        let coverNames = ["sidebar-after.png", "HIG-sidebars.pdf", "Row metrics table", "Metrics.swift",
            "Row height chart", "narrow-window.png", "Density audit.pdf", "profile-capsule.png", "Layout pass diagram"]
        let coverKinds: [FunctionPanelCover.Kind] = [.image, .pdf, .artifact, .artifact, .artifact, .image, .pdf,
            .image, .artifact]
        let coverColours: [UInt32] = [0x2f343a, 0x3a3f46, 0x274a63, 0x2d2f3b, 0x1f4730, 0x44372d, 0x4c3b28, 0x48302e,
            0x2d3e52]
        let covers = (0..<(empty ? 0 : many ? 30 : 9)).map { index in
            FunctionPanelCover(id: "cover-\(index)", name: coverNames[index % 9] + (index > 8 ? " \(index)" : ""),
                               kind: coverKinds[index % 9],
                               metadata: .known(coverKinds[
                                       index % 9] == .pdf ? "PDF · 14 pages · fixture" : coverKinds[index % 9
                                   ] == .image ? "1280 × 820 · Turn 4 · fixture" : "Artifact · Turn 3 · fixture"),
                               step: ["Captured the sidebar after the pass", "Read the sidebar guidelines",
                                   "Tabulated row metrics"][index % 3],
                               lyric: ["This is the sidebar now", "28 pt is the system row",
                                   "Every metric in one table"][index % 3], colour: coverColours[index % 9])
        }
        let fileNames = ["Tests/SidebarSnapshotTests.swift", "native/Sidebar/SidebarStyle.swift",
            "docs/HIG-sidebars.md", "native/Design/Metrics.swift", "native/Sidebar/ProfileCapsule.swift",
            "native/Sidebar/SidebarView.swift", "native/Sidebar/SidebarRow.swift"]
        let files = (0..<(empty ? 0 : 7)).map { index in
            FunctionPanelFile(id: "file-\(index)", path: fileNames[index],
                              additions: index < 3 ? .unavailable : .known([18, 6, 1, 18][index - 3]),
                              removals: index < 3 ? .unavailable : .known([2, 2, 1, 9][index - 3]),
                              provenance: index < 3 ? "Referenced · fixture" : "Changed in this conversation · fixture",
                              lines: index < 3 ? ["Read the system sidebar guidelines.",
                                  "Keep the profile capsule clear of the list."] : [
                                  "  HStack(spacing: Metrics.rowGap) {", "−   Image(systemName: icon).frame(width: 18)",
                                  "+   Image(systemName: icon).frame(width: 16)", "    Text(title).lineLimit(1)", "  }",
                                  "− .frame(height: 32)", "+ .frame(height: Metrics.rowHeight)"])
        }
        let tasks: [FunctionPanelTask] = empty ? [] : [
            .init(id: "tests", command: "swift test --filter SidebarSnapshot",
                status: "Running", progress: .known(0.64), elapsed: .known("01:12"),
                log: "testWide2x passed\ntestWide1x passed\ntestNarrow2x started", action: "Stop"),
            .init(id: "archive", command: "xcodebuild -scheme Organic archive",
                status: "Running", progress: .known(0.22), elapsed: .known("03:40"), log:
                "CompileSwift SidebarRow.swift\nCompileSwift Metrics.swift\nLd Organic normal arm64", action: "Stop"),
            .init(id: "build", command: "swift build", status: "Finished", progress: .unavailable,
                elapsed: .known("48s"), log: "Build complete", action: "Copy log"),
            .init(id: "search", command: "rg -n rowInsets native/", status: "Finished", progress: .unavailable,
                elapsed: .known("1s"), log: "SidebarRow.swift: customInset", action: "Copy log"),
            .init(id: "tail", command: "tail -f build.log", status: "Stopped by you", progress: .unavailable,
                elapsed: .known("5m"), log: "", action: "Restart")
        ]
        let outputNames = ["Sidebar density patch", "PR description", "Snapshot report", "sidebar-after.png",
            "Density notes"]
        let outputs = (0..<(empty ? 0 : 5)).map { index in
            FunctionPanelOutput(id: "output-\(index)", name: outputNames[index],
                metadata: .known(["Diff · 4 files · +43 −14", "Markdown · 18 lines", "HTML · 8 of 8 passing",
                        "Image · 1280 × 820", "Text · 6 lines"][index]),
                content: index == 0 ? """
                 HStack(spacing: rowGap)\n− .frame(width: 18)\n+ .frame(width: 16)\n\n\
                − .frame(height: 32)\n+ .frame(height: rowHeight)
                """ : "Rows are 28 pt now.\n\nInsets come from the list.\n\nThe capsule clears by 12.",
                colour: [UInt32(0x244b39), 0x303d4d, 0x345343, 0x3b454d, 0x514735][index])
        }
        return FunctionPanelInput(id: "mock-sidebar", title: "Sidebar density pass",
            goal: "Tighten the sidebar rows to the system metrics and check the profile capsule still clears the list.",
                                  status: state == .known && !agents.isEmpty ?
                                      "Running · \(agents.filter { $0.status == "Running" }.count) sub-agents" :
                                      "Running", model: state.project("GPT-5 Codex · High"),
                                      context: state.project(0.61),
                                  worked: state.project("6m 12s"), compactHistory: state.project(
                                      "Last compacted 18 min ago, 84% to 26%. Auto at 85%."),
                                  bodyID: "mercury", bodies: bodies, colours: colours, subagents: state.project(agents),
                                  covers: state.project(covers), files: state.project(files),
                                      tasks: state.project(tasks), outputs: state.project(outputs))
    }
}
