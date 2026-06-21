import Foundation

public struct ETACalculator: Sendable {
    private struct Sample: Sendable {
        let progress: Double
        let date: Date
    }
    private var first: Sample?
    private var latest: Sample?

    public init() {}

    public mutating func observe(progress: Double, at date: Date = Date()) {
        let clamped = min(1, max(0, progress))
        let sample = Sample(progress: clamped, date: date)
        if first == nil { first = sample }
        latest = sample
    }

    public mutating func reset() {
        first = nil
        latest = nil
    }

    public func remainingSeconds(at date: Date = Date()) -> TimeInterval? {
        guard let first, let latest else { return nil }
        if latest.progress >= 1 { return 0 }
        guard latest.progress > first.progress else { return nil }
        let elapsed = latest.date.timeIntervalSince(first.date)
        guard elapsed > 0 else { return nil }
        let rate = (latest.progress - first.progress) / elapsed
        guard rate > 0 else { return nil }
        let remaining = (1 - latest.progress) / rate
        guard remaining.isFinite else { return nil }
        return max(0, remaining)
    }

    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(exactly: max(0, seconds).rounded()) ?? .max
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
