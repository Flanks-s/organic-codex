import AppKit
import QuartzCore

/// The resident split material samples the same window backdrop throughout a switch. Neither the
/// opaque body bitmap nor Organic's canvas may enter the independently moving sidebar's rectangle.
@MainActor final class ModeContentSidebarCutout {
    private let mask=CAShapeLayer()
    private weak var target:CALayer?
    private var width:CGFloat=0
    private var offset:((Double)->CGFloat)?
    private var installedBounds=CGRect.null,installedRevision:UInt64?
    func fullyExposes(_ rect:CGRect,at time:Double)->Bool {
        guard target != nil,let offset else {return true}
        return rect.minX>=max(0,width+offset(time))-0.001
    }
    func apply(to root:NSView,width:CGFloat,time:Double,revision:UInt64?=nil,offset:@escaping (Double)->CGFloat) {
        guard let layer=root.layer else {return}
        if let revision,target === layer,installedRevision == revision,installedBounds == root.bounds,self.width == width,layer.mask === mask {return}
        installedRevision=revision;installedBounds=root.bounds
        target=layer;self.width=width;self.offset=offset;mask.frame=root.bounds;mask.fillColor=CGColor(gray:1,alpha:1)
        func path(_ t:Double)->CGPath {
            let edge=min(root.bounds.width,max(0,width+offset(t)))
            return CGPath(rect:CGRect(x:edge,y:0,width:max(0,root.bounds.width-edge),height:root.bounds.height),transform:nil)
        }
        // Sidebar's longest authored leg is 0.14 + 0.46 s. Sample its existing clock; never restart it.
        let duration=0.60,count=144
        let animation=CAKeyframeAnimation(keyPath:"path")
        animation.values=(0...count).map {path(time+Double($0)/240)}
        animation.duration=duration;animation.beginTime=mask.convertTime(time,from:nil)
        animation.calculationMode = .linear;animation.fillMode = .both;animation.isRemovedOnCompletion=false
        mask.path=path(time+duration);mask.add(animation,forKey:"mode.content.sidebar-cutout")
        layer.mask=mask
    }
    func clear() {if target?.mask === mask {target?.mask=nil};mask.removeAllAnimations();target=nil;offset=nil;installedRevision=nil;installedBounds = .null}
}
