import AppKit
import QuartzCore

/// Immutable glyph ink, prepared by configure(), never by the host's display-frame callback.
/// Native drawing remains the exact still representation; only a plain, tight bitmap is replicated.
@MainActor final class OrbHostInk {
    let carrier=CALayer(),trail=ChordTrail(),bitmap=CALayer()
    private(set) var sample=ExposureSample.still
    private(set) var captures=0
    private(set) var sceneRect=CGRect.zero,earlierRect=CGRect.zero
    private var rect=CGRect.zero,size=CGSize.zero
    #if M10_DOCK_SELFTEST
    var verificationRect:CGRect {rect}
    #endif
    init(){carrier.addSublayer(trail.layer);trail.layer.addSublayer(bitmap);carrier.isHidden=true}
    /// Reuse an already decoded body image; rendering a bitmap layer again would reverse its rows.
    func prepare(image: CGImage, size: CGSize) {
        guard size.width>0,size.height>0 else { return }
        bitmap.contents=image; bitmap.contentsScale=CGFloat(image.width)/size.width
        rect=CGRect(origin:.zero,size:size); self.size=size
        ReplicaContainerAudit.register(bitmap,material:.glyph,note:"Orb shared static body image; independent alpha bitmap")
    }
    func prepare(_ source:CALayer,scale:CGFloat,topDown:Bool=false){
        let box=source.bounds,w=Int(ceil(box.width*scale)),h=Int(ceil(box.height*scale))
        guard w>0,h>0,let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return}
        c.scaleBy(x:scale,y:scale)
        // Mounted sources inherit ancestor parity; pickup also requests top-down rows before mounting.
        if topDown || source.contentsAreFlipped() {c.translateBy(x:0,y:box.height);c.scaleBy(x:1,y:-1)}
        let hidden=source.isHidden,opacity=source.opacity;source.isHidden=false;source.opacity=1;source.render(in:c);source.isHidden=hidden;source.opacity=opacity
        let p=c.data!.assumingMemoryBound(to:UInt8.self)
        var x0=w,y0=h,x1=0,y1=0
        for y in 0..<h{for x in 0..<w where p[(y*w+x)*4+3]>0{x0=min(x0,x);y0=min(y0,y);x1=max(x1,x+1);y1=max(y1,y+1)}}
        guard x1>x0,y1>y0 else{bitmap.contents=nil;return}
        let width=x1-x0,height=y1-y0,row=width*4
        var bytes=Data(count:row*height)
        bytes.withUnsafeMutableBytes{d in for y in 0..<height{d.baseAddress!.advanced(by:y*row).copyMemory(from:p.advanced(by:((y+y0)*w+x0)*4),byteCount:row)}}
        bitmap.contents=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:row,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
        bitmap.contentsScale=scale
        ReplicaContainerAudit.register(bitmap,material:.glyph,note:"Orb own drawing; transparent tight independent ink")
        rect=CGRect(x:CGFloat(x0)/scale,y:CGFloat(y0)/scale,width:CGFloat(width)/scale,height:CGFloat(height)/scale);size=box.size;captures+=1
    }
    /// now/earlier are the un-stretched ink boxes in scene points. parent is this carrier's actual native
    /// parent box in the same scene. The inverse is ink-only: glass/liquid/badge plates never enter this tree.
    func update(now:CGRect,earlier:CGRect,parent:CGRect,parentSize:CGSize,profile:DisplayProfile,enabled:Bool){
        guard enabled,bitmap.contents != nil,now.width>0,now.height>0,parent.width>0,parent.height>0,size.width>0 else{reset();return}
        func mapped(_ pose:CGRect)->CGRect{CGRect(x:pose.minX+rect.minX*pose.width/size.width,y:pose.minY+rect.minY*pose.height/size.height,width:rect.width*pose.width/size.width,height:rect.height*pose.height/size.height)}
        let a=mapped(now),b=mapped(earlier),local=CGRect(origin:.zero,size:a.size),old=b.offsetBy(dx:-a.minX,dy:-a.minY)
        sceneRect=a;earlierRect=b
        trail.settings=M10FExposure.settings(now:local,earlier:old)
        sample=M10FExposure.sample(now:local,earlier:old,profile:profile,settings:trail.settings)
        carrier.isHidden=sample.count==1
        carrier.anchorPoint = .zero;carrier.position = .zero;carrier.bounds=CGRect(origin:.zero,size:parentSize)
        carrier.setAffineTransform(CGAffineTransform(a:parentSize.width/parent.width,b:0,c:0,d:parentSize.height/parent.height,tx:-parent.minX*parentSize.width/parent.width,ty:-parent.minY*parentSize.height/parent.height))
        trail.layer.frame=a;bitmap.frame=local
        M10FExposure.apply(sample,to:trail,now:local,earlier:old)
    }
    func reusePreparedInk(from source:OrbHostInk) {
        bitmap.contents=source.bitmap.contents;bitmap.contentsScale=source.bitmap.contentsScale
        rect=source.rect;size=source.size
    }
    func installPreparedBitmap(in parent:CALayer,size:CGSize) {
        bitmap.removeFromSuperlayer();parent.addSublayer(bitmap)
        bitmap.anchorPoint = .zero;bitmap.frame=rect
        ReplicaContainerAudit.register(bitmap,material:.glyph,note:"Orb own drawing; baked shadow; tight independent alpha bitmap")
    }
    func reset(){sample = .still;trail.reset();carrier.isHidden=true}
}
