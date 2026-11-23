import AppKit

/// One real glass surface. Switching content never replaces its shape channels or scales a capture.
@MainActor final class SunHoverPanelView: NSView {
    final class Content: NSView { override var isFlipped: Bool { true } }
    final class Row: NSButton {
        let id: String
        var detail: String, value: String, actionValue: SunHoverAction?
        var used: Double?, dividerBefore = false, header = false
        var identity: OrbIdentity?
        var home = CGRect.zero
        let blur = OverlayFilter.make("gaussianBlur", values: ["name": "sunRowBlur", "inputRadius": 0, "enabled": true])
        var invoke: (() -> Void)?
        let valueAlignment: NSTextAlignment = .right
        var valueRect: CGRect { CGRect(x: bounds.width - 84, y: 3, width: 76, height: 18) }
        var titleY: CGFloat { header ? 4 : detail.isEmpty && value.isEmpty ? 8 : 3 }
        init(id: String, title: String, detail: String = "", value: String = "", used: Double? = nil, action: SunHoverAction? = nil) {
            self.id = id; self.detail = detail; self.value = value; self.used = used; actionValue = action
            super.init(frame: .zero); self.title = title; isBordered = false; target = self; self.action = #selector(run)
            wantsLayer = true; setAccessibilityLabel([title, detail, value].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        @objc private func run() { if isEnabled { invoke?() } }
        override func draw(_ dirtyRect: NSRect) {
            if isHighlighted { NSColor.white.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
            let alpha = isEnabled ? 0.92 : 0.3
            func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, alpha: Double, weight: NSFont.Weight = .regular, right: Bool = false) {
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                if right { style.alignment = valueAlignment }
                (string as NSString).draw(in: CGRect(x: x, y: y, width: max(0, width), height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: style])
            }
            let extra = value.isEmpty ? 0.0 : 76.0, start = identity == nil ? 8.0 : 38.0
            if let identity {
                let path = NSBezierPath(cgPath: OrbCelestialGlyph(symbol: identity.symbol).path(in: CGRect(x: 8, y: 10, width: 20, height: 20)).cgPath)
                identity.tint.color.setStroke(); path.lineWidth = 1.5; path.stroke()
            }
            text(title, x: start, y: titleY, width: bounds.width - start - 8 - extra, size: header ? 11 : 13, alpha: header ? 0.45 : alpha, weight: detail.isEmpty ? .medium : .semibold)
            if !detail.isEmpty { text(detail, x: start, y: 20, width: bounds.width - start - 8, size: 11, alpha: 0.55, weight: .medium) }
            if !value.isEmpty { text(value, x: valueRect.minX, y: valueRect.minY, width: valueRect.width, size: 11, alpha: 0.55, right: true) }
            if let used {
                NSColor.white.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: CGRect(x: 8, y: bounds.height - 5, width: bounds.width - 16, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
                NSColor.white.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: CGRect(x: 8, y: bounds.height - 5, width: (bounds.width - 16) * used, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
    let glass = NSGlassEffectView(), content = Content(), document = Content(), scroll = NSScrollView()
    private(set) var rows: [Row] = []
    private var exitingRows: [Row] = []
    var exitingCount: Int { exitingRows.count }
    private var kind: SunHoverPanel?
    private var signature = ""
    private let heading = NSTextField(labelWithString: "")
    private let divider = NSBox()
    var activate: ((SunHoverAction) -> Void)?
    /// Board: 8pt padding, 34pt account row, .5pt inner rule. Reuse padding on both sides of the new rule.
    static let accountHeight = 142.0 + 34 + 8 + 0.5 + 8
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        glass.style = .regular; glass.cornerRadius = 20; glass.contentView = content; addSubview(glass)
        glass.tintColor = NSColor(srgbRed: 48/255, green: 50/255, blue: 48/255, alpha: 0.82)
        heading.font = .systemFont(ofSize: 11); heading.textColor = .white.withAlphaComponent(0.45)
        content.addSubview(heading); content.addSubview(scroll)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.documentView = document
        divider.boxType = .separator; content.addSubview(divider); divider.isHidden = true
        setAccessibilityElement(false)
        displayOptionsChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func displayOptionsChanged() {
        let opaque = OrbDisplayEnvironment.shared.options.opaqueSurfaces
        glass.tintColor = OrbDisplayEnvironment.surface(NSColor(srgbRed: 48/255, green: 50/255, blue: 48/255, alpha: 1), opacity: 0.82)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = opaque ? 0 : 0.45
        layer?.shadowRadius = 22; layer?.shadowOffset = CGSize(width: 0, height: -18)
    }
    func configure(kind: SunHoverPanel, access: SunHoverAccess, usage: SunHoverUsagePanel, attention: SunHoverAttention, identities: [String: OrbIdentity] = [:]) -> [String] {
        let key = "\(kind)|\(access.accountTitle)|\(access.accountItems)|\(usage.accountVersion)|\(usage.currentConversationID ?? "")|\(usage.rows.map { $0.detail })|\(attention.rows)"
        if key == signature {
            if kind == .attention { for row in rows where row.identity != identities[row.id] { row.identity = identities[row.id]; row.needsDisplay = true } }
            return rows.map(\.id)
        }
        signature = key; self.kind = kind
        let previous = rows; rows = []
        divider.isHidden = kind != .account; heading.isHidden = kind == .account
        switch kind {
        case .account:
            for (i, item) in access.accountItems.enumerated() {
                let row = Row(id: "account:\(i)", title: item.title, action: item.action)
                row.isEnabled = item.enabled; row.dividerBefore = item.dividerBefore; row.header = i == 0; rows.append(row)
            }
        case .usage:
            heading.stringValue = "Usage"
            for (i, value) in usage.rows.enumerated() {
                let reset = i == 2 ? "" : value.resetsAt.map { "resets " + $0.formatted(.dateTime.hour().minute()) } ?? "resets not reported"
                let row = Row(id: "usage:\(i)", title: value.title, detail: reset, value: i == 2 ? value.percentage : value.detail, used: value.used)
                row.setAccessibilityRole(.staticText); rows.append(row)
            }
        case .attention:
            heading.stringValue = "\(attention.conversationCount) need you"
            for value in attention.rows {
                let mark = value.mostSevere.severity <= .runningError ? "!" : "?"
                let row = Row(id: value.conversationID, title: value.title, detail: value.mostSevere.text, value: mark + value.suffix, action: .conversation(value.conversationID))
                row.identity = identities[value.conversationID]; rows.append(row)
            }
        }
        let currentIDs = Set(rows.map(\.id))
        for row in previous {
            if currentIDs.contains(row.id) { row.removeFromSuperview() }
            else { row.isEnabled = false; exitingRows.append(row) }
        }
        for row in rows {
            document.addSubview(row)
            row.invoke = { [weak self, weak row] in if let action = row?.actionValue { self?.activate?(action) } }
        }
        needsLayout = true; layoutSubtreeIfNeeded()
        return rows.map(\.id)
    }
    override func layout() {
        super.layout(); glass.frame = bounds; content.frame = bounds
        heading.frame = CGRect(x: 14, y: 12, width: max(0, bounds.width - 28), height: 16)
        let top: CGFloat = kind == .account ? 8 : 32
        scroll.frame = CGRect(x: 6, y: top, width: max(0, bounds.width - 12), height: max(0, bounds.height - top - 8))
        let pitch: CGFloat = kind == .attention ? 46 : kind == .usage ? 44 : 34
        let contentHeight = kind == .account ? 24 + CGFloat(max(0, rows.count - 1)) * 34 + 16.5 : CGFloat(rows.count) * pitch
        document.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: max(scroll.bounds.height, contentHeight))
        for (i, row) in rows.enumerated() {
            let gap: CGFloat = row.dividerBefore ? 16.5 : 0
            let y = kind == .account && i > 0 ? 24 + CGFloat(i - 1) * 34 : CGFloat(i) * pitch
            row.frame = CGRect(x: 0, y: y + gap, width: document.bounds.width, height: kind == .account ? (i == 0 ? 24 : 34) : pitch - 2)
            row.home = row.frame
            if row.dividerBefore { divider.frame = CGRect(x: 14, y: top + row.frame.minY - 8.5, width: max(0, bounds.width - 28), height: 0.5) }
        }
    }
    func sampleRows(state: SunHoverState) {
        for row in rows + exitingRows {
            let q = state.rowVisibility(row.id, at: state.now)
            row.isHidden = q <= 0.004
            row.alphaValue = q; row.setAccessibilityHidden(!row.isEnabled || q <= 0.5 || state.mode != .panel(kind ?? .account))
            row.frame = row.home.offsetBy(dx: 0, dy: state.reduceMotion ? 0 : 6 * (1 - q))
            if !state.reduceMotion, q < 0.999, let blur = row.blur {
                row.layer?.filters = [blur]; row.layer?.setValue(6 * (1 - q), forKeyPath: "filters.sunRowBlur.inputRadius")
            } else { row.layer?.filters = nil }
        }
        exitingRows.removeAll { row in
            guard state.rowVisibility(row.id, at: state.now) <= 0.004 else { return false }
            row.removeFromSuperview(); return true
        }
    }
    func retire() {
        rows.forEach { $0.setAccessibilityHidden(true) }; activate = nil
        exitingRows.forEach { $0.removeFromSuperview() }; exitingRows = []
    }
}
