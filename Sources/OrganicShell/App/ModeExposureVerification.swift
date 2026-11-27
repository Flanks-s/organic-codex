#if M10_MODE_SELFTEST
import AppKit
import ImageIO
import Metal
import QuartzCore

/// Standalone, windowless M10-A verification. No AppController, Main or network transport is constructed.
@main @MainActor enum M10ModeVerification {
    static var checks = 0, failures: [String] = []
    static let dell = DisplayProfile(name: "Dell 60 Hz", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0)
    static let size = CGSize(width: 1280, height: 820)
    static var csv = "scenario,enabled,frame,object,step_pt,step_mm,gate,copies,copy_alpha,stretch_pt,coverage_pt,max_copy_gap_pt,x,y,width,height\n"
    static var summary: [[String: Any]] = []
    static var renderPeaks: [String: Double] = [:]

    static func check(_ v: Bool, _ label: String) { checks += 1; if !v { failures.append(label); print("FAIL: " + label) } }
    static func png(_ image: CGImage, _ url: URL) {
        let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, image, nil); check(CGImageDestinationFinalize(dst), "write " + url.lastPathComponent)
    }
    static func bytes(_ image: CGImage) -> [UInt8] { Array(image.dataProvider!.data! as Data) }
    static func isUnitTransform(_ t: CATransform3D) -> Bool {
        let values = [t.m11-1,t.m12,t.m13,t.m14,t.m21,t.m22-1,t.m23,t.m24,t.m31,t.m32,t.m33-1,t.m34,t.m41,t.m42,t.m43,t.m44-1]
        return values.allSatisfy { abs($0)<1e-12 }
    }
    static func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a,b).map { abs(Int($0)-Int($1)) }.max() ?? 0 }
    static func span(_ r: M10ModeFrameSample) -> (CGFloat, CGFloat) {
        guard r.exposure.count > 1 else { return (0,0) }
        let t = CATransform3DGetAffineTransform(r.instanceTransform)
        // The transform is glass-local; bring the box into the same coordinates before applying it.
        var box = r.now.offsetBy(dx: -r.painted.minX, dy: -r.painted.minY)
        let first = box
        var gap: CGFloat = 0
        for _ in 1..<r.exposure.count { let next = box.applying(t); gap=max(gap,MotionStep.edge(box,next));box=next }
        return (MotionStep.edge(first,box),gap)
    }

    static func validate(_ r: M10ModeFrameSample, enabled: Bool, scenario: String, frame: Int) {
        let treated = enabled && !(ModeFlight.orreryEnabled && r.id != "composer")
        let step = r.step, expected = treated ? smoothstep(1.08, 2.7, Double(step)*dell.mmPerPoint):0
        check(abs(Double(r.exposure.gate)-expected)<1e-8,"\(scenario) \(frame) \(r.id) gate")
        if expected == 0 {
            check(r.painted == r.now && r.exposure.count == 1 && r.exposure.alpha == 1,
                  "\(scenario) \(frame) \(r.id) exact untreated pose")
        } else {
            // Up to the cap the glass covers its sweep; past it, it stops growing (a 40 pt orb was a 200 pt capsule, user 10-30).
            let cap=MotionStretch.maxReach*min(r.now.width,r.now.height)
            check(r.stretch+1e-5 >= min(step*CGFloat(expected),cap),"\(scenario) \(frame) \(r.id) glass sweep continuity")
            check(r.stretch <= cap*2.squareRoot()+1e-5,"\(scenario) \(frame) \(r.id) glass reach stays capped")
        }
        let glyph = r.id != "composer", value = glyph ? span(r):(r.stretch,CGFloat(0))
        if expected > 0, glyph {
            check(value.0+1e-4 >= step*CGFloat(expected),"\(scenario) \(frame) \(r.id) glyph sweep continuity")
            check(value.1 <= 1.50001,"\(scenario) \(frame) \(r.id) glyph spacing")
        }
        csv += "\(scenario),\(enabled),\(frame),\(r.id),\(step),\(Double(step)*0.27),\(r.exposure.gate),\(r.id == "composer" ? 1:r.exposure.count),\(r.id == "composer" ? 1:r.exposure.alpha),\(r.stretch),\(value.0),\(value.1),\(r.now.minX),\(r.now.minY),\(r.now.width),\(r.now.height)\n"
    }

    static func flight(_ forward: Bool, enabled: Bool, clock: @escaping () -> Double) -> ModeFlight {
        let f=ModeFlight();f.manualTime=clock;f.exposureEnabled=enabled;f.resize(to:size)
        let c=MockSeed.make()[0];c.running=false
        let row=CGRect(x:26,y:116,width:16,height:16), orb=CGRect(x:1040,y:766,width:40,height:40)
        let second=CGRect(x:26,y:244,width:16,height:16), bar=CGRect(x:590,y:770,width:32,height:32)
        f.start(toOrganic:forward,avatar:forward ? (CGRect(x:25,y:740,width:26,height:26),CGRect(x:420,y:765,width:36,height:36)):
                (CGRect(x:420,y:765,width:36,height:36),CGRect(x:25,y:740,width:26,height:26)),initials:"LL",
                tokens:[.init(id:"orb",conversation:c,from:forward ? row:orb,to:forward ? orb:row,start:0.08,absorbed:!forward),
                        .init(id:"bar",conversation:c,from:forward ? second:bar,to:forward ? bar:second,start:0.12,absorbed:!forward || !ModeFlight.orreryEnabled)],
                composer:forward ? (CGRect(x:300,y:654,width:720,height:120),CGRect(x:564,y:770,width:530,height:40),0):nil,
                reduceMotion:false)
        return f
    }

    static func spikes(_ values: [Double]) -> Int {
        guard values.count>5 else { return 0 };var n=0
        for k in 2..<(values.count-2) {
            let around=[values[k-2],values[k-1],values[k+1],values[k+2]].sorted(),m=(around[1]+around[2])/2
            if values[k]>8 && values[k]>3*m+2 { n+=1 }
        }
        return n
    }

    static func modes(_ output: URL, scale: CGFloat) {
        for forward in [true,false] {
            let name=forward ? "hide":"show",dir=output.appendingPathComponent("\(name)-\(Int(scale))x")
            try! FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let off=flight(forward,enabled:false,clock:{1000}),on=flight(forward,enabled:true,clock:{1000})
            var samplesOff:[M10ModeFrameSample]=[],samplesOn:[M10ModeFrameSample]=[]
            off.onExposureSample={samplesOff.append($0)};on.onExposureSample={samplesOn.append($0)}
            let root=CALayer(),renderer=M10ModeRenderer(size:size,root:root,scale:scale)
            root.backgroundColor=NSColor(white:0.09,alpha:1).cgColor
            var previousOff:[UInt8]?,previousOn:[UInt8]?,deltasOff:[Double]=[],deltasOn:[Double]=[]
            var contact:[(CGImage,CGImage,String)]=[], peaks:[String:(CGFloat,CGFloat,Int,CGFloat,CGFloat)]=[:]
            var previousPaint:[String:CGRect]=[:]
            var sourceFrames:[String:CGRect]=[:],sourceCounts:[String:Int]=[:]
            var details:[String:[(CGImage,CGImage,String)]]=[:],lastPose:[String:CGRect]=[:]
            let count=Int(ceil(max(off.duration,on.duration)*60))+2
            for k in 0...count {
                let t=Double(k)/60;samplesOff=[];samplesOn=[]
                off.sample(at:t,profile:dell);on.sample(at:t,profile:dell)
                for (id,glass) in on.verificationGlass where !glass.isHidden {
                    check(isUnitTransform(glass.layer?.transform ?? CATransform3DIdentity),"\(id) glass has no scale transform beyond native floating-point roundoff")
                    var ancestor=glass.superview
                    while let v=ancestor {check(!(v is M10ModeGlyphTrail),"glass is never inside a glyph replicator");ancestor=v.superview}
                }
                for (id,trail) in on.verificationTrails {
                    if id.hasPrefix("planet"),let body=trail.subviews.first {
                        if sourceCounts[id,default:1]>1,trail.exposure.count>1,let old=sourceFrames[id] {
                            check(body.frame==old,"suppressed orb source never resizes per frame")
                        }
                        sourceFrames[id]=body.frame;sourceCounts[id]=trail.exposure.count
                    }
                    if trail.exposure.count>1 {
                        let image=trail.flattenedImage
                        check(image != nil,"\(id) exposure has a baked image")
                        if let image {
                            let raw=bytes(image)
                            check(stride(from:3,to:raw.count,by:4).contains(where:{raw[$0]>0}),"\(id) baked ink is not empty outside the native source frame")
                        }
                    }
                }
                var framePixels = 0.0
                for (id, glass) in on.verificationGlass where !glass.isHidden {
                    if let layer = glass.contentView?.layer {
                        let budget = M10ModeRenderBudget.inspect(layer, scale:scale)
                        check(budget.violations.isEmpty, "\(name) \(k) \(id) flat compositor subtree: \(budget.violations)")
                        framePixels += max(budget.replicatedPixels,budget.sampledTexturePixels)
                    }
                }
                renderPeaks[name] = max(renderPeaks[name] ?? 0,framePixels)
                check(framePixels <= M10ModeRenderBudget.pixelLimit, "mode whole-frame replicated pixel budget")
                check(samplesOff.map(\.now)==samplesOn.map(\.now),"\(name) \(k) exposure never changes logical path")
                for r in samplesOff { validate(r,enabled:false,scenario:name,frame:k) }
                for r in samplesOn {
                    validate(r,enabled:true,scenario:name,frame:k)
                    let p=peaks[r.id] ?? (0,0,1,0,0)
                    let paintedStep=previousPaint[r.id].map{MotionStep.edge($0,r.painted)} ?? 0
                    previousPaint[r.id]=r.painted
                    lastPose[r.id]=r.now
                    peaks[r.id]=(max(p.0,r.step),max(p.1,r.stretch),max(p.2,r.id == "composer" ? 1:r.exposure.count),max(p.3,r.id == "composer" ? 0:span(r).1),max(p.4,paintedStep))
                }
                func render(_ f: ModeFlight) -> ([UInt8],CGImage) {
                    root.sublayers?.forEach{$0.removeFromSuperlayer()}
                    let restore=f.verificationPaint(into:root,scale:scale,elapsed:t)
                    let b=renderer.render(at:VerificationClock.renderOrigin+t);let image=renderer.image(b)
                    restore();return(b,image)
                }
                let a=render(off),b=render(on)
                if k==0 {
                    if ModeFlight.orreryEnabled {
                        check(on.verificationContentIsSeparated,"D 0.3 content is independent of sharp glass opacity")
                    } else {
                        let restore=off.verificationOriginalMounts(),original=render(off)
                        restore()
                        check(maxDiff(a.0,original.0)==0,"\(name) \(Int(scale))x direct M9 mounts == one-copy M10 mounts")
                    }
                }
                if k==0 || k==count {check(maxDiff(a.0,b.0)==0,"\(name) \(Int(scale))x endpoint pixels identical")}
                if let old=previousOff {deltasOff.append(renderer.tileDiff(old,a.0))}
                if let old=previousOn {deltasOn.append(renderer.tileDiff(old,b.0))}
                previousOff=a.0;previousOn=b.0
                if scale==1 {
                    png(a.1,dir.appendingPathComponent(String(format:"off-%03d.png",k)))
                    png(b.1,dir.appendingPathComponent(String(format:"on-%03d.png",k)))
                    if k%3==0 || k==count {contact.append((a.1,b.1,String(format:"frame %02d  t %.3f",k,t)))}
                    if k%3==0 || k==count {
                        for id in ["me","planet.orb","composer"] {
                            guard let pose=lastPose[id] else {continue}
                            let w:CGFloat=id == "composer" ? 760:360,h:CGFloat=id == "composer" ? 240:420
                            let crop=CGRect(x:min(size.width-w,max(0,pose.midX-w/2)),y:min(size.height-h,max(0,pose.midY-h/2)),width:w,height:h).integral
                            details[id,default:[]].append((a.1.cropping(to:crop)!,b.1.cropping(to:crop)!,String(format:"%@ frame %02d t %.3f",id,k,t)))
                        }
                    }
                }
            }
            let a=spikes(deltasOff),b=spikes(deltasOn)
            check(a==0 && b==0,"\(name) \(Int(scale))x spikes off/on \(a)/\(b)")
            summary.append(["scenario":name,"scale":scale,"spikesOff":a,"spikesOn":b,
                            "avatarHandoffSeconds":on.avatarHandoff,"oldAvatarHandoffSeconds":ModeFlight.handoff,
                            "stepsOff":deltasOff,"stepsOn":deltasOn,
                            "objects":peaks.mapValues{["maxStepPt":$0.0,"maxStretchPt":$0.1,"maxCopies":$0.2,"maxCopyGapPt":$0.3,"maxPaintedBoxStepPt":$0.4]}])
            if scale==1 { montage(contact,output:output.appendingPathComponent("\(name)-before-after.png")) }
            if scale==1 {for (id,frames) in details {detailMontage(frames,output:output.appendingPathComponent("\(name)-\(id)-detail.png"))}}
            off.shutdown();on.shutdown()
        }
    }

    static func sidebar(_ output: URL, scale: CGFloat) {
        let host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size));host.wantsLayer=true
        host.layer?.backgroundColor=NSColor(white:0.09,alpha:1).cgColor
        let source=SidebarFixture(frame:CGRect(x:0,y:0,width:280,height:820));source.wantsLayer=true;host.addSubview(source)
        let exposure=M10SidebarExposure(),renderer=M10ModeRenderer(size:size,root:CALayer(),scale:scale)
        let cache=NativeViewBitmap.capture(source,scale:scale)
        var contact:[(CGImage,CGImage,String)]=[]
        for showing in [false,true] {
            let name=showing ? "sidebar-in":"sidebar-out"
            let initial=CGRect(x:showing ? -280:0,y:0,width:280,height:820)
            source.frame=initial
            let lease=exposure.begin(source:source,in:host,driven:false,scale:scale)!
            var oldOff:[UInt8]?,oldOn:[UInt8]?,offD:[Double]=[],onD:[Double]=[]
            var peak:CGFloat=0,maxGap:CGFloat=0,copies=1
            for k in 0...30 {
                let t=Double(k)/60,u=min(1,t/0.25),ease=u*u*(3-2*u)
                let r=CGRect(x:showing ? -280+280*ease:-280*ease,y:0,width:280,height:820)
                let before=k==0 ? r:CGRect(x:showing ? -280+280*powEase(max(0,t-1/60)/0.25):-280*powEase(max(0,t-1/60)/0.25),y:0,width:280,height:820)
                source.frame=r
                let opacity:Float = showing ? 1 : Float(1-powEase(t/0.22))
                exposure.sample(rect:r,at:t,profile:dell,alpha:opacity)
                let sample=M10ModeFrameSample(id:"sidebar",time:t,now:r,earlier:before,painted:r,
                    exposure:exposure.glyphs.exposure,instanceTransform:exposure.glyphs.trail.layer.instanceTransform)
                check(exposure.glyphs.trail.layer.animationKeys()?.isEmpty != false,"sidebar driver A never installs implicit geometry animations")
                let budget=M10ModeRenderBudget.inspect(exposure.renderingLayer,scale:scale)
                check(exposure.plane.layer?.opacity==1 && exposure.renderingLayer.bounds.size==r.size,"sidebar fades only a tight source-sized group")
                check(budget.maxIntermediatePixels<=Double(r.width*r.height*scale*scale)+1e-5,"sidebar alpha intermediate never has full-window bounds")
                renderPeaks[name] = max(renderPeaks[name] ?? 0,max(budget.replicatedPixels,budget.sampledTexturePixels))
                check(budget.violations.isEmpty, "sidebar flat compositor budget: \(budget.violations)")
                let step=MotionStep.edge(r,before),gate=smoothstep(1.08,2.7,Double(step)*0.27)
                check(abs(Double(sample.exposure.gate)-gate)<1e-8,"\(name) \(k) physical gate")
                let s=span(sample)
                if gate>0 {check(s.0+1e-5>=step*CGFloat(gate) && s.1<=1.50001,"\(name) \(k) coverage/spacing")}
                else {check(exposure.plane.isHidden && source.layer?.opacity==1,"\(name) \(k) real sidebar restored below onset")}
                peak=max(peak,step);maxGap=max(maxGap,s.1);copies=max(copies,sample.exposure.count)
                csv += "\(name),true,\(k),sidebar,\(step),\(Double(step)*0.27),\(gate),\(sample.exposure.count),\(sample.exposure.alpha),0,\(s.0),\(s.1),\(r.minX),\(r.minY),\(r.width),\(r.height)\n"
                func render(_ enabled:Bool)->([UInt8],CGImage) {
                    let root=renderer.root;root.sublayers?.forEach{$0.removeFromSuperlayer()};root.backgroundColor=NSColor(white:0.09,alpha:1).cgColor
                    if !enabled || exposure.plane.isHidden {
                        let image=CALayer();image.contents=cache;image.frame=r;image.opacity=opacity;root.addSublayer(image)
                    } else {
                        let layer=exposure.renderingLayer,parent=layer.superlayer
                        root.addSublayer(layer)
                        let bytes=renderer.render(at:VerificationClock.renderOrigin+t)
                        parent?.addSublayer(layer);return(bytes,renderer.image(bytes))
                    }
                    let bytes=renderer.render(at:VerificationClock.renderOrigin+t);return(bytes,renderer.image(bytes))
                }
                let a=render(false),b=render(true)
                if k==0 || k==30 {check(maxDiff(a.0,b.0)==0,"\(name) \(scale)x endpoint exact")}
                if let old=oldOff {offD.append(renderer.tileDiff(old,a.0))};if let old=oldOn {onD.append(renderer.tileDiff(old,b.0))}
                oldOff=a.0;oldOn=b.0
                if scale==1,k%2==0 {contact.append((a.1,b.1,"\(name) frame \(k) step \(String(format:"%.2f",step)) pt"))}
            }
            let a=spikes(offD),b=spikes(onD);check(a==0 && b==0,"\(name) spikes off/on \(a)/\(b)")
            summary.append(["scenario":name,"scale":scale,"maxStepPt":peak,"maxCopies":copies,"maxCopyGapPt":maxGap,"spikesOff":a,"spikesOn":b])
            exposure.finish(lease);check(source.layer?.opacity==1 && exposure.image.contents==nil && exposure.lease==nil,"sidebar finish releases capture/restores real opacity")
        }
        if scale==1 {
            montage(contact,output:output.appendingPathComponent("sidebar-before-after.png"))
            let crop=CGRect(x:0,y:0,width:310,height:400)
            detailMontage(contact.map{($0.0.cropping(to:crop)!,$0.1.cropping(to:crop)!,$0.2)},output:output.appendingPathComponent("sidebar-text-detail.png"))
        }
        // Stale completion, missed frame, actual glass exclusion and no idle clock.
        source.frame=CGRect(x:0,y:0,width:280,height:820)
        let a=exposure.begin(source:source,in:host,driven:false)!,b=exposure.begin(source:source,in:host,driven:false)!
        exposure.finish(a);check(exposure.lease==b,"old completion cannot clear new sidebar leg")
        exposure.sample(rect:source.frame,at:0,profile:dell)
        source.frame=source.frame.offsetBy(dx:100,dy:0)
        exposure.sample(rect:source.frame,at:0.1,profile:dell)
        check(exposure.droppedSample && exposure.plane.isHidden,"missed frame is reported and never concealed by a longer shutter")
        exposure.finish(b)
        let glass=NSGlassEffectView();source.addSubview(glass)
        check(exposure.begin(source:source,in:host,driven:false)==nil,"sidebar never captures glass into replicator")
    }

    static func powEase(_ u: Double)->Double {let v=min(1,max(0,u));return v*v*(3-2*v)}

    static func montage(_ frames:[(CGImage,CGImage,String)],output:URL) {
        let width=768,height=frames.count*272
        let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor(white:0.14,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:width,height:height))
        for (i,f) in frames.enumerated() {
            let y=height-(i+1)*272
            c.draw(f.0,in:CGRect(x:0,y:y,width:384,height:246));c.draw(f.1,in:CGRect(x:384,y:y,width:384,height:246))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
            (f.2+" · OFF                              ON · glass = proxy" as NSString).draw(at:CGPoint(x:8,y:y+249),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),.foregroundColor:NSColor.white])
            NSGraphicsContext.restoreGraphicsState()
        }
        png(c.makeImage()!,output)
    }

    static func detailMontage(_ frames:[(CGImage,CGImage,String)],output:URL) {
        guard let first=frames.first else {return}
        let w=first.0.width,h=first.0.height,row=h+26,width=w*2,height=row*frames.count
        let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor(white:0.14,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:width,height:height))
        for (i,f) in frames.enumerated() {
            let y=height-(i+1)*row
            c.draw(f.0,in:CGRect(x:0,y:y,width:w,height:h));c.draw(f.1,in:CGRect(x:w,y:y,width:w,height:h))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
            (f.2+" · OFF / ON · 1:1 pixels" as NSString).draw(at:CGPoint(x:8,y:y+h+5),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),.foregroundColor:NSColor.white])
            NSGraphicsContext.restoreGraphicsState()
        }
        png(c.makeImage()!,output)
    }

    static func costs() {
        var clock=1000.0
        let off=flight(true,enabled:false,clock:{clock}),on=flight(true,enabled:true,clock:{clock})
        var a:[Double]=[],b:[Double]=[]
        var perOff:[String:[Double]]=[:],perOn:[String:[Double]]=[:]
        off.onExposureCost={id,seconds in perOff[id,default:[]].append(seconds*1000)}
        on.onExposureCost={id,seconds in perOn[id,default:[]].append(seconds*1000)}
        let p=DisplayProfile(name:"MBP nominal",frameInterval:1/120,mmPerPoint:0.20,persistenceFrames:0)
        for k in 0..<3000 {
            if k%100 == 0 { off.verificationRearmAvatar();on.verificationRearmAvatar() }
            let t=Double(k%100)/120;clock=1000+t
            let start=CACurrentMediaTime();off.sample(at:t,profile:p);let mid=CACurrentMediaTime();on.sample(at:t,profile:p);let end=CACurrentMediaTime()
            if k>=200 {a.append((mid-start)*1000);b.append((end-mid)*1000)}
        }
        func percentile(_ x:[Double],_ f:Double)->Double{x.sorted()[min(x.count-1,Int(Double(x.count-1)*f))]}
        summary.append(["scenario":"main-thread-sampler-cost","samples":a.count,"offP95ms":percentile(a,0.95),"onP95ms":percentile(b,0.95),"p95IncreaseMs":percentile(b,0.95)-percentile(a,0.95),"scope":"sampler and frame writes only; excludes WindowServer glass layout/presented frames"])
        check(percentile(b,0.95)-percentile(a,0.95)<0.5,"sampler p95 increment below 0.5 ms")
        for id in perOff.keys.sorted() {
            let x=percentile(perOff[id]!,0.95),y=percentile(perOn[id]!,0.95)
            summary.append(["scenario":"cost."+id,"offP95ms":x,"onP95ms":y,"p95IncreaseMs":y-x])
            check(y-x<0.5,"\(id) p95 increment below 0.5 ms")
        }
        off.shutdown();on.shutdown()
        // Sidebar frame work and one-time capture are separate costs, never attributed to every frame.
        let host=ModeFlight.Plane(frame:CGRect(origin:.zero,size:size))
        let sourceA=SidebarFixture(frame:CGRect(x:0,y:0,width:280,height:820)),sourceB=SidebarFixture(frame:sourceA.frame)
        host.addSubview(sourceA);host.addSubview(sourceB)
        let sa=M10SidebarExposure(),sb=M10SidebarExposure()
        let captureStart=CACurrentMediaTime();_ = sa.begin(source:sourceA,in:host,driven:false,scale:2);_ = sb.begin(source:sourceB,in:host,driven:false,scale:2)
        let captureMs=(CACurrentMediaTime()-captureStart)*500
        sa.enabled=false
        a=[];b=[]
        for k in 0..<3000 {
            let t=Double(k)/120,r=CGRect(x:-140+140*sin(t*8),y:0,width:280,height:820)
            let begin=CACurrentMediaTime();sa.sample(rect:r,at:t,profile:p);let mid=CACurrentMediaTime();sb.sample(rect:r,at:t,profile:p);let end=CACurrentMediaTime()
            if k>=200 {a.append((mid-begin)*1000);b.append((end-mid)*1000)}
        }
        summary.append(["scenario":"cost.sidebar","offP95ms":percentile(a,0.95),"onP95ms":percentile(b,0.95),
                        "p95IncreaseMs":percentile(b,0.95)-percentile(a,0.95),"captureMeanMs":captureMs])
        check(percentile(b,0.95)-percentile(a,0.95)<0.5,"sidebar sampler p95 increment below 0.5 ms")
        sa.finish();sb.finish()
    }

    static func contracts() {
        let r=CGRect(x:100,y:100,width:80,height:40),trail=M10ModeGlyphTrail(frame:CGRect(x:0,y:0,width:500,height:500))
        for hz in [60.0,120,144] {
            let p=DisplayProfile(name:"injected",frameInterval:1/hz,mmPerPoint:0.27,persistenceFrames:0)
            for i in 0...1200 {
                let d=CGFloat(i)/100,old=r.offsetBy(dx:-d,dy:0),s=M10ModeExposure.sample(r,old,profile:p,enabled:true)
                let expected=smoothstep(1.08,2.7,Double(d)*0.27)
                check(abs(Double(s.gate)-expected)<1e-9,"\(hz) Hz continuous physical gate")
                trail.update(now:r,earlier:old,profile:p,enabled:true)
                if expected==0 {check(trail.trail.layer.instanceCount==1 && CATransform3DIsIdentity(trail.trail.layer.instanceTransform),"below-onset actual CA identity")}
                else {check(trail.exposure.count>1 && M10ModeExposure.stretch(r,old,profile:p,enabled:true) != r,"no finite cutoff in onset tail")}
            }
        }
        // A real zoom and translation must end at the linearly gated older box, without compound-centre drift.
        for ratio:CGFloat in [0.1,0.5,1,2,5] {
            let old=CGRect(x:82,y:88,width:r.width*ratio,height:r.height*ratio)
            trail.update(now:r,earlier:old,profile:dell,enabled:true)
            let s=M10ModeFrameSample(id:"zoom",time:0,now:r,earlier:old,painted:.zero,exposure:trail.exposure,instanceTransform:trail.trail.layer.instanceTransform)
            let v=span(s)
            check(v.0+1e-4>=MotionStep.edge(r,old)*trail.exposure.gate && v.1<=1.50001,"zoom coverage and adjacent corner spacing")
        }
        // Reversing from a stretched glass frame must not contaminate either new logical source.
        var clock=1000.0
        let a=flight(true,enabled:false,clock:{clock}),b=flight(true,enabled:true,clock:{clock})
        var recordsA:[M10ModeFrameSample]=[],recordsB:[M10ModeFrameSample]=[]
        a.onExposureSample={recordsA.append($0)};b.onExposureSample={recordsB.append($0)}
        a.sample(at:0.15,profile:dell);b.sample(at:0.15,profile:dell);clock+=0.15
        let c=MockSeed.make()[0]
        recordsA=[];recordsB=[]
        for f in [a,b] {
            f.start(toOrganic:false,avatar:(.zero,CGRect(x:25,y:740,width:26,height:26)),initials:"LL",
                    tokens:[.init(id:"orb",conversation:c,from:.zero,to:CGRect(x:26,y:116,width:16,height:16),start:0,absorbed:true)],composer:nil,reduceMotion:false)
            f.sample(at:0,profile:dell)
        }
        check(recordsA.map(\.now)==recordsB.map(\.now),"reverse starts from identical logical poses with exposure on/off")
        a.shutdown();b.shutdown()
        let shifted=flight(false,enabled:true,clock:{clock})
        var at=0.0,previous:[String:CGRect]=[:],shiftRecords:[M10ModeFrameSample]=[]
        shifted.targetShift={CGPoint(x:-280*max(0,1-at/0.25),y:0)}
        shifted.onExposureSample={shiftRecords.append($0)}
        for i in 0...45 {
            at=Double(i)/60;shiftRecords=[];shifted.sample(at:at,profile:dell)
            for r in shiftRecords {
                if let old=previous[r.id] {check(MotionStep.edge(old,r.earlier)<1e-5,"moving sidebar target uses its actually observed earlier pose")}
                previous[r.id]=r.now
            }
        }
        shifted.shutdown()
    }

    static func headerFlights(_ output: URL) {
        let conversation = MockSeed.make()[0]
        for scale: CGFloat in [1, 2] {
            for diameter: CGFloat in [44, 56] {
                for forward in [false, true] {
                    let row = CGRect(x: 26, y: 150, width: 16, height: 16)
                    let header = CGRect(x: 420, y: 24, width: diameter, height: diameter)
                    let token = ModeFlight.Token(id: "header." + conversation.id, conversation: conversation,
                                                 from: forward ? row : header, to: forward ? header : row,
                                                 start: 0.08, absorbed: !forward)
                    let cold = ModeFlight(), hot = ModeFlight()
                    for f in [cold, hot] { f.manualTime = { 1000 }; f.resize(to: size) }
                    hot.prewarm(tokens: [token])
                    for f in [cold, hot] {
                        f.start(toOrganic: forward, avatar: (row, header), initials: "LL", tokens: [token], composer: nil, reduceMotion: false)
                    }
                    check(hot.consumedPreparedTokens == 1, "header consumes its prepared glyph/glass resource")
                    let renderer = M10ModeRenderer(size: size, root: CALayer(), scale: scale)
                    renderer.root.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
                    var samples: [M10ModeFrameSample] = []
                    hot.onExposureSample = { samples.append($0) }
                    var samePixels = true
                    let count = ModeFlight.orreryEnabled ? Int(ceil(max(cold.duration,hot.duration)*60))+1 : 42
                    for index in 0...count {
                        let t = Double(index) / 60
                        samples = []
                        cold.sample(at: t, profile: dell); hot.sample(at: t, profile: dell)
                        for sample in samples { validate(sample, enabled: true, scenario: "header.\(diameter).\(forward)", frame: index) }
                        for (_, glass) in hot.verificationGlass where !glass.isHidden {
                            if let content = glass.contentView?.layer {
                                check(M10ModeRenderBudget.inspect(content, scale: scale).violations.isEmpty, "header flight has no replicated container")
                            }
                        }
                        if index % 12 == 0 || index == count {
                            let paintTime = VerificationClock.renderOrigin + t
                            func render(_ f: ModeFlight) -> [UInt8] {
                                renderer.root.sublayers?.forEach { $0.removeFromSuperlayer() }
                                // Compare just the newly prewarmed token. me's separate native gradient capture can
                                // quantize by one byte between draws; its original M10-A checks run unchanged above.
                                let restore = f.verificationPaint(into: renderer.root, scale: scale, elapsed: t, includeAvatar: false)
                                let result = renderer.render(at: paintTime)
                                restore(); return result
                            }
                            let a = render(cold), b = render(hot)
                            samePixels = samePixels && maxDiff(a, b) == 0
                            if index == 12, scale == 1, diameter == 56 {
                                png(renderer.image(b), output.appendingPathComponent("header-\(forward ? "in" : "out").png"))
                                png(renderer.image(a), output.appendingPathComponent("header-\(forward ? "in" : "out")-cold.png"))
                            }
                        }
                    }
                    check(samePixels, "\(scale)x header \(diameter) prewarming is pixel-identical to cold production glyph baking")
                    hot.shutdown(); cold.shutdown()
                }
            }
        }
    }

    static func main() {
        _ = NSApplication.shared;NSApp.appearance=NSAppearance(named:.darkAqua)
        let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "runs/m10-mode")
        try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        if CommandLine.arguments.contains("--headers-only") {
            headerFlights(output)
            print("M10.4: \(checks) checks, \(failures.count) findings")
            exit(failures.isEmpty ? 0 : 1)
        }
        contracts()
        check(!isUnitTransform(CATransform3DMakeScale(1.001,1,1)),"negative: visible glass scaling is rejected")
        let sourceURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("ModeExposure.swift")
        let source=(try? String(contentsOf:sourceURL,encoding:.utf8)) ?? ""
        let bake=source.components(separatedBy:"private func flattenNativeContent").dropFirst().first?.components(separatedBy:"func reset()").first ?? ""
        check(!bake.isEmpty && !bake.contains(".displayIfNeeded(") && !bake.contains(".layoutSubtreeIfNeeded("),"bitmap bake never forces AppKit/window layout")
        let old = CAReplicatorLayer();old.bounds=CGRect(origin:.zero,size:size);old.instanceCount=20
        let oldGlyph=CAShapeLayer();oldGlyph.shadowOpacity=1;old.addSublayer(oldGlyph)
        let oldFade=CALayer();oldFade.bounds=CGRect(origin:.zero,size:size);oldFade.opacity=0.5;oldFade.addSublayer(old)
        let rejected=M10ModeRenderBudget.inspect(oldFade,scale:2)
        check(rejected.maxIntermediatePixels>Double(280*820*4),"regression: old faded window-sized proxy has an oversized intermediate")
        check(rejected.replicatedPixels > M10ModeRenderBudget.pixelLimit,"regression: old full-window replica exceeds pixel budget")
        check(rejected.violations.contains(where:{$0.contains("shadow")}),"regression: old live orb shadow rejected")
        check(rejected.violations.contains(where:{$0.contains("unflattened")}),"regression: old vector subtree rejected")
        for scale:CGFloat in [1,2] {modes(output,scale:scale);sidebar(output,scale:scale)}
        headerFlights(output)
        costs()
        summary.append(["scenario":"compositor-budget","limitPixels":M10ModeRenderBudget.pixelLimit,"peakPixels":renderPeaks,
                        "scope":"max(instance count × backing quad area, instance count × source CGImage area); visible replica subtrees contain no AppKit backing / vectors / shadows / filters / masks / backdrop"])
        check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible windows created")
        try! csv.write(to:output.appendingPathComponent("frames.csv"),atomically:true,encoding:.utf8)
        let report:[String:Any]=["checks":checks,"findings":failures,"profile":["Hz":60,"mmPerPoint":0.27],"results":summary,
                                "renderScope":"production non-glass subtrees and draw paths in CARenderer; glass is an explicit proxy; sidebar geometry is an injected split movement, not WindowServer proof"]
        try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
        print("M10-A: \(checks) checks, \(failures.count) findings; \(output.path)")
        exit(failures.isEmpty ? 0:1)
    }

    final class SidebarFixture: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white:0.16,alpha:1).setFill();bounds.fill()
            for (k,text) in ["Search chats", "Projects", "Organic Animation", "M10 · Mode flights", "Sidebar", "Long history", "Louis L.   Plus"].enumerated() {
                (text as NSString).draw(at:CGPoint(x:24,y:CGFloat(k)*52+36),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:k==2 ? .medium:.regular),.foregroundColor:NSColor(white:0.86,alpha:1)])
            }
        }
    }
}

/// The same CARenderer/Metal readback method as App/SelfTest; no App executable or window is started.
@MainActor final class M10ModeRenderer {
    let root: CALayer
    private let texture:MTLTexture,queue:MTLCommandQueue,renderer:CARenderer
    let width:Int,height:Int
    private var warmed=false
    init(size:CGSize,root:CALayer,scale:CGFloat) {
        self.root=root;width=Int(size.width*scale);height=Int(size.height*scale)
        let device=MTLCreateSystemDefaultDevice()!;queue=device.makeCommandQueue()!
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        desc.usage=[.renderTarget,.shaderRead];desc.storageMode = .managed;texture=device.makeTexture(descriptor:desc)!
        renderer=CARenderer(mtlTexture:texture,options:[kCARendererMetalCommandQueue:queue])
        let outer=CALayer();outer.anchorPoint = .zero;outer.bounds=CGRect(x:0,y:0,width:width,height:height)
        renderer.layer=outer;renderer.bounds=outer.bounds;CATransaction.flush()
        root.anchorPoint = .zero;root.bounds=CGRect(origin:.zero,size:size);root.position = .zero;root.isGeometryFlipped=true
        root.transform=CATransform3DMakeScale(scale,scale,1);outer.addSublayer(root);CATransaction.flush()
    }
    func render(at time:Double)->[UInt8] {
        CATransaction.flush();if !warmed {warmed=true;_ = render(at:time)}
        renderer.beginFrame(atTime:time,timeStamp:nil);renderer.addUpdate(renderer.bounds);renderer.render();renderer.endFrame()
        let cmd=queue.makeCommandBuffer()!,blit=cmd.makeBlitCommandEncoder()!;blit.synchronize(resource:texture);blit.endEncoding();cmd.commit();cmd.waitUntilCompleted()
        var bytes=[UInt8](repeating:0,count:width*height*4)
        texture.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
        return (0..<height).reversed().flatMap{bytes[($0*width*4)..<(($0+1)*width*4)]}
    }
    func image(_ b:[UInt8])->CGImage {CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue),provider:CGDataProvider(data:Data(b) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!}
    func tileDiff(_ a:[UInt8],_ b:[UInt8])->Double {
        var best=0.0
        for y in stride(from:0,to:height,by:16) {for x in stride(from:0,to:width,by:16) {
            var sum=0,n=0
            for yy in y..<min(height,y+16) {for xx in x..<min(width,x+16) {
                let i=(yy*width+xx)*4;sum+=abs(Int(a[i])-Int(b[i]))+abs(Int(a[i+1])-Int(b[i+1]))+abs(Int(a[i+2])-Int(b[i+2]));n+=3
            }}
            best=max(best,Double(sum)/Double(n))
        }}
        return best
    }
}
#endif
