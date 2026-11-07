import AppKit

/// M11.13's pixel-aligned exception to product HaloBlur. One alpha image shapes both glass and wash.
enum PeekHalo {
  static let radius: CGFloat = 96, inner: CGFloat = 16, outer: CGFloat = 84
  struct Key: Hashable, Sendable {
    let width: CGFloat, height: CGFloat, scale: CGFloat
    var size: CGSize { CGSize(width: width, height: height) }
    init(size: CGSize, scale: CGFloat) {
      width = size.width
      height = size.height
      self.scale = scale
    }
  }
  struct Images: Sendable {
    let mask: CGImage, wash: CGImage
    var bytes: Int { mask.bytesPerRow * mask.height + wash.bytesPerRow * wash.height }
  }
  struct Palette: Sendable { let canvas: CGColor, moss: CGColor, teal: CGColor }
  @MainActor private static var cache: [(Key, Images)] = []
  @MainActor private static var palette: Palette {
    .init(canvas: Look.canvas.cgColor, moss: Look.moss.cgColor, teal: Look.teal.cgColor)
  }
  @MainActor private static func cached(_ key: Key) -> Images? {
    guard let index = cache.firstIndex(where: { $0.0 == key }) else { return nil }
    let entry = cache.remove(at: index)
    cache.append(entry)
    return entry.1
  }
  @MainActor private static func store(_ images: Images, for key: Key) {
    cache.removeAll { $0.0 == key }
    cache.append((key, images))
    // Bound resize/display churn. An oversized current surface is allowed as the sole entry.
    while cache.count > 1
      && (cache.count > 8 || cache.reduce(0, { $0 + $1.1.bytes }) > 32 * 1024 * 1024)
    {
      cache.removeFirst()
    }
  }
  @MainActor static func images(for key: Key) -> Images? {
    if let images = cached(key) { return images }
    guard let images = makeImages(key, palette: palette) else { return nil }
    store(images, for: key)
    return images
  }
  @MainActor static func prepare(_ key: Key) async {
    guard cached(key) == nil else { return }
    let colors = palette
    let images = await Task.detached(priority: .utility) { makeImages(key, palette: colors) }.value
    if let images { store(images, for: key) }
  }
  static func alpha(distance d: CGFloat) -> CGFloat {
    let t = (d + inner) / (inner + outer)
    func smooth(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
    if t <= 0 { return 1 }
    if t >= 1 { return 0 }
    return t < 0.47 ? 1 - 0.3 * smooth(t / 0.47) : 0.7 * (1 - smooth((t - 0.47) / 0.53))
  }
  static func maskImage(_ key: Key) -> CGImage? {
    let size = key.size
    let k = key.scale / 2
    guard size.width.isFinite, size.height.isFinite, k.isFinite, k > 0,
      size.width > 2 * outer, size.height > 2 * outer
    else { return nil }
    let w = Int(ceil(size.width * k))
    let h = Int(ceil(size.height * k))
    let surface = CGRect(origin: .zero, size: size).insetBy(dx: outer, dy: outer)
    let r = min(radius, min(surface.width, surface.height) / 2)
    // Map pixel centres to exact point bounds, including fractional-size frames at either display scale.
    let qx = (0..<w).map {
      abs((CGFloat($0) + 0.5) * size.width / CGFloat(w) - surface.midX) - (surface.width / 2 - r)
    }
    var pixels = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
      let qy =
        abs((CGFloat(y) + 0.5) * size.height / CGFloat(h) - surface.midY) - (surface.height / 2 - r)
      for x in 0..<w {
        let q = qx[x]
        let dx = max(q, 0)
        let dy = max(qy, 0)
        let d = (dx == 0 ? dy : dy == 0 ? dx : sqrt(dx * dx + dy * dy)) + min(max(q, qy), 0) - r
        pixels[y * w + x] = UInt8((alpha(distance: d) * 255).rounded())
      }
    }
    return pixels.withUnsafeMutableBytes { bytes in
      CGContext(
        data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)?
        .makeImage()
    }
  }
  // Each lane owns disjoint rows; concurrentPerform joins before either bitmap buffer is released.
  private struct PixelBuffers: @unchecked Sendable {
    let source: UnsafePointer<UInt8>, target: UnsafeMutablePointer<UInt8>
  }
  /// The existing canvas/radial gradients and source-over clip, evaluated directly at full wash resolution.
  /// This preserves the palette and texture scale while avoiding three expensive Quartz alpha-clip passes.
  static func makeImages(_ key: Key, palette: Palette) -> Images? {
    guard let mask = maskImage(key), let maskData = mask.dataProvider?.data else { return nil }
    defer { withExtendedLifetime(maskData) {} }
    let size = key.size
    let scale = key.scale
    let w = Int(ceil(size.width * scale))
    let h = Int(ceil(size.height * scale))
    let mw = mask.width
    let mh = mask.height
    let stride = mask.bytesPerRow
    let source = CFDataGetBytePtr(maskData)!
    let canvas = palette.canvas.components!
    let moss = palette.moss.components!
    let teal = palette.teal.components!
    let cr = Float(canvas[0])
    let cg = Float(canvas[1])
    let cb = Float(canvas[2])
    let mr = Float(moss[0])
    let mg = Float(moss[1])
    let mb = Float(moss[2])
    let tr = Float(teal[0])
    let tg = Float(teal[1])
    let tb = Float(teal[2])
    let xs = (0..<w).map { x -> (Int, Int, Float, Float, Float) in
      let u = Float((CGFloat(x) + 0.5) / (scale * size.width))
      let p = u * Float(mw) - 0.5
      let low = Int(floor(p))
      let fraction = p - Float(low)
      return (
        max(0, min(mw - 1, low)), max(0, min(mw - 1, low + 1)), fraction, (u - 0.62) * (u - 0.62),
        (u - 0.32) * (u - 0.32)
      )
    }
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    pixels.withUnsafeMutableBufferPointer { target in
      let buffers = PixelBuffers(source: source, target: target.baseAddress!)
      DispatchQueue.concurrentPerform(iterations: 4) { lane in
        let source = buffers.source
        let target = buffers.target
        for y in (lane * h / 4)..<((lane + 1) * h / 4) {
          let v = 1 - Float((CGFloat(y) + 0.5) / (scale * size.height))
          let p = (1 - v) * Float(mh) - 0.5
          let low = Int(floor(p))
          let fy = p - Float(low)
          let y0 = max(0, min(mh - 1, low)) * stride
          let y1 = max(0, min(mh - 1, low + 1)) * stride
          let my = (v - 0.70) * (v - 0.70)
          let ty = (v - 0.22) * (v - 0.22)
          let base = 0.46 - 0.16 * v
          for x in 0..<w {
            let (x0, x1, fx, mx, tx) = xs[x]
            let lo = Float(source[y0 + x0]) * (1 - fx) + Float(source[y0 + x1]) * fx
            let hi = Float(source[y1 + x0]) * (1 - fx) + Float(source[y1 + x1]) * fx
            let mask = (lo * (1 - fy) + hi * fy) / 255
            var a = base * mask
            var r = cr * a
            var g = cg * a
            var b = cb * a
            let ma = max(0, 1 - sqrt(mx + my) / 0.6) * 0.13 * mask
            let mi = 1 - ma
            r = mr * ma + r * mi
            g = mg * ma + g * mi
            b = mb * ma + b * mi
            a = ma + a * mi
            let ta = max(0, 1 - sqrt(tx + ty) / 0.6) * 0.10 * mask
            let ti = 1 - ta
            r = tr * ta + r * ti
            g = tg * ta + g * ti
            b = tb * ta + b * ti
            a = ta + a * ti
            let i = (y * w + x) * 4
            target[i] = UInt8((r * 255).rounded())
            target[i + 1] = UInt8((g * 255).rounded())
            target[i + 2] = UInt8((b * 255).rounded())
            target[i + 3] = UInt8((a * 255).rounded())
          }
        }
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let wash = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return Images(mask: mask, wash: wash)
  }
}
