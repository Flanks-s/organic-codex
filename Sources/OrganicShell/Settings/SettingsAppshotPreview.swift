import AppKit

/// Static Appshot illustration. Captures can inject a phase; mounted art has no idle animation clock.
@MainActor final class SettingsAppshotPreview:SettingsView {
    let outline=CAShapeLayer(),capture=CAShapeLayer()
    private let keys=SettingsAppshotKeys(),chip=SettingsAppshotChip()
    private var animationSize=CGSize.zero
    private var accessibilityObserver:NSObjectProtocol?
    var reduceMotion=false{didSet{syncAnimation();needsDisplay=true}}
    var verificationPhase:Double=1/9{didSet{needsDisplay=true}}
    private var reduced:Bool{reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    private var visiblePhase:Double{reduced ? 0.6:verificationPhase}
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer?.cornerRadius=10;layer?.masksToBounds=true
        outline.fillColor=NSColor.clear.cgColor;outline.lineWidth=2;outline.lineDashPattern=[5,4]
        capture.fillColor=NSColor.clear.cgColor
        layer?.addSublayer(outline);layer?.addSublayer(capture)
        for child in [keys,chip]{child.wantsLayer=true;addSubview(child)}
        setAccessibilityElement(false);setAccessibilityHidden(true)
        accessibilityObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.syncAnimation();self?.needsDisplay=true}}
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    isolated deinit{if let accessibilityObserver{NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)}}
    override func layout(){super.layout();let x=bounds.width/2-50,y=bounds.height/2
        CATransaction.begin();CATransaction.setDisableActions(true);outline.frame=bounds;capture.frame=bounds
        outline.strokeColor=SettingsDrawing.palette(self).accent.cgColor
        outline.path=CGPath(roundedRect:CGRect(x:x-75,y:y-45,width:150,height:90),cornerWidth:8,cornerHeight:8,transform:nil)
        place(keys,CGRect(x:bounds.midX+64,y:y-37,width:61,height:22));place(chip,CGRect(x:bounds.midX+29,y:y+15,width:132,height:22))
        keys.isHidden=true;chip.isHidden=true
        outline.opacity=0;keys.layer?.opacity=0.3;chip.layer?.opacity=0
        CATransaction.commit()
        if animationSize != bounds.size{syncAnimation()}
    }
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();syncAnimation();needsLayout=true;needsDisplay=true}
    private func syncAnimation(){
        outline.removeAllAnimations();capture.removeAllAnimations();keys.layer?.removeAllAnimations();chip.layer?.removeAllAnimations();animationSize=bounds.size
        CATransaction.begin();CATransaction.setDisableActions(true)
        outline.opacity=0;keys.isHidden=true;chip.isHidden=true
        CATransaction.commit();needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect){
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        NSBezierPath(roundedRect:bounds,xRadius:10,yRadius:10).addClip()
        SettingsArt.diagonalGradient([SettingsDrawing.hex("#1f3b4d"),SettingsDrawing.hex("#2d5a52")],in:bounds)
        let x=bounds.width/2-50,y=bounds.height/2,windowRect=CGRect(x:x-75,y:y-45,width:150,height:90)
        SettingsArt.plate(windowRect,radius:6,color:SettingsDrawing.hex("#1e1e1e"))
        for i in 0..<3{SettingsArt.plate(CGRect(x:windowRect.minX+5+CGFloat(i)*8,y:windowRect.minY+5,width:5,height:5),radius:2.5,color:.secondaryLabelColor.withAlphaComponent(0.5))}
        for (i,width) in [70.0,96,54].enumerated(){SettingsArt.plate(CGRect(x:windowRect.minX+12,y:y-10+CGFloat(i)*8,width:width,height:4),radius:2,color:.secondaryLabelColor.withAlphaComponent(i == 0 ? 0.35:0.25))}
        do {
            if visiblePhase<0.55{let extra=1-min(1,visiblePhase*3),w=150+40*extra,h=90+24*extra
                SettingsDrawing.palette(self).accent.setStroke();let p=NSBezierPath(roundedRect:CGRect(x:x-w/2,y:y-h/2,width:w,height:h),xRadius:8,yRadius:8);p.lineWidth=2;p.setLineDash([5,4],count:2,phase:0);p.stroke()}
            SettingsAppshotKeys.paint(in:CGRect(x:bounds.midX+64,y:y-37,width:61,height:22),alpha:visiblePhase>0.2 && visiblePhase<0.6 ? 1:0.3)
            if visiblePhase>0.6{SettingsAppshotChip.paint(in:CGRect(x:bounds.midX+29,y:y+15,width:132,height:22))}
        }
    }
}
@MainActor private final class SettingsAppshotKeys:SettingsView {
    override func draw(_ dirtyRect:NSRect){Self.paint(in:bounds,alpha:1)}
    static func paint(in r:CGRect,alpha:CGFloat){for dx:CGFloat in [0,37]{SettingsArt.plate(CGRect(x:r.minX+dx,y:r.minY,width:24,height:22),radius:5,color:.white.withAlphaComponent(0.18*alpha));SettingsDrawing.text("⇧",in:CGRect(x:r.minX+dx,y:r.minY+3,width:24,height:17),font:.systemFont(ofSize:12,weight:.semibold),color:.white.withAlphaComponent(alpha),alignment:.center)}
        SettingsDrawing.text("+",in:CGRect(x:r.minX+26,y:r.minY+5,width:9,height:16),font:.systemFont(ofSize:11),color:.white.withAlphaComponent(0.8*alpha),alignment:.center)}
}
@MainActor private final class SettingsAppshotChip:SettingsView {
    override func draw(_ dirtyRect:NSRect){Self.paint(in:bounds)}
    static func paint(in r:CGRect){SettingsArt.plate(r,radius:11,color:NSColor(white:0.27,alpha:0.95));SettingsArt.symbol("macwindow",in:CGRect(x:r.minX+8,y:r.minY+5,width:13,height:12),size:11,color:.labelColor);SettingsDrawing.text("Appshot · Notes",in:CGRect(x:r.minX+26,y:r.minY+4,width:r.width-32,height:15),font:.systemFont(ofSize:11,weight:.medium),color:.labelColor)}
}
