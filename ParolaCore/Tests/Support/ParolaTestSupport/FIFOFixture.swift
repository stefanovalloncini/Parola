import Foundation

/// A FIFO with no writer parks `open()` for reading, the way a TCC-denied folder or a stalled share does.
public enum FIFOFixture {
    /// AVFoundation funnels every open through one internal queue, so two tests wedging it at once
    /// would stall each other's release; this keeps FIFO tests to one wedge at a time, process-wide.
    private actor Gate {
        static let shared = Gate()
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            while busy {
                await withCheckedContinuation { waiters.append($0) }
            }
            busy = true
        }

        func release() {
            busy = false
            let woken = waiters
            waiters = []
            for waiter in woken { waiter.resume() }
        }
    }

    /// Opened read-write, then unlinked, the writer kept a second: an `open()` that found the path just before the
    /// unlink still meets a writer, so a parked or later one goes through or fails, never outliving the test.
    public static func release(_ url: URL) {
        let descriptor = open(url.path, O_RDWR | O_NONBLOCK)
        unlink(url.path)
        guard descriptor >= 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { close(descriptor) }
    }

    /// Runs `body` under the shared gate and releases the FIFO the moment it returns or throws —
    /// right there, not deferred to the end of a test that does more afterward.
    public static func holding<Value>(
        _ url: URL,
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        await Gate.shared.acquire()
        defer {
            release(url)
            await Gate.shared.release()
        }
        return try await body()
    }
}
