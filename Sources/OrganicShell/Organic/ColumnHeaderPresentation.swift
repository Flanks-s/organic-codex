import AppKit
import QuartzCore
import CoreText

extension ColumnNode {
    func attachIsland(_ island: HeaderIsland) {
        self.island = island
        planet.isHidden = true; capsule.isHidden = true
        snapshots = [:]; applied = nil
    }

    /// The island at rest as `variant`, for a column `width` wide (under full bleed, t = 44).
    func configureIsland(_ variant: HeaderIslandVariant, width: CGFloat) {
        guard let island else { return }
        island.motionProfile = motionProfile; island.motionExposure = motionExposure
        // Native header geometry/text already animate directly. Avoid cacheDisplay-backed glyph duplicates;
        // they add capture work while contributing little visible motion detail (M11-3, 261031).
        island.motionExposure.enabled=false
        islandVariant = variant
        let reduce = Motion.reduce
        var input=HeaderIslandConfiguration.conversation(conversation, variant: variant, columnWidth: width, band: HeaderIslandVariant.band(bleedTop: 52),
                                       reduceMotion: reduce, ambient: ambient, isKeyWindow: island.window?.isKeyWindow ?? true, scale: scale,
                                       identitySymbol: conversation.identitySymbol, identityTint: conversation.identityTint)
        if variant == .full || variant == .brief {
            input.notices=conversation.notices.snapshot(in:conversation)
            // Separators are six points beyond each content edge (ColumnNode.place).
            input.noticeColumnWidth=width+12
        }
        island.configure(input)
    }

    /// Ambient motion held or let go (f202): the header's planet and dots, the brief's "…".
    func setAmbientRunning(_ on: Bool) {
        island?.setPresentationActive(on)
        for layer in briefLayers.values { for case let d as DotsLayer in layer.sublayers ?? [] { d.setRunning(on) } }
    }

    /// At rest, where the column is.
    func placeIsland(_ r: CGRect, shown: Bool) {
        guard let island else { return }
        island.endMotion()
        island.setFrameOrigin(CGPoint(x: r.minX, y: 0))
        island.alphaValue = 1
        island.isHidden = !shown
    }

    /// A transition starts towards `variant`: the island is laid out for it once, and moves there frame by frame.
    func beginIslandMotion(to variant: HeaderIslandVariant, width: CGFloat) {
        guard let island else { return }
        let work=M10ColumnWorkTrace.scope("column.headerCommit",["id":conversation.id]);defer{work.end()}
        let captures=island.motionGlyphMaterial.captureCount
        defer {M10ColumnWorkTrace.count("column.headerCaptures",["id":conversation.id,"count":island.motionGlyphMaterial.captureCount-captures])}
        islandFrom = islandVariant
        island.beginMotion()
        configureIsland(variant, width: width)
        island.isHidden = false
    }

    // MARK: The first send's header rise (f078)

    var isPromoting: Bool { promotion != nil }

    /// New Chat's first send: the full header rises from the seed (88 / 56, the planet's centre at `seedCenterY`) on
    /// 0.38 / 0.86, and "New Chat" gives way to the title 0.12 s in (HeaderIslandPromotion).
    func beginPromotion(seedCenterY: CGFloat, now: Double) {
        guard let island, let plan = island.beginPromotion(seedCenterY: seedCenterY) else { return }
        promotion = (plan, now, false)
    }

    /// Driver A for the rise; false once it is over (the header is at rest again).
    func promotionFrame(at now: Double, x: CGFloat, width: CGFloat, earlierX: CGFloat? = nil) -> Bool {
        guard var p = promotion, let island else { return false }
        let t = now - p.began
        let sample = p.plan.motionSample(elapsed: t)
        let height=ceil(max(sample.geometry.height,island.frame.height)*scale)/scale
        if sample.revealTitle && !p.revealed { island.revealPromotionTitle(); p.revealed = true }
        // revealPromotionTitle configures its endpoint. Reapply the moving canvas afterwards so that frame cannot
        // clip the still-rising plate/name for one display frame.
        island.frame = CGRect(x:x,y:0,width:(width*scale).rounded()/scale,height:height)
        let old = p.plan.motionSample(elapsed: max(0,t-motionProfile.frameInterval*motionExposure.shutter))
        island.placeMotion(sample.geometry, fontScale: sample.fontScale, earlier: old.geometry,
            earlierOrigin: CGPoint(x: earlierX ?? x, y: 0), earlierFontScale: old.fontScale)
        promotion = p
        guard t > 1.2 else { return true }
        promotion = nil
        island.endPromotion()
        return false
    }

    /// Driver A, one frame: the header between its two variants. Between brief and full it follows the form; between
    /// variants of the same fullness (Focused ↔ Split), the column's width.
    func islandFrame(rect r: CGRect, form f: Double, presence p: Double, earlierRect: CGRect? = nil, earlierForm: Double? = nil) {
        // Rising from the seed, the header stays opaque (it takes the seed's place in the same frame; the column fades in).
        guard let island, promotion == nil else { island?.alphaValue = 1; return }
        func pose(_ r:CGRect,_ f:Double)->(HeaderIslandGeometry,CGFloat) {
            func full(_ v: HeaderIslandVariant) -> Bool { v != .brief }
            let k: CGFloat
            if full(islandFrom) != full(islandVariant) { k = CGFloat(full(islandVariant) ? f : 1 - f) }
            else if islandFrom != islandVariant, abs(rect.w.to - rect.w.from) > 0.5 { k = (r.width - rect.w.from) / (rect.w.to - rect.w.from) }
            else { k = 1 }
            let a=island.motionGeometry(variant:islandFrom,columnWidth:r.width), b=island.motionGeometry(variant:islandVariant,columnWidth:r.width)
            let g=HeaderIslandGeometry.mix(a,b,min(1.05,max(-0.05,k)))
            return (g,g.titleFont/max(1,b.titleFont))
        }
        let (g,fontScale)=pose(r,f)
        island.frame = CGRect(x: r.minX, y: 0, width: (r.width * scale).rounded() / scale, height: g.height)
        if let old=earlierRect {
            let (before,k)=pose(old,earlierForm ?? f)
            island.placeMotion(g,fontScale:fontScale,earlier:before,earlierOrigin:CGPoint(x:old.minX,y:0),earlierFontScale:k)
        } else { island.placeMotion(g,fontScale:fontScale) }
        island.alphaValue = CGFloat(min(1, max(0, p)))
    }

    /// Header geometry for a column width and form (full 1, brief 0): planet, capsule.
}
