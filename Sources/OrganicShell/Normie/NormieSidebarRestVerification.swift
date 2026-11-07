#if M9_NORMIE_REST_SELFTEST
import AppKit
import ImageIO

/// Windowless component fixtures for the 2026-10-30 2×, inactive-window parity capture.
@main @MainActor enum NormieSidebarRestVerification {
    static func main() throws {
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .darkAqua)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/normie-rest")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let seeds = MockSeed.library(), store = ConversationStore(conversations: seeds, projects: MockSeed.projects, devices: MockSeed.devices)
        let model = NormieSidebarModel(store: store, current: "A"), sidebar = NormieSidebarController(model: model)
        sidebar.loadViewIfNeeded(); let root = sidebar.view as! NormieView
        root.frame = CGRect(x: 0, y: 0, width: 240, height: 820)
        root.verificationSafeAreaInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        var geometry: [[String: Any]] = [], metrics: [[String: Any]] = []
        var checks = 0, failures: [String] = []
        func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures.append(label) } }
        let referencePath = ProcessInfo.processInfo.environment["NORMIE_REST_REFERENCE"] ?? "runs/parity-m9ef-105708/normie-product.png"
        let reference = CGImageSourceCreateWithURL(URL(fileURLWithPath: referencePath) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(Pixels.init)
        check(reference != nil, "The original 2560×1640 product capture is available (NORMIE_REST_REFERENCE)")
        func compare(_ image: CGImage, rect: CGRect, at origin: CGPoint, name: String, kind: String = "white") {
            guard let reference else { return }
            let own = Pixels(image), r = rect.integral
            var a: [Double] = [], b: [Double] = []
            let low = kind == "secondary" ? 0.375 : kind == "button" ? 0.27 : 0.0
            for y in Int(r.minY)..<Int(r.maxY) {
                for x in Int(r.minX)..<Int(r.maxX) {
                    let sx = Int(origin.x) + x, sy = Int(origin.y) + y
                    let alpha = own.value(x,y,3)
                    var foreground = kind == "secondary" ? alpha / low : kind == "button" ? (alpha-low)/(1-low) : alpha
                    let channel = kind == "folder" ? 2 : 0
                    if kind == "white", own.value(x,y,0) < 0.8 { foreground = 0 }
                    if kind == "folder", own.value(x,y,2) < own.value(x,y,0)+0.12 { foreground = 0 }
                    let background: Double
                    let peak: Double
                    if kind == "button" {
                        background = reference.value(Int(origin.x)+4,Int(origin.y)+image.height/2,0); peak = 1
                    } else {
                        let samples = (Int(r.minY)..<Int(r.maxY)).map { reference.value(sx,Int(origin.y)+$0,channel) }.sorted()
                        background = samples[max(0,samples.count/10)]
                        if kind == "secondary" { peak = background + (1-background)*0.375 }
                        else if kind == "folder" { peak = reference.peak(CGRect(x:origin.x+r.minX,y:origin.y+r.minY,width:r.width,height:r.height),channel:channel) }
                        else { peak = 1 }
                    }
                    let target = (reference.value(sx,sy,channel)-background)/max(0.01,peak-background)
                    a.append(min(1,max(0,foreground))); b.append(min(1,max(0,target)))
                }
            }
            // Normalize coverage rather than comparing the offscreen material proxy with WindowServer glass.
            // Font antialiasing is included. Low residuals from the live backdrop's gradient are ignored below 3%.
            for i in a.indices { if a[i] < 0.03 { a[i] = 0 }; if b[i] < 0.03 { b[i] = 0 } }
            let boxA = pixelBox(a,width:Int(r.width)), boxB = pixelBox(b,width:Int(r.width))
            let error = zip(a,b).reduce(0.0) { $0 + abs($1.0-$1.1) } / max(1,b.reduce(0,+))
            let mismatch = zip(a,b).filter { ($0.0 > 0.5) != ($0.1 > 0.5) }.count
            let union = zip(a,b).filter { $0.0 > 0.5 || $0.1 > 0.5 }.count
            metrics.append(["name":name,"kind":kind,"coverageError":error,"binaryMismatch":Double(mismatch)/Double(max(1,union)),"v2Box":boxA,"productBox":boxB])
            check(zip(boxA,boxB).allSatisfy { abs($0-$1) <= 1 }, "\(name): ink bounds within one backing pixel")
            check(error < (name.hasSuffix(" identity") ? 0.04 : 0.012), "\(name): normalized coverage error \(error)")
        }
        func write(_ image: CGImage, _ name: String) throws {
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try data.write(to: out.appendingPathComponent(name + ".png"))
        }
        func layout(_ view: NSView, scale: CGFloat) {
            if let view = view as? NormieView { view.verificationScale = scale }
            view.needsLayout = true; view.subviews.forEach { layout($0, scale: scale) }; view.layoutSubtreeIfNeeded()
        }
        for scale: CGFloat in [1, 2] {
            layout(root, scale: scale); layout(root, scale: scale)
            try write(VerificationRaster.capture(root, scale: scale), "sidebar@\(Int(scale))x")
            check(root.window == nil && NSApp.windows.isEmpty, "\(Int(scale))× fixture never creates a window")
            for key in ["project:spw", "project:fn", "project:rs", "project:ai", "project:plt", "chat:C"] {
                let i = model.rows.firstIndex { $0.key == key }!
                let c = sidebar.table.view(atColumn: 0, row: i, makeIfNecessary: true) as! NormieSidebarCell
                let name = key.replacingOccurrences(of: ":", with: "-")
                if key == "chat:C" {
                    let symbol = Pixels(VerificationRaster.capture(c.statusMark, scale: scale))
                    var holes = 0
                    for y in Int(3*scale)..<Int(10*scale) { for x in Int(3.5*scale)..<Int(10.5*scale) { if symbol.value(x,y,3)<0.1 { holes += 1 } } }
                    check(holes>=Int(scale*scale), "\(Int(scale))× filled question symbol preserves its knockout glyph")
                }
                let bitmap = VerificationRaster.capture(c, scale: scale)
                try write(bitmap, "\(name)@\(Int(scale))x")
                let expectedX = NormieDrawing.pixel(c.isChat ? 45 : 46.5, scale: scale)
                check(c.title.frame.minX == expectedX && c.title.font == NSFont.systemFont(ofSize:13), "\(key) \(Int(scale))× title optical origin / regular 13 pt")
                check(c.frame.height == 32 && c.folder.frame == CGRect(x:26,y:8,width:16,height:16), "\(key) keeps row and icon slots")
                if scale == 2 {
                    let rows: [String:CGFloat] = ["project:spw":116,"project:fn":372,"project:rs":404,"project:ai":468,"project:plt":532,"chat:C":308]
                    let titleEnd: CGFloat = key == "project:rs" || key == "project:ai" ? 263 : 414
                    compare(bitmap, rect:CGRect(x:90,y:12,width:titleEnd-90,height:42), at:CGPoint(x:0,y:rows[key]!*2), name:key+" title")
                    if !c.isChat { compare(bitmap, rect:CGRect(x:48,y:8,width:42,height:48), at:CGPoint(x:0,y:rows[key]!*2), name:key+" folder",kind:"folder") }
                    else { compare(bitmap, rect:CGRect(x:48,y:10,width:40,height:46), at:CGPoint(x:0,y:rows[key]!*2), name:key+" identity",kind:"folder") }
                    if ["project:fn","project:plt"].contains(key) { check(c.disclosure.frame.minY == 8, "\(key) collapsed chevron optical vertical anchor") }
                    if ["project:rs","project:ai"].contains(key) {
                        check(c.deviceMark.frame == CGRect(x:216.5,y:11.5,width:7,height:7), "\(key) device dot matches text optical midline")
                        check(c.device.frame == CGRect(x:141,y:8,width:72.5,height:16), "\(key) accessory proposal / trailing anchor")
                    }
                }
                geometry.append(["scale": Int(scale), "row": key, "title": NSStringFromRect(c.title.frame), "device": NSStringFromRect(c.device.frame), "folder": NSStringFromRect(c.folder.frame)])
            }
            let card = NativeTranscriptCard()
            #if !M9_REST_BASELINE
            card.verificationScale = scale
            #endif
            card.setApprovalSource(.init(project: "Synthetic preview workspace", conversation: "Approval copy review", isOtherConversation: true))
            card.configureApproval(seeds.first { $0.id == "B" }!.approvals[0], width: 796) { _ in }
            try write(VerificationRaster.capture(card, scale: scale), "approval@\(Int(scale))x")
            let full = VerificationRaster.capture(card, scale: scale), fullPixels = Pixels(full)
            let accept = card.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Run" }!
            let plateAlpha = fullPixels.value(Int((accept.frame.minX+4)*scale),Int((accept.frame.midY)*scale),3)
            check(abs(plateAlpha-(0.08+0.27*(1-0.08))) < 0.012, "\(Int(scale))× approval button plate is painted only once")
            let sourceLabel = card.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "approval.source" || $0.stringValue.hasPrefix("Synthetic preview workspace") }!
            let sourceAlpha = sourceLabel.textColor!.usingColorSpace(.sRGB)!.alphaComponent
            check(abs(sourceAlpha-0.375)<0.001, "\(Int(scale))× inactive secondary matches the product's de-emphasis")
            let command = card.subviews.compactMap { $0 as? NSScrollView }.first!
            check(command.frame.minX == 28 && command.frame.minY == 59 && command.frame.height == 16, "\(Int(scale))× command geometry unchanged")
            let title = card.subviews.compactMap { $0 as? NSTextView }.first { $0.string == "Run this command?" }!
            check(title.frame.minX == 51 && title.frame.minY == (scale == 2 ? 13.5:14), "\(Int(scale))× title correction is backing aligned")
            for (i, child) in card.subviews.enumerated() where !(child is NSGlassEffectView) {
                let text = (child as? NSTextField)?.stringValue ?? (child as? NSTextView)?.string ?? (child as? NSButton)?.title ?? "command"
                let name = text == "Run this command?" ? "title" : text.hasPrefix("Synthetic") ? "source" : text.hasPrefix("Runs") ? "note" : text.replacingOccurrences(of: " ", with: "-")
                geometry.append(["scale": Int(scale), "part": text, "frame": NSStringFromRect(child.frame)])
                if !name.contains("/") {
                    let image = VerificationRaster.capture(child, scale: scale)
                    try write(image, "approval-\(name.isEmpty ? String(i) : name)@\(Int(scale))x")
                    if scale == 2 && ["title","source","note","Show-Conversation","Cancel","Decline","Run"].contains(name) {
                        let kind = ["source","note","Show-Conversation"].contains(name) ? "secondary" : ["Cancel","Decline","Run"].contains(name) ? "button" : "white"
                        let limit: CGFloat = name == "title" ? 270 : name == "note" ? 510 : CGFloat(image.width)
                        compare(image,rect:CGRect(x:0,y:0,width:limit,height:CGFloat(image.height)),at:CGPoint(x:724+child.frame.minX*2,y:1064+child.frame.minY*2),name:"approval "+name,kind:kind)
                    }
                }
            }
        }
        #if !M9_REST_BASELINE
        let mounted = NativeTranscriptCard()
        mounted.setApprovalSource(.init(project:"Synthetic preview workspace",conversation:"Approval copy review",isOtherConversation:true))
        mounted.verificationScale = 1
        mounted.configureApproval(seeds.first { $0.id == "B" }!.approvals[0],width:796) { _ in }
        let oldCommand = mounted.subviews.compactMap { $0 as? NSScrollView }.first!.documentView as! NSTextView
        oldCommand.setSelectedRange(NSRange(location:0,length:7))
        mounted.verificationScale = 2
        let mountedTitle = mounted.subviews.compactMap { $0 as? NSTextView }.first { $0.string == "Run this command?" }!
        check(mountedTitle.frame.minY == 13.5,"Detached 1× approval adopts 2× grid before its first window frame")
        check((mounted.subviews.compactMap { $0 as? NSScrollView }.first!.documentView as! NSTextView).selectedRange() == NSRange(location:0,length:7),"Backing-grid change preserves the selected command range")
        mounted.verificationScale = 1
        check(mounted.subviews.compactMap { $0 as? NSTextView }.first { $0.string == "Run this command?" }!.frame.minY == 14,"2× approval returns to a 1× pixel grid")
        #endif
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("geometry.json"))
        try JSONSerialization.data(withJSONObject: ["checks":checks,"failures":failures,"metrics":metrics,"reference":referencePath], options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
        print("M9 Normie rest: \(checks) checks, \(failures.count) failures")
        failures.forEach { print("FAIL: " + $0) }
        if !failures.isEmpty { exit(1) }
    }
    struct Pixels {
        let w:Int,h:Int,bytes:[UInt8]
        init(_ image:CGImage) {
            w=image.width;h=image.height
            let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            bytes=Array(UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:w*h*4))
        }
        func value(_ x:Int,_ y:Int,_ c:Int)->Double {
            guard x>=0,y>=0,x<w,y<h else{return 0}
            let alpha=Double(bytes[(y*w+x)*4+3])/255
            let raw=Double(bytes[(y*w+x)*4+c])/255
            return c==3 ? alpha : alpha>0 ? min(1,raw/alpha):0
        }
        func peak(_ r:CGRect,channel:Int)->Double {
            var peak=0.0
            for y in Int(r.minY)..<Int(r.maxY) {for x in Int(r.minX)..<Int(r.maxX) {peak=max(peak,value(x,y,channel))}}
            return peak
        }
    }
    static func pixelBox(_ a:[Double],width:Int)->[Int] {
        var x1=width,y1=Int.max,x2=0,y2=0
        for i in a.indices where a[i]>0.5 {x1=min(x1,i%width);x2=max(x2,i%width+1);y1=min(y1,i/width);y2=max(y2,i/width+1)}
        return y1 == Int.max ? []:[x1,y1,x2,y2]
    }
}
#endif
