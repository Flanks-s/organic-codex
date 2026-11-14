#if M10_DOCK_SELFTEST
import AppKit
import QuartzCore

/// Three-way material proof. Geometry is the production spring; glass is explicitly a solid offscreen proxy.
/// Native component wiring/audit is checked separately below, never presented as a WindowServer capture.
@MainActor enum M10DockGaussianVerification {
    static var checks=0,failures:[String]=[],rows:[[String:Any]]=[],frameRows:[[String:Any]]=[]
    static func check(_ ok:Bool,_ name:String){checks+=1;if !ok{failures.append(name);print("FINDING: "+name)}}
    static func run(_ output:URL) throws {
        let profile=M10DockMotion.dell
        let a=CGRect(x:24,y:42,width:270,height:36),b=CGRect(x:250,y:40,width:44,height:44)
        let paths:[M10DockVerification.Path]=[
            M10DockVerification.spring("bloom",a.insetBy(dx:-8,dy:-1),a,0.22,1),
            M10DockVerification.spring("peek-bud",b,a,0.38,0.78),
            M10DockVerification.spring("peek-row",a.offsetBy(dx:0,dy:18),a,0.55,0.92),
            M10DockVerification.spring("bar-orb",a,b),
            M10DockVerification.spring("promotion",CGRect(x:120,y:100,width:88,height:88),CGRect(x:120,y:20,width:56,height:56),0.38,0.86),
            M10DockVerification.spring("expand",CGRect(x:80,y:25,width:150,height:32),CGRect(x:24,y:25,width:290,height:95)),
            M10DockVerification.spring("lobe",a,a.offsetBy(dx:12,dy:0),0.24,0.72)]
        for scale:CGFloat in [1,2] {for path in paths {
            let count=Int(ceil(path.duration*60))+1
            var sequences:[[[UInt8]]]=[],renderer:OffscreenRenderer?,maxCopies=1,maxPixels=0,maxDrawPixels=0,maxFilter=0,prep:[Double]=[],submit:[Double]=[],cpu:[[Double]]=[],auditFailures=0
            for mode in ["off","accum","gauss"] {
                let root=CALayer(),glass=CAShapeLayer(),ink=CALayer(),inkPose=CALayer(),oldPose=CALayer(),trail=ChordTrail()
                root.backgroundColor=NSColor(white:0.09,alpha:1).cgColor;glass.fillColor=NSColor(white:0.24,alpha:1).cgColor
                let carrier:CALayer=mode == "accum" ? trail.layer:CALayer()
                root.addSublayer(glass);root.addSublayer(carrier);carrier.addSublayer(inkPose);inkPose.addSublayer(ink)
                let label=NativeLabel(labelWithString:path.name == "promotion" ? "New Chat":"Organic · 下一步")
                label.font = .systemFont(ofSize:13,weight:["promotion","expand","lobe"].contains(path.name) ? .semibold:.regular);label.textColor = .white;label.frame=CGRect(x:0,y:0,width:160,height:24)
                let start=CACurrentMediaTime(),tiles=M10DockPicture.tiles(M10DockPicture.draw(label,scale:scale,plates:false)!,scale:scale)
                for tile in tiles {let l=CALayer();l.anchorPoint = .zero;l.frame=tile.rect;l.contents=tile.image;l.contentsScale=scale;ink.addSublayer(l);ReplicaContainerAudit.register(l,material:.glyph,note:"NativeLabel own draw, tight independent alpha")}
                prep.append((CACurrentMediaTime()-start)*1000)
                ink.bounds=label.bounds;ink.position=CGPoint(x:label.bounds.midX,y:label.bounds.midY)
                let r=OffscreenRenderer(size:CGSize(width:340,height:205),host:root,scale:scale);renderer=r
                let began=VerificationClock.renderOrigin
                // Full visible old/new replacement: one layer per content, complementary alpha.
                let old=CALayer();old.frame=ink.frame
                if mode == "gauss" {for tile in tiles {let l=CALayer();l.anchorPoint = .zero;l.frame=tile.rect;l.contents=tile.image;l.contentsScale=scale;old.addSublayer(l)};oldPose.addSublayer(old);root.addSublayer(oldPose)}
                let appearance = path.name == "bloom" || path.name == "peek-row"
                var config:ContentGaussianTransition.Configuration=path.name == "promotion" ? .spotlight:.system
                if path.name == "bloom" {config.duration=0.16}
                if appearance && mode != "gauss" {config.radius=0;config.hiddenScale=1}
                let submission=CACurrentMediaTime()
                let incoming=ContentGaussianTransition(content:ink,clock:SceneClock(),initiallyVisible:!appearance && mode != "gauss",configuration:config)
                let outgoing=ContentGaussianTransition(content:old,clock:SceneClock())
                let opacityPlan=ContentGaussianTransition.Plan(began:began,duration:config.duration,rate:240,
                    from:.init(radius:0,opacity:0,scale:1),to:.visible,initialVelocity:.init(radius:0,opacity:0,scale:0))
                if appearance {
                    oldPose.removeFromSuperlayer()
                    if mode == "gauss" {incoming.setVisible(true,at:began)}
                    else {
                        let timeline=Timeline(began:began,duration:config.duration,rate:240)
                        ink.opacity=1;timeline.track(ink,"opacity",timeline.map{NSNumber(value:opacityPlan.pose(at:began+$0).opacity)})?.start(at:began)
                    }
                }
                else if mode == "gauss" {ContentGaussianTransition.replace(old:outgoing,new:incoming,at:began)}
                submit.append((CACurrentMediaTime()-submission)*1000)
                var frames:[[UInt8]]=[],mutations:[Double]=[]
                for k in 0...count {
                    let t=Double(k)/60,now=path.pose(t),earlier=path.pose(max(0,t-profile.frameInterval)),mutation=CACurrentMediaTime()
                    CATransaction.begin();CATransaction.setDisableActions(true)
                    let f=M10DockMotion.frame(name:path.name,now:now,earlier:earlier,time:began+t,profile:profile,enabled:mode != "off")
                    // The same real-geometry plate path in accum and gauss. No glass filter or transform.
                    let rect=mode == "off" ? now:f.painted
                    glass.path=CGPath(roundedRect:rect,cornerWidth:min(rect.width,rect.height)/2,cornerHeight:min(rect.width,rect.height)/2,transform:nil)
                    carrier.frame=CGRect(x:0,y:0,width:340,height:205)
                    func glyphRect(_ r:CGRect)->CGRect {
                        let k=path.name == "promotion" ? r.width/56:path.name == "bloom" ? r.height/36:1
                        return CGRect(x:r.midX-80*k,y:r.midY-12*k,width:160*k,height:24*k)
                    }
                    let glyph=glyphRect(now),oldGlyph=glyphRect(earlier)
                    for pose in [inkPose,oldPose] {
                        pose.bounds=label.bounds;pose.position=CGPoint(x:now.midX,y:now.midY)
                        pose.transform=CATransform3DMakeScale(glyph.width/160,glyph.height/24,1)
                    }
                    if mode == "accum" {_=M10DockMotion.update(trail,now:glyph,earlier:oldGlyph,profile:profile,enabled:true)}
                    else {trail.reset()}
                    incoming.settle(at:began+t);outgoing.settle(at:began+t)
                    CATransaction.commit()
                    mutations.append((CACurrentMediaTime()-mutation)*1000)
                    let audit=ReplicaContainerAudit.inspect(root,scenario:path.name,frame:k,time:began+t,includeDormant:false).filter{$0.active}
                    auditFailures+=audit.count
                    maxCopies=max(maxCopies,trail.layer.instanceCount)
                    let area=tiles.reduce(0){$0+$1.image.width*$1.image.height}
                    if mode == "accum" {
                        maxPixels=max(maxPixels,area*trail.layer.instanceCount)
                        maxDrawPixels=max(maxDrawPixels,Int(Double(area*trail.layer.instanceCount)*pow(Double(max(glyph.width,oldGlyph.width)/160),2)))
                    }
                    if mode == "gauss",let plan=incoming.plan {let pose=plan.pose(at:began+t)
                        let poses=appearance ? [pose]:[pose,outgoing.pose(at:began+t)]
                        let area=poses.filter{$0.radius>0 && $0.opacity>0}.reduce(0.0){$0+160*24*Double(scale*scale)*pow(Double(glyph.width/160)*$1.scale,2)}
                        maxFilter=max(maxFilter,Int(ceil(area)))
                        if !appearance {check(abs(pose.opacity+outgoing.pose(at:began+t).opacity-1)<1e-8,path.name+" complementary replacement")}}
                    check(glass.filters == nil && CATransform3DIsIdentity(glass.transform),path.name+" glass no filter/transform")
                    let pose=incoming.pose(at:began+t)
                    frameRows.append(["object":path.name,"scale":scale,"mode":mode,"frame":k,"time":t,"stepPt":MotionStep.edge(now,earlier),"stepMM":MotionStep.edge(now,earlier)*0.27,"copies":trail.layer.instanceCount,"radiusPt":mode == "gauss" ? pose.radius:0,"opacity":appearance && mode != "gauss" ? opacityPlan.pose(at:began+t).opacity:pose.opacity,"contentScale":pose.scale,"mutationMs":mutations.last!])
                    frames.append(r.render(at:began+t))
                }
                sequences.append(frames);cpu.append(mutations.sorted())
            }
            guard let r=renderer else{continue}
            let first=sequences.allSatisfy{$0.first==sequences[0].first},last=sequences.allSatisfy{$0.last==sequences[0].last}
            check(first,path.name+" three-way first byte exact \(scale)x");check(last,path.name+" three-way last byte exact \(scale)x")
            check(auditFailures==0,path.name+" active replica audit zero \(scale)x")
            let spikes=sequences.map{M10DockVerification.spikes($0,r)}
            for (i,n) in spikes.enumerated(){check(n==0,path.name+" mode \(i) isolated spikes \(n)")}
            // Every frame, three rows (off / accum / gauss), paginated at twelve time samples per page.
            for page in stride(from:0,through:count,by:12) {
                let end=min(count+1,page+12),w=340,h=205
                let c=CGContext(data:nil,width:w*(end-page),height:h*3,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                for m in 0..<3 {for k in page..<end {c.draw(r.image(sequences[m][k]),in:CGRect(x:(k-page)*w,y:(2-m)*h,width:w,height:h))}}
                Offscreen.write(c.makeImage()!,output.appendingPathComponent("\(path.name)-three-rows-\(page)@\(Int(scale))x.png"))
            }
            rows.append(["object":path.name,"scale":scale,"frames":count+1,"firstExact":first,"lastExact":last,"spikes":spikes,"activeReplicaFindings":auditFailures,"maxCopiesAccum":maxCopies,"maxReplicatedPixels":maxPixels,"maxReplicatedDrawPixelsUpperBound":maxDrawPixels,"maxFilteredPixelsGauss":maxFilter,"prepareMs":prep,"submitDebugMs":submit,"mutationP95DebugMs":cpu.map{$0[Int(Double($0.count-1)*0.95)]},"changes":sequences.map { frames in (1..<frames.count).map {r.tileDiff(frames[$0-1],frames[$0]).value}}])
        }}
        nativeWiring();nativeComposerWiring();completionAudit();nativeEndpoints();nativeDockWiring();interruptedNames();parentFadeContract();pausedOrbGaussian()
        try JSONSerialization.data(withJSONObject:["checks":checks,"findings":failures,"objects":rows,"frames":frameRows,"boundary":"Solid glass proxy + own-draw glyph fixture. Appearance compares identical opacity timing with/without Gaussian; other cases compare old/new replacement. This is not a full native Dock movie or WindowServer / live FPS evidence."],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("gaussian.json"))
        print("M10.1 Dock/island: \(checks) checks, \(failures.count) findings")
        if !failures.isEmpty {exit(1)}
    }
    static func pausedOrbGaussian() {
        let orb=OrbComponent(id:"paused-gaussian");var c=OrbConfiguration(content:.identity(.assigned(2)),drawingSize:56)
        c.ambient=false;orb.configure(c);orb.setFrame(CGRect(x:0,y:0,width:44,height:44))
        let captures=orb.verificationHostGlyph.captures+orb.verificationHostBadge.captures,start=VerificationClock.modelOrigin
        orb.setGlyphGaussianVisible(true,at:start,initiallyVisible:false)
        var mutations:[Double]=[]
        for k in 0...6 {let begin=CACurrentMediaTime();orb.settleGlyphGaussian(at:start+Double(k)/60);mutations.append((CACurrentMediaTime()-begin)*1000)
            if k==3 {let state=orb.verificationGaussianState
                let alpha=Double(state["opacity"] as! Float)
                check(alpha>0.4 && alpha<0.7,"paused ambient Orb Gaussian progresses at 50ms; never waits frozen")
                check(state["modelSampling"] as? Bool == true,"paused ancestor uses existing host clock fallback")}}
        check(orb.verificationGaussianState["filtered"] as? Bool == false,"paused Gaussian clears filter at endpoint")
        check(captures==orb.verificationHostGlyph.captures+orb.verificationHostBadge.captures,"paused Gaussian never bakes motion textures")
        rows.append(["object":"paused-orb-gaussian","mutationP95DebugMs":mutations.sorted()[Int(Double(mutations.count-1)*0.95)],"capturesDuringMotion":0])
        orb.dispose()
    }
    static func parentFadeContract() {
        var config=ContentGaussianTransition.Configuration.system;config.fadesContent=false
        let layer=CALayer(),effect=ContentGaussianTransition(content:layer,clock:SceneClock(),initiallyVisible:false,configuration:config)
        effect.setVisible(true,at:1000)
        for k in 0...24 {check(effect.pose(at:1000+Double(k)/240).opacity==1,"parent fade owns all opacity; no double fade")}
        check(effect.pose(at:1000).radius==4 && effect.pose(at:1000.1).radius==0,"parent fade still has full Gaussian progression")
    }
    static func interruptedNames() {
        for offset in [0.003,0.017,0.037,0.071,0.097] {
            let v=HeaderIsland();v.contentZoomStyle = .gauss;v.motionExposure.enabled=true
            var time=VerificationClock.modelOrigin;v.now={time}
            v.configure(.init(id:"interrupted",title:"A changing island",ambient:false))
            v.setExpanded(true);time+=offset;v.sampleMotion(at:time)
            let before=v.contentGaussianPoses.reduce(0){$0+$1.opacity}
            v.setExpanded(false)
            let after=v.contentGaussianPoses.reduce(0){$0+$1.opacity}
            check(abs(before-after)<0.000001,"interrupted Gaussian alpha continuous \(offset): \(before)/\(after)")
            for _ in 0..<10 {time+=1/120;v.sampleMotion(at:time)
                check(abs(v.contentGaussianPoses.reduce(0){$0+$1.opacity}-1)<0.001,"interrupted Gaussian complementary alpha \(offset)")}
            v.dispose()
        }
    }
    static func nativeDockWiring() {
        let seed=Array(MockSeed.make().prefix(2)),store=ConversationStore(conversations:Array(MockSeed.make().prefix(2)))
        for mode in ["off","accum","gauss"] {
            let view=DockNode.Passage(frame:CGRect(x:0,y:0,width:1000,height:150));view.wantsLayer=true
            let dock=DockNode(view:view,scale:2);var time=VerificationClock.modelOrigin
            dock.motionTime={time};dock.ambient=false;dock.motionProfile=M10DockMotion.dell
            dock.motionEnabled=mode != "off";dock.contentZoomStyle=mode == "gauss" ? .gauss:.accum
            var layout=AutoLayout();layout.me=CGRect(x:16,y:80,width:40,height:40)
            layout.bars=[CGRect(x:70,y:80,width:650,height:40)];layout.orbs=[CGRect(x:800,y:80,width:40,height:40)]
            dock.install(layout,metrics:.init(),order:seed,full:[],store:store)
            let before=NativeViewBitmap.capture(view,scale:2)
            let began=time;dock.bloom(excluding:[])
            var sawGaussian=false
            for k in 0...90 {time=began+Double(k)/60;dock.sample(Double(k)/60)
                sawGaussian = sawGaussian || dock.items.values.contains{$0.wordGaussian.endTime>time}
                check(dock.items.values.allSatisfy{CATransform3DIsIdentity($0.glass.layer?.transform ?? CATransform3DIdentity)},"native Dock bloom real glass \(mode)")}
            dock.settleContent(full:[])
            check((mode == "gauss")==sawGaussian,"native Dock bloom selector \(mode)")
            check(before.dataProvider?.data==NativeViewBitmap.capture(view,scale:2).dataProvider?.data,"native Dock bloom rest byte exact \(mode)")
            let order=Array(seed.reversed()),start=time
            let springs=Dictionary(uniqueKeysWithValues:order.enumerated().map{index,c in (c.id,RectSpring(from:dock.items[c.id]!.target,to:index==0 ? layout.bars[0]:layout.orbs[0],response:0.42,damping:0.86))})
            dock.transition(to:layout,order:order.map(\.id),full:[],springs:springs,duration:1)
            if mode == "gauss",let layer=dock.items[order[0].id]?.barFace.layer {
                check((layer.animation(forKey:"shell.fade")?.beginTime ?? start)<=start+0.001,"incoming bar does not delay past its Gaussian")
            }
            for k in 0...90 {time=start+Double(k)/60;dock.sample(Double(k)/60)
                if mode == "gauss",k<6 {check(dock.items.values.allSatisfy{$0.wordTrail.trail.layer.instanceCount==1},"native role replacement no text replicas")}}
            dock.settleContent(full:[])
            let orb=order[1],peekStart=time
            dock.projectPeek(shown:orb.id,open:true,capsule:CGRect(x:600,y:76,width:280,height:48),rows:[:],rowY:0)
            dock.peekContent(visible:true,duration:0.12)
            for k in 0...90 {time=peekStart+Double(k)/60;dock.sample(2)}
            dock.projectPeek(shown:orb.id,open:false,capsule:.zero,rows:[:],rowY:0);dock.peekContent(visible:false,duration:0.07)
            let close=time
            for k in 0...90 {time=close+Double(k)/60;dock.sample(2)}
            dock.resetMotion()
            check(dock.items[orb.id]!.peekFace.layer!.opacity==0,"native Peek closed stays hidden after reset \(mode)")
            for item in dock.items.values {item.decoration.dispose();item.identity?.dispose()}
        }
    }
    static func nativeComposerWiring() {
        let root=NSView(frame:CGRect(x:0,y:0,width:1080,height:140));root.wantsLayer=true
        let composer=NativeComposer(frame:CGRect(x:30,y:50,width:650,height:48));composer.targetWidth=650
        root.addSubview(composer);composer.setText("A native composer · 字形");composer.layoutSubtreeIfNeeded()
        let manager=M10DockComposer(in:root),start=VerificationClock.renderOrigin
        let prepared=CACurrentMediaTime();manager.prepare(composer);let cpu=(CACurrentMediaTime()-prepared)*1000,captures=manager.captures
        let before=NativeViewBitmap.capture(root,scale:2)
        let submission=CACurrentMediaTime();manager.setGaussianVisible(composer,true,at:start,initiallyVisible:false)
        let submitMs=(CACurrentMediaTime()-submission)*1000
        var maxPixels=0,maxPlanes=0,mutations:[Double]=[]
        for k in 0...12 {
            let r=composer.frame,time=start+Double(k)/60
            let mutation=CACurrentMediaTime()
            manager.update(composer,frame:M10DockMotion.frame(name:"composer-role",now:r,earlier:r,time:time,profile:M10DockMotion.dell,enabled:true),profile:M10DockMotion.dell,enabled:true)
            mutations.append((CACurrentMediaTime()-mutation)*1000)
            let fields=manager.verificationGaussianFields
            check((fields["violations"] as? [String])?.isEmpty == true,"native composer Gaussian only plain ink")
            maxPixels=max(maxPixels,fields["filteredPixels"] as? Int ?? 0);maxPlanes=max(maxPlanes,fields["planes"] as? Int ?? 0)
            check(manager.verificationGlyphs.allSatisfy{$0.2.count<=1},"native composer role has no accumulation")
        }
        check(maxPlanes>0,"native composer Gaussian branch installed")
        check(manager.captures==captures,"native composer no motion-frame baking")
        manager.reset();check(before.dataProvider?.data==NativeViewBitmap.capture(root,scale:2).dataProvider?.data,"native composer rest handoff byte exact")
        rows.append(["object":"native-composer-role","prepareDebugMs":cpu,"addedGaussianPreparationDebugMs":manager.gaussianPreparationMs,"gaussianSubmitDebugMs":submitMs,"mutationP95DebugMs":mutations.sorted()[Int(Double(mutations.count-1)*0.95)],"maxFilteredPixels2x":maxPixels,"maxPlanes":maxPlanes,"capturesDuringMotion":manager.captures-captures])
    }
    static func completionAudit() {
        let orb=OrbComponent(id:"completion-audit")
        var c=OrbConfiguration(content:.identity(.assigned(3)),drawingSize:56,ambient:true)
        orb.configure(c);c.completions+=1;orb.configure(c)
        var findings:[ReplicaContainerAudit.Finding]=[]
        for k in 0...60 {for root in orb.verificationHostPlanes {
            findings+=ReplicaContainerAudit.inspect(root,scenario:"completion",frame:k,time:CACurrentMediaTime()+Double(k)/60,includeDormant:true)
        }}
        check(findings.isEmpty,"Orb completion active AND dormant replica audit zero: \(Set(findings.map(\.reason)))")
        orb.dispose()
    }
    static func nativeEndpoints() {
        for scale:CGFloat in [1,2] {
            let a=HeaderIsland(),b=HeaderIsland();a.contentZoomStyle = .accum;b.contentZoomStyle = .gauss
            var time=VerificationClock.renderOrigin
            for v in [a,b] {v.now={time};v.motionExposure.enabled=true;v.motionProfile=M10DockMotion.dell
                v.configure(.init(id:"endpoint",title:"Native endpoint",ambient:false,scale:scale))}
            let before=a.snapshot(scale:scale)
            check(before.dataProvider?.data==b.snapshot(scale:scale).dataProvider?.data,"native island resting style byte exact \(scale)x")
            for v in [a,b] {v.setExpanded(true)}
            time+=2;for v in [a,b] {v.sampleMotion(at:time)}
            check(a.snapshot(scale:scale).dataProvider?.data==b.snapshot(scale:scale).dataProvider?.data,"native island expanded endpoint byte exact \(scale)x")
            for v in [a,b] {v.setExpanded(false)}
            time+=2;for v in [a,b] {v.sampleMotion(at:time)}
            check(a.snapshot(scale:scale).dataProvider?.data==b.snapshot(scale:scale).dataProvider?.data,"native island closed endpoint byte exact \(scale)x")
            check(b.verificationRetiringNameCount==0,"native Gaussian retiring names cleaned without running a real event loop")
            for v in [a,b] {v.dispose()}
        }
    }
    static func nativeWiring(){
        HeaderIsland.forceMotionTexturesForVerification=true
        defer{HeaderIsland.forceMotionTexturesForVerification=false}
        let island=HeaderIsland();var time=VerificationClock.modelOrigin
        island.now={time};island.motionProfile=M10DockMotion.dell;island.motionExposure.enabled=true
        island.configure(.init(id:"gaussian",title:"A native island",ambient:false))
        let captures=island.motionGlyphMaterial.captureCount
        let plan=island.beginPromotion(seedCenterY:160)!
        for k in 0...72 {let t=Double(k)/60;time+=1/60
            if t>=plan.titleDelay {island.revealPromotionTitle()}
            let pose=plan.motionSample(elapsed:t);island.placeMotion(pose.geometry,fontScale:pose.fontScale)
            check(!island.glassHasExposureTransform,"native promotion real glass")
            if M10IslandZoom.selected == .gauss {check(island.motionGlyphMaterial.sample.count==1,"native Gaussian promotion no replicas")}
        }
        if island.contentZoomStyle == .gauss {check(island.motionGlyphMaterial.captureCount==captures,"native Gaussian promotion no motion-frame glyph baking")}
        island.endPromotion();island.setExpanded(true)
        for k in 0...72 {time+=1/60;island.sampleMotion(at:time);check(!island.glassHasExposureTransform,"native expand real glass \(k)")}
        island.dispose()
    }
}
#endif
