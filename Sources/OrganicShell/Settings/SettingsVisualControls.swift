import AppKit

@MainActor final class SettingsSegments:SettingsView {
    var choose:((String)->Void)?
    var isEnabled=true{didSet{buttons.forEach{$0.isEnabled=isEnabled}}}
    private(set) var buttons:[SettingsButton]=[]
    private var choices:[(String,String)]=[],value=""
    func configure(choices:[(String,String)],value:String){self.choices=choices;self.value=value
        if buttons.count != choices.count{buttons.forEach{$0.removeFromSuperview()};buttons=choices.enumerated().map{i,_ in let b=SettingsButton();b.chromeless=true;b.run={ [weak self] in guard let self,self.isEnabled,self.choices.indices.contains(i)else{return};self.choose?(self.choices[i].0) };b.setAccessibilityRole(.radioButton);addSubview(b);return b}}
        for (i,b) in buttons.enumerated(){b.title="";b.setAccessibilityLabel(choices[i].1);b.setAccessibilityValue(choices[i].0 == value ? 1:0);b.isEnabled=isEnabled};needsLayout=true;needsDisplay=true
    }
    override func layout(){super.layout();for (i,b) in buttons.enumerated(){place(b,CGRect(x:CGFloat(i)*bounds.width/CGFloat(max(1,buttons.count)),y:0,width:bounds.width/CGFloat(max(1,buttons.count)),height:bounds.height))}}
    override func draw(_ dirtyRect:NSRect){
        SettingsArt.plate(bounds,radius:6,color:.white.withAlphaComponent(0.08))
        for (i,item) in choices.enumerated(){let r=CGRect(x:CGFloat(i)*bounds.width/CGFloat(max(1,choices.count)),y:0,width:bounds.width/CGFloat(max(1,choices.count)),height:bounds.height)
            if item.0 == value{SettingsArt.plate(r,radius:6,color:.white.withAlphaComponent(0.15))}
            else if i>0 {NSColor.white.withAlphaComponent(0.12).setFill();CGRect(x:r.minX,y:5,width:1,height:max(1,r.height-10)).fill()}
            SettingsDrawing.text(item.1,in:r.insetBy(dx:5,dy:3),font:.systemFont(ofSize:12),color:.labelColor,alignment:.center)
        }
    }
}
@MainActor final class SettingsTextSlider:NSControl {
    static let stops=[0.85,1.0,1.15,1.3,1.5]
    var trackRect:CGRect{CGRect(x:16,y:bounds.midY-3,width:max(1,min(160,bounds.width-32)),height:6)}
    var changed:((Double)->Void)?
    override var doubleValue:Double{didSet{needsDisplay=true}}
    override var acceptsFirstResponder:Bool{true}
    override var isFlipped:Bool{true}
    override func draw(_ dirtyRect:NSRect){
        let y=bounds.midY,track=trackRect
        SettingsArt.plate(track,radius:3,color:.white.withAlphaComponent(0.3))
        for i in Self.stops.indices{SettingsArt.plate(CGRect(x:track.minX+8+CGFloat(i)*max(1,track.width-16)/4,y:y+6,width:1,height:1),radius:0,color:.secondaryLabelColor)}
        let values=Self.stops,index=values.indices.min(by:{abs(values[$0]-doubleValue)<abs(values[$1]-doubleValue)}) ?? 1
        let x=track.minX+8+CGFloat(index)/4*max(1,track.width-16)
        SettingsArt.plate(CGRect(x:x-10,y:y-7,width:20,height:14),radius:7,color:.white)
        SettingsDrawing.text("A",in:CGRect(x:1,y:y-6,width:14,height:14),font:.systemFont(ofSize:10),color:.labelColor)
        SettingsDrawing.text("A",in:CGRect(x:bounds.width-10.5,y:y-9,width:14,height:18),font:.systemFont(ofSize:16),color:.labelColor)
    }
    override func mouseDown(with event:NSEvent){guard isEnabled else{return};move(event)}
    override func mouseDragged(with event:NSEvent){guard isEnabled else{return};move(event)}
    private func move(_ e:NSEvent){let p=convert(e.locationInWindow,from:nil),levels=Self.stops;let i=Int((max(0,min(1,(p.x-trackRect.minX-8)/max(1,trackRect.width-16)))*4).rounded());doubleValue=levels[i];changed?(doubleValue)}
    override func keyDown(with event:NSEvent){if [123,124].contains(event.keyCode){step(event.keyCode == 124 ? 1:-1)}else{super.keyDown(with:event)}}
    override func accessibilityRole()->NSAccessibility.Role?{.slider}
    override func accessibilityValue()->Any?{doubleValue}
    override func accessibilityPerformIncrement()->Bool{guard isEnabled else{return false};step(1);return true}
    override func accessibilityPerformDecrement()->Bool{guard isEnabled else{return false};step(-1);return true}
    private func step(_ direction:Int){let levels=Self.stops,i=levels.indices.min(by:{abs(levels[$0]-doubleValue)<abs(levels[$1]-doubleValue)}) ?? 1;doubleValue=levels[max(0,min(4,i+direction))];changed?(doubleValue)}
}
@MainActor final class SettingsAccentChoices:SettingsView {
    var selected="multi",custom="",choose:((String)->Void)?,openCustom:(()->Void)?
    private var buttons:[SettingsButton]=[]
    private let ids=["custom","multi","blue","purple","pink","red","orange","yellow","green","graphite"]
    private let colors=["#808080","#ffffff","#0a84ff","#bf5af2","#ff375f","#ff453a","#ff9f0a","#ffd60a","#30d158","#8e8e93"]
    override init(frame:NSRect){super.init(frame:frame);buttons=ids.map{id in let b=SettingsButton();b.title="";b.chromeless=true;b.setAccessibilityLabel(id == "multi" ? "Multicolor":id.capitalized);b.setAccessibilityRole(.radioButton);b.run={ [weak self] in if id == "custom"{self?.openCustom?()}else{self?.choose?(id)} };addSubview(b);return b}}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override func layout(){super.layout();for (i,b) in buttons.enumerated(){place(b,CGRect(x:CGFloat(i)*23+(i == 0 ? 0:8),y:0,width:20,height:22));b.setAccessibilityValue(ids[i] == selected ? 1:0)};needsDisplay=true}
    override func draw(_ dirtyRect:NSRect){for (i,id) in ids.enumerated(){let r=CGRect(x:CGFloat(i)*23+(i == 0 ? 0:8)+2,y:1,width:16,height:16)
        if id == "multi"{let center=CGPoint(x:r.midX,y:r.midY);for j in 0..<6{let p=NSBezierPath();p.move(to:center);p.appendArc(withCenter:center,radius:8,startAngle:CGFloat(j)*60,endAngle:CGFloat(j+1)*60);p.close();NSColor(calibratedHue:CGFloat(j)/6,saturation:0.8,brightness:1,alpha:1).setFill();p.fill()}}
        else{SettingsArt.plate(r,radius:8,color:id == "custom" && !SettingsPreferences.isHex(custom) ? .white.withAlphaComponent(0.1):SettingsDrawing.hex(id == "custom" ? custom:colors[i]))}
        if id == "custom"{SettingsArt.symbol(SettingsPreferences.isHex(custom) ? "eyedropper":"plus",in:r,size:8,color:.white,weight:.bold)}
        if id == selected {if id == "custom"{NSColor.white.withAlphaComponent(0.9).setStroke();let p=NSBezierPath(ovalIn:r.insetBy(dx:-3,dy:-3));p.lineWidth=1.5;p.stroke()}else{SettingsArt.plate(CGRect(x:r.midX-2.5,y:r.midY-2.5,width:5,height:5),radius:2.5,color:.white)}}
        };NSColor.white.withAlphaComponent(0.15).setFill();CGRect(x:25,y:2,width:1,height:14).fill();SettingsDrawing.text(selected == "multi" ? "Multicolor":selected.capitalized,in:CGRect(x:0,y:21,width:bounds.width-6,height:14),font:.systemFont(ofSize:11),color:.secondaryLabelColor,alignment:.right)
    }
}

/// Product-specific illustrations/plots. Each is a small deterministic drawing with separate native action controls.
@MainActor final class SettingsFigure:SettingsView {
    var spec:SettingsRow
    init(_ spec:SettingsRow){self.spec=spec;super.init(frame:.zero);setAccessibilityRole(.image);setAccessibilityLabel(spec.title+" "+spec.detail)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    private func text(_ s:String,_ r:CGRect,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular,_ color:NSColor = .labelColor,_ alignment:NSTextAlignment = .left){SettingsDrawing.text(s,in:r,font:.systemFont(ofSize:size,weight:weight),color:color,alignment:alignment)}
    override func draw(_ dirtyRect:NSRect){
        let w=bounds.width,h=bounds.height,accent=SettingsDrawing.palette(self).accent
        switch spec.visual.style {
        case .profile:
            SettingsArt.avatar(spec.title.split(separator:" ").prefix(2).compactMap{$0.first}.map(String.init).joined(),in:CGRect(x:w/2-32,y:8,width:64,height:64))
            text(spec.title,CGRect(x:0,y:78,width:w,height:23),17,.bold,.labelColor,.center)
            text(spec.detail,CGRect(x:0,y:105,width:w,height:18),12,.regular,.secondaryLabelColor,.center)
        case .statistics:
            for (i,pair) in [("2.4bn","Lifetime tokens"),("310M","Peak day"),("3h 12m","Longest task"),("23 days","Longest streak"),("9 days","Current streak")].enumerated(){let x=CGFloat(i)*w/5; text(pair.0,CGRect(x:x,y:4,width:w/5,height:21),15,.bold,.labelColor,.center);text(pair.1,CGRect(x:x,y:25,width:w/5,height:14),10,.regular,.secondaryLabelColor,.center)}
        case .activity:
            let range=spec.visual.actions.first?.value.settingsText ?? "daily"
            text(range == "daily" ? "1,284 active hours in the last year":range == "weekly" ? "Tokens per week":"Tokens over the year",CGRect(x:0,y:6.5,width:max(1,w-250),height:18),12,.regular,.secondaryLabelColor)
            let cells=SettingsDemoVisuals.profileGrid(range)
            for (i,n) in cells.enumerated() where n>=0{let c=n == 0 ? SettingsButton.ink(SettingsDrawing.palette(self).label,opacity:0.07):accent.withAlphaComponent([0,0.3,0.5,0.75,1][Int(n)])
                SettingsArt.plate(CGRect(x:CGFloat(i/7)*10,y:32+CGFloat(i%7)*10,width:8,height:8),radius:1.5,color:c)}
            for (i,month) in ["Nov","Dec","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct"].enumerated(){text(month,CGRect(x:CGFloat(i)*w/12,y:108,width:48,height:13),9,.regular,.tertiaryLabelColor)}
        case .pluginTiles:
            let total:CGFloat=432,left=(w-total)/2
            for (i,p) in [("design","Product Design"),("git","Git Host"),("drive","Drive"),("calendar","Calendar"),("contacts","Contacts")].enumerated(){let x=left+CGFloat(i)*90,style=SettingsPresentation.pluginStyle(p.0);SettingsArt.tile(style.0,style.1,in:CGRect(x:x+14,y:6,width:44,height:44));text(p.1,CGRect(x:x,y:55,width:72,height:15),11,.regular,.secondaryLabelColor,.center)}
        case .storage:
            text(spec.title,CGRect(x:0,y:4,width:w,height:18),13,.semibold)
            let parts=spec.value["parts"]?.arrayValue ?? [],total=max(1,parts.reduce(0){$0+($1["mb"]?.doubleValue ?? 0)});var x:CGFloat=0
            NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:CGRect(x:0,y:28,width:w,height:12),xRadius:4,yRadius:4).addClip()
            for p in parts{let width=w*CGFloat((p["mb"]?.doubleValue ?? 0)/total);SettingsDrawing.hex(p["hex"]?.settingsText ?? "#8e8e93").setFill();CGRect(x:x,y:28,width:max(0,width-1),height:12).fill();x+=width};NSGraphicsContext.restoreGraphicsState()
            x=0
            for p in parts{let name=p["id"]?.settingsText ?? "",color=SettingsDrawing.hex(p["hex"]?.settingsText ?? "#8e8e93");SettingsArt.plate(CGRect(x:x,y:51,width:7,height:7),radius:3.5,color:color);text(name,CGRect(x:x+11,y:48,width:120,height:15),11);text(String(format:"%.1f MB",p["mb"]?.doubleValue ?? 0),CGRect(x:x,y:63,width:120,height:14),10,.regular,.secondaryLabelColor);x += (name as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width+24}
        case .meter:
            text(spec.title,CGRect(x:0,y:2,width:w-100,height:18));text(spec.detail,CGRect(x:0,y:20,width:w,height:15),11,.regular,.secondaryLabelColor)
            let fraction=CGFloat(max(0,min(1,spec.value.doubleValue ?? 0)))
            text(spec.visual.rightText.isEmpty ? String(format:"%.0f%% left",fraction*100):spec.visual.rightText,CGRect(x:w-100,y:2,width:100,height:18),13,.semibold,spec.tint ?? .secondaryLabelColor,.right)
            SettingsArt.plate(CGRect(x:0,y:h-8,width:w,height:5),radius:2.5,color:.white.withAlphaComponent(0.1));SettingsArt.plate(CGRect(x:0,y:h-8,width:w*fraction,height:5),radius:2.5,color:spec.tint ?? accent)
        case .usageChart:
            text(spec.title,CGRect(x:0,y:4,width:55,height:27),20,.bold);text(spec.detail,CGRect(x:52,y:12,width:200,height:18),12,.regular,.secondaryLabelColor)
            let vals=spec.value.arrayValue?.compactMap(\.doubleValue) ?? [],maxN=vals.max() ?? 1,gap:CGFloat=5,bw=(w-CGFloat(max(0,vals.count-1))*gap)/CGFloat(max(1,vals.count))
            for (i,n) in vals.enumerated(){let bh=max(2,90*n/maxN);SettingsArt.plate(CGRect(x:CGFloat(i)*(bw+gap),y:126-bh,width:bw,height:bh),radius:3,color:i<7 ? SettingsButton.ink(SettingsDrawing.palette(self).label,opacity:0.18):accent)}
            for (i,date) in ["Oct 8","Oct 11","Oct 14","Oct 17","Today"].enumerated(){text(date,CGRect(x:CGFloat(i)*(w-30)/4,y:134,width:60,height:14),10,.regular,.tertiaryLabelColor)}
        case .empty:
            SettingsArt.symbol(spec.visual.symbol.isEmpty ? "gearshape":spec.visual.symbol,in:CGRect(x:w/2-14,y:h/2-10,width:28,height:28),size:28,color:.tertiaryLabelColor);text(spec.title,CGRect(x:0,y:h/2+28,width:w,height:20),13,.semibold,.labelColor,.center)
        default:break
        }
    }
}

@MainActor final class SettingsPaletteDot:SettingsButton {
    var color=NSColor.systemBlue
    override func draw(_ dirtyRect:NSRect){SettingsArt.plate(bounds,radius:bounds.width/2,color:color);NSColor.white.withAlphaComponent(0.25).setStroke();let p=NSBezierPath(ovalIn:bounds.insetBy(dx:0.25,dy:0.25));p.lineWidth=0.5;p.stroke()}
}

/// Stepper's two native actions with a drawn bezel, matching the product's 1…20 worktree control.
@MainActor final class SettingsCounter:NSControl {
    var changed:((Int)->Void)?
    override var integerValue:Int{didSet{needsDisplay=true}}
    override var acceptsFirstResponder:Bool{true}
    override var isFlipped:Bool{true}
    override func draw(_ dirtyRect:NSRect){SettingsDrawing.text("\(integerValue) worktrees",in:CGRect(x:0,y:4,width:104,height:18),font:.systemFont(ofSize:13),color:.labelColor,alignment:.right);let r=CGRect(x:112,y:0,width:18,height:24);SettingsArt.plate(r,radius:5,color:.white.withAlphaComponent(0.12));SettingsArt.symbol("chevron.up",in:CGRect(x:116,y:4,width:10,height:6),size:8);SettingsArt.symbol("chevron.down",in:CGRect(x:116,y:15,width:10,height:6),size:8)}
    override func mouseDown(with event:NSEvent){guard isEnabled else{return};step(convert(event.locationInWindow,from:nil).y<12 ? 1:-1)}
    override func keyDown(with event:NSEvent){if [125,126].contains(event.keyCode){step(event.keyCode == 126 ? 1:-1)}else{super.keyDown(with:event)}}
    override func accessibilityRole()->NSAccessibility.Role?{.incrementor}
    override func accessibilityValue()->Any?{integerValue}
    override func accessibilityPerformIncrement()->Bool{guard isEnabled else{return false};step(1);return true}
    override func accessibilityPerformDecrement()->Bool{guard isEnabled else{return false};step(-1);return true}
    private func step(_ delta:Int){guard isEnabled else{return};integerValue=max(1,min(20,integerValue+delta));changed?(integerValue)}
}

/// A clipped horizontal theme strip with an explicit pixel-aligned offset. NSScrollView changes a detached clip
/// view's bounds while it tiles/resizes; using a plain viewport makes initial selection and capture repeatable.
@MainActor final class SettingsThemeViewport:SettingsView {
    weak var canvas:SettingsView?
    private(set) var offset:CGFloat=0
    override init(frame:NSRect){super.init(frame:frame);clipsToBounds=true;setAccessibilityRole(.scrollArea);setAccessibilityLabel("Theme choices")}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    func setOffset(_ proposed:CGFloat){guard let canvas else{return};offset=(min(max(0,canvas.bounds.width-bounds.width),max(0,proposed))*scale).rounded()/scale;canvas.frame.origin=CGPoint(x:-offset,y:0);needsDisplay=true}
    func reveal(_ rect:CGRect){if rect.minX<offset{setOffset(rect.minX)}else if rect.maxX>offset+bounds.width{setOffset(rect.maxX-bounds.width)}}
    override func scrollWheel(with event:NSEvent){if abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift){setOffset(offset+(abs(event.scrollingDeltaX)>0 ? event.scrollingDeltaX:event.scrollingDeltaY))}else{super.scrollWheel(with:event)}}
    override func accessibilityCustomActions()->[NSAccessibilityCustomAction]?{[NSAccessibilityCustomAction(name:"Previous themes",handler:{[weak self] in self?.accessibilityPerformScrollLeft() ?? false}),NSAccessibilityCustomAction(name:"Next themes",handler:{[weak self] in self?.accessibilityPerformScrollRight() ?? false})]}
    func accessibilityPerformScrollLeft()->Bool{let old=offset;setOffset(offset-168);return old != offset}
    func accessibilityPerformScrollRight()->Bool{let old=offset;setOffset(offset+168);return old != offset}
}
