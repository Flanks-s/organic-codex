// Compares two window captures in a band of rows (window points, 2× pixels): mean and max channel difference,
// and the share of pixels that differ by more than 8. For "this layout did not change" checks (M11.30 Split).
// swift region-diff.swift A.png B.png [y0 y1]   default y 730–790, the Dock row of a 1280×820 window.
import AppKit

let a = CommandLine.arguments
func load(_ path: String) -> CGImage {
    guard let i = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("can't read \(path)") }
    return i
}
func rgba(_ i: CGImage) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: i.width * i.height * 4)
    let c = CGContext(data: &px, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
    return px
}
let i1 = load(a[1]), i2 = load(a[2])
guard i1.width == i2.width, i1.height == i2.height else { print("sizes differ: \(i1.width)x\(i1.height) vs \(i2.width)x\(i2.height)"); exit(1) }
let scale = Double(i1.width) / 1280
let y0 = Int((a.count > 4 ? Double(a[3])! : 730) * scale), y1 = Int((a.count > 4 ? Double(a[4])! : 790) * scale)
let p1 = rgba(i1), p2 = rgba(i2)
var sum = 0.0, maxD = 0, over = 0, n = 0
for y in y0..<min(y1, i1.height) {
    for x in 0..<i1.width {
        let k = (y * i1.width + x) * 4
        var d = 0
        for ch in 0..<3 { d = max(d, abs(Int(p1[k + ch]) - Int(p2[k + ch]))) }
        sum += Double(d); maxD = max(maxD, d); if d > 8 { over += 1 }; n += 1
    }
}
print(String(format: "rows %d–%d px: mean %.3f, max %d, over 8: %d of %d (%.4f%%)", y0, y1, sum / Double(n), maxD, over, n, 100 * Double(over) / Double(n)))
