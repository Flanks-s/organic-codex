#if M1138_CAPTURE
import AppKit

/// Read-only diagnostics used by the mock real-window driver. No bitmap capture or layout.
@MainActor enum SplitRealwinCapture {
    // Explicitly enabled by the isolated probe, before constructing any view.
    static var enabled = false
    private final class Identity {
        weak var object: AnyObject?
        let serial: String, created: Double, origin: String
        var first: Double?, removed: Double?
        init(_ object: AnyObject, _ serial: String, _ origin: String) {
            self.object = object; self.serial = serial; self.origin = origin
            created = CACurrentMediaTime()
        }
    }
    private static var identities: [ObjectIdentifier: Identity] = [:]
    private static var sequence = 0
    private static var sampleWall = 0.0
    private static var poses: [ObjectIdentifier: CALayer] = [:]
    private static var epochRoot = "none", epochComplete = false
    private static var fadeHistory: [ObjectIdentifier: [[String: Any]]] = [:]
    private static var frameAnimations: [ObjectIdentifier: [[String: Any]]] = [:]
    private static var satelliteCache: [ObjectIdentifier: (Identity, [Identity])] = [:]
    private static var exposureCache: [(Identity, Identity)]?
    static func invalidateBindings() { exposureCache = nil }
    static func beginRoot(_ root: NSView) {
        poses.removeAll(keepingCapacity: true); frameAnimations.removeAll(keepingCapacity: true); epochComplete = true
        guard let model = root.layer, let shown = model.presentation() else { epochComplete = false; return }
        epochRoot = token(model)
        func bind(_ p: CALayer) {
            poses[ObjectIdentifier(p.model())] = p
            for child in p.sublayers ?? [] { bind(child) }
        }
        bind(shown)
    }
    private static func pose(_ layer: CALayer) -> CALayer { poses[ObjectIdentifier(layer)] ?? layer }
    private static func animationEvidence(_ layer: CALayer) -> [[String: Any]] {
        var result: [[String: Any]] = [], cursor: CALayer? = layer
        while let l = cursor {
            let key = ObjectIdentifier(l)
            if let cached = frameAnimations[key] { result += cached; cursor = l.superlayer; continue }
            let live: [[String: Any]] = (l.animationKeys() ?? []).compactMap { name in
                guard let a = l.animation(forKey: name) else { return nil }
                let basic = a as? CABasicAnimation
                let channels = (a as? CAAnimationGroup)?.animations ?? [a]
                return ["author": name, "holder": token(l), "keyPath": (a as? CAPropertyAnimation)?.keyPath ?? "group", "start": l.convertTime(a.beginTime, to: nil),
                    "duration": a.duration, "from": (basic?.fromValue as? NSNumber)?.doubleValue ?? NSNull() as Any,
                    "to": (basic?.toValue as? NSNumber)?.doubleValue ?? NSNull() as Any, "observed": sampleWall,
                    "channels": channels.map { c -> [String: Any] in ["keyPath": (c as? CAPropertyAnimation)?.keyPath ?? "", "values": ((c as? CAKeyframeAnimation)?.values ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }] }]
            }
            if !live.isEmpty { fadeHistory[key] = live }
            let value = live.isEmpty ? (fadeHistory[key] ?? []) : live
            frameAnimations[key] = value; result += value; cursor = l.superlayer
        }
        return result
    }
    static func glyph(_ cache: M10DockGlyph, source: NSView, in root: NSView, id: String, owner: String) -> [[String: Any]] {
        let trail = cache.trail.layer
        let stored = Mirror(reflecting: cache).children.first { $0.label == "source" }?.value
        let actual = stored.flatMap { Mirror(reflecting: $0).children.first?.value as? NSView }
        var rows = leafRows(trail, in: root, id: id, owner: owner, member: id, plane: "glyph")
        for index in rows.indices {
            rows[index]["kind"] = "ink"; rows[index]["copy"] = token(trail)
            rows[index]["nativeSource"] = token(source); rows[index]["sourceHost"] = source.superview.map { token($0) } ?? "none"
            rows[index]["renderer"] = "M10DockGlyph.trail"; rows[index]["sourceLayerHidden"] = source.layer?.isHidden ?? false
            rows[index]["replicaCount"] = trail.instanceCount
            rows[index]["replicaDelay"] = trail.instanceDelay
            rows[index]["actualSource"] = actual.map { token($0) } ?? "none"
            rows[index]["sourceBindingVerified"] = actual === source
        }
        return rows
    }
    private static var definitions: [[String: Any]] = []
    private static var glassLives: [Identity] = []
    private struct Paint {
        let role: String, image: String?, rect: CGRect, alpha: CGFloat
    }
    private static var paints: [ObjectIdentifier: [Paint]] = [:]
    private static var nativePaints: [ObjectIdentifier: [Paint]] = [:]
    private static var nativePaintWalls: [ObjectIdentifier: Double] = [:]
    private static var captureDepth = 0
    static func beginBitmapObservation() { captureDepth += 1 }
    static func endBitmapObservation() { captureDepth -= 1 }
    private static let writer = DispatchQueue(label: "m1138.capture.writer", qos: .utility)
    private final class Batch: @unchecked Sendable {
        let rows: [[String: Any]], output: String
        init(_ rows: [[String: Any]], _ output: String) { self.rows = rows; self.output = output }
    }
    static func beginFrame(_ wall: Double) {
        sampleWall = wall
        for life in glassLives where life.first != nil && life.removed == nil {
            if let v = life.object as? NSView, v.superview != nil { continue }
            life.removed = wall
            definitions.append(["instance": life.serial, "event": "removed", "wall": wall])
        }
    }
    static func created(_ object: AnyObject) { _ = identity(object, origin: "constructor-observation") }
    private static func identity(_ object: AnyObject, origin: String = "first-observed") -> Identity {
        let key = ObjectIdentifier(object)
        if let found = identities[key], found.object === object { return found }
        sequence += 1
        let value = Identity(object, "object-" + String(sequence), origin)
        identities[key] = value
        if object is NSGlassEffectView { glassLives.append(value) }
        definitions.append(["instance": value.serial, "class": String(describing: type(of: object)),
            "creation": value.created, "creationEvidence": origin])
        return value
    }
    static func takeDefinitions() -> [[String: Any]] {
        let value = definitions; definitions.removeAll(keepingCapacity: true); return value
    }
    static func enqueue(_ rows: [[String: Any]], output: String) {
        let batch = Batch(rows, output)
        writer.async {
            let url = URL(fileURLWithPath: batch.output + "/split-r2a.jsonl")
            try? FileManager.default.createDirectory(atPath: batch.output, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            for row in batch.rows {
                if let data = try? JSONSerialization.data(withJSONObject: row) { handle.write(data); handle.write(Data([10])) }
            }
            try? handle.close()
        }
    }
    static func drain() { writer.sync {} }
    /// Called inside draw, without requesting another draw or retaining an image.
    static func buttonDidDraw(_ button: NativeComposerMenuButton) {
        let values: [Paint]
        if let b = button.segmentBlend {
            values = [Paint(role: "from", image: identity(b.from).serial,
                            rect: CGRect(origin: .zero, size: b.from.size), alpha: 1-b.progress),
                      Paint(role: "to", image: identity(b.to).serial,
                            rect: CGRect(origin: .zero, size: b.to.size), alpha: b.progress)]
        } else { values = [Paint(role: "normal", image: nil, rect: button.bounds, alpha: 1)] }
        paints[ObjectIdentifier(button)] = values
        if captureDepth == 0 {
            nativePaints[ObjectIdentifier(button)] = values
            nativePaintWalls[ObjectIdentifier(button)] = CACurrentMediaTime()
        }
    }
    static func subpaints(_ button: NativeComposerMenuButton, in root: NSView,
                          id: String, owner: String) -> [[String: Any]] {
        guard let layer = button.layer else { return [] }
        let parent = identity(button).serial
        let key = ObjectIdentifier(button)
        let origin = nativePaints[key] == nil ? "offscreen-only" : "native-display"
        return (nativePaints[key] ?? paints[key] ?? []).map { paint in
            var row = sample(layer, in: root, id: id, instance: parent + "." + paint.role,
                             kind: "ink", owner: owner, hidden: button.isHiddenOrHasHiddenAncestor)
            let p = pose(layer)
            let base = root.layer.map { pose($0) }
            let frame = root.convert(p.convert(paint.rect, to: base), to: nil)
            let clip = row["clipRect"] as? [Double] ?? []
            let clipRect = clip.count == 4 ? CGRect(x: CGFloat(clip[0]), y: CGFloat(clip[1]),
                width: CGFloat(clip[2]), height: CGFloat(clip[3])) : frame
            let alpha = (row["visibleOpacity"] as? Double ?? 0) * Double(paint.alpha)
            row["frame"] = rect(frame); row["visibleRect"] = rect(frame.intersection(clipRect))
            row["visibleOpacity"] = alpha; row["opacity"] = alpha
            row["instance"] = parent + "." + paint.role; row["copy"] = parent + "." + paint.role
            row["nativeSource"] = parent
            row["sourceHost"] = button.superview.map { token($0) } ?? "none"
            row["subpaint"] = ["control": id, "view": parent, "role": paint.role,
                "image": paint.image ?? "native-text", "drawRect": rect(paint.rect), "fraction": Double(paint.alpha),
                "origin": origin, "drawWall": nativePaintWalls[key] ?? NSNull() as Any]
            return row
        }
    }
    static func leafRows(_ layer: CALayer, in root: NSView, id: String, owner: String,
                         member: String, plane: String, satellites: [CALayer] = []) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func walk(_ l: CALayer, path: String, satellite: Bool = false) {
            let isSatellite = satellite || satellites.contains(where: { $0 === l })
            let p = pose(l)
            let shape = l as? CAShapeLayer
            let draws = l.contents != nil || (l as? CATextLayer)?.string != nil ||
                (p.backgroundColor?.alpha ?? 0) > 0 ||
                (shape?.path != nil && ((shape?.fillColor?.alpha ?? 0) > 0 || (shape?.strokeColor?.alpha ?? 0) > 0))
            if draws {
                var row = sample(l, in: root, id: id, instance: identity(l).serial, kind: "planet", owner: owner)
                row["member"] = member; row["plane"] = plane; row["leaf"] = true
                row["leafPath"] = path; row["leafClass"] = String(describing: type(of: l))
                row["leafName"] = l.name ?? ""; row["textLeaf"] = l is CATextLayer
                row["role"] = isSatellite ? "satellite" : "planet"
                result.append(row)
            }
            for (index, child) in (l.sublayers ?? []).enumerated() { walk(child, path: path + "." + String(index), satellite: isSatellite) }
        }
        walk(layer, path: "root"); return result
    }
    static func satelliteRoots(_ orb: OrbComponent) -> [CALayer] {
        let key = ObjectIdentifier(orb)
        if let found = satelliteCache[key], found.0.object === orb { return found.1.compactMap { $0.object as? CALayer } }
        guard let value = Mirror(reflecting: orb).children.first(where: { $0.label == "satellites" })?.value as? OrbSatellites else { return [] }
        let result = [value.front, value.back]; satelliteCache[key] = (identity(orb), result.map { identity($0) }); return result
    }
    private static func observe(_ v: NSView, row: inout [String: Any]) {
        let life = identity(v), frame = v.convert(v.bounds, to: nil)
        var chain: [String] = [], cursor: NSView? = v
        var container: NSGlassEffectContainerView?, outsideAlpha = 1.0, outsideHidden = false
        while let current = cursor {
            chain.append(identity(current).serial)
            if container == nil, let found = current as? NSGlassEffectContainerView { container = found }
            if container != nil {
                outsideAlpha *= Double(current.layer.map { pose($0).opacity } ?? Float(current.alphaValue))
                outsideHidden = outsideHidden || current.isHidden
            }
            cursor = current.superview
        }
        let attached = v.window != nil && v.superview != nil
        let nativeHidden = v.isHiddenOrHasHiddenAncestor
        if life.first == nil && attached && !nativeHidden && v.layer?.presentation() != nil { life.first = sampleWall }
        if !attached && life.first != nil && life.removed == nil { life.removed = sampleWall }
        row["instance"] = life.serial; row["modelFrame"] = rect(frame)
        row["presentationFrame"] = row["frame"]
        row["nativeHidden"] = nativeHidden; row["viewHidden"] = v.isHidden
        row["modelLayerHidden"] = v.layer?.isHidden ?? false
        row["ancestors"] = chain; row["container"] = container.map { identity($0).serial } ?? "none"
        row["materialGroupState"] = container.map { ["instance": identity($0).serial, "spacing": Double($0.spacing)] as [String: Any] } ?? [:]
        row["lifetime"] = ["created": life.created, "creationEvidence": life.origin,
            "firstOnscreen": life.first ?? NSNull() as Any, "removed": life.removed ?? NSNull() as Any]
        row["attached"] = attached
        if v is NSGlassEffectView {
            row["cornerRadius"] = Double((v as! NSGlassEffectView).cornerRadius)
            row["material"] = ["childAlphaIgnored": container != nil, "outsideOpacity": outsideAlpha,
                "nativeHidden": nativeHidden || outsideHidden, "modelFrame": rect(frame),
                "evidence": "native-state-not-compositor-pixels"]
        }
    }
    static func rect(_ r: CGRect) -> [Double] {
        guard !r.isNull, !r.isInfinite else { return [] }
        return [r.minX, r.minY, r.width, r.height].map { (Double($0)*1000).rounded()/1000 }
    }
    static func token(_ object: AnyObject) -> String { identity(object).serial }
    private static func masks(_ layer: CALayer) -> [[String: Any]] {
        var result: [[String: Any]] = [], cursor: CALayer? = layer
        while let current = cursor {
            if let mask = (current.presentation() ?? current).mask {
                var path: [[Double]] = []
                if let shape = mask as? CAShapeLayer, let outline = shape.path {
                    outline.applyWithBlock { entry in
                        let e = entry.pointee
                        let n = e.type == .addCurveToPoint ? 3 : (e.type == .addQuadCurveToPoint ? 2 : (e.type == .closeSubpath ? 0 : 1))
                        path.append([Double(e.type.rawValue)] + (0..<n).flatMap { [Double(e.points[$0].x), Double(e.points[$0].y)] })
                    }
                }
                var alpha = mask.opacity, ancestor: CALayer? = current
                while let l = ancestor { alpha *= (l.presentation() ?? l).opacity; ancestor = l.superlayer }
                result.append(["holder": token(current), "instance": token(current.mask ?? mask), "path": path,
                    "bounds": rect(mask.bounds), "frame": rect(mask.frame), "opacity": Double(mask.opacity),
                    "actualOpacity": Double(alpha), "fillAlpha": Double((mask as? CAShapeLayer)?.fillColor?.alpha ?? 1),
                    "hidden": mask.isHidden, "fillRule": (mask as? CAShapeLayer)?.fillRule.rawValue ?? "bounds",
                    "holderOpacity": Double((current.presentation() ?? current).opacity)])
            }
            cursor = current.superlayer
        }
        return result
    }
    static func sample(_ layer: CALayer, in root: NSView, id: String, instance: String,
                       kind: String, owner: String?, hidden: Bool = false) -> [String: Any] {
        let p = pose(layer)
        let base = root.layer.map { pose($0) }
        func world(_ l: CALayer, _ r: CGRect) -> CGRect {
            root.convert(l.convert(r, to: base), to: nil)
        }
        let frame = world(p, p.bounds)
        var clip = CGRect.null, clipped = false, opacity: Float = 1, gone = hidden
        var cursor: CALayer? = p
        while let l = cursor {
            opacity *= l.opacity; gone = gone || l.isHidden
            if l.masksToBounds {
                let r = world(l, l.bounds)
                clip = clipped ? clip.intersection(r) : r; clipped = true
            }
            if let mask = l.mask {
                let box = (mask as? CAShapeLayer)?.path?.boundingBoxOfPath ?? mask.bounds
                let sx = mask.frame.width / max(0.001, mask.bounds.width)
                let sy = mask.frame.height / max(0.001, mask.bounds.height)
                let r = world(l, CGRect(x: mask.frame.minX + (box.minX-mask.bounds.minX)*sx,
                    y: mask.frame.minY + (box.minY-mask.bounds.minY)*sy, width: box.width*sx, height: box.height*sy))
                clip = clipped ? clip.intersection(r) : r; clipped = true
            }
            cursor = l.superlayer
        }
        let visible = clipped ? frame.intersection(clip) : frame
        var row: [String: Any] = ["id": id, "instance": instance, "kind": kind, "owner": owner ?? NSNull() as Any,
                "frame": rect(frame), "opacity": (Double(opacity)*1000000).rounded()/1000000, "hidden": gone,
                "clipped": clipped, "clipRect": clipped ? rect(clip) : [], "visibleRect": rect(visible),
                "visibleOpacity": gone || visible.isEmpty ? 0 : (Double(opacity)*1000000).rounded()/1000000,
                "maskOwner": p.mask?.name ?? NSNull() as Any,
                "presentation": poses[ObjectIdentifier(layer)] != nil]
        if enabled {
            row["instance"] = identity(layer).serial
            row["modelFrame"] = rect(root.convert(layer.convert(layer.bounds, to: root.layer), to: nil))
            row["presentationFrame"] = rect(frame)
            var chain: [String] = [], cursor: CALayer? = layer
            while let l = cursor { chain.append(identity(l).serial); cursor = l.superlayer }
            row["ancestors"] = chain
            row["holdingToken"] = identity(layer).serial
            row["externalMasks"] = masks(layer)
            row["nativeLeaf"] = String(describing: type(of: layer))
            row["displayEpoch"] = ["wall": sampleWall, "root": epochRoot, "commonRoot": epochComplete && poses[ObjectIdentifier(layer)] != nil,
                "materialCertified": false, "evidence": "single-presentation-root; material-model-is-not-compositor-proof"]
            row["animationEvidence"] = animationEvidence(layer)
        }
        return row
    }
    static func sample(_ v: NSView, in root: NSView, id: String, instance: String,
                       kind: String, owner: String?, ink: Bool = true) -> [String: Any]? {
        guard let layer = v.layer else { return nil }
        var row = sample(layer, in: root, id: id, instance: instance, kind: kind, owner: owner,
                      hidden: v.superview == nil || (layer.presentation() == nil && v.isHiddenOrHasHiddenAncestor) || !ink)
        if enabled {
            observe(v, row: &row)
            row["materialGroup"] = row["container"]
            row["holdingToken"] = identity(v).serial
            row["nativeSource"] = identity(v).serial
            row["sourceHost"] = v.superview.map { token($0) } ?? "none"
            row["nativeLeaf"] = String(describing: type(of: v))
        }
        return row
    }
    /// M10's private caches are inspected only by this diagnostic. This keeps its product API unchanged.
    /// The source view, rather than geometry or bitmap similarity, identifies every physical ink copy.
    static func exposure(_ cache: M10DockComposer) -> [(NSView, CALayer)] {
        if let found = exposureCache {
            let live = found.compactMap { pair -> (NSView, CALayer)? in
                guard let v = pair.0.object as? NSView, let l = pair.1.object as? CALayer else { return nil }; return (v, l)
            }
            if live.count == found.count { return live }
        }
        func field(_ value: Any, _ name: String) -> Any? {
            Mirror(reflecting: value).children.first { $0.label == name }?.value
        }
        func unwrapped(_ value: Any?) -> Any? {
            guard let value else { return nil }
            let m = Mirror(reflecting: value)
            return m.displayStyle == .optional ? m.children.first?.value : value
        }
        guard let entries = field(cache, "entries") else { return [] }
        var result: [(NSView, CALayer)] = []
        for pair in Mirror(reflecting: entries).children {
            let tuple = Array(Mirror(reflecting: pair.value).children)
            guard tuple.count == 2, let parts = field(tuple[1].value, "parts") else { continue }
            for part in Mirror(reflecting: parts).children {
                if let source = unwrapped(field(part.value, "source")) as? NSView,
                   let layer = field(part.value, "layer") as? CALayer { result.append((source, layer)) }
            }
        }
        exposureCache = result.map { (identity($0.0), identity($0.1)) }; return result
    }
}
#endif
