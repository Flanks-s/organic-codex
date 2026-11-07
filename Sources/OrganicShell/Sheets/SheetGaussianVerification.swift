#if SHEETS_M101_SELFTEST
import AppKit
import QuartzCore

@main @MainActor enum SheetGaussianVerification {
    static var checks=0,findings:[String]=[],audit:[[String:Any]]=[]
    static let profile=DisplayProfile(name:"Dell 60 Hz",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
    static func check(_ value:Bool,_ note:String) {checks+=1;if !value {findings.append(note);print("FINDING: "+note)}}
    static func delta(_ a:[UInt8],_ b:[UInt8])->Int {zip(a,b).reduce(0){max($0,abs(Int($1.0)-Int($1.1)))}}
    static func p95(_ a:[Double])->Double {let s=a.sorted();return s.isEmpty ? 0:s[Int(Double(s.count-1)*0.95)]}
    static func fixture(_ name:String)->(NSView,CGRect,NSView) {
        let host=OverlayView(frame:CGRect(x:0,y:0,width:900,height:820))
        if name.hasPrefix("sheet") {
            let c=Conversation(id:"sheet-fixture",title:"Searching for layout differences")
            c.satellites=(0..<7).map{Satellite(id:"agent-\($0)",face:$0>4 ? "-_-":"•ᴗ•",done:$0>4,title:"Checking the native scene \($0+1)")}
            let sheet=SheetSubAgents(clock:OverlayManualClock());sheet.reduceMotion=true
            sheet.present(conversation:c,anchor:CGRect(x:420,y:700,width:28,height:28),upward:name.contains("up"),in:host)
            sheet.card.content.layoutSubtreeIfNeeded();return (sheet.card,sheet.card.content.bounds,host)
        }
        let toast=SheetToast(clock:OverlayManualClock());toast.reduceMotion=true
        toast.present(text:"“Layout comparison” archived",anchor:CGRect(x:450,y:740,width:28,height:28),in:host,undo:{})
        toast.card.content.layoutSubtreeIfNeeded();return (toast.card,toast.card.content.bounds,host)
    }
    @MainActor final class Scene {
        let host=CALayer(),glass=CAShapeLayer(),pose=CALayer(),sharp=CALayer()
        let transition:SheetContentTransition?
        let source:SheetCard,bounds:CGRect,mode:String,scale:CGFloat,name:String
        let owner:NSView
        let renderer:OffscreenRenderer
        let start=1000.0
        var maxCopies=1,maxHandoffDelta=0
        var maxHandoffMean=0.0,maxHandoffChanged=0.0
        init(name:String,mode:String,scale:CGFloat) {
            self.name=name;self.mode=mode;self.scale=scale
            let f=fixture(name);source=f.0 as! SheetCard;bounds=f.1;owner=f.2
            host.backgroundColor=NSColor(srgbRed:0.075,green:0.09,blue:0.085,alpha:1).cgColor
            glass.fillColor=NSColor(white:0.21,alpha:1).cgColor;host.addSublayer(glass);host.addSublayer(pose)
            pose.anchorPoint = .zero;pose.bounds=bounds;pose.position=CGPoint(x:40,y:36)
            let pair=SheetInkCapture.capture(source.content,scale:scale)
            sharp.anchorPoint = .zero;sharp.frame=bounds;sharp.contents=pair.original;sharp.contentsScale=scale;pose.addSublayer(sharp)
            if mode=="off" {transition=nil}
            else {
                let t=SheetContentTransition(clock:SceneClock());transition=t
                t.begin(in:source.content,mode:mode=="gauss" ? .gauss:.accum,configuration:name.hasPrefix("sheet") ? .spotlight:.system,visible:!name.hasSuffix("out"),at:start,scale:scale,pivot:CGPoint(x:bounds.midX,y:name.contains("up") ? bounds.height:0))
                t.root.removeFromSuperlayer();pose.addSublayer(t.root);sharp.isHidden=true
            }
            renderer=OffscreenRenderer(size:CGSize(width:max(460,bounds.width+80),height:max(150,bounds.height+72)),host:host,scale:scale)
        }
        func frame(_ elapsed:Double)->[UInt8] {
            let incoming = !name.hasSuffix("out"),isSheet=name.hasPrefix("sheet")
            CATransaction.begin();CATransaction.setDisableActions(true)
            var rect=bounds,opacity:Float=1,transform=CATransform3DIdentity
            if incoming,isSheet {
                let plan=SheetBudMotion(rect:bounds,upward:name.contains("up")),a=plan.pose(elapsed),b=plan.pose(max(0,elapsed-1/60))
                rect=a.rect;opacity=a.opacity
                transform=CATransform3DMakeScale(a.scale,a.scale,1);transform.m41=bounds.midX*(1-a.scale);transform.m42=(name.contains("up") ? bounds.height:0)*(1-a.scale)
                transition?.accumulate(now:a.rect,earlier:b.rect,profile:profile)
            } else if incoming {
                let p=CGFloat(OverlayCurve(0.3,1.15,0.5,1,0.35).value(at:elapsed/0.35)),s=0.98+0.02*p
                opacity=Float(min(1,max(0,p)));transform=CATransform3DMakeScale(s,s,1);transform.m42=8*(1-p)
                let a=CGRect(x:0,y:8*(1-p),width:bounds.width*s,height:bounds.height*s)
                let q=CGFloat(OverlayCurve(0.3,1.15,0.5,1,0.35).value(at:max(0,elapsed-1/60)/0.35)),z=0.98+0.02*q
                transition?.accumulate(now:a,earlier:CGRect(x:0,y:8*(1-q),width:bounds.width*z,height:bounds.height*z),profile:profile)
            } else {opacity=Float(1-OverlayMotion.ease(isSheet ? 0.16:0.2).value(at:elapsed/(isSheet ? 0.16:0.2)))}
            let snapped=SheetStyle.snap(rect.offsetBy(dx:40,dy:36),scale:scale)
            glass.path=CGPath(roundedRect:snapped,cornerWidth:isSheet ? 24*rect.width/bounds.width:16,cornerHeight:isSheet ? 24*rect.width/bounds.width:16,transform:nil)
            glass.opacity=opacity;pose.opacity=opacity;pose.transform=transform
            maxCopies=max(maxCopies,transition?.trail.layer.instanceCount ?? 1)
            CATransaction.commit();let pixels=renderer.render(at:start+elapsed)
            if incoming,mode=="gauss",elapsed>=0.1,transition?.active==true,transition?.effect?.resting == .visible {
                CATransaction.begin();CATransaction.setDisableActions(true);transition?.finish();sharp.isHidden=false;CATransaction.commit()
                let native=renderer.render(at:start+elapsed);maxHandoffDelta=max(maxHandoffDelta,SheetGaussianVerification.delta(pixels,native))
                var sum=0,changed=0
                for i in stride(from:0,to:pixels.count,by:4) {
                    var hit=false
                    for c in 0..<3 {let d=abs(Int(pixels[i+c])-Int(native[i+c]));sum+=d;hit=hit || d>0}
                    if hit {changed+=1}
                }
                maxHandoffMean=max(maxHandoffMean,Double(sum)/Double(pixels.count/4*3));maxHandoffChanged=max(maxHandoffChanged,Double(changed)/Double(pixels.count/4))
                return native
            }
            return pixels
        }
        func endpoint(_ elapsed:Double)->[UInt8] {CATransaction.begin();CATransaction.setDisableActions(true);transition?.finish();sharp.isHidden=false;CATransaction.commit();return frame(elapsed)}
    }
    static func main() throws {
        _=NSApplication.shared
        let out=URL(fileURLWithPath:CommandLine.arguments[1]),tag=CommandLine.arguments.dropFirst(2).first ?? "gaussian-debug"
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        if tag.hasPrefix("switches") {
            let env=ProcessInfo.processInfo.environment,expected=env["M10_SHEET_ZOOM"]=="gauss" ? SheetZoom.gauss:.accum
            let sheet=SheetSubAgents(clock:OverlayManualClock()),toast=SheetToast(clock:OverlayManualClock())
            check(SheetZoom.selected==expected && sheet.budMotion.zoom==expected && toast.zoom==expected,"environment selects both real components")
            check(sheet.budMotion.exposureEnabled == (env["M10_DRAFT_EXPOSURE"] != "0") && toast.exposureEnabled == sheet.budMotion.exposureEnabled,"master off has precedence")
            print("Sheet switches: \(checks) checks, \(findings.count) findings, mode \(expected.rawValue), enabled \(toast.exposureEnabled)")
            exit(findings.isEmpty ? 0:1)
        }
        var summaries:[[String:Any]]=[],csv="scenario,mode,scale,frame,time,radius,opacity,innerScale,copies,renderMs,auditViolations\n"
        for scale:CGFloat in [1,2] {for name in ["sheet-down-in","sheet-up-in","sheet-out","toast-in","toast-out"] {
            let scenes=["off","accum","gauss"].map{Scene(name:name,mode:$0,scale:scale)}
            check(scenes[2].transition?.effect?.filterAvailable==true,"actual Gaussian CA filter available")
            check(scenes[2].transition?.plates.filters?.isEmpty != false && scenes[2].glass.filters?.isEmpty != false,"plate/glass siblings never filtered")
            var frames=[[[UInt8]]] (repeating:[],count:3),costs=[[Double]](repeating:[],count:3)
            let duration=name.hasSuffix("out") ? 0.3:name.hasPrefix("sheet") ? 0.9:0.5,total=Int((duration*60).rounded())
            for i in 0...total {let t=Double(i)/60
                for (k,scene) in scenes.enumerated() {
                    let started=CACurrentMediaTime(),pixels=scene.frame(t);costs[k].append((CACurrentMediaTime()-started)*1000);frames[k].append(pixels)
                    let failures=ReplicaContainerAudit.inspect(scene.host,scenario:name+"-"+scene.mode,frame:i,time:1000+t)
                    audit += failures.map(\.fields);check(failures.isEmpty,"\(name) \(scene.mode) \(scale)x audit frame \(i)")
                    let p=scene.transition?.effect?.pose(at:1000+t)
                    csv+="\(name),\(scene.mode),\(scale),\(i),\(t),\(p?.radius ?? 0),\(p?.opacity ?? 1),\(p?.scale ?? 1),\(scene.transition?.trail.layer.instanceCount ?? 1),\(costs[k].last!),\(failures.count)\n"
                }
            }
            for k in 1...2 {
                check(frames[k].first==frames[0].first,"\(name) \(scale)x first pixel difference 0 (max \(delta(frames[k].first!,frames[0].first!)))")
                let before=frames[k].last!,after=scenes[k].endpoint(duration)
                check(delta(before,after)<=1,"\(name) \(scale)x native handoff rounding <=1/255: \(delta(before,after))")
                frames[k][total]=after
                check(after==frames[0].last!,"\(name) \(scale)x last pixel difference 0")
            }
            for (k,scene) in scenes.enumerated() {
                let spikes=SheetM10FVerification.spikes(frames[k],scene.renderer)
                // Moving, separately sampled 8-bit foreground/plate planes need not round like one flat native image.
                // Bound that edge-only re-sampling separately from the strict zero static endpoints.
                if scene.mode=="gauss" {check(scene.maxHandoffDelta<=3 && scene.maxHandoffMean<0.03,"100ms moving native handoff max <=3/255, RGB mean <0.03/255: \(scene.maxHandoffDelta) / \(scene.maxHandoffMean)")}
                check(spikes==0,"\(name) \(scene.mode) \(scale)x spikes \(spikes)")
                summaries.append(["scenario":name,"mode":scene.mode,"scale":scale,"spikes":spikes,"renderReadbackP95ms":p95(costs[k]),"maxCopies":scene.maxCopies,"nativeHandoffDelta":scene.maxHandoffDelta,"nativeHandoffMean":scene.maxHandoffMean,"nativeHandoffChangedFraction":scene.maxHandoffChanged,"contentFilters":scene.mode=="gauss" ? 1:0])
            }
            try filmstrip(frames:frames,renderer:scenes[0].renderer,name:name,scale:scale,out:out)
        }}
        try nativeChecks(out)
        legacyFixtureAudit()
        try JSONSerialization.data(withJSONObject:["findings":audit,"count":audit.count],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("container-audit.json"))
        let columns=["file","layerPath","scenario","frame","time","reason","active"]
        func cell(_ value:Any?)->String {"\""+String(describing:value ?? "").replacingOccurrences(of:"\"",with:"\"\"")+"\""}
        let auditCSV=columns.joined(separator:",")+"\n"+audit.map{row in columns.map{cell(row[$0])}.joined(separator:",")+"\n"}.joined()
        try auditCSV.write(to:out.appendingPathComponent("audit-violations.csv"),atomically:true,encoding:.utf8)
        let cost=commitCosts(iterations:tag.contains("timing") ? 30:0)
        let tickCost=sampleCosts(iterations:tag.contains("timing") ? 30:0)
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible windows")
        try csv.write(to:out.appendingPathComponent(tag+"-frames.csv"),atomically:true,encoding:.utf8)
        let result:[String:Any]=["checks":checks,"findings":findings,"auditFindings":audit,"profile":["Hz":60,"mmPerPoint":0.27],"scenarios":summaries,"cost":cost,"sampleCost":tickCost,"configuration":["sheet":"spotlight","toast":"system","duration":0.1,"radius":4],"limitations":"In-process CARenderer; rounded glass proxy. renderReadback includes synchronous GPU readback, not live presented FPS."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent(tag+"-report.json"))
        print("M10.1 Sheets: \(checks) checks, \(findings.count) findings, \(audit.count) container findings; cost \(cost)")
        exit(findings.isEmpty ? 0:1)
    }
    static func nativeChecks(_ out:URL)throws {
        for name in ["sheet-down-in","toast-in"] {for scale:CGFloat in [1,2] {
            let f=fixture(name);defer {withExtendedLifetime(f.2){}};let card=f.0 as! SheetCard,original=NativeViewBitmap.capture(card.content,scale:scale)
            let transition=SheetContentTransition(clock:SceneClock())
            transition.begin(in:card.content,mode:.gauss,configuration:.spotlight,visible:true,at:1000,scale:scale,pivot:.zero)
            check(transition.capture?.exceptionalPixels==0,"native matte source-over alpha consistency")
            check(ReplicaContainerAudit.inspect(card.layer!,scenario:"native-"+name,frame:0,time:1000).isEmpty,"native card audit has no replicated containers")
            check(card.content.accumulates==false,"native backing is never a replicator")
            let geometry=card.content.subviews.map(\.frame)
            transition.finish()
            check(geometry==card.content.subviews.map(\.frame),"capture/finish preserves native layout")
            check(SheetInkCapture.bytes(original)==SheetInkCapture.bytes(NativeViewBitmap.capture(card.content,scale:scale)),"native restoration pixel difference 0")
        }}
        let host=OverlayView(frame:CGRect(x:0,y:0,width:900,height:820)),clock=OverlayManualClock()
        let c=Conversation(id:"updates",title:"Source");c.satellites=[Satellite(id:"a",face:"•ᴗ•",title:"Before"),Satellite(id:"b",face:"-_-",done:true)]
        let agents=SheetSubAgents(clock:clock);agents.reduceMotion=true;agents.present(conversation:c,anchor:CGRect(x:400,y:600,width:20,height:20),upward:true,in:host)
        agents.reduceMotion=false;agents.budMotion.zoom = .gauss;agents.budMotion.start(card:agents.card,upward:true,reduceMotion:false,at:1000,windowless:true)
        agents.budMotion.sample(elapsed:0.037,profile:profile)
        let effect=agents.budMotion.contentTransition!.effect!,pose=effect.pose(at:1000.037),sourceBefore=SheetInkCapture.bytes(agents.budMotion.contentTransition!.capture!.original)
        c.satellites[0].title="After the history update";agents.refresh()
        check(effect === agents.budMotion.contentTransition?.effect && pose==effect.pose(at:1000.037),"semantic refresh preserves Gaussian clock / pose")
        check(sourceBefore != SheetInkCapture.bytes(agents.budMotion.contentTransition!.capture!.original),"semantic refresh replaces stale glyph texture")
        let interrupted=agents.budMotion.openingOpacity(at:1000.037)
        check(interrupted>0 && interrupted<1,"interrupted sheet fade starts at its existing spring opacity, not 1")
        let geometry=agents.card.content.layer!.transform
        agents.dismiss(reason:.escape)
        check(CATransform3DEqualToTransform(geometry,agents.card.content.layer!.transform),"dismiss does not replay the .86 entrance or jump parent geometry")
        clock.advance(by:0.16)
        check(agents.budMotion.contentTransition==nil && agents.card.content.layer?.isHidden != true,"dismiss restores native content and retires transition")
        let f=fixture("toast-in"),late=SheetContentTransition(clock:SceneClock()),event=CACurrentMediaTime()
        late.begin(in:(f.0 as! SheetCard).content,mode:.gauss,configuration:.system,visible:true,scale:1,pivot:.zero)
        check(late.commitTime>event && late.effect?.plan?.began==late.commitTime,"live commit timestamp is selected AFTER preparation")
        let l=CALayer();SheetMotionAnimation.animate(l,"opacity",from:0,to:1,curve:OverlayMotion.ease(0.16),at:late.commitTime)
        check(l.animation(forKey:"overlay.opacity")?.beginTime==l.convertTime(late.commitTime,from:nil),"container and Gaussian share the prepared commit timestamp")
        late.finish();withExtendedLifetime(f.2){}
        let toast=SheetToast(clock:clock);toast.reduceMotion=true;toast.present(text:"Archived",anchor:.zero,in:host)
        let toastTime=toast.sceneClock.mediaTime()
        check(toast.openingOpacity(at:toastTime)<0.05 && toast.openingOpacity(at:toastTime+0.35)==1,"toast closing can continue the existing opening opacity without snapping to 1")
        toast.reduceMotion=false;toast.startContent(visible:true,at:1000)
        clock.advance(by:0.101)
        check(toast.contentTransition==nil,"toast restores native hover/text immediately after its 100ms Gaussian, before original 350ms motion ends")
        toast.dismiss(reason:.programmatic,animated:false)
        let fresh=fixture("sheet-down-in"),driver=SheetBudDriver()
        driver.zoom = .gauss;driver.start(card:fresh.0 as! SheetCard,upward:false,reduceMotion:false,at:1000,windowless:true)
        driver.sample(elapsed:0.101,profile:profile)
        check(driver.contentTransition==nil && driver.plan != nil,"sheet restores live native dots/hover after 100ms while the glass spring continues")
        driver.stop(reset:true);withExtendedLifetime(fresh.2){}
        let originalPixel=SheetInkCapture.image([80,120,190,218],width:1,height:1),platePixel=SheetInkCapture.image([72,113,185,218],width:1,height:1)
        let matte=SheetInkCapture.split(originalPixel,plates:platePixel),ink=SheetInkCapture.bytes(matte.ink)
        check(ink[3]>0,"equal-alpha native font smoothing never loses RGB ink")
        check((0..<3).allSatisfy {abs(Int(ink[$0])+Int((Double([72,113,185][$0])*(1-Double(ink[3])/255)).rounded())-[80,120,190][$0])<=1},"valid premultiplied matte recomposes synthetic RGB within 1/255")
        let scene=Scene(name:"sheet-down-in",mode:"gauss",scale:1),t=0.037
        let before=scene.frame(t);scene.transition?.setVisible(false,at:1000+t);let after=scene.frame(t)
        check(before==after,"mid-bud reversal has pixel difference 0")
        let terminalEffect=scene.transition!.effect!
        _=scene.frame(t+0.1);let a=scene.renderer.render(at:1000+t+0.1);_ = terminalEffect.settle(at:1000+t+0.1);let b=scene.renderer.render(at:1000+t+0.1)
        check(a==b,"Gaussian terminal enabled gate / filter removal has pixel difference 0")
    }
    static func legacyFixtureAudit() {
        for f in SheetM10FVerification.makeFixtures() where f.name.hasPrefix("subagents") || f.name.hasPrefix("toast") || f.name.hasPrefix("surface") {
            let size=f.pose(f.duration).size,image=SheetM10FVerification.texture(size:size,name:f.name),root=CAReplicatorLayer(),ink=CALayer()
            if let b=SheetInkCapture.trim(image,scale:1) {ink.contents=b.image;ink.frame=b.rect}
            ReplicaContainerAudit.register(ink,material:.glyph,note:"Legacy fixture source now foreground-only and alpha-tight")
            root.addSublayer(ink)
            let failures=ReplicaContainerAudit.inspect(root,scenario:"legacy-fixture-"+f.name,frame:0,time:1000);audit += failures.map(\.fields)
            check(failures.isEmpty,"legacy \(f.name) audited ink texture")
        }
    }
    static func threadMilliseconds()->Double {var t=timespec();clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t);return Double(t.tv_sec)*1000+Double(t.tv_nsec)/1e6}
    static func commitCosts(iterations:Int)->[[String:Any]] {
        var output:[[String:Any]]=[]
        for name in ["sheet-down-in","toast-in"] {for mode in ["off","accum","gauss"] {
            let f=fixture(name);defer {withExtendedLifetime(f.2){}};let card=f.0 as! SheetCard,clock=SceneClock();var times:[Double]=[],cpu:[Double]=[]
            for i in 0..<iterations {let start=CACurrentMediaTime(),thread=threadMilliseconds()
                if mode != "off" {let content=SheetContentTransition(clock:clock);content.begin(in:card.content,mode:mode=="gauss" ? .gauss:.accum,configuration:name.hasPrefix("sheet") ? .spotlight:.system,visible:true,at:1000+Double(i),scale:2,pivot:.zero);content.finish()}
                times.append((CACurrentMediaTime()-start)*1000);cpu.append(threadMilliseconds()-thread)
            }
            output.append(["scenario":name,"mode":mode,"prepareCommitP95ms":p95(times),"prepareThreadP95ms":p95(cpu),"firstPrepareMs":times.first ?? 0,"wallSamplesMs":times,"cpuSamplesMs":cpu,"samples":iterations,"scale":2])
        }}
        return output
    }
    /// Existing driver-A glass tick, with preparation excluded. Replay the first 100ms, including handoff.
    static func sampleCosts(iterations:Int)->[[String:Any]] {
        guard iterations>0 else {return []}
        var result:[[String:Any]]=[]
        for mode in ["off","accum","gauss"] {
            let f=fixture("sheet-down-in"),card=f.0 as! SheetCard,driver=SheetBudDriver()
            driver.exposureEnabled=mode != "off";driver.zoom=mode=="accum" ? .accum:.gauss
            driver.backingScaleOverride=2
            var wall:[Double]=[],cpu:[Double]=[]
            for _ in 0..<iterations {
                driver.start(card:card,upward:false,reduceMotion:false,at:1000,windowless:true)
                for i in 1...6 {
                    let start=CACurrentMediaTime(),thread=threadMilliseconds()
                    driver.sample(elapsed:Double(i)/60,profile:profile)
                    wall.append((CACurrentMediaTime()-start)*1000);cpu.append(threadMilliseconds()-thread)
                }
                driver.stop(reset:true)
            }
            result.append(["mode":mode,"samples":wall.count,"wallP95ms":p95(wall),"threadP95ms":p95(cpu),"wallSamplesMs":wall,"cpuSamplesMs":cpu,"scale":2])
            withExtendedLifetime(f.2){}
        }
        return result
    }
    static func filmstrip(frames:[[[UInt8]]],renderer:OffscreenRenderer,name:String,scale:CGFloat,out:URL)throws {
        let dir=out.appendingPathComponent(name+"-\(Int(scale))x");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let w=renderer.w,h=renderer.h,header=24
        for first in stride(from:0,to:frames[0].count,by:8) {
            let ids=Array(first..<min(first+8,frames[0].count)),context=CGContext(data:nil,width:w*ids.count,height:(h+header)*3,bitsPerComponent:8,bytesPerRow:w*ids.count*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
            for k in 0..<3 {for (column,i) in ids.enumerated() {
                let y=(2-k)*(h+header);context.draw(renderer.image(frames[k][i]),in:CGRect(x:column*w,y:y,width:w,height:h))
                (["OFF","ACCUM","GAUSS"][k]+" · f\(i) · "+String(format:"%.4f",Double(i)/60)+" s" as NSString).draw(in:CGRect(x:column*w+6,y:y+h,width:w-12,height:header),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),.foregroundColor:NSColor.white])
            }}
            NSGraphicsContext.restoreGraphicsState()
            try NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(String(format:"%03d-%03d.png",first,ids.last!)))
        }
    }
}
#endif
