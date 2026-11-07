import AppKit
#if canImport(SwiftTerm)
import SwiftTerm
#endif

/// Native fallback, explicitly labelled as limited ANSI. SwiftTerm is selected automatically when linked by App.
@MainActor final class ToolsTerminalView:ToolsView {
    private(set) var buffer=ToolsTerminalBuffer()
    var onInput:((String)->Void)?,onSize:((Int,Int)->Void)?,onTitle:((String)->Void)?,onDirectory:((String)->Void)?
    private var scroll=0,selectionStart:Int?,selectionEnd:Int?
    let font=NSFont.monospacedSystemFont(ofSize:12,weight:.regular)
    var cellSize:CGSize { CGSize(width:ceil(("M" as NSString).size(withAttributes:[.font:font]).width*pixelScale)/pixelScale,height:ceil((font.ascender-font.descender+3)*pixelScale)/pixelScale) }
    override init(frame:NSRect) { super.init(frame:frame); setAccessibilityElement(true); setAccessibilityRole(.textArea); setAccessibilityLabel("Terminal"); setAccessibilityHelp("Interactive shell. Type commands here; use the session toolbar to end the session.") }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder:Bool { true }
    func feed(_ value:String,reset:Bool=false) { if reset { buffer.reset() }; buffer.feed(value); scroll=0; if let title=buffer.title { onTitle?(title) }; if let directory=buffer.directory { onDirectory?(directory) }; needsDisplay=true }
    override func layout() { super.layout(); let size=cellSize,cols=max(1,Int((bounds.width-16)/size.width)),rows=max(1,Int((bounds.height-16)/size.height)); if cols != buffer.columns || rows != buffer.rows { buffer.resize(columns:cols,rows:rows); onSize?(cols,rows); needsDisplay=true } }
    static func color(_ value:Int)->NSColor {
        let base:[NSColor]=[NSColor(white:0.06,alpha:1),.systemRed,.systemGreen,.systemYellow,.systemBlue,.systemPurple,.systemCyan,NSColor(white:0.85,alpha:1),.darkGray,.red,.green,.yellow,.blue,.magenta,.cyan,.white]
        if value<16 { return base[max(0,value)] }
        if value>=232 { return NSColor(white:CGFloat(8+(min(255,value)-232)*10)/255,alpha:1) }
        let index=value-16
        let levels:[Int]=[index/36,(index/6)%6,index%6]
        let components:[CGFloat]=levels.map { value in value == 0 ? 0:CGFloat(55+value*40)/255 }
        return NSColor(srgbRed:components[0],green:components[1],blue:components[2],alpha:1)
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(white:0.055,alpha:1).setFill(); bounds.fill()
        let cell=cellSize,all=buffer.scrollback+buffer.screen,end=max(0,all.count-scroll),start=max(0,end-buffer.rows)
        for (y,row) in all[start..<end].enumerated() {
            for (x,value) in row.enumerated() {
                let rect=CGRect(x:8+CGFloat(x)*cell.width,y:8+CGFloat(y)*cell.height,width:cell.width,height:cell.height)
                if value.background != 0 { Self.color(value.background).setFill(); rect.fill() }
                (value.text as NSString).draw(in:rect,withAttributes:[.font:value.bold ? NSFont.monospacedSystemFont(ofSize:12,weight:.bold):font,.foregroundColor:Self.color(value.foreground)])
            }
        }
        if scroll == 0 { NSColor.secondaryLabelColor.setStroke(); NSBezierPath(rect:CGRect(x:8+CGFloat(min(buffer.cursorX,buffer.columns-1))*cell.width,y:8+CGFloat(buffer.cursorY)*cell.height,width:cell.width,height:cell.height)).stroke() }
    }
    func input(for event:NSEvent)->String? {
        if event.modifierFlags.contains(.command) { return nil }
        let special:[UInt16:String]=[36:"\r",48:"\t",51:"\u{7f}",53:"\u{1b}",123:"\u{1b}[D",124:"\u{1b}[C",125:"\u{1b}[B",126:"\u{1b}[A",115:"\u{1b}[H",119:"\u{1b}[F",116:"\u{1b}[5~",121:"\u{1b}[6~",117:"\u{1b}[3~"]
        if let value=special[event.keyCode] { return value }
        if event.modifierFlags.contains(.control),let scalar=event.charactersIgnoringModifiers?.unicodeScalars.first,scalar.value<128 { return String(UnicodeScalar(scalar.value&0x1f)!) }
        guard let text=event.characters else { return nil }; return event.modifierFlags.contains(.option) ? "\u{1b}"+text:text
    }
    override func keyDown(with event:NSEvent) { if let text=input(for:event) { onInput?(text) } else { super.keyDown(with:event) } }
    @objc func paste(_ sender:Any?) { if let text=NSPasteboard.general.string(forType:.string) { onInput?(text) } }
    @objc func copy(_ sender:Any?) { let text=selectedText; if !text.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) } }
    override func selectAll(_ sender:Any?) { selectionStart=0; selectionEnd=selectionDocument.count }
    var selectedText:String { let text=selectionDocument; guard let a=selectionStart,let b=selectionEnd else { return "" }; return String(text.dropFirst(min(a,b)).prefix(abs(b-a))) }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); selectionStart=offset(at:convert(event.locationInWindow,from:nil)); selectionEnd=selectionStart }
    override func mouseDragged(with event:NSEvent) { selectionEnd=offset(at:convert(event.locationInWindow,from:nil)); needsDisplay=true }
    private var selectionLines:[String] { (buffer.scrollback+buffer.screen).map { $0.map(\.text).joined().replacingOccurrences(of:#" +$"#,with:"",options:.regularExpression) } }
    private var selectionDocument:String { selectionLines.joined(separator:"\n") }
    private func offset(at point:CGPoint)->Int {
        let cell=cellSize,lines=selectionLines,end=max(0,lines.count-scroll),start=max(0,end-buffer.rows)
        let row=min(max(0,lines.count-1),start+max(0,Int((point.y-8)/cell.height)))
        return lines.prefix(row).reduce(0) { $0+$1.count+1 }+min(lines[row].count,max(0,Int((point.x-8)/cell.width)))
    }
    override func scrollWheel(with event:NSEvent) { scroll=min(buffer.scrollback.count,max(0,scroll+Int(event.scrollingDeltaY))); needsDisplay=true }
    override func accessibilityValue()->Any? { String(buffer.text.suffix(65536)) }
    override func accessibilityPerformPress()->Bool { window?.makeFirstResponder(self) ?? false }
    override func isAccessibilitySelectorAllowed(_ selector:Selector)->Bool { selector != NSSelectorFromString("setAccessibilityValue:") && super.isAccessibilitySelectorAllowed(selector) }
}

@MainActor final class ToolsTerminalSurface:ToolsView {
    #if canImport(SwiftTerm)
    // Match product's initial viewport: replay can arrive before the first host layout.
    // A zero-size TerminalView parses that history into a one-cell grid before it can reflow.
    let terminal=ToolsSwiftTermView(frame:CGRect(x:0,y:0,width:720,height:240),font:.monospacedSystemFont(ofSize:12,weight:.regular))
    static let fullVTCompatibility=true
    #else
    let terminal=ToolsTerminalView(frame:.zero)
    static let fullVTCompatibility=false
    #endif
    private weak var session:CoreTerminalSession?
    private var observer:UUID?
    override init(frame:NSRect) {
        super.init(frame:frame); addSubview(terminal)
        #if canImport(SwiftTerm)
        terminal.terminalDelegate=self; terminal.nativeBackgroundColor=NSColor(white:0.055,alpha:1); terminal.nativeForegroundColor = .textColor; terminal.suspendsRenderingWhenNotVisible=true
        #else
        terminal.onInput={ [weak self] in self?.session?.send($0) }; terminal.onSize={ [weak self] in self?.session?.resize(columns:$0,rows:$1) }
        terminal.onTitle={ [weak self] in self?.session?.setTitle($0) }; terminal.onDirectory={ [weak self] in self?.session?.updateDirectory($0) }
        #endif
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { if let observer { session?.removeOutputObserver(observer) } }
    func bind(_ next:CoreTerminalSession) {
        guard session !== next else { return }; if let observer { session?.removeOutputObserver(observer) }; session=next
        observer=next.observeOutput { [weak self] value in
            #if canImport(SwiftTerm)
            if value.reset { self?.terminal.feed(text:"\u{1b}c") }; self?.terminal.feed(text:value.text)
            #else
            self?.terminal.feed(value.text,reset:value.reset)
            #endif
        }
    }
    override func layout() { super.layout(); place(terminal,bounds) }
}
#if canImport(SwiftTerm)
// SwiftTerm already draws its buffer in its own non-open NSView.draw override (no AppKit text cell path).
final class ToolsSwiftTermView:TerminalView {
    override func isAccessibilityElement()->Bool { true }
    override func accessibilityRole()->NSAccessibility.Role? { .textArea }
    override func accessibilityLabel()->String? { "Terminal" }
    override func accessibilityValue()->Any? { String(String(decoding:getBufferAsData(),as:UTF8.self).suffix(65536)) }
    override func isAccessibilitySelectorAllowed(_ selector:Selector)->Bool { selector != NSSelectorFromString("setAccessibilityValue:") && super.isAccessibilitySelectorAllowed(selector) }
    override func accessibilityPerformPress()->Bool { window?.makeFirstResponder(self) ?? false }
}
extension ToolsTerminalSurface:TerminalViewDelegate {
    func send(source:TerminalView,data:ArraySlice<UInt8>) { session?.send(String(decoding:data,as:UTF8.self)) }
    func sizeChanged(source:TerminalView,newCols:Int,newRows:Int) { session?.resize(columns:newCols,rows:newRows) }
    func setTerminalTitle(source:TerminalView,title:String) { session?.setTitle(title) }
    func hostCurrentDirectoryUpdate(source:TerminalView,directory:String?) { session?.updateDirectory(directory) }
    func scrolled(source:TerminalView,position:Double) {}
    func rangeChanged(source:TerminalView,startY:Int,endY:Int) {}
}
#endif
