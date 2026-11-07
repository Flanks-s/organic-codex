import AppKit
import QuartzCore

/// A full column can remain full while its width changes (Focused / Split / Ungraft). Its text is never stretched.
/// Two native layouts share the rectangle spring's timeline. On reversal the existing mixture is the departure,
/// so neither a newly captured target nor a native layout can jump into the first frame.
struct ColumnFullMaterial {
    let image: CGImage
    let size: CGSize
    var opacity: Double
    var overlay:CALayer?=nil
    var offsetY:CGFloat=0
    var independentFade=false
    var clipWidth:CGFloat?=nil

    @MainActor func copyOverlay()->CALayer? {
        guard let overlay else {return nil}
        var copies:[ObjectIdentifier:CALayer]=[:]
        let result=M10ColumnTexture.clone(overlay,into:&copies)
        func restore(_ source:CALayer) {
            let copy=copies[ObjectIdentifier(source)]
            copy?.shouldRasterize=source.shouldRasterize;copy?.rasterizationScale=source.rasterizationScale
            copy?.compositingFilter=source.compositingFilter
            for child in source.sublayers ?? [] {restore(child)}
        }
        restore(overlay);return result
    }
}

@MainActor final class ColumnFullReflow {
    let target: ColumnNode.Snapshot
    let layer = CALayer()
    private(set) var overlayLayer:CALayer?
    private var overlays:[(CALayer,Double)]=[]
    private let departure: [ColumnFullMaterial]
    private let arrival: ColumnFullMaterial
    private let width: Spring
    private let oldLayers: [CALayer]
    private let newLayer: CALayer
    let clipBounds:CGRect?
    let clipMask:CALayer?
    var previousClipMask:CALayer?

    init?(from: [ColumnFullMaterial], to target: ColumnNode.Snapshot, width: Spring, scale: CGFloat) {
        guard !from.isEmpty, let image = target.withGoal else { return nil }
        self.departure = from; self.target = target; self.width = width
        let independent=from.contains{$0.independentFade}
        arrival = ColumnFullMaterial(image: image, size: target.transcriptSize, opacity: 1,independentFade:independent)
        if independent {
            let lo=min(0,from.map(\.offsetY).min() ?? 0)
            let hi=max(target.area.height,from.map{$0.offsetY+$0.size.height}.max() ?? 0)
            clipBounds=CGRect(x:0,y:lo,width:target.area.width,height:hi-lo)
        } else {clipBounds=nil}
        if let clipBounds {
            let mask=CALayer();mask.anchorPoint = .zero;mask.backgroundColor=NSColor.black.cgColor;mask.frame=clipBounds
            clipMask=mask
        } else {clipMask=nil}
        func plane(_ material: ColumnFullMaterial) -> CALayer {
            let p = CALayer(); p.anchorPoint = .zero; p.contentsScale = scale; p.contentsGravity = .resize
            p.contents = material.image; p.frame = CGRect(origin: CGPoint(x:0,y:material.offsetY), size: material.size)

            if independent {
                let mask=ColumnNode.fade(),h=material.size.height
                mask.frame=CGRect(x:0,y:0,width:material.clipWidth ?? material.size.width,height:h)
                mask.locations=[0,NSNumber(value:Double(16/h)),NSNumber(value:Double(1-28/h)),1]
                p.mask=mask
            }
            return p
        }
        oldLayers = from.map(plane); newLayer = plane(arrival)
        layer.anchorPoint = .zero; layer.frame = target.area.offsetBy(dx: -target.area.minX, dy: -target.area.minY)
        for old in oldLayers { layer.addSublayer(old) }; layer.addSublayer(newLayer)
        if from.contains(where:{$0.overlay != nil}) {
            let root=CALayer();root.anchorPoint = .zero;overlayLayer=root
            for material in from {
                if let overlay=material.copyOverlay() {
                    let plane=CALayer();plane.anchorPoint = .zero;plane.position.y=material.offsetY
                    plane.addSublayer(overlay);root.addSublayer(plane);overlays.append((plane,material.opacity))
                }
            }
        }
    }

    func progress(at time: Double) -> Double {
        guard abs(width.to - width.from) > 0.0001 else { return 1 }
        return smoothstep(0, 0.94, (width.sample(time).value - width.from) / (width.to - width.from))
    }

    func materials(at time: Double) -> [ColumnFullMaterial] {
        let p = progress(at: time)
        return (departure.map { var material=$0;material.opacity *= 1-p;return material }
            + [{var material=arrival;material.opacity=p;return material}()]).filter { $0.opacity > 0.00001 }
    }

    func tracks(_ timeline: Timeline) -> [Track] {
        let p = timeline.map { progress(at: $0) }
        var result: [Track] = []
        for (old, material) in zip(oldLayers, departure) {
            result.appendIf(timeline.track(old, "opacity", p.map { NSNumber(value: material.opacity * (1 - $0)) }))
            old.opacity = Float(material.opacity * (1 - p.last!))
        }
        for (overlay,opacity) in overlays {
            result.appendIf(timeline.track(overlay,"opacity",p.map{NSNumber(value:opacity*(1-$0))}))
            overlay.opacity=Float(opacity*(1-p.last!))
        }
        result.appendIf(timeline.track(newLayer, "opacity", p.map { NSNumber(value: $0) }))
        newLayer.opacity = Float(p.last!)
        return result
    }
}
