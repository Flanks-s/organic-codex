#if ISLAND_SELFTEST
import AppKit
import QuartzCore

/// Exercise real mounted input targets without a window, haptic device dependency or window factory.
@MainActor enum SatelliteOpenerVerification {
    static func run(check:(Bool,String)->Void) {
        let canvas=IslandPlane(frame:CGRect(x:0,y:0,width:600,height:400))
        let button=IslandButton(frame:CGRect(x:100,y:100,width:24,height:24));button.drawsText=false;canvas.addSubview(button)
        let origin=button.convert(CGPoint(x:12,y:12),to:nil)
        func event(_ type:NSEvent.EventType,_ x:CGFloat=0)->NSEvent {
            NSEvent.mouseEvent(with:type,location:CGPoint(x:origin.x+x,y:origin.y),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        let opener=SatelliteOpener(satellite:.init(id:"sat",face:"^-^"),diameter:16)
        var opens:[CGPoint?]=[];opener.open={opens.append($0)}
        _=opener.begin(from:button,event:event(.leftMouseDown))
        opener.move(translation:CGSize(width:5.9,height:0));check(!opener.dragging,"SatelliteOpener waits for product's 6pt minimum")
        opener.move(translation:CGSize(width:6,height:0));check(opener.dragging,"SatelliteOpener starts at 6pt")
        check(opener.carriedLayer?.transform.m11==1.25,"SatelliteOpener magnifies the carried dot 1.25x")
        check(ReplicaContainerAudit.inspect(canvas.layer!,scenario:"satellite-opener",frame:0,time:CACurrentMediaTime()).isEmpty,"SatelliteOpener plate stays outside every replica tree")
        opener.cancel();check(opener.carriedLayer==nil && opens.isEmpty,"SatelliteOpener cancel removes paint without opening")
        _=opener.begin(from:button,event:event(.leftMouseDown));opener.released(with:event(.leftMouseUp))
        check(opens.count==1 && opens[0]==nil,"SatelliteOpener click uses cascade location")
        for distance:CGFloat in [28,29] {
            _=opener.begin(from:button,event:event(.leftMouseDown))
            opener.dragged(with:event(.leftMouseDragged,distance));opener.released(with:event(.leftMouseUp,distance))
            check(opens.count==(distance==28 ? 1:2),"SatelliteOpener opens strictly above 28pt: \(distance)")
            if let a=opener.carriedLayer?.animation(forKey:"satellite.return.position") as? CASpringAnimation {
                let w=2*Double.pi/0.3
                check(abs(a.stiffness-w*w)<0.001 && abs(a.damping-2*0.72*w)<0.001,"SatelliteOpener keeps product .30/.72 spring")
            } else {check(false,"SatelliteOpener installs release spring")}
            opener.cancel()
        }
        let header=HeaderIsland();canvas.addSubview(header)
        header.configure(.init(id:"satellite-test",title:"Satellites",columnWidth:600,signals:.init(satellites:[.init(id:"row-sat",face:"S")]),ambient:false))
        header.setExpanded(true)
        func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap{descendants($0)}}
        var drops:[CGPoint?]=[];header.actions.openSatellite={_,point in drops.append(point)}
        if let row=descendants(header).compactMap({$0 as? IslandButton}).first(where:{$0.text.hasPrefix("Sub-agent S")}) {
            let p=row.convert(CGPoint(x:row.bounds.midX,y:row.bounds.midY),to:nil)
            func rowEvent(_ type:NSEvent.EventType,_ dx:CGFloat=0)->NSEvent {
                NSEvent.mouseEvent(with:type,location:CGPoint(x:p.x+dx,y:p.y),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            row.mouseDown(with:rowEvent(.leftMouseDown));row.mouseDragged(with:rowEvent(.leftMouseDragged,40));row.mouseUp(with:rowEvent(.leftMouseUp,40))
            check(drops.count==1 && drops[0] != nil,"Island routes a mounted satellite's screen drop point")
            row.mouseDown(with:rowEvent(.leftMouseDown));row.mouseDragged(with:rowEvent(.leftMouseDragged,40));header.setPresentationActive(false);row.mouseUp(with:rowEvent(.leftMouseUp,40))
            check(drops.count==1,"Island suspension cancels a pending satellite drop")
        } else {check(false,"Island exposes its mounted satellite target")}
        header.dispose()
    }
}
#endif
