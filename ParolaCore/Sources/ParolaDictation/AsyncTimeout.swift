import Foundation

/// Races async work against a deadline without waiting for the loser: a structured
/// task-group race still awaits its cancelled child, so work that ignores cancellation
/// (a hung AX round-trip, a wedged model call) would hold the caller past the timeout.
/// On timeout the work task is cancelled and abandoned — it may run to completion in
/// the background, and callers accept that leak.
public enum AsyncTimeout {
    public static func run<T: Sendable>(
        _ timeout: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let winner = FirstClaim()
            let work = Task {
                let value = await operation()
                if winner.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await clock.sleep(for: timeout, tolerance: nil)
                if winner.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // @unchecked is safe: the only state is `taken`, guarded by the lock.
    private final class FirstClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
