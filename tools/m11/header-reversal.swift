// header-reversal RUN_DIR: did a header jump the wrong way at the start of a column switch?
//
// Reads rec.mov, rec.json, diff.txt and app/receipt.json of a recorded run. For each switch it tracks the capsule titles, the
// bright clusters in the band y 70...132, through every recorded frame from just before the commit to 130 ms after, and flags
// a title that jumps 40 pt or more and then comes back 25 pt or more. Found by Opus in board 261031i: 8 of 12 on that
// run's switch-short, none after f0fce3f. Only a window recording: a camera sees the screen, this doesn't.
// Build: swiftc -O tools/m11/header-reversal.swift -o tools/m11/header-reversal
import AVFoundation
import AppKit

let run = URL(fileURLWithPath: CommandLine.arguments[1])
func json(_ name: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent(name))) as! [String: Any]
}
let switches = json("app/receipt.json")["switches"] as! [[String: Any]]
let pts = json("rec.json")["ptsSeconds"] as! [Double]

// The app's clock against the movie's: the offset that puts the most commits right before a changed frame.
var changed: [(t: Double, px: Int)] = []
for line in try! String(contentsOf: run.appendingPathComponent("diff.txt"), encoding: .utf8).split(separator: "\n") {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
    if parts.count > 3, parts[3] == "px", let t = Double(parts[1]), let px = Int(parts[2]) { changed.append((t, px)) }
}
let times = switches.compactMap { $0["at"] as? Double }
var offset = 0.0, best = -1
for first in changed where first.px >= 3000 {
    let candidate = times[0] - first.t
    let score = times.filter { at in changed.contains { abs($0.t - (at - candidate)) < 0.015 && $0.px >= 1500 } }.count
    if score > best { best = score; offset = candidate }
}

let generator = AVAssetImageGenerator(asset: AVURLAsset(url: run.appendingPathComponent("rec.mov")))
generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
/// The titles' horizontal extents in points: bright columns, split where the gap is wider than 34 pt, each wider than 70 pt.
func titles(at t: Double) -> [(CGFloat, CGFloat)]? {
    guard let image = try? generator.copyCGImage(at: CMTime(seconds: t + 0.003, preferredTimescale: 6000), actualTime: nil) else { return nil }
    let w = image.width, h = image.height, scale = CGFloat(w) / 1280
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var bright = [Bool](repeating: false, count: w)
    for y in Int(70 * scale)..<min(h, Int(132 * scale)) {
        for x in 0..<w where pixels[(y * w + x) * 4 + 1] > 170 { bright[x] = true }
    }
    var out: [(CGFloat, CGFloat)] = [], start: Int?, last = 0
    for x in 0..<w where bright[x] {
        if let s = start, CGFloat(x - last) / scale > 34 {
            if CGFloat(last - s) / scale > 70 { out.append((CGFloat(s) / scale, CGFloat(last) / scale)) }
            start = x
        } else if start == nil { start = x }
        last = x
    }
    if let s = start, CGFloat(last - s) / scale > 70 { out.append((CGFloat(s) / scale, CGFloat(last) / scale)) }
    return out
}

var checked = 0, reversed = 0
for at in times {
    let commit = at - offset
    let frames = pts.filter { $0 >= commit - 0.02 && $0 <= commit + 0.13 }.compactMap { t in titles(at: t).map { (t, $0) } }.filter { $0.1.count >= 2 }
    guard frames.count >= 3 else { continue }
    checked += 1
    var found: String?
    for i in 0..<2 where found == nil {
        let xs = frames.compactMap { f -> (Double, CGFloat)? in i < f.1.count ? (f.0, (f.1[i].0 + f.1[i].1) / 2) : nil }
        for k in xs.indices.dropFirst().dropLast() {
            let there = xs[k].1 - xs[k - 1].1
            guard abs(there) >= 40, let next = xs[(k + 1)...].first(where: { $0.1 != xs[k].1 }) else { continue }
            let back = next.1 - xs[k].1
            if abs(back) >= 25, there * back < 0 {
                found = String(format: "title %d: %.3f %+.0f pt, %.3f %+.0f pt", i, xs[k].0, there, next.0, back)
                break
            }
        }
    }
    if let found { reversed += 1; print(String(format: "%.3f ", commit) + found) }
}
print("switches with a reversal: \(reversed) of \(checked) with enough frames, \(times.count) in the receipt")
exit(reversed > 0 ? 1 : 0)
