import AppKit
import CoreMedia
import Darwin
import QuartzCore

/// Opt-in, local JSONL diagnostics. No file, queue, payload or clock reads are created per frame when disabled.
@MainActor final class DockFrameLog {
    static let shared: DockFrameLog? = {
        guard let value = getenv("DOCK_FRAME_LOG"), value.pointee != 0 else { return nil }
        return DockFrameLog(path: String(cString: value))
    }()

    final class Context {
        let sink: DockFrameLog
        let id = UUID().uuidString
        var transitionCount = 0, lastLoggedTransition = 0
        var transitionBegan = 0.0
        var fromFocused = false, toFocused = false, reversed = false
        init(_ sink: DockFrameLog) { self.sink = sink }
        func transition(at time: Double, from: Bool, to: Bool, previousUntil: Double) {
            reversed = time < previousUntil && from != to && transitionCount > 0 && toFocused != to
            transitionCount += 1; transitionBegan = time; fromFocused = from; toFocused = to
        }
    }

    private let descriptor: Int32
    private let session = UUID().uuidString
    private var sequence = 0
    private var previousWriteMS = 0.0

    private init?(path: String) {
        descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            fputs("DOCK_FRAME_LOG: cannot open destination (errno \(errno)); logging disabled\n", stderr)
            return nil
        }
    }

    nonisolated static func rect(_ r: CGRect) -> [CGFloat] { [r.origin.x, r.origin.y, r.size.width, r.size.height] }

    func write(_ payload: [String: Any]) {
        let start = CACurrentMediaTime()
        var row = payload
        sequence += 1
        row["schema"] = 1
        row["session"] = session
        row["pid"] = getpid()
        row["sequence"] = sequence
        row["mediaTime"] = start
        row["hostTimeSeconds"] = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        row["unixSeconds"] = Date().timeIntervalSince1970
        row["previousWriteMS"] = previousWriteMS
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        // Synchronous append avoids losing the final frame when an offscreen driver calls exit(). No fsync.
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                offset += count
            }
        }
        previousWriteMS = (CACurrentMediaTime() - start) * 1000
    }

    deinit { Darwin.close(descriptor) }
}
