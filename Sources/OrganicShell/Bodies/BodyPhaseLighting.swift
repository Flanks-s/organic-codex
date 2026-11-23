import Foundation
import simd

/// Coverage uses projected alpha, including the visible ring plane and its occlusion of the body.
/// Calibrating against the worst case (an entirely night-side ring) protects the whole silhouette.
enum BodyPhaseLighting {
    struct Surface { let normal: SIMD3<Float>; let weight: Float; var isRing=false }
    static let workspaceBytes = 4096 * MemoryLayout<Double>.stride
    static func visitSurface(body: BodyDefinition, request: BodyRenderRequest, ring: BodyMap? = nil, profile: BodyProfile = .current, visit: (Surface)->Void) {
        let side=max(1,Int((request.outer*Float(request.scale)).rounded())), n=side*profile.supersampling
        let center=Float(n)/2, radius=center*profile.bodyDiameter(outer:request.outer,framing:request.framing)/request.outer
        let b=body.basis, axis=body.axis, angle=profile.fixedTurn(body:body)*2*Float.pi, cp=cos(angle), sp=sin(angle)
        func local(_ v: SIMD3<Float>)->SIMD3<Float> {
            let x=simd_dot(v,b.east),y=simd_dot(v,b.pole),z=simd_dot(v,b.meridian)
            return SIMD3((x*cp-z*sp)/axis.x,y/axis.z,(x*sp+z*cp)/axis.y)
        }
        let ex=local(SIMD3(1,0,0)),ey=local(SIMD3(0,1,0)),ez=local(SIMD3(0,0,1)),A=simd_dot(ez,ez)
        for j in 0..<n {for i in 0..<n {
            let x=(Float(i)+0.5-center)/radius,y=(center-Float(j)-0.5)/radius,r2=x*x+y*y,r=sqrt(r2)
            let clip=min(1,max(0,center-r*radius+0.5)); if clip<=0 {continue}
            var alpha:Float=0,normal=SIMD3<Float>.zero
            if body.ellipsoid {
                let origin=x*ex+y*ey,B = -2*simd_dot(origin,ez),C=simd_dot(origin,origin)-1,q=C-B*B/(4*A)
                alpha=min(1,max(0,-q*radius/2+0.5))
                if alpha>0 {
                    let t=q<0 ? (-B-sqrt(max(0,B*B-4*A*C)))/(2*A) : -B/(2*A)
                    let s=simd_normalize(origin-t*ez),X=s.x/axis.x,Y=s.y/axis.z,Z=s.z/axis.y
                    normal=simd_normalize((X*cp+Z*sp)*b.east+Y*b.pole+(-X*sp+Z*cp)*b.meridian)
                }
            } else {
                alpha=min(1,max(0,(1-r)*radius+0.5))
                normal=r>=1 ? SIMD3(x/max(r,0.001),y/max(r,0.001),0) : SIMD3(x,y,sqrt(max(0,1-r2)))
            }
            var bodyWeight=alpha,ringWeight:Float=0
            if body.ring,let ring,abs(b.pole.z)>0.00001 {
                let z = -(b.pole.x*x+b.pole.y*y)/b.pole.z,rho=sqrt(r2+z*z)
                if rho>=profile.ringInner && rho<=profile.ringOuter {
                    let u=min(1-0.5/Float(ring.width),max(0.5/Float(ring.width),(rho-profile.ringInner)/(profile.ringOuter-profile.ringInner)))
                    let sample=ring.sample(u:u,v:0.5)
                    if sample.w>0.01 {
                        let a=sample.w*0.92*clip,front = !(r<1 && z<sqrt(max(0,1-r2)))
                        bodyWeight=alpha*(front ? 1-a:1);ringWeight=a*(front ? 1:1-alpha)
                    }
                }
            }
            if bodyWeight>0 {
                // A tangent antialias sample faces the viewer; discard only numerical negative z.
                normal=simd_normalize(SIMD3(normal.x,normal.y,max(0,normal.z)))
                visit(.init(normal:normal,weight:bodyWeight*clip))
            }
            if ringWeight>0 {visit(.init(normal:b.pole.z>0 ? b.pole:-b.pole,weight:ringWeight*clip,isRing:true))}
        }}
    }
    static func surface(body: BodyDefinition, request: BodyRenderRequest, ring: BodyMap? = nil, profile: BodyProfile = .current) -> [Surface] {
        var result:[Surface]=[]
        visitSurface(body:body,request:request,ring:ring,profile:profile){result.append($0)}
        return result
    }
    private static func direction(sample: BodyPhaseSample, degrees: Float, minimum: Float, visit: ((Surface)->Void)->Void) -> SIMD3<Float> {
        if sample.lit>=1 {return SIMD3(0,0,1)}
        if sample.lit<=0 {return SIMD3(0,0,-1)}
        let a=degrees*Float.pi/180,d=SIMD2(cos(a),sin(a)),bins=4096
        var weights=[Double](repeating:0,count:bins),total:Double=0,bodyTotal:Double=0
        visit { s in
            total+=Double(s.weight)
            if s.isRing {return}
            let threshold=atan2(-(s.normal.x*d.x+s.normal.y*d.y),max(0,s.normal.z))
            let i=min(bins-1,max(0,Int((threshold/Float.pi+0.5)*Float(bins))))
            weights[i]+=Double(s.weight);bodyTotal+=Double(s.weight)
        }
        let goal=min(bodyTotal,max(bodyTotal*Double(sample.lit),total*Double(minimum)))
        var sum:Double=0,index=0
        for i in 0..<bins {sum+=weights[i];index=i;if sum>=goal {break}}
        let theta=(Float(index+1)/Float(bins)-0.5)*Float.pi
        if index==bins-1 {return SIMD3(0,0,1)}
        return SIMD3(d.x*cos(theta),d.y*cos(theta),sin(theta))
    }
    static func direction(sample: BodyPhaseSample, degrees: Float, surface: [Surface], profile: BodyProfile = .current) -> SIMD3<Float> {
        direction(sample:sample,degrees:degrees,minimum:profile.phase.floor) { visit in for point in surface {visit(point)} }
    }
    static func direction(body: BodyDefinition, request: BodyRenderRequest, ring: BodyMap? = nil, profile: BodyProfile = .current) -> SIMD3<Float> {
        guard let phase=request.phase else{return profile.direction(degrees:request.lightDegrees)}
        return direction(sample:phase,degrees:request.lightDegrees,minimum:profile.phase.floor) { visit in visitSurface(body:body,request:request,ring:ring,profile:profile,visit:visit) }
    }
    static func coverage(_ surface: [Surface], light: SIMD3<Float>) -> Float {
        var all:Double=0,lit:Double=0
        for s in surface {all+=Double(s.weight);if simd_dot(s.normal,light)>=0 {lit+=Double(s.weight)}}
        return all>0 ? Float(lit/all) : 0
    }
    static func color(_ source: SIMD3<Float>, normal: SIMD3<Float>, light: SIMD3<Float>, position: SIMD2<Float>? = nil, sample: BodyPhaseSample, profile p: BodyProfile) -> SIMD3<Float> {
        let ndl=simd_dot(normal,light),width=p.soft+(p.haze-p.soft)*sample.haze
        let t=min(1,max(0,(ndl+width/2)/width)),day=t*t*(3-2*t)
        let limb=1-p.limb*pow(1-max(0,normal.z),2),f=p.phase
        let base=simd_max(source,SIMD3(repeating:1)),lum=simd_dot(base,SIMD3(0.2126,0.7152,0.0722))
        let amber=SIMD3(f.waitRGB[0],f.waitRGB[1],f.waitRGB[2])
        let night=base*p.night+(amber*lum-base*p.night)*sample.amber
        let diffuse=f.diffuseBase+f.diffuseGain*sqrt(max(0,ndl))
        var rgb=(night+(base*diffuse*(1+sample.emphasis)-night)*day)*limb
        let a=SIMD2(light.x,light.y),length=simd_length(a),d=length>0 ? a/length : SIMD2<Float>(1,0)
        let point=position ?? SIMD2(normal.x,normal.y),projection=simd_dot(point,d),front = -1.3+2.6*sample.blood
        let u=min(1,max(0,(projection-front+f.failEdge)/(2*f.failEdge))),sweep:Float=sample.blood>=1 ? 1:(1-u*u*(3-2*u))*(sample.blood>0 ? 1:0)
        let blood=SIMD3(f.failRGB[0],f.failRGB[1],f.failRGB[2])*lum*limb*(0.75+0.25*projection)*(1+sample.emphasis)
        rgb+=(blood-rgb)*sweep
        let ash=SIMD3<Float>(repeating:(lum*limb*f.cancelLevel+f.cancelFloor)*limb)
        if sample.ash>=1 {return ash}
        return rgb+(ash-rgb)*sample.ash
    }
}
