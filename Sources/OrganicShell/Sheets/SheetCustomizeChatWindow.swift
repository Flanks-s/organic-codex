import AppKit

/// The product's window-sheet presentation. SheetCustomizeChat can also be mounted in a scene's modal plane.
@MainActor final class SheetCustomizeChatWindow {
    let sheet: SheetCustomizeChat
    private let factory: SheetWindowFactory
    private var handle: (any SheetWindowHandle)?
    private var generation: UUID?
    private var requestEpoch = 0
    var isShowing: Bool { handle != nil }
    var onDone: ((SheetChatCustomization) -> Void)?
    var onCancel: (() -> Void)?
    init(clock: any OverlayClock = OverlaySystemClock(), factory: @escaping SheetWindowFactory = { SheetAppKitWindow(configuration: $0, onClose: $1) }) {
        self.factory = factory; sheet = SheetCustomizeChat(clock: clock)
        sheet.onDone = { [weak self] in self?.finish(result: $0) }; sheet.onCancel = { [weak self] in self?.finish(result: nil) }
    }
    isolated deinit { handle?.dismiss() }
    func present(name: String, identity: OrbIdentity, level: Double, sheetFor parent: NSWindow) {
        present(name: name, identity: identity, level: level) { $0.presentSheet(for: parent) }
    }
    /// Factory/attach injection permits verification without constructing an NSWindow.
    func present(name: String, identity: OrbIdentity, level: Double, attach: (any SheetWindowHandle) -> Void) {
        requestEpoch += 1; let requestID = requestEpoch; finish(result: nil)
        guard requestEpoch == requestID else { return }
        let id = UUID(); generation = id
        let size = CGSize(width: 424, height: 374)
        let h = factory(.init(title: "Customize Chat", size: size, minimumSize: size, resizable: false)) { [weak self] in
            guard let self, self.generation == id else { return }; self.finish(result: nil, windowAlreadyClosed: true)
        }
        handle = h; sheet.present(name: name, identity: identity, level: level, in: h.host); attach(h)
        h.host.window?.makeFirstResponder(sheet.nameField)
    }
    func dismiss() { requestEpoch += 1; finish(result: nil) }
    private func finish(result: SheetChatCustomization?, windowAlreadyClosed: Bool = false) {
        guard let handle else { return }; self.handle = nil; generation = nil
        sheet.dismiss(reason: result == nil ? .cancelled : .confirmed, animated: false)
        if !windowAlreadyClosed { handle.dismiss() }
        if let result { onDone?(result) } else { onCancel?() }
    }
}
