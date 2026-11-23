import AppKit

/// A browser-local draft. It never borrows a conversation composer or a runtime submission callback.
@MainActor final class BrowserMockComposer: NSView {
    let field = NSTextField(string: "")
    private let send = NSButton(image: NSImage(systemSymbolName:"arrow.up",accessibilityDescription:"Send")!,target:nil,action:nil)
    var submit: ((String) -> Void)?
    override var isFlipped: Bool { true }
    init() {
        super.init(frame:.zero)
        field.isBordered=false;field.drawsBackground=false;field.focusRingType = .none
        field.placeholderString="Ask about this page…";field.font = .systemFont(ofSize:13);field.textColor = .white
        field.setAccessibilityLabel("Ask about this page")
        field.target=self;field.action=#selector(sendDraft)
        send.isBordered=false;send.target=self;send.action=#selector(sendDraft)
        addSubview(field);addSubview(send);setAccessibilityRole(.group);setAccessibilityLabel("Browser message")
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is unsupported")}
    override func layout() {
        super.layout();field.frame=CGRect(x:20,y:bounds.midY-10,width:max(1,bounds.width-64),height:22)
        send.frame=CGRect(x:bounds.width-38,y:bounds.midY-13,width:26,height:26)
    }
    override func draw(_ dirtyRect:NSRect) {
        BrowserPaint.plate(bounds,radius:bounds.height/2,color:NSColor.white.withAlphaComponent(0.06))
        BrowserPaint.plate(send.frame,radius:13,color:NSColor(srgbRed:66/255,green:178/255,blue:146/255,alpha:1))
    }
    @objc private func sendDraft() {
        let text=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else {return};submit?(text);field.stringValue=""
    }
    func sendForVerification() {sendDraft()}
    func setInteractive(_ interactive:Bool) {field.isEnabled=interactive;send.isEnabled=interactive;setAccessibilityHidden(!interactive)}
    func retire() {submit=nil;setAccessibilityHidden(true);removeFromSuperview()}
}
