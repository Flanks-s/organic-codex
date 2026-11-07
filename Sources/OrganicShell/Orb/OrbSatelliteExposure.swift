import AppKit
import QuartzCore

/// Stretch the satellite's solid and accumulate its face independently. The face remains in the original
/// shadow/compositing group; its position compensates the solid's changed bounds.
/// All tables are submitted once, in the satellite's existing clock (including finite real-time row springs).
@MainActor enum OrbSatelliteExposure {
    static func install(solid:CALayer,ink:CAReplicatorLayer,diameter:CGFloat,duration:Double,
                        timing:CAAnimation,profile:DisplayProfile,speed:Double=1,loop:Bool=false,displayScale:CGFloat=1,
                        pose:(Double)->(CGPoint,CGFloat)) {
        solid.removeAnimation(forKey:"m10F.solid");ink.removeAnimation(forKey:"m10F.ink")
        let intervals=max(2,Int(ceil(duration/(profile.frameInterval*max(0.001,speed))))),base=CGRect(x:0,y:0,width:diameter,height:diameter)
        var boxes:[Any]=[],positions:[Any]=[],radii:[Any]=[],counts:[Any]=[],colors:[Any]=[],transforms:[Any]=[],inkPositions:[Any]=[]
        var active=false
        let times=(0...intervals).map{min(duration,Double($0)*profile.frameInterval*max(0.001,speed))}
        for i in 0...intervals {
            let t=times[i],a=pose(t),b=pose(loop ? t-profile.frameInterval*speed:max(0,t-profile.frameInterval*speed))
            let now=M10FExposure.rect(center:a.0,size:CGSize(width:diameter*a.1,height:diameter*a.1))
            let old=M10FExposure.rect(center:b.0,size:CGSize(width:diameter*b.1,height:diameter*b.1))
            let stretched=M10FExposure.stretch(now:now,earlier:old,profile:profile)
            let size=CGSize(width:stretched.width/a.1,height:stretched.height/a.1)
            boxes.append(NSValue(rect:CGRect(origin:.zero,size:size)))
            positions.append(NSValue(point:CGPoint(x:(stretched.midX-now.midX)/a.1,y:(stretched.midY-now.midY)/a.1)))
            inkPositions.append(NSValue(point:CGPoint(x:(size.width-diameter)/2-(stretched.midX-now.midX)/a.1,y:(size.height-diameter)/2-(stretched.midY-now.midY)/a.1)))
            radii.append(min(size.width,size.height)/2)
            let relative=CGRect(x:(old.minX-now.minX)/a.1,y:(old.minY-now.minY)/a.1,width:old.width/a.1,height:old.height/a.1)
            var metric=profile;metric.mmPerPoint *= Double(a.1)
            var s=M10FExposure.settings(now:base,earlier:relative);s.spacing /= max(1,a.1*displayScale)
            let e=M10FExposure.sample(now:base,earlier:relative,profile:metric,settings:s)
            active=active || e.count>1
            counts.append(e.count);colors.append(e.instanceColor);transforms.append(NSValue(caTransform3D:M10FExposure.chord(now:base,earlier:relative,sample:e)))
        }
        guard active else { return } // The ordinary slow orbit installs nothing at all.
        func group(_ animations:[CAAnimation])->CAAnimationGroup {
            let g=CAAnimationGroup();g.animations=animations;g.duration=duration;g.beginTime=timing.beginTime
            g.speed=timing.speed;g.fillMode=timing.fillMode
            if loop { g.repeatCount = .infinity;g.isRemovedOnCompletion=false }
            return g
        }
        solid.add(group([M10FExposure.keys("bounds",boxes,duration:duration,times:times),M10FExposure.keys("position",positions,duration:duration,times:times),M10FExposure.keys("cornerRadius",radii,duration:duration,times:times)]),forKey:"m10F.solid")
        let n=M10FExposure.keys("instanceCount",counts,duration:duration,times:times);n.calculationMode = .discrete
        ink.add(group([n,M10FExposure.keys("instanceColor",colors,duration:duration,times:times),M10FExposure.keys("instanceTransform",transforms,duration:duration,times:times),M10FExposure.keys("position",inkPositions,duration:duration,times:times)]),forKey:"m10F.ink")
    }
}
