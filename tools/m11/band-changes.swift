// M11.43: what changes from one recorded frame to the next inside a box of the window, for "did moving a glass between
// containers show": at rest nothing else moves, so any changed frame there is the move itself.
// swift band-changes.swift REC.mov [Y0 Y1 [X0 X1]]   window points of a 1280-wide window; default the Dock row y 700–800.
// BAND_FROM=… BAND_TO=… limit the time range; BAND_DUMP=DIR also writes every frame in that range as DIR/t-SSS.mmm.png.
// Prints each frame that differs from the one before (t, largest channel difference, pixels over 8, their box in points,
// pixels over 64: a hard cut moves many by that much, a fade step few),
// then the frame count and the changed-frame count. WinRec only delivers a frame when the window changed.
import AVFoundation
import AppKit

let a = CommandLine.arguments
let num = { (i: Int, d: Double) in a.count > i ? Double(a[i])! : d }
let y0 = num(2, 700), y1 = num(3, 800), x0 = num(4, 0), x1 = num(5, 1280)
let env = ProcessInfo.processInfo.environment
let from = Double(env["BAND_FROM"] ?? "") ?? -1, to = Double(env["BAND_TO"] ?? "") ?? 1e9
let dump = env["BAND_DUMP"]
if let dump { try? FileManager.default.createDirectory(atPath: dump, withIntermediateDirectories: true) }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let track = asset.tracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
// Start a little before BAND_FROM: decoding the whole file first made short windows of long recordings slow.
if from > 0 || to < 1e9 {
    let start = max(0, from - 0.5), end = to < 1e9 ? to + 0.05 : asset.duration.seconds
    reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 6000), end: CMTime(seconds: end, preferredTimescale: 6000))
}
reader.add(out); reader.startReading()
var last: [UInt8] = [], frames = 0, changed = 0
while let sample = out.copyNextSampleBuffer(), let buf = CMSampleBufferGetImageBuffer(sample) {
    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), row = CVPixelBufferGetBytesPerRow(buf)
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    let s = Double(w) / 1280
    let ry = Int(y0 * s)..<min(h, Int(y1 * s)), rx = Int(x0 * s)..<min(w, Int(x1 * s))
    var cur = [UInt8](); cur.reserveCapacity(ry.count * rx.count * 3)
    for y in ry { for x in rx { let i = y * row + x * 4; cur.append(base[i]); cur.append(base[i + 1]); cur.append(base[i + 2]) } }
    guard t >= from, t <= to else { last = cur; continue }
    frames += 1
    if let dump {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        let d = rep.bitmapData!
        for y in 0..<h { for x in 0..<w { let i = y * row + x * 4, k = (y * w + x) * 4; d[k] = base[i + 2]; d[k + 1] = base[i + 1]; d[k + 2] = base[i]; d[k + 3] = 255 } }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dump)/t-\(String(format: "%07.3f", t)).png"))
    }
    if last.count == cur.count {
        var maxD = 0, over = 0, strong = 0, bx0 = Int.max, bx1 = -1, by0 = Int.max, by1 = -1
        for k in 0..<(cur.count / 3) {
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(cur[k * 3 + c]) - Int(last[k * 3 + c]))) }
            maxD = max(maxD, d)
            if d > 64 { strong += 1 }
            if d > 8 { over += 1; let x = k % rx.count, y = k / rx.count; bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y) }
        }
        if maxD > 0 {
            changed += 1
            let box = over > 0 ? String(format: "x %.1f–%.1f y %.1f–%.1f", (Double(bx0 + rx.lowerBound)) / s, (Double(bx1 + rx.lowerBound + 1)) / s,
                                        (Double(by0 + ry.lowerBound)) / s, (Double(by1 + ry.lowerBound + 1)) / s) : ""
            print(String(format: "%8.3f  max %3d  over8 %6d  %@  over64 %d", t, maxD, over, box, strong))
        }
    }
    last = cur
}
print("frames \(frames), changed \(changed)")
