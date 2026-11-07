import AppKit
import PDFKit
import QuartzCore

/// PDFKit owns page layout, text selection, Copy, zoom, scroll and the native PDF accessibility subtree.
/// No screenshot/text extraction surrogate and no PDF annotation editor is installed.
@MainActor final class ToolsPDFView: PDFView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoScales = true; displayMode = .singlePageContinuous
        backgroundColor = .clear
        setAccessibilityLabel("Read-only PDF preview")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    /// Retired PDF page layers may finish drawing in this CA commit. PDFPage does not retain its document.
    /// Keep that document alive through the commit instead of releasing it under a queued PDFKit draw.
    func replaceDocument(_ value: PDFDocument?) {
        guard document !== value else { return }
        let previous = document
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if previous != nil { CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} } }
        clearSelection(); document = value
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == NSSelectorFromString("setAccessibilityValue:") || selector == NSSelectorFromString("setAccessibilitySelectedText:") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 124 { goToNextPage(nil); return }
            if event.keyCode == 123 { goToPreviousPage(nil); return }
        }
        super.keyDown(with: event)
    }
}
