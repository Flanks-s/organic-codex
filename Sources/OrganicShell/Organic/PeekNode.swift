import AppKit
import QuartzCore

/// Peek (f045–f046; product NativeDockPeekContent, HaloBlur, BriefSummary `peek`): over the orb's column a blur halo,
/// feathered out past a brief-sized core, with its soft shadow and the conversation's brief as lyrics, bottom up. The
/// capsule it opens into and the satellites' row are the dock's (the orb's own glass, budded out). The plane sits between
/// the native transcripts and the dock, so the blur takes in a full column's native view as well as the briefs.
@MainActor final class PeekNode {
    final class Plane: NSView {
        var covers: (CGPoint) -> Bool = { _ in false }
        var click: ((CGPoint) -> Void)?
        var scroll: ((CGFloat, CGPoint) -> Void)?
        var orbInput: ((NSEvent) -> Bool)?
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) { if orbInput?(event) != true { click?(convert(event.locationInWindow, from: nil)) } }
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) { _ = orbInput?(event) }
        override func pressureChange(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) { scroll?(event.scrollingDeltaY, convert(event.locationInWindow, from: nil)) }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let p = superview == nil ? point : convert(point, from: superview)
            let hit = super.hitTest(point)
            if let hit, hit !== self { return hit }
            return covers(p) ? self : nil
        }
    }

    /// A visual endpoint only: the existing Peek surface keeps all pointer and scroll ownership.
    final class HeaderPlane: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let view = Plane()
    lazy var pointerShield = NativePointerShield(plane: view)
    private var pointerRegions: [CGRect] = []
    private var pointerPassage = CGRect.zero
    func coversPointer(_ p: CGPoint) -> Bool {
        containsPointerSurface(p) && !pointerPassage.contains(p)
    }
    private let root = CALayer()
    // Keep the native endpoint prepared but detached while closed: no extra WindowServer glass at rest.
    let header = HeaderIsland()
    private let headerPlane = HeaderPlane()
    private(set) var headerVisible = false
    var headerFrame: CGRect? { headerPlane.superview == nil ? nil : headerPlane.frame }
    func containsPointerSurface(_ p: CGPoint) -> Bool {
        shown != nil && pointerRegions.contains { $0.contains(p) }
    }
    /// The halo: the picker's backdrop blur and wash, shaped to the core and feathered `feather` past it. It grows from
    /// 70 % about a point near its bottom (the orb) and shrinks back to it as it closes.
    private let halo = CALayer()
    private let backdrop: CALayer = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init() ?? CALayer()
    private let backdropMask = CALayer(), wash = CALayer()
    /// The lyrics: a clip whose top fades over 16 pt (BriefSummary fixedFade), one row per summary line.
    private let lyrics = CALayer(), lyricsFade = CAGradientLayer(), content = CALayer()
    private var rows: [CALayer] = []
    var motionProfile: DisplayProfile?
    var motionEnabled = true
    var onMotionFrame: ((M10DockFrame) -> Void)?
    private var rowTrails: [CAReplicatorLayer] = []
    private var glyphTrails: [(layer: CALayer, trail: M10DockLayerGlyph)] = []
    private var movingDots: [(layer: DotsLayer, frame: CGRect)] = []
    private var scrollExposureEpoch = 0
    private var exposureProfile: DisplayProfile { M10DockMotion.profile(for: view, override: motionProfile) }
    private func resetScrollExposure() {
        glyphTrails.forEach { $0.trail.reset() }
        for (dots, frame) in movingDots { dots.transform = CATransform3DIdentity; dots.frame = frame }
    }
    private var restY: CGFloat = 0, scrollRange: CGFloat = 0, scrolled: CGFloat = 0
    /// The capsule's float shadow (FloatShadow capsuleAmbient / capsuleContact), following the glass per frame.
    private let capsuleShadow = CALayer(), capsuleMask = CAShapeLayer()
    private var capsuleLayers: [CALayer] = []
    private var capsuleShown = false
    private(set) var shown: String?
    private var core = CGRect.zero
    private var imageKey: PeekHalo.Key?
    var scale: CGFloat
    var ambient = true
    private var satelliteButtons:[String:IslandButton]=[:]
    private var satelliteOpeners:[String:SatelliteOpener]=[:]
    func satellites(_ values:[OrbSatellite],positions:[String:CGFloat],rowY:CGFloat,diameter:CGFloat,
                    open:@escaping (String,CGPoint?)->Void) {
        let ids=Set(positions.keys)
        for id in satelliteButtons.keys.filter({!ids.contains($0)}) {
            satelliteOpeners.removeValue(forKey:id)?.cancel();satelliteButtons.removeValue(forKey:id)?.removeFromSuperview()
        }
        for s in values {
            guard let x=positions[s.id] else{continue}
            let button=satelliteButtons[s.id] ?? IslandButton()
            if button.superview == nil {view.addSubview(button);satelliteButtons[s.id]=button}
            button.drawsText=false;button.circular=true;button.linkCursor=true;button.circularHit=true;button.drawsPointerHighlight=false;button.text="Sub-agent \(s.face), \(s.done ? "done":"running")"
            button.frame=CGRect(x:x-diameter/2,y:rowY-diameter/2,width:diameter,height:diameter)
            button.invoke={open(s.id,nil)}
            let opener=satelliteOpeners[s.id] ?? SatelliteOpener(satellite:s,diameter:diameter)
            satelliteOpeners[s.id]=opener;opener.satellite=s;opener.diameter=diameter
            opener.admitted={ [weak self] in self?.shown != nil && self?.satelliteButtons[s.id] === button }
            opener.open={point in open(s.id,point)}
            button.beginPointerGesture={ [weak button,weak opener] event in guard let button else{return nil};return opener?.begin(from:button,event:event) }
        }
    }
    func clearSatellites() {
        satelliteOpeners.values.forEach{$0.cancel()};satelliteOpeners=[:]
        satelliteButtons.values.forEach{$0.removeFromSuperview()};satelliteButtons=[:]
    }
    static let feather = PeekHalo.outer

    init(size: CGSize, scale: CGFloat) {
        self.scale = scale
        view.layer = root
        view.wantsLayer = true
        view.covers = { [weak self] in self?.coversPointer($0) == true }
        view.frame = CGRect(origin: .zero, size: size)
        headerPlane.wantsLayer = true
        headerPlane.addSubview(header)
        header.motionExposure.enabled = false
        for l in [backdrop, backdropMask, wash, lyrics, content, capsuleShadow] { l.anchorPoint = .zero }
        // M11.13 pixel-aligned exception to product HaloBlur: a distance-field fog, no plate silhouette.
        halo.name = "peek.halo"; backdrop.name = "peek.backdrop"; wash.name = "peek.wash"
        capsuleShadow.name = "peek.capsule-shadow"
        backdrop.setValue(1.0, forKey: "scale")
        backdrop.filters = [OverlayFilter.make("colorSaturate", values: ["inputAmount": 1.5]),
                            OverlayFilter.make("gaussianBlur", values: ["inputRadius": 22, "inputNormalizeEdges": true])].compactMap { $0 }
        backdrop.mask = backdropMask
        halo.addSublayer(backdrop)
        // Its wash carries the picker's shadow (black 0.4, radius 18, y 16).
        wash.contentsGravity = .resize
        wash.shadowColor = NSColor.black.cgColor; wash.shadowOpacity = 0.4; wash.shadowRadius = 18
        wash.shadowOffset = CGSize(width: 0, height: 16)
        halo.addSublayer(wash)
        halo.anchorPoint = CGPoint(x: 0.5, y: 0.85)
        halo.opacity = 0
        root.addSublayer(halo)
        lyrics.masksToBounds = true
        lyricsFade.anchorPoint = .zero
        lyricsFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        lyrics.mask = lyricsFade
        lyrics.addSublayer(content)
        root.addSublayer(lyrics)
        // FloatShadow capsuleAmbient (18, y 10, 0.38) and capsuleContact (4, y 2, 0.24).
        for (radius, y, opacity) in [(CGFloat(18), CGFloat(10), Float(0.38)), (4, 2, 0.24)] {
            let l = CALayer()
            l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = opacity; l.shadowRadius = radius
            l.shadowOffset = CGSize(width: 0, height: y)
            capsuleShadow.addSublayer(l); capsuleLayers.append(l)
        }
        capsuleMask.fillRule = .evenOdd
        capsuleShadow.mask = capsuleMask
        capsuleShadow.opacity = 0
        root.addSublayer(capsuleShadow)
    }

    func resize(to size: CGSize) { view.frame = CGRect(origin: .zero, size: size) }

    /// Opens (or moves to another conversation while open): the halo over `geometry.blur`, the brief in its lyrics.
    func open(_ c: Conversation, geometry g: AutoLayout.Peek, showHeader: Bool = true) {
        let moving = shown != nil && halo.opacity > 0
        shown = c.id
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let headerWork = M10ColumnWorkTrace.scope("peek.header")
        var input = HeaderIslandConfiguration.conversation(c, variant: .brief, columnWidth: g.blur.width,
                                                          band: HeaderIslandVariant.band(bleedTop: g.blur.minY),
                                                          reduceMotion: Motion.reduce, ambient: ambient, scale: scale)
        input.active = false
        // The existing Peek row owns the satellites; do not draw another orbit above it.
        input.signals.satellites = []
        header.configure(input)
        // A passive endpoint must settle immediately when a differently sized Peek replaces it.
        header.setPresentationActive(false)
        header.setFrameOrigin(.zero)
        headerPlane.frame = CGRect(x: g.blur.minX, y: 0,
                                  width: header.frame.width, height: header.frame.height)
        if headerPlane.superview == nil { view.addSubview(headerPlane) }
        // The header was configured before its host moved; resolve LL after the final common-space placement.
        header.orb.setFrame(header.geometry.planet)
        setHeaderVisible(showHeader)
        headerWork.end()
        // Cover the actual painted header, not its transparent canvas above the Peek. Pointer and halo
        // geometry are independent of the lyrics clip; normal Peek geometry already contains both pieces.
        let surface = g.blur.union(header.geometry.planet.offsetBy(dx: headerPlane.frame.minX, dy: 0))
            .union(header.geometry.capsule.offsetBy(dx: headerPlane.frame.minX, dy: 0))
        let f = Self.feather, frame = surface.insetBy(dx: -f, dy: -f)
        let imageWork = M10ColumnWorkTrace.scope("peek.images")
        let key = PeekHalo.Key(size: frame.size, scale: scale)
        if key != imageKey, let images = PeekHalo.images(for: key) {
            imageKey = key
            backdropMask.contents = images.mask
            wash.contents = images.wash
        }
        imageWork.end()
        let from = (halo.presentation() ?? halo).position, fromBounds = (halo.presentation() ?? halo).bounds
        halo.bounds = CGRect(origin: .zero, size: frame.size)
        halo.position = CGPoint(x: frame.minX + 0.5 * frame.width, y: frame.minY + 0.85 * frame.height)
        for l in [backdrop, backdropMask, wash] { l.frame = halo.bounds }
        core = surface
        pointerRegions = [g.blur, header.geometry.planet.offsetBy(dx: headerPlane.frame.minX, dy: 0),
                          header.geometry.capsule.offsetBy(dx: headerPlane.frame.minX, dy: 0)]
        pointerPassage = g.capsule
        let lyricWork = M10ColumnWorkTrace.scope("peek.lyrics")
        // Match the real brief column's contentTop - 18 clip and existing 16pt gradient. This only changes
        // retained layer geometry; the halo mask/cache and all pointer regions remain independent.
        let lyricTop=max(g.lyrics.minY,header.geometry.contentTop-18)
        let lyricRect=CGRect(x:g.lyrics.minX,y:lyricTop,width:g.lyrics.width,height:max(1,g.lyrics.maxY-lyricTop))
        layoutLyrics(c, in: lyricRect)
        lyricWork.end()
        CATransaction.commit()
        if moving {
            // Another orb while open: the halo moves on the peek spring (0.3 / 0.86), its rows come in anew.
            for (key, value, to) in [("position", NSValue(point: from), NSValue(point: halo.position)),
                                     ("bounds", NSValue(rect: fromBounds), NSValue(rect: halo.bounds))] {
                let a = Self.spring(key, response: 0.3, damping: 0.86)
                a.fromValue = value; a.toValue = to
                halo.add(a, forKey: "peek." + key)
            }
        } else {
            // HaloBlur: from 70 % and transparent on blurIn (0.2, 1, 0.3, 1; 0.38 s).
            OverlayMotion.animate(halo, "opacity", from: 0, to: 1, curve: OverlayMotion.blurIn)
            OverlayMotion.animate(halo, "transform.scale", from: 0.7, to: 1, curve: OverlayMotion.blurIn)
        }
        enterRows()
    }

    /// The Dock's existing veil finishes before this endpoint appears; this is not an orb flight.
    func setHeaderVisible(_ visible: Bool, duration: Double = 0) {
        headerVisible = visible && shown != nil && headerPlane.superview != nil
        guard let layer = headerPlane.layer else { return }
        OverlayMotion.animate(layer, "opacity", from: layer.opacity, to: headerVisible ? 1 : 0,
                              curve: OverlayCurve(0, 0, 0.58, 1, duration), enabled: duration > 0)
    }

    private func detachHeader() {
        setHeaderVisible(false)
        headerPlane.removeFromSuperview()
    }

    /// A scroll over the halo (f045 "阅读可滚动"): back towards the brief's first lines, and down to its end again.
    func scroll(by dy: CGFloat) {
        guard shown != nil, scrollRange > 0 else { return }
        let previous = scrolled
        let previousGlyphs = Dictionary(uniqueKeysWithValues: glyphTrails.map { (ObjectIdentifier($0.layer), $0.layer.convert($0.layer.bounds, to: root)) })
        scrolled = min(scrollRange, max(0, scrolled + dy))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame.origin.y = restY + scrolled
        refreshVirtualLyrics(followEnd: scrolled == 0)
        let delta = scrolled-previous, profile = exposureProfile, now = CACurrentMediaTime()
        for (layer, trail) in glyphTrails {
            let r = layer.convert(layer.bounds, to: root)
            let f = M10DockMotion.frame(name: "peek.scroll.glyph", now: r, earlier: previousGlyphs[ObjectIdentifier(layer)] ?? r.offsetBy(dx: 0, dy: -delta), time: now,
                                       profile: profile, enabled: motionEnabled && M10DockMotion.enabled && !Motion.reduce)
            trail.update(layer, world: r, earlier: f.earlier, profile: profile, enabled: motionEnabled && M10DockMotion.enabled && !Motion.reduce)
            onMotionFrame?(f)
        }
        for (dots, r) in movingDots {
            let f = M10DockMotion.frame(name: "peek.scroll.dots", now: r, earlier: r.offsetBy(dx: 0, dy: -delta), time: now,
                                       profile: profile, enabled: motionEnabled && M10DockMotion.enabled && !Motion.reduce)
            dots.transform = CATransform3DMakeScale(1, f.painted.height/max(0.0001,r.height), 1)
            dots.position = f.painted.origin
            onMotionFrame?(f)
        }
        CATransaction.commit()
        scrollExposureEpoch += 1
        let epoch = scrollExposureEpoch
        DispatchQueue.main.asyncAfter(deadline: .now()+profile.frameInterval) { [weak self] in
            guard let self, self.scrollExposureEpoch == epoch else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true); self.resetScrollExposure(); CATransaction.commit()
        }
    }

    /// The close starts: the lyrics leave with the capsule's content (0.07 s).
    func fadeLyrics(duration: Double = 0.07) {
        // Finish before the existing 60 ms close stage unveils the Dock planet.
        setHeaderVisible(false, duration: min(duration, 0.06))
        OverlayMotion.animate(lyrics, "opacity", from: lyrics.opacity, to: 0, curve: OverlayCurve(0, 0, 0.58, 1, duration))
    }

    /// The halo closes (peekOpen false): to 70 % and transparent, ease-in 0.23 s.
    func retract() {
        setHeaderVisible(false)
        clearSatellites()
        OverlayMotion.animate(halo, "opacity", from: halo.opacity, to: 0, curve: OverlayMotion.blurOut)
        OverlayMotion.animate(halo, "transform.scale", from: 1, to: 0.7, curve: OverlayMotion.blurOut)
    }

    /// Gone at once with a short fade, when the peeked orb lands (its column grows where the halo was).
    func dismiss() {
        detachHeader()
        clearSatellites()
        let fade = OverlayCurve(0, 0, 0.58, 1, 0.12)
        for l in [halo, lyrics] { OverlayMotion.animate(l, "opacity", from: l.opacity, to: 0, curve: fade) }
        shown = nil
    }

    /// Nothing shown any more (shownPeek nil): the rows go.
    func clear() {
        detachHeader()
        clearSatellites()
        lyricConversation = nil; lyricLayouts = [:]; lyricRows = [:]; lyricHeights.reset([]); mountedLyricCount = 0
        shown = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        resetScrollExposure(); glyphTrails = []; movingDots = []; scrollExposureEpoch += 1
        rowTrails.forEach { $0.removeFromSuperlayer() }; rowTrails = []
        rows.forEach { $0.removeFromSuperlayer() }; rows = []
        CATransaction.commit()
    }

    /// The capsule's shadow at the peek glass's frame now, or fading away (nil).
    func placeCapsuleShadow(_ r: CGRect?) {
        if let r {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            capsuleShadow.frame = CGRect(origin: .zero, size: view.bounds.size)
            let radius = min(r.width, r.height) / 2
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            for l in capsuleLayers { l.frame = capsuleShadow.bounds; l.shadowPath = path }
            capsuleMask.frame = capsuleShadow.bounds
            let outside = CGMutablePath(); outside.addRect(capsuleShadow.bounds.insetBy(dx: -120, dy: -120)); outside.addPath(path)
            capsuleMask.path = outside
            CATransaction.commit()
        }
        guard (r != nil) != capsuleShown else { return }
        capsuleShown = r != nil
        OverlayMotion.animate(capsuleShadow, "opacity", from: capsuleShadow.opacity, to: capsuleShown ? 1 : 0, curve: OverlayCurve(0, 0, 0.58, 1, 0.12))
    }

    // MARK: Lyrics

    /// BriefSummary for a peek: 20 pt a side, 16 pt from the top, 22 from the bottom, its lines bottom-aligned in at least
    /// the viewport less 70, scrolled to the end; no title (the capsule names it).
    private var lyricConversation: Conversation?
    private var lyricHeights = NativeTranscriptHeightIndex()
    private var lyricLayouts: [Int: BriefLayout] = [:]
    private var lyricCount = 0
    private struct LyricRow {
        var layer: CALayer
        var glyphs: [(layer: CALayer, trail: M10DockLayerGlyph)] = []
        var dots: [(layer: DotsLayer, frame: CGRect)] = []
        var trail: CAReplicatorLayer?
    }
    private var lyricRows: [Int: LyricRow] = [:]
    private var lyricEntranceTime = -Double.infinity
    private var lyricWidth: CGFloat = 0, lyricColumnWidth: CGFloat = 0, lyricGap: CGFloat = 0
    private(set) var mountedLyricCount = 0
    private(set) var lyricDocumentHeight: CGFloat = 0
    // Offscreen equivalence probes; no window or display-server capture.
    var verificationLyricsLayer: CALayer { lyrics }
    func verificationScrollToLine(_ line: Int) {
        guard line >= 0, line < lyricCount else { return }
        scrolled = min(scrollRange, max(0, -lyricHeights.prefix(line) - restY))
        content.frame.origin.y = restY + scrolled
        refreshVirtualLyrics(followEnd: scrolled == 0)
    }


    private func layoutLyrics(_ c: Conversation, in r: CGRect) {
        resetScrollExposure(); glyphTrails = []; movingDots = []; scrollExposureEpoch += 1
        rowTrails.forEach { $0.removeFromSuperlayer() }; rowTrails = []
        rows.forEach { $0.removeFromSuperlayer() }; rows = []
        lyricConversation = c; lyricCount = c.summarySource.lineCount(c)
        lyricLayouts = [:]; lyricRows = [:]; lyricEntranceTime = -Double.infinity; scrolled = 0
        lyrics.removeAllAnimations(); lyrics.opacity = 1; lyrics.frame = r
        lyricsFade.frame = CGRect(origin: .zero, size: r.size)
        lyricsFade.locations = [0, NSNumber(value: Double(16 / max(16, r.height)))]
        lyricWidth = max(60, r.width - 40); lyricColumnWidth = r.width
        let size = Look.lyric(columnWidth: r.width).font.pointSize
        lyricGap = (size * 0.62).rounded()
        // Only cold, unseen geometry is estimated. Entering rows use the exact original BriefLayout and images.
        lyricHeights.reset(Array(repeating: size * 3 + lyricGap, count: lyricCount))
        positionLyrics()
        refreshVirtualLyrics(followEnd: true)
    }

    private func positionLyrics() {
        let height = max(0, lyricHeights.total - (lyricCount == 0 ? 0 : lyricGap))
        let minimum = max(0, lyrics.bounds.height - 70), document = 16 + max(height, minimum) + 22
        restY = 16 + max(0, minimum - height) + min(0, lyrics.bounds.height - document)
        scrollRange = max(0, document - lyrics.bounds.height)
        scrolled = min(scrollRange, max(0, scrolled))
        content.frame = CGRect(x: 20, y: restY + scrolled, width: lyricWidth, height: max(1, height))
        lyricDocumentHeight = height
    }

    private func refreshVirtualLyrics(followEnd: Bool = false) {
        guard let c = lyricConversation, lyricCount > 0 else { mountedLyricCount = 0; return }
        let anchorIndex = lyricHeights.row(at: -content.frame.minY)
        let anchorY = content.frame.minY + lyricHeights.prefix(anchorIndex)
        // Refine until the entire viewport is exact, including unexpectedly short rows. No full-history layout.
        while true {
            let first = lyricHeights.row(at: max(0, -content.frame.minY - 48))
            let last = lyricHeights.row(at: max(0, lyrics.bounds.height - content.frame.minY + 48))
            var measured = false
            for i in first...last where lyricLayouts[i] == nil {
                let log = c.summarySource.log(c, playful: Look.playful, range: i..<(i + 1))
                let layout = BriefLayout(log, width: lyricWidth, columnWidth: lyricColumnWidth, scale: scale,
                                         showsState: true, lastLineIsCurrent: i == lyricCount - 1)
                lyricLayouts[i] = layout; lyricHeights.set(layout.height + lyricGap, at: i)
                measured = true
            }
            positionLyrics()
            if !followEnd { scrolled = min(scrollRange, max(0, anchorY - lyricHeights.prefix(anchorIndex) - restY)); content.frame.origin.y = restY + scrolled }
            if !measured { break }
        }
        let first = lyricHeights.row(at: max(0, -content.frame.minY - 48))
        let last = lyricHeights.row(at: max(0, lyrics.bounds.height - content.frame.minY + 48))
        for line in Array(lyricRows.keys) where !(first...last).contains(line) {
            guard let row = lyricRows.removeValue(forKey: line) else { continue }
            row.glyphs.forEach { $0.trail.reset() }; row.trail?.removeFromSuperlayer(); row.layer.removeFromSuperlayer()
        }
        // Keep only viewport typography/images; measured scalar heights survive recycling. Existing row/entrance
        // layers remain resident while scrolling, just as they did in the complete document.
        lyricLayouts = lyricLayouts.filter { (first...last).contains($0.key) }
        var entered: [Int] = []
        for line in first...last {
            guard let layout = lyricLayouts[line], let firstPart = layout.parts.first else { continue }
            let box = layout.parts.dropFirst().reduce(firstPart.frame) { $0.union($1.frame) }
            if let row = lyricRows[line] {
                row.layer.frame.origin.y = lyricHeights.prefix(line); continue
            }
            let row = CALayer(); row.anchorPoint = .zero
            row.frame = CGRect(x: 0, y: lyricHeights.prefix(line), width: lyricWidth, height: box.height)
            row.name = "\(lyricCount - 1 - line)"
            var resident = LyricRow(layer: row)
            for part in layout.parts {
                let l = CALayer(); l.anchorPoint = .zero; l.frame = part.frame
                let text = CALayer(); text.anchorPoint = .zero; text.contentsScale = scale; text.contentsGravity = .resize
                text.contents = part.image; text.frame = CGRect(origin: .zero, size: part.frame.size)
                l.addSublayer(text); resident.glyphs.append((text, M10DockLayerGlyph()))
                if let dots = part.dots {
                    let d = DotsLayer(); d.anchorPoint = .zero; d.frame = dots.frame
                    d.configure(dots.size, color: part.kind == .dots ? Look.ink : Look.secondary, scale: scale, still: !ambient)
                    l.addSublayer(d); resident.dots.append((d, dots.frame))
                }
                l.opacity = part.current ? 1 : Look.olderLine; row.addSublayer(l)
            }
            content.addSublayer(row); lyricRows[line] = resident; entered.append(line)
        }
        if lyricEntranceTime.isFinite { for line in entered { enterRow(line) } }
        rows = (first...last).compactMap { lyricRows[$0]?.layer }
        glyphTrails = (first...last).flatMap { lyricRows[$0]?.glyphs ?? [] }
        movingDots = (first...last).flatMap { lyricRows[$0]?.dots ?? [] }
        rowTrails = (first...last).compactMap { lyricRows[$0]?.trail }
        mountedLyricCount = rows.count
    }

    /// Each line arrives from 18 pt lower, 3 pt out of focus and transparent, on 0.55 / 0.92, the nearest first and each
    /// line above 30 ms later (NativeBriefRow entrance). Recycled rows share the original entrance clock.
    private func enterRows() {
        lyricEntranceTime = CACurrentMediaTime()
        for line in Array(lyricRows.keys) { enterRow(line) }
        rowTrails = lyricRows.values.compactMap(\.trail)
    }
    private func enterRow(_ line: Int) {
        guard var resident = lyricRows[line] else { return }
        let row = resident.layer, order = Double(min(lyricCount - 1 - line, 8))
        guard CACurrentMediaTime() < lyricEntranceTime + order * 0.03 + 1.5 else { return }
        Self.installBlur(on: row)
        for (key, from) in [("transform.translation.y", 18.0), ("opacity", 0.0), ("filters.peekBlur.inputRadius", 3.0)] {
            if key.hasPrefix("filters"), row.filters?.isEmpty != false { continue }
            let a = Self.spring(key, response: 0.55, damping: 0.92)
            a.fromValue = key == "opacity" ? 0 : from; a.toValue = key == "opacity" ? 1 : 0
            a.beginTime = row.convertTime(lyricEntranceTime, from: nil) + order * 0.03; a.fillMode = .backwards
            row.add(a, forKey: "peek.entrance." + key)
        }
        if motionEnabled, M10DockMotion.enabled, !Motion.reduce {
            resident.trail = M10DockRowTrail.install(on: row, distance: 18, response: 0.55, damping: 0.92,
                                                     profile: exposureProfile, begin: lyricEntranceTime + order * 0.03)
        }
        lyricRows[line] = resident
    }

    /// A blur to animate, without edge normalisation: with it, a layer of text over nothing went black around its glyphs
    /// while the radius was above 0 (recording, 2026-10-29).
    static func installBlur(on layer: CALayer) {
        guard layer.filters?.isEmpty != false else { return }
        if let f = OverlayFilter.make("gaussianBlur", values: ["inputRadius": 0, "name": "peekBlur"]) { layer.filters = [f] }
    }

    private static func spring(_ key: String, response: Double, damping: Double) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: key), omega = 2 * Double.pi / response
        a.mass = 1; a.stiffness = omega * omega; a.damping = 2 * damping * omega; a.duration = a.settlingDuration
        return a
    }

    // Offscreen probes inspect the mounted production assets, including layer ownership and animation.
    var verificationHalo: (halo: CALayer, backdrop: CALayer, mask: CALayer, wash: CALayer) {
        (halo, backdrop, backdropMask, wash)
    }
    var verificationHasOnlySurfaceLayers: Bool {
        root.sublayers?.filter { $0 !== headerPlane.layer } == [halo, lyrics, capsuleShadow]
    }

    /// Compact header title width cannot enlarge the blur union; prepare without mounting native glass.
    static func preparedImageSize(geometry g: AutoLayout.Peek, scale: CGFloat) -> CGSize {
        let header = HeaderIslandGeometry.make(variant: .brief, columnWidth: g.blur.width,
            state: .init(band: HeaderIslandVariant.band(bleedTop: g.blur.minY), scale: scale))
        return g.blur.union(header.planet.offsetBy(dx: g.blur.minX, dy: 0))
            .union(header.capsule.offsetBy(dx: g.blur.minX, dy: 0)).insetBy(dx: -feather, dy: -feather).size
    }
}
