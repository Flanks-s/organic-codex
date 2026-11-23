import AppKit

/// A detached specimen at board coordinates. It never creates a window or a product entry point.
@MainActor final class BrowserOrbOffscreenHost: NSView {
    private(set) var homeEarth: BrowserEarthPresentation?
    let browser: BrowserIslandPresentation
    override var isFlipped: Bool { true }
    static func make(live: Bool, explicitlyEnabled: Bool, replay: MockBrowserReplay?,
                     images: () -> BrowserBodyImages) -> BrowserOrbOffscreenHost? {
        // Keep this gate before resource construction, state observation, or view allocation.
        guard !live, explicitlyEnabled, let replay, replay.enabled else { return nil }
        return BrowserOrbOffscreenHost(replay: replay, images: images())
    }
    private init(replay: MockBrowserReplay, images: BrowserBodyImages) {
        browser = BrowserIslandPresentation(replay: replay, images: images)
        super.init(frame: CGRect(x: 0, y: 0, width: 1280, height: 820))
        appearance = NSAppearance(named: .darkAqua); addSubview(browser)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 29 / 255, green: 31 / 255, blue: 30 / 255, alpha: 1).setFill(); bounds.fill()
        BrowserPaint.plate(CGRect(x: 2, y: 2, width: 1276, height: 816), radius: 18, color: NSColor(white: 0.14, alpha: 1), stroke: NSColor.white.withAlphaComponent(0.12))
        for (x, color) in [(18.0, NSColor.systemRed), (38.0, .systemYellow), (58.0, .systemGreen)] { BrowserPaint.plate(CGRect(x: x, y: 17, width: 11, height: 11), radius: 6, color: color) }
        for (id, diameter, center) in BrowserBodyImages.companions {
            let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            BrowserPaint.plate(rect, radius: diameter / 2, color: NSColor(white: 0.3, alpha: 1), stroke: NSColor.white.withAlphaComponent(0.30))
            if let image = browser.images.image(id, outer: diameter, scale: browser.backing, center: center) { NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        }
        BrowserPaint.plate(CGRect(x: 30, y: 746, width: 36, height: 36), radius: 18, color: NSColor(srgbRed: 66 / 255, green: 178 / 255, blue: 146 / 255, alpha: 0.55))
        BrowserPaint.text("LL", CGRect(x: 30, y: 757, width: 36, height: 18), size: 12, weight: .semibold, alignment: .center)
        NSColor.white.withAlphaComponent(0.10).setFill(); CGRect(x: 598, y: 84, width: 1, height: 652).fill(); CGRect(x: 915, y: 84, width: 1, height: 652).fill()
        for (rect, title) in [(CGRect(x: 665, y: 97, width: 185, height: 32), "1   Approval copy review   ›"), (CGRect(x: 991, y: 97, width: 189, height: 32), "?   Release notes outline   ›")] {
            BrowserPaint.glass(rect, radius: 16); BrowserPaint.text(title, rect.insetBy(dx: 12, dy: 8), size: 12, weight: .semibold)
        }
        let k = browser.motion.transcriptOpacity
        BrowserPaint.inkGroup(in: CGRect(x: 14, y: 150, width: 570, height: 578), alpha: k, blur: 12 * (1 - k), scale: 0.97 + 0.03 * k) {
            BrowserPaint.text("SIDEBAR DENSITY PASS", CGRect(x: 36, y: 164, width: 300, height: 20), size: 11, color: BrowserPaint.tertiary)
            BrowserPaint.text("Make the sidebar breathe.", CGRect(x: 36, y: 206, width: 480, height: 32), size: 24, weight: .semibold)
            BrowserPaint.text("A native browser specimen with explicit mock state.", CGRect(x: 36, y: 252, width: 500, height: 24), size: 14, color: BrowserPaint.secondary)
            BrowserPaint.text("No page is fetched. No message is sent to Core.", CGRect(x: 36, y: 290, width: 500, height: 24), size: 13, color: BrowserPaint.tertiary)
        }
        for rect in [CGRect(x: 78, y: 740, width: 515, height: 48), CGRect(x: 605, y: 740, width: 305, height: 48), CGRect(x: 922, y: 740, width: 104, height: 48)] {
            BrowserPaint.plate(rect, radius: 24, color: NSColor.white.withAlphaComponent(0.06))
            BrowserPaint.plate(CGRect(x: rect.midX - 17, y: 737.5, width: 34, height: 5), radius: 2.5, color: NSColor.white.withAlphaComponent(0.30))
        }
        let p = browser.motion.placeholderAmount
        BrowserPaint.text("Steer or queue…", CGRect(x: 148, y: 755, width: 390, height: 18), size: 13, color: BrowserPaint.tertiary.withAlphaComponent(0.38 * (1 - p)))
        BrowserPaint.text("Ask about this page…", CGRect(x: 148, y: 755, width: 390, height: 18), size: 13, color: BrowserPaint.tertiary.withAlphaComponent(0.38 * p))
        BrowserPaint.text("Reply…", CGRect(x: 626, y: 755, width: 200, height: 18), color: BrowserPaint.tertiary)
        BrowserPaint.text("Reply…", CGRect(x: 943, y: 755, width: 72, height: 18), color: BrowserPaint.tertiary)
        BrowserPaint.plate(CGRect(x: 556, y: 751, width: 26, height: 26), radius: 13, color: NSColor(srgbRed: 66 / 255, green: 178 / 255, blue: 146 / 255, alpha: 1))
        BrowserPaint.symbol("arrow.up", rect: CGRect(x: 562, y: 757, width: 14, height: 14))
    }
    func sample(at time: Double, scale: Int) { browser.backing = scale; browser.sample(at: time); needsDisplay = true }
    func bitmap(scale: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280 * scale, pixelsHigh: 820 * scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = bounds.size
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }
    /// Explicit rendering fixture entry. Product Dock/column ownership remains deferred to R3.
    func prepareHomeEarth(outer: Float = 56, scale: Int = 2, reduceMotion: Bool, utcOffsetSeconds: Int = TimeZone.current.secondsFromGMT()) async throws {
        let earth = BrowserEarthPresentation(resources: browser.images.resources, outer: outer, scale: scale,
                                              reduceMotion: reduceMotion, utcOffsetSeconds: utcOffsetSeconds, lightDegrees: earthLightDegrees())
        try await earth.prepare(); homeEarth = earth
    }
    func sampleHomeEarth(at time: Double, scale: Int) async throws {
        sample(at: time, scale: scale)
        guard let homeEarth else { return }
        for event in browser.replay.store.state.homeEvents { homeEarth.receive(event, at: event.time) }
        homeEarth.lightDegrees = earthLightDegrees()
        try await homeEarth.sample(at: time)
        browser.earthImageOverride = homeEarth.image
        browser.needsDisplay = true
    }
    private func earthLightDegrees() -> Float {
        let frame = browser.motion.earthFrame
        let degrees = Float(atan2(frame.midY - 764, 48 - frame.midX) * 180 / .pi)
        return BodyProfile.current.quantizedDirection(degrees).degrees
    }
    func dispose() { homeEarth?.cancel(); homeEarth = nil; browser.earthImageOverride = nil; browser.dispose(); browser.removeFromSuperview() }
}
