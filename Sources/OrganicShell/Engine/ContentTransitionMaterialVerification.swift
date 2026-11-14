#if M101_SELFTEST
import AppKit
import QuartzCore
import Metal
import ImageIO

@main @MainActor enum M101Verification {
    static func main() throws {
        let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],rows:[[String:Any]]=[]
        func check(_ v:Bool,_ name:String) { checks+=1;if !v { failures.append(name);print("FAIL "+name) } }
        for scale:CGFloat in [1,2] {
            let clock=SceneClock(),root=CALayer(),ink=CALayer()
            root.backgroundColor=NSColor(white:0.13,alpha:1).cgColor
            ink.frame=CGRect(x:40,y:40,width:180,height:60);root.addSublayer(ink)
            let image=texture();ink.contents=image;ink.contentsScale=2
            let r=M101Renderer(size:CGSize(width:260,height:140),host:root,scale:scale)
            let begin=VerificationClock.renderOrigin
            let reference=r.render(at:begin-1)
            let c=ContentGaussianTransition(content:ink,clock:clock,configuration:.spotlight)
            check(reference == r.render(at:begin-0.5),"init exact \(scale)")
            c.setVisible(false,at:begin)
            check(reference == r.render(at:begin),"exit first exact \(scale)")
            check(c.filterAvailable,"private gaussianBlur available")
            var frames:[[UInt8]]=[]
            for i in 0...24 { frames.append(r.render(at:begin+Double(i)/240)) }
            check(frames.first != frames[12],"filter/fade/scale rendered \(scale)")
            let hidden=frames.last!
            check(c.settle(at:begin+0.101),"exit settles")
            check(hidden==r.render(at:begin+0.102),"exit last exact \(scale)")
            check(ink.filters?.isEmpty != false,"endpoint filter removed")
            c.setVisible(true,at:begin+1)
            check(hidden==r.render(at:begin+1),"entrance first exact \(scale)")
            var deltas:[Double]=[],appearFrames:[[UInt8]]=[],previous=hidden
            for i in 0...24 {
                let f=r.render(at:begin+1+Double(i)/240)
                deltas.append(r.diff(previous,f));appearFrames.append(f);previous=f
                if i%4==0 { try r.write(f,out.appendingPathComponent("appear-\(Int(scale))x-\(i).png")) }
            }
            for rate in [60,120,240] {
                let strideBy=240/rate
                let sample=stride(from:strideBy,through:24,by:strideBy).map { r.diff(appearFrames[$0-strideBy],appearFrames[$0]) }
                if sample.count>4 { for i in 2..<(sample.count-2) {
                    let around=[sample[i-2],sample[i-1],sample[i+1],sample[i+2]].sorted()
                    check(!(sample[i]>8 && sample[i]>3*(around[1]+around[2])/2+2),"no isolated spike \(rate)Hz \(scale)x")
                } }
            }
            let last=r.render(at:begin+1.1);c.settle(at:begin+1.101)
            let afterSettle=r.render(at:begin+1.102)
            if last != afterSettle { try r.write(last,out.appendingPathComponent("end-before-\(Int(scale)).png"));try r.write(afterSettle,out.appendingPathComponent("end-after-\(Int(scale)).png"));print("end max",r.maxDiff(last,afterSettle)) }
            check(last==afterSettle,"entrance last exact \(scale)")
            check(reference==r.render(at:begin+1.103),"roundtrip exact \(scale)")
            // At arbitrary, non-grid offsets compare identical media times before and after a reverse submission.
            var reverseDiffs:[Int]=[]
            for (j,offset) in [0.003,0.017,0.037,0.071,0.097].enumerated() {
                let t=begin+2+Double(j)
                c.setVisible(false,at:t)
                let from=c.pose(at:t+offset),velocity=c.plan!.velocity(at:t+offset),before=r.render(at:t+offset)
                c.setVisible(true,at:t+offset)
                let after=r.render(at:t+offset),d=r.maxDiff(before,after)
                reverseDiffs.append(d)
                check(c.plan?.from==from,"reverse analytical current pose")
                check(c.plan?.initialVelocity==velocity,"reverse carries current table velocity")
                check(d<=1,"reverse no pixel step \(scale) \(offset) diff \(d)")
                c.settle(at:t+0.3)
            }
            c.setVisible(false,at:begin+8)
            let freezeBefore=r.render(at:begin+8.037);c.freeze(at:begin+8.037)
            check(freezeBefore==r.render(at:begin+8.037),"freeze exact current pose \(scale)")
            c.setVisible(true,at:begin+8.04,animated:false)
            check(reference==r.render(at:begin+8.04),"disable interrupted effect exact sharp reference \(scale)")
            check(ink.filters?.isEmpty != false && (ink.animationKeys() ?? []).isEmpty,"disable interrupted effect clears own state")
            let other=CALayer();other.frame=ink.frame;other.contents=texture(alternate:true);other.contentsScale=2;root.addSublayer(other)
            let n=ContentGaussianTransition(content:other,clock:clock,initiallyVisible:false)
            let t=begin+9;ContentGaussianTransition.replace(old:c,new:n,at:t)
            let a=c.pose(at:t+0.05),b=n.pose(at:t+0.05)
            check(abs(a.opacity+b.opacity-1)<1e-10,"replace complementary opacity")
            check(root.sublayers?.count==2,"replace only old/new single layers")
            c.settle(at:t+0.11);n.settle(at:t+0.11)
            let settled=r.render(at:t+0.12)
            n.setVisible(true,at:t+1,animated:false)
            check(settled==r.render(at:t+1),"disabled visible exact \(scale)")
            n.setVisible(false,at:t+2,animated:false);c.setVisible(false,at:t+2,animated:false)
            check(hidden==r.render(at:t+2),"disabled hidden exact \(scale)")
            check((other.animationKeys() ?? []).isEmpty && other.filters?.isEmpty != false,"disabled no animation or filter")
            // Existing material stays independent, even while content blurs.
            let glass=CALayer();glass.backgroundColor=NSColor.gray.cgColor;root.insertSublayer(glass,at:0)
            n.setVisible(true,at:t+3)
            check(glass.filters==nil && CATransform3DIsIdentity(glass.transform),"glass untouched")
            rows.append(["scale":scale,"reverseMaxDiff":reverseDiffs.max() ?? 0,"appearSteps":deltas])
        }
        // Private-filter transfer calibration: white half-plane on an opaque dark canvas, at known layer-point radii.
        for scale: CGFloat in [1,2] {
            let root=CALayer(),edge=CALayer();root.backgroundColor=NSColor.black.cgColor
            edge.frame=CGRect(x:80,y:20,width:80,height:100)
            let context=CGContext(data:nil,width:80,height:100,bitsPerComponent:8,bytesPerRow:320,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:80,height:100));edge.contents=context.makeImage();root.addSublayer(edge)
            let r=M101Renderer(size:CGSize(width:240,height:140),host:root,scale:scale)
            let cls=NSClassFromString("CAFilter") as! NSObject.Type
            let filter=cls.perform(NSSelectorFromString("filterWithType:"),with:"gaussianBlur")!.takeUnretainedValue() as! NSObject
            edge.filters=[filter]
            for radius in [0.0,2,4,8,12] {
                filter.setValue(radius,forKey:"inputRadius");edge.filters=nil;edge.filters=[filter];CATransaction.flush()
                try r.write(r.render(at:VerificationClock.renderOrigin+radius),out.appendingPathComponent("kernel-\(Int(scale))x-r\(Int(radius)).png"))
            }
        }
        // Material detector negative/positive controls, including a manual-copy host and a baked container.
        let root=CALayer(),rep=CAReplicatorLayer(),bad=CALayer();rep.instanceCount=8;root.addSublayer(rep);rep.addSublayer(bad)
        bad.name="wash";bad.backgroundColor=NSColor.black.withAlphaComponent(0.2).cgColor
        check(!ReplicaContainerAudit.inspect(root,scenario:"negative",frame:0,time:0).isEmpty,"detect live container")
        bad.backgroundColor=nil;bad.name="ink"
        let icon=CGContext(data:nil,width:12,height:12,bitsPerComponent:8,bytesPerRow:48,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        icon.setFillColor(NSColor.white.cgColor);icon.fillEllipse(in:CGRect(x:1,y:1,width:10,height:10));bad.contents=icon.makeImage();bad.bounds=CGRect(x:0,y:0,width:12,height:12)
        ReplicaContainerAudit.register(bad,material:.glyph)
        check(ReplicaContainerAudit.inspect(root,scenario:"positive",frame:0,time:0).isEmpty,"allow registered tight glyph")
        let vector=CAShapeLayer();let path=CGMutablePath();path.move(to:.zero);path.addLine(to:CGPoint(x:10,y:10))
        vector.path=path;vector.fillColor=nil;vector.strokeColor=NSColor.white.cgColor;rep.addSublayer(vector)
        check(ReplicaContainerAudit.inspect(root,scenario:"vector",frame:0,time:0).contains{$0.reason.contains("live vector")},"reject live stroked vector inside replicas")
        vector.removeFromSuperlayer()
        let manual=CALayer();root.addSublayer(manual);ReplicaContainerAudit.registerCopies(manual)
        let mask=CALayer();manual.addSublayer(mask);mask.mask=CALayer()
        check(ReplicaContainerAudit.inspect(root,scenario:"manual",frame:0,time:0).contains{$0.reason.contains("mask")},"detect manual-copy mask")
        let report:[String:Any]=["checks":checks,"findings":failures,"rows":rows,"renderer":"CARenderer + Metal; no windows or event loop"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
        print("M10.1 Engine: \(checks) checks, \(failures.count) findings")
        if !failures.isEmpty { exit(1) }
    }
    static func texture(alternate:Bool=false)->CGImage {
        let c=CGContext(data:nil,width:360,height:120,bitsPerComponent:8,bytesPerRow:360*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x:2,y:2)
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:alternate ? "New content 􀆊":"Organic Codex 123",attributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.white]))
        c.textPosition=CGPoint(x:3,y:22);CTLineDraw(line,c);return c.makeImage()!
    }
}

@MainActor final class M101Renderer {
    let w:Int,h:Int
    let renderer:CARenderer,texture:MTLTexture,queue:MTLCommandQueue
    var warmed=false
    init(size:CGSize,host:CALayer,scale:CGFloat) {
        w=Int(size.width*scale);h=Int(size.height*scale)
        let device=MTLCreateSystemDefaultDevice()!;queue=device.makeCommandQueue()!
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
        d.usage=[.renderTarget,.shaderRead];d.storageMode = .managed;texture=device.makeTexture(descriptor:d)!
        renderer=CARenderer(mtlTexture:texture,options:[kCARendererMetalCommandQueue:queue])
        let mount=CALayer();mount.anchorPoint = .zero;mount.bounds=CGRect(x:0,y:0,width:w,height:h);renderer.layer=mount;renderer.bounds=mount.bounds;CATransaction.flush()
        CATransaction.begin();CATransaction.setDisableActions(true)
        host.anchorPoint = .zero;host.bounds=CGRect(origin:.zero,size:size);host.position = .zero;host.transform=CATransform3DMakeScale(scale,scale,1)
        mount.addSublayer(host);CATransaction.commit();CATransaction.flush()
    }
    func render(at t:Double)->[UInt8] {
        if !warmed { warmed=true;_ = render(at:t) }
        ReplicaAuditRecorder.sample(renderer.layer,at:t)
        CATransaction.flush();renderer.beginFrame(atTime:t,timeStamp:nil);renderer.addUpdate(renderer.bounds);renderer.render();renderer.endFrame()
        let b=queue.makeCommandBuffer()!,e=b.makeBlitCommandEncoder()!;e.synchronize(resource:texture);e.endEncoding();b.commit();b.waitUntilCompleted()
        var a=[UInt8](repeating:0,count:w*h*4);texture.getBytes(&a,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0);return a
    }
    func maxDiff(_ a:[UInt8],_ b:[UInt8])->Int { zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0 }
    func diff(_ a:[UInt8],_ b:[UInt8])->Double {
        var best=0.0
        for ty in stride(from:0,to:h,by:16) { for tx in stride(from:0,to:w,by:16) {
            var sum=0,n=0
            for y in ty..<min(h,ty+16) { for x in tx..<min(w,tx+16) {
                let i=(y*w+x)*4
                for c in 0..<3 {sum+=abs(Int(a[i+c])-Int(b[i+c]));n+=1}
            } }
            best=max(best,Double(sum)/Double(max(1,n)))
        } }
        return best
    }
    func write(_ bytes:[UInt8],_ url:URL)throws {
        let topDown=(0..<h).reversed().flatMap { bytes[($0*w*4)..<(($0+1)*w*4)] }
        let im=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue),provider:CGDataProvider(data:Data(topDown) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        try NSBitmapImageRep(cgImage:im).representation(using:.png,properties:[:])!.write(to:url)
    }
}
#endif
