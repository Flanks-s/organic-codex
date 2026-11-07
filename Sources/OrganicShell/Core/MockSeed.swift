import Foundation

/// The six starting conversations of spec §12.1: running with sub-agents, waiting for approval,
/// asking a question, error but running, error and stopped, idle. Canopy's other chats fill the sidebar.
@MainActor
enum MockSeed {
    static let question = "Should the release notes mention the removed New Chat sheet, or stay with new features only?"
    static let devices = [Device(id: "mac", name: "This Mac", kind: .mac),
                          Device(id: "pc", name: "Preview PC", kind: .pc),
                          Device(id: "srv", name: "Archive Server", kind: .server),
                          Device(id: "preview-srv", name: "Preview Server", kind: .server, online: false)]
    static let projects = [Project(id: "spw", name: "Synthetic preview workspace", deviceID: "mac", colorHex: "#5856d6", pinned: true),
                           Project(id: "fn", name: "Field Notes", deviceID: "mac"),
                           Project(id: "rs", name: "Render Scripts", deviceID: "pc"),
                           Project(id: "ai", name: "Archive Indexer", deviceID: "srv"),
                           Project(id: "plt", name: "Photo Library Tools", deviceID: "mac")]
    /// The first window holds A–F; the other chats join a window when opened from the sidebar.
    static let windowMembers: [ConversationID] = ["A", "B", "C", "D", "E", "F"]

    /// Retain the existing six-member fixture API for component and scene tests.
    static func make(now: Date = .now) -> [Conversation] { Array(library(now: now).prefix(windowMembers.count)) }

    /// The product's complete sidebar library: six window members, eleven history chats, three archived chats.
    static func library(now: Date = .now) -> [Conversation] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func item(_ id: String, _ turn: String, _ kind: RowKind, _ text: String, _ status: String? = nil) -> TranscriptItem {
            TranscriptItem(id: id, turnID: turn, kind: kind, text: text, status: status)
        }

        let a = Conversation(id: "A", identityIndex: 0, title: "Sidebar density pass", projectID: "spw", updated: ago(0), contextUsed: 0.46, items: [
            item("A-1", "A-t1", .user, "Tighten the sidebar rows to the system metrics and check the profile capsule still clears the list."),
            item("A-2", "A-t1", .reasoning, "The sidebar row height comes from the system list. Custom insets only fight it."),
            item("A-3", "A-t1", .tool(.command), "rg -n \"rowInsets\" native/\nnative/SidebarView.swift:42:    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))"),
            item("A-3b", "A-t1", .tool(.fileChange), "native/SidebarView.swift  +1 −1"),
            item("A-4", "A-t1", .assistant, "Found one custom inset in `SidebarView.swift` and removed it. Checking the narrow window next."),
        ])
        a.changes = [FileChange(path: "native/SidebarView.swift", added: 1, removed: 1, lines: [
            .init(kind: .context, text: "        chatRow(conversation)"),
            .init(kind: .removed, text: "            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))"),
            .init(kind: .added, text: "            // Row height and insets come from the system sidebar list."),
            .init(kind: .context, text: "    }")])]
        a.satellites = [Satellite(id: "A-s1", face: "^-^"), Satellite(id: "A-s2", face: "^o^"),
                        Satellite(id: "A-s3", face: "•ᴗ•"), Satellite(id: "A-s4", face: "-_-", done: true)]

        let b = Conversation(id: "B", identityIndex: 1, title: "Approval copy review", projectID: "spw", updated: ago(5), contextUsed: 0.22, items: [
            item("B-1", "B-t1", .user, "Run the copy linter over the approval strings."),
            item("B-2", "B-t1", .reasoning, "The linter lives in Scripts/. Running it reads every .strings file but writes nothing."),
            item("B-3", "B-t1", .tool(.command), "Scripts/lint-copy.sh native/Approval*.strings", "waiting"),
        ])
        let approval = Approval(id: "B-ap1", title: "Run this command?", command: "Scripts/lint-copy.sh native/Approval*.strings",
                                note: "Runs in Synthetic preview workspace on This Mac.", acceptLabel: "Run", toolItemID: "B-3")
        b.approvals = [approval]

        let c = Conversation(id: "C", identityIndex: 2, title: "Release notes outline", projectID: nil, updated: ago(25), contextUsed: 0.31, items: [
            item("C-1", "C-t1", .user, "Outline the release notes for 0.1.2."),
            item("C-1b", "C-t1", .reasoning, "Four user-visible changes since 0.1.1; group them by where people meet them."),
            item("C-1c", "C-t1", .tool(.command), "git log --oneline v0.1.1..HEAD\n9 commits"),
            item("C-2", "C-t1", .assistant, "Here’s an outline for **0.1.2**:\n\n- **Sidebar**: Pinned, Projects and Recents, across devices\n- **Model control**: one place for model, reasoning and speed\n- **New Chat**: starts right in the composer\n- **Context row**: shows where the next message runs"),
            item("C-3", "C-t1", .assistant, question),
        ])
        c.question = question
        c.pinned = true

        let d = Conversation(id: "D", identityIndex: 3, title: "Speed up batch render", projectID: "rs", deviceID: "pc", updated: ago(2), contextUsed: 0.63, items: [
            item("D-1", "D-t1", .user, "Why is the batch render slow on the PC? Fix it if you can."),
            item("D-2", "D-t1", .tool(.command), "render --batch scenes/*.json --profile", "failed"),
            item("D-3", "D-t1", .notice(.error), "Command failed with exit code 1: texture cache is locked by another process."),
        ])
        d.error = .running
        d.redEvents = 1

        let e = Conversation(id: "E", identityIndex: 4, title: "Rebuild search index", projectID: "ai", deviceID: "srv", updated: ago(40), contextUsed: 0.88, items: [
            item("E-1", "E-t1", .user, "Rebuild the search index after the schema change."),
            item("E-2", "E-t1", .tool(.command), "indexer rebuild --schema v4", "failed"),
            item("E-3", "E-t1", .notice(.error), "The run stopped: disk quota exceeded on /srv/index."),
        ])
        e.error = .stopped
        e.redEvents = 1

        let f = Conversation(id: "F", identityIndex: 5, title: "Synthetic UI layout specimen", projectID: "spw", updated: ago(90), contextUsed: 0.12, items: [
            item("F-1", "F-t1", .user, "The layout specimen wraps the toolbar title at 560 pt. Can you make it hold?"),
            item("F-2", "F-t1", .reasoning, "The title wraps only below 600 pt, so the column math is where to look, not the toolbar."),
            item("F-3", "F-t1", .tool(.command), "rg -n \"readingWidth\" native/\nnative/Specimen/ColumnMath.swift:18:    let readingWidth = window.width - 2 * gutter"),
            item("F-4", "F-t1", .tool(.fileChange), "native/Specimen/ColumnMath.swift  +6 −2\nnative/Specimen/ColumnMathTests.swift  +14 −0"),
            item("F-5", "F-t1", .tool(.command), "swift test --filter ColumnMathTests\nExecuted 4 tests, with 0 failures."),
            item("F-6", "F-t1", .assistant, "Fixed. The reading width now clamps between 480 and 740 pt, so the toolbar title keeps one line down to 560 pt.\n\n**What changed**\n- `ColumnMath.swift`: clamp the reading width instead of letting it follow the window\n- `ColumnMathTests.swift`: four cases, 560 to 1920 pt\n\n**Checks**\n- `swift test --filter ColumnMathTests`: 4 passed"),
            item("F-7", "F-t2", .user, "nice. what was actually wrong?"),
            item("F-8", "F-t2", .assistant, "The width was computed before the gutters were known, so at small sizes it came out negative and the title took the rest of the line:\n\n```swift\nlet readingWidth = window.width - 2 * gutter // gutter was 0 here\n```\n\nNow it waits for the gutters and clamps. Classic case of the math being right and the order being wrong."),
        ])
        f.draft = ""

        // Branches and plans (the Status inspector's Git tools and Progress).
        func plan(_ id: String, _ steps: [String], done: Int) -> [PlanStep] {
            steps.enumerated().map { PlanStep(id: "\(id)-p\($0.offset)", title: $0.element, done: $0.offset < done) }
        }
        a.branch = "feat/sidebar-density"
        a.plan = plan("A", ["Find the custom row insets", "Remove them and use the system metrics",
                            "Check the profile capsule still clears the list", "Run LayoutTests at 560 and 1920 pt",
                            "Summarise what changed"], done: 1)
        b.branch = "copy/approvals"
        b.plan = plan("B", ["Run the copy linter over the approval strings", "Fix what it flags", "Recheck the sheet copy"], done: 0)
        c.branch = "docs/release-0.1.2"
        c.plan = plan("C", ["Collect merged changes since 0.1.1", "Group them by area", "Write the outline"], done: 2)
        d.branch = "perf/batch-render"
        d.plan = plan("D", ["Profile the batch render", "Cache the glyph atlas", "Parallelise the tile pass",
                            "Compare timings"], done: 2)
        e.branch = "fix/index-rebuild"
        e.plan = plan("E", ["Rebuild the search index", "Skip undated documents", "List the skipped ones"], done: 1)
        f.branch = "main"
        f.plan = plan("F", ["Lay out the specimen columns", "Check the reading width", "Add the 560 pt test"], done: 3)
        f.changes = [FileChange(path: "native/Specimen/ColumnMath.swift", added: 6, removed: 2,
                                lines: diff(path: "native/Specimen/ColumnMath.swift", added: 6, removed: 2)),
                     FileChange(path: "native/Specimen/ColumnMathTests.swift", added: 14, removed: 0,
                                lines: diff(path: "native/Specimen/ColumnMathTests.swift", added: 14, removed: 0))]
        a.running = true; a.activeTurnID = "A-t1"
        b.running = true; b.activeTurnID = "B-t1"
        d.running = true; d.activeTurnID = "D-t1"
        for c in [a, b, c, d, e, f] {
            var rows: [TranscriptItem] = []
            for (i, item) in c.items.enumerated() {
                rows.append(item)
                let endsTurn = i == c.items.count - 1 || c.items[i + 1].turnID != item.turnID
                guard endsTurn, item.turnID != c.activeTurnID,
                      let summary = changesSummary(c.items.filter { $0.turnID == item.turnID }) else { continue }
                rows.append(.init(id: item.turnID + "-changes", turnID: item.turnID, kind: .notice(.info),
                                  text: summary, status: TranscriptPresentation.changesStatus))
            }
            c.items = rows
        }
        // The rest of Canopy's sidebar (prototype seed): finished chats that wait in the sidebar until opened, one on the
        // offline Preview Server, and three archived ones. They take the identities after A–F.
        var history: [Conversation] = []
        func past(_ id: String, _ title: String, _ project: String?, on device: String = "mac", _ minutes: Double,
                  _ question: String, _ answer: String, archivedDays: Double? = nil) {
            let h = Conversation(id: id, identityIndex: 6 + history.count, title: title, projectID: project, deviceID: device,
                                 updated: ago(minutes), contextUsed: 0.08, items: [
                item("\(id)-1", "\(id)-t1", .user, question),
                item("\(id)-2", "\(id)-t1", .assistant, answer),
            ])
            if let archivedDays { h.archived = true; h.archivedAt = ago(archivedDays * 1440) }
            history.append(h)
        }
        past("H1", "Synthetic conversation title for truncation and wrapping checks", "spw", 120,
             "Check how a very long conversation title truncates in the sidebar.",
             "Titles stay on one line and truncate at the end. The full title is in the tooltip and in the window title when the chat is open.")
        past("H2", "Synthetic 多语言界面样本", "spw", 1440,
             "Synthetic Unicode specimen: 合成界面预览，用于检查中文、英文和标点的混排。\n\nEnglish / 中文 / 日本語 / 한국어 / العربية / Français — 0123456789.",
             "Mixed scripts share one line height here, so Chinese and Latin text keep the same rhythm. 标点使用全角，数字保持等宽。")
        past("H3", "Tag cleanup plan", "fn", 2880, "Suggest a tag cleanup plan for the notes.",
             "Merge tags that differ only by case, retire tags used once, and keep a short list of 12 top-level tags.")
        past("H4", "Weekly digest format", "fn", 5000, "What should the weekly digest include?",
             "Three sections: what changed, what is blocked, what is next. One line each, links last.")
        past("H5", "HEIC to JPEG script", "plt", 9000, "Write a script that converts HEIC photos to JPEG.",
             "Use sips: `sips -s format jpeg input.heic --out output.jpg`. A loop over the folder handles the batch.")
        past("H6", "Regex for log timestamps", nil, 60, "Regex for ISO timestamps in the log?",
             #"This matches them: `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z`"#)
        past("H7", "Nightly preview build", nil, on: "preview-srv", 180,
             "Kick off the nightly preview build and tell me if the asset step is still slow.",
             "The nightly build finished on Preview Server. The asset step took 4m 10s, down from 6m; everything else ran in under a minute.")
        past("H8", "Compare two JSON exports", nil, on: "pc", 1400, "Compare these two JSON exports.",
             "They differ in 3 keys: version, updatedAt and the order of tags. The data itself is the same.")
        past("H9", "Explain a concurrency warning", nil, 2900, "What does \"Sending non-Sendable value\" mean?",
             "A value crosses an actor boundary but its type is not Sendable. Make the type Sendable or keep it on one actor.")
        past("H10", "Draft a changelog entry", nil, 9500, "Draft a changelog entry for the bubble padding fix.",
             "Fixed: user message bubbles now have equal optical padding on all four sides.")
        past("H11", "Batch rename screenshots", nil, 17000, "Batch rename screenshots by date.",
             "A Shortcuts action can read the creation date and rename each file to YYYY-MM-DD-HHMM.png.")
        past("X1", "Old sidebar spike", "spw", 12000, "Try a sidebar with host headers.",
             "Done as a spike. The 0.1.2 design replaces host headers with Pinned, Projects and Recents.", archivedDays: 6)
        past("X2", "Try SwiftData for drafts", nil, 30000, "Could drafts live in SwiftData?",
             "They could, but drafts are per-device and small; UserDefaults keyed by chat ID is simpler.", archivedDays: 15)
        past("X3", "Render farm notes", "rs", on: "pc", 40000, "Notes on the render farm setup.",
             "Two machines, shared cache on the NAS, jobs queued by a small script.", archivedDays: 22)

        return [a, b, c, d, e, f] + history
    }
    static func diff(path: String, added: Int, removed: Int) -> [FileChange.Line] {
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let gone = ["        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))",
                    "        .frame(height: 30)", "        .padding(.vertical, 3)", "            .font(.system(size: 12))"]
        let new = ["        // Row height and insets come from the system sidebar list.",
                   "        .help(\"\\(title)\\nUpdated \\(updated)\")", "        .lineLimit(1).truncationMode(.tail)",
                   "        .accessibilityElement(children: .combine)", "            .foregroundStyle(.secondary)",
                   "        .contentShape(Rectangle())", "        .tag(conversation.id)", "        .font(.body)",
                   "        .listRowSeparator(.hidden)"]
        var lines: [FileChange.Line] = [.init(kind: .context, text: "struct \(name): View {"),
                                        .init(kind: .context, text: "    var body: some View {")]
        lines += (0..<removed).map { .init(kind: .removed, text: gone[$0 % gone.count]) }
        lines += (0..<added).map { .init(kind: .added, text: new[$0 % new.count]) }
        lines.append(.init(kind: .context, text: "    }"))
        return lines
    }
    static func changesSummary(_ items: [TranscriptItem]) -> String? {
        var files: [(path: String, added: Int, removed: Int)] = []
        for item in items where item.rowKind == .tool(.fileChange) {
            for line in item.text.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3, let added = Int(parts[1].dropFirst()), let removed = Int(parts[2].dropFirst()) else { continue }
                if let i = files.firstIndex(where: { $0.path == parts[0] }) {
                    files[i].added += added; files[i].removed += removed
                } else { files.append((String(parts[0]), added, removed)) }
            }
        }
        // Zero counts are left out, as Codex writes "+14" (the activity rows do the same).
        return files.isEmpty ? nil : files.map { file in
            ([file.path + " "] + (file.added > 0 ? ["+\(file.added)"] : []) + (file.removed > 0 ? ["−\(file.removed)"] : []))
                .joined(separator: " ")
        }.joined(separator: "\n")
    }


}
