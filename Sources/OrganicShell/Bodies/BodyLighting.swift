import Foundation
import QuartzCore
import CoreGraphics
import simd

/// A sphere's normals do not change with longitude. One canonical shade rotates toward LL independently of the albedo.
enum BodyLighting {
    static func shade(width:Int,outer:Float,framing:BodyProfile.Framing,lightDegrees:Float,unknown:Bool=false,profile:BodyProfile = .current)->BodyRaster {
        let center=Float(width)/2,radius=center*profile.bodyDiameter(outer:outer,framing:framing)/outer,L=profile.direction(degrees:lightDegrees)
        var pixels=[UInt8](repeating:0,count:width*width*4)
        for y in 0..<width {for x in 0..<width {
            let nx=(Float(x)+0.5-center)/radius,ny=(center-Float(y)-0.5)/radius,r2=nx*nx+ny*ny
            guard r2<1 else {continue}
            let normal=SIMD3(nx,ny,sqrt(1-r2)),brightness=profile.brightness(ndl:simd_dot(normal,L),nz:normal.z,unknown:unknown)
            pixels[(y*width+x)*4+3]=UInt8(min(255,max(0,(1-brightness)*255)).rounded())
        }}
        return BodyRaster(width:width,pixels:pixels)
    }
    static func applying(to image:CGImage,descriptor:BodySpriteDescriptor,degrees:Float,unknown:Bool=false,profile:BodyProfile = .current)throws->CGImage {
        let mask=shade(width:descriptor.cellPixels,outer:descriptor.outer,framing:descriptor.framing,lightDegrees:degrees,unknown:unknown,profile:profile)
        guard let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw BodyError.invalid("Cannot allocate lit frame")}
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let bytes=c.data!.assumingMemoryBound(to:UInt8.self)
        for o in stride(from:0,to:mask.pixels.count,by:4) {let gain=1-Float(mask.pixels[o+3])/255;for channel in 0..<3 {bytes[o+channel]=UInt8((Float(bytes[o+channel])*gain).rounded())}}
        guard let output=c.makeImage() else {throw BodyError.invalid("Cannot export lit frame")}
        return output
    }
}

@MainActor final class BodyLightLayer {
    let layer=CALayer()
    private let descriptor:BodySpriteDescriptor
    private let profile:BodyProfile
    private var unknown=false
    init(descriptor:BodySpriteDescriptor,profile:BodyProfile = .current)throws {
        self.descriptor=descriptor;self.profile=profile
        let side=CGFloat(descriptor.outer)
        layer.bounds=CGRect(x:0,y:0,width:side,height:side);layer.position=CGPoint(x:side/2,y:side/2);layer.contentsScale=CGFloat(descriptor.scale)
        layer.contents=try BodyLighting.shade(width:descriptor.cellPixels,outer:descriptor.outer,framing:descriptor.framing,lightDegrees:0,profile:profile).image()
    }
    func setLight(degrees:Float,unknown:Bool=false)throws {
        guard degrees.isFinite else {throw BodyError.invalid("Invalid light direction")}
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        if self.unknown != unknown {
            self.unknown=unknown
            layer.contents=try BodyLighting.shade(width:descriptor.cellPixels,outer:descriptor.outer,framing:descriptor.framing,lightDegrees:0,unknown:unknown,profile:profile).image()
        }
        layer.transform=CATransform3DMakeRotation(CGFloat(degrees)*CGFloat.pi/180,0,0,1)
    }
}
