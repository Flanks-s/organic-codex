#if M9_SPLIT_SELFTEST && !M9_SPLIT_BASELINE
import AppKit
import QuartzCore

/// Keep the real NSView/CALayer ancestry: detaching the three placement planes hides host-space bugs.
@MainActor enum OrbMountedVerification {
    static func run(out: URL, check: (Bool, String) -> Void) throws {
        var rows: [[String: Any]] = []
        for scale: CGFloat in [1, 2] {
            let host = DockNode.Passage(frame: CGRect(x: 0, y: 0, width: 300, height: 200)); host.wantsLayer = true
            let item = DockNode.Item(MockSeed.make(now: VerificationRaster.date)[2])
            let content = item.content, glass = item.glass, orb = item.decoration
            orb.setCanvasSize(host.bounds.size)
            host.addSubview(orb.backView); host.addSubview(glass); host.addSubview(orb.frontView)
            let config = OrbConfiguration(content: .identity(.assigned(2)), drawingSize: 48, context: 0.3,
                                          badge: .init(tone: .yellow, symbol: .question), reduceMotion: true, ambient: false, backingScale: scale)
            orb.configure(config)
            for diameter: CGFloat in [32.16, 36, 48] {
                let frame = CGRect(x: 100, y: 80, width: diameter, height: diameter)
                glass.frame = frame; content.frame = CGRect(origin: .zero, size: frame.size)
                orb.setFrame(frame)
                host.layoutSubtreeIfNeeded()
                let bitmap = VerificationRaster.capture(host, scale: scale)
                if let png = NSBitmapImageRep(cgImage:bitmap).representation(using:.png,properties:[:]) {
                    try png.write(to:out.appendingPathComponent("mounted-orb-\(Int(scale))x-\(diameter).png"))
                }
                let body = orb.verificationBodyView
                let bodyCentre = body.convert(CGPoint(x: diameter/2, y: diameter/2), to: host)
                let glyph = orb.mountedGlyph
                let glyphCentre = glyph.convert(CGPoint(x: 24, y: 24), to: host.layer)
                let badge = orb.verificationBadgePlacement
                let badgeCentre = badge.convert(CGPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: host.layer)
                let expectedBadge = CGPoint(x: frame.minX + diameter*0.86, y: frame.minY + diameter*0.14)
                let nominalError = glyphCentre.y - frame.midY
                let contentLayer = content.layer!
                let expectedLocal = CGPoint(x: diameter/2, y: content.isFlipped ? diameter/2 : contentLayer.bounds.maxY-diameter/2)
                let expectedMounted = contentLayer.convert(expectedLocal, to: host.layer)
                let error = glyphCentre.y - expectedMounted.y
                rows.append(["scale": scale, "diameter": diameter, "bodyViewCentre": [bodyCentre.x,bodyCentre.y],
                             "glyphCentre": [glyphCentre.x,glyphCentre.y], "expectedCentre": [frame.midX,frame.midY],
                             "glyphErrorY": error, "nominalErrorY":nominalError,"mountedExpected":[expectedMounted.x,expectedMounted.y], "badgeCentre": [badgeCentre.x,badgeCentre.y],
                             "expectedBadge": [expectedBadge.x,expectedBadge.y],
                             "ancestry": orb.mountedPlanes.map { plane in
                                 var chain: [[String: Any]] = []; var current: CALayer? = plane
                                 while let l = current { chain.append(["class": String(describing:type(of:l)),"bounds":NSStringFromRect(l.bounds),"position":NSStringFromPoint(l.position),"anchor":NSStringFromPoint(l.anchorPoint),"flipped":l.isGeometryFlipped,"scale":l.contentsScale]);current=l.superlayer }; return chain
                             }])
                check(abs(error) < 0.001, "\(scale)x mounted orb \(diameter) glyph vertical centre")
                check(abs(badgeCentre.y-expectedBadge.y) < 0.001, "\(scale)x mounted orb \(diameter) badge vertical centre")
                check(orb.mountedGlyphInk.contentsScale == scale,"\(scale)x glyph uses requested drawing density")
                check(orb.mountedPlanes.allSatisfy { $0.bounds.width == 48 && $0.anchorPoint == CGPoint(x:0.5,y:0.5) },"\(scale)x mounted planes retain canonical bounds / centre anchor")
            }
            orb.dispose()
            let size = CGSize(width:1280,height:820), metrics = AutoLayout.Metrics.tuned(for:size)
            let all = Array(MockSeed.make(now: VerificationRaster.date).prefix(6)), store = ConversationStore(conversations:all,projects:MockSeed.projects,devices:MockSeed.devices)
            let dockHost = DockNode.Passage(frame:CGRect(origin:.zero,size:size));dockHost.wantsLayer=true
            let dock = DockNode(view:dockHost,scale:scale);var now=VerificationRaster.epoch
            dock.motionTime={now};dock.motionProfile=DisplayProfile(name:"mounted-check",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0);dock.ambient=false;dock.still=true
            let layout=AutoLayout(size:size,count:all.count,fullIndex:0,metrics:metrics)
            for (i,c) in all.enumerated() { c.satellites = [Satellite(id:"moon-\(i)",face:"S")] }
            dock.install(layout,metrics:metrics,order:all,full:[all[0].id],store:store)
            now += 1;dock.hoverFrame(at:now);dock.sample(.infinity)
            let moonItem = dock.items.values.first{ $0.role == .orb && !$0.conversation.satellites.isEmpty }!
            let frame = moonItem.glass.frame, moon = moonItem.conversation.satellites[0]
            let target=CGPoint(x:frame.midX-70,y:frame.midY-62)
            let capsule=CGRect(x:frame.minX-120,y:frame.minY-8,width:240,height:48)
            dock.projectPeek(shown:moonItem.conversation.id,open:true,capsule:capsule,rows:[moon.id:target.x],rowY:target.y)
            now += 4;dock.sample(.infinity);dockHost.layoutSubtreeIfNeeded()
            _ = VerificationRaster.capture(dockHost,scale:scale)
            let clock=moonItem.decoration.mountedSatelliteFront.sublayers![0], pose=clock.sublayers![0]
            let actual=pose.convert(CGPoint.zero,to:dockHost.layer)
            rows.append(["scale":scale,"state":"peek-row","actual":[actual.x,actual.y],"expected":[target.x,target.y],"error":[actual.x-target.x,actual.y-target.y]])
            check(abs(actual.x-target.x)<0.001 && abs(actual.y-target.y)<0.001,"\(scale)x Peek satellite world row target")
            let local = frame.offsetBy(dx:-moonItem.glass.frame.minX,dy:-moonItem.glass.frame.minY)
            mounted(moonItem.decoration, local:local, host:dockHost, scale:scale, label:"Peek wide capsule", check:check)
            dock.projectPeek(shown:nil,open:false,capsule:capsule,rows:[:],rowY:target.y)
            now += 4;dock.sample(.infinity);dockHost.layoutSubtreeIfNeeded()
            _ = VerificationRaster.capture(dockHost,scale:scale)
            let closingLocal=frame.offsetBy(dx:-moonItem.glass.frame.minX,dy:-moonItem.glass.frame.minY)
            mounted(moonItem.decoration,local:closingLocal,host:dockHost,scale:scale,label:"Peek closing M10 painted host",check:check)
            for _ in 0..<3 { now += 1.0/60;dock.sample(.infinity) }
            dockHost.layoutSubtreeIfNeeded();_ = VerificationRaster.capture(dockHost,scale:scale)
            mounted(moonItem.decoration,local:CGRect(origin:.zero,size:frame.size),host:dockHost,scale:scale,label:"Peek closed settled",check:check)
            for count in [0,1,2,3] {
                let root = DockNode.Passage(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
                let sceneDock = DockNode(view:root,scale:scale);sceneDock.ambient=false;sceneDock.still=true;sceneDock.motionTime={now};sceneDock.motionProfile=DisplayProfile(name:"mounted-check",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
                let layout:AutoLayout
                if count == 0 { layout=AutoLayout(size:size,count:all.count,fullIndex:0,metrics:metrics) }
                else {
                    let f=FocusLayout(size:size,segments:count,leftOrbs:0,rightOrbs:all.count-count,satellites:count>1,metrics:metrics)
                    var l=AutoLayout();l.focused=true;l.bars=f.segments;l.columns=f.columns;l.orbs=f.rightOrbs;l.me=f.me;layout=l
                }
                sceneDock.install(layout,metrics:metrics,order:all,full:Set(all.prefix(max(1,count)).map(\.id)),store:store)
                now += 1;sceneDock.hoverFrame(at:now);sceneDock.sample(.infinity);root.layoutSubtreeIfNeeded()
                _ = VerificationRaster.capture(root,scale:scale)
                for node in sceneDock.items.values {
                    if node.role == .orb {
                        mounted(node.decoration,local:CGRect(origin:.zero,size:node.glass.frame.size),host:root,scale:scale,label:"\(count) segments side \(node.conversation.id)",check:check)
                    }
                    if let identity=node.identity {
                        mounted(identity,local:CGRect(origin:.zero,size:node.identityFrame.size),host:root,scale:scale,label:"\(count) segments identity \(node.conversation.id)",check:check)
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]).write(to: out.appendingPathComponent("mounted-orbs.json"))
    }

    /// AppKit aligns the glass's private backing content to pixels during cacheDisplay. Use that real host's
    /// top-origin point as reference, while the report above also retains the error against the nominal glass frame.
    static func mounted(_ orb:OrbComponent,local:CGRect,host:NSView,scale:CGFloat,label:String,check:(Bool,String)->Void) {
        let content=orb.glassView.contentView!, layer=content.layer!
        let point=CGPoint(x:local.midX,y:content.isFlipped ? local.midY : layer.bounds.maxY-local.midY)
        let expected=layer.convert(point,to:host.layer)
        for (name,ink) in [("glyph",orb.mountedGlyph),("liquid",orb.mountedLiquid)] {
            let actual=ink.convert(CGPoint(x:ink.bounds.midX,y:ink.bounds.midY),to:host.layer)
            if abs(actual.x-expected.x)>0.001 || abs(actual.y-expected.y)>0.001 {
                print("mounted geometry \(label) \(name) actual=\(actual) expected=\(expected) local=\(local) glass=\(orb.glassView.frame) body=\(orb.verificationBodyView.frame)")
            }
            check(abs(actual.x-expected.x)<0.001 && abs(actual.y-expected.y)<0.001,"\(scale)x \(label) mounted \(name) centre")
        }
        check(orb.verificationBodyView.isDescendant(of:orb.glassView),"\(scale)x \(label) body retains real glass ancestry")
    }
}
#endif
