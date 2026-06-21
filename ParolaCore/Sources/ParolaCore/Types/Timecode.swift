import Foundation

public enum Timecode {
    /// H:MM:SS for durations over an hour, MM:SS otherwise.
    public static func format(_ seconds: Double) -> String {
        let total = Int(exactly: max(0, seconds).rounded(.towardZero)) ?? .max
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Parses MM:SS or HH:MM:SS into seconds. Returns nil for malformed input.
    public static func parse(_ string: String) -> Double? {
        let parts = string.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Int = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return Double(total)
    }
}
