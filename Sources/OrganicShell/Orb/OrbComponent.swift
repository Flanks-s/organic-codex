import AppKit
import QuartzCore
import SwiftUI

/// Decoration only. DockNode owns the glass's geometry, container, hit testing, and accessibility.
/// Mount backView BELOW the shared container; frontView ABOVE it, both at the scene origin.
/// Set their canvas size at installation/viewport resize. Their NSView frames stay fixed during hover.
@MainActor final class OrbComponent {
    let id: String
    let glassView: NSGlassEffectView
    let backView: NSView
    let frontView: NSView
    private let bodyView: OrbDecorationView
    private let counters = OrbMetrics()
    private let backPlacement = CALayer(), frontPlacement = CALayer(), bodyPlacement = CALayer()
    private let backMotion = CALayer(), frontMotion = CALayer(), bodyMotion = CALayer()
    private let glyphGroup = CALayer(), glyph = CAShapeLayer(), initials = CATextLayer(), seedGlyph = CALayer()
    private let texturedBody = BodyPresentationLeaf()
    private let phaseBody = OrbPhaseContent()
    private var bodyVeil: Float = 0
    private var phaseWindowAttached=false
    private let meLabel = CATextLayer()
    private var meLabelMix = 0.0
    private let glyphTrail=ChordTrail()
    private let completionPose=CALayer()
    private var glyphGaussian:ContentGaussianTransition?, badgeGaussian:ContentGaussianTransition?
    private let gaussianClock=SceneClock()
    private var gaussianNeedsModelSampling=false
    private let hostGlyph=OrbHostInk(),hostBadge=OrbHostInk(),completionInk=OrbHostInk()
    private(set) var pointerInkPrepared=false
    private let badgePlacement = CALayer(), badge = CAShapeLayer(), badgeText = CATextLayer()
    private let glow = CAShapeLayer()
    private let liquid: OrbLiquid
    private let satellites: OrbSatellites
    private var configuration: OrbConfiguration?
    private var frame: CGRect?
    private var contentFrame: CGRect?
    private var renderedBadge: OrbBadge?
    private var drawingKey = "", badgeKey = ""
    private var badgeDiameter: CGFloat = 1
    private var drawingSize: CGFloat = 1
    private var canvasSize: CGSize?
    private var active = true, disposed = false
    private var glassHopPaused = false
    private var ownsGlassFeedback=true
    private final class HeldExposure {
        weak var layer:CALayer?
        let key:String,animation:CAAnimation
        init(layer:CALayer,key:String,animation:CAAnimation) {self.layer=layer;self.key=key;self.animation=animation}
    }
    private var heldExposure:[HeldExposure]=[]
    /// Set before a transition/semantic configure. Turning off also removes an in-flight treatment immediately.
    /// M10_DRAFT_EXPOSURE=0: off, for live on/off comparisons.
    var exposureEnabled=ProcessInfo.processInfo.environment["M10_DRAFT_EXPOSURE"] != "0" { didSet { if !exposureEnabled { discardExposure() } } }
    /// A scene may supply its measured display-link profile. Otherwise use this view's actual screen at commit.
    var motionProfile:DisplayProfile?
    private var displayObservation:UUID?
    private var glassHopKey: String { "organic.orb.alert.\(id)" }
    var metrics: OrbDrawingMetrics { counters.value }
    var quotaSummary: String? {
        if case .me(_, let q) = configuration?.content { return q.summary }
        return nil
    }

    init(id: String, glassView: NSGlassEffectView? = nil) {
        self.id = id
        self.glassView = glassView ?? NSGlassEffectView(frame: .zero)
        let back = OrbDecorationView(metrics: counters), front = OrbDecorationView(metrics: counters)
        bodyView = OrbDecorationView(metrics: counters)
        backView = back; frontView = front
        liquid = OrbLiquid(metrics: counters); satellites = OrbSatellites(metrics: counters)
        satellites.onExposureInvalidated = { [weak self] layer in self?.heldExposure.removeAll { $0.layer === layer } }
        self.glassView.wantsLayer = true
        for view in [back, front] {
            view.visibilityChanged = { [weak self] in self?.updateSatelliteVisibility(at: CACurrentMediaTime()); self?.updateBodyVisibility() }
        }
        bodyView.visibilityChanged = { [weak self] in self?.updateBodyVisibility() }
        if self.glassView.contentView == nil { self.glassView.contentView = OrbDecorationView(metrics: counters) }
        self.glassView.contentView?.addSubview(bodyView)
        back.layer?.addSublayer(backPlacement); front.layer?.addSublayer(frontPlacement)
        bodyView.layer?.addSublayer(bodyPlacement)
        backPlacement.addSublayer(backMotion); frontPlacement.addSublayer(frontMotion)
        bodyPlacement.addSublayer(bodyMotion)
        backMotion.addSublayer(glow); backMotion.addSublayer(satellites.back)
        frontMotion.addSublayer(satellites.front); frontMotion.addSublayer(badgePlacement)
        badgePlacement.addSublayer(badge); badge.addSublayer(badgeText)
        frontMotion.insertSublayer(hostGlyph.carrier,below:badgePlacement)
        badge.addSublayer(hostBadge.carrier)
        bodyMotion.addSublayer(liquid.layer);bodyMotion.addSublayer(glyphTrail.layer);bodyMotion.addSublayer(glyphGroup)
        glyphGroup.addSublayer(glyph); glyphGroup.addSublayer(initials); glyphGroup.addSublayer(seedGlyph)
        glyphGroup.addSublayer(texturedBody.layer)
        phaseBody.attach(to:glyphGroup,above:texturedBody.layer)
        texturedBody.onPictureChange = { [weak self] in self?.prepareBodyInk() }
        phaseBody.picture.onPictureChange = { [weak self] _ in self?.prepareBodyInk() }
        glyphGroup.addSublayer(meLabel); meLabel.isHidden = true; meLabel.alignmentMode = .center
        glyph.fillColor = nil; glyph.lineCap = .round; glyph.lineJoin = .round
        glyph.shadowOpacity = 1; glyph.shadowOffset = .zero
        initials.alignmentMode = .center; initials.truncationMode = .end
        badgeText.alignmentMode = .center
        glow.fillColor = nil; glow.shadowOpacity = 1; glow.shadowOffset = .zero; glow.opacity = 0
        badge.opacity = 0
        displayObservation=OrbDisplayEnvironment.shared.observe { [weak self] in
            guard let self,let configuration=self.configuration else { return }; self.apply(configuration,appearanceChanged:true)
        }
    }
    isolated deinit { if let displayObservation { OrbDisplayEnvironment.shared.removeObserver(displayObservation) } }

    /// Call only on semantic changes (including backing scale and environment), never during hover sampling.
    func configure(_ next: OrbConfiguration) {
        apply(next,appearanceChanged:false)
    }
    /// An LL input channel; both labels stay inside the same real glass, with the same placement.
    func setMeLabelMix(_ amount: Double) {
        guard case .me = configuration?.content else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        meLabelMix = min(1, max(0, amount))
        initials.opacity = Float(1 - meLabelMix); meLabel.opacity = Float(meLabelMix)
    }
    var meBadgeRect: CGRect? {
        guard configuration?.meBadgeAtCorner == true, configuration?.badge != nil, let path = badge.path else { return nil }
        return frontView.layer?.convert(path.boundingBoxOfPath, from: badge)
    }
    var meSemanticBadge: OrbBadge? { if case .me = configuration?.content { return configuration?.badge }; return nil }
    var meSemanticUsage: Double? { if case .me = configuration?.content { return configuration?.liquidLevel }; return nil }
    var meBadgeIsAboveBody: Bool { configuration?.meBadgeAtCorner == true && badgePlacement.superlayer === frontPlacement }
    var meBadgeEffectiveOpacity: Float {
        var opacity: Float = 1, current: CALayer? = badge
        while let layer = current { if layer.isHidden { return 0 }; opacity *= layer.opacity; current = layer.superlayer }
        return opacity
    }
    func hasSameDragConfiguration(as other:OrbComponent)->Bool {configuration == other.configuration}
    /// Prepare at pointer DOWN, before the hold/drag starts. New component-owned drawing only; never copy
    /// an AppKit backing tree, a glass view, or a native snapshot into an exposure replicator.
    func prepareDragDecoration(glassView sharedGlass:NSGlassEffectView?=nil,compactSatellites:Bool=false,
                               satellitesRetired:Bool?=nil) -> OrbComponent? {
        guard !disposed,var configuration else { return nil }
        if compactSatellites {
            configuration.satelliteMode = .orbit;configuration.satelliteVisibleIDs=nil;configuration.satelliteDiameter=nil
            if let satellitesRetired {configuration.satellitesRetired=satellitesRetired}
        }
        let result=OrbComponent(id:id+".header-drag",glassView:sharedGlass)
        result.ownsGlassFeedback=false // The queue's real-frame driver owns this material's position.
        result.motionProfile=motionProfile; result.exposureEnabled=exposureEnabled
        result.configure(configuration)
        if sharedGlass == nil { result.glassView.style=glassView.style; result.glassView.tintColor=glassView.tintColor }
        result.synchronizeDragAnimationPhase(from:self)
        return result
    }
    /// Align only owned semantic animation clocks. Both independently authored trees already exist. This does
    /// not clone layers or native backing, and is called at pickup/handback, never in a motion-frame loop.
    func synchronizeDragAnimationPhase(from source:OrbComponent) {
        guard configuration == source.configuration else { return }
        func align(_ a:CALayer,_ b:CALayer) {
            b.speed=a.speed; b.beginTime=a.beginTime; b.timeOffset=a.timeOffset
            for key in b.animationKeys() ?? [] { b.removeAnimation(forKey:key) }
            for (key, animation) in source.satellites.animationEntries(on: a) where !key.hasPrefix("m10F.") {
                // A carry recomputes its host exposure from its actual trajectory. Do not import the
                // source row's exposure replicators into an independently configured decoration.
                b.add(animation,forKey:key)
            }
            let aa=a.sublayers ?? [],bb=b.sublayers ?? []
            // Semantic changes during the carry can add/remove satellites. Never pair unrelated nodes.
            if aa.count == bb.count { for (x,y) in zip(aa,bb) { align(x,y) } }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (a,b) in zip([source.backPlacement,source.bodyPlacement,source.frontPlacement],
                         [backPlacement,bodyPlacement,frontPlacement]) { align(a,b) }
        liquid.synchronizeActivity(from:source.liquid)
        satellites.synchronizeVisibility(from: source.satellites, at: CACurrentMediaTime())
        CATransaction.commit()
    }
    private func apply(_ next:OrbConfiguration,appearanceChanged:Bool) {
        guard !disposed, appearanceChanged || configuration != next else { return }
        if !appearanceChanged,var previous=configuration {
            previous.activitySerial=next.activitySerial
            if previous == next {
                configuration=next;counters.value.configurations+=1
                CATransaction.begin();CATransaction.setDisableActions(true)
                liquid.settle(activitySerial:next.activitySerial,
                              amplitude:next.content != .seed && next.identityLiquid ? OrbTuning.wobble*drawingSize/40:0,
                              animate:active && next.ambient && !next.reduceMotion)
                CATransaction.commit();return
            }
        }
        if next.reduceMotion { discardExposure() }
        let old = configuration, now = CACurrentMediaTime()
        configuration = next; counters.value.configurations += 1
        drawingSize = next.drawingSize.isFinite ? max(1, next.drawingSize) : 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if old?.meBadgeAtCorner == true && !next.meBadgeAtCorner { frontMotion.transform = CATransform3DIdentity }
        if canvasSize == nil { setCanvasSize(CGSize(width: drawingSize, height: drawingSize)) }
        let high=OrbDisplayEnvironment.shared.options.increaseContrast
        let appearance=NSAppearance(named:next.appearance == .dark ? (high ? .accessibilityHighContrastDarkAqua:.darkAqua):(high ? .accessibilityHighContrastAqua:.aqua))!
        for view in [backView,frontView,bodyView,glassView] { view.appearance=appearance }
        appearance.performAsCurrentDrawingAppearance {
            rebuildDrawing(next)
            if let value = next.badge { renderedBadge = value }
            rebuildBadge(next)
            let tint: NSColor
            let colors: [CGColor]
            switch next.content {
            case .identity(let identity):
                tint = identity.bodyTintColor
                let deep = (next.liquidLevel ?? 0) >= OrbTuning.deepen
                colors = [tint.withAlphaComponent(deep ? 0.50 : 0.24).cgColor,
                          tint.withAlphaComponent(deep ? 0.78 : 0.42).cgColor]
            case .seed:
                tint = .secondaryLabelColor
                colors = [NSColor(srgbRed: 0xcf/255, green: 0xe9/255, blue: 0xdc/255, alpha: 0.32).cgColor,
                          NSColor(srgbRed: 0x5f/255, green: 0xae/255, blue: 0x94/255, alpha: 0.5).cgColor]
            case .me:
                tint = .white
                colors = [NSColor(srgbRed: 0x78/255, green: 0xd8/255, blue: 0xa6/255, alpha: 0.35).cgColor,
                          NSColor(srgbRed: 0x2b/255, green: 0x8a/255, blue: 0x7a/255, alpha: 0.55).cgColor]
            }
            glyph.strokeColor = tint.cgColor
            glyph.shadowColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
            glyph.shadowOpacity=OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 0:1
            initials.foregroundColor = NSColor.labelColor.cgColor
            glow.strokeColor = NSColor.systemRed.cgColor; glow.shadowColor = NSColor.systemRed.cgColor
            glow.isHidden=OrbDisplayEnvironment.shared.options.opaqueSurfaces
            let opaque=OrbDisplayEnvironment.shared.options.opaqueSurfaces
            let liquidColors:[CGColor]
            if opaque,let last=colors.last,let color=NSColor(cgColor:last) {
                let solid=OrbDisplayEnvironment.surface(color,opacity:last.alpha).cgColor; liquidColors=[solid,solid]
            } else { liquidColors=colors }
            liquid.configure(size: drawingSize, level: next.liquidLevel, colors: liquidColors,
                             wobble: next.content != .seed && next.identityLiquid && !next.reduceMotion ? OrbTuning.wobble*drawingSize/40 : 0,
                             compactions: next.content == .seed ? 0 : next.compactions, animate: next.content != .seed && active && next.ambient && !next.reduceMotion,
                             activitySerial: next.activitySerial, eventVisible: active && next.ambient)
            if opaque { liquid.settleColors() }
            let shown=contentFrame?.size ?? frame?.size ?? CGSize(width:drawingSize,height:drawingSize)
            let satelliteScale=max(0.001,max(shown.width,shown.height)/drawingSize)
            var satelliteProfile=motionProfile ?? M10FExposure.profile(for:glassView)
            satelliteProfile.mmPerPoint *= Double(satelliteScale)
            satellites.configure(next.satellites, size: drawingSize, scale: max(1, next.backingScale),
                                 retired: next.satellitesRetired, mode: next.satelliteMode,
                                 reduceMotion: next.reduceMotion, now: now, diameter: next.satelliteDiameter, visibleIDs: next.satelliteVisibleIDs,
                                 shape:next.orbitShape,accent:next.satelliteAccent,followStagger:next.satelliteFollowStagger,
                                 motionProfile:exposureEnabled ? satelliteProfile:nil,motionScale:satelliteScale)
        }
        // Semantic preparation only. Host callbacks never allocate images or copy native layer trees.
        if case .identity = next.content {} else { hostGlyph.prepare(glyphGroup,scale:max(1,next.backingScale)*2,topDown:pointerInkPrepared) }
        hostBadge.prepare(badgeText,scale:max(1,next.backingScale)*2,topDown:pointerInkPrepared)
        completionInk.reusePreparedInk(from:hostGlyph)
        if let frame { place(frame, contentFrame: contentFrame) }
        else { setFrame(CGRect(x: 0, y: 0, width: drawingSize, height: drawingSize)) }
        if old?.badge != next.badge { animateBadge(from: old?.badge, to: next.badge, reduceMotion: next.reduceMotion) }
        if let old, next.completions > old.completions, !next.reduceMotion { completionHop() }
        let alert = next.badge?.tone == .red && next.redUnseen && next.isKeyWindow && !next.reduceMotion
        let wasAlert = old.map { $0.badge?.tone == .red && $0.redUnseen && $0.isKeyWindow && !$0.reduceMotion } ?? false
        if alert && (!wasAlert || old?.redEvents != next.redEvents) { alertHop(at: now) }
        else if !alert { removeAlert() }
        // Acknowledged red status is static. New errors retain their finite alert hop above.
        glow.removeAnimation(forKey:"breathe")
        glow.opacity = next.badge?.tone == .red && !next.redUnseen ? 0.4 : 0
        if next.reduceMotion {
            bodyMotion.removeAnimation(forKey: "headerRename")
            glyphGroup.removeAnimation(forKey: "completion")
            glyphGroup.removeAnimation(forKey:"m101.completion.native")
            glyphTrail.layer.removeAllAnimations();glyphTrail.layer.opacity=0;glyphTrail.reset()
            badge.removeAllAnimations()
        }
        updatePause(at: now)
        updateBodyPresentation()
        CATransaction.commit()
    }

    /// Driver A entry. glassView.frame/cornerRadius remain the Dock's responsibility.
    /// frame is in the common back/front scene space. contentFrame is optional glass-local orb geometry.
    /// Fixed O(1): six position/transform writes + badge placement/stroke. No NSView frame, layout, paths or fonts.
    func setFrame(_ frame: CGRect, contentFrame: CGRect? = nil) {
        guard !disposed else { return }
        counters.value.geometryCalls += 1
        self.frame = frame; self.contentFrame = contentFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place(frame, contentFrame: contentFrame)
        CATransaction.commit()
    }

    /// Host translation/zoom. Flattened ink only: no live shadow/filter/mask/native backing in replicas.
    /// Liquid/plate keep setFrame's shape; glyphs use the logical circle and badge digits their capped size.
    func exposeGlyphs(now:CGRect,earlier:CGRect,profile:DisplayProfile,enabled:Bool=true) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        let local=contentFrame ?? CGRect(origin:.zero,size:frame?.size ?? now.size)
        let painted=local.offsetBy(dx:frame?.minX ?? now.minX,dy:frame?.minY ?? now.minY)
        // Keep the capped badge plate at the logical planet's pole, rather than stretching its position with
        // the liquid's trailing edge. Its shape and digits remain round at all velocities (ON and A/B OFF).
        if painted != now, configuration?.meBadgeAtCorner != true {
        let diameter=min(now.width*0.4,18),badgeScale=diameter/max(0.001,badgeDiameter)
        badgePlacement.position=CGPoint(x:(now.minX-painted.minX+now.width*0.86)*drawingSize/max(0.001,painted.width),
                                        y:(now.minY-painted.minY+now.height*0.14)*drawingSize/max(0.001,painted.height))
        badgePlacement.transform=CATransform3DMakeScale(badgeScale*drawingSize/max(0.001,painted.width),badgeScale*drawingSize/max(0.001,painted.height),1)
        badge.lineWidth=max(1,diameter*0.1)/max(0.001,badgeScale)
        }
        let on=enabled && exposureEnabled && configuration?.reduceMotion != true && glyphGaussian?.plan == nil
        hostGlyph.update(now:now,earlier:earlier,parent:painted,parentSize:CGSize(width:drawingSize,height:drawingSize),profile:profile,enabled:on)
        glyphGroup.isHidden=hostGlyph.sample.count>1
        hostGlyph.carrier.opacity=bodyMotion.opacity
        if configuration?.meBadgeAtCorner == true { placeMeBadge(logical: now, painted: painted); badgeText.isHidden = false; return }
        func badgePose(_ r:CGRect)->CGRect {
            let scale=min(r.width*0.4,18)/max(0.001,badgeDiameter)
            return CGRect(x:r.minX+r.width*0.86+(badgeText.frame.minX-badge.bounds.width/2)*scale,
                          y:r.minY+r.height*0.14+(badgeText.frame.minY-badge.bounds.height/2)*scale,
                          width:badgeText.bounds.width*scale,height:badgeText.bounds.height*scale)
        }
        let current=badgePose(now),old=badgePose(earlier)
        // The parent badge already carries presence scale/opacity. Sharing it keeps the semantic animation exact.
        let scale=min(now.width*0.4,18)/max(0.001,badgeDiameter)
        let parent=CGRect(x:now.minX+now.width*0.86-badge.bounds.width*scale/2,
                          y:now.minY+now.height*0.14-badge.bounds.height*scale/2,
                          width:badge.bounds.width*scale,height:badge.bounds.height*scale)
        hostBadge.update(now:current,earlier:old,parent:parent,parentSize:badge.bounds.size,profile:profile,enabled:on)
        badgeText.isHidden=hostBadge.sample.count>1
    }

    /// Prepare once at pickup, never in the display-frame callback. Dock's three entrances share this ink.
    /// Other hosts retain their existing textures, including island transitions and mode flights.
    func preparePointerInk() {
        guard !pointerInkPrepared,let configuration else {return}
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        pointerInkPrepared=true
        let scale=max(1,configuration.backingScale)*2
        if case .identity = configuration.content { prepareBodyInk() }
        else { hostGlyph.prepare(glyphGroup,scale:scale,topDown:true) }
        hostBadge.prepare(badgeText,scale:scale,topDown:true)
    }

    /// Semantic entrance/replacement. Native ink only; glass, liquid and solid badge remain unfiltered siblings.
    func setGlyphGaussianVisible(_ visible:Bool,at time:Double,initiallyVisible:Bool?=nil,spotlight:Bool=false,fadesContent:Bool=true) {
        guard exposureEnabled,configuration?.reduceMotion != true else {resetGlyphGaussian();return}
        resetHostExposure(); glyphTrail.reset()
        glyphGroup.removeAnimation(forKey:"m101.completion.native")
        glyphTrail.layer.removeAnimation(forKey:"m101.completion.ink");glyphTrail.layer.opacity=0
        if glyphGaussian == nil {
            var configuration:ContentGaussianTransition.Configuration=spotlight ? .spotlight:.system
            configuration.fadesContent=fadesContent
            glyphGaussian=ContentGaussianTransition(content:glyphGroup,clock:gaussianClock,initiallyVisible:initiallyVisible ?? !visible,configuration:configuration)
            configuration.hiddenScale=1
            badgeGaussian=ContentGaussianTransition(content:badgeText,clock:gaussianClock,initiallyVisible:initiallyVisible ?? !visible,configuration:configuration)
        }
        glyphGaussian?.configuration.fadesContent=fadesContent;badgeGaussian?.configuration.fadesContent=fadesContent
        glyphGaussian?.setVisible(visible,at:time);badgeGaussian?.setVisible(visible,at:time)
        gaussianNeedsModelSampling = !active || configuration?.ambient != true
        if gaussianNeedsModelSampling {glyphGaussian?.sampleModel(at:time);badgeGaussian?.sampleModel(at:time)}
    }
    func settleGlyphGaussian(at time:Double) {
        if gaussianNeedsModelSampling {glyphGaussian?.sampleModel(at:time);badgeGaussian?.sampleModel(at:time)}
        glyphGaussian?.settle(at:time);badgeGaussian?.settle(at:time)
    }
    func resetGlyphGaussian() {
        glyphGaussian?.setVisible(true,animated:false);badgeGaussian?.setVisible(true,animated:false)
        glyphGaussian=nil;badgeGaussian=nil;gaussianNeedsModelSampling=false
    }

    /// Installation/viewport resize only, in the same coordinate space as the glass container.
    /// Give both planes a real canvas so AppKit does not cull an empty NSView before rendering its sublayers.
    func setCanvasSize(_ size: CGSize) {
        guard !disposed, canvasSize != size else { return }
        canvasSize = size
        let rect = CGRect(origin: .zero, size: size)
        backView.frame = rect; frontView.frame = rect
    }

    /// Hide/reveal retained orb decoration during bar/orb transitions without touching the shared glass.
    /// May be sampled alongside geometry. setPresentationActive(false) additionally holds ambient clocks.
    func setOpacity(_ opacity: Float) {
        guard !disposed else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [backPlacement, frontPlacement, bodyPlacement] { layer.opacity = min(1, max(0, opacity)) }
        updateSatelliteVisibility(at: CACurrentMediaTime())
        updateBodyVisibility()
        CATransaction.commit()
    }

    private func updateSatelliteVisibility(at now: CFTimeInterval) {
        func visible(_ view: NSView, _ placement: CALayer) -> Bool {
            var ancestor: NSView? = view
            while let current = ancestor {
                if current.isHidden || current.alphaValue == 0 { return false }
                ancestor = current.superview
            }
            var layer: CALayer? = placement
            while let current = layer {
                if current.isHidden || current.opacity == 0 { return false }
                layer = current.superlayer
            }
            return true
        }
        satellites.setVisible(visible(backView, backPlacement) || visible(frontView, frontPlacement), at: now)
    }

    /// The veil (product OrbView `orbVeiled`; a peek, a bud coming out of a bar): the planet's body and its badge go
    /// while its satellites stay. Sampled per frame by the Dock (added by Claude for f045, f066).
    func setVeil(_ amount: Float) {
        guard !disposed else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bodyMotion.opacity = 1 - min(1, max(0, amount))
        bodyVeil = amount
        badgePlacement.opacity = bodyMotion.opacity
        hostGlyph.carrier.opacity = bodyMotion.opacity
        updateBodyVisibility()
        CATransaction.commit()
    }

    private func place(_ rect: CGRect, contentFrame: CGRect?) {
        let local = contentFrame ?? CGRect(origin: .zero, size: rect.size)
        let decoration = local.offsetBy(dx: rect.minX, dy: rect.minY)
        for (layer, r) in [(backPlacement, decoration), (frontPlacement, decoration), (bodyPlacement, local)] {
            layer.position = CGPoint(x: r.midX, y: r.midY)
            layer.transform = CATransform3DMakeScale(r.width/drawingSize, r.height/drawingSize, 1)
        }
        let center=CGPoint(x:decoration.midX,y:decoration.midY)
        if case .me = configuration?.content { backPlacement.name="organic.body.light-anchor"; BodyLightRegistry.shared.setAnchor(owner:self,view:backView,point:center) }
        texturedBody.setGeometry(view:backView,center:center)
        phaseBody.setLightBin(texturedBody.lightBin)
        if configuration?.meBadgeAtCorner == true {
            frontMotion.transform = frontPlacement.transform
            frontPlacement.transform = CATransform3DIdentity
            placeMeBadge(logical: decoration, painted: decoration)
            return
        }
        if badgePlacement.superlayer !== frontMotion { badgePlacement.removeFromSuperlayer(); frontMotion.addSublayer(badgePlacement) }
        let diameter = min(local.width*0.4, 18), scale = max(0.0001, diameter/badgeDiameter)
        badgePlacement.position = CGPoint(x: drawingSize*0.86, y: drawingSize*0.14)
        // Counter the parent's magnification so the product's badge stops at 18 pt.
        badgePlacement.transform = CATransform3DMakeScale(scale*drawingSize/max(0.0001, local.width),
                                                        scale*drawingSize/max(0.0001, local.height), 1)
        badge.lineWidth = max(1, diameter*0.1)/scale
    }
    private func placeMeBadge(logical: CGRect, painted: CGRect) {
        if badgePlacement.superlayer !== frontPlacement { badgePlacement.removeFromSuperlayer(); frontPlacement.addSublayer(badgePlacement) }
        let center = CGPoint(x: logical.maxX + 3 - badgePlacement.bounds.width / 2, y: logical.minY - 3 + 7)
        badgePlacement.position = frontPlacement.convert(center, from: frontView.layer)
        badgePlacement.transform = CATransform3DIdentity
        badge.lineWidth = 0
    }

    func setPresentationActive(_ active: Bool) {
        guard !disposed, self.active != active else { return }
        self.active = active
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updatePause(at: CACurrentMediaTime()); CATransaction.commit()
        updateBodyVisibility()
    }

    private var bodyIsVisible: Bool {
        guard !disposed,configuration?.bodyVisible != false,bodyPlacement.opacity>0.001,bodyVeil<0.999 else { return false }
        var node: NSView?=bodyView
        while let view=node {
            if view.isHidden || view.alphaValue<=0.001 { return false }; node=view.superview
        }
        if let window=bodyView.window {
            phaseWindowAttached=true
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
        if configuration?.bodyPhase != nil,phaseWindowAttached {return false}
        return true
    }
    private func updateBodyPresentation() {
        guard let c=configuration else { return }
        guard case .identity(let identity)=c.content else {
            phaseBody.configure(c,visible:false,active:false)
            texturedBody.setVisibility(false,keyWindow:false);texturedBody.layer.isHidden=true;return
        }
        texturedBody.configure(bodyID:identity.resolvedBodyID,outer:c.bodyOuter ?? c.drawingSize,drawingSize:drawingSize,scale:c.backingScale,unknown:c.bodyUnknown || !c.context.isFinite,visible:bodyIsVisible,keyWindow:bodyView.window?.isKeyWindow ?? c.isKeyWindow)
        phaseBody.configure(c,visible:bodyIsVisible,active:active,bin:texturedBody.lightBin,samplingOuter:CGFloat(texturedBody.samplingTier))
        texturedBody.layer.opacity=c.bodyPhase == nil || phaseBody.picture.image == nil ? 1:0
        if c.bodyPhase == nil {prepareBodyInk()}
    }
    private func prepareBodyInk() {
        phaseBody.setLightBin(texturedBody.lightBin)
        guard !disposed,let image=phaseBody.picture.image ?? texturedBody.displayedImage else { return }
        if configuration?.bodyPhase != nil,phaseBody.picture.image != nil {texturedBody.layer.opacity=0}
        hostGlyph.prepare(image:image,size:CGSize(width:drawingSize,height:drawingSize))
        completionInk.reusePreparedInk(from:hostGlyph)
    }
    private func updateBodyVisibility() {
        guard case .identity = configuration?.content else { return }
        phaseBody.setActivity(visible:bodyIsVisible,animate:active && configuration?.isKeyWindow == true && configuration?.reduceMotion != true)
        texturedBody.layer.opacity=configuration?.bodyPhase == nil || phaseBody.picture.image == nil ? 1:0
        texturedBody.setVisibility(bodyIsVisible,keyWindow:bodyView.window?.isKeyWindow ?? configuration?.isKeyWindow ?? true)
    }
    var bodyWork: [String:Int] { configuration?.bodyPhase == nil ? texturedBody.work:phaseBody.picture.work }

    private func updatePause(at now: CFTimeInterval) {
        updateSatelliteVisibility(at: now)
        satellites.setPhaseActive(active && configuration?.reduceMotion != true)
        let wanted = !active || configuration?.ambient != true || configuration?.reduceMotion == true
        if wanted,glyphGaussian?.plan != nil {
            gaussianNeedsModelSampling=true
            let finish = !active ? max(glyphGaussian?.endTime ?? now,badgeGaussian?.endTime ?? now):now
            settleGlyphGaussian(at:finish)
        }
        if wanted {
            visitExposure { layer,key,animation in
                heldExposure.append(HeldExposure(layer:layer,key:key,animation:animation));layer.removeAnimation(forKey:key)
            }
            glyphTrail.reset();resetHostExposure()
            glyphGroup.removeAnimation(forKey:"m101.completion.native")
            glyphTrail.layer.removeAnimation(forKey:"m101.completion.ink");glyphTrail.layer.opacity=0
            completionPose.removeAnimation(forKey:"completion")
        } else if exposureEnabled {
            for item in heldExposure { item.layer?.add(item.animation,forKey:item.key) }
            heldExposure.removeAll()
        }
        // Presence describes current semantic truth. Settling before a parent clock stops prevents a
        // partially visible badge (or a delayed entrance) when this retained orb returns from a bar.
        if wanted { settleBadgePresence(); liquid.finishFeedback() }
        for layer in [backPlacement, frontPlacement, bodyPlacement] { OrbMotion.setAnimationsPaused(wanted, on: layer, at: now) }
        // Never pause DockNode's glass layer: it also owns geometry/entry transitions. Pause ONLY our hop animation.
        if wanted != glassHopPaused, let layer = glassView.layer,
           let hop = layer.animation(forKey: glassHopKey)?.copy() as? CAAnimation {
            let t = layer.convertTime(now, from: nil)
            if wanted {
                hop.timeOffset += max(0, t-hop.beginTime)*Double(hop.speed)
                hop.speed = 0; hop.beginTime = t
            } else {
                hop.beginTime = t-hop.timeOffset; hop.timeOffset = 0; hop.speed = 1
            }
            layer.add(hop, forKey: glassHopKey)
        }
        glassHopPaused = wanted
    }

    private func rebuildDrawing(_ c: OrbConfiguration) {
        let contentKey: String
        switch c.content {
        case .seed: contentKey = "seed:sparkle"
        case .identity(let i): contentKey = "planet:\(i.symbol.rawValue)"
        case .me(let text, _): contentKey = "me:\(text):\(c.meLabel ?? ""):\(c.meLabelVisible)"
        }
        let key = "\(contentKey)|\(drawingSize)|\(c.backingScale)|\(c.appearance)|\(OrbDisplayEnvironment.shared.options)"
        guard drawingKey != key else { return }; drawingKey = key
        let d = drawingSize, box = CGRect(x: 0, y: 0, width: d, height: d)
        if bodyView.frame != box { bodyView.frame = box }
        for layer in [backPlacement, frontPlacement, bodyPlacement, backMotion, frontMotion, bodyMotion, glyphGroup] {
            layer.bounds = box
        }
        for layer in [backMotion, frontMotion, bodyMotion, glyphGroup] { layer.position = CGPoint(x: d/2, y: d/2) }
        bodyMotion.masksToBounds = true; bodyMotion.cornerRadius = d/2
        glyph.frame = box; initials.frame = box
        glyph.contentsScale = max(1, c.backingScale)
        initials.contentsScale = max(1, c.backingScale)*2
        meLabel.isHidden = true
        seedGlyph.isHidden = c.content != .seed
        if case .identity = c.content { texturedBody.layer.isHidden=false } else { texturedBody.layer.isHidden=true }
        switch c.content {
        case .seed:
            glyph.isHidden = true; initials.isHidden = true
            let scale = max(1, c.backingScale), pointSize = d*26/88
            let side = ceil(pointSize*1.5*scale)/scale
            let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium).applying(.init(paletteColors: [OrbDisplayEnvironment.shared.options.opaqueSurfaces ? .labelColor:.secondaryLabelColor])))!
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side*scale), pixelsHigh: Int(side*scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = CGSize(width: side, height: side)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: CGRect(x: (side-image.size.width)/2, y: (side-image.size.height)/2, width: image.size.width, height: image.size.height))
            NSGraphicsContext.restoreGraphicsState()
            seedGlyph.contents = bitmap.cgImage; seedGlyph.contentsScale = scale
            seedGlyph.frame = CGRect(x: ((d-side)/2*scale).rounded()/scale, y: ((d-side)/2*scale).rounded()/scale, width: side, height: side)
            counters.value.glyphPaths += 1
        case .identity(let identity):
            _ = identity
            glyph.isHidden = true; glyph.path=nil; initials.isHidden = true
        case .me(let text, _):
            glyph.isHidden = true; initials.isHidden = !c.meLabelVisible
            meLabel.isHidden = !c.meLabelVisible || c.meLabel == nil
            counters.value.textLayouts += 1
            let font = NSFont.systemFont(ofSize: d*0.32, weight: .semibold)
            initials.font = font; initials.fontSize = font.pointSize; initials.string = text
            let h = font.ascender-font.descender
            initials.frame = CGRect(x: 0, y: (d-h)/2, width: d, height: h)
            meLabel.font = font; meLabel.fontSize = font.pointSize; meLabel.string = c.meLabel
            meLabel.contentsScale = max(1, c.backingScale)*2; meLabel.frame = initials.frame
            meLabel.foregroundColor = NSColor.labelColor.cgColor
            initials.opacity = Float(1 - meLabelMix); meLabel.opacity = Float(meLabelMix)
        }
        counters.value.glowPaths += 1
        glow.frame = box; glow.path = CGPath(ellipseIn: box.insetBy(dx: -d*0.02, dy: -d*0.02), transform: nil)
        glow.lineWidth = d*0.08; glow.shadowRadius = d*0.1
    }

    private func rebuildBadge(_ c: OrbConfiguration) {
        guard let renderedBadge else { return }
        let text = renderedBadge.symbol.text
        let key = "\(text)|\(drawingSize)|\(c.backingScale)|\(c.meBadgeAtCorner)"
        if key != badgeKey {
            badgeKey = key
            let d = c.meBadgeAtCorner ? 14 : min(drawingSize*0.4, 18)
            badgeDiameter = d
            let font = NSFont.systemFont(ofSize: c.meBadgeAtCorner ? 8 : d*(text.count > 2 ? 0.48 : 0.62), weight: .bold)
            let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
            counters.value.textLayouts += 1
            let width = max(d, (text as NSString).size(withAttributes: [.font: rounded]).width + (c.meBadgeAtCorner ? 6 : text.count > 1 ? d*0.44 : 0))
            let box = CGRect(x: 0, y: 0, width: width, height: d)
            if c.meBadgeAtCorner { badge.transform = CATransform3DIdentity }
            badgePlacement.bounds = box; badge.frame = box
            counters.value.badgePaths += 1
            badge.path = CGPath(roundedRect: box, cornerWidth: d/2, cornerHeight: d/2, transform: nil)
            badgeText.font = rounded; badgeText.fontSize = rounded.pointSize; badgeText.string = text
            badgeText.contentsScale = max(1, c.backingScale)*2
            let h = rounded.ascender-rounded.descender
            badgeText.frame = CGRect(x: 0, y: (d-h)/2, width: width, height: h)
        }
        badge.fillColor = (renderedBadge.tone == .red ? NSColor.systemRed : renderedBadge.tone == .yellow ? .systemYellow : .systemGreen).cgColor
        badge.strokeColor = NSColor(srgbRed: 42/255, green: 43/255, blue: 42/255, alpha: 1).cgColor
        badgeText.foregroundColor = (renderedBadge.tone == .red ? NSColor.white : NSColor.black.withAlphaComponent(OrbDisplayEnvironment.shared.options.opaqueSurfaces ? 1:0.85)).cgColor
        badge.opacity = c.badge == nil ? 0 : 1
        badge.setAffineTransform(CGAffineTransform(scaleX: c.badge == nil ? 0.4 : 1, y: c.badge == nil ? 0.4 : 1))
    }

    private func animateBadge(from old: OrbBadge?, to next: OrbBadge?, reduceMotion: Bool) {
        guard !reduceMotion, active, configuration?.ambient == true, frontPlacement.speed != 0 else {
            settleBadgePresence(); return
        }
        guard (old == nil) != (next == nil) else { return }
        let show = next != nil
        let scale = CGFloat(badge.presentation()?.value(forKeyPath: "transform.scale") as? Double ?? (show ? 0.4 : 1))
        let spring = OrbMotion.spring("transform.scale", from: scale, to: show ? 1 : 0.4)
        spring.beginTime = badge.convertTime(CACurrentMediaTime(), from: nil)
        badge.add(spring, forKey: "presence.scale")
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = badge.presentation()?.opacity ?? (show ? 0 : 1); opacity.toValue = show ? 1 : 0
        opacity.duration = spring.duration; opacity.beginTime = spring.beginTime
        badge.add(opacity, forKey: "presence.opacity")
    }

    private func settleBadgePresence() {
        badge.removeAnimation(forKey:"presence.scale"); badge.removeAnimation(forKey:"presence.opacity")
        let shown=configuration?.badge != nil
        badge.opacity=shown ? 1:0
        badge.setAffineTransform(CGAffineTransform(scaleX:shown ? 1:0.4,y:shown ? 1:0.4))
    }

    private func alertHop(at now: CFTimeInterval) {
        // The placement's translation is in scene points, outside its scale: hover must not amplify the 5 pt hop.
        for layer in [backPlacement, frontPlacement] {
            let hop = OrbMotion.alertHop(); hop.beginTime = layer.convertTime(now, from: nil)
            layer.add(hop, forKey: "alert")
        }
        if ownsGlassFeedback, let layer = glassView.layer {
            let hop = OrbMotion.alertHop(); hop.beginTime = layer.convertTime(now, from: nil)
            layer.add(hop, forKey: glassHopKey); glassHopPaused = false
        }
    }

    private func removeAlert() {
        backPlacement.removeAnimation(forKey: "alert"); frontPlacement.removeAnimation(forKey: "alert")
        glassView.layer?.removeAnimation(forKey: glassHopKey); glassHopPaused = false
    }



    private func completionHop() {
        // Copy of the product's pure spring evaluator, sampled once; no SwiftUI view animation or timer.
        let timeline=OrbMotion.completionKeyframes(),values=timeline.values
        let y = CAKeyframeAnimation(keyPath: "transform.translation.y")
        y.values = values.map { -$0*Double(drawingSize)*0.14 }
        let s = CAKeyframeAnimation(keyPath: "transform.scale"); s.values = values.map { 1+$0*0.12 }
        let group = CAAnimationGroup(); group.animations = [y, s]; group.duration = timeline.duration
        group.beginTime = glyphGroup.convertTime(CACurrentMediaTime(), from: nil)
        glyphGroup.add(group, forKey: "completion")
        var profile=motionProfile ?? M10FExposure.profile(for:glassView)
        profile.mmPerPoint *= Double((contentFrame ?? frame ?? CGRect(x:0,y:0,width:drawingSize,height:drawingSize)).width/drawingSize)
        let size=drawingSize,duration=timeline.duration
        guard exposureEnabled, active, configuration?.ambient == true else { return }
        glyphTrail.layer.bounds=CGRect(x:0,y:0,width:drawingSize,height:drawingSize)
        glyphTrail.layer.position=CGPoint(x:drawingSize/2,y:drawingSize/2)
        completionPose.frame=glyphTrail.layer.bounds
        if completionPose.superlayer !== glyphTrail.layer {glyphTrail.layer.addSublayer(completionPose)}
        completionInk.installPreparedBitmap(in: completionPose, size: CGSize(width:drawingSize,height:drawingSize))
        let show=CAKeyframeAnimation(keyPath:"opacity");show.values=[0,0,1];show.keyTimes=[0,0.999999,1];show.calculationMode = .discrete
        show.duration=duration;show.beginTime=glyphGroup.convertTime(CACurrentMediaTime(),from:nil)
        glyphGroup.add(show,forKey:"m101.completion.native")
        let hide=CAKeyframeAnimation(keyPath:"opacity");hide.values=[1,1,0];hide.keyTimes=show.keyTimes;hide.calculationMode = .discrete
        hide.duration=duration;hide.beginTime=glyphTrail.layer.convertTime(CACurrentMediaTime(),from:nil)
        glyphTrail.layer.opacity=0;glyphTrail.layer.add(hide,forKey:"m101.completion.ink")
        // The raster follows the same authored hop; no live vector/shadow enters the replica subtree.
        let hop=group.copy() as! CAAnimation;hop.beginTime=glyphTrail.layer.convertTime(CACurrentMediaTime(),from:nil)
        completionPose.add(hop,forKey:"completion")
        heldExposure.removeAll { $0.layer === glyphTrail.layer }
        M10FExposure.glyphMotion(trail:glyphTrail,duration:duration,timing:group,profile:profile) { t in
            // The original CA group linearly interpolates its 81 samples; sample that same path.
            let u=min(80,max(0,t/duration*80)),i=min(79,Int(u)),p=values[i]+(values[i+1]-values[i])*(u-Double(i))
            return CGRect(x:0,y:-p*Double(size)*0.14,width:Double(size)*(1+p*0.12),height:Double(size)*(1+p*0.12))
        }
        // Below the physical gate keep the exact native primitive, including the first/last sample.
        // The flattened drawing is exposed ONLY on samples where the shared plan actually has copies.
        if let plan=glyphTrail.layer.animation(forKey:"m10F.glyph") as? CAAnimationGroup,
           let counts=plan.animations?.compactMap({$0 as? CAKeyframeAnimation}).first(where:{$0.keyPath == "instanceCount"}),
           let values=counts.values {
            show.keyTimes=counts.keyTimes;hide.keyTimes=counts.keyTimes
            show.values=values.map{(($0 as? NSNumber)?.intValue ?? 1)>1 ? 0:1}
            hide.values=values.map{(($0 as? NSNumber)?.intValue ?? 1)>1 ? 1:0}
            glyphGroup.add(show,forKey:"m101.completion.native");glyphTrail.layer.add(hide,forKey:"m101.completion.ink")
        } else {
            glyphGroup.removeAnimation(forKey:"m101.completion.native")
            glyphTrail.layer.removeAnimation(forKey:"m101.completion.ink");glyphTrail.layer.opacity=0
        }
    }
    private func visitExposure(_ visit:(CALayer,String,CAAnimation)->Void) {
        func walk(_ layer:CALayer) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("m10F.") { if let animation=layer.animation(forKey:key) { visit(layer,key,animation) } }
            for child in layer.sublayers ?? [] { walk(child) }
        }
        for layer in [backPlacement,bodyPlacement,frontPlacement] { walk(layer) }
    }
    func resetHostExposure() {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        hostGlyph.reset();hostBadge.reset();glyphGroup.isHidden=false;badgeText.isHidden=false
    }
    private func discardExposure() {
        satellites.discardHeldExposure()
        resetHostExposure()
        heldExposure.removeAll();visitExposure { layer,key,_ in layer.removeAnimation(forKey:key) };glyphTrail.reset()
    }

    /// Header-only finite body feedback. Satellite clocks and positions do not tilt.
    func animateHeaderRename() {
        guard configuration?.reduceMotion != true, !disposed else { return }
        if case .identity = configuration?.content { return }
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = [0, -4*Double.pi/180, 2*Double.pi/180, 0]
        a.keyTimes = [0, 0.3333333333, 0.6666666667, 1]; a.duration = 0.18
        bodyMotion.add(a, forKey: "headerRename")
    }

    /// Offscreen verification/endpoint preview only. No render-server glass backdrop exists here.
    /// Live snapshots continue to use the window's own cacheDisplay representation.
    func renderOffscreenDecorations(in context: CGContext, planet: CGRect) {
        // This entry is offscreen only. Temporarily move the actual model planes, like OrbVerification;
        // init(layer:) clones can carry the view's hidden/presentation backing and omit its ornaments.
        let planes = [backPlacement, bodyPlacement, frontPlacement]
        let parents = planes.map { layer in
            (parent: layer.superlayer, index: layer.superlayer?.sublayers?.firstIndex(of: layer) ?? 0)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scene = CALayer(); scene.bounds = CGRect(origin: .zero, size: canvasSize ?? planet.size); scene.isGeometryFlipped = true
        scene.addSublayer(backPlacement)
        let proxy = CAShapeLayer(); proxy.path = CGPath(ellipseIn: planet, transform: nil)
        proxy.fillColor = OrbDisplayEnvironment.surface(NSColor(white:0.22,alpha:1),opacity:0.6).cgColor
        proxy.strokeColor = OrbDisplayEnvironment.surface(NSColor(white:0.7,alpha:1),opacity:0.22).cgColor; proxy.lineWidth = 0.7; scene.addSublayer(proxy)
        let body = CALayer(); body.anchorPoint = .zero; body.position = planet.origin; body.addSublayer(bodyPlacement); scene.addSublayer(body)
        scene.addSublayer(frontPlacement); scene.render(in: context)
        for (plane, prior) in zip(planes, parents) {
            plane.removeFromSuperlayer()
            prior.parent?.insertSublayer(plane, at: UInt32(prior.index))
        }
        CATransaction.commit()
    }

    /// Removes only component-owned views/animations; the scene retains its glass identity.
    func dispose() {
        guard !disposed else { return }; disposed = true
        if let displayObservation { OrbDisplayEnvironment.shared.removeObserver(displayObservation); self.displayObservation=nil }
        removeAlert()
        satellites.dispose()
        if configuration?.bodyPhase != nil {hostGlyph.bitmap.contents=nil;completionInk.bitmap.contents=nil}
        phaseBody.dispose()
        texturedBody.dispose(); BodyLightRegistry.shared.remove(self)
        discardExposure()
        glyphTrail.layer.removeAllAnimations();glyphTrail.reset()
        backView.removeFromSuperview(); frontView.removeFromSuperview(); bodyView.removeFromSuperview()
        for root in [backPlacement, frontPlacement, bodyPlacement] { root.removeFromSuperlayer() }
    }

    #if M9_SPLIT_SELFTEST
    var verificationBodyView: NSView { bodyView }
    var verificationBadgePlacement: CALayer { badgePlacement }
    var mountedGlyph: CALayer { glyphGroup }
    var mountedGlyphInk: CALayer { glyph }
    var mountedLiquid: CALayer { liquid.layer }
    var mountedSatelliteFront: CALayer { satellites.front }
    var mountedPlanes: [CALayer] { [backPlacement,bodyPlacement,frontPlacement] }
    #endif
    #if ORB_SELFTEST || M10_DOCK_SELFTEST
    var verificationConfiguration:OrbConfiguration? {configuration}
    var verificationGaussianState:[String:Any] {["opacity":glyphGroup.opacity,"modelSampling":gaussianNeedsModelSampling,"filtered":!(glyphGroup.filters ?? []).isEmpty]}
    var verificationHostPlanes:[CALayer] {[backPlacement,bodyPlacement,frontPlacement]}
    var verificationHostGlyph:OrbHostInk {hostGlyph}
    var verificationHostBadge:OrbHostInk {hostBadge}
    #if M10_DOCK_SELFTEST && !(ORB_SELFTEST || ISLAND_SELFTEST)
    var verificationBadgeLayer:CALayer {badge}
    var verificationGlyphLayer:CALayer {glyphGroup}
    #endif
    #endif
    #if ORB_SELFTEST || ISLAND_SELFTEST
    var verificationLayers: [CALayer] { [backPlacement, bodyPlacement, frontPlacement] }
    var verificationMotionLayers: [CALayer] { [backPlacement, bodyPlacement, frontPlacement, liquid.surfaceLayer, glow] }
    var verificationLiquidColors: [CGColor] { liquid.fill.colors as? [CGColor] ?? [] }
    var verificationSeedLayer: CALayer { seedGlyph }
    var verificationContent: OrbContent? { configuration?.content }
    var verificationLiquidLevel: Double? { configuration?.liquidLevel }
    var verificationBadgeLayer: CALayer { badge }
    var verificationGlyphLayer: CALayer { glyphGroup }
    var verificationSpinnerLayer: CALayer { liquid.spinnerLayer }
    func verificationPhases(at time: CFTimeInterval) -> [(Double, Double)] { satellites.phases(at: time) }
    func verificationPause(_ value: Bool, at time: CFTimeInterval) {
        for layer in [backPlacement, frontPlacement, bodyPlacement] { OrbMotion.setAnimationsPaused(value, on: layer, at: time) }
    }
    func verificationSample(phase: Double) { satellites.sampleModels(phase: phase) }
    var verificationSatellites: [String: (front: CGPoint, back: CGPoint, frontOpacity: Float, backOpacity: Float)] { satellites.geometry }
    #endif
}

/// A layer-hosting, click-through plane. Geometry lives entirely in its sublayers.
/// Auto Layout is never installed or requested. The counter catches unexpected AppKit callbacks.
private final class OrbDecorationView: NSView {
    private let metrics: OrbMetrics
    var visibilityChanged: (() -> Void)?
    private var windowObservations: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    init(metrics: OrbMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        layer = CALayer(); wantsLayer = true
        layer?.isGeometryFlipped = true; layer?.masksToBounds = false
        autoresizesSubviews = false
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityElement(false); setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidHide() { super.viewDidHide(); visibilityChanged?() }
    override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged?() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); visibilityChanged?() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in windowObservations { NotificationCenter.default.removeObserver(token) }; windowObservations=[]
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification] {
                windowObservations.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.visibilityChanged?() }
                })
            }
        }
        visibilityChanged?()
    }
    isolated deinit { for token in windowObservations { NotificationCenter.default.removeObserver(token) } }
    override func layout() { metrics.value.layoutCalls += 1; super.layout() }
}
