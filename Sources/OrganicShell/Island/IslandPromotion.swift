import Foundation

/// Product ColumnHeader.riseFromHero + NativeColumnHeaderSurface hero scale. Values are in header-local y-down points.
struct HeaderIslandPromotion {
    static let riseResponse=0.38, riseDamping=0.86, nameResponse=0.24, nameDamping=0.72
    static let titleDelay=0.12, titleInDelay=0.05, titleInDuration=0.10, titleOutDuration=0.05
    let seed:HeaderIslandGeometry
    let launchName:HeaderIslandGeometry
    let full:HeaderIslandGeometry
    let seedCenterY:CGFloat, columnWidth:CGFloat, scale:CGFloat
    let reduceMotion:Bool
    var titleDelay:Double { reduceMotion ? 0:Self.titleDelay }
    struct Sample { var geometry:HeaderIslandGeometry; var fontScale:CGFloat; var revealTitle:Bool }
    var initial:HeaderIslandGeometry { sample(elapsed:0).geometry }
    func sample(elapsed:Double) -> Sample { sample(elapsed:elapsed,pixelAligned:true) }
    /// M10-D: keep the original endpoint API/pixel grid, but do not round the moving spring's edges every frame.
    /// That rounding held the name still, then moved it by a whole pixel at ~0.5s (both exposure on and off).
    func motionSample(elapsed:Double) -> Sample { sample(elapsed:elapsed,pixelAligned:elapsed<=0 || elapsed>=1.2) }
    private func sample(elapsed:Double,pixelAligned:Bool) -> Sample {
        if reduceMotion { return .init(geometry:full,fontScale:1,revealTitle:true) }
        let rise=Self.spring(max(0,elapsed),response:Self.riseResponse,damping:Self.riseDamping)
        let name=elapsed < Self.titleDelay ? 0:Self.spring(elapsed-Self.titleDelay,response:Self.nameResponse,damping:Self.nameDamping)
        var g=HeaderIslandGeometry.mix(launchName,full,CGFloat(name))
        let k=CGFloat(88.0/56.0+(1-88.0/56.0)*rise)
        let offset=(seedCenterY-CGFloat(88.0/56.0)*launchName.planet.midY)*CGFloat(1-rise)
        func rect(_ r:CGRect)->CGRect {
            let s=max(1,scale)
            func pixel(_ x:CGFloat)->CGFloat {pixelAligned ? (x*s).rounded()/s:x}
            let x=pixel(columnWidth/2+(r.minX-columnWidth/2)*k)
            let y=pixel(r.minY*k+offset)
            let maxX=pixel(columnWidth/2+(r.maxX-columnWidth/2)*k)
            let maxY=pixel(r.maxY*k+offset)
            return CGRect(x:x,y:y,width:maxX-x,height:maxY-y)
        }
        g.planet=rect(g.planet); g.capsule=rect(g.capsule); g.title=rect(g.title); g.titleRow=rect(g.titleRow)
        g.radius *= k; g.height=max(g.height,g.capsule.maxY); g.contentTop=g.contentTop*k+offset
        return .init(geometry:g,fontScale:k,revealTitle:elapsed>=Self.titleDelay)
    }
    private static func spring(_ time:Double,response:Double,damping:Double)->Double {
        if time >= 1.2 { return 1 }
        let omega=2*Double.pi/response, wd=omega*sqrt(1-damping*damping)
        return 1-exp(-damping*omega*time)*(cos(wd*time)+damping/sqrt(1-damping*damping)*sin(wd*time))
    }
}
