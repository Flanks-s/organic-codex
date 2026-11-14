import AppKit
import QuartzCore

/// A badge-free Tide face, authored independently from the normal orb so its badge can crossfade intact.
@MainActor final class DockTideFace {
    let orb:OrbComponent
    private weak var body:NSView?
    private var filters:[NSObject?]=[nil,nil,nil]
    private var lastRect:CGRect?,lastOpacity = -1.0
    private var configuration:OrbConfiguration?
    init(id:String,glass:NSGlassEffectView,configuration:OrbConfiguration) {
        let existing=Set((glass.contentView?.subviews ?? []).map(ObjectIdentifier.init)),tint=glass.tintColor
        orb=OrbComponent(id:"tide.face."+id,glassView:glass)
        body=glass.contentView?.subviews.first{!existing.contains(ObjectIdentifier($0))}
        var c=configuration;c.badge=nil;c.ambient=false;c.drawingSize=48;c.bodyOuter=36;c.bodyVisible=false
        orb.configure(c);self.configuration=c;glass.tintColor=tint;orb.setOpacity(0)
        for (i,v) in [orb.backView,orb.frontView,body].enumerated() {
            if let layer=v?.layer {DockTidePresentation.ink(layer,opacity:0,blur:6,scale:0.92,filter:&filters[i],prepare:true);v?.isHidden = !TideCompositePolicy.legacy}
        }
    }
    /// Refresh semantic waterline and identity only when Core changes; never from the frame loop.
    func configure(_ next:OrbConfiguration) {
        var next=next;next.badge=nil;next.ambient=false;next.drawingSize=48;next.bodyOuter=36;next.bodyVisible=(lastOpacity>0.001)
        guard configuration != next else{return}
        configuration=next
        let tint=orb.glassView.tintColor
        orb.configure(next)
        if orb.glassView.tintColor != tint {orb.glassView.tintColor=tint}
    }
    func render(rect:CGRect,opacity:Double) {
        guard lastRect != rect || lastOpacity != opacity else{return}
        lastRect=rect;lastOpacity=opacity
        if var c=configuration,c.bodyVisible != (opacity>0.001) { c.bodyVisible=opacity>0.001; configuration=c; orb.configure(c) }
        let d=min(rect.width,rect.height),size=d*(0.92+0.08*opacity)
        orb.setFrame(rect,contentFrame:CGRect(x:(d-size)/2,y:(d-size)/2,width:size,height:size))
        orb.setOpacity(Float(opacity))
        for (i,v) in [orb.backView,orb.frontView,body].enumerated() {
            if let layer=v?.layer {
                v?.isHidden = !TideCompositePolicy.legacy && opacity<=0.001
                DockTidePresentation.ink(layer,opacity:opacity>0.001 ? 1:0,blur:(1-opacity)*6,scale:1,filter:&filters[i])
            }
        }
    }
    /// Auto capsules draw a small vector glyph. Do not lay out an invisible planet on every display frame.
    func hide() {
        guard lastOpacity != 0 || lastRect != nil else{return}
        park();lastOpacity=0;lastRect=nil
    }
    func park() {
        if var c=configuration { c.bodyVisible=false; configuration=c; orb.configure(c) }
        orb.setOpacity(0)
        for (i,v) in [orb.backView,orb.frontView,body].enumerated() {
            v?.isHidden = !TideCompositePolicy.legacy
            if let layer=v?.layer {DockTidePresentation.ink(layer,opacity:0,blur:0,scale:1,filter:&filters[i])}
        }
        lastOpacity = -1;lastRect=nil
    }
    func dispose() {orb.dispose()}
    var probe:[String:Any] {
        var p:[String:Any] = ["opacity":max(0,lastOpacity),"badge":false,"running":configuration?.running ?? false,"context":configuration?.context ?? 0,"bodyFilter":!(body?.layer?.filters ?? []).isEmpty,"bodyBlur":(body?.layer?.filters ?? []).isEmpty ? 0:(filters[2]?.value(forKey:"inputRadius") as? Double ?? 0)]
#if M10_DOCK_SELFTEST
        p["badge"] = orb.verificationConfiguration?.badge != nil
#endif
        return p
    }
}
