import AppKit
import QuartzCore

/// Deliberately retain the drawing below the hidden NSViews; snapshot(bool) cannot test this.
@MainActor enum HeaderPickupPaintVerification {
    static func run(to output:URL,check:(Bool,String)->Void) {
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var records=[[String:Any]]()
        for scale:CGFloat in [1,2] {for variant:HeaderIslandVariant in [.full,.brief] {
            let header=HeaderIsland(),root=IslandPlane(frame:CGRect(x:0,y:0,width:400,height:300))
            root.addSubview(header)
            var c=HeaderIslandConfiguration(id:"pickup",title:"Source satellites",variant:variant,columnWidth:400,band:44,ambient:false,scale:scale)
            c.signals.satellites=[.init(id:"a",face:"a",pace:0.5),.init(id:"b",face:"b",pace:0.5),.init(id:"c",face:"c",pace:0.5,done:true)]
            header.configure(c)
            let size=header.bounds.size,w=Int(size.width*scale),h=Int(size.height*scale),planet=header.draggableOrbRect
            func paint()->CGImage {
                let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x:scale,y:scale)
                header.orb.renderOffscreenDecorations(in:context,planet:planet)
                return context.makeImage()!
            }
            func outsideInk(_ image:CGImage)->Int {
                let data=CFDataGetBytePtr(image.dataProvider!.data!)!
                var count=0
                for y in 0..<h {for x in 0..<w {
                    let dx=(CGFloat(x)+0.5)/scale-planet.midX,dy=(CGFloat(h-y)-0.5)/scale-planet.midY
                    if hypot(dx,dy)>planet.width/2+2,data[(y*w+x)*4+3]>16 {count+=1}
                }}
                return count
            }
            let before=paint(),parent=header.orb.glassView.superview,rect=header.draggableOrbRect
            let tag="\(variant == .full ? "full":"brief")@\(Int(scale))x"
            check(outsideInk(before)>5,"pickup probe contains actual source satellites \(tag)")
            header.setOrbCarried(true)
            let carried=paint(),count=outsideInk(carried)
            check(count==0,"pickup withdraws owned satellite paint on the first frame \(tag): \(count) pixels")
            check(header.orb.glassView.superview === parent && header.draggableOrbRect==rect,"pickup preserves glass parent and geometry \(tag)")
            header.setOrbCarried(false)
            let returned=paint()
            check(before.dataProvider?.data == returned.dataProvider?.data,"pickup handback preserves exact source drawing \(tag)")
            for (name,image) in [("before",before),("held",carried),("returned",returned)] {Offscreen.write(image,output.appendingPathComponent("\(tag)-\(name).png"))}
            records.append(["tag":tag,"beforePixels":outsideInk(before),"heldPixels":count,"returnedPixels":outsideInk(returned)])
            header.dispose();withExtendedLifetime(root){}
        }}
        try? JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("owned-paint.json"))
    }
}
