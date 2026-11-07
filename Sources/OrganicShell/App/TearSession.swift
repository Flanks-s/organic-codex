import AppKit

/// One torn-off conversation between windows (f182–f186; product TearSession, TearOrbPanel, TearWindowGrowth;
/// docs/reference/TEAR-SPEC-26102909.md): an orb of glass in a floating panel under the pointer, a 2 pt outline on the
/// window it would merge into, and on the drop a merge, a new window, or the flight back.
@MainActor final class TearSession {
    let id: String
    let conversation: Conversation
    private(set) weak var source: OrganicWindow?
    private let panel: NSPanel
    private let glass = NSGlassEffectView()
    private let decoration: OrbComponent
    /// The dock's row and the press, in the source's content coordinates (flipped).
    private let row: CGFloat, press: CGPoint
    private let headerOrigin:CGPoint?
    private var carryOffset:DragCarryGeometry.TearOffset?
    private var carryClock:SceneClock?
    private var carryPointer:CGPoint?
    /// The source had only this member: it fades away while the orb is out, and closes if it does not come back.
    private(set) var single = false
    private weak var target: OrganicWindow?
    private var outline: OutlineView?
    static let orb: CGFloat = 40 * 1.12, panelSide: CGFloat = 144

    init(id: String, conversation: Conversation, source: OrganicWindow, row: CGFloat, press: CGPoint) {
        self.id = id; self.conversation = conversation; self.source = source; self.row = row; self.press = press
        headerOrigin=source.scene.dock.headerCarryOrigin
        let side = Self.panelSide
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        content.wantsLayer = true
        panel.contentView = content
        glass.style = .regular
        let o = Self.orb
        let r = CGRect(x: (side - o) / 2, y: (side - o) / 2, width: o, height: o)
        glass.frame = r; glass.cornerRadius = o / 2
        decoration = OrbComponent(id: "tear." + id, glassView: glass)
        decoration.setCanvasSize(content.bounds.size)
        content.addSubview(decoration.backView)
        content.addSubview(glass)
        content.addSubview(decoration.frontView)
        // The torn orb: liquid still, not running, no completions or alerts; its satellites keep orbiting.
        var c = makeOrbConfiguration(conversation, drawingSize: o, backingScale: source.window.backingScaleFactor, reduceMotion: Motion.reduce, ambient: true, isKeyWindow: true)
        c.running = false; c.completions = 0; c.redUnseen = false
        decoration.configure(c)
        decoration.setFrame(r, contentFrame: CGRect(x: 0, y: 0, width: o, height: o))
    }

    /// The panel's window number, for recording it on its own.
    var windowNumber: Int { panel.windowNumber }

    /// Detached: the panel shows at the pointer in the same frame the dock hides its node.
    func begin(at p: CGPoint, sourceHasOthers: Bool) {
        single = !sourceHasOthers
        panel.alphaValue = 0.01
        let now=CACurrentMediaTime()
        if headerOrigin != nil,let center=source?.scene.dock.items[id]?.glass.frame {
            // Header follow at the pressed row is x-aligned and lifted by four points.
            carryOffset=DragCarryGeometry.TearOffset(from:CGPoint(x:center.midX-p.x,y:center.midY-p.y),
                to:CGPoint(x:0,y:-4),at:now,spring:AutoScene.queueSpring)
        }
        carryPointer=p
        placeCarry(at:now)
        if let screen=screenPoint(p) {setTarget(findTarget(at:screen))}
        panel.orderFrontRegardless()
        CATransaction.begin(); CATransaction.setDisableActions(true); panel.alphaValue = 1; CATransaction.commit()
        if let offset=carryOffset,let content=panel.contentView {
            let clock=SceneClock();carryClock=clock
            clock.onFrame={ [weak self] time in
                guard let self,self.carryOffset?.isStopped == false else {return}
                self.placeCarry(at:time)
            }
            clock.attach(to:content);clock.run(until:now+offset.duration)
        }
        if !sourceHasOthers, let w = source?.window { fade(w, to: 0) }
    }

    /// `p`: the pointer in the source's content coordinates.
    func move(_ p: CGPoint) {
        guard carryOffset?.isStopped != true else {return}
        carryPointer=p;placeCarry(at:CACurrentMediaTime())
        if let screen=screenPoint(p) {setTarget(findTarget(at:screen))}
    }

    private func placeCarry(at time:Double) {
        guard let p=carryPointer,let screen=screenPoint(p) else {return}
        let offset=carryOffset?.advance(at:time) ?? CGPoint(x:0,y:row-press.y)
        let c=DragCarryGeometry.screenCenter(pointer:screen,offset:offset)
        panel.setFrameOrigin(CGPoint(x:(c.x-Self.panelSide/2).rounded(),y:(c.y-Self.panelSide/2).rounded()))
    }
    private func stopCarry(at pointer:CGPoint? = nil) {
        guard carryOffset != nil,carryOffset?.isStopped == false else {return}
        if let pointer {carryPointer=pointer}
        let now=CACurrentMediaTime()
        placeCarry(at:now);carryOffset?.stop(at:now);carryClock?.invalidate();carryClock=nil
    }

    enum Outcome { case merge(OrganicWindow, index: Int), newWindow(CGPoint), back }

    /// Where a drop at `p` leads: the outlined window, empty desktop (a new window), or back.
    func outcome(at p: CGPoint) -> Outcome {
        stopCarry(at:p)
        guard let screen = screenPoint(p) else { return .back }
        if let t = findTarget(at: screen) {
            if t === source { return .back }
            let local = t.root.convert(t.window.convertPoint(fromScreen: screen), from: nil)
            return .merge(t, index: t.scene.insertionIndex(at: local.x))
        }
        // No window takes it: the desktop, if a screen has it (a title bar or the source's reading area bounces).
        // Only conversation windows count: Settings, Tools or a sub-agent's window neither take it nor stop a new window
        // growing there (TearSession: coordinator.controllers; audit A17).
        let managed = (NSApp.delegate as? AppController)?.windows.map(\.window) ?? []
        let blocked = managed.contains { $0.isVisible && $0.alphaValue > 0.01 && $0.frame.contains(screen) && !(single && $0 === source?.window) }
        if !blocked, NSScreen.screens.contains(where: { $0.visibleFrame.contains(screen) }) { return .newWindow(screen) }
        return .back
    }

    /// Back where it came from: 0.28 s ease-out to the press's x on the dock's row, then gone.
    func flyBack(then done: @escaping @MainActor () -> Void) {
        stopCarry()
        setTarget(nil)
        if let w = source?.window, single { fade(w, to: 1) }
        guard let home = screenPoint(headerOrigin ?? CGPoint(x: press.x, y: row)) else { retire(); done(); return }
        let reduce = Motion.reduce
        let f = CGRect(x: (home.x - Self.panelSide / 2).rounded(), y: (home.y - Self.panelSide / 2).rounded(), width: Self.panelSide, height: Self.panelSide)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0 : 0.28; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(f, display: true)
            // The app has already let go of this session on a drop or Esc, so the flight keeps it alive until it lands.
            // A weak capture here left the panel on screen for good, floating above other apps.
        }, completionHandler: { MainActor.assumeIsolated { self.retire(); done() } })
    }

    /// Gone: after a merge at once, after a new window once it has drawn (0.2 s).
    func retire(after delay: Double = 0) {
        stopCarry()
        setTarget(nil)
        let p = panel, d = decoration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { p.orderOut(nil); d.dispose() } }
    }

    isolated deinit {carryClock?.invalidate()}

    // MARK: Targets

    /// Front to back, the first Organic window whose frame has the point decides: another one takes it anywhere in its
    /// content inset by the orb's radius; the source only on its dock's row (±30 pt). Other windows do not block.
    private func findTarget(at screen: CGPoint) -> OrganicWindow? {
        guard let app = NSApp.delegate as? AppController else { return nil }
        for w in NSApp.orderedWindows where w !== panel && w.isVisible && !w.isMiniaturized && w.alphaValue > 0.01 {
            guard let ow = app.windows.first(where: { $0.window === w }) else { continue }
            guard w.frame.contains(screen) else { continue }
            if ow.isCollapsed { return nil }
            let local = ow.root.convert(w.convertPoint(fromScreen: screen), from: nil)
            if ow === source { return abs(local.y - row) <= 30 && !single ? ow : nil }
            let inset = ow.root.bounds.insetBy(dx: Self.orb / 2, dy: Self.orb / 2)
            return inset.contains(local) ? ow : nil
        }
        return nil
    }

    private func setTarget(_ t: OrganicWindow?) {
        guard t !== target || (t == nil && outline != nil) else { return }
        outline?.removeFromSuperview(); outline = nil
        target = t
        guard let t, t !== source, let host = t.window.contentView else { return }
        let o = OutlineView(frame: host.bounds)
        o.autoresizingMask = [.width, .height]
        host.addSubview(o, positioned: .above, relativeTo: nil)
        outline = o
    }

    private func screenPoint(_ p: CGPoint) -> CGPoint? {
        guard let s = source else { return nil }
        return s.window.convertPoint(toScreen: s.root.convert(p, to: nil))
    }

    private func fade(_ w: NSWindow, to alpha: CGFloat) {
        let reduce = Motion.reduce
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = reduce ? 0 : 0.15; w.animator().alphaValue = alpha }
    }

    /// The merge target's outline: 2 pt, the accent at 65 %, radius 12, over its whole content.
    final class OutlineView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            path.lineWidth = 2; path.stroke()
        }
    }
}
