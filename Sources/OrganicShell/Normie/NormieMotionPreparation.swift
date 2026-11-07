import AppKit
import QuartzCore

private final class NormieMotionCancellation:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    func cancel(){lock.lock();cancelled=true;lock.unlock()}
    var active:Bool {lock.lock();defer{lock.unlock()};return !cancelled}
}

/// A single immutable image job crosses the worker boundary. AppKit views, material descriptors and layers never do.
private struct NormiePreparedPixels: @unchecked Sendable {
    let full:CGImage,solids:CGImage,ink:CGImage
    let plates:[(CGRect,CGImage)]
    let region:NormieMotionPicture.InkRegion
    nonisolated static func make(full:CGImage,solids:CGImage,size:CGSize,editor:Bool,cancellation:NormieMotionCancellation)->Self? {
        guard cancellation.active else{return nil}
        let ink=editor ? full:NormieMotionPicture.separate(full,solids,shouldContinue:{cancellation.active})
        guard cancellation.active else{return nil}
        let plates=editor ? []:NormieMotionPicture.plates(solids,size:size,shouldContinue:{cancellation.active})
        guard cancellation.active else{return nil}
        let region=NormieMotionPicture.inkRegion(ink,size:size,shouldContinue:{cancellation.active})
        guard cancellation.active else{return nil}
        return .init(full:full,solids:solids,ink:ink,plates:plates,region:region)
    }
}

/// One bounded AppKit tile per idle turn; expensive matting/connected components/ink bounds run on a utility queue.
/// Captures remain private until the owner validates its complete semantic key again on the main actor.
@MainActor final class NormieIdleMotionCapture {
    static let orreryEnabled=ProcessInfo.processInfo.environment["M11_MODE_ORRERY_FLIGHT"] != "0"
    /// ToolsTerminalView.draw ignores dirtyRect and visits every cell, including blanks. Its owning module must
    /// expose a bounded renderer/immutable visible-cell snapshot before it can join this idle tile queue.
    static func supports(_ source:NSView)->Bool {
        if source is ToolsTerminalView || source is ToolsTerminalSurface {return false}
        return source.subviews.allSatisfy(supports)
    }
    private let cancellation=NormieMotionCancellation()
    isolated deinit{cancellation.cancel()}
    let source:NSView,scale:CGFloat,rect:CGRect
    private let tree:[NSView],glassViews:[NSGlassEffectView]
    private let full:CGContext,solids:CGContext
    private let editor:Bool
    private var x:CGFloat,y:CGFloat,background=false,submitted=false
    private let glasses:[NormieMotionPicture.Glass]
    private let waveform:NormieMotionPicture.Waveform?
    private(set) var result:NormieMotionPicture?
    private(set) var maxSliceMS=0.0
    var complete:Bool {result != nil}
    var waitingForPixels:Bool {submitted && result == nil}
    init?(_ source:NSView,scale:CGFloat,composer:NativeComposer?=nil) {
        self.source=source;self.scale=scale
        editor=composer != nil
        if let composer {
            let clip=composer.scrollView.contentView
            rect=CGRect(x:clip.bounds.minX,y:max(0,clip.bounds.minY-220),width:max(1,clip.bounds.width),height:max(280,clip.bounds.height)+440)
        } else {rect=source.bounds}
        guard Self.supports(source),!rect.isEmpty,!(source is NSGlassEffectView) else{return nil}
        func all(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(all)}
        tree=all(source);glassViews=tree.compactMap{$0 as? NSGlassEffectView}
        guard glassViews.allSatisfy({$0.contentView?.subviews.isEmpty != false}) else{return nil}
        glasses=glassViews.map{.init(view:$0,frame:$0.convert($0.bounds,to:source),style:$0.style,radius:$0.cornerRadius,tint:$0.tintColor,backdropParent:source.superview)}
        let wave=(source as? NativeComposer)?.voiceWaveform
        waveform=wave.flatMap{$0.active ? .init(view:$0,frame:$0.convert($0.bounds,to:source)):nil}
        let w=Int(ceil(rect.width*scale)),h=Int(ceil(rect.height*scale))
        guard let f=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:source.window?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
              let s=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
        full=f;solids=s;x=rect.minX;y=rect.minY
    }
    func step() {
        guard !submitted else{return}
        let began=CACurrentMediaTime()
        defer{maxSliceMS=max(maxSliceMS,(CACurrentMediaTime()-began)*1000)}
        ModeSignposts.operation("NormieMotionPrewarmSlice",detail:background ? "plates draw":"foreground draw") {
            let tile=CGRect(x:x,y:y,width:min(256,rect.maxX-x),height:min(48,rect.maxY-y))
            draw(tile,plates:background)
            x+=256
            if x>=rect.maxX {x=rect.minX;y+=48}
            if y>=rect.maxY {
                if !background && !editor {background=true;x=rect.minX;y=rect.minY}
                else {submit()}
            }
        }
    }
    private func submit() {
        submitted=true
        let f=full.makeImage()!,s=solids.makeImage()!,size=rect.size,isEditor=editor,cancellation=self.cancellation
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let value=NormiePreparedPixels.make(full:f,solids:s,size:size,editor:isEditor,cancellation:cancellation) else{return}
            DispatchQueue.main.async { [weak self] in
                guard let self else{return}
                self.result=NormieMotionPicture(full:value.full,solids:value.solids,ink:value.ink,size:size,glasses:self.glasses,plates:value.plates,waveform:self.waveform,editorOrigin:isEditor ? self.rect.origin:nil,inkRegion:value.region)
            }
        }
    }
    private func draw(_ tile:CGRect,plates:Bool) {
        CATransaction.begin();CATransaction.setDisableActions(true);defer{CATransaction.commit()}
        let hidden=glassViews.map{($0,$0.isHidden)};for (g,_) in hidden{g.isHidden=true}
        let opacity=source.layer?.opacity;source.layer?.opacity=1
        defer{for(g,h) in hidden{g.isHidden=h};if let opacity{source.layer?.opacity=opacity}}
        let c=plates ? solids:full
        c.saveGState();defer{c.restoreGState()}
        // Draw directly into the final canvas. An extra per-tile image/colour conversion can change edge texels.
        let sx=CGFloat(c.width)/rect.width,sy=CGFloat(c.height)/rect.height
        c.scaleBy(x:sx,y:sy)
        if source.isFlipped {c.translateBy(x:-rect.minX,y:rect.maxY);c.scaleBy(x:1,y:-1)} else {c.translateBy(x:-rect.minX,y:-rect.minY)}
        source.effectiveAppearance.performAsCurrentDrawingAppearance {
            for v in tree where NormieMotionPicture.includes(v,in:source) {
                if v is NSGlassEffectView || v is NativeComposerVoiceWaveform || v is NSTextInsertionIndicator || glassViews.contains(where:{v.isDescendant(of:$0)}){continue}
                if plates && (v is NSTextField || v is NSTextView || v is NSImageView || v is NSProgressIndicator || v is NSPopUpButton || v is ToolsTerminalView || v is ToolsTerminalSurface){continue}
                let dirty=source.convert(tile,to:v).intersection(v.bounds)
                guard !dirty.isEmpty else{continue}
                c.saveGState();c.clip(to:tile)
                if !plates {
                    var parent=Self.orreryEnabled && v === source ? nil:v.superview
                    while let a=parent,a !== source {if a is NSClipView || a.layer?.masksToBounds == true{c.clip(to:a.convert(a.bounds,to:source))};parent=a.superview}
                }
                let o=v.convert(CGPoint.zero,to:source),px=v.convert(CGPoint(x:1,y:0),to:source),py=v.convert(CGPoint(x:0,y:1),to:source)
                c.concatenate(CGAffineTransform(a:px.x-o.x,b:px.y-o.y,c:py.x-o.x,d:py.y-o.y,tx:o.x,ty:o.y));c.clip(to:v.bounds)
                if let color=v.layer?.backgroundColor {c.setFillColor(color);let radius=v.layer?.cornerRadius ?? 0;c.addPath(CGPath(roundedRect:v.bounds,cornerWidth:radius,cornerHeight:radius,transform:nil));c.fillPath()}
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:v.isFlipped)
                if plates,let b=v as? NSButton {let t=b.title,i=b.image;b.title="";b.image=nil;b.draw(dirty);b.title=t;b.image=i} else {v.draw(v is NSTextField || v is NSImageView || v is NSButton ? v.bounds:dirty)}
                NSGraphicsContext.restoreGraphicsState();c.restoreGState()
            }
        }
    }
}
