import Foundation

public struct ETACalculator: Sendable {
    private struct Sample: Sendable {
        let progress: Double
        let date: Date
    }
    private var first: Sample?
    private var latest: Sample?
    private var smoothedFinish: Date?
    private static let smoothingFactor = 0.5

    public init() {}

    public mutating func observe(progress: Double, at date: Date = Date()) {
        let clamped = min(1, max(0, progress))
        let sample = Sample(progress: clamped, date: date)
        if first == nil { first = sample }
        latest = sample
        guard let remaining = remainingSeconds(at: date) else { return }
        let candidate = date.addingTimeInterval(remaining)
        if let current = smoothedFinish {
            let step = candidate.timeIntervalSince(current) * Self.smoothingFactor
            smoothedFinish = current.addingTimeInterval(step)
        } else {
            smoothedFinish = candidate
        }
    }

    public mutating func reset() {
        first = nil
        latest = nil
        smoothedFinish = nil
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

    /// Smoothed wall-clock time the job is expected to finish, so a countdown glides between coarse progress updates instead of snapping.
    public func projectedFinish() -> Date? {
        if let latest, latest.progress >= 1 { return latest.date }
        return smoothedFinish
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
