import AppKit
import QuartzCore

/// Immutable render input. CGImage/CGColor/CGPath are retained immutable Core Graphics values.
/// Capturing is main-only; rendering does not access a view, layer, dynamic color or presentation tree.
struct ModePhotoSnapshot: @unchecked Sendable {
    struct Node {
        let frame:CGRect,opacity:CGFloat,background:CGColor?,image:CGImage?
        let radius:CGFloat,continuous:Bool,border:CGColor?,borderWidth:CGFloat,clips:Bool
        let children:[Node]
        var decoration:CGImage?=nil
        var clipPath:CGPath?=nil
        var clipEvenOdd=false
    }
    let root:Node,size:CGSize,scale:CGFloat,colorSpace:CGColorSpace
    /// Cache the small, immutable decoration when it is created, outside the turn's freeze/compose path.
    /// Native CA supplies the continuous-corner/border rasterization; generic path approximations do not.
    @MainActor static func cacheDecoration(_ layer:CALayer,scale:CGFloat) {
        guard layer.sublayers?.isEmpty ?? true,layer.bounds.width>0,layer.bounds.height>0 else {return}
        let width=max(1,Int(ceil(layer.bounds.width*scale))),height=max(1,Int(ceil(layer.bounds.height*scale)))
        guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return}
        c.scaleBy(x:scale,y:scale);layer.render(in:c)
        layer.setValue(c.makeImage(),forKey:"modeImmutableDecoration")
    }
    @MainActor static func fadeNativeSource(_ view:NSView,begin:Double,duration:Double,to target:Float=0) {
        guard let layer=view.layer else {return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        let fade=CABasicAnimation(keyPath:"opacity")
        fade.fromValue=layer.presentation()?.opacity ?? layer.opacity;fade.toValue=target
        fade.beginTime=layer.convertTime(begin,from:nil);fade.duration=duration
        fade.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut);fade.fillMode = .both;fade.isRemovedOnCompletion=false
        layer.opacity=target;layer.add(fade,forKey:"mode.turn.native-out")
        CATransaction.commit()
    }
    /// Stop an abandoned Native fade at its displayed opacity before preparing a turn curtain.
    @MainActor static func freezeNativeFades(_ view:NSView) {
        if let layer=view.layer {
            let opacity=layer.presentation()?.opacity ?? layer.opacity
            layer.removeAnimation(forKey:"mode.normie")
            // AppKit animator opacity is also abandoned; do not cancel layout/scroll animations.
            for key in layer.animationKeys() ?? [] {
                if let animation=layer.animation(forKey:key) as? CABasicAnimation,animation.keyPath == "opacity" {layer.removeAnimation(forKey:key)}
            }
            layer.opacity=opacity
        }
        for child in view.subviews {freezeNativeFades(child)}
    }
    @MainActor static func capture(_ view:NSView,size:CGSize,scale:CGFloat)->Self {
        func layer(_ source:CALayer,parentBounds:CGRect,parentFlipped:Bool)->Node {
            let pose=source.presentation() ?? source
            let image:CGImage? = source.contents.flatMap {CFGetTypeID($0 as CFTypeRef) == CGImage.typeID ? ($0 as! CGImage):nil}
            let frame=parentFlipped ? pose.frame:CGRect(x:pose.frame.minX,y:parentBounds.minY+parentBounds.maxY-pose.frame.maxY,width:pose.frame.width,height:pose.frame.height)
            var node=Node(frame:frame,opacity:pose.isHidden ? 0:CGFloat(pose.opacity),background:pose.backgroundColor,image:image,
                          radius:pose.cornerRadius,continuous:pose.cornerCurve == .continuous,border:pose.borderColor,borderWidth:pose.borderWidth,clips:pose.masksToBounds,
                          children:(source.sublayers ?? []).map {layer($0,parentBounds:pose.bounds,parentFlipped:source.isGeometryFlipped)})
            if let cached=source.value(forKey:"modeImmutableDecoration"),CFGetTypeID(cached as CFTypeRef) == CGImage.typeID {
                node.decoration=(cached as! CGImage)
            }
            if let mask=source.mask as? CAShapeLayer {node.clipPath=mask.path;node.clipEvenOdd=mask.fillRule == .evenOdd}
            // Freeze exactly what was displayed; workers never re-read a newer pose.
            source.removeAllAnimations();source.bounds=pose.bounds;source.position=pose.position;source.opacity=pose.opacity;source.transform=pose.transform
            return node
        }
        func captureView(_ view:NSView)->Node {
            let pose=view.layer?.presentation() ?? view.layer
            let childLayers=Set(view.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
            let children=(view.layer?.sublayers ?? []).filter {!childLayers.contains(ObjectIdentifier($0))}.map {layer($0,parentBounds:view.bounds,parentFlipped:view.isFlipped)}+view.subviews.map(captureView)
            let nativeFrame=view.frame
            let frame: CGRect
            if let parent=view.superview,!parent.isFlipped {frame=CGRect(x:nativeFrame.minX,y:parent.bounds.minY+parent.bounds.maxY-nativeFrame.maxY,width:nativeFrame.width,height:nativeFrame.height)} else {frame=nativeFrame}
            let node=Node(frame:frame,opacity:view.isHidden ? 0:CGFloat(pose?.opacity ?? Float(view.alphaValue)),background:pose?.backgroundColor,image:nil,
                          radius:pose?.cornerRadius ?? 0,continuous:pose?.cornerCurve == .continuous,border:pose?.borderColor,borderWidth:pose?.borderWidth ?? 0,clips:pose?.masksToBounds ?? false,children:children)
            if let own=view.layer,let pose {own.removeAllAnimations();own.opacity=pose.opacity}
            return node
        }
        return .init(root:captureView(view),size:size,scale:scale,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
    }
    func render()->CGImage? {
        let width=max(1,Int(ceil(size.width*scale))),height=max(1,Int(ceil(size.height*scale)))
        guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        c.translateBy(x:0,y:CGFloat(height));c.scaleBy(x:scale,y:-scale)
        func supported(_ node:Node)->Bool {
            // Never substitute a generic rounded path for a native continuous decoration.
            if node.continuous,node.radius>0,node.decoration == nil {return false}
            return node.children.allSatisfy(supported)
        }
        guard supported(root) else {return nil}
        func shape(_ rect:CGRect,_ radius:CGFloat)->CGPath {
            let r=min(radius,min(rect.width,rect.height)/2)
            return CGPath(roundedRect:rect,cornerWidth:r,cornerHeight:r,transform:nil)
        }
        func draw(_ n:Node) {
            guard n.opacity>0 else {return}
            c.saveGState();c.translateBy(x:n.frame.minX,y:n.frame.minY)
            let rect=CGRect(origin:.zero,size:n.frame.size),outline=shape(rect,n.radius)
            c.setAlpha(n.opacity);c.beginTransparencyLayer(auxiliaryInfo:nil)
            if n.clips {c.addPath(outline);c.clip()}
            if let path=n.clipPath {c.addPath(path);c.clip(using:n.clipEvenOdd ? .evenOdd:.winding)}
            if let decoration=n.decoration {
                c.saveGState();c.translateBy(x:0,y:rect.height);c.scaleBy(x:1,y:-1);c.draw(decoration,in:rect);c.restoreGState()
                c.endTransparencyLayer();c.restoreGState();return
            }
            if let color=n.background {c.setFillColor(color);c.addPath(outline);c.fillPath()}
            if let image=n.image {c.saveGState();c.translateBy(x:0,y:rect.height);c.scaleBy(x:1,y:-1);c.draw(image,in:rect);c.restoreGState()}
            for child in n.children {draw(child)}
            if let border=n.border,n.borderWidth>0 {
                c.setStrokeColor(border);c.setLineWidth(n.borderWidth)
                c.addPath(shape(rect.insetBy(dx:n.borderWidth/2,dy:n.borderWidth/2),max(0,n.radius-n.borderWidth/2)));c.strokePath()
            }
            c.endTransparencyLayer();c.restoreGState()
        }
        draw(root);return c.makeImage()
    }
}
