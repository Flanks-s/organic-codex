#if OVERLAY_SELFTEST
import AppKit

@MainActor enum OverlayM101Verification {
    private static func views(_ v:NSView)->[NSView] {[v]+v.subviews.flatMap(views)}
    private static func layers(_ l:CALayer)->[CALayer] {[l]+(l.sublayers ?? []).flatMap(layers)}
    private static func peakCopies(_ root:CALayer)->Int {
        layers(root).compactMap{$0 as? CAReplicatorLayer}.map {r in
            let a=r.animation(forKey:"overlay.exposure.instanceCount") as? CAKeyframeAnimation
            return max(r.instanceCount,(a?.values as? [NSNumber])?.map(\.intValue).max() ?? 1)
        }.max() ?? 0
    }
    private static func cost(_ root:CALayer,scale:CGFloat,native:NSView?=nil)->[String:Any] {
        var copied=0.0,filtered=0.0,filters=0,enhanced=0
        func maximumRadius(_ layer:CALayer,_ name:String)->Double {
            var maximum=0.0
            func scan(_ a:CAAnimation) {
                if let group=a as? CAAnimationGroup {group.animations?.forEach(scan)}
                if let p=a as? CAPropertyAnimation,p.keyPath=="filters."+name+".inputRadius" {
                    if let k=p as? CAKeyframeAnimation {maximum=max(maximum,(k.values as? [NSNumber])?.map(\.doubleValue).max() ?? 0)}
                    if let b=p as? CABasicAnimation {maximum=max(maximum,(b.fromValue as? NSNumber)?.doubleValue ?? 0,(b.toValue as? NSNumber)?.doubleValue ?? 0)}
                }
            };for key in layer.animationKeys() ?? [] {if let a=layer.animation(forKey:key) {scan(a)}}
            return maximum
        }
        let nativeViews=native.map(views) ?? []
        var all=layers(root),bounds:[ObjectIdentifier:CGRect]=[:]
        for v in nativeViews {if let l=v.layer {all+=layers(l);bounds[ObjectIdentifier(l)]=v.bounds}}
        var seen=Set<ObjectIdentifier>()
        for l in all where seen.insert(ObjectIdentifier(l)).inserted {
            if let r=l as? CAReplicatorLayer {
                let count=peakCopies(r)
                let area=layers(r).filter{$0.contents != nil}.reduce(0.0){$0+Double($1.bounds.width*$1.bounds.height*scale*scale)}
                copied+=area*Double(count)
            }
            for f in l.filters ?? [] {
                guard let o=f as? NSObject,o.responds(to:NSSelectorFromString("name")),let name=o.value(forKey:"name") as? String,
                      name.hasPrefix("m101ContentGaussian") || name=="overlayBlur" else {continue}
                filters+=1;if name.hasPrefix("m101ContentGaussian") {enhanced+=1}
                let padding=CGFloat(3*maximumRadius(l,name)),box=(bounds[ObjectIdentifier(l)] ?? l.bounds).insetBy(dx:-padding,dy:-padding)
                filtered+=Double(box.width*box.height*scale*scale)
            }
        }
        return ["maxCopies":peakCopies(root),"copiesTimesPixels":copied,"gaussianExpandedPixels":filtered,"contentFiltersIncludingProduct":filters,"newGaussianFilters":enhanced]
    }
    static func run(output:URL,check:(Bool,String)->Void)throws {
        let saved=OverlayExposure.enabled,mode=OverlayZoom.verificationOverride
        defer {OverlayExposure.enabled=saved;OverlayZoom.verificationOverride=mode}
        let directory=output.appendingPathComponent("appearance");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var audit:[[String:Any]]=[],metrics:[[String:Any]]=[],traces="scenario,mode,scale,frame,time,tileStep,enhancedRadius,enhancedOpacity\n"
        let selected=[0,1,2,3,4,5,6,9,15,24,36,48]
        for scenario in ["picker-in","picker-out","send-in","peek-row-adapter-in"] {
            for scale:CGFloat in [1,2] {
                var sheets:[[CGImage]]=[],allSheets:[[CGImage]]=[],firstReference:[UInt8]?,lastReference:[UInt8]?
                for variant in ["off","accum","gauss"] {
                    OverlayExposure.enabled=variant != "off";OverlayZoom.verificationOverride=variant == "accum" ? .accum:.gauss
                    FileHandle.standardOutput.write(Data("begin \(scenario) \(variant) \(scale)x\n".utf8))
                    let clock=OverlayManualClock(),scene=SceneClock(),mount=CALayer()
                    let size=scenario.hasPrefix("peek") ? CGSize(width:520,height:130):CGSize(width:1080,height:900)
                    let renderer=OverlayM101Renderer(size:size,root:mount,scale:scale)
                    let host=OverlayView(frame:CGRect(origin:.zero,size:size)),picker=OverlayModelPicker(clock:clock),send=OverlaySendOptions(clock:clock)
                    host.wantsLayer=true
                    var settings=ModelSettings();settings.modelID="g61sol";settings.effort = .ultra
                    picker.configure(settings:settings,models:ModelCatalog.mockModels)
                    let anchor=CGRect(x:650,y:830,width:158,height:28)
                    for surface in [picker as OverlaySurface,send] {surface.sceneClock=scene;surface.sceneTime={renderer.origin+clock.now};surface.exposureProfile=OverlayExposure.dell}
                    var row:OverlayAccumulatingView?,appearance:OverlayContentAppearance?
                    let source:CALayer
                    if scenario.hasPrefix("peek") {
                        let v=OverlayAccumulatingView(frame:CGRect(x:20,y:30,width:480,height:44)),label=OverlayStyle.label("Read-only thread · review the latest result",size:19,weight:.medium)
                        label.frame=v.bounds;v.ink.addSubview(label);host.addSubview(v);v.layoutSubtreeIfNeeded();row=v
                        if variant == "gauss" {appearance=OverlayContentAppearance(content:v.layer!,clock:scene);_=appearance?.setVisible(true,at:renderer.origin)}
                        else {
                            // Product Peek's 18pt / .55 response / .92 damping, with no container or filter copies.
                            for (key,from) in [("transform.translation.y",18.0),("opacity",0.0)] {
                                let a=CASpringAnimation(keyPath:key),w=2*Double.pi/0.55;a.mass=1;a.stiffness=w*w;a.damping=2*0.92*w;a.duration=a.settlingDuration
                                a.fromValue=from;a.toValue=key == "opacity" ? 1:0;a.beginTime=renderer.origin;a.fillMode = .backwards;v.motionLayer.add(a,forKey:"peek.fixture."+key)
                            }
                            if variant == "accum" {v.accumulate(enabled:true)}
                        }
                        source=host.layer!
                    } else if scenario.hasPrefix("send") {
                        send.present(anchor:anchor,in:host);source=send.layer!
                    } else {
                        picker.present(anchor:anchor,in:host);picker.reasoning.stopAmbient();source=picker.layer!
                        if scenario.hasSuffix("out") {clock.advance(by:1);picker.dismiss()}
                    }
                    let began=scenario.hasSuffix("out") ? 1.0:0
                    let mirror=OverlayM101Mirror(scale:scale,startTime:renderer.origin,view:scenario.hasPrefix("peek") ? host:scenario.hasPrefix("send") ? send:picker)
                    var nonempty=false
                    var previous:[UInt8]?,first:[UInt8]?,last:[UInt8]?,steps:[Double]=[],tiles:[CGImage]=[],allTiles:[CGImage]=[]
                    let nativeRoot:NSView=scenario.hasPrefix("peek") ? host:scenario.hasPrefix("send") ? send:picker
                    let preCost=cost(source,scale:scale,native:nativeRoot)
                    for frame in 0...48 {
                        let t=Double(frame)/60
                        clock.advance(by:max(0,began+t-clock.now))
                        host.layoutSubtreeIfNeeded()
                        if let appearance {_=appearance.settle(at:renderer.origin+began+t)}
                        let found=ReplicaContainerAudit.inspect(source,scenario:scenario+"-"+variant,frame:frame,time:renderer.origin+began+t)
                        audit+=found.map(\.fields);check(found.isEmpty,"M10.1 source container audit \(scenario) \(variant) \(frame)")
                        if [0,6,48].contains(frame) {
                            for view in views(nativeRoot) {if let l=view.layer {
                                let f=ReplicaContainerAudit.inspect(l,scenario:scenario+"-native-"+variant,frame:frame,time:renderer.origin+began+t)
                                audit+=f.map(\.fields);check(f.isEmpty,"M10.1 every native backing root is audited")
                            }}
                        }
                        CATransaction.begin();CATransaction.setDisableActions(true)
                        mount.sublayers?.forEach{$0.removeFromSuperlayer()};mount.addSublayer(mirror.copy(source))
                        CATransaction.commit()
                        if [0,6,48].contains(frame) {
                            let f=ReplicaContainerAudit.inspect(mount,scenario:scenario+"-fixture-"+variant,frame:frame,time:renderer.origin+began+t)
                            audit+=f.map(\.fields);check(f.isEmpty,"M10.1 fixture has no copied Gaussian or container")
                        }
                        if scenario=="picker-in",variant=="gauss",scale==1 {
                            let geometry=views(picker).map {v -> [String:Any] in
                                ["type":String(describing:type(of:v)),"frame":NSStringFromRect(v.frame),"bounds":NSStringFromRect(v.bounds),"alpha":v.alphaValue,"hidden":v.isHidden,"layer":String(describing:v.layer?.position),"clip":v.layer?.masksToBounds ?? false]
                            }
                            try JSONSerialization.data(withJSONObject:geometry,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("picker-geometry-\(frame).json"))
                        }
                        let pixels=renderer.render(at:began+t)
                        if !nonempty {
                            var k=0
                            while k<pixels.count {if abs(Int(pixels[k])-30)>8 || abs(Int(pixels[k+1])-30)>8 || abs(Int(pixels[k+2])-30)>8 {nonempty=true;break};k+=4}
                        }
                        let step=previous.map{renderer.tileDiff($0,pixels)} ?? 0;steps.append(step)
                        let poses=appearance.map {[$0.transition.pose(at:renderer.origin+began+t)]} ?? (scenario.hasPrefix("send") ? send:picker).appearanceEffects.verificationPoses(at:renderer.origin+began+t)
                        let radius=poses.filter{$0.opacity>0}.map(\.radius).max() ?? 0,opacity=poses.map(\.opacity).max() ?? 0
                        traces+="\(scenario),\(variant),\(scale),\(frame),\(t),\(step),\(radius),\(opacity)\n"
                        allTiles.append(thumbnail(renderer.image(pixels),width:240))
                        if frame==0 {first=pixels};last=pixels;previous=pixels
                        if selected.contains(frame) {
                            tiles.append(thumbnail(renderer.image(pixels),width:360))

                        }
                        if scale==1 {try renderer.write(pixels,to:directory.appendingPathComponent("\(scenario)-\(variant)-\(frame).png"))}
                    }
                    check(nonempty,"M10.1 visible content really rendered "+scenario+" "+variant)
                    if variant=="off" {firstReference=first;lastReference=last}
                    else {check(first==firstReference,"M10.1 first byte identity \(scenario) \(variant) \(scale)");check(last==lastReference,"M10.1 last byte identity \(scenario) \(variant) \(scale)")}
                    let spikes=(2..<steps.count-2).filter {i in
                        let around=[steps[i-2],steps[i-1],steps[i+1],steps[i+2]].sorted(),median=(around[1]+around[2])/2
                        return steps[i]>8 && steps[i]>3*median+2
                    }
                    check(spikes.isEmpty,"M10.1 spikes \(scenario) \(variant) \(scale): \(spikes)")
                    var m=preCost;m["scenario"]=scenario;m["mode"]=variant;m["scale"]=scale;m["spikes"]=spikes
                    metrics.append(m);sheets.append(tiles);allSheets.append(allTiles)
                    if variant=="gauss" {check(peakCopies(source)==0,"M10.1 appearance Gaussian contains zero copies")}
                    // Keep the fixture and native row alive until every render has completed.
                    _=row
                    picker.dismiss();send.dismiss();clock.advance(by:2)
                }
                try sheet(sheets,to:directory.appendingPathComponent("\(scenario)-\(Int(scale))x-three-way.png"))
                try sheet(allSheets,to:directory.appendingPathComponent("\(scenario)-\(Int(scale))x-all-frames-three-way.png"),frames:Array(0...48))
            }
        }
        // Movement remains physically gated, including rolling letters and a model jump while letters are active.
        do {
            OverlayExposure.enabled=true;OverlayZoom.verificationOverride = .gauss
            let clock=OverlayManualClock(),host=OverlayView(frame:CGRect(x:0,y:0,width:1080,height:900)),p=OverlayModelPicker(clock:clock)
            p.exposureProfile=OverlayExposure.dell;var s=ModelSettings();s.modelID="g61sol";s.effort = .high;p.configure(settings:s,models:ModelCatalog.mockModels)
            p.present(anchor:CGRect(x:650,y:830,width:158,height:28),in:host);clock.advance(by:1)
            _=p.selectModel(ModelCatalog.mockModels.first!.id);_=p.selectEffort(.ultra)
            let findings=ReplicaContainerAudit.inspect(p.layer!,scenario:"model-move-and-word",frame:0,time:CACurrentMediaTime())
            audit+=findings.map(\.fields);check(findings.isEmpty,"M10.1 model movement and rolling word source audit")
            check(peakCopies(p.layer!)>1,"M10.1 model movement keeps real exposure copies")
            for v in views(p).compactMap({$0 as? OverlayAccumulatingView}) {
                for f in v.exposureFrames {
                    check(f.spacing<=1.50001,"M10.1 moving glyph spacing <=1.5pt")
                    check(f.sample.count == 1 ? f.sample.length <= 0.010001 : f.coverage+0.0001>=f.sample.length,"M10.1 moving glyph coverage or Engine sub-0.01pt quantum")
                }
            }
            p.dismiss();clock.advance(by:2)
            check(layers(p.layer!).allSatisfy{!($0 is CAReplicatorLayer)},"M10.1 retirement releases all replica textures")
        }
        // One Gaussian, no legacy filter stack, sharp endpoints and exact C0 reversals.
        for time in [0.003,0.017,0.037,0.071,0.097] {
            let layer=CALayer(),effect=OverlayContentAppearance(content:layer,clock:SceneClock())
            _=effect.setVisible(true,at:0);let before=effect.transition.pose(at:time)
            _=effect.setVisible(false,at:time)
            check(before==effect.transition.pose(at:time),"M10.1 reverse preserves analytical pose")
            check((layer.filters ?? []).count==1,"M10.1 single Gaussian filter only")
            _=effect.settle(at:time+0.1);check((layer.filters ?? []).isEmpty,"M10.1 settled filter removed")
        }
        do {
            let rep=CAReplicatorLayer(),container=CALayer();container.backgroundColor=NSColor.white.cgColor;rep.addSublayer(container)
            ReplicaContainerAudit.register(container,material:.container,note:"intentional negative control")
            check(!ReplicaContainerAudit.inspect(rep,scenario:"negative",frame:0,time:0).isEmpty,"M10.1 material auditor rejects a deliberately copied container")
        }
        metrics+=try preparationCosts()
        try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("metrics.json"))
        try JSONSerialization.data(withJSONObject:audit,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("audit-findings.json"))
        try traces.write(to:output.appendingPathComponent("frames.csv"),atomically:true,encoding:.utf8)
        check(NSApp.windows.allSatisfy{!$0.isVisible},"M10.1 strictly windowless")
    }
    static func costOnly(output:URL)throws {
        let saved=OverlayExposure.enabled,old=OverlayZoom.verificationOverride
        defer {OverlayExposure.enabled=saved;OverlayZoom.verificationOverride=old}
        let values=try preparationCosts(optimized:true)
        try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("cost-release.json"))
        print("Overlay cost-only: three modes, no window, no backend")
    }
    private static func preparationCosts(optimized:Bool=false)throws->[[String:Any]] {
        var result:[[String:Any]]=[]
        for variant in ["off","accum","gauss"] {
            OverlayExposure.enabled=variant != "off";OverlayZoom.verificationOverride=variant == "accum" ? .accum:.gauss
            var values:[Double]=[]
            for _ in 0..<7 {
                let clock=OverlayManualClock(),host=OverlayView(frame:CGRect(x:0,y:0,width:1080,height:900)),p=OverlayModelPicker(clock:clock)
                var s=ModelSettings();s.modelID="g61sol";p.configure(settings:s,models:ModelCatalog.mockModels)
                let start=CACurrentMediaTime();p.present(anchor:CGRect(x:650,y:830,width:158,height:28),in:host);values.append((CACurrentMediaTime()-start)*1000)
                p.dismiss();clock.advance(by:2)
            }
            values.sort();result.append(["scenario":optimized ? "picker-preparation-optimized":"picker-preparation-debug","mode":variant,"samples":values,"medianMS":values[3],"p95MS":values[6],"includes":"present/layout/CA submit; init/configure excluded; " + (optimized ? "optimized WMO objects":"debug production objects")])
        };return result
    }
    private static func thumbnail(_ image:CGImage,width:Int)->CGImage {
        let h=max(1,image.height*width/image.width),c=CGContext(data:nil,width:width,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:width,height:h));return c.makeImage()!
    }
    private static func sheet(_ rows:[[CGImage]],to url:URL,frames:[Int]?=nil)throws {
        guard let image=rows.first?.first else{return};let w=image.width,h=image.height
        let header=frames==nil ? 0:22,side=frames==nil ? 0:56
        let c=CGContext(data:nil,width:w*rows[0].count+side,height:h*rows.count+header,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor(srgbRed:0.06,green:0.06,blue:0.06,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:c.width,height:c.height))
        for (row,images) in rows.enumerated() {for (column,image) in images.enumerated(){c.draw(image,in:CGRect(x:column*w+side,y:(rows.count-1-row)*h,width:w,height:h))}}
        if let frames {
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.white]
            for (i,frame) in frames.enumerated() {NSAttributedString(string:String(format:"f%02d · %.1fms",frame,Double(frame)*1000/60),attributes:attrs).draw(at:CGPoint(x:side+i*w+5,y:h*rows.count+4))}
            for (i,name) in ["off","accum","gauss"].enumerated() {NSAttributedString(string:name,attributes:attrs).draw(at:CGPoint(x:5,y:(rows.count-1-i)*h+h/2))}
            NSGraphicsContext.restoreGraphicsState()
        }
        try NSBitmapImageRep(cgImage:c.makeImage()!).representation(using:.png,properties:[:])!.write(to:url)
    }
}

/// Test-only mirror: own native paint is captured without live layer filters, then the ORIGINAL single-layer
/// animations/filters are cloned at their real positions. Glass is a labelled neutral geometry proxy, not refraction.
@MainActor final class OverlayM101Mirror {
    let scale:CGFloat
    let startTime:Double
    private var cache:[String:CGImage]=[:]
    private var native:[ObjectIdentifier:NSView]=[:]
    private var virtual:[ObjectIdentifier:CALayer]=[:]
    init(scale:CGFloat,startTime:Double,view:NSView){
        self.scale=scale;self.startTime=startTime
        func add(_ view:NSView){if let layer=view.layer {native[ObjectIdentifier(layer)]=view};view.subviews.forEach(add)
            if let glass=view as? NSGlassEffectView,let content=glass.contentView,!view.subviews.contains(where:{$0===content}) {add(content)}
        };add(view)
    }
    func copy(_ l:CALayer)->CALayer {
        let c:CALayer
        if let r=l as? CAReplicatorLayer {
            let n=CAReplicatorLayer();n.instanceCount=r.instanceCount;n.instanceDelay=r.instanceDelay;n.instanceTransform=r.instanceTransform;n.instanceColor=r.instanceColor;c=n
        } else if let s=l as? CAShapeLayer {let n=CAShapeLayer();n.path=s.path;n.fillColor=s.fillColor;n.strokeColor=s.strokeColor;n.lineWidth=s.lineWidth;n.fillRule=s.fillRule;c=n}
        else if let g=l as? CAGradientLayer {let n=CAGradientLayer();n.colors=g.colors;n.locations=g.locations;n.startPoint=g.startPoint;n.endPoint=g.endPoint;n.type=g.type;c=n}
        else {c=CALayer()}
        c.name=l.name;c.bounds=l.bounds;c.position=l.position;c.anchorPoint=l.anchorPoint;c.transform=l.transform;c.sublayerTransform=l.sublayerTransform
        c.opacity=l.opacity;c.isHidden=l.isHidden;c.isGeometryFlipped=l.isGeometryFlipped;c.masksToBounds=l.masksToBounds;c.cornerRadius=l.cornerRadius
        c.backgroundColor=l.backgroundColor;c.borderColor=l.borderColor;c.borderWidth=l.borderWidth;c.filters=l.filters;c.compositingFilter=l.compositingFilter
        c.shadowColor=l.shadowColor;c.shadowOpacity=l.shadowOpacity;c.shadowRadius=l.shadowRadius;c.shadowOffset=l.shadowOffset;c.shadowPath=l.shadowPath
        c.contents=l.contents;c.contentsScale=l.contentsScale;c.contentsGravity=l.contentsGravity
        let nativeView = native[ObjectIdentifier(l)] ?? l.delegate as? NSView
        if let view=nativeView {
            c.contents=nil // AppKit's cached backing contents can already include descendants. Draw OWN paint only.
            c.bounds=view.bounds
            c.position=CGPoint(x:view.frame.minX+c.anchorPoint.x*view.bounds.width,y:view.frame.minY+c.anchorPoint.y*view.bounds.height)
            c.isHidden=view.isHidden
            if l.name?.hasPrefix("overlay.appearance.")==true {c.opacity=Float(view.alphaValue)}
            if let glass=view as? NSGlassEffectView {
                c.filters=nil;c.sublayers=nil
                let shape=CAShapeLayer();shape.frame=c.bounds;shape.path=CGPath(roundedRect:shape.bounds,cornerWidth:glass.cornerRadius,cornerHeight:glass.cornerRadius,transform:nil)
                shape.fillColor=NSColor.white.withAlphaComponent(0.08).cgColor;c.addSublayer(shape)
                if let content=glass.contentView,let layer=content.layer {c.addSublayer(copy(layer))}
                for k in l.animationKeys() ?? [] {if let a=l.animation(forKey:k){let copy=a.copy() as! CAAnimation;copy.beginTime=a.beginTime==0 ? startTime:l.convertTime(a.beginTime,to:nil);c.add(copy,forKey:k)}};return c
            }
            let trivial=type(of:view)==OverlayView.self || view is OverlaySurface || view is OverlayAccumulatingView || view is OverlayRollingWord || view is OverlayLens
            if !trivial && view.bounds.width>0 && view.bounds.height>0 {
                let key="\(ObjectIdentifier(view)):\(view.bounds)"
                if let image=cache[key] {c.contents=image;c.contentsScale=scale}
                else {
                    let paint=OverlayInkView(frame:view.bounds);paint.paint={view.draw($0)}
                    let image=NativeViewBitmap.capture(paint,scale:scale);cache[key]=image;c.contents=image;c.contentsScale=scale
                }
            }
        }
        if l.name=="overlay.tight-glyph" {ReplicaContainerAudit.register(c,material:.glyph,note:"Mirror of audited own-paint tight glyph source")}
        if let view=nativeView {
            let children=view.subviews.compactMap {v -> CALayer? in
                let layer:CALayer
                if let backing=v.layer {layer=backing}
                else {
                    let id=ObjectIdentifier(v)
                    if let old=virtual[id] {layer=old} else {layer=CALayer();virtual[id]=layer}
                    layer.bounds=v.bounds;layer.anchorPoint = .zero;layer.position=v.frame.origin;layer.opacity=Float(v.alphaValue)
                }
                native[ObjectIdentifier(layer)]=v;return layer
            }
            let ids=Set(children.map{ObjectIdentifier($0)})
            for child in l.sublayers ?? [] where !ids.contains(ObjectIdentifier(child)) && native[ObjectIdentifier(child)] == nil && !String(describing:type(of:child)).lowercased().contains("viewbacking") {c.addSublayer(copy(child))}
            for child in children {c.addSublayer(copy(child))}
        } else {for child in l.sublayers ?? [] {c.addSublayer(copy(child))}}
        if let mask=l.mask {c.mask=copy(mask)}
        for key in l.animationKeys() ?? [] {if let a=l.animation(forKey:key){let copy=a.copy() as! CAAnimation;copy.beginTime=a.beginTime==0 ? startTime:l.convertTime(a.beginTime,to:nil);c.add(copy,forKey:key)}}
        return c
    }
}
#endif
