import Foundation

/// What a bounded read came back with. `.timedOut` means the read is still parked on a thread
/// this process has stopped waiting for.
public enum BoundedRead<Value: Sendable>: Sendable {
    case done(Value)
    case timedOut
}

/// How long a file read on the transcription path may take before Parola stops waiting for it.
/// A TCC-denied folder, a stalled network share and an ejected volume all park `open()` in a
/// syscall that returns no error and cannot be interrupted.
public enum FileReadDeadline {
    /// Reading a header costs the same whatever the file weighs, so one figure covers every size.
    public static let header: Duration = .seconds(30)

    /// Slower than any working disk or share, fast enough that a wedge is still caught in minutes.
    static let slowestTolerableBytesPerSecond = 5_000_000.0

    static let ceiling: Duration = .seconds(3600)

    /// Streaming a whole file scales with its size, so the budget scales too, never below `header`.
    public static func forReading(_ url: URL) -> Duration {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
        guard let bytes = size ?? nil else { return header }
        return budget(forBytes: bytes)
    }

    static func budget(forBytes bytes: UInt64) -> Duration {
        let seconds = Double(bytes) / slowestTolerableBytesPerSecond
        guard seconds.isFinite else { return ceiling }
        return max(header, min(ceiling, .seconds(seconds)))
    }
}

/// Runs blocking file I/O off the caller's executor and stops waiting at the deadline. The parked
/// thread is abandoned rather than cancelled — nothing can interrupt it — and whatever it
/// eventually returns is dropped. GCD and not `Task.detached`: a detached job resuming main-actor
/// work around AVFoundation's NSURL bridging has crashed with EXC_ARM_DA_ALIGN before.
public enum BoundedFileRead {
    public static func run<Value: Sendable>(
        deadline: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        _ work: @escaping @Sendable () -> Value
    ) async -> BoundedRead<Value> {
        let value = await AsyncTimeout.run(deadline, clock: clock) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: work())
                }
            }
        }
        guard let value else { return .timedOut }
        return .done(value)
    }
}
