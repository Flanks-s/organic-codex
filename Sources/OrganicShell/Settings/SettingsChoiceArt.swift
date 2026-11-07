import AppKit

/// Independent AppKit copy of ChoiceCards/ChoiceArt/AppearanceModes (SettingsComponents.swift:257–392).
/// Geometry is the artwork's actual geometry; neither letters nor a native bezel are stretched into a thumbnail.
@MainActor final class SettingsChoiceArt:SettingsButton {
    var value="",art="",selected=false,caption=""
    override init(frame:NSRect){super.init(frame:frame);setButtonType(.radio);setAccessibilityRole(.radioButton)}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    override var isFlipped:Bool{true}
    override func accessibilityValue()->Any?{selected ? 1:0}
    override func draw(_ dirtyRect:NSRect){
        let modes=art == "modes",w:CGFloat=modes ? 66:70,h:CGFloat=modes ? 44:46
        let r=CGRect(x:(bounds.width-w)/2,y:0,width:w,height:h),accent=SettingsDrawing.palette(self).accent
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect:r,xRadius:modes ? 7:8,yRadius:modes ? 7:8).addClip()
        NSColor.textBackgroundColor.setFill();r.fill()
        if modes {
            let parts=value == "auto" ? [true,false]:[value == "light"]
            for (i,light) in parts.enumerated(){let x=r.minX+CGFloat(i)*w/CGFloat(parts.count),rw=w/CGFloat(parts.count)
                SettingsDrawing.hex(light ? "#d8dde4":"#2a2d33").setFill();CGRect(x:x,y:0,width:rw,height:h).fill()
                SettingsArt.plate(CGRect(x:x+6,y:9,width:26,height:22),radius:3,color:light ? .white:SettingsDrawing.hex("#45484f"))
                SettingsArt.plate(CGRect(x:x+10,y:14,width:12,height:3),radius:1.5,color:accent)
            }
        } else if art == "glass" {
            SettingsArt.diagonalGradient([SettingsDrawing.hex("#3bafc2",alpha:0.55),SettingsDrawing.hex("#57c27a",alpha:0.55)],in:r)
            let p=CGRect(x:r.minX+5,y:5,width:22,height:36)
            SettingsArt.plate(p,radius:5,color:.white.withAlphaComponent(value == "clear" ? 0.10:0.32))
            NSColor.white.withAlphaComponent(0.35).setStroke();let path=NSBezierPath(roundedRect:p.insetBy(dx:0.25,dy:0.25),xRadius:5,yRadius:5);path.lineWidth=0.5;path.stroke()
        } else {
            SettingsDrawing.hex("#1e1e1e").setFill();r.fill()
            SettingsArt.plate(CGRect(x:r.minX+4,y:4,width:16,height:38),radius:3,color:.white.withAlphaComponent(0.10))
            for (i,l) in [30.0,38,24].enumerated(){SettingsArt.plate(CGRect(x:r.minX+25,y:9+CGFloat(i)*7,width:l,height:3),radius:1.5,color:.white.withAlphaComponent(i == 0 ? 0.22:0.16))}
            SettingsArt.plate(CGRect(x:r.minX+24,y:33,width:40,height:7),radius:3.5,color:.white.withAlphaComponent(0.14))
            if art == "access" {
                SettingsArt.symbol(value == "read" ? "lock.shield":value == "auto" ? "checkmark.shield":"exclamationmark.shield.fill",in:CGRect(x:r.maxX-21,y:25,width:16,height:16),size:15,color:value == "full" ? .systemOrange:value == "auto" ? accent:.secondaryLabelColor,weight:.semibold)
            } else if art == "send" {
                let key=value == "⌘↩" ? "⌘↩":value == "↩" ? "↩":value
                let kw=max(16,(key as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.semibold)]).width+8)
                let kr=CGRect(x:r.maxX-kw-5,y:26,width:kw,height:15);SettingsArt.plate(kr,radius:4,color:.white.withAlphaComponent(0.14))
                let base=NSFont.systemFont(ofSize:10,weight:.semibold),font=NSFont(descriptor:base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,size:10) ?? base
                SettingsDrawing.text(key,in:kr.offsetBy(dx:0,dy:1),font:font,color:.labelColor,alignment:.center)
            } else if value == "queue" {
                for (i,l) in [18.0,14,10].enumerated(){SettingsArt.plate(CGRect(x:r.maxX-6-l,y:14+CGFloat(i)*7,width:l,height:5),radius:2.5,color:accent.withAlphaComponent([0.55,0.35,0.2][i]))}
            } else {SettingsArt.symbol("arrow.turn.up.right",in:CGRect(x:r.maxX-20,y:21,width:14,height:14),size:13,color:accent,weight:.semibold)}
        }
        NSGraphicsContext.restoreGraphicsState()
        (selected ? accent:NSColor.white.withAlphaComponent(0.12)).setStroke()
        let line:CGFloat=selected ? 2.5:1,path=NSBezierPath(roundedRect:r.insetBy(dx:line/2,dy:line/2),xRadius:modes ? 7:8,yRadius:modes ? 7:8);path.lineWidth=line;path.stroke()
        SettingsDrawing.text(caption,in:CGRect(x:0,y:h+5,width:bounds.width,height:16),font:.systemFont(ofSize:11,weight:selected ? .semibold:.regular),color:selected ? .labelColor:.secondaryLabelColor,alignment:.center)
    }
}

@MainActor final class SettingsCardChoices:SettingsChoice {
    var art=""{didSet{syncCards()}}
    private(set) var cards:[SettingsChoiceArt]=[]
    func syncCards(){
        if cards.count != choices.count {cards.forEach{$0.removeFromSuperview()};cards=choices.map{_ in let c=SettingsChoiceArt();addSubview(c);return c}}
        for (i,c) in cards.enumerated(){c.value=choices[i].0;c.caption=choices[i].1;c.art=art;c.selected=c.value == selected;c.isEnabled=isEnabled
            c.setAccessibilityLabel(c.caption);c.run={ [weak self,weak c] in guard let self,let c else{return};self.choose?(c.value) };c.needsDisplay=true}
        setAccessibilityRole(.group);setAccessibilityLabel(title);needsLayout=true
    }
    override func draw(_ dirtyRect:NSRect){}
    override func layout(){super.layout();let width:CGFloat=art == "modes" ? 66:70,gap:CGFloat=art == "modes" ? 14:10
        for (i,c) in cards.enumerated(){c.frame=SettingsDrawing.align(CGRect(x:CGFloat(i)*(width+gap),y:0,width:width,height:66),window?.backingScaleFactor ?? 2)}}
    override func mouseDown(with event:NSEvent){}
    override func keyDown(with event:NSEvent){
        guard isEnabled else{return};let i=choices.firstIndex{$0.0 == selected} ?? 0
        if [123,124].contains(event.keyCode){let j=max(0,min(choices.count-1,i+(event.keyCode == 124 ? 1:-1)));choose?(choices[j].0)}
        else if event.keyCode == 49 || event.keyCode == 36{choose?(selected)}else{super.keyDown(with:event)}
    }
}

@MainActor enum SettingsArt {
    /// SwiftUI UnitPoint.topLeading → bottomTrailing maps to the RECT's corners, not a fixed 35° line.
    /// The distinction is large on the 600×150 Daybreak illustration and survives a change of window width.
    static func diagonalGradient(_ colors:[NSColor],in rect:CGRect){
        guard let context=NSGraphicsContext.current?.cgContext,let gradient=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB)!,colors:colors.map{$0.cgColor} as CFArray,locations:nil)else{return}
        context.drawLinearGradient(gradient,start:CGPoint(x:rect.minX,y:rect.minY),end:CGPoint(x:rect.maxX,y:rect.maxY),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    }
    static func plate(_ rect:CGRect,radius:CGFloat=6,color:NSColor){color.setFill();NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()}
    static func symbol(_ name:String,in rect:CGRect,size:CGFloat=14,color:NSColor = .secondaryLabelColor,weight:NSFont.Weight = .medium,imageScale:NSImage.SymbolScale = .medium){
        guard let image=NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:size,weight:weight,scale:imageScale).applying(.preferringMonochrome()))else{return}
        // SF Symbols' point size includes optical padding. Re-scaling that padded bitmap to a glyph rect
        // shrinks e.g. Terminal and shields twice; keep the configured font size, centred on its target.
        let s=image.size
        let drawing=CGRect(x:rect.midX-s.width/2,y:rect.midY-s.height/2,width:s.width,height:s.height)
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        context.saveGState();context.beginTransparencyLayer(auxiliaryInfo:nil)
        image.draw(in:drawing,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        context.setBlendMode(.sourceIn);context.setFillColor(color.cgColor);context.fill(drawing)
        context.endTransparencyLayer();context.restoreGState()
    }
    static func avatar(_ initials:String,in rect:CGRect){
        NSGradient(starting:SettingsDrawing.hex("#78d8a6"),ending:SettingsDrawing.hex("#2b8a7a"))?.draw(in:NSBezierPath(ovalIn:rect),angle:90)
        SettingsDrawing.text(initials,in:CGRect(x:rect.minX,y:rect.midY-rect.height*0.24,width:rect.width,height:rect.height*0.58),font:.systemFont(ofSize:rect.height*0.4,weight:.semibold),color:.white,alignment:.center)
    }
    static func tile(_ symbol:String,_ color:String,in rect:CGRect,imageScale:NSImage.SymbolScale = .medium){
        let pairs:[String:(String,String)]=[
            "#8e8e93":("#a1a1a6","#6c6c72"),"#ff453a":("#ff6a5f","#e0362c"),"#0a84ff":("#4aa3ff","#1a6ef0"),"#8587ff":("#8587ff","#5050e0"),"#5a5a60":("#5a5a60","#2c2c30"),"#57c27a":("#6bd39a","#2b8a6a"),"#b4946c":("#c3a47c","#8f7350"),"#bf5af2":("#cd85ff","#9a4fe6"),"#ff9f0a":("#ffad4a","#f07a12"),"#30c6bc":("#56dcd5","#1fa7a8"),"#50b8ed":("#6fd0ff","#1e9ee0"),"#30d158":("#55d97a","#25a84b"),
            "#c34cff":("#ee7bff","#9b3bf0"),"#29292c":("#48484c","#1c1c1e"),"#31c465":("#4bd37a","#1f9d48"),"#f65d55":("#ff7a6e","#e0362c"),"#d8d8db":("#f5f5f7","#d4d4d9"),"#39b5ed":("#74d6ff","#2a8fd8"),"#1686ff":("#4aa3ff","#1a6ef0"),"#55b990":("#6bd39a","#2b8a6a"),"#6fc3ff":("#6fc3ff","#1d7ff0"),"#4a4a4f":("#4a4a4f","#1c1c1e"),"#8fd0ff":("#8fd0ff","#3b8fe0"),"#5fb0ff":("#5fb0ff","#1460d8"),"#f5f5f7":("#f5f5f7","#c7c7cc"),"#ffe27a":("#ffe27a","#f4c430")]
        let base=SettingsDrawing.hex(color),pair=pairs[color.lowercased()]
        NSGradient(starting:pair.map{SettingsDrawing.hex($0.0)} ?? base,ending:pair.map{SettingsDrawing.hex($0.1)} ?? base)?.draw(in:NSBezierPath(roundedRect:rect,xRadius:rect.width*0.275,yRadius:rect.width*0.275),angle:90)
        self.symbol(symbol,in:rect.insetBy(dx:rect.width*0.16,dy:rect.height*0.16),size:rect.width*0.6,color:color.lowercased() == "#d8d8db" ? SettingsDrawing.hex("#1d1d1f"):.white,imageScale:imageScale)
    }
}
