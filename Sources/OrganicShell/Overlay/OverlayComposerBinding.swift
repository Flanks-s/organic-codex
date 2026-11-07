import AppKit

/// Opt-in pointer and keyboard adapter. Retain with the scene; disconnect before retiring its composer or modal host.
/// No NativeComposer source/target/menu is changed. Keyboard Send keeps its existing editor path.
@MainActor final class OverlayComposerBinding {
    let modelPicker: OverlayModelPicker
    let sendOptions: OverlaySendOptions
    private weak var composer: NativeComposer?
    private weak var host: NSView?
    private var monitor: Any?
    private(set) var isConnected = true
    private(set) var capturesSendPress = false
    /// Share the host window's Engine clock. No extra frame callback/display link is installed.
    func bindSceneClock(_ scene: SceneClock, now: (() -> Double)? = nil) {
        modelPicker.sceneClock=scene; sendOptions.sceneClock=scene
        modelPicker.sceneTime=now; sendOptions.sceneTime=now
    }
    init(composer: NativeComposer, host: NSView, clock: any OverlayClock = OverlaySystemClock()) {
        self.composer = composer; self.host = host
        modelPicker = OverlayModelPicker(clock: clock); sendOptions = OverlaySendOptions(clock: clock)
        modelPicker.onSettingsChange = { [weak composer] in composer?.setSettings($0) }
        sendOptions.canSend = { [weak composer] in guard let composer else { return false }; return composer.superview != nil && !composer.isHiddenOrHasHiddenAncestor && composer.canSend && composer.window?.isKeyWindow != false }
        sendOptions.onShortPress = { [weak composer] in _ = composer?.submit() }
        sendOptions.onSelect = { [weak composer] in _ = composer?.submit(followUp: $0) }
        sendOptions.onPressStateChange = { [weak composer] pressed in
            guard let button = composer?.sendButton else { return }
            button.wantsLayer = true
            guard let layer = button.layer else { return }
            let scale: CGFloat = pressed ? 0.88 : 1
            let x = (1 - scale) * button.bounds.width * (0.5 - layer.anchorPoint.x)
            let y = (1 - scale) * button.bounds.height * (0.5 - layer.anchorPoint.y)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (key, target) in [("transform.scale", scale), ("transform.translation.x", x), ("transform.translation.y", y)] {
                let spring = OverlayMotion.pressSpring(); spring.keyPath = key
                spring.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key); spring.toValue = target
                layer.setValue(target, forKeyPath: key)
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { layer.add(spring, forKey: "overlay.send.press." + key) }
            }
            CATransaction.commit()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
    }
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        sendOptions.cancelPress(); sendOptions.dismiss(); modelPicker.dismiss()
    }
    func disconnect() {
        isConnected = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        sendOptions.cancelPress(); sendOptions.dismiss(); modelPicker.dismiss(); capturesSendPress = false
    }
    private var canPresentModelPicker: Bool {
        guard isConnected, let composer, let host, !host.isHiddenOrHasHiddenAncestor, composer.superview != nil,
              composer.isPresentationVisible, composer.modelButton.isEnabled, NativeInteractionSurface.permits(composer.modelButton),
              composer.canEditOptions, !capturesSendPress, !sendOptions.isShowing else { return false }
        return true
    }
    @discardableResult func presentModelPicker() -> Bool {
        guard canPresentModelPicker, let composer, let host else { return false }
        modelPicker.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        modelPicker.configure(settings: composer.settings, base: composer.baseSettings)
        modelPicker.present(anchor: host.convert(composer.modelButton.bounds, from: composer.modelButton), in: host)
        return true
    }
    /// Point coordinates are host bounds coordinates; also used by deterministic offscreen integration checks.
    @discardableResult func pointerDown(at point: CGPoint) -> Bool {
        guard isConnected, let composer, let host, composer.superview != nil, composer.isPresentationVisible, !modelPicker.isShowing, !sendOptions.isShowing else { return false }
        if !composer.modelButton.isHidden, host.convert(composer.modelButton.bounds, from: composer.modelButton).contains(point) { return presentModelPicker() }
        if !composer.sendButton.isHidden, composer.canSend, host.convert(composer.sendButton.bounds, from: composer.sendButton).contains(point) {
            sendOptions.running = composer.state.running; sendOptions.defaultChoice = composer.followUpDefault
            sendOptions.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            capturesSendPress = sendOptions.beginPress(anchor: host.convert(composer.sendButton.bounds, from: composer.sendButton), in: host, pointer: point)
            return capturesSendPress
        }
        return false
    }
    /// Called before NSControl.keyDown so Model uses the same lyric picker as pointer activation.
    /// The event monitor supplies the owning window's first responder. Injection also permits windowless checks.
    @discardableResult func keyDown(with event: NSEvent, firstResponder: NSResponder?) -> Bool {
        guard isConnected, event.type == .keyDown, let composer, firstResponder === composer.modelButton,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let activates = [UInt16(36), 76, 49, 125].contains(event.keyCode)
        if modelPicker.isShowing {
            if modelPicker.isDismissing { return activates || OverlayKey.from(code: event.keyCode, modifiers: event.modifierFlags) != nil }
            if let key = OverlayKey.from(code: event.keyCode, modifiers: event.modifierFlags) { return modelPicker.handleKey(key) }
            return activates // Space must not fall through into the native menu while the picker is open.
        }
        guard activates, canPresentModelPicker else { return false }
        // Holding Return/Space through dismissal must not immediately reopen the picker.
        if event.isARepeat { return true }
        return presentModelPicker()
    }
    @discardableResult func pointerDragged(at point: CGPoint) -> Bool {
        guard capturesSendPress else { return false }; sendOptions.continuePress(at: point); return true
    }
    @discardableResult func pointerUp(at point: CGPoint) -> Bool {
        guard capturesSendPress else { return false }; capturesSendPress = false; sendOptions.endPress(at: point); return true
    }
    @discardableResult func cancelGesture() -> Bool {
        guard capturesSendPress || sendOptions.isShowing else { return false }
        sendOptions.cancelPress(); sendOptions.dismiss(reason: .escape); return true
    }
    private func consume(_ event: NSEvent) -> Bool {
        guard isConnected, let host else { return false }
        guard let window = host.window, event.window === window else {
            if capturesSendPress { sendOptions.cancelPress(); if event.type == .leftMouseUp { capturesSendPress = false } }
            return false
        }
        let point = host.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown: return pointerDown(at: point)
        case .leftMouseDragged: return pointerDragged(at: point)
        case .leftMouseUp: return pointerUp(at: point)
        case .keyDown:
            if keyDown(with: event, firstResponder: window.firstResponder) { return true }
            return OverlayKey.from(code: event.keyCode, modifiers: event.modifierFlags) == .escape && cancelGesture()
        case .rightMouseDown where capturesSendPress, .otherMouseDown where capturesSendPress: return cancelGesture()
        default: return false
        }
    }
}
