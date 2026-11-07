#if NORMIE_SELFTEST
import AppKit
import ObjectiveC

/// Standalone, offscreen only. Initializes AppKit, but creates no window, launches no .app and enters no run loop.
@main @MainActor enum NormieVerification {
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/normie-verification")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks = 0, failures: [String] = [], notes: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ name: String) { checks += 1; if !value() { failures.append(name) } }
        NormieHostVerification.run { value,name in check(value,name) }
        let now = Date(timeIntervalSince1970: 1_793_145_600)
        let original = MockSeed.make()
        let store = ConversationStore(conversations: original, projects: MockSeed.projects, devices: MockSeed.devices)
        let model = NormieSidebarModel(store: store)
        check(model.groupOpen["Recents"] == false, "Recents starts collapsed")
        check(model.isOpen(store.project("spw")!), "pinned project starts open")
        check(model.isOpen(store.project("rs")!), "active project starts open")
        check(!model.isOpen(store.project("plt")!), "inactive project starts closed")
        for i in 0..<32 {
            let c = Conversation(id: "many-\(i)", title: "Long list \(i)")
            c.projectID = "fn"; c.updated = now.addingTimeInterval(-Double(i)*100); store.add(c)
        }
        model.toggleProject("fn")
        check(model.rows.filter { if case .conversation(_, "fn") = $0 { true } else { false } }.count == 5, "first five per project")
        model.showMore("fn")
        check(model.limit("fn") == 25, "Show More adds twenty")
        model.select("many-30")
        check(model.limit("fn") >= 31 && model.rows.contains { $0.conversationID == "many-30" }, "selected deep chat is visible")
        model.search("Field Notes")
        check(model.rows.filter { $0.conversationID?.hasPrefix("many-") == true }.count == 32, "project search shows every matching chat, without pagination")
        model.search("Long list 31")
        check(model.rows.compactMap(\.conversationID) == ["many-31"], "title search")
        model.search("不存在的项目")
        check(model.rows.isEmpty, "Unicode no-results search")
        model.search(""); model.select("many-30")
        model.pin("many-30")
        check(store.conversation("many-30")!.pinned, "pin mutates original model")
        check(model.rows.contains(.conversation("many-30", project: nil)), "pinned chat leaves project")
        model.pin("many-30")
        check(model.rows.contains(.conversation("many-30", project: "fn")), "unpin returns to project and stays visible")
        model.pinProject("fn")
        check(store.project("fn")!.pinned, "project pin")
        check(model.isGroupOpen("Pinned"), "selected pinned project opens Pinned")
        model.pinProject("fn")
        model.beginRename("many-30"); model.renameText = "  新标题  "; model.finishRename()
        check(store.conversation("many-30")!.title == "新标题", "Return rename trims whitespace")
        model.beginRename("many-30"); model.renameText = "wrong"; model.cancelRename()
        check(store.conversation("many-30")!.title == "新标题", "Escape cancels rename")
        model.beginRename("many-30"); model.renameText = "  \n "; model.finishRename()
        check(store.conversation("many-30")!.title == "新标题", "empty rename retains original")
        model.beginRename("many-30"); model.renameText = "Committed on leaving"; model.select("many-29")
        check(store.conversation("many-30")!.title == "Committed on leaving", "selection change commits rename")
        model.select("A"); let running = store.conversation("A")!.running
        model.archive("A", at: now)
        check(store.conversation("A")!.archived && store.conversation("A")!.running == running, "archive does not stop a run")
        let nearest = model.live.sorted { $0.updated > $1.updated }.first?.id
        check(model.current == nearest && model.current != "A", "archive current selects most recent other chat")
        check(model.undoArchive() && model.current == "A" && !store.conversation("A")!.archived, "Undo restores archived current and selection")
        model.archive("many-10"); check(model.current == "A", "archive background preserves current")
        check(model.undoArchive() && model.current == "A", "undo background preserves selection")
        model.archive("many-10"); model.archive("many-11")
        check(model.undoArchive() && !store.conversation("many-11")!.archived && store.conversation("many-10")!.archived, "archive undo LIFO")
        check(model.undoArchive(), "second archive undo")
        model.archive("many-12"); model.invalidateUndo(for: ["many-12"])
        check(!model.undoArchive() && store.conversation("many-12")!.archived, "permanent deletion invalidates Undo (b030)")
        model.canLeaveSelection = { false }; let selected = model.current
        model.select("B"); model.archive(selected!)
        check(model.current == selected && !store.conversation(selected!)!.archived, "marked input admission blocks selection/archive")
        model.canLeaveSelection = { true }
        model.keyboard(.home); let first = model.rows.compactMap(\.conversationID).first
        check(model.current == first, "Home selects first chat")
        model.keyboard(.down); let second = model.current
        check(second != first, "Down skips section and project rows")
        model.keyboard(.up); check(model.current == first, "Up selects previous chat")
        model.keyboard(.end); check(model.current == model.rows.compactMap(\.conversationID).last, "End selects last visible chat")
        model.select("many-20"); model.keyboard(.left)
        check(model.projectOpen["fn"] == false, "Left folds project")
        model.keyboard(.right); check(model.rows.contains { $0.conversationID == "many-20" }, "Right restores project")
        model.focus(.group("Recents")); model.keyboard(.right)
        check(model.groupOpen["Recents"] == true, "keyboard can open a group without switching conversations")
        model.keyboard(.left); check(model.groupOpen["Recents"] == false, "keyboard can fold a group")
        model.focus(.project("fn")); model.keyboard(.activate)
        check(model.projectOpen["fn"] == false, "Return activates focused project disclosure")
        model.keyboard(.activate)
        let moreModel = NormieSidebarModel(store: store); moreModel.toggleProject("fn"); moreModel.focus(.more("fn"))
        let beforeMore = moreModel.limit("fn"); moreModel.keyboard(.activate)
        check(moreModel.limit("fn") == beforeMore+20, "keyboard activates Show More")
        let c = store.conversation("A")!
        let oldError = c.error, oldQuestion = c.question, oldRunning = c.running
        c.error = .running; c.question = "?"; c.running = true
        check(NormieSidebarModel.status(c) == "Error, still running", "error beats needs-you and running")
        c.error = nil; check(NormieSidebarModel.status(c) == "Question", "question beats running")
        c.error = oldError; c.question = oldQuestion; c.running = oldRunning
        for (seconds, expected) in [(0, "now"), (240, "4m"), (7200, "2h"), (259200, "3d"), (3024000, "5w")] {
            check(NormieSidebarModel.shortAge(now.addingTimeInterval(-Double(seconds)), now: now) == expected, "relative age \(expected)")
        }

        var menuContext = NormieMenuContext(hasConversation: true, running: true, memberCount: 3)
        var fired: [NormieCommand] = []
        let menus = NormieMenuBuilder(context: { menuContext }, perform: { command, _ in fired.append(command) })
        let menu = menus.makeMainMenu(demo: true)
        func flatten(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0]+($0.submenu.map(flatten) ?? []) } }
        let items = flatten(menu)
        func item(_ command: NormieCommand) -> NSMenuItem { items.first { $0.representedObject as? String == command.rawValue }! }
        check(item(.newChat).keyEquivalent == "n", "New Chat shortcut")
        check(item(.archive).keyEquivalent == "\u{8}", "Archive shortcut")
        check(item(.sidebar).keyEquivalentModifierMask == [.command, .control], "Sidebar shortcut")
        check(items.first { $0.title == "Undo" }?.target == nil && items.first { $0.title == "Copy" }?.target == nil, "editing commands use native responder chain")
        check(menus.validateMenuItem(item(.stop)), "Stop enabled for running selected chat")
        menuContext.online = false; check(!menus.validateMenuItem(item(.stop)), "offline Stop disabled")
        menuContext.online = true; menuContext.hasConversation = false; menuContext.composingNew = true
        for command in [NormieCommand.archive, .pin, .rename, .stop, .member] { check(!menus.validateMenuItem(item(command)), "draft disables \(command)") }
        menuContext.hasConversation = true; menuContext.composingNew = false; menuContext.pinned = true
        _ = menus.validateMenuItem(item(.pin)); check(item(.pin).title == "Unpin Chat", "menu validates actual current pin state")
        menus.applyShortcuts(["newChat": "⌥⌘N", "archive": ""], numberShortcuts: false)
        check(item(.newChat).keyEquivalentModifierMask == [.option, .command] && item(.archive).keyEquivalent.isEmpty, "custom shortcuts apply")
        check(items.filter { $0.identifier?.rawValue.hasPrefix("number.") == true }.allSatisfy { $0.keyEquivalent.isEmpty }, "number shortcuts can be disabled")
        NSApp.sendAction(item(.pin).action!, to: item(.pin).target, from: item(.pin))
        check(fired == [.pin], "menu emits callback")
        store.quotaFiveHourReported = false; store.quotaWeekReported = false
        let account = menus.makeAccountMenu(account: NormieAccount(initials: "LO", name: "Louis", plan: "Pro", daybreak: true), quotaSummary: store.quotaMenuSummary, organic: true)
        check(account.items.first?.title == "New Chat" && account.items.contains { $0.subtitle == "Usage not reported" }, "Organic account commands and unknown quota")

        let dir = URL(fileURLWithPath: "/tmp/normie-core")
        let health: JSONValue = ["result": ["name": "Organic Codex Core", "backendConnected": true, "instanceId": "one", "pid": 42, "dataDir": .string(dir.path)]]
        let marker: JSONValue = ["instanceId": "one", "pid": 42]
        let identity = NormieLocalIdentity(health: health, localMarker: marker, dataDirectory: dir)
        check(identity.verified, "instance marker verifies local backend")
        for bad: JSONValue in [["instanceId": "two", "pid": 42], ["instanceId": "one", "pid": 43], ["instanceId": "", "pid": 42], .null] {
            check(!NormieLocalIdentity(health: health, localMarker: bad, dataDirectory: dir).verified, "mismatched identity is not local")
        }
        check(!NormieLocalIdentity(health: health, localMarker: marker, dataDirectory: URL(fileURLWithPath: "/tmp/other")).verified, "dataDir must match local marker directory")
        c.cwd = "/tmp/project"; var probes = 0
        let opener = NormieOpenIn(store: store, selected: { c }, notice: { _ in })
        let demoDecision = opener.decision(application: "Finder", directoryExists: { _ in probes += 1; return true })
        if case .prototype(let message) = demoDecision { check(message.contains("prototype"), "demo Open in is a prototype") } else { check(false, "demo Open in") }
        check(probes == 0, "demo does not probe file system")
        store.usesLiveCore = true
        _ = opener.decision(application: "Finder", directoryExists: { _ in probes += 1; return true })
        check(probes == 0, "unverified backend cannot probe local paths")
        opener.identity = identity
        check(opener.decision(application: "Finder", directoryExists: { _ in true }) == .open(URL(fileURLWithPath: "/tmp/project", isDirectory: true), bundle: "com.apple.finder"), "verified local directory allowed")
        c.deviceID = "pc"; probes = 0
        _ = opener.decision(application: "Finder", directoryExists: { _ in probes += 1; return true })
        check(probes == 0, "remote device stays remote even with local Core")
        c.deviceID = "mac"; store.usesLiveCore = false
        let review = NormieGitReview(c); c.gitDiffHash = "new"
        check(!review.isCurrent(c), "stale Git review is rejected")
        let gitActions = NormieActions(); var commits = 0, reverts = 0
        gitActions.commit = { _, _, _ in commits += 1 }; gitActions.revert = { _, _ in reverts += 1 }
        let git = NormieInspectorController(store: store, actions: gitActions)
        _ = git.view; git.view.frame = CGRect(x: 0, y: 0, width: 320, height: 700); git.show(c); git.view.needsLayout = true; git.view.layoutSubtreeIfNeeded()
        check(git.beginCommit(), "Git commit form opens")
        let commitField = git.verificationCommitField!
        commitField.stringValue = "Keep my commit message"
        git.view.frame.size.width = 280; git.view.needsLayout = true; git.view.layoutSubtreeIfNeeded()
        check(git.verificationCommitField === commitField && commitField.stringValue == "Keep my commit message", "inspector resize retains the same commit field and text")
        let reviewedHash = c.gitDiffHash; c.gitDiffHash = "stale"
        check(!git.commit() && commits == 0, "stale hash prevents Git commit callback")
        c.gitDiffHash = reviewedHash
        check(git.commit() && commits == 1, "reviewed commit reaches callback once")
        git.showChanges(); c.gitBusy = true
        check(!git.revertReviewedChanges(), "busy Git cannot revert")
        c.gitBusy = false; check(git.revertReviewedChanges() && reverts == 1, "reviewed revert uses explicit callback")

        let sessions = NativeComposerSessions(), actions = NormieActions()
        let workbench = NormieWorkbench(store: store, sessions: sessions, current: "A", actions: actions)
        workbench.refresh()
        check(workbench.detail.composer === sessions.composer(for: c, store: store), "detail shares composer session")
        let sameEditor = workbench.detail.composer!.textView
        let handed = workbench.composerForHandoff(); workbench.remountComposer()
        check(handed?.textView === sameEditor && workbench.detail.composer === handed, "handoff reuses editor")
        let external = NormieView(frame: CGRect(x: 0, y: 0, width: 700, height: 100))
        if let moving = workbench.composerForHandoff() { external.addSubview(moving) }
        _ = workbench.select("B")
        let externalB = workbench.composerForHandoff()!; external.addSubview(externalB)
        externalB.layoutMode = .fullBar; externalB.frame = CGRect(x: 10, y: 20, width: 500, height: 48)
        let externalFrame = externalB.frame; var externalSubmits = 0
        externalB.onSubmit = { [weak externalB] request in externalSubmits += 1; externalB?.completeSubmission(request.id, outcome: .accepted) }
        workbench.refresh()
        check(externalB.superview === external && externalB.frame == externalFrame && externalB.layoutMode == .fullBar,
              "external selection/refresh never steals or resizes the scene composer")
        _ = externalB.setText("External submission")
        check(externalB.submit() && externalSubmits == 1, "external refresh preserves scene submission callbacks")
        _ = workbench.select("A"); workbench.remountComposer()
        check(workbench.detail.composer?.superview === workbench.detail.view, "explicit reverse handoff remounts only the current session")
        check(workbench.newChat(), "New Chat starts a draft")
        let draft = workbench.detail.composer!, count = store.conversations.count
        _ = draft.setText("First message from retained editor")
        draft.textView.setSelectedRange(NSRange(location: 5, length: 3))
        check(store.conversations.count == count, "typing does not create a conversation")
        let savedEditor = draft.textView
        check(workbench.cancelNewChat() && workbench.newChat(), "cancel/reopen draft")
        check(workbench.detail.composer === draft && draft.textView.selectedRange() == NSRange(location: 5, length: 3), "reopen preserves draft, editor and selection")
        var creates = 0, submissions = 0
        actions.create = { _, _ in creates += 1; return Conversation(id: "promoted", title: "Promoted") }
        actions.submit = { _, _, complete in submissions += 1; complete(.accepted) }
        check(draft.submit(), "first send is admitted")
        check(creates == 1 && submissions == 1 && store.conversations.count == count+1, "first send creates once and submits once")
        check(sessions.existingComposer(for: "promoted") === draft && draft.textView === savedEditor, "promotion preserves the native editor")
        _ = draft.setText("Second message")
        check(draft.submit() && creates == 1 && submissions == 2, "promoted composer sends to its own conversation")
        check(sessions.draft().composer !== draft, "next draft has its own identity and Undo")
        actions.submit = { _, _, complete in complete(.failed("offline test")) }
        _ = draft.setText("Keep this on failure"); _ = draft.submit()
        check(draft.text == "Keep this on failure", "failed sends retain text")
        _ = workbench.select("A"); store.setOnline("mac", false); workbench.refresh()
        let offlineComposer = workbench.detail.composer!
        check(!offlineComposer.canSend && !offlineComposer.canEditOptions && offlineComposer.textView.isEditable, "offline keeps draft writable and disables send/options")
        check(!workbench.detail.offlineBanner.isHidden, "last-loaded-copy banner visible")
        check(!offlineComposer.voiceButton.isEnabled && !offlineComposer.modelButton.isEnabled && !offlineComposer.accessButton.isEnabled, "offline voice/model/access controls disabled")
        store.setOnline("mac", true); workbench.refresh()
        check(!workbench.detail.newChatView.pickDevice("preview-srv"), "offline device card cannot be chosen")
        check(workbench.detail.newChatView.pickDevice("pc") && workbench.detail.newChatView.context.projectID == "rs", "device switch picks its first project")
        check(!workbench.detail.newChatView.pickProject("fn"), "cannot choose project on another device")
        // M9 (NormieDetailView.emptyState, NewChatContext): the page is the leaf, the project and one line; the project
        // and device are the composer's chips, the devices a popover of cards; Voice needs a conversation.
        _ = workbench.newChat(projectID: "spw")
        let page = workbench.detail.newChatView, draftComposer = workbench.detail.composer!
        check(!page.subviews.contains { $0 is NSButton }, "M9 New Chat page has no project button or device cards")
        check(page.heading.stringValue == "Synthetic preview workspace" && page.subtitle.stringValue == "New chat on This Mac. Nothing is created until you send.", "M9 New Chat page names project and device")
        check(draftComposer.contextRow.onProject != nil && draftComposer.contextRow.onDevice != nil, "M9 draft context chips are menus")
        check(!draftComposer.voiceButton.isEnabled, "M9 draft Voice is disabled (no conversation)")
        var closed = 0
        let cards = page.makeDeviceCards { closed += 1 }
        check(cards.buttons.map(\.device.id) == store.devices.map(\.id) && cards.buttons.filter(\.chosen).map(\.device.id) == ["mac"], "M9 device cards list every device, the chosen one marked")
        check(cards.frame.width == 16 + CGFloat(store.devices.count) * 76 + CGFloat(store.devices.count - 1) * 6 && cards.frame.height == 16 + (cards.buttons.map(\.preferredHeight).max() ?? NormieDeviceButton.height), "M9 device cards are 76 pt, 6 pt apart, 8 pt around, with intrinsic wrapped names")
        check(cards.buttons.allSatisfy { $0.isEnabled == (store.device($0.device.id)?.online ?? false) }, "M9 offline device card is disabled")
        cards.buttons.first { $0.device.id == "pc" }?.run?()
        check(closed == 1 && page.context.deviceID == "pc" && workbench.newContext.deviceID == "pc", "M9 picking a device card closes the popover and switches the draft")
        _ = page.pickDevice("mac"); _ = page.pickProject("spw")
        _ = workbench.select("A")
        check(workbench.detail.composer!.contextRow.onProject == nil && workbench.detail.composer!.contextRow.onDevice == nil, "M9 a conversation's context chips are plain")
        _ = workbench.select("A"); workbench.sidebarModel.archive("A")
        check(workbench.archiveUndoManager.canUndo, "archive registers with native UndoManager")
        workbench.archiveUndoManager.undo()
        check(!c.archived && workbench.selectedConversation?.id == "A", "native UndoManager restores archive")
        workbench.sidebarModel.archive("B"); workbench.invalidateUndo(for: ["B"])
        check(!workbench.archiveUndoManager.canUndo && store.conversation("B")!.archived, "permanent delete removes native Undo token")
        var folderReply: (@MainActor (Project?) -> Void)?
        actions.chooseWorkspace = { _, reply in folderReply = reply }
        _ = workbench.newChat(projectID: "fn")
        let contextView = workbench.detail.newChatView
        let folderCount = store.projects.count
        (contextView.makeProjectMenu().items.last as? NormieMenuItem)?.fire()
        _ = workbench.select("A")
        folderReply?(Project(id: "late-folder", name: "Late folder", deviceID: "mac", path: "/tmp/late"))
        check(store.projects.count == folderCount, "late workspace callback cannot change a closed draft")
        _ = workbench.newChat(projectID: "fn")
        (contextView.makeProjectMenu().items.last as? NormieMenuItem)?.fire()
        folderReply?(Project(id: "chosen-folder", name: "Chosen folder", deviceID: "mac", path: "/tmp/chosen"))
        check(workbench.newContext.projectID == "chosen-folder", "current workspace callback selects its project")
        c.unread = true; c.completions = 2; c.redEvents = 3; c.redSeen = 0
        _ = workbench.select("A")
        check(!c.unread && c.completions == 0 && c.redSeen == 3, "selecting a conversation marks its visual events seen")
        let sidebar = workbench.sidebar
        _ = sidebar.view; sidebar.view.frame = CGRect(x: 0, y: 0, width: 270, height: 820); sidebar.view.needsLayout = true; sidebar.view.layoutSubtreeIfNeeded()
        check(sidebar.table.accessibilityRole() == .table, "sidebar AX table")
        check(sidebar.searchField.accessibilityRole() == .textField, "search AX text field")
        check(sidebar.accountView.button.accessibilityRole() == .button, "account AX button")
        let beforeKey = sidebar.model.current
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        sidebar.table.keyDown(with: event)
        check(sidebar.model.current != beforeKey, "actual table keyDown routes keyboard selection")
        check(sidebar.rowFrames.isEmpty && sidebar.avatarFrame == nil, "offscreen views do not fabricate window anchors")

        _ = workbench.select("A"); workbench.remountComposer()
        for scale:CGFloat in [1,2] {
            let insets=NSEdgeInsets(top:58,left:7,bottom:16,right:9)
            for controller in [workbench.sidebar as NSViewController,workbench.detail,workbench.inspector] {
                let root=controller.view as! NormieView
                root.frame=CGRect(x:0,y:0,width:420,height:760); root.verificationScale=scale; root.verificationSafeAreaInsets=insets
                root.needsLayout=true; root.layoutSubtreeIfNeeded(); controller.viewDidLayout()
                check(root.contentSafeRect == CGRect(x:7,y:58,width:404,height:686),"safe area excludes all four edges at \(scale)x")
            }
            let detail=workbench.detail
            check(workbench.sidebar.searchField.convert(workbench.sidebar.searchField.bounds,to:workbench.sidebar.view).minY>=58+10,"search clears unified toolbar")
            check(workbench.sidebar.accountView.frame.maxY<=744,"account clears bottom safe area")
            check(workbench.inspector.scrollView.frame.minY==58 && workbench.inspector.scrollView.frame.maxY==744,"inspector fills only its safe rect")
            check(detail.composerDockRect.maxY<=744-14 && detail.composerDockRect.minX>=7,"composer glass respects bottom and side safe areas")
            check(detail.composerGlass.cornerRadius == 20 && detail.composerGlass.style == .regular,"product20pt regular glass composer base")
            check(detail.composer?.superview === detail.view && detail.composer?.textView === sameEditor,"base does not reparent or replace the shared editor")
            check(detail.composerContext.stringValue.contains("·"),"glass context row shows project/device")
            check(detail.composerDockSnapshot(scale:scale) != nil,"composer glass snapshot entry at \(scale)x")
            for controller in [workbench.sidebar as NSViewController,workbench.detail,workbench.inspector] {
                let live=controller.view as! NormieView
                live.verificationSafeAreaInsets=nil
                live.additionalSafeAreaInsets=NSEdgeInsets(top:24,left:4,bottom:6,right:8)
                live.needsLayout=true; live.layoutSubtreeIfNeeded(); controller.viewDidLayout()
                check(live.contentSafeRect == live.safeAreaRect && live.contentSafeRect.width < live.bounds.width,"live AppKit safeAreaRect is used without verification overrides")
                live.additionalSafeAreaInsets=NSEdgeInsetsZero
            }
        }

        // Real AppKit subtree captures at both scales; no windows or app run loop.
        let fresh = ConversationStore(conversations: MockSeed.make(), projects: MockSeed.projects, devices: MockSeed.devices)
        let wb = NormieWorkbench(store: fresh, sessions: NativeComposerSessions(), current: "A")
        wb.account = NormieAccount(initials: "LO", name: "Louis", plan: "Pro", daybreak: true)
        let canvas = NormieView(frame: CGRect(x: 0, y: 0, width: 1280, height: 820)); canvas.fill = NormieDrawing.background
        for controller in [wb.sidebar as NSViewController, wb.detail, wb.inspector] { canvas.addSubview(controller.view) }
        wb.sidebar.view.frame = CGRect(x: 0, y: 0, width: 260, height: 820)
        wb.detail.view.frame = CGRect(x: 260, y: 0, width: 700, height: 820)
        wb.inspector.view.frame = CGRect(x: 960, y: 0, width: 320, height: 820)
        for scale in [CGFloat(1), 2] {
            for state in ["A-status", "B-approval", "C-question", "offline", "new-chat", "changes", "archive-toast", "search"] {
                fresh.setOnline("pc", true)
                switch state {
                case "A-status": _ = wb.select("A"); wb.inspector.showStatus()
                case "B-approval": _ = wb.select("B")
                case "C-question": _ = wb.select("C")
                case "offline":
                    if let offline = fresh.conversations.first(where: { fresh.isOffline($0) && !$0.archived }) { _ = wb.select(offline.id) }
                    else { fresh.setOnline("pc", false); _ = wb.select("D") }
                case "new-chat": _ = wb.newChat(projectID: "fn")
                case "changes": _ = wb.select("A"); wb.reviewChanges(); for file in fresh.conversation("A")!.changes where !wb.inspector.isFileExpanded(file.path) { wb.inspector.toggleFile(file.path) }
                case "archive-toast": _ = wb.select("A"); wb.sidebarModel.archive("A")
                default: _ = wb.undoArchive(); wb.sidebar.search("Release")
                }
                wb.refresh(); layout(canvas, scale: scale)
                let image = NativeViewBitmap.capture(canvas, scale: scale)
                check(image.width == 1280*Int(scale) && image.height == 820*Int(scale), "\(state) bitmap scale \(scale)")
                try write(image, to: directory.appendingPathComponent("\(state)@\(Int(scale))x.png"))
                let pixelIssues = gridIssues(canvas, root: canvas, scale: scale)
                check(pixelIssues.isEmpty, "\(state) own geometry lies on \(scale)× grid: \(pixelIssues)")
                wb.sidebar.search("")
            }
            model.select("many-30"); sidebar.model.select("many-30"); layout(sidebar.view, scale: scale)
            try write(NativeViewBitmap.capture(sidebar.view, scale: scale), to: directory.appendingPathComponent("sidebar-deep@\(Int(scale))x.png"))
        }
        let rootWorkbench = NormieWorkbench(store: fresh, sessions: NativeComposerSessions(), current: "A")
        rootWorkbench.view.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        layout(rootWorkbench.view, scale: 1)
        check(rootWorkbench.sidebar.parent is NSSplitViewController && rootWorkbench.detail.parent === rootWorkbench.sidebar.parent,
              "default root installs the three controllers into one NSSplitViewController")
        check(rootWorkbench.view.subviews.first?.frame.size == rootWorkbench.view.bounds.size, "default split fills root")
        let ownIssues = plainControls(canvas, skipNative: true)
        check(ownIssues.isEmpty, "Normie controls override draw and avoid plain fields/buttons: \(ownIssues)")
        let importedIssues = plainControls(canvas, skipNative: false)
        check(importedIssues.isEmpty, "Full reused-Native tree has zero plain controls: \(importedIssues)")
        notes.append("§7.5 own Normie controls: \(ownIssues.count) plain controls. Full reused-Native audit: \(importedIssues.count) plain controls: \(importedIssues.joined(separator: ", "))")
        notes.append("PNG captures are offscreen AppKit cacheDisplay output. They do not prove live screen/snapshot equality; that needs Claude's real-window swap recording.")
        notes.append("Window anchors intentionally empty offscreen. Window-coordinate conversion and external VoiceOver remain integration checks.")
        let drawIssues = controlsWithoutDrawOverride(canvas, skipNative: true)
        check(drawIssues.isEmpty, "own controls implement draw and use no system bezel: \(drawIssues)")
        try NormieM8Verification.run(directory:directory,check:{check($0,$1)})
        try NormieLookVerification.run(directory:directory,check:{check($0,$1)})
        try NormieS2Verification.run(directory:directory,check:{check($0,$1)})
        try await NormieComponentFixVerification.run(directory:directory,check:{check($0,$1)})
        try NormieSidebarM9Verification.run(directory:directory,check:{check($0,$1)})
        try NormieStreamCostVerification.run(output:directory,check:{check($0,$1)})
        let result = "Normie selftest: \(checks) checks, \(failures.count) failures\n"+(notes+failures.map { "FAIL: "+$0 }).joined(separator: "\n")+"\n"
        try result.write(to: directory.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        print(result)
        if !failures.isEmpty { exit(1) }
    }
    static func layout(_ view: NSView, scale: CGFloat) {
        func apply(_ v: NSView) { if let own = v as? NormieView { own.verificationScale = scale }; v.needsLayout = true; v.subviews.forEach(apply) }
        apply(view); view.layoutSubtreeIfNeeded(); apply(view); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
    static func plainControls(_ view: NSView, skipNative: Bool) -> [String] {
        if skipNative && (view is NativeComposer || view is NativeTranscript) { return [] }
        let type = type(of: view)
        var result: [String] = []
        if type == NSTextField.self || type == NSButton.self || type == NSPopUpButton.self { result.append(String(describing: type)) }
        return result+view.subviews.flatMap { plainControls($0, skipNative: skipNative) }
    }
    static func gridIssues(_ view: NSView, root: NSView, scale: CGFloat) -> [String] {
        if view is NativeComposer || view is NativeTranscript { return [] }
        var issues: [String] = []
        if view is NormieView || view is NormieField || view is NormieLabel || view is NormieButton || view is NormieDiffTextView {
            let r = view.convert(view.bounds, to: root)
            if [r.minX, r.minY, r.width, r.height].contains(where: { abs($0*scale-($0*scale).rounded()) > 1e-6 }) { issues.append(String(describing: type(of: view))) }
        }
        return issues+view.subviews.flatMap { gridIssues($0, root: root, scale: scale) }
    }
    static func controlsWithoutDrawOverride(_ view: NSView, skipNative: Bool) -> [String] {
        if skipNative && (view is NativeComposer || view is NativeTranscript) { return [] }
        var issues: [String] = []
        let base: AnyClass? = view is NSButton ? NSButton.self : view is NSTextField ? NSTextField.self : nil
        if let base, let own = class_getInstanceMethod(type(of: view), #selector(NSView.draw(_:))), let inherited = class_getInstanceMethod(base, #selector(NSView.draw(_:))),
           unsafeBitCast(method_getImplementation(own), to: UInt.self) == unsafeBitCast(method_getImplementation(inherited), to: UInt.self) { issues.append("draw: "+String(describing: type(of: view))) }
        if let b = view as? NSButton, b.isBordered { issues.append("bezel: "+b.title) }
        if let f = view as? NSTextField, f.isBezeled || f.isBordered { issues.append("bezel: "+f.stringValue) }
        return issues+view.subviews.flatMap { controlsWithoutDrawOverride($0, skipNative: skipNative) }
    }
    static func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
#endif
