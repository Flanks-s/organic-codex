// Stacks one band of rows from several frames into one image, each labelled with its file name, for looking at a
// motion frame by frame. swift strip.swift OUT.png Y0 Y1 FRAME.png [FRAME.png …]   (Y in window points of a 1280-wide window)
import AppKit

let a = CommandLine.arguments
let y0 = Double(a[2])!, y1 = Double(a[3])!
let images = a.dropFirst(4).compactMap { p -> (String, CGImage)? in
    guard let i = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return ((p as NSString).lastPathComponent, i)
}
guard let first = images.first?.1 else { print("no frames"); exit(1) }
let scale = Double(first.width) / 1280, bandH = Int((y1 - y0) * scale), label = 34
let W = first.width, H = images.count * (bandH + label)
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
for (k, (name, img)) in images.enumerated() {
    let top = H - k * (bandH + label)
    let crop = img.cropping(to: CGRect(x: 0, y: Int(y0 * scale), width: W, height: bandH))!
    ctx.draw(crop, in: CGRect(x: 0, y: top - label - bandH, width: W, height: bandH))
    (name as NSString).draw(at: CGPoint(x: 8, y: top - label + 6), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), .foregroundColor: NSColor.white])
}
let url = URL(fileURLWithPath: a[1]) as CFURL
let d = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
print("\(images.count) frames -> \(a[1])")
