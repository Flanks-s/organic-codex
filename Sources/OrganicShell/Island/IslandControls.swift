import AppKit

@MainActor class IslandPlane: NSView {
    private var displayObservation:UUID?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame); wantsLayer=true; autoresizesSubviews=false
        appearance=NSAppearance(named:OrbDisplayEnvironment.shared.options.increaseContrast ? .accessibilityHighContrastDarkAqua:.darkAqua); setAccessibilityElement(false)
        displayObservation=OrbDisplayEnvironment.shared.observe { [weak self] in self?.displayOptionsDidChange() }
    }
    isolated deinit { if let displayObservation { OrbDisplayEnvironment.shared.removeObserver(displayObservation) } }
    func displayOptionsDidChange() {
        appearance=NSAppearance(named:OrbDisplayEnvironment.shared.options.increaseContrast ? .accessibilityHighContrastDarkAqua:.darkAqua)
        func invalidate(_ view:NSView) { view.needsDisplay=true; for child in view.subviews { invalidate(child) } }
        invalidate(self)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class IslandLabel: NativeLabel {
    override func draw(_ dirtyRect:NSRect) {
        // NSTextFieldCell reserves horizontal insets even for labels. Draw at the measured glyph origin
        // so a fitting title (especially New Chat) never loses its last glyph to a cell inset.
        let paragraph=NSMutableParagraphStyle(); paragraph.alignment=alignment; paragraph.lineBreakMode=lineBreakMode
        (stringValue as NSString).draw(in:bounds,withAttributes:[.font:font ?? .systemFont(ofSize:12),.foregroundColor:textColor ?? NSColor.labelColor,.paragraphStyle:paragraph])
    }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
}

/// Cell-free action surface: no AppKit bezel or cell can reappear during an offscreen capture.
@MainActor final class IslandButton: NSControl {
    var invoke:(()->Void)?, doubleClick:(()->Void)?, focus:((Bool)->Void)?
    var beginPointerGesture: ((NSEvent) -> (any IslandOrbDragGesture)?)?
    var routePointerDown: ((NSEvent) -> Bool)?
    var cancelRoutedPointer: (() -> Bool)?
    var routesContextInput: (() -> Bool)?
    private var pointerGesture: (any IslandOrbDragGesture)?
    /// The gesture can outlive a leaving/hidden column. Its local event monitor calls this on every exit.
    func endPointerGesture() { pointerGesture=nil; pressed=false; needsDisplay=true }
    func restorePointerHover() {
        if NativePointerShield.permits(self), let window {
            let p=convert(window.mouseLocationOutsideOfEventStream,from:nil)
            let dx=(p.x-bounds.midX)/max(1,bounds.width/2),dy=(p.y-bounds.midY)/max(1,bounds.height/2)
            hovered=bounds.contains(p) && (!circular || dx*dx+dy*dy<=1)
        } else {hovered=false}
        needsDisplay=true
    }
    var text="" { didSet { needsDisplay=true; setAccessibilityLabel(text) } }
    var symbol:String? { didSet { needsDisplay=true } }
    var tint=NSColor.secondaryLabelColor
    var pointSize:CGFloat=11.5
    var drawsText=true
    var circular=false
    var linkCursor=false
    var circularHit=false
    var drawsPointerHighlight=true
    var participates=true { didSet { setAccessibilityHidden(!participates); setAccessibilityElement(participates); needsDisplay=true } }
    private var enabledValue=true, hovered=false, pressed=false
    var pointerHighlight:CGFloat {
        drawsPointerHighlight && isEnabled && (hovered || pressed || window?.firstResponder === self) ? (pressed ? 0.14:0.055):0
    }
    private var tracking:NSTrackingArea?
    override var isEnabled:Bool { get { enabledValue } set { enabledValue=newValue; setAccessibilityEnabled(newValue); needsDisplay=true } }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { participates && isEnabled && !isHiddenOrHasHiddenAncestor }
    override init(frame:NSRect) {
        super.init(frame:frame); cell=nil; wantsLayer=true; focusRingType = .none
        setAccessibilityRole(.button); setAccessibilityElement(true)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) {
        let active=isEnabled // Departing controls keep their authored appearance after losing input/AX participation.
        if drawsPointerHighlight && active && (hovered || pressed || window?.firstResponder === self) {
            OrbDisplayEnvironment.surface(.white,opacity:pressed ? 0.14:0.055).setFill()
            (circular ? NSBezierPath(ovalIn:bounds):NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8)).fill()
        }
        guard drawsText else { return }
        let color=active ? tint:OrbDisplayEnvironment.surface(tint,opacity:0.5)
        var x:CGFloat=8
        if let symbol, let image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:pointSize,weight:.medium).applying(.init(paletteColors:[color]))) {
            image.draw(in:CGRect(x:x,y:floor((bounds.height-14)/2),width:14,height:14),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil); x+=20
        }
        let p=NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        let font=NSFont.systemFont(ofSize:pointSize,weight:.medium), h=ceil(font.ascender-font.descender)
        (text as NSString).draw(in:CGRect(x:x,y:floor((bounds.height-h)/2),width:max(0,bounds.width-x-8),height:h),withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:p])
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard participates,NativePointerShield.permits(self,localPoint:convert(point,from:superview)) else{return nil}
        if circularHit {
            let p=convert(point,from:superview),x=(p.x-bounds.midX)/max(1,bounds.width/2),y=(p.y-bounds.midY)/max(1,bounds.height/2)
            if x*x+y*y>1 {return nil}
        }
        return super.hitTest(point)
    }
    override func resetCursorRects() {super.resetCursorRects();if linkCursor && participates && isEnabled {addCursorRect(bounds,cursor:.pointingHand)}}
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
        addTrackingArea(area); tracking=area; super.updateTrackingAreas()
    }
    func reconcilePointerHover(_ point:CGPoint?) {
        let inside=point.map { p in
            let x=(p.x-bounds.midX)/max(1,bounds.width/2),y=(p.y-bounds.midY)/max(1,bounds.height/2)
            return bounds.contains(p) && (!circularHit || x*x+y*y<=1)
        } ?? false
        hovered=inside && participates && NativePointerShield.permits(self); needsDisplay=true
    }
    override func mouseEntered(with event:NSEvent) { hovered=participates && NativePointerShield.permits(self,localPoint:convert(event.locationInWindow,from:nil)); needsDisplay=true }
    override func mouseExited(with event:NSEvent) { hovered=false; needsDisplay=true }
    override func mouseDown(with event:NSEvent) {
        guard participates && isEnabled && NativePointerShield.permits(self,localPoint:convert(event.locationInWindow,from:nil)) else { return }
        if routePointerDown?(event) == true { return }
        if event.clickCount>1, let doubleClick { doubleClick(); return }
        pressed=true; needsDisplay=true
        if let gesture=beginPointerGesture?(event) {
            pointerGesture=gesture
            // Like a Dock press, a prospective drag keeps the current editor's first responder.
            // Esc is owned by the gesture's local monitor, including when this column leaves the tree.
            return // Do not run the old blocking loop: the scene's hold timer and display link must run.
        }
        if let window {
            // No first responder: a click is not keyboard focus (Tab still reaches it). As focus it took the keyboard from
            // the composer, and an island that has focus holds its activity line and stays open for good (user 10-30).
            while let next=window.nextEvent(matching:[.leftMouseUp,.leftMouseDragged]) {
                if next.type == .leftMouseUp {
                    pressed=false; needsDisplay=true
                    if bounds.contains(convert(next.locationInWindow,from:nil)) { performClick(self) }; break
                }
            }
        } else { pressed=false; performClick(self) }
    }
    override func mouseDragged(with event:NSEvent) { if routePointerDown?(event) != true { pointerGesture?.dragged(with:event) } }
    override func rightMouseDown(with event:NSEvent) {
        if routePointerDown?(event) != true { super.rightMouseDown(with:event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        // AppKit asks this before mouseDown for Control-click. Leave routing to the shared input owner.
        if event.modifierFlags.contains(.control), routesContextInput?() == true { return nil }
        return super.menu(for:event)
    }
    override func mouseUp(with event:NSEvent) { if routePointerDown?(event) != true { pointerGesture?.released(with:event) } }
    override func cancelOperation(_ sender:Any?) {
        if cancelRoutedPointer?() != true { pointerGesture?.cancel() }
        endPointerGesture()
    }
    override func performClick(_ sender:Any?) { if participates && isEnabled && !isHiddenOrHasHiddenAncestor { invoke?() } }
    override func accessibilityPerformPress() -> Bool {
        guard participates && isEnabled && !isHiddenOrHasHiddenAncestor else { return false }; performClick(self); return true
    }
    override func becomeFirstResponder() -> Bool { guard acceptsFirstResponder else { return false }; focus?(true); needsDisplay=true; return true }
    override func resignFirstResponder() -> Bool { focus?(false); needsDisplay=true; return true }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53, pointerGesture != nil { cancelOperation(self); return }
        guard participates else { return }
        if event.keyCode == 36 || event.keyCode == 49 { performClick(self) } else { super.keyDown(with:event) }
    }
}

@MainActor final class IslandRenameField:NSTextField {
    private(set) var focusGeneration=0
    var participates=false {
        didSet { isEditable=participates; isSelectable=participates; isHidden = !participates; setAccessibilityHidden(!participates); setAccessibilityElement(participates) }
    }
    override init(frame:NSRect) {
        super.init(frame:frame); isBordered=false; isBezeled=false; drawsBackground=false
        focusRingType = .none; alignment = .center; maximumNumberOfLines=1
        cell?.usesSingleLineMode=true; setAccessibilityLabel("Chat name"); participates=false
        isEditable=false; isSelectable=false; isHidden=true; setAccessibilityHidden(true); setAccessibilityElement(false)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect:NSRect) { super.draw(dirtyRect) }
    func beginSession(text:String) { focusGeneration+=1; stringValue=text }
    func endSession() { focusGeneration+=1; participates=false }
    func invalidateFocusRequests() { focusGeneration+=1 }
    /// A repeated focus request must preserve the current caret, Undo and marked text.
    @discardableResult func focusSession(generation:Int?=nil)->Bool {
        guard participates,!isHiddenOrHasHiddenAncestor,generation == nil || generation == focusGeneration,let window else { return false }
        if let editor=currentEditor() as? NSTextView,window.firstResponder === editor { return true }
        guard window.makeFirstResponder(self),participates,let editor=currentEditor() as? NSTextView,window.firstResponder === editor else { return false }
        if !editor.hasMarkedText() { editor.setSelectedRange(NSRange(location:0,length:editor.string.utf16.count)) }
        return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); let generation=focusGeneration
        if participates,window != nil { DispatchQueue.main.async { [weak self] in _ = self?.focusSession(generation:generation) } }
    }
    override var canBecomeKeyView:Bool { participates && !isHiddenOrHasHiddenAncestor && super.canBecomeKeyView }
    override func isAccessibilitySelectorAllowed(_ selector:Selector)->Bool {
        if (!participates || isHiddenOrHasHiddenAncestor),selector == NSSelectorFromString("setAccessibilityValue:") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func setAccessibilityValue(_ value:Any?) { if participates && !isHiddenOrHasHiddenAncestor { super.setAccessibilityValue(value) } }
    override var acceptsFirstResponder:Bool { participates && !isHiddenOrHasHiddenAncestor && super.acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { participates && super.becomeFirstResponder() }
    override func hitTest(_ point:NSPoint) -> NSView? { participates ? super.hitTest(point):nil }
    override func keyDown(with event:NSEvent) { if participates { super.keyDown(with:event) } }
}

@MainActor final class IslandMarkView:IslandPlane {
    var mark:HeaderIslandSignals.Mark? { didSet { needsDisplay=true } }
    private let workingDots=IslandWorkingDots()
    private var dotsPaused=true,dotsReduced=false,dotsScale:CGFloat=2
    override func displayOptionsDidChange() { configureDots(paused:dotsPaused,reduced:dotsReduced,scale:dotsScale); super.displayOptionsDidChange() }
    func configureDots(paused:Bool,reduced:Bool,scale:CGFloat) {
        dotsPaused=paused; dotsReduced=reduced; dotsScale=scale
        if workingDots.layer.superlayer == nil { layer?.addSublayer(workingDots.layer) }
        workingDots.layer.isHidden=window == nil || mark != .working || reduced
        effectiveAppearance.performAsCurrentDrawingAppearance {
            workingDots.configure(paused:paused || window == nil || mark != .working,reduced:reduced,scale:scale,now:CACurrentMediaTime())
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureDots(paused:dotsPaused,reduced:dotsReduced,scale:dotsScale) }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        guard let mark else { return }
        let text:String, color:NSColor
        switch mark {
        case .stoppedError:(text,color)=("x_x",.systemRed)
        case .runningError:(text,color)=("!",.systemRed)
        case .approvals(let n):(text,color)=("\(n)",.systemYellow)
        case .question:(text,color)=("?",.systemYellow)
        case .completion:(text,color)=("✓",.systemGreen)
        case .working:
            guard window == nil || dotsReduced else { return }
            NSColor.labelColor.withAlphaComponent(OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 1:0.62*0.78).setFill()
            for i in 0..<3 { NSBezierPath(ovalIn:CGRect(x:1.25+CGFloat(i)*4.5,y:5.75,width:2.5,height:2.5)).fill() }; return
        }
        color.setFill(); NSBezierPath(ovalIn:bounds).fill()
        let font=NSFont.systemFont(ofSize:text.count>2 ? 6.5:9,weight:.heavy), h=ceil(font.ascender-font.descender)
        let p=NSMutableParagraphStyle(); p.alignment = .center
        (text as NSString).draw(in:CGRect(x:0,y:floor((bounds.height-h)/2),width:bounds.width,height:h),withAttributes:[.font:font,.foregroundColor:NSColor.black.withAlphaComponent(OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 1:0.78),.paragraphStyle:p])
    }
}

@MainActor final class IslandMenuItem:NSMenuItem {
    var invoke:(()->Void)?
    init(_ title:String,_ action:@escaping ()->Void) { super.init(title:title,action:#selector(fire),keyEquivalent:""); target=self; invoke=action }
    required init(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func fire() { invoke?() }
}

extension IslandButton: NativePointerHoverClient {}
