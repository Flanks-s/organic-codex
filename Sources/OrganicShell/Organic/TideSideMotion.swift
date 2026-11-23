import Foundation
import CoreGraphics

/// TideSide B, V46. Geometry runs only while these finite board channels are unsettled.
struct TideSideMotion {
    var center:TideSpring,width=TideSpring(14),height=TideSpring(14),bottom:TideSpring,diameter=TideSpring(32),radius=TideSpring(7)
    var anchor:CGRect,composerTop:Double
    private(set) var shown=false,returning=false
    private var target:CGRect?
    private var residual=0.0
    private var laneTarget:CGRect?,laneSliding=false
    private var alternateLane=false,laneExit=0
    var goal:CGRect? {target}
    init(anchor:CGRect,composerTop:Double) {
        self.anchor=anchor;self.composerTop=composerTop
        center=TideSpring(anchor.midX);bottom=TideSpring(anchor.midY+6)
    }
    var orb:CGRect {CGRect(x:anchor.midX-diameter.x/2,y:anchor.midY-diameter.x/2,width:diameter.x,height:diameter.x)}
    var card:CGRect {CGRect(x:center.x-width.x/2,y:bottom.x-height.x,width:max(0,width.x),height:max(0,height.x))}
    var busy:Bool {laneTarget != nil || laneExit != 0 || center.busy || width.busy || height.busy || bottom.busy || diameter.busy || radius.busy}
    /// Follow the existing Dock lift without starting a second spring or changing its velocity.
    mutating func translate(anchorX:Double,y:Double) {
        anchor.origin.x+=anchorX
        guard y != 0 else{return}
        anchor.origin.y+=y;composerTop+=y
        bottom.value.x+=y;bottom.value.target+=y
        if let q=bottom.queued {bottom.queued=(q.0+y,q.1,q.2,q.3)}
        if let rect=target {target=rect.offsetBy(dx:0,dy:y)}
    }
    mutating func aim(_ rect:CGRect?,staged:Bool=false) {
        guard target != rect else{return};target=rect
        if let rect {
            let fresh = !shown || returning;shown=true;returning=false;laneExit=0
            alternateLane = alternateLane || staged
            diameter.aim(36,(0.40,0.88))
            if staged,abs(center.x-rect.midX)>8 || bottom.x>rect.maxY+8 {
                laneTarget=rect;laneSliding=false
                width.aim(14,(0.36,0.92));height.aim(14,(0.40,0.90));radius.aim(7,(0.40,0.90))
                center.aim(center.x,(0.44,0.84));bottom.aim(rect.maxY,(0.44,0.84),after:fresh ? 0.04:0)
                return
            }
            laneTarget=nil
            bottom.aim(rect.maxY,(0.44,0.84),after:fresh ? 0.04:0)
            height.aim(rect.height,rect.height>=height.value.target ? (0.46,0.86):(0.40,0.90),after:fresh ? 0.07:0)
            radius.aim(rect.height==88 ? 22:rect.height/2,(0.46,0.86),after:fresh ? 0.07:0)
            width.aim(rect.width,rect.width>=width.value.target ? (0.42,0.80):(0.36,0.92),after:fresh ? 0.10:0)
            center.aim(rect.midX,(0.44,0.84),after:fresh ? 0.08:0)
        } else if shown {
            laneTarget=nil;returning=true
            width.aim(14,(0.36,0.92),after:0.05);height.aim(14,(0.40,0.90),after:0.05)
            radius.aim(7,(0.40,0.90),after:0.05)
            if alternateLane {
                laneExit=1
                let travel=max(anchor.midX,card.minX+8)
                center.aim(travel,(0.44,0.84),after:0.05);bottom.aim(bottom.x,(0.40,0.90))
            } else {
                center.aim(anchor.midX,(0.44,0.84),after:0.05)
                bottom.aim(anchor.midY+6,(0.40,0.90),after:0.11)
            }
            diameter.aim(32,(0.40,0.88),after:0.20)
        }
    }
    /// Only this notification yields to a blocked contour. Unblocked spring channels keep their velocity.
    mutating func accept(_ rect:CGRect) {
        func admitted(_ channel:inout TideSpring,_ value:Double) {
            if abs(channel.x-value)>0.000_001 {channel.value.x=value;channel.value.v=0}
        }
        admitted(&center,rect.midX);admitted(&width,rect.width);admitted(&height,rect.height);admitted(&bottom,rect.maxY)
    }
    mutating func step(_ dt:Double,reduced:Bool) {
        residual+=max(0,dt);let h=1.0/240
        let count=Int(floor((residual+1e-8)/h));residual-=Double(count)*h
        for _ in 0..<count {
            if laneExit==1,width.x<18,height.x<18 {laneExit=2;center.aim(anchor.midX,(0.44,0.84))}
            if laneExit==2,abs(center.x-anchor.midX)<4 {laneExit=0;bottom.aim(anchor.midY+6,(0.40,0.90))}
            if let lane=laneTarget {
                let side=lane.midX>=anchor.midX ? 1.0:-1.0
                let root=max(lane.minX+16,min(lane.maxX-16,anchor.midX+side*8))
                let travel=root-side*8
                if !laneSliding,bottom.x<=lane.maxY+8 {laneSliding=true;center.aim(travel,(0.44,0.84))}
                if laneSliding,abs(center.x-travel)<4 {
                    laneTarget=nil;center.aim(lane.midX,(0.44,0.84));width.aim(lane.width,(0.42,0.80));height.aim(lane.height,(0.46,0.86));radius.aim(lane.height==88 ? 22:lane.height/2,(0.46,0.86))
                }
            }
            center.step(h);width.step(h);height.step(h);bottom.step(h);diameter.step(h);radius.step(h)
        }
        if reduced {
            if laneExit != 0 {laneExit=0;center.aim(anchor.midX,(0.44,0.84));bottom.aim(anchor.midY+6,(0.40,0.90))}
            if let lane=laneTarget {laneTarget=nil;center.aim(lane.midX,(0.44,0.84));width.aim(lane.width,(0.42,0.80));height.aim(lane.height,(0.46,0.86));radius.aim(lane.height==88 ? 22:lane.height/2,(0.46,0.86))}
            center.snap();width.snap();height.snap();bottom.snap();diameter.snap();radius.snap()
        }
        if returning,!busy {shown=false}
    }
}

/// Pure packing for one margin. Urgent candidates receive width first; physical order stays by orb position.
enum TideSidePacking {
    struct Candidate {let id:String,anchor:CGRect,preferred:Double;let action:Bool,one:Bool,rank:Int}
    /// V46 geo(): Focused's 560 pt reading column; Split and parked use the outer 320 pt margin.
    static func region(width:Double,focused:Bool,split:Bool,right:Bool)->ClosedRange<Double>? {
        let edge=focused && !split ? width/2-292:min(350,width/2-12)
        let low=right ? width-edge:30,high=right ? width-30:edge
        guard high-low>=150 else{return nil}
        return low...high
    }
    /// Finite lane alternatives are tested as complete body/stem/orb contours, never bounding-box unions.
    static func fit(_ proposed:[String:CGRect],order:[String],obstacles:[CGRect],staggered:Bool=false,contour:(String,CGRect)->[CGRect])->[String:CGRect]? {
        var fitted:[String:CGRect]=[:],parts:[CGRect]=[]
        func search(_ index:Int)->Bool {
            guard index<order.count else{return true}
            let id=order[index];guard let base=proposed[id] else{return false}
            let lifts=[0.0,12,24,48,72,100,140,188,240]
            for lift in lifts {
                let rect=base.offsetBy(dx:0,dy:-lift),shape=contour(id,rect)
                guard !shape.isEmpty,shape.allSatisfy({a in (obstacles+parts).allSatisfy {TideContour.gap(a,$0)>=11.99999}}) else{continue}
                let count=parts.count;parts+=shape;fitted[id]=rect
                if search(index+1) {return true}
                parts.removeLast(parts.count-count);fitted[id]=nil
            }
            return false
        }
        return search(0) ? fitted:nil
    }
    static func solve(_ candidates:[Candidate],region:ClosedRange<Double>,bottom:Double,right:Bool)->[String:CGRect] {
        let ranked=candidates.sorted{$0.rank == $1.rank ? $0.id<$1.id:$0.rank>$1.rank}
        var chosen:[Candidate]=[]
        for c in ranked where Double((chosen.count+1)*150+chosen.count*12)<=region.upperBound-region.lowerBound {chosen.append(c)}
        var extra=region.upperBound-region.lowerBound-Double(chosen.count*150+max(0,chosen.count-1)*12)
        var widths:[String:Double]=[:]
        for c in chosen {let add=max(0,min(extra,c.action ? (c.one ? 260:330)-150:c.preferred-150));widths[c.id]=150+add;extra-=add}
        let order=chosen.sorted{$0.anchor.midX<$1.anchor.midX};var left:[String:Double]=[:]
        for c in order {let w=widths[c.id]!;left[c.id]=max(region.lowerBound,min(region.upperBound-w,right ? c.anchor.midX-26:c.anchor.midX+26-w))}
        for i in order.indices.dropFirst() {let a=order[i-1],b=order[i];left[b.id]=max(left[b.id]!,left[a.id]!+widths[a.id]!+12)}
        for i in order.indices.reversed() {let c=order[i];let edge=i+1<order.count ? left[order[i+1].id]!-12:region.upperBound;left[c.id]=min(left[c.id]!,edge-widths[c.id]!)}
        return Dictionary(uniqueKeysWithValues:order.map{c in
            let w=widths[c.id]!,h=c.action ? (w>=(c.one ? 260:300) ? 48.0:88.0):40.0
            return (c.id,CGRect(x:left[c.id]!,y:bottom-h,width:w,height:h))
        })
    }
}
