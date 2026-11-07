import Darwin
import Foundation

/// Test-run crash guard (Claude, 11-06, Advisor plan after DialogType proved a dead end on macOS 27.2). A crash in a driver or
/// self-test run normally raises the system's crash dialog, which takes the front and leaves every later run without a key
/// window. Installed only in test runs, this catches the crash in-process instead:
/// - an uncaught NSException writes its name, reason and call stack symbols;
/// - SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP and SIGFPE (on an alternate stack) write the signal and backtrace;
/// then the process calls _exit(70). Nothing is re-raised, so ReportCrash never sees a crash: no dialog and no system .ips.
/// The trace goes to DIRECTORY/crash-guard.txt, which the lanes read as CRASHED.
enum CrashGuard {
    static let exitCode: Int32 = 70
    // Everything the signal handler touches is prepared here, so the handler itself only calls async-signal-safe functions
    // (open, write, strlen, backtrace, backtrace_symbols_fd, close, _exit) and allocates nothing.
    nonisolated(unsafe) fileprivate static var path: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) fileprivate static var frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    nonisolated(unsafe) fileprivate static var names = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 64)
    nonisolated(unsafe) private static var altStack: UnsafeMutableRawPointer?

    static var installed: Bool { path != nil }

    /// Installs the guard for this process. The alternate signal stack covers the calling thread only, so call it from main.
    static func install(directory: String) {
        guard path == nil else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = strdup((directory as NSString).appendingPathComponent("crash-guard.txt"))
        let signals: [(Int32, String)] = [(SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"),
                                          (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE")]
        // Touch the lazily initialised statics here, never first in the handler.
        _ = frames; names.initialize(repeating: nil, count: 64)
        for (signal, name) in signals { names[Int(signal)] = strdup("CRASHED \(name)\nbacktrace:\n") }
        NSSetUncaughtExceptionHandler { exception in
            let text = "CRASHED NSException \(exception.name.rawValue): \(exception.reason ?? "")\ncallStackSymbols:\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            CrashGuard.append(text)
            _exit(CrashGuard.exitCode)
        }
        let size = 256 * 1024
        altStack = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        var stack = stack_t(ss_sp: altStack, ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)
        for (signal, _) in signals {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: crashGuardSignal)
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// Outside a signal handler only (the exception path).
    fileprivate static func append(_ text: String) {
        guard let path else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        text.utf8CString.withUnsafeBufferPointer { buffer in _ = write(fd, buffer.baseAddress, max(0, buffer.count - 1)) }
        close(fd)
    }
}

/// The signal handler: async-signal-safe calls only, no allocation, no Swift strings.
private func crashGuardSignal(_ signal: Int32) {
    if let path = CrashGuard.path {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            if signal >= 0, signal < 64, let name = CrashGuard.names[Int(signal)] { _ = write(fd, name, strlen(name)) }
            let count = backtrace(CrashGuard.frames, 128)
            backtrace_symbols_fd(CrashGuard.frames, count, fd)
            close(fd)
        }
    }
    _exit(CrashGuard.exitCode)
}
