import AppKit
import QuartzCore

/// Gaussian zoom is the default; accum remains available for comparison.
enum M10ColumnZoom: String { case accum, gauss
    static var selected: Self { Self(rawValue:ProcessInfo.processInfo.environment["M10_COLUMN_ZOOM"] ?? "gauss") ?? .gauss }
}

/// Two native drawings, not colour-keying: the second keeps backgrounds/selection/controls but mutes text.
/// Recover their source-over foreground so error/user/code plates never enter the filtered content plane.
@MainActor enum M10ColumnMatte {
    enum Channel:Int {case original, ink, plates}
    struct Pair {let original:CGImage,ink:CGImage,plates:CGImage;let exceptionalPixels:Int;let omittedPlatePixels:Int}
    static func plate(_ native:NativeTranscript,scale:CGFloat)->CGImage {
        var restore:[()->Void]=[]
        let offset=native.scrollOffset,follow=native.followsEnd
        let hidden=native.isHidden,layerHidden=native.layer?.isHidden,mask=native.layer?.mask
        CATransaction.begin();CATransaction.setDisableActions(true)
        // Same admission as ColumnNode.makeSnapshot: cacheDisplay on a hidden root otherwise gives an empty B.
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
                // Display-only overrides preserve TextKit's glyph/layout cache and never touch the attributed string.
                layout.addTemporaryAttributes([.foregroundColor:NSColor.clear,.strokeColor:NSColor.clear,.underlineStyle:0,.strikethroughStyle:0],forCharacterRange:whole)
                var selected=selection;selected[.foregroundColor] = NSColor.clear;text.selectedTextAttributes=selected
                var links=link ?? [:];links[.foregroundColor] = NSColor.clear;text.linkTextAttributes=links;text.needsDisplay=true
                return
            }
            if let label=view as? NSTextField {
                let old=label.textColor;restore.append {label.textColor=old;label.needsDisplay=true};label.textColor = .clear;label.needsDisplay=true
            } else if view is NSImageView || String(describing:type(of:view)) == "NativeTranscriptMark" {
                let old=view.alphaValue;restore.append {view.alphaValue=old};view.alphaValue=0
            }
            // Custom action buttons draw their plate and title together. Keep that small control intact on the
            // unfiltered plane, rather than silently blurring its plate or inventing another title renderer.
            for child in view.subviews {mute(child)}
        }
        mute(native)
        let result=native.snapshot(scale:scale)
        for undo in restore.reversed() {undo()}
        native.scrollOffset=offset;native.followsEnd=follow
        native.displayIfNeeded()
        native.layer?.mask=mask;if let layerHidden {native.layer?.isHidden=layerHidden};native.isHidden=hidden
        CATransaction.commit()
        return result
    }
    static func rgba(_ image:CGImage)->[UInt8] {
        let w=image.width,h=image.height
        var data=[UInt8](repeating:0,count:w*h*4)
        data.withUnsafeMutableBytes {p in
            let c=CGContext(data:p.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        };return data
    }
    static func image(_ bytes:[UInt8],width:Int,height:Int)->CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
    }
    static func split(_ original:CGImage,plates:CGImage)->Pair {
        guard original.width==plates.width,original.height==plates.height else {
            // A stale geometry must never put its plate through the foreground filter. Verification fails closed.
            let clear=image([UInt8](repeating:0,count:original.width*original.height*4),width:original.width,height:original.height)
            return Pair(original:original,ink:clear,plates:original,exceptionalPixels:original.width*original.height,omittedPlatePixels:0)
        }
        let a=rgba(original);var b=rgba(plates),g=[UInt8](repeating:0,count:a.count),exceptional=0,omitted=0
        for i in stride(from:0,to:a.count,by:4) {
            if a[i...i+3].elementsEqual(b[i...i+3]) {continue}
            let aa=Double(a[i+3])/255,ab=Double(b[i+3])/255
            // Native ranged flight hiding also clips inline-code/selection backgrounds. A cached base can
            // therefore omit an entire backing pixel of B. Its original alpha=0 proves BOTH planes are absent;
            // trim that plate pixel, rather than inventing foreground ink or recapturing the whole transcript.
            if aa==0 {omitted+=1;for c in 0..<4 {b[i+c]=0};continue}
            var alpha=ab<1 ? max(0,min(1,(aa-ab)/(1-ab))):0
            // Opaque selection/code plates do not expose foreground alpha. Find the minimal valid source-over
            // alpha; transparent native drawings use the uniquely determined alpha above.
            if ab>=1 {for c in 0..<3 {let x=Double(a[i+c])/255,y=Double(b[i+c])/255
                alpha=max(alpha,x>=y ? (x-y)/max(1e-9,1-y):(y-x)/max(1e-9,y))}}
            if aa+1/255<ab {exceptional+=1;for c in 0..<4 {b[i+c]=0};alpha=aa}
            let q=min(255,max(0,Int((alpha*255).rounded())));g[i+3]=UInt8(q)
            for c in 0..<3 {g[i+c]=UInt8(min(q,max(0,Int((Double(a[i+c])-Double(b[i+c])*(1-Double(q)/255)).rounded()))))}
        }
        return Pair(original:original,ink:image(g,width:original.width,height:original.height),plates:image(b,width:original.width,height:original.height),exceptionalPixels:exceptional,omittedPlatePixels:omitted)
    }
}

/// Prepared content-only planes; no clocks, windows, native trees or copies in the material.
@MainActor final class M10ColumnGaussianAsset {
    let ink=CALayer(),plates=CALayer()
    var tracks:[Track]=[]
    var clip:CALayer?
    var contentViolations:[String] {
        var result:[String]=[]
        func walk(_ l:CALayer) {
            if l is CAReplicatorLayer {result.append("replicator inside Gaussian content")}
            if l.delegate is NSView || String(describing:type(of:l)).lowercased().contains("glass") {result.append("native/glass tree inside Gaussian content")}
            if l.backgroundColor?.alpha ?? 0 > 0 || l.borderWidth>0 {result.append("container fill/border inside Gaussian content")}
            if l.shadowOpacity>0 || !(l.backgroundFilters ?? []).isEmpty || !(l.filters ?? []).isEmpty {result.append("live shadow/filter/backdrop inside prepared Gaussian content")}
            if l is CAShapeLayer || l is CAGradientLayer || l is CATextLayer {result.append("unflattened drawing inside Gaussian content")}
            for c in l.sublayers ?? [] {walk(c)}
        }
        walk(ink);return result
    }
    private func pixels(_ layer:CALayer)->Int {
        let own=(layer.contents as AnyObject?).flatMap {CFGetTypeID($0 as CFTypeRef)==CGImage.typeID ? ($0 as! CGImage).width*($0 as! CGImage).height:nil} ?? 0
        return own+(layer.sublayers ?? []).reduce(0){$0+pixels($1)}
    }
    var inkPixels:Int {pixels(ink)}
    var platePixels:Int {pixels(plates)}
    var inkBounds:CGRect {
        func visit(_ layer:CALayer)->CGRect {
            var r=layer.contents == nil ? CGRect.null:layer.convert(layer.bounds,to:ink)
            for child in layer.sublayers ?? [] {r=r.union(visit(child))};return r
        }
        let r=visit(ink);return r.isNull ? CGRect(x:0,y:0,width:1,height:1):r.insetBy(dx:-16,dy:-32)
    }
    init(size:CGSize) {for layer in [ink,plates] {layer.anchorPoint = .zero;layer.bounds=CGRect(origin:.zero,size:size)}}
    func append(_ bitmaps:[M10ColumnTexture.Bitmap],to root:CALayer,scale:CGFloat,material:ReplicaContainerAudit.Material = .glyph) {
        for b in bitmaps {let l=CALayer();l.anchorPoint = .zero;l.contentsScale=scale;l.frame=b.rect;l.contents=b.image
            ReplicaContainerAudit.register(l,material:material,note:material == .glyph ? "Native foreground matte, plate pixels removed, same-source baked/cropped ink":"Unfiltered plate sibling; never a replica/filter child")
            root.addSublayer(l)}
    }
}

/// One content filter and its unfiltered plate sibling. The Engine controller is retained across reversal;
/// form/reflow geometry remains in children, while the 100ms content transition uses the shared scene timestamp.
@MainActor final class M10ColumnGaussianSurface {
    let root=CALayer(),foreground=CALayer(),plates=CALayer()
    let effect:ContentGaussianTransition
    private(set) var inkPixels=0,platePixels=0
    private(set) var contentViolations:[String]=[]
    private let backingScale:CGFloat
    init(size:CGSize,pivot:CGPoint,clock:SceneClock,visible:Bool,scale:CGFloat) {
        backingScale=scale
        root.name="column.gaussian.surface";foreground.name="column.gaussian.glyphs";plates.name="column.gaussian.plates"
        for layer in [root,foreground,plates] {layer.contentsScale=scale}
        root.anchorPoint = .zero;root.bounds=CGRect(origin:.zero,size:size)
        foreground.bounds=root.bounds;foreground.anchorPoint=CGPoint(x:pivot.x/max(1,size.width),y:pivot.y/max(1,size.height));foreground.position=pivot
        plates.anchorPoint = .zero;plates.bounds=root.bounds
        root.addSublayer(plates);root.addSublayer(foreground)
        effect=ContentGaussianTransition(content:foreground,clock:clock,initiallyVisible:visible,configuration:.spotlight)
    }
    func install(_ asset:M10ColumnGaussianAsset,visible:Bool,at time:Double) {
        inkPixels=asset.inkPixels;platePixels=asset.platePixels;contentViolations=asset.contentViolations
        let pivot=foreground.position,r=asset.inkBounds
        foreground.bounds=r;foreground.anchorPoint=CGPoint(x:(pivot.x-r.minX)/r.width,y:(pivot.y-r.minY)/r.height)
        foreground.sublayers=[asset.ink];plates.sublayers=[asset.plates];root.mask=asset.clip
        let plan=effect.setVisible(visible,at:time)
        plates.removeAnimation(forKey:"shell.m101.plate-opacity")
        if let plan {
            let t=Timeline(began:time,duration:plan.duration,rate:plan.rate)
            let values=t.map {NSNumber(value:plan.pose(at:time+$0).opacity)}
            t.track(plates,"opacity",values)?.start(at:time)
        }
        plates.opacity=visible ? 1:0
        for track in asset.tracks {track.start(at:time)}
    }
    var fields:[String:Any] { ["filters":1,"copies":1,"inkPixels":inkPixels,"platePixels":platePixels,"contentViolations":contentViolations,"filterPixels":Double(foreground.bounds.width*foreground.bounds.height*backingScale*backingScale),"filterBounds":NSStringFromRect(foreground.bounds),"radiusPt":effect.configuration.radius,"duration":effect.configuration.duration,"hiddenScale":effect.configuration.hiddenScale] }
}
