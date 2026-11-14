import AppKit
import QuartzCore

/// Process-local diagnostic selection. Geometry and the default twelve tail pieces are unchanged.
enum TideAnimationMode:String {
    case board, offglass, lowrate, `static`
    static let selected=TideAnimationMode(rawValue:ProcessInfo.processInfo.environment["M11_TIDE_ANIM"] ?? "") ?? .static
}

@MainActor private final class TideTrialInkHost:NSView {
    override var isFlipped:Bool {true}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

/// Mock-only ablation of the ordinary working orb used by the old still driver. Never changes live Core ink.
@MainActor final class DockTideAnimationTrial {
    let owner:String
    let mode=TideAnimationMode.selected
    private let orb:OrbComponent
    private var held:[(CALayer,String,CAAnimation)]=[]
    private var moved:[(NSView,NSView,Int)]=[]
    private var host:NSView?
    init(owner:String,orb:OrbComponent,parent:NSView,container:NSView) {
        self.owner=owner;self.orb=orb
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        switch mode {
        case .board:break
        case .static:
            // Measurement also works after an independent ambient-policy rollback. Preserve satellite orbits.
            var seen=Set<ObjectIdentifier>()
            func visit(_ l:CALayer) {
                guard seen.insert(ObjectIdentifier(l)).inserted else{return}
                if let a=l.animation(forKey:"wobble") {held.append((l,"wobble",a));l.removeAnimation(forKey:"wobble")}
                if let mask=l.mask {visit(mask)}
                for child in l.sublayers ?? [] {visit(child)}
            }
            func visitView(_ view:NSView) {
                if let layer=view.layer {visit(layer)}
                for child in view.subviews {visitView(child)}
            }
            for view in [orb.backView,orb.frontView,orb.glassView.contentView].compactMap({$0}) {visitView(view)}
        case .lowrate:
            var seen=Set<ObjectIdentifier>()
            func visit(_ l:CALayer) {
                guard seen.insert(ObjectIdentifier(l)).inserted else{return}
                for key in l.animationKeys() ?? [] {
                    guard let a=l.animation(forKey:key),!a.repeatCount.isFinite || a.repeatCount>1_000_000 else{continue}
                    held.append((l,key,a));let next=a.copy() as! CAAnimation
                    next.preferredFrameRateRange=CAFrameRateRange(minimum:15,maximum:15,preferred:15)
                    l.add(next,forKey:key)
                }
                if let mask=l.mask {visit(mask)}
                for child in l.sublayers ?? [] {visit(child)}
            }
            func visitView(_ view:NSView) {
                if let layer=view.layer {visit(layer)}
                for child in view.subviews {visitView(child)}
            }
            for view in [orb.backView,orb.frontView,orb.glassView.contentView].compactMap({$0}) {visitView(view)}
        case .offglass:
            guard let content=orb.glassView.contentView else{return}
            let ink=TideTrialInkHost();ink.wantsLayer=true
            ink.frame=orb.glassView.convert(orb.glassView.bounds,to:parent)
            parent.addSubview(ink,positioned:.above,relativeTo:container);host=ink
            func hasRunningLoop(_ layer:CALayer)->Bool {
                let now=CACurrentMediaTime(),moving=layer.convertTime(now+1,from:nil) != layer.convertTime(now,from:nil)
                if moving,(layer.animationKeys() ?? []).contains(where:{key in
                    guard let a=layer.animation(forKey:key) else{return false}
                    return a.speed != 0 && (!a.repeatCount.isFinite || a.repeatCount>1_000_000)
                }) {return true}
                if let mask=layer.mask,hasRunningLoop(mask) {return true}
                return (layer.sublayers ?? []).contains(where:hasRunningLoop)
            }
            // Move only the public content child containing the measured loop, never native backing or Peek ink.
            for (index,view) in content.subviews.enumerated() where view.layer.map(hasRunningLoop) == true {
                moved.append((view,content,index));ink.addSubview(view)
            }
        }
    }
    func finish(ambient:Bool) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        for (layer,key,animation) in held {layer.add(animation,forKey:key)};held=[]
        for (view,parent,index) in moved.sorted(by:{$0.2<$1.2}) {
            if index<parent.subviews.count {parent.addSubview(view,positioned:.below,relativeTo:parent.subviews[index])}
            else {parent.addSubview(view)}
        }
        moved=[];host?.removeFromSuperview();host=nil
        // Finishing a measurement must not change the product animation policy.
    }
    var probe:[String:Any] {["owner":owner,"mode":mode.rawValue,"movedContentViews":moved.count,"cappedAnimations":held.count,"fps":mode == .lowrate ? 15:60]}
}
