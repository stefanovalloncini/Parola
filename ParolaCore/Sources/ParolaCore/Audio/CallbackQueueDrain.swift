import Foundation

extension DispatchQueue {
    /// Awaits a no-op block on the queue, so a capture callback already dispatched there finishes
    /// before the caller releases the file it writes to. Unlike `sync`, it frees the cooperative
    /// thread while the queue catches up.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.async { continuation.resume() }
        }
    }
}
