import AppKit
import QuartzCore

/// Bounded shape/text layers. Tracking never asks AppKit to redraw a window-sized bitmap.
@MainActor final class SunHoverNode: NSView, NativePointerHoverClient {
    final class Plane: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    enum Target: Equatable { case satellite(SunHoverSatellite), label(SunHoverSatellite) }
    let glass = NSGlassEffectContainerView(), glassPlane = Plane()
    let panel = SunHoverPanelView()
    private var discs: [NSGlassEffectView] = [], capsules: [NSGlassEffectView] = []
    private var icons: [CAShapeLayer] = [], texts: [CATextLayer] = []
    private let track = CAShapeLayer(), used = CAShapeLayer()
    private(set) var satelliteFrames: [SunHoverSatellite: CGRect] = [:], labelFrames: [SunHoverSatellite: CGRect] = [:]
    private(set) var visibleLabels: [SunHoverSatellite] = [], visibleSatellites: [SunHoverSatellite] = []
    var onPointer: ((CGPoint?) -> Void)?, onActivate: ((SunHoverSatellite) -> Void)?
    var permits: (SunHoverSatellite) -> Bool = { _ in false }
    var mountGlass: ((NSGlassEffectView) -> Void)?
    var mountRing: (([CALayer]) -> Void)?
    var exposed = Set(SunHoverSatellite.allCases)
    var onWindow: ((NSWindow?) -> Void)?
    private var pressed: Target?, tracking: NSTrackingArea?
    private var ax: [DockElement] = [], axSignature: [String] = []
    private var ringKey = "", textKeys = Array(repeating: "", count: 6)
    var glassSurfaces: [NSGlassEffectView] { discs + capsules }
    var ringLayers: [CALayer] { [track, used] }
    private(set) var samples = 0, axBuilds = 0, inkBuilds = 0
    var inkLayerBounds: [CGRect] { ((icons as [CALayer]) + (texts as [CALayer]) + [track, used]).map(\.bounds) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; appearance = NSAppearance(named: .darkAqua); isHidden = true
        glass.spacing = 10; glass.contentView = glassPlane; addSubview(glass); addSubview(panel)
        for ring in [track, used] { ring.fillColor = nil; ring.lineCap = .round; layer?.addSublayer(ring); ring.isHidden = true }
        for key in SunHoverSatellite.allCases {
            let disc = NSGlassEffectView(), capsule = NSGlassEffectView()
            for view in [disc, capsule] { view.style = .regular; view.tintColor = NSColor(white: 0.2, alpha: 1); view.isHidden = true }
            discs.append(disc); capsules.append(capsule)
            let icon = CAShapeLayer(), text = CATextLayer()
            icon.path = Self.glyph(key); icon.lineWidth = 1.4; icon.strokeColor = NSColor.white.cgColor; icon.fillColor = nil
            icon.lineCap = .round; icon.lineJoin = .round
            text.font = NSFont.systemFont(ofSize: 12, weight: .semibold); text.fontSize = 12
            text.foregroundColor = NSColor.white.cgColor; text.alignmentMode = .center
            for ink in [icon, text] as [CALayer] { ink.isHidden = true; ink.zPosition = 17; layer?.addSublayer(ink) }
            icons.append(icon); texts.append(text)
        }
        panel.layer?.zPosition = 20; setAccessibilityElement(false); panel.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    override func layout() { super.layout(); glass.frame = bounds; glassPlane.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseMoved(with event: NSEvent) { onPointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }
    func reconcilePointerHover(_ point: CGPoint?) { onPointer?(point) }
    func sample(state: SunHoverState, geometry: SunHoverGeometry, diameter: Double, usage: AccountUsage, titles: [String]) {
        samples += 1; isHidden = false
        if frame != geometry.bounds { frame = geometry.bounds; layoutSubtreeIfNeeded() }
        satelliteFrames = [:]; labelFrames = [:]; visibleLabels = []; visibleSatellites = []
        let t = state.now
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        mountRing?(ringLayers)
        for key in SunHoverSatellite.allCases {
            let i = key.rawValue, q = state.satellites[i].value(at: t), c = state.labels[i].value(at: t)
            let shown = q > 0.004 && exposed.contains(key), enabled = permits(key)
            let rect = geometry.satellite(key, progress: q, reduceMotion: state.reduceMotion)
            discs[i].frame = rect; discs[i].cornerRadius = rect.width / 2
            show(discs[i], shown); discs[i].alphaValue = state.reduceMotion ? min(1, max(0, q)) : 1
            if shown { satelliteFrames[key] = geometry.satelliteHitRect(key, progress: q, reduceMotion: state.reduceMotion); visibleSatellites.append(key) }
            icons[i].frame = CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
            icons[i].isHidden = !shown; icons[i].opacity = Float(discs[i].alphaValue * (enabled ? 1 : 0.3))
            let labelRect = geometry.label(key, progress: state.reduceMotion ? 1 : c, aligned: true)
            capsules[i].frame = labelRect; capsules[i].cornerRadius = labelRect.height / 2
            capsules[i].alphaValue = state.reduceMotion ? min(1, max(0, c)) : 1
            show(capsules[i], c > 0.004 && exposed.contains(key))
            let textKey = "\(titles[i])|\(geometry.backingScale)"
            if textKeys[i] != textKey { textKeys[i] = textKey; texts[i].string = titles[i]; texts[i].contentsScale = geometry.backingScale; inkBuilds += 1 }
            texts[i].frame = CGRect(x: labelRect.minX, y: labelRect.midY - 7.5, width: labelRect.width, height: 15)
            texts[i].opacity = Float(SunHoverGeometry.smooth((c - 0.62) / 0.38) * (enabled ? 1 : 0.3))
            texts[i].isHidden = !exposed.contains(key) || c <= 0.62
            if c > 0.5 && exposed.contains(key) { labelFrames[key] = labelRect }
            if c > 0.62 && exposed.contains(key) { visibleLabels.append(key) }
        }
        let ring = geometry.ring(diameter: diameter, number: state.number.value(at: t), progress: state.ring.value(at: t), usage: usage, reduceMotion: state.reduceMotion)
        let rect = CGRect(x: ring.center.x - ring.radius - 2, y: ring.center.y - ring.radius - 2, width: 2 * ring.radius + 4, height: 2 * ring.radius + 4)
        let key = "\(ring.radius)|\(ring.stroke)|\(String(describing: ring.used))|\(ring.sweep)"
        if ringKey != key {
            ringKey = key; inkBuilds += 1
            let box = CGRect(x: 2, y: 2, width: 2 * ring.radius, height: 2 * ring.radius)
            track.path = CGPath(ellipseIn: box, transform: nil)
            let path = NSBezierPath(); path.appendArc(withCenter: CGPoint(x: ring.radius + 2, y: ring.radius + 2), radius: ring.radius, startAngle: -90, endAngle: -90 + 360 * ring.sweep, clockwise: false)
            used.path = path.cgPath
        }
        let alpha = Float(min(1, max(0, state.ring.value(at: t))))
        for ringLayer in [track, used] { ringLayer.frame = rect; ringLayer.lineWidth = ring.stroke; ringLayer.opacity = alpha; ringLayer.isHidden = alpha <= 0.001 }
        track.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor; used.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        used.isHidden = used.isHidden || ring.used == nil || ring.sweep <= 0
        updateAccessibility(state: state, titles: titles)
    }
    func regions(at point: CGPoint?, state: SunHoverState, geometry: SunHoverGeometry, ll: CGRect, badge: Bool, badgeFrame: CGRect? = nil) -> Set<SunHoverState.Region> {
        guard let point else { return [] }; var result: Set<SunHoverState.Region> = []
        if ll.insetBy(dx: min(0, (ll.width - 48) / 2), dy: min(0, (ll.height - 48) / 2)).contains(point) { result.insert(.ll) }
        if badge && Self.badgeHitRect(badgeFrame ?? Self.badgeRect(ll: ll)).contains(point) { result.insert(.badge); result.insert(.ll) }
        if state.mode != .idle {
            if geometry.zone.contains(point) { result.insert(.zone) }
            for (key, rect) in satelliteFrames where rect.contains(point) { result.insert(.satellite(key)) }
            for (key, rect) in labelFrames where rect.contains(point) { result.insert(.label(key)) }
            if !panel.isHidden && panel.frame.contains(point) { result.insert(.panel) }
        }
        return result
    }
    static func badgeRect(ll: CGRect, width: CGFloat = 14) -> CGRect { CGRect(x: ll.maxX + 3 - width, y: ll.minY - 3, width: width, height: 14) }
    static func badgeHitRect(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX - 6, y: rect.minY - 6, width: rect.width + 12, height: rect.height + 10) }
    func target(at point: CGPoint) -> Target? {
        for key in SunHoverSatellite.allCases where permits(key) {
            if labelFrames[key]?.contains(point) == true { return .label(key) }
            if satelliteFrames[key]?.contains(point) == true { return .satellite(key) }
        }
        return nil
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }; let p = convert(point, from: superview)
        if !panel.isHidden && panel.frame.contains(p) { return panel.hitTest(p) ?? self }
        return target(at: p) == nil ? nil : self
    }
    override func mouseDown(with event: NSEvent) { pressed = target(at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let next = target(at: convert(event.locationInWindow, from: nil)), previous = pressed; pressed = nil
        guard previous == next, let next else { return }
        switch next { case .satellite(let key), .label(let key): onActivate?(key) }
    }
    func retire() {
        guard !isHidden else { return }; isHidden = true
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        pressed = nil; satelliteFrames = [:]; labelFrames = [:]; visibleSatellites = []; visibleLabels = []
        (discs + capsules).forEach { show($0, false) }; panel.retire(); panel.isHidden = true
        ((icons as [CALayer]) + (texts as [CALayer]) + [track, used]).forEach { $0.isHidden = true }
        ax = []; axSignature = []
    }
    private func show(_ surface: NSGlassEffectView, _ visible: Bool) {
        surface.isHidden = !visible
        if visible && surface.superview == nil {
            if let mountGlass { mountGlass(surface) } else { glassPlane.addSubview(surface) }
        } else if !visible { surface.removeFromSuperview() }
    }
    func dispose() { retire(); glassSurfaces.forEach { $0.removeFromSuperview() }; ringLayers.forEach { $0.removeFromSuperlayer() }; removeFromSuperview() }
    private func updateAccessibility(state: SunHoverState, titles: [String]) {
        let keys = SunHoverSatellite.allCases.filter { exposed.contains($0) && state.canClick($0) && permits($0) }
        let signature = keys.map { "\($0.rawValue):\(titles[$0.rawValue])" }
        guard signature != axSignature else { return }; axSignature = signature; axBuilds += 1
        ax = keys.map { key in
            let item = DockElement(); item.host = self; item.setAccessibilityRole(.button); item.setAccessibilityLabel(titles[key.rawValue]); item.setAccessibilityEnabled(true)
            item.frameInHost = { [weak self] in self?.satelliteFrames[key] ?? .zero }
            item.press = { [weak self] in guard let self, self.permits(key), self.satelliteFrames[key] != nil else { return false }; self.onActivate?(key); return true }
            return item
        }
    }
    override func accessibilityChildren() -> [Any]? { var result: [Any] = ax; if !panel.isHidden { result.append(panel) }; return result }
    private static func glyph(_ key: SunHoverSatellite) -> CGPath {
        let path = NSBezierPath()
        func line(_ x: Double, _ y: Double, _ x2: Double, _ y2: Double) { path.move(to: CGPoint(x: x, y: y)); path.line(to: CGPoint(x: x2, y: y2)) }
        switch key {
        case .search: path.appendOval(in: CGRect(x: 2.6, y: 2.6, width: 8.8, height: 8.8)); line(10.4, 10.4, 13.6, 13.6)
        case .sidebar: path.appendRoundedRect(CGRect(x: 2.2, y: 3, width: 11.6, height: 10), xRadius: 1.8, yRadius: 1.8); line(6.3, 3, 6.3, 13)
        case .usage: path.appendArc(withCenter: CGPoint(x: 8, y: 8.7), radius: 6.2, startAngle: 142.2, endAngle: 397.8, clockwise: false); line(8, 9.5, 10.6, 6.4)
        case .settings:
            line(2.5, 5, 8.3, 5); line(11.7, 5, 13.5, 5); line(2.5, 11, 4.3, 11); line(7.7, 11, 13.5, 11)
            path.appendOval(in: CGRect(x: 8.3, y: 3.3, width: 3.4, height: 3.4)); path.appendOval(in: CGRect(x: 4.3, y: 9.3, width: 3.4, height: 3.4))
        case .newChat, .addToDock: break
        }
        return path.cgPath
    }
}
