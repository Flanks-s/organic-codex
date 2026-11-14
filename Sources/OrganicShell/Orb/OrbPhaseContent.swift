import AppKit

/// A contents publisher inside the existing glyph tree. Parent animation clocks are irrelevant to publication.
@MainActor final class OrbPhaseContent {
    let picture=BodyPhasePresentation()
    var layer:CALayer {picture.layer}
    private var event:BodyPhaseEvent?
    private var configuration:OrbConfiguration?
    private var lightBin=12
    private var samplingOuter:CGFloat?
    private var visible=true,active=true
    private weak var parent:CALayer?
    private weak var underlying:CALayer?
    func attach(to parent:CALayer,above underlying:CALayer) {
        self.parent=parent;self.underlying=underlying
    }
    func configure(_ c:OrbConfiguration,visible:Bool,active:Bool,bin:Int=12,samplingOuter:CGFloat?=nil) {
        configuration=c;lightBin=bin;self.samplingOuter=samplingOuter;self.visible=visible;self.active=active
        guard case .identity(let identity)=c.content,let incoming=c.bodyPhase else {picture.dispose();layer.removeFromSuperlayer();event=nil;return}
        // Preserve the original layer tree when the host has no phase input.
        if let parent,let underlying,layer.superlayer !== parent {parent.insertSublayer(layer,above:underlying)}
        let phase=BodyPhasePlaybackRegistry.shared.resolve(incoming).event
        event=phase
        layer.bounds=CGRect(x:0,y:0,width:c.drawingSize,height:c.drawingSize)
        layer.position=CGPoint(x:c.drawingSize/2,y:c.drawingSize/2)
        picture.configure(event:phase,bodyID:identity.resolvedBodyID,outer:c.bodyOuter ?? c.drawingSize,
            scale:c.backingScale>=1.5 ? 2:1,bin:bin,visible:visible,animate:active && c.isKeyWindow && !c.reduceMotion,samplingOuter:samplingOuter)
    }
    func setLightBin(_ bin:Int) {
        guard bin != lightBin,let configuration,let event,
              case .identity(let identity)=configuration.content else {return}
        lightBin=bin
        picture.configure(event:event,bodyID:identity.resolvedBodyID,outer:configuration.bodyOuter ?? configuration.drawingSize,
            scale:configuration.backingScale>=1.5 ? 2:1,bin:bin,visible:visible,
            animate:active && configuration.isKeyWindow && !configuration.reduceMotion,samplingOuter:samplingOuter)
    }
    func setActivity(visible:Bool,animate:Bool) {
        self.visible=visible;self.active=animate
        picture.setActivity(visible:visible,animate:animate)
    }
    func dispose() {picture.dispose();layer.removeFromSuperlayer()}
}
