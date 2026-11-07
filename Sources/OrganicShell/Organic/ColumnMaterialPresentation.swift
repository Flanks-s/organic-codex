import AppKit
import QuartzCore
import CoreText

extension ColumnNode {
    var gaussianOmittedPlatePixels:Int {gaussianPairs.values.reduce(0){$0+$1.omittedPlatePixels}}
    var gaussianMatteFallbackPixels:Int {gaussianPairs.values.reduce(0){$0+$1.exceptionalPixels}}
    var gaussianEnabled:Bool {zoomStyle == .gauss && motionExposure.enabled && !Motion.reduce}
    var gaussianFields:[String:Any] {
        guard let surface=gaussianSurface else{return [:]}
        return surface.fields.merging(["id":conversation.id,"entering":entering,"rect":NSStringFromRect(rect.target)]){_,b in b}
    }
    func gaussianFrame(at time:Double)->[String:Any] {
        guard let surface=gaussianSurface else{return [:]};let p=surface.effect.pose(at:time)
        return gaussianFields.merging(["radius":p.radius,"opacity":p.opacity,"scale":p.scale]){_,b in b}
    }
    struct PresenceMapping {let base:CGFloat,slope:CGFloat,direction:Bool?,entering:Bool}
    var presenceMapping:PresenceMapping {
        get {.init(base:presenceScaleMap.base,slope:presenceScaleMap.slope,direction:presenceScaleEntering,entering:entering)}
        set {presenceScaleMap=(newValue.base,newValue.slope);presenceScaleEntering=newValue.direction;entering=newValue.entering}
    }
    var preparedMotion:M10ColumnPlan {
        get {.init(times:m10Times,materials:m10Frames)}
        set {m10Times=newValue.times;m10Frames=newValue.materials}
    }
    func motionFrames(at elapsed: Double) -> [M10ColumnFrame] {
        guard !m10Times.isEmpty else { return [] }
        let i = min(m10Times.count - 1, max(0, Int((elapsed * Double(max(1, m10Times.count-1)) / max(0.0001, m10Times.last!)).rounded())))
        return m10Frames.keys.sorted().compactMap { m10Frames[$0]?[i] }
    }
    func rememberGaussian(_ image:CGImage,plate:CGImage) {
        let token=ObjectIdentifier(image)
        guard gaussianPairs[token] == nil else{return}
        gaussianPairs[token]=M10ColumnMatte.split(image,plates:plate);gaussianPairOrder.append(token)
        while gaussianPairOrder.count>8 {gaussianPairs[gaussianPairOrder.removeFirst()]=nil}
    }

    /// Reflow's planes have a common local origin. Rebase a retained source bitmap when full→Split
    /// changes the header reserve, so the first frame stays at its old screen position.
    func alignFullMaterials(_ materials:[ColumnFullMaterial],to top:CGFloat)->[ColumnFullMaterial] {
        let delta=nativeArea.minY-top
        guard abs(delta)>0.001 else{return materials}
        return materials.compactMap { material in
            if material.independentFade {var shifted=material;shifted.offsetY += delta;return shifted}
            let h=material.size.height+delta
            guard h>0,let context=CGContext(data:nil,width:material.image.width,height:Int(ceil(h*scale)),bitsPerComponent:8,bytesPerRow:0,
                                          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
            context.draw(material.image,in:CGRect(x:0,y:0,width:material.image.width,height:material.image.height))
            guard let image=context.makeImage() else{return nil}
            let overlay=material.copyOverlay();overlay?.position.y += delta
            return ColumnFullMaterial(image:image,size:CGSize(width:material.size.width,height:h),opacity:material.opacity,overlay:overlay)
        }
    }
    /// Freeze both current owners only when a second full layout interrupts a wheel continuation.
    func continuedFullMaterial(at time:Double)->ColumnFullMaterial? {
        guard hasContinuedTranscriptFlights else {return nil}
        let area=nativeArea,r=rect.sample(time).rect
        let root=CALayer();root.anchorPoint = .zero;root.frame=CGRect(origin:.zero,size:area.size)
        let clip=continuedTranscriptClip(at:time).offsetBy(dx:-r.minX-area.minX,dy:-r.minY-area.minY)
        let coverage=Self.fade();coverage.anchorPoint = .zero;coverage.frame=clip
        coverage.locations=Self.flightClipLocations(clip);root.mask=coverage
        let mask=native.layer?.mask;native.layer?.mask=nil
        let image=native.snapshot(scale:scale);native.layer?.mask=mask
        for flight in transcriptHandoff.continuedFlights {
            let material=flight.continuationMaterial(rect:r,form:form.sample(time).value,lyricSize:lyricSize)
            material.position.x -= r.minX+area.minX;material.position.y -= r.minY+area.minY
            root.addSublayer(material)
        }
        // Keep sampled glyph layers as layers. Rasterizing them into the native bitmap changes their
        // subpixel sampling at the exchange, even though their geometry and opacity are unchanged.
        return ColumnFullMaterial(image:image,size:area.size,opacity:1,overlay:root,independentFade:true,clipWidth:area.width+r.width-rect.target.width)
    }

    func fullMaterials(at time: Double) -> [ColumnFullMaterial] {
        if let continuation=continuedFullMaterial(at:time) {return [continuation]}
        if let fullReflow { return fullReflow.materials(at: time) }
        // The outgoing full layout is captured NOW, before snapshot(targetWidth) changes native geometry.
        if (!restOnSnapshot || gaussianCaptureNeeded), followBeforeMotion == nil, let widths=displayWidths {
            restWithGoal=snapshot(fullWidth:widths.full,briefWidth:widths.brief).withGoal
        }
        return restWithGoal.map { [ColumnFullMaterial(image: $0, size: nativeArea.size, opacity: 1)] } ?? []
    }

    func beginFullReflow(_ reflow: ColumnFullReflow) {
        fullReflow?.layer.removeFromSuperlayer();fullReflow?.overlayLayer?.removeFromSuperlayer();fullReflow = reflow
        if let overlay=reflow.overlayLayer {overlay.position=nativeArea.origin;inkMaterial.addSublayer(overlay)}
        transcriptClip.addSublayer(reflow.layer); transcript.opacity = 0; transcriptClip.opacity = 1
        if let bounds=reflow.clipBounds {
            // Each layout owns its fade. The common clip covers both header reserves until the old layout fades out.
            reflow.previousClipMask=transcriptClip.mask
            transcriptClip.mask=reflow.clipMask;transcriptClip.bounds=bounds
            transcriptClip.position=CGPoint(x:nativeArea.minX,y:nativeArea.minY+bounds.minY)
        }
        if ownsNative {
            if !native.isHidden { atEndBeforeMotion = native.shouldFollowEnd && native.isAtEnd }
            if followBeforeMotion == nil { followBeforeMotion = native.followsEnd }
            native.followsEnd = false
        }
        setNative(visible: false)
    }

    func fullReflowTracks(_ reflow: ColumnFullReflow, timeline: Timeline, rects: [CGRect]) -> [Track] {
        var tracks = reflow.tracks(timeline)
        let bounds = rects.map { r -> NSValue in
            let b=reflow.clipBounds ?? CGRect(origin:.zero,size:reflow.target.area.size)
            return NSValue(rect:CGRect(x:0,y:b.minY,width:r.width,height:b.height))
        }
        tracks.appendIf(timeline.track(transcriptClip, "bounds", bounds, smooth: true))
        if let mask=reflow.clipMask {
            let masks=bounds.map{NSValue(rect:CGRect(origin:.zero,size:$0.rectValue.size))}
            tracks.appendIf(timeline.track(mask,"bounds",masks,smooth:true))
        } else if let mask = transcriptClip.mask { tracks.appendIf(timeline.track(mask, "bounds", bounds, smooth: true)) }
        return tracks
    }

    /// Driver B for coming and going: the card and its separator fade, the card scales about its content's bottom centre.
    func presenceTracks(_ timeline: Timeline, values: [Double], rects: [CGRect]? = nil, earlierValues: [Double]? = nil, forms: [Double]? = nil, earlierForms: [Double]? = nil, sharp:Bool = false) -> [Track] {
        var out: [Track] = []
        let pivot = CGPoint(x: rect.target.width / 2, y: logicalBottom)
        let oldMap=presenceScaleMap,hadMap=presenceScaleEntering != nil,p0=CGFloat(values[0])
        // A reversal changes semantic direction, not the scale already on screen. Switching .25+.75p directly
        // to .92+.08p at p≈.5 jumped the returning header by hundreds of points (240Hz self-test, M10 on).
        if let previous=presenceScaleEntering,previous != entering,p0>0.00001,p0<0.99999 {
            let scale=oldMap.base+oldMap.slope*p0
            presenceScaleMap=entering ? ((scale-p0)/(1-p0),(1-scale)/(1-p0)):(0.25,(scale-0.25)/p0)
        } else if presenceScaleEntering == nil || presenceScaleEntering != entering {
            presenceScaleMap=entering ? (0.92,0.08):(0.25,0.75)
        }
        presenceScaleEntering=entering
        // A Gaussian form reveal must not be baked into delayed exposure copies. The legacy
        // accum comparison keeps its presence geometry, but changing-form content stays single.
        let singleReveal = motionExposure.enabled && zoomStyle == .accum && !Motion.reduce && MorphFlightMath.revealStyle != .slide
            && (forms.map { values in values.contains { abs($0-values[0])>1e-9 } } ?? false)
        if gaussianEnabled || sharp || singleReveal {
            // Preserve the container geometry/fade; only the separate foreground takes the Gaussian zoom.
            let transforms=values.map{NSValue(caTransform3D:presenceTransform($0,pivot:pivot))}
            out.appendIf(timeline.track(presenceMaterial,"transform",transforms))
            out.appendIf(timeline.track(presenceMaterial,"opacity",values.map{NSNumber(value:$0)}))
            out.appendIf(timeline.track(separator,"opacity",values.map{NSNumber(value:$0)}))
            presenceMaterial.transform=transforms.last!.caTransform3DValue;presenceMaterial.opacity=Float(values.last!);presenceMaterial.isHidden=false
            separator.opacity=Float(values.last!);card.opacity=1
            m10Frames["zoom"]=values.indices.map{M10ColumnFrame(id:conversation.id+".zoom.gauss",rect:(rects?[$0] ?? self.rect.target),sample:.still,treatment:"single content Gaussian, no exposure copies")}
            return out
        }
        // At p=0 no earlier pixels exist: a retired .25 scale must not become a fictitious zoom into the next
        // .92 entrance. Hold the new departure behind zero opacity instead of emitting hundreds of empty copies.
        let previousMap=hadMap && p0>0.00001 ? oldMap:presenceScaleMap
        let transforms = values.map { NSValue(caTransform3D: presenceTransform($0, pivot: pivot)) }
        let old = earlierValues ?? values, dt=motionProfile.frameInterval*motionExposure.shutter
        func value(_ time:Double)->Double {
            let times=timeline.times,source=time<0 ? old:values,t=time<0 ? time+dt:time
            var lo=0,hi=times.count-1
            while lo<hi {let m=(lo+hi)/2;if times[m]<t{lo=m+1}else{hi=m}}
            guard lo>0 else{return source[0]}
            let k=min(1,max(0,(t-times[lo-1])/max(1e-9,times[lo]-times[lo-1])))
            return source[lo-1]+(source[lo]-source[lo-1])*k
        }
        // A one-exposure prefix lets delayed copies read the real departure on interruption instead of holding the
        // new first pose. Its begin time is one exposure earlier; every original pose keeps its original timestamp.
        let prefixed=Timeline(began:0,duration:timeline.duration+dt,rate:Timeline.rate(frameInterval:dt))
        let prefixedValues=prefixed.map{value($0-dt)}
        let prefixedTransforms=prefixed.times.map { time in NSValue(caTransform3D:presenceTransform(value(time-dt),pivot:pivot,map:time<dt ? previousMap:nil)) }
        if let t=prefixed.track(presenceMaterial,"transform",prefixedTransforms) {out.append(Track(layer:t.layer,key:"shell.m10-prefix|\(dt)|\(t.key)",animation:t.animation))}
        if let t=prefixed.track(presenceMaterial,"opacity",prefixedValues.map{NSNumber(value:$0)}) {out.append(Track(layer:t.layer,key:"shell.m10-prefix|\(dt)|\(t.key)",animation:t.animation))}
        if let t=prefixed.track(presenceInk,"transform",prefixedTransforms) {out.append(Track(layer:t.layer,key:"shell.m10-prefix|\(dt)|\(t.key)",animation:t.animation))}
        if let t=prefixed.track(presenceInk,"opacity",prefixedValues.map{NSNumber(value:$0)}) {out.append(Track(layer:t.layer,key:"shell.m10-prefix|\(dt)|\(t.key)",animation:t.animation))}
        presenceInk.transform = transforms.last!.caTransform3DValue
        presenceInk.opacity = Float(values.last!)
        // An interrupted form flight can also leave/return. Preserve BOTH planes and the original reveal,
        // instead of freezing the target brief and losing the still-visible transcript underneath its flights.
        if let forms {
            func formValue(_ time:Double)->Double {
                let source=time<0 ? (earlierForms ?? forms):forms,t=time<0 ? time+dt:time,keys=timeline.times
                var lo=0,hi=keys.count-1
                while lo<hi {let m=(lo+hi)/2;if keys[m]<t {lo=m+1}else{hi=m}}
                guard lo>0 else{return source[0]}
                let k=min(1,max(0,(t-keys[lo-1])/max(1e-9,keys[lo]-keys[lo-1])))
                return source[lo-1]+(source[lo]-source[lo-1])*k
            }
            for (source,full) in [(presenceFullInk,true),(presenceBriefInk,false)] {
                let sourceValues=prefixed.times.map { time -> NSNumber in
                    let f=formValue(time-dt),opacity=full ? MorphFlightMath.transcriptOpacity(form:f,on:true):MorphFlightMath.reveal(amount:1-f,order:1,on:true).opacity
                    return NSNumber(value:value(time-dt)*opacity)
                }
                let sourceTransforms=prefixed.times.indices.map { i -> NSValue in
                    var tr=prefixedTransforms[i].caTransform3DValue
                    if !full {tr.m42 += tr.m22*CGFloat(MorphFlightMath.reveal(amount:1-formValue(prefixed.times[i]-dt),order:1,on:true,moves:!Motion.reduce).offsetY)}
                    return NSValue(caTransform3D:tr)
                }
                source.transform=sourceTransforms.last!.caTransform3DValue;source.opacity=sourceValues.last!.floatValue
                for (path,data) in [("transform",sourceTransforms as [Any]),("opacity",sourceValues as [Any])] {
                    if let t=prefixed.track(source,path,data) {out.append(Track(layer:t.layer,key:"shell.m10-prefix|\(dt)|\(t.key)",animation:t.animation))}
                }
            }
        }
        if let t = timeline.track(separator, "opacity", values.map { NSNumber(value: $0) }) { out.append(t) }
        // Model values: where it ends, so nothing jumps if the animations end early. Without implicit animations: this
        // runs when the transition is prepared, and an implicit fade (timed by the real clock) outlived the tracks.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        presenceMaterial.transform = transforms.last!.caTransform3DValue
        presenceMaterial.opacity = Float(values.last!); separator.opacity = Float(values.last!)
        card.opacity = 1
        let boxes = rects ?? timeline.map { _ in CGRect(origin: .zero, size: self.rect.target.size) }
        let samples = timeline.times.indices.map { i -> ExposureSample in
            let box = CGRect(origin: .zero, size: boxes[i].size)
            return M10ColumnExposure.pathSample(at:timeline.times[i],profile:motionProfile,settings:motionExposure) { time in
                let tr=presenceTransform(value(time),pivot:pivot,map:time<0 ? previousMap:nil)
                return box.applying(CGAffineTransform(a:tr.m11,b:0,c:0,d:tr.m22,tx:tr.m41,ty:tr.m42))
            }
        }
        m10Frames["zoom"] = samples.indices.map { i in
            let sample=samples[i],box=CGRect(origin:.zero,size:boxes[i].size),time=timeline.times[i]
            @MainActor func pose(_ time:Double)->CGRect {
                let tr=presenceTransform(value(time),pivot:pivot,map:time<0 ? previousMap:nil)
                return box.applying(CGAffineTransform(a:tr.m11,b:0,c:0,d:tr.m22,tx:tr.m41,ty:tr.m42))
            }
            let first=pose(time);var previous=first,gap:CGFloat=0
            if sample.count>1 {for k in 1..<sample.count {let next=pose(time-Double(k)*sample.delayStep);gap=max(gap,MotionStep.edge(previous,next));previous=next}}
            return M10ColumnFrame(id:conversation.id + (entering ? ".zoom.in":".zoom.out"),rect:boxes[i],sample:sample,
                treatment:"path-scale accumulation",adjacentSpacing:gap,coveredLength:MotionStep.edge(first,previous))
        }
        if cardBand != nil {
            let fs=forms ?? values.map{_ in self.form.to}
            let poses=samples.indices.map { i -> (CGRect,CGRect,CGFloat) in
                let time=timeline.times[i],box=cardFrame(width:boxes[i].width),s=samples[i]
                let a=presenceTransform(value(time),pivot:pivot)
                let before=presenceTransform(value(time-Double(max(0,s.count-1))*s.delayStep),pivot:pivot,map:time-Double(max(0,s.count-1))*s.delayStep<0 ? previousMap:nil)
                return (box.applying(CATransform3DGetAffineTransform(a)),box.applying(CATransform3DGetAffineTransform(before)),max(a.m11,before.m11)*18)
            }
            out += zoomSurface.tracks(timeline,poses:poses,colors:fs.map{Self.cardFillColor(form:$0)},opacities:values.indices.map{samples[$0].count>1 ? values[$0]:0})
            let weights=values.indices.map { i in smoothstep(0,0.75,Double(m10Frames["edges"]?[i].sample.length ?? 0)) }
            out.appendIf(timeline.track(cardFill,"opacity",samples.indices.map{NSNumber(value:samples[$0].count>1 ? 0:1-weights[$0])}))
            out.appendIf(timeline.track(cardSweep,"opacity",samples.indices.map{NSNumber(value:samples[$0].count>1 ? 0:weights[$0])}))
        }
        out.appendIf(timeline.track(presenceTrail, "instanceCount", samples.map { NSNumber(value: $0.count) }, discrete: true))
        out.appendIf(timeline.track(presenceTrail, "instanceDelay", samples.map { NSNumber(value: $0.delayStep) }))
        out.appendIf(M10ColumnExposure.colorTrack(timeline,on:presenceTrail,samples:samples))
        out.appendIf(timeline.track(inkMaterial, "opacity", samples.map { NSNumber(value: Double(1-$0.gate)) }))
        out.appendIf(timeline.track(inkMaterial, "hidden", samples.map { NSNumber(value: $0.gate>=1) }, discrete: true))
        // At full gate the baked leaves carry all body ink and the analytic surface carries the card. Cull the
        // empty column-sized clipping/opacity group too; native island glass lives in its own view plane.
        if island != nil {out.appendIf(timeline.track(presenceMaterial,"hidden",samples.map{NSNumber(value:$0.gate>=1)},discrete:true))}
        presenceMaterial.isHidden=false
        out.appendIf(timeline.track(presenceTrail, "opacity", samples.map { NSNumber(value: Double($0.gate)) }))
        inkMaterial.opacity = 1; inkMaterial.isHidden = false; presenceTrail.opacity = 0
        presenceTrail.instanceCount = 1; presenceTrail.instanceDelay = 0; presenceTrail.instanceColor = NSColor.white.cgColor
        CATransaction.commit()
        return out
    }

    func warmBriefExposureInk() {
        guard motionExposure.enabled, form.to<0.5,presence.to>0.5,applied != nil else{return}
        _=preparePresenceInk(snapshot:nil,width:rect.target.width,form:form.to,hideGoals:false)
    }

    struct InkKey: Hashable {
        let snapshot: Snapshot.Key?
        let width: CGFloat, height: CGFloat, form: Double
        let hidden: Bool, island: Bool
        let revision: Int
        let band: ClosedRange<CGFloat>?
        let imageToken: UInt
        let channel:Int
    }

    /// Prepared and cached together with the immutable transition. Never bake or flush AppKit after its clock
    /// starts: that lost two display frames even after the expensive render-server subtree had been removed.
    func preparePresenceInk(snapshot s: Snapshot?, width: CGFloat, form f: Double, hideGoals: Bool, transcriptOverride: (image:CGImage,size:CGSize)? = nil, channel:M10ColumnMatte.Channel = .original) -> [M10ColumnTexture.Bitmap] {
        let key=InkKey(snapshot:s?.key ?? applied,width:width,height:sceneHeight,form:f,hidden:hideGoals,island:island != nil,revision:s?.key.revision ?? applied?.revision ?? conversation.revision,band:cardBand,imageToken:transcriptOverride.map{CFHash($0.image)} ?? 0,channel:channel.rawValue)
        if let cached=bakedInkCache[key] { exposureBakeMs=0;return cached }
        let began=CACurrentMediaTime()
        func material(_ image:CGImage?)->CGImage? {
            guard let image,channel != .original else{return image}
            if let pair=gaussianPairs[ObjectIdentifier(image)] ?? ColumnRevealMaterial.find(image,owner:self)?.pair {return channel == .ink ? pair.ink:pair.plates}
            if f>0.5 && image.width>1 {gaussianMissingMaterials+=1}
            return channel == .plates ? image:nil
        }
        var clones:[ObjectIdentifier:CALayer]=[:]
        let source=M10ColumnTexture.clone(cardBody,into:&clones)
        if channel != .original,let fullReflow {clones[ObjectIdentifier(fullReflow.layer)]?.removeFromSuperlayer()}
        func copy(_ l:CALayer)->CALayer {clones[ObjectIdentifier(l)]!}
        source.frame=CGRect(x:0,y:0,width:width,height:sceneHeight)
        if channel != .original {copy(transcript).opacity=1}
        copy(planet).opacity=0;copy(capsule).opacity=0 // headless geometry proxy; real HeaderIsland is a separate plane
        copy(inkMaterial).frame=source.bounds;copy(inkMaterial).opacity=1;clones[ObjectIdentifier(cardFill)]?.opacity=0
        if let mask=source.mask {mask.frame=cardFrame(width:width)}
        if let s {
            let clip=copy(transcriptClip);clip.frame=s.area
            if transcriptOverride != nil {clip.frame.size.width=width}
            shapeFade(clip.mask,clip.bounds.size)
            copy(transcript).contents=material(transcriptOverride?.image ?? (hideGoals ? s.transcript:(s.withGoal ?? s.transcript)))
            copy(transcript).frame=CGRect(origin:.zero,size:transcriptOverride?.size ?? s.transcriptSize)
            let b=copy(brief);b.frame=s.briefFrame;b.transform=CATransform3DIdentity
            b.mask?.frame=CGRect(origin:.zero,size:s.briefFrame.size)
            (b.mask as? CAGradientLayer)?.locations=[0,NSNumber(value:Double(16/max(16,s.briefFrame.height)))]
            let content=copy(briefContent);content.frame=CGRect(origin:s.briefOrigin,size:CGSize(width:s.briefFrame.width,height:max(1,s.briefLayout.height)));content.sublayers=[]
            for part in s.briefLayout.parts {
                let layer=CALayer();layer.anchorPoint = .zero;layer.frame=part.frame
                layer.opacity=part.current ? 1:Look.olderLine
                if channel != .plates && (!hideGoals || !s.flownParts.contains(part.id)) {
                    let text=CALayer();text.anchorPoint = .zero;text.frame=CGRect(origin:.zero,size:part.frame.size)
                    text.contentsScale=scale;text.contents=part.image;layer.addSublayer(text)
                }
                if channel != .plates,let dots=part.dots {
                    let d=DotsLayer();d.anchorPoint = .zero;d.frame=dots.frame
                    d.configure(dots.size,color:part.kind == .dots ? Look.ink:Look.secondary,scale:scale,still:!ambient || Motion.reduce);layer.addSublayer(d)
                }
                content.addSublayer(layer)
            }
            if let title=s.title {copy(capsuleTitle).contents=title.image;copy(capsuleTitle).bounds=CGRect(origin:.zero,size:title.size)}
        } else {
            if f>0.5 {copy(transcript).contents=material(hideGoals ? motionBase:(restWithGoal ?? motionBase))}
            if channel == .plates {copy(briefContent).sublayers=[]}
            if hideGoals {for id in flownParts {if let l=briefLayers[id]?.sublayers?.first(where:{$0.name=="text"}) {copy(l).opacity=0}}}
        }
        copy(transcriptClip).opacity=Float(MorphFlightMath.transcriptOpacity(form:f,on:true))
        copy(brief).opacity=Float(MorphFlightMath.reveal(amount:1-f,order:1,on:true).opacity)
        let h=header(width:width,form:f)
        copy(planet).position=h.planet.origin;copy(planet).bounds=CGRect(origin:.zero,size:h.planet.size);copy(planet).cornerRadius=h.planet.width/2
        copy(capsule).position=h.capsule.origin;copy(capsule).bounds=CGRect(origin:.zero,size:h.capsule.size);copy(capsule).cornerRadius=h.capsule.height/2
        copy(capsuleTitle).position=CGPoint(x:h.capsule.width/2,y:h.capsule.height/2)
        copy(capsuleTitle).transform=CATransform3DMakeScale(h.titleScale,h.titleScale,1)
        let baked=M10ColumnTexture.bake(source,scale:scale)
        if bakedInkCache.count>12 {bakedInkCache=[:]}
        bakedInkCache[key]=baked;exposureBakeMs=(CACurrentMediaTime()-began)*1000
        return baked
    }

    func prepareInkTiles(_ bitmaps:[M10ColumnTexture.Bitmap],tracks:[Track],plane:Bool? = nil)->[M10ColumnInkTile] {
        let source=plane.map{$0 ? presenceFullInk:presenceBriefInk} ?? presenceInk
        return bitmaps.map { M10ColumnInkTile.make($0,scale:scale,prototype:presenceTrail,source:source,tracks:tracks) }
    }
    func prepareReflowInk(_ reflow:ColumnFullReflow,snapshot:Snapshot,tracks:[Track])->[M10ColumnInkTile] {
        let crop=tracks.first{$0.layer===transcriptClip && $0.animation.keyPath=="bounds"}?.animation
        return (reflow.layer.sublayers ?? []).flatMap { material -> [M10ColumnInkTile] in
            guard let contents=material.contents,CFGetTypeID(contents as CFTypeRef)==CGImage.typeID else{return []}
            let fade=tracks.first{$0.layer===material && $0.animation.keyPath=="opacity"}?.animation
            guard fade != nil || material.opacity>0 else{return []}
            let image=contents as! CGImage,width=max(snapshot.area.width,material.bounds.width,rect.target.width)
            let bitmaps=preparePresenceInk(snapshot:snapshot,width:width,form:1,hideGoals:false,transcriptOverride:(image,material.bounds.size))
            return bitmaps.map {M10ColumnInkTile.make($0,scale:scale,prototype:presenceTrail,source:presenceFullInk,tracks:tracks,materialOpacity:fade,materialAlpha:Double(material.opacity),clipWidth:crop)}
        }
    }

    /// These carry immutable reference curves for prepare(), never visible material or server-side clocks.
    func isExposureTemplate(_ layer:CALayer)->Bool {
        layer === presenceTrail || layer === presenceInk || layer === presenceFullInk || layer === presenceBriefInk
    }

    func installPresenceInk(_ tiles: [M10ColumnInkTile]) {
        for item in bakedPresence { item.trail.removeFromSuperlayer() }
        bakedPresence=tiles.map { ($0.trail,$0.ink) }
        bakedInkFrames=tiles.map(\.frames)
        bakedPeakCopies=tiles.map(\.peakCopies).max() ?? 1
        for tile in tiles { card.addSublayer(tile.trail) }
    }

    func prepareGaussian(snapshot:Snapshot?,reflow:ColumnFullReflow?,timeline:Timeline,forms:[Double],hideGoals:Bool,tracks:[Track])->M10ColumnGaussianAsset {
        let asset=M10ColumnGaussianAsset(size:CGSize(width:rect.target.width,height:sceneHeight))
        if cardBand != nil {
            let clip=CALayer();clip.anchorPoint = .zero;clip.contentsScale=scale
            clip.cornerCurve = .continuous;clip.backgroundColor=NSColor.black.cgColor;asset.clip=clip
            let sizes=tracks.first{$0.layer===cardMask && $0.animation.keyPath=="bounds"}?.animation.values as? [NSValue]
            let poses=tracks.first{$0.layer===presenceMaterial && $0.animation.keyPath=="transform"}?.animation.values as? [NSValue]
            let shapes=timeline.times.indices.map { i -> CGRect in
                let box=cardFrame(width:sizes?[i].rectValue.width ?? rect.target.width)
                return box.applying(CATransform3DGetAffineTransform(poses?[i].caTransform3DValue ?? presenceMaterial.transform))
            }
            let radii=timeline.times.indices.map {NSNumber(value:18*Double((poses?[$0].caTransform3DValue ?? presenceMaterial.transform).m11))}
            clip.frame=shapes.last!;clip.cornerRadius=CGFloat(radii.last!.doubleValue)
            // The content has its own mild zoom. Clip it to the ORIGINAL moving card's real bounds, rather
            // than allowing a still-full-size glyph plane to stick out of the shrinking card during its exit.
            asset.tracks.appendIf(timeline.track(clip,"position",shapes.map{NSValue(point:$0.origin)}))
            asset.tracks.appendIf(timeline.track(clip,"bounds",shapes.map{NSValue(rect:CGRect(origin:.zero,size:$0.size))}))
            asset.tracks.appendIf(timeline.track(clip,"cornerRadius",radii))
        }
        func plane(full:Bool,image:CGImage?=nil,size:CGSize?=nil,fade:CAKeyframeAnimation?=nil,alpha:Float=1) {
            if full && forms.allSatisfy({MorphFlightMath.transcriptOpacity(form:$0,on:true)==0}) {return}
            if !full && forms.allSatisfy({MorphFlightMath.reveal(amount:1-$0,order:1,on:true).opacity==0}) {return}
            let inkRoot=CALayer(),plateRoot=CALayer()
            for r in [inkRoot,plateRoot] {r.anchorPoint = .zero;r.bounds=asset.ink.bounds}
            for (root,channel) in [(inkRoot,M10ColumnMatte.Channel.ink),(plateRoot,.plates)] {
                let override=image.map{(image:$0,size:size ?? CGSize(width:rect.target.width,height:sceneHeight))}
                let bitmaps=preparePresenceInk(snapshot:snapshot,width:max(rect.target.width,size?.width ?? 0),form:full ? 1:0,hideGoals:hideGoals,transcriptOverride:override,channel:channel)
                // A single filter wraps all foreground quads; backgrounds are siblings outside that filter.
                if channel == .ink {root.name = full ? "m1115.reveal.full":"m1115.reveal.brief"}
                let target=channel == .ink ? asset.ink:asset.plates
                let group=M10ColumnGaussianAsset(size:asset.ink.bounds.size);group.append(bitmaps,to:channel == .ink ? group.ink:group.plates,scale:scale,material:channel == .ink ? .glyph:.container)
                root.addSublayer(channel == .ink ? group.ink:group.plates);target.addSublayer(root)
                if full,let crop=tracks.first(where:{$0.layer===transcriptClip && $0.animation.keyPath=="bounds"}),let sizes=crop.animation.values as? [NSValue] {
                    root.masksToBounds=true
                    let bounds=sizes.map{NSValue(rect:CGRect(x:0,y:0,width:$0.rectValue.width,height:sceneHeight))}
                    root.bounds=bounds.last!.rectValue
                    asset.tracks.appendIf(timeline.track(root,"bounds",bounds,smooth:true))
                }
                let opacities=forms.enumerated().map{i,f -> NSNumber in
                    var p=full ? MorphFlightMath.transcriptOpacity(form:f,on:true):MorphFlightMath.reveal(amount:1-f,order:1,on:true).opacity
                    if let values=fade?.values as? [NSNumber],i<values.count {p *= values[i].doubleValue}else{p *= Double(alpha)}
                    return NSNumber(value:p)
                }
                root.opacity=opacities.last!.floatValue;asset.tracks.appendIf(timeline.track(root,"opacity",opacities))
                if !full {let poses=forms.map{NSValue(caTransform3D:CATransform3DMakeTranslation(0,CGFloat(MorphFlightMath.reveal(amount:1-$0,order:1,on:true,moves:!Motion.reduce).offsetY),0))}
                    root.transform=poses.last!.caTransform3DValue;asset.tracks.appendIf(timeline.track(root,"transform",poses))}
            }
        }
        if let reflow {
            for l in reflow.layer.sublayers ?? [] {guard let value=l.contents,CFGetTypeID(value as CFTypeRef)==CGImage.typeID else{continue}
                plane(full:true,image:(value as! CGImage),size:l.bounds.size,fade:tracks.first{$0.layer===l && $0.animation.keyPath=="opacity"}?.animation,alpha:l.opacity)
            }
        } else {plane(full:true)}
        plane(full:false)
        return asset
    }

    func installGaussian(_ asset:M10ColumnGaussianAsset?,timeline:Timeline,clock:SceneClock,at time:Double) {
        // The commit has now applied the prepared snapshot and hidden flight-owned words.
        if asset == nil { installReveal(timeline, at: time) }
        guard let asset,gaussianEnabled else {gaussianSurface?.root.removeFromSuperlayer();gaussianSurface=nil;return}
        let fresh=gaussianSurface == nil
        if gaussianSurface == nil {gaussianSurface=M10ColumnGaussianSurface(size:CGSize(width:rect.target.width,height:sceneHeight),pivot:CGPoint(x:rect.target.width/2,y:logicalBottom),clock:clock,visible:!entering,scale:scale)}
        let surface=gaussianSurface!;if surface.root.superlayer == nil {card.addSublayer(surface.root)}
        surface.foreground.removeAnimation(forKey:"shell.m1115.outer-clear")
        surface.install(asset,visible:entering,at:time)
        installCombinedReveal(asset, surface:surface, timeline:timeline, at:time)
        // Exact original pixels at the first and final plateau. The Gaussian is sharp by 100ms and remains the
        // content material until the unchanged column spring ends; no early handoff to a half-opacity spring.
        let gate=CAKeyframeAnimation(keyPath:"opacity");gate.values=[fresh ? 1:0,0,1];gate.keyTimes=[0,0.000001,NSNumber(value:1-1/(240*timeline.duration)),1];gate.calculationMode = .discrete;gate.duration=timeline.duration;gate.fillMode = .both;gate.isRemovedOnCompletion=false
        gate.beginTime=inkMaterial.convertTime(time,from:nil);inkMaterial.add(gate,forKey:"shell.m101.original-gate");inkMaterial.isHidden=false;inkMaterial.opacity=1
        let inverse=gate.copy() as! CAKeyframeAnimation;inverse.values=[fresh ? 0:1,1,0];inverse.beginTime=surface.root.convertTime(time,from:nil);surface.root.add(inverse,forKey:"shell.m101.surface-gate");surface.root.isHidden=false;surface.root.opacity=0
    }

    private func presenceTransform(_ p: Double, pivot: CGPoint,map:(base:CGFloat,slope:CGFloat)?=nil) -> CATransform3D {
        let map=map ?? presenceScaleMap,s=map.base+map.slope*CGFloat(p)
        guard abs(s - 1) > 1e-6 else { return CATransform3DIdentity }
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(pivot.x, pivot.y, 0), s, s, 1), -pivot.x, -pivot.y, 0)
    }

    func finishGaussian() {
        finishReveal()
        guard gaussianSurface != nil || !gaussianPairs.isEmpty else{return}
        if let effect=gaussianSurface?.effect,let end=effect.endTime {_ = effect.settle(at:end)}
        gaussianSurface?.root.removeFromSuperlayer();gaussianSurface=nil
        inkMaterial.removeAnimation(forKey:"shell.m101.original-gate");inkMaterial.opacity=1
        gaussianPairs=[:];gaussianPairOrder=[];gaussianCapturePlate=nil
        bakedInkCache=bakedInkCache.filter{$0.key.channel == M10ColumnMatte.Channel.original.rawValue}
    }

    /// At rest on screen: no presence transform left over.
    func showPresent() {
        finishGaussian()
        presenceScaleMap=(0.25,0.75);presenceScaleEntering=nil
        card.transform = CATransform3DIdentity
        card.opacity = 1
        presenceMaterial.transform = CATransform3DIdentity; presenceMaterial.opacity = 1; presenceMaterial.isHidden = false
        inkMaterial.opacity = 1; inkMaterial.isHidden = false; presenceTrail.opacity = 0; presenceTrail.instanceCount = 1
        for tile in bakedPresence { tile.trail.opacity = 0; tile.trail.instanceCount = 1 }
        zoomSurface.layer.opacity = 0
        cardSweep.opacity = 0; cardFill.opacity = 1; separatorSweep.opacity = 0
        separator.colors = [Look.separator.withAlphaComponent(0).cgColor, Look.separator.cgColor, Look.separator.cgColor, Look.separator.withAlphaComponent(0).cgColor]
    }

    func removeAnimations() {
        finishReveal()
        for l in [card, presenceMaterial, cardBody, inkMaterial, presenceTrail, presenceInk, presenceFullInk, presenceBriefInk, cardSweep, separator, separatorSweep, separatorSweepMask, planet, capsule, capsuleTitle, transcriptClip, brief, cardMask, cardFill] { l.removeShellAnimations() }
        zoomSurface.layer.removeShellAnimations();zoomSurface.layer.mask?.removeShellAnimations()
        for tile in bakedPresence { tile.trail.removeShellAnimations(); tile.ink.removeShellAnimations() }
        transcriptClip.mask?.removeShellAnimations()
    }

    /// Driver B for this column: carrier rect, separator, header variant, transcript fade and brief reveal,
    /// from its rect and form sampled on `timeline`.
    func tracks(_ timeline: Timeline, rects: [CGRect], forms: [Double], earlierRects: [CGRect]? = nil) -> [Track] {
        var out: [Track] = []
        m10Frames = [:]; m10Times = timeline.times
        func add(_ l: CALayer, _ key: String, _ v: [Any], smooth: Bool = false) {
            if let t = timeline.track(l, key, v, smooth: smooth) { out.append(t) }
        }
        add(card, "position", rects.map { NSValue(point: $0.origin) }, smooth: true)
        add(card, "bounds", rects.map { NSValue(rect: CGRect(origin: .zero, size: $0.size)) }, smooth: true)
        for layer in [presenceMaterial, cardBody, inkMaterial] {
            add(layer, "bounds", rects.map { NSValue(rect: CGRect(origin: .zero, size: $0.size)) }, smooth: true)
        }
        if cardBand != nil {
            let shapes = rects.map { NSValue(rect: CGRect(origin: .zero, size: cardFrame(width: $0.width).size)) }
            add(cardMask, "bounds", shapes, smooth: true)
            add(cardFill, "bounds", shapes, smooth: true)
            add(cardFill, "backgroundColor", forms.map { Self.cardFillColor(form: $0) })
        }
        let earlier = earlierRects ?? rects
        let samples = rects.indices.map { M10ColumnExposure.sample(rects[$0], earlier[$0], profile: motionProfile, settings: motionExposure) }
        if cardBand != nil {
            m10Frames["edges"] = samples.indices.map { M10ColumnFrame(id: conversation.id + ".edges", rect: rects[$0], sample: samples[$0], treatment: "linear edge gradients") }
            let sweeps = rects.indices.map { i -> M10ColumnExposure.Sweep in
                let now = cardFrame(width: rects[i].width)
                let old = cardFrame(width: earlier[i].width).offsetBy(dx: earlier[i].minX-rects[i].minX, dy: 0)
                return .make(now, earlier: old, gate: samples[i].gate)
            }
            let weights = sweeps.map { smoothstep(0, 0.75, Double($0.length)) }
            cardSweep.frame = sweeps.last!.frame; cardSweep.locations = sweeps.last!.locations
            cardSweep.colors = M10ColumnExposure.colors(Self.cardFillColor(form: forms.last!), peak: sweeps.last!.peak)
            add(cardSweep, "position", sweeps.map { NSValue(point: $0.frame.origin) }, smooth: true)
            add(cardSweep, "bounds", sweeps.map { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }, smooth: true)
            add(cardSweep, "locations", sweeps.map { $0.locations })
            add(cardSweep, "colors", sweeps.indices.map { M10ColumnExposure.colors(Self.cardFillColor(form: forms[$0]), peak: sweeps[$0].peak) })
            add(cardSweep, "opacity", weights.map { NSNumber(value: $0) })
            add(cardFill, "opacity", weights.map { NSNumber(value: 1-$0) })
        }
        let lines = rects.map { CGRect(x: $0.maxX + 6 - 0.5/scale, y: 0, width: 1/scale, height: $0.height) }
        let oldLines = earlier.map { CGRect(x: $0.maxX + 6 - 0.5/scale, y: 0, width: 1/scale, height: $0.height) }
        let lineSamples = lines.indices.map { M10ColumnExposure.sample(lines[$0], oldLines[$0], profile: motionProfile, settings: motionExposure) }
        let lineSweeps = lines.indices.map { M10ColumnExposure.Sweep.make(lines[$0], earlier: oldLines[$0], gate: lineSamples[$0].gate) }
        let lineWeights = lineSweeps.map { smoothstep(0, 0.75, Double($0.length)) }
        m10Frames["separator"] = lineSamples.indices.map { M10ColumnFrame(id: conversation.id + ".separator", rect: lines[$0], sample: lineSamples[$0], treatment: "area-preserving linear convolution") }
        add(separator, "colors", lineWeights.map { w in [0.0,1,1,0].map { Look.separator.withAlphaComponent(CGFloat($0 * (1-w)) * Look.separator.alphaComponent).cgColor } })
        separatorSweep.colors = [Look.separator.withAlphaComponent(0).cgColor, Look.separator.cgColor, Look.separator.cgColor, Look.separator.withAlphaComponent(0).cgColor]
        separatorSweep.locations = [0,0.12,0.8,1]
        separatorSweep.frame = lineSweeps.last!.frame.offsetBy(dx: -lines.last!.minX, dy: 0)
        separatorSweepMask.frame = separatorSweep.bounds; separatorSweepMask.locations = lineSweeps.last!.locations
        separatorSweepMask.colors = M10ColumnExposure.colors(NSColor.black.cgColor, peak: lineSweeps.last!.peak)
        add(separatorSweep, "position", lineSweeps.indices.map { NSValue(point: CGPoint(x: lineSweeps[$0].frame.minX-lines[$0].minX, y: 0)) }, smooth: true)
        add(separatorSweep, "bounds", lineSweeps.map { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }, smooth: true)
        add(separatorSweep, "opacity", lineWeights.map { NSNumber(value: $0) })
        add(separatorSweepMask, "bounds", lineSweeps.map { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }, smooth: true)
        add(separatorSweepMask, "locations", lineSweeps.map { $0.locations })
        add(separatorSweepMask, "colors", lineSweeps.map { M10ColumnExposure.colors(NSColor.black.cgColor, peak: $0.peak) })
        add(separator, "position", rects.map { NSValue(point: CGPoint(x: $0.maxX + 6 - 0.5 / scale, y: 0)) }, smooth: true)
        let headers = zip(rects, forms).map { header(width: $0.width, form: $1) }
        add(planet, "position", headers.map { NSValue(point: $0.planet.origin) }, smooth: true)
        add(planet, "bounds", headers.map { NSValue(rect: CGRect(origin: .zero, size: $0.planet.size)) }, smooth: true)
        add(planet, "cornerRadius", headers.map { NSNumber(value: Double($0.planet.width / 2)) })
        add(capsule, "position", headers.map { NSValue(point: $0.capsule.origin) }, smooth: true)
        add(capsule, "bounds", headers.map { NSValue(rect: CGRect(origin: .zero, size: $0.capsule.size)) }, smooth: true)
        add(capsule, "cornerRadius", headers.map { NSNumber(value: Double($0.capsule.height / 2)) })
        add(capsuleTitle, "position", headers.map { NSValue(point: CGPoint(x: $0.capsule.width / 2, y: $0.capsule.height / 2)) }, smooth: true)
        add(capsuleTitle, "transform", headers.map { NSValue(caTransform3D: CATransform3DMakeScale($0.titleScale, $0.titleScale, 1)) })
        add(transcriptClip, "opacity", forms.map { NSNumber(value: MorphFlightMath.transcriptOpacity(form: $0, on: true)) })
        let reveals = forms.map { MorphFlightMath.reveal(amount: 1 - $0, order: 1, on: true, moves: !Motion.reduce) }
        add(brief, "opacity", reveals.map { NSNumber(value: $0.opacity) })
        add(brief, "transform", reveals.map { NSValue(caTransform3D: CATransform3DMakeTranslation(0, $0.offsetY, 0)) })
        return out
    }
}

/// M11.15: immutable form samples, one foreground Gaussian, and no display-link work.
/// CA's gaussianBlur inputRadius is in layer points. A radius of 10 is used directly (not
/// multiplied by backing scale); the offscreen impulse fixture records its measured sigma.
@MainActor enum ColumnRevealFilter {
    static let name = "m1115RevealGaussian"
    static func filter(radius: CGFloat) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              let f = cls.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else { return nil }
        f.setValue(name, forKey: "name"); f.setValue(radius, forKey: "inputRadius")
        return f
    }
    /// Same source-over recovery as M10ColumnMatte, with a packed equality fast path for the
    /// large unchanged/transparent viewport. Recover only the hidden-flight source used during
    /// form motion; do not also split withGoal, which is restored unfiltered at the endpoint.
    nonisolated static func split(_ original:CGImage,plates:CGImage)->M10ColumnMatte.Pair {
        guard original.width==plates.width,original.height==plates.height else {
            return .init(original:original,ink:image([UInt8](repeating:0,count:original.width*original.height*4),width:original.width,height:original.height),plates:original,exceptionalPixels:original.width*original.height,omittedPlatePixels:0)
        }
        let a=rgba(original);var b=rgba(plates),g=[UInt8](repeating:0,count:a.count)
        var exceptional=0,omitted=0
        a.withUnsafeBytes { ar in b.withUnsafeMutableBytes { br in g.withUnsafeMutableBytes { gr in
            let ap=ar.bindMemory(to:UInt8.self).baseAddress!,bp=br.bindMemory(to:UInt8.self).baseAddress!,gp=gr.bindMemory(to:UInt8.self).baseAddress!
            for i in stride(from:0,to:a.count,by:4) {
                if ar.loadUnaligned(fromByteOffset:i,as:UInt32.self)==br.loadUnaligned(fromByteOffset:i,as:UInt32.self) {continue}
                let aa=Double(ap[i+3])/255,ab=Double(bp[i+3])/255
                if aa==0 {omitted+=1;for c in 0..<4 {bp[i+c]=0};continue}
                var alpha=ab<1 ? max(0,min(1,(aa-ab)/(1-ab))):0
                if ab>=1 {for c in 0..<3 {let x=Double(ap[i+c])/255,y=Double(bp[i+c])/255
                    alpha=max(alpha,x>=y ? (x-y)/max(1e-9,1-y):(y-x)/max(1e-9,y))}}
                if aa+1/255<ab {exceptional+=1;for c in 0..<4 {bp[i+c]=0};alpha=aa}
                let q=min(255,max(0,Int((alpha*255).rounded())));gp[i+3]=UInt8(q)
                for c in 0..<3 {gp[i+c]=UInt8(min(q,max(0,Int((Double(ap[i+c])-Double(bp[i+c])*(1-Double(q)/255)).rounded()))))}
            }
        }}}
        return .init(original:original,ink:image(g,width:original.width,height:original.height),
                     plates:image(b,width:original.width,height:original.height),exceptionalPixels:exceptional,omittedPlatePixels:omitted)
    }
    static func start(_ track:Track,at time:Double) {
        let animation=track.animation
        animation.beginTime=track.layer.convertTime(time+animation.beginTime,from:nil)
        track.layer.add(animation,forKey:track.key)
    }
    // Pure bitmap helpers mirror M10's sRGB/premultiplied contract and can run off the main actor.
    nonisolated private static func rgba(_ image:CGImage)->[UInt8] {
        var data=[UInt8](repeating:0,count:image.width*image.height*4)
        data.withUnsafeMutableBytes {p in
            let c=CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        };return data
    }
    nonisolated private static func image(_ bytes:[UInt8],width:Int,height:Int)->CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
    }
    static func transform(_ pose: MorphFlightMath.Reveal, pivot: CGPoint) -> CATransform3D {
        // Keep the existing layer anchor/position contract, including transcript handoff geometry.
        let s = pose.scale
        return CATransform3DMakeAffineTransform(CGAffineTransform(a:s,b:0,c:0,d:s,tx:pivot.x*(1-s),ty:pivot.y*(1-s)))
    }
    static func tracks(_ timeline: Timeline, layer: CALayer, poses: [MorphFlightMath.Reveal], pivot: CGPoint) -> [Track] {
        var result: [Track] = []
        // Animating the filter array also removes it at BOTH plateaus. There is no disabled,
        // zero-radius filter left on the large full-text surface while the spring keeps settling.
        let active=poses.map{$0.blurRadius>0 && $0.opacity>0}
        if active.contains(true),let gaussian=filter(radius:poses.map(\.blurRadius).max() ?? 10) {
            layer.filters=[gaussian]
            if let t=timeline.track(layer,"filters.\(name).inputRadius",poses.map{NSNumber(value:Double($0.blurRadius))}) {result.append(t)}
            // Empty-array intervals have no backwards fill. They never compete with the
            // radius channel during active filtering, and the final interval retains no filter.
            var i=0
            while i<active.count {
                if active[i] {i+=1;continue}
                let first=i
                while i<active.count && !active[i] {i+=1}
                let begin=timeline.times[first],end=i<active.count ? timeline.times[i]:timeline.duration
                let animation=CAKeyframeAnimation(keyPath:"filters")
                animation.values=[[],[]];animation.keyTimes=[0,1];animation.duration=max(1e-6,end-begin)
                animation.beginTime=begin;animation.fillMode=i==active.count ? .forwards:.removed;animation.isRemovedOnCompletion=false
                result.append(Track(layer:layer,key:"shell.m1115.clear.\(first)",animation:animation))
            }
        }
        if let t = timeline.track(layer, "transform", poses.map { NSValue(caTransform3D:transform($0,pivot:pivot)) }) { result.append(t) }
        return result
    }
}

/// At most three foreground/plate pairs, 64 MiB including their retained originals.
/// Idle eviction never removes an active animation. CPU staging can transiently hold one extra pair.
@MainActor final class ColumnRevealMaterial {
    static let byteLimit=64*1024*1024, countLimit=3
    private static var pool:[ColumnRevealMaterial]=[]
    static var retainedBytes:Int {pool.reduce(0){$0+$1.bytes}}
    static var entryCount:Int {pool.count}
    let pair:M10ColumnMatte.Pair
    weak var owner:ColumnNode?
    let root=CALayer(),ink=CALayer(),plates=CALayer()
    var ready=false,active=false
    var bytes:Int {[pair.original,pair.ink,pair.plates].reduce(0){$0+$1.bytesPerRow*$1.height}}
    private init(_ pair:M10ColumnMatte.Pair,owner:ColumnNode) {
        self.pair=pair;self.owner=owner
        for layer in [root,ink,plates] {layer.anchorPoint = .zero;layer.contentsScale=owner.scale}
        root.opacity=0
        root.bounds=CGRect(x:0,y:0,width:CGFloat(pair.original.width)/owner.scale,height:CGFloat(pair.original.height)/owner.scale)
        ink.frame=root.bounds;plates.frame=root.bounds
        ink.contents=pair.ink;plates.contents=pair.plates
        root.addSublayer(plates);root.addSublayer(ink)
        owner.transcriptClip.addSublayer(root)
    }
    static func find(_ image:CGImage,owner:ColumnNode)->ColumnRevealMaterial? {
        pool.first{$0.owner === owner && $0.pair.original === image}
    }
    static func publishStaged(owner:ColumnNode) {
        let pending=pool.filter{$0.owner === owner && !$0.ready}
        guard !pending.isEmpty else{return}
        // Publish immutable images during idle, never during the input transaction. A run-loop
        // yield alone does not prove CA has serialized the new contents. This is not a GPU fence.
        let began=CACurrentMediaTime()
        CATransaction.flush()
        owner.revealStageFlushes += 1
        owner.revealStageFlushMs += (CACurrentMediaTime()-began)*1000
        for material in pending {material.ready=true}
    }
    static func admit(_ pair:M10ColumnMatte.Pair,owner:ColumnNode)->ColumnRevealMaterial? {
        if let existing=find(pair.original,owner:owner) {return existing}
        let bytes=[pair.original,pair.ink,pair.plates].reduce(0){$0+$1.bytesPerRow*$1.height}
        guard bytes<=byteLimit else{return nil}
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        // A column keeps one current source, rather than accumulating obsolete revisions/scrolls.
        for old in pool where !old.active && (old.owner == nil || old.owner === owner) {old.root.removeFromSuperlayer()}
        pool.removeAll{!$0.active && ($0.owner == nil || $0.owner === owner)}
        while pool.count>=countLimit || retainedBytes+bytes>byteLimit {
            guard let index=pool.firstIndex(where:{!$0.active}) else{return nil}
            pool.remove(at:index).root.removeFromSuperlayer()
        }
        let material=ColumnRevealMaterial(pair,owner:owner);pool.append(material)
        return material
    }
    /// Exactly the same discrete sample boundaries, with consecutive equal values coalesced.
    static func gate(_ timeline:Timeline,layer:CALayer,values:[Int])->Track {
        var indices=[0]
        for i in 1..<max(1,values.count-1) where values[i] != values[i-1] {indices.append(i)}
        let animation=CAKeyframeAnimation(keyPath:"opacity")
        animation.values=indices.map{NSNumber(value:values[$0])}
        animation.keyTimes=indices.map{timeline.linearKeys[$0]}+[1]
        animation.duration=timeline.duration;animation.calculationMode = .discrete
        animation.fillMode = .both;animation.isRemovedOnCompletion=false
        return Track(layer:layer,key:"shell.m1115.gate",animation:animation)
    }
}

extension ColumnNode {
    /// Native capture is tiled on idle turns; pixel recovery is immutable utility work.
    func prepareRevealMattes(forms:[Double],idle:M11IdlePreparation) async throws {
        guard !Motion.reduce,MorphFlightMath.revealStyle != .slide,ownsNative,
              forms.contains(where:{let t=MorphFlightMath.transcriptOpacity(form:$0,on:true);return t>0 && t<1}) else{return}
        let images:[CGImage]=try await idle.step("reveal.matte.resolve") {
            ColumnRevealMaterial.publishStaged(owner:self)
            var seen=Set<ObjectIdentifier>()
            return snapshots.values.filter{abs(($0.key.full*scale).rounded()/scale-native.bounds.width)<0.01 && $0.transcriptSize==native.bounds.size}
                .compactMap(\.transcript).filter{$0.width>1 && ColumnRevealMaterial.find($0,owner:self)==nil && seen.insert(ObjectIdentifier($0)).inserted}
        }
        guard let image=images.first,
              image.bytesPerRow*image.height+2*image.width*image.height*4<=ColumnRevealMaterial.byteLimit else{return}
        let plate=try await idle.capture(native,scale:scale) {body in self.withMutedRevealContent(body)}
        idle.finish()
        let pair=await Task.detached(priority:.utility) {ColumnRevealFilter.split(image,plates:plate)}.value
        try await idle.step("reveal.matte.stage") {
            gaussianPlateCaptures += 1
            guard ColumnRevealMaterial.admit(pair,owner:self) != nil else{return}
            revealMattePrepared += 1
        }
        // A distinct idle slice pays publication once per pair. Cancellation keeps it ineligible
        // until a later idle retry publishes it. installReveal never assigns new image contents.
        try await idle.step("reveal.matte.publish") {ColumnRevealMaterial.publishStaged(owner:self)}
    }
    private func withMutedRevealContent(_ body:()->Void) {
        var restore:[()->Void]=[]
        let hidden=native.isHidden,layerHidden=native.layer?.isHidden,mask=native.layer?.mask
        CATransaction.begin();CATransaction.setDisableActions(true)
        native.isHidden=false;native.layer?.isHidden=false;native.layer?.mask=nil
        func mute(_ view:NSView) {
            if view.isHidden {return}
            if let text=view as? NSTextView,let storage=text.textStorage,let layout=text.layoutManager {
                let selection=text.selectedTextAttributes,link=text.linkTextAttributes,ranges=text.selectedRanges
                let keys:[NSAttributedString.Key]=[.foregroundColor,.strokeColor,.underlineStyle,.strikethroughStyle]
                let whole=NSRange(location:0,length:storage.length)
                var saved:[(NSRange,[NSAttributedString.Key:Any])]=[],index=0
                while index<storage.length {
                    var range=NSRange();let values=layout.temporaryAttributes(atCharacterIndex:index,effectiveRange:&range)
                    saved.append((NSIntersectionRange(range,whole),values.filter{keys.contains($0.key)}));index=NSMaxRange(range)
                }
                restore.append {
                    for key in keys {layout.removeTemporaryAttribute(key,forCharacterRange:whole)}
                    for (range,values) in saved {layout.addTemporaryAttributes(values,forCharacterRange:range)}
                    text.selectedTextAttributes=selection;text.linkTextAttributes=link;text.selectedRanges=ranges;text.needsDisplay=true
                }
                layout.addTemporaryAttributes([.foregroundColor:NSColor.clear,.strokeColor:NSColor.clear,.underlineStyle:0,.strikethroughStyle:0],forCharacterRange:whole)
                var selected=selection;selected[.foregroundColor]=NSColor.clear;text.selectedTextAttributes=selected
                var links=link ?? [:];links[.foregroundColor]=NSColor.clear;text.linkTextAttributes=links;text.needsDisplay=true
                return
            }
            if let label=view as? NSTextField {
                let old=label.textColor;restore.append{label.textColor=old;label.needsDisplay=true};label.textColor = .clear;label.needsDisplay=true
            } else if view is NSImageView || String(describing:type(of:view))=="NativeTranscriptMark" {
                let old=view.alphaValue;restore.append{view.alphaValue=old};view.alphaValue=0
            }
            for child in view.subviews {mute(child)}
        }
        mute(native);body()
        for undo in restore.reversed() {undo()}
        native.layer?.mask=mask;if let layerHidden {native.layer?.isHidden=layerHidden};native.isHidden=hidden
        CATransaction.commit()
    }
    /// If an interrupted form change also enters/leaves, compose the two Gaussian variances
    /// on each foreground plane. Retain M10's outer fade/zoom, but remove its filter channels:
    /// no Gaussian is nested inside another, and unfiltered plates keep their existing motion.
    func installCombinedReveal(_ asset:M10ColumnGaussianAsset,surface:M10ColumnGaussianSurface,timeline:Timeline,at time:Double) {
        guard !Motion.reduce,MorphFlightMath.revealStyle != .slide else{return}
        let forms=timeline.map{form.sample($0).value}
        guard forms.contains(where:{abs($0-forms[0])>1e-9}) else{return}
        if let group=surface.foreground.animation(forKey:"shell.m101.content")?.copy() as? CAAnimationGroup {
            group.animations=group.animations?.filter{!(($0 as? CAPropertyAnimation)?.keyPath?.hasPrefix("filters.") ?? false)}
            surface.foreground.removeAnimation(forKey:"shell.m101.content")
            surface.foreground.add(group,forKey:"shell.m101.content")
        }
        let clear=CAKeyframeAnimation(keyPath:"filters");clear.values=[[],[]];clear.keyTimes=[0,1]
        clear.duration=timeline.duration;clear.fillMode = .both;clear.isRemovedOnCompletion=false
        clear.beginTime=surface.foreground.convertTime(time,from:nil)
        surface.foreground.add(clear,forKey:"shell.m1115.outer-clear")
        for layer in asset.ink.sublayers ?? [] {
            guard let name=layer.name,name.hasPrefix("m1115.reveal.") else{continue}
            let full=name.hasSuffix("full")
            let poses=timeline.times.indices.map{i -> MorphFlightMath.Reveal in
                let p=full ? MorphFlightMath.revealPose(MorphFlightMath.transcriptOpacity(form:forms[i],on:true),full:true):MorphFlightMath.reveal(amount:1-forms[i],order:1,on:true)
                let presence=surface.effect.pose(at:time+timeline.times[i])
                return .init(opacity:p.opacity*presence.opacity,offsetY:p.offsetY,
                             blurRadius:hypot(p.blurRadius,CGFloat(presence.radius)),scale:p.scale)
            }
            let b=full ? nativeArea:briefContent.convert(briefContent.bounds,to:inkMaterial)
            for track in ColumnRevealFilter.tracks(timeline,layer:layer,poses:poses,pivot:CGPoint(x:b.midX,y:b.midY)) {
                if track.animation.keyPath == "transform" {
                    track.animation.values=poses.map{p -> NSValue in
                        var tr=ColumnRevealFilter.transform(p,pivot:CGPoint(x:b.midX,y:b.midY));tr.m42 += p.offsetY
                        return NSValue(caTransform3D:tr)
                    }
                }
                ColumnRevealFilter.start(Track(layer:track.layer,key:track.key.hasPrefix("shell.m1115.clear.") ? track.key:"shell.m1115."+track.animation.keyPath!,animation:track.animation),at:time)
            }
        }
    }
    func finishReveal() {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        for layer in [briefContent,transcript,goalText] {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("shell.m1115.") { layer.removeAnimation(forKey:key) }
            layer.filters=nil;layer.transform=CATransform3DIdentity
        }
        goalText.contents=nil;goalText.opacity=0
        if let material=revealMaterial {
            material.active=false;material.root.opacity=0
            for layer in [material.root,material.ink,material.plates] {
                layer.removeShellAnimations();layer.filters=nil;layer.transform=CATransform3DIdentity
            }
        }
    }
    func installReveal(_ timeline: Timeline, at time: Double) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        guard !Motion.reduce, MorphFlightMath.revealStyle != .slide else { return }
        let forms=timeline.map { form.sample($0).value }
        let briefPoses=forms.map { MorphFlightMath.reveal(amount:1-$0,order:1,on:true) }
        let fullPoses=forms.map { MorphFlightMath.revealPose(MorphFlightMath.transcriptOpacity(form:$0,on:true),full:true) }
        func start(_ tracks:[Track]) {
            for track in tracks {
                ColumnRevealFilter.start(Track(layer:track.layer,key:track.key.hasPrefix("shell.m1115.clear.") ? track.key:"shell.m1115."+track.animation.keyPath!,animation:track.animation),at:time)
            }
        }
        if briefPoses.contains(where:{$0.opacity>0 && $0.opacity<1}) {
            let b=briefContent.bounds
            start(ColumnRevealFilter.tracks(timeline,layer:briefContent,poses:briefPoses,pivot:CGPoint(x:b.midX,y:b.midY)))
        }
        guard fullReflow == nil,fullPoses.contains(where:{$0.opacity>0 && $0.opacity<1}),
              let value=transcript.contents,CFGetTypeID(value as CFTypeRef)==CGImage.typeID else { return }
        let original=value as! CGImage
        guard let material=ColumnRevealMaterial.find(original,owner:self),material.ready else {
            // This switch retains the original unfiltered fade. Never filter unsplit containers.
            revealMatteFallbacks += 1
            M10ColumnWorkTrace.count("reveal.matte.fallback",["id":conversation.id,"reason":"not-ready"])
            return
        }
        revealMatteHits += 1;revealMaterial=material;material.active=true
        M10ColumnWorkTrace.count("reveal.matte.hit",["id":conversation.id])
        let active=fullPoses.map{$0.opacity>0 && $0.opacity<1}
        material.root.frame=transcript.frame
        material.ink.frame=material.root.bounds;material.plates.frame=material.root.bounds
        material.root.opacity=0
        // Immutable image planes were attached during idle. Only sparse opacity keys cross the commit.
        start([ColumnRevealMaterial.gate(timeline,layer:material.root,values:active.map{$0 ? 1:0}),
               ColumnRevealMaterial.gate(timeline,layer:transcript,values:active.map{$0 ? 0:1})])
        start(ColumnRevealFilter.tracks(timeline,layer:material.ink,poses:fullPoses,pivot:CGPoint(x:nativeArea.width/2,y:nativeArea.height/2)))
    }
}
