import AppKit
import QuartzCore
import SwiftUI

#if M10_COMPOSER_SELFTEST
/// In-process attribution only. Compiled out of the app; no signposts or file writes in production.
@MainActor enum NormieMotionAudit {
    static var enabled=false
    static var events:[[String:Any]]=[]
    static func begin()->Double{enabled ? CACurrentMediaTime():0}
    static func end(_ work:String,_ start:Double,_ view:NSView?=nil){
        guard enabled else{return}
        events.append(["work":work,"source":view.map{String(describing:type(of:$0))} ?? "none","ms":(CACurrentMediaTime()-start)*1000])
    }
}
#endif

/// M10-C: the detail owns one display-linked clock, asleep outside authored transitions. A manual clock uses the
/// identical callbacks in the windowless check. Timestamps are targetTimestamp, not the time the callback arrived.
@MainActor final class NormieMotionClock: NSObject {
    var frame: ((Double, DisplayProfile) -> Bool)?
    var onSuspend:(()->Void)?
    var manualTime: Double?
    var manualProfile = DisplayProfile(name: "Dell verification", frameInterval: 1/60, mmPerPoint: 0.27, persistenceFrames: 0)
    private weak var view: NSView?
    private var link: CADisplayLink?
    private(set) var running = false
    private(set) var log=FrameLog()
    var now: Double { manualTime ?? CACurrentMediaTime() }
    var profile:DisplayProfile { if manualTime != nil{return manualProfile};if let screen=view?.window?.screen{return DisplayProfile.of(screen)};return DisplayProfile(name:"No screen",frameInterval:1/60,mmPerPoint:0.27,persistenceFrames:0) }
    func attach(_ view: NSView) { self.view = view; if running { start() } }
    func start() {
        running = true
        guard manualTime == nil, let view, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else { return }
        if link == nil {
            let next = view.displayLink(target: self, selector: #selector(tick(_:)))
            next.add(to: .main, forMode: .common); link = next
        }
        link?.isPaused = false
    }
    func stop() { running = false; link?.invalidate(); link = nil;log.pause() }
    func advance(to time: Double) { manualTime = time; if frame?(time, manualProfile) != true { stop() } }
    @objc private func tick(_ next: CADisplayLink) {
        guard let view, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor,
              let screen = view.window?.screen else { stop();onSuspend?(); return }
        var profile = DisplayProfile.of(screen)
        profile.frameInterval = max(1/1000, next.targetTimestamp-next.timestamp)
        let start=CACurrentMediaTime(),active=frame?(next.targetTimestamp,profile) == true
        log.add(target:next.targetTimestamp,interval:profile.frameInterval,busy:CACurrentMediaTime()-start)
        if !active{stop()}
    }
    isolated deinit { link?.invalidate() }
}

@MainActor final class NormieMotionHost: NormieView {
    var onWindowChange: (() -> Void)?
    var onHidden: (() -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChange?() }
    override func viewDidHide() { super.viewDidHide(); onHidden?() }
}
@MainActor private final class NormieMotionGlassClip:NSClipView{
    override var isFlipped:Bool{true}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
}

/// Own an AppKit-ordered foreground plane. A manual sublayer on the detail's backing layer is placed BELOW
/// AppKit's view layers on the next layout/cacheDisplay. Putting ink there lets NSGlassEffectView blur the ink.
@MainActor private final class NormieMotionForeground:NSView {
    override var isFlipped:Bool{true}
    override var wantsUpdateLayer:Bool{true}
    override func updateLayer(){} // Own sublayers only; do not allocate a transparent window-sized backing bitmap.
    override func hitTest(_ point:NSPoint)->NSView?{nil}
}

/// Product NormieDetailView:101: SwiftUI's duration/bounce spring, copied without approximating it by a Bezier.
struct NormieApprovalMotion {
    static let duration = 0.35, bounce = 0.15
    static let spring = SwiftUI.Spring(duration: duration, bounce: bounce)
    static func value(_ time: Double) -> Double { spring.value(target: 1, initialVelocity: 0, time: max(0,time)) }
}

/// Product ArchiveToast:43 (insertion); a separate easeOut .20 removal. Keeping this local avoids an Overlay dependency.
enum NormieToastMotion {
    static let duration = 0.35
    static func value(_ time: Double) -> Double {
        let x = min(1,max(0,time/duration)); var lo=0.0,hi=1.0
        for _ in 0..<30 { let t=(lo+hi)/2; let a=1-t; let v=3*a*a*t*0.3+3*a*t*t*0.5+t*t*t; if v<x { lo=t } else { hi=t } }
        let t=(lo+hi)/2,a=1-t
        return 3*a*a*t*1.15+3*a*t*t+t*t*t
    }
}

/// MotionStretch's shared implementation gates centre translation. A resizing composer/section also moves its
/// edges: use the farthest corner as the sweep length, retaining the actual centre's direction. No glass transform.
enum NormieSolidMotion {
    static func rect(now:CGRect,earlier:CGRect,profile:DisplayProfile,settings:ExposureSettings)->CGRect{
        let edge=MotionStep.edge(now,earlier)
        guard edge>0 else{return now}
        var dx=earlier.midX-now.midX,dy=earlier.midY-now.midY
        if hypot(dx,dy)<1e-9{
            let pairs=[(CGPoint(x:now.minX,y:now.minY),CGPoint(x:earlier.minX,y:earlier.minY)),(CGPoint(x:now.maxX,y:now.minY),CGPoint(x:earlier.maxX,y:earlier.minY)),(CGPoint(x:now.minX,y:now.maxY),CGPoint(x:earlier.minX,y:earlier.maxY)),(CGPoint(x:now.maxX,y:now.maxY),CGPoint(x:earlier.maxX,y:earlier.maxY))]
            if let pair=pairs.max(by:{hypot($0.0.x-$0.1.x,$0.0.y-$0.1.y)<hypot($1.0.x-$1.1.x,$1.0.y-$1.1.y)}){dx=pair.1.x-pair.0.x;dy=pair.1.y-pair.0.y}
        }
        let d=max(1e-12,hypot(dx,dy)),previous=now.offsetBy(dx:dx*edge/d,dy:dy*edge/d)
        return MotionStretch.rect(now:now,earlier:previous,profile:profile,settings:settings)
    }
}

/// A real view's two materials, from its own drawing paths. The first pass is complete; the second suppresses
/// text/images while leaving the view's plates. Glass is NEVER admitted. Controls are restored in the same transaction;
/// this changes neither frame nor text selection, and no intermediate state is committed to the compositor.
@MainActor struct NormieMotionPicture {
    /// An explicitly requested capture owns its local visibility. An inactive mode root above
    /// the source is not part of these pixels; hidden descendants inside the source still are.
    static func includes(_ view:NSView,in source:NSView)->Bool {
        guard NormieIdleMotionCapture.orreryEnabled else {return !view.isHiddenOrHasHiddenAncestor}
        var node:NSView?=view
        while let current=node,current !== source {
            if current.isHidden {return false};node=current.superview
        }
        return true
    }
    let full: CGImage, solids: CGImage, ink: CGImage
    let size: CGSize
    struct Glass {
        weak var view:NSGlassEffectView?
        let frame:CGRect,style:NSGlassEffectView.Style,radius:CGFloat,tint:NSColor?
        weak var backdropParent:NSView?=nil
    }
    let glasses:[Glass]
    let plates:[(CGRect,CGImage)]
    struct Waveform{weak var view:NativeComposerVoiceWaveform?;let frame:CGRect}
    let waveform:Waveform?
    var editorOrigin:CGPoint?=nil
    /// Exact nonzero-alpha bounds plus a two-texel sampling guard. Prepared with the idle picture, never scanned
    /// in update(). Keep full/ink unchanged for native reconstruction, selection/flight consumers and verification.
    struct InkRegion { let rect:CGRect;let image:CGImage? }
    var inkRegion:InkRegion?=nil
    func preparingInk()->Self{
        guard inkRegion == nil else{return self}
        #if M10_COMPOSER_SELFTEST
        let audit=NormieMotionAudit.begin();defer{NormieMotionAudit.end("ink-region",audit)}
        #endif
        var copy=self;copy.inkRegion=Self.inkRegion(ink,size:size);return copy
    }
    nonisolated static func inkRegion(_ ink:CGImage,size:CGSize,shouldContinue:()->Bool = {true})->InkRegion {
        let w=ink.width,h=ink.height,c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(ink,in:CGRect(x:0,y:0,width:w,height:h));let p=c.data!.assumingMemoryBound(to:UInt8.self)
        var left=w,top=h,right = -1,bottom = -1
        for y in 0..<h{if y%32 == 0 && !shouldContinue(){return InkRegion(rect:.zero,image:nil)};for x in 0..<w where p[(y*w+x)*4+3] != 0{left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)}}
        guard right>=left,bottom>=top else{return InkRegion(rect:.zero,image:nil)}
        let x=max(0,left-2),y=max(0,top-2),r=min(w,right+3),b=min(h,bottom+3)
        let pixels=CGRect(x:x,y:y,width:r-x,height:b-y)
        guard let image=ink.cropping(to:pixels) else{return InkRegion(rect:CGRect(origin:.zero,size:size),image:ink)}
        return InkRegion(rect:CGRect(x:CGFloat(x)*size.width/CGFloat(w),y:CGFloat(y)*size.height/CGFloat(h),width:CGFloat(r-x)*size.width/CGFloat(w),height:CGFloat(b-y)*size.height/CGFloat(h)),image:image)
    }
    static func capture(_ view: NSView, scale: CGFloat, reusing plates:NormieMotionPicture?=nil) -> NormieMotionPicture? {
        #if M10_COMPOSER_SELFTEST
        let audit=NormieMotionAudit.begin();defer{NormieMotionAudit.end("capture",audit,view)}
        #endif
        func all(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(all) }
        let tree=all(view)
        guard !(view is NSGlassEffectView) else { return nil }
        let glassViews=tree.compactMap{$0 as? NSGlassEffectView}
        // These are empty material siblings (ApprovalCard). A glass with hosted controls needs its owner's adapter.
        guard glassViews.allSatisfy({$0.contentView?.subviews.isEmpty != false}) else{return nil}
        let glasses=glassViews.map{Glass(view:$0,frame:$0.convert($0.bounds,to:view),style:$0.style,radius:$0.cornerRadius,tint:$0.tintColor,backdropParent:view.superview)}
        let wave=(view as? NativeComposer)?.voiceWaveform
        let waveform=wave.flatMap{$0.active ? Waveform(view:$0,frame:$0.convert($0.bounds,to:view)):nil}
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        let opacity=view.layer?.opacity; view.layer?.opacity=1
        defer { if let opacity { view.layer?.opacity=opacity } }
        let hidden=glassViews.map{($0,$0.isHidden)};for (g,_) in hidden{g.isHidden=true}
        let waveHidden=wave?.layer?.isHidden;wave?.layer?.isHidden=true
        let full:CGImage
        if !glassViews.isEmpty || (view as? NativeTranscriptCard)?.approvalSource != nil{
            let w=Int(ceil(view.bounds.width*scale)),h=Int(ceil(view.bounds.height*scale))
            let space=view.window?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
            let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.scaleBy(x:scale,y:scale)
            if view.isFlipped{c.translateBy(x:0,y:view.bounds.height);c.scaleBy(x:1,y:-1)}
            // cacheDisplay/displayIgnoringOpacity can replay a layer-backed ancestor's opaque canvas in a real
            // window. A glass surface owns no such canvas. Call the SAME draw overrides on a clear bitmap, clipping
            // each child in its native coordinates, while retaining the actual window colour space and appearance.
            view.effectiveAppearance.performAsCurrentDrawingAppearance{
                for v in tree where Self.includes(v,in:view){
                    if v is NSGlassEffectView || tree.contains(where:{$0 is NSGlassEffectView && v.isDescendant(of:$0)}){continue}
                    c.saveGState();c.clip(to:view.bounds)
                    var parent=NormieIdleMotionCapture.orreryEnabled && v === view ? nil:v.superview
                    while let ancestor=parent,ancestor !== view{
                        if ancestor is NSClipView || ancestor.layer?.masksToBounds == true{c.clip(to:ancestor.convert(ancestor.bounds,to:view))}
                        parent=ancestor.superview
                    }
                    let o=v.convert(CGPoint.zero,to:view),x=v.convert(CGPoint(x:1,y:0),to:view),y=v.convert(CGPoint(x:0,y:1),to:view)
                    c.concatenate(CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y));c.clip(to:v.bounds)
                    if let color=v.layer?.backgroundColor{c.setFillColor(color);let radius=v.layer?.cornerRadius ?? 0;c.addPath(CGPath(roundedRect:v.bounds,cornerWidth:radius,cornerHeight:radius,transform:nil));c.fillPath()}
                    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:v.isFlipped)
                    v.draw(v.bounds)
                    NSGraphicsContext.restoreGraphicsState();c.restoreGState()
                }
            }
            full=c.makeImage()!
        }else{full=NativeViewBitmap.capture(view,scale:scale)}
        for (g,h) in hidden{g.isHidden=h}
        if let waveHidden{wave?.layer?.isHidden=waveHidden}
        if let plates,plates.size == view.bounds.size,plates.full.width == full.width,plates.full.height == full.height{
            return NormieMotionPicture(full:full,solids:plates.solids,ink:separate(full,plates.solids),size:view.bounds.size,glasses:glasses,plates:plates.plates,waveform:waveform).preparingInk()
        }
        // Draw the background through the same draw overrides, without hiding an editor (which could resign an IME).
        let c=CGContext(data:nil,width:full.width,height:full.height,bitsPerComponent:8,bytesPerRow:full.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x:CGFloat(full.width)/max(1,view.bounds.width),y:CGFloat(full.height)/max(1,view.bounds.height))
        if view.isFlipped{c.translateBy(x:0,y:view.bounds.height);c.scaleBy(x:1,y:-1)}
        for v in tree where Self.includes(v,in:view) {
            if v is NSGlassEffectView || v is NativeComposerVoiceWaveform || v is NSTextField || v is NSTextView || v is NSImageView || v is NSProgressIndicator || v is NSPopUpButton || v is ToolsTerminalView || v is ToolsTerminalSurface{continue}
            if tree.contains(where:{$0 is NSGlassEffectView && v.isDescendant(of:$0)}){continue}
            c.saveGState();let r=v.convert(v.bounds,to:view);c.translateBy(x:r.minX,y:r.minY)
            if v.isFlipped != view.isFlipped{c.translateBy(x:0,y:v.bounds.height);c.scaleBy(x:1,y:-1)}
            c.clip(to:v.bounds)
            if let color=v.layer?.backgroundColor{c.setFillColor(color);let radius=v.layer?.cornerRadius ?? 0;c.addPath(CGPath(roundedRect:v.bounds,cornerWidth:radius,cornerHeight:radius,transform:nil));c.fillPath()}
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:v.isFlipped)
            if let b=v as? NSButton{let t=b.title,i=b.image;b.title="";b.image=nil;b.draw(b.bounds);b.title=t;b.image=i}else{v.draw(v.bounds)}
            NSGraphicsContext.restoreGraphicsState();c.restoreGState()
        }
        let background=c.makeImage()!
        return NormieMotionPicture(full:full,solids:background,ink:separate(full,background),size:view.bounds.size,glasses:glasses,plates:Self.plates(background,size:view.bounds.size),waveform:waveform).preparingInk()
    }
    /// Bounded native text region. It includes the future revealed area without resizing/clamping the live clip view.
    static func editor(_ composer:NativeComposer,scale:CGFloat)->NormieMotionPicture?{
        #if M10_COMPOSER_SELFTEST
        let audit=NormieMotionAudit.begin();defer{NormieMotionAudit.end("editor",audit,composer)}
        #endif
        let view=composer.textView,clip=composer.scrollView.contentView
        let rect=CGRect(origin:CGPoint(x:clip.bounds.minX,y:max(0,clip.bounds.minY-220)),size:CGSize(width:max(1,clip.bounds.width),height:max(280,clip.bounds.height)+440))
        let rep:NSBitmapImageRep
        if view.window != nil,let own=view.bitmapImageRepForCachingDisplay(in:rect){rep=own}else{rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(rect.width*scale)),pixelsHigh:Int(ceil(rect.height*scale)),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;rep.size=rect.size}
        if let bytes=rep.bitmapData{memset(bytes,0,rep.bytesPerRow*rep.pixelsHigh)}
        view.cacheDisplay(in:rect,to:rep)
        guard let image=rep.cgImage,let space=image.colorSpace,let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
        let clear=c.makeImage()!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));let ink=c.makeImage()!
        return NormieMotionPicture(full:ink,solids:clear,ink:ink,size:rect.size,glasses:[],plates:[],waveform:nil,editorOrigin:rect.origin).preparingInk()
    }
    /// Separate disconnected plates. Stretching the WHOLE transparent composer bitmap would move its buttons away
    /// from their glyphs; each circle/chip must keep its own leading edge. An opaque terminal is one rectangle.
    nonisolated static func plates(_ image:CGImage,size:CGSize,shouldContinue:()->Bool = {true})->[(CGRect,CGImage)]{
        let w=image.width,h=image.height,c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:w,height:h));let bytes=c.data!.assumingMemoryBound(to:UInt8.self)
        var previous=[Int](repeating:0,count:w),current=previous,parents=[0],boxes=[CGRect.zero]
        func find(_ id:Int)->Int{var p=id;while parents[p] != p{p=parents[p]};return p}
        for y in 0..<h{
            if y%32 == 0 && !shouldContinue(){return []}
            for x in 0..<w{
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
        return roots.values.sorted{$0.minY == $1.minY ? $0.minX<$1.minX:$0.minY<$1.minY}.compactMap{r in
            guard let crop=image.cropping(to:r) else{return nil}
            return (CGRect(x:r.minX*size.width/CGFloat(w),y:r.minY*size.height/CGFloat(h),width:r.width*size.width/CGFloat(w),height:r.height*size.height/CGFloat(h)),crop)
        }
    }
    /// Source-over matting. Transparent plates solve by alpha; opaque terminal backgrounds use the minimum alpha
    /// whose premultiplied RGB is legal. Compositing ink over the captured plate reconstructs the source (rounding ≤1).
    nonisolated static func separate(_ full: CGImage,_ background: CGImage,shouldContinue:()->Bool = {true}) -> CGImage {
        let w=full.width,h=full.height,space=CGColorSpaceCreateDeviceRGB()
        func pixels(_ image: CGImage) -> CGContext { let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!; c.draw(image,in:CGRect(x:0,y:0,width:w,height:h)); return c }
        let source=pixels(full),base=pixels(background)
        let a=source.data!.assumingMemoryBound(to:UInt8.self),b=base.data!.assumingMemoryBound(to:UInt8.self)
        let words=source.data!.assumingMemoryBound(to:UInt32.self),baseWords=base.data!.assumingMemoryBound(to:UInt32.self)
        for y in 0..<h {
            if y%32 == 0 && !shouldContinue(){return full}
            for x in 0..<w {
            let i=(y*w+x)*4
            // Nearly all pixels are unchanged plates/empty canvas. Avoid floating-point matting altogether there.
            if words[i/4] == baseWords[i/4]{words[i/4]=0;continue}
            let fa=Float(a[i+3])/255,ba=Float(b[i+3])/255
            var alpha=ba<0.999 ? max(0,min(1,(fa-ba)/(1-ba))):0
            if ba>=0.999 { for k in 0..<3 { let f=Float(a[i+k])/255,v=Float(b[i+k])/255; alpha=max(alpha,f>=v ? (f-v)/max(1e-9,1-v):(v-f)/max(1e-9,v)) } }
            for k in 0..<3 { a[i+k]=UInt8(max(0,min(255,((Float(a[i+k])-Float(b[i+k])*(1-alpha))).rounded()))) }
            a[i+3]=UInt8(max(0,min(255,(alpha*255).rounded())))
        }
        }
        return source.makeImage()!
    }
}

/// Only the glyph plane is replicated. Solids use a real frame stretch and a nine-slice (corners remain round).
/// Native controls remain mounted, with their semantic frames, responder/selection and AX identities intact.
@MainActor final class NormieMotionProxy {
    let layer=CALayer(), solid=CALayer(), trail=ChordTrail(), glyph=CALayer()
    private weak var source: NSView?
    var nativeSource:NSView?{source}
    private(set) var earlierRect=CGRect.zero
    private(set) var idealRect=CGRect.zero
    private var savedOpacity: Float=1
    var picture: NormieMotionPicture
    private(set) var sample=ExposureSample.still
    private(set) var solidRect=CGRect.zero
    private(set) var nativeRect=CGRect.zero
    var settings=ExposureSettings()
    private var plateLayers:[CALayer]=[]
    var fixedInkSize=false
    weak var clippingView:NSView?{didSet{CATransaction.begin();CATransaction.setDisableActions(true);prepareInkClip();CATransaction.commit()}}
    func replaceContent(_ next:NormieMotionPicture){
        #if M10_COMPOSER_SELFTEST
        let audit=NormieMotionAudit.begin();defer{NormieMotionAudit.end("replace",audit,source)}
        #endif
        picture=NormieMotionPicture(full:next.full,solids:next.solids,ink:next.ink,size:next.size,glasses:picture.glasses,plates:next.plates,waveform:picture.waveform ?? next.waveform,editorOrigin:next.editorOrigin,inkRegion:next.inkRegion).preparingInk()
        CATransaction.begin();CATransaction.setDisableActions(true);rebuildPlates();configureInk();configureScale();CATransaction.commit()
    }
    private struct LiveGlass {let view:NSGlassEffectView;weak var parent:NSView?;let index:Int,frame:CGRect,local:CGRect;weak var motionParent:NSView?}
    private var glass:[LiveGlass]=[]
    private weak var host:NSView?
    private var foreground:NormieMotionForeground?
    private var glassClip:NormieMotionGlassClip?
    private let inkClip=CAShapeLayer()
    private var inkClipRect:CGRect?
    private weak var waveParent:NSView?
    private var floatingWave:NativeComposerVoiceWaveform?
    private var waveFrame=CGRect.zero
    init(source: NSView?, picture: NormieMotionPicture, in host: NSView) {
        #if M10_COMPOSER_SELFTEST
        let audit=NormieMotionAudit.begin();defer{NormieMotionAudit.end("proxy-init",audit,source)}
        #endif
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        self.source=source;self.picture=picture.preparingInk();self.host=host
        host.wantsLayer=true
        layer.addSublayer(solid); layer.addSublayer(trail.layer); trail.layer.addSublayer(glyph)
        rebuildPlates();configureInk()
        solid.contentsGravity = .resize;glyph.contentsGravity = .resize
        let x=min(0.49,20/max(1,picture.size.width)),y=min(0.49,20/max(1,picture.size.height))
        solid.contentsCenter=CGRect(x:x,y:y,width:1-2*x,height:1-2*y)
        let front:NormieMotionForeground
        if let existing=host.subviews.compactMap({$0 as? NormieMotionForeground}).first{front=existing}
        else{front=NormieMotionForeground(frame:host.bounds);front.wantsLayer=true;front.autoresizesSubviews=false;front.setAccessibilityElement(false);host.addSubview(front,positioned:.above,relativeTo:nil)}
        foreground=front;front.layer?.addSublayer(layer);layer.isHidden=true
        configureScale()
        if let source { source.wantsLayer=true; savedOpacity=source.layer?.opacity ?? 1 }
        // Prepare once, before motion. Gate crossings change only ink; never rebuild a glass backdrop there.
        mountGlass()
    }
    private func configureScale(){
        let scale=max(1,CGFloat(picture.full.width)/max(1,picture.size.width))
        for node in [layer,solid,trail.layer,glyph]+plateLayers{
            node.contentsScale=scale;node.shouldRasterize=false
        }
        foreground?.layer?.contentsScale=scale
    }
    private func configureInk(){
        glyph.contents=picture.inkRegion?.image ?? picture.ink
        glyph.isHidden=picture.inkRegion?.image == nil
    }
    private func prepareInkClip(){
        if let clippingView,let host{
            let rect=clippingView.convert(clippingView.bounds,to:host)
            if inkClipRect != rect{
                #if M10_COMPOSER_SELFTEST
                let audit=NormieMotionAudit.begin();defer{NormieMotionAudit.end("mask-path",audit,source)}
                #endif
                inkClip.path=CGPath(rect:rect,transform:nil);inkClipRect=rect
            }
            if layer.mask !== inkClip{layer.mask=inkClip}
        }else if layer.mask != nil{layer.mask=nil;inkClipRect=nil}
    }
    private func rebuildPlates(){
        #if M10_COMPOSER_SELFTEST
        let audit=NormieMotionAudit.begin();defer{NormieMotionAudit.end("plates",audit,source)}
        #endif
        plateLayers.forEach{$0.removeFromSuperlayer()};plateLayers=[]
        for (rect,image) in picture.plates{let p=CALayer();p.contents=image;p.contentsGravity = .resize
            let x=min(0.49,20/max(1,rect.width)),y=min(0.49,20/max(1,rect.height))
            p.contentsCenter=CGRect(x:x,y:y,width:1-2*x,height:1-2*y);p.contentsScale=max(1,CGFloat(image.width)/max(1,rect.width));solid.addSublayer(p);plateLayers.append(p)
        }
    }
    private func mountGlass(){
        guard glass.isEmpty,!picture.glasses.isEmpty,let host else{return}
        for material in picture.glasses where material.frame.intersects(CGRect(origin:.zero,size:picture.size)) {
            let g=source != nil ? material.view ?? NSGlassEffectView():NSGlassEffectView()
            let parent=source != nil ? g.superview:nil,index=parent?.subviews.firstIndex(of:g) ?? 0,frame=g.frame
            let inherited=source?.superview ?? material.backdropParent
            let target:NSView
            if let inherited,inherited === host || inherited.isDescendant(of:host){
                // Approval glass remains inside its ORIGINAL native scroll/clip backdrop domain. Putting it in a
                // new masksToBounds group on the detail root isolates its backdrop and changes the material.
                target=inherited
            }else{
                if glassClip == nil{
                    let clip=NormieMotionGlassClip();clip.drawsBackground=false;clip.wantsLayer=true
                    var ancestor=source;while let next=ancestor?.superview,next !== host{ancestor=next}
                    host.addSubview(clip,positioned:.below,relativeTo:ancestor);glassClip=clip
                }
                target=glassClip!
            }
            if g.style != material.style{g.style=material.style}
            if g.cornerRadius != material.radius{g.cornerRadius=material.radius}
            if g.tintColor != material.tint{g.tintColor=material.tint}
            glass.append(.init(view:g,parent:parent,index:index,frame:frame,local:material.frame,motionParent:target))
            target.addSubview(g,positioned:.below,relativeTo:source?.superview === target ? source:nil)
            if let source{g.frame=target.convert(source.convert(material.frame,to:host),from:host)}
            g.isHidden=host.window == nil
        }
    }
    private func restoreGlass(){
        for material in glass{if let parent=material.parent{let next=parent.subviews.dropFirst(material.index).first;parent.addSubview(material.view,positioned:.below,relativeTo:next);material.view.frame=material.frame;material.view.alphaValue=1;material.view.isHidden=parent.window == nil}else{material.view.removeFromSuperview()}}
        glass=[];glassClip?.removeFromSuperview();glassClip=nil
    }
    func update(now: CGRect, earlier: CGRect, profile: DisplayProfile, opacity: CGFloat=1, force: Bool=false, ideal: CGRect?=nil) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        nativeRect=now;earlierRect=earlier;idealRect=ideal ?? now
        settings.maxCopies=max(40,1+Int(ceil(MotionStep.edge(now,earlier)/settings.spacing)))
        sample=ExposureSample(now:now,earlier:earlier,frameInterval:profile.frameInterval,mmPerPoint:profile.mmPerPoint,settings:settings)
        // An authored M9 tail can already be represented by the native view at this exact pose. Do not keep a
        // bitmap admitted just because its spring clock still runs (approval's perceptual duration is .35s).
        let nativeAligned:Bool
        if let source,let host,source.isDescendant(of:host){
            let r=source.convert(source.bounds,to:host)
            nativeAligned=MotionStep.edge(r,now)<1e-7
        }else{nativeAligned=false}
        let active=sample.count>1 || (force && !nativeAligned)
        layer.isHidden = !active;layer.opacity=Float(opacity)
        if let foreground,let host{
            // This view owns no pixels and never hits. Keep its empty container admitted before the first gate;
            // switching NSView visibility on the first fast frame needlessly invalidates AppKit's display tree.
            if foreground.frame != host.bounds{foreground.frame=host.bounds}
            if host.subviews.last !== foreground{host.addSubview(foreground,positioned:.above,relativeTo:nil)}
        }
        savedOpacity=Float(opacity); source?.layer?.opacity=active ? 0:savedOpacity
        let clipRect=clippingView.flatMap{v in host.map{v.convert(v.bounds,to:$0)}} ?? (source is NSScrollView ? now:NormieSolidMotion.rect(now:now,earlier:earlier,profile:profile,settings:settings))
        glassClip?.frame=clipRect
        for material in glass {
            let r=material.local.offsetBy(dx:now.minX,dy:now.minY),old=material.local.offsetBy(dx:earlier.minX,dy:earlier.minY)
            let pose=active ? NormieSolidMotion.rect(now:r,earlier:old,profile:profile,settings:settings):r
            if let parent=material.motionParent,let host{let frame=parent.convert(pose,from:host);if material.view.frame != frame{material.view.frame=frame}}
            if material.view.alphaValue != opacity{material.view.alphaValue=opacity}
            let hidden=material.view.window == nil;if material.view.isHidden != hidden{material.view.isHidden=hidden}
        }
        if active,let waveform=picture.waveform,let wave=waveform.view,wave.active,let host{
            if floatingWave == nil{waveParent=wave.superview;waveFrame=wave.frame;host.addSubview(wave);floatingWave=wave}
            wave.frame=waveform.frame.offsetBy(dx:now.minX,dy:now.minY)
            let s=ExposureSample(now:now,earlier:earlier,frameInterval:profile.frameInterval,mmPerPoint:profile.mmPerPoint,settings:settings)
            wave.setCarryStretch(CGPoint(x:(earlier.midX-now.midX)*s.gate,y:(earlier.midY-now.midY)*s.gate));wave.alphaValue=opacity
        }else{restoreWave()}
        guard active else { trail.reset();return }
        layer.frame=CGRect(origin:.zero,size:layer.superlayer?.bounds.size ?? .zero)
        prepareInkClip()
        solidRect=NormieSolidMotion.rect(now:now,earlier:earlier,profile:profile,settings:settings)
        solid.frame=layer.bounds
        func plateRect(_ local:CGRect,_ frame:CGRect)->CGRect{CGRect(x:frame.minX+local.minX*frame.width/picture.size.width,y:frame.minY+local.minY*frame.height/picture.size.height,width:local.width*frame.width/picture.size.width,height:local.height*frame.height/picture.size.height)}
        for ((local,_),plate) in zip(picture.plates,plateLayers){plate.frame=NormieSolidMotion.rect(now:plateRect(local,now),earlier:plateRect(local,earlier),profile:profile,settings:settings)}
        if let region=picture.inkRegion,region.image != nil{
            glyph.frame=plateRect(region.rect,now)
        }else{glyph.frame=now}
        trail.layer.frame=layer.bounds;trail.settings=settings;trail.update(now:now,earlier:earlier,profile:profile)
    }
    func retire() { CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        source?.layer?.opacity=savedOpacity;source=nil;layer.isHidden=true;layer.removeAllAnimations();layer.removeFromSuperlayer()
        if let foreground{
            if foreground.layer?.sublayers?.isEmpty != false{foreground.removeFromSuperview()}
        }
        foreground=nil;trail.reset()
        restoreGlass();restoreWave()
    }
    private func restoreWave(){if let wave=floatingWave{wave.setCarryStretch(.zero);if let parent=waveParent{parent.addSubview(wave)}else{wave.removeFromSuperview()};wave.frame=waveFrame;wave.alphaValue=1};floatingWave=nil;waveParent=nil}
    isolated deinit { retire() }
}

/// The M9 authored transition and its M10 exposure use the SAME pose function. The enabled switch changes only
/// the exposure, not the spring, geometry, time, fade, or start/stop frames.
@MainActor final class NormieDetailItemMotion {
    enum Kind { case approval, toastIn, toastOut, snappy20, snappy25 }
    let proxy:NormieMotionProxy,from:CGRect,to:CGRect,start:Double,kind:Kind
    let appearing:Bool,fade:Bool
    private weak var carryView:NSView?,coordinateHost:NSView?
    private var carryOrigin=CGPoint.zero,lastCarry=CGPoint.zero,lastCarryTime:Double?
    var duration:Double { kind == .approval || kind == .snappy20 || kind == .snappy25 ? 0.85:kind == .toastOut ? 0.2:NormieToastMotion.duration }
    init(proxy:NormieMotionProxy,from:CGRect,to:CGRect,start:Double,kind:Kind,appearing:Bool=true,fade:Bool=true,carriedBy:NSView?=nil,host:NSView?=nil){
        self.proxy=proxy;self.from=from;self.to=to;self.start=start;self.kind=kind;self.appearing=appearing;self.fade=fade;carryView=carriedBy;coordinateHost=host
        if let carriedBy,let host{carryOrigin=carriedBy.convert(CGPoint.zero,to:host)}
    }
    func value(_ elapsed:Double)->CGFloat {
        guard elapsed>0 else{return 0};if elapsed>=duration{return 1}
        switch kind {
        case .approval:return CGFloat(NormieApprovalMotion.value(elapsed))
        case .snappy20:return CGFloat(SwiftUI.Spring.snappy(duration:0.2).value(target:Double(1),initialVelocity:Double(0),time:elapsed))
        case .snappy25:return CGFloat(SwiftUI.Spring.snappy(duration:0.25).value(target:Double(1),initialVelocity:Double(0),time:elapsed))
        case .toastIn:return CGFloat(NormieToastMotion.value(elapsed))
        case .toastOut:
            let x=elapsed/duration;var lo=0.0,hi=1.0
            for _ in 0..<30{let t=(lo+hi)/2,v=3*(1-t)*t*t*0.58+t*t*t;if v<x{lo=t}else{hi=t}}
            let t=(lo+hi)/2;return CGFloat(3*(1-t)*t*t+t*t*t)
        }
    }
    func rect(at time:Double)->CGRect{Self.mix(from,to,value(time-start))}
    @discardableResult func advance(_ time:Double,profile:DisplayProfile,enabled:Bool)->Bool {
        let t=time-start,p=value(t),opacity:CGFloat=fade ? min(1,max(0,appearing ? p:1-p)):1
        proxy.settings.enabled=enabled
        let carry:CGPoint
        if let carryView,let coordinateHost{let p=carryView.convert(CGPoint.zero,to:coordinateHost);carry=CGPoint(x:p.x-carryOrigin.x,y:p.y-carryOrigin.y)}else{carry = .zero}
        let earlierCarry=lastCarryTime == time ? carry:lastCarry
        let pose=rect(at:time).offsetBy(dx:carry.x,dy:carry.y)
        if let card=proxy.nativeSource as? NativeTranscriptCard,let host=coordinateHost,let parent=card.superview,
           from.size == to.size{card.frame=parent.convert(pose,from:host)}
        proxy.update(now:pose,earlier:rect(at:time-profile.frameInterval).offsetBy(dx:earlierCarry.x,dy:earlierCarry.y),profile:profile,opacity:opacity,force:true)
        lastCarry=carry;lastCarryTime=time
        return t<duration
    }
    static func mix(_ a:CGRect,_ b:CGRect,_ t:CGFloat)->CGRect{CGRect(x:a.minX+(b.minX-a.minX)*t,y:a.minY+(b.minY-a.minY)*t,width:a.width+(b.width-a.width)*t,height:a.height+(b.height-a.height)*t)}
}
