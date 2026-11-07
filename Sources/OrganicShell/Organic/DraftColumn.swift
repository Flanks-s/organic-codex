import AppKit

/// New Chat's draft column (f047, f078; product NewChatColumn and NewChatHero, docs/reference/NEWCHAT-SPEC-26102909.md):
/// the seed — an 88 pt planet over a 42 pt "New Chat" nameplate, without badge, context or satellites — centred in the
/// column, and the context row at its foot (project, device, close). Native; it comes in from beyond the window's right
/// edge on its own spring (0.48 / 0.88) and goes back out on 0.36 / 0.90, placed per frame by the scene's clock.
@MainActor final class DraftColumn: NSView {
    override var isFlipped: Bool { true }
    /// A brief's empty space passes clicks on; the seed and the row take them.
    override func hitTest(_ point: NSPoint) -> NSView? { let v = super.hitTest(point); return v === self ? nil : v }

    let island = HeaderIsland()
    let contextRow: DraftContextRow
    private let close = NativeButton(frame: .zero)
    let motionInk=M10DraftExposure(frame:.zero)
    /// M10_DRAFT_EXPOSURE=0: off, for live on/off comparisons.
    var exposureEnabled=ProcessInfo.processInfo.environment["M10_DRAFT_EXPOSURE"] != "0"
    var motionProfile:DisplayProfile?
    var onClose: (() -> Void)?

    private(set) var column = CGRect.zero
    private var offset = Spring.rest(0), began = 0.0
    private var leaving = false
    private var motionActive=false
    private var inkPreparation: (appearance:Int,scale:CGFloat)?
    private func prepareMotionInk() {
        let scale=max(1,window?.backingScaleFactor ?? island.configuration?.scale ?? 1)
        if let key=inkPreparation,key.appearance==NativeAppearance.revision,key.scale==scale {return}
        let work=M10ColumnWorkTrace.scope("draft.capture");defer{work.end()}
        motionInk.prepare(in:self,scale:scale)
        inkPreparation=(NativeAppearance.revision,scale)
    }
    var isLeaving: Bool { leaving }
    var isMoving: Bool { motionActive }
    /// When its spring is at rest (media time).
    var settles: Double { began + offset.duration }

    init(placeholder: Conversation, store: ConversationStore, scale: CGFloat) {
        contextRow = DraftContextRow(store: store)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(island)
        island.configure(.conversation(placeholder, variant: .newChat, columnWidth: 192, band: 0, ambient: true, scale: scale))
        addSubview(contextRow)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close New Chat")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        close.contentTintColor = Look.secondary
        close.imagePosition = .imageOnly
        close.toolTip = "Close New Chat (Esc)"
        close.setAccessibilityLabel("Close New Chat")
        close.target = self; close.action = #selector(closeClicked)
        addSubview(close)
        addSubview(motionInk)
        contextRow.onVisualChange = { [weak self] in
            guard let self else { return }
            self.inkPreparation=nil
            guard self.motionActive else { return }
            self.contextRow.layoutSubtreeIfNeeded()
            self.prepareMotionInk()
        }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("New conversation")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func closeClicked() { onClose?() }

    /// Lays out for its column (logical, scene coordinates): the seed's centre in the room between the header band and
    /// the context row (NativeNewChatLayout: tall windows centre it, short ones raise it into the header band).
    func lay(_ column: CGRect) {
        motionInk.reset()
        inkPreparation=nil
        self.column = column
        let w = column.width, h = column.maxY
        frame = CGRect(x: column.minX + offset.sample(.infinity).value, y: 0, width: w, height: h)
        // NativeNewChatLayout.content computes 104 in unbled content; auto then adds bleed.top (52).
        let top = Look.contentTop.full, row = h - 28
        let centre = row - 24 - top >= 150 ? (top + row - 24) / 2 - 24 : top - 56
        let seed = island.motionGeometry(variant: .newChat, columnWidth: 192)
        island.endMotion()
        island.frame = CGRect(x: ((w - 192) / 2).rounded(), y: (centre - 63).rounded(), width: 192, height: seed.height)
        // 20 pt in, as the product's row (NewChatColumn: width − 40, the close button in the same row, 4 pt apart).
        contextRow.frame = CGRect(x: 20, y: row, width: max(0, w - 40 - 22 - 4), height: 22)
        close.frame = CGRect(x: w - 20 - 22, y: row, width: 22, height: 22)
        contextRow.layoutSubtreeIfNeeded()
        prepareMotionInk()
    }

    /// In from beyond the right edge of a window `width` wide.
    func enter(windowWidth width: CGFloat, now: Double) {
        leaving = false
        motionActive=true
        offset = Spring(from: width + 24 - column.minX, to: 0, response: 0.48, damping: 0.88, epsilon: Spring.restEpsilon)
        began = now
        prepareMotionInk()
        frame(at: now)
    }

    /// Back out to the right.
    func leave(windowWidth width: CGFloat, now: Double) {
        let c = offset.sample(now - began)
        leaving = true
        motionActive=true
        offset = Spring(from: c.value, to: width + 24 - column.minX, velocity: c.velocity, response: 0.36, damping: 0.90, epsilon: Spring.restEpsilon)
        began = now
        prepareMotionInk()
    }

    /// Driver A: where its spring has it now.
    func frame(at now: Double) {
        let profile=motionProfile ?? M10FExposure.profile(for:self),elapsed=max(0,now-began)
        let x=column.minX+offset.sample(elapsed).value,old=column.minX+offset.sample(max(0,elapsed-profile.frameInterval)).value
        setFrameOrigin(CGPoint(x:x,y:0))
        guard motionActive else { return }
        let current=CGRect(origin:CGPoint(x:x,y:0),size:bounds.size),previous=current.offsetBy(dx:old-x,dy:0)
        motionInk.update(in:self,now:current,earlier:previous,profile:profile,enabled:exposureEnabled)
        let planet=convert(island.geometry.planet,from:island).offsetBy(dx:x,dy:0)
        island.orb.exposeGlyphs(now:planet,earlier:planet.offsetBy(dx:old-x,dy:0),profile:profile,enabled:exposureEnabled)
        if elapsed>=offset.duration { motionInk.reset();island.orb.exposeGlyphs(now:planet,earlier:planet,profile:profile,enabled:false);motionActive=false }
    }
}
