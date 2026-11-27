import AppKit
import CoreImage

/// A native port of the adopted board's single goo carrier: sigma 4, alpha 20/-9.
@MainActor final class BrowserIslandGlass {
    struct Disc { let rect: CGRect; let radius: Double; let color: NSColor }
    struct Neck { let start: CGPoint; let end: CGPoint; let width: Double }
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private var signature = "", image: CGImage?
    private(set) var renderCount = 0
    func draw(discs: [Disc], necks: [Neck], scale: Int) {
        let rect = CGRect(x: 30, y: 0, width: 580, height: 470)
        let key = "\(scale)|" + discs.map { "\($0.rect)|\($0.radius)|\($0.color)" }.joined(separator: ";") + necks.map { "\($0.start)|\($0.end)|\($0.width)" }.joined(separator: ";")
        if key != signature {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 580 * scale, pixelsHigh: 470 * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            graphics.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); graphics.cgContext.translateBy(x: -30, y: 470); graphics.cgContext.scaleBy(x: 1, y: -1)
            for neck in necks where neck.width >= 0.6 {
                let p = NSBezierPath(); p.move(to: neck.start); p.line(to: neck.end); p.lineWidth = neck.width; p.lineCapStyle = .round
                NSColor(srgbRed: 54 / 255, green: 56 / 255, blue: 54 / 255, alpha: 1).setStroke(); p.stroke()
            }
            for disc in discs { BrowserPaint.plate(disc.rect, radius: disc.radius, color: disc.color) }
            graphics.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
            guard let source = bitmap.cgImage else { return }
            let filtered = CIImage(cgImage: source).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4 * scale])
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 20), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: -9)])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            image = context.createCGImage(filtered, from: CGRect(x: 0, y: 0, width: 580 * scale, height: 470 * scale))
            signature = key; renderCount += 1
        }
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState(); let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 10; shadow.shadowOffset = CGSize(width: 0, height: -6); shadow.set()
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    func dispose() { image = nil; signature = "" }
}
