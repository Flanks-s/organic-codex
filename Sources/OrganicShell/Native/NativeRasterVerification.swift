import AppKit
import QuartzCore

/// Absolute fixture epochs, independent of the machine's uptime.
@MainActor enum VerificationClock {
    // A small, nonzero binade for model sampling, including 240 Hz expiry boundaries.
    static let modelOrigin = 4096.0

    // 2^26 seconds (about 2.1 years); Double spacing is about 15 ns here.
    // CA rejects frames predating its commits. Refuse an exhausted horizon instead of rebasing.
    static var renderOrigin: Double {
        let origin = 67_108_864.0
        let observed = max(CACurrentMediaTime(), ProcessInfo.processInfo.systemUptime)
        guard observed.isFinite && observed + 3600 < origin else {
            fatalError("VerificationClock render epoch \(origin) is not ahead of CA commits (uptime \(observed)); choose a new fixed horizon explicitly")
        }
        return origin
    }
}

/// Fixed inputs for windowless pixel checks. Never derive density or color from a display.
@MainActor enum VerificationRaster {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let date = Date(timeIntervalSince1970: 1_793_952_000)
    static let epoch = 0.0

    static func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
        // Retag the empty allocation BEFORE AppKit draws; converting afterward cannot fix the source context.
        let allocation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bitmap = allocation.retagging(with: .sRGB)!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return bitmap
    }

    static func capture(_ view: NSView, scale: CGFloat, alignCanvas: Bool = false) -> CGImage {
        precondition(scale.isFinite && scale > 0)
        let size = CGSize(width: max(1, view.bounds.width), height: max(1, view.bounds.height))
        let bitmap = bitmap(width: max(1, Int(ceil(size.width * scale))),
                            height: max(1, Int(ceil(size.height * scale))))
        bitmap.size = alignCanvas ? CGSize(width: CGFloat(bitmap.pixelsWide) / scale,
                                            height: CGFloat(bitmap.pixelsHigh) / scale) : size
        let rect = CGRect(origin: view.bounds.origin, size: bitmap.size)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: rect, to: bitmap) }
        let image = bitmap.cgImage!
        // Own the bytes independently of AppKit's caching allocation and its lifetime.
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }
}

