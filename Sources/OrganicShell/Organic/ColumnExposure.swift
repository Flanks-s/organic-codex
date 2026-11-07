import AppKit
import QuartzCore

/// M10-D. No sampling clock lives here: the column's original springs supply every pose. In particular a trail
/// never moves the sharp leading edge, changes the spring, or substitutes for a missing display frame.
struct M10ColumnExposure {
    @MainActor static var diagnostics = false
    @MainActor static func colorTrack(_ timeline:Timeline,on layer:CAReplicatorLayer,samples:[ExposureSample])->Track? {
        // The compensated RGB is 1/alpha. Interpolating it separately from alpha can overshoot above white
        // between keys. Count and its equal weights must change on the same (at least 120Hz) key boundary.
        timeline.track(layer,"instanceColor",samples.map{$0.instanceColor},discrete:true)
    }
    @MainActor static func start(_ track:Track,at time:Double,frameInterval:Double? = nil) {
        // Keep the scene's existing scheduling policy. Exposure uses the actual display profile for physics;
        // it must not change the compositor's frame-rate hint (including in the sharp control run).
        guard track.key.hasPrefix("shell.m10-prefix|") else {track.start(at:time);return}
        let parts=track.key.split(separator:"|",maxSplits:2)
        let prefix=parts.count>1 ? Double(parts[1]) ?? 0:0
        track.animation.beginTime=track.layer.convertTime(time-prefix,from:nil)
        track.layer.add(track.animation,forKey:track.key)
    }
    static let spacing: CGFloat = 0.75 // temporal copies on a curved/accelerating path have room below the 1.5pt limit
    static func sample(_ now: CGRect, _ earlier: CGRect, profile: DisplayProfile, settings: ExposureSettings) -> ExposureSample {
        var settings = settings
        settings.spacing = spacing; settings.maxCopies = 2048
        let enabled = settings.enabled; settings.enabled = true
        var sample = ExposureSample(now: now, earlier: earlier, frameInterval: profile.frameInterval,
                                    mmPerPoint: profile.mmPerPoint, settings: settings)
        if sample.gate>0,sample.count==1 {sample.count=2;sample.alpha=CGFloat(1-sqrt(0.1*Double(sample.gate)));sample.delayStep=Double(sample.gate)*settings.shutter*profile.frameInterval}
        if !enabled { sample.count = 1; sample.alpha = 1; sample.delayStep = 0; sample.length = 0; sample.gate = 0 }
        return sample
    }
    /// Exact box convolution in the direction of the sweep. If the source is thinner than the exposure (a separator),
    /// its peak becomes width/length: stretching a 1px line at unchanged alpha would manufacture a bright fence.
    struct Sweep {
        var frame: CGRect
        var locations: [NSNumber]
        var peak: CGFloat
        var length: CGFloat
        static func make(_ now: CGRect, earlier: CGRect, gate: CGFloat) -> Self {
            let back = (earlier.minX - now.minX) * gate
            let rightBack = (earlier.maxX - now.maxX) * gate
            let length = max(abs(back), abs(rightBack))
            guard length > 0 else { return .init(frame: now, locations: [0,0,1,1], peak: 1, length: 0) }
            let a = min(now.minX, now.minX + back), b = max(now.maxX, now.maxX + rightBack)
            let extent = max(0.001, b - a)
            let leftRamp = min(now.width, abs(back)), rightRamp = min(now.width, abs(rightBack))
            return .init(frame: CGRect(x: a, y: now.minY, width: extent, height: now.height),
                         locations: [0, NSNumber(value: Double(leftRamp / extent)), NSNumber(value: Double(1-rightRamp / extent)), 1],
                         peak: min(1, now.width / max(0.001,length)), length: length)
        }
    }
    static func colors(_ color: CGColor, peak: CGFloat) -> [CGColor] {
        let c = NSColor(cgColor: color) ?? .white
        return [c.withAlphaComponent(0).cgColor, c.withAlphaComponent(c.alphaComponent * peak).cgColor,
                c.withAlphaComponent(c.alphaComponent * peak).cgColor, c.withAlphaComponent(0).cgColor]
    }
    /// instanceDelay follows time, but the gate is a spatial coverage requirement. During deceleration g*dt is
    /// shorter than g times the whole frame's sweep. Find the actual time back on the unchanged scale trajectory,
    /// then check every real adjacent pair rather than reporting only an average spacing.
    static func pathSample(at time:Double,profile:DisplayProfile,settings:ExposureSettings,pose:(Double)->CGRect) -> ExposureSample {
        let now=pose(time),dt=profile.frameInterval*settings.shutter
        var sample=sample(now,pose(time-dt),profile:profile,settings:settings)
        guard sample.count>1 else{return sample}
        var lo=0.0,hi=dt
        for _ in 0..<24 {let mid=(lo+hi)/2;if MotionStep.edge(now,pose(time-mid))<sample.length {lo=mid}else{hi=mid}}
        for _ in 0..<4 {
            let delay=hi/Double(sample.count-1)
            var previous=now,gap:CGFloat=0
            for k in 1..<sample.count {let next=pose(time-Double(k)*delay);gap=max(gap,MotionStep.edge(previous,next));previous=next}
            if gap<=1.5 {sample.delayStep=delay;break}
            sample.count=max(sample.count+1,Int(ceil(Double(sample.count)*Double(gap/1.49))))
        }
        sample.alpha=CGFloat(1-pow(0.1*Double(sample.gate),1/Double(sample.count)))
        return sample
    }
}

/// A recorded sample of the actual material treatment; reused by scene self-test, never inferred from rendered FPS.
struct M10ColumnFrame {
    let id: String
    let rect: CGRect
    let sample: ExposureSample
    var treatment: String
    var adjacentSpacing: CGFloat? = nil
    var coveredLength: CGFloat? = nil
    var usesCopies: Bool { treatment.contains("accumulation") }
    var spacing: CGFloat { adjacentSpacing ?? (usesCopies && sample.count > 1 ? sample.length / CGFloat(sample.count-1) : 0) }
    var fields: [String: Any] {
        ["id": id, "rect": NSStringFromRect(rect), "stepPt": sample.stepPt, "gate": sample.gate,
         "lengthPt": sample.length, "coveredLengthPt": coveredLength ?? sample.length,
         "copies": usesCopies ? sample.count:1, "spacingPt": spacing, "treatment": treatment]
    }
}

struct M10ColumnPlan {
    let times: [Double]
    let materials: [String: [M10ColumnFrame]]
    func frames(at time: Double) -> [M10ColumnFrame] {
        guard !times.isEmpty else { return [] }
        var lo=0, hi=times.count-1
        while lo<hi { let m=(lo+hi)/2; if times[m]<time { lo=m+1 } else { hi=m } }
        if lo>0,abs(times[lo-1]-time)<abs(times[lo]-time) { lo-=1 }
        return materials.keys.sorted().compactMap { materials[$0]?[lo] }
    }
}

/// A model-layer bake: no NSView display/layout, no render-server masks or gradients per replica.
@MainActor enum M10ColumnTexture {
    struct Bitmap { let image: CGImage; let rect: CGRect }
    static func clone(_ layer:CALayer,into copies:inout [ObjectIdentifier:CALayer])->CALayer {
        let out:CALayer
        if let gradient=layer as? CAGradientLayer {
            let g=CAGradientLayer();g.colors=gradient.colors;g.locations=gradient.locations;g.startPoint=gradient.startPoint;g.endPoint=gradient.endPoint;g.type=gradient.type;out=g
        } else if let shape=layer as? CAShapeLayer {
            let g=CAShapeLayer();g.path=shape.path;g.fillColor=shape.fillColor;g.strokeColor=shape.strokeColor;g.lineWidth=shape.lineWidth;g.lineCap=shape.lineCap;g.lineJoin=shape.lineJoin;g.fillRule=shape.fillRule;out=g
        } else {out=CALayer()}
        // init(layer:) is a presentation-layer hook, NOT a model-layer copy (it returns zero bounds/nil ink).
        out.anchorPoint=layer.anchorPoint;out.bounds=layer.bounds;out.position=layer.position;out.transform=layer.transform
        out.sublayerTransform=layer.sublayerTransform;out.isGeometryFlipped=layer.isGeometryFlipped
        out.opacity=layer.opacity;out.isHidden=layer.isHidden;out.masksToBounds=layer.masksToBounds
        out.cornerRadius=layer.cornerRadius;out.cornerCurve=layer.cornerCurve
        out.backgroundColor=layer.backgroundColor;out.borderColor=layer.borderColor;out.borderWidth=layer.borderWidth
        out.contents=layer.contents;out.contentsRect=layer.contentsRect;out.contentsCenter=layer.contentsCenter
        out.contentsScale=layer.contentsScale;out.contentsGravity=layer.contentsGravity
        out.minificationFilter=layer.minificationFilter;out.magnificationFilter=layer.magnificationFilter
        copies[ObjectIdentifier(layer)]=out;out.delegate=nil;out.removeAllAnimations();out.sublayers=[]
        out.mask=layer.mask.map { clone($0,into:&copies) }
        for child in layer.sublayers ?? [] {out.addSublayer(clone(child,into:&copies))}
        return out
    }
    static func bake(_ layer: CALayer, scale: CGFloat) -> [Bitmap] {
        // render(in:) uses contentsAreFlipped(), which includes ancestor parity. The bitmap context below
        // has top-down layer coordinates; give this detached tree the corresponding flipped ancestor too.
        // Copying isGeometryFlipped alone misses that inherited state and mirrors CGImage ink inside each band.
        precondition(layer.superlayer == nil,"bake expects a detached model tree")
        let context=CALayer();context.isGeometryFlipped=true;context.addSublayer(layer)
        defer {layer.removeFromSuperlayer();withExtendedLifetime(context) {}}
        func visual(_ l:CALayer)->CGRect {
            guard !l.isHidden,l.opacity>0 else{return .null}
            var r=CGRect.null
            if l.contents != nil || (l.backgroundColor?.alpha ?? 0)>0 || l.borderWidth>0 {r=l.bounds}
            if let shape=l as? CAShapeLayer,let path=shape.path {r=r.union(path.boundingBoxOfPath.insetBy(dx:-shape.lineWidth/2,dy:-shape.lineWidth/2))}
            for child in l.sublayers ?? [] {let b=visual(child);if !b.isNull {r=r.union(child.convert(b,to:l))}}
            return l.masksToBounds ? r.intersection(l.bounds):r
        }
        let ink=visual(layer).intersection(layer.bounds)
        guard !ink.isNull,!ink.isEmpty else{return []}
        let originX=floor(ink.minX*scale)/scale,originY=floor(ink.minY*scale)/scale
        let box=CGRect(x:originX,y:originY,width:ceil(ink.maxX*scale)/scale-originX,height:ceil(ink.maxY*scale)/scale-originY)
        let w=max(1,Int(round(box.width*scale))),h=max(1,Int(round(box.height*scale)))
        guard let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                              space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
              let data=c.data else {return []}
        c.translateBy(x:0,y:CGFloat(h));c.scaleBy(x:scale,y:-scale);c.translateBy(x:-box.minX,y:-box.minY);layer.render(in:c)
        let p=data.assumingMemoryBound(to:UInt8.self)
        var spans=[(x0:Int,x1:Int)](repeating:(w,0),count:h)
        for y in 0..<h {for x in 0..<w where p[(y*w+x)*4+3]>0 {spans[y].x0=min(spans[y].x0,x);spans[y].x1=max(spans[y].x1,x+1)}}
        var out:[Bitmap]=[], y=0
        while y<h {
            if spans[y].x1==0 {y+=1;continue}
            let y0=y;var x0=w,x1=0,last=y
            // Split on two empty backing rows (or 128pt): do not copy the blank height between lyric lines,
            // header and brief. Every nonzero-alpha source pixel remains at its original 1x/2x resolution.
            while y<h && y-y0<Int(128*scale) {
                if spans[y].x1>0 {x0=min(x0,spans[y].x0);x1=max(x1,spans[y].x1);last=y}
                else if y-last>=2 {break}
                y+=1
            }
            let height=last-y0+1
            // CGImage.cropping retains the full canvas row stride/provider. Materialize truly tight immutable
            // storage, not a small logical image backed by wide rows that still need copying/uploading.
            let width=x1-x0,rowBytes=width*4
            var bytes=Data(count:rowBytes*height)
            bytes.withUnsafeMutableBytes { destination in
                for row in 0..<height {destination.baseAddress!.advanced(by:row*rowBytes).copyMemory(from:p.advanced(by:((y0+row)*w+x0)*4),byteCount:rowBytes)}
            }
            if let provider=CGDataProvider(data:bytes as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:rowBytes,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) {
                out.append(Bitmap(image:image,rect:CGRect(x:box.minX+CGFloat(x0)/scale,y:box.minY+CGFloat(y0)/scale,width:CGFloat(x1-x0)/scale,height:CGFloat(height)/scale)))
            }
            y=max(y,last+1)
        }
        return out
    }
}

/// A structural GPU cost gate, independent of how fast prepare() runs on the CPU. Count the peak keyframe
/// multiplicity of each tight quad and its immutable source pixels. An empty padded texture costs just as much
/// bandwidth as an opaque one. Model opacity zero is not a reason to skip a layer with an active opacity track.
@MainActor struct M10ColumnRenderBudget {
    static let pixelLimit = 32.0 * 1024 * 1024
    var limit=Self.pixelLimit
    var replicatedPixels = 0.0, sourcePixels = 0.0
    var replicas = 0, textures = 0, maxCopies = 1, sourceEvaluations = 0, violations: [String] = []
    var fields: [String: Any] { ["replicatedPixels":replicatedPixels,"sourcePixels":sourcePixels,"replicas":replicas,"sourceEvaluations":sourceEvaluations,"maxCopies":maxCopies,"textures":textures,"violations":violations,"limit":limit] }
    static func inspect(_ root: CALayer, scale: CGFloat, frameInterval:Double = 1/120) -> Self {
        var result = Self()
        // Fixed throughput budget: 32 MiPixels at 120 Hz; a 60 Hz frame has twice the rendering time.
        result.limit=Self.pixelLimit*frameInterval/(1/120.0)
        func peak(_ layer: CALayer, _ key: String, _ initial: Double) -> Double {
            var value=initial
            for name in layer.animationKeys() ?? [] {
                guard let a=layer.animation(forKey:name) as? CAKeyframeAnimation,a.keyPath==key else{continue}
                value=max(value,(a.values ?? []).compactMap{($0 as? NSNumber)?.doubleValue}.max() ?? 0)
            };return value
        }
        func ink(_ l: CALayer) -> Double {
            guard !l.isHidden,peak(l,"opacity",Double(l.opacity))>0 else{return 0}
            let name=String(describing:type(of:l))
            if l.mask != nil {result.violations.append("replicated live mask: "+name)}
            if l.shadowOpacity>0 {result.violations.append("replicated live shadow: "+name)}
            if !(l.filters ?? []).isEmpty || !(l.backgroundFilters ?? []).isEmpty {result.violations.append("replicated live filter: "+name)}
            if l.delegate is NSView || name.lowercased().contains("glass") || name.lowercased().contains("backdrop") {result.violations.append("replicated native/backdrop: "+name)}
            if l is CAShapeLayer || l is CATextLayer || l is CAGradientLayer {result.violations.append("replicated unflattened drawing: "+name)}
            var pixels=0.0
            if let contents=l.contents,CFGetTypeID(contents as CFTypeRef)==CGImage.typeID {
                let image=contents as! CGImage
                let storage=CFDataGetLength(image.dataProvider!.data!)
                pixels=max(Double(image.width*image.height),Double(max(storage,image.bytesPerRow*image.height))/4);result.textures+=1
                if image.bytesPerRow>image.width*4+63 || storage>image.bytesPerRow*image.height+63 {result.violations.append("replicated retained source canvas/stride") }
                if CGFloat(image.width)+0.01<l.bounds.width*scale || CGFloat(image.height)+0.01<l.bounds.height*scale {result.violations.append("texture backing scale reduced") }
            }
            return pixels+(l.sublayers ?? []).reduce(0){$0+ink($1)}
        }
        func walk(_ l:CALayer) {
            guard !l.isHidden,peak(l,"opacity",Double(l.opacity))>0 else{return}
            if let r=l as? CAReplicatorLayer {
                let n=Int(peak(r,"instanceCount",Double(r.instanceCount)))
                if n>1 {
                    result.replicas+=n;result.maxCopies=max(result.maxCopies,n)
                    result.replicatedPixels+=Double(r.bounds.width*r.bounds.height*scale*scale)*Double(n)
                    result.sourcePixels+=(r.sublayers ?? []).reduce(0){$0+ink($1)}*Double(n)
                    func animations(_ l:CALayer)->Int {
                        (l.animationKeys()?.count ?? 0)+(l.sublayers ?? []).reduce(0){$0+animations($1)}
                    }
                    let clocks=peak(r,"instanceDelay",r.instanceDelay)>0 ? n:1
                    result.sourceEvaluations += clocks*(r.sublayers ?? []).reduce(0){$0+animations($1)}
                }
            }
            for child in l.sublayers ?? [] {walk(child)}
        }
        walk(root)
        if result.sourceEvaluations>128 {result.violations.append("per-copy source timeline evaluation budget exceeds 128")}
        if max(result.replicatedPixels,result.sourcePixels)>result.limit {result.violations.append("replica pixel-rate budget exceeds 4 GiPixels/s")}
        return result
    }
}

/// A server-side spatial exposure of the same zoom path. No per-copy animation clock: all instances share one
/// frozen texture evaluation. Uniform-scale poses lie on the same homothetic path; the oldest/current endpoints
/// are retained. As with ChordTrail, geometric steps compound exactly, rather than replaying an animation tree.
@MainActor struct M10ColumnInkTile {
    let trail: CAReplicatorLayer, ink: CALayer
    let tracks: [Track], frames: [[String: Any]], peakCopies: Int
    static func make(_ bitmap:M10ColumnTexture.Bitmap,scale:CGFloat,prototype:CALayer,source:CALayer,tracks:[Track],materialOpacity:CAKeyframeAnimation? = nil,materialAlpha:Double = 1,clipWidth:CAKeyframeAnimation? = nil)->Self {
        let trail=CAReplicatorLayer(),ink=CALayer(),r=bitmap.rect
        trail.name="column.baked-ink";trail.anchorPoint = .zero;trail.contentsScale=scale
        trail.bounds=CGRect(origin:.zero,size:r.size);trail.position=r.origin;trail.opacity=0
        ink.name="column.texture";ink.contentsScale=scale;ink.bounds=CGRect(origin:.zero,size:r.size)
        ink.anchorPoint=CGPoint(x:-r.minX/r.width,y:-r.minY/r.height);ink.position=CGPoint(x:-r.minX,y:-r.minY)
        ink.contents=bitmap.image;ink.opacity=source.opacity;ink.transform=source.transform;trail.addSublayer(ink)
        let originals=tracks.filter{$0.layer===prototype || $0.layer===source}
        func original(_ layer:CALayer,_ path:String)->Track? {originals.first{$0.layer===layer && $0.animation.keyPath==path}}
        let transform=original(source,"transform"),opacity=original(source,"opacity")?.animation
        let prefix=transform.flatMap{Double($0.key.split(separator:"|").dropFirst().first ?? "0")} ?? 0
        let matrices=transform?.animation.values?.map{CATransform3DGetAffineTransform(($0 as! NSValue).caTransform3DValue)} ?? []
        let matrixKeys=transform?.animation.keyTimes?.map(\.doubleValue) ?? [],md=transform?.animation.duration ?? 1
        let ps=opacity?.values?.map{($0 as! NSNumber).doubleValue} ?? [],pkeys=opacity?.keyTimes?.map(\.doubleValue) ?? [],pd=opacity?.duration ?? 1
        func interval(_ x:Double,_ keys:[Double])->(Int,CGFloat) {
            var lo=0,hi=keys.count-1
            while lo<hi {let m=(lo+hi)/2;if keys[m]<x {lo=m+1}else{hi=m}}
            let i=max(1,lo),k=min(1,max(0,(x-keys[i-1])/max(1e-12,keys[i]-keys[i-1])))
            return(i,CGFloat(k))
        }
        func mix(_ a:CGAffineTransform,_ b:CGAffineTransform,_ k:CGFloat)->CGAffineTransform {
            CGAffineTransform(a:a.a+(b.a-a.a)*k,b:0,c:0,d:a.d+(b.d-a.d)*k,tx:a.tx+(b.tx-a.tx)*k,ty:a.ty+(b.ty-a.ty)*k)
        }
        func matrix(_ t:Double)->CGAffineTransform {
            guard matrices.count>1 else{return CATransform3DGetAffineTransform(source.transform)}
            let(i,k)=interval(min(1,max(0,(t+prefix)/md)),matrixKeys)
            return mix(matrices[i-1],matrices[min(i,matrices.count-1)],k)
        }
        let extra=materialOpacity?.values?.map{($0 as! NSNumber).doubleValue} ?? [],extraKeys=materialOpacity?.keyTimes?.map(\.doubleValue) ?? [],extraDuration=materialOpacity?.duration ?? 1
        let widths=clipWidth?.values?.map{($0 as! NSValue).rectValue.width} ?? [],widthKeys=clipWidth?.keyTimes?.map(\.doubleValue) ?? [],widthDuration=clipWidth?.duration ?? 1
        func p(_ t:Double)->Double {
            var base=Double(source.opacity),part=materialAlpha
            if ps.count>1 {let(i,k)=interval(min(1,max(0,(t+prefix)/pd)),pkeys);base=ps[i-1]+(ps[min(i,ps.count-1)]-ps[i-1])*Double(k)}
            if extra.count>1 {let(i,k)=interval(min(1,max(0,t/extraDuration)),extraKeys);part=extra[i-1]+(extra[min(i,extra.count-1)]-extra[i-1])*Double(k)}
            return min(1,max(0,base*part))
        }
        func crop(_ t:Double)->CGFloat {
            guard widths.count>1 else{return 1}
            let(i,k)=interval(min(1,max(0,t/widthDuration)),widthKeys),w=widths[i-1]+(widths[min(i,widths.count-1)]-widths[i-1])*k
            return min(1,max(0,(w-r.minX)/r.width))
        }
        let count=original(prototype,"instanceCount")?.animation,delay=original(prototype,"instanceDelay")?.animation,color=original(prototype,"instanceColor")?.animation
        let opacityTrack=original(prototype,"opacity")
        let keys=count?.keyTimes ?? [0,1],duration=count?.duration ?? 1
        let oldCounts=count?.values?.map{($0 as! NSNumber).intValue} ?? [1],oldDelays=delay?.values?.map{($0 as! NSNumber).doubleValue} ?? [0]
        let gates=opacityTrack?.animation.values?.map{($0 as! NSNumber).doubleValue} ?? [0]
        let colors=color?.values ?? []
        func n(_ i:Int)->Int {i<oldCounts.count ? oldCounts[i]:1}
        func tau(_ i:Int)->Double {Double(max(0,n(i)-1))*(i<oldDelays.count ? oldDelays[i]:0)}
        func gate(_ i:Int)->CGFloat {CGFloat(i<gates.count ? gates[i]:0)}
        // A subpixel guard covers linear-key interpolation error; it extends the OLD end, never moves the front.
        // It vanishes with the gate. No reduction in shutter duration or backing resolution.
        func guardLength(_ i:Int)->CGFloat {
            gate(i)>0 ? max(0.03,0.125*gate(i)):0
        }
        func endpoints(_ i:Int)->(CGAffineTransform,CGAffineTransform,Double,Double) {
            let t=keys[i].doubleValue*duration,a=matrix(t),b=matrix(t-tau(i))
            let L=MotionStep.edge(r.applying(a),r.applying(b)),k=1+guardLength(i)/max(0.001,L)
            return(a,mix(a,b,k),p(t),min(1,max(0,p(t)+(p(t-tau(i))-p(t))*Double(k))))
        }
        var copies=8
        for i in keys.indices where n(i)>1 {let(a,b,_,_)=endpoints(i);copies=max(copies,Int(ceil(MotionStep.edge(r.applying(a),r.applying(b))/1.25))+1)}
        var counts:[NSNumber]=[],poses:[CGAffineTransform]=[],steps:[CGAffineTransform]=[],alphas:[NSNumber]=[],offsets:[NSNumber]=[],tints:[CGColor]=[],crops:[NSValue]=[],frames:[[String:Any]]=[]
        func copyRects(_ a:CGAffineTransform,_ step:CGAffineTransform,_ count:Int)->[CGRect] {
            var result=[r.applying(a)]
            let global=CGAffineTransform(a:step.a,b:0,c:0,d:step.d,tx:step.tx-(step.a-1)*r.minX,ty:step.ty-(step.d-1)*r.minY)
            for _ in 1..<count {result.append(result.last!.applying(global))};return result
        }
        func spatialStep(_ from:CGAffineTransform,_ to:CGAffineTransform,_ amount:Int)->CGAffineTransform {
            guard amount>1 else{return .identity}
            let x=to.a/from.a,y=to.d/from.d,q=CGFloat(amount-1),sx=pow(max(0.001,x),1/q),sy=pow(max(0.001,y),1/q)
            func sum(_ r:CGFloat,_ total:CGFloat)->CGFloat {abs(r-1)<1e-8 ? q:(total-1)/(r-1)}
            return CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:(to.tx-x*from.tx)/sum(sx,x)+(sx-1)*r.minX,ty:(to.ty-y*from.ty)/sum(sy,y)+(sy-1)*r.minY)
        }
        func adjacent(_ a:CGAffineTransform,_ local:CGAffineTransform)->CGFloat {
            let step=CGAffineTransform(a:local.a,b:0,c:0,d:local.d,tx:local.tx-(local.a-1)*r.minX,ty:local.ty-(local.d-1)*r.minY)
            let q=CGFloat(copies-1),sx=pow(step.a,q),sy=pow(step.d,q)
            func sum(_ r:CGFloat,_ total:CGFloat)->CGFloat {abs(r-1)<1e-8 ? q:(total-1)/(r-1)}
            let total=CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:step.tx*sum(step.a,sx),ty:step.ty*sum(step.d,sy))
            let first=r.applying(a),last=first.applying(total)
            return max(MotionStep.edge(first,first.applying(step)),MotionStep.edge(last.applying(step.inverted()),last))
        }
        // Geometric steps need fewer samples than delayed playback. Spend the permitted spacing budget, with
        // a 0.10pt reserve for key interpolation. Audit the actual first/last adjacent pair (the extrema of a
        // uniform-scale chord), including quarter keys, rather than assuming totalLength / (count-1).
        while true {
            let ss=keys.indices.map {i -> CGAffineTransform in let(a,b,_,_)=endpoints(i);return spatialStep(a,b,n(i)>1 ? copies:1)}
            var largest:CGFloat=0
            for i in keys.indices where n(i)>1 {
                largest=max(largest,adjacent(matrix(keys[i].doubleValue*duration),ss[i]))
                if i+1<keys.count {for f in [CGFloat(0.25),0.5,0.75] {
                    let t=(keys[i].doubleValue+(keys[i+1].doubleValue-keys[i].doubleValue)*Double(f))*duration
                    largest=max(largest,adjacent(matrix(t),mix(ss[i],ss[i+1],f)))
                }}
            }
            if largest<=1.4 {break};copies+=1
        }
        for i in keys.indices {
            let amount=n(i)>1 ? copies:1,t=keys[i].doubleValue*duration,(now,old,pNow,pOld)=endpoints(i)
            let from=now,to=old,pMax=max(pNow,pOld)
            var tint=ExposureSample.still;tint.alpha=pMax>1e-9 ? CGFloat(pNow/pMax):1
            let packed=tint.instanceColor,startAlpha=Double(packed.alpha),endAlpha=pMax>1e-9 ? pOld/pMax:1
            let step=spatialStep(from,to,amount)
            let offset=amount>1 ? (endAlpha-startAlpha)/Double(amount-1):0
            var target=1.0
            let oldAlpha=i<colors.count ? Double((colors[i] as! CGColor).alpha):1
            if n(i)>1 {for j in 0..<n(i) {target *= 1-oldAlpha*p(t-tau(i)*Double(j)/Double(n(i)-1))}}
            else {target=1-pNow}
            var lo=0.0,hi=1.0
            let values=(0..<amount).map{pMax*(startAlpha+Double($0)*offset)}
            for _ in 0..<28 {let a=(lo+hi)/2,v=values.reduce(1.0){$0*(1-a*$1)};if v>target {lo=a}else{hi=a}}
            poses.append(from);steps.append(step);tints.append(packed);crops.append(NSValue(rect:CGRect(x:0,y:0,width:crop(t),height:1)));counts.append(NSNumber(value:amount));alphas.append(NSNumber(value:amount>1 ? (lo+hi)/2*pMax:pNow));offsets.append(NSNumber(value:offset))
            if M10ColumnExposure.diagnostics {
                let actual=copyRects(from,step,amount),spacing=zip(actual,actual.dropFirst()).map{MotionStep.edge($0,$1)}.max() ?? 0
                frames.append(["time":t,"rect":NSStringFromRect(r),"copies":amount,"referenceCopies":n(i),"interval":tau(i),"referenceInterval":tau(i),"spacingPt":spacing,
                               "coveredLengthPt":MotionStep.edge(actual.first!,actual.last!),"referenceLengthPt":MotionStep.edge(r.applying(matrix(t)),r.applying(matrix(t-tau(i)))),"guardPt":guardLength(i),"sourcePixels":bitmap.image.width*bitmap.image.height,"targetTransmission":target])
            }
        }
        if M10ColumnExposure.diagnostics {
            for i in 0..<(keys.count-1) where counts[i].intValue>1 {
                for f in [CGFloat(0.25),0.5,0.75] {
                    let t=(keys[i].doubleValue+(keys[i+1].doubleValue-keys[i].doubleValue)*Double(f))*duration
                    let a=matrix(t),s=mix(steps[i],steps[i+1],f),actual=copyRects(a,s,counts[i].intValue),exposure=tau(i)+(tau(i+1)-tau(i))*Double(f)
                    frames.append(["time":t,"rect":NSStringFromRect(r),"copies":counts[i].intValue,"referenceCopies":n(i),"interval":exposure,"referenceInterval":exposure,
                                   "spacingPt":zip(actual,actual.dropFirst()).map{MotionStep.edge($0,$1)}.max() ?? 0,"coveredLengthPt":MotionStep.edge(actual.first!,actual.last!),
                                   "referenceLengthPt":MotionStep.edge(r.applying(matrix(t)),r.applying(matrix(t-exposure))),"guardPt":guardLength(i)+(guardLength(i+1)-guardLength(i))*f,"sourcePixels":bitmap.image.width*bitmap.image.height])
                }
            }
        }
        var result:[Track]=[]
        func add(_ layer:CALayer,_ path:String,_ values:[Any],discrete:Bool=false) {
            let a=CAKeyframeAnimation(keyPath:path);a.values=discrete ? Array(values.dropLast()):values;a.keyTimes=keys;a.duration=duration
            a.calculationMode=discrete ? .discrete:.linear;a.fillMode = .both;a.isRemovedOnCompletion=false
            result.append(Track(layer:layer,key:"shell."+path,animation:a))
        }
        if widths.count>1 {
            let clipped=poses.indices.map { i -> NSValue in
                let q=crops[i].rectValue.width;var m=poses[i];m.tx += m.a*(1-q)*r.minX;m.a *= q
                return NSValue(caTransform3D:CATransform3DMakeAffineTransform(m))
            }
            add(ink,"transform",clipped);add(ink,"contentsRect",crops)
        } else if let transform {result.append(Track(layer:ink,key:transform.key,animation:transform.animation.copy() as! CAKeyframeAnimation))}
        else {ink.transform=source.transform}
        add(ink,"opacity",alphas)
        add(trail,"instanceCount",counts,discrete:true);add(trail,"instanceTransform",steps.map{NSValue(caTransform3D:CATransform3DMakeAffineTransform($0))})
        add(trail,"instanceAlphaOffset",offsets,discrete:true);add(trail,"instanceColor",tints,discrete:true)
        if let t=opacityTrack {result.append(Track(layer:trail,key:t.key,animation:t.animation.copy() as! CAKeyframeAnimation))}
        // RGB is precompensated once by ExposureSample; scalar alpha offsets operate on its packed white.
        // Count, base colour and offsets change together. The source transform is the ORIGINAL current-pose track.
        trail.instanceDelay=0;trail.instanceColor=NSColor.white.cgColor
        return Self(trail:trail,ink:ink,tracks:result,frames:frames,peakCopies:copies)
    }
}


/// Solids are an analytic four-edge convolution, never repeated transparent full-column quads. Horizontal and
/// vertical ramps cover the full zoom sweep; a single rounded mask keeps the original card's material boundary.
@MainActor final class M10ColumnSolidZoom {
    let layer=CAGradientLayer()
    private let vertical=CAGradientLayer()
    init() {
        layer.anchorPoint = .zero;layer.startPoint=CGPoint(x:0,y:0.5);layer.endPoint=CGPoint(x:1,y:0.5)
        layer.cornerCurve = .continuous;layer.masksToBounds=true;layer.opacity=0
        vertical.anchorPoint = .zero;vertical.startPoint = .zero;vertical.endPoint=CGPoint(x:0,y:1)
        vertical.colors=[NSColor.clear.cgColor,NSColor.black.cgColor,NSColor.black.cgColor,NSColor.clear.cgColor];layer.mask=vertical
    }
    func tracks(_ timeline:Timeline,poses:[(CGRect,CGRect,CGFloat)],colors:[CGColor],opacities:[Double])->[Track] {
        let boxes=poses.map{$0.0.union($0.1)}
        func locations(_ a:CGFloat,_ b:CGFloat,_ width:CGFloat)->[NSNumber] {[0,NSNumber(value:Double(min(0.5,max(0,a)/max(1e-9,width)))),NSNumber(value:Double(1-min(0.5,max(0,b)/max(1e-9,width)))),1]}
        let xs=poses.indices.map{i in let inner=poses[i].0.intersection(poses[i].1),r=boxes[i];return locations(inner.minX-r.minX,r.maxX-inner.maxX,r.width)}
        let ys=poses.indices.map{i in let inner=poses[i].0.intersection(poses[i].1),r=boxes[i];return locations(inner.minY-r.minY,r.maxY-inner.maxY,r.height)}
        var out:[Track]=[]
        func add(_ l:CALayer,_ key:String,_ values:[Any]) {out.appendIf(timeline.track(l,key,values))}
        layer.frame=boxes.last!;layer.locations=xs.last!;layer.colors=M10ColumnExposure.colors(colors.last!,peak:1)
        layer.cornerRadius=poses.last!.2;layer.opacity=0;vertical.frame=layer.bounds;vertical.locations=ys.last!
        add(layer,"position",boxes.map{NSValue(point:$0.origin)})
        add(layer,"bounds",boxes.map{NSValue(rect:CGRect(origin:.zero,size:$0.size))})
        add(layer,"locations",xs);add(layer,"colors",colors.map{M10ColumnExposure.colors($0,peak:1)})
        add(layer,"cornerRadius",poses.map{NSNumber(value:Double($0.2))});add(layer,"opacity",opacities.map{NSNumber(value:$0)})
        add(vertical,"bounds",boxes.map{NSValue(rect:CGRect(origin:.zero,size:$0.size))});add(vertical,"locations",ys)
        return out
    }
}
