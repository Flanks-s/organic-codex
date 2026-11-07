import AppKit

/// Demo-only approval card. Live never infers an access grant from the prototype account.
@MainActor final class SettingsDaybreakCard:SettingsView {
    var email=""{didSet{approval.stringValue="Approved for "+email;setAccessibilityLabel("Daybreak Access: Daybreak Blue, approved for "+email)}}
    private let access=SettingsDrawing.label("Daybreak Access",size:11,weight:.semibold)
    private let name=SettingsDrawing.label("Daybreak Blue",size:17,weight:.bold)
    private let explanation=SettingsDrawing.label("Expanded cyber capabilities for approved security work. Turn it on for a chat from the model picker.",size:12)
    private let approval=SettingsDrawing.label(size:11)
    private var stars:[SettingsDaybreakStar]=[]
    private var displayObserver:NSObjectProtocol?
    private let points:[(CGFloat,CGFloat)]=[(0.08,0.22),(0.19,0.58),(0.31,0.14),(0.44,0.36),(0.53,0.12),(0.61,0.30)]
    override init(frame:NSRect){super.init(frame:frame);for view in [access,name,explanation,approval]{view.usesPalette=false;addSubview(view)}
        access.textColor=SettingsDrawing.hex("#ffc77a");name.textColor = .white;explanation.textColor = .white.withAlphaComponent(0.78);approval.textColor = .white.withAlphaComponent(0.7)
        stars=points.enumerated().map{i,_ in let star=SettingsDaybreakStar();star.wantsLayer=true;star.layer?.opacity=i.isMultiple(of:2) ? 0.9:0.35;addSubview(star,positioned:.below,relativeTo:access);return star}
        displayObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.syncStars();self?.needsDisplay=true}}
        explanation.maximumNumberOfLines=3;explanation.cell?.wraps=true;setAccessibilityElement(true);setAccessibilityRole(.group)
    }
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    isolated deinit{if let displayObserver{NSWorkspace.shared.notificationCenter.removeObserver(displayObserver)}}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();syncStars()}
    private func syncStars(){for star in stars {star.layer?.removeAllAnimations()}}
    override func accessibilityChildren()->[Any]?{[]}
    override func layout(){super.layout();for (i,point) in points.enumerated(){place(stars[i],CGRect(x:bounds.width*point.0-1,y:bounds.height*point.1-1,width:2,height:2))};place(access,CGRect(x:40.5,y:29,width:max(1,bounds.width-60),height:15));place(name,CGRect(x:14,y:47,width:max(1,bounds.width-32),height:23));place(explanation,CGRect(x:14,y:71,width:min(300,bounds.width-32),height:31));place(approval,CGRect(x:40,y:107,width:max(1,bounds.width-58),height:16))}
    override func draw(_ dirtyRect:NSRect){
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        let path=NSBezierPath(roundedRect:bounds,xRadius:10,yRadius:10);path.addClip()
        let reduced=NativeDisplayOptions.shared.state.reducesEffects
        if reduced{SettingsDrawing.hex("#18213b").setFill();bounds.fill()}
        else{SettingsArt.diagonalGradient([SettingsDrawing.hex("#0d1430"),SettingsDrawing.hex("#24305a"),SettingsDrawing.hex("#5a4a63")],in:bounds)}
        SettingsArt.symbol("sunrise.fill",in:CGRect(x:16,y:30,width:16,height:14),size:11,color:SettingsDrawing.hex("#ffc77a"),weight:.semibold)
        if !reduced,let context=NSGraphicsContext.current?.cgContext,let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[SettingsDrawing.hex("#ffd89a").cgColor,SettingsDrawing.hex("#ff9f50",alpha:0).cgColor] as CFArray,locations:[0,1]) {let center=CGPoint(x:bounds.width*0.84,y:bounds.height*0.82);context.drawRadialGradient(gradient,startCenter:center,startRadius:0,endCenter:center,endRadius:46,options:[])}
        SettingsArt.symbol("checkmark.seal.fill",in:CGRect(x:16,y:109,width:14,height:14),size:11,color:.white.withAlphaComponent(0.7),weight:.regular)
        if let context=NSGraphicsContext.current?.cgContext,let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[SettingsDrawing.hex("#f6a95a",alpha:0).cgColor,SettingsDrawing.hex("#ffb35c",alpha:0.7).cgColor,SettingsDrawing.hex("#ffe3b0").cgColor,SettingsDrawing.hex("#ffc77a",alpha:0.6).cgColor] as CFArray,locations:[0,0.33,0.66,1]) {
            context.saveGState();context.move(to:CGPoint(x:bounds.width*0.2,y:bounds.height));context.addCurve(to:CGPoint(x:bounds.width,y:bounds.height*0.61),control1:CGPoint(x:bounds.width*0.44,y:bounds.height*0.61),control2:CGPoint(x:bounds.width*0.73,y:bounds.height*0.53));context.setLineWidth(1.6);context.replacePathWithStrokedPath();context.clip();context.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:bounds.width,y:0),options:[]);context.restoreGState()
        }
    }
}

@MainActor private final class SettingsDaybreakStar:SettingsView {
    override func draw(_ dirtyRect:NSRect){NSColor.white.setFill();NSBezierPath(ovalIn:bounds).fill()}
}
