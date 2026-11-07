import AppKit

/// Quantize reading positions as well as frames; rubber-band proposals still go through AppKit's constraints.
final class ToolsClipView:NSClipView {
    var pixelScale:CGFloat {
        var ancestor=superview
        while let current=ancestor { if let view=current as? ToolsView { return view.pixelScale }; ancestor=current.superview }
        return window?.backingScaleFactor ?? 2
    }
    override func constrainBoundsRect(_ proposedBounds:NSRect)->NSRect {
        var rect=super.constrainBoundsRect(proposedBounds)
        let s=max(1,pixelScale); rect.origin.x=(rect.origin.x*s).rounded()/s; rect.origin.y=(rect.origin.y*s).rounded()/s
        return rect
    }
    override func scroll(to newOrigin:NSPoint) {
        var proposed=bounds; proposed.origin=newOrigin
        super.scroll(to:constrainBoundsRect(proposed).origin)
    }
}
final class ToolsScrollView:NSScrollView {
    override init(frame:NSRect) { super.init(frame:frame); contentView=ToolsClipView(); borderType = .noBorder }
    convenience init() { self.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor class ToolsView:NSView {
    private var displayObservation:UUID?
    var verificationScale:CGFloat?
    var pixelScale:CGFloat { verificationScale ?? window?.backingScaleFactor ?? 2 }
    override var isFlipped:Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer=true; appearance=NSAppearance(named:ToolsDisplayEnvironment.shared.options.increaseContrast ? .accessibilityHighContrastDarkAqua:.darkAqua); autoresizesSubviews=false
        displayObservation=ToolsDisplayEnvironment.shared.observe { [weak self] in self?.displayOptionsDidChange() }
    }
    isolated deinit { if let displayObservation { ToolsDisplayEnvironment.shared.removeObserver(displayObservation) } }
    func displayOptionsDidChange() {
        appearance=NSAppearance(named:ToolsDisplayEnvironment.shared.options.increaseContrast ? .accessibilityHighContrastDarkAqua:.darkAqua)
        func invalidate(_ view:NSView) { view.needsDisplay=true; for child in view.subviews { invalidate(child) } }
        invalidate(self)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func place(_ view:NSView,_ rect:CGRect) { view.frame=Self.aligned(rect,scale:pixelScale) }
    static func aligned(_ r:CGRect,scale:CGFloat)->CGRect {
        let s=max(1,scale),x=(r.minX*s).rounded()/s,y=(r.minY*s).rounded()/s
        return CGRect(x:x,y:y,width:(r.maxX*s).rounded()/s-x,height:(r.maxY*s).rounded()/s-y)
    }
    override func draw(_ dirtyRect:NSRect) { super.draw(dirtyRect) }
    func snapshot(scale:CGFloat)->CGImage {
        layoutSubtreeIfNeeded(); displayIfNeeded()
        let rep=bitmapImageRepForCachingDisplay(in:bounds) ?? NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:max(1,Int(bounds.width*scale)),pixelsHigh:max(1,Int(bounds.height*scale)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        // Offscreen AppKit otherwise chooses the default display scale. Preserve the same cacheDisplay drawing path.
        let target:NSBitmapImageRep
        if rep.pixelsWide != Int(bounds.width*scale) || rep.pixelsHigh != Int(bounds.height*scale) {
            target=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:max(1,Int(bounds.width*scale)),pixelsHigh:max(1,Int(bounds.height*scale)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:rep.colorSpaceName,bytesPerRow:0,bitsPerPixel:0)!
        } else { target=rep }
        target.size=bounds.size; cacheDisplay(in:bounds,to:target); return target.cgImage!
    }
}
final class ToolsLabel:NSTextField {
    init(_ text:String="",size:CGFloat=12,weight:NSFont.Weight = .regular) {
        super.init(frame:.zero); stringValue=text; font = .systemFont(ofSize:size,weight:weight)
        isEditable=false; isSelectable=false; isBordered=false; isBezeled=false; drawsBackground=false
        lineBreakMode = .byTruncatingTail; maximumNumberOfLines=1; textColor = .labelColor
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) { super.draw(dirtyRect) }
}
final class ToolsButton:NSButton {
    var invoke:(()->Void)?
    var active=false { didSet { needsDisplay=true } }
    init(_ text:String,_ action:(()->Void)?=nil) {
        super.init(frame:.zero); title=text; invoke=action; isBordered=false; bezelStyle = .regularSquare
        target=self; self.action=#selector(activate); font = .systemFont(ofSize:12,weight:.semibold)
        setAccessibilityLabel(text)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() { guard isEnabled else { return }; invoke?() }
    override func performClick(_ sender:Any?) { activate() }
    override func accessibilityLabel()->String? { title }
    override func accessibilityPerformPress()->Bool { guard isEnabled,invoke != nil else { return false }; activate(); return true }
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:7,yRadius:7)
        (active ? ToolsDisplayEnvironment.surface(.controlAccentColor,opacity:0.28):ToolsDisplayEnvironment.surface(.white,opacity:isHighlighted ? 0.15:0.07)).setFill(); path.fill()
        let style=NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        let f=font ?? .systemFont(ofSize:12),h=f.ascender-f.descender
        (title as NSString).draw(in:CGRect(x:5,y:(bounds.height-h)/2,width:max(0,bounds.width-10),height:h+2),withAttributes:[.font:f,.foregroundColor:isEnabled ? NSColor.labelColor:NSColor.tertiaryLabelColor,.paragraphStyle:style])
    }
}
final class ToolsField:NSTextField,NSTextFieldDelegate {
    var onEdit:((String)->Void)?,onReturn:(()->Void)?
    init(_ placeholder:String) {
        super.init(frame:.zero); placeholderString=placeholder; font = .systemFont(ofSize:12)
        isBordered=false; isBezeled=false; drawsBackground=false; focusRingType = .none; delegate=self
        setAccessibilityLabel(placeholder)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) {
        ToolsDisplayEnvironment.surface(.white,opacity:0.055).setFill(); NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill(); super.draw(dirtyRect)
    }
    func controlTextDidChange(_ obj:Notification) { onEdit?(stringValue) }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onReturn?(); return true }; return false
    }
    func update(_ text:String) { if currentEditor() == nil && stringValue != text { stringValue=text } }
}
final class ToolsTextView:NSTextView,NSTextViewDelegate {
    private let retainedStorage:NSTextStorage?
    private let retainedManager:NSLayoutManager?
    var onQuote:((String)->Void)?
    override init(frame:NSRect,textContainer:NSTextContainer?=nil) {
        let container:NSTextContainer
        if let textContainer { container=textContainer; retainedManager=textContainer.layoutManager; retainedStorage=textContainer.layoutManager?.textStorage }
        else {
            let storage=NSTextStorage(),manager=NSLayoutManager(); retainedStorage=storage; retainedManager=manager
            container=NSTextContainer(size:CGSize(width:max(1,frame.width),height:CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(container)
        }
        super.init(frame:frame,textContainer:container); isEditable=false; isSelectable=true; drawsBackground=false
        font = .monospacedSystemFont(ofSize:12,weight:.regular); textColor = .labelColor; delegate=self
        textContainerInset=CGSize(width:8,height:8); isHorizontallyResizable=false; isVerticallyResizable=true
        self.textContainer?.widthTracksTextView=true; maxSize=CGSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude); setAccessibilityLabel("Read-only preview")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) { super.draw(dirtyRect) }
    override func isAccessibilitySelectorAllowed(_ selector:Selector)->Bool {
        if selector == NSSelectorFromString("setAccessibilityValue:") { return false }; return super.isAccessibilitySelectorAllowed(selector)
    }
    func textViewDidChangeSelection(_ notification:Notification) {
        let r=selectedRange(); if r.length>0,NSMaxRange(r)<=(string as NSString).length { onQuote?((string as NSString).substring(with:r)) }
    }
    func fit(in scroll:NSScrollView,scale:CGFloat) {
        guard let textContainer,let layoutManager else { return }
        let s=max(1,scale),width=(scroll.contentSize.width*s).rounded()/s
        textContainer.containerSize=CGSize(width:max(1,width),height:CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for:textContainer)
        let height=max(scroll.contentSize.height,layoutManager.usedRect(for:textContainer).height+2*textContainerInset.height)
        frame=CGRect(x:0,y:0,width:width,height:ceil(height*s)/s)
    }
}
@MainActor final class ToolsList:ToolsView {
    struct Row:Equatable { var id:String,title:String,detail:String }
    var rows:[Row]=[] { didSet { if oldValue != rows { frame.size.height=max(1,CGFloat(rows.count)*rowHeight); needsDisplay=true } } }
    var selectedID:String? { didSet { needsDisplay=true } }
    var onSelect:((String)->Void)?
    let rowHeight:CGFloat=54
    override var acceptsFirstResponder:Bool { true }
    override init(frame:NSRect) { super.init(frame:frame); setAccessibilityElement(true); setAccessibilityRole(.list); setAccessibilityLabel("Tools items") }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func select(_ index:Int) {
        guard rows.indices.contains(index) else { return }; selectedID=rows[index].id
        scrollToVisible(CGRect(x:0,y:CGFloat(index)*rowHeight,width:bounds.width,height:rowHeight)); onSelect?(rows[index].id)
    }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); select(Int(convert(event.locationInWindow,from:nil).y/rowHeight)) }
    override func keyDown(with event:NSEvent) {
        let index=rows.firstIndex { $0.id == selectedID } ?? -1
        switch event.keyCode {
        case 125: select(min(rows.count-1,index+1))
        case 126: select(max(0,index-1))
        case 36: if index>=0 { select(index) }
        case 115: select(0)
        case 119: select(rows.count-1)
        default: super.keyDown(with:event)
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        for (i,row) in rows.enumerated() {
            let rect=CGRect(x:0,y:CGFloat(i)*rowHeight,width:bounds.width,height:rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            if row.id == selectedID { ToolsDisplayEnvironment.surface(.controlAccentColor,opacity:0.22).setFill(); NSBezierPath(roundedRect:rect.insetBy(dx:2,dy:2),xRadius:7,yRadius:7).fill() }
            let style=NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (row.title as NSString).draw(in:rect.insetBy(dx:10,dy:7),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.labelColor,.paragraphStyle:style])
            (row.detail as NSString).draw(in:CGRect(x:10,y:rect.minY+29,width:bounds.width-20,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:style])
        }
    }
    override func accessibilityChildren()->[Any]? { rows.enumerated().map { index,row in
        let e=ToolsListAXRow(); e.setAccessibilityParent(self); e.setAccessibilityRole(.row); e.setAccessibilityLabel(row.title+", "+row.detail); e.setAccessibilitySelected(row.id == selectedID)
        let local=CGRect(x:0,y:CGFloat(index)*rowHeight,width:bounds.width,height:rowHeight)
        e.setAccessibilityFrame(window.map { $0.convertToScreen(convert(local,to:nil)) } ?? local)
        e.invoke={ [weak self] in self?.select(index) }; return e
    } }
}
private final class ToolsListAXRow:NSAccessibilityElement {
    var invoke:(()->Void)?
    override func accessibilityPerformPress()->Bool { invoke?(); return invoke != nil }
}
