import AppKit
import QuartzCore
import ObjectiveC

/// Fail-closed material audit for DECISIONS #56. Audit the source tree, not n conceptual instances.
/// Baking a wash/card into a CGImage does NOT turn it into glyph ink: provenance is checked as well as live layers.
@MainActor enum ReplicaContainerAudit {
    enum Material: String { case glyph, icon, container, unclassified }
    struct Origin { var file: String; var material: Material; var note: String }
    struct Finding {
        var file: String, path: String, scenario: String, frame: Int, time: Double, reason: String, active: Bool
        var fields: [String: Any] { ["file":file,"layerPath":path,"scenario":scenario,"frame":frame,
                                   "time":time,"reason":reason,"active":active] }
    }
    private static let origins = NSMapTable<CALayer, AuditOrigin>.weakToStrongObjects()
    private final class AuditOrigin: NSObject { let value: Origin; init(_ v: Origin) { value=v } }
    /// Required for custom/manual copy hosts, and recommended for every baked texture. Inherited by descendants.
    private static let copyRoots = NSHashTable<CALayer>.weakObjects()
    static func register(_ layer: CALayer, file: String = #filePath, material: Material, note: String = "") {
        origins.setObject(AuditOrigin(Origin(file:file,material:material,note:note)),forKey:layer)
    }
    static func registerCopies(_ layer: CALayer, file: String = #filePath) {
        copyRoots.add(layer)
        if origins.object(forKey:layer) == nil { register(layer,file:file,material:.glyph,note:"manual copy host") }
    }

    static func inspect(_ root: CALayer, scenario: String, frame: Int, time: Double,
                        sourceFile: String = "unregistered", includeDormant: Bool = true,
                        onFinding: ((CALayer, Finding) -> Void)? = nil) -> [Finding] {
        var result: [Finding] = []
        func visit(_ l: CALayer, _ parent: String, _ copied: Bool, _ visible: Bool, _ origin: Origin?) {
            let type = String(describing:type(of:l)), name=l.name ?? type
            let path=parent+"/"+name
            let live=visible && !l.isHidden && number(l, key: "opacity", at: time, fallback: Double(l.opacity))>0
            let constructionFile=objc_getAssociatedObject(l,&constructionKey) as? String
            let own=origins.object(forKey:l)?.value ?? constructionFile.map { Origin(file:$0,material:.unclassified,note:"") } ?? origin
            func fail(_ reason: String) {
                guard includeDormant || live else { return }
                let finding=Finding(file:own?.file ?? sourceFile,path:path,scenario:scenario,frame:frame,time:time,reason:reason,active:live)
                result.append(finding);onFinding?(l,finding)
            }
            let label=(name+" "+type).lowercased()
            if copied {
                if own?.material == .container { fail("container provenance: "+(own?.note ?? "")) }
                if label.contains("backdrop") || label.contains("glass") || label.contains("sdf") { fail("system glass/backdrop") }
                if label.contains("viewbacking") { fail("NSView backing layer class") }
                if let view=l.delegate as? NSView { fail("NSView backing: "+String(describing:Swift.type(of:view))) }
                if let c=l.backgroundColor,c.alpha>0 { fail("nontransparent backgroundColor") }
                if let shape=l as? CAShapeLayer,shape.path != nil {
                    fail("live vector: expected tightly cropped glyph/icon texture")
                    if let fill=shape.fillColor,fill.alpha>0 { fail("filled shape") }
                }
                if l is CAGradientLayer { fail("gradient/wash") }
                if l.shadowOpacity>0 { fail("live shadow") }
                if l.mask != nil || l.masksToBounds { fail("mask/clipping container") }
                if !(l.filters ?? []).isEmpty || !(l.backgroundFilters ?? []).isEmpty || l.compositingFilter != nil { fail("live filter") }
                if l.borderWidth>0,l.borderColor?.alpha ?? 0 > 0 { fail("card/border") }
                if ["wash","bubble","card.background","card-base","shadow"].contains(where:label.contains) { fail("container semantic name") }
                if let contents=l.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                    let image = contents as! CGImage
                    // Raw images cannot prove their material. Fail closed until the capture site supplies provenance.
                    if own == nil || own?.material == .unclassified { fail("unclassified bitmap: register glyph/icon provenance after transparent tight-crop verification") }
                    if looseCrop(image, bounds: l.bounds) { fail("bitmap is not tightly cropped to ink") }
                    if own?.material != .container, image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast {
                        fail("opaque texture (container baked into bitmap)")
                    }
                    if l.bounds.width>64 || l.bounds.height>64 {
                        if solidCanvas(image) { fail("large bitmap with filled canvas (baked container)") }
                    }
                } else if l.contents != nil { fail("non-CGImage replica content") }
                if l is CATextLayer { fail("live text: expected tightly cropped glyph texture") }
            }
            let isCopies=l is CAReplicatorLayer || copyRoots.contains(l)
            let count=number(l,key:"instanceCount",at:time,fallback:Double((l as? CAReplicatorLayer)?.instanceCount ?? 2))
            let childLive=live && (!isCopies || count>1)
            for (i,child) in (l.sublayers ?? []).enumerated() {
                visit(child,path+"[\(i)]",copied || isCopies,childLive,own)
            }
            if let mask=l.mask { visit(mask,path+".mask",copied,live,own) }
        }
        visit(root,"",false,true,nil); return result
    }
    /// Construction-site labels for PRIVATE verifier instrumentation. They do not authorize bitmap material.
    nonisolated(unsafe) private static var constructionKey: UInt8 = 0
    private static func number(_ layer: CALayer, key: String, at time: Double, fallback: Double) -> Double {
        func evaluate(_ a: CAAnimation, _ t: Double) -> Double? {
            let local=t-a.beginTime+a.timeOffset
            if local<0 && a.fillMode != .both && a.fillMode != .backwards { return nil }
            if local>a.duration && a.isRemovedOnCompletion { return nil }
            if let g=a as? CAAnimationGroup {
                for child in (g.animations ?? []).reversed() { if let v=evaluate(child,local) { return v } }
            }
            guard let property=a as? CAPropertyAnimation,property.keyPath==key else { return nil }
            let f=min(1,max(0,local/max(1e-9,a.duration)))
            if let k=a as? CAKeyframeAnimation,let values=k.values as? [NSNumber],!values.isEmpty {
                let times=k.keyTimes?.map(\.doubleValue) ?? values.indices.map{Double($0)/Double(max(1,values.count-1))}
                let i=times.lastIndex(where:{$0<=f}) ?? 0
                if k.calculationMode == .discrete || i>=values.count-1 { return values[min(i,values.count-1)].doubleValue }
                let u=(f-times[i])/max(1e-9,times[i+1]-times[i])
                return values[i].doubleValue+(values[i+1].doubleValue-values[i].doubleValue)*u
            }
            if let b=a as? CABasicAnimation,let from=b.fromValue as? NSNumber,let to=b.toValue as? NSNumber {
                return from.doubleValue+(to.doubleValue-from.doubleValue)*f
            }
            return nil
        }
        let local=layer.convertTime(time,from:nil)
        for k in (layer.animationKeys() ?? []).reversed() { if let a=layer.animation(forKey:k),let v=evaluate(a,local) { return v } }
        return fallback
    }
    private static func looseCrop(_ image: CGImage, bounds: CGRect) -> Bool {
        let w=min(256,image.width),h=min(256,image.height)
        guard w>0,h>0 else { return false }
        var pixels=[UInt8](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes { b in
            let c=CGContext(data:b.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        var x0=w,y0=h,x1 = -1,y1 = -1
        for y in 0..<h { for x in 0..<w where pixels[(y*w+x)*4+3]>1 {
            x0=min(x0,x);y0=min(y0,y);x1=max(x1,x);y1=max(y1,y)
        } }
        guard x1>=x0 else { return false } // An empty retired texture has no visible container.
        // Allow 2pt antialias padding plus one downsample pixel on every edge, at any backing scale.
        let px=max(2,2*Double(w)/max(1,Double(bounds.width)))+1
        let py=max(2,2*Double(h)/max(1,Double(bounds.height)))+1
        return Double(x0)>px || Double(w-1-x1)>px || Double(y0)>py || Double(h-1-y1)>py
    }
    /// Conservative detector, not material authorization: a >64pt canvas filled at its perimeter is a container.
    private static func solidCanvas(_ image: CGImage) -> Bool {
        let w=32,h=32
        var bytes=[UInt8](repeating:0,count:w*h*4)
        let ok=bytes.withUnsafeMutableBytes { b -> Bool in
            guard let c=CGContext(data:b.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                                  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(image,in:CGRect(x:0,y:0,width:w,height:h)); return true
        }
        guard ok else { return false }
        let edges=(0..<w).flatMap { x in [x,(h-1)*w+x] }+(1..<(h-1)).flatMap { y in [y*w,y*w+w-1] }
        return edges.filter { bytes[$0*4+3]>8 }.count > edges.count*9/10
    }
}
