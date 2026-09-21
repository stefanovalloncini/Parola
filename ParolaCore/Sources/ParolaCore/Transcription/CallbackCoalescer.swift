import Foundation

/// Rate-limits a stream of progress-style values to one every `minimumInterval`, keeping the newest
/// withheld value so `flush()` can deliver it when the stream ends.
///
/// The first value always passes through, so a run reports as early as it does without coalescing.
struct CallbackCoalescer<Value> {
    private let elapsed: @Sendable () -> Duration
    private let minimumInterval: Duration
    private var lastEmit: Duration?
    private var pending: Value?

    init(minimumInterval: Duration) {
        self.init(minimumInterval: minimumInterval, clock: ContinuousClock())
    }

    init<C: Clock>(minimumInterval: Duration, clock: C) where C.Duration == Duration {
        let start = clock.now
        self.elapsed = { start.duration(to: clock.now) }
        self.minimumInterval = minimumInterval
    }

    /// The value to deliver now, or nil while it is withheld until the interval passes.
    mutating func offer(_ value: Value) -> Value? {
        let now = elapsed()
        if let lastEmit, now - lastEmit < minimumInterval {
            pending = value
            return nil
        }
        lastEmit = now
        pending = nil
        return value
    }

    /// The newest withheld value, or nil when everything offered has already been delivered.
    mutating func flush() -> Value? {
        guard let value = pending else { return nil }
        pending = nil
        lastEmit = elapsed()
        return value
    }
}
