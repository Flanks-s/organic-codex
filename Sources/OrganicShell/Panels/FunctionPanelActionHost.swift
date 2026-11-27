import AppKit

/// Specialized fixture host only; no Scene, App, orb or Dock creates it.
@MainActor class FunctionPanelActionHost: FunctionPanelLiveHost {
    let commandOwner: FunctionPanelActionOwner
    init(conversation: Conversation, store: ConversationStore, resources: BodyResources, scale: Int,
         commands: FunctionPanelActionOwner, read: @escaping (FunctionPanelPage) -> FunctionPanelReadSources) {
        commandOwner = commands
        super.init(conversation: conversation, store: store, resources: resources, scale: scale, read: read)
        stage.onAction = { [weak self] action in
            guard let self else { return }
            if action == .closed { self.close(); return }
            self.commandOwner.submit(action)
        }
        stage.onIntent = { [weak commands] in commands?.beginIntent() }
        stage.onDismissFeedback = { [weak commands] in commands?.dismissFeedback() }
        commandOwner.onChange = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func decorate(_ input: FunctionPanelInput) -> FunctionPanelInput {
        var input = input; input.commands = commandOwner.value; return input
    }
    override func close() { commandOwner.onChange = nil; super.close() }
}
