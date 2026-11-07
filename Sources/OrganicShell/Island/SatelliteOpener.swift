import AppKit
import QuartzCore

/// Product SubAgentWindow.swift:161–195. The row owns input, the host owns window opening.
/// The floating dot has one solid plate and one face; neither is ever put in a replica tree.
@MainActor final class SatelliteOpener: IslandOrbDragGesture {
    static let minimumDistance: CGFloat = 6
    static let openingDistance: CGFloat = 28
    static let magnification: CGFloat = 1.25
    static let response = 0.3, damping = 0.72
    var satellite: OrbSatellite
    var diameter: CGFloat
    var open: ((CGPoint?) -> Void)?
    var hiddenAtRest = true
    var carryingChanged: ((Bool) -> Void)?
    var admitted: () -> Bool = { true }
    private weak var button: IslandButton?
    private weak var canvas: NSView?
    private var start = CGPoint.zero, origin = CGPoint.zero
    private(set) var translation = CGSize.zero
    private(set) var dragging = false
    private(set) var carriedLayer: CALayer?
    private var monitor: Any?, retirement: DispatchWorkItem?
    private var pressed = false
    private var carrying = false
    var isPressed: Bool { pressed }

    init(satellite: OrbSatellite, diameter: CGFloat) { self.satellite = satellite; self.diameter = diameter }
    isolated deinit { retirement?.cancel(); if let monitor { NSEvent.removeMonitor(monitor) }; carriedLayer?.removeFromSuperlayer() }

    func begin(from button: IslandButton, event: NSEvent) -> (any IslandOrbDragGesture)? {
        guard admitted(), button.participates, !button.isHiddenOrHasHiddenAncestor else { return nil }
        cancel()
        self.button = button
        var host: NSView = button
        while let parent = host.superview { host = parent }
        canvas = host; start = host.convert(event.locationInWindow, from: nil)
        let rect = host.convert(button.bounds, from: button)
        origin = CGPoint(x: rect.midX, y: rect.midY)
        pressed = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, self.pressed else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }; self.cancel(); return nil
            }
            if event.type == .leftMouseDragged { self.dragged(with: event) }
            else { self.released(with: event) }
            return nil
        }
        return self
    }

    func dragged(with event: NSEvent) {
        guard pressed, admitted(), let canvas else { cancel(); return }
        let p = canvas.convert(event.locationInWindow, from: nil)
        move(translation: CGSize(width: p.x-start.x, height: p.y-start.y))
    }
    /// Also used by windowless hosts to feed their own pointer coordinates.
    func move(translation: CGSize) {
        self.translation = translation
        guard dragging || hypot(translation.width, translation.height) >= Self.minimumDistance else { return }
        dragging = true
        if !carrying {carrying=true;carryingChanged?(true)}
        if carriedLayer == nil, let canvas {
            canvas.wantsLayer = true
            let dot = Self.dot(satellite, diameter: diameter, scale: canvas.window?.backingScaleFactor ?? 2)
            dot.name = "satellite.opener.solid"; dot.zPosition = 10000
            canvas.layer?.addSublayer(dot); carriedLayer = dot
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        carriedLayer?.position = CGPoint(x: origin.x+translation.width, y: origin.y+translation.height)
        carriedLayer?.setAffineTransform(CGAffineTransform(scaleX: Self.magnification, y: Self.magnification))
        CATransaction.commit()
    }
    func released(with event: NSEvent) {
        guard pressed else { return }
        // Include a final location even if AppKit coalesced the last drag event.
        if dragging { dragged(with: event) }
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let wasDragging = dragging
        let shouldOpen = admitted() && wasDragging && hypot(translation.width, translation.height) > Self.openingDistance
        let click = !wasDragging && admitted() && button.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } == true
        finishInput()
        if shouldOpen {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            open?(screen)
        } else if click { open?(nil) }
        rebound()
    }
    func cancel() {
        finishInput(); retirement?.cancel(); retirement = nil
        carriedLayer?.removeFromSuperlayer(); carriedLayer = nil
        if carrying {carrying=false;carryingChanged?(false)}
        translation = .zero; dragging = false
    }
    private func finishInput() {
        pressed = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        button?.endPointerGesture()
    }
    private func rebound() {
        guard let dot = carriedLayer else { translation = .zero; dragging = false; return }
        if let button,let canvas {
            let rect=canvas.convert(button.bounds,from:button);origin=CGPoint(x:rect.midX,y:rect.midY)
        }
        let from = dot.position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.position = origin; dot.transform = CATransform3DIdentity; dot.opacity = hiddenAtRest ? 0.001:1
        CATransaction.commit()
        for (key, a, b) in [("position", NSValue(point: from) as Any, NSValue(point: origin) as Any),
                            ("transform.scale", Self.magnification as Any, 1 as Any), ("opacity", 1 as Any, (hiddenAtRest ? 0.001:1) as Any)] {
            let spring = CASpringAnimation(keyPath: key)
            let w = 2 * Double.pi / Self.response
            spring.mass = 1; spring.stiffness = w*w; spring.damping = 2*Self.damping*w
            spring.fromValue = a; spring.toValue = b; spring.duration = spring.settlingDuration
            dot.add(spring, forKey: "satellite.return."+key)
        }
        let duration = (dot.animation(forKey: "satellite.return.position")?.duration ?? 1)
        let work = DispatchWorkItem { [weak self, weak dot] in
            guard let self,let dot,self.carriedLayer === dot else{return}
            dot.removeFromSuperlayer();self.carriedLayer=nil
            if self.carrying {self.carrying=false;self.carryingChanged?(false)}
        }
        retirement = work; DispatchQueue.main.asyncAfter(deadline: .now()+duration, execute: work)
        translation = .zero; dragging = false
    }
    private static func dot(_ satellite: OrbSatellite, diameter d: CGFloat, scale: CGFloat) -> CALayer {
        let dot = CAShapeLayer(); dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.path = CGPath(ellipseIn:dot.bounds,transform:nil)
        dot.fillColor = OrbDisplayEnvironment.surface(satellite.done ? .systemGray:.controlAccentColor, opacity: satellite.done ? 0.85:0.9).cgColor
        dot.lineWidth = 0.5; dot.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        ReplicaContainerAudit.register(dot, material: .container, note: "Single satellite plate, never replicated")
        let face = CATextLayer(), system = NSFont.systemFont(ofSize: d*0.34, weight: .semibold)
        let descriptor=system.fontDescriptor.withDesign(.rounded) ?? system.fontDescriptor
        var font=NSFont(descriptor:descriptor,size:d*0.34) ?? system
        let width=(satellite.face as NSString).size(withAttributes:[.font:font]).width
        if width>d {font=NSFont(descriptor:descriptor,size:d*0.34*max(0.5,d/width)) ?? font}
        face.string = satellite.face; face.font = font; face.fontSize = font.pointSize; face.alignmentMode = .center
        face.foregroundColor = NSColor.white.withAlphaComponent(satellite.done ? 0.75:1).cgColor
        face.contentsScale = scale*2
        let h = font.ascender-font.descender
        face.frame = CGRect(x: 0, y: (d-h)/2, width: d, height: h); dot.addSublayer(face)
        return dot
    }
}
