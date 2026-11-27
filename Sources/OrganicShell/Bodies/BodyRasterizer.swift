import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Explicit geographic longitudes. Only Earth accepts this opt-in input.
struct BodyEarthPose: Equatable, Sendable {
    var surfaceDegrees: Float
    var cloudDegrees: Float
    var isFinite: Bool { surfaceDegrees.isFinite && cloudDegrees.isFinite }
}

/// Optional, deterministic phase preparation. Hosts compute this outside the main actor.
struct BodyPhaseLightingInputs:Equatable,Sendable {
    let direction:SIMD3<Float>
    let bloodLift:Float
    static func prepare(body:BodyDefinition,map:BodyMap,ring:BodyMap?,clouds:BodyMap?,request:BodyRenderRequest,profile:BodyProfile = .current)->Self {
        .init(direction:BodyPhaseLighting.direction(body:body,request:request,ring:ring,profile:profile),
              bloodLift:BodyPhaseBlood.lift(body:body,map:map,ring:ring,clouds:clouds,request:request,profile:profile))
    }
}

struct BodyRenderRequest: Equatable, Sendable {
    var outer: Float
    var scale: Int = 2
    var framing: BodyProfile.Framing = .orb
    // Legacy turn is ignored; the opt-in Earth pose is a separate input.
    var turn: Float = 0
    var lightDegrees: Float = 180
    var unknown = false
    var unlit = false
    var phase: BodyPhaseSample? = nil
    var pose: BodyEarthPose? = nil
    var phaseLighting: BodyPhaseLightingInputs? = nil
    func resolved(for body: BodyDefinition, profile: BodyProfile) -> Self {
        var result = self
        if body.id == "earth", var pose, pose.isFinite {
            func wrap(_ value: Float) -> Float {
                let remainder = value.truncatingRemainder(dividingBy: 360), wrapped = remainder < 0 ? remainder + 360 : remainder
                return wrapped == 0 || wrapped >= 360 ? 0 : wrapped
            }
            pose.surfaceDegrees = wrap(pose.surfaceDegrees); pose.cloudDegrees = wrap(pose.cloudDegrees)
            result.pose = pose
            result.turn = -pose.surfaceDegrees / 360
        } else {
            result.pose = nil
            result.turn = profile.fixedTurn(body: body)
        }
        return result
    }
}
struct BodyRaster: Sendable {
    let width: Int
    let pixels: [UInt8]
    var byteCount: Int { pixels.count }
    func image() throws -> CGImage {try BodyMap(width:width,height:width,pixels:pixels).cgImage()}
    func writePNG(_ url: URL) throws {
        guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {throw BodyError.invalid("Cannot write PNG")}
        CGImageDestinationAddImage(destination,try image(),nil)
        guard CGImageDestinationFinalize(destination) else {throw BodyError.invalid("Cannot finish PNG")}
    }
}

/// Windowless reference renderer and explicit offline baker; never scheduled by a product host.
enum BodyRasterizer {
    static func render(body: BodyDefinition,map: BodyMap,ring: BodyMap? = nil,clouds: BodyMap? = nil,request: BodyRenderRequest,profile: BodyProfile = .current, isCancelled: ()->Bool = {false}, applyBloodFloor: Bool = true) -> BodyRaster {
        let request=request.resolved(for:body,profile:profile)
        let bloodLift=applyBloodFloor ? (request.phaseLighting?.bloodLift ?? BodyPhaseBlood.lift(body:body,map:map,ring:ring,clouds:clouds,request:request,profile:profile)):0
        let side=max(1,Int((request.outer*Float(request.scale)).rounded())),ss=profile.supersampling,n=side*ss
        let diameter=profile.bodyDiameter(outer:request.outer,framing:request.framing),ratio=diameter/request.outer,radius=Float(n)/2*ratio,center=Float(n)/2
        let basis=body.basis,L=request.phaseLighting?.direction ?? BodyPhaseLighting.direction(body:body,request:request,ring:ring,profile:profile),axis=body.axis,angle=request.turn*2 * .pi,cp=cos(angle),sp=sin(angle)
        func toLocal(_ v: SIMD3<Float>)->SIMD3<Float> {let bx=simd_dot(v,basis.east),by=simd_dot(v,basis.pole),bz=simd_dot(v,basis.meridian);return SIMD3((bx*cp-bz*sp)/axis.x,by/axis.z,(bx*sp+bz*cp)/axis.y)}
        let ex=toLocal(SIMD3(1,0,0)),ey=toLocal(SIMD3(0,1,0)),ez=toLocal(SIMD3(0,0,1)),A=simd_dot(ez,ez)
        let poleLight=simd_dot(basis.pole,L)
        func ringAt(_ rho: Float)->SIMD4<Float> {
            guard let ring,rho>=profile.ringInner,rho<=profile.ringOuter else {return .zero}
            return ring.sample(u:min(1-0.5/Float(ring.width),max(0.5/Float(ring.width),(rho-profile.ringInner)/(profile.ringOuter-profile.ringInner))),v:0.5)
        }
        var output=[UInt8](repeating:0,count:side*side*4)
        for oy in 0..<side {
            if isCancelled() {return BodyRaster(width:side,pixels:output)}
            for ox in 0..<side {
            var sum=SIMD4<Float>.zero
            for sy in 0..<ss {for sx in 0..<ss {
                let i=ox*ss+sx,j=oy*ss+sy,x=(Float(i)+0.5-center)/radius,y=(center-Float(j)-0.5)/radius,r2=x*x+y*y,r=sqrt(r2)
                let clip=min(1,max(0,center-r*radius+0.5))
                if clip<=0 {continue}
                var alpha:Float=0,u:Float=0,v:Float=0,normal=SIMD3<Float>.zero
                if body.ellipsoid {
                    let origin=x*ex+y*ey,B = -2*simd_dot(origin,ez),C=simd_dot(origin,origin)-1,q=C-B*B/(4*A)
                    alpha=min(1,max(0,-q*radius/2+0.5))
                    if alpha>0 {
                        let t=q<0 ? (-B-sqrt(max(0,B*B-4*A*C)))/(2*A) : -B/(2*A)
                        let surface=simd_normalize(origin-t*ez),X=surface.x/axis.x,Y=surface.y/axis.z,Z=surface.z/axis.y,bx=X*cp+Z*sp,bz = -X*sp+Z*cp
                        normal=simd_normalize(bx*basis.east+Y*basis.pole+bz*basis.meridian)
                        u=0.5+atan2(surface.x,surface.z)/(2 * .pi);v=0.5-asin(min(1,max(-1,surface.y)))/Float.pi
                    }
                } else {
                    alpha=min(1,max(0,(1-r)*radius+0.5))
                    if alpha>0 {
                        normal=r>=1 ? SIMD3(x/max(r,0.001),y/max(r,0.001),0):SIMD3(x,y,sqrt(max(0,1-r2)))
                        u=0.5+atan2(simd_dot(normal,basis.east),simd_dot(normal,basis.meridian))/(2 * .pi)-request.turn
                        v=0.5-asin(min(1,max(-1,simd_dot(normal,basis.pole))))/Float.pi
                    }
                }
                var rgb=SIMD3<Float>.zero
                if alpha>0 {
                    if request.phase != nil {normal=simd_normalize(SIMD3(normal.x,normal.y,max(0,normal.z)))}
                    let sample=map.sample(u:u,v:v);rgb=SIMD3(sample.x,sample.y,sample.z)
                    if let clouds {let cloudU=request.pose.map { u+($0.cloudDegrees-$0.surfaceDegrees)/360 } ?? (u-request.turn*0.08);let c=clouds.sample(u:cloudU,v:v).x/255*0.85;rgb+=(SIMD3(240,242,245)-rgb)*c}
                    let ndl=simd_dot(normal,L)
                    var shade:Float=request.unlit ? 1 : body.emits ? 0.58+0.42*pow(max(0,normal.z),0.45):profile.brightness(ndl:ndl,nz:normal.z,unknown:request.unknown)
                    var shadow:Float=1
                    if body.ring && !request.unlit && poleLight>0.02 {
                        let t = -simd_dot(normal,basis.pole)/poleLight
                        if t>0 {shadow=1-0.7*ringAt(simd_length(normal+t*L)).w;shade *= shadow}
                    }
                    if let phase=request.phase {
                        rgb=BodyPhaseLighting.color(rgb,normal:normal,light:L,position:SIMD2(x,y),sample:phase,profile:profile)*shadow
                    } else {rgb *= shade}
                    if let a=body.atmosphere,!request.unlit {let w=min(1,max(0,(r-(1-profile.rim))/profile.rim)),dl=min(1,max(0,(ndl+0.25)/0.5));rgb+=SIMD3(a[0],a[1],a[2])*w*w*(0.25+0.75*dl)*0.7*(1-(request.phase?.ash ?? 0))*(1-(request.phase?.blood ?? 0))}
                }
                var premul=SIMD4(rgb.x*alpha,rgb.y*alpha,rgb.z*alpha,alpha)
                if body.ring,abs(basis.pole.z)>0.00001 {
                    let z = -(basis.pole.x*x+basis.pole.y*y)/basis.pole.z,rho=sqrt(r2+z*z),sample=ringAt(rho)
                    if sample.w>0.01 {
                        let q=simd_dot(SIMD3(x,y,z),L)
                        // View-aligned phase light has an exact projected shadow radius; avoid subtracting squared depths.
                        let perp=request.phase != nil && L.x == 0 && L.y == 0 ? r2:rho*rho-q*q
                        let lit:Float=request.unlit ? 1 : q<0 && perp<1 ? 0.16:0.95,a=sample.w*0.92*clip
                        let front = !(r<1 && z<sqrt(max(0,1-r2)))
                        var ringRGB=SIMD3(sample.x,sample.y,sample.z)*lit
                        if let phase=request.phase {ringRGB=BodyPhaseLighting.color(SIMD3(sample.x,sample.y,sample.z),normal:basis.pole.z>0 ? basis.pole : -basis.pole,light:L,position:SIMD2(x,y),sample:phase,profile:profile)*lit}
                        let ringPixel=SIMD4(ringRGB.x*a,ringRGB.y*a,ringRGB.z*a,a)
                        premul=front ? ringPixel+premul*(1-a):premul+ringPixel*(1-alpha)
                    }
                }
                sum += premul*clip
            }}
            sum/=Float(ss*ss)
            let o=(oy*side+ox)*4
            for c in 0..<3 {output[o+c]=UInt8(min(255,max(0,sum[c])).rounded())}
            output[o+3]=UInt8(min(255,max(0,sum.w*255)).rounded())
        }}
        BodyPhaseBlood.apply(bloodLift,blood:request.phase?.blood ?? 0,to:&output)
        return BodyRaster(width:side,pixels:output)
    }
}
