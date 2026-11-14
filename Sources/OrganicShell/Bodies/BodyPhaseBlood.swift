import Foundation

/// A texture-preserving red lift, calibrated from the unchanged failed recipe.
/// Values already at the floor take the exact legacy path, including rounding.
enum BodyPhaseBlood {
    static func meanRed(_ raster:BodyRaster,request:BodyRenderRequest,profile:BodyProfile = .current)->Double {
        let side=raster.width,center=Double(side)/2
        let radius=center*Double(profile.bodyDiameter(outer:request.outer,framing:request.framing)/request.outer)
        var red=0.0,alpha=0.0
        for y in 0..<side {for x in 0..<side {
            let dx=(Double(x)+0.5-center)/radius,dy=(Double(y)+0.5-center)/radius
            guard dx*dx+dy*dy<=1 else {continue}
            let i=(y*side+x)*4
            red+=Double(raster.pixels[i]);alpha+=Double(raster.pixels[i+3])/255
        }}
        return alpha>0 ? red/alpha:0
    }
    static func lift(body:BodyDefinition,map:BodyMap,ring:BodyMap?,clouds:BodyMap?,request:BodyRenderRequest,profile:BodyProfile)->Float {
        guard let phase=request.phase,phase.blood>0 else {return 0}
        var reference=request
        reference.phase = .init(lit:phase.lit,blood:1)
        let raster=BodyRasterizer.render(body:body,map:map,ring:ring,clouds:clouds,request:reference,profile:profile,applyBloodFloor:false)
        let mean=meanRed(raster,request:reference,profile:profile)
        // One code value covers CPU/GPU integer quantization without flattening the texture.
        let value:Float=mean>=72 ? 0:Float((73-mean)/(255-mean))
        return value
    }
    static func apply(_ lift:Float,blood:Float,to pixels:inout[UInt8]) {
        guard lift>0,blood>0 else {return}
        let gain=lift*blood
        for i in stride(from:0,to:pixels.count,by:4) {
            let alpha=Float(pixels[i+3])/255
            let red=Float(pixels[i])
            pixels[i]=UInt8(min(255,max(0,red+gain*(255*alpha-red))).rounded())
        }
    }
}
