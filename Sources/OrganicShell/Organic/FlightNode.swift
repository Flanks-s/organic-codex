import AppKit
import QuartzCore

/// One piece flying between the transcript and the brief: glyph material (spec §5.1). A window-level replicator holds a
/// carrier with the piece's two looks; the carrier's own keyframes are replayed by the copies `instanceDelay` apart, so
/// the exposure follows the real screen path, all in the render server.
///
/// The carrier hangs its looks from the anchor the look keeps (reference §C): a goal line from its top-right (trailing),
/// a narration from its top-left (leading), a Worked note or the current activity from its centre. At either end the
/// carrier puts that end's look exactly where it rests, so the first and last frames match the rest.
@MainActor final class FlightNode {
    let replicator = CAReplicatorLayer()
    private let carrier = CALayer()
    private let source = CALayer(), destination = CALayer()
    /// The same native glyph bitmap at its exact source size. Near the endpoint the scaled material blends into
    /// this plane, rather than letting CA switch sampling modes on a nearly-identity transform in a single frame.
    /// The analytic carrier and its spring (including overshoot) are unchanged.
    private let sourceEndpoint = CALayer()
    private let sourceMaterial = CALayer()
    /// A narration's word groups, each coming in over its own range of u (kept words early, its own words late).
    private var groups: [(layer: CALayer, range: ClosedRange<Double>)] = []
    let plan: FlightPlan
    var line: ColumnNode.FlightPiece
    private(set) var peakStep: CGFloat = 0, smearedSamples = 0
    private let anchor: CGPoint
    private var clipEnd:CGRect?
    private var clipDuration:Double=0.08

    func continuedClip(at t:Double)->CGRect? {
        guard let start=line.nativeClip,let end=clipEnd else {return line.nativeClip}
        let p=CGFloat(smoothstep(0,clipDuration,t))
        return CGRect(x:start.minX+(end.minX-start.minX)*p,y:start.minY,
                      width:start.width+(end.width-start.width)*p,height:start.height+(end.height-start.height)*p)
    }

    init(line: ColumnNode.FlightPiece, plan: FlightPlan, bounds: CGRect, scale: CGFloat) {
        self.line = line; self.plan = plan
        anchor = switch plan.anchor { case .trailing: CGPoint(x: 1, y: 0); case .leading: .zero; case .center: CGPoint(x: 0.5, y: 0.5) }
        replicator.anchorPoint = .zero
        replicator.frame = bounds
        let w = line.destination.width, h = max(line.destination.height, line.source.height)
        // Trailing: both looks hang from the carrier's top-right. Otherwise from its top-left; the carrier's own
        // anchor is then only where it scales about.
        let hang = plan.anchor == .trailing ? CGPoint(x: 1, y: 0) : .zero
        for l in [carrier, source, destination] { l.contentsScale = scale; l.contentsGravity = .resize }
        carrier.anchorPoint = anchor
        carrier.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        for (layer, image, size) in [(source, line.sourceImage as CGImage?, line.source.size), (destination, line.destinationImage, line.destination.size)] {
            layer.anchorPoint = hang
            layer.contents = image
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.position = CGPoint(x: hang.x * w, y: 0)
        }
        sourceMaterial.anchorPoint = .zero; sourceMaterial.bounds = carrier.bounds
        // Isolate addition from the scene behind the carrier. A normal opacity crossfade between antialiased
        // glyphs loses coverage in the middle; these are two samples of ONE premultiplied glyph material.
        sourceMaterial.shouldRasterize = true; sourceMaterial.rasterizationScale = scale
        sourceMaterial.addSublayer(source)
        sourceEndpoint.anchorPoint = source.anchorPoint
        sourceEndpoint.contentsScale = scale; sourceEndpoint.contentsGravity = .resize
        sourceEndpoint.contents = line.sourceImage
        sourceEndpoint.bounds = source.bounds; sourceEndpoint.position = source.position
        sourceEndpoint.opacity = 0
        // M10.1 audit: this is the isolated glyph coverage crossfade above, not a copied plate/backdrop.
        // Complementary weights add to the original premultiplied glyph; source-over would darken its AA edge.
        // M10ColumnGaussianVerification.additiveGlyph checks both laws (including the counterexample).
        sourceEndpoint.compositingFilter = "plusL"
        sourceMaterial.addSublayer(sourceEndpoint)
        carrier.addSublayer(sourceMaterial)
        carrier.addSublayer(destination)
        for g in line.groups {
            let l = CALayer()
            l.anchorPoint = .zero; l.contentsScale = scale; l.contentsGravity = .resize
            l.contents = g.image
            l.frame = g.frame
            destination.addSublayer(l)
            groups.append((l, g.range))
        }
        replicator.addSublayer(carrier)
    }

    /// The carrier's position on screen for a column rect and form, its pop scale and u.
    func screenPose(rect r: CGRect, form f: Double) -> (origin: CGPoint, scale: CGFloat, u: CGFloat) {
        let pose = MorphFlightMath.pose(plan, form: f)
        let b = carrier.bounds.size
        return (CGPoint(x: r.minX + pose.origin.x + anchor.x * b.width, y: r.minY + pose.origin.y + anchor.y * b.height + line.nativeScrollY * CGFloat(min(1,max(0,f/max(0.00001,line.nativeScrollForm))))), pose.scale, plan.u(f))
    }

    func continuationBounds(rect:CGRect,form:Double,lyricSize:CGFloat)->CGRect {
        let p=screenPose(rect:rect,form:form)
        let inner=max(1,1+(lyricSize/13-1)*p.u)
        let w=max(line.source.width,line.destination.width)*p.scale*inner
        let h=max(line.source.height,line.destination.height)*p.scale*inner
        return CGRect(x:p.origin.x-anchor.x*w,y:p.origin.y-anchor.y*h,width:w,height:h)
    }

    /// A layout interruption hands the currently visible glyph material to the existing full reflow.
    /// This samples the original plan; uninterrupted flights retain their original animations and clock.
    func continuationMaterial(rect:CGRect,form:Double,lyricSize:CGFloat)->CALayer {
        var copies:[ObjectIdentifier:CALayer]=[:]
        let result=M10ColumnTexture.clone(carrier,into:&copies)
        let p=screenPose(rect:rect,form:form),u=Double(p.u),dim=Double(line.destinationOpacity)
        result.position=p.origin;result.transform=CATransform3DMakeScale(p.scale,p.scale,1)
        let leave=line.look == .segment ? 0.02...0.22:0.35...0.65
        let scalesText=line.look == .goal || line.look == .segment
        let endpoint=scalesText ? 1-smoothstep(0,0.01,u):0
        let alpha=1-smoothstep(leave.lowerBound,leave.upperBound,u)
        copies[ObjectIdentifier(source)]?.opacity=Float(alpha*(1-endpoint))
        copies[ObjectIdentifier(sourceEndpoint)]?.opacity=Float(alpha*endpoint)
        copies[ObjectIdentifier(sourceEndpoint)]?.compositingFilter="plusL"
        copies[ObjectIdentifier(sourceMaterial)]?.shouldRasterize=true
        copies[ObjectIdentifier(sourceMaterial)]?.rasterizationScale=carrier.contentsScale
        if groups.isEmpty {copies[ObjectIdentifier(destination)]?.opacity=Float(smoothstep(0.35,0.65,u)*dim)}
        else {
            copies[ObjectIdentifier(destination)]?.opacity=Float(dim)
            for g in groups {copies[ObjectIdentifier(g.layer)]?.opacity=Float(smoothstep(g.range.lowerBound,g.range.upperBound,u))}
        }
        let k=scalesText ? lyricSize/13:1
        copies[ObjectIdentifier(source)]?.transform=CATransform3DMakeScale(1+(k-1)*p.u,1+(k-1)*p.u,1)
        copies[ObjectIdentifier(destination)]?.transform=CATransform3DMakeScale((1+(k-1)*p.u)/k,(1+(k-1)*p.u)/k,1)
        return result
    }

    /// Driver B for this flight, from its column's rect and form sampled on `timeline`, and the same sampled
    /// one exposure earlier (for the accumulate pass).
    func tracks(_ timeline: Timeline, rects: [CGRect], forms: [Double], earlierRects: [CGRect], earlierForms: [Double],
                lyricSize: CGFloat, profile: DisplayProfile, exposure: ExposureSettings) -> [Track] {
        var out: [Track] = []
        let poses = zip(rects, forms).map { screenPose(rect: $0, form: $1) }
        let earlier = zip(earlierRects, earlierForms).map { screenPose(rect: $0, form: $1).origin }
        if let start=line.nativeClip {
            clipDuration=max(0.000001,min(ColumnTranscriptHandoff.clipSeconds,timeline.duration))
            // A reversal inherits the current viewport coverage. Opening its side/bottom bounds is continuous;
            // the top remains protected even when scroll transport has moved a goal above the header.
            let union=zip(rects,forms).reduce(start) {box,pair in
                box.union(continuationBounds(rect:pair.0,form:pair.1,lyricSize:lyricSize))
            }
            clipEnd=CGRect(x:union.minX-1,y:start.minY,width:union.width+2,height:max(start.height,union.maxY+29-start.minY))
            let boxes=timeline.times.map{continuedClip(at:$0)!},mask=ColumnNode.fade()
            mask.anchorPoint = .zero;mask.frame=boxes.last!;mask.locations=ColumnNode.flightClipLocations(boxes.last!)
            replicator.mask=mask
            out.appendIf(timeline.track(mask,"position",boxes.map{NSValue(point:$0.origin)}))
            out.appendIf(timeline.track(mask,"bounds",boxes.map{NSValue(rect:CGRect(origin:.zero,size:$0.size))}))
            out.appendIf(timeline.track(mask,"locations",boxes.map{ColumnNode.flightClipLocations($0)}))
        }
        out.appendIf(timeline.track(carrier, "position", poses.map { NSValue(point: $0.origin) }, smooth: true))
        out.appendIf(timeline.track(carrier, "transform", poses.map { NSValue(caTransform3D: CATransform3DMakeScale($0.scale, $0.scale, 1)) }))
        let u = poses.map { Double($0.u) }
        // The brief end carries its line's dim (an older line rests at 0.34), so landing matches the rest.
        let dim = Double(line.destinationOpacity)
        // The looks cross over (ColumnMorphMath.swift:91-113): goal, worked and activity at u 0.35 → 0.65; a narration's
        // source sentence leaves early, 0.02 → 0.22, and its word groups come in over their own ranges.
        let leave = line.look == .segment ? 0.02...0.22 : 0.35...0.65
        let scalesText = line.look == .goal || line.look == .segment
        let endpoint = u.map { scalesText ? 1 - smoothstep(0, 0.01, $0) : 0 }
        let sourceAlpha = u.map { 1 - smoothstep(leave.lowerBound, leave.upperBound, $0) }
        out.appendIf(timeline.track(source, "opacity", zip(sourceAlpha, endpoint).map { NSNumber(value: $0 * (1 - $1)) }))
        out.appendIf(timeline.track(sourceEndpoint, "opacity", zip(sourceAlpha, endpoint).map { NSNumber(value: $0 * $1) }))
        if groups.isEmpty {
            out.appendIf(timeline.track(destination, "opacity", u.map { NSNumber(value: smoothstep(0.35, 0.65, $0) * dim) }))
        } else {
            destination.opacity = Float(dim)
            for g in groups {
                out.appendIf(timeline.track(g.layer, "opacity", u.map { NSNumber(value: smoothstep(g.range.lowerBound, g.range.upperBound, $0)) }))
            }
        }
        // Lyrics grow from 13 / lyricSize to 1 and the transcript's words grow to meet them; notes and activity keep size.
        let k = line.look == .goal || line.look == .segment ? lyricSize / 13 : 1
        if k != 1 {
            out.appendIf(timeline.track(source, "transform", u.map { NSValue(caTransform3D: CATransform3DMakeScale(1 + (k - 1) * $0, 1 + (k - 1) * $0, 1)) }))
            out.appendIf(timeline.track(destination, "transform", u.map { NSValue(caTransform3D: CATransform3DMakeScale((1 + (k - 1) * $0) / k, (1 + (k - 1) * $0) / k, 1)) }))
        }

        let samples = zip(poses, earlier).map { ExposureSample(now: $0.origin, earlier: $1, frameInterval: profile.frameInterval,
                                                               mmPerPoint: profile.mmPerPoint, settings: exposure) }
        if ProcessInfo.processInfo.environment["FLIGHT_LOG"] == "\(line.look)" {
            let rows = zip(zip(timeline.times, u), zip(samples, poses)).map { a, b in
                String(format: "t %.3f u %.3f step %.1f count %d pos (%.0f, %.0f)", a.0, a.1, b.0.stepPt, b.0.count, b.1.origin.x, b.1.origin.y)
            }
            print("FLIGHT \(line.look) towardBrief \(plan.towardBrief) delay \(plan.delay)\n" + rows.prefix(60).joined(separator: "\n"))
        }
        peakStep = samples.map(\.stepPt).max() ?? 0
        smearedSamples = samples.filter { $0.count > 1 }.count
        out.appendIf(timeline.track(replicator, "instanceCount", samples.map { NSNumber(value: $0.count) }, discrete: true))
        out.appendIf(timeline.track(replicator, "instanceDelay", samples.map { NSNumber(value: $0.delayStep) }))
        out.appendIf(M10ColumnExposure.colorTrack(timeline,on:replicator,samples:samples))
        // Model values are the landing pose: nothing jumps if the animations end early.
        carrier.position = poses.last!.origin
        let last = u.last!
        source.opacity = Float(sourceAlpha.last! * (1 - endpoint.last!))
        sourceEndpoint.opacity = Float(sourceAlpha.last! * endpoint.last!)
        if groups.isEmpty { destination.opacity = Float(smoothstep(0.35, 0.65, last) * dim) }
        for g in groups { g.layer.opacity = Float(smoothstep(g.range.lowerBound, g.range.upperBound, last)) }
        return out
    }
}

extension Array where Element == Track {
    mutating func appendIf(_ t: Track?) { if let t { append(t) } }
}
