import AppKit

/// Paint-only retirement. There are no controls, accessibility elements, subscriptions or clocks in this view.
@MainActor final class BrowserDockExitPicture: NSView {
    let image: CGImage
    override var isFlipped: Bool {true}
    init(image:CGImage,frame:CGRect) {self.image=image;super.init(frame:frame);setAccessibilityHidden(true)}
    required init?(coder:NSCoder) {fatalError("init(coder:) is unsupported")}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        NSImage(cgImage:image,size:bounds.size).draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
}
