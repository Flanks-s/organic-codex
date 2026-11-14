// M11.30: the Dock's two Auto gaps over a whole window recording, frame by frame, with dock-gap-check.swift's ratio
// (about 0: glass runs through the gap, about 1: none does). Shows when the gaps close and open around Focused.
// swift gap-series.swift REC.mov [x0-x1 ...]   prints: t  ratio per gap  (only frames where a ratio moved by > 0.03, plus the first)
import AVFoundation

let a = CommandLine.arguments
let gaps: [(Double, Double)] = a.count > 2 ? a[2...].map { let p = $0.split(separator: "-").compactMap { Double($0) }; return (p[0], p[1]) } : [(593, 605), (910, 922)]
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let track = asset.tracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(out); reader.startReading()
var last: [Double] = []
while let sample = out.copyNextSampleBuffer(), let buf = CMSampleBufferGetImageBuffer(sample) {
    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    let w = CVPixelBufferGetWidth(buf), row = CVPixelBufferGetBytesPerRow(buf)
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    let scale = Double(w) / 1280
    func mean(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
        var sum = 0.0, n = 0.0
        for y in Int(y0 * scale)..<max(Int(y0 * scale) + 1, Int(y1 * scale)) { for x in Int(x0 * scale)..<max(Int(x0 * scale) + 1, Int(x1 * scale)) {
            let i = y * row + x * 4; sum += 0.0722 * Double(base[i]) + 0.7152 * Double(base[i + 1]) + 0.2126 * Double(base[i + 2]); n += 1 } }
        return sum / max(n, 1)
    }
    let ratios = gaps.map { (x0, x1) -> Double in
        let gap = mean(x0 + 4, x1 - 4, 752, 776), glass = mean(x1 + 8, x1 + 16, 752, 776), backdrop = mean(x0 - 30, x0 - 10, 716, 730)
        return abs(glass - backdrop) < 1 ? 0 : (glass - gap) / (glass - backdrop)
    }
    CVPixelBufferUnlockBaseAddress(buf, .readOnly)
    if last.isEmpty || zip(ratios, last).contains(where: { abs($0 - $1) > 0.03 }) {
        print(String(format: "%7.3f", t), ratios.map { String(format: "%6.2f", $0) }.joined(separator: " "))
        last = ratios
    }
}
