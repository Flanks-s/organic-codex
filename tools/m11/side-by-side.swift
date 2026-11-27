// M11.31 side-by-side: two window recordings next to each other, each cut from its own key press, at real speed or
// slowed, with a label over each half. WinRec recordings only hold a frame when the window changed; the composition
// keeps showing the last one, as the screen did.
// swift side-by-side.swift OUT.mp4 SLOW DURATION LEFT.mov LEFT_START LEFT_LABEL RIGHT.mov RIGHT_START RIGHT_LABEL
//   SLOW 1 = real speed, 4 = quarter speed. START and DURATION in seconds of each recording (cut from START - 0.1 s so
//   the first output frame shows the window just before the key). Output: 2560 × 856 HEVC, labels in a 36 px strip.
import AVFoundation
import AppKit

let a = CommandLine.arguments
guard a.count == 10, let slow = Double(a[2]), let duration = Double(a[3]), let ls = Double(a[5]), let rs = Double(a[8]) else {
    print("usage: side-by-side.swift OUT.mp4 SLOW DURATION LEFT.mov LEFT_START LEFT_LABEL RIGHT.mov RIGHT_START RIGHT_LABEL"); exit(2)
}
let out = URL(fileURLWithPath: a[1])
let pre = 0.1, w = 1280.0, h = 820.0, strip = 36.0
let comp = AVMutableComposition()
let instruction = AVMutableVideoCompositionInstruction()
var layers: [AVMutableVideoCompositionLayerInstruction] = []
let total = CMTime(seconds: (duration + pre) * slow, preferredTimescale: 6000)
for (i, (path, start)) in [(a[4], ls), (a[7], rs)].enumerated() {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let src = try await asset.loadTracks(withMediaType: .video).first,
          let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        print("no video track in \(path)"); exit(1)
    }
    let range = CMTimeRange(start: CMTime(seconds: max(0, start - pre), preferredTimescale: 6000),
                            duration: CMTime(seconds: duration + pre, preferredTimescale: 6000))
    try track.insertTimeRange(range, of: src, at: .zero)
    if slow != 1 { track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: total) }
    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    li.setTransform(CGAffineTransform(translationX: Double(i) * w, y: strip), at: .zero)
    layers.append(li)
}
instruction.timeRange = CMTimeRange(start: .zero, duration: total)
instruction.layerInstructions = layers
let video = AVMutableVideoComposition()
video.instructions = [instruction]
video.renderSize = CGSize(width: w * 2, height: h + strip)
video.frameDuration = CMTime(value: 1, timescale: 120)
video.renderScale = 1

// Labels: Core Animation's y runs up, so the strip at the top of the picture is at y = h.
let parent = CALayer(), videoLayer = CALayer()
parent.frame = CGRect(x: 0, y: 0, width: w * 2, height: h + strip)
videoLayer.frame = parent.frame
parent.addSublayer(videoLayer)
let speed = slow == 1 ? "real speed" : "1/\(Int(slow)) speed"
// The labels are drawn into bitmaps first: a CATextLayer comes out blank in the export.
for (i, label) in [a[6], a[9]].enumerated() {
    let size = CGSize(width: w, height: strip)
    guard let ctx = CGContext(data: nil, width: Int(w), height: Int(strip), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let text = NSAttributedString(string: "\(label)   ·   \(speed)   ·   starts 0.1 s before the key", attributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
    let b = text.size()
    text.draw(at: CGPoint(x: (w - b.width) / 2, y: (strip - b.height) / 2))
    NSGraphicsContext.current = nil
    let layer = CALayer()
    layer.contents = ctx.makeImage()
    layer.frame = CGRect(x: Double(i) * w, y: h, width: w, height: strip)
    parent.addSublayer(layer)
}
video.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

try? FileManager.default.removeItem(at: out)
guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVCHighestQuality) else { print("no export session"); exit(1) }
export.videoComposition = video
try await export.export(to: out, as: .mp4)
print("wrote \(out.path) (\(String(format: "%.2f", total.seconds)) s)")
