import AppKit
import QuartzCore

/// All sidebar identities at the two real macOS backing scales and both palettes. Build once
/// during flight-host initialization, never on a key path or an idle repaint loop (about 1.7 MiB).
@MainActor private enum ModeRowInkAtlas {
    private static var images:[CGImage]=[]
    private(set) static var warmMilliseconds=0.0
    static var rasterCount:Int {images.count}
    static var bytes:Int {images.reduce(0) {$0+$1.bytesPerRow*$1.height}}
    static func warm() {
        guard images.isEmpty else {return}
        let began=CACurrentMediaTime()
        let paths=OrbCelestialBody.allCases.map {OrbCelestialGlyph(symbol:$0).path(in:CGRect(x:0.5,y:0.5,width:15,height:15)).cgPath}
        for name in [NSAppearance.Name.aqua,.darkAqua] {
            NSAppearance(named:name)!.performAsCurrentDrawingAppearance {
                for path in paths {for tint in OrbTint.allCases {for scale:CGFloat in [1,2] {
                    images.append(M10ModeExposure.glyphBitmap(size:CGSize(width:16,height:16),scale:scale) { _ in
                        guard let c=NSGraphicsContext.current?.cgContext else {return}
                        c.addPath(path);c.setStrokeColor(tint.color.cgColor);c.setLineWidth(15/24*2.2)
                        c.setLineCap(.round);c.setLineJoin(.round);c.strokePath()
                    })
                }}}
            }
        }
        warmMilliseconds=(CACurrentMediaTime()-began)*1000
    }
    static func image(_ identity:OrbIdentity,scale:CGFloat,appearance:NSAppearance)->CGImage {
        warm()
        let dark=appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        let index=(((dark ? 1:0)*OrbCelestialBody.allCases.count+identity.symbol.rawValue)*OrbTint.allCases.count+identity.tint.rawValue)*2+(scale>=1.5 ? 1:0)
        return images[index]
    }
}

/// M11.27's content/glass separation, with D 0.3's exact 160 ms, 6 pt and 1.15 values.
/// One Gaussian on the sidebar glyph. The glass and its container never receive a filter.
@MainActor final class ModeFlightGlyphStage {
    static func prewarmInkAtlas() {ModeRowInkAtlas.warm()}
    #if M11_MODE_SELFTEST
    static var verificationInkRasterizationCount:Int {ModeRowInkAtlas.rasterCount}
    static var verificationInkAtlas:[String:Any] {["images":ModeRowInkAtlas.rasterCount,"bytes":ModeRowInkAtlas.bytes,"warmMS":ModeRowInkAtlas.warmMilliseconds]}
    #endif
    final class Ink: NSView {
        var identity = OrbIdentity.assigned(0)
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {}
    }
    var coverageHorizontalOffset:CGFloat=0 {didSet {if coverageHorizontalOffset != oldValue {lastMaskState=nil;updateCoverage()}}}
    private(set) var coverageRevision=0
    var coverage:ModeFlightRowCoverage? {didSet {if coverage != oldValue {coverageRevision+=1;updateCoverage()}}}
    private let clipMask=CALayer(),fadeMask=CAGradientLayer()
    private struct MaskState:Equatable {let coverage:ModeFlightRowCoverage,position:CGPoint,bounds:CGRect,scale:CGFloat}
    private var lastMaskState:MaskState?
    private func updateCoverage() {
        guard let coverage,let layer=line.layer else {line.layer?.mask=nil;clipMask.removeAllAnimations();lastMaskState=nil;return}
        let scale=max(0.001,layer.transform.m11)
        let state=MaskState(coverage:coverage,position:layer.position,bounds:line.bounds,scale:scale)
        if lastMaskState == state,layer.mask === clipMask {return}
        lastMaskState=state
        clipMask.bounds=CGRect(origin:.zero,size:coverage.rect.size)
        clipMask.position=CGPoint(x:line.bounds.midX+(coverage.rect.midX+coverageHorizontalOffset-layer.position.x)/scale,
                                  y:line.bounds.midY+(coverage.rect.midY-layer.position.y)/scale)
        clipMask.transform=CATransform3DMakeScale(1/scale,1/scale,1)
        clipMask.masksToBounds=true;clipMask.backgroundColor=nil
        fadeMask.frame=clipMask.bounds
        fadeMask.startPoint=coverage.start;fadeMask.endPoint=coverage.end
        fadeMask.colors=coverage.alpha.map {CGColor(gray:1,alpha:$0)}
        fadeMask.locations=coverage.stops.map {NSNumber(value:Double($0))}
        if fadeMask.superlayer == nil {clipMask.addSublayer(fadeMask)}
        layer.mask=clipMask
    }
    /// Counter the row's server-side transform. The viewport remains fixed in window points during a stall.
    func installCoverageClock(rows:[CGRect],strengths:[Double],duration:Double,began:Double,offsets:[CGFloat]?=nil) {
        guard let coverage,let layer=line.layer,rows.count == strengths.count,!rows.isEmpty else {return}
        let scales=strengths.map {1+0.15*(1-$0)}
        func key(_ path:String,_ values:[NSNumber])->CAKeyframeAnimation {
            let animation=CAKeyframeAnimation(keyPath:path);animation.values=values;animation.duration=duration;animation.calculationMode = .linear
            return animation
        }
        let x=rows.indices.map {i in NSNumber(value:line.bounds.midX+(coverage.rect.midX+(offsets?[i] ?? 0)-rows[i].midX+3)/scales[i])}
        let y=zip(rows,scales).map {r,s in NSNumber(value:line.bounds.midY+(coverage.rect.midY-r.midY+1)/s)}
        let group=CAAnimationGroup();group.animations=[key("position.x",x),key("position.y",y),key("transform.scale",scales.map {NSNumber(value:1/$0)})]
        group.duration=duration;group.beginTime=layer.convertTime(began,from:nil);group.fillMode = .both;group.isRemovedOnCompletion=false
        clipMask.add(group,forKey:"mode.row.coverage")
    }
    let line = Ink()
    let bitmap = CALayer()
    private let gaussian: NSObject?
    private struct State:Equatable {let row:CGRect,strength:Double,depth:Double,visible:Bool}
    private var lastState:State?
    init(conversation: Conversation, in carrier: NSView) {
        line.wantsLayer = true
        // AppKit owns the backing layer's contents. A child layer owns the eagerly baked ink.
        line.layer?.addSublayer(bitmap)
        if let type = NSClassFromString("CAFilter") as? NSObject.Type {
            gaussian = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        } else { gaussian = nil }
        gaussian?.setValue("m1131RowGaussian", forKey: "name")
        gaussian?.setValue(false, forKey: "inputNormalizeEdges")
        gaussian?.setValue(0, forKey: "inputRadius")
        gaussian?.setValue(false, forKey: "enabled")
        line.layer?.filters = gaussian.map { [$0] }
        carrier.addSubview(line)
        refresh(conversation:conversation,scale:carrier.window?.backingScaleFactor ?? 2,force:true)
    }
    func refresh(conversation: Conversation,scale: CGFloat,force: Bool = false) {
        let identity=NormieDrawing.identity(conversation)
        guard force || identity != line.identity || bitmap.contentsScale != scale else { return }
        line.identity=identity
        bitmap.contents=ModeRowInkAtlas.image(identity,scale:scale,appearance:NativeDisplayOptions.appearance ?? line.effectiveAppearance)
        bitmap.contentsScale=scale;bitmap.frame=CGRect(x:0,y:0,width:16,height:16)
    }
    func sample(_ pose: ModeOrreryFlight.Pose, row: CGRect) {
        let k = pose.row, scale = 1 + 0.15 * (1-k)
        let row = row.offsetBy(dx:-3,dy:-1)
        let state=State(row:row,strength:k,depth:pose.depth,visible:pose.visible)
        if lastState == state,line.layer?.opacity == Float(k) {return}
        lastState=state
        if line.frame != row {line.frame=row}
        if bitmap.frame != line.bounds {bitmap.frame=line.bounds}
        if let layer = line.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x:row.midX,y:row.midY)
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            layer.opacity = Float(k)
            // Match the board child order: returning row ink is in front of its sharp glass.
            layer.zPosition = CGFloat(pose.depth) + 0.01
            layer.setValue(6 * (1-k), forKeyPath:"filters.m1131RowGaussian.inputRadius")
            layer.setValue(k > 0 && k < 1, forKeyPath:"filters.m1131RowGaussian.enabled")
        }
        updateCoverage()
        // Keep transparent ink mounted: the render-server clock may reach the return stage before
        // another main-thread frame. Its opacity channel, rather than isHidden, owns the quiet interval.
        line.isHidden = !pose.visible
    }
    func reset() { line.removeFromSuperview() }
}

/// Window-point viewport and the exact native gradient, including its coordinate direction.
struct ModeFlightRowCoverage:Equatable {
    let rect:CGRect,start:CGPoint,end:CGPoint,alpha:[CGFloat],stops:[CGFloat]
}
