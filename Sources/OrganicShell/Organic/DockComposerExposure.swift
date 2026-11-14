import AppKit
import QuartzCore

/// Dock-only foreground. AppKit, rather than a backing-layer insertion index, keeps ink above glass.
@MainActor final class M10DockForeground:NSView {
    override var isFlipped:Bool { true }
    override var wantsUpdateLayer:Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point:NSPoint)->NSView? { nil }
}

/// Transparent own-draw pictures. Never cacheDisplay, clone an NSView backing, or capture glass.
@MainActor enum M10DockPicture {
    struct Tile { let rect:CGRect,image:CGImage }
    static func draw(_ source:NSView,scale:CGFloat,plates:Bool)->CGImage? {
        let w=Int(ceil(source.bounds.width*scale)),h=Int(ceil(source.bounds.height*scale))
        guard w>0,h>0,let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:source.window?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
        c.scaleBy(x:scale,y:scale)
        if source.isFlipped { c.translateBy(x:0,y:source.bounds.height);c.scaleBy(x:1,y:-1) }
        func paint(_ v:NSView) {
            guard !v.isHidden,!(v is NSGlassEffectView),!(v is NSGlassEffectContainerView),!(v is NativeComposerVoiceWaveform) else{return}
            let text=v is NSTextField || v is NSTextView || v is NSImageView || v is NSProgressIndicator || v is NSScroller
            if !(plates && text) {
                c.saveGState();c.clip(to:source.bounds)
                var parent=v === source ? nil:v.superview
                while let a=parent,a !== source {
                    if a is NSClipView || a.layer?.masksToBounds == true {c.clip(to:a.convert(a.bounds,to:source))}
                    parent=a.superview
                }
                let o=v.convert(CGPoint.zero,to:source),x=v.convert(CGPoint(x:1,y:0),to:source),y=v.convert(CGPoint(x:0,y:1),to:source)
                c.concatenate(CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y));c.clip(to:v.bounds)
                if let color=v.layer?.backgroundColor {c.setFillColor(color);let r=v.layer?.cornerRadius ?? 0;c.addPath(CGPath(roundedRect:v.bounds,cornerWidth:r,cornerHeight:r,transform:nil));c.fillPath()}
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:v.isFlipped)
                if let b=v as? NativeComposerMenuButton {let saved=b.drawingPlate;b.drawingPlate=plates;b.draw(b.bounds);b.drawingPlate=saved}
                else if plates,let b=v as? NSButton {let title=b.title,image=b.image;b.title="";b.image=nil;b.draw(b.bounds);b.title=title;b.image=image}
                else {v.draw(source.convert(source.bounds,to:v).intersection(v.bounds))}
                NSGraphicsContext.restoreGraphicsState();c.restoreGState()
            }
            for child in v.subviews {paint(child)}
        }
        source.effectiveAppearance.performAsCurrentDrawingAppearance {paint(source)}
        return c.makeImage()
    }
    /// One tightly cropped independent alpha allocation; no retained wide CGImage provider.
    static func tight(_ image:CGImage,scale:CGFloat)->Tile? {
        let tiles=tiles(image,scale:scale)
        guard let first=tiles.first else{return nil}
        if tiles.count==1{return first}
        let rect=tiles.reduce(CGRect.null){$0.union($1.rect)}
        let w=Int((rect.width*scale).rounded()),h=Int((rect.height*scale).rounded())
        let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for tile in tiles {c.draw(tile.image,in:tile.rect.offsetBy(dx:-rect.minX,dy:-rect.minY).applying(CGAffineTransform(scaleX:scale,y:scale)))}
        return Tile(rect:rect,image:c.makeImage()!)
    }
    static func plates(_ image:CGImage,scale:CGFloat)->[Tile] {
        let w=image.width,h=image.height,c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:w,height:h));let bytes=c.data!.assumingMemoryBound(to:UInt8.self)
        var previous=[Int](repeating:0,count:w),current=previous,parents=[0],boxes=[CGRect.zero]
        func find(_ id:Int)->Int{var p=id;while parents[p] != p{p=parents[p]};return p}
        for y in 0..<h {
            for x in 0..<w {
                guard bytes[(y*w+x)*4+3]>0 else{current[x]=0;continue}
                let left=x>0 ? current[x-1]:0,up=previous[x]
                var label=left>0 ? find(left):up>0 ? find(up):0
                if label==0{label=parents.count;parents.append(label);boxes.append(CGRect(x:x,y:y,width:1,height:1))}
                if left>0,up>0{let other=find(up);if other != label{parents[other]=label;boxes[label]=boxes[label].union(boxes[other])}}
                current[x]=label;boxes[label]=boxes[label].union(CGRect(x:x,y:y,width:1,height:1))
            };swap(&previous,&current)
        }
        var roots:[Int:CGRect]=[:]
        for id in 1..<parents.count{let root=find(id);roots[root]=(roots[root] ?? .null).union(boxes[id])}
        return roots.values.compactMap{r in
            let width=Int(r.width),height=Int(r.height),row=width*4
            var data=Data(count:row*height)
            data.withUnsafeMutableBytes{d in for y in 0..<height{d.baseAddress!.advanced(by:y*row).copyMemory(from:bytes.advanced(by:((Int(r.minY)+y)*w+Int(r.minX))*4),byteCount:row)}}
            let tile=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:row,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            return Tile(rect:CGRect(x:r.minX/scale,y:r.minY/scale,width:r.width/scale,height:r.height/scale),image:tile)
        }
    }

    static func ink(_ full:CGImage,_ solid:CGImage)->CGImage {
        let w=full.width,h=full.height
        func pixels(_ image:CGImage)->CGContext {let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:w,height:h));return c}
        let f=pixels(full),s=pixels(solid),a=f.data!.assumingMemoryBound(to:UInt8.self),b=s.data!.assumingMemoryBound(to:UInt8.self)
        let words=f.data!.assumingMemoryBound(to:UInt32.self),baseWords=s.data!.assumingMemoryBound(to:UInt32.self)
        for i in stride(from:0,to:w*h*4,by:4) {
            if words[i/4]==baseWords[i/4] {words[i/4]=0;continue}
            let fa=Double(a[i+3])/255,ba=Double(b[i+3])/255
            var alpha=ba<0.999 ? max(0,min(1,(fa-ba)/(1-ba))):0
            if ba>=0.999 {for k in 0..<3 {let x=Double(a[i+k])/255,y=Double(b[i+k])/255;alpha=max(alpha,x>=y ? (x-y)/max(1e-9,1-y):(y-x)/max(1e-9,y))}}
            for k in 0..<3 {a[i+k]=UInt8(max(0,min(255,(Double(a[i+k])-Double(b[i+k])*(1-alpha)).rounded())))}
            a[i+3]=UInt8(max(0,min(255,(alpha*255).rounded())))
        };return f.makeImage()!
    }
    /// Tight independent storage, not CGImage.cropping's retained wide provider. Tiles never span blank rows.
    static func tiles(_ image:CGImage,scale:CGFloat)->[Tile] {
        let w=image.width,h=image.height,c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:w,height:h));let p=c.data!.assumingMemoryBound(to:UInt8.self)
        var out:[Tile]=[]
        for top in stride(from:0,to:h,by:Int(32*scale)) {
            for left in stride(from:0,to:w,by:Int(160*scale)) {
                var x0=w,y0=h,x1=0,y1=0
                for y in top..<min(h,top+Int(32*scale)) {for x in left..<min(w,left+Int(160*scale)) where p[(y*w+x)*4+3]>0 {x0=min(x0,x);y0=min(y0,y);x1=max(x1,x+1);y1=max(y1,y+1)}}
                guard x1>x0,y1>y0 else {continue}
                let width=x1-x0,height=y1-y0,row=width*4
                var data=Data(count:row*height)
                data.withUnsafeMutableBytes { d in for y in 0..<height {d.baseAddress!.advanced(by:y*row).copyMemory(from:p.advanced(by:((y0+y)*w+x0)*4),byteCount:row)} }
                let tile=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:row,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
                out.append(Tile(rect:CGRect(x:CGFloat(x0)/scale,y:CGFloat(y0)/scale,width:CGFloat(width)/scale,height:CGFloat(height)/scale),image:tile))
            }
        };return out
    }
}

@MainActor final class M10DockComposer {
    static let enabled=ProcessInfo.processInfo.environment["M10_DOCK_COMPOSER"] != "0"
    let foreground=M10DockForeground()
    private weak var host:NSView?
    @MainActor private final class Part {
        weak var source:NSView?
        let layer=CALayer(),history=M10DockHistory()
        var tiles:[(M10DockPicture.Tile,ChordTrail,CALayer)]=[],plates:[(M10DockPicture.Tile,CALayer)]=[]
        var modelSplit:Int?
        let gaussianInk=CALayer()
        var gaussian:ContentGaussianTransition?
        var active=false,prepared=CGSize.zero
        #if M10_DOCK_SELFTEST
        var glyphFrames:[(CGRect,CGRect,ExposureSample,CAReplicatorLayer)]=[]
        var full:CGImage?
        #endif
        init(_ source:NSView){self.source=source;gaussianInk.anchorPoint = .zero;gaussianInk.isHidden=true;layer.addSublayer(gaussianInk)}
        func reset(){
            CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
            #if M10_DOCK_SELFTEST
            glyphFrames=[]
            #endif
            gaussian?.setVisible(true,animated:false);gaussian=nil;gaussianInk.isHidden=true
            for (_,trail,_) in tiles{trail.layer.isHidden=false}
            if active,let source{source.layer?.opacity=Float(source.alphaValue)};active=false;layer.isHidden=true;for (_,t,_) in tiles{t.reset()}}
    }
    @MainActor private final class Entry {
        weak var source:NativeComposer?
        var parts:[Part]=[],dirty=true,moving=false
        var preparationViews:[NSView]?
        var contentKey:ContentKey?
        var gaussianUntil=0.0,lastPrepared=0.0
        var frameObservation:NSObjectProtocol?,selectionObservation:NSObjectProtocol?
        var active:Bool{parts.contains{ $0.active }}
        init(_ source:NativeComposer){self.source=source}
        isolated deinit {if let frameObservation{NotificationCenter.default.removeObserver(frameObservation)};if let selectionObservation{NotificationCenter.default.removeObserver(selectionObservation)}}
        func reset(){moving=false;gaussianUntil=0;for p in parts{p.reset()};source?.voiceWaveform.setCarryStretch(.zero)}
    }
    private var entries:[ObjectIdentifier:Entry]=[:]
    private(set) var captures=0,modeCaptureSkips=0
    private var modeInFlight=false
    private var idleTask:DispatchWorkItem?,inputMonitor:Any?
    private var lastInput = -Double.infinity
    var canPrepareAtRest:(()->Bool)?
    private func scheduleIdlePreparation() {
        guard idleTask == nil,!modeInFlight else{return}
        let task=DispatchWorkItem{[weak self] in
            guard let self else{return};self.idleTask=nil
            guard !self.modeInFlight,self.canPrepareAtRest?() != false else{return}
            guard CACurrentMediaTime()-self.lastInput>=0.35,NSEvent.pressedMouseButtons == 0 else{self.scheduleIdlePreparation();return}
            if !ModeSignposts.operation("DockComposerIdleSlice",detail:"one native control",{self.prewarmModeStep()}) {self.scheduleIdlePreparation()}
        };idleTask=task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.016,execute:task)
    }
    private struct ContentKey:Equatable {
        var text:String,state:NativeComposerState,files:[Attachment],settings:ModelSettings,base:ModelSettings,access:Access,workspace:NativeComposerWorkspace,queued:[QueuedMessage],summary:String,percent:Int?
        var appearance:Int,display:Int,scale:CGFloat,growing:Bool,segmented:Bool,compact:Bool,enabled:Bool,legacyFiles:Bool,sendVoice:Bool
    }
    private func contentKey(_ c:NativeComposer)->ContentKey {
        .init(text:c.text,state:c.state,files:c.attachments,settings:c.settings,base:c.baseSettings,access:c.access,workspace:c.workspace,queued:c.queued,summary:c.contextSummary,percent:c.contextPercent,appearance:NativeAppearance.revision,display:NativeDisplayOptions.shared.revision,scale:c.controlScale,growing:c.layoutMode == .growing,segmented:c.segment != nil,compact:c.layoutMode == .fullBar && c.densityWidth < (c.segment == nil ? 620:560),enabled:c.isEnabled,legacyFiles:c.hasAttachments,sendVoice:c.onSendVoice != nil)
    }
    func beginModeHandoff(){modeInFlight=true;idleTask?.cancel();idleTask=nil}
    func endModeHandoff(){modeInFlight=false;lastInput=CACurrentMediaTime();scheduleIdlePreparation()}
    /// Geometry prewarm visits one control per turn. No borrowed editor is moved/resized to obtain a future image.
    func prewarmModeStep()->Bool {
        guard let host,!modeInFlight else{return true}
        func composers(_ v:NSView)->[NativeComposer]{if let c=v as? NativeComposer{return [c]};return v.subviews.flatMap(composers)}
        guard let source=composers(host).first(where:{let e=entries[ObjectIdentifier($0)];return e == nil || e!.dirty || e!.preparationViews != nil}) else{return true}
        if let e=entries[ObjectIdentifier(source)],e.active || e.moving {return true}
        ModeSignposts.measure("PrewarmDockComposerControl"){prepare(source,onePart:true)}
        return false
    }

    init(in host:NSView) {self.host=host;foreground.frame=host.bounds;foreground.wantsLayer=true;foreground.autoresizesSubviews=false;foreground.isHidden=true;foreground.setAccessibilityElement(false);host.addSubview(foreground,positioned:.above,relativeTo:nil)
        if NSApp != nil {inputMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown,.leftMouseDragged,.rightMouseDragged,.scrollWheel,.magnify,.rotate,.swipe]) { [weak self] event in
            MainActor.assumeIsolated {self?.lastInput=CACurrentMediaTime()};return event
        }}
    }
    func prepare(_ source:NativeComposer, atCommit:Bool = false,onePart:Bool=false) {
        guard let host,source.isDescendant(of:host),source.bounds.width>0 else{return}
        // A mode flight never captures or scans pixels, including its semantic admission/atCommit calls.
        if modeInFlight {
            modeCaptureSkips+=1
            if let e=entries[ObjectIdentifier(source)],e.preparationViews == nil,!e.parts.isEmpty,e.contentKey == contentKey(source) {e.dirty=false}
            return
        }
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        let id=ObjectIdentifier(source),e:Entry
        if let existing=entries[id] {e=existing}
        else {
            e=Entry(source);entries[id]=e
            // Normie borrows the SAME composer. Restore its paint before the borrower's first layout/capture,
            // even if the old Dock no longer receives display ticks. No Native or Normie API change is needed.
            source.postsFrameChangedNotifications=true
            e.frameObservation=NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:source,queue:nil){[weak self,weak source] _ in
                MainActor.assumeIsolated {guard let self,let source,let host=self.host,!source.isDescendant(of:host) else{return};self.entries[ObjectIdentifier(source)]?.reset();self.prune()}
            }
            e.selectionObservation=NotificationCenter.default.addObserver(forName:NSTextView.didChangeSelectionNotification,object:source.textView,queue:nil){[weak self,weak source] _ in
                MainActor.assumeIsolated {guard let self,let source,let host=self.host,source.isDescendant(of:host),let e=self.entries[ObjectIdentifier(source)] else{return};e.dirty=true
                    self.scheduleIdlePreparation()
                }
            }
            let previous=source.onMotionContentsChange
            source.onMotionContentsChange = {[weak self,weak source] in previous?();guard let self,let source,let e=self.entries[ObjectIdentifier(source)] else{return};e.dirty=true
                if !source.isDescendant(of:self.host ?? self.foreground){e.reset();self.prune();return}
                self.scheduleIdlePreparation()
            }
        }
        if !onePart,atCommit && (e.dirty || source.modelButton.segmentBlend != nil || e.parts.contains(where:{$0.source?.bounds.size != $0.prepared})) {e.reset();e.dirty=true;e.preparationViews=nil}
        guard !e.active,!e.moving,e.dirty || e.parts.contains(where:{$0.source?.bounds.size != $0.prepared}) else{return}
        if e.preparationViews == nil {
            e.reset();for p in e.parts{p.layer.removeFromSuperlayer()};e.parts=[]
            e.contentKey=contentKey(source)
            e.preparationViews=source.subviews.filter{!$0.isHidden && $0 !== source.voiceWaveform && !($0 is NSProgressIndicator)}
        }
        if e.contentKey != contentKey(source) {e.preparationViews=nil;e.dirty=true;return}
        let scale=source.window?.backingScaleFactor ?? source.verificationScale ?? 2
        // Per-control poses also cover the Native segment transition's internal control/clip movement.
        // Live waveform and progress indicators keep drawing in the original hierarchy.
        let todo=onePart ? Array((e.preparationViews ?? []).prefix(1)):(e.preparationViews ?? [])
        e.preparationViews?.removeFirst(todo.count)
        for view in todo {
            guard let full=M10DockPicture.draw(view,scale:scale,plates:false),let solid=M10DockPicture.draw(view,scale:scale,plates:true) else{continue}
            view.wantsLayer=true
            let p=Part(view);p.prepared=view.bounds.size
            #if M10_DOCK_SELFTEST
            p.full=full
            #endif
            var tiles=M10DockPicture.tiles(M10DockPicture.ink(full,solid),scale:scale)
            if view === source.modelButton,let blend=source.modelButton.segmentBlend {
                guard let a=blend.from.cgImage(forProposedRect:nil,context:nil,hints:nil),let b=blend.to.cgImage(forProposedRect:nil,context:nil,hints:nil) else{continue}
                let from=M10DockPicture.tiles(a,scale:scale),to=M10DockPicture.tiles(b,scale:scale)
                guard !from.isEmpty,!to.isEmpty else{continue}
                p.modelSplit=from.count;tiles=from+to
            }
            p.tiles=tiles.map {tile in let t=ChordTrail(),l=CALayer();ReplicaContainerAudit.register(l,material:.glyph,note:"Composer own-draw tight alpha ink");l.contents=tile.image;l.contentsScale=scale;t.layer.addSublayer(l);p.layer.addSublayer(t.layer);return(tile,t,l)}
            p.plates=M10DockPicture.plates(solid,scale:scale).map {tile in let l=CALayer();l.contents=tile.image;l.contentsScale=scale;let x=min(0.49,20/tile.rect.width),y=min(0.49,20/tile.rect.height);l.contentsCenter=CGRect(x:x,y:y,width:1-2*x,height:1-2*y);p.layer.insertSublayer(l,at:0);return(tile,l)}
            // Prepared at the same semantic commit. Gaussian ink shares immutable CGImages, never a backing tree.
            #if M10_DOCK_SELFTEST
            let gaussianPreparationBegan=CACurrentMediaTime()
            #endif
            for (tile,_,_) in p.tiles {
                let l=CALayer();l.anchorPoint = .zero;l.frame=tile.rect;l.contents=tile.image;l.contentsScale=scale
                ReplicaContainerAudit.register(l,material:.glyph,note:"Composer own-draw ink matte; tight independent glyph texture")
                p.gaussianInk.addSublayer(l)
            }
            p.gaussianInk.bounds=CGRect(origin:.zero,size:p.prepared)
            #if M10_DOCK_SELFTEST
            gaussianPreparationMs+=(CACurrentMediaTime()-gaussianPreparationBegan)*1000
            #endif
            p.layer.isHidden=true;foreground.layer?.addSublayer(p.layer);e.parts.append(p)
        }
        if e.preparationViews?.isEmpty == true {e.preparationViews=nil;e.dirty=false;e.lastPrepared=CACurrentMediaTime();captures+=1}
    }
    /// Semantic role change only. Plain ink bitmaps prepared at rest; unfiltered plate siblings remain sharp.
    func setGaussianVisible(_ source:NativeComposer,_ visible:Bool,at time:Double,initiallyVisible:Bool) {
        guard let e=entries[ObjectIdentifier(source)],!e.dirty else{return}
        e.gaussianUntil=time+0.1
        for p in e.parts {
            p.gaussian?.setVisible(true,animated:false)
            var configuration=ContentGaussianTransition.Configuration.system;configuration.fadesContent=false
            p.gaussian=ContentGaussianTransition(content:p.gaussianInk,clock:SceneClock(),initiallyVisible:initiallyVisible,configuration:configuration)
            p.gaussian?.setVisible(visible,at:time)
        }
    }
    func cancelGaussian(_ source:NativeComposer) {
        guard let e=entries[ObjectIdentifier(source)] else{return}
        e.gaussianUntil=0;for part in e.parts {part.reset()};refreshForeground()
    }
    func update(_ source:NativeComposer,frame:M10DockFrame,profile:DisplayProfile,enabled:Bool) {
        guard let host,let e=entries[ObjectIdentifier(source)] else{return}
        guard source.isDescendant(of:host) else{e.reset();prune();return}
        // A retained mode bitmap owns this ink. Its native source and its exposure foreground must both yield.
        if source.layer?.mask?.name == "mode.composer.ink.hold" {
            e.reset();for part in e.parts {part.history.reset()};refreshForeground();return
        }
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        foreground.frame=host.bounds;e.moving=false
        let treatment=enabled && Self.enabled && frame.treatmentEnabled
        let semanticGaussian=treatment && frame.time<e.gaussianUntil
        for p in e.parts {
            guard let view=p.source else{continue}
            let rect=view.convert(view.bounds,to:host)
            let f=p.history.update(rect,at:frame.time,name:frame.name+".composer",profile:profile,enabled:treatment)
            e.moving = e.moving || f.exposure.gate>0
            let active=(f.exposure.gate>0 || semanticGaussian) && !source.isHiddenOrHasHiddenAncestor && !view.isHidden && !e.dirty
            if !active {p.reset();continue}
            let gaussianGlyphs=p.gaussianInk.sublayers ?? []
            if p.modelSplit != nil && gaussianGlyphs.count != p.tiles.count {
                #if M10_DOCK_SELFTEST
                modelMaterialMismatchCount += 1
                #endif
                p.reset();continue
            }
            p.active=true;p.layer.isHidden=false
            var alpha:Float=1;var ancestor:NSView?=view
            while let v=ancestor,v !== host {alpha *= v === view ? Float(v.alphaValue):(v.layer?.presentation()?.opacity ?? Float(v.alphaValue));ancestor=v.superview}
            p.layer.opacity=alpha;view.layer?.opacity=0
            if let split=p.modelSplit {
                let k=source.modelButton.segmentBlend?.progress ?? 1
                for (i,(_,trail,_)) in p.tiles.enumerated() {
                    let opacity=Float(i<split ? 1-k:k);trail.layer.opacity=opacity
                    gaussianGlyphs[i].opacity=opacity
                }
            }
            p.layer.frame=foreground.bounds
            #if M10_DOCK_SELFTEST
            p.glyphFrames=[]
            #endif
            func mapped(_ local:CGRect,_ pose:CGRect)->CGRect {CGRect(x:pose.minX+local.minX*pose.width/p.prepared.width,y:pose.minY+local.minY*pose.height/p.prepared.height,width:local.width*pose.width/p.prepared.width,height:local.height*pose.height/p.prepared.height)}
            if semanticGaussian {
                p.gaussianInk.isHidden=false;p.gaussianInk.position=rect.origin
                for (_,trail,_) in p.tiles {trail.layer.isHidden=true;trail.reset()}
                p.gaussian?.settle(at:frame.time)
            } else {p.gaussianInk.isHidden=true}
            for (tile,trail,ink) in p.tiles where !semanticGaussian {
                let a=tile.rect.offsetBy(dx:f.rect.minX,dy:f.rect.minY),b=tile.rect.offsetBy(dx:f.earlier.minX,dy:f.earlier.minY)
                trail.layer.frame=a;ink.frame=CGRect(origin:.zero,size:a.size)
                let local=CGRect(origin:.zero,size:a.size),old=b.offsetBy(dx:-a.minX,dy:-a.minY)
                trail.settings=M10FExposure.settings(now:local,earlier:old)
                let s=M10FExposure.sample(now:local,earlier:old,profile:profile,settings:trail.settings)
                M10FExposure.apply(s,to:trail,now:local,earlier:old)
                #if M10_DOCK_SELFTEST
                p.glyphFrames.append((a,b,s,trail.layer))
                #endif
            }
            for (tile,plate) in p.plates {plate.frame=M10DockMotion.frame(name:"plate",now:mapped(tile.rect,f.rect),earlier:mapped(tile.rect,f.earlier),time:frame.time,profile:profile,enabled:true).painted}
        }
        source.voiceWaveform.setCarryStretch(treatment ? CGPoint(x:(frame.earlier.minX-frame.rect.minX)*frame.exposure.gate,y:(frame.earlier.minY-frame.rect.minY)*frame.exposure.gate):.zero)
        if !e.moving,e.dirty {scheduleIdlePreparation()}
        refreshForeground()
    }
    private func refreshForeground(){foreground.isHidden=entries.values.allSatisfy{!$0.active};if let host,host.subviews.last !== foreground{host.addSubview(foreground,positioned:.above,relativeTo:nil)}}
    func reset(){for e in entries.values{e.reset();for p in e.parts{p.history.reset()}};refreshForeground()}
    isolated deinit {idleTask?.cancel();if let inputMonitor{NSEvent.removeMonitor(inputMonitor)};for e in entries.values{e.reset()}}
    func prune(){
        let parked=entries.filter{$0.value.source != nil && $0.value.source?.isDescendant(of:host ?? foreground) != true}.sorted{$0.value.lastPrepared>$1.value.lastPrepared}
        let keep=Set(parked.prefix(2).map(\.key)) // bounded return-trip cache, independent of total session count
        for (id,e) in entries where e.source == nil || e.source?.isDescendant(of:host ?? foreground) != true {
            e.reset();e.preparationViews=nil;e.dirty=true
            if e.source == nil || !keep.contains(id) {for p in e.parts{p.layer.removeFromSuperlayer()};e.parts=[]}
            // Keep the weak registration while Normie borrows the editor, preventing callback-chain growth.
            if e.source == nil {entries[id]=nil}
        };refreshForeground()
    }
    #if M10_DOCK_SELFTEST
    private(set) var modelMaterialMismatchCount=0
    private(set) var gaussianPreparationMs=0.0
    var verificationGaussianFields:[String:Any] {
        let parts=entries.values.flatMap{$0.parts}.filter{!$0.gaussianInk.isHidden}
        var violations:[String]=[]
        for p in parts {for l in p.gaussianInk.sublayers ?? [] {
            if l is CAReplicatorLayer || l is CAShapeLayer || l is CATextLayer || l.delegate is NSView || l.mask != nil || l.shadowOpacity>0 || l.backgroundColor?.alpha ?? 0 > 0 || !(l.filters ?? []).isEmpty || !(l.backgroundFilters ?? []).isEmpty {violations.append("Gaussian descendant is not plain ink")}
        }}
        return ["planes":parts.count,"filteredPixels":parts.reduce(0){$0+Int($1.gaussianInk.bounds.width*$1.gaussianInk.bounds.height*4)},"copies":parts.count,"violations":violations]
    }
    var verificationGlyphs:[(CGRect,CGRect,ExposureSample,CAReplicatorLayer)]{entries.values.flatMap{$0.parts.flatMap(\.glyphFrames)}}
    /// Plain model paint only. No native backing tree is copied, even in the offscreen comparator.
    func verificationPaint(exposed:Bool)->CALayer {
        let root=CALayer()
        func clone(_ l:CALayer)->CALayer {
            let out:CALayer
            if let r=l as? CAReplicatorLayer {let c=CAReplicatorLayer();c.instanceCount=r.instanceCount;c.instanceTransform=r.instanceTransform;c.instanceColor=r.instanceColor;out=c}else{out=CALayer()}
            out.bounds=l.bounds;out.position=l.position;out.anchorPoint=l.anchorPoint;out.transform=l.transform;out.opacity=l.opacity;out.isHidden=l.isHidden
            out.contents=l.contents;out.contentsScale=l.contentsScale;out.contentsCenter=l.contentsCenter
            for child in l.sublayers ?? [] {out.addSublayer(clone(child))};return out
        }
        for e in entries.values {for p in e.parts {
            guard let source=p.source,let host,!source.isHiddenOrHasHiddenAncestor else{continue}
            if exposed && p.active{root.addSublayer(clone(p.layer))}
            else{let l=CALayer();l.frame=source.convert(source.bounds,to:host);l.contents=p.full;l.contentsScale=source.window?.backingScaleFactor ?? e.source?.verificationScale ?? 2;root.addSublayer(l)}
        }};return root
    }
    var verificationLayers:[CALayer]{entries.values.flatMap{ $0.parts.map(\.layer) }}
    var activeCount:Int{entries.values.filter(\.active).count}
    #endif
}
