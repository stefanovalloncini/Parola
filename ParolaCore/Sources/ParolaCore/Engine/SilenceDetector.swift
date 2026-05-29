import Foundation

public struct SilenceDetector: Sendable, Equatable {
    public var threshold: TimeInterval
    private var silenceStart: Date?

    public init(threshold: TimeInterval = 8) {
        self.threshold = threshold
    }

    public mutating func note(active: Bool, at date: Date = Date()) {
        if active {
            silenceStart = nil
        } else if silenceStart == nil {
            silenceStart = date
        }
    }

    public mutating func reset() {
        silenceStart = nil
    }

    public func silenceSeconds(at date: Date = Date()) -> TimeInterval {
        guard let start = silenceStart else { return 0 }
        return max(0, date.timeIntervalSince(start))
    }

    public func shouldAlert(at date: Date = Date()) -> Bool {
        silenceSeconds(at: date) >= threshold
    }
}
