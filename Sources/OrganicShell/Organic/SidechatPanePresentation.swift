import AppKit
import QuartzCore

/// A discrete event drives each transition. The host samples only while a transition is active.
@MainActor final class SidechatPanePresentation: NativeFlippedView, NSMenuDelegate {
    private struct Transition {
        let initial: CGFloat
        let target: CGFloat
        let start: TimeInterval
        let duration: TimeInterval

        func value(at time: TimeInterval) -> CGFloat {
            let t = CGFloat(min(1, max(0, (time - start) / duration)))
            let progress = t * t * (3 - 2 * t)
            return initial + (target - initial) * progress
        }
    }

    let pane = NativeSidechatPane(frame: .zero)
    private let filamentInk = OverlayInkView()
    let moon = SheetButton(frame: .zero)
    let confirmation = SheetForm()
    private var placement: ExpandPaneLayout?
    var sidechatStructure: (onRight: Bool, overlaysParent: Bool)?
    private var transition: Transition?
    private var drop: Transition?
    private(set) var reveal: CGFloat = 0
    private(set) var dropProgress: CGFloat?
    private(set) var folded = true
    private(set) var closed = false
    private var reduce: Bool
    private let now: () -> TimeInterval
    var onClose: (() -> Void)?
    var hasMotion: Bool { transition != nil || drop != nil }

    init(reducedMotion: Bool = Motion.reduce, now: @escaping () -> TimeInterval = CACurrentMediaTime) {
        reduce = reducedMotion
        self.now = now
        super.init(frame: .zero)
        pane.editor.sendShortcut = AutoScene.sendShortcut
        addSubview(pane)
        addSubview(filamentInk)
        addSubview(moon)
        pane.isHidden = true
        filamentInk.paint = { [weak self] _ in self?.drawFilament() }
        moon.drawsPlate = false
        moon.menu = NSMenu()
        moon.menu?.delegate = self
        moon.setAccessibilityLabel("Open sidechat")
        moon.invoke = { [weak self] in self?.toggleMoon() }
        moon.drawContent = { [weak self] rect in
            guard let self else { return }
            let ball = NSBezierPath(ovalIn: rect)
            NSColor.white.withAlphaComponent(0.17).setFill()
            ball.fill()
            NSGraphicsContext.saveGraphicsState()
            ball.addClip()
            let tide = rect.height * (pane.content.running ? 0.62 : 0.35)
            pane.moonColor.withAlphaComponent(0.48).setFill()
            NSBezierPath(rect: CGRect(x: rect.minX, y: rect.maxY - tide, width: rect.width, height: tide)).fill()
            NSGraphicsContext.restoreGraphicsState()
            SheetStyle.text("☽︎", in: rect.offsetBy(dx: 0, dy: 4), size: 14, color: pane.moonColor, align: .center)
        }
        pane.onContentChanged = { [weak moon = moon] in moon?.needsDisplay = true }
        pane.onFold = { [weak self] in self?.fold() }
        pane.onClose = { [weak self] in self?.requestClose() }
        pane.setAccessibilityCustomActions([.init(name: "Fold") { [weak self] in
            guard let self, !folded, !closed else { return false }
            fold()
            return true
        }])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleMoon() {
        if folded { open() } else { fold() }
    }

    @objc private func sendFromMoon() { pane.sendToMain() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !closed, !confirmation.isShowing else { return }
        func add(_ name: String, action: Selector) {
            let item = menu.addItem(withTitle: name, action: action, keyEquivalent: "")
            item.target = self
        }
        add(folded ? "Open" : "Fold", action: #selector(toggleMoon))
        if pane.canSendToMain { add("Send to main", action: #selector(sendFromMoon)) }
        add("Close sidechat", action: #selector(requestClose))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === filamentInk { return pane.hitTest(convert(point, from: superview)) }
        return hit === self ? nil : hit
    }

    func place(_ value: ExpandPaneLayout) {
        placement = value
        updateGeometry()
    }

    func open() {
        guard folded, !closed else { return }
        folded = false
        moon.setAccessibilityLabel("Fold sidechat")
        animate(to: 1, duration: 0.42)
        _ = window?.makeFirstResponder(pane.editor)
    }

    func fold() {
        guard !folded, !closed else { return }
        folded = true
        moon.setAccessibilityLabel("Open sidechat")
        pane.editor.unmarkText()
        _ = window?.makeFirstResponder(nil)
        animate(to: 0, duration: 0.34)
    }

    @objc func requestClose() {
        guard !closed, !confirmation.isShowing else { return }
        if pane.needsCloseConfirmation {
            confirmClosure(title: "Close sidechat?", names: []) { [weak self] accepted in
                if accepted { self?.close() }
            }
        } else {
            close()
        }
    }

    func confirmClosure(title: String, names: [String], action: String = "Close",
                        completion: @escaping (Bool) -> Void) {
        let message = names.isEmpty
            ? "The sidechat’s draft and conversation will be lost."
            : "These sidechats will close:\n" + names.joined(separator: "\n")
        confirmation.onConfirm = { _ in completion(true) }
        confirmation.onCancel = { completion(false) }
        confirmation.card.usesOpaqueBacking = true
        confirmation.reduceMotion = true
        let bottom = CGRect(x: bounds.midX, y: bounds.maxY - 12, width: 0, height: 0)
        let anchor = names.isEmpty && placement?.overlaysParent == true ? bottom : nil
        confirmation.present(.init(title: title, message: message, confirmTitle: action, destructive: true),
                             anchor: anchor, in: self)
    }

    private func close() {
        fold()
        closed = true
        drop = nil
        dropProgress = nil
        pane.clear()
        onClose?()
        updateGeometry()
    }

    func acceptQuoteReceipt() {
        guard !closed, pane.markSent() else { return }
        if !reduce, placement != nil {
            drop = Transition(initial: 0, target: 1, start: now(), duration: 0.48)
            needsDisplay = true
        }
    }

    func setReducedMotion(_ value: Bool) {
        reduce = value
        if value {
            reveal = folded ? 0 : 1
            transition = nil
            drop = nil
            dropProgress = nil
            updateGeometry()
        }
    }

    private func animate(to target: CGFloat, duration: TimeInterval) {
        if reduce {
            reveal = target
            transition = nil
        } else {
            transition = Transition(initial: reveal, target: target, start: now(), duration: duration)
        }
        updateGeometry()
    }

    func advance(at time: TimeInterval) {
        if let transition {
            reveal = transition.value(at: time)
            if time >= transition.start + transition.duration { self.transition = nil }
        }
        if let drop {
            if time >= drop.start + drop.duration {
                self.drop = nil
                dropProgress = nil
            } else {
                dropProgress = drop.value(at: time)
            }
        }
        updateGeometry()
    }

    private func updateGeometry() {
        guard let placement else { return }
        pane.frame = placement.pane
        pane.reveal(reveal, fromLeft: placement.anchor.x <= placement.pane.midX,
                    opaqueBacking: placement.overlaysParent)
        pane.isHidden = closed || (folded && reveal == 0)
        pane.setAccessibilityHidden(folded || closed)
        let center = mix(placement.moon, placement.mouth, reveal)
        moon.frame = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
        moon.isHidden = closed && reveal == 0
        filamentInk.frame = bounds
        filamentInk.needsDisplay = true
    }

    private func mix(_ from: CGPoint, _ to: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    private func drawFilament() {
        guard let placement, !closed || reveal > 0 else { return }
        let tip = mix(placement.moon, placement.mouth, reveal)
        let crossesContent = placement.pane.contains(tip) && tip.y > placement.mouth.y + 6
        if !placement.overlaysParent, !crossesContent {
            let onLeft = placement.anchor.x < placement.pane.midX
            let entryX = onLeft ? moon.frame.minX : moon.frame.maxX
            let edge = onLeft ? min(placement.pane.minX, entryX) - 6 : max(placement.pane.maxX, entryX) + 6
            pane.moonColor.withAlphaComponent(0.55).setStroke()
            let filament = NSBezierPath()
            filament.move(to: placement.anchor)
            filament.line(to: CGPoint(x: edge, y: placement.anchor.y))
            filament.line(to: CGPoint(x: edge, y: tip.y))
            filament.line(to: CGPoint(x: entryX, y: tip.y))
            filament.lineJoinStyle = .round
            filament.stroke()
        }
        pane.moonColor.setFill()
        let marker = placement.anchor
        NSBezierPath(ovalIn: CGRect(x: marker.x - 3, y: marker.y - 3, width: 6, height: 6)).fill()
        if let dropProgress {
            let sag = CGPoint(x: (tip.x + marker.x) / 2, y: max(tip.y, marker.y) + 12)
            let a = mix(tip, sag, dropProgress)
            let b = mix(sag, marker, dropProgress)
            let center = mix(a, b, dropProgress)
            NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
        }
    }

    func dispose() {
        confirmation.dismiss(reason: .cancelled, animated: false)
        pane.dispose()
        removeFromSuperview()
    }
}
