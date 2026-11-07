#if SETTINGS_SELFTEST
import AppKit
import ImageIO

/// MBP 2× references from runs/parity-settings-m9c-010322, read only. The integer/half-point landmarks below
/// are measured plate edges, not values copied from the implementation. Product sources: SettingsWindow.swift
/// 174–211 (List reveal), SettingsComponents.swift 156–201/271–294/445–466 (popup/cards/key chips),
/// SettingsPanesPersonal.swift, SettingsPanesData.swift and SettingsPanesIntegrations.swift (grouped Forms).
@MainActor enum SettingsM9CVerification {
    private static var records:[String:Any]=[:]
    private static let groups:[String:[(CGFloat,CGFloat)]]=[
        "general":[(72,170),(298,85),(439,208.5)],
        "notifications":[(72,40),(168,168),(392,111.5)],
        "import":[(98,77.5),(231.5,105)],
        "profile":[(72,179),(261,62),(379,143),(578,94)],
        "appearance":[(72,123),(251,97),(358,223)],
        "organic":[(98,108.5),(262.5,105),(423.5,52)],
        "archived":[(72,44),(172,52),(280,52),(388,52)],
        "storage":[(72,41.5),(173.5,100),(283.5,163)],
        "configuration":[(72,41.5),(173.5,210),(439.5,126),(621.5,36.5)],
        "personalization":[(72,41.5),(169.5,115),(340.5,36),(432.5,36)],
        "shortcuts":[(72,86.5),(214.5,201.5),(472,161)],
        "usage":[(72,44),(172,46),(274,203),(533,170)],
        "data":[(72,158),(240,122)],
        "plugins":[(72,44),(178.5,423)],
        "computer":[(98,105),(259,146),(461,187)],
        "appshots":[(72,170),(252,121)],
        "browser":[(72,46),(178,257.5),(491.5,183)],
        "connections":[(72,44),(176.5,142.5),(375,36.5)]
    ]
    static func capture(_ pane:String,workbench:NativeSettingsWorkbench,image:CGImage,target:URL,check:(Bool,String)->Void){
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["SETTINGS_M9C_REFERENCE"] ?? FileManager.default.currentDirectoryPath+"/runs/parity-settings-m9c2-044931")
        let referenceRoot=pane == "appearance" ? URL(fileURLWithPath:ProcessInfo.processInfo.environment["SETTINGS_TEXT_APPEARANCE_REFERENCE"] ?? root.path):root
        guard let product=load(referenceRoot.appendingPathComponent("settings-"+pane+"-product.png")) else{check(false,"M9C missing MBP 2× reference "+pane);return}
        check(product.width == 1760 && product.height == 1320,"M9C \(pane) uses the original 2× reference, without resampling")
        SettingsTextParityVerification.capture(pane,workbench:workbench,image:image,product:product,reference:referenceRoot,target:target,check:check)
        let measured=workbench.form.groupFrames.values.sorted{$0.minY<$1.minY}.map{workbench.view.convert($0,from:workbench.form)}
        if let expected=groups[pane] {
            check(measured.count>=expected.count,"M9C \(pane) retains its measured groups")
            for (i,e) in expected.enumerated() where measured.indices.contains(i){let r=measured[i]
                check(abs(r.minY-e.0)<=0.5 && abs(r.height-e.1)<=0.5,"M9C \(pane) group \(i+1) measured MBP edge y=\(e.0), h=\(e.1): \(r)")
            }
        }
        let title=workbench.view.convert(workbench.titleLabel.bounds,from:workbench.titleLabel),nav=workbench.view.convert(workbench.navigationPlate.bounds,from:workbench.navigationPlate)
        check(nav.minX == 227 && title.minX == 310.5 && title.minY == 16.5,"M9C \(pane) real-toolbar and windowless shared geometry")
        check(workbench.navigationPlate.superview === workbench.toolbarContent && workbench.titleLabel.superview === workbench.toolbarContent,"M9C \(pane) title cannot negotiate a separate NSToolbar-item margin")
        let expectedOffset:[String:CGFloat]=["plugins":0,"computer":29,"appshots":61,"browser":93,"connections":157]
        if let expected=expectedOffset[pane]{check(abs(workbench.sidebarScroll.contentView.bounds.minY-expected)<=0.5,"M9C \(pane) direct-open sidebar offset \(expected), actual \(workbench.sidebarScroll.contentView.bounds.minY)")}
        check(workbench.sidebarScroll.frame.minY == 89 && workbench.table.frame.minY == 9,"M9C \(pane) List clips below Search with its independent initial inset")
        if let index=workbench.catalogRows.firstIndex(where:{$0.pane?.id == pane}),let cell=workbench.table.view(atColumn:0,row:index,makeIfNecessary:true) as? SettingsCatalogCell{
            check(cell.label.frame.minX == 44 && cell.label.textColor?.usingColorSpace(.sRGB)?.alphaComponent == 1,"M9C \(pane) sidebar labels keep the product's leading inset and vibrant primary even when mounted after render")
            cell.applyPalette(SettingsPalette(workbench.session.preferences));check(cell.label.usesPalette == false && cell.subtitle.usesPalette == false,"M9C \(pane) ordinary label painting cannot replace sidebar-specific primary/secondary")
        }
        if pane == "browser",let i=workbench.catalogRows.firstIndex(where:{$0.pane?.id == "general"}){
            let row=workbench.table.rect(ofRow:i),icon=workbench.view.convert(CGRect(x:19,y:row.minY+6,width:20,height:20),from:workbench.table)
            check(icon.minY>=89 && icon.maxY<=660,"M9C Browser reveal retains the entire General icon, not merely its row centre")
            if let plugins=workbench.catalogRows.firstIndex(where:{$0.pane?.id == "plugins"}){let iconY=workbench.view.convert(CGPoint(x:19,y:workbench.table.rect(ofRow:plugins).minY+6),from:workbench.table).y;check(iconY == 538,"M9C the 32pt Integrations header places its first icon at the measured 538pt, not 540pt")}
        }
        if pane == "appearance"{
            check(workbench.form.rows.first{$0.spec.id == "look.mode"}?.control?.bounds.width == 226,"M9C Appearance modes reserve 3×66pt cards plus 2×14pt gaps, without the extra 4pt at the trailing edge")
            let slider=workbench.form.rows.first{$0.spec.id == "look.text"}?.control as? SettingsTextSlider
            check(slider?.bounds.width == 194.5 && slider?.trackRect.width == 160 && SettingsTextSlider.stops.count == 5,"M9C text slider matches the 160pt product track and exactly five supported ticks")
            let color=workbench.form.rows.first{$0.spec.id == "color.background"}?.control as? SettingsButton
            check(color?.bounds.height == 22 && color?.swatchFromTheme == true,"M9C inherited colour well uses its 22pt secondary-label appearance")
        }
        let bodyButtons=workbench.form.rows.flatMap{([$0.control].compactMap{$0})+$0.actionControls}.compactMap{$0 as? SettingsButton}.filter{$0.formBodyButton}
        check(bodyButtons.allSatisfy{$0.bounds.height == 24},"M9C \(pane) body buttons keep the measured 24pt face, independently of small header controls")
        let actual=Pixels(image),reference=Pixels(product)
        // Probe actual drawn separators, not just their frame model. Product's Form uses 1 pt, i.e. TWO pixels here.
        var separatorCount=0
        let rows=workbench.form.rows
        for i in rows.indices where i+1<rows.count && !rows[i].spec.visual.group.isEmpty && rows[i].spec.visual.group == rows[i+1].spec.visual.group {
            let row=rows[i],r=workbench.view.convert(row.bounds,from:row),y=Int((r.maxY*2).rounded())
            guard y>=104 && y+2<1320 else{continue};let x=Int((r.minX+row.bounds.width/2)*2)
            // Card/plot contents may cross this column but the separator's two pixels must remain identical.
            check(actual.rgb(x,y) == actual.rgb(x,y+1),"M9C \(pane) separator \(i) draws both backing pixels equally")
            separatorCount+=1
        }
        if pane == "scheduler"{let left=actual.rgb(520,684);check(left.max()!<70,"M9C empty pane has no duplicate leading gear")}
        var item:[String:Any]=["after":actual.difference(reference),"sidebarAfter":actual.difference(reference,minX:20,minY:180,maxX:420,maxY:1300),"toolbarAfter":actual.difference(reference,minX:440,minY:0,maxX:1720,maxY:104),"sidebarOffset":workbench.sidebarScroll.contentView.bounds.minY,"groups":measured.map{[$0.minY,$0.height]},"separatorCount":separatorCount]
        if let path=ProcessInfo.processInfo.environment["SETTINGS_M9C_BASELINE"],let before=load(URL(fileURLWithPath:path).appendingPathComponent("settings-"+pane+"-v2@2x.png")),before.width == 1760,before.height == 1320 {let pixels=Pixels(before);item["before"]=pixels.difference(reference);item["sidebarBefore"]=pixels.difference(reference,minX:20,minY:180,maxX:420,maxY:1300);item["toolbarBefore"]=pixels.difference(reference,minX:440,minY:0,maxX:1720,maxY:104)}
        records[pane]=item
        write(pair(image,product),target.appendingPathComponent("settings-"+pane+"-m9c-comparison@2x.png"))
        SettingsVerification.images+=1
        if pane == SettingsM9Verification.panes.last {
            check(NativeSettingsWorkbench.catalogOffset(current:0,row:CGRect(x:0,y:632,width:220,height:32),viewport:571,document:728,scale:2) == 93,"M9C minimal reveal excludes NSTableView breathing margin")
            check(NativeSettingsWorkbench.catalogOffset(current:93,row:CGRect(x:0,y:79,width:220,height:32),viewport:571,document:728,scale:2) == 79,"M9C reveal also scrolls upward")
            check(NativeSettingsWorkbench.catalogOffset(current:55,row:CGRect(x:0,y:100,width:220,height:32),viewport:571,document:728,scale:2) == 55,"M9C selecting a visible item preserves the reading position")
            let payload:[String:Any]=["reference":root.path,"appearanceReference":ProcessInfo.processInfo.environment["SETTINGS_TEXT_APPEARANCE_REFERENCE"] ?? root.path,"viewportPoints":[880,660],"scale":2,"metric":"Mean absolute sRGB channel error (%) in content x≥220pt,y≥52pt. Same offscreen path before/after, compared to one fixed MBP reference. Excludes toolbar/sidebar. Does not predict WindowServer glass or real-window percentage.","panes":records]
            if let data=try? JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:target.appendingPathComponent("m9c-measurements.json"))}
        }
    }
    private struct Pixels {
        let width:Int,height:Int,data:[UInt8]
        init(_ image:CGImage){width=image.width;height=image.height;var bytes=[UInt8](repeating:0,count:width*height*4);bytes.withUnsafeMutableBytes{raw in let c=CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))};data=bytes}
        func rgb(_ x:Int,_ y:Int)->[UInt8]{let i=(y*width+x)*4;return Array(data[i..<i+3])}
        func difference(_ other:Self,minX:Int=440,minY:Int=104,maxX:Int?=nil,maxY:Int?=nil)->Double{guard width == other.width && height == other.height else{return -1};let endX=maxX ?? width,endY=maxY ?? height;var sum:UInt64=0;for y in minY..<endY{for x in minX..<endX{let i=(y*width+x)*4;for c in 0..<3{sum+=UInt64(abs(Int(data[i+c])-Int(other.data[i+c])))}}};return Double(sum)/Double((endX-minX)*(endY-minY)*3*255)*100}
    }
    private static func load(_ url:URL)->CGImage?{guard let source=CGImageSourceCreateWithURL(url as CFURL,nil)else{return nil};return CGImageSourceCreateImageAtIndex(source,0,nil)}
    private static func write(_ image:CGImage,_ url:URL){try? NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:url)}
    private static func pair(_ a:CGImage,_ b:CGImage)->CGImage{let c=CGContext(data:nil,width:3520,height:1320,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(a,in:CGRect(x:0,y:0,width:1760,height:1320));c.draw(b,in:CGRect(x:1760,y:0,width:1760,height:1320));return c.makeImage()!}
}
#endif
