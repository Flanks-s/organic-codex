import Foundation

/// Await an already submitted GPU command without polling or submitting cleanup work after hiding.
final class BodyWorkFence: @unchecked Sendable {
    private let lock=NSLock()
    private var completed=false
    private var waiters: [CheckedContinuation<Void,Never>]=[]
    func finish() {
        lock.lock(); completed=true
        let pending=waiters; waiters=[]; lock.unlock()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}
