import AppKit
import QuartzCore

@MainActor enum IslandLongTitleVerification {
    static let title="Organic Shell 性能回归与灵动岛长标题布局检查 ABC-2026 调整建议"
    static func run(to output:URL,check:(Bool,String)->Void) {
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var records=[[String:Any]]()
        for scale:CGFloat in [1,2] {for width:CGFloat in [220,280,340] {
            let c=Conversation(id:"long-title",title:title),store=ConversationStore(conversations:[])
            let r=CGRect(x:0,y:0,width:width,height:720)
            let column=ColumnNode(c,store:store,identity:.systemBlue,rect:r,full:false,scale:scale,logicalBottom:720)
            let root=IslandPlane(frame:CGRect(x:0,y:0,width:800,height:820)),header=HeaderIsland()
            root.addSubview(header);column.attachIsland(header);column.ambient=false
            var time=1000.0;header.now={time};column.configureIsland(.brief,width:width);column.placeIsland(r,shown:true)
            defer {header.dispose();withExtendedLifetime(root){}}
            @MainActor func pose(_ name:String)->CGRect {
                let rect=header.motionGlyphRect,g=header.geometry
                func labels(_ v:NSView)->[IslandLabel] { (v as? IslandLabel).map{[$0]} ?? v.subviews.flatMap{labels($0)} }
                let label=labels(header).first{$0.stringValue == title}!
                let arrow=labels(header).first{$0.stringValue == "›"}!
                let parent=label.superview!
                let extra:[String:Any]=["labelFrame":NSStringFromRect(label.frame),"labelBounds":NSStringFromRect(label.bounds),"parentFrame":NSStringFromRect(parent.frame),"parentBounds":NSStringFromRect(parent.bounds),"arrowFrame":NSStringFromRect(arrow.frame)]
                records.append(["details":extra,"stage":name,"tag":"\(Int(scale))x-\(Int(width))"])
                records.append(["tag":"\(Int(scale))x-\(Int(width))","stage":name,"glyphX":rect.minX,"glyphWidth":rect.width,
                    "capsuleX":g.capsule.minX,"capsuleWidth":g.capsule.width,"titleX":g.title.minX,"titleWidth":g.title.width,
                    "headerBoundsWidth":header.bounds.width,"headerFrameWidth":header.frame.width])
                Offscreen.write(header.snapshot(scale:scale),output.appendingPathComponent("\(name)-\(Int(scale))x-\(Int(width)).png"))
                return rect
            }
            let rest=pose("brief-rest"),capsule=header.geometry.capsule
            check(rest.minX-capsule.minX>=11.5,"M11.23 long brief retains the product 12pt padding \(scale)x \(width)")
            column.beginIslandMotion(to:.full,width:680)
            column.islandFrame(rect:r,form:0,presence:1)
            let first=pose("first-frame")
            check(abs(first.width-rest.width)<0.51,"M11.23 first frame keeps brief truncation width \(scale)x \(width)")
            check(abs(first.minX-rest.minX)<0.51,"M11.23 first frame has no horizontal title jump \(scale)x \(width): \(first.minX-rest.minX)")
            check(abs(first.midY-rest.midY)<0.51,"M11.23 first frame keeps title baseline \(scale)x \(width)")
            time+=1/120;column.islandFrame(rect:r,form:0.001,presence:1);_=pose("next-frame")
            column.islandFrame(rect:CGRect(x:0,y:0,width:680,height:720),form:1,presence:1)
            column.placeIsland(CGRect(x:0,y:0,width:680,height:720),shown:true)
            column.beginIslandMotion(to:.brief,width:width)
            column.islandFrame(rect:r,form:1,presence:1)
            column.placeIsland(r,shown:true)
            let warm=pose("warm-rest")
            check(abs(warm.minX-rest.minX)<0.001 && abs(warm.width-rest.width)<0.001,"M11.23 settled round trip restores brief padding and truncation \(scale)x \(width)")
        }}
        try? JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("poses.json"))
    }
}
