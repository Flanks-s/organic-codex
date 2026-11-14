import AppKit

/// Background pictures yield their epoch before AppKit dispatches input to a native control.
@MainActor class ModeContentWindow:NSWindow {
    private var modeShell:WindowShell? {contentViewController as? WindowShell}

    override func sendEvent(_ event:NSEvent) {
        switch event.type {
        case .leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,
             .leftMouseDragged,.rightMouseDragged,.otherMouseDragged,
             .keyDown,.keyUp,.scrollWheel,.magnify,.smartMagnify,.rotate,.swipe,
             .beginGesture,.endGesture:
            // Key releases belong to the responder; hover, modifiers and tablet telemetry can wait.
            modeShell?.prepareForContentInput()
        case .pressure where event.stage == 2:
            // RootView turns the force-click stage into an immediate Peek action.
            modeShell?.prepareForContentInput()
        default:break
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder:NSResponder?)->Bool {
        if responder !== firstResponder {modeShell?.prepareForContentInput()}
        return super.makeFirstResponder(responder)
    }

    override func performKeyEquivalent(with event:NSEvent)->Bool {
        modeShell?.prepareForContentInput()
        return super.performKeyEquivalent(with:event)
    }
}
