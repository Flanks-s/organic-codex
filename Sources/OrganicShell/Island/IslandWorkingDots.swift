import AppKit
import QuartzCore

/// Static compact working ink. Event transitions are driven by the island, never by an idle CA loop.
@MainActor final class IslandWorkingDots {
    let layer=CALayer()
    private let dots=[CALayer(),CALayer(),CALayer()]
    private var wasOpaque=false
    func configure(paused:Bool,reduced:Bool,scale:CGFloat,now:Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let opaque=OrbDisplayEnvironment.shared.options.opaqueSurfaces
        if opaque != wasOpaque { layer.removeAllAnimations(); dots.forEach { $0.removeAllAnimations() }; wasOpaque=opaque }
        layer.bounds=CGRect(x:0,y:0,width:11.5,height:2.5); layer.position=CGPoint(x:7,y:7)
        for (i,dot) in dots.enumerated() {
            if dot.superlayer == nil { layer.addSublayer(dot) }
            dot.frame=CGRect(x:CGFloat(i)*4.5,y:0,width:2.5,height:2.5); dot.cornerRadius=1.25
            dot.backgroundColor=NSColor.labelColor.cgColor; dot.contentsScale=scale
            dot.opacity=opaque ? 1:0.62*0.78
        }
        layer.name="island.working"
        layer.removeAllAnimations(); dots.forEach { $0.removeAllAnimations() }
        layer.transform=CATransform3DIdentity
        CATransaction.commit()
    }
}
