import AppKit

extension NSAttributedString.Key {
    static let transcriptReference = NSAttributedString.Key("organic.transcript.reference")
}

/// Mounted only by a host with onReference. It never changes the shared text storage or glyph layout.
@MainActor final class NativeReferenceInteraction: NSView, NSViewToolTipOwner, NativePointerHoverClient {
    struct Hit { let target: ReferenceTarget; let range: NSRange; let rect: CGRect }
    private(set) var hits: [Hit] = []
    private var callback: ((ReferenceTarget, NSRange) -> Void)?
    private var generation = 0, focused = 0
    weak var body: NativeTranscriptTextView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { permits() && hits.contains { $0.rect.intersects(visibleRect) } }
    override func becomeFirstResponder() -> Bool {
        guard permits(), let index = hits.firstIndex(where: { $0.rect.intersects(visibleRect) }) else { return false }
        if !hits.indices.contains(focused) || !hits[focused].rect.intersects(visibleRect) { focused = index }
        needsDisplay = true; return true
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self, permits(), hits.indices.contains(focused) {
            NSColor.keyboardFocusIndicatorColor.setStroke(); NSBezierPath(rect: hits[focused].rect.insetBy(dx: -1, dy: -1)).stroke()
        }
    }
    func configure(body: NativeTranscriptTextView, action: @escaping (ReferenceTarget, NSRange) -> Void) {
        revoke(); self.body = body; callback = action; frame = body.frame
        guard let storage = body.textStorage, let layout = body.layoutManager, let container = body.textContainer else { return }
        layout.ensureLayout(for: container)
        storage.enumerateAttribute(.transcriptReference, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let raw = value as? String, let target = ReferenceTarget(raw) else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let clipped = rect.intersection(body.bounds)
                if !clipped.isEmpty { self.hits.append(Hit(target: target, range: range, rect: clipped)) }
            }
        }
        for hit in hits { addToolTip(hit.rect, owner: self, userData: nil) }
        focused = min(focused, max(0, hits.count - 1))
        needsDisplay = true; window?.invalidateCursorRects(for: self)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Message references")
    }
    func revoke() {
        generation += 1; callback = nil; hits = []; removeAllToolTips()
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        permits(point) ? hits.first(where: { $0.rect.contains(point) })?.target.raw ?? "" : ""
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard permits(point), let index = hits.firstIndex(where: { $0.rect.contains(point) }) else { return nil }
        focused = index
        let menu = NSMenu(), item = NSMenuItem(title: "Copy Reference", action: #selector(copy(_:)), keyEquivalent: "")
        item.target = self; menu.addItem(item); return menu
    }
    private func permits(_ point: CGPoint? = nil) -> Bool {
        guard callback != nil, let body, !body.isHiddenOrHasHiddenAncestor,
              NativeInteractionSurface.permits(self) else { return false }
        if let point { return visibleRect.contains(point) && NativePointerShield.permits(self, localPoint: point) }
        return NativePointerShield.permits(self)
    }
    func reconcilePointerHover(_ point: CGPoint?) { window?.invalidateCursorRects(for: self) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return permits(local) && hits.contains(where: { $0.rect.contains(local) }) ? self : nil
    }
    override func resetCursorRects() {
        guard permits() else { return }
        for hit in hits { addCursorRect(hit.rect.intersection(visibleRect), cursor: .pointingHand) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard permits(point), let index = hits.firstIndex(where: { $0.rect.contains(point) }) else { return }
        focused = index; window?.makeFirstResponder(self); activate(index)
    }
    private func activate(_ index: Int) {
        guard permits(), hits.indices.contains(index) else { return }
        let hit = hits[index]; callback?(hit.target, hit.range)
    }
    override func keyDown(with event: NSEvent) {
        guard permits(), !hits.isEmpty else { return }
        if event.keyCode == 36 || event.keyCode == 49 { activate(focused) }
        else if event.keyCode == 123 || event.keyCode == 124 {
            focused = (focused + (event.keyCode == 124 ? 1 : hits.count - 1)) % hits.count
            body?.scrollRangeToVisible(hits[focused].range); needsDisplay = true
        }
        else { super.keyDown(with: event) }
    }
    @objc func copy(_ sender: Any?) {
        guard permits(), hits.indices.contains(focused) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hits[focused].target.raw, forType: .string)
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard permits() else { return nil }
        let epoch = generation
        return hits.enumerated().filter { $0.element.rect.intersects(visibleRect) }.flatMap { index, hit in [
            NSAccessibilityCustomAction(name: "Open " + hit.target.raw, handler: { [weak self] in
                guard let self, self.generation == epoch, self.permits() else { return false }
                self.activate(index); return true
            }),
            NSAccessibilityCustomAction(name: "Copy " + hit.target.raw, handler: { [weak self] in
                guard let self, self.generation == epoch, self.permits() else { return false }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hit.target.raw, forType: .string); return true
            })]
        }
    }
}
