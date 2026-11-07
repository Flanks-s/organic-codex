#if M10_COMPOSER_SELFTEST
import AppKit
import QuartzCore
import Metal
import ImageIO
import SwiftUI
import CoreImage
@MainActor final class NormieMotionRenderer {
    let w: Int, h: Int
    private let texture: MTLTexture
    private let queue: MTLCommandQueue
    private let renderer: CARenderer
    private var warmed = false

    /// `scale` pixels per point: the scene draws at its own scale, and the renderer magnifies the tree to match.
    init(size: CGSize, host: CALayer, scale: CGFloat = 1) {
        w = Int(size.width * scale); h = Int(size.height * scale)
        let device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .managed
        texture = device.makeTexture(descriptor: d)!
        renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        // The renderer only sees what is committed after it is attached: attach an empty root, then the scene.
        let root = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Without a window nobody sizes the hosting layer; an empty one hides its subtree.
        host.anchorPoint = .zero
        host.bounds = CGRect(origin: .zero, size: size)
        host.position = .zero
        host.transform = CATransform3DMakeScale(scale, scale, 1)
        host.isGeometryFlipped = true
        root.addSublayer(host)
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Top-down BGRA pixels at media time `t`.
    func render(at t: Double) -> [UInt8] {
        CATransaction.flush()
        if !warmed { warmed = true; _ = render(at: t) }   // the first frame comes out empty
        renderer.beginFrame(atTime: t, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let b = queue.makeCommandBuffer()!, e = b.makeBlitCommandEncoder()!
        e.synchronize(resource: texture); e.endEncoding(); b.commit(); b.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // CARenderer's first texture row is the bottom of the scene.
        return (0..<h).reversed().flatMap { bytes[($0 * w * 4)..<(($0 + 1) * w * 4)] }
    }

    func image(_ bytes: [UInt8]) -> CGImage {
        CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func write(_ bytes: [UInt8], _ url: URL) { NormieMotionVerification.writeImage(image(bytes), url) }

    /// |a − b| × 4 in red, for seeing what changed.
    func heat(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.count)
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
            out[i + 2] = UInt8(min(255, d * 4)); out[i + 3] = 255
        }
        return out
    }

    /// The largest mean |Δ| (0–255, RGB) over 16 × 16 tiles, and where it is.
    func tileDiff(_ a: [UInt8], _ b: [UInt8]) -> (value: Double, at: CGPoint) {
        let tile = 16
        var best = 0.0, at = CGPoint.zero
        for ty in stride(from: 0, to: h, by: tile) {
            for tx in stride(from: 0, to: w, by: tile) {
                var sum = 0, n = 0
                for y in ty..<min(h, ty + tile) {
                    var i = (y * w + tx) * 4
                    for _ in tx..<min(w, tx + tile) {
                        sum += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                        n += 3; i += 4
                    }
                }
                let m = Double(sum) / Double(max(1, n))
                if m > best { best = m; at = CGPoint(x: tx, y: ty) }
            }
        }
        return (best, at)
    }
}


/// Replay the exact real-window failure: the subtree-cache call supplies opaque (28,28,28,255) canvas even
/// though this view's draw path owns only ink. No window or WindowServer approximation is needed to inject it.
@MainActor private final class NormieOpaqueCacheReplay:NSView{
    var cacheCalls=0
    override var isFlipped:Bool{true}
    override func draw(_ dirtyRect:NSRect){}
    override func cacheDisplay(in rect:NSRect,to rep:NSBitmapImageRep){
        cacheCalls+=1
        if let p=rep.bitmapData{for y in 0..<rep.pixelsHigh{for x in 0..<rep.pixelsWide{let i=y*rep.bytesPerRow+x*4;p[i]=28;p[i+1]=28;p[i+2]=28;p[i+3]=255}}}
    }
}

@main @MainActor enum NormieMotionVerification {
    static var checks=0,failures:[String]=[]
    static var controlRecords:[[String:Any]]=[]
    static let profile=DisplayProfile(name:"Dell 60Hz",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
    static func check(_ value:Bool,_ label:String){checks+=1;if !value{failures.append(label);print("FINDING: "+label)}}
    static func writeImage(_ image:CGImage,_ url:URL){try! NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:url)}
    static func rgba(_ image:CGImage)->[UInt8]{
        let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
    }
    struct MaterialProbe {var index:Int,rect:CGRect,radius:CGFloat}
    struct InkProbe {var index:Int,proxy:NormieMotionProxy}
    static func rootBranch(_ node:CALayer,in root:CALayer)->CALayer?{
        var result=node
        while let parent=result.superlayer,parent !== root{result=parent}
        return result.superlayer === root ? result:nil
    }
    static func viewTree(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(viewTree)}
    static func pipeline(_ detail:NormieDetailController)->([InkProbe],[MaterialProbe],[String]){
        // This is what the old pixel harness omitted. cacheDisplay/layout lets AppKit re-establish its subview layers.
        _ = NativeViewBitmap.capture(detail.view,scale:2)
        let root=detail.view.layer!,layers=root.sublayers ?? []
        let ink=detail.activeMotionProxies.filter{!$0.layer.isHidden}.compactMap{p -> InkProbe? in
            guard let branch=rootBranch(p.layer,in:root),let index=layers.firstIndex(of:branch) else{return nil}
            return .init(index:index,proxy:p)
        }
        let material=viewTree(detail.view).compactMap{$0 as? NSGlassEffectView}.compactMap{v -> MaterialProbe? in
            guard let l=v.layer,let branch=rootBranch(l,in:root),let index=layers.firstIndex(of:branch),v.bounds.width>0,v.bounds.height>0 else{return nil}
            var rect=v.convert(v.bounds,to:detail.view).intersection(detail.view.bounds),parent=v.superview
            while let p=parent,p !== detail.view{if p.layer?.masksToBounds == true{rect=rect.intersection(p.convert(p.bounds,to:detail.view))};parent=p.superview}
            guard !rect.isNull,!rect.isEmpty else{return nil}
            return .init(index:index,rect:rect,radius:v.cornerRadius)
        }
        let descriptions=layers.enumerated().map{index,l in
            String(index)+":"+(detail.view.subviews.first{$0.layer === l}.map{String(describing:type(of:$0))} ?? "manual/"+String(describing:type(of:l)))
        }
        return (ink,material,descriptions)
    }
    /// A deterministic BACKDROP surrogate, not a claim to render WindowServer glass. Its inputs and ordering come
    /// from the ACTUAL AppKit tree above. It makes the old error visible without creating even an invisible window.
    static func materialAwareImage(_ ink:[InkProbe],_ material:[MaterialProbe],size:CGSize,reference:Bool)->CGImage{
        let host=CALayer();host.backgroundColor=NativePalette.canvas.cgColor
        let renderer=NormieMotionRenderer(size:size,host:host,scale:2)
        let ci=CIContext(options:[.cacheIntermediates:false])
        var events:[(Int,Int,Int)]=[]
        for (i,m) in material.enumerated(){events.append((reference ? -1000+m.index:m.index,0,i))}
        for (i,p) in ink.enumerated(){events.append((p.index,1,i))}
        events.sort{if $0.0 != $1.0{return $0.0<$1.0};if $0.1 != $1.1{return $0.1<$1.1};return $0.2<$1.2}
        var time=2000.0
        for (_,kind,index) in events{
            CATransaction.begin();CATransaction.setDisableActions(true)
            if kind==1{host.addSublayer(clone(ink[index].proxy.layer));CATransaction.commit();continue}
            CATransaction.commit();let image=renderer.image(renderer.render(at:time));time+=1/120
            let input=CIImage(cgImage:image),filter=CIFilter(name:"CIGaussianBlur")!
            filter.setValue(input.clampedToExtent(),forKey:kCIInputImageKey);filter.setValue(18,forKey:kCIInputRadiusKey)
            let blur=ci.createCGImage(filter.outputImage!.cropped(to:input.extent),from:input.extent)!
            let m=material[index],r=m.rect
            let crop=blur.cropping(to:CGRect(x:r.minX*2,y:r.minY*2,width:r.width*2,height:r.height*2).integral)!
            let plate=CALayer();plate.frame=r;plate.contents=crop;plate.contentsScale=2;plate.cornerRadius=m.radius;plate.masksToBounds=true
            CATransaction.begin();CATransaction.setDisableActions(true);host.addSublayer(plate);CATransaction.commit()
        }
        return renderer.image(renderer.render(at:time+1/120))
    }
    static func horizontalGradient(_ image:CGImage,rect:CGRect)->Double{
        guard let crop=image.cropping(to:CGRect(x:rect.minX*2,y:rect.minY*2,width:rect.width*2,height:rect.height*2).integral) else{return 0}
        let bytes=rgba(crop),w=crop.width,h=crop.height
        var result=0.0
        for y in 0..<h{for x in 1..<w{for k in 0..<3{result+=Double(abs(Int(bytes[(y*w+x)*4+k])-Int(bytes[(y*w+x-1)*4+k])))}}}
        return result
    }
    static func pipelineMontage(_ reference:CGImage,_ actual:CGImage,to url:URL){
        // The bottom 520pt contains the actual approval/composer/terminal textures; no photograph is rescaled first.
        let w=1080,h=520,c=CGContext(data:nil,width:w*2,height:h+32,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NativePalette.canvas.cgColor);c.fill(CGRect(x:0,y:0,width:c.width,height:c.height))
        for (i,full) in [reference,actual].enumerated(){let crop=full.cropping(to:CGRect(x:0,y:480,width:2160,height:1040))!
            c.draw(crop,in:CGRect(x:i*w,y:0,width:w,height:h))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
            (i==0 ? "Expected: ink ABOVE backdrop (offscreen surrogate)":"Actual AppKit ordering + backdrop surrogate" as NSString).draw(at:CGPoint(x:i*w+12,y:h+8),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.medium),.foregroundColor:NativePalette.label]);NSGraphicsContext.restoreGraphicsState()
        };writeImage(c.makeImage()!,url)
    }
    static func livePipelineChecks(_ out:URL)throws{
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let seeds=MockSeed.make(),store=ConversationStore(conversations:Array(seeds.prefix(2)),projects:MockSeed.projects,devices:MockSeed.devices)
        let d=NormieDetailController(store:store,sessions:NativeComposerSessions(),actions:NormieActions())
        d.view.frame=CGRect(x:0,y:0,width:1080,height:760);(d.view as? NormieView)?.verificationScale=2
        d.show(seeds[0]);d.composer?.verificationScale=2;d.view.layoutSubtreeIfNeeded()
        d.motionClock.manualTime=1000;d.motionClock.manualProfile = .init(name:"MBP 120Hz verification",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0)
        d.setTerminalShown(true);d.motionClock.advance(to:1000+8.0/120)
        let (ink,material,order)=pipeline(d)
        check(!ink.isEmpty && material.count>=2,"live pipeline includes actual composer/approval glass AND ink")
        var rows:[[String:Any]]=[]
        for p in ink{
            let above=material.allSatisfy{p.index>$0.index},name=p.proxy.nativeSource.map{String(describing:type(of:$0))} ?? "exit"
            check(above,"AppKit foreground above every backdrop: "+name)
            check(p.proxy.glyph.contentsScale==2,"2x glyph plane metadata: "+name)
            check(p.proxy.picture.full.width==Int(ceil(p.proxy.picture.size.width*2)) && p.proxy.picture.full.height==Int(ceil(p.proxy.picture.size.height*2)),"2x native texture dimensions: "+name)
            let t=p.proxy.trail.layer.instanceTransform
            check(abs(t.m11-1)<1e-12 && abs(t.m21)<1e-12 && abs(t.m41)<1e-9,"vertical flight has NO horizontal spread: "+name)
            rows.append(["source":name,"inkIndex":p.index,"glassIndices":material.map(\.index),"aboveGlass":above,"stepPt":MotionStep.edge(p.proxy.nativeRect,p.proxy.earlierRect),"gate":p.proxy.sample.gate,"copies":p.proxy.sample.count,"widthPx":p.proxy.picture.full.width,"heightPx":p.proxy.picture.full.height,"contentsScale":p.proxy.glyph.contentsScale])
        }
        // Render the actual backing-plane branch too. This catches an extra geometry flip or bitmap scale in the
        // new NSView wrapper; the model ink layer alone must have exactly the same pixels as its live branch.
        let plain=CALayer(),wrapped=CALayer();plain.backgroundColor=NativePalette.canvas.cgColor;wrapped.backgroundColor=NativePalette.canvas.cgColor
        let plainRenderer=NormieMotionRenderer(size:d.view.bounds.size,host:plain,scale:2),wrappedRenderer=NormieMotionRenderer(size:d.view.bounds.size,host:wrapped,scale:2)
        CATransaction.begin();CATransaction.setDisableActions(true)
        var branches=Set<ObjectIdentifier>()
        for p in ink{plain.addSublayer(clone(p.proxy.layer));if let branch=rootBranch(p.proxy.layer,in:d.view.layer!),branches.insert(ObjectIdentifier(branch)).inserted{wrapped.addSublayer(clone(branch))}}
        CATransaction.commit()
        let plainPixels=plainRenderer.render(at:1800),wrappedPixels=wrappedRenderer.render(at:1800)
        check(plainPixels==wrappedPixels,"native foreground wrapper introduces no resampling, flip or pixel change")
        let expected=materialAwareImage(ink,material,size:d.view.bounds.size,reference:true),actual=materialAwareImage(ink,material,size:d.view.bounds.size,reference:false)
        let a=rgba(actual),b=rgba(expected),difference=zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0
        check(difference<=1,"material-aware ordering matches reference (CI/CARenderer rounding <=1/255)")
        var sharpness:[[String:Any]]=[]
        for m in material{let r=m.rect.insetBy(dx:24,dy:12),e=horizontalGradient(expected,rect:r),v=horizontalGradient(actual,rect:r),ratio=e>0 ? v/e:1
            check(abs(ratio-1)<1e-9,"perpendicular sharpness preserved over material \(m.index): \(ratio)")
            sharpness.append(["rect":NSStringFromRect(r),"referenceHorizontalGradient":e,"actualHorizontalGradient":v,"ratio":ratio])
        }
        writeImage(actual,out.appendingPathComponent("live-pipeline-actual@2x.png"));writeImage(expected,out.appendingPathComponent("live-pipeline-reference@2x.png"));pipelineMontage(expected,actual,to:out.appendingPathComponent("live-pipeline-compare.png"))
        let held=d.activeMotionProxies.compactMap{p in p.nativeSource.map{(p,$0)}}
        var lowGateReturns=0
        for k in 9...80{d.motionClock.advance(to:1000+Double(k)/120)
            for (p,v) in held where v !== d.terminalPane && p.sample.count==1{
                check(p.layer.isHidden && abs((v.layer?.opacity ?? 1)-1)<1e-6,"below-onset frame uses the native source immediately");lowGateReturns+=1
            }
        }
        check(lowGateReturns>0,"120Hz fixture observes native return before spring clock retirement")
        check(d.activeMotionProxies.isEmpty,"settled terminal has no admitted proxy")
        // Approval's local .35/.15 tail must not keep a bitmap while it is carried or after the rail settles.
        d.motionClock.manualTime=1002
        seeds[0].approvals=[.init(id:"tail",title:"Approval tail",command:"printf harmless",note:"Native-tail fixture",acceptLabel:"Run",toolItemID:"")]
        d.show(seeds[0]);d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded();d.motionClock.advance(to:1002.45)
        let tails=d.activeMotionProxies.filter{$0.nativeSource is NativeTranscriptCard}
        check(!tails.isEmpty,"local approval spring tail is exercised")
        check(tails.allSatisfy{$0.sample.count==1 && $0.layer.isHidden},"approval tail already uses native view, not forced .85s bitmap")
        let result:[String:Any]=["profile":["hz":120,"scale":2,"mmPerPoint":0.2],"layerOrder":order,"planes":rows,"orthogonalSharpness":sharpness,"maxMaterialAwareChannelDifference":difference,"surrogateChannelTolerance":1,"wrapperPixelDifference":plainPixels==wrappedPixels ? 0:1,"lowGateNativeReturns":lowGateReturns,"localTailNative":tails.allSatisfy{$0.layer.isHidden},"note":"No window. Surrogate gaussian models backdrop dependency only; it is NOT a WindowServer glass recording.","findings":failures]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("live-pipeline.json"))
        print("LIVE PIPELINE",order);print("LIVE SHARPNESS",sharpness);print("LIVE PIPELINE findings",failures.count)
        d.disposeTerminal();d.disposeTranscripts()
    }
    /// Windowless checks cannot sample WindowServer's glass radiance. Test BOTH the real glass's backdrop-input
    /// identity (native clipping domain, style/tint, no gate-time reparent) and the pixel contribution of the ink/plate
    /// over ONE shared backdrop. This avoids claiming that a Gaussian stand-in is the real material.
    static func handoffChecks(_ out:URL)throws{
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let initialFailures=failures.count
        let seeds=MockSeed.make(),store=ConversationStore(conversations:Array(seeds.prefix(2)),projects:MockSeed.projects,devices:MockSeed.devices)
        let d=NormieDetailController(store:store,sessions:NativeComposerSessions(),actions:NormieActions())
        d.view.frame=CGRect(x:0,y:0,width:1080,height:760);(d.view as? NormieView)?.verificationScale=2
        d.show(seeds[0]);d.composer?.verificationScale=2;d.view.layoutSubtreeIfNeeded()
        _=NativeViewBitmap.capture(d.view,scale:2)
        let cards=viewTree(d.view).compactMap{$0 as? NativeTranscriptCard}.filter{$0.approvalSource != nil}
        let glasses=cards.flatMap{viewTree($0).compactMap{$0 as? NSGlassEffectView}}
        check(!glasses.isEmpty,"handoff fixture contains the actual approval NSGlassEffectView")
        func scope(_ g:NSView)->[NSView]{
            var result:[NSView]=[],p=g.superview
            while let v=p,v !== d.view{if v is NSClipView || v.layer?.masksToBounds == true{result.append(v)};p=v.superview}
            return result
        }
        let original=glasses.map{(view:$0,parent:$0.superview,scope:scope($0).map(ObjectIdentifier.init),style:$0.style,tint:$0.tintColor,radius:$0.cornerRadius)}
        func pendingDisplay(_ view:NSView){
            if view.needsDisplay{view.displayIfNeeded()};view.layer?.displayIfNeeded()
            for child in view.subviews{pendingDisplay(child)}
        }
        // In both columns use the SAME backdrop pixels. This measures any dark/opaque matte in the proxy,
        // separately from the real material's backdrop identity assertion below. No window is constructed.
        func recomposition(_ picture:NormieMotionPicture)->(Double,Int,CGImage,CGImage){
            func draw(_ images:[CGImage])->CGImage{
                let w=picture.full.width,h=picture.full.height,c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.setFillColor(CGColor(gray:0.24,alpha:1));c.fill(CGRect(x:0,y:0,width:w,height:h))
                for image in images{c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))};return c.makeImage()!
            }
            let native=draw([picture.full]),proxy=draw([picture.solids,picture.ink]),a=rgba(native),b=rgba(proxy)
            var sum=0.0,maxChannel=0
            for i in stride(from:0,to:a.count,by:4){
                sum+=abs(0.2126*Double(Int(a[i])-Int(b[i]))+0.7152*Double(Int(a[i+1])-Int(b[i+1]))+0.0722*Double(Int(a[i+2])-Int(b[i+2])))
                for k in 0..<3{maxChannel=max(maxChannel,abs(Int(a[i+k])-Int(b[i+k])))}
            }
            return(sum/Double(picture.full.width*picture.full.height),maxChannel,native,proxy)
        }
        var matte:[[String:Any]]=[]
        for (i,card) in cards.enumerated(){if let picture=NormieMotionPicture.capture(card,scale:2){let (mean,maxChannel,native,proxy)=recomposition(picture)
            check(mean<=1 && maxChannel<=1,"approval proxy/native same-backdrop matte luminance <=1/255")
            writeImage(native,out.appendingPathComponent("handoff-native-\(i)@2x.png"));writeImage(proxy,out.appendingPathComponent("handoff-proxy-\(i)@2x.png"))
            matte.append(["card":i,"meanAbsoluteLumaDifference255":mean,"maxChannelDifference255":maxChannel])
        }}
        let hz=120.0,budget=1000/hz
        d.motionClock.manualProfile = .init(name:"MBP 120Hz handoff",frameInterval:1/hz,mmPerPoint:0.2,persistenceFrames:0)
        var frames:[[String:Any]]=[],scopeFindings=Set<String>(),handoffMS:[Double]=[],gateReparents=0,handoffs=0,retireMS:[Double]=[],brightnessPairs:[[String:Any]]=[]
        func pair(_ saved:(CALayer,CGRect,NativeTranscriptCard),_ name:String){
            // Align each ROI in card coordinates, so the expected 4px motion cannot masquerade as a brightness jump.
            // Use identical material pixels under both frames; the independent scope assertion checks that the REAL
            // NSGlassEffectView keeps the very same native backdrop input, which cacheDisplay cannot render.
            let (oldLayer,oldRect,card)=saved,rect=card.convert(card.bounds,to:d.view)
            let local=CGRect(x:card.approvalPlateRect.midX+100,y:75,width:100,height:10)
            let beforeHost=CALayer(),afterHost=CALayer();beforeHost.backgroundColor=CGColor(gray:0.24,alpha:1);afterHost.backgroundColor=beforeHost.backgroundColor
            let beforeRenderer=NormieMotionRenderer(size:d.view.bounds.size,host:beforeHost,scale:2),afterRenderer=NormieMotionRenderer(size:d.view.bounds.size,host:afterHost,scale:2)
            CATransaction.begin();CATransaction.setDisableActions(true);oldLayer.isHidden=false;beforeHost.addSublayer(oldLayer)
            let native=CALayer();native.contents=NativeViewBitmap.capture(card,scale:2);native.contentsScale=2;native.frame=rect;afterHost.addSublayer(native);CATransaction.commit()
            let a=beforeRenderer.image(beforeRenderer.render(at:7000)),b=afterRenderer.image(afterRenderer.render(at:7000))
            func crop(_ image:CGImage,_ r:CGRect)->CGImage{image.cropping(to:CGRect(x:r.minX*2,y:r.minY*2,width:r.width*2,height:r.height*2).integral)!}
            let aa=rgba(crop(a,local.offsetBy(dx:oldRect.minX,dy:oldRect.minY))),bb=rgba(crop(b,local.offsetBy(dx:rect.minX,dy:rect.minY)))
            func luma(_ bytes:[UInt8])->Double{var sum=0.0;for i in stride(from:0,to:bytes.count,by:4){sum+=0.2126*Double(bytes[i])+0.7152*Double(bytes[i+1])+0.0722*Double(bytes[i+2])};return sum/Double(bytes.count/4)}
            let old=luma(aa),new=luma(bb),delta=abs(old-new)
            check(delta<=1,"aligned quiet approval plate: adjacent proxy/native luminance jump <=1/255")
            brightnessPairs.append(["name":name,"beforeLuma255":old,"afterLuma255":new,"absoluteLumaJump255":delta,"localROI":NSStringFromRect(local)])
            writeImage(crop(a,oldRect),out.appendingPathComponent(name+"-proxy@2x.png"));writeImage(crop(b,rect),out.appendingPathComponent(name+"-native@2x.png"))
        }
        for cycle in 0..<2{
            d.motionClock.manualTime=4000+Double(cycle)*4;d.setTerminalShown(false,animated:false);d.view.layoutSubtreeIfNeeded();d.prepareMotionPictures()
            for shown in [true,false]{
                let base=4000+Double(cycle)*4+(shown ? 0:2);d.motionClock.manualTime=base;d.setTerminalShown(shown)
                var wasActive=false,previousProxyCount=d.activeMotionProxies.count,parents=glasses.map{$0.superview.map(ObjectIdentifier.init)},previous:(CALayer,CGRect,NativeTranscriptCard)?
                for k in 0...110{
                    let t=base+Double(k)/hz,start=CACurrentMediaTime(),recaptures=d.motionRecaptureMS.count
                    d.motionClock.advance(to:t);let afterCallback=CACurrentMediaTime()
                    d.view.layoutSubtreeIfNeeded();let afterLayout=CACurrentMediaTime()
                    pendingDisplay(d.view);let afterDisplay=CACurrentMediaTime()
                    CATransaction.flush();let end=CACurrentMediaTime(),ms=(end-start)*1000
                    let proxies=d.activeMotionProxies.filter{$0.nativeSource is NativeTranscriptCard},active=proxies.contains{!$0.layer.isHidden}
                    let currentParents=glasses.map{$0.superview.map(ObjectIdentifier.init)}
                    let handoff=wasActive && !active,retired=previousProxyCount>0 && d.activeMotionProxies.isEmpty
                    if retired{retireMS.append(ms)}
                    if handoff{handoffs+=1;handoffMS.append(ms);if currentParents != parents{gateReparents+=1};if let previous{pair(previous,"handoff-\(cycle)-\(shown ? "open":"close")")}}
                    if let p=proxies.first(where:{!$0.layer.isHidden}),let card=p.nativeSource as? NativeTranscriptCard{previous=(clone(p.layer),p.nativeRect,card)}
                    for (i,record) in original.enumerated(){
                        if scope(record.view).map(ObjectIdentifier.init) != record.scope{scopeFindings.insert("approval glass keeps native backdrop/clipping input at every frame")}
                        if record.view.style != record.style || record.view.tintColor != record.tint || record.view.cornerRadius != record.radius{scopeFindings.insert("approval glass material parameters unchanged")}
                        check(CATransform3DIsIdentity(record.view.layer?.transform ?? CATransform3DIdentity),"handoff never transforms glass")
                        _=i
                    }
                    frames.append(["cycle":cycle,"shown":shown,"frame":k,"t":Double(k)/hz,"callbackAndPendingDisplayMS":ms,"callbackMS":(afterCallback-start)*1000,"layoutMS":(afterLayout-afterCallback)*1000,"pendingDisplayMS":(afterDisplay-afterLayout)*1000,"transactionFlushMS":(end-afterDisplay)*1000,"recaptures":d.motionRecaptureMS.count-recaptures,"approvalProxy":active,"handoff":handoff,"retirement":retired,"glassParents":currentParents.map{$0.map{String(describing:$0)} ?? "nil"},"scope":glasses.map{scope($0).map{String(describing:type(of:$0))}}])
                    wasActive=active;parents=currentParents;previousProxyCount=d.activeMotionProxies.count
                }
            }
        }
        // Attribute the boundary itself separately from transcript/composer resizing. Keep the whole-frame budget
        // assertion too: a small component number must NEVER turn a slow entire display callback into a pass.
        var directHandoffMS:[Double]=[]
        for n in 0..<4{
            d.motionClock.manualTime=5000+Double(n)*2;d.setTerminalShown(false,animated:false);d.view.layoutSubtreeIfNeeded();d.prepareMotionPictures();d.setTerminalShown(true)
            d.motionClock.advance(to:d.motionClock.now+8.0/120)
            if let p=d.activeMotionProxies.first(where:{$0.nativeSource is NativeTranscriptCard}),let card=p.nativeSource{
                let rect=card.convert(card.bounds,to:d.view),start=CACurrentMediaTime()
                p.update(now:rect,earlier:rect.offsetBy(dx:0,dy:4),profile:d.motionClock.manualProfile)
                pendingDisplay(card);CATransaction.flush();directHandoffMS.append((CACurrentMediaTime()-start)*1000)
                check(p.layer.isHidden && card.layer?.opacity == 1,"isolated real approval boundary returns native ink")
            }
        }
        d.setTerminalShown(false,animated:false);d.view.layoutSubtreeIfNeeded()
        for finding in scopeFindings.sorted(){check(false,finding)}
        check(handoffs>=4,"four actual exposure-to-native approval handoffs exercised")
        check(gateReparents==0,"NO real-glass reparent or backdrop rebuild at exposure/native handoff")
        if ProcessInfo.processInfo.environment["NORMIE_CHECK_CONFIGURATION"] == "release"{
            check((directHandoffMS.max() ?? .infinity)<budget,"isolated approval handoff + native paint <120Hz budget (max \(directHandoffMS.max() ?? 0))")
            check((retireMS.max() ?? .infinity)<budget,"release proxy retirement + pending native display <120Hz budget (max \(retireMS.max() ?? 0))")
            check((handoffMS.max() ?? .infinity)<budget,"release handoff callback + pending native display <120Hz budget \(budget)ms (max \(handoffMS.max() ?? 0))")
        }
        print("HANDOFF APPKIT WINDOWS",NSApp.windows.map{["type":String(describing:type(of:$0)),"title":$0.title,"visible":String($0.isVisible),"frame":NSStringFromRect($0.frame)]})
        check(NSApp.windows.allSatisfy{!$0.isVisible && String(describing:type(of:$0)) == "TUINSWindow"},"handoff has no app-owned window; only AppKit hidden text-input helper")
        let result:[String:Any]=["configuration":ProcessInfo.processInfo.environment["NORMIE_CHECK_CONFIGURATION"] ?? "unknown","checks":checks,"findings":Array(failures.dropFirst(initialFailures)),"matte":matte,"adjacentFrameBrightness":brightnessPairs,"handoffs":handoffs,"gateReparents":gateReparents,"handoffMaxMS":handoffMS.max() ?? 0,"handoffTimesMS":handoffMS,"isolatedApprovalHandoffTimesMS":directHandoffMS,"retirementTimesMS":retireMS,"budgetMS":budget,"frames":frames,"boundary":"Real NSGlassEffectView identity and backdrop ancestry, shared-backdrop bitmap contribution; not WindowServer glass radiance. Callback + pending AppKit display + transaction flush excludes server GPU/presentation time."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("handoff.json"))
        print("HANDOFF",handoffs,"reparents",gateReparents,"maxMS",handoffMS.max() ?? 0,"findings",failures.count-initialFailures);fflush(stdout)
        d.disposeTerminal();d.disposeTranscripts()
    }
    /// No render/readback in the CPU interval; records callback, pending AppKit work and flush separately.
    /// The texture metric counts all pixels submitted by the glyph layer, including transparent padding.
    static func startupChecks(_ out:URL)throws{
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var rows:[[String:Any]]=[]
        func pendingDisplay(_ view:NSView){
            if view.needsDisplay{view.displayIfNeeded()};view.layer?.displayIfNeeded()
            for child in view.subviews{pendingDisplay(child)}
        }
        for warm in [false,true]{for enabled in [false,true]{for trial in 0..<6{
            let seeds=MockSeed.make(),store=ConversationStore(conversations:Array(seeds.prefix(2)),projects:MockSeed.projects,devices:MockSeed.devices)
            let d=NormieDetailController(store:store,sessions:NativeComposerSessions(),actions:NormieActions())
            d.view.frame=CGRect(x:0,y:0,width:1080,height:760);(d.view as? NormieView)?.verificationScale=2
            d.show(seeds[0]);d.composer?.verificationScale=2;d.view.layoutSubtreeIfNeeded();pendingDisplay(d.view)
            d.motionClock.manualTime=1000;d.motionClock.manualProfile = .init(name:"MBP 120Hz startup",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0)
            d.motionProcessingEnabled=enabled
            NormieMotionAudit.enabled=true;NormieMotionAudit.events=[]
            if warm{d.prepareMotionPictures()}
            let idleEvents=NormieMotionAudit.events;NormieMotionAudit.events=[]
            let begin=CACurrentMediaTime();d.setTerminalShown(true);let preparation=(CACurrentMediaTime()-begin)*1000
            let prepareEvents=NormieMotionAudit.events;NormieMotionAudit.events=[]
            var frames:[[String:Any]]=[]
            for k in 0..<18{
                let recaptures=d.motionRecaptureMS.count,start=CACurrentMediaTime()
                d.motionClock.advance(to:1000+Double(k)/120);let callback=CACurrentMediaTime()
                d.view.layoutSubtreeIfNeeded();let layout=CACurrentMediaTime()
                pendingDisplay(d.view);let display=CACurrentMediaTime();CATransaction.flush();let end=CACurrentMediaTime()
                var area=0,planes:[[String:Any]]=[]
                for p in d.activeMotionProxies{
                    let image=p.glyph.contents as! CGImage
                    let pixels=image.width*image.height,copies=p.trail.layer.instanceCount,active = !p.layer.isHidden && !p.glyph.isHidden
                    let work=active ? pixels*copies:0;area+=work
                    planes.append(["source":p.nativeSource.map{String(describing:type(of:$0))} ?? "none","active":active,"copies":copies,"bitmapPixels":pixels,"copiesTimesPixels":work,"frame":NSStringFromRect(p.glyph.frame),"fullBitmapPixels":p.picture.ink.width*p.picture.ink.height])
                }
                check(NormieMotionAudit.events.allSatisfy{!["capture","editor","ink-region","proxy-init","plates","replace"].contains($0["work"] as? String ?? "")},"stable startup frame \(k) has no capture, alpha scan or layer construction")
                frames.append(["frame":k,"callbackMS":(callback-start)*1000,"layoutMS":(layout-callback)*1000,"displayMS":(display-layout)*1000,"flushMS":(end-display)*1000,"mainThreadMS":(end-start)*1000,"recaptures":d.motionRecaptureMS.count-recaptures,"work":NormieMotionAudit.events,"foregroundHidden":d.view.subviews.filter{String(describing:type(of:$0)) == "NormieMotionForeground"}.map(\.isHidden),"copiesTimesPixels":area,"planes":planes])
                NormieMotionAudit.events=[]
            }
            rows.append(["warm":warm,"enabled":enabled,"trial":trial,"preparationMS":preparation,"idleWork":idleEvents,"preparationWork":prepareEvents,"frames":frames])
            NormieMotionAudit.enabled=false;d.disposeTerminal();d.disposeTranscripts()
        }}}
        let result:[String:Any]=["profile":["hz":120,"scale":2,"mmPerPoint":0.2],"configuration":ProcessInfo.processInfo.environment["NORMIE_CHECK_CONFIGURATION"] ?? "unknown","rows":rows,"note":"CPU includes callback, pending AppKit layout/display and transaction flush. Excludes GPU and WindowServer; no window or app launch. copiesTimesPixels includes transparent texture padding; no GPU bandwidth claim."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("startup.json"))
        print("STARTUP",rows.count,"trials",checks,"checks",failures.count,"findings");fflush(stdout)
        check(NSApp.windows.allSatisfy{!$0.isVisible && String(describing:type(of:$0)) == "TUINSWindow"},"startup has no app-owned window")
    }
    /// Compare the smaller submitted quads with the original full glyph textures through the same replicator.
    /// This is a representation optimization, never a change in exposure strength, spacing, path or text coverage.
    static func inkRegionChecks(_ out:URL)throws{
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let seeds=MockSeed.make(),store=ConversationStore(conversations:Array(seeds.prefix(2)),projects:MockSeed.projects,devices:MockSeed.devices)
        let d=NormieDetailController(store:store,sessions:NativeComposerSessions(),actions:NormieActions())
        d.view.frame=CGRect(x:0,y:0,width:1080,height:760);(d.view as? NormieView)?.verificationScale=2
        d.show(seeds[0]);d.composer?.verificationScale=2;d.view.layoutSubtreeIfNeeded()
        d.motionClock.manualTime=1000;d.motionClock.manualProfile = .init(name:"120Hz ink region",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0)
        d.prepareMotionPictures();d.setTerminalShown(true)
        var rows:[[String:Any]]=[],sourceProofs:[[String:Any]]=[],checked=Set<ObjectIdentifier>()
        let a=CALayer(),b=CALayer()
        a.backgroundColor=CGColor(gray:0.11,alpha:1);b.backgroundColor=a.backgroundColor
        let ra=NormieMotionRenderer(size:d.view.bounds.size,host:a,scale:2),rb=NormieMotionRenderer(size:d.view.bounds.size,host:b,scale:2)
        for k in [0,2,4,7,10,17,30,90]{
            d.motionClock.advance(to:1000+Double(k)/120)
            CATransaction.begin();CATransaction.setDisableActions(true)
            a.sublayers=[];b.sublayers=[];var fullWork=0,croppedWork=0
            for p in d.activeMotionProxies where !p.layer.isHidden{
                let actual=clone(p.layer),reference=clone(p.layer)
                if let rep=reference.sublayers?.compactMap({$0 as? CAReplicatorLayer}).first,let raw=rep.sublayers?.first{
                    raw.contents=p.picture.ink;raw.frame=p.nativeRect;raw.isHidden=false
                }
                a.addSublayer(actual);b.addSublayer(reference)
                let count=p.trail.layer.instanceCount
                fullWork+=p.picture.ink.width*p.picture.ink.height*count
                if !p.glyph.isHidden{let image=p.glyph.contents as! CGImage;croppedWork+=image.width*image.height*count}
                if checked.insert(ObjectIdentifier(p.picture.ink)).inserted{
                    let full=rgba(p.picture.ink),w=p.picture.ink.width,h=p.picture.ink.height
                    var outside=0,sourceDelta=0
                    if p.glyph.isHidden{outside=stride(from:3,to:full.count,by:4).filter{full[$0] != 0}.count}
                    else{
                        let image=p.glyph.contents as! CGImage,small=rgba(image),n=p.nativeRect,g=p.glyph.frame
                        let x0=Int(((g.minX-n.minX)*CGFloat(w)/n.width).rounded()),y0=Int(((g.minY-n.minY)*CGFloat(h)/n.height).rounded())
                        for y in 0..<h{for x in 0..<w{
                            let i=(y*w+x)*4
                            if x>=x0,y>=y0,x<x0+image.width,y<y0+image.height{
                                let j=((y-y0)*image.width+x-x0)*4
                                for c in 0..<4{sourceDelta=max(sourceDelta,abs(Int(full[i+c])-Int(small[j+c])))}
                            }else if full[i+3] != 0{outside+=1}
                        }}
                    }
                    check(outside==0 && sourceDelta==0,"glyph texture source exact: no nonzero alpha removed, no texel changed")
                    sourceProofs.append(["source":p.nativeSource.map{String(describing:type(of:$0))} ?? "none","outsideNonzeroAlphaPixels":outside,"sourceMaxChannelDifference":sourceDelta])
                }
            }
            CATransaction.commit()
            let aa=ra.render(at:9000+Double(k)/120),bb=rb.render(at:9000+Double(k)/120)
            let maxDelta=zip(aa,bb).map{abs(Int($0)-Int($1))}.max() ?? 0,different=zip(aa,bb).filter{$0 != $1}.count
            // Smaller quads change float texture coordinates at fractional positions. Source pixels above must be
            // BIT EXACT; CARenderer's repeated 8-bit blend may round by 2/255 on moving frames. Native endpoints 0.
            check(maxDelta <= (fullWork>0 ? 2:0),"glyph region render rounding bounded; native endpoints exact at frame \(k): \(maxDelta)")
            if fullWork>0{check(croppedWork<fullWork,"transparent padding removed without reducing copies at frame \(k)")}
            rows.append(["frame":k,"maxChannelDifference":maxDelta,"differentChannels":different,"fullCopiesTimesPixels":fullWork,"croppedCopiesTimesPixels":croppedWork])
            if k==4{writeImage(ra.image(aa),out.appendingPathComponent("ink-region-cropped@2x.png"));writeImage(rb.image(bb),out.appendingPathComponent("ink-region-full@2x.png"))}
        }
        // A long editor and live content invalidation still retain every glyph in the prepared future viewport.
        _=d.composer?.setText(String(repeating:"Retained glyphs 中文 and a real native editor.\n",count:35))
        d.motionClock.advance(to:1000.8)
        check(d.composer?.text.contains("中文") == true,"region optimization preserves live draft")
        try JSONSerialization.data(withJSONObject:["rows":rows,"sourceProofs":sourceProofs,"sourceTolerance":0,"movingRenderRoundingTolerance":2,"nativeEndpointTolerance":0,"findings":failures],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("ink-region.json"))
        d.disposeTerminal();d.disposeTranscripts()
    }
    static func alphaChecks(_ out:URL)throws{
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let before=failures.count;var rows:[[String:Any]]=[]
        for scale:CGFloat in [1,2]{
            let source=NormieOpaqueCacheReplay(frame:CGRect(x:0,y:0,width:240,height:80)),glass=NSGlassEffectView(frame:source.bounds)
            source.addSubview(glass);glass.isHidden=true
            for (title,color,y) in [("Native approval",NSColor.white,CGFloat(12)),("Black",NSColor.black,CGFloat(35))]{let label=NativeLabel(labelWithString:title);label.font = .systemFont(ofSize:13);label.textColor=color;label.frame=CGRect(x:12,y:y,width:180,height:18);source.addSubview(label)}
            guard let picture=NormieMotionPicture.capture(source,scale:scale) else{check(false,"opaque-cache replay captured");continue}
            for (name,image) in [("full",picture.full),("ink",picture.ink)]{
                let bytes=rgba(image),x=Int(120*scale),y=Int(60*scale),i=(y*image.width+x)*4,alpha=bytes[i+3]
                let nonempty=stride(from:3,to:bytes.count,by:4).filter{bytes[$0]>0}.count
                check(alpha==0,"real-window opaque-cache replay leaves quiet \(name) TRANSPARENT at \(scale)x")
                check(nonempty>0 && nonempty<image.width*image.height/2,"\(name) retains glyphs without a whole-card matte at \(scale)x")
                check(stride(from:0,to:bytes.count,by:4).contains{bytes[$0]==0 && bytes[$0+1]==0 && bytes[$0+2]==0 && bytes[$0+3]>128},"legitimate black glyphs retained, not colour keyed")
                rows.append(["scale":scale,"plane":name,"quietRGBA":Array(bytes[i..<i+4]),"nonemptyPixels":nonempty])
                writeImage(image,out.appendingPathComponent("alpha-\(name)@\(Int(scale))x.png"))
            }
            let solids=rgba(picture.solids),quiet=(Int(60*scale)*picture.solids.width+Int(120*scale))*4
            check(solids[quiet+3]==0,"solids quiet region remains transparent at \(scale)x")
            check(source.cacheCalls==0,"glass capture uses own draw overrides, not cached opaque ancestor")
        }
        let result:[String:Any]=["rows":rows,"checks":checks,"findings":Array(failures.dropFirst(before)),"fixture":"Recorded live blank pixel 28/28/28/255 injected at NSView subtree cache boundary; draw owns only glyphs."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("alpha.json"))
        print("ALPHA replay",checks,"checks",failures.count-before,"findings");fflush(stdout)
    }
    static func factory()->NormieDetailController{
        let c=MockSeed.make()[0];c.running=false;c.satellites=[];c.approvals=[];c.question=nil;c.userInput=nil
        let store=ConversationStore(conversations:[c],projects:MockSeed.projects,devices:MockSeed.devices)
        let d=NormieDetailController(store:store,sessions:NativeComposerSessions(),actions:NormieActions())
        d.view.frame=CGRect(x:0,y:0,width:1080,height:760);(d.view as? NormieView)?.verificationScale=1
        d.show(c);d.composer?.verificationScale=1;_ = d.composer?.setText("Review the sidebar and keep the original draft.")
        d.view.layoutSubtreeIfNeeded();d.motionClock.manualTime=1000;d.motionClock.manualProfile=profile
        return d
    }
    struct Run {var frames:[[UInt8]]=[],records:[[String:Any]]=[],timings:[Double]=[],preparation=0.0,layouts=0,indexBuilds=0}
    /// Isolated pixel checks clone model layers; they must not reparent the LIVE layer out of its AppKit plane.
    static func clone(_ source:CALayer)->CALayer{
        let target:CALayer
        if let r=source as? CAReplicatorLayer{let t=CAReplicatorLayer();t.instanceCount=r.instanceCount;t.instanceTransform=r.instanceTransform;t.instanceColor=r.instanceColor;t.instanceDelay=r.instanceDelay;target=t}
        else if let shape=source as? CAShapeLayer{let t=CAShapeLayer();t.path=shape.path;t.fillColor=shape.fillColor;t.strokeColor=shape.strokeColor;t.lineWidth=shape.lineWidth;target=t}
        else{target=CALayer()}
        target.bounds=source.bounds;target.position=source.position;target.anchorPoint=source.anchorPoint;target.transform=source.transform;target.sublayerTransform=source.sublayerTransform
        target.isGeometryFlipped=source.isGeometryFlipped;target.opacity=source.opacity;target.isHidden=source.isHidden
        target.contents=source.contents;target.contentsScale=source.contentsScale;target.contentsGravity=source.contentsGravity;target.contentsRect=source.contentsRect;target.contentsCenter=source.contentsCenter
        target.minificationFilter=source.minificationFilter;target.magnificationFilter=source.magnificationFilter;target.backgroundColor=source.backgroundColor;target.cornerRadius=source.cornerRadius;target.masksToBounds=source.masksToBounds
        if let mask=source.mask{target.mask=clone(mask)}
        for child in source.sublayers ?? []{target.addSublayer(clone(child))};return target
    }
    static func drawClone(_ proxy:NormieMotionProxy,in host:CALayer){
        let key="proxy-check-"+String(describing:ObjectIdentifier(proxy))
        host.sublayers?.first{$0.name == key}?.removeFromSuperlayer()
        if !proxy.layer.isHidden{let copy=clone(proxy.layer);copy.name=key;host.addSublayer(copy)}
    }
    static func render(_ detail:NormieDetailController,_ host:CALayer,_ renderer:NormieMotionRenderer,_ time:Double,_ seen:inout [ObjectIdentifier:(NormieMotionProxy,NSView?,CALayer)])->[UInt8]{
        CATransaction.begin();CATransaction.setDisableActions(true)
        for p in detail.activeMotionProxies {
            let id=ObjectIdentifier(p)
            if seen[id] == nil {
                if let source=p.nativeSource {for (old,entry) in Array(seen) where entry.1 === source{entry.2.removeFromSuperlayer();host.sublayers?.first{$0.name == "proxy-check-"+String(describing:old)}?.removeFromSuperlayer();seen[old]=nil}}
                let raw=CALayer();raw.contents=p.picture.full;host.addSublayer(raw);seen[id]=(p,p.nativeSource,raw)
            }
        }
        for (_,entry) in seen {
            let (proxy,source,raw)=entry
            raw.frame=proxy.nativeRect;raw.opacity=proxy.layer.opacity
            if let clip=proxy.clippingView{let mask=CAShapeLayer();let r=clip.convert(clip.bounds,to:detail.view);mask.path=CGPath(rect:r.offsetBy(dx:-raw.frame.minX,dy:-raw.frame.minY),transform:nil);raw.mask=mask}else{raw.mask=nil}
            raw.isHidden = !proxy.layer.isHidden || source == nil || source?.isHidden == true
            drawClone(proxy,in:host)
        }
        CATransaction.commit()
        return renderer.render(at:time)
    }
    static func record(_ d:NormieDetailController,_ frame:Int,_ time:Double,_ enabled:Bool)->[[String:Any]]{
        var rows=d.activeMotionProxies.enumerated().map{index,p -> [String:Any] in
            let step=MotionStep.edge(p.nativeRect,p.earlierRect),s=p.sample
            if enabled{
                let expected=smoothstep(1.08,2.7,Double(step)*0.27)
                check(abs(Double(s.gate)-expected)<1e-8,"gate matches physical bbox at frame \(frame)/\(index)")
                if Double(step)*0.27>2.7{check(s.count>1,"every >2.7mm frame is processed")}
                if Double(step)*0.27<1.08{check(s.count==1 && s.gate==0,"below onset untouched")}
                if s.count>1{
                    check(s.length+1e-7>=step*s.gate,"full gated sweep covered")
                    check(s.length/CGFloat(s.count-1)<=1.5+1e-7,"copy spacing <=1.5pt")
                    let last=CATransform3DConcatRepeated(p.trail.layer.instanceTransform,s.count-1)
                    let endpoint=CGPoint(x:p.nativeRect.midX*last.m11+p.nativeRect.midY*last.m21+last.m41,y:p.nativeRect.midX*last.m12+p.nativeRect.midY*last.m22+last.m42)
                    if abs(p.nativeRect.width-p.earlierRect.width)<0.01 && abs(p.nativeRect.height-p.earlierRect.height)<0.01{
                        check(hypot(endpoint.x-p.nativeRect.midX,endpoint.y-p.nativeRect.midY)+0.02>=s.length,"actual replicator chord reaches previous exposure")
                    }
                }
            }
            return ["frame":frame,"t":time,"object":p.nativeSource.map{String(describing:type(of:$0))} ?? "retired-card-or-toast",
                    "rect":[p.nativeRect.minX,p.nativeRect.minY,p.nativeRect.width,p.nativeRect.height],"idealRect":[p.idealRect.minX,p.idealRect.minY,p.idealRect.width,p.idealRect.height],"rawStepPt":step,"stepMM":Double(step)*0.27,"gate":s.gate,"copies":s.count,"lengthPt":s.length,
                    "spacingPt":s.count>1 ? s.length/CGFloat(s.count-1):0,"alpha":s.alpha,"enabled":enabled]
        }
        if d.composerGlassNative.width>0{
            let now=d.composerGlassNative,old=d.composerGlassEarlier,s=d.composerGlassSample,step=MotionStep.edge(now,old)
            let stretched=NormieSolidMotion.rect(now:now,earlier:old,profile:profile,settings:ExposureSettings(enabled:enabled))
            check(CATransform3DIsIdentity(d.composerGlass.layer?.transform ?? CATransform3DIdentity),"composer glass never transformed")
            if enabled{check(abs(Double(s.gate)-smoothstep(1.08,2.7,Double(step)*0.27))<1e-8,"composer glass physical gate");check(d.composerGlass.frame==stretched,"composer glass uses REAL stretched frame");check(hypot(stretched.width-now.width,stretched.height-now.height)+1e-7>=step*s.gate,"resizing glass covers farthest edge sweep")}
            rows.append(["object":"composer glass (real NSGlassEffectView)","frame":frame,"t":time,"rawStepPt":step,"stepMM":Double(step)*0.27,"gate":s.gate,"copies":1,"lengthPt":max(stretched.width-now.width,stretched.height-now.height),"spacingPt":0,"enabled":enabled])
        };return rows
    }
    static func CATransform3DConcatRepeated(_ t:CATransform3D,_ count:Int)->CATransform3D{
        var v=CATransform3DIdentity;for _ in 0..<count{v=CATransform3DConcat(v,t)};return v
    }
    static func run(_ scenario:String,enabled:Bool,renderPixels:Bool=true,hz:Double=60,scale:CGFloat=1)->Run{
        let d=factory();d.motionProcessingEnabled=enabled
        (d.view as? NormieView)?.verificationScale=scale;d.composer?.verificationScale=scale;d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded();d.motionClock.manualProfile.frameInterval=1/hz
        let host=CALayer();host.backgroundColor=NativePalette.canvas.cgColor
        let background=CALayer();background.frame=d.view.bounds;host.addSublayer(background)
        let renderer=NormieMotionRenderer(size:d.view.bounds.size,host:host)
        var run=Run();var seen:[ObjectIdentifier:(NormieMotionProxy,NSView?,CALayer)]=[:]
        let transcript=d.transcripts[d.conversation!.id]!
        let beforeIndex=transcript.fullIndexRebuildCount
        let opened=scenario=="terminal-close"
        if opened{d.setTerminalShown(true,animated:false);d.view.layoutSubtreeIfNeeded()}
        if scenario=="terminal-long"{_ = d.composer?.setText(String(repeating:"中文草稿 retained editor and selection.\n",count:35));d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded()}
        let layoutBefore=d.terminalFullLayoutCount
        let beforePreparationEditor=d.composer!.textView
        if scenario=="terminal-long"{beforePreparationEditor.setSelectedRange(NSRange(location:4,length:9))}
        let beforePreparationSelection=beforePreparationEditor.selectedRanges,beforePreparationScroll=d.composer!.scrollView.contentView.bounds.origin
        switch scenario{
        case "terminal-approval":
            d.conversation!.approvals=[.init(id:"overlap",title:"Approval while opening terminal",command:"printf harmless",note:"Overlap fixture",acceptLabel:"Run",toolItemID:"")];d.show(d.conversation);d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded();d.setTerminalShown(true)
        case "toast":d.showNotice("Archived conversation — the draft is still here.",undo:true)
        case "toast-out":d.showNotice("Archived conversation — the draft is still here.",undo:true);d.motionClock.advance(to:1001);d.dismissNotice()
        case "approval":
            d.conversation!.approvals=[.init(id:"m10-approval",title:"Run this command?",command:"printf harmless",note:"Approval motion fixture",acceptLabel:"Run",toolItemID:"")]
            d.show(d.conversation);d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded()
        case "approval-reflow":
            let a=Approval(id:"m10-first",title:"First request",command:"printf first",note:"Fixture",acceptLabel:"Run",toolItemID:"")
            d.conversation!.approvals=[a];d.show(d.conversation);d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded()
            d.motionClock.advance(to:1001);d.view.layoutSubtreeIfNeeded()
            d.conversation!.approvals=[a,.init(id:"m10-second",title:"Second request",command:"printf second",note:"Fixture",acceptLabel:"Run",toolItemID:"")]
            d.show(d.conversation);d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded()
        default:d.setTerminalShown(!opened)
        }
        run.preparation=d.motionPreparationMS
        let editor=d.composer!.textView,selection=editor.selectedRanges
        if scenario=="terminal-long"{
            check(beforePreparationScroll == d.composer!.scrollView.contentView.bounds.origin,"preparation never clamps the future editor viewport")
            check(beforePreparationSelection == editor.selectedRanges && editor === beforePreparationEditor,"preparation preserves a nonempty native selection")
        }
        let base=d.motionClock.now
        let actualLayoutBefore=d.terminalFullLayoutCount
        for k in 0...Int(1.1*hz){
            let t=base+Double(k)/hz
            let start=CACurrentMediaTime();d.motionClock.advance(to:t);run.timings.append((CACurrentMediaTime()-start)*1000)
            run.records+=record(d,k,t-base,enabled)
            check(d.composer!.textView === editor && editor.selectedRanges == selection,"same editor/selection at frame \(k)")
            for proxy in d.activeMotionProxies{if let source=proxy.nativeSource,source.isDescendant(of:d.composer!){check(source.alphaValue>0,"proxy changes visual layer, never semantic NSView alpha")}
                for material in proxy.picture.glasses{if let glass=material.view{check(CATransform3DIsIdentity(glass.layer?.transform ?? CATransform3DIdentity),"glass transform always identity")}}}
            if renderPixels{run.frames.append(render(d,host,renderer,t,&seen))}
            if scenario=="terminal-reverse" && k==Int(0.1*hz){d.setTerminalShown(false)}
        }
        run.layouts=d.terminalFullLayoutCount-actualLayoutBefore
        run.indexBuilds=transcript.fullIndexRebuildCount-beforeIndex
        check(run.indexBuilds <= (scenario.hasPrefix("approval") || scenario=="terminal-approval" ? 2:0),"no per-frame transcript index rebuild during \(scenario)")
        if scenario.hasPrefix("terminal"){
            check(d.activeMotionProxies.isEmpty && !d.motionClock.running,"terminal leaves no motion work")
            check(d.terminalFullLayoutCount-layoutBefore<8,"terminal does not synchronously full-layout the detail every frame")
        }
        d.disposeTerminal();d.disposeTranscripts()
        return run
    }
    static func spikes(_ frames:[[UInt8]],_ records:[[String:Any]],_ renderer:NormieMotionRenderer)->(raw:Int,unexpected:Int){
        guard frames.count>6 else{return (0,0)}
        let s=(1..<frames.count).map{renderer.tileDiff(frames[$0-1],frames[$0]).value}
        var raw=0,unexpected=0
        for k in 2..<(s.count-2){
            let around=[s[k-2],s[k-1],s[k+1],s[k+2]].sorted(),median=(around[1]+around[2])/2
            if s[k]>8 && s[k]>3*median+2{
                raw+=1
                // Use the original App/SelfTest threshold, without a geometry or quantization exemption.
                unexpected+=1;print("SPIKE frame \(k+1): \(s[k]) neighbors \(around)")
            }
        };return (raw,unexpected)
    }
    static func sheet(_ off:Run,_ on:Run,_ name:String,_ out:URL){
        let isInspector=name.hasPrefix("inspector")
        let selected=isInspector ? [0,1,2,3,6,12,30,66]:[0,1,2,3,4,6,8,12,18,30,50,66],w=isInspector ? 420:540,h=isInspector ? 760:260
        let ctx=CGContext(data:nil,width:w*2,height:(h+26)*selected.count,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(white:0.06,alpha:1).cgColor);ctx.fill(CGRect(x:0,y:0,width:ctx.width,height:ctx.height))
        let host=CALayer(),renderer=NormieMotionRenderer(size:CGSize(width:1080,height:760),host:host)
        for (row,k) in selected.enumerated(){
            let y=ctx.height-(row+1)*(h+26)
            for (col,run) in [off,on].enumerated(){
                let full=renderer.image(run.frames[k]),crop=full.cropping(to:isInspector ? CGRect(x:0,y:0,width:420,height:760):CGRect(x:0,y:240,width:1080,height:520))!
                ctx.draw(crop,in:CGRect(x:col*w,y:y,width:w,height:h))
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
                let records=run.records.filter{($0["frame"] as? Int)==k},step=records.compactMap{$0["rawStepPt"] as? CGFloat}.max() ?? 0
                (String(format:"%@ · f%02d · step %.2fpt",col==0 ? "Sharp":"M10",k,step) as NSString).draw(at:CGPoint(x:col*w+8,y:y+h+5),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.white])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        writeImage(ctx.makeImage()!,out.appendingPathComponent(name+"-compare.png"))
    }
    static func staticAndNative(_ out:URL)throws->[[String:Any]]{
        var states:[[String:Any]]=[]
        for scale:CGFloat in [1,2]{
            let d=factory();(d.view as? NormieView)?.verificationScale=scale;d.composer?.verificationScale=scale
            let c=d.composer!,editor=c.textView,undo=editor.undoManager
            for name in ["empty","long","attachment","voice","sending","stopping"]{
                c.state.running=false;c.state.sending=false;c.state.stopping=false;c.state.voice=nil;c.attachments=[]
                _ = c.setText(name=="empty" ? "":name=="long" ? String(repeating:"A readable draft on a new line.\n",count:25):"A retained draft.")
                if name=="attachment"{c.attachments=[.init(id:"m10-file",name:"fixture.txt",symbol:"doc",input:["type":"text","text":"fixture"])]}
                if name=="voice"{c.state.voice="The original voice transcript"}
                if name=="sending"{c.state.sending=true}
                if name=="stopping"{c.state.running=true;c.state.stopping=true}
                d.view.needsLayout=true;d.view.layoutSubtreeIfNeeded()
                d.motionProcessingEnabled=false;let off=NativeViewBitmap.capture(d.view,scale:scale)
                d.motionProcessingEnabled=true;let on=NativeViewBitmap.capture(d.view,scale:scale)
                check(rgba(off)==rgba(on),"static \(name) \(scale)x is byte-identical")
                check(c.textView===editor && c.textView.undoManager===undo,"composer identity and Undo retained")
                states.append(["state":name,"scale":scale,"height":c.frame.height,"restPixelDifference":0,"kind":"product-instant/no-M10"])
                writeImage(on,out.appendingPathComponent("static-\(name)@\(Int(scale))x.png"))
            }
            let original=NativePrimaryButton(title:"",target:nil,action:nil),button=NativePrimaryButton(title:"",target:nil,action:nil)
            let motion=NativeComposerPressMotion(button);motion.setPressed(false,animated:false)
            for b in [original as NSButton,button]{b.frame=CGRect(x:0,y:0,width:28,height:28);b.image=NSImage(systemSymbolName:"arrow.up",accessibilityDescription:nil)}
            for enabled in [false,true]{
                original.isEnabled=enabled;button.isEnabled=enabled
                check(rgba(NativeViewBitmap.capture(original,scale:scale))==rgba(NativeViewBitmap.capture(button,scale:scale)),"Send original/rest draw identical \(scale)x enabled \(enabled)")
            }
            d.disposeTerminal();d.disposeTranscripts()
        }
        // Every animated capsule/press frame is recorded, even when the entire run is below the onset.
        for kind in ["press"]+(0..<7).map{"voice-\($0)"}{
            var last=CGRect(x:0,y:0,width:28,height:28),maxStep:CGFloat=0
            for k in 0...120{
                let t=Double(k)/60,now:CGRect
                if kind=="press"{
                    let f=1-0.12*SwiftUI.Spring(response:0.22,dampingRatio:0.55).value(target:1,initialVelocity:0,time:min(1,t))
                    now=CGRect(x:14-14*f,y:14-14*f,width:28*f,height:28*f)
                }else{
                    let i=Int(kind.split(separator:"-").last!)!,duration=0.45+Double(i)*0.04,cycle=t.truncatingRemainder(dividingBy:duration*2)
                    let f=cycle<=duration ? cycle/duration:2-cycle/duration
                    let eased=easeInOut(f),height=NativeComposerVoiceWaveform.low[i]+(NativeComposerVoiceWaveform.high[i]-NativeComposerVoiceWaveform.low[i])*eased
                    now=CGRect(x:0,y:20-height/2,width:3,height:height)
                }
                if k>0{let step=MotionStep.edge(now,last);maxStep=max(maxStep,step);check(Double(step)*0.27<1.08,"\(kind) has no above-onset frame");controlRecords.append(["scenario":kind,"object":kind,"frame":k,"t":t,"rawStepPt":step,"stepMM":Double(step)*0.27,"gate":0,"copies":1,"lengthPt":0,"alpha":1])};last=now
            }
            states.append(["state":kind,"maxStepPt":maxStep,"maxStepMM":Double(maxStep)*0.27,"maxGate":0,"copies":1])
        }
        return states
    }
    static func easeInOut(_ x:Double)->Double{
        var lo=0.0,hi=1.0
        for _ in 0..<30{let t=(lo+hi)/2,a=1-t,v=3*a*a*t*0.42+3*a*t*t*0.58+t*t*t;if v<x{lo=t}else{hi=t}}
        let t=(lo+hi)/2;return 3*(1-t)*t*t+t*t*t
    }
    static func inspector(_ enabled:Bool,_ scenario:String,hz:Double=60,scale:CGFloat=1,renderPixels:Bool=true)->Run{
        let seed=MockSeed.make()[0],store=ConversationStore(conversations:[seed],projects:MockSeed.projects,devices:MockSeed.devices)
        let d=NormieInspectorController(store:store,actions:NormieActions());d.view.frame=CGRect(x:0,y:0,width:420,height:760);(d.view as? NormieView)?.verificationScale=scale;d.show(seed);d.view.layoutSubtreeIfNeeded()
        if scenario=="inspector-plan"{d.showStatus()}else{d.showChanges()};d.view.layoutSubtreeIfNeeded()
        d.motion.enabled=enabled;d.motion.clock.manualTime=1000;d.motion.clock.manualProfile=profile;d.motion.clock.manualProfile.frameInterval=1/hz
        if scenario=="inspector-collapse",let first=seed.changes.first{d.toggleFile(first.path);d.motion.clock.advance(to:1001)}
        if scenario=="inspector-plan"{seed.plan.append(.init(id:"m10-plan",title:"Review the native transition without changing files"));d.show(seed)}else if scenario=="inspector-commit"{_ = d.beginCommit()}else if let first=seed.changes.first{d.toggleFile(first.path)}
        let host=CALayer();host.backgroundColor=NativePalette.canvas.cgColor;let renderer=NormieMotionRenderer(size:CGSize(width:1080,height:760),host:host)
        var seen:[ObjectIdentifier:(NormieMotionProxy,NSView?,CALayer)]=[:],run=Run();let start=d.motion.clock.now
        for k in 0...Int(1.1*hz){
            let t=start+Double(k)/hz,began=CACurrentMediaTime();d.motion.clock.advance(to:t);run.timings.append((CACurrentMediaTime()-began)*1000)
            CATransaction.begin();CATransaction.setDisableActions(true)
            for motion in d.motion.motions{let p=motion.proxy,id=ObjectIdentifier(p);if seen[id] == nil{let raw=CALayer();raw.contents=p.picture.full;host.addSublayer(raw);seen[id]=(p,p.nativeSource,raw)}
                let s=p.sample,step=MotionStep.edge(p.nativeRect,p.earlierRect)
                check(abs(Double(s.gate)-(enabled ? smoothstep(1.08,2.7,Double(step)*0.27):0))<1e-8,"inspector actual gate")
                if enabled && s.count>1{check(s.length+1e-7>=step*s.gate && s.length/CGFloat(s.count-1)<=1.5+1e-7,"inspector continuous sweep")}
                let row:[String:Any]=["scenario":scenario,"object":p.nativeSource.map{String(describing:type(of:$0))} ?? "exit","frame":k,"t":t-start,"rawStepPt":step,"stepMM":Double(step)*0.27,"gate":s.gate,"copies":s.count,"lengthPt":s.length,"spacingPt":s.count>1 ? s.length/CGFloat(s.count-1):0,"enabled":enabled]
                run.records.append(row)
            }
            for (_,entry) in seen{let(p,source,raw)=entry;drawClone(p,in:host);raw.frame=p.nativeRect;raw.opacity=p.layer.opacity;raw.isHidden = !p.layer.isHidden || source == nil || source?.superview == nil
                if let clip=p.clippingView{let mask=CAShapeLayer(),r=clip.convert(clip.bounds,to:d.view);mask.path=CGPath(rect:r.offsetBy(dx:-raw.frame.minX,dy:-raw.frame.minY),transform:nil);raw.mask=mask}
            }
            CATransaction.commit();if renderPixels{run.frames.append(renderer.render(at:t))}
        }
        d.motion.settle();check(d.motion.motions.isEmpty && !d.motion.clock.running,"inspector motion cleanup")
        return run
    }
    static func controlMontage(_ out:URL){
        let selected=[0,1,2,3,4,6,8,12,18,30,50,66]
        let button=NativePrimaryButton(title:"",target:nil,action:nil);button.frame=CGRect(x:0,y:0,width:28,height:28);button.image=NSImage(systemSymbolName:"arrow.up",accessibilityDescription:nil)
        let image=NativeViewBitmap.capture(button,scale:2)
        let motion=NativeComposerPressMotion(button);motion.setPressed(true)
        if let a=button.layer?.animation(forKey:"composer.press.transform.scale") as? CASpringAnimation{
            let omega=2*Double.pi/0.22
            check(abs(a.stiffness-omega*omega)<1e-8 && abs(a.damping-2*0.55*omega)<1e-8,"actual native Send cell uses product spring")
        }else{check(false,"native Send press installs CA spring")};motion.setPressed(false,animated:false)
        for name in ["send-press","voice-waveform"]{
            let w=560,rowH=112,c=CGContext(data:nil,width:w,height:rowH*selected.count,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(NativePalette.canvas.cgColor);c.fill(CGRect(x:0,y:0,width:c.width,height:c.height))
            for (row,k) in selected.enumerated(){let t=Double(k)/60,y=c.height-(row+1)*rowH
                for col in 0..<2{
                    c.saveGState();c.translateBy(x:CGFloat(col*280+80),y:CGFloat(y+18));c.scaleBy(x:2,y:2)
                    if name=="send-press"{let p=1-0.12*SwiftUI.Spring(response:0.22,dampingRatio:0.55).value(target:Double(1),initialVelocity:Double(0),time:t);c.draw(image,in:CGRect(x:14-14*p,y:14-14*p,width:28*p,height:28*p))}
                    else{for i in 0..<7{let duration=0.45+Double(i)*0.04,cycle=t.truncatingRemainder(dividingBy:duration*2),f=cycle<=duration ? cycle/duration:2-cycle/duration
                        let h=NativeComposerVoiceWaveform.low[i]+(NativeComposerVoiceWaveform.high[i]-NativeComposerVoiceWaveform.low[i])*easeInOut(f)
                        c.setFillColor(NativeAppearance.current.accentColor.cgColor);c.addPath(CGPath(roundedRect:CGRect(x:CGFloat(i)*5.5,y:20-h/2,width:3,height:h),cornerWidth:1.5,cornerHeight:1.5,transform:nil));c.fillPath()
                    }}
                    c.restoreGState();NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
                    ("\(col==0 ? "Sharp":"M10") · f\(k) · gate 0 · 2× crop" as NSString).draw(at:CGPoint(x:col*280+8,y:y+88),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.regular),.foregroundColor:NativePalette.label]);NSGraphicsContext.restoreGraphicsState()
                }
            };writeImage(c.makeImage()!,out.appendingPathComponent(name+"-compare.png"))
        }
    }
    static func percentile(_ a:[Double],_ q:Double)->Double{let a=a.sorted();return a[min(a.count-1,Int(Double(a.count-1)*q))]}
    static func main() throws{
        _ = NSApplication.shared;NSApp.appearance=NSAppearance(named:.darkAqua)
        if ProcessInfo.processInfo.environment["NORMIE_INK_REGION_PROBE"] == "1"{try inkRegionChecks(URL(fileURLWithPath:CommandLine.arguments[1]));if !failures.isEmpty{exit(1)};return}
        if ProcessInfo.processInfo.environment["NORMIE_STARTUP_PROBE"] == "1"{try startupChecks(URL(fileURLWithPath:CommandLine.arguments[1]));if !failures.isEmpty{exit(1)};return}
        if ProcessInfo.processInfo.environment["NORMIE_ALPHA_PROBE"] == "1"{try alphaChecks(URL(fileURLWithPath:CommandLine.arguments[1]));if !failures.isEmpty{exit(1)};return}
        if ProcessInfo.processInfo.environment["NORMIE_HANDOFF_PROBE"] == "1"{try handoffChecks(URL(fileURLWithPath:CommandLine.arguments[1]));if !failures.isEmpty{exit(1)};return}
        if ProcessInfo.processInfo.environment["NORMIE_STACK_PROBE"] == "1"{try livePipelineChecks(URL(fileURLWithPath:CommandLine.arguments[1]));if !failures.isEmpty{exit(1)};return}
        let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        try alphaChecks(out)
        try inkRegionChecks(out)
        try livePipelineChecks(out)
        try handoffChecks(out)
        let states=try staticAndNative(out)
        controlMontage(out)
        var summary:[[String:Any]]=[],allRecords=controlRecords
        let spikeHost=CALayer(),spikeRenderer=NormieMotionRenderer(size:CGSize(width:1080,height:760),host:spikeHost)
        for scenario in ["terminal-open","terminal-close","terminal-reverse","terminal-long","terminal-approval","approval","approval-reflow","toast","toast-out","inspector-expand","inspector-collapse","inspector-commit","inspector-plan"]{
            print("Rendering "+scenario);fflush(stdout)
            let off=scenario.hasPrefix("inspector") ? inspector(false,scenario):run(scenario,enabled:false),on=scenario.hasPrefix("inspector") ? inspector(true,scenario):run(scenario,enabled:true)
            let offSpikes=spikes(off.frames,off.records,spikeRenderer),onSpikes=spikes(on.frames,on.records,spikeRenderer)
            check(offSpikes.unexpected==0 && onSpikes.unexpected==0,"no spikes sharp/M10 \(scenario): \(offSpikes)/\(onSpikes)")
            check(off.frames.first==on.frames.first,"first frame identical \(scenario)")
            check(off.frames.last==on.frames.last,"last frame identical \(scenario)")
            let maxStep=on.records.compactMap{$0["rawStepPt"] as? CGFloat}.max() ?? 0
            let maxLength=on.records.compactMap{$0["lengthPt"] as? CGFloat}.max() ?? 0
            let maxCount=on.records.compactMap{$0["copies"] as? Int}.max() ?? 1
            let maximumSpacing=on.records.compactMap{$0["spacingPt"] as? CGFloat}.max() ?? 0
            summary.append(["scenario":scenario,"maxRawStepPt":maxStep,"maxRawStepMM":Double(maxStep)*0.27,"maxLengthPt":maxLength,"maxCopies":maxCount,"maxSpacingPt":maximumSpacing,"sharpSpikes":offSpikes.unexpected,"m10Spikes":onSpikes.unexpected,"sharpRawPixelSpikes":offSpikes.raw,"m10RawPixelSpikes":onSpikes.raw,"firstPixelDifference":off.frames.first==on.frames.first ? 0:1,"lastPixelDifference":off.frames.last==on.frames.last ? 0:1,"prepareMS":on.preparation,"callbackSharpP95MS":percentile(off.timings,0.95),"callbackM10P95MS":percentile(on.timings,0.95),"fullLayouts":on.layouts])
            allRecords+=off.records.map{var r=$0;r["scenario"]=scenario;return r}+on.records.map{var r=$0;r["scenario"]=scenario;return r}
            let frames=out.appendingPathComponent(scenario);try FileManager.default.createDirectory(at:frames,withIntermediateDirectories:true)
            for k in 0..<on.frames.count{
                writeImage(spikeRenderer.image(off.frames[k]),frames.appendingPathComponent(String(format:"sharp-%03d.png",k)))
                writeImage(spikeRenderer.image(on.frames[k]),frames.appendingPathComponent(String(format:"m10-%03d.png",k)))
            }
            sheet(off,on,scenario,out)
        }
        // Callback-only 120Hz/2x budget; capture/render is separate from the main-thread update cost.
        let d=factory();(d.view as? NormieView)?.verificationScale=2;d.composer?.verificationScale=2
        d.motionClock.manualProfile.frameInterval=1/120
        var timing:[[String:Any]]=[]
        for enabled in [false,true]{
            d.setTerminalShown(false,animated:false);d.view.layoutSubtreeIfNeeded();d.motionClock.manualTime=2000;d.motionProcessingEnabled=enabled;d.prepareMotionPictures();d.setTerminalShown(true)
            var times:[Double]=[]
            for k in 0...100{let start=CACurrentMediaTime();d.motionClock.advance(to:2000+Double(k)/120);times.append((CACurrentMediaTime()-start)*1000)}
            timing.append(["enabled":enabled,"p50MS":percentile(times,0.5),"p95MS":percentile(times,0.95),"maxMS":times.max()!,"preparationMS":d.motionPreparationMS,"idleWarmupMS":d.motionWarmupMS])
        }
        let currentEditor=d.composer!.textView,selection=currentEditor.selectedRanges,origin=d.composer!.scrollView.contentView.bounds.origin
        d.setTerminalShown(false,animated:false);d.view.layoutSubtreeIfNeeded();d.motionClock.manualTime=3000;d.motionProcessingEnabled=true;d.prepareMotionPictures();d.setTerminalShown(true)
        _ = d.composer!.setText("Updated while moving — 中文输入保留。");d.terminalPane.runMock("printf harmless")
        d.motionClock.advance(to:3000+1/60)
        check(d.composer!.textView === currentEditor,"changing draft during motion retains editor")
        check(d.motionRecaptureMS.count>0,"dirty text/terminal content refreshed, never a stale fixed transition image")
        let recaptures=d.motionRecaptureMS
        d.setTranscriptPresentationActive(false)
        check(d.activeMotionProxies.isEmpty && !d.motionClock.running,"handoff retires all pictures and material adapters")
        check(d.composer!.textView === currentEditor,"handoff does not replace editor")
        _ = selection;_ = origin
        d.disposeTerminal();d.disposeTranscripts()
        var objectCosts:[[String:Any]]=[]
        for scenario in ["terminal-long","approval","approval-reflow","toast","toast-out","inspector-expand","inspector-collapse","inspector-commit","inspector-plan"]{
            let sharp=scenario.hasPrefix("inspector") ? inspector(false,scenario,hz:120,scale:2,renderPixels:false):run(scenario,enabled:false,renderPixels:false,hz:120,scale:2)
            let processed=scenario.hasPrefix("inspector") ? inspector(true,scenario,hz:120,scale:2,renderPixels:false):run(scenario,enabled:true,renderPixels:false,hz:120,scale:2)
            let a=percentile(sharp.timings,0.95),b=percentile(processed.timings,0.95)
            objectCosts.append(["object":scenario,"sharpP95MS":a,"m10P95MS":b,"increaseMS":b-a])
            if ProcessInfo.processInfo.environment["NORMIE_CHECK_CONFIGURATION"] != "debug"{check(b-a<=0.5,"120Hz2x \(scenario) callback p95 increase <=.5ms: \(b-a)")}
        }
        let delta=(timing[1]["p95MS"] as! Double)-(timing[0]["p95MS"] as! Double)
        if ProcessInfo.processInfo.environment["NORMIE_CHECK_CONFIGURATION"] != "debug"{check(delta<=0.5,"120Hz2x callback p95 increase <=.5ms: \(delta)")}
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible window or application event loop")
        let result:[String:Any]=["checks":checks,"findings":failures,"profile":["hz":60,"mmPerPoint":0.27],"scenarios":summary,"nativeStates":states,"cost120Hz2x":timing,"p95IncreaseMS":delta,"dirtyRecaptureMS":recaptures,"otherCosts120Hz2x":objectCosts,"terminalRenderer":ToolsTerminalSurface.fullVTCompatibility ? "SwiftTerm":"limited-ANSI fallback (standalone swiftc)","boundary":"Offscreen AppKit cacheDisplay + in-process CARenderer. No WindowServer refraction, physical presentation timing, IME or human-board claim."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
        try JSONSerialization.data(withJSONObject:allRecords,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("frames.json"))
        let report="M10-C: \(checks) checks, \(failures.count) findings\n"+failures.joined(separator:"\n")+"\n"
        try report.write(to:out.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8);print(report)
        if !failures.isEmpty{exit(1)}
    }
}

#endif
