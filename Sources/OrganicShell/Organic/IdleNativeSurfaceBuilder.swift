import AppKit
import QuartzCore

/// Organic viewport-only variant of the validated own-draw capture; 256 x 32 pt tiles.
@MainActor final class M11IdleSurfaceBuilder {
    #if M11_MODE_SELFTEST
    static var verificationLegacyVisibility=false
    var verificationViews:[NSView] {views.map(\.view)}
    #endif
    private let root:NSView, source:NSView, scale:CGFloat
    private struct PaintView {let view:NSView;let detachedRoot:NSView?;let rect:CGRect?;let clip:CGRect?}
    private let views:[PaintView], glass:[ModeSurfacePicture.Glass]
    private let rects:[CGRect]
    private var tiles:[ModeSurfacePicture.Tile]=[]
    private var canvas:CGContext?
    private var viewCursor=0
    private(set) var lastStepSeconds=0.0015
    var ready:Bool {tiles.count == rects.count}
    init(_ root:NSView,scale:CGFloat,includeWindowFrame:Bool=true,excluding:[NSView]=[],detached:[(view:NSView,rect:CGRect,clip:CGRect)]=[]) {
        self.root=root;self.scale=scale
        source=includeWindowFrame ? root.window?.contentView?.superview ?? root:root
        let captureSource=source
        #if M11_MODE_SELFTEST
        let legacy=Self.verificationLegacyVisibility
        #else
        let legacy=false
        #endif
        func walk(_ v:NSView)->[NSView] {
            guard !excluding.contains(where:{$0 === v}), (v === captureSource && !includeWindowFrame) || (!v.isHidden && v.alphaValue>0 && v.layer?.opacity != 0 && (legacy || v.layer?.isHidden != true)) else{return []}
            // A column that has no rect yet is parked behind a fade mask of no size: mounted, not on screen.
            if !legacy,let mask=v.layer?.mask,mask.bounds.isEmpty {return []}
            // The system's caret draws a solid bar here whether or not it's blinking on screen.
            if !legacy,v is NSTextInsertionIndicator {return []}
            if let glass=v as? NSGlassEffectView {return [v]+(glass.contentView.map(walk) ?? [])}
            return [v]+v.subviews.flatMap(walk)
        }
        let live=walk(source)
        views=live.map{PaintView(view:$0,detachedRoot:nil,rect:nil,clip:nil)}+detached.flatMap { entry in
            walk(entry.view).map{PaintView(view:$0,detachedRoot:entry.view,rect:entry.rect,clip:entry.clip)}
        }
        glass=live.compactMap { v in
            guard let g=v as? NSGlassEffectView,g.isDescendant(of:root) else{return nil}
            var top:NSView=g
            while let p=top.superview,p !== root {top=p}
            return .init(view:g,rect:g.convert(g.bounds,to:root),sourcePlane:top)
        }
        var chunks:[CGRect]=[]
        for y in stride(from:CGFloat(0),to:root.bounds.height,by:32) {
            for x in stride(from:CGFloat(0),to:root.bounds.width,by:256) {
                chunks.append(CGRect(x:x,y:y,width:min(256,root.bounds.width-x),height:min(32,root.bounds.height-y)))
            }
        }
        rects=chunks
    }
    func step() {
        guard !ready else{return}
        let rect=rects[tiles.count],started=CACurrentMediaTime()
        let image=ModeSignposts.measure("PrewarmSourceTile",detail:"\(tiles.count) \(rect)") {paint(rect)}
        if let image {tiles.append(.init(rect:rect,image:image))}
        lastStepSeconds=CACurrentMediaTime()-started
    }
    func finish()->ModeSurfacePicture? {guard ready else{return nil};let picture=ModeSurfacePicture(tiles:tiles,glasses:glass,size:root.bounds.size,scale:scale);picture.root=root;return picture}
    private func paint(_ rect:CGRect)->CGImage? {
        let w=max(1,Int(ceil(rect.width*scale))),h=max(1,Int(ceil(rect.height*scale)))
        let space=root.window?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
        let c:CGContext
        if let canvas {c=canvas}
        else {
            c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.translateBy(x:0,y:CGFloat(h));c.scaleBy(x:scale,y:-scale);c.translateBy(x:-rect.minX,y:-rect.minY);c.clip(to:rect)
            canvas=c
        }
        let started=CACurrentMediaTime()
        NativeTranscriptCard.drawsMotionPlate=true
        defer {NativeTranscriptCard.drawsMotionPlate=false}
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            while viewCursor<views.count {
                let entry=views[viewCursor];viewCursor+=1
                guard !(entry.view is NSGlassEffectView),entry.view === root || !entry.view.isHidden else {continue}
                let v=entry.view
                // Hidden ancestors OUTSIDE the capture root do not suppress a prepared target sidebar.
                @MainActor func mapped(_ rect:CGRect)->CGRect {
                    if let detached=entry.detachedRoot,let destination=entry.rect {return v.convert(rect,to:detached).offsetBy(dx:destination.minX,dy:destination.minY)}
                    return v.convert(rect,to:root)
                }
                let visible=mapped(v.bounds)
                guard visible.intersects(rect) else{continue}
                c.saveGState()
                var opacity=v.alphaValue,opacityParent=v.superview
                while let ancestor=opacityParent,ancestor !== source.superview {opacity *= ancestor.alphaValue;opacityParent=ancestor.superview}
                c.setAlpha(opacity)
                if let clip=entry.clip {c.clip(to:clip)}
                var parent=v.superview
                while let ancestor=parent,ancestor !== source.superview {
                    if ancestor is NSClipView || ancestor.layer?.masksToBounds == true {c.clip(to:ancestor.convert(ancestor.bounds,to:root))}
                    parent=ancestor.superview
                }
                // Ancestors own the canvas, not a glass surface's blank pixels. Keep the original live glass.
                let hasGlass=glass.contains { $0.view?.isDescendant(of:v) == true }
                @MainActor func mappedPoint(_ point:CGPoint)->CGPoint {let r=mapped(CGRect(origin:point,size:.zero));return r.origin}
                let o=mappedPoint(.zero),x=mappedPoint(CGPoint(x:1,y:0)),y=mappedPoint(CGPoint(x:0,y:1))
                c.concatenate(.init(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y))
                c.clip(to:v.bounds)
                @MainActor func clipGlass() {
                    // Intersect individual complements; overlapping material rectangles never XOR-fill.
                    for g in glass {
                        let path=CGMutablePath();path.addRect(v.bounds);path.addRect(v.convert(g.rect,from:root))
                        c.addPath(path);c.clip(using:.evenOdd)
                    }
                }
                if let color=v.layer?.backgroundColor {
                    c.saveGState();if hasGlass {clipGlass()};c.setFillColor(color)
                    let corner=min(v.layer?.cornerRadius ?? 0,min(v.bounds.width,v.bounds.height)/2)
                    if corner>0 {c.addPath(CGPath(roundedRect:v.bounds,cornerWidth:corner,cornerHeight:corner,transform:nil));c.fillPath()} else {c.fill(v.bounds)}
                    c.restoreGState()
                }
                c.saveGState()
                let canvas=(v as? NormieView).map{$0.fill != nil || $0.canopy} ?? (v === source && source !== root)
                if canvas {clipGlass()}
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:v.isFlipped)
                let transform=CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y)
                v.draw(rect.applying(transform.inverted()).intersection(v.bounds))
                NSGraphicsContext.restoreGraphicsState();c.restoreGState()
                // Only scene-owned CA subtrees. NSView backing layers are drawn through their own draw above.
                let nativeLayers=Set(v.subviews.compactMap{$0.layer}.map(ObjectIdentifier.init))
                func nativeBacking(_ layer:CALayer)->Bool {layer.delegate is NSView || (layer.sublayers ?? []).contains(where:nativeBacking)}
                for l in v.layer?.sublayers ?? [] where !nativeLayers.contains(ObjectIdentifier(l)) && !nativeBacking(l) && !ModeSurfaceBuilder.glassInternal(l) && !l.isHidden && l.opacity>0 {
                    c.saveGState()
                    clipGlass()
                    c.translateBy(x:l.position.x,y:l.position.y);c.concatenate(l.affineTransform())
                    c.translateBy(x:-l.bounds.minX-l.anchorPoint.x*l.bounds.width,y:-l.bounds.minY-l.anchorPoint.y*l.bounds.height)
                    c.setAlpha(opacity*CGFloat(l.opacity));l.render(in:c);c.restoreGState()
                }
                c.restoreGState()
                if CACurrentMediaTime()-started>=0.001 {break}
            }
        }
        guard viewCursor==views.count else{return nil}
        canvas=nil;viewCursor=0
        return c.makeImage()!
    }
}
