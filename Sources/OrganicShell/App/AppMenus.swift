import AppKit

extension AppController {
    /// One menu bar for every window; its commands go to the key window's workbench.
    func installMainMenu() {
        menus.context = { [weak self] in
            guard let self else { return NormieMenuContext(supported: []) }
            // Window selectors have no responder; New Chat remains an application command.
            guard let w = self.front else { return NormieMenuContext(supported: Self.applicationMenuCommands) }
            var c = w.workbench.menuContext
            c.inspectorVisible = w.shell.inspectorShown
            // A draft is what the commands are about, Collapse's or Organic's: none goes to the chat it covers (b052;
            // WindowModel.commandTarget is nil while composing; audit A03).
            if w.strip?.isDrafting == true || (w.shell.mode == .organic && w.scene.composingNew) {
                c.composingNew = true; c.hasConversation = false; c.running = false; c.canAttach = false
            }
            // Window commands need a conversation window in front (OWC canMoveConversationToNewWindow; audit A14).
            if !self.windows.contains(where: { $0.window === NSApp.keyWindow }) { c.supported.subtract([.moveWindow, .mergeWindows]) }
            return c
        }
        menus.perform = { [weak self] command, tag in self?.performMainMenu(command, tag: tag) }
        NSApp.mainMenu = menus.makeMainMenu(demo: false)
    }

    /// Product MainMenu targets the app delegate for these commands, independently of any chat window.
    static let applicationMenuCommands: Set<NormieCommand> = [.settings, .shortcuts, .artifacts, .browser, .appshots, .newChat]

    func performMainMenu(_ command: NormieCommand, tag: Int) {
        if command == .newChat, windows.isEmpty { _ = newChatWindow(); return }
        switch command {
        case .settings: settings?.show()
        case .shortcuts: settings?.show(pane: "shortcuts")
        case .artifacts, .browser, .appshots:
            let w = front
            let id = w.flatMap { $0.shell.mode == .organic ? $0.scene.focusTarget : $0.workbench.selectedConversation?.id }
            showTools(command == .artifacts ? .artifacts : command == .browser ? .browser : .capture, conversation: id)
        default:
            guard let w = front else { return }
            if command == .sidebar {
                ModeSignposts.withInput("menu.main.sidebar") { w.workbench.perform(command, tag: tag) }
            } else { w.workbench.perform(command, tag: tag) }
        }
    }
}
