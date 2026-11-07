import AppKit

/// Separate native glass experiment; these shapes never replace the production Dock.
@MainActor final class SpotlightLabStage:DebugCanvas {
    var out=false{didSet{guard out != oldValue else{return};start=progress;elapsed=0}}
    private(set) var progress=0.0
    private var start=0.0,elapsed=0.0
    func advance(_ dt:Double){guard dt.isFinite,dt>=0 else{return};elapsed+=dt;let target=out ? 1.0:0.0;let spring=LabSpring(response:0.38,damping:0.74);progress=elapsed>=spring.settlingTime ? target:start+(target-start)*spring.value(elapsed);needsLayout=true}
    private(set) var containers:[NSGlassEffectContainerView]=[]
    private var bars:[NSGlassEffectView]=[],orbs:[[NSGlassEffectView]]=[]
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityLabel("Spotlight glass experiments")}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    func installGlass(){guard containers.isEmpty else{return};for _ in 0..<3{
        let container=NSGlassEffectContainerView();container.spacing=8;container.contentView=NativeFlippedView();addSubview(container);containers.append(container)
        let bar=NSGlassEffectView();bar.cornerRadius=22;container.contentView?.addSubview(bar);bars.append(bar)
        let row=(0..<3).map{_ in let orb=NSGlassEffectView();orb.cornerRadius=22;container.contentView?.addSubview(orb);return orb};orbs.append(row)
    };needsLayout=true}
    func releaseGlass(){containers.forEach{$0.removeFromSuperview()};containers=[];bars=[];orbs=[]}
    override func layout(){super.layout();let barWidth=min(600,max(300,bounds.width-120));for (i,container) in containers.enumerated(){
        container.frame=CGRect(x:25,y:95+CGFloat(i)*140,width:max(1,bounds.width-50),height:60);container.contentView?.frame=container.bounds
        let width=barWidth-160*progress
        CATransaction.begin();CATransaction.setDisableActions(true)
        bars[i].frame=CGRect(x:0,y:8,width:width,height:44)
        for (j,orb) in orbs[i].enumerated(){let tucked=barWidth-48;let destination=barWidth-160+10+CGFloat(j)*54;let x=tucked+(destination-tucked)*progress;orb.frame=CGRect(x:x,y:8,width:44,height:44);orb.alphaValue = i == 1 ? 1:min(1,max(0,progress));orb.isHidden = i == 2 && progress<0.001}
        CATransaction.commit()
    }}
    override func draw(_ dirtyRect:NSRect){
        if NativeDisplayOptions.shared.state.reducesEffects{DebugPaint.background.setFill();bounds.fill()}else{NSGradient(colors:[NSColor.systemIndigo.withAlphaComponent(0.65),NSColor.systemTeal.withAlphaComponent(0.65),NSColor.systemOrange.withAlphaComponent(0.6)])?.draw(in:bounds,angle:25)}
        NSColor.white.withAlphaComponent(0.15).setStroke();for x in stride(from:CGFloat(0),to:bounds.width+bounds.height,by:18){let line=NSBezierPath();line.move(to:CGPoint(x:x,y:0));line.line(to:CGPoint(x:x-bounds.height,y:bounds.height));line.lineWidth=2;line.stroke()}
        DebugPaint.text("Spotlight · isolated NSGlassEffectContainerView experiments",CGRect(x:25,y:22,width:bounds.width-50,height:25),size:14)
        for (i,title) in ["A · reveal beside the bar","B · slide from under the bar","C · single bar while tucked"].enumerated(){DebugPaint.text(title,CGRect(x:25,y:72+CGFloat(i)*140,width:bounds.width-50,height:20),size:11)}
        if window == nil {
            // Offscreen glass has no compositor backdrop. Keep the experiment's geometry legible without pretending refraction.
            let barWidth=min(600,max(300,bounds.width-120)),width=barWidth-160*progress
            for i in 0..<3{NativeDisplayOptions.plate(alpha:0.18).setFill();NSBezierPath(roundedRect:CGRect(x:25,y:103+CGFloat(i)*140,width:width,height:44),xRadius:22,yRadius:22).fill();if progress>0.01{for j in 0..<3{NSBezierPath(ovalIn:CGRect(x:35+width+CGFloat(j)*54,y:103+CGFloat(i)*140,width:44,height:44)).fill()}}}
        }
        DebugPaint.text("Native geometry experiment; SwiftUI matchedGeometry / union IDs have no AppKit equivalent here.",CGRect(x:25,y:bounds.height-52,width:bounds.width-50,height:40),size:11,color:.secondaryLabelColor)
    }
}
