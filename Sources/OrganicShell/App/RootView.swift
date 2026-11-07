import AppKit

final class RootView: NSView {
    weak var owner: OrganicWindow?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A press on a dock node may become a queue drag: the click waits for the release.
    private var pressed = false
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if owner?.scene.peekClick(at: p) == true { return }
        pressed = owner?.scene.pointerDown(p) ?? false
        if pressed { owner?.scene.pressFromPointer = true } else { owner?.click(p) }
    }
    override func mouseDragged(with event: NSEvent) { if pressed { owner?.scene.pointerDragged(convert(event.locationInWindow, from: nil)) } }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        let p = convert(event.locationInWindow, from: nil)
        if owner?.scene.pressCancelled == true { return }
        if owner?.scene.pointerUp(p) == false { owner?.click(p) }
    }
    override func cancelOperation(_ sender: Any?) {
        // The press ends here: its mouse-up must not become a click on whatever is under it now (TearSession consumed).
        if pressed { pressed = false }
        owner?.scene.cancelDrag()
    }
    /// Right-click on the dock: me's account menu, or the node's (f073).
    override func rightMouseDown(with event: NSEvent) {
        guard let owner, owner.shell.mode == .organic, let menu = owner.scene.contextMenu(at: convert(event.locationInWindow, from: nil)) else {
            super.rightMouseDown(with: event); return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    /// Smart zoom on the dock: Collapse to the node under the pointer, else to the shown conversation (f050).
    override func smartMagnify(with event: NSEvent) {
        guard let owner, owner.shell.mode == .organic else { return }
        let p = convert(event.locationInWindow, from: nil)
        owner.collapseToSide(owner.scene.dockNode(at: p) ?? owner.scene.focusTarget)
    }
    override func scrollWheel(with event: NSEvent) {
        // A replay that reaches a scroll boundary may bubble back here. Its original Peek/queue arbitration already ran.
        if ColumnTranscriptHandoff.replayDepth>0 {super.scrollWheel(with:event);return}
        if owner?.scene.queueSwipe(event, at: convert(event.locationInWindow, from: nil)) == true { return }
        if owner?.scene.peekScroll(event.scrollingDeltaY, at: convert(event.locationInWindow, from: nil)) == true { return }
        if owner?.shell.mode == .organic, owner?.scene.transcriptWheel(event, at: convert(event.locationInWindow, from: nil)) == true { return }
        super.scrollWheel(with: event)
    }
    /// Force Click on an orb peeks at once (Settings ▸ Organic ▸ Force Click to Peek, on by default; f045).
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, UserDefaults.standard.object(forKey: "toggle.forceClickPeek") as? Bool ?? true else { return }
        owner?.scene.forcePeek(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseMoved(with event: NSEvent) { owner?.hover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { owner?.scene.pointer(nil) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func keyDown(with event: NSEvent) { if owner?.key(event) != true { super.keyDown(with: event) } }
}
