import Foundation

public enum TranscriptTimestampedText {
    public static func render(_ transcript: Transcript) -> String {
        guard !transcript.segments.isEmpty else { return "" }
        let maxEnd = transcript.segments.map(\.end).max() ?? 0
        let useHours = maxEnd >= 3600
        var lines: [String] = []
        for segment in transcript.segments {
            let stamp = format(segment.start, hours: useHours)
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let speaker = segment.speaker, !speaker.isEmpty {
                lines.append("\(stamp)  \(speaker): \(body)")
            } else {
                lines.append("\(stamp)  \(body)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ seconds: Double, hours: Bool) -> String {
        let total = Int(exactly: max(0, seconds).rounded(.towardZero)) ?? .max
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if hours { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
