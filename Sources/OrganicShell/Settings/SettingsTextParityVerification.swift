#if SETTINGS_SELFTEST
import AppKit
import ImageIO

/// Read-only measurements against original 2× window captures. A translation is reported separately from
/// residual ink error: repainting a matching glyph with a different weight to hide a 1px offset is incorrect.
@MainActor enum SettingsTextParityVerification {
    private static var records:[String:Any]=[:]
    static func capture(_ pane:String,workbench:NativeSettingsWorkbench,image:CGImage,product:CGImage,reference:URL,target:URL,check:(Bool,String)->Void){
        let after=Pixels(image),expected=Pixels(product)
        let real=load(reference.appendingPathComponent("settings-"+pane+"-v2.png")).map(Pixels.init)
        var before:Pixels?
        if let path=ProcessInfo.processInfo.environment["SETTINGS_M9C_BASELINE"]{before=load(URL(fileURLWithPath:path).appendingPathComponent("settings-"+pane+"-v2@2x.png")).map(Pixels.init)}
        var labels:[[String:Any]]=[]
        for label in SettingsVerification.tree(workbench.view).compactMap({$0 as? SettingsLabel}) where !label.isHiddenOrHasHiddenAncestor && !label.stringValue.isEmpty {
            let frame=workbench.view.convert(label.bounds,from:label)
            guard frame.minY>=52,frame.maxY<660,frame.minX>=0 else{continue}
            let width=min(frame.width,ceil((label.stringValue as NSString).size(withAttributes:[.font:label.font!]).width)+5,70)
            let crop=CGRect(x:frame.minX*2,y:max(104,frame.minY*2-8),width:width*2,height:frame.height*2+16)
            guard crop.maxX<1760,crop.maxY<1320 else{continue}
            let threshold=frame.minX<220 ? 150:((label.font?.pointSize ?? 13)<=11 ? 100:120)
            var item:[String:Any]=["text":label.stringValue,"frame":[frame.minX,frame.minY,frame.width,frame.height],"after":after.fit(expected,crop,threshold:threshold)]
            if let real {item["realBefore"]=real.fit(expected,crop,threshold:threshold)}
            if let before {item["offscreenBefore"]=before.fit(expected,crop,threshold:threshold)}
            labels.append(item)
            let fit=item["after"] as! [String:Any],sum=fit["inkSum"] as! Int,error=fit["alignedInkError"] as! Int
            if sum>3000 && Double(error)/Double(sum)<0.02 && label !== workbench.titleLabel {
                check((fit["dx"] as! Int) == 0 && (fit["dy"] as! Int) == 0,"Text parity \(pane) \(label.stringValue.prefix(35)) has no integer backing-pixel displacement: \(fit)")
            }
        }
        for button in SettingsVerification.tree(workbench.form).compactMap({$0 as? SettingsButton}) where !button.isHiddenOrHasHiddenAncestor && !button.title.isEmpty && !(button is SettingsCardChoices) && !(button is SettingsThemeTile) && !(button is SettingsChoiceArt) && button.style != .toggle && button.style != .checkbox {
            let frame=workbench.view.convert(button.bounds,from:button)
            guard frame.minY>=52,frame.maxY<656,frame.minX>=220 else{continue}
            let crop=CGRect(x:frame.minX*2,y:frame.minY*2,width:min(frame.width,100)*2,height:frame.height*2)
            var item:[String:Any]=["text":button.title,"kind":"button","frame":[frame.minX,frame.minY,frame.width,frame.height],"after":after.fit(expected,crop,threshold:120)]
            if let real{item["realBefore"]=real.fit(expected,crop,threshold:120)}
            if let before{item["offscreenBefore"]=before.fit(expected,crop,threshold:120)}
            if (pane == "plugins" && button.title == "Browse Directory…") || button.chromeless || (button.swatch != nil && button.title == "#1E1E1E") {
                let fit=item["after"] as! [String:Any]
                check((fit["dx"] as! Int) == 0 && (fit["dy"] as! Int) == 0,"Text parity \(pane) \(button.title) has the measured native text origin")
            }
            labels.append(item)
        }
        let titleCrop=CGRect(x:615,y:30,width:600,height:50)
        let titleBox=after.brightBox(titleCrop,threshold:75),titleExpected=expected.brightBox(titleCrop,threshold:75)
        check(titleBox.count == 4 && titleExpected.count == 4 && zip(titleBox,titleExpected).allSatisfy{abs($0-$1)<=1},"Text parity \(pane) toolbar title has the measured 2× glyph origin and extent")
        let titleRecord:[String:Any]=["after":titleBox,"product":titleExpected,"realBefore":real?.brightBox(titleCrop,threshold:75) ?? []]
        var symbols:[[String:Any]]=[]
        for cell in SettingsVerification.tree(workbench.view).compactMap({$0 as? SettingsCatalogCell}) where cell.pane != nil && cell.pane?.id != "account" {
            let r=workbench.view.convert(CGRect(x:19,y:6,width:20,height:20),from:cell)
            guard r.minY>=89,r.maxY<=660 else{continue}
            let actual=after.whiteBox(r),wanted=expected.whiteBox(r)
            if actual.count == 4 && wanted.count == 4 {
                check(zip(actual,wanted).allSatisfy{abs($0-$1)<=1},"Text parity \(pane) \(cell.pane!.name) List uses the product's large SF glyph, including its optical padding")
                symbols.append(["pane":cell.pane!.id,"after":actual,"product":wanted])
            }
        }
        var switches:[[String:Any]]=[]
        for toggle in SettingsVerification.tree(workbench.form).compactMap({$0 as? SettingsButton}) where toggle.style == .toggle && !toggle.isHiddenOrHasHiddenAncestor {
            let r=workbench.view.convert(toggle.bounds,from:toggle)
            guard r.minY>60,r.maxY<655 else{continue}
            let actual=after.whiteBox(r),wanted=expected.whiteBox(r)
            if actual.count == 4 && wanted.count == 4 {
                check(zip(actual,wanted).allSatisfy{abs($0-$1)<=1},"Text parity \(pane) switch knob matches the native 21×13pt ink, within one antialias edge pixel")
                switches.append(["frame":[r.minX,r.minY,r.width,r.height],"after":actual,"product":wanted])
            }
        }
        if let selected=workbench.catalogRows.firstIndex(where:{$0.pane?.id == pane}),let cell=workbench.table.view(atColumn:0,row:selected,makeIfNecessary:false) {
            let sample=workbench.view.convert(CGPoint(x:190,y:16),from:cell)
            if sample.y>89 && sample.y<660 {let x=Int(sample.x*2),y=Int(sample.y*2)
                check(after.rgb(x,y) == [51,52,55] && after.rgb(x,y) == expected.rgb(x,y),"Text parity \(pane) selected List plate has the exact product flat colour")
            }
        }
        let canvas=after.rgb(1740,1200),ground=expected.rgb(1740,1200)
        check(canvas == [30,31,32],"Text parity \(pane) offscreen canvas matches the product's measured sRGB pixels")
        if pane == "usage"{check(after.rgb(540,1300) == expected.rgb(540,1300) && after.rgb(540,1300) == [70,71,72],"Text parity Usage history bar preserves primary's semantic opacity, including its exact flat sRGB fill")}
        if pane == "profile"{check(after.rgb(506,848) == expected.rgb(506,848) && after.rgb(506,848) == [50,51,52],"Text parity Profile empty heatmap cell preserves primary's semantic opacity")}
        records[pane]=["text":labels,"symbols":symbols,"switches":switches,"toolbar":titleRecord,"canvas":canvas,"productCanvas":ground]

        if pane == SettingsM9Verification.panes.last {
            let payload:[String:Any]=["units":"backing pixels at 2×; shift is product minus v2; positive dy moves v2 down; ink threshold excludes flat plate/background; residual is absolute channel-coverage error, not a window parity percentage","panes":records]
            if let data=try? JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:target.appendingPathComponent("text-measurements.json"))}
        }
        for cell in SettingsVerification.tree(workbench.view).compactMap({$0 as? SettingsCatalogCell}) where cell.pane != nil && cell.pane?.id != "account" {
            check(cell.label.frame.minY == 7.5,"Text parity \(pane) sidebar typographic centre is 7.5pt, independent of selection")
        }
        check(after.width == 1760 && after.height == 1320,"Text parity \(pane) measures original backing pixels")
    }
    static func geometry(_ pane:String,workbench:NativeSettingsWorkbench,scale:CGFloat,check:(Bool,String)->Void){
        check(workbench.search.frame.minX == 36 && workbench.search.frame.minY == 67 && workbench.search.drawsSearchPlaceholder,"Text parity \(pane) \(scale)× retains the searchable-field leading inset, baseline and placeholder path")
        let p=SettingsPalette(workbench.session.preferences)
        check(abs(SettingsButton.ink(p.label,opacity:1).alphaComponent-p.label.alphaComponent)<0.0001 && abs(SettingsButton.ink(p.secondary,opacity:0.4).alphaComponent-p.secondary.alphaComponent*0.4)<0.0001,"Text parity \(pane) button ink preserves intrinsic label/secondary opacity, including disabled state")
        workbench.view.effectiveAppearance.performAsCurrentDrawingAppearance{
            let c=p.canvas.usingColorSpace(.sRGB)!,s=p.searchFill.usingColorSpace(.sRGB)!
            check([c.redComponent,c.greenComponent,c.blueComponent].map{Int(($0*255).rounded())} == [30,31,32],"Text parity \(pane) dark Form has the measured cool-neutral canvas")
            check([s.redComponent,s.greenComponent,s.blueComponent].map{Int(($0*255).rounded())} == [76,78,82],"Text parity \(pane) Search has the measured plate colour")
        }
        for cell in SettingsVerification.tree(workbench.view).compactMap({$0 as? SettingsCatalogCell}) where cell.pane != nil && cell.pane?.id != "account" {
            check(cell.label.frame.minY == (7.5*scale).rounded()/scale,"Text parity \(pane) sidebar baseline snaps once at \(scale)×")
        }
        check(abs((workbench.titleLabel.textColor?.alphaComponent ?? 0)-0.255)<0.001,"Text parity \(pane) title uses the measured inactive-toolbar ink")
        if pane == "appearance" {
            let row=workbench.form.rows.first{$0.spec.visual.style == .footer}!
            check(row.detailLabel.frame.minX == 8 && row.detailLabel.frame.minY == 2 && row.height(620) == 16,"Text parity Appearance footer owns its typographic inset and intrinsic height")
            // Font APIs vary their fractional line metrics with the current macOS SDK; the drawn 2× baseline,
            // checked by capture(), is the final contract rather than the label control's empty padding.
        }
    }
    private static func load(_ url:URL)->CGImage?{guard let s=CGImageSourceCreateWithURL(url as CFURL,nil)else{return nil};return CGImageSourceCreateImageAtIndex(s,0,nil)}
    private struct Pixels {
        let width:Int,height:Int,data:[UInt8]
        init(_ image:CGImage){width=image.width;height=image.height;var bytes=[UInt8](repeating:0,count:width*height*4);bytes.withUnsafeMutableBytes{r in let c=CGContext(data:r.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))};data=bytes}
        func rgb(_ x:Int,_ y:Int)->[Int]{let i=(y*width+x)*4;return data[i..<i+3].map(Int.init)}
        func whiteBox(_ rect:CGRect)->[Int]{brightBox(CGRect(x:rect.minX*2,y:rect.minY*2,width:rect.width*2,height:rect.height*2),threshold:230)}
        func brightBox(_ rect:CGRect,threshold:UInt8)->[Int]{
            let x0=Int(rect.minX),y0=Int(rect.minY),x1=Int(rect.maxX),y1=Int(rect.maxY)
            var left=x1,top=y1,right=x0-1,bottom=y0-1
            for y in y0..<y1{for x in x0..<x1{let i=(y*width+x)*4;if min(data[i],data[i+1],data[i+2])>threshold{left=min(left,x);top=min(top,y);right=max(right,x);bottom=max(bottom,y)}}}
            return left<=right ? [left,top,right,bottom]:[]
        }
        func ink(_ x:Int,_ y:Int,_ t:Int)->Int{let i=(y*width+x)*4;return max(0,min(Int(data[i]),Int(data[i+1]),Int(data[i+2]))-t)}
        func fit(_ product:Self,_ rect:CGRect,threshold:Int)->[String:Any]{
            let x0=Int(rect.minX)+6,y0=Int(rect.minY)+8,x1=Int(rect.maxX)-6,y1=Int(rect.maxY)-8
            guard x0<x1,y0<y1,y1<height-8 else{return [:]}
            let w=x1-x0,h=y1-y0,margin=12,pw=w+2*margin
            // Expand the two small crops ONCE. Correlation then uses integer buffers, so -Onone verification
            // does not repeatedly decode image coordinates/channels millions of times per pane.
            var source=[Int](),reference=[Int]();source.reserveCapacity(w*h);reference.reserveCapacity(pw*(h+16))
            for y in y0..<y1{for x in x0..<x1{source.append(ink(x,y,threshold))}}
            for y in y0-8..<y1+8{for x in x0-margin..<x1+margin{reference.append(product.ink(x,y,threshold))}}
            var best=Int.max,bx=0,by=0,zero=0
            let inkTotal=source.reduce(0,+),count=source.filter{$0>0}.count
            var bestY=0,projection=Int.max
            let rows=(0..<h).map{y in source[y*w..<(y+1)*w].reduce(0,+)}
            for dy in -8...8 {
                var error=0
                for y in 0..<h{let offset=(y+dy+8)*pw+margin;error+=abs(rows[y]-reference[offset..<offset+w].reduce(0,+))}
                if error<projection{projection=error;bestY=dy}
            }
            for dy in max(-8,bestY-1)...min(8,bestY+1){for dx in -margin...margin {
                var error=0
                for y in 0..<h{let offset=(y+dy+8)*pw+dx+margin;for x in 0..<w{error+=abs(source[y*w+x]-reference[offset+x])}}
                if error<best || error == best && abs(dx)+abs(dy)<abs(bx)+abs(by){best=error;bx=dx;by=dy}
            }}
            for y in 0..<h{let offset=(y+8)*pw+margin;for x in 0..<w{zero+=abs(source[y*w+x]-reference[offset+x])}}
            if inkTotal == 0{bx=0;by=0}
            return ["dx":bx,"dy":by,"inkError":zero,"alignedInkError":best,"inkSum":inkTotal,"inkPixels":count]
        }
    }
}
#endif
