#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Native frame sampling covers owners to the right of the first row orb and both lifecycle directions.
@MainActor enum DockTideRound10Verification {
    static func run(to output:URL,check:(Bool,String)->Void)throws {
        NativeAppearance.apply(.init());ModelCatalog.models=ModelCatalog.mockModels
        var rows:[[String:Any]]=[]
        for scale in [CGFloat(1),2] {for owner in ["D","E","F"] {
            let f=DockTideRound6Verification.Fixture(scale:scale)
            let host=RootView(frame:f.dock.view.bounds)
            let window=NSWindow(contentRect:host.bounds,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=host;host.addSubview(f.dock.view)
            f.target=owner;f.start();f.command()
            var minimum=Double.infinity,reported=Double.infinity,neighbourMissing=false
            for tick in 0..<360 {
                if tick==120 {NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:window)}
                f.pump(1.0/120)
                let parts=physical(f.dock)
                for (a,ra) in parts {for (b,rb) in parts where a != b {minimum=min(minimum,TideContour.gap(ra,rb))}}
                let p=f.dock.tideLightProbe
                if p["phase"] as? String != "idle",let gap=p["minimumGap"] as? Double {reported=min(reported,gap)}
                if tick>60,tick<120 {
                    let nodes=f.p["nodes"] as? [String:[CGFloat]] ?? [:]
                    neighbourMissing = neighbourMissing || ["D","E","F"].contains {nodes[$0]==nil}
                }
                if tick%12==0 {rows.append(["case":"row-lifecycle","scale":scale,"owner":owner,"tick":tick,"minimum":minimum,"reported":reported,"probe":p,"parts":parts.map{["owner":$0.0,"rect":DockTideShape.rect($0.1)]}])}
            }
            check(minimum>=12,"120 Hz native glass keeps 12 pt through holding and resign-key retreat: \(scale)x \(owner) (\(minimum))")
            check(reported>=12,"receipt minimumGap matches the native row guarantee: \(scale)x \(owner) (\(reported))")
            check(!neighbourMissing,"every displaced row orb retains its admitted pose while the notice holds: \(scale)x \(owner)")
            check(f.p["phase"] as? String=="idle","resign-key completes the finite retreat: \(scale)x \(owner)")
            check(!window.isVisible,"native row fixture never orders its window")
            f.close();window.contentView=nil;window.close()
        }}
        for scale in [CGFloat(1),2] {
            let f=DockTideRound6Verification.Fixture(scale:scale)
            f.scene.enterFocused("A",reason:"tide-r10-face");f.scene.settle();f.scene.ends = -1;f.dock.prepareTideMaterialNow()
            f.target=f.dock.restingTargets.filter{!$0.bar}.sorted{$0.rect.minX<$1.rect.minX}.last!.id
            f.start();f.command()
            var visible=0,valid=true,minimumViewport=Double.infinity
            func orb(_ view:NSView)->NSGlassEffectView? {
                if let g=view as? NSGlassEffectView,g.identifier?.rawValue=="tide.side.orb."+f.target {return g}
                return view.subviews.compactMap(orb).first
            }
            for _ in 0..<36 {
                f.pump(1.0/120)
                if let glass=orb(f.dock.view),!glass.isHidden,glass.frame.width>31 {
                    visible+=1
                    let viewport=glass.contentView?.frame ?? .zero
                    minimumViewport=min(minimumViewport,Double(viewport.width))
                    valid = valid && abs(viewport.width-glass.bounds.width)<0.001 && abs(viewport.height-glass.bounds.height)<0.001
                }
            }
            check(visible>20 && valid,"every native Side bud frame already owns its full face viewport: \(scale)x (\(minimumViewport))")
            rows.append(["case":"side-face","scale":scale,"visibleFrames":visible,"minimumViewport":minimumViewport,"side":f.dock.tideSidePhysicalProbe]);f.close()
        }
        let water=DockTideRound6Verification.Fixture();water.start();water.emit("core/pulseProgress",["completed":3,"total":7])
        let began=water.now
        var waterRows:[[String:Any]]=[]
        for target in [0.04,0.10,0.30,0.60,1.0] {
            water.pump(max(0,target-(water.now-began)))
            waterRows.append(["t":water.now-began,"presentation":water.ink])
        }
        let early=(waterRows[0]["presentation"] as? [String:Any])?["liquidAlpha"] as? Double ?? 0
        let displayed=(waterRows[0]["presentation"] as? [String:Any])?["liquidDisplayedAlpha"] as? Double ?? 0
        let late=(waterRows.last?["presentation"] as? [String:Any])?["liquidAlpha"] as? Double ?? 0
        check(early>0.24 && early<=0.42,"reported test water starts with the board's existing .42 orb opacity")
        check(displayed>0.24,"test water remains visible before the delayed lyric entrance")
        check(abs(late-0.24)<0.005,"reported test water settles once to the board's .24 capsule opacity")
        rows.append(["case":"liquid","rows":waterRows]);water.close()
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("tide-round10.json"))
    }
    private static func physical(_ dock:DockNode)->[(String,CGRect)] {
        var parts:[(String,CGRect)]=dock.items.compactMap {id,item in
            guard !item.glass.isHidden,item.glass.layer?.isHidden != true,item.glass.alphaValue>0 else{return nil}
            return (id,item.glass.frame)
        }
        if let me=dock.meFrame {parts.append(("me",me))}
        for shape in dock.tideMaterialProbe["shapes"] as? [[String:Any]] ?? [] {
            guard let id=shape["owner"] as? String else{continue}
            for p in shape["tail"] as? [[String:Any]] ?? [] {
                if let r=p["rect"] as? [CGFloat],r.count==4 {parts.append((id,CGRect(x:r[0],y:r[1],width:r[2],height:r[3])))}
            }
        }
        return parts
    }
}
#endif
