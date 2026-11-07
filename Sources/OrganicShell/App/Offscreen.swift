import AppKit
import ImageIO
import Metal
import QuartzCore

/// `--offscreen DIR`: renders one brief↔full switch with CARenderer (Core Animation's own renderer, in
/// process) at a fixed rate, without a window or screen-recording permission. Glass bars are AppKit views
/// and do not appear; everything driver B does does.
@MainActor enum Offscreen {
    static func run(to path: String, hz: Double, size: CGSize, target: Int) {
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConversationStore()
        let mock = MockReplay(store: store)
        mock.start(live: false)
        var profile = DisplayProfile(name: "offscreen", frameInterval: 1 / hz, mmPerPoint: 0.27, persistenceFrames: 0)
        profile.frameInterval = 1 / hz
        let scene = AutoScene(size: size, store: store, profile: profile, scale: 1)
        scene.restOnSnapshot = true
        scene.ambient = false
        scene.install()
        guard let host = scene.sceneView.layer else { return }
        let w = Int(size.width), h = Int(size.height)
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .managed
        let texture = device.makeTexture(descriptor: d)!
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        // The renderer only sees what is committed after it is attached: attach an empty root, then add the scene.
        let root = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Without a window nobody sizes the hosting layer; an empty one hides its subtree from the renderer.
        host.anchorPoint = .zero
        host.frame = root.bounds
        host.isGeometryFlipped = true
        root.addSublayer(host)
        CATransaction.commit()
        CATransaction.flush()

        func shot(_ time: Double, _ name: String) -> CGImage {
            renderer.beginFrame(atTime: time, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            let b = queue.makeCommandBuffer()!, e = b.makeBlitCommandEncoder()!
            e.synchronize(resource: texture); e.endEncoding(); b.commit(); b.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            // CARenderer's first texture row is the bottom of the scene.
            bytes = (0..<h).reversed().flatMap { bytes[($0 * w * 4)..<(($0 + 1) * w * 4)] }
            let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            write(image, dir.appendingPathComponent(name + ".png"))
            return image
        }

        func walk(_ l: CALayer, _ d: Int) -> Int { 1 + (l.sublayers ?? []).reduce(0) { $0 + walk($1, d + 1) } }
        print("layers under host:", walk(host, 0), "scene sublayers:", scene.scene.sublayers?.count ?? 0,
              "first card:", scene.columns.first.map { "\($0.card.frame) hidden=\($0.card.isHidden) opacity=\($0.card.opacity) super=\($0.card.superlayer != nil)" } ?? "-",
              "host super:", host.superlayer != nil, "host bounds:", host.bounds, "scene frame:", scene.scene.frame)
        // The renderer's first frame comes out empty; render one to discard.
        _ = shot(CACurrentMediaTime(), "warmup")
        _ = shot(CACurrentMediaTime(), "rest-before")
        scene.switchTo(target, reason: "offscreen")
        CATransaction.flush()
        guard let last = scene.lastSwitch, let duration = last["durationSeconds"] as? Double else { return }
        let began = CACurrentMediaTime() - (last["compileMs"] as? Double ?? 0) / 1000
        var frames: [CGImage] = []
        let count = Int(ceil(duration * hz)) + 1
        for k in 0...count { frames.append(shot(began + Double(k) / hz, String(format: "frame-%02d", k))) }
        sheet(Array(frames.prefix(12)), to: dir.appendingPathComponent("sheet-01-12.png"))
        let receipt: [String: Any] = ["switch": last, "hz": hz, "frames": count + 1, "size": [size.width, size.height]]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("receipt.json"))
        }
        print("offscreen \(count + 1) frames -> \(dir.path)")
    }

    static func write(_ image: CGImage, _ url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Frames at half size, three per row.
    static func sheet(_ images: [CGImage], to url: URL) {
        guard let first = images.first else { return }
        let cw = first.width / 2, ch = first.height / 2, columns = 3, rows = (images.count + columns - 1) / columns
        guard let context = CGContext(data: nil, width: cw * columns, height: ch * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        for (i, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: (i % columns) * cw, y: (rows - 1 - i / columns) * ch, width: cw, height: ch))
        }
        if let image = context.makeImage() { write(image, url) }
    }
}
