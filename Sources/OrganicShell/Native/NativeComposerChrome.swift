import AppKit
import QuartzCore

/// ComposerDock.swift:32–52, 97–153. All three rows belong to the retained composer;
/// switching to a bar hides the context row without changing the editor's identity.
struct NativeComposerWorkspace: Equatable {
    var project = "No Project"
    var projectSymbol = "folder"
    var projectTint: String?
    var branch = ""
    var device = "This Mac"
    var deviceSymbol = "laptopcomputer"
    var status = ""
    var statusMark = ""
}

/// A context chip's click target: the chip itself draws nothing new (ContextChip in a plain Button / Menu).
@MainActor final class NativeComposerChipButton: NSButton {
    var run: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); title = ""; isBordered = false; isTransparent = true; focusRingType = .none
        target = self; action = #selector(fire); setAccessibilityRole(.popUpButton); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    // A transparent hit target: NativeComposerContextRow draws the icon and text through its own capture path.
    override func draw(_ dirtyRect: NSRect) {}
    @objc private func fire() { run?() }
}

@MainActor final class NativeComposerContextRow: NativeFlippedView {
    let project = NativeLabel(labelWithString: "")
    let branch = NativeLabel(labelWithString: "")
    let device = NativeLabel(labelWithString: "")
    let status = NativeLabel(labelWithString: "")
    private let symbols = (0..<3).map { _ in NSImageView() }
    let statusSymbol = NSImageView()
    let spinner = NativeComposerSpinner()
    var scale: CGFloat = 1
    private(set) var value = NativeComposerWorkspace(project: "")
    /// New Chat's chips open its project menu and device cards (NewChatContext); nil leaves a chip plain text.
    var onProject: ((NSView, CGRect) -> Void)? { didSet { needsLayout = true } }
    var onDevice: ((NSView, CGRect) -> Void)? { didSet { needsLayout = true } }
    let projectChip = NativeComposerChipButton(), deviceChip = NativeComposerChipButton()
    override init(frame: NSRect) {
        super.init(frame: frame)
        projectChip.run = { [weak self] in guard let self else { return }; self.onProject?(self, self.projectChip.frame) }
        deviceChip.run = { [weak self] in guard let self else { return }; self.onDevice?(self, self.deviceChip.frame) }
        addSubview(projectChip); addSubview(deviceChip)
        for label in [project, branch, device, status] {
            label.font = .systemFont(ofSize: 11); label.textColor = NativePalette.secondaryLabel
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
            addSubview(label)
        }
        for symbol in symbols + [statusSymbol] { addSubview(symbol); symbol.setAccessibilityElement(false) }
        addSubview(spinner); spinner.isHidden = true; configure(.init())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func configure(_ next: NativeComposerWorkspace) {
        guard value != next else { return }; value = next
        project.stringValue = next.project; branch.stringValue = next.branch; device.stringValue = next.device; status.stringValue = next.status
        for (view, name) in zip(symbols, [next.projectSymbol, "arrow.triangle.branch", next.deviceSymbol]) {
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            view.contentTintColor = NativePalette.secondaryLabel
        }
        if let hex = next.projectTint { symbols[0].contentTintColor = Self.color(hex) }
        statusSymbol.image = next.statusMark.isEmpty ? nil : NSImage(systemSymbolName: next.statusMark, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        statusSymbol.contentTintColor = .systemOrange
        spinner.isHidden = next.status.isEmpty || !next.statusMark.isEmpty
        statusSymbol.isHidden = next.status.isEmpty || next.statusMark.isEmpty
        spinner.animating = !spinner.isHidden
        status.toolTip = next.status
        needsLayout = true
    }
    private static func color(_ hex: String) -> NSColor? {
        guard let n = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8) & 255)/255, blue: CGFloat(n & 255)/255, alpha: 1)
    }
    override func nativeAppearanceDidChange() { super.nativeAppearanceDidChange(); let old = value; value = .init(); configure(old) }
    override func layout() {
        super.layout()
        func snap(_ r: CGRect) -> CGRect { r.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.applying(CGAffineTransform(scaleX: 1/scale, y: 1/scale)) }
        let statusWidth = value.status.isEmpty ? 0 : min(bounds.width * 0.44, ceil((status.stringValue as NSString).size(withAttributes:[.font:status.font!]).width) + 22)
        status.frame = snap(CGRect(x: bounds.width-statusWidth+18, y: 3, width: max(0, statusWidth-18), height: 16))
        let mark = snap(CGRect(x: bounds.width-statusWidth, y: 6, width: 10, height: 10))
        spinner.frame = mark; statusSymbol.frame = mark
        var x: CGFloat = 0
        let end = max(0, bounds.width-statusWidth-(statusWidth > 0 ? 12:0))
        for (i, label) in [project, branch, device].enumerated() {
            let hidden = label.stringValue.isEmpty; label.isHidden = hidden; symbols[i].isHidden = hidden
            guard !hidden else { continue }
            // ContextChip: 6 pt horizontal padding, 12 pt symbol, 5 pt gap; chips are 2 pt apart.
            let symbolSize = symbols[i].image?.size ?? CGSize(width:12,height:12)
            let symbolWidth = ceil(symbolSize.width)
            let labelWidth = ceil((label.stringValue as NSString).size(withAttributes:[.font:label.font!]).width)+4
            let natural = min(280, labelWidth+symbolWidth+17)
            let width = min(natural, max(0, end-x))
            symbols[i].frame = snap(CGRect(x:x+6,y:(22-symbolSize.height)/2,width:symbolWidth,height:symbolSize.height))
            label.frame = snap(CGRect(x:x+6+symbolWidth+5,y:3,width:max(0,width-symbolWidth-17),height:16))
            if i == 0 { projectChip.frame = CGRect(x: x, y: 0, width: width, height: 22) }
            if i == 2 { deviceChip.frame = CGRect(x: x, y: 0, width: width, height: 22) }
            x += width+2
        }
        projectChip.isHidden = onProject == nil || project.isHidden; deviceChip.isHidden = onDevice == nil || device.isHidden
        projectChip.setAccessibilityLabel("Project: \(value.project)"); deviceChip.setAccessibilityLabel("Device: \(value.device)")
    }
}

/// The same threaded AppKit mini-spinner as product Design/Spinner.swift. No main-thread frame loop.
@MainActor final class NativeComposerSpinner: NSProgressIndicator {
    var animating = false { didSet { if animating != oldValue { updateMotion() } } }
    override init(frame: NSRect) {
        super.init(frame:frame);style = .spinning;isIndeterminate=true;isDisplayedWhenStopped=false
        usesThreadedAnimation=true;controlSize = .mini;setAccessibilityElement(false)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    private func updateMotion() {
        if animating && !isHiddenOrHasHiddenAncestor { startAnimation(nil) } else { stopAnimation(nil) }
    }
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();updateMotion()}
    override func viewDidHide(){super.viewDidHide();stopAnimation(nil)}
    override func viewDidUnhide(){super.viewDidUnhide();updateMotion()}
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect)}
}

/// No AppKit bezel in motion captures. ComposerDock's bordered Stop and FullBar's plain circle.
@MainActor final class NativeComposerStopButton: NativeButton {
    var normie = false { didSet { if normie != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        let plate = normie ? bounds.insetBy(dx: 2, dy: 2) : bounds
        NativeDisplayOptions.plate(alpha: normie ? 0.25 : 0.10).setFill()
        NSBezierPath(ovalIn: plate).fill()
        if let image = image?.withSymbolConfiguration(.init(pointSize: normie ? 12:10, weight: .regular).applying(.init(paletteColors: [NativePalette.label]))) {
            let size = image.size
            image.draw(in: CGRect(x: bounds.midX-size.width/2,y: bounds.midY-size.height/2,width: size.width,height: size.height),from: .zero,operation: .sourceOver,fraction: isEnabled ? 1:0.45,respectFlipped: true,hints: nil)
        }
    }
}
