import AppKit
import QuartzCore

/// A key contains presentation state as well as model revisions. A draft edit or scroll need not publish a store event.
struct ModePreparationKey: Equatable {
    var mode: String, size: CGSize, scale: CGFloat, appearance: Int, reduced: Bool
    var selected: String, current: String, order: [String], rows: [String], sidebarScroll: CGPoint
    var display: Int, contrast: Int, flags: [String]
    var models: [Model], viewports: [Viewport]
    var headerStates:[HeaderIslandState?] = [],headerRects:[CGRect] = []
    var deviceStatus: [String] = []
    var scheme:AutoScene.Scheme? = nil
    struct Model: Equatable {
        var identity: ObjectIdentifier, revision: Int, draft: String, attachments: [Attachment]
    }
    struct Viewport: Equatable {
        var identity: ObjectIdentifier, frame: CGRect, scroll: CGPoint, revision: Int
        var editor: String, selection: NSRange, marked: NSRange
    }
}

/// Only immutable pixels and value plans are cached. No live editor, lease, callback or selection is transferred here.
@MainActor struct PreparedModeSwitch {
    let key:ModePreparationKey
    let geometryKey:ModePreparationKey
    let hasSource:Bool
    let source: ModeSurfacePicture
    let sidebarContentKey:String
    let sidebar: CGImage
    let rows: [String: CGRect]
    let avatar: CGRect
    let headers: [ModeHeaderEndpoint]
    let toOrganic: [ModeFlight.Token], toNormie: [ModeFlight.Token]
    let composer: CGRect?
    let sidebarSafeRect: CGRect
    let organicTarget:AutoScene.ModeTargetPlan?
}

/// One plain image, never replicated. It holds the source until the destination has actually been laid out.
@MainActor final class ModeHandoffPlate: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { blocksSourceInput && bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    // The old carrier changes WindowServer's backdrop ancestry before the first frame. Keep source materials resident.
    static let carriesGlass=ProcessInfo.processInfo.environment["M11_MODE_GLASS_CARRY"] == "1"
    private let maskShape = CAShapeLayer()
    // AppKit owns the backing layer's contents. Keep the immutable image in its own child layer.
    private let glassPlane = ModeFlight.Plane()
    private var imagePlane = ModeFlight.Plane()
    private var imageLayer = CALayer()
    private var nativeBacking=ModeFlight.Plane()
    private var compositionGroups:[NSView]=[]
    private var hasNativeBacking=false
    private var photoGlassRects:[CGRect]=[]
    private func retainGlassFootprints(_ image:ModeSurfacePicture) {
        guard ModeFlight.orreryEnabled else {return}
        for material in image.glasses {
            let rect=material.rect
            // Input ink remains in the photo; its real material replica is below that ink.
            let orb=rect.width>0 && rect.width<=80 && abs(rect.width-rect.height)<1
            if orb,!photoGlassRects.contains(rect) {photoGlassRects.append(rect)}
        }
    }
    var presentationInterval:Double? {didSet {intervalScreen=window?.screen}}
    private weak var intervalScreen:NSScreen?
    private let displayProfile=M10ModeDisplayProfile()
    private var commitInterval:Double {
        let sampled=displayProfile.sample(for:self).frameInterval
        return Self.resolveCommitInterval(measured:presentationInterval,sameScreen:intervalScreen === window?.screen,nominal:sampled)
    }
    static func resolveCommitInterval(measured:Double?,sameScreen:Bool,nominal:Double)->Double {
        sameScreen ? (measured ?? nominal):nominal
    }
    @MainActor private final class CarriedGlass {
        let view:NSGlassEffectView, index:Int, source:CGRect, originalAlpha:CGFloat
        weak var content:NSView?
        let contentAlpha:CGFloat
        weak var parent:NSView?, sourcePlane:NSView?, root:NSView?
        var frame:CGRect, destination:CGRect?, adoptsDestination=false
        init(_ view:NSGlassEffectView,parent:NSView,index:Int,frame:CGRect,source:CGRect,sourcePlane:NSView?,root:NSView?) {
            self.view=view;self.parent=parent;self.index=index;self.frame=frame;self.source=source;self.sourcePlane=sourcePlane;self.root=root;originalAlpha=view.alphaValue;content=view.contentView;contentAlpha=view.contentView?.alphaValue ?? 1
        }
    }
    private var fadeStarted=0.0,fadeDuration=0.22
    private var carriedGlass:[CarriedGlass]=[]
    private(set) var picture: ModeSurfacePicture?
    private(set) var fading = false
    private var generation: UInt64 = 0
    private var staged: ModeSurfacePicture?
    private var blocksSourceInput = false
    /// Left open in the picture: going to Organic the real sidebar slides away, and the picture's still copy of it stood
    /// under the moving one, every row twice (board 10-31).
    var openRect: CGRect?

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        glassPlane.wantsLayer=true; imagePlane.wantsLayer=true
        nativeBacking.wantsLayer=true
        addSubview(glassPlane);addSubview(nativeBacking);addSubview(imagePlane)
        imageLayer.isGeometryFlipped=ModeFlight.orreryEnabled
        imagePlane.layer?.addSublayer(imageLayer)
        setAccessibilityElement(false); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func shieldSource(in host: NSView, below: NSView) {
        generation &+= 1; fading = false
        let opacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAllAnimations(); layer?.opacity = opacity
        CATransaction.commit()
        blocksSourceInput = true; frame = host.bounds
        host.addSubview(self, positioned: .below, relativeTo: below)
        layer?.zPosition=ModePlaneOrder.source; below.layer?.zPosition=ModePlaneOrder.flight
        isHidden = false
    }

    func stage(_ image: CGImage, in host: NSView, below: NSView) { stage(ModeSurfacePicture(image:image),in:host,below:below) }
    func stage(_ image: ModeSurfacePicture, in host: NSView, below: NSView) {
        guard picture == nil else { return }
        frame = host.bounds; autoresizingMask = [.width, .height]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        alphaValue = 0
        install(image)
        layer?.opacity = 0; layer?.mask = nil
        CATransaction.commit()
        staged = image
        retainGlassFootprints(image)
        host.addSubview(self, positioned: .below, relativeTo: below)
        layer?.zPosition=ModePlaneOrder.source; below.layer?.zPosition=ModePlaneOrder.flight
        isHidden = false
    }

    func hold(_ image: CGImage, in host: NSView, below: NSView, holes:[CGRect]) { hold(ModeSurfacePicture(image:image),in:host,below:below,holes:holes) }
    func hold(_ image: ModeSurfacePicture, in host: NSView, below: NSView, holes: [CGRect]) {
        if picture !== image {restoreGlass()}
        resetComposition();photoGlassRects=[];retainGlassFootprints(image)
        generation &+= 1; fading = false; picture = image; blocksSourceInput = true
        frame = host.bounds; autoresizingMask = [.width, .height]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        alphaValue = 1
        layer?.removeAllAnimations(); layer?.opacity = 1
        imagePlane.layer?.removeAllAnimations();imagePlane.layer?.opacity=1
        if staged !== image { install(image) }
        for material in image.glasses where Self.carriesGlass {
            guard let glass=material.view, !holes.contains(where:{$0.contains(CGPoint(x:material.rect.midX,y:material.rect.midY))}),
                  let parent=glass.superview, parent !== glassPlane else {continue}
            carriedGlass.append(.init(glass,parent:parent,index:parent.subviews.firstIndex(of:glass) ?? 0,frame:glass.frame,source:material.rect,sourcePlane:material.sourcePlane,root:image.root))
            glassPlane.addSubview(glass);glass.contentView?.alphaValue=0;glass.frame=material.rect
        }
        staged = image
        updateHoles(holes)
        CATransaction.commit()
        host.addSubview(self, positioned: .below, relativeTo: below)
        layer?.zPosition=ModePlaneOrder.source; below.layer?.zPosition=ModePlaneOrder.flight
        isHidden = false
    }

    /// Freeze one subtree on main. A worker receives only immutable values, never AppKit/CA objects.
    private static let compositionQueue=DispatchQueue(label:"organic.mode-photo-composition",qos:.userInitiated)
    private var flattenLease:UInt64=0
    private var flattenPending=false
    private var compositionsApplied=0
    private(set) var compositionCosts:[String:Double]=[:]
    private func flattenCompositionIfNeeded() {
        guard ModeFlight.orreryEnabled,compositionGroups.count>=3,!flattenPending else {return}
        let started=CACurrentMediaTime(),size=bounds.size
        let scale=window?.backingScaleFactor ?? picture?.scale ?? 1
        let anchor=ModeFlight.Plane(frame:bounds);anchor.wantsLayer=true
        for child in subviews where child !== glassPlane {anchor.addSubview(child)}
        addSubview(anchor);compositionGroups=[anchor]
        let snapshot=ModePhotoSnapshot.capture(anchor,size:size,scale:scale)
        flattenLease &+= 1;let lease=flattenLease;flattenPending=true
        compositionCosts["freezeMS"]=(CACurrentMediaTime()-started)*1000
        Self.compositionQueue.async { [weak self,weak anchor] in
            let start=CACurrentMediaTime(),result=snapshot.render()
            let cost=(CACurrentMediaTime()-start)*1000
            DispatchQueue.main.async {
                guard let self,self.flattenLease == lease else {return}
                self.flattenPending=false
                guard let anchor,anchor.isDescendant(of:self),self.bounds.size == size,
                      (self.window?.backingScaleFactor ?? self.picture?.scale ?? 1) == scale,let result else {return}
                let start=CACurrentMediaTime()
                CATransaction.begin();CATransaction.setDisableActions(true)
                anchor.subviews.forEach {$0.removeFromSuperview()}
                anchor.layer?.sublayers?.forEach {$0.removeFromSuperlayer()}
                let image=CALayer();image.frame=anchor.bounds;image.contents=result;image.contentsScale=scale
                image.isGeometryFlipped=true;anchor.layer?.addSublayer(image)
                if self.imagePlane.isDescendant(of:anchor) {self.imagePlane=anchor;self.imageLayer=image}
                if self.nativeBacking.isDescendant(of:anchor) {
                    self.nativeBacking=ModeFlight.Plane(frame:self.bounds);self.nativeBacking.wantsLayer=true;self.nativeBacking.isHidden=true
                    self.addSubview(self.nativeBacking,positioned:.above,relativeTo:self.glassPlane)
                }
                self.compositionsApplied+=1
                self.compositionGroups.removeAll {!$0.isDescendant(of:self)}
                CATransaction.commit()
                self.compositionCosts["composeBackgroundMS"]=cost
                self.compositionCosts["replaceMS"]=(CACurrentMediaTime()-start)*1000
            }
        }
    }
    private func preserveComposition() {
        flattenCompositionIfNeeded()
        let opacity=layer?.presentation()?.opacity ?? layer?.opacity ?? 1
        let inkOpacity=imagePlane.layer?.presentation()?.opacity ?? imagePlane.layer?.opacity ?? 1
        imagePlane.layer?.removeAllAnimations();imagePlane.layer?.opacity=inkOpacity
        layer?.removeAllAnimations()
        let group=ModeFlight.Plane(frame:bounds);group.wantsLayer=true;group.alphaValue=CGFloat(opacity)
        for child in subviews where child !== glassPlane {group.addSubview(child)}
        addSubview(group);compositionGroups.append(group)
        alphaValue=1;layer?.opacity=1
    }
    private func resetComposition() {
        flattenLease &+= 1;flattenPending=false
        imagePlane.removeFromSuperview();nativeBacking.removeFromSuperview()
        for group in compositionGroups {group.removeFromSuperview()}
        compositionGroups=[];addSubview(nativeBacking);addSubview(imagePlane)
        nativeBacking.isHidden=true;hasNativeBacking=false
    }

    /// Pin a clean native source below the current photo. Never bake a transitional composite into a new photo.
    func pinNativeBackdrop(_ native:ModeSurfacePicture,in host:NSView,below:NSView,holes:[CGRect]) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        defer {CATransaction.commit()}
        generation &+= 1;fading=false;blocksSourceInput=true
        frame=host.bounds;autoresizingMask=[.width,.height]
        preserveComposition();retainGlassFootprints(native)
        nativeBacking=ModeFlight.Plane(frame:bounds);nativeBacking.wantsLayer=true
        nativeBacking.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor
        for tile in native.tiles {
            let part=CALayer();part.frame=tile.rect;part.contents=tile.image;part.contentsScale=native.scale
            nativeBacking.layer?.addSublayer(part)
        }
        addSubview(nativeBacking,positioned:.above,relativeTo:glassPlane)
        nativeBacking.isHidden=false;hasNativeBacking=true
        if picture == nil {picture=native;imagePlane.layer?.opacity=0}
        updateHoles(holes);host.addSubview(self,positioned:.below,relativeTo:below)
        layer?.zPosition=ModePlaneOrder.source;isHidden=false
    }

    func updateHoles(_ holes:[CGRect]) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        defer {CATransaction.commit()}
        if ModeFlight.orreryEnabled {
            let exterior=CGPath(rect:bounds,transform:nil)
            var cutouts:CGPath=CGMutablePath()
            // Sidebar exclusion belongs to each Normie photo, never to an Organic photo.
            for rect in photoGlassRects {
                let shape = rect.width<=80 ? CGPath(ellipseIn:rect,transform:nil):CGPath(roundedRect:rect,cornerWidth:min(20,rect.height/2),cornerHeight:min(20,rect.height/2),transform:nil)
                cutouts=cutouts.union(shape,using:.winding)
            }
            for hole in holes {
                cutouts=cutouts.union(CGPath(ellipseIn:hole,transform:nil),using:.winding)
            }
            maskShape.frame=bounds;maskShape.path=exterior.subtracting(cutouts,using:.winding);maskShape.fillRule = .evenOdd
        } else {
            let path=CGMutablePath();path.addRect(bounds)
            if let openRect {path.addRect(openRect)}
            for hole in holes where openRect?.contains(hole) != true {path.addEllipse(in:hole)}
            maskShape.frame=bounds;maskShape.path=path;maskShape.fillRule = .evenOdd
        }
        let materialHoles=ModeFlight.orreryEnabled && !photoGlassRects.isEmpty
        layer?.mask = holes.isEmpty && openRect == nil && !materialHoles ? nil : maskShape
    }

    /// Reverse the existing source fade on the compositor before native admission runs.
    func restoreSource(_ image: ModeSurfacePicture,in host: NSView,below: NSView,holes: [CGRect],duration: Double = 0.14,completion: (@MainActor () -> Void)? = nil) {
        let opacity:Float
        if ModeFlight.orreryEnabled {
            CATransaction.begin();CATransaction.setDisableActions(true)
            preserveComposition();retainGlassFootprints(image)
            imagePlane=ModeFlight.Plane(frame:bounds);imagePlane.wantsLayer=true;imageLayer=CALayer()
            imageLayer.isGeometryFlipped=ModeFlight.orreryEnabled
        imagePlane.layer?.addSublayer(imageLayer);addSubview(imagePlane)
            generation &+= 1;fading=false;picture=image;staged=image;blocksSourceInput=true
            frame=host.bounds;install(image);updateHoles(holes)
            host.addSubview(self,positioned:.below,relativeTo:below);layer?.zPosition=ModePlaneOrder.source
            imagePlane.layer?.opacity=1;isHidden=false;opacity=0
            CATransaction.commit()
        } else {
            opacity=picture === image ? (imagePlane.layer?.presentation()?.opacity ?? imagePlane.layer?.opacity ?? 1):0
            hold(image,in:host,below:below,holes:holes)
        }
        let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=opacity;fade.toValue=1
        fade.duration=duration;fade.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        fade.beginTime=imagePlane.layer?.convertTime(CACurrentMediaTime(),from:nil) ?? CACurrentMediaTime()
        fade.fillMode = .both;fade.isRemovedOnCompletion=false;ModeSignposts.frameRange(fade)
        let lease=generation
        CATransaction.begin();CATransaction.setDisableActions(true)
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self,self.generation == lease else {return}
            completion?()
        }
        if window?.isVisible == true {CATransaction.setCompletionBlock {DispatchQueue.main.async {complete()}}}
        if ModeFlight.orreryEnabled {fade.beginTime=CACurrentMediaTime()+commitInterval}
        imagePlane.layer?.add(fade,forKey:"mode.source.turn")
        if ModeFlight.orreryEnabled {glassPlane.layer?.opacity=1;glassPlane.layer?.add(fade,forKey:"mode.photo.material")}
        CATransaction.commit()
        if ModeFlight.orreryEnabled {CATransaction.flush()}
        if window?.isVisible != true {DispatchQueue.main.asyncAfter(deadline:.now()+duration+max(0,fade.beginTime-CACurrentMediaTime())) {complete()}}
    }

    #if M11_MODE_SELFTEST
    var verificationFlattenPending:Bool {flattenPending}
    var verificationCompositionsApplied:Int {compositionsApplied}
    var verificationMaterialLayer:CALayer {glassPlane.layer!}
    var verificationImageLayer:CALayer? {imagePlane.layer}
    var verificationNativeBackdropView:NSView {nativeBacking}
    var verificationCompositionStats:(groups:Int,layers:Int,depth:Int,bytes:Int) {
        var layers=0,depth=0,bytes=0,images=Set<ObjectIdentifier>()
        func image(_ value:Any?) {if let value,CFGetTypeID(value as CFTypeRef) == CGImage.typeID {let image=value as! CGImage;if images.insert(ObjectIdentifier(image)).inserted {bytes+=image.bytesPerRow*image.height}}}
        func layer(_ node:CALayer,_ level:Int) {layers+=1;depth=max(depth,level);image(node.contents);for child in node.sublayers ?? [] {layer(child,level+1)}}
        func view(_ node:NSView,_ level:Int) {
            if let own=node.layer {layers+=1;depth=max(depth,level);image(own.contents)
                let children=Set(node.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
                for child in own.sublayers ?? [] where !children.contains(ObjectIdentifier(child)) {layer(child,level+1)}
            }
            for child in node.subviews {view(child,level+1)}
        }
        view(self,0)
        for picture in [picture,staged].compactMap({$0}) {for tile in picture.tiles {image(tile.image)}}
        return (compositionGroups.count,layers,depth,bytes)
    }
    var verificationPinnedNative:Bool {hasNativeBacking}
    var verificationContentFadeLayer:CALayer? {(hasNativeBacking || !compositionGroups.isEmpty) ? layer:imagePlane.layer}
    var verificationTurnOpacity: Float {imagePlane.layer?.presentation()?.opacity ?? imagePlane.layer?.opacity ?? 0}
    var verificationHasPhotoSidebarCutout:Bool {
        normiePhotoLayers.allObjects.allSatisfy { layer in
            guard let mask=layer.mask as? CAShapeLayer else {return false}
            return mask.path?.contains(CGPoint(x:20,y:100),using:.evenOdd) == false
        }
    }
    var verificationHoles: CGPath? {(layer?.mask as? CAShapeLayer)?.path}
    var verificationTurnCommitted: Bool {
        guard picture != nil,!isHidden,let fade=imagePlane.layer?.animation(forKey:"mode.source.turn") as? CABasicAnimation else {return false}
        return (fade.toValue as? NSNumber)?.doubleValue == 1 && abs(fade.duration-0.14)<1e-6 && fade.beginTime>0
    }
    #endif

    /// Native pixels and their photograph use the exact same committed opacity interval.
    func bindNativeCrossfade(_ native:NSView,revealing:Bool) {
        let candidates=[layer,imagePlane.layer].compactMap {$0}
        var clock:CABasicAnimation?,owner:CALayer?
        for key in ["mode.source.handoff","mode.source.turn"] {
            for candidate in candidates {
                if let value=candidate.animation(forKey:key) as? CABasicAnimation {clock=value;owner=candidate;break}
            }
            if clock != nil {break}
        }
        guard let clock,let owner else {return}
        ModePhotoSnapshot.fadeNativeSource(native,begin:owner.convertTime(clock.beginTime,to:nil),duration:clock.duration,to:revealing ? 1:0)
    }
    func revealDestination(duration: Double = 0.22, completion: @escaping @MainActor () -> Void) {
        guard picture != nil else { completion(); return }
        generation &+= 1; let lease = generation; fading = true; blocksSourceInput = false
        let probe=ModeSignposts.current
        probe?.record("ModeSourceFadeScheduled",detail:Self.carriesGlass ? "carry":"resident")
        let fade = CABasicAnimation(keyPath: "opacity");ModeSignposts.frameRange(fade)
        let fadeLayer=(hasNativeBacking || !compositionGroups.isEmpty) ? layer:imagePlane.layer
        fade.fromValue = fadeLayer?.presentation()?.opacity ?? fadeLayer?.opacity ?? 1; fade.toValue = 0
        if ModeFlight.orreryEnabled,fadeLayer === layer {
            imagePlane.layer?.opacity=imagePlane.layer?.presentation()?.opacity ?? imagePlane.layer?.opacity ?? 1
        }
        imagePlane.layer?.removeAnimation(forKey:"mode.source.turn")
        fadeStarted=CACurrentMediaTime();fadeDuration=duration
        for material in carriedGlass {
            if let parent=material.view.superview,parent !== glassPlane {material.parent=parent;material.frame=material.view.frame}
            else if material.view.frame != material.source {material.frame=material.view.frame}
            if let parent=material.parent, let root=material.root {
                var top=parent
                while let p=top.superview,p !== root {top=p}
                material.adoptsDestination = top !== material.sourcePlane && top.superview === root
                if material.adoptsDestination {material.destination=parent.convert(material.frame,to:self)}
            }
            glassPlane.addSubview(material.view);material.view.frame=material.source
        }
        fade.duration = duration; fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let retire: @MainActor ()->Void = { [weak self] in
            guard let self,self.generation == lease else{return}
            probe?.record("ModeSourceRetired")
            self.clear();completion()
        }
        if window?.isVisible == true {
            // A dispatch deadline starts before CA has committed. Retire on actual animation completion instead.
            CATransaction.setCompletionBlock {DispatchQueue.main.async {retire()}}
        }
        if ModeFlight.orreryEnabled {
            fade.beginTime=CACurrentMediaTime()+commitInterval;fade.fillMode = .both;fade.isRemovedOnCompletion=false
        }
        fadeLayer?.opacity = 0; fadeLayer?.add(fade, forKey: "mode.source.handoff")
        if ModeFlight.orreryEnabled,fadeLayer !== layer {glassPlane.layer?.opacity=0;glassPlane.layer?.add(fade,forKey:"mode.photo.material")}
        CATransaction.commit()
        if ModeFlight.orreryEnabled {CATransaction.flush()}
        if window?.isVisible != true {DispatchQueue.main.asyncAfter(deadline:.now()+duration+max(0,fade.beginTime-CACurrentMediaTime())) {retire()}}
    }

    /// Under the picture's tiles, for cards that just left for a column and took their glass along. See `leavesNormieForColumn`.
    func addCardPlates(_ rects:[CGRect]) {
        guard !rects.isEmpty else {return}
        let scale=window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for rect in rects {
            let plate=CALayer()
            plate.frame=rect; plate.cornerRadius=18; plate.cornerCurve = .continuous
            plate.backgroundColor=NativeDisplayOptions.plate(alpha:0.1).cgColor
            plate.borderColor=NSColor.black.withAlphaComponent(0.45).cgColor; plate.borderWidth=1/scale
            if ModeFlight.orreryEnabled {ModePhotoSnapshot.cacheDecoration(plate,scale:scale)}
            imageLayer.insertSublayer(plate,at:0)
        }
        CATransaction.commit()
    }
    private let normiePhotoLayers=NSHashTable<CALayer>.weakObjects()
    private var photoMaterials:[NSGlassEffectView]=[]
    private final class PhotoMaterial {
        let replica:NSGlassEffectView,rect:CGRect
        weak var native:NSGlassEffectView?,root:NSView?
        init(_ replica:NSGlassEffectView,_ native:NSGlassEffectView,_ root:NSView?,_ rect:CGRect) {
            self.replica=replica;self.native=native;self.root=root;self.rect=rect
        }
    }
    private var materialSources:[PhotoMaterial]=[]
    private func updateMaterialOwners() {
        for item in materialSources {
            guard let native=item.native else {item.replica.isHidden=false;continue}
            var visible=true,node:NSView?=native
            while let current=node {
                if current.isHidden || current.alphaValue<=0 || (current.layer?.presentation()?.opacity ?? current.layer?.opacity ?? 1)<=0 {visible=false;break}
                node=current.superview
            }
            if let root=item.root {
                var nativeRect=native.convert(native.bounds,to:root)
                if !root.isFlipped {nativeRect.origin.y=root.bounds.height-nativeRect.maxY}
                visible = visible && native.isDescendant(of:root) && MotionStep.edge(nativeRect,item.rect)<0.5
            } else {visible=false}
            if item.replica.isHidden != visible {item.replica.isHidden=visible}
        }
    }
    private func installMaterials(_ picture:ModeSurfacePicture) {
        glassPlane.layer?.removeAllAnimations();glassPlane.layer?.opacity=1
        for old in photoMaterials {old.removeFromSuperview()};photoMaterials=[];materialSources=[]
        guard ModeFlight.orreryEnabled else {return}
        for material in picture.glasses where material.rect.width>120 && material.rect.height>=20 && material.rect.height<200 {
            guard let native=material.view else {continue}
            let glass=NSGlassEffectView(frame:material.rect)
            glass.style=native.style;glass.tintColor=native.tintColor;glass.cornerRadius=native.cornerRadius
            glass.appearance=native.effectiveAppearance;glass.isHidden=false
            glassPlane.addSubview(glass);photoMaterials.append(glass)
            materialSources.append(PhotoMaterial(glass,native,picture.root,material.rect))
        }
        updateMaterialOwners()
    }
    private func install(_ picture:ModeSurfacePicture) {
        imagePlane.frame=bounds;glassPlane.frame=bounds;imageLayer.frame=bounds;imageLayer.contents=nil
        if ModeFlight.orreryEnabled {
            installMaterials(picture)
            if let sidebar=picture.sidebarRect {
                let mask=CAShapeLayer();let path=CGMutablePath();path.addRect(bounds);path.addRect(sidebar)
                mask.path=path;mask.fillRule = .evenOdd;imageLayer.mask=mask
                normiePhotoLayers.add(imageLayer)
            } else {imageLayer.mask=nil}
        }
        imageLayer.sublayers?.forEach{$0.removeFromSuperlayer()}
        for tile in picture.tiles {let node=CALayer();node.frame=tile.rect;node.contents=tile.image;node.contentsGravity = .resize;node.contentsScale=picture.scale;imageLayer.addSublayer(node)}
    }

    /// The real source material stays opaque on the first frame. A shared material moves to its actual admitted
    /// destination; a source-only material fades away. No captured opaque matte substitutes for either.
    func advance(at time:Double) {
        if ModeFlight.orreryEnabled {updateMaterialOwners()}
        guard fading else{return}
        let fraction=min(1,max(0,(time-fadeStarted)/max(0.001,fadeDuration)))
        let k=CGFloat(fraction*fraction*(3-2*fraction))
        for material in carriedGlass {
            if material.view.superview !== glassPlane {glassPlane.addSubview(material.view)}
            if let target=material.destination {
                let a=material.source
                material.view.frame=CGRect(x:a.minX+(target.minX-a.minX)*k,y:a.minY+(target.minY-a.minY)*k,width:a.width+(target.width-a.width)*k,height:a.height+(target.height-a.height)*k)
            } else {material.view.frame=material.source}
            material.view.alphaValue=material.originalAlpha*(material.adoptsDestination ? 1:1-k)
        }
    }
    private func restoreGlass() {
        for material in carriedGlass {
            material.content?.alphaValue=material.contentAlpha
            guard material.view.superview === glassPlane else{continue}
            if let parent=material.parent {let sibling=parent.subviews.indices.contains(material.index) ? parent.subviews[material.index]:nil;parent.addSubview(material.view,positioned:.below,relativeTo:sibling);material.view.frame=material.frame;material.view.alphaValue=material.originalAlpha}
            else {material.view.removeFromSuperview()}
        }
        carriedGlass=[]
    }

    func clear() {
        resetComposition();photoGlassRects=[]
        for material in photoMaterials {material.removeFromSuperview()};photoMaterials=[];materialSources=[]
        nativeBacking.layer?.sublayers?.forEach {$0.removeFromSuperlayer()}
        nativeBacking.isHidden=true;hasNativeBacking=false
        generation &+= 1; fading = false; picture = nil; staged = nil; blocksSourceInput = false
        restoreGlass()
        layer?.removeAllAnimations();imagePlane.layer?.removeAllAnimations(); imageLayer.contents = nil;imageLayer.sublayers=nil; layer?.mask = nil; openRect = nil
        isHidden = true; removeFromSuperview()
    }
}

/// Generation is checked both when work is queued and when it executes. A reversal cannot admit an old target.
@MainActor final class ModeAdmissionGate {
    private(set) var generation: UInt64 = 0
    private(set) var waitingForFrame = false
    private var action: (() -> Void)?
    private var task: DispatchWorkItem?
    func arm(_ action: @escaping () -> Void) {
        cancel(); waitingForFrame = true; self.action = action
    }
    func presentedFrame(interval: Double) {
        guard waitingForFrame else { return }; waitingForFrame = false
        let lease = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == lease else { return }
            let action = self.action; self.action = nil; self.task = nil; action?()
        }
        task = work
        // The production link has just sampled a first pose. Let that transaction reach its display deadline first.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, interval), execute: work)
    }
    func cancel() { generation &+= 1; task?.cancel(); task = nil; action = nil; waitingForFrame = false }
    func performNow() {
        let work = action; cancel(); work?()
    }
}

@MainActor enum ModeSurfaceCapture {
    /// The frame view includes the toolbar which will leave during admission. Crop to the full-size content view.
    static func capture(_ content: NSView, scale: CGFloat) -> CGImage {
        let builder=ModeSurfaceBuilder(content,scale:scale)
        while !builder.ready {builder.step()}
        return builder.finish()!.flattened()
    }
}

@MainActor final class ModeSurfacePicture {
    struct Tile {let rect:CGRect;let image:CGImage}
    struct Glass {weak var view:NSGlassEffectView?;let rect:CGRect;weak var sourcePlane:NSView?=nil}
    let tiles:[Tile], glasses:[Glass], size:CGSize, scale:CGFloat
    weak var root:NSView?
    var sidebarRect:CGRect?
    var modeName:String?
    init(tiles:[Tile],glasses:[Glass],size:CGSize,scale:CGFloat){self.tiles=tiles;self.glasses=glasses;self.size=size;self.scale=scale}
    convenience init(image:CGImage){self.init(tiles:[.init(rect:CGRect(x:0,y:0,width:image.width,height:image.height),image:image)],glasses:[],size:CGSize(width:image.width,height:image.height),scale:1)}
}

/// The same own-draw boundary used by M10-C: no ancestor cacheDisplay canvas and no rasterized glass.
/// Each small tile is independent; production bounds each main-loop batch.
@MainActor final class ModeSurfaceBuilder {
    #if M11_MODE_SELFTEST
    static var verificationLegacyVisibility=false
    var verificationViews:[NSView] {views.map(\.view)}
    #endif
    /// Each tile is the existing bounded draw unit; cancellation is checked before every slice.
    func completeInSlices(valid:@escaping @MainActor ()->Bool,onSlice:((Double)->Void)?=nil,completion:@escaping @MainActor (ModeSurfacePicture?)->Void) {
        guard valid() else {return}
        if ready {completion(finish());return}
        if !ModeFlight.orreryEnabled {
            let began=CACurrentMediaTime();step();onSlice?((CACurrentMediaTime()-began)*1000)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.002) { [self] in completeInSlices(valid:valid,onSlice:onSlice,completion:completion) }
            return
        }
        let began=CACurrentMediaTime()
        // Bounded work, not a synchronous whole-window loop or one fixed timer delay per tile.
        for _ in 0..<4 {
            step()
            if ready || CACurrentMediaTime()-began>=0.002 {break}
        }
        onSlice?((CACurrentMediaTime()-began)*1000)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.0001) { [self] in completeInSlices(valid:valid,onSlice:onSlice,completion:completion) }
    }
    private let root:NSView, source:NSView, scale:CGFloat
    private let usePresentation:Bool
    private let opaqueBody:Bool
    private let photoInk:Bool
    private let colorSpaceOverride:CGColorSpace?
    private let normalizeRootOpacity:Bool
    private struct AlphaMask {let image:CGImage,rect:CGRect}
    private var maskImages:[ObjectIdentifier:CGImage]=[:]
    private struct PaintView {
        let view:NSView;let detachedRoot:NSView?;let rect:CGRect?;let clip:CGRect?
        var frozenTransform:CGAffineTransform?=nil
        var frozenOpacity:CGFloat?=nil
        var frozenClips:[CGRect]?=nil
        var frozenMasks:[AlphaMask]=[]
    }
    private var views:[PaintView], glass:[ModeSurfacePicture.Glass]
    private var indexStack:[PaintView]=[]
    private var indexing=false
    private let excludedViews:Set<ObjectIdentifier>
    private let rects:[CGRect]
    private var tiles:[ModeSurfacePicture.Tile]=[]
    private(set) var lastStepSeconds=0.0015
    var ready:Bool {!indexing && tiles.count == rects.count}
    init(_ root:NSView,scale:CGFloat,includeWindowFrame:Bool=true,presentation:Bool=false,excluding:[NSView]=[],detached:[(view:NSView,rect:CGRect,clip:CGRect)]=[],normalizeRootOpacity:Bool=false,opaqueBody:Bool=false,photoInk:Bool=false,detachedOpacityBoundary:NSView?=nil,colorSpace:CGColorSpace?=nil) {
        self.root=root;self.scale=scale;self.opaqueBody=opaqueBody;self.photoInk=photoInk;colorSpaceOverride=colorSpace;usePresentation=presentation;self.normalizeRootOpacity=normalizeRootOpacity
        excludedViews=Set(excluding.map(ObjectIdentifier.init))
        source=includeWindowFrame ? root.window?.contentView?.superview ?? root:root
        let captureSource=source
        #if M11_MODE_SELFTEST
        let legacy=Self.verificationLegacyVisibility
        #else
        let legacy=false
        #endif
        func walk(_ v:NSView)->[NSView] {
            guard !excluding.contains(where:{$0 === v}), (v === captureSource && !includeWindowFrame) || (!v.isHidden && v.alphaValue>0 && (presentation ? (v.layer?.presentation()?.opacity ?? v.layer?.opacity):v.layer?.opacity) != 0 && (legacy || v.layer?.isHidden != true)) else{return []}
            // A column that has no rect yet is parked behind a fade mask of no size: mounted, not on screen.
            if !legacy,let mask=v.layer?.mask,mask.bounds.isEmpty {return []}
            // The system's caret draws a solid bar here whether or not it's blinking on screen.
            if !legacy,v is NSTextInsertionIndicator {return []}
            if let glass=v as? NSGlassEffectView {return [v]+(glass.contentView.map(walk) ?? [])}
            return [v]+v.subviews.flatMap(walk)
        }
        let live=opaqueBody ? []:walk(source)
        views=live.map{PaintView(view:$0,detachedRoot:nil,rect:nil,clip:nil)}+(opaqueBody ? []:detached.flatMap { entry in
            walk(entry.view).map{PaintView(view:$0,detachedRoot:entry.view,rect:entry.rect,clip:entry.clip)}
        })
        glass=live.compactMap { v in
            guard let g=v as? NSGlassEffectView,g.isDescendant(of:root) else{return nil}
            var top:NSView=g
            while let p=top.superview,p !== root {top=p}
            return .init(view:g,rect:g.convert(g.bounds,to:root),sourcePlane:top)
        }
        var chunks:[CGRect]=[]
        for y in stride(from:CGFloat(0),to:root.bounds.height,by:96) {
            for x in stride(from:CGFloat(0),to:root.bounds.width,by:256) {
                chunks.append(CGRect(x:x,y:y,width:min(256,root.bounds.width-x),height:min(96,root.bounds.height-y)))
            }
        }
        rects=chunks
        if opaqueBody {
            indexStack=([PaintView(view:source,detachedRoot:nil,rect:nil,clip:nil)]+detached.map {PaintView(view:$0.view,detachedRoot:$0.view,rect:$0.rect,clip:$0.clip)}).reversed()
            indexing=true;return
        }
        if ModeFlight.orreryEnabled {
            for i in views.indices {
                let entry=views[i],v=entry.view
                func point(_ p:CGPoint)->CGPoint {
                    if let detached=entry.detachedRoot,let destination=entry.rect {
                        let q=v.convert(p,to:detached)
                        if detachedOpacityBoundary != nil {
                            let y=detached.isFlipped == root.isFlipped ? q.y:detached.bounds.minY+detached.bounds.maxY-q.y
                            return CGPoint(x:q.x-detached.bounds.minX+destination.minX,y:y-detached.bounds.minY+destination.minY)
                        }
                        return CGPoint(x:q.x+destination.minX,y:q.y+destination.minY)
                    }
                    let model=v.convert(v.bounds,to:root),q=v.convert(p,to:root)
                    guard presentation else {return q}
                    let shown=M10SidebarExposure.presentedRect(v,in:root)
                    return CGPoint(x:shown.minX+(q.x-model.minX)*shown.width/max(0.001,model.width),y:shown.minY+(q.y-model.minY)*shown.height/max(0.001,model.height))
                }
                let o=point(.zero),x=point(CGPoint(x:1,y:0)),y=point(CGPoint(x:0,y:1))
                views[i].frozenTransform=CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y)
                var alpha=normalizeRootOpacity && v === source ? 1:(presentation ? CGFloat(v.layer?.presentation()?.opacity ?? Float(v.alphaValue)):v.alphaValue),parent=v.superview
                while let p=parent,p !== (entry.detachedRoot == nil ? source.superview:(detachedOpacityBoundary ?? source.superview)) {
                    if !(normalizeRootOpacity && p === source) {alpha *= presentation ? CGFloat(p.layer?.presentation()?.opacity ?? Float(p.alphaValue)):p.alphaValue}
                    parent=p.superview
                }
                views[i].frozenOpacity=alpha
                if let detached=entry.detachedRoot,let destination=entry.rect,let boundary=detachedOpacityBoundary {
                    var clips:[CGRect]=[],ancestor=v.superview
                    while let p=ancestor,p !== boundary {
                        if p is NSClipView || p.layer?.masksToBounds == true {
                            var rect=p.convert(p.bounds,to:detached)
                            if detached.isFlipped != root.isFlipped {rect.origin.y=detached.bounds.minY+detached.bounds.maxY-rect.maxY}
                            clips.append(rect.offsetBy(dx:destination.minX-detached.bounds.minX,dy:destination.minY-detached.bounds.minY))
                        }
                        ancestor=p.superview
                    }
                    views[i].frozenClips=clips
                }
                if opaqueBody {
                    var clips:[CGRect]=[],ancestor=v.superview
                    while let parent=ancestor,parent !== source.superview {
                        if parent is NSClipView || parent.layer?.masksToBounds == true {clips.append(parent.convert(parent.bounds,to:root))}
                        ancestor=parent.superview
                    }
                    views[i].frozenClips=clips
                }
            }
        }
    }
    private func indexSlice() {
        let began=CACurrentMediaTime()
        while let original=indexStack.popLast() {
            let v=original.view
            guard !excludedViews.contains(ObjectIdentifier(v)),v === source || (!v.isHidden && v.alphaValue>0 && v.layer?.opacity != 0 && v.layer?.isHidden != true),!(v is NSTextInsertionIndicator) else {continue}
            if let mask=v.layer?.mask,mask.bounds.isEmpty {continue}
            var entry=original
            func point(_ p:CGPoint)->CGPoint {
                if let detached=entry.detachedRoot,let destination=entry.rect {let q=v.convert(p,to:detached);return CGPoint(x:q.x+destination.minX,y:q.y+destination.minY)}
                var result=v.convert(p,to:root),ancestor:NSView?=v
                while let node=ancestor,node !== source.superview {
                    if node is NativeTranscriptTable,let shift=node.layer?.value(forKeyPath:"transform.translation.y") as? NSNumber,abs(shift.doubleValue)>0.0001 {
                        let origin=node.convert(CGPoint.zero,to:root),translated=node.convert(CGPoint(x:0,y:shift.doubleValue),to:root)
                        result.x+=translated.x-origin.x;result.y+=translated.y-origin.y
                    }
                    ancestor=node.superview
                }
                return result
            }
            let o=point(.zero),x=point(CGPoint(x:1,y:0)),y=point(CGPoint(x:0,y:1))
            entry.frozenTransform=CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y)
            var alpha=normalizeRootOpacity && v === source ? 1:v.alphaValue,parent=v.superview
            var clips:[CGRect]=[]
            while let ancestor=parent,ancestor !== source.superview {
                if !(normalizeRootOpacity && ancestor === source) {alpha *= ancestor.alphaValue}
                if ancestor is NSClipView || ancestor.layer?.masksToBounds == true {clips.append(ancestor.convert(ancestor.bounds,to:root))}
                parent=ancestor.superview
            }
            entry.frozenOpacity=alpha;entry.frozenClips=clips
            // Own-draw capture bypasses the ancestor CA compositor. Preserve its native gradient alpha,
            // including the transcript fade below a header, in the same immutable picture epoch.
            var ancestor:NSView?=v
            while let owner=ancestor,owner !== source.superview {
                if let mask=owner.layer?.mask as? CAGradientLayer,!mask.bounds.isEmpty {
                    let key=ObjectIdentifier(mask)
                    let image:CGImage?
                    if let cached=maskImages[key] {image=cached}
                    else {
                        let vertical=mask.type == .axial && mask.startPoint.x == mask.endPoint.x
                        let width=vertical ? 1:max(1,Int(ceil(mask.bounds.width*scale)))
                        let height=max(1,Int(ceil(mask.bounds.height*scale)))
                        let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.scaleBy(x:CGFloat(width)/mask.bounds.width,y:CGFloat(height)/mask.bounds.height)
                        context.translateBy(x:-mask.bounds.minX,y:-mask.bounds.minY)
                        mask.render(in:context);image=context.makeImage();maskImages[key]=image
                    }
                    if let image {entry.frozenMasks.append(AlphaMask(image:image,rect:owner.convert(mask.frame,to:root)))}
                }
                ancestor=owner.superview
            }
            views.append(entry)
            if let material=v as? NSGlassEffectView,material.isDescendant(of:root) {
                var top:NSView=material;while let parent=top.superview,parent !== root {top=parent}
                glass.append(.init(view:material,rect:material.convert(material.bounds,to:root),sourcePlane:top))
            }
            let children=(v as? NSGlassEffectView).map {$0.contentView.map {[$0]} ?? []} ?? v.subviews
            for child in children.reversed() {indexStack.append(PaintView(view:child,detachedRoot:entry.detachedRoot,rect:entry.rect,clip:entry.clip))}
            if CACurrentMediaTime()-began>=0.0015 {break}
        }
        indexing = !indexStack.isEmpty
        lastStepSeconds=CACurrentMediaTime()-began
    }
    func step() {
        guard !ready else{return}
        if indexing {indexSlice();return}
        let rect=rects[tiles.count],started=CACurrentMediaTime()
        let image=ModeSignposts.measure("PrewarmSourceTile",detail:"\(tiles.count) \(rect)") {paint(rect)}
        tiles.append(.init(rect:rect,image:image));lastStepSeconds=CACurrentMediaTime()-started
    }
    private func photoRect(_ rect:CGRect)->CGRect {
        ModeFlight.orreryEnabled && !root.isFlipped ? CGRect(x:rect.minX,y:root.bounds.height-rect.maxY,width:rect.width,height:rect.height):rect
    }
    func finish()->ModeSurfacePicture? {
        guard ready else{return nil}
        let materials=glass.map {ModeSurfacePicture.Glass(view:$0.view,rect:photoRect($0.rect),sourcePlane:$0.sourcePlane)}
        let picture=ModeSurfacePicture(tiles:tiles,glasses:materials,size:root.bounds.size,scale:scale);picture.root=root;return picture
    }
    /// A glass container's merged shape lives in private SDF layers. With no backdrop render(in:) paints them solid white:
    /// the white band around the Dock's bars at the start of a mode switch, and the header's plates (user 10-30, 41.15 s).
    static func glassInternal(_ layer:CALayer)->Bool {
        String(describing:type(of:layer)) == "SDFLayer" || (layer.sublayers ?? []).contains(where:glassInternal)
    }
    private func paint(_ rect:CGRect)->CGImage {
        let w=max(1,Int(ceil(rect.width*scale))),h=max(1,Int(ceil(rect.height*scale)))
        let space=colorSpaceOverride ?? root.window?.colorSpace?.cgColorSpace ?? (opaqueBody ? NSColorSpace.genericRGB.cgColorSpace!:CGColorSpaceCreateDeviceRGB())
        let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        if opaqueBody {c.setFillColor(NativePalette.canvas.withAlphaComponent(1).cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h))}
        c.translateBy(x:0,y:CGFloat(h));c.scaleBy(x:scale,y:-scale);c.translateBy(x:-rect.minX,y:-rect.minY);c.clip(to:rect)
        // Without its glass, a rail card needs its plate here too: it lost its background in the picture (board 10-31).
        NativeTranscriptCard.drawsMotionPlate = !photoInk
        NativeTranscriptCard.drawsPhotoInk=photoInk
        defer {NativeTranscriptCard.drawsMotionPlate=false;NativeTranscriptCard.drawsPhotoInk=false}
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            for entry in views where !(entry.view is NSGlassEffectView) && (entry.view === root || !entry.view.isHidden) {
                let v=entry.view
                // Hidden ancestors OUTSIDE the capture root do not suppress a prepared target sidebar.
                @MainActor func nativeRect(_ rect:CGRect)->CGRect {
                    if let transform=entry.frozenTransform {return rect.applying(transform)}
                    if let detached=entry.detachedRoot,let destination=entry.rect {return v.convert(rect,to:detached).offsetBy(dx:destination.minX,dy:destination.minY)}
                    if usePresentation {
                        let bounds=v.convert(v.bounds,to:root),mapped=v.convert(rect,to:root),shown=M10SidebarExposure.presentedRect(v,in:root)
                        return CGRect(x:shown.minX+(mapped.minX-bounds.minX)*shown.width/max(0.001,bounds.width),
                                      y:shown.minY+(mapped.minY-bounds.minY)*shown.height/max(0.001,bounds.height),
                                      width:mapped.width*shown.width/max(0.001,bounds.width),height:mapped.height*shown.height/max(0.001,bounds.height))
                    }
                    return v.convert(rect,to:root)
                }
                @MainActor func mapped(_ rect:CGRect)->CGRect {photoRect(nativeRect(rect))}
                let visible=mapped(v.bounds)
                guard visible.intersects(rect) else{continue}
                c.saveGState()
                var opacity=usePresentation ? CGFloat(v.layer?.presentation()?.opacity ?? Float(v.alphaValue)):v.alphaValue,opacityParent=v.superview
                while let ancestor=opacityParent,ancestor !== source.superview {opacity *= usePresentation ? CGFloat(ancestor.layer?.presentation()?.opacity ?? Float(ancestor.alphaValue)):ancestor.alphaValue;opacityParent=ancestor.superview}
                opacity=entry.frozenOpacity ?? opacity
                c.setAlpha(opacity)
                for mask in entry.frozenMasks {c.clip(to:photoRect(mask.rect),mask:mask.image)}
                if let clip=entry.clip {c.clip(to:photoRect(clip))}
                var parent=entry.frozenClips == nil ? v.superview:nil
                for clip in entry.frozenClips ?? [] {c.clip(to:photoRect(clip))}
                while let ancestor=parent,ancestor !== source.superview {
                    if ancestor is NSClipView || ancestor.layer?.masksToBounds == true {c.clip(to:photoRect(ancestor.convert(ancestor.bounds,to:root)))}
                    if usePresentation,let shape=ancestor.layer?.mask as? CAShapeLayer,let path=shape.path {
                        let box=M10SidebarExposure.presentedRect(ancestor,in:root)
                        var transform=CGAffineTransform(translationX:box.minX-ancestor.bounds.minX,y:box.minY-ancestor.bounds.minY)
                        if let mappedPath=path.copy(using:&transform) {c.addPath(mappedPath);c.clip(using:shape.fillRule == .evenOdd ? .evenOdd:.winding)}
                    }
                    parent=ancestor.superview
                }
                // Ancestors own the canvas, not a glass surface's blank pixels. Keep the original live glass.
                let hasGlass=glass.contains { $0.view?.isDescendant(of:v) == true }
                @MainActor func mappedPoint(_ point:CGPoint)->CGPoint {let r=mapped(CGRect(origin:point,size:.zero));return r.origin}
                let o=mappedPoint(.zero),x=mappedPoint(CGPoint(x:1,y:0)),y=mappedPoint(CGPoint(x:0,y:1))
                c.concatenate(.init(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y))
                c.clip(to:v.bounds)
                @MainActor func clipGlass() {
                    if opaqueBody {return}
                    // Material footprints cut ancestor canvases, never ink inside any glass content.
                    if ModeFlight.orreryEnabled,glass.contains(where: {material in material.view.map {v.isDescendant(of:$0)} ?? false}) {return}
                    // Intersect individual complements; overlapping material rectangles never XOR-fill.
                    for g in glass {
                        let path=CGMutablePath();path.addRect(v.bounds);path.addRect(v.convert(g.rect,from:root))
                        c.addPath(path);c.clip(using:.evenOdd)
                    }
                }
                if let color=v.layer?.backgroundColor {
                    c.saveGState();if hasGlass {clipGlass()};c.setFillColor(color)
                    let corner=min(v.layer?.cornerRadius ?? 0,min(v.bounds.width,v.bounds.height)/2)
                    if corner>0 {c.addPath(CGPath(roundedRect:v.bounds,cornerWidth:corner,cornerHeight:corner,transform:nil));c.fillPath()} else {c.fill(v.bounds)}
                    c.restoreGState()
                }
                c.saveGState()
                let canvas=(v as? NormieView).map{$0.fill != nil || $0.canopy} ?? (v === source && source !== root)
                if canvas {clipGlass()}
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:v.isFlipped)
                let transform=CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y)
                v.draw(rect.applying(transform.inverted()).intersection(v.bounds))
                NSGraphicsContext.restoreGraphicsState();c.restoreGState()
                // Only scene-owned CA subtrees. NSView backing layers are drawn through their own draw above.
                let nativeLayers=Set(v.subviews.compactMap{$0.layer}.map(ObjectIdentifier.init))
                func nativeBacking(_ layer:CALayer)->Bool {layer.delegate is NSView || (layer.sublayers ?? []).contains(where:nativeBacking)}
                for l in v.layer?.sublayers ?? [] where !nativeLayers.contains(ObjectIdentifier(l)) && !nativeBacking(l) && !Self.glassInternal(l) && !l.isHidden && l.opacity>0 {
                    c.saveGState()
                    clipGlass()
                    c.translateBy(x:l.position.x,y:l.position.y);c.concatenate(l.affineTransform())
                    c.translateBy(x:-l.bounds.minX-l.anchorPoint.x*l.bounds.width,y:-l.bounds.minY-l.anchorPoint.y*l.bounds.height)
                    c.setAlpha(opacity*CGFloat(usePresentation ? (l.presentation()?.opacity ?? l.opacity):l.opacity));(usePresentation ? (l.presentation() ?? l):l).render(in:c);c.restoreGState()
                }
                c.restoreGState()
            }
        }
        return c.makeImage()!
    }
}

extension ModeSurfacePicture {
    func flattened()->CGImage {
        let c=CGContext(data:nil,width:max(1,Int(ceil(size.width*scale))),height:max(1,Int(ceil(size.height*scale))),bitsPerComponent:8,bytesPerRow:0,space:tiles.first?.image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x:scale,y:scale)
        for tile in tiles {c.draw(tile.image,in:CGRect(x:tile.rect.minX,y:size.height-tile.rect.maxY,width:tile.rect.width,height:tile.rect.height))}
        return c.makeImage()!
    }
}

@MainActor final class ModePreparationBatch {
    enum Kind {case geometry,source}
    let kind:Kind
    var key:ModePreparationKey
    let trace:ModeSignposts.Trace?
    var steps:[()->Bool]=[]
    var completed=0
    var finish:(()->Void)?
    init(key:ModePreparationKey,reason:String,kind:Kind = .source) {
        self.kind=kind;self.key=key;trace=ModeSignposts.enabled ? ModeSignposts.Trace():nil
        trace?.record("ModePrewarm",.begin,detail:reason)
    }
    func step()->Bool {
        guard completed<steps.count else{return true}
        let done=ModeSignposts.withTrace(trace) {ModeSignposts.measure("PrewarmSlice",detail:"step=\(completed)"){steps[completed]()}}
        if done {completed+=1}
        return completed==steps.count
    }
    func end(cancelled:Bool) {trace?.record("ModePrewarm",.end,detail:cancelled ? "invalidated":"ready")}
}

/// The same frame-paced capture pump handles material ink. No draw/layout is added to the key path.
@MainActor final class ModeContentMaterialJob {
    let source:NSView
    private let builder:ModeSurfaceBuilder
    private let kind:String,rect:CGRect,inkRect:CGRect,clip:CGRect
    private let style:NSGlassEffectView.Style,tint:NSColor?,radius:CGFloat,appearance:NSAppearance
    init(source:NSView,ink:NSView,glass:NSGlassEffectView,in root:NSView,scale:CGFloat,kind:String) {
        self.source=source;self.kind=kind
        rect=glass.convert(glass.bounds,to:root);inkRect=ink.convert(ink.bounds,to:root)
        var visible=rect.intersection(root.bounds),ancestor=source.superview
        while let view=ancestor,view !== root.superview {
            if view is NSClipView || view.layer?.masksToBounds == true {visible=visible.intersection(view.convert(view.bounds,to:root))}
            ancestor=view.superview
        }
        clip=visible;style=glass.style;tint=glass.tintColor;radius=glass.cornerRadius;appearance=glass.effectiveAppearance
        builder=ModeSurfaceBuilder(ink,scale:scale,includeWindowFrame:false,excluding:ink === source ? [glass]:[],normalizeRootOpacity:true,photoInk:true)
    }
    var ready:Bool {builder.ready}
    func step() {builder.step()}
    func raster()->ModeContentRaster? {
        guard let picture=builder.finish() else {return nil}
        return ModeContentRaster(tiles:picture.tiles.map {.init(rect:$0.rect,image:$0.image)},size:picture.size,scale:picture.scale)
    }
    func finish(ink:CGImage?)->ModeContentMaterial? {
        guard !clip.isNull,!clip.isEmpty,let ink else {return nil}
        return .init(kind:kind,rect:rect,inkRect:inkRect,clip:clip,ink:ink,style:style,tint:tint,radius:radius,appearance:appearance)
    }
}

/// A finite attachment to the outgoing body picture. Materials remain native; ink is immutable.
/// Callers freeze their own model/input before retaining surfaces and release at the handoff endpoint.
@MainActor final class ModeDepartureSurfaces {
    enum Plane {case behindMaterial,material,foreground}
    struct Surface {
        let view:NSView,plane:Plane
        init(_ view:NSView,plane:Plane = .foreground) {self.view=view;self.plane=plane}
    }
    @MainActor private final class PicturePlane:NSView {
        override var isFlipped:Bool {true}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
    }
    @MainActor final class Lease {
        let picture:NSView,started:Double,duration:Double
        let sourceViews:[NSView]
        let captureMS:Double
        private let hidden:[Bool],viewHidden:[Bool]
        private var expiry:DispatchWorkItem?
        private(set) var released=false
        var exclusions:[NSView] {released ? []:sourceViews+[picture]}
        fileprivate init(surfaces:[Surface],in host:NSView,at time:Double,duration:Double,spacing:CGFloat) {
            started=time;self.duration=duration
            let begin=CACurrentMediaTime(),scale=host.window?.backingScaleFactor ?? 2
            var seen=Set<ObjectIdentifier>()
            let shown=surfaces.filter {surface in
                let v=surface.view
                return seen.insert(ObjectIdentifier(v)).inserted && !v.isHiddenOrHasHiddenAncestor
                    && v.layer?.isHidden != true && v.alphaValue>0 && v.bounds.width>0 && v.bounds.height>0
            }
            // A registered ancestor already owns all of its descendants, including glass content ink.
            let roots=shown.filter {entry in !shown.contains {$0.view !== entry.view && entry.view.isDescendant(of:$0.view)}}
            sourceViews=roots.map(\.view);hidden=sourceViews.map {$0.layer?.isHidden ?? false};viewHidden=sourceViews.map(\.isHidden)
            // Orb canvases and shadow hosts span the scene, but their visible ink belongs to these materials.
            // Crop the attachment to small registered surfaces plus 32 pt for their shadows/satellites.
            let footprints=roots.filter {$0.view.bounds.width<host.bounds.width-1 || $0.view.bounds.height<host.bounds.height-1}
            let tight=footprints.reduce(CGRect.null) {$0.union($1.view.convert($1.view.bounds,to:host))}
            let bounds=(tight.isNull ? host.bounds:tight.insetBy(dx:-32,dy:-32)).intersection(host.bounds)
            let photo=PicturePlane(frame:bounds.isNull ? .zero:bounds);photo.wantsLayer=true;picture=photo
            photo.identifier = .init("mode.departure.picture")
            photo.setAccessibilityElement(false);photo.setAccessibilityHidden(true)
            let container=NSGlassEffectContainerView(frame:photo.bounds),content=PicturePlane(frame:photo.bounds)
            container.spacing=spacing;container.contentView=content;photo.addSubview(container)
            var glasses:Set<ObjectIdentifier>=[]
            @MainActor func material(_ v:NSView) {
                guard !v.isHidden,v.layer?.isHidden != true,v.alphaValue>0 else{return}
                if let glass=v as? NSGlassEffectView,glasses.insert(ObjectIdentifier(glass)).inserted {
                    let clone=NSGlassEffectView(frame:glass.convert(glass.bounds,to:host).offsetBy(dx:-photo.frame.minX,dy:-photo.frame.minY))
                    clone.identifier = .init("mode.departure."+(glass.identifier?.rawValue ?? "glass"))
                    if clone.style != glass.style {clone.style=glass.style}
                    clone.tintColor=glass.tintColor;clone.cornerRadius=glass.cornerRadius
                    if host.effectiveAppearance.name != glass.effectiveAppearance.name {clone.appearance=glass.effectiveAppearance}
                    content.addSubview(clone)
                    return
                }
                v.subviews.forEach(material)
            }
            roots.forEach {material($0.view)}
            // Use the same own-draw boundary as body photos. Never cacheDisplay or rasterize a glass backdrop.
            for plane in [Plane.behindMaterial,.material,.foreground] {
                let selected=roots.filter {$0.plane == plane}
                guard !selected.isEmpty,!photo.bounds.isEmpty else{continue}
                let inkRoot=PicturePlane(frame:photo.bounds)
                let entries=selected.map {entry in
                    (view:entry.view,rect:entry.view.convert(entry.view.bounds,to:host).offsetBy(dx:-photo.frame.minX,dy:-photo.frame.minY),clip:photo.bounds)
                }
                let builder=ModeSurfaceBuilder(inkRoot,scale:scale,includeWindowFrame:false,presentation:true,detached:entries,photoInk:true,detachedOpacityBoundary:host.window?.contentView?.superview,colorSpace:host.window?.colorSpace?.cgColorSpace)
                while !builder.ready {builder.step()}
                guard let ink=builder.finish()?.flattened() else{continue}
                let image=CALayer();image.frame=photo.bounds;image.contents=ink;image.contentsScale=scale;image.isGeometryFlipped=true
                let inkPlane=PicturePlane(frame:photo.bounds);inkPlane.wantsLayer=true;inkPlane.layer?.addSublayer(image)
                inkPlane.identifier = .init("mode.departure.ink."+String(describing:plane))
                inkPlane.layer?.name="mode.departure.sources:"+selected.compactMap {$0.view.identifier?.rawValue}.joined(separator:"|")
                if plane == .behindMaterial {photo.addSubview(inkPlane,positioned:.below,relativeTo:container)}
                else {photo.addSubview(inkPlane)}
            }
            captureMS=(CACurrentMediaTime()-begin)*1000
            CATransaction.begin();CATransaction.setDisableActions(true)
            host.addSubview(photo)
            // The material group, ink and shadow all receive this one finite source opacity.
            photo.layer?.allowsGroupOpacity=true
            let fade=CABasicAnimation(keyPath:"opacity");ModeSignposts.frameRange(fade)
            fade.fromValue=1;fade.toValue=0
            fade.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
            fade.beginTime=photo.layer?.convertTime(time,from:nil) ?? time;fade.duration=duration
            fade.fillMode = .both;fade.isRemovedOnCompletion=false
            photo.layer?.opacity=0;photo.layer?.add(fade,forKey:"mode.departure.fade")
            sourceViews.forEach {$0.isHidden=true;$0.layer?.isHidden=true}
            CATransaction.commit()
            let work=DispatchWorkItem { [weak self] in self?.picture.removeFromSuperview() }
            expiry=work
            DispatchQueue.main.asyncAfter(deadline:.now()+max(0,time+duration-CACurrentMediaTime()),execute:work)
        }
        /// This is the actual photo/material hierarchy, not the notification model's retirement phase.
        var screenState:[String:Any] {
            let attached=picture.window != nil && !picture.isHiddenOrHasHiddenAncestor
            var opacity=Double(picture.layer?.presentation()?.opacity ?? picture.layer?.opacity ?? 0)
            var parent=picture.superview
            let boundary=picture.window?.contentView?.superview
            while let p=parent,p !== boundary {opacity *= Double(p.layer?.presentation()?.opacity ?? Float(p.alphaValue));parent=p.superview}
            @MainActor func count(_ v:NSView)->Int {(v is NSGlassEffectView ? 1:0)+v.subviews.reduce(0){$0+count($1)}}
            let visibleSources=sourceViews.filter {v in
                guard v.window != nil,!v.isHiddenOrHasHiddenAncestor else{return false}
                var node:NSView?=v
                while let current=node,current !== v.window?.contentView?.superview {
                    if current.layer?.isHidden == true || current.alphaValue<=0 || current.layer?.opacity==0 {return false}
                    node=current.superview
                }
                return true
            }.count
            return ["attached":attached,"opacity":attached ? opacity:0,"glassCount":count(picture),"visibleSources":visibleSources,"captureMS":captureMS,"started":started,"duration":duration,"released":released]
        }
        func release() {
            guard !released else{return};released=true;expiry?.cancel();expiry=nil
            CATransaction.begin();CATransaction.setDisableActions(true)
            picture.removeFromSuperview()
            for (index,view) in sourceViews.enumerated() {view.isHidden=viewHidden[index];view.layer?.isHidden=hidden[index]}
            CATransaction.commit()
        }
        isolated deinit {expiry?.cancel();picture.removeFromSuperview();if !released {for (index,view) in sourceViews.enumerated() {view.isHidden=viewHidden[index];view.layer?.isHidden=hidden[index]}}}
    }
    private final class WeakLease {weak var value:Lease?;init(_ lease:Lease) {value=lease}}
    private static var active:[WeakLease]=[]
    private var leases:[Lease]=[]
    var exclusions:[NSView] {leases.flatMap(\.exclusions)}
    var screenStates:[[String:Any]] {leases.map(\.screenState)}
    /// A source cannot be unhidden by a later native/flight writer while its photo owns that surface.
    static func retains(_ view:NSView)->Bool {
        active.contains {$0.value.map {!$0.released && $0.sourceViews.contains(where:{$0 === view})} ?? false}
    }
    func retain(_ surfaces:[Surface],in host:NSView,at time:Double,duration:Double=0.22,spacing:CGFloat=10)->Lease {
        Self.active.removeAll {$0.value == nil || $0.value?.released == true}
        let lease=Lease(surfaces:surfaces,in:host,at:time,duration:duration,spacing:spacing)
        leases.append(lease);Self.active.append(WeakLease(lease));return lease
    }
    /// Release source suppression only at an admitted content endpoint, never at photo-fade completion.
    func finish() {leases.forEach {$0.release()};leases=[]}
    isolated deinit {leases.forEach {$0.release()}}
}
