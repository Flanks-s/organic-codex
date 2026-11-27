// M11.30: necks between the Dock's glass shapes, followed gap by gap through a window recording. A gap is a run of
// columns with no glass pixel on rows y 742–786 (a neck of any height closes it; content over the glass is not glass).
// Limit: a content motion trail with neutral grey parts (the send button's) can cross a gap and read as glass;
// check flagged moments frame by frame before calling them necks. Gaps are matched frame to frame
// by position, so each keeps its identity while the shapes move; the "me" avatar (x≈30) is inside the range, so it
// never leaves it. Replaces counting runs on one row (segment-series.swift), which mistook me leaving x 60 for a
// re-join and missed 3 → 2 → 3 (Astra, M11-30-ASTRA-261104.md).
// swift neck-gaps.swift REC.mov [from to]   NECK_LIST=1 also prints every frame's gaps.
// Prints each gap's birth and death with time and x, and a flicker list: a gap that dies and is reborn near the same
// place within 0.12 s, or is born and dies within 0.12 s.
import AVFoundation

let a = CommandLine.arguments
let from = a.count > 3 ? Double(a[2])! : 0, to = a.count > 3 ? Double(a[3])! : .infinity
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(out); reader.startReading()

struct Gap { var id: Int; var x0: Double; var x1: Double; var mid: Double { (x0 + x1) / 2 } }
var live: [Gap] = [], nextID = 0
var events: [(t: Double, kind: String, id: Int, x: Double)] = []
let xLo = 20.0, xHi = 1100.0, matchReach = 60.0

while let sample = out.copyNextSampleBuffer(), let buf = CMSampleBufferGetImageBuffer(sample) {
    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    if t < from || t > to { continue }
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    let w = CVPixelBufferGetWidth(buf), row = CVPixelBufferGetBytesPerRow(buf), s = Double(w) / 1280
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    func lum(_ x: Int, _ y: Int) -> Double { let i = y * row + x * 4; return 0.0722 * Double(base[i]) + 0.7152 * Double(base[i + 1]) + 0.2126 * Double(base[i + 2]) }
    // Glass is a near-neutral grey of moderate brightness. Content drawn over it (the blue send button and its motion
    // trail, white highlights) can reach into a gap while the glass on both sides stays apart; it must not count.
    func glass(_ x: Int, _ y: Int, _ threshold: Double) -> Bool {
        let i = y * row + x * 4, b = Double(base[i]), g = Double(base[i + 1]), r = Double(base[i + 2])
        let l = 0.0722 * b + 0.7152 * g + 0.2126 * r
        return l > threshold && l < threshold + 70 && max(r, g, b) - min(r, g, b) < 28
    }
    var bsum = 0.0, bn = 0.0
    for x in stride(from: Int(xLo * s), to: Int(xHi * s), by: 4) { bsum += lum(x, Int(722 * s)); bn += 1 }
    let threshold = bsum / bn + 9
    let rows = Array(Int(742 * s)...Int(786 * s))
    var glassCol = [Bool](repeating: false, count: Int(xHi * s) + 1)
    for x in Int(xLo * s)..<Int(xHi * s) {
        for y in rows where glass(x, y, threshold) { glassCol[x] = true; break }
    }
    CVPixelBufferUnlockBaseAddress(buf, .readOnly)
    // Gaps: interior runs of non-glass columns at least 2 px wide, with glass on both sides.
    var gaps: [(Double, Double)] = [], start = -1, seenGlass = false
    for x in Int(xLo * s)..<Int(xHi * s) {
        if glassCol[x] {
            if start >= 0, seenGlass, x - start >= 2 { gaps.append((Double(start) / s, Double(x) / s)) }
            start = -1; seenGlass = true
        } else if start < 0 { start = x }
    }
    if ProcessInfo.processInfo.environment["NECK_LIST"] != nil { print(String(format: "%7.3f  ", t) + gaps.map { String(format: "%.0f–%.0f", $0.0, $0.1) }.joined(separator: " ")) }
    // Gaps keep their left-to-right order, so match in order: same count, by index; a changed count, by the
    // order-preserving pairing with the least total movement (at most a handful of gaps, so try every subset).
    let mids = gaps.map { ($0.0 + $0.1) / 2 }
    var next: [Gap] = []
    func pairs(_ small: Int, _ big: Int, cost: (Int, Int) -> Double) -> [Int] {
        // choose `small` increasing indices out of `big`; returns the chosen indices of the bigger list
        var best: [Int] = [], bestCost = Double.infinity
        func walk(_ i: Int, _ j: Int, _ pick: [Int], _ c: Double) {
            if c >= bestCost { return }
            if i == small { best = pick; bestCost = c; return }
            if big - j < small - i { return }
            walk(i + 1, j + 1, pick + [j], c + cost(i, j))
            walk(i, j + 1, pick, c)
        }
        walk(0, 0, [], 0); return best
    }
    if mids.count == live.count {
        for (k, g) in gaps.enumerated() { next.append(Gap(id: live[k].id, x0: g.0, x1: g.1)) }
    } else if mids.count < live.count {
        let kept = pairs(mids.count, live.count) { i, j in abs(mids[i] - live[j].mid) }
        for (i, j) in kept.enumerated() { next.append(Gap(id: live[j].id, x0: gaps[i].0, x1: gaps[i].1)) }
        for (j, g) in live.enumerated() where !kept.contains(j) { events.append((t, "died", g.id, g.mid)) }
    } else {
        let kept = pairs(live.count, mids.count) { i, j in abs(live[i].mid - mids[j]) }
        var byNew: [Int: Int] = [:]; for (i, j) in kept.enumerated() { byNew[j] = live[i].id }
        for (j, g) in gaps.enumerated() {
            if let id = byNew[j] { next.append(Gap(id: id, x0: g.0, x1: g.1)) }
            else { next.append(Gap(id: nextID, x0: g.0, x1: g.1)); events.append((t, "born", nextID, mids[j])); nextID += 1 }
        }
    }
    live = next
}
for e in events { print(String(format: "%7.3f  %-4@ gap %3d at x %6.1f", e.t, e.kind, e.id, e.x)) }
// Flickers: death then a birth within 0.12 s and 40 pt, or a birth whose gap dies within 0.12 s.
var flickers: [String] = []
for (i, e) in events.enumerated() {
    if e.kind == "died", let b = events[(i + 1)...].first(where: { $0.kind == "born" && $0.t - e.t <= 0.12 && abs($0.x - e.x) < matchReach }) {
        flickers.append(String(format: "closed %.3f–%.3f at x %.0f", e.t, b.t, e.x))
    }
    if e.kind == "born", let d = events[(i + 1)...].first(where: { $0.kind == "died" && $0.id == e.id && $0.t - e.t <= 0.12 }) {
        flickers.append(String(format: "opened %.3f–%.3f at x %.0f", e.t, d.t, e.x))
    }
}
print("flickers: \(flickers.count)"); flickers.forEach { print("  " + $0) }
