#if M11_MODE_SELFTEST
import AppKit
import QuartzCore

/// Software composition of the production photo/Dock layer order. WindowServer glass color is not simulated.
@MainActor enum ModeFadeSurfaceVerification {
    static func run(to output:URL) throws->Int32 {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks=0,failures:[String]=[],facts:[[String:Any]]=[]
        func check(_ yes:Bool,_ name:String) {checks+=1;if !yes {failures.append(name);print("FAIL: "+name)}}
        let size=CGSize(width:96,height:80),barRect=CGRect(x:28,y:56,width:40,height:14)
        let context=CGContext(data:nil,width:96,height:80,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(srgbRed:0.8,green:0.08,blue:0.12,alpha:1).cgColor);context.fill(CGRect(origin:.zero,size:size));let image=context.makeImage()!
        for masked in [false,true] {
            let host=CALayer();host.frame=CGRect(origin:.zero,size:size);host.isGeometryFlipped=true
            host.backgroundColor=NSColor(srgbRed:0.08,green:0.16,blue:0.72,alpha:1).cgColor
            let picture=CALayer();picture.frame=host.bounds;picture.contents=image;host.addSublayer(picture)
            let dock=ModeFlight.Plane(frame:host.bounds);dock.wantsLayer=true;dock.layer!.isGeometryFlipped=true
            let ink=CALayer();ink.frame=barRect;ink.backgroundColor=NSColor(white:0.85,alpha:1).cgColor;dock.layer!.addSublayer(ink);host.addSublayer(dock.layer!)
            let photo=ModeWarmPicture(mode:"normie",revision:"R0",image:image,size:size,scale:1,captureMS:0,maximumSliceMS:0)
            let base=CACurrentMediaTime()+3600,session=ModeContentSession(photo:photo,target:"organic",time:base,trace:nil)
            let mask=ModeContentDockExposure()
            if masked {mask.apply(to:dock,session:session,time:base)}
            session.animate(picture,at:base,photoOnTop:true)
            let renderer=OffscreenRenderer(size:size,host:host,scale:1)
            let first=renderer.image(renderer.render(at:base)),last=renderer.image(renderer.render(at:base+0.22))
            Offscreen.write(first,output.appendingPathComponent(masked ? "masked-start.png":"old-order-start.png"));Offscreen.write(last,output.appendingPathComponent(masked ? "masked-end.png":"old-order-end.png"))
            // The upper Dock must not paint through fully opaque PhotoN, including its actual bottom-row position.
            let rep=NSBitmapImageRep(cgImage:first)
            let bottom=rep.colorAt(x:48,y:63)!.usingColorSpace(.sRGB)!,top=rep.colorAt(x:48,y:17)!.usingColorSpace(.sRGB)!
            let error=abs(bottom.redComponent-top.redComponent)+abs(bottom.greenComponent-top.greenComponent)+abs(bottom.blueComponent-top.blueComponent)
            check(masked ? error<0.02:error>0.1,masked ? "PhotoN covers the real bottom bar without an inverted mask":"negative: old unattenuated Dock paints through PhotoN")
            var largest=0,over64=0,previous=renderer.render(at:base)
            for frame in 1...27 {
                let next=renderer.render(at:base+Double(frame)/120)
                var count=0
                for i in stride(from:0,to:min(previous.count,next.count),by:4) {
                    let delta=max(abs(Int(previous[i])-Int(next[i])),abs(Int(previous[i+1])-Int(next[i+1])),abs(Int(previous[i+2])-Int(next[i+2])))
                    if delta>64 {count+=1}
                }
                largest=max(largest,count);over64+=count;previous=next
            }
            check(largest == 0,"220 ms source-over phase adds no >64-level single-frame pixels")
            session.turn(to:"normie",at:base+0.22)
            session.animate(picture,at:base+0.22,photoOnTop:true)
            if masked {mask.apply(to:dock,session:session,time:base+0.22)}
            let covered=renderer.render(at:base+0.45)
            let native=CALayer();native.frame=host.bounds;native.contents=image;host.addSublayer(native)
            let admitted=renderer.render(at:base+0.45+1/120)
            var cut=0
            for i in stride(from:0,to:min(covered.count,admitted.count),by:4) {
                if max(abs(Int(covered[i])-Int(admitted[i])),abs(Int(covered[i+1])-Int(admitted[i+1])),abs(Int(covered[i+2])-Int(admitted[i+2])))>64 {cut+=1}
            }
            check(masked ? cut == 0:cut>100,masked ? "R0 Native admission adds zero >64-level pixels after a reversal":"negative: the old upper Dock disappears in a single native-admission frame")
            Offscreen.write(renderer.image(covered),output.appendingPathComponent(masked ? "new-before-admission.png":"old-before-admission.png"))
            Offscreen.write(renderer.image(admitted),output.appendingPathComponent(masked ? "new-after-admission.png":"old-after-admission.png"))
            facts.append(["masked":masked,"admissionPixelsOver64":cut,"sourceCoverError":error,"maximumPixelsOver64":largest,"summedPixelsOver64":over64])
            mask.clear()
        }
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures.count,"failures":failures,"facts":facts],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("fade-surfaces.json"))
        print("Fade surfaces: \(checks) checks, \(failures.count) findings")
        return failures.isEmpty ? 0:1
    }
}
#endif
