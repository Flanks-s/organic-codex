// WinRec — records one window with ScreenCaptureKit, even when other windows cover it.
// Display variant of tools/winrec (built-in screen, run from the shell, so it never asks for a new grant). Adapted from the current product's scripts/winrec (copied, not shared). Built as its own app bundle
// so Screen Recording is granted to "WinRec" once, instead of to Claude. Rebuilding changes the ad-hoc
// signature and macOS may ask again, so rebuild only when needed.
//
// open -n tools/winrec/build/WinRec.app --args --bundle <bundle id> --seconds 6 --out /path/run.mov
// Writes run.mov (ProRes 422) and run.json (status, frame count, presentation times).
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var times: [Double] = []
    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(buffer)
            times.append(buffer.presentationTimeStamp.seconds)
        }
    }
}

struct Args {
    var bundle: String?, windowID: UInt32?, seconds = 6.0, out = "", fps = 240, scale = 1.0
    static func parse() -> Args {
        var a = Args(), i = 1
        let v = CommandLine.arguments
        func next() -> String { i += 1; return i < v.count ? v[i] : "" }
        while i < v.count {
            switch v[i] {
            case "--bundle": a.bundle = next()
            case "--window": a.windowID = UInt32(next())
            case "--seconds": a.seconds = Double(next()) ?? 6
            case "--out": a.out = next()
            case "--fps": a.fps = Int(next()) ?? 240
            case "--scale": a.scale = Double(next()) ?? 1
            default: break
            }
            i += 1
        }
        return a
    }
}

func finish(_ out: String, _ fields: [String: Any], code: Int32) -> Never {
    if !out.isEmpty, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("json"))
    }
    print(fields["status"] ?? ""); exit(code)
}

// SCK needs the window-server connection that NSApplication sets up.
_ = NSApplication.shared
let args = Args.parse()
guard !args.out.isEmpty else { print("usage: display-rec --seconds S --out FILE.mov [--scale 0.5]"); exit(2) }
// Never asks: the shell's app already has Screen Recording or this stops here.
guard CGPreflightScreenCaptureAccess() else { finish(args.out, ["status": "no screen recording permission"], code: 1) }
let url = URL(fileURLWithPath: args.out)
try? FileManager.default.removeItem(at: url)
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
// The built-in screen only: the external one is the user's.
guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else { finish(args.out, ["status": "no built-in display"], code: 1) }
let config = SCStreamConfiguration()
config.width = Int(CGFloat(display.width) * args.scale)
config.height = Int(CGFloat(display.height) * args.scale)
config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(args.fps))
config.pixelFormat = kCVPixelFormatType_32BGRA
config.showsCursor = false
config.queueDepth = 8
let recorder = try Recorder(url: url, width: config.width, height: config.height)
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "displayrec"))
func waitFor(_ start: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        start { error in if let error { c.resume(throwing: error) } else { c.resume() } }
    }
}
try await waitFor { stream.startCapture(completionHandler: $0) }
try await Task.sleep(for: .seconds(args.seconds))
try await waitFor { stream.stopCapture(completionHandler: $0) }
recorder.input.markAsFinished()
await recorder.writer.finishWriting()
let first = recorder.times.first ?? 0
finish(args.out, ["status": "ok", "frames": recorder.times.count, "size": [config.width, config.height], "ptsSeconds": recorder.times.map { $0 - first }], code: 0)
