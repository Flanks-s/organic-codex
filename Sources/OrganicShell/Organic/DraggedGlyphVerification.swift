#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

extension M10DockVerification {
    /// Compare the actual prepared ink to its native source in the same flipped render-server plane.
    /// An asymmetric symbol must match the upright source better than a vertically reflected source.
    static func glyphOrientation(_ source:CALayer,ink:OrbHostInk,scale:CGFloat,name:String,output:URL)->[String:Any] {
        let size=source.bounds.size,root=CALayer(),renderer=OffscreenRenderer(size:size,host:root,scale:scale)
        root.backgroundColor=NSColor(white:0.5,alpha:1).cgColor
        let parent=source.superlayer,index=parent?.sublayers?.firstIndex(of:source) ?? 0
        let position=source.position,hidden=source.isHidden,opacity=source.opacity
        CATransaction.begin();CATransaction.setDisableActions(true)
        source.removeFromSuperlayer();root.addSublayer(source)
        source.position=CGPoint(x:size.width/2,y:size.height/2);source.isHidden=false;source.opacity=1
        CATransaction.commit()
        let native=renderer.render(at:100_000_000)
        CATransaction.begin();CATransaction.setDisableActions(true)
        source.removeFromSuperlayer();parent?.insertSublayer(source,at:UInt32(index))
        source.position=position;source.isHidden=hidden;source.opacity=opacity
        let bakedRoot=CALayer(),bakedRenderer=OffscreenRenderer(size:size,host:bakedRoot,scale:scale)
        bakedRoot.backgroundColor=root.backgroundColor
        let bitmap=CALayer();bitmap.contents=ink.bitmap.contents;bitmap.contentsScale=ink.bitmap.contentsScale
        bitmap.frame=ink.verificationRect;bitmap.transform=ink.bitmap.transform;bakedRoot.addSublayer(bitmap)
        CATransaction.commit()
        let baked=bakedRenderer.render(at:100_000_001),w=renderer.w,h=renderer.h
        var upright=0.0,inverted=0.0,energy=0.0
        for y in 0..<h {for x in 0..<w {
            for channel in 0..<3 {
                let i=(y*w+x)*4+channel,j=((h-1-y)*w+x)*4+channel
                upright+=abs(Double(native[i])-Double(baked[i]));inverted+=abs(Double(native[j])-Double(baked[i]));energy+=abs(Double(native[i])-128)
            }
        }}
        check(energy>500,"\(name) has readable native ink")
        check(upright<inverted*0.5,"\(name) prepared ink upright: \(upright/max(1,energy)) vs reflected \(inverted/max(1,energy))")
        renderer.write(native,output.appendingPathComponent(name+"-native.png"));renderer.write(baked,output.appendingPathComponent(name+"-texture.png"))
        return ["name":name,"uprightError":upright/max(1,energy),"reflectedError":inverted/max(1,energy)]
    }
    static func draggedGlyphs(output:URL) throws {
        let firstCheck=checks,firstFinding=findings.count
        var rows=[[String:Any]]()
        for scale:CGFloat in [1,2] {for symbol in [0,1,3] {
            let orb=OrbComponent(id:"glyph-probe")
            orb.configure(OrbConfiguration(content:.identity(.assigned(symbol)),drawingSize:48,
                badge:.init(tone:.yellow,symbol:.count(12)),ambient:false,backingScale:scale))
            orb.preparePointerInk()
            let r=CGRect(x:100,y:100,width:48,height:48),next=r.offsetBy(dx:24,dy:0)
            orb.setFrame(next);orb.exposeGlyphs(now:next,earlier:r,profile:profile)
            rows.append(glyphOrientation(orb.verificationGlyphLayer,ink:orb.verificationHostGlyph,scale:scale,name:"symbol-\(symbol)-\(Int(scale))x",output:output))
            rows.append(glyphOrientation(orb.verificationBadgeLayer.sublayers!.first!,ink:orb.verificationHostBadge,scale:scale,name:"badge-\(symbol)-\(Int(scale))x",output:output))
            orb.dispose()
        }}
        for scale:CGFloat in [1,2] {for origin in ["header-full","header-brief","header-focused","header-split","bar-full","bar-brief","dock-orb","dock-identity"] {
            let f=HeaderFixture(scale:scale,members:["A","B","C","D","E","F"]);defer{f.dispose()}
            if origin.contains("focused") || origin.contains("split") || origin == "dock-identity" {
                f.scene.enterFocused("A",reason:"glyph-fixture");f.settle()
                if !origin.contains("focused") {f.scene.graft("B",at:1,reason:"glyph-fixture");f.settle()}
            }
            let top=origin.hasPrefix("header"),side=origin.contains("brief") || origin.contains("split") || origin == "dock-identity"
            // D is Mars: Earth's vertically symmetric cross cannot detect a reflected texture.
            let id=origin == "dock-orb" ? "D":f.scene.columns[side ? 1:0].conversation.id
            let item=f.scene.dock.items[id]!,island=f.scene.columns.first{$0.conversation.id==id}?.island
            let down=top ? f.point(island!):(origin == "dock-identity" ? CGPoint(x:item.identityFrame.midX,y:item.identityFrame.midY):CGPoint(x:item.glass.frame.midX,y:origin == "dock-orb" ? item.glass.frame.midY:item.glass.frame.minY))
            func event(_ type:NSEvent.EventType,_ p:CGPoint)->NSEvent {
                NSEvent.mouseEvent(with:type,location:f.scene.dock.view.convert(p,to:nil),modifierFlags:[],timestamp:f.time,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            f.scene.pressedButtons={1}
            if top {island!.planetButton.mouseDown(with:event(.leftMouseDown,down))}
            else {check(f.scene.pointerDown(down),"\(origin) actual Dock hit target")}
            var p=down
            func move(_ dx:CGFloat) {
                p.x+=dx
                if top {island!.planetButton.mouseDragged(with:event(.leftMouseDragged,p))} else {f.scene.pointerDragged(p)}
                f.tick()
            }
            move(8);check(f.scene.isDragging,"\(origin) actual held entrance")
            if top {
                rows.append(["origin":origin,"scale":scale,"sourcePlanes":
                    [island!.orb.glassView,island!.orb.backView,island!.orb.frontView].map{
                        ["viewHidden":$0.isHidden,"layerHidden":$0.layer?.isHidden ?? false,
                         "animations":$0.layer?.animationKeys() ?? []] as [String:Any]
                    }])
            }
            for _ in 0..<65 {f.tick()}
            let orb=origin == "dock-identity" ? item.identity!:item.decoration
            check(orb.verificationHostGlyph.bitmap.animation(forKey:"contents") == nil &&
                  orb.verificationHostBadge.bitmap.animation(forKey:"contents") == nil,
                  "\(origin) pickup never crossfades old and corrected ink textures")
            let captures=orb.verificationHostGlyph.captures+orb.verificationHostBadge.captures
            var exposed=0,quiet=0
            let movements:[CGFloat]=Array(repeating:1,count:12)+[5,12,24,-24,-12,-5,3,5,3,5,0,0]+Array(repeating:0,count:6)
            for (frame,dx) in movements.enumerated() {
                move(dx)
                let ink=orb.verificationHostGlyph,badge=orb.verificationHostBadge,active=ink.sample.count>1
                check(orb.verificationGlyphLayer.isHidden == active && ink.carrier.isHidden != active,"\(origin) exactly one glyph paint owner at frame \(frame)")
                check(orb.verificationBadgeLayer.sublayers!.first!.isHidden == (badge.sample.count>1),"\(origin) badge hands back with its exposure gate")
                check(ink.trail.layer.instanceTransform.m11>0 && ink.trail.layer.instanceTransform.m22>0,"\(origin) exposure copies remain upright")
                if frame<12 || frame>=movements.count-5 {
                    quiet+=1;check(!active && ink.trail.layer.instanceCount==1,"\(origin) low-speed/rest uses one native glyph, no duplicate")
                }
                if active {exposed+=1}
            }
            check(exposed>0 && quiet==17,"\(origin) covers low speed, physical gate crossings, high speed and rest")
            check(captures==orb.verificationHostGlyph.captures+orb.verificationHostBadge.captures,"\(origin) movement never rebakes glyphs")
            rows.append(glyphOrientation(orb.verificationGlyphLayer,ink:orb.verificationHostGlyph,scale:scale,name:"\(origin)-\(Int(scale))x",output:output))
            if orb.verificationConfiguration?.badge != nil {
                rows.append(glyphOrientation(orb.verificationBadgeLayer.sublayers!.first!,ink:orb.verificationHostBadge,scale:scale,name:"\(origin)-badge-\(Int(scale))x",output:output))
            }
            rows.append(["origin":origin,"scale":scale,"frames":movements.count,"exposureFrames":exposed,"quietFrames":quiet])
            f.scene.cancelDrag();f.settle()
        }}
        for scale:CGFloat in [1,2] {
            let f=HeaderFixture(scale:scale,members:["A","B","C","D"]);defer{f.dispose()}
            f.scene.enterFocused("A",reason:"glyph-graft-fixture");f.settle()
            let item=f.scene.dock.items["D"]!,r=item.glass.frame,down=CGPoint(x:r.midX,y:r.midY)
            f.scene.pressedButtons={1}
            check(item.identity == nil && f.scene.pointerDown(down),"graft starts at a real Dock orb without an identity")
            f.scene.pointerDragged(CGPoint(x:down.x+8,y:down.y));f.tick()
            let cap=f.scene.dock.capsule!,drop=CGPoint(x:cap.midX,y:cap.midY)
            f.scene.pointerDragged(drop);f.tick();_=f.scene.pointerUp(drop);f.settle()
            check(f.scene.scheme.split.contains("D") && item.identity != nil,"graft creates the member's new identity orb")
            if let orb=item.identity {
                rows.append(glyphOrientation(orb.verificationGlyphLayer,ink:orb.verificationHostGlyph,scale:scale,name:"grafted-new-identity-\(Int(scale))x",output:output))
            }
        }
        check(NSApp.windows.allSatisfy{!$0.isVisible},"glyph verification opens no visible window")
        try JSONSerialization.data(withJSONObject:["checks":checks-firstCheck,"findings":Array(findings.dropFirst(firstFinding)),"samples":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("dragged-glyphs.json"))
    }
}
#endif
