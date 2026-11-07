import Foundation

/// Port of ColumnHeader.HeaderVariant and NativeHeaderIslandEndpoint. All coordinates are y-down.
enum HeaderIslandVariant: Equatable {
    case full, brief, split(focused: Bool), collapse, newChat
    struct Metrics: Equatable {
        var planet: CGFloat, planetTop: CGFloat, capsuleTop: CGFloat, capsuleHeight: CGFloat
        var font: CGFloat, contentTop: CGFloat, titleOpacity: Double
    }
    func metrics(band t: CGFloat) -> Metrics {
        switch self {
        case .full: .init(planet: 56, planetTop: t+8, capsuleTop: t+60, capsuleHeight: 32, font: 13, contentTop: t+112, titleOpacity: 1)
        case .brief: .init(planet: 44, planetTop: t+12, capsuleTop: t+52, capsuleHeight: 28, font: 12, contentTop: t+100, titleOpacity: 0.82)
        case .split(let focused): .init(planet: 48, planetTop: t+10, capsuleTop: t+54, capsuleHeight: 30, font: 12.5, contentTop: t+104, titleOpacity: focused ? 1 : 0.82)
        case .collapse: .init(planet: 48, planetTop: t+8, capsuleTop: t+52, capsuleHeight: 32, font: 13, contentTop: t+104, titleOpacity: 1)
        case .newChat: .init(planet: 88, planetTop: t, capsuleTop: t+84, capsuleHeight: 42, font: 17, contentTop: t+146, titleOpacity: 1)
        }
    }
    static func band(bleedTop: CGFloat) -> CGFloat { max(0, bleedTop-8) }
}

enum HeaderIslandShape: Equatable { case compact, activity, expanded, editing }
struct HeaderIslandGeometryState: Equatable {
    var shape: HeaderIslandShape = .compact
    /// Measure once per semantic title/font change; geometry itself never calls AppKit or measures text.
    var titleWidth: CGFloat = 0
    var hasMark = false
    var hasSatellites = false
    var band: CGFloat = 0
    var scale: CGFloat = 2
}
struct HeaderIslandGeometry: Equatable {
    var planet: CGRect, capsule: CGRect, title: CGRect, titleRow: CGRect
    var event: CGRect?, actions: [CGRect], satelliteRow: CGRect?, rename: CGRect?
    var radius: CGFloat, titleFont: CGFloat, titleOpacity: Double
    /// Resting transcript start includes the product's 20pt edge fade. Expansion floats over it.
    var contentTop: CGFloat
    var height: CGFloat
    static func make(variant: HeaderIslandVariant, columnWidth: CGFloat, state s: HeaderIslandGeometryState) -> Self {
        let w = max(1, columnWidth.isFinite ? columnWidth : 1), m = variant.metrics(band: s.band)
        let seed = variant == .newChat
        let shape = seed ? HeaderIslandShape.compact : s.shape
        let available = max(1, w-24)
        let compact = seed ? min(192, w) : min(max(112, ceil(s.titleWidth)+40+(s.hasMark ? 20 : 0)), max(1, min(320, w-32)))
        let strip = s.hasSatellites && variant != .collapse
        let width: CGFloat, height: CGFloat, radius: CGFloat, ty: CGFloat, th: CGFloat, font: CGFloat
        switch shape {
        case .compact: (width,height,radius,ty,th,font) = (compact,m.capsuleHeight,m.capsuleHeight/2,0,m.capsuleHeight,m.font)
        case .activity: (width,height,radius,ty,th,font) = (max(compact,min(288,available)),58,29,9,18,12)
        case .expanded: (width,height,radius,ty,th,font) = (min(336,available),strip ? 148:116,24,8,28,13)
        case .editing: (width,height,radius,ty,th,font) = (min(max(compact,240),available),36,18,0,36,m.font)
        }
        let scale = s.scale.isFinite && s.scale > 0 ? s.scale : 1
        func p(_ n: CGFloat) -> CGFloat { (n*scale).rounded()/scale }
        func rect(_ x: CGFloat,_ y: CGFloat,_ a: CGFloat,_ b: CGFloat) -> CGRect {
            let px=p(x), py=p(y); return CGRect(x:px,y:py,width:p(x+a)-px,height:p(y+b)-py)
        }
        let x=(w-width)/2, y=m.capsuleTop
        var actions: [CGRect] = []
        if shape == .expanded {
            let cell=max(1,(width-32)/2)
            actions = [rect(x+12,y+40,cell,30),rect(x+20+cell,y+40,cell,30),rect(x+12,y+74,cell,30),rect(x+20+cell,y+74,cell,30)]
        }
        let mark: CGFloat = shape == .compact && s.hasMark && !seed ? 20:0
        let chevron: CGFloat = seed ? 0:16
        let group = min(max(0,width-24),s.titleWidth+mark+chevron)
        let title = rect(x+(width-group)/2+mark,y+ty,max(0,group-mark-chevron),th)
        return Self(planet:rect((w-m.planet)/2,m.planetTop,m.planet,m.planet), capsule:rect(x,y,width,height),
                    title:title, titleRow:rect(x,y+ty,width,th), event:shape == .activity ? rect(x,y+31,width,18):nil,
                    actions:actions, satelliteRow:shape == .expanded && strip ? rect(x+12,y+112,width-24,24):nil,
                    rename:shape == .editing ? rect(x+14,y,width-28,36):nil, radius:radius,titleFont:font,
                    titleOpacity:m.titleOpacity,contentTop:p(m.contentTop),height:p(max(m.contentTop,y+height)))
    }
}

extension HeaderIslandGeometry {
    /// Between two variants' compact geometry (Claude, for the column's transitions): frames, radius, font and opacity.
    static func mix(_ a: Self, _ b: Self, _ k: CGFloat) -> Self {
        func r(_ x: CGRect, _ y: CGRect) -> CGRect {
            CGRect(x: x.minX + (y.minX - x.minX) * k, y: x.minY + (y.minY - x.minY) * k,
                   width: x.width + (y.width - x.width) * k, height: x.height + (y.height - x.height) * k)
        }
        var g = b
        g.planet = r(a.planet, b.planet); g.capsule = r(a.capsule, b.capsule)
        g.title = r(a.title, b.title); g.titleRow = r(a.titleRow, b.titleRow)
        if let x = a.event, let y = b.event { g.event = r(x, y) }
        g.radius = a.radius + (b.radius - a.radius) * k
        g.titleFont = a.titleFont + (b.titleFont - a.titleFont) * k
        g.titleOpacity = a.titleOpacity + (b.titleOpacity - a.titleOpacity) * Double(k)
        g.contentTop = a.contentTop + (b.contentTop - a.contentTop) * k
        g.height = max(a.height, b.height)
        return g
    }
}

/// Product SatelliteRow.plan: running first, latest finished retained, overflow occupies a real cell.
struct HeaderIslandSatellitePlan: Equatable {
    var running: Int, done: Int, divider: Bool, hidden: Int
    /// Product SatelliteRow.firstHidden: omitted running first, then omitted finished newest first.
    static func firstHidden(shown:Set<String>,running:[OrbSatellite],done:[OrbSatellite])->String? {
        (running+done.reversed()).first { !shown.contains($0.id) }?.id
    }
    /// Product SatelliteRow.places. Coordinates are relative to the row, before backing-pixel alignment.
    func places(width:CGFloat)->(running:[CGFloat],done:[CGFloat],divider:CGFloat,more:CGFloat) {
        let r=(0..<running).map { CGFloat($0)*24+12 },end=CGFloat(running)*24
        if hidden>0 {
            if running == 0 {
                return (r,(0..<done).map { width-24-CGFloat(done-$0)*24+12 },0,width-12)
            }
            let start=end+(divider ? 12:0)
            return (r,(0..<done).map { start+CGFloat(done-1-$0)*24+12 },end+6,start+CGFloat(done)*24+12)
        }
        let d=(0..<done).map { width-CGFloat($0)*24-12 }
        return (r,d,(end+width-CGFloat(done)*24)/2,0)
    }
    static func make(running r: Int, done d: Int, width: CGFloat) -> Self {
        let both=r>0 && d>0, used=CGFloat(r+d)*24
        if (!both || width-used >= 20) && used <= width { return .init(running:r,done:d,divider:false,hidden:0) }
        if both && used+12 <= width { return .init(running:r,done:d,divider:true,hidden:0) }
        let slots=max(0,Int(floor((both ? width-12:width)/24)))
        guard slots>=3 || !both else { return .init(running:0,done:0,divider:false,hidden:r+d) }
        let budget=max(0,slots-1)
        var done=both ? 1:min(d,budget), running=min(r,budget-done)
        done=min(d,budget-running); if !both { running=min(r,budget) }
        return .init(running:running,done:done,divider:running>0 && done>0,hidden:r+d-running-done)
    }
}
