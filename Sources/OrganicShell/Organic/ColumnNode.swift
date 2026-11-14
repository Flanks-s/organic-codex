import AppKit
import QuartzCore
import CoreText

/// One conversation shown as an Auto column, full bleed (the product default): no card fill, a fading
/// separator, a planet-and-name header, and content laid out once per revision and width as snapshots
/// (spec §7). Geometry follows docs/reference/AUTO-DOCK-REFERENCE-26102804.md §A, §C, §D.
@MainActor final class ColumnNode {

    let conversation: Conversation
    /// The column's native transcript (one per conversation, kept for its selection and scroll). Shown at rest
    /// in full form; while moving, its own captures stand in for it.
    let native: NativeTranscript
    weak var transcriptSessions: NativeTranscriptSessions?
    var nativeLease: NativeTranscriptSessions.Lease?
    var modeSuspended=false
    let sharedTranscript: Bool
    var followBeforeMotion: Bool?
    var atEndBeforeMotion: Bool?
    var restOnSnapshot = false
    var restWithGoal: CGImage?, motionBase: CGImage?
    var fullReflow: ColumnFullReflow?
    var hasFullReflow: Bool { fullReflow != nil }
    var nativeArea = CGRect.zero
    var fullContentTop = Look.contentTop.full
    let identity: NSColor
    // The public carrier retains its original position/bounds contract. Only its material is replicated: the native
    // island/glass lives in another plane and is never put under this replicator.
    let card = CALayer()
    let presenceMaterial = CALayer(), cardBody = CALayer(), inkMaterial = CALayer()
    // The native/masked tree never enters an exposure replicator. Only the nonempty baked ink does.
    let presenceTrail = CAReplicatorLayer()
    let presenceInk = CALayer(), presenceFullInk = CALayer(), presenceBriefInk = CALayer()
    let zoomSurface = M10ColumnSolidZoom()
    var zoomStyle=M10ColumnZoom.selected
    weak var revealMaterial: ColumnRevealMaterial?
    var revealMatteHits=0, revealMatteFallbacks=0, revealMattePrepared=0
    var revealStageFlushes=0, revealStageFlushMs=0.0
    var gaussianCaptureNeeded=false
    var gaussianPairs:[ObjectIdentifier:M10ColumnMatte.Pair]=[:]
    var gaussianPairOrder:[ObjectIdentifier]=[]
    var gaussianCapturePlate:CGImage?
    var gaussianPlateCaptures=0
    var gaussianSurface:M10ColumnGaussianSurface?
    var gaussianMatteMs=0.0,gaussianMissingMaterials=0
    var bakedPresence: [(trail: CAReplicatorLayer, ink: CALayer)] = []
    var exposureBakeMs = 0.0
    var bakedPeakCopies = 1
    /// Preserve the receipt's model-opacity meaning now that the public carrier is an unscaled replicator.
    var modelOpacity:Float {card.opacity*presenceMaterial.opacity}
    let cardSweep = CAGradientLayer(), separatorSweep = CAGradientLayer()
    let separatorSweepMask = CAGradientLayer()
    var motionProfile = DisplayProfile(name: "unmounted column", frameInterval: 1/60, mmPerPoint: 0.27, persistenceFrames: 0)
    var motionExposure = ExposureSettings()
    var presenceScaleMap:(base:CGFloat,slope:CGFloat)=(0.25,0.75)
    var presenceScaleEntering:Bool?
    var m10Frames: [String: [M10ColumnFrame]] = [:]
    var m10Times: [Double] = []
    let separator = CAGradientLayer()
    let planet = CALayer()
    let capsule = CALayer(), capsuleTitle = CALayer()
    let transcriptClip = CALayer(), transcript = CALayer()
    /// The goal's words in the transcript, shown only at rest in full form; flights stand in while moving.
    let goalText = CALayer()
    /// The brief form: a clip under the header (its top fades in as the product's does) holding one layer per part.
    let brief = CALayer()
    let briefContent = CALayer()
    let briefFade = CAGradientLayer()
    var briefLayers: [String: CALayer] = [:]
    /// Parts a flight stands in for while moving (hidden then), and every part's resting opacity.
    var flownParts: Set<String> = [], restOpacity: [String: Float] = [:]
    /// Ambient motion (the "…" dots); tests hold it still, so frames depend only on the transition.
    var ambient = true

    var rect: RectSpring
    var form: Spring
    /// On screen (1) or going (0). Entering, a column grows from 0.92 and fades in; leaving, it shrinks to 0.25 and
    /// fades out; both scale about the bottom of its content (columnPresence: NativeColumnTransition.swift).
    var presence = Spring.rest(1)
    var entering = true
    var pieces: [FlightPiece] = []
    var lyricSize: CGFloat = 21
    /// While its flights are landing, an entering column takes new content but keeps its scroll, so the goal
    /// stays where the flights are going; it scrolls to the end once still.
    var needsReanchor = false
    var scale: CGFloat
    private(set) var sceneHeight: CGFloat, logicalBottom: CGFloat
    var titleSize = CGSize.zero

    init(_ conversation: Conversation, store: ConversationStore, identity: NSColor, rect: CGRect, full: Bool, scale: CGFloat, logicalBottom: CGFloat,
         transcriptSessions: NativeTranscriptSessions? = nil) {
        self.conversation = conversation; self.identity = identity
        self.transcriptSessions = transcriptSessions; sharedTranscript = transcriptSessions != nil
        native = transcriptSessions?.transcript(for: conversation, store: store) ?? NativeTranscript(conversation: conversation, store: store)
        if transcriptSessions == nil { native.decisionCardsInline = false; native.decisionCardsAtBottom = !conversation.approvals.isEmpty || conversation.userInput != nil }
        if !sharedTranscript { native.isHidden = true; native.wantsLayer = true }
        self.scale = scale; sceneHeight = rect.height; self.logicalBottom = logicalBottom
        self.rect = .rest(rect)
        form = .rest(full ? 1 : 0)
        for l in [card, separator, planet, capsule, capsuleTitle, transcriptClip, transcript, goalText, brief, briefContent] {
            l.anchorPoint = .zero
            l.contentsScale = scale
            l.contentsGravity = .resize
        }
        card.masksToBounds = false
        for l in [presenceMaterial, cardBody, cardSweep, separatorSweep, separatorSweepMask] {
            l.anchorPoint = .zero; l.contentsScale = scale
        }
        cardBody.masksToBounds = true
        for l in [inkMaterial, presenceTrail, presenceInk] { l.anchorPoint = .zero; l.contentsScale = scale }
        presenceTrail.name = "column.baked-ink"; presenceInk.name = "column.texture"
        // These are detached animation templates; only tightly bounded texture tiles enter the scene.
        presenceTrail.opacity = 0
        cardBody.addSublayer(inkMaterial)
        card.addSublayer(presenceMaterial)
        card.addSublayer(zoomSurface.layer)
        presenceMaterial.addSublayer(cardSweep); presenceMaterial.addSublayer(cardBody)
        cardSweep.startPoint = CGPoint(x: 0, y: 0.5); cardSweep.endPoint = CGPoint(x: 1, y: 0.5)
        cardSweep.opacity = 0; cardSweep.cornerRadius = 18; cardSweep.cornerCurve = .continuous; cardSweep.masksToBounds = true
        separatorSweep.startPoint = .zero; separatorSweep.endPoint = CGPoint(x: 0, y: 1)
        separatorSweepMask.startPoint = CGPoint(x: 0, y: 0.5); separatorSweepMask.endPoint = CGPoint(x: 1, y: 0.5)
        separatorSweep.mask = separatorSweepMask; separatorSweep.opacity = 0
        separator.addSublayer(separatorSweep)
        separator.colors = [Look.separator.withAlphaComponent(0).cgColor, Look.separator.cgColor, Look.separator.cgColor, Look.separator.withAlphaComponent(0).cgColor]
        separator.locations = [0, 0.12, 0.8, 1]
        planet.backgroundColor = identity.cgColor
        planet.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        planet.borderWidth = 1
        planet.anchorPoint = CGPoint(x: 0.5, y: 0)
        capsule.backgroundColor = Look.capsule.cgColor
        capsule.anchorPoint = CGPoint(x: 0.5, y: 0)
        capsuleTitle.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        transcriptClip.masksToBounds = true
        transcriptClip.mask = Self.fade()
        inkMaterial.addSublayer(transcriptClip)
        if !sharedTranscript { native.layer?.mask = Self.fade() }
        transcriptClip.addSublayer(transcript)
        transcriptClip.addSublayer(goalText)
        inkMaterial.addSublayer(brief)
        brief.masksToBounds = true
        briefFade.anchorPoint = .zero
        briefFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        brief.mask = briefFade
        brief.addSublayer(briefContent)
        cardBody.addSublayer(planet)
        cardBody.addSublayer(capsule)
        capsule.addSublayer(capsuleTitle)
        place(rect, form: full ? 1 : 0)
    }

    /// The transcript's top and bottom fade; the native view and its capture wear the same one.
    static func fade() -> CAGradientLayer {
        let fade = CAGradientLayer()
        fade.anchorPoint = .zero
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        return fade
    }

    func shapeFade(_ layer: CALayer?, _ size: CGSize) {
        guard let fade = layer as? CAGradientLayer else { return }
        fade.frame = CGRect(origin: .zero, size: size)
        fade.locations = [0, NSNumber(value: Double(16 / size.height)), NSNumber(value: Double(1 - 28 / size.height)), 1]
    }

    var isFull: Bool { form.to > 0.5 }
    var target: CGRect { rect.target }

    // MARK: Card (Settings ▸ Organic ▸ Full-bleed Organic canvas off)

    /// Off, each column is a card between the title bar and the dock (its logical rect's top and bottom): radius 18, a
    /// faint fill (0.025 full, 0.045 brief), its content clipped to it, no separator (OrganicColumn card, bled(on:)).
    /// The content keeps its place: only the card's shape and fill change.
    var cardBand: ClosedRange<CGFloat>? {
        didSet { guard cardBand != oldValue else { return }; shapeCard(width: card.bounds.width, form: form.to) }
    }
    let cardMask = CALayer(), cardFill = CALayer()

    func cardFrame(width w: CGFloat) -> CGRect {
        guard let b = cardBand else { return .zero }
        return CGRect(x: 0, y: b.lowerBound, width: w, height: b.upperBound - b.lowerBound)
    }
    static func cardFillColor(form f: Double) -> CGColor {
        NSColor(white: 1, alpha: 0.045 - 0.02 * CGFloat(min(1, max(0, f)))).cgColor
    }
    private func shapeCard(width w: CGFloat, form f: Double) {
        guard cardBand != nil else {
            if cardBody.mask === cardMask { cardBody.mask = nil }
            cardFill.removeFromSuperlayer()
            separator.isHidden = false
            return
        }
        for l in [cardMask, cardFill] { l.anchorPoint = .zero; l.cornerRadius = 18; l.cornerCurve = .continuous; l.frame = cardFrame(width: w) }
        cardMask.backgroundColor = NSColor.black.cgColor
        cardFill.backgroundColor = Self.cardFillColor(form: f)
        if cardBody.mask !== cardMask { cardBody.mask = cardMask }
        if cardFill.superlayer !== cardBody { cardBody.insertSublayer(cardFill, at: 0) }
        separator.isHidden = true
    }

    // MARK: Header island (Sol's HeaderIsland, f069–f080)

    /// Native, over the column, when there is a window; tests keep the drawn header. With it, the state goes in its
    /// nameplate and no longer under the brief (DECISIONS #2).
    var island: HeaderIsland?
    var browserAttachment: BrowserColumnAttachment?
    var islandVariant = HeaderIslandVariant.brief
    var islandFrom = HeaderIslandVariant.brief

    var promotion: (plan: HeaderIslandPromotion, began: Double, revealed: Bool)?
    func header(width w: CGFloat, form f: Double) -> (planet: CGRect, capsule: CGRect, titleScale: CGFloat) {
        let k = CGFloat(min(1, max(0, f)))
        func mix(_ v: (full: CGFloat, brief: CGFloat)) -> CGFloat { v.brief + (v.full - v.brief) * k }
        let d = mix(Look.planet), ch = mix(Look.capsuleHeight), ts = (12 + k) / 13
        let cw = min(w - 24, titleSize.width * ts + 24)
        return (CGRect(x: w / 2, y: mix(Look.avatarTop), width: d, height: d),
                CGRect(x: w / 2, y: mix(Look.capsuleTop), width: cw, height: ch), ts)
    }

    func place(_ r: CGRect, form f: Double) {
        positionNative(CGPoint(x: r.minX + nativeArea.minX, y: r.minY + nativeArea.minY))
        card.position = r.origin
        card.bounds = CGRect(origin: .zero, size: r.size)
        presenceMaterial.bounds = card.bounds; presenceMaterial.position = .zero; cardBody.frame = card.bounds; inkMaterial.frame = card.bounds
        if cardBand != nil { shapeCard(width: r.width, form: f) }
        separator.frame = CGRect(x: r.maxX + 6 - 0.5 / scale, y: 0, width: 1 / scale, height: r.height)
        apply(header(width: r.width, form: f))
    }

    func apply(_ h: (planet: CGRect, capsule: CGRect, titleScale: CGFloat)) {
        planet.position = h.planet.origin
        planet.bounds = CGRect(origin: .zero, size: h.planet.size)
        planet.cornerRadius = h.planet.width / 2
        capsule.position = h.capsule.origin
        capsule.bounds = CGRect(origin: .zero, size: h.capsule.size)
        capsule.cornerRadius = h.capsule.height / 2
        capsuleTitle.position = CGPoint(x: h.capsule.width / 2, y: h.capsule.height / 2)
        capsuleTitle.transform = CATransform3DMakeScale(h.titleScale, h.titleScale, 1)
    }

    var modeBriefs:[ModeBriefKey:(log:SummaryLog,layout:BriefLayout)]=[:]
    var snapshots: [Snapshot.Key: Snapshot] = [:]
    var applied: Snapshot.Key?
    var displayWidths: (full:CGFloat, brief:CGFloat)?
    var idleRowConfigurationDirty=false
    /// The window moved to a screen of another density. Every capture and cut is in pixels of the old one.
    func backingChanged(_ next: CGFloat) {
        scale = next
        for l in [card, separator, planet, capsule, capsuleTitle, transcriptClip, transcript, goalText, brief, briefContent,
                  presenceMaterial, cardBody, cardSweep, separatorSweep, separatorSweepMask, inkMaterial, presenceTrail, presenceInk] {
            l.contentsScale = next
        }
        invalidateCaptures()
    }

    /// The window changed size: a new height and content bottom, and every snapshot made for the old ones is stale.
    func reshape(sceneHeight h: CGFloat, logicalBottom b: CGFloat) {
        guard h != sceneHeight || b != logicalBottom else { return }
        sceneHeight = h; logicalBottom = b
        bakedInkCache = [:]
        snapshots = [:]; applied = nil
    }
    /// The picture of the motion stays at the offset it was taken at. What arrived on the way puts the real transcript a row or
    /// two further on when it takes over, and that was one hard jump of 20-40 pt at settle (board 10-31). It slides there instead.
    var motionOffset: CGFloat?
    static var briefMotionSerial = 0
    static let dotsLeaving = "leaving"


    /// Past this a row's layout takes several frames, too long for one idle slice. The synchronous path then does it at the press.
    static let idleRowTextLimit=64*1024

    var bakedInkCache: [InkKey: [M10ColumnTexture.Bitmap]] = [:]
    var bakedInkFrames: [[[String: Any]]] = []
}
