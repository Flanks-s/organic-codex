// M11.31 side-by-side: frame strips at the same moments after a key press, one row per recording, for comparing two
// content handoffs frame by frame. Each cell is the frame the window showed at key + offset (WinRec stores a frame only
// when the window changed, so that is the last stored frame at or before that time), scaled down, captioned with the
// offset asked for and the stored frame's own time after the key.
// swift sbs-strip.swift OUT.png OFFSETS_MS LABEL REC.mov KEY_SECONDS [LABEL REC.mov KEY_SECONDS …]
//   OFFSETS_MS like "-10,17,33,50,100,250,600" (milliseconds after the key; negative = before). KEY_SECONDS is the key
//   press in that recording's own time (sbs-table.py's keyVideo). Optional CROP=x0,y0,x1,y1 in window points of a
//   1280 × 820 window; CELL=width of a cell in pixels (default 400).
import AVFoundation
import AppKit

let a = CommandLine.arguments
guard a.count >= 6, (a.count - 3) % 3 == 0 else {
    print("usage: sbs-strip.swift OUT.png OFFSETS_MS LABEL REC.mov KEY_SECONDS [LABEL REC.mov KEY_SECONDS …]"); exit(2)
}
let offsets = a[2].split(separator: ",").map { Double($0)! }
let rows = stride(from: 3, to: a.count, by: 3).map { (label: a[$0], path: a[$0 + 1], key: Double(a[$0 + 2])!) }
let env = ProcessInfo.processInfo.environment
let crop = env["CROP"].map { $0.split(separator: ",").map { Double($0)! } } ?? [0, 0, 1280, 820]
let cellW = Double(env["CELL"] ?? "") ?? 400
let cellH = (cellW * (crop[3] - crop[1]) / (crop[2] - crop[0])).rounded()
let caption = 26.0, header = 30.0, rowLabel = 150.0
let W = Int(rowLabel + cellW * Double(offsets.count)), H = Int(header + Double(rows.count) * (cellH + caption))

var cells: [[(CGImage, Double)?]] = []
for r in rows {
    let asset = AVURLAsset(url: URL(fileURLWithPath: r.path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    var line: [(CGImage, Double)?] = []
    for o in offsets {
        let t = CMTime(seconds: r.key + o / 1000, preferredTimescale: 60000)
        if let (img, actual) = try? await gen.image(at: t) { line.append((img, (actual.seconds - r.key) * 1000)) } else { line.append(nil) }
    }
    cells.append(line)
}

let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let font = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
let text = { (s: String, x: Double, y: Double, c: NSColor) in (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: c]) }
for (j, o) in offsets.enumerated() {
    text(String(format: "%+.0f ms", o), rowLabel + Double(j) * cellW + 8, Double(H) - header + 6, .white)
}
for (i, r) in rows.enumerated() {
    let top = Double(H) - header - Double(i) * (cellH + caption)
    text(r.label, 8, top - cellH / 2, .white)
    for (j, cell) in cells[i].enumerated() {
        let x = rowLabel + Double(j) * cellW
        guard let (img, at) = cell else { text("no frame", x + 8, top - cellH / 2, .red); continue }
        let s = Double(img.width) / 1280
        let src = CGRect(x: crop[0] * s, y: crop[1] * s, width: (crop[2] - crop[0]) * s, height: (crop[3] - crop[1]) * s)
        if let c = img.cropping(to: src) {
            ctx.interpolationQuality = .high
            ctx.draw(c, in: CGRect(x: x + 2, y: top - cellH, width: cellW - 4, height: cellH))
        }
        text(String(format: "frame %+.1f", at), x + 8, top - cellH - caption + 5, NSColor(white: 0.75, alpha: 1))
    }
}
let url = URL(fileURLWithPath: a[1]) as CFURL
let d = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
CGImageDestinationFinalize(d)
print("wrote \(a[1]) \(W)×\(H)")
