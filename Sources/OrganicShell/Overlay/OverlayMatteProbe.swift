#if M10_MATTE_PROBE
import AppKit
import Metal

// Legacy isolated probe: M10.1 keeps the wash single, regardless of the former M10_MATTE_COPIES input. No app/Core.
struct OverlayExposureFrame { var time: Double; var sample: ExposureSample }
@main @MainActor enum OverlayMatteProbe {
    static func main() {
        let imageContext=CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        imageContext.setFillColor(CGColor(gray:0.3,alpha:0.5));imageContext.fill(CGRect(x:0,y:0,width:100,height:100))
        let image=imageContext.makeImage()!,device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:100,height:100,mipmapped:false);d.usage=[.renderTarget,.shaderRead];d.storageMode = .managed
        let texture=device.makeTexture(descriptor:d)!,r=CARenderer(mtlTexture:texture,options:[kCARendererMetalCommandQueue:queue])
        let root=CALayer();root.frame=CGRect(x:0,y:0,width:100,height:100);root.backgroundColor=CGColor(red:30/255,green:30/255,blue:30/255,alpha:1)
        r.layer=root;r.bounds=root.bounds;CATransaction.flush()
        let source=CALayer(),group=CALayer();source.anchorPoint = .zero;source.frame=root.bounds;source.contents=image;root.addSublayer(source)
        source.shadowColor = NSColor.black.cgColor; source.shadowOpacity = 0.42; source.shadowRadius = 18; source.shadowOffset = CGSize(width: 0, height: 16)
        group.anchorPoint = .zero;group.frame=root.bounds;root.addSublayer(group)
        let origin=VerificationClock.renderOrigin
        var pixels=[UInt8](repeating:0,count:40000)
        func read() -> UInt8 {
            for _ in 0..<3 {
                CATransaction.flush();r.beginFrame(atTime:origin+0.2,timeStamp:nil);r.addUpdate(r.bounds);r.render();r.endFrame()
                let b=queue.makeCommandBuffer()!,e=b.makeBlitCommandEncoder()!;e.synchronize(resource:texture);e.endEncoding();b.commit();b.waitUntilCompleted()
                texture.getBytes(&pixels,bytesPerRow:400,from:MTLRegionMake2D(0,0,100,100),mipmapLevel:0)
            }
            return pixels[(50*100+50)*4]
        }
        let expected = read()
        _ = OverlayWashExposure.prepare(group:group,source:source,image:image,animations:[],profile:DisplayProfile(name:"probe",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0),origin:origin)
        _ = read()
        let value=pixels[(50*100+50)*4]
        print("M10.1 single wash: native \(expected), unchanged \(value), copies 0")
        if abs(Int(value)-Int(expected))>1 {exit(1)}
    }
}
#endif
