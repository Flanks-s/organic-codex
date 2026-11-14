// M11.30: are the Dock's bars separate in a real window? Offscreen captures can't show it: the glass that merged them only merges in WindowServer.
// Usage: swift tools/m11/dock-gap-check.swift IMAGE separate|merged [x0-x1 ...]
// Reads a capture of a 1280×820 window (any scale). For each gap, in points from the top left: `ratio` is how far the middle of the gap falls from the
// glass next to it towards the backdrop above the Dock, on the bar's centre rows. About 0 means glass runs through the gap, about 1 means none does.
import AppKit
let a = CommandLine.arguments
guard a.count >= 3, let image = NSImage(contentsOfFile: a[1]), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("usage or unreadable image"); exit(2) }
let expect = a[2]
let gaps: [(Double, Double)] = a.count > 3 ? a[3...].map { let p = $0.split(separator: "-").compactMap { Double($0) }; return (p[0], p[1]) } : [(593, 605), (910, 922)]
let w = cg.width, h = cg.height, scale = Double(w) / 1280
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
func mean(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
    var sum = 0.0, n = 0.0
    for y in Int(y0 * scale)..<max(Int(y0 * scale) + 1, Int(y1 * scale)) { for x in Int(x0 * scale)..<max(Int(x0 * scale) + 1, Int(x1 * scale)) {
        let i = (y * w + x) * 4; sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2]); n += 1 } }
    return sum / max(n, 1)
}
var bad = 0
for (x0, x1) in gaps {
    let gap = mean(x0 + 4, x1 - 4, 752, 776), glass = mean(x1 + 8, x1 + 16, 752, 776), backdrop = mean(x0 - 30, x0 - 10, 716, 730)
    let ratio = abs(glass - backdrop) < 1 ? 0 : (glass - gap) / (glass - backdrop)
    let ok = expect == "separate" ? ratio > 0.5 : ratio < 0.25
    if !ok { bad += 1 }
    print(String(format: "gap %4.0f-%4.0f  gap %6.2f  glass %6.2f  backdrop %6.2f  ratio %5.2f  %@", x0, x1, gap, glass, backdrop, ratio, ok ? "ok" : "WRONG for \(expect)"))
}
print(bad == 0 ? "\(expect): ok" : "\(expect): \(bad) wrong")
exit(bad == 0 ? 0 : 1)
