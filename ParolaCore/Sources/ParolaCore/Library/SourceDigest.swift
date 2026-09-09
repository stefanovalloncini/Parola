import CryptoKit
import Foundation

/// The identity Parola gives an imported file: the SHA-256 of its bytes, lowercase hex. Two
/// imports of the same recording carry the same digest however they arrived and whatever they
/// were transcribed with.
public enum SourceDigest {
    static let chunkBytes = 1 << 20

    /// Hashes the file a chunk at a time and gives up as soon as `isCancelled` says so, returning
    /// nil. Blocking — a 500 MB file takes a moment — so call it off the caller's executor.
    public static func compute(
        contentsOf url: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { return nil }
            guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of `url`, or nil when it could not be had — an unreadable file, a cancelled
    /// caller, or a read that ran past the deadline a file that size is allowed.
    public static func digest(
        of url: URL,
        deadline: Duration? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> String? {
        let stop = CancelFlag()
        let budget = deadline ?? FileReadDeadline.forReading(url)
        let read = await withTaskCancellationHandler {
            await BoundedFileRead.run(deadline: budget, clock: clock) {
                (try? compute(contentsOf: url, isCancelled: { stop.isCancelled })) ?? nil
            }
        } onCancel: {
            stop.cancel()
        }
        guard case .done(let value) = read else {
            stop.cancel()
            return nil
        }
        return value
    }

    // @unchecked is safe: the only state is `cancelled`, guarded by the lock.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }
}
