#if OVERLAY_SELFTEST
import AppKit
import Metal

/// Compatibility entry: M10 movement and M10.1 appearance now share the audited verifier.
@MainActor enum OverlayM10Verification {
    static func run(output: URL, check: (Bool, String) -> Void) throws {
        try OverlayM101Verification.run(output:output,check:check)
    }
}

/// Same CARenderer/Metal readback path and 16×16 spike metric as App/SelfTest; intentionally owns no window.
@MainActor final class OverlayM101Renderer {
    let width: Int, height: Int, origin = VerificationClock.renderOrigin
    private let texture: MTLTexture, queue: MTLCommandQueue, renderer: CARenderer
    init(size: CGSize, root: CALayer, scale: CGFloat) {
        width = max(1,Int(ceil(size.width*scale))); height = max(1,Int(ceil(size.height*scale)))
        let device=MTLCreateSystemDefaultDevice()!;queue=device.makeCommandQueue()!
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        d.usage=[.renderTarget,.shaderRead];d.storageMode = .managed;texture=device.makeTexture(descriptor:d)!
        renderer=CARenderer(mtlTexture:texture,options:[kCARendererMetalCommandQueue:queue])
        let mount=CALayer();mount.anchorPoint = .zero;mount.bounds=CGRect(x:0,y:0,width:width,height:height)
        mount.backgroundColor=NSColor(srgbRed:0.118,green:0.118,blue:0.118,alpha:1).cgColor
        renderer.layer=mount;renderer.bounds=mount.bounds;CATransaction.flush()
        CATransaction.begin();CATransaction.setDisableActions(true)
        root.anchorPoint = .zero;root.bounds=CGRect(origin:.zero,size:size);root.position = .zero
        root.transform=CATransform3DMakeScale(scale,scale,1);root.isGeometryFlipped=true;mount.addSublayer(root)
        CATransaction.commit();CATransaction.flush();_ = render(at:0);_ = render(at:0)
    }
    func render(at time: Double) -> [UInt8] {
        CATransaction.flush();renderer.beginFrame(atTime:origin+time,timeStamp:nil);renderer.addUpdate(renderer.bounds);renderer.render();renderer.endFrame()
        let b=queue.makeCommandBuffer()!,e=b.makeBlitCommandEncoder()!;e.synchronize(resource:texture);e.endEncoding();b.commit();b.waitUntilCompleted()
        var pixels=[UInt8](repeating:0,count:width*height*4)
        texture.getBytes(&pixels,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
        return (0..<height).reversed().flatMap { pixels[($0*width*4)..<(($0+1)*width*4)] }
    }
    func image(_ bytes:[UInt8])->CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    func write(_ bytes:[UInt8],to url:URL)throws { try NSBitmapImageRep(cgImage:image(bytes)).representation(using:.png,properties:[:])!.write(to:url) }
    func tileDiff(_ a:[UInt8],_ b:[UInt8])->Double {
        var best=0.0
        for y in stride(from:0,to:height,by:16) {for x in stride(from:0,to:width,by:16) {
            var sum=0,n=0
            for yy in y..<min(height,y+16) {for xx in x..<min(width,x+16) {let k=(yy*width+xx)*4;for c in 0..<3 {sum+=abs(Int(a[k+c])-Int(b[k+c]));n+=1}}}
            best=max(best,Double(sum)/Double(n))
        }};return best
    }
    func sheet(off:[[UInt8]],on:[[UInt8]],to url:URL)throws {
        let indices=Array(Set([0,1,2,3,5,8,12,off.count-1].map { min($0,off.count-1) })).sorted()
        let factor=min(1,CGFloat(420)/CGFloat(width)),w=Int(CGFloat(width)*factor),h=Int(CGFloat(height)*factor)
        let c=CGContext(data:nil,width:w*indices.count,height:h*2,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (column,index) in indices.enumerated() {
            c.draw(image(off[index]),in:CGRect(x:column*w,y:h,width:w,height:h));c.draw(image(on[index]),in:CGRect(x:column*w,y:0,width:w,height:h))
        }
        try NSBitmapImageRep(cgImage:c.makeImage()!).representation(using:.png,properties:[:])!.write(to:url)
    }
}
#endif
