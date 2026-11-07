import AppKit
import CoreImage
import QuartzCore

/// Production mask/layer checks and mock-only offscreen evidence. CABackdropLayer needs a real window;
/// evidence substitutes its sampled blur with an in-process CI image through the actual production mask.
@MainActor enum PeekHaloVerification {
  static func run(to output: URL, check: (Bool, String) -> Void) {
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var costs: [[String: Any]] = []
    var checkCount = 0
    var findingCount = 0
    func verify(_ value: Bool, _ label: String) {
      checkCount += 1
      if !value { findingCount += 1 }
      check(value, label)
    }
    for scale: CGFloat in [1, 2] {
      let size = CGSize(width: 1280, height: 820)
      let store = ConversationStore()
      let replay = MockReplay(store: store)
      replay.start(live: false)
      let scene = AutoScene(
        size: size, store: store,
        profile: .init(
          name: "M11.13 offscreen", frameInterval: 1 / 60, mmPerPoint: 0.27, persistenceFrames: 0),
        scale: scale)
      scene.manualSettle = true
      scene.ambient = false
      scene.install()
      scene.clock.invalidate()
      scene.settle()
      defer {
        withExtendedLifetime(replay) {}
        scene.clock.invalidate()
        scene.disposeTranscriptPresentation()
        scene.peekNode.header.dispose()
      }
      let root = IslandPlane(frame: CGRect(origin: .zero, size: size))
      for view in [scene.sceneView, scene.nativePlane, scene.dockView] { root.addSubview(view) }
      let background = NativeViewBitmap.capture(root, scale: scale)
      guard let orb = scene.layout.orbs.first, let c = scene.members.last else {
        verify(false, "M11.13 mock has overflow geometry")
        continue
      }
      let g = scene.layout.peek(
        over: orb, size: size, satelliteRows: 1, satellite: orb.width * 0.38, metrics: scene.metrics
      )
      let node = PeekNode(size: size, scale: scale)
      node.ambient = false
      node.motionEnabled = false
      defer { node.header.dispose() }
      M10ColumnWorkTrace.reset()
      let began = CACurrentMediaTime()
      node.open(c, geometry: g)
      let coldOpen = (CACurrentMediaTime() - began) * 1000
      let coldImages =
        M10ColumnWorkTrace.events.first { $0.name == "peek.images" }.map {
          ($0.end - $0.start) * 1000
        } ?? -1
      M10ColumnWorkTrace.active = false
      let layers = node.verificationHalo
      guard let maskContents = layers.mask.contents, let washContents = layers.wash.contents else {
        verify(false, "M11.13 mounted assets exist")
        continue
      }
      let mask = maskContents as! CGImage
      let wash = washContents as! CGImage
      let alphaContext = CGContext(
        data: nil, width: mask.width, height: mask.height, bitsPerComponent: 8,
        bytesPerRow: mask.width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
      alphaContext.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
      guard let alphaImage = alphaContext.makeImage(), let bytes = alphaImage.dataProvider?.data
      else {
        verify(false, "M11.13 mask pixels exist")
        continue
      }
      let frame = layers.halo.frame
      let surface = frame.insetBy(dx: 84, dy: 84)
      let key = PeekHalo.Key(size: frame.size, scale: scale)
      verify(
        node.verificationHasOnlySurfaceLayers, "M11.13 no silhouette shadows layer / \(scale)x")
      verify(
        PeekNode.feather == 84 && layers.halo.anchorPoint == CGPoint(x: 0.5, y: 0.85),
        "M11.13 84pt frame and original anchor / \(scale)x")
      verify(
        layers.wash.shadowOpacity == 0.4 && layers.wash.shadowRadius == 18
          && layers.wash.shadowOffset.height == 16,
        "M11.13 wash keeps its alpha-following shadow / \(scale)x")
      verify(
        frame.size == PeekNode.preparedImageSize(geometry: g, scale: scale),
        "M11.13 idle size equals mounted surface union / \(scale)x")
      verify(
        mask.width == Int(ceil(frame.width * scale / 2))
          && mask.height == Int(ceil(frame.height * scale / 2)),
        "M11.13 half-resolution alpha / \(scale)x")
      func sample(_ p: CGPoint) -> Int {
        let x = min(mask.width - 1, max(0, Int(p.x * CGFloat(mask.width) / frame.width)))
        let y = min(mask.height - 1, max(0, Int(p.y * CGFloat(mask.height) / frame.height)))
        return Int(CFDataGetBytePtr(bytes)![y * alphaImage.bytesPerRow + x])
      }
      let local = CGRect(origin: .zero, size: frame.size).insetBy(dx: 84, dy: 84)
      verify(
        sample(CGPoint(x: local.maxX - 16, y: local.midY)) == 255,
        "M11.13 solid at surface inset 16 / \(scale)x")
      verify(
        sample(CGPoint(x: local.maxX + 84, y: local.midY)) == 0,
        "M11.13 zero at surface outset 84 / \(scale)x")
      verify(
        abs(sample(CGPoint(x: local.maxX + 31, y: local.midY)) - 179) <= 2,
        "M11.13 picker 70 percent at 47 percent / \(scale)x")
      let samples = (-16...84).map { sample(CGPoint(x: local.maxX + CGFloat($0), y: local.midY)) }
      verify(
        zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 },
        "M11.13 generated alpha is monotone / \(scale)x")
      // At an unrounded rectangle corner, a 96pt rounded-box SDF is (sqrt(2)-1)*96.
      verify(
        abs(sample(CGPoint(x: local.minX, y: local.minY)) - 165) <= 4,
        "M11.13 96pt rounded corner pixels / \(scale)x")
      let assets = PeekHalo.images(for: key)!
      verify(
        assets.mask === mask && assets.wash === wash,
        "M11.13 mounted mask and wash share cached assets / \(scale)x")
      let reference = referenceWash(key, mask: mask)!
      // Retain both providers while comparing; Quartz and the analytic raster differ only in 8-bit rounding.
      let expectedData = reference.dataProvider!.data!
      let actualData = wash.dataProvider!.data!
      let expected = CFDataGetBytePtr(expectedData)!
      let actual = CFDataGetBytePtr(actualData)!
      var maxChannelDelta = 0
      var sumChannelDelta = 0
      withExtendedLifetime((expectedData, actualData)) {
        for y in 0..<wash.height {
          for x in 0..<(wash.width * 4) {
            let delta = abs(
              Int(expected[y * reference.bytesPerRow + x]) - Int(actual[y * wash.bytesPerRow + x]))
            maxChannelDelta = max(maxChannelDelta, delta)
            sumChannelDelta += delta
          }
        }
      }
      let meanChannelDelta = Double(sumChannelDelta) / Double(wash.width * wash.height * 4)
      verify(
        maxChannelDelta <= 4 && meanChannelDelta < 0.6,
        "M11.13 full-resolution wash retains Quartz palette/clip within 8-bit rounding / \(scale)x")
      let planet = node.header.geometry.planet.offsetBy(dx: g.blur.minX, dy: 0)
      let capsule = node.header.geometry.capsule.offsetBy(dx: g.blur.minX, dy: 0)
      var pointerMatches = true
      for y in stride(from: frame.minY, through: frame.maxY, by: 9) {
        for x in stride(from: frame.minX, through: frame.maxX, by: 9) {
          let p = CGPoint(x: x, y: y)
          let expected = g.blur.contains(p) || planet.contains(p) || capsule.contains(p)
          pointerMatches =
            pointerMatches && node.containsPointerSurface(p) == expected
            && node.coversPointer(p) == (expected && !g.capsule.contains(p))
        }
      }
      verify(pointerMatches, "M11.13 M11.12 core pointer regions unchanged across halo / \(scale)x")
      let opacity = layers.halo.animation(forKey: "overlay.opacity") as? CABasicAnimation
      let zoom = layers.halo.animation(forKey: "overlay.transform.scale") as? CABasicAnimation
      verify(
        opacity?.duration == 0.38 && zoom?.duration == 0.38 && (zoom?.fromValue as? Double) == 0.7
          && (zoom?.toValue as? Double) == 1,
        "M11.13 opening keeps blurIn, opacity and 0.7 to 1 scale / \(scale)x")
      M10ColumnWorkTrace.reset()
      let hotStart = CACurrentMediaTime()
      node.open(c, geometry: g)
      let hotOpen = (CACurrentMediaTime() - hotStart) * 1000
      let hotImages =
        M10ColumnWorkTrace.events.first { $0.name == "peek.images" }.map {
          ($0.end - $0.start) * 1000
        } ?? -1
      M10ColumnWorkTrace.active = false
      let palette = PeekHalo.Palette(
        canvas: Look.canvas.cgColor, moss: Look.moss.cgColor, teal: Look.teal.cgColor)
      var maskMs: [Double] = []
      var pairMs: [Double] = []
      var hitMs: [Double] = []
      let benchKey = PeekHalo.Key(size: CGSize(width: 513, height: 858), scale: scale)
      for _ in 0..<12 {
        autoreleasepool {
          let start = CACurrentMediaTime()
          _ = PeekHalo.maskImage(benchKey)
          maskMs.append((CACurrentMediaTime() - start) * 1000)
          let pair = CACurrentMediaTime()
          _ = PeekHalo.makeImages(benchKey, palette: palette)
          pairMs.append((CACurrentMediaTime() - pair) * 1000)
          let hit = CACurrentMediaTime()
          _ = PeekHalo.images(for: key)
          hitMs.append((CACurrentMediaTime() - hit) * 1000)
        }
      }
      costs.append([
        "scale": scale, "oldFrameArea": (surface.width + 72) * (surface.height + 72),
        "newFrameArea": frame.width * frame.height,
        "frame": NSStringFromRect(frame), "assetBytes": assets.bytes, "coldOpenMs": coldOpen,
        "cachedOpenMs": hotOpen,
        "coldPeekImagesMs": coldImages, "cachedPeekImagesMs": hotImages,
        "washMaxChannelDelta": maxChannelDelta, "washMeanChannelDelta": meanChannelDelta,
        "maskMedianMs": maskMs.sorted()[6], "pairMedianMs": pairMs.sorted()[6],
        "pairMaxMs": pairMs.max()!, "cacheMedianMs": hitMs.sorted()[6],
      ])

      // A mock native background plus the production halo tree. Only the window-server blur is proxied.
      let host = CALayer()
      let base = CALayer()
      base.frame = CGRect(origin: .zero, size: size)
      base.contents = background
      host.addSublayer(base)
      host.addSublayer(node.view.layer!)
      let proxy = CALayer()
      proxy.frame = layers.backdrop.frame
      let ci = CIContext(options: [.cacheIntermediates: false])
      let source = CIImage(cgImage: background)
      let crop = CGRect(
        x: frame.minX * scale, y: (size.height - frame.maxY) * scale, width: frame.width * scale,
        height: frame.height * scale)
      let blurred = source.clampedToExtent().applyingFilter(
        "CIColorControls", parameters: ["inputSaturation": 1.5]
      ).applyingGaussianBlur(sigma: 22 * scale)
      proxy.contents = ci.createCGImage(blurred, from: crop)
      let proxyMask = CALayer()
      proxyMask.frame = proxy.bounds
      proxyMask.contents = mask
      proxy.mask = proxyMask
      layers.backdrop.removeFromSuperlayer()
      layers.halo.insertSublayer(proxy, at: 0)
      let header = CALayer()
      header.frame = node.headerFrame!
      header.contents = node.header.snapshot(scale: scale)
      host.addSublayer(header)
      node.header.isHidden = true
      let renderer = OffscreenRenderer(size: size, host: host, scale: scale)
      layers.halo.removeAllAnimations()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layers.halo.opacity = 1
      layers.halo.transform = CATransform3DIdentity
      CATransaction.commit()
      renderer.write(
        renderer.render(at: CACurrentMediaTime() + 2),
        output.appendingPathComponent("peek-open-\(Int(scale))x-mock-proxy.png"))
      // Reinstall the production opening curve, then sample halfway through its 0.38s duration.
      node.clear()
      node.open(c, geometry: g)
      let start = CACurrentMediaTime()
      renderer.write(
        renderer.render(at: start + 0.19),
        output.appendingPathComponent("peek-mid-\(Int(scale))x-mock-proxy.png"))
      Offscreen.write(mask, output.appendingPathComponent("peek-mask-\(Int(scale))x.png"))
      node.retract()
      node.clear()
      verify(
        !node.containsPointerSurface(CGPoint(x: surface.midX, y: surface.midY)),
        "M11.13 closed pointer surface absent / \(scale)x")
    }
    if let data = try? JSONSerialization.data(
      withJSONObject: costs, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: output.appendingPathComponent("costs.json"))
    }
    print("M11.13 Peek halo: \(checkCount) checks / \(findingCount) findings")
    try? JSONSerialization.data(
      withJSONObject: ["checks": checkCount, "findings": findingCount],
      options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: output.appendingPathComponent("verification.json"))
  }
  private static func referenceWash(_ key: PeekHalo.Key, mask: CGImage) -> CGImage? {
    let palette = PeekHalo.Palette(
      canvas: Look.canvas.cgColor, moss: Look.moss.cgColor, teal: Look.teal.cgColor)
    let size = key.size
    let scale = key.scale
    let w = Int(ceil(size.width * scale))
    let h = Int(ceil(size.height * scale))
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    ctx.clip(to: CGRect(origin: .zero, size: size), mask: mask)
    let linear = CGGradient(
      colorsSpace: space,
      colors: [palette.canvas.copy(alpha: 0.30)!, palette.canvas.copy(alpha: 0.46)!] as CFArray,
      locations: [0, 1])!
    ctx.drawLinearGradient(linear, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
    for (x, y, color, alpha) in [
      (0.62, 0.30, palette.moss, 0.13), (0.32, 0.78, palette.teal, 0.10),
    ] as [(CGFloat, CGFloat, CGColor, CGFloat)] {
      ctx.saveGState()
      ctx.translateBy(x: x * size.width, y: (1 - y) * size.height)
      ctx.scaleBy(x: size.width, y: size.height)
      let glow = CGGradient(
        colorsSpace: space, colors: [color.copy(alpha: alpha)!, color.copy(alpha: 0)!] as CFArray,
        locations: [0, 1])!
      ctx.drawRadialGradient(
        glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 0.6, options: [])
      ctx.restoreGState()
    }
    guard let wash = ctx.makeImage() else { return nil }
    return wash
  }
}
