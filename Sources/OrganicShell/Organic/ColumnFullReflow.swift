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
    private(set) var target: ColumnNode.Snapshot?
    let area: CGRect
    let layer = CALayer()
    private(set) var overlayLayer:CALayer?
    private var overlays:[(CALayer,Double)]=[]
    private let departure: [ColumnFullMaterial]
    private var arrival: ColumnFullMaterial?
    private let width: Spring
    private let oldLayers: [CALayer]
    private let newLayer: CALayer
    private var delivery: (start: Double, duration: Double)?
    var deliveryDuration: Double { delivery?.duration ?? 0 }
    let clipBounds:CGRect?
    let clipMask:CALayer?
    var previousClipMask:CALayer?

    convenience init?(from: [ColumnFullMaterial], to target: ColumnNode.Snapshot, width: Spring, scale: CGFloat) {
        guard !from.isEmpty, target.withGoal != nil else { return nil }
        self.init(from: from, pending: target.area, width: width, scale: scale)
        self.target = target
        arrival = ColumnFullMaterial(image: target.withGoal!, size: target.transcriptSize, opacity: 1,
                                     independentFade: from.contains { $0.independentFade })
        configureArrival(target, scale: scale)
    }

    init?(from: [ColumnFullMaterial], pending area: CGRect, width: Spring, scale: CGFloat) {
        self.departure = from
        self.area = area
        self.width = width
        let independent=from.contains{$0.independentFade}
        if independent {
            let lo=min(0,from.map(\.offsetY).min() ?? 0)
            let hi=max(area.height,from.map{$0.offsetY+$0.size.height}.max() ?? 0)
            clipBounds=CGRect(x:0,y:lo,width:area.width,height:hi-lo)
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
        oldLayers = from.map(plane)
        newLayer = CALayer()
        newLayer.anchorPoint = .zero
        newLayer.contentsScale = scale
        newLayer.contentsGravity = .resize
        newLayer.opacity = 0
        layer.anchorPoint = .zero
        layer.frame = area.offsetBy(dx: -area.minX, dy: -area.minY)
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

    private func configureArrival(_ target: ColumnNode.Snapshot, scale: CGFloat) {
        newLayer.contents = target.withGoal
        newLayer.frame = CGRect(origin: .zero, size: target.transcriptSize)
        if departure.contains(where: { $0.independentFade }) {
            let mask = ColumnNode.fade(), h = target.transcriptSize.height
            mask.frame = CGRect(origin: .zero, size: target.transcriptSize)
            mask.locations = [0, NSNumber(value: Double(16/h)), NSNumber(value: Double(1-28/h)), 1]
            newLayer.mask = mask
        }
    }

    func deliver(_ target: ColumnNode.Snapshot, at time: Double, scale: CGFloat, rate: Double) -> [Track] {
        self.target = target
        guard let image = target.withGoal else { return [] }
        arrival = ColumnFullMaterial(image: image, size: target.transcriptSize, opacity: 1,
                                     independentFade: departure.contains { $0.independentFade })
        configureArrival(target, scale: scale)
        if abs(target.area.width-area.width) >= 0.5 || abs(target.area.height-area.height) >= 0.5 {
            layer.frame = target.area.offsetBy(dx: -target.area.minX, dy: -target.area.minY)
        }
        var end = time
        while end < width.duration && progress(at: end) < 0.999 { end += 0.002 }
        let duration = max(0.12, end-time)
        delivery = (time, duration)
        return tracks(Timeline(began: time, duration: duration, rate: rate))
    }

    func progress(at time: Double) -> Double {
        if let delivery { return min(1, max(0, (time-delivery.start)/delivery.duration)) }
        if target == nil { return 0 }
        guard abs(width.to - width.from) > 0.0001 else { return 1 }
        return smoothstep(0, 0.94, (width.sample(time).value - width.from) / (width.to - width.from))
    }

    func materials(at time: Double) -> [ColumnFullMaterial] {
        let p = progress(at: time)
        var result = departure.map { material in
            var copy = material
            copy.opacity *= 1-p
            return copy
        }
        if var arrival {
            arrival.opacity = p
            result.append(arrival)
        }
        return result.filter { $0.opacity > 0.00001 }
    }

    func tracks(_ timeline: Timeline) -> [Track] {
        let p = timeline.map { progress(at: timeline.began + $0) }
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
