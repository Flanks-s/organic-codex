import AppKit

@MainActor enum NativePalette {
    static var label:NSColor{NativeAppearance.current.label}
    static var secondaryLabel:NSColor{NativeAppearance.current.secondary}
    static var tertiaryLabel:NSColor{NativeAppearance.current.tertiary}
    static var canvas:NSColor{NativeAppearance.current.canvas}
    static var accent:NSColor{NativeAppearance.current.accentColor}
    static var codeText:NSColor{NativeAppearance.current.code.text ?? label}
    static var codeFill:NSColor {NativeDisplayOptions.shared.state.reducesEffects ? NativeDisplayOptions.plate(NativeAppearance.current.foreground ?? .white,alpha:0.12):NativeAppearance.current.foreground?.withAlphaComponent(0.06) ?? .quaternarySystemFill}
    static var bubble:NSColor {NativeDisplayOptions.plate(accent,alpha:0.20)}
    static var added:NSColor{NativeAppearance.current.code.added ?? .systemGreen}
    static var removed:NSColor{NativeAppearance.current.code.removed ?? .systemRed}
    /// The plate behind a card's buttons and answer fields (dark mode only).
    static let plate = NSColor.white.withAlphaComponent(0.10)
}

@MainActor final class NativeReadOnlyTextView: NSTextView {
    private let backingStorage: NSTextStorage
    init() {
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer()
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        backingStorage = storage
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true
        drawsBackground = false; importsGraphics = false
        textContainerInset = .zero; textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = false; isHorizontallyResizable = false
        focusRingType = .none
        setAccessibilityLabel("Transcript text")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor class NativeFlippedView: NSView {
    override var isFlipped: Bool { true }
    private var displayObservation:UUID?
    private var appearanceObservation:UUID?
    override init(frame:NSRect){super.init(frame:frame);appearance=NativeDisplayOptions.appearance;displayObservation=NativeDisplayOptions.shared.observe{[weak self] in self?.displayOptionsDidChange()};appearanceObservation=NativeAppearance.observe{[weak self] in self?.nativeAppearanceDidChange()}}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    isolated deinit{if let displayObservation{NativeDisplayOptions.shared.removeObserver(displayObservation)};if let appearanceObservation{NativeAppearance.removeObserver(appearanceObservation)}}
    func nativeAppearanceDidChange(){NativeAppearance.recolor(self);needsDisplay=true}
    func displayOptionsDidChange(){appearance=NativeDisplayOptions.appearance;func redraw(_ view:NSView){view.needsDisplay=true;view.subviews.forEach(redraw)};redraw(self)}
}

// Text controls in a transcript that motion captures are these subclasses, never the plain AppKit classes.
//
// A plain NSTextField or NSButton reaches the screen through AppKit's own text path, and draws its text
// noticeably bolder when the same view is drawn into a capture (cacheDisplay). A subclass that overrides
// draw(_:), even only to call super, is drawn the same way in both. Recorded beside their captures in a
// window, the difference per control dropped from 20 316 to 575 (label), 1 961 to 211 (borderless button)
// and 9 893 to 285 (borderless field); the rest is the recording's own noise, which NSTextView also shows.
// Bezels (rounded buttons, bezeled fields) still differ with the override, so cards draw their own plates.

@MainActor class NativeLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}

@MainActor class NativeSecureField: NSSecureTextField {
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}

@MainActor class NativeButton: NSButton {
    private var explicitAXLabel:String?,explicitAXHelp:String?
    override func setAccessibilityLabel(_ value:String?){explicitAXLabel=value;super.setAccessibilityLabel(value);cell?.setAccessibilityLabel(value)}
    override func accessibilityLabel()->String?{explicitAXLabel ?? super.accessibilityLabel()}
    override func setAccessibilityHelp(_ value:String?){explicitAXHelp=value;super.setAccessibilityHelp(value);cell?.setAccessibilityHelp(value)}
    override func accessibilityHelp()->String?{explicitAXHelp ?? super.accessibilityHelp()}
    override func accessibilityPerformPress()->Bool {
        guard superview != nil,isEnabled,NativeInteractionSurface.permits(self)else{return false}
        return super.accessibilityPerformPress()
    }
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}

/// Composer primary action. Own drawing path, no system bezel, shared by window and cacheDisplay.
@MainActor final class NativePrimaryButton:NativeButton {
    var drawsAccentCircle=true{didSet{if oldValue != drawsAccentCircle{needsDisplay=true}}}
    /// Normie's AccentCircleStyle when disabled: SwiftUI resolves the accent to grey there (measured on the product's
    /// New Chat Voice: grey 117 at 45%, white glyph). Nil keeps the accent at 45% (the full bar's circles).
    var disabledFill:NSColor?{didSet{if oldValue != disabledFill{needsDisplay=true}}}
    static let dockDisabledFill=NSColor(srgbRed:117/255,green:118/255,blue:117/255,alpha:0.45)
    override func draw(_ dirtyRect:NSRect){
        guard drawsAccentCircle else{super.draw(dirtyRect);return}
        let color=NativeAppearance.current.accentColor
        let fill = !isEnabled && disabledFill != nil ? disabledFill! : (isHighlighted ? color.blended(withFraction:0.08,of:.black) ?? color:color).withAlphaComponent(isEnabled ? 1:0.45)
        fill.setFill();NSBezierPath(ovalIn:bounds).fill()
        if let image=image?.withSymbolConfiguration(.init(pointSize:14,weight:.semibold).applying(.init(paletteColors:[.white]))){
            let size=image.size;let rect=CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height)
            image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
    }
}

@MainActor enum NativeViewBitmap {
    #if M11_MODE_SELFTEST
    static var verificationCaptureObserver:((NSView)->Void)?
    #endif
    static func capture(_ view: NSView, scale: CGFloat) -> CGImage {
        #if M11_MODE_SELFTEST
        verificationCaptureObserver?(view)
        #endif
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let size = CGSize(width: max(1, view.bounds.width), height: max(1, view.bounds.height))
        let rect = CGRect(origin: view.bounds.origin, size: size)
        // In a window, AppKit's own caching rep: the window's colour space and backing, so the capture matches
        // what the view draws on screen (a deviceRGB rep differed faintly on every glyph in a recording).
        let rep: NSBitmapImageRep
        if view.window != nil, let own = view.bitmapImageRepForCachingDisplay(in: rect) {
            rep = own
        } else {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(ceil(size.width * scale))),
                pixelsHigh: max(1, Int(ceil(size.height * scale))), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
        }
        if let bytes = rep.bitmapData { memset(bytes, 0, rep.bytesPerRow * rep.pixelsHigh) }
        view.cacheDisplay(in: rect, to: rep)
        // The rep's image reads the rep's own buffer, which may be gone by the time Core Animation draws a layer
        // showing it. Copy into an image that owns its pixels, same colour space.
        let image = rep.cgImage!
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}

/// Transcript-only read-only TextKit surface. Keep the older NativeReadOnlyTextView API intact for other clients.
@MainActor final class NativeTranscriptTextView: NSTextView {
    private(set) var isTrackingSelection = false
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes + [DragAttachmentPayload.quoteType]
    }
    /// NSTextView keeps its existing plain-text/RTF writer and native drag gesture.
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == DragAttachmentPayload.quoteType else { return super.writeSelection(to: pasteboard, type: type) }
        guard NativeInteractionSurface.permits(self) else { return false }
        var parent = superview
        while let view = parent {
            if let row = view as? NativeTranscriptRow {
                return DragAttachmentPayload.writeQuotes(row.dragAttachmentQuotes(), to: pasteboard)
            }
            parent = view.superview
        }
        return false
    }
    override func mouseDown(with event: NSEvent) {
        isTrackingSelection = true
        defer { isTrackingSelection = false }
        super.mouseDown(with: event)
    }

    private let backingStorage: NSTextStorage
    init() {
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer()
        storage.addLayoutManager(manager); manager.addTextContainer(container); backingStorage = storage
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true
        drawsBackground = false; importsGraphics = false; focusRingType = .none
        textContainerInset = .zero; container.lineFragmentPadding = 0
        isVerticallyResizable = false; isHorizontallyResizable = false
        setAccessibilityLabel("Transcript text")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
    override func setAccessibilityValue(_ value: Any?) {}
    override func setAccessibilitySelectedText(_ selectedText: String?) {}
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == NSSelectorFromString("setAccessibilityValue:") || selector == NSSelectorFromString("setAccessibilitySelectedText:") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .value || attribute == .selectedText { return false }
        if attribute == .selectedTextRange || attribute == .selectedTextRanges {
            return MainActor.assumeIsolated { isSelectable && NativeInteractionSurface.permits(self) }
        }
        return false
    }
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .value || attribute == .selectedText { return }
        if attribute == .selectedTextRange, let wrapped = value as? NSValue {
            let range = wrapped.rangeValue
            MainActor.assumeIsolated {
                if isSelectable && NativeInteractionSurface.permits(self) {
                    setSelectedRange(NSIntersectionRange(range, NSRange(location: 0, length: (string as NSString).length)))
                }
            }
        } else if attribute == .selectedTextRanges, let wrapped = value as? [NSValue] {
            let ranges = wrapped.map(\.rangeValue)
            MainActor.assumeIsolated {
                if isSelectable && NativeInteractionSurface.permits(self) {
                    let whole = NSRange(location: 0, length: (string as NSString).length)
                    selectedRanges = ranges.map { NSValue(range: NSIntersectionRange($0, whole)) }
                }
            }
        }
    }
}
