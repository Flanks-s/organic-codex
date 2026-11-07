import AppKit

@MainActor final class NormieMenuItem: NSMenuItem {
    private var run: () -> Void
    init(_ title: String, enabled: Bool = true, run: @escaping () -> Void = {}) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc func fire() { if isEnabled { run() } }
}

enum NormieCommand: String, CaseIterable {
    case settings, profile, usage, shortcuts, signOut, help, newChat, search, sidebar, inspector, terminal, fullyFocused
    case stop, focus, attach, latest, rename, customize, pin, unread, archive
    case focused, split, nextPane, previousPane, member, moveWindow, mergeWindows, collapse, restore
    case artifacts, browser, appshots
}

struct NormieMenuContext {
    var hasConversation = false
    var composingNew = false
    var running = false
    var stopping = false
    var online = true
    var pinned = false
    var collapsed = false
    var sidebarVisible = true
    var inspectorVisible = false
    var terminalShown=false
    var normie = true
    var memberCount = 0
    var canAttach = true
    var supported = Set(NormieCommand.allCases)
    func enabled(_ command: NormieCommand, tag: Int = 0) -> Bool {
        guard supported.contains(command) else { return false }
        switch command {
        case .stop: return hasConversation && running && online && !stopping
        case .rename, .customize, .pin, .unread, .archive, .latest, .moveWindow: return hasConversation && !composingNew
        case .focused, .split: return hasConversation && !composingNew
        case .nextPane, .previousPane: return memberCount > 1 && !composingNew
        case .member: return tag >= 0 && tag < memberCount && !composingNew
        case .attach: return (hasConversation || composingNew) && canAttach
        case .focus: return hasConversation || composingNew
        case .terminal: return hasConversation && normie && !composingNew
        case .inspector: return normie
        case .collapse: return !collapsed
        case .restore: return collapsed
        case .help: return false // Same disabled placeholder as the product account menu.
        default: return true
        }
    }
}

/// Retain this object while its menus are mounted. It has no NSApp side effects; App installs the returned menus.
@MainActor final class NormieMenuBuilder: NSObject, NSMenuItemValidation {
    var context: () -> NormieMenuContext
    var perform: (NormieCommand, Int) -> Void
    private(set) var servicesMenu = NSMenu(title: "Services")
    private(set) var windowsMenu = NSMenu(title: "Window")
    private(set) var helpMenu = NSMenu(title: "Help")
    private var main: NSMenu?
    init(context: @escaping () -> NormieMenuContext, perform: @escaping (NormieCommand, Int) -> Void) {
        self.context = context; self.perform = perform
    }
    @discardableResult private func command(_ menu: NSMenu, _ title: String, _ action: NormieCommand, key: String = "", modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        item.target = self; item.representedObject = action.rawValue; item.tag = tag
        // Match the product: only commands in Keyboard Shortcuts carry the editable prefix.
        let configurable:Set<NormieCommand>=[.newChat,.archive,.rename,.pin,.unread,.attach,.focus,.stop,.search,.sidebar,.collapse,.restore,.inspector,.settings]
        item.identifier = .init(action == .member ? "number.\(tag+1)" : (configurable.contains(action) ? "shortcut.":"command.")+action.rawValue)
        item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
        item.isEnabled = context().enabled(action, tag: tag); return item
    }
    private func responder(_ menu: NSMenu, _ title: String, selector: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        item.target = nil; item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
    }
    func makeMainMenu(appName: String = "Organic Codex", demo: Bool = false) -> NSMenu {
        let root = NSMenu(); main = root
        func submenu(_ name: String) -> NSMenu {
            let menu = NSMenu(title: name); root.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = menu; return menu
        }
        let app = submenu(appName)
        responder(app, "About \(appName)", selector: "orderFrontStandardAboutPanel:")
        app.addItem(.separator()); command(app, "Settings…", .settings, key: ",")
        app.addItem(.separator()); servicesMenu = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = servicesMenu
        app.addItem(.separator()); responder(app, "Hide \(appName)", selector: "hide:", key: "h")
        responder(app, "Hide Others", selector: "hideOtherApplications:", key: "h", modifiers: [.command, .option])
        responder(app, "Show All", selector: "unhideAllApplications:")
        app.addItem(.separator()); responder(app, "Quit \(appName)", selector: "terminate:", key: "q")
        let file = submenu("File"); command(file, "New Chat", .newChat, key: "n")
        file.addItem(.separator()); responder(file, "Close Window", selector: "performClose:", key: "w")
        let edit = submenu("Edit")
        responder(edit, "Undo", selector: "undo:", key: "z")
        responder(edit, "Redo", selector: "redo:", key: "z", modifiers: [.command, .shift]); edit.addItem(.separator())
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { responder(edit, title, selector: selector, key: key) }
        let view = submenu("View")
        command(view, "Search Chats", .search, key: "f")
        command(view, "Toggle Sidebar", .sidebar, key: "s", modifiers: [.control, .command])
        command(view, "Show Inspector", .inspector, key: "i", modifiers: [.option, .command])
        command(view, context().terminalShown ? "Hide Terminal":"Show Terminal", .terminal, key: "j"); command(view, "Fully Focused", .fullyFocused)
        let chat = submenu("Conversation")
        command(chat, "Stop Response", .stop, key: "."); command(chat, "Focus Message Field", .focus, key: "l")
        command(chat, "Attach Files…", .attach, key: "a", modifiers: [.shift, .command]); command(chat, "Jump to Latest", .latest)
        chat.addItem(.separator()); command(chat, "Rename Chat…", .rename); command(chat, "Customize Chat…", .customize)
        command(chat, "Pin Chat", .pin); command(chat, "Mark as Unread", .unread, key: "u", modifiers: [.command, .shift])
        command(chat, "Archive Chat", .archive, key: "\u{8}")
        // Product puts layout commands in Conversation; keep that location and its exact default keys.
        chat.addItem(.separator()); addLayoutItems(to: chat)
        windowsMenu = submenu("Window")
        responder(windowsMenu, "Minimize", selector: "performMiniaturize:", key: "m"); responder(windowsMenu, "Zoom", selector: "performZoom:")
        windowsMenu.addItem(.separator()); command(windowsMenu, "Move Conversation to New Window", .moveWindow)
        command(windowsMenu, "Merge All Conversation Windows", .mergeWindows)
        windowsMenu.addItem(.separator())
        command(windowsMenu, "Collapse to Side", .collapse, key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command, .option])
        command(windowsMenu, "Restore Window", .restore, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command, .option])
        windowsMenu.addItem(.separator()); responder(windowsMenu, "Bring All to Front", selector: "arrangeInFront:")
        if !demo {
            let tools = submenu("Tools")
            command(tools, "Artifacts & Annotations…", .artifacts); command(tools, "Browser…", .browser); command(tools, "Appshots…", .appshots)
        }
        helpMenu = submenu("Help"); command(helpMenu, "Keyboard Shortcuts", .shortcuts, key: "/", modifiers: [.command, .shift])
        return root
    }
    private func addLayoutItems(to menu: NSMenu) {
        command(menu, "Focus Conversation", .focused, key: "\r", modifiers: [.command, .shift])
        command(menu, "Split with Next Conversation", .split, key: "\\", modifiers: [.command, .option])
        command(menu, "Next Split Pane", .nextPane, key: "\t", modifiers: .control)
        command(menu, "Previous Split Pane", .previousPane, key: "\t", modifiers: [.control, .shift])
        menu.addItem(.separator()); for n in 1...9 { command(menu, "Show Conversation \(n)", .member, key: String(n), tag: n-1) }
    }
    func makeAccountMenu(account: NormieAccount, quotaSummary: String, organic: Bool = false) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = true
        if organic {
            command(menu, "New Chat", .newChat); command(menu, "Show Sidebar", .sidebar); command(menu, "Collapse to Side", .collapse)
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: account.name+" · "+account.plan))
        command(menu, "Profile", .profile)
        command(menu, "Usage & Billing", .usage).subtitle = quotaSummary
        command(menu, "Settings…", .settings, key: ","); menu.addItem(.separator())
        command(menu, "Fully Focused", .fullyFocused).state = account.fullyFocused ? .on : .off
        menu.addItem(.separator()); command(menu, "Keyboard Shortcuts", .shortcuts)
        command(menu, "Help", .help); menu.addItem(.separator()); command(menu, "Sign Out…", .signOut)
        return menu
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let command = NormieCommand(rawValue: raw) else { return true }
        let c = context()
        if command == .terminal {item.title=c.terminalShown ? "Hide Terminal":"Show Terminal";item.state=c.terminalShown ? .on:.off}
        if command == .pin { item.title = c.pinned ? "Unpin Chat" : "Pin Chat" }
        if command == .sidebar { item.state = c.sidebarVisible ? .on : .off }
        if command == .inspector { item.state = c.inspectorVisible ? .on : .off }
        return c.enabled(command, tag: item.tag)
    }
    @objc private func fire(_ item: NSMenuItem) {
        guard validateMenuItem(item), let raw = item.representedObject as? String, let command = NormieCommand(rawValue: raw) else { return }
        perform(command, item.tag)
    }
    func applyShortcuts(_ bindings: [String: String], numberShortcuts: Bool = true) {
        guard let main else { return }
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { visit(sub) }
                if let id = item.identifier?.rawValue, id.hasPrefix("number.") { item.keyEquivalent = numberShortcuts ? String(item.tag+1) : "" }
                else if item.identifier?.rawValue.hasPrefix("shortcut.") == true,let raw = item.representedObject as? String, let binding = bindings[raw] {
                    (item.keyEquivalent, item.keyEquivalentModifierMask) = Self.keyEquivalent(binding)
                }
            }
        }
        visit(main)
    }
    static func keyEquivalent(_ combo: String) -> (String, NSEvent.ModifierFlags) {
        var rest = Substring(combo), modifiers: NSEvent.ModifierFlags = []
        let marks: [Character: NSEvent.ModifierFlags] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        while let first = rest.first, let flag = marks[first] { modifiers.insert(flag); rest = rest.dropFirst() }
        let names = ["⌫": "\u{8}", "⌦": "\u{7f}", "↩": "\r", "⇥": "\t", "Space": " ",
                     "←": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "→": String(UnicodeScalar(NSRightArrowFunctionKey)!),
                     "↑": String(UnicodeScalar(NSUpArrowFunctionKey)!), "↓": String(UnicodeScalar(NSDownArrowFunctionKey)!)]
        let key = String(rest)
        if key.isEmpty { return ("", []) }
        if let named = names[key] { return (named, modifiers) }
        if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...12).contains(n) { return (String(UnicodeScalar(NSF1FunctionKey+n-1)!), modifiers) }
        return (key.lowercased(), modifiers)
    }
}
