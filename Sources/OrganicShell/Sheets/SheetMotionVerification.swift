#if M10_F_SELFTEST || SHEETS_M101_SELFTEST
import AppKit
import ImageIO
import QuartzCore

/// Native ink textures + the production motion/exposure functions, rendered by CARenderer at 60 Hz.
/// Glass is explicitly a rounded proxy: no WindowServer refraction is claimed by these images.
#if M10_F_SELFTEST
@main
#endif
@MainActor enum SheetM10FVerification {
    struct Fixture {
        let name:String,duration:Double,kind:String
        let pose:(Double)->CGRect
    }
    static var checks=0,findings:[String]=[]
    static let profile=DisplayProfile(name:"Dell 60 Hz",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
    static func check(_ value:Bool,_ message:String) { checks+=1;if !value { findings.append(message);print("FINDING: "+message) } }
    static func main() throws {
        _=NSApplication.shared
        let out=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "runs/m10-draft-subagent")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let fixtures=makeFixtures();var summaries:[[String:Any]]=[]
        var csv="object,frame,time,stepPt,stepMM,gate,copies,coveragePt,maxSpacingPt,stretchPt,processedFootprintStepPt\n"
        for fixture in fixtures {
            let size=CGSize(width:960,height:520),base=fixture.pose(fixture.duration)
            let hosts=[CALayer(),CALayer()],inks=[M10FInkPlane(frame:CGRect(origin:.zero,size:base.size)),M10FInkPlane(frame:CGRect(origin:.zero,size:base.size))]
            let solids=[CALayer(),CALayer()]
            let image=texture(size:base.size,name:fixture.name)
            for k in 0...1 {
                hosts[k].backgroundColor=NSColor(srgbRed:0.09,green:0.105,blue:0.10,alpha:1).cgColor
                solids[k].backgroundColor=NSColor(white:0.21,alpha:1).cgColor;solids[k].borderColor=NSColor(white:0.43,alpha:1).cgColor;solids[k].borderWidth=0.5
                hosts[k].addSublayer(solids[k]);hosts[k].addSublayer(inks[k].trail.layer)
                let ink=CALayer();ink.anchorPoint = .zero;if let b=SheetInkCapture.trim(image,scale:1) {ink.frame=b.rect;ink.contents=b.image};ink.contentsScale=1;ReplicaContainerAudit.register(ink,material:.glyph,note:"Transparent, alpha-tight fixture ink; native plate matte removed");inks[k].trail.layer.addSublayer(ink)
            }
            let renderers=(0...1).map{OffscreenRenderer(size:size,host:hosts[$0])}
            var frames=[[[UInt8]](),[[UInt8]]()],maxStep:CGFloat=0,maxLength:CGFloat=0,maxSpacing:CGFloat=0,maxStretch:CGFloat=0,maxCopies=1,active=0,mid=0,low=0
            var previousFootprint: CGRect?,maxFootprintStep:CGFloat=0
            let total=Int(ceil((fixture.duration+0.15)/profile.frameInterval))
            for i in 0...total {
                let t=Double(i)*profile.frameInterval,a=fixture.pose(t),b=fixture.pose(max(0,t-profile.frameInterval))
                let step=MotionStep.edge(a,b),expected=smoothstep(1.08,2.7,Double(step)*profile.mmPerPoint)
                maxStep=max(maxStep,step)
                CATransaction.begin();CATransaction.setDisableActions(true)
                for k in 0...1 {
                    let ink=inks[k],factor=a.width/base.width
                    ink.trail.layer.anchorPoint=CGPoint(x:0.5,y:0.5)
                    ink.trail.layer.bounds=CGRect(origin:.zero,size:base.size);ink.trail.layer.position=CGPoint(x:a.midX,y:a.midY)
                    ink.trail.layer.transform=CATransform3DMakeScale(factor,factor,1)
                    ink.expose(now:a,earlier:b,profile:profile,enabled:k==1)
                    let r=fixture.kind == "glyph" || k==0 ? a:M10FExposure.stretch(now:a,earlier:b,profile:profile)
                    solids[k].isHidden=fixture.kind == "glyph"
                    solids[k].frame=r;solids[k].cornerRadius=fixture.kind == "sheet" ? 24*factor:min(r.width,r.height)/2
                    let opacity:Float
                    if fixture.name.hasPrefix("subagents") { opacity=SheetBudMotion(rect:base,upward:false).pose(t).opacity }
                    else if fixture.name.hasPrefix("toast-") && fixture.name != "toast-dismiss" { opacity=Float(min(1,max(0,OverlayCurve(0.3,1.15,0.5,1,0.35).value(at:t/0.35)))) }
                    else if fixture.name=="surface-fade" { opacity=Float(OverlayMotion.ease(0.16).value(at:t/0.16)) }
                    else if fixture.name=="surface-fade-out" || fixture.name=="toast-dismiss" { opacity=Float(1-OverlayMotion.ease(fixture.duration).value(at:t/fixture.duration)) }
                    else { opacity=1 }
                    solids[k].opacity=opacity;ink.trail.layer.opacity=opacity
                }
                CATransaction.commit()
                let s=inks[1].exposureSample
                check(abs(Double(s.gate)-expected)<1e-7,fixture.name+" gate frame \(i)")
                check(expected==0 ? s.count==1:s.count>1,fixture.name+" threshold frame \(i)")
                var spacing:CGFloat=0,coverage:CGFloat=0
                if s.count>1 {
                    var previous=CGRect(origin:.zero,size:base.size),last=previous
                    let transform=CATransform3DGetAffineTransform(inks[1].trail.layer.instanceTransform)
                    for _ in 1..<s.count { let next=previous.applying(transform);spacing=max(spacing,MotionStep.edge(next,previous)*a.width/base.width);previous=next;last=next }
                    coverage=MotionStep.edge(CGRect(origin:.zero,size:base.size),last)*a.width/base.width
                    check(spacing<=1.5+1e-4,fixture.name+" spacing frame \(i): \(spacing)")
                    check(coverage+1e-5>=step*s.gate,fixture.name+" continuity frame \(i): \(coverage) / \(step*s.gate)")
                    active+=1
                }
                if expected>0 && expected<1 { mid+=1 };if expected==0 { low+=1 }
                let stretch=max(0,solids[1].frame.width-a.width,solids[1].frame.height-a.height)
                let oldRect=CGRect(x:a.minX+(b.minX-a.minX)*s.gate,y:a.minY+(b.minY-a.minY)*s.gate,width:a.width+(b.width-a.width)*s.gate,height:a.height+(b.height-a.height)*s.gate)
                let footprint=a.union(oldRect).union(fixture.kind == "glyph" ? a:solids[1].frame)
                let footprintStep=previousFootprint.map{MotionStep.edge(footprint,$0)} ?? 0
                previousFootprint=footprint;maxFootprintStep=max(maxFootprintStep,footprintStep)
                maxLength=max(maxLength,coverage);maxSpacing=max(maxSpacing,spacing);maxStretch=max(maxStretch,stretch);maxCopies=max(maxCopies,s.count)
                csv+="\(fixture.name),\(i),\(t),\(step),\(Double(step)*profile.mmPerPoint),\(s.gate),\(s.count),\(coverage),\(spacing),\(stretch),\(footprintStep)\n"
                for k in 0...1 { frames[k].append(renderers[k].render(at:1000+t)) }
            }
            check(frames[0].first==frames[1].first,fixture.name+" first pixels 0")
            check(frames[0].last==frames[1].last,fixture.name+" last pixels 0")
            let off=spikes(frames[0],renderers[0]),on=spikes(frames[1],renderers[1])
            check(off==0 && on==0,fixture.name+" spikes off/on \(off)/\(on)")
            let visible=frames[0].indices.filter { let r=fixture.pose(Double($0)/60);return r.minX>=0 && r.maxX<=size.width }
            let peak=(visible.isEmpty ? Array(frames[0].indices):visible).max { i,j in MotionStep.edge(fixture.pose(Double(i)/60),fixture.pose(max(0,Double(i-1)/60))) < MotionStep.edge(fixture.pose(Double(j)/60),fixture.pose(max(0,Double(j-1)/60))) } ?? 0
            try contact(frames:frames,indices:[0,max(0,peak-1),peak,min(total,peak+1),min(total,peak+2),total],renderer:renderers[0],to:out.appendingPathComponent(fixture.name+"-before-after.png"))
            try allFrames(frames,renderer:renderers[0],out:out,name:fixture.name)
            summaries.append(["object":fixture.name,"maxStepPtBefore":maxStep,"maxStepPtAfter":maxStep,"maxProcessedFootprintStepPt":maxFootprintStep,"maxStepMM":Double(maxStep)*profile.mmPerPoint,"maxCoveragePt":maxLength,"maxSpacingPt":maxSpacing,"maxStretchPt":maxStretch,"maxCopies":maxCopies,"treatedFrames":active,"rampFrames":mid,"belowFrames":low,"spikesOff":off,"spikesOn":on,"endpointPixelDifference":0])
        }
        summaries.append(try actualAlert(out:out,csv:&csv))
        try csv.write(to:out.appendingPathComponent("frames.csv"),atomically:true,encoding:.utf8)
        try componentChecks(out)
        let costs=measure()
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible window")
        let report:[String:Any]=["checks":checks,"findings":findings,"profile":["Hz":60,"mmPerPoint":0.27],"objects":summaries,"cost":costs,"limitations":"Glass proxies; geometry and native ink textures are real, WindowServer/glass refraction/physical frames/board remain host acceptance."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("motion-report.json"))
        print("M10-F: \(checks) checks, \(findings.count) findings; cost \(costs)")
        exit(findings.isEmpty ? 0:1)
    }
    static func makeFixtures()->[Fixture] {
        var f:[Fixture]=[]
        for (name,from,to,response,damping) in [("draft-enter",1304.0,320.0,0.48,0.88),("draft-exit",320.0,1304.0,0.36,0.90)] {
            let s=Spring(from:from,to:to,response:response,damping:damping,epsilon:Spring.restEpsilon)
            f.append(Fixture(name:name,duration:s.duration,kind:"glass",pose:{CGRect(x:s.sample($0).value,y:160,width:192,height:142)}))
        }
        for (name,from,to,response,damping) in [("draft-enter-max",1304.0,0.0,0.48,0.88),("draft-exit-max",0.0,1304.0,0.36,0.90)] {
            let s=Spring(from:from,to:to,response:response,damping:damping,epsilon:Spring.restEpsilon)
            f.append(Fixture(name:name,duration:s.duration,kind:"glass",pose:{CGRect(x:s.sample($0).value,y:160,width:192,height:142)}))
        }
        for up in [false,true] {
            let s=SheetBudMotion(rect:CGRect(x:300,y:30,width:352,height:448),upward:up)
            f.append(Fixture(name:up ? "subagents-up":"subagents-down",duration:s.duration,kind:"sheet",pose:{s.pose($0).rect}))
        }
        for width in [CGFloat(300),1200] {
            let curve=OverlayCurve(0.3,1.15,0.5,1,0.35)
            f.append(Fixture(name:"toast-\(Int(width))",duration:curve.duration,kind:"glass",pose:{t in let p=CGFloat(curve.value(at:t/curve.duration)),s=0.98+0.02*p;return CGRect(x:400-width/2,y:220+8*(1-p),width:width*s,height:32*s)}))
        }
        f.append(Fixture(name:"surface-fade",duration:0.16,kind:"sheet",pose:{_ in CGRect(x:300,y:100,width:352,height:300)}))
        f.append(Fixture(name:"surface-fade-out",duration:0.16,kind:"sheet",pose:{_ in CGRect(x:300,y:100,width:352,height:300)}))
        f.append(Fixture(name:"toast-dismiss",duration:0.20,kind:"glass",pose:{_ in CGRect(x:250,y:220,width:460,height:32)}))
        for size in [CGFloat(32),56,88] {
            let duration=2 * .pi/1.18/2.6
            f.append(Fixture(name:"orbit-\(Int(size))",duration:duration,kind:"solid",pose:{t in let v=OrbSatellites.motionPose(index:2,size:size,shape:nil,time:t*2.6);return M10FExposure.rect(center:CGPoint(x:440+v.0.x,y:180+v.0.y),size:CGSize(width:size*0.38*v.1,height:size*0.38*v.1))}))
        }
        for distance in [CGFloat(60),180] {
            let x=Spring(from:0,to:distance,response:2 * .pi/10,damping:0.8,epsilon:1e-12)
            f.append(Fixture(name:"satellite-row-\(Int(distance))",duration:1.5,kind:"solid",pose:{CGRect(x:350+x.sample($0).value,y:240,width:16,height:16)}))
        }
        let rx=Spring(from:-60,to:0,response:2 * .pi/10,damping:0.9,epsilon:1e-12),ry=Spring(from:50,to:0,response:2 * .pi/10,damping:0.9,epsilon:1e-12)
        f.append(Fixture(name:"satellite-return",duration:1.5,kind:"solid",pose:{t in let p=OrbSatellites.motionPose(index:2,size:56,shape:nil,time:1.1+1.4*t);return M10FExposure.rect(center:CGPoint(x:420+p.0.x+rx.sample(t).value,y:180+p.0.y+ry.sample(t).value),size:CGSize(width:16*p.1,height:16*p.1))}))
        let badge=Spring(from:0.4,to:1,response:0.30,damping:0.70,epsilon:1e-9)
        f.append(Fixture(name:"badge-99plus",duration:badge.duration,kind:"glyph",pose:{let s=CGFloat(badge.sample($0).value);return M10FExposure.rect(center:CGPoint(x:440,y:250),size:CGSize(width:28*s,height:18*s))}))
        let completion=OrbMotion.completionKeyframes()
        for size in [CGFloat(32),56,88] {
            f.append(Fixture(name:"completion-\(Int(size))",duration:completion.duration,kind:"glyph",pose:{t in let u=min(80,max(0,t/completion.duration*80)),i=min(79,Int(u)),v=completion.values[i]+(completion.values[i+1]-completion.values[i])*(u-Double(i));return CGRect(x:400,y:220-v*Double(size)*0.14,width:Double(size)*(1+v*0.12),height:Double(size)*(1+v*0.12))}))
        }
        f.append(Fixture(name:"rename-88",duration:0.18,kind:"glyph",pose:{t in let u=min(3,max(0,t/0.06)),i=min(2,Int(u)),v=[0.0,-4,2,0],a=(v[i]+(v[i+1]-v[i])*(u-Double(i)))*Double.pi/180;return CGRect(x:0,y:0,width:88,height:88).applying(CGAffineTransform(rotationAngle:a)).offsetBy(dx:420,dy:200)}))
        return f
    }
    static func texture(size:CGSize,name:String)->CGImage {
        if name.hasPrefix("subagents") {
            let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices),c=store.conversations[0]
            c.satellites += (4..<9).map { Satellite(id:"m10-agent-\($0)",face:"•ᴗ•",done:$0>6) }
            let sheet=SheetSubAgents(clock:OverlayManualClock()),host=OverlayView(frame:CGRect(x:0,y:0,width:900,height:800))
            sheet.present(conversation:c,anchor:CGRect(x:400,y:20,width:60,height:24),upward:false,in:host)
            sheet.card.content.layoutSubtreeIfNeeded()
            let image=SheetInkCapture.capture(sheet.card.content,scale:1).ink;sheet.dismiss(reason:.programmatic,animated:false);return image
        }
        let view=OverlayView(frame:CGRect(origin:.zero,size:size))
        let title=SheetStyle.label(name.contains("draft") ? "New Chat":name.contains("subagents") ? "Sub-agents":"•ᴗ•",size:name.contains("draft") ? 17:13,weight:.semibold)
        title.frame=CGRect(x:8,y:8,width:max(1,size.width-16),height:min(28,size.height));view.addSubview(title)
        if size.height>80 { let detail=SheetStyle.label("Running · Searching for rowInsets",size:11,secondary:true);detail.frame=CGRect(x:12,y:size.height-28,width:max(1,size.width-24),height:20);view.addSubview(detail) }
        return NativeViewBitmap.capture(view,scale:1)
    }
    static func spikes(_ frames:[[UInt8]],_ r:OffscreenRenderer)->Int {
        let d=(1..<frames.count).map{r.tileDiff(frames[$0-1],frames[$0]).value};guard d.count>5 else{return 0}
        return (2..<d.count-2).filter{k in let around=[d[k-2],d[k-1],d[k+1],d[k+2]].sorted(),median=(around[1]+around[2])/2;return d[k]>8 && d[k]>3*median+2}.count
    }
    static func contact(frames:[[[UInt8]]],indices:[Int],renderer:OffscreenRenderer,to url:URL)throws {
        let width=renderer.w,height=renderer.h,rowHeight=height+24,c=CGContext(data:nil,width:width*2,height:rowHeight*indices.count,bitsPerComponent:8,bytesPerRow:width*8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
        for (row,i) in indices.enumerated() {for k in 0...1 {
            let y=(indices.count-row-1)*rowHeight
            c.draw(renderer.image(frames[k][i]),in:CGRect(x:k*width,y:y,width:width,height:height))
            ("\(k==0 ? "OFF":"ON") · frame \(i) · \(String(format:"%.4f",Double(i)/60)) s" as NSString).draw(in:CGRect(x:k*width+8,y:y+height+3,width:width-16,height:18),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),.foregroundColor:NSColor.white])
        }}
        NSGraphicsContext.restoreGraphicsState()
        try NSBitmapImageRep(cgImage:c.makeImage()!).representation(using:.png,properties:[:])!.write(to:url)
    }
    static func allFrames(_ frames:[[[UInt8]]],renderer:OffscreenRenderer,out:URL,name:String)throws {
        let directory=out.appendingPathComponent("all-frames").appendingPathComponent(name)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for start in stride(from:0,to:frames[0].count,by:12) { try contact(frames:frames,indices:Array(start..<min(start+12,frames[0].count)),renderer:renderer,to:directory.appendingPathComponent(String(format:"%04d-%04d.png",start,min(start+11,frames[0].count-1)))) }
    }
    static func pixels(_ image:CGImage)->Data {let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return Data(bytes:c.data!,count:image.width*image.height*4)}
    static func componentChecks(_ out:URL)throws {
        let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices)
        func glassSafe(_ view:NSView)->Bool {
            if view is NSGlassEffectView {
                var layer=view.layer?.superlayer
                while let current=layer {if current is CAReplicatorLayer {return false};layer=current.superlayer}
                if !CATransform3DIsIdentity(view.layer?.transform ?? CATransform3DIdentity) {return false}
            }
            return view.subviews.allSatisfy(glassSafe)
        }
        for scale:CGFloat in [1,2] {
            let draft=DraftColumn(placeholder:store.conversations[0],store:store,scale:scale);draft.motionProfile=profile;draft.lay(CGRect(x:0,y:0,width:600,height:820))
            draft.enter(windowWidth:1280,now:1000);draft.frame(at:1000+draft.settles-1000)
            let before=NativeViewBitmap.capture(draft,scale:scale);draft.exposureEnabled=false;draft.frame(at:draft.settles)
            check(pixels(before)==pixels(NativeViewBitmap.capture(draft,scale:scale)),"draft rest pixel equality \(scale)x")
            draft.exposureEnabled=true;draft.enter(windowWidth:1280,now:2000);draft.frame(at:2000+1/60)
            check(draft.motionInk.trail.sample.count>1 && draft.motionInk.lastStretch>0,"real draft applies ink + glass")
            check(CATransform3DIsIdentity(draft.island.orb.glassView.layer!.transform),"real seed glass never transformed")
            check(glassSafe(draft),"draft glass never inside replicator")
            draft.frame(at:draft.settles);check(draft.motionInk.trail.sample.count==1,"draft clears trail at rest")
            let agents=SheetSubAgents(clock:OverlayManualClock()),host=OverlayView(frame:CGRect(x:0,y:0,width:900,height:800))
            agents.present(conversation:store.conversations[0],anchor:CGRect(x:300,y:700,width:100,height:24),upward:true,in:host)
            let base=agents.snapshot(scale:scale);agents.budMotion.exposureEnabled=false;agents.budMotion.sample(elapsed:agents.budMotion.plan!.duration,profile:profile)
            check(pixels(base)==pixels(agents.snapshot(scale:scale)),"sheet rest pixel equality \(scale)x")
            agents.budMotion.exposureEnabled=true;agents.budMotion.sample(elapsed:1/60,profile:profile)
            check(agents.card.motionGlassRect != nil && CATransform3DIsIdentity(agents.card.layer!.transform),"sheet whole glass real frame")
            let layer=agents.card.content.layer!,anchor=layer.anchorPoint,bounds=layer.bounds
            let visible=CGRect(x:-anchor.x*bounds.width,y:-anchor.y*bounds.height,width:bounds.width,height:bounds.height)
                .applying(CATransform3DGetAffineTransform(layer.transform)).offsetBy(dx:layer.position.x,dy:layer.position.y)
            let expected=agents.budMotion.plan!.pose(1/60).rect.offsetBy(dx:-agents.card.frame.minX,dy:-agents.card.frame.minY)
            check(MotionStep.edge(visible,expected)<1e-5,"AppKit actual anchor keeps native ink aligned with whole-sheet pose")
            check(glassSafe(agents),"subagents glass never inside replicator")
            agents.dismiss(reason:.programmatic,animated:false)
            check(agents.card.content.trail.sample.count==1,"dismiss retires sheet trail")
            let custom=SheetCustomizeChat(clock:OverlayManualClock());custom.present(name:"Chat",identity:.assigned(0),level:0.12,in:host)
            check(!custom.card.content.accumulates && glassSafe(custom),"customize nested glass has plain non-replicating ancestors")
            custom.dismiss(reason:.programmatic,animated:false)
        }
        let baseline=out.appendingPathComponent("m9-orb"),current=out
        var compared=0
        for file in (try? FileManager.default.contentsOfDirectory(at:baseline,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension=="png" {
            guard let a=CGImageSourceCreateWithURL(file as CFURL,nil).flatMap({CGImageSourceCreateImageAtIndex($0,0,nil)}),let b=CGImageSourceCreateWithURL(current.appendingPathComponent(file.lastPathComponent) as CFURL,nil).flatMap({CGImageSourceCreateImageAtIndex($0,0,nil)}) else{continue}
            compared+=1;check(pixels(a)==pixels(b),"orb baseline pixels "+file.lastPathComponent)
        }
        print("Orb baseline PNG compared: \(compared)")
        check(compared==32,"all 32 committed M9 Orb endpoints compared (run --suite orb first)")
        try satelliteServer(out)
        scaledSatelliteChecks()
    }
    static func scaledSatelliteChecks() {
        let path=Spring(from:0,to:180,response:2 * .pi/10,damping:0.8,epsilon:1e-12),base=CGRect(x:0,y:0,width:16,height:16)
        for scale:CGFloat in [0.5,1.28,2] {
            let solid=CALayer(),ink=CAReplicatorLayer(),timing=CAAnimation()
            var metric=profile;metric.mmPerPoint *= Double(scale)
            OrbSatelliteExposure.install(solid:solid,ink:ink,diameter:16,duration:1.5,timing:timing,profile:metric,displayScale:scale) { (CGPoint(x:path.sample($0).value,y:0),1) }
            guard let group=ink.animation(forKey:"m10F.ink") as? CAAnimationGroup,
                  let count=group.animations?.first(where:{($0 as? CAKeyframeAnimation)?.keyPath=="instanceCount"}) as? CAKeyframeAnimation,
                  let transform=group.animations?.first(where:{($0 as? CAKeyframeAnimation)?.keyPath=="instanceTransform"}) as? CAKeyframeAnimation,
                  let counts=count.values,let transforms=transform.values,let times=count.keyTimes else {
                check(false,"scaled satellite exposure tables \(scale)");continue
            }
            for i in counts.indices {
                let t=times[i].doubleValue*1.5,step=abs(path.sample(t).value-path.sample(max(0,t-1/60)).value)*Double(scale)
                let gate=smoothstep(1.08,2.7,step*profile.mmPerPoint),n=(counts[i] as! NSNumber).intValue
                check(gate==0 ? n==1:n>1,"scaled satellite physical gate \(scale) frame \(i)")
                guard n>1 else {continue}
                let matrix=CATransform3DGetAffineTransform((transforms[i] as! NSValue).caTransform3DValue)
                var previous=base,spacing:CGFloat=0
                for _ in 1..<n {let next=previous.applying(matrix);spacing=max(spacing,MotionStep.edge(next,previous)*scale);previous=next}
                check(spacing<=1.5+1e-4,"scaled satellite displayed spacing \(scale) frame \(i)")
                check(Double(MotionStep.edge(base,previous)*scale)+1e-5>=step*gate,"scaled satellite displayed coverage \(scale) frame \(i)")
            }
        }
    }
    static func actualAlert(out:URL,csv:inout String)throws->[String:Any] {
        let hosts=[CALayer(),CALayer()],shapes=[CALayer(),CALayer()]
        for k in 0...1 {hosts[k].backgroundColor=NSColor.black.cgColor;shapes[k].frame=CGRect(x:130,y:80,width:36,height:36);shapes[k].cornerRadius=18;shapes[k].backgroundColor=NSColor.green.cgColor;hosts[k].addSublayer(shapes[k])}
        let renderers=hosts.map{OffscreenRenderer(size:CGSize(width:300,height:160),host:$0)}
        for shape in shapes { let a=OrbMotion.alertHop();a.beginTime=1000;shape.add(a,forKey:"authored.alert") }
        var frames=[[[UInt8]](),[[UInt8]]()],old:Double?,maxStep=0.0
        for i in 0...400 {
            for k in 0...1 {frames[k].append(renderers[k].render(at:1000+Double(i)/60))}
            let bytes=frames[0].last!,w=renderers[0].w,h=renderers[0].h
            var total=0.0,weight=0.0
            for y in 0..<h {for x in 0..<w {let p=(y*w+x)*4;if bytes[p+1]>200 && bytes[p]<20 && bytes[p+2]<20 {total+=Double(y);weight+=1}}}
            let center=total/max(1,weight),step=old.map{abs(center-$0)} ?? 0;old=center;maxStep=max(maxStep,step)
            check(step+1<4,"authored cubic hop below onset, including 1px measurement allowance")
            csv+="alert-hop,\(i),\(Double(i)/60),\(step),\(step*0.27),0,1,0,0,0,\(step)\n"
            check(frames[0].last==frames[1].last,"authored hop off/on pixels \(i)")
        }
        let a=spikes(frames[0],renderers[0]),b=spikes(frames[1],renderers[1]);check(a==0 && b==0,"authored cubic hop spikes")
        try contact(frames:frames,indices:[0,3,6,9,12,400],renderer:renderers[0],to:out.appendingPathComponent("alert-hop-before-after.png"))
        try allFrames(frames,renderer:renderers[0],out:out,name:"alert-hop")
        return ["object":"alert-hop","maxStepPtBefore":maxStep,"maxStepPtAfter":maxStep,"maxProcessedFootprintStepPt":maxStep,"maxStepMM":maxStep*0.27,"measurement":"authored CA cubic animation; raster centroid, +1px conservative allowance also below onset","maxCoveragePt":0,"maxSpacingPt":0,"maxStretchPt":0,"maxCopies":1,"treatedFrames":0,"spikesOff":a,"spikesOn":b,"endpointPixelDifference":0]
    }
    static func satelliteServer(_ out:URL)throws {
        let hosts=[CALayer(),CALayer()],poses=[CALayer(),CALayer()],solids=[CALayer(),CALayer()],inks=[CAReplicatorLayer(),CAReplicatorLayer()]
        let spring=Spring(from:0,to:180,response:2 * .pi/10,damping:0.8,epsilon:1e-12),duration=1.5
        for k in 0...1 {
            hosts[k].backgroundColor=NSColor.black.cgColor;hosts[k].addSublayer(poses[k]);poses[k].addSublayer(solids[k])
            solids[k].bounds=CGRect(x:0,y:0,width:16,height:16);solids[k].cornerRadius=8;solids[k].backgroundColor=NSColor.systemBlue.cgColor;solids[k].addSublayer(inks[k])
            let face=CATextLayer();face.font=NSFont.systemFont(ofSize:5.4,weight:.semibold);face.fontSize=5.4;face.string="•ᴗ•";face.foregroundColor=NSColor.white.cgColor;face.alignmentMode = .center;face.frame=CGRect(x:0,y:4,width:16,height:8);face.contentsScale=2;inks[k].addSublayer(face)
        }
        let timing=CAAnimation();timing.beginTime=1000
        let renderers=hosts.map{OffscreenRenderer(size:CGSize(width:340,height:100),host:$0)};var frames=[[[UInt8]](),[[UInt8]]()]
        OrbSatelliteExposure.install(solid:solids[1],ink:inks[1],diameter:16,duration:duration,timing:timing,profile:profile) { t in (CGPoint(x:spring.sample(t).value,y:0),1) }
        check(solids[1].animation(forKey:"m10F.solid") != nil && inks[1].animation(forKey:"m10F.ink") != nil,"actual satellite CA exposure installed")
        for i in 0...100 {
            let t=Double(i)/60
            CATransaction.begin();CATransaction.setDisableActions(true);for p in poses {p.position=CGPoint(x:60+spring.sample(t).value,y:50)};CATransaction.commit()
            for k in 0...1 {frames[k].append(renderers[k].render(at:1000+t))}
        }
        check(frames[0].first==frames[1].first && frames[0].last==frames[1].last,"actual satellite CA endpoint pixels 0")
        let a=spikes(frames[0],renderers[0]),b=spikes(frames[1],renderers[1]);check(a==0 && b==0,"actual satellite CA spikes \(a)/\(b)")
        check(frames[0][8] != frames[1][8],"actual satellite CA treatment visibly differs at speed")
        try contact(frames:frames,indices:[0,3,6,9,12,100],renderer:renderers[0],to:out.appendingPathComponent("satellite-server-before-after.png"))
        try allFrames(frames,renderer:renderers[0],out:out,name:"satellite-server")
    }
    static func measure()->[String:Double] {
        let card=SheetCard(frame:CGRect(x:0,y:0,width:352,height:448));card.layoutSubtreeIfNeeded()
        card.enableInkAccumulation();card.layoutSubtreeIfNeeded()
        let driver=SheetBudDriver();driver.start(card:card,upward:true,reduceMotion:false)
        driver.backingScaleOverride=2
        let builtin=NSScreen.screens.first { screen in
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main!
        var costProfile=DisplayProfile.of(builtin);costProfile.frameInterval=1/120
        var off:[Double]=[],on:[Double]=[]
        for enabled in [false,true] {driver.exposureEnabled=enabled;for i in 0..<1200 {let start=CACurrentMediaTime();driver.sample(elapsed:Double(i%30)/120,profile:costProfile);let elapsed=(CACurrentMediaTime()-start)*1000;if i>100 {if enabled {on.append(elapsed)}else{off.append(elapsed)}}}}
        func p95(_ a:[Double])->Double {let s=a.sorted();return s[Int(Double(s.count-1)*0.95)]}
        let store=ConversationStore(conversations:MockSeed.make(),projects:MockSeed.projects,devices:MockSeed.devices),draft=DraftColumn(placeholder:store.conversations[0],store:store,scale:2)
        draft.motionProfile=costProfile;draft.lay(CGRect(x:0,y:0,width:600,height:820));draft.enter(windowWidth:1280,now:1000)
        var doff:[Double]=[],don:[Double]=[]
        for enabled in [false,true] {draft.exposureEnabled=enabled;for i in 0..<1200 {let start=CACurrentMediaTime();draft.frame(at:1000+Double(i%30)/120);let elapsed=(CACurrentMediaTime()-start)*1000;if i>100 {if enabled {don.append(elapsed)}else{doff.append(elapsed)}}}}
        return ["offP95ms":p95(off),"onP95ms":p95(on),"deltaP95ms":p95(on)-p95(off),"draftOffP95ms":p95(doff),"draftOnP95ms":p95(don),"draftDeltaP95ms":p95(don)-p95(doff),"Hz":120,"scale":2,"mmPerPoint":costProfile.mmPerPoint]
    }
}
#endif
