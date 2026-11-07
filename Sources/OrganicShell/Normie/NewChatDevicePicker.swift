import AppKit
import SwiftUI

/// NewChatContext uses the same DeviceCards and arrow above its chip in both presentations.
@MainActor final class NewChatDevicePicker {
    static let preferredEdge: NSRectEdge = .minY
    private var popover: NSPopover?
    private var parityScheduled = false

    static func makeCards(store: ConversationStore, selected: String,
                          pick: @escaping @MainActor (NormieNewChatContext) -> Void,
                          done: @escaping @MainActor () -> Void) -> NormieDeviceCards {
        let cards = NormieDeviceCards(devices: store.devices, selected: selected)
        for button in cards.buttons {
            let id = button.device.id
            button.run = { [weak store] in
                guard let store, store.device(id)?.online == true else { return }
                pick(.init(projectID: store.projects.first { $0.deviceID == id }?.id, deviceID: id))
                done()
            }
        }
        return cards
    }

    func show(from view: NSView, rect: CGRect,
              cards: (@escaping @MainActor () -> Void) -> NormieDeviceCards) {
        guard view.window != nil else { return }
        close()
        let popover = NSPopover()
        popover.behavior = .transient; popover.appearance = view.window?.appearance
        let controller = NSViewController()
        controller.view = cards { [weak popover] in popover?.performClose(nil) }
        popover.contentViewController = controller; popover.contentSize = controller.view.frame.size
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: Self.preferredEdge)
    }

    func close() { popover?.close(); popover = nil }

    /// Existing PARITY_STATE=newchat creates the draft without changes to App/. The extra opt-in opens its chip
    /// after the draft's entrance settles. Offscreen checks have no window and never schedule this callback.
    func scheduleParityOpen(from view: NSView, open: @escaping @MainActor () -> Void) {
        let env = ProcessInfo.processInfo.environment
        guard !parityScheduled, env["PARITY_STATE"] == "newchat", env["PARITY_DEVICES"] == "1",
              view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        parityScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak view] in
            guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
            open()
        }
    }
}

/// Organic's footer uses the same product ContextChip renderer and 22pt anchor as Normie's composer.
/// This also avoids NSButtonCell's extra image/title gap moving the popover's horizontal centre.
@MainActor final class DraftContextRow: NSView {
    override var isFlipped: Bool { true }
    private let store: ConversationStore
    let chips = NativeComposerContextRow()
    private let devicePicker = NewChatDevicePicker()
    var context = NormieNewChatContext() { didSet { refresh() } }
    var onChange: ((NormieNewChatContext) -> Void)?
    var onVisualChange: (() -> Void)?

    init(store: ConversationStore) {
        self.store = store
        super.init(frame: .zero)
        addSubview(chips)
        chips.onProject = { [weak self] _, _ in self?.chooseProject() }
        chips.onDevice = { [weak self] view, rect in
            guard let self else { return }
            self.devicePicker.show(from: view, rect: rect) { [self] done in makeDeviceCards(done: done) }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { devicePicker.close() }
        else {
            devicePicker.scheduleParityOpen(from: chips) { [weak self] in self?.chips.deviceChip.run?() }
        }
    }
    override func layout() {
        super.layout()
        chips.scale = max(1, window?.backingScaleFactor ?? 1)
        chips.frame = bounds
        chips.needsLayout = true; chips.layoutSubtreeIfNeeded()
    }
    private func refresh() {
        let p = store.project(context.projectID), d = store.device(context.deviceID)
        chips.configure(.init(project: p?.name ?? "No Project",
                              projectSymbol: p == nil ? "bubble.left" : p?.colorHex == nil ? "folder" : "folder.fill",
                              projectTint: p?.colorHex, device: d?.name ?? "This Mac",
                              deviceSymbol: d?.symbol ?? "laptopcomputer"))
        needsLayout = true; onVisualChange?()
    }
    func makeDeviceCards(done: @escaping @MainActor () -> Void) -> NormieDeviceCards {
        NewChatDevicePicker.makeCards(store: store, selected: context.deviceID,
                                      pick: { [weak self] in self?.pick($0) }, done: done)
    }
    private func chooseProject() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Projects on \(store.device(context.deviceID)?.name ?? context.deviceID)"))
        for p in store.projects where p.deviceID == context.deviceID {
            let item = NormieMenuItem(p.name) { [weak self] in self?.pick(.init(projectID: p.id, deviceID: p.deviceID)) }
            item.state = p.id == context.projectID ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let none = NormieMenuItem("No Project") { [weak self] in
            guard let self else { return }; self.pick(.init(projectID: nil, deviceID: self.context.deviceID))
        }
        none.state = context.projectID == nil ? .on : .off; menu.addItem(none)
        menu.popUp(positioning: nil, at: CGPoint(x: chips.projectChip.frame.minX, y: chips.projectChip.frame.maxY + 2), in: self)
    }
    private func pick(_ next: NormieNewChatContext) {
        guard next != context else { return }
        context = next; onChange?(next)
    }
}

/// DeviceCards (ComposerDock.swift): 76 pt cards 6 pt apart, 8 pt around, in New Chat's device popover.
@MainActor final class NormieDeviceCards: NormieView {
    let buttons: [NormieDeviceButton]
    init(devices: [Device], selected: String) {
        buttons = devices.map { d in
            let b = NormieDeviceButton(device: d); b.isEnabled = d.online; b.chosen = d.id == selected
            b.setAccessibilityLabel("\(d.name), \(d.online ? "connected" : "offline")"); b.setAccessibilityValue(d.id == selected ? "selected" : nil)
            return b
        }
        let height = buttons.map(\.preferredHeight).max() ?? NormieDeviceButton.height
        super.init(frame: CGRect(x: 0, y: 0, width: 16+CGFloat(devices.count)*76+CGFloat(max(0, devices.count-1))*6, height: 16+height))
        // SwiftUI HStack centres each card: a wrapped name makes that card taller, not its neighbours.
        for (i, b) in buttons.enumerated() { addSubview(b); b.frame = CGRect(x: 8+CGFloat(i)*82, y: 8+(height-b.preferredHeight)/2, width: 76, height: b.preferredHeight) }
        setAccessibilityRole(.group); setAccessibilityLabel("Devices")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Device cards retain native button focus/action/AX while drawing the product's 46 pt symbol circle and status badge.
@MainActor final class NormieDeviceButton: NormieButton {
    /// Product Text at 11/10pt measures 14/13pt. The name can occupy two lines at the full 76pt width.
    static let height: CGFloat = 105
    let device: Device
    let nameLines: [String]
    private let systemAccent = resolve(.accentColor), systemOrange = resolve(.orange)
    var preferredHeight: CGFloat { Self.height+CGFloat(nameLines.count-1)*14 }
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
    init(device: Device) { self.device = device; nameLines = Self.lines(device.name); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private static func resolve(_ color: Color) -> NSColor {
        var environment = EnvironmentValues(); environment.colorScheme = .dark
        return NSColor(cgColor: color.resolve(in: environment).cgColor) ?? .controlAccentColor
    }
    private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.preferringMonochrome())),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let s = image.size, drawing = CGRect(x: rect.midX-s.width/2, y: rect.midY-s.height/2, width: s.width, height: s.height)
        context.saveGState(); context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: drawing, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn); context.setFillColor(color.cgColor); context.fill(drawing)
        context.endTransparencyLayer(); context.restoreGState()
    }
    private static func lines(_ name: String) -> [String] {
        let storage = NSTextStorage(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: 76, height: 1000))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        container.lineFragmentPadding = 0; container.maximumNumberOfLines = 2
        manager.ensureLayout(for: container)
        var lines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var line = (name as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if lines.count == 1 && NSMaxRange(range) < storage.length { line += "…" }
            lines.append(line)
        }
        return lines.isEmpty ? [""] : lines
    }
    override func draw(_ dirtyRect: NSRect) {
        if chosen { NativeDisplayOptions.plate(NativeAppearance.current.accent ?? systemAccent,alpha:0.18).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
        let alpha: CGFloat = isEnabled ? 1 : 0.55
        let label = NativePalette.label.withAlphaComponent(NativePalette.label.alphaComponent*alpha)
        let circle = CGRect(x: (bounds.width-46)/2, y: 10, width: 46, height: 46)
        NativeDisplayOptions.plate(alpha:0.08*label.alphaComponent).setFill(); NSBezierPath(ovalIn: circle).fill()
        symbol(device.symbol, size: 22, weight: .regular, color: label, in: circle)
        // The badge sits on the circle's bottom-trailing corner, 1 pt out.
        let mark = CGRect(x: circle.maxX-13, y: circle.maxY-13, width: 14, height: 14)
        (device.online ? NSColor.systemGreen : systemOrange).withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: mark).fill()
        symbol(device.online ? "checkmark" : "exclamationmark", size: 7, weight: .heavy, color: .white.withAlphaComponent(alpha), in: mark)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        for (i, line) in nameLines.enumerated() {
            (line as NSString).draw(in: CGRect(x: 0, y: 62+CGFloat(i)*14, width: bounds.width, height: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: label, .paragraphStyle: paragraph])
        }
        let status = device.online ? NativePalette.secondaryLabel : systemOrange
        ((device.online ? "Connected" : "Offline") as NSString).draw(in: CGRect(x: 0, y: 62+CGFloat(nameLines.count)*14+6, width: bounds.width, height: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: status.withAlphaComponent(status.alphaComponent*alpha), .paragraphStyle: paragraph])
    }
}

