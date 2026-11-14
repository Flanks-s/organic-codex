// M11.30: how many separate glass shapes cross the Dock's centre row, frame by frame, in a window recording. A neck
// between two bubbles joins them into one run, so the count drops; a count that goes down, up, down within one motion
// is a neck flickering. swift segment-series.swift REC.mov [y] [x0 x1]   default y 764, x 60–1100 (bubbles, not the orbs)
// SERIES_FROM=… SERIES_TO=… print every frame in that time range.
// Prints t, count and the runs (x from–to in points) whenever the count changes, then the number of re-joins:
// a frame where the count drops again within 0.2 s after it rose.
import AVFoundation

let a = CommandLine.arguments
let yRow = a.count > 2 ? Double(a[2])! : 764, xLo = a.count > 4 ? Double(a[3])! : 60, xHi = a.count > 4 ? Double(a[4])! : 1100
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(out); reader.startReading()
var last = -1, lastRise = -9.0, rejoins: [Double] = []
while let sample = out.copyNextSampleBuffer(), let buf = CMSampleBufferGetImageBuffer(sample) {
    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    let w = CVPixelBufferGetWidth(buf), row = CVPixelBufferGetBytesPerRow(buf), scale = Double(w) / 1280
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    let y = Int(yRow * scale)
    func lum(_ x: Int) -> Double { let i = y * row + x * 4; return 0.0722 * Double(base[i]) + 0.7152 * Double(base[i + 1]) + 0.2126 * Double(base[i + 2]) }
    // The backdrop just above the Dock sets the threshold: glass is clearly brighter than it.
    var bsum = 0.0, bn = 0.0
    for x in stride(from: Int(xLo * scale), to: Int(xHi * scale), by: 4) { let i = Int(722 * scale) * row + x * 4
        bsum += 0.0722 * Double(base[i]) + 0.7152 * Double(base[i + 1]) + 0.2126 * Double(base[i + 2]); bn += 1 }
    let threshold = bsum / bn + 9
    var runs: [(Int, Int)] = [], start = -1, gap = 0
    for x in Int(xLo * scale)..<Int(xHi * scale) {
        if lum(x) > threshold { if start < 0 { start = x }; gap = 0 }
        else if start >= 0 { gap += 1; if Double(gap) > 2.5 * scale { runs.append((start, x - gap)); start = -1; gap = 0 } }
    }
    if start >= 0 { runs.append((start, Int(xHi * scale))) }
    runs = runs.filter { Double($0.1 - $0.0) > 20 * scale }
    CVPixelBufferUnlockBaseAddress(buf, .readOnly)
    // SERIES_FROM / SERIES_TO (seconds): print every frame in that range, for following one edge frame by frame.
    let env = ProcessInfo.processInfo.environment
    if let from = env["SERIES_FROM"].flatMap(Double.init), let to = env["SERIES_TO"].flatMap(Double.init), t >= from, t <= to {
        print(String(format: "%7.3f  %d  ", t, runs.count) + runs.map { String(format: "%.0f–%.0f", Double($0.0) / scale, Double($0.1) / scale) }.joined(separator: " "))
        last = runs.count; continue
    }
    if runs.count != last {
        if last >= 0 && runs.count < last && t - lastRise < 0.2 { rejoins.append(t) }
        if last >= 0 && runs.count > last { lastRise = t }
        print(String(format: "%7.3f  %d  ", t, runs.count) + runs.map { String(format: "%.0f–%.0f", Double($0.0) / scale, Double($0.1) / scale) }.joined(separator: " "))
        last = runs.count
    }
}
print("re-joins within 0.2 s of a split: \(rejoins.count)" + (rejoins.isEmpty ? "" : " at " + rejoins.map { String(format: "%.3f", $0) }.joined(separator: ", ")))
