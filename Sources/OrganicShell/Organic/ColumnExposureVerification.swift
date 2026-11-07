import AppKit
import QuartzCore
import CoreText

/// Invoked by App/SelfTest.swift with SELFTEST_M10_COLUMNS=1. This is the actual scene, at Dell 60Hz, not an app or
/// a window. The native island is tested separately through its real placement entry and documented glass proxy.
@MainActor enum M10ColumnVerification {
    static let profile=DisplayProfile(name:"Dell 60Hz M10-D",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0)
    static var findings:[String]=[], checks=0, rows:[[String:Any]]=[], summaries:[[String:Any]]=[]
    static func check(_ value:Bool,_ message:String) { checks+=1; if !value { findings.append(message); print("FINDING: "+message) } }
    static func run(to path:String,size:CGSize)->Int32 {
        _ = NSApplication.shared; NSApp.appearance=NSAppearance(named:.darkAqua)
        let output=URL(fileURLWithPath:path);try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        findings=[];checks=0;rows=[];summaries=[]
        M10ColumnExposure.diagnostics=true
        let scales=ProcessInfo.processInfo.environment["SELFTEST_SCALES"]?.split(separator:",").compactMap{Double($0)}.map{CGFloat($0)} ?? [1,2]
        for scale in scales {
            for name in ["switch","card-switch","card-focused","focused","land","land-reverse","card-land","archive","split","graft-focus","reverse","chain"] {
                if let only=ProcessInfo.processInfo.environment["SELFTEST_ONLY"]?.split(separator:",").map(String.init),!only.contains(name) { continue }
                autoreleasepool { scene(name,scale:scale,size:size,output:output) }
            }
            for name in ["island-travel","island-promotion","island-expand","island-collapse","island-activity","island-activity-out","island-retarget"] {
                if let only=ProcessInfo.processInfo.environment["SELFTEST_ONLY"]?.split(separator:",").map(String.init),!only.contains(name) { continue }
                autoreleasepool { island(name,scale:scale,output:output) }
            }
        }
        edgeComparison(output:output); weights(); spatialWeights(); cost(output:output); renderBudget(); textureOrientation(output:output); liveLayerFixture(); glyphTextureFixture(output:output); nativeMotionCosts(output:output)
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no windows opened")
        let report:[String:Any]=["profile":profile.summary,"checks":checks,"findings":findings,"scenarios":summaries,"frames":rows,
            "boundary":"CARenderer and native cacheDisplay/proxy only; no physical FPS, WindowServer glass or human score claimed."]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:output.appendingPathComponent("report.json")) }
        print("M10 columns: \(checks) checks, \(findings.count) findings -> \(output.path)")
        return findings.isEmpty ? 0:1
    }
    static func gate(_ step:CGFloat)->CGFloat { CGFloat(smoothstep(1.08,2.7,Double(step)*profile.mmPerPoint)) }
    static func verify(_ fields:[String:Any],enabled:Bool,tag:String) {
        let step=(fields["stepPt"] as? CGFloat) ?? CGFloat((fields["stepPt"] as? Double) ?? 0)
        let g=(fields["gate"] as? CGFloat) ?? 0,L=(fields["lengthPt"] as? CGFloat) ?? 0
        let copies=(fields["copies"] as? Int) ?? 1, spacing=(fields["spacingPt"] as? CGFloat) ?? 0
        let coverage=(fields["coveredLengthPt"] as? CGFloat) ?? L
        check(abs(g-(enabled ? gate(step):0))<0.00001,tag+" physical gate")
        let accumulation=(fields["treatment"] as? String)?.contains("accumulation") == true
        if enabled && g>0 { check(L+0.0001>=step*g && coverage+0.0001>=L,tag+" actual path coverage"); if L>0.01 && accumulation { check(copies>1,tag+" copies/processing") }; check(spacing<=1.5+0.0001,tag+" spacing") }
        if !enabled || Double(step)*profile.mmPerPoint<1.08 { check(g==0 && copies==1 && L==0,tag+" subthreshold unchanged") }
    }
    static func spikes(_ changes:[Double])->Int {
        guard changes.count>4 else { return 0 }; var count=0
        for k in 2..<(changes.count-2) {
            let a=[changes[k-2],changes[k-1],changes[k+1],changes[k+2]].sorted(),median=(a[1]+a[2])/2
            if changes[k]>8 && changes[k]>3*median+2 { count+=1 }
        }; return count
    }
    static func containsInk(_ bytes:[UInt8])->Bool {
        var n=0
        for i in stride(from:0,to:bytes.count,by:4) where max(bytes[i],bytes[i+1],bytes[i+2])>140 {n+=1;if n>32{return true}}
        return false
    }
    static func scene(_ name:String,scale:CGFloat,size:CGSize,output:URL) {
        let stores=[ConversationStore(),ConversationStore()]
        let mocks=stores.map{MockReplay(store:$0)};mocks.forEach{$0.start(live:false)}
        let scenes=stores.enumerated().map { i,store -> AutoScene in
            let s=AutoScene(size:size,store:store,profile:profile,scale:scale)
            s.columnExposureEnabled=i==1;s.manualSettle=true;s.restOnSnapshot=true;s.ambient=false;return s
        }
        var clock=10_000_000.0
        for s in scenes { s.now={clock};s.install();s.clock.invalidate() }
        defer { scenes.forEach{$0.disposeTranscriptPresentation()} }
        if name.hasPrefix("card-") { scenes.forEach{$0.columns.forEach{$0.cardBand=52...714}} }
        let renderers=scenes.map{OffscreenRenderer(size:size,host:$0.sceneView.layer!,scale:scale)}
        let initial=renderers.map{$0.render(at:clock-0.001)}
        check(initial.allSatisfy(containsInk),"\(name)/\(scale)x actual scene is not blank")
        check(initial[0]==initial[1],"\(name)/\(scale)x initial pixel diff 0")
        let start=clock
        let displaced=scenes[0].columns.last?.conversation.id
        func action(_ n:Int) {
            for s in scenes {
                if n==1 { s.switchTo(0,reason:"m10-reverse");continue }
                if n==2 { s.switchTo(2,reason:"m10-chain");continue }
                switch name {
                case "focused","card-focused":s.enterFocused(s.current,reason:"m10")
                case "land","land-reverse","card-land":if let id=s.order.dropFirst(s.columns.count).first {s.land(id,reason:"m10")}
                case "archive":if let c=s.columns.last?.conversation {c.archived=true;s.store.changed(c)}
                case "split":
                    s.enterFocused(s.current,reason:"m10");clock=s.transitionEnd+0.05;s.settle();clock=start
                    if let id=s.order.dropFirst(s.columns.count).first {s.graft(id,at:1,reason:"m10")}
                default:s.switchTo(1,reason:"m10")
                }
            }
        }
        // Split starts from a genuinely settled Focused endpoint in both runs, not a fake zero-time compound step.
        if name=="split" || name=="graft-focus" {
            for s in scenes {s.enterFocused(s.current,reason:"m10-setup")}
            clock=scenes.map(\.transitionEnd).max()!+0.05;scenes.forEach{$0.settle()};clock+=0.1
            for s in scenes {if let id=s.order.dropFirst(s.columns.count).first {s.graft(id,at:1,reason:"m10")}}
            if name=="graft-focus" {
                clock=scenes.map(\.transitionEnd).max()!+0.05;scenes.forEach{$0.settle()};clock+=0.1
                for s in scenes {if let id=s.scheme.split.first(where:{$0 != s.current}) {s.ungraft(id,reason:"m10-full-leave")}}
            }
        } else {action(0)}
        let began=clock
        func auditMaterials(_ phase:String) {
            for i in 0..<2 {
                let budget=scenes[i].columnRenderBudget()
                if i==1 { for c in scenes[i].columns where c.m10Frames["zoom"]?.allSatisfy({ $0.sample.count == 1 }) ?? true {
                    check(c.bakedInkFrames.isEmpty,"subthreshold presence has no texture preparation or stale tiles")
                }}
                check(budget.violations.isEmpty,"\(name)/\(scale)x \(i) render budget \(budget.violations)")
                rows.append(["scenario":name,"scale":scale,"enabled":i==1,"gpuBudget":budget.fields,"phase":phase])
                for tile in scenes[i].columnInkFrames() {
                    for f in tile {
                        check((f["spacingPt"] as? CGFloat ?? 0)<=1.5+0.0001,"material texture actual adjacent spacing <=1.5pt")
                        check(abs((f["interval"] as? Double ?? 0)-(f["referenceInterval"] as? Double ?? 0))<1e-9,"material texture same exposure interval")
                        check((f["coveredLengthPt"] as? CGFloat ?? 0)+0.001>=(f["referenceLengthPt"] as? CGFloat ?? 0),"material texture same exposure endpoints")
                    }
                    rows.append(["scenario":name,"scale":scale,"enabled":i==1,"inkFrames":tile,"phase":phase])
                }
            }
        }
        auditMaterials("initial")
        var previous=[[UInt8]?](repeating:nil,count:2),changes=[[Double](),[Double]()],k=0
        var tiles:[CGImage]=[],labels:[String]=[],didInterrupt=false,auditedInterruption=false,peak:CGFloat=0,maxGate:CGFloat=0,maxLength:CGFloat=0,maxCopies=1,maxSpacing:CGFloat=0,effectDifference=0.0,firstExact=false
        while k<240 {
            clock=began+Double(k)/60
            if !didInterrupt,name=="graft-focus",k>=8 {
                clock=began+0.12
                for s in scenes {if let id=s.order.dropFirst(s.columns.count).first {
                    let kept=s.current;s.graft(id,at:1,reason:"m10-full-return");s.ungraft(kept,reason:"m10-full-grow")
                }}
                clock=began+Double(k)/60;didInterrupt=true
            }
            if !didInterrupt,name=="land-reverse",k>=8,let displaced {
                clock=began+0.12;scenes.forEach{$0.land(displaced,reason:"m10-land-reverse")}
                clock=began+Double(k)/60;didInterrupt=true
            }
            if !didInterrupt,name=="reverse",k>=5 {action(1);didInterrupt=true}
            if !didInterrupt,name=="chain",k>=9 {action(2);didInterrupt=true}
            if didInterrupt && !auditedInterruption { auditMaterials("interrupted");auditedInterruption=true }
            var pair:[[UInt8]]=[]
            for i in 0..<2 {
                let bytes=renderers[i].render(at:clock);pair.append(bytes)
                if let before=previous[i] {changes[i].append(renderers[i].tileDiff(before,bytes).value)}
                previous[i]=bytes
                for frame in scenes[i].columnMotionFrames(at:clock) {
                    verify(frame.fields,enabled:i==1,tag:"\(name)/\(k)/\(frame.id)/\(i)")
                    rows.append(["scenario":name,"scale":scale,"frame":k,"time":clock-began,"enabled":i==1,"material":frame.fields])
                    if i==1 {peak=max(peak,frame.sample.stepPt);maxGate=max(maxGate,frame.sample.gate);maxLength=max(maxLength,frame.sample.length);maxCopies=max(maxCopies,(frame.fields["copies"] as? Int) ?? 1);maxSpacing=max(maxSpacing,frame.spacing)}
                }
            }
            effectDifference=max(effectDifference,renderers[0].tileDiff(pair[0],pair[1]).value)
            if k==0 {firstExact=pair[0]==pair[1];check(firstExact,"\(name)/\(scale)x first pixel diff 0")}
            if [1,2,3,4,6,9,15,24,40,60].contains(k) {tiles += (0..<2).map{renderers[$0].image(pair[$0])};labels += ["OFF · f\(k)","ON · f\(k)"]}
            k+=1
            if clock>scenes.map(\.transitionEnd).max()!+0.04 {break}
        }
        if name=="graft-focus" {check(didInterrupt && k>16,"full reflow + presence scenario actually exercised")}
        let last=previous.map{$0!}
        check(last[0]==last[1],"\(name)/\(scale)x last pixel diff 0")
        clock=scenes.map(\.transitionEnd).max()!+0.05;scenes.forEach{$0.settle()}
        let rested=(0..<2).map{renderers[$0].render(at:clock)}
        check(rested[0]==rested[1],"\(name)/\(scale)x settled pixel diff 0")
        for i in 0..<2 {check(renderers[i].tileDiff(last[i],rested[i]).value<=SelfTest.popThreshold,"\(name)/\(scale)x \(i) no handoff brightness/sharpness pop")}
        for i in 0..<2 {check(spikes(changes[i])==0,"\(name)/\(scale)x \(i==1 ? "on":"off") spike count \(spikes(changes[i]))")}
        if maxGate>0.1 {check(effectDifference>0,"\(name) treatment is actually rendered, not metadata only")}
        summaries.append(["scenario":name,"scale":scale,"frames":k,"peakStepPt":peak,"peakStepMM":Double(peak)*0.27,"maxGate":maxGate,"maxLengthPt":maxLength,"maxCopies":maxCopies,"maxSpacingPt":maxSpacing,"offSpikes":spikes(changes[0]),"onSpikes":spikes(changes[1]),"firstExact":firstExact,"lastExact":last[0]==last[1],"restExact":rested[0]==rested[1],"maxEffectTileDifference":effectDifference,
            "offChanges":changes[0],"onChanges":changes[1],"prepareOffMs":scenes[0].lastSwitch?["prepareMs"] ?? 0,"prepareOnMs":scenes[1].lastSwitch?["prepareMs"] ?? 0])
        contact(tiles,size:CGSize(width:320,height:205),columns:4,to:output.appendingPathComponent("\(name)@\(Int(scale))x.png"),labels:labels)
        print("M10 \(name) \(scale)x: \(k) frames, step \(peak), length \(maxLength), copies \(maxCopies), spikes \(spikes(changes[0]))/\(spikes(changes[1]))")
    }
    static func island(_ name:String,scale:CGFloat,output:URL) {
        let a=HeaderIsland(),b=HeaderIsland(),views=[a,b]
        let nativeHosts=views.map{_ in IslandPlane(frame:CGRect(x:0,y:0,width:960,height:420))}
        for i in 0..<2 {nativeHosts[i].addSubview(views[i])}
        let origin=CACurrentMediaTime()+3600
        var clock=origin
        for (i,v) in views.enumerated() {
            v.now={clock};v.motionProfile=profile;v.motionExposure.enabled=i==1
            v.configure(.init(id:"m10",title:"A native island · 原生列头",columnWidth:420,ambient:false,scale:scale))
        }
        defer{views.forEach{$0.dispose();$0.removeFromSuperview()}}
        let base=a.geometry
        let promotion=views.map{$0.beginPromotion(seedCenterY:280)}
        if name != "island-promotion" {views.forEach{$0.endPromotion()}}
        if name=="island-collapse" || name=="island-activity-out" {
            clock=origin-1
            if name=="island-collapse" {views.forEach{$0.setExpanded(true)}}
            else {views.forEach{$0.receive(.init(kind:.changes,text:"Edited 3 files",at:clock),at:clock)}}
            views.forEach{$0.sampleMotion(at:origin)};clock=origin
            if name=="island-collapse" {views.forEach{$0.setExpanded(false)}} else {views.forEach{$0.escape()}}
        }
        if name=="island-expand" || name=="island-retarget" {views.forEach{$0.setExpanded(true)}}
        if name=="island-activity" {views.forEach{$0.receive(.init(kind:.changes,text:"Edited 3 files",at:clock),at:clock)}}
        if name=="island-expand" {check(views.allSatisfy{$0.state.expanded && $0.motionIsRunning},"expanded surface actually animates its geometry")}
        let hosts=[CALayer(),CALayer()];hosts.forEach{$0.backgroundColor=Look.canvas.cgColor}
        let renders=hosts.map{OffscreenRenderer(size:CGSize(width:960,height:400),host:$0,scale:scale)}
        let planes=[CALayer(),CALayer()]
        for i in 0..<2 {let p=planes[i];p.anchorPoint = .zero;p.contentsScale=scale;p.contentsGravity = .resize;hosts[i].addSublayer(p)}
        var previous=[[UInt8]?](repeating:nil,count:2),changes=[[Double](),[Double]()],tiles:[CGImage]=[],labels:[String]=[]
        var peak:CGFloat=0,maxLength:CGFloat=0,maxCopies=1,maxSpacing:CGFloat=0
        for k in 0...90 {
            let t=Double(k)/60;clock=origin+t
            if name=="island-retarget",k==5 {views.forEach{$0.sampleMotion(at:clock);$0.setExpanded(false)}}
            let travel=Spring(from:0,to:420,response:0.42,damping:0.86,epsilon:0.01)
            for (i,v) in views.enumerated() {
                if name=="island-travel" {
                    v.frame.origin=CGPoint(x:travel.sample(t).value,y:0)
                    v.placeMotion(base,fontScale:1,earlier:base,earlierOrigin:CGPoint(x:travel.sample(max(0,t-1/60)).value,y:0),earlierFontScale:1)
                } else if name=="island-promotion",let plan=promotion[i] {
                    let p=plan.motionSample(elapsed:t),old=plan.motionSample(elapsed:max(0,t-1/60))
                    let height=ceil(max(v.frame.height,p.geometry.height)*scale)/scale
                    if p.revealTitle {v.revealPromotionTitle()}
                    v.frame.size.height=height
                    v.placeMotion(p.geometry,fontScale:p.fontScale,earlier:old.geometry,earlierOrigin:v.frame.origin,earlierFontScale:old.fontScale)
                    if k==90 {v.endPromotion()}
                } else {v.sampleMotion(at:clock)}
                check(!v.glassHasExposureTransform,"\(name) no glass transform or replication")
                let copies=v.motionGlyphLayer.instanceCount,step=CATransform3DGetAffineTransform(v.motionGlyphLayer.instanceTransform)
                var box=v.motionGlyphRect,spacing:CGFloat=0
                let initialBox=box
                if copies>1 {for _ in 1..<copies {let next=box.applying(step);spacing=max(spacing,MotionStep.edge(box,next));box=next}}
                check(spacing<=1.5+0.001,"\(name) actual affine copy spacing \(spacing)")
                if let record=v.motionRecords.first(where:{$0.material=="island.name"}) {
                    check(copies==record.sample.count,"\(name) actual replicator count")
                    check(MotionStep.edge(initialBox,box)+0.001>=record.sample.length,"\(name) actual last copy covers sweep")
                }
                for record in v.motionRecords {
                    let f=record.fields;verify(f,enabled:i==1,tag:"\(name)/\(k)/\(record.material)/\(i)")
                    if i==1 {peak=max(peak,MotionStep.edge(record.now,record.earlier));maxLength=max(maxLength,record.sample.length);maxCopies=max(maxCopies,(f["copies"] as? Int) ?? 1);maxSpacing=max(maxSpacing,(f["spacingPt"] as? CGFloat) ?? 0)}
                    rows.append(["scenario":name,"scale":scale,"frame":k,"time":t,"enabled":i==1,"material":f])
                    if record.material.contains("Glass") || record.material=="island.glass" || record.material=="island.lobe" {
                        let coverage=hypot(record.treated.width-record.now.width,record.treated.height-record.now.height)
                        check(coverage+0.001>=record.sample.length,"\(name) actual glass frame covers sweep")
                    }
                }
            }
            // Each run uses one independent canvas; the paired image is not a screenshot of an actual glass window.
            var bytes:[[UInt8]]=[]
            var native:[CGImage]=[]
            for i in 0..<2 {
                CATransaction.begin();CATransaction.setDisableActions(true)
                let source=views[i].snapshot(scale:scale);native.append(source);planes[i].contents=source
                planes[i].frame=CGRect(x:views[i].frame.minX,y:0,width:views[i].bounds.width,height:views[i].bounds.height)
                CATransaction.commit()
                let image=renders[i].render(at:origin+t);bytes.append(image)
                if ProcessInfo.processInfo.environment["M10_DUMP"]==name {
                    renders[i].write(image,output.appendingPathComponent("\(name)-\(i==1 ? "on":"off")-f\(k)@\(Int(scale))x.png"))
                    Offscreen.write(source,output.appendingPathComponent("\(name)-native-\(i==1 ? "on":"off")-f\(k)@\(Int(scale))x.png"))
                }
                if let old=previous[i] {changes[i].append(renders[i].tileDiff(old,image).value)};previous[i]=image
            }
            check(bytes.allSatisfy(containsInk),"\(name)/\(scale)x \(k) actual native glyphs are not blank")
            if k==0 || k==90 {check(native[0].dataProvider?.data == native[1].dataProvider?.data,"\(name)/\(scale)x \(k) native source pixel diff 0")}
            if k==0 || k==90 {check(bytes[0]==bytes[1],"\(name)/\(scale)x \(k==0 ? "first":"last") pixel diff 0")}
            if [0,1,2,3,5,8,12,20,35,60,90].contains(k) {tiles += (0..<2).map{renders[$0].image(bytes[$0])};labels += ["OFF · f\(k)","ON · f\(k)"]}
        }
        for i in 0..<2 {check(spikes(changes[i])==0,"\(name)/\(scale)x \(i==1 ? "on":"off") spike count \(spikes(changes[i]))")}
        check(peak>0,"\(name) exercised actual motion")
        summaries.append(["scenario":name,"scale":scale,"peakStepPt":peak,"peakStepMM":Double(peak)*0.27,"maxLengthPt":maxLength,"maxCopies":maxCopies,"maxSpacingPt":maxSpacing,"offSpikes":spikes(changes[0]),"onSpikes":spikes(changes[1]),"offChanges":changes[0],"onChanges":changes[1]])
        contact(tiles,size:CGSize(width:480,height:200),columns:4,to:output.appendingPathComponent("\(name)@\(Int(scale))x.png"),labels:labels)
    }
    static func edgeComparison(output:URL) {
        var half=ExposureSettings();half.shutter=0.5
        let exposure=M10ColumnExposure.pathSample(at:1,profile:profile,settings:half){t in CGRect(x:t*600,y:0,width:200,height:100)}
        check(abs(exposure.stepPt-10)<0.0001 && abs(exposure.length-5)<0.0001,"180 degree debug shutter retains physical gate, halves exposure length")
        check(exposure.delayStep*Double(exposure.count-1)<=profile.frameInterval/2+0.00001,"180 degree copies stay inside their actual exposure")
        let reveal=IslandControlsFade(from:0,to:1,began:0)
        check(reveal.value(at:0.099)==0 && reveal.value(at:0.191)==1,"M9 controls use product .1/.09 reveal")
        let alpha=reveal.value(at:0.14),retire=IslandControlsFade(from:reveal.value(at:0.14),to:0,began:0.14)
        check(retire.value(at:0.14)==alpha && retire.value(at:0.331)==0,"M9 controls reverse from sampled alpha, then retire")
        let bitmap=CGContext(data:nil,width:10,height:10,bitsPerComponent:8,bytesPerRow:40,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray:1,alpha:1));bitmap.fill(CGRect(x:2,y:2,width:5,height:5))
        let source=bitmap.makeImage()!
        var alphas:[UInt8]=[]
        for delta in [0.2,0.4,0.6,0.8] {
            let image=IslandGlyphBitmapPose.image(source,transform:CGAffineTransform(translationX:0,y:delta),width:10,height:10)!
            bitmap.clear(CGRect(x:0,y:0,width:10,height:10));bitmap.draw(image,in:CGRect(x:0,y:0,width:10,height:10))
            alphas.append(bitmap.data!.assumingMemoryBound(to:UInt8.self)[2*40+3*4+3])
        }
        check(zip(alphas,[51,102,153,204]).allSatisfy{abs(Int($0.0)-$0.1)<=1},"native moving glyph proxy has linear, not half-pixel-quantized reconstruction")
        let old=CGRect(x:40,y:30,width:280,height:120),now=old.offsetBy(dx:54,dy:0)
        let sample=M10ColumnExposure.sample(now,old,profile:profile,settings:.init()),sweep=M10ColumnExposure.Sweep.make(now,earlier:old,gate:sample.gate)
        let stretched=MotionStretch.rect(now:now,earlier:old,profile:profile)
        var images:[CGImage]=[]
        for stretch in [false,true] {
            let c=CGContext(data:nil,width:440,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(Look.canvas.cgColor);c.fill(CGRect(x:0,y:0,width:440,height:200))
            if stretch {c.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor);c.fill(stretched)}
            else {
                let colors=M10ColumnExposure.colors(NSColor.white.withAlphaComponent(0.35).cgColor,peak:sweep.peak) as CFArray
                let locations=sweep.locations.map{CGFloat(truncating:$0)}
                if let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:locations) {
                    c.saveGState();c.clip(to:sweep.frame);c.drawLinearGradient(gradient,start:CGPoint(x:sweep.frame.minX,y:90),end:CGPoint(x:sweep.frame.maxX,y:90),options:[]);c.restoreGState()
                }
            };images.append(c.makeImage()!)
        }
        check(abs(sweep.frame.width-now.width-sample.length)<0.0001,"edge ramp has full swept extent")
        let line=CGRect(x:100,y:0,width:1,height:120),r=M10ColumnExposure.Sweep.make(line,earlier:line.offsetBy(dx:-54,dy:0),gate:1)
        check(abs(r.peak-1/54)<0.00001,"separator conserves area, stretch would multiply brightness by55")
        contact(images,size:CGSize(width:440,height:200),columns:2,to:output.appendingPathComponent("gradient-left-vs-stretch-right.png"),labels:["Linear edge convolution","Solid stretch (rejected for large rectangles)"])
    }
    static func contact(_ images:[CGImage],size:CGSize,columns:Int,to url:URL,labels:[String]=[]) {
        guard !images.isEmpty else{return};let rows=(images.count+columns-1)/columns
        let labelHeight:CGFloat=24
        let w=Int(size.width)*columns,h=Int(size.height+labelHeight)*rows
        let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(Look.canvas.cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h))
        for (i,image) in images.enumerated() {
            let x=CGFloat(i%columns)*size.width,y=CGFloat(rows-1-i/columns)*(size.height+labelHeight)
            c.draw(image,in:CGRect(x:x,y:y,width:size.width,height:size.height))
            let text=i<labels.count ? labels[i]:(i%2==0 ? "OFF":"ON")
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.white]))
            c.textPosition=CGPoint(x:x+6,y:y+size.height+6);CTLineDraw(line,c)
        }
        Offscreen.write(c.makeImage()!,url)
    }
    static func weights() {
        let host=CALayer(),replicator=CAReplicatorLayer(),patch=CALayer()
        host.backgroundColor=Look.canvas.cgColor;host.addSublayer(replicator);replicator.addSublayer(patch)
        replicator.anchorPoint = .zero;replicator.frame=CGRect(x:0,y:0,width:64,height:64)
        patch.frame=CGRect(x:16,y:16,width:32,height:32);patch.backgroundColor=NSColor(srgbRed:0.6,green:0.25,blue:0.1,alpha:1).cgColor
        let renderer=OffscreenRenderer(size:CGSize(width:64,height:64),host:host)
        let began=CACurrentMediaTime()+3600,timeline=Timeline(began:0,duration:0.1,rate:120)
        let samples=timeline.times.map {t in M10ColumnExposure.sample(CGRect(x:max(0,sin(t/0.1 * .pi))*60,y:0,width:32,height:32),CGRect(x:0,y:0,width:32,height:32),profile:profile,settings:.init())}
        let before=renderer.render(at:began-0.01),centre=(32*64+32)*4
        CATransaction.begin();CATransaction.setDisableActions(true)
        timeline.track(replicator,"instanceCount",samples.map{NSNumber(value:$0.count)},discrete:true)?.start(at:began)
        M10ColumnExposure.colorTrack(timeline,on:replicator,samples:samples)?.start(at:began)
        CATransaction.commit()
        for k in 0...48 {
            let frame=renderer.render(at:began+Double(k)/480)
            // Compositing may approach the background in a channel where the background is brighter than the
            // patch. Its valid bound is the source/background convex hull, not the patch alone (blue25 vs bg30).
            check((0..<3).allSatisfy{Int(frame[centre+$0])<=max(Int(before[centre+$0]),Int(before[$0]))+2},"column equal weights stay inside source/background colour bounds between keys")
        }
    }
    static func spatialWeights() {
        let ctx=CGContext(data:nil,width:96,height:96,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(srgbRed:0.8,green:0.4,blue:0.2,alpha:1).cgColor);ctx.fill(CGRect(x:0,y:0,width:96,height:96))
        let bitmap=M10ColumnTexture.Bitmap(image:ctx.makeImage()!,rect:CGRect(x:32,y:32,width:96,height:96))
        let tl=Timeline(began:0,duration:0.4,rate:120),dt=1.0/60,prefix=Timeline(began:0,duration:0.4+dt,rate:120)
        let prototype=CAReplicatorLayer(),source=CALayer()
        func opacity(_ t:Double)->Double {min(1,max(0.1,1-t*2))}
        func matrix(_ t:Double)->CATransform3D {let s=0.25+0.75*opacity(t);return CATransform3DMakeAffineTransform(CGAffineTransform(a:s,b:0,c:0,d:s,tx:80*(1-s),ty:80*(1-s)))}
        var tracks:[Track]=[]
        if let t=prefix.track(source,"transform",prefix.map{NSValue(caTransform3D:matrix($0-dt))}) {tracks.append(Track(layer:source,key:"shell.m10-prefix|\(dt)|shell.transform",animation:t.animation))}
        if let t=prefix.track(source,"opacity",prefix.map{NSNumber(value:opacity($0-dt))}) {tracks.append(Track(layer:source,key:"shell.m10-prefix|\(dt)|shell.opacity",animation:t.animation))}
        let ns=tl.times.indices.map{$0==0 || $0==tl.times.count-1 ? 1:64}
        var sample=ExposureSample.still;sample.count=64;sample.alpha=CGFloat(1-pow(0.1,1/64.0))
        tracks.appendIf(tl.track(prototype,"instanceCount",ns.map{NSNumber(value:$0)},discrete:true))
        tracks.appendIf(tl.track(prototype,"instanceDelay",ns.map{NSNumber(value:$0>1 ? dt/63:0)}))
        tracks.appendIf(tl.track(prototype,"instanceColor",ns.map{$0>1 ? sample.instanceColor:NSColor.white.cgColor},discrete:true))
        tracks.appendIf(tl.track(prototype,"opacity",ns.map{NSNumber(value:$0>1 ? 1:0)}))
        let tile=M10ColumnInkTile.make(bitmap,scale:1,prototype:prototype,source:source,tracks:tracks)
        let host=CALayer();host.backgroundColor=NSColor.black.cgColor;host.addSublayer(tile.trail)
        let reference=CALayer();reference.anchorPoint = .zero;reference.frame=bitmap.rect.offsetBy(dx:160,dy:0);reference.contents=bitmap.image;reference.opacity=0;host.addSublayer(reference)
        let values=Array(tile.frames.prefix(tl.times.count)).map{NSNumber(value:1-($0["targetTransmission"] as? Double ?? 1))}
        let begin=CACurrentMediaTime()+3700
        for t in tile.tracks {M10ColumnExposure.start(t,at:begin)}
        if let t=tl.track(reference,"opacity",values) {t.start(at:begin)}
        let renderer=OffscreenRenderer(size:CGSize(width:320,height:160),host:host)
        for k in 3..<(tl.times.count-3) {
            let bytes=renderer.render(at:begin+tl.times[k]),a=(80*320+80)*4,b=(80*320+240)*4
            check((0..<3).allSatisfy{abs(Int(bytes[a+$0])-Int(bytes[b+$0]))<=3},"spatial scalar weights preserve opaque-ink transmission without animated-color premultiplication")
        }
        check(tile.tracks.allSatisfy{$0.animation.keyPath != "instanceDelay"},"spatial renderer has no per-copy animation clock")
    }

    static func glyphTextureFixture(output:URL) {
        for scale in [CGFloat(1),2] {
            let plane=IslandGlyphPlane(frame:CGRect(x:0,y:0,width:600,height:200));plane.forceTextureExposure=true;plane.textureScale=scale
            let source=IslandPlane(frame:plane.bounds),label=IslandLabel(labelWithString:"Native glyph texture")
            label.font = .systemFont(ofSize:13);label.textColor = .white;label.frame=CGRect(x:200,y:80,width:160,height:20)
            source.addSubview(label);plane.addSubview(source)
            let before=NativeViewBitmap.capture(plane,scale:scale)
            plane.warmingEnabled=false;plane.warmTextures()
            check(plane.captureCount==0,"disabled exposure never prewarms glyphs")
            plane.warmingEnabled=true;plane.warmTextures();let warmCaptures=plane.captureCount
            plane.update(now:label.frame,earlier:label.frame.offsetBy(dx:-40,dy:0),profile:profile,settings:ExposureSettings())
            let budget=M10ColumnRenderBudget.inspect(plane.layer!,scale:scale)
            check(budget.violations.isEmpty,"native glyph replica is flattened and tight")
            check(warmCaptures==1 && plane.captureCount==warmCaptures,"first moving frame never calls AppKit cacheDisplay for warmed glyphs")
            check(plane.textureTrail.bounds.width<=170 && plane.textureTrail.bounds.height<=30,"name exposure never copies the entire header canvas")
            check(plane.textureTrail.instanceCount==plane.sample.count && source.layer?.opacity==0,"native glyph source outside replicator is suppressed once")
            plane.layer?.backgroundColor=NSColor.black.cgColor
            let renderer=OffscreenRenderer(size:plane.bounds.size,host:plane.layer!,scale:scale)
            let pixels=renderer.render(at:CACurrentMediaTime()+5)
            check(stride(from:0,to:pixels.count,by:4).filter{max(pixels[$0],pixels[$0+1],pixels[$0+2])>20}.count>32,"real glyph texture renderer is not blank")
            renderer.write(pixels,output.appendingPathComponent("glyph-texture@\(Int(scale))x.png"))
            let blur=CIFilter(name:"CIGaussianBlur")!;blur.setValue(2,forKey:kCIInputRadiusKey)
            label.layer?.filters=[blur]
            plane.update(now:label.frame,earlier:label.frame.offsetBy(dx:-40,dy:0),profile:profile,settings:ExposureSettings())
            check(M10ColumnRenderBudget.inspect(plane.layer!,scale:scale).violations.isEmpty,"authored Gaussian is outside glyph replicas")
            check(plane.textureTrail.superlayer?.filters?.count==1 && label.layer?.filters?.count==1,"native Gaussian retained and applied once after glyph accumulation")
            label.layer?.filters=nil
            source.layer?.transform=CATransform3DMakeScale(1.4,1.4,1)
            let expected=source.layer!.convert(label.frame.insetBy(dx:-4,dy:-4),to:plane.layer!)
            plane.update(now:expected,earlier:expected.offsetBy(dx:-40,dy:0),profile:profile,settings:ExposureSettings())
            let first=plane.textureTrail.convert(plane.textureTrail.bounds,to:plane.layer!)
            let second=plane.textureTrail.convert(plane.textureTrail.bounds.applying(CATransform3DGetAffineTransform(plane.textureTrail.instanceTransform)),to:plane.layer!)
            check(MotionStep.edge(first,expected)<0.001,"baked glyph front preserves native zoom pose")
            check(MotionStep.edge(second,first.applying(CATransform3DGetAffineTransform(plane.trail.layer.instanceTransform)))<0.001,"canonical glyph replay is conjugate to the screen-space path")
            source.layer?.transform=CATransform3DIdentity
            plane.reset();plane.layer?.backgroundColor=nil
            let after=NativeViewBitmap.capture(plane,scale:scale)
            check(before.dataProvider?.data as Data? == after.dataProvider?.data as Data?,"glyph texture return to native is byte-identical")
            check(source.layer?.opacity==1 && plane.textureTrail.isHidden,"native glyph state restored at rest")
        }
    }

    static func liveLayerFixture() {
        for display in [profile,DisplayProfile(name:"Built-in Retina cost fixture",frameInterval:1/120,mmPerPoint:0.199,persistenceFrames:0)] {
        let store=ConversationStore()
        let replay=MockReplay(store:store);replay.start(live:false)
        let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:display,scale:2)
        scene.restOnSnapshot=false;scene.ambient=false;scene.manualSettle=true
        var time=CACurrentMediaTime()+3600;scene.now={time};scene.install();scene.clock.invalidate();scene.prewarm()
        if let id=scene.order.dropFirst(scene.columns.count).first {
            scene.land(id,reason:"m10-native-layer-source")
            let column=scene.columns.first{$0.conversation.id==id}
            if column?.m10Frames["zoom"]?.contains(where:{$0.sample.count>1}) == true {
                check(column?.bakedPresence.isEmpty == false,"entering native-header column has baked body ink, not just the fallback planet")
            } else {check(column?.bakedPresence.isEmpty == true,"actual-display subthreshold entrance needs no texture")}
            let budget=scene.columnRenderBudget()
            check(budget.violations.isEmpty,"actual-display native cost fixture passes")
            print("NATIVE BUDGET",display.summary,budget.fields)
            check((column?.presenceTrail.animationKeys() ?? []).isEmpty,"reference exposure curves never start detached server animation clocks")
            print("NATIVE SOURCE",scene.columnState)
        }
        time=scene.transitionEnd+1;scene.settle();scene.disposeTranscriptPresentation()
        }
    }

    static func renderBudget() {
        for hz in [60.0,120.0] {
            let layer=CALayer(),a=CAKeyframeAnimation(keyPath:"opacity");a.values=[0,1];a.keyTimes=[0,1];a.duration=0.42
            let originalRate=a.preferredFrameRateRange
            M10ColumnExposure.start(Track(layer:layer,key:"shell.rate",animation:a),at:CACurrentMediaTime(),frameInterval:1/hz)
            check(a.preferredFrameRateRange.minimum==originalRate.minimum && a.preferredFrameRateRange.maximum==originalRate.maximum && a.preferredFrameRateRange.preferred==originalRate.preferred,"exposure leaves the original CA scheduling hint unchanged")
        }
        // The old structure fails twice: native/masked subtree, and millions of padded pixels per copy.
        let old=CAReplicatorLayer();old.bounds=CGRect(x:0,y:0,width:600,height:700);old.instanceCount=81
        let masked=CALayer();masked.mask=CALayer();masked.addSublayer(CAGradientLayer());old.addSublayer(masked)
        let first=M10ColumnRenderBudget.inspect(old,scale:2)
        check(first.violations.contains{$0.contains("mask")},"old live mask rejected")
        check(first.violations.contains{$0.contains("unflattened")},"old vector drawing rejected")
        check(first.violations.contains{$0.contains("pixel-rate budget")},"old whole-column area rejected")
        // A model-one/hidden layer with animated count/opacity must still be charged to the budget.
        let count=CAKeyframeAnimation(keyPath:"instanceCount");count.values=[1,81,1];count.keyTimes=[0,0.5,1];count.duration=1
        let alpha=CAKeyframeAnimation(keyPath:"opacity");alpha.values=[0,1,0];alpha.keyTimes=count.keyTimes;alpha.duration=1
        old.instanceCount=1;old.opacity=0;old.add(count,forKey:"count");old.add(alpha,forKey:"opacity")
        check(!M10ColumnRenderBudget.inspect(old,scale:2).violations.isEmpty,"animated cost counted despite resting model-one/hidden state")
        old.removeAllAnimations();old.instanceCount=81;old.opacity=1
        old.sublayers=[]
        let c=CGContext(data:nil,width:1200,height:1400,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let flat=CALayer();flat.contents=c.makeImage();old.addSublayer(flat)
        let retained=CAReplicatorLayer();retained.instanceCount=81;retained.bounds=CGRect(x:0,y:0,width:140,height:18)
        let cropped=CALayer();cropped.bounds=retained.bounds;cropped.contents=c.makeImage()!.cropping(to:CGRect(x:17,y:90,width:140,height:18));retained.addSublayer(cropped)
        check(M10ColumnRenderBudget.inspect(retained,scale:1).violations.contains{$0.contains("stride")},"logical small crop retaining full source stride is rejected")
        check(!M10ColumnRenderBudget.inspect(old,scale:2).violations.isEmpty,"one flattened but padded full-column texture still rejected")
        let temporal=CAReplicatorLayer();temporal.instanceCount=81;temporal.instanceDelay=0.001;temporal.bounds=CGRect(x:0,y:0,width:10,height:10)
        let animated=CALayer();temporal.addSublayer(animated)
        for key in ["opacity","transform.scale"] {let a=CAKeyframeAnimation(keyPath:key);a.values=[1,0.25];a.keyTimes=[0,1];a.duration=1;animated.add(a,forKey:key)}
        check(M10ColumnRenderBudget.inspect(temporal,scale:2).violations.contains{$0.contains("timeline")},"small flattened texture still fails when replaying its source animations per copy")
        temporal.instanceDelay=0
        check(M10ColumnRenderBudget.inspect(temporal,scale:2).violations.isEmpty,"same tight source evaluated once passes spatial replay budget")
        for scale in [CGFloat(1),CGFloat(2)] {
            let source=CALayer();source.bounds=CGRect(x:0,y:0,width:300,height:700)
            for r in [CGRect(x:10,y:20,width:140,height:18),CGRect(x:40,y:580,width:220,height:22)] {
                let l=CALayer();l.anchorPoint = .zero;l.frame=r;l.backgroundColor=NSColor.orange.cgColor;source.addSublayer(l)
            }
            let tiles=M10ColumnTexture.bake(source,scale:scale)
            var copies:[ObjectIdentifier:CALayer]=[:]
            let clone=M10ColumnTexture.clone(source,into:&copies)
            check(clone.bounds==source.bounds && clone.sublayers?.count==2,"clone preserves geometry and source tree")
            let cloned=M10ColumnTexture.bake(clone,scale:scale)
            check(cloned.map{$0.rect}==tiles.map{$0.rect},"detached model clone preserves all nonempty ink, not just metadata")
            check(source.sublayers?.allSatisfy{$0.superlayer===source} == true,"baking never reparents native model ink")
            check(tiles.count==2,"two separated ink bands, no empty column height")
            check(tiles.allSatisfy{$0.image.bytesPerRow==$0.image.width*4 && CFDataGetLength($0.image.dataProvider!.data!)==$0.image.width*$0.image.height*4},"tight images own exactly their RGBA pixels, no retained canvas stride")
            check(tiles.map{$0.image.width*$0.image.height}.reduce(0,+)==Int((140*18+220*22)*scale*scale),"native-scale nonempty pixels preserved")
            check(tiles.first?.rect==CGRect(x:10,y:20,width:140,height:18),"top-down bake orientation and first ink band")
            check(tiles.last?.rect==CGRect(x:40,y:580,width:220,height:22),"bottom ink band is not vertically reversed")
        }
    }

    /// Compare what CA actually displays before/after baking, not just band rectangles or symmetric fills.
    /// Both consumers use the same flipped host, so renderer/image orientation cannot cancel the bake error.
    static func textureOrientation(output:URL) {
        for scale in [CGFloat(1),CGFloat(2)] { for flipped in [false,true] {
            let tag="@\(Int(scale))x-\(flipped ? "flipped":"unflipped")"
            let size=CGSize(width:240,height:180), host=CALayer(),source=CALayer(),baked=CALayer()
            source.anchorPoint = .zero;source.frame=CGRect(origin:.zero,size:size);host.addSublayer(source)
            baked.anchorPoint = .zero;baked.frame=source.bounds;baked.isHidden=true;host.addSublayer(baked)
            let w=Int(120*scale),h=Int(60*scale)
            let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Deliberately asymmetric within each band, including a transparent hole and unequal left/right ends.
            c.scaleBy(x:scale,y:scale)
            c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:0,y:0,width:120,height:12))
            c.setFillColor(NSColor.green.cgColor);c.fill(CGRect(x:8,y:12,width:110,height:29))
            c.setFillColor(NSColor.blue.cgColor);c.fill(CGRect(x:21,y:41,width:80,height:19))
            c.clear(CGRect(x:42,y:18,width:17,height:13))
            let image=c.makeImage()!
            for (index,origin) in [CGPoint(x:12,y:18),CGPoint(x:84,y:108)].enumerated() {
                let ink=CALayer();ink.anchorPoint = .zero;ink.frame=CGRect(origin:origin,size:CGSize(width:120,height:60))
                ink.contentsScale=scale;ink.contents=image;ink.isGeometryFlipped=index==1;source.addSublayer(ink)
            }
            let renderer=OffscreenRenderer(size:size,host:host,scale:scale),time=CACurrentMediaTime()+3600
            host.isGeometryFlipped=flipped
            let before=renderer.render(at:time)
            var copies:[ObjectIdentifier:CALayer]=[:]
            let detached=M10ColumnTexture.clone(source,into:&copies)
            let tiles=M10ColumnTexture.bake(detached,scale:scale)
            for bitmap in tiles {
                let r=bitmap.rect,trail=CAReplicatorLayer(),ink=CALayer()
                trail.anchorPoint = .zero;trail.bounds=CGRect(origin:.zero,size:r.size);trail.position=r.origin
                // Same untransformed texture placement as M10ColumnInkTile.make; no proxy redraw of the source.
                ink.bounds=trail.bounds;ink.anchorPoint=CGPoint(x:-r.minX/r.width,y:-r.minY/r.height)
                ink.position=CGPoint(x:-r.minX,y:-r.minY);ink.contentsScale=scale;ink.contents=bitmap.image
                trail.addSublayer(ink);baked.addSublayer(trail)
            }
            CATransaction.begin();CATransaction.setDisableActions(true);source.isHidden=true;baked.isHidden=false;CATransaction.commit()
            let after=renderer.render(at:time+0.1)
            let differing=zip(before,after).filter{$0 != $1}.count
            check(tiles.count==2,"orientation fixture contains two nonempty asymmetric bands \(tag)")
            check(before==after,"CA source→detached clone→bake→texture orientation pixel diff 0 \(tag); differing bytes \(differing)")
            renderer.write(before,output.appendingPathComponent("orientation-source\(tag).png"))
            renderer.write(after,output.appendingPathComponent("orientation-baked\(tag).png"))
            contact([renderer.image(before),renderer.image(after)],size:size,columns:2,
                to:output.appendingPathComponent("orientation-roundtrip\(tag).png"),labels:["Original CA source","Baked CA texture"])
            check(detached.superlayer==nil,"baking restores the detached clone's ownership \(tag)")
            check(source.superlayer===host,"baking does not reparent the real source \(tag)")
            print("ORIENTATION \(tag): \(differing) differing bytes")
        }}
    }

    /// Actual native scene entry points, injected 120Hz clock and glyph textures, without a window/backdrop.
    /// This distinguishes post-commit cacheDisplay from CA replica area; neither is presented-frame timing.
    static func nativeMotionCosts(output:URL) {
        HeaderIsland.forceMotionTexturesForVerification=true
        defer {HeaderIsland.forceMotionTexturesForVerification=false}
        let display=DisplayProfile(name:"Built-in120Hz native fixture",frameInterval:1/120,mmPerPoint:0.2,persistenceFrames:0)
        var reports:[[String:Any]]=[]
        for scenario in ["newchat","auto","land-third"] { for enabled in [false,true] {
            autoreleasepool {
                let store=ConversationStore();let replay=MockReplay(store:store);replay.start(live:false)
                let scene=AutoScene(size:CGSize(width:1280,height:820),store:store,profile:display,scale:2)
                scene.restOnSnapshot=false;scene.columnExposureEnabled=enabled;scene.ambient=false;scene.manualSettle=true
                var time=CACurrentMediaTime()+3600;scene.now={time};scene.install();scene.clock.invalidate()
                defer {scene.disposeTranscriptPresentation()}
                @MainActor func synchronize() {time=scene.transitionEnd+0.1;scene.clock.onFrame?(time);scene.settle()}
                @MainActor func clocks() {for c in scene.columns {c.island?.now={time}}}
                clocks()
                if scenario=="newchat" {
                    scene.newChat();synchronize()
                    scene.onCreate={text,_ in Conversation(id:"native-cost-new",title:text)}
                    scene.onSubmit={c,r,done in c.items.append(.init(id:"first-user",kind:.user,text:r.text,running:false));store.changed(c);done(.accepted);return true}
                    scene.composers.draft().composer.setText("Draft a plan for the onboarding tour")
                } else if scenario=="land-third",let id=scene.order.dropFirst(scene.columns.count).first {
                    scene.land(id,reason:"fixture-land-1");synchronize();scene.activate(id,reason:"fixture-land-2");synchronize()
                }
                scene.prewarm();clocks()
                let preparation=CACurrentMediaTime()
                if scenario=="newchat" {scene.composers.draft().composer.submit()}
                else {scene.switchTo(scenario=="auto" ? 1:0,reason:"native-cost-"+scenario)}
                let prepareMs=(CACurrentMediaTime()-preparation)*1000
                clocks()
                let began=time
                var frames:[[String:Any]]=[],busy:[Double]=[]
                let initialCaptures=scene.columns.compactMap(\.island).map{$0.motionGlyphMaterial.captureCount}.reduce(0,+)
                let initialCaptureMs=scene.columns.compactMap(\.island).map{$0.motionGlyphMaterial.captureTimeMs}.reduce(0,+)
                let initialBudget=scene.columnRenderBudget()
                for k in 0...150 {
                    time=began+Double(k)/120
                    let start=CACurrentMediaTime();scene.clock.onFrame?(time);busy.append((CACurrentMediaTime()-start)*1000)
                    let glyphs=scene.columns.compactMap(\.island).map{$0.motionGlyphMaterial.textureCosts}
                    var total:[String:Int]=[:]
                    for row in glyphs {for (key,value) in row {total[key,default:0]+=value}}
                    frames.append(["frame":k,"time":time-began,"glyphs":total])
                }
                let endCaptures=scene.columns.compactMap(\.island).map{$0.motionGlyphMaterial.captureCount}.reduce(0,+)
                let captureMs=scene.columns.compactMap(\.island).map{$0.motionGlyphMaterial.captureTimeMs}.reduce(0,+)-initialCaptureMs
                let peakPixels=frames.map{($0["glyphs"] as! [String:Int])["replicatedPixels"] ?? 0}.max() ?? 0
                let peakCopies=frames.map{($0["glyphs"] as! [String:Int])["replicas"] ?? 0}.max() ?? 0
                let report:[String:Any]=["scenario":scenario,"enabled":enabled,"prepareMs":prepareMs,"prepareBreakdown":scene.lastSwitch?["prepareBreakdown"] ?? [:],
                    "frameP95Ms":busy.sorted()[Int(Double(busy.count-1)*0.95)],"frameMaxMs":busy.max() ?? 0,"movingCaptures":endCaptures-initialCaptures,"movingCaptureMs":captureMs,
                    "peakGlyphPixels":peakPixels,"peakGlyphCopies":peakCopies,"columns":initialBudget.fields,"frames":frames]
                reports.append(report)
                if enabled {check(endCaptures==initialCaptures,"native \(scenario) has no cacheDisplay in motion frames")}
                check(scene.columns.allSatisfy{$0.island != nil},"native \(scenario) exercises mounted HeaderIsland")
                print("NATIVE MOTION COST",scenario,enabled,"prepare",prepareMs,"p95",report["frameP95Ms"]!,"max",report["frameMaxMs"]!,"captures",endCaptures-initialCaptures,"captureMs",captureMs,"pixels",peakPixels,"copies",peakCopies,"columns",initialBudget.fields)
                time=max(time,scene.transitionEnd)+0.1;scene.settle()
            }
        }}
        try? JSONSerialization.data(withJSONObject:["boundary":"offscreen native placements/texture counts; no WindowServer glass or presented-FPS claim","profile":display.summary,"scenarios":reports],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native-motion-costs.json"))
    }

    static func cost(output:URL) {
        var costs=[[Double](),[Double]()]
        let g=HeaderIslandGeometry.make(variant:.full,columnWidth:420,state:.init(titleWidth:160,band:44,scale:2))
        for enabled in 0..<2 {
            let v=HeaderIsland();v.configure(.init(id:"cost",title:"Cost probe",columnWidth:420,ambient:false));v.motionProfile=profile;v.motionExposure.enabled=enabled==1
            for n in 0..<240 {
                let dx=CGFloat(n%2)*30;v.frame.origin.x=dx
                let start=CACurrentMediaTime()
                v.placeMotion(g,fontScale:1,earlier:g,earlierOrigin:CGPoint(x:30-dx,y:0),earlierFontScale:1)
                let elapsed=(CACurrentMediaTime()-start)*1000
                if n>=40 {costs[enabled].append(elapsed)}
            };v.dispose()
        }
        let p95=costs.map{$0.sorted()[Int(Double($0.count-1)*0.95)]}
        let result:[String:Any]=["unit":"ms","offP95":p95[0],"onP95":p95[1],"additionalP95":p95[1]-p95[0],"samples":200,"boundary":"offscreen native placement CPU only; real NSGlass SDF/WindowServer/drop count requires host recording"]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.appendingPathComponent("cost.json"))}
    }
}
